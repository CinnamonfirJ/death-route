extends SceneTree
## FFA + disconnect test, CLIENT: wait for the host's pizza, steal it, then quit.

var results := {}
var net
var ms


func _initialize() -> void:
	_run.call_deferred()
	create_timer(120.0, true, true).timeout.connect(func() -> void:
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
	return 47950


func _run() -> void:
	net = root.get_node("Net")
	ms = root.get_node("MatchState")
	net.my_name = "Thief"
	await _wait(1.0)
	net.join("127.0.0.1", _port())
	_check("connected", await _until(func() -> bool: return net.players.size() == 2, 20.0))
	net.set_ready(true)
	_check("match started", await _until(func() -> bool: return ms.active and net.local_player() != null, 25.0))
	var me = net.local_player()
	_check("host's pizza landed", await _until(func() -> bool:
		return ms.pizza_of(1) != null and ms.pizza_of(1)._spawned, 15.0))
	var target = ms.pizza_of(1)
	await _wait(0.2)
	_check("enemy pizza is hidden from far away", me.global_position.distance_to(target.global_position)
		<= ms.cfg.pizza_enemy_reveal_distance or not target.visible)
	me.global_position = target.global_position + Vector2(6, 0)
	await _wait(0.3)
	_check("enemy pizza revealed up close", target.visible)
	_check("steal prompt", "Steal" in target.get_interact_prompt(me), target.get_interact_prompt(me))
	target.interact(me)
	_check("I'm carrying their pizza", await _until(func() -> bool: return target.carrier_id == net.local_id(), 3.0))
	await _wait(1.0)
	net.leave()
	await _wait(0.5)
	_report()
	quit()


func _report() -> void:
	var failed := results.values().count(false)
	print("CLIENT RESULT: %d/%d passed" % [results.size() - failed, results.size()])
