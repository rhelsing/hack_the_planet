extends SceneTree

## Per-dev override tool: writes a custom ElevenLabs API key to
## user://tts_config.tres. The Dialogue autoload reads in this order at
## boot:
##   1. ELEVEN_LABS_API_KEY env var
##   2. user://tts_config.tres   (this file's output — per-dev override)
##   3. res://dialogue/tts_config.tres   (committed in repo, default for all devs)
##
## You only need to run this if you want to override the committed key on
## your machine (e.g. testing a different ElevenLabs account). A fresh
## clone already works without running this.
##
## Usage:
##   godot --headless --script res://tools/setup_tts.gd --quit -- <api_key>


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
