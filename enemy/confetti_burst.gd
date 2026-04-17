extends GPUParticles3D


func _ready() -> void:
	finished.connect(queue_free)


## Aim the confetti cone along `direction`. Safe to call before the node enters
## the tree; the material is duplicated so each burst aims independently.
func set_direction(direction: Vector3) -> void:
	if direction.length_squared() < 0.0001:
		return
	var mat := (process_material as ParticleProcessMaterial).duplicate() as ParticleProcessMaterial
	mat.direction = direction.normalized()
	process_material = mat
