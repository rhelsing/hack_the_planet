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
var _sfx_pool: Array[AudioStreamPlayer] = []
var _sfx_next: int = 0


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
	_music_player.stream = stream
	_music_player.volume_db = -40.0 if fade_in > 0.0 else 0.0
	_music_player.play()
	if fade_in > 0.0:
		var tween := create_tween()
		tween.tween_property(_music_player, "volume_db", 0.0, fade_in)


func stop_music(fade_out: float = 1.0) -> void:
	if fade_out <= 0.0:
		_music_player.stop()
		return
	var tween := create_tween()
	tween.tween_property(_music_player, "volume_db", -40.0, fade_out)
	tween.tween_callback(_music_player.stop)


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
func play_dialogue(stream: AudioStream) -> void:
	if stream == null: return
	_dialogue_player.stream = stream
	_dialogue_player.play()


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
