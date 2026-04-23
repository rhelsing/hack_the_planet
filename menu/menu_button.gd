class_name TerminalButton
extends Button
## Terminal-aesthetic button. Prefixes "> " on focus/hover to mimic a console
## cursor. Mouse-over grabs focus so keyboard + mouse stay in agreement. SFX
## hooks are guarded on the Audio autoload's existence (it's not shipped by
## interactables_dev yet).

@export var label: String = "":
	set(v):
		label = v
		_refresh_text()

@export var focused_prefix: String = "> "
@export var unfocused_prefix: String = "  "


func _ready() -> void:
	focus_mode = Control.FOCUS_ALL
	flat = true
	alignment = HORIZONTAL_ALIGNMENT_LEFT
	mouse_filter = Control.MOUSE_FILTER_STOP
	mouse_entered.connect(_on_mouse_entered)
	focus_entered.connect(_on_focus_entered)
	focus_exited.connect(_on_focus_exited)
	pressed.connect(_on_pressed)
	_refresh_text()


func _refresh_text() -> void:
	var prefix := focused_prefix if has_focus() else unfocused_prefix
	text = "%s%s" % [prefix, label]


func _on_mouse_entered() -> void:
	if not disabled:
		grab_focus()


func _on_focus_entered() -> void:
	_refresh_text()
	_play_sfx(&"ui_move")


func _on_focus_exited() -> void:
	_refresh_text()


func _on_pressed() -> void:
	_play_sfx(&"ui_confirm")


# Audio autoload is interactables_dev's turf and isn't shipped yet. Guarded.
func _play_sfx(cue: StringName) -> void:
	var audio := get_tree().root.get_node_or_null(^"Audio")
	if audio != null and audio.has_method(&"play_sfx"):
		audio.call(&"play_sfx", cue)
