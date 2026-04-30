class_name FlagStep
extends CutsceneStep

## Mutate GameState. The ONLY way to change game state during a cutscene —
## per the engine's invariant that all side effects are typed and skippable.
## When the player skips past this step, the player's skip-replay logic
## applies the mutation as if the step had fired naturally.

@export var flag: StringName

## The value to set. Bool / int / string are common; anything that survives
## ConfigFile serialization works.
@export var value: Variant = true
