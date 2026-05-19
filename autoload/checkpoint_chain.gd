extends Node

## Optional sequencing layer on top of the phone-booth checkpoint system.
##
## When a booth activates, PhoneBooth.notify_chain() calls set_target() with
## the next booth in the chain and the GameState flag that gates its beacon.
## Each physics frame we measure distance(player, target), ratchet the closest-
## ever value, and if the player goes `stall_seconds` without setting a new
## closest, we LATCH the chain hint flag on. The next booth's Beacon picks
## that up via its visible_when_flag and renders the marker.
##
## Latch semantics: once the flag is set, the ratchet stops — the flag (and
## thus the beacon) stays on until the player actually reaches the next
## checkpoint, at which point that booth's own activation clears the flag and
## either arms the next link or ends the chain.

## Seconds the player can go without setting a new closest distance before
## the hint beacon latches on.
@export var stall_seconds: float = 10.0
## Distance dead-zone (units). A new "closest" must beat the prior best by
## at least this much to ratchet — prevents sub-meter jitter (landing,
## slope drift) from continuously resetting the timer.
@export var epsilon: float = 0.5
## Show live debug overlay in the bottom-left corner while tracking is active.
## Off by default — flip to true (here or via the inspector on CheckpointChain
## autoload) when iterating on the ratchet/stall tuning.
@export var debug_overlay: bool = false

var _target: Node3D = null
var _chain_flag: StringName = &""
var _best_distance: float = INF
var _last_progress_msec: int = 0
var _latched: bool = false

var _dbg_canvas: CanvasLayer
var _dbg_label: Label


func _ready() -> void:
	# Physics frame is plenty for a distance check — the player moves in
	# physics_process anyway, and we avoid running during paused state.
	set_physics_process(false)
	if debug_overlay:
		_build_debug_overlay()


## Called by PhoneBooth._activate when that booth has a next_checkpoint
## configured. `next` is the Node3D we measure distance to; `flag` is the
## GameState flag we latch on stall. Empty `flag` or null `next` clears
## any active tracking.
func set_target(next: Node3D, flag: StringName) -> void:
	# Idempotent: re-touching the SAME active booth re-fires this with the
	# same (target, flag) we're already tracking. Bailing out preserves the
	# ratchet AND any latched flag — without this guard, walking back into
	# the booth you came from clears the next booth's beacon.
	if next == _target and flag == _chain_flag:
		return
	# Clear the prior link's flag if we're switching — the new booth that
	# just activated IS the prior link's target, so we want its hint marker
	# to go away regardless of whether the latch fired.
	if _chain_flag != &"" and _chain_flag != flag:
		GameState.set_flag(_chain_flag, false)
	_target = next
	_chain_flag = flag
	_latched = false
	_best_distance = INF
	_last_progress_msec = Time.get_ticks_msec()
	if next == null or flag == &"":
		set_physics_process(false)
		print("[chain] cleared (no next)")
		return
	# Pre-clear the flag in case it was somehow set from a prior run.
	GameState.set_flag(flag, false)
	set_physics_process(true)
	print("[chain] tracking %s flag=%s stall=%.1fs eps=%.2f" % [
		next.name, flag, stall_seconds, epsilon])


func _physics_process(_delta: float) -> void:
	if _target == null or not is_instance_valid(_target):
		_refresh_debug_overlay(0.0, 0.0)
		return
	var player := _find_player()
	if player == null:
		return
	var current: float = player.global_position.distance_to(_target.global_position)
	if _latched:
		_refresh_debug_overlay(current, 0.0)
		return
	# Seed best on first valid sample so we don't carry an INF that the
	# next line would treat as "any current value is huge progress".
	if _best_distance == INF:
		_best_distance = current
		_last_progress_msec = Time.get_ticks_msec()
		_refresh_debug_overlay(current, 0.0)
		return
	if current + epsilon < _best_distance:
		_best_distance = current
		_last_progress_msec = Time.get_ticks_msec()
		_refresh_debug_overlay(current, 0.0)
		return
	var stall_ms: int = int(stall_seconds * 1000.0)
	var elapsed_ms: int = Time.get_ticks_msec() - _last_progress_msec
	if elapsed_ms >= stall_ms:
		_latched = true
		GameState.set_flag(_chain_flag, true)
		print("[chain] LATCH %s (best=%.1fu current=%.1fu stalled=%.1fs)" % [
			_chain_flag, _best_distance, current, stall_seconds])
	_refresh_debug_overlay(current, float(elapsed_ms) / 1000.0)


func _find_player() -> Node3D:
	for p in get_tree().get_nodes_in_group("player"):
		if p is Node3D:
			return p
	return null


# ── Debug overlay ────────────────────────────────────────────────────────

func _build_debug_overlay() -> void:
	_dbg_canvas = CanvasLayer.new()
	_dbg_canvas.layer = 90
	add_child(_dbg_canvas)
	_dbg_label = Label.new()
	_dbg_label.anchor_left = 0.0
	_dbg_label.anchor_right = 0.0
	_dbg_label.anchor_top = 1.0
	_dbg_label.anchor_bottom = 1.0
	# Bottom-left corner. Negative offset_top lifts the label up from the
	# bottom edge — ~110px tall block, 12px from the left/bottom margins.
	_dbg_label.offset_left = 12.0
	_dbg_label.offset_right = 360.0
	_dbg_label.offset_top = -132.0
	_dbg_label.offset_bottom = -12.0
	_dbg_label.add_theme_color_override(&"font_color", Color(0.85, 1.0, 0.85))
	_dbg_label.add_theme_color_override(&"font_outline_color", Color(0, 0, 0, 0.9))
	_dbg_label.add_theme_constant_override(&"outline_size", 4)
	_dbg_label.add_theme_font_size_override(&"font_size", 14)
	_dbg_label.text = ""
	_dbg_label.visible = false
	_dbg_canvas.add_child(_dbg_label)


func _refresh_debug_overlay(current: float, elapsed_s: float) -> void:
	if _dbg_label == null:
		return
	if _target == null or not is_instance_valid(_target):
		_dbg_label.visible = false
		return
	_dbg_label.visible = true
	var best_str: String = "—" if _best_distance == INF else "%.1fu" % _best_distance
	var state_str: String = "LATCHED" if _latched else "armed"
	_dbg_label.text = "[chain] %s\ntarget   %s\nflag     %s\ncurrent  %.1fu\nbest     %s\nstall    %.1fs / %.1fs" % [
		state_str,
		_target.name,
		_chain_flag,
		current,
		best_str,
		elapsed_s, stall_seconds,
	]
