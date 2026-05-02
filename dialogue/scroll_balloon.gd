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
const PORTRAITS_PATH: String = "res://dialogue/voice_portraits.tres"

## Per-character speaker colors used for the log entries and the current
## CharacterLabel. Add entries as new speakers enter the game.
const SPEAKER_COLORS := {
	"Grit": "#E4C57A",
	"Me": "#6AD9FF",
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

@export_group("Typing Clicks")
## Per-character keyboard click cue. See audio/typing_clicks.gd for the gate.
@export var typing_cue: StringName = &"end_card_type"
## Override DialogueLabel.seconds_per_step for the scroll balloon. Lower = faster.
## Set to <= 0 to leave whatever the .tscn / addon default is untouched.
@export var typing_seconds_per_char: float = 0.018
## Only fire on every Nth character (1 = every char, 2 = every other, …).
@export_range(1, 8) var typing_every_n_chars: int = 2
## Chance gate stacked on top of every_n_chars. 1.0 = always.
@export_range(0.0, 1.0) var typing_chance: float = 0.6
## Skip whitespace (space/newline/tab) entirely — keeps the click pattern from
## firing on word gaps.
@export var typing_skip_whitespace: bool = true

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

## Per-speaker portrait, anchored upper-left of the balloon. Same registry
## as the walkie HUD (voice_portraits.tres). Hidden when no portrait is
## registered for the current speaker.
@onready var portrait_rect: TextureRect = %PortraitRect

var _portraits: Resource  # VoicePortraits

## True for exactly one setter dispatch when the response handler has already
## logged the previous line. Prevents double-logging.
var _skip_next_snapshot: bool = false

## Countdown (physics frames) of remaining auto-scroll snaps after a log
## append. Each frame we re-pin v_scrollbar.value to its current max so the
## snap survives the cascade of layout updates triggered by RichTextLabel
## fit_content + ResponsesMenu population.
var _auto_scroll_frames: int = 0


func _ready() -> void:
	balloon.hide()
	if ResourceLoader.exists(PORTRAITS_PATH):
		_portraits = load(PORTRAITS_PATH)
	Engine.get_singleton("DialogueManager").mutated.connect(_on_mutated)

	# If the responses menu doesn't have a next action set, use this one
	if responses_menu.next_action.is_empty():
		responses_menu.next_action = next_action

	# HIDE failed `[if ... /]` responses entirely instead of showing them
	# disabled/greyed. Also set in .tscn (belt-and-suspenders).
	responses_menu.hide_failed_responses = true

	# P4.5 — skill check outcome banners in the scroll log.
	if not Events.skill_check_rolled.is_connected(_on_skill_check_rolled):
		Events.skill_check_rolled.connect(_on_skill_check_rolled)

	# Hook response-menu focus change → UI move sound. The plugin's menu
	# emits `response_focused(control)` on focus change; we play ui_move.
	# ui_dev wired this cue in audio/cues/ui_move.tres (clicks).
	if responses_menu.has_signal(&"response_focused"):
		responses_menu.response_focused.connect(_on_response_focused)

	mutation_cooldown.timeout.connect(_on_mutation_cooldown_timeout)
	add_child(mutation_cooldown)

	# Per-character keystroke clicks. The DialogueLabel emits `spoke` once
	# per revealed character; we gate via TypingClicks. seconds_per_char is
	# applied here so the inspector knob actually reaches the addon node.
	if typing_seconds_per_char > 0.0:
		dialogue_label.seconds_per_step = typing_seconds_per_char
	if not dialogue_label.spoke.is_connected(_on_dialogue_label_spoke):
		dialogue_label.spoke.connect(_on_dialogue_label_spoke)

	if auto_start:
		if not is_instance_valid(dialogue_resource):
			assert(false, DMConstants.get_error_message(DMConstants.ERR_MISSING_RESOURCE_FOR_AUTOSTART))
		start()


## UI "tick" sound as the player navigates between response choices.
func _on_response_focused(_control: Control) -> void:
	Audio.play_sfx(&"ui_move")


func _on_dialogue_label_spoke(letter: String, letter_index: int, _speed: float) -> void:
	TypingClicks.play(letter_index, letter, typing_cue, typing_every_n_chars,
			typing_chance, typing_skip_whitespace)


## P4.5 — render a colored banner in the scroll log when a skill check resolves.
## Green = pass, red = fail. The percent shown is the EFFECTIVE chance the
## player had at the moment of the roll (after level bonuses).
func _on_skill_check_rolled(skill: StringName, chance_pct: int, succeeded: bool) -> void:
	var label := String(skill).capitalize()  # "Composure" etc.
	var banner: String
	if succeeded:
		banner = "[color=#5AE85A][b]✓ %s CHECK PASSED (%d%%)[/b][/color]" % [label.to_upper(), chance_pct]
	else:
		banner = "[color=#E85A5A][b]✗ %s CHECK FAILED (%d%%)[/b][/color]" % [label.to_upper(), chance_pct]
	_append_to_log(banner)


func _process(_delta: float) -> void:
	if is_instance_valid(dialogue_line):
		progress.visible = not dialogue_label.is_typing and dialogue_line.responses.size() == 0 and not dialogue_line.has_tag("voice")
	# Re-pin scroll to bottom for a short window after any log append. We can't
	# do this in a single-shot await because the ScrollContainer's v_scrollbar
	# max_value updates in a cascade (RichTextLabel fit_content → LogContainer
	# minimum_size → ScrollContainer range → ResponsesMenu resize), and hitting
	# the scrollbar once races the cascade. Driving the scrollbar directly
	# every frame for ~20 frames is cheap and always wins.
	if _auto_scroll_frames > 0 and _scroll != null:
		_auto_scroll_frames -= 1
		var bar := _scroll.get_v_scroll_bar()
		bar.value = bar.max_value


func _unhandled_input(event: InputEvent) -> void:
	# Up arrow past the FIRST response → scroll log up one chunk, so reader
	# can review history without leaving the conversation.
	if event.is_action_pressed(&"ui_up"):
		var focused := get_viewport().gui_get_focus_owner() as Control
		if focused != null:
			var buttons := _response_buttons()
			if buttons.size() > 0 and focused == buttons[0]:
				_scroll_log_by(-80)
				get_viewport().set_input_as_handled()
				return
	# Down arrow past the LAST response → scroll log down.
	elif event.is_action_pressed(&"ui_down"):
		var focused := get_viewport().gui_get_focus_owner() as Control
		if focused != null:
			var buttons := _response_buttons()
			if buttons.size() > 0 and focused == buttons[-1]:
				_scroll_log_by(80)
				get_viewport().set_input_as_handled()
				return
	# Mouse wheel on the ScrollContainer is already default-handled by Godot
	# so the user can scroll freely with the wheel without our intervention.
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
	_apply_portrait(dialogue_line.character)

	# P3: convert emphasis markers to BBCode for the live label.
	#   **word** → [b][color=<speaker>]WORD[/color][/b]
	#   *word*   → [i]word[/i]
	# Stash the raw `**word**` form in meta BEFORE mutating — `got_dialogue`
	# is emitted call_deferred (see dialogue_manager.gd:129) so dialogue.gd's
	# TTS hook fires AFTER this mutation. Without the meta, runtime hashes
	# the BBCode form while the prebake hashes the raw form → cache miss.
	dialogue_line.set_meta(&"raw_text", dialogue_line.text)
	dialogue_line.text = TextEmphasis.format_for_display(
		dialogue_line.text, _speaker_color(dialogue_line.character))

	dialogue_label.hide()
	dialogue_label.dialogue_line = dialogue_line

	responses_menu.hide()
	responses_menu.responses = dialogue_line.responses
	_style_skill_check_buttons()  # P4 — amber tint for [SKILL PCT%] prefixed responses
	_style_can_gated_buttons()    # speaker-color outline for [CAN]-prefixed unlock options
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
		# Visit key = text alone (see GameState header). response.id passed
		# through for backward compat / future per-line discrimination if
		# we ever need it again, but it's currently ignored by GameState.
		print("[balloon] visit RECORDED  char=%s  text=%s" %
			[character, response.text])
		GameState.visit_dialogue(character, response.id, response.text)
	next(response.next_id)


# ---- P2: log helpers ---------------------------------------------------

func _append_line_to_log(line: DialogueLine) -> void:
	var speaker: String = str(line.character) if line.character else ""
	var text: String = str(line.text) if line.text else ""
	if text.is_empty(): return
	# Apply the same emphasis conversion as the live label so log and live
	# are visually consistent. Speaker color drives the bold-span tint.
	text = TextEmphasis.format_for_display(text, _speaker_color(speaker))
	var color := _speaker_color(speaker)
	var bbcode: String
	if speaker.is_empty():
		# Unattributed line (no `Speaker:` prefix in the .dialogue file). Render
		# italic so it reads as scene direction; no speaker tag.
		bbcode = "[color=%s][i]%s[/i][/color]" % [color, text]
	else:
		bbcode = "[color=%s][b]%s:[/b][/color] %s" % [color, speaker.to_upper(), text]
	_append_to_log(bbcode)


func _append_choice_to_log(choice_text: String) -> void:
	_append_to_log("[color=%s][i]YOU: \"%s\"[/i][/color]" % [YOU_CHOICE_COLOR, choice_text])


## Appends a BBCode RichTextLabel to the LogContainer and ALWAYS auto-scrolls
## to the bottom after. DE-style — the newest line is what the player cares
## about. If they want to re-read history, up-arrow at top of responses
## scrolls the log (see _unhandled_input), OR mouse wheel.
##
## Auto-scroll is driven by _process re-pinning v_scrollbar.value to max_value
## for the frame window — see `_auto_scroll_frames`. A single-shot snap loses
## the race because fit_content / container layout cascades over many frames.
func _append_to_log(rich_text: String) -> void:
	var label := RichTextLabel.new()
	label.bbcode_enabled = true
	label.fit_content = true
	label.scroll_active = false
	label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	label.text = rich_text
	_log.add_child(label)
	_auto_scroll_frames = 20


## Scroll the log by a pixel delta, clamped to valid range.
func _scroll_log_by(delta: int) -> void:
	if _scroll == null: return
	var max_v: int = int(_scroll.get_v_scroll_bar().max_value)
	_scroll.scroll_vertical = clampi(_scroll.scroll_vertical + delta, 0, max_v)


## Returns the response buttons currently in the responses menu (skips the
## template row). Order matches visual top→bottom.
func _response_buttons() -> Array:
	var out: Array = []
	for child in responses_menu.get_children():
		if child is Button and child.has_meta("response"):
			out.append(child)
	return out


func _speaker_color(name: String) -> String:
	# Prefer the centralized VoicePortraits registry so dialogue, walkie,
	# and beacons all draw from the same per-character color. The local
	# SPEAKER_COLORS dict above is now a fallback for characters not
	# registered there (e.g. test placeholders like "Grit" / "Me").
	if _portraits != null and _portraits.has_method(&"has_color") \
			and bool(_portraits.call(&"has_color", name)):
		var c: Color = _portraits.call(&"get_color", name) as Color
		return "#" + c.to_html(false)
	return SPEAKER_COLORS.get(name, DEFAULT_SPEAKER_COLOR)


## Swap the upper-left portrait to match the current speaker. Hides the rect
## entirely if no portrait is registered (e.g. an unrecognised character).
## Also draws a 3px border in the character's registry color with 4px
## rounded corners, via a child Panel overlay (mounted lazily so we don't
## need to touch the .tscn).
func _apply_portrait(character: String) -> void:
	var tex: Texture2D = null
	if _portraits != null and _portraits.has_method(&"get_portrait"):
		tex = _portraits.call(&"get_portrait", character) as Texture2D
	if tex != null:
		portrait_rect.texture = tex
		portrait_rect.visible = true
		_apply_portrait_frame(character)
	else:
		portrait_rect.texture = null
		portrait_rect.visible = false


# Lazily mount a Panel child of the portrait that draws a colored border
# matching the character's registry color. Border width = 3, corner radius
# = 4, transparent fill so the texture shows through. Stylebox is rebuilt
# per character so each speaker swap retints cleanly.
func _apply_portrait_frame(character: String) -> void:
	var frame: Panel = portrait_rect.get_node_or_null(^"BorderOverlay") as Panel
	if frame == null:
		frame = Panel.new()
		frame.name = "BorderOverlay"
		frame.set_anchors_preset(Control.PRESET_FULL_RECT)
		frame.mouse_filter = Control.MOUSE_FILTER_IGNORE
		portrait_rect.add_child(frame)
	var color: Color = Color.WHITE
	if _portraits != null and _portraits.has_method(&"has_color") \
			and bool(_portraits.call(&"has_color", character)):
		color = _portraits.call(&"get_color", character) as Color
	var sb: StyleBoxFlat = StyleBoxFlat.new()
	sb.bg_color = Color(0, 0, 0, 0)
	sb.border_width_left = 3
	sb.border_width_top = 3
	sb.border_width_right = 3
	sb.border_width_bottom = 3
	sb.border_color = color
	sb.corner_radius_top_left = 4
	sb.corner_radius_top_right = 4
	sb.corner_radius_bottom_left = 4
	sb.corner_radius_bottom_right = 4
	frame.add_theme_stylebox_override(&"panel", sb)


# Emphasis conversion (`**word**` / `*word*`) lives in TextEmphasis
# (dialogue/text_emphasis.gd) so the walkie subtitle and the dialogue
# balloon share one converter. Color comes from _speaker_color() above.


# P4 — skill-check visual styling -----------------------------------------

## Response text matching `[SKILL PCT%]` gets its button tinted amber AND
## the displayed percent is replaced with the EFFECTIVE chance (base + the
## player's level bonus, clamped). So "[COMPOSURE 30%]" at skill level 2
## renders on-screen as "[COMPOSURE 60%] …".
##
## Button labels don't parse BBCode, so the whole button is colored via
## theme override. Condition-gated options that fail (is_allowed=false) are
## already hidden via hide_failed_responses — we only style visible buttons.
const SKILL_CHECK_COLOR: Color = Color(0.91, 0.78, 0.48, 1.0)  # amber, ~#E8C77A
const SKILL_CHECK_HOVER: Color = Color(1.0, 0.9, 0.55, 1.0)
const _SKILL_PREFIX_RE := "^\\[([A-Z][A-Z _]*) (\\d+)%\\]"

var _skill_prefix_regex: RegEx

func _style_skill_check_buttons() -> void:
	if _skill_prefix_regex == null:
		_skill_prefix_regex = RegEx.create_from_string(_SKILL_PREFIX_RE)
	for child: Node in responses_menu.get_children():
		if not (child is Button): continue
		if not child.has_meta("response"): continue
		var response: DialogueResponse = child.get_meta("response")
		if response == null: continue
		var btn := child as Button
		var match: RegExMatch = _skill_prefix_regex.search(response.text)
		if match == null: continue
		# Extract skill name + base percent, compute effective chance.
		var skill_display: String = match.get_string(1)  # "COMPOSURE"
		var base_pct := match.get_string(2).to_int()
		var skill_id := StringName(skill_display.to_lower().replace(" ", "_"))
		var effective := Skills.effective_chance(skill_id, base_pct)
		# Rewrite the button text to show effective chance (and flag gain if lvl>0).
		var level := Skills.get_level(skill_id)
		var level_marker: String = "" if level == 0 else " ★%d" % level
		var new_prefix := "[%s %d%%%s]" % [skill_display, effective, level_marker]
		btn.text = new_prefix + response.text.substr(match.get_end())
		# Amber tint for all skill-check buttons regardless of level.
		btn.add_theme_color_override("font_color", SKILL_CHECK_COLOR)
		btn.add_theme_color_override("font_hover_color", SKILL_CHECK_HOVER)
		btn.add_theme_color_override("font_focus_color", SKILL_CHECK_HOVER)


# ── [CAN]-prefixed unlock options ───────────────────────────────────────
# Response text starting with `[CAN]` (post-`[if /]` gate) marks an option
# the player unlocked through collectible progress. The marker is purely a
# render hint — stripped from response.text so it never reaches the chat
# log, the visited-dim key, or any downstream consumer. The button gets a
# 2px outline in the current speaker's color (3px radius), no bg fill.

const _CAN_PREFIX_RE := "^\\[CAN\\]\\s*"
var _can_prefix_regex: RegEx


func _style_can_gated_buttons() -> void:
	if _can_prefix_regex == null:
		_can_prefix_regex = RegEx.create_from_string(_CAN_PREFIX_RE)
	var border_color: Color = _current_speaker_color()
	for child: Node in responses_menu.get_children():
		if not (child is Button): continue
		if not child.has_meta("response"): continue
		var response: DialogueResponse = child.get_meta("response")
		if response == null: continue
		var match: RegExMatch = _can_prefix_regex.search(response.text)
		if match == null: continue
		# Strip the marker from BOTH the runtime response object and the
		# button label. Mutating response.text means the chat log + the
		# visited-dim key (which read response.text downstream) never see
		# `[CAN]` either.
		response.text = response.text.substr(match.get_end())
		var btn := child as Button
		btn.text = response.text
		for state in ["normal", "hover", "pressed", "focus"]:
			var sb := StyleBoxFlat.new()
			sb.bg_color = Color(border_color.r, border_color.g, border_color.b, 0.10) \
					if state == "hover" else Color(0, 0, 0, 0)
			sb.border_width_left = 2
			sb.border_width_top = 2
			sb.border_width_right = 2
			sb.border_width_bottom = 2
			sb.border_color = border_color
			sb.corner_radius_top_left = 3
			sb.corner_radius_top_right = 3
			sb.corner_radius_bottom_left = 3
			sb.corner_radius_bottom_right = 3
			btn.add_theme_stylebox_override(state, sb)


func _current_speaker_color() -> Color:
	if not is_instance_valid(dialogue_line): return Color.WHITE
	var name: String = dialogue_line.character
	if name.is_empty(): return Color.WHITE
	if _portraits != null and _portraits.has_method(&"has_color") \
			and bool(_portraits.call(&"has_color", name)):
		return _portraits.call(&"get_color", name) as Color
	return Color.WHITE


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
		# Visit key is the text alone — see GameState.visit_dialogue header
		# for why id is intentionally excluded.
		var was_visited: bool = GameState.has_visited(character, matching.text)
		print("[balloon] dim CHECK     char=%s  text=%s  visited=%s" %
			[character, matching.text, was_visited])
		if was_visited:
			(child as CanvasItem).modulate = VISITED_DIM
			dimmed_count += 1
		else:
			(child as CanvasItem).modulate = Color.WHITE
	if total_count > 0:
		print("[balloon] dim pass: %d/%d responses dimmed for character '%s'" %
			[dimmed_count, total_count, character])


#endregion
