class_name VoicePortraits
extends Resource

## Character-name → portrait + name-color registry. One source of truth
## for everything that wants to brand a speaker visually:
##   - dialogue balloon: portrait image + colored speaker name
##   - scroll balloon: colored speaker name in the chat log
##   - walkie HUD chip: portrait image + colored speaker name
##   - beacons (optional): can read color by character name to avoid
##     designers retyping the same hue per beacon instance
## Both maps are independent — a character can have a portrait without
## a color and vice versa. Edit the .tres in the inspector or here.

@export var portraits: Dictionary = {
	# "DialTone": preload("res://dialtone.png"),
	# "Nyx":      preload("res://nyx.png"),
}

## Character → display Color used for the speaker's name in dialogue UIs
## and (optionally) by waypoints. Light/saturated colors read best on the
## dark balloon panel. Returns Color.WHITE when not registered.
@export var colors: Dictionary = {
	# "DialTone": Color("#99CCFF"),
	# "Nyx":      Color("#FFEE66"),
}


func get_portrait(character: String) -> Texture2D:
	return portraits.get(character, null) as Texture2D


func has_portrait(character: String) -> bool:
	return portraits.has(character) and portraits[character] != null


func get_color(character: String) -> Color:
	return colors.get(character, Color.WHITE) as Color


func has_color(character: String) -> bool:
	return colors.has(character)
