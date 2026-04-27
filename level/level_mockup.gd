extends Node3D

## Flat-plane mockup level. Used as a template for all 4 powerup levels.
## Exports parameterize which power-up this level grants; on _ready, those
## values get pushed into the child PowerupPickup so a single tscn can be
## reused 4 times with different inspector-set configs.
##
## See docs/level_progression.md Phase 7.

## 1..4. Determines which level_N_completed flag advance() sets.
@export var level_num: int = 1

## StringName of the GameState flag the pickup flips on collect. E.g.
## &"powerup_love".
@export var powerup_flag: StringName = &"powerup_love"

## Short label billboarded on the floppy + shown in install toast.
@export var powerup_label: String = "LOVE"

## Caption shown on the how-to-use panel after install toast completes.
@export var howto_caption: String = "You have blades!"


func _ready() -> void:
	# Push exports into the pickup so the single .tscn template can host
	# any of the 4 power-ups.
	var pickup: PowerupPickup = get_node_or_null(^"PowerupPickup") as PowerupPickup
	if pickup != null:
		# Already owned from a previous visit → free the pickup before it
		# gets wired up. Must happen here (parent _ready) because the
		# pickup's own _ready has already run at this point with an empty
		# powerup_flag default.
		if bool(GameState.get_flag(powerup_flag, false)):
			pickup.queue_free()
		else:
			pickup.powerup_flag = powerup_flag
			pickup.powerup_label = powerup_label
			pickup.howto_caption = howto_caption
	# Register with the state machine so completion flags + save paths
	# reference this level.
	LevelProgression.register_level(level_num)
	# Level 1 is the skate tutorial — once the player enables skates, lock
	# them on for the rest of the run. PlayerBody.toggle_profile honors the
	# flag so the controller's L1 / keyboard's R becomes inert until the
	# next level boundary clears it.
	_set_player_skate_lock(level_num == 1)


func _exit_tree() -> void:
	# Release the lock so subsequent levels (and the hub) get free toggling
	# back. The player persists across level swaps, so this is necessary
	# even when the player isn't moving — they'd keep the property otherwise.
	_set_player_skate_lock(false)


func _set_player_skate_lock(on: bool) -> void:
	# Use call_deferred so the lookup runs AFTER the current frame's _ready
	# pass — guarantees PlayerBody._ready has run its add_to_group("player")
	# step regardless of ready order.
	_apply_skate_lock.call_deferred(on)


func _apply_skate_lock(on: bool) -> void:
	var player := get_tree().get_first_node_in_group(&"player")
	if player == null:
		# Fallback: walk the absolute path that game.tscn uses. Useful when
		# the player either hasn't joined the group yet or the level is being
		# tested in isolation (no game.tscn shell).
		player = get_tree().root.get_node_or_null(^"Game/Player")
	if player == null:
		print("[level_mockup] skate_lock(%s): player NOT FOUND — gate inert" % on)
		return
	if not ("skate_locked" in player):
		print("[level_mockup] skate_lock(%s): player has no `skate_locked` property — wrong PlayerBody?" % on)
		return
	player.skate_locked = on
	print("[level_mockup] skate_lock(%s) applied to %s" % [on, player])
