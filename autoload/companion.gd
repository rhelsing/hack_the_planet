extends Node

## Companion voice channel — diegetic in-world narration from Glitch / DialTone
## when present in person / Nyx (post-meet) / etc. Plays on the dedicated
## Companion bus (reverb + slight low-pass = "across the room" feel) instead
## of the Walkie bus's phone FX. NO ownership flag gate — companions can talk
## any time they're present.
##
## Mirrors Walkie's queue + cache logic; lives as a sibling autoload so the
## two channels never share a queue, but synth requests share the same TTS
## cache via Dialogue._cache_path_read / _cache_path_write.
##
## Contract:
##   Companion.speak(character, text) — enqueue, synth on cache miss, play.
##   Companion.stop() — abort current + clear queue.
## Signals:
##   line_started(character, text) — fires when a line begins playing.
##   line_ended() — fires when the current line finishes.

signal line_started(character: String, text: String)
signal line_ended

const ELEVEN_API_URL: String = "https://api.elevenlabs.io/v1/text-to-speech/%s"
const ELEVEN_MODEL_ID: String = "eleven_flash_v2_5"
const TtsText: GDScript = preload("res://autoload/tts_text.gd")

var verbose: bool = true

var _queue: Array = []
var _playing: bool = false
var _http: HTTPRequest
var _in_flight: Dictionary = {}


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	_http = HTTPRequest.new()
	_http.request_completed.connect(_on_http_completed)
	add_child(_http)
	Audio.companion_finished.connect(_on_companion_finished)
	_log("ready")


func _log(msg: String) -> void:
	if verbose:
		print("[Companion] %s" % msg)


func speak(character: String, text: String) -> void:
	_log('speak: character="%s" text="%s"' % [character, text])
	_queue.append({"character": character, "text": text})
	_dispatch_if_idle()


func stop() -> void:
	_log("stop")
	_queue.clear()
	Audio.stop_companion()


## Pause/resume the active line. Mirror of Walkie.pause — see that for the
## why (Audio is PROCESS_MODE_ALWAYS, so the cutscene engine needs an
## explicit hook to halt voice playback during pause-menu).
func pause(on: bool) -> void:
	Audio.pause_companion(on)


func _dispatch_if_idle() -> void:
	# In-flight guard: a previous request is still mid-flight on _http. A
	# second _http.request() while busy returns ERR_BUSY (44), and the err
	# branch below clears _in_flight, which makes _on_http_completed early-
	# return for the original request — no playback, no line_ended, cutscene
	# soft-locks. Re-enter only after the in-flight request settles.
	if _playing or _queue.is_empty() or not _in_flight.is_empty():
		return
	var next: Dictionary = _queue[0]
	var character: String = next.character
	var text: String = next.text
	var voices: Resource = Dialogue._voices
	if voices == null or not voices.has_voice(character):
		_log('dispatch: no voice for "%s" — display-only' % character)
		_queue.pop_front()
		_play_silent(character, text)
		return
	var voice_id: String = voices.get_voice_id(character)
	# Per-line model override (see walkie.gd dispatch for rationale — same
	# pattern). Companion lines come in as raw strings, so we parse the
	# `[#model=v3]` tag ourselves and strip it before TTS / display.
	var line_model: String = TtsText.parse_model_tag(text, ELEVEN_MODEL_ID)
	var clean_text: String = TtsText.strip_model_tag(text)
	# Resolve template tokens ({player_handle}, etc.) before the cache key is
	# computed. Same template can render as 4 different mp3s (one per handle);
	# the other 3 get queued in VoicePrimer as background work.
	var resolved_text: String = LineLocalizer.resolve(clean_text)
	VoicePrimer.enqueue_siblings(character, clean_text, resolved_text)
	var read_path: String = Dialogue._cache_path_read(character, resolved_text, voice_id, line_model)
	if not read_path.is_empty():
		_log("dispatch: CACHE HIT %s%s" % [read_path, (" [model=%s]" % line_model) if line_model != ELEVEN_MODEL_ID else ""])
		_queue.pop_front()
		_play_from_path(read_path, character, resolved_text)
		return

	# Exported builds must rely on res://audio/voice_cache/ — never POST to
	# ElevenLabs at runtime. Symmetrical with Dialogue (dialogue.gd:346) and
	# Walkie (walkie.gd:98). Without this gate, a build that accidentally
	# shipped with the API key embedded would still synth on cache miss,
	# leaking the key + costing API calls. Editor playtests still synth as
	# normal — OS.has_feature("template") is true ONLY in exports.
	if OS.has_feature("template"):
		_log("dispatch: cache MISS in exported build — display-only")
		_queue.pop_front()
		_play_silent(character, resolved_text)
		return

	if Dialogue._api_key.is_empty():
		_log("dispatch: cache MISS + no API key — display-only")
		_queue.pop_front()
		_play_silent(character, resolved_text)
		return

	_log("dispatch: cache MISS — requesting from ElevenLabs%s" % ((" [model=%s]" % line_model) if line_model != ELEVEN_MODEL_ID else ""))
	var write_path: String = Dialogue._cache_path_write(character, resolved_text, voice_id, line_model)
	_in_flight = {
		"character": character,
		"text": resolved_text,
		"voice_id": voice_id,
		"path": write_path,
		"model_id": line_model,
	}
	var url: String = ELEVEN_API_URL % voice_id
	var headers: PackedStringArray = [
		"Accept: audio/mpeg",
		"Content-Type: application/json",
		"xi-api-key: " + Dialogue._api_key,
	]
	var body: String = JSON.stringify({
		"text": TtsText.for_eleven_labs(resolved_text),
		"model_id": line_model,
		"voice_settings": {"stability": 0.5, "similarity_boost": 0.5},
	})
	var err: int = _http.request(url, headers, HTTPClient.METHOD_POST, body)
	if err != OK:
		_log("dispatch: HTTPRequest err=%d" % err)
		_in_flight = {}
		_queue.pop_front()
		_dispatch_if_idle()


func _on_http_completed(_result: int, response_code: int, _headers: PackedStringArray, body: PackedByteArray) -> void:
	if _in_flight.is_empty():
		return
	var req: Dictionary = _in_flight
	_in_flight = {}
	if response_code == 200 and body.size() > 0:
		var file := FileAccess.open(req.path, FileAccess.WRITE)
		if file != null:
			file.store_buffer(body)
			file.close()
			_log("synth OK — cached %d bytes to %s" % [body.size(), req.path])
			_queue.pop_front()
			_play_from_path(req.path, req.character, req.text)
			return
		_log("synth OK but FileAccess write failed for %s" % req.path)
	else:
		_log("synth FAIL code=%d" % response_code)
	_queue.pop_front()
	_dispatch_if_idle()


func _play_from_path(path: String, character: String, text: String) -> void:
	# Two-path load matching Dialogue._play_cached + Walkie._play_from_path.
	# FileAccess for editor + un-imported files; ResourceLoader as fallback
	# for exports and stale-import cases.
	var stream: AudioStream = null
	var file := FileAccess.open(path, FileAccess.READ)
	if file != null:
		var mp3 := AudioStreamMP3.new()
		mp3.data = file.get_buffer(file.get_length())
		file.close()
		stream = mp3
	else:
		stream = load(path) as AudioStream
		if stream == null:
			_log("play: both FileAccess and ResourceLoader failed for %s" % path)
			_dispatch_if_idle()
			return
		_log("play: FileAccess failed but ResourceLoader resolved %s" % path)
	_playing = true
	line_started.emit(character, text)
	Audio.play_companion(stream)


func _on_companion_finished() -> void:
	if not _playing:
		return
	_playing = false
	line_ended.emit()


## Display-only line: emits line_started, plays the open click, holds for a
## duration matched to walkie_ui's typewriter, emits line_ended. Used when
## TTS synthesis is unavailable so consumers awaiting line_ended don't hang
## and walkie_ui still renders the subtitle. cps matches scroll_balloon's
## typing speed.
## Match walkie_ui.typewrite_speed so the autoload's timer expires no
## sooner than the typewriter completes. Raw text.length() is ≥ visible
## char count (emphasis markers strip), so chars/CPS is a safe upper bound
## on typewriter duration — the line is guaranteed fully visible before
## the tail pad starts counting.
const _SILENT_CPS: float = 55.0
## Hold the fully-displayed line on screen this long after the typewriter
## finishes, before emitting line_ended (which triggers walkie_ui's fade).
const _SILENT_TAIL_PAD: float = 4.0

func _play_silent(character: String, text: String) -> void:
	_playing = true
	line_started.emit(character, text)
	Audio.play_sfx(&"ui_move")
	var duration: float = float(text.length()) / _SILENT_CPS + _SILENT_TAIL_PAD
	await get_tree().create_timer(duration).timeout
	if _playing:
		_playing = false
		line_ended.emit()
		_dispatch_if_idle()
	_dispatch_if_idle()
