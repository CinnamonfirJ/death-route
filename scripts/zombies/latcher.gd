class_name Latcher
extends Zombie
## Fast runner that jumps onto the car and chews through it.
## Counters: mash [Q] (shove), handbrake drift, or get out and shoot it off.

@export var latch_range := 30.0
## Car HP per second while latched (reduced by the car's latch_resist).
@export var latch_dps := 6.0
## Shoves needed to throw it off.
@export var grip_max := 5
## Car lateral slip (px/s) during a handbrake drift that flings latchers off.
@export var drift_fling_slip := 140.0
@export var fall_damage := 12.0

var latched_car: Car = null
var _latch_offset := Vector2.ZERO
var _grip := 0


func _physics_process(delta: float) -> void:
	if latched_car != null:
		_latched_update(delta)
	else:
		super(delta)


func _try_attack(target: Node2D, delta: float) -> void:
	if target is Car:
		var car := target as Car
		if not car.is_destroyed and car.latchers.size() < 3 \
				and global_position.distance_to(car.global_position) <= latch_range:
			_latch(car)
		return
	super(target, delta)


func _latch(car: Car) -> void:
	latched_car = car
	_latch_offset = car.to_local(global_position).limit_length(12.0)
	_grip = grip_max
	_knockback = Vector2.ZERO
	z_index = 2
	car.add_latcher(self)
	_play(&"hit")
	EventBus.zombie_latched.emit(car, self)


func _latched_update(delta: float) -> void:
	var car := latched_car
	if not is_instance_valid(car) or car.is_destroyed:
		unlatch(Vector2.ZERO)
		return
	global_position = car.to_global(_latch_offset) + Vector2(randf_range(-1, 1), randf_range(-1, 1))
	car.take_damage(latch_dps * (1.0 - car.stats.latch_resist) * delta)
	if car.is_handbraking and car.get_slip() > drift_fling_slip:
		_throw_off(car)
		return
	_play(&"hit")


## One shove from the driver. Enough shoves and it's off.
func shove() -> void:
	if latched_car == null:
		return
	_grip -= 1
	sprite.rotation = randf_range(-0.4, 0.4)
	if _grip <= 0:
		_throw_off(latched_car)


func _throw_off(car: Car) -> void:
	var away := car.global_position.direction_to(global_position)
	if away == Vector2.ZERO:
		away = car.global_transform.x
	unlatch(away * 260.0 + car.velocity * 0.5)
	take_damage(fall_damage)


func unlatch(fling: Vector2) -> void:
	if latched_car == null:
		return
	if is_instance_valid(latched_car):
		latched_car.remove_latcher(self)
		EventBus.zombie_unlatched.emit(latched_car, self)
	latched_car = null
	z_index = 0
	sprite.rotation = 0.0
	stun(1.2, fling)


func take_damage(amount: float, knockback := Vector2.ZERO) -> void:
	if latched_car != null:
		_grip -= 3  # a bullet loosens its grip a lot
		knockback = Vector2.ZERO
		super(amount, knockback)
		if not is_dead and _grip <= 0:
			_throw_off(latched_car)
		return
	super(amount, knockback)


func die(by_car: bool, fling := Vector2.ZERO) -> void:
	if latched_car != null:
		if is_instance_valid(latched_car):
			latched_car.remove_latcher(self)
		latched_car = null
		z_index = 0
	super(by_car, fling)
