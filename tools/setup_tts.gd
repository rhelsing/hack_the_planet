extends SceneTree

## One-shot tool: writes an ElevenLabs API key to user://tts_config.tres so
## the Dialogue autoload picks it up. The config lives under the user's Godot
## app_userdata directory (NOT in the repo — never committed).
##
## Usage:
##   godot --headless --script res://tools/setup_tts.gd --quit -- <api_key>
##
## Or set it inline (fallback if no arg passed):
##   godot --headless --script res://tools/setup_tts.gd --quit
##
## The key from /Users/ryanhelsing/GodotProjects/3dPFormer/dialogue_balloon/
## balloon.gd is baked into DEFAULT_KEY below as a convenience for this
## demo project. Replace with your own key or pass as arg.


const DEFAULT_KEY: String = "6d55209ea42585939fb4650dbefe92d1"
const CONFIG_PATH: String = "user://tts_config.tres"


func _init() -> void:
	var key: String = DEFAULT_KEY
	var args := OS.get_cmdline_user_args()
	if args.size() > 0 and not args[0].is_empty():
		key = args[0]

	var cf := ConfigFile.new()
	cf.set_value("tts", "api_key", key)
	var result := cf.save(CONFIG_PATH)
	if result != OK:
		printerr("FAIL setup_tts: ConfigFile.save(%s) returned %d" % [CONFIG_PATH, result])
		quit(1)
		return

	var globalized := ProjectSettings.globalize_path(CONFIG_PATH)
	print("PASS setup_tts: wrote api_key to %s" % CONFIG_PATH)
	print("  -> %s" % globalized)
	print("  -> length=%d chars (first 6: %s…)" % [key.length(), key.substr(0, 6)])
	print("")
	print("The Dialogue autoload will pick this up at next boot via _load_api_key().")
	print("To override per-session, set env: export ELEVEN_LABS_API_KEY=<key>")
	quit(0)
