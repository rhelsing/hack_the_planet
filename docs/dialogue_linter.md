# Dialogue Linter

Static checker for `.dialogue` files + the `.gd` / `.tscn` code that backs
them. Catches the bugs that compound silently as the story grows: orphan
flags, typo'd StoryVec axes/regions, and missing `[#exit]` tags.

## Run it

```sh
godot --headless --script res://tools/lint_dialogues.gd --quit
```

Exit code `1` if any **errors**; `0` otherwise. Warnings don't fail.

The compiled `.tres` form of each `.dialogue` is what gets walked, so if
you've just edited a file run `godot --headless --import` first to refresh
the compiled cache (the editor does this automatically when open).

## What it checks

### Errors (real bugs — fail the gate)

**Orphan readers.** A `[if /]` gate reads `flag_name`, but no code anywhere
writes that flag. The gate always evaluates to its default (typically
`false`), so the option is permanently invisible. Either add the writer or
delete the gate.

```
flag 'powerup_love' is READ but never SET — gate always evaluates to default
```

**Bad StoryVec axis or region.** `nudge`/`value`/`in_region` calls a name
that isn't declared in `dialogue/story_vec_config.tres`. Fails closed at
runtime — option silently invisible or nudge silently no-ops.

```
StoryVec.nudge("axiis_typo", ...) — axis not declared in config
StoryVec.in_region("propeople") — region not declared in config
```

### Warnings (review-only)

**Orphan writers.** A flag is set somewhere but never read by any other
file the linter scans. Often legitimate (set as side-effect, consumed by
analytics, future-proofing), but worth eyeballing.

```
flag 'game_completed' is SET but never READ — verify it's still meaningful
```

**Untagged exits.** A response option whose body terminates at `=> END` or
`=> *_done` lacks the `[#exit]` tag. Will dim on revisit and trap the
player. Fix by appending `[#exit]` to the option line.

```
option "Sign me out." routes to END/done without [#exit] tag — will dim on revisit
```

## What it scans

- All `.dialogue` files in `res://dialogue/` (compiled form).
- All `.gd` files under `autoload/`, `game.gd`, `hud/`, `interactable/`,
  `level/`, `menu/`, `player/`, `cutscene_engine/`, `dialogue/`.
- All `.tscn` files under `level/`, `hud/`, `interactable/`, `menu/`.
- `dialogue/story_vec_config.tres` for axis/region declarations.

`.gd` and `.tscn` scans are needed because production flag references
hide in:
- Direct `set_flag(&"X", ...)` / `get_flag(&"X", ...)` calls.
- `@export` defaults — `@export var require_flag := &"X"`.
- Inspector bindings in `.tscn` — `done_flag = &"X"`.

The linter treats `*_flag` property bindings as **both read and write**
since we can't always tell from the property name alone (`done_flag`
typically writes, `require_flag` reads). Conservative — eliminates false
positives at the cost of letting through truly-unused properties.

## Allowlists

Two short hand-maintained lists live in `tools/dialogue_linter.gd`:

- `FLAG_DYNAMIC_GD_WRITERS` — flag names set by `.gd` code via dynamic
  builders the regex can't see (e.g. `LevelProgression._completed_key(num)`
  builds `level_N_completed` at runtime). Add a name here only after
  confirming the dynamic writer with `grep`.

(There's deliberately no orphan-writer allowlist. Real orphans are cheap
to leave as warnings; we'd rather see the list than auto-suppress.)

## Extending

The lint logic lives in `tools/dialogue_linter.gd` (a `RefCounted` class),
exposed via a single `analyze(dialogue_paths, gd_dirs, story_vec_config,
tscn_dirs)` method. The SceneTree wrapper (`tools/lint_dialogues.gd`)
invokes it with production paths; tests
(`tests/test_dialogue_lint.gd`) invoke it with smaller inputs.

To add a new check:
1. Add a regex constant or load helper at the top of `dialogue_linter.gd`.
2. Implement a `_check_xxx(...)` method that appends to
   `report.errors` / `report.warnings`.
3. Call it from `_scan_dialogue` (per-file) or directly from `analyze`
   (cross-file).
4. Update the test if the new check has a high enough false-positive risk
   to warrant a fixture.

## Why this design

We chose to walk **source text via regex** for flag and StoryVec name
extraction rather than the compiled DM expression AST. The AST is more
"correct" — it has the actual function calls parsed into typed tokens —
but extracting a flag name from a nested AST is 30 lines per check.
Source-text regex is one line per check and equally reliable for
quoted-string literals (which is what flag/axis/region names are).

The exit-tag check **does** use the compiled `DialogueResource` because
it needs structural walking of `next_id` chains across line types. Source
regex would have to parse Dialogue Manager's full grammar; the compiled
form is already a tree.

## Current state (post Phase E.6)

- **0 errors** across 19 dialogue files + production code.
- **4 warnings** (orphan writers — `game_completed`, `glitch2_asked_origin`,
  `glitch_chance_done`, `hub_nyx_post3_done`). All "set on completion of
  a thing" flags with no current consumers. Likely future-use; review
  next time the relevant story stage gets touched.
