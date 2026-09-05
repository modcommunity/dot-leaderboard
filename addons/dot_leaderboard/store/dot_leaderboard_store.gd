class_name DotLeaderboardStore
extends RefCounted

## Where entries and statistics live. Subclass to put them somewhere else.
##
## Same shape and the same reasoning as [code]DotTimerStore[/code]: everything returns
## a [DotResult] and everything is a coroutine in shape even where it does not need to
## be, because an interface written against the in-memory case has to be rewritten the
## first time somebody points it at a database.
##
## [b]A store never decides whether an entry is allowed.[/b] It writes what it is
## given. Whether a value is plausible, whether the player is banned, whether the run
## was clean — all of that is the game's, upstream, where the context to judge it
## exists. A check inside the store would have to be repeated in every implementation
## and would be missing from somebody's.

## Files an entry. Returns the player's previous entry on that board, or null.
##
## The previous one rather than a bool, because every caller needs it: "you improved
## by 0.4 seconds" is the message, and re-reading it is a second round trip in the
## store that just wrote it.
func put(_entry: DotLeaderboardEntry) -> DotResult:
	return DotResult.fail(
		DotError.CODE_UNSUPPORTED, "DotLeaderboardStore.put() was not overridden."
	)


## A page of a board, best first. Returns an [code]Array[DotLeaderboardEntry][/code].
func page(
	_board: DotLeaderboardDef, _offset: int = 0, _limit: int = 25
) -> DotResult:
	return DotResult.fail(
		DotError.CODE_UNSUPPORTED, "DotLeaderboardStore.page() was not overridden."
	)


## One player's entry, or a success carrying null.
##
## Absent is not an error: a player who has never played is the normal case, and
## making it a failure means every caller has to tell "no entry" from "the database is
## down" by inspecting an error code — which somebody will not do.
func entry_for(
	_board: DotLeaderboardDef, _player_id: StringName
) -> DotResult:
	return DotResult.fail(
		DotError.CODE_UNSUPPORTED,
		"DotLeaderboardStore.entry_for() was not overridden."
	)


## How many players are on a board.
func count_on(_board: DotLeaderboardDef) -> DotResult:
	return DotResult.fail(
		DotError.CODE_UNSUPPORTED,
		"DotLeaderboardStore.count_on() was not overridden."
	)


## Removes a player's entry. For moderation.
func remove(
	_board: DotLeaderboardDef, _player_id: StringName
) -> DotResult:
	return DotResult.fail(
		DotError.CODE_UNSUPPORTED, "DotLeaderboardStore.remove() was not overridden."
	)


## Adds counters into a player's stats, and returns the totals.
func add_stats(_player_id: StringName, _stats: DotStatSet) -> DotResult:
	return DotResult.fail(
		DotError.CODE_UNSUPPORTED,
		"DotLeaderboardStore.add_stats() was not overridden."
	)


## A player's accumulated statistics. Never null on success — an empty set, so a
## caller reading a counter does not have to check twice.
func stats_for(_player_id: StringName) -> DotResult:
	return DotResult.fail(
		DotError.CODE_UNSUPPORTED,
		"DotLeaderboardStore.stats_for() was not overridden."
	)


func describe() -> Dictionary:
	return {
		"implementation": (
			get_script().get_global_name() if get_script() != null else "?"
		),
	}
