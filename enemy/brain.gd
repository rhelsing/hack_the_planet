class_name EnemyBrain extends Node


## Override in subclasses. Return the desired horizontal velocity (m/s) in
## world space. The Enemy applies gravity on top; the brain only controls XZ
## motion and its magnitude. Return Vector3.ZERO to stand still.
func think(_enemy: Enemy, _delta: float) -> Vector3:
	return Vector3.ZERO
