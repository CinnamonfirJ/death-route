extends SceneTree
## Visual check (needs a window): opens the title screen's sign-in panel and saves a PNG.
##   godot -s tests/market/title_screenshot.gd -- --save=user://title_shot.save --out=/tmp/shots

var out := "user://"


func _initialize() -> void:
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--out="):
			out = a.trim_prefix("--out=")
	_run.call_deferred()
	create_timer(20.0, true, true).timeout.connect(func() -> void: print("TIMEOUT"); quit(2))


func _run() -> void:
	var scene = load("res://scenes/ui/main_menu.tscn").instantiate()
	root.add_child(scene)
	current_scene = scene
	DisplayServer.window_move_to_foreground()
	await create_timer(1.5, true, true).timeout
	scene._show_wallet()
	await create_timer(0.8, true, true).timeout
	await RenderingServer.frame_post_draw
	await RenderingServer.frame_post_draw
	root.get_viewport().get_texture().get_image().save_png(out.path_join("signin.png"))
	print("SAVED signin.png")
	quit(0)
