extends CanvasLayer
## Player health, weapons, vehicle condition, and route objectives.

## px/s -> displayed km/h. 330 px/s (starter top speed) reads ~120 km/h.
const SPEED_TO_KMH := 0.36
const WEAPON_SHEET := preload("res://assets/weapons/weapons_static_sheet.png")
const WEAPON_REGIONS := {
	&"pistol": Rect2(43, 12, 11, 8),
	&"shotgun": Rect2(101, 13, 22, 8),
	&"knife": Rect2(105, 46, 14, 6),
}
const FOOT_CONTROLS := "WASD Move · Shift Sprint · C Crouch · LMB Attack · V Cycle · R Reload · E Use · F Light"
const CAR_CONTROLS := "WASD Drive · Space Handbrake · Q Shove · H Horn · E Exit"

var _car: Car
var _kills := 0
var _weapon_icon := AtlasTexture.new()
var _touch_hud := false
var _status_cards: Array[Panel] = []
var _route_button: Button
var _route_card: PanelContainer
var _route_text: Label

@onready var player_hp: Range = %PlayerHP
@onready var car_panel: Control = %CarPanel
@onready var car_name: Label = %CarName
@onready var car_hp: ProgressBar = %CarHP
@onready var fuel: ProgressBar = %Fuel
@onready var speed: Label = %Speed
@onready var prompt: Label = %Prompt
@onready var kills: Label = %Kills
@onready var message: Label = %Message
@onready var noise_label: Label = %NoiseLabel
@onready var noise_bar: ProgressBar = %NoiseBar
@onready var ammo: Label = %Ammo
@onready var weapon_name: Label = %WeaponName
@onready var controls: Label = $Controls
@onready var objective: Label = %Objective
@onready var scrap_label: Label = %Scrap
@onready var party: Label = %Party
@onready var light_status: Label = %LightStatus

const MODE_TEXT := {1: "following", 2: "waiting", 3: "in the car"}
var _party_cd := 0.0

const TIER_NAMES := ["QUIET", "HEARD", "HUNTED", "SWARMED", "HORDE"]
const TIER_COLORS := [Color(0.6, 0.85, 1), Color(1, 0.9, 0.4), Color(1, 0.65, 0.25), Color(1, 0.4, 0.3), Color(0.9, 0.1, 0.1)]
const TIER_BANNERS := ["", "Something heard that.", "They're coming.", "That was LOUD.", "THE HORDE IS HERE"]

var _banner_tween: Tween
var _dead := false


func _ready() -> void:
	_weapon_icon.atlas = WEAPON_SHEET
	%WeaponIcon.texture = _weapon_icon
	controls.text = FOOT_CONTROLS
	%PizzaIcon.texture = Assets.item_icon("pizza")
	EventBus.pizza_status_changed.connect(func(t: String) -> void: %PizzaLabel.text = t)
	EventBus.noise_level_changed.connect(_on_noise_level)
	EventBus.noise_threshold_reached.connect(_on_noise_tier)
	EventBus.ammo_changed.connect(_refresh_weapon.unbind(3))
	EventBus.weapon_switched.connect(_refresh_weapon)
	EventBus.objective_changed.connect(_set_objectives)
	EventBus.hud_message.connect(_banner)
	EventBus.weapon_jammed.connect(func() -> void: _banner("*click*  JAMMED. Maintain your gun."))
	EventBus.scrap_collected.connect(func(_a: int) -> void:
		scrap_label.text = "Scrap: %d" % GameManager.run_scrap)
	car_panel.visible = false
	message.visible = false
	prompt.text = ""
	EventBus.player_damaged.connect(_on_player_damaged)
	EventBus.player_died.connect(_on_player_died)
	EventBus.player_entered_car.connect(_on_entered_car)
	EventBus.player_exited_car.connect(_on_exited_car)
	EventBus.car_damaged.connect(_on_car_changed.unbind(2))
	EventBus.car_fuel_changed.connect(_on_car_changed.unbind(2))
	EventBus.interact_prompt_changed.connect(func(t: String) -> void:
		prompt.text = t.replace("[E]", "Use").replace("[Hold E]", "Hold Use") if _touch_hud else t)
	EventBus.zombie_killed.connect(_on_zombie_killed)
	var feed: Control = load("res://scripts/ui/kill_feed.gd").new()
	add_child(feed)
	set_touch_layout.call_deferred($TouchControls.active)


func set_touch_layout(enabled: bool) -> void:
	if not enabled or _touch_hud or not is_node_ready():
		return
	_touch_hud = true
	var left := $TopLeft as VBoxContainer
	var right := $TopRight as VBoxContainer
	kills.reparent(right, false)
	right.move_child(kills, 0)
	objective.hide()
	right.set_anchors_and_offsets_preset(Control.PRESET_TOP_LEFT)
	for column in [left, right]:
		column.add_theme_constant_override(&"separation", 3)
		var card := Panel.new()
		card.mouse_filter = Control.MOUSE_FILTER_IGNORE
		card.add_theme_stylebox_override(&"panel", TitleStyle.surface(Color(TitleStyle.INK, 0.90), TitleStyle.BORDER, 0))
		add_child(card)
		move_child(card, column.get_index())
		_status_cards.append(card)
		column.minimum_size_changed.connect(_layout_touch_hud.call_deferred)
	for element in [left.get_node(^"HPLabel"), light_status, party, car_name, speed,
			kills, scrap_label, noise_label, weapon_name, ammo, %PizzaLabel, prompt]:
		TouchLayout.label(element, 12)
	party.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	%PizzaLabel.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	%PizzaLabel.custom_minimum_size.x = 106

	_route_button = Button.new()
	_route_button.toggle_mode = true
	_route_button.text = "Objectives"
	_route_button.focus_mode = Control.FOCUS_NONE
	_route_button.theme = Assets.ui_theme()
	TouchLayout.button(_route_button)
	add_child(_route_button)
	_route_card = PanelContainer.new()
	_route_card.theme = Assets.ui_theme()
	_route_card.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_route_card)
	var route_scroll := ScrollContainer.new()
	route_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	_route_card.add_child(route_scroll)
	_route_text = Label.new()
	_route_text.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_route_text.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	TouchLayout.label(_route_text)
	route_scroll.add_child(_route_text)
	_route_card.hide()
	_route_button.toggled.connect(func(open: bool) -> void:
		_route_card.visible = open
		_layout_touch_hud())
	get_viewport().size_changed.connect(_layout_touch_hud)
	_set_objectives(objective.text)
	_layout_touch_hud()


func _layout_touch_hud() -> void:
	if not _touch_hud or not is_instance_valid(_route_card):
		return
	var safe := TouchLayout.safe_rect(get_viewport())
	var columns := [$TopLeft, $TopRight]
	for i in columns.size():
		var column: VBoxContainer = columns[i]
		var width := 150.0
		column.position = Vector2(safe.position.x + 16.0 if i == 0 else safe.end.x - width - 16.0,
			safe.position.y + 13.0)
		column.size = Vector2(width, column.get_combined_minimum_size().y)
		_status_cards[i].position = column.position - Vector2(7, 6)
		_status_cards[i].size = column.size + Vector2(14, 12)
	_route_button.position = Vector2(safe.get_center().x - 74, safe.position.y + 7)
	_route_button.size.x = 148
	var width := clampf(safe.size.x - 354.0, 145.0, 258.0)
	_route_card.position = Vector2(safe.get_center().x - width / 2.0, _route_button.position.y + 44)
	_route_card.size = Vector2(width, minf(148.0, safe.size.y * 0.42))


func _set_objectives(text: String) -> void:
	objective.text = text
	if not _touch_hud or not is_instance_valid(_route_text):
		return
	_route_text.text = text.replace("[ ] ", "• ").replace("[x] ", "✓ ")
	var remaining := text.count("[ ] ")
	_route_button.text = "Objectives · %d" % remaining if remaining else "Objectives"
	_layout_touch_hud.call_deferred()


func _process(delta: float) -> void:
	var player := Net.local_player()
	var lamp := player.get_node_or_null(^"Flashlight") if player else null
	var on := bool(lamp.get("active")) if lamp else false
	light_status.text = "LIGHT ON" if on else "LIGHT OFF"
	light_status.self_modulate = Color("#b9efb3") if on else Color("#b0b4c3")
	_party_cd -= delta
	if _party_cd <= 0.0:
		_party_cd = 0.25
		_refresh_party()
	if _car:
		speed.text = "%d km/h" % roundi(_car.velocity.length() * SPEED_TO_KMH)


## Companion list. Deliberately shows nothing about infection.
func _refresh_party() -> void:
	var lines: Array[String] = []
	for c in get_tree().get_nodes_in_group(&"companions"):
		if c.is_in_party():
			lines.append("%s · %s · %d%%" % [c.display_name, MODE_TEXT.get(int(c.mode), "?"),
				roundi(c.hp / c.max_hp * 100.0)])
	party.text = ("%d survivor%s" % [lines.size(), "" if lines.size() == 1 else "s"]) if _touch_hud else "\n".join(lines)
	party.visible = not lines.is_empty()


func _on_player_damaged(_amount: float, hp: float) -> void:
	var player := Net.local_player()
	if player == null:
		return
	$TopLeft/HPLabel.text = player.display_name()
	player_hp.max_value = player.max_hp
	player_hp.value = hp
	if _dead and hp > 0.0:
		_dead = false
		message.hide()


func _on_player_died() -> void:
	_dead = true
	if _banner_tween:
		_banner_tween.kill()
	message.modulate.a = 1.0
	if MatchState.active:
		message.text = "YOU DIED\nRespawning in %ds" % roundi(MatchState.cfg.respawn_time)
	else:
		message.text = "DOWNED\nA teammate can revive you" if Net.is_online() else "YOU DIED"
	message.visible = true


func _on_noise_level(level: float, max_level: float) -> void:
	noise_bar.max_value = max_level
	noise_bar.value = level
	# The tier can fall without an event, so read it off the director each update.
	var director := get_tree().get_first_node_in_group(&"noise_director")
	var tier: int = clampi(director.tier if director else 0, 0, TIER_NAMES.size() - 1)
	noise_label.text = "NOISE: %s" % TIER_NAMES[tier]
	noise_bar.self_modulate = TIER_COLORS[tier]


func _on_noise_tier(tier: int) -> void:
	_banner(TIER_BANNERS[clampi(tier, 0, TIER_BANNERS.size() - 1)])


func _banner(text: String) -> void:
	if text == "" or _dead:
		return
	if _banner_tween:
		_banner_tween.kill()
	message.text = text
	message.visible = true
	message.modulate.a = 1.0
	_banner_tween = create_tween()
	_banner_tween.tween_interval(1.6)
	_banner_tween.tween_property(message, "modulate:a", 0.0, 0.6)
	_banner_tween.tween_callback(func() -> void: message.visible = false)


func _refresh_weapon() -> void:
	var player := Net.local_player() as Player
	if player == null:
		return
	var weapon := player.weapon
	var id := &"knife" if weapon.knife_equipped else weapon.stats.weapon_id
	_weapon_icon.region = WEAPON_REGIONS.get(id, WEAPON_REGIONS[&"pistol"])
	%WeaponIcon.texture = weapon.stats.pickup_icon if not weapon.knife_equipped and weapon.stats.pickup_icon else _weapon_icon
	weapon_name.text = "Knife" if weapon.knife_equipped else weapon.stats.display_name
	if not weapon.knife_equipped and weapon.gun_slot_count() > 1:
		weapon_name.text = "%d/%d · %s" % [weapon.active_gun_slot(), weapon.gun_slot_count(), weapon_name.text]
	if weapon.knife_equipped:
		ammo.text = "Melee"
	else:
		ammo.text = "Reloading..." if weapon.is_reloading else "%d / %d" % [weapon.in_mag, weapon.reserve]
		if is_zero_approx(weapon.durability):
			ammo.text = "BROKEN"
		elif not weapon.is_reloading and weapon.in_mag + weapon.reserve == 0:
			ammo.text = "OUT OF AMMO"


func _on_entered_car(car: Node2D) -> void:
	_car = car
	controls.text = CAR_CONTROLS
	car_name.text = _car.stats.display_name
	car_panel.visible = true
	_on_car_changed(car)


func _on_exited_car(_c: Node2D) -> void:
	_car = null
	controls.text = FOOT_CONTROLS
	car_panel.visible = false


func _on_car_changed(car: Node2D) -> void:
	if car != _car or _car == null:
		return
	car_hp.max_value = _car.stats.max_hp
	car_hp.value = _car.hp
	fuel.max_value = _car.stats.fuel_capacity
	fuel.value = _car.fuel
	if _car.is_destroyed:
		car_name.text = "%s (WRECKED)" % _car.stats.display_name


func _on_zombie_killed(_type: StringName, _pos: Vector2, by_car: bool) -> void:
	_kills += 1
	kills.text = "Kills: %d" % _kills
	if by_car:
		kills.pivot_offset = kills.size / 2.0
		var t := create_tween()
		kills.scale = Vector2(1.3, 1.3)
		t.tween_property(kills, "scale", Vector2.ONE, 0.15)
