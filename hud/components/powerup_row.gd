extends VBoxContainer
## Vertical stack of emoji-icon slots, one per owned ability. Walks
## PlayerBody/Abilities
## on _ready and subscribes to PlayerBody.ability_granted / enabled_changed
## so the row stays in sync as the player collects pickups.
##
## Cooldown overlay is driven by Events.skill_cooldown_started when the
## skill id matches an owned ability. Non-skill abilities never show one.

const SLOT_SIZE := Vector2(72, 26)
const COLOR_ACTIVE   := Color(0, 1, 1)        # accent_cyan
const COLOR_INACTIVE := Color(0.10, 0.53, 0.20, 0.7)
const ICON_FALLBACK := "??"

# Per-ability icon (emoji) + short text. Most project fonts don't carry emoji
# glyphs, so we render both — the text reads on any font, the emoji shows up
# if the system font happens to have it.
const ICONS := {
	&"Skate":           {"emoji": "⛸", "text": "SKATE"},
	&"GrappleAbility":  {"emoji": "🪝", "text": "GRAPPLE"},
	&"GodAbility":      {"emoji": "😇", "text": "GOD"},
	&"HackModeAbility": {"emoji": "🕶", "text": "HACK"},
}

var _player: Node = null
var _slots: Dictionary = {}  # ability_id (StringName) -> Label node


func _ready() -> void:
	alignment = BoxContainer.ALIGNMENT_BEGIN
	add_theme_constant_override(&"separation", 6)
	Events.skill_cooldown_started.connect(_on_cooldown_started)
	call_deferred(&"_bind")


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
		_slots[id].queue_free()
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
	var slot: Control = _slots.get(ability_id)
	if slot == null:
		return
	slot.modulate = COLOR_ACTIVE if enabled else COLOR_INACTIVE


func _on_cooldown_started(skill: StringName, seconds: float) -> void:
	var slot: Control = _slots.get(skill)
	if slot == null or seconds <= 0.0:
		return
	slot.modulate.a = 0.4
	var tw := create_tween()
	tw.tween_interval(seconds)
	tw.tween_callback(func() -> void:
		if is_instance_valid(slot):
			slot.modulate.a = 1.0
	)


# ── Slot construction ───────────────────────────────────────────────────

func _add_slot(ability_id: StringName, enabled: bool) -> void:
	var slot := PanelContainer.new()
	slot.custom_minimum_size = SLOT_SIZE
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

	var label := Label.new()
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	label.add_theme_font_size_override(&"font_size", 12)
	var icon_data: Variant = ICONS.get(ability_id, {"emoji": "", "text": ICON_FALLBACK})
	var emoji: String = icon_data.get("emoji", "")
	var text: String = icon_data.get("text", ICON_FALLBACK)
	label.text = "%s %s" % [emoji, text] if emoji != "" else text
	slot.add_child(label)
	# Apply the active/inactive tint on the slot so the panel border + label
	# dim together.
	slot.modulate = COLOR_ACTIVE if enabled else COLOR_INACTIVE

	add_child(slot)
	_slots[ability_id] = slot


func _is_owned(node: Node) -> bool:
	return "owned" in node and bool(node.owned)


func _is_enabled(node: Node) -> bool:
	return "enabled" in node and bool(node.enabled)
