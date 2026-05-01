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

## Player's forced walk direction in WORLD space (Y is stripped). Default
## -Z = standard "into the corridor". Flip if you mirror the level layout.
@export var walk_direction: Vector3 = Vector3(0, 0, -1)
## Splice's pace. The player has no independent velocity in this scene —
## per-frame we snap them to a fixed offset behind Splice, so Splice's
## speed IS the cinematic's pace.
@export var splice_walk_speed_mps: float = 1.35
## How far behind Splice (along walk_direction) the player rides. Tune
## by feel; with Splice at 2x scale, 8u keeps him filling frame nicely
## without the camera being inside his body.
@export var follow_distance: float = 8.0
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
	# Wire the end terminal.
	var end_area: Area3D = get_node_or_null(^"EndTerminal") as Area3D
	if end_area != null:
		end_area.body_entered.connect(_on_end_entered)
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


func _process(delta: float) -> void:
	if _ended or _splice_npc == null:
		return
	var dir := walk_direction
	dir.y = 0.0
	if dir.length_squared() < 0.0001:
		return
	dir = dir.normalized()
	# Splice walks indefinitely. The cinematic ends when the cutscene's
	# `ended` signal fires (wired in _arm_walk_cutscene_after_delay) — at
	# that point _show_end_card runs the fade-to-black + main-menu transit.
	if _splice_walking:
		_splice_npc.global_position += dir * splice_walk_speed_mps * delta
	# Player rides a fixed offset behind Splice every frame. No physics
	# fight, no velocity drift, no save-load race — Splice's transform IS
	# the cinematic. Camera mouse-look still rotates the camera_pivot
	# (which is parented to player_body, so it tracks this position).
	if _player != null and is_instance_valid(_player):
		_player.global_position = _splice_npc.global_position \
			- dir * follow_distance \
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
	_show_end_card()


func _on_end_entered(body: Node) -> void:
	if _ended:
		return
	if not body.is_in_group(&"player"):
		return
	_ended = true
	_show_end_card()


func _show_end_card() -> void:
	# Build a black-fade overlay + end-card label as a CanvasLayer so we don't
	# need a pre-authored UI scene. Lives for `end_card_hold_s` then changes
	# to the main menu.
	var layer := CanvasLayer.new()
	layer.layer = 100
	add_child(layer)
	var bg := ColorRect.new()
	bg.color = Color(0, 0, 0, 0)
	bg.anchor_right = 1.0
	bg.anchor_bottom = 1.0
	layer.add_child(bg)
	var lbl := Label.new()
	lbl.text = "DIALTONE: DISCONNECTED.\nNYX: DISCONNECTED.\nGLITCH: OFFLINE.\n\nTHE GIBSON IS YOURS.\nPOPULATION: 1."
	lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	lbl.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	lbl.anchor_right = 1.0
	lbl.anchor_bottom = 1.0
	lbl.add_theme_font_size_override(&"font_size", 48)
	lbl.add_theme_color_override(&"font_color", Color(0.8, 1.0, 0.8, 1.0))
	lbl.modulate.a = 0.0
	layer.add_child(lbl)
	var tw := create_tween().set_parallel(true)
	tw.tween_property(bg, "color", Color(0, 0, 0, 1), 1.0)
	tw.tween_property(lbl, "modulate:a", 1.0, 1.5)
	await tw.finished
	await get_tree().create_timer(end_card_hold_s).timeout
	# Reset the betrayed flag so a new run isn't permanently locked. The save
	# slot still holds it; New Game from main menu wipes via begin_new_game.
	var sl := get_tree().root.get_node_or_null(^"SceneLoader")
	if sl != null and sl.has_method(&"goto"):
		sl.call(&"goto", main_menu_path)
	else:
		get_tree().change_scene_to_file(main_menu_path)
