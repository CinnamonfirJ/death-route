extends PlayerState
## Hands busy on a task. Progress only while [E] is held and the player stands still.
## Moving, releasing [E], or taking damage interrupts (damage also costs progress).

var task: Node
var _damaged := false
var _work_sfx_cd := 0.0


func enter(msg := {}) -> void:
	task = msg["task"]
	_damaged = false
	player.velocity = Vector2.ZERO
	player.weapon.visible = false
	player.sprite.play(&"idle")
	task.begin(player)
	EventBus.player_damaged.connect(_on_player_damaged)


func exit() -> void:
	EventBus.player_damaged.disconnect(_on_player_damaged)
	player.weapon.visible = true
	if task and not task.is_completed:
		task.interrupt(_damaged)
	task = null
	EventBus.interact_prompt_changed.emit("")


func physics_update(delta: float) -> void:
	var moving := Input.get_vector(&"move_left", &"move_right", &"move_up", &"move_down") != Vector2.ZERO
	if moving or not Input.is_action_pressed(&"interact"):
		state_machine.transition_to(&"OnFoot")
		return
	# Little "working" bob + ratchet sounds so it reads as busy.
	player.sprite.position.y = -absf(sin(Time.get_ticks_msec() * 0.02)) * 1.5
	_work_sfx_cd -= delta
	if _work_sfx_cd <= 0.0:
		_work_sfx_cd = 0.45
		Sfx.play(&"task_work", player.global_position)
	EventBus.interact_prompt_changed.emit("%s... %d%%" % [task.task_name, roundi(task.progress * 100.0)])
	if task.advance(delta):
		player.sprite.position.y = 0.0
		state_machine.transition_to(&"OnFoot")


func _on_player_damaged(amount: float, _hp: float) -> void:
	if amount <= 0.0 or state_machine.current != self:
		return
	_damaged = true
	player.sprite.position.y = 0.0
	if not player.is_dead():
		state_machine.transition_to(&"OnFoot")
