class_name StoryVecConfig extends Resource

## Per-game configuration for the StoryVec autoload.
##
## Generic / reusable: the engine knows nothing about specific axis names
## or region semantics. A second project can drop the StoryVec autoload in,
## point at a different config .tres, and use it.
##
## Hack The Planet ships with axes [&"ai_tech", &"humanity"] and four
## quadrant regions (configured in dialogue/story_vec_config.tres).
##
## ── Schema ──────────────────────────────────────────────────────────────
## axes — the names of every dimension. Each axis is a float scalar
##        accumulated by StoryVec.nudge(axis, delta), clamped to
##        [bounds_min, bounds_max].
##
## bounds_min / bounds_max — same bounds for every axis. Symmetric is
##        recommended (e.g. -10 / +10) but not required. Per-axis bounds
##        could be added later; YAGNI for now.
##
## regions — author-defined named predicates. Each entry is a Dictionary:
##           {
##             "name": StringName,
##             "thresholds": { axis_name: [min_inclusive, max_inclusive] }
##           }
##         A region matches if every axis listed in `thresholds` falls
##         within its [min, max] inclusive range. Axes NOT listed are
##         unconstrained — a region can name only one axis if that's the
##         only one it cares about.
##
## ── Authoring example ──────────────────────────────────────────────────
## Hack The Planet's pro_ai_pro_people region:
##   { name = &"pro_ai_pro_people",
##     thresholds = { &"ai_tech": [2, 10], &"humanity": [2, 10] } }
##
## A "neutral" region for small-magnitude vectors:
##   { name = &"neutral",
##     thresholds = { &"ai_tech": [-2, 2], &"humanity": [-2, 2] } }

@export var axes: Array[StringName] = []
@export var bounds_min: float = -10.0
@export var bounds_max: float = 10.0
@export var regions: Array[Dictionary] = []
