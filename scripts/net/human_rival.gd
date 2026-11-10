extends Node
## Online "secret rival" role, attached to the rival's own handyman (only their machine
## knows). [G] / SABO sabotages whatever is closest:
##   a car        -> siphon fuel + jam its doors
##   a job        -> knock its progress back
##   nothing near -> make a racket (draws a wave)
## For EVIDENCE_TIME seconds afterwards, a teammate's flashlight exposes you.

const COOLDOWN := 35.0
const EVIDENCE_TIME := 25.0
const REACH := 70.0
const FUEL_DRAIN := 30.0
const JAM_TIME := 3.0
const JOB_SETBACK := 0.3
const NOISE := 30.0

var cooldown := 10.0
var evidence_left := 0.0
var last_kind := ""
var exposed := false
var uses := 0

@onready var player: Node2D = get_parent()


func _ready() -> void:
	EventBus.hud_message.emit.call_deferred(
		"You're the RIVAL. Sabotage with [G]. Don't get caught in a flashlight.")


func _process(delta: float) -> void:
	cooldown = maxf(cooldown - delta, 0.0)
	evidence_left = maxf(evidence_left - delta, 0.0)
	if Input.is_action_just_pressed(&"sabotage"):
		try_sabotage()


## Returns what was sabotaged ("siphon", "undo", "noise") or "" if not possible right now.
func try_sabotage() -> String:
	if exposed or player.is_dead():
		return ""
	if cooldown > 0.0:
		EventBus.hud_message.emit("Lie low: sabotage ready in %ds." % ceili(cooldown))
		return ""
	var kind := ""
	var car := _nearest(&"cars", func(c) -> bool: return not c.is_destroyed)
	var job := _nearest(&"tasks", func(t) -> bool: return not t.is_completed)
	if car:
		car.add_fuel(-FUEL_DRAIN)
		car.jam_doors(JAM_TIME)
		kind = "siphon"
	elif job:
		job.sabotage(JOB_SETBACK)
		kind = "undo"
	else:
		EventBus.noise_increased.emit(NOISE, player.global_position)
		kind = "noise"
	cooldown = COOLDOWN
	evidence_left = EVIDENCE_TIME
	last_kind = kind
	uses += 1
	EventBus.hud_message.emit({"siphon": "Fuel siphoned, doors jammed.", "undo": "Job sabotaged.",
		"noise": "That'll bring them running."}[kind])
	return kind


## A teammate's flashlight landed on us. Fresh evidence = exposed.
func on_flashlight() -> void:
	if exposed or evidence_left <= 0.0:
		return
	exposed = true
	var reason: String = {"siphon": "smells like gasoline", "undo": "has grease on their hands",
		"noise": "was making noise on purpose"}.get(last_kind, "was acting shifty")
	Net.report_rival_exposed(reason)


func _nearest(group: StringName, ok: Callable) -> Node2D:
	var best: Node2D = null
	var best_d := REACH
	for n in get_tree().get_nodes_in_group(group):
		if not ok.call(n):
			continue
		var d: float = n.global_position.distance_to(player.global_position)
		if d <= best_d:
			best_d = d
			best = n
	return best
