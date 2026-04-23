class_name CharacterSkin
extends Node3D

## Visual-only contract for a character skin. PlayerBody drives it through a
## small set of method calls — idle/move/jump/fall/edge_grab/wall_slide/attack —
## and reads per-character proportions (lean pivot, body center) off it.
##
## Skins are swappable at design time via PlayerBody.skin_scene. The same
## body runs identically regardless of which skin is plugged in — so Sophia
## today, cop_riot tomorrow, KayKit next week, all on the same physics pawn.
##
## Default implementations are no-ops so minimal skins (e.g., a GLB with only
## idle/run animations) can subclass, override only what they can show, and
## leave the rest silently ignored without crashing the body.

@export_group("Proportions")
## Height of the skin's natural "lean pivot" in meters — roughly head height.
## Body rotates the skin around this point for lean/tilt so the feet swing
## while the head stays put.
@export var lean_pivot_height: float = 1.6
## Height of the body center for the double-jump flip pivot.
@export var body_center_y: float = 0.9

## Red damage flash intensity (0 = none, 1 = full). Skins with a mesh that
## can show the flash override set_damage_tint() to apply a material overlay;
## others inherit the no-op setter.
var damage_tint: float = 0.0 : set = set_damage_tint

## Scales the body's runtime lean (forward pitch on acceleration + side roll
## on turns) for THIS skin. Lives on the skin because different rigs look
## right at different lean amounts — Sophia is dramatic, cops + mannequins
## should be subtler. 1.0 = stock. 0.5 = half. Body reads this each frame.
@export_range(0.0, 3.0) var lean_multiplier: float = 1.0


func set_damage_tint(value: float) -> void:
	damage_tint = clampf(value, 0.0, 1.0)


# --- Animation state contract ---
# Override in concrete skins. No-op defaults let minimal skins skip states
# they can't show (e.g., no jump animation → jump() just holds the run pose).

func idle() -> void: pass
func move() -> void: pass
func fall() -> void: pass
func jump() -> void: pass
func edge_grab() -> void: pass
func wall_slide() -> void: pass
func attack() -> void: pass

## Called once on the frame a dash fires. `direction` is the world-space
## dash vector (horizontal, y=0). Skins with directional dodge clips use it
## to pick forward/back/left/right. No-op default.
func dash(_direction: Vector3 = Vector3.ZERO) -> void: pass

## Called when the crouch-held state changes (on press and on release). No-op
## default — skins with a crouch pose override to travel Crouch state on
## active=true, return to prior state on active=false.
func crouch(_active: bool) -> void: pass

## Called when the body switches between walk_profile and skate_profile.
## No-op default. Sophia overrides to toggle her rollerblade wheels and
## the skin root Y offset (skates lift her heel off the ground slightly).
## Other skins without wheel gear inherit the no-op.
func set_skate_mode(_active: bool) -> void: pass

## Called once by the body at the start of the death sequence. Skins with a
## real death animation override to travel their Die state; others inherit
## the no-op and the body's velocity pop + confetti carry the visual.
func die() -> void: pass

## Called once on the frame the pawn transitions from airborne to grounded.
## Lets skins play a landing impact clip. No-op default.
func land() -> void: pass

## Called once per incoming take_hit (damage application). Skins with a
## flinch / hit-react clip override and travel their Hit state. No-op default.
func on_hit() -> void: pass

## Called every physics tick by the body to toggle the skin's ground-dust
## emitter. Skins with a `DustParticles` GPUParticles3D override to pipe the
## bool through to that node. Skins without feet or dust (cutscene props,
## future NPCs) inherit the no-op and the body doesn't branch on has_method.
func set_dust_emitting(_enabled: bool) -> void: pass
