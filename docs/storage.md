# Storage

`DotLeaderboardStore` and its two implementations, and why the manager has `_async` forms.

## SQL storage, through dot-sql

`DotLeaderboardStoreSql` holds its driver **untyped** and asks it for `query`, `execute`, `batch`, `upsert_sql`, `dialect` and `migrate`, so no file in the addon names a dot-sql class and the addon parses in a project that has not installed it: the same bargain dot-moderation's SQL store makes. dot-sql is linked into `addons/` (gitignored) only for the suites. The tables are `DotLeaderboardSqlSchema`'s plain-dictionary specs, which the driver renders per dialect, so MySQL's refusal to index TEXT and its missing `CREATE INDEX IF NOT EXISTS` are dot-sql's problem rather than another copy here. A database written by a newer build is refused at `open()`, by dot-sql's migrator, rather than read with columns that changed meaning.

- **`board_key` is the whole address** (`DotLeaderboardDef.key()`), not an id and a scope in columns, for the reason the scope is string keys at all.
- **No column is `value`, `rank` or `key`.** `rank` and `key` are reserved on MySQL and refused by dot-sql; the value is `score`, a counter is `amount`, a computed rank comes back as `place`.
- **Counters are added by the database**, `amount = amount + excluded.amount` (MySQL: `amount + VALUES(amount)`), the one statement spelled per dialect. A read, an add and a write from two servers at once lose one of the two kills; the arithmetic belongs where the row lock is.
- **`put()` is an unconditional upsert** and returns the previous entry. Whether a value is an improvement is still the manager's call, because the store still has no ordering to judge by.

## Ranks in SQL

A table that rewrote every row's rank on every submission turns one write into a write per player on the board, under a lock, on the busiest board. There the index *is* the order, and a rank is a count of the strictly better rows over `(board_key, score)`, computed per row of a page in the same SELECT.

`sort_board` in SQL re-sorts nothing and ranks the one entry just written, so the entry `submit_async` hands back says "4th" exactly as the memory store's would. It ranks that entry by player (`rank_entry`): a per-board "last written" slot was overwritten by a second submission before the first was ranked.

## Why there are `_async` forms

`DotLeaderboardStore` says every method is a coroutine in shape, because an interface written against the in-memory case has to be rewritten the first time somebody points it at a database. The manager called `store.entry_for`, `store.put` and `store.page` without `await`; against a store that really suspends, Godot aborts the call with *"Trying to call an async function without await"* and the caller gets null.

Adding the `await` makes `submit`, `page` and `entry_for` coroutines, which is a **parse error** at every caller that does not await them, and game-arena (`arena_boards.gd`, `arena_module._cmd_boards`, `headless_match`) and game-hungario (`hungry_progress`) do not. An addon edit that stops two games parsing is not a fix, so:

- `submit_async`, `page_async` and `entry_for_async` are the awaited forms and work with every store.
- The plain forms stay synchronous and **refuse** a store whose `is_synchronous()` is false, naming the form that works.
- `add_stats`, `stats_for` and `publish_stat` had no synchronous callers and are awaited in place.

When those call sites await, the plain forms can become the awaited ones.

## Testing

The selftest's last section drives the SQL store with dot-sql's recording driver: which statements, in which order, bound how, mapped back how, what a failure does, and that a newer schema is refused. It cannot say whether the SQL is valid; `examples/leaderboard_sql_live.tscn` is what does, through dot-sql's gateway, on SQLite always and on Postgres and MySQL/MariaDB when `DOT_SQL_PG_DSN` / `DOT_SQL_MYSQL_DSN` are set.
