class_name DotStatSet
extends RefCounted

## Per-player counters: kills, distance, jumps, time played, whatever a game counts.
##
## [b]Counters, not a leaderboard.[/b] The two are different problems and conflating
## them is the usual mistake. A leaderboard is "one number per player, ordered"; a
## stat set is "many numbers per player, accumulated". A board is often derived from
## a stat — "most kills" is an ordering over the kills counter — and
## [method DotLeaderboardManager.publish_stat] is how, but a stat that nothing ranks
## is still worth keeping and a board whose value is not a counter is common.
##
## [b]Everything is a float and everything is additive.[/b] A single numeric type
## because these cross a network and a database and go into a JSON body, and an
## int/float split is three conversions with two chances to disagree. Additive because
## merging two servers' figures, or a session's into a lifetime total, is then a
## dictionary walk rather than a per-stat rule — and because a counter that some other
## code decides how to combine is one nobody can sum.
##
## Set-rather-than-add exists for the two that are genuinely not counters — a best
## and a last — and both say so in their names.

## The counters, by id.
var values: Dictionary = {}


func add(id: StringName, amount: float = 1.0) -> float:
	var next := float(values.get(id, 0.0)) + amount
	values[id] = next
	return next


func get_value(id: StringName, fallback: float = 0.0) -> float:
	return float(values.get(id, fallback))


func has(id: StringName) -> bool:
	return values.has(id)


## Sets a counter outright. For a gauge rather than a counter.
func set_value(id: StringName, value: float) -> void:
	values[id] = value


## Keeps the higher of the current value and [param value].
##
## For a best-ever: top speed, longest jump, biggest streak. Separate from
## [method add] because "best" is the one thing that is not additive and quietly
## adding to it produces a number that only ever goes up and means nothing.
func set_best(id: StringName, value: float) -> void:
	if not values.has(id) or value > float(values[id]):
		values[id] = value


## Keeps the lower of the two. For a personal best where lower wins.
func set_lowest(id: StringName, value: float) -> void:
	if not values.has(id) or value < float(values[id]):
		values[id] = value


## Adds another set into this one. For merging a session into a lifetime.
##
## [b]Additive for every key, which is why [method set_best] is a separate concept
## and not a flag.[/b] Merging two "best speed" figures by adding them is nonsense,
## and this method cannot tell — so a game that keeps bests merges those itself, or
## keeps them on a board rather than in a stat set. Named [code]add_from[/code] rather
## than [code]merge[/code] to make that explicit at the call site.
func add_from(other: DotStatSet) -> void:
	if other == null:
		return

	for id in other.values:
		add(id, float(other.values[id]))


func clear() -> void:
	values.clear()


func size() -> int:
	return values.size()


func to_dictionary() -> Dictionary:
	var out := {}

	for id in values:
		out[String(id)] = float(values[id])

	return out


static func from_dictionary(data: Dictionary) -> DotStatSet:
	var out := DotStatSet.new()

	for key in data:
		# Non-numeric values are dropped rather than coerced. This arrives from a
		# file or a network, and `float("banana")` is 0.0 — which silently resets a
		# counter to zero instead of leaving it alone.
		var value: Variant = data[key]

		if value is float or value is int:
			out.values[StringName(str(key))] = float(value)

	return out


func duplicate_stats() -> DotStatSet:
	var out := DotStatSet.new()
	out.values = values.duplicate()
	return out


func describe() -> Dictionary:
	return to_dictionary()


func _to_string() -> String:
	return "DotStatSet(%d counters)" % values.size()
