extends SceneTree
## Versus test, CLIENT side. Joins vs_host.gd, picks BLUE, readies up, talks, gets knifed.

var results := {}
var net
var ms
var gm


func _initialize() -> void:
	_run.call_deferred()
	create_timer(150.0, true, true).timeout.connect(func() -> void:
		print("CLIENT TIMEOUT"); _report(); quit(2))


func _check(name: String, ok: bool, info := "") -> void:
	results[name] = ok
	print(("PASS " if ok else "FAIL ") + "[client] " + name + ("  (" + info + ")" if info != "" else ""))


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


func _run() -> void:
	net = root.get_node("Net")
	ms = root.get_node("MatchState")
	gm = root.get_node("GameManager")
	ms.cfg.spawn_protection = 0.5  # match the host's fast test tuning
	ms.cfg.respawn_time = 1.0
	net.my_name = "Clienty"
	await _wait(1.0)
	net.join("127.0.0.1", _port())
	_check("connected", await _until(func() -> bool: return net.is_online() and net.players.size() == 2, 20.0))
	_check("lobby shows Team Deathmatch", net.settings.get("mode", "") == "tdm")
	net.set_team(1)
	await _wait(0.5)
	net.set_ready(true)
	_check("I'm BLUE and READY", await _until(func() -> bool:
		return net.peer_team(net.local_id()) == 1 and net.peer_ready(net.local_id()), 5.0))
	_check("match started", await _until(func() -> bool: return ms.active and net.local_player() != null, 25.0))
	var me = net.local_player()
	await _wait(1.0)
	_check("I'm on BLUE in the match", ms.local_team() == 1)
	var host_p = null
	for p in get_nodes_in_group(&"player"):
		if p.get_multiplayer_authority() == 1:
			host_p = p
	_check("enemy (host) bar is red on my screen", host_p != null and host_p.get_node("HealthTag").fill_column() == 0)
	_check("objectives on my HUD", ms.objectives.has(1))

	# Push-to-talk: inject a 440 Hz tone as if from the mic.
	var voice = root.get_node("Voice")
	Input.action_press(&"voice_talk")
	for k in 6:
		var frames := PackedVector2Array()
		for i in 2205:
			var v := sin(TAU * 440.0 * (k * 2205 + i) / 44100.0) * 0.4
			frames.append(Vector2(v, v))
		voice.feed(frames, 44100.0, 0.05)
		await _wait(0.05)
	Input.action_release(&"voice_talk")
	_check("my voice was sent", voice.packets_sent > 0, str(voice.packets_sent))
	var dec: PackedFloat32Array = voice.decode(voice.encode(PackedFloat32Array([0.5, -0.25, 0.0])))
	_check("voice codec round-trips", absf(dec[0] - 0.5) < 0.02 and absf(dec[1] + 0.25) < 0.02 and absf(dec[2]) < 0.01)

	_check("I got knifed", await _until(func() -> bool: return me.hp < me.max_hp, 30.0), str(me.hp))
	_check("I died and respawned", await _until(func() -> bool: return me.is_dead(), 30.0)
		and await _until(func() -> bool: return not me.is_dead() and me.hp >= me.max_hp - 0.1, 8.0))
	_check("pizza countdown / status on my HUD", ms.pizza_status(1) != "")
	_check("host's job doesn't count for BLUE", await _until(func() -> bool:
		return ms.objectives.has(0) and ms.objectives[0].jobs.size() >= 1, 60.0) and ms.objectives[1].jobs.is_empty())
	_check("match ended: BLUE lost", await _until(func() -> bool:
		return gm.last_run.get("result", "") == "lose", 60.0), str(gm.last_run.get("result", "")))
	_report()
	quit()


func _report() -> void:
	var failed := results.values().count(false)
	print("CLIENT RESULT: %d/%d passed" % [results.size() - failed, results.size()])
