extends CanvasLayer
## Eats every action-typed input event so kbd/controller can't reach Controls
## on lower CanvasLayers (HUD, menu remnants, etc.) while a NPC-dialogue
## cinematic is in progress. Mouse is blocked separately by the FULL_RECT
## ColorRect child with MOUSE_FILTER_STOP. The dialogue balloon's own canvas
## sits above this layer (~2000) so its choice prompts still work normally.

func _input(event: InputEvent) -> void:
	if event.is_action_type():
		get_viewport().set_input_as_handled()
