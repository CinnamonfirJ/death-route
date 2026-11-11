class_name CharacterPicker
extends OptionButton


func _ready() -> void:
	texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	for id in GameManager.PLAYABLE_CHARACTERS:
		var frames := Assets.character_frames(id)
		add_icon_item(frames.get_frame_texture(&"idle", 0), GameManager.PLAYABLE_CHARACTERS[id])
		set_item_metadata(item_count - 1, id)
		if id == GameManager.selected_character:
			select(item_count - 1)
	item_selected.connect(_on_character_selected)


func _on_character_selected(index: int) -> void:
	var id: StringName = get_item_metadata(index)
	GameManager.set_character(id)
	Net.set_character(id)
