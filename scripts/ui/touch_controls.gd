extends Control
## On-screen twin-stick controls for phones/tablets. Shown automatically on touch
## devices (or with force_visible for desktop testing).
##
##   Left side:  floating stick -> move / steer + throttle (analog move_* actions)
##   Right side: aim stick with a fire ring, or a separate FIRE button in Advanced.
##   Buttons (context-aware):
##     on foot: USE (hold for jobs), SWAP, RELOAD, LIGHT (toggle), RUN (hold)
##     driving: BRAKE (handbrake, hold), SHOVE (shake off latchers), EXIT
##
## Multitouch is tracked here by touch index (not via GUI focus), so a thumb on each
## stick plus a button tap all work at once. Everything feeds the normal input
## actions, so gameplay code doesn't know touch exists.

const STICK_RADIUS := 43.0
const KNOB_RADIUS := 15.0
const DEADZONE := 0.2
## Sticks only start in the lower part of the screen (top is HUD).
const STICK_ZONE_TOP := 0.48

## Show even without a touchscreen (desktop testing).
@export var force_visible := false
@export var button_radius := 22.0
@export var fire_radius := 26.0
@export var touch_slop := 2.0
@export_range(0.4, 0.95, 0.01) var fire_threshold := 0.77
@export_range(0.05, 0.3, 0.01) var fire_hysteresis := 0.14

var active := false
var _move_index := -1
var _move_origin := Vector2.ZERO
var _move_vec := Vector2.ZERO
var _aim_index := -1
var _aim_origin := Vector2.ZERO
var _aim_vec := Vector2.ZERO
var _aim_firing := false
var _advanced := false
var _held := {}  # touch index -> button dictionary
var _was_in_car := false
var _touch_primary := false
var _safe := Rect2()


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	set_anchors_preset(Control.PRESET_FULL_RECT)
	_touch_primary = TouchLayout.enabled()
	_advanced = GameManager.get_setting("touch_shooting") == "advanced"
	GameManager.settings_changed.connect(_settings_changed)
	get_viewport().size_changed.connect(_update_safe_area)
	_update_safe_area()
	_set_active(force_visible or _touch_primary)


func _set_active(value: bool) -> void:
	active = value
	visible = value
	var hint := get_parent().get_node_or_null(^"Controls") as CanvasItem
	if hint:
		hint.visible = not value  # keyboard hint is noise on a phone
	if get_parent().has_method("set_touch_layout"):
		get_parent().set_touch_layout(value)
	queue_redraw()


func _update_safe_area() -> void:
	_cancel_gestures()
	_safe = TouchLayout.safe_rect(get_viewport())
	queue_redraw()


func _settings_changed() -> void:
	var advanced: bool = GameManager.get_setting("touch_shooting") == "advanced"
	if advanced != _advanced:
		_cancel_gestures()
		_advanced = advanced
	queue_redraw()


func _player():
	return Net.local_player()


func _in_car() -> bool:
	var p = _player()
	return p != null and p.current_car != null


func buttons() -> Array:
	var s := _safe.end
	if _in_car():
		return [
			{"action": &"handbrake", "label": "Brake", "pos": s - Vector2(43, 62), "r": fire_radius},
			{"action": &"shove", "label": "Shove", "pos": s - Vector2(105, 62), "r": button_radius},
			{"action": &"interact", "label": "Exit", "pos": s - Vector2(43, 125), "r": button_radius},
			_pause_button(),
		]
	var list := [
		{"action": &"interact", "label": "Use", "pos": s - Vector2(30, 138), "r": button_radius},
		{"action": &"reload", "label": "Reload", "pos": s - Vector2(84, 138), "r": button_radius},
		{"action": &"switch_weapon", "label": "Swap", "pos": s - Vector2(138, 138), "r": button_radius},
		{"action": &"flashlight", "label": "Light", "pos": Vector2(_safe.position.x + 86, s.y - 138), "r": button_radius},
	]
	if _advanced:
		list.append({"action": &"shoot", "label": "Fire", "pos": s - Vector2(36, 61), "r": fire_radius})
	if not GameManager.get_setting("auto_run"):  # auto-run makes the RUN button pointless
		list.append({"action": &"sprint", "label": "Run", "pos": Vector2(_safe.position.x + 32, s.y - 138), "r": button_radius})
	list.append(_pause_button())
	var p = _player()
	if p and p.has_node(^"HumanRival"):  # only the secret rival sees this
		list.append({"action": &"sabotage", "label": "Sabo", "pos": Vector2(_safe.position.x + 140, s.y - 138), "r": button_radius})
	return list


func _pause_button() -> Dictionary:
	return {"action": &"pause", "label": "II", "pos": Vector2(_safe.position.x + 30, _safe.end.y - 191), "r": button_radius}


# ---------- Input ----------

func _input(event: InputEvent) -> void:
	if event is InputEventScreenTouch or event is InputEventScreenDrag:
		if _menu_open():
			return
		if not active:
			_set_active(true)
		var p = _player()
		if p:
			p.touch_mode = true
		if event is InputEventScreenTouch:
			_on_touch(event)
		else:
			_on_drag(event)
		queue_redraw()
	elif event is InputEventMouseMotion and event.device != InputEvent.DEVICE_ID_EMULATION \
			and _move_index == -1 and _aim_index == -1:
		# A real mouse took over: aim with it again.
		var p = _player()
		if p:
			p.touch_mode = false
		if not force_visible and not _touch_primary and _held.is_empty():
			_set_active(false)


func _on_touch(e: InputEventScreenTouch) -> void:
	if e.pressed:
		for b in buttons():
			if e.position.distance_to(b.pos) <= b.r + touch_slop:
				if b.action == &"pause":
					var menu := get_parent().get_node_or_null(^"PauseMenu")
					if menu:
						_cancel_gestures()
						menu.toggle()
					get_viewport().set_input_as_handled()
					return
				if b.action == &"flashlight":
					var player = _player()
					if player:
						player.get_node(^"Flashlight").toggle()
					get_viewport().set_input_as_handled()
					return
				_held[e.index] = b
				if b.action == &"shoot":
					var player = _player()
					if player:
						player.touch_fire = true
				else:
					Input.action_press(b.action)
				get_viewport().set_input_as_handled()
				return
		if not _safe.has_point(e.position) or e.position.y < _safe.position.y + _safe.size.y * STICK_ZONE_TOP:
			return
		var x := (e.position.x - _safe.position.x) / _safe.size.x
		if x < 0.45 and _move_index == -1:
			_move_index = e.index
			_move_origin = e.position
			_move_vec = Vector2.ZERO
			get_viewport().set_input_as_handled()
		elif x > 0.55 and _aim_index == -1 and not _in_car():
			_aim_index = e.index
			_aim_origin = e.position
			_aim_vec = Vector2.ZERO
			get_viewport().set_input_as_handled()
		return
	# Released.
	if _held.has(e.index):
		get_viewport().set_input_as_handled()
		var action: StringName = _held[e.index].action
		_held.erase(e.index)
		if not _holding(action):
			_release(action)
	if e.index == _move_index:
		get_viewport().set_input_as_handled()
		_move_index = -1
		_move_vec = Vector2.ZERO
		_apply_move()
	if e.index == _aim_index:
		get_viewport().set_input_as_handled()
		_end_aim()


func _on_drag(e: InputEventScreenDrag) -> void:
	if _held.has(e.index) and _held[e.index].action == &"shoot":
		get_viewport().set_input_as_handled()
		var p = _player()
		var heading: Vector2 = e.position - _held[e.index].pos
		if p and heading.length() > STICK_RADIUS * DEADZONE:
			p.touch_aim = heading.normalized()
	elif e.index == _move_index:
		get_viewport().set_input_as_handled()
		_move_origin = _follow(_move_origin, e.position)
		_move_vec = ((e.position - _move_origin) / STICK_RADIUS).limit_length(1.0)
	elif e.index == _aim_index:
		get_viewport().set_input_as_handled()
		_aim_vec = ((e.position - _aim_origin) / STICK_RADIUS).limit_length(1.0)
		_update_aim()


## Floating stick: if the thumb drifts far, drag the base along behind it.
func _follow(origin: Vector2, pos: Vector2) -> Vector2:
	var off := pos - origin
	var limit := STICK_RADIUS * 1.4
	return pos - off.normalized() * limit if off.length() > limit else origin


func _end_aim() -> void:
	_aim_index = -1
	_aim_vec = Vector2.ZERO
	_aim_firing = false
	_sync_fire()


func _update_aim() -> void:
	var strength := _aim_vec.length()
	var p = _player()
	if p and strength > DEADZONE:
		p.touch_aim = _aim_vec.normalized()
	var threshold := fire_threshold - fire_hysteresis if _aim_firing else fire_threshold
	_aim_firing = not _advanced and strength >= threshold
	_sync_fire()


func _sync_fire() -> void:
	var p = _player()
	if p:
		p.touch_fire = _aim_firing or (_advanced and _holding(&"shoot"))


func _menu_open() -> bool:
	var pause_menu := get_parent().get_node_or_null(^"PauseMenu") as CanvasLayer
	var level := get_parent().get_parent()
	var summary := level.get_node_or_null(^"RunSummary") as CanvasLayer if level else null
	return (pause_menu != null and pause_menu.visible) or (summary != null and summary.visible)


func _holding(action: StringName) -> bool:
	for button in _held.values():
		if button.action == action:
			return true
	return false


func _release(action: StringName) -> void:
	if action == &"shoot":
		var p = _player()
		if p:
			p.touch_fire = false
	else:
		Input.action_release(action)


func _notification(what: int) -> void:
	if what == NOTIFICATION_APPLICATION_FOCUS_OUT or what == NOTIFICATION_PAUSED or what == NOTIFICATION_EXIT_TREE:
		_cancel_gestures()


func _cancel_gestures() -> void:
	if _move_index != -1:
		_move_index = -1
		_move_vec = Vector2.ZERO
		_apply_move()
	_release_buttons()
	if is_inside_tree():
		_end_aim()
	queue_redraw()


func _release_buttons() -> void:
	for button in _held.values():
		_release(button.action)
	_held.clear()


# ---------- Feed actions every frame ----------

func _process(_delta: float) -> void:
	if not active:
		return
	if _menu_open():
		if _move_index != -1 or _aim_index != -1 or not _held.is_empty():
			_cancel_gestures()
		return
	var in_car := _in_car()
	if in_car != _was_in_car:
		# Context flipped (got in/out): drop held buttons and the aim stick.
		_release_buttons()
		_end_aim()
		_was_in_car = in_car
		queue_redraw()
	if _move_index != -1:
		_apply_move()


func _apply_move() -> void:
	_apply_axis(&"move_left", &"move_right", _move_vec.x)
	_apply_axis(&"move_up", &"move_down", _move_vec.y)


func _apply_axis(neg: StringName, pos: StringName, v: float) -> void:
	if v < -DEADZONE:
		Input.action_press(neg, -v)
		Input.action_release(pos)
	elif v > DEADZONE:
		Input.action_press(pos, v)
		Input.action_release(neg)
	else:
		Input.action_release(neg)
		Input.action_release(pos)


# ---------- Drawing ----------

func _draw() -> void:
	var s := _safe.end
	_draw_stick(_move_origin if _move_index != -1 else Vector2(_safe.position.x + 61, s.y - 61),
		_move_vec, _move_index != -1, "Move")
	if not _in_car():
		_draw_stick(_aim_origin if _aim_index != -1 else s - Vector2(115 if _advanced else 61, 61), _aim_vec,
			_aim_index != -1, "Aim" if _advanced else "Aim + fire", not _advanced)
	var held_actions := _held.values().map(func(b: Dictionary) -> StringName: return b.action)
	var font := ThemeDB.fallback_font
	for b in buttons():
		var pressed: bool = held_actions.has(b.action)
		draw_circle(b.pos, b.r, Color("#563049") if pressed else Color(TitleStyle.INK, 0.88), true, -1, true)
		draw_arc(b.pos, b.r, 0.0, TAU, 40, Color(TitleStyle.AMBER, 1.0 if pressed else 0.74), 1.4, true)
		draw_string(font, b.pos + Vector2(-b.r, 4), b.label, HORIZONTAL_ALIGNMENT_CENTER, b.r * 2.0, 12, TitleStyle.CREAM)


func _draw_stick(origin: Vector2, vec: Vector2, live: bool, label: String, fire_ring := false) -> void:
	var firing := fire_ring and _aim_firing
	var ink := Color("#703c42") if firing else Color(TitleStyle.INK, 0.67)
	var accent := TitleStyle.AMBER if fire_ring else Color("#b7bde3")
	draw_circle(origin, STICK_RADIUS, ink, true, -1, true)
	draw_arc(origin, STICK_RADIUS, 0.0, TAU, 48, Color(accent, 0.9 if live else 0.6), 1.6, true)
	if fire_ring:
		draw_arc(origin, STICK_RADIUS * fire_threshold, 0.0, TAU, 40, Color(accent, 1.0 if firing else 0.44), 1.5, true)
	var knob_color := Color(accent, 1.0 if live else 0.65)
	draw_circle(origin + vec * STICK_RADIUS, KNOB_RADIUS, knob_color, true, -1, true)
	if not live:
		draw_string(ThemeDB.fallback_font, origin + Vector2(-STICK_RADIUS, STICK_RADIUS + 13), label,
			HORIZONTAL_ALIGNMENT_CENTER, STICK_RADIUS * 2.0, 12, TitleStyle.CREAM)
