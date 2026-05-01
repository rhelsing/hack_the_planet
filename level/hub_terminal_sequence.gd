extends Node3D

## Master gate for the hub's 5-puzzle sequence platform. Hides + makes
## everything under this node UNREACHABLE (no visual, no collision, no
## interaction sensor pickup) until `gate_flag` is true. Unlock fires
## once `level_4_completed` is set; from then on the chained
## PuzzleTerminals + Beacons drive the sequence-internal reveal logic
## via their own `visible_when_flag` listeners.
##
## Spec: docs/hub_terminal_sequence.md §C
##
## Why a parent gate (vs. a second `visible_when_flag_2` on PuzzleTerminal):
## the platform also has its own geometry (the floor itself), and the
## level-bound gate is a separate concern from the chain-internal gate.
## Keeping them on different nodes means the chain logic stays terminal-
## level and the level gate stays platform-level — composes cleanly.

@export var gate_flag: StringName = &"level_4_completed"
## Default Area3D collision_layer to restore on unlock. Matches the
## hacking_terminal.tscn authored value (512 = the InteractionSensor
## pickup layer). PuzzleTerminal._apply_visibility_gate then takes over
## and may zero this out per terminal if the chain says that terminal
## isn't ready yet.
@export var area_collision_layer_unlocked: int = 512

@export_group("Rise on flag")
## Optional second flag — the terminals (Area3D children) start lowered
## by `lower_amount` at scene load and tween back to their authored Y
## the moment this flag flips true on GameState. Independent from the
## visibility / collision gate above. Empty = no rise behavior; the
## terminals stay at their authored Y from frame zero.
@export var rise_flag: StringName = &""
## Y offset applied to each terminal at _ready when `rise_flag` is set
## and not already true. Tweened back to 0 on rise. Per-terminal local Y.
@export var lower_amount: float = 2.0
@export_range(0.05, 5.0) var rise_duration: float = 1.0

# Captured authored Y per terminal so the tween targets the original pose
# regardless of when the rise fires.
var _terminal_authored_y: Dictionary = {}
var _terminals_risen: bool = false


func _ready() -> void:
	_apply()
	_setup_rise()
	Events.flag_set.connect(_on_flag_set)


func _on_flag_set(id: StringName, value: Variant) -> void:
	if id == gate_flag:
		_apply()
	if id == rise_flag and bool(value) and not _terminals_risen:
		_rise_terminals()


# Snapshot each terminal child's authored Y, then drop them by
# `lower_amount` if the flag isn't already set. On a continued save where
# `rise_flag` is true, leave them at the authored Y and mark risen so
# nothing animates. Skipped entirely when `rise_flag` is empty.
func _setup_rise() -> void:
	if rise_flag == &"":
		return
	for child in get_children():
		if child is Area3D and child is Node3D:
			_terminal_authored_y[child] = (child as Node3D).position.y
	if bool(GameState.get_flag(rise_flag, false)):
		_terminals_risen = true
		return
	for terminal in _terminal_authored_y:
		(terminal as Node3D).position.y = _terminal_authored_y[terminal] - lower_amount


func _rise_terminals() -> void:
	_terminals_risen = true
	for terminal in _terminal_authored_y:
		var t: Node3D = terminal
		var target_y: float = _terminal_authored_y[terminal]
		var tw := create_tween()
		tw.tween_property(t, ^"position:y", target_y, rise_duration) \
			.set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)


func _apply() -> void:
	var unlocked: bool = bool(GameState.get_flag(gate_flag, false))
	visible = unlocked
	# Walk descendants once. Three node types matter:
	#   - CSGShape3D: platform geometry. use_collision off when locked so
	#     the player can't grapple onto an invisible floor pre-L4.
	#   - Area3D: PuzzleTerminal interaction sensors. Layer to 0 when
	#     locked; on unlock, restore the layer THEN call PuzzleTerminal's
	#     own _apply_visibility_gate so terminals 2-5 immediately re-zero
	#     themselves if their chain predecessor isn't solved.
	#   - Beacon: HUD overlays drawn through beacon_layer (a CanvasLayer),
	#     not the 3D scene tree — so the parent's `visible=false` cascade
	#     does NOT hide them. Force-hide on lock, refresh on unlock.
	for n in _walk(self):
		if n is CSGShape3D:
			(n as CSGShape3D).use_collision = unlocked
		elif n is Area3D:
			(n as Area3D).collision_layer = area_collision_layer_unlocked if unlocked else 0
			# PuzzleTerminal-derived terminals re-evaluate their chain
			# gate immediately so any with un-solved predecessors snap
			# back to layer=0 + visible=false. Without this, the master
			# unlock would briefly make the entire chain interactable.
			if unlocked and n.has_method(&"_apply_visibility_gate"):
				n.call(&"_apply_visibility_gate")
		elif n.has_method(&"refresh_flag_gates"):
			# Beacon — re-sync to chain state on unlock; force off on lock.
			if unlocked:
				n.call(&"refresh_flag_gates")
			else:
				n.call(&"set_beacon_visible", false)


# Flat descendant iteration — order doesn't matter, we just visit each
# node once and apply the toggle.
static func _walk(root: Node) -> Array:
	var out: Array = [root]
	for child in root.get_children():
		out.append_array(_walk(child))
	return out
