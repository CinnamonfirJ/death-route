extends SceneTree
## Visual check (needs a window, not --headless): banks a haul, opens the Garage's Market tab and
## the fast-forward overlay, and saves both as PNGs. A bridge must be listening on 127.0.0.1:8787.
##
##   godot -s tests/market/garage_screenshot.gd -- --save=user://market_shot.save --out=/tmp/shots

var out := "user://"


func _initialize() -> void:
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--out="):
			out = a.trim_prefix("--out=")
	_run.call_deferred()
	create_timer(45.0, true, true).timeout.connect(func() -> void: print("TIMEOUT"); quit(2))


func _run() -> void:
	var gm = root.get_node("GameManager")
	gm.reset_save()
	gm.currency = 140
	gm.start_run(&"camp")
	gm.add_run_commodity("medkit", 4)
	gm.add_run_commodity("battery", 2)
	gm.end_run(true, -1.0, {"pizza_delivered": true})
	var scene = load("res://scenes/ui/garage.tscn").instantiate()
	root.add_child(scene)
	current_scene = scene
	DisplayServer.window_move_to_foreground()
	await create_timer(3.0, true, true).timeout
	var tabs: TabContainer = scene.get_node("Margin/VBox/Body/ShopPanel/Tabs")
	if tabs == null:
		scene.print_tree_pretty()
		print("FAIL no Tabs node")
		quit(1)
		return
	tabs.current_tab = tabs.get_tab_count() - 1
	await create_timer(1.5, true, true).timeout
	await _capture(out.path_join("market_tab.png"))
	print("SAVED market_tab.png")
	var panel = tabs.get_child(tabs.get_tab_count() - 1).get_node("List").get_child(0)
	panel._fast_forward()
	await create_timer(3.0, true, true).timeout
	var overlay = scene.find_child("FastForwardOverlay", true, false)
	if overlay:
		overlay._elapsed = 15.0
		await create_timer(0.5, true, true).timeout
		await _capture(out.path_join("fast_forward.png"))
		print("SAVED fast_forward.png")
	else:
		print("FAIL no overlay")
	quit(0)


## An occluded window on macOS can hand back a stale frame; wait for a fresh one first.
func _capture(path: String) -> void:
	DisplayServer.window_move_to_foreground()
	await RenderingServer.frame_post_draw
	await RenderingServer.frame_post_draw
	root.get_viewport().get_texture().get_image().save_png(path)
