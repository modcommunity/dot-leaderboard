# Design

What a board is, how it differs from a stat set, and who decides what. Storage is [storage.md](storage.md); the site is [backbone.md](backbone.md).

## The one idea

**A board is an ordering over one number per player, scoped by a set of string keys.**

"Fastest time on surf_beginner, main track, normal style", "most kills this week" and "highest arena score" are the same shape. The only things that differ are the ordering, the scope and how the number is rendered, so they are one `DotLeaderboardDef` with a `Kind`, a `scope` dictionary and a `decimals`, and a site, a HUD and a store all handle a game's own invented board without any of them being changed.

**The scope is string keys, not fixed columns.** A timer scopes by map, track and style; a deathmatch by map and mode; a 2D game by nothing at all. Fixed columns would mean every consumer carrying a `track` field that most games leave at zero, and a game with a fourth dimension having nowhere to put it. A season is a scope key too (`{"season": "2026-q1"}`) and needs no code here: when one ends, define the next.

**`scope_key()` sorts the keys**, and that is load-bearing rather than tidy. GDScript iterates a dictionary in insertion order, so without the sort `{"map": x, "track": y}` and `{"track": y, "map": x}` are two different boards holding half the entries each, and nothing anywhere errors. `examples/leaderboard_selftest.gd::_test_scope_key_is_canonical` is the guard.

**`to_dictionary()` copies its `scope`.** A `Dictionary` is a reference, and `scoped()` round-trips through it, so handing out the original makes every scoped board share one scope ([history](history.md#every-board-had-the-last-scope-anybody-asked-for)).

## Boards and statistics are different problems

Conflating them is the usual mistake. A **board** is one number per player, ordered. A **stat set** is many numbers per player, accumulated. A board is often *derived* from a stat ("most kills" is an ordering over the kills counter, and `DotLeaderboardManager.publish_stat` is the bridge), but a stat nothing ranks is still worth keeping, and a board whose value is not a counter is the common case.

`DotStatSet` is additive everywhere, because merging a session into a lifetime total, or two servers' figures, is then a dictionary walk rather than a per-stat rule. `set_best` and `set_lowest` exist for the two things that are genuinely not counters, and they are separate methods rather than a flag so that `add_from` cannot silently add two "best speed" figures together.

`DotStatSet.from_dictionary` **drops** non-numeric values rather than coercing them. `float("banana")` is `0.0`, which silently resets a counter instead of leaving it alone.

## Why the manager sorts and the store does not

A store holds entries, and an entry does not carry whether lower is better. The manager has the definition, so it decides whether a value is an improvement and it asks the store to re-sort and re-rank (`sort_board`). Putting the ordering on the entry would repeat it on every row of every board; passing the definition into `put()` would make the interface awkward for a database implementation that keys on a board id alone.

**Ranks are materialised on write** in the memory store: "am I first" is asked far more often than a board is written, and computing it on read means sorting the board per request. The SQL store's answer is different on purpose ([storage](storage.md#ranks-in-sql)).

**A tie shares a rank** (1, 2, 2, 4), in both stores. Ranking by array index made two identical times 2nd and 3rd in whichever order an unstable `sort_custom` left them: a ranking rule nobody agreed to (`DotLeaderboardEntry.set_at` says why the older one is not first either), and one the SQL store's count could never reproduce. Both break a tie by player id for a stable page boundary only.

**A store never decides whether an entry is allowed.** It writes what it is given. Whether the value is plausible, whether the player is banned, whether the run was clean: all of that is the game's, upstream, where the context to judge it exists.

The manager does refuse two things, and both are structural rather than editorial:

- **A non-finite value.** A NaN on a board can never be displaced, because every `beats` test against it is false. Cheap to refuse here and effectively unfixable afterwards.
- **A board that was never defined**, so a typo in a board id is a refusal rather than a silently empty board that never appears anywhere.

## Running totals

`DotLeaderboardDef.running_total` marks a board whose newest value is the right one even when it is lower: a ranking total that drops when somebody else's record re-scores the board. "Keep the best" froze a player at the highest total they ever had. `DotLeaderboardManager.replace_async` writes one without the improvement test, and the reporter sends such entries in their own request with the site's `overwrite: true` ([backbone](backbone.md#running-totals-on-the-wire)).

## Deliberately not here

- **A leaderboard UI.** dot-ui has the screen stack; what a board looks like is a game's own decision and every game's is different.
- **Cross-map ranking.** Summing a player's points across every board into one rank is a policy decision (which boards count, how they weight, whether it decays) and it belongs to the game or to the site, not to the storage layer.
- **Seasons and resets** as code: a season is a scope key.
- **Reading the backbone's copy.** The reporter writes. A client that wants the site's leaderboard asks the site, over HTTP, like any other page.
- **Anti-cheat.** The refusals here are structural (a NaN, an unknown board). Judging whether a score is plausible needs the context the game has and this does not.
