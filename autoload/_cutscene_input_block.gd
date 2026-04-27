extends CanvasLayer
## Eats every action-typed input event while a Cutscene (image or video) is
## on screen so kbd/controller can't navigate Buttons on lower CanvasLayers.
## Mouse is blocked by the FULL_RECT ColorRect child with MOUSE_FILTER_STOP.

func _input(event: InputEvent) -> void:
	if event.is_action_type():
		get_viewport().set_input_as_handled()
