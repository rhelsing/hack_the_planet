class_name VoicePortraits
extends Resource

## Character-name → portrait Texture2D map. Parallel to voices.gd.
## WalkieUI reads this; falls back to a procedural placeholder for any
## character not registered. Edit the .tres in the inspector, or add entries
## here. Drop portrait images anywhere under res:// and reference by path.

@export var portraits: Dictionary = {
	# "DialTone": preload("res://dialtone.png"),
	# "Nyx":      preload("res://nyx.png"),
}


func get_portrait(character: String) -> Texture2D:
	return portraits.get(character, null) as Texture2D


func has_portrait(character: String) -> bool:
	return portraits.has(character) and portraits[character] != null
