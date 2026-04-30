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

## If true, becomes non-interactable after being solved once. Default
## false: terminals stay hackable across saves/reloads. Critical for
## terminals with `slide_target` — the slide tween only fires on live
## solve, so a saved-then-reloaded one_shot terminal would leave the
## world geometry in its closed authored position with no way to
## re-trigger. Repeatable hacking is the safe default; flip per-instance
## to true only when retry would be undesirable.
@export var one_shot: bool = false

## GameState flag that must be truthy for the terminal to be usable. Defaults
## to the hacker power-up for legacy hacking terminals; set empty ("") to
## remove the gate so non-hack puzzles (flow, password) don't require it.
@export var required_flag: StringName = &"powerup_secret"
## Message shown in the locked prompt when `required_flag` isn't set. Empty
## uses the default "not a hacker" text from legacy hacking terminals.
@export var locked_message: String = "not a hacker"

## Path to a .maze file (authored in tools/maze_editor/) forwarded into the
## puzzle instance as `maze_path` when interact() fires. Only relevant when
## `puzzle_scene` is a MazePuzzle; ignored by other puzzle types. Empty =
## the puzzle scene's own default applies.
@export_file("*.maze") var maze_path: String = ""

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
## Direct list of pawns to flip on solve, by NodePath. Bypasses positional
## ConvertZone lookup — useful when "these specific four enemies" is the
## right framing rather than "everyone in this room." Same target_factions
## filter applies (current faction must match).
@export var convert_targets: Array[NodePath] = []

@export_group("Highlight")
## MeshInstance3D nodes (typically inside the imported GLB) that get a green
## emissive overlay applied while this terminal is the focused interactable.
## Empty array = no visual highlight (script-only). Wire each laptop sub-mesh
## you want to glow (screen, chassis, etc.) by drag/drop in the editor.
@export var highlight_meshes: Array[NodePath] = []
## Optional override for the highlight material. null = use the built-in
## transparent green emissive (see _default_highlight_material).
@export var highlight_overlay_material: Material

@export_group("Gating")
## When non-empty, the terminal hides itself + disables collision until
## this GameState flag flips true. Used to chain terminals (terminal B
## stays invisible until terminal A is hacked). Listens to Events.flag_set
## so the reveal happens live, not just on _ready.
@export var visible_when_flag: StringName = &""

@export_group("Slide On Solve")
## Optional Node3D to translate when the puzzle is solved. Empty = no slide.
@export var slide_target: NodePath
## World-space offset applied to slide_target's global_position over slide_duration.
@export var slide_offset: Vector3 = Vector3(10.0, 0.0, 0.0)
## Tween duration in seconds. Ease-in-out cubic.
@export var slide_duration: float = 2.0
## AudioCue id played at slide start (registered in cue_registry.tres).
## Empty = silent slide.
@export var slide_sound_cue: StringName = &""

var _default_highlight_cached: Material
# Cached mesh list for the highlight overlay. Resolved lazily on first
# set_highlighted() call: explicit `highlight_meshes` paths if any, else
# every MeshInstance3D descendant of this terminal (drop any GLB and the
# whole model glows). Cached so repeated focus toggles don't re-walk.
var _resolved_highlight_meshes: Array[MeshInstance3D] = []
var _highlight_resolved: bool = false


func _ready() -> void:
	super._ready()
	pauses_game = true
	if prompt_verb == "interact":
		prompt_verb = "hack"
	# If we already solved this terminal in a prior session (flag restored),
	# replay the conversion side effect so enemies that were converted last
	# session show up converted again on reload — instead of respawning in
	# their authored faction. Independently, if one_shot, also disable the
	# sensor so the terminal can't be re-interacted. The replay fires for
	# both modes (one_shot AND repeatable) — the persistence question is
	# orthogonal to whether the player can re-hack.
	if GameState.get_flag(interactable_id, false):
		print("[hack] %s _ready: flag is set, scheduling replay" % interactable_id)
		if one_shot:
			collision_layer = 0  # sensor stops picking us up
		_replay_faction_conversion_on_load.call_deferred()
	else:
		print("[hack] %s _ready: flag NOT set — terminal idle" % interactable_id)
	# Visibility gate: hide + disable collision until the gate flag flips.
	# Listener stays alive across saves because Events is an autoload.
	if visible_when_flag != &"":
		_apply_visibility_gate()
		Events.flag_set.connect(_on_visibility_flag_set)


func _apply_visibility_gate() -> void:
	var unlocked: bool = bool(GameState.get_flag(visible_when_flag, false))
	visible = unlocked
	# Drop collision_layer so the InteractionSensor stops scoring us; restore
	# to 512 (the layer the terminal uses for E-press detection) on unlock.
	collision_layer = 512 if unlocked else 0


func _on_visibility_flag_set(id: StringName, value: Variant) -> void:
	if id != visible_when_flag:
		return
	if not bool(value):
		return
	visible = true
	collision_layer = 512


# Deferred-call entry: waits one physics frame so PlayerBody _ready has
# joined the right faction group AND the ConvertZone's overlapping_bodies
# query has populated, then runs the same conversion the live hack would
# have. Idempotent: if the enemies were authored in the resulting faction
# already, set_faction is a cheap no-op.
func _replay_faction_conversion_on_load() -> void:
	await get_tree().physics_frame
	_apply_faction_conversion()


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
	var setup: Dictionary = {}
	if maze_path != "":
		setup["maze_path"] = maze_path
	Puzzles.start(puzzle_scene, interactable_id, setup)
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
	# Treat puzzle solve as a checkpoint — same hook phone_booth.gd uses.
	# Without this, the flag lives only in GameState until a phone-booth or
	# end-of-level autosave; reloads mid-level would lose the hack progress.
	Events.checkpoint_reached.emit(global_position)
	if one_shot:
		collision_layer = 0
	_apply_faction_conversion()
	_apply_slide_on_solve()
	_disconnect_puzzle_signals()


func _apply_slide_on_solve() -> void:
	if slide_target.is_empty():
		return
	var node: Node = get_node_or_null(slide_target)
	if not (node is Node3D):
		push_warning("PuzzleTerminal %s: slide_target %s is not a Node3D" % [interactable_id, slide_target])
		return
	var target := node as Node3D
	if slide_sound_cue != &"":
		Audio.play_sfx(slide_sound_cue)
	var dest: Vector3 = target.global_position + slide_offset
	var tween := create_tween().set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_IN_OUT)
	tween.tween_property(target, "global_position", dest, slide_duration)


## Walk every ConvertZone matching `convert_zone_id`, flip every PlayerBody
## overlapping any of them whose faction is in `target_factions` to
## `resulting_faction`. ALSO subscribes to each zone's body_entered so any
## body that enters LATER (e.g., enemies dynamically spawned by EnemySpawner
## proximity triggers) auto-converts on entry. The subscription is
## idempotent (guarded by is_connected) so multiple replays are safe.
##
## No-op if target_factions is empty or no zones are registered with this
## id — keeps non-hack terminals (flow, password) untouched.
##
## Duck-typed body access (has_method + get) so this script compiles in
## SceneTree-mode tests without forcing the PlayerBody class import.
func _apply_faction_conversion() -> void:
	if target_factions.is_empty():
		return
	# Direct named targets — flip each by NodePath. No body_entered subscribe;
	# these are static scene nodes, not late-spawned.
	for path: NodePath in convert_targets:
		var node: Node = get_node_or_null(path)
		if node != null:
			_try_convert_body(node)
	if convert_zone_id == &"":
		return
	var zones: Array = _CONVERT_ZONE_SCRIPT.call(&"zones_for", convert_zone_id) as Array
	print("[hack] _apply_faction_conversion id=%s zones=%d targets=%s -> %s" % [
		convert_zone_id, zones.size(), target_factions, resulting_faction])
	for zone in zones:
		if not (zone is Area3D):
			continue
		var area := zone as Area3D
		# 1) Convert anyone currently overlapping.
		for body in area.get_overlapping_bodies():
			_try_convert_body(body)
		# 2) Subscribe so future entries also convert. EnemySpawner adds
		#    enemies AFTER scene load, so the initial scan won't catch them
		#    — but body_entered fires when the spawner's tween parks them
		#    inside the zone.
		if not area.body_entered.is_connected(_try_convert_body):
			area.body_entered.connect(_try_convert_body)


## Try to flip a single body's faction if it's in our target list. No-op
## for bodies without a set_faction method or with a non-matching current
## faction. Wired both as the initial-scan callback and the long-lived
## body_entered subscriber.
func _try_convert_body(body: Node) -> void:
	if body == null or not body.has_method(&"set_faction"):
		return
	var current: StringName = StringName(body.get(&"faction"))
	if current in target_factions:
		print("[hack] convert %s: %s -> %s" % [body.name, current, resulting_faction])
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


## InteractionSensor calls this with `on=true` when this terminal becomes the
## focused interactable, `on=false` when focus drops. Toggles a green emissive
## overlay on every MeshInstance3D either explicitly listed in
## `highlight_meshes` or auto-discovered as a descendant of this terminal.
func set_highlighted(on: bool) -> void:
	var meshes: Array[MeshInstance3D] = _resolve_highlight_meshes()
	if meshes.is_empty():
		return
	var overlay: Material = highlight_overlay_material if highlight_overlay_material != null else _default_highlight_material()
	for m: MeshInstance3D in meshes:
		m.material_overlay = overlay if on else null


# Resolve once: explicit NodePaths take priority; if the array is empty,
# walk descendants and grab every MeshInstance3D — drop any GLB in here
# and it just glows. Cached so repeated focus toggles don't re-walk.
func _resolve_highlight_meshes() -> Array[MeshInstance3D]:
	if _highlight_resolved:
		return _resolved_highlight_meshes
	_highlight_resolved = true
	if not highlight_meshes.is_empty():
		for path in highlight_meshes:
			var node: Node = get_node_or_null(path)
			if node is MeshInstance3D:
				_resolved_highlight_meshes.append(node as MeshInstance3D)
	else:
		_collect_mesh_instances(self, _resolved_highlight_meshes)
	return _resolved_highlight_meshes


func _collect_mesh_instances(node: Node, out: Array[MeshInstance3D]) -> void:
	if node is MeshInstance3D:
		out.append(node as MeshInstance3D)
	for child: Node in node.get_children():
		_collect_mesh_instances(child, out)


func _default_highlight_material() -> Material:
	if _default_highlight_cached == null:
		var mat := StandardMaterial3D.new()
		mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		mat.albedo_color = Color(0.1, 1.0, 0.3, 0.35)
		mat.emission_enabled = true
		mat.emission = Color(0.2, 1.0, 0.4)
		mat.emission_energy_multiplier = 1.5
		_default_highlight_cached = mat
	return _default_highlight_cached
