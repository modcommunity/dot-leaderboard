@tool
class_name DotLeaderboardManager
extends Node

## The node a game adds: its boards, its store, its statistics, and the reporter.
##
## [codeblock]
## var boards := DotLeaderboardManager.new()
## boards.store = DotLeaderboardStoreMemory.new()
## add_child(boards)
##
## boards.define(DotLeaderboardDef.make(&"fastest", DotLeaderboardDef.Kind.TIME,
##     {"map": "surf_beginner", "track": "0", "style": "normal"}))
##
## await boards.submit(&"fastest", {"map": "surf_beginner", "track": "0",
##     "style": "normal"}, player_id, player_name, run.time())
## [/codeblock]
##
## [b]Boards are defined once and addressed by id plus scope.[/b] A timer has one
## board — "fastest time" — instantiated per map, track and style, and defining
## fourteen thousand of them up front would be absurd. So a definition is a template
## and [method board_for] produces the scoped instance on demand, caching it because
## the key is a string build and this is on the path of every submission.

const CHANNEL := "leaderboard"

## An entry was filed. [param previous] is what the player had before, or null.
signal entry_accepted(
	board: DotLeaderboardDef,
	entry: DotLeaderboardEntry,
	previous: DotLeaderboardEntry
)

## An entry was not filed, and why.
signal entry_refused(board_id: StringName, player_id: StringName, reason: String)

## A player's statistics changed.
signal stats_changed(player_id: StringName, totals: DotStatSet)

@export_group("Reporting")

## Whether accepted entries are queued for the backbone.
##
## Per-board [member DotLeaderboardDef.publish] still decides individually; this is
## the master switch, so a server can be taken off the site's leaderboards without
## editing every board.
@export var report_to_backbone: bool = false

## Seconds between flushes of the report queue. 0 disables the timer.
@export_range(0.0, 600.0, 1.0) var report_interval: float = 30.0

## Where entries live.
var store: DotLeaderboardStore = null

## Sends published entries to the backbone. Assign its client from dot-auth.
var reporter := DotLeaderboardReporter.new()

## Board templates by id.
var _definitions: Dictionary = {}

## Scoped boards by their full key, so the key is built once per scope.
var _scoped: Dictionary = {}

var _report_timer: Timer = null


func _ready() -> void:
	if Engine.is_editor_hint():
		return

	if store == null:
		store = DotLeaderboardStoreMemory.new()

	if report_interval > 0.0:
		_report_timer = Timer.new()
		_report_timer.wait_time = report_interval
		_report_timer.autostart = true
		_report_timer.timeout.connect(_on_report_due)
		add_child(_report_timer)


func _exit_tree() -> void:
	if Engine.is_editor_hint():
		return

	# One last flush on the way out. A server shutting down cleanly holds up to a
	# whole interval of results, and losing the last round of a map because the
	# operator restarted is exactly the case a queue exists to survive.
	if report_to_backbone and reporter.queued() > 0 and reporter.is_available():
		reporter.flush_all()


# --- Boards ----------------------------------------------------------------

## Registers a board template.
func define(board: DotLeaderboardDef) -> DotResult:
	if board == null:
		return DotResult.fail(DotError.CODE_INVALID, "No board to define.")

	var valid := board.validate()

	if not valid.ok:
		return valid

	_definitions[board.id] = board

	return DotResult.success(board)


func definition(id: StringName) -> DotLeaderboardDef:
	var found: Variant = _definitions.get(id)
	return found if found is DotLeaderboardDef else null


## The board for an id and a scope, creating the scoped instance if needed.
##
## Cached by key. The key is a sorted string build, and this is called for every
## submission and every page render.
func board_for(id: StringName, scope: Dictionary = {}) -> DotLeaderboardDef:
	var template := definition(id)

	if template == null:
		return null

	if scope.is_empty():
		return template

	var scoped := template.scoped(scope)
	var key := scoped.key()

	if _scoped.has(key):
		return _scoped[key]

	_scoped[key] = scoped

	return scoped


func definitions() -> Array[DotLeaderboardDef]:
	var out: Array[DotLeaderboardDef] = []

	for id in _definitions:
		out.append(_definitions[id])

	out.sort_custom(func(a: DotLeaderboardDef, b: DotLeaderboardDef) -> bool:
		return String(a.id) < String(b.id)
	)

	return out


# --- Submitting ------------------------------------------------------------

## Files a value on a board.
##
## [b]Only an improvement is written.[/b] The comparison uses the board's own
## ordering, which is why this goes through the manager rather than the store — a
## store has entries and an entry does not carry whether lower is better.
func submit(
	board_id: StringName,
	scope: Dictionary,
	player_id: StringName,
	player_name: String,
	value: float,
	meta: Dictionary = {}
) -> DotResult:
	var board := board_for(board_id, scope)

	if board == null:
		var reason := "No such board."
		entry_refused.emit(board_id, player_id, reason)
		return DotResult.fail(DotError.CODE_IO, reason, String(board_id))

	if not is_finite(value):
		# A NaN sorts unpredictably and, once on a board, cannot be compared out of
		# first place — every `beats` test against it is false, so nothing ever
		# replaces it. Cheap to refuse here; effectively unfixable afterwards.
		var reason := "That value is not a finite number."
		entry_refused.emit(board_id, player_id, reason)
		return DotResult.fail(DotError.CODE_INVALID, reason, str(value))

	var existing := store.entry_for(board, player_id)

	if not existing.ok:
		return existing

	var previous: DotLeaderboardEntry = (
		existing.value if existing.value is DotLeaderboardEntry else null
	)

	if previous != null and not board.beats(value, previous.value):
		# Not an error. Most results are worse than the player's own best, and
		# treating that as a failure means every caller has to tell the two apart.
		return DotResult.success(previous)

	var entry := DotLeaderboardEntry.make(
		board.key(), player_id, player_name, value, meta
	)

	var wrote := store.put(entry)

	if not wrote.ok:
		entry_refused.emit(board_id, player_id, wrote.error.message)
		return wrote

	# The store holds entries and does not know the ordering, so the manager — which
	# does — asks it to re-sort and re-rank. A store that does its own ordering
	# overrides this by ignoring the call.
	if store.has_method("sort_board"):
		store.call("sort_board", board)

	if report_to_backbone:
		reporter.queue_entry(board, entry)

	entry_accepted.emit(board, entry, previous)

	return DotResult.success(entry)


## A page of a board.
func page(
	board_id: StringName,
	scope: Dictionary = {},
	offset: int = 0,
	limit: int = 0
) -> DotResult:
	var board := board_for(board_id, scope)

	if board == null:
		return DotResult.fail(
			DotError.CODE_IO, "No such board.", String(board_id)
		)

	return store.page(
		board, offset, limit if limit > 0 else board.page_size
	)


## A player's entry on a board, or a success carrying null.
func entry_for(
	board_id: StringName, scope: Dictionary, player_id: StringName
) -> DotResult:
	var board := board_for(board_id, scope)

	if board == null:
		return DotResult.fail(
			DotError.CODE_IO, "No such board.", String(board_id)
		)

	return store.entry_for(board, player_id)


# --- Statistics ------------------------------------------------------------

## Adds counters to a player's totals.
func add_stats(player_id: StringName, stats: DotStatSet) -> DotResult:
	var added := store.add_stats(player_id, stats)

	if added.ok and added.value is DotStatSet:
		stats_changed.emit(player_id, added.value)

	return added


func stats_for(player_id: StringName) -> DotResult:
	return store.stats_for(player_id)


## Files a player's counter onto a board — "most kills", "furthest travelled".
##
## The bridge between the two halves: a stat set is many numbers accumulated, a board
## is one number ordered, and this is how one becomes the other. Reads the total from
## the store rather than taking a value, so a board built this way always agrees with
## the counter it is derived from.
func publish_stat(
	board_id: StringName,
	scope: Dictionary,
	player_id: StringName,
	player_name: String,
	stat_id: StringName
) -> DotResult:
	var totals := store.stats_for(player_id)

	if not totals.ok:
		return totals

	var set: DotStatSet = totals.value

	if not set.has(stat_id):
		return DotResult.success(null)

	return await submit(
		board_id, scope, player_id, player_name, set.get_value(stat_id)
	)


# --- Reporting -------------------------------------------------------------

func _on_report_due() -> void:
	if not report_to_backbone or reporter.queued() == 0:
		return

	if not reporter.is_available():
		return

	var flushed := await reporter.flush()

	if not flushed.ok:
		DotLog.debug(CHANNEL, "a leaderboard report failed", {
			"why": flushed.error.message, "queued": reporter.queued()
		})


func describe() -> Dictionary:
	return {
		"boards": _definitions.size(),
		"scoped": _scoped.size(),
		"store": store.describe() if store != null else "none",
		"reporting": report_to_backbone,
		"reporter": reporter.describe(),
	}


func describe_lines() -> PackedStringArray:
	var out := PackedStringArray()

	out.append("boards       %d defined, %d scoped" % [
		_definitions.size(), _scoped.size()
	])
	out.append("reporting    %s" % report_to_backbone)
	out.append("queued       %d" % reporter.queued())

	for board in definitions():
		out.append("  %-20s %s" % [
			String(board.id), DotLeaderboardDef.Kind.keys()[board.kind]
		])

	return out
