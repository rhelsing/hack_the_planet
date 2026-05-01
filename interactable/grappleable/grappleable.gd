class_name Grappleable
extends Node3D

## Drop this node into a scene (as a child of a platform, hook, beam — or
## standalone) to mark the spot as a valid grapple target. Joins the
## "grappleable" group so GrappleAbility can find it, and shows a floating
## label (e.g. "[G] grapple") when the player's camera is roughly aimed at it.
##
## The grapple point is this node's `global_position`. Position the node
## exactly where you want the player's rope to attach.

## Template — `{action}` tokens (e.g. {grapple_fire}) get substituted by Glyphs
## at _ready, so the bracketed key matches the active controller config.
@export var prompt_text: String = "[{grapple_fire}] grapple"
## Label offset from this node's origin. Raise for overhead hooks so the
## label floats above the attachment point, not inside it.
@export var prompt_offset: Vector3 = Vector3(0, 0.8, 0)

var _label: Label3D = null


func _ready() -> void:
	add_to_group(&"grappleable")
	_label = Label3D.new()
	_label.text = Glyphs.format(prompt_text)
	_label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	_label.no_depth_test = true
	_label.pixel_size = 0.012
	_label.font_size = 48
	_label.outline_size = 8
	_label.modulate = Color(0.9, 0.4, 0.85)
	_label.position = prompt_offset
	_label.visible = false
	add_child(_label)


## Called each frame by GrappleAbility — true when the player is facing us
## within range. Cheaper than polling from here every tick.
func set_prompt_visible(v: bool) -> void:
	if _label == null:
		return
	# Re-format on every show so the bracketed glyph follows the active
	# device. Without this, the label freezes on whatever was current at
	# _ready and never flips when the player swaps keyboard↔gamepad.
	if v:
		_label.text = Glyphs.format(prompt_text)
	_label.visible = v
