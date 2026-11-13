extends StaticBody2D
## The depot is solid; the doorstep in front becomes an exit after all work is done.

const REACH := 40.0

var route: Location
var _lantern: Sprite2D


func _ready() -> void:
	add_to_group(&"nav_obstacle")
	var shape := RectangleShape2D.new()
	shape.size = Vector2(138, 38)
	var footprint := CollisionShape2D.new()
	footprint.shape = shape
	footprint.position = Vector2(0, -29)
	add_child(footprint)

	var facade := Sprite2D.new()
	facade.texture = load("res://assets/props/pizza_shop.png")
	facade.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	facade.scale = Vector2(2, 2)
	facade.position.y = -62
	add_child(facade)
	_lantern = Fx.attach_glow(self, Color("#edac65"), 3.3, Vector2(0, -17), 0.0)
	_lantern.modulate.a = 0.32

	var door := Area2D.new()
	door.collision_layer = 16
	door.collision_mask = 0
	door.monitoring = false
	add_child(door)
	var circle := CircleShape2D.new()
	circle.radius = REACH - 14.0
	var hitbox := CollisionShape2D.new()
	hitbox.shape = circle
	door.add_child(hitbox)


func unlock() -> void:
	_lantern.self_modulate = Color("#d3ff8e")
	_lantern.modulate.a = 0.62


func can_interact(player: Player) -> bool:
	return player.is_on_foot() and not player.is_dead() and player.visible \
		and player.global_position.distance_squared_to(global_position) <= REACH * REACH


func get_interact_prompt(_player: Player) -> String:
	return "[E] Clock out at Pizza Co." if route.can_finish_route() else "Pizza Co. · Return after deliveries and repairs"


func interact(player: Player) -> void:
	if route.can_finish_route():
		route.request_checkout(player)
