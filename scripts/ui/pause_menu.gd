extends CanvasLayer
## In-run pause menu: [Esc] / the II button. Settings, resume, or abandon the run.
## Offline the game pauses; online the world keeps going (you're just in a menu).

var _root: Control
var _dim: ColorRect
var _finish_button: Button


func _ready() -> void:
	layer = 9
	process_mode = Node.PROCESS_MODE_ALWAYS
	_dim = ColorRect.new()
	_dim.color = Color(0, 0, 0, 0.5)
	_dim.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(_dim)
	var center := CenterContainer.new()
	center.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(center)
	var panel := PanelContainer.new()
	panel.theme = Assets.ui_theme()
	center.add_child(panel)
	var v := VBoxContainer.new()
	v.add_theme_constant_override(&"separation", 6)
	panel.add_child(v)
	var title := Label.new()
	title.text = "PAUSED" if not Net.is_online() else "MENU (game keeps running)"
	title.add_theme_font_size_override(&"font_size", 16)
	v.add_child(title)
	v.add_child(SettingsPanel.new())
	var resume := Button.new()
	resume.name = "Resume"
	resume.text = "Resume"
	resume.pressed.connect(close)
	v.add_child(resume)
	_finish_button = Button.new()
	_finish_button.name = "FinishRoute"
	_finish_button.text = "Finish route"
	_finish_button.hide()
	_finish_button.pressed.connect(_finish_route)
	v.add_child(_finish_button)
	EventBus.objective_changed.connect(func(_text: String) -> void: _refresh_finish_button())
	var quit := Button.new()
	quit.name = "Abandon"
	quit.text = "Abandon run (keep half scrap)"
	quit.pressed.connect(_abandon)
	v.add_child(quit)
	_root = center
	visible = false


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
	_refresh_finish_button()
	if not Net.is_online():
		get_tree().paused = true


func close() -> void:
	visible = false
	if not Net.is_online():
		get_tree().paused = false


func _refresh_finish_button() -> void:
	var loc := _level() as Location
	_finish_button.visible = loc != null and Net.is_sim_authority() and loc.can_finish_route()


func _finish_route() -> void:
	var loc := _level() as Location
	if loc and loc.can_finish_route():
		close()
		loc.finish_route()


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
