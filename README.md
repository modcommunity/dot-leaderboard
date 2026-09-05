This is the **leaderboard** asset for TMC's **Dot** collection. It is where a number a player earned goes, and the road from a game server to the TMC backbone.

This collection of assets provides modular building blocks for creating games and applications within the TMC ecosystem, ensuring consistency and interoperability across all `dot-*` assets. This includes core functionality, networking, authentication, cloud integration, and more.

**These assets are COMPLETELY OPEN SOURCE**. You are free to use, modify, and distribute them under the terms of the MIT license. The only thing not open source is the back-end web infrastructure. So if you opt into using your own authentication backend instead of integrating with TMC, you will need to build and integrate your own back-end infrastructure.

## From Maintainer & WARNING
This asset, along with all the others, was built initially with **Claude Code** and will continue to be maintained and extended using it. This is because I (`gamemann`) cannot build the entire TMC platform alone (I wish I could lol).

**Please treat this as partially tested.** Every asset has its own headless test suite and those suites pass, but very little of this has been in front of real players yet. Expect rough edges, and please report anything you run into.

I intend on reviewing code, testing, and editing documentation regularly. If you're interested in helping out, please let me know!

## Leaderboards and Player Statistics
**Leaderboards and player statistics for any Godot game**, and the road from a game
server to the TMC backbone.

A board is an ordering over one number per player, scoped by string keys — so
"fastest time on surf_beginner, main track, normal style", "most kills this week" and
"highest arena score" are one thing with three configurations.

## What it gives you

- **Boards** with four orderings (`TIME`, `SCORE`, `POINTS`, `PENALTY`), a scope of
  your choosing, and rendering that knows a time from a score.
- **Ranks materialised on write**, because "am I first" is asked far more often than a
  board is written to.
- **Per-player statistics** — counters, bests and lowests — with a bridge that turns
  any counter into a board.
- **A store interface** with an in-memory implementation. Point it at a database when
  you outgrow it; nothing above changes.
- **A reporter** that batches submissions to the backbone, keeps its queue through an
  outage, and is bounded so a backbone down for a day cannot exhaust the server.

## Installing

Copy `addons/dot_leaderboard/` and [`dot-core`](../dot-core)'s `addons/dot_core/` into
your project, and enable dot-leaderboard in *Project → Project Settings → Plugins*.

[dot-auth](../dot-auth), [dot-timer](../dot-timer) and dot-server are optional and
none is named in the source.

## Five minutes

```gdscript
var boards := DotLeaderboardManager.new()
boards.store = DotLeaderboardStoreMemory.new()
add_child(boards)

var fastest := DotLeaderboardDef.make(&"fastest", DotLeaderboardDef.Kind.TIME)
fastest.display_name = "Fastest time"
fastest.publish = true                # opt in to the site leaderboard
boards.define(fastest)

# one definition, one board per (map, track, style)
await boards.submit(
    &"fastest",
    {"map": "surf_beginner", "track": "0", "style": "normal"},
    player_id, player_name, run.time()
)

var page := await boards.page(&"fastest", {"map": "surf_beginner", "track": "0", "style": "normal"})
for entry in page.value:
    print("%d. %s %s" % [entry.rank, entry.player_name, fastest.format_value(entry.value)])
```

## Statistics

```gdscript
var session := DotStatSet.new()
session.add(&"jumps", stats.jumps)
session.add(&"distance", metres)
session.set_best(&"top_speed", stats.max_speed)

await boards.add_stats(player_id, session)

# and any counter can become a board
await boards.publish_stat(&"most_jumps", {}, player_id, player_name, &"jumps")
```

## Reporting to the site

```gdscript
boards.report_to_backbone = true
boards.reporter.client = backbone_client   # dot-auth's DotBackboneClient
```

Needs the `LEADERBOARD_WRITE` scope on a server- or app-scoped integration. Nothing is
sent per event: entries are queued and flushed in batches, the queue survives an
outage, and it is bounded.

## Documentation

[`CLAUDE.md`](CLAUDE.md) has the design reasoning: why boards and statistics are
different problems, why the manager sorts and the store does not, and the dictionary
aliasing bug the self-test found.

## Validating

```bash
godot --headless --path . --import
godot --headless --path . res://examples/leaderboard_selftest.tscn   # 69 checks
```

## Licence

MIT. See [LICENSE](LICENSE).
