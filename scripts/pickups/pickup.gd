class_name Pickup
extends Area2D
## Loot on the ground. Walk over it, or drive over it. Drifts toward a nearby
## player, blinks before despawning.
## Usage: Pickup.drop(parent, Pickup.Kind.SCRAP, 3, global_position)
## Online the host owns pickups: it detects who touched one and Net.grant()s the
## reward on that player's own machine.

## CRATE_* are supply crates: camp market commodities that go into the run haul instead of
## being used on the spot. Appended at the end so saved marker kinds keep their numbers.
enum Kind { SCRAP, AMMO, FUEL, MEDKIT, FLARE_PISTOL, NEEDLE_SMG, CRATE_MEDKIT, CRATE_AMMO, CRATE_BATTERY, CRATE_FOOD }

const FIELD_IDS := {Kind.FLARE_PISTOL: &"flare_pistol", Kind.NEEDLE_SMG: &"needle_smg"}
## Crate kind -> commodity id in economy/pricing_rules.toml.
const CRATE_COMMODITY := {Kind.CRATE_MEDKIT: "medkit", Kind.CRATE_AMMO: "premium_ammo",
	Kind.CRATE_BATTERY: "battery", Kind.CRATE_FOOD: "food_stock"}

const ITEM_FOR_KIND := {
	Kind.SCRAP: "scrap", Kind.AMMO: "ammo_pistol", Kind.FUEL: "fuel_can", Kind.MEDKIT: "medkit",
	Kind.CRATE_MEDKIT: "chest_red", Kind.CRATE_AMMO: "chest_metal", Kind.CRATE_BATTERY: "battery",
	Kind.CRATE_FOOD: "chest_green",
}
const GLOW_FOR_KIND := {
	Kind.SCRAP: Color(1, 0.8, 0.35), Kind.AMMO: Color(0.6, 0.8, 1), Kind.FUEL: Color(1, 0.9, 0.3),
	Kind.MEDKIT: Color(1, 0.4, 0.4), Kind.CRATE_MEDKIT: Color("#e9c46a"), Kind.CRATE_AMMO: Color("#e9c46a"),
	Kind.CRATE_BATTERY: Color("#e9c46a"), Kind.CRATE_FOOD: Color("#e9c46a"),
}
## Loaded lazily: a preload here would be a cyclic reference (the scene uses this script).
const SCENE_PATH := "res://scenes/pickups/pickup.tscn"
const MAGNET_RADIUS := 44.0
const MAGNET_SPEED := 160.0

@export var kind: Kind = Kind.SCRAP
@export var amount := 1
## Seconds before it despawns. 0 = never (hand-placed loot).
@export var lifetime := 0.0
@export var anchored := false
@export var swap_reach := 32.0

var _age := 0.0
var _taken := false

@onready var sprite: AnimatedSprite2D = $AnimatedSprite2D


static func drop(parent: Node, k: Kind, amt: int, pos: Vector2, life := 30.0) -> Pickup:
	var jitter := Vector2(randf_range(-8, 8), randf_range(-8, 8))
	return Net.spawn(parent, SCENE_PATH, {"kind": k, "amount": amt, "lifetime": life,
		"position": pos + jitter}) as Pickup


static func is_crate(k: int) -> bool:
	return CRATE_COMMODITY.has(k)


## Crate kind for a commodity id; a blank or unknown id picks a random crate.
static func crate_kind_for(commodity: String) -> int:
	for k in CRATE_COMMODITY:
		if CRATE_COMMODITY[k] == commodity:
			return k
	return random_crate_kind()


static func random_crate_kind() -> int:
	return CRATE_COMMODITY.keys().pick_random()


## Applies a pickup's effect to `player`. Returns false if it doesn't apply
## (fuel with no car, medkit at full health).
static func apply_to(player: Node, k: int, amt: int) -> bool:
	Sfx.play(&"pickup", player.global_position)
	match k:
		Kind.SCRAP:
			EventBus.scrap_collected.emit(amt)
			float_text(player, "+%d scrap" % amt, Color(1.0, 0.85, 0.4))
		Kind.AMMO:
			player.weapon.add_ammo(amt)
			float_text(player, "+%d ammo" % amt, Color(0.8, 0.9, 1.0))
		Kind.FUEL:
			if player.current_car == null:
				return false
			player.current_car.add_fuel(amt)
			float_text(player, "+%d fuel" % amt, Color(1.0, 0.9, 0.3))
		Kind.MEDKIT:
			if player.hp >= player.max_hp:
				return false
			player.heal(amt)
			float_text(player, "+%d HP" % amt, Color(1.0, 0.45, 0.45))
		Kind.FLARE_PISTOL, Kind.NEEDLE_SMG:
			player.weapon.equip_found(FIELD_IDS[k])
			float_text(player, player.weapon.stats.display_name, Color("#b9eebb"))
		Kind.CRATE_MEDKIT, Kind.CRATE_AMMO, Kind.CRATE_BATTERY, Kind.CRATE_FOOD:
			var id: String = CRATE_COMMODITY[k]
			GameManager.add_run_commodity(id, amt)
			float_text(player, "+%d %s · camp market" % [amt, GameManager.commodity_name(id, amt)], Color("#e9c46a"))
	return true


func _ready() -> void:
	if FIELD_IDS.has(kind):
		collision_layer = 16
		monitorable = true
		monitoring = false
		var config: WeaponStats = load(Weapon.FIELD_WEAPONS[FIELD_IDS[kind]])
		var frames := SpriteFrames.new()
		frames.add_frame(&"default", config.pickup_icon)
		sprite.sprite_frames = frames
		sprite.play(&"default")
		Fx.attach_glow(self, Color(config.tracer_color, 0.35), 0.46, Vector2(0, -6))
		return
	sprite.sprite_frames = Assets.item_frames(ITEM_FOR_KIND[kind])
	sprite.play(&"default")
	body_entered.connect(_on_body_entered)
	Net.attach_sync(self, [".:position"], [])
	var glow_color: Color = GLOW_FOR_KIND[kind]
	Fx.attach_glow(self, Color(glow_color, 0.35), 0.55 if is_crate(kind) else 0.45, Vector2(0, -6), 0.3)


func _physics_process(delta: float) -> void:
	if not Net.is_sim_authority():
		return
	_age += delta
	if lifetime > 0.0:
		if _age > lifetime:
			queue_free()
			return
		if _age > lifetime - 5.0:
			sprite.visible = int(_age * 8.0) % 2 == 0
	if anchored or FIELD_IDS.has(kind):
		return
	for player in Net.player_nodes():
		if player.visible and global_position.distance_to(player.global_position) < MAGNET_RADIUS:
			global_position = global_position.move_toward(player.global_position, MAGNET_SPEED * delta)
			break


func can_interact(player: Node) -> bool:
	return FIELD_IDS.has(kind) and not _taken and player.visible and player.is_on_foot() \
		and global_position.distance_to(player.global_position) <= swap_reach


func get_interact_prompt(player: Node) -> String:
	var config: WeaponStats = load(Weapon.FIELD_WEAPONS[FIELD_IDS[kind]])
	var weapon: Weapon = player.weapon
	if weapon.gun_slot_count() < 2:
		return "[E] Pick up %s · %s" % [config.display_name, config.ammo_name]
	var slot := 2 if weapon.knife_equipped else weapon.active_gun_slot()
	return "[E] Replace gun %d with %s" % [slot, config.display_name]


func interact(player: Node) -> void:
	if Net.is_sim_authority():
		_claim_weapon(player)
	else:
		_rpc_claim_weapon.rpc_id(1)


@rpc("any_peer", "reliable")
func _rpc_claim_weapon() -> void:
	if Net.is_host():
		_claim_weapon(_player_by_id(multiplayer.get_remote_sender_id()))


func _claim_weapon(player: Node) -> void:
	if player == null or not can_interact(player):
		return
	_taken = true
	Net.grant(player.get_multiplayer_authority(), kind, amount)
	queue_free()


func _on_body_entered(body: Node) -> void:
	if _taken or not Net.is_sim_authority():
		return
	var player: Node = null
	if body.is_in_group(&"player") and not body.is_dead() and body.visible:
		player = body
	elif body.is_in_group(&"cars") and body.has_driver():
		player = body.driver if body.driver != null else _player_by_id(body.driver_id)
	if player == null:
		return
	var owner_id: int = player.get_multiplayer_authority() if Net.is_online() else 1
	if owner_id != Net.local_id():
		# Someone else's handyman: hand the reward to their machine.
		if kind == Kind.FUEL and Net.car_of(player) == null:
			return
		Net.grant(owner_id, kind, amount)
	elif not Pickup.apply_to(player, kind, amount):
		return
	_taken = true
	queue_free()


func _player_by_id(id: int) -> Node:
	for p in Net.player_nodes():
		if p.get_multiplayer_authority() == id:
			return p
	return null


static func float_text(at: Node2D, text: String, color: Color) -> void:
	var parent := at.get_parent()
	if parent == null:
		return
	var label := Label.new()
	label.text = text
	label.add_theme_font_size_override(&"font_size", 9)
	label.add_theme_color_override(&"font_color", color)
	label.add_theme_color_override(&"font_outline_color", Color.BLACK)
	label.add_theme_constant_override(&"outline_size", 3)
	label.z_index = 10
	label.position = at.global_position + Vector2(-20, -32)
	parent.add_child(label)
	var t := label.create_tween()
	t.set_parallel(true)
	t.tween_property(label, "position:y", label.position.y - 18.0, 0.8)
	t.tween_property(label, "modulate:a", 0.0, 0.8).set_delay(0.3)
	t.set_parallel(false)
	t.tween_callback(label.queue_free)
