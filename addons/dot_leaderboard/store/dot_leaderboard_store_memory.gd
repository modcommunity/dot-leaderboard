class_name DotLeaderboardStoreMemory
extends DotLeaderboardStore

## Entries and statistics in dictionaries. For tests, a scratch server, and as the
## reference implementation.
##
## [b]Boards are kept sorted on write and ranks are materialised there too.[/b] A
## board is read far more often than it is written — a HUD asks for the top ten
## whenever anybody finishes, a scoreboard asks on every open, and "am I first" is
## asked constantly — so paying the sort on the write is the right side of the trade,
## and it turns a rank lookup into an array read.

## board key -> player id -> entry.
var _rows: Dictionary = {}

## board key -> sorted array of entries.
var _boards: Dictionary = {}

## player id -> DotStatSet.
var _stats: Dictionary = {}


func put(entry: DotLeaderboardEntry) -> DotResult:
	if entry == null or entry.board_key == "":
		return DotResult.fail(
			DotError.CODE_INVALID, "An entry needs a board key."
		)

	if not _rows.has(entry.board_key):
		_rows[entry.board_key] = {}
		_boards[entry.board_key] = []

	var by_player: Dictionary = _rows[entry.board_key]
	var previous_value: Variant = by_player.get(entry.player_id)
	var previous: DotLeaderboardEntry = (
		previous_value if previous_value is DotLeaderboardEntry else null
	)

	by_player[entry.player_id] = entry

	var rows: Array = _boards[entry.board_key]

	if previous != null:
		rows.erase(previous)

	rows.append(entry)

	return DotResult.success(previous)


## Sorts a board and rewrites every rank on it.
##
## [b]Called by the manager, not by [method put], and that is a real decision.[/b] The
## manager knows the board's ordering; the store only has entries, and an entry does
## not carry whether lower is better. Storing the ordering on the entry would put it
## on every row of every board; passing the definition to put() would make the
## interface awkward for a database implementation that keys on the board id alone.
## So the manager sorts, and a store used directly is a store with unranked rows —
## which [method page] still returns in insertion order rather than pretending.
func sort_board(board: DotLeaderboardDef) -> void:
	var key := board.key()
	var rows_value: Variant = _boards.get(key)

	if not (rows_value is Array):
		return

	var rows: Array = rows_value
	var lower := board.lower_is_better()

	rows.sort_custom(func(a: DotLeaderboardEntry, b: DotLeaderboardEntry) -> bool:
		return a.value < b.value if lower else a.value > b.value
	)

	for i in range(rows.size()):
		(rows[i] as DotLeaderboardEntry).rank = i + 1


func page(
	board: DotLeaderboardDef, offset: int = 0, limit: int = 25
) -> DotResult:
	var rows_value: Variant = _boards.get(board.key(), [])
	var rows: Array = rows_value if rows_value is Array else []

	var out: Array[DotLeaderboardEntry] = []
	var start := maxi(offset, 0)

	for i in range(start, mini(start + maxi(limit, 0), rows.size())):
		out.append(rows[i])

	return DotResult.success(out)


func entry_for(
	board: DotLeaderboardDef, player_id: StringName
) -> DotResult:
	var by_player_value: Variant = _rows.get(board.key(), {})
	var by_player: Dictionary = (
		by_player_value if by_player_value is Dictionary else {}
	)

	var found: Variant = by_player.get(player_id)

	return DotResult.success(
		found if found is DotLeaderboardEntry else null
	)


func count_on(board: DotLeaderboardDef) -> DotResult:
	var rows_value: Variant = _boards.get(board.key(), [])
	return DotResult.success((rows_value as Array).size() if rows_value is Array else 0)


func remove(board: DotLeaderboardDef, player_id: StringName) -> DotResult:
	var key := board.key()
	var by_player_value: Variant = _rows.get(key, {})
	var by_player: Dictionary = (
		by_player_value if by_player_value is Dictionary else {}
	)

	var found: Variant = by_player.get(player_id)

	if not (found is DotLeaderboardEntry):
		return DotResult.success(false)

	by_player.erase(player_id)

	var rows_value: Variant = _boards.get(key, [])
	if rows_value is Array:
		(rows_value as Array).erase(found)

	sort_board(board)

	return DotResult.success(true)


func add_stats(player_id: StringName, stats: DotStatSet) -> DotResult:
	if stats == null:
		return DotResult.fail(DotError.CODE_INVALID, "No stats to add.")

	if not _stats.has(player_id):
		_stats[player_id] = DotStatSet.new()

	(_stats[player_id] as DotStatSet).add_from(stats)

	return DotResult.success(_stats[player_id])


func stats_for(player_id: StringName) -> DotResult:
	var found: Variant = _stats.get(player_id)

	# An empty set rather than null, so a caller reading a counter does not have to
	# check twice. A player with no statistics has zero of everything, which is what
	# an empty set says.
	return DotResult.success(
		found if found is DotStatSet else DotStatSet.new()
	)


## Every board key that has entries. For an export or a re-rank.
func board_keys() -> PackedStringArray:
	var out := PackedStringArray()

	for key in _boards:
		out.append(key)

	return out


func clear() -> void:
	_rows.clear()
	_boards.clear()
	_stats.clear()


func describe() -> Dictionary:
	var out := super.describe()
	out["boards"] = _boards.size()
	out["players_with_stats"] = _stats.size()

	var total := 0
	for key in _boards:
		total += (_boards[key] as Array).size()

	out["entries"] = total
	return out
