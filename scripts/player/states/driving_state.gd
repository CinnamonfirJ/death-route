extends PlayerState
## Player is inside a car: body hidden, car reads the input, player rides along.

const ENTER_COOLDOWN := 0.3
const EJECT_DAMAGE := 25.0

var car: Car
var _cooldown := 0.0
var _passenger_damage := 0.0
var _prompt := ""


func enter(msg := {}) -> void:
	car = msg["car"]
	car.set_driver(player)
	player.current_car = car
	player.velocity = Vector2.ZERO
	player.set_body_enabled(false)
	car.destroyed.connect(_on_car_destroyed)
	car.board_party(player.global_position)
	_cooldown = ENTER_COOLDOWN
	EventBus.player_entered_car.emit(car)


func exit() -> void:
	if car:
		if car.destroyed.is_connected(_on_car_destroyed):
			car.destroyed.disconnect(_on_car_destroyed)
		# Passengers always get out with the driver, however the driver leaves.
		car.unload_party(car.global_position - car.global_transform.x * 28.0, _passenger_damage)
		_passenger_damage = 0.0
		car.clear_driver()
		EventBus.player_exited_car.emit(car)
	player.current_car = null
	car = null
	_set_prompt("")


func physics_update(delta: float) -> void:
	player.global_position = car.global_position
	_cooldown -= delta
	if Input.is_action_just_pressed(&"shove"):
		car.shove_latchers()
	var backseat := car.passengers.any(func(c) -> bool: return is_instance_valid(c) and c.is_turned)
	if backseat:
		_set_prompt("SOMETHING IN THE BACK SEAT!  Stop and get out [E]")
	elif car.latch_count() > 0:
		_set_prompt("LATCHED x%d!  Mash [Q] or handbrake-drift" % car.latch_count())
	else:
		_set_prompt("[E] Exit car" if car.can_exit() else "Slow down to exit")
	if _cooldown <= 0.0 and Input.is_action_just_pressed(&"interact"):
		try_exit()


## Gets out if the car is slow enough and there's room. Returns true on success.
func try_exit() -> bool:
	if car == null or not car.can_exit():
		return false
	if car.is_door_jammed():
		EventBus.hud_message.emit("The door won't open! It's jammed!")
		return false
	var spot = _find_exit_position()
	if spot == null:
		return false
	_leave_to(spot)
	return true


func _leave_to(spot: Vector2, passenger_damage := 0.0) -> void:
	_passenger_damage = passenger_damage
	state_machine.transition_to(&"OnFoot")
	player.global_position = spot


## Tries driver side, passenger side, rear, front. Returns null if all are blocked.
func _find_exit_position() -> Variant:
	var half := car.stats.sprite.get_size() * Car.SPRITE_SCALE * 0.5
	var side := car.global_transform.x * (half.x + 12.0)
	var back := car.global_transform.y * (half.y + 12.0)
	for offset in [-side, side, back, -back]:
		var spot: Vector2 = car.global_position + offset
		if _is_free(spot):
			return spot
	return null


func _is_free(spot: Vector2) -> bool:
	var params := PhysicsShapeQueryParameters2D.new()
	params.shape = player.collision.shape
	params.transform = Transform2D(0.0, spot + player.collision.position)
	params.collision_mask = player.collision_mask
	return player.get_world_2d().direct_space_state.intersect_shape(params, 1).is_empty()


func _on_car_destroyed(_c: Car) -> void:
	var spot = _find_exit_position()
	if spot == null:
		spot = car.global_position + car.global_transform.x * 40.0
	var blast_dir: Vector2 = (spot - car.global_position).normalized()
	_leave_to(spot, 15.0)
	player.take_damage(EJECT_DAMAGE, blast_dir * 200.0)


func _set_prompt(text: String) -> void:
	if text != _prompt:
		_prompt = text
		EventBus.interact_prompt_changed.emit(text)
