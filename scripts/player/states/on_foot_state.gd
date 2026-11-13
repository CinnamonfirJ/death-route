extends PlayerState
## Walking, sprinting, and interacting with nearby objects.

var _prompt := ""
var _step_cd := 0.0
## Crouch walk speed as a fraction of walking speed.
const CROUCH_SPEED := 0.55


func enter(_msg := {}) -> void:
	player.set_body_enabled(true)
	player.sprite.play(&"idle")


func exit() -> void:
	_set_prompt("")
	player.crouching = false
	player.sprite.scale.y = 1.0


func physics_update(delta: float) -> void:
	var input := Input.get_vector(&"move_left", &"move_right", &"move_up", &"move_down")
	var crouch := Input.is_action_pressed(&"crouch")
	var run_held := not crouch and (Input.is_action_pressed(&"sprint") or bool(GameManager.get_setting("auto_run")))
	var sprinting := run_held and input != Vector2.ZERO
	var target_speed := player.sprint_speed if sprinting else player.walk_speed
	if crouch:
		target_speed = player.walk_speed * CROUCH_SPEED
	if crouch != player.crouching:
		player.crouching = crouch
		player.sprite.scale.y = 0.85 if crouch else 1.0
	if player.field_rush > 0.0 and not crouch:
		target_speed *= 1.0 + player.field_speed_bonus
	player.velocity = player.velocity.move_toward(input * target_speed, player.acceleration * delta)
	player.move_and_slide()

	if sprinting:
		EventBus.noise_increased.emit(player.sprint_noise_per_sec * delta, player.global_position)
	# Footstep sounds zombies can hear: sprinting carries, walking barely, crouching not at all.
	_step_cd -= delta
	if _step_cd <= 0.0 and player.velocity.length() > 10.0:
		_step_cd = 0.35
		var cfg := MatchConfig.get_config()
		var radius := cfg.sound_sprint if sprinting else (cfg.sound_crouch if crouch else cfg.sound_walk)
		if radius > 0.0:
			EventBus.sound_made.emit(player.global_position, radius)

	# Keep the last facing while moving straight up or down, or standing still.
	if absf(input.x) > 0.05:
		player.sprite.flip_h = input.x > 0.0  # the source art faces left
	if player.velocity.length() > 10.0:
		player.sprite.play(&"run")
		player.sprite.speed_scale = 1.4 if sprinting else (0.6 if crouch else 1.0)
	else:
		player.sprite.play(&"idle")
		player.sprite.speed_scale = 1.0

	var w := player.weapon
	if Input.is_action_just_pressed(&"switch_weapon"):
		w.request_switch()
	var fire := false
	if player.touch_mode:
		# TouchControls drives fire at the gun's rate. (Touches also emulate mouse
		# clicks, so the mouse "shoot" action is ignored in touch mode.)
		fire = player.touch_fire
	else:
		fire = Input.is_action_pressed(&"shoot") if not w.knife_equipped and w.stats.automatic \
			else Input.is_action_just_pressed(&"shoot")
	if fire and (player.touch_mode or not _over_field_shop()):
		w.try_attack()
	if not w.knife_equipped and Input.is_action_just_pressed(&"reload"):
		w.start_reload()

	var target := player.get_best_interactable()
	_set_prompt(target.get_interact_prompt(player) if target else "")
	if target and Input.is_action_just_pressed(&"interact"):
		target.interact(player)


func _set_prompt(text: String) -> void:
	if text != _prompt:
		_prompt = text
		EventBus.interact_prompt_changed.emit(text)


func _over_field_shop() -> bool:
	var mouse := player.get_viewport().get_mouse_position()
	for menu: Control in get_tree().get_nodes_in_group(&"field_shop_menus"):
		if menu.is_visible_in_tree() and menu.get_global_rect().has_point(mouse):
			return true
	return false
