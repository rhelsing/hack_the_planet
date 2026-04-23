class_name Door
extends Interactable

## Press-E door. Supports key gating via `requires_key` (on the Interactable
## base). On interact: plays open animation if present (or falls back to a
## slide-down tween), marks GameState flag, emits Events.door_opened, and
## self-frees.
## See docs/interactables.md §10.2.

@export var open_animation: String = "open"

## Optional AnimationPlayer path relative to this node. If unset or missing,
## the door slides downward before despawning (fallback animation).
@export var animation_player_path: NodePath = ^"AnimationPlayer"

## Fallback animation tuning when no AnimationPlayer is present.
@export var fallback_slide_depth: float = 3.0
@export var fallback_slide_time: float = 0.4


func _ready() -> void:
	super._ready()
	if prompt_verb == "interact":
		prompt_verb = "open"


func interact(_actor: Node3D) -> void:
	GameState.set_flag(interactable_id, true)
	Events.door_opened.emit(interactable_id)

	# Disable further focus + collision immediately so the player can step
	# through even mid-animation. We queue_free at the end of the animation.
	collision_layer = 0
	_disable_blocker()

	var anim := get_node_or_null(animation_player_path) as AnimationPlayer
	if anim != null and anim.has_animation(open_animation):
		anim.play(open_animation)
		await anim.animation_finished
	else:
		# Fallback: slide the door downward into the ground, then despawn.
		# Cheap, readable, no animation asset required.
		var tween := create_tween()
		tween.tween_property(self, "position:y",
			position.y - fallback_slide_depth, fallback_slide_time
		).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_IN)
		await tween.finished

	queue_free()


## Door prefabs include a `Blocker` StaticBody3D child that physically blocks
## the player until open. Disable its collider when opening so the slide-down
## tween doesn't push the player. Silent no-op if the child is absent.
func _disable_blocker() -> void:
	var blocker := get_node_or_null(^"Blocker") as StaticBody3D
	if blocker == null: return
	blocker.collision_layer = 0
	for child: Node in blocker.get_children():
		if child is CollisionShape3D:
			(child as CollisionShape3D).disabled = true
