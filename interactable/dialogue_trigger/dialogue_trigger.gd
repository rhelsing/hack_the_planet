class_name DialogueTrigger
extends Interactable

## Press-E NPC / interactable that opens a dialogue conversation. Pauses the
## game via the Dialogue autoload (which flips get_tree().paused).
## See docs/interactables.md §10.3.

## Authored in the Godot editor via Nathan Hoad's Dialogue Manager plugin.
## Typed as Resource (not DialogueResource) so the class_name from the plugin
## isn't required at parse time of this file.
@export var dialogue_resource: Resource

## Start node name inside the .dialogue file (matches `~ start` convention).
@export var dialogue_start: String = "start"


func _ready() -> void:
	super._ready()
	pauses_game = true
	if prompt_verb == "interact":
		prompt_verb = "talk"


func interact(_actor: Node3D) -> void:
	if dialogue_resource == null:
		push_warning("DialogueTrigger %s has no dialogue_resource" % interactable_id)
		return
	Dialogue.start(dialogue_resource, dialogue_start, interactable_id)
