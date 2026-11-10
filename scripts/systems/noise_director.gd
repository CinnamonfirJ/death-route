class_name NoiseDirector
extends Node
## Zombie waves, driven by two things:
##   - the RUN CLOCK: difficulty ("threat", 0..1) ramps over ramp_seconds. New zombie
##     types unlock at set times, and wave size / frequency / the alive cap grow with it.
##   - the NOISE METER: shooting, sprinting, engines, jobs push a 0..100 meter. Its tier
##     makes the next wave come sooner and somewhat bigger, never beyond what the clock allows.
## Waves trickle in one zombie at a time from off-screen spawn points (group "zombie_spawn").
## Every noise also alerts zombies within earshot so they come investigate.

const WALKER := preload("res://scenes/zombies/walker.tscn")
const LATCHER := preload("res://scenes/zombies/latcher.tscn")
const STOPPER := preload("res://scenes/zombies/stopper.tscn")
const BRUTE := preload("res://scenes/zombies/brute.tscn")

## Noise tier -> wave size multiplier and how much faster the next wave comes.
const TIER_SIZE := {1: 1.0, 2: 1.2, 3: 1.45, 4: 1.75}
const TIER_SPEED := {1: 1.0, 2: 1.25, 3: 1.5, 4: 1.9}
const UNLOCK_LINES := {
	"latcher": "Latchers are out. Keep them off your roof.",
	"stopper": "Stoppers on the roads. Drift past them.",
	"brute": "Something BIG is moving. Find a barrel.",
}

@export var max_noise := 100.0
@export var tier_thresholds: Array[float] = [25.0, 50.0, 75.0, 99.0]
@export var decay_per_sec := 5.0
## Quiet seconds before the meter starts to fall.
@export var decay_delay := 2.0

@export_group("Progression")
## Seconds for threat to go from 0 to 1.
@export var ramp_seconds := 360.0
## No waves at all during the opening seconds.
@export var opening_grace := 20.0
## Run time (s) when each type can start appearing in waves.
@export var latcher_unlock := 90.0
@export var stopper_unlock := 180.0
@export var brute_unlock := 270.0
@export var wave_size_start := 2.0
@export var wave_size_end := 8.0
## Seconds between waves at tier 1 (start -> end of the ramp); higher tiers come faster.
@export var interval_start := 30.0
@export var interval_end := 12.0
@export var max_alive_start := 14
@export var max_alive_end := 45
## Global multipliers for tuning.
@export_range(0.1, 2.0) var wave_size_mult := 1.0
@export_range(0.5, 3.0) var wave_interval_mult := 1.0
## Seconds between zombies within a wave (they trickle in, not all at once).
@export var trickle_interval := 0.8

@export_group("Spawning")
## Spawns happen between these distances from the nearest player (keeps them off-screen).
@export var spawn_min_dist := 450.0
@export var spawn_max_dist := 1000.0
## Hearing radius = base + amount * per_unit (then x zombie.hearing_mult).
@export var hearing_base := 60.0
@export var hearing_per_unit := 25.0
@export var hearing_max := 700.0
## Node that receives spawned zombies (y-sorted entities).
@export var spawn_parent: Node

var level := 0.0
var tier := 0
var wave_index := 0
## Seconds since the run started (drives threat + unlocks).
var elapsed := 0.0

var _quiet := 0.0
var _wave_timer := 0.0
var _emit_timer := 0.0
var _last_noise_pos := Vector2.ZERO
var _queue: Array[PackedScene] = []
var _queue_points: Array[Vector2] = []
var _trickle_cd := 0.0
var _announced := {}


func _ready() -> void:
	add_to_group(&"noise_director")
	EventBus.noise_increased.connect(_on_noise)
	_wave_timer = opening_grace


func threat() -> float:
	return clampf(elapsed / ramp_seconds, 0.0, 1.0)


func max_alive() -> int:
	return roundi(lerpf(max_alive_start, max_alive_end, threat()))


## Zombie scenes that may appear right now.
func unlocked_types() -> Array[String]:
	var out: Array[String] = ["walker"]
	if elapsed >= latcher_unlock:
		out.append("latcher")
	if elapsed >= stopper_unlock:
		out.append("stopper")
	if elapsed >= brute_unlock:
		out.append("brute")
	return out


func _on_noise(amount: float, pos: Vector2) -> void:
	level = minf(level + amount, max_noise)
	_quiet = decay_delay
	_last_noise_pos = pos
	var radius := minf(hearing_base + amount * hearing_per_unit, hearing_max)
	for z in get_tree().get_nodes_in_group(&"zombies"):
		if pos.distance_to(z.global_position) < radius * z.hearing_mult:
			z.hear(pos)


func _physics_process(delta: float) -> void:
	elapsed += delta
	_announce_unlocks()
	_quiet -= delta
	if _quiet <= 0.0:
		level = maxf(level - decay_per_sec * delta, 0.0)

	var new_tier := 0
	for i in tier_thresholds.size():
		if level >= tier_thresholds[i]:
			new_tier = i + 1
	if new_tier != tier:
		var rising := new_tier > tier
		tier = new_tier
		if rising:
			EventBus.noise_threshold_reached.emit(tier)
			# A louder tier pulls the next wave in, but with a short warning, not instantly.
			if elapsed >= opening_grace:
				_wave_timer = minf(_wave_timer, 3.0)

	if tier > 0:
		_wave_timer -= delta * TIER_SPEED.get(tier, 1.0)
		if _wave_timer <= 0.0:
			_spawn_wave()
	_tick_trickle(delta)

	_emit_timer -= delta
	if _emit_timer <= 0.0:
		_emit_timer = 0.1
		EventBus.noise_level_changed.emit(level, max_noise)
		Net.broadcast_noise(level, tier)  # clients' HUDs


func _announce_unlocks() -> void:
	for kind in unlocked_types():
		if kind == "walker" or _announced.has(kind):
			continue
		_announced[kind] = true
		Net.announce(UNLOCK_LINES[kind])


## Queues the next wave; zombies then trickle in from _tick_trickle.
func _spawn_wave() -> void:
	_wave_timer = lerpf(interval_start, interval_end, threat()) * wave_interval_mult
	if tier == 0:
		return
	var points := _pick_spawn_points()
	if points.is_empty():
		return
	var size := roundi(lerpf(wave_size_start, wave_size_end, threat()) * TIER_SIZE.get(tier, 1.0) * wave_size_mult)
	size = maxi(size, 1)
	wave_index += 1
	EventBus.wave_started.emit(wave_index)
	_queue_points = points
	var stoppers := 0
	for i in size:
		var kind := _roll_kind(stoppers)
		if kind == "stopper":
			stoppers += 1
		_queue.append({"walker": WALKER, "latcher": LATCHER, "stopper": STOPPER, "brute": BRUTE}[kind])
	_trickle_cd = 0.0


## Weighted pick among unlocked types. Walkers dominate; at most one stopper per
## wave, one brute alive at a time, and only when the noise is high (tier 3+).
func _roll_kind(stoppers_this_wave: int) -> String:
	var t := threat()
	var weights := {"walker": 10.0}
	var types := unlocked_types()
	if "latcher" in types:
		weights["latcher"] = lerpf(2.0, 4.0, t)
	if "stopper" in types and stoppers_this_wave == 0:
		weights["stopper"] = 1.2
	if "brute" in types and tier >= 3 and _alive_of(&"zombie_brute") == 0 \
			and not _queue.has(BRUTE):
		weights["brute"] = 0.8
	var total := 0.0
	for w in weights.values():
		total += w
	var roll := randf() * total
	for k in weights:
		roll -= weights[k]
		if roll <= 0.0:
			return k
	return "walker"


func _alive_of(id: StringName) -> int:
	return get_tree().get_nodes_in_group(&"zombies").filter(func(z) -> bool: return z.zombie_id == id).size()


func _tick_trickle(delta: float) -> void:
	if _queue.is_empty():
		return
	_trickle_cd -= delta
	if _trickle_cd > 0.0:
		return
	_trickle_cd = trickle_interval
	if get_tree().get_nodes_in_group(&"zombies").size() >= max_alive():
		return  # wait for room
	var scene: PackedScene = _queue.pop_front()
	var p: Vector2 = _queue_points[randi() % _queue_points.size()]
	var z = Net.spawn(_parent(), scene.resource_path,
		{"position": p + Vector2(randf_range(-24, 24), randf_range(-24, 24))})
	if z:
		z.hear(_last_noise_pos, 15.0)


## Spawn points off-screen for every player but not too far from the nearest one,
## nearest to the noise first.
func _pick_spawn_points() -> Array[Vector2]:
	var centers: Array[Vector2] = []
	for p in Net.player_nodes():
		centers.append(p.global_position)
	if centers.is_empty():
		centers.append(_last_noise_pos)
	var pts: Array[Vector2] = []
	for m in get_tree().get_nodes_in_group(&"zombie_spawn"):
		var nearest := INF
		for c in centers:
			nearest = minf(nearest, m.global_position.distance_to(c))
		if nearest >= spawn_min_dist and nearest <= spawn_max_dist:
			pts.append(m.global_position)
	pts.sort_custom(func(a: Vector2, b: Vector2) -> bool:
		return a.distance_squared_to(_last_noise_pos) < b.distance_squared_to(_last_noise_pos))
	return pts.slice(0, 3)


func _parent() -> Node:
	return spawn_parent if spawn_parent else get_parent()
