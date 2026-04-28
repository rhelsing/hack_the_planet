extends Node3D
class_name PortalPlatform

## Paired warp portal — drop two with matching `link_id` and walking on
## one drops the player through it, teleports them to the partner, and
## pops them up out of the partner. Glitch overlay + warp sfx sell the
## "data packet handoff" feel.
##
## Pairing is via a static class-level registry keyed by link_id. The
## first instance to _ready stores itself; the second sees the entry
## and both link to each other. Solo portals (no partner) silently
## refuse warp on body_entered.
##
## Player physics is paused during the warp so move_and_slide doesn't
## fight the tweens. Restored at the end. Partner gets a brief cooldown
## so the just-warped player can't immediately re-trigger them on land.

const _PLATFORM_MATERIAL: ShaderMaterial = preload("res://level/platforms.tres")

@export_group("Pair")
## Both portals in a pair must share this. Empty = unpaired (silent).
@export var link_id: StringName = &""

@export_group("Color")
@export var palette_base: Color = Color(0.06, 0.0, 0.04, 1.0):
	set(value):
		palette_base = value
		_apply_palette()
@export var palette_highlight: Color = Color(0.95, 0.35, 0.85, 1.0):
	set(value):
		palette_highlight = value
		_apply_palette()

@export_group("Shape")
@export var size: Vector3 = Vector3(4.0, 0.3, 4.0):
	set(value):
		size = value
		_apply_size()

@export_group("Warp")
## How far below the deck the player slides before teleporting. Read as
## "fall through the floor."
@export var slide_depth: float = 1.5
## Seconds for the down-slide at the source. Quick — quad ease-in.
@export var slide_in_duration: float = 0.25
## Seconds for the up-slide at the destination. Elastic ease-out gives
## the springy "pop out" arrival.
@export var slide_out_duration: float = 0.35
## Seconds for the glitch overlay to fade back to 0 after arrival.
@export var glitch_fade: float = 0.3
## Cooldown applied to the partner the moment a warp starts, so the
## player who just landed can't immediately re-warp back.
@export var partner_cooldown: float = 0.5
## Warp sfx — plays at both source and destination. Empty = silent.
@export var warp_sound: AudioStream

# Static registry: link_id → first PortalPlatform with that id.
# Second instance to _ready sees the entry and both link up.
static var _registry: Dictionary = {}

@onready var _deck: Node3D = $Deck
@onready var _box: CSGBox3D = $Deck/Box
@onready var _trigger: Area3D = $Trigger
@onready var _trigger_shape: CollisionShape3D = $Trigger/Shape

var _material: ShaderMaterial = null
var _partner: PortalPlatform = null
var _is_warping: bool = false
var _cooldown_t: float = 0.0
var _warp_player: AudioStreamPlayer3D = null


func _ready() -> void:
	_material = _PLATFORM_MATERIAL.duplicate() as ShaderMaterial
	_box.material_override = _material
	_apply_palette()
	_apply_size()
	_warp_player = AudioStreamPlayer3D.new()
	_warp_player.bus = &"SFX"
	_warp_player.unit_size = 6.0
	_warp_player.max_distance = 35.0
	_deck.add_child(_warp_player)
	_trigger.body_entered.connect(_on_body_entered)
	if link_id != &"":
		if _registry.has(link_id) and is_instance_valid(_registry[link_id]):
			var first: PortalPlatform = _registry[link_id]
			first._partner = self
			self._partner = first
		else:
			_registry[link_id] = self


func _exit_tree() -> void:
	# Unhook from the registry + partner so a fresh load can re-pair.
	if link_id != &"" and _registry.get(link_id) == self:
		_registry.erase(link_id)
	if _partner != null and is_instance_valid(_partner):
		_partner._partner = null
	_partner = null


func _process(delta: float) -> void:
	if _cooldown_t > 0.0:
		_cooldown_t -= delta


func _on_body_entered(body: Node) -> void:
	if _is_warping or _cooldown_t > 0.0:
		return
	if _partner == null or not is_instance_valid(_partner):
		push_warning("PortalPlatform[%s]: no partner, can't warp" % link_id)
		return
	if not body.is_in_group("player"):
		return
	if not (body is Node3D):
		return
	_warp(body as Node3D)


# Single coroutine that drives the whole warp: lock physics, slide-in,
# teleport, slide-out, glitch fade, restore physics. Tween awaits gate
# the phases sequentially. Typed as Node3D + duck-typed access (has_method,
# property existence) so the script compiles without forcing the
# PlayerBody class into the SceneTree-mode test context.
func _warp(player: Node3D) -> void:
	_is_warping = true
	_partner._cooldown_t = partner_cooldown

	# Pause player physics so move_and_slide doesn't fight the tween.
	player.set_physics_process(false)
	if "velocity" in player:
		player.set(&"velocity", Vector3.ZERO)

	# Brain refs — duck-typed so AI-driven bodies (no PlayerBrain) skip the
	# camera dance gracefully. Suspend mouse-look during the warp so the
	# yaw/pitch tweens aren't fought by twitch input.
	var brain: Node = player.get(&"_brain") if "_brain" in player else null
	var camera_pivot: Node3D = null
	var spring_arm: Node3D = null
	if brain != null:
		if "camera_pivot" in brain:
			camera_pivot = brain.get(&"camera_pivot") as Node3D
		if "spring_arm" in brain:
			spring_arm = brain.get(&"spring_arm") as Node3D
		brain.set_process_unhandled_input(false)

	# Sfx + glitch ramp on departure.
	_play_warp_sound()
	var skin: Object = player.get(&"_skin") if "_skin" in player else null
	if skin != null and skin.has_method(&"set_glitch_progress"):
		var glitch_tween := player.create_tween()
		glitch_tween.tween_method(skin.set_glitch_progress, 0.0, 1.0, slide_in_duration)

	# Camera lookat — yaw to face the partner deck, pitch to level. Runs in
	# parallel with the slide-in so the player sees their destination
	# rotating into view while they fall through the source.
	#
	# Compute target yaw via look_at on a leveled point, then read the
	# resulting local rotation.y. Avoids hand-rolled basis math (and the
	# sign-flip bug it caused) and is robust to any parent body rotation.
	if camera_pivot != null and is_instance_valid(_partner):
		var partner_aim: Vector3 = _partner._deck.global_position
		var leveled_aim := Vector3(partner_aim.x, camera_pivot.global_position.y, partner_aim.z)
		var aim_dir: Vector3 = leveled_aim - camera_pivot.global_position
		if aim_dir.length_squared() > 0.0001:
			var saved_basis: Basis = camera_pivot.global_basis
			camera_pivot.look_at(leveled_aim, Vector3.UP)
			# Flip 180° — this rig's "view direction" is the opposite of what
			# Node3D.look_at considers forward (camera_pivot's effective face is
			# +Z, not -Z, due to the SpringArm3D's flipped basis in player_body).
			var target_yaw: float = camera_pivot.rotation.y + PI
			camera_pivot.global_basis = saved_basis
			# Wrap to within ±PI of current so the tween takes the short arc.
			var current_yaw: float = camera_pivot.rotation.y
			while target_yaw - current_yaw > PI:
				target_yaw -= TAU
			while target_yaw - current_yaw < -PI:
				target_yaw += TAU
			var yaw_tween := player.create_tween()
			yaw_tween.tween_property(camera_pivot, "rotation:y", target_yaw, slide_in_duration) \
				.set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_IN_OUT)
		if spring_arm != null:
			var pitch_tween := player.create_tween()
			pitch_tween.tween_property(spring_arm, "rotation:x", 0.0, slide_in_duration) \
				.set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_IN_OUT)

	# Slide down through the source deck. Target = a bit below the deck top.
	var source_top: Vector3 = _deck.global_position
	source_top.y += size.y * 0.5
	var source_below: Vector3 = source_top + Vector3.DOWN * slide_depth
	var slide_in := player.create_tween()
	slide_in.tween_property(player, "global_position", source_below, slide_in_duration) \
		.set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_IN)
	await slide_in.finished

	# Teleport. Partner's "below" position is the equivalent depth under
	# its own deck — we'll slide up from there.
	var partner_top: Vector3 = _partner._deck.global_position
	partner_top.y += _partner.size.y * 0.5
	var partner_below: Vector3 = partner_top + Vector3.DOWN * slide_depth
	player.global_position = partner_below
	_partner._play_warp_sound()

	# Slide up out of the partner deck. Elastic for that springy pop-out.
	var slide_out := player.create_tween()
	slide_out.tween_property(player, "global_position",
		partner_top + Vector3.UP * 0.1, slide_out_duration) \
		.set_trans(Tween.TRANS_ELASTIC).set_ease(Tween.EASE_OUT)
	await slide_out.finished

	# Glitch fade back to 0 + restore physics + mouse-look.
	if skin != null and skin.has_method(&"set_glitch_progress"):
		var unglitch := player.create_tween()
		unglitch.tween_method(skin.set_glitch_progress, 1.0, 0.0, glitch_fade)
	player.set_physics_process(true)
	if brain != null:
		brain.set_process_unhandled_input(true)
	_is_warping = false


func _play_warp_sound() -> void:
	if warp_sound == null or _warp_player == null:
		return
	_warp_player.stream = warp_sound
	_warp_player.play()


func _apply_palette() -> void:
	if _material == null:
		return
	_material.set_shader_parameter(&"palette_black", palette_base)
	_material.set_shader_parameter(&"palette_purple", palette_highlight)


func _apply_size() -> void:
	if _box != null:
		_box.size = size
	if _trigger_shape != null and _trigger_shape.shape is BoxShape3D:
		var trigger_box: BoxShape3D = _trigger_shape.shape as BoxShape3D
		trigger_box.size = Vector3(size.x, 0.6, size.z)
		_trigger_shape.position.y = size.y * 0.5 + 0.3
