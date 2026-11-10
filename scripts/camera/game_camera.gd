class_name GameCamera
extends Camera2D
## Follows the player, switches to the car while driving, looks ahead along
## velocity, zooms out with speed, and shakes on EventBus requests.

@export var target: Node2D
@export var follow_sharpness := 7.0
## Seconds of target velocity to lead by.
@export var look_ahead := 0.3
@export var on_foot_zoom := 1.0
## Zoom at the car's top speed (< 1 = zoomed out).
@export var max_speed_zoom := 0.75
@export var zoom_sharpness := 2.5

var _player: Node2D
var _snapped := false
var _shake_strength := 0.0
var _shake_duration := 0.0
var _shake_left := 0.0


func _ready() -> void:
	process_callback = Camera2D.CAMERA2D_PROCESS_PHYSICS
	_player = target
	EventBus.screen_shake_requested.connect(shake)
	EventBus.player_entered_car.connect(func(car: Node2D) -> void: target = car)
	EventBus.player_exited_car.connect(func(_car: Node2D) -> void: target = _player)
	# Online clients: follow our own handyman once the host spawns it.
	Net.local_player_spawned.connect(func(p: Node2D) -> void:
		_player = p
		target = p
		_snapped = false)
	if target:
		global_position = target.global_position
	make_current()


func _physics_process(delta: float) -> void:
	if target == null:
		return
	var vel: Vector2 = target.velocity if target is CharacterBody2D else Vector2.ZERO
	var desired := target.global_position + vel * look_ahead
	if not _snapped:
		# Levels may place the player after our _ready (map-built spawns): jump, don't pan.
		_snapped = true
		global_position = desired
		reset_smoothing()
	global_position = global_position.lerp(desired, 1.0 - exp(-follow_sharpness * delta))

	var z := on_foot_zoom
	if target is Car:
		var t := clampf(vel.length() / (target as Car).stats.top_speed, 0.0, 1.0)
		z = lerpf(on_foot_zoom, max_speed_zoom, t)
	zoom = zoom.lerp(Vector2(z, z), 1.0 - exp(-zoom_sharpness * delta))

	if _shake_left > 0.0:
		_shake_left -= delta
		var k := _shake_strength * (_shake_left / _shake_duration)
		offset = Vector2(randf_range(-k, k), randf_range(-k, k))
	else:
		offset = Vector2.ZERO


func shake(strength: float, duration: float) -> void:
	strength *= float(GameManager.get_setting("screen_shake"))
	if strength <= 0.0:
		return
	# Stronger shake wins; a weaker one never cuts a big one short.
	if _shake_left > 0.0 and strength * duration < _shake_strength * _shake_left:
		return
	_shake_strength = strength
	_shake_duration = maxf(duration, 0.01)
	_shake_left = _shake_duration
