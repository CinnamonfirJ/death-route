class_name HoldTask
extends StaticBody2D
## Generic handyman job: walk up, hold [E] until the bar fills.
## The player's Tasking state calls begin / advance / interrupt.
## Working is noisy: noise_per_sec feeds the Noise Meter while you hold [E].

signal completed(task: HoldTask)
signal generator_started

## Each helping companion adds this much speed.
const HELPER_BONUS := 0.5
const HELPER_RADIUS := 80.0
## Progress lost when an infected helper fumbles.
const FUMBLE_LOSS := 0.08

@export var task_name := "Repair"
@export var waypoint_label := "JOB"
@export var duration := 6.0
@export var noise_per_sec := 5.0
@export var completion_noise := 20.0
## Fraction of progress lost when a hit interrupts you.
@export_range(0.0, 1.0) var damage_progress_loss := 0.25
@export var reward_scrap := 25
## Manifest tileset regions shown before/after (e.g. "pump_broken" -> "pump_working").
@export var tileset_id := "wasteland"
@export var broken_region := ""
@export var fixed_region := ""
## Resize the body collider to the sprite's footprint (generic task scene).
@export var fit_collision := false

@export_group("Generator")
@export var powers_generator := false
@export var generator_light_radius := 220.0
@export var generator_light_energy := 0.80
@export var generator_light_offset := Vector2(0, 30)
@export var generator_hum_range := 320.0
@export var generator_hum_db := -22.0
@export var generator_shake_pixels := 0.65
@export var generator_shake_hz := 8.0
var generator_running := false

var progress := 0.0
var is_completed := false
var _worker: Node = null

@onready var sprite: Sprite2D = $Sprite2D
var _shadow: Sprite2D


func _ready() -> void:
	add_to_group(&"tasks")
	add_to_group(&"nav_obstacle")
	if broken_region != "":
		_set_region(broken_region)


func _set_region(region: String) -> void:
	var tex := Assets.region_texture(tileset_id, region)
	sprite.texture = tex
	sprite.offset = Vector2(0, -tex.get_height() * 0.5 + 6.0)
	var shadow_size := Vector2(tex.get_width() * 1.1, maxf(tex.get_height() * 0.45, 12.0))
	if _shadow:
		_shadow.queue_free()
	_shadow = Fx.attach_shadow(self, shadow_size, Vector2(2, 4))
	if fit_collision:
		var rect := RectangleShape2D.new()
		rect.size = Vector2(maxf(tex.get_width() - 4.0, 12.0), maxf(tex.get_height() * 0.5, 10.0))
		var cs: CollisionShape2D = $CollisionShape2D
		cs.shape = rect
		cs.position = Vector2(0, 6.0 - rect.size.y * 0.5)


# ---------- Interaction ----------

func can_interact(player: Node) -> bool:
	if MatchState.active:
		return not MatchState.has_job(MatchState.team_of(player.get_multiplayer_authority()), task_name)
	# Online, several players may work the same job at once (it goes faster).
	return not is_completed and (_worker == null or Net.is_online())


func get_interact_prompt(_player: Node) -> String:
	if progress > 0.0:
		return "[Hold E] %s  (%d%%)" % [task_name, roundi(progress * 100.0)]
	return "[Hold E] %s" % task_name


func interact(player: Node) -> void:
	player.start_task(self)


# ---------- Driven by TaskingState ----------

func begin(worker: Node) -> void:
	_worker = worker
	EventBus.task_started.emit(self)


## Returns true when the task completes this tick.
func advance(delta: float) -> bool:
	if is_completed:
		return true
	var speed := GameManager.apply_stat(&"player.task_speed", 1.0)
	var noise_mult := GameManager.apply_stat(&"player.noise", 1.0)
	if MatchState.active:
		var t := MatchState.local_team()
		if Net.is_sim_authority():
			_work_team(delta, speed, t)
		else:
			_rpc_work_team.rpc_id(1, delta, speed)
		return MatchState.has_job(t, task_name)
	if not Net.is_sim_authority():
		# The host owns job progress; send our effort (with our own upgrades).
		_rpc_work.rpc_id(1, delta, speed, noise_mult)
		return is_completed
	return _work(delta, speed, noise_mult)


@rpc("any_peer", "unreliable_ordered")
func _rpc_work(delta: float, speed: float, noise_mult: float) -> void:
	if not is_completed:
		_work(delta, speed, noise_mult)


func _work(delta: float, speed: float, noise_mult: float) -> bool:
	var helpers := get_helpers()
	speed *= 1.0 + HELPER_BONUS * helpers.size()
	progress = minf(progress + delta / duration * speed, 1.0)
	# Infected helpers' hands shake: the "failing task" tell.
	for h in helpers:
		if randf() < h.fumble_chance() * delta:
			progress = maxf(progress - FUMBLE_LOSS, 0.0)
			h.say(["Sorry... my hands...", "Ugh. Dropped it.", "I'm fine. I'm FINE."].pick_random(),
				Color(0.85, 1.0, 0.7))
			EventBus.task_fumbled.emit(self, h)
	EventBus.noise_increased.emit(noise_per_sec * noise_mult * delta, global_position)
	_job_sound(delta)
	EventBus.task_progress.emit(self, progress)
	queue_redraw()
	if progress >= 1.0:
		_complete()
		return true
	_share_progress()
	return false


func _share_progress() -> void:
	if Net.is_host():
		_rpc_progress.rpc(progress)


@rpc("authority", "unreliable_ordered")
func _rpc_progress(p: float) -> void:
	progress = p
	queue_redraw()


var _sound_cd := 0.0


## Banging on a job carries: zombies within MatchConfig.sound_job come to look.
func _job_sound(delta: float) -> void:
	_sound_cd -= delta
	if _sound_cd <= 0.0:
		_sound_cd = 0.6
		EventBus.sound_made.emit(global_position, MatchConfig.get_config().sound_job)


# ---------- Versus: each team has its own progress on every job ----------

var _team_progress := {}


@rpc("any_peer", "unreliable_ordered")
func _rpc_work_team(delta: float, speed: float) -> void:
	if Net.is_host():
		_work_team(minf(delta, 0.1), speed, MatchState.team_of(multiplayer.get_remote_sender_id()))


func _work_team(delta: float, speed: float, team: int) -> void:
	if MatchState.has_job(team, task_name):
		return
	var p: float = minf(float(_team_progress.get(team, 0.0)) + delta / duration * speed, 1.0)
	EventBus.noise_increased.emit(noise_per_sec * delta, global_position)
	_job_sound(delta)
	if p >= 1.0:
		_team_progress.erase(team)
		MatchState.on_job_done(task_name, team)
		_rpc_team_done.rpc(team)
		_team_done(team)
		return
	_team_progress[team] = p
	_rpc_team_progress.rpc(team, p)
	_team_progress_local(team, p)


@rpc("authority", "unreliable_ordered")
func _rpc_team_progress(team: int, p: float) -> void:
	_team_progress_local(team, p)


func _team_progress_local(team: int, p: float) -> void:
	if team == MatchState.local_team():
		progress = p
		EventBus.task_progress.emit(self, progress)
		queue_redraw()


@rpc("authority", "reliable")
func _rpc_team_done(team: int) -> void:
	_team_done(team)


func _team_done(team: int) -> void:
	_start_generator()
	Sfx.play(&"task_done", global_position)
	Fx.glow(global_position + Vector2(0, -20), MatchState.team_color(team), 1.4, 0.5)
	if team == MatchState.local_team():
		progress = 0.0
		_worker = null
		EventBus.scrap_collected.emit(reward_scrap)
		EventBus.waypoint_cleared.emit(self)
		EventBus.task_completed.emit(self)
		queue_redraw()


## Rival sabotage: knock progress back (host applies it).
func sabotage(amount: float) -> void:
	if not Net.is_sim_authority():
		_rpc_sabotage.rpc_id(1, amount)
		return
	if is_completed:
		return
	progress = maxf(progress - amount, 0.0)
	queue_redraw()
	_share_progress()


@rpc("any_peer", "reliable")
func _rpc_sabotage(amount: float) -> void:
	sabotage(amount)


## Following companions close enough to lend a hand.
func get_helpers() -> Array:
	var out := []
	for c in get_tree().get_nodes_in_group(&"companions"):
		if c.is_following() and c.global_position.distance_to(global_position) <= HELPER_RADIUS:
			out.append(c)
	return out


func interrupt(by_damage: bool) -> void:
	_worker = null
	if by_damage and not MatchState.active:
		sabotage(damage_progress_loss)  # same effect: lose some progress (host-applied online)
	EventBus.task_interrupted.emit(self)


## Host decides completion; online every machine plays it and gets the job reward.
func _complete() -> void:
	if Net.is_host():
		_rpc_completed.rpc()
	_complete_local()


@rpc("authority", "reliable")
func _rpc_completed() -> void:
	_complete_local()


func _complete_local() -> void:
	if is_completed:
		return
	is_completed = true
	progress = 1.0
	_worker = null
	if fixed_region != "":
		_set_region(fixed_region)
	_start_generator()
	OneShotEffect.spawn(get_parent(), &"bullet_impact", global_position + Vector2(0, -24), 2.0)
	Fx.glow(global_position + Vector2(0, -20), Color(1.0, 0.85, 0.4), 1.4, 0.5)
	Sfx.play(&"task_done", global_position)
	if Net.is_sim_authority():
		EventBus.noise_increased.emit(completion_noise, global_position)
	EventBus.scrap_collected.emit(reward_scrap)
	EventBus.task_completed.emit(self)
	completed.emit(self)
	queue_redraw()


func _start_generator() -> void:
	if not powers_generator or generator_running:
		return
	generator_running = true
	var hum := Sfx.loop_player(&"generator_hum", self)
	if OS.has_feature("web"):
		hum.playback_type = AudioServer.PLAYBACK_TYPE_STREAM
	hum.max_distance = generator_hum_range
	hum.volume_db = generator_hum_db
	hum.play()
	var motion := sprite.create_tween().set_loops().set_trans(Tween.TRANS_SINE)
	var base := sprite.position
	var half_cycle := 0.5 / maxf(generator_shake_hz, 0.1)
	motion.tween_property(sprite, "position", base + Vector2(generator_shake_pixels, 0), half_cycle)
	motion.tween_property(sprite, "position", base - Vector2(generator_shake_pixels, 0), half_cycle)
	generator_started.emit()


# ---------- Progress bar ----------

func _draw() -> void:
	if is_completed or progress <= 0.0:
		return
	var height: float = sprite.texture.get_height() if sprite.texture else 32.0
	var top := -height - 2.0
	var r := Rect2(-16, top, 32, 4)
	draw_rect(r.grow(1.0), Color(0, 0, 0, 0.8))
	draw_rect(Rect2(r.position, Vector2(r.size.x * progress, r.size.y)), Color(1.0, 0.8, 0.2))
