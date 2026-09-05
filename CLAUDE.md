# dot-leaderboard

Leaderboards and player statistics for any game, and the road from a game server to
the TMC backbone.

Read the family-wide conventions in [`../../CLAUDE.md`](../../CLAUDE.md) first. This
file is only what is specific to boards.

**Only dot-core is a dependency.** dot-auth, dot-timer and dot-server are all
optional and none of them is named anywhere in the source.

## The one idea

**A board is an ordering over one number per player, scoped by a set of string keys.**

"Fastest time on surf_beginner, main track, normal style", "most kills this week" and
"highest arena score" are the same shape. The only things that differ are the
ordering, the scope and how the number is rendered — so they are one `DotLeaderboardDef`
with a `Kind`, a `scope` dictionary and a `decimals`, and a site, a HUD and a store all
handle a game's own invented board without any of them being changed.

**The scope is string keys, not fixed columns.** A timer scopes by map, track and
style; a deathmatch by map and mode; a 2D game by nothing at all. Fixed columns would
mean every consumer carrying a `track` field that most games leave at zero, and a game
with a fourth dimension having nowhere to put it.

**`scope_key()` sorts the keys**, and that is load-bearing rather than tidy. GDScript
iterates a dictionary in insertion order, so without the sort
`{"map": x, "track": y}` and `{"track": y, "map": x}` are two different boards holding
half the entries each — and nothing anywhere errors.
`examples/leaderboard_selftest.gd::_test_scope_key_is_canonical` is the guard.

## Layout

```
addons/dot_leaderboard/
  core/
    dot_leaderboard_def.gd    a board: ordering, scope, rendering
    dot_leaderboard_entry.gd  one player's standing on one board
    dot_stat_set.gd           per-player counters. Not a board — see below
  store/
    dot_leaderboard_store.gd        where entries live (abstract)
    dot_leaderboard_store_memory.gd sorted on write, ranks materialised
  net/
    dot_leaderboard_reporter.gd  batches, queues and retries to the backbone
  runtime/
    dot_leaderboard_manager.gd   boards + store + reporter. The node a game adds
```

## Boards and statistics are different problems

Conflating them is the usual mistake. A **board** is one number per player, ordered. A
**stat set** is many numbers per player, accumulated. A board is often *derived* from a
stat — "most kills" is an ordering over the kills counter, and
`DotLeaderboardManager.publish_stat` is the bridge — but a stat nothing ranks is still
worth keeping, and a board whose value is not a counter is the common case.

`DotStatSet` is additive everywhere, because merging a session into a lifetime total,
or two servers' figures, is then a dictionary walk rather than a per-stat rule.
`set_best` and `set_lowest` exist for the two things that are genuinely not counters,
and they are separate methods rather than a flag so that `add_from` cannot silently
add two "best speed" figures together.

`DotStatSet.from_dictionary` **drops** non-numeric values rather than coercing them.
`float("banana")` is `0.0`, which silently resets a counter instead of leaving it
alone.

## Why the manager sorts and the store does not

A store holds entries, and an entry does not carry whether lower is better. The
manager has the definition, so it decides whether a value is an improvement and it
asks the store to re-sort and re-rank. Putting the ordering on the entry would repeat
it on every row of every board; passing the definition into `put()` would make the
interface awkward for a database implementation that keys on a board id alone.

**Ranks are materialised on write.** "Am I first" is asked far more often than a board
is written, and computing it on read means sorting the board per request.

**A store never decides whether an entry is allowed.** It writes what it is given.
Whether the value is plausible, whether the player is banned, whether the run was
clean — all of that is the game's, upstream, where the context to judge it exists.

The manager does refuse two things, and both are structural rather than editorial:

- **A non-finite value.** A NaN on a board can never be displaced, because every
  `beats` test against it is false. Cheap to refuse here and effectively unfixable
  afterwards.
- **A board that was never defined**, so a typo in a board id is a refusal rather than
  a silently empty board that never appears anywhere.

## Reporting to the backbone

`DotLeaderboardReporter` calls `post_integration(path, body)` on an object it is
handed. That method is the generic hook dot-auth's `DotBackboneClient` already
exposes: it stamps `ts` (Unix **seconds**) and a `nonce`, adds the bearer header, and
rate-limits locally. So everything about authenticating to the backbone stays in one
place, this class does not know a token exists, and **dot-auth is not a dependency** —
naming `DotBackboneClient` would make this addon fail to parse without it.

Three properties, each of which is a specific failure avoided:

- **Nothing is sent per event.** Twenty players finishing a round is twenty POSTs to
  one endpoint, which is both rude and the reason integration rate limits exist.
- **A failed flush keeps the queue.** The batch is removed only *after* the request
  succeeds. Taking it first and re-queueing on failure is the obvious shape and is
  wrong under a second flush arriving while the first is in flight: the re-queue puts
  entries back behind newer ones, and the order the backbone sees stops being the
  order they happened in.
- **The queue is bounded, and drops the OLDEST.** A backbone down for a day must not
  grow the server's memory until it is killed. Oldest, because on a leaderboard the
  newest results are the ones somebody is waiting to see — a queue that dropped the
  newest would faithfully report a backlog nobody remembers while discarding the
  record just set.

**Publishing is opt-in per board**, and off by default. Publishing sends player names
and scores off the server; that should be a decision somebody made, not something that
happens because a default was permissive. `DotLeaderboardManager.report_to_backbone`
is the master switch on top, so a server can be taken off the site's leaderboards
without editing every board.

`define()` exists separately from `submit` because a board's name, ordering and units
are editorial and change without any entry changing — deriving them from the first
submission means a site cannot render an empty board at all, and renaming one means
waiting for somebody to play.

**`player_id` is not a site user id.** The family's identity layer hands a server a
per-scope pseudonymous id precisely so operators cannot correlate their players across
servers. The backbone maps it to an account at the point of reporting, if the player
has linked one.

## The backbone endpoints

`POST /api/integration/v1/leaderboard/define` and `.../submit`, with the
`LEADERBOARD_WRITE` scope on a server- or app-scoped integration. `GET .../board`
reads one with `LEADERBOARD_READ`. The contracts live in website-city at
`src/types/integration/leaderboard.ts`; the request pipeline (authentication, scope,
IP allowlist, rate limit, replay check, audit) is the shared
`handleIntegrationRequest`.

A 403 means the integration lacks the scope and will not fix itself, so the reporter
says which scope rather than retrying it every thirty seconds for ever.

## Validating

```bash
godot --headless --path . --import
find . -name '*.gd' -not -path './.godot/*' | while read f; do
    godot --headless --path . --check-only --script "res://${f#./}"
done
godot --headless --path . res://examples/leaderboard_selftest.tscn   # 69 checks
```

The suite found one bug, and it was a good one: **`to_dictionary()` handed out its own
`scope` dictionary**. A `Dictionary` is a reference in GDScript, and `scoped()`
round-trips through `to_dictionary`/`from_dictionary` — so every scoped board and the
template it came from were one object, and every board on the server ended up with the
last scope anybody asked for. The same aliasing was then found and fixed in
`DotTimerZone.payload`, `DotTimerRecord.splits`/`stats`/`extra` and `DotMapDef.meta`,
none of which had a test that would have caught it.


A second one was found by reading rather than running, and it is the family's
recurring shape — *the two ends had never met*: the reporter's payload used this
addon's own file format as if it were the wire. `LeaderboardSubmitInput` on the
backbone spells the timestamp `setAt` and takes the kind as `"TIME"`; the reporter
sent `set_at` and the enum's integer. `LeaderboardDefineInput` names a board by `key`;
`to_dictionary()` says `id`. Every request would have been refused by the schema. The
wire shape is now `wire_definition()` and the queue entry, both commented with the
backbone type they mirror, and the suite asserts the field names.

## Where a game plugs in

| To change | Where |
| --- | --- |
| Where entries live | `DotLeaderboardStore` subclass on `DotLeaderboardManager.store` |
| What a board measures and how it sorts | `DotLeaderboardDef.Kind` |
| What a board is per | `DotLeaderboardDef.scope`, and `scoped()` per instance |
| How a value renders | `decimals`, `unit`, or override `format_value` |
| Whether a board reaches the site | `DotLeaderboardDef.publish` plus the master switch |
| Where reports go | `DotLeaderboardReporter.client` — anything with `post_integration` |
| How often they go | `DotLeaderboardManager.report_interval` |
| Turning a counter into a board | `publish_stat` |

## Things deliberately not here

- **A leaderboard UI.** dot-ui has the screen stack; what a board looks like is a
  game's own decision and every game's is different.
- **Cross-map ranking.** Summing a player's points across every board into one rank is
  a policy decision — which boards count, how they weight, whether it decays — and it
  belongs to the game or to the site, not to the storage layer.
- **Seasons and resets.** A season is a scope key (`{"season": "2026-q1"}`) and needs
  no code here. When one ends, define the next.
- **Reading the backbone's copy.** The reporter writes. A client that wants the site's
  leaderboard asks the site, over HTTP, like any other page.
- **Anti-cheat.** The refusals here are structural (a NaN, an unknown board).
  Judging whether a score is plausible needs the context the game has and this does
  not.
