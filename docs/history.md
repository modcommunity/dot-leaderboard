# History

Bugs worth recognising if they come back.

## Every board had the last scope anybody asked for

Found by the suite. **`to_dictionary()` handed out its own `scope` dictionary.** A `Dictionary` is a reference in GDScript, and `scoped()` round-trips through `to_dictionary`/`from_dictionary`, so every scoped board and the template it came from were one object, and every board on the server ended up with the last scope anybody asked for. The same aliasing was then found and fixed in `DotTimerZone.payload`, `DotTimerRecord.splits`/`stats`/`extra` and `DotMapDef.meta`, none of which had a test that would have caught it.

## The two ends had never met

Found by reading. The reporter's payload used this addon's own file format as if it were the wire. `LeaderboardSubmitInput` on the backbone spells the timestamp `setAt` and takes the kind as `"TIME"`; the reporter sent `set_at` and the enum's integer. `LeaderboardDefineInput` names a board by `key`; `to_dictionary()` says `id`. Every request would have been refused by the schema. See [backbone](backbone.md#the-endpoints-and-the-wire-shape).

## Smaller ones

- **Ties ranked by array index**, so identical times were 2nd and 3rd in an unstable order. Ties share a rank now ([design](design.md#why-the-manager-sorts-and-the-store-does-not)).
- **"Keep the best" froze a running total** at the highest value a player ever had. `running_total` and `replace_async` ([design](design.md#running-totals)).
- **The manager never awaited its store**, which only shows against a store that really suspends ([storage](storage.md#why-there-are-_async-forms)).
- **A per-board "last written" slot in the SQL store** was overwritten by a second submission before the first was ranked; `rank_entry` ranks by player ([storage](storage.md#ranks-in-sql)).
