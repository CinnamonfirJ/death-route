class_name PizzaCargo
extends Node2D
## Co-op orders share the same cargo rules. Versus has one pizza per team, created by
## MatchState, hidden until its spawn timer runs out. The host decides pickup, drop,
## handoff (and in versus, steal / reset by enemies).

signal changed

const REACH := 38.0

@export var follow_stiffness := 85.0
@export var follow_damping := 12.0
@export var follow_leash := 52.0

var number := 1
var customer: Node2D
## Versus: owning team (-1 = co-op shared pizza).
var team := -1
var carrier_id := 0
var delivered := false
var _spawned := false
var _spawn_position := Vector2.ZERO
var _last_position := Vector2.ZERO
var _glow: Sprite2D
var _spring_velocity := Vector2.ZERO
var _travel_direction := Vector2.RIGHT

@onready var sprite: AnimatedSprite2D = $AnimatedSprite2D


func _ready() -> void:
	add_to_group(&"pizza_cargo")
	sprite.sprite_frames = Assets.item_frames("pizza")
	sprite.play(&"default")
	_glow = Fx.attach_glow(self, Color(1.0, 0.72, 0.33, 0.45), 0.95, Vector2(0, -9), 0.0)
	if team >= 0:
		visible = false  # not spawned yet
		add_to_group(&"team_pizzas")
		var tint := MatchState.team_color(team)
		sprite.self_modulate = Color(1, 1, 1).lerp(tint, 0.35)


func _drop_off() -> Node2D:
	if team >= 0 and customer == null:
		customer = MatchState.dropoff_of(team)
	return customer


func _is_owner(id: int) -> bool:
	return team < 0 or MatchState.team_of(id) == team


## Versus: only the owning team sees its pizza, unless an enemy is close.
func _process(_delta: float) -> void:
	if team < 0:
		return
	var show := _spawned and not delivered
	if show and not _is_owner(Net.local_id()):
		var me := Net.local_player() as Node2D
		show = me != null and me.global_position.distance_to(global_position) \
			<= MatchState.cfg.pizza_enemy_reveal_distance
	visible = show


func place(pos: Vector2) -> void:
	_spawn_position = pos
	_set_state(pos, 0, false)


func can_interact(player: Player) -> bool:
	return _spawned and carrier_id == 0 and not delivered and (team < 0 or visible)


func get_interact_prompt(player: Player) -> String:
	if _is_owner(player.get_multiplayer_authority()):
		return "[E] Pick up %s" % ("your pizza" if team >= 0 else "pizza for Order %d" % number)
	if _enemy_rule() == "steal":
		return "[E] Steal %s's pizza" % MatchState.team_name(team)
	return "[E] Toss %s's pizza (it respawns elsewhere)" % MatchState.team_name(team)


func _enemy_rule() -> String:
	return Net.settings.get("pizza_enemy", MatchState.cfg.pizza_enemy_action)


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
	if not _spawned or delivered or player == null or player.is_dead() or not player.visible or not player.is_on_foot():
		return
	var id := player.get_multiplayer_authority()
	var drop := _drop_off()
	if handoff and drop == null:
		return
	var target := drop.global_position if handoff else global_position
	if player.global_position.distance_squared_to(target) > REACH * REACH:
		return
	if handoff and carrier_id == id:
		if not _is_owner(id):
			return  # a stolen pizza can't be delivered
		_set_state(target, 0, true)
		if team >= 0:
			MatchState.on_pizza_delivered(team)
	elif not handoff and carrier_id == 0:
		if not _is_owner(id) and _enemy_rule() == "reset":
			Net.announce("%s tossed %s's pizza! It'll turn up somewhere else." % [
				Net.peer_name(id), MatchState.team_name(team)])
			MatchState.spawn_pizza(team)
			return
		_set_state(player.global_position, id, false)


func _physics_process(delta: float) -> void:
	if carrier_id == 0:
		return
	var carrier := _player_for(carrier_id)
	if carrier == null or carrier.is_dead():
		if Net.is_sim_authority():
			_set_state(_drop_position(), 0, false)
		return
	var car := Net.car_of(carrier)
	var anchor := car.global_position if is_instance_valid(car) else carrier.global_position
	var motion := anchor - _last_position
	_last_position = anchor
	if motion.length_squared() > 0.09:
		_travel_direction = _travel_direction.lerp(motion.normalized(), minf(delta * 10.0, 1.0))
	var rank := 0
	for order: PizzaCargo in get_tree().get_nodes_in_group(&"pizza_cargo"):
		if order != self and order.number < number and order.carrier_id == carrier_id:
			rank += 1
	var tail := _travel_direction * (15.0 + rank * 15.0)
	var target := anchor - tail + _travel_direction.orthogonal() * (7.0 if rank % 2 else -7.0)
	if global_position.distance_to(anchor) > follow_leash * 4.0:
		global_position = target
		_spring_velocity = Vector2.ZERO
	_spring_velocity += ((target - global_position) * follow_stiffness - _spring_velocity * follow_damping) * delta
	global_position += _spring_velocity * delta
	global_position = anchor + (global_position - anchor).limit_length(follow_leash)
	sprite.rotation = clampf(_spring_velocity.x * 0.008, -0.35, 0.35)


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
	_spring_velocity = Vector2.ZERO
	sprite.rotation = 0.0
	global_position = pos
	_last_position = pos
	carrier_id = new_carrier
	delivered = handed_off
	visible = not delivered
	var on_ground := carrier_id == 0
	sprite.scale = Vector2.ONE * (2.5 if on_ground else 1.5)
	sprite.position.y = -9.0 if on_ground else -14.0
	_glow.visible = on_ground
	if team >= 0:
		_update_waypoints()
		MatchState._refresh_hud()
	changed.emit()


## Versus: the owning team gets an arrow to its pizza (or to the drop-off while carrying it).
func _update_waypoints() -> void:
	if not _is_owner(Net.local_id()):
		return
	var drop := _drop_off()
	EventBus.waypoint_cleared.emit(self)
	if drop:
		EventBus.waypoint_cleared.emit(drop)
	if delivered or not _spawned:
		return
	if carrier_id != 0 and _is_owner(carrier_id):
		if drop:
			EventBus.waypoint_set.emit(drop, "DROP-OFF")
	else:
		EventBus.waypoint_set.emit(self, "PIZZA")
