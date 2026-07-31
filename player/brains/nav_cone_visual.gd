class_name NavConeVisual
extends Node3D

## Vision-cone renderer — LOOK layer (docs/nav_stack.md + parity plan §8).
## Drop as a child of any pawn whose brain is a NavBrain; it draws the
## brain's REAL detection cone (arc + range come from perception_view(), so
## the picture can never drift from the truth) with the legacy presentation
## the old brain's built-in fan had:
##   • per-slice wall clipping — the fan stops at cover, at the same eye
##     height the brain's LOS ray uses, so low crates block it visibly
##   • smooth lerp_angle swivel toward the brain's facing
##   • apex→rim radial alpha fade, suspicion-blended color
##   • crouch shrink for free (the view reports stance-effective numbers)
##     plus the fluorescent ignition flicker on the target crouching
##   • hack flicker-out: stochastic dropout on a (1 - progress) envelope
##
## STRICTLY READ-ONLY: it consumes `NavBrain.perception_view()` and casts
## physics ray READS; it writes nothing back, so adding/removing/toggling
## it cannot affect behavior by construction. Portable to any game using
## the stack.

enum VisibleMode { ALWAYS, WHEN_SUSPICIOUS, NEVER }

## When the cone renders. WHEN_SUSPICIOUS = appears once suspicion > 0.
@export var visible_mode: VisibleMode = VisibleMode.ALWAYS
@export var calm_color: Color = Color(0.0, 0.85, 0.0)
@export var suspect_color: Color = Color(0.95, 0.85, 0.0)
@export var hostile_color: Color = Color(0.95, 0.0, 0.0)
## Blend color continuously with the suspicion accumulator (calm→suspect→
## hostile). Off = hard color per state.
@export var suspicion_lerp: bool = true
@export_range(0.05, 1.0) var opacity: float = 0.35
## Draw radius as a fraction of the real detection range. 1.0 = truth-size
## (the fan honestly shows what the pawn can see — parity plan §9).
@export_range(0.1, 1.0) var radius_scale: float = 1.0
## Seconds for the fan to swivel toward the brain's facing (exponential
## smoothing; 0 = instant snap). ~0.15 reads natural for patrol AI — the
## legacy vision_swivel_smoothing value.
@export_range(0.0, 1.0) var swivel_smoothing: float = 0.15
## Fan slices — one wall-clip ray per slice boundary. 16 matches the
## legacy fan's cost and look.
@export_range(6, 64) var segments: int = 16
## Beyond this camera distance (m) the fan hides and casts NO rays (perf
## guard, review R8). 0 = never cull.
@export var max_draw_distance: float = 60.0

# Crouch-entry fluorescent flicker: [alpha, duration] steps, played once,
# then steady on. Ported verbatim from the legacy brain — reads as a tube
# struggling to ignite.
const _CROUCH_FLICKER_PATTERN: Array = [
	[1.0, 0.05], [0.0, 0.05], [1.0, 0.04], [0.0, 0.08],
	[1.0, 0.06], [0.0, 0.03], [1.0, 0.10], [0.0, 0.04],
]
const _FLICKER_DEBOUNCE_SEC: float = 1.0
## 360° isn't a cone — hide rather than draw a full-map disc (covers pawns
## converted off stealth, whose cone_deg is poked to 360; the legacy brain
## freed its fan on conversion).
const _OMNI_HIDE_DEG: float = 359.0

var _brain: NavBrain = null
var _mesh_instance: MeshInstance3D = null
var _mesh: ImmediateMesh = null
var _exclude_rids: Array[RID] = []
var _yaw: float = 0.0
var _yaw_seeded: bool = false
var _warned: bool = false
# Flicker playback + crouch edge state.
var _flicker_pattern: Array = []
var _flicker_index: int = 0
var _flicker_step_timer: float = 0.0
var _last_flicker_started_at: float = -1000.0
var _was_crouched_view: bool = false


func _ready() -> void:
	# Deferred: the parent body swaps in its brain_scene override during ITS
	# _ready, which runs after this child's — resolve after that happened.
	_resolve_brain.call_deferred()
	# World-anchored like the legacy fan (top_level): immune to any parent
	# transform; yaw is baked into slice vertices, node rotation stays
	# identity, position is written each physics tick.
	top_level = true
	var mat := StandardMaterial3D.new()
	# Per-vertex RGBA carries the color (apex full, rim ~1% — radial fade);
	# the material is a white passthrough. DEPTH_PRE_PASS lets opaque walls
	# correctly occlude the translucent fan (plain alpha bleeds through).
	mat.albedo_color = Color(1, 1, 1, 1)
	mat.vertex_color_use_as_albedo = true
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA_DEPTH_PRE_PASS
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	_mesh = ImmediateMesh.new()
	_mesh_instance = MeshInstance3D.new()
	_mesh_instance.mesh = _mesh
	_mesh_instance.material_override = mat
	_mesh_instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(_mesh_instance)
	var parent := get_parent()
	if parent is CollisionObject3D:
		_exclude_rids.append((parent as CollisionObject3D).get_rid())


func _resolve_brain() -> void:
	for c: Node in get_parent().get_children():
		if c is NavBrain:
			_brain = c
			return
	if not _warned:
		_warned = true
		push_warning("NavConeVisual %s: no NavBrain sibling — nothing to draw" % get_path())


## PlayerBody.replace_brain broadcasts this after a runtime brain swap —
## the cached ref dies with the old node.
func rewire_brain(brain: Node) -> void:
	_brain = brain as NavBrain


# Physics-tick update: direct-space raycasts belong here, and the legacy
# fan rebuilt at exactly this cadence.
func _physics_process(delta: float) -> void:
	if _brain == null or not is_instance_valid(_brain):
		_brain = null
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
	var cone_deg: float = view.cone_deg
	if cone_deg >= _OMNI_HIDE_DEG:
		visible = false
		return
	var parent := get_parent() as Node3D
	if parent == null:
		visible = false
		return
	var eye_height: float = float(view.get("eye_height", 1.0))
	global_position = parent.global_position + Vector3.UP * eye_height
	if max_draw_distance > 0.0:
		var cam := get_viewport().get_camera_3d() if is_inside_tree() else null
		if cam != null and cam.global_position.distance_to(global_position) > max_draw_distance:
			visible = false
			return
	visible = true

	# Smooth swivel toward the brain's facing (stare/scan lock included —
	# the brain owns facing; we only ease the picture toward it).
	var facing: Vector3 = view.facing
	var target_yaw: float = atan2(facing.x, facing.z)
	if not _yaw_seeded or swivel_smoothing <= 0.0:
		_yaw_seeded = true
		_yaw = target_yaw
	else:
		_yaw = lerp_angle(_yaw, target_yaw, 1.0 - exp(-delta / swivel_smoothing))

	var alpha_mult: float = _advance_alpha(view, delta)
	var color: Color = _color_for(suspicion, view.suspect_threshold, view.state)
	_rebuild_fan(view, cone_deg, float(view.range) * radius_scale,
		eye_height, color, alpha_mult)


## Suspicion → color, same mapping the tint listener uses.
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


# Per-tick alpha multiplier: hack envelope > crouch flicker > steady 1.0.
# Presentation only — the brain just reports hack_active/hack_progress.
func _advance_alpha(view: Dictionary, delta: float) -> float:
	if bool(view.get("hack_active", false)):
		# Dying signal losing power as the hack drains it: ~35% chance per
		# tick to black out, otherwise sit at the (1 - progress) envelope.
		_flicker_pattern.clear()
		var p: float = float(view.get("hack_progress", 0.0))
		if p >= 1.0:
			return 0.0
		return 0.0 if randf() < 0.35 else 1.0 - p
	# Crouch edge → start the ignition flicker (debounced so rapid crouch
	# toggling snaps to ON instead of restarting the pattern).
	var crouched: bool = bool(view.get("target_crouched", false))
	if crouched and not _was_crouched_view:
		var t: float = Time.get_ticks_msec() / 1000.0
		if t - _last_flicker_started_at >= _FLICKER_DEBOUNCE_SEC:
			_last_flicker_started_at = t
			_flicker_pattern = _CROUCH_FLICKER_PATTERN.duplicate()
			_flicker_index = 0
			_flicker_step_timer = float((_flicker_pattern[0] as Array)[1])
		else:
			_flicker_pattern.clear()
	_was_crouched_view = crouched
	if _flicker_pattern.is_empty():
		return 1.0
	_flicker_step_timer -= delta
	if _flicker_step_timer <= 0.0:
		_flicker_index += 1
		if _flicker_index >= _flicker_pattern.size():
			_flicker_pattern.clear()
			return 1.0
		_flicker_step_timer = float((_flicker_pattern[_flicker_index] as Array)[1])
	return float((_flicker_pattern[_flicker_index] as Array)[0])


## Wall-clipped triangle fan: one ray per slice boundary from the eye,
## clipped at its first hit; each triangle reaches its slices' clipped
## distances. Per-vertex color: apex at full phase alpha × alpha_mult, rim
## at 1% — the legacy radial fade.
func _rebuild_fan(_view: Dictionary, cone_deg: float, radius: float,
		eye_height: float, color: Color, alpha_mult: float) -> void:
	_mesh.clear_surfaces()
	if radius <= 0.1 or alpha_mult <= 0.001:
		return
	var n: int = segments + 1
	var half: float = deg_to_rad(clampf(cone_deg, 1.0, 359.0)) * 0.5
	var step: float = (2.0 * half) / float(segments)
	var dists := PackedFloat32Array()
	dists.resize(n)
	var space: PhysicsDirectSpaceState3D = null
	if is_inside_tree():
		space = get_world_3d().direct_space_state
	var origin: Vector3 = global_position  # node already sits at eye height
	for i in n:
		var a: float = _yaw + (-half + step * float(i))
		var dir := Vector3(sin(a), 0.0, cos(a))
		if space == null:
			dists[i] = radius
			continue
		var query := PhysicsRayQueryParameters3D.create(origin, origin + dir * radius)
		query.exclude = _exclude_rids
		var hit := space.intersect_ray(query)
		dists[i] = radius if hit.is_empty() else origin.distance_to(hit.position as Vector3)
	var apex_color := Color(color.r, color.g, color.b, color.a * alpha_mult)
	var rim_color := Color(color.r, color.g, color.b, color.a * 0.01 * alpha_mult)
	_mesh.surface_begin(Mesh.PRIMITIVE_TRIANGLES)
	for i in segments:
		var a0: float = _yaw + (-half + step * float(i))
		var a1: float = _yaw + (-half + step * float(i + 1))
		var p0 := Vector3(sin(a0), 0.0, cos(a0)) * dists[i]
		var p1 := Vector3(sin(a1), 0.0, cos(a1)) * dists[i + 1]
		_mesh.surface_set_color(apex_color)
		_mesh.surface_add_vertex(Vector3.ZERO)
		_mesh.surface_set_color(rim_color)
		_mesh.surface_add_vertex(p0)
		_mesh.surface_set_color(rim_color)
		_mesh.surface_add_vertex(p1)
	_mesh.surface_end()
