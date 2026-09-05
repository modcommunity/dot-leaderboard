extends Node

## Proves the boards, the statistics and the reporter do what a site depends on.
##
## [codeblock]
## godot --headless --path . res://examples/leaderboard_selftest.tscn
## [/codeblock]
##
## [b]Two tests here are the ones that matter.[/b] `_test_scope_key_is_canonical`
## checks that two callers who built the same scope in different orders address the
## same board — without it a leaderboard silently splits in half and nothing errors.
## `_test_reporter_keeps_its_queue` checks that a backbone outage costs latency rather
## than results.

var _passed := 0
var _failed := 0
var _failures := PackedStringArray()


func _ready() -> void:
	DotLog.set_level(DotLog.Level.ERROR)
	_run.call_deferred()


func _run() -> void:
	print("dot-leaderboard self-test")
	print("")

	_test_definitions()
	_test_scope_key_is_canonical()
	_test_ordering()
	_test_formatting()
	await _test_submitting()
	await _test_ranks()
	await _test_refusals()
	await _test_stats()
	await _test_publish_stat()
	await _test_reporter_keeps_its_queue()
	await _test_reporter_bounds_its_queue()
	await _test_publish_is_opt_in()

	print("")
	print("%d passed, %d failed" % [_passed, _failed])

	for line in _failures:
		print("  FAIL  %s" % line)

	get_tree().quit(1 if _failed > 0 else 0)


func _check(ok: bool, what: String, detail: String = "") -> void:
	if ok:
		_passed += 1
		print("  ok    %s" % what)
	else:
		_failed += 1
		var line := what if detail == "" else "%s (%s)" % [what, detail]
		_failures.append(line)
		print("  FAIL  %s" % line)


func _manager() -> DotLeaderboardManager:
	var manager := DotLeaderboardManager.new()
	manager.store = DotLeaderboardStoreMemory.new()
	manager.report_interval = 0.0
	add_child(manager)
	return manager


# --- Definitions -----------------------------------------------------------

func _test_definitions() -> void:
	print("board definitions")

	var board := DotLeaderboardDef.make(
		&"fastest", DotLeaderboardDef.Kind.TIME, {"map": "surf_beginner"}
	)

	_check(board.validate().ok, "a board validates")
	_check(board.lower_is_better(), "a time board is lower-is-better")
	_check(board.decimals == 3, "and defaults to three decimals")

	var score := DotLeaderboardDef.make(&"kills", DotLeaderboardDef.Kind.SCORE)
	_check(not score.lower_is_better(), "a score board is higher-is-better")
	_check(score.decimals == 0, "and to none")

	var penalty := DotLeaderboardDef.make(&"deaths", DotLeaderboardDef.Kind.PENALTY)
	_check(penalty.lower_is_better(), "a penalty board is lower-is-better")

	var nameless := DotLeaderboardDef.new()
	_check(not nameless.validate().ok, "a board with no id is refused")

	# The round trip, and the enum guard against a hostile value.
	var back := DotLeaderboardDef.from_dictionary(board.to_dictionary())
	_check(back.key() == board.key(), "a board round-trips through a dictionary")

	var junk := DotLeaderboardDef.from_dictionary({"id": "x", "kind": 99})
	_check(
		junk.kind == DotLeaderboardDef.Kind.SCORE,
		"an out-of-range kind falls back rather than becoming a number nothing handles"
	)

	# Scoping copies, so one definition can serve fourteen thousand boards.
	var scoped := board.scoped({"track": 0, "style": "normal"})
	_check(scoped.scope.size() == 3, "scoping adds to the scope")
	_check(board.scope.size() == 1, "and does not touch the template")
	_check(
		str(scoped.scope["track"]) == "0",
		"and stringifies, so an int and a string address one board"
	)


func _test_scope_key_is_canonical() -> void:
	print("scope keys are canonical")

	# The bug this prevents: GDScript iterates a dictionary in insertion order, so
	# two callers building the same scope in different orders would address two
	# boards holding half the entries each — and nothing anywhere would error.
	var a := DotLeaderboardDef.make(&"fastest", DotLeaderboardDef.Kind.TIME, {
		"map": "surf_beginner", "track": "0", "style": "normal",
	})
	var b := DotLeaderboardDef.make(&"fastest", DotLeaderboardDef.Kind.TIME, {
		"style": "normal", "map": "surf_beginner", "track": "0",
	})

	_check(a.key() == b.key(), "two orderings of one scope give one key",
		"%s vs %s" % [a.key(), b.key()])

	var different := DotLeaderboardDef.make(&"fastest", DotLeaderboardDef.Kind.TIME, {
		"map": "surf_beginner", "track": "1", "style": "normal",
	})

	_check(a.key() != different.key(), "and a different scope a different one")

	var unscoped := DotLeaderboardDef.make(&"kills", DotLeaderboardDef.Kind.SCORE)
	_check(unscoped.key() == "kills", "an unscoped board is just its id")


func _test_ordering() -> void:
	print("ordering")

	var time := DotLeaderboardDef.make(&"t", DotLeaderboardDef.Kind.TIME)
	_check(time.beats(9.0, 10.0), "a faster time beats a slower one")
	_check(not time.beats(10.0, 9.0), "and not the other way")
	_check(not time.beats(9.0, 9.0), "and a tie is not an improvement")

	var score := DotLeaderboardDef.make(&"s", DotLeaderboardDef.Kind.SCORE)
	_check(score.beats(10.0, 9.0), "a higher score beats a lower one")
	_check(not score.beats(9.0, 10.0), "and not the other way")


func _test_formatting() -> void:
	print("formatting")

	var time := DotLeaderboardDef.make(&"t", DotLeaderboardDef.Kind.TIME)
	_check(time.format_value(83.456) == "1:23.456", "a time renders as a time")
	_check(time.format_value(3723.5) == "1:02:03.500", "and past an hour")

	var speed := DotLeaderboardDef.make(&"s", DotLeaderboardDef.Kind.POINTS)
	speed.decimals = 1
	speed.unit = "m/s"
	_check(speed.format_value(12.34) == "12.3 m/s", "and a value renders with its unit")


# --- Submitting ------------------------------------------------------------

func _test_submitting() -> void:
	print("submitting")

	var manager := _manager()
	manager.define(DotLeaderboardDef.make(&"fastest", DotLeaderboardDef.Kind.TIME))

	var scope := {"map": "surf_beginner"}

	var first: DotResult = await manager.submit(
		&"fastest", scope, &"alice", "Alice", 30.0
	)
	_check(first.ok, "a first entry is accepted")

	var slower: DotResult = await manager.submit(
		&"fastest", scope, &"alice", "Alice", 35.0
	)
	_check(slower.ok, "a worse one is not an error")
	_check(
		slower.value is DotLeaderboardEntry
			and (slower.value as DotLeaderboardEntry).value == 30.0,
		"and reports the entry it did not beat"
	)

	var page: DotResult = await manager.page(&"fastest", scope)
	_check((page.value as Array).size() == 1, "the board still has one row")

	await manager.submit(&"fastest", scope, &"alice", "Alice", 25.0)
	page = await manager.page(&"fastest", scope)
	_check(
		(page.value[0] as DotLeaderboardEntry).value == 25.0,
		"and a better one replaces it"
	)

	# Scopes are separate boards.
	await manager.submit(&"fastest", {"map": "surf_other"}, &"alice", "Alice", 99.0)
	page = await manager.page(&"fastest", scope)
	_check(
		(page.value as Array).size() == 1,
		"an entry on another scope stays off this board"
	)

	manager.queue_free()


func _test_ranks() -> void:
	print("ranks")

	var manager := _manager()
	manager.define(DotLeaderboardDef.make(&"fastest", DotLeaderboardDef.Kind.TIME))
	manager.define(DotLeaderboardDef.make(&"kills", DotLeaderboardDef.Kind.SCORE))

	for row in [[&"alice", 30.0], [&"bob", 20.0], [&"carol", 40.0]]:
		await manager.submit(&"fastest", {}, row[0], String(row[0]), row[1])

	var page: DotResult = await manager.page(&"fastest", {})
	var rows: Array = page.value

	_check(rows.size() == 3, "three entries")
	_check(
		(rows[0] as DotLeaderboardEntry).player_id == &"bob",
		"sorted fastest first",
		str(rows.map(func(e): return String(e.player_id)))
	)
	_check((rows[0] as DotLeaderboardEntry).rank == 1, "with ranks written")
	_check((rows[2] as DotLeaderboardEntry).rank == 3, "all the way down")

	# A score board sorts the other way, which is the whole reason the manager does
	# the sorting rather than the store.
	for row in [[&"alice", 30.0], [&"bob", 20.0], [&"carol", 40.0]]:
		await manager.submit(&"kills", {}, row[0], String(row[0]), row[1])

	var scores: DotResult = await manager.page(&"kills", {})
	_check(
		((scores.value as Array)[0] as DotLeaderboardEntry).player_id == &"carol",
		"and a score board sorts highest first"
	)

	var mine: DotResult = await manager.entry_for(&"fastest", {}, &"carol")
	_check(
		mine.value is DotLeaderboardEntry
			and (mine.value as DotLeaderboardEntry).rank == 3,
		"a player's own entry carries their rank"
	)

	var absent: DotResult = await manager.entry_for(&"fastest", {}, &"nobody")
	_check(
		absent.ok and absent.value == null,
		"and an absent one is a success carrying null, not a failure"
	)

	manager.queue_free()


func _test_refusals() -> void:
	print("refusals")

	var manager := _manager()
	manager.define(DotLeaderboardDef.make(&"fastest", DotLeaderboardDef.Kind.TIME))

	var refusals := PackedStringArray()
	manager.entry_refused.connect(
		func(_id: StringName, _p: StringName, reason: String) -> void:
			refusals.append(reason)
	)

	var unknown: DotResult = await manager.submit(
		&"nonexistent", {}, &"alice", "Alice", 1.0
	)
	_check(not unknown.ok, "an unknown board is refused")

	# A NaN on a board can never be displaced: every `beats` test against it is
	# false, so nothing ever replaces it. Cheap to refuse; unfixable afterwards.
	var nan_result: DotResult = await manager.submit(
		&"fastest", {}, &"alice", "Alice", NAN
	)
	_check(not nan_result.ok, "and so is a NaN")

	var inf_result: DotResult = await manager.submit(
		&"fastest", {}, &"alice", "Alice", INF
	)
	_check(not inf_result.ok, "and an infinity")

	_check(refusals.size() == 3, "each refusal is announced", str(refusals))

	var page: DotResult = await manager.page(&"fastest", {})
	_check((page.value as Array).is_empty(), "and nothing reached the board")

	manager.queue_free()


# --- Statistics ------------------------------------------------------------

func _test_stats() -> void:
	print("statistics")

	var set := DotStatSet.new()
	set.add(&"kills", 3.0)
	set.add(&"kills")
	set.add(&"distance", 120.5)

	_check(set.get_value(&"kills") == 4.0, "counters accumulate")
	_check(set.get_value(&"nothing") == 0.0, "and an absent one reads as zero")

	set.set_best(&"top_speed", 12.0)
	set.set_best(&"top_speed", 9.0)
	_check(set.get_value(&"top_speed") == 12.0, "a best keeps the higher value")

	set.set_lowest(&"best_time", 30.0)
	set.set_lowest(&"best_time", 25.0)
	_check(set.get_value(&"best_time") == 25.0, "and a lowest the lower one")

	var session := DotStatSet.new()
	session.add(&"kills", 2.0)

	set.add_from(session)
	_check(set.get_value(&"kills") == 6.0, "sets merge additively")

	# Non-numeric values are dropped rather than coerced: float("banana") is 0.0,
	# which silently resets a counter instead of leaving it alone.
	var loaded := DotStatSet.from_dictionary({
		"kills": 5, "distance": 12.5, "name": "alice", "nested": {},
	})
	_check(loaded.size() == 2, "loading drops non-numeric values", "%d" % loaded.size())
	_check(loaded.get_value(&"kills") == 5.0, "and keeps the numbers")

	var manager := _manager()
	var totals: DotResult = await manager.add_stats(&"alice", set)
	_check(totals.ok, "a store accumulates them")

	var again := DotStatSet.new()
	again.add(&"kills", 1.0)
	await manager.add_stats(&"alice", again)

	var read: DotResult = await manager.stats_for(&"alice")
	_check(
		(read.value as DotStatSet).get_value(&"kills") == 7.0,
		"across calls",
		"%.1f" % (read.value as DotStatSet).get_value(&"kills")
	)

	var empty: DotResult = await manager.stats_for(&"nobody")
	_check(
		empty.ok and empty.value is DotStatSet,
		"and a player with none reads as an empty set rather than null"
	)

	manager.queue_free()


func _test_publish_stat() -> void:
	print("a counter becomes a board")

	var manager := _manager()
	manager.define(DotLeaderboardDef.make(&"most_kills", DotLeaderboardDef.Kind.SCORE))

	var alice := DotStatSet.new()
	alice.add(&"kills", 12.0)
	await manager.add_stats(&"alice", alice)

	var bob := DotStatSet.new()
	bob.add(&"kills", 30.0)
	await manager.add_stats(&"bob", bob)

	await manager.publish_stat(&"most_kills", {}, &"alice", "Alice", &"kills")
	await manager.publish_stat(&"most_kills", {}, &"bob", "Bob", &"kills")

	var page: DotResult = await manager.page(&"most_kills", {})
	var rows: Array = page.value

	_check(rows.size() == 2, "both players are on the board")
	_check(
		(rows[0] as DotLeaderboardEntry).player_id == &"bob",
		"highest first"
	)
	_check(
		(rows[0] as DotLeaderboardEntry).value == 30.0,
		"with the counter's own total, not a value passed in"
	)

	var missing: DotResult = await manager.publish_stat(
		&"most_kills", {}, &"carol", "Carol", &"kills"
	)
	_check(
		missing.ok and missing.value == null,
		"a player with no such counter is not an error"
	)

	manager.queue_free()


# --- Reporting -------------------------------------------------------------

## A stand-in for dot-auth's DotBackboneClient, which this addon never names.
class FakeBackbone extends RefCounted:
	var calls: Array[Dictionary] = []
	var fail: bool = false
	var status: int = 500

	func post_integration(path: String, body: Dictionary) -> DotResult:
		calls.append({"path": path, "body": body})

		if fail:
			var error := DotError.make(DotError.CODE_HTTP, "backbone is down")
			error.http_status = status
			return DotResult.failure(error)

		return DotResult.success({"ok": true})


func _test_reporter_keeps_its_queue() -> void:
	print("a backbone outage costs latency, not results")

	var manager := _manager()
	manager.report_to_backbone = true

	var backbone := FakeBackbone.new()
	manager.reporter.client = backbone

	var board := DotLeaderboardDef.make(&"fastest", DotLeaderboardDef.Kind.TIME)
	board.publish = true
	manager.define(board)

	for i in range(5):
		await manager.submit(
			&"fastest", {}, StringName("p%d" % i), "P%d" % i, float(i)
		)

	_check(manager.reporter.queued() == 5, "five entries are queued",
		"%d" % manager.reporter.queued())

	backbone.fail = true
	var failed: DotResult = await manager.reporter.flush()

	_check(not failed.ok, "a flush against a dead backbone fails")
	_check(
		manager.reporter.queued() == 5,
		"and the queue is intact",
		"%d" % manager.reporter.queued()
	)

	backbone.fail = false
	var flushed: DotResult = await manager.reporter.flush()

	_check(flushed.ok and int(flushed.value) == 5, "and a later flush sends them all")
	_check(manager.reporter.queued() == 0, "leaving the queue empty")

	var body: Dictionary = backbone.calls[backbone.calls.size() - 1]["body"]
	_check(
		(body["entries"] as Array).size() == 5,
		"in one request rather than five"
	)
	_check(
		str(backbone.calls[0]["path"]) == DotLeaderboardReporter.SUBMIT_PATH,
		"to the submit endpoint"
	)

	# The backbone's contract, field for field: website-city's
	# LeaderboardSubmitInput. The two ends had never met, and this once sent
	# `set_at` and an integer kind.
	var first: Dictionary = (body["entries"] as Array)[0]
	_check(first.has("setAt") and not first.has("set_at"), "with the timestamp spelled as the contract spells it")
	_check(first["kind"] is String and first["kind"] in ["TIME", "SCORE", "POINTS", "PENALTY"],
		"and the kind by its name", str(first.get("kind")))
	for key in ["board", "player", "name", "value"]:
		_check(first.has(key), "and `%s`" % key)
	var wire := DotLeaderboardReporter.wire_definition(
		DotLeaderboardDef.make(&"fastest", DotLeaderboardDef.Kind.TIME)
	)
	_check(wire.has("key") and not wire.has("id") and wire["kind"] == "TIME", "a definition goes out under `key`, by kind name")
	_check(DotLeaderboardDef.kind_name(DotLeaderboardDef.Kind.PENALTY) == "PENALTY", "every kind has a name")

	manager.queue_free()


func _test_reporter_bounds_its_queue() -> void:
	print("the queue is bounded")

	var reporter := DotLeaderboardReporter.new()
	reporter.queue_limit = 10

	var board := DotLeaderboardDef.make(&"fastest", DotLeaderboardDef.Kind.TIME)
	board.publish = true

	for i in range(40):
		reporter.queue_entry(
			board,
			DotLeaderboardEntry.make("fastest", StringName("p%d" % i), "P", float(i))
		)

	_check(reporter.queued() == 10, "the queue stops at its limit")
	_check(reporter.dropped == 30, "and counts what it dropped", "%d" % reporter.dropped)

	# The OLDEST go. On a leaderboard the newest results are the ones somebody is
	# waiting to see, and dropping those would report a backlog nobody remembers.
	reporter.client = FakeBackbone.new()
	await reporter.flush()

	var calls: Array[Dictionary] = (reporter.client as FakeBackbone).calls
	var entries: Array = calls[0]["body"]["entries"]

	_check(
		float(entries[0]["value"]) == 30.0,
		"and the ones kept are the newest",
		"first is %.0f" % float(entries[0]["value"])
	)


func _test_publish_is_opt_in() -> void:
	print("publishing is per board and opt-in")

	var manager := _manager()
	manager.report_to_backbone = true
	manager.reporter.client = FakeBackbone.new()

	# Publishing sends player names and scores off the server, so a board that has
	# not asked for it is not reported even with the master switch on.
	manager.define(DotLeaderboardDef.make(&"private", DotLeaderboardDef.Kind.TIME))

	await manager.submit(&"private", {}, &"alice", "Alice", 10.0)

	_check(manager.reporter.queued() == 0, "an unpublished board queues nothing")

	var public := DotLeaderboardDef.make(&"public", DotLeaderboardDef.Kind.TIME)
	public.publish = true
	manager.define(public)

	await manager.submit(&"public", {}, &"alice", "Alice", 10.0)

	_check(manager.reporter.queued() == 1, "and a published one does")

	# And the master switch overrides both ways.
	manager.report_to_backbone = false
	await manager.submit(&"public", {}, &"bob", "Bob", 5.0)

	_check(
		manager.reporter.queued() == 1,
		"while the master switch takes the whole server off"
	)

	var defined: DotResult = await manager.reporter.define(
		DotLeaderboardDef.make(&"private", DotLeaderboardDef.Kind.TIME)
	)
	_check(not defined.ok, "and an unpublished board cannot be declared either")

	manager.queue_free()
