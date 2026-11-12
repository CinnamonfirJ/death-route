class_name DeliveryCustomer
extends Node2D

var pizza: PizzaCargo
## Versus: this drop-off belongs to a team (-1 = the co-op customer).
var team := -1

@onready var sprite: AnimatedSprite2D = $AnimatedSprite2D


func _ready() -> void:
	sprite.sprite_frames = Assets.character_frames(&"npc_companion_b")
	sprite.play(&"idle")
	if team >= 0:
		sprite.self_modulate = Color(1, 1, 1).lerp(MatchState.team_color(team), 0.45)


func _pizza() -> PizzaCargo:
	if team >= 0 and pizza == null:
		pizza = MatchState.pizza_of(team) as PizzaCargo
	return pizza
	Fx.attach_shadow(self, Vector2(22, 9))


func can_interact(_player: Player) -> bool:
	return _pizza() != null and not pizza.delivered


func get_interact_prompt(player: Player) -> String:
	if team >= 0 and MatchState.team_of(player.get_multiplayer_authority()) != team:
		return "%s's drop-off" % MatchState.team_name(team)
	if pizza.carrier_id == player.get_multiplayer_authority():
		return "[E] Hand pizza to customer"
	return "Customer is waiting for the pizza"


func interact(player: Player) -> void:
	if _pizza() and pizza.carrier_id == player.get_multiplayer_authority():
		pizza.request_interaction(player, true)


func receive_pizza() -> void:
	sprite.play(&"talk")
	await get_tree().create_timer(1.4, false).timeout
	sprite.play(&"idle")
