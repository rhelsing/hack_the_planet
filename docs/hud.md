# HUD + Player UI Spec (v1, Godot 4.6.2 Forward+)

In-game HUD umbrella: health bar, collectible counters, powerup row, event toasts, level banner, death overlay. Sibling to `docs/menus.md` (pause/settings/save out-of-game), `docs/character_next.md` (ability system this doc visualizes), `docs/scroll_dialogue.md` (skill-check mechanics this doc toasts), and `docs/interactables.md` (runtime services this doc subscribes to).

> **Sync rule:** `ui_dev` owns this doc. Where it depends on siblings, it cites them by section. §7 lists open contracts for sibling devs; §13 captures their inline comments.
>
> **Amendment log:**
> - **v1** (2026-04-22) — initial spec.
> - **v1.1** (2026-04-22) — sibling responses landed (§13). Changes:
>   1. char_dev's HUD signals are **local on `PlayerBody`**, not on `Events` bus. HealthBar / DeathOverlay / PowerupRow connect via player-node ref. Bus-pollution prevention; matches the cross-cutting-vs-tight-coupling rule from `sync_up.md`.
>   2. char_dev added **`PlayerBody.ability_granted(id)`** and **`ability_enabled_changed(id, enabled)`** local signals. PowerupRow uses these instead of polling.
>   3. char_dev added bonus **`PlayerBody.is_dying()`** accessor — DeathOverlay can self-gate without poll.
>   4. interactables_dev shipped **`GameState.coin_count` + `floppy_count`** (schema bumped 1→2, migration-safe). Counters component reads these directly.
>   5. interactables_dev owns the **`LevelRoot.gd` base** carrying `hud_level_title` + `hud_level_objective` exports (§7.1.4 bounced from char_dev).
>   6. ToastStack expanded to include **`door_opened`**, **`puzzle_solved`**, **`puzzle_failed`** per interactables_dev's bonus list (§13.2 — informational, not asks).
>   7. `HUDState` fallback (§7.2.2 in v1) — **dropped**. Counters live on `GameState`, no second store.
>   8. All §7 open contracts now **🟢 closed**.

---

## 0. Project facts that constrain everything

| Fact | Value | Source |
|---|---|---|
| Engine version | **Godot 4.6.2 stable** | [`materials.md §0`](materials.md) |
| Renderer | **Forward+** | same |
| Release target | **Desktop only** | same |
| Doc house style | `materials.md`, `menus.md`, `interactables.md` | same |
| HUD scene path | `res://hud/hud.tscn` | new |
| HUD layer | CanvasLayer `layer = 0` | menus.md §13 CanvasLayer z-order table |
| Aesthetic | Terminal — monospace, green-on-black, cyan accents | inherits `menu/menu_theme.tres` |
| Save persistence of counters | Via `GameState` → round-trip through `SaveService` | §7.2 open contract |

**User-confirmed decisions (2026-04-22 chat):**
1. Skill-check outcomes show as **toast** (not permanent HUD).
2. Collectible counts are **persistent** in save data; show as emoji + number.
3. Death overlay text is **"CONNECTION TERMINATED"**.
4. Powerup row shows what the player owns; empty until char_dev's first pickup is placed.
5. Scope is v1; minimap / inventory grid / skill-level summary are deferred (§10).

---

## 1. Godot 4.6 primitives we lean on

None of this is custom framework. First-party features listed so future contributors know where to read the docs.

| Primitive | Used for | Source |
|---|---|---|
| `CanvasLayer` | HUD root, isolated from 3D camera | [CanvasLayer](https://docs.godotengine.org/en/stable/classes/class_canvaslayer.html) |
| `Control` + anchors | Responsive positioning of elements | [Control](https://docs.godotengine.org/en/stable/classes/class_control.html) |
| `ProgressBar` | Health bar underlying mechanic (or `TextureProgressBar` if we go stylized) | [ProgressBar](https://docs.godotengine.org/en/stable/classes/class_progressbar.html) |
| `Tween` | Toast fade-in/out, banner slide, death-overlay reveal | [Tween](https://docs.godotengine.org/en/stable/classes/class_tween.html) |
| `RichTextLabel` | Typewriter reveal on banner / death / toast if needed | [RichTextLabel](https://docs.godotengine.org/en/stable/classes/class_richtextlabel.html) + `visible_ratio` |
| `AnimationPlayer` | Optional per-element animations (pop/shake) | [AnimationPlayer](https://docs.godotengine.org/en/stable/classes/class_animationplayer.html) |
| Process modes | `PROCESS_MODE_ALWAYS` on toast stack so toasts animate even if tree paused; `PROCESS_MODE_INHERIT` on rest | [Pausing games](https://docs.godotengine.org/en/stable/tutorials/scripting/pausing_games.html) |

---

## 2. Architecture in one page

```
┌─────────────────────────────────────────────────────────────────────┐
│  Autoloads (read-only from HUD — single source of truth)            │
│                                                                     │
│   Events       GameState     Skills      PlayerBody (scene node)    │
└─────────────────────────────────────────────────────────────────────┘
         ▲              ▲             ▲               ▲
         │ subscribe    │ counters    │ levels        │ health, dying,
         │              │             │ cooldowns     │ abilities
         │              │             │               │
   ┌─────┴──────────────┴─────────────┴───────────────┴──────┐
   │  HUD (res://hud/hud.tscn) — CanvasLayer, layer 0         │
   │                                                          │
   │  ┌──────────────┐                     ┌──────────────┐  │
   │  │ HealthBar    │                     │ Counters     │  │
   │  │ (top-left)   │                     │ (top-right)  │  │
   │  └──────────────┘                     └──────────────┘  │
   │                                                          │
   │         ┌─────────────────────────────────┐              │
   │         │ ObjectiveBanner (top-center,    │              │
   │         │   2s on scene enter, fades)     │              │
   │         └─────────────────────────────────┘              │
   │                                                          │
   │         ┌─────────────────────────────────┐              │
   │         │ ToastStack (bottom-center,      │              │
   │         │   event-driven, 1.5-2s each)    │              │
   │         └─────────────────────────────────┘              │
   │         ┌─────────────────────────────────┐              │
   │         │ PowerupRow (bottom-center,      │              │
   │         │   hidden until ≥1 ability owned)│              │
   │         └─────────────────────────────────┘              │
   │                                                          │
   │  ┌────────────────────────────────────────────────────┐  │
   │  │ DeathOverlay (fullscreen, hidden until died signal)│  │
   │  └────────────────────────────────────────────────────┘  │
   └──────────────────────────────────────────────────────────┘
```

**Legend:** solid arrows = direct calls / signal connections. HUD is a passive consumer: it subscribes to `Events` and reads `GameState`/`Skills`/`PlayerBody` state; it never mutates game state.

HUD is added as a child of `game.tscn` (a new `HUD` node, instance of `hud.tscn`). Not an autoload — only exists in gameplay. Not shown on the main menu (menu has its own UI at `res://menu/main_menu.tscn`).

---

## 3. The six components

Each component is a self-contained `Control` scene authored under `res://hud/components/`. They're all children of `hud.tscn`'s root `CanvasLayer`. Each owns its own subscription setup in `_ready`; disconnect in `_exit_tree` to avoid leaks when `hud.tscn` is freed on level change.

### 3.1 HealthBar

**Path:** `res://hud/components/health_bar.tscn + .gd`

**Visual:** Top-left corner. Style options (see §5; pick one):
- (a) **ASCII** — `HP [████████░░░░]` in monospace, 12 cells, cyan filled / dim-green empty. Matches terminal aesthetic cleanly.
- (b) **Thin gradient bar** — 160×8 px `TextureProgressBar`, cyan→dim-cyan gradient, border line. More conventional, less hacker-flavored.

v1 default: **(a) ASCII**. One line to swap if (b) reads better after playtesting.

**Data:**
- Reads `PlayerBody.get_health() -> int` and `PlayerBody.get_max_health() -> int` (char_dev Patch C).
- Subscribes to **`PlayerBody.health_changed(new: int, old: int)` — local signal**, not on the `Events` bus (per char_dev §13.1 — keeps per-pawn traffic off the global bus).
- Also polls once in `_ready` after the player pawn is in-tree.

**Behavior:**
- No animation on increase.
- Small shake + brief red flash on decrease (Tween, 200ms). Shake amplitude 3px, flash from current color → `alert_red` → current.
- If `_health == 0`, nothing here — DeathOverlay takes over (§3.6).

**Hide when:** never (always on during gameplay).

### 3.2 Counters (coin, floppy)

**Path:** `res://hud/components/counters.tscn + .gd`

**Visual:** Top-right corner, vertical stack. Each row is emoji + space + number in monospace, size 20. Cyan text.

```
🪙 14
💾 3
```

**Data:**
- Reads `GameState.coin_count: int` and `GameState.floppy_count: int` — both shipped by interactables_dev (schema v2, round-trips through SaveService).
- Subscribes to `Events.coin_collected(coin: Node)` and `Events.item_added(id: StringName)` for the pop animation. By the time the listener fires, the counter is already incremented (interactables_dev bumps inside the same code path — no race).
- Reads counters on `_ready` from GameState.

**Behavior:**
- On increment, number pops (scale 1.0 → 1.15 → 1.0 over 150ms via Tween).
- Optional: small `+1` float up from the row and fade (deferred polish; leave hook, skip impl in v1).

**Hide when:** counters == 0 (don't show a zero floppy count until the first one is picked up).

### 3.3 PowerupRow

**Path:** `res://hud/components/powerup_row.tscn + .gd`

**Visual:** Bottom-center, above the ToastStack. A horizontal row of icon slots. One slot per owned ability.

Each slot:
- 32×32 icon (texture or emoji fallback)
- Faint cyan border when the ability is `owned` but not currently `enabled`
- Solid cyan border when `enabled`
- Cooldown overlay (radial or alpha 0.4) when on cooldown per `Skills.cooldown_remaining_sec()` (only relevant if an ability routes through the Skills system — abilities without a cooldown never show one)

**Data:**
- char_dev's `PlayerBody` exposes a container named `Abilities` with `PawnAbility` children ([`character_next.md §2.2`](character_next.md)). Each has `ability_id: StringName`, `owned: bool`, `enabled: bool`.
- Subscribes to **`PlayerBody.ability_granted(ability_id)` — local signal** (char_dev §13.1) — adds a slot.
- Subscribes to **`PlayerBody.ability_enabled_changed(ability_id, enabled)` — local signal** — toggles slot border between owned-but-inactive vs active.
- On `_ready`, walks `PlayerBody.Abilities` children and adds a slot for every `owned` one.
- Subscribes to `Events.skill_cooldown_started(skill, seconds)` (live, see [`autoload/skills.gd:91`](../autoload/skills.gd) per interactables_dev §13.2) — only relevant for abilities whose `ability_id` matches a skill.

**Known ability IDs** (from `character_next.md §2.1-2.2`):
- `&"Skate"`, `&"GrappleAbility"`, `&"FlareAbility"`, `&"HackModeAbility"`

**Icon assets** (**open item**, §10):
- v1 fallback: emoji in a Label (⛸ 🪝 🚨 🕶). Low-friction, on-brand for hacker-emoji flavor.
- v1.1: proper 32×32 PNG icons in `res://hud/icons/`.

**Hide when:** no powerups owned (empty row is clutter).

### 3.4 ToastStack

**Path:** `res://hud/components/toast_stack.tscn + .gd`

**Visual:** Bottom-center, above PowerupRow, stack-of-messages (newest on top of the stack, stack grows downward). Each toast is a `RichTextLabel` with:
- `> ` prefix (terminal cursor)
- Message in `primary_green` (success / neutral) or `alert_red` (failure)
- Typewriter reveal: `visible_ratio` tweened 0 → 1 over 300ms
- Hold: 1500ms
- Fade-out: 300ms
- Total lifetime: ~2100ms

**Event → toast mapping:**

| Event | Text | Color | Notes |
|---|---|---|---|
| `skill_check_rolled(skill, 45, true)` | `> [HACK 45%] SUCCESS` | green | skill name upper-cased |
| `skill_check_rolled(skill, 45, false)` | `> [HACK 45%] FAILED` | red | |
| `PlayerBody.ability_granted(&"GrappleAbility")` | `> GRAPPLE ABILITY ONLINE` | cyan | local signal; powerup id de-suffixed + spaced |
| `skill_granted(skill, new_level)` | `> HACK ★%d` | green | first grant only (`new_level == 1`) |
| `door_opened(id)` | `> ACCESS GRANTED :: %s` | cyan | id stringified |
| `puzzle_solved(id)` | `> %s :: SOLVED` | green | upper-case id |
| `puzzle_failed(id)` | `> %s :: FAILED` | red | upper-case id |

**Filtering rule:** not every `Events` broadcast shows a toast — only the ones in the table. This stays a curated set so the HUD doesn't become noise.

**Event coalescing:** if two of the same event fire within 500ms (e.g., double-pickup), merge to a single toast `> +2 💾`. Deferred to v1.1; v1 just shows both toasts stacked.

**Stack cap:** 3 toasts max on screen. If a 4th arrives, oldest is freed early.

**Process mode:** `PROCESS_MODE_ALWAYS` on the stack root so toasts animate if the tree is paused mid-animation (e.g., dialogue opens mid-skill-check toast).

### 3.5 ObjectiveBanner

**Path:** `res://hud/components/objective_banner.tscn + .gd`

**Visual:** Top-center, below any future minimap space. Text banner appears on scene enter, auto-fades.

```
> LEVEL 01 :: MAINFRAME
  retrieve the floppy disk
```

- Line 1 is the level title (cyan, monospace, size 28, typewriter 600ms).
- Line 2 is the objective (green, size 18, typewriter after line 1 finishes).
- After both reveal: hold 2.5s, fade-out 600ms, free self.

**Data source:**
- Each level scene's root exposes two `@export` fields:
  - `hud_level_title: String = ""` (e.g., `"LEVEL 01 :: MAINFRAME"`)
  - `hud_level_objective: String = ""` (e.g., `"retrieve the floppy disk"`)
- On `SceneLoader.scene_entered(scene)`, HUD root reads those two strings off `scene` and instantiates a banner. If either is empty, banner skips.

**This adds two `@export` fields to level root scripts.** I'll specify them in §7 as an open contract with char_dev (or whoever owns level scripts — interactables_dev likely).

### 3.6 DeathOverlay

**Path:** `res://hud/components/death_overlay.tscn + .gd`

**Visual:** Fullscreen `ColorRect` that fades in from transparent to opaque black. Centered `RichTextLabel` with:

```
CONNECTION TERMINATED

> reconnecting to last checkpoint...
```

- Line 1: size 48, `alert_red`, monospace, typewriter 700ms.
- Line 2 (after line 1 done): size 20, `primary_green`, typewriter 500ms, then ellipsis animates with dots-rotator.
- Hold ~1.2s after both lines revealed.
- Fade back to transparent over 500ms.
- Total lifetime: ~3.5s. During this time, `PauseController.user_pause_allowed = false` so Esc doesn't open the pause menu on the death card (see [`menus.md §13.3(c)`](menus.md)).

**Data:**
- Subscribes to **`PlayerBody.died()` — local signal** (char_dev §13.1, ships in Patch C). On fire, plays the overlay.
- Subscribes to **`PlayerBody.respawned()` — local signal** — calls `queue_free` if still alive (handles fast respawns where char_dev's retry is quicker than our 3.5s lifetime).
- Optional gate: `PlayerBody.is_dying() -> bool` for self-check on overlap edge cases (char_dev §13.1).

**Behavior edge cases:**
- If player dies again while overlay is already up (retry-before-overlay-done): restart the typewriter, don't stack.
- Full-screen input is absorbed during the overlay via `mouse_filter = STOP` on the ColorRect and `set_input_as_handled()` in `_input` for `ui_accept` / `ui_cancel`. Arrow keys and pause are also eaten so the player can't do weird things mid-death.

---

## 4. Event subscription map

All subscriptions live in each component's `_ready`, disconnected in `_exit_tree`. HUD *never* mutates these events — only reads. Split between **local signals** (1-to-1 player-HUD coupling) and the **`Events` bus** (cross-cutting world broadcasts).

### 4.1 Local signals on `PlayerBody`

| Signal | Subscriber | Handler outcome |
|---|---|---|
| `PlayerBody.health_changed(new, old)` | HealthBar | Re-render bar; flash red if `new < old` |
| `PlayerBody.died()` | DeathOverlay | Show overlay |
| `PlayerBody.respawned()` | DeathOverlay | Hide overlay early if still visible |
| `PlayerBody.ability_granted(id)` | PowerupRow, ToastStack | Add slot; queue "ABILITY ONLINE" toast |
| `PlayerBody.ability_enabled_changed(id, enabled)` | PowerupRow | Toggle slot border |

HUD looks the player up via `get_tree().get_first_node_in_group("player")` once at `_ready` (after `call_deferred` to guarantee tree ordering — see §9.4).

### 4.2 `Events` bus (cross-cutting broadcasts)

| Event | Subscriber | Handler outcome |
|---|---|---|
| `Events.skill_check_rolled(skill, pct, ok)` | ToastStack | Queue `[SKILL PCT%] SUCCESS/FAILED` toast |
| `Events.skill_cooldown_started(skill, sec)` | PowerupRow | Start cooldown overlay if that skill maps to an owned ability |
| `Events.skill_granted(skill, new_level)` | ToastStack | Queue `SKILL ★N` toast on first grant only |
| `Events.coin_collected(node)` | Counters | Pop number, re-read `GameState.coin_count` |
| `Events.item_added(id)` | Counters | If `id == &"floppy_disk"`, pop floppy counter |
| `Events.item_removed(id)` | Counters | Re-sync (rare; e.g., puzzle consumes floppy) |
| `Events.door_opened(id)` | ToastStack | Queue `ACCESS GRANTED :: id` toast |
| `Events.puzzle_solved(id)` | ToastStack | Queue `id :: SOLVED` toast (green) |
| `Events.puzzle_failed(id)` | ToastStack | Queue `id :: FAILED` toast (red) |
| `SceneLoader.scene_entered(scene)` | ObjectiveBanner | Show banner if `scene.hud_level_title` is set |

All Events bus signals exist in `autoload/events.gd` today (interactables_dev shipped them).

---

## 5. Visual style

Inherits `menu/menu_theme.tres` (see [`menus.md §12`](menus.md)). Summary:

| Token | Hex | Use in HUD |
|---|---|---|
| `bg_black` | `#000000` | Transparent usually; solid for DeathOverlay |
| `primary_green` | `#33FF66` | Body text, counter numbers, success toasts |
| `accent_cyan` | `#00FFFF` | Titles (banner line 1), health-bar fill, focused/selected |
| `dim_green` | `#198833` | Empty health cells, disabled ability slots |
| `alert_red` | `#FF5577` | Failure toasts, death card title, health flash |

Typography: system monospace fallback (`JetBrains Mono` → `Menlo` → `Consolas` → `monospace`).

Per-element visual tweaks in the component sections above. All tweened animations use `Tween.EASE_OUT` for reveals, `EASE_IN` for fades.

---

## 6. Scene layout

```
hud.tscn  (CanvasLayer, layer 0)
├── Anchors
│   ├── TopLeft (Control, anchor top-left)
│   │   └── HealthBar (instance of health_bar.tscn)
│   ├── TopRight (Control, anchor top-right)
│   │   └── Counters (instance of counters.tscn)
│   ├── TopCenter (CenterContainer anchored top)
│   │   └── ObjectiveBanner spawn point
│   ├── BottomCenter (VBoxContainer anchored bottom-center)
│   │   ├── ToastStack (instance of toast_stack.tscn)
│   │   └── PowerupRow (instance of powerup_row.tscn)
│   └── Fullscreen (Control fullscreen)
│       └── DeathOverlay spawn point
└── hud.gd (root script, wires SceneLoader signal for banner)
```

`hud.tscn` added to `game.tscn` as a child of `Game` root. Not an autoload (HUD shouldn't exist on the main menu).

---

## 7. Interfaces — contracts (all 🟢 closed as of v1.1)

### 7.1 @ char_dev (`docs/character_next.md` owner) — 🟢

1. 🟢 **Health getters** — `PlayerBody.get_health()` + `get_max_health()` shipping in Patch C. Bonus: `is_dying() -> bool`.
2. 🟢 **HUD signals — local on PlayerBody**, not on `Events` bus (char_dev's call, accepted). Signatures: `health_changed(new: int, old: int)`, `died()`, `respawned()`.
3. 🟢 **`Abilities` container convention confirmed** — `Node` named `Abilities` direct child of `PlayerBody`, `PawnAbility` children with `owned: bool`, `enabled: bool`, `ability_id: StringName`, `visual_mod_scene: PackedScene` (optional). Plus new local signals `ability_granted(id)`, `ability_enabled_changed(id, enabled)`.
4. 🟢 **Level scene exports** — bounced to interactables_dev (see §7.2.4).

### 7.2 @ interactables_dev (`docs/interactables.md` owner) — 🟢

1. 🟢 **`GameState.coin_count` + `floppy_count` shipped** — schema bumped 1→2, migration-safe (old saves default to 0). Round-trip via `to_dict`/`from_dict`. interactables_dev increments inside their own `Events.coin_collected` subscriber and inside `add_item()` on `&"floppy_disk"` — single owner, no race. HUD reads the field in its bump-pop handler.
2. ❌ **`HUDState` fallback dropped** — not needed.
3. 🟢 **`Events.skill_cooldown_started(skill, seconds)` live** at `autoload/skills.gd:91` and `autoload/events.gd:59`. Wire HUD directly.
4. 🟢 **`LevelRoot.gd` base class** — interactables_dev owns it. Carries `@export var hud_level_title: String` + `@export var hud_level_objective: String`. Level scenes extend the base.
5. 🟢 **Coin vs floppy distinction kept**: coins = arcade score pickups (auto-trigger), floppies = narrative inventory (`Pickup` interactable, `requires_key`-gateable). Different UX roles.
6. 🟢 **Objective text** — static `@export` is fine for v1. Add `Events.objective_changed(new_text)` later when first dynamic objective lands.

### 7.3 No open contracts.

---

## 8. Integration points with existing code

Minimally invasive. Files touched:

| File | Change (additive only) |
|---|---|
| `game.tscn` | Add `HUD` child (instance of `res://hud/hud.tscn`), layer 0, no transform. |
| `autoload/events.gd` | No new signals from ui_dev for this spec. Consumers only. (New signals in §7 are char_dev's / interactables_dev's to add.) |
| `game.gd` | No changes. |
| `controls_hint.gd` | No changes. HUD and ControlsHint coexist on layer 0; ControlsHint is positioned bottom-right and HUD's BottomCenter doesn't collide. If overlap shows during playtest, move ControlsHint to bottom-left. |
| `autoload/game_state.gd` | ✅ **interactables_dev shipped** (counters + schema v2). Not my edit. |
| `player/body/player_body.gd` | **char_dev Patch C** (health getters + HUD local signals + ability signals). Not my edit; awaiting their next push. |

---

## 9. Open risks before prototype

1. **PauseController modal-count interaction with DeathOverlay.** DeathOverlay absorbs input but isn't technically a modal in the `Events.modal_opened/closed` sense. If PauseController sees no modal open during death and the user mashes Esc, Esc goes to the pause menu. §3.6 addresses this via `user_pause_allowed = false` during the death sequence; untested in the real flow until char_dev ships `died()`/`respawned()`.

2. **Emoji font coverage.** 🪙 and 💾 are rendered by the system font chain. On some Linux setups without an emoji font, they'd render as tofu. Desktop-only per `materials.md §0` = Mac/Windows have native emoji coverage. Acceptable risk.

3. **Toast stack + dialogue balloon overlap.** If a skill-check toast fires while dialogue is open, both draw in the lower-middle region. Coexistence is fine (different layers — dialogue at 10 per `menus.md §13.1`, HUD at 0), but they'd visually stack. Acceptable: the skill-check toast is *about* the dialogue roll, and seeing it alongside the balloon is informative.

4. **HUD scene load order vs player ready.** HUD's `_ready` runs when `game.tscn` loads. `HUD` queries `PlayerBody` methods, which requires Player to already be in the tree. Godot runs `_ready` children-first, so both HUD and Player are ready before `game.gd._ready` — but the exact order between siblings depends on tree order. Defensive: HUD does its first poll in `call_deferred` to guarantee ordering.

5. ~~**`health_changed` signal location.**~~ — resolved v1.1: local signals on `PlayerBody` per char_dev §13.1.

---

## 10. Deferred / out of scope

- **Minimap.** Own spec, own asset pipeline (render-to-texture of level). Not v1.
- **Full inventory grid.** Pause-menu tab. Extends `docs/menus.md`.
- **Skill-level summary page.** Pause-menu tab. Extends `docs/menus.md`.
- **Quest / objective tracker** (persistent, mid-level). v1 only has the enter-scene banner.
- **Ability wheel** (hold to select active powerup). `character_next.md §2.3` deferred this; v1 uses hotkey per-ability.
- **Toast coalescing / priority queue.** v1 just stacks up to 3.
- **Subtitles panel** (if dialogue is voiced/played offscreen). `scroll_dialogue.md §1.1` already has its own rendering; HUD doesn't duplicate.
- **Damage-direction indicator** (red arrow showing where the hit came from). Nice polish, not v1.
- **Combo / score multiplier** à la skateboard games. Readme hints at grind mechanics; a combo meter could live here later.
- **Boss-health bar** at bottom-center. No boss encounters yet.
- **PNG icons for abilities.** v1 uses emoji fallback. v1.1 swaps in real icons.

---

## 11. Target file layout

```
hud/
  hud.tscn / .gd                        <-- root, wires SceneLoader.scene_entered
  components/
    health_bar.tscn / .gd
    counters.tscn / .gd
    powerup_row.tscn / .gd
    toast_stack.tscn / .gd
    toast.tscn / .gd                    <-- single toast, ToastStack instantiates
    objective_banner.tscn / .gd
    death_overlay.tscn / .gd
  icons/                                <-- v1.1; v1 uses emoji
    skate.png   (placeholder)
    grapple.png
    flare.png
    hack.png
game.tscn                               <-- +HUD child, additive
docs/
  hud.md                                <-- this file
```

---

## 12. Sources

**Godot 4.6 docs:**
- [CanvasLayer](https://docs.godotengine.org/en/stable/classes/class_canvaslayer.html)
- [Control](https://docs.godotengine.org/en/stable/classes/class_control.html)
- [ProgressBar](https://docs.godotengine.org/en/stable/classes/class_progressbar.html)
- [RichTextLabel](https://docs.godotengine.org/en/stable/classes/class_richtextlabel.html)
- [Tween](https://docs.godotengine.org/en/stable/classes/class_tween.html)
- [Pausing games and process mode](https://docs.godotengine.org/en/stable/tutorials/scripting/pausing_games.html)

**In-project sibling docs:**
- `docs/character_next.md` — ability system this doc visualizes (PowerupRow, DeathOverlay signals)
- `docs/scroll_dialogue.md` — skill-check mechanics this doc toasts
- `docs/interactables.md` — Events bus, GameState contract, Audio cues used for toast sfx
- `docs/menus.md` — theme, CanvasLayer z-order, PauseController coordination
- `docs/materials.md` — visual palette + terminal aesthetic precedent

**Reference commits (survey sources for this doc's §0-3):**
- `autoload/skills.gd` lines 101, 108, 128 — skill API we read
- `autoload/game_state.gd` lines 12-14, 19-42, 63-81 — fields we read, counter asks target here
- `player/body/player_body.gd` lines 91, 186, 331, 438 — fields/methods we read or request getters for
- `autoload/events.gd` — signals we subscribe to (existing + contract asks)

---

## 13. Sibling dev comments (reserved)

> Appended by `char_dev`, `interactables_dev`, `dialogue_dev` in response to §7 asks. `ui_dev` reads and either accepts the feedback (amending §0 amendment log as v1.1) or pushes back in `sync_up.md`.

### @ char_dev — 2026-04-22 (reply)

Read the spec. Clean design, boundaries match what I've been holding to. Per-ask:

**§7.1.1 — health getters.** Yes, trivial. Shipping as `PlayerBody.get_health() -> int` + `PlayerBody.get_max_health() -> int` in the next small patch. Will also expose `PlayerBody.is_dying() -> bool` so your DeathOverlay can gate its own display logic without polling a private field.

**§7.1.2 — HUD signals (`health_changed` / `died` / `respawned`).** I'll ship as **local signals on `PlayerBody`**, not on the `Events` autoload.

Reasoning:
- `Events` is for game-world broadcasts where subscribers don't know the source (coin collected, flag reached, door opened). HUD-vs-PlayerBody is a tight 1-to-1 binding — the HUD knows which player it's tracking (local human pawn), PlayerBody knows who asked.
- Broadcasting on `Events` pollutes the bus with per-pawn traffic. With multiplayer / companion later, `Events.health_changed` would fire per pawn and every subscriber would have to filter.
- Aligns with my earlier rule in sync_up.md: "emit on Events when cross-cutting; local signal when parent-child or tight coupling."

You connect via:
```gdscript
var player: PlayerBody = get_tree().get_first_node_in_group("player")
if player != null:
    player.health_changed.connect(_on_health_changed)
    player.died.connect(_on_player_died)
    player.respawned.connect(_on_player_respawned)
```

**Signatures I'll ship:**
```gdscript
signal health_changed(new: int, old: int)
signal died()
signal respawned()
```

If you'd rather I also mirror them on `Events` for convenience (small redundancy, easier for your HUD to subscribe without a player-ref lookup), I'll add that — tell me.

**§7.1.3 — `Abilities` container convention.** Not yet implemented (Patch F from `character_next.md` §2.2). Confirming the contract so you can build against it:

- The container will be a `Node` named `Abilities` as a direct child of `PlayerBody`.
- Each child is a `PawnAbility` subclass with:
  - `owned: bool` — true once the pickup has been collected (persisted via `GameState.flags`).
  - `enabled: bool` — player-toggleable; distinct from `owned`.
  - `ability_id: StringName` — matches the pickup's `ability_id` export.
  - `visual_mod_scene: PackedScene` (optional) — the cape/glasses/hook visual that parents to the skin when active.
- Signal `PlayerBody.ability_granted(ability_id: StringName)` and `PlayerBody.ability_enabled_changed(ability_id: StringName, enabled: bool)` when those lands.

Your HUD walks `get_node_or_null(^"Abilities")` → iterates children → filters `owned && enabled`. One slot per match. Fine.

**§7.1.4 — Level scene exports (`hud_level_title`, `hud_level_objective`).** Not my turf — level scenes live in `res://level/` and aren't owned by `character_next.md`. Flagging for interactables_dev or whoever owns level scripting (probably the same person shipping `scroll_dialogue.md`). I'd reject the ask on "char_dev should add this" grounds but agree the convention is sensible.

**§9.1 — PauseController vs DeathOverlay.** Noted. Once I ship `died()`/`respawned()` and you wire the overlay, I can help debug the Esc-during-death case if it breaks. Current `_start_death`/`_finish_death` flow in `player_body.gd` is:
- `_start_death`: sets `_dying = true`, freezes HP, plays confetti, pops up.
- `_physics_process`: ticks `_dying_timer`, calls `_finish_death` when it hits zero.
- `_finish_death`: respawns (or `queue_free`s if `dies_permanently`).

Your `user_pause_allowed = false` for the `_dying` window should cover it — I'll emit `died()` at the start of `_start_death` and `respawned()` at the end of `_finish_death`. Both single-shot, no re-emission on repeated deaths because `_dying` already guards re-entry.

**§9.5 — local signal vs bus.** Agreed, going local (see §7.1.2 above).

### ETA
Patch labeled **C** (HUD signals) was deferred in the sync_up.md Patch B/C split. Now that you're actively blocked on it, I'll promote to "next immediate patch" as soon as you're ready. Five lines of code on my side plus a test. Say go and I ship.


### @ interactables_dev — 2026-04-22

Reviewed §7.2 + §7.3. Accepting most, rejecting fallback, picking up char_dev's orphan from §7.1.4.

**§7.2.1 — counters on `GameState`. ✅ Shipped.**

```gdscript
# autoload/game_state.gd (landed, test_game_state.tscn updated + green)
var coin_count: int = 0
var floppy_count: int = 0
```

Increment policy:
- `coin_count` bumps inside my own subscriber to `Events.coin_collected` — single owner, no double-count race.
- `floppy_count` bumps inside `add_item()` when `id == &"floppy_disk"` — same code path as `Events.item_added`, so by the time your HUD's `item_added` listener runs, the counter is already current.

Both fields round-trip through `to_dict` / `from_dict`. **`SCHEMA_VERSION` bumped 1 → 2.** Old v1 save files without these fields default to 0 on load (migration-safe via `.get(..., 0)`). Test coverage added.

You don't need a separate signal — subscribe to `Events.item_added` and read `GameState.floppy_count`, or subscribe to `Events.coin_collected` and read `GameState.coin_count` for the bump-animation toast.

**§7.2.2 — `HUDState` fallback. ❌ Rejected.** Not needed given 7.2.1 is clean.

**§7.2.3 — `Events.skill_cooldown_started` stays. ✅ Confirmed live.** Already emitting today from `Skills.start_cooldown()` — see `autoload/skills.gd:91` and `autoload/events.gd:59`. Payload is `(skill: StringName, seconds: float)`. Wire your HUD directly.

**§7.3.1 — coin vs floppy distinction.** Keep both. Coins = arcade score pickups (`level/interactable/coin/coin.gd` is an auto-trigger per `docs/interactables.md §18.1`). Floppies = narrative/progression items (enter inventory via the narrative `Pickup` interactable; gate doors/terminals via `requires_key`). They serve different UX roles; don't merge them.

**§7.3.2 — objective text.** Static `@export var hud_level_objective: String` on the level scene root is fine for v1. For dynamic mid-level changes, add `Events.objective_changed(new_text: String)` — a 1-line Events addition; your HUD listens. Ship the signal when the first dynamic objective lands. Until then, static exports only.

**§7.1.4 (char_dev bounced to us) — level scene exports.** ✅ Accepting. Levels are interactables-adjacent — doors/checkpoints/dialogue triggers/puzzles live in them — so the convention sits naturally on my side. Proposal: base `LevelRoot.gd` with `@export var hud_level_title: String` + `@export var hud_level_objective: String`, extended by any level scene's Node3D root. HUD reads both on scene load. Shipping when HUD v1 is ready to consume.

**Bonus — other signals from my surface worth subscribing to (not asks, just informational):**
- `Events.door_opened(id)` — toast candidate: "Door opened: village_gate"
- `Events.puzzle_solved(id)` / `Events.puzzle_failed(id)` — puzzle outcome toasts
- `Events.skill_check_rolled(skill, pct, ok)` — you already have this
- `Events.skill_granted(skill, new_level)` — new in P4; perfect for "Composure ★1" toast
- `Events.dialogue_started(id)` / `Events.dialogue_ended(id)` — already counted via `modal_opened/closed` per sync_up convention, keeping HUD hidden during dialogue modals

**Bumping `docs/interactables.md` spec v1.2 → v1.3** for the GameState schema change. No breaking behavior.

### @ dialogue_dev / interactables_dev (dialogue scope)

*[reserved — if the skill-check toast visual overlaps with anything in scroll_dialogue.md or if event names need adjustment]*
