extends Node

## Background synth queue for sibling variants of tokenized voice lines.
## Foreground (Companion / Walkie) handles the chosen variant exactly the way
## it does today; this autoload picks up the OTHER variants and writes them to
## the TTS cache without ever playing them. Layer 3 of the dynamic dialogue
## engine — see docs/dynamic_dialogue_engine.md.
##
## Triggered at speak-time: when a Companion / Walkie call resolves a template
## to a chosen variant, it also calls VoicePrimer.enqueue_siblings(...) with the
## same template, and we expand the remaining variants and queue them.
##
## Idempotent: duplicate enqueues fold on cache path. Already-cached variants
## skip. In-flight variants skip. Missing API key pauses the queue silently
## (existing dev playthroughs without a key just don't pre-fill — fine).

const ELEVEN_API_URL: String = "https://api.elevenlabs.io/v1/text-to-speech/%s"
const ELEVEN_MODEL_ID: String = "eleven_flash_v2_5"

## Toggle logs via `VoicePrimer.verbose = false`.
var verbose: bool = true

var _queue: Array = []                 # [{character, text, voice_id, path}, ...]
var _in_flight: Dictionary = {}        # path -> true while HTTP request open
var _http: HTTPRequest
var _current: Dictionary = {}


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	_http = HTTPRequest.new()
	_http.request_completed.connect(_on_http_completed)
	add_child(_http)
	_log("ready")


func _log(msg: String) -> void:
	if verbose:
		print("[VoicePrimer] %s" % msg)


## Enqueue every OTHER variant of `template` for background synth. Variants
## are the cartesian of {player_handle} × device-profile expansions, so a line
## with both tokens caches handles × profiles entries. Skips the variant
## matching `chosen_resolved_text` (foreground handles it), variants already
## on disk, variants already in flight, and duplicate queue entries.
func enqueue_siblings(character: String, template: String, chosen_resolved_text: String) -> void:
	if not (LineLocalizer.has_handle_token(template) or LineLocalizer.has_device_token(template)):
		return
	var voices: Resource = Dialogue._voices
	if voices == null or not voices.has_voice(character):
		return
	var voice_id: String = voices.get_voice_id(character)
	var added: int = 0
	for variant: String in LineLocalizer.all_variants(template):
		if variant == chosen_resolved_text:
			continue
		var path: String = Dialogue._cache_path_write(character, variant, voice_id)
		if _in_flight.has(path):
			continue
		if FileAccess.file_exists(path):
			continue
		var dup: bool = false
		for q: Dictionary in _queue:
			if q.path == path:
				dup = true
				break
		if dup:
			continue
		_queue.append({
			"character": character,
			"text": variant,
			"voice_id": voice_id,
			"path": path,
		})
		added += 1
	if added > 0:
		_log("queued %d sibling(s) for template: %s" % [added, template])
	_drain_if_idle()


func _drain_if_idle() -> void:
	if not _current.is_empty():
		return
	if _queue.is_empty():
		return
	if Dialogue._api_key.is_empty():
		_log("api key missing — queue paused (%d waiting)" % _queue.size())
		return
	_current = _queue.pop_front()
	_in_flight[_current.path] = true
	_log('drain: synthing "%s"' % _current.text)
	var url: String = ELEVEN_API_URL % _current.voice_id
	var headers: PackedStringArray = [
		"Accept: audio/mpeg",
		"Content-Type: application/json",
		"xi-api-key: " + Dialogue._api_key,
	]
	var body: String = JSON.stringify({
		"text": _current.text,
		"model_id": ELEVEN_MODEL_ID,
		"voice_settings": {"stability": 0.5, "similarity_boost": 0.5},
	})
	var err: int = _http.request(url, headers, HTTPClient.METHOD_POST, body)
	if err != OK:
		_log("HTTPRequest err=%d — dropping" % err)
		_in_flight.erase(_current.path)
		_current = {}
		_drain_if_idle()


func _on_http_completed(_result: int, response_code: int, _headers: PackedStringArray, body: PackedByteArray) -> void:
	if _current.is_empty():
		return
	var req: Dictionary = _current
	_current = {}
	_in_flight.erase(req.path)
	if response_code == 200 and body.size() > 0:
		var file := FileAccess.open(req.path, FileAccess.WRITE)
		if file != null:
			file.store_buffer(body)
			file.close()
			_log("cached %d bytes -> %s" % [body.size(), req.path])
		else:
			_log("FileAccess write failed for %s" % req.path)
	else:
		_log("synth FAIL code=%d" % response_code)
	_drain_if_idle()
