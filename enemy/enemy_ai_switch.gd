class_name EnemyAiSwitch
extends Node
## Level-wide toggle between the OLD lunge AI (EnemyAIBrain) and the NEW nav
## stack (NavBrain). Flip `use_new_ai` — in the inspector or right here — to
## swap every enemy in the level this node lives under.
##
## Why a WHOLE-scene swap (not just a brain swap): the new AI needs a
## NavigationAgent3D child for navmesh pathing + RVO crowd avoidance, plus a
## jump_horizontal_boost tune. Those live in the `*_nav.tscn` wrappers, NOT in
## the plain enemy scenes. Swapping only the brain gives nav BRAINS with no nav
## LEGS — NavSteering finds no agent and beelines in a straight line (through
## walls, off ledges, zero spacing). So we replace the whole node with its nav
## twin, which carries the agent, jump boost, and (stealth) cone + alert tint.
##
## Safe to re-instance: every system that touches enemies finds them by GROUP
## ("enemies" / "splice_enemies"), never by node path — the twins rejoin the
## same groups on _ready. Per-instance data on the placed enemies is only
## `transform`, which we copy across.
##
## Timing: the swap runs deferred (call_deferred) so we're not adding children
## to the level root while it's still setting up its own children (the "parent
## is busy setting up children" error). The old nodes tick their old brain for
## one frame, then queue_free as the twins take over — invisible in practice.
##
## Unlisted scenes are left alone — the player and any already-nav enemy are
## never touched.

## The single switch. true = new nav AI, false = old lunge AI.
@export var use_new_ai: bool = true

## Old enemy scene path → nav-twin scene path. Covers BOTH placed enemies
## (whole-node replacement) and spawners (enemy_scene remap).
const NAV_TWIN_FOR_ENEMY := {
	"res://enemy/enemy_kaykit.tscn": "res://enemy/enemy_kaykit_nav.tscn",
	"res://enemy/enemy_kaykit_splice.tscn": "res://enemy/enemy_kaykit_splice_nav.tscn",
	"res://enemy/enemy_kaykit_splice_stealth.tscn": "res://enemy/enemy_kaykit_stealth_nav.tscn",
}


func _ready() -> void:
	if not use_new_ai:
		print("[EnemyAiSwitch] new AI OFF — enemies keep their authored (old) brains")
		return
	call_deferred(&"_apply")


func _apply() -> void:
	var root := get_parent()
	if root == null:
		push_error("EnemyAiSwitch: no parent to scan — place it as a child of the level root")
		return
	var swapped := 0
	var spawners := 0
	# Snapshot first: we mutate the tree (add twins, free old) as we go, so we
	# iterate a frozen list rather than a live walk.
	for node in _all_descendants(root):
		if not is_instance_valid(node):
			continue
		if node is PlayerBody:
			var nav_path: String = NAV_TWIN_FOR_ENEMY.get((node as Node).scene_file_path, "")
			if nav_path != "":
				_swap_enemy(node as PlayerBody, nav_path)
				swapped += 1
		elif node is EnemySpawner:
			var src: PackedScene = (node as EnemySpawner).enemy_scene
			if src != null:
				var sp: String = NAV_TWIN_FOR_ENEMY.get(src.resource_path, "")
				if sp != "":
					(node as EnemySpawner).enemy_scene = load(sp)
					spawners += 1
	print("[EnemyAiSwitch] new AI ON — swapped %d placed enemies + %d spawners to nav twins" % [
		swapped, spawners])


## Replace one placed enemy with its nav twin at the same world transform.
func _swap_enemy(old: PlayerBody, nav_path: String) -> void:
	var scene: PackedScene = load(nav_path)
	if scene == null:
		push_error("EnemyAiSwitch: could not load nav twin %s" % nav_path)
		return
	var parent := old.get_parent()
	var world_xform: Transform3D = old.global_transform
	var enemy_name: String = old.name
	old.name = enemy_name + "_replaced"  # free the name for the twin
	old.queue_free()
	var twin: Node = scene.instantiate()
	parent.add_child(twin)
	if twin is Node3D:
		(twin as Node3D).global_transform = world_xform
	twin.name = enemy_name


func _all_descendants(node: Node) -> Array[Node]:
	var out: Array[Node] = []
	for child in node.get_children():
		out.append(child)
		out.append_array(_all_descendants(child))
	return out


# TEMP DEBUG — group-behavior probe. Every 0.5s while any enemy is in combat,
# print the state histogram + how many CHASE/WIND_UP pawns are stalled (near-
# zero velocity). Reads:
#   states oscillate CHASE<->WIND_UP together  -> attack-cooldown / wind-up sync
#   stable CHASE but high 'stalled'            -> RVO crowd-jam on the standoff ring
# Strip after diagnosing the fight/pause pulse.
var _probe_accum: float = 0.0

func _process(delta: float) -> void:
	if not use_new_ai:
		return
	_probe_accum += delta
	if _probe_accum < 0.5:
		return
	_probe_accum = 0.0
	var counts: Dictionary = {}
	var reasons: Dictionary = {}
	var in_combat: int = 0
	var stalled: int = 0
	var vel_sum: float = 0.0
	var player_vel: float = 0.0
	for node in _all_descendants(get_tree().root):
		if not (node is PlayerBody):
			continue
		if (node as PlayerBody).pawn_group == "player":
			player_vel = (node as CharacterBody3D).velocity.length()
			continue
		var brain: Node = null
		for c in (node as Node).get_children():
			if c is NavBrain:
				brain = c
				break
		if brain == null:
			continue
		var view: Dictionary = brain.call(&"perception_view") as Dictionary
		var st: String = String(view.get("state", "?"))
		counts[st] = int(counts.get(st, 0)) + 1
		if st == "CHASE" or st == "WIND_UP":
			in_combat += 1
			var v: float = (node as CharacterBody3D).velocity.length()
			vel_sum += v
			if v < 0.4:
				stalled += 1
				var why: String = String(view.get("stall", "?"))
				reasons[why] = int(reasons.get(why, 0)) + 1
	if in_combat > 0:
		print("[grp-probe] inCombat=%d stalled=%d why=%s avgVel=%.1f playerVel=%.1f states=%s" % [
			in_combat, stalled, reasons, vel_sum / maxf(in_combat, 1), player_vel, counts])
