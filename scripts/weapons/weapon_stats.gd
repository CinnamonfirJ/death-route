class_name WeaponStats
extends Resource
## Tunable stats for a hitscan weapon. Authored as .tres in res://resources/weapons/.

## Key into the asset manifest's "weapons" section (sprite).
@export var weapon_id: StringName = &"pistol"
@export var display_name := "Pistol"

@export_group("Damage")
@export var damage := 14.0
@export var pellets := 1
@export var spread_deg := 3.0
@export var weapon_range := 320.0
## Bullets are a small swept circle, not a thin ray, so near-misses connect.
## Zombie hitboxes sit at their feet while players aim at the torso; ~6 covers that.
@export var bullet_radius := 6.0
@export var knockback := 90.0

@export_group("Handling")
## Seconds between shots.
@export var fire_interval := 0.22
@export var automatic := false
@export var mag_size := 12
@export var start_reserve := 48
@export var reload_time := 1.1

@export_group("Noise")
## Noise added to the meter per shot.
@export var noise_per_shot := 9.0

@export_group("Maintenance")
## 0..1. Degrades per shot; repaired in the Garage (Phase 4).
@export var durability_loss_per_shot := 0.002
