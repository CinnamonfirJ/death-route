extends PlayerState
## Walking, sprinting, and interacting with nearby objects.

var _prompt := ""


func enter(_msg := {}) -> void:
	player.set_body_enabled(true)
	player.sprite.play(&"idle")


func exit() -> void:
	_set_prompt("")


func physics_update(delta: float) -> void:
	var input := Input.get_vector(&"move_left", &"move_right", &"move_up", &"move_down")
	var run_held := Input.is_action_pressed(&"sprint") or bool(GameManager.get_setting("auto_run"))
	var sprinting := run_held and input != Vector2.ZERO
	var target_speed := player.sprint_speed if sprinting else player.walk_speed
	player.velocity = player.velocity.move_toward(input * target_speed, player.acceleration * delta)
	player.move_and_slide()

	if sprinting:
		EventBus.noise_increased.emit(player.sprint_noise_per_sec * delta, player.global_position)

	# Keep the last facing while moving straight up or down, or standing still.
	if absf(input.x) > 0.05:
		player.sprite.flip_h = input.x > 0.0  # the source art faces left
	if player.velocity.length() > 10.0:
		player.sprite.play(&"run")
		player.sprite.speed_scale = 1.4 if sprinting else 1.0
	else:
		player.sprite.play(&"idle")
		player.sprite.speed_scale = 1.0

	var w := player.weapon
	var fire := false
	if player.touch_mode:
		# Holding the aim stick fires at the gun's rate. (Touches also emulate mouse
		# clicks, so the mouse "shoot" action is ignored in touch mode.)
		fire = player.touch_fire
	else:
		fire = Input.is_action_pressed(&"shoot") if w.stats.automatic else Input.is_action_just_pressed(&"shoot")
	if fire:
		w.try_fire()
	if Input.is_action_just_pressed(&"reload"):
		w.start_reload()

	var target := player.get_best_interactable()
	_set_prompt(target.get_interact_prompt(player) if target else "")
	if target and Input.is_action_just_pressed(&"interact"):
		target.interact(player)


func _set_prompt(text: String) -> void:
	if text != _prompt:
		_prompt = text
		EventBus.interact_prompt_changed.emit(text)
