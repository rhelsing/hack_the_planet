class_name PuzzleTerminal
extends Interactable

# Preload by path so the class_name doesn't need to resolve at parse-time
# under SceneTree-mode tests (where class_name registries can be empty).
const _CONVERT_ZONE_SCRIPT: Script = preload("res://level/interactable/convert_zone/convert_zone.gd")

## Press-E terminal that launches a puzzle minigame. Pauses the game via the
## Puzzles autoload (which flips get_tree().paused).
## See docs/interactables.md §10.6.

## Puzzle scene to instantiate — must extend `Puzzle` (CanvasLayer with
## finished(success: bool) signal). Example: res://puzzle/hacking/hacking_puzzle.tscn.
@export var puzzle_scene: PackedScene

## If true, becomes non-interactable after being solved once. Otherwise
## the terminal stays hackable (useful for retry / practice).
@export var one_shot: bool = true

## GameState flag that must be truthy for the terminal to be usable. Defaults
## to the hacker power-up for legacy hacking terminals; set empty ("") to
## remove the gate so non-hack puzzles (flow, password) don't require it.
@export var required_flag: StringName = &"powerup_secret"
## Message shown in the locked prompt when `required_flag` isn't set. Empty
## uses the default "not a hacker" text from legacy hacking terminals.
@export var locked_message: String = "not a hacker"

@export_group("Faction Conversion")
## On puzzle-solved, every PlayerBody overlapping any ConvertZone with a
## matching `convert_zone_id` whose current faction is in this list gets
## flipped to `resulting_faction`. Empty (default) = no conversion side
## effect; the terminal still sets its GameState flag normally.
@export var target_factions: Array[StringName] = []
## Faction the matched pawns get flipped to. Ignored if target_factions
## is empty.
@export var resulting_faction: StringName = &"green"
## ID linking this terminal to one or more ConvertZone nodes in the level.
## Empty (default) = no conversion. Drop ConvertZone scenes wherever you
## want the conversion to apply, set their `id` to match this. Many zones
## can share an id (covering disjoint rooms a single hack should affect).
@export var convert_zone_id: StringName = &""


func _ready() -> void:
	super._ready()
	pauses_game = true
	if prompt_verb == "interact":
		prompt_verb = "hack"
	# If we already solved this terminal in a prior session (flag restored),
	# and it's one-shot, disable it at spawn.
	if one_shot and GameState.get_flag(interactable_id, false):
		collision_layer = 0  # sensor stops picking us up


## Gate: if `required_flag` is set and unsatisfied, terminal locks. Set
## `required_flag = &""` to remove the gate (for non-hack puzzles).
func can_interact(actor: Node3D) -> bool:
	if required_flag != &"" and not bool(GameState.get_flag(required_flag, false)):
		return false
	return super.can_interact(actor)


func describe_lock() -> String:
	if required_flag != &"" and not bool(GameState.get_flag(required_flag, false)):
		return locked_message
	return super.describe_lock()


func interact(_actor: Node3D) -> void:
	if puzzle_scene == null:
		push_warning("PuzzleTerminal %s has no puzzle_scene" % interactable_id)
		return
	Puzzles.start(puzzle_scene, interactable_id)
	# Listen for our specific outcome. Plain connect (NOT ONE_SHOT) — a ONE_SHOT
	# would disconnect on the first puzzle_solved regardless of whether the id
	# matched us, causing missed self-completions if another puzzle resolves
	# first. We disconnect manually after id match.
	if not Events.puzzle_solved.is_connected(_on_puzzle_solved):
		Events.puzzle_solved.connect(_on_puzzle_solved)
	if not Events.puzzle_failed.is_connected(_on_puzzle_failed):
		Events.puzzle_failed.connect(_on_puzzle_failed)


func _on_puzzle_solved(solved_id: StringName) -> void:
	if solved_id != interactable_id: return
	GameState.set_flag(interactable_id, true)
	if one_shot:
		collision_layer = 0
	_apply_faction_conversion()
	_disconnect_puzzle_signals()


## Walk every ConvertZone matching `convert_zone_id`, flip every PlayerBody
## overlapping any of them whose faction is in `target_factions` to
## `resulting_faction`. No-op if target_factions is empty or no zones are
## registered with this id — keeps non-hack terminals (flow, password) and
## unconverted hack terminals untouched.
##
## Duck-typed body access (has_method + get) so this script compiles in
## SceneTree-mode tests without forcing the PlayerBody class import.
func _apply_faction_conversion() -> void:
	if target_factions.is_empty() or convert_zone_id == &"":
		return
	var seen: Dictionary = {}
	var zones: Array = _CONVERT_ZONE_SCRIPT.call(&"zones_for", convert_zone_id) as Array
	for zone in zones:
		if not (zone is Area3D):
			continue
		for body in (zone as Area3D).get_overlapping_bodies():
			if seen.has(body):
				continue
			seen[body] = true
			if not body.has_method(&"set_faction"):
				continue
			var current: StringName = StringName(body.get(&"faction"))
			if current in target_factions:
				body.call(&"set_faction", resulting_faction)


func _on_puzzle_failed(failed_id: StringName) -> void:
	if failed_id != interactable_id: return
	# On fail (cancel/bail), just unhook — terminal remains interactable for retry.
	_disconnect_puzzle_signals()


func _disconnect_puzzle_signals() -> void:
	if Events.puzzle_solved.is_connected(_on_puzzle_solved):
		Events.puzzle_solved.disconnect(_on_puzzle_solved)
	if Events.puzzle_failed.is_connected(_on_puzzle_failed):
		Events.puzzle_failed.disconnect(_on_puzzle_failed)
