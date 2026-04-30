extends Node

## Walkie-talkie voice channel. In-level narration from DialTone / Nyx that
## plays on the dedicated Walkie audio bus (phone FX) instead of the press-E
## Dialogue balloon. One-way only — no choice UI — per docs/level_one_arc.md §4.
##
## Contract:
##   Walkie.speak(character, text) — enqueue a line, synth if needed, play.
##   Walkie.stop() — abort current + clear queue.
## Signals:
##   line_started(character, text) — fires when a line begins playing.
##   line_ended() — fires when the current line finishes (natural OR stop()).
##
## Lines queue FIFO and never interrupt each other. Rapid triggers are
## sequenced, not chaotic.
##
## TTS cache: shares the read path with autoload/dialogue.gd via Dialogue's
## _cache_path_read. API miss → Dialogue's HTTP queue handles the synth; we
## subscribe to line_ended on the player to dequeue. For simplicity this first
## version uses its own HTTPRequest mirror of Dialogue's pattern; if we extract
## a shared TTS service later, this consolidates.

signal line_started(character: String, text: String)
signal line_ended

const ELEVEN_API_URL: String = "https://api.elevenlabs.io/v1/text-to-speech/%s"
const ELEVEN_MODEL_ID: String = "eleven_flash_v2_5"
const TtsText: GDScript = preload("res://autoload/tts_text.gd")

## Toggle logs via `Walkie.verbose = false`.
var verbose: bool = true

var _queue: Array = []  # [{character, text}, ...]
var _playing: bool = false
var _http: HTTPRequest
var _in_flight: Dictionary = {}  # current API request


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	_http = HTTPRequest.new()
	_http.request_completed.connect(_on_http_completed)
	add_child(_http)
	# Dequeue on natural end OR explicit stop.
	Audio.walkie_finished.connect(_on_walkie_finished)
	_log("ready")


func _log(msg: String) -> void:
	if verbose:
		print("[Walkie] %s" % msg)


## Enqueue a walkie line. Synthesizes on cache miss, plays on hit. FIFO.
func speak(character: String, text: String) -> void:
	_log('speak: character="%s" text="%s"' % [character, text])
	_queue.append({"character": character, "text": text})
	_dispatch_if_idle()


## Abort current line + clear queue.
func stop() -> void:
	_log("stop")
	_queue.clear()
	Audio.stop_walkie()  # will emit walkie_finished → _on_walkie_finished


# ---- internals ----------------------------------------------------------

func _dispatch_if_idle() -> void:
	if _playing or _queue.is_empty():
		return
	var next: Dictionary = _queue[0]
	var character: String = next.character
	var text: String = next.text
	# Resolve voice via Dialogue's voices.tres (single source of truth).
	var voices: Resource = Dialogue._voices
	if voices == null or not voices.has_voice(character):
		_log('dispatch: no voice for "%s" — skipping' % character)
		_queue.pop_front()
		_dispatch_if_idle()
		return
	var voice_id: String = voices.get_voice_id(character)
	# Per-line model override. Walkie lines aren't DialogueLine objects, so
	# we parse `[#model=v3]` directly from the text (DialogueManager only
	# extracts tags from .dialogue files). Default model is the project-wide
	# ELEVEN_MODEL_ID. The tag is stripped from the text before TTS / display
	# so it never reaches ElevenLabs or the subtitle as literal chars.
	var line_model: String = TtsText.parse_model_tag(text, ELEVEN_MODEL_ID)
	var clean_text: String = TtsText.strip_model_tag(text)
	# Resolve template tokens ({player_handle}, etc.) before the cache key is
	# computed — different handles = different mp3s. Then kick the sibling
	# variants into the background primer queue.
	var resolved_text: String = LineLocalizer.resolve(clean_text)
	VoicePrimer.enqueue_siblings(character, clean_text, resolved_text)
	var read_path: String = Dialogue._cache_path_read(character, resolved_text, voice_id, line_model)
	if not read_path.is_empty():
		_log("dispatch: CACHE HIT %s%s" % [read_path, (" [model=%s]" % line_model) if line_model != ELEVEN_MODEL_ID else ""])
		_queue.pop_front()
		_play_from_path(read_path, character, resolved_text)
		return

	# Production gate: exported builds never hit ElevenLabs (mirrors the
	# Dialogue autoload). Shipped builds must rely on res://audio/voice_cache/.
	if OS.has_feature("template"):
		_log("dispatch: SKIP — exported build, no runtime synthesis allowed")
		_queue.pop_front()
		_dispatch_if_idle()
		return

	if Dialogue._api_key.is_empty():
		_log("dispatch: cache MISS + no API key — skipping line")
		_queue.pop_front()
		_dispatch_if_idle()
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
	# Strip + uppercase emphasis markers (`*word*` / `**word**`) before
	# they hit ElevenLabs — same transform the dialogue + companion paths
	# use so spoken emphasis matches the on-screen subtitle WYSIWYG.
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
	# On any failure, drop the line and move on.
	_queue.pop_front()
	_dispatch_if_idle()


func _play_from_path(path: String, character: String, text: String) -> void:
	# Two-path load matching Dialogue._play_cached:
	#   - FileAccess works in editor for raw .mp3 on disk (and for freshly-
	#     synthed files that haven't been imported yet — no .import sidecar
	#     means ResourceLoader.load() would return null).
	#   - ResourceLoader works in exports (raw .mp3 isn't in the .pck; only
	#     the imported .mp3str form is, which load() resolves via .import).
	# Try FileAccess first, fall back to ResourceLoader if it fails (catches
	# stale-import cases where the file is "there" per Godot but FileAccess
	# can't open it directly).
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
	Audio.play_walkie(stream)


func _on_walkie_finished() -> void:
	if not _playing:
		return
	_playing = false
	line_ended.emit()
	_dispatch_if_idle()


