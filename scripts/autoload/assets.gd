extends Node
## Loads res://assets/asset_manifest.json and builds SpriteFrames from it,
## so scenes never hard-code sprite paths or frame counts.
## Usage: $AnimatedSprite2D.sprite_frames = Assets.character_frames(&"zombie_walker")

const MANIFEST_PATH := "res://assets/asset_manifest.json"
const UI_FONT_PATH := "res://assets/ui/NewGameFont.ttf"

var manifest: Dictionary = {}
var _frames_cache: Dictionary = {}


func _ready() -> void:
	var project_theme := ThemeDB.get_project_theme()
	if project_theme and ResourceLoader.exists(UI_FONT_PATH):
		var font := FontVariation.new()
		font.base_font = load(UI_FONT_PATH)
		font.spacing_glyph = 1
		# NewGame lacks punctuation such as brackets, slashes, and percent signs.
		font.fallbacks = [ThemeDB.get_default_theme().default_font]
		project_theme.default_font = font
	var f := FileAccess.open(MANIFEST_PATH, FileAccess.READ)
	if f == null:
		push_error("Asset manifest missing at %s" % MANIFEST_PATH)
		return
	var parsed = JSON.parse_string(f.get_as_text())
	if typeof(parsed) == TYPE_DICTIONARY:
		manifest = parsed
	else:
		push_error("Asset manifest is not valid JSON")


func character(id: StringName) -> Dictionary:
	return manifest.get("characters", {}).get(String(id), {})


func vehicle(id: StringName) -> Dictionary:
	return manifest.get("vehicles", {}).get(String(id), {})


func vehicle_ids() -> Array[String]:
	var out: Array[String] = []
	for k in manifest.get("vehicles", {}).keys():
		if not String(k).begins_with("_"):
			out.append(k)
	return out


func texture(section: String, id: String) -> Texture2D:
	var entry: Dictionary = manifest.get(section, {}).get(id, {})
	return load(entry["res"]) if entry.has("res") else null


## Builds a CarStats from the manifest's vehicle "base" block.
## Phase 4 replaces this with authored .tres files; this stays as the fallback.
func car_stats(id: StringName) -> CarStats:
	var s := CarStats.new()
	var e := vehicle(id)
	if e.is_empty():
		push_error("Unknown vehicle id: %s" % id)
		return s
	var b: Dictionary = e.get("base", {})
	s.display_name = String(id).capitalize()
	s.sprite = load(e["res"])
	s.max_hp = b.get("max_hp", s.max_hp)
	s.top_speed = b.get("top_speed", s.top_speed)
	s.acceleration = b.get("accel", s.acceleration)
	s.ram_mult = b.get("ram_mult", s.ram_mult)
	s.fuel_capacity = b.get("fuel_cap", s.fuel_capacity)
	s.latch_resist = b.get("latch_resist", 0.0)
	# Heavier (higher HP) cars steer slower: 70 HP -> ~3.6 rad/s, 200 HP -> ~2.8 rad/s.
	s.turn_rate = clampf(3.4 - (s.max_hp - 100.0) * 0.006, 2.6, 3.8)
	return s


## Tile lists for a tileset entry: { "road": [Vector2i, ...], ... }
func tileset_tiles(tileset_id: String) -> Dictionary:
	var out := {}
	var tiles: Dictionary = manifest.get("tilesets", {}).get(tileset_id, {}).get("tiles", {})
	for key in tiles:
		if String(key).begins_with("_"):
			continue
		var arr: Array[Vector2i] = []
		for c in tiles[key]:
			arr.append(Vector2i(int(c[0]), int(c[1])))
		out[key] = arr
	return out


## A TileSet (source id 0) containing every tile listed under the entry's "tiles".
func build_tileset(tileset_id: String) -> TileSet:
	var key := "tileset:" + tileset_id
	if _frames_cache.has(key):
		return _frames_cache[key]
	var entry: Dictionary = manifest["tilesets"][tileset_id]
	var size := int(entry.get("tile", 32))
	var ts := TileSet.new()
	ts.tile_size = Vector2i(size, size)
	var src := TileSetAtlasSource.new()
	src.texture = load(entry["res"])
	src.texture_region_size = Vector2i(size, size)
	# Tiles listed under "solid" (e.g. walls) get a full-cell collision polygon,
	# so they block movement and are carved out of baked navmeshes.
	var solid: Array = entry.get("solid", [])
	if not solid.is_empty():
		ts.add_physics_layer()
		ts.set_physics_layer_collision_layer(0, 1)  # "world"
		ts.set_physics_layer_collision_mask(0, 0)
	var tiles := tileset_tiles(tileset_id)
	var half := size * 0.5
	var full := PackedVector2Array([Vector2(-half, -half), Vector2(half, -half), Vector2(half, half), Vector2(-half, half)])
	for tile_name in tiles:
		for c in tiles[tile_name]:
			if src.has_tile(c):
				continue
			src.create_tile(c)
	ts.add_source(src, 0)
	for solid_name in solid:
		for c in tiles.get(solid_name, []):
			var data := src.get_tile_data(c, 0)
			data.add_collision_polygon(0)
			data.set_collision_polygon_points(0, 0, full)
	_frames_cache[key] = ts
	return ts


## AtlasTexture for a named pixel region of a tileset (props).
func region_texture(tileset_id: String, region: String) -> AtlasTexture:
	var key := "region:%s:%s" % [tileset_id, region]
	if _frames_cache.has(key):
		return _frames_cache[key]
	var entry: Dictionary = manifest["tilesets"][tileset_id]
	var r: Array = entry["regions"][region]
	var at := AtlasTexture.new()
	at.atlas = load(entry["res"])
	at.region = Rect2(r[0], r[1], r[2], r[3])
	_frames_cache[key] = at
	return at


## SpriteFrames with a single non-looping "default" animation for an effects entry.
func effect_frames(id: StringName, fps := 14.0) -> SpriteFrames:
	var key := "fx:%s" % id
	if _frames_cache.has(key):
		return _frames_cache[key]
	var e: Dictionary = manifest.get("effects", {}).get(String(id), {})
	if e.is_empty():
		push_error("Unknown effect id: %s" % id)
		return null
	var size: Array = e["frame_size"]
	var tex: Texture2D = load(e["res"])
	var sf := SpriteFrames.new()
	sf.set_animation_speed(&"default", fps)
	sf.set_animation_loop(&"default", false)
	for i in int(e["frames"]):
		var at := AtlasTexture.new()
		at.atlas = tex
		at.region = Rect2(i * size[0], 0, size[0], size[1])
		sf.add_frame(&"default", at)
	_frames_cache[key] = sf
	return sf


## Weapon SpriteFrames: "shoot" = the full firing strip, "idle" = its last frame
## (frame 0 is the muzzle flash; the last frame is the gun at rest).
func weapon_frames(id: StringName) -> SpriteFrames:
	var key := "weapon:%s" % id
	if _frames_cache.has(key):
		return _frames_cache[key]
	var e: Dictionary = manifest.get("weapons", {}).get(String(id), {})
	var strip: Dictionary = e.get("shoot", e.get("idle", {}))
	if strip.is_empty():
		push_error("Unknown weapon id: %s" % id)
		return null
	var tex: Texture2D = load(strip["res"])
	var sf := SpriteFrames.new()
	sf.remove_animation(&"default")
	sf.add_animation(&"idle")
	sf.add_animation(&"shoot")
	sf.set_animation_loop(&"shoot", false)
	sf.set_animation_speed(&"shoot", 24.0)
	var count := int(strip["frames"])
	for i in count:
		var at := AtlasTexture.new()
		at.atlas = tex
		at.region = Rect2(i * 32, 0, 32, 32)
		sf.add_frame(&"shoot", at)
		if i == count - 1:
			sf.add_frame(&"idle", at)
	_frames_cache[key] = sf
	return sf


## Shared title palette for the game menus and overlays.
func ui_theme() -> Theme:
	if _frames_cache.has("ui_theme"):
		return _frames_cache["ui_theme"]
	var th := Theme.new()
	th.default_font = ThemeDB.get_project_theme().default_font
	th.default_font_size = 10
	TitleStyle.apply(th)

	var bar_bg := StyleBoxFlat.new()
	bar_bg.bg_color = Color(0.08, 0.05, 0.07)
	bar_bg.set_corner_radius_all(2)
	var bar_fill := StyleBoxFlat.new()
	bar_fill.bg_color = Color(0.25, 0.42, 0.18)  # bar_fillers green
	bar_fill.set_corner_radius_all(2)
	th.set_stylebox(&"background", &"ProgressBar", bar_bg)
	th.set_stylebox(&"fill", &"ProgressBar", bar_fill)
	_frames_cache["ui_theme"] = th
	return th


func _nine(tex: Texture2D, region: Rect2, margin: int, content: int) -> StyleBoxTexture:
	var sb := StyleBoxTexture.new()
	sb.texture = tex
	sb.region_rect = region
	sb.texture_margin_left = margin
	sb.texture_margin_right = margin
	sb.texture_margin_top = margin
	sb.texture_margin_bottom = margin
	sb.content_margin_left = content
	sb.content_margin_right = content
	sb.content_margin_top = content
	sb.content_margin_bottom = content
	return sb


## Looping "default" SpriteFrames for a 16x16, 7-frame item from the manifest.
func item_frames(id: String) -> SpriteFrames:
	var key := "item:%s" % id
	if _frames_cache.has(key):
		return _frames_cache[key]
	var e: Dictionary = manifest.get("items", {}).get(id, {})
	if e.is_empty():
		push_error("Unknown item id: %s" % id)
		return null
	var tex: Texture2D = load(e["res"])
	var sf := SpriteFrames.new()
	sf.set_animation_speed(&"default", 8.0)
	sf.set_animation_loop(&"default", true)
	for i in 7:
		var at := AtlasTexture.new()
		at.atlas = tex
		at.region = Rect2(i * 16, 0, 16, 16)
		sf.add_frame(&"default", at)
	_frames_cache[key] = sf
	return sf


## First frame of an item as a static icon (Garage, HUD).
func item_icon(id: String) -> Texture2D:
	var sf := item_frames(id)
	return sf.get_frame_texture(&"default", 0) if sf else null


## SpriteFrames for an animated prop strip (looping "default").
func prop_frames(id: StringName, fps := 10.0) -> SpriteFrames:
	var key := "prop:%s" % id
	if _frames_cache.has(key):
		return _frames_cache[key]
	var e: Dictionary = manifest.get("props", {}).get(String(id), {})
	var size: Array = e["frame_size"]
	var tex: Texture2D = load(e["res"])
	var sf := SpriteFrames.new()
	sf.set_animation_speed(&"default", fps)
	sf.set_animation_loop(&"default", true)
	for i in int(e["frames"]):
		var at := AtlasTexture.new()
		at.atlas = tex
		at.region = Rect2(i * size[0], 0, size[0], size[1])
		sf.add_frame(&"default", at)
	_frames_cache[key] = sf
	return sf


## Builds (and caches) a SpriteFrames from a horizontal-strip character entry.
func character_frames(id: StringName) -> SpriteFrames:
	if _frames_cache.has(id):
		return _frames_cache[id]
	var entry := character(id)
	if entry.is_empty():
		push_error("Unknown character id: %s" % id)
		return null
	var size: Array = entry.get("frame_size", [32, 32])
	var sf := SpriteFrames.new()
	sf.remove_animation(&"default")
	for anim_name in entry["animations"]:
		var a: Dictionary = entry["animations"][anim_name]
		var tex: Texture2D = load(a["res"])
		sf.add_animation(anim_name)
		sf.set_animation_speed(anim_name, a.get("fps", 8))
		sf.set_animation_loop(anim_name, a.get("loop", true))
		for i in int(a["frames"]):
			var at := AtlasTexture.new()
			at.atlas = tex
			at.region = Rect2(i * size[0], 0, size[0], size[1])
			sf.add_frame(anim_name, at)
	_frames_cache[id] = sf
	return sf
