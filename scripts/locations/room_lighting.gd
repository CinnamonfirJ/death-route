class_name RoomLighting
extends Node2D
## World-canvas lights. The HUD stays readable on its own CanvasLayer.

const BEAM_TEXTURE := "res://assets/effects/flashlight_cookie.png"
@export var night_ambient := Color(0.36, 0.39, 0.49)
@export var interior_tint := Color(0.83, 0.85, 0.94)
@export var interior_glow_radius := 120.0
@export var exterior_glow_radius := 166.0
@export var interior_glow_energy := 0.30
@export var exterior_glow_energy := 0.43
@export var flower_glow := Color(0.51, 0.92, 0.66, 0.22)
@export var flower_glow_scale := 0.18
@export var flower_pulse_seconds := 2.4
const MACHINE_LIGHTS := {
	"vending": Color(0.55, 0.85, 1.0),
	"computer": Color(0.52, 0.93, 0.77),
	"coffeemachine": Color(1.0, 0.74, 0.47),
	"radio": Color(0.68, 0.92, 0.62),
	"pump": Color(1.0, 0.79, 0.49),
	"generator": Color(1.0, 0.78, 0.54),
	"plantpower": Color(0.55, 0.80, 1.0),
	"firebarrel": Color(1.0, 0.49, 0.22),
}

static var _soft: GradientTexture2D
var _ambient := CanvasModulate.new()
var _nearby: PointLight2D
var _floor: TileMapLayer
var _floor_tint := Color.WHITE
var _fixtures := Node2D.new()


static func is_night() -> bool:
	return GameManager.get_setting("lighting_mode") != "classic"


static func make_beam(reach: float, energy: float, color: Color) -> PointLight2D:
	return _light(load(BEAM_TEXTURE), reach / 126.0, energy, color)


static func _light(texture: Texture2D, size: float, energy: float, color: Color) -> PointLight2D:
	var light := PointLight2D.new()
	light.texture = texture
	light.texture_scale = size
	light.energy = energy
	light.color = color
	light.shadow_enabled = true
	light.shadow_filter = Light2D.SHADOW_FILTER_NONE if OS.has_feature("web") else Light2D.SHADOW_FILTER_PCF5
	light.shadow_filter_smooth = 1.3
	return light


static func _pool(radius: float, energy: float, color: Color) -> PointLight2D:
	if _soft == null:
		var gradient := Gradient.new()
		gradient.colors = PackedColorArray([Color.WHITE, Color(1, 1, 1, 0.0)])
		gradient.offsets = PackedFloat32Array([0.0, 1.0])
		_soft = GradientTexture2D.new()
		_soft.gradient = gradient
		_soft.width = 128
		_soft.height = 128
		_soft.fill = GradientTexture2D.FILL_RADIAL
		_soft.fill_from = Vector2(0.5, 0.5)
		_soft.fill_to = Vector2(1.0, 0.5)
	var pool := _light(_soft, radius / 64.0, energy, color)
	# Save the Web shadow passes for moving beams that communicate line of sight.
	pool.shadow_enabled = not OS.has_feature("web")
	return pool


func configure(level: Node2D) -> void:
	add_child(_ambient)
	add_child(_fixtures)
	_floor = level.get_node_or_null(^"Floors") as TileMapLayer
	if _floor:
		_floor_tint = _floor.self_modulate
	_nearby = _pool(exterior_glow_radius, exterior_glow_energy, Color(0.8, 0.85, 1.0))
	_nearby.shadow_enabled = false
	_fixtures.add_child(_nearby)
	var walls := level.get_node_or_null(^"Entities/Walls") as TileMapLayer
	if walls and walls.tile_set:
		_add_wall_shadows(walls)
	for body in level.get_node(^"Entities").find_children("*", "StaticBody2D", true, false):
		_add_prop_shadow(body)
		_add_machine_light(body)
	var delivery := _pool(112.0, 0.91, Color(1.0, 0.78, 0.49))
	_fixtures.add_child(delivery)
	delivery.global_position = level.get_node(^"Entities/DeliveryCustomer").global_position
	_plant_flowers(level.map_rect())
	GameManager.settings_changed.connect(_apply_mode)
	_apply_mode()


func _apply_mode() -> void:
	var night := is_night()
	_ambient.color = night_ambient if night else Color.WHITE
	if _floor:
		_floor.self_modulate = _floor_tint * interior_tint if night else _floor_tint
	_fixtures.visible = night
	set_process(night)


func _process(_delta: float) -> void:
	var player = Net.local_player()
	_nearby.visible = is_instance_valid(player) and not player.is_dead()
	if not _nearby.visible:
		return
	_nearby.global_position = player.global_position
	var inside := _floor != null and _floor.get_cell_source_id(_floor.local_to_map(
		_floor.to_local(player.global_position))) != -1
	_nearby.energy = interior_glow_energy if inside else exterior_glow_energy
	_nearby.texture_scale = (interior_glow_radius if inside else exterior_glow_radius) / 64.0


func _plant_flowers(bounds: Rect2) -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = 143 + int(bounds.size.x)
	for i in 22:
		var anchor := Node2D.new()
		var y := bounds.position.y + 50.0 if i % 2 == 0 else bounds.end.y - 50.0
		anchor.position = Vector2(bounds.position.x + bounds.size.x * (i + 1) / 23.0,
			y + rng.randf_range(-11, 11))
		_fixtures.add_child(anchor)
		var petals := Polygon2D.new()
		petals.polygon = PackedVector2Array([Vector2(-3,-1), Vector2(-1,-1), Vector2(-1,-3),
			Vector2(1,-3), Vector2(1,-1), Vector2(3,-1), Vector2(3,1), Vector2(1,1),
			Vector2(1,3), Vector2(-1,3), Vector2(-1,1), Vector2(-3,1)])
		petals.color = Color(flower_glow, 0.66)
		anchor.add_child(petals)
		var glow := Fx.attach_glow(anchor, flower_glow, flower_glow_scale, Vector2.ZERO, 0.0)
		var pulse := glow.create_tween().set_loops().set_trans(Tween.TRANS_SINE)
		pulse.tween_interval(rng.randf_range(0.0, flower_pulse_seconds))
		pulse.tween_property(glow, "modulate:a", flower_glow.a * 0.45, flower_pulse_seconds)
		pulse.tween_property(glow, "modulate:a", flower_glow.a, flower_pulse_seconds)


func _add_wall_shadows(walls: TileMapLayer) -> void:
	var tile_size := Vector2(walls.tile_set.tile_size)
	var used := {}
	for cell in walls.get_used_cells():
		used[cell] = true
	for cell: Vector2i in used:
		if used.has(cell + Vector2i.LEFT):
			continue
		var count := 1
		while used.has(cell + Vector2i(count, 0)):
			count += 1
		var corner := walls.map_to_local(cell) - tile_size * 0.5
		_add_occluder(walls, Rect2(corner, Vector2(tile_size.x * count, tile_size.y)))


func _add_prop_shadow(body: StaticBody2D) -> void:
	if not body.is_in_group(&"nav_obstacle"):
		return
	for node in body.get_children(true):
		var collider := node as CollisionShape2D
		if collider == null or collider.disabled or not collider.shape is RectangleShape2D:
			continue
		var size: Vector2 = collider.shape.size
		_add_occluder(collider, Rect2(-size * 0.5, size))


func _add_occluder(parent: Node2D, rect: Rect2) -> void:
	var polygon := OccluderPolygon2D.new()
	polygon.polygon = PackedVector2Array([rect.position, Vector2(rect.end.x, rect.position.y),
		rect.end, Vector2(rect.position.x, rect.end.y)])
	var occluder := LightOccluder2D.new()
	occluder.occluder = polygon
	parent.add_child(occluder)


func _add_machine_light(body: StaticBody2D) -> void:
	var generator := body as HoldTask
	if generator and generator.powers_generator:
		var source := _pool(generator.generator_light_radius, generator.generator_light_energy,
			Color("#bbdbff"))
		_fixtures.add_child(source)
		source.global_position = body.global_position + generator.generator_light_offset
		source.visible = generator.generator_running
		generator.generator_started.connect(source.show)
		return
	var name_key := String(body.name).to_lower()
	for machine: String in MACHINE_LIGHTS:
		if name_key.contains(machine):
			var light := _pool(92.0, 0.92, MACHINE_LIGHTS[machine])
			_fixtures.add_child(light)
			# Light falls into the approach lane in front of the machine.
			light.global_position = body.global_position + Vector2(0, 18)
			var job := body as HoldTask
			if job and not job.is_completed:
				light.hide()
				job.completed.connect(func(_completed: HoldTask) -> void: light.show())
			return
