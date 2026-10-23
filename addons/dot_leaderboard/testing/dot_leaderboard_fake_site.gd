class_name DotLeaderboardFakeSite
extends RefCounted

## An in-process stand-in for the site's leaderboard endpoints, for tests: pass it as a manager's
## `backbone_client` or a store's `client`. It enforces declare-before-submit like the real site.

const DEFINE := "leaderboard/define"
const SUBMIT := "leaderboard/submit"
const BOARD := "leaderboard/board"

## Scopes the fake integration holds ("LEADERBOARD_READ", "LEADERBOARD_WRITE"); empty means all.
var granted_scopes := PackedStringArray()
## Frames each call waits, so a caller that forgets to await is caught. 0 answers at once.
var latency_frames := 1
## Forces every answer to this HTTP status when not 0.
var force_status := 0
## Requests received: {method, path, query, body}.
var seen: Array = []
## "board|scope" -> {kind, rows: {player: {name, value, setAt}}}
var boards := {}

var _tree: SceneTree


func _init(tree: SceneTree = null) -> void:
	_tree = tree


## Number of POSTs received (defines and submits).
func posts() -> int:
	var n := 0
	for r in seen:
		if r["method"] == "POST":
			n += 1
	return n


func post_integration(path: String, body: Dictionary) -> DotResult:
	await _wait()
	return _answer(handle("POST", path, {}, body))


func get_integration(path: String, query: Dictionary) -> DotResult:
	await _wait()
	return _answer(handle("GET", path, query, null))


## Answers one request synchronously as {status, reply}; a transport can use this directly.
func handle(method: String, path: String, query: Dictionary, body: Variant) -> Dictionary:
	seen.append({"method": method, "path": path, "query": query, "body": body})
	if force_status != 0:
		return {"status": force_status, "reply": {"error": "forced"}}
	var need := "LEADERBOARD_READ" if method == "GET" else "LEADERBOARD_WRITE"
	if not granted_scopes.is_empty() and not granted_scopes.has(need):
		return {"status": 403, "reply": {"error": "Missing scope %s." % need}}

	if path.ends_with(DEFINE):
		for b in body["boards"]:
			var key := _key(str(b["key"]), b.get("scope", {}))
			if not boards.has(key):
				boards[key] = {"kind": b["kind"], "rows": {}}
		return {"status": 200, "reply": {"ok": true}}
	if path.ends_with(SUBMIT):
		var refused := []
		for e in body["entries"]:
			var key := _key(str(e["board"]), e.get("scope", {}))
			if not boards.has(key):
				refused.append("%s: no such board — declare it first." % key)
				continue
			boards[key]["rows"][str(e["player"])] = {
				"name": e.get("name", ""), "value": e["value"], "setAt": int(e.get("setAt", 1))}
		return {"status": 200, "reply": {"ok": true, "accepted": body["entries"].size() - refused.size(), "refused": refused}}
	if path.ends_with(BOARD):
		var key := "%s|%s" % [query.get("board", ""), query.get("scope", "")]
		if not boards.has(key):
			return {"status": 404, "reply": {"error": "No such leaderboard."}}
		return {"status": 200, "reply": _read(key, query)}
	return {"status": 404, "reply": {"error": "No such endpoint."}}


func _wait() -> void:
	if latency_frames <= 0:
		return
	var tree := _tree if _tree != null else Engine.get_main_loop() as SceneTree
	for i in latency_frames:
		await tree.process_frame


func _answer(res: Dictionary) -> DotResult:
	if int(res["status"]) >= 400:
		return DotResult.failure(DotError.from_http(int(res["status"]), JSON.stringify(res["reply"])))
	return DotResult.success(res["reply"])


func _key(board: String, scope: Dictionary) -> String:
	var keys := scope.keys()
	keys.sort()
	var parts := PackedStringArray()
	for k in keys:
		parts.append("%s=%s" % [k, scope[k]])
	return "%s|%s" % [board, ";".join(parts)]


func _read(key: String, query: Dictionary) -> Dictionary:
	var board: Dictionary = boards[key]
	var ascending: bool = board["kind"] in ["TIME", "PENALTY"]
	var rows: Dictionary = board["rows"]
	var ids: Array = rows.keys()
	ids.sort_custom(func(a: String, b: String) -> bool:
		var va: float = rows[a]["value"]
		var vb: float = rows[b]["value"]
		if va == vb:
			return a < b
		return va < vb if ascending else va > vb)
	var out := []
	var offset := int(query.get("offset", 0))
	for i in range(offset, mini(ids.size(), offset + int(query.get("limit", 25)))):
		out.append(_row(rows, ids[i], i + 1))
	var mine: Variant = null
	var player := str(query.get("player", ""))
	if player != "" and rows.has(player):
		mine = _row(rows, player, ids.find(player) + 1)
	return {"ok": true, "board": {"entries": ids.size()}, "rows": out, "self": mine}


func _row(rows: Dictionary, player: String, rank: int) -> Dictionary:
	var r: Dictionary = rows[player]
	return {"rank": rank, "player": player, "name": r["name"], "value": r["value"], "setAt": r["setAt"], "meta": null}
