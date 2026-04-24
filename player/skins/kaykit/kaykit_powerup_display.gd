extends Label3D

## Floating emoji row above KayKit's head. Text rebuilds from GameState flags
## whenever a powerup_* flag changes. Order is fixed (love → secret → sex →
## god) so the slot position reads the same game after game.
##
## Subscribes to Events.flag_set — every GameState.set_flag emits this.

const _SLOTS: Array = [
	[&"powerup_love", "💘"],
	[&"powerup_secret", "💻"],
	[&"powerup_sex", "💋"],
	[&"powerup_god", "😇"],
]


func _ready() -> void:
	# Only show the player's powerups. Enemies using the KayKit skin would
	# otherwise render a heart over their head the moment the player owns
	# powerup_love. Walk up to the owning body and gate on pawn_group.
	var body: Node = _find_body()
	if body != null and body.get("pawn_group") != "player":
		visible = false
		return
	Events.flag_set.connect(_on_flag_set)
	_rebuild()


func _find_body() -> Node:
	var n: Node = get_parent()
	while n != null:
		if n is CharacterBody3D:
			return n
		n = n.get_parent()
	return null


func _on_flag_set(id: StringName, _value: Variant) -> void:
	# Only care about the four powerup flags.
	for entry in _SLOTS:
		if entry[0] == id:
			_rebuild()
			return


func _rebuild() -> void:
	var earned: Array[String] = []
	for entry in _SLOTS:
		var flag: StringName = entry[0]
		var emoji: String = entry[1]
		if bool(GameState.get_flag(flag, false)):
			earned.append(emoji)
	text = " ".join(earned)
