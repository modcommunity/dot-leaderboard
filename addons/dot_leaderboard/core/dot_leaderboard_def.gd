@tool
class_name DotLeaderboardDef
extends Resource

## One board: what it measures, how it sorts, and what it is scoped to.
##
## [b]A board is a definition, not a table.[/b] "Fastest time on surf_beginner, main
## track, normal style" and "most kills this week" and "highest arena score" are the
## same shape — an ordering over one number per player — and the only things that
## differ are the ordering, the scope and how the number is rendered. Modelling them
## as one definition means a site, a HUD and a store all handle a game's own invented
## board without any of them being changed.
##
## [b]The scope is a set of string keys, not a fixed set of columns.[/b] A timer
## scopes by map, track and style; a deathmatch by map and mode; a 2D game by nothing
## at all. Fixed columns would mean every consumer carrying a track field that most
## games leave at zero, and a game with a fourth dimension having nowhere to put it.

## How the board is ordered, and what the number means.
enum Kind {
	## Lower is better, rendered as a time. A speedrun board.
	TIME,
	## Higher is better, rendered as an integer. Kills, wins, distance.
	SCORE,
	## Higher is better, rendered with decimals. Ranking points, ratios.
	POINTS,
	## Lower is better, rendered as an integer. Deaths, attempts, penalties.
	PENALTY,
}

@export_group("Identity")

## Stable id. What entries are filed under and what a URL names.
##
## [b]Never renamed[/b], for the reason a map id is not: every entry names its board
## by this.
@export var id: StringName = &""

@export var display_name: String = ""

@export_multiline var description: String = ""

@export var kind: Kind = Kind.TIME

@export_group("Scope")

## What this board is per: [code]{"map": "surf_beginner", "track": "0"}[/code].
##
## [b]Strings, and string keys.[/b] A scope crosses a network, goes into a database
## key and comes back out of a URL query, and a typed value would be four conversions
## with three chances to disagree about how a zero renders. The store composes the key
## with [method scope_key], which sorts the keys — so two callers that built the same
## scope in different orders address the same board.
@export var scope: Dictionary = {}

@export_group("Presentation")

## Decimals to render. Three for a time, because this genre is decided by
## thousandths.
@export_range(0, 6, 1) var decimals: int = 3

## A unit shown after the value, e.g. [code]m/s[/code]. Empty for none.
@export var unit: String = ""

## How many entries a page holds by default.
@export_range(1, 500, 1) var page_size: int = 25

## Whether the board is shown at all. Off keeps its entries without listing it.
@export var visible: bool = true

## Whether entries may be reported to the backbone for a site leaderboard.
##
## [b]Off by default, and deliberately.[/b] Publishing a board sends player names and
## scores off the server. That should be a decision somebody made, not something that
## happens because a default was permissive.
@export var publish: bool = false


static func make(
	p_id: StringName, p_kind: Kind, p_scope: Dictionary = {}
) -> DotLeaderboardDef:
	var board := DotLeaderboardDef.new()
	board.id = p_id
	board.kind = p_kind
	board.scope = p_scope
	board.decimals = 3 if p_kind == Kind.TIME else 0
	return board


## Whether a lower value is a better one.
func lower_is_better() -> bool:
	return kind == Kind.TIME or kind == Kind.PENALTY


## Whether [param challenger] is a better value than [param incumbent].
##
## [b]Strict.[/b] An equal value is not an improvement, and treating it as one moves
## the date, resets whatever the entry carries and reorders the board for a result
## that was not better.
func beats(challenger: float, incumbent: float) -> bool:
	return (
		challenger < incumbent if lower_is_better() else challenger > incumbent
	)


## The canonical key for this board's scope.
##
## [b]Sorted, so two callers that built the same scope in different orders address the
## same board.[/b] A dictionary's iteration order in GDScript is insertion order, so
## without the sort `{"map": x, "track": y}` and `{"track": y, "map": x}` are two
## different boards holding half the entries each — and nothing anywhere errors.
func scope_key() -> String:
	var keys := scope.keys()
	keys.sort()

	var parts := PackedStringArray()

	for key in keys:
		parts.append("%s=%s" % [str(key), str(scope[key])])

	return ";".join(parts)


## The full address of this board: its id plus its scope.
func key() -> String:
	var suffix := scope_key()
	return String(id) if suffix == "" else "%s|%s" % [String(id), suffix]


## Renders a value the way this board means it.
func format_value(value: float) -> String:
	if kind == Kind.TIME:
		return _format_time(value)

	var text := String.num(value, decimals)

	return text if unit == "" else "%s %s" % [text, unit]


## A time as [code]m:ss.mmm[/code], the same rendering dot-timer uses.
##
## Duplicated rather than imported, because dot-timer is optional here and naming the
## class would make this addon fail to parse without it. The duplication is eight
## lines and the alternative is a hard dependency between two things that are
## otherwise independent.
static func _format_time(seconds: float) -> String:
	var negative := seconds < 0.0
	var total := absf(seconds)

	var hours := int(total / 3600.0)
	var minutes := int(fmod(total, 3600.0) / 60.0)
	var rest := fmod(total, 60.0)

	var text := (
		"%d:%02d:%06.3f" % [hours, minutes, rest] if hours > 0
		else "%d:%06.3f" % [minutes, rest]
	)

	return ("-" if negative else "") + text


func validate() -> DotResult:
	if id == &"":
		return DotResult.fail(DotError.CODE_INVALID, "A board needs an id.")

	for key in scope:
		if not (key is String or key is StringName):
			return DotResult.fail(
				DotError.CODE_INVALID,
				"A board's scope keys must be strings.",
				str(key)
			)

	return DotResult.success(null)


func to_dictionary() -> Dictionary:
	return {
		"id": String(id),
		"name": display_name,
		"description": description,
		"kind": kind,
		# Duplicated, not handed out. A Dictionary is a reference in GDScript, so
		# returning this one lets a caller who serialises a board and edits the
		# result edit the BOARD — and `scoped()`, which round-trips through here,
		# then wrote every scope it was given straight into the shared template.
		# The self-test caught it: two scoped boards and the template were one
		# object, so every board on the server had the last scope anybody asked for.
		"scope": scope.duplicate(true),
		"decimals": decimals,
		"unit": unit,
		"page_size": page_size,
		"visible": visible,
		"publish": publish,
	}


static func from_dictionary(data: Dictionary) -> DotLeaderboardDef:
	var board := DotLeaderboardDef.new()

	board.id = StringName(str(data.get("id", "")))
	board.display_name = str(data.get("name", ""))
	board.description = str(data.get("description", ""))
	board.kind = _to_kind(data.get("kind", Kind.TIME))
	board.decimals = clampi(int(data.get("decimals", 3)), 0, 6)
	board.unit = str(data.get("unit", ""))
	board.page_size = clampi(int(data.get("page_size", 25)), 1, 500)
	board.visible = bool(data.get("visible", true))
	board.publish = bool(data.get("publish", false))

	var scope_value: Variant = data.get("scope", {})
	board.scope = (
		(scope_value as Dictionary).duplicate(true) if scope_value is Dictionary
		else {}
	)

	return board


## The kind's name, which is what leaves the server: "TIME", "SCORE", "POINTS",
## "PENALTY" — the backbone's enum, spelled the same on purpose.
static func kind_name(p_kind: Kind) -> String:
	return Kind.keys()[int(p_kind)] if int(p_kind) >= 0 and int(p_kind) < Kind.size() else "TIME"


static func _to_kind(value: Variant) -> Kind:
	var raw := int(value)
	return raw as Kind if raw >= 0 and raw < Kind.size() else Kind.SCORE


## A copy of this board scoped to something else.
##
## The usual case: one definition of "fastest time", instantiated per map, track and
## style. Copying rather than mutating means the definition can be a shared resource.
func scoped(extra: Dictionary) -> DotLeaderboardDef:
	var out := DotLeaderboardDef.from_dictionary(to_dictionary())

	for key in extra:
		out.scope[str(key)] = str(extra[key])

	return out


func describe() -> Dictionary:
	return {
		"id": String(id),
		"kind": Kind.keys()[kind],
		"scope": scope_key(),
		"publish": publish,
	}


func _to_string() -> String:
	return "DotLeaderboardDef(%s)" % key()
