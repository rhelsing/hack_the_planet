class_name PowerupPickup
extends Pickup

## Big gold floppy disk. On collect, sets a GameState flag that enables the
## associated mechanic (Skate / Hack / Grapple / Flare) and shows an install
## toast + how-to panel. Visual is set via the inherited pickup.tscn scene.
##
## See docs/level_progression.md Phases 2-3.

## Which GameState flag to set on collect. One of:
## &"powerup_love", &"powerup_secret", &"powerup_sex", &"powerup_god".
@export var powerup_flag: StringName

## Short word billboarded on the disk face and shown in the install toast.
## E.g. "LOVE", "SECRET", "SEX", "GOD".
@export var powerup_label: String = ""

## One-line caption shown on the how-to panel. E.g. "PRESS R TO SKATE."
@export var howto_caption: String = ""

## Optional per-instance disk visual. If set, replaces the default `disk_mesh`
## child at _ready. If the scene is a master model containing multiple
## `{label} disc` subtrees (e.g., the love_disc_model.glb shipping with
## Love/sex/secret/god discs), the one matching `powerup_label` is kept and
## the rest are freed. Empty = the default floppy in powerup_pickup.tscn stays.
@export var disk_scene: PackedScene
## Uniform scale applied to the swapped-in disk. 0.2 ≈ the legacy floppy size.
@export_range(0.01, 5.0) var disk_visual_scale: float = 0.2
## Local rotation (degrees) layered on top of the disc's authored orientation.
## Tune if the disc faces the wrong direction after swap.
@export var disk_visual_rotation_deg: Vector3 = Vector3.ZERO
## Local position offset for the disk. Matches the floppy's position by default.
@export var disk_visual_offset: Vector3 = Vector3(-0.0345, 0.0, -0.0223)

const _INSTALL_TOAST_SCENE := preload("res://hud/components/install_toast.tscn")
const _HOWTO_PANEL_SCENE := preload("res://hud/components/howto_panel.tscn")

## Y rotation speed applied to the spinning visual, radians/sec.
## TAU/4 ≈ 90°/s = one full turn every 4 seconds.
const _SPIN_SPEED: float = TAU / 4.0

## Tint color washed over the floppy's original material. 0 alpha = no tint.
@export var tint_color: Color = Color(1.0, 0.84, 0.3)
## 0.0 = no tint (original floppy texture untouched).
## 1.0 = fully gold (original hidden). 0.2-0.35 = a gentle wash.
@export_range(0.0, 1.0) var tint_strength: float = 0.25
## Slight self-illumination intensity — makes the floppy catch the eye.
@export_range(0.0, 1.0) var tint_emission: float = 0.15

var _visual: Node3D = null
var _tint_material: StandardMaterial3D


func _ready() -> void:
	super._ready()
	prompt_verb = "install power up"
	# Already owned from a previous visit → don't spawn the floppy at all.
	# Player revisiting a level for exploration shouldn't see a stale pickup.
	if not powerup_flag.is_empty() and bool(GameState.get_flag(powerup_flag, false)):
		queue_free()
		return
	if disk_scene != null:
		_swap_disk_scene()
	var disk_label: Label3D = get_node_or_null(^"DiskLabel") as Label3D
	if disk_label != null:
		disk_label.text = powerup_label
	_visual = _find_visual()
	_build_tint_material()
	_tint_all_meshes(self)


func _swap_disk_scene() -> void:
	var existing: Node3D = get_node_or_null(^"disk_mesh") as Node3D
	if existing != null:
		remove_child(existing)
		existing.queue_free()
	var inst := disk_scene.instantiate()
	if not (inst is Node3D):
		push_warning("PowerupPickup %s: disk_scene root must be Node3D" % interactable_id)
		return
	var node := inst as Node3D
	# Master-model case: scene root holds multiple "{label} disc" subtrees.
	# Pick the one matching powerup_label, peel siblings off, drop the wrapper.
	var picked := _pick_label_disc(node)
	if picked != null:
		picked.get_parent().remove_child(picked)
		node.queue_free()
		node = picked
		node.position = Vector3.ZERO
	node.name = &"disk_mesh"
	node.scale = Vector3.ONE * disk_visual_scale
	node.rotation += Vector3(
		deg_to_rad(disk_visual_rotation_deg.x),
		deg_to_rad(disk_visual_rotation_deg.y),
		deg_to_rad(disk_visual_rotation_deg.z),
	)
	node.position += disk_visual_offset
	add_child(node)


# Find a child of `root` whose name (case-insensitive) starts with the
# powerup label and contains "disc" — e.g., powerup_label "LOVE" matches
# "Love disc". Returns null if no master-model layout is present (single-
# disc scene or unmatched label), in which case the caller uses the
# instanced root directly.
func _pick_label_disc(root: Node3D) -> Node3D:
	if powerup_label.is_empty():
		return null
	var needle := powerup_label.to_lower()
	for c in root.get_children():
		if c is Node3D:
			var lname := String(c.name).to_lower()
			if lname.contains("disc") and lname.contains(needle):
				return c
	return null


func _process(delta: float) -> void:
	if _visual != null and is_instance_valid(_visual):
		_visual.rotate_y(_SPIN_SPEED * delta)


func _find_visual() -> Node3D:
	# Prefer an explicitly-named node so designers can tag the spinning body.
	for candidate in ["disk_mesh", "DiskMesh", "Disk", "Sketchfab_Scene"]:
		var n := get_node_or_null(NodePath(candidate))
		if n is Node3D:
			return n
	# Fallback: first Node3D child that isn't infra (collision, label, anim).
	for c in get_children():
		if c is Label3D: continue
		if c is CollisionShape3D: continue
		if c is AnimationPlayer: continue
		if c is Node3D:
			return c
	return null


func _build_tint_material() -> void:
	_tint_material = StandardMaterial3D.new()
	# Tint goes through material_overlay (not override) so the original floppy
	# texture still shows. Alpha controls how strong the gold wash is.
	_tint_material.albedo_color = Color(tint_color.r, tint_color.g, tint_color.b, tint_strength)
	_tint_material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	if tint_emission > 0.0:
		_tint_material.emission_enabled = true
		_tint_material.emission = tint_color
		_tint_material.emission_energy_multiplier = tint_emission


## Walk children and apply the gold wash as `material_overlay` on every
## MeshInstance3D. Overlay preserves the underlying material/texture.
func _tint_all_meshes(n: Node) -> void:
	if n is MeshInstance3D:
		(n as MeshInstance3D).material_overlay = _tint_material
	for c in n.get_children():
		_tint_all_meshes(c)


func interact(_actor: Node3D) -> void:
	if powerup_flag.is_empty():
		push_error("PowerupPickup %s has no powerup_flag set" % interactable_id)
		queue_free()
		return
	GameState.set_flag(powerup_flag, true)
	# Reuse the existing collect-ding path.
	Events.item_added.emit(powerup_flag)

	# Disable detection + hide visuals THIS frame so the PromptUI's "[E]
	# install power up" hint clears before queue_free takes effect next tick.
	monitorable = false
	monitoring = false
	visible = false

	# Spawn the install toast into the root so the UX survives THIS pickup
	# being freed. On toast.finished, spawn the how-to panel. Both the toast
	# and the panel free themselves once their own lifecycle completes.
	var toast := _INSTALL_TOAST_SCENE.instantiate()
	get_tree().root.add_child(toast)
	toast.show_install(powerup_label)

	# Capture args into local vars so the lambda doesn't hold a dangling ref
	# to `self` (which is about to be freed).
	var caption := howto_caption
	var flag := powerup_flag
	var tree := get_tree()
	toast.finished.connect(func() -> void:
		var panel := _HOWTO_PANEL_SCENE.instantiate()
		tree.root.add_child(panel)
		panel.show_for(flag, caption)
	)

	# Free the pickup now so the sensor defocuses and PromptUI clears the
	# "[E] install" hint immediately. Visuals disappear with the node.
	queue_free()
