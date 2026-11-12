extends Range
## The pack's framed heart and red fill. The HUD adds a numeric readout.

const FRAMES := preload("res://assets/ui/healthbars_icons.png")
const FILLS := preload("res://assets/ui/bar_fillers.png")
const FRAME := Rect2(24, 72, 72, 24)

@export var show_value := true
var _touch := false
## Fill colour from bar_fillers.png: 0 red, 1 blue, 2 orange, 3 green.
@export_range(0, 3) var fill_column := 0:
	set(v):
		fill_column = v
		queue_redraw()


func _ready() -> void:
	_touch = TouchLayout.enabled()
	value_changed.connect(queue_redraw.unbind(1))
	changed.connect(queue_redraw)


func _get_minimum_size() -> Vector2:
	return Vector2(146, 24) if show_value else FRAME.size


func _draw() -> void:
	draw_texture_rect_region(FRAMES, Rect2(Vector2.ZERO, FRAME.size), FRAME)
	var fill := roundf(ratio * 46.0)
	if fill > 0.0:
		draw_texture_rect_region(FILLS, Rect2(23, 8, fill, 9), Rect2(fill_column * 64, 0, fill, 9),
			Color(1.6, 1.34, 1.3))
		draw_rect(Rect2(23, 8, fill, 1), Color(1.0, 0.57, 0.54, 0.58))
	if show_value:
		var font := ThemeDB.fallback_font if _touch else get_theme_default_font()
		var font_size := 12 if _touch else 9
		var health := "%d / %d" % [roundi(value), roundi(max_value)]
		var ink := Color(1.0, 0.69, 0.66) if ratio <= 0.3 else Color.WHITE
		draw_string_outline(font, Vector2(78, 16), health, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size, 3, Color.BLACK)
		draw_string(font, Vector2(78, 16), health, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size, ink)
