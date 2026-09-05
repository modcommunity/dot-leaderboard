class_name DotLeaderboardReporter
extends RefCounted

## Sends entries and statistics to the TMC backbone, in batches, without losing them.
##
## [b]dot-auth is not a dependency and [code]DotBackboneClient[/code] is not named.[/b]
## The family rule — a script that mentions an absent [code]class_name[/code] fails to
## parse. The client is assigned as an [Object] and its
## [code]post_integration(path, body)[/code] is called by name, which is the generic
## hook dot-auth already exposes for exactly this: it stamps [code]ts[/code] and
## [code]nonce[/code], adds the bearer header, and rate-limits locally. Everything
## about authenticating to the backbone therefore lives in one place and this class
## does not know the token exists.
##
## [b]Batched, queued and retried, because a leaderboard report is the least urgent
## and most losable thing a server sends.[/b] Three properties this has to have:
##
## - **Nothing is sent per event.** Twenty players finishing a round is twenty POSTs
##   to the same endpoint, which is both rude and the reason integration rate limits
##   exist.
## - **A failed flush does not lose the queue.** The backbone being down for a minute
##   must cost a minute of latency, not a round of results.
## - **The queue is bounded.** A backbone that is down for a day must not grow the
##   server's memory until it is killed — so the queue has a cap and drops the
##   OLDEST, because on a leaderboard the newest results are the ones somebody is
##   waiting to see.

const CHANNEL := "leaderboard.report"

## The integration endpoint entries go to, relative to `/api/integration/v1/`.
const SUBMIT_PATH := "leaderboard/submit"

## The endpoint a board's definition is declared at.
const DEFINE_PATH := "leaderboard/define"

## The scope an integration needs to submit. Named so a 403 can say which box to tick.
const SCOPE_WRITE := "LEADERBOARD_WRITE"

## The backbone client. Any object with `post_integration(String, Dictionary)`.
var client: Object = null

## Entries queued but not yet sent.
var _queue: Array[Dictionary] = []

## Most entries held before the oldest are dropped.
##
## Two hundred is several rounds' worth on a full server and a few tens of kilobytes.
var queue_limit: int = 200

## Most entries in one request.
##
## Matched to what the backbone's schema caps a submission at. Sending more means a
## 400 for the whole batch, which loses results that were individually fine.
var batch_limit: int = 50

## Diagnostics.
var sent: int = 0
var dropped: int = 0
var failures: int = 0
var last_error: String = ""


static func with_client(p_client: Object) -> DotLeaderboardReporter:
	var reporter := DotLeaderboardReporter.new()
	reporter.client = p_client
	return reporter


func is_available() -> bool:
	return client != null and client.has_method("post_integration")


## Queues an entry for the next flush.
##
## [b]Queued rather than sent, always.[/b] Even when the backbone is reachable and the
## queue is empty: a caller that sometimes blocks on a round trip and sometimes does
## not is one whose timing depends on the network, and the place this is called from
## is the end of a run.
func queue_entry(
	board: DotLeaderboardDef, entry: DotLeaderboardEntry
) -> void:
	if board == null or entry == null:
		return

	if not board.publish:
		# Publishing sends player names and scores off the server, so it is opt-in
		# per board. Silently dropping here rather than refusing: a board that is not
		# published is a normal configuration, not a mistake.
		return

	# The backbone's shape, field for field — `LeaderboardSubmitInput` in
	# website-city's src/types/integration/leaderboard.ts. The kind travels as the
	# enum's NAME, because an integer means nothing to a site that has its own
	# enum, and the timestamp is camel-cased because that contract is. This once
	# sent `set_at` and an integer kind, and no test could see it: the two ends
	# had never met.
	_queue.append({
		"board": String(board.id),
		"scope": board.scope.duplicate(true),
		"kind": DotLeaderboardDef.kind_name(board.kind),
		"player": String(entry.player_id),
		"name": entry.player_name,
		"value": entry.value,
		"meta": entry.meta,
		"setAt": entry.set_at,
	})

	while _queue.size() > queue_limit:
		# The OLDEST goes. On a leaderboard the newest results are the ones somebody
		# is waiting to see, and a queue that dropped the newest would report a
		# backlog nobody remembers while discarding the record just set.
		_queue.pop_front()
		dropped += 1

		if dropped == 1 or dropped % 100 == 0:
			DotLog.warn(CHANNEL, "the report queue is full; dropping oldest", {
				"dropped": dropped, "limit": queue_limit
			})


func queued() -> int:
	return _queue.size()


## Sends up to [member batch_limit] queued entries.
##
## [b]The batch is removed from the queue only after the request succeeds.[/b] Taken
## first and re-queued on failure is the obvious shape and is wrong under a second
## flush arriving while the first is in flight — the re-queue puts them back behind
## entries that are newer, and the ordering the backbone sees stops being the ordering
## they happened in.
func flush() -> DotResult:
	if _queue.is_empty():
		return DotResult.success(0)

	if not is_available():
		return DotResult.fail(
			DotError.CODE_STATE,
			"No backbone client; leaderboard reporting is off.",
			"assign DotLeaderboardReporter.client from dot-auth's DotBackboneClient"
		)

	var count := mini(_queue.size(), batch_limit)
	var batch: Array = []

	for i in range(count):
		batch.append(_queue[i])

	var result: Variant = await client.call(
		"post_integration", SUBMIT_PATH, {"entries": batch}
	)

	if not (result is DotResult):
		failures += 1
		last_error = "the backbone client returned something unexpected"
		return DotResult.fail(DotError.CODE_INTERNAL, last_error, str(result))

	var typed: DotResult = result

	if not typed.ok:
		failures += 1
		last_error = typed.error.message

		# A 403 will not fix itself, so say which scope is missing rather than
		# retrying it every thirty seconds for ever.
		if typed.error.http_status == 403:
			DotLog.warn(
				CHANNEL,
				"the backbone refused the report; the integration may lack a scope",
				{"need": SCOPE_WRITE}
			)
		else:
			DotLog.debug(CHANNEL, "report failed; keeping the queue", {
				"why": last_error, "queued": _queue.size()
			})

		return typed

	for _i in range(count):
		_queue.pop_front()

	sent += count
	last_error = ""

	return DotResult.success(count)


## Sends every queued entry, a batch at a time.
##
## Bounded by the queue's own limit so it cannot spin: each successful pass removes at
## least one entry, and a failed one stops.
func flush_all() -> DotResult:
	var total := 0

	while not _queue.is_empty():
		var flushed := await flush()

		if not flushed.ok:
			return flushed

		total += int(flushed.value)

	return DotResult.success(total)


## Declares a board to the backbone, so a site can render it before anybody has
## scored.
##
## [b]Separate from submitting, and worth the extra call.[/b] A board's name,
## ordering and units are editorial and change without any entry changing; deriving
## them from the first submission means a site cannot show an empty board at all, and
## renaming one means waiting for somebody to play.
func define(board: DotLeaderboardDef) -> DotResult:
	if not is_available():
		return DotResult.fail(
			DotError.CODE_STATE, "No backbone client."
		)

	if not board.publish:
		return DotResult.fail(
			DotError.CODE_FORBIDDEN,
			"That board is not published.",
			String(board.id)
		)

	var result: Variant = await client.call(
		"post_integration", DEFINE_PATH, {"boards": [wire_definition(board)]}
	)

	return result if result is DotResult else DotResult.fail(
		DotError.CODE_INTERNAL,
		"The backbone client returned something unexpected.",
		str(result)
	)


func describe() -> Dictionary:
	return {
		"available": is_available(),
		"queued": _queue.size(),
		"sent": sent,
		"dropped": dropped,
		"failures": failures,
		"last_error": last_error,
	}


## A board as the backbone's `LeaderboardDefineInput` names it: `key`, not `id`,
## and the kind by name. `to_dictionary()` is this addon's own file format and is
## not the wire.
static func wire_definition(board: DotLeaderboardDef) -> Dictionary:
	return {
		"key": String(board.id),
		"scope": board.scope.duplicate(true),
		"name": board.display_name,
		"description": board.description,
		"kind": DotLeaderboardDef.kind_name(board.kind),
		"decimals": board.decimals,
		"unit": board.unit,
		"visible": board.visible,
	}
