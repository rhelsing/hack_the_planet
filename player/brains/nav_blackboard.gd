class_name NavBlackboard
extends Node

## Shared squad knowledge — the coordination layer of the nav stack
## (docs/nav_stack.md). One node per squad, placed in the level (or spawned
## at runtime); brains find it by matching `group` against their
## `squad_group` export. THE OFF-SWITCH IS STRUCTURAL: no board in the
## tree, `enabled = false`, or an empty squad_group on the brain all mean
## every caller gets solo semantics — provably identical to pre-blackboard
## behavior (the existing brain test suite runs board-less and must always
## pass unchanged).
##
## v1 scope: engage claims (kills the doorway pile-up — unclaimed pawns
## hold a standoff perimeter), shared last-known-position (the squad hunts
## one truth, not N private copies), stateless search-spread offsets
## (investigators fan out instead of converging), and a squad alert level
## (readable by barks/HUD; not yet coupled to behavior).
##
## Portable by construction: group names are config strings, claimants are
## duck-typed Nodes, zero game references.

## Squad this board serves — brains with a matching `squad_group` join.
@export var group: StringName = &""
## Live kill-switch: disabled boards answer with solo semantics (claims
## always granted, no shared LKP, zero offsets). Registered on the debug
## panel for mid-run A/B when one exists.
@export var enabled: bool = true
## How many squad members may actively engage one target; the rest hold
## the standoff perimeter until a slot frees (death/target-loss rotates
## the next pawn in automatically via claim pruning).
@export var max_engagers_per_target: int = 2
## Shared LKP older than this (seconds) is stale — squad forgets.
@export var lkp_max_age: float = 12.0
## Squad alert decays this much per second (slower than personal memory —
## the AREA stays tense after individuals calm down).
@export var alert_decay_per_sec: float = 0.1

const _GROUP_TAG: StringName = &"nav_blackboards"

# target instance_id -> Array[int] of claimant instance_ids.
var _claims: Dictionary = {}
var _lkp: Vector3 = Vector3.INF
var _lkp_at_ms: int = -1
var _alert: float = 0.0
var _alert_at_ms: int = 0


func _ready() -> void:
	add_to_group(_GROUP_TAG)
	if group == &"":
		push_warning("NavBlackboard %s: empty group — no squad will find it" % get_path())
	_register_debug_panel()


## Find the board serving `squad_group`, or null (null = solo, by design).
static func find_for(tree: SceneTree, squad_group: StringName) -> NavBlackboard:
	if squad_group == &"" or tree == null:
		return null
	for n: Node in tree.get_nodes_in_group(_GROUP_TAG):
		if n is NavBlackboard and (n as NavBlackboard).group == squad_group:
			return n
	return null


# ── Engage claims ──────────────────────────────────────────────────────────

## May `claimant` actively engage `target`? Already-claimants renew for
## free; otherwise a slot must be open. Dead claimants are pruned on every
## call, so a slot frees the moment its holder dies or despawns.
func claim_engage(claimant: Node, target: Node) -> bool:
	if not enabled:
		return true  # solo semantics
	if claimant == null or target == null:
		return true
	var tid: int = target.get_instance_id()
	var holders: Array = _pruned_holders(tid)
	var cid: int = claimant.get_instance_id()
	if cid in holders:
		return true
	if holders.size() < max_engagers_per_target:
		holders.append(cid)
		_claims[tid] = holders
		return true
	return false


## Drop every claim `claimant` holds (call on target loss).
func release_engage(claimant: Node) -> void:
	if claimant == null:
		return
	var cid: int = claimant.get_instance_id()
	for tid: int in _claims.keys():
		(_claims[tid] as Array).erase(cid)


func _pruned_holders(tid: int) -> Array:
	var holders: Array = _claims.get(tid, [])
	var alive: Array = []
	for cid: int in holders:
		if is_instance_valid(instance_from_id(cid)):
			alive.append(cid)
	_claims[tid] = alive
	return alive


# ── Shared last-known position ─────────────────────────────────────────────

func report_lkp(pos: Vector3) -> void:
	if not enabled:
		return
	_lkp = pos
	_lkp_at_ms = Time.get_ticks_msec()


## The squad's freshest known target position, or Vector3.INF when stale/
## disabled/never-reported (INF = "you're on your own", matching solo).
func squad_lkp() -> Vector3:
	if not enabled or _lkp_at_ms < 0:
		return Vector3.INF
	if (Time.get_ticks_msec() - _lkp_at_ms) / 1000.0 > lkp_max_age:
		return Vector3.INF
	return _lkp


# ── Search spread ──────────────────────────────────────────────────────────

## Stateless per-claimant offset: hashes the claimant's identity to a stable
## angle so squad members approach the same point from DIFFERENT directions
## (fan-out search / standoff perimeter) with zero claim bookkeeping.
func search_offset_for(claimant: Node, radius: float) -> Vector3:
	if not enabled or claimant == null or radius <= 0.0:
		return Vector3.ZERO
	var angle: float = float(claimant.get_instance_id() % 628) / 100.0  # 0..TAU
	return Vector3(cos(angle) * radius, 0.0, sin(angle) * radius)


# ── Squad alert (readable state; behavior coupling comes later) ────────────

func report_alert(level: float) -> void:
	if not enabled:
		return
	_alert = clampf(maxf(squad_alert(), level), 0.0, 1.0)
	_alert_at_ms = Time.get_ticks_msec()


## Current squad alertness with lazy decay — no per-frame work.
func squad_alert() -> float:
	if not enabled:
		return 0.0
	var elapsed: float = (Time.get_ticks_msec() - _alert_at_ms) / 1000.0
	return maxf(0.0, _alert - alert_decay_per_sec * elapsed)


func _register_debug_panel() -> void:
	var panel: Node = get_node_or_null(^"/root/DebugPanel")
	if panel == null or not panel.has_method(&"add_toggle"):
		return
	panel.call(&"add_toggle", "Nav/Squad/%s enabled" % group,
		func() -> bool: return enabled,
		func(v: bool) -> void: enabled = v,
		"nav_blackboard.gd")
