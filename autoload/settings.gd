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
		# First-launch defaults (used only when settings.cfg has no value
		# stored). Slider values in the menu show as linear 0..1; these are
		# their dB equivalents via linear_to_db(): 0.50 → -6.02, 0.33 → -9.63,
		# 0.65 → -3.74. Returning users keep whatever they last set.
		"master_volume_db": -6.02,    # ~50% slider
		"music_volume_db": -20.0,     # 10% slider (linear_to_db(0.1))
		"sfx_volume_db": -3.74,       # ~65% slider
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
		"crt_enabled": false,          # full-screen VHS/CRT monitor filter (off by default)
	},
	"hud": {
		# Single uniform scaler for all HUD content: powerup pills, coin/
		# walkie/keys counters, walkie/companion subtitle bubble, beacon
		# waypoint text, hacking-puzzle title/subline/instructions, and
		# the post-pickup powerup card. Each consumer multiplies its base
		# sizes (icon px, font_size) by this value on settings_applied.
		# Range 0.5–5.0; default 1.5 — modestly enlarged from 1.0 base for
		# legibility while leaving room above to scale up.
		"scale": 1.5,
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
	"input": {
		# Which device drives glyph swaps in HUD prompts, dialogue
		# placeholders, hint zones, and the controls panel. "auto" follows the
		# player's most recently used device (PlayerBrain.last_device). "keyboard"
		# / "gamepad" force the choice. Glyphs._active_device() reads this.
		"device_mode": "auto",
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
	# Deferred so DebugPanel's _ready has built its UI (autoload order agnostic).
	call_deferred(&"_register_env_debug_sliders")


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


## Convenience getter for HUD consumers. Clamped to the slider's
## authoring range so a stale settings.cfg from before this key existed
## (or a hand-edit) can't push consumers into an unusable size.
func get_hud_scale() -> float:
	return clampf(float(get_value("hud", "scale", 1.5)), 0.5, 5.0)


func apply() -> void:
	_apply_graphics()
	_apply_crt()
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

# Persistent full-screen VHS/CRT filter. Parented to the tree root (not the
# current scene) so it survives level swaps, and sits at layer 1900 — above
# HUD/menus (1000), below scene transitions (2000). apply() runs on every
# level mount and on each set_value, so this is idempotent: show once, remove
# once, no-op otherwise.
const _CRT_SHADER := "res://menu/effects/vhs_crt.gdshader"
const _CRT_LAYER := 1900
var _crt_overlay: ScreenShaderOverlay = null


func _apply_crt() -> void:
	var on := bool(get_value("graphics", "crt_enabled", false))
	if on:
		if _crt_overlay == null or not is_instance_valid(_crt_overlay):
			_crt_overlay = ScreenShaderOverlay.spawn(get_tree().root, _CRT_SHADER, _CRT_LAYER)
	elif _crt_overlay != null and is_instance_valid(_crt_overlay):
		_crt_overlay.queue_free()
		_crt_overlay = null


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


## The one global color-grade slot. Swap this file (level/luts/ holds the
## library) and every scene follows — no per-scene wiring needed.
const _COLOR_GRADE_LUT_PATH := "res://level/color_grade_lut.png"


func _apply_environment(quality: String) -> void:
	var env := _find_active_environment()
	if env == null:
		return
	# Global LUT enforcement: runs on every level mount (Settings.apply in
	# game.gd), so any scene whose Environment didn't author its OWN color
	# correction inherits the shipped grade. Authored references win —
	# per-level custom grades stay possible. Needs the env's authored
	# adjustment_enabled = true to show (all current envs set it).
	if env.adjustment_color_correction == null:
		env.adjustment_color_correction = load(_COLOR_GRADE_LUT_PATH)
	match quality:
		"low":
			# SSR on at 8 steps — minimum trace length so the cheapest preset
			# still shows a near-cropped player reflection on platforms (the
			# game's signature look). 8 is half of medium's 16; reflections
			# fade out within ~2-3m of the surface.
			env.ssr_enabled = true
			env.ssr_max_steps = 8
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
			env.ssr_max_steps = 64
			env.ssil_enabled = true
			env.ssao_enabled = true
			# SDFGI explicitly OFF: enabling it triggers a per-toggle voxel
			# bake of every static MeshInstance in the scene. With the
			# procedural city (~1600 buildings), the bake is a multi-second
			# main-thread stall that looks like a freeze. The other Max-only
			# bumps (SSR 64 steps, denser fog) carry the visual upgrade
			# without the cost. Re-enable here only if SDFGI gets streaming
			# / async support OR the city is downsized.
			env.sdfgi_enabled = false
			env.volumetric_fog_density = 0.015
			env.glow_enabled = true


# Live glow / color-adjust tuning in the DebugPanel (` to toggle). One
# registration for the whole session: getters/setters resolve the CURRENT
# level's Environment on every call via _find_active_environment(), so the
# sliders keep working across level swaps (each level duplicates its env at
# _ready — we always write to the live copy). Values are session-only by
# DebugPanel design: tweak, hit "Copy diff", stamp the numbers back into the
# authored Environment sub-resources (hub.tscn, level_mockup.tscn, …).
# NOTE: slider *initial* values are captured from whatever scene is mounted
# at registration time (usually the main menu) — read the current value off
# the label after entering a level, not the diff baseline.
func _register_env_debug_sliders() -> void:
	var src := "Environment sub_resource in hub.tscn / level_*.tscn"
	# LUT selector, registered FIRST so it sits at the top of the panel.
	# "off" = no color correction (the old kill-switch); "active" = the
	# shipped slot (level/color_grade_lut.png); the rest is the library in
	# level/luts/, scanned at registration so new files appear with zero
	# code. Selection is session-only (DebugPanel philosophy) — to make one
	# permanent, copy it over the active slot. Library files must be
	# imported as Texture3D (16-slice strips); a 2D-imported strip would be
	# silently misread as a 1D ramp.
	var lut_options := PackedStringArray(["off", "active"])
	var lut_paths: Array[String] = ["", "res://level/color_grade_lut.png"]
	var lut_dir := DirAccess.open("res://level/luts")
	if lut_dir != null:
		var lut_files := lut_dir.get_files()
		lut_files.sort()
		for f: String in lut_files:
			if f.ends_with(".png"):
				lut_options.append(f.get_basename())
				lut_paths.append("res://level/luts/" + f)
	DebugPanel.add_enum("Environment/LUT", lut_options,
		func() -> int:
			var e := _find_active_environment()
			if e == null or e.adjustment_color_correction == null:
				return 0
			var i := lut_paths.find(e.adjustment_color_correction.resource_path)
			return i if i >= 0 else 1,
		func(idx: int) -> void:
			var e := _find_active_environment()
			if e == null:
				return
			e.adjustment_color_correction = \
				null if idx <= 0 or idx >= lut_paths.size() else load(lut_paths[idx]),
		src)
	DebugPanel.add_toggle("Environment/Glow/enabled",
		func() -> bool: var e := _find_active_environment(); return e.glow_enabled if e != null else false,
		func(v: bool) -> void: var e := _find_active_environment(); if e != null: e.glow_enabled = v,
		src)
	_env_slider("Environment/Glow/intensity", 0.0, 8.0, 0.005, &"glow_intensity", src)
	_env_slider("Environment/Glow/strength", 0.0, 2.0, 0.005, &"glow_strength", src)
	_env_slider("Environment/Glow/bloom", 0.0, 1.0, 0.005, &"glow_bloom", src)
	_env_slider("Environment/Glow/hdr_threshold", 0.0, 4.0, 0.01, &"glow_hdr_threshold", src)
	_env_slider("Environment/Glow/hdr_scale", 0.0, 4.0, 0.01, &"glow_hdr_scale", src)
	_env_slider("Environment/Glow/hdr_luminance_cap", 0.0, 256.0, 0.5, &"glow_hdr_luminance_cap", src)
	DebugPanel.add_enum("Environment/Glow/blend_mode",
		PackedStringArray(["Additive", "Screen", "Softlight", "Replace", "Mix"]),
		func() -> int: var e := _find_active_environment(); return e.glow_blend_mode if e != null else 0,
		func(idx: int) -> void: var e := _find_active_environment(); if e != null: e.glow_blend_mode = idx,
		src)
	DebugPanel.add_toggle("Environment/Adjust/enabled",
		func() -> bool: var e := _find_active_environment(); return e.adjustment_enabled if e != null else false,
		func(v: bool) -> void: var e := _find_active_environment(); if e != null: e.adjustment_enabled = v,
		src)
	_env_slider("Environment/Adjust/brightness", 0.25, 2.0, 0.005, &"adjustment_brightness", src)
	_env_slider("Environment/Adjust/contrast", 0.25, 2.0, 0.005, &"adjustment_contrast", src)
	_env_slider("Environment/Adjust/saturation", 0.0, 3.0, 0.005, &"adjustment_saturation", src)


func _env_slider(path: String, min_v: float, max_v: float, step: float, prop: StringName, src: String) -> void:
	DebugPanel.add_slider(path, min_v, max_v, step,
		func() -> float:
			var env := _find_active_environment()
			return float(env.get(prop)) if env != null else 0.0,
		func(v: float) -> void:
			var env := _find_active_environment()
			if env != null:
				env.set(prop, v),
		src)


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
