extends Node
## Cosmetic effects: particle bursts, glow "blooms", and blood splatters that hold for
## a while then slowly fade. Everything is local to this machine (online, each peer
## plays effects from replicated events). CPUParticles2D: works on Compatibility/web/mobile.
##
##   Fx.blood(pos, dir)        hit spray + a splat or two
##   Fx.gore(pos, dir)         death burst + bigger splats
##   Fx.muzzle(pos, angle)     flash bloom + sparks + ejected shell
##   Fx.impact(pos, angle)     sparks where a bullet lands
##   Fx.explosion(pos, scale)  bloom, fire, smoke, debris, scorch mark
##   Fx.glow(pos, color, size, time)       one-off bloom
##   Fx.attach_glow(node, color, size)     persistent flickering bloom (fire barrels, loot)

const MAX_SPLATS := 140
const SPLAT_HOLD := 10.0
const SPLAT_FADE := 14.0
const BLOOD := Color(0.55, 0.04, 0.04)
const BLOOD_DARK := Color(0.3, 0.02, 0.02)

var _dot: Texture2D
var _soft: Texture2D
var _blobs: Array[Texture2D] = []
var _additive: CanvasItemMaterial
var _splats: Array[Node2D] = []


func _ready() -> void:
	_dot = _make_dot()
	_soft = _make_soft()
	for i in 4:
		_blobs.append(_make_blob(i))
	_additive = CanvasItemMaterial.new()
	_additive.blend_mode = CanvasItemMaterial.BLEND_MODE_ADD


## Additive blend material (for glowing tracers etc.).
func additive() -> CanvasItemMaterial:
	return _additive


func _layer() -> Node:
	var scene := get_tree().current_scene
	if scene == null:
		return null
	var ents := scene.get_node_or_null(^"Entities")
	return ents if ents else scene


func _decals() -> Node:
	var d := get_tree().get_first_node_in_group(&"decals")
	return d if d else _layer()


# ---------- Public effects ----------

## Soft contact shadow in world pixels. It follows the body below the y-sorted sprites.
func attach_shadow(body: Node2D, size: Vector2, offset := Vector2(0, 2)) -> Sprite2D:
	var shadow := Sprite2D.new()
	shadow.texture = _soft
	shadow.texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR
	shadow.self_modulate = Color(0.09, 0.055, 0.04, 0.68)
	shadow.scale = size / _soft.get_size()
	shadow.position = offset
	shadow.z_as_relative = false
	shadow.z_index = -4
	body.add_child(shadow)
	return shadow


func blood(pos: Vector2, dir := Vector2.ZERO, amount := 10) -> void:
	_burst(pos, {"amount": amount, "color": BLOOD, "speed": Vector2(40, 110), "life": 0.45,
		"dir": dir, "spread": 50.0 if dir != Vector2.ZERO else 180.0, "size": Vector2(1.0, 2.0),
		"damping": 160.0})
	if randf() < 0.7:
		splat(pos + dir.normalized() * randf_range(4, 14), randf_range(0.5, 0.9))


func gore(pos: Vector2, dir := Vector2.ZERO) -> void:
	_burst(pos, {"amount": 22, "color": BLOOD, "speed": Vector2(60, 170), "life": 0.6,
		"dir": dir, "spread": 70.0 if dir != Vector2.ZERO else 180.0, "size": Vector2(1.5, 3.0),
		"damping": 200.0})
	_burst(pos, {"amount": 6, "color": BLOOD_DARK, "speed": Vector2(30, 90), "life": 0.7,
		"dir": dir, "spread": 180.0, "size": Vector2(2.5, 3.5), "damping": 120.0})
	splat(pos, randf_range(1.0, 1.4))
	for i in 2:
		splat(pos + Vector2.from_angle(randf() * TAU) * randf_range(8, 20) + dir.normalized() * 10.0,
			randf_range(0.5, 0.8))


func muzzle(pos: Vector2, angle: float) -> void:
	glow(pos, Color(1.0, 0.75, 0.35), 0.45, 0.07)
	_burst(pos, {"amount": 5, "color": Color(1.0, 0.85, 0.4), "speed": Vector2(80, 160), "life": 0.12,
		"dir": Vector2.from_angle(angle), "spread": 18.0, "size": Vector2(1.0, 1.5), "additive": true})
	# Ejected brass, flicked out to the side.
	_burst(pos, {"amount": 1, "color": Color(0.85, 0.65, 0.2), "speed": Vector2(50, 80), "life": 0.35,
		"dir": Vector2.from_angle(angle + PI * 0.5), "spread": 25.0, "size": Vector2(1.5, 1.5),
		"gravity": Vector2(0, 260)})


func impact(pos: Vector2, angle: float) -> void:
	glow(pos, Color(1.0, 0.8, 0.4), 0.25, 0.06)
	_burst(pos, {"amount": 6, "color": Color(1.0, 0.8, 0.35), "speed": Vector2(40, 120), "life": 0.18,
		"dir": Vector2.from_angle(angle + PI), "spread": 60.0, "size": Vector2(1.0, 1.0), "additive": true})


func explosion(pos: Vector2, scale := 1.0) -> void:
	glow(pos, Color(1.0, 0.55, 0.15), 2.6 * scale, 0.45)
	glow(pos, Color(1.0, 0.9, 0.6), 1.1 * scale, 0.15)
	_burst(pos, {"amount": int(26 * scale), "color": Color(1.0, 0.55, 0.1), "color_end": Color(0.6, 0.1, 0.0, 0.0),
		"speed": Vector2(40, 150) * scale, "life": 0.55, "spread": 180.0, "size": Vector2(2.0, 4.0),
		"damping": 120.0, "additive": true})
	_burst(pos, {"amount": int(9 * scale), "color": Color(0.42, 0.4, 0.38, 0.4), "color_end": Color(0.3, 0.3, 0.3, 0.0),
		"speed": Vector2(15, 45) * scale, "life": 1.1, "spread": 180.0, "size": Vector2(2.5, 4.5),
		"gravity": Vector2(0, -25), "damping": 25.0})
	_burst(pos, {"amount": int(10 * scale), "color": Color(0.12, 0.1, 0.09), "speed": Vector2(90, 200) * scale,
		"life": 0.5, "spread": 180.0, "size": Vector2(1.5, 2.5), "damping": 260.0})
	splat(pos, 1.6 * scale, Color(0.05, 0.04, 0.04, 0.75))  # scorch mark


## A one-off additive bloom.
func glow(pos: Vector2, color: Color, size := 1.0, time := 0.15) -> void:
	var layer := _layer()
	if layer == null:
		return
	var s := Sprite2D.new()
	s.texture = _soft
	s.material = _additive
	s.modulate = color
	s.scale = Vector2.ONE * size
	s.z_index = 8
	s.z_as_relative = false
	layer.add_child(s)
	s.global_position = pos
	var t := s.create_tween()
	t.set_parallel(true)
	t.tween_property(s, "modulate:a", 0.0, time)
	t.tween_property(s, "scale", s.scale * 1.3, time)
	t.set_parallel(false)
	t.tween_callback(s.queue_free)


## Persistent flickering bloom parented to `node` (fire barrels, loot).
func attach_glow(node: Node2D, color: Color, size := 1.0, offset := Vector2.ZERO, flicker := 0.15) -> Sprite2D:
	var s := Sprite2D.new()
	s.name = "Glow"
	s.texture = _soft
	s.material = _additive
	s.modulate = color
	s.scale = Vector2.ONE * size
	s.position = offset
	s.z_index = 1
	node.add_child(s)
	if flicker > 0.0:
		var t := s.create_tween().set_loops()
		t.tween_property(s, "modulate:a", color.a * (1.0 - flicker), randf_range(0.08, 0.16))
		t.tween_property(s, "modulate:a", color.a, randf_range(0.08, 0.16))
	return s


## A ground decal that holds, then slowly fades. Oldest ones go first past MAX_SPLATS.
func splat(pos: Vector2, size := 1.0, color := Color(BLOOD, 0.85)) -> void:
	var layer := _decals()
	if layer == null:
		return
	var s := Sprite2D.new()
	s.texture = _blobs.pick_random()
	s.modulate = color
	s.rotation = randf() * TAU
	s.scale = Vector2.ONE * size
	layer.add_child(s)
	s.global_position = pos
	_splats.append(s)
	while _splats.size() > MAX_SPLATS:
		var old: Node2D = _splats.pop_front()
		if is_instance_valid(old):
			old.queue_free()
	var t := s.create_tween()
	t.tween_interval(SPLAT_HOLD + randf() * 4.0)
	t.tween_property(s, "modulate:a", 0.0, SPLAT_FADE)
	t.tween_callback(func() -> void:
		_splats.erase(s)
		s.queue_free())


# ---------- Internals ----------

func _burst(pos: Vector2, o: Dictionary) -> void:
	var layer := _layer()
	if layer == null:
		return
	var p := CPUParticles2D.new()
	p.one_shot = true
	p.explosiveness = 0.9
	p.amount = maxi(int(o.get("amount", 8)), 1)
	p.lifetime = o.get("life", 0.5)
	p.texture = _dot
	var dir: Vector2 = o.get("dir", Vector2.ZERO)
	p.direction = dir.normalized() if dir != Vector2.ZERO else Vector2.RIGHT
	p.spread = o.get("spread", 180.0)
	var spd: Vector2 = o.get("speed", Vector2(40, 100))
	p.initial_velocity_min = spd.x
	p.initial_velocity_max = spd.y
	p.gravity = o.get("gravity", Vector2.ZERO)
	p.damping_min = o.get("damping", 0.0)
	p.damping_max = o.get("damping", 0.0)
	var sz: Vector2 = o.get("size", Vector2(1, 2))
	p.scale_amount_min = sz.x
	p.scale_amount_max = sz.y
	p.color = o.get("color", Color.WHITE)
	if o.has("color_end"):
		var g := Gradient.new()
		g.set_color(0, o.color)
		g.set_color(1, o.color_end)
		p.color_ramp = g
	else:
		var fade := Gradient.new()
		fade.set_color(0, p.color)
		fade.set_color(1, Color(p.color, 0.0))
		p.color_ramp = fade
	if o.get("additive", false):
		p.material = _additive
	p.z_index = 7
	p.z_as_relative = false
	layer.add_child(p)
	p.global_position = pos
	p.emitting = true
	get_tree().create_timer(p.lifetime + 0.3, false).timeout.connect(p.queue_free)


func _make_dot() -> Texture2D:
	var img := Image.create(2, 2, false, Image.FORMAT_RGBA8)
	img.fill(Color.WHITE)
	return ImageTexture.create_from_image(img)


func _make_soft() -> Texture2D:
	var g := Gradient.new()
	g.set_color(0, Color(1, 1, 1, 0.9))
	g.set_color(1, Color(1, 1, 1, 0.0))
	var t := GradientTexture2D.new()
	t.gradient = g
	t.fill = GradientTexture2D.FILL_RADIAL
	t.fill_from = Vector2(0.5, 0.5)
	t.fill_to = Vector2(1.0, 0.5)
	t.width = 48
	t.height = 48
	return t


## Pixel-y irregular blob for blood/scorch decals.
func _make_blob(seed_i: int) -> Texture2D:
	var rng := RandomNumberGenerator.new()
	rng.seed = 1337 + seed_i
	var n := 20
	var img := Image.create(n, n, false, Image.FORMAT_RGBA8)
	img.fill(Color(0, 0, 0, 0))
	var c := Vector2(n, n) * 0.5
	var blobs := []
	for i in rng.randi_range(4, 7):
		blobs.append([c + Vector2(rng.randf_range(-5, 5), rng.randf_range(-5, 5)), rng.randf_range(2.0, 5.0)])
	for i in rng.randi_range(3, 6):  # droplets
		blobs.append([c + Vector2.from_angle(rng.randf() * TAU) * rng.randf_range(6, 9), rng.randf_range(0.8, 1.6)])
	for y in n:
		for x in n:
			var p := Vector2(x + 0.5, y + 0.5)
			for b in blobs:
				if p.distance_to(b[0]) <= b[1]:
					img.set_pixel(x, y, Color.WHITE)
					break
	return ImageTexture.create_from_image(img)
