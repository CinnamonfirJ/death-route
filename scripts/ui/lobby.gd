extends Control
## Multiplayer lobby: host or join, see who's in. The host picks the mode (Co-op run,
## Team Deathmatch, Free For All), the map, and the rules; players pick a team and
## press READY. The host starts once everyone is ready.

const LOBBY_LOCATIONS := [&"hospital", &"camp", &"wasteland"]

var _name_edit: LineEdit
var _code_edit: LineEdit
var _public: CheckButton
var _allow_voice: CheckButton
var _browser: VBoxContainer
var _rooms: ItemList
var _directory_status: Label
var _request: HTTPRequest
var _room_title: Label
var _identity: VBoxContainer
var _host_btn: Button
var _join_btn: Button
var _leave_btn: Button
var _start_btn: Button
var _status: Label
var _roster: RichTextLabel
var _mode: OptionButton
var _pizza_rule: OptionButton
var _versus_box: Control
var _team_row: Control
var _ready_btn: Button
var _dest: OptionButton
var _rival: CheckButton
var _host_box: Control
var _panel: PanelContainer
var _mobile := false


func _ready() -> void:
	_mobile = TouchLayout.enabled()
	theme = Assets.ui_theme()
	_build()
	get_viewport().size_changed.connect(_layout)
	_layout()
	Net.roster_changed.connect(_refresh)
	Net.status_changed.connect(func(t: String) -> void: _status.text = t)
	_refresh()
	_fetch_rooms()


func _build() -> void:
	TitleStyle.add_backdrop(self)
	var panel := PanelContainer.new()
	_panel = panel
	add_child(panel)
	var frame := VBoxContainer.new()
	panel.add_child(frame)
	var scroll := ScrollContainer.new()
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	frame.add_child(scroll)
	var v := VBoxContainer.new()
	v.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	v.add_theme_constant_override(&"separation", 5)
	scroll.add_child(v)

	var title := Label.new()
	title.text = "ONLINE ROOMS"
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.add_theme_font_size_override(&"font_size", 16)
	title.add_theme_color_override(&"font_color", TitleStyle.AMBER)
	v.add_child(title)

	var entry: Container = HBoxContainer.new() if _mobile else VBoxContainer.new()
	entry.add_theme_constant_override(&"separation", 12 if _mobile else 5)
	v.add_child(entry)
	_identity = VBoxContainer.new()
	_identity.custom_minimum_size.x = 162 if _mobile else 0
	_identity.add_theme_constant_override(&"separation", 8)
	entry.add_child(_identity)
	var row1: Container = VBoxContainer.new() if _mobile else HBoxContainer.new()
	_identity.add_child(row1)
	row1.add_child(_label("Name"))
	_name_edit = LineEdit.new()
	_name_edit.name = "NameEdit"
	_name_edit.text = str(GameManager.get_setting("display_name"))
	_name_edit.placeholder_text = GameManager.display_name()
	_name_edit.max_length = 16
	_name_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_style_field(_name_edit)
	row1.add_child(_name_edit)

	var character_row: Container = VBoxContainer.new() if _mobile else HBoxContainer.new()
	_identity.add_child(character_row)
	character_row.add_child(_label("Character"))
	var picker := CharacterPicker.new()
	picker.name = "CharacterPicker"
	picker.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	if _mobile:
		TouchLayout.button(picker)
	character_row.add_child(picker)

	_add_browser(entry)
	var room_row := HBoxContainer.new()
	v.add_child(room_row)
	_room_title = _label("")
	_room_title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_room_title.add_theme_color_override(&"font_color", TitleStyle.AMBER)
	room_row.add_child(_room_title)
	_button(room_row, "COPY CODE", func() -> void:
		DisplayServer.clipboard_set(Net.room_code)
		_status.text = "Room code copied.").size_flags_horizontal = Control.SIZE_FILL
	_leave_btn = _button(room_row, "LEAVE ROOM", func() -> void:
		Net.leave()
		_status.text = ""
		_fetch_rooms())
	_leave_btn.size_flags_horizontal = Control.SIZE_FILL

	_roster = RichTextLabel.new()
	_roster.name = "Roster"
	_roster.bbcode_enabled = true
	_roster.fit_content = true
	_roster.scroll_active = false
	_roster.add_theme_font_size_override(&"normal_font_size", 10)
	if _mobile:
		_roster.add_theme_font_override(&"normal_font", ThemeDB.fallback_font)
		_roster.add_theme_font_size_override(&"normal_font_size", 14)
	v.add_child(_roster)

	# Everyone (versus): pick a side + ready up.
	_team_row = HBoxContainer.new()
	v.add_child(_team_row)
	var red := _button(_team_row, "Join RED", func() -> void: Net.set_team(0))
	red.add_theme_color_override(&"font_color", MatchState.TEAM_COLORS[0])
	var blue := _button(_team_row, "Join BLUE", func() -> void: Net.set_team(1))
	blue.add_theme_color_override(&"font_color", MatchState.TEAM_COLORS[1])
	_ready_btn = Button.new()
	_ready_btn.name = "ReadyButton"
	_ready_btn.toggle_mode = true
	_ready_btn.text = "READY"
	_ready_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_ready_btn.toggled.connect(func(on: bool) -> void: Net.set_ready(on))
	v.add_child(_ready_btn)

	_host_box = VBoxContainer.new()
	v.add_child(_host_box)
	var mode_row := HBoxContainer.new()
	_host_box.add_child(mode_row)
	mode_row.add_child(_label("Mode"))
	_mode = OptionButton.new()
	_mode.name = "ModeOption"
	for m in Net.MODES:
		_mode.add_item(Net.MODE_NAMES[m])
	_mode.item_selected.connect(func(i: int) -> void: Net.set_setting("mode", Net.MODES[i]))
	_mode.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	mode_row.add_child(_mode)
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
	_versus_box = VBoxContainer.new()
	_host_box.add_child(_versus_box)
	var rule_row := HBoxContainer.new()
	_versus_box.add_child(rule_row)
	rule_row.add_child(_label("Enemy pizza"))
	_pizza_rule = OptionButton.new()
	_pizza_rule.add_item("Can steal it (carry it away)")
	_pizza_rule.add_item("Can only reset it (it respawns)")
	_pizza_rule.item_selected.connect(func(i: int) -> void:
		Net.set_setting("pizza_enemy", "steal" if i == 0 else "reset"))
	_pizza_rule.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	rule_row.add_child(_pizza_rule)
	_button(_versus_box, "Auto-balance teams", func() -> void: Net.auto_balance())
	_rival = CheckButton.new()
	_rival.text = "Secret rival (one of you is a saboteur)"
	_rival.toggled.connect(func(on: bool) -> void: Net.set_setting("rival", on))
	_host_box.add_child(_rival)
	_start_btn = _button(_host_box, "START RUN", func() -> void: Net.start_match())
	TitleStyle.primary(_start_btn)

	_status = Label.new()
	_status.add_theme_font_size_override(&"font_size", 9)
	_status.add_theme_color_override(&"font_color", TitleStyle.MUTED)
	_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	if _mobile:
		TouchLayout.label(_status, 13)
	frame.add_child(_status)

	_button(frame, "BACK TO GARAGE", func() -> void:
		Net.leave()
		get_tree().change_scene_to_file(GameManager.GARAGE_SCENE))


func _label(text: String) -> Label:
	var l := Label.new()
	l.text = text
	l.custom_minimum_size = Vector2(70, 0)
	if _mobile:
		TouchLayout.label(l)
	return l


func _button(parent: Control, text: String, cb: Callable) -> Button:
	var b := Button.new()
	b.text = text
	b.name = text.replace(" ", "")
	b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	b.custom_minimum_size.y = 22
	if _mobile:
		TouchLayout.button(b, 13, 34)
	b.pressed.connect(cb)
	parent.add_child(b)
	return b


func _layout() -> void:
	TouchLayout.fit_panel(_panel, TouchLayout.safe_rect(get_viewport()),
		Vector2(552 if _mobile else 460, 348), 6)


func _style_field(field: LineEdit) -> void:
	if _mobile:
		field.custom_minimum_size.y = 35
		field.add_theme_font_override(&"font", ThemeDB.fallback_font)
		field.add_theme_font_size_override(&"font_size", 14)


func _add_browser(parent: Control) -> void:
	_browser = VBoxContainer.new()
	_browser.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_browser.add_theme_constant_override(&"separation", 5)
	parent.add_child(_browser)
	var create := HBoxContainer.new()
	_browser.add_child(create)
	_public = CheckButton.new()
	_public.text = "List publicly"
	_public.button_pressed = true
	if _mobile:
		TouchLayout.button(_public, 13, 34)
	create.add_child(_public)
	_host_btn = _button(create, "CREATE ROOM", _on_host)
	TitleStyle.primary(_host_btn)
	_allow_voice = CheckButton.new()
	_allow_voice.text = "Allow proximity voice"
	_allow_voice.button_pressed = true
	TouchLayout.button(_allow_voice, 13, 34)
	_browser.add_child(_allow_voice)

	var join := HBoxContainer.new()
	_browser.add_child(join)
	_code_edit = LineEdit.new()
	_code_edit.max_length = 6
	_code_edit.placeholder_text = "6-character room code"
	_code_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_style_field(_code_edit)
	_code_edit.text_submitted.connect(func(_value: String) -> void: _on_join())
	join.add_child(_code_edit)
	_join_btn = _button(join, "JOIN CODE", _on_join)
	_join_btn.size_flags_horizontal = Control.SIZE_FILL

	var directory := HBoxContainer.new()
	_browser.add_child(directory)
	_directory_status = _label("Public rooms")
	_directory_status.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	directory.add_child(_directory_status)
	_button(directory, "REFRESH", _fetch_rooms).size_flags_horizontal = Control.SIZE_FILL
	_rooms = ItemList.new()
	_rooms.custom_minimum_size.y = 57
	if _mobile:
		_rooms.add_theme_font_override(&"font", ThemeDB.fallback_font)
		_rooms.add_theme_font_size_override(&"font_size", 14)
		_rooms.add_theme_constant_override(&"v_separation", 15)
		_rooms.custom_minimum_size.y = 75
	_rooms.item_activated.connect(func(_index: int) -> void: _join_selected())
	_browser.add_child(_rooms)
	_button(_browser, "JOIN SELECTED ROOM", _join_selected)
	_request = HTTPRequest.new()
	_request.timeout = 7.0
	_request.body_size_limit = 32768
	_request.request_completed.connect(_on_directory)
	add_child(_request)
	var refresh_timer := Timer.new()
	refresh_timer.wait_time = 8.0
	refresh_timer.autostart = true
	refresh_timer.timeout.connect(_fetch_rooms)
	add_child(refresh_timer)


func _fetch_rooms() -> void:
	if Net.is_online() or Net.room_connecting() or _request.get_http_client_status() != HTTPClient.STATUS_DISCONNECTED:
		return
	var service := Net.room_service_url()
	if service.is_empty() or _request.request(service + "/rooms") != OK:
		_directory_status.text = "Room service unavailable"


func _on_directory(result: int, response_code: int, _headers: PackedStringArray, body: PackedByteArray) -> void:
	if not _browser.visible:
		return
	if result != HTTPRequest.RESULT_SUCCESS or response_code != 200:
		_directory_status.text = "Room service unavailable"
		return
	var data: Variant = JSON.parse_string(body.get_string_from_utf8())
	if not data is Dictionary or not data.get("rooms") is Array:
		_directory_status.text = "Room service unavailable"
		return
	var selected := ""
	if not _rooms.get_selected_items().is_empty():
		selected = str(_rooms.get_item_metadata(_rooms.get_selected_items()[0]))
	_rooms.clear()
	for room in data.rooms:
		if not room is Dictionary:
			continue
		var code := str(room.get("code", ""))
		var mode := str(Net.MODE_NAMES.get(room.get("mode", ""), "Co-op Run"))
		var location: Dictionary = GameManager.LOCATIONS.get(StringName(room.get("location", "")), {})
		var index := _rooms.add_item("%s  /  %s  /  %s   %d/%d" % [
			str(room.get("name", "Courier")).left(16), mode, location.get("name", ""),
			int(room.get("count", 0)), int(room.get("capacity", 4))])
		_rooms.set_item_metadata(index, code)
		if code == selected:
			_rooms.select(index)
	_directory_status.text = "Public rooms (%d)" % _rooms.item_count if _rooms.item_count else "No public rooms open"


func _set_name() -> void:
	var value := GameManager.clean_display_name(_name_edit.text)
	if value != GameManager.get_setting("display_name"):
		GameManager.set_setting("display_name", value)


func _on_host() -> void:
	if not Net.is_online() and not Net.room_connecting():
		_set_name()
		Net.create_room(_public.button_pressed, GameManager.selected_location, _allow_voice.button_pressed)


func _on_join() -> void:
	_join_code(_code_edit.text.strip_edges().to_upper())


func _join_selected() -> void:
	if _rooms.get_selected_items().is_empty():
		_status.text = "Select a public room first."
		return
	_join_code(str(_rooms.get_item_metadata(_rooms.get_selected_items()[0])))


func _join_code(code: String) -> void:
	if Net.is_online() or Net.room_connecting():
		return
	var valid := code.length() == 6
	for letter in code:
		valid = valid and letter in "ABCDEFGHJKLMNPQRSTUVWXYZ23456789"
	if not valid:
		_status.text = "Enter the six-character code shown in the room."
		return
	_set_name()
	Net.join_room(code)


func _refresh() -> void:
	var online := Net.is_online()
	var mode: String = Net.settings.get("mode", "coop")
	var versus := mode != "coop"
	var lines: Array[String] = ["Players (%d/%d):" % [Net.players.size(), Net.MAX_PLAYERS]]
	for id in Net.players:
		var team := ""
		if mode == "tdm":
			var t := Net.peer_team(id)
			team = "[color=#%s]%s[/color]  " % [MatchState.TEAM_COLORS[t].to_html(false), MatchState.TEAM_NAMES[t]]
		var ready := ""
		if versus:
			ready = "   [color=#7fdc6a]READY[/color]" if Net.peer_ready(id) else "   [color=#b0a090]not ready[/color]"
		lines.append("  %s%s · %s%s%s" % [team, Net.peer_name(id).replace("[", "[lb]"),
			GameManager.PLAYABLE_CHARACTERS[Net.peer_character(id)], "  (host)" if id == 1 else "", ready])
	if Net.players.is_empty():
		lines.append("  (not connected)")
	else:
		var loc: Dictionary = GameManager.LOCATIONS.get(StringName(Net.settings.location), {})
		var extra := ""
		if versus:
			extra = "   ·   Enemy pizza: %s" % ("steal" if Net.settings.get("pizza_enemy", "steal") == "steal" else "reset only")
		elif Net.settings.rival:
			extra = "   ·   Secret rival ON"
		lines.append("Mode: %s   ·   Map: %s%s" % [Net.MODE_NAMES[mode], loc.get("name", "?"), extra])
		lines.append("Proximity voice: %s" % ("Allowed" if Net.allows_voice() else "Off"))
	_roster.text = "\n".join(lines)
	_roster.visible = online
	_browser.visible = not online
	_identity.visible = not online
	_room_title.get_parent().visible = online
	_room_title.text = "ROOM CODE   %s" % Net.room_code
	_host_box.visible = Net.is_host()
	_mode.select(Net.MODES.find(mode))
	var destination := LOBBY_LOCATIONS.find(StringName(Net.settings.location))
	if destination >= 0:
		_dest.select(destination)
	_pizza_rule.select(0 if Net.settings.pizza_enemy == "steal" else 1)
	_rival.set_pressed_no_signal(Net.settings.rival)
	_versus_box.visible = versus
	_rival.visible = not versus
	_team_row.visible = online and mode == "tdm"
	_ready_btn.visible = online and versus and not Net.is_host()
	if _ready_btn.visible:
		_ready_btn.set_pressed_no_signal(Net.peer_ready(Net.local_id()))
	_start_btn.text = "START MATCH" if versus else "START RUN"
	_start_btn.disabled = not Net.is_host() or (versus and not Net.all_ready())
	_host_btn.disabled = online or Net.room_connecting()
	_join_btn.disabled = online or Net.room_connecting()
	_leave_btn.disabled = not online
