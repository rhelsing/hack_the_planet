extends VBoxContainer
## Emoji + number counters for coins and floppies, plus an icon strip for
## keys. Reads counts from GameState (schema v2 — interactables_dev) and
## subscribes to the events that bump them so we can animate the row on
## each increment.

const POP_SCALE := 1.18
const POP_S := 0.15

const FLOPPY_ITEM_ID := &"floppy_disk"

# Any inventory id ending with this suffix renders as a key icon in KeysRow.
# Covers pickup_key's `red_key`, troll-gives-key, future `blue_key` etc.
const KEY_ID_SUFFIX := "_key"
const KEY_ICON := "🔑"

# Color tint per key-id prefix. Unknown prefixes fall back to default cyan.
const KEY_COLORS := {
	"red": Color(1.0, 0.30, 0.30),
	"blue": Color(0.35, 0.65, 1.00),
	"green": Color(0.30, 1.00, 0.50),
	"yellow": Color(1.00, 0.90, 0.30),
	"troll": Color(0.55, 1.00, 0.20),
}
const KEY_COLOR_FALLBACK := Color(0, 1, 1)  # accent_cyan

@onready var _coin_row:   HBoxContainer = %CoinRow
@onready var _coin_label: Label         = %CoinLabel
@onready var _floppy_row:   HBoxContainer = %FloppyRow
@onready var _floppy_label: Label         = %FloppyLabel
@onready var _keys_row:   HBoxContainer = %KeysRow


func _ready() -> void:
	Events.coin_collected.connect(_on_coin_collected)
	Events.item_added.connect(_on_item_added)
	Events.item_removed.connect(_on_item_removed)
	_refresh()


# ── Event handlers ──────────────────────────────────────────────────────

func _on_coin_collected(_coin: Node) -> void:
	_refresh_coins()
	_pop(_coin_row)


func _on_item_added(id: StringName) -> void:
	if id == FLOPPY_ITEM_ID:
		_refresh_floppies()
		_pop(_floppy_row)
	elif String(id).ends_with(KEY_ID_SUFFIX):
		_refresh_keys()
		# Pop the last-added icon in the row (it's the newest).
		var icon_count := _keys_row.get_child_count()
		if icon_count > 0:
			_pop(_keys_row.get_child(icon_count - 1))


func _on_item_removed(id: StringName) -> void:
	if id == FLOPPY_ITEM_ID:
		_refresh_floppies()
	elif String(id).ends_with(KEY_ID_SUFFIX):
		_refresh_keys()


# ── Refresh ─────────────────────────────────────────────────────────────

func _refresh() -> void:
	_refresh_coins()
	_refresh_floppies()
	_refresh_keys()


func _refresh_coins() -> void:
	var n := _read_count(&"coin_count")
	_coin_label.text = "%d" % n
	_coin_row.visible = n > 0


func _refresh_floppies() -> void:
	var n := _read_count(&"floppy_count")
	_floppy_label.text = "%d" % n
	_floppy_row.visible = n > 0


func _refresh_keys() -> void:
	for child in _keys_row.get_children():
		child.queue_free()
	for id in _read_inventory():
		if not String(id).ends_with(KEY_ID_SUFFIX):
			continue
		_keys_row.add_child(_make_key_icon(id))
	_keys_row.visible = _keys_row.get_child_count() > 0


func _make_key_icon(id: StringName) -> Label:
	var lbl := Label.new()
	lbl.custom_minimum_size = Vector2(32, 0)
	lbl.add_theme_font_size_override(&"font_size", 26)
	lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	lbl.text = KEY_ICON
	lbl.modulate = _color_for_key(id)
	lbl.tooltip_text = String(id)
	return lbl


func _color_for_key(id: StringName) -> Color:
	var s := String(id)
	# "red_key" → prefix "red"; "troll_key" → "troll".
	var underscore := s.find("_")
	if underscore <= 0:
		return KEY_COLOR_FALLBACK
	var prefix := s.substr(0, underscore)
	return KEY_COLORS.get(prefix, KEY_COLOR_FALLBACK)


# ── Helpers ─────────────────────────────────────────────────────────────

func _read_count(key: StringName) -> int:
	var gs := get_tree().root.get_node_or_null(^"GameState")
	if gs == null:
		return 0
	var value = gs.get(key)
	return int(value) if value != null else 0


func _read_inventory() -> Array:
	var gs := get_tree().root.get_node_or_null(^"GameState")
	if gs == null or not ("inventory" in gs):
		return []
	var inv = gs.inventory
	return inv if inv is Array else []


func _pop(target: Control) -> void:
	if target == null or not target.visible:
		return
	target.pivot_offset = target.size * 0.5
	target.scale = Vector2.ONE
	var tw := create_tween()
	tw.tween_property(target, "scale", Vector2(POP_SCALE, POP_SCALE), POP_S * 0.5)\
		.set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	tw.tween_property(target, "scale", Vector2.ONE, POP_S * 0.5)\
		.set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_IN)
