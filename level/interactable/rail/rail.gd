@tool
class_name Rail extends Path3D


## Padding (m) added around the curve's baked bounding box when sizing
## the detection Area3D. Larger = easier to snap onto the rail; smaller
## requires the player to be right on top of it.
@export var grab_pad: float = 1.2


func _ready() -> void:
	if Engine.is_editor_hint():
		return
	# Group registration so city_builder.gd can find every rail in the level
	# and steer procedural buildings away from their curves.
	add_to_group(&"rail")
	var area: Area3D = get_node_or_null("Area3D")
	if area != null:
		area.body_entered.connect(_on_body_entered)
	_fit_area_to_curve()


func _on_body_entered(body: Node3D) -> void:
	Events.rail_touched.emit(self, body)


func closest_progress(world_pos: Vector3) -> float:
	return curve.get_closest_offset(to_local(world_pos))


## Auto-size the detection Area3D to enclose the entire curve plus a pad.
func _fit_area_to_curve() -> void:
	if curve == null or curve.point_count < 2:
		return
	var col: CollisionShape3D = get_node_or_null("Area3D/CollisionShape3D") as CollisionShape3D
	if col == null:
		return
	var points: PackedVector3Array = curve.get_baked_points()
	if points.size() == 0:
		return
	var min_p := points[0]
	var max_p := points[0]
	for p in points:
		min_p = min_p.min(p)
		max_p = max_p.max(p)
	var pad := grab_pad
	var center: Vector3 = (min_p + max_p) * 0.5
	var size: Vector3 = (max_p - min_p) + Vector3.ONE * (pad * 2.0)
	# BoxShape3D can't have a zero extent along any axis.
	size.x = maxf(size.x, 0.2)
	size.y = maxf(size.y, 0.2)
	size.z = maxf(size.z, 0.2)
	var shape := BoxShape3D.new()
	shape.size = size
	col.shape = shape
	col.position = center
