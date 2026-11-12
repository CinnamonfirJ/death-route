class_name TouchLayout
extends RefCounted

const TARGET_HEIGHT := 38.0


static func enabled() -> bool:
	if "--mobile-ui" in OS.get_cmdline_user_args():
		return true
	if OS.has_feature("web"):
		return bool(JavaScriptBridge.eval(
			"matchMedia('(any-pointer: coarse)').matches && navigator.maxTouchPoints > 0", true))
	return OS.has_feature("mobile") or DisplayServer.is_touchscreen_available()


static func safe_rect(view: Viewport) -> Rect2:
	var rect := view.get_visible_rect()
	if OS.has_feature("web"):
		var values: Variant = JSON.parse_string(str(JavaScriptBridge.eval(
			"window.deadRouteInsets ? window.deadRouteInsets() : '[0,0,0,0]'", true)))
		if values is Array and values.size() == 4:
			var start := Vector2(values[0], values[1]) * rect.size
			var end := Vector2(values[2], values[3]) * rect.size
			return Rect2(rect.position + start, rect.size - start - end)
	elif OS.has_feature("mobile"):
		var area := DisplayServer.get_display_safe_area()
		if area.has_area():
			var to_view := view.get_screen_transform().affine_inverse()
			return rect.intersection(to_view * Rect2(area))
	return rect


static func fit_panel(panel: Control, bounds: Rect2, max_size: Vector2, padding := 10.0) -> void:
	var available := bounds.grow(-padding)
	panel.size = available.size.min(max_size)
	panel.position = available.get_center() - panel.size * 0.5


static func button(button_node: BaseButton, font_size := 14, height := TARGET_HEIGHT) -> void:
	button_node.custom_minimum_size.y = maxf(button_node.custom_minimum_size.y, height)
	button_node.add_theme_font_override(&"font", ThemeDB.fallback_font)
	button_node.add_theme_font_size_override(&"font_size", font_size)
	if button_node is OptionButton:
		var popup: PopupMenu = button_node.get_popup()
		popup.add_theme_font_override(&"font", ThemeDB.fallback_font)
		popup.add_theme_font_size_override(&"font_size", 14)
		popup.add_theme_constant_override(&"v_separation", 15)


static func label(label_node: Label, font_size := 13) -> void:
	label_node.add_theme_font_override(&"font", ThemeDB.fallback_font)
	label_node.add_theme_font_size_override(&"font_size", font_size)


static func scroll(parent: Container) -> VBoxContainer:
	var scroll_box := ScrollContainer.new()
	scroll_box.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	scroll_box.size_flags_vertical = Control.SIZE_EXPAND_FILL
	parent.add_child(scroll_box)
	var content := VBoxContainer.new()
	content.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	content.add_theme_constant_override(&"separation", 8)
	scroll_box.add_child(content)
	return content
