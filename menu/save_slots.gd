extends Control
## Shared Save/Load/New picker. `configure({"mode": "save" | "load" | "new"})`
## before adding to the tree. Emits `back_requested` on cancel.
##
## Modes:
##   "new"  — pick a slot to start a new game in (empty slots are green-lit,
##             populated slots show "Overwrite").
##   "save" — overwrite any of A/B/C from gameplay (pause → Save-As path).
##   "load" — only populated slots are clickable.

signal back_requested

@onready var _title:  Label = %Title
@onready var _card_a: Control = %CardA
@onready var _card_b: Control = %CardB
@onready var _card_c: Control = %CardC
@onready var _back_btn: Button = %BackBtn

var _mode: String = "load"  # "save" | "load" | "new"


func configure(args: Dictionary) -> void:
	_mode = args.get("mode", "load")


func _ready() -> void:
	print("[save_slots] _ready start, mode=%s" % _mode)
	# process_mode stays at INHERIT (Godot default). When pushed from the main
	# menu the parent tree runs unpaused → we run. When pushed from pause_menu
	# the parent has WHEN_PAUSED → we inherit and still run. Explicitly setting
	# WHEN_PAUSED here would DISABLE the scene on the main menu (where the tree
	# isn't paused) — buttons wouldn't receive input, arrows would still work
	# because focus-nav happens at Viewport level. That was the 10-cycle bug.
	Events.modal_opened.emit(&"save_slots")
	tree_exited.connect(func() -> void: Events.modal_closed.emit(&"save_slots"))
	print("[save_slots] _title=%s _card_a=%s _back_btn=%s" % [_title, _card_a, _back_btn])
	_title.text = _title_for_mode()
	_refresh_card(&"a", _card_a)
	_refresh_card(&"b", _card_b)
	_refresh_card(&"c", _card_c)
	_wire_cards()
	_back_btn.pressed.connect(func() -> void:
		print("[save_slots] BACK BTN PRESSED signal fired!")
		_play_back_sfx()
		back_requested.emit()
	)
	# Track every focus change so we can see what arrows are actually focusing.
	get_viewport().gui_focus_changed.connect(func(c: Control) -> void:
		print("[save_slots] focus → %s (disabled=%s focus_mode=%s)" % [
			c, ("n/a" if c == null else str(c.disabled if "disabled" in c else "n/a")),
			("n/a" if c == null else c.focus_mode),
		])
	)
	_back_btn.grab_focus()
	print("[save_slots] _ready done — wires installed, focused=%s" % get_viewport().gui_get_focus_owner())


func _wire_cards() -> void:
	print("[save_slots] _wire_cards: cards=[%s, %s, %s]" % [_card_a, _card_b, _card_c])
	_wire_card_confirm(_card_a, &"a")
	_wire_card_confirm(_card_b, &"b")
	_wire_card_confirm(_card_c, &"c")


func _title_for_mode() -> String:
	match _mode:
		"save": return "SAVE SLOT"
		"new":  return "NEW GAME — PICK SLOT"
		_:      return "LOAD SLOT"


func _wire_card_confirm(card: Control, id: StringName) -> void:
	if card == null:
		push_warning("[save_slots] _wire_card_confirm: card NULL for slot %s" % id)
		return
	var btn: Button = card.get_node_or_null(^"Col/Confirm") as Button
	print("[save_slots] _wire_card_confirm slot=%s card=%s btn=%s" % [id, card.name, btn])
	if btn == null:
		push_warning("save_slots: Confirm button missing on card %s" % card.name)
		return
	btn.pressed.connect(_on_card_confirm.bind(id))


func _on_card_confirm(id: StringName) -> void:
	print("[save_slots] confirm pressed for slot=%s mode=%s" % [id, _mode])
	var save_service := get_tree().root.get_node_or_null(^"SaveService")
	if save_service == null:
		push_error("[save_slots] SaveService autoload missing — can't confirm")
		return
	match _mode:
		"save":
			save_service.call(&"save_to_slot", id)
			_refresh_card(id, _card_for(id))
		"load":
			if save_service.call(&"has_slot", id):
				save_service.call(&"load_from_slot", id)
				back_requested.emit()
			else:
				print("[save_slots] load: slot %s is empty, ignoring" % id)
		"new":
			# begin_new_game resets GameState, writes the slot, sets active_slot.
			# Caller (main menu) then navigates to the gameplay scene.
			print("[save_slots] new: calling begin_new_game(%s)" % id)
			save_service.call(&"begin_new_game", id)
			print("[save_slots] new: active_slot=%s — emitting back_requested" % save_service.active_slot)
			back_requested.emit()


func _card_for(id: StringName) -> Control:
	match String(id):
		"a": return _card_a
		"b": return _card_b
		"c": return _card_c
	return null


func _refresh_card(id: StringName, card: Control) -> void:
	if card == null:
		return
	# All card children live under a Col VBoxContainer inside the card panel.
	var label_slot: Label = card.get_node_or_null(^"Col/SlotLabel") as Label
	var label_meta: Label = card.get_node_or_null(^"Col/MetaLabel") as Label
	var btn: Button = card.get_node_or_null(^"Col/Confirm") as Button
	var save_service := get_tree().root.get_node_or_null(^"SaveService")
	if label_slot != null:
		label_slot.text = String(id).to_upper()
	var has: bool = save_service != null and bool(save_service.call(&"has_slot", id))
	# menu_button.gd writes `text` from its `label` property via _refresh_text(),
	# so we set `label` here — if we set `text` it gets overwritten on next
	# focus-change. (Found by manual playtest — clicks did nothing because
	# the path was also wrong and the connect never ran.)
	if not has:
		if label_meta != null:
			label_meta.text = "[ empty ]"
		if btn != null:
			match _mode:
				"load":
					btn.disabled = true
					_set_btn_label(btn,"--")
				"new":
					btn.disabled = false
					_set_btn_label(btn,"Start here")
				_:
					btn.disabled = false
					_set_btn_label(btn,"Save here")
		return
	var meta: Dictionary = save_service.call(&"slot_metadata", id)
	var ts := int(meta.get("timestamp", 0))
	var playtime := float(meta.get("playtime_s", 0.0))
	var level := String(meta.get("level_id", "?"))
	if label_meta != null:
		label_meta.text = "%s\n%s\n%s" % [
			_fmt_time(ts),
			level,
			_fmt_playtime(playtime),
		]
	if btn != null:
		btn.disabled = false
		match _mode:
			"load":    btn.set(&"label", "Load")
			"new":     btn.set(&"label", "Overwrite → New")
			_:         _set_btn_label(btn,"Overwrite")


func _fmt_time(ts: int) -> String:
	if ts <= 0:
		return "--"
	var d := Time.get_datetime_dict_from_unix_time(ts)
	return "%04d-%02d-%02d %02d:%02d" % [d.year, d.month, d.day, d.hour, d.minute]


func _fmt_playtime(secs: float) -> String:
	var total: int = int(secs)
	@warning_ignore("integer_division")
	var h: int = total / 3600
	@warning_ignore("integer_division")
	var m: int = (total / 60) % 60
	return "%dh %02dm" % [h, m]


func _input(event: InputEvent) -> void:
	# Diagnostic — print everything that reaches _input so we can see which
	# events are making it here vs. being swallowed upstream.
	if event.is_action_pressed(&"ui_accept"):
		print("[save_slots] _input: ui_accept — focused=%s" % get_viewport().gui_get_focus_owner())
	if event.is_action_pressed(&"ui_cancel"):
		print("[save_slots] _input: ui_cancel — emitting back_requested")
		_play_back_sfx()
		back_requested.emit()
		get_viewport().set_input_as_handled()
	if event is InputEventMouseButton and (event as InputEventMouseButton).pressed:
		var ev := event as InputEventMouseButton
		print("[save_slots] _input: mouse button=%d at %s" % [ev.button_index, ev.position])


func _play_back_sfx() -> void:
	var audio := get_tree().root.get_node_or_null(^"Audio")
	if audio != null and audio.has_method(&"play_sfx"):
		audio.call(&"play_sfx", &"ui_back")


func _set_btn_label(btn: Button, value: String) -> void:
	# The Confirm button is an instance of menu_button.tscn whose script is
	# TerminalButton. The authored `label` property drives the rendered text
	# via TerminalButton._refresh_text; we set it through the cast so the
	# setter fires properly.
	var tb := btn as TerminalButton
	if tb != null:
		tb.label = value
	else:
		btn.text = value
