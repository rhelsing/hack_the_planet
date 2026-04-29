# Level Progression Mockup — Phased Plan

End-to-end scaffold for the 4-level arc. Each level grants one power-up (gold floppy disk pickup) that **enables a mechanic** on the player character, and ends with a "you did it" dialogue routing back to a **hub** where NPCs react to progress. Current level persists via save.

Mapping:
| # | Level theme | Emoji | Power-up flag | Mechanic enabled |
|---|---|---|---|---|
| 1 | Rollerblade | 💘 love | `powerup_love` | Skate mode toggle (already built — gate behind flag) |
| 2 | Hacking | 💻 secret | `powerup_secret` | Hack Mode ability (stub for mockup) |
| 3 | Grapple | 💋 sex | `powerup_sex` | Grapple Hook ability (stub for mockup) |
| 4 | Flares | 😇 god | `powerup_god` | Shoot Flares ability (stub for mockup) |

This doc covers the **mockup** — flat-plane levels + placeholder hub + stub mechanics (input + sound + debug print, no real visuals yet). The goal is to prove the state machine, persistence, hub loop, and flag-gated mechanics end-to-end.

---

## State model

Everything lives in `GameState.flags` (persisted via SaveService):

| Key | Type | Meaning |
|---|---|---|
| `current_level_num` | int (1..4) | Which level the player last entered. |
| `level_N_completed` | bool | Set when player picks "Continue" in end-of-level dialogue. |
| `powerup_love` / `_secret` / `_sex` / `_god` | bool | Pickup collected → corresponding mechanic enabled + emoji shown. |

`SaveService.current_level: StringName` holds the scene path for resume. Updated in lockstep with `current_level_num` when advancing.

---

## How Skate works today (reference for gating)

Found in exploration — captured here so the gating task is unambiguous:
- **State**: `player/body/player_body.gd` — `_current_profile: MovementProfile` (walk or skate reference, not a bool).
- **Toggle**: `toggle_profile()` at `player_body.gd:334` — called from `player_brain.gd:79` on `toggle_skate` input action.
- **Skin sync**: `toggle_profile()` calls `_skin.set_skate_mode(...)`; KayKit handles wheel visibility + root Y offset at `kaykit_skin.gd:265-272`.
- **Init seeding**: `_ready()` at `player_body.gd:254-255` calls `set_skate_mode(...)` once before any input — **gating must cover this too**, otherwise wheels show at spawn.
- **HUD ability contract** (expected by `hud/components/powerup_row.gd:49-55`, not yet wired up): child nodes of `PlayerBody/Abilities` with `ability_id: StringName`, `owned: bool`, `enabled: bool`. Body emits `ability_granted(id)` and `ability_enabled_changed(id, bool)`.

Gating at `toggle_profile()` is a 1-line add (`if not GameState.get_flag(&"powerup_love"): return`) plus the `_ready` seeding guard. The other three power-ups will follow the same pattern: input handler checks flag, mechanic no-ops without it.

---

## Phase 1 — LevelProgression autoload (state machine backbone)

Goal: single source of truth for level state + transitions. Build first so every other phase can wire into it.

- [ ] New autoload `autoload/level_progression.gd`:
  - `register_level(num: int)` — level scenes call on `_ready`; sets `current_level_num`, updates `SaveService.current_level` to current path, saves.
  - `advance()` — sets `level_N_completed` flag for current level, routes to `&"res://level/hub.tscn"` via SceneLoader, saves.
  - `goto_level(num: int)` — hub pedestals call; validates gate (previous complete), sets save path, routes.
  - Read helpers: `get_current_level_num()`, `is_level_complete(num)`, `is_powerup_owned(flag)`.
- [ ] Register in `project.godot` autoloads (after SaveService).
- [ ] Verify main-menu "Continue" honors `SaveService.current_level` (already does — smoke test only).

**Gate**: headless boot clean; new unit test `tests/test_level_progression.gd` covering advance + goto_level flag writes.

---

## Phase 2 — Powerup pickup (flag + gold floppy visual)

- [ ] `interactable/pickup/powerup_pickup.gd` extending `Pickup`.
  - Exports `powerup_flag: StringName`, `powerup_label: String` (e.g. `"LOVE"`).
  - `interact()`: `GameState.set_flag(powerup_flag, true)`, emit `Events.item_added`, trigger Phase 3 UX, `queue_free` when dismissed.
- [ ] `interactable/pickup/powerup_pickup.tscn`: inherits `pickup.tscn`, ~2× scale, gold `StandardMaterial3D` (metallic + emissive), child `Label3D` on the disk face billboarded with `powerup_label`, slow Y rotation.
- [ ] `tests/test_powerup_pickup.gd` — instantiate, interact, assert flag set.

**Gate**: test passes, headless boot clean.

---

## Phase 3 — Install toast + How-to-use panel

- [ ] `hud/components/install_toast.gd` + scene: banner reading `INSTALLING [POWERUP_LABEL]…`, ~1.5s progress bar, emits `finished`.
- [ ] `hud/components/howto_panel.gd` + scene: TextureRect with placeholder image + one-line caption (`"PRESS R TO SKATE"`, `"PRESS F TO HACK"`, etc.), dismissable on input or 3s timeout.
- [ ] Wire `powerup_pickup.gd` → show toast → wait `finished` → show panel → wait dismissed → queue_free.
- [ ] Placeholder assets in `hud/icons/howto/` — one per power-up; start with static images (gifs later).

**Gate**: manual — walk into pickup, see toast → panel → emoji on character (Phase 4).

---

## Phase 4 — KayKit emoji indicator

- [ ] `Label3D` child on `kaykit_skin.tscn` named `PowerupEmojis`, ~2m above head, billboard Y, large pixel size, no depth test.
- [ ] Script `player/skins/kaykit/kaykit_powerup_display.gd`:
  - `_ready`: rebuild text from flags (fixed order: 💘 💻 💋 😇).
  - Subscribe to `Events.flag_changed` (add signal to `autoload/events.gd` if missing; otherwise listen to `Events.item_added` and re-read flags).
  - Rebuild on change.

**Gate**: smoke test boot, manual confirmation emoji appears post-pickup.

---

## Phase 5 — Abilities node + gate Skate behind `powerup_love`

Goal: stand up the ability scaffold the HUD already expects, and gate Skate as the reference implementation.

- [ ] Create `Abilities` child node under `PlayerBody` in `player_body.tscn`.
- [ ] Base `Ability` class (`player/abilities/ability.gd`) exposing `ability_id: StringName`, `owned: bool`, `enabled: bool`, `powerup_flag: StringName`. On `_ready` and on `Events.flag_changed`, set `owned = GameState.get_flag(powerup_flag)`.
- [ ] `SkateAbility` (`player/abilities/skate_ability.gd`) extends `Ability` — `ability_id = &"Skate"`, `powerup_flag = &"powerup_love"`. No logic of its own; it's a flag mirror.
- [ ] Gate in `player_body.gd`:
  - `toggle_profile()` (line ~334): `if not GameState.get_flag(&"powerup_love"): return`.
  - `_ready()` seeding (line ~254-255): only call `set_skate_mode(true)` if flag set AND `_current_profile == skate_profile`.
- [ ] Emit `ability_granted(&"Skate")` from `PlayerBody` on `Events.flag_changed` when the flag flips to true (for HUD).

**Gate**: 
1. Fresh save (no flag) → R does nothing, no wheels at spawn.
2. After pickup → R toggles skate normally, HUD `powerup_row` shows the skate icon.
3. Existing tests green.

---

## Phase 6 — Stub the other three mechanics

Goal: each remaining power-up enables an input-driven stub — real mechanic visuals come later, but the gating + signal wiring is real.

- [ ] Add input actions to `project.godot`: `hack_toggle` (F), `grapple_fire` (G), `flare_shoot` (H) — pick keys that don't collide.
- [ ] `HackModeAbility` (`powerup_secret`): on input, toggle a `Node3D` "hack mode tint" overlay under the camera (simple ColorRect with cyan tint); print `[hack] on/off`.
- [ ] `GrappleAbility` (`powerup_sex`): on input, shoot a debug raycast from camera, print hit position; (real grapple physics later).
- [ ] `FlareAbility` (`powerup_god`): on input, spawn a bright OmniLight3D at player position for 2s; print `[flare] fired`.
- [ ] Each ability script extends `Ability`, checks `owned` before acting, emits `ability_enabled_changed` when toggling on/off (for HUD cooldown/active visuals later).

**Gate**: with all 4 flags set (set manually via debug), all 4 inputs trigger their stubs. Without a flag, input no-ops silently.

---

## Phase 7 — Mockup level template

- [ ] `level/level_mockup.tscn`:
  - Root `Node3D` + `level_mockup.gd`.
  - Flat `CSGBox3D` 60×1×8 ground, existing sky env.
  - Player spawn marker at one end.
  - 2 `PhoneBoothCheckpoint`s along the length.
  - 1 `PowerupPickup` at midpoint.
  - 1 `DialogueTrigger` at the far end → `level_clear.dialogue`.
- [ ] `level_mockup.gd` exports: `level_num: int`, `powerup_flag: StringName`, `powerup_label: String`.
- [ ] `_ready`: push flag/label into the pickup, call `LevelProgression.register_level(level_num)`.

**Gate**: headless boot clean. Manual: walk plane, hit checkpoints, pickup (toast + panel), emoji on KayKit, mechanic now works, reach NPC.

---

## Phase 8 — End-of-level dialogue (routes to hub)

- [ ] `dialogue/level_clear.dialogue`:
  ```
  ~ start
  You did it!
  - Continue
      do LevelProgression.advance()
  - Keep exploring
  => END
  ```
- [ ] `advance()` (already built Phase 1) sets `level_N_completed`, routes to hub, saves.

**Gate**: manual — reach NPC, Continue → land in hub with updated flags.

---

## Phase 9 — Hub scene

- [ ] `level/hub.tscn`:
  - Placeholder flat plane + distinct skybox.
  - 4 `HubPedestal` nodes (new `interactable/hub_pedestal/` — extends `Interactable`, exports `level_num: int`, `level_scene: String`).
    - Gate: locked if `level_num > 1` and `level_{num-1}_completed` is false.
    - Interact: `LevelProgression.goto_level(level_num)`.
    - Visual: green tint/glow if that level is already complete.
  - 4 NPCs (one per theme) using `dialogue_trigger.tscn`. Each has a `.dialogue` branching on `level_N_completed` + `powerup_X`.
  - Player spawn marker.
- [ ] `level/hub.gd`: on `_ready`, `SaveService.current_level = &"res://level/hub.tscn"` so quitting here resumes here.
- [ ] `main_menu.gd` "New Game": reset GameState, goto hub (hub's L1 pedestal launches L1).

**Gate**: New Game → hub → only L1 unlocked → L1 → Continue → hub with L1 green + L2 unlocked → talk to L1 NPC, dialogue acknowledges. Quit in hub → reload → same state.

---

## Phase 10 — Clone mockup to 4 levels

- [ ] `level/level_1.tscn` … `level/level_4.tscn`, each instancing `level_mockup.tscn` with:
  - L1: `level_num=1, powerup_flag=&"powerup_love", powerup_label="LOVE"`
  - L2: `level_num=2, powerup_flag=&"powerup_secret", powerup_label="SECRET"`
  - L3: `level_num=3, powerup_flag=&"powerup_sex", powerup_label="SEX"`
  - L4: `level_num=4, powerup_flag=&"powerup_god", powerup_label="GOD"`
- [ ] Hub pedestals' `level_scene` exports wired to these paths.

**Gate**: full playthrough — New Game → hub → L1 → hub → L2 → hub → L3 → hub → L4 → hub with all 4 emojis + all 4 mechanics usable + all 4 NPCs reacting.

---

## Phase 11 — (Future) Polish

Deferred until the chain is live:
- Real mechanics replacing stubs (real grapple physics, real flare projectile, real hack overlay effects).
- Per-level bespoke flags (kills, secrets, floppies per level) for richer hub dialogue.
- Real level content replacing flat planes.
- Real hub design.
- HUD emoji row (2D HUD counterpart to the 3D Label3D on KayKit).

---

## Verification per phase

```bash
godot --headless --quit-after 120 2>&1 | grep -Ei "SCRIPT ERROR|Compile Error"
```
Must be empty.

```bash
godot --headless --script res://tests/test_level_progression.gd --quit
godot --headless --script res://tests/test_powerup_pickup.gd --quit
godot --headless --script res://tests/test_kaykit_skin_contract.gd --quit
```

---

## Open questions (non-blocking)

- **Stub mechanics' keybinds**: F/G/H placeholder — adjust if they collide.
- **Hub ambiance**: grey plane now, real design later.
- **L4 ending**: return-to-hub vs. credits stub — mockup just lands in hub with everything complete.
- **How-to panel content**: static images first, gifs/interactive demos later.
