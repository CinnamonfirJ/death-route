class_name Brute
extends Zombie
## Massive HP; wrecks cars in seconds and punishes ramming.
## Counter: avoid it, or lure it next to explosive barrels and shoot them.


## Car damage taken when ramming a Brute, on top of the normal ram cost.
@export var ram_recoil := 25.0


func on_rammed(car: Node2D, car_velocity: Vector2, damage: float) -> void:
	take_damage(damage * 0.5, car_velocity * 0.05)
	car.take_damage(ram_recoil)
	EventBus.screen_shake_requested.emit(8.0, 0.3)


## Body contact with a car: it bounces off.
func on_car_impact(car: Car, pre_velocity: Vector2, _slip: float) -> void:
	if is_dead:
		return
	car.velocity = -pre_velocity * 0.3
	car.take_damage(10.0 + pre_velocity.length() * 0.05)


func _animate() -> void:
	super()
	sprite.speed_scale = 0.8
