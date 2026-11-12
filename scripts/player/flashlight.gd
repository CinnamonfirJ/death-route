extends Node2D
## Press [F] on foot to toggle the flashlight. Companions caught in
## the beam react: infected ones flinch and back away, healthy ones just complain.
## It's a little noisy (clicking, waving it around).

@export var beam_range := 150.0
@export var night_beam_range := 190.0
@export var half_angle_deg := 22.0
@export var noise_per_sec := 1.0
@export var beam_energy := 1.65
@export var scan_interval := 0.15

var _scan_cd := 0.0
var _switched_on := false
var _lamp: PointLight2D
var active := false:
	set(value):
		active = value
		if is_node_ready():
			_update_visuals()

@onready var beam: Polygon2D = $Beam


func _ready() -> void:
	var half := deg_to_rad(half_angle_deg)
	var pts := PackedVector2Array([Vector2.ZERO])
	for i in 9:
		pts.append(Vector2.RIGHT.rotated(lerpf(-half, half, i / 8.0)) * beam_range)
	beam.polygon = pts
	var mat := CanvasItemMaterial.new()
	mat.blend_mode = CanvasItemMaterial.BLEND_MODE_ADD
	beam.material = mat
	_lamp = RoomLighting.make_beam(night_beam_range, beam_energy, Color(1.0, 0.93, 0.76))
	add_child(_lamp)
	GameManager.settings_changed.connect(_update_visuals)
	_update_visuals()


func _update_visuals() -> void:
	var night := RoomLighting.is_night()
	beam.visible = active and not night
	_lamp.visible = active and night


func _physics_process(delta: float) -> void:
	var player = owner
	if not Net.is_local_authority(player):
		return  # another player's light; theirs to aim
	if Input.is_action_just_pressed(&"flashlight"):
		toggle()
	if player.is_dead():
		_switched_on = false
	var on: bool = _switched_on and player.is_on_foot()
	if on != active:
		active = on
	if not active:
		return
	rotation = (player.get_aim_point(true) - global_position).angle()  # raw: no auto-aim on the light
	EventBus.noise_increased.emit(noise_per_sec * delta, global_position)
	_scan_cd -= delta
	if _scan_cd <= 0.0:
		_scan_cd = scan_interval
		shine()


func toggle() -> void:
	if Net.is_local_authority(owner) and owner.is_on_foot():
		_switched_on = not _switched_on


## Calls on_flashlight on every companion inside the beam. Returns how many were lit.
func shine() -> int:
	var lit := 0
	var dir := Vector2.RIGHT.rotated(global_rotation)
	var half := deg_to_rad(half_angle_deg)
	var reach := night_beam_range if RoomLighting.is_night() else beam_range
	for c in get_tree().get_nodes_in_group(&"companions"):
		if not c.visible:
			continue
		var to: Vector2 = c.global_position + Vector2(0, -10) - global_position
		if to.length() > reach or absf(dir.angle_to(to)) > half or not _can_see(to):
			continue
		c.on_flashlight(global_position)
		lit += 1
	# Online: teammates in the beam too (that's how a human rival gets caught).
	for p in get_tree().get_nodes_in_group(&"player"):
		if p == owner or not p.visible:
			continue
		var to_p: Vector2 = p.global_position + Vector2(0, -10) - global_position
		if to_p.length() <= reach and absf(dir.angle_to(to_p)) <= half and _can_see(to_p):
			p.on_flashlight(global_position)
			lit += 1
	return lit


func _can_see(offset: Vector2) -> bool:
	var ray := PhysicsRayQueryParameters2D.create(global_position, global_position + offset, 1)
	return get_world_2d().direct_space_state.intersect_ray(ray).is_empty()
