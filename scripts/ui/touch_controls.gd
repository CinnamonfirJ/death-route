extends Control
## On-screen twin-stick controls for phones/tablets. Shown automatically on touch
## devices (or with force_visible for desktop testing).
##
##   Left side:  floating stick -> move / steer + throttle (analog move_* actions)
##   Right side: floating aim stick and separate FIRE button
##   Buttons (context-aware):
##     on foot: USE (hold for jobs), SWAP, RELOAD, LIGHT (toggle), RUN (hold)
##     driving: BRAKE (handbrake, hold), SHOVE (shake off latchers), EXIT
##
## Multitouch is tracked here by touch index (not via GUI focus), so a thumb on each
## stick plus a button tap all work at once. Everything feeds the normal input
## actions, so gameplay code doesn't know touch exists.

const STICK_RADIUS := 40.0
const KNOB_RADIUS := 15.0
const DEADZONE := 0.2
## Sticks only start in the lower part of the screen (top is HUD).
const STICK_ZONE_TOP := 0.3

## Show even without a touchscreen (desktop testing).
@export var force_visible := false
@export var button_radius := 20.0
@export var fire_radius := 28.0
@export var touch_slop := 4.0

var active := false
var _move_index := -1
var _move_origin := Vector2.ZERO
var _move_vec := Vector2.ZERO
var _aim_index := -1
var _aim_origin := Vector2.ZERO
var _aim_vec := Vector2.ZERO
var _held := {}  # touch index -> button dictionary
var _was_in_car := false
var _touch_primary := false
var _safe := Rect2()
var _hud_base := {}


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	set_anchors_preset(Control.PRESET_FULL_RECT)
	_touch_primary = DisplayServer.is_touchscreen_available() or OS.has_feature("mobile")
	if OS.has_feature("web"):
		_touch_primary = bool(JavaScriptBridge.eval(
			"matchMedia('(pointer: coarse)').matches && navigator.maxTouchPoints > 0", true))
	get_viewport().size_changed.connect(_update_safe_area)
	_update_safe_area()
	_set_active(force_visible or _touch_primary)


func _set_active(value: bool) -> void:
	active = value
	visible = value
	var hint := get_parent().get_node_or_null(^"Controls") as CanvasItem
	if hint:
		hint.visible = not value  # keyboard hint is noise on a phone


func _update_safe_area() -> void:
	_safe = get_viewport_rect()
	if OS.has_feature("web"):
		var values: Variant = JSON.parse_string(str(JavaScriptBridge.eval(
			"window.deadRouteInsets ? window.deadRouteInsets() : '[0,0,0,0]'", true)))
		if values is Array and values.size() == 4:
			_safe = Rect2(Vector2(values[0], values[1]) * _safe.size,
				Vector2(1.0 - values[0] - values[2], 1.0 - values[1] - values[3]) * _safe.size)
	var view := get_viewport_rect()
	for corner in [&"TopLeft", &"TopRight"]:
		var hud := get_parent().get_node_or_null(NodePath(corner)) as Control
		if not hud:
			continue
		if not _hud_base.has(corner):
			_hud_base[corner] = Vector4(hud.offset_left, hud.offset_top, hud.offset_right, hud.offset_bottom)
		var base: Vector4 = _hud_base[corner]
		var x := _safe.position.x if corner == &"TopLeft" else _safe.end.x - view.end.x
		hud.offset_left = base.x + x
		hud.offset_right = base.z + x
		hud.offset_top = base.y + _safe.position.y
		hud.offset_bottom = base.w + _safe.position.y


func _player():
	return Net.local_player()


func _in_car() -> bool:
	var p = _player()
	return p != null and p.current_car != null


func buttons() -> Array:
	var s := _safe.end
	if _in_car():
		return [
			{"action": &"handbrake", "label": "BRAKE", "pos": s - Vector2(45, 53), "r": fire_radius},
			{"action": &"shove", "label": "SHOVE", "pos": s - Vector2(110, 49), "r": button_radius},
			{"action": &"interact", "label": "EXIT", "pos": s - Vector2(46, 117), "r": button_radius},
			_pause_button(),
		]
	var list := [
		# Kept below ~s.y-170: waypoint arrows stack under the top-right HUD above that.
		{"action": &"shoot", "label": "FIRE", "pos": s - Vector2(42, 50), "r": fire_radius},
		{"action": &"interact", "label": "USE", "pos": s - Vector2(42, 112), "r": button_radius},
		{"action": &"reload", "label": "RELOAD", "pos": s - Vector2(94, 112), "r": button_radius},
		{"action": &"switch_weapon", "label": "SWAP", "pos": s - Vector2(205, 48), "r": button_radius},
		{"action": &"flashlight", "label": "LIGHT", "pos": Vector2(_safe.position.x + 110, s.y - 132), "r": button_radius},
	]
	if not GameManager.get_setting("auto_run"):  # auto-run makes the RUN button pointless
		list.append({"action": &"sprint", "label": "RUN", "pos": Vector2(_safe.position.x + 55, s.y - 132), "r": button_radius})
	list.append(_pause_button())
	var p = _player()
	if p and p.has_node(^"HumanRival"):  # only the secret rival sees this
		list.append({"action": &"sabotage", "label": "SABO", "pos": Vector2(_safe.position.x + 164, s.y - 132), "r": button_radius})
	return list


func _pause_button() -> Dictionary:
	return {"action": &"pause", "label": "II", "pos": Vector2(_safe.position.x + 32, _safe.end.y - 186), "r": 17.0}


# ---------- Input ----------

func _input(event: InputEvent) -> void:
	if event is InputEventScreenTouch or event is InputEventScreenDrag:
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
						menu.toggle()
					return
				if b.action == &"flashlight":
					var player = _player()
					if player:
						player.get_node(^"Flashlight").toggle()
					return
				_held[e.index] = b
				if b.action == &"shoot":
					var player = _player()
					if player:
						player.touch_fire = true
				else:
					Input.action_press(b.action)
				return
		var s := get_viewport_rect().size
		if e.position.y < s.y * STICK_ZONE_TOP:
			return
		if e.position.x < s.x * 0.45 and _move_index == -1:
			_move_index = e.index
			_move_origin = e.position
			_move_vec = Vector2.ZERO
		elif e.position.x > s.x * 0.5 and _aim_index == -1 and not _in_car():
			_aim_index = e.index
			_aim_origin = e.position
			_aim_vec = Vector2.ZERO
		return
	# Released.
	if _held.has(e.index):
		var action: StringName = _held[e.index].action
		_held.erase(e.index)
		if not _holding(action):
			_release(action)
	if e.index == _move_index:
		_move_index = -1
		_move_vec = Vector2.ZERO
		_apply_move()
	if e.index == _aim_index:
		_end_aim()


func _on_drag(e: InputEventScreenDrag) -> void:
	if _held.has(e.index) and _held[e.index].action == &"shoot":
		var p = _player()
		var heading: Vector2 = e.position - _held[e.index].pos
		if p and heading.length() > STICK_RADIUS * DEADZONE:
			p.touch_aim = heading.normalized()
	elif e.index == _move_index:
		_move_origin = _follow(_move_origin, e.position)
		_move_vec = ((e.position - _move_origin) / STICK_RADIUS).limit_length(1.0)
	elif e.index == _aim_index:
		_aim_origin = _follow(_aim_origin, e.position)
		_aim_vec = ((e.position - _aim_origin) / STICK_RADIUS).limit_length(1.0)


## Floating stick: if the thumb drifts far, drag the base along behind it.
func _follow(origin: Vector2, pos: Vector2) -> Vector2:
	var off := pos - origin
	var limit := STICK_RADIUS * 1.4
	return pos - off.normalized() * limit if off.length() > limit else origin


func _end_aim() -> void:
	_aim_index = -1
	_aim_vec = Vector2.ZERO


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
		if _move_index != -1:
			_move_index = -1
			_move_vec = Vector2.ZERO
			_apply_move()
		_release_buttons()
		_end_aim()


func _release_buttons() -> void:
	for button in _held.values():
		_release(button.action)
	_held.clear()


# ---------- Feed actions every frame ----------

func _process(_delta: float) -> void:
	if not active:
		return
	var in_car := _in_car()
	if in_car != _was_in_car:
		# Context flipped (got in/out): drop held buttons and the aim stick.
		_release_buttons()
		_end_aim()
		_was_in_car = in_car
	if _move_index != -1:
		_apply_move()
	var p = _player()
	if p and _aim_index != -1:
		if _aim_vec.length() > DEADZONE:
			p.touch_aim = _aim_vec.normalized()
	queue_redraw()


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
	_draw_stick(_move_origin if _move_index != -1 else Vector2(_safe.position.x + 66, s.y - 60),
		_move_vec, _move_index != -1, "MOVE")
	if not _in_car():
		_draw_stick(_aim_origin if _aim_index != -1 else s - Vector2(134, 60), _aim_vec,
			_aim_index != -1, "AIM")
	var held_actions := _held.values().map(func(b: Dictionary) -> StringName: return b.action)
	var font := get_theme_default_font()
	for b in buttons():
		var pressed: bool = held_actions.has(b.action)
		draw_circle(b.pos, b.r, Color(TitleStyle.INK, 0.65 if pressed else 0.48))
		draw_arc(b.pos, b.r, 0.0, TAU, 32, Color(TitleStyle.AMBER, 0.9 if pressed else 0.55), 1.5)
		draw_string(font, b.pos + Vector2(-b.r, 3), b.label, HORIZONTAL_ALIGNMENT_CENTER, b.r * 2.0, 7,
			Color(TitleStyle.CREAM, 0.95 if pressed else 0.7))


func _draw_stick(origin: Vector2, vec: Vector2, live: bool, label: String) -> void:
	var a := 0.45 if live else 0.18
	draw_circle(origin, STICK_RADIUS, Color(TitleStyle.INK, a * 0.6))
	draw_arc(origin, STICK_RADIUS, 0.0, TAU, 40, Color(1, 1, 1, a), 1.5)
	var knob_color := Color(TitleStyle.AMBER, a + 0.2)
	draw_circle(origin + vec * STICK_RADIUS, KNOB_RADIUS, knob_color)
	if not live:
		draw_string(get_theme_default_font(), origin + Vector2(-STICK_RADIUS, STICK_RADIUS + 10), label,
			HORIZONTAL_ALIGNMENT_CENTER, STICK_RADIUS * 2.0, 7, Color(1, 1, 1, 0.4))
