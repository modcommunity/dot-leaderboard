extends Node

## The SQL store against a real database, through dot-sql's gateway.
##
## The self-test proves which statements the store sends; this proves a database accepts
## them and answers what the store expects — the ordering, the tie ranks, the additive
## counters — in all three dialects. Run by dot-sql's runner, which starts a gateway per
## dialect and sets DOT_SQL_URL, DOT_SQL_DIALECT and DOT_SQL_TOKEN_FILE:
##
## [codeblock]
## ../dot-sql/tools/test_live.sh . res://examples/leaderboard_sql_live.tscn
## [/codeblock]

const CHECKS := 17

const ENTRIES := "dot_lb_live_entries"
const STATS := "dot_lb_live_stats"

var _passed := 0
var _failed := 0


func _ready() -> void:
	DotLog.set_level(DotLog.Level.ERROR)

	var dialect := DotSqlDialect.from_name(OS.get_environment("DOT_SQL_DIALECT"))
	var made := DotSql.from_config({
		"driver": "gateway",
		"url": OS.get_environment("DOT_SQL_URL"),
		"dialect": DotSqlDialect.name_of(dialect),
		"token": FileAccess.get_file_as_string(OS.get_environment("DOT_SQL_TOKEN_FILE")).strip_edges(),
	}, self)
	if not made.ok or made.value == null:
		print("set DOT_SQL_URL, DOT_SQL_DIALECT and DOT_SQL_TOKEN_FILE; see dot-sql/tools/test_live.sh")
		get_tree().quit(2)
		return

	var driver: DotSqlDriverGateway = made.value
	print("dot-leaderboard live: %s" % DotSqlDialect.name_of(dialect))

	# Clean tables every run.
	await driver.open()
	await driver.execute("DROP TABLE IF EXISTS %s" % ENTRIES)
	await driver.execute("DROP TABLE IF EXISTS %s" % STATS)
	await driver.execute("DELETE FROM dot_sql_migrations WHERE component = ?", ["dot_leaderboard:%s" % ENTRIES])

	var store := DotLeaderboardStoreSql.new(driver)
	store.entries_table = ENTRIES
	store.stats_table = STATS

	var opened: DotResult = await store.open()
	_check("the store creates its tables", opened.ok, opened)

	var board := DotLeaderboardDef.make(&"fastest", DotLeaderboardDef.Kind.TIME, {"map": "surf_live", "track": "0"})
	var key := board.key()

	var first: DotResult = await store.put(_entry(key, &"p1", "Ann", 11.0))
	_check("a first entry has no previous", first.ok and first.value == null, first)

	var again: DotResult = await store.put(_entry(key, &"p1", "Ann", 10.0))
	_check(
		"writing it again updates and returns the previous",
		again.ok and again.value is DotLeaderboardEntry and (again.value as DotLeaderboardEntry).value == 11.0,
		again
	)

	var quoted := _entry(key, &"p2", "O'Brien 🙃; --", 61.123, {"replay": "r'2", "splits": [1.5, 2.5]})
	await store.put(quoted)
	await store.put(_entry(key, &"p3", "Cy", 61.123))
	await store.put(_entry(key, &"p4", "Di", 75.0))

	var page: DotResult = await store.page(board)
	var rows: Array = page.value if page.ok else []
	_check(
		"a time board comes back lowest first, a tie sharing its rank (1, 2, 2, 4)",
		_shape(rows) == "p1=1 p2=2 p3=2 p4=4",
		page, _shape(rows)
	)

	var second: DotResult = await store.page(board, 2, 2)
	_check(
		"a later page keeps the ranks of the whole board",
		_shape(second.value if second.ok else []) == "p3=2 p4=4",
		second, _shape(second.value if second.ok else [])
	)

	var p2: DotLeaderboardEntry = rows[1] if rows.size() > 1 else null
	_check(
		"a name with a quote and an emoji, its meta and its thousandths all come back",
		p2 != null and p2.player_name == "O'Brien 🙃; --" and p2.value == 61.123
			and str(p2.meta.get("replay", "")) == "r'2" and p2.set_at == 1700000000
	)

	var mine: DotResult = await store.entry_for(board, &"p4")
	_check(
		"one player's entry carries their rank",
		mine.ok and mine.value is DotLeaderboardEntry and (mine.value as DotLeaderboardEntry).rank == 4,
		mine
	)

	var absent: DotResult = await store.entry_for(board, &"nobody")
	_check("an absent player is a success carrying null", absent.ok and absent.value == null, absent)

	var counted: DotResult = await store.count_on(board)
	_check("the board counts four", counted.ok and counted.value == 4, counted)

	var other := DotLeaderboardDef.make(&"fastest", DotLeaderboardDef.Kind.TIME, {"map": "elsewhere", "track": "0"})
	var elsewhere: DotResult = await store.count_on(other)
	_check("another scope is another board", elsewhere.ok and elsewhere.value == 0, elsewhere)

	var kills := DotLeaderboardDef.make(&"kills", DotLeaderboardDef.Kind.SCORE)
	await store.put(_entry(kills.key(), &"p1", "Ann", 5.0))
	await store.put(_entry(kills.key(), &"p2", "Bo", 9.0))
	await store.put(_entry(kills.key(), &"p3", "Cy", 5.0))
	var scores: DotResult = await store.page(kills)
	_check(
		"a score board comes back highest first (1, 2, 2)",
		_shape(scores.value if scores.ok else []) == "p2=1 p1=2 p3=2",
		scores, _shape(scores.value if scores.ok else [])
	)

	var removed: DotResult = await store.remove(board, &"p4")
	var after: DotResult = await store.count_on(board)
	_check("a removal removes", removed.ok and removed.value == true and after.ok and after.value == 3, removed)

	var round_one := DotStatSet.new()
	round_one.add(&"kills", 3.0)
	round_one.add(&"metres", 1.5)
	await store.add_stats(&"p1", round_one)
	var round_two := DotStatSet.new()
	round_two.add(&"kills", 4.0)
	round_two.add(&"metres", 2.25)
	var totals: DotResult = await store.add_stats(&"p1", round_two)
	var set: DotStatSet = totals.value if totals.ok else DotStatSet.new()
	_check(
		"counters add in the database: 3 + 4 kills, 1.5 + 2.25 metres",
		set.get_value(&"kills") == 7.0 and set.get_value(&"metres") == 3.75,
		totals, str(set.to_dictionary())
	)

	var nobody: DotResult = await store.stats_for(&"nobody")
	_check("a player with no counters reads as an empty set", nobody.ok and (nobody.value as DotStatSet).size() == 0, nobody)

	# Through the manager, the way a game uses it.
	var manager := DotLeaderboardManager.new()
	manager.store = store
	manager.report_interval = 0.0
	add_child(manager)
	manager.define(DotLeaderboardDef.make(&"fastest", DotLeaderboardDef.Kind.TIME))
	var scope := {"map": "surf_live", "track": "0"}
	var filed: DotResult = await manager.submit_async(&"fastest", scope, &"p3", "Cy", 9.5)
	_check(
		"the manager files an improvement and hands it back ranked first",
		filed.ok and filed.value is DotLeaderboardEntry and (filed.value as DotLeaderboardEntry).rank == 1,
		filed
	)
	var worse: DotResult = await manager.submit_async(&"fastest", scope, &"p3", "Cy", 99.0)
	var still: DotResult = await store.entry_for(board, &"p3")
	_check(
		"and leaves a worse one off the table",
		worse.ok and still.ok and (still.value as DotLeaderboardEntry).value == 9.5,
		worse
	)

	var reopened := DotLeaderboardStoreSql.new(driver)
	reopened.entries_table = ENTRIES
	reopened.stats_table = STATS
	var reopen: DotResult = await reopened.open()
	_check("opening existing tables again is harmless", reopen.ok, reopen)

	print("%d passed, %d failed" % [_passed, _failed])
	await driver.execute("DROP TABLE IF EXISTS %s" % ENTRIES)
	await driver.execute("DROP TABLE IF EXISTS %s" % STATS)
	await driver.execute("DELETE FROM dot_sql_migrations WHERE component = ?", ["dot_leaderboard:%s" % ENTRIES])
	manager.queue_free()
	get_tree().quit(1 if _failed > 0 or _passed + _failed != CHECKS else 0)


func _entry(key: String, player: StringName, name: String, value: float, meta: Dictionary = {}) -> DotLeaderboardEntry:
	var entry := DotLeaderboardEntry.make(key, player, name, value, meta)
	entry.set_at = 1700000000
	return entry


func _shape(rows: Array) -> String:
	var parts := PackedStringArray()
	for row in rows:
		parts.append("%s=%d" % [String((row as DotLeaderboardEntry).player_id), (row as DotLeaderboardEntry).rank])
	return " ".join(parts)


func _check(what: String, passed: bool, res: DotResult = null, detail: String = "") -> void:
	if passed:
		_passed += 1
		print("  %-60s ok" % what)
		return
	_failed += 1
	var why := ""
	if res != null and not res.ok and res.error != null:
		why = " — %s (%s)" % [res.error.message, res.error.detail]
	elif detail != "":
		why = " — %s" % detail
	print("  %-60s FAILED%s" % [what, why])
