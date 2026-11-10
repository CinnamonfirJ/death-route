class_name ExplosiveBarrel
extends StaticBody2D
## Burning barrel. Shoot it, ram it, or let a blast reach it: it explodes,
## hurting everything nearby (Brutes included) and chaining into other barrels.

@export var blast_radius := 90.0
@export var blast_damage := 200.0
@export var blast_noise := 35.0

var _exploded := false


func _ready() -> void:
	add_to_group(&"barrels")
	add_to_group(&"nav_obstacle")
	var spr: AnimatedSprite2D = $AnimatedSprite2D
	spr.sprite_frames = Assets.prop_frames(&"explosive_barrel")
	spr.play(&"default")
	spr.frame = randi() % 7
	Fx.attach_glow(self, Color(1.0, 0.55, 0.2, 0.5), 0.9, Vector2(0, -30))


func take_damage(_amount: float, _knockback := Vector2.ZERO) -> void:
	explode()


## Cars that hit a barrel set it off.
func on_car_impact(_car: Node, _pre_velocity: Vector2, _slip: float) -> void:
	explode()


## Online the host decides and applies damage; every machine plays the blast.
func explode() -> void:
	if _exploded:
		return
	if not Net.is_sim_authority():
		_rpc_request_explode.rpc_id(1)
		return
	if Net.is_online():
		_rpc_blast_fx.rpc()
	_exploded = true
	var center := global_position + Vector2(0, -8)
	OneShotEffect.spawn(get_parent(), &"explosion", center, 1.5)
	Fx.explosion(center, 1.2)
	Sfx.play(&"explosion", center)
	EventBus.screen_shake_requested.emit(12.0, 0.5)
	EventBus.noise_increased.emit(blast_noise, center)
	for group in [&"zombies", &"player", &"cars", &"barrels"]:
		for node in get_tree().get_nodes_in_group(group):
			if node == self or not node.has_method(&"take_damage"):
				continue
			var d: float = center.distance_to(node.global_position)
			if d > blast_radius:
				continue
			var falloff := 1.0 - 0.5 * (d / blast_radius)
			if node is ExplosiveBarrel:
				node.call_deferred(&"_chain")
			else:
				var push: Vector2 = center.direction_to(node.global_position) * 300.0 * falloff
				node.take_damage(blast_damage * falloff, push)
	queue_free()


@rpc("any_peer", "reliable")
func _rpc_request_explode() -> void:
	explode()


@rpc("authority", "reliable")
func _rpc_blast_fx() -> void:
	if _exploded:
		return
	_exploded = true
	OneShotEffect.spawn(get_parent(), &"explosion", global_position + Vector2(0, -8), 1.5)
	Fx.explosion(global_position + Vector2(0, -8), 1.2)
	Sfx.play(&"explosion", global_position)
	EventBus.screen_shake_requested.emit(12.0, 0.5)
	queue_free()


func _chain() -> void:
	await get_tree().create_timer(0.12).timeout
	explode()
