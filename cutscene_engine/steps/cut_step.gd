class_name CutStep
extends CutsceneStep

## Hard-cut to a different camera. Instant — no fade, no pan. Use PanStep
## for animated camera movement.

## Path to a Camera3D node, relative to the CutscenePlayer's scene root.
## CutsceneCamera will call make_current() on it.
@export var camera: NodePath
