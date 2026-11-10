extends Node2D
## Hold [F] on foot to shine a flashlight toward the mouse. Companions caught in
## the beam react: infected ones flinch and back away, healthy ones just complain.
## It's a little noisy (clicking, waving it around).

@export var beam_range := 150.0
@export var half_angle_deg := 22.0
@export var noise_per_sec := 1.0

var _scan_cd := 0.0

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
	beam.visible = false


func _physics_process(delta: float) -> void:
	var player = owner
	if not Net.is_local_authority(player):
		return  # another player's light; theirs to aim
	var on: bool = Input.is_action_pressed(&"flashlight") and player.is_on_foot()
	beam.visible = on
	if not on:
		return
	rotation = (player.get_aim_point(true) - global_position).angle()  # raw: no auto-aim on the light
	EventBus.noise_increased.emit(noise_per_sec * delta, global_position)
	_scan_cd -= delta
	if _scan_cd <= 0.0:
		_scan_cd = 0.15
		shine()


## Calls on_flashlight on every companion inside the beam. Returns how many were lit.
func shine() -> int:
	var lit := 0
	var dir := Vector2.RIGHT.rotated(global_rotation)
	var half := deg_to_rad(half_angle_deg)
	for c in get_tree().get_nodes_in_group(&"companions"):
		if not c.visible:
			continue
		var to: Vector2 = c.global_position + Vector2(0, -10) - global_position
		if to.length() > beam_range or absf(dir.angle_to(to)) > half:
			continue
		c.on_flashlight(global_position)
		lit += 1
	# Online: teammates in the beam too (that's how a human rival gets caught).
	for p in get_tree().get_nodes_in_group(&"player"):
		if p == owner or not p.visible:
			continue
		var to_p: Vector2 = p.global_position + Vector2(0, -10) - global_position
		if to_p.length() <= beam_range and absf(dir.angle_to(to_p)) <= half:
			p.on_flashlight(global_position)
			lit += 1
	return lit
