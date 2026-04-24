class_name HackModeAbility
extends Ability

## Pure flag mirror — the actual mechanic is implemented as a gate on
## PuzzleTerminal.can_interact (see interactable/puzzle_terminal). Owning
## this ability lets the player activate hack consoles; without it, they
## show "[E] hack (locked — not a hacker)".
##
## This node exists so HUD powerup_row can render the 🕶 icon; it has no
## input of its own.


func _ready() -> void:
	if ability_id == &"":
		ability_id = &"HackModeAbility"
	if powerup_flag == &"":
		powerup_flag = &"powerup_secret"
	super._ready()
