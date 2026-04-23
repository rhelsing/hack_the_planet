extends HBoxContainer
## Row of emoji-icon slots, one per owned ability. Walks PlayerBody/Abilities
## on _ready and subscribes to PlayerBody.ability_granted / enabled_changed
## so the row stays in sync as the player collects pickups.
##
## Cooldown overlay is driven by Events.skill_cooldown_started when the
## skill id matches an owned ability. Non-skill abilities never show one.

const SLOT_SIZE := Vector2(40, 40)
const COLOR_ACTIVE   := Color(0, 1, 1)        # accent_cyan
const COLOR_INACTIVE := Color(0.10, 0.53, 0.20, 0.7)
const ICON_FALLBACK := "❓"

# Emoji fallback per known ability id. Replace with proper textures in v1.1.
const ICONS := {
	&"Skate": "⛸",
	&"GrappleAbility": "🪝",
	&"FlareAbility": "🚨",
	&"HackModeAbility": "🕶",
}

var _player: Node = null
var _slots: Dictionary = {}  # ability_id (StringName) -> Label node


func _ready() -> void:
	alignment = BoxContainer.ALIGNMENT_CENTER
	add_theme_constant_override(&"separation", 6)
	Events.skill_cooldown_started.connect(_on_cooldown_started)
	call_deferred(&"_bind")


func _bind() -> void:
	_player = get_tree().get_first_node_in_group(&"player")
	if _player == null:
		visible = false
		return
	if _player.has_signal(&"ability_granted"):
		_player.ability_granted.connect(_on_ability_granted)
	if _player.has_signal(&"ability_enabled_changed"):
		_player.ability_enabled_changed.connect(_on_ability_enabled_changed)
	_rebuild_from_player()


func _rebuild_from_player() -> void:
	for id in _slots.keys():
		_slots[id].queue_free()
	_slots.clear()
	var abilities := _player.get_node_or_null(^"Abilities")
	if abilities == null:
		visible = false
		return
	for child in abilities.get_children():
		if _is_owned(child):
			_add_slot(child.ability_id, _is_enabled(child))
	visible = not _slots.is_empty()


# ── Signal handlers ─────────────────────────────────────────────────────

func _on_ability_granted(ability_id: StringName) -> void:
	if _slots.has(ability_id):
		return
	_add_slot(ability_id, true)
	visible = true


func _on_ability_enabled_changed(ability_id: StringName, enabled: bool) -> void:
	var slot: Label = _slots.get(ability_id)
	if slot == null:
		return
	slot.modulate = COLOR_ACTIVE if enabled else COLOR_INACTIVE


func _on_cooldown_started(skill: StringName, seconds: float) -> void:
	var slot: Label = _slots.get(skill)
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
	var slot := Label.new()
	slot.custom_minimum_size = SLOT_SIZE
	slot.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	slot.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	slot.add_theme_font_size_override(&"font_size", 28)
	slot.text = ICONS.get(ability_id, ICON_FALLBACK)
	slot.modulate = COLOR_ACTIVE if enabled else COLOR_INACTIVE
	add_child(slot)
	_slots[ability_id] = slot


func _is_owned(node: Node) -> bool:
	return "owned" in node and bool(node.owned)


func _is_enabled(node: Node) -> bool:
	return "enabled" in node and bool(node.enabled)
