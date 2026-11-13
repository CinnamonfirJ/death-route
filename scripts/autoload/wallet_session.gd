extends Node
## The browser and bridge handle Google credentials. The game only receives the
## game session and item access after the player confirms the pairing code.

signal changed

var signed_in := false
var busy := false
var message := ""
var browser_url := ""
var _attempt := 0
var _bridge := ""
var _session := ""
var _owns_shotgun := false
var _ownership_deadline := 0
var _last_check := -3000
var _checking := false

const ENTITLEMENT_CACHE_MS := 600_000


func sign_in() -> void:
	if busy:
		return
	var bridge := OS.get_environment("DEAD_ROUTE_WALLET_URL")
	if bridge.is_empty():
		bridge = str(ProjectSettings.get_setting_with_override("dead_route/wallet/bridge_url"))
	if bridge.is_empty() and not OS.has_feature("web") and not OS.has_feature("mobile"):
		bridge = "http://127.0.0.1:8787"
	bridge = bridge.trim_suffix("/")
	if not bridge.begins_with("https://") and bridge != "http://127.0.0.1:8787":
		_finish("Google sign-in is unavailable right now. You can play as a guest.")
		return
	_attempt += 1
	var attempt := _attempt
	busy = true
	message = "Starting Google sign-in..."
	changed.emit()
	var flow := await _post(bridge + "/api/device/start", {})
	if attempt != _attempt:
		return
	if not flow.has_all(["id", "secret", "code"]):
		_finish("Google sign-in is unavailable right now. You can play as a guest.")
		return
	browser_url = bridge + "/signin?flow=" + str(flow.id).uri_encode()
	if not OS.has_feature("web"):
		open_browser()
	message = "Enter code %s in your browser to continue." % str(flow.code)
	changed.emit()
	var deadline := Time.get_ticks_msec() + 300_000
	while attempt == _attempt and Time.get_ticks_msec() < deadline:
		await get_tree().create_timer(2.0).timeout
		if attempt != _attempt:
			return
		var result := await _post(bridge + "/api/device/poll", {"id": flow.id, "secret": flow.secret})
		if attempt != _attempt:
			return
		if result.is_empty() or result.get("pending", false):
			continue
		if result.get("signed_in", false):
			_bridge = bridge
			signed_in = true
			_session = str(result.get("session", ""))
			_read_entitlement(result)
			_finish("")
		else:
			_finish("Could not complete Google sign-in. Try again or play as a guest.")
		return
	if attempt == _attempt:
		_finish("The sign-in code expired. Start a new sign-in.")


func sign_out() -> void:
	signed_in = false
	_session = ""
	_owns_shotgun = false
	cancel_sign_in()


func cancel_sign_in() -> void:
	_attempt += 1
	_finish("")


func has_shotgun() -> bool:
	return _owns_shotgun and Time.get_ticks_msec() < _ownership_deadline


func refresh_ownership() -> void:
	var now := Time.get_ticks_msec()
	if _session.is_empty() or _checking or now - _last_check < 2500:
		return
	_checking = true
	_last_check = now
	var token := _session
	for retry in 6:
		var result := await _post(_bridge + "/api/entitlement", {"session": token})
		if token != _session:
			break
		if not result.get("pending", false):
			if result.has("shotgun_owned"):
				_read_entitlement(result)
				changed.emit()
			break
		await get_tree().create_timer(5.0).timeout
	_checking = false


func _read_entitlement(result: Dictionary) -> void:
	_owns_shotgun = result.get("shotgun_owned", false)
	_ownership_deadline = Time.get_ticks_msec() + ENTITLEMENT_CACHE_MS


func open_browser() -> void:
	if not browser_url.is_empty():
		OS.shell_open(browser_url)


func _finish(status: String) -> void:
	busy = false
	browser_url = ""
	message = status
	changed.emit()


func _post(url: String, payload: Dictionary) -> Dictionary:
	var http := HTTPRequest.new()
	http.timeout = 12.0
	http.max_redirects = 0
	add_child(http)
	var err := http.request(url, ["Content-Type: application/json"],
		HTTPClient.METHOD_POST, JSON.stringify(payload))
	if err != OK:
		http.queue_free()
		return {}
	var response: Array = await http.request_completed
	http.queue_free()
	if response[0] != HTTPRequest.RESULT_SUCCESS:
		return {}
	var data: Variant = JSON.parse_string(response[3].get_string_from_utf8())
	return data if data is Dictionary else {}
