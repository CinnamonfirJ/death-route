class_name Room
extends Location
## A hand-built run room, laid out entirely in the Godot editor (res://rooms/*.tscn).
## Nothing here generates the layout; it only reads what you placed:
##
##   Ground / Roads / Floors   TileMapLayers - paint dirt, road and indoor floor tiles
##   Entities/Walls            TileMapLayer  - paint walls (solid, block zombies' paths)
##   Entities/Props            drag scenes from res://scenes/props/library/ (beds, tents, wrecks...)
##   Entities/Jobs             HoldTask / FuelPumpTask instances - every job must be done
##   Entities/Barrels          explosive_barrel.tscn instances
##   Entities/Player, Car, DeliveryCustomer   move them to set the start + drop-off
##   Markers                   RoomMarker nodes: zombie/car spawns, pizza spots, survivors,
##                             spare cars, starting zombies and pickups (pick `kind`)
##
## The playable area is the rectangle covered by Ground tiles.

@onready var floors: TileMapLayer = $Floors
@onready var walls: TileMapLayer = $Entities/Walls
@onready var markers: Node2D = $Markers

var _survivors: Array[Vector2] = []
var _pizza_spots: Array[Vector2] = []
var _crew_starts: Array[Vector2] = []
## Shared actors: [scene_path, props]. Spawned by _spawn_dynamic()
## (immediately offline; by the host once everyone has loaded, online).
var _dynamic: Array = []
var _field_weapons: Array[Dictionary] = []
var _pool_loot: Dictionary = {}

@export_range(0.0, 1.0) var acid_loot_chance := 0.4


func _build_world() -> void:
	walls.add_to_group(&"nav_obstacle")
	for m in markers.get_children():
		if m is RoomMarker:
			_read_marker(m)


func _read_marker(m: RoomMarker) -> void:
	var pos := m.global_position
	match m.kind:
		RoomMarker.Kind.PIZZA_SPOT:
			_pizza_spots.append(pos)
		RoomMarker.Kind.CREW_START:
			_crew_starts.append(pos)
		RoomMarker.Kind.SURVIVOR:
			_survivors.append(pos)
		RoomMarker.Kind.SPARE_CAR:
			_dynamic.append([CAR_SCENE.resource_path, {"vehicle_id": $CarSpawner._roll_model(),
				"start_hp_ratio": randf_range(0.5, 1.0), "start_fuel_ratio": randf_range(0.3, 0.8),
				"stat_variance": 0.1, "position": pos, "rotation": m.rotation}])
		RoomMarker.Kind.WALKER:
			_dynamic.append([WALKER.resource_path, {"position": pos}])
		RoomMarker.Kind.LATCHER:
			_dynamic.append([LATCHER.resource_path, {"position": pos}])
		RoomMarker.Kind.STOPPER:
			_dynamic.append([STOPPER.resource_path, {"position": pos}])
		RoomMarker.Kind.BRUTE:
			_dynamic.append([BRUTE.resource_path, {"position": pos}])
		RoomMarker.Kind.SCRAP, RoomMarker.Kind.AMMO, RoomMarker.Kind.FUEL, RoomMarker.Kind.MEDKIT, \
				RoomMarker.Kind.FLARE_PISTOL, RoomMarker.Kind.NEEDLE_SMG:
			var k: int = {RoomMarker.Kind.SCRAP: Pickup.Kind.SCRAP, RoomMarker.Kind.AMMO: Pickup.Kind.AMMO,
				RoomMarker.Kind.FUEL: Pickup.Kind.FUEL, RoomMarker.Kind.MEDKIT: Pickup.Kind.MEDKIT,
				RoomMarker.Kind.FLARE_PISTOL: Pickup.Kind.FLARE_PISTOL,
				RoomMarker.Kind.NEEDLE_SMG: Pickup.Kind.NEEDLE_SMG}[m.kind]
			var props := {"kind": k, "amount": m.pickup_amount(),
				"lifetime": 0.0, "position": pos, "anchored": m.anchored}
			if k in [Pickup.Kind.FLARE_PISTOL, Pickup.Kind.NEEDLE_SMG]:
				_field_weapons.append(props)
			else:
				var hazard := _pool_at(pos)
				if hazard:
					if not _pool_loot.has(hazard):
						_pool_loot[hazard] = []
					_pool_loot[hazard].append(props)
				else:
					_dynamic.append([Pickup.SCENE_PATH, props])
		RoomMarker.Kind.CRATE:
			_dynamic.append([Pickup.SCENE_PATH, {"kind": Pickup.crate_kind_for(m.commodity),
				"amount": m.pickup_amount(), "lifetime": 0.0, "position": pos, "anchored": true}])
		_:
			pass  # zombie/car spawns join their groups themselves


func map_rect() -> Rect2:
	var r := ground.get_used_rect()
	return Rect2(Vector2(r.position * TILE), Vector2(r.size * TILE))


func _spawn_dynamic() -> void:
	for entry in _dynamic:
		Net.spawn(entities, entry[0], entry[1])
	for hazard in _pool_loot:
		if randf() < acid_loot_chance:
			var props: Dictionary = _pool_loot[hazard].pick_random()
			Net.spawn(entities, Pickup.SCENE_PATH, props)
	if MatchState.active:
		return  # Versus supplies its own weapons through MatchState.
	var spots := _pizza_spots.duplicate()
	spots.shuffle()
	if _field_weapons.is_empty():
		_field_weapons.assign([{"kind": Pickup.Kind.FLARE_PISTOL}, {"kind": Pickup.Kind.NEEDLE_SMG}])
	for props in _field_weapons:
		props["position"] = _take_route_spot(spots, 95.0)
		props["lifetime"] = 0.0
		props["anchored"] = true
		Net.spawn(entities, Pickup.SCENE_PATH, props)


func _pool_at(point: Vector2) -> Node2D:
	for pool in get_tree().get_nodes_in_group(&"acid_pool"):
		if is_ancestor_of(pool) and pool.contains(point):
			return pool
	return null


func _survivor_spots() -> Array[Vector2]:
	return _survivors


func _pizza_spawn_spots() -> Array[Vector2]:
	return _pizza_spots


func _guest_start(index: int) -> Vector2:
	if index < _crew_starts.size():
		return _crew_starts[index]
	return super._guest_start(index)
