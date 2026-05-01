extends Node

## Audio-cue tag verification harness. Synthesizes one demo sentence per
## ElevenLabs cue/tag through Nyx's voice on flash_v2_5 (the project's
## default model — NOT v3, per the established no-v3 rule).
##
## Output lands in res://audio/voice_cache/_tag_test/ as nyx_<slug>.mp3.
## After completion, open that folder and spot-check each clip; tags that
## render audibly = supported on flash. Tags that come through silent or
## mispronounced literally = not supported.
##
## Run:
##   /Applications/Godot.app/Contents/MacOS/Godot --headless \
##       res://tools/tag_test/tag_test.tscn

const ELEVEN_API_URL: String = "https://api.elevenlabs.io/v1/text-to-speech/%s"
const MODEL_ID: String = "eleven_v3"
const OUT_DIR: String = "res://audio/voice_cache/_tag_test_v3"
const CHARACTER: StringName = &"Nyx"

# slug → demo sentence. Keep slugs filename-safe (no spaces / special
# chars) — they go straight into the mp3 name.
const TESTS: Array = [
	{"slug": "laughs", "text": "[laughs] You really pulled that off, runner."},
	{"slug": "laughs_harder", "text": "[laughs harder] No, that's just unfair to him."},
	{"slug": "starts_laughing", "text": "[starts laughing] Wait, are you serious right now?"},
	{"slug": "wheezing", "text": "[wheezing] I cannot — I cannot breathe."},
	{"slug": "whispers", "text": "[whispers] Don't let him hear you."},
	{"slug": "sighs", "text": "[sighs] Of course it does."},
	{"slug": "exhales", "text": "[exhales] Alright. Let's do this."},
	{"slug": "sarcastic", "text": "[sarcastic] Oh, brilliant plan, runner."},
	{"slug": "curious", "text": "[curious] What's behind that door?"},
	{"slug": "excited", "text": "[excited] We did it! That actually worked!"},
	{"slug": "crying", "text": "[crying] He didn't make it out."},
	{"slug": "snorts", "text": "[snorts] Yeah, right."},
	{"slug": "mischievously", "text": "[mischievously] Let's see what trouble we can find."},
	{"slug": "gunshot", "text": "Watch out — [gunshot] — get down!"},
	{"slug": "applause", "text": "[applause] Bravo, runner. Bravo."},
	{"slug": "clapping", "text": "[clapping] Very nice. Very nice indeed."},
	{"slug": "explosion", "text": "The grid just popped. [explosion]"},
	{"slug": "swallows", "text": "[swallows] Okay. Let's do this."},
	{"slug": "gulps", "text": "[gulps] I really hope this works."},
	{"slug": "french_accent", "text": "[strong French accent] You think you understand me, runner?"},
	{"slug": "sings", "text": "[sings] La la la, hacking the planet."},
	{"slug": "woo", "text": "[woo] We're flying!"},
	{"slug": "fart", "text": "[fart] Excuse me, that wasn't me."},
]

var _http: HTTPRequest
var _idx: int = 0
var _voice_id: String = ""
var _api_key: String = ""


func _ready() -> void:
	_api_key = Dialogue._api_key
	if _api_key.is_empty():
		push_error("[tag_test] no ElevenLabs API key — abort")
		get_tree().quit(1)
		return
	var voices: Resource = Dialogue._voices
	if voices == null or not voices.has_method(&"has_voice") or not voices.has_voice(CHARACTER):
		push_error("[tag_test] no voice configured for %s" % CHARACTER)
		get_tree().quit(1)
		return
	_voice_id = voices.get_voice_id(CHARACTER)
	# Make output dir (idempotent).
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(OUT_DIR))
	_http = HTTPRequest.new()
	_http.request_completed.connect(_on_done)
	add_child(_http)
	print("[tag_test] %d tests, model=%s voice=%s (Nyx)" % [TESTS.size(), MODEL_ID, _voice_id])
	print("[tag_test] output dir: %s" % OUT_DIR)
	_next()


func _next() -> void:
	if _idx >= TESTS.size():
		print("[tag_test] DONE — synthesized %d clips. Open %s to listen." % [TESTS.size(), OUT_DIR])
		get_tree().quit(0)
		return
	var test: Dictionary = TESTS[_idx]
	print("[tag_test] %d/%d %s ..." % [_idx + 1, TESTS.size(), test.slug])
	var url: String = ELEVEN_API_URL % _voice_id
	var headers: PackedStringArray = [
		"Accept: audio/mpeg",
		"Content-Type: application/json",
		"xi-api-key: " + _api_key,
	]
	var body: String = JSON.stringify({
		"text": test.text,
		"model_id": MODEL_ID,
		"voice_settings": {"stability": 0.5, "similarity_boost": 0.5},
	})
	var err: int = _http.request(url, headers, HTTPClient.METHOD_POST, body)
	if err != OK:
		push_error("[tag_test] http err for %s: %d" % [test.slug, err])
		_idx += 1
		_next.call_deferred()


func _on_done(_result: int, response_code: int, _headers: PackedStringArray, payload: PackedByteArray) -> void:
	var test: Dictionary = TESTS[_idx]
	if response_code != 200 or payload.size() == 0:
		push_error("[tag_test] %s synth failed code=%d" % [test.slug, response_code])
	else:
		var path: String = "%s/nyx_%s.mp3" % [OUT_DIR, test.slug]
		var f := FileAccess.open(path, FileAccess.WRITE)
		if f != null:
			f.store_buffer(payload)
			f.close()
			print("  → %s (%d bytes)" % [path, payload.size()])
		else:
			push_error("[tag_test] write failed: %s" % path)
	_idx += 1
	_next()
