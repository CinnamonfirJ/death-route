@tool
class_name Prop
extends StaticBody2D
## A static room prop (bed, crate, tent, wreck...). Visible in the editor, so you
## can drag prop scenes from res://scenes/props/library/ into a room and move them.
## The sprite stands on the node's origin (drawn upward, for y-sorting); a collider
## covers its footprint. Swap `texture` to change what it looks like.

@export var texture: Texture2D:
	set(v):
		texture = v
		_rebuild()
## Blocks movement and is carved out of the zombie navmesh.
@export var solid := true:
	set(v):
		solid = v
		_rebuild()
## Soft ground shadow under the prop (in game).
@export var cast_shadow := true
## Collider size as a fraction of the sprite (x = width, y = height).
@export var footprint := Vector2(1.0, 0.55):
	set(v):
		footprint = v
		_rebuild()

var _sprite: Sprite2D
var _shape: CollisionShape2D


func _ready() -> void:
	_rebuild()
	if Engine.is_editor_hint():
		return
	if solid:
		add_to_group(&"nav_obstacle")
	if cast_shadow and texture:
		var size := texture.get_size()
		Fx.attach_shadow(self, Vector2(size.x * 1.1, maxf(size.y * 0.45, 12.0)), Vector2(2, 4))


func _rebuild() -> void:
	if not is_inside_tree():
		return
	collision_mask = 0
	collision_layer = 1 if solid else 0
	if _sprite == null:
		_sprite = Sprite2D.new()
		add_child(_sprite, false, Node.INTERNAL_MODE_FRONT)
	if _shape == null:
		_shape = CollisionShape2D.new()
		add_child(_shape, false, Node.INTERNAL_MODE_FRONT)
	_sprite.texture = texture
	var size := texture.get_size() if texture else Vector2(16, 16)
	_sprite.offset = Vector2(0, -size.y * 0.5 + 6.0)
	var rect := RectangleShape2D.new()
	rect.size = Vector2(maxf(size.x * footprint.x - 4.0, 8.0), maxf(size.y * footprint.y, 8.0))
	_shape.shape = rect
	_shape.position = Vector2(0, 6.0 - rect.size.y * 0.5)
	_shape.disabled = not solid
