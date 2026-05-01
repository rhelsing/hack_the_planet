extends CanvasLayer

## Top-center subtitle band for Walkie lines. Subscribes to Walkie.line_started
## and line_ended; typewrites text, shows a portrait (voice_portraits.tres
## lookup with placeholder fallback), fades out when the line ends.

@export var fade_duration: float = 0.18
@export var typewrite_speed: float = 45.0  # chars per second

# Authored sizes at hud.scale = 1.0. Multiplied by Settings.get_hud_scale()
# in _apply_hud_scale (called at _ready and on Events.settings_applied so
# the slider takes effect even with a line on screen).
const _PORTRAIT_SLOT_BASE: Vector2 = Vector2(64, 64)
const _PORTRAIT_INITIAL_FONT_BASE: int = 32
const _NAME_FONT_BASE: int = 14
const _TEXT_FONT_BASE: int = 16
const _PANEL_MIN_WIDTH_BASE: float = 520.0
const _HBOX_SEPARATION_BASE: int = 12

@onready var _root: Control = $Root
@onready var _panel: PanelContainer = $Root/CenterBox/Panel
@onready var _hbox: HBoxContainer = $Root/CenterBox/Panel/HBox
@onready var _portrait_slot: Control = $Root/CenterBox/Panel/HBox/PortraitSlot
@onready var _portrait: TextureRect = $Root/CenterBox/Panel/HBox/PortraitSlot/Portrait
@onready var _portrait_initial: Label = $Root/CenterBox/Panel/HBox/PortraitSlot/PortraitInitial
@onready var _name_label: Label = $Root/CenterBox/Panel/HBox/VBox/NameLabel
@onready var _text_label: RichTextLabel = $Root/CenterBox/Panel/HBox/VBox/TextLabel

var _portraits: Resource  # VoicePortraits; keyed character → Texture2D
var _typewrite_tween: Tween
var _fade_tween: Tween


func _ready() -> void:
	layer = 50  # above HUD, below pause menu
	_root.modulate.a = 0.0
	_root.visible = false
	var path := "res://dialogue/voice_portraits.tres"
	if ResourceLoader.exists(path):
		_portraits = load(path)
	Walkie.line_started.connect(_on_line_started)
	Walkie.line_ended.connect(_on_line_ended)
	# Companion (in-world voice) shares the same panel — different audio bus,
	# same HUD treatment. Portrait + name + typewriting subtitle all reuse the
	# walkie path. If we ever want a distinct look (e.g., no antenna icon for
	# diegetic voices), branch here.
	Companion.line_started.connect(_on_line_started)
	Companion.line_ended.connect(_on_line_ended)
	# HUD scale: portrait + fonts + panel width all read from a single
	# Settings.hud.scale knob, applied here and live on slider drags.
	Events.settings_applied.connect(_apply_hud_scale)
	_apply_hud_scale()


func _apply_hud_scale() -> void:
	var s: float = Settings.get_hud_scale()
	_portrait_slot.custom_minimum_size = _PORTRAIT_SLOT_BASE * s
	_portrait_initial.add_theme_font_size_override(&"font_size", int(_PORTRAIT_INITIAL_FONT_BASE * s))
	_name_label.add_theme_font_size_override(&"font_size", int(_NAME_FONT_BASE * s))
	# RichTextLabel has per-style size overrides — without explicit bold +
	# italics overrides, **bold** spans (from the emphasis-marker converter)
	# fall back to the theme default and don't scale with HUD size. Set all
	# four to the same value so emphasized text matches body text.
	var text_size: int = int(_TEXT_FONT_BASE * s)
	_text_label.add_theme_font_size_override(&"normal_font_size", text_size)
	_text_label.add_theme_font_size_override(&"bold_font_size", text_size)
	_text_label.add_theme_font_size_override(&"italics_font_size", text_size)
	_text_label.add_theme_font_size_override(&"bold_italics_font_size", text_size)
	_panel.custom_minimum_size = Vector2(_PANEL_MIN_WIDTH_BASE * s, 0)
	_hbox.add_theme_constant_override(&"separation", int(_HBOX_SEPARATION_BASE * s))


func _on_line_started(character: String, text: String) -> void:
	# Diagnostic: confirms the handler fires for every line. If a line
	# gets dropped from the subtitle UI, this print reveals whether it's
	# a signal-routing issue (no print = signal didn't reach us) vs a
	# rendering issue (print fires but text didn't appear).
	print("[walkie_ui] line_started char=%s text='%s' (pre-alpha=%.2f)" % [
		character, text.substr(0, 50), _root.modulate.a])
	_cancel_tweens()
	_apply_portrait(character)
	_name_label.text = character.to_upper()
	# Per-character name color from the VoicePortraits registry — keeps
	# the walkie chip in sync with the dialogue balloon's speaker color.
	# Falls back to the theme default when no color is registered.
	if _portraits != null and _portraits.has_method(&"has_color") \
			and bool(_portraits.call(&"has_color", character)):
		var c: Color = _portraits.call(&"get_color", character) as Color
		_name_label.add_theme_color_override(&"font_color", c)
		_apply_panel_border(c)
	else:
		_name_label.remove_theme_color_override(&"font_color")
		_apply_panel_border(Color(0.45, 0.85, 0.55, 0.9))  # default green
	# Snap to fully visible synchronously. Cutscene lines chain via
	# `await line_ended` → `line_started` synchronously, so the previous
	# line's fade-out tween may still have a queued visible=false callback
	# in flight; we forced visible=true + modulate=1 here so race outcomes
	# can't hide the new line. The fade-in tween below is a slight ease so
	# first-line entry isn't a hard pop.
	_root.visible = true
	_root.modulate.a = 1.0
	# Apply emphasis-marker conversion (**bold**/*italic*) — same converter
	# the dialogue balloon uses, so the subtitles match the balloon style.
	# Speaker color drives the **bold** span tint via VoicePortraits.
	var color_hex: String = ""
	if _portraits != null and _portraits.has_method(&"has_color") \
			and bool(_portraits.call(&"has_color", character)):
		var c: Color = _portraits.call(&"get_color", character) as Color
		color_hex = "#" + c.to_html(false)
	var formatted: String = TextEmphasis.format_for_display(text, color_hex)
	# Show text fully on line start. The typewrite-via-visible_ratio path
	# was unreliable for chained cutscene lines (rapid line_ended →
	# line_started transitions could leave visible_ratio at 0 with text
	# loaded, rendering as an invisible subtitle even though _root was
	# visible and modulate.a was 1.0). The line's natural audio duration
	# gives the player time to read; explicit typewriting can come back
	# later as a separate effect once the chain-transition bug is
	# understood at a deeper level.
	_text_label.text = formatted
	_text_label.visible_ratio = 1.0


func _on_line_ended() -> void:
	# Diagnostic: this is the ONLY place that fades the panel out (modulate
	# tween 1→0). If the subtitle is disappearing unexpectedly, every event
	# that gets here is a suspect. Pre-alpha tells us what state we're
	# starting from — alpha=0 means we're "ending" something already hidden,
	# which is fishy.
	print("[walkie_ui] line_ended — starting fade-out (pre-alpha=%.2f)" % _root.modulate.a)
	_cancel_tweens()
	# Fade modulate to 0 only — DO NOT touch _root.visible. The previous
	# implementation flipped visible=false in a tween_callback after fade,
	# but that callback could land in the same frame as the next line's
	# line_started (cutscene chains lines synchronously), occasionally
	# clobbering a freshly-displayed subtitle. modulate alpha alone is
	# enough to hide the panel; visible stays true for the lifetime of
	# the layer.
	_fade_tween = create_tween()
	_fade_tween.tween_property(_root, "modulate:a", 0.0, fade_duration)


func _cancel_tweens() -> void:
	if _typewrite_tween != null and _typewrite_tween.is_valid():
		_typewrite_tween.kill()
	if _fade_tween != null and _fade_tween.is_valid():
		_fade_tween.kill()


func _apply_portrait(character: String) -> void:
	var tex: Texture2D = null
	if _portraits != null and _portraits.has_method(&"get_portrait"):
		tex = _portraits.call(&"get_portrait", character) as Texture2D
	if tex != null:
		_portrait.texture = tex
		_portrait.visible = true
		_portrait_initial.visible = false
	else:
		# Placeholder — colored square with the character's initial. Color picked
		# from a hash of the name so every character gets a stable distinct tile.
		_portrait.texture = null
		_portrait.visible = false
		_portrait_initial.visible = true
		_portrait_initial.text = character.substr(0, 1).to_upper()
		var h: int = character.hash()
		var r: float = float((h >> 16) & 0xFF) / 255.0
		var g: float = float((h >> 8) & 0xFF) / 255.0
		var b: float = float(h & 0xFF) / 255.0
		var sb := _portrait_initial.get_theme_stylebox(&"normal") as StyleBoxFlat
		if sb == null:
			sb = StyleBoxFlat.new()
			_portrait_initial.add_theme_stylebox_override(&"normal", sb)
		sb.bg_color = Color(r * 0.6 + 0.2, g * 0.6 + 0.2, b * 0.6 + 0.2, 1.0)


# Tint the outer walkie panel's border color to match the speaker. The
# .tscn ships a green border; we mutate the live stylebox in place per
# line so the panel re-tints on each speaker swap. Alpha is preserved
# from the existing border (0.9) regardless of input alpha.
func _apply_panel_border(color: Color) -> void:
	if _panel == null:
		return
	var sb: StyleBoxFlat = _panel.get_theme_stylebox(&"panel") as StyleBoxFlat
	if sb == null:
		return
	sb.border_color = Color(color.r, color.g, color.b, 0.9)
