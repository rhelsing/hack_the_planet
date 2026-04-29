extends CanvasLayer

## Post-install how-to-use panel. Shown after InstallToast completes. Displays
## a video (or fallback image) + caption teaching the mechanic.
##
## Lifecycle:
##   1. Spawned by PowerupPickup; sized 800×540 with 16:9 media area.
##   2. Plays the auto-resolved video at res://hud/icons/howto/{key}.ogv
##      where key = the powerup_flag with the "powerup_" prefix stripped
##      (e.g. powerup_love → love.ogv). Falls back to a .png placeholder
##      then to caption-only.
##   3. Locks dismissal for MIN_DISPLAY_S seconds — players can't skip
##      the intro before they've seen it.
##   4. After the lock expires, the hint label shows "[any key to
##      continue]" and any input button dismisses + queue_frees.

signal dismissed

const MIN_DISPLAY_S: float = 5.0
## Placeholder music track played when no per-powerup loop is found at
## res://audio/music/howto_{key}.{mp3,ogg}. Reuses the maze hack track for
## now — replace per-powerup as the bespoke tracks land.
const _PLACEHOLDER_MUSIC: AudioStream = preload("res://audio/music/maze_hack_loop.mp3")
const _MUSIC_VOLUME_DB: float = 0.0

@onready var _video: VideoStreamPlayer = %Video
@onready var _image: TextureRect = %Image
@onready var _caption: Label = %Caption
@onready var _hint: Label = %Hint

var _start_time: float = 0.0
var _can_dismiss: bool = false
var _dismissed: bool = false
var _music_player: AudioStreamPlayer = null
var _ducked_main_music: bool = false
var _paused_tree: bool = false


func _ready() -> void:
	# PROCESS_MODE_ALWAYS so the panel keeps ticking + accepting input while
	# the world tree is paused below it.
	process_mode = Node.PROCESS_MODE_ALWAYS
	_start_time = Time.get_ticks_msec() / 1000.0
	_hint.text = ""  # blank until min-display window passes
	# Pause gameplay underneath us. Skip if something else already paused
	# (e.g., a puzzle) so we don't unpause it on dismiss.
	if not get_tree().paused:
		get_tree().paused = true
		_paused_tree = true
	# Duck the world music so the howto track plays alone.
	var audio: Node = get_node_or_null(^"/root/Audio")
	if audio != null and audio.has_method(&"pause_music"):
		audio.call(&"pause_music")
		_ducked_main_music = true


func show_for(powerup_flag: StringName, caption: String, image: Texture2D = null,
		video: VideoStream = null) -> void:
	# Resolve {action} tokens to the active device's glyph so authoring once
	# as "PRESS {dash} TO DASH" renders correctly for both keyboard and pad.
	# No-op for legacy hardcoded captions that contain no tokens.
	_caption.text = Glyphs.format(caption)
	# Media — explicit video > auto-loaded video > explicit image > auto image.
	var key: String = String(powerup_flag).replace("powerup_", "")
	if video != null:
		_set_video(video)
	elif _try_auto_video(key):
		pass
	elif image != null:
		_set_image(image)
	else:
		_try_auto_image(key)
	# Music — per-powerup track if present, else placeholder (hack loop).
	_play_music_loop(_resolve_music(key))


# Look up a per-powerup music track. Convention:
#   res://audio/music/howto_{key}.mp3  (or .ogg)
# Falls back to _PLACEHOLDER_MUSIC so every panel has SOMETHING playing.
func _resolve_music(key: String) -> AudioStream:
	for ext: String in ["mp3", "ogg"]:
		var path: String = "res://audio/music/howto_%s.%s" % [key, ext]
		if ResourceLoader.exists(path):
			var stream: Resource = load(path)
			if stream is AudioStream:
				return stream
	return _PLACEHOLDER_MUSIC


func _play_music_loop(stream: AudioStream) -> void:
	if stream == null:
		return
	var s: AudioStream = stream.duplicate()
	if "loop" in s:
		s.loop = true
	_music_player = AudioStreamPlayer.new()
	_music_player.stream = s
	_music_player.bus = &"Music"
	_music_player.volume_db = _MUSIC_VOLUME_DB
	_music_player.process_mode = Node.PROCESS_MODE_ALWAYS
	add_child(_music_player)
	_music_player.play()


func _try_auto_video(key: String) -> bool:
	var path: String = "res://hud/icons/howto/%s.ogv" % key
	if not ResourceLoader.exists(path):
		return false
	var stream: Resource = load(path)
	if not stream is VideoStream:
		return false
	_set_video(stream)
	return true


func _try_auto_image(key: String) -> bool:
	var path: String = "res://hud/icons/howto/%s.png" % key
	if not ResourceLoader.exists(path):
		return false
	_set_image(load(path))
	return true


func _set_video(stream: VideoStream) -> void:
	_image.visible = false
	_video.visible = true
	_video.stream = stream
	# Loop while the panel is up — players who linger past the clip's end
	# still see continuous footage instead of a frozen last frame.
	_video.loop = true
	_video.play()


func _set_image(tex: Texture2D) -> void:
	_video.visible = false
	_image.visible = true
	_image.texture = tex


func _process(_delta: float) -> void:
	if _can_dismiss or _dismissed:
		return
	var elapsed: float = Time.get_ticks_msec() / 1000.0 - _start_time
	if elapsed >= MIN_DISPLAY_S:
		_can_dismiss = true
		_hint.text = "[any key to continue]"


func _unhandled_input(event: InputEvent) -> void:
	if not _can_dismiss or _dismissed:
		return
	if event.is_pressed() and not event.is_echo():
		_dismiss()


func _dismiss() -> void:
	if _dismissed:
		return
	_dismissed = true
	if _video != null:
		_video.stop()
	if _music_player != null and is_instance_valid(_music_player):
		_music_player.stop()
	# Restore the world music + un-pause gameplay (only if we paused it).
	if _ducked_main_music:
		var audio: Node = get_node_or_null(^"/root/Audio")
		if audio != null and audio.has_method(&"resume_music"):
			audio.call(&"resume_music")
		_ducked_main_music = false
	if _paused_tree:
		get_tree().paused = false
		_paused_tree = false
	dismissed.emit()
	queue_free()
