extends Node

## The backbone store against a fake website-city in this process, through the real
## dot-auth DotBackboneClient (so DotHttp and the HTTPRequest path are exercised).
##
## [codeblock]
## godot --headless --path . res://examples/leaderboard_backbone_test.tscn
## [/codeblock]

const CHECKS := 41
const SECTIONS := 7
const PORT := 18942

var _passed := 0
var _failed := 0
var _entered := 0
var _completed := 0

var _server := TCPServer.new()
var _conns: Array = []
## Requests the fake saw: {method, path, query, body, auth}.
var _seen: Array = []
## Fake state: "board|scope" -> {kind, rows: {player: {name, value, setAt}}}.
var _boards: Dictionary = {}
var _force_status := 0
var _client: Node = null


func _ready() -> void:
	DotLog.set_level(DotLog.Level.ERROR)
	_run.call_deferred()


func _process(_delta: float) -> void:
	while _server.is_listening() and _server.is_connection_available():
		_conns.append({"peer": _server.take_connection(), "buf": PackedByteArray()})
	for conn in _conns.duplicate():
		var peer: StreamPeerTCP = conn["peer"]
		peer.poll()
		var n := peer.get_available_bytes()
		if n > 0:
			# A packed array in a dictionary is a copy; assign it back.
			var chunk: PackedByteArray = conn["buf"]
			chunk.append_array(peer.get_data(n)[1])
			conn["buf"] = chunk
		if _complete(conn["buf"]):
			_respond(peer, conn["buf"])
			_conns.erase(conn)


func _run() -> void:
	print("dot-leaderboard backbone store test")
	if _server.listen(PORT, "127.0.0.1") != OK:
		print("ERROR: cannot listen on %d" % PORT)
		get_tree().quit(1)
		return

	var config := DotAuthConfig.new()
	config.backbone_url = "http://127.0.0.1:%d" % PORT
	config.integration_token = "test-token"
	_client = DotBackboneClient.new()
	_client.config = config
	_client.auto_report = false
	_client.register_as = &""
	add_child(_client)
	_client.start()

	await _test_define_and_submit()
	await _test_reads()
	await _test_around_me()
	await _test_manager_backend()
	await _test_failures()
	await _test_no_client()
	_test_key_split()

	print("")
	print("%d passed, %d failed" % [_passed, _failed])
	print("%d of %d sections ran to their last line" % [_completed, _entered])
	if _entered != SECTIONS or _completed != _entered or _passed + _failed != CHECKS:
		print("ERROR: %d sections (%d done, want %d), %d checks (want %d)" % [
			_entered, _completed, SECTIONS, _passed + _failed, CHECKS])
		get_tree().quit(1)
		return
	get_tree().quit(1 if _failed > 0 else 0)


func _section(title: String) -> void:
	_entered += 1
	print(title)


func _done() -> void:
	_completed += 1


func _check(ok: bool, what: String, detail: String = "") -> void:
	if ok:
		_passed += 1
		print("  ok    %s" % what)
	else:
		_failed += 1
		print("  FAIL  %s %s" % [what, detail])


func _board() -> DotLeaderboardDef:
	var board := DotLeaderboardDef.make(&"fastest", DotLeaderboardDef.Kind.TIME)
	board.display_name = "Fastest"
	board.publish = true
	return board.scoped({"map": "surf_a"})


func _store() -> DotLeaderboardStoreBackbone:
	return DotLeaderboardStoreBackbone.with_client(_client)


func _put(store: DotLeaderboardStoreBackbone, board: DotLeaderboardDef, player: String, value: float) -> DotResult:
	return await store.put(DotLeaderboardEntry.make(board.key(), StringName(player), player.capitalize(), value))


# --- Sections --------------------------------------------------------------

func _test_define_and_submit() -> void:
	_section("define and submit")
	var store := _store()
	var board := _board()
	var res := await store.declare(board)
	_check(res.ok, "declare succeeds", str(res.error.message if not res.ok else ""))
	_check(_seen.size() == 1 and _seen[0]["path"] == "/api/integration/v1/leaderboard/define", "define hit the define endpoint")
	_check(_seen[0]["auth"] == "Bearer test-token", "the integration token rides as a bearer header")
	var wire: Dictionary = _seen[0]["body"]["boards"][0]
	_check(wire["key"] == "fastest" and wire["kind"] == "TIME", "define carries key and kind name")
	_check(wire["scope"] == {"map": "surf_a"}, "define carries the scope as a map")

	await store.declare(board)
	_check(_seen.size() == 1, "a second declare of the same board sends nothing")

	res = await _put(store, board, "ann", 12.5)
	_check(res.ok and res.value == null, "put succeeds")
	var body: Dictionary = _seen[1]["body"]
	_check(_seen[1]["path"].ends_with("leaderboard/submit") and body["overwrite"] == true, "submit goes to submit, overwriting")
	_check(body["entries"][0]["board"] == "fastest" and body["entries"][0]["scope"] == {"map": "surf_a"}, "entry names the board and scope separately")
	_check(body["entries"][0]["player"] == "ann" and is_equal_approx(body["entries"][0]["value"], 12.5), "entry carries player and value")
	_check(body.has("ts") and _seen[1]["nonce"] != "", "the client stamps ts and a nonce")

	var ghost := DotLeaderboardDef.make(&"nope", DotLeaderboardDef.Kind.TIME)
	res = await _put(store, ghost, "ann", 1.0)
	_check(not res.ok and res.error.code == DotError.CODE_INVALID, "an undeclared board is refused with the site's reason")
	_done()


func _test_reads() -> void:
	_section("top-N and entry_for")
	var store := _store()
	var board := _board()
	await _put(store, board, "bob", 10.0)
	await _put(store, board, "cy", 15.0)
	var top := await store.top(board, 2)
	_check(top.ok and top.value.size() == 2, "top(2) returns two entries")
	_check(top.value[0].player_id == &"bob" and top.value[0].rank == 1, "best first with rank 1")
	_check(top.value[1].player_id == &"ann" and top.value[1].rank == 2, "second is ann at 12.5")
	_check(is_equal_approx(top.value[0].value, 10.0) and top.value[0].board_key == board.key(), "entry fields map back")
	var q: Dictionary = _seen.back()["query"]
	_check(q["board"] == "fastest" and q["scope"] == "map=surf_a" and q["limit"] == "2" and q["offset"] == "0", "the read query carries board, scope, offset, limit")
	var mine := await store.entry_for(board, &"cy")
	_check(mine.ok and mine.value.rank == 3 and is_equal_approx(mine.value.value, 15.0), "entry_for returns the player's row with rank")
	var none := await store.entry_for(board, &"nobody")
	_check(none.ok and none.value == null, "no entry is a success carrying null")
	var count := await store.count_on(board)
	_check(count.ok and count.value == 3, "count_on reads the board's entry count")
	var ranked := await store.rank_entry(board, &"bob")
	_check(ranked.ok and ranked.value == 1, "rank_entry gives the rank")
	_done()


func _test_around_me() -> void:
	_section("around me")
	var store := _store()
	var board := _board()
	for i in range(10):
		await _put(store, board, "p%02d" % i, 20.0 + i)
	# bob 10, ann 12.5, cy 15 are above; p00 is rank 4, p05 rank 9.
	var around := await store.around(board, &"p05", 2)
	_check(around.ok and around.value.size() == 5, "around returns 2*radius+1 rows")
	_check(around.value[0].rank == 7 and around.value[2].player_id == &"p05" and around.value[4].rank == 11, "window is centred on the player")
	var edge := await store.around(board, &"bob", 2)
	_check(edge.ok and edge.value[0].player_id == &"bob", "near the top the window starts at rank 1")
	var absent := await store.around(board, &"ghost", 2)
	_check(absent.ok and absent.value[0].rank == 1, "an unranked player gets the top")
	_done()


func _test_manager_backend() -> void:
	_section("manager selects the backend")
	var manager := DotLeaderboardManager.new()
	manager.backend = "backbone"
	manager.backbone_client = _client
	manager.report_to_backbone = true
	manager.report_interval = 0.0
	add_child(manager)
	_check(manager.store is DotLeaderboardStoreBackbone, "backend=backbone builds the backbone store")
	var def := DotLeaderboardDef.make(&"fastest", DotLeaderboardDef.Kind.TIME)
	def.display_name = "Fastest"
	def.publish = true
	manager.define(def)
	var before := _seen.size()
	var res := await manager.submit_async(&"fastest", {"map": "surf_b"}, &"dee", "Dee", 9.0)
	_check(res.ok and res.value.rank == 1, "submit_async declares, writes and ranks", str(res.error.message if not res.ok else ""))
	var posts := 0
	for r in _seen.slice(before):
		if r["method"] == "POST":
			posts += 1
	_check(posts == 2, "one define and one submit, nothing duplicated by the reporter", str(posts))
	_check(manager.reporter.queued() == 0, "the report queue stays empty")
	var worse := await manager.submit_async(&"fastest", {"map": "surf_b"}, &"dee", "Dee", 11.0)
	_check(worse.ok and is_equal_approx(worse.value.value, 9.0), "a worse time keeps the held one")
	var page := await manager.page_async(&"fastest", {"map": "surf_b"})
	_check(page.ok and page.value.size() == 1, "page_async reads through the store")
	var sync_page := manager.page(&"fastest", {"map": "surf_b"})
	_check(not sync_page.ok and sync_page.error.code == DotError.CODE_UNSUPPORTED, "the synchronous form refuses a remote store")
	var memory := DotLeaderboardManager.new()
	memory.report_interval = 0.0
	add_child(memory)
	_check(memory.store is DotLeaderboardStoreMemory, "memory stays the default")
	_done()


func _test_failures() -> void:
	_section("failures")
	var store := _store()
	var board := _board()
	_force_status = 403
	var res := await store.page(board)
	_check(not res.ok and res.error.http_status == 403, "a 403 surfaces with its status")
	_force_status = 500
	res = await store.entry_for(board, &"ann")
	_check(not res.ok, "a server error is a failure, not a null entry")
	_force_status = 404
	res = await store.entry_for(board, &"ann")
	_check(res.ok and res.value == null, "an unknown board reads as no entry")
	_force_status = 0
	_done()


func _test_no_client() -> void:
	_section("no client")
	var store := DotLeaderboardStoreBackbone.new()
	var res := await store.page(_board())
	_check(not res.ok and res.error.code == DotError.CODE_STATE, "reads without a client fail with state")
	res = await _put(store, _board(), "ann", 1.0)
	_check(not res.ok and res.error.code == DotError.CODE_STATE, "writes without a client fail with state")
	_check(not (await store.stats_for(&"a")).ok, "statistics are unsupported")
	_done()


func _test_key_split() -> void:
	_section("key split")
	var parts := DotLeaderboardStoreBackbone.split_key("fastest|map=a;style=b")
	_check(parts["board"] == "fastest" and parts["scope"] == {"map": "a", "style": "b"}, "scope parsed")
	_check(DotLeaderboardStoreBackbone.split_key("plain")["scope"] == {}, "unscoped key has an empty scope")
	_done()


# --- The fake site ---------------------------------------------------------

func _complete(buf: PackedByteArray) -> bool:
	var text := buf.get_string_from_utf8()
	var split := text.find("\r\n\r\n")
	if split < 0:
		return false
	var length := 0
	for line in text.substr(0, split).split("\r\n"):
		if line.to_lower().begins_with("content-length:"):
			length = int(line.split(":")[1].strip_edges())
	return buf.size() >= split + 4 + length


func _respond(peer: StreamPeerTCP, buf: PackedByteArray) -> void:
	var text := buf.get_string_from_utf8()
	var split := text.find("\r\n\r\n")
	var lines := text.substr(0, split).split("\r\n")
	var request := lines[0].split(" ")
	var url: String = request[1]
	var path := url.get_slice("?", 0)
	var query := {}
	if url.contains("?"):
		for pair in url.get_slice("?", 1).split("&"):
			query[pair.get_slice("=", 0).uri_decode()] = pair.get_slice("=", 1).uri_decode()
	var auth := ""
	var nonce := ""
	for line in lines:
		if line.to_lower().begins_with("authorization:"):
			auth = line.substr(14).strip_edges()
		if line.to_lower().begins_with("x-tmc-nonce:"):
			nonce = line.substr(12).strip_edges()
	var body: Variant = JSON.parse_string(text.substr(split + 4)) if request[0] == "POST" else null
	_seen.append({"method": request[0], "path": path, "query": query, "body": body, "auth": auth, "nonce": nonce})

	var status := 200
	var reply: Dictionary = {}
	if _force_status != 0:
		status = _force_status
		reply = {"error": "forced"}
	elif path.ends_with("leaderboard/define"):
		for b in body["boards"]:
			_boards["%s|%s" % [b["key"], _scope_string(b.get("scope", {}))]] = {"kind": b["kind"], "rows": {}}
		reply = {"ok": true}
	elif path.ends_with("leaderboard/submit"):
		var refused := []
		for e in body["entries"]:
			var key := "%s|%s" % [e["board"], _scope_string(e.get("scope", {}))]
			if not _boards.has(key):
				refused.append("%s: no such board — declare it first." % key)
				continue
			_boards[key]["rows"][e["player"]] = {"name": e["name"], "value": e["value"], "setAt": int(e.get("setAt", 1))}
		reply = {"ok": true, "accepted": body["entries"].size(), "refused": refused}
	elif path.ends_with("leaderboard/board"):
		var key := "%s|%s" % [query["board"], query["scope"]]
		if not _boards.has(key):
			status = 404
			reply = {"error": "No such leaderboard."}
		else:
			reply = _read_board(key, query)
	else:
		status = 404
	var payload := JSON.stringify(reply).to_utf8_buffer()
	var head := "HTTP/1.1 %d X\r\nContent-Type: application/json\r\nContent-Length: %d\r\nConnection: close\r\n\r\n" % [status, payload.size()]
	peer.put_data(head.to_utf8_buffer() + payload)
	peer.disconnect_from_host()


func _scope_string(scope: Dictionary) -> String:
	var keys := scope.keys()
	keys.sort()
	var parts := PackedStringArray()
	for k in keys:
		parts.append("%s=%s" % [k, scope[k]])
	return ";".join(parts)


func _read_board(key: String, query: Dictionary) -> Dictionary:
	var board: Dictionary = _boards[key]
	var ascending: bool = board["kind"] in ["TIME", "PENALTY"]
	var ids: Array = board["rows"].keys()
	ids.sort_custom(func(a: String, b: String) -> bool:
		var va: float = board["rows"][a]["value"]
		var vb: float = board["rows"][b]["value"]
		if va == vb:
			return a < b
		return va < vb if ascending else va > vb)
	var rows := []
	var offset := int(query["offset"])
	for i in range(offset, mini(ids.size(), offset + int(query["limit"]))):
		rows.append(_row(board, ids[i], i + 1))
	var mine: Variant = null
	var player: String = query.get("player", "")
	if player != "" and board["rows"].has(player):
		mine = _row(board, player, ids.find(player) + 1)
	return {"ok": true, "board": {"entries": ids.size()}, "rows": rows, "self": mine}


func _row(board: Dictionary, player: String, rank: int) -> Dictionary:
	var r: Dictionary = board["rows"][player]
	return {"rank": rank, "player": player, "name": r["name"], "value": r["value"], "setAt": r["setAt"], "meta": null}
