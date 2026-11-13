@tool
class_name RoomMarker
extends Marker2D
## A spot in a room where something appears when the run starts.
## Put these under the room's "Markers" node; pick `kind` in the Inspector.
## In the editor each marker shows a preview icon + label; in game it's invisible.

enum Kind {
	ZOMBIE_SPAWN,  ## Wave zombies come from here (NoiseDirector).
	CAR_SPAWN,     ## A replacement car can appear here when yours is wrecked.
	PIZZA_SPOT,    ## The pizza is hidden at ONE of these per run.
	SURVIVOR,      ## A survivor to recruit (may be infected, or a rival).
	SPARE_CAR,     ## A random scavengeable car (50-100% HP).
	WALKER,
	LATCHER,
	STOPPER,
	BRUTE,
	SCRAP,
	AMMO,
	FUEL,
	MEDKIT,
	CREW_START,
	FLARE_PISTOL,
	NEEDLE_SMG,
	CRATE,         ## A camp-market supply crate (set `commodity`, or leave blank for a random one).
}

const LABELS := ["ZOMBIE SPAWN", "CAR SPAWN", "PIZZA?", "SURVIVOR", "SPARE CAR", "walker", "latcher",
	"stopper", "BRUTE", "scrap", "ammo", "fuel", "medkit", "CREW START", "FLARE", "NEEDLE", "CRATE"]
const COLORS := [Color(0.9, 0.2, 0.2), Color(0.3, 0.6, 1.0), Color(1.0, 0.6, 0.1), Color(0.3, 0.9, 0.4),
	Color(0.5, 0.7, 1.0), Color(0.6, 0.9, 0.5), Color(0.6, 0.9, 0.5), Color(0.6, 0.9, 0.5), Color(0.9, 0.4, 0.9),
	Color(1, 0.85, 0.3), Color(0.6, 0.8, 1), Color(1, 0.9, 0.3), Color(1, 0.4, 0.4),
	Color(0.8, 0.85, 1.0), Color("#ff8650"), Color("#69e6ef"), Color("#e9c46a")]
## Preview art per kind: [manifest section, id] (characters / items) or a texture path.
const PREVIEW := {
	Kind.SURVIVOR: ["characters", "npc_companion_a"], Kind.WALKER: ["characters", "zombie_walker"],
	Kind.LATCHER: ["characters", "zombie_latcher"], Kind.STOPPER: ["characters", "zombie_stopper"],
	Kind.BRUTE: ["characters", "zombie_brute"], Kind.SCRAP: ["items", "scrap"],
	Kind.AMMO: ["items", "ammo_pistol"], Kind.FUEL: ["items", "fuel_can"], Kind.MEDKIT: ["items", "medkit"],
	Kind.SPARE_CAR: ["path", "res://assets/vehicles/car3.png"],
	Kind.FLARE_PISTOL: ["path", "res://assets/items/flare_pistol_pickup.png"],
	Kind.NEEDLE_SMG: ["path", "res://assets/items/needle_smg_pickup.png"],
	Kind.CRATE: ["items", "chest_metal"],
}
## Default pickup amounts (amount = 0 uses these).
const DEFAULT_AMOUNT := {Kind.SCRAP: 6, Kind.AMMO: 12, Kind.FUEL: 40, Kind.MEDKIT: 35, Kind.CRATE: 1}

@export var kind: Kind = Kind.ZOMBIE_SPAWN:
	set(v):
		kind = v
		queue_redraw()
## Pickups only: how much it gives (0 = default).
@export var amount := 0
@export var anchored := false
## CRATE only: medkit, premium_ammo, battery or food_stock. Blank picks one at random each run.
@export var commodity := ""

static var _manifest: Dictionary = {}


func _ready() -> void:
	gizmo_extents = 6.0
	if not Engine.is_editor_hint():
		match kind:
			Kind.ZOMBIE_SPAWN:
				add_to_group(&"zombie_spawn")
			Kind.CAR_SPAWN:
				add_to_group(&"car_spawn")
	queue_redraw()


func pickup_amount() -> int:
	return amount if amount > 0 else DEFAULT_AMOUNT.get(kind, 0)


func _draw() -> void:
	if not Engine.is_editor_hint():
		return
	var col: Color = COLORS[kind]
	var tex := _preview_texture()
	if tex:
		var s := tex.get_size()
		if kind == Kind.SPARE_CAR:
			draw_set_transform(Vector2.ZERO, 0.0, Vector2(2, 2))
			draw_texture(tex, -s * 0.5, Color(1, 1, 1, 0.85))
			draw_set_transform(Vector2.ZERO)
		else:
			draw_texture(tex, Vector2(-s.x * 0.5, -s.y + 4.0))
	else:
		draw_circle(Vector2.ZERO, 7.0, Color(col, 0.35))
		draw_arc(Vector2.ZERO, 7.0, 0.0, TAU, 20, col, 1.5)
	var font := ThemeDB.fallback_font
	draw_string(font, Vector2(-30, 14), LABELS[kind], HORIZONTAL_ALIGNMENT_CENTER, 60, 8, col)


func _preview_texture() -> Texture2D:
	if not PREVIEW.has(kind):
		return null
	var p: Array = PREVIEW[kind]
	if p[0] == "path":
		return load(p[1])
	if _manifest.is_empty():
		var parsed = JSON.parse_string(FileAccess.get_file_as_string("res://assets/asset_manifest.json"))
		_manifest = parsed if parsed is Dictionary else {}
	var entry: Dictionary = _manifest.get(p[0], {}).get(p[1], {})
	var res := ""
	var frame := Vector2(16, 16)
	if p[0] == "characters":
		res = entry.get("animations", {}).get("idle", {}).get("res", "")
		frame = Vector2(32, 32)
	else:
		res = entry.get("res", "")
	if res == "" or not ResourceLoader.exists(res):
		return null
	var at := AtlasTexture.new()
	at.atlas = load(res)
	at.region = Rect2(Vector2.ZERO, frame)
	return at
