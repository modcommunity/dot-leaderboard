extends Node

## The helpers and the SQL-store section of leaderboard_selftest.gd, split out for size.

var _passed := 0
var _failed := 0
var _failures := PackedStringArray()
var _entered := 0
var _completed := 0


func _section(title: String) -> void:
	_entered += 1
	print(title)


## A section reached its last line. See SECTIONS in leaderboard_selftest.gd.
func _done() -> void:
	_completed += 1


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


## The SQL store against a driver that records what it is asked.
##
## What a store gets wrong is which statements it sends, in what order, with which values
## bound where, and how it maps rows back — none of which needs a database.
## examples/leaderboard_sql_live.tscn runs the same store against real SQLite, Postgres and
## MariaDB through dot-sql's gateway, which is what says the SQL is valid.
func _test_sql_store() -> void:
	_section("the SQL store, against a driver that records what it is asked")

	var entries_spec := DotLeaderboardSqlSchema.entries_spec()
	var stats_spec := DotLeaderboardSqlSchema.stats_spec()
	_check(
		DotSqlSchema.validate(entries_spec).ok and DotSqlSchema.validate(stats_spec).ok,
		"both table specs are valid: safe names, no reserved words, indexable key columns"
	)

	var driver := DotSqlDriverRecording.new(DotSqlDialect.Kind.POSTGRES)
	driver.answers = {"SELECT version FROM": []}
	var store := DotLeaderboardStoreSql.new(driver)

	var closed: DotResult = await store.page(DotLeaderboardDef.make(&"fastest", DotLeaderboardDef.Kind.TIME))
	_check(
		not closed.ok and closed.code() == DotError.CODE_STATE,
		"a store that was never opened says so rather than querying nothing"
	)

	var opened: DotResult = await store.open()
	_check(opened.ok, "the store opens and creates its schema", str(opened.error))
	_check(
		driver.matching("CREATE TABLE IF NOT EXISTS dot_leaderboard_entries").size() == 1
			and driver.matching("CREATE TABLE IF NOT EXISTS dot_leaderboard_stats").size() == 1,
		"both tables are created"
	)
	_check(
		driver.matching("CREATE INDEX IF NOT EXISTS dot_leaderboard_entries_order_idx").size() == 1,
		"with the (board_key, score) index a page and a rank both read"
	)
	var recorded := driver.matching("INSERT INTO dot_sql_migrations")
	_check(
		recorded.size() == 1 and (recorded[0]["params"] as Array)[0] == "dot_leaderboard:dot_leaderboard_entries",
		"and its schema version recorded under its own component"
	)

	# Writing. The previous entry is read first because put() returns it.
	var board := DotLeaderboardDef.make(&"fastest", DotLeaderboardDef.Kind.TIME, {"map": "surf_a"})
	var entry := DotLeaderboardEntry.make(board.key(), &"p1", "O'Brien; DROP", 12.5, {"replay": "r1"})
	entry.set_at = 1700000000
	driver.clear()
	driver.answers = {
		"SELECT board_key, player_id": [{
			"board_key": board.key(), "player_id": "p1", "player_name": "Old",
			"score": "14.25", "set_at": 1600000000.0, "meta": "",
		}],
	}
	var put: DotResult = await store.put(entry)
	_check(
		put.ok and put.value is DotLeaderboardEntry and (put.value as DotLeaderboardEntry).value == 14.25,
		"a write returns the previous entry, mapped from its row (a score that came back as text)"
	)
	_check(
		driver.statements.size() == 2
			and str(driver.statements[0]["sql"]).begins_with("SELECT")
			and str(driver.statements[1]["sql"]).begins_with("INSERT INTO dot_leaderboard_entries"),
		"read the previous entry, then write: two statements, in that order"
	)
	if driver.statements.size() == 2:
		var write: Dictionary = driver.statements[1]
		var params: Array = write["params"]
		_check(
			params == [board.key(), "p1", "O'Brien; DROP", 12.5, 1700000000, JSON.stringify({"replay": "r1"})],
			"bound in column order: board, player, name, score, set_at, meta",
			str(params)
		)
		_check(
			not str(write["sql"]).contains("O'Brien"),
			"the name is bound, never interpolated"
		)
		_check(
			str(write["sql"]).contains("ON CONFLICT (board_key, player_id) DO UPDATE"),
			"and the write is an upsert on (board, player)",
			"a retry after a timeout must not file a player twice on one board"
		)
	else:
		for _i in range(3):
			_check(false, "the write statement was not recorded")

	# Reading a page: the direction and the comparison come from the board's kind.
	driver.clear()
	driver.rows = [
		{"board_key": board.key(), "player_id": "p2", "player_name": "Ann", "score": 10.0, "set_at": 5.0, "meta": "{\"replay\":\"r2\"}", "place": 1.0},
		{"board_key": board.key(), "player_id": "p1", "player_name": null, "score": 12.5, "set_at": 6.0, "meta": "", "place": 2},
		{"board_key": board.key(), "player_id": "p3", "player_name": "Cy", "score": 12.5, "set_at": 7.0, "meta": "", "place": 2},
	]
	var page: DotResult = await store.page(board, 5, 3)
	var sql := str(driver.statements[0]["sql"]) if driver.statements.size() == 1 else ""
	_check(
		sql.contains("ORDER BY e.score ASC") and sql.contains("b.score < e.score"),
		"a time board reads lowest first and counts the lower scores as ahead"
	)
	_check(
		driver.statements.size() == 1 and (driver.statements[0]["params"] as Array) == [board.key(), 3, 5],
		"bound as board, LIMIT, OFFSET — in that order, which is the order the SQL names them",
		str(driver.statements[0]["params"]) if driver.statements.size() == 1 else ""
	)
	var rows: Array = page.value if page.ok else []
	_check(
		rows.size() == 3 and (rows[0] as DotLeaderboardEntry).rank == 1 and (rows[0] as DotLeaderboardEntry).meta.get("replay", "") == "r2",
		"rows map back with their rank and their meta"
	)
	_check(
		rows.size() == 3 and (rows[1] as DotLeaderboardEntry).rank == 2 and (rows[2] as DotLeaderboardEntry).rank == 2
			and (rows[1] as DotLeaderboardEntry).player_name == "",
		"a tie comes back sharing its rank, and a NULL name as empty rather than \"<null>\""
	)

	var score_board := DotLeaderboardDef.make(&"kills", DotLeaderboardDef.Kind.SCORE)
	driver.clear()
	driver.rows = []
	await store.page(score_board)
	var score_sql := str(driver.statements[0]["sql"]) if driver.statements.size() == 1 else ""
	_check(
		score_sql.contains("ORDER BY e.score DESC") and score_sql.contains("b.score > e.score"),
		"a score board reads highest first and counts the higher scores as ahead"
	)

	driver.clear()
	var absent: DotResult = await store.entry_for(board, &"nobody")
	_check(
		absent.ok and absent.value == null and (driver.statements[0]["params"] as Array) == [board.key(), "nobody"],
		"an absent player is a success carrying null, looked up by board and player"
	)

	driver.answers = {"COUNT(*) AS entries": [{"entries": 42.0}]}
	var counted: DotResult = await store.count_on(board)
	_check(counted.ok and counted.value is int and counted.value == 42, "a count comes back an int, whatever JSON made of it")

	# Counters: additive in the database, in the driver's own dialect.
	driver.clear()
	driver.answers = {"SELECT stat_id, amount": [{"stat_id": "kills", "amount": 7.0}, {"stat_id": "metres", "amount": "120.5"}]}
	var set := DotStatSet.new()
	set.add(&"kills", 3.0)
	set.add(&"metres", 20.5)
	var totals: DotResult = await store.add_stats(&"p1", set)
	var adds := driver.matching("INSERT INTO dot_leaderboard_stats")
	_check(
		adds.size() == 2 and str(adds[0]["sql"]).contains("amount = dot_leaderboard_stats.amount + excluded.amount"),
		"a counter is added by the database, one statement each, not read and rewritten here"
	)
	_check(
		totals.ok and (totals.value as DotStatSet).get_value(&"kills") == 7.0 and (totals.value as DotStatSet).get_value(&"metres") == 120.5,
		"and the totals come back read from the table"
	)

	var mysql := DotSqlDriverRecording.new(DotSqlDialect.Kind.MYSQL)
	mysql.answers = {"SELECT version FROM": []}
	var mysql_store := DotLeaderboardStoreSql.new(mysql)
	await mysql_store.open()
	mysql.clear()
	await mysql_store.add_stats(&"p1", set)
	var mysql_adds := mysql.matching("INSERT INTO dot_leaderboard_stats")
	_check(
		mysql_adds.size() == 2 and str(mysql_adds[0]["sql"]).contains("ON DUPLICATE KEY UPDATE amount = amount + VALUES(amount)"),
		"and spelled MySQL's way on MySQL, which has no ON CONFLICT"
	)

	driver.clear()
	var nan_entry := DotLeaderboardEntry.make(board.key(), &"p9", "N", NAN)
	var nan_put: DotResult = await store.put(nan_entry)
	_check(
		not nan_put.ok and driver.statements.is_empty(),
		"a NaN is refused before any statement: JSON cannot carry one and MySQL refuses it"
	)

	# Failures are failures.
	driver.clear()
	driver.fail_next = "connection reset"
	var failed_page: DotResult = await store.page(board)
	_check(not failed_page.ok, "a read failure is reported rather than read as an empty board")

	# The read before a write succeeds and the write fails. fail_next would fail the read
	# instead, so a driver that fails one statement by its text.
	var flaky := FailSecond.new(DotSqlDialect.Kind.POSTGRES)
	flaky.answers = {"SELECT version FROM": []}
	var flaky_store := DotLeaderboardStoreSql.new(flaky)
	await flaky_store.open()
	flaky.fail_on = "INSERT INTO dot_leaderboard_entries"
	var failed_put: DotResult = await flaky_store.put(entry)
	_check(not failed_put.ok, "a write failure is reported, not swallowed")

	var newer := DotSqlDriverRecording.new(DotSqlDialect.Kind.SQLITE)
	newer.answers = {"SELECT version FROM": [{"version": 99}]}
	var refused: DotResult = await DotLeaderboardStoreSql.new(newer).open()
	_check(
		not refused.ok and newer.matching("CREATE TABLE IF NOT EXISTS dot_leaderboard_entries").is_empty(),
		"a database from a newer build is refused, and nothing is created in it"
	)

	# Through the manager. The synchronous form refuses a store that suspends, in words.
	var manager := DotLeaderboardManager.new()
	manager.store = store
	manager.report_interval = 0.0
	add_child(manager)
	manager.define(DotLeaderboardDef.make(&"fastest", DotLeaderboardDef.Kind.TIME))

	var sync_try := manager.submit(&"fastest", {"map": "surf_a"}, &"p1", "P", 9.0)
	_check(
		not sync_try.ok and sync_try.code() == DotError.CODE_UNSUPPORTED and sync_try.error.message.contains("submit_async"),
		"the synchronous submit refuses an asynchronous store and names the form that works",
		str(sync_try.error)
	)

	driver.clear()
	driver.answers = {
		"AS place": [{"board_key": board.key(), "player_id": "p1", "player_name": "P", "score": 12.5, "set_at": 1.0, "meta": "", "place": 3.0}],
		"SELECT board_key, player_id": [],
	}
	var filed: DotResult = await manager.submit_async(&"fastest", {"map": "surf_a"}, &"p1", "P", 9.0)
	_check(
		filed.ok and filed.value is DotLeaderboardEntry and (filed.value as DotLeaderboardEntry).value == 9.0
			and driver.matching("INSERT INTO dot_leaderboard_entries").size() == 1,
		"submit_async files an improvement through the SQL store",
		str(filed.error)
	)
	_check(
		filed.ok and (filed.value as DotLeaderboardEntry).rank == 3,
		"and hands back the entry ranked by a query, as the memory store's re-sort would"
	)

	driver.clear()
	var worse: DotResult = await manager.submit_async(&"fastest", {"map": "surf_a"}, &"p1", "P", 20.0)
	_check(
		worse.ok and driver.matching("INSERT INTO").is_empty(),
		"and writes nothing for a result that did not beat the player's own"
	)

	manager.queue_free()
	_done()


## A recording driver that fails every statement containing [member fail_on].
class FailSecond extends DotSqlDriverRecording:
	var fail_on: String = ""

	func _init(p_dialect: int = DotSqlDialect.Kind.SQLITE) -> void:
		super(p_dialect)

	func _execute(sql: String, params: Array) -> DotResult:
		if fail_on != "" and sql.contains(fail_on):
			statements.append({"sql": sql, "params": params.duplicate()})
			return DotResult.fail(DotError.CODE_IO, "disk full")
		return await super(sql, params)
