extends CanvasLayer

## Top-center subtitle band for Walkie lines. Subscribes to Walkie.line_started
## and line_ended; typewrites text, shows a portrait (voice_portraits.tres
## lookup with placeholder fallback), fades out when the line ends.

@export var fade_duration: float = 0.18
@export var typewrite_speed: float = 45.0  # chars per second

@onready var _root: Control = $Root
@onready var _panel: PanelContainer = $Root/CenterBox/Panel
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


func _on_line_started(character: String, text: String) -> void:
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
	_text_label.text = ""
	_root.visible = true
	var fade := create_tween()
	fade.tween_property(_root, "modulate:a", 1.0, fade_duration)
	# Apply emphasis-marker conversion (**bold**/*italic*) — same converter
	# the dialogue balloon uses, so the subtitles match the balloon style.
	# Speaker color drives the **bold** span tint via VoicePortraits.
	var color_hex: String = ""
	if _portraits != null and _portraits.has_method(&"has_color") \
			and bool(_portraits.call(&"has_color", character)):
		var c: Color = _portraits.call(&"get_color", character) as Color
		color_hex = "#" + c.to_html(false)
	var formatted: String = TextEmphasis.format_for_display(text, color_hex)
	# Typewrite via visible_ratio.
	_text_label.text = formatted
	_text_label.visible_ratio = 0.0
	_typewrite_tween = create_tween()
	var duration: float = max(0.4, float(text.length()) / typewrite_speed)
	_typewrite_tween.tween_property(_text_label, "visible_ratio", 1.0, duration)


func _on_line_ended() -> void:
	_cancel_tweens()
	_fade_tween = create_tween()
	_fade_tween.tween_property(_root, "modulate:a", 0.0, fade_duration)
	_fade_tween.tween_callback(func(): _root.visible = false)


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
