class_name FuelPumpTask
extends HoldTask
## Sample task: repair a broken gas pump. Once fixed, any car parked beside it refuels.

@export var refuel_radius := 56.0
@export var refuel_per_sec := 20.0


func _physics_process(delta: float) -> void:
	if not is_completed:
		return
	for car in get_tree().get_nodes_in_group(&"cars"):
		if car.is_destroyed or car.fuel >= car.stats.fuel_capacity:
			continue
		if car.global_position.distance_to(global_position) <= refuel_radius:
			car.add_fuel(refuel_per_sec * delta)
