@tool
class_name PhoneBooth extends Node3D

## Drag the buildings shader material here to use a different active look
## without editing the scene subresource. Defaults to the project's
## res://level/buildings.tres via the scene.
@export var active_material: Material

## Notification sound played when this booth transitions to the active
## checkpoint. Played as a 2D AudioStreamPlayer on the SFX bus so it reads
## as UI feedback regardless of camera distance. Re-touching an already-
## active booth does NOT replay (gated by _was_active).
@export var active_sound: AudioStream = preload("res://audio/sfx/checkpoint_active.mp3")
@export_range(-30.0, 12.0) var active_sound_volume_db: float = 0.0

## Optional: when this booth activates (live touch OR continue-from-save
## spawn at this position), arm the CutscenePlayer at the given path
## after `arm_delay` seconds. Empty NodePath = no cutscene wiring.
##
## Session-once semantics: if `session_played_flag` is set in
## GameState.session_flags (in-memory only, not serialized), the cutscene
## is NOT armed — same-session re-entries (death/respawn at this
## checkpoint) skip silently. Game restart wipes the session_flags dict
## (autoload re-init) so continue-from-save replays the cutscene.
@export_group("Cutscene trigger")
@export var on_activate_arm_cutscene: NodePath
@export_range(0.0, 10.0, 0.1) var arm_delay: float = 1.0
@export var session_played_flag: StringName = &""

## Persistent flag set on GameState the first time the player enters this
## booth's trigger. Empty = no flag (default — every existing booth in the
## game leaves it empty). Used by chained beacon UI: Booth A's persist_flag
## becomes Booth B's beacon `visible_when_flag`, so each activation lights
## up the next marker. Symmetric to Walkie's persist_flag and WallCage's
## spawned_flag — same pattern, different sub-system.
@export var persist_flag: StringName = &""

@onready var _activation_block: MeshInstance3D = get_node_or_null("ActivationBlock")

var _active_sound_player: AudioStreamPlayer
var _was_active: bool = false


func _ready() -> void:
	if Engine.is_editor_hint():
		return
	add_to_group("phone_booths")
	# Start hidden — the block only appears (with building material) once the
	# player activates this booth as their checkpoint. Kept visible in the
	# editor so you can position it; toggled off at runtime startup.
	if _activation_block != null:
		_activation_block.visible = false
	# 2D notification player — same pattern as warp/coin clicks (see audio.gd
	# _make_player). Bus is SFX so master+sfx volume settings apply.
	_active_sound_player = AudioStreamPlayer.new()
	_active_sound_player.bus = &"SFX"
	add_child(_active_sound_player)
	var area: Area3D = get_node_or_null("Area3D")
	if area != null:
		area.body_entered.connect(_on_body_entered)
		# Continue-from-save case: the player teleports INSIDE this Area3D
		# rather than crossing its boundary, so body_entered would never
		# fire. After one physics frame, walk the overlap set and synthesize
		# the entry. No-op on fresh-load when no player exists yet, no-op
		# on level-load where the player spawned elsewhere.
		_check_initial_overlap.call_deferred(area)


func _check_initial_overlap(area: Area3D) -> void:
	if not is_instance_valid(area):
		return
	await get_tree().physics_frame
	if not is_instance_valid(area):
		return
	for body: Node3D in area.get_overlapping_bodies():
		if body.is_in_group("player"):
			_on_body_entered(body)
			return


func _on_body_entered(body: Node3D) -> void:
	# Only the player banks checkpoints — if an enemy wanders through a booth
	# it shouldn't move the player's respawn point to wherever the enemy was.
	if not body.is_in_group("player"):
		return
	Events.checkpoint_reached.emit(global_position)
	_activate()
	_maybe_fire_cutscene()
	if persist_flag != &"":
		GameState.set_flag(persist_flag, true)


func _maybe_fire_cutscene() -> void:
	if on_activate_arm_cutscene.is_empty():
		return
	# Same-session guard. We set the session flag IMMEDIATELY (before the
	# delay timer) so a second body_entered during the 1s window can't
	# double-arm. The flag is in-memory only — death+respawn keeps it set
	# (no replay), but game restart / continue-from-save wipes it (replay).
	if session_played_flag != &"" \
			and bool(GameState.session_flags.get(session_played_flag, false)):
		return
	if session_played_flag != &"":
		GameState.session_flags[session_played_flag] = true
	_arm_after_delay.call_deferred()


func _arm_after_delay() -> void:
	if arm_delay > 0.0:
		await get_tree().create_timer(arm_delay).timeout
	if not is_inside_tree():
		return
	var cs: Node = get_node_or_null(on_activate_arm_cutscene)
	if cs == null:
		push_warning("PhoneBooth: cutscene path not found: %s" % on_activate_arm_cutscene)
		return
	if cs.has_method(&"arm"):
		cs.call(&"arm")


func _activate() -> void:
	# One active checkpoint at a time: clear every other booth, then light us up.
	for other: Node in get_tree().get_nodes_in_group("phone_booths"):
		if other is PhoneBooth and other != self:
			(other as PhoneBooth)._set_active(false)
	_set_active(true)


func _set_active(active: bool) -> void:
	if _activation_block == null:
		return
	# Detect the false→true transition before flipping state — that's the
	# only moment the notification should fire.
	var newly_active: bool = active and not _was_active
	_was_active = active
	_activation_block.visible = active
	if active and active_material != null:
		_activation_block.set_surface_override_material(0, active_material)
	if newly_active and active_sound != null and _active_sound_player != null:
		_active_sound_player.stream = active_sound
		_active_sound_player.volume_db = active_sound_volume_db
		_active_sound_player.play()
