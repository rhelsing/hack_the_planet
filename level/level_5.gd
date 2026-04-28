extends Node3D

## Level 5 — Betray Ending. Walk-of-shame scene that fires when the player
## chose `splice_committed` in level_3_splice_offer.dialogue. See
## docs/splice_arc.md §5b for the spec.
##
## On _ready: locks the player into a slow forward walk via
## PlayerBody.enter_betrayal_walk, then plays a scripted sequence of walkie
## lines from Splice / DialTone / Glitch / Nyx. When the player reaches the
## EndTerminal Area3D, the screen fades to a "POPULATION: 1" card and the
## game returns to the main menu.

## Path to the main menu the game returns to after the end card.
@export var main_menu_path: String = "res://menu/main_menu.tscn"

## Player's forced walk direction in WORLD space (Y is stripped). Default
## -Z = standard "into the corridor". Flip if you mirror the level layout.
@export var walk_direction: Vector3 = Vector3(0, 0, -1)
@export var walk_speed_mps: float = 1.5
## Splice's pace. Default matches the player's, so he stays exactly
## `splice_lead_distance` ahead the whole walk. Bump above to read as
## "leading", drop below to have the player overtake him at the end.
@export var splice_walk_speed_mps: float = 1.5
## World-Z (when walk_direction is -Z) where Splice stops walking. Player's
## EndTerminal is at z=-60, floor ends at z=-65 — clamp Splice short of
## that so he doesn't walk off the geometry.
@export var splice_stop_at_z: float = -62.0

## Seconds between scripted lines. Each line is queued through Walkie which
## chains them on its own FIFO — this interval is just the spacing between
## kicks, not the playback duration.
@export var line_interval_s: float = 7.0
## Initial delay before the first line fires (gives the player a beat to
## realize they can't control anything).
@export var first_line_delay_s: float = 2.5
## Seconds the end card holds before fading to main menu.
@export var end_card_hold_s: float = 4.5

# Scripted dialogue beats — preserved here as code (not a .dialogue file)
# because they're timed walkie lines, not press-E branching dialogue.
const _BEATS: Array = [
	["Splice",   "There you are. I knew you'd see it."],
	["DialTone", "Channel's open. Wanted you to hear me say it. You sold us."],
	["Splice",   "What's a runner without a contract? You belong to me now."],
	["Glitch",   "I had hoped my analysis was wrong. It was not."],
	["Splice",   "We start with the lower nodes. By morning we'll own the dial-up."],
	["Nyx",      "I rooted for you. Whatever. Bye, runner."],
	["Splice",   "Keep walking. The throne room's just ahead."],
]

var _ended: bool = false
var _splice_npc: Node3D
var _splice_skin: Node
var _splice_walking: bool = false


func _ready() -> void:
	SaveService.set_current_level(&"level_5")
	# Find the player and lock them into the walk. PlayerBody is added to the
	# "player" group at _ready by the existing setup.
	var player := get_tree().get_first_node_in_group(&"player")
	if player != null and player.has_method(&"enter_betrayal_walk"):
		player.call(&"enter_betrayal_walk", walk_direction, walk_speed_mps)
	# Wire the end terminal.
	var end_area: Area3D = get_node_or_null(^"EndTerminal") as Area3D
	if end_area != null:
		end_area.body_entered.connect(_on_end_entered)
	# Splice walks ahead alongside the player. Skin pre-faces the walk
	# direction (CompanionNPC.swivel_speed=0 keeps it from rotating back
	# toward the player every frame); calling skin.move() switches the
	# AnimationTree state machine to its Move state for the duration.
	_splice_npc = get_node_or_null(^"SpliceLead") as Node3D
	if _splice_npc != null:
		_splice_skin = _splice_npc.get_node_or_null(^"Skin")
		if _splice_skin is Node3D:
			(_splice_skin as Node3D).rotation.y = atan2(walk_direction.x, walk_direction.z)
		if _splice_skin != null and _splice_skin.has_method(&"move"):
			_splice_skin.call(&"move")
		_splice_walking = true
	# Kick off the scripted line sequence.
	_play_beats()
	# Credits roll alongside the corridor walk. Same scroll as the post-L4
	# hub trigger and the main-menu Credits button. Self-frees on completion
	# or Esc; the end-card / main-menu transition is independent of this
	# overlay (end-card's CanvasLayer is layer 100 — credits sit below at 50).
	_spawn_credits_overlay()


func _spawn_credits_overlay() -> void:
	var packed: PackedScene = load("res://menu/credits.tscn")
	if packed == null:
		return
	var layer := CanvasLayer.new()
	layer.layer = 50
	add_child(layer)
	var inst: Node = packed.instantiate()
	layer.add_child(inst)
	if inst.has_signal(&"back_requested"):
		inst.connect(&"back_requested", func() -> void: layer.queue_free(),
			CONNECT_ONE_SHOT)


func _process(delta: float) -> void:
	if _ended or not _splice_walking or _splice_npc == null:
		return
	var dir := walk_direction
	dir.y = 0.0
	if dir.length_squared() < 0.0001:
		return
	dir = dir.normalized()
	_splice_npc.global_position += dir * splice_walk_speed_mps * delta
	# Clamp at splice_stop_at_z so he doesn't step off the corridor edge.
	# Direction-aware: if walking toward -Z, stop when we've passed the
	# threshold from above; toward +Z, stop when passed from below.
	var z := _splice_npc.global_position.z
	var done := (dir.z < 0.0 and z <= splice_stop_at_z) \
			or (dir.z > 0.0 and z >= splice_stop_at_z)
	if done:
		_splice_npc.global_position.z = splice_stop_at_z
		_splice_walking = false
		if _splice_skin != null and _splice_skin.has_method(&"idle"):
			_splice_skin.call(&"idle")


func _play_beats() -> void:
	await get_tree().create_timer(first_line_delay_s).timeout
	for beat: Array in _BEATS:
		if _ended:
			return
		var character: String = beat[0]
		var line: String = beat[1]
		Walkie.speak(character, line)
		await get_tree().create_timer(line_interval_s).timeout


func _on_end_entered(body: Node) -> void:
	if _ended:
		return
	if not body.is_in_group(&"player"):
		return
	_ended = true
	_show_end_card()


func _show_end_card() -> void:
	# Build a black-fade overlay + end-card label as a CanvasLayer so we don't
	# need a pre-authored UI scene. Lives for `end_card_hold_s` then changes
	# to the main menu.
	var layer := CanvasLayer.new()
	layer.layer = 100
	add_child(layer)
	var bg := ColorRect.new()
	bg.color = Color(0, 0, 0, 0)
	bg.anchor_right = 1.0
	bg.anchor_bottom = 1.0
	layer.add_child(bg)
	var lbl := Label.new()
	lbl.text = "THE GIBSON IS YOURS.\nPOPULATION: 1."
	lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	lbl.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	lbl.anchor_right = 1.0
	lbl.anchor_bottom = 1.0
	lbl.add_theme_font_size_override(&"font_size", 48)
	lbl.add_theme_color_override(&"font_color", Color(0.8, 1.0, 0.8, 1.0))
	lbl.modulate.a = 0.0
	layer.add_child(lbl)
	var tw := create_tween().set_parallel(true)
	tw.tween_property(bg, "color", Color(0, 0, 0, 1), 1.0)
	tw.tween_property(lbl, "modulate:a", 1.0, 1.5)
	await tw.finished
	await get_tree().create_timer(end_card_hold_s).timeout
	# Reset the betrayed flag so a new run isn't permanently locked. The save
	# slot still holds it; New Game from main menu wipes via begin_new_game.
	var sl := get_tree().root.get_node_or_null(^"SceneLoader")
	if sl != null and sl.has_method(&"goto"):
		sl.call(&"goto", main_menu_path)
	else:
		get_tree().change_scene_to_file(main_menu_path)
