class_name GameCamera
extends Camera2D
## Follows the player, switches to the car while driving, looks ahead along
## velocity, zooms out with speed, and shakes on EventBus requests.

@export var target: Node2D
@export var follow_sharpness := 8.0
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
var _play_bounds := Rect2()
var _follow_center := Vector2.ZERO
var _zoom_level := 1.0
var _lead := Vector2.ZERO


func _ready() -> void:
	process_callback = Camera2D.CAMERA2D_PROCESS_IDLE
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


func set_play_bounds(bounds: Rect2) -> void:
	_play_bounds = bounds
	_snapped = false


func _process(delta: float) -> void:
	if not is_instance_valid(target):
		return
	var vel: Vector2 = target.velocity if target is CharacterBody2D else Vector2.ZERO
	_lead = _lead.lerp((vel * look_ahead).limit_length(108.0), 1.0 - exp(-5.0 * delta))
	var desired := target.global_position + _lead
	if not _snapped:
		_snapped = true
		_lead = Vector2.ZERO
		_follow_center = target.global_position
		reset_smoothing()

	var z := on_foot_zoom
	if target is Car:
		var t := clampf(vel.length() / (target as Car).stats.top_speed, 0.0, 1.0)
		z = lerpf(on_foot_zoom, max_speed_zoom, t)
	_zoom_level = lerpf(_zoom_level, z, 1.0 - exp(-zoom_sharpness * delta))
	var view := get_viewport_rect().size
	var zoom_fit := 0.0
	if _play_bounds.has_area():
		zoom_fit = maxf(view.x / _play_bounds.size.x, view.y / _play_bounds.size.y)
	zoom = Vector2.ONE * maxf(_zoom_level, zoom_fit)
	var half_view := view / (2.0 * zoom)
	_follow_center = _follow_center.lerp(_clamp_center(desired, half_view),
		1.0 - exp(-follow_sharpness * delta))

	var jitter := Vector2.ZERO
	if _shake_left > 0.0:
		_shake_left = maxf(_shake_left - delta, 0.0)
		var k := _shake_strength * (_shake_left / _shake_duration)
		jitter = Vector2(randf_range(-k, k), randf_range(-k, k))
	global_position = _clamp_center(_follow_center + jitter, half_view)


func _clamp_center(center: Vector2, half_view: Vector2) -> Vector2:
	if not _play_bounds.has_area():
		return center
	var inset := half_view.min(_play_bounds.size * 0.5)
	return center.clamp(_play_bounds.position + inset, _play_bounds.end - inset)


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
