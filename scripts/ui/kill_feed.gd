extends VBoxContainer
## Versus kill feed (top centre): "A [knife] B", "B was eaten", jobs fixed. Lines fade out.

const MAX_LINES := 5
const LIFETIME := 5.0


func _ready() -> void:
	name = "KillFeed"
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	set_anchors_preset(Control.PRESET_CENTER_TOP)
	offset_left = -140
	offset_right = 140
	offset_top = 6
	alignment = BoxContainer.ALIGNMENT_BEGIN
	add_theme_constant_override(&"separation", 1)
	MatchState.kill_feed.connect(add_line)


func add_line(text: String, color: Color) -> void:
	var l := Label.new()
	l.text = text
	l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	l.add_theme_font_size_override(&"font_size", 9)
	l.add_theme_color_override(&"font_color", color)
	l.add_theme_color_override(&"font_outline_color", Color.BLACK)
	l.add_theme_constant_override(&"outline_size", 3)
	add_child(l)
	while get_child_count() > MAX_LINES:
		get_child(0).free()
	var t := l.create_tween()
	t.tween_interval(LIFETIME)
	t.tween_property(l, "modulate:a", 0.0, 0.6)
	t.tween_callback(l.queue_free)
