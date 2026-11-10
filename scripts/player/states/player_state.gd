class_name PlayerState
extends Node
## Base class for player states. Override the hooks you need.

var player: Player
var state_machine: StateMachine


func enter(_msg := {}) -> void:
	pass


func exit() -> void:
	pass


func physics_update(_delta: float) -> void:
	pass


func handle_input(_event: InputEvent) -> void:
	pass
