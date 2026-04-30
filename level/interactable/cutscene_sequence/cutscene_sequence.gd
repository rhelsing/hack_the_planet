extends Node
class_name CutsceneSequence

## Two-shot cinematic sequence. Triggered by `arm_flag`. Sequence:
##   1. Save the current gameplay camera, freeze the player (optional),
##      pause music, kick off `cutscene_music` (optional).
##   2. Cut to `shot1_camera`. Optionally tween its transform to
##      `shot1_pan_to` over `shot1_pan_duration`. Play `shot1_lines`
##      sequentially (each line waits on its channel's `line_ended`).
##   3. Cut to `shot2_camera`, same options for pan + lines.
##   4. Restore gameplay camera, unfreeze player, resume default music,
##      set `done_flag` (if any).
##
## Lines are configured as [{character: StringName, text: String, channel:
## StringName}], where channel is "walkie" or "companion". Each line plays
## via that autoload and we await its `line_ended` before the next.
##
## Drop this as a child of the level scene. Exports configured per-shot.
## Camera node paths point at Camera3D nodes you place in the level;
## pan-to paths point at optional Marker3D children of the camera.

@export var arm_flag: StringName = &""
@export var done_flag: StringName = &""
@export var fire_once: bool = true
## Optional flag that aborts the dialogue walk early. Checked between
## lines and at the start of each wait — set during the run to cut a
## background-dialogue sequence short (e.g. "battle ended early; stop
## the radio chatter"). The walk exits cleanly: shot 3 wrap-up still
## runs, music swap-out runs, done_flag still fires.
@export var stop_flag: StringName = &""

@export_group("Player")
@export var freeze_player: bool = true

@export_group("Camera Drift")
## Total seconds for any CameraDrift children of the cameras. When the
## cutscene starts, every CameraDrift descendant of the listed shot
## cameras has its `duration` set to this value and is kicked off in
## parallel — so the cameras drift across the whole scene regardless of
## which shot is currently being viewed.
@export var scene_duration: float = 30.0

@export_group("Music")
## One-shot stinger played at the very start of the cutscene as a SEQUENCED
## step — sequence awaits its `finished` signal before kicking off
## `cutscene_music` and the first shot. Empty = no stinger.
@export var intro_stinger: AudioStream
## Bus the stinger plays through. SFX so it follows standard sidechain
## ducking; in practice nothing overlaps the stinger because it's a
## sequenced step, but the bus assignment still drives volume slider routing.
@export var intro_stinger_bus: StringName = &"SFX"
## Looped while the cutscene plays. Starts AFTER the stinger ends. Empty
## = keep current music (no swap).
@export var cutscene_music: AudioStream
## When true, `Audio.resume_default_playlist_if_overridden()` is called on
## sequence end so gameplay returns to the default rotation.
@export var resume_default_music_on_end: bool = true

@export_group("Dialogue")
## DialogueResource (.dialogue file) that drives the script. Lines are
## walked sequentially via DialogueResource.get_next_dialogue_line. Each
## line whose text contains `[#walkie]` plays via Walkie; others via
## Companion. Text emphasis (`*x*`, `**x**`) and tokens (`{player_handle}`)
## are resolved by the existing TTS pipeline.
##
## Shot transitions: emit `do CutsceneSequence.set_shot(N)` mutations in
## the dialogue file. N is 1-based and indexes into `shot_cameras`.
@export var dialogue_file: Resource
@export var dialogue_start: String = "start"
## Cameras that `set_shot(N)` cuts between. shot_cameras[0] = shot 1, etc.
@export var shot_cameras: Array[NodePath] = []

var _fired: bool = false
var _saved_camera: Camera3D = null
var _saved_player_physics: bool = true
var _saved_player: Node3D = null


func _ready() -> void:
	if arm_flag == &"":
		return
	if bool(GameState.get_flag(arm_flag, false)):
		_fired = true  # already past this beat on reload
		return
	Events.flag_set.connect(_on_flag_set)


func _on_flag_set(id: StringName, value: Variant) -> void:
	if _fired and fire_once: return
	if id != arm_flag: return
	if not bool(value): return
	_fired = true
	_run.call_deferred()


## Coroutine: walks the sequence from start to finish.
##   1. Save camera + freeze player.
##   2. Cut to shot 1's camera immediately so the stinger lands ON the shot.
##   3. Play stinger to completion (sequenced — no overlap).
##   4. Start looped cutscene music.
##   5. Play shot 1's lines, then shot 2 (with pan + lines).
##   6. Restore music, camera, player; set done flag.
func _run() -> void:
	_save_camera_and_freeze()
	# Cut to shot 1's camera first so the stinger lands while we're already
	# framed correctly — not on the gameplay camera. Skip when the sequence
	# has no shot cameras (e.g. background-dialogue mode for battle radio
	# chatter where gameplay camera should keep rendering).
	if not shot_cameras.is_empty():
		set_shot(1)
	# Kick off CameraDrift descendants so they advance through their
	# authored trajectories for the whole sequence, regardless of which
	# shot is currently being viewed.
	_kick_camera_drifts()
	await _play_stinger()
	_swap_music_in()
	if dialogue_file != null:
		await _walk_dialogue()
	# Force cameras to their endpoints in case dialogue ran longer than
	# scene_duration would have taken to finish drifting on its own.
	_finalize_camera_drifts()
	_swap_music_out()
	_restore_camera_and_unfreeze()
	if done_flag != &"":
		GameState.set_flag(done_flag, true)


## Pause the dialogue walk for `seconds`. Called by dialogue mutations:
##   do CutsceneSequence.wait(7)
## Used to pace background-dialogue beats — e.g. 10-second-cadence battle
## radio banter where you want gaps between lines, not back-to-back chatter.
## Skipped immediately if `stop_flag` is already set (the walk is being
## aborted), so a stop fires through any pending pauses.
func wait(seconds: float) -> void:
	if seconds <= 0.0: return
	if _is_stopped(): return
	await get_tree().create_timer(seconds).timeout


func _is_stopped() -> bool:
	return stop_flag != &"" and bool(GameState.get_flag(stop_flag, false))


## Switch the active cinematic camera. Called by dialogue mutations:
##   do CutsceneSequence.set_shot(2)
## Also invoked at sequence start to land on shot 1 before the stinger.
## 1-based index into `shot_cameras` to match how authors think.
func set_shot(n: int) -> void:
	var idx: int = n - 1
	if idx < 0 or idx >= shot_cameras.size():
		push_warning("CutsceneSequence: shot %d out of range (%d cams)" % [n, shot_cameras.size()])
		return
	var cam: Camera3D = get_node_or_null(shot_cameras[idx]) as Camera3D
	if cam == null:
		push_warning("CutsceneSequence: shot %d camera not found at %s" % [n, shot_cameras[idx]])
		return
	cam.make_current()


## Walks every line of `dialogue_file` from `dialogue_start`. Each line
## dispatches via Walkie or Companion based on a `[#walkie]` tag in the
## line text. Mutations (`do …`) inside the file run before the next line
## resolves — that's how shot transitions land on the right beat.
func _walk_dialogue() -> void:
	var dm: Node = get_node_or_null(^"/root/DialogueManager")
	if dm == null or dialogue_file == null:
		push_warning("CutsceneSequence: no DialogueManager / dialogue_file")
		return
	# Pass `self` so `do CutsceneSequence.set_shot(...)` mutations resolve.
	var line: Object = await dialogue_file.call(&"get_next_dialogue_line", dialogue_start, [self])
	while line != null:
		if _is_stopped(): break
		var character: String = ""
		var text: String = ""
		if "character" in line: character = String(line.character)
		if "text" in line: text = String(line.text)
		if not text.strip_edges().is_empty():
			var channel: String = "companion"
			if text.contains("[#walkie]"):
				channel = "walkie"
				text = text.replace("[#walkie]", "").strip_edges()
			await _play_line(channel, character, text)
		var next_id: String = ""
		if "next_id" in line: next_id = String(line.next_id)
		if next_id.is_empty(): break
		line = await dialogue_file.call(&"get_next_dialogue_line", next_id, [self])


## Snap all CameraDrift descendants of any shot camera to their endpoints.
## Called at sequence end so a still-mid-drift camera lands at its
## authored final pose regardless of how long the dialogue ran.
func _finalize_camera_drifts() -> void:
	var seen: Dictionary = {}
	for path: NodePath in shot_cameras:
		if path.is_empty(): continue
		var cam: Node = get_node_or_null(path)
		if cam == null or seen.has(cam): continue
		seen[cam] = true
		for child: Node in cam.get_children():
			if child is CameraDrift:
				(child as CameraDrift).snap_to_end()


## Start every CameraDrift descendant of any distinct shot camera. Sets
## each drift's duration to `scene_duration` so trajectories spread over
## the expected cutscene length. Cameras that finish their drift early
## sit at end_position waiting; cameras that don't finish get snapped on
## sequence end via _finalize_camera_drifts.
func _kick_camera_drifts() -> void:
	var seen: Dictionary = {}
	for path: NodePath in shot_cameras:
		if path.is_empty(): continue
		var cam: Node = get_node_or_null(path)
		if cam == null or seen.has(cam): continue
		seen[cam] = true
		for child: Node in cam.get_children():
			if child is CameraDrift:
				(child as CameraDrift).duration = scene_duration
				(child as CameraDrift).start_drift()


## Plays the intro stinger as a discrete sequenced step. Returns when its
## `finished` signal fires. No-op if no stream is set.
func _play_stinger() -> void:
	if intro_stinger == null: return
	var player := AudioStreamPlayer.new()
	player.stream = intro_stinger
	player.bus = intro_stinger_bus
	add_child(player)
	player.play()
	await player.finished
	player.queue_free()


func _save_camera_and_freeze() -> void:
	_saved_camera = get_viewport().get_camera_3d()
	if freeze_player:
		_saved_player = get_tree().get_first_node_in_group(&"player") as Node3D
		if _saved_player != null:
			_saved_player_physics = _saved_player.is_physics_processing()
			_saved_player.set_physics_process(false)


func _restore_camera_and_unfreeze() -> void:
	if _saved_camera != null and is_instance_valid(_saved_camera):
		_saved_camera.make_current()
	if freeze_player and _saved_player != null and is_instance_valid(_saved_player):
		_saved_player.set_physics_process(_saved_player_physics)


func _swap_music_in() -> void:
	if cutscene_music != null:
		Audio.play_music(cutscene_music, 0.4)


func _swap_music_out() -> void:
	if resume_default_music_on_end and cutscene_music != null:
		# play_music marked the prior playlist as overridden — resume that.
		if Audio.has_method(&"resume_default_playlist_if_overridden"):
			Audio.call(&"resume_default_playlist_if_overridden")


## Plays one line on the chosen channel and awaits its line_ended.
func _play_line(channel: String, character: String, text: String) -> void:
	if channel == "walkie":
		Walkie.speak(character, text)
		await Walkie.line_ended
	else:
		Companion.speak(character, text)
		await Companion.line_ended
