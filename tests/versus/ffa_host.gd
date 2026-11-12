extends SceneTree
## FFA + disconnect test, HOST. The client steals our pizza, then disconnects while carrying it.

var results := {}
var net
var ms


func _initialize() -> void:
	_run.call_deferred()
	create_timer(120.0, true, true).timeout.connect(func() -> void:
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
	return 47950


func _player(id: int) -> Node:
	for p in get_nodes_in_group(&"player"):
		if p.get_multiplayer_authority() == id:
			return p
	return null


func _run() -> void:
	net = root.get_node("Net")
	ms = root.get_node("MatchState")
	ms.cfg.pizza_delay_min = 3.0
	ms.cfg.pizza_delay_max = 3.5
	net.my_name = "Hosty"
	_check("host listens", net.host(_port()) == OK)
	net.set_setting("mode", "ffa")
	net.set_setting("location", "camp")
	net.set_setting("pizza_enemy", "steal")
	_check("client joined", await _until(func() -> bool: return net.players.size() == 2, 20.0))
	var cid: int = net.players.keys().filter(func(i: int) -> bool: return i != 1)[0]
	await _until(func() -> bool: return net.all_ready(), 10.0)
	net.start_match()
	_check("FFA started", await _until(func() -> bool: return ms.active and _player(cid) != null, 25.0))
	await _wait(0.8)
	var me = _player(1)
	var him = _player(cid)
	_check("everyone is their own team", ms.team_of(1) == 1 and ms.team_of(cid) == cid and ms.are_enemies(1, cid))
	var gap: float = me.global_position.distance_to(him.global_position)
	_check("FFA spawns spread far apart", gap > 600.0, "%.0f px" % gap)
	_check("both bars red for each other in FFA", him.get_node("HealthTag").fill_column() == 0)
	_check("my pizza lands", await _until(func() -> bool: return ms.pizza_of(1)._spawned, 8.0))
	var mine = ms.pizza_of(1)
	_check("client stole my pizza", await _until(func() -> bool: return mine.carrier_id == cid, 30.0))
	var dropoff = ms.dropoff_of(1)
	_check("a thief can't deliver it", not ms.objectives[1].pizza and not mine.delivered)
	_check("client disconnects", await _until(func() -> bool: return not net.players.has(cid), 30.0))
	await _wait(0.5)
	_check("pizza dropped when the carrier left", mine.carrier_id == 0 and mine._spawned and not mine.delivered)
	_check("dropped pizza is on reachable ground", ms.is_walkable(mine.global_position, 6.0)
		or ms.reachable(me.global_position, mine.global_position))
	_check("their player is removed", _player(cid) == null or _player(cid).is_queued_for_deletion())
	_check("they're out of the match", not ms.teams.has(cid) and not ms.objectives.has(cid))
	_check("their pizza + drop-off are cleaned up", ms.pizza_of(cid) == null or ms.pizza_of(cid).is_queued_for_deletion())
	_check("match keeps running for the host", ms.active and ms.winner == -2)
	_report()
	quit()


func _report() -> void:
	var failed := results.values().count(false)
	print("HOST RESULT: %d/%d passed" % [results.size() - failed, results.size()])
