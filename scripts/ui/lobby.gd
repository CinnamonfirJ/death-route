extends Control
## Multiplayer lobby: host or join, see who's in, host picks destination + rival mode.

const LOBBY_LOCATIONS := [&"hospital", &"camp", &"wasteland"]

var _name_edit: LineEdit
var _addr_edit: LineEdit
var _port_edit: SpinBox
var _host_btn: Button
var _join_btn: Button
var _leave_btn: Button
var _start_btn: Button
var _status: Label
var _roster: Label
var _dest: OptionButton
var _rival: CheckButton
var _host_box: Control


func _ready() -> void:
	theme = Assets.ui_theme()
	_build()
	Net.roster_changed.connect(_refresh)
	Net.status_changed.connect(func(t: String) -> void: _status.text = t)
	_refresh()


func _build() -> void:
	var bg := ColorRect.new()
	bg.color = Color(0.1, 0.09, 0.085)
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(bg)
	var center := CenterContainer.new()
	center.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(center)
	var panel := PanelContainer.new()
	panel.custom_minimum_size = Vector2(420, 0)
	center.add_child(panel)
	var v := VBoxContainer.new()
	v.add_theme_constant_override(&"separation", 5)
	panel.add_child(v)

	var title := Label.new()
	title.text = "MULTIPLAYER"
	title.add_theme_font_size_override(&"font_size", 16)
	title.add_theme_color_override(&"font_color", Color(1, 0.85, 0.4))
	v.add_child(title)

	var row1 := HBoxContainer.new()
	v.add_child(row1)
	row1.add_child(_label("Name"))
	_name_edit = LineEdit.new()
	_name_edit.name = "NameEdit"
	_name_edit.text = Net.my_name
	_name_edit.max_length = 16
	_name_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row1.add_child(_name_edit)

	var character_row := HBoxContainer.new()
	v.add_child(character_row)
	character_row.add_child(_label("Character"))
	var picker := CharacterPicker.new()
	picker.name = "CharacterPicker"
	picker.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	character_row.add_child(picker)

	var row2 := HBoxContainer.new()
	v.add_child(row2)
	row2.add_child(_label("Host IP / link"))
	_addr_edit = LineEdit.new()
	_addr_edit.name = "AddressEdit"
	_addr_edit.text = "127.0.0.1"
	_addr_edit.placeholder_text = "192.168.x.x  or  wss://your-tunnel-link"
	_addr_edit.tooltip_text = "LAN: the host's IP. Internet / browser: the host's wss:// tunnel link."
	_addr_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row2.add_child(_addr_edit)
	row2.add_child(_label("Port"))
	_port_edit = SpinBox.new()
	_port_edit.min_value = 1024
	_port_edit.max_value = 65535
	_port_edit.value = Net.DEFAULT_PORT
	row2.add_child(_port_edit)

	var row3 := HBoxContainer.new()
	v.add_child(row3)
	_host_btn = _button(row3, "Host", _on_host)
	_join_btn = _button(row3, "Join", _on_join)
	_leave_btn = _button(row3, "Leave", func() -> void: Net.leave(); _status.text = "Left.")
	if not Net.can_host():
		_host_btn.disabled = true
		_host_btn.tooltip_text = "Browsers can't host. Join a PC or phone host."

	_roster = Label.new()
	_roster.add_theme_font_size_override(&"font_size", 10)
	v.add_child(_roster)

	_host_box = VBoxContainer.new()
	v.add_child(_host_box)
	var row4 := HBoxContainer.new()
	_host_box.add_child(row4)
	row4.add_child(_label("Destination"))
	_dest = OptionButton.new()
	for id in LOBBY_LOCATIONS:
		_dest.add_item(GameManager.LOCATIONS[id].name)
	var selected := LOBBY_LOCATIONS.find(GameManager.selected_location)
	if selected >= 0:
		_dest.select(selected)
	_dest.item_selected.connect(func(i: int) -> void: Net.set_setting("location", String(LOBBY_LOCATIONS[i])))
	_dest.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row4.add_child(_dest)
	_rival = CheckButton.new()
	_rival.text = "Secret rival (one of you is a saboteur)"
	_rival.toggled.connect(func(on: bool) -> void: Net.set_setting("rival", on))
	_host_box.add_child(_rival)
	_start_btn = _button(_host_box, "START RUN", func() -> void: Net.start_match())

	_status = Label.new()
	_status.add_theme_font_size_override(&"font_size", 9)
	_status.add_theme_color_override(&"font_color", Color(0.75, 0.72, 0.65))
	_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_status.text = "Host a game, or join one on your network. All players need the same game version."
	v.add_child(_status)

	_button(v, "Back to Garage", func() -> void:
		Net.leave()
		get_tree().change_scene_to_file(GameManager.GARAGE_SCENE))


func _label(text: String) -> Label:
	var l := Label.new()
	l.text = text
	l.custom_minimum_size = Vector2(70, 0)
	return l


func _button(parent: Control, text: String, cb: Callable) -> Button:
	var b := Button.new()
	b.text = text
	b.name = text.replace(" ", "")
	b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	b.pressed.connect(cb)
	parent.add_child(b)
	return b


func _on_host() -> void:
	Net.my_name = _name_edit.text.strip_edges() if _name_edit.text.strip_edges() != "" else "Host"
	Net.host(int(_port_edit.value))
	Net.set_setting("location", String(LOBBY_LOCATIONS[_dest.selected]))


func _on_join() -> void:
	Net.my_name = _name_edit.text.strip_edges() if _name_edit.text.strip_edges() != "" else "Handyman"
	Net.join(_addr_edit.text.strip_edges(), int(_port_edit.value))


func _refresh() -> void:
	var online := Net.is_online()
	var lines: Array[String] = ["Players (%d/%d):" % [Net.players.size(), Net.MAX_PLAYERS]]
	for id in Net.players:
		lines.append("  %s · %s%s" % [Net.peer_name(id),
			GameManager.PLAYABLE_CHARACTERS[Net.peer_character(id)], "  (host)" if id == 1 else ""])
	if Net.players.is_empty():
		lines.append("  (not connected)")
	else:
		var loc: Dictionary = GameManager.LOCATIONS.get(StringName(Net.settings.location), {})
		lines.append("Destination: %s%s" % [loc.get("name", "?"), "   ·   Secret rival ON" if Net.settings.rival else ""])
	_roster.text = "\n".join(lines)
	_host_box.visible = Net.is_host()
	_start_btn.disabled = not Net.is_host()
	_host_btn.disabled = online or not Net.can_host()
	_join_btn.disabled = online
	_leave_btn.disabled = not online
