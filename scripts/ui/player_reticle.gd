extends Control
## A reticle for the local player's aim, using the two cursors on the weapon sheet.

const SHEET := preload("res://assets/weapons/weapons_static_sheet.png")
const GUN_CURSOR := Rect2(168, 8, 16, 16)
const KNIFE_CURSOR := Rect2(136, 40, 16, 16)

var _position := Vector2.ZERO
var _region := GUN_CURSOR
var _tint := Color.WHITE
var _show := false
var _cursor_hidden := false
var _touch := false

@onready var _pause_menu: CanvasLayer = $"../PauseMenu"


func _ready() -> void:
	_touch = TouchLayout.enabled()


func _process(_delta: float) -> void:
	var player := Net.local_player() as Player
	var mouse := get_viewport().get_mouse_position()
	_show = is_instance_valid(player) and player.is_on_foot() and not _pause_menu.visible \
		and not get_tree().paused and (player.touch_mode or get_viewport_rect().has_point(mouse))
	_set_cursor_hidden(_show and not player.touch_mode)
	if _show:
		var weapon := player.weapon
		_region = KNIFE_CURSOR if weapon.knife_equipped else GUN_CURSOR
		_tint = TitleStyle.AMBER if player.touch_mode and player.touch_fire else Color.WHITE
		_position = mouse
		if weapon.knife_equipped or player.touch_mode:
			var reach := Weapon.KNIFE_REACH if weapon.knife_equipped else 96.0
			var aim := Vector2.RIGHT.rotated(weapon.global_rotation)
			_position = get_viewport().get_canvas_transform() * (weapon.global_position + aim * reach)
		elif is_instance_valid(player.aim_target) and not player.aim_target.is_dead:
			_tint = Color(1.0, 0.85, 0.56)
	queue_redraw()


func _draw() -> void:
	if _show:
		var extent := _region.size * (1.25 if _touch else 1.0)
		draw_texture_rect_region(SHEET, Rect2(_position.round() - extent * 0.5, extent), _region, _tint)


func _exit_tree() -> void:
	_set_cursor_hidden(false)


func _set_cursor_hidden(hide_cursor: bool) -> void:
	if hide_cursor and Input.mouse_mode == Input.MOUSE_MODE_VISIBLE:
		Input.mouse_mode = Input.MOUSE_MODE_HIDDEN
		_cursor_hidden = true
	elif not hide_cursor and _cursor_hidden:
		if Input.mouse_mode == Input.MOUSE_MODE_HIDDEN:
			Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
		_cursor_hidden = false
