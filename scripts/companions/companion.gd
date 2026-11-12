class_name Companion
extends CharacterBody2D
## AI survivor. Follows the handyman, rides in the car, shoots nearby zombies,
## helps with tasks, shares ammo, and can revive the player once.
##
## The "Among Us" part: a companion can be secretly infected (bitten by a zombie,
## or already bitten when recruited). Infection is never shown directly. Tells:
##   - coughing (more often as it progresses; healthy people cough too, rarely)
##   - fumbling tasks they help with (HoldTask asks fumble_chance())
##   - flinching from the flashlight (healthy companions only complain)
## At 100% they turn: in the car they attack from the back seat; on foot they
## become a Latcher; left waiting far away they turn harmlessly out of reach.

signal turned(companion: Companion)

const NAMES := ["Dale", "Marisol", "Big Tony", "Priya", "Gus", "Wendell", "Okafor", "Lou",
	"Bea", "Hector", "Nadia", "Skip", "Ruthie", "Vince"]
const LATCHER := preload("res://scenes/zombies/latcher.tscn")
const HIT_MASK := 1 | 8  # world + zombies

enum Mode { SURVIVOR, FOLLOW, WAIT, IN_CAR, DEAD }

@export var character_id: StringName = &"npc_companion_a"
## Leave empty for a random name.
@export var display_name := ""
@export var max_hp := 60.0
@export var move_speed := 95.0
@export var follow_distance := 34.0
@export_group("Combat")
@export var shoot_range := 150.0
@export var shoot_interval := 1.4
@export var shoot_damage := 8.0
@export var shoot_noise := 5.0
@export var ammo_to_share := 24
@export_group("Infection")
@export_range(0.0, 1.0) var start_infected_chance := 0.0
## Seconds from bite to turning.
@export var turn_time_range := Vector2(120.0, 200.0)
## Debug: tint infected companions so you can see who's who.
@export var reveal_infection := false

var mode: Mode = Mode.SURVIVOR
var hp: float
var infected := false
## 0..1 progress toward turning. Hidden from the player.
var infection := 0.0
var is_turned := false
var revive_available := true
## The Car we're riding in (untyped: avoids a cyclic class dependency with Car).
var car = null

var _turn_time := 160.0
var _ordered_wait := false
var _cough_left := 0.0
var _shoot_cd := 0.0
var _share_cd := 0.0
var _flinch_cd := 0.0
var _backseat_cd := 0.0
var _repath_cd := 0.0
var _flash_tween: Tween

@onready var sprite: AnimatedSprite2D = $AnimatedSprite2D
@onready var collision: CollisionShape2D = $CollisionShape2D
@onready var nav: NavigationAgent2D = $NavigationAgent2D
@onready var interact_zone: Area2D = $InteractZone


func _ready() -> void:
	add_to_group(&"companions")
	if display_name == "":
		display_name = NAMES.pick_random()
	sprite.sprite_frames = Assets.character_frames(character_id)
	sprite.play(&"idle")
	Fx.attach_shadow(self, Vector2(22, 9))
	hp = max_hp
	if randf() < start_infected_chance:
		infect(randf_range(0.15, 0.45))
	_cough_left = _next_cough_delay()


# ---------- Party control ----------

func join() -> void:
	mode = Mode.FOLLOW
	_ordered_wait = false
	EventBus.companion_recruited.emit(self)
	EventBus.waypoint_cleared.emit(self)
	say(["Finally. Let's go.", "You're the delivery guy? Perfect.", "I can shoot. Mostly."].pick_random())


## Secretly a rival courier? (Has a RivalBrain child.)
func is_rival() -> bool:
	return has_node(^"RivalBrain")


func rival_brain() -> RivalBrain:
	return get_node_or_null(^"RivalBrain") as RivalBrain


## Leaves the world without death effects (used when a rival is unmasked).
func vanish() -> void:
	mode = Mode.DEAD
	remove_from_group(&"companions")
	queue_free()


func is_following() -> bool:
	return mode == Mode.FOLLOW


func is_in_party() -> bool:
	return mode == Mode.FOLLOW or mode == Mode.WAIT or mode == Mode.IN_CAR


func can_interact(_player: Node) -> bool:
	# No "wait here" order: a following companion has nothing to interact with.
	return mode == Mode.SURVIVOR or mode == Mode.WAIT


func get_interact_prompt(_player: Node) -> String:
	match mode:
		Mode.SURVIVOR:
			return "[E] Recruit %s" % display_name if Companion.party_size(get_tree()) < 3 \
				else "Car's full (3 seats)"
		_:
			return "[E] Call %s back" % display_name


func interact(_player: Node) -> void:
	match mode:
		Mode.SURVIVOR:
			if Companion.party_size(get_tree()) < 3:
				join()
		Mode.WAIT:
			mode = Mode.FOLLOW
			_ordered_wait = false
			say("Right behind you.")


static func party_size(tree: SceneTree) -> int:
	var n := 0
	for c in tree.get_nodes_in_group(&"companions"):
		if c.is_in_party():
			n += 1
	return n


# ---------- Car ----------

func board(c) -> void:
	car = c
	mode = Mode.IN_CAR
	visible = false
	velocity = Vector2.ZERO
	collision.set_deferred(&"disabled", true)
	interact_zone.set_deferred(&"monitorable", false)


## Called when the driver gets out (or the car is destroyed).
func disembark(spot: Vector2, damage := 0.0) -> void:
	car = null
	global_position = spot
	if is_turned:
		_become_zombie()
		return
	mode = Mode.FOLLOW
	visible = true
	collision.set_deferred(&"disabled", false)
	interact_zone.set_deferred(&"monitorable", true)
	if damage > 0.0:
		take_damage(damage)


# ---------- Main loop ----------

func _physics_process(delta: float) -> void:
	if mode == Mode.DEAD:
		return
	_shoot_cd -= delta
	_share_cd -= delta
	_flinch_cd -= delta
	_repath_cd -= delta
	if infected and not is_turned:
		infection += delta / _turn_time
		if reveal_infection:
			sprite.self_modulate = Color(0.7, 1.0, 0.6)
		elif infection > 0.8:
			sprite.self_modulate = Color(0.92, 1.0, 0.9)  # very late, very subtle tint
		if infection >= 1.0:
			_turn()
			return
	_tick_cough(delta)

	match mode:
		Mode.IN_CAR:
			if is_instance_valid(car):
				global_position = car.global_position
			if is_turned:
				_backseat_attack(delta)
			return
		Mode.FOLLOW:
			_follow()
			_maybe_shoot()
			_maybe_share_ammo()
		Mode.WAIT:
			velocity = velocity.move_toward(Vector2.ZERO, 600.0 * delta)
			_maybe_shoot()
			_maybe_rejoin()
		Mode.SURVIVOR:
			velocity = velocity.move_toward(Vector2.ZERO, 600.0 * delta)
	move_and_slide()
	_animate()


## The Player (untyped so its methods are called dynamically).
func _player():
	return get_tree().get_first_node_in_group(&"player")


func _follow() -> void:
	var player = _player()
	if player == null or player.is_dead():
		velocity = Vector2.ZERO
		return
	if player.current_car != null:
		# Player drove off without us.
		mode = Mode.WAIT
		_ordered_wait = false
		say("HEY! WAIT FOR ME!")
		EventBus.hud_message.emit("%s was left behind." % display_name)
		return
	var d := global_position.distance_to(player.global_position)
	if d <= follow_distance:
		velocity = velocity.move_toward(Vector2.ZERO, 40.0)
		return
	var speed := move_speed * (1.4 if d > 150.0 else 1.0)
	velocity = _steer_to(player.global_position, speed)


## Involuntarily left behind: rejoin when the handyman comes back on foot.
func _maybe_rejoin() -> void:
	if _ordered_wait:
		return
	var player = _player()
	if player and player.is_on_foot() and global_position.distance_to(player.global_position) < 90.0:
		mode = Mode.FOLLOW
		say("Don't do that again.")


func _steer_to(pos: Vector2, speed: float) -> Vector2:
	if global_position.distance_to(pos) < 48.0:
		return global_position.direction_to(pos) * speed
	if _repath_cd <= 0.0:
		_repath_cd = 0.3
		nav.target_position = pos
	var next := nav.get_next_path_position()
	if nav.is_navigation_finished() or next.distance_squared_to(global_position) < 1.0:
		return global_position.direction_to(pos) * speed
	return global_position.direction_to(next) * speed


func _animate() -> void:
	if absf(velocity.x) > 1.0:
		sprite.flip_h = velocity.x > 0.0
	var moving := velocity.length() > 5.0
	sprite.speed_scale = 2.0 if moving else 1.0
	# NPC sheets have no run cycle; bob while walking instead.
	sprite.position.y = -absf(sin(Time.get_ticks_msec() * 0.018)) * 2.0 if moving else 0.0


# ---------- Helping ----------

func _maybe_shoot() -> void:
	if _shoot_cd > 0.0:
		return
	var best: Node2D = null
	var best_d := shoot_range
	for z in get_tree().get_nodes_in_group(&"zombies"):
		var d: float = global_position.distance_to(z.global_position)
		if d < best_d:
			best_d = d
			best = z
	if best == null:
		return
	_shoot_cd = shoot_interval * randf_range(0.8, 1.2)
	var from := global_position + Vector2(0, -12)
	var to: Vector2 = best.global_position + Vector2(0, -8)
	var query := PhysicsRayQueryParameters2D.create(from, to + from.direction_to(to) * 20.0, HIT_MASK)
	var hit := get_world_2d().direct_space_state.intersect_ray(query)
	if hit and hit.collider.has_method(&"take_damage"):
		hit.collider.take_damage(shoot_damage, from.direction_to(to) * 60.0)
		to = hit.position
	var line := Line2D.new()
	line.width = 1.0
	line.default_color = Color(1.0, 0.92, 0.6, 0.8)
	line.points = PackedVector2Array([from, to])
	line.z_index = 4
	get_parent().add_child(line)
	var t := line.create_tween()
	t.tween_property(line, "modulate:a", 0.0, 0.08)
	t.tween_callback(line.queue_free)
	EventBus.noise_increased.emit(shoot_noise, global_position)
	EventBus.sound_made.emit(global_position, MatchConfig.get_config().sound_gunshot)


func _maybe_share_ammo() -> void:
	if _share_cd > 0.0 or ammo_to_share <= 0 or is_rival():
		return  # tell: a rival never shares
	var player = _player()
	if player == null or not player.is_on_foot():
		return
	var w = player.weapon
	if w.in_mag + w.reserve >= 10:
		return
	var give := mini(12, ammo_to_share)
	ammo_to_share -= give
	w.add_ammo(give)
	_share_cd = 20.0
	say("Here, take some of mine.")


## Chance per second that this helper fumbles a task. Healthy hands never do.
func fumble_chance() -> float:
	return infection * 0.6 if infected else 0.0


## Revives the downed handyman (once per companion). Returns true if it happened.
func try_revive(player: Node2D) -> bool:
	if is_rival():
		return false  # tell: a rival lets you die
	if not revive_available or is_turned or mode == Mode.DEAD or mode == Mode.SURVIVOR:
		return false
	if mode != Mode.IN_CAR and global_position.distance_to(player.global_position) > 220.0:
		return false
	revive_available = false
	say(["Not today!", "Get UP. We have a delivery.", "Breathe, damn it!"].pick_random())
	return true


# ---------- Infection ----------

func infect(start_progress := 0.0) -> void:
	if infected or mode == Mode.DEAD:
		return
	infected = true
	infection = start_progress
	_turn_time = randf_range(turn_time_range.x, turn_time_range.y)
	EventBus.companion_bitten.emit(self)


func _next_cough_delay() -> float:
	if infected:
		return randf_range(0.6, 1.4) * lerpf(24.0, 6.0, infection)
	return randf_range(50.0, 110.0)  # red herring: everyone coughs sometimes


func _tick_cough(delta: float) -> void:
	_cough_left -= delta
	if _cough_left > 0.0:
		return
	_cough_left = _next_cough_delay()
	Sfx.play(&"cough", _speech_anchor(), -2.0 if infected else -6.0)
	if infected and infection > 0.55:
		say(["*cough* *cough*", "*hacking cough*", "*wet cough*"].pick_random(), Color(0.75, 0.9, 0.6))
		OneShotEffect.spawn(get_parent(), &"popup_3", _speech_anchor() + Vector2(14, 8), 1.0, 0.8)
	else:
		say("*cough*", Color(0.85, 0.85, 0.8))


## Flashlight check. Infected flinch and back off; healthy ones just complain.
func on_flashlight(source: Vector2) -> void:
	if mode == Mode.IN_CAR or mode == Mode.DEAD:
		return
	# A rival with fresh evidence on them is exposed on the spot.
	if is_rival() and rival_brain().on_flashlight():
		return
	if _flinch_cd > 0.0:
		return
	_flinch_cd = 2.5
	if infected:
		say(["Get that outta my face!", "Ngh... too bright.", "Turn it OFF."].pick_random(), Color(0.85, 1.0, 0.7))
		velocity = source.direction_to(global_position) * 160.0
		var t := create_tween()
		t.tween_property(sprite, "rotation", 0.35, 0.06)
		t.tween_property(sprite, "rotation", -0.35, 0.08)
		t.tween_property(sprite, "rotation", 0.0, 0.06)
		EventBus.companion_flinched.emit(self)
	else:
		say(["Hey.", "What?", "I'm fine. Relax.", "You're blinding me, man."].pick_random())


func _turn() -> void:
	is_turned = true
	EventBus.companion_turned.emit(self)
	turned.emit(self)
	if mode == Mode.IN_CAR:
		_backseat_cd = 0.0
		EventBus.hud_message.emit("SOMETHING IN THE BACK SEAT!")
		return
	var player = _player()
	var far: bool = player == null or global_position.distance_to(player.global_position) > 450.0
	if mode == Mode.WAIT and far:
		EventBus.hud_message.emit("Somewhere behind you, %s stopped answering." % display_name)
	_become_zombie()


## Turned in the car: chews on the car and the driver until someone gets out.
func _backseat_attack(delta: float) -> void:
	_backseat_cd -= delta
	if _backseat_cd > 0.0 or not is_instance_valid(car):
		return
	_backseat_cd = 0.6
	car.take_damage(5.0)
	if car.driver:
		car.driver.take_damage(4.0)
	EventBus.screen_shake_requested.emit(2.5, 0.1)


func _become_zombie() -> void:
	var parent := get_parent()
	var z: Node2D = LATCHER.instantiate()
	z.position = global_position
	parent.add_child(z)
	OneShotEffect.spawn(parent, &"popup_3", global_position + Vector2(0, -36), 1.2, 1.0)
	EventBus.hud_message.emit("%s turned!" % display_name)
	mode = Mode.DEAD
	queue_free()


# ---------- Health ----------

func take_damage(amount: float, knockback := Vector2.ZERO) -> void:
	if mode == Mode.DEAD or mode == Mode.IN_CAR:
		return
	hp -= amount
	velocity += knockback
	_flash()
	if hp <= 0.0:
		die(false)


## A zombie's melee on this companion. Might be a bite.
func bitten(damage: float, chance: float) -> void:
	take_damage(damage)
	if mode != Mode.DEAD and randf() < chance:
		infect()


## Player bullets route here (Weapon checks for this method).
func hit_by_player(amount: float, knockback := Vector2.ZERO) -> void:
	if mode == Mode.DEAD:
		return
	hp -= amount
	velocity += knockback
	_flash()
	if hp <= 0.0:
		die(true)
	else:
		say(["OW! Watch it!", "Whose side are you on?!", "Friendly fire!"].pick_random())


func die(by_player: bool) -> void:
	if mode == Mode.DEAD:
		return
	mode = Mode.DEAD
	remove_from_group(&"companions")
	collision.set_deferred(&"disabled", true)
	interact_zone.set_deferred(&"monitorable", false)
	EventBus.companion_died.emit(self, by_player)
	var brain := rival_brain()
	if brain:
		if brain.stash > 0:
			Pickup.drop(get_parent(), Pickup.Kind.SCRAP, brain.stash, global_position)
		if by_player:
			EventBus.hud_message.emit("%s was a rival courier. Their pockets are full of your scrap." % display_name)
			EventBus.rival_stopped.emit(display_name, brain.stash)
		by_player = false  # skip the innocent/infected messages below
	if by_player:
		if infected:
			EventBus.hud_message.emit("You put %s down. They were turning. Good call." % display_name)
			EventBus.scrap_collected.emit(10)
		else:
			EventBus.hud_message.emit("%s was fine. %s was FINE." % [display_name, display_name])
	var t := create_tween()
	t.tween_property(sprite, "rotation", PI * 0.5, 0.3)
	if infected and not by_player:
		# Bitten corpses get back up.
		t.tween_interval(3.0)
		t.tween_callback(_become_zombie)
	else:
		t.tween_interval(6.0)
		t.tween_property(sprite, "modulate:a", 0.0, 1.0)
		t.tween_callback(queue_free)


func heal(amount: float) -> void:
	hp = minf(hp + amount, max_hp)


func _flash() -> void:
	if _flash_tween:
		_flash_tween.kill()
	sprite.modulate = Color(1.0, 0.4, 0.4)
	_flash_tween = create_tween()
	_flash_tween.tween_property(sprite, "modulate", Color.WHITE, 0.15)


# ---------- Speech ----------

func _speech_anchor() -> Vector2:
	var base: Vector2 = car.global_position if mode == Mode.IN_CAR and is_instance_valid(car) else global_position
	return base + Vector2(0, -38)


## Floating line above the companion (or the car, from the back seat).
func say(text: String, color := Color(0.95, 0.95, 0.9)) -> void:
	var parent := get_parent()
	if parent == null:
		return
	var label := Label.new()
	label.text = text
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	label.custom_minimum_size = Vector2(140, 0)
	label.add_theme_font_size_override(&"font_size", 8)
	label.add_theme_color_override(&"font_color", color)
	label.add_theme_color_override(&"font_outline_color", Color.BLACK)
	label.add_theme_constant_override(&"outline_size", 3)
	label.z_index = 20
	label.position = _speech_anchor() + Vector2(-70, 0)
	parent.add_child(label)
	var t := label.create_tween()
	t.tween_interval(1.6)
	t.set_parallel(true)
	t.tween_property(label, "position:y", label.position.y - 10.0, 0.6)
	t.tween_property(label, "modulate:a", 0.0, 0.6)
	t.set_parallel(false)
	t.tween_callback(label.queue_free)
	EventBus.companion_said.emit(self, text)
