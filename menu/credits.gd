extends Control
## Placeholder credits screen. Scrolling text block. Emits back_requested.

signal back_requested

@onready var _back_btn: Button = %BackBtn


func configure(_args: Dictionary) -> void:
	pass


func _ready() -> void:
	# Inherit parent process_mode — see save_slots.gd for the rationale.
	Events.modal_opened.emit(&"credits")
	tree_exited.connect(func() -> void: Events.modal_closed.emit(&"credits"))
	_back_btn.pressed.connect(func() -> void:
		_play_back_sfx()
		back_requested.emit()
	)
	_back_btn.grab_focus()


func _input(event: InputEvent) -> void:
	if event.is_action_pressed(&"ui_cancel"):
		_play_back_sfx()
		back_requested.emit()
		get_viewport().set_input_as_handled()


func _play_back_sfx() -> void:
	var audio := get_tree().root.get_node_or_null(^"Audio")
	if audio != null and audio.has_method(&"play_sfx"):
		audio.call(&"play_sfx", &"ui_back")
