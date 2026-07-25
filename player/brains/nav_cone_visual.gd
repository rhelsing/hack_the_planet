class_name NavConeVisual
extends Node3D

## Optional, tunable vision-cone renderer — LOOK layer (docs/nav_stack.md).
## Drop as a child of any pawn whose brain is a NavBrain; it draws the
## brain's real detection cone (arc + range come from perception config, so
## the picture can never drift from the truth) and colors it by suspicion.
##
## STRICTLY READ-ONLY: it consumes `NavBrain.perception_view()` and writes
## nothing back, so adding/removing/toggling it cannot affect behavior by
## construction. Portable to any game using the stack.

enum VisibleMode { ALWAYS, WHEN_SUSPICIOUS, NEVER }

## When the cone renders. WHEN_SUSPICIOUS = fades in once suspicion > 0.
@export var visible_mode: VisibleMode = VisibleMode.ALWAYS
@export var calm_color: Color = Color(0.3, 0.8, 1.0)
@export var suspect_color: Color = Color(1.0, 0.75, 0.1)
@export var hostile_color: Color = Color(1.0, 0.15, 0.1)
## Blend color continuously with the suspicion accumulator (calm→suspect→
## hostile). Off = hard color per state.
@export var suspicion_lerp: bool = true
@export_range(0.05, 1.0) var opacity: float = 0.3
## Draw radius as a fraction of the real detection range (1.0 = true size —
## long cones can dominate the screen; tune down for readability).
@export_range(0.1, 1.0) var radius_scale: float = 1.0
## Height above the pawn's feet the fan is drawn at.
@export var draw_height: float = 0.15
@export_range(6, 64) var segments: int = 24

var _brain: NavBrain = null
var _mesh_instance: MeshInstance3D = null
var _material: StandardMaterial3D = null
var _built_cone_deg: float = -1.0
var _built_range: float = -1.0
var _warned: bool = false


func _ready() -> void:
	# Deferred: the parent body swaps in its brain_scene override during ITS
	# _ready, which runs after this child's — resolve after that happened.
	_resolve_brain.call_deferred()
	_material = StandardMaterial3D.new()
	_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	_material.cull_mode = BaseMaterial3D.CULL_DISABLED
	_material.no_depth_test = false
	_mesh_instance = MeshInstance3D.new()
	_mesh_instance.material_override = _material
	_mesh_instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(_mesh_instance)


func _resolve_brain() -> void:
	for c: Node in get_parent().get_children():
		if c is NavBrain:
			_brain = c
			return
	if not _warned:
		_warned = true
		push_warning("NavConeVisual %s: no NavBrain sibling — nothing to draw" % get_path())


func _process(_delta: float) -> void:
	if _brain == null:
		visible = false
		return
	if visible_mode == VisibleMode.NEVER:
		visible = false
		return
	var view: Dictionary = _brain.perception_view()
	var suspicion: float = view.suspicion
	if visible_mode == VisibleMode.WHEN_SUSPICIOUS and suspicion <= 0.02:
		visible = false
		return
	visible = true
	var cone_deg: float = view.cone_deg
	var draw_range: float = float(view.range) * radius_scale
	if absf(cone_deg - _built_cone_deg) > 0.5 or absf(draw_range - _built_range) > 0.1:
		_rebuild_fan(cone_deg, draw_range)
	var facing: Vector3 = view.facing
	rotation.y = atan2(facing.x, facing.z)
	position.y = draw_height
	_material.albedo_color = _color_for(suspicion, view.suspect_threshold, view.state)


func _color_for(suspicion: float, threshold: float, state: StringName) -> Color:
	var c: Color
	if suspicion_lerp:
		if suspicion < threshold:
			c = calm_color.lerp(suspect_color, suspicion / maxf(threshold, 0.001))
		else:
			c = suspect_color.lerp(hostile_color,
				(suspicion - threshold) / maxf(1.0 - threshold, 0.001))
	else:
		match state:
			&"CHASE", &"WIND_UP": c = hostile_color
			&"SUSPECT": c = suspect_color
			_: c = calm_color
	c.a = opacity
	return c


## Triangle fan in the XZ plane, apex at origin, opening along +Z (yaw 0 in
## the body's facing convention). 360° builds a full disc.
func _rebuild_fan(cone_deg: float, radius: float) -> void:
	_built_cone_deg = cone_deg
	_built_range = radius
	var arc: float = deg_to_rad(clampf(cone_deg, 1.0, 360.0))
	var verts := PackedVector3Array()
	var indices := PackedInt32Array()
	verts.append(Vector3.ZERO)
	for i in segments + 1:
		var a: float = -arc * 0.5 + arc * float(i) / float(segments)
		verts.append(Vector3(sin(a) * radius, 0.0, cos(a) * radius))
	for i in segments:
		indices.append_array([0, i + 1, i + 2])
	var arrays: Array = []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_INDEX] = indices
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	_mesh_instance.mesh = mesh
