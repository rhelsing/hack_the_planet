class_name SceneSetupOnFlag extends Node

## Generic "stage the world for a beat" node. Listens for a configured
## GameState flag and, when it flips true, applies a bundle of one-shot
## world-setup actions: teleport the player, spawn a fixed crew of allies
## at marker positions, and disable interactable colliders (rails, etc.).
##
## Used by the L4 Splice showdown to hard-stage the scene the moment
## Splice says the player's handle — golds appear in posed positions, the
## player snaps to a fixed spot in front of Splice, the rail closest to
## the halfpipe goes inert so the player can't slide off mid-monologue.
##
## Single-shot. After firing, disconnects and stays inert for the rest
## of the level. No "undo" — pawns + position changes are permanent for
## the session.

## Flag we listen for. When this flag flips true on GameState, fire().
@export var listen_flag: StringName = &""

@export_group("Player")
## Where to teleport the player when the flag fires. Empty = no teleport.
@export var player_teleport_target: NodePath

@export_group("Allies")
## Group of Marker3Ds that mark spawn positions for staged allies. Every
## marker in the group gets one `ally_pawn_scene` instance positioned at
## its world location, then converted to faction "gold". Existing nodes
## in the global "allies" group are queue_free'd first so the staged
## crew is exactly the marker count regardless of how many allies the
## player had before. Empty group OR null scene = staging disabled.
@export var ally_marker_group: StringName = &""
@export var ally_pawn_scene: PackedScene = null
## When true, each spawned ally toggles into its skate (rollerblade)
## profile after gold conversion — pawn_template starts in walk mode by
## convention, so one toggle puts them in skate. Defaults to false to
## preserve existing behavior; turn on for staged crews that should
## roll-with-the-runner instead of walking. Used by L4 Splice showdown
## to give the staged ally posse rollerblades.
@export var ally_skate_mode: bool = false

@export_group("Disable on fire")
## Rails (Path3D + child Area3D) whose body_entered detection should be
## switched off. Mesh stays visible; player just can't grind onto them.
@export var rails_to_disable: Array[NodePath] = []


var _fired: bool = false


func _ready() -> void:
	if listen_flag == &"":
		return
	if bool(GameState.get_flag(listen_flag, false)):
		# Already armed from a prior session — fire immediately.
		_fire()
		return
	Events.flag_set.connect(_on_flag_set)


func _on_flag_set(id: StringName, value: Variant) -> void:
	if _fired:
		return
	if id != listen_flag:
		return
	if not bool(value):
		return
	_fire()


func _fire() -> void:
	if _fired:
		return
	_fired = true
	_teleport_player()
	_stage_allies()
	_disable_rails()
	# Disconnect so we never re-react if someone re-fires the flag later.
	if Events.flag_set.is_connected(_on_flag_set):
		Events.flag_set.disconnect(_on_flag_set)


func _teleport_player() -> void:
	if player_teleport_target.is_empty():
		return
	var target: Node3D = get_node_or_null(player_teleport_target) as Node3D
	if target == null:
		push_warning("SceneSetupOnFlag: player_teleport_target not Node3D: %s" % player_teleport_target)
		return
	var player: Node3D = get_tree().get_first_node_in_group(&"player") as Node3D
	if player == null:
		return
	# Position-only teleport. Marker may have non-identity scale (authoring
	# convenience); copying full transform would distort the player's
	# CharacterBody3D. Rotation copied separately so the player faces the
	# direction the marker points.
	player.global_position = target.global_position
	player.global_rotation = target.global_rotation


func _stage_allies() -> void:
	if ally_marker_group == &"" or ally_pawn_scene == null:
		return
	# Clear existing allies. Snapshot first so freeing mid-iteration can't
	# trip the "already-freed" trap on typed loops.
	var to_free: Array[Node] = []
	for ally: Node in get_tree().get_nodes_in_group(&"allies"):
		if is_instance_valid(ally):
			to_free.append(ally)
	for ally: Node in to_free:
		ally.queue_free()
	# Spawn one per marker into the level scene root so the new pawns
	# don't get cleaned up if this node is ever despawned.
	var parent: Node = get_tree().current_scene
	if parent == null:
		return
	for marker: Node in get_tree().get_nodes_in_group(ally_marker_group):
		if not (marker is Node3D):
			continue
		var pawn: Node = ally_pawn_scene.instantiate()
		parent.add_child(pawn)
		if pawn is Node3D:
			# Position-only — marker scale/rotation is authoring metadata,
			# not pawn pose. Pawns spawn upright with identity scale.
			(pawn as Node3D).global_position = (marker as Node3D).global_position
		# Pawn template is a red minion; convert immediately so it joins
		# the player rather than fights them. Deferred so PlayerBody._ready
		# completes before set_faction reconfigures brain/buffs.
		if pawn.has_method(&"set_faction"):
			pawn.call_deferred(&"set_faction", &"gold")
		# Optional: flip the pawn into skate (rollerblade) mode. Toggle is
		# called AFTER set_faction so brain/skin reconfiguration is done.
		# pawn_template starts in walk mode → one toggle = skate. Idempotent
		# only under that assumption; if a future template defaults to skate
		# this would un-toggle them.
		if ally_skate_mode and pawn.has_method(&"toggle_profile"):
			pawn.call_deferred(&"toggle_profile")


func _disable_rails() -> void:
	for path in rails_to_disable:
		var rail: Node = get_node_or_null(path)
		if rail == null:
			continue
		var area: Area3D = rail.get_node_or_null("Area3D") as Area3D
		if area != null:
			area.monitoring = false
