class_name FullscreenButton
extends Button
## The same fullscreen control on the title screen and in settings.

static var _previous_mode := DisplayServer.WINDOW_MODE_WINDOWED
var _web_document: JavaScriptObject
var _web_callback: JavaScriptObject


static func available() -> bool:
	if OS.has_feature("web"):
		return bool(JavaScriptBridge.eval("window.deadRouteFullscreenAvailable?.() === true", true))
	return OS.has_feature("pc") and DisplayServer.get_name() != "headless"


func _ready() -> void:
	pressed.connect(_toggle)
	if OS.has_feature("web"):
		_web_document = JavaScriptBridge.get_interface("document")
		_web_callback = JavaScriptBridge.create_callback(_on_web_change)
		_web_document.addEventListener("fullscreenchange", _web_callback)
	else:
		get_viewport().size_changed.connect(_refresh)
	_refresh()


func _exit_tree() -> void:
	if _web_document != null and _web_callback != null:
		_web_document.removeEventListener("fullscreenchange", _web_callback)


func _on_web_change(_arguments: Array) -> void:
	_refresh()


func _active() -> bool:
	if OS.has_feature("web"):
		return bool(JavaScriptBridge.eval("window.deadRouteIsFullscreen?.() === true", true))
	var mode := DisplayServer.window_get_mode()
	return mode == DisplayServer.WINDOW_MODE_FULLSCREEN or mode == DisplayServer.WINDOW_MODE_EXCLUSIVE_FULLSCREEN


func _refresh() -> void:
	text = "Exit fullscreen" if _active() else "Fullscreen"


func _toggle() -> void:
	if OS.has_feature("web"):
		JavaScriptBridge.eval("window.deadRouteToggleFullscreen?.()", true)
		return
	if _active():
		DisplayServer.window_set_mode(_previous_mode)
	else:
		var current := DisplayServer.window_get_mode()
		_previous_mode = DisplayServer.WINDOW_MODE_MAXIMIZED if current == DisplayServer.WINDOW_MODE_MAXIMIZED else DisplayServer.WINDOW_MODE_WINDOWED
		DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_FULLSCREEN)
	_refresh()
