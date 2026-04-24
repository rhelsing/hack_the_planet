extends CSGBox3D

## Vertical elevator platform. Rises, holds, falls, holds — repeating.
## Base Y is the bottom of the cycle; amplitude is the climb height.
##
## Carries the player via the "reparent trick": when the player enters the
## CarryZone Area3D above the deck, the player is reparented under this
## node. Parent transform updates cascade automatically — the player rides
## the elevator without any per-frame velocity transfer math. On leave
## (jump or walk-off), we reparent back to the original level root.

@export var amplitude: float = 2.0
@export var rise_duration: float = 1.5
@export var peak_pause: float = 0.8
@export var fall_duration: float = 1.5
@export var trough_pause: float = 0.8
@export var phase_offset: float = 0.0

var _base_y: float = 0.0
var _t: float = 0.0

# Reparent-trick bookkeeping. We remember which parent the player came from
# so we can put them back exactly there on exit (rather than guessing).
var _original_player_parent: Node = null
@onready var _carry_zone: Area3D = get_node_or_null(^"CarryZone") as Area3D


func _ready() -> void:
	_base_y = position.y
	if _carry_zone != null:
		_carry_zone.body_entered.connect(_on_carry_body_entered)
		_carry_zone.body_exited.connect(_on_carry_body_exited)


func _on_carry_body_entered(body: Node) -> void:
	if not body.is_in_group("player"):
		return
	if body.get_parent() == self:
		return  # already riding
	_original_player_parent = body.get_parent()
	# Defer the reparent — running it during a body_entered signal can race
	# with the player's own _physics_process (which may be mid-move_and_slide).
	body.call_deferred(&"reparent", self, true)


func _on_carry_body_exited(body: Node) -> void:
	if not body.is_in_group("player"):
		return
	if body.get_parent() != self:
		return
	if _original_player_parent == null or not is_instance_valid(_original_player_parent):
		return
	body.call_deferred(&"reparent", _original_player_parent, true)


func _process(delta: float) -> void:
	_t += delta
	position.y = _base_y + _offset()


func _offset() -> float:
	var total: float = rise_duration + peak_pause + fall_duration + trough_pause
	if total <= 0.0:
		return 0.0
	var t: float = fposmod(_t + phase_offset * total, total)
	if t < rise_duration:
		return (1.0 - cos(PI * t / rise_duration)) * 0.5 * amplitude
	t -= rise_duration
	if t < peak_pause:
		return amplitude
	t -= peak_pause
	if t < fall_duration:
		return (1.0 + cos(PI * t / fall_duration)) * 0.5 * amplitude
	return 0.0
