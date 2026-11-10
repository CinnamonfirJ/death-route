class_name Car
extends CharacterBody2D
## Top-down arcade car. Sprite nose points UP, so forward = -transform.y.
##
## Model: velocity is split into forward and lateral parts relative to the
## car's heading each tick. Throttle/brake act on the forward part; lateral
## velocity decays by `grip`. Releasing grip (handbrake) lets momentum carry
## sideways -> drift.

signal destroyed(car: Car)

const SPRITE_SCALE := 2.0
const EXIT_SPEED_LIMIT := 60.0

@export var vehicle_id: StringName = &"delivery_hatch"
## Optional authored stats. If null, loads res://resources/cars/<vehicle_id>.tres
## (falling back to the asset manifest).
@export var stats: CarStats
@export_range(0.0, 1.0) var start_hp_ratio := 1.0
@export_range(0.0, 1.0) var start_fuel_ratio := 1.0
## Garage upgrades apply to every car the handyman drives (parts move with you).
@export var apply_player_upgrades := true
## Randomizes speed/accel/HP/handling by +/- this fraction (scavenged cars).
@export_range(0.0, 0.5) var stat_variance := 0.0

@export_group("Ramming")
@export var min_ram_speed := 70.0
@export var ram_damage_per_speed := 0.4
@export var ram_self_damage := 1.0
## Fraction of speed kept after each ram.
@export var ram_speed_keep := 0.92

@export_group("Crashes")
@export var crash_speed_threshold := 150.0
@export var crash_damage_per_speed := 0.08

@export_group("Noise")
## Noise per second at full throttle (engine).
@export var engine_noise_per_sec := 1.5
@export var crash_noise := 6.0

var hp: float
var fuel: float
var driver: Node2D = null
var is_destroyed := false
var is_handbraking := false
## Zombies currently latched on (see Latcher).
var latchers: Array[Node2D] = []
## Companions riding along (see Companion). 3 seats besides the driver.
var passengers: Array[Node2D] = []
const SEATS := 3
var _jammed_until := 0
## Online: peer id of whoever is driving (0 = nobody). Every peer knows it; only the
## driver's machine has `driver` set and simulates the car.
var driver_id := 0
var _remote_latch_count := 0

var _steer := 0.0
var _rammed_at := {}           # instance_id -> msec of last ram
var _last_fuel_int := -1
var _skid_lines: Array[Line2D] = []
var _flash_tween: Tween

@onready var sprite: Sprite2D = $Sprite2D
@onready var body_shape: CollisionShape2D = $CollisionShape2D
@onready var ram_area: Area2D = $RamArea
@onready var ram_shape: CollisionShape2D = $RamArea/CollisionShape2D


func _ready() -> void:
	if stats == null:
		var path := "res://resources/cars/%s.tres" % vehicle_id
		stats = load(path) if ResourceLoader.exists(path) else Assets.car_stats(vehicle_id)
	# Always work on a copy so upgrades/variance never touch the shared resource.
	stats = GameManager.upgraded_car_stats(stats) if apply_player_upgrades else stats.duplicate()
	if stat_variance > 0.0:
		_randomize_stats()
	sprite.texture = stats.sprite
	sprite.scale = Vector2.ONE * SPRITE_SCALE
	_fit_shapes()
	# Move before other bodies each tick so the riding driver copies this frame's position.
	process_physics_priority = -1
	hp = stats.max_hp * start_hp_ratio
	fuel = stats.fuel_capacity * start_fuel_ratio
	add_to_group(&"cars")
	Net.attach_sync(self, [".:position", ".:rotation", ".:velocity"],
		[".:hp", ".:fuel", ".:is_handbraking"])
	_engine = Sfx.loop_player(&"engine", self)
	EventBus.car_spawned.emit(self)


var _engine: AudioStreamPlayer2D


## Engine hum while someone's driving; pitch climbs with speed (all machines).
func _process(_delta: float) -> void:
	if _engine == null:
		return
	var driven := has_driver() and not is_destroyed
	if driven != _engine.playing:
		if driven:
			_engine.play()
		else:
			_engine.stop()
	if driven:
		var t := clampf(velocity.length() / stats.top_speed, 0.0, 1.0)
		_engine.pitch_scale = 0.75 + t * 0.9
		_engine.volume_db = -12.0 + t * 6.0


func _randomize_stats() -> void:
	var v := stat_variance
	stats.top_speed *= randf_range(1.0 - v, 1.0 + v)
	stats.acceleration *= randf_range(1.0 - v, 1.0 + v)
	stats.max_hp *= randf_range(1.0 - v, 1.0 + v)
	stats.turn_rate *= randf_range(1.0 - v, 1.0 + v)


func _fit_shapes() -> void:
	var size := stats.sprite.get_size() * SPRITE_SCALE
	var body := RectangleShape2D.new()
	body.size = size - Vector2(4, 4)
	body_shape.shape = body
	# Ram zone is a bit wider and longer so zombies are hit before they touch the body.
	var ram := RectangleShape2D.new()
	ram.size = size + Vector2(8, 14)
	ram_shape.shape = ram


# ---------- Driving ----------

func _physics_process(delta: float) -> void:
	if not Net.is_local_authority(self):
		return  # driven (or parked) on another machine; we mirror it
	var throttle := 0.0
	var steer_in := 0.0
	var handbrake := false
	if driver != null and not is_destroyed:
		throttle = Input.get_axis(&"move_down", &"move_up")
		steer_in = Input.get_axis(&"move_left", &"move_right")
		handbrake = Input.is_action_pressed(&"handbrake")
	is_handbraking = handbrake
	_steer = move_toward(_steer, steer_in, delta * 8.0)

	# Steering scales with speed (no turning on the spot) and flips in reverse.
	var fwd := -global_transform.y
	var fwd_speed := velocity.dot(fwd)
	var speed_factor := clampf(absf(fwd_speed) / (stats.top_speed * 0.3), 0.0, 1.0)
	var turn := _steer * stats.turn_rate * speed_factor * signf(fwd_speed)
	if handbrake:
		turn *= stats.handbrake_turn_mult
	rotation += turn * delta

	# Re-split velocity against the new heading.
	fwd = -global_transform.y
	fwd_speed = velocity.dot(fwd)
	var lateral := velocity - fwd * fwd_speed

	var braking := throttle != 0.0 and signf(throttle) != signf(fwd_speed) and absf(fwd_speed) > 5.0
	if fuel <= 0.0 and not braking:
		throttle = 0.0

	if braking:
		fwd_speed = move_toward(fwd_speed, 0.0, stats.brake_force * delta)
	elif throttle > 0.0:
		fwd_speed += stats.acceleration * throttle * delta
	elif throttle < 0.0:
		fwd_speed += stats.acceleration * 0.6 * throttle * delta
	else:
		fwd_speed = move_toward(fwd_speed, 0.0, stats.coast_decel * delta)
	if handbrake:
		fwd_speed = move_toward(fwd_speed, 0.0, stats.handbrake_decel * delta)
	fwd_speed = clampf(fwd_speed, -stats.top_speed * stats.reverse_speed_ratio, stats.top_speed)

	var grip := stats.drift_grip if handbrake else stats.grip
	lateral *= exp(-grip * delta)
	velocity = fwd * fwd_speed + lateral

	if throttle != 0.0 and not braking:
		_burn_fuel(absf(throttle) * stats.fuel_burn_rate * delta)
		EventBus.noise_increased.emit(absf(throttle) * engine_noise_per_sec * delta, global_position)

	var pre_velocity := velocity
	move_and_slide()
	_handle_crashes(pre_velocity)
	_handle_ramming()
	_update_skids(handbrake and lateral.length() > 40.0 or lateral.length() > 120.0)


func _burn_fuel(amount: float) -> void:
	fuel = maxf(fuel - amount, 0.0)
	var as_int := int(ceil(fuel))
	if as_int != _last_fuel_int:
		_last_fuel_int = as_int
		EventBus.car_fuel_changed.emit(self, fuel, stats.fuel_capacity)


## Objects with on_car_impact(car, pre_velocity, slip) (Stopper, Brute, barrels)
## handle the hit themselves and may rewrite our velocity. Anything else is a crash.
func _handle_crashes(pre_velocity: Vector2) -> void:
	var fwd := -global_transform.y
	var slip := (pre_velocity - fwd * pre_velocity.dot(fwd)).length()
	for i in get_slide_collision_count():
		var c := get_slide_collision(i)
		var other := c.get_collider()
		if other != null and other.has_method(&"on_car_impact"):
			other.on_car_impact(self, pre_velocity, slip)
			return
		var impact := -pre_velocity.dot(c.get_normal())
		if impact > crash_speed_threshold:
			take_damage((impact - crash_speed_threshold) * crash_damage_per_speed + 2.0)
			EventBus.screen_shake_requested.emit(clampf(impact / stats.top_speed, 0.3, 1.0) * 7.0, 0.25)
			Fx.impact(c.get_position(), c.get_normal().angle() + PI)
			Sfx.play(&"crash", global_position)
			EventBus.noise_increased.emit(crash_noise, global_position)
			return


## Sideways speed (px/s). High while drifting.
func get_slip() -> float:
	var fwd := -global_transform.y
	return (velocity - fwd * velocity.dot(fwd)).length()


func _handle_ramming() -> void:
	var speed := velocity.length()
	if speed < min_ram_speed:
		return
	var now := Time.get_ticks_msec()
	if _rammed_at.size() > 64:
		_rammed_at.clear()
	for body in ram_area.get_overlapping_bodies():
		if not body.has_method(&"on_rammed"):
			continue
		if velocity.dot(body.global_position - global_position) <= 0.0:
			continue  # moving away from it
		var id := body.get_instance_id()
		if now - int(_rammed_at.get(id, -10000)) < 400:
			continue
		_rammed_at[id] = now
		body.on_rammed(self, velocity, speed * ram_damage_per_speed * stats.ram_mult)
		Sfx.play(&"ram", global_position)
		take_damage(ram_self_damage)
		velocity *= ram_speed_keep
		EventBus.screen_shake_requested.emit(clampf(speed / stats.top_speed, 0.3, 1.0) * 4.0, 0.15)


# ---------- Skid marks ----------

func _update_skids(drifting: bool) -> void:
	if drifting and absf(velocity.length()) > 40.0:
		if _skid_lines.is_empty():
			var layer := _decal_layer()
			for i in 2:
				var line := Line2D.new()
				line.width = 3.0
				line.default_color = Color(0.12, 0.08, 0.05, 0.45)
				layer.add_child(line)
				_skid_lines.append(line)
		var half := stats.sprite.get_size() * SPRITE_SCALE * 0.5
		var rear := global_transform.y * (half.y - 6.0)
		var side := global_transform.x * (half.x - 4.0)
		_skid_lines[0].add_point(global_position + rear - side)
		_skid_lines[1].add_point(global_position + rear + side)
		if _skid_lines[0].get_point_count() > 240:
			_end_skids()
	elif not _skid_lines.is_empty():
		_end_skids()


func _end_skids() -> void:
	for line in _skid_lines:
		var t := line.create_tween()
		t.tween_interval(4.0)
		t.tween_property(line, "modulate:a", 0.0, 2.0)
		t.tween_callback(line.queue_free)
	_skid_lines.clear()


func _decal_layer() -> Node:
	var layer := get_tree().get_first_node_in_group(&"decals")
	return layer if layer != null else get_parent()


# ---------- Health ----------

func take_damage(amount: float, _knockback := Vector2.ZERO) -> void:
	if is_destroyed:
		return
	if not Net.is_local_authority(self):
		_rpc_take_damage.rpc_id(get_multiplayer_authority(), amount)
		return
	hp = maxf(hp - amount, 0.0)
	EventBus.car_damaged.emit(self, amount, hp)
	if amount >= 3.0:  # chip damage from ramming walkers shouldn't strobe the car red
		_flash()
	if hp <= 0.0:
		_destroy()


func repair(amount: float) -> void:
	if is_destroyed:
		return
	hp = minf(hp + amount, stats.max_hp)
	EventBus.car_damaged.emit(self, -amount, hp)


func add_fuel(amount: float) -> void:
	if is_destroyed:
		return
	if not Net.is_local_authority(self):
		_rpc_add_fuel.rpc_id(get_multiplayer_authority(), amount)
		return
	fuel = clampf(fuel + amount, 0.0, stats.fuel_capacity)  # negative = siphoned
	_last_fuel_int = -1
	_burn_fuel(0.0)  # emits car_fuel_changed


# ---------- Latchers ----------

func add_latcher(z: Node2D) -> void:
	if not latchers.has(z):
		latchers.append(z)
	_share_latch_count()


func remove_latcher(z: Node2D) -> void:
	latchers.erase(z)
	_share_latch_count()


## How many zombies are clinging on (works on every machine).
func latch_count() -> int:
	return latchers.size() if Net.is_sim_authority() else _remote_latch_count


func _share_latch_count() -> void:
	if Net.is_host():
		_rpc_latch_count.rpc(latchers.size())


@rpc("authority", "reliable")
func _rpc_latch_count(n: int) -> void:
	_remote_latch_count = n


## Sabotage: doors won't open for a few seconds (rival's work).
func jam_doors(seconds: float) -> void:
	if not Net.is_local_authority(self):
		_rpc_jam.rpc_id(get_multiplayer_authority(), seconds)
		return
	_jammed_until = Time.get_ticks_msec() + roundi(seconds * 1000.0)


@rpc("any_peer", "reliable")
func _rpc_jam(seconds: float) -> void:
	jam_doors(seconds)


@rpc("any_peer", "reliable")
func _rpc_take_damage(amount: float) -> void:
	take_damage(amount)


@rpc("any_peer", "reliable")
func _rpc_add_fuel(amount: float) -> void:
	add_fuel(amount)


func is_door_jammed() -> bool:
	return Time.get_ticks_msec() < _jammed_until


## Following companions near the car hop in when the driver does.
func board_party(near: Vector2) -> void:
	for c in get_tree().get_nodes_in_group(&"companions"):
		if passengers.size() >= SEATS:
			return
		if c.is_following() and c.global_position.distance_to(near) < 160.0:
			passengers.append(c)
			c.board(self)


## Everyone out, scattered around `spot`.
func unload_party(spot: Vector2, damage := 0.0) -> void:
	var i := 0
	for c in passengers.duplicate():
		if is_instance_valid(c):
			c.disembark(spot + Vector2(14, 0).rotated(i * 2.1) + Vector2(0, 10), damage)
		i += 1
	passengers.clear()


## Driver mashes [Q]: every latcher loses some grip.
func shove_latchers() -> void:
	if not Net.is_sim_authority():
		_rpc_shove.rpc_id(1)  # latchers live on the host
		sprite.rotation = randf_range(-0.06, 0.06)
		create_tween().tween_property(sprite, "rotation", 0.0, 0.1)
		return
	for z in latchers.duplicate():
		if is_instance_valid(z):
			z.shove()
	sprite.rotation = randf_range(-0.06, 0.06)
	create_tween().tween_property(sprite, "rotation", 0.0, 0.1)


func _flash() -> void:
	if _flash_tween:
		_flash_tween.kill()
	sprite.modulate = Color(1.0, 0.45, 0.45)
	_flash_tween = create_tween()
	_flash_tween.tween_property(sprite, "modulate", Color.WHITE, 0.15)


@rpc("any_peer", "reliable")
func _rpc_shove() -> void:
	shove_latchers()


## Runs on the car's authority; online every machine plays the wreck.
func _destroy() -> void:
	if Net.is_online():
		_rpc_destroyed.rpc()
	else:
		_apply_destroyed()


@rpc("any_peer", "call_local", "reliable")
func _rpc_destroyed() -> void:
	_apply_destroyed()


func _apply_destroyed() -> void:
	if is_destroyed:
		return
	is_destroyed = true
	if _flash_tween:
		_flash_tween.kill()
	sprite.modulate = Color(0.3, 0.27, 0.27)
	for z in latchers.duplicate():
		if is_instance_valid(z):
			z.unlatch(global_position.direction_to(z.global_position) * 300.0)
	latchers.clear()
	OneShotEffect.spawn(get_parent(), &"explosion", global_position, 1.3)
	Fx.explosion(global_position, 1.0)
	Sfx.play(&"explosion", global_position)
	if Net.is_sim_authority():
		EventBus.noise_increased.emit(30.0, global_position)
	EventBus.screen_shake_requested.emit(10.0, 0.5)
	destroyed.emit(self)
	EventBus.car_destroyed.emit(self)


# ---------- Interaction (used by Player) ----------

func can_interact(_player: Node) -> bool:
	return not is_destroyed and not has_driver()


func has_driver() -> bool:
	return driver != null or driver_id != 0


func get_interact_prompt(_player: Node) -> String:
	return "[E] Drive %s  (%d%% HP)" % [stats.display_name, roundi(hp / stats.max_hp * 100.0)]


func interact(player: Node) -> void:
	player.enter_car(self)


func set_driver(d: Node2D) -> void:
	driver = d
	if Net.is_online():
		_rpc_set_driver.rpc(Net.local_id())


func clear_driver() -> void:
	driver = null
	if Net.is_online():
		_rpc_set_driver.rpc(0)


## Every machine: who drives, and therefore who simulates this car.
@rpc("any_peer", "call_local", "reliable")
func _rpc_set_driver(id: int) -> void:
	driver_id = id
	set_multiplayer_authority(id if id != 0 else 1)
	if id != Net.local_id():
		driver = null


func can_exit() -> bool:
	return velocity.length() < EXIT_SPEED_LIMIT
