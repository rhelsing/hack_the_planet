extends CSGBox3D

## Procedural city backdrop. Generates a MultiMeshInstance3D filled with
## variable-height building blocks across the parent's footprint, skipping
## the play area around the hub center. One draw call for all instances.
## "Instance pooling" via MultiMesh — no per-building Node3D overhead.

@export var building_material: ShaderMaterial = preload("res://level/buildings.tres")
@export var instance_count: int = 600
## Footprint of each building block (X×Z). Y scale is randomized per instance.
@export var building_footprint: Vector2 = Vector2(6.0, 6.0)
@export var height_range: Vector2 = Vector2(8.0, 70.0)
## Buildings within this rectangle (parent-local XZ) are skipped — keeps the
## city out of the actual play area around the platforms / pedestals.
@export var play_area_min: Vector2 = Vector2(-40.0, -50.0)
@export var play_area_max: Vector2 = Vector2(40.0, 40.0)
@export var ground_y_offset: float = 0.02
@export var rng_seed: int = 1337


func _ready() -> void:
	var mmi := MultiMeshInstance3D.new()
	mmi.name = "CityMultiMesh"
	add_child(mmi)

	var box := BoxMesh.new()
	box.size = Vector3.ONE  # scaled per-instance via the per-instance basis

	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.mesh = box
	mm.instance_count = instance_count
	mmi.multimesh = mm
	mmi.material_override = building_material

	# Top surface of this CSGBox3D in PARENT-local terms (the script's transform
	# is what positions the slab; local y=0 is the slab's center, top is +half).
	var ground_top_local: float = size.y * 0.5
	# Footprint span — buildings live within ±half_extent in X/Z.
	var half_x: float = size.x * 0.5 - building_footprint.x
	var half_z: float = size.z * 0.5 - building_footprint.y

	var rng := RandomNumberGenerator.new()
	rng.seed = rng_seed

	var placed: int = 0
	var attempts: int = 0
	var max_attempts: int = instance_count * 4
	while placed < instance_count and attempts < max_attempts:
		attempts += 1
		var x: float = rng.randf_range(-half_x, half_x)
		var z: float = rng.randf_range(-half_z, half_z)
		# Skip the central play area so we don't wall the player in.
		if x >= play_area_min.x and x <= play_area_max.x \
				and z >= play_area_min.y and z <= play_area_max.y:
			continue
		var height: float = rng.randf_range(height_range.x, height_range.y)
		# Place base 0.02 above the slab's top, scale extends upward.
		var y: float = ground_top_local + ground_y_offset + height * 0.5
		var basis := Basis.IDENTITY.scaled(Vector3(building_footprint.x, height, building_footprint.y))
		mm.set_instance_transform(placed, Transform3D(basis, Vector3(x, y, z)))
		placed += 1
	# If we bailed early (couldn't fit instance_count outside the play area),
	# trim so unfilled slots don't render at the origin.
	if placed < instance_count:
		mm.instance_count = placed
