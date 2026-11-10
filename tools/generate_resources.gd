extends SceneTree
## Seeds the .tres resources for upgrades, the upgrade catalog, and per-vehicle CarStats.
## Run:  godot --headless --path . -s res://tools/generate_resources.gd
## Existing files are left alone (pass -- --force to overwrite), so editor tuning is safe.

const U := preload("res://scripts/meta/upgrade_def.gd")

# id, name, description, category, icon item, stat, mode, per_level, max_level, base_cost
const UPGRADES := [
	# --- Vehicle ---
	["reinforced_bumper", "Reinforced Bumper", "Steel ram plate bolted to the front. More ram damage.",
		U.Category.VEHICLE, "steel", "car.ram_mult", U.Mode.PERCENT, 0.25, 3, 40],
	["tuned_engine", "Tuned Engine", "Higher top speed and acceleration.",
		U.Category.VEHICLE, "repair_tools", "car.speed", U.Mode.PERCENT, 0.08, 3, 50],
	["armored_glass", "Armored Glass", "Latchers can't chew through as fast.",
		U.Category.VEHICLE, "armor_vest", "car.latch_resist", U.Mode.ADD, 0.15, 3, 45],
	["reinforced_chassis", "Reinforced Chassis", "More car HP.",
		U.Category.VEHICLE, "chest_metal", "car.max_hp", U.Mode.PERCENT, 0.15, 3, 45],
	["long_range_tank", "Long-Range Tank", "Bigger fuel tank.",
		U.Category.VEHICLE, "fuel_can", "car.fuel_capacity", U.Mode.PERCENT, 0.25, 2, 35],
	# --- Weapons ---
	["shotgun_license", "Pump Shotgun", "Unlocks the shotgun for your loadout. Loud, brutal up close.",
		U.Category.WEAPONS, "ammo_shotgun", "unlock.shotgun", U.Mode.UNLOCK, 1.0, 1, 120],
	["hollow_points", "Hollow Points", "More damage per bullet.",
		U.Category.WEAPONS, "ammo_pistol", "weapon.damage", U.Mode.PERCENT, 0.15, 3, 45],
	["extended_mags", "Extended Mags", "Bigger magazines.",
		U.Category.WEAPONS, "ammo_rifle", "weapon.mag_size", U.Mode.PERCENT, 0.25, 2, 40],
	["muffled_barrel", "Muffled Barrel", "Shots make less noise.",
		U.Category.WEAPONS, "ammo_sniper", "weapon.noise", U.Mode.PERCENT, -0.15, 3, 50],
	# --- Handyman ---
	["quick_hands", "Quick Hands", "Finish repairs and jobs faster.",
		U.Category.HANDYMAN, "repair_tools", "player.task_speed", U.Mode.PERCENT, 0.2, 3, 40],
	["soft_soles", "Soft Soles", "Quieter movement: sprinting and working make less noise.",
		U.Category.HANDYMAN, "backpack", "player.noise", U.Mode.PERCENT, -0.15, 3, 40],
	["big_pockets", "Big Pockets", "Larger inventory: carry more spare ammo.",
		U.Category.HANDYMAN, "military_bag", "player.ammo_reserve", U.Mode.PERCENT, 0.5, 2, 35],
	["thick_overalls", "Thick Overalls", "More health.",
		U.Category.HANDYMAN, "medkit", "player.max_hp", U.Mode.ADD, 20.0, 2, 50],
]


func _initialize() -> void:
	_generate.call_deferred()


func _generate() -> void:
	var force := OS.get_cmdline_user_args().has("--force")
	DirAccess.make_dir_recursive_absolute("res://resources/upgrades")
	DirAccess.make_dir_recursive_absolute("res://resources/cars")

	var catalog := UpgradeCatalog.new()
	for row in UPGRADES:
		var path := "res://resources/upgrades/%s.tres" % row[0]
		var u: UpgradeDef
		if ResourceLoader.exists(path) and not force:
			u = load(path)
		else:
			u = UpgradeDef.new()
			u.id = StringName(row[0])
			u.display_name = row[1]
			u.description = row[2]
			u.category = row[3]
			u.icon_item = row[4]
			u.stat = StringName(row[5])
			u.mode = row[6]
			u.per_level = row[7]
			u.max_level = row[8]
			u.base_cost = row[9]
			_save(u, path)
			u = load(path)  # reload so the catalog references the file, not an embedded copy
		catalog.upgrades.append(u)
	_save(catalog, "res://resources/upgrades/upgrade_catalog.tres")

	var assets = root.get_node("Assets")
	for id in assets.vehicle_ids():
		var path := "res://resources/cars/%s.tres" % id
		if ResourceLoader.exists(path) and not force:
			continue
		_save(assets.car_stats(StringName(id)), path)
	quit()


func _save(res: Resource, path: String) -> void:
	var err := ResourceSaver.save(res, path)
	print(("saved " if err == OK else "FAILED (%d) " % err) + path)
