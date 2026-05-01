extends Node3D
class_name CrumblePlatform

## Player lands → deck shakes for `shake_duration`, then drops out from under
## them faster than gravity. During the drop the kaykit `death_glitch` overlay
## ramps to 1, giving the cyan/magenta tear that reads as "glitching out of
## existence." Resets `reset_after_contact` seconds after first contact so the
## next traversal restarts the cycle clean.
##
## Same shader/palette plumbing as bouncy_platform: per-instance duplicate of
## `platforms.tres` with overrideable base/highlight colors (default red).
##
## Note: NO reparent trick. The player rides via plain CharacterBody3D
## collision the entire time. During shake the deck jitters under their feet
## (the player stays steady; the visual jitter sells the destabilization).
## During drop the deck pulls away faster than gravity, naturally putting
## the player in free-fall. During reset the deck's collision is off so the
## position snap can't push anything.

const _PLATFORM_MATERIAL: ShaderMaterial = preload("res://level/platforms.tres")
const _GLITCH_SHADER: Shader = preload("res://player/skins/kaykit/death_glitch.gdshader")

enum Phase { IDLE, SHAKING, CRUMBLING, GONE }

@export_group("Color")
@export var palette_base: Color = Color(0.04, 0.0, 0.0, 1.0):
	set(value):
		palette_base = value
		_apply_palette()
@export var palette_highlight: Color = Color(1.0, 0.18, 0.12, 1.0):
	set(value):
		palette_highlight = value
		_apply_palette()

@export_group("Shape")
@export var size: Vector3 = Vector3(4.0, 1.0, 4.0):
	set(value):
		size = value
		_apply_size()

@export_group("Audio")
## Round-robin pool. One clip per crumble — index cycles across all instances
## so back-to-back falls don't repeat. Defaults to the 5 glitch-death stingers
## the maze puzzle uses for its fail SFX.
@export var glitch_sounds: Array[AudioStream] = [
	preload("res://audio/sfx/enemy_deaths/glitch_death_1.wav"),
	preload("res://audio/sfx/enemy_deaths/glitch_death_2.wav"),
	preload("res://audio/sfx/enemy_deaths/glitch_death_3.wav"),
	preload("res://audio/sfx/enemy_deaths/glitch_death_4.wav"),
	preload("res://audio/sfx/enemy_deaths/glitch_death_5.wav"),
]
@export_range(-30.0, 12.0) var glitch_volume_db: float = 0.0
## Loops while the deck is shaking — same hacking-puzzle buzz the maze uses
## for its slide loop. Stops the moment the deck starts to crumble.
@export var shake_sound: AudioStream = preload("res://audio/sfx/maze_buzz.mp3")
@export_range(-30.0, 12.0) var shake_volume_db: float = -6.0
## Glitch overlay value at the end of the shake phase. The crumble continues
## from here to 1.0 — keeps the chromatic-aberration ramp continuous instead
## of popping back to 0 at the start of the fall.
@export_range(0.0, 1.0) var shake_glitch_peak: float = 0.25

@export_group("Timeline")
## Seconds the deck shakes after first contact, before it crumbles.
@export var shake_duration: float = 3.0
## Peak shake amplitude in meters; ramps in quadratically over `shake_duration`
## so the destabilization reads as accelerating.
@export var shake_amplitude: float = 0.1
## Seconds the deck takes to fall away.
@export var crumble_duration: float = 2.0
## Distance the deck drops over `crumble_duration` (with QUAD/EASE_IN curve so
## it accelerates into the fall — pulls away from a player who's now in
## free-fall under regular gravity).
@export var crumble_drop: float = 16.0
## Total seconds from first contact until the deck snaps back. The remainder
## (after shake + crumble) is the "gone" interval.
@export var reset_after_contact: float = 10.0

@onready var _deck: Node3D = $Deck
@onready var _box: CSGBox3D = $Deck/Box
@onready var _trigger: Area3D = $Trigger
@onready var _trigger_shape: CollisionShape3D = $Trigger/Shape

var _material: ShaderMaterial = null
var _glitch_overlay: ShaderMaterial = null
var _deck_base_position: Vector3 = Vector3.ZERO
var _phase: int = Phase.IDLE
var _shake_t: float = 0.0
var _tween: Tween = null
var _sfx_player: AudioStreamPlayer3D = null
var _shake_sfx_player: AudioStreamPlayer3D = null

# Cross-instance round-robin. Static so two platforms breaking back-to-back
# play different stingers regardless of which instance fires first.
static var _glitch_idx: int = 0

# Class-level overrides driven by debug panel. NAN = "use my @export."
# Shared across all instances for global tuning.
static var _override_shake_duration: float = NAN
static var _override_shake_amplitude: float = NAN
static var _override_crumble_duration: float = NAN
static var _override_crumble_drop: float = NAN
static var _override_reset_after_contact: float = NAN
static var _panel_registered: bool = false


func _ready() -> void:
	_material = _PLATFORM_MATERIAL.duplicate() as ShaderMaterial
	_box.material_override = _material
	_glitch_overlay = ShaderMaterial.new()
	_glitch_overlay.shader = _GLITCH_SHADER
	_glitch_overlay.set_shader_parameter(&"glitch_progress", 0.0)
	_box.material_overlay = _glitch_overlay
	_apply_palette()
	_apply_size()
	_deck_base_position = _deck.position
	_trigger.body_entered.connect(_on_body_entered)
	_sfx_player = AudioStreamPlayer3D.new()
	_sfx_player.bus = &"SFX"
	_sfx_player.unit_size = 6.0
	_sfx_player.max_distance = 35.0
	_deck.add_child(_sfx_player)
	# Shake loop — duplicate so we can flip `loop` on without mutating the
	# shared resource other systems may use unlooped (matches maze_puzzle.gd).
	if shake_sound != null:
		var loop_stream: AudioStream = shake_sound.duplicate()
		if "loop" in loop_stream:
			loop_stream.loop = true
		_shake_sfx_player = AudioStreamPlayer3D.new()
		_shake_sfx_player.bus = &"SFX"
		_shake_sfx_player.unit_size = 6.0
		_shake_sfx_player.max_distance = 35.0
		_shake_sfx_player.stream = loop_stream
		_shake_sfx_player.volume_db = shake_volume_db
		_deck.add_child(_shake_sfx_player)
	_register_debug_panel()


func _process(delta: float) -> void:
	if _phase != Phase.SHAKING:
		return
	_shake_t += delta
	# Quadratic ramp so jitter is barely visible at first and aggressive by
	# the time it crumbles — sells "this thing is failing." Player rides on
	# the deck's collision; this jitter only moves the deck, not the player.
	var prog: float = clampf(_shake_t / _eff_shake_duration(), 0.0, 1.0)
	var amp: float = _eff_shake_amplitude() * prog * prog
	_deck.position = _deck_base_position + Vector3(
		randf_range(-amp, amp),
		randf_range(-amp, amp),
		randf_range(-amp, amp))
	# Subtle glitch overlay during shake — same quadratic ramp, capped at
	# `shake_glitch_peak`. Crumble continues the ramp from this value to 1.0.
	_set_glitch_progress(prog * prog * shake_glitch_peak)


func _on_body_entered(body: Node) -> void:
	if _phase != Phase.IDLE:
		return
	if not body.is_in_group("player"):
		return
	# Just kick off the timeline. No reparent — the player rides via
	# CharacterBody3D collision against the deck the whole way through.
	_enter_shaking()


func _enter_shaking() -> void:
	_phase = Phase.SHAKING
	_shake_t = 0.0
	if _shake_sfx_player != null:
		_shake_sfx_player.play()
	if _tween != null and _tween.is_valid():
		_tween.kill()
	_tween = create_tween()
	_tween.tween_interval(_eff_shake_duration())
	_tween.tween_callback(_enter_crumbling)


func _enter_crumbling() -> void:
	_phase = Phase.CRUMBLING
	_play_glitch_sfx()
	if _shake_sfx_player != null and _shake_sfx_player.playing:
		_shake_sfx_player.stop()
	var crumble_t: float = _eff_crumble_duration()
	var drop_target_y: float = _deck_base_position.y - _eff_crumble_drop()
	# Snap deck back to base before tweening — shake left it at a random
	# offset; if we don't, the QUAD curve starts from the wrong spot.
	_deck.position = _deck_base_position
	# Continue the glitch ramp from wherever shake left it (~shake_glitch_peak)
	# up to 1.0 — avoids a pop back to 0 at the start of the fall.
	var glitch_start: float = 0.0
	if _glitch_overlay != null:
		glitch_start = float(_glitch_overlay.get_shader_parameter(&"glitch_progress"))
	if _tween != null and _tween.is_valid():
		_tween.kill()
	_tween = create_tween()
	_tween.set_parallel(true)
	_tween.tween_property(_deck, ^"position:y", drop_target_y, crumble_t) \
		.set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_IN)
	_tween.tween_method(_set_glitch_progress, glitch_start, 1.0, crumble_t * 0.85)
	_tween.chain().tween_callback(_enter_gone)


func _enter_gone() -> void:
	_phase = Phase.GONE
	_box.visible = false
	_box.use_collision = false
	# Sleep the rest of the cycle, then reset.
	var elapsed: float = _eff_shake_duration() + _eff_crumble_duration()
	var remaining: float = maxf(_eff_reset_after_contact() - elapsed, 0.1)
	if _tween != null and _tween.is_valid():
		_tween.kill()
	_tween = create_tween()
	_tween.tween_interval(remaining)
	_tween.tween_callback(_reset)


func _reset() -> void:
	_phase = Phase.IDLE
	# Collision was off during the GONE phase, so the position snap can't
	# push anything — safe to teleport the deck back to base.
	_deck.position = _deck_base_position
	_box.visible = true
	_box.use_collision = true
	_set_glitch_progress(0.0)


func _set_glitch_progress(v: float) -> void:
	if _glitch_overlay != null:
		_glitch_overlay.set_shader_parameter(&"glitch_progress", v)


func _play_glitch_sfx() -> void:
	if _sfx_player == null or glitch_sounds.is_empty():
		return
	var stream: AudioStream = glitch_sounds[_glitch_idx % glitch_sounds.size()]
	_glitch_idx = (_glitch_idx + 1) % glitch_sounds.size()
	if stream == null:
		return
	_sfx_player.stream = stream
	_sfx_player.volume_db = glitch_volume_db
	_sfx_player.play()


func _apply_palette() -> void:
	if _material == null:
		return
	_material.set_shader_parameter(&"palette_black", palette_base)
	_material.set_shader_parameter(&"palette_purple", palette_highlight)


func _apply_size() -> void:
	if _box != null:
		_box.size = size
	if _trigger_shape != null and _trigger_shape.shape is BoxShape3D:
		var trigger_box: BoxShape3D = _trigger_shape.shape as BoxShape3D
		trigger_box.size = Vector3(size.x, 0.6, size.z)
		_trigger_shape.position.y = size.y * 0.5 + 0.3


# Effective getters: panel override wins, otherwise the @export.
func _eff_shake_duration() -> float:
	return shake_duration if is_nan(_override_shake_duration) else _override_shake_duration

func _eff_shake_amplitude() -> float:
	return shake_amplitude if is_nan(_override_shake_amplitude) else _override_shake_amplitude

func _eff_crumble_duration() -> float:
	return crumble_duration if is_nan(_override_crumble_duration) else _override_crumble_duration

func _eff_crumble_drop() -> float:
	return crumble_drop if is_nan(_override_crumble_drop) else _override_crumble_drop

func _eff_reset_after_contact() -> float:
	return reset_after_contact if is_nan(_override_reset_after_contact) else _override_reset_after_contact


func _register_debug_panel() -> void:
	if _panel_registered:
		return
	var dp: Node = get_tree().root.get_node_or_null(^"DebugPanel")
	if dp == null:
		return
	_panel_registered = true
	_override_shake_duration = shake_duration
	_override_shake_amplitude = shake_amplitude
	_override_crumble_duration = crumble_duration
	_override_crumble_drop = crumble_drop
	_override_reset_after_contact = reset_after_contact
	dp.call(&"add_slider", "Crumble/shake_duration", 0.5, 8.0, 0.1,
		func() -> float: return _override_shake_duration,
		func(v: float) -> void: _override_shake_duration = v,
		"crumble_platform.gd")
	dp.call(&"add_slider", "Crumble/shake_amplitude", 0.0, 0.3, 0.005,
		func() -> float: return _override_shake_amplitude,
		func(v: float) -> void: _override_shake_amplitude = v,
		"crumble_platform.gd")
	dp.call(&"add_slider", "Crumble/crumble_duration", 0.1, 2.0, 0.05,
		func() -> float: return _override_crumble_duration,
		func(v: float) -> void: _override_crumble_duration = v,
		"crumble_platform.gd")
	dp.call(&"add_slider", "Crumble/crumble_drop", 2.0, 40.0, 0.5,
		func() -> float: return _override_crumble_drop,
		func(v: float) -> void: _override_crumble_drop = v,
		"crumble_platform.gd")
	dp.call(&"add_slider", "Crumble/reset_after_contact", 1.0, 15.0, 0.25,
		func() -> float: return _override_reset_after_contact,
		func(v: float) -> void: _override_reset_after_contact = v,
		"crumble_platform.gd")
