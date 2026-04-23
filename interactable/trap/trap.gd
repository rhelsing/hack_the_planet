class_name Trap
extends Interactable

## Press-E interactable that damages the actor — spike you can choose to poke,
## electrified panel, etc. Uses PlayerBody's unified damage API.
##
## Char-controller dev flagged (sync_up.md 2026-04-22): damage is subject to
## post-respawn invuln. Trap's interact() still fires (audio, animation) during
## invuln; only the take_hit() is no-op'd by the body. That's a feature, not a bug.

@export var knockback: float = 14.0
## If true, the trap self-destructs after one use (single-shot spike).
## Set false for resettable hazards.
@export var single_use: bool = true


func _ready() -> void:
	super._ready()
	if prompt_verb == "interact":
		prompt_verb = "touch"


func interact(actor: Node3D) -> void:
	if actor != null and actor.has_method(&"take_hit"):
		var dir := (actor.global_position - global_position).normalized()
		if dir.length_squared() < 0.0001:
			dir = Vector3.UP  # degenerate: push straight up
		actor.take_hit(dir, knockback)
	if single_use:
		queue_free()
