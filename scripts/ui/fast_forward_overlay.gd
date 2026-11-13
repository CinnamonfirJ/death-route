class_name FastForwardOverlay
extends Control
## Judge mode. Plays a bridge fast-forward report: the price graph fills in day by day while the
## event log prints what happened ("Day 3: Doc went bankrupt. Shop closed."). Nothing is applied to
## the live market unless the viewer chooses to.

const PLAYBACK_SECONDS := 24.0

var _report: Dictionary
var _graph: PriceGraph
var _log: Label
var _day_label: Label
var _apply: Button
var _field := "bid"
var _elapsed := 0.0
var _playing := false
var _panel: PanelContainer


func _init(report: Dictionary) -> void:
	_report = report
	name = "FastForwardOverlay"
	set_anchors_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_STOP


func _ready() -> void:
	var mobile := TouchLayout.enabled()
	var dim := ColorRect.new()
	dim.color = Color(0, 0, 0, 0.7)
	dim.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(dim)
	_panel = PanelContainer.new()
	_panel.theme = Assets.ui_theme()
	add_child(_panel)
	var v := VBoxContainer.new()
	v.add_theme_constant_override(&"separation", 5)
	_panel.add_child(v)

	var head := HBoxContainer.new()
	v.add_child(head)
	var title := Label.new()
	title.text = "%d DAYS AT THE CAMP  ·  simulated, seed %d" % [int(_report.get("days", 7)), int(_report.get("seed", 0))]
	title.add_theme_font_size_override(&"font_size", 12)
	title.add_theme_color_override(&"font_color", TitleStyle.AMBER)
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	head.add_child(title)
	_day_label = Label.new()
	_day_label.add_theme_font_size_override(&"font_size", 10)
	head.add_child(_day_label)
	var toggle := Button.new()
	toggle.text = "SHOW: MERCHANT PAYS"
	toggle.add_theme_font_size_override(&"font_size", 8)
	toggle.pressed.connect(func() -> void:
		_field = "ask" if _field == "bid" else "bid"
		toggle.text = "SHOW: MERCHANT PAYS" if _field == "bid" else "SHOW: MERCHANT CHARGES"
		_graph.set_report(_report, _field)
		_graph.progress = _elapsed / PLAYBACK_SECONDS)
	head.add_child(toggle)

	_graph = PriceGraph.new()
	_graph.custom_minimum_size = Vector2(0, 150)
	_graph.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_graph.set_report(_report, _field)
	_graph.progress = 0.0
	v.add_child(_graph)

	var scroll := ScrollContainer.new()
	scroll.custom_minimum_size = Vector2(0, 74)
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	v.add_child(scroll)
	_log = Label.new()
	_log.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_log.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_log.add_theme_font_size_override(&"font_size", 12 if mobile else 8)
	_log.add_theme_color_override(&"font_color", TitleStyle.CREAM)
	scroll.add_child(_log)

	var buttons := HBoxContainer.new()
	buttons.add_theme_constant_override(&"separation", 6)
	v.add_child(buttons)
	var skip := Button.new()
	skip.text = "SKIP TO END"
	skip.pressed.connect(func() -> void: _elapsed = PLAYBACK_SECONDS)
	buttons.add_child(skip)
	_apply = Button.new()
	_apply.text = "APPLY TO LIVE MARKET"
	_apply.tooltip_text = "Makes this simulated week the camp's real state. Everyone in the market sees it."
	_apply.pressed.connect(_apply_live)
	buttons.add_child(_apply)
	_apply.visible = bool(_report.get("can_apply", false))
	var spacer := Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	buttons.add_child(spacer)
	var close := Button.new()
	close.text = "CLOSE"
	close.pressed.connect(queue_free)
	TitleStyle.primary(close)
	buttons.add_child(close)
	for b in [toggle, skip, _apply, close]:
		if mobile:
			TouchLayout.button(b, 12, 32)
	get_viewport().size_changed.connect(_layout)
	_layout()
	_playing = true
	close.grab_focus()


func _layout() -> void:
	var bounds := TouchLayout.safe_rect(get_viewport()) if TouchLayout.enabled() else get_viewport_rect()
	TouchLayout.fit_panel(_panel, bounds, Vector2(560, 330), 8.0)


func _process(delta: float) -> void:
	if not _playing:
		return
	_elapsed = minf(_elapsed + delta, PLAYBACK_SECONDS)
	var t := _elapsed / PLAYBACK_SECONDS
	_graph.progress = t
	var from_day := int(_report.get("from_day", 1))
	var to_day := int(_report.get("to_day", from_day))
	var current := from_day + int(floor(t * float(to_day - from_day)))
	_day_label.text = "Day %d" % current
	var lines: Array[String] = []
	for entry in _report.get("log", []):
		if int(entry.get("day", 0)) <= current:
			lines.append("Day %d: %s" % [int(entry.day), str(entry.text)])
	if _elapsed >= PLAYBACK_SECONDS:
		_playing = false
		var summary: Array = _report.get("summary", [])
		var closing: Array[String] = []
		for m in summary:
			closing.append("%s: %s, %d scrap" % [str(m.name), "open" if m.open else "CLOSED", int(m.treasury)])
		lines.append("End of week — " + " · ".join(closing))
	_log.text = "\n".join(lines)


func _apply_live() -> void:
	_apply.disabled = true
	_apply.text = "APPLYING..."
	var result: Dictionary = await CampMarket.fast_forward(int(_report.get("days", 7)), true, int(_report.get("seed", 0)))
	_apply.text = "APPLIED" if result.get("ok", false) else "FAILED"


func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed(&"pause"):
		queue_free()
