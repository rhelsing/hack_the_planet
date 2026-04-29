extends Area3D

## One-shot walkie cue. Fires `Walkie.speak(character, line)` the first time
## the player enters the area. Drop one per narrative beat in a level.
##
## Persistence: if `persist_flag` is set, the fired state writes to
## GameState.flags — survives deaths/reloads. Otherwise re-enters after a
## scene reload WILL re-fire (in-memory only).

@export var character: StringName = &"DialTone"
@export_multiline var line: String = ""
@export var fire_once: bool = true
## Only fire if this flag is true on GameState. Empty string = always allowed.
## Default gates on walkie ownership so triggers are silent before Beat 1.
@export var require_flag: StringName = &"walkie_talkie_owned"
## If non-empty, fired state persists via GameState.set_flag(persist_flag, true).
## Prevents re-firing across saves. Empty = in-memory only.
@export var persist_flag: StringName = &""
## Optional music override. When set, on trigger fire calls Audio.play_music
## (force-loops the stream) — the song plays until something else takes over
## (typically Audio.resume_default_playlist_if_overridden() called from a
## later level's _ready). Used for story-beat scoring like the level-2
## "something is wrong" cue → dust-motions track until level 3 starts.
@export var music_loop: AudioStream = null

var _fired: bool = false


func _ready() -> void:
	monitoring = true
	monitorable = false
	collision_layer = 0
	# Only detect the player pawn.
	collision_mask = 1
	body_entered.connect(_on_body_entered)
	if persist_flag != &"" and bool(GameState.get_flag(persist_flag, false)):
		_fired = true


func _on_body_entered(body: Node) -> void:
	if _fired and fire_once:
		return
	if not body.is_in_group("player"):
		return
	if require_flag != &"" and not bool(GameState.get_flag(require_flag, false)):
		return
	if line.strip_edges().is_empty():
		push_warning("WalkieTrigger has no line — %s" % get_path())
		return
	_fired = true
	if persist_flag != &"":
		GameState.set_flag(persist_flag, true)
	if music_loop != null:
		var audio: Node = get_node_or_null(^"/root/Audio")
		if audio != null and audio.has_method(&"play_music"):
			audio.call(&"play_music", music_loop, 1.0)
	Walkie.speak(String(character), line)
