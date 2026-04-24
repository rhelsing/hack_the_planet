class_name HubPedestal
extends Interactable

## Press-E pedestal in the hub. Interact launches a specific level via
## LevelProgression.goto_level(). Gated on the previous level being complete;
## locks otherwise (interact is no-op, UI shows "locked"). Glows green once
## that level itself has been completed.

## 1..4. Which level this pedestal launches.
@export var level_num: int = 1

## If true, the pedestal shows a green tint material when `level_N_completed`
## is set. Always-on visual feedback without needing any player interaction.
@export var show_complete_tint: bool = true

@onready var _mesh: MeshInstance3D = get_node_or_null(^"Mesh") as MeshInstance3D
@onready var _label: Label3D = get_node_or_null(^"Label") as Label3D

const _TINT_COMPLETE: Color = Color(0.25, 1.0, 0.35, 1.0)
const _TINT_LOCKED: Color = Color(0.45, 0.15, 0.15, 1.0)
const _TINT_READY: Color = Color(1.0, 0.84, 0.3, 1.0)


func _ready() -> void:
	super._ready()
	if prompt_verb == "interact":
		prompt_verb = "enter"
	if _label != null:
		_label.text = "LEVEL %d" % level_num
	Events.flag_set.connect(_on_flag_set)
	_refresh_tint()


func can_interact(_actor: Node3D) -> bool:
	if level_num > 1 and not LevelProgression.is_level_complete(level_num - 1):
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
	_refresh_tint()


func _refresh_tint() -> void:
	if _mesh == null:
		return
	var mat: StandardMaterial3D = _mesh.get_surface_override_material(0)
	if mat == null:
		mat = StandardMaterial3D.new()
		_mesh.set_surface_override_material(0, mat)
	var tint: Color = _TINT_READY
	if is_locked():
		tint = _TINT_LOCKED
	elif show_complete_tint and LevelProgression.is_level_complete(level_num):
		tint = _TINT_COMPLETE
	mat.albedo_color = tint
	mat.emission_enabled = true
	mat.emission = tint
	mat.emission_energy_multiplier = 0.5
