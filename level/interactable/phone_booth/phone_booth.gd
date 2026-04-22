@tool
class_name PhoneBooth extends Node3D

## Drag the buildings shader material here to use a different active look
## without editing the scene subresource. Defaults to the project's
## res://level/buildings.tres via the scene.
@export var active_material: Material

@onready var _activation_block: MeshInstance3D = get_node_or_null("ActivationBlock")


func _ready() -> void:
	if Engine.is_editor_hint():
		return
	add_to_group("phone_booths")
	# Start hidden — the block only appears (with building material) once the
	# player activates this booth as their checkpoint. Kept visible in the
	# editor so you can position it; toggled off at runtime startup.
	if _activation_block != null:
		_activation_block.visible = false
	var area: Area3D = get_node_or_null("Area3D")
	if area != null:
		area.body_entered.connect(_on_body_entered)


func _on_body_entered(body: Node3D) -> void:
	# Only the player banks checkpoints — if an enemy wanders through a booth
	# it shouldn't move the player's respawn point to wherever the enemy was.
	if not body.is_in_group("player"):
		return
	Events.checkpoint_reached.emit(global_position)
	_activate()


func _activate() -> void:
	# One active checkpoint at a time: clear every other booth, then light us up.
	for other: Node in get_tree().get_nodes_in_group("phone_booths"):
		if other is PhoneBooth and other != self:
			(other as PhoneBooth)._set_active(false)
	_set_active(true)


func _set_active(active: bool) -> void:
	if _activation_block == null:
		return
	_activation_block.visible = active
	if active and active_material != null:
		_activation_block.set_surface_override_material(0, active_material)
