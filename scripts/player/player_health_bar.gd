extends Node2D
## Drives the small health bar above a player's head (the Player's "CrewHealth" node,
## a half-size copy of the HUD health meter) and draws their name above it.
## Colours: green = you and allies (co-op crew, your TDM team), red = enemies
## (in FFA everyone else is an enemy). Blue = you.
## hp / max_hp are replicated on the Player's NetSync, so every machine shows real values.

const FILL_RED := 0
const FILL_BLUE := 1
const FILL_GREEN := 3
const NAME_COLORS := {FILL_RED: Color(1.0, 0.55, 0.5), FILL_BLUE: Color(0.6, 0.8, 1.0), FILL_GREEN: Color(0.65, 1.0, 0.65)}

var player: Player
var bar: Range
var _font: Font
var _column := -1
var _name := ""


func _ready() -> void:
	z_index = 20
	z_as_relative = false
	position = Vector2(0, -50)
	var theme := ThemeDB.get_project_theme()
	_font = theme.default_font if theme and theme.default_font else ThemeDB.fallback_font


func _process(_delta: float) -> void:
	var show := Net.is_online() and player.visible and not player.is_dead()
	visible = show
	bar.visible = show
	if not show:
		return
	bar.max_value = player.max_hp
	bar.value = player.hp
	var column := fill_column()
	var n := player.display_name()
	if column != _column or n != _name:
		_column = column
		_name = n
		bar.fill_column = column
		queue_redraw()


func fill_column() -> int:
	var me := Net.local_id()
	var id := player.get_multiplayer_authority()
	if id == me:
		return FILL_BLUE
	if MatchState.active and MatchState.are_enemies(me, id):
		return FILL_RED
	return FILL_GREEN


func _draw() -> void:
	if player.get_multiplayer_authority() == Net.local_id():
		return  # you know your own name
	var size := 8
	var w := _font.get_string_size(_name, HORIZONTAL_ALIGNMENT_LEFT, -1, size).x
	if w > 80.0:
		return
	var at := Vector2(-w * 0.5, 0.0)
	draw_string_outline(_font, at, _name, HORIZONTAL_ALIGNMENT_LEFT, -1, size, 3, Color(0, 0, 0, 0.85))
	draw_string(_font, at, _name, HORIZONTAL_ALIGNMENT_LEFT, -1, size, NAME_COLORS.get(_column, Color.WHITE))
