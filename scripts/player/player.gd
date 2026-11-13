class_name Player
extends CharacterBody2D
## The Handyman. Behaviour lives in StateMachine children (OnFoot, Driving, Dead);
## this script holds shared data and helpers the states use.

@export var max_hp := 100.0
@export var walk_speed := 80.0
@export var sprint_speed := 130.0
@export var acceleration := 900.0
@export var character_id: StringName
## Noise added per second while sprinting (consumed by the Noise Meter in Phase 3).
@export var sprint_noise_per_sec := 4.0

const REVIVE_HP_RATIO := 0.35
## Online: seconds a teammate holds [E] to revive you.
const REVIVE_TIME := 3.0
const AMMO_GIFT := 12

var hp: float
var current_car: Car = null
var _invuln := 0.0

## Revive acts like a HoldTask (TaskingState drives these on the reviver's machine).
var progress := 0.0
var is_completed := false
var task_name: String:
	get:
		return "Reviving %s" % display_name()

## Touch controls (set by TouchControls). In touch mode, aim comes from the right
## stick instead of the mouse, and holding the stick fires.
var touch_mode := false
var touch_aim := Vector2.RIGHT
var touch_fire := false

var _flash_tween: Tween
## Crouching: slower, silent footsteps (zombies can't hear you).
var crouching := false

@onready var sprite: AnimatedSprite2D = $AnimatedSprite2D
@onready var collision: CollisionShape2D = $CollisionShape2D
@onready var interact_area: Area2D = $InteractArea
@onready var state_machine: StateMachine = $StateMachine
@onready var weapon: Weapon = $Weapon
@onready var interact_zone: Area2D = $InteractZone
@onready var _crew_health: Range = $CrewHealth


func _enter_tree() -> void:
	# Online, "Player_<peer id>" belongs to that peer; the scene's own "Player" is the host's.
	if String(name).begins_with("Player_"):
		set_multiplayer_authority(String(name).trim_prefix("Player_").to_int())


func _ready() -> void:
	max_hp = GameManager.apply_stat(&"player.max_hp", max_hp)
	sprint_noise_per_sec = GameManager.apply_stat(&"player.noise", sprint_noise_per_sec)
	hp = max_hp
	_crew_health.visible = false
	var tag: Node2D = load("res://scripts/player/player_health_bar.gd").new()
	tag.name = "HealthTag"
	tag.player = self
	tag.bar = _crew_health
	add_child(tag)
	if MatchState.active:
		_invuln = MatchState.cfg.spawn_protection
	if character_id == &"":
		character_id = Net.peer_character(1) if Net.is_online() else GameManager.selected_character
	sprite.sprite_frames = Assets.character_frames(character_id)
	sprite.play(&"idle")
	Fx.attach_shadow(self, Vector2(22, 9))
	add_to_group(&"player")
	interact_zone.monitorable = Net.is_online()  # teammates can give ammo / revive
	Net.attach_sync(self,
		[".:position", "AnimatedSprite2D:animation", "AnimatedSprite2D:flip_h", "Weapon:rotation", "Flashlight:rotation"],
		[".:visible", ".:hp", ".:max_hp", "Weapon:visible", "Weapon:knife_equipped", "Weapon:display_id",
			"AnimatedSprite2D:speed_scale", "AnimatedSprite2D:scale", "Flashlight:active"])
	if Net.is_local_authority(self):
		# Hear the world from your own handyman (voice chat, zombie sounds pan around you).
		var ears := AudioListener2D.new()
		ears.name = "Ears"
		add_child(ears)
		ears.make_current()
		EventBus.player_damaged.emit.call_deferred(0.0, hp)  # sync HUD bar to upgraded max
		if Net.is_online():
			Net.local_player_spawned.emit.call_deferred(self)
			if Net.role == "rival":
				var rival: Node = load("res://scripts/net/human_rival.gd").new()
				rival.name = "HumanRival"
				add_child(rival)


func display_name() -> String:
	return Net.peer_name(get_multiplayer_authority()) if Net.is_online() else GameManager.display_name()


## Auto-aim: max distance and how far off the crosshair a zombie can be to get locked.
const AUTO_AIM_RANGE := 280.0
const AUTO_AIM_CONE_DEG := 28.0

## The current auto-aim target. The local reticle changes color when aim is assisted.
var aim_target: Node2D = null


## World point the handyman is aiming at: mouse or touch stick, snapped to the
## zombie nearest the crosshair when auto-aim is on (raw = ignore auto-aim).
func get_aim_point(raw := false) -> Vector2:
	var origin := global_position + Vector2(0, -11)
	var base := origin + touch_aim * 120.0 if touch_mode else get_global_mouse_position()
	if raw:
		return base
	aim_target = null
	if not GameManager.get_setting("auto_aim"):
		return base
	var dir := (base - origin).normalized()
	var best_score := INF
	for group in [&"zombies", &"hostiles"]:
		for z in get_tree().get_nodes_in_group(group):
			if z.is_dead:
				continue
			var to: Vector2 = z.global_position + Vector2(0, -10) - origin
			var d := to.length()
			if d > AUTO_AIM_RANGE:
				continue
			var ang := absf(dir.angle_to(to))
			if ang > deg_to_rad(AUTO_AIM_CONE_DEG):
				continue
			var score := ang * 200.0 + d * 0.3  # near the crosshair first, then nearer
			if score < best_score:
				best_score = score
				aim_target = z
	return aim_target.global_position + Vector2(0, -10) if aim_target else base


func is_dead() -> bool:
	return hp <= 0.0


func is_on_foot() -> bool:
	return state_machine.current_name == &"OnFoot"


func enter_car(car: Car) -> void:
	if not is_on_foot() or not car.can_interact(self):
		return
	if car.is_door_jammed():
		EventBus.hud_message.emit("The door's jammed!")
		return
	state_machine.transition_to(&"Driving", {"car": car})


## Leaves the current car if possible (same rules as pressing [E]).
func exit_car() -> bool:
	if state_machine.current_name != &"Driving":
		return false
	return state_machine.current.try_exit()


## Called by a task's interact(). Holding [E] in the Tasking state progresses it.
func start_task(task: Node) -> void:
	if not is_on_foot():
		return
	state_machine.transition_to(&"Tasking", {"task": task})


func take_damage(amount: float, knockback := Vector2.ZERO, acid := false) -> void:
	if not Net.is_local_authority(self):
		_rpc_take_damage.rpc_id(get_multiplayer_authority(), amount, knockback, acid)
		return
	if is_dead() or _invuln > 0.0:
		return
	if hp - amount <= 0.0 and _try_companion_revive():
		return
	hp = maxf(hp - amount, 0.0)
	velocity += knockback
	if acid:
		Sfx.play(&"acid_tick", global_position)
		Pickup.float_text(self, "-%d ACID" % roundi(amount), Color("#c2f186"))
	else:
		Fx.blood(global_position + Vector2(0, -12), knockback, 6)
		Sfx.play(&"player_hurt", global_position)
	EventBus.player_damaged.emit(amount, hp)
	EventBus.screen_shake_requested.emit(3.0, 0.12)
	_flash(Color("#9de65b") if acid else Color(1.0, 0.35, 0.35))
	if is_dead():
		state_machine.transition_to(&"Dead")


## An ally drags you back up instead of dying (once per companion per run).
func _try_companion_revive() -> bool:
	for c in get_tree().get_nodes_in_group(&"companions"):
		if c.try_revive(self):
			hp = max_hp * REVIVE_HP_RATIO
			_invuln = 1.5
			EventBus.player_damaged.emit(0.0, hp)
			EventBus.hud_message.emit("%s dragged you back up!" % c.display_name)
			EventBus.screen_shake_requested.emit(6.0, 0.3)
			return true
	return false


func _physics_process(delta: float) -> void:
	_invuln = maxf(_invuln - delta, 0.0)
	if not Net.is_local_authority(self):
		# Someone else's handyman: no physics here, but don't block anything while
		# they're inside a car (invisible) or downed.
		var off := not visible or is_dead()
		if collision.disabled != off:
			collision.set_deferred(&"disabled", off)


# ---------- Online: forwarded damage, revive, ammo gifts, flashlight ----------

@rpc("any_peer", "reliable")
func _rpc_take_damage(amount: float, knockback: Vector2, acid := false) -> void:
	if MatchState.active and multiplayer.get_remote_sender_id() != 1:
		return  # versus: only the host's simulation may hurt you
	take_damage(amount, knockback, acid and multiplayer.get_remote_sender_id() == 1)


func can_interact(other: Node) -> bool:
	if MatchState.active:
		# Versus: no revives (you respawn); ammo only for teammates.
		return other != self and visible and not is_dead() 			and not MatchState.are_enemies(other.get_multiplayer_authority(), get_multiplayer_authority())
	return Net.is_online() and other != self and visible


func get_interact_prompt(other: Node) -> String:
	if is_dead():
		return "[Hold E] Revive %s" % display_name()
	if other.weapon.reserve >= AMMO_GIFT:
		return "[E] Give %d ammo to %s" % [AMMO_GIFT, display_name()]
	return "No spare ammo for %s" % display_name()


func interact(other: Node) -> void:
	if is_dead():
		progress = 0.0
		is_completed = false
		other.start_task(self)
		return
	if other.weapon.reserve < AMMO_GIFT:
		return
	other.weapon.reserve -= AMMO_GIFT
	other.weapon._emit_ammo()
	_rpc_receive_ammo.rpc_id(get_multiplayer_authority(), AMMO_GIFT, other.display_name())
	Pickup.float_text(self, "+%d ammo" % AMMO_GIFT, Color(0.8, 0.9, 1.0))


@rpc("any_peer", "reliable")
func _rpc_receive_ammo(amount: int, from_name: String) -> void:
	weapon.add_ammo(amount)
	EventBus.hud_message.emit("%s gave you %d ammo." % [from_name, amount])


# ---------- Versus: knife hits (host-validated) + respawns ----------

## Host: a validated knife hit on this player. Damage is applied by the owner's machine.
func receive_pvp_hit(amount: float, knockback: Vector2, attacker: int) -> void:
	if Net.is_local_authority(self):
		_apply_pvp_hit(amount, knockback, attacker)
	else:
		_rpc_pvp_hit.rpc_id(get_multiplayer_authority(), amount, knockback, attacker)


@rpc("any_peer", "reliable")
func _rpc_pvp_hit(amount: float, knockback: Vector2, attacker: int) -> void:
	# Only the host (the referee) may deal PvP damage.
	if multiplayer.get_remote_sender_id() == 1:
		_apply_pvp_hit(amount, knockback, attacker)


func _apply_pvp_hit(amount: float, knockback: Vector2, attacker: int) -> void:
	if is_dead():
		return
	take_damage(amount, knockback)
	if attacker != 0 and not is_dead():
		EventBus.hud_message.emit("%s is knifing you!" % Net.peer_name(attacker))


## Owner: come back to life at `pos` with brief spawn protection.
func respawn_at(pos: Vector2, protection: float) -> void:
	if current_car:
		exit_car()
	global_position = pos
	velocity = Vector2.ZERO
	hp = max_hp
	_invuln = protection
	state_machine.transition_to(&"OnFoot")
	EventBus.player_damaged.emit(0.0, hp)
	EventBus.hud_message.emit("Back in the fight.")
	EventBus.screen_shake_requested.emit(2.0, 0.15)


@rpc("any_peer", "reliable")
func _rpc_respawn(pos: Vector2, protection: float) -> void:
	if multiplayer.get_remote_sender_id() == 1:
		respawn_at(pos, protection)


func is_protected() -> bool:
	return _invuln > 0.0


# HoldTask-style hooks so TaskingState can drive a revive.
func begin(_worker: Node) -> void:
	pass


func advance(delta: float) -> bool:
	if not is_dead():
		is_completed = true
		return true
	progress = minf(progress + delta / REVIVE_TIME, 1.0)
	if progress >= 1.0:
		is_completed = true
		progress = 0.0
		_rpc_revive.rpc_id(get_multiplayer_authority(), Net.peer_name(Net.local_id()))
		return true
	return false


func interrupt(_by_damage: bool) -> void:
	progress = 0.0


@rpc("any_peer", "reliable")
func _rpc_revive(by_name: String) -> void:
	if not is_dead():
		return
	hp = max_hp * REVIVE_HP_RATIO
	_invuln = 1.5
	state_machine.transition_to(&"OnFoot")
	EventBus.player_damaged.emit(0.0, hp)
	EventBus.hud_message.emit("%s got you back on your feet!" % by_name)
	Net.report_down(false)


## A teammate's flashlight is on us. Only matters if we're the rival with fresh evidence.
func on_flashlight(_source: Vector2) -> void:
	if Net.is_online() and not Net.is_local_authority(self):
		_rpc_flashlit.rpc_id(get_multiplayer_authority())


@rpc("any_peer", "reliable")
func _rpc_flashlit() -> void:
	var rival := get_node_or_null(^"HumanRival")
	if rival:
		rival.on_flashlight()


func heal(amount: float) -> void:
	hp = minf(hp + amount, max_hp)
	EventBus.player_damaged.emit(-amount, hp)


## Shows/hides the body and toggles collision + interaction (used when entering cars).
func set_body_enabled(enabled: bool) -> void:
	visible = enabled
	weapon.visible = enabled
	collision.set_deferred(&"disabled", not enabled)
	interact_area.set_deferred(&"monitoring", enabled)


## Nearest object in reach that implements interact(player) and allows it.
func get_best_interactable() -> Node:
	if not interact_area.monitoring:
		return null  # re-enabled deferred right after leaving a car
	var best: Node = null
	var best_d := INF
	for area in interact_area.get_overlapping_areas():
		var target: Node = area if area.has_method(&"interact") else area.get_parent()
		if target == self or not target.has_method(&"interact"):
			continue
		if target.has_method(&"can_interact") and not target.can_interact(self):
			continue
		var d := global_position.distance_squared_to(area.global_position)
		if d < best_d:
			best_d = d
			best = target
	return best


func _flash(tint := Color(1.0, 0.35, 0.35)) -> void:
	if _flash_tween:
		_flash_tween.kill()
	sprite.modulate = tint
	_flash_tween = create_tween()
	_flash_tween.tween_property(sprite, "modulate", Color.WHITE, 0.2)
