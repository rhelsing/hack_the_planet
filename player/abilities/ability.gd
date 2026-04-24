class_name Ability
extends Node

## Base class for player-character abilities (Skate, Hack, Grapple, Flare).
## Lives under PlayerBody/Abilities as a child. HUD powerup_row walks these
## children to render the icon row; see hud/components/powerup_row.gd.
##
## Contract required by powerup_row: `ability_id`, `owned`, `enabled`.
## Subclasses set `ability_id` and `powerup_flag` via @export.
##
## Flag mirror: owned = GameState.get_flag(powerup_flag). Subclasses that
## need per-frame input should check `owned` before acting.

@export var ability_id: StringName
@export var powerup_flag: StringName

var owned: bool = false
var enabled: bool = true


func _ready() -> void:
	_sync_from_flag()
	Events.flag_set.connect(_on_flag_set)


func _on_flag_set(id: StringName, _value: Variant) -> void:
	if id != powerup_flag:
		return
	_sync_from_flag()


func _sync_from_flag() -> void:
	var new_owned := bool(GameState.get_flag(powerup_flag, false))
	if new_owned == owned:
		return
	owned = new_owned
	print("[pw] Ability[%s, flag=%s].owned -> %s" % [ability_id, powerup_flag, owned])
	# Tell the PlayerBody so HUD signals fire. Use a group lookup rather than
	# a hardcoded parent so this works when abilities live under a different
	# rig (e.g. companions).
	var body: Node = _find_body()
	if body == null:
		print("[pw]   ability %s: no body found — HUD won't hear" % ability_id)
		return
	if not body.has_method(&"notify_ability_granted"):
		print("[pw]   ability %s: body missing notify_ability_granted" % ability_id)
		return
	if owned:
		print("[pw]   ability %s -> body.notify_ability_granted" % ability_id)
		body.call(&"notify_ability_granted", ability_id)


func _find_body() -> Node:
	var n: Node = get_parent()
	while n != null:
		if n is CharacterBody3D:
			return n
		n = n.get_parent()
	return null
