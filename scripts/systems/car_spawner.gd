class_name CarSpawner
extends Node
## When the car the player last drove is destroyed, a scavenged car appears at a
## designated spawn point (Marker2D in group "car_spawn") after respawn_delay.
## It rolls a random model (weighted by rarity), 50-100% HP, partial fuel, and
## base stats varied by +/- stat_variance.

const CAR_SCENE := preload("res://scenes/car/car.tscn")

@export var respawn_delay := 15.0
@export var hp_range := Vector2(0.5, 1.0)
@export var fuel_range := Vector2(0.35, 0.8)
@export_range(0.0, 0.5) var stat_variance := 0.1
## Spawn points closer than this to the player are skipped (no popping in).
@export var min_player_distance := 300.0
## Model weights by manifest class; rarer classes appear less.
@export var class_weights := {
	"starter": 6, "civilian": 10, "muscle": 6, "sports": 3, "heavy": 4, "armored": 2, "military": 1,
}
@export var spawn_parent: Node
## The car the run starts with (counts as the player's even before they get in).
@export var starting_car: Node2D

var _player_car: Node2D = null
var _pending := false


func _ready() -> void:
	_player_car = starting_car
	EventBus.player_entered_car.connect(func(car: Node2D) -> void: _player_car = car)
	EventBus.car_destroyed.connect(_on_car_destroyed)


func _on_car_destroyed(car: Node2D) -> void:
	if not Net.is_sim_authority():
		return  # the host handles respawns
	# Online any wrecked car counts (it was somebody's ride).
	if _pending or (car != _player_car and not Net.is_online()):
		return
	_pending = true
	Net.announce("That ride is toast. Another car in %ds..." % roundi(respawn_delay))
	await get_tree().create_timer(respawn_delay, false).timeout
	_pending = false
	spawn_car()


## Spawns one scavenged car now. Returns it (or null if no valid spawn point).
func spawn_car() -> Car:
	var point := _pick_point()
	if point == null:
		push_warning("CarSpawner: no car_spawn markers")
		return null
	var car: Car = Net.spawn(spawn_parent if spawn_parent else get_parent(), CAR_SCENE.resource_path, {
		"vehicle_id": _roll_model(),
		"start_hp_ratio": randf_range(hp_range.x, hp_range.y),
		"start_fuel_ratio": randf_range(fuel_range.x, fuel_range.y),
		"stat_variance": stat_variance,
		"position": point.global_position,
		"rotation": point.global_rotation,
	})
	Net.announce("A %s has turned up. Go get it." % car.stats.display_name)
	EventBus.waypoint_set.emit(car, "CAR")
	var clear := func(_c: Node2D) -> void: EventBus.waypoint_cleared.emit(car)
	EventBus.player_entered_car.connect(clear, CONNECT_ONE_SHOT)
	return car


## Nearest marker that's at least min_player_distance from every player.
func _pick_point() -> Node2D:
	var best: Node2D = null
	var best_d := INF
	for m in get_tree().get_nodes_in_group(&"car_spawn"):
		var d := INF
		for p in Net.player_nodes():
			d = minf(d, m.global_position.distance_to(p.global_position))
		if d == INF:
			d = 0.0
		if d < min_player_distance:
			continue
		if d < best_d:
			best_d = d
			best = m
	return best


func _roll_model() -> StringName:
	var ids := Assets.vehicle_ids()
	var total := 0
	var weights: Array[int] = []
	for id in ids:
		var w := int(class_weights.get(Assets.vehicle(id).get("class", "civilian"), 5))
		weights.append(w)
		total += w
	var roll := randi() % total
	for i in ids.size():
		roll -= weights[i]
		if roll < 0:
			return StringName(ids[i])
	return StringName(ids[0])
