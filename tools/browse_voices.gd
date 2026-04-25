extends Node

## Searches the ElevenLabs Voice Library (community-shared voices) via the
## /v1/shared-voices endpoint. Prints name + voice_id + description +
## preview_url for each match, ranked by featured status. Use the preview
## URLs to listen before committing — paste them into a browser.
##
## Run: godot --headless res://tools/browse_voices.tscn --quit-after 1200
##
## Edit QUERIES below to pivot the search. The script runs each query
## sequentially and dedupes voice_ids across results.


const CONFIG_PATH: String = "user://tts_config.tres"
const REPO_CONFIG_PATH: String = "res://dialogue/tts_config.tres"

# Each query is a Dictionary of URL parameters. Multiple queries widen the
# net — same voice may show up across several, dedupe by voice_id.
const QUERIES: Array = [
	{"search": "sultry", "gender": "female", "language": "en"},
	{"search": "femme fatale", "gender": "female", "language": "en"},
	{"search": "smoky", "gender": "female", "language": "en"},
	{"search": "noir", "gender": "female", "language": "en"},
	{"search": "african american", "gender": "female", "language": "en"},
	{"search": "soulful", "gender": "female", "language": "en"},
	{"accent": "american", "gender": "female", "age": "middle_aged", "language": "en", "page_size": "30"},
]


var _seen: Dictionary = {}
var _all_results: Array = []


func _ready() -> void:
	_run.call_deferred()


func _run() -> void:
	var api_key := _load_api_key()
	if api_key.is_empty():
		printerr("FAIL: no API key configured"); get_tree().quit(1); return

	for q in QUERIES:
		await _query(api_key, q)

	_print_results()
	get_tree().quit(0)


func _query(api_key: String, params: Dictionary) -> void:
	var url := "https://api.elevenlabs.io/v1/shared-voices?"
	var pairs: Array[String] = []
	for k in params:
		pairs.append("%s=%s" % [k, String(params[k]).uri_encode()])
	url += "&".join(pairs)

	print("\n--- query: %s ---" % params)
	var http := HTTPRequest.new()
	add_child(http)
	var headers: PackedStringArray = ["xi-api-key: " + api_key]
	var err := http.request(url, headers, HTTPClient.METHOD_GET)
	if err != OK:
		printerr("FAIL: HTTPRequest.request err=%d" % err); return
	var result: Array = await http.request_completed
	var code: int = result[1]
	var body: PackedByteArray = result[3]
	http.queue_free()
	if code != 200:
		printerr("  FAIL: code=%d  body=%s" % [code, body.get_string_from_utf8().substr(0, 200)])
		return
	var data: Variant = JSON.parse_string(body.get_string_from_utf8())
	if not (data is Dictionary):
		printerr("  FAIL: unexpected response shape"); return
	var voices: Array = (data as Dictionary).get("voices", [])
	print("  %d hits" % voices.size())
	for v: Dictionary in voices:
		var vid: String = v.get("voice_id", "")
		if vid.is_empty() or _seen.has(vid):
			continue
		_seen[vid] = true
		_all_results.append(v)


func _print_results() -> void:
	# Light ranking: featured first, then by name. Keeps it deterministic.
	_all_results.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		var fa: bool = a.get("featured", false)
		var fb: bool = b.get("featured", false)
		if fa != fb: return fa
		return String(a.get("name", "")) < String(b.get("name", ""))
	)
	print("\n=== %d unique candidates ===" % _all_results.size())
	for v: Dictionary in _all_results:
		var name: String = v.get("name", "?")
		var vid: String = v.get("voice_id", "?")
		var desc: String = String(v.get("description", "")).substr(0, 120).replace("\n", " ")
		var preview: String = v.get("preview_url", "")
		var accent: String = v.get("accent", "?")
		var age: String = v.get("age", "?")
		var descriptive: String = v.get("descriptive", "?")
		var use_case: String = v.get("use_case", "?")
		var featured: bool = v.get("featured", false)
		print("\n[%s%s]  %s  (%s)" % [
			"★ " if featured else "", name, vid, accent,
		])
		print("  age=%s  vibe=%s  use=%s" % [age, descriptive, use_case])
		if not desc.is_empty():
			print("  \"%s\"" % desc)
		if not preview.is_empty():
			print("  preview: %s" % preview)


func _load_api_key() -> String:
	var env_key := OS.get_environment("ELEVEN_LABS_API_KEY")
	if not env_key.is_empty(): return env_key
	for path in [CONFIG_PATH, REPO_CONFIG_PATH]:
		if FileAccess.file_exists(path):
			var cf := ConfigFile.new()
			if cf.load(path) == OK:
				var k: String = cf.get_value("tts", "api_key", "")
				if not k.is_empty(): return k
	return ""
