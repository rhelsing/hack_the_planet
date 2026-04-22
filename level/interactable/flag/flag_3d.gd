extends Node3D

@onready var _area_3d: Area3D = %Area3D


func _ready() -> void:
	_area_3d.body_entered.connect(func (body_that_entered: PhysicsBody3D) -> void:
		# Only the player triggers victory — enemies walking into the flag
		# shouldn't end the level. Matches the pawn_group convention on
		# PlayerBody so any player-driven skin (Sophia, cop_riot, KayKit)
		# counts, while enemies (pawn_group="enemies") are ignored.
		if not body_that_entered.is_in_group("player"):
			return
		Events.flag_reached.emit()
	)
