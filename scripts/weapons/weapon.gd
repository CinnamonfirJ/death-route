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

var in_mag := 0
var reserve := 0
var durability := 1.0
var is_reloading := false

var _cooldown := 0.0
var _reload_left := 0.0

@onready var sprite: AnimatedSprite2D = $AnimatedSprite2D


func _ready() -> void:
	equip(GameManager.loadout_stats() if use_loadout else stats)


## Equips an upgraded copy of `base` and restores its saved durability.
func equip(base: WeaponStats) -> void:
	stats = GameManager.upgraded_weapon_stats(base)
	durability = GameManager.get_durability(stats.weapon_id)
	sprite.sprite_frames = Assets.weapon_frames(stats.weapon_id)
	sprite.play(&"idle")
	in_mag = stats.mag_size
	reserve = stats.start_reserve
	is_reloading = false
	_emit_ammo.call_deferred()  # deferred so the HUD (later in the tree) is listening


func _physics_process(delta: float) -> void:
	_cooldown -= delta
	if is_reloading:
		_reload_left -= delta
		if _reload_left <= 0.0:
			_finish_reload()
	if visible and Net.is_local_authority(owner):
		var target: Vector2 = owner.get_aim_point() if owner and owner.has_method(&"get_aim_point") \
			else get_global_mouse_position()
		var aim := target - global_position
		rotation = aim.angle()
		sprite.flip_v = aim.x < 0.0


func try_fire() -> bool:
	if _cooldown > 0.0 or is_reloading:
		return false
	if in_mag <= 0:
		start_reload()
		return false
	_cooldown = stats.fire_interval
	# Worn guns jam: up to ~50% at 0 durability.
	if durability < JAM_THRESHOLD and randf() < (JAM_THRESHOLD - durability) * 1.5:
		_cooldown = 0.45
		EventBus.weapon_jammed.emit()
		Sfx.play(&"jam", global_position)
		return false
	in_mag -= 1
	durability = maxf(durability - stats.durability_loss_per_shot, 0.0)
	sprite.play(&"shoot")
	sprite.animation_finished.connect(func() -> void: sprite.play(&"idle"), CONNECT_ONE_SHOT)

	var muzzle := global_position + Vector2.RIGHT.rotated(rotation) * 14.0
	var aim_angle := rotation
	Fx.muzzle(muzzle, aim_angle)
	Sfx.play(&"shotgun" if stats.pellets > 1 else &"pistol", global_position)
	var spread := stats.spread_deg * (1.0 + (1.0 - durability) * 1.5)
	for i in stats.pellets:
		var angle := aim_angle + deg_to_rad(randf_range(-spread, spread) * 0.5)
		_fire_ray(muzzle, Vector2.RIGHT.rotated(angle))

	EventBus.noise_increased.emit(stats.noise_per_shot, global_position)
	EventBus.screen_shake_requested.emit(1.5 + stats.pellets * 0.3, 0.08)
	_emit_ammo()
	if in_mag == 0:
		start_reload()
	return true


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
			if collider.has_method(&"hit_by_player"):
				collider.hit_by_player(stats.damage, dir * stats.knockback)
			elif collider.has_method(&"take_damage"):
				collider.take_damage(stats.damage, dir * stats.knockback)
		OneShotEffect.spawn(_fx_parent(), &"bullet_impact", end, 1.2)
		Fx.impact(end, dir.angle())
	_tracer(from, end)
	if Net.is_online():
		_rpc_shot_fx.rpc(from, end, fractions.size() == 2 and fractions[1] < 1.0)


## Teammates see your tracers and impacts (cosmetic only; damage is already applied).
@rpc("any_peer", "call_remote", "unreliable")
func _rpc_shot_fx(from: Vector2, end: Vector2, hit: bool) -> void:
	_tracer(from, end)
	Fx.muzzle(from, from.angle_to_point(end))
	Sfx.play(&"shotgun" if stats.pellets > 1 else &"pistol", from)
	if hit:
		OneShotEffect.spawn(_fx_parent(), &"bullet_impact", end, 1.2)
		Fx.impact(end, from.angle_to_point(end))


func _tracer(from: Vector2, to: Vector2) -> void:
	var line := Line2D.new()
	line.material = Fx.additive()  # glowing tracer
	line.width = 2.5
	line.default_color = Color(1.0, 0.92, 0.6, 0.9)
	line.points = PackedVector2Array([from, to])
	line.z_index = 4
	_fx_parent().add_child(line)
	var t := line.create_tween()
	t.tween_property(line, "modulate:a", 0.0, 0.08)
	t.tween_callback(line.queue_free)


func _fx_parent() -> Node:
	return owner.get_parent() if owner else get_tree().current_scene


func start_reload() -> void:
	if is_reloading or reserve <= 0 or in_mag >= stats.mag_size:
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
