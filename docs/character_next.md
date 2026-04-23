# character_next.md — Character Controller Roadmap (v1)

Scope for `character_dev`: what's next after Patch A, covering standard movements, power-up progression, and expanding the skin/animation library. Companion spec to `CLAUDE.md` and `sync_up.md`. Nothing below is implemented yet; this doc is the agreement before writing code.

---

## 0. Ownership & boundaries

`character_dev` owns:
- `player/body/*` — PlayerBody, Intent, MovementProfile
- `player/brains/*` — Brain base, PlayerBrain, EnemyAIBrain, ScriptedBrain, new AI archetypes
- `player/skins/*` — CharacterSkin contract + concrete skins
- `enemy/brains/*` — AI brain instances per enemy type
- `enemy/*.tscn` — enemy pawn variants (PlayerBody inheritance)
- `tests/test_*` — character-side unit/smoke tests

Not this doc's turf:
- Interactables, dialogue, puzzles, audio ducking → `docs/interactables.md`
- Pause menu, settings, save/load, HUD rendering → `docs/menus.md`
- Level geometry shaders → `docs/materials.md`

---

## 1. Standard movement — the baseline kit

A "standard" movement is always available regardless of which power-up pickups the player has. Core traversal vocabulary. Wall-ride and grind are **NOT** standard — they're tied to the Skate power-up (see §2).

| Move | Status | Source of truth |
|---|---|---|
| **Walk / run** | ✅ shipped | `MovementProfile.max_speed`, `accel`, `friction` |
| **Jump + double jump** | ✅ shipped | `PlayerBody._air_jump_available` + front-flip visual |
| **Attack** | ✅ shipped | `PlayerBody._start_attack_jostle` — forward lunge + sweep against `attack_target_group` via `take_hit()` |
| **Dash / Dodge** | ❌ to implement | Proposed: `Intent.dash_pressed` edge + body applies forward velocity impulse with cooldown + short i-frame window. |
| **Crouch** | ❌ to implement | Proposed: `Intent.crouch_held` boolean + body halves collider height + reduces `max_speed` while held. |

**Skate-only movements** (locked behind the Skate power-up pickup):

| Move | Status |
|---|---|
| Wall-ride / wallrun | ✅ shipped (active only when `skate_profile` is current) |
| Rail grind | ✅ shipped (same condition) |

### 1.1 Dash / Dodge — proposed contract

Same action, context-sensitive direction: "dash" when moving forward, "dodge" when holding a lateral input. Either way, a short high-speed impulse with brief i-frames.

- **Intent**: new field `dash_pressed: bool` (edge-triggered). PlayerBrain fills from `Input.is_action_just_pressed("dash")`.
- **InputMap**: new `dash` action — keyboard `Shift` (physical_keycode 4194325), gamepad right-shoulder (button 5). Right-trigger reserved for aimed-projectile power-ups (Flares).
- **MovementProfile tuning**:
  - `dash_speed: float = 18.0` — peak velocity magnitude along dash direction.
  - `dash_duration: float = 0.2` — seconds of impulse.
  - `dash_cooldown: float = 0.8` — seconds before another dash can fire.
  - `dash_iframes_duration: float = 0.15` — damage-immunity window (shorter than total dash; recovery frames are vulnerable).
  - `dash_preserves_y: bool = true` — keep current jump/fall momentum on Y.
- **Direction picking**: if `intent.move_direction.length() > 0.2`, dash along `move_direction`. Otherwise, dash along last-faced direction. Lateral input → sideways dodge feel; forward input → forward dash.
- **Body behavior** (`PlayerBody._physics_process`): track `_dash_timer` and `_dash_cooldown_timer`. While `_dash_timer > 0`, velocity is locked to `dash_direction * dash_speed`. `_start_attack_jostle` suppressed. `take_hit` gated by the same `_invuln_until_time` mechanism as respawn invuln — reused, no new state.
- **Skin**: add optional `func dash() -> void` to CharacterSkin contract with a no-op default. Sophia can animate a roll via AnimationTree; minimal skins fall back to the move anim.
- **Test**: `tests/test_dash.gd` — ScriptedBrain fires dash, assert velocity magnitude matches profile, assert cooldown gates subsequent dashes, assert take_hit no-ops during i-frame window.

### 1.2 Crouch — proposed contract

- **Intent**: new field `crouch_held: bool` (held, NOT edge). PlayerBrain fills from `Input.is_action_pressed("crouch")`.
- **InputMap**: new `crouch` action — keyboard `Ctrl` (physical_keycode 4194326), gamepad `B` (button 1).
- **MovementProfile tuning**:
  - `crouch_speed_multiplier: float = 0.35` — max_speed multiplier while crouched.
  - `crouch_collider_scale_y: float = 0.6` — capsule collider height scale.
- **Body behavior**: while `intent.crouch_held`, scale the collision shape's height by `crouch_collider_scale_y` (cached-restore on release), multiply computed speed by the crouch multiplier, skip wall-ride attempts (crouch breaks wall contact).
- **Skin**: new optional `func crouch(active: bool) -> void`. Sophia overrides for a crouch pose via her AnimationTree; others no-op.
- **Test**: `tests/test_crouch.gd` — hold crouch, assert collider height shrinks + speed caps.

---

## 2. Power-ups — world pickups that grant permanent abilities

A power-up is a world object. The player walks into it, picks it up, and permanently has that ability. Abilities can be toggled on/off. When active, an optional visual modifier appears on the character (cape, glasses, backpack, etc.).

Level design decides *where the pickups live* and *how early the player finds them* — not the code. The user wants all four placed by mid-way through level 4, but that's a scene-authoring detail, not a systems concern.

### 2.1 Roster (initial)

| Name | Ability | Visual mod | World pickup |
|---|---|---|---|
| **Skate** | Higher max_speed + grind on rails (wraps existing `toggle_skate`) | Rollerblades on feet | Floating skates mesh |
| **Grapple Hook** | Aim + fire hook, pulls pawn toward hit point | Hook on belt / wrist | Floating hook mesh |
| **Flares** | Fire projectile; damages enemies, lights dark zones | Flare gun on hip | Floating flare gun |
| **Sunglasses / Hack** | Toggle reveals hidden interactables, recolors world, modifies AI perception | Glasses on face | Floating glasses |

Placeholders from the README (`love`, `sex`, `secret`) — same architecture applies whenever mechanics are defined. Add more `PawnAbility` subclasses; no code elsewhere changes.

### 2.2 Architecture — `PawnAbility` component + `PowerUpPickup` interactable

Two pieces, neither knows about the other directly:

**`PawnAbility`** — a Node attached to PlayerBody. Owns one ability's tick logic, Intent field extension, cooldowns, VFX. Body calls `ability.tick(self, intent, delta)` each frame.

```
PlayerBody
├── PlayerBrain
├── SophiaSkin (or any CharacterSkin)
└── Abilities (Node container)
    ├── SkateAbility
    ├── GrappleAbility
    ├── FlareAbility
    └── HackModeAbility
```

```gdscript
class_name PawnAbility
extends Node

## True once the pickup has been collected. Persists via GameState.
var owned: bool = false

## Player/user toggle — can be disabled without losing ownership.
var enabled: bool = true

## Called by PlayerBody in _physics_process. Ability reads intent fields
## it cares about, mutates body velocity / spawns projectiles / swaps skin
## modifier. No-op when !owned or !enabled.
func tick(_body: PlayerBody, _intent: Intent, _delta: float) -> void: pass

## Optional visual modifier scene (cape, hat, glasses) parented to the skin
## when the ability is active. Abilities that have no visual leave this null.
@export var visual_mod_scene: PackedScene
```

**`PowerUpPickup`** — an Interactable (uses interactables_dev's base class). On overlap with the player, grants ownership of the ability and frees itself.

```gdscript
class_name PowerUpPickup
extends Interactable  # from docs/interactables.md §3

## Which ability this pickup grants. The string matches the ability node's
## name under Abilities (e.g., "GrappleAbility"). Matched on the player at
## pickup time.
@export var ability_id: StringName

func interact(actor: Node3D) -> void:
    if actor is PlayerBody:
        (actor as PlayerBody).grant_ability(ability_id)
    queue_free()
```

`PlayerBody.grant_ability(id)`:
1. Find the Abilities child node matching `id`, set `owned = true`.
2. Add pickup flag to `GameState.flags` (so it persists across saves and scene reloads).
3. If `visual_mod_scene` is set, instance it and parent to the skin.
4. Emit `Events.powerup_acquired(id)` for audio / HUD / tutorial popups.

On scene load, `PlayerBody._ready` checks `GameState.flags` to restore owned abilities and re-attach visual mods. No code distinguishes "first pickup in L1" from "re-loading a save where you already had it" — same code path.

### 2.3 Enable/disable toggle

The user wants power-ups toggleable (e.g., sunglasses-mode off for normal world, on for hack view). Two options equally simple — pick when implementing:

- **(A) Per-ability hotkey**: each ability binds its own `Input` action that flips `enabled`.
- **(B) Ability wheel / menu**: UI lets the player toggle owned abilities from a list. ui_dev territory.

Default to (A) for v1 — zero UI work. Ability wheel is a later polish pass.

### 2.4 Why this shape holds

- **Pickup and ability are decoupled.** interactables_dev can place `PowerUpPickup` instances in levels without knowing anything about what the ability does. character_dev writes the ability without knowing how or where the pickup is placed.
- **Enemies/companions can own abilities too.** A ranged-cop archetype gets `FlareAbility` at spawn (via export preset on its variant scene) — no pickup needed. Same code path.
- **Save / load is trivial.** Ability ownership lives in `GameState.flags`. SaveService already serializes that dict.
- **New power-ups are self-contained.** Add a Node subclass, add an Intent field if needed, add an InputMap action if needed, add a Pickup placement. No changes to PlayerBody.

---

## 3. Character expansion — new skins + animation libraries

User provided six asset packs. Inventory:

| Pack | Format | Skeleton | Usefulness |
|---|---|---|---|
| **Universal Base Characters [Standard]** | `.gltf` (Godot-native folder) | Universal | ⭐ Primary target. 2 base meshes (Superhero_Male_FullBody, Superhero_Female_FullBody). Godot-compatible out of the box. |
| **Universal Animation Library [Standard]** | `.glb` (Unreal-Godot folder) | Universal | ⭐ Primary anim source. Single `UAL1_Standard.glb` (~8 MB). Pairs with Base Characters skeleton. |
| **Universal Animation Library 2 [Standard]** | `.glb` + Female Mannequin `.glb` | Universal | ⭐ Additional anims + a female mannequin variant. |
| **Ultimate Platformer Pack (Quaternius)** | `.gltf` + `.fbx` | Custom / Quaternius | 🟡 Alt character (`Character.gltf`, `Character_Gun.gltf`) — different skeleton from Universal, separate import pipeline. Platform cubes are level-art not skin-relevant. |
| **KayKit Platformer Pack** | `.fbx` | n/a | 🔴 Environment props (arches). No characters. Skip for character scope. |
| **Animations V1 (01_XX.fbx)** | `.fbx` | Unknown | 🔴 Raw mocap, unknown skeleton. Defer until we determine compatibility. |

### 3.1 Strategy — "duplicate Sophia's template, don't abstract yet"

**AAA-proven pattern: the first working skin IS the template.** Each new skin is a copy of `sophia_skin.tscn` with the model + AnimationTree clip references swapped. Sophia's files are never modified in the process.

Why not build a shared base class with a ClipMap resource + code-generated state machine? Premature abstraction. We have one proven AnimationTree (Sophia's). With only one data point, there's no way to know which parts of it are truly common across rigs. Extract the base only after **three skins** on this pattern reveal real duplication (rule of three).

Per-skin workflow:
1. In Godot editor, open `player/skins/sophia/sophia_skin.tscn`, File → Save As → `<new_skin>_skin.tscn` under its own folder.
2. Swap the Sophia model reference for the new rig's `.gltf`/`.glb`.
3. In the duplicated AnimationTree, re-point each `AnimationNodeAnimation`'s `animation` property to the new rig's clip names (editor inspector, ~30s per state node).
4. Wire `extra_animation_sources` to merge additional packs (the K1 pattern) so all needed clip names resolve.
5. Write a thin `<NewSkin>.gd` mirroring Sophia's method shape — drop Sophia-specific bits (`blink`, `eye_mat`, body-mesh damage overlay) unless the new rig supports them.
6. Copy Sophia's contract test as `test_<new_skin>_contract.gd`.

Adopting the Universal Base Characters + UAL 1+2 gives us:
- 2 base bodies (male, female) + female mannequin — 3 skin variants all on the same skeleton, all consuming UAL1+UAL2.
- Each skin is still its own file (own AnimationTree .tres, own script) — but they end up very similar. That's the signal for "now extract a base class."

Existing Sophia and KayKit skins stay on their own skeletons. KayKit upgrades from string-play to a Sophia-derived AnimationTree so it gets tilts too.

### 3.2 Target directory layout

```
player/skins/
  sophia/              (existing)
  cop_riot/            (existing)
  kaykit/              (existing)
  universal/           (new)
    _shared/
      ual1.glb         # Universal Animation Library 1
      ual2.glb         # Universal Animation Library 2
      animation_library.tres  # Godot AnimationLibrary combining the above
    base_male/
      base_male.gltf + .bin + textures
      base_male_skin.gd
      base_male_skin.tscn
    base_female/
      ... (same shape)
    base_female_mannequin/
      ... (same shape)
```

### 3.3 Implementation phases

Phase per skin variant:

1. **Import**: copy .gltf + .bin + textures into `player/skins/universal/<variant>/`. Run editor to index.
2. **Animation wiring**: import UAL1/UAL2 glb files with "Import As: AnimationLibrary" flag. Attach libraries to an `AnimationPlayer` child of the skin scene.
3. **State-machine wrapper**: build an `AnimationTree` with states matching the CharacterSkin contract (Idle/Move/Fall/Jump/EdgeGrab/WallSlide/Attack/+Dash/+Crouch when those ship). Map to specific clips from the library.
4. **Skin script**: `base_male_skin.gd extends CharacterSkin` calling `state_machine.travel(<state>)`. Tune `lean_pivot_height` and `body_center_y` for the rig's height.
5. **Contract test**: copy `tests/test_sophia_skin_contract.gd` as `tests/test_base_male_skin_contract.gd`.
6. **Acceptance**: swap the Player's `skin_scene` in `game.tscn` to the new variant. Boot, walk, jump, verify animations play.

**Estimate**: ~2 hours per variant after the first. First one is ~half a day because the AnimationTree wiring is the real work.

### 3.4 Use cases

Same body, swappable skins:
- **Player**: drag-and-drop preferred base character in `game.tscn` Player inspector.
- **Enemy archetypes**: each enemy type (patroller, ranged, boss) gets its own skin + tuning. Universal female for police, Universal male for henchman, Quaternius for a stylized boss.
- **Companion**: future companion pawn uses yet another Universal variant + a `CompanionBrain`.
- **Remote player (multiplayer)**: `NetworkBrain` reads a skin-id from peer metadata, instantiates the matching skin.

No new code required beyond the skin scenes themselves — `PlayerBody.skin_scene` already supports it.

---

## 3.4 Making a new enemy variant (drop-in)

Workflow to put any skin in the level as an enemy:

1. **Duplicate** `res://enemy/enemy_cop_riot.tscn` → `res://enemy/enemy_<name>.tscn`.
2. **Change the skin reference**: replace the `skin_scene` ExtResource line with the target skin's `.tscn` UID/path.
3. **Save**. Godot regenerates the UID of the new scene automatically.
4. **Place**: open `res://level/level.tscn` and drag an instance of the new enemy scene wherever you want.

Everything else — AI brain, pawn_group, attack_target_group, max_health, dies_permanently, speed profile — stays identical across variants by default. Override only what's different for that enemy archetype (e.g., a tank with higher max_health).

**Pre-made variants currently in the repo**:
- `enemy_cop_riot.tscn` — original cop_riot enemy (from KayKit animations pack)
- `enemy_kaykit.tscn` — KayKit mannequin with full dodge/crouch/punch animation set
- `enemy_sophia.tscn` — Sophia as an enemy (same skeleton + animations as the default player)

Creating a new enemy is a 90-second editor task once a skin exists.

---

## 4. AI archetypes

Each archetype is a Brain subclass (or a parameterized EnemyAIBrain preset). Progression idea: new archetypes appear every few levels, same as power-ups.

| Archetype | Brain | Behavior |
|---|---|---|
| **Cop patrol** (current) | `EnemyAIBrain` | Wander + chase + contact-lunge. Shipped. |
| **Cop_riot static watcher** | `EnemyAIBrain` w/ `wander_speed_fraction=0`, `detection_radius=20` | Stands watch, chases when spotted. Trivial preset — just a tuned `.tscn` variant. |
| **Ranged cop** | `RangedEnemyBrain` (new) | Keeps distance from player, fires flare projectile (reuses `FlareAbility`). Needs P3 power-up system to exist. |
| **Ambusher** | `AmbusherBrain` (new) | Hides until player in range, then charges. Needs a `hidden` state that disables detection against the pawn. |
| **Boss (L-end)** | `BossBrain` (new) | Scripted phase transitions. One-off per level end. Out of scope for v1. |

**Vision cone debug** (README requests): ship as an `@tool` `MeshInstance3D` child of `EnemyAIBrain` that draws a cone geometry matching `detection_radius` + a forward-facing aperture. Toggleable via `@export var show_vision_cone: bool = false`. Visible in editor only; runtime hidden. ~30 lines.

---

## 5. Patch plan — order of delivery

Each patch is independently shippable + smoke-testable. No patch depends on another dev's work unless marked.

| Patch | Scope | Blocks / Blocked by |
|---|---|---|
| **B** | Save dict (`PlayerBody.get_save_dict` / `load_save_dict`) | Blocks `ui_dev`'s SaveService end-to-end. |
| **C** | HUD signals (`health_changed`, `profile_changed`, `died`, `respawned`) | Unblocks `ui_dev`'s HUD wiring. |
| **D** | Dash + Crouch (standard movements) | Self-contained. |
| **E** | Universal Base Male skin variant — first new character | Proves the import pipeline. Self-contained. |
| **F** | `PawnAbility` base + Abilities container + `PlayerBody.grant_ability()` + `Events.powerup_acquired` | Infra for power-ups. Blocks G+. Needs `PowerUpPickup` (interactables_dev) for in-world pickup, but F ships independently and can be tested via direct `grant_ability()` calls. |
| **G** | `SkateAbility` — wrap existing `toggle_skate` + optional wheeled-feet visual mod | Blocked by F. |
| **H** | `GrappleAbility` — Intent `grapple_pressed`, hook mesh + rope visual, physics pull | Blocked by F. |
| **I** | `FlareAbility` — Intent `fire_pressed`, projectile system, enemy damage hook | Blocked by F. Partially blocks Ranged Cop archetype. |
| **J** | `HackModeAbility` — toggle shader/state; needs interactables_dev for hidden-interactable reveal | Blocked by F + some interactables_dev hooks. |
| **K** | Universal Base Female + Mannequin skin variants | Blocked by E. |
| **L** | Ranged / Ambusher enemy archetypes | Blocked by F, I. |
| **M** | Vision cone debug gizmo | Self-contained. |

**Recommended order for immediate next sessions**: B → C → D → E → F → G. Then power-up iteration H/I/J in parallel with new character variants K.

---

## 6. Open questions (need user answers before committing)

Resolved:
- ~~Is skate a power-up or always-on?~~ → Power-up pickup. Same code path as the other three.
- ~~Is it an unlock-by-level or a pickup?~~ → Pickup. Levels decide *placement*; code doesn't gate ownership by level number.

Still open:
1. **Enable/disable UX** — per-ability hotkey (v1 default) or ability-wheel UI (v2)? Not blocking F; confirm before shipping G.
2. **"Love, sex, secret"** — mechanic definitions? Placeholders in current README. Can be added any time via a new `PawnAbility` subclass + pickup scene.
3. **Character selection**: per-save character pick, or fixed Sophia protagonist with cop_riot/others reserved for enemies/companions?
4. **Companion scope**: fight-capable, follow-only, or mixed? Different `CompanionBrain` per answer.
5. **Multiplayer timing**: v1 or v2? If v1, `NetworkBrain` needs scoping now. If v2, we ship single-player first (cheap because Intent is already a serialization-friendly contract, trivial to replay remote intent later).

---

## 7. Non-goals (explicitly out of scope for character_next)

- Authoring new animations or models (art dept).
- Level design / placement (level dept).
- Input remapping UI (ui_dev).
- Dialogue, cutscenes, scripted sequences (interactables_dev owns via ScriptedBrain hook).
- Voice acting / TTS for the player pawn (interactables_dev Dialogue autoload).
- Procedural animation (IK, ragdoll) — big rabbit hole; skip for v1.

---

## 8. Sources used to scope this doc

- **README.md** — roadmap bullets for Character Controllers.
- **CLAUDE.md** — principles + "Current state of the refactor" section.
- **sync_up.md** — cross-dev boundaries already negotiated.
- **docs/interactables.md** — for `Events` + `GameState` signal/flag patterns I extend (§6, §7).
- **docs/menus.md** — for the Settings/SaveService contract PlayerBody plugs into.
- **Pack inventories** — `unzip -l` on the six downloaded asset archives (see §3).
