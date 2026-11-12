extends SceneTree
## Versus test, HOST side (Team Deathmatch on Route 9). Run vs_client.gd alongside.
## Run with tests/run_versus_tests.ps1 (starts the host + client processes).

var results := {}
var feed: Array[String] = []
var net
var ms
var gm


func _initialize() -> void:
	_run.call_deferred()
	create_timer(150.0, true, true).timeout.connect(func() -> void:
		print("HOST TIMEOUT"); _report(); quit(2))


func _check(name: String, ok: bool, info := "") -> void:
	results[name] = ok
	print(("PASS " if ok else "FAIL ") + "[host] " + name + ("  (" + info + ")" if info != "" else ""))


func _wait(s: float) -> void:
	await create_timer(s, true, true).timeout


func _until(cond: Callable, timeout: float) -> bool:
	var t := 0.0
	while t < timeout:
		if cond.call():
			return true
		await _wait(0.1)
		t += 0.1
	return cond.call()


func _port() -> int:
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--port="):
			return int(a.trim_prefix("--port="))
	return 47900


func _player(id: int) -> Node:
	for p in get_nodes_in_group(&"player"):
		if p.get_multiplayer_authority() == id:
			return p
	return null


func _run() -> void:
	net = root.get_node("Net")
	ms = root.get_node("MatchState")
	gm = root.get_node("GameManager")
	var cfg = ms.cfg
	# Fast test tuning (host decides everything that matters).
	cfg.pizza_delay_min = 4.0
	cfg.pizza_delay_max = 4.5
	cfg.respawn_time = 1.0
	cfg.spawn_protection = 0.5
	cfg.zombie_kill_target = 2
	cfg.jobs_required = 1
	ms.kill_feed.connect(func(t: String, _c: Color) -> void: feed.append(t))

	net.my_name = "Hosty"
	_check("host listens", net.host(_port()) == OK)
	net.set_setting("mode", "tdm")
	net.set_setting("location", "wasteland")
	_check("client joined lobby", await _until(func() -> bool: return net.players.size() == 2, 20.0))
	var cid: int = net.players.keys().filter(func(i: int) -> bool: return i != 1)[0]
	_check("start blocked until everyone is READY", not net.all_ready())
	_check("client picked BLUE and pressed READY",
		await _until(func() -> bool: return net.all_ready() and net.peer_team(cid) == 1, 10.0))
	net.start_match()

	_check("match started on host", await _until(func() -> bool: return ms.active and _player(cid) != null, 25.0))
	var me = _player(1)
	var him = _player(cid)
	await _until(func() -> bool: return ms.pizza_of(0) != null and ms.pizza_of(1) != null, 5.0)
	await _wait(0.6)
	var rect: Rect2 = ms.location.map_rect()
	_check("teams spawn on opposite sides",
		me.global_position.x < rect.get_center().x and him.global_position.x > rect.get_center().x,
		"%s vs %s" % [me.global_position, him.global_position])
	_check("spawns are on walkable ground", ms.is_walkable(me.global_position, 6.0) and ms.is_walkable(him.global_position, 6.0))
	_check("each team has a pizza + drop-off", ms.pizza_of(0) and ms.pizza_of(1) and ms.dropoff_of(0) and ms.dropoff_of(1))
	_check("pizzas don't exist at the start", not ms.pizza_of(0)._spawned and not ms.pizza_of(1)._spawned)
	_check("health bar over the enemy is red", him.get_node("HealthTag").fill_column() == 0)
	_check("own health bar is blue", me.get_node("HealthTag").fill_column() == 1)

	# ---------- Melee PvP ----------
	ms._respawns.clear()
	await _wait(0.8)  # spawn protection over
	var w = me.weapon
	var hp0: float = him.hp
	w.knife_equipped = false
	w.request_switch()
	_check("weapon swap takes time", w.is_switching() and not w.try_attack())
	await _wait(cfg.weapon_switch_time + 0.1)
	_check("knife out after the swap", w.knife_equipped and not w.is_switching())
	# Walk up to the enemy (we own our position) and stab.
	var stabbed := false
	for attempt in 5:
		me.global_position = him.global_position + Vector2(-26, 0)
		await _wait(0.2)
		w.rotation = me.global_position.angle_to_point(him.global_position)
		w._knife_cooldown = 0.0
		w._try_slash()
		if await _until(func() -> bool: return him.hp <= hp0 - cfg.knife_pvp_damage + 0.1, 1.0):
			stabbed = true
			break
	_check("knife hurts an enemy player (host-validated)", stabbed, "%s -> %s" % [hp0, him.hp])
	# Guns never hurt players.
	var hp1: float = him.hp
	w.knife_equipped = false
	w._switch_left = 0.0
	w.in_mag = 6
	for i in 3:
		me.global_position = him.global_position + Vector2(-40, 0)
		w._cooldown = 0.0
		w.rotation = me.global_position.angle_to_point(him.global_position)
		w.try_fire()
		await _wait(0.15)
	await _wait(0.6)
	_check("guns do zero damage to players", is_equal_approx(him.hp, hp1), "%s -> %s" % [hp1, him.hp])
	# No friendly fire: pretend he's on our team for a moment.
	ms.teams[cid] = 0
	w.knife_equipped = true
	w._switch_left = 0.0
	var hp2: float = him.hp
	me.global_position = him.global_position + Vector2(-26, 0)
	await _wait(0.5)
	w._knife_cooldown = 0.0
	w.rotation = me.global_position.angle_to_point(him.global_position)
	w._try_slash()
	ms._validate_hit(1, cid, Vector2.RIGHT)  # even a forged request is refused
	await _wait(0.6)
	_check("no friendly fire in TDM", is_equal_approx(him.hp, hp2), "%s -> %s" % [hp2, him.hp])
	ms.teams[cid] = 1
	ms._broadcast()

	# Kill him: hits until he drops, then he respawns on his side.
	var tries := 0
	while him.hp > 0.0 and tries < 12:
		tries += 1
		me.global_position = him.global_position + Vector2(-26, 0)
		await _wait(0.12)
		w._knife_cooldown = 0.0
		w.rotation = me.global_position.angle_to_point(him.global_position)
		w._try_slash()
		await _wait(0.45)
	_check("enemy dies to the knife", await _until(func() -> bool: return him.hp <= 0.0 or him.is_dead(), 2.0))
	_check("kill feed shows the kill", await _until(func() -> bool:
		return feed.any(func(t: String) -> bool: return "[knife]" in t and "Hosty" in t), 3.0), str(feed))
	_check("player kill scored", ms.objectives[0].pk == 1)
	_check("he respawns at full health", await _until(func() -> bool: return him.hp >= him.max_hp - 0.1, 5.0))
	await _wait(0.3)
	_check("respawned on BLUE's side", him.global_position.x > rect.get_center().x, str(him.global_position))

	# ---------- Voice ----------
	_check("voice packets arrive from the client",
		await _until(func() -> bool: return int(root.get_node("Voice").frames_received.get(cid, 0)) > 0, 8.0))
	_check("his voice plays from his handyman (positional)", him.get_node_or_null("Voice") is AudioStreamPlayer2D)

	# ---------- Pizza ----------
	_check("pizzas land after the delay", await _until(func() -> bool:
		return ms.pizza_of(0)._spawned and ms.pizza_of(1)._spawned, 10.0))
	var p0 = ms.pizza_of(0)
	var d0: float = p0.global_position.distance_to(me.global_position)
	_check("our pizza is far from our team", d0 >= cfg.pizza_min_owner_distance * 0.5, "%.0f px" % d0)
	_check("pizza is on reachable ground", ms.is_walkable(p0.global_position, 8.0)
		and ms.reachable(ms.anchors[0], p0.global_position))
	_check("rejects spots near the owners", not ms.is_pizza_spot_ok(me.global_position + Vector2(40, 0),
		[me.global_position] as Array[Vector2], ms.anchors[0], 300.0))
	await _wait(0.2)
	_check("enemy pizza hidden from us at a distance",
		ms.pizza_of(1).global_position.distance_to(me.global_position) <= cfg.pizza_enemy_reveal_distance
		or not ms.pizza_of(1).visible)
	me.global_position = p0.global_position + Vector2(8, 0)
	await _wait(0.2)
	p0.interact(me)
	_check("we carry our pizza", await _until(func() -> bool: return p0.carrier_id == 1, 2.0))
	var drop = ms.dropoff_of(0)
	me.global_position = drop.global_position + Vector2(10, 0)
	await _wait(0.2)
	drop.interact(me)
	_check("delivering scores the pizza objective", await _until(func() -> bool: return ms.objectives[0].pizza, 2.0))

	# ---------- Jobs + zombies -> win ----------
	var task = ms.location.tasks[0]
	me.global_position = task.global_position + Vector2(0, 24)
	for i in 30:
		if ms.has_job(0, task.task_name):
			break
		task.advance(0.5)
		await _wait(0.02)
	_check("RED completed a job", ms.has_job(0, task.task_name), task.task_name)
	_check("BLUE still has that job to do", not ms.has_job(1, task.task_name))
	var zs := get_nodes_in_group(&"zombies")
	_check("zombies to kill", zs.size() >= 2, str(zs.size()))
	for z in zs.slice(0, 2):
		z.last_hitter = 1
		z.take_damage(9999.0)
	_check("zombie kills credited to RED", await _until(func() -> bool: return ms.objectives[0].kills >= 2, 2.0))
	_check("RED wins when every objective is done", await _until(func() -> bool:
		return gm.last_run.get("result", "") == "win", 5.0), str(gm.last_run.get("result", "")))
	await _wait(2.0)
	_report()
	quit()


func _report() -> void:
	var failed := results.values().count(false)
	print("HOST RESULT: %d/%d passed" % [results.size() - failed, results.size()])
