class_name GrappleAbilitySpring
extends Ability

## Titanfall-style yank-and-launch grapple. Pulls the player toward the
## anchor (slightly below it so trajectory arcs UNDER the hook instead of
## smashing into it), auto-releases at proximity, hands the carried velocity
## back to PlayerBody. Press jump to release early for trick shots.
##
## Pull model (constant velocity, no gravity):
##   1. On fire, compute aim_point = anchor - UP * PULL_AIM_DROP. The drop
##      bias is what makes the player skim past the hook rather than colliding
##      with it; release happens just before reaching aim_point.
##   2. Each tick: aim direction = (aim_point - player).normalized().
##      Apply velocity = aim_dir * PULL_SPEED. Body's own physics is paused
##      so this is the only force acting on the player.
##   3. Auto-release when within RELEASE_DISTANCE of aim_point.
##   4. On release, hand the carried pull velocity to PlayerBody (+ small
##      upward kick) so the player launches in the pull direction; gravity
##      then takes over for a normal arc.

## How far the aim detector reaches (m). Target beyond this is ignored.
const MAX_RANGE: float = 37.5
## Cosine of the max angle between camera-forward and direction-to-target.
## 0.7 ≈ 45° half-cone — forgiving aim.
const FACING_COS: float = 0.7
## Upward kick added to the release velocity so a grapple-into-jump feels
## like it has a little hop on top of the carried pull velocity.
const RELEASE_UP_KICK: float = 5.0

## Player's pull speed toward the anchor (m/s). Higher = snappier yank.
## Compare to typical jump apex velocity (~10 m/s) — 30 reads as decisively
## fast. Bump up for a launchier feel.
@export var pull_speed: float = 30.0
## How far below the anchor the player aims for. The pull trajectory ends
## at (anchor - UP * pull_aim_drop), so the player skims under the hook
## instead of slamming into it. 1.5 ≈ player's eye-level offset.
@export var pull_aim_drop: float = 1.5
## Auto-release proximity (m). When the player gets within this of the aim
## point, the grapple lets go and hands velocity back to PlayerBody.
@export var release_distance: float = 2.5

# Aim state — updated each frame from the grappleable scan.
var _aim_target: Node3D = null

# Pull state — populated on _start_swing, cleared on _release.
var _swinging: bool = false
var _anchor: Node3D = null
## Carried velocity during pull — set each tick to (aim_dir * pull_speed)
## so the value at release is the launch velocity handed back to PlayerBody.
var _vel: Vector3 = Vector3.ZERO
var _line_renderer: MeshInstance3D = null

# Camera pivot bookkeeping — we flip CameraPivot out of top-level mode for
# the duration of the swing so it follows the body as a regular child (the
# normal DETACHED follow loop is paused while body._physics_process is off).
var _cached_pivot: Node3D = null
var _saved_pivot_top_level: bool = false
var _saved_pivot_local_position: Vector3 = Vector3.ZERO

# AudioStreamPlayer3D handles — same pattern as %JumpSound / %GrindSound on
# PlayerBody. Nodes live in player_body.tscn with stream pre-wired in the
# inspector; we just .play() / .stop(). Resolved at _ready by walking up to
# the body so this ability doesn't bake in node-path coupling.
var _fire_sound: AudioStreamPlayer3D = null
var _bite_sound: AudioStreamPlayer3D = null
var _swing_sound: AudioStreamPlayer3D = null
# True from fire until the body touches ground after release. Lets the wind
# loop continue through the post-pull airtime — _swinging itself flips off
# the moment the auto-release proximity hits.
var _swing_audio_active: bool = false


func _ready() -> void:
	if ability_id == &"":
		ability_id = &"GrappleAbility"
	if powerup_flag == &"":
		powerup_flag = &"powerup_sex"
	super._ready()
	var body: Node = _find_body()
	if body != null:
		_fire_sound = body.get_node_or_null(^"%GrappleFireSound") as AudioStreamPlayer3D
		_bite_sound = body.get_node_or_null(^"%GrappleBiteSound") as AudioStreamPlayer3D
		_swing_sound = body.get_node_or_null(^"%GrappleSwingSound") as AudioStreamPlayer3D
		if _fire_sound == null: push_error("[grapple] missing %GrappleFireSound on body")
		if _bite_sound == null: push_error("[grapple] missing %GrappleBiteSound on body")
		if _swing_sound == null: push_error("[grapple] missing %GrappleSwingSound on body")


# ── Frame-level updates ─────────────────────────────────────────────────

func _process(_delta: float) -> void:
	if not owned:
		return
	if _swinging:
		_update_line_visual()
	else:
		_update_aim()
	# Wind loop outlives the pull — _swinging flips off on auto-release but
	# the player keeps flying through the air from the carried velocity.
	# Stop the loop only once the body actually touches ground again.
	if _swing_audio_active and not _swinging:
		var body := _find_body()
		if body is CharacterBody3D and (body as CharacterBody3D).is_on_floor():
			if _swing_sound != null and _swing_sound.playing:
				_swing_sound.stop()
			_swing_audio_active = false


func _physics_process(delta: float) -> void:
	if _swinging:
		_tick_swing(delta)


func _unhandled_input(event: InputEvent) -> void:
	if not owned:
		return
	if _swinging:
		if event.is_action_pressed(&"jump"):
			_release()
		return
	if event.is_action_pressed(&"grapple_fire") and _aim_target != null:
		_start_swing(_aim_target)


# ── Aim scan ─────────────────────────────────────────────────────────────

func _update_aim() -> void:
	var body := _find_body()
	if body == null:
		_clear_all_prompts()
		_aim_target = null
		return
	var camera: Camera3D = body.get_node_or_null(^"CameraPivot/SpringArm3D/Camera3D") as Camera3D
	if camera == null:
		_clear_all_prompts()
		_aim_target = null
		return

	var cam_pos: Vector3 = camera.global_transform.origin
	var cam_fwd: Vector3 = -camera.global_transform.basis.z

	# Hide every grappleable first, then surface only the best — exactly one
	# prompt should be visible at a time so the player knows which they'll
	# latch onto.
	_clear_all_prompts()

	var best: Node3D = null
	var best_dist: float = -INF
	for n: Node in get_tree().get_nodes_in_group(&"grappleable"):
		var t: Node3D = n as Node3D
		if t == null or not is_instance_valid(t):
			continue
		var to_t: Vector3 = t.global_position - cam_pos
		var dist: float = to_t.length()
		if dist > MAX_RANGE or dist < 0.5:
			continue
		var dot: float = to_t.normalized().dot(cam_fwd)
		if dot < FACING_COS:
			continue
		# Among everything in the cone + within range, pick the FURTHEST —
		# lets the player chain a bigger leap when multiple hooks are
		# stacked along the camera line. Closer hooks are still selectable
		# by aiming such that they're the only one in the cone.
		if dist > best_dist:
			best_dist = dist
			best = t
	if best != null:
		_set_target_prompt(best, true)
	# Log transitions (new aim or dropped aim) rather than every frame.
	if best != _aim_target:
		if best != null:
			print("[grapple] aim locked: %s at dist=%.2f" % [best.name, best_dist])
		else:
			print("[grapple] aim dropped")
	_aim_target = best


func _set_target_prompt(target: Node, visible: bool) -> void:
	if target.has_method(&"set_prompt_visible"):
		target.call(&"set_prompt_visible", visible)


func _clear_all_prompts() -> void:
	for n: Node in get_tree().get_nodes_in_group(&"grappleable"):
		_set_target_prompt(n, false)


# ── Swing start / tick / release ────────────────────────────────────────

func _start_swing(target: Node3D) -> void:
	var body := _find_body()
	if body == null:
		return
	var body_3d: Node3D = body as Node3D
	if body_3d == null:
		return
	_clear_all_prompts()
	# Three-event grapple SFX, same shape as GrindSound: nodes live in the
	# tscn with stream pre-wired, we just .play(). Fire + bite are layered
	# same-frame ("throw…thunk"); the wind loop runs from now until the
	# body touches ground after release (poll in _process below).
	if _fire_sound != null:
		if _fire_sound.playing: _fire_sound.stop()
		_fire_sound.play()
	if _bite_sound != null:
		if _bite_sound.playing: _bite_sound.stop()
		_bite_sound.play()
	if _swing_sound != null:
		if _swing_sound.playing: _swing_sound.stop()
		_swing_sound.play()
		_swing_audio_active = true
	print("[grapple-aud] fire+bite+swing play")

	_anchor = target
	_swinging = true
	_vel = Vector3.ZERO  # populated each tick to the active pull velocity
	print("[grapple] fire: anchor=%s player=%s dist=%.2f" % [
		target.global_position, body_3d.global_position,
		(target.global_position - body_3d.global_position).length(),
	])

	# Animation: Jump (active leap "Jumping" clip) for the launch read,
	# then Fall (held "Jump" pose) after the leap clip's natural length.
	# Both transitions reachable from any state on AjSkin (see
	# aj_skin.tscn:216). Body's _physics_process is paused below, so
	# PlayerBody won't fight us until release.
	_play_grapple_anim(body)

	# Hand motion over to our pull loop. CharacterBody3D's own move_and_slide
	# would fight the constant-velocity pull if left running.
	body.set_physics_process(false)
	if body is CharacterBody3D:
		(body as CharacterBody3D).velocity = Vector3.ZERO

	# With body._physics_process off, PlayerBody's smoothed camera-follow
	# loop stops running — in DETACHED mode the pivot is a top-level node
	# and would freeze in world space, detaching from the flying body.
	# Pin the pivot to the body as a plain child for the duration of the
	# pull so it rides along automatically.
	_cached_pivot = body.get_node_or_null(^"CameraPivot") as Node3D
	if _cached_pivot != null:
		_saved_pivot_top_level = _cached_pivot.top_level
		_saved_pivot_local_position = _cached_pivot.position
		var pivot_local: Vector3 = Vector3(0, 1, 0)
		var body_offset: Variant = body.get(&"pivot_offset")
		if body_offset is Vector3:
			pivot_local = body_offset
		_cached_pivot.top_level = false
		_cached_pivot.position = pivot_local

	# Spawn the rope-line renderer into the current scene so it can follow
	# the anchor even if we move between levels (edge case: mid-pull).
	_line_renderer = _build_line_renderer()
	get_tree().current_scene.add_child(_line_renderer)


func _tick_swing(delta: float) -> void:
	if _anchor == null or not is_instance_valid(_anchor):
		_release()
		return
	var body := _find_body() as Node3D
	if body == null:
		return
	# Aim BELOW the anchor by pull_aim_drop so the trajectory carries the
	# player past/under the hook on release instead of crashing into it.
	var aim_point: Vector3 = _anchor.global_position - Vector3.UP * pull_aim_drop
	var to_aim: Vector3 = aim_point - body.global_position
	var dist: float = to_aim.length()
	if dist <= release_distance:
		_release()
		return
	var dir: Vector3 = to_aim / dist  # already non-zero; dist > release_distance > 0
	_vel = dir * pull_speed
	body.global_position += _vel * delta


func _release() -> void:
	var body := _find_body()
	# Hand the Verlet velocity straight to PlayerBody, plus a small up kick
	# so letting go at the apex feels like a jump instead of an instant fall.
	var release_velocity: Vector3 = _vel + Vector3.UP * RELEASE_UP_KICK

	_swinging = false
	_anchor = null
	if _line_renderer != null and is_instance_valid(_line_renderer):
		_line_renderer.queue_free()
	_line_renderer = null

	# Restore the camera pivot to whatever mode PlayerBody was in (top-level
	# for DETACHED, parented for PARENTED). _physics_process resuming below
	# takes over the smoothed follow from here.
	if _cached_pivot != null and is_instance_valid(_cached_pivot):
		_cached_pivot.top_level = _saved_pivot_top_level
		_cached_pivot.position = _saved_pivot_local_position
	_cached_pivot = null

	if body == null:
		return
	if body is CharacterBody3D:
		(body as CharacterBody3D).velocity = release_velocity
	body.set_physics_process(true)
	# Snap the camera to the body's new position so DETACHED mode doesn't
	# start from a stale pivot transform on the next frame.
	if body.has_method(&"_snap_camera_to_player"):
		body.call(&"_snap_camera_to_player")


# ── Animation ───────────────────────────────────────────────────────────

# Drive the body's skin into Jump (launch) → Fall (held pose) so the player
# reads as airborne for the grapple. Body._physics_process is paused during
# the pull, so we must drive the skin manually — PlayerBody's per-tick
# idle/move/jump/fall router is offline. Same skin contract methods
# PlayerBody itself uses (player_body.gd:1532, :2446-:2448).
func _play_grapple_anim(body: Node) -> void:
	var skin: Variant = body.get(&"_skin")
	if skin == null or not is_instance_valid(skin):
		push_error("[grapple-anim] no _skin on body=%s" % body)
		return
	if skin.has_method(&"jump"):
		skin.call(&"jump")
		print("[grapple-anim] jump()")
	else:
		push_error("[grapple-anim] skin %s missing jump()" % skin)
	await get_tree().create_timer(0.4, true).timeout
	if not _swinging or not is_instance_valid(skin):
		return
	if skin.has_method(&"fall"):
		skin.call(&"fall")
		print("[grapple-anim] fall()")


# ── Line renderer ───────────────────────────────────────────────────────

func _build_line_renderer() -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	var im := ImmediateMesh.new()
	mi.mesh = im
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.9, 0.4, 0.85, 1)
	mat.emission_enabled = true
	mat.emission = Color(0.9, 0.4, 0.85, 1)
	mat.emission_energy_multiplier = 2.5
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.no_depth_test = true
	mi.material_override = mat
	return mi


func _update_line_visual() -> void:
	if _line_renderer == null or _anchor == null or not is_instance_valid(_anchor):
		return
	var body := _find_body() as Node3D
	if body == null:
		return
	var im := _line_renderer.mesh as ImmediateMesh
	if im == null:
		return
	im.clear_surfaces()
	im.surface_begin(Mesh.PRIMITIVE_LINE_STRIP)
	im.surface_add_vertex(body.global_position + Vector3.UP * 1.2)
	im.surface_add_vertex(_anchor.global_position)
	im.surface_end()
