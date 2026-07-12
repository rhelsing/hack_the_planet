class_name GlitchReveal
extends Node

## Drop as a child of a platform instance (PortalPlatform, ControlPortal —
## anything with a Deck/Box CSG and Trigger Area3D). Hides the parent
## platform entirely (visuals + collision + trigger) until `reveal_flag`
## flips true on GameState, then materializes it with the death-glitch
## shader enemies already die with, run in reverse: glitch bands flicker
## up over nothing, the platform fades in underneath, bands clear.
## Collision returns at reveal start; the trigger arms at reveal end.
##
## Collision is snapshot/restore rather than a blind toggle because
## CsgColliderSwap rebuilds CSG collision into a runtime StaticBody3D and
## runs in the same ready cascade as us, in level-dependent order. The
## hide is deferred one frame so it always runs after the whole cascade
## (swap included) and records exactly what it turned off.

## GameState flag that triggers the reveal. Typically set by a `do` line
## in a .dialogue file at the moment the NPC mentions the platform.
@export var reveal_flag: StringName = &""
## Seconds for the full materialize: bands ramp up over the first half,
## the platform fades in throughout, bands clear over the second half.
@export var reveal_duration: float = 1.2

const _GLITCH_SHADER: Shader = preload("res://player/skins/kaykit/death_glitch.gdshader")

var _platform: Node3D = null
var _box: GeometryInstance3D = null
var _overlay: ShaderMaterial = null
var _revealed := false
# Collision state disabled by _hide_platform, restored on reveal.
var _disabled_csg: Array[CSGShape3D] = []
var _disabled_shapes: Array[CollisionShape3D] = []
var _stopped_areas: Array[Area3D] = []


func _ready() -> void:
	_platform = get_parent() as Node3D
	if _platform == null:
		push_error("[glitch_reveal] parent of %s is not a Node3D" % get_path())
		return
	if reveal_flag == &"":
		push_error("[glitch_reveal] reveal_flag not set on %s" % get_path())
		return
	_box = _platform.get_node_or_null(^"Deck/Box") as GeometryInstance3D
	if _box == null:
		push_error("[glitch_reveal] %s has no Deck/Box to reveal" % _platform.name)
	if bool(GameState.get_flag(reveal_flag, false)):
		# Saved game already past the reveal — leave the authored state.
		_revealed = true
		return
	Events.flag_set.connect(_on_flag_set)
	_hide_platform.call_deferred()


func _hide_platform() -> void:
	if _revealed:
		return
	_platform.visible = false
	for csg: Node in _platform.find_children("*", "CSGShape3D", true, false):
		var c := csg as CSGShape3D
		if c.use_collision:
			c.use_collision = false
			_disabled_csg.append(c)
	for shape: Node in _platform.find_children("*", "CollisionShape3D", true, false):
		var s := shape as CollisionShape3D
		if not s.disabled:
			s.disabled = true
			_disabled_shapes.append(s)
	for area: Node in _platform.find_children("*", "Area3D", true, false):
		var a := area as Area3D
		if a.monitoring:
			a.monitoring = false
			_stopped_areas.append(a)
	print("[glitch_reveal] %s hidden until flag %s (csg=%d shapes=%d areas=%d)" % [
		_platform.name, reveal_flag,
		_disabled_csg.size(), _disabled_shapes.size(), _stopped_areas.size()])


func _on_flag_set(id: StringName, value: Variant) -> void:
	if _revealed or id != reveal_flag or not bool(value):
		return
	_revealed = true
	Events.flag_set.disconnect(_on_flag_set)
	_reveal()


func _reveal() -> void:
	print("[glitch_reveal] %s revealing on flag %s" % [_platform.name, reveal_flag])
	for c in _disabled_csg:
		c.use_collision = true
	for s in _disabled_shapes:
		s.disabled = false
	_platform.visible = true
	if _box == null:
		_arm_areas()
		return
	_overlay = ShaderMaterial.new()
	_overlay.shader = _GLITCH_SHADER
	_overlay.set_shader_parameter(&"glitch_progress", 0.0)
	_box.material_overlay = _overlay
	_box.transparency = 1.0
	var half := reveal_duration * 0.5
	var fade := create_tween()
	fade.tween_property(_box, "transparency", 0.0, reveal_duration)
	var bands := create_tween()
	bands.tween_method(_set_band_progress, 0.0, 1.0, half)
	bands.tween_method(_set_band_progress, 1.0, 0.0, reveal_duration - half)
	bands.tween_callback(_finish_reveal)


func _set_band_progress(v: float) -> void:
	_overlay.set_shader_parameter(&"glitch_progress", v)


func _finish_reveal() -> void:
	_box.material_overlay = null
	_overlay = null
	_arm_areas()


func _arm_areas() -> void:
	for a in _stopped_areas:
		a.monitoring = true
