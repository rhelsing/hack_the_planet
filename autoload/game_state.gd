extends Node

## Save-serializable world state. Single source of truth for player inventory,
## world flags (doors opened, NPCs talked to, puzzles solved), and per-NPC
## dialogue-visited tracking (ported from 3dPFormer/state.gd).
##
## Schema version 1 — change to_dict/from_dict together when incrementing.
## See docs/interactables.md §7.

const SCHEMA_VERSION: int = 2  # v2 added coin_count + floppy_count

var inventory: Array[StringName] = []
var flags: Dictionary = {}
var dialogue_visited: Dictionary = {}

## HUD counter — bumped on Events.coin_collected (see _ready subscriber).
## Per-run / per-level: NOT persisted to save slots. Resets on engine boot
## and on every load/new-game so each play starts at zero.
var coin_count: int = 0

## HUD counter — bumped when a floppy-disk item enters inventory. Per-run /
## per-level: NOT persisted to save slots.
var floppy_count: int = 0

const FLOPPY_ITEM_ID: StringName = &"floppy_disk"


# ---- Inventory -----------------------------------------------------------

func _ready() -> void:
	# HUD counter: coin pickups bump via existing Events.coin_collected.
	# The emit site (level/interactable/coin/coin.gd) is a legacy auto-trigger
	# interactable, per docs/interactables.md §18.1.
	Events.coin_collected.connect(_on_coin_collected)


func has_item(id: StringName) -> bool:
	return inventory.has(id)


func add_item(id: StringName) -> void:
	if inventory.has(id): return
	inventory.append(id)
	# Per-id counter bumps keep the HUD in sync without a second subscriber.
	if id == FLOPPY_ITEM_ID:
		floppy_count += 1
	Events.item_added.emit(id)


func _on_coin_collected(_coin: Node) -> void:
	coin_count += 1


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
	var loaded_inv: Array = d.get("inventory", [])
	inventory.clear()
	for entry: Variant in loaded_inv:
		inventory.append(StringName(entry))
	flags = d.get("flags", {}).duplicate(true)
	dialogue_visited = d.get("dialogue_visited", {}).duplicate(true)
	# coin_count / floppy_count are intentionally NOT loaded — they're per-run
	# counters that start fresh every level. Old v2 save files may include
	# them; we ignore.
	coin_count = 0
	floppy_count = 0


## Full reset — used by "New Game" and by tests.
func reset() -> void:
	inventory.clear()
	flags.clear()
	dialogue_visited.clear()
	coin_count = 0
	floppy_count = 0
