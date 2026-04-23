extends CanvasLayer
## Dialogue balloon for Nathan Hoad's Dialogue Manager (3.x). Forked from
## the addon's example_balloon with two additions ported from 3dPFormer:
##   - Dims response buttons for choices the player has already made
##     (scoped per character via GameState.has_visited).
##   - Records the choice on selection via GameState.visit_dialogue so
##     future conversations with the same character re-dim correctly.
## "End the conversation" is never dimmed (designer escape hatch).
## See docs/interactables.md §9.4.

const VISITED_DIM: Color = Color(0.5, 0.5, 0.5, 1.0)
const EXIT_TEXT: String = "End the conversation"

## Per-character speaker colors used for the log entries and the current
## CharacterLabel. Add entries as new speakers enter the game.
const SPEAKER_COLORS := {
	"Troll": "#E4C57A",
	"Me": "#6AD9FF",
	"Narrator": "#888888",
	"NARRATOR": "#888888",
}
const DEFAULT_SPEAKER_COLOR := "#E0E0E0"
const YOU_CHOICE_COLOR := "#8FA08F"


## The dialogue resource
@export var dialogue_resource: DialogueResource

## Start from a given cue when using balloon as a [Node] in a scene.
@export var start_from_cue: String = ""

## If running as a [Node] in a scene then auto start the dialogue.
@export var auto_start: bool = false

## If all other input is blocked as long as dialogue is shown.
@export var will_block_other_input: bool = true

## The action to use for advancing the dialogue
@export var next_action: StringName = &"ui_accept"

## The action to use to skip typing the dialogue
@export var skip_action: StringName = &"ui_cancel"

## A sound player for voice lines (if they exist).
@onready var audio_stream_player: AudioStreamPlayer = %AudioStreamPlayer

## Temporary game states
var temporary_game_states: Array = []

## See if we are waiting for the player
var is_waiting_for_input: bool = false

## See if we are running a long mutation and should hide the balloon
var will_hide_balloon: bool = false

## A dictionary to store any ephemeral variables
var locals: Dictionary = {}

var _locale: String = TranslationServer.get_locale()

## The current line
var dialogue_line: DialogueLine:
	set(value):
		# P2: snapshot the PREVIOUS line to the scrolling log before overwriting.
		# The response handler also logs (current line + YOU choice) and sets
		# _skip_next_snapshot so we don't double-log that transition.
		if not _skip_next_snapshot and is_instance_valid(dialogue_line):
			_append_line_to_log(dialogue_line)
		_skip_next_snapshot = false

		if value:
			dialogue_line = value
			apply_dialogue_line()
		else:
			# The dialogue has finished so close the balloon
			if owner == null:
				queue_free()
			else:
				hide()
	get:
		return dialogue_line

## A cooldown timer for delaying the balloon hide when encountering a mutation.
var mutation_cooldown: Timer = Timer.new()

## The base balloon anchor
@onready var balloon: Control = %Balloon

## The label showing the name of the currently speaking character
@onready var character_label: RichTextLabel = %CharacterLabel

## The label showing the currently spoken dialogue
@onready var dialogue_label: DialogueLabel = %DialogueLabel

## The menu of responses
@onready var responses_menu: DialogueResponsesMenu = %ResponsesMenu

## Indicator to show that player can progress dialogue. Typed as Control so
## the label-based `▼` fits (old plugin used Polygon2D).
@onready var progress: Control = %Progress

## Scroll log (P2): LogContainer holds past DialogueLines + YOU choices as
## BBCode RichTextLabels. ScrollContainer handles overflow; we auto-scroll
## to newest only if the user was at bottom (respect manual scroll-up).
@onready var _scroll: ScrollContainer = %ScrollContainer
@onready var _log: VBoxContainer = %LogContainer

## True for exactly one setter dispatch when the response handler has already
## logged the previous line. Prevents double-logging.
var _skip_next_snapshot: bool = false


func _ready() -> void:
	balloon.hide()
	Engine.get_singleton("DialogueManager").mutated.connect(_on_mutated)

	# If the responses menu doesn't have a next action set, use this one
	if responses_menu.next_action.is_empty():
		responses_menu.next_action = next_action

	# HIDE failed `[if ... /]` responses entirely instead of showing them
	# disabled/greyed. Also set in .tscn (belt-and-suspenders).
	responses_menu.hide_failed_responses = true
	print("[balloon] _ready: hide_failed_responses=%s" % responses_menu.hide_failed_responses)

	# Hook response-menu focus change → UI move sound. The plugin's menu
	# emits `response_focused(control)` on focus change; we play ui_move.
	# ui_dev wired this cue in audio/cues/ui_move.tres (clicks).
	if responses_menu.has_signal(&"response_focused"):
		responses_menu.response_focused.connect(_on_response_focused)

	mutation_cooldown.timeout.connect(_on_mutation_cooldown_timeout)
	add_child(mutation_cooldown)

	if auto_start:
		if not is_instance_valid(dialogue_resource):
			assert(false, DMConstants.get_error_message(DMConstants.ERR_MISSING_RESOURCE_FOR_AUTOSTART))
		start()


## UI "tick" sound as the player navigates between response choices.
func _on_response_focused(_control: Control) -> void:
	Audio.play_sfx(&"ui_move")


func _process(_delta: float) -> void:
	if is_instance_valid(dialogue_line):
		progress.visible = not dialogue_label.is_typing and dialogue_line.responses.size() == 0 and not dialogue_line.has_tag("voice")


func _unhandled_input(_event: InputEvent) -> void:
	# Only the balloon is allowed to handle input while it's showing
	if will_block_other_input:
		get_viewport().set_input_as_handled()


func _notification(what: int) -> void:
	## Detect a change of locale and update the current dialogue line to show the new language
	if what == NOTIFICATION_TRANSLATION_CHANGED and _locale != TranslationServer.get_locale() and is_instance_valid(dialogue_label):
		_locale = TranslationServer.get_locale()
		var visible_ratio: float = dialogue_label.visible_ratio
		await dialogue_line.refresh()
		if visible_ratio < 1:
			dialogue_label.skip_typing()


## Start some dialogue
func start(with_dialogue_resource: DialogueResource = null, cue: String = "", extra_game_states: Array = []) -> void:
	temporary_game_states = [self] + extra_game_states
	is_waiting_for_input = false
	if is_instance_valid(with_dialogue_resource):
		dialogue_resource = with_dialogue_resource
	if not cue.is_empty():
		start_from_cue = cue
	dialogue_line = await dialogue_resource.get_next_dialogue_line(start_from_cue, temporary_game_states)
	show()


## Apply any changes to the balloon given a new [DialogueLine].
func apply_dialogue_line() -> void:
	mutation_cooldown.stop()

	progress.hide()
	is_waiting_for_input = false
	balloon.focus_mode = Control.FOCUS_ALL
	balloon.grab_focus()

	character_label.visible = not dialogue_line.character.is_empty()
	if dialogue_line.character.is_empty():
		character_label.text = ""
	else:
		character_label.text = "[color=%s][b]%s[/b][/color]" % [
			_speaker_color(dialogue_line.character),
			tr(dialogue_line.character, "dialogue").to_upper(),
		]

	dialogue_label.hide()
	dialogue_label.dialogue_line = dialogue_line

	responses_menu.hide()
	responses_menu.responses = dialogue_line.responses
	# Log the gate state per response so we can diagnose the "should be hidden
	# but shows grayed" confusion. is_allowed=false + hide_failed_responses=true
	# == option hidden (no button). is_allowed=true + visited == button with
	# modulate=grey. is_allowed=true + unvisited == bright button.
	for r: DialogueResponse in dialogue_line.responses:
		print("[balloon] response '%s' is_allowed=%s" % [r.text, r.is_allowed])
	_dim_visited_responses()  # ported from 3dPFormer

	# Show our balloon
	balloon.show()
	will_hide_balloon = false

	dialogue_label.show()
	if not dialogue_line.text.is_empty():
		dialogue_label.type_out()
		await dialogue_label.finished_typing

	# Wait for next line
	if dialogue_line.has_tag("voice"):
		audio_stream_player.stream = load(dialogue_line.get_tag_value("voice"))
		audio_stream_player.play()
		await audio_stream_player.finished
		next(dialogue_line.next_id)
	elif dialogue_line.responses.size() > 0:
		balloon.focus_mode = Control.FOCUS_NONE
		responses_menu.show()
	elif dialogue_line.time != "":
		var time: float = dialogue_line.text.length() * 0.02 if dialogue_line.time == "auto" else dialogue_line.time.to_float()
		await get_tree().create_timer(time).timeout
		next(dialogue_line.next_id)
	else:
		is_waiting_for_input = true
		balloon.focus_mode = Control.FOCUS_ALL
		balloon.grab_focus()


## Go to the next line
func next(next_id: String) -> void:
	dialogue_line = await dialogue_resource.get_next_dialogue_line(next_id, temporary_game_states)


#region Signals


func _on_mutation_cooldown_timeout() -> void:
	if will_hide_balloon:
		will_hide_balloon = false
		balloon.hide()


func _on_mutated(mutation: Dictionary) -> void:
	if not mutation.is_inline:
		is_waiting_for_input = false
		will_hide_balloon = true
		mutation_cooldown.start(0.1)


func _on_balloon_gui_input(event: InputEvent) -> void:
	# See if we need to skip typing of the dialogue
	if dialogue_label.is_typing:
		var mouse_was_clicked: bool = event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT and event.is_pressed()
		var skip_button_was_pressed: bool = event.is_action_pressed(skip_action)
		if mouse_was_clicked or skip_button_was_pressed:
			get_viewport().set_input_as_handled()
			dialogue_label.skip_typing()
			return

	if not is_waiting_for_input: return
	if dialogue_line.responses.size() > 0: return

	# When there are no response options the balloon itself is the clickable thing
	get_viewport().set_input_as_handled()

	if event is InputEventMouseButton and event.is_pressed() and event.button_index == MOUSE_BUTTON_LEFT:
		next(dialogue_line.next_id)
	elif event.is_action_pressed(next_action) and get_viewport().gui_get_focus_owner() == balloon:
		next(dialogue_line.next_id)


func _on_responses_menu_response_selected(response: DialogueResponse) -> void:
	# Confirm sound for UI feedback on selection.
	Audio.play_sfx(&"ui_confirm")

	# P2: log the line the NPC just finished saying, then the player's choice.
	# Setting _skip_next_snapshot=true prevents the dialogue_line setter from
	# re-logging the same line when the next line arrives.
	if is_instance_valid(dialogue_line):
		_append_line_to_log(dialogue_line)
	_append_choice_to_log(response.text)
	_skip_next_snapshot = true

	# Record the visit so subsequent conversations with this character dim
	# this response option. Skip "End the conversation" — always available.
	var character: String = dialogue_line.character if is_instance_valid(dialogue_line) else ""
	if not character.is_empty() and response.text != EXIT_TEXT:
		GameState.visit_dialogue(character, response.id, response.text)
	next(response.next_id)


# ---- P2: log helpers ---------------------------------------------------

func _append_line_to_log(line: DialogueLine) -> void:
	var speaker: String = str(line.character) if line.character else ""
	var text: String = str(line.text) if line.text else ""
	if text.is_empty(): return
	var color := _speaker_color(speaker)
	var bbcode: String
	if speaker.is_empty():
		bbcode = "[color=%s]%s[/color]" % [color, text]
	else:
		bbcode = "[color=%s][b]%s:[/b][/color] %s" % [color, speaker.to_upper(), text]
	_append_to_log(bbcode)


func _append_choice_to_log(choice_text: String) -> void:
	_append_to_log("[color=%s][i]YOU: \"%s\"[/i][/color]" % [YOU_CHOICE_COLOR, choice_text])


## Appends a BBCode RichTextLabel to the LogContainer. If the user was already
## at the bottom (or close), auto-scrolls to reveal the new entry. If they had
## scrolled up to review, leaves their view alone.
func _append_to_log(rich_text: String) -> void:
	var was_at_bottom := _is_at_bottom()
	var label := RichTextLabel.new()
	label.bbcode_enabled = true
	label.fit_content = true
	label.scroll_active = false
	label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	label.text = rich_text
	_log.add_child(label)
	if was_at_bottom:
		# Two frames — first lets fit_content compute height, second lets the
		# scroll container recompute its max_value. Then we jump.
		await get_tree().process_frame
		await get_tree().process_frame
		var bar := _scroll.get_v_scroll_bar()
		_scroll.scroll_vertical = int(bar.max_value)


func _is_at_bottom() -> bool:
	if _scroll == null: return true
	var bar := _scroll.get_v_scroll_bar()
	# 8px slack — reader is "at bottom" if they're close to the edge.
	return bar.value >= bar.max_value - 8.0


func _speaker_color(name: String) -> String:
	return SPEAKER_COLORS.get(name, DEFAULT_SPEAKER_COLOR)


## Dims response buttons for choices the player has already taken with this
## character. Called from apply_dialogue_line after responses_menu populates.
##
## The 3.x DialogueResponsesMenu stores the DialogueResponse via
## `item.set_meta("response", response)` — use that instead of matching by
## button text (which loses identity if two responses share the same text).
func _dim_visited_responses() -> void:
	if not is_instance_valid(dialogue_line): return
	var character: String = dialogue_line.character
	if character.is_empty(): return
	var dimmed_count := 0
	var total_count := 0
	for child: Node in responses_menu.get_children():
		if not (child is Control): continue
		if not child.has_meta("response"): continue  # skip the template row
		total_count += 1
		var matching: DialogueResponse = child.get_meta("response")
		if matching == null: continue
		if matching.text == EXIT_TEXT:
			(child as CanvasItem).modulate = Color.WHITE
			continue
		var zipped: String = "%s_%s" % [matching.id, matching.text]
		if GameState.has_visited(character, zipped):
			(child as CanvasItem).modulate = VISITED_DIM
			dimmed_count += 1
		else:
			(child as CanvasItem).modulate = Color.WHITE
	if total_count > 0:
		print("[balloon] dim pass: %d/%d responses dimmed for character '%s'" %
			[dimmed_count, total_count, character])


#endregion
