extends Node3D

## Level 5 — Betray Ending. Walk-of-shame scene that fires when the player
## chose `splice_committed` in level_3_splice_offer.dialogue. See
## docs/splice_arc.md §5b for the spec.
##
## On _ready: locks the player into a slow forward walk via
## PlayerBody.enter_betrayal_walk, then plays a scripted sequence of walkie
## lines from Splice / DialTone / Glitch / Nyx. When the player reaches the
## EndTerminal Area3D, the screen fades to a "POPULATION: 1" card and the
## game returns to the main menu.

## Path to the main menu the game returns to after the end card.
@export var main_menu_path: String = "res://menu/main_menu.tscn"

# End-card assets — same shader the menu transitions and on-puzzle glitches
# use, plus the warp sfx that punches in when the glitch ramp goes exponential.
const _GLITCH_SHADER_PATH: String = "res://menu/transitions/glitch.gdshader"
const _PORTRAITS_PATH: String = "res://dialogue/voice_portraits.tres"
const _WARP4: AudioStream = preload("res://audio/sfx/warp4.mp3")

# End-card script. Each entry is [speaker, rest_text]. Empty array = blank
# spacer row. The speaker token is uppercased + bolded + colored from the
# VoicePortraits registry (so DialTone is blue, Nyx gold, Glitch lavender,
# Splice red — same palette the dialogue balloons use). rest_text renders
# in the default end-card green.
const _END_CARD_SCRIPT: Array = [
	["DialTone", ": DISCONNECTED."],
	["Nyx", ": DISCONNECTED."],
	["Glitch", ": OFFLINE."],
	[],
	["", "THE GIBSON IS YOURS."],
	["", "POPULATION: 2."],
	[],
	["Splice", " IS YOUR BEST FRIEND."],
]

## Player's forced walk direction in WORLD space (Y is stripped). Default
## -Z = standard "into the corridor". Flip if you mirror the level layout.
@export var walk_direction: Vector3 = Vector3(0, 0, -1)
## Splice's pace. The player has no independent velocity in this scene —
## per-frame we snap them to a fixed offset behind Splice, so Splice's
## speed IS the cinematic's pace.
@export var splice_walk_speed_mps: float = 1.35
## How far behind Splice (along walk_direction) the player rides. Tune
## by feel; with Splice at 2x scale, 3u puts the player right behind him
## for a tight close-walk shot.
@export var follow_distance: float = 3.0
## Lateral offset (meters) from the follow line. Positive = LEFT of Splice
## relative to walk_direction (so the player walks beside-and-behind, not
## directly in his shadow). 0 = on the follow line.
@export var side_offset: float = 2.0
## Lateral offset (meters) for Splice himself, opposite of side_offset
## (positive = RIGHT of corridor centerline). Combined with side_offset
## lets the pair walk side-by-side with a clear lateral gap, instead of
## the player parked in Splice's shadow.
@export var splice_side_offset: float = 1.0
## Vertical offset for the player relative to Splice (Splice's transform
## origin is at his feet — this lifts the player to floor + 1u).
@export var follow_y_offset: float = 0.0
## World-Z (when walk_direction is -Z) where Splice stops walking. Player's
## EndTerminal is at z=-60, floor ends at z=-65 — clamp Splice short of
## that so he doesn't walk off the geometry.
@export var splice_stop_at_z: float = -62.0

## Initial delay before the cutscene's first line fires (gives the player
## a beat to realize they're locked into the walk).
@export var first_line_delay_s: float = 2.5
## Seconds the end card holds before fading to main menu.
@export var end_card_hold_s: float = 4.5
## Background loop for the corridor walk. Force-looped via Audio.play_music.
@export var loop_music: AudioStream = preload("res://audio/music/it_came_from_a_synth.mp3")
@export var loop_music_fade_in_s: float = 1.5

# Scripted dialogue beats now live in cutscenes/l5_walk.tres as a non-
# blocking CutsceneTimeline (LineSteps + WaitSteps). The level locks the
# player into the forced walk; the cutscene plays the radio chatter on top.
# freeze_player must stay false on that timeline — level_5 owns the walk.

var _ended: bool = false
var _splice_npc: Node3D
var _splice_skin: Node
var _splice_walking: bool = false
var _player: Node3D = null  # cached so _process can position-snap each tick


func _ready() -> void:
	SaveService.set_current_level(&"level_5")
	# Match level_mockup's atmosphere — load its scene, lift the
	# WorldEnvironment's environment resource, swap into ours. Cheap one-time
	# extraction; instance is freed immediately. The runtime_boost script on
	# level_mockup's env flips fog_enabled / ssao / glow on at runtime, so we
	# also instance + duplicate to inherit the same boosted state.
	_adopt_mockup_environment()
	# Hide the gameplay HUD for the betray walk — coin counter / powerup pills
	# read as belonging to the loyal arc and break the cinematic frame.
	# Restored in _exit_tree so a debug reload doesn't strand it hidden.
	var hud := get_tree().get_first_node_in_group(&"hud")
	if hud != null:
		hud.visible = false
	if loop_music != null:
		Audio.play_music(loop_music, loop_music_fade_in_s)
	# Find the player and lock them into the walk. PlayerBody is added to the
	# "player" group at _ready by the existing setup.
	var player := get_tree().get_first_node_in_group(&"player") as Node3D
	_player = player
	# Lock all input (jump/dash/attack/crouch/interact) but pass speed=0 so
	# the body doesn't drive any velocity — _process snaps the position
	# directly behind Splice each frame, so we don't want a fight between
	# physics velocity and the snap.
	if player != null and player.has_method(&"enter_betrayal_walk"):
		player.call(&"enter_betrayal_walk", walk_direction, 0.0)
	# Bake the cinematic's spawn camera pose. User picked these via the
	# 5-second logger: pivot yaw 26.5°, spring-arm pitch -11.4°. Set after
	# enter_betrayal_walk because that call may swing yaw to face the walk
	# direction; we override here so the camera lands at the framed angle
	# regardless.
	if player != null:
		# Camera bake — explicit full Vector3 assignment (not single-axis
		# component setters) so Godot doesn't carry stale pitch/roll from
		# whatever the pivot/spring were previously into the new basis. The
		# component-setter approach (`pivot.global_rotation.y = X`) reads
		# existing components, modifies one, writes back via Euler.from_basis
		# in YXZ order — and that's where the 180° wraparound was coming from
		# when an existing pitch was non-zero.
		# Verbatim from the in-game logger: pivot.yaw = -57.7°, spring.pitch
		# = -15.7°. No +180° offset needed once we control all three axes.
		var pivot: Node3D = player.get_node_or_null(^"CameraPivot") as Node3D
		if pivot != null:
			pivot.global_rotation = Vector3(0.0, deg_to_rad(-57.7), 0.0)
		var spring: Node3D = player.get_node_or_null(^"CameraPivot/SpringArm3D") as Node3D
		if spring != null:
			spring.rotation = Vector3(deg_to_rad(-15.7), 0.0, 0.0)
	if player != null and player.has_method(&"set_profile_walk"):
		player.call(&"set_profile_walk")
	# Swap the player skin's running animation for plain Walking. The body
	# keeps calling _skin.move() per tick, but with the AnimationTree
	# disabled those calls are no-ops; the underlying AnimationPlayer just
	# loops Walking. _exit_tree restores.
	if player != null:
		var pskin = player.get(&"_skin")
		if pskin != null and pskin.has_method(&"walk_lock"):
			pskin.call(&"walk_lock")
		# Hide any wheels-related node anywhere under the player. find_children
		# walks the FULL subtree (owned=false) so it catches WheelsLeft/Right
		# even after they've been reparented under a Skeleton3D BoneAttachment.
		_kill_wheels(player)
	# EndTerminal is no longer wired as a fade trigger — the fade-to-black
	# end card is bound exclusively to the WalkOfShameCutscene.ended signal
	# (`_on_cutscene_ended` below). The Area3D stays in the scene as a
	# geometric landmark / safety stop, but doesn't drive the cinematic.
	# Without this gating, walking into the area would fire _show_end_card
	# BEFORE Glitch's last line lands, cutting the dialogue mid-beat.
	# Splice walks ahead alongside the player. Skin pre-faces the walk
	# direction (CompanionNPC.swivel_speed=0 keeps it from rotating back
	# toward the player every frame); calling skin.move() switches the
	# AnimationTree state machine to its Move state for the duration.
	_splice_npc = get_node_or_null(^"SpliceLead") as Node3D
	if _splice_npc != null:
		_splice_skin = _splice_npc.get_node_or_null(^"Skin")
		if _splice_skin is Node3D:
			(_splice_skin as Node3D).rotation.y = atan2(walk_direction.x, walk_direction.z)
		# Splice walks (not runs) for the betray cinematic.
		if _splice_skin != null and _splice_skin.has_method(&"walk_lock"):
			_splice_skin.call(&"walk_lock")
		elif _splice_skin != null and _splice_skin.has_method(&"move"):
			_splice_skin.call(&"move")
		_splice_walking = true
	# Kick off the scripted line sequence via the non-blocking CutscenePlayer.
	# We arm manually (instead of via arm_flag) because this fires once per
	# level load, not on a save-flag; the CutscenePlayer's fire_once gate
	# would otherwise block re-entry on respawn.
	_arm_walk_cutscene_after_delay()
	# Credits roll alongside the corridor walk. Same scroll as the post-L4
	# hub trigger and the main-menu Credits button. Self-frees on completion
	# or Esc; the end-card / main-menu transition is independent of this
	# overlay (end-card's CanvasLayer is layer 100 — credits sit below at 50).
	_spawn_credits_overlay()


func _adopt_mockup_environment() -> void:
	var packed: PackedScene = load("res://level/level_mockup.tscn")
	if packed == null:
		push_warning("level_5: level_mockup.tscn missing — keeping local env")
		return
	var inst: Node = packed.instantiate()
	var src_we: WorldEnvironment = inst.find_child("WorldEnvironment", true, false) as WorldEnvironment
	var local_we: WorldEnvironment = find_child("WorldEnvironment", true, false) as WorldEnvironment
	if src_we != null and local_we != null and src_we.environment != null:
		local_we.environment = src_we.environment.duplicate()
		# Mirror the runtime-boost flips the mockup applies in its _ready.
		local_we.environment.fog_enabled = true
		local_we.environment.ssao_enabled = true
		local_we.environment.glow_enabled = true
	inst.queue_free()


func _kill_wheels(root: Node) -> void:
	# Walk the whole player subtree (recursive=true, owned=false so reparented
	# nodes still match) and hide anything matching "Wheels*" or
	# "RollerbladeWheels". `find_children` is the canonical Godot 4 API for
	# this — handles deep reparenting (under Skeleton3D / BoneAttachment3D).
	var hits: Array[Node] = []
	hits.append_array(root.find_children("Wheels*", "", true, false))
	hits.append_array(root.find_children("RollerbladeWheels", "", true, false))
	for n in hits:
		if n is Node3D:
			(n as Node3D).visible = false
	print("[level_5] _kill_wheels hits=%d under %s" % [hits.size(), root.get_path()])


func _exit_tree() -> void:
	var hud := get_tree().get_first_node_in_group(&"hud") if get_tree() != null else null
	if hud != null:
		hud.visible = true
	# Restore the player skin's normal AnimationTree so subsequent levels
	# get full state-machine driven animation again. Splice's skin lives on
	# this level and disposes with it — no need to unlock him.
	var player := get_tree().get_first_node_in_group(&"player") if get_tree() != null else null
	if player != null:
		var pskin = player.get(&"_skin")
		if pskin != null and pskin.has_method(&"walk_unlock"):
			pskin.call(&"walk_unlock")
		# Mirror enter_betrayal_walk (called in _ready). Without this, the
		# locked walk vector leaks into whatever level is mounted next and
		# the player can't move. F9 round-trips remount level_5 so the
		# symptom never showed; F1/F2 unmount to a different level and it
		# does. See player_body.gd:1911.
		if player.has_method(&"exit_betrayal_walk"):
			player.call(&"exit_betrayal_walk")


func _spawn_credits_overlay() -> void:
	var packed: PackedScene = load("res://menu/credits.tscn")
	if packed == null:
		return
	var layer := CanvasLayer.new()
	layer.layer = 50
	add_child(layer)
	var inst: Node = packed.instantiate()
	layer.add_child(inst)
	if inst.has_signal(&"back_requested"):
		inst.connect(&"back_requested", func() -> void: layer.queue_free(),
			CONNECT_ONE_SHOT)


## Debug — temporary camera-position logger. Prints camera + pivot pose
## every 5s so the user can read off a desired spawn pose. Strip when
## level_5's spawn camera angle is finalized.
var _cam_log_timer: float = 0.0


func _process(delta: float) -> void:
	# Camera pose log (every 5 seconds, regardless of cinematic state).
	_cam_log_timer -= delta
	if _cam_log_timer <= 0.0:
		_cam_log_timer = 5.0

		_log_camera_pose()
	# NOTE: do NOT gate on _ended. Once the last line ("Don't stop walking.")
	# finishes the cutscene fires `ended`, _ended flips true, and the end-card
	# fade begins — but the visual contract is "they keep walking off into
	# the dark." Splice's per-frame advance + the player's follow-snap must
	# continue running through the fade window for that to land.
	if _splice_npc == null:
		return
	var dir := walk_direction
	dir.y = 0.0
	if dir.length_squared() < 0.0001:
		return
	dir = dir.normalized()
	# "Left" relative to walk direction: right = forward × up, left = -right.
	# For walk_direction = -Z, up = +Y, this evaluates to -X (positive
	# side_offset puts the player on the -X side of Splice).
	var left: Vector3 = -dir.cross(Vector3.UP).normalized()
	# Splice walks indefinitely. The cinematic ends when the cutscene's
	# `ended` signal fires (wired in _arm_walk_cutscene_after_delay) — at
	# that point _show_end_card runs the fade-to-black + main-menu transit.
	if _splice_walking:
		_splice_npc.global_position += dir * splice_walk_speed_mps * delta
	# Anchor Splice on the right side of the corridor regardless of how
	# much he's walked along dir. Per-frame: forward progress accumulates
	# (set above), but the lateral component is overwritten to lock him on
	# his side. The player anchors on the left, so the pair walks side-by-side.
	var lateral_axis: Vector3 = -left  # right vector
	# Project current splice position onto the walk axis, then add Splice's
	# right offset. Avoids drift from any small lateral nudge that might
	# accumulate over time.
	var splice_along: float = _splice_npc.global_position.dot(dir)
	_splice_npc.global_position = (
		dir * splice_along
		+ lateral_axis * splice_side_offset
		+ Vector3(0.0, _splice_npc.global_position.y, 0.0)
	)
	# Player rides a fixed offset behind Splice every frame, plus side_offset
	# meters to the left of him so they're not in his shadow. No physics
	# fight, no velocity drift, no save-load race — Splice's transform IS
	# the cinematic. Camera mouse-look still rotates the camera_pivot
	# (which is parented to player_body, so it tracks this position).
	if _player != null and is_instance_valid(_player):
		_player.global_position = _splice_npc.global_position \
			- dir * follow_distance \
			+ left * side_offset \
			+ Vector3(0.0, follow_y_offset, 0.0)
		# Zero velocity so the body doesn't try to integrate any leftover
		# physics state into the next frame. Skin facing is driven by
		# enter_betrayal_walk now (via intent.face_yaw_override).
		if "velocity" in _player:
			_player.set("velocity", Vector3.ZERO)


func _arm_walk_cutscene_after_delay() -> void:
	await get_tree().create_timer(first_line_delay_s).timeout
	if _ended:
		return
	var cs := get_node_or_null(^"%WalkOfShameCutscene")
	if cs != null and cs.has_method(&"arm"):
		# Cutscene's `ended(success)` signal is the cinematic's natural
		# terminator — Splice keeps walking until then, then the end card
		# fades and we transition to the main menu.
		if cs.has_signal(&"ended"):
			cs.connect(&"ended", _on_cutscene_ended, CONNECT_ONE_SHOT)
		cs.call(&"arm")
	else:
		push_warning("level_5: WalkOfShameCutscene not found — radio chatter will not play")


func _on_cutscene_ended(_success: bool) -> void:
	if _ended:
		return
	_ended = true
	# Flip the camera 180° on Y so the fade reveals Splice + player walking
	# AWAY from the lens instead of toward it. Instant snap — the fade itself
	# is the transition; tweening the yaw alongside the fade reads as drifty
	# in playtest, the cut version reads as a deliberate framing change.
	if _player != null and is_instance_valid(_player):
		var pivot: Node3D = _player.get_node_or_null(^"CameraPivot") as Node3D
		if pivot != null:
			pivot.global_rotation.y += PI
	_show_end_card()


func _on_end_entered(body: Node) -> void:
	if _ended:
		return
	if not body.is_in_group(&"player"):
		return
	_ended = true
	_show_end_card()


func _show_end_card() -> void:
	# Build the overlay: bg (black) + VBox of typewriter RichTextLabels + a
	# glitch ColorRect on TOP. Order matters — glitch_rect added last so its
	# screen_texture sample picks up the bg + typed lines below.
	var portraits: Resource = null
	if ResourceLoader.exists(_PORTRAITS_PATH):
		portraits = load(_PORTRAITS_PATH)

	var layer := CanvasLayer.new()
	layer.layer = 100
	add_child(layer)

	var bg := ColorRect.new()
	bg.color = Color(0, 0, 0, 0)
	bg.anchor_right = 1.0
	bg.anchor_bottom = 1.0
	bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	layer.add_child(bg)

	var box := VBoxContainer.new()
	box.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	box.alignment = BoxContainer.ALIGNMENT_CENTER
	box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	box.add_theme_constant_override(&"separation", 8)
	layer.add_child(box)

	var glitch_rect := ColorRect.new()
	var glitch_mat := ShaderMaterial.new()
	glitch_mat.shader = load(_GLITCH_SHADER_PATH)
	glitch_mat.set_shader_parameter(&"alpha", 0.0)
	glitch_mat.set_shader_parameter(&"aberration_max", 0.012)
	glitch_mat.set_shader_parameter(&"jitter_amplitude", 0.04)
	glitch_rect.material = glitch_mat
	glitch_rect.anchor_right = 1.0
	glitch_rect.anchor_bottom = 1.0
	glitch_rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
	layer.add_child(glitch_rect)

	# 1s fade-to-black under the still-live cinematic.
	var fade_tw := create_tween()
	fade_tw.tween_property(bg, "color", Color(0, 0, 0, 1), 1.0)
	await fade_tw.finished

	# Typewrite each line in sequence. Per-character: pull from the
	# `&"end_card_type"` cue (62-sample mechanical-keyboard pool, randomized
	# pick + volume + pitch each play) so the typing reads as a real keyboard
	# rather than a synthetic UI click. Density is gated by THREE filters
	# stacked: every-other-character (A), 60% chance gate (B), skip whitespace
	# (C). Roughly 25% of characters end up with a click — sparse enough that
	# the pool has room to breathe and you don't hear the same wav twice in
	# quick succession.
	for entry in _END_CARD_SCRIPT:
		var lbl := RichTextLabel.new()
		lbl.bbcode_enabled = true
		lbl.fit_content = true
		lbl.scroll_active = false
		lbl.autowrap_mode = TextServer.AUTOWRAP_OFF
		lbl.add_theme_font_size_override(&"normal_font_size", 48)
		lbl.add_theme_font_size_override(&"bold_font_size", 48)
		lbl.add_theme_color_override(&"default_color", Color(0.8, 1.0, 0.8, 1.0))
		lbl.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
		if entry.is_empty():
			# Blank spacer row — fixed-height, no typing pass.
			lbl.text = " "
			lbl.custom_minimum_size = Vector2(0, 24)
			box.add_child(lbl)
			continue
		var speaker: String = entry[0]
		var rest: String = entry[1]
		lbl.text = _format_end_card_line(speaker, rest, portraits)
		lbl.visible_characters = 0
		box.add_child(lbl)
		var total: int = lbl.get_total_character_count()
		var parsed: String = lbl.get_parsed_text()
		for i in total:
			lbl.visible_characters = i + 1
			# A: every other character only.
			# B: 60% chance gate on top of (A).
			# C: skip whitespace (space / newline / tab) entirely.
			if i % 2 == 0 and randf() < 0.6:
				var ch: String = parsed.substr(i, 1) if i < parsed.length() else ""
				if ch != " " and ch != "\n" and ch != "\t":
					Audio.play_sfx(&"end_card_type")
			await get_tree().create_timer(0.035).timeout
		await get_tree().create_timer(0.45).timeout

	# Beat to read the final state.
	await get_tree().create_timer(1.0).timeout

	# Glitch flicker phase — short pulses at low alpha. Reads as "the signal
	# is starting to break up." Lambda setter keeps the tween bound to the
	# specific ShaderMaterial we just built.
	var set_alpha := func(v: float) -> void:
		if is_instance_valid(glitch_mat):
			glitch_mat.set_shader_parameter(&"alpha", v)
	var flicker_tw := create_tween()
	flicker_tw.tween_method(set_alpha, 0.0, 0.25, 0.06)
	flicker_tw.tween_method(set_alpha, 0.25, 0.05, 0.08)
	flicker_tw.tween_method(set_alpha, 0.05, 0.30, 0.10)
	flicker_tw.tween_method(set_alpha, 0.30, 0.10, 0.08)
	flicker_tw.tween_method(set_alpha, 0.10, 0.20, 0.10)
	await flicker_tw.finished

	# Warp4 punches in at the start of the exponential ramp.
	var warp_player := AudioStreamPlayer.new()
	warp_player.stream = _WARP4
	warp_player.bus = &"SFX"
	layer.add_child(warp_player)
	warp_player.play()

	# Exponential ramp to 1.0 — feels like the signal collapsing into static.
	var ramp_tw := create_tween()
	ramp_tw.tween_method(set_alpha, 0.20, 1.0, 1.8) \
		.set_trans(Tween.TRANS_EXPO).set_ease(Tween.EASE_IN)
	await ramp_tw.finished

	# Brief hold at peak so the warp tail isn't cut by the menu mount.
	await get_tree().create_timer(0.25).timeout

	var sl := get_tree().root.get_node_or_null(^"SceneLoader")
	if sl != null and sl.has_method(&"goto"):
		sl.call(&"goto", main_menu_path)
	else:
		get_tree().change_scene_to_file(main_menu_path)


# Build a single end-card BBCode line. Empty speaker = plain rest_text in the
# default green; populated speaker = uppercased + bolded + colored from
# VoicePortraits.
func _format_end_card_line(speaker: String, rest: String, portraits: Resource) -> String:
	if speaker.is_empty():
		return rest
	var color: Color = Color.WHITE
	if portraits != null and portraits.has_method(&"has_color") \
			and bool(portraits.call(&"has_color", speaker)):
		color = portraits.call(&"get_color", speaker) as Color
	var hex := color.to_html(false)
	return "[b][color=#%s]%s[/color][/b]%s" % [hex, speaker.to_upper(), rest]


# Debug — print player + camera pivot + camera positions and yaws so the
# user can read off the desired spawn pose. Strip this and the timer when
# level_5's spawn camera angle is finalized.
func _log_camera_pose() -> void:
	var player: Node3D = get_tree().get_first_node_in_group(&"player") as Node3D
	if player == null or not is_instance_valid(player):
		print("[L5-cam] (no player in tree)")
		return
	var pivot: Node3D = player.get_node_or_null(^"CameraPivot") as Node3D
	var cam: Node3D = player.get_node_or_null(^"CameraPivot/SpringArm3D/Camera3D") as Node3D
	var splice_z: float = _splice_npc.global_position.z if _splice_npc != null else 0.0
	if pivot == null or cam == null:
		print("[L5-cam] (player has no camera tree)")
		return
	print("[L5-cam] player=%s yaw=%.1f° | pivot=%s yaw=%.1f° | cam=%s yaw=%.1f° pitch=%.1f° | splice_z=%.2f" % [
		player.global_position.snappedf(0.01),
		rad_to_deg(float(player.get(&"_yaw_state"))),
		pivot.global_position.snappedf(0.01),
		rad_to_deg(pivot.global_rotation.y),
		cam.global_position.snappedf(0.01),
		rad_to_deg(cam.global_rotation.y),
		rad_to_deg(cam.global_rotation.x),
		splice_z,
	])
