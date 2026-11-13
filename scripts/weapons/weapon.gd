class_name Weapon
extends Node2D
## Hitscan gun held by the player. Aims at the mouse, raycasts on fire, makes noise.

## world (1) + zombie (8) + hazard (128). Cars (4) are ignored so you don't shoot your own ride.
## Companions (256) are hittable too: friendly fire, or putting down someone who's turning.
const HIT_MASK := 1 | 8 | 128 | 256

## Fallback stats. With use_loadout, the Garage-selected weapon is used instead.
@export var stats: WeaponStats
@export var use_loadout := true

## Below this durability the gun can jam; spread grows as durability falls.
const JAM_THRESHOLD := 0.35
const KNIFE_REACH := 42.0
const KNIFE_DAMAGE := 32.0
const KNIFE_COOLDOWN := 0.42
const KNIFE_TARGET_LAYER := 8
const PLAYER_LAYER := 2
const FIELD_WEAPONS := {
	&"flare_pistol": "res://resources/weapons/flare_pistol.tres",
	&"needle_smg": "res://resources/weapons/needle_smg.tres",
}
const KNIFE_BLOCKERS := 1 | 4 | 128

var in_mag := 0
var reserve := 0
var durability := 1.0
var is_reloading := false
var knife_equipped := false:
	set(value):
		knife_equipped = value
		if is_node_ready():
			sprite.visible = not value
			knife.visible = value
			if Net.is_local_authority(owner):
				EventBus.weapon_switched.emit()

var _cooldown := 0.0
var _knife_cooldown := 0.0
var _reload_left := 0.0
var _swing_tween: Tween
## Seconds left in a gun <-> knife swap (no attacking meanwhile).
var _switch_left := 0.0
var _switch_tween: Tween
var _starting_id: StringName
var _stored_condition := 1.0
var _guns: Array[Dictionary] = [{}]
var _gun_slot := 0
var _starting_slot := 0
var display_id: StringName = &"pistol":
	set(value):
		display_id = value
		if is_node_ready():
			sprite.sprite_frames = Assets.weapon_frames(value)
			sprite.play(&"idle")

@onready var sprite: AnimatedSprite2D = $AnimatedSprite2D
@onready var knife: AnimatedSprite2D = $Knife


func _ready() -> void:
	equip(GameManager.loadout_stats() if use_loadout else stats)
	_starting_id = stats.weapon_id
	knife.sprite_frames = Assets.weapon_frames(&"knife")
	knife.play(&"idle")
	knife.animation_finished.connect(func() -> void: knife.play(&"idle"))
	sprite.animation_finished.connect(func() -> void: sprite.play(&"idle"))


## Equips an upgraded copy of `base` and restores its saved durability.
func equip(base: WeaponStats) -> void:
	var field := FIELD_WEAPONS.has(base.weapon_id)
	stats = base.duplicate() if field else GameManager.upgraded_weapon_stats(base)
	durability = 1.0 if field else GameManager.get_durability(stats.weapon_id)
	display_id = stats.weapon_id
	sprite.sprite_frames = Assets.weapon_frames(display_id)
	sprite.play(&"idle")
	in_mag = stats.mag_size
	reserve = stats.start_reserve
	is_reloading = false
	_reload_left = 0.0
	_emit_ammo.call_deferred()  # deferred so the HUD (later in the tree) is listening


func equip_found(id: StringName) -> void:
	var slot := _gun_slot
	if _guns.size() == 1:
		_save_gun()
		slot = 1
		_guns.append({})
	elif knife_equipped:
		slot = 1
	if slot != _gun_slot:
		_save_gun()
	if slot == _starting_slot:
		_stored_condition = durability if slot == _gun_slot else float(_guns[slot]["durability"])
		_starting_slot = -1
	_gun_slot = slot
	equip(load(FIELD_WEAPONS[id]))
	_cooldown = 0.0
	knife_equipped = false
	_save_gun()


func gun_slot_count() -> int:
	return _guns.size()


func active_gun_slot() -> int:
	return _gun_slot + 1


func _save_gun() -> void:
	_guns[_gun_slot] = {"stats": stats, "mag": in_mag, "reserve": reserve, "durability": durability}


func _select_gun(slot: int) -> void:
	if slot != _gun_slot:
		_save_gun()
		_gun_slot = slot
		var stored := _guns[slot]
		stats = stored["stats"]
		in_mag = stored["mag"]
		reserve = stored["reserve"]
		durability = stored["durability"]
		display_id = stats.weapon_id
	knife_equipped = false
	_emit_ammo()


func loadout_condition() -> float:
	if _starting_slot == -1:
		return _stored_condition
	if _starting_slot == _gun_slot:
		return durability
	return float(_guns[_starting_slot]["durability"])


func started_with() -> StringName:
	return _starting_id


## Cycle occupied gun slots and the knife with a short holster animation.
func request_switch() -> void:
	if _switch_left > 0.0 or is_reloading:
		return
	_switch_left = MatchConfig.get_config().weapon_switch_time
	if knife_equipped:
		_select_gun(0)
	elif _gun_slot + 1 < _guns.size():
		_select_gun(_gun_slot + 1)
	else:
		knife_equipped = true
	_play_switch()
	if Net.is_online():
		_rpc_switch_fx.rpc()


@rpc("authority", "call_remote", "unreliable")
func _rpc_switch_fx() -> void:
	_play_switch()


func _play_switch() -> void:
	if _switch_tween:
		_switch_tween.kill()
	var t := MatchConfig.get_config().weapon_switch_time
	scale = Vector2(1.0, 0.2)
	modulate.a = 0.4
	_switch_tween = create_tween().set_parallel(true)
	_switch_tween.tween_property(self, "scale", Vector2.ONE, t).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	_switch_tween.tween_property(self, "modulate:a", 1.0, t)


func is_switching() -> bool:
	return _switch_left > 0.0


func _physics_process(delta: float) -> void:
	_switch_left -= delta
	_cooldown -= delta
	_knife_cooldown -= delta
	if is_reloading:
		_reload_left -= delta
		if _reload_left <= 0.0:
			_finish_reload()
	if visible and Net.is_local_authority(owner):
		_aim()
	sprite.flip_v = cos(rotation) < 0.0
	knife.flip_v = sprite.flip_v


func _aim() -> void:
	var target: Vector2 = owner.get_aim_point(knife_equipped) if owner and owner.has_method(&"get_aim_point") \
		else get_global_mouse_position()
	var direction := target - global_position
	if direction.length_squared() > 0.01:
		rotation = direction.angle()


func try_attack() -> bool:
	if _switch_left > 0.0:
		return false
	_aim()
	return _try_slash() if knife_equipped else try_fire()


func try_fire() -> bool:
	if _cooldown > 0.0 or is_reloading:
		return false
	if is_zero_approx(durability):
		return false
	if in_mag <= 0:
		start_reload()
		return false
	_cooldown = stats.fire_interval
	# Worn guns can jam before they reach the break point.
	if durability < JAM_THRESHOLD and randf() < (JAM_THRESHOLD - durability) * 1.5:
		_cooldown = 0.45
		EventBus.weapon_jammed.emit()
		Sfx.play(&"jam", global_position)
		return false
	in_mag -= 1
	durability = maxf(durability - stats.durability_loss_per_shot, 0.0)
	sprite.play(&"shoot")

	var muzzle := global_position + Vector2.RIGHT.rotated(rotation) * 14.0
	var aim_angle := rotation
	Fx.muzzle(muzzle, aim_angle)
	Sfx.play(&"shotgun" if stats.pellets > 1 else &"pistol", global_position)
	var spread := stats.spread_deg * (1.0 + (1.0 - durability) * 1.5)
	for i in stats.pellets:
		var angle := aim_angle + deg_to_rad(randf_range(-spread, spread) * 0.5)
		_fire_ray(muzzle, Vector2.RIGHT.rotated(angle))

	EventBus.noise_increased.emit(stats.noise_per_shot, global_position)
	EventBus.sound_made.emit(global_position, MatchConfig.get_config().sound_shotgun if stats.pellets > 1 else MatchConfig.get_config().sound_gunshot)
	EventBus.screen_shake_requested.emit(1.5 + stats.pellets * 0.3, 0.08)
	_emit_ammo()
	if in_mag == 0:
		start_reload()
	return true


func _try_slash() -> bool:
	if _knife_cooldown > 0.0:
		return false
	_knife_cooldown = MatchConfig.get_config().knife_cooldown if MatchState.active else KNIFE_COOLDOWN
	_play_slash()
	if Net.is_online():
		_play_slash.rpc()
	Sfx.play(&"knife_swing", global_position)
	EventBus.noise_increased.emit(1.0, global_position)
	EventBus.sound_made.emit(global_position, MatchConfig.get_config().sound_knife)
	var aim := Vector2.RIGHT.rotated(rotation)
	var target := _knife_target(global_position + Vector2(0, 7), aim)
	if target is Player:
		# Versus: the host validates the hit and applies damage (MatchState).
		MatchState.request_knife_hit(target, aim)
		EventBus.screen_shake_requested.emit(1.6, 0.09)
	elif target:
		if "last_hitter" in target:
			target.last_hitter = Net.local_id()
		target.take_damage(KNIFE_DAMAGE, aim * 95.0)
		Sfx.play(&"knife_hit", target.global_position)
		EventBus.screen_shake_requested.emit(1.6, 0.09)
	return true


func _knife_target(origin: Vector2, aim: Vector2) -> Node2D:
	var reach_px := MatchConfig.get_config().knife_reach if MatchState.active else KNIFE_REACH
	var reach := CircleShape2D.new()
	reach.radius = reach_px
	var query := PhysicsShapeQueryParameters2D.new()
	query.shape = reach
	query.transform = Transform2D(0.0, origin)
	# Knives hurt zombies; in versus they also hurt enemy players (never teammates,
	# and guns never hurt players at all: bullets don't hit the player layer).
	query.collision_mask = KNIFE_TARGET_LAYER | (PLAYER_LAYER if MatchState.active else 0)
	if owner is CollisionObject2D:
		query.exclude = [owner.get_rid()]
	var space := get_world_2d().direct_space_state
	var nearest: Node2D
	var best_distance := reach_px
	var me := Net.local_id()
	for hit in space.intersect_shape(query):
		var target := hit.collider as Node2D
		if not is_instance_valid(target) or target == owner:
			continue
		if target is Player:
			if target.is_dead() or not target.visible 					or not MatchState.are_enemies(me, target.get_multiplayer_authority()):
				continue
		elif target.is_dead:
			continue
		var point := target.global_position + Vector2(0, -4)
		var offset := point - origin
		var distance := offset.length()
		if distance > best_distance or offset.dot(aim) < distance * 0.56:
			continue
		var line := PhysicsRayQueryParameters2D.create(origin, point, KNIFE_BLOCKERS)
		if not space.intersect_ray(line).is_empty():
			continue
		nearest = target
		best_distance = distance
	return nearest


@rpc("authority", "call_remote", "unreliable")
func _play_slash() -> void:
	knife.play(&"shoot")
	if _swing_tween:
		_swing_tween.kill()
	var side := -1.0 if cos(rotation) < 0.0 else 1.0
	knife.rotation = -0.85 * side
	_swing_tween = create_tween()
	_swing_tween.tween_property(knife, "rotation", 0.65 * side, 0.13)
	_swing_tween.tween_property(knife, "rotation", 0.0, 0.14)


## Sweeps a small circle (stats.bullet_radius) along the shot and hits the first thing it touches.
func _fire_ray(from: Vector2, dir: Vector2) -> void:
	var space := get_world_2d().direct_space_state
	var motion := dir * stats.weapon_range
	var shape := CircleShape2D.new()
	shape.radius = stats.bullet_radius
	var params := PhysicsShapeQueryParameters2D.new()
	params.shape = shape
	params.transform = Transform2D(0.0, from)
	params.motion = motion
	params.collision_mask = HIT_MASK
	params.exclude = [owner.get_rid()] if owner is CollisionObject2D else []
	var fractions := space.cast_motion(params)  # [safe, unsafe]; 1.0 = clear
	var end := from + motion
	if fractions.size() == 2 and fractions[1] < 1.0:
		var hit_pos := from + motion * fractions[1]
		params.transform = Transform2D(0.0, hit_pos)
		params.motion = Vector2.ZERO
		var hits := space.intersect_shape(params, 1)
		end = from + motion * fractions[0]
		if not hits.is_empty():
			var collider: Object = hits[0].collider
			if "last_hitter" in collider:
				collider.last_hitter = Net.local_id()
			if collider.has_method(&"hit_by_player"):
				collider.hit_by_player(stats.damage, dir * stats.knockback)
			elif collider.has_method(&"take_damage"):
				collider.take_damage(stats.damage, dir * stats.knockback)
		OneShotEffect.spawn(_fx_parent(), &"bullet_impact", end, 1.2)
		Fx.impact(end, dir.angle())
	_tracer(from, end, stats)
	if Net.is_online():
		_rpc_shot_fx.rpc(from, end, fractions.size() == 2 and fractions[1] < 1.0, stats.weapon_id)


## Teammates see your tracers and impacts (cosmetic only; damage is already applied).
@rpc("any_peer", "call_remote", "unreliable")
func _rpc_shot_fx(from: Vector2, end: Vector2, hit: bool, id: StringName) -> void:
	var path: String = FIELD_WEAPONS.get(id, GameManager.WEAPONS.get(id, ""))
	if path.is_empty():
		return
	var fired: WeaponStats = load(path)
	_tracer(from, end, fired)
	Fx.muzzle(from, from.angle_to_point(end))
	Sfx.play(&"shotgun" if fired.pellets > 1 else &"pistol", from)
	if hit:
		OneShotEffect.spawn(_fx_parent(), &"bullet_impact", end, 1.2)
		Fx.impact(end, from.angle_to_point(end))


func _tracer(from: Vector2, to: Vector2, fired: WeaponStats) -> void:
	var line := Line2D.new()
	line.material = Fx.additive()  # glowing tracer
	line.width = fired.tracer_width
	line.default_color = fired.tracer_color
	line.points = PackedVector2Array([from, to])
	line.z_index = 4
	_fx_parent().add_child(line)
	var t := line.create_tween()
	t.tween_property(line, "modulate:a", 0.0, fired.tracer_seconds)
	t.tween_callback(line.queue_free)


func _fx_parent() -> Node:
	return owner.get_parent() if owner else get_tree().current_scene


func start_reload() -> void:
	if knife_equipped or is_reloading or is_zero_approx(durability) or reserve <= 0 or in_mag >= stats.mag_size:
		return
	is_reloading = true
	_reload_left = stats.reload_time
	Sfx.play(&"reload", global_position)
	_emit_ammo()


func _finish_reload() -> void:
	var take := mini(stats.mag_size - in_mag, reserve)
	in_mag += take
	reserve -= take
	is_reloading = false
	_emit_ammo()


func add_ammo(amount: int) -> void:
	reserve += amount
	_emit_ammo()


func _emit_ammo() -> void:
	if Net.is_local_authority(owner):  # only your own gun drives your HUD
		EventBus.ammo_changed.emit(in_mag, reserve, is_reloading)
