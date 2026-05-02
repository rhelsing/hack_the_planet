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
##   1. API key resolved at boot: env var → user://tts_config.tres (per-dev
##      override) → res://dialogue/tts_config.tres (committed, repo-private)
##   2. Single cache at res://audio/voice_cache/ — editor + playtest write
##      directly there (committed alongside .import sidecars), exports read
##      via ResourceLoader (no FileAccess on raw paths)
##   3. voices.tres externalizes the character → voice_id map
##   4. HTTPRequest lives here (survives balloon close, FIFO queue)
##   5. Playback routed through Audio.play_dialogue so Dialogue bus sidechains

const MODAL_ID: StringName = &"dialogue"
## The single cache location. Editor writes here directly; exports read here
## through ResourceLoader (which resolves the imported .mp3str form via the
## .import sidecar). Exports never write — the production gate in
## _maybe_dispatch_next_tts no-ops ElevenLabs requests.
const SHIPPED_CACHE_DIR: String = "res://audio/voice_cache/"
const CONFIG_PATH: String = "user://tts_config.tres"
## Committed fallback. Loaded only if env and user:// both come up empty.
## Repo-private; exists because we'd rather a fresh clone "just work" than
## require every dev to bootstrap their own user:// config.
const REPO_CONFIG_PATH: String = "res://dialogue/tts_config.tres"
const VOICES_PATH: String = "res://dialogue/voices.tres"
const ELEVEN_API_URL: String = "https://api.elevenlabs.io/v1/text-to-speech/%s"
const TtsText: GDScript = preload("res://autoload/tts_text.gd")
# eleven_flash_v2_5 — ~75ms latency, right for game NPC dialogue. Trade off vs
# eleven_multilingual_v2 (higher quality, ~400ms) and eleven_v3 (best quality,
# highest latency). Change here to re-voice — cache filename doesn't include
# the model, so consider clearing res://audio/voice_cache/ after swapping.
const ELEVEN_MODEL_ID: String = "eleven_flash_v2_5"

## Master kill-switch for runtime TTS synthesis. When true, `_api_key` is
## forced empty at boot — every dispatcher (Dialogue/Walkie/Companion) sees
## a missing key and takes its existing silent-skip branch. Flip to false
## to re-enable bake/regen workflows. Voice cache is unaffected; cache HITS
## still play normally.
const TTS_DISABLED: bool = true

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

	_voices = load(VOICES_PATH)
	_api_key = "" if TTS_DISABLED else _load_api_key()
	_log("ready. voices=%s api_key=%s cache=%s" % [
		"loaded" if _voices != null else "<MISSING>",
		"present (%d chars)" % _api_key.length() if not _api_key.is_empty() else "<NOT SET — TTS will be silent>",
		ProjectSettings.globalize_path(SHIPPED_CACHE_DIR),
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
	var template: String = ""
	if "character" in line: character = str(line.character)
	# Prefer `raw_text` meta if the balloon stashed it before mutating
	# `line.text` to BBCode-formatted display form (scroll_balloon.gd does
	# this — got_dialogue is emitted deferred, so by the time we get here
	# `line.text` already has `**word**` swapped to `[b][color=…]WORD[/color][/b]`).
	# Hashing the BBCode form would miss every prebaked mp3 (which is keyed
	# off the raw `**word**` source). Falls back to `line.text` for callers
	# that don't go through the balloon.
	if line.has_meta(&"raw_text"):
		template = str(line.get_meta(&"raw_text"))
	elif "text" in line:
		template = str(line.text)
	# `template` is post-mustache (DialogueManager already ran `{{ }}`) but
	# pre-LineLocalizer (our `{jump}` / `{player_handle}` tokens are still
	# present). Resolve here so subtitles + TTS see the device-correct text;
	# preserve `template` so VoicePrimer can enumerate sibling variants.
	var text: String = LineLocalizer.resolve(template)
	# Strip ElevenLabs audio tags ([laughs], [whispering], [sighs], etc.) from
	# the DISPLAY text. They stay intact in `template` so the TTS payload still
	# contains them — ElevenLabs reads them as audio cues. The visible balloon
	# only needs them removed. See _strip_audio_tags() for the regex.
	var display_text: String = _strip_audio_tags(text)
	# Mutate the line so the dialogue plugin's UI renders our resolved text.
	# The got_dialogue signal is emitted deferred (see addons/dialogue_manager/
	# dialogue_manager.gd:129), and we connect first in autoload init — so the
	# plugin's UI handler reads the mutated `line.text` after this hook runs.
	if "text" in line:
		line.text = display_text
	_log('_on_line_shown: character="%s" text="%s"' % [character, text])
	Events.dialogue_line_shown.emit(StringName(character), text)

	# Per-line bus routing via Dialogue Manager tags. `[#walkie]` placed on a
	# line plays through the Walkie bus (phone-FX bandpass + distortion) so
	# off-screen radio interjections sound like they're coming over the wire.
	# Default = Dialogue bus (clean, in-room voice). The tag itself is parsed
	# out by the plugin so it never appears in the visible balloon text or in
	# the TTS payload — that part is automatic.
	var route_walkie: bool = false
	if line.has_method("has_tag") and line.has_tag("walkie"):
		route_walkie = true

	# Per-line model override via `[#model=eleven_v3]` tag. Default = the
	# project's ELEVEN_MODEL_ID constant (currently `eleven_flash_v2_5`).
	# Only lines with an explicit model tag get baked + cached on a
	# different model. See README "Per-line model overrides" for details.
	var line_model: String = ELEVEN_MODEL_ID
	if line.has_method("has_tag") and line.has_tag("model"):
		line_model = str(line.get_tag_value("model"))

	# CRITICAL (2026-04-22 fix): stop any in-flight / queued dialogue audio
	# before queueing the new line's TTS request. Without this, clicking past
	# a line while it's still speaking leaves the old audio playing over the
	# new one — you hear line A's tail mixed with line B. Stop BOTH buses so
	# a walkie-tagged line cuts a clean dialogue line and vice versa.
	Audio.stop_dialogue()
	Audio.stop_walkie()

	# WYSIWYG TTS: send the entire visible line in the speaker's own voice.
	# Keep the raw `**word**` markers in the hash input so runtime matches
	# what `tools/prime_all_dialogue.gd` keys off (it hashes the raw line
	# from the .dialogue file, asterisks intact). The asterisk strip + bold
	# uppercasing happens at the ElevenLabs payload boundary in
	# _maybe_dispatch_next_tts via TtsText.for_eleven_labs.
	var tts_template := template
	var tts_text := LineLocalizer.resolve(tts_template)
	if tts_text.strip_edges().is_empty(): return
	_log("  speak: [%s]%s%s %s" % [
		character,
		" [WALKIE]" if route_walkie else "",
		(" [model=%s]" % line_model) if line_model != ELEVEN_MODEL_ID else "",
		tts_text,
	])
	# Cutscene-driver gate: if a CutsceneSequence is currently walking the
	# DialogueManager, it's also calling Companion.speak / Walkie.speak for
	# the same line via _play_line. Dispatching TTS here too would cause
	# parallel HTTPRequests writing the same cache file (race), wasted API
	# calls, and (combined with the in-flight bug fixed in companion.gd /
	# walkie.gd this commit) hang the cutscene. The line still surfaces via
	# Events.dialogue_line_shown above for HUD/subtitles — only the TTS
	# dispatch is suppressed. VoicePrimer also skipped because Companion /
	# Walkie's own speak path enqueues siblings.
	if CutsceneSequence.is_dialogue_driven():
		_log("  speak: SKIPPED (cutscene-driven; routed via Companion/Walkie)")
		return
	speak_line(character, tts_text, route_walkie, line_model)
	VoicePrimer.enqueue_siblings(character, tts_template, tts_text)


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
func speak_line(character: String, text: String, route_walkie: bool = false, model_id: String = ELEVEN_MODEL_ID) -> void:
	if _voices == null:
		_log('speak_line: ABORT — voices.tres failed to load (expected %s)' % VOICES_PATH)
		return
	if not _voices.has_voice(character):
		_log('speak_line: no voice configured for character="%s" — silent' % character)
		return
	var voice_id: String = _voices.get_voice_id(character)
	var read_path: String = _cache_path_read(character, text, voice_id, model_id)
	if not read_path.is_empty():
		_log('speak_line: CACHE HIT (%s) → _play_cached%s%s' % [
			read_path,
			" [WALKIE]" if route_walkie else "",
			(" [model=%s]" % model_id) if model_id != ELEVEN_MODEL_ID else "",
		])
		_play_cached(read_path, route_walkie)
		return

	_log("speak_line: cache MISS — enqueue ElevenLabs request%s%s" % [
		" [WALKIE]" if route_walkie else "",
		(" [model=%s]" % model_id) if model_id != ELEVEN_MODEL_ID else "",
	])
	var write_path: String = _cache_path_write(character, text, voice_id, model_id)
	# Not cached — enqueue a TTS request. Silent until response arrives.
	_tts_queue.append({
		"character": character,
		"text": text,
		"voice_id": voice_id,
		"path": write_path,
		"route_walkie": route_walkie,
		"model_id": model_id,
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
## Strip ElevenLabs audio tags from a line for display. The TTS payload
## keeps them intact (so ElevenLabs interprets them as audio cues — laughs,
## sighs, whispers, etc.) but the visible balloon shouldn't show literal
## brackets to the player.
##
## Matches: `[lowercase]`, `[lowercase with spaces]`, `[lowercase-words]`,
## `[laughs harder]`, etc. The leading char must be a letter; contents need
## AT LEAST TWO total chars (letters / digits / spaces / hyphens /
## underscores). The ≥2-char floor excludes 1-char visual BBCode tags
## (`[b]`, `[i]`, `[u]`, `[s]`) so this strip is idempotent across
## already-formatted text. This deliberately does NOT match:
##   - `[#tag]` — DialogueManager line tags (already parsed out by now)
##   - `[[a|b]]` — alternations (also already parsed)
##   - `[COMPOSURE 30%]` — skill check prefix (% is outside the char class)
##   - `[b]` / `[i]` / `[/b]` / `[/i]` — BBCode (visual styling preserved)
func _strip_audio_tags(text: String) -> String:
	var re_tag: RegEx = RegEx.create_from_string("\\[[a-zA-Z][a-zA-Z0-9 _-]+\\]")
	var out: String = re_tag.sub(text, "", true)
	# Collapse runs of whitespace caused by stripped tags ("a [laughs] b" → "a  b" → "a b").
	var re_space: RegEx = RegEx.create_from_string("\\s+")
	out = re_space.sub(out, " ", true)
	return out.strip_edges()


## Cache filename hash. By design, the DEFAULT model (eleven_flash_v2_5) is
## NOT included in the hash — so all existing flash-baked mp3s remain valid
## without a re-bake when this function evolves. Non-default models APPEND
## `__<model_id>` to the hash key, producing distinct cache entries that can
## coexist with the flash version for the same line. This lets a single
## tagged line be selectively re-baked on `eleven_v3` without invalidating
## the rest of the cache. See README §"Voice / dialogue audio (TTS cache +
## variants)" for the per-line `[#model=v3]` workflow.
func _cache_filename(character: String, text: String, voice_id: String, model_id: String = ELEVEN_MODEL_ID) -> String:
	var hash_input: String
	if model_id == ELEVEN_MODEL_ID:
		# Default model — backward-compat hash (no model suffix).
		hash_input = "%s__%s__%s" % [character, text, voice_id]
	else:
		hash_input = "%s__%s__%s__%s" % [character, text, voice_id, model_id]
	var hashed: String = hash_input.md5_text().left(15)
	var safe_char: String = character.to_lower().replace(" ", "_")
	return "%s_%s.mp3" % [safe_char, hashed]


## Read path. Single cache at res://audio/voice_cache/. Returns "" if not
## cached — caller falls back to API (editor only; production gates dispatch).
##
## Editor uses FileAccess (raw mp3 on disk; un-imported just-written files
## still resolve). Exports use ResourceLoader (raw source isn't in the .pck;
## only the imported .mp3str is — which ResourceLoader resolves via .import).
func _cache_path_read(character: String, text: String, voice_id: String, model_id: String = ELEVEN_MODEL_ID) -> String:
	var fname: String = _cache_filename(character, text, voice_id, model_id)
	var shipped: String = SHIPPED_CACHE_DIR + fname
	if OS.has_feature("template"):
		if ResourceLoader.exists(shipped): return shipped
	else:
		if FileAccess.file_exists(shipped): return shipped
	return ""


## Write path. Always res://audio/voice_cache/ — editor + playtest both write
## here directly so synths show up in `git status` and are committable without
## a separate sync step. Exports never reach this function (gated by
## OS.has_feature("template") in _maybe_dispatch_next_tts).
func _cache_path_write(character: String, text: String, voice_id: String, model_id: String = ELEVEN_MODEL_ID) -> String:
	return SHIPPED_CACHE_DIR + _cache_filename(character, text, voice_id, model_id)


func _load_api_key() -> String:
	# Prefer env var (CI / per-shell override).
	var env_key: String = OS.get_environment("ELEVEN_LABS_API_KEY")
	if not env_key.is_empty(): return env_key
	# Per-dev override at user://tts_config.tres (machine-local).
	if FileAccess.file_exists(CONFIG_PATH):
		var cf := ConfigFile.new()
		if cf.load(CONFIG_PATH) == OK:
			var key := cf.get_value("tts", "api_key", "") as String
			if not key.is_empty(): return key
	# Committed fallback so a fresh clone boots with TTS working.
	if FileAccess.file_exists(REPO_CONFIG_PATH):
		var cf2 := ConfigFile.new()
		if cf2.load(REPO_CONFIG_PATH) == OK:
			return cf2.get_value("tts", "api_key", "")
	return ""


func _maybe_dispatch_next_tts() -> void:
	if not _tts_in_flight.is_empty():
		_log("_maybe_dispatch: waiting on in-flight (character=%s)" % _tts_in_flight.get("character", "?"))
		return
	if _tts_queue.is_empty():
		return
	# Production gate: never hit ElevenLabs from an exported build, even on
	# a true cache miss. Shipped builds must rely on res://audio/voice_cache/
	# (run tools/sync_voice_cache.gd before exporting if cache is stale).
	if OS.has_feature("template"):
		_log("_maybe_dispatch: SKIP — exported build, no runtime synthesis allowed")
		_tts_queue.clear()
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
	var line_model: String = next.get("model_id", ELEVEN_MODEL_ID)
	var body: String = JSON.stringify({
		"text": TtsText.for_eleven_labs(next["text"]),
		"model_id": line_model,
		"voice_settings": {"stability": 0.5, "similarity_boost": 0.5},
	})
	_log('_maybe_dispatch: POST %s (model=%s text_len=%d)' % [url, line_model, next["text"].length()])
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
			_play_cached(req["path"], req.get("route_walkie", false))
	else:
		_log('_on_http_completed: FAIL code=%d (body preview: %s)' % [
			response_code,
			body.get_string_from_utf8().substr(0, 200) if body.size() > 0 else "<empty>",
		])
		push_warning("Dialogue TTS request failed (code=%d) for character=%s" %
			[response_code, req["character"]])
	_maybe_dispatch_next_tts()


## Plays a cached mp3. `route_walkie=true` sends through the Walkie bus
## (phone-FX) instead of the Dialogue bus. Used when a line had a `[#walkie]`
## tag — radio interjections from off-screen characters.
func _play_cached(path: String, route_walkie: bool = false) -> void:
	# Editor + exports need DIFFERENT load paths because Godot ships only the
	# imported (.mp3str) form of audio resources, not the raw .mp3 source:
	#   - Exports:   raw mp3 isn't in the .pck. Use ResourceLoader → resolves
	#                via .import sidecar → returns a usable AudioStream.
	#   - Editor:    raw mp3 IS on disk, but a freshly-synthed file has no
	#                .import sidecar yet (the editor's filesystem watcher
	#                imports asynchronously after writes). ResourceLoader
	#                fails on unimported files, so use FileAccess to read
	#                the raw bytes directly. Already-imported files would
	#                also work via ResourceLoader, but FileAccess works for
	#                BOTH cases in editor — simpler.
	var stream: AudioStream = null
	if OS.has_feature("template"):
		stream = load(path) as AudioStream
		if stream == null:
			_log("_play_cached: ResourceLoader.load(%s) returned null in export" % path)
			return
	else:
		var file := FileAccess.open(path, FileAccess.READ)
		if file == null:
			_log("_play_cached: FileAccess.open(%s) failed in editor" % path)
			return
		var mp3 := AudioStreamMP3.new()
		mp3.data = file.get_buffer(file.get_length())
		file.close()
		stream = mp3
	if route_walkie:
		_log("_play_cached: loaded %s, routing through Audio.play_walkie (Walkie bus, phone-FX)" % path)
		Audio.play_walkie(stream)
	else:
		_log("_play_cached: loaded %s, routing through Audio.play_dialogue (Dialogue bus)" % path)
		# Route through Audio autoload so the Dialogue bus drives sidechain ducking.
		Audio.play_dialogue(stream)
