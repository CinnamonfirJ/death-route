extends Control

const AMBER := TitleStyle.AMBER
const CREAM := TitleStyle.CREAM
const MUTED := TitleStyle.MUTED

var _menu: CenterContainer
var _overlay: Control
var _panel: VBoxContainer
var _play: Button
var _account: Button
var _status: Label
var _account_actions: VBoxContainer
var _frame: PanelContainer
var _footer: VBoxContainer
var _mobile := false


func _ready() -> void:
	GameManager.phase = GameManager.Phase.MENU
	_mobile = TouchLayout.enabled()
	theme = Assets.ui_theme()
	TitleStyle.add_backdrop(self)
	_menu = CenterContainer.new()
	_menu.set_anchors_and_offsets_preset(Control.PRESET_TOP_LEFT)
	add_child(_menu)
	var stack := VBoxContainer.new()
	stack.custom_minimum_size.x = 404 if _mobile else 274
	stack.add_theme_constant_override(&"separation", 8)
	_menu.add_child(stack)
	var title := _label("DEAD ROUTE", 38, CREAM)
	title.add_theme_color_override(&"font_shadow_color", Color("#0b0715"))
	title.add_theme_constant_override(&"shadow_offset_x", 2)
	title.add_theme_constant_override(&"shadow_offset_y", 5)
	stack.add_child(title)
	_play = _button(stack, "PLAY", GameManager.goto_garage, true)
	_play.custom_minimum_size = Vector2(180, 48) if _mobile else Vector2(180, 32)
	if not _mobile:
		_play.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	var row := HBoxContainer.new()
	row.add_theme_constant_override(&"separation", 6)
	stack.add_child(row)
	_button(row, "LEADERBOARD", _show_scores)
	_button(row, "SHOP", _show_shop)
	_button(row, "EARN", _show_earn)
	var secondary := HBoxContainer.new()
	secondary.add_theme_constant_override(&"separation", 6)
	stack.add_child(secondary)
	_account = _button(secondary, "SIGN IN WITH GOOGLE", _account_pressed)
	_button(secondary, "SETTINGS", _show_settings)
	if FullscreenButton.available():
		var full := FullscreenButton.new()
		full.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		if _mobile:
			TouchLayout.button(full)
		secondary.add_child(full)
	get_viewport().size_changed.connect(_layout)
	_layout()
	WalletSession.changed.connect(_refresh_account)
	_refresh_account()
	_play.grab_focus()


func _show_scores() -> void:
	_open("LOCAL LEADERBOARD")
	_copy("Successful deliveries ranked by scrap, then kills.")
	if GameManager.run_scores.is_empty():
		_copy("Complete a delivery to set your first score.")
	for i in GameManager.run_scores.size():
		var score: Dictionary = GameManager.run_scores[i]
		var route: Dictionary = GameManager.LOCATIONS.get(StringName(score.location), {})
		var row := HBoxContainer.new()
		var label := _label("%02d  %s" % [i + 1, route.get("name", "Delivery")], 10, CREAM)
		label.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT
		label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		row.add_child(label)
		row.add_child(_label("%d scrap  /  %d kills" % [int(score.scrap), int(score.kills)], 10, AMBER))
		_panel.add_child(row)
	_close_button()


func _show_shop() -> void:
	_open("SHOP")
	_copy("%d scrap available for garage upgrades." % GameManager.currency, AMBER)
	_copy("Spend scrap on vehicle, weapon, and gear upgrades in the garage.")
	_button(_panel, "OPEN GARAGE SHOP", GameManager.goto_garage, true).grab_focus()
	_close_button(false)


func _show_earn() -> void:
	_open("EARN")
	_copy("%d deliveries completed" % GameManager.stats.successful_runs, AMBER)
	_copy("Complete deliveries to earn scrap for garage upgrades.")
	_close_button()


func _account_pressed() -> void:
	_show_account()
	if OS.has_feature("web") and not WalletSession.signed_in and not WalletSession.busy:
		WalletSession.sign_in()


func _show_account() -> void:
	_open("ACCOUNT")
	_status = _copy("")
	_account_actions = VBoxContainer.new()
	_account_actions.add_theme_constant_override(&"separation", 5)
	_panel.add_child(_account_actions)
	_close_button()
	_refresh_account()


func _show_settings() -> void:
	_open("")
	_panel.add_child(SettingsPanel.new())
	_close_button()


func _refresh_account() -> void:
	_account.text = "ACCOUNT" if WalletSession.signed_in else "SIGN IN WITH GOOGLE"
	if not is_instance_valid(_status):
		return
	for child in _account_actions.get_children():
		_account_actions.remove_child(child)
		child.queue_free()
	if WalletSession.busy:
		_status.text = WalletSession.message
		if not WalletSession.browser_url.is_empty():
			_button(_account_actions, "OPEN SIGN-IN PAGE", WalletSession.open_browser, true)
		_button(_account_actions, "CANCEL SIGN-IN", WalletSession.cancel_sign_in)
	elif WalletSession.signed_in:
		_status.text = WalletSession.message if not WalletSession.message.is_empty() else "Signed in with Google as %s." % GameManager.display_name()
		_button(_account_actions, "PLAY", GameManager.goto_garage, true)
		_button(_account_actions, "SIGN OUT", WalletSession.sign_out)
	else:
		_status.text = WalletSession.message if not WalletSession.message.is_empty() else "Sign in with Google or play as a guest."
		_button(_account_actions, "CONTINUE WITH GOOGLE", WalletSession.sign_in, true)
		_button(_account_actions, "PLAY AS GUEST", GameManager.goto_garage)


func _open(title: String) -> void:
	_close()
	_menu.hide()
	_overlay = Control.new()
	add_child(_overlay)
	_overlay.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	var dim := ColorRect.new()
	dim.color = Color(0.025, 0.019, 0.055, 0.75)
	_overlay.add_child(dim)
	dim.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_frame = PanelContainer.new()
	_frame.add_theme_stylebox_override(&"panel", TitleStyle.surface(TitleStyle.INK, TitleStyle.BORDER, 14))
	_overlay.add_child(_frame)
	_footer = VBoxContainer.new()
	_frame.add_child(_footer)
	_panel = TouchLayout.scroll(_footer)
	_layout()
	if not title.is_empty():
		_panel.add_child(_label(title, 17, AMBER))


func _close_button(focus := true) -> void:
	var close := _button(_footer, "BACK", _close)
	if focus:
		close.grab_focus()


func _close() -> void:
	if not is_instance_valid(_overlay):
		return
	remove_child(_overlay)
	_overlay.queue_free()
	_overlay = null
	_frame = null
	_status = null
	_menu.show()
	_play.grab_focus()


func _layout() -> void:
	var bounds := TouchLayout.safe_rect(get_viewport()) if _mobile else get_viewport_rect()
	_menu.position = bounds.position
	_menu.size = bounds.size
	if is_instance_valid(_frame):
		TouchLayout.fit_panel(_frame, bounds, Vector2(424, 332))


func _unhandled_input(event: InputEvent) -> void:
	if is_instance_valid(_overlay) and event.is_action_pressed(&"ui_cancel"):
		get_viewport().set_input_as_handled()
		_close()


func _copy(value: String, color := MUTED) -> Label:
	var label := _label(value, 10, color)
	if _mobile:
		TouchLayout.label(label, 14)
	label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_panel.add_child(label)
	return label


func _label(value: String, font_size: int, color: Color) -> Label:
	var label := Label.new()
	label.text = value
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	label.add_theme_color_override(&"font_color", color)
	label.add_theme_font_size_override(&"font_size", font_size)
	return label


func _button(parent: Container, value: String, action: Callable, primary := false) -> Button:
	var button := Button.new()
	button.text = value
	button.custom_minimum_size.y = 24
	button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	button.add_theme_font_size_override(&"font_size", 12 if primary else 10)
	if _mobile:
		TouchLayout.button(button, 16 if primary else 14)
	if primary:
		TitleStyle.primary(button)
	button.pressed.connect(action)
	parent.add_child(button)
	return button
