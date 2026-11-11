class_name Zombie
extends CharacterBody2D
## Base zombie (also the Walker). Pathfinds with NavigationAgent2D toward the player
## (or the car they're driving), investigates noises, melees, reacts to rams.
##
## Subclasses override these hooks:
##   _think(delta)          -> sets _desired (velocity before knockback)
##   _try_attack(target, d) -> melee logic
##   _after_move()          -> inspect slide collisions
##   on_rammed / on_car_impact / take_damage / die

@export var zombie_id: StringName = &"zombie_walker"
@export var max_hp := 30.0
@export var wander_speed := 14.0
@export var chase_speed := 38.0
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

@export_group("Loot")
## Scrap dropped on death: random in [x, y]. (0, 0) = none.
@export var scrap_drop := Vector2i(0, 1)
@export_range(0.0, 1.0) var ammo_drop_chance := 0.08
@export var ammo_drop_amount := 6

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

@onready var sprite: AnimatedSprite2D = $AnimatedSprite2D
@onready var collision: CollisionShape2D = $CollisionShape2D
@onready var nav: NavigationAgent2D = $NavigationAgent2D


func _ready() -> void:
	hp = max_hp
	add_to_group(&"zombies")
	var entry := Assets.character(zombie_id)
	sprite.sprite_frames = Assets.character_frames(zombie_id)
	var s := float(entry.get("scale", 1.0))
	sprite.scale = Vector2(s, s)
	Fx.attach_shadow(self, Vector2(22, 9) * s)
	sprite.self_modulate = Color(entry.get("tint", "#ffffff"))
	sprite.play(&"idle")
	sprite.frame = randi() % sprite.sprite_frames.get_frame_count(&"idle")
	_wander_timer = randf_range(0.5, 3.0)
	_repath_cd = randf() * REPATH_INTERVAL  # stagger path queries across the horde
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
	var target := _find_target()
	if target and global_position.distance_to(target.global_position) < aggro_radius:
		if not _aggro:
			_aggro = true
			_bubble(&"popup_1")
		_desired = _steer_to(target.global_position, chase_speed)
		_try_attack(target, delta)
		return
	if _aggro:
		_aggro = false
		_bubble(&"popup_2")
	if _investigate_left > 0.0:
		_investigate_left -= delta
		_desired = _steer_to(_investigate_pos, chase_speed * 0.8)
		if global_position.distance_to(_investigate_pos) < 24.0:
			_investigate_left = 0.0
		return
	_desired = _wander(delta)


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
		target.take_damage(attack_damage, global_position.direction_to(target.global_position) * 60.0)
	elif target is Car and d <= car_attack_range and car_attack_damage > 0.0:
		_attack_timer = attack_cooldown
		target.take_damage(car_attack_damage)


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


## The nearest living player on foot, or the car they're driving. Null if none.
func _find_target() -> Node2D:
	return Net.nearest_target(global_position)


func _wander(delta: float) -> Vector2:
	_wander_timer -= delta
	if _wander_timer <= 0.0:
		_wander_timer = randf_range(1.5, 4.0)
		_wander_dir = Vector2.ZERO if randf() < 0.4 else Vector2.from_angle(randf() * TAU)
	return _wander_dir * wander_speed


## Called by the NoiseDirector when a noise lands within earshot.
func hear(pos: Vector2, duration := INVESTIGATE_TIME) -> void:
	if is_dead:
		return
	_investigate_pos = pos
	_investigate_left = duration


func _play(anim: StringName) -> void:
	if sprite.animation != anim:
		sprite.play(anim)


func _bubble(effect: StringName) -> void:
	var head := -30.0 * sprite.scale.y
	OneShotEffect.spawn(self, effect, global_position + Vector2(0, head), 1.0, 0.6)


func stun(seconds: float, knockback := Vector2.ZERO) -> void:
	_stun_left = maxf(_stun_left, seconds)
	_knockback = knockback


# ---------- Damage ----------

var _seen_hp := -1.0
var _seen_dead := false
var _groan_cd := randf_range(2.0, 12.0)


## Ambient groans, only for zombies near this machine's player (cosmetic, every peer).
func _process(delta: float) -> void:
	if is_dead:
		return
	_groan_cd -= delta
	if _groan_cd > 0.0:
		return
	_groan_cd = randf_range(7.0, 16.0)
	var me := Net.local_player() as Node2D
	if me and me.global_position.distance_to(global_position) < 450.0:
		Sfx.play(&"groan", global_position, 0.0, 0.15)


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
	take_damage(amount, knockback)


@rpc("any_peer", "reliable")
func _rpc_rammed(car_name: String, car_velocity: Vector2, damage: float) -> void:
	on_rammed(get_parent().get_node_or_null(car_name), car_velocity, damage)


func on_rammed(_car: Node2D, car_velocity: Vector2, damage: float) -> void:
	if _forward(&"_rpc_rammed", [String(_car.name) if _car else "", car_velocity, damage]):
		return
	if dies_to_ram or damage >= hp:
		die(true, car_velocity)
	else:
		take_damage(damage, car_velocity * 0.6)


func take_damage(amount: float, knockback := Vector2.ZERO) -> void:
	if is_dead or _forward(&"_rpc_take_damage", [amount, knockback]):
		return
	hp -= amount
	if hp > 0.0:
		Fx.blood(global_position + Vector2(0, -12) * sprite.scale.y, knockback)
		Sfx.play(&"hit_flesh", global_position)
	_knockback = knockback
	_flash()
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


func _flash() -> void:
	if _flash_tween:
		_flash_tween.kill()
	sprite.modulate = Color(1.0, 0.4, 0.4)
	_flash_tween = create_tween()
	_flash_tween.tween_property(sprite, "modulate", Color.WHITE, 0.15)
