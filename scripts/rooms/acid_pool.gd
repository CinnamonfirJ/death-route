@tool
extends Node2D
## Acid occupies the drawn polygon. It has no solid collider or navigation cutout.

@export var radii := Vector2(62, 43)
@export var player_tick_damage := 7.0
@export var zombie_tick_damage := 9.0
@export var tick_seconds := 0.65
@export var shore_color := Color("#36513a")
@export var surface_color := Color("#5f9f38")
@export var bubble_color := Color("#c3ef76")
@export var bubble_period := 2.5

var _elapsed := 0.0
var _tick := 0.0
var _outline := PackedVector2Array()


func _ready() -> void:
	add_to_group(&"acid_pool")
	for i in 20:
		var angle := TAU * i / 20.0
		_outline.append(Vector2.from_angle(angle) * radii * (0.92 + 0.08 * sin(i * 2.31)))
	set_process(not Engine.is_editor_hint())
	set_physics_process(not Engine.is_editor_hint())
	queue_redraw()


func contains(world_point: Vector2, clearance := 0.0) -> bool:
	var local := to_local(world_point)
	if clearance > 0.0:
		return (local / (radii + Vector2.ONE * clearance)).length_squared() <= 1.0
	return Geometry2D.is_point_in_polygon(local, _outline)


func _physics_process(delta: float) -> void:
	if not Net.is_sim_authority():
		return
	_tick += delta
	if _tick < tick_seconds:
		return
	_tick = fmod(_tick, tick_seconds)
	for player in Net.player_nodes():
		if player.visible and not player.is_dead() and contains(player.global_position):
			player.take_damage(player_tick_damage, Vector2.ZERO, true)
	for zombie in get_tree().get_nodes_in_group(&"zombies"):
		if contains(zombie.global_position):
			zombie.last_hitter = 0
			zombie.take_damage(zombie_tick_damage, Vector2.ZERO, true)


func _process(delta: float) -> void:
	var last := int(_elapsed * 12.0)
	_elapsed += delta
	if last != int(_elapsed * 12.0):
		queue_redraw()


func _draw() -> void:
	if _outline.is_empty():
		return
	draw_colored_polygon(_outline, shore_color)
	var inner := PackedVector2Array()
	for p in _outline:
		inner.append((p * 0.88).round())
	draw_colored_polygon(inner, surface_color)
	for i in 9:
		var phase := fposmod(_elapsed / bubble_period + i * 0.37, 1.0)
		var origin := Vector2.from_angle(i * 2.4) * radii * (0.19 + 0.055 * i)
		origin.y -= phase * 7.0
		var size := floorf(2.0 + phase * 3.0)
		draw_rect(Rect2(origin.round(), Vector2.ONE * size),
			Color(bubble_color, sin(phase * PI) * 0.76), false, 1.0)
