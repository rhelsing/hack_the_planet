extends CanvasLayer
## Dialogue balloon for Nathan Hoad's Dialogue Manager (3.x). Forked from
## the addon's example_balloon with two additions ported from 3dPFormer:
##   - Dims response buttons for choices the player has already made
##     (scoped per character via DialogueState.has_visited_dialogue).
##   - Records the choice on selection via DialogueState.visit_dialogue so
##     future conversations with the same character re-dim correctly.
## "End the conversation" is never dimmed (designer escape hatch).
## See docs/interactables.md §9.4.

const VISITED_DIM: Color = Color(0.5, 0.5, 0.5, 1.0)
const EXIT_TEXT: String = "End the conversation"
## Tag authors put on response options that end (or short-circuit) the
## conversation, e.g. `- Got it. [#exit]`. Tagged options are never dimmed
## and never recorded as visits — so "Got it." stays available the next
## time the player talks to this NPC.
const EXIT_TAG: String = "exit"

## Tag for options whose body is a one-way DECISION (Rule 8 side-block
## with mutually exclusive endpoints), as opposed to a probe sub-hub. The
## recursive dim treats `[#decision]`-tagged options as leaves: visiting
## once = fully explored, no recurse into the branch. Without this tag,
## the dim would demand the player pick every endpoint of the side-block.
##
## Example: `- Can I trust them? [#decision]` opens a Treat-as-tools /
## Treat-as-neighbors branch — the player picks one and the question is
## answered. Subsequent visits aren't expected.
const DECISION_TAG: String = "decision"
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

## Last NPC speaker seen on a real TYPE_DIALOGUE line. Used as the visit-key
## scope when DM hands us a synthetic TYPE_RESPONSE line (`character=''`),
## which happens when a `do` mutation (or anything that isn't CUE/GOTO) sits
## between the last spoken line and the response set — DM's lookahead doesn't
## fold the responses into the speaker's line, so dialogue_line.character is
## empty on the menu render. Without this fallback, the click handler bails
## and visits never reach GameState. Reset implicitly: a fresh conversation
## creates a fresh balloon instance, so this defaults back to "".
var _last_known_speaker: String = ""

## Phase B — texts of response options that are "new this render" (not yet
## marked seen for the current speaker). Recomputed at the start of every
## menu render. Used by _style_new_responses to apply green outline + reorder
## to top, and by _mark_responses_seen to update DialogueState after the
## render. Empty when nothing is new (the steady state).
var _new_response_texts: Dictionary = {}

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
			# Track the last real speaker so the visit-write/visit-read fallback
			# works when DM hands us a synthetic TYPE_RESPONSE line. See the
			# `_last_known_speaker` docstring above.
			if not String(value.character).is_empty():
				_last_known_speaker = value.character
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

## Countdown (frames) of remaining auto-scroll work after a log append.
## Each frame we lerp v_scrollbar.value toward its current max so the
## scroll catches up to the cascade of layout updates (RichTextLabel
## fit_content → LogContainer minimum_size → ScrollContainer range →
## ResponsesMenu resize) without snapping abruptly. Keeps the scroll
## feeling like an animation instead of a teleport. Counter bounds the
## animation so it stops cleanly even if the user starts manually
## scrolling mid-flight.
var _auto_scroll_frames: int = 0

## Lerp factor per frame for the smooth-scroll easing. 0.18 ≈ closes ~95%
## of the gap in 16 frames (~0.27s at 60fps). Higher = snappier; lower =
## more drift before settling.
const _AUTO_SCROLL_LERP: float = 0.18


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

	if auto_start:
		if not is_instance_valid(dialogue_resource):
			assert(false, DMConstants.get_error_message(DMConstants.ERR_MISSING_RESOURCE_FOR_AUTOSTART))
		start()


## UI "tick" sound as the player navigates between response choices.
func _on_response_focused(_control: Control) -> void:
	Audio.play_sfx(&"ui_move")


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
	# Smooth-scroll to bottom for a short window after any log append. We
	# can't do this in a single-shot await because the ScrollContainer's
	# v_scrollbar max_value updates in a cascade (RichTextLabel fit_content
	# → LogContainer minimum_size → ScrollContainer range → ResponsesMenu
	# resize). Lerping each frame keeps following the moving target while
	# feeling animated. Counter ensures we stop cleanly.
	if _auto_scroll_frames > 0 and _scroll != null:
		_auto_scroll_frames -= 1
		var bar := _scroll.get_v_scroll_bar()
		var target: float = bar.max_value
		var current: float = bar.value
		if target - current > 0.5:
			bar.value = lerp(current, target, _AUTO_SCROLL_LERP)
		else:
			bar.value = target


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
	_compute_new_responses()      # B.2 — populate _new_response_texts BEFORE styling so reorder runs against fresh data
	_style_skill_check_buttons()  # P4 — amber tint for [SKILL PCT%] prefixed responses
	_style_can_gated_buttons()    # speaker-color outline for [CAN]-prefixed unlock options
	_style_new_responses()        # B.3 — green outline + reorder to top for newly-unlocked options
	_dim_visited_responses()      # ported from 3dPFormer
	_mark_responses_seen()        # B.2 — commit seen AFTER render so the next render flips them to "not new"

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
	# this response option. Skip exit-tagged options + the legacy EXIT_TEXT.
	# DialogueState owns the sidecar (survives load_from_slot — see
	# autoload/dialogue_state.gd). Phase A's compat-write to GameState was
	# removed in Final.3 once the sidecar was verified live.
	var scope: String = _visit_scope()
	if not scope.is_empty() and not _is_exit_response(response):
		print("[balloon] visit RECORDED  scope=%s  text=%s" %
			[scope, response.text])
		DialogueState.visit_dialogue(scope, response.text)
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
	_auto_scroll_frames = 30


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


# ── Phase B — new-unlock detection / reorder / outline ─────────────────
# A response option is "new" when its text has never appeared in any prior
# menu render for this character (DialogueState.has_seen returns false).
# New options get a green outline + jump to the top of the response list,
# Disco-Elysium-style. After the render, _mark_responses_seen flips them to
# "seen" so subsequent renders treat them as normal.
#
# Exit-tagged options ([#exit] / EXIT_TEXT) are never tracked as "new" or
# "seen" — they're permanent fixtures that should never call attention to
# themselves and don't need persistence noise.

## Outline color for newly-unlocked options. Matches the passed skill-check
## banner color so "good thing happened" reads consistently across the UI.
const NEW_UNLOCK_OUTLINE: Color = Color(0.353, 0.910, 0.353, 1.0)  # #5AE85A

## SFX cue played once per render that contains at least one new option.
## Placeholder: `ui_confirm` — swap to a dedicated menu/page-turn cue once
## one is recorded (drop a new audio/cues/<name>.tres and update this const).
## Existing cues for reference: ui_move (navigation tick), ui_confirm (commit),
## ui_back (cancel), ui_type (single click), end_card_type (keyboard cluster).
const NEW_UNLOCK_SFX: StringName = &"ui_confirm"


## Walks the response menu's buttons and populates `_new_response_texts`
## with options that are NEWLY UNLOCKED in this menu — i.e., options the
## player hasn't seen yet, IN A MENU WHERE AT LEAST ONE OTHER OPTION IS
## ALREADY SEEN. The "another option already seen" gate is what makes this
## a true unlock detector and not a "first time at this hub" detector:
##
##   - First-ever render of a hub: no options seen yet → no highlights.
##     Player gets a clean menu without every option screaming "NEW".
##   - Re-entering an already-seen hub with a new [if /]-gated option that
##     just flipped visible → that option highlights, the seen siblings
##     don't.
##
## Skips exit-tagged options entirely (they neither count toward the
## "any-seen" check nor get highlighted themselves).
func _compute_new_responses() -> void:
	_new_response_texts.clear()
	var scope: String = _visit_scope()
	if scope.is_empty(): return
	var any_seen := false
	var unseen_texts: Array[String] = []
	for child: Node in responses_menu.get_children():
		if not child.has_meta("response"): continue
		var response: DialogueResponse = child.get_meta("response")
		if response == null: continue
		if _is_exit_response(response): continue
		if DialogueState.has_seen(scope, response.text):
			any_seen = true
		else:
			unseen_texts.append(response.text)
	# Only flag as "new" if the player has been here before — i.e., at least
	# one sibling option is already seen. Otherwise this is a first-render
	# and nothing should highlight.
	if any_seen:
		for t in unseen_texts:
			_new_response_texts[t] = true


## Commits the current render's option texts to DialogueState.seen so the
## NEXT render no longer flags them as "new". Must run after the visual
## styling pass (otherwise we'd seen-mark first and the styling would find
## nothing new). Skips exit options (they shouldn't pollute the seen dict).
func _mark_responses_seen() -> void:
	var scope: String = _visit_scope()
	if scope.is_empty(): return
	for child: Node in responses_menu.get_children():
		if not child.has_meta("response"): continue
		var response: DialogueResponse = child.get_meta("response")
		if response == null: continue
		if _is_exit_response(response): continue
		DialogueState.mark_seen(scope, response.text)


## B.3 — applies green outline to new-unlock buttons and reorders them to
## the top of the response menu (above the template). Plays the new-unlock
## SFX once if at least one option in this render is new.
##
## Per-state fill alpha is tuned so focus reads clearly as "selected" — the
## default theme's focus stylebox would normally provide that contrast, but
## once we override `focus` with our own green stylebox we have to supply
## the contrast ourselves. Empirically: 0.10 hover, 0.28 focus, 0.40 pressed.
##
## After reorder, configure_focus() is called on the DialogueResponsesMenu
## so its focus_neighbor_top/bottom pointers reflect the new visual order.
## Without that, arrow-key navigation walks the source order and the player
## sees the highlight skip past the top option — visibly broken.
func _style_new_responses() -> void:
	if _new_response_texts.is_empty(): return
	var moved_any := false
	for child: Node in responses_menu.get_children():
		if not (child is Button): continue
		if not child.has_meta("response"): continue
		var response: DialogueResponse = child.get_meta("response")
		if response == null: continue
		if not _new_response_texts.has(response.text): continue
		var btn := child as Button
		# Green outline — overrides any prior stylebox set by [CAN] / skill-check
		# styling. New-unlock visually dominates other markers because it's the
		# strongest "look at this" signal.
		for state: String in ["normal", "hover", "pressed", "focus"]:
			var sb := StyleBoxFlat.new()
			var fill_alpha: float = 0.0
			match state:
				"hover": fill_alpha = 0.10
				"focus": fill_alpha = 0.28
				"pressed": fill_alpha = 0.40
			sb.bg_color = Color(NEW_UNLOCK_OUTLINE.r, NEW_UNLOCK_OUTLINE.g, NEW_UNLOCK_OUTLINE.b, fill_alpha)
			sb.border_width_left = 2
			sb.border_width_top = 2
			sb.border_width_right = 2
			sb.border_width_bottom = 2
			sb.border_color = NEW_UNLOCK_OUTLINE
			sb.corner_radius_top_left = 3
			sb.corner_radius_top_right = 3
			sb.corner_radius_bottom_left = 3
			sb.corner_radius_bottom_right = 3
			btn.add_theme_stylebox_override(state, sb)
		# Reorder: bump to position 1 (slot 0 is the response_template — keep
		# it at the bottom of the z-order so duplicate() still works).
		responses_menu.move_child(btn, 1)
		moved_any = true
	if moved_any:
		# Rebuild focus chain in the new visual order — without this, arrow
		# navigation still follows the pre-reorder neighbors and the focus
		# highlight visibly skips past the top option.
		if responses_menu.has_method(&"configure_focus"):
			responses_menu.call(&"configure_focus")
		Audio.play_sfx(NEW_UNLOCK_SFX)


# ── Phase C — recursive subtree dim ────────────────────────────────────
# A parent option dims only when every visible non-exit child has been
# picked. To know what "the children" are, we walk the option's body
# through DM's resource.lines (following gotos / mutations / dialogue
# lines) until we hit a TYPE_RESPONSE block — those are the children. If
# we hit END or detect a cycle (loop-back to the parent hub), the option
# is a leaf with no subtree and dims on visit alone.
#
# Walker is structural (doesn't evaluate [if /] conditions). The caller
# (_subtree_fully_explored) cross-references with DialogueState to compute
# completion. Hidden children are checked for visibility there, not here.

## Walks from a starting block id through DM's resource.lines following
## non-menu types (goto / cue / mutation / dialogue / etc.) until it hits
## a TYPE_RESPONSE block. Returns that block's child entries, each as a
## small dict {text, tags, next_id} — enough info for the dim check to
## test visited-state and recurse into grandchildren.
##
## Returns [] for leaf paths: END, walker cycle, unknown type, empty
## start_id, OR — critically — when the walked-into response set contains
## `parent_response_id` in its own `responses` list. That last case is
## "the option's body loops back to the hub it lives in" — the option is
## a flat probe, not a parent of a sub-hub.
##
## `visited_block_ids` is mutated — pass {} on the top-level call; the
## recursion shares one accumulating set so a deeper walk can't revisit a
## hub already on the stack.
func _walk_subtree_from_id(start_id: String, visited_block_ids: Dictionary,
		parent_response_id: String = "") -> Array[Dictionary]:
	var children: Array[Dictionary] = []
	if dialogue_resource == null: return children
	var resource: DialogueResource = dialogue_resource
	# DM appends an id_trail like "@uid@123" or "|fallback" — strip to the
	# plain id for resource.lines lookup. The trail re-attaches when DM
	# does its own walking; our structural walk only needs the bare id.
	var current_id: String = _strip_id_trail(start_id)
	var hops: int = 0
	while hops < 64:  # hard cap as a belt-and-suspenders against missed cycles
		hops += 1
		if current_id.is_empty(): break
		if visited_block_ids.has(current_id): break  # cycle
		if not resource.lines.has(current_id): break  # extern / terminal
		visited_block_ids[current_id] = true
		var data: Dictionary = resource.lines.get(current_id)
		var t: String = String(data.get("type", ""))
		if t == "response":
			var ids: Array = data.get("responses", [])
			# Loop-back detection: if this response set contains the option
			# we started from, it's the option's PARENT hub, not a sub-hub.
			# Treat as a leaf and bail.
			if not parent_response_id.is_empty() and (parent_response_id in ids):
				break
			for child_id_v in ids:
				var child_id: String = String(child_id_v)
				if not resource.lines.has(child_id): continue
				var child_data: Dictionary = resource.lines.get(child_id)
				children.append({
					"id": child_id,
					"text": String(child_data.get("text", "")),
					"tags": child_data.get("tags", PackedStringArray()),
					"next_id": String(child_data.get("next_id", "")),
				})
			break
		elif t in ["goto", "cue", "mutation", "dialogue", "condition", "while", "comment", "random", "match"]:
			current_id = _strip_id_trail(String(data.get("next_id", "")))
		else:
			break  # unknown type or terminal
	return children


## Convenience overload — kicks off the walk from a DialogueResponse object.
## Returns the immediate child entries (no recursion). Forwards the response's
## id to the walker so it can detect loop-backs to the option's parent hub.
func _walk_response_subtree(response: DialogueResponse, visited_block_ids: Dictionary) -> Array[Dictionary]:
	if response == null: return []
	return _walk_subtree_from_id(response.next_id, visited_block_ids, response.id)


## Returns true iff this child option (and the entire subtree underneath
## it) has been visited. Definition:
##   - exit-tagged children count as "explored" by default (never required).
##   - not-visited leaf  → false.
##   - visited leaf      → true.
##   - visited parent    → true iff every visible non-exit grandchild is
##                         also fully explored (recursive).
##
## `visited_blocks` is the cycle-tracking set, accumulated across the whole
## recursion so a `=> back_to_parent` loop terminates cleanly.
func _is_child_fully_explored(child_data: Dictionary, character: String,
		visited_blocks: Dictionary) -> bool:
	var tags: PackedStringArray = child_data.get("tags", PackedStringArray())
	if EXIT_TAG in tags: return true
	var text: String = String(child_data.get("text", ""))
	if text == EXIT_TEXT: return true

	# Never-shown child: probably hidden behind an [if /] gate the player
	# hasn't tripped. Doesn't count toward parent completion — players
	# can't engage with content they've never been shown. (When the gate
	# eventually flips, the option becomes "new", marks seen, and from
	# then on counts normally — visit-it-or-block-dim.)
	if not DialogueState.has_seen(character, text):
		return true

	if not DialogueState.has_visited_dialogue(character, text):
		return false

	# Decision-tagged: the body is a one-way Rule-8 side-block (mutually
	# exclusive endpoints), not a probe sub-hub. Visiting once = answered.
	# Don't recurse — we'd otherwise demand every endpoint be picked, which
	# defeats "decision".
	if DECISION_TAG in tags:
		return true

	# Visited. Recurse into this child's subtree. Pass child's own id so the
	# walker detects loop-backs to the sub-hub it lives in.
	var grandkids: Array[Dictionary] = _walk_subtree_from_id(
			String(child_data.get("next_id", "")),
			visited_blocks,
			String(child_data.get("id", "")))
	if grandkids.is_empty(): return true  # leaf — done
	for gk in grandkids:
		if not _is_child_fully_explored(gk, character, visited_blocks):
			return false
	return true


## Top-level subtree completion check: does this response option have any
## visible non-exit children left unexplored? Used by _dim_visited_responses
## to decide whether a parent option dims the moment it's picked or only
## after its sub-hub is fully cleared.
##
## Returns true if the option has no sub-hub (a flat probe) — those dim on
## simple visit, same as before Phase C.
func _subtree_fully_explored(response: DialogueResponse, character: String) -> bool:
	if response == null: return true
	if character.is_empty(): return true
	var visited_blocks: Dictionary = {}
	var children: Array[Dictionary] = _walk_response_subtree(response, visited_blocks)
	if children.is_empty(): return true  # leaf
	for child in children:
		if not _is_child_fully_explored(child, character, visited_blocks):
			return false
	return true


## Strip the DM id-trail decoration so resource.lines.has() lookups match.
## DM uses two separators on next_ids:
##   - `@uid@id` — cross-resource ref. Take the part AFTER the last `@`.
##     (Inline-compiled dialogues have empty uid → `@id`, which still works
##     because we want the part after the lone `@`.)
##   - `id|fallback_id` — return-stack pipe. Take the part BEFORE the `|`.
func _strip_id_trail(id: String) -> String:
	if id.is_empty(): return id
	var pipe: int = id.find("|")
	if pipe > -1: id = id.substr(0, pipe)
	if "@" in id:
		var parts: PackedStringArray = id.split("@")
		id = parts[parts.size() - 1]
	return id


## Returns the current NPC speaker for visit-key scoping. Falls back to the
## last seen speaker when DM hands us a synthetic TYPE_RESPONSE line with
## empty character (see `_last_known_speaker`).
func _resolve_speaker() -> String:
	if is_instance_valid(dialogue_line) and not String(dialogue_line.character).is_empty():
		return dialogue_line.character
	return _last_known_speaker


## Stable scope key for visit/seen tracking. Was `_resolve_speaker()` but
## that drifts when an option's body ends with a different speaker than the
## next menu render — visit recorded under speaker A, dim check looked up
## under speaker B, miss. Resource path is one-per-NPC and never drifts.
## Falls back to last-known-speaker for unit tests that drive the balloon
## without a real DialogueResource bound.
func _visit_scope() -> String:
	if dialogue_resource != null and not String(dialogue_resource.resource_path).is_empty():
		return dialogue_resource.resource_path
	return _last_known_speaker


## True for response options that should never dim and never record a visit —
## either the legacy EXIT_TEXT exact-match or any option carrying the [#exit]
## tag (e.g. `- Got it. [#exit]`, `- That's all? [#exit]`).
func _is_exit_response(response: DialogueResponse) -> bool:
	if response == null: return false
	if response.text == EXIT_TEXT: return true
	return EXIT_TAG in response.tags


## Dims response buttons for choices the player has already taken with this
## character. Called from apply_dialogue_line after responses_menu populates.
##
## The 3.x DialogueResponsesMenu stores the DialogueResponse via
## `item.set_meta("response", response)` — use that instead of matching by
## button text (which loses identity if two responses share the same text).
func _dim_visited_responses() -> void:
	if not is_instance_valid(dialogue_line): return
	var scope: String = _visit_scope()
	if scope.is_empty(): return
	var dimmed_count := 0
	var total_count := 0
	for child: Node in responses_menu.get_children():
		if not (child is Control): continue
		if not child.has_meta("response"): continue  # skip the template row
		total_count += 1
		var matching: DialogueResponse = child.get_meta("response")
		if matching == null: continue
		if _is_exit_response(matching):
			(child as CanvasItem).modulate = Color.WHITE
			continue
		# Visit key is the text alone — see DialogueState._zip header for why
		# response.id is intentionally excluded.
		var was_visited: bool = DialogueState.has_visited_dialogue(scope, matching.text)
		# Phase C — for parent options with a sub-hub, "visited" alone isn't
		# enough to dim. The whole subtree must be explored. Flat probes
		# (no sub-hub) report subtree_explored=true unconditionally so they
		# behave exactly as they did before this phase shipped.
		var subtree_done: bool = _subtree_fully_explored(matching, scope)
		var should_dim: bool = was_visited and subtree_done
		print("[balloon] dim CHECK     scope=%s  text=%s  visited=%s  subtree_done=%s" %
			[scope, matching.text, was_visited, subtree_done])
		if should_dim:
			(child as CanvasItem).modulate = VISITED_DIM
			dimmed_count += 1
		else:
			(child as CanvasItem).modulate = Color.WHITE
	if total_count > 0:
		print("[balloon] dim pass: %d/%d responses dimmed for scope '%s'" %
			[dimmed_count, total_count, scope])


#endregion
