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
	Events.flag_set.connect(_on_flag_set)
	_rebuild()


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
