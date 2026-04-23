extends Node

## Live ElevenLabs test — hits the real API, verifies the round-trip:
##   1. API key loads from env or user://tts_config.tres
##   2. voices.tres has Troll mapped
##   3. POST /v1/text-to-speech/{voice_id} returns 200 + MP3 bytes
##   4. Bytes cache to user://tts_cache/
##   5. AudioStreamMP3 loads cleanly
##
## Run with:
##   godot --headless res://tools/test_tts_live.tscn
##
## Exits with code 0 on success, 1 on any failure. Prints verbose progress.


const VOICES_PATH: String = "res://dialogue/voices.tres"
const CONFIG_PATH: String = "user://tts_config.tres"
const API_URL: String = "https://api.elevenlabs.io/v1/text-to-speech/%s"
const MODEL: String = "eleven_flash_v2_5"

const TEST_CHARACTER: String = "Troll"
const TEST_TEXT: String = "Testing, one two three."


func _ready() -> void:
	_run.call_deferred()


func _run() -> void:
	print("=== ElevenLabs TTS Live Test ===")

	var api_key := _load_api_key()
	if api_key.is_empty():
		printerr("FAIL: no API key (env ELEVEN_LABS_API_KEY OR %s)" % CONFIG_PATH)
		printerr("      run: godot --headless --script res://tools/setup_tts.gd --quit")
		get_tree().quit(1)
		return
	print("  api_key: %d chars, starts with '%s...'" % [api_key.length(), api_key.substr(0, 6)])

	var voices: Resource = load(VOICES_PATH)
	if voices == null:
		printerr("FAIL: could not load %s" % VOICES_PATH)
		get_tree().quit(1)
		return
	if not voices.has_voice(TEST_CHARACTER):
		printerr('FAIL: no voice for character "%s" in voices.tres' % TEST_CHARACTER)
		get_tree().quit(1)
		return
	var voice_id: String = voices.get_voice_id(TEST_CHARACTER)
	print('  voice for "%s": %s' % [TEST_CHARACTER, voice_id])

	var http := HTTPRequest.new()
	add_child(http)

	var url := API_URL % voice_id
	var headers: PackedStringArray = [
		"Accept: audio/mpeg",
		"Content-Type: application/json",
		"xi-api-key: " + api_key,
	]
	var body := JSON.stringify({
		"text": TEST_TEXT,
		"model_id": MODEL,
		"voice_settings": {"stability": 0.5, "similarity_boost": 0.5},
	})

	print("  POST %s" % url)
	print('  model: %s, text: "%s"' % [MODEL, TEST_TEXT])
	var start_ms := Time.get_ticks_msec()
	var err := http.request(url, headers, HTTPClient.METHOD_POST, body)
	if err != OK:
		printerr("FAIL: HTTPRequest.request returned err=%d" % err)
		get_tree().quit(1)
		return

	var result: Array = await http.request_completed
	var elapsed_ms := Time.get_ticks_msec() - start_ms
	var response_code: int = result[1]
	var response_body: PackedByteArray = result[3]

	print("  response: code=%d, %d bytes, %dms" % [response_code, response_body.size(), elapsed_ms])

	if response_code != 200:
		var preview: String = response_body.get_string_from_utf8().substr(0, 500) if response_body.size() > 0 else "<empty>"
		printerr("FAIL: response_code=%d, body preview:" % response_code)
		printerr("  %s" % preview)
		get_tree().quit(1)
		return
	if response_body.size() < 1000:
		printerr("FAIL: response body suspiciously small (%d bytes) — check model/voice_id" % response_body.size())
		get_tree().quit(1)
		return

	DirAccess.make_dir_recursive_absolute("user://tts_cache")
	var hash_input := "%s__%s__%s" % [TEST_CHARACTER, TEST_TEXT, voice_id]
	var hashed := hash_input.md5_text().left(15)
	var safe_char := TEST_CHARACTER.to_lower().replace(" ", "_")
	var cache_path := "user://tts_cache/%s_%s.mp3" % [safe_char, hashed]

	var file := FileAccess.open(cache_path, FileAccess.WRITE)
	if file == null:
		printerr("FAIL: could not write to %s" % cache_path)
		get_tree().quit(1)
		return
	file.store_buffer(response_body)
	file.close()
	print("  cached to %s" % cache_path)
	print("     (%s)" % ProjectSettings.globalize_path(cache_path))

	var rb := FileAccess.open(cache_path, FileAccess.READ)
	var mp3 := AudioStreamMP3.new()
	mp3.data = rb.get_buffer(rb.get_length())
	rb.close()
	if mp3.data.size() != response_body.size():
		printerr("FAIL: round-trip mismatch (%d written, %d read)" % [response_body.size(), mp3.data.size()])
		get_tree().quit(1)
		return
	print("  AudioStreamMP3 OK: %d bytes, length=%.2fs" % [mp3.data.size(), mp3.get_length()])

	print("")
	print("PASS test_tts_live: API round-trip succeeded, file cached, MP3 decodes")
	print("       — in a live session, the next speak_line call will CACHE HIT this file")
	get_tree().quit(0)


func _load_api_key() -> String:
	var env_key := OS.get_environment("ELEVEN_LABS_API_KEY")
	if not env_key.is_empty(): return env_key
	if FileAccess.file_exists(CONFIG_PATH):
		var cf := ConfigFile.new()
		if cf.load(CONFIG_PATH) == OK:
			return cf.get_value("tts", "api_key", "")
	return ""
