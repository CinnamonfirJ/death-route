class_name StateMachine
extends Node
## Generic finite state machine. Child nodes extending PlayerState are the states,
## keyed by node name. Only the current state receives updates.

@export var initial_state: PlayerState

var current: PlayerState
var current_name: StringName = &""
var states: Dictionary = {}


func _ready() -> void:
	for child in get_children():
		if child is PlayerState:
			states[child.name] = child
			child.player = owner
			child.state_machine = self
	await owner.ready
	current = initial_state
	current_name = current.name
	current.enter({})


func _physics_process(delta: float) -> void:
	# Online, other players' handymen are driven by their own machines (state arrives via sync).
	if current and Net.is_local_authority(owner):
		current.physics_update(delta)


func _unhandled_input(event: InputEvent) -> void:
	if current and Net.is_local_authority(owner):
		current.handle_input(event)


func transition_to(state_name: StringName, msg := {}) -> void:
	if not states.has(state_name):
		push_error("StateMachine: unknown state '%s'" % state_name)
		return
	if current:
		current.exit()
	current = states[state_name]
	current_name = state_name
	current.enter(msg)
	EventBus.player_state_changed.emit(state_name)
