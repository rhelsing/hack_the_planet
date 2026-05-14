class_name LabEntry
extends Interactable

## Hub press-E portal into a procedurally-generated level.
## Stashes brief_path on GameState so procedural_level._ready can read it,
## then swaps the level child via LevelProgression.goto_path (bypasses the
## numbered-level bookkeeping; this isn't slot 1-4).

const NEXT_BRIEF_FLAG: StringName = &"next_brief_path"
const PROCEDURAL_PATH: String = "res://level/procedural_level.tscn"

@export_file("*.json") var brief_path: String = "res://tools/level_constructor/briefs/level_1_starter.json"


func _ready() -> void:
	super._ready()
	if prompt_verb == "interact":
		prompt_verb = "enter lab"


func interact(_actor: Node3D) -> void:
	GameState.set_flag(NEXT_BRIEF_FLAG, brief_path)
	LevelProgression.goto_path(PROCEDURAL_PATH)
