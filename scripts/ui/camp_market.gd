class_name CampMarketPanel
extends VBoxContainer
## Garage tab: the Survivor Camp market. Merchants are agent NPCs with their own wallets; every
## price and the "why" line beside it come from the bridge, which computes them from
## economy/pricing_rules.toml. Scrap is local; commodities are NEP-245 balances. The chain stays
## invisible: Sell and Buy are plain buttons.

const SELL_ALL_CAP := 20

var _mobile := false
var _status: Label
var _account: Label
var _haul: HBoxContainer
var _list: VBoxContainer
var _ff: Button
var _feed: Label
var _signature := 0


func _ready() -> void:
	_mobile = TouchLayout.enabled()
	size_flags_horizontal = Control.SIZE_EXPAND_FILL
	add_theme_constant_override(&"separation", 4)

	var head := HBoxContainer.new()
	head.add_theme_constant_override(&"separation", 6)
	add_child(head)
	_status = Label.new()
	_status.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_status.add_theme_font_size_override(&"font_size", 9)
	_status.add_theme_color_override(&"font_color", TitleStyle.AMBER)
	_status.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	head.add_child(_status)
	_ff = Button.new()
	_ff.text = "FAST-FORWARD 7 DAYS"
	_ff.tooltip_text = "Judge mode: simulate a week of courier traffic and watch prices move. Nothing changes unless you apply it."
	_ff.add_theme_font_size_override(&"font_size", 8)
	_ff.pressed.connect(_fast_forward)
	head.add_child(_ff)

	_account = Label.new()
	_account.add_theme_font_size_override(&"font_size", 8)
	_account.add_theme_color_override(&"font_color", TitleStyle.MUTED)
	_account.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	add_child(_account)

	var haul_label := Label.new()
	haul_label.text = "YOUR HAUL"
	haul_label.add_theme_font_size_override(&"font_size", 8)
	haul_label.add_theme_color_override(&"font_color", TitleStyle.MUTED)
	add_child(haul_label)
	_haul = HBoxContainer.new()
	_haul.add_theme_constant_override(&"separation", 8)
	add_child(_haul)

	_list = VBoxContainer.new()
	_list.add_theme_constant_override(&"separation", 6)
	add_child(_list)

	_feed = Label.new()
	_feed.add_theme_font_size_override(&"font_size", 8)
	_feed.add_theme_color_override(&"font_color", TitleStyle.MUTED)
	_feed.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	add_child(_feed)

	if _mobile:
		for l in [_status, _account, haul_label, _feed]:
			TouchLayout.label(l, 12)
		TouchLayout.button(_ff, 12, 32)
	CampMarket.changed.connect(_refresh)
	CampMarket.trade_completed.connect(_on_trade)
	_refresh()


func _refresh() -> void:
	# The bridge is polled every few seconds; only rebuild when something the player can see
	# changed, so a focused button survives the poll.
	var signature := hash(JSON.stringify([CampMarket.online, CampMarket.busy, CampMarket.message, CampMarket.day,
		CampMarket.merchants, CampMarket.balances, CampMarket.events, GameManager.currency,
		GameManager.pending_hauls.size(), WalletSession.signed_in]))
	if signature == _signature:
		return
	_signature = signature
	if not CampMarket.online:
		_status.text = CampMarket.message if not CampMarket.message.is_empty() else CampMarket.OFFLINE_MESSAGE
		_status.add_theme_color_override(&"font_color", Color("#f08a7e"))
	else:
		_status.text = "%s  ·  Day %d" % [CampMarket.market_name, CampMarket.day]
		_status.add_theme_color_override(&"font_color", TitleStyle.AMBER)
	_ff.disabled = not CampMarket.online or CampMarket.busy
	_account.text = "Trading as %s" % CampMarket.account_label()
	_refresh_haul()
	_clear(_list)
	if CampMarket.online:
		for m in CampMarket.merchants:
			_list.add_child(_merchant_card(m))
	elif not GameManager.pending_hauls.is_empty():
		var note := Label.new()
		note.text = "%d haul(s) waiting to sync. They'll be credited when the bridge is back." % GameManager.pending_hauls.size()
		note.add_theme_font_size_override(&"font_size", 8)
		_list.add_child(note)
	var lines: Array[String] = []
	var events: Array = CampMarket.events
	for i in range(maxi(0, events.size() - 4), events.size()):
		lines.append("· " + str(events[i].get("text", "")))
	_feed.text = "\n".join(lines)


func _refresh_haul() -> void:
	_clear(_haul)
	var ids: Array = GameManager.COMMODITIES.keys()
	for id in CampMarket.commodities:
		if not ids.has(id):
			ids.append(id)
	var any := false
	for id in ids:
		var n := CampMarket.balance(id)
		if n <= 0:
			continue
		any = true
		var chip := HBoxContainer.new()
		chip.add_theme_constant_override(&"separation", 2)
		chip.tooltip_text = CampMarket.commodity_name(id, n)
		chip.add_child(_icon(CampMarket.commodity_icon(id), 16))
		var count := Label.new()
		count.text = "x%d" % n
		count.add_theme_font_size_override(&"font_size", 12 if _mobile else 9)
		chip.add_child(count)
		_haul.add_child(chip)
	if not any:
		var empty := Label.new()
		empty.text = "Nothing to sell yet. Supply crates sit at the pizza spots that turned out empty; a finished delivery mints a Pizza Delivery Contract."
		empty.add_theme_font_size_override(&"font_size", 12 if _mobile else 8)
		empty.add_theme_color_override(&"font_color", TitleStyle.MUTED)
		empty.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		empty.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		_haul.add_child(empty)


func _merchant_card(m: Dictionary) -> Control:
	var card := PanelContainer.new()
	card.add_theme_stylebox_override(&"panel", TitleStyle.surface(Color(0.09, 0.08, 0.15, 0.85), TitleStyle.BORDER, 6))
	var v := VBoxContainer.new()
	v.add_theme_constant_override(&"separation", 3)
	card.add_child(v)

	var head := HBoxContainer.new()
	head.add_theme_constant_override(&"separation", 6)
	v.add_child(head)
	var portrait := Assets.character_frames(StringName(str(m.get("character", "npc_companion_a"))))
	if portrait:
		head.add_child(_icon(portrait.get_frame_texture(&"idle", 0), 24))
	var who := Label.new()
	who.text = "%s  ·  %s" % [str(m.get("name", "")), str(m.get("title", ""))]
	who.add_theme_font_size_override(&"font_size", 10)
	who.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	who.tooltip_text = "Wallet: %s" % str(m.get("account", ""))
	head.add_child(who)
	var state := Label.new()
	var open: bool = m.get("open", true)
	state.text = "OPEN  ·  %d scrap" % int(m.get("treasury", 0)) if open else "CLOSED  ·  bankrupt"
	state.add_theme_font_size_override(&"font_size", 9)
	state.add_theme_color_override(&"font_color", Color("#7fd1ae") if open else Color("#f08a7e"))
	head.add_child(state)
	if _mobile:
		TouchLayout.label(who, 13)
		TouchLayout.label(state, 12)

	if not open:
		v.add_child(_closed_row(m))
		return card
	for q in m.get("quotes", []):
		v.add_child(_quote_row(m, q))
	return card


func _closed_row(m: Dictionary) -> Control:
	var v := VBoxContainer.new()
	var why := Label.new()
	why.text = str(m.get("closed_line", "Shop closed."))
	why.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	why.add_theme_font_size_override(&"font_size", 12 if _mobile else 8)
	why.add_theme_color_override(&"font_color", TitleStyle.CREAM)
	v.add_child(why)
	var row := HBoxContainer.new()
	row.add_theme_constant_override(&"separation", 6)
	v.add_child(row)
	var invested := int(m.get("invested", 0))
	var cost := int(m.get("reopen_cost", 0))
	var progress := Label.new()
	progress.text = "Reopen fund: %d / %d scrap pooled by couriers" % [invested, cost]
	progress.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	progress.add_theme_font_size_override(&"font_size", 12 if _mobile else 8)
	row.add_child(progress)
	var id := str(m.get("id", ""))
	for amount in [25, cost - invested]:
		if amount <= 0:
			continue
		var b := Button.new()
		b.text = "INVEST %d" % amount
		b.disabled = CampMarket.busy or GameManager.currency < 1
		b.tooltip_text = "Pool scrap to restock the shop. It reopens once the fund is full."
		b.pressed.connect(func() -> void: CampMarket.invest(id, amount))
		if _mobile:
			TouchLayout.button(b, 12, 32)
		row.add_child(b)
	return v


func _quote_row(m: Dictionary, q: Dictionary) -> Control:
	var commodity := str(q.get("commodity", ""))
	var merchant_id := str(m.get("id", ""))
	var row := HBoxContainer.new()
	row.add_theme_constant_override(&"separation", 6)
	row.tooltip_text = "%s\n\n%s" % [str(q.get("reason", "")), str(q.get("formula", ""))]
	row.add_child(_icon(CampMarket.commodity_icon(commodity), 20))

	var text := VBoxContainer.new()
	text.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	text.add_theme_constant_override(&"separation", 0)
	row.add_child(text)
	var head := Label.new()
	var have := CampMarket.balance(commodity)
	head.text = CampMarket.commodity_name(commodity, 2)
	head.add_theme_font_size_override(&"font_size", 9)
	head.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	text.add_child(head)
	var numbers := Label.new()
	numbers.text = "pays %d · charges %d · stock %d/%d%s" % [int(q.get("bid", 0)), int(q.get("ask", 0)),
		int(q.get("inventory", 0)), int(q.get("ideal", 0)), " · yours %d" % have if have > 0 else ""]
	numbers.add_theme_font_size_override(&"font_size", 8)
	numbers.add_theme_color_override(&"font_color", TitleStyle.CREAM)
	numbers.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	text.add_child(numbers)
	var why := Label.new()
	why.text = "💡 " + str(q.get("reason", ""))
	why.add_theme_font_size_override(&"font_size", 8)
	why.add_theme_color_override(&"font_color", _band_color(str(q.get("band", "balanced"))))
	why.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	text.add_child(why)
	if _mobile:
		TouchLayout.label(head, 13)
		TouchLayout.label(numbers, 12)
		TouchLayout.label(why, 12)

	var buttons := HBoxContainer.new()
	buttons.add_theme_constant_override(&"separation", 3)
	buttons.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	row.add_child(buttons)
	var can_sell: bool = q.get("can_sell", false) and have > 0 and not CampMarket.busy
	var sell := _trade_button("SELL 1", can_sell, "%s pays %d scrap for one." % [m.get("name", ""), int(q.get("bid", 0))],
		func() -> void: CampMarket.trade(merchant_id, commodity, "sell", 1))
	buttons.add_child(sell)
	if have > 1:
		var ladder: Array = q.get("bid_ladder", [])
		var n := mini(mini(have, SELL_ALL_CAP), maxi(ladder.size(), 1))
		var total := 0
		for i in mini(n, ladder.size()):
			total += int(ladder[i])
		buttons.add_child(_trade_button("SELL %d" % n, can_sell, "About %d scrap. Each unit lowers the next price." % total,
			func() -> void: CampMarket.trade(merchant_id, commodity, "sell", n)))
	var ask := int(q.get("ask", 0))
	var can_buy: bool = q.get("can_buy", false) and GameManager.currency >= ask and not CampMarket.busy
	buttons.add_child(_trade_button("BUY 1", can_buy, "Costs %d scrap." % ask if q.get("can_buy", false) else "Sold out.",
		func() -> void: CampMarket.trade(merchant_id, commodity, "buy", 1)))
	return row


func _trade_button(label: String, enabled: bool, tip: String, action: Callable) -> Button:
	var b := Button.new()
	b.text = label
	b.disabled = not enabled
	b.tooltip_text = tip
	b.custom_minimum_size = Vector2(52, 0)
	b.add_theme_font_size_override(&"font_size", 8)
	b.pressed.connect(action)
	if _mobile:
		TouchLayout.button(b, 12, 30)
	return b


func _on_trade(result: Dictionary) -> void:
	if result.get("ok", false):
		var verb := "Sold" if result.get("side", "") == "sell" else "Bought"
		var who := str(CampMarket.merchant(str(result.get("merchant", ""))).get("name", "the merchant"))
		EventBus.hud_message.emit("%s %d %s. %s: \"%s\"" % [verb, int(result.get("qty", 0)),
			CampMarket.commodity_name(str(result.get("commodity", "")), int(result.get("qty", 0))), who,
			str(result.get("reason", ""))])
	else:
		_status.text = str(result.get("error", "Trade failed."))
		_status.add_theme_color_override(&"font_color", Color("#f08a7e"))


func _fast_forward() -> void:
	_ff.disabled = true
	_ff.text = "SIMULATING..."
	var report: Dictionary = await CampMarket.fast_forward(7, false)
	_ff.text = "FAST-FORWARD 7 DAYS"
	_ff.disabled = not CampMarket.online
	if not report.get("ok", false):
		_status.text = str(report.get("error", "The bridge could not run the simulation."))
		return
	var overlay := FastForwardOverlay.new(report)
	get_tree().current_scene.add_child(overlay)


func _band_color(band: String) -> Color:
	match band:
		"glut", "high":
			return Color("#f08a7e")
		"low", "scarce":
			return Color("#7fd1ae")
		_:
			return TitleStyle.MUTED


func _icon(tex: Texture2D, px: int) -> TextureRect:
	var r := TextureRect.new()
	r.texture = tex
	r.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	r.custom_minimum_size = Vector2(px, px)
	r.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	r.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	r.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	return r


func _clear(node: Node) -> void:
	for c in node.get_children():
		node.remove_child(c)
		c.queue_free()
