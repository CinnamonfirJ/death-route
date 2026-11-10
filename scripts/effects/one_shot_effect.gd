class_name OneShotEffect
extends AnimatedSprite2D
## Plays a manifest effect once and frees itself.
## Usage: OneShotEffect.spawn(get_parent(), &"explosion", global_position, 2.0)
## `hold` keeps the last frame on screen that many seconds (speech bubbles).


static func spawn(parent: Node, effect_id: StringName, pos: Vector2, scale_mult := 1.0, hold := 0.0) -> OneShotEffect:
	var fx := OneShotEffect.new()
	fx.sprite_frames = Assets.effect_frames(effect_id)
	fx.scale = Vector2.ONE * scale_mult
	fx.z_index = 5
	parent.add_child(fx)
	fx.global_position = pos
	if hold > 0.0:
		fx.animation_finished.connect(func() -> void:
			var t := fx.create_tween()
			t.tween_interval(hold)
			t.tween_property(fx, "modulate:a", 0.0, 0.2)
			t.tween_callback(fx.queue_free))
	else:
		fx.animation_finished.connect(fx.queue_free)
	fx.play(&"default")
	return fx
