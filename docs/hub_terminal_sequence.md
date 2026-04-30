# Hub 5-Puzzle Sequence — Spec

A new beat on `level/hub.tscn`: five chained hacking terminals on a fresh
platform 15m behind the pedestal cluster, **gated entirely on
`level_4_completed`** (invisible AND non-collidable pre-L4). The player
solves them in order, a beacon points at whichever is next, and on
solving #5 the screen plays `cutscenes/byte.ogv` with music ducked the
way other intros do it. **Failing any one wipes the chain back to step
1.** Replayable post-completion (the cutscene only fires once).

**Status: decisions locked 2026-04-30. Ready for implementation.**

## Locked decisions

| # | decision | choice |
|---|---|---|
| 1 | Platform location | 8m×4m floor at `(X=-23, Y=11.15, Z=-85)`, facing +Z (back toward spawn) — 15m behind pedestal cluster |
| 2 | Naming | `hub_terminal_1` … `hub_terminal_5` |
| 3 | Mazes (hub-specific, authored 2026-04-30) | enigma.key (3×3) → strange_loop.core (4×3) → the_loom.dat (4×3) → entropy.cfg (4×4) → imitation_game.tmp (5×5). All UNTIMED, all hazard-bearing (Witness-style separation). Difficulty curve: 1+1 → 2+2 → 2+2 → 2+3 → 3+4 hazard cells. |
| 4 | `one_shot` | **`false`** (replayable). Cutscene gated by per-terminal `<id>_cutscene_played` flag so byte.ogv never replays on subsequent solves. |
| 5 | `required_flag` | `powerup_secret` on all 5. Chain gating moved entirely onto `visible_when_flag`. |
| 6 | Final trigger | Option A — `cutscene_video_path` export on PuzzleTerminal. |
| 7 | Fail policy | **`fail_reset_count = -1`** on all 5. Any fail (timer / hazard / cancel) wipes whole chain. |
| 8 | Platform-level gate | **`level_4_completed`** required for the platform to exist (visibility + collision). New `hub_terminal_sequence.gd` script on the parent Node3D. |
| 9 | Cutscene file | `res://cutscenes/byte.ogv` (placeholder). |

---

## Goal

> A linear 5-step puzzle ladder on the hub. Reveal one terminal at a
> time. Beacon follows the next-up. Last solve = cutscene. Done once;
> on re-entry the player sees the cleared platform with no beacon.

---

## Reuse map (what we DO NOT need to build)

Almost the entire pattern already exists. Anything below is shipping
code being authored against, not new behavior.

| Need | Existing mechanism | File |
|---|---|---|
| One terminal solved → flag set | `_on_puzzle_solved` calls `GameState.set_flag(interactable_id, true)` | `interactable/puzzle_terminal/puzzle_terminal.gd:181` |
| Next terminal hidden until previous solved | `@export var visible_when_flag` + live `Events.flag_set` listener | `puzzle_terminal.gd:117–136` |
| Next terminal locked from interaction until previous solved | `@export var required_flag` (with `locked_message`) | `puzzle_terminal.gd:151–160` |
| Beacon ON when its terminal is the current target | Beacon `@export var visible_when_flag` | `hud/components/beacon.gd:31` |
| Beacon OFF when its terminal is solved | Beacon `@export var hide_when_flag` | `hud/components/beacon.gd:32` |
| Fullscreen video w/ music+ambience pause+resume | `Cutscene.show_video(path, duration=-1, post_delay=0)` | `autoload/cutscene.gd:67` |
| Solve persists across save/reload | Existing — `puzzle_terminal.gd:108` reads `GameState.get_flag(interactable_id)` on `_ready` and disables sensor if `one_shot` | `puzzle_terminal.gd:96–119` |

The only "intro pattern" worth quoting from `Cutscene.show_video`:

```gdscript
Audio.pause_music()              # pauses music + ambience in place
player.bus = &"SFX"              # video audio routed around the music duck
player.play()
await player.finished            # natural end (or duration timeout)
Audio.resume_music()             # resumes from same playback position
```

This is the existing "way other intros work." Do not write a new movie
player — call `Cutscene.show_video` with the path.

---

## What changes in code (~70 lines across 3 files)

**Default behavior of every existing terminal stays byte-for-byte
identical** — every new export defaults to off.

### A. `puzzle_terminal.gd` (additions + one fix)

**Cutscene On Solve (~10 lines):**
```gdscript
@export_group("Cutscene On Solve")
@export_file("*.ogv") var cutscene_video_path: String = ""
@export var cutscene_only_once: bool = true
@export var cutscene_post_delay: float = 0.0
```

`_on_puzzle_solved` becomes async; after slide tween, if a path is set:

```gdscript
var played: StringName = StringName("%s_cutscene_played" % interactable_id)
if not (cutscene_only_once and bool(GameState.get_flag(played, false))):
    await Cutscene.show_video(cutscene_video_path, -1.0, cutscene_post_delay)
    GameState.set_flag(played, true)
```

The played-flag is auto-derived from `interactable_id` — no extra
authoring field. Persists via the existing GameState save layer, so
re-entering the hub after sequence completion never replays byte.ogv.

**Fail Cascade (~25 lines):**
```gdscript
@export_group("Fail Cascade")
## On fail, walk back N predecessors via `visible_when_flag` and clear
## their flags. 0 = no rewind (default). N = clear N predecessors.
## -1 = walk all the way to chain start.
@export var fail_reset_count: int = 0

static var _by_id: Dictionary = {}  # interactable_id -> PuzzleTerminal
```

`_ready` registers `_by_id[interactable_id] = self`; `tree_exiting`
erases. `_on_puzzle_failed` calls `_rewind_chain(fail_reset_count)` if
non-zero. The walk follows `visible_when_flag` (the chain link in this
design — `required_flag` is now `powerup_secret`, fixed), clears each
flag, stops cleanly when it hits an empty flag or a flag that doesn't
resolve to a registered terminal.

**Visibility-clear fix (~3 lines):** `_on_visibility_flag_set`
currently early-returns on `value=false`; change it to call
`_apply_visibility_gate()` regardless. When the chain rewinds and
predecessors clear, dependent terminals re-hide live.

### B. `beacon.gd` (one fix, ~5 lines)

Same bug as PuzzleTerminal — `_on_flag_set` only acts on `value=true`.
Refactor to call a re-evaluation helper on any matching id. After the
fix:
- Beacon's `visible_when_flag` clears → beacon re-hides.
- Beacon's `hide_when_flag` clears → beacon re-shows.

This is what makes the beacon "ratchet back" to terminal_1 after a fail.

### C. `level/hub_terminal_sequence.gd` (new file, ~25 lines)

Master gate on the parent `HubTerminalSequence` Node3D. Walks
descendants once at `_ready`:
- CSGShape3D children → toggle `use_collision`
- Area3D children → toggle `collision_layer`

Subscribes to `Events.flag_set` for `level_4_completed`.

When locked: `visible = false` (cascades), CSG `use_collision = false`,
terminal Area3Ds `collision_layer = 0`. **Unreachable** — invisible AND
non-collidable AND undetectable by InteractionSensor. Player flies past
empty space pre-L4.

When unlocked: nominal values restored. The chain inside takes over —
terminal_1 visible (its own `visible_when_flag` empty), terminals 2–5
hidden until #1 solves.

---

## Authoring spec (`hub.tscn` only — single file edit)

### Parent node

`HubTerminalSequence` Node3D at `(X=-23.07, Y=11.15, Z=-85)` (15m behind
the pedestal cluster on -Z). Script: `level/hub_terminal_sequence.gd`.

### Children

- 1× CSGBox3D platform (8m × 0.3m × 4m), `use_collision = true`,
  material match to existing pedestal stage.
- 5× `library/interactables/hacking_terminal.tscn` instances arranged in
  a row across the platform.
- 5× `hud/components/beacon.tscn` as children of corresponding terminals,
  ~1.5m local Y offset to float above each laptop.

### Per-terminal inspector overrides

| # | id | visible_when_flag | required_flag | one_shot | maze | cutscene_video | fail_reset_count |
|---|---|---|---|---|---|---|---|
| 1 | hub_terminal_1 | `&""` | powerup_secret | false | `enigma_key.maze` (3×3) | `""` | -1 |
| 2 | hub_terminal_2 | hub_terminal_1 | powerup_secret | false | `strange_loop_core.maze` (4×3) | `""` | -1 |
| 3 | hub_terminal_3 | hub_terminal_2 | powerup_secret | false | `the_loom_dat.maze` (4×3) | `""` | -1 |
| 4 | hub_terminal_4 | hub_terminal_3 | powerup_secret | false | `entropy_cfg.maze` (4×4) | `""` | -1 |
| 5 | hub_terminal_5 | hub_terminal_4 | powerup_secret | false | `imitation_game_tmp.maze` (5×5) | **`res://cutscenes/byte.ogv`** | -1 |

### Per-beacon inspector overrides (one beacon child per terminal)

| beacon parent | visible_when_flag | hide_when_flag | label |
|---|---|---|---|
| Terminal1 | `&""` (always visible until solved) | hub_terminal_1 | "01" |
| Terminal2 | hub_terminal_1 | hub_terminal_2 | "02" |
| Terminal3 | hub_terminal_2 | hub_terminal_3 | "03" |
| Terminal4 | hub_terminal_3 | hub_terminal_4 | "04" |
| Terminal5 | hub_terminal_4 | hub_terminal_5 | "05" |

---

## Edge cases traced

- **Cutscene replays on hub re-entry?** No — first solve sets
  `hub_terminal_5_cutscene_played`, persists in GameState, all subsequent
  solves skip the await.
- **Rewind ripple re-hides terminals + beacons?** Yes — fixed visibility
  listeners on both files re-evaluate on flag clears.
- **Rewind walks past `powerup_secret`?** No — registry lookup returns
  null for non-terminal ids; walk stops cleanly.
- **Mid-sequence save/reload?** Existing per-terminal `_on_puzzle_solved`
  already calls `Events.checkpoint_reached.emit(global_position)`
  (puzzle_terminal.gd:187). Mid-sequence solves persist. Mid-sequence
  fails that just rewound also persist (cleared flags propagate to save).
  Resume drops you at terminal_1 with the correct beacon visible.
- **Cancel (Esc) = fail with rewind?** Yes — by design. Player must
  commit to attempting any puzzle they open. The cancel path is hard mode
  for this sequence specifically; non-sequence terminals still default to
  `fail_reset_count = 0` so cancel-doesn't-reset elsewhere.
- **Pre-L4 player flying via grapple to where the platform should be?**
  Platform CSG `use_collision = false` + parent `visible = false` → no
  collision, no visual. Player flies through empty space.
- **Post-L4 first entry — what does the player see immediately?** Parent
  flips visible, terminal_1 visible (its `visible_when_flag` empty),
  beacon_1 visible (its `visible_when_flag` empty), terminals 2–5 hidden,
  beacons 2–5 hidden. The platform appears with one beacon and one
  terminal lit. Clean entry.
- **Post-completion replay — flags interfere?** No. Re-solving terminal_1
  (a) sets the same flag (idempotent, no-op), (b) the cutscene-on-solve
  guard never fires because terminal_1 has no cutscene path. Cutscene is
  on terminal_5 only, gated by the played-flag.

---

## Out of scope (explicit)

- Audio bus / cutscene plumbing changes (existing `Cutscene.show_video`
  already covers our needs).
- Maze authoring — placeholders chosen from existing files.
- A "controls submenu" or HUD device-glyph live-refresh (separate
  threads from earlier in this session).
- Splash text / pre-cutscene dialogue beats — the spec is "solve #5 →
  byte.ogv plays → done." Add a dialogue line later if the moment needs
  it.

---

## Implementation order (each step independently smoke-testable)

1. **`puzzle_terminal.gd` — Cutscene On Solve.** Add export group + async
   await branch in `_on_puzzle_solved`. Smoke: existing 12 terminals
   still solve correctly (default empty path = unchanged behavior).

2. **`puzzle_terminal.gd` — Fail Cascade + visibility-clear fix.** Add
   static registry + `_rewind_chain`. Extend `_on_visibility_flag_set` to
   call `_apply_visibility_gate()` on any flag change (not just true).
   Smoke: existing terminals unchanged (default `fail_reset_count=0`).

3. **`beacon.gd` — flag-clear handling.** Refactor `_on_flag_set` to
   re-evaluate gates on any value. Smoke: level_2 beacons still appear
   correctly on first entry (their gating flags don't currently clear, so
   live behavior unchanged; the new code path is exercised only by the
   hub sequence's rewind).

4. **`level/hub_terminal_sequence.gd` — new master gate script.** Walks
   CSG/Area3D children to toggle collision; subscribes to
   `Events.flag_set` for `level_4_completed`. Smoke: drop into hub
   pre-L4, platform invisible + non-collidable; manually
   `set_flag("level_4_completed", true)` via debug console, platform
   appears.

5. **`hub.tscn` authoring.** Instance the parent + platform + 5 terminals
   + 5 beacons; set inspector values per the tables above. Smoke: walk
   sequence end-to-end.

6. **End-to-end smoke:** F12 to hub post-L4, verify only beacon_1
   visible, solve through #5, verify byte.ogv plays with music ducked +
   resumes. Mid-sequence fail at #3 — verify chain wipes back to #1.
   F12 stash + reload mid-sequence — verify resume state.

**No new tests required.** The PuzzleTerminal contract is unchanged for
terminals that don't set the new exports. `tests/test_maze_data.gd` is
unaffected.

Estimated implementation: **~45 min**.
