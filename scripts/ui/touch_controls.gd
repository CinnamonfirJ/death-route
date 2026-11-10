extends Control
## On-screen twin-stick controls for phones/tablets. Shown automatically on touch
## devices (or with force_visible for desktop testing).
##
##   Left side:  floating stick -> move / steer + throttle (analog move_* actions)
##   Right side: floating stick -> aim; push it past FIRE_THRESHOLD to fire
##   Buttons (context-aware):
##     on foot: USE (hold for jobs), RELOAD, LIGHT (flashlight, hold), RUN (hold)
##     driving: BRAKE (handbrake, hold), SHOVE (shake off latchers), EXIT
##
## Multitouch is tracked here by touch index (not via GUI focus), so a thumb on each
## stick plus a button tap all work at once. Everything feeds the normal input
## actions, so gameplay code doesn't know touch exists.

const STICK_RADIUS := 40.0
const KNOB_RADIUS := 15.0
const DEADZONE := 0.2
const FIRE_THRESHOLD := 0.45
## Sticks only start in the lower part of the screen (top is HUD).
const STICK_ZONE_TOP := 0.3

## Show even without a touchscreen (desktop testing).
@export var force_visible := false

var active := false
var _move_index := -1
var _move_origin := Vector2.ZERO
var _move_vec := Vector2.ZERO
var _aim_index := -1
var _aim_origin := Vector2.ZERO
var _aim_vec := Vector2.ZERO
var _held := {}  # touch index -> button dictionary
var _was_in_car := false


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	set_anchors_preset(Control.PRESET_FULL_RECT)
	_set_active(force_visible or DisplayServer.is_touchscreen_available() or OS.has_feature("mobile"))


func _set_active(value: bool) -> void:
	active = value
	visible = value
	var hint := get_parent().get_node_or_null(^"Controls") as CanvasItem
	if hint:
		hint.visible = not value  # keyboard hint is noise on a phone


func _player():
	return Net.local_player()


func _in_car() -> bool:
	var p = _player()
	return p != null and p.current_car != null


func buttons() -> Array:
	var s := get_viewport_rect().size
	if _in_car():
		return [
			{"action": &"handbrake", "label": "BRAKE", "pos": Vector2(s.x - 64, s.y - 64), "r": 28.0},
			{"action": &"shove", "label": "SHOVE", "pos": Vector2(s.x - 134, s.y - 46), "r": 18.0},
			{"action": &"interact", "label": "EXIT", "pos": Vector2(s.x - 44, s.y - 144), "r": 20.0},
			_pause_button(s),
		]
	var list := [
		# Kept below ~s.y-170: waypoint arrows stack under the top-right HUD above that.
		{"action": &"interact", "label": "USE", "pos": Vector2(s.x - 44, s.y - 112), "r": 20.0},
		{"action": &"reload", "label": "RELOAD", "pos": Vector2(s.x - 44, s.y - 160), "r": 16.0},
		{"action": &"flashlight", "label": "LIGHT", "pos": Vector2(s.x - 90, s.y - 150), "r": 16.0},
	]
	if not GameManager.get_setting("auto_run"):  # auto-run makes the RUN button pointless
		list.append({"action": &"sprint", "label": "RUN", "pos": Vector2(58, s.y - 150), "r": 18.0})
	list.append(_pause_button(s))
	var p = _player()
	if p and p.has_node(^"HumanRival"):  # only the secret rival sees this
		list.append({"action": &"sabotage", "label": "SABO", "pos": Vector2(s.x - 136, s.y - 112), "r": 16.0})
	return list


func _pause_button(s: Vector2) -> Dictionary:
	return {"action": &"pause", "label": "II", "pos": Vector2(s.x * 0.5, 16), "r": 12.0}


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


func _on_touch(e: InputEventScreenTouch) -> void:
	if e.pressed:
		for b in buttons():
			if e.position.distance_to(b.pos) <= b.r + 6.0:
				if b.action == &"pause":
					var menu := get_parent().get_node_or_null(^"PauseMenu")
					if menu:
						menu.toggle()
					return
				_held[e.index] = b
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
		Input.action_release(_held[e.index].action)
		_held.erase(e.index)
	if e.index == _move_index:
		_move_index = -1
		_move_vec = Vector2.ZERO
		_apply_move()
	if e.index == _aim_index:
		_end_aim()


func _on_drag(e: InputEventScreenDrag) -> void:
	if e.index == _move_index:
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
	var p = _player()
	if p:
		p.touch_fire = false


# ---------- Feed actions every frame ----------

func _process(_delta: float) -> void:
	if not active:
		return
	var in_car := _in_car()
	if in_car != _was_in_car:
		# Context flipped (got in/out): drop held buttons and the aim stick.
		for i in _held:
			Input.action_release(_held[i].action)
		_held.clear()
		_end_aim()
		_was_in_car = in_car
	if _move_index != -1:
		_apply_move()
	var p = _player()
	if p and _aim_index != -1:
		if _aim_vec.length() > DEADZONE:
			p.touch_aim = _aim_vec.normalized()
		p.touch_fire = _aim_vec.length() > FIRE_THRESHOLD
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
	var s := get_viewport_rect().size
	_draw_stick(_move_origin if _move_index != -1 else Vector2(72, s.y - 72), _move_vec, _move_index != -1, "MOVE")
	if not _in_car():
		_draw_stick(_aim_origin if _aim_index != -1 else Vector2(s.x - 150, s.y - 72), _aim_vec,
			_aim_index != -1, "AIM / FIRE")
	var held_actions := _held.values().map(func(b: Dictionary) -> StringName: return b.action)
	var font := get_theme_default_font()
	for b in buttons():
		var pressed: bool = held_actions.has(b.action)
		draw_circle(b.pos, b.r, Color(0.1, 0.1, 0.12, 0.55 if pressed else 0.35))
		draw_arc(b.pos, b.r, 0.0, TAU, 32, Color(1, 0.85, 0.4, 0.9 if pressed else 0.55), 1.5)
		draw_string(font, b.pos + Vector2(-b.r, 3), b.label, HORIZONTAL_ALIGNMENT_CENTER, b.r * 2.0, 7,
			Color(1, 1, 1, 0.95 if pressed else 0.7))


func _draw_stick(origin: Vector2, vec: Vector2, live: bool, label: String) -> void:
	var a := 0.45 if live else 0.18
	draw_circle(origin, STICK_RADIUS, Color(0.1, 0.1, 0.12, a * 0.6))
	draw_arc(origin, STICK_RADIUS, 0.0, TAU, 40, Color(1, 1, 1, a), 1.5)
	var knob_color := Color(1, 0.85, 0.4, a + 0.2)
	if label != "MOVE" and vec.length() > FIRE_THRESHOLD:
		knob_color = Color(1, 0.4, 0.3, 0.8)  # firing
	draw_circle(origin + vec * STICK_RADIUS, KNOB_RADIUS, knob_color)
	if not live:
		draw_string(get_theme_default_font(), origin + Vector2(-STICK_RADIUS, STICK_RADIUS + 10), label,
			HORIZONTAL_ALIGNMENT_CENTER, STICK_RADIUS * 2.0, 7, Color(1, 1, 1, 0.4))
