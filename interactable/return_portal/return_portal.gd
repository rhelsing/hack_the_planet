class_name ReturnPortal
extends Interactable

## Press-E pedestal that warps the player to a target scene (default: hub).
## Uses the same BoxMesh + buildings.tres material as the hub pedestals so it
## reads as part of the same family of scene-jump objects, but skinned in
## L3's magenta as a "level-clear sentinel."
##
## Visibility is gated on `require_flag` — hidden (scale 0, non-monitoring)
## until the flag flips, then pops in with an elastic overshoot. Mirrors
## HubPedestal's reveal pattern.

@export_group("Target")
## Scene path loaded on interact via LevelProgression.goto_path.
@export var target_scene_path: String = "res://level/hub.tscn"

@export_group("Reveal")
## GameState flag that gates visibility + interactivity. Empty = always on.
@export var require_flag: StringName = &""
@export var pop_in_duration: float = 0.45

@export_group("Color")
## Defaults to the L3 PedestalSex magenta. Drives the buildings shader's
## `palette_blue` uniform on a per-instance clone of the shared material.
@export var ready_tint: Color = Color(0.7495762, 0.22929168, 0.9761173, 1.0):
	set(value):
		ready_tint = value
		_refresh_tint()

@onready var _mesh: MeshInstance3D = get_node_or_null(^"Mesh") as MeshInstance3D

var _tinted_material: ShaderMaterial = null
var _was_locked: bool = true


func _ready() -> void:
	super._ready()
	if prompt_verb == "interact":
		prompt_verb = "back to hub"
	_ensure_tinted_material()
	_refresh_tint()
	_was_locked = is_locked()
	_set_interactive(not _was_locked)
	if _was_locked:
		scale = Vector3.ZERO
	if require_flag != &"":
		Events.flag_set.connect(_on_flag_set)


func can_interact(actor: Node3D) -> bool:
	if not super.can_interact(actor):
		return false
	if require_flag != &"" and not bool(GameState.get_flag(require_flag, false)):
		return false
	return true


func interact(_actor: Node3D) -> void:
	if not can_interact(_actor):
		return
	LevelProgression.goto_path(target_scene_path)


func _on_flag_set(id: StringName, _value: Variant) -> void:
	if id != require_flag:
		return
	var locked_now: bool = is_locked()
	if _was_locked and not locked_now:
		_set_interactive(true)
		_pop_in()
	_was_locked = locked_now


func _set_interactive(on: bool) -> void:
	monitoring = on
	monitorable = on


func _pop_in() -> void:
	scale = Vector3.ZERO
	var tw := create_tween()
	tw.tween_property(self, "scale", Vector3.ONE, pop_in_duration) \
		.set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)


# Duplicate the shared buildings material so per-instance tweaks don't leak
# into every other mesh in the project that uses buildings.tres.
func _ensure_tinted_material() -> void:
	if _mesh == null or _tinted_material != null:
		return
	var shared: ShaderMaterial = _mesh.material_override as ShaderMaterial
	if shared == null:
		return
	_tinted_material = shared.duplicate() as ShaderMaterial
	_mesh.material_override = _tinted_material


func _refresh_tint() -> void:
	if _tinted_material == null:
		return
	_tinted_material.set_shader_parameter(&"palette_blue", ready_tint)
