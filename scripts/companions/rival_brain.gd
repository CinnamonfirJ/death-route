class_name RivalBrain
extends Node
## Hidden role, attached as a child of a Companion: this "survivor" secretly works
## for a rival courier outfit and sabotages the run when it thinks nobody's looking.
##
## Sabotage (one every cooldown_range seconds, when an opportunity fits):
##   in the car     -> siphon fuel over a few seconds, or jam the doors when zombies are close
##   you're working -> "accidentally" make a racket (noise burst = incoming wave)
##   on foot        -> pocket some of your scrap (takes a moment; can be caught in the act)
## Evidence: for evidence_time seconds after any sabotage, shining the flashlight on
## them exposes them. Exposed (or caught) rivals become a hostile Bandit with the stash.

const BANDIT := preload("res://scenes/companions/bandit.tscn")

@export var cooldown_range := Vector2(30.0, 55.0)
@export var evidence_time := 25.0
@export_group("Sabotage")
@export var drain_rate := 6.0
@export var drain_time := 4.0
@export var noise_burst := 25.0
@export var jam_time := 3.0
## Fraction of the run's scrap pocketed per skim.
@export var skim_ratio := 0.15
@export var skim_time := 1.5
@export_group("Being watched")
@export var watch_range := 170.0
@export var watch_half_angle_deg := 55.0

## Scrap stolen so far (dropped if they die, taken if they escape/are delivered).
var stash := 0
var exposed := false
var evidence_left := 0.0
var last_sabotage := ""

var _cd := 0.0
var _draining := 0.0
var _skimming := 0.0

@onready var c: Companion = get_parent()


func _ready() -> void:
	_cd = randf_range(cooldown_range.x * 0.4, cooldown_range.x)  # first move comes a bit sooner


func _physics_process(delta: float) -> void:
	if exposed or c.mode == Companion.Mode.DEAD:
		return
	evidence_left = maxf(evidence_left - delta, 0.0)
	if _draining > 0.0:
		_tick_drain(delta)
		return
	if _skimming > 0.0:
		_tick_skim(delta)
		return
	_cd -= delta
	if _cd > 0.0:
		return
	_cd = randf_range(cooldown_range.x, cooldown_range.y) if try_sabotage() else 2.0


## Picks a sabotage that fits right now. Returns true if one started.
func try_sabotage() -> bool:
	var player = c.get_tree().get_first_node_in_group(&"player")
	if player == null or player.is_dead():
		return false
	match c.mode:
		Companion.Mode.IN_CAR:
			var car = c.car
			if not is_instance_valid(car) or car.is_destroyed:
				return false
			if _zombies_near(car.global_position, 220.0) and randf() < 0.6:
				car.jam_doors(jam_time)
				_did("jam")
				return true
			if car.fuel > 15.0:
				_draining = drain_time
				_did("siphon")
				return true
		Companion.Mode.FOLLOW, Companion.Mode.WAIT:
			var dist: float = c.global_position.distance_to(player.global_position)
			if player.state_machine.current_name == &"Tasking" and dist < 220.0:
				c.say(["Oops!", "*drops a toolbox*", "Whoops. My bad."].pick_random())
				EventBus.noise_increased.emit(noise_burst, c.global_position)
				EventBus.sound_made.emit(c.global_position, 300.0)
				_did("noise")
				return true
			if GameManager.run_scrap >= 10 and dist < 200.0:
				_skimming = skim_time
				return true
	return false


func _did(kind: String) -> void:
	last_sabotage = kind
	evidence_left = evidence_time
	EventBus.rival_sabotaged.emit(c, kind)


func _tick_drain(delta: float) -> void:
	_draining -= delta
	var car = c.car
	if c.mode != Companion.Mode.IN_CAR or not is_instance_valid(car):
		_draining = 0.0
		return
	car.add_fuel(-drain_rate * delta)


## Pocketing scrap takes a moment. If the handyman is looking, they're caught.
func _tick_skim(delta: float) -> void:
	_skimming -= delta
	c.velocity = Vector2.ZERO
	if is_watched():
		_skimming = 0.0
		expose("caught pocketing your scrap")
		return
	if _skimming <= 0.0:
		var take := maxi(1, floori(GameManager.run_scrap * skim_ratio))
		take = mini(take, GameManager.run_scrap)
		stash += take
		EventBus.scrap_collected.emit(-take)
		_did("skim")


## The handyman is on foot, close, and aiming roughly at us.
func is_watched() -> bool:
	var player = c.get_tree().get_first_node_in_group(&"player")
	if player == null or not player.is_on_foot() or not c.visible:
		return false
	var to: Vector2 = c.global_position - player.global_position
	if to.length() > watch_range:
		return false
	var aim := Vector2.RIGHT.rotated(player.weapon.global_rotation)
	return absf(aim.angle_to(to)) <= deg_to_rad(watch_half_angle_deg)


## Flashlight check. Returns true if this exposed them (fresh evidence on them).
func on_flashlight() -> bool:
	if exposed:
		return true
	if evidence_left <= 0.0:
		return false
	var reason: String = {
		"siphon": "smells like gasoline",
		"skim": "has your scrap in their pockets",
		"noise": "was making noise on purpose",
		"jam": "had the car's door lock in their hand",
	}.get(last_sabotage, "was acting shifty")
	expose(reason)
	return true


func _zombies_near(pos: Vector2, radius: float) -> bool:
	for z in c.get_tree().get_nodes_in_group(&"zombies"):
		if z.global_position.distance_to(pos) < radius:
			return true
	return false


## Unmasks the rival: they become a hostile Bandit carrying the stash.
func expose(reason: String) -> void:
	if exposed:
		return
	exposed = true
	EventBus.rival_exposed.emit(c.display_name, reason)
	EventBus.hud_message.emit("%s %s! A rival courier!" % [c.display_name, reason])
	var spot: Vector2 = c.car.global_position + Vector2(-30, 10) if c.mode == Companion.Mode.IN_CAR \
		and is_instance_valid(c.car) else c.global_position
	if c.mode == Companion.Mode.IN_CAR and is_instance_valid(c.car):
		c.car.passengers.erase(c)
	var b = BANDIT.instantiate()
	b.display_name = c.display_name
	b.stash = stash
	b.position = spot
	c.get_parent().add_child(b)
	c.vanish()


## Delivered without being caught, they bolt with their stash plus this cut of
## the run's (remaining) scrap. Returns the cut; the stash is already gone.
func delivery_cut() -> int:
	return floori(GameManager.run_scrap * 0.2)
