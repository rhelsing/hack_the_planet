class_name CopRiotSkin
extends CharacterSkin

## Sophia-derived state machine for the cop_riot rig. The GLB only ships
## with Riot_Idle + Riot_Run, so most states fall back to one of the two
## inside the AnimationTree — but the STRUCTURE is full (idle/move/jump/
## fall/edge/wall/attack/dash/crouch + tilt blend) so this skin is
## behaviourally identical to Sophia/KayKit as a player. Adding new cop
## clips later requires only swapping clip names in the AnimationTree
## sub-resources; no code changes.
##
## No damage-tint overlay — the cop_riot GLB uses embedded materials that
## aren't trivially overlayable. Damage-flash inherits the CharacterSkin
## no-op.

@onready var animation_tree: AnimationTree = %AnimationTree
@onready var state_machine: AnimationNodeStateMachinePlayback = animation_tree.get("parameters/StateMachine/playback")
@onready var move_tilt_path: String = "parameters/StateMachine/Move/tilt/add_amount"


# --- CharacterSkin contract ---
func idle() -> void: state_machine.travel("Idle")
func move() -> void: state_machine.travel("Move")
func fall() -> void: state_machine.travel("Fall")
func jump() -> void: state_machine.travel("Jump")
func edge_grab() -> void: state_machine.travel("EdgeGrab")
func wall_slide() -> void: state_machine.travel("WallSlide")
func attack() -> void: state_machine.start("EdgeGrab")

func dash(_direction: Vector3 = Vector3.ZERO) -> void:
	# No directional dodge clips on this rig — force-enter the shared Dash
	# state (points at Riot_Run). Exits via body's per-frame travel calls
	# once dash_timer expires.
	state_machine.start("Dash")

func crouch(active: bool) -> void:
	if active:
		state_machine.start("Crouch")
