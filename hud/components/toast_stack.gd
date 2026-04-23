extends VBoxContainer
## Event-driven toast surface. Subscribes to world events (skill checks, door
## opens, puzzle outcomes) and PlayerBody-local ability-granted signal; spawns
## a HUDToast per event. Caps at MAX_LIVE and drops the oldest on overflow.
##
## Format + color policy lives here (not on individual emitters) so the HUD
## owns presentation and siblings keep their signals terse.

const TOAST_SCENE := preload("res://hud/components/toast.tscn")
const MAX_LIVE := 3

const COLOR_SUCCESS := Color(0.20, 1.00, 0.40)
const COLOR_FAILURE := Color(1.00, 0.33, 0.47)
const COLOR_ACCENT  := Color(0.00, 1.00, 1.00)

var _player: Node = null


func _ready() -> void:
	alignment = BoxContainer.ALIGNMENT_END
	add_theme_constant_override(&"separation", 4)
	Events.skill_check_rolled.connect(_on_skill_check)
	Events.skill_granted.connect(_on_skill_granted)
	Events.door_opened.connect(_on_door_opened)
	Events.puzzle_solved.connect(_on_puzzle_solved)
	Events.puzzle_failed.connect(_on_puzzle_failed)
	# PlayerBody signals are local, not on the Events bus. Look up the pawn
	# after the tree is fully in place; guarded in case the current scene has
	# no player (main menu, loader, etc.).
	call_deferred(&"_connect_player_signals")


func _connect_player_signals() -> void:
	_player = get_tree().get_first_node_in_group(&"player")
	if _player == null:
		return
	if _player.has_signal(&"ability_granted"):
		_player.ability_granted.connect(_on_ability_granted)


# ── Event handlers ──────────────────────────────────────────────────────

func _on_skill_check(skill: StringName, chance_pct: int, ok: bool) -> void:
	var verdict := "SUCCESS" if ok else "FAILED"
	var color   := COLOR_SUCCESS if ok else COLOR_FAILURE
	_push("> [%s %d%%] %s" % [String(skill).to_upper(), chance_pct, verdict], color)


func _on_skill_granted(skill: StringName, new_level: int) -> void:
	# Only announce the first level — level-ups after that are noise during play.
	if new_level != 1:
		return
	_push("> %s ★%d" % [String(skill).to_upper(), new_level], COLOR_SUCCESS)


func _on_door_opened(id: StringName) -> void:
	_push("> ACCESS GRANTED :: %s" % String(id), COLOR_ACCENT)


func _on_puzzle_solved(id: StringName) -> void:
	_push("> %s :: SOLVED" % String(id).to_upper(), COLOR_SUCCESS)


func _on_puzzle_failed(id: StringName) -> void:
	_push("> %s :: FAILED" % String(id).to_upper(), COLOR_FAILURE)


func _on_ability_granted(ability_id: StringName) -> void:
	var label := String(ability_id).to_upper()
	# De-suffix common conventions: "GrappleAbility" → "GRAPPLE"
	if label.ends_with("ABILITY"):
		label = label.substr(0, label.length() - len("ABILITY"))
	_push("> %s ABILITY ONLINE" % label.strip_edges(), COLOR_ACCENT)


# ── Stack management ────────────────────────────────────────────────────

func _push(text: String, color: Color) -> void:
	var toast: HUDToast = TOAST_SCENE.instantiate()
	add_child(toast)
	toast.show_message(text, color)
	while get_child_count() > MAX_LIVE:
		var oldest := get_child(0)
		if oldest != toast:
			oldest.queue_free()
		else:
			break
