class_name Zombie
extends CharacterBody2D
## Base zombie (also the Walker). Pathfinds with NavigationAgent2D, melees, reacts to rams.
##
## Senses (no x-ray): zombies SEE players only inside a view cone (sight_range /
## sight_angle_deg in MatchConfig) with a clear line of sight: walls, props and
## buildings block it. Mostly they HEAR: gunshots, engines, horns, sprinting and fights
## make sound events (EventBus.sound_made) and zombies in range walk to where the sound
## came from (not to the player). Having lost you, they go to where they last saw you;
## either way they search for a few seconds, then go back to wandering.
##
## Subclasses override these hooks:
##   _think(delta)          -> sets _desired (velocity before knockback)
##   _try_attack(target, d) -> melee logic
##   _after_move()          -> inspect slide collisions
##   on_rammed / on_car_impact / take_damage / die

@export var zombie_id: StringName = &"zombie_walker"
@export var visual_id: StringName
@export var visual_tint := Color.WHITE
@export var voice: StringName = &"groan"
@export var attack_voice: StringName = &"zombie_attack"
@export var rush_speed_mult := 1.0
@export var rush_duration := 0.0
@export var rush_interval := 2.5
@export var stun_duration_mult := 1.0
var _rush_clock := 0.0
@export var max_hp := 30.0
@export var wander_speed := 14.0
@export var chase_speed := 38.0
## Legacy (co-op tuning): sight range now comes from MatchConfig.sight_range.
@export var aggro_radius := 220.0
## Multiplies the radius at which this zombie hears noise.
@export var hearing_mult := 1.0
@export var attack_range := 18.0
@export var attack_damage := 8.0
@export var car_attack_range := 30.0
@export var car_attack_damage := 2.0
@export var attack_cooldown := 1.0
## Chance a melee hit on a companion is a (secret) infecting bite.
@export_range(0.0, 1.0) var bite_chance := 0.35
## Walkers die instantly to any ram above the car's minimum ram speed.
@export var dies_to_ram := true
@export var corpse_lifetime := 4.0

@export_group("Ambient Audio")
@export var ambient_voice_range := 220.0
@export var ambient_voice_interval := Vector2(3.5, 8.0)
@export var ambient_voice_volume_db := -5.0

@export_group("Loot")
## Scrap dropped on death: random in [x, y]. (0, 0) = none.
@export var scrap_drop := Vector2i(0, 1)
@export_range(0.0, 1.0) var ammo_drop_chance := 0.08
@export var ammo_drop_amount := 6

@export_group("Night Silhouette")
@export var night_glow := Color(0.62, 0.82, 0.66, 0.20)
@export var night_glow_scale := 0.42
var _night_glow: Sprite2D

const REPATH_INTERVAL := 0.3
const DIRECT_CHASE_DIST := 36.0
const INVESTIGATE_TIME := 8.0

var hp: float
var is_dead := false

var _desired := Vector2.ZERO
var _knockback := Vector2.ZERO
var _attack_timer := 0.0
var _stun_left := 0.0
var _wander_dir := Vector2.ZERO
var _wander_timer := 0.0
var _repath_cd := 0.0
var _investigate_pos := Vector2.ZERO
var _investigate_left := 0.0
var _aggro := false
var _flash_tween: Tween

enum Sense { WANDER, CHASE, INVESTIGATE, SEARCH }
var sense := Sense.WANDER
## Peer that hit this zombie last (versus kill credit). 0 = nobody.
var last_hitter := 0
var _target: Node2D
var _last_seen := Vector2.ZERO
var _facing := Vector2.DOWN
var _vision_cd := randf() * 0.2
var _search_left := 0.0
var _search_turn := 0.0
var _step_cd := randf() * 0.5
var _senses: MatchConfig

@onready var sprite: AnimatedSprite2D = $AnimatedSprite2D
@onready var collision: CollisionShape2D = $CollisionShape2D
@onready var nav: NavigationAgent2D = $NavigationAgent2D


func _ready() -> void:
	hp = max_hp
	_senses = MatchConfig.get_config()
	_facing = Vector2.from_angle(randf() * TAU)
	add_to_group(&"zombies")
	var skin := visual_id if not visual_id.is_empty() else zombie_id
	var entry := Assets.character(skin)
	sprite.sprite_frames = Assets.character_frames(skin)
	var s := float(entry.get("scale", 1.0))
	sprite.scale = Vector2(s, s)
	Fx.attach_shadow(self, Vector2(22, 9) * s)
	sprite.self_modulate = Color(entry.get("tint", "#ffffff")) * visual_tint
	_night_glow = Fx.attach_glow(self, night_glow, night_glow_scale * s, Vector2(0, -12), 0.0)
	_night_glow.z_index = 0
	_night_glow.show_behind_parent = true
	sprite.play(&"idle")
	sprite.frame = randi() % sprite.sprite_frames.get_frame_count(&"idle")
	_wander_timer = randf_range(0.5, 3.0)
	_repath_cd = randf() * REPATH_INTERVAL  # stagger path queries across the horde
	_groan_cd = randf_range(0.0, ambient_voice_interval.x)
	Net.attach_sync(self, [".:position"],
		[".:is_dead", ".:hp", ".:z_index", "AnimatedSprite2D:animation", "AnimatedSprite2D:flip_h",
		"AnimatedSprite2D:rotation", "AnimatedSprite2D:modulate", "AnimatedSprite2D:speed_scale",
		"AnimatedSprite2D:position"])


func _physics_process(delta: float) -> void:
	if not Net.is_sim_authority():
		# The host runs zombie AI; here we only mirror it. Corpses stop blocking bullets.
		if is_dead and not collision.disabled:
			collision.set_deferred(&"disabled", true)
		_mirror_fx()
		return
	if is_dead:
		return
	_knockback = _knockback.move_toward(Vector2.ZERO, 700.0 * delta)
	_repath_cd -= delta
	_attack_timer -= delta
	if _stun_left > 0.0:
		_stun_left -= delta
		velocity = _knockback
		move_and_slide()
		_play(&"knocked")
		return
	_think(delta)
	velocity = _desired + _knockback
	move_and_slide()
	_after_move()
	_animate()


# ---------- Behaviour hooks ----------

func _think(delta: float) -> void:
	_vision_cd -= delta
	if _vision_cd <= 0.0:
		_vision_cd = 0.2
		var seen := _visible_target()
		if seen:
			if sense != Sense.CHASE:
				_bubble(&"popup_1")
			sense = Sense.CHASE
			_target = seen
			_last_seen = seen.global_position
		elif sense == Sense.CHASE:
			# Lost sight: walk to where we last saw them, then search.
			_bubble(&"popup_2")
			_go_investigate(_last_seen, INVESTIGATE_TIME)
			_rush_clock = 0.0
	match sense:
		Sense.CHASE:
			if not is_instance_valid(_target):
				_go_investigate(_last_seen, INVESTIGATE_TIME)
				return
			_rush_clock = fposmod(_rush_clock + delta, maxf(rush_interval, delta))
			var speed := chase_speed * rush_speed_mult if _rush_clock < rush_duration else chase_speed
			_desired = _steer_to(_target.global_position, speed)
			_try_attack(_target, delta)
		Sense.INVESTIGATE:
			_investigate_left -= delta
			_desired = _steer_to(_investigate_pos, chase_speed * 0.8)
			if global_position.distance_to(_investigate_pos) < 24.0 or _investigate_left <= 0.0:
				_start_search()
		Sense.SEARCH:
			_search_left -= delta
			_search_turn -= delta
			if _search_turn <= 0.0:
				_search_turn = randf_range(0.6, 1.1)
				_facing = Vector2.from_angle(randf() * TAU)  # look around
			_desired = _facing * wander_speed * 0.7
			if _search_left <= 0.0:
				sense = Sense.WANDER
		_:
			_desired = _wander(delta)
	if _desired.length_squared() > 1.0 and sense != Sense.SEARCH:
		_facing = _desired.normalized()


func _go_investigate(pos: Vector2, duration: float) -> void:
	sense = Sense.INVESTIGATE
	_investigate_pos = pos
	_investigate_left = duration


func _start_search() -> void:
	sense = Sense.SEARCH
	_search_left = _senses.search_time
	_search_turn = 0.0


## Nearest living player (or the car they drive) this zombie can actually see.
func _visible_target() -> Node2D:
	var best: Node2D = null
	var best_d := INF
	for p in Net.player_nodes():
		if p.is_dead():
			continue
		var t: Node2D = p if p.visible else Net.car_of(p)
		if t == null:
			continue
		var d := global_position.distance_squared_to(t.global_position)
		if d < best_d and can_see(t):
			best_d = d
			best = t
	return best


## View cone + line of sight. Walls, props, jobs and barrels (world layer) block it.
func can_see(t: Node2D) -> bool:
	var eye := global_position + Vector2(0, -10)
	var at := t.global_position + Vector2(0, -10)
	var to := at - eye
	var d := to.length()
	if d > _senses.sight_range:
		return false
	if d > _senses.sight_close_range and absf(_facing.angle_to(to)) > deg_to_rad(_senses.sight_angle_deg * 0.5):
		return false
	var ray := PhysicsRayQueryParameters2D.create(eye, at, 1)
	var skip: Array[RID] = [get_rid()]
	if t is CollisionObject2D:
		skip.append(t.get_rid())
	ray.exclude = skip
	return get_world_2d().direct_space_state.intersect_ray(ray).is_empty()


func _try_attack(target: Node2D, _delta: float) -> void:
	if _attack_timer > 0.0:
		return
	var d := global_position.distance_to(target.global_position)
	# A companion standing closer than the player gets it instead.
	var companion = _nearest_companion(minf(d, attack_range))
	if companion:
		_attack_timer = attack_cooldown
		companion.bitten(attack_damage, bite_chance)
		return
	if target is Player and d <= attack_range:
		_attack_timer = attack_cooldown
		_attack_fx()
		target.take_damage(attack_damage, global_position.direction_to(target.global_position) * 60.0)
	elif target is Car and d <= car_attack_range and car_attack_damage > 0.0:
		_attack_timer = attack_cooldown
		target.take_damage(car_attack_damage)


func _attack_fx() -> void:
	Sfx.play(attack_voice, global_position, 0.0, 0.15)
	if Net.is_host():
		_rpc_attack_fx.rpc()


@rpc("authority", "unreliable")
func _rpc_attack_fx() -> void:
	Sfx.play(attack_voice, global_position, 0.0, 0.15)


## Nearest on-foot companion within `max_dist`, or null.
func _nearest_companion(max_dist: float) -> Node2D:
	var best: Node2D = null
	var best_d := max_dist
	for c in get_tree().get_nodes_in_group(&"companions"):
		if not c.visible:
			continue  # riding in a car
		var d: float = global_position.distance_to(c.global_position)
		if d <= best_d:
			best_d = d
			best = c
	return best


func _after_move() -> void:
	pass


func _animate() -> void:
	if absf(velocity.x) > 1.0:
		sprite.flip_h = velocity.x > 0.0
	_play(&"run" if velocity.length() > 5.0 else &"idle")


# ---------- Movement helpers ----------

## Velocity toward `pos`: navmesh path when far, straight line when close.
func _steer_to(pos: Vector2, speed: float) -> Vector2:
	if global_position.distance_to(pos) < DIRECT_CHASE_DIST:
		return global_position.direction_to(pos) * speed
	if _repath_cd <= 0.0:
		_repath_cd = REPATH_INTERVAL
		nav.target_position = pos
	if nav.is_navigation_finished():
		return global_position.direction_to(pos) * speed
	var next := nav.get_next_path_position()
	if next.distance_squared_to(global_position) < 1.0:
		return global_position.direction_to(pos) * speed  # no navmesh yet
	return global_position.direction_to(next) * speed


## The player (or car) this zombie is chasing because it can see them. Null if none.
func _find_target() -> Node2D:
	return _target if sense == Sense.CHASE and is_instance_valid(_target) else null


func _wander(delta: float) -> Vector2:
	_wander_timer -= delta
	if _wander_timer <= 0.0:
		_wander_timer = randf_range(1.5, 4.0)
		_wander_dir = Vector2.ZERO if randf() < 0.4 else Vector2.from_angle(randf() * TAU)
	return _wander_dir * wander_speed


## Called by the NoiseDirector when a sound lands within earshot: go to the SOURCE
## of the sound (the zombie doesn't know where the player is now).
func hear(pos: Vector2, duration := INVESTIGATE_TIME) -> void:
	if is_dead or sense == Sense.CHASE:
		return
	_go_investigate(pos, duration)


func _play(anim: StringName) -> void:
	if sprite.animation != anim:
		sprite.play(anim)


func _bubble(effect: StringName) -> void:
	var head := -30.0 * sprite.scale.y
	OneShotEffect.spawn(self, effect, global_position + Vector2(0, head), 1.0, 0.6)


func stun(seconds: float, knockback := Vector2.ZERO) -> void:
	_stun_left = maxf(_stun_left, seconds * stun_duration_mult)
	_knockback = knockback


# ---------- Damage ----------

var _seen_hp := -1.0
var _seen_dead := false
var _groan_cd := 0.0


## Ambient groans, only for zombies near this machine's player (cosmetic, every peer).
func _process(delta: float) -> void:
	_night_glow.visible = not is_dead and RoomLighting.is_night()
	if is_dead:
		return
	_footsteps(delta)
	_groan_cd -= delta
	if _groan_cd > 0.0:
		return
	var me := Net.local_player() as Node2D
	if not me or me.global_position.distance_squared_to(global_position) > ambient_voice_range ** 2:
		_groan_cd = ambient_voice_interval.x
		return
	_groan_cd = randf_range(ambient_voice_interval.x, ambient_voice_interval.y)
	Sfx.play_zombie_ambience(voice, global_position, ambient_voice_volume_db)


## Shuffling feet near you: quiet, positional (panned left/right), so you can tell
## roughly where they are without seeing them.
var _last_pos := Vector2.ZERO


func _footsteps(delta: float) -> void:
	var moved := global_position.distance_to(_last_pos) / maxf(delta, 0.001)
	_last_pos = global_position
	_step_cd -= delta
	if _step_cd > 0.0 or moved < 8.0 or moved > 400.0:
		return
	_step_cd = 0.5 if moved < 30.0 else 0.32
	var me := Net.local_player() as Node2D
	if me and me.global_position.distance_to(global_position) < 320.0:
		Sfx.play(&"zombie_step", global_position, -4.0, 0.2)


## Clients: play blood from replicated hp/death changes (the host plays its own directly).
func _mirror_fx() -> void:
	if _seen_hp < 0.0:
		_seen_hp = hp
	if hp < _seen_hp and not is_dead:
		Fx.blood(global_position + Vector2(0, -12))
		Sfx.play(&"hit_flesh", global_position)
	_seen_hp = hp
	if is_dead and not _seen_dead:
		Fx.gore(global_position + Vector2(0, -10))
		Sfx.play(&"zombie_die", global_position)
	_seen_dead = is_dead


## Online, damage from a client (bullets, a client-driven car) goes to the host.
func _forward(method: StringName, args: Array) -> bool:
	if Net.is_sim_authority():
		return false
	callv(&"rpc_id", [1, method] + args)
	return true


@rpc("any_peer", "reliable")
func _rpc_take_damage(amount: float, knockback: Vector2) -> void:
	last_hitter = multiplayer.get_remote_sender_id()
	take_damage(amount, knockback)


@rpc("any_peer", "reliable")
func _rpc_rammed(car_name: String, car_velocity: Vector2, damage: float) -> void:
	last_hitter = multiplayer.get_remote_sender_id()
	on_rammed(get_parent().get_node_or_null(car_name), car_velocity, damage)


func on_rammed(_car: Node2D, car_velocity: Vector2, damage: float) -> void:
	if _forward(&"_rpc_rammed", [String(_car.name) if _car else "", car_velocity, damage]):
		return
	if _car and "driver_id" in _car and int(_car.driver_id) != 0:
		last_hitter = int(_car.driver_id)
	elif not Net.is_online():
		last_hitter = 1
	if dies_to_ram or damage >= hp:
		die(true, car_velocity)
	else:
		take_damage(damage, car_velocity * 0.6)


func take_damage(amount: float, knockback := Vector2.ZERO, acid := false) -> void:
	if is_dead or _forward(&"_rpc_take_damage", [amount, knockback]):
		return
	hp -= amount
	if hp > 0.0 and not acid:
		Fx.blood(global_position + Vector2(0, -12) * sprite.scale.y, knockback)
		Sfx.play(&"hit_flesh", global_position)
	_knockback = knockback
	if acid:
		Sfx.play(&"acid_tick", global_position, -9.0)
	_flash(Color("#9de65b") if acid else Color(1.0, 0.4, 0.4))
	if hp <= 0.0:
		die(false, knockback)


func die(by_car: bool, fling := Vector2.ZERO) -> void:
	if is_dead:
		return
	is_dead = true
	velocity = Vector2.ZERO
	collision.set_deferred(&"disabled", true)
	remove_from_group(&"zombies")
	z_index = -1  # corpses under the living
	var death_anim := &"death"
	if sprite.sprite_frames.has_animation(&"death_alt") and randf() < 0.5:
		death_anim = &"death_alt"
	sprite.speed_scale = 1.0
	sprite.play(death_anim)
	EventBus.zombie_killed.emit(zombie_id, global_position, by_car)
	if MatchState.active and Net.is_sim_authority():
		MatchState.on_zombie_killed(last_hitter)
	Fx.gore(global_position + Vector2(0, -10), fling)
	EventBus.screen_shake_requested.emit(2.5 if by_car else 1.2, 0.08)
	Sfx.play(&"zombie_die", global_position)
	_drop_loot.call_deferred(global_position)  # not mid-physics-callback

	var t := create_tween()
	if by_car:
		OneShotEffect.spawn(get_parent(), &"bullet_impact", global_position + Vector2(0, -12), 1.6)
		# Black-comedy ragdoll: fling along the car's path with a spin.
		t.set_parallel(true)
		t.tween_property(self, "global_position", global_position + fling * 0.22, 0.4) \
			.set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
		t.tween_property(sprite, "rotation", randf_range(-2.5, 2.5), 0.4)
		t.set_parallel(false)  # everything below runs after the fling
	t.tween_interval(corpse_lifetime)
	t.tween_property(sprite, "modulate:a", 0.0, 1.0)
	t.tween_callback(queue_free)


func _drop_loot(pos: Vector2) -> void:
	var parent := get_parent()
	if parent == null:
		return
	var scrap := randi_range(scrap_drop.x, scrap_drop.y)
	if scrap > 0:
		Pickup.drop(parent, Pickup.Kind.SCRAP, scrap, pos)
	if randf() < ammo_drop_chance:
		Pickup.drop(parent, Pickup.Kind.AMMO, ammo_drop_amount, pos)


func _flash(tint := Color(1.0, 0.4, 0.4)) -> void:
	if _flash_tween:
		_flash_tween.kill()
	sprite.modulate = tint
	_flash_tween = create_tween()
	_flash_tween.tween_property(sprite, "modulate", Color.WHITE, 0.15)
