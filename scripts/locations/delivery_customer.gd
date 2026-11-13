class_name DeliveryCustomer
extends Node2D

@export var work_radius := 7.0
@export var work_cycle := 5.5
@export var celebration_time := 2.4

var pizza: PizzaCargo
var _work_clock := 0.0
var _celebrating := false
## Versus: this drop-off belongs to a team (-1 = the co-op customer).
var team := -1

@onready var sprite: AnimatedSprite2D = $AnimatedSprite2D


func _ready() -> void:
	sprite.sprite_frames = Assets.character_frames(&"npc_companion_b")
	sprite.play(&"idle")
	Fx.attach_shadow(self, Vector2(22, 9))
	_work_clock = fposmod(position.x * 0.117, work_cycle)
	if team < 0 and pizza == null and name != &"DeliveryCustomer":
		var crate := Sprite2D.new()
		crate.texture = Assets.region_texture("wasteland", "crate_wood")
		crate.position = Vector2(-19, -7)
		crate.scale = Vector2(0.7, 0.7)
		add_child(crate)
		move_child(crate, 0)
	if team >= 0:
		sprite.self_modulate = Color(1, 1, 1).lerp(MatchState.team_color(team), 0.45)


func _pizza() -> PizzaCargo:
	if team >= 0 and pizza == null:
		pizza = MatchState.pizza_of(team) as PizzaCargo
	return pizza


func can_interact(player: Player) -> bool:
	return _pizza() != null and not pizza.delivered and (team >= 0 or pizza.carrier_id == player.get_multiplayer_authority())


func get_interact_prompt(player: Player) -> String:
	if team >= 0 and MatchState.team_of(player.get_multiplayer_authority()) != team:
		return "%s's drop-off" % MatchState.team_name(team)
	if pizza.carrier_id == player.get_multiplayer_authority():
		return "[E] Deliver Order %d" % pizza.number if team < 0 else "[E] Hand pizza to customer"
	return "Customer is waiting for the pizza"


func interact(player: Player) -> void:
	if _pizza() and pizza.carrier_id == player.get_multiplayer_authority():
		pizza.request_interaction(player, true)


func _process(delta: float) -> void:
	if team >= 0 or _celebrating:
		return
	_work_clock = fposmod(_work_clock + delta, work_cycle)
	var phase := _work_clock / work_cycle
	if phase < 0.38:
		var angle := phase / 0.38 * TAU
		sprite.position = Vector2((1.0 - cos(angle)) * work_radius * 0.5, sin(angle * 3.0) * work_radius * 0.25).round()
		sprite.flip_h = angle > PI
		sprite.play(&"idle")
	else:
		sprite.position = Vector2.ZERO
		sprite.play(&"talk" if phase > 0.68 and phase < 0.84 else &"idle")


func receive_pizza() -> void:
	_celebrating = true
	sprite.play(&"talk")
	var meal := AnimatedSprite2D.new()
	meal.sprite_frames = Assets.item_frames("pizza")
	meal.position = Vector2(10, -21)
	meal.play(&"default")
	add_child(meal)
	var jump := create_tween()
	jump.tween_property(sprite, "position:y", -8.0, 0.20).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
	jump.tween_property(sprite, "position:y", 0.0, 0.24).set_trans(Tween.TRANS_BOUNCE)
	var lift := create_tween()
	lift.tween_property(meal, "position", Vector2(7, -26), 0.22)
	var bites := create_tween()
	for i in 3:
		bites.tween_property(meal, "scale", Vector2.ONE * (0.75 - i * 0.23), celebration_time / 4.0)
		bites.tween_property(sprite, "rotation", 0.08 if i % 2 == 0 else -0.07, 0.08)
	await bites.finished
	meal.queue_free()
	sprite.rotation = 0.0
	sprite.play(&"idle")
	_celebrating = false
