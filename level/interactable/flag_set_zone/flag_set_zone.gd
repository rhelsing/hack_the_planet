extends Area3D
class_name FlagSetZone

## Drop this Area3D into a level. The first time the player enters its
## collision shape, the configured GameState flag flips to `value`. Useful
## for "the first time you reach point X, mark it" — e.g. the post-portal
## checkpoint that arms Glitch's "wasn't that neat?" line. One-shot by
## default; set `repeat = true` to re-fire every entry.

## Flag id to set on first entry. Empty = no-op.
@export var flag: StringName = &""
## Value to write when the flag fires. Bool by default; can be int/string
## via inspector if a richer state is needed.
@export var value: Variant = true
## When true, fires on every body_entered instead of the one-shot default.
@export var repeat: bool = false

var _fired: bool = false


func _ready() -> void:
	body_entered.connect(_on_body_entered)


func _on_body_entered(body: Node) -> void:
	if flag == &"":
		return
	if _fired and not repeat:
		return
	if not body.is_in_group(&"player"):
		return
	_fired = true
	GameState.set_flag(flag, value)
	print("[flag_set_zone] %s → %s" % [flag, value])
