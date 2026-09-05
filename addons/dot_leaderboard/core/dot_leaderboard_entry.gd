class_name DotLeaderboardEntry
extends RefCounted

## One player's standing on one board.

## Which board. See [method DotLeaderboardDef.key].
var board_key: String = ""

## Who, in the host's own vocabulary.
##
## [b]Not a site user id.[/b] The family's identity layer hands a server a per-scope
## pseudonymous id precisely so operators cannot correlate their players across
## servers, and a leaderboard storing a global id would undo that. The backbone maps
## it to an account at the point of reporting, if the player has linked one.
var player_id: StringName = &""

## What to show. Denormalised, because a board renders without a lookup per row and
## because the name an entry was set under is part of the entry.
var player_name: String = ""

var value: float = 0.0

## Rank at the time of the last write. 1 is first, 0 is unranked.
##
## [b]Materialised, not computed on read.[/b] "Am I first" is asked far more often
## than a board is written to, and computing it on read means sorting the board per
## request. Written by the store on every put.
var rank: int = 0

## Unix seconds. Presentation only; never used for ordering.
##
## Ordering by value and breaking ties by this would be wrong in the one case that
## matters: two identical values are a tie, and awarding the older one first is a rule
## nobody agreed to.
var set_at: int = 0

## Anything the game keeps with an entry: splits, a replay id, statistics.
var meta: Dictionary = {}


static func make(
	p_board: String,
	p_player: StringName,
	p_name: String,
	p_value: float,
	p_meta: Dictionary = {}
) -> DotLeaderboardEntry:
	var entry := DotLeaderboardEntry.new()

	entry.board_key = p_board
	entry.player_id = p_player
	entry.player_name = p_name
	entry.value = p_value
	entry.meta = p_meta
	entry.set_at = int(Time.get_unix_time_from_system())

	return entry


func to_dictionary() -> Dictionary:
	return {
		"board": board_key,
		"player": String(player_id),
		"name": player_name,
		"value": value,
		"rank": rank,
		"set_at": set_at,
		"meta": meta,
	}


static func from_dictionary(data: Dictionary) -> DotLeaderboardEntry:
	var entry := DotLeaderboardEntry.new()

	entry.board_key = str(data.get("board", ""))
	entry.player_id = StringName(str(data.get("player", "")))
	entry.player_name = str(data.get("name", ""))
	entry.value = float(data.get("value", 0.0))
	entry.rank = int(data.get("rank", 0))
	entry.set_at = int(data.get("set_at", 0))

	var meta_value: Variant = data.get("meta", {})
	entry.meta = meta_value if meta_value is Dictionary else {}

	return entry


func describe() -> Dictionary:
	return {
		"board": board_key,
		"player": player_name if player_name != "" else String(player_id),
		"value": value,
		"rank": rank,
	}


func _to_string() -> String:
	return "DotLeaderboardEntry(#%d %s %.3f)" % [
		rank, player_name if player_name != "" else String(player_id), value
	]
