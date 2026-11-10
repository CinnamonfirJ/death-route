extends CanvasLayer
## Prototype HUD: player HP, car HP/fuel/speed while driving, interact prompt, kills.
## Phase 4 reskins this with the pack's UI sheets.

## px/s -> displayed km/h. 330 px/s (starter top speed) reads ~120 km/h.
const SPEED_TO_KMH := 0.36

var _car: Car
var _kills := 0

@onready var player_hp: ProgressBar = %PlayerHP
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
@onready var objective: Label = %Objective
@onready var scrap_label: Label = %Scrap
@onready var party: Label = %Party

const MODE_TEXT := {1: "following", 2: "waiting", 3: "in the car"}
var _party_cd := 0.0

const TIER_NAMES := ["QUIET", "HEARD", "HUNTED", "SWARMED", "HORDE"]
const TIER_COLORS := [Color(0.6, 0.85, 1), Color(1, 0.9, 0.4), Color(1, 0.65, 0.25), Color(1, 0.4, 0.3), Color(0.9, 0.1, 0.1)]
const TIER_BANNERS := ["", "Something heard that.", "They're coming.", "That was LOUD.", "THE HORDE IS HERE"]

var _banner_tween: Tween
var _dead := false


func _ready() -> void:
	EventBus.noise_level_changed.connect(_on_noise_level)
	EventBus.noise_threshold_reached.connect(_on_noise_tier)
	EventBus.ammo_changed.connect(_on_ammo)
	EventBus.objective_changed.connect(func(t: String) -> void: objective.text = t)
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
	EventBus.interact_prompt_changed.connect(func(t: String) -> void: prompt.text = t)
	EventBus.zombie_killed.connect(_on_zombie_killed)


func _process(delta: float) -> void:
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
	party.text = "\n".join(lines)
	party.visible = not lines.is_empty()


func _on_player_damaged(_amount: float, hp: float) -> void:
	var player := Net.local_player()
	if player:
		player_hp.max_value = player.max_hp
	player_hp.value = hp


func _on_player_died() -> void:
	_dead = true
	if _banner_tween:
		_banner_tween.kill()
	message.modulate.a = 1.0
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


func _on_ammo(in_mag: int, reserve: int, reloading: bool) -> void:
	ammo.text = "RELOADING..." if reloading else "%d / %d" % [in_mag, reserve]


func _on_entered_car(car: Node2D) -> void:
	_car = car
	car_name.text = _car.stats.display_name
	car_panel.visible = true
	_on_car_changed(car)


func _on_exited_car(_c: Node2D) -> void:
	_car = null
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
