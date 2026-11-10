class_name Location
extends Node2D
## Base for every run map. Subclasses only build the world (_build_world) and say
## how big it is (map_rect) and where survivors wait (_survivor_spots). This class
## handles the rest of a delivery run:
##   - jobs: every HoldTask under Entities must be done; objective text + waypoints
##   - the delivery drop unlocks when all jobs are done; driving in ends the run
##   - companions (one at your side + survivors, maybe infected, maybe a rival)
##   - death / success -> RunSummary, navmesh bake, map bounds
##
## Expected scene nodes: Ground, Roads (TileMapLayer), Decals, NavigationRegion2D,
## SpawnPoints, Bounds, Entities/{Player, Car}, NoiseDirector, CarSpawner,
## ExtractionZone, RunSummary, GameCamera, HUD.

const WALKER := preload("res://scenes/zombies/walker.tscn")
const LATCHER := preload("res://scenes/zombies/latcher.tscn")
const STOPPER := preload("res://scenes/zombies/stopper.tscn")
const BRUTE := preload("res://scenes/zombies/brute.tscn")
const CAR_SCENE := preload("res://scenes/car/car.tscn")
const BARREL_SCENE := preload("res://scenes/props/explosive_barrel.tscn")
const COMPANION_SCENE := preload("res://scenes/companions/companion.tscn")
const TILE := 32
## Scrap per healthy survivor delivered / per infected one (the camp has a bad night).
const SURVIVOR_BONUS := 15
const INFECTED_PENALTY := 20

@export var location_id: StringName = &"wasteland"
@export var location_name := "The Wasteland"

@export_group("Companions")
## Start the run with a companion at your side.
@export var starting_companion := true
@export_range(0.0, 1.0) var survivor_infected_chance := 0.4
## Chance each map survivor is secretly a rival courier (at most one per run).
@export_range(0.0, 1.0) var survivor_rival_chance := 0.35

var tasks: Array[HoldTask] = []
var _rival_note := ""
var _player_dead := false

@onready var ground: TileMapLayer = $Ground
@onready var roads: TileMapLayer = $Roads
@onready var entities: Node2D = $Entities
@onready var bounds: StaticBody2D = $Bounds
@onready var nav_region: NavigationRegion2D = $NavigationRegion2D
@onready var spawn_points: Node2D = $SpawnPoints
@onready var extraction: ExtractionZone = $ExtractionZone
@onready var summary: RunSummary = $RunSummary
@onready var player: Player = $Entities/Player
@onready var start_car: Car = $Entities/Car


func _ready() -> void:
	_build_world()
	_build_bounds(map_rect())
	_build_navigation(map_rect())
	if Net.is_online():
		_setup_online()
	else:
		_spawn_dynamic()
		_spawn_companions()  # AI companions are single-player; human allies replace them online
	if GameManager.phase != GameManager.Phase.RUN:
		GameManager.start_run(location_id)  # launched directly from the editor
	EventBus.player_died.connect(_on_player_died)
	extraction.reached.connect(_on_drop_reached)
	_setup_tasks()
	EventBus.hud_message.emit.call_deferred(location_name)


## Online: replicate Entities children; host spawns players + shared actors once
## every peer has built the static map.
func _setup_online() -> void:
	var sp := MultiplayerSpawner.new()
	sp.name = "NetSpawner"
	add_child(sp)
	sp.spawn_path = sp.get_path_to(entities)
	Net.register_spawner(sp)
	if Net.is_host():
		Net.all_peers_ready.connect(_on_all_peers_ready, CONNECT_ONE_SHOT)
	else:
		# Clients don't simulate shared systems; the host's state arrives over the network.
		$NoiseDirector.process_mode = Node.PROCESS_MODE_DISABLED
		$CarSpawner.process_mode = Node.PROCESS_MODE_DISABLED
	Net.scene_ready()


func _on_all_peers_ready() -> void:
	var i := 0
	for id in Net.players:
		if id == 1:
			continue  # the scene's own Player node is the host's handyman
		i += 1
		Net.spawn(entities, "res://scenes/player/player.tscn",
			{"name": "Player_%d" % id, "position": player.position + Vector2(20 * i, 16)})
	_spawn_dynamic()


## Shared actors (zombies, spare cars, loot). Subclasses that defer them override this.
func _spawn_dynamic() -> void:
	pass


func _on_drop_reached() -> void:
	if Net.is_online():
		Net.end_run(true)
	else:
		_finish(true)


## Called on every machine when the host ends an online run.
func finish_networked(success: bool, info: Dictionary) -> void:
	var extra := {}
	var rival_id: int = info.get("rival_id", 0)
	if rival_id != 0:
		var exposed: bool = info.get("exposed", false)
		if Net.local_id() == rival_id:
			if not success:
				EventBus.scrap_collected.emit(40)  # the rival's payday
			elif not exposed:
				EventBus.scrap_collected.emit(10)
		elif exposed:
			EventBus.scrap_collected.emit(15)
		extra["rival"] = "The rival was %s (%s)." % [info.get("rival_name", "?"),
			"exposed" if exposed else "never caught"]
	_finish(success, extra)


# ---------- Subclass hooks ----------

## Build tiles, props, markers; position Player/Car/ExtractionZone.
func _build_world() -> void:
	pass


## The playable area in world pixels (bounds + navmesh outline).
func map_rect() -> Rect2:
	return Rect2(-1280, -1280, 2560, 2560)


## Where recruitable survivors wait.
func _survivor_spots() -> Array[Vector2]:
	return []


# ---------- Jobs + objective ----------

func _setup_tasks() -> void:
	for n in entities.get_children():
		if n is HoldTask:
			tasks.append(n)
			n.completed.connect(_on_task_completed)
			EventBus.waypoint_set.emit.call_deferred(n, "JOB")
	if tasks.is_empty():
		_unlock_drop()
	else:
		_update_objective.call_deferred()


func _on_task_completed(task: HoldTask) -> void:
	EventBus.waypoint_cleared.emit(task)
	if tasks.all(func(t: HoldTask) -> bool: return t.is_completed):
		_unlock_drop()
	else:
		_update_objective()


func _update_objective() -> void:
	var lines: Array[String] = ["Jobs at %s:" % location_name]
	for t in tasks:
		lines.append(("[x] " if t.is_completed else "[ ] ") + t.task_name)
	EventBus.objective_changed.emit("\n".join(lines))


func _unlock_drop() -> void:
	extraction.set_active(true)
	EventBus.waypoint_set.emit(extraction, "DROP")
	EventBus.objective_changed.emit("Jobs done. Drive a car to the delivery drop.")
	if not tasks.is_empty():
		EventBus.hud_message.emit("All jobs done. Get to the drop!")


# ---------- End of run ----------

func _on_player_died() -> void:
	_player_dead = true
	if Net.is_online():
		# Downed, not dead: a teammate can revive. The host ends the run if everyone's down.
		Net.report_down(true)
		return
	await get_tree().create_timer(2.0).timeout
	_finish(false)


func _finish(success: bool, extra_in := {}) -> void:
	var me: Player = Net.local_player()
	var extra := {"survivors": 0, "infected_delivered": 0, "location": String(location_id)}
	extra.merge(extra_in, true)
	if success and me and me.current_car:
		for c in me.current_car.passengers:
			if not is_instance_valid(c):
				continue
			if c.is_rival():
				var brain: RivalBrain = c.rival_brain()
				var cut := brain.delivery_cut()
				EventBus.scrap_collected.emit(-cut)
				_rival_note = "%s was a rival courier. They bolted with %d of your scrap." % [
					c.display_name, brain.stash + cut]
				continue
			if c.infected:
				extra.infected_delivered += 1
				EventBus.scrap_collected.emit(-mini(INFECTED_PENALTY, GameManager.run_scrap))
			else:
				extra.survivors += 1
				EventBus.scrap_collected.emit(SURVIVOR_BONUS)
	if _rival_note != "":
		extra["rival"] = _rival_note
	summary.show_summary(GameManager.end_run(success, me.weapon.durability if me else -1.0, extra))


# ---------- Companions ----------

## One companion at your side, plus survivors to find (some bitten, maybe one rival).
func _spawn_companions() -> void:
	var sprites := [&"npc_companion_a", &"npc_companion_b"]
	if starting_companion:
		var c: Companion = COMPANION_SCENE.instantiate()
		c.character_id = sprites[0]
		c.position = player.position + Vector2(-20, 24)
		entities.add_child(c)
		c.join.call_deferred()
	EventBus.rival_stopped.connect(func(n: String, _s: int) -> void:
		_rival_note = "You exposed a rival courier: %s." % n)
	EventBus.rival_escaped.connect(func(n: String, s: int) -> void:
		_rival_note = "Rival courier %s escaped with %d scrap." % [n, s])
	var rival_assigned := false
	var i := 0
	for pos in _survivor_spots():
		var s: Companion = COMPANION_SCENE.instantiate()
		s.character_id = sprites[(i + 1) % sprites.size()]
		s.start_infected_chance = survivor_infected_chance
		s.position = pos
		if not rival_assigned and randf() < survivor_rival_chance:
			rival_assigned = true
			var brain := RivalBrain.new()
			brain.name = "RivalBrain"
			s.add_child(brain)
		entities.add_child(s)
		EventBus.waypoint_set.emit.call_deferred(s, "SURVIVOR")
		i += 1


# ---------- Shared builders ----------

func _build_bounds(rect: Rect2) -> void:
	var t := 64.0
	for r in [
		Rect2(rect.position.x - t, rect.position.y - t, rect.size.x + 2 * t, t),
		Rect2(rect.position.x - t, rect.end.y, rect.size.x + 2 * t, t),
		Rect2(rect.position.x - t, rect.position.y, t, rect.size.y),
		Rect2(rect.end.x, rect.position.y, t, rect.size.y),
	]:
		var shape := RectangleShape2D.new()
		shape.size = r.size
		var cs := CollisionShape2D.new()
		cs.shape = shape
		cs.position = r.get_center()
		bounds.add_child(cs)


## Bake a navmesh over the map, carving out every static collider in the
## "nav_obstacle" group (props, barrels, tasks, wall TileMapLayers).
func _build_navigation(rect: Rect2) -> void:
	var poly := NavigationPolygon.new()
	poly.agent_radius = 8.0
	poly.parsed_geometry_type = NavigationPolygon.PARSED_GEOMETRY_STATIC_COLLIDERS
	poly.parsed_collision_mask = 1
	poly.source_geometry_mode = NavigationPolygon.SOURCE_GEOMETRY_GROUPS_WITH_CHILDREN
	poly.source_geometry_group_name = &"nav_obstacle"
	poly.add_outline(PackedVector2Array([
		rect.position, Vector2(rect.end.x, rect.position.y), rect.end, Vector2(rect.position.x, rect.end.y)]))
	nav_region.navigation_polygon = poly
	nav_region.bake_navigation_polygon(false)


## Static obstacle from a manifest region: sprite drawn upward from its origin
## (for y-sort), footprint collider at the base.
func make_prop(tileset_id: String, region: String, pos: Vector2, solid := true) -> StaticBody2D:
	var tex := Assets.region_texture(tileset_id, region)
	var size := tex.get_size()
	var body := StaticBody2D.new()
	body.name = "Prop_" + region
	body.position = pos
	body.collision_layer = 1 if solid else 0
	body.collision_mask = 0
	var spr := Sprite2D.new()
	spr.texture = tex
	spr.offset = Vector2(0, -size.y * 0.5 + 6.0)
	body.add_child(spr)
	if solid:
		body.add_to_group(&"nav_obstacle")
		var rect := RectangleShape2D.new()
		rect.size = Vector2(maxf(size.x - 4.0, 8.0), maxf(size.y * 0.55, 8.0))
		var cs := CollisionShape2D.new()
		cs.shape = rect
		cs.position = Vector2(0, 6.0 - rect.size.y * 0.5)
		body.add_child(cs)
	return body


func add_marker(group: StringName, pos: Vector2, rot := 0.0) -> Marker2D:
	var m := Marker2D.new()
	m.position = pos
	m.rotation = rot
	m.add_to_group(group)
	spawn_points.add_child(m)
	return m


func spawn(scene: PackedScene, pos: Vector2) -> Node2D:
	var n: Node2D = scene.instantiate()
	n.position = pos
	entities.add_child(n)
	return n
