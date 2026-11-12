extends Node
## The browser and bridge handle Google credentials. The game only receives the
## verified testnet account after the player confirms the pairing code.

signal changed

var account_id := ""
var signed_in := false
var busy := false
var message := ""
var ownership_message := ""
var browser_url := ""
var _attempt := 0
var _bridge := ""
var _session := ""
var _owns_shotgun := false
var _ownership_deadline := 0
var _last_check := -3000
var _checking := false

const ENTITLEMENT_CACHE_MS := 600_000


func sign_in(method := "google") -> void:
	if busy:
		return
	var bridge := OS.get_environment("DEAD_ROUTE_WALLET_URL")
	if bridge.is_empty():
		bridge = str(ProjectSettings.get_setting_with_override("dead_route/wallet/bridge_url"))
	if bridge.is_empty() and not OS.has_feature("web") and not OS.has_feature("mobile"):
		bridge = "http://127.0.0.1:8787"
	bridge = bridge.trim_suffix("/")
	if not bridge.begins_with("https://") and bridge != "http://127.0.0.1:8787":
		_finish("A wallet bridge URL is required in this build.")
		return
	_attempt += 1
	var attempt := _attempt
	busy = true
	message = "Contacting the wallet service..."
	changed.emit()
	var flow := await _post(bridge + "/api/device/start", {"method": method})
	if attempt != _attempt:
		return
	if not flow.has_all(["id", "secret", "code"]):
		_finish(str(flow.get("error", "The wallet service is offline. See the README for setup.")))
		return
	browser_url = bridge + "/wallet?flow=" + str(flow.id).uri_encode()
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
			account_id = str(result.get("account_id", ""))
			_session = str(result.get("session", ""))
			_read_entitlement(result)
			_finish("")
		else:
			_finish(str(result.get("error", "Could not complete sign-in. Please try again.")))
		return
	if attempt == _attempt:
		_finish("The sign-in code expired. Start a new sign-in.")


func sign_out() -> void:
	signed_in = false
	account_id = ""
	_session = ""
	_owns_shotgun = false
	ownership_message = ""
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
	var result := await _post(_bridge + "/api/entitlement", {"session": token})
	_checking = false
	if token == _session:
		_read_entitlement(result)
		changed.emit()


func _read_entitlement(result: Dictionary) -> void:
	_owns_shotgun = result.get("shotgun_owned", false)
	_ownership_deadline = Time.get_ticks_msec() + ENTITLEMENT_CACHE_MS
	ownership_message = str(result.get("ownership_message", result.get(
		"error", "Could not verify shotgun ownership.")))


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
