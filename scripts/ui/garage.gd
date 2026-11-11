extends Control
## Between-run hub: spend scrap on upgrades, maintain weapons, pick a loadout,
## start the next delivery. Rows are rebuilt from the UpgradeCatalog on every change.

const TAB_NAMES := {
	UpgradeDef.Category.VEHICLE: "Vehicle",
	UpgradeDef.Category.WEAPONS: "Weapons",
	UpgradeDef.Category.HANDYMAN: "Handyman",
}
const STARTER_CAR := &"delivery_hatch"

@onready var scrap: Label = %Scrap
@onready var scrap_icon: TextureRect = %ScrapIcon
@onready var last_run: Label = %LastRun
@onready var tabs: TabContainer = %Tabs
@onready var weapons_row: HBoxContainer = %LoadoutWeapons
@onready var car_sprite: TextureRect = %CarSprite
@onready var car_stats_label: Label = %CarStats
@onready var lifetime: Label = %Lifetime
@onready var start_button: Button = %StartButton
@onready var destinations: HBoxContainer = %Destinations
@onready var dest_blurb: Label = %DestBlurb

## Short button labels for the destination row.
const DEST_SHORT := {&"hospital": "Hospital", &"camp": "Camp", &"wasteland": "Route 9"}


func _ready() -> void:
	get_tree().paused = false
	GameManager.phase = GameManager.Phase.GARAGE
	theme = Assets.ui_theme()
	scrap_icon.texture = Assets.item_icon("scrap")
	start_button.pressed.connect(GameManager.launch_run)
	%CoopButton.pressed.connect(func() -> void:
		get_tree().change_scene_to_file("res://scenes/ui/lobby.tscn"))
	_add_settings_button()
	_build_tabs()
	_build_destinations()
	_refresh()
	start_button.grab_focus()


## Header button that opens the shared settings panel in an overlay.
func _add_settings_button() -> void:
	var header := $Margin/VBox/Header
	var b := Button.new()
	b.name = "SettingsButton"
	b.text = "SETTINGS"
	b.add_theme_font_size_override(&"font_size", 9)
	header.add_child(b)
	header.move_child(b, scrap_icon.get_index())
	var overlay := CenterContainer.new()
	overlay.name = "SettingsOverlay"
	overlay.set_anchors_preset(Control.PRESET_FULL_RECT)
	overlay.visible = false
	var dim := ColorRect.new()
	dim.color = Color(0, 0, 0, 0.55)
	dim.set_anchors_preset(Control.PRESET_FULL_RECT)
	dim.mouse_filter = Control.MOUSE_FILTER_STOP
	var layer := Control.new()
	layer.set_anchors_preset(Control.PRESET_FULL_RECT)
	layer.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(layer)
	layer.add_child(dim)
	layer.add_child(overlay)
	dim.visible = false
	var panel := PanelContainer.new()
	overlay.add_child(panel)
	var v := VBoxContainer.new()
	panel.add_child(v)
	v.add_child(SettingsPanel.new())
	var close := Button.new()
	close.text = "Done"
	v.add_child(close)
	var show := func(on: bool) -> void:
		overlay.visible = on
		dim.visible = on
	b.pressed.connect(show.bind(true))
	close.pressed.connect(show.bind(false))


func _build_tabs() -> void:
	for category in TAB_NAMES:
		tabs.add_child(_make_tab(TAB_NAMES[category]))
	tabs.add_child(_make_tab("Maintenance"))


func _make_tab(tab_name: String) -> ScrollContainer:
	var scroll := ScrollContainer.new()
	scroll.name = tab_name
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	var list := VBoxContainer.new()
	list.name = "List"
	list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	list.add_theme_constant_override(&"separation", 3)
	scroll.add_child(list)
	return scroll


## Rebuilds everything from GameManager state. Cheap enough to call after every click.
func _refresh() -> void:
	scrap.text = "%d scrap" % GameManager.currency
	_refresh_last_run()
	for category in TAB_NAMES:
		var list := tabs.get_node("%s/List" % TAB_NAMES[category])
		_clear(list)
		for u in GameManager.catalog.in_category(category):
			list.add_child(_upgrade_row(u))
	var maint := tabs.get_node("Maintenance/List")
	_clear(maint)
	for id in GameManager.WEAPONS:
		maint.add_child(_maintenance_row(id))
	_refresh_loadout()
	_refresh_destinations()
	_refresh_car()
	var s := GameManager.stats
	lifetime.text = "Runs: %d  ·  Delivered: %d\nKills: %d  ·  Best haul: %d" % [
		s.runs, s.successful_runs, s.zombies_killed, s.best_run_scrap]


func _refresh_last_run() -> void:
	var r := GameManager.last_run
	if r.is_empty():
		last_run.text = "First day on the job. Buy something, then go deliver."
		return
	last_run.text = "Last run: %s  ·  +%d scrap banked  ·  %d kills  ·  %s at %d%%" % [
		"DELIVERED" if r.success else "FAILED (half scrap kept)", r.scrap_banked, r.kills,
		String(r.weapon).capitalize(), roundi(float(r.durability) * 100.0)]


func _clear(node: Node) -> void:
	for c in node.get_children():
		node.remove_child(c)
		c.queue_free()


func _upgrade_row(u: UpgradeDef) -> Control:
	var level := GameManager.get_upgrade_level(u.id)
	var row := HBoxContainer.new()
	row.name = String(u.id)
	row.add_theme_constant_override(&"separation", 6)
	row.add_child(_icon(Assets.item_icon(u.icon_item)))

	var text := VBoxContainer.new()
	text.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	text.add_theme_constant_override(&"separation", 0)
	var head := Label.new()
	head.text = "%s   %s" % [u.display_name, _pips(level, u.max_level)]
	if level > 0:
		head.text += "   " + u.effect_text(level)
	head.add_theme_font_size_override(&"font_size", 10)
	var desc := Label.new()
	desc.text = u.description
	desc.add_theme_font_size_override(&"font_size", 8)
	desc.add_theme_color_override(&"font_color", Color(0.7, 0.68, 0.62))
	desc.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	text.add_child(head)
	text.add_child(desc)
	row.add_child(text)

	var button := Button.new()
	button.name = "Buy"
	button.custom_minimum_size = Vector2(68, 0)
	button.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	var cost := GameManager.next_cost(u.id)
	if cost < 0:
		button.text = "MAXED"
		button.disabled = true
	else:
		button.text = "Buy %d" % cost
		button.disabled = cost > GameManager.currency
	button.pressed.connect(func() -> void:
		if GameManager.try_buy(u.id):
			Sfx.play(&"pickup")
			_refresh())
	row.add_child(button)
	return row


func _maintenance_row(id: StringName) -> Control:
	var stats: WeaponStats = load(GameManager.WEAPONS[id])
	var available := GameManager.is_weapon_available(id)
	var durability := GameManager.get_durability(id)
	var row := HBoxContainer.new()
	row.name = String(id)
	row.add_theme_constant_override(&"separation", 6)
	row.add_child(_icon(_weapon_icon(id)))

	var text := VBoxContainer.new()
	text.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var head := Label.new()
	head.text = stats.display_name if available else "%s  (locked)" % stats.display_name
	head.add_theme_font_size_override(&"font_size", 10)
	var bar := ProgressBar.new()
	bar.custom_minimum_size = Vector2(0, 7)
	bar.max_value = 1.0
	bar.value = durability
	bar.show_percentage = false
	bar.self_modulate = Color(1, 1, 1) if durability >= 0.35 else Color(1.6, 0.6, 0.5)
	var note := Label.new()
	note.text = "Condition %d%%%s" % [roundi(durability * 100.0),
		"  · may jam!" if durability < 0.35 else ""]
	note.add_theme_font_size_override(&"font_size", 8)
	text.add_child(head)
	text.add_child(bar)
	text.add_child(note)
	row.add_child(text)

	var button := Button.new()
	button.name = "Repair"
	button.custom_minimum_size = Vector2(68, 0)
	button.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	var cost := GameManager.repair_cost(id)
	button.text = "Repair %d" % cost if cost > 0 else "Mint"
	button.disabled = cost <= 0 or cost > GameManager.currency or not available
	button.pressed.connect(func() -> void:
		if GameManager.repair_weapon(id):
			_refresh())
	row.add_child(button)
	return row


func _refresh_loadout() -> void:
	_clear(weapons_row)
	for id in GameManager.WEAPONS:
		var stats: WeaponStats = load(GameManager.WEAPONS[id])
		var b := Button.new()
		b.name = String(id)
		b.toggle_mode = true
		b.button_pressed = GameManager.loadout_weapon == id
		b.disabled = not GameManager.is_weapon_available(id)
		b.text = stats.display_name if not b.disabled else "%s (locked)" % stats.display_name
		b.icon = _weapon_icon(id)
		b.add_theme_font_size_override(&"font_size", 9)
		b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		b.pressed.connect(func() -> void:
			GameManager.set_loadout(id)
			_refresh())
		weapons_row.add_child(b)


func _build_destinations() -> void:
	for id in GameManager.LOCATIONS:
		var loc: Dictionary = GameManager.LOCATIONS[id]
		if loc.get("hidden", false):
			continue
		var b := Button.new()
		b.name = String(id)
		b.toggle_mode = true
		b.text = DEST_SHORT.get(id, loc.name)
		b.add_theme_font_size_override(&"font_size", 9)
		b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		b.pressed.connect(_select_destination.bind(id))
		destinations.add_child(b)


func _select_destination(id: StringName) -> void:
	GameManager.set_destination(id)
	_refresh_destinations()


func _refresh_destinations() -> void:
	# Hidden (dev) maps can't be picked here; fall back to a real destination.
	var selected: Dictionary = GameManager.LOCATIONS.get(GameManager.selected_location, {})
	if selected.is_empty() or selected.get("hidden", false):
		GameManager.set_destination(&"wasteland")
		selected = GameManager.LOCATIONS[&"wasteland"]
	for button: Button in destinations.get_children():
		button.set_pressed_no_signal(button.name == GameManager.selected_location)
	dest_blurb.text = "%s: %s" % [selected.name, selected.blurb]


## Shows the starter car with all purchased upgrades applied.
func _refresh_car() -> void:
	var base: CarStats = load("res://resources/cars/%s.tres" % STARTER_CAR)
	var s := GameManager.upgraded_car_stats(base)
	car_sprite.texture = s.sprite
	car_stats_label.add_theme_font_size_override(&"font_size", 8)
	car_stats_label.text = "%s\nHP %d · Fuel %d\nTop speed %d km/h\nRam x%.2f · Latch resist %d%%" % [
		s.display_name, roundi(s.max_hp), roundi(s.fuel_capacity), roundi(s.top_speed * 0.36),
		s.ram_mult, roundi(s.latch_resist * 100.0)]


func _weapon_icon(id: StringName) -> Texture2D:
	var sf := Assets.weapon_frames(id)
	return sf.get_frame_texture(&"idle", 0) if sf else null


func _icon(tex: Texture2D) -> TextureRect:
	var r := TextureRect.new()
	r.texture = tex
	r.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	r.custom_minimum_size = Vector2(24, 24)
	r.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	r.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	r.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	return r


func _pips(level: int, max_level: int) -> String:
	return "Lv %d/%d" % [level, max_level]
