extends Node

## Dialogue autoload — thin wrapper over Nathan Hoad's DialogueManager plugin.
## Owns:
##   - Pause + modal coordination (get_tree().paused, Events.modal_opened/closed)
##   - Lifecycle emission (Events.dialogue_started/ended)
##   - Player mouse-capture toggle (via PlayerBrain.capture_mouse)
##   - TTS cache + ElevenLabs HTTPRequest queue (§9.3)
##
## See docs/interactables.md §9. Five bugs from the 3dPFormer reference are
## fixed here:
##   1. API key from user://tts_config.tres or env, NOT hardcoded
##   2. Cache path user://tts_cache/ (res:// is read-only in exported builds)
##   3. voices.tres externalizes the character → voice_id map
##   4. HTTPRequest lives here (survives balloon close, FIFO queue)
##   5. Playback routed through Audio.play_dialogue so Dialogue bus sidechains

const MODAL_ID: StringName = &"dialogue"
## Shipped cache. Checked first at read time. Populated before export by
## tools/sync_voice_cache.gd (copies from DEV_CACHE_DIR). Exports include
## everything under res://, so shipped builds hit the API zero times.
const SHIPPED_CACHE_DIR: String = "res://audio/voice_cache/"
## Dev cache. Writes always go here (res:// is read-only in exported builds).
## During authoring this is where fresh synths land.
const DEV_CACHE_DIR: String = "user://tts_cache/"
const CONFIG_PATH: String = "user://tts_config.tres"
const VOICES_PATH: String = "res://dialogue/voices.tres"
const ELEVEN_API_URL: String = "https://api.elevenlabs.io/v1/text-to-speech/%s"
# eleven_flash_v2_5 — ~75ms latency, right for game NPC dialogue. Trade off vs
# eleven_multilingual_v2 (higher quality, ~400ms) and eleven_v3 (best quality,
# highest latency). Change here to re-voice — cache filename doesn't include
# the model, so consider clearing user://tts_cache/ after swapping.
const ELEVEN_MODEL_ID: String = "eleven_flash_v2_5"

## Toggle via `Dialogue.verbose = false` to silence the trace logs.
@export var verbose: bool = true


func _log(msg: String) -> void:
	if verbose:
		print("[Dialogue] %s" % msg)

var _open: bool = false
var _active_id: StringName = &""
var _voices: Resource
var _api_key: String = ""

# TTS request queue — FIFO, one outstanding HTTP request at a time.
# Each entry: { "character": String, "text": String, "voice_id": String, "path": String }
var _tts_queue: Array = []
var _tts_in_flight: Dictionary = {}  # non-empty == a request is pending
var _http: HTTPRequest


func _ready() -> void:
	# Dialogue autoload runs during paused game time (balloon is up). Also
	# our HTTPRequest child's response handler needs to fire under pause.
	process_mode = Node.PROCESS_MODE_ALWAYS

	DirAccess.make_dir_recursive_absolute(DEV_CACHE_DIR)
	_voices = load(VOICES_PATH)
	_api_key = _load_api_key()
	_log("ready. voices=%s api_key=%s shipped_cache=%s dev_cache=%s" % [
		"loaded" if _voices != null else "<MISSING>",
		"present (%d chars)" % _api_key.length() if not _api_key.is_empty() else "<NOT SET — TTS will be silent>",
		ProjectSettings.globalize_path(SHIPPED_CACHE_DIR),
		ProjectSettings.globalize_path(DEV_CACHE_DIR),
	])
	_http = HTTPRequest.new()
	_http.request_completed.connect(_on_http_completed)
	add_child(_http)

	# Hook DialogueManager's got_dialogue to:
	#  1. Emit Events.dialogue_line_shown for subscribers (HUD, analytics, etc.)
	#  2. Trigger TTS for the line (voice lookup via character name)
	# Waits until after autoload init so the plugin is ready.
	call_deferred("_connect_dialogue_manager")

	# Scene-change safety: ui_dev's SceneLoader may emit a pre-change signal
	# (checked by name). If present, force-close so we don't soft-lock with
	# an orphaned balloon. Silent no-op if the signal doesn't exist yet.
	var loader: Node = get_node_or_null(^"/root/SceneLoader")
	if loader != null and loader.has_signal(&"scene_changing"):
		loader.connect(&"scene_changing", force_close)


func _connect_dialogue_manager() -> void:
	var dm: Node = get_node_or_null(^"/root/DialogueManager")
	if dm == null:
		_log("_connect_dialogue_manager: /root/DialogueManager not found — plugin not enabled?")
		return
	# CRITICAL: the plugin's DialogueManager autoload inherits pause from
	# root (PROCESS_MODE_INHERIT default). When we pause the tree to show
	# the balloon, the plugin freezes mid-`get_next_dialogue_line` and the
	# balloon box appears with no text. Flip it to ALWAYS so it keeps
	# resolving lines under pause.
	dm.process_mode = Node.PROCESS_MODE_ALWAYS
	_log("_connect_dialogue_manager: DialogueManager.process_mode = ALWAYS")
	if dm.has_signal(&"got_dialogue") and not dm.got_dialogue.is_connected(_on_line_shown):
		dm.got_dialogue.connect(_on_line_shown)
		_log("_connect_dialogue_manager: hooked DialogueManager.got_dialogue")
	else:
		_log("_connect_dialogue_manager: got_dialogue signal missing or already connected")


func _on_line_shown(line: Object) -> void:
	# DialogueLine has `.character: String` and `.text: String`. Typed as
	# Object so we don't pin the plugin's class_name at parse time.
	if line == null:
		_log("_on_line_shown: line=null (dialogue ended)")
		Audio.stop_dialogue()  # drop queued audio so it doesn't play after end
		return
	var character: String = ""
	var text: String = ""
	if "character" in line: character = str(line.character)
	if "text" in line: text = str(line.text)
	_log('_on_line_shown: character="%s" text="%s"' % [character, text])
	Events.dialogue_line_shown.emit(StringName(character), text)

	# CRITICAL (2026-04-22 fix): stop any in-flight / queued dialogue audio
	# before queueing the new line's segments. Without this, clicking past a
	# line while it's still speaking leaves the old audio playing over the
	# new one — you hear line A's tail mixed with line B.
	Audio.stop_dialogue()

	# P4.5: segment the line into alternating character/narrator chunks
	# based on `*asterisk*` spans. Non-italic = character voice, italic =
	# Narrator voice.
	var is_pure_narrator := character.is_empty() or character.to_upper() == "NARRATOR"
	if is_pure_narrator:
		var narrator_text := _strip_italic_spans(text) if text.contains("*") else text
		if narrator_text.strip_edges().is_empty(): return
		_log("  segments: [NARRATOR whole-line] %s" % narrator_text)
		speak_line("Narrator", narrator_text)
		return

	var segments := _segment_line(text, character)
	_log("  segments built (%d):" % segments.size())
	for seg: Dictionary in segments:
		_log("    [%s] %s" % [seg.speaker, seg.text])
		speak_line(seg.speaker, seg.text)


## Splits a line into alternating segments:
##   "Hello. *scratches.* World."  →
##     [{speaker=character, text="Hello."},
##      {speaker="Narrator",  text="scratches."},
##      {speaker=character, text="World."}]
##
## Empty/whitespace-only segments dropped.
static func _segment_line(text: String, character: String) -> Array:
	var out: Array = []
	var re := RegEx.create_from_string("\\*([^*]+)\\*")
	var pos: int = 0
	for m: RegExMatch in re.search_all(text):
		var before: String = text.substr(pos, m.get_start() - pos).strip_edges()
		if not before.is_empty():
			out.append({"speaker": character, "text": before})
		var italic: String = m.get_string(1).strip_edges()
		if not italic.is_empty():
			out.append({"speaker": "Narrator", "text": italic})
		pos = m.get_end()
	var tail: String = text.substr(pos).strip_edges()
	if not tail.is_empty():
		out.append({"speaker": character, "text": tail})
	return out


## Removes `*italic*` spans from text. Kept as public helper for callers that
## want plain text without narration beats. Not used by TTS anymore — we now
## segment the line and voice italics via the Narrator.
static func _strip_italic_spans(text: String) -> String:
	var re := RegEx.create_from_string("\\*[^*]+\\*")
	return re.sub(text, "", true).strip_edges()


# ---- Public API ---------------------------------------------------------

func is_open() -> bool:
	return _open


## `resource` is a DialogueResource from Nathan Hoad's plugin. Typed as
## Resource to avoid plugin-class parse timing issues on autoload load.
func start(resource: Resource, title: String = "start", id: StringName = &"") -> void:
	_log("start: resource=%s title='%s' id=%s" % [resource, title, id])
	if _open:
		_log("start: IGNORED — already open for %s" % _active_id)
		push_warning("Dialogue.start ignored — already open: %s" % _active_id)
		return
	if resource == null:
		_log("start: ABORT — resource is null")
		push_warning("Dialogue.start called with null resource")
		return

	# Invariant: flip state BEFORE emit + pause — synchronous consumers
	# (PauseController._unhandled_input) must see is_open() true immediately.
	_open = true
	_active_id = id if not id.is_empty() else StringName(title)
	_log("start: flipped _open=true, _active_id=%s" % _active_id)

	Events.dialogue_started.emit(_active_id)
	Events.modal_opened.emit(MODAL_ID)
	_capture_player_mouse(false)

	# Check DialogueManager is present (plugin enabled).
	var dm: Node = get_node_or_null(^"/root/DialogueManager")
	if dm == null:
		_log("start: ABORT — /root/DialogueManager not found")
		push_error("Dialogue.start: DialogueManager autoload not found — is the plugin enabled?")
		_close()
		return

	_log("start: calling DialogueManager.show_dialogue_balloon(...)")
	# DialogueManager.show_dialogue_balloon instantiates the balloon scene
	# from project.godot `dialogue_manager/general/balloon_path`. The balloon
	# `queue_free`s when dialogue ends; we hook `tree_exited` on the returned
	# balloon so our close pair fires even on error-triggered cleanup.
	#
	# Design decision (2026-04-22): dialogue does NOT pause the world. Music,
	# ambient audio, NPC idle loops, and camera dolly (future) all keep
	# running. The balloon itself sets will_block_other_input=true so player
	# movement input is consumed by the balloon and they stay rooted. Puzzles
	# still pause (see Puzzles autoload).
	var balloon: Node = dm.show_dialogue_balloon(resource, title)
	_log("start: show_dialogue_balloon returned %s" % balloon)
	if balloon != null:
		balloon.tree_exited.connect(_close, CONNECT_ONE_SHOT)
		_log("start: balloon configured (no tree pause — world keeps ticking)")
	else:
		# Plugin didn't give us a handle — fall back to listening for the
		# generic "dialogue_ended" signal on the plugin.
		_log("start: balloon handle is null, falling back to dm.dialogue_ended signal")
		if dm.has_signal(&"dialogue_ended"):
			dm.dialogue_ended.connect(_close, CONNECT_ONE_SHOT)
		else:
			push_error("Dialogue: plugin produced no balloon handle; force-closing")
			_close()


## Called by the dialogue balloon (or its replacement) for each TTS line.
## Hashes character+text to a stable filename. Reads through two-tier lookup:
## shipped res:// cache wins, then user:// dev cache, else API.
## Plays through Audio.play_dialogue so the Dialogue bus drives sidechain.
func speak_line(character: String, text: String) -> void:
	if _voices == null:
		_log('speak_line: ABORT — voices.tres failed to load (expected %s)' % VOICES_PATH)
		return
	if not _voices.has_voice(character):
		_log('speak_line: no voice configured for character="%s" — silent' % character)
		return
	var voice_id: String = _voices.get_voice_id(character)
	var read_path: String = _cache_path_read(character, text, voice_id)
	if not read_path.is_empty():
		_log('speak_line: CACHE HIT (%s) → _play_cached' % read_path)
		_play_cached(read_path)
		return

	_log("speak_line: cache MISS — enqueue ElevenLabs request")
	var write_path: String = _cache_path_write(character, text, voice_id)
	# Not cached — enqueue a TTS request. Silent until response arrives.
	_tts_queue.append({
		"character": character,
		"text": text,
		"voice_id": voice_id,
		"path": write_path,
	})
	_maybe_dispatch_next_tts()


## Force-close from outside (scene-change, error recovery, dev escape hatch).
## Safe to call when not open — returns early.
func force_close() -> void:
	if not _open: return
	_close()


# ---- Internals ----------------------------------------------------------

func _close() -> void:
	if not _open: return
	# Mark closed FIRST — the balloon's tree_exited can fire during scene
	# teardown when get_tree() is already null. Setting state before any
	# tree access makes the close contract atomic from the caller's view.
	_open = false
	var closed_id := _active_id
	_active_id = &""

	# Guard: tree_exited can fire as part of SceneTree teardown (app quit,
	# scene change). In that case get_tree() is null. Skip tree-dependent
	# cleanup; nothing to restore anyway.
	var tree := get_tree()
	if tree == null: return

	# Dialogue doesn't pause the tree anymore (see start() note), so no
	# unpause is needed on close. Only mouse-mode cleanup remains.
	_capture_player_mouse(true)
	Events.modal_closed.emit(MODAL_ID)
	Events.dialogue_ended.emit(closed_id)


func _capture_player_mouse(on: bool) -> void:
	var tree := get_tree()
	if tree == null: return
	var brain: Node = tree.get_first_node_in_group(&"player_brain")
	if brain != null and brain.has_method(&"capture_mouse"):
		brain.capture_mouse(on)


## Stable filename derived from character + text + voice_id. Machine-independent.
func _cache_filename(character: String, text: String, voice_id: String) -> String:
	var hash_input: String = "%s__%s__%s" % [character, text, voice_id]
	var hashed: String = hash_input.md5_text().left(15)
	var safe_char: String = character.to_lower().replace(" ", "_")
	return "%s_%s.mp3" % [safe_char, hashed]


## Read path. Shipped cache wins so exports play from res://. Returns "" if no
## cache hit on either tier — caller falls back to API.
func _cache_path_read(character: String, text: String, voice_id: String) -> String:
	var fname: String = _cache_filename(character, text, voice_id)
	var shipped: String = SHIPPED_CACHE_DIR + fname
	if FileAccess.file_exists(shipped): return shipped
	var dev: String = DEV_CACHE_DIR + fname
	if FileAccess.file_exists(dev): return dev
	return ""


## Write path. Always user:// — res:// is read-only in exported builds.
## tools/sync_voice_cache.gd copies from user:// → res:// before ship.
func _cache_path_write(character: String, text: String, voice_id: String) -> String:
	return DEV_CACHE_DIR + _cache_filename(character, text, voice_id)


func _load_api_key() -> String:
	# Prefer env var.
	var env_key: String = OS.get_environment("ELEVEN_LABS_API_KEY")
	if not env_key.is_empty(): return env_key
	# Fallback to user://tts_config.tres if authored by the user. We read
	# as ConfigFile for simplicity — no custom Resource class needed.
	if FileAccess.file_exists(CONFIG_PATH):
		var cf := ConfigFile.new()
		if cf.load(CONFIG_PATH) == OK:
			return cf.get_value("tts", "api_key", "")
	return ""


func _maybe_dispatch_next_tts() -> void:
	if not _tts_in_flight.is_empty():
		_log("_maybe_dispatch: waiting on in-flight (character=%s)" % _tts_in_flight.get("character", "?"))
		return
	if _tts_queue.is_empty():
		return
	if _api_key.is_empty():
		_log("_maybe_dispatch: SKIP — no api key configured (see tools/setup_tts.gd)")
		return
	var next: Dictionary = _tts_queue.pop_front()
	_tts_in_flight = next
	var url: String = ELEVEN_API_URL % next["voice_id"]
	var headers: PackedStringArray = [
		"Accept: audio/mpeg",
		"Content-Type: application/json",
		"xi-api-key: " + _api_key,
	]
	var body: String = JSON.stringify({
		"text": next["text"],
		"model_id": ELEVEN_MODEL_ID,
		"voice_settings": {"stability": 0.5, "similarity_boost": 0.5},
	})
	_log('_maybe_dispatch: POST %s (model=%s text_len=%d)' % [url, ELEVEN_MODEL_ID, next["text"].length()])
	var err: int = _http.request(url, headers, HTTPClient.METHOD_POST, body)
	if err != OK:
		_log("_maybe_dispatch: HTTPRequest.request returned err=%d — clearing in-flight" % err)
		_tts_in_flight = {}


func _on_http_completed(result: int, response_code: int, _headers: PackedStringArray, body: PackedByteArray) -> void:
	_log("_on_http_completed: result=%d response_code=%d body_size=%d" % [result, response_code, body.size()])
	if _tts_in_flight.is_empty():
		_log("_on_http_completed: nothing in flight; ignoring")
		return
	var req: Dictionary = _tts_in_flight
	_tts_in_flight = {}

	if response_code == 200 and body.size() > 0:
		var file := FileAccess.open(req["path"], FileAccess.WRITE)
		if file == null:
			_log("_on_http_completed: FileAccess.open(WRITE) failed for %s" % req["path"])
		else:
			file.store_buffer(body)
			file.close()
			_log('_on_http_completed: cached %d bytes to %s — playing' % [body.size(), req["path"]])
			_play_cached(req["path"])
	else:
		_log('_on_http_completed: FAIL code=%d (body preview: %s)' % [
			response_code,
			body.get_string_from_utf8().substr(0, 200) if body.size() > 0 else "<empty>",
		])
		push_warning("Dialogue TTS request failed (code=%d) for character=%s" %
			[response_code, req["character"]])
	_maybe_dispatch_next_tts()


func _play_cached(path: String) -> void:
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		_log("_play_cached: FileAccess.open(READ) failed for %s" % path)
		return
	var mp3 := AudioStreamMP3.new()
	mp3.data = file.get_buffer(file.get_length())
	file.close()
	_log("_play_cached: routing %d bytes through Audio.play_dialogue (Dialogue bus)" % mp3.data.size())
	# Route through Audio autoload so the Dialogue bus drives sidechain ducking.
	Audio.play_dialogue(mp3)
