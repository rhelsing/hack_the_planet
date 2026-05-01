extends GPUParticles3D
class_name FloatingMotes

## Player-following ambient motes. Emitter chases the player so motes always
## populate the player's vicinity, but `local_coords = false` keeps emitted
## particles in world-space — they drift naturally and are LEFT BEHIND as
## the player moves on. New ones spawn ahead. Result: cheap "fog of small
## things" wrapping the player without filling the whole level volume.
##
## Particle count is quality-tiered via the Settings autoload. Low quality
## disables the system entirely (emitting = false, amount clamped to 1
## because GPUParticles3D requires >= 1).

## Group to follow. Defaults to the player's group.
@export var follow_target_group: StringName = &"player"
## Meters ahead of the player to center the emission box. Use the camera's
## horizontal forward, so motes appear in the direction the player is facing.
@export var forward_offset: float = 5.0
## Meters above the player to lift the emission box (so motes show in the
## upper-half of the screen, not just at foot level).
@export var height_offset: float = 1.0

@export_group("Quality tiers")
## Particle count at each Settings.graphics.quality preset. 0 disables.
@export var amount_low: int = 20
@export var amount_medium: int = 40
@export var amount_high: int = 80
@export var amount_max: int = 120

var _target: Node3D = null


func _ready() -> void:
	# World-space simulation: once a particle spawns, it stays put while the
	# emitter moves on. Required for the "leave them behind" feel.
	local_coords = false
	_apply_quality()
	if Events.has_signal(&"settings_applied"):
		Events.settings_applied.connect(_apply_quality)


func _process(_delta: float) -> void:
	if _target == null or not is_instance_valid(_target):
		_target = get_tree().get_first_node_in_group(follow_target_group) as Node3D
		if _target == null:
			return
	var fwd: Vector3 = _camera_forward_horizontal(_target)
	if fwd.length_squared() < 0.0001:
		fwd = Vector3.FORWARD
	global_position = (
		_target.global_position
		+ fwd * forward_offset
		+ Vector3.UP * height_offset
	)


func _apply_quality(_args: Variant = null) -> void:
	# Settings.apply() now fires on every level mount, which means this
	# handler can be triggered AFTER the old level (and this node) has been
	# removed from the tree via remove_child() but BEFORE queue_free completes.
	# get_tree() returns null in that window. Bail gracefully — the new
	# level's own FloatingMotes will pick up the settings on its own _ready.
	if not is_inside_tree():
		return
	var s := get_tree().root.get_node_or_null(^"Settings")
	var q: String = "high"
	if s != null and s.has_method(&"get_value"):
		q = String(s.call(&"get_value", "graphics", "quality", "high"))
	var n: int = amount_high
	match q:
		"low": n = amount_low
		"medium": n = amount_medium
		"high": n = amount_high
		"max": n = amount_max
	if n <= 0:
		emitting = false
		amount = 1  # GPUParticles3D requires amount >= 1
	else:
		amount = n
		emitting = true


# Player rig has CameraPivot child; fall back to the body's own basis if
# the player skin doesn't expose it (AI-driven body, etc.).
func _camera_forward_horizontal(target: Node3D) -> Vector3:
	var pivot := target.get_node_or_null(^"CameraPivot") as Node3D
	var basis_z: Vector3
	if pivot != null:
		basis_z = pivot.global_basis.z
	else:
		basis_z = target.global_basis.z
	var fwd: Vector3 = -basis_z
	fwd.y = 0.0
	if fwd.length_squared() < 0.0001:
		return Vector3.FORWARD
	return fwd.normalized()
