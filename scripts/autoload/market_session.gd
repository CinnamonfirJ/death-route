extends Node
## Camp Market client (autoload `CampMarket`). Talks to the wallet bridge's /api/market endpoints.
##
## Scrap stays in the local save. Commodity balances and the merchants' books live on the bridge,
## which prices everything from economy/pricing_rules.toml and mirrors balance changes to the
## NEP-245 contract in the background. The player clicks Sell or Buy; no wallet popup, no gas.
## Signed-in players trade under their NEAR account; everyone else trades as a guest id.

signal changed
signal trade_completed(result: Dictionary)

const POLL_SECONDS := 4.0
const OFFLINE_MESSAGE := "Camp market offline. Start the wallet bridge (npm --prefix wallet-bridge start)."

var online := false
var message := ""
var day := 1
var market_name := "Survivor Camp Market"
var chain := {"mode": "offline"}
var merchants: Array = []      # bridge snapshot, in pricing-file order
var commodities := {}          # id -> {token_id, name, plural, icon, base_price, description}
var balances := {}             # id -> int, mirrors GameManager.haul once the bridge answers
var history: Array = []
var events: Array = []
var busy := false              # a trade or investment is in flight
var _refreshing := false
var _poll: Timer


func _ready() -> void:
	_poll = Timer.new()
	_poll.wait_time = POLL_SECONDS
	_poll.timeout.connect(refresh)
	add_child(_poll)
	WalletSession.changed.connect(func() -> void:
		if not WalletSession.busy:
			refresh())


## The Garage polls while open so co-op partners' trades show up within seconds.
func start_polling() -> void:
	refresh()
	_poll.start()


func stop_polling() -> void:
	_poll.stop()


func identity() -> Dictionary:
	var token := WalletSession.session_token()
	if not token.is_empty():
		return {"session": token}
	return {"guest_id": GameManager.guest_id}


func account_label() -> String:
	return "Google courier" if WalletSession.signed_in else "Guest courier"


func chain_label() -> String:
	var mode := str(chain.get("mode", "offline"))
	match mode:
		"offline":
			return "offline"
		"ledger-only":
			return "bridge ledger (no contract configured)"
		_:
			return "NEP-245 on %s" % mode


func merchant(id: String) -> Dictionary:
	for m in merchants:
		if m.get("id", "") == id:
			return m
	return {}


func quote(merchant_id: String, commodity: String) -> Dictionary:
	for q in merchant(merchant_id).get("quotes", []):
		if q.get("commodity", "") == commodity:
			return q
	return {}


func commodity_name(id: String, count := 1) -> String:
	var c: Dictionary = commodities.get(id, {})
	if c.is_empty():
		return GameManager.commodity_name(id, count)
	return str(c.get("name", id)) if count == 1 else str(c.get("plural", c.get("name", id)))


func commodity_icon(id: String) -> Texture2D:
	var icon := str(commodities.get(id, {}).get("icon", GameManager.COMMODITIES.get(id, {}).get("icon", "scrap")))
	return Assets.item_icon(icon)


func balance(id: String) -> int:
	return int(balances.get(id, GameManager.haul.get(id, 0)))


# ---------- requests ----------

func refresh() -> void:
	if _refreshing:
		return
	_refreshing = true
	var result := await _post("state", {})
	if result.is_empty():
		online = false
		message = OFFLINE_MESSAGE
	else:
		_apply_snapshot(result)
		await _flush_pending_hauls()
	_refreshing = false
	changed.emit()


## Sell to or buy from a merchant. For buys the scrap is checked against the quote ladder first
## and the bridge is told the maximum we agreed to pay, so a price move can't overcharge.
func trade(merchant_id: String, commodity: String, side: String, qty: int) -> Dictionary:
	if busy:
		return {"ok": false, "error": "Still finishing the last trade."}
	var body := {"merchant": merchant_id, "commodity": commodity, "side": side, "qty": qty,
		"intent_id": _intent_id()}
	if side == "buy":
		var ladder: Array = quote(merchant_id, commodity).get("ask_ladder", [])
		qty = mini(qty, ladder.size())
		if qty <= 0:
			return {"ok": false, "error": "Nothing in stock."}
		var total := 0
		for i in qty:
			total += int(ladder[i])
		if total > GameManager.currency:
			return {"ok": false, "error": "Not enough scrap: %d needed." % total}
		body["qty"] = qty
		body["max_total"] = total
	elif side == "sell":
		qty = mini(qty, balance(commodity))
		if qty <= 0:
			return {"ok": false, "error": "You don't have any to sell."}
		body["qty"] = qty
	busy = true
	changed.emit()
	var result := await _post("trade", body)
	busy = false
	if result.is_empty():
		result = {"ok": false, "error": OFFLINE_MESSAGE}
		online = false
	if result.get("ok", false):
		GameManager.add_currency(int(result.get("scrap_delta", 0)))
		_set_balances(result.get("balances", balances))
		_merge_quote(merchant_id, result.get("quote", {}), int(result.get("merchant_treasury", -1)))
		Sfx.play(&"pickup")
	message = str(result.get("reason", result.get("error", "")))
	trade_completed.emit(result)
	changed.emit()
	refresh()
	return result


## Pool scrap to reopen a bankrupt merchant.
func invest(merchant_id: String, scrap: int) -> Dictionary:
	if busy:
		return {"ok": false, "error": "Still finishing the last trade."}
	scrap = mini(scrap, GameManager.currency)
	if scrap <= 0:
		return {"ok": false, "error": "No scrap to invest."}
	busy = true
	changed.emit()
	var result := await _post("invest", {"merchant": merchant_id, "scrap": scrap})
	busy = false
	if result.is_empty():
		result = {"ok": false, "error": OFFLINE_MESSAGE}
	if result.get("ok", false):
		GameManager.add_currency(int(result.get("scrap_delta", 0)))
		Sfx.play(&"pickup")
	message = str(result.get("error", ""))
	changed.emit()
	refresh()
	return result


## Judge mode: the bridge simulates `days` of courier traffic and returns prices day by day.
## Nothing changes for real unless `apply` is true.
func fast_forward(days := 7, apply := false) -> Dictionary:
	var result := await _post("fast-forward", {"days": days, "apply": apply})
	if apply and result.get("ok", false):
		refresh()
	return result


func ledger() -> Dictionary:
	return await _post("ledger", {})


## GameManager queues every banked haul; this pushes them to the bridge (idempotent per run id)
## and adopts the bridge's balances as the truth once it answers.
func report_haul(run_id: String, haul: Dictionary) -> void:
	if haul.is_empty():
		return
	GameManager.queue_haul(run_id, haul)
	await _flush_pending_hauls()
	changed.emit()


# ---------- internals ----------

func _apply_snapshot(s: Dictionary) -> void:
	online = true
	message = ""
	day = int(s.get("day", day))
	market_name = str(s.get("market", market_name))
	chain = s.get("chain", chain)
	merchants = s.get("merchants", [])
	commodities = s.get("commodities", {})
	events = s.get("events", [])
	if s.has("player"):
		var p: Dictionary = s.player
		history = p.get("history", [])
		if GameManager.pending_hauls.is_empty():
			_set_balances(p.get("balances", {}))


func _flush_pending_hauls() -> void:
	for entry in GameManager.pending_hauls.duplicate():
		var result := await _post("haul", {"run_id": entry.run_id, "haul": entry.haul})
		if not result.get("ok", false):
			return  # offline or rejected; try again next refresh
		GameManager.remove_pending_haul(str(entry.run_id))
		_set_balances(result.get("balances", balances))


func _set_balances(values: Dictionary) -> void:
	balances = {}
	for id in values:
		balances[str(id)] = int(values[id])
	GameManager.set_haul(balances)


func _merge_quote(merchant_id: String, q: Dictionary, treasury: int) -> void:
	if q.is_empty():
		return
	var m := merchant(merchant_id)
	if m.is_empty():
		return
	if treasury >= 0:
		m["treasury"] = treasury
	var quotes: Array = m.get("quotes", [])
	for i in quotes.size():
		if quotes[i].get("commodity", "") == q.get("commodity", ""):
			quotes[i] = q


func _intent_id() -> String:
	return "%s-%d-%05d" % [GameManager.guest_id.left(8), int(Time.get_unix_time_from_system()), randi() % 100000]


func _post(action: String, payload: Dictionary) -> Dictionary:
	var bridge := WalletSession.bridge_url()
	if bridge.is_empty():
		return {}
	var body := identity()
	body.merge(payload, true)
	var http := HTTPRequest.new()
	http.timeout = 10.0
	http.max_redirects = 0
	add_child(http)
	var err := http.request(bridge + "/api/market/" + action, ["Content-Type: application/json"],
		HTTPClient.METHOD_POST, JSON.stringify(body))
	if err != OK:
		http.queue_free()
		return {}
	var response: Array = await http.request_completed
	http.queue_free()
	if response[0] != HTTPRequest.RESULT_SUCCESS:
		return {}
	var data: Variant = JSON.parse_string(response[3].get_string_from_utf8())
	return data if data is Dictionary else {}
