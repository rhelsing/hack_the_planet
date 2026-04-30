# Cutscene Engine — Design Spec

**Status**: design **locked**. Implementation may begin. Drop-in replacement for `level/interactable/cutscene_sequence/cutscene_sequence.gd`. The existing system is **not removed** until the new one is shipped, tested, and migrated to. New engine lives in its own folder; old keeps working until each cutscene migrates.

**Audience**: this is the architecture spec. §10 holds the seven cross-cutting decisions, each marked DECIDED with rationale + rejected alternatives.

---

## 1. Why a new engine

The current cutscene path adapts Nathan Hoad's `DialogueManager` to walk a `.dialogue` file as if it were a linear script. That works for "press E to advance" branching dialogue — its actual purpose. For cutscenes it inherits a stack of leaks:

- **Pause trap**: `Audio` autoload is `PROCESS_MODE_ALWAYS` (so the ducking sidechain compressor can pump while menus are open). `Walkie.line_ended` therefore fires during pause. Anything that does `await Walkie.line_ended` plows through pause and the cutscene marches on with no audio.
- **No skip support**: there's nowhere to put "skip to here." Skip-replay of flag mutations would require introspecting the dialogue file at runtime.
- **Stringly-typed mutations**: `do CutsceneSequence.set_shot(2)` lives inside a `.dialogue` file as text the plugin parses with regex. Camera node references aren't validated at edit time. Shot-out-of-range is a runtime warning, not a typecheck error.
- **Parallel TTS**: `DialogueManager.got_dialogue` fires on every line, so `Dialogue` autoload tries to dispatch its own TTS call in parallel with our `Walkie.speak`/`Companion.speak`. We work around it via a global `_dialogue_drive_count` static. That's a static singleton holding sequencer state — it WILL leak high if a cutscene is freed mid-walk, permanently muting dialogue TTS for the rest of the session.
- **No data validation**: 3000+ LOC plugin, a parser, and a runtime in the way of authoring a 12-line linear cutscene.

The post-mortem's framing is right: cutscenes are a different problem from dialogue. Build a small dedicated engine.

---

## 2. Goals + non-goals

### Goals

- **Linear, multi-system sequencer** — dialogue + camera + audio + state mutation + signals, all driven by one driver.
- **Pause-respecting** — pause menu opens → cutscene fully freezes including audio. Resume picks up where it left off.
- **Skippable from day one** — every step has `allow_skip`; press the skip key to fast-forward to the next `SkipPointStep`. Flag mutations between current and target are applied as if they fired naturally.
- **Cancellable mid-game** — `cancel()` stops the run, restores state (camera, music, player, HUD), optionally sets `done_flag` or `cancelled_flag`.
- **Mid-game-kickoffable** — `arm()` triggers the cutscene immediately. A scene's flag-armed cutscenes coexist with method-armed ones.
- **Three use cases, one engine**: boss cutscene (full kit), battle radio (degenerate cutscene — just lines + waits, no cuts), L5 walk-of-shame (positional triggers feeding short cutscenes, or one cutscene with TriggerSteps).
- **Drop-in** — lives in its own folder, doesn't touch existing `cutscene_sequence.gd`.

### Non-goals (out of scope for v1)

- Branching cutscenes with player choice (use DialogueManager — that's what it's for).
- Editor timeline UI / visual scrubber. (Mentioned as a v2 win.)
- Localization beyond what `LineLocalizer` already provides (`{handle}`, `{action_name}` token substitution).
- Frame-perfect sync with animations (call out animations from `LineStep` if needed; don't try to be a NLE).
- Replacing existing `cutscene_sequence.gd`. We migrate one cutscene at a time when each is ready.

---

## 3. Architecture overview

Three abstractions:

```
Cutscene (Resource)
 └── steps: Array[CutsceneStep]

CutsceneStep (Resource, polymorphic) — eight subclasses (§4)

CutscenePlayer (Node)
 ├── play(cutscene: Cutscene) → awaitable
 ├── skip()
 ├── cancel()
 ├── pause(on: bool)        # called by PauseController
 └── signals: step_started, step_ended, ended, cancelled
```

Plus two **service autoloads** the player depends on, NOT direct calls into existing systems:

```
CutsceneAudio  — play_line, play_stinger, play_music, set_music, fade_music
CutsceneCamera — cut_to, pan, save_current, restore
```

These services are thin façades. They internally call existing systems (`Walkie`, `Companion`, `Audio`, viewport camera) but expose a **pause-respecting interface**. The driver never calls `Walkie.speak` directly. This is the post-mortem's "service interface, not a backend" point.

---

## 4. Step types (the typed data)

Each step is a Resource subclass of `CutsceneStep`. All share two common fields:

```gdscript
class_name CutsceneStep extends Resource
@export var allow_skip: bool = true   # skipping past this step is safe
@export var label: String = ""        # author-facing tag, shown in debug panel
```

The eight subclasses:

### `LineStep`
Speaks one line. Awaits playback finish (with pause-respecting audio).
```gdscript
@export var character: StringName              # &"Splice"
@export_multiline var text: String             # supports **bold**, *italic*, [whispering], {handle}
@export_enum("companion", "walkie") var channel: String = "companion"
@export var bus_override: StringName           # optional bus override (&"Reverb", &"CloseUp")
@export var voice_id_override: StringName      # optional ElevenLabs voice override
@export var hold_after: float = 0.0            # post-line breath (pause-respecting)
```

### `CutStep`
Hard-cut to a camera. Instant.
```gdscript
@export var camera: NodePath                   # Camera3D in the scene
```

### `PanStep`
Tween a camera between two transforms over a duration. Drives a `CameraDrift`-style trajectory but as a step, not a sibling node.
```gdscript
@export var camera: NodePath
@export var from: NodePath                     # Marker3D for start pose
@export var to: NodePath                       # Marker3D for end pose
@export var duration: float = 5.0
@export var trans: Tween.TransitionType = Tween.TRANS_QUAD
@export var ease: Tween.EaseType = Tween.EASE_IN_OUT
@export var await_finish: bool = false         # if false, pan kicks off and step returns immediately (use ParallelStep to overlap with lines)
```

### `WaitStep`
Pure timing. Pause-respecting (uses `get_tree().create_timer()` whose timer is INHERIT mode).
```gdscript
@export var seconds: float = 1.0
@export var until_signal: NodePath             # if set, await Object.signal_name instead of timer
@export var signal_name: StringName
@export var until_flag: StringName             # if set, await GameState.set_flag(name, true)
```

### `MusicStep`
Swap music. Routes through `CutsceneAudio.set_music` — doesn't touch `Audio` directly.
```gdscript
@export var stream: AudioStream                # null = stop
@export var fade_in: float = 0.4
@export var fade_out_prev: float = 0.4
@export var loop: bool = true
```

### `StingerStep`
One-shot SFX, optionally awaited.
```gdscript
@export var stream: AudioStream
@export var bus: StringName = &"SFX"
@export var await_finish: bool = false         # block until stinger ends? defaults to no
@export var volume_db: float = 0.0
```

### `FlagStep`
The ONLY way to mutate state during a cutscene. Skip-replay reads these to apply flags between current step and skip target.
```gdscript
@export var flag: StringName
@export var value: Variant = true
```

### `ParallelStep`
Run a list of steps concurrently. Awaits all of them. Used for "pan camera while lines play."
```gdscript
@export var steps: Array[CutsceneStep] = []
@export var await_all: bool = true             # if false, awaits until first completes
```
Each entry in `steps` runs as its own track. To run a SERIAL subgroup parallel to
another track (e.g., a serial run of dialogue parallel to a single pan), wrap the
subgroup in a `SubsequenceStep` (below). `ParallelStep.steps` is pure parallel —
no inline serial-subgroup magic.

### `SubsequenceStep`
Embeds another `Cutscene` resource as a single step. Runs that cutscene's steps
serially; this step completes when the subsequence does. The driver's run state
(pause, skip, cancel) propagates into the subsequence — it's a black box that
behaves like any other step from the driver's perspective.
```gdscript
@export var cutscene: Cutscene
```
Used inside `ParallelStep` to express "serial subgroup running parallel to other
tracks." Also useful on its own: a long Cutscene can embed re-usable smaller
ones (e.g. a "Splice laughs" ten-step run that shows up in three cutscenes
with slight variations).

### `SkipPointStep`
Marks a safe target for skip. Player jumps here on skip.
```gdscript
@export var label: String = ""
```

### Step combinators in v2 (out of scope for first pass)

- `LoopStep(steps, count)` — repeat a sub-sequence
- `RandomStep(steps)` — pick one at random (battle radio variation)
- `ChoiceStep(...)` — only added if a cutscene genuinely needs branching; defer until needed

---

## 5. The driver

### `CutscenePlayer` (Node)

```gdscript
class_name CutscenePlayer extends Node

signal step_started(step: CutsceneStep, index: int)
signal step_ended(step: CutsceneStep, index: int)
signal ended(success: bool)                    # success=false on cancel
signal cancelled

@export var skip_action: StringName = &"ui_cancel"   # InputMap action that fires skip()
@export var freeze_player_default: bool = true
@export var hide_hud_default: bool = false

var _running: bool = false
var _paused: bool = false
var _cancelled: bool = false
var _skip_requested: bool = false
var _current_index: int = 0
var _current_cutscene: Cutscene = null

func play(cutscene: Cutscene) -> void:         # async
func skip() -> void
func cancel() -> void
func pause(on: bool) -> void
```

### Lifecycle (single play() call)

1. **Setup**: save current camera, freeze player, hide HUD, swap music (if cutscene has `intro_music`), play intro stinger if any.
2. **Loop**: for each step, emit `step_started`, dispatch via the right service, await completion (interruptible), emit `step_ended`.
3. **Skip handling**: if `_skip_requested`:
    - Stop in-flight audio (call `CutsceneAudio.cancel_line()`)
    - Apply `FlagStep` mutations between current and next `SkipPointStep`
    - Jump `_current_index` to that step
    - Continue loop
4. **Pause handling**: `pause(true)` sets `_paused = true` and notifies services (`CutsceneAudio.pause(true)`). The driver's loop checks `_paused` between steps and inside `WaitStep`/`LineStep` awaits. The services route through buses the pause autoload can mute; service-internal timers/tweens are PROCESS_MODE_INHERIT.
5. **Cancel**: any time, `cancel()` flips `_cancelled = true`. Loop exits at next check. Teardown runs: stop audio, restore music, restore camera, unfreeze player, restore HUD, set `done_flag` (if configured) or `cancelled_flag`.
6. **Teardown** on natural end OR cancel: reverse of setup, in defined order.

### What's NOT in the driver

- Direct calls to `Walkie.speak`, `Companion.speak`, `Audio.play_music`. All go through services.
- A static singleton like `_dialogue_drive_count`. State is per-player-instance.
- Any `await` on signals it doesn't own.

---

## 6. Pause is a one-line invariant

The post-mortem's most important point. Three rules:

1. **CutscenePlayer + every Step's awaitable** is `PROCESS_MODE_INHERIT`. Pause the tree → pause the player.
2. **All timing** uses `get_tree().create_timer(seconds)` (whose timer respects pause) or tweens on the player node (also inherit). Never `Time.get_ticks_msec()` math.
3. **All audio** routes through services. Services own a `pause(on)` method that sets `stream_paused = on` on every active player. Music, lines, stingers — all pausable by the service, not by the underlying autoload.

The current pain (`await Walkie.line_ended` firing through pause) goes away because the new driver doesn't `await` an autoload signal — it `await`s `CutsceneAudio.line_ended`, and `CutsceneAudio` owns the player and respects pause.

We do **not** change `Audio`'s `PROCESS_MODE_ALWAYS` (the sidechain ducking still needs it). We add a thin layer above that the cutscene controls.

---

## 7. Skip is a day-one invariant

The post-mortem is right: bolt skip on later → never bolt skip on. Build it from the start.

**Skip request flow:**

1. Player presses `skip_action` (default `ui_cancel`, inspector-tunable per-cutscene).
2. `CutscenePlayer.skip()` sets `_skip_requested = true`.
3. Driver's loop sees the flag at the next check. Stops in-flight audio (`CutsceneAudio.cancel_line()`).
4. Walks forward: for each step from `_current_index + 1` to next `SkipPointStep`:
    - If it's a `FlagStep`, apply it (`GameState.set_flag(...)`).
    - All other side-effect-free steps (`LineStep`, `CutStep`, `PanStep`, `WaitStep`, `MusicStep`, `StingerStep`) are silently skipped.
5. `_current_index` jumps to the `SkipPointStep`. Loop continues from there.
6. Clears `_skip_requested`.

**Author rules** (call out in the doc, enforce at runtime):

- All state mutation MUST live in `FlagStep`. Don't use `LineStep.text = "do this thing"` shortcuts.
- Side-effecting code that can't be replayed via flag mutation belongs OUTSIDE the cutscene (e.g., spawning enemies — emit a flag, listen elsewhere).
- If a cutscene has no `SkipPointStep`s, skip jumps to end. (Author chose to make it un-skippable mid-way.)

This shapes good habits: every cutscene is replay-able by flag-state alone. No hidden mutations. Skip-replay's correctness is enforceable by reading the script.

---

## 8. Three use cases, one engine

### 8.1 Battle radio (degenerate cutscene)

Background dialogue while the player fights. No camera cuts, no freeze.

```gdscript
# cutscenes/l4_battle_radio.tres
freeze_player = false
hide_hud = false
cancel_on_flag = &"l4_battle_over"   # auto-cancel when fight ends
intro_stinger = null
cutscene_music = null

steps = [
    WaitStep(seconds=2.0),
    LineStep("Nyx", "Ten down already.", channel="walkie"),
    WaitStep(seconds=7.0),
    LineStep("DialTone", "Twelve more, runner.", channel="walkie"),
    WaitStep(seconds=5.0),
    LineStep("Nyx", "Behind you!", channel="walkie"),
    # ...
]
```

Driver plays the steps without ever cutting the camera. If the battle ends early, `cancel_on_flag` fires and the radio chatter stops mid-step. The driver's cancel teardown stops the line, leaves the music alone (none was set), unfreezes the player (was never frozen).

### 8.2 Boss cutscene (full kit) — L4 Splice showdown

```gdscript
# cutscenes/l4_splice_showdown.tres
freeze_player = true
hide_hud = true
arm_flag = &"l4_cage_spawned"
done_flag = &"l4_splice_cutscene_done"
intro_stinger = preload("res://audio/sfx/braam.mp3")
cutscene_music = preload("res://audio/music/leap_motiv.mp3")
post_cutscene_music = preload("res://audio/music/hackers_theme.mp3")

steps = [
    StingerStep(braam, await_finish=true),
    MusicStep(leap_motiv, fade_in=0.4),
    CutStep(splice_cam),
    ParallelStep([
        PanStep(splice_cam, splice_start_pose, splice_end_pose, duration=90.0),
        # serial subgroup of dialogue — implemented as a nested Cutscene resource
        # OR by listing siblings inside the ParallelStep that the driver runs serially:
        LineStep("Splice", "{handle}.", channel="companion"),
        WaitStep(1.0),
        LineStep("Splice", "So here we are.", channel="companion"),
        # ...
        LineStep("Nyx", "He has no idea what's coming, does he?", channel="walkie"),
    ]),
    SkipPointStep(label="halfpipe"),
    CutStep(halfpipe_cam),
    ParallelStep([
        PanStep(halfpipe_cam, hp_start, hp_end, duration=30.0),
        LineStep("Splice", "After tonight, the Gibson is mine.", channel="companion"),
        # ...
    ]),
    SkipPointStep(label="finale"),
    CutStep(splice_cam),
    LineStep("Splice", "I'm just going to do **anything I want**.", channel="companion"),
    FlagStep(&"l4_splice_cutscene_done", true),
]
```

Same player, same step types, just more of them. Two SkipPointSteps mean the player can skip to "halfpipe" or "finale" if they're replaying.

**Decision needed (§10)**: should `ParallelStep` serial-subgroups be expressed inline or as a nested `Cutscene` resource? Inline is simpler authoring; nested is cleaner separation.

### 8.3 L5 walk-of-shame

The post-mortem's analysis is right: this is several short cutscenes triggered by Area3Ds, NOT one big cutscene. Each `WalkieTrigger` Area3D's `body_entered` plays a one-step Cutscene:

```gdscript
# cutscenes/l5_nyx_youre_doing_this.tres (1-step cutscene)
steps = [
    LineStep("Nyx", "You're really doing this.", channel="walkie"),
]
```

The walk-of-shame's existing 11-line scripted sequence in `level_5.gd._BEATS` becomes a single Cutscene resource:

```gdscript
# cutscenes/l5_walk.tres
freeze_player = false                   # player is in compelled walk; cutscene doesn't add freeze
hide_hud = false

steps = [
    WaitStep(2.5),                                          # first_line_delay_s
    LineStep("Splice",   "There you are. ...I knew you'd see it eventually.", channel="walkie"),
    WaitStep(7.0),
    LineStep("DialTone", "Channel's open. They wanted to hear me say it.", channel="walkie"),
    # ... 9 more lines + waits ...
    SkipPointStep(label="end_terminal"),
    LineStep("Splice",   "Don't stop walking.", channel="walkie"),
]
```

When the player reaches the end terminal, `level_5.gd` calls `cutscene_player.cancel()` and shows the end card. The cutscene exits cleanly, `done_flag` fires, end card runs, scene transitions to main menu.

The post-mortem is also right that **positional + sequential composition** can be added later via a `TriggerStep` if the level designer wants single-resource control over a multi-zone sequence. v1 ships without it.

---

## 9. Drop-in coexistence with existing engine

The new engine lives at `cutscene_engine/`:

```
cutscene_engine/
├── cutscene.gd                          # Resource — the script
├── cutscene_step.gd                     # base Resource
├── steps/
│   ├── line_step.gd
│   ├── cut_step.gd
│   ├── pan_step.gd
│   ├── wait_step.gd
│   ├── music_step.gd
│   ├── stinger_step.gd
│   ├── flag_step.gd
│   ├── parallel_step.gd
│   └── skip_point_step.gd
├── cutscene_player.gd                   # the Node driver
├── cutscene_player.tscn
└── services/
    ├── cutscene_audio.gd                # autoload — pause-respecting line/music/stinger dispatch
    └── cutscene_camera.gd               # autoload — cut/pan/save/restore
```

Existing `level/interactable/cutscene_sequence/cutscene_sequence.gd` is **not modified**. Cutscenes already authored in `.dialogue` files keep working with the old driver. New cutscenes use the new driver. Migrate one at a time.

When migrating a cutscene from old → new:

1. Read the `.dialogue` file's lines. Each becomes a `LineStep`. Replace `[#walkie]` tag with `channel = "walkie"`.
2. Replace `do CutsceneSequence.set_shot(N)` mutations with `CutStep(shot_camera_paths[N-1])`.
3. Add `MusicStep` / `StingerStep` for any audio swaps the old `intro_stinger` / `cutscene_music` exports were doing.
4. Add `SkipPointStep`s at natural beats (post-stinger, between shots).
5. Save as `cutscenes/<name>.tres`.
6. In the host scene, swap the old `CutsceneSequence` node for a new `CutscenePlayer` node + `cutscene` ref to the .tres.

When all cutscenes are migrated: delete the old engine + the `.dialogue` files used as scripts. Until then they coexist.

---

## 10. Locked decisions

Reviewed and signed off on 2026-04-29. Implementation may start without further discussion. Each decision has a brief rationale + the rejected alternatives, kept here for posterity if anyone re-litigates.

### 10.1 ParallelStep nesting model — **DECIDED: nested Cutscene via SubsequenceStep**

Parallel siblings can include other CutsceneSteps including a `SubsequenceStep` that wraps a `Cutscene`. To run a serial dialogue subgroup parallel to a pan, wrap the dialogue in its own `Cutscene` and reference it via `SubsequenceStep`. ParallelStep is pure parallel — no special-case "track" semantics.

*Rejected*: inline serial subgroups inside `ParallelStep.steps` (terser authoring but requires special-case track logic in the driver).

### 10.2 Audio service integration depth — **DECIDED: wrap existing `Walkie` / `Companion`**

`CutsceneAudio.play_line` dispatches to `Walkie.speak` or `Companion.speak` and awaits a wrapper signal. Add `pause(on: bool)` methods to both autoloads (~10 LOC each) that set `stream_paused = true/false` on the active line player. This reuses the entire TTS pipeline: cache, primer, ElevenLabs sync, BBCode strip, ducking, FX buses.

*Rejected*: new audio dispatch in `CutsceneAudio` from scratch (would duplicate TTS hashing + cache lookup + bus routing).

### 10.3 Camera service depth — **DECIDED: Tween-based, no CameraDrift dependency**

`CutsceneCamera.cut_to(camera)` calls `make_current()`. `PanStep` runs a Tween on the camera's `global_transform` (or position + basis separately) over `duration` with the configured `trans` + `ease`. `CameraDrift` is unrelated; the new engine doesn't depend on or interact with it.

*Rejected*: wrapping `CameraDrift` (it's a workaround for a different problem; tying PanStep to it leaks that workaround into the new design).

### 10.4 Skip key — **DECIDED: `ui_cancel` consumed by player while running**

`CutscenePlayer._unhandled_input` calls `get_viewport().set_input_as_handled()` on `ui_cancel` while the player is running. The pause menu never sees the input. Outside cutscenes, `ui_cancel` continues to open pause as today.

The skip action is also exposed as `@export var skip_action: StringName = &"ui_cancel"` so a per-cutscene override is possible without touching the InputMap.

*Rejected*: dedicated `skip_cutscene` InputMap action (extra binding + glyph plumbing for marginal value).

### 10.5 Cancel: done_flag vs cancelled_flag — **DECIDED: per-cutscene opt-in**

Default cancel sets `done_flag` (cancel = "cutscene ran"). Story-critical cutscenes that need to branch on player-skipped-vs-watched-fully can set `@export var cancelled_flag: StringName` on their `Cutscene` resource — when non-empty, cancel sets `cancelled_flag` instead of `done_flag`. Both flags exist on `Cutscene`; only one fires per run.

*Rejected*: forcing every cutscene to author both flags (overhead for the 90% case where nobody cares about the distinction).

### 10.6 HUD discovery — **DECIDED: `&"hud"` group**

HUD root adds itself to the `&"hud"` group in `_ready`. `CutscenePlayer` finds via `get_tree().get_first_node_in_group(&"hud")` and toggles `visible` on setup/teardown. One-line registration enables every cutscene to hide HUD without per-cutscene wiring.

*Rejected*: inspector NodePath (per-cutscene authoring tax) and `Game.hud` accessor (introduces a singleton dependency the engine doesn't otherwise need).

### 10.7 Step storage — **DECIDED: inline subresources by convention**

Steps authored inline as elements of `Array[CutsceneStep]` on the parent `Cutscene` resource. Single `.tres` file per cutscene. Authors CAN extract a step to its own `.tres` if they need to share it across cutscenes (Godot supports both transparently), but the default + recommended path is inline.

*Rejected*: per-step `.tres` files by default (too much file noise for 12-line cutscenes; reusability rarely materializes in practice).

---

## 11. Implementation phases

Adapted from the post-mortem's 2-week prototype path, scaled to fit our project size:

### Phase 1 — Skeleton (one day)

- `cutscene.gd`, `cutscene_step.gd`, `cutscene_player.gd` (no logic yet).
- `LineStep`, `CutStep`, `WaitStep` only.
- `CutsceneAudio.play_line` + `cancel_line`. Wraps `Walkie`/`Companion` per §10.2. Adds `pause(on: bool)` to both autoloads (sets `stream_paused` on active line players).
- `CutsceneCamera.cut_to`, `save_current`, `restore`. Uses `make_current()` directly per §10.3 (no CameraDrift involvement).
- HUD registers in `&"hud"` group per §10.6.
- Manually author a 3-line cutscene as a test resource. Verify it plays.

### Phase 2 — Audio + camera fidelity (one day)

- `MusicStep`, `StingerStep`, `PanStep`.
- `CutsceneAudio` pause-respecting (test: pause menu mid-line, verify line halts).
- Single test cutscene: stinger → music → cut → pan + line → music swap → end.

### Phase 3 — State + parallelism (one day)

- `FlagStep`, `ParallelStep`, `SubsequenceStep` (per §10.1).
- ParallelStep awaits all child tracks; when a serial dialogue subgroup needs to run parallel to a pan, the subgroup is its own `Cutscene` referenced via `SubsequenceStep`.
- Test: a 2-line cutscene with a parallel pan running underneath via `ParallelStep([PanStep, SubsequenceStep(dialogue_cutscene)])`.

### Phase 4 — Skip + cancel (one day)

- `SkipPointStep`.
- Skip implementation: walk forward, apply `FlagStep`s, jump to next SkipPointStep.
- `cancel()` teardown. `done_flag` set by default; `cancelled_flag` if the cutscene resource opts in per §10.5.
- `CutscenePlayer._unhandled_input` consumes `ui_cancel` while running per §10.4 — pause menu never sees the input mid-cutscene.

### Phase 5 — Migration of one real cutscene (half a day)

- Port `level_4_splice_showdown.dialogue` to `cutscenes/l4_splice_showdown.tres`.
- Replace the `CutsceneSequence` node in `level_4.tscn` with a `CutscenePlayer` + the new resource.
- Headless smoke test L4 boots, manual playthrough.

### Phase 6 — Migration of remaining + delete old (half a day)

- Port `level_4_splice_well_shit.dialogue`.
- Port `level_5.gd._BEATS` to `cutscenes/l5_walk.tres`. Replace the inline beats array.
- Delete `cutscene_sequence.gd` + `cutscene_sequence.tscn` + the two `.dialogue` files now unused.

### Phase 7 — Battle radio (half a day, optional v1.5)

- Port whatever's currently driving battle radio chatter (if anything has been built yet) to a Cutscene with no cuts and `cancel_on_flag`.

### Phase 8 — Editor scrubber (out of scope for v1, planned for v2)

- Debug panel: list current cutscene's steps with index. Click a step to fast-forward to it. Useful for QA.

**Total estimated effort**: ~4 person-days for core, +0.5–1 day per cutscene to migrate. ~250–400 LOC for the player + steps + services per the post-mortem's estimate, which feels right.

---

## 12. What we're explicitly NOT taking from the post-mortem

The post-mortem suggests **using `AnimationPlayer` for the timeline**. Pros: scrub, loop, reverse, edit; free tooling. Cons: harder to read in source control vs. a `.tres`; method-call tracks are stringly-typed (the very thing we're escaping); `.anim` files are binary-ish.

Recommendation: **don't** adopt this for v1. The Resource-based approach is more git-diffable and authorable. Re-evaluate for v2 if the editor scrubber becomes a bottleneck.

---

## 13. Anti-patterns the post-mortem calls out (ratified)

These are the rules the implementation MUST follow:

1. **No state mutations in dialogue text.** All state changes are `FlagStep`s.
2. **No `await`s on signals you don't own.** The driver awaits `CutsceneAudio.line_ended`, NOT `Walkie.line_ended`. The service is the abstraction barrier.
3. **No static singleton state in the driver.** Each `CutscenePlayer` instance owns its run state. Concurrent cutscenes (rare but legal — e.g., two background-radio cutscenes overlapping) are safe.
4. **No PROCESS_MODE_ALWAYS inside the cutscene path.** All driver/step/service tweens and timers are INHERIT.
5. **Don't bolt skip on later.** Build it day one; it shapes the rest of the architecture (FlagSteps, SkipPointSteps).

---

## 14. Migration timing + decision gate

**Decision gate passed 2026-04-29.** §10 is locked. Implementation may begin.

- Phase 1–4 land as one PR (the engine), tested with a synthetic 3-step cutscene.
- Phase 5–6 land as a follow-up PR (migration of existing cutscenes); the old engine deletes only when all uses are ported.
- Phase 7+ are post-ship if time allows.

Until phase 6 lands, the existing `cutscene_sequence.gd` and the two `.dialogue` script files keep working. No existing code is touched until each cutscene migrates.

---

## 14a. Tooling integration — bake + brief

Cutscenes authored as `.tres` `CutsceneTimeline` resources are auto-discovered by both the TTS bake script and the dialogue brief compiler. **No per-cutscene wiring is required** for either pipeline.

### Bake (`tools/prime_all_dialogue.gd`)

The script walks `res://cutscenes/*.tres`, loads each as a `CutsceneTimeline`, and recurses into `steps` — including `ParallelStep.steps` and `SubsequenceStep.timeline.steps`. Every `LineStep` contributes `(character, text)` to the synth queue, expanded through `DialogueExpander` for `{handle}` / `{action_name}` variants.

**Author rule:** if you author a `LineStep` and want its TTS pre-cached, drop the `.tres` in `res://cutscenes/`. That's it. The next bake run picks it up.

### Brief (`tools/compile_dialogue_brief.gd`)

Two new `PROGRESSION` item types:

- `["cutscene_timeline", "res://cutscenes/<name>.tres"]` — required cutscene. Missing file errors loud.
- `["cutscene_timeline_optional", "res://cutscenes/<name>.tres"]` — placeholder cutscene. Missing file renders *"(cutscene not yet authored: `…`)"* same as `dialogue_file_optional`.

The renderer walks the timeline and emits a script-shaped block:

```
Splice: There you are. ...I knew you'd see it eventually. [#walkie]
do wait(7)
DialTone: Channel's open. They wanted to hear me say it. [#walkie]
do wait(7)
# parallel {
    # pan 30.0s
    # subsequence {
        Splice: ...
    # }
# }
do GameState.set_flag("l4_done", True)
```

`LineStep` → `Character: text` (with `[#walkie]` tag when `channel == "walkie"`). `WaitStep` → `do wait(N)`. `FlagStep` → `do GameState.set_flag(...)`. `ParallelStep` / `SubsequenceStep` recurse with indentation. `CutStep` / `PanStep` / `MusicStep` / `StingerStep` / `SkipPointStep` render as comments since they're non-verbal.

**Author rule:** when adding a new cutscene, add an entry to the `PROGRESSION` array in `compile_dialogue_brief.gd` at its narrative position. The brief becomes the canonical reading order; missing entries don't appear.

### Migration debt

Until each cutscene migrates from old → new format:

- **L4 battle radio** lives in `dialogue/level_4_battle_radio_1.dialogue` (old format) — picked up by the bake script via the .dialogue scanner; rendered in the brief via `dialogue_file_optional`.
- **L5 walk-of-shame** lives in `level/level_5.gd::_BEATS` (hardcoded array) — **NOT picked up by either pipeline.** The `_BEATS` lines do not get pre-cached TTS and do not appear in the brief. Migrate to `cutscenes/l5_walk.tres` to fix; the brief PROGRESSION already has the placeholder slot waiting (`cutscene_timeline_optional`).
- **L4 splice showdown / well-shit** still in .dialogue format — same story as battle radio.

When migrating: convert `_BEATS` arrays / `.dialogue` cutscene files to `LineStep` + `WaitStep` arrays in a `CutsceneTimeline.tres`. Both tooling pipelines auto-pick-up; old file can be deleted.

---

## 15. Summary

The post-mortem is right. The shape:

- **Polymorphic typed steps as Resources** — no parser, no regex, edit-time validation.
- **A small driver** — one Node, ~250–400 LOC, owns the run state per-instance.
- **Service interfaces over the existing audio + camera systems** — pause-respecting, not direct backend calls.
- **Pause + skip are day-one invariants** — not bolted on.
- **Drop-in alongside the old engine** — migration is opt-in per cutscene.

Lives in `cutscene_engine/`. Does not touch `cutscene_sequence.gd`. Migrates cutscenes one at a time. Old code deletes only when all uses are ported.

Three use cases (battle radio, boss cutscene, L5 walk) are the same engine, different content + config. That's the validation that the abstraction is sized right.
