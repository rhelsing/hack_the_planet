extends Node

## Root gameplay orchestrator. Currently owns:
## - Fullscreen toggle
## - Attack-input diagnostic (compare J-key vs mouse-click path timing;
##   strip once we know why clicks lag). Logs at top-of-pipeline so we see
##   what Godot actually dispatched.

const ATTACK_DEBUG := true


func _input(event: InputEvent) -> void:
	if event.is_action_pressed("toggle_fullscreen"):
		get_viewport().mode = (
			Window.MODE_FULLSCREEN if
			get_viewport().mode != Window.MODE_FULLSCREEN else
			Window.MODE_WINDOWED
		)

	if ATTACK_DEBUG:
		_log_attack_input(event)


## Instrumentation for the "mouse click feels slower than J" bug.
## Prints three stages for comparison between the keyboard and mouse paths:
##   1. Raw event classification + timestamp
##   2. Whether the event is classified as `attack` by InputMap
##   3. If mouse: which Control (if any) is under the cursor — the prime
##      suspect for swallowing clicks via _gui_input before _input sees it.
## Print format is stable so grep / diff across runs is easy.
func _log_attack_input(event: InputEvent) -> void:
	var now_ms := Time.get_ticks_msec()
	if event is InputEventKey:
		var key := event as InputEventKey
		if not key.pressed or key.echo:
			return
		if key.physical_keycode != KEY_J:  # only care about attack key
			return
		print("[attack-debug] %d ms  KEY J  is_attack=%s" % [
			now_ms,
			event.is_action_pressed("attack"),
		])
	elif event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if not mb.pressed:
			return
		if mb.button_index != MOUSE_BUTTON_LEFT:
			return
		var hover := get_viewport().gui_get_hovered_control()
		var mode_name := {
			Input.MOUSE_MODE_VISIBLE: "VISIBLE",
			Input.MOUSE_MODE_HIDDEN: "HIDDEN",
			Input.MOUSE_MODE_CAPTURED: "CAPTURED",
			Input.MOUSE_MODE_CONFINED: "CONFINED",
			Input.MOUSE_MODE_CONFINED_HIDDEN: "CONFINED_HIDDEN",
		}.get(Input.mouse_mode, "?")
		print("[attack-debug] %d ms  MOUSE-LMB  is_attack=%s  is_left_click=%s  mouse_mode=%s  hover=%s" % [
			now_ms,
			event.is_action_pressed("attack"),
			event.is_action_pressed("left_click"),
			mode_name,
			hover,
		])
