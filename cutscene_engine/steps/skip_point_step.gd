class_name SkipPointStep
extends CutsceneStep

## A no-op step that marks a safe target for skip. When the player presses
## skip, the player walks forward through the timeline applying any
## FlagSteps it crosses, then resumes execution at the next SkipPointStep
## (or at the end if none).
##
## Place these at natural beats — between shots, after a stinger settles,
## anywhere a partial-cutscene experience would still leave the player
## with consistent game state.
##
## SkipPointStep itself does nothing when executed naturally (it's just a
## marker), so its `allow_skip` is irrelevant. The base class field is
## inherited but unused by this type.
