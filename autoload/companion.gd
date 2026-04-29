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


func _dispatch_if_idle() -> void:
	if _playing or _queue.is_empty():
		return
	var next: Dictionary = _queue[0]
	var character: String = next.character
	var text: String = next.text
	var voices: Resource = Dialogue._voices
	if voices == null or not voices.has_voice(character):
		_log('dispatch: no voice for "%s" — skipping' % character)
		_queue.pop_front()
		_dispatch_if_idle()
		return
	var voice_id: String = voices.get_voice_id(character)
	# Resolve template tokens ({player_handle}, etc.) before the cache key is
	# computed. Same template can render as 4 different mp3s (one per handle);
	# the other 3 get queued in VoicePrimer as background work.
	var resolved_text: String = LineLocalizer.resolve(text)
	VoicePrimer.enqueue_siblings(character, text, resolved_text)
	var read_path: String = Dialogue._cache_path_read(character, resolved_text, voice_id)
	if not read_path.is_empty():
		_log("dispatch: CACHE HIT %s" % read_path)
		_queue.pop_front()
		_play_from_path(read_path, character, resolved_text)
		return

	if Dialogue._api_key.is_empty():
		_log("dispatch: cache MISS + no API key — skipping line")
		_queue.pop_front()
		_dispatch_if_idle()
		return

	_log("dispatch: cache MISS — requesting from ElevenLabs")
	var write_path: String = Dialogue._cache_path_write(character, resolved_text, voice_id)
	_in_flight = {
		"character": character,
		"text": resolved_text,
		"voice_id": voice_id,
		"path": write_path,
	}
	var url: String = ELEVEN_API_URL % voice_id
	var headers: PackedStringArray = [
		"Accept: audio/mpeg",
		"Content-Type: application/json",
		"xi-api-key: " + Dialogue._api_key,
	]
	var body: String = JSON.stringify({
		"text": TtsText.for_eleven_labs(resolved_text),
		"model_id": ELEVEN_MODEL_ID,
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
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		_log("play: FileAccess.open failed for %s" % path)
		_dispatch_if_idle()
		return
	var mp3 := AudioStreamMP3.new()
	mp3.data = file.get_buffer(file.get_length())
	file.close()
	_playing = true
	line_started.emit(character, text)
	Audio.play_companion(mp3)


func _on_companion_finished() -> void:
	if not _playing:
		return
	_playing = false
	line_ended.emit()
	_dispatch_if_idle()
