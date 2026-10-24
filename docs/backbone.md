# Reporting to the backbone

`DotLeaderboardReporter`, and the site endpoints it writes to. The family's backbone rules are in [backbone.md](../../../docs/backbone.md).

## The client is anything with `post_integration`

`DotLeaderboardReporter` calls `post_integration(path, body)` on an object it is handed. That method is the generic hook dot-auth's `DotBackboneClient` already exposes: it stamps `ts` (Unix **seconds**) and a `nonce`, adds the bearer header, and rate-limits locally. So everything about authenticating to the backbone stays in one place, this class does not know a token exists, and **dot-auth is not a dependency**: naming `DotBackboneClient` would make this addon fail to parse without it.

## Three properties, each a failure avoided

- **Nothing is sent per event.** Twenty players finishing a round is twenty POSTs to one endpoint, which is both rude and the reason integration rate limits exist.
- **A failed flush keeps the queue.** The batch is removed only *after* the request succeeds. Taking it first and re-queueing on failure is the obvious shape and is wrong under a second flush arriving while the first is in flight: the re-queue puts entries back behind newer ones, and the order the backbone sees stops being the order they happened in.
- **The queue is bounded, and drops the OLDEST.** A backbone down for a day must not grow the server's memory until it is killed. Oldest, because on a leaderboard the newest results are the ones somebody is waiting to see: a queue that dropped the newest would faithfully report a backlog nobody remembers while discarding the record just set.

## Publishing is a decision

**Publishing is opt-in per board**, and off by default. Publishing sends player names and scores off the server; that should be a decision somebody made, not something that happens because a default was permissive. `DotLeaderboardManager.report_to_backbone` is the master switch on top, so a server can be taken off the site's leaderboards without editing every board.

`define()` exists separately from `submit` because a board's name, ordering and units are editorial and change without any entry changing: deriving them from the first submission means a site cannot render an empty board at all, and renaming one means waiting for somebody to play.

**`player_id` is not a site user id.** The family's identity layer hands a server a per-scope pseudonymous id precisely so operators cannot correlate their players across servers. The backbone maps it to an account at the point of reporting, if the player has linked one.

## The endpoints and the wire shape

`POST /api/integration/v1/leaderboard/define` and `.../submit`, with the `LEADERBOARD_WRITE` scope on a server- or app-scoped integration. `GET .../board` reads one with `LEADERBOARD_READ`. The contracts live in website-city at `src/types/integration/leaderboard.ts`; the request pipeline (authentication, scope, IP allowlist, rate limit, replay check, audit) is the shared `handleIntegrationRequest`.

**The wire shape is not the file format.** `wire_definition()` and the queue entry mirror the backbone's types (`setAt`, the kind as a string like `"TIME"`, a board named by `key`), each commented with the type it mirrors, and the suite asserts the field names. `to_dictionary()` is this addon's own format and must not be sent ([history](history.md#the-two-ends-had-never-met)).

A 403 means the integration lacks the scope and will not fix itself, so the reporter says which scope rather than retrying it every thirty seconds for ever.

## Running totals on the wire

A `running_total` board's entries go in their own request with the site's `overwrite: true`. The site's flag is per request, so a batch is the run of queued entries that agree about it, in order.

## Reading the backbone: `DotLeaderboardStoreBackbone`

The reporter only writes. `DotLeaderboardStoreBackbone` is a store whose boards live on the site: `declare` (define, once per board), `put` (submit with `overwrite`, because the manager already judged improvement), `page`/`top`, `entry_for`, `rank_entry`, `around` and `count_on`, through `GET .../board` with the `LEADERBOARD_READ` scope. Select it with `DotLeaderboardManager.backend = "backbone"` and `backbone_client` (or a registered `dot_backbone_client`); memory stays the default. It is remote, so use the `_async` forms, and the manager does not also queue to the reporter. Authentication is the integration token on the client; the API takes no player token. Statistics are not on the site and stay unsupported.

## Choosing the store: `DotBoardsConfig`

`DotBoardsConfig.for_game("arena")` is the one config every game's server uses to pick `memory` or `backbone`: `ARENA_BOARDS_BACKEND`, `--arena_boards_backend` (`for_game("hungry", "-")` gives `--hungry-boards-backend`), and `DotBoardsConfig.json_path_for("arena")` for the file. Call `load_layered(path)` and assign `boards.backend = config.backend`; do not copy the class into a game.
