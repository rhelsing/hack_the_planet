class_name Interactable
extends Area3D

## Base class for every press-E interactable (Door, DialogueTrigger, Pickup,
## Trap, PuzzleTerminal). Subclasses override interact(); everything else is
## optional. See docs/interactables.md §3 and §18 for when to use this base
## vs the walk-into auto-trigger pattern.

## Text shown in the prompt UI while focused. PromptUI prepends the button
## glyph — e.g. "hack terminal" → "[E] hack terminal".
@export var prompt_verb: String = "interact"

## Stable ID for GameState world flags, save keys, and Events payloads.
@export var interactable_id: StringName

## If non-empty, GameState.inventory must contain this item for can_interact()
## to pass. Default `can_interact` honors this automatically.
@export var requires_key: StringName = &""

## If non-empty, GameState.get_flag(requires_flag) must be truthy for
## can_interact() to pass. Enables puzzle→door chains: set the door's
## requires_flag to the puzzle terminal's interactable_id, and solving the
## puzzle unlocks the door via the flag that PuzzleTerminal sets on solve.
@export var requires_flag: StringName = &""

## Pause get_tree() while this interaction is "open." Dialogue + PuzzleTerminal
## flip this to true; Door / Pickup / Trap stay false.
@export var pauses_game: bool = false

## Score bonus added in InteractionSensor scoring (additive, not multiplicative
## — see sensor code). Use for author-ranked importance; default 1.0 = no bonus.
## Named `focus_priority` to avoid shadowing Area3D's built-in `priority`
## (used for audio reverb ordering).
@export var focus_priority: float = 1.0


func _ready() -> void:
	add_to_group(&"interactable")
	collision_layer = Layers.INTERACTABLE
	collision_mask = 0  # sensor scans us; we don't scan anything


## Gate — subclasses may override to add more conditions. Default honors
## requires_key (inventory) AND requires_flag (world state). Both must pass
## if set. Either left empty is treated as "not required."
func can_interact(_actor: Node3D) -> bool:
	if not requires_key.is_empty() and not GameState.has_item(requires_key):
		return false
	if not requires_flag.is_empty() and not GameState.get_flag(requires_flag, false):
		return false
	return true


## True if any requires_key / requires_flag gate is currently failing. Used by
## PromptUI to render a "(locked)" suffix on focus without needing an actor
## reference. Default implementation matches can_interact(null).
func is_locked() -> bool:
	return not can_interact(null)


## Human-readable description of WHY this interactable is locked, for UI
## toast. Returns "" if not locked. Override in subclasses to customize.
func describe_lock() -> String:
	var parts: PackedStringArray = []
	if not requires_key.is_empty() and not GameState.has_item(requires_key):
		parts.append("needs " + _humanize(requires_key))
	if not requires_flag.is_empty() and not GameState.get_flag(requires_flag, false):
		parts.append(_humanize(requires_flag) + " required")
	if parts.is_empty():
		return ""
	return "Locked — " + " & ".join(parts)


static func _humanize(id: StringName) -> String:
	# StringName snake_case → Title Case via Godot's built-in word splitter.
	# "village_gate_key" → "Village Gate Key"
	return str(id).capitalize()


## Subclasses MUST override. Base pushes a warning so missing overrides are loud.
func interact(_actor: Node3D) -> void:
	push_warning("Interactable %s has no interact() override" % interactable_id)


## Subclasses override if they have visuals worth highlighting. Default no-op
## so script-only interactables don't need to implement this.
func set_highlighted(_on: bool) -> void:
	pass
