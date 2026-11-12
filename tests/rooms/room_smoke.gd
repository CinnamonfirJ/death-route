extends SceneTree
## Run two processes against the same relay. Start the host first, then the guest.

var net: Node


func _initialize() -> void:
	_run.call_deferred()
	create_timer(110).timeout.connect(func() -> void:
		printerr("FAIL: room test timed out")
		quit(2))


func _wait_for(condition: Callable, checks := 200) -> bool:
	for i in range(checks):
		if condition.call():
			return true
		await create_timer(0.1).timeout
	return false


func _check(value: bool, message: String) -> bool:
	print(("PASS " if value else "FAIL ") + message)
	if not value:
		quit(1)
	return value


func _run() -> void:
	net = root.get_node("Net")
	var args := OS.get_cmdline_user_args()
	var host := "--host" in args
	var code_path := ProjectSettings.globalize_path("res://build/room-smoke-code.txt")
	for arg in args:
		if arg.begins_with("--code-file="):
			code_path = arg.trim_prefix("--code-file=")
	net.my_name = "SmokeHost" if host else "SmokeGuest"
	if host:
		net.create_room(true, &"hospital")
		if not _check(await _wait_for(func() -> bool: return net.is_host() and not net.room_code.is_empty()), "host opened room"):
			return
		var code_file := FileAccess.open(code_path, FileAccess.WRITE)
		if not _check(code_file != null, "room code file opened"):
			return
		code_file.store_string(net.room_code)
		code_file.close()
	else:
		if not _check(await _wait_for(func() -> bool: return FileAccess.get_file_as_string(code_path).length() == 6, 800), "room code exists"):
			return
		net.join_room(FileAccess.get_file_as_string(code_path))
	if not _check(await _wait_for(func() -> bool: return net.players.size() == 2, 800), "roster reached both peers"):
		return
	if host:
		net.start_match()
	if not _check(await _wait_for(func() -> bool: return net.in_match and net.player_nodes().size() == 2), "both players spawned in the match"):
		return
	await create_timer(0.8 if host else 0.5).timeout
	net.leave()
	quit()
