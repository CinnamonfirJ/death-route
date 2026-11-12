extends Control

const CANOPY := preload("res://assets/tilesets/rim_foliage.png")
const ART_SIZE := Vector2(640, 360)
@export var animation_fps := 20.0

var _ground: AtlasTexture
var _props: Array[Array] = []
var _embers: Array[Vector3] = []
var _glow: GradientTexture2D
var _time := 0.0


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	var atlas: Texture2D = load("res://assets/tilesets/wasteland_32.png")
	_ground = AtlasTexture.new()
	_ground.atlas = atlas
	_ground.region = Rect2(32, 32, 32, 32)
	_prop("wasteland", "container", Vector2(104, 117))
	_prop("wasteland", "pump_working", Vector2(137, 145))
	_prop("wasteland", "wreck_red_v", Vector2(117, 221))
	_prop("wasteland", "wreck_blue_h", Vector2(511, 251))
	_prop("camp", "shack_barrels", Vector2(510, 129))
	_prop("camp", "barrels_grey", Vector2(557, 159))
	_prop("wasteland", "tires", Vector2(483, 200))
	var rng := RandomNumberGenerator.new()
	rng.seed = 416
	for i in 42:
		var x := rng.randf_range(38.0, 179.0)
		_embers.append(Vector3(x if i % 2 == 0 else ART_SIZE.x - x,
			rng.randf_range(0.0, 280.0), rng.randf_range(0.2, 1.0)))
	var fade := Gradient.new()
	fade.colors = PackedColorArray([Color(1, 1, 1, 0.7), Color(1, 1, 1, 0)])
	_glow = GradientTexture2D.new()
	_glow.gradient = fade
	_glow.width = 128
	_glow.height = 128
	_glow.fill = GradientTexture2D.FILL_RADIAL
	_glow.fill_from = Vector2(0.5, 0.5)
	_glow.fill_to = Vector2(1.0, 0.5)


func _prop(atlas: String, region: String, at: Vector2) -> void:
	_props.append([Assets.region_texture(atlas, region), at])


func _process(delta: float) -> void:
	var frame := int(_time * animation_fps)
	_time += delta
	if int(_time * animation_fps) != frame:
		queue_redraw()


func _draw() -> void:
	if _ground == null:
		return
	var scale_to_fit := minf(size.x / ART_SIZE.x, size.y / ART_SIZE.y)
	draw_rect(Rect2(Vector2.ZERO, size), Color("#0a0814"))
	draw_set_transform((size - ART_SIZE * scale_to_fit) * 0.5, 0.0, Vector2.ONE * scale_to_fit)
	var clearing := Rect2(35, 35, 570, 290)
	draw_rect(clearing, Color("#151b39"))
	for y in 9:
		for x in 18:
			draw_texture_rect(_ground, Rect2(Vector2(35 + 32 * x, 35 + 32 * y), Vector2(32, 32)),
				false, Color(0.23, 0.26, 0.57, 0.39 + 0.035 * cos(x * 1.6 + y * 2.1)))
	_acid_edge(Vector2(46, 169), 1)
	_acid_edge(Vector2(594, 200), -1)
	draw_texture_rect(_glow, Rect2(104, 113, 74, 78), false, Color(0.38, 0.85, 0.23, 0.32))
	draw_texture_rect(_glow, Rect2(463, 85, 100, 104), false, Color(0.58, 0.23, 0.82, 0.40))
	for prop in _props:
		var sprite: Texture2D = prop[0]
		var extent := sprite.get_size() * 1.10
		var center: Vector2 = prop[1]
		draw_texture_rect(_glow, Rect2(center - Vector2(extent.x, 0) * 0.5,
			Vector2(extent.x, extent.y * 0.72)), false, Color(0.02, 0.01, 0.05))
		draw_texture_rect(sprite, Rect2(center - extent * 0.5, extent), false,
			Color(0.68, 0.53, 0.85))
	for side in 2:
		for i in 17:
			var sway := floorf(sin(_time * (0.65 + 0.1 * (i % 4)) + i * 1.63 + side) * 2.0)
			var x := 16.0 + i * 36.0 + sway
			var y := 14.0 + 3 * (i % 3) if side == 0 else 301.0 - 4 * (i % 3)
			draw_texture_rect_region(CANOPY, Rect2(x, y, 53, 42),
				Rect2(64 * ((i + side) % 3), 0, 64, 65), Color(0.16, 0.11, 0.24))
		for i in 8:
			var x := 15.0 if side == 0 else 592.0
			var y := 36.0 + i * 35.0 + floorf(sin(_time * 0.95 + i * 0.6) * 2.0)
			draw_texture_rect_region(CANOPY, Rect2(x - 3.0 * (i % 3), y, 32, 49),
				Rect2(64 * ((i + side + 1) % 3), 0, 64, 65), Color(0.17, 0.10, 0.22))
	for ember in _embers:
		var y := 42.0 + fposmod(ember.y - _time * (6.0 + ember.z * 14.0), 275.0)
		var x := ember.x + sin(_time * 0.8 + ember.y) * 7.0
		var alpha := ember.z * (0.56 + 0.34 * sin(_time * 2.0 + ember.y))
		var width := 2.0 if ember.z < 0.75 else 4.0
		draw_rect(Rect2(floorf(x), floorf(y), width, width),
			Color(0.36 + 0.30 * ember.z, 1.0, 0.24, alpha), ember.z < 0.75)


func _acid_edge(at: Vector2, inward: int) -> void:
	draw_texture_rect(_glow, Rect2(at - Vector2(106, 115), Vector2(212, 230)),
		false, Color(0.27, 0.83, 0.16, 0.64))
	var acid := Color("#4b983a")
	for i in 9:
		var reach := 18.0 + 8.0 * sin(i * PI / 8.0) + 4.0 * (i % 3)
		var x := at.x - (reach if inward < 0 else 0.0)
		draw_rect(Rect2(x, at.y - 56.0 + i * 12.0, reach, 13.0), acid)
	draw_rect(Rect2(at.x - (8.0 if inward < 0 else 0.0), at.y - 44.0, 8, 84), Color("#9cdf52"))
