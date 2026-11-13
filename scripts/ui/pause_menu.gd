extends CanvasLayer
## In-run pause menu: [Esc] / the II button. Settings, resume, or abandon the run.
## Offline the game pauses; online the world keeps going (you're just in a menu).

var _root: Control
var _dim: ColorRect
var _mic: CheckButton
var _voice_status: Label
var _panel: PanelContainer


func _ready() -> void:
	layer = 9
	process_mode = Node.PROCESS_MODE_ALWAYS
	_dim = ColorRect.new()
	_dim.color = Color(TitleStyle.INK, 0.72)
	_dim.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(_dim)
	var center := Control.new()
	center.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(center)
	var panel := PanelContainer.new()
	_panel = panel
	panel.theme = Assets.ui_theme()
	center.add_child(panel)
	var v := VBoxContainer.new()
	v.add_theme_constant_override(&"separation", 6)
	panel.add_child(v)
	var title := Label.new()
	title.text = "PAUSED" if not Net.is_online() else "MENU (game keeps running)"
	title.add_theme_font_size_override(&"font_size", 16)
	v.add_child(title)
	if Net.is_online():
		_mic = CheckButton.new()
		_mic.text = "Proximity microphone"
		TouchLayout.button(_mic, 14, 34)
		_mic.disabled = not Net.allows_voice()
		_mic.toggled.connect(Voice.set_microphone)
		v.add_child(_mic)
		_voice_status = Label.new()
		_voice_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		v.add_child(_voice_status)
		Voice.microphone_changed.connect(_refresh_voice)
		_refresh_voice()
	TouchLayout.scroll(v).add_child(SettingsPanel.new())
	var resume := Button.new()
	resume.name = "Resume"
	resume.text = "Resume"
	TouchLayout.button(resume)
	TitleStyle.primary(resume)
	resume.pressed.connect(close)
	v.add_child(resume)
	var quit := Button.new()
	quit.name = "Abandon"
	quit.text = "Abandon run (keep half scrap)"
	TouchLayout.button(quit, 14, 34)
	quit.pressed.connect(_abandon)
	v.add_child(quit)
	_root = center
	get_viewport().size_changed.connect(_layout)
	_layout()
	visible = false


func _layout() -> void:
	TouchLayout.fit_panel(_panel, TouchLayout.safe_rect(get_viewport()), Vector2(430, 338))


func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed(&"pause"):
		toggle()
		get_viewport().set_input_as_handled()


func toggle() -> void:
	if visible:
		close()
	else:
		open()


## The level this HUD belongs to (HUD's parent), whether or not it's the current scene.
func _level() -> Node:
	var hud := get_parent()
	return hud.get_parent() if hud else null


func open() -> void:
	var level := _level()
	var summary := level.get_node_or_null(^"RunSummary") as CanvasLayer if level else null
	if summary and summary.visible:
		return  # run's already over
	visible = true
	_refresh_voice()
	if not Net.is_online():
		get_tree().paused = true


func close() -> void:
	visible = false
	if not Net.is_online():
		get_tree().paused = false


func _refresh_voice() -> void:
	if _mic == null:
		return
	_mic.set_pressed_no_signal(Voice.mic_enabled)
	_voice_status.text = Voice.mic_status if Net.allows_voice() else "The host disabled voice for this room."


func _abandon() -> void:
	close()
	var loc := _level() as Location
	if loc == null:
		GameManager.goto_garage()
	elif Net.is_online():
		Net.report_down(true)  # you leave the fight; the team carries on
		GameManager.goto_garage()
	else:
		loc._finish(false)
