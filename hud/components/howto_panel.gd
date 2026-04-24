extends CanvasLayer

## Post-install how-to-use panel. Shown after InstallToast completes. Displays
## a placeholder image + one-line caption teaching the mechanic. Dismissable
## on any action input or after AUTO_DISMISS_S seconds. Emits `dismissed` +
## queue_frees.

signal dismissed

const AUTO_DISMISS_S: float = 3.5

@onready var _image: TextureRect = %Image
@onready var _caption: Label = %Caption

var _dismissed: bool = false


func _ready() -> void:
	# Allow input while the game isn't paused (the world keeps running — this
	# is an informational overlay, not a modal pause).
	process_mode = Node.PROCESS_MODE_ALWAYS


func show_for(powerup_flag: StringName, caption: String, image: Texture2D = null) -> void:
	_caption.text = caption
	if image != null:
		_image.texture = image
	else:
		# Try to load a placeholder based on the flag id (e.g.
		# "powerup_love" → "res://hud/icons/howto/love.png"). If missing,
		# the image stays blank — the caption still conveys the mechanic.
		var key := String(powerup_flag).replace("powerup_", "")
		var path := "res://hud/icons/howto/%s.png" % key
		if ResourceLoader.exists(path):
			_image.texture = load(path)
	# Auto-dismiss timer.
	var t := get_tree().create_timer(AUTO_DISMISS_S)
	t.timeout.connect(_dismiss)


func _unhandled_input(event: InputEvent) -> void:
	if _dismissed:
		return
	if event.is_pressed() and not event.is_echo():
		_dismiss()


func _dismiss() -> void:
	if _dismissed:
		return
	_dismissed = true
	dismissed.emit()
	queue_free()
