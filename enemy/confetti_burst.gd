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


## Replace the per-particle mesh material so the burst reads as glitch debris
## instead of party confetti. Used by skins that own a glitch death effect
## (KayKit). Safe to call before the node enters the tree.
func set_overlay_material(material: ShaderMaterial) -> void:
	if material == null or draw_pass_1 == null:
		return
	var dup_mesh: Mesh = draw_pass_1.duplicate() as Mesh
	dup_mesh.surface_set_material(0, material)
	draw_pass_1 = dup_mesh
