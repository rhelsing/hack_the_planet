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
## its world location, then converted to faction "gold". Empty group OR
## null scene = staging disabled. NOTE: this only spawns; if you want to
## clear existing allies first, set `despawn_group = &"allies"` on this
## node OR fire a separate SceneSetupOnFlag with despawn_group earlier in
## the timeline (preferred — see L4 splice showdown setup).
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

## When non-empty, every node in the named group is queue_free'd at fire
## time. Used by L4 post-PLANET-terminal beat to wipe remaining red
## sentinels (`splice_enemies` group) so the arena clears cleanly even if
## the player left some alive.
@export var despawn_group: StringName = &""

@export_group("Pawn freeze")
## When non-empty, every pawn spawned by `_stage_allies` is dropped in
## with `set_physics_process(false)` + `set_process(false)` on both the
## body AND its brain — so they sit statue-still at the marker pose.
## They thaw the moment this flag flips true on GameState. Canonical
## use: L4 Splice showdown — staged golds shouldn't path toward the
## player while the cutscene runs, so we hold them frozen and release
## on `l4_splice_cutscene_done`.
@export var freeze_pawns_until_flag: StringName = &""


var _fired: bool = false
# Pawns frozen at staging time. Walked + thawed when
# freeze_pawns_until_flag fires true. Cleared on thaw.
var _frozen_pawns: Array[Node] = []


func _ready() -> void:
	# Wire the unfreeze listener BEFORE we possibly _fire() — the listen-flag
	# may already be true on resume, and the freeze + immediate-thaw window
	# can overlap if both flags were set in a prior session. Putting the
	# unfreeze hook first guarantees we hear it.
	if freeze_pawns_until_flag != &"":
		Events.flag_set.connect(_on_unfreeze_flag_set)
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
	_despawn_group()
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
	print("[stage] _stage_allies fired — group=%s freeze_flag=%s" % [
		ally_marker_group, freeze_pawns_until_flag])
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
			# Position from the marker. Pawns spawn upright with identity scale,
			# but we DO consume the marker's Y rotation — authoring per-pawn
			# facing by rotating each marker in the editor.
			#
			# Yaw convention mirrors PlayerBody.snap_to_spawn (player_body.gd:
			# 1970): the marker's BLUE Z arrow (basis.z) points where the
			# pawn should face. yaw = Vector3.BACK.signed_angle_to(fwd, UP).
			#
			# Three writes are required for a frozen pawn:
			#   1. _yaw_state on the body — canonical "logical facing" field.
			#   2. _target_yaw + _last_input_direction — so post-thaw, the
			#      body doesn't lerp out of this pose toward a stale cache.
			#   3. _skin.rotation.y directly — the body's _physics_process
			#      normally rebuilds skin.transform from _yaw_state every
			#      tick, but we're about to freeze it before any tick runs.
			#      Without this mirror, the skin stays at identity rotation
			#      regardless of _yaw_state.
			var p3d: Node3D = pawn as Node3D
			p3d.global_position = (marker as Node3D).global_position
			var marker_fwd: Vector3 = (marker as Node3D).global_basis.z
			marker_fwd.y = 0.0
			var yaw: float = 0.0
			var fwd_norm: Vector3 = Vector3.BACK
			if marker_fwd.length_squared() > 0.0001:
				fwd_norm = marker_fwd.normalized()
				yaw = Vector3.BACK.signed_angle_to(fwd_norm, Vector3.UP)
			if "_yaw_state" in p3d:
				p3d.set(&"_yaw_state", yaw)
			if "_target_yaw" in p3d:
				p3d.set(&"_target_yaw", yaw)
			if "_last_input_direction" in p3d:
				p3d.set(&"_last_input_direction", fwd_norm)
			var skin_immediate: Variant = p3d.get(&"_skin") if "_skin" in p3d else null
			if skin_immediate != null and skin_immediate is Node3D:
				(skin_immediate as Node3D).rotation.y = yaw
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
		# Optional pawn freeze. Applied SYNCHRONOUSLY (not call_deferred) so
		# the pawn never gets a single physics tick of motion between
		# spawn and freeze. set_faction / toggle_profile run on the
		# deferred queue regardless of process_mode (call_deferred is a
		# direct method dispatch, not a process tick), so the pawn still
		# converts to gold + skate cleanly while frozen — those mutations
		# just don't take visible effect until the thaw.
		if freeze_pawns_until_flag != &"":
			_frozen_pawns.append(pawn)
			_freeze_pawn(pawn)


# Targeted freeze. Stops the body + brain from ticking (no physics
# integration, no Intent generation, no movement) but leaves the skin's
# AnimationTree running so the idle loop keeps breathing instead of
# slamming to the rest pose. We explicitly travel the skin to "Idle" once
# so it's in a known, animated state — without this, the skin freezes at
# whatever transient state the AnimationTree was in (often T-pose).
#
# NOTE: an earlier attempt used process_mode = PROCESS_MODE_DISABLED on
# the pawn root. That worked but propagated to the skin too, halting
# every animation including the idle. The targeted disable below is the
# better fit for "in idle pose, breathing" without giving up motion lock.
func _freeze_pawn(pawn: Node) -> void:
	if pawn == null or not is_instance_valid(pawn):
		return
	# Body — kill physics + idle process so move_and_slide / camera /
	# damage tint code can't run.
	if pawn is Node3D:
		(pawn as Node3D).set_physics_process(false)
		(pawn as Node3D).set_process(false)
	# Velocity zero — no latent motion to resume on thaw.
	if "velocity" in pawn:
		pawn.set(&"velocity", Vector3.ZERO)
	# Brain — duck-typed by `tick` (the Brain contract).
	for child: Node in pawn.get_children():
		if child.has_method(&"tick"):
			child.set_physics_process(false)
			child.set_process(false)
	# Skin — keep its process callbacks live (AnimationTree needs them)
	# and explicitly travel to Idle so it loops the breathing clip.
	var skin: Variant = pawn.get(&"_skin") if "_skin" in pawn else null
	if skin != null and skin is Node and is_instance_valid(skin) \
			and (skin as Node).has_method(&"idle"):
		(skin as Node).call(&"idle")
	print("[stage-freeze] %s body+brain disabled, skin -> idle" % pawn.get_path())


func _thaw_pawn(pawn: Node) -> void:
	if pawn == null or not is_instance_valid(pawn):
		return
	if pawn is Node3D:
		(pawn as Node3D).set_physics_process(true)
		(pawn as Node3D).set_process(true)
	for child: Node in pawn.get_children():
		if child.has_method(&"tick"):
			child.set_physics_process(true)
			child.set_process(true)
	print("[stage-thaw] %s body+brain re-enabled" % pawn.get_path())


func _on_unfreeze_flag_set(id: StringName, value: Variant) -> void:
	if id != freeze_pawns_until_flag or not bool(value):
		return
	print("[stage-thaw] flag %s fired — thawing %d pawns" % [id, _frozen_pawns.size()])
	for pawn: Node in _frozen_pawns:
		_thaw_pawn(pawn)
	_frozen_pawns.clear()
	if Events.flag_set.is_connected(_on_unfreeze_flag_set):
		Events.flag_set.disconnect(_on_unfreeze_flag_set)


func _despawn_group() -> void:
	if despawn_group == &"":
		return
	# Snapshot before freeing — typed loops over a dict whose Object refs
	# become invalid mid-iteration crash on the assignment to the loop var.
	var to_free: Array[Node] = []
	for n: Node in get_tree().get_nodes_in_group(despawn_group):
		if is_instance_valid(n):
			to_free.append(n)
	for n: Node in to_free:
		n.queue_free()


func _disable_rails() -> void:
	for path in rails_to_disable:
		var rail: Node = get_node_or_null(path)
		if rail == null:
			continue
		var area: Area3D = rail.get_node_or_null("Area3D") as Area3D
		if area != null:
			area.monitoring = false
