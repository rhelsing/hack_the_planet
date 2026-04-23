extends Node
## Temporary diagnostic autoload — logs raw input events at the viewport level
## so we can compare J-key vs mouse-LMB timing end-to-end across any scene
## (game.tscn, interactables_demo.tscn, etc.). Delete this file + the autoload
## entry in project.godot once the click-delay bug is understood.

const ENABLED := true


func _input(event: InputEvent) -> void:
	if not ENABLED:
		return
	var now_ms := Time.get_ticks_msec()
	if event is InputEventKey:
		var key := event as InputEventKey
		if not key.pressed or key.echo:
			return
		if key.physical_keycode != KEY_J:
			return
		print("[attack-debug] %d ms  KEY J  is_attack=%s" % [
			now_ms, event.is_action_pressed("attack"),
		])
	elif event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if not mb.pressed or mb.button_index != MOUSE_BUTTON_LEFT:
			return
		var hover: Control = get_viewport().gui_get_hovered_control()
		var mode_map: Dictionary = {
			Input.MOUSE_MODE_VISIBLE: "VISIBLE",
			Input.MOUSE_MODE_HIDDEN: "HIDDEN",
			Input.MOUSE_MODE_CAPTURED: "CAPTURED",
			Input.MOUSE_MODE_CONFINED: "CONFINED",
			Input.MOUSE_MODE_CONFINED_HIDDEN: "CONFINED_HIDDEN",
		}
		var mode_name: String = mode_map.get(Input.mouse_mode, "?")
		print("[attack-debug] %d ms  MOUSE-LMB  is_attack=%s  is_left_click=%s  mouse_mode=%s  hover=%s" % [
			now_ms,
			event.is_action_pressed("attack"),
			event.is_action_pressed("left_click"),
			mode_name,
			hover,
		])
