extends PlayerState
## Terminal state: play the death animation and announce it.


func enter(_msg := {}) -> void:
	player.velocity = Vector2.ZERO
	player.visible = true
	player.collision.set_deferred(&"disabled", true)
	player.interact_area.set_deferred(&"monitoring", false)
	player.sprite.speed_scale = 1.0
	player.sprite.play(&"death")
	EventBus.interact_prompt_changed.emit("")
	EventBus.player_died.emit()
