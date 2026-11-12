extends SceneTree
## Zombie senses (offline, hospital): no seeing through walls, view cone, hearing goes to
## the SOURCE of a sound, then search, then wander. Noise radii: sprint > walk > crouch.

var results := {}


func _initialize() -> void:
	_run.call_deferred()
	create_timer(60.0, true, true).timeout.connect(func() -> void: print("TIMEOUT"); _report(); quit(2))


func _check(name: String, ok: bool, info := "") -> void:
	results[name] = ok
	print(("PASS " if ok else "FAIL ") + name + ("  (" + info + ")" if info != "" else ""))


func _wait(s: float) -> void:
	await create_timer(s, true, true).timeout


func _run() -> void:
	var gm = root.get_node("GameManager")
	var level = load(gm.LOCATIONS[&"hospital"].scene).instantiate()
	level.starting_companion = false
	root.add_child(level)
	await _wait(0.5)
	level.get_node("NoiseDirector").process_mode = Node.PROCESS_MODE_DISABLED
	for z in get_nodes_in_group(&"zombies"):
		z.queue_free()
	for c in get_nodes_in_group(&"companions"):
		c.queue_free()
	var player = level.get_node("Entities/Player")
	var walls: TileMapLayer = level.get_node("Entities/Walls")
	# A wall cell with open floor on its left and right (a vertical wall).
	var cell := Vector2i(-999, 0)
	for c in walls.get_used_cells():
		var ok := true
		for dx in [-3, -2, -1, 1, 2, 3]:
			if walls.get_cell_source_id(c + Vector2i(dx, 0)) != -1:
				ok = false
		for dy in [-1, 1]:
			if walls.get_cell_source_id(c + Vector2i(0, dy)) == -1:
				ok = false  # want a wall segment, not a lone tile
		if ok:
			cell = c
			break
	_check("found a wall to hide behind", cell.x != -999, str(cell))
	var wall_pos := walls.map_to_local(cell)
	var z = load("res://scenes/zombies/walker.tscn").instantiate()
	z.position = wall_pos + Vector2(-80, 0)
	level.get_node("Entities").add_child(z)
	await _wait(0.1)
	z.set_physics_process(false)
	player.global_position = wall_pos + Vector2(80, 0)
	z._facing = Vector2.RIGHT
	await physics_frame
	_check("can't see through a wall", not z.can_see(player))
	player.global_position = z.global_position + Vector2(-60, -20)
	z._facing = Vector2.LEFT
	await physics_frame
	var space_clear: bool = z.can_see(player)
	_check("sees a player in front, in the open", space_clear)
	z._facing = Vector2.RIGHT
	_check("doesn't see a player behind it", not z.can_see(player))
	player.global_position = z.global_position + Vector2(-20, 6)
	_check("notices a player right next to it", z.can_see(player))
	player.global_position = z.global_position + Vector2(-400, 0)
	_check("doesn't see past sight range", not z.can_see(player))

	# Hearing: a sound pulls it to the sound's position, not to the player.
	player.global_position = wall_pos + Vector2(80, 0)  # hidden behind the wall
	z.set_physics_process(true)
	var src: Vector2 = z.global_position + Vector2(-50, 30)
	root.get_node("EventBus").sound_made.emit(src, 200.0)
	_check("hears the sound", z.sense == z.Sense.INVESTIGATE)
	_check("heads for the sound's source", z._investigate_pos == src)
	var reached := false
	for i in 80:
		await _wait(0.1)
		if z.sense == z.Sense.SEARCH:
			reached = true
			break
	_check("searches when it gets there", reached)
	await _wait(z._senses.search_time + 0.6)
	_check("gives up and wanders", z.sense == z.Sense.WANDER, str(z.sense))
	var far: Vector2 = z.global_position + Vector2(600, 0)
	root.get_node("EventBus").sound_made.emit(far, 100.0)
	_check("ignores sounds out of earshot", z.sense != z.Sense.INVESTIGATE)
	var cfg = root.get_node("MatchState").cfg
	_check("sprint > walk > crouch (silent)", cfg.sound_sprint > cfg.sound_walk and cfg.sound_walk > cfg.sound_crouch
		and cfg.sound_crouch == 0.0)
	_check("gunshots and horns carry far", cfg.sound_gunshot > cfg.sound_sprint and cfg.sound_horn > cfg.sound_gunshot)
	_report()
	quit()


func _report() -> void:
	var failed := results.values().count(false)
	print("RESULT: %d/%d passed" % [results.size() - failed, results.size()])
