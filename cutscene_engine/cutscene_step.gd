class_name CutsceneStep
extends Resource

## Base class for every step in a CutsceneTimeline. Pure data — no execution
## logic. The CutscenePlayer dispatches each subclass type via a centralized
## switch (see cutscene_player.gd::_run_step). This separation is deliberate:
## data goes in Resources, code goes in the Player. Adding a new step type is
## one new Resource subclass + one case in the dispatch.

## When skip is requested mid-cutscene, the player walks forward through the
## timeline; steps with allow_skip=false will NOT be jumped past. FlagSteps
## are always applied during skip-replay regardless of this value, since flag
## mutations encode game state and must reach their target value.
@export var allow_skip: bool = true

## Author-facing tag, shown in the debug panel + log. Optional. Has no
## runtime effect.
@export var label: String = ""
