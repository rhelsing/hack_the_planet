extends Node

## Save-serializable world state. Single source of truth for player inventory,
## world flags (doors opened, NPCs talked to, puzzles solved), and per-NPC
## dialogue-visited tracking (ported from 3dPFormer/state.gd).
##
## Schema version 1 — change to_dict/from_dict together when incrementing.
## See docs/interactables.md §7.

const SCHEMA_VERSION: int = 3  # v3: persisted coin sets (collected + seen)

var inventory: Array[StringName] = []
var flags: Dictionary = {}
var dialogue_visited: Dictionary = {}

## Set-shaped dicts — keys are coin node paths, values are `true`. Both
## are persisted via to_dict / from_dict, so collected coins stay
## collected across reload AND the HUD denominator survives session
## boundaries.
##   coins_collected: paths of coins that have been picked up. Coins
##     queue_free themselves on _ready if their path is in this set, so
##     collected coins never respawn — Mario-style permanence.
##   coins_seen:      paths of every coin that has registered itself,
##     ever (across all sessions persisted to this slot). Drives the
##     HUD's #/total denominator. Always a superset of coins_collected.
var coins_collected: Dictionary = {}
var coins_seen: Dictionary = {}

## HUD reads. Mirror the dict sizes — kept in sync on every mutation so
## counters.gd's `_read_count(&"coin_count")` / `&"coin_total"` lookups
## keep working without touching the HUD.
var coin_count: int = 0
var coin_total: int = 0


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
	Events.item_added.emit(id)


## Subscriber for Events.coin_collected — coin.gd emits when the player
## triggers a pickup. We add the path to the persisted set; idempotent.
## Defensive: also adds to coins_seen in case a coin gets collected
## without _ready having registered it (shouldn't happen, but cheap).
func _on_coin_collected(coin: Node) -> void:
	if coin == null or not is_instance_valid(coin):
		return
	var key: String = String(coin.get_path())
	if coins_collected.has(key):
		return
	coins_collected[key] = true
	coin_count = coins_collected.size()
	if not coins_seen.has(key):
		coins_seen[key] = true
		coin_total = coins_seen.size()


## Coin self-registration. Each coin._ready calls this with itself; the
## first time we see a given path it joins the seen-set. Path is stable
## across scene reloads (re-entering a level builds new instances at the
## same paths) so dedup is robust without authored ids.
func register_coin(coin: Node) -> void:
	if coin == null or not is_instance_valid(coin):
		return
	var key: String = String(coin.get_path())
	if coins_seen.has(key):
		return
	coins_seen[key] = true
	coin_total = coins_seen.size()


## True if this coin has already been collected (in this run or restored
## from a prior save). coin._ready uses this to queue_free immediately —
## permanently-collected coins don't respawn, ever.
func is_coin_collected(coin: Node) -> bool:
	if coin == null:
		return false
	return coins_collected.has(String(coin.get_path()))


## 0..1 fraction of authored coins collected. Returns 0 when no coins
## have registered (avoids divide-by-zero before any level loads). Use
## as a modifier driver — e.g. unlock progression, reward scaling.
func coin_completion_ratio() -> float:
	if coin_total <= 0:
		return 0.0
	return float(coin_count) / float(coin_total)


func remove_item(id: StringName) -> void:
	if not inventory.has(id): return
	inventory.erase(id)
	Events.item_removed.emit(id)


# ---- World flags ---------------------------------------------------------

func set_flag(id: StringName, value: Variant = true) -> void:
	flags[id] = value
	Events.flag_set.emit(id, value)
	if String(id).begins_with("powerup_"):
		print("[pw] GameState.set_flag(%s=%s)" % [id, value])


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
		"coins_collected": coins_collected.duplicate(),
		"coins_seen": coins_seen.duplicate(),
	}


func from_dict(d: Dictionary) -> void:
	var loaded_inv: Array = d.get("inventory", [])
	inventory.clear()
	for entry: Variant in loaded_inv:
		inventory.append(StringName(entry))
	flags = d.get("flags", {}).duplicate(true)
	dialogue_visited = d.get("dialogue_visited", {}).duplicate(true)
	# Coin sets persist across reload — collected coins stay collected
	# permanently, and the seen-set survives so the HUD denominator is
	# correct from the first frame after load (before coin._ready runs
	# and re-registers what's currently in the scene).
	coins_collected = d.get("coins_collected", {}).duplicate()
	coins_seen = d.get("coins_seen", {}).duplicate()
	coin_count = coins_collected.size()
	coin_total = coins_seen.size()


## Full reset — used by "New Game" and by tests.
func reset() -> void:
	inventory.clear()
	flags.clear()
	dialogue_visited.clear()
	coins_collected.clear()
	coins_seen.clear()
	coin_count = 0
	coin_total = 0
