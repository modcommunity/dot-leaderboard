@tool
class_name DotBoardsConfig
extends DotConfig

## Where a game server's leaderboards live, for any game. Layered like every [DotConfig]:
## defaults, JSON file, environment (`<GAME>_BOARDS_BACKEND`), command line
## (`--<game>_boards_backend`). Build one with [method for_game].

## "memory" keeps boards in this process; "backbone" keeps them on the site (needs a registered backbone client).
@export_enum("memory", "backbone") var backend: String = "memory"

var _game: String = ""
var _cli_separator: String = "_"


## A config for [param game] (e.g. "arena"). [param cli_separator] is the character between the
## words of the command-line flag; "_" gives `--arena_boards_backend`.
static func for_game(game: String, cli_separator: String = "_") -> DotBoardsConfig:
	var config := DotBoardsConfig.new()
	config._game = game
	config._cli_separator = cli_separator
	return config


## The conventional JSON file for [param game]: `user://<game>_boards.json`.
static func json_path_for(game: String) -> String:
	return "user://%s_boards.json" % game


func env_prefix() -> String:
	return "%s_BOARDS_" % _game.to_upper() if _game != "" else ""


func cli_prefix() -> String:
	if _game == "":
		return ""
	return "--%s%sboards%s" % [_game, _cli_separator, _cli_separator]


func validate() -> DotResult:
	if backend != "memory" and backend != "backbone":
		return DotResult.fail(DotError.CODE_INVALID, "backend must be memory or backbone")
	return DotResult.success(null)
