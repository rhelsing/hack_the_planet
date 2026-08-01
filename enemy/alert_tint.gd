class_name AlertTint
extends Node

## Game-side listener: paints a sibling NavBrain's suspicion onto the parent
## body's skin — "state readable on the skin" (calm faction color → amber →
## hostile red). The stack emits `suspicion_changed`; this maps it to art.
## Strictly one-way: removing this node changes nothing behavioral.
##
## `calm_color` should match the pawn's faction tint (stealth purple by
## default) — at suspicion 0 the lerp lands exactly on the faction look, so
## no save/restore dance is needed.

@export var calm_color: Color = Color(0.55, 0.0, 0.45)  # splice_stealth purple
@export var suspect_color: Color = Color(1.0, 0.7, 0.1)
@export var hostile_color: Color = Color(1.0, 0.1, 0.05)
@export var tint_amount: float = 1.0
## Blend continuously with the accumulator (rising glow as it notices you).
## Off = hard color switch at the suspect/hostile thresholds.
@export var suspicion_lerp: bool = true

var _body: Node = null
var _brain: Node = null


func _ready() -> void:
	_body = get_parent()
	# Deferred: children ready before the parent body, and the body swaps in
	# its brain_scene override during ITS _ready — look after that happened.
	_hook_brain.call_deferred()


func _hook_brain() -> void:
	for c: Node in _body.get_children():
		if c.has_signal(&"suspicion_changed"):
			_brain = c
			break
	if _brain == null:
		push_warning("AlertTint %s: no brain with suspicion_changed — inert" % get_path())
		return
	# suspicion_changed is deduped brain-side (~0.03 granularity), so skin
	# retints only while suspicion actually moves — quiet at rest.
	_brain.connect(&"suspicion_changed", _on_suspicion)


## Re-point at a replacement brain — PlayerBody.replace_brain broadcasts
## this after a runtime brain swap (the cached ref dies with the old node).
func rewire_brain(brain: Node) -> void:
	if _brain != null and is_instance_valid(_brain) \
			and _brain.has_signal(&"suspicion_changed") \
			and _brain.is_connected(&"suspicion_changed", _on_suspicion):
		_brain.disconnect(&"suspicion_changed", _on_suspicion)
	_brain = null
	if brain != null and brain.has_signal(&"suspicion_changed"):
		_brain = brain
		_brain.connect(&"suspicion_changed", _on_suspicion)


func _on_suspicion(value: float) -> void:
	if _body == null or not _body.has_method(&"apply_tint"):
		return
	var threshold: float = 0.5
	if "suspect_threshold" in _brain:
		threshold = float(_brain.suspect_threshold)
	var c: Color
	if suspicion_lerp:
		if value < threshold:
			c = calm_color.lerp(suspect_color, clampf(value / maxf(threshold, 0.001), 0.0, 1.0))
		else:
			c = suspect_color.lerp(hostile_color,
				clampf((value - threshold) / maxf(1.0 - threshold, 0.001), 0.0, 1.0))
	elif value >= 0.999:
		c = hostile_color
	elif value >= threshold:
		c = suspect_color
	else:
		c = calm_color
	# TEMP: only fires when this listener repaints a pawn that has already left
	# stealth — i.e. the "converted gold got repainted purple" bug.
	if "faction" in _body and StringName(_body.get(&"faction")) != &"splice_stealth":
		print("[tint-dbg] AlertTint REPAINT non-stealth %s faction=%s susp=%.2f -> %s" % [
			_body.name, _body.get(&"faction"), value, c])
	_body.call(&"apply_tint", c, tint_amount)
