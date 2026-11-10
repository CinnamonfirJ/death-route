class_name Stopper
extends Zombie
## Heavy. Plants itself in the car's path and stops it dead (it's on the "heavy"
## physics layer, which cars collide with).
## Counters:
##   - Handbrake-drift into it: shoved aside, car keeps most of its speed.
##   - On foot: it charges in a straight line. Bait it into a wall or wreck to stun
##     and hurt it badly.

const HEAVY_LAYER := 7

@export var charge_trigger_range := 150.0
@export var charge_speed := 175.0
@export var charge_windup := 0.6
@export var charge_duration := 1.3
@export var charge_hit_damage := 25.0
@export var wall_stun := 3.0
@export var wall_damage := 60.0
## Car lateral slip (px/s) at impact that counts as a drift shove.
@export var shove_slip := 110.0

enum Mode { NORMAL, WINDUP, CHARGING }

var _mode := Mode.NORMAL
var _mode_left := 0.0
var _charge_dir := Vector2.ZERO
var _charge_cd := 0.0


func _think(delta: float) -> void:
	_charge_cd -= delta
	match _mode:
		Mode.WINDUP:
			_desired = Vector2.ZERO
			_mode_left -= delta
			sprite.position.x = randf_range(-1.5, 1.5)  # shaking tell
			if _mode_left <= 0.0:
				sprite.position.x = 0.0
				_mode = Mode.CHARGING
				_mode_left = charge_duration
			return
		Mode.CHARGING:
			_desired = _charge_dir * charge_speed
			_mode_left -= delta
			if _mode_left <= 0.0:
				_end_charge(1.5)
			return

	var target := _find_target()
	if target is Car and global_position.distance_to(target.global_position) < aggro_radius * 1.5:
		# Stand in the road: head for where the car is going, then plant.
		var car := target as Car
		var ahead := car.global_position + car.velocity * 0.7
		if global_position.distance_to(car.global_position) < 80.0:
			_desired = Vector2.ZERO
		else:
			_desired = _steer_to(ahead, chase_speed)
		_try_attack(target, delta)
		return
	if target is Player and _charge_cd <= 0.0:
		var d := global_position.distance_to(target.global_position)
		if d < charge_trigger_range and d > 30.0:
			_mode = Mode.WINDUP
			_mode_left = charge_windup
			_charge_dir = global_position.direction_to(target.global_position)
			_bubble(&"popup_1")
			_desired = Vector2.ZERO
			return
	super(delta)


func _after_move() -> void:
	if _mode != Mode.CHARGING:
		return
	for i in get_slide_collision_count():
		var other := get_slide_collision(i).get_collider()
		if other is Player:
			other.take_damage(charge_hit_damage, _charge_dir * 320.0)
			_end_charge(1.0)
			return
		if other is StaticBody2D:
			# Baited into a wall/wreck.
			take_damage(wall_damage)
			EventBus.screen_shake_requested.emit(5.0, 0.25)
			_end_charge(wall_stun)
			return


func _end_charge(cooldown_stun: float) -> void:
	_mode = Mode.NORMAL
	_charge_cd = 2.5
	stun(cooldown_stun)


func _animate() -> void:
	if _mode == Mode.WINDUP:
		_play(&"idle")
		return
	super()
	sprite.speed_scale = 2.0 if _mode == Mode.CHARGING else 1.0


## Ram trigger fires before the bodies touch; the real response is on_car_impact.
func on_rammed(_car: Node2D, _v: Vector2, _dmg: float) -> void:
	pass


## Called by Car when its body hits ours. Returns nothing; may change car.velocity.
func on_car_impact(car: Car, pre_velocity: Vector2, slip: float) -> void:
	if is_dead:
		return
	var impact := pre_velocity.length()
	if car.is_handbraking and slip > shove_slip:
		# Drift shove: knock it aside and keep going.
		var side := pre_velocity.normalized().orthogonal()
		if side.dot(global_position - car.global_position) < 0.0:
			side = -side
		_apply_shove(side)
		car.velocity = pre_velocity * 0.85
		EventBus.screen_shake_requested.emit(4.0, 0.15)
	else:
		# Dead stop.
		car.velocity = Vector2.ZERO
		car.take_damage(4.0 + impact * 0.05)
		take_damage(impact * 0.08, pre_velocity.normalized() * 40.0)
		EventBus.screen_shake_requested.emit(clampf(impact / 40.0, 3.0, 9.0), 0.3)
	EventBus.noise_increased.emit(4.0, global_position)


## Knocked aside by a drifting car. Online the host applies it; the driver's copy
## also lets the car through immediately so it doesn't bounce off a stale position.
func _apply_shove(side: Vector2) -> void:
	_pass_through_for(0.8)
	if _forward(&"_rpc_shove", [side]):
		return
	take_damage(20.0)
	stun(1.5, side * 260.0)


@rpc("any_peer", "reliable")
func _rpc_shove(side: Vector2) -> void:
	_apply_shove(side)


func _pass_through_for(seconds: float) -> void:
	set_collision_layer_value(HEAVY_LAYER, false)
	get_tree().create_timer(seconds, false, true).timeout.connect(func() -> void:
		if is_instance_valid(self) and not is_dead:
			set_collision_layer_value(HEAVY_LAYER, true))
