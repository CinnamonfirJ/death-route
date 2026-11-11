class_name PizzaCargo
extends Node2D
## One shared pizza per run. The host decides pickup, drop, and handoff.

signal changed

const REACH := 38.0

var customer: Node2D
var carrier_id := 0
var delivered := false
var _spawned := false
var _spawn_position := Vector2.ZERO
var _last_position := Vector2.ZERO
var _glow: Sprite2D

@onready var sprite: AnimatedSprite2D = $AnimatedSprite2D


func _ready() -> void:
	sprite.sprite_frames = Assets.item_frames("pizza")
	sprite.play(&"default")
	_glow = Fx.attach_glow(self, Color(1.0, 0.72, 0.33, 0.45), 0.95, Vector2(0, -9), 0.0)


func place(pos: Vector2) -> void:
	_spawn_position = pos
	_set_state(pos, 0, false)


func can_interact(_player: Player) -> bool:
	return _spawned and carrier_id == 0 and not delivered


func get_interact_prompt(_player: Player) -> String:
	return "[E] Pick up pizza"


func interact(player: Player) -> void:
	request_interaction(player, false)


func request_interaction(player: Player, handoff: bool) -> void:
	if Net.is_sim_authority():
		_try_interaction(player, handoff)
	else:
		_rpc_interact.rpc_id(1, handoff)


@rpc("any_peer", "reliable")
func _rpc_interact(handoff: bool) -> void:
	if Net.is_host():
		_try_interaction(_player_for(multiplayer.get_remote_sender_id()), handoff)


func _try_interaction(player: Player, handoff: bool) -> void:
	if not _spawned or delivered or player == null or player.is_dead() or not player.visible:
		return
	var id := player.get_multiplayer_authority()
	var target := customer.global_position if handoff else global_position
	if player.global_position.distance_squared_to(target) > REACH * REACH:
		return
	if handoff and carrier_id == id:
		_set_state(target, 0, true)
	elif not handoff and carrier_id == 0:
		_set_state(player.global_position, id, false)


func _physics_process(_delta: float) -> void:
	if carrier_id == 0:
		return
	var carrier := _player_for(carrier_id)
	if carrier == null or carrier.is_dead():
		if Net.is_sim_authority():
			_set_state(_drop_position(), 0, false)
		return
	var car := Net.car_of(carrier)
	_last_position = car.global_position if is_instance_valid(car) else carrier.global_position
	global_position = _last_position


func _drop_position() -> Vector2:
	# A carrier in a crashed car can end up inside a prop. Keep the pizza reachable.
	var probe := PhysicsPointQueryParameters2D.new()
	probe.position = _last_position
	probe.collision_mask = 1
	if get_world_2d().direct_space_state.intersect_point(probe, 1).is_empty():
		return _last_position
	return _spawn_position


func _player_for(id: int) -> Player:
	for player in Net.player_nodes():
		if player.get_multiplayer_authority() == id:
			return player
	return null


func _set_state(pos: Vector2, new_carrier: int, handed_off: bool) -> void:
	if Net.is_online():
		_apply_state.rpc(pos, new_carrier, handed_off)
	else:
		_apply_state(pos, new_carrier, handed_off)


@rpc("authority", "call_local", "reliable")
func _apply_state(pos: Vector2, new_carrier: int, handed_off: bool) -> void:
	_spawned = true
	global_position = pos
	_last_position = pos
	carrier_id = new_carrier
	delivered = handed_off
	visible = not delivered
	var on_ground := carrier_id == 0
	sprite.scale = Vector2.ONE * (2.5 if on_ground else 1.5)
	sprite.position.y = -9.0 if on_ground else -39.0
	_glow.visible = on_ground
	changed.emit()
