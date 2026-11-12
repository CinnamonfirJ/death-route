class_name TitleStyle
extends RefCounted

const Backdrop := preload("res://scripts/ui/title_backdrop.gd")
const AMBER := Color("#ffc688")
const CREAM := Color("#fff2df")
const MUTED := Color("#b5b3cb")
const INK := Color("#151428")
const BORDER := Color("#784650")


static func add_backdrop(parent: Control) -> void:
	var backdrop := Backdrop.new()
	backdrop.mouse_filter = Control.MOUSE_FILTER_IGNORE
	backdrop.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	parent.add_child(backdrop)
	parent.move_child(backdrop, 0)


static func surface(fill: Color, border: Color, padding: int) -> StyleBoxFlat:
	var style := StyleBoxFlat.new()
	style.bg_color = fill
	style.border_color = border
	style.set_border_width_all(1)
	style.set_content_margin_all(padding)
	return style


static func primary(button: Button) -> void:
	button.add_theme_color_override(&"font_color", AMBER)
	button.add_theme_stylebox_override(&"normal", surface(Color("#362238"), Color("#e38b56"), 5))


static func apply(theme: Theme) -> void:
	var panel := surface(Color("#151428f5"), BORDER, 9)
	var normal := surface(Color("#1a192e"), Color("#844c57"), 5)
	var hover := surface(Color("#4b283c"), AMBER, 5)
	var pressed := surface(Color("#2a1932"), AMBER, 5)
	var disabled := surface(Color("#181623"), Color("#4d374b"), 5)
	var focus := surface(Color.TRANSPARENT, AMBER, 0)
	focus.draw_center = false
	focus.set_expand_margin_all(1)

	for type in [&"Panel", &"PanelContainer", &"PopupPanel", &"PopupMenu", &"ItemList"]:
		theme.set_stylebox(&"panel", type, panel)
	for type in [&"Button", &"OptionButton"]:
		theme.set_stylebox(&"normal", type, normal)
		theme.set_stylebox(&"hover", type, hover)
		theme.set_stylebox(&"pressed", type, pressed)
		theme.set_stylebox(&"disabled", type, disabled)
		theme.set_stylebox(&"focus", type, focus)
		theme.set_color(&"font_color", type, CREAM)
		theme.set_color(&"font_hover_color", type, AMBER)
		theme.set_color(&"font_disabled_color", type, MUTED.darkened(0.25))
	for type in [&"Label", &"LineEdit", &"CheckButton", &"ItemList", &"PopupMenu", &"TabContainer"]:
		theme.set_color(&"font_color", type, CREAM)
	theme.set_color(&"font_selected_color", &"TabContainer", AMBER)
	theme.set_color(&"font_unselected_color", &"TabContainer", MUTED)
	theme.set_stylebox(&"normal", &"LineEdit", normal)
	theme.set_stylebox(&"focus", &"LineEdit", focus)
	theme.set_stylebox(&"selected", &"ItemList", pressed)
	theme.set_stylebox(&"selected_focus", &"ItemList", hover)
	theme.set_stylebox(&"hover", &"PopupMenu", hover)
	theme.set_stylebox(&"tab_selected", &"TabContainer", pressed)
	theme.set_stylebox(&"tab_unselected", &"TabContainer", normal)
	theme.set_stylebox(&"tab_hovered", &"TabContainer", hover)
	theme.set_stylebox(&"tab_disabled", &"TabContainer", disabled)
	theme.set_stylebox(&"tab_focus", &"TabContainer", focus)
	theme.set_stylebox(&"panel", &"TabContainer", StyleBoxEmpty.new())
