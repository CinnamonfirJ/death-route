extends Location
## Procedural sandbox (dev/testing): road grid, random obstacles, spare cars, a
## fuel-pump job, explosive barrels, a mixed zombie population. The real run maps
## are hand-built MapLocations (hospital/camp/wasteland); this one stays for tests.

const PROPS: Array[String] = [
	"wreck_red_v", "wreck_red_h", "wreck_blue_v", "wreck_blue_h", "wreck_brown_v", "wreck_brown_h",
	"crate_metal", "crate_wood", "barrel_red", "barrel_orange", "tires", "fence", "container",
]

## Map spans -half_size..half_size tiles on each axis.
@export var half_size := Vector2i(40, 40)
@export var road_spacing := 16
@export var road_width := 4
@export var prop_count := 70
@export var barrel_count := 12
@export var spawn_point_spacing := 8
@export var spare_cars: Array[StringName] = [&"muscle_red", &"heavy_orange", &"sports_black", &"armored_black"]
## Keep this radius around the start clear of props and zombies.
@export var safe_radius := 200.0
## Survivors waiting somewhere on the map to be recruited.
@export var survivor_count := 2

@export_group("Starting population")
@export var walkers := 28
@export var latchers := 6
@export var stoppers := 4
@export var brutes := 1

var _rng := RandomNumberGenerator.new()

@onready var pump: HoldTask = $Entities/FuelPumpTask


func _build_world() -> void:
	_rng.randomize()
	_build_ground()
	_scatter_props()
	_scatter_barrels()
	_spawn_spare_cars()
	_build_spawn_points()
	_build_car_spawns()
	_scatter_pickups()
	_spawn_population()


func map_rect() -> Rect2:
	var w := float(half_size.x * TILE)
	var h := float(half_size.y * TILE)
	return Rect2(-w, -h, 2 * w, 2 * h)


func _survivor_spots() -> Array[Vector2]:
	var out: Array[Vector2] = []
	for i in survivor_count:
		var pos := Vector2.ZERO
		for attempt in 100:
			pos = _cell_center(_random_cell(4))
			if not _is_reserved(pos) and pos.length() > 450.0:
				break
		out.append(pos)
	return out


func _is_road(cell: Vector2i) -> bool:
	# Road bands are centered on multiples of road_spacing, so (0,0) is an intersection.
	var half := road_width >> 1
	return posmod(cell.x + half, road_spacing) < road_width \
		or posmod(cell.y + half, road_spacing) < road_width


func _cell_center(cell: Vector2i) -> Vector2:
	return Vector2(cell * TILE) + Vector2(16, 16)


func _random_cell(margin := 2) -> Vector2i:
	return Vector2i(
		_rng.randi_range(-half_size.x + margin, half_size.x - margin - 1),
		_rng.randi_range(-half_size.y + margin, half_size.y - margin - 1))


## Clear of the start area, the pump and the drop.
func _is_reserved(pos: Vector2) -> bool:
	return pos.length() < safe_radius or pos.distance_to(pump.position) < 110.0 \
		or pos.distance_to(extraction.position) < 120.0


## Ground layer is darkened (see scene modulate); roads sit on their own layer at full brightness.
func _build_ground() -> void:
	var ts := Assets.build_tileset("wasteland")
	ground.tile_set = ts
	roads.tile_set = ts
	var tiles := Assets.tileset_tiles("wasteland")
	for x in range(-half_size.x, half_size.x):
		for y in range(-half_size.y, half_size.y):
			var cell := Vector2i(x, y)
			if _is_road(cell):
				roads.set_cell(cell, 0, tiles["road"][0])
			ground.set_cell(cell, 0, tiles["ground"][0])


func _scatter_props() -> void:
	var placed := 0
	var tries := 0
	while placed < prop_count and tries < prop_count * 30:
		tries += 1
		var cell := _random_cell()
		# Mostly off-road; ~1 in 4 road attempts kept as roadblocks to steer around.
		if _is_road(cell) and _rng.randf() > 0.25:
			continue
		var pos := _cell_center(cell)
		if _is_reserved(pos):
			continue
		entities.add_child(make_prop("wasteland", PROPS[_rng.randi() % PROPS.size()], pos))
		placed += 1


func _scatter_barrels() -> void:
	var placed := 0
	while placed < barrel_count:
		var pos := _cell_center(_random_cell(3))
		if _is_reserved(pos):
			continue
		for i in _rng.randi_range(1, 3):
			if placed >= barrel_count:
				break
			spawn(BARREL_SCENE, pos + Vector2(i * 18, _rng.randf_range(-6, 6)))
			placed += 1


func _spawn_spare_cars() -> void:
	var spots: Array[Vector2] = [
		Vector2(0, road_spacing * TILE * 0.5),
		Vector2(road_spacing * TILE * 0.5, 0),
		Vector2(-road_spacing * TILE, -road_spacing * TILE * 0.4),
		Vector2(road_spacing * TILE * 0.6, -road_spacing * TILE),
	]
	for i in mini(spare_cars.size(), spots.size()):
		var car: Car = CAR_SCENE.instantiate()
		car.vehicle_id = spare_cars[i]
		car.position = spots[i]
		car.rotation = _rng.randf_range(-0.4, 0.4) + (PI * 0.5 if i % 2 == 1 else 0.0)
		car.start_hp_ratio = _rng.randf_range(0.5, 1.0)
		car.start_fuel_ratio = _rng.randf_range(0.3, 0.9)
		entities.add_child(car)


func _build_spawn_points() -> void:
	var step := spawn_point_spacing
	for x in range(-half_size.x + 4, half_size.x - 3, step):
		for y in range(-half_size.y + 4, half_size.y - 3, step):
			add_marker(&"zombie_spawn", _cell_center(Vector2i(x, y)))


func _build_car_spawns() -> void:
	var step := road_spacing * TILE
	for gx in range(-2, 3):
		for gy in range(-2, 3):
			if gx == 0 and gy == 0:
				continue
			add_marker(&"car_spawn", Vector2(gx * step, gy * step), (randi() % 4) * PI * 0.5)


func _scatter_pickups() -> void:
	var table := [[Pickup.Kind.SCRAP, 8, 6], [Pickup.Kind.AMMO, 5, 12],
		[Pickup.Kind.FUEL, 3, 40], [Pickup.Kind.MEDKIT, 3, 35]]
	for row in table:
		for i in row[1]:
			var pos := _cell_center(_random_cell(3))
			if not _is_reserved(pos):
				Pickup.drop(entities, row[0], row[2], pos, 0.0)


func _spawn_population() -> void:
	_spawn_kind(WALKER, walkers, false)
	_spawn_kind(LATCHER, latchers, false)
	_spawn_kind(STOPPER, stoppers, true)  # stoppers loiter on roads
	_spawn_kind(BRUTE, brutes, false, 900.0)


func _spawn_kind(scene: PackedScene, count: int, on_road: bool, min_dist := 0.0) -> void:
	var extent := Vector2(half_size * TILE) - Vector2(64, 64)
	var keep_out := maxf(safe_radius + 60.0, min_dist)
	for i in count:
		var pos := Vector2.ZERO
		for attempt in 200:
			pos = Vector2(_rng.randf_range(-extent.x, extent.x), _rng.randf_range(-extent.y, extent.y))
			if pos.length() < keep_out:
				continue
			if on_road and not _is_road(Vector2i((pos / TILE).floor())):
				continue
			break
		spawn(scene, pos)
