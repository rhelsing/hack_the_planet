extends Node
## User settings persistence. ConfigFile at user://settings.cfg.
##
## Design (docs/menus.md §3.1, sync_up 2026-04-22):
## - Settings owns the keys. This autoload persists them.
## - AudioServer bus volume writes are owned by interactables_dev's `Audio`
##   autoload (single-writer pattern). Audio subscribes to settings_applied
##   and re-reads the 5 audio.*_volume_db keys.
## - Graphics quality is applied here: shader uniform overrides + World-
##   Environment property toggles. Authored values in the .tres files
##   represent the "high"/"max" preset (we cache them at startup).
## - Camera values (mouse sens, invert_y, FOV, etc.) are read by PlayerBrain
##   from this autoload; we don't push to it. PlayerBrain subscribes to
##   settings_applied and re-reads.

const PATH := "user://settings.cfg"

const DEFAULTS := {
	"audio": {
		"master_volume_db": 0.0,
		"music_volume_db": 0.0,
		"sfx_volume_db": 0.0,
		"dialogue_volume_db": 0.0,
		"ambience_volume_db": 0.0,
	},
	"dialogue": {
		"subtitles_always_on": true,
		"tts_enabled": true,
		"text_speed": 1.0,
	},
	"graphics": {
		"quality": "medium",
		"transition_style": "glitch",  # "glitch" = palette-tinted scanline fade; "instant" disables
	},
	"camera": {
		"mouse_x_sensitivity": 1.0,
		"mouse_y_sensitivity": 1.0,
		"invert_y": true,
		"follow_mode": "DETACHED",
		"release_delay": 2.4,
		"pitch_return_rate": 1.5,
		"fov": 50.0,
	},
}

var data: Dictionary = _deep_duplicate(DEFAULTS)

# Authored values from platforms.tres / buildings.tres. Captured once at
# startup so "high"/"max" presets can restore them exactly and lower presets
# can deviate from them without losing designer tuning on slider return.
var _authored_platform: Dictionary = {}
var _authored_building: Dictionary = {}


func _ready() -> void:
	_capture_authored_values()
	load_from_disk()
	# Deferred so any scene that wants to respond can connect first.
	call_deferred(&"apply")


# ── Public API ───────────────────────────────────────────────────────────

func get_value(section: String, key: String, fallback = null):
	if not data.has(section):
		return fallback
	return data[section].get(key, fallback)


func set_value(section: String, key: String, value) -> void:
	if not data.has(section):
		data[section] = {}
	data[section][key] = value
	save_to_disk()
	apply()


func apply() -> void:
	_apply_graphics()
	Events.settings_applied.emit()


func load_from_disk() -> void:
	var cf := ConfigFile.new()
	if cf.load(PATH) != OK:
		return
	for section in data.keys():
		for key in data[section].keys():
			data[section][key] = cf.get_value(section, key, data[section][key])


func save_to_disk() -> void:
	var cf := ConfigFile.new()
	for section in data.keys():
		for key in data[section].keys():
			cf.set_value(section, key, data[section][key])
	cf.save(PATH)


# ── Internals ────────────────────────────────────────────────────────────

func _capture_authored_values() -> void:
	var plat := load("res://level/platforms.tres") as ShaderMaterial
	if plat != null:
		for k in [
			"pit_strength", "smudge_strength", "scratch_strength",
			"pulse_density",
		]:
			var v = plat.get_shader_parameter(k)
			if v != null:
				_authored_platform[k] = v
	var bldg := load("res://level/buildings.tres") as ShaderMaterial
	if bldg != null:
		for k in [
			"pit_strength", "smudge_strength", "scratch_strength",
			"code_opacity",
		]:
			var v = bldg.get_shader_parameter(k)
			if v != null:
				_authored_building[k] = v


func _apply_graphics() -> void:
	var q := String(data.graphics.quality)
	var plat := load("res://level/platforms.tres") as ShaderMaterial
	var bldg := load("res://level/buildings.tres") as ShaderMaterial

	match q:
		"low":
			_override(plat, "pit_strength", 0.0)
			_override(plat, "smudge_strength", 0.0)
			_override(plat, "scratch_strength", 0.0)
			_override(plat, "pulse_density", 0.3)
			_override(bldg, "pit_strength", 0.0)
			_override(bldg, "smudge_strength", 0.0)
			_override(bldg, "scratch_strength", 0.0)
			# Keep the scrolling code overlay on buildings — it's part of the
			# game's signature look, not a surface-detail effect that should
			# fall off with quality.
			_authored(bldg, _authored_building, "code_opacity")
		"medium":
			_override(plat, "pit_strength", 0.0)
			_authored(plat, _authored_platform, "smudge_strength")
			_authored(plat, _authored_platform, "scratch_strength")
			_authored(plat, _authored_platform, "pulse_density")
			_override(bldg, "pit_strength", 0.0)
			_authored(bldg, _authored_building, "smudge_strength")
			_authored(bldg, _authored_building, "scratch_strength")
			_authored(bldg, _authored_building, "code_opacity")
		"high", "max":
			for k in _authored_platform.keys():
				_authored(plat, _authored_platform, k)
			for k in _authored_building.keys():
				_authored(bldg, _authored_building, k)

	_apply_environment(q)


func _apply_environment(quality: String) -> void:
	var env := _find_active_environment()
	if env == null:
		return
	match quality:
		"low":
			env.ssr_enabled = false
			env.ssil_enabled = false
			env.ssao_enabled = false
			env.sdfgi_enabled = false
			env.volumetric_fog_density = 0.0
			env.glow_enabled = true
		"medium":
			env.ssr_enabled = true
			env.ssr_max_steps = 16
			env.ssil_enabled = false
			env.ssao_enabled = true
			env.sdfgi_enabled = false
			env.volumetric_fog_density = 0.0
			env.glow_enabled = true
		"high":
			env.ssr_enabled = true
			env.ssr_max_steps = 32
			env.ssil_enabled = true
			env.ssao_enabled = true
			env.sdfgi_enabled = false
			env.volumetric_fog_density = 0.005
			env.glow_enabled = true
		"max":
			env.ssr_enabled = true
			env.ssr_max_steps = 48
			env.ssil_enabled = true
			env.ssao_enabled = true
			env.sdfgi_enabled = true
			env.volumetric_fog_density = 0.01
			env.glow_enabled = true


func _override(mat: ShaderMaterial, key: String, v) -> void:
	if mat == null:
		return
	mat.set_shader_parameter(key, v)


func _authored(mat: ShaderMaterial, source: Dictionary, key: String) -> void:
	if mat == null or not source.has(key):
		return
	mat.set_shader_parameter(key, source[key])


func _find_active_environment() -> Environment:
	var scene := get_tree().current_scene
	if scene == null:
		return null
	var we := _find_world_environment(scene)
	if we == null:
		return null
	return we.environment


func _find_world_environment(n: Node) -> WorldEnvironment:
	if n is WorldEnvironment:
		return n as WorldEnvironment
	for c in n.get_children():
		var r := _find_world_environment(c)
		if r != null:
			return r
	return null


# Godot's Dictionary.duplicate(true) is not deeply safe across nested dicts
# with mixed types in older 4.x — this helper is defensive.
func _deep_duplicate(d: Dictionary) -> Dictionary:
	var out := {}
	for k in d.keys():
		var v = d[k]
		if v is Dictionary:
			out[k] = _deep_duplicate(v)
		elif v is Array:
			out[k] = (v as Array).duplicate(true)
		else:
			out[k] = v
	return out
