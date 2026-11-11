class_name MapLocation
extends Location
## A hand-built run map, authored as ASCII in res://levels/<name>.txt.
## One character = one 32px cell. Edit the .txt in any text editor.
##
## Terrain:  .  ground (dirt)      =  road        ,  interior floor     #  wall (solid)
## Markers:  P  player start       C  your car    V  spare car (scavenged, 50-100% HP)
##           X  customer           K  car respawn point                 S  zombie spawn point
##           ?  possible pizza spawn (one is chosen per run)
##           H  survivor           B  explosive barrel
##           w  walker   l  latcher   o  stopper   R  brute
##           $  scrap    a  ammo      f  fuel      +  medkit
## Jobs and props: per-location legends below (LEGENDS[legend_id]).
## Markers and props sit on whatever terrain surrounds them.

const HOLD_TASK := preload("res://scenes/tasks/hold_task.tscn")
const FUEL_PUMP_TASK := preload("res://scenes/tasks/fuel_pump_task.tscn")

## props: char -> [tileset_id, region]. tasks: char -> job definition.
const LEGENDS := {
	"hospital": {
		"props": {
			"b": ["hospital", "bed_a"], "n": ["hospital", "bed_b"], "e": ["hospital", "bed_c"],
			"g": ["hospital", "gurney_bloody"], "c": ["hospital", "surgery_curtain"],
			"v": ["hospital", "vending_soda"], "m": ["hospital", "vending_snack"], "k": ["hospital", "coffee_machine"],
			"d": ["hospital", "desk_computer"], "p": ["hospital", "desk_papers"], "L": ["hospital", "lockers"],
			"r": ["hospital", "fridge"], "F": ["hospital", "fridge_double"], "q": ["hospital", "supply_shelf"],
			"y": ["hospital", "water_cooler"], "j": ["hospital", "shelving"], "i": ["hospital", "file_cabinet"],
			"W": ["wasteland", "wreck_red_h"], "E": ["wasteland", "wreck_blue_h"], "Q": ["wasteland", "wreck_brown_v"],
			"x": ["wasteland", "crate_wood"], "M": ["wasteland", "crate_metal"], "t": ["wasteland", "tires"],
			"G": ["wasteland", "container"],
		},
		"tasks": {
			"T": {"name": "Restore backup power", "tileset": "hospital", "region": "radio_desk",
				"duration": 7.0, "noise": 6.0, "scrap": 25},
			"U": {"name": "Pack medical supplies", "tileset": "hospital", "region": "med_cabinet",
				"duration": 5.0, "noise": 3.0, "scrap": 30},
		},
	},
	"camp": {
		"props": {
			"n": ["camp", "tent_tan"], "b": ["camp", "tent_box"], "g": ["camp", "tent_green"],
			"G": ["camp", "tent_green_box"], "h": ["camp", "shack_barrels"], "j": ["camp", "shack_a"],
			"k": ["camp", "shack_b"], "p": ["camp", "pallet"], "x": ["camp", "boxes"], "y": ["camp", "barrels_grey"],
			"O": ["camp", "barrel_oil"], "F": ["camp", "fence_wood"], "Z": ["camp", "fence_chain_sign"],
			"r": ["camp", "fence_rail"], "L": ["camp", "palisade"], "d": ["camp", "table_food"],
			"e": ["camp", "table_trade"], "i": ["camp", "fire_barrel"], "Y": ["camp", "flag_tires"],
			"u": ["camp", "sign_keep_out"], "q": ["camp", "sign_quarantine"], "z": ["camp", "sign_safe"],
			"m": ["camp", "planter_long"],
			"W": ["wasteland", "wreck_red_h"], "E": ["wasteland", "wreck_blue_h"], "Q": ["wasteland", "wreck_brown_v"],
			"t": ["wasteland", "tires"],
		},
		"tasks": {
			"T": {"name": "Fix the water pump", "tileset": "camp", "region": "water_tower",
				"duration": 7.0, "noise": 6.0, "scrap": 25},
			"U": {"name": "Repair the camp radio", "tileset": "hospital", "region": "radio_desk",
				"duration": 6.0, "noise": 4.0, "scrap": 25},
		},
	},
	"wasteland": {
		"props": {
			"W": ["wasteland", "wreck_red_h"], "v": ["wasteland", "wreck_red_v"], "E": ["wasteland", "wreck_blue_h"],
			"e": ["wasteland", "wreck_blue_v"], "Q": ["wasteland", "wreck_brown_v"], "q": ["wasteland", "wreck_brown_h"],
			"x": ["wasteland", "crate_wood"], "M": ["wasteland", "crate_metal"], "y": ["wasteland", "barrel_red"],
			"O": ["wasteland", "barrel_orange"], "t": ["wasteland", "tires"], "F": ["wasteland", "fence"],
			"G": ["wasteland", "container"], "g": ["wasteland", "pump_working"],
		},
		"tasks": {
			"T": {"name": "Repair fuel pump", "fuel_pump": true, "duration": 6.0, "noise": 5.0, "scrap": 30},
			"U": {"name": "Hotwire the generator", "tileset": "wasteland", "region": "container",
				"duration": 7.0, "noise": 8.0, "scrap": 25},
		},
	},
}

const TERRAIN := ".=,#"
const PICKUPS := {"$": [Pickup.Kind.SCRAP, 6], "a": [Pickup.Kind.AMMO, 12],
	"f": [Pickup.Kind.FUEL, 40], "+": [Pickup.Kind.MEDKIT, 35]}

@export_file("*.txt") var map_file := ""
@export var legend_id := "hospital"

var size := Vector2i.ZERO
var _rows: PackedStringArray = []
var _survivors: Array[Vector2] = []
var _pizza_spots: Array[Vector2] = []
## Shared actors found while parsing: [scene_path, props]. Spawned by _spawn_dynamic()
## (immediately offline; by the host once everyone has loaded, online).
var _dynamic: Array = []

@onready var floors: TileMapLayer = $Floors
@onready var walls: TileMapLayer = $Entities/Walls


func _build_world() -> void:
	_load_map()
	var outdoor := Assets.build_tileset("wasteland")
	var indoor := Assets.build_tileset("hospital")
	ground.tile_set = outdoor
	roads.tile_set = outdoor
	floors.tile_set = indoor
	walls.tile_set = indoor
	walls.add_to_group(&"nav_obstacle")
	var out_tiles := Assets.tileset_tiles("wasteland")
	var in_tiles := Assets.tileset_tiles("hospital")
	var legend: Dictionary = LEGENDS[legend_id]
	for y in size.y:
		for x in size.x:
			var cell := Vector2i(x, y)
			var ch := char_at(cell)
			var base := ch if ch in TERRAIN else _surrounding_terrain(cell)
			ground.set_cell(cell, 0, out_tiles["ground"][0])
			match base:
				"=":
					roads.set_cell(cell, 0, out_tiles["road"][0])
				",":
					floors.set_cell(cell, 0, in_tiles["floor"][0])
				"#":
					floors.set_cell(cell, 0, in_tiles["floor"][0])
					walls.set_cell(cell, 0, in_tiles["wall"][0])
			if not ch in TERRAIN:
				_place(ch, cell, legend)


func map_rect() -> Rect2:
	return Rect2(Vector2.ZERO, Vector2(size * TILE))


func _spawn_dynamic() -> void:
	for entry in _dynamic:
		Net.spawn(entities, entry[0], entry[1])


func _survivor_spots() -> Array[Vector2]:
	return _survivors


func _pizza_spawn_spots() -> Array[Vector2]:
	return _pizza_spots


func _load_map() -> void:
	var text := FileAccess.get_file_as_string(map_file)
	if text.is_empty():
		push_error("MapLocation: can't read %s" % map_file)
	for line in text.replace("\r", "").split("\n"):
		_rows.append(line)
	while not _rows.is_empty() and _rows[_rows.size() - 1].strip_edges() == "":
		_rows.remove_at(_rows.size() - 1)
	var w := 0
	for r in _rows:
		w = maxi(w, r.length())
	size = Vector2i(w, _rows.size())


## Character at a cell; short lines are padded with ground.
func char_at(cell: Vector2i) -> String:
	if cell.y < 0 or cell.y >= _rows.size():
		return "."
	var row: String = _rows[cell.y]
	return row[cell.x] if cell.x >= 0 and cell.x < row.length() else "."


## Terrain under a marker/prop: the most common walkable terrain among its neighbours.
func _surrounding_terrain(cell: Vector2i) -> String:
	var counts := {".": 0, "=": 0, ",": 0}
	for dy in range(-1, 2):
		for dx in range(-1, 2):
			var c := char_at(cell + Vector2i(dx, dy))
			if counts.has(c):
				counts[c] += 1
	var best := "."
	for k in [",", "=", "."]:  # ties favour floor, then road
		if counts[k] > counts[best]:
			best = k
	return best


func cell_center(cell: Vector2i) -> Vector2:
	return Vector2(cell * TILE) + Vector2(16, 16)


func _place(ch: String, cell: Vector2i, legend: Dictionary) -> void:
	var center := cell_center(cell)
	var foot := center + Vector2(0, 6)  # props/characters stand near the cell's bottom
	match ch:
		"P":
			player.position = foot
		"C":
			start_car.position = center
			start_car.rotation = 0.0
		"V":
			_dynamic.append([CAR_SCENE.resource_path, {"vehicle_id": $CarSpawner._roll_model(),
				"start_hp_ratio": randf_range(0.5, 1.0), "start_fuel_ratio": randf_range(0.3, 0.8),
				"stat_variance": 0.1, "position": center}])
		"X":
			customer.position = foot
		"?":
			_pizza_spots.append(center)
		"K":
			add_marker(&"car_spawn", center)
		"S":
			add_marker(&"zombie_spawn", center)
		"H":
			_survivors.append(foot)
		"B":
			var b := spawn(BARREL_SCENE, foot)
			b.name = "Barrel_%d_%d" % [cell.x, cell.y]  # same name on every peer
		"w":
			_dynamic.append([WALKER.resource_path, {"position": foot}])
		"l":
			_dynamic.append([LATCHER.resource_path, {"position": foot}])
		"o":
			_dynamic.append([STOPPER.resource_path, {"position": foot}])
		"R":
			_dynamic.append([BRUTE.resource_path, {"position": foot}])
		_:
			if PICKUPS.has(ch):
				_dynamic.append([Pickup.SCENE_PATH, {"kind": PICKUPS[ch][0], "amount": PICKUPS[ch][1],
					"lifetime": 0.0, "position": center}])
			elif legend.tasks.has(ch):
				var t := _make_task(legend.tasks[ch], foot)
				t.name = "Task_%d_%d" % [cell.x, cell.y]
				entities.add_child(t)
			elif legend.props.has(ch):
				var p: Array = legend.props[ch]
				entities.add_child(make_prop(p[0], p[1], foot))
			else:
				push_warning("%s: unknown map char '%s' at %s" % [map_file, ch, cell])


func _make_task(def: Dictionary, pos: Vector2) -> HoldTask:
	var t: HoldTask
	if def.get("fuel_pump", false):
		t = FUEL_PUMP_TASK.instantiate()
	else:
		t = HOLD_TASK.instantiate()
		t.tileset_id = def.tileset
		t.broken_region = def.region
	t.task_name = def.name
	t.duration = def.get("duration", 6.0)
	t.noise_per_sec = def.get("noise", 5.0)
	t.reward_scrap = def.get("scrap", 25)
	t.position = pos
	return t
