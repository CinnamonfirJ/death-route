extends Control
## Draws a marker over each waypoint target: a bobbing tag when on screen,
## an edge arrow with distance when off screen. Fed by EventBus.waypoint_set/cleared.

const EDGE_MARGIN := 18.0
## World px per displayed metre.
const PX_PER_M := 16.0

var _targets: Dictionary = {}   # Node2D -> label


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	set_anchors_preset(Control.PRESET_FULL_RECT)
	EventBus.waypoint_set.connect(func(t: Node2D, label: String) -> void: _targets[t] = label)
	EventBus.waypoint_cleared.connect(func(t: Node2D) -> void: _targets.erase(t))


func _process(_delta: float) -> void:
	queue_redraw()


func _draw() -> void:
	var view := get_viewport_rect()
	var to_screen := get_viewport().get_canvas_transform()
	var player := Net.local_player() as Node2D
	var font := get_theme_default_font()
	var used: Array[Vector2] = []  # edge arrows already drawn this frame
	for target in _targets.keys():
		if not is_instance_valid(target):
			_targets.erase(target)
			continue
		var label: String = _targets[target]
		var screen: Vector2 = to_screen * (target.global_position + Vector2(0, -40))
		var inner := view.grow(-EDGE_MARGIN)
		var color := Color(1.0, 0.85, 0.3)
		if inner.has_point(screen):
			var bob := sin(Time.get_ticks_msec() * 0.006) * 2.0
			var tip := screen + Vector2(0, bob)
			draw_colored_polygon(PackedVector2Array([tip, tip + Vector2(-5, -8), tip + Vector2(5, -8)]), color)
			_draw_label(font, tip + Vector2(0, -11), label, color)
			continue
		var center := view.get_center()
		var dir := (screen - center).normalized()
		var edge := _avoid_hud(_clamp_to_rect(center, dir, inner))
		# Arrows sharing a spot (same direction, or pushed below the HUD) stack downward.
		var moved := true
		while moved:
			moved = false
			for u in used:
				if u.distance_to(edge) < 16.0:
					edge.y = u.y + 16.0
					moved = true
		used.append(edge)
		var ang := dir.angle()
		var tri := PackedVector2Array([
			edge + Vector2(9, 0).rotated(ang),
			edge + Vector2(-5, -6).rotated(ang),
			edge + Vector2(-5, 6).rotated(ang)])
		draw_colored_polygon(tri, color)
		var dist := 0
		if player:
			dist = roundi(player.global_position.distance_to(target.global_position) / PX_PER_M)
		var text := "%s %dm" % [label, dist]
		_draw_label(font, edge - dir * 22.0 + Vector2(0, 3), text, color)


func _draw_label(font: Font, center: Vector2, text: String, color: Color) -> void:
	var width := font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, 9).x
	var start := center - Vector2(width * 0.5, 0)
	draw_string_outline(font, start, text, HORIZONTAL_ALIGNMENT_LEFT, -1, 9, 3, Color.BLACK)
	draw_string(font, start, text, HORIZONTAL_ALIGNMENT_LEFT, -1, 9, color)


## Edge arrows that would land on a HUD panel slide down to just below it.
func _avoid_hud(p: Vector2) -> Vector2:
	for panel_name in [^"TopLeft", ^"TopRight"]:
		var panel := get_parent().get_node_or_null(panel_name) as Control
		if panel == null or not panel.visible:
			continue
		var r := panel.get_global_rect().grow(8.0)
		if r.has_point(p):
			p.y = r.end.y + 6.0
	return p


## Where a ray from `origin` along `dir` leaves `rect`.
func _clamp_to_rect(origin: Vector2, dir: Vector2, rect: Rect2) -> Vector2:
	var t := INF
	if dir.x > 0.0:
		t = minf(t, (rect.end.x - origin.x) / dir.x)
	elif dir.x < 0.0:
		t = minf(t, (rect.position.x - origin.x) / dir.x)
	if dir.y > 0.0:
		t = minf(t, (rect.end.y - origin.y) / dir.y)
	elif dir.y < 0.0:
		t = minf(t, (rect.position.y - origin.y) / dir.y)
	return origin + dir * t
