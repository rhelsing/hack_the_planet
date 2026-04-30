extends Node

## Pause-respecting audio façade for the cutscene engine. Wraps the existing
## Walkie / Companion / Audio autoloads so the cutscene driver doesn't have
## to know about them directly.
##
## Pause is the load-bearing reason this exists. Audio (and Walkie/Companion
## by extension) runs PROCESS_MODE_ALWAYS so the sidechain compressor can
## duck during pause-menu open. That means `await Walkie.line_ended` would
## fire through pause and the cutscene would plow ahead silently. This
## service intercepts that: pause(true) tells Walkie + Companion to halt
## their active line player; the underlying line_ended doesn't fire while
## paused, so the awaiter stays parked.

## Re-emitted from Walkie/Companion so the cutscene player has a single
## signal to await regardless of channel.
signal line_ended

@onready var _walkie: Node = get_node_or_null(^"/root/Walkie")
@onready var _companion: Node = get_node_or_null(^"/root/Companion")
@onready var _audio: Node = get_node_or_null(^"/root/Audio")

## Owned by this service so a stinger doesn't compete with line audio. The
## SFX bus carries it; same routing as level SFX.
var _stinger_player: AudioStreamPlayer

## Tracks the currently-active speaking channel so cancel_line knows which
## autoload to stop. Cleared on line_ended.
var _active_channel: String = ""


func _ready() -> void:
	# INHERIT — when the tree pauses, this service's process pauses too.
	# (The actual audio playback is on the existing Audio autoload, which
	# stays ALWAYS for sidechain reasons; we explicitly pause its players
	# via pause_walkie / pause_companion.)
	process_mode = Node.PROCESS_MODE_INHERIT
	_stinger_player = AudioStreamPlayer.new()
	_stinger_player.bus = &"SFX"
	add_child(_stinger_player)
	# Deferred connection is load-bearing. Walkie.line_ended also fans out to
	# walkie_ui._on_line_ended (the subtitle fade-out). If our handler runs
	# first and synchronously, the cutscene awaiter resumes inside this emit
	# chain, dispatches the next LineStep, and walkie_ui._on_line_started
	# fires (snap alpha=1) BEFORE the fade-out handler in the same chain
	# runs — which then fades the just-snapped subtitle of line N+1 to 0.
	# Visible bug: lines with hold_after=0 flash on then disappear. Deferring
	# our handler lets walkie_ui._on_line_ended run first synchronously
	# (fade tween starts), then we resume the cutscene next frame; the next
	# line_started cancels the in-flight fade. Net effect: imperceptible
	# 1-frame alpha dip during transitions.
	if _walkie != null:
		_walkie.line_ended.connect(_on_walkie_line_ended, CONNECT_DEFERRED)
	if _companion != null:
		_companion.line_ended.connect(_on_companion_line_ended, CONNECT_DEFERRED)


# ── Lines ────────────────────────────────────────────────────────────────

## Play one line through the named channel. Returns when the line finishes
## naturally OR when cancel_line() is called. Bus override is per-line and
## doesn't persist past this call.
func play_line(speaker: StringName, text: String, channel: String,
		bus_override: StringName = &"") -> void:
	if speaker == &"" or text.strip_edges().is_empty():
		return
	# bus_override lets a line use one channel's queue + subtitle pipeline
	# while playing on a different bus. The canonical use case is Splice in
	# the L4 cutscene: channel="walkie" + bus_override="Companion" runs
	# through Walkie's proven plumbing but renders with the in-room reverb
	# instead of the radio FX. Currently only walkie honors the override —
	# Companion's bus is fixed.
	_active_channel = channel
	if channel == "walkie":
		if _walkie != null:
			_walkie.speak(String(speaker), text, bus_override)
	else:
		if _companion != null:
			_companion.speak(String(speaker), text)


## Stop the active line, if any. Player calls this on cancel/skip. Emits
## line_ended so any awaiter unblocks cleanly.
func cancel_line() -> void:
	if _active_channel == "walkie" and _walkie != null:
		_walkie.stop()
	elif _active_channel == "companion" and _companion != null:
		_companion.stop()
	# stop() emits walkie_finished/companion_finished, which surfaces here as
	# _on_*_line_ended → line_ended.emit. We don't need to fire it manually.


# ── Music ────────────────────────────────────────────────────────────────

## Swap music. Returns immediately — the fade happens in the background.
## stream=null = stop music with a fade.
func play_music(stream: AudioStream, fade_in: float = 0.4) -> void:
	if _audio == null:
		return
	if stream == null:
		_audio.stop_music(fade_in)
	else:
		_audio.play_music(stream, fade_in)


# ── Stingers ─────────────────────────────────────────────────────────────

## Fire a one-shot SFX layered over current audio. Returns immediately
## unless await_finish=true, in which case the caller blocks on the
## stinger's `finished` signal.
func play_stinger(stream: AudioStream, bus: StringName = &"SFX",
		await_finish: bool = false, volume_db: float = 0.0) -> void:
	if stream == null:
		return
	_stinger_player.stream = stream
	_stinger_player.bus = bus
	_stinger_player.volume_db = volume_db
	_stinger_player.play()
	if await_finish:
		await _stinger_player.finished


# ── Pause ────────────────────────────────────────────────────────────────

## Pause/resume all cutscene-relevant audio: voice (walkie + companion),
## music, ambience, the stinger player. Idempotent. Player calls this when
## the game pauses/resumes.
func pause(on: bool) -> void:
	if _walkie != null and _walkie.has_method(&"pause"):
		_walkie.pause(on)
	if _companion != null and _companion.has_method(&"pause"):
		_companion.pause(on)
	if _audio != null:
		if on:
			# Existing Audio API: pause_music halts both music + ambience.
			# When we're un-pausing we call resume_music for symmetry.
			if _audio.has_method(&"pause_music"):
				_audio.pause_music()
		else:
			if _audio.has_method(&"resume_music"):
				_audio.resume_music()
	if _stinger_player != null:
		_stinger_player.stream_paused = on


# ── Internals ────────────────────────────────────────────────────────────

func _on_walkie_line_ended() -> void:
	if _active_channel == "walkie":
		_active_channel = ""
		line_ended.emit()


func _on_companion_line_ended() -> void:
	if _active_channel == "companion":
		_active_channel = ""
		line_ended.emit()
