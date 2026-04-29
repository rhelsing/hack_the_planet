extends Node

## Non-positional audio — music, ambience, dialogue voice, and SFX cues.
## Positional SFX (door creak at the door) lives on the interactable as
## AudioStreamPlayer3D with bus = "SFX", not through this autoload.
##
## Reacts to Events broadcasts so game code never has to call Audio directly
## for common lifecycle sounds (pickup ding, door open, puzzle resolution).
## See docs/interactables.md §8.

const REGISTRY_PATH: String = "res://audio/cue_registry.tres"

const BUS_MASTER: StringName = &"Master"
const BUS_MUSIC: StringName = &"Music"
const BUS_SFX: StringName = &"SFX"
const BUS_DIALOGUE: StringName = &"Dialogue"
const BUS_AMBIENCE: StringName = &"Ambience"
const BUS_UI: StringName = &"UI"
const BUS_WALKIE: StringName = &"Walkie"
const BUS_COMPANION: StringName = &"Companion"

## Settings keys (see sync_up.md ui_dev table). Default 0.0 dB means
## "unattenuated." Settings autoload writes them; we subscribe to
## settings_applied and re-push to AudioServer.
const SETTINGS_VOLUME_KEYS := {
	BUS_MASTER: "audio.master_volume_db",
	BUS_MUSIC: "audio.music_volume_db",
	BUS_SFX: "audio.sfx_volume_db",
	BUS_DIALOGUE: "audio.dialogue_volume_db",
	BUS_AMBIENCE: "audio.ambience_volume_db",
}

var _registry: Resource  # CueRegistry instance; untyped to avoid class_name timing
var _music_player: AudioStreamPlayer
var _ambience_player: AudioStreamPlayer
var _dialogue_player: AudioStreamPlayer
var _walkie_player: AudioStreamPlayer
var _companion_player: AudioStreamPlayer
var _sfx_pool: Array[AudioStreamPlayer] = []
var _sfx_next: int = 0

## Emitted when a walkie line finishes playing (natural end OR stop_walkie()).
## Walkie autoload uses this to advance its FIFO queue.
signal walkie_finished

## Emitted when a companion line finishes (natural end OR stop_companion()).
## Companion autoload uses this to advance its FIFO queue.
signal companion_finished


func _ready() -> void:
	# Audio must keep running while the tree is paused (dialogue / puzzle /
	# pause menu). Otherwise music stops dead instead of being ducked by the
	# sidechain compressor — which is the whole point of the 5-bus layout.
	process_mode = Node.PROCESS_MODE_ALWAYS

	_load_registry()
	_create_players()
	_connect_event_reactions()
	_apply_volumes_from_settings()
	# Resubscribe whenever ui_dev's Settings autoload announces changes.
	Events.settings_applied.connect(_apply_volumes_from_settings)


# ---- Public API ---------------------------------------------------------

func play_sfx(id: StringName) -> void:
	if _registry == null:
		push_error("Audio: registry not loaded; call arrived before _ready")
		return
	var cues: Dictionary = _registry.get("cues")
	if not cues.has(id):
		push_error("Audio cue not registered: %s" % id)
		return
	var cue: Resource = cues[id]
	if cue == null:
		push_error("Audio: cue %s is null in registry" % id)
		return
	var sample: Array = cue.sample()
	var stream: AudioStream = sample[0]
	if stream == null: return  # empty pool — silent, not an error (v1 cues have no streams yet)

	var player := _pick_sfx_player()
	player.stream = stream
	player.volume_db = sample[1]
	player.pitch_scale = sample[2]
	player.bus = cue.bus
	player.play()


func play_music(stream: AudioStream, fade_in: float = 0.8) -> void:
	if stream == null: return
	# Singleton bus: starting a track stops whichever was playing. Each
	# new track loops by default — set loop=false on the AudioStream
	# resource if you ever want a one-shot here.
	if _music_player.playing and _music_player.stream == stream:
		return  # already playing this track — don't restart
	_force_loop(stream)
	_music_player.stream = stream
	_music_player.volume_db = -40.0 if fade_in > 0.0 else 0.0
	_music_player.play()
	if fade_in > 0.0:
		var tween := create_tween()
		tween.tween_property(_music_player, "volume_db", 0.0, fade_in)


## Mutates the supplied AudioStream resource so its `loop` (or `loop_mode`)
## is enabled. Most music files in this project are imported with loop=false
## by default; rather than re-importing each one, we flip the runtime
## resource flag here. Idempotent — calling on an already-looping stream
## is a no-op.
func _force_loop(stream: AudioStream) -> void:
	if stream == null: return
	if "loop" in stream:
		if not bool(stream.get("loop")):
			stream.set("loop", true)
	elif "loop_mode" in stream:
		# AudioStreamWAV uses loop_mode (enum: 0 disabled, 1 forward, ...).
		if int(stream.get("loop_mode")) == 0:
			stream.set("loop_mode", 1)


func stop_music(fade_out: float = 1.0) -> void:
	if fade_out <= 0.0:
		_music_player.stop()
		return
	var tween := create_tween()
	tween.tween_property(_music_player, "volume_db", -40.0, fade_out)
	tween.tween_callback(_music_player.stop)


## Pause music + ambience playback in place. Position is preserved, so
## resume_music() picks up where it stopped — used by cutscenes that need
## the soundtrack out of the way for a few seconds without restarting it.
## Idempotent.
func pause_music() -> void:
	if _music_player != null and _music_player.playing:
		_music_player.stream_paused = true
	if _ambience_player != null and _ambience_player.playing:
		_ambience_player.stream_paused = true


## Resume music + ambience after a pause_music() call. Idempotent — safe
## to call even if nothing was paused.
func resume_music() -> void:
	if _music_player != null:
		_music_player.stream_paused = false
	if _ambience_player != null:
		_ambience_player.stream_paused = false


func play_ambience(stream: AudioStream, fade_in: float = 1.5) -> void:
	if stream == null: return
	_ambience_player.stream = stream
	_ambience_player.volume_db = -40.0 if fade_in > 0.0 else 0.0
	_ambience_player.play()
	if fade_in > 0.0:
		var tween := create_tween()
		tween.tween_property(_ambience_player, "volume_db", 0.0, fade_in)


## Called by the Dialogue autoload for TTS lines. Routes through the
## Dialogue bus so the sidechain compressors on Music + Ambience duck
## against it. See §8.1.
##
## Dialogue plays SERIALLY — each call enqueues, plays when previous finishes.
var _dialogue_queue: Array[AudioStream] = []

func play_dialogue(stream: AudioStream) -> void:
	if stream == null: return
	_dialogue_queue.append(stream)
	_play_next_dialogue_if_idle()


func stop_dialogue() -> void:
	_dialogue_queue.clear()
	_dialogue_player.stop()


## Walkie channel — phone-FX filtered voice. Used by the Walkie autoload for
## in-level narration from DialTone/Nyx. Plays on the dedicated Walkie bus
## (bandpass + distortion) so it reads as radio chatter, not standard dialogue.
## Single-stream-at-a-time; the Walkie autoload queues lines and drives the
## next one via the walkie_finished signal.
func play_walkie(stream: AudioStream) -> void:
	if stream == null: return
	# Kill standard dialogue so the two channels never overlap — last speaker
	# wins per the concurrency rule in docs/level_one_arc.md §4.7.
	stop_dialogue()
	_walkie_player.stream = stream
	_walkie_player.play()


func stop_walkie() -> void:
	if _walkie_player.playing:
		_walkie_player.stop()
	# Emit manually on explicit stop so Walkie queue advances / UI hides.
	walkie_finished.emit()


## Companion channel — diegetic in-world voice with reverb + slight low-pass
## (the "across the room" feel). Used by the Companion autoload for nearby
## NPC narration that ISN'T radio chatter. Distinct bus from Walkie so the two
## channels can be tuned independently.
func play_companion(stream: AudioStream) -> void:
	if stream == null: return
	# Don't kill walkie/dialogue here; companion may layer with ambient SFX
	# but the autoload's FIFO ensures it never overlaps another companion line.
	_companion_player.stream = stream
	_companion_player.play()


func stop_companion() -> void:
	if _companion_player.playing:
		_companion_player.stop()
	companion_finished.emit()


func _play_next_dialogue_if_idle() -> void:
	if _dialogue_player.playing: return
	if _dialogue_queue.is_empty(): return
	var next_stream: AudioStream = _dialogue_queue.pop_front()
	_dialogue_player.stream = next_stream
	_dialogue_player.play()


func _on_dialogue_finished() -> void:
	_play_next_dialogue_if_idle()


# ---- Internals ----------------------------------------------------------

func _load_registry() -> void:
	if not ResourceLoader.exists(REGISTRY_PATH):
		push_error("Audio: cue registry missing at %s" % REGISTRY_PATH)
		return
	_registry = load(REGISTRY_PATH)
	if _registry == null:
		push_error("Audio: %s is not a CueRegistry" % REGISTRY_PATH)


func _create_players() -> void:
	_music_player = _make_player(BUS_MUSIC)
	_ambience_player = _make_player(BUS_AMBIENCE)
	_dialogue_player = _make_player(BUS_DIALOGUE)
	# Serial dialogue playback — `finished` advances the queue.
	_dialogue_player.finished.connect(_on_dialogue_finished)
	_walkie_player = _make_player(BUS_WALKIE)
	# Natural end: re-emit our signal so the Walkie autoload can dequeue.
	_walkie_player.finished.connect(func(): walkie_finished.emit())
	_companion_player = _make_player(BUS_COMPANION)
	_companion_player.finished.connect(func(): companion_finished.emit())
	# SFX pool: 6 players round-robin handles overlapping short sounds without
	# cutting each other off. Overflow silently reuses oldest.
	for i in range(6):
		_sfx_pool.append(_make_player(BUS_SFX))


func _make_player(bus: StringName) -> AudioStreamPlayer:
	var p := AudioStreamPlayer.new()
	p.bus = bus
	add_child(p)
	return p


func _pick_sfx_player() -> AudioStreamPlayer:
	var p := _sfx_pool[_sfx_next]
	_sfx_next = (_sfx_next + 1) % _sfx_pool.size()
	return p


func _connect_event_reactions() -> void:
	# "One file owns what sound plays when what happens" — docs §8.5.
	Events.item_added.connect(func(_id: StringName) -> void: play_sfx(&"pickup_ding"))
	Events.door_opened.connect(func(_id: StringName) -> void: play_sfx(&"door_open"))
	Events.puzzle_solved.connect(func(_id: StringName) -> void: play_sfx(&"hack_success"))
	Events.puzzle_failed.connect(func(_id: StringName) -> void: play_sfx(&"hack_fail"))
	Events.coin_collected.connect(func(_coin: Node) -> void: play_sfx(&"coin_pickup"))


func _apply_volumes_from_settings() -> void:
	# ui_dev's Settings autoload uses ConfigFile-style (section, key, fallback).
	# Our dotted keys (audio.music_volume_db) split on the first dot.
	var settings := get_tree().root.get_node_or_null(^"Settings")
	for bus_name: StringName in SETTINGS_VOLUME_KEYS:
		var dotted: String = SETTINGS_VOLUME_KEYS[bus_name]
		var parts := dotted.split(".", true, 1)
		var section: String = parts[0] if parts.size() >= 1 else ""
		var key: String = parts[1] if parts.size() >= 2 else dotted
		var db: float = 0.0
		if settings != null and settings.has_method(&"get_value"):
			var v: Variant = settings.get_value(section, key, 0.0)
			if typeof(v) == TYPE_FLOAT or typeof(v) == TYPE_INT:
				db = float(v)
		var idx := AudioServer.get_bus_index(bus_name)
		if idx >= 0:
			AudioServer.set_bus_volume_db(idx, db)
