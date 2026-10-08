@tool
class_name DotLeaderboardSqlSchema
extends RefCounted

## The two leaderboard tables, their statements and their row mapping, in one place.
##
## [b]The tables are plain data, rendered by dot-sql.[/b] [method entries_spec] and
## [method stats_spec] are [Dictionary] specs a dot-sql driver turns into DDL for its own
## dialect, which is where MySQL's refusal to index TEXT and its missing
## [code]CREATE INDEX IF NOT EXISTS[/code] are handled once for every addon. This file names
## no dot-sql class, so dot-leaderboard still parses in a project without it.
##
## [b]Placeholders are [code]?[/code] in every dialect[/b] — dot-sql's contract. Identifiers
## (the table names) are the only thing ever spliced in, and they come from code or an
## operator's config, are checked by the driver's schema validation on [code]open()[/code],
## and are never a value a player chose.
##
## [b]No column is called `value`, `rank` or `key`.[/b] `rank` and `key` are reserved on
## MySQL and refused by dot-sql; `value` is not reserved anywhere yet but is one SQL
## standard revision away from it. So a board value is `score`, a counter is `amount`, and
## a computed rank comes back as `place`.

const DEFAULT_ENTRIES_TABLE := "dot_leaderboard_entries"
const DEFAULT_STATS_TABLE := "dot_leaderboard_stats"

## The component the schema version is recorded under in dot-sql's migration table,
## suffixed with the entries table so two stores in one database keep separate versions.
## Bumped by adding a step to [method migration_steps], never by editing one.
const MIGRATION_COMPONENT := "dot_leaderboard"

## Column order for the entries table. Every INSERT, SELECT and mapping uses this.
const ENTRY_COLUMNS := ["board_key", "player_id", "player_name", "score", "set_at", "meta"]

const STAT_COLUMNS := ["player_id", "stat_id", "amount"]


## One row per player per board.
##
## - [b]`board_key` is the whole address[/b] ([method DotLeaderboardDef.key]: id plus the
##   sorted scope), not an id and a scope in separate columns. The scope is open-ended string
##   keys — a timer has three, a deathmatch two, a 2D game none — and fixed columns would be
##   the mistake [DotLeaderboardDef] already explains. VARCHAR(191) on MySQL; a key past that
##   is a scope nobody should be building.
## - [b]The `(board_key, score)` index is the board.[/b] A page is a range scan of it, and
##   a rank is a count over it, so neither sorts the table per request.
## - [b]`set_at` is Unix seconds in a BIGINT[/b], never a timestamp type: two servers
##   writing one table are in two zones.
static func entries_spec(table: String = DEFAULT_ENTRIES_TABLE) -> Dictionary:
	return {
		"name": table,
		"columns": [
			{"name": "board_key", "type": "key", "null": false},
			{"name": "player_id", "type": "key", "null": false},
			{"name": "player_name", "type": "text"},
			{"name": "score", "type": "real", "null": false, "default": 0},
			{"name": "set_at", "type": "bigint", "null": false, "default": 0},
			{"name": "meta", "type": "json"},
		],
		"primary_key": ["board_key", "player_id"],
		"indexes": [
			{"name": "order_idx", "columns": ["board_key", "score"]},
		],
	}


## One row per player per counter. Additive, like [DotStatSet].
static func stats_spec(table: String = DEFAULT_STATS_TABLE) -> Dictionary:
	return {
		"name": table,
		"columns": [
			{"name": "player_id", "type": "key", "null": false},
			{"name": "stat_id", "type": "key", "null": false},
			{"name": "amount", "type": "real", "null": false, "default": 0},
		],
		"primary_key": ["player_id", "stat_id"],
	}


## Every schema change, in order, for dot-sql's migrator. Step N brings version N to N+1.
static func migration_steps(
	entries: String = DEFAULT_ENTRIES_TABLE, stats: String = DEFAULT_STATS_TABLE
) -> Array:
	return [
		[entries_spec(entries), stats_spec(stats)],
	]


## A board, best first, with each row's competition rank as `place`.
##
## [b]The rank is computed, not stored.[/b] The memory store materialises ranks because it
## re-sorts an array it already holds; a table that rewrote every row's rank on every
## submission would turn one write into a write per player on the board, under a lock, on
## the busiest board. A count of the strictly better rows over the `(board_key, score)` index
## is the same answer and costs a range scan per row of a page.
##
## [b]Ties share a rank[/b] (1, 2, 2, 4), because two identical values are a tie — see
## [member DotLeaderboardEntry.set_at] for why the older one is not awarded first. The
## ORDER BY breaks a tie by player id only so that a page boundary is stable; it is not a
## ranking rule.
##
## [param lower_is_better] chooses the operator and the direction: both are spliced from a
## boolean in code, never from a value.
static func select_page(table: String, lower_is_better: bool) -> String:
	return "%s WHERE e.board_key = ? ORDER BY e.score %s, e.player_id ASC LIMIT ? OFFSET ?" % [
		_select_ranked(table, lower_is_better), "ASC" if lower_is_better else "DESC"
	]


## One player's entry on a board, with its rank.
static func select_ranked_entry(table: String, lower_is_better: bool) -> String:
	return "%s WHERE e.board_key = ? AND e.player_id = ?" % _select_ranked(table, lower_is_better)


## One player's entry with no rank, for [code]put()[/code], which has no ordering to rank by.
static func select_entry(table: String) -> String:
	return "SELECT %s FROM %s WHERE board_key = ? AND player_id = ?" % [
		", ".join(ENTRY_COLUMNS), table
	]


static func count_board(table: String) -> String:
	return "SELECT COUNT(*) AS entries FROM %s WHERE board_key = ?" % table


static func delete_entry(table: String) -> String:
	return "DELETE FROM %s WHERE board_key = ? AND player_id = ?" % table


static func select_stats(table: String) -> String:
	return "SELECT stat_id, amount FROM %s WHERE player_id = ?" % table


## Adds to a counter, creating it if absent, in ONE statement.
##
## [b]Additive in the database, not read-modify-write here.[/b] Two servers sharing a
## database add kills for one player at the same moment; a read, an add and a write lose one
## of the two. The arithmetic belongs where the row lock is. It is the one statement in this
## addon spelled per dialect, because `ON CONFLICT … DO UPDATE` and
## `ON DUPLICATE KEY UPDATE` are two grammars and dot-sql's upsert only replaces. The
## dialect is dot-sql's frozen integer: 2 is MySQL.
static func add_stat(table: String, dialect: int) -> String:
	var head := "INSERT INTO %s (player_id, stat_id, amount) VALUES (?, ?, ?)" % table
	if dialect == 2:
		return "%s ON DUPLICATE KEY UPDATE amount = amount + VALUES(amount)" % head
	return "%s ON CONFLICT (player_id, stat_id) DO UPDATE SET amount = %s.amount + excluded.amount" % [
		head, table
	]


## An entry as bound parameters, in [constant ENTRY_COLUMNS] order.
static func entry_to_row(entry: DotLeaderboardEntry) -> Array:
	return [
		entry.board_key,
		String(entry.player_id),
		entry.player_name,
		entry.value,
		entry.set_at,
		"" if entry.meta.is_empty() else JSON.stringify(entry.meta),
	]


## A row back into an entry. A [Dictionary] keyed by column name, which is what a dot-sql
## driver returns; null for anything else.
##
## Numbers may arrive as floats (the gateway speaks JSON, which has one number type) or as
## strings (some drivers return a DOUBLE as text), so every one is converted rather than
## trusted.
static func entry_from_row(row: Variant) -> DotLeaderboardEntry:
	if not (row is Dictionary):
		return null

	var values := row as Dictionary
	var entry := DotLeaderboardEntry.new()
	entry.board_key = str(values.get("board_key", ""))
	entry.player_id = StringName(str(values.get("player_id", "")))
	var name_value: Variant = values.get("player_name")
	entry.player_name = "" if name_value == null else str(name_value)
	entry.value = _number(values.get("score", 0.0))
	entry.set_at = int(_number(values.get("set_at", 0)))
	entry.rank = int(_number(values.get("place", 0)))

	var meta_value: Variant = values.get("meta")
	if meta_value is String and meta_value != "":
		var parsed: Variant = JSON.parse_string(meta_value)
		if parsed is Dictionary:
			entry.meta = parsed
	elif meta_value is Dictionary:
		entry.meta = meta_value

	return entry


static func _number(value: Variant) -> float:
	if value is float or value is int:
		return float(value)
	if value is String and (value as String).is_valid_float():
		return (value as String).to_float()
	return 0.0


## The SELECT both ranked reads share. `e` is the row; `b` counts the rows that beat it.
static func _select_ranked(table: String, lower_is_better: bool) -> String:
	var columns := PackedStringArray()
	for column in ENTRY_COLUMNS:
		columns.append("e.%s" % column)
	return (
		"SELECT %s, (SELECT COUNT(*) FROM %s b WHERE b.board_key = e.board_key AND b.score %s e.score) + 1 AS place FROM %s e"
		% [", ".join(columns), table, "<" if lower_is_better else ">", table]
	)


## A dialect's name, for logs and [code]describe()[/code]. The integers are dot-sql's.
static func dialect_name(dialect: int) -> String:
	match dialect:
		0: return "sqlite"
		1: return "postgres"
		2: return "mysql"
	return "unknown"
