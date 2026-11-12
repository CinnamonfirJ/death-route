@tool
extends Node2D
## Preview sprite shown only in the editor (so rooms show where the player, car,
## customer and barrels stand). Removed as soon as the game runs.


func _ready() -> void:
	if not Engine.is_editor_hint():
		queue_free()
