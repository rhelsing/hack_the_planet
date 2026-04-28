extends Node

## Runtime CSG-collider swap. At _ready, walks the scene tree starting at our
## parent and replaces the auto-generated trimesh collision on simple
## CSGBox3D nodes with primitive BoxShape3D collision on a sibling
## StaticBody3D. Primitive box collision is dramatically cheaper for
## physics queries than CSG's triangle-soup auto-mesh.
##
## Skipped (left with their original collision):
##   - CSGBox3D whose parent is another CSGShape3D — they're operands of
##     a boolean op handled by their root.
##   - CSGBox3D that has a CSGShape3D child — the boolean op changes the
##     resulting collision shape away from a plain box.
##   - All non-Box CSG types (Combiner, Polygon, Sphere, etc.).
##
## A box CSG with no CSG ancestors AND no CSG descendants is geometrically
## identical to a BoxShape3D of the same size + transform, so the swap is
## exact — no gameplay change.

@export var verbose: bool = true


func _ready() -> void:
	var parent := get_parent()
	if parent == null:
		return
	var swapped := _swap_recursive(parent)
	if verbose:
		print("[csg_collider_swap] replaced %d CSGBox3D colliders" % swapped)


func _swap_recursive(node: Node) -> int:
	var count := 0
	# Snapshot children before iterating — _swap_one adds a sibling node
	# which would otherwise shift indices mid-iteration.
	var children := node.get_children()
	for child: Node in children:
		count += _swap_recursive(child)
	if node is CSGBox3D and _should_swap(node as CSGBox3D):
		_swap_one(node as CSGBox3D)
		count += 1
	return count


func _should_swap(box: CSGBox3D) -> bool:
	if not box.use_collision:
		return false
	if box.get_parent() is CSGShape3D:
		return false
	for c: Node in box.get_children():
		if c is CSGShape3D:
			return false
	return true


func _swap_one(box: CSGBox3D) -> void:
	box.use_collision = false
	var body := StaticBody3D.new()
	body.collision_layer = box.collision_layer
	body.collision_mask = box.collision_mask
	var shape := CollisionShape3D.new()
	var box_shape := BoxShape3D.new()
	box_shape.size = box.size
	shape.shape = box_shape
	body.add_child(shape)
	# Add as a CHILD of the CSG (not sibling) so it inherits the CSG's world
	# transform automatically — no need to copy global_transform, and avoids
	# the "parent busy setting up children" error from add_sibling during the
	# scene's initial _ready cascade.
	box.add_child(body)
