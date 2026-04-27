extends Node3D

## Glitch's stage — the parent Node3D bundling Ground6 + Ground7 + Glitch.
## On _ready, drops the whole set by `drop_offset` (negative) below the
## authored position. When a configured Companion voice line FINISHES
## playing, tweens back up to the authored Y over `rise_duration`.
##
## Trigger model: match on (character, line substring). Listens to
## Companion.line_started to record a pending match, then fires on
## Companion.line_ended. This means the rise happens just after the player
## hears the cue — not when they enter a trigger zone, and not before the
## line is audible.
##
## One-shot — disconnects after firing.

@export var drop_offset: float = -40.0
@export var rise_duration: float = 4.0
@export var trigger_character: StringName = &"Glitch"
## Substring; matched case-insensitively against the spoken line. Empty
## means "any line from trigger_character".
@export var trigger_line_match: String = "see me"
## If this flag is already true on _ready (a saved game has progressed past
## the entrance), skip the drop+rise entirely — the set stays at the
## authored position. Default matches the lift trigger so the set is
## "already up" once the player has accepted the lift.
@export var restore_when_flag: StringName = &"glitch_lift_ready"

var _authored_y: float = 0.0
var _has_fired: bool = false
var _armed: bool = false


func _ready() -> void:
	_authored_y = position.y
	# Restore branch: if we've already progressed past the entrance in a
	# saved session, leave the set at its authored position and don't arm
	# the voice trigger. _has_fired guards future re-fires.
	if restore_when_flag != &"" and bool(GameState.get_flag(restore_when_flag, false)):
		_has_fired = true
		print("[glitch_set] restore: %s already true — staying at authored Y=%s" % [restore_when_flag, _authored_y])
		return
	position.y = _authored_y + drop_offset
	Companion.line_started.connect(_on_line_started)
	Companion.line_ended.connect(_on_line_ended)


func _on_line_started(character: String, text: String) -> void:
	if _has_fired:
		return
	if String(trigger_character) != character:
		return
	if not trigger_line_match.is_empty():
		if not text.to_lower().contains(trigger_line_match.to_lower()):
			return
	_armed = true


func _on_line_ended() -> void:
	if _has_fired or not _armed:
		return
	_has_fired = true
	Companion.line_started.disconnect(_on_line_started)
	Companion.line_ended.disconnect(_on_line_ended)
	var tw := create_tween()
	tw.tween_property(self, "position:y", _authored_y, rise_duration) \
		.set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
