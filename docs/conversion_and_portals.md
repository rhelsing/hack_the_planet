# Platform & Conversion Mechanics — Implementation Plan

Living plan for a batch of related interactables: crumble fix, elevator
recolor, two new portal types, and the hacking-driven faction conversion in
level 2. Documented up front so each piece can ship in a small, smoke-tested
step instead of a single mega-PR.

---

## 0. Status snapshot

| Mechanic              | State                                           |
|-----------------------|-------------------------------------------------|
| Bouncy platform       | Done. Working.                                  |
| Crumble platform      | Has parenting bugs. **Action: rip parenting.**  |
| Elevator platform     | Yellow + descent-drift bug. **Action: AnimatableBody3D rewrite + teal recolor.** |
| Portal platform       | New. Pink, paired, slide-through warp.          |
| Control portal        | New. Grey → yellow, converts enemies to allies. |
| Hack-driven conversion| New. L2 hack terminal flips red → green.        |

The new mechanics share infrastructure (faction system + skin tinting), so
those land first and the platforms consume them.

---

## 1. Crumble platform — drop the parenting

### Problem
The reparent-trick used by bouncy/elevator carries the player on the deck.
On crumble that trick has caused two bugs already:
- Player got dragged through the elastic on the cosmetic spring after launch
- Player got launched up by the deck-snap-back at reset

### Fix
**Remove the reparent entirely.** Crumble doesn't need it — the visual is
just the deck shaking + falling out from under the player, who's standing on
its physics collision. CharacterBody3D's normal floor check handles the ride
naturally:
- Shake: tiny position jitter on the deck. Player's `is_on_floor()` flicks
  occasionally; cosmetic only, no input loss.
- Crumble drop: deck position tweens down faster than gravity. Player falls
  off the top via normal collision. No reparent needed.
- Reset: deck snaps back to base position. Collision is off during the
  invisible window, so the snap never pushes the player.

### Implementation
- Delete `_carried_body`, `_original_parent`, `_release_player()`,
  `_on_body_exited`.
- `_on_body_entered` only triggers the timeline; no reparent.
- The defensive evict-children loop in `_reset` becomes a no-op (drop it).
- `_enter_crumbling` no longer calls `_release_player()`.

### Smoke test
- Stand on crumble → shakes for 3s → falls → resets after 5s. Player
  free-falls under their own gravity from wherever they were when crumble
  started. No teleport. Walking off mid-shake leaves the deck cycle running
  to completion (no reparent to clean up).

---

## 2. Elevator platform — recolor + AnimatableBody3D rewrite

### Problem
The reparent trick fails on fast-descending platforms. CharacterBody3D's
`move_and_slide()` writes a new `global_position` each physics frame, which
Godot translates back to `local_position` on a parented node — so the
local offset to the deck drifts under gravity. On ascent the deck presses
into the player (collision resolves, grounded). On descent the deck pulls
away faster than gravity can catch them, drift accumulates, `is_on_floor()`
flips false, the player falls off mid-ride.

### Fix
**Replace deck collision with `AnimatableBody3D`** — Godot 4's official
kinematic moving-platform type. CharacterBody3D's `get_platform_velocity()`
naturally inherits an AnimatableBody3D's per-frame velocity, so the body
rides without any reparent trick at all. Deletes the entire CarryZone +
reparent + restore-parent path.

### New scene structure

```
ElevatorPlatform (Node3D, elevator_platform.gd)
└── Deck (AnimatableBody3D, sync_to_physics = true)
    ├── Visual (CSGBox3D, use_collision = false)  # platform shader, no collision
    └── CollisionShape3D (BoxShape3D)              # the actual collider
```

CarryZone removed entirely.

### Implementation notes
- `_deck` becomes the AnimatableBody3D instead of a Node3D wrapper.
- Movement code unchanged — still `_deck.position.y = _base_y + _offset()`.
  AnimatableBody3D + `sync_to_physics = true` + setting position from
  `_process` (or `_physics_process`) is the supported pattern; the engine
  derives the platform's velocity from the position delta and exposes it
  via `get_platform_velocity()` to bodies standing on it.
- `_apply_size()` resizes both the visual CSGBox3D and the BoxShape3D in
  the CollisionShape3D child.
- Delete: `_carry_zone`, `_carry_shape`, `_original_player_parent`,
  `_on_carry_body_entered`, `_on_carry_body_exited`. None of the reparent
  logic survives.

### Recolor (the original §2 task)
Default `palette_highlight` flips from yellow `(1.0, 0.82, 0.08)` to teal
`(0.05, 0.85, 0.85)` (or thereabouts — tune to taste). `palette_base` stays
dark warm. The hub elevator instance in `level/hub.tscn` doesn't override
colors, so it inherits the new teal automatically.

### Smoke test
- Hub elevator: ride it from the bottom → reach top, deck pauses, deck
  descends. Player stays glued to the deck the entire descent (no
  mid-ride fall). Reads teal not yellow.
- Walk off the side mid-ride: player falls under gravity normally. No
  stale reparent state to clean up.

### Bouncy stays as-is
Bouncy's squash + spring is too brief (~0.6s total) to hit the descent-drift
problem. Reparent trick keeps working there. Don't touch.

---

## 3. Faction system (shared plumbing)

The portal/control/hack mechanics all hinge on a pawn changing **whose side
it's on** at runtime. Today this is a binary `@export var pawn_group:
String = "player"` on `PlayerBody`, set once in `_ready` via `add_to_group`.
Need to expand to three states with runtime transitions.

### States

| Faction      | Group         | Hits (attack_target_groups)                    | Tint  |
|--------------|---------------|------------------------------------------------|-------|
| `player`     | `player`      | `enemies` ∪ `splice_enemies` ∪ `allies`        | none  |
| `green`      | `enemies`     | `player` ∪ `allies`                            | none  |
| `red`        | `splice_enemies` | `player` ∪ `allies`                         | red   |
| `gold`       | `allies`      | `enemies` ∪ `splice_enemies`                   | gold  |

`splice_enemies` is its own group rather than a sub-tag of `enemies`
because allies need to target it AND the player needs to target it AND green
enemies should NOT target it (they're independent factions, not splice's).

**Player can punch allies.** The user can swing on a friendly gold pawn and
kill it — by design, so you can clean up after a hack mistake or thin a
crowd that's clogging your route. That's why `player`'s target groups
include `allies` (the only faction that hits its "own side"; allies don't
hit each other).

### API on PlayerBody

```gdscript
@export var attack_target_groups: Array[StringName] = [&"enemies"]
func set_faction(faction: StringName) -> void
```

`attack_target_group: String` (existing single-slot) becomes
`attack_target_groups: Array[StringName]`. `_sweep_attack()` iterates the
array and unions the hit candidates (deduped). Existing enemy variants set
the array to `[&"player", &"allies"]` — punchy migration but mechanical.

`set_faction()` encapsulates: leave old group(s), join new group(s), rewrite
`attack_target_groups` from the table above, retarget the EnemyAIBrain
(`target_group` → `target_groups: Array[StringName]`), retint the skin
(§4), emit `Events.faction_changed(self, faction)`. Single public entry
point so everything that wants to flip a pawn calls one method.

Brains: PlayerBrain ignores groups (input-driven). EnemyAIBrain's
detection sweep iterates `target_groups` and unions candidates — same
pattern as PlayerBody's attack sweep.

### Initial faction at spawn
Existing `pawn_group = "enemies"` on enemy variants becomes
`@export var faction: StringName = &"green"` set per scene. `_ready` calls
`set_faction(faction)` once to install groups + targets + tint.

### Persistence
Faction does NOT persist in saves. Hub respawns reset enemies to authored
faction. Mid-level conversions are session-only — designed so the player
can't trivialize a level by hacking once and reloading.

---

## 4. Skin tinting

Already half-built: KayKit skin's `death_glitch.gdshader` is a
`material_overlay` shader that takes a `damage_color` uniform. We extend
the same overlay shader with a persistent tint slot:

```glsl
uniform vec3  faction_tint   : source_color = vec3(1.0, 1.0, 1.0);
uniform float faction_amount : hint_range(0.0, 1.0) = 0.0;
```

In `fragment()`, the tint composites onto ALBEDO at `faction_amount` after
the damage-flush + glitch passes. `faction_amount = 0` = vanilla skin.

### CharacterSkin contract
Adds:
```gdscript
func set_faction_tint(color: Color, amount: float) -> void
```

KayKit implements via `_glitch_overlay.set_shader_parameter(...)`. Sophia
and cop_riot can no-op (faction tint not visible on those — they're
narrative-locked skins). New skins that ship with red/gold variants
implement properly.

### Faction → tint table

| Faction | Color                 | Amount |
|---------|-----------------------|--------|
| green   | `(1, 1, 1)`           | 0.0    |
| red     | `(1.0, 0.18, 0.12)`   | 0.55   |
| gold    | `(1.0, 0.78, 0.10)`   | 0.55   |

`PlayerBody.set_faction()` looks these up and calls the skin's setter.

---

## 5. Portal platform (pink, paired)

### Visual
Two `Node3D` instances in the level, each with a `link_id: StringName`
matching its partner. Same-id pairs are linked at `_ready` via a static
class-level dict (first to ready stores itself, second finds and links to
first). Pink defaults (`palette_highlight = (0.95, 0.35, 0.85)`).

### Behavior
On `body_entered` for `player`:
1. Lock input on the player (set `_betrayal_walk_dir`-style lockout, or a
   new `set_portal_locked(true)` method on PlayerBody that ignores Intent).
2. Play warp sfx (one-shot 3D, deck-positioned).
3. Fire glitch overlay on the player skin (`set_glitch_progress` ramped
   to 1.0 over `slide_in_duration`).
4. Tween player position **down** by `slide_depth` over
   `slide_in_duration` (0.25s default). Elastic ease for the squelch feel.
5. At slide-in finish: instantly teleport player to the linked portal's
   position (still `slide_depth` below ground at that location), fire warp
   sfx on linked portal, glitch stays at 1.0.
6. Tween player position **up** to linked portal's deck-top over
   `slide_out_duration` (0.25s). Elastic ease.
7. Restore input, ramp glitch back to 0 over `glitch_fade` (0.3s).

Total: ~0.5s door-to-door, tunable. Reads as "fall through, pop out
elsewhere."

### Implementation

`level/interactable/portal_platform/portal_platform.gd`:

```gdscript
@export var link_id: StringName
@export var palette_base: Color
@export var palette_highlight: Color = Color(0.95, 0.35, 0.85)
@export var slide_depth: float = 1.5
@export var slide_in_duration: float = 0.25
@export var slide_out_duration: float = 0.25
@export var glitch_fade: float = 0.3
@export var warp_sound: AudioStream

static var _registry: Dictionary = {}  # link_id → PortalPlatform

func _ready():
    if _registry.has(link_id):
        # second instance — pair up
        var partner: PortalPlatform = _registry[link_id]
        ...
    else:
        _registry[link_id] = self

func _on_body_entered(body):
    if not body.is_in_group("player"): return
    if _is_warping or partner == null: return
    _warp(body)
```

### Edge cases
- Solo portal (no partner): warn and no-op. Don't crash.
- Re-entering source mid-warp: gated by `_is_warping` flag, ignored.
- Player exits at partner: partner sets a brief cooldown so the just-warped
  player isn't immediately re-warped.

### Smoke test
Drop two portals with matching `link_id` in a level. Walk onto one — fade,
warp sound, slide down + up, end up on the partner with input restored.

---

## 6. Control portal (grey → yellow → ally conversion)

### Visual
Single `Node3D` with the platforms shader. Default palette grey
`(0.4, 0.4, 0.42)`. On activation, palette tweens to yellow
`(1.0, 0.85, 0.10)` over `activate_duration` (0.5s).

### Conversion is zone-wired, not radial-from-portal

The portal scene includes a child `ConvertZone: Area3D` that the level
designer **shapes and positions in the editor** to cover whatever room /
courtyard / corridor the portal controls. Could be 5m × 5m or 30m × 50m —
the level decides. No radius export; the Area3D's collision shape is the
source of truth.

On activation, the portal calls `_convert_zone.get_overlapping_bodies()`
once. Every PlayerBody in there with faction in `target_factions` flips
to `gold`. That's the entire conversion step — no per-frame polling, no
distance math. Pawns wandering into the zone *after* activation are NOT
auto-converted; conversion is a one-shot on activate.

### Behavior
On `body_entered` for `player`:
1. If already activated, return (one-shot).
2. Tween palette grey → yellow.
3. Play activation sfx.
4. Enumerate `_convert_zone.get_overlapping_bodies()`.
5. For each PlayerBody matching `target_factions` (default `[&"green",
   &"splice_enemies"]`), call `pawn.set_faction(&"gold")`.

### Ally AI behavior — stop-and-idle follow

Allies use a stripped-down behavior loop:

| Situation                                              | Action                                |
|--------------------------------------------------------|---------------------------------------|
| Enemy in detection radius                              | Chase + attack (existing AI)          |
| No enemy in range, distance to player > `follow_distance` | Walk toward player                 |
| No enemy in range, distance to player ≤ `follow_distance` | Idle in place                      |

`follow_distance` defaults to **3.0m** (tunable), so allies park ~3m from
the player and idle until either an enemy shows up or the player walks
away. No leash physics — if they fall off a cliff or get stuck on
geometry, they're stuck. Player can swing on them to clean up.

### Implementation

`EnemyAIBrain` gets one new export and a small state addition:

```gdscript
@export var follow_subject_group: StringName = &""
@export var follow_distance: float = 3.0
```

When `follow_subject_group` is non-empty AND no target is in detection
range, the brain's wander pick replaces with: `if dist_to_subject >
follow_distance: walk toward subject; else: idle (zero intent)`. That's
~10 lines added to the existing wander branch.

`PlayerBody.set_faction(&"gold")` writes
`brain.follow_subject_group = &"player"`. Other factions write `&""`.

### Control portal scene structure

```
ControlPortal (Node3D, control_portal.gd)
├── Deck (Node3D)
│   └── Box (CSGBox3D, platforms shader)
├── CarryZone (Area3D)         # detects player standing on portal
│   └── Shape (CollisionShape3D)
└── ConvertZone (Area3D)       # designer-shaped: who gets converted
    └── Shape (CollisionShape3D)  # box, sphere, or polygon as needed
```

Exports:
```gdscript
@export var palette_base: Color
@export var palette_highlight: Color = Color(0.4, 0.4, 0.42)  # grey idle
@export var palette_active: Color = Color(1.0, 0.85, 0.10)    # yellow active
@export var target_factions: Array[StringName] = [&"green", &"splice_enemies"]
@export var activation_sound: AudioStream
@export var activate_duration: float = 0.5
```

### Rollerblades for converted enemies
"Gives them rollerblades" = on conversion, set
`pawn._current_profile = pawn.skate_profile` (already supported). Their
movement profile shifts; their skin's `set_skate_mode(true)` shows wheels
if the skin supports it. KayKit skin currently doesn't have wheels —
**deferred** as listed in §9.

### Smoke test
Drop a control portal next to a room with 2-3 KayKit enemies; size the
ConvertZone to overlap the room. Step on the portal → palette flips
yellow → enemies tint gold + park ~3m from you when there's nothing to
fight + chase any green/red that wanders in. Punch one of them with
attack — it dies (friendly fire confirmed).

---

## 7. Hacking-driven splice→normal conversion (level 2)

Level 2's `HackTerminal` already exists in `level/level_2.tscn`. Today it
sets a flag (`l2_hack_terminal`) that opens a door. We add a side effect:

Same zone-wired pattern as the control portal. The terminal scene gets a
`ConvertZone: Area3D` child the designer shapes per-level. On hack
success, enumerate `_convert_zone.get_overlapping_bodies()` and flip every
red pawn in it to green.

### Implementation
`HackTerminal` already emits a "completed" signal / sets a flag. Add the
ConvertZone child + an export:

```gdscript
@export var target_factions: Array[StringName] = [&"splice_enemies"]
@export var resulting_faction: StringName = &"green"

# on hack success:
for pawn in _convert_zone.get_overlapping_bodies():
    if not pawn is PlayerBody: continue
    if pawn.faction not in target_factions: continue
    pawn.set_faction(resulting_faction)
```

Reuses §3 plumbing entirely + the same zone pattern from §6 — no new
mechanic, just a different trigger.

### Smoke test
Place red enemies in L2 → hack terminal → enemies tint green and stop
attacking the player.

---

## 8. Build order

Each step has a smoke-test gate. Don't merge multiple at once.

1. **Crumble parenting fix** (§1). Pure deletion. Quick win, low risk.
2. **Elevator AnimatableBody3D rewrite + teal recolor** (§2). Structural
   change — bigger than the original "one-line teal" task. New scene
   layout, deletion of reparent code path. Smoke-tested against the hub
   elevator's full up/down cycle. Worth doing standalone before stacking
   anything on top.
3. **Faction system on PlayerBody** (§3). No visible behavior change yet —
   `set_faction("green")` for green enemies is a no-op transition. Verify
   existing combat still works.
4. **Skin tinting** (§4). Visible: spawn enemies with `red` or `gold`
   faction in a debug scene, confirm tints. No behavior change.
5. **Hacking conversion** (§7). First user of the faction system — easiest
   to test because the trigger is deterministic (press E on terminal).
6. **Control portal** (§6). Builds on §3+§4+§7 plumbing; new pieces are
   the zone-wired conversion + ally stop-and-idle follow.
7. **Portal pair** (§5). Independent of the faction system — could ship in
   parallel. Lands last because it has the most visual polish surface
   (slide tween, glitch ramp, warp sfx).

---

## 9. Out of scope (explicitly)

- Persistent faction (saves don't carry conversions across reloads).
- Leashed allies (they wander/follow but can't be recalled).
- Visual rollerblades on converted gold KayKits (skin doesn't have them;
  movement profile flips but the wheels won't show until the skin gets a
  rig update).
- Splice "re-conversion" (red enemies that were hacked green can't be
  re-flipped to red — the level resets that on respawn).
- Multi-tier factions (no "blue" / "purple" beyond what's listed). Adding
  one is just a new entry in the table + a tint color.
