extends Node3D
class_name CrumblePlatform

## Player lands → deck shakes for `shake_duration`, then drops out from under
## them faster than gravity (player is released on phase change, so they fall
## under their own gravity while the deck pulls away). During the drop the
## kaykit `death_glitch` overlay ramps to 1, giving the cyan/magenta tear that
## reads as "glitching out of existence." Resets `reset_after_contact` seconds
## after first contact so the next traversal restarts the cycle clean.
##
## Same shader/palette plumbing as bouncy_platform: per-instance duplicate of
## `platforms.tres` with overrideable base/highlight colors (default red).

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

@export_group("Timeline")
## Seconds the deck shakes after first contact, before it crumbles.
@export var shake_duration: float = 3.0
## Peak shake amplitude in meters; ramps in quadratically over `shake_duration`
## so the destabilization reads as accelerating.
@export var shake_amplitude: float = 0.05
## Seconds the deck takes to fall away. Short = "yanked from under you."
@export var crumble_duration: float = 0.6
## Distance the deck drops over `crumble_duration` (with QUAD/EASE_IN curve so
## it accelerates into the fall — pulls away from a player who's now in
## free-fall under regular gravity).
@export var crumble_drop: float = 16.0
## Total seconds from first contact until the deck snaps back. The remainder
## (after shake + crumble) is the "gone" interval.
@export var reset_after_contact: float = 5.0

@onready var _deck: Node3D = $Deck
@onready var _box: CSGBox3D = $Deck/Box
@onready var _carry_zone: Area3D = $CarryZone
@onready var _carry_shape: CollisionShape3D = $CarryZone/Shape

var _material: ShaderMaterial = null
var _glitch_overlay: ShaderMaterial = null
var _deck_base_position: Vector3 = Vector3.ZERO
var _phase: int = Phase.IDLE
var _shake_t: float = 0.0
var _carried_body: Node3D = null
var _original_parent: Node = null
var _tween: Tween = null

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
	_carry_zone.body_entered.connect(_on_body_entered)
	_carry_zone.body_exited.connect(_on_body_exited)
	_register_debug_panel()


func _process(delta: float) -> void:
	if _phase != Phase.SHAKING:
		return
	_shake_t += delta
	# Quadratic ramp so jitter is barely visible at first and aggressive by
	# the time it crumbles — sells "this thing is failing."
	var prog: float = clampf(_shake_t / _eff_shake_duration(), 0.0, 1.0)
	var amp: float = _eff_shake_amplitude() * prog * prog
	_deck.position = _deck_base_position + Vector3(
		randf_range(-amp, amp),
		randf_range(-amp, amp),
		randf_range(-amp, amp))


func _on_body_entered(body: Node) -> void:
	if _phase != Phase.IDLE:
		return
	if not body.is_in_group("player"):
		return
	if not (body is Node3D):
		return
	_carried_body = body as Node3D
	_original_parent = body.get_parent()
	# Reparent under Deck (elevator trick) so the shake doesn't fight the
	# player's own physics — they ride the jitter cleanly. Deferred because
	# we're inside a body_entered signal (physics frame).
	body.call_deferred(&"reparent", _deck, true)
	_enter_shaking()


func _on_body_exited(body: Node) -> void:
	# Walked / jumped off mid-shake. If still parented under Deck, restore
	# their original parent — otherwise the deck's shake / fall / reset
	# will keep dragging them via parent transform inheritance even though
	# they're physically meters away.
	if body != _carried_body:
		return
	_release_player()


func _enter_shaking() -> void:
	_phase = Phase.SHAKING
	_shake_t = 0.0
	if _tween != null and _tween.is_valid():
		_tween.kill()
	_tween = create_tween()
	_tween.tween_interval(_eff_shake_duration())
	_tween.tween_callback(_enter_crumbling)


func _enter_crumbling() -> void:
	_phase = Phase.CRUMBLING
	# Release player BEFORE the drop so they don't ride it down. They're now
	# at the position the shake left them, with their own velocity + gravity
	# acting normally; the deck pulls away beneath their feet.
	_release_player()
	var crumble_t: float = _eff_crumble_duration()
	var drop_target_y: float = _deck_base_position.y - _eff_crumble_drop()
	# Snap deck back to base before tweening — shake left it at a random
	# offset; if we don't, the QUAD curve starts from the wrong spot.
	_deck.position = _deck_base_position
	if _tween != null and _tween.is_valid():
		_tween.kill()
	_tween = create_tween()
	_tween.set_parallel(true)
	_tween.tween_property(_deck, ^"position:y", drop_target_y, crumble_t) \
		.set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_IN)
	_tween.tween_method(_set_glitch_progress, 0.0, 1.0, crumble_t * 0.85)
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
	# Defensive: evict anything still parented under Deck before snapping it
	# back to base. If a body slipped through (e.g. body_exited didn't fire
	# because they fell straight down and never crossed the carry-zone edge),
	# the position snap would teleport them up by `crumble_drop` meters.
	for child in _deck.get_children():
		if child == _box:
			continue
		if child is Node3D:
			child.reparent(get_tree().current_scene, true)
	_deck.position = _deck_base_position
	_box.visible = true
	_box.use_collision = true
	_set_glitch_progress(0.0)
	_carried_body = null
	_original_parent = null


func _release_player() -> void:
	if _carried_body == null or not is_instance_valid(_carried_body):
		_carried_body = null
		_original_parent = null
		return
	if _carried_body.get_parent() != _deck:
		# Already not parented under us (someone else moved them, or the
		# initial deferred reparent never landed). Just clear bookkeeping.
		_carried_body = null
		_original_parent = null
		return
	if _original_parent == null or not is_instance_valid(_original_parent):
		_carried_body = null
		_original_parent = null
		return
	# Direct (non-deferred) reparent: this runs from tween callbacks or
	# body_exited (post-physics), so it's safe — and we need it to land
	# *now* so the next tween step doesn't move the deck while the player
	# is still inheriting its transform.
	_carried_body.reparent(_original_parent, true)
	_carried_body = null
	_original_parent = null


func _set_glitch_progress(v: float) -> void:
	if _glitch_overlay != null:
		_glitch_overlay.set_shader_parameter(&"glitch_progress", v)


func _apply_palette() -> void:
	if _material == null:
		return
	_material.set_shader_parameter(&"palette_black", palette_base)
	_material.set_shader_parameter(&"palette_purple", palette_highlight)


func _apply_size() -> void:
	if _box != null:
		_box.size = size
	if _carry_shape != null and _carry_shape.shape is BoxShape3D:
		var carry_box: BoxShape3D = _carry_shape.shape as BoxShape3D
		carry_box.size = Vector3(size.x, 0.6, size.z)
		_carry_shape.position.y = size.y * 0.5 + 0.3


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
