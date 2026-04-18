@tool
class_name WaterSurface extends MeshInstance3D

## Triangulates `points` (XZ polygon) into a flat mesh on the XZ plane so the
## water shader has UVs + tangents to work with. Edit `points` in the
## inspector to reshape the surface — regenerates automatically in editor
## and at runtime.

@export var points: PackedVector2Array = PackedVector2Array([
		Vector2(-2.5, -2.5),
		Vector2(2.5, -2.5),
		Vector2(2.5, 2.5),
		Vector2(-2.5, 2.5),
	]):
	set(value):
		points = value
		_rebuild()


func _ready() -> void:
	_rebuild()


func _rebuild() -> void:
	if points.size() < 3:
		mesh = null
		return
	var tris := Geometry2D.triangulate_polygon(points)
	if tris.is_empty():
		return

	# UVs use the polygon's XZ bounding box so the normal-map tiling looks
	# consistent regardless of shape.
	var min_p := points[0]
	var max_p := points[0]
	for p: Vector2 in points:
		min_p.x = minf(min_p.x, p.x)
		min_p.y = minf(min_p.y, p.y)
		max_p.x = maxf(max_p.x, p.x)
		max_p.y = maxf(max_p.y, p.y)
	var size := max_p - min_p
	if size.x <= 0.0 or size.y <= 0.0:
		return

	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)

	# Triangulate in CCW order when viewed from +Y — flip each triangle's
	# winding if it comes out facing down.
	for i in range(0, tris.size(), 3):
		var a: Vector2 = points[tris[i]]
		var b: Vector2 = points[tris[i + 1]]
		var c: Vector2 = points[tris[i + 2]]
		var cross := (b.x - a.x) * (c.y - a.y) - (b.y - a.y) * (c.x - a.x)
		var order: Array[int] = [tris[i], tris[i + 1], tris[i + 2]]
		if cross < 0.0:
			order = [tris[i], tris[i + 2], tris[i + 1]]
		for idx: int in order:
			var p: Vector2 = points[idx]
			st.set_normal(Vector3.UP)
			st.set_uv((p - min_p) / size)
			st.add_vertex(Vector3(p.x, 0.0, p.y))

	st.generate_tangents()
	mesh = st.commit()
