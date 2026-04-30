extends Node

## Camera control for the cutscene engine. Handles save/restore of the
## gameplay camera, hard cuts to cinematic cameras, and Tween-based pans
## between Marker3D pose nodes.
##
## Tween-based by design (per docs/cutscene_engine.md §10.3). Does NOT
## interact with the project's CameraDrift node — that's a sibling system
## for ambient gameplay-camera motion, not a cutscene primitive.

var _saved_camera: Camera3D = null


# ── Save / restore ───────────────────────────────────────────────────────

## Capture the current viewport camera so we can return to it on cutscene
## end. Called once during cutscene setup. Idempotent — multiple calls
## within a session would each clobber, but the player only calls this
## once per run.
func save_current() -> void:
	_saved_camera = _viewport_camera()


## Re-make the saved camera current. No-op if save_current was never called
## or the saved camera was freed mid-cutscene (level reload, etc.).
func restore() -> void:
	if _saved_camera != null and is_instance_valid(_saved_camera):
		_saved_camera.make_current()
	_saved_camera = null


# ── Cuts + pans ──────────────────────────────────────────────────────────

## Hard-cut to a different camera. Instant.
func cut_to(camera: Camera3D) -> void:
	if camera == null or not is_instance_valid(camera):
		push_warning("CutsceneCamera.cut_to: null/invalid camera")
		return
	camera.make_current()


## Tween `camera`'s global_transform from the `from` marker's pose to the
## `to` marker's pose. Returns when the tween finishes.
##
## The camera is NOT make_current'd here — call cut_to first if needed.
## (Pans are usually applied to the already-current cinematic camera.)
##
## Pause-respecting: the tween is created on the camera node, which is
## PROCESS_MODE_INHERIT (the default for level scenery), so it freezes
## with the tree. If the camera lives somewhere with a different process
## mode, the caller is responsible.
func pan(camera: Camera3D, from: Marker3D, to: Marker3D, duration: float,
		trans: Tween.TransitionType = Tween.TRANS_QUAD,
		ease: Tween.EaseType = Tween.EASE_IN_OUT) -> void:
	if camera == null or from == null or to == null:
		push_warning("CutsceneCamera.pan: null camera/from/to")
		return
	camera.global_transform = from.global_transform
	var tw := camera.create_tween()
	tw.set_trans(trans).set_ease(ease)
	tw.tween_property(camera, "global_transform", to.global_transform, duration)
	await tw.finished


# ── Internals ────────────────────────────────────────────────────────────

func _viewport_camera() -> Camera3D:
	var tree := get_tree()
	if tree == null:
		return null
	var vp := tree.root.get_viewport()
	if vp == null:
		return null
	return vp.get_camera_3d()
