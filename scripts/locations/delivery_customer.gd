class_name DeliveryCustomer
extends Node2D

var pizza: PizzaCargo

@onready var sprite: AnimatedSprite2D = $AnimatedSprite2D


func _ready() -> void:
	sprite.sprite_frames = Assets.character_frames(&"npc_companion_b")
	sprite.play(&"idle")
	Fx.attach_shadow(self, Vector2(22, 9))


func can_interact(_player: Player) -> bool:
	return pizza != null and not pizza.delivered


func get_interact_prompt(player: Player) -> String:
	if pizza.carrier_id == player.get_multiplayer_authority():
		return "[E] Hand pizza to customer"
	return "Customer is waiting for the pizza"


func interact(player: Player) -> void:
	if pizza.carrier_id == player.get_multiplayer_authority():
		pizza.request_interaction(player, true)


func receive_pizza() -> void:
	sprite.play(&"talk")
	await get_tree().create_timer(1.4, false).timeout
	sprite.play(&"idle")
