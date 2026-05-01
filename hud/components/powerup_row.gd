extends VBoxContainer
## Vertical stack of emoji-icon slots, one per owned ability. Walks
## PlayerBody/Abilities
## on _ready and subscribes to PlayerBody.ability_granted / enabled_changed
## so the row stays in sync as the player collects pickups.
##
## Cooldown overlay is driven by Events.skill_cooldown_started when the
## skill id matches an owned ability. Non-skill abilities never show one.

## Base sizes at hud.scale = 1.0. Multiplied by Settings.get_hud_scale()
## at slot-build time. Default Settings hud.scale is 2.0, so the visible
## default is 2× these — i.e., a 240×68 pill with a 56×56 icon.
const SLOT_SIZE_BASE := Vector2(120, 34)
const ICON_SIZE_BASE := Vector2(28, 28)
const FONT_SIZE_BASE: int = 12
const COLOR_ACTIVE   := Color(0, 1, 1)        # accent_cyan
const COLOR_INACTIVE := Color(0.10, 0.53, 0.20, 0.7)
## Cooldown tint — pill goes yellow at the moment the cooldown starts and
## fades back to COLOR_ACTIVE over the cooldown duration (the "progress
## fade" — yellow draining toward ready). When the fade finishes, the pill
## blinks yellow→active three times to flag "ability available again."
const COLOR_COOLDOWN := Color(1.0, 0.85, 0.10)  # yellow
const READY_BLINK_COUNT: int = 3
const READY_BLINK_INTERVAL: float = 0.08  # seconds per half-blink
const ICON_FALLBACK := "??"

# Per-ability icon texture + short label + the input action that fires the
# ability (so the pill can render the device-correct glyph in brackets,
# e.g. "GOD [Y]" on keyboard / "GOD [R2]" on gamepad). Icons live in
# hud/icons/powerups/; powerup_flag-keyed names map level → ability:
#   love=Skate (L1) · secret=HackMode (L2) · sex=Grapple (L3) · god=Godd (L4).
const ICONS := {
	&"Skate": {
		"icon": preload("res://hud/icons/powerups/love.png"),
		"text": "SKATE",
		# Skate is passive — always-on once unlocked, no toggle button. Empty
		# action skips the [glyph] suffix on this pill.
		"action": "",
	},
	&"HackModeAbility": {
		"icon": preload("res://hud/icons/powerups/secret.png"),
		"text": "HACK",
		"action": "interact",
	},
	&"GrappleAbility": {
		"icon": preload("res://hud/icons/powerups/sex.png"),
		"text": "GRAPPLE",
		"action": "grapple_fire",
	},
	&"GodAbility": {
		"icon": preload("res://hud/icons/powerups/god.png"),
		"text": "GOD",
		"action": "flare_shoot",
	},
}

var _player: Node = null
## ability_id (StringName) -> PanelContainer.
## Tinting goes through `panel.self_modulate` ONLY — that colors the pill's
## bg + border without cascading. The icon TextureRect and the label text
## are never tinted; powerup artwork and the SKATE/HACK/etc text always
## render in their real colors regardless of active/inactive/cooldown state.
var _slots: Dictionary = {}


func _ready() -> void:
	alignment = BoxContainer.ALIGNMENT_BEGIN
	add_theme_constant_override(&"separation", 6)
	Events.skill_cooldown_started.connect(_on_cooldown_started)
	# HUD scale changes rebuild the entire row so per-slot sizing picks up
	# the new value. Cheaper than retrofitting individual nodes' sizes.
	Events.settings_applied.connect(_on_settings_applied)
	call_deferred(&"_bind")


func _on_settings_applied() -> void:
	if _player != null and is_instance_valid(_player):
		_rebuild_from_player()


func _bind() -> void:
	_player = get_tree().get_first_node_in_group(&"player")
	if _player == null:
		print("[pw] PowerupRow._bind: no player in 'player' group — HUD row idle")
		visible = false
		return
	if _player.has_signal(&"ability_granted"):
		_player.ability_granted.connect(_on_ability_granted)
	if _player.has_signal(&"ability_enabled_changed"):
		_player.ability_enabled_changed.connect(_on_ability_enabled_changed)
	print("[pw] PowerupRow._bind: hooked player=%s" % _player.name)
	_rebuild_from_player()


func _rebuild_from_player() -> void:
	for id in _slots.keys():
		var panel: Node = _slots[id]
		if panel != null and is_instance_valid(panel):
			panel.queue_free()
	_slots.clear()
	var abilities := _player.get_node_or_null(^"Abilities")
	if abilities == null:
		print("[pw] PowerupRow._rebuild: no Abilities node under player")
		visible = false
		return
	var summary: Array[String] = []
	for child in abilities.get_children():
		var owned_now: bool = _is_owned(child)
		summary.append("%s(owned=%s)" % [child.get("ability_id"), owned_now])
		if owned_now:
			_add_slot(child.ability_id, _is_enabled(child))
	print("[pw] PowerupRow._rebuild scanned: %s → slots=%s" % [summary, _slots.keys()])
	visible = not _slots.is_empty()


# ── Signal handlers ─────────────────────────────────────────────────────

func _on_ability_granted(ability_id: StringName) -> void:
	if _slots.has(ability_id):
		print("[pw] PowerupRow.ability_granted(%s) — slot already exists, skipping" % ability_id)
		return
	print("[pw] PowerupRow.ability_granted(%s) — adding slot" % ability_id)
	_add_slot(ability_id, true)
	visible = true


func _on_ability_enabled_changed(ability_id: StringName, enabled: bool) -> void:
	var panel: PanelContainer = _slots.get(ability_id)
	if panel == null:
		return
	panel.self_modulate = COLOR_ACTIVE if enabled else COLOR_INACTIVE


func _on_cooldown_started(skill: StringName, seconds: float) -> void:
	var panel: PanelContainer = _slots.get(skill)
	if panel == null or seconds <= 0.0:
		return
	# Yellow progress fade: snap pill bg to yellow, tween back to active over
	# the cooldown's duration. The visual transition IS the progress meter.
	# Only `self_modulate` — never cascades, so the icon and label stay in
	# their real colors throughout.
	panel.self_modulate = COLOR_COOLDOWN
	var tw := create_tween()
	tw.tween_property(panel, "self_modulate", COLOR_ACTIVE, seconds)\
		.set_trans(Tween.TRANS_LINEAR)
	tw.tween_callback(func() -> void:
		if is_instance_valid(panel):
			_blink_ready(panel)
	)


# Three rapid yellow→active flashes signaling "available again." Tweens the
# pill bg only — icon and label text are never touched.
func _blink_ready(panel: PanelContainer) -> void:
	var tw := create_tween()
	for i in READY_BLINK_COUNT:
		tw.tween_property(panel, "self_modulate", COLOR_COOLDOWN, READY_BLINK_INTERVAL)
		tw.tween_property(panel, "self_modulate", COLOR_ACTIVE, READY_BLINK_INTERVAL)


# ── Slot construction ───────────────────────────────────────────────────

func _add_slot(ability_id: StringName, enabled: bool) -> void:
	var hud_scale: float = Settings.get_hud_scale()
	var slot := PanelContainer.new()
	slot.custom_minimum_size = SLOT_SIZE_BASE * hud_scale
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0, 0.1, 0.06, 0.85)
	style.border_width_left = 2
	style.border_width_top = 2
	style.border_width_right = 2
	style.border_width_bottom = 2
	style.border_color = COLOR_ACTIVE
	style.corner_radius_top_left = 6
	style.corner_radius_top_right = 6
	style.corner_radius_bottom_left = 6
	style.corner_radius_bottom_right = 6
	style.content_margin_left = 6
	style.content_margin_right = 6
	style.content_margin_top = 2
	style.content_margin_bottom = 2
	slot.add_theme_stylebox_override(&"panel", style)

	var icon_data: Variant = ICONS.get(ability_id, {})
	var icon_tex: Texture2D = icon_data.get("icon", null)
	var text: String = icon_data.get("text", ICON_FALLBACK)
	var action: String = icon_data.get("action", "")

	# Pill layout: icon flush-left, "TEXT [GLYPH]" immediately to its right.
	# HBox alignment BEGIN packs both children to the leading edge instead of
	# centering them in the 120px pill.
	var hbox := HBoxContainer.new()
	hbox.add_theme_constant_override(&"separation", 6)
	hbox.alignment = BoxContainer.ALIGNMENT_BEGIN
	slot.add_child(hbox)

	if icon_tex != null:
		var icon := TextureRect.new()
		icon.texture = icon_tex
		icon.custom_minimum_size = ICON_SIZE_BASE * hud_scale
		icon.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		hbox.add_child(icon)

	var label := Label.new()
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT
	label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	label.add_theme_font_size_override(&"font_size", int(FONT_SIZE_BASE * hud_scale))
	var glyph: String = Glyphs.for_action(action) if action != "" else ""
	if glyph != "" and glyph != "?":
		label.text = "%s [%s]" % [text, glyph]
	else:
		label.text = text
	hbox.add_child(label)

	add_child(slot)
	# Pill bg is the only thing that ever changes color. self_modulate stays
	# on the panel and never cascades; icon and label keep their real colors.
	slot.self_modulate = COLOR_ACTIVE if enabled else COLOR_INACTIVE
	_slots[ability_id] = slot


func _is_owned(node: Node) -> bool:
	return "owned" in node and bool(node.owned)


func _is_enabled(node: Node) -> bool:
	return "enabled" in node and bool(node.enabled)
