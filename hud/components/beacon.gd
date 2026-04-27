extends Node3D
class_name Beacon

## World-space objective marker. Drop as a child of any node you want to
## point the player at — the beacon's own global_position is what the HUD
## projects, so offset it (e.g., +1.5 Y) to float above a head.
##
## Visibility gates (all optional, all combined as AND):
##   - visible_when_flag    — beacon hidden until this GameState flag is true
##   - hide_when_flag       — beacon hidden once this flag is true
##   - visible_when_voice_ends + visible_when_voice_match — beacon flips
##       on after a Companion line finishes (matched by character + line
##       substring, case-insensitive). Pairs with the same trigger pattern
##       used by glitch_set.gd so a single voice cue can fire multiple
##       choreographies (entrance + beacon + ...).
##
## Rendered by hud/components/beacon_layer.gd.

@export var color: Color = Color(1.0, 0.29, 0.12)  # orange-red default
## Short label shown next to the marker. UPPERCASE looks best with the
## monospace HUD font; the renderer doesn't transform case.
@export var label: String = ""

## Optional flag gates — see header.
@export var visible_when_flag: StringName = &""
@export var hide_when_flag: StringName = &""

## Optional voice-line trigger — beacon turns ON when a Companion line
## from this character ends, matched (case-insensitive substring) against
## the spoken text. Empty match string = "any line from this character".
@export var visible_when_voice_ends: StringName = &""
@export var visible_when_voice_match: String = ""

## Runtime state. The renderer reads this — toggle through `set_visible`
## or by setting flags / firing the configured voice line.
var beacon_visible: bool = true

var _voice_armed: bool = false


func _ready() -> void:
	# Initial visibility from flag gates. Voice-trigger overrides start to
	# hidden — voice ends will turn it on later.
	if visible_when_voice_ends != &"":
		beacon_visible = false
	_apply_flag_gates()
	if visible_when_flag != &"" or hide_when_flag != &"":
		Events.flag_set.connect(_on_flag_set)
	if visible_when_voice_ends != &"":
		Companion.line_started.connect(_on_line_started)
		Companion.line_ended.connect(_on_line_ended)
	Beacons.register(self)
	print("[beacon] ready: %s visible=%s voice_gate=%s flag_gate=%s/%s" % [
		get_path(), beacon_visible,
		visible_when_voice_ends, visible_when_flag, hide_when_flag])


func _exit_tree() -> void:
	Beacons.unregister(self)


func set_beacon_visible(on: bool) -> void:
	if beacon_visible == on:
		return
	beacon_visible = on
	print("[beacon] %s visible -> %s" % [name, on])


func _apply_flag_gates() -> void:
	if visible_when_flag != &"" and not bool(GameState.get_flag(visible_when_flag, false)):
		beacon_visible = false
		return
	if hide_when_flag != &"" and bool(GameState.get_flag(hide_when_flag, false)):
		beacon_visible = false
		return


func _on_flag_set(id: StringName, value: Variant) -> void:
	if id == visible_when_flag and value:
		set_beacon_visible(true)
	elif id == hide_when_flag and value:
		set_beacon_visible(false)


func _on_line_started(character: String, text: String) -> void:
	if String(visible_when_voice_ends) != character:
		return
	if not visible_when_voice_match.is_empty():
		if not text.to_lower().contains(visible_when_voice_match.to_lower()):
			return
	if not _voice_armed:
		print("[beacon] %s armed by voice: %s '%s'" % [name, character, text])
	_voice_armed = true


func _on_line_ended() -> void:
	if not _voice_armed:
		return
	_voice_armed = false
	# Re-apply flag gates so a hide_when_flag already true keeps it hidden.
	var on := true
	if hide_when_flag != &"" and bool(GameState.get_flag(hide_when_flag, false)):
		on = false
	set_beacon_visible(on)
