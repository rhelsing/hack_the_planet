extends Node3D

## Between-levels hub. 4 pedestals (one per level) + 4 NPCs (one per theme).
## Pedestals gate on prior completion flags; NPCs branch their dialogue on
## level_N_completed + powerup_X flags.
##
## On _ready we tell the state machine this is our "current level" so a quit
## here resumes here on next launch.

# First-time hub entry uses `tutorial_spawn`; every visit after uses the
# authored `PlayerSpawn` slot. We achieve this by copying tutorial_spawn's
# transform onto PlayerSpawn before Game._spawn_player consumes it.
const FLAG_HUB_VISITED: StringName = &"hub_visited"


func _ready() -> void:
	SaveService.set_current_level(LevelProgression.HUB_LEVEL_ID)
	# No register_level(num) call — hub isn't a numbered level.
	if not GameState.get_flag(FLAG_HUB_VISITED, false):
		var ps := get_node_or_null(^"PlayerSpawn") as Marker3D
		var ts := get_node_or_null(^"tutorial_spawn") as Marker3D
		if ps != null and ts != null:
			ps.global_transform = ts.global_transform
		GameState.set_flag(FLAG_HUB_VISITED, true)
