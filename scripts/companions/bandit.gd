class_name Bandit
extends CharacterBody2D
## An exposed rival courier. Runs away from the handyman with the stolen stash,
## firing back over their shoulder. Kill them (or run them over) to get the scrap
## back; if they get far enough away, it's gone.

const HIT_MASK := 1 | 2  # world + player

@export var max_hp := 50.0
@export var run_speed := 88.0
@export var shoot_range := 210.0
@export var shoot_interval := 1.6
@export var shoot_damage := 6.0
@export var shoot_noise := 6.0
@export var escape_distance := 900.0
## Bonus scrap dropped on top of the stash when they're stopped.
@export var bounty := 10

var display_name := "Rival"
var stash := 0
var hp: float
var is_dead := false

var _shoot_cd := 1.0
var _flash_tween: Tween

@onready var sprite: AnimatedSprite2D = $AnimatedSprite2D
@onready var collision: CollisionShape2D = $CollisionShape2D


func _ready() -> void:
	hp = max_hp
	add_to_group(&"hostiles")
	sprite.sprite_frames = Assets.character_frames(&"bandit_rival")
	sprite.play(&"run")
	Fx.attach_shadow(self, Vector2(22, 9))
	OneShotEffect.spawn(get_parent(), &"popup_1", global_position + Vector2(0, -36), 1.0, 0.8)


func _physics_process(delta: float) -> void:
	if is_dead:
		return
	var player = get_tree().get_first_node_in_group(&"player")
	if player == null:
		return
	var away: Vector2 = player.global_position.direction_to(global_position)
	if away == Vector2.ZERO:
		away = Vector2.RIGHT
	velocity = away * run_speed
	move_and_slide()
	if absf(velocity.x) > 1.0:
		sprite.flip_h = velocity.x > 0.0

	var dist: float = global_position.distance_to(player.global_position)
	if dist > escape_distance:
		_escape()
		return
	_shoot_cd -= delta
	if _shoot_cd <= 0.0 and dist < shoot_range and not player.is_dead():
		_shoot_cd = shoot_interval * randf_range(0.8, 1.2)
		_shoot_at(player)


func _shoot_at(player) -> void:
	var from := global_position + Vector2(0, -12)
	var to: Vector2 = player.global_position + Vector2(0, -8)
	var query := PhysicsRayQueryParameters2D.create(from, to, HIT_MASK)
	var hit := get_world_2d().direct_space_state.intersect_ray(query)
	var end := to
	if hit:
		end = hit.position
		if hit.collider == player:
			player.take_damage(shoot_damage, from.direction_to(to) * 50.0)
	var line := Line2D.new()
	line.width = 1.0
	line.default_color = Color(1.0, 0.5, 0.4, 0.85)
	line.points = PackedVector2Array([from, end])
	line.z_index = 4
	get_parent().add_child(line)
	var t := line.create_tween()
	t.tween_property(line, "modulate:a", 0.0, 0.1)
	t.tween_callback(line.queue_free)
	EventBus.noise_increased.emit(shoot_noise, global_position)
	EventBus.sound_made.emit(global_position, MatchConfig.get_config().sound_gunshot)


func _escape() -> void:
	is_dead = true
	EventBus.rival_escaped.emit(display_name, stash)
	EventBus.hud_message.emit("%s got away with %d of your scrap." % [display_name, stash])
	queue_free()


func take_damage(amount: float, knockback := Vector2.ZERO) -> void:
	if is_dead:
		return
	hp -= amount
	velocity += knockback
	if _flash_tween:
		_flash_tween.kill()
	sprite.modulate = Color(1.0, 0.4, 0.4)
	_flash_tween = create_tween()
	_flash_tween.tween_property(sprite, "modulate", Color.WHITE, 0.15)
	if hp <= 0.0:
		_die()


func on_rammed(_car: Node2D, _v: Vector2, _dmg: float) -> void:
	_die()


func _die() -> void:
	if is_dead:
		return
	is_dead = true
	remove_from_group(&"hostiles")
	collision.set_deferred(&"disabled", true)
	sprite.play(&"death")
	EventBus.rival_stopped.emit(display_name, stash)
	EventBus.hud_message.emit("You stopped %s. Scrap recovered." % display_name)
	_drop.call_deferred(global_position, stash + bounty)
	var t := create_tween()
	t.tween_interval(5.0)
	t.tween_property(sprite, "modulate:a", 0.0, 1.0)
	t.tween_callback(queue_free)


func _drop(pos: Vector2, amount: int) -> void:
	if amount > 0 and get_parent():
		Pickup.drop(get_parent(), Pickup.Kind.SCRAP, amount, pos)
