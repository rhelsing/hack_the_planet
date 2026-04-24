extends Area3D
class_name RespawnMessageZone

## Trigger volume that arms a contextual hint for the next respawn. Place
## these around tricky platforming so falling produces a relevant message
## (e.g. drop one in the air below a gap with "Try the wall-ride to your
## left"). Latest-armed wins; PlayerBody clears the queue after one show.

@export_multiline var message: String = ""


func _ready() -> void:
	body_entered.connect(_on_body_entered)


func _on_body_entered(body: Node) -> void:
	if not body.is_in_group("player"):
		return
	if message.is_empty():
		return
	Events.respawn_message_armed.emit(message)
