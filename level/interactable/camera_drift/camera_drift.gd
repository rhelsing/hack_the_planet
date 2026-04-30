extends Node
class_name CameraDrift

## Slow camera position lerp + optional rotation aim over a fixed duration.
## Attach as a child of a Camera3D. Caller invokes `start_drift()` to kick
## off the motion; both position lerp and rotation lerp run on _process.
##
## Position: from the camera's authored global_position to `end_position`.
## Rotation: optional. When _progress reaches `rotation_start_progress`,
## the camera starts smoothly aiming at `rotation_target` (a Marker3D or
## any Node3D) using `looking_at`. Rotation tracks the moving camera —
## per-tick recompute, so the look-at stays accurate as position drifts.

## Camera's destination world position. The component lerps from
## start_position (or the camera's authored position if `override_start`
## is false) to this point over `duration`.
@export var end_position: Vector3
## Optional start position. If `override_start` is true, the camera is
## snapped to this point at start_drift; otherwise the camera's authored
## position is used (handy when the editor position doubles as the start).
@export var start_position: Vector3
@export var override_start: bool = false
## Total seconds for the drift. Should match the cutscene's expected
## total duration so the camera is at end_position when the cutscene ends.
@export var duration: float = 30.0
## Optional Node3D the camera lerps its rotation toward — typically a
## Marker3D placed in world space. Empty = no rotation change.
@export var rotation_target: NodePath
## 0..1 — fraction of the position lerp at which the rotation lerp begins.
## 0 = rotate from start, 0.5 = halfway, 1 = no rotation. Rotation
## completes at progress = 1.0.
@export_range(0.0, 1.0) var rotation_start_progress: float = 0.5

var _camera: Camera3D
var _start_position: Vector3
## Captured at the moment the rotation starts so the slerp begins from
## whatever the camera was facing then, not what it was facing at
## drift-start. Lets the camera hold its initial orientation cleanly
## through the pre-rotation phase.
var _rotation_start_basis: Basis
var _running: bool = false
var _elapsed: float = 0.0
var _rotation_active: bool = false


func _ready() -> void:
	_camera = get_parent() as Camera3D
	if _camera == null:
		push_warning("CameraDrift: parent must be Camera3D — %s" % get_path())
	set_process(false)


## Begin the drift. No-ops if already running.
func start_drift() -> void:
	if _camera == null or _running:
		return
	if override_start:
		_camera.global_position = start_position
		_start_position = start_position
	else:
		_start_position = _camera.global_position
	_running = true
	_elapsed = 0.0
	_rotation_active = false
	set_process(true)


## Halts the drift in place. Camera stays at its current position.
func stop_drift() -> void:
	_running = false
	set_process(false)


## Snap to the final transform — used at cutscene end so the camera lands
## at its authored endpoint regardless of how long the scene actually ran.
## Idempotent — calling it after a complete drift is a no-op.
func snap_to_end() -> void:
	if _camera == null: return
	_camera.global_position = end_position
	if not rotation_target.is_empty():
		var rot_target: Node3D = get_node_or_null(rotation_target) as Node3D
		if rot_target != null:
			var look_dir: Vector3 = rot_target.global_position - _camera.global_position
			if look_dir.length_squared() > 0.0001:
				_camera.global_basis = Transform3D.IDENTITY.looking_at(
					look_dir, Vector3.UP
				).basis
	_running = false
	set_process(false)


func _process(delta: float) -> void:
	if not _running:
		return
	_elapsed += delta
	var t: float = clampf(_elapsed / max(duration, 0.0001), 0.0, 1.0)
	_camera.global_position = _start_position.lerp(end_position, t)

	# Rotation phase.
	if not rotation_target.is_empty() and t >= rotation_start_progress:
		var rot_target: Node3D = get_node_or_null(rotation_target) as Node3D
		if rot_target != null:
			if not _rotation_active:
				_rotation_active = true
				_rotation_start_basis = _camera.global_basis
			var rot_t: float = clampf(
				(t - rotation_start_progress) / maxf(0.001, 1.0 - rotation_start_progress),
				0.0, 1.0
			)
			var look_dir: Vector3 = rot_target.global_position - _camera.global_position
			if look_dir.length_squared() > 0.0001:
				var target_basis: Basis = Transform3D.IDENTITY.looking_at(
					rot_target.global_position - _camera.global_position, Vector3.UP
				).basis
				# Slerp via Quaternion for correct rotation interpolation —
				# a linear basis tween distorts orientation mid-arc.
				var start_q := Quaternion(_rotation_start_basis.orthonormalized())
				var end_q := Quaternion(target_basis.orthonormalized())
				_camera.global_basis = Basis(start_q.slerp(end_q, rot_t))

	if t >= 1.0:
		_running = false
		set_process(false)
