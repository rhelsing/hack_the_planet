class_name Pickup
extends Interactable

## Press-E narrative pickup — a quest key on a pedestal, a story-relevant
## floppy, a handed item from an NPC. Scattered platformer collectibles
## (coins, floppies strewn around) stay on the existing auto-trigger pattern
## (see level/interactable/coin/coin.gd and docs §18.4).
##
## On interact: adds item_id to GameState inventory and self-frees.

@export var item_id: StringName


func _ready() -> void:
	super._ready()
	if prompt_verb == "interact":
		prompt_verb = "take"


func interact(_actor: Node3D) -> void:
	if item_id.is_empty():
		push_error("Pickup %s has no item_id set — removing to avoid player soft-lock" % interactable_id)
		queue_free()  # remove anyway so prompt doesn't haunt the world
		return
	GameState.add_item(item_id)  # fires Events.item_added → Audio plays ding
	queue_free()
