class_name ExtractionZone
extends Area2D
## The delivery drop. Locked until the run's jobs are done; then driving a working
## car into the ring ends the run successfully ("The Escape").

signal reached

@export var radius := 56.0

var active := false

@onready var sprite: AnimatedSprite2D = $AnimatedSprite2D


func _ready() -> void:
	sprite.sprite_frames = Assets.prop_frames(&"camp_flag")
	sprite.play(&"default")
	(($CollisionShape2D as CollisionShape2D).shape as CircleShape2D).radius = radius
	set_active(false)


func set_active(value: bool) -> void:
	active = value
	sprite.modulate = Color.WHITE if active else Color(0.45, 0.45, 0.45, 0.8)
	set_physics_process(active)
	queue_redraw()


## Polls (rather than body_entered) so a car already parked inside counts on activation.
func _physics_process(_delta: float) -> void:
	if not Net.is_sim_authority():
		return  # the host decides when the delivery lands
	for body in get_overlapping_bodies():
		if body.is_in_group(&"cars") and body.has_driver() and not body.is_destroyed:
			set_physics_process(false)
			reached.emit()
			return


func _draw() -> void:
	var color := Color(1.0, 0.85, 0.3, 0.8) if active else Color(0.6, 0.6, 0.6, 0.35)
	draw_arc(Vector2.ZERO, radius, 0.0, TAU, 48, color, 2.0)
	draw_arc(Vector2.ZERO, radius - 6.0, 0.0, TAU, 48, Color(color, color.a * 0.4), 1.0)
