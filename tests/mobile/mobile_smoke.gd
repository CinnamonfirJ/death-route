extends SceneTree
## godot --headless --script tests/mobile/mobile_smoke.gd -- --mobile-ui --save=user://mobile-smoke.save

var _failed := false


func _initialize() -> void:
	_run.call_deferred()


func _check(value: bool, message: String) -> void:
	print(("PASS " if value else "FAIL ") + message)
	_failed = _failed or not value


func _scene(path: String) -> void:
	change_scene_to_file(path)
	await scene_changed
	for frame in 3:
		await process_frame


func _tap(index: int, point: Vector2, down: bool) -> void:
	var event := InputEventScreenTouch.new()
	event.index = index
	event.position = point
	event.pressed = down
	Input.parse_input_event(event)


func _drag(index: int, point: Vector2) -> void:
	var event := InputEventScreenDrag.new()
	event.index = index
	event.position = point
	Input.parse_input_event(event)


func _run() -> void:
	root.size = Vector2i(980, 360)
	await _scene("res://scenes/ui/main_menu.tscn")
	var title := current_scene
	_check(title.get("_play").size.y >= 38, "title play button has a large mobile hit area")
	title.call("_show_settings")
	await process_frame
	_check(root.get_visible_rect().encloses(title.get("_frame").get_rect()), "settings fits inside landscape viewport")
	await _scene("res://scenes/ui/garage.tscn")
	var garage := current_scene
	var start := garage.get_node(^"%StartButton") as Button
	_check(start.size.y >= 38 and root.get_visible_rect().encloses(start.get_global_rect()), "garage launch stays visible")
	await _scene("res://scenes/ui/lobby.tscn")
	var lobby := current_scene
	_check(root.get_visible_rect().encloses(lobby.get("_panel").get_rect()), "online rooms fits inside landscape viewport")
	await _scene("res://rooms/hospital.tscn")
	var hud := current_scene.get_node_or_null(^"HUD")
	var controls := hud.get_node_or_null(^"TouchControls") if hud else null
	var player: Node = root.get_node(^"Net").local_player()
	_check(controls != null and player != null, "hospital loaded with touch controls and a player")
	if not controls or not player:
		quit(1)
		return
	_check(is_instance_valid(hud.get("_route_button")), "mobile objectives drawer is available")
	var route_button: Button = hud.get("_route_button")
	route_button.button_pressed = true
	await process_frame
	await process_frame
	var route_card: PanelContainer = hud.get("_route_card")
	var route_text: Label = hud.get("_route_text")
	var text_visible := route_card.visible and not route_text.text.is_empty() and route_text.size.x > 100.0
	_check(text_visible and root.get_visible_rect().encloses(route_card.get_global_rect()), "objective text fits in the mobile drawer")
	route_button.button_pressed = false
	var gm := root.get_node(^"GameManager")
	gm.set_setting("touch_shooting", "drag")
	var safe: Rect2 = controls.get("_safe")
	var aim := safe.end - Vector2(62, 61)
	var move := Vector2(safe.position.x + 61, safe.end.y - 61)
	_tap(0, move, true)
	_drag(0, move + Vector2(18, 0))
	_tap(1, aim, true)
	_drag(1, aim + Vector2(20, 0))
	await process_frame
	_check(not player.touch_fire and player.touch_aim.is_equal_approx(Vector2.RIGHT), "aim inside the ring does not fire")
	_drag(1, aim + Vector2(43, -4))
	await process_frame
	_check(player.touch_fire and Input.is_action_pressed(&"move_right"), "crossing the ring fires while moving")
	_drag(1, aim + Vector2(18, 0))
	await process_frame
	_check(not player.touch_fire, "returning inside the ring stops fire")
	_drag(1, aim + Vector2(43, 0))
	_tap(1, aim, false)
	_tap(0, move, false)
	await process_frame
	_check(not player.touch_fire and not Input.is_action_pressed(&"move_right"), "releasing both thumbs stops movement and fire")
	gm.set_setting("touch_shooting", "advanced")
	aim = safe.end - Vector2(115, 61)
	_tap(1, aim, true)
	_drag(1, aim + Vector2(43, 0))
	await process_frame
	_check(not player.touch_fire, "advanced aim never fires on its own")
	var fire := safe.end - Vector2(36, 61)
	_tap(2, fire, true)
	await process_frame
	_check(player.touch_fire, "advanced fire button fires while aiming")
	hud.get_node(^"PauseMenu").open()
	_check(not player.touch_fire, "opening pause clears held fire")
	quit(int(_failed))
