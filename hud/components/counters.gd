extends VBoxContainer
## Emoji + number counter for coins, plus an icon strip for keys and a
## walkie comm chip. Reads counts from GameState and subscribes to the
## events that bump them so we can animate the row on each increment.

const POP_SCALE := 1.18
const POP_S := 0.15

## Coin-row emoji. Defaults to 🥤 (cup-with-straw — closest emoji to a
## soda can; no aluminum-can glyph exists in Unicode). Swap to 🥫 if you
## want the tin-can silhouette instead. Inspector-editable so reskins are
## a one-field change without touching the .tscn.
@export var coin_emoji: String = "🥤"

# Walkie / companion comm chip — appears on the HUD once the player has been
# registered (Glitch's pick beat grants this). Pulses whenever a Walkie or
# Companion line plays. Same inventory pattern as keys, distinct row so it
# stays visually anchored regardless of which keys the player is carrying.
const WALKIE_ITEM_ID := &"walkie_talkie"

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
@onready var _coin_icon:  Label         = %CoinIcon
@onready var _coin_label: Label         = %CoinLabel
@onready var _keys_row:   HBoxContainer = %KeysRow
@onready var _walkie_row:  HBoxContainer = %WalkieRow
@onready var _walkie_icon: Label         = %WalkieIcon

const _WALKIE_IDLE_MODULATE: Color = Color(1, 1, 1, 0.55)
const _WALKIE_ACTIVE_MODULATE: Color = Color(0.55, 1, 0.65, 1)
var _walkie_pulse_tween: Tween


func _ready() -> void:
	# Apply the configured emoji once. Future swaps just change the export.
	_coin_icon.text = coin_emoji
	Events.coin_collected.connect(_on_coin_collected)
	Events.item_added.connect(_on_item_added)
	Events.item_removed.connect(_on_item_removed)
	# Pulse the walkie chip whenever a comm line plays — both channels share
	# the same affordance since "you have a comm channel" is the player-side
	# read; whether it's radio (Walkie) or in-world (Companion) is incidental.
	Walkie.line_started.connect(_on_walkie_line_started)
	Walkie.line_ended.connect(_on_walkie_line_ended)
	Companion.line_started.connect(_on_walkie_line_started)
	Companion.line_ended.connect(_on_walkie_line_ended)
	_refresh()


# ── Event handlers ──────────────────────────────────────────────────────

func _on_coin_collected(_coin: Node) -> void:
	_refresh_coins()
	_pop(_coin_row)


func _on_item_added(id: StringName) -> void:
	if id == WALKIE_ITEM_ID:
		_refresh_walkie()
		_pop(_walkie_row)
	elif String(id).ends_with(KEY_ID_SUFFIX):
		_refresh_keys()
		# Pop the last-added icon in the row (it's the newest).
		var icon_count := _keys_row.get_child_count()
		if icon_count > 0:
			_pop(_keys_row.get_child(icon_count - 1))


func _on_item_removed(id: StringName) -> void:
	if id == WALKIE_ITEM_ID:
		_refresh_walkie()
	elif String(id).ends_with(KEY_ID_SUFFIX):
		_refresh_keys()


# ── Refresh ─────────────────────────────────────────────────────────────

func _refresh() -> void:
	_refresh_coins()
	_refresh_keys()
	_refresh_walkie()


func _refresh_walkie() -> void:
	var owned: bool = GameState.has_item(WALKIE_ITEM_ID)
	_walkie_row.visible = owned
	if owned:
		_walkie_icon.modulate = _WALKIE_IDLE_MODULATE


func _on_walkie_line_started(_character: String, _text: String) -> void:
	if not _walkie_row.visible:
		return
	_walkie_icon.modulate = _WALKIE_ACTIVE_MODULATE
	if _walkie_pulse_tween != null and _walkie_pulse_tween.is_valid():
		_walkie_pulse_tween.kill()
	_walkie_pulse_tween = create_tween().set_loops().set_trans(Tween.TRANS_SINE)
	_walkie_pulse_tween.tween_property(_walkie_icon, "scale", Vector2(1.15, 1.15), 0.35)
	_walkie_pulse_tween.tween_property(_walkie_icon, "scale", Vector2(1.0, 1.0), 0.35)


func _on_walkie_line_ended() -> void:
	if _walkie_pulse_tween != null and _walkie_pulse_tween.is_valid():
		_walkie_pulse_tween.kill()
	_walkie_icon.scale = Vector2.ONE
	_walkie_icon.modulate = _WALKIE_IDLE_MODULATE


func _refresh_coins() -> void:
	var n := _read_count(&"coin_count")
	var total := _read_count(&"coin_total")
	# Show #/total once any coin has registered; fall back to bare count if
	# no coin has entered the scene yet (defensive — shouldn't happen mid-
	# gameplay because coin._ready registers before any pickup can fire).
	if total > 0:
		_coin_label.text = "%d / %d" % [n, total]
	else:
		_coin_label.text = "%d" % n
	_coin_row.visible = total > 0 or n > 0


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
