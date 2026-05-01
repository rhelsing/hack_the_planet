extends Node

## Non-positional audio — music, ambience, dialogue voice, and SFX cues.
## Positional SFX (door creak at the door) lives on the interactable as
## AudioStreamPlayer3D with bus = "SFX", not through this autoload.
##
## Reacts to Events broadcasts so game code never has to call Audio directly
## for common lifecycle sounds (pickup ding, door open, puzzle resolution).
## See docs/interactables.md §8.

const REGISTRY_PATH: String = "res://audio/cue_registry.tres"

## Default music rotation. First entry is the locked opener (always plays at
## the start of each cycle); the rest shuffle. Single source of truth so
## menu, levels, and "resume after override" all use the same list.
const DEFAULT_MUSIC_PATHS := [
	"res://audio/music/hackers_theme.mp3",
	"res://audio/music/one_love.mp3",
	"res://audio/music/dnb.mp3",
	"res://audio/music/dopo_goto_disc3.mp3",
	"res://audio/music/dopo_goto_disc3_01.mp3",
	"res://audio/music/dopo_goto_disc3_02.mp3",
	"res://audio/music/interpersonal_arbitrage.mp3",
	"res://audio/music/this_is_me_letting_you_go.mp3",
	"res://audio/music/for_new_drugs.mp3",
	"res://audio/music/tyler_ono_fast_paced_low.mp3",
	"res://audio/music/tyler_ono_fast_paced_high.mp3",
	"res://audio/music/vibes_c.mp3",
	"res://audio/music/vibes_d.mp3",
	"res://audio/music/slow_jam.mp3",
	"res://audio/music/tina.mp3",
]

## Per-track linear-gain overrides for the default rotation. Keys are paths
## from DEFAULT_MUSIC_PATHS; values are linear gain (1.0 = unchanged, 0.5 =
## -6 dB, 2.0 = +6 dB). Tracks not listed here play at 1.0. Adjust here when
## a particular master is too hot or too quiet relative to the rotation.
const DEFAULT_MUSIC_GAINS: Dictionary = {}

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

## Preloaded SFX streams kept alive for the session so first-play hitches
## don't happen mid-gameplay. Populated at boot by _preload_all_sfx() —
## walks res://audio/sfx/ recursively, loads every audio file. Music +
## voice_cache are intentionally NOT preloaded (music streams are big
## and dialogue lines are loaded on-demand by the TTS cache path).
var _preloaded_sfx: Array[AudioStream] = []
const SFX_PRELOAD_DIRS: Array[String] = ["res://audio/sfx/"]
const PRELOAD_AUDIO_EXTS: Array[String] = [".mp3", ".wav", ".ogg"]

## Music playlist state. Three modes:
##   1. Single-track loop  — `play_music(stream)`. Force-loops the stream
##      (`_music_player.finished` never fires).
##   2. Playlist           — `play_playlist([s1, s2, ...])`. Each track plays
##      un-looped; `finished` advances to the next. Wraps when list ends.
##   3. One-shot interrupt — `play_oneshot_music(stream)`. Plays once over
##      whatever was current; on `finished` returns to the playlist (or
##      stays silent if no playlist was active).
var _playlist: Array[AudioStream] = []
## Parallel to _playlist: linear gain per track (1.0 default). Applied as the
## final volume_db target by _play_track_no_loop after the fade-in completes.
var _playlist_gains: Array[float] = []
var _playlist_idx: int = 0
var _playlist_shuffle: bool = false
## When true, _playlist[0] is pinned — it always plays at the start of each
## cycle and is excluded from shuffling. Useful for an "intro" or signature
## opening track that should bookend every rotation.
var _playlist_lock_first: bool = false
var _oneshot_active: bool = false
## True while a single-track override (play_music) is replacing an active
## playlist. resume_default_playlist_if_overridden() reads this to decide
## whether to swap back to the default rotation.
var _playlist_overridden: bool = false

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
	# Preload every SFX file so first-play decoder hitches don't surface
	# mid-gameplay. Music intentionally excluded — those streams are big.
	_preload_all_sfx()


## Walk every directory in SFX_PRELOAD_DIRS recursively and load() any audio
## file. Loaded streams are held in _preloaded_sfx so Godot's resource cache
## doesn't drop them — the next play_sfx / per-pool .play() hits a warm
## resource instead of paying decode-table init mid-gameplay.
##
## Reports total streams loaded so the count shows up in launch logs and
## you can sanity-check coverage as you add new SFX folders.
func _preload_all_sfx() -> void:
	for root_dir: String in SFX_PRELOAD_DIRS:
		_preload_dir_recursive(root_dir)
	print("[Audio] preloaded %d sfx streams from %s" % [
		_preloaded_sfx.size(), str(SFX_PRELOAD_DIRS)])


func _preload_dir_recursive(dir_path: String) -> void:
	var dir := DirAccess.open(dir_path)
	if dir == null:
		return
	dir.list_dir_begin()
	var entry: String = dir.get_next()
	while not entry.is_empty():
		var full: String = dir_path.path_join(entry)
		if dir.current_is_dir():
			if entry != "." and entry != "..":
				_preload_dir_recursive(full)
		else:
			for ext: String in PRELOAD_AUDIO_EXTS:
				if entry.ends_with(ext):
					var stream: AudioStream = load(full) as AudioStream
					if stream != null:
						_preloaded_sfx.append(stream)
					break
		entry = dir.get_next()
	dir.list_dir_end()


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
	# Single-track loop: replaces whatever was playing. If a playlist was
	# active, mark _playlist_overridden so a later resume_default_playlist
	# call knows to swap back. The playlist itself is cleared because the
	# new track owns the bus indefinitely.
	if not _playlist.is_empty():
		_playlist_overridden = true
	_playlist.clear()
	_oneshot_active = false
	if _music_player.playing and _music_player.stream == stream:
		return  # already playing this track — don't restart
	_force_loop(stream)
	_music_player.stream = stream
	_music_player.volume_db = -40.0 if fade_in > 0.0 else 0.0
	_music_player.play()
	if fade_in > 0.0:
		var tween := create_tween()
		tween.tween_property(_music_player, "volume_db", 0.0, fade_in)


## Start a sequenced playlist. Each track plays un-looped; when one finishes,
## the next starts. The list wraps to index 0 when it reaches the end (so
## `play_playlist([...])` plays "forever" rotating through). Set
## `shuffle = true` to randomize order each cycle. Set `lock_first = true`
## to pin `streams[0]` as the cycle opener — it always plays at index 0,
## and shuffling only affects `streams[1..end]`.
##
## Example:
##     # Intro track plays first, the other 3 shuffle each rotation.
##     Audio.play_playlist([intro, song_a, song_b, song_c], 0.8, true, true)
##
## A one-shot interrupt (play_oneshot_music) returns to the next playlist
## track when it finishes.
func play_playlist(streams: Array, fade_in: float = 0.8,
		shuffle: bool = false, lock_first: bool = false,
		gains: Array = []) -> void:
	if streams.is_empty():
		stop_music(0.5)
		return
	_playlist = []
	_playlist_gains = []
	for i: int in range(streams.size()):
		var s: Variant = streams[i]
		if s is AudioStream:
			_playlist.append(s)
			var g: float = 1.0
			if i < gains.size():
				g = float(gains[i])
			_playlist_gains.append(g)
	if _playlist.is_empty():
		return
	_playlist_shuffle = shuffle
	_playlist_lock_first = lock_first
	_shuffle_playlist_if_needed()
	_playlist_idx = 0
	_oneshot_active = false
	_playlist_overridden = false
	_play_track_no_loop(_playlist[_playlist_idx], fade_in, _gain_for_index(_playlist_idx))


## Convenience: start the project-wide default playlist. Locks the first
## track (signature opener), shuffles the rest. Single source of truth lives
## in DEFAULT_MUSIC_PATHS at the top of this file. Per-track linear gains
## come from DEFAULT_MUSIC_GAINS (default 1.0 for any path not in the dict).
func play_default_playlist(fade_in: float = 1.5) -> void:
	var streams: Array = []
	var gains: Array = []
	for path: String in DEFAULT_MUSIC_PATHS:
		if ResourceLoader.exists(path):
			var s: Resource = load(path)
			if s is AudioStream:
				streams.append(s)
				gains.append(float(DEFAULT_MUSIC_GAINS.get(path, 1.0)))
	if streams.is_empty():
		return
	play_playlist(streams, fade_in, true, true, gains)


## Resume the default playlist iff a single-track override (play_music) is
## currently in control. Used by level scripts to "snap back" to the regular
## music rotation after a story override (e.g. dust-motions interlude that
## ran from a level-2 walkie until level-3 starts). No-op if music is
## already playing the playlist or has been explicitly stopped.
func resume_default_playlist_if_overridden(fade_in: float = 1.0) -> void:
	if not _playlist_overridden:
		return
	play_default_playlist(fade_in)


## Toggle whether index 0 of the active playlist is pinned (always plays at
## the start of each cycle). Affects future cycles only — the current track
## plays out untouched. Used by the main menu to give "New Game" a fixed
## signature opener while "Continue" / "Load" shuffle every track equally.
func set_playlist_lock_first(on: bool) -> void:
	_playlist_lock_first = on


## Skip to the next track in the playlist immediately, without waiting for
## the current track to finish. Used by Continue / Load on the main menu so
## the player drops out of the locked-first opener (hackers_theme) and into
## the shuffled rotation without having to listen out the whole opener.
## Mirrors the natural-end advance in `_on_music_finished`: increment the
## index, reshuffle on wrap, fade in the new track. No-op on empty playlist.
func advance_playlist(fade_in: float = 0.8) -> void:
	if _playlist.is_empty():
		return
	_playlist_idx += 1
	if _playlist_idx >= _playlist.size():
		_playlist_idx = 0
		_shuffle_playlist_if_needed()
	_play_track_no_loop(_playlist[_playlist_idx], fade_in, _gain_for_index(_playlist_idx))


## Skip to the previous track. Wraps to the end of the current rotation
## without reshuffling — backward navigation should feel deterministic, not
## reroll the whole playlist. Used by the `music_prev` input action.
func previous_playlist_track(fade_in: float = 0.8) -> void:
	if _playlist.is_empty():
		return
	_playlist_idx -= 1
	if _playlist_idx < 0:
		_playlist_idx = _playlist.size() - 1
	_play_track_no_loop(_playlist[_playlist_idx], fade_in, _gain_for_index(_playlist_idx))


# Reshuffle the playlist's tail if shuffling is enabled. With `lock_first`,
# index 0 stays pinned and only [1..end] is shuffled. Called once at start
# and again whenever the playlist wraps so each cycle is freshly randomized.
# Shuffles tracks + gains as paired tuples so per-track gain stays bound to
# its track across rotations.
func _shuffle_playlist_if_needed() -> void:
	if not _playlist_shuffle or _playlist.size() <= 1:
		return
	var start_i: int = 1 if _playlist_lock_first else 0
	var indices: Array[int] = []
	for i: int in range(start_i, _playlist.size()):
		indices.append(i)
	indices.shuffle()
	var new_streams: Array[AudioStream] = []
	var new_gains: Array[float] = []
	if _playlist_lock_first:
		new_streams.append(_playlist[0])
		new_gains.append(_gain_for_index(0))
	for i: int in indices:
		new_streams.append(_playlist[i])
		new_gains.append(_gain_for_index(i))
	_playlist = new_streams
	_playlist_gains = new_gains


# Defensive helper: returns the gain for index `i`, or 1.0 if out-of-range
# or _playlist_gains is empty. Keeps the per-track gain plumbing safe even
# if a future caller forgets to populate gains alongside streams.
func _gain_for_index(i: int) -> float:
	if i < 0 or i >= _playlist_gains.size():
		return 1.0
	return _playlist_gains[i]


## Interrupt with a single un-looped track. When it finishes, the playlist
## resumes from its next track. If no playlist is active, music goes silent
## after the one-shot ends.
##
## Use this for victory stings, post-cutscene cues, ambient one-offs.
func play_oneshot_music(stream: AudioStream, fade_in: float = 0.5) -> void:
	if stream == null: return
	_oneshot_active = true
	_play_track_no_loop(stream, fade_in)


# Plays `stream` with looping disabled so `finished` will fire and our
# playlist/one-shot advancer can react. Duplicates the resource so we don't
# mutate a shared AudioStream's loop flag for callers using play_music on
# the same MP3. `gain` is linear (1.0 = unchanged); converted to dB and
# applied as the fade target — for gain=1.0 this is 0 dB (existing behavior).
func _play_track_no_loop(stream: AudioStream, fade_in: float, gain: float = 1.0) -> void:
	if stream == null: return
	var s: AudioStream = stream.duplicate()
	if "loop" in s:
		s.set("loop", false)
	elif "loop_mode" in s:
		s.set("loop_mode", 0)
	var target_db: float = linear_to_db(gain) if gain > 0.0 else -80.0
	_music_player.stream = s
	_music_player.volume_db = -40.0 if fade_in > 0.0 else target_db
	_music_player.play()
	if fade_in > 0.0:
		var tween := create_tween()
		tween.tween_property(_music_player, "volume_db", target_db, fade_in)


# `_music_player.finished` callback. Only fires for un-looped tracks
# (single-track loop mode never reaches it). Advances the playlist or
# resumes from a one-shot.
func _on_music_finished() -> void:
	if _oneshot_active:
		_oneshot_active = false
		if _playlist.is_empty():
			return
		_play_track_no_loop(_playlist[_playlist_idx], 0.4, _gain_for_index(_playlist_idx))
		return
	if _playlist.is_empty():
		return
	_playlist_idx += 1
	if _playlist_idx >= _playlist.size():
		_playlist_idx = 0
		_shuffle_playlist_if_needed()
	_play_track_no_loop(_playlist[_playlist_idx], 0.4, _gain_for_index(_playlist_idx))


## Listens for music_next / music_prev input actions and skips tracks. Gated
## on a non-empty playlist + no active one-shot so battle-scene music
## (`play_music` clears _playlist) and post-L4 victory music can't be
## skipped. Audio autoload runs in PROCESS_MODE_ALWAYS so this also fires
## while the game is paused — players can re-roll the rotation from the
## pause menu.
func _unhandled_input(event: InputEvent) -> void:
	if _playlist.is_empty() or _oneshot_active:
		return
	if event.is_action_pressed(&"music_next"):
		advance_playlist(0.5)
	elif event.is_action_pressed(&"music_prev"):
		previous_playlist_track(0.5)


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
	# Clear playlist + one-shot + override state so we don't bounce back
	# into music right after the caller asked for silence.
	_playlist.clear()
	_oneshot_active = false
	_playlist_overridden = false
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
##
## bus_override: when non-empty, the line plays on that bus instead of Walkie.
## Used by cutscene LineStep.bus_override to route an in-person speaker
## (e.g. Splice) through Walkie's proven subtitle/queue pipeline while
## bypassing the radio FX. The override lasts only for this stream — the
## next play_walkie() with no override snaps back to BUS_WALKIE.
func play_walkie(stream: AudioStream, bus_override: StringName = &"") -> void:
	if stream == null: return
	# Kill standard dialogue so the two channels never overlap — last speaker
	# wins per the concurrency rule in docs/level_one_arc.md §4.7.
	stop_dialogue()
	_walkie_player.bus = bus_override if bus_override != &"" else BUS_WALKIE
	_walkie_player.stream = stream
	_walkie_player.play()


func stop_walkie() -> void:
	# Diagnostic: log every explicit stop. The walkie_finished emission below
	# eventually drives walkie_ui's fade-out tween, so any caller hitting this
	# is a candidate for "subtitle disappeared mysteriously."
	print("[audio] stop_walkie called (was_playing=%s) — emitting walkie_finished" % _walkie_player.playing)
	if _walkie_player.playing:
		_walkie_player.stop()
	# Emit manually on explicit stop so Walkie queue advances / UI hides.
	walkie_finished.emit()


## Pause/resume the active walkie line in place. Used by the cutscene engine
## to honor pause-menu open: Audio is PROCESS_MODE_ALWAYS so its playback is
## not paused by the tree pause; this method is the explicit hook. Idempotent;
## safe to call when nothing is playing. Does NOT emit walkie_finished —
## paused playback is still "in flight," it just doesn't progress.
func pause_walkie(on: bool) -> void:
	if _walkie_player != null:
		_walkie_player.stream_paused = on


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
	print("[audio] stop_companion called (was_playing=%s) — emitting companion_finished" % _companion_player.playing)
	if _companion_player.playing:
		_companion_player.stop()
	companion_finished.emit()


## Pause/resume the active companion line. Same contract as pause_walkie.
func pause_companion(on: bool) -> void:
	if _companion_player != null:
		_companion_player.stream_paused = on


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
	# Hook playlist advance + one-shot return on natural track end. Looped
	# (single-track loop mode) tracks never fire `finished`, so this is a
	# no-op for the legacy play_music path.
	_music_player.finished.connect(_on_music_finished)
	_ambience_player = _make_player(BUS_AMBIENCE)
	_dialogue_player = _make_player(BUS_DIALOGUE)
	# Serial dialogue playback — `finished` advances the queue.
	_dialogue_player.finished.connect(_on_dialogue_finished)
	_walkie_player = _make_player(BUS_WALKIE)
	# Natural end: re-emit our signal so the Walkie autoload can dequeue.
	# Diagnostic log captures the bus we were on at end — useful for
	# correlating with bus_override (e.g. Splice on bus=Companion).
	_walkie_player.finished.connect(func():
		print("[audio] _walkie_player.finished (bus=%s) — emitting walkie_finished" % _walkie_player.bus)
		walkie_finished.emit())
	_companion_player = _make_player(BUS_COMPANION)
	_companion_player.finished.connect(func():
		print("[audio] _companion_player.finished — emitting companion_finished")
		companion_finished.emit())
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
