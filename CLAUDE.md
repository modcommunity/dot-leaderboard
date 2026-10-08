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
    dot_leaderboard_store_sql.gd    the same, in SQLite, Postgres or MySQL via dot-sql
    dot_leaderboard_sql_schema.gd   its two tables as dot-sql specs, its statements
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

That is the memory store's answer, and the SQL store's is different on purpose: a table that rewrote every row's rank on every submission turns one write into a write per player on the board, under a lock, on the busiest board. There the index *is* the order, and a rank is a count of the strictly better rows over `(board_key, score)` — computed per row of a page in the same SELECT.

**A tie shares a rank** (1, 2, 2, 4), in both stores. Until 2026-10-08 the memory store ranked by array index, so two identical times were 2nd and 3rd in whichever order an unstable `sort_custom` left them — a ranking rule nobody agreed to (`DotLeaderboardEntry.set_at` says why the older one is not first either), and one the SQL store's count could never reproduce. Both now break a tie by player id for a stable page boundary only; the `ranks` section asserts 1, 2, 2, 4.

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

## SQL storage, through dot-sql

`DotLeaderboardStoreSql` holds its driver **untyped** and asks it for `query`, `execute`, `batch`, `upsert_sql`, `dialect` and `migrate`, so no file in the addon names a dot-sql class and the addon parses in a project that has not installed it — the same bargain dot-moderation's SQL store makes. dot-sql is linked into `addons/` (gitignored) only for the suites. The tables are `DotLeaderboardSqlSchema`'s plain-dictionary specs, which the driver renders per dialect, so MySQL's refusal to index TEXT and its missing `CREATE INDEX IF NOT EXISTS` are dot-sql's problem rather than a fourth copy here. A database written by a newer build is refused at `open()`, by dot-sql's migrator, rather than read with columns that changed meaning.

- **`board_key` is the whole address** (`DotLeaderboardDef.key()`), not an id and a scope in columns, for the reason the scope is string keys at all.
- **No column is `value`, `rank` or `key`.** `rank` and `key` are reserved on MySQL and refused by dot-sql; the value is `score`, a counter is `amount`, a computed rank comes back as `place`.
- **Counters are added by the database**, `amount = amount + excluded.amount` (MySQL: `amount + VALUES(amount)`), the one statement spelled per dialect. A read, an add and a write from two servers at once lose one of the two kills; the arithmetic belongs where the row lock is.
- **`put()` is an unconditional upsert** and returns the previous entry. Whether a value is an improvement is still the manager's call, because the store still has no ordering to judge by.

**The manager never awaited its store, and that is why there are `_async` forms.** `DotLeaderboardStore` says every method is "a coroutine in shape … because an interface written against the in-memory case has to be rewritten the first time somebody points it at a database" — and the manager called `store.entry_for`, `store.put` and `store.page` without `await`. Against a store that really suspends, Godot aborts the call with *"Trying to call an async function without await"* and the caller gets null. Adding the `await` makes `submit`, `page` and `entry_for` coroutines, which is a **parse error** at every caller that does not await them — and game-arena (`arena_module._cmd_boards`, `headless_match`) and game-hungario (`hungry_progress._submit`, `.page`) do not. An addon edit that stops two games parsing is not a fix, so `submit_async`, `page_async` and `entry_for_async` are the awaited forms and work with every store, and the plain forms stay synchronous and **refuse** a store whose `is_synchronous()` is false, naming the form that works. When those four call sites await, the plain forms can become the awaited ones. `add_stats`, `stats_for` and `publish_stat` had no synchronous callers and are awaited in place.

`sort_board` is what the manager calls after a write; in SQL it re-sorts nothing and ranks the one entry it just wrote, so the entry `submit_async` hands back says "4th" exactly as the memory store's would.

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
godot --headless --path . res://examples/leaderboard_selftest.tscn   # 13 sections, 107 checks

# The SQL store against real databases, through dot-sql's gateway. SQLite always;
# Postgres and MySQL/MariaDB when DOT_SQL_PG_DSN / DOT_SQL_MYSQL_DSN are set.
../dot-sql/tools/test_live.sh . res://examples/leaderboard_sql_live.tscn   # 17 checks per dialect
```

The selftest's last section drives the SQL store with dot-sql's recording driver: which statements, in which order, bound how, mapped back how, what a failure does, and that a newer schema is refused. It cannot say whether the SQL is valid; the live scene is what does, and it has run green on SQLite, Postgres 17 and MariaDB 11.8 (2026-10-08).

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
| Where entries live | `DotLeaderboardStore` subclass on `DotLeaderboardManager.store`; `DotLeaderboardStoreSql` for a database |
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

## Running totals (2026-10-08)

`DotLeaderboardDef.running_total` marks a board whose newest value is the right one even when it is lower: a ranking total that drops when somebody else's record re-scores the board. "Keep the best" froze a player at the highest total they ever had. `DotLeaderboardManager.replace_async` writes one without the improvement test, and the reporter sends such entries in their own request with the site's `overwrite: true` (the site's flag is per request, so a batch is the run of queued entries that agree about it, in order). The SQL store ranks the entry just written by player (`rank_entry`); a per-board "last written" slot was overwritten by a second submission before the first was ranked.

