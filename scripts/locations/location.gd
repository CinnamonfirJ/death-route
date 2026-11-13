class_name Location
extends Node2D
## Base for every run map. Subclasses only build the world (_build_world) and say
## how big it is (map_rect) and where survivors wait (_survivor_spots). This class
## handles the rest of a delivery run:
##   - jobs: every HoldTask under Entities must be done; objective text + waypoints
##   - find the pizza, hand it to the customer, and finish jobs to clear the route
##   - companions (one at your side + survivors, maybe infected, maybe a rival)
##   - death / success -> RunSummary, navmesh bake, map bounds
##
## Expected scene nodes: Ground, Roads (TileMapLayer), Decals, NavigationRegion2D,
## SpawnPoints, Bounds, Entities/{Player, Car, DeliveryCustomer}, NoiseDirector,
## CarSpawner, RunSummary, GameCamera, HUD.

const WALKER := preload("res://scenes/zombies/walker.tscn")
const LATCHER := preload("res://scenes/zombies/latcher.tscn")
const STOPPER := preload("res://scenes/zombies/stopper.tscn")
const BRUTE := preload("res://scenes/zombies/brute.tscn")
const CAR_SCENE := preload("res://scenes/car/car.tscn")
const BARREL_SCENE := preload("res://scenes/props/explosive_barrel.tscn")
const COMPANION_SCENE := preload("res://scenes/companions/companion.tscn")
const CUSTOMER_SCENE := preload("res://scenes/locations/delivery_customer.tscn")
const PIZZA_SHOP := preload("res://scripts/locations/pizza_shop.gd")
const PIZZA_SCENE := preload("res://scenes/pickups/pizza_cargo.tscn")
const TILE := 32
## Scrap per healthy survivor delivered / per infected one (the camp has a bad night).
const SURVIVOR_BONUS := 15
const INFECTED_PENALTY := 20
## Camp-market supply crates placed at decoy pizza spots each run.
const CRATES_PER_RUN := 3

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
var _delivered_survivors: Array[Companion] = []
@export_group("Delivery route")
@export var depot_position := Vector2.ZERO
@export var extra_customer_positions: Array[Vector2] = []
@export var job_discovery_radius := 260.0
@export var job_spacing := 125.0

var pizza: PizzaCargo
var pizzas: Array[PizzaCargo] = []
var _depot: StaticBody2D
var _known_jobs: Array[HoldTask] = []
var _layout_ready := false
var _reserved_spots: Array[Vector2] = []

@onready var ground: TileMapLayer = $Ground
@onready var roads: TileMapLayer = $Roads
@onready var entities: Node2D = $Entities
@onready var bounds: StaticBody2D = $Bounds
@onready var nav_region: NavigationRegion2D = $NavigationRegion2D
@onready var spawn_points: Node2D = $SpawnPoints
@onready var customer: DeliveryCustomer = $Entities/DeliveryCustomer
@onready var summary: RunSummary = $RunSummary
@onready var player: Player = $Entities/Player
@onready var start_car: Car = $Entities/Car


func _ready() -> void:
	_build_world()
	var dirt: ShaderMaterial = load("res://assets/tilesets/dirt_material.tres")
	ground.material = dirt
	var road: ShaderMaterial = dirt.duplicate()
	road.set_shader_parameter(&"road_surface", true)
	roads.material = road
	if not Net.is_versus():
		_depot = PIZZA_SHOP.new()
		_depot.name = "PizzaCo"
		_depot.route = self
		_depot.position = depot_position if depot_position != Vector2.ZERO else player.position + Vector2(-120, 20)
		entities.add_child(_depot)
	_build_bounds(map_rect())
	_build_navigation(map_rect())
	var camera := get_node_or_null(^"GameCamera") as GameCamera
	if camera:
		camera.set_play_bounds(map_rect())
	pizza = _add_order(customer, 1)
	if not Net.is_versus():
		for i in extra_customer_positions.size():
			var stop: DeliveryCustomer = CUSTOMER_SCENE.instantiate()
			stop.name = "DeliveryCustomer_%d" % (i + 2)
			stop.position = extra_customer_positions[i]
			entities.add_child(stop)
			_add_order(stop, i + 2)
	if Net.is_versus():
		# Versus: every team gets its own pizza + drop-off (MatchState); the shared ones sit out.
		MatchState.begin(self)
		customer.pizza = null
		customer.visible = false
		customer.process_mode = Node.PROCESS_MODE_DISABLED
		pizza.visible = false
		pizza.process_mode = Node.PROCESS_MODE_DISABLED
		$NoiseDirector.wave_size_mult *= MatchState.cfg.versus_wave_mult
	var lighting := RoomLighting.new()
	lighting.name = "RoomLighting"
	add_child(lighting)
	lighting.configure(self)
	if GameManager.phase != GameManager.Phase.RUN:
		GameManager.start_run(location_id)  # launched directly from the editor
	EventBus.player_died.connect(_on_player_died)
	_setup_tasks()
	if Net.is_online():
		_setup_online()
	else:
		_start_delivery_layout()
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
	if MatchState.active:
		await MatchState.host_setup()
		player.global_position = MatchState.spawn_point(1)
	var i := 0
	for id in Net.players:
		if id == 1:
			continue  # the scene's own Player node is the host's handyman
		Net.spawn(entities, "res://scenes/player/player.tscn",
			{"name": "Player_%d" % id,
				"position": MatchState.spawn_point(id) if MatchState.active else _guest_start(i),
				"character_id": Net.peer_character(id)})
		i += 1
	if MatchState.active:
		_spawn_dynamic()
	else:
		_start_delivery_layout()


func _exit_tree() -> void:
	if MatchState.location == self:
		MatchState.end()


func _guest_start(index: int) -> Vector2:
	return player.position + Vector2(20 * (index + 1), 16)


## Shared actors (zombies, spare cars, loot). Subclasses that defer them override this.
func _spawn_dynamic() -> void:
	pass


func can_finish_route() -> bool:
	return _layout_ready and not MatchState.active and GameManager.phase == GameManager.Phase.RUN \
		and pizzas.all(func(order: PizzaCargo) -> bool: return order.delivered) \
		and tasks.all(func(t: HoldTask) -> bool: return t.is_completed)


func request_checkout(courier: Player) -> void:
	if Net.is_sim_authority():
		_checkout(courier)
	else:
		_rpc_checkout.rpc_id(1)


@rpc("any_peer", "reliable")
func _rpc_checkout() -> void:
	var peer := multiplayer.get_remote_sender_id()
	for courier: Player in Net.player_nodes():
		if courier.get_multiplayer_authority() == peer:
			_checkout(courier)
			return


func _checkout(courier: Player) -> void:
	if not Net.is_sim_authority() or not can_finish_route() or not _depot.can_interact(courier):
		return
	if Net.is_online():
		Net.end_run(true)
	else:
		_finish(true)


## Called on every machine when the host ends an online run.
func finish_networked(success: bool, info: Dictionary) -> void:
	if info.get("versus", false):
		var w: int = info.get("winner", -1)
		var mine := MatchState.local_team()
		var extra_v := {"versus": true, "result": "draw" if w == -1 else ("win" if w == mine else "lose"),
			"reason": info.get("reason", ""), "board": info.get("board", ""),
			"winner_name": info.get("winner_name", "")}
		_finish(w == mine, extra_v)
		return
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

## Build tiles, props, markers; position the player, car, and customer.
func _build_world() -> void:
	pass


## The playable area in world pixels (bounds + navmesh outline).
func map_rect() -> Rect2:
	return Rect2(-1280, -1280, 2560, 2560)


## Where recruitable survivors wait.
func _survivor_spots() -> Array[Vector2]:
	return []


func _pizza_spawn_spots() -> Array[Vector2]:
	return []


func _place_pizza() -> void:
	var spots := _pizza_spawn_spots()
	if spots.is_empty():
		push_warning("No pizza spawn spots in %s" % location_id)
		pizza.place(player.global_position + Vector2(0, 32))
		return
	pizza.place(spots.pick_random())


# ---------- Jobs + objective ----------

func _setup_tasks() -> void:
	for n in entities.find_children("*", "StaticBody2D", true, false):
		if n is HoldTask:
			tasks.append(n)
			n.completed.connect(_on_task_completed)
	_update_objective.call_deferred()


func _on_task_completed(task: HoldTask) -> void:
	EventBus.waypoint_cleared.emit(task)
	_update_objective()


func _physics_process(_delta: float) -> void:
	if not _layout_ready or MatchState.active or _known_jobs.size() == tasks.size():
		return
	var courier := Net.local_player() as Player
	if courier == null:
		return
	var changed := false
	for task in tasks:
		if not task.is_completed and not _known_jobs.has(task) \
				and courier.global_position.distance_squared_to(task.global_position) <= job_discovery_radius * job_discovery_radius:
			_known_jobs.append(task)
			EventBus.waypoint_set.emit(task, task.waypoint_label)
			changed = true
	if changed:
		_update_objective()


func _update_objective() -> void:
	if Net.is_versus():
		MatchState._refresh_hud()
		return
	var delivered := pizzas.filter(func(order: PizzaCargo) -> bool: return order.delivered).size()
	var carrying := pizzas.filter(func(order: PizzaCargo) -> bool: return order.carrier_id == Net.local_id()).size()
	EventBus.pizza_status_changed.emit("Orders %d/%d · Carrying %d" % [delivered, pizzas.size(), carrying])
	if can_finish_route():
		_depot.unlock()
		EventBus.waypoint_set.emit(_depot, "PIZZA CO.")
		EventBus.objective_changed.emit("Return to Pizza Co. to clock out")
		return
	var lines: Array[String] = []
	if delivered < pizzas.size():
		lines.append("Deliver the pizzas to the customers" if carrying > 0 else "Search for pizza orders")
	for t in tasks:
		var hint := "" if t.is_completed or _known_jobs.has(t) else " (search)"
		lines.append(("[x] " if t.is_completed else "[ ] ") + t.task_name + hint)
	EventBus.objective_changed.emit("\n".join(lines))


func _on_pizza_changed(order: PizzaCargo) -> void:
	var stop := order.customer as DeliveryCustomer
	if order.delivered:
		EventBus.waypoint_cleared.emit(stop)
		stop.receive_pizza()
		EventBus.hud_message.emit("Order %d delivered. Enjoy!" % order.number)
		if not Net.is_online():
			_record_survivors_at_customer(stop)
	elif order.carrier_id != 0:
		EventBus.waypoint_set.emit(stop, "ORDER %d" % order.number)
	else:
		EventBus.waypoint_cleared.emit(stop)
	_update_objective()


func _record_survivors_at_customer(stop: DeliveryCustomer) -> void:
	for c: Companion in get_tree().get_nodes_in_group(&"companions"):
		if not _delivered_survivors.has(c) and c.is_in_party() and c.global_position.distance_to(stop.global_position) <= 100.0:
			_delivered_survivors.append(c)


# ---------- End of run ----------

func _on_player_died() -> void:
	if MatchState.active:
		MatchState.report_local_death()  # respawn instead of being downed
		return
	if Net.is_online():
		# Downed, not dead: a teammate can revive. The host ends the run if everyone's down.
		Net.report_down(true)
		return
	await get_tree().create_timer(2.0).timeout
	_finish(false)


func _finish(success: bool, extra_in := {}) -> void:
	var me: Player = Net.local_player()
	var extra := {"survivors": 0, "infected_delivered": 0, "location": String(location_id),
		"pizza_delivered": pizzas.all(func(order: PizzaCargo) -> bool: return order.delivered)}
	extra.merge(extra_in, true)
	if success:
		for c in _delivered_survivors:
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
	summary.show_summary(GameManager.end_run(success, me.weapon.loadout_condition() if me else -1.0,
		extra, me.weapon.started_with() if me else &""))


# ---------- Companions ----------

## One companion at your side, plus survivors to find (some bitten, maybe one rival).
func _spawn_companions() -> void:
	var cast := [&"npc_companion_a", &"npc_companion_b"]
	if starting_companion:
		var c: Companion = COMPANION_SCENE.instantiate()
		c.character_id = cast[0]
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
		s.character_id = cast[(i + 1) % cast.size()]
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
	Fx.attach_shadow(body, Vector2(size.x * 1.1, maxf(size.y * 0.45, 12.0)), Vector2(2, 4))
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
