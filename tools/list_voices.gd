extends Node

## List every voice the current ElevenLabs API key can access, via
## GET /v1/voices. Prints name + voice_id + category so we know which ones
## are free-tier usable.
##
## Run with:
##   godot --headless res://tools/list_voices.tscn


const CONFIG_PATH: String = "user://tts_config.tres"


func _ready() -> void:
	_run.call_deferred()


func _run() -> void:
	print("=== ElevenLabs /v1/voices (account inventory) ===")
	var api_key := _load_api_key()
	if api_key.is_empty():
		printerr("FAIL: no API key configured")
		get_tree().quit(1)
		return

	var http := HTTPRequest.new()
	add_child(http)
	var headers: PackedStringArray = ["xi-api-key: " + api_key]
	var err := http.request("https://api.elevenlabs.io/v1/voices", headers, HTTPClient.METHOD_GET)
	if err != OK:
		printerr("FAIL: HTTPRequest.request err=%d" % err)
		get_tree().quit(1)
		return

	var result: Array = await http.request_completed
	var response_code: int = result[1]
	var body: PackedByteArray = result[3]
	print("  response: code=%d, %d bytes" % [response_code, body.size()])

	if response_code != 200:
		printerr("FAIL body: %s" % body.get_string_from_utf8().substr(0, 500))
		get_tree().quit(1)
		return

	var json: Variant = JSON.parse_string(body.get_string_from_utf8())
	if json == null or not (json is Dictionary) or not (json as Dictionary).has("voices"):
		printerr("FAIL: malformed voices response")
		get_tree().quit(1)
		return

	var voices: Array = json["voices"]
	print("  %d voices accessible to this key:" % voices.size())
	print("")
	print("  %-24s  %-22s  %-16s  %s" % ["voice_id", "name", "category", "labels"])
	print("  %s" % "-".repeat(100))
	for v: Dictionary in voices:
		var vid: String = v.get("voice_id", "?")
		var name: String = v.get("name", "?")
		var cat: String = v.get("category", "?")
		var labels: Dictionary = v.get("labels", {})
		var label_str := ""
		var label_keys: Array = labels.keys()
		label_keys.sort()
		for k: String in label_keys:
			label_str += "%s=%s " % [k, labels[k]]
		print("  %-24s  %-22s  %-16s  %s" % [vid, name, cat, label_str])

	print("")
	print("PASS list_voices: use any of the voice_ids above in dialogue/voices.tres")
	get_tree().quit(0)


func _load_api_key() -> String:
	var env_key := OS.get_environment("ELEVEN_LABS_API_KEY")
	if not env_key.is_empty(): return env_key
	if FileAccess.file_exists(CONFIG_PATH):
		var cf := ConfigFile.new()
		if cf.load(CONFIG_PATH) == OK:
			return cf.get_value("tts", "api_key", "")
	return ""
