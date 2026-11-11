extends Node2D
## Draws one-pixel silhouettes behind the live sprite frame, including atlas edges.

const OUTLINE_SHADER := preload("res://assets/characters/player_outline.gdshader")
const OUTLINE_OFFSETS := [Vector2.LEFT, Vector2.RIGHT, Vector2.UP, Vector2.DOWN]
const TEAMMATE_BLUE := Color(0.26, 0.66, 1.0)

var _flipped := false
@onready var _sprite: AnimatedSprite2D = get_parent()


func _ready() -> void:
	var outline := ShaderMaterial.new()
	outline.shader = OUTLINE_SHADER
	var color := Color.WHITE if Net.is_local_authority(_sprite.get_parent()) else TEAMMATE_BLUE
	outline.set_shader_parameter(&"outline_color", color)
	material = outline
	_sprite.frame_changed.connect(queue_redraw)
	_sprite.animation_changed.connect(queue_redraw)
	_sprite.sprite_frames_changed.connect(queue_redraw)


func _process(_delta: float) -> void:
	if _flipped != _sprite.flip_h:
		_flipped = _sprite.flip_h
		queue_redraw()


func _draw() -> void:
	var frames := _sprite.sprite_frames
	if frames == null or not frames.has_animation(_sprite.animation):
		return
	var texture := frames.get_frame_texture(_sprite.animation, _sprite.frame)
	if texture == null:
		return
	var size := texture.get_size()
	var flip := Vector2(-1.0 if _sprite.flip_h else 1.0, 1.0)
	draw_set_transform(_sprite.offset, 0.0, flip)
	for offset in OUTLINE_OFFSETS:
		draw_texture_rect(texture, Rect2(-size * 0.5 + offset, size), false)
