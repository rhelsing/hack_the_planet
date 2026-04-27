extends CanvasLayer
## Eats every action-typed input event while a scene transition is on screen
## so kbd/controller can't navigate the menu/world visible through the
## chromatic-aberration overlay. Mouse is blocked separately by the FULL_RECT
## ColorRect child with MOUSE_FILTER_STOP. Lives at layer 2000 (above the
## loader UI at 1000), so it covers the brief play_out / play_in windows
## that bookend the loader.

func _input(event: InputEvent) -> void:
	if event.is_action_type():
		get_viewport().set_input_as_handled()
