extends Node2D
## A compact world-space shop. Opening it never pauses the route.

const OFFERS := {
	"medkit": {"label": "Trauma Shot", "detail": "+55 HP and 4s shield", "amount": 55.0, "duration": 4.0},
	"premium_ammo": {"label": "Ammo Dump", "detail": "+32 rounds to selected gun", "amount": 32.0, "duration": 0.0},
	"battery": {"label": "Jury-Rig Shield", "detail": "8s damage protection", "amount": 0.0, "duration": 8.0},
	"food_stock": {"label": "Hot Slice Rush", "detail": "+40% speed for 16s", "amount": 0.4, "duration": 16.0},
}
const VENDORS := [
	["rusty", "Rusty", &"npc_companion_a", ["premium_ammo", "battery"]],
	["doc", "Doc", &"npc_companion_b", ["medkit"]],
	["mama_g", "Mama G", &"npc_companion_b", ["food_stock"]],
]

@export var reach := 68.0
var vendor_index := 0
var _menu: PanelContainer
var _name_tag: Label
var _buttons: Array[Button] = []
var _courier: Player
var _safe_bounds: Rect2
var _vendor: Array


func _ready() -> void:
	_vendor = VENDORS[vendor_index]
	var sprite := AnimatedSprite2D.new()
	sprite.sprite_frames = Assets.character_frames(_vendor[2])
	sprite.position = Vector2(0, -14)
	sprite.play(&"talk")
	add_child(sprite)
	Fx.attach_shadow(self, Vector2(22, 8))
	var counter := Sprite2D.new()
	counter.texture = Assets.region_texture("camp", "table_trade")
	counter.position = Vector2(-23, -7)
	counter.scale = Vector2.ONE * 0.65
	add_child(counter)

	var layer := CanvasLayer.new()
	layer.layer = 6
	add_child(layer)
	_name_tag = Label.new()
	_name_tag.text = _vendor[1]
	_name_tag.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_name_tag.custom_minimum_size.x = 104
	_name_tag.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_name_tag.add_theme_color_override(&"font_color", Color("#ffd091"))
	_name_tag.add_theme_color_override(&"font_outline_color", Color("#1c1320"))
	_name_tag.add_theme_constant_override(&"outline_size", 4)
	TouchLayout.label(_name_tag, 13)
	layer.add_child(_name_tag)

	_menu = PanelContainer.new()
	_menu.theme = Assets.ui_theme()
	_menu.add_to_group(&"field_shop_menus")
	_menu.custom_minimum_size.x = 185
	_menu.mouse_filter = Control.MOUSE_FILTER_IGNORE
	layer.add_child(_menu)
	var rows := VBoxContainer.new()
	_menu.add_child(rows)
	for id: String in _vendor[3]:
		var button := Button.new()
		button.focus_mode = Control.FOCUS_NONE
		button.pressed.connect(_buy.bind(id))
		TouchLayout.button(button, 13, 38)
		rows.add_child(button)
		_buttons.append(button)
	CampMarket.changed.connect(_refresh)
	EventBus.scrap_collected.connect(func(_amount: int) -> void: _refresh())
	_update_bounds()
	get_viewport().size_changed.connect(_update_bounds)
	_refresh()


func _update_bounds() -> void:
	_safe_bounds = TouchLayout.safe_rect(get_viewport())


func _process(_delta: float) -> void:
	_courier = Net.local_player() as Player
	var near := _courier != null and _courier.is_on_foot() and not _courier.is_dead() \
		and global_position.distance_squared_to(_courier.global_position) <= reach * reach \
		and GameManager.phase == GameManager.Phase.RUN
	var anchor := get_global_transform_with_canvas().origin
	var bounds := _safe_bounds
	_name_tag.visible = not near and bounds.has_point(anchor)
	_name_tag.position = anchor - Vector2(52, 37)
	_menu.visible = near and bounds.has_point(anchor)
	if _menu.visible:
		_menu.position = (anchor - Vector2(_menu.size.x * 0.5, _menu.size.y + 38)).clamp(
			bounds.position + Vector2(4, 4), bounds.end - _menu.size - Vector2(4, 4))


func _refresh() -> void:
	var merchant := CampMarket.merchant(_vendor[0])
	for i in _buttons.size():
		var id: String = _vendor[3][i]
		var button := _buttons[i]
		var q := CampMarket.quote(_vendor[0], id)
		var ladder: Array = q.get("ask_ladder", [])
		var text := "Checking stock..." if CampMarket.message.is_empty() else "Market unavailable"
		var can_buy := false
		if CampMarket.online:
			if not merchant.get("open", false):
				text = "Shop closed"
			elif ladder.is_empty():
				text = "Sold out"
			else:
				var price := int(ladder[0])
				text = "%d scrap / %d left" % [price, int(q.get("inventory", ladder.size()))]
				can_buy = price <= GameManager.run_scrap
		button.text = "%s  |  %s\n%s" % [OFFERS[id].label, text, OFFERS[id].detail]
		button.disabled = not can_buy or CampMarket.busy


func _buy(id: String) -> void:
	if not _menu.visible or _courier == null or _courier.is_dead():
		return
	var courier := _courier
	var result: Dictionary = await CampMarket.trade(_vendor[0], id, "buy", 1, true)
	if not result.get("ok", false):
		EventBus.hud_message.emit(str(result.get("error", "Trade unavailable.")))
		return
	if is_instance_valid(courier) and not courier.is_dead() and GameManager.phase == GameManager.Phase.RUN:
		var effect: Dictionary = OFFERS[id]
		courier.apply_field_supply(id, effect.amount, effect.duration)
		EventBus.hud_message.emit("%s activated" % effect.label)
