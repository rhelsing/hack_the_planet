class_name GodAbility
extends Ability

## "GOD" power-up. On flare_shoot input, every enemy within `radius` of the
## player permanently flips to faction "gold" (your rollerblade ally posse).
## Includes red, green, and splice_stealth — all become permanent allies.
##
## Visualization: a transparent gold sphere expands from the player to
## `radius` over `vfx_duration`, fading to zero alpha as it grows. A
## placeholder activation sound plays at the player position.
##
## Replaces the legacy lobbed-flare projectile. Trigger input action
## (flare_shoot) is preserved so the keybinding doesn't churn.

## Conversion radius (m) from the player — driven by the player's coin
## completion ratio. lerp(min, max, GameState.coin_completion_ratio()):
##   0 coins   → min_radius (puny — collect to grow it).
##   full coins → max_radius (full room-clear).
## Re-evaluated each fire so a coin grabbed mid-fight shows up on the
## next press. The VFX sphere scales to the same effective radius so
## the visible blast always matches the actual conversion catch.
@export var min_radius: float = 3.0
@export var max_radius: float = 15.0
## Seconds for the sphere to grow from spawn to `radius`.
@export var vfx_duration: float = 0.4
## Sphere's peak alpha at conversion-time; fades to 0 over vfx_duration.
@export_range(0.0, 1.0) var vfx_alpha: float = 0.35
## Sphere color — gold-ish so it reads as "ally posse". Alpha is overridden
## by vfx_alpha at spawn and tweens to 0.
@export var vfx_color: Color = Color(1.0, 0.78, 0.10, 1.0)
## Activation sound — placeholder (sound_teleport.mp3) until a proper "GOD
## roar" / pulse SFX is sourced. Override via inspector.
@export var activation_sound: AudioStream = preload("res://audio/sfx/sound_teleport.mp3")

# Groups whose members are eligible for conversion. Allies (gold) skipped
# since they're already on our side; player skipped to avoid self-conversion.
const _TARGET_GROUPS: Array[StringName] = [&"enemies", &"splice_enemies"]


func _ready() -> void:
	if ability_id == &"":
		ability_id = &"GodAbility"
	if powerup_flag == &"":
		powerup_flag = &"powerup_god"
	super._ready()


func _unhandled_input(event: InputEvent) -> void:
	if not owned:
		return
	if event.is_action_pressed("flare_shoot"):
		_fire()


func _fire() -> void:
	var body := _find_body()
	if body == null:
		return
	var body_3d: Node3D = body as Node3D
	if body_3d == null:
		return
	# Snapshot the effective radius once per cast so the VFX visual and
	# the conversion check use the same value (otherwise a coin picked up
	# during the tween could desync the two).
	var r: float = _effective_radius()
	_spawn_vfx(body_3d.global_position, r)
	_play_sound(body_3d.global_position)
	_convert_in_radius(body_3d, r)


## Lerps min_radius..max_radius by the player's coin completion ratio.
## 0 coins seen → min_radius. Full ratio → max_radius. Read once per
## fire (caller passes the result into _spawn_vfx + _convert_in_radius).
func _effective_radius() -> float:
	return lerp(min_radius, max_radius, GameState.coin_completion_ratio())


func _convert_in_radius(player: Node3D, radius: float) -> void:
	var origin: Vector3 = player.global_position
	var r2: float = radius * radius
	var tree := player.get_tree()
	if tree == null:
		return
	var seen: Dictionary = {}
	for grp in _TARGET_GROUPS:
		for node: Node in tree.get_nodes_in_group(grp):
			if seen.has(node):
				continue
			seen[node] = true
			if not (node is Node3D):
				continue
			if (node as Node3D).global_position.distance_squared_to(origin) > r2:
				continue
			if not node.has_method(&"set_faction"):
				continue
			node.call(&"set_faction", &"gold")
			# GOD-power converts get the rollerblade visual + skate profile.
			# (ControlPortal converts skip this path → they walk.)
			if node.has_method(&"set_profile_skate"):
				node.call(&"set_profile_skate")


# Build a unit sphere mesh with its own transparent material, drop into the
# scene at `origin`, scale up to `radius` while fading alpha to 0, then
# queue_free. Material is duplicated per-spawn so concurrent casts don't
# share an alpha tween. `radius` is the snapshotted _effective_radius()
# from the calling _fire() so the visual matches the conversion catch.
func _spawn_vfx(origin: Vector3, radius: float) -> void:
	var inst := MeshInstance3D.new()
	var sphere := SphereMesh.new()
	sphere.radius = 1.0
	sphere.height = 2.0
	sphere.radial_segments = 32
	sphere.rings = 16
	inst.mesh = sphere
	var mat := StandardMaterial3D.new()
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	var c: Color = vfx_color
	c.a = vfx_alpha
	mat.albedo_color = c
	inst.material_override = mat
	get_tree().current_scene.add_child(inst)
	inst.global_position = origin
	inst.scale = Vector3.ONE * 0.1
	var tween := create_tween()
	tween.set_parallel(true)
	tween.tween_property(inst, "scale", Vector3.ONE * radius, vfx_duration) \
		.set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
	tween.tween_property(mat, "albedo_color:a", 0.0, vfx_duration)
	tween.chain().tween_callback(inst.queue_free)


# One-shot 3D audio attached to the scene root at player position. Frees
# itself when the stream finishes — no orphan AudioStreamPlayer3Ds linger.
func _play_sound(origin: Vector3) -> void:
	if activation_sound == null:
		return
	var p := AudioStreamPlayer3D.new()
	p.bus = &"SFX"
	p.unit_size = 8.0
	p.max_distance = 40.0
	p.stream = activation_sound
	get_tree().current_scene.add_child(p)
	p.global_position = origin
	p.play()
	p.finished.connect(p.queue_free)
