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
@export var howto_caption: String = "PRESS {toggle_skate} TO SKATE"


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
