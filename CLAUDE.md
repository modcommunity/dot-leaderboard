# dot-leaderboard

Leaderboards and player statistics for any game: boards as an ordering over one number per player, scoped by string keys; stat sets; memory and SQL stores; and a reporter that batches results to the TMC backbone.

Read the family [CLAUDE.md](../../CLAUDE.md) first; this file is only what is specific to boards. The reasoning is in [docs/](docs/README.md).

**Only dot-core is a dependency.** dot-auth, dot-timer, dot-server and dot-sql are all optional and none is named anywhere in the source. dot-sql is linked (`.gitignore`) only for the suites.

## Read before

| Read | Before |
| --- | --- |
| [docs/README.md](docs/README.md) | the index |
| [docs/design.md](docs/design.md) | `DotLeaderboardDef`, `DotLeaderboardEntry`, `DotStatSet`, `DotLeaderboardManager` |
| [docs/storage.md](docs/storage.md) | any `DotLeaderboardStore`, `DotLeaderboardSqlSchema`, the `_async` forms |
| [docs/backbone.md](docs/backbone.md) | `DotLeaderboardReporter`, anything the site receives |
| [docs/history.md](docs/history.md) | the bugs, and how each looked |

## Layout

| Path | What |
| --- | --- |
| `addons/dot_leaderboard/core/` | `DotLeaderboardDef` (ordering, scope, rendering), `DotLeaderboardEntry`, `DotStatSet` (per-player counters; not a board) |
| `addons/dot_leaderboard/store/` | `DotLeaderboardStore` (abstract), backbone (the site's `/api/integration/v1/leaderboard/*`: top, around-me, rank; remote, `_async` only; the manager skips its reporter for it), memory (sorted on write, ranks materialised), SQL (SQLite, Postgres, MySQL via dot-sql), `DotLeaderboardSqlSchema` |
| `addons/dot_leaderboard/net/` | `DotLeaderboardReporter`: batches, queues and retries to the backbone |
| `addons/dot_leaderboard/runtime/` | `DotLeaderboardManager`: boards, store and reporter; the node a game adds |
| `addons/dot_leaderboard/testing/` | `DotLeaderboardFakeSite`: the in-process fake site for tests (`post_integration`/`get_integration`, one frame of latency, declare-before-submit, optional scope checks); games use it, never their own copy |
| `examples/leaderboard_backbone_test.tscn` | the backbone store against the fake site, over TCP through dot-auth's client and in-process |
| `examples/leaderboard_selftest.tscn` | the suite (the SQL store through dot-sql's recording driver) |
| `examples/leaderboard_sql_live.tscn` | the SQL store against real databases |

## Running and testing

- The family's two steps ([game-dev/CLAUDE.md](../../CLAUDE.md#validating-anything)), then `godot --headless --path . res://examples/leaderboard_selftest.tscn`.
- Anything in the SQL store: `../dot-sql/tools/test_live.sh . res://examples/leaderboard_sql_live.tscn` (SQLite always; Postgres and MySQL with `DOT_SQL_PG_DSN` / `DOT_SQL_MYSQL_DSN`). [storage](docs/storage.md#testing)
- A change to the manager's sync forms: re-run game-arena's and game-hungario's suites, which call them.

## Rules that bite

- A board is one `DotLeaderboardDef` with a `Kind`, a string-keyed `scope` and rendering; never fixed scope columns. [design](docs/design.md#the-one-idea)
- `scope_key()` sorts **by text** (`sort_custom` on `str`, never `sort()`: StringName keys sort by interning); `to_dictionary()` copies its dictionaries. Both have a guard in the suite. [design](docs/design.md#the-one-idea)
- `DotStatSet` is additive; `set_best`/`set_lowest` are methods, not a flag; `from_dictionary` drops non-numbers. [design](docs/design.md#boards-and-statistics-are-different-problems)
- The manager owns ordering and improvement; a store writes what it is given and judges nothing. [design](docs/design.md#why-the-manager-sorts-and-the-store-does-not)
- Ties share a rank (1, 2, 2, 4) in both stores; player id breaks a tie only for paging. [design](docs/design.md#why-the-manager-sorts-and-the-store-does-not)
- The manager refuses a non-finite value and an undefined board, and nothing else. [design](docs/design.md#why-the-manager-sorts-and-the-store-does-not)
- `running_total` boards are written by `replace_async` and reported with `overwrite: true`. [design](docs/design.md#running-totals)
- The SQL driver is untyped; tables are dot-sql specs; no column named `value`, `rank` or `key`; counters are added in the database. [storage](docs/storage.md#sql-storage-through-dot-sql)
- SQL ranks are counted at read time, never rewritten per write. [storage](docs/storage.md#ranks-in-sql)
- Plain `submit`/`page`/`entry_for` are synchronous and refuse a suspending store; `_async` forms work with every store. [storage](docs/storage.md#why-there-are-_async-forms)
- The reporter batches, removes a batch only after success, and drops the oldest when full. [backbone](docs/backbone.md#three-properties-each-a-failure-avoided)
- Publishing is opt-in per board plus `report_to_backbone`; `player_id` is a pseudonym, never a site user id. [backbone](docs/backbone.md#publishing-is-a-decision)
- Send `wire_definition()` and the queue entry, never `to_dictionary()`; a 403 names the missing scope and is not retried. [backbone](docs/backbone.md#the-endpoints-and-the-wire-shape)

## Where a game plugs in

| To change | Where |
| --- | --- |
| Where entries live | `DotLeaderboardStore` subclass on `DotLeaderboardManager.store`; `DotLeaderboardStoreSql` for a database; `DotLeaderboardStoreBackbone` (or `backend = "backbone"` plus `backbone_client`) for the site's own boards |
| What a board measures and how it sorts | `DotLeaderboardDef.Kind` |
| What a board is per | `DotLeaderboardDef.scope`, and `scoped()` per instance |
| How a value renders | `decimals`, `unit`, or override `format_value` |
| Whether a board reaches the site | `DotLeaderboardDef.publish` plus the master switch |
| Where reports go | `DotLeaderboardReporter.client`: anything with `post_integration` |
| How often they go | `DotLeaderboardManager.report_interval` |
| Turning a counter into a board | `publish_stat` |

## Open

- **The plain `submit`/`page`/`entry_for` are still the synchronous forms.** game-arena and game-hungario now await the `_async` forms (their suites run them against `DotLeaderboardFakeSite`), so the plain forms can become the awaited ones in a breaking release. [storage](docs/storage.md#why-there-are-_async-forms)

Deliberately not here: a UI, cross-map ranking, seasons as code, reading the backbone's copy, anti-cheat. [design](docs/design.md#deliberately-not-here)
