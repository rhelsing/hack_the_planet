class_name HubPedestal
extends Interactable

## Press-E pedestal in the hub. Interact launches a specific level via
## LevelProgression.goto_level(). Gated on the previous level being complete;
## hidden (scale 0) until unlocked, then pops in with an elastic overshoot.

## 1..4. Which level this pedestal launches.
@export var level_num: int = 1

## If true, the pedestal swaps to a green tint material when `level_N_completed`
## is set. Default OFF — completed pedestals keep their per-level `ready_tint`
## (love/secret/sex/god) so the hub reads as a palette of distinct portals
## rather than a row of green "done" markers. Flip on if you want the green
## completion indicator back.
@export var show_complete_tint: bool = false

## Per-pedestal tint when unlocked + not yet completed. Pick in inspector so
## each level has a visual signature (love / secret / sex / god). Drives the
## buildings shader's `palette_blue` uniform on a per-pedestal clone of the
## shared material.
@export var ready_tint: Color = Color(1.0, 0.84, 0.3, 1.0)

## Seconds for the scale pop-in. TRANS_BACK ease-out gives a single overshoot.
@export var pop_in_duration: float = 0.45

## Optional extra unlock gate. If non-empty, the pedestal stays locked until
## GameState.flags[require_flag] is true — regardless of level completion
## state. Used for PedestalLove to gate Level 1 behind DialTone's intro.
@export var require_flag: StringName = &""

@onready var _mesh: MeshInstance3D = get_node_or_null(^"Mesh") as MeshInstance3D

const _TINT_COMPLETE: Color = Color(0.25, 1.0, 0.35, 1.0)
const _TINT_LOCKED: Color = Color(0.45, 0.15, 0.15, 1.0)

var _was_locked: bool = true
var _tinted_material: ShaderMaterial


func _ready() -> void:
	super._ready()
	if prompt_verb == "interact":
		prompt_verb = "enter"
	Events.flag_set.connect(_on_flag_set)
	scale = Vector3.ZERO
	_was_locked = is_locked()
	_ensure_tinted_material()
	_refresh_tint()
	# While locked the pedestal is scale=0 and not meant to be discovered —
	# stop the Area3D from firing any interact/prompt signals.
	_set_interactive(not _was_locked)
	if not _was_locked:
		_pop_in()


func can_interact(_actor: Node3D) -> bool:
	if level_num > 1 and not LevelProgression.is_level_complete(level_num - 1):
		return false
	if require_flag != &"" and not bool(GameState.get_flag(require_flag, false)):
		return false
	return true


func is_locked() -> bool:
	return not can_interact(null)


func describe_lock() -> String:
	if is_locked():
		return "Locked — clear Level %d first" % (level_num - 1)
	return ""


func interact(_actor: Node3D) -> void:
	if not can_interact(_actor):
		return
	LevelProgression.goto_level(level_num)


func _on_flag_set(_id: StringName, _value: Variant) -> void:
	var locked_now: bool = is_locked()
	if _was_locked and not locked_now:
		_set_interactive(true)
		_pop_in()
		# Live "portal-just-appeared" cue. Plays warp7 exclusively (the
		# stream was removed from the level-warp `teleport` cue rotation
		# so this beat is unmistakable). Only fired on the locked→unlocked
		# transition — NOT on the `_ready`-side _pop_in for save-restore,
		# where the player loaded into a hub that already had the pedestal
		# revealed and shouldn't hear a fresh appearance sting.
		Audio.play_sfx(&"portal_appear")
	_was_locked = locked_now
	_refresh_tint()


func _set_interactive(on: bool) -> void:
	monitoring = on
	monitorable = on


func _pop_in() -> void:
	scale = Vector3.ZERO
	var tw := create_tween()
	tw.tween_property(self, "scale", Vector3.ONE, pop_in_duration) \
		.set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)


# Duplicate the shared buildings material so per-pedestal palette_blue tweaks
# don't leak into every other mesh in the project that uses buildings.tres.
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
	var tint: Color = ready_tint
	if is_locked():
		tint = _TINT_LOCKED
	elif show_complete_tint and LevelProgression.is_level_complete(level_num):
		tint = _TINT_COMPLETE
	_tinted_material.set_shader_parameter(&"palette_blue", tint)
