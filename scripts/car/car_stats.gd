class_name CarStats
extends Resource
## Tunable per-vehicle stats. Saved as .tres in res://resources/cars/ (Phase 4).
## Speeds are px/s, accelerations px/s², turn_rate rad/s at full steer.

@export var display_name := "Car"
@export var sprite: Texture2D

@export_group("Durability")
@export var max_hp := 100.0
@export_range(0.0, 1.0) var latch_resist := 0.0

@export_group("Engine")
@export var top_speed := 330.0
@export var acceleration := 570.0
@export_range(0.1, 1.0) var reverse_speed_ratio := 0.4
@export var brake_force := 900.0
@export var coast_decel := 160.0

@export_group("Handling")
@export var turn_rate := 3.2
## Lateral grip (per second). Higher = tighter, less slide.
@export var grip := 12.0
## Lateral grip while the handbrake is held. Low = drift.
@export var drift_grip := 1.5
@export var handbrake_decel := 240.0
@export var handbrake_turn_mult := 1.45

@export_group("Combat")
@export var ram_mult := 1.0

@export_group("Fuel")
@export var fuel_capacity := 100.0
## Fuel burned per second at full throttle.
@export var fuel_burn_rate := 1.0
