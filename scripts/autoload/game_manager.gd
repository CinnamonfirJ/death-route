extends Node
## Owns run state and persistent meta-progression: currency, upgrade levels,
## weapon loadout + durability, lifetime stats. Saves JSON to user://save_game.save.
##
## Stat keys read by gameplay code through apply_stat():
##   car.max_hp  car.speed  car.ram_mult  car.latch_resist  car.fuel_capacity
##   weapon.damage  weapon.mag_size  weapon.noise
##   player.max_hp  player.noise  player.task_speed  player.ammo_reserve
##   unlock.<thing>  (use is_unlocked)

const DEFAULT_SAVE_PATH := "user://save_game.save"
const SAVE_VERSION := 2
const CATALOG_PATH := "res://resources/upgrades/upgrade_catalog.tres"
const GARAGE_SCENE := "res://scenes/ui/garage.tscn"

## Run destinations. "hidden" ones aren't offered in the Garage (dev/test maps).
const LOCATIONS := {
	&"hospital": {"scene": "res://scenes/locations/hospital.tscn", "name": "St. Mercy Hospital",
		"blurb": "Restore backup power, pack the meds. Tight corridors. Something big in surgery."},
	&"camp": {"scene": "res://scenes/locations/camp.tscn", "name": "Survivor Camp",
		"blurb": "Water pump and radio are down. Half the camp has turned. Deliver to the plaza."},
	&"wasteland": {"scene": "res://scenes/locations/wasteland.tscn", "name": "Route 9 Gas & Junk",
		"blurb": "Fix the station pump, hotwire the junkyard generator, drop at the west depot."},
	&"sandbox": {"scene": "res://scenes/locations/test_drive.tscn", "name": "Test Drive",
		"blurb": "Procedural sandbox.", "hidden": true},
}

const WEAPONS := {
	&"pistol": "res://resources/weapons/pistol.tres",
	&"shotgun": "res://resources/weapons/shotgun.tres",
}
## Weapon -> unlock key. Weapons not listed are always available.
const WEAPON_UNLOCKS := {&"shotgun": &"unlock.shotgun"}
## Scrap to fully repair a weapon from 0% durability.
const FULL_REPAIR_COST := 60

enum Phase { MENU, GARAGE, RUN }

var phase: Phase = Phase.MENU
var save_path := DEFAULT_SAVE_PATH
var catalog: UpgradeCatalog

# --- Persistent (meta) ---
var currency: int = 0
var upgrade_levels: Dictionary = {}       # String id -> int level
var weapon_durability: Dictionary = {}    # String weapon id -> float 0..1
var loadout_weapon: StringName = &"pistol"
var selected_location: StringName = &"wasteland"
var stats := { "runs": 0, "successful_runs": 0, "zombies_killed": 0, "best_run_scrap": 0 }

## Player options (saved). Auto-aim on by default for casual play; hardcore players switch it off.
const DEFAULT_SETTINGS := {
	"auto_aim": true, "auto_run": false, "sfx_volume": 0.8, "screen_shake": 1.0,
}
var settings := DEFAULT_SETTINGS.duplicate()

signal settings_changed


func get_setting(key: String) -> Variant:
	return settings.get(key, DEFAULT_SETTINGS.get(key))


func set_setting(key: String, value: Variant) -> void:
	settings[key] = value
	settings_changed.emit()
	save_game()

# --- Per-run ---
var run_scrap: int = 0
var run_kills: int = 0
## Summary of the last finished run, shown by the Garage. Empty before the first run.
var last_run: Dictionary = {}


func _ready() -> void:
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--save="):
			save_path = arg.trim_prefix("--save=")
	catalog = load(CATALOG_PATH)
	load_game()
	EventBus.scrap_collected.connect(_on_scrap_collected)
	EventBus.zombie_killed.connect(_on_zombie_killed)


# ---------- Scene flow ----------

func goto_garage() -> void:
	phase = Phase.GARAGE
	get_tree().paused = false
	if Net.is_online() or Net.in_match:
		Net.leave()  # each online run ends the session; host again from the lobby
	# Until the Garage scene exists, go straight into another run.
	if ResourceLoader.exists(GARAGE_SCENE):
		get_tree().change_scene_to_file(GARAGE_SCENE)
	else:
		launch_run()


func launch_run() -> void:
	if not LOCATIONS.has(selected_location):
		selected_location = &"wasteland"
	start_run(selected_location)
	get_tree().change_scene_to_file(LOCATIONS[selected_location].scene)


func set_destination(id: StringName) -> void:
	if LOCATIONS.has(id):
		selected_location = id
		save_game()


# ---------- Run lifecycle ----------

func start_run(location_id: StringName) -> void:
	phase = Phase.RUN
	run_scrap = 0
	run_kills = 0
	EventBus.run_started.emit(location_id)


## Banks scrap (half on failure), records stats, saves. Returns the summary.
## `extra` is merged into the summary (e.g. survivors delivered).
func end_run(success: bool, weapon_durability_now := -1.0, extra := {}) -> Dictionary:
	if phase != Phase.RUN:
		return last_run
	var earned := run_scrap if success else floori(run_scrap / 2.0)
	currency += earned
	stats.runs += 1
	stats.zombies_killed += run_kills
	if success:
		stats.successful_runs += 1
	stats.best_run_scrap = maxi(int(stats.best_run_scrap), earned)
	if weapon_durability_now >= 0.0:
		weapon_durability[String(loadout_weapon)] = weapon_durability_now
	last_run = {
		"success": success, "scrap_found": run_scrap, "scrap_banked": earned,
		"kills": run_kills, "weapon": String(loadout_weapon),
		"durability": get_durability(loadout_weapon),
	}
	last_run.merge(extra, true)
	phase = Phase.GARAGE
	EventBus.run_ended.emit(success, earned)
	EventBus.currency_changed.emit(currency)
	save_game()
	return last_run


func _on_scrap_collected(amount: int) -> void:
	run_scrap += amount


func _on_zombie_killed(_type: StringName, _pos: Vector2, _by_car: bool) -> void:
	run_kills += 1


# ---------- Upgrades ----------

func get_upgrade_level(id: StringName) -> int:
	return int(upgrade_levels.get(String(id), 0))


func next_cost(id: StringName) -> int:
	var u := catalog.get_upgrade(id)
	if u == null or get_upgrade_level(id) >= u.max_level:
		return -1
	return u.cost_for_level(get_upgrade_level(id) + 1)


func try_buy(id: StringName) -> bool:
	var cost := next_cost(id)
	if cost < 0 or not try_spend(cost):
		return false
	var level := get_upgrade_level(id) + 1
	upgrade_levels[String(id)] = level
	EventBus.upgrade_purchased.emit(id, level)
	save_game()
	return true


func try_spend(amount: int) -> bool:
	if amount > currency:
		return false
	currency -= amount
	EventBus.currency_changed.emit(currency)
	return true


## Applies every owned upgrade that targets `stat` to `base`.
func apply_stat(stat: StringName, base: float) -> float:
	var value := base
	var add := 0.0
	var mult := 1.0
	for u in catalog.upgrades:
		if u.stat != stat:
			continue
		var level := get_upgrade_level(u.id)
		if level <= 0:
			continue
		match u.mode:
			UpgradeDef.Mode.PERCENT:
				mult += u.per_level * level
			UpgradeDef.Mode.ADD:
				add += u.per_level * level
	value = (value + add) * maxf(mult, 0.05)
	return value


func is_unlocked(key: StringName) -> bool:
	for u in catalog.upgrades:
		if u.stat == key and u.mode == UpgradeDef.Mode.UNLOCK and get_upgrade_level(u.id) > 0:
			return true
	return false


## Returns an upgraded copy; the source resource is never modified.
func upgraded_car_stats(base: CarStats) -> CarStats:
	var s: CarStats = base.duplicate()
	s.max_hp = apply_stat(&"car.max_hp", s.max_hp)
	s.top_speed = apply_stat(&"car.speed", s.top_speed)
	s.acceleration = apply_stat(&"car.speed", s.acceleration)
	s.ram_mult = apply_stat(&"car.ram_mult", s.ram_mult)
	s.latch_resist = clampf(apply_stat(&"car.latch_resist", s.latch_resist), 0.0, 0.9)
	s.fuel_capacity = apply_stat(&"car.fuel_capacity", s.fuel_capacity)
	return s


func upgraded_weapon_stats(base: WeaponStats) -> WeaponStats:
	var s: WeaponStats = base.duplicate()
	s.damage = apply_stat(&"weapon.damage", s.damage)
	s.mag_size = roundi(apply_stat(&"weapon.mag_size", s.mag_size))
	s.noise_per_shot = apply_stat(&"weapon.noise", s.noise_per_shot)
	s.start_reserve = roundi(apply_stat(&"player.ammo_reserve", s.start_reserve))
	return s


# ---------- Weapons: loadout + maintenance ----------

func is_weapon_available(id: StringName) -> bool:
	return not WEAPON_UNLOCKS.has(id) or is_unlocked(WEAPON_UNLOCKS[id])


func set_loadout(id: StringName) -> bool:
	if not WEAPONS.has(id) or not is_weapon_available(id):
		return false
	loadout_weapon = id
	save_game()
	return true


func loadout_stats() -> WeaponStats:
	return load(WEAPONS[loadout_weapon])


func get_durability(id: StringName) -> float:
	return float(weapon_durability.get(String(id), 1.0))


func repair_cost(id: StringName) -> int:
	return ceili((1.0 - get_durability(id)) * FULL_REPAIR_COST)


func repair_weapon(id: StringName) -> bool:
	var cost := repair_cost(id)
	if cost <= 0 or not try_spend(cost):
		return false
	weapon_durability[String(id)] = 1.0
	save_game()
	return true


# ---------- Save / load ----------

func save_game() -> void:
	var data := {
		"version": SAVE_VERSION,
		"currency": currency,
		"upgrade_levels": upgrade_levels,
		"weapon_durability": weapon_durability,
		"loadout_weapon": String(loadout_weapon),
		"selected_location": String(selected_location),
		"stats": stats,
		"last_run": last_run,
		"settings": settings,
	}
	# Write to a temp file, then swap it in, so a crash mid-write can't corrupt the save.
	var tmp := save_path + ".tmp"
	var f := FileAccess.open(tmp, FileAccess.WRITE)
	if f == null:
		push_error("Save failed: %s" % error_string(FileAccess.get_open_error()))
		return
	f.store_string(JSON.stringify(data, "\t"))
	f.close()
	var err := DirAccess.rename_absolute(tmp, save_path)
	if err != OK:
		push_error("Save rename failed: %s" % error_string(err))


func load_game() -> void:
	if not FileAccess.file_exists(save_path):
		return
	var f := FileAccess.open(save_path, FileAccess.READ)
	if f == null:
		push_error("Load failed: %s" % error_string(FileAccess.get_open_error()))
		return
	var text := f.get_as_text()
	var data = JSON.parse_string(text) if not text.strip_edges().is_empty() else null
	if typeof(data) != TYPE_DICTIONARY:
		push_warning("Save file corrupt; starting fresh.")
		return
	currency = int(data.get("currency", 0))
	upgrade_levels = data.get("upgrade_levels", {})
	weapon_durability = data.get("weapon_durability", {})
	loadout_weapon = StringName(data.get("loadout_weapon", "pistol"))
	if not is_weapon_available(loadout_weapon):
		loadout_weapon = &"pistol"
	selected_location = StringName(data.get("selected_location", "wasteland"))
	if not LOCATIONS.has(selected_location):
		selected_location = &"wasteland"
	stats.merge(data.get("stats", {}), true)
	last_run = data.get("last_run", {})
	settings = DEFAULT_SETTINGS.duplicate()
	settings.merge(data.get("settings", {}), true)


func reset_save() -> void:
	currency = 0
	upgrade_levels.clear()
	weapon_durability.clear()
	loadout_weapon = &"pistol"
	selected_location = &"wasteland"
	stats = { "runs": 0, "successful_runs": 0, "zombies_killed": 0, "best_run_scrap": 0 }
	last_run = {}
	settings = DEFAULT_SETTINGS.duplicate()
	save_game()
