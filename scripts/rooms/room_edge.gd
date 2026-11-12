@tool
extends Node2D
## Layers anchored canopy sprites along the playable perimeter. The shader bends
## each sprite at its own rate, with stronger motion away from the root.

const SWAY := preload("res://assets/tilesets/canopy_sway.gdshader")
const SHEET := "res://assets/tilesets/rim_foliage.png"
const FRAME := Vector2(64, 65)
const PALETTES := [
	Color(0.65, 0.77, 0.96),
	Color(0.76, 0.96, 0.69),
	Color(1.0, 0.78, 0.58),
]

@export var bounds := Rect2(0, 0, 2048, 1472)
@export_enum("Hospital", "Camp", "Wasteland") var biome := 0


func _ready() -> void:
	if not ResourceLoader.exists(SHEET):
		return
	var sheet: Texture2D = load(SHEET)
	var variants: Array[AtlasTexture] = []
	for i in 3:
		var frame := AtlasTexture.new()
		frame.atlas = sheet
		frame.region = Rect2(Vector2(i * FRAME.x, 0), FRAME)
		variants.append(frame)
	var wind := ShaderMaterial.new()
	wind.shader = SWAY
	var rng := RandomNumberGenerator.new()
	rng.seed = 8317 + biome * 137
	var top_left := bounds.position
	var top_right := Vector2(bounds.end.x, bounds.position.y)
	var bottom_left := Vector2(bounds.position.x, bounds.end.y)
	var bottom_right := bounds.end
	_plant_edge(top_left, top_right, Vector2.DOWN, PI, variants, wind, rng)
	_plant_edge(top_right, bottom_right, Vector2.LEFT, -PI * 0.5, variants, wind, rng)
	_plant_edge(bottom_right, bottom_left, Vector2.UP, 0.0, variants, wind, rng)
	_plant_edge(bottom_left, top_left, Vector2.RIGHT, PI * 0.5, variants, wind, rng)


func _plant_edge(start: Vector2, end: Vector2, inward: Vector2, angle: float,
		variants: Array[AtlasTexture], wind: ShaderMaterial, rng: RandomNumberGenerator) -> void:
	var along := start.direction_to(end)
	var length := start.distance_to(end)
	var distance := -12.0
	while distance <= length + 12.0:
		var root := start + along * distance
		var bank := sin(distance * 0.012 + angle) * 8.0 + sin(distance * 0.027) * 4.0
		_add_cluster(root - inward * rng.randf_range(30, 42), angle,
			variants[rng.randi_range(0, 2)], wind, rng.randf_range(0.92, 1.19), Color(0.49, 0.50, 0.57))
		_add_cluster(root + inward * (bank - rng.randf_range(15, 33)), angle,
			variants[rng.randi_range(0, 2)], wind, rng.randf_range(0.61, 1.03), PALETTES[biome])
		distance += rng.randf_range(24, 41)


func _add_cluster(anchor: Vector2, angle: float, frame: Texture2D, wind: ShaderMaterial,
		size: float, tint: Color) -> void:
	var sprite := Sprite2D.new()
	sprite.texture = frame
	sprite.centered = false
	sprite.offset = Vector2(-FRAME.x * 0.5, -FRAME.y)
	sprite.position = anchor.round()
	sprite.rotation = angle
	sprite.scale = Vector2.ONE * size
	sprite.self_modulate = tint
	sprite.material = wind
	sprite.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	add_child(sprite, false, Node.INTERNAL_MODE_BACK)
