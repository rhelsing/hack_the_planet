extends Node

## Save-serializable world state. Single source of truth for player inventory,
## world flags (doors opened, NPCs talked to, puzzles solved), and per-NPC
## dialogue-visited tracking (ported from 3dPFormer/state.gd).
##
## Schema version 1 — change to_dict/from_dict together when incrementing.
## See docs/interactables.md §7.

const SCHEMA_VERSION: int = 1

var inventory: Array[StringName] = []
var flags: Dictionary = {}
var dialogue_visited: Dictionary = {}


# ---- Inventory -----------------------------------------------------------

func has_item(id: StringName) -> bool:
	return inventory.has(id)


func add_item(id: StringName) -> void:
	if inventory.has(id): return
	inventory.append(id)
	Events.item_added.emit(id)


func remove_item(id: StringName) -> void:
	if not inventory.has(id): return
	inventory.erase(id)
	Events.item_removed.emit(id)


# ---- World flags ---------------------------------------------------------

func set_flag(id: StringName, value: Variant = true) -> void:
	flags[id] = value
	Events.flag_set.emit(id, value)


func get_flag(id: StringName, default_value: Variant = null) -> Variant:
	return flags.get(id, default_value)


# ---- Dialogue-visited tracking ------------------------------------------
# Called from .dialogue files via `general/states=["GameState", ...]`.
# `zipped` is "<response_id>_<response_text>" to uniquely identify a choice.

func visit_dialogue(character: String, response_id: String, text: String) -> void:
	var zipped := "%s_%s" % [response_id, text]
	if not dialogue_visited.has(character):
		dialogue_visited[character] = {}
	dialogue_visited[character][zipped] = true


func has_visited(character: String, zipped: String) -> bool:
	return dialogue_visited.get(character, {}).has(zipped)


# ---- Save / load (called by ui_dev's SaveService) -----------------------

func to_dict() -> Dictionary:
	return {
		"version": SCHEMA_VERSION,
		"inventory": inventory.duplicate(),
		"flags": flags.duplicate(true),
		"dialogue_visited": dialogue_visited.duplicate(true),
	}


func from_dict(d: Dictionary) -> void:
	# Schema migration lives here. v1 is the only version right now; future
	# versions branch on d.get("version", 1) and translate before assigning.
	var loaded_inv: Array = d.get("inventory", [])
	inventory.clear()
	for entry: Variant in loaded_inv:
		inventory.append(StringName(entry))
	flags = d.get("flags", {}).duplicate(true)
	dialogue_visited = d.get("dialogue_visited", {}).duplicate(true)


## Full reset — used by "New Game" and by tests.
func reset() -> void:
	inventory.clear()
	flags.clear()
	dialogue_visited.clear()
