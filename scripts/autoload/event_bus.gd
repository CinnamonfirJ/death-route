extends Node
## Global event bus. Systems emit and listen here instead of holding direct references.
## Usage: EventBus.noise_increased.emit(10.0, global_position)

# --- Noise ---
signal noise_increased(amount: float, source_position: Vector2)
## A sound zombies can hear: anything within `radius` px of `pos` goes to investigate.
signal sound_made(pos: Vector2, radius: float)
signal noise_level_changed(level: float, max_level: float)
signal noise_threshold_reached(tier: int)

# --- Player ---
signal player_damaged(amount: float, current_hp: float)
signal player_died
signal player_state_changed(new_state: StringName)
signal player_entered_car(car: Node2D)
signal player_exited_car(car: Node2D)
signal interact_prompt_changed(text: String)

# --- Vehicles ---
signal car_damaged(car: Node2D, amount: float, current_hp: float)
signal car_destroyed(car: Node2D)
signal car_spawned(car: Node2D)
signal car_fuel_changed(car: Node2D, fuel: float, max_fuel: float)
signal zombie_latched(car: Node2D, zombie: Node2D)
signal zombie_unlatched(car: Node2D, zombie: Node2D)

# --- Zombies ---
signal zombie_killed(zombie_type: StringName, position: Vector2, by_car: bool)
signal wave_started(wave_index: int)

# --- Tasks ---
signal task_started(task: Node)
signal task_progress(task: Node, progress: float)
signal task_interrupted(task: Node)
signal task_completed(task: Node)
signal task_fumbled(task: Node, helper: Node)

signal objective_changed(text: String)
signal pizza_status_changed(text: String)
## HUD shows an off-screen arrow to each waypoint until it's cleared.
signal waypoint_set(target: Node2D, label: String)
signal waypoint_cleared(target: Node2D)
signal hud_message(text: String)

# --- Weapons ---
signal ammo_changed(in_mag: int, reserve: int, reloading: bool)
signal weapon_switched
signal weapon_jammed

# --- Companions / infection ---
signal companion_bitten(companion: Node)
signal companion_turned(companion: Node)
signal companion_recruited(companion: Node)
signal companion_died(companion: Node, by_player: bool)
signal companion_flinched(companion: Node)
signal companion_said(companion: Node, text: String)

# --- Rival saboteur ---
signal rival_sabotaged(rival: Node, kind: String)
signal rival_exposed(rival_name: String, reason: String)
signal rival_escaped(rival_name: String, scrap: int)
signal rival_stopped(rival_name: String, scrap: int)

# --- Run / meta ---
signal run_started(location_id: StringName)
signal run_ended(success: bool, scrap_earned: int)
signal scrap_collected(amount: int)
signal currency_changed(total: int)
signal upgrade_purchased(upgrade_id: StringName, new_level: int)

# --- Juice ---
signal screen_shake_requested(strength: float, duration: float)
