class_name SettingsPanel
extends VBoxContainer
## Options shared by the Garage and the in-run pause menu. Writes straight to
## GameManager settings (saved immediately).


func _ready() -> void:
	add_theme_constant_override(&"separation", 4)
	var title := Label.new()
	title.text = "SETTINGS"
	title.add_theme_color_override(&"font_color", TitleStyle.AMBER)
	add_child(title)
	var name_label := Label.new()
	name_label.text = "Display name"
	TouchLayout.label(name_label)
	add_child(name_label)
	var name_edit := LineEdit.new()
	name_edit.name = "DisplayName"
	name_edit.text = str(GameManager.get_setting("display_name"))
	name_edit.placeholder_text = WalletSession.google_name if not WalletSession.google_name.is_empty() else "Courier"
	name_edit.max_length = 16
	name_edit.custom_minimum_size.y = 36 if TouchLayout.enabled() else 24
	add_child(name_edit)
	var save_name := func() -> void:
		var value := GameManager.clean_display_name(name_edit.text)
		if value != GameManager.get_setting("display_name"):
			GameManager.set_setting("display_name", value)
	name_edit.text_changed.connect(func(_value: String) -> void: save_name.call())
	name_edit.text_submitted.connect(func(_value: String) -> void: name_edit.release_focus())
	_hint("Leave blank to use your Google name when signed in.")
	if FullscreenButton.available():
		var full := FullscreenButton.new()
		TouchLayout.button(full)
		add_child(full)
	var touch_mode := OptionButton.new()
	touch_mode.name = "TouchShooting"
	touch_mode.add_item("Touch shooting: Drag to fire")
	touch_mode.add_item("Touch shooting: Advanced")
	touch_mode.select(1 if GameManager.get_setting("touch_shooting") == "advanced" else 0)
	TouchLayout.button(touch_mode)
	add_child(touch_mode)
	var touch_hint := _hint("")
	var update_shooting := func(index: int) -> void:
		if index == 1:
			touch_hint.text = "Aim with the right stick. Hold Fire separately."
		else:
			touch_hint.text = "Aim with the right stick. Drag past the ring to fire. Release to stop."
	update_shooting.call(touch_mode.selected)
	touch_mode.item_selected.connect(func(index: int) -> void:
		GameManager.set_setting("touch_shooting", "advanced" if index == 1 else "drag")
		update_shooting.call(index))
	_toggle("Auto-aim", "auto_aim", "Snaps your aim to the zombie nearest your crosshair.")
	_toggle("Auto-run", "auto_run", "Always sprint without holding Shift or Run.")
	var lighting := OptionButton.new()
	lighting.name = "LightingMode"
	lighting.add_item("Lighting  /  Night")
	lighting.add_item("Lighting  /  Classic")
	lighting.select(1 if GameManager.get_setting("lighting_mode") == "classic" else 0)
	lighting.item_selected.connect(func(i: int) -> void:
		GameManager.set_setting("lighting_mode", "night" if i == 0 else "classic"))
	TouchLayout.button(lighting)
	add_child(lighting)
	_slider("Room brightness", "room_brightness", 0.0, 1.0,
		"Night mode only. Left is darker, right is brighter.")
	_slider("Sound effects", "sfx_volume", 0.0, 1.0)
	_slider("Music volume", "music_volume", 0.0, 1.0)
	_slider("Screen shake", "screen_shake", 0.0, 1.5)
	_slider("Voice volume", "voice_volume", 0.0, 1.0)
	_toggle("Mute other players", "voice_mute_others", "Silences everyone's voice chat for you.")


func _toggle(label: String, key: String, hint: String) -> void:
	var c := CheckButton.new()
	c.name = key
	c.text = label
	c.tooltip_text = hint
	c.button_pressed = GameManager.get_setting(key)
	c.toggled.connect(func(on: bool) -> void: GameManager.set_setting(key, on))
	TouchLayout.button(c, 14, 34)
	add_child(c)


func _hint(copy: String) -> Label:
	var h := Label.new()
	h.text = copy
	TouchLayout.label(h, 12)
	h.add_theme_color_override(&"font_color", TitleStyle.MUTED)
	h.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	h.custom_minimum_size = Vector2(220, 0)
	add_child(h)
	return h


func _slider(label: String, key: String, lo: float, hi: float, hint := "") -> void:
	var row := HBoxContainer.new()
	var l := Label.new()
	l.text = label
	TouchLayout.label(l)
	l.custom_minimum_size = Vector2(110, 0)
	row.add_child(l)
	var s := HSlider.new()
	s.name = key
	s.tooltip_text = hint
	s.min_value = lo
	s.max_value = hi
	s.step = 0.05
	s.value = GameManager.get_setting(key)
	s.custom_minimum_size = Vector2(120, 32)
	s.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	s.value_changed.connect(func(v: float) -> void: GameManager.set_setting(key, v))
	row.add_child(s)
	add_child(row)
