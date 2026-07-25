# The Nav Stack — pawn platform architecture

Status: **active build-out** (sandbox-proven, pre-port). Owner doc for the
clean-room AI rebuild. Read this before touching `player/brains/nav_*.gd`,
`enemy/nav_dummy_body.gd`, `level/nav/`, or `tools/bake_nav.sh`.

---

## Thesis

Every creature — enemy, ally, dog, future anything — is a **point in a
configuration space**, not a class. Four independent axes, each swappable
without touching the others:

```
OFFLINE  bake pipeline   navmesh + auto-links → sidecar .res    "where can things go"
DECIDE   NavBrain        awareness, states, destinations, speed  WHAT and WHY
PLAN     NavSteering     agent paths, link jumps, safety holds   HOW to get there
ACT      body            physics, Intent consumption             muscles
LOOK     CharacterSkin   visuals, animation                      clothes
```

The old `EnemyAIBrain` (2,809 lines) grew by accretion — every creature
added conditionals to one class. The new stack grows by **composition** —
every addition lands in exactly **one** layer. If a change wants to touch
two layers, the design is wrong; stop and re-cut the seam.

**Interfaces are deliberately tiny:**
- brain → steering: `steer_to(body, dest, arrive) -> Vector3` + `consume_jump()`
- steering → body: the existing `Intent` (via the brain filling it)
- body → skin: the existing `CharacterSkin` contract (`idle/move/jump/fall/…`)
- world → steering: NavigationServer (baked mesh + `NavigationLink3D`s)

## Files

| Layer | File | Notes |
|---|---|---|
| bake | `level/nav/nav_region_bake.gd` | `@tool`; editor `bake_now` button + `-- --nav-bake` pipeline mode; auto-link generation |
| bake | `level/nav/nav_bake_result.gd` | sidecar Resource: mesh + link table |
| bake | `tools/bake_nav.sh` | the command; add levels to `LEVELS` |
| bake | `level/nav/baked/<level>.res` | artifacts; **only** thing the bake writes |
| decide | `player/brains/nav_brain.gd` | `NavBrain` |
| decide (senses) | `player/brains/nav_perception.gd` | `NavPerception` (RefCounted): sight cone + hearing×loudness + suspicion accumulator + LKP + `notify()` stimuli. suspect_time=0 collapses to the binary v3 model (parity by preset) |
| plan | `player/brains/nav_steering.gd` | `NavSteering` (RefCounted) |
| look | `player/brains/nav_cone_visual.gd` | `NavConeVisual`: optional, tunable cone renderer reading `perception_view()` — STRICTLY read-only, toggling can't affect behavior |
| act (sandbox) | `enemy/nav_dummy_body.gd` + `enemy/enemy_nav_dummy.tscn` | independent test body — **never ships**; ship body is PlayerBody |
| look | `player/skins/cylinder/cylinder_skin.tscn` | debug skin; any CharacterSkin drops in |
| sandbox | `level/nav_test.tscn` | F10 round-trip (`game.gd`, editor-only) |
| test | `tests/test_nav_brain.gd` | awareness/steer/arrive + suspect/alert contract |
| test | `tests/test_nav_perception.gd` | accumulator/cone/hearing/stimulus contract (pure logic, no physics) |

Game-side listeners (NOT stack — this game's mapping of stack signals):
`enemy/alert_tint.gd` (suspicion → skin tint), PlayerBody's
`aggressive_while_chasing` connect (state_changed → buffs), `noise_loudness()`
(crouch = silent), and set_faction's guarded cone/patrol shed pokes.

## Growth recipe — one home per addition

- **New behavior** (follow, attack, suspect, flee): export group + state in
  **NavBrain**. Nothing below changes.
- **New traversal** (ladder, glide, grind): link annotation at **bake** +
  dispatch case in **NavSteering** + verb on the **body**. Brain never
  learns it exists.
- **New creature shape**: **skin** scene + body numbers. Brain/steering
  unchanged.
- **New archetype**: a preset `.tscn` of NavBrain exports (pattern:
  `enemy/brains/*.tscn`).

### Capability bits (BUILT — first consumers: skating reds + skating golds)

Godot navigation layers are the mechanism: links carry `navigation_layers`
bits, each pawn's agent carries its capability mask, and A* simply never
plans through links the pawn can't do. Constants: `level/nav/nav_layers.gd`
(WALK=1, SKATE_JUMP=2, WALK_AND_SKATE=3). The bake tags each link by tier
(`max_link_horizontal` = walk envelope, `skate_link_horizontal` = 14m skate
envelope); the sidecar carries `link_layers`. Agent masks: static in the
variant tscn (splice nav reds ship mask 3) AND runtime-synced by PlayerBody
`_sync_nav_capability_mask()` on every walk/skate profile switch — a GOD-
blast gold given rollerblades replans through skate links automatically.
Jump strength is a bucket, never a per-creature mesh: apex is speed-
independent, so tiers only widen HORIZONTAL reach. Future verbs (ladder,
grind, grapple) claim the next bits.

### The envelope contract (important coupling, keep it explicit)

Link generation thresholds (`max_link_horizontal`, `max_jump_up`,
`max_drop`) are a function of the pawn's jump physics:
`reach = (max_speed + jump_horizontal_boost) × 2·jump_impulse / gravity`,
`apex = jump_impulse² / 2·gravity` (gravity = 30, matching PlayerBody).
Today these are hand-synced between the dummy and the bake exports. When
multiple body configs share a level, derive tiers from the weakest/strongest
envelopes — candidate future home: `MovementProfile` carries its envelope.

## Current state (v3 — "regular kaykit" nav layer)

- WANDER: unaware. Destinations random-picked and **snapped to the
  navmesh** — cannot stray off an edge, zero probe raycasts. Slow (0.33).
- CHASE: aware. Awareness model: **"radius acquires, sight sustains, time
  forgets"** — detection sphere (24m) + LOS ray to acquire; once locked,
  distance is irrelevant (long route detours never cause forgetting);
  losing the sense for `chase_memory_duration` (6s) forgets. A* over mesh +
  links; jump on `link_reached`.
- Safety rules (all bug-derived, all proven by logs): no path → **hold,
  never beeline**; teleport (>5m/tick) → forced repath; path requests
  Y-nudged so identical-value setters can't silently keep stale paths.
- Kill-plane recovery: body self-detects `y < kill_y`, respawns beside
  nearest `phone_booths`-group node (else spawn point).
- Targeting is **multi-group**: `target_groups: Array[StringName]`,
  nearest member across all groups wins. Plural deliberately matches
  PlayerBody.set_faction's guarded `"target_groups" in _brain` write, so
  runtime faction conversion retargets a NavBrain with zero faction
  knowledge in the stack (the game knows the stack; never the reverse).
- Awareness is **per-relationship**, and follow is NOT a separate layer:
  ally follow = the `omniscient` toggle skipping detection gating (v2 of
  the brain was exactly this, and it worked). A preset, not a subsystem.
  Three-zone hysteresis / personal-space push from the old brain only get
  built if arrive_distance + bump physics visibly fails. KISS.

Workflow: edit geometry → `./tools/bake_nav.sh` (or `bake_now` checkbox) →
F10 in. Debug: navmesh/link/path draw is on in the sandbox; `[nav]` logs
are deduped state transitions (debugging protocol: log changes, never ticks).

## Edge cases

**Handled:** map-sync latency at load; stale path after respawn; identical-
target-setter no-op; navmesh floating ~0.5m above floor (acceptance radius
1.5 > offset + turning circle v/turn_rate ≈ 0.42m); walk/skate profile
identity check eating AI jumps (never point both at one .tres); mid-jump
knockoff (lands → repaths from wherever — self-healing); route detours
dropping the target (give-up is time-since-sensed, never distance); stale
queued link-jumps firing seconds late near edges (500ms TTL in NavSteering).

**NOT yet handled — known, prioritized:**
1. **Damage doesn't wake the pawn.** Shot from behind outside detection →
   it doesn't react. Needs `aggro_to(attacker)` API (old brain has one).
   *Must land with the attack layer.*
2. **No last-known-position.** During LOS grace the brain steers at the
   target's TRUE position (mild wallhack); on drop it forgets instantly.
   Proper: LKP + search behavior.
3. **Wander is untethered.** Radius is around the *current* position → a
   random walk migrates across the map over minutes. Needs a home anchor.
4. **Vertical arrive.** Arrive check is horizontal-only: target directly
   overhead reads as "arrived" (pawn parks underneath). Fine pre-combat;
   the attack layer must add vertical range (learned lesson — see
   CLAUDE.md anti-patterns).
5. **No crowd behavior.** Agent avoidance off; multiple pawns pile and
   contest links. Wire RVO (`avoidance_enabled` + `velocity_computed`) +
  target claims when >1 pawn hunts.
6. **No perf governance.** Old brain has tick LOD / anim LOD / offscreen
   pause. Required before porting swarms; design as a shared PerfGovernor,
   not per-brain code.
7. **LOS blocked by other pawns.** The sight ray has no collision mask —
   an enemy standing between "blocks vision." Maybe desired; decide and
   mask explicitly.
8. **Stale sidecar.** Geometry edits need a rebake; no staleness detection.
   Symptom: pawn ignores new platforms. Fix is always "run the bake."
9. **Dynamic geometry.** Elevators, glitch platforms, runtime city — not
   in the offline bake, by design. Moving-platform traversal = dynamic
   link toggling, deliberately out of scope for now.
10. **kill_y / respawn placement are per-level numbers.** Deep levels and
    narrow platforms need per-instance tuning (booth offset can push off
    edge).
11. **Unreachable-forever.** Pawn holds at closest reachable point with no
    give-up timer (no "return home / despawn" watchdog yet).
12. **Fence-hop links.** Link LOS ray runs at 1.2m; a low fence between
    islands under the ray → link generated; jump apex usually clears —
    verify visually on new geometry.

## Migration map — where the old code's features land

Reviewed: `enemy_ai_brain.gd` (2,809 lines) + pawn-relevant `player_body.gd`.
Verdict per feature cluster:

### EnemyAIBrain → new stack

| Feature (lines ≈) | Destination | Notes |
|---|---|---|
| Detection sphere + LOS + hysteresis | **DONE** — NavBrain v3 | numbers preserved |
| Wander + curiosity | **DONE** (better) | navmesh-snap replaces ledge probes |
| Vision cone (slices, crouch mods, debug fan) | future **NavPerception** component | perception deserves its own class beside NavSteering; visual fan = separate debug node reading it |
| 4-phase alert (CALM/SUSPECT/HOSTILE/ALERT) | NavBrain states + perception accumulator | suspect timer = awareness accumulator, per AAA pattern |
| Attack (range/cooldown/wind-up/vertical) | NavBrain **ATTACK layer** | brain fires `attack_pressed`; body keeps the swing |
| Follow 3-zone + personal space + crouch pause | `omniscient` toggle preset | follow = chase without detection gating; zones only if bump physics proves insufficient |
| Faction targeting table / `set_faction` rewiring | config, not brain | factions set `target_group`/`follow_subject_group` exports at runtime |
| Ally target claims (static registry) | future shared **Blackboard** | also carries LKP when built |
| `aggro_to` (damage → instant aggro) | NavBrain public API | edge case #1; port with attack layer |
| Rail follow (NavTrail steering) | **bake + NavSteering** | rails become grind-annotated links; traversal verb on body |
| Waypoint graph (K-NN, BFS, elevation pick) | **RETIRED** | navmesh + links replaces it wholesale |
| Ledge probes / `_has_ground_ahead` sweep | **RETIRED** for nav | navmesh constrains by construction; body may keep one last-resort ray |
| DUMB/SMART jump + arc validation + drop probes | **RETIRED at runtime** | the arc math already moved to bake-time link generation |
| Stuck escape (Bug algorithm + local grid BFS) | mostly RETIRED | navmesh kills the deadlock class; keep a thin "no displacement → repath/report" watchdog in NavSteering |
| Tick LOD + anim LOD + offscreen pause | shared **PerfGovernor** on body | edge case #6; build once, both brains could use it during transition |
| Hack freeze (`set_hack_active`) | NavBrain external CONTROL state | generalize: any system can push "frozen/stunned" |
| Aggressive buffs flip | body stat module reacting to brain signal | brain emits `state_changed`; never applies buffs itself |
| Phase-change sounds / debug label (F3) | audio + debug components subscribing to brain signals | brain prints/plays nothing itself long-term |

### PlayerBody (pawn-relevant) → unchanged home, one decision locked

**The ship body is PlayerBody.** `NavDummyBody` is sandbox-only scaffolding.
NavBrain already speaks the Brain/Intent contract, so the port is: swap a
variant's `brain_scene` to a NavBrain preset — body, skins, factions,
death/ragdoll, attack sweep, contact bumps, camera, save all stay where
they are. NavBrain must therefore never depend on NavDummyBody specifics
(it doesn't — everything is duck-typed: `is_on_floor`, children lookup).
One PlayerBody item to fix at port time: the walk/skate profile identity
check that eats brain jumps (`disable_brain_jump_on_skates`) triggers when
both profiles point at one .tres — configs must keep them distinct.

## Build plan — next pieces: shape / isolation test / tuning

Ordered; each is one small PR-sized change to exactly one layer.

1. ✅ **Follow (ally preset)** — `omniscient: bool` skips detection AND
   forgetting. Tested. (Preset tscn still to author when an ally ships.)
2. ✅ **Attack** — attack_range/vertical/cooldown fire `attack_pressed`;
   vertical range restores jump-dodge. Tested (fires once, cooldown gates,
   overhead never fires). No wind-up in v1. Dummy body consumes the edge
   by calling skin.attack() (no damage in the sandbox).
3. ✅ **Aggro-on-hit** — `aggro_to(attacker)` bypasses senses for
   `aggro_grace` (4s); NavDummyBody.take_hit wires it (hits wake + shove,
   no damage). Tested.
4. ✅ **Hearing** — `hearing_radius` (8m): omnidirectional no-LOS sense
   inside `_senses()`. `_can_see()` extracted as the overridable perception
   seam (tests subclass to mock sight). Tested via BlindBrain. Noise
   EVENTS (skating/landing emit stimuli) still future.
5. ✅ **Crowds (RVO)** — agent `avoidance_enabled` + `velocity_computed`
   safe-velocity loop in NavSteering (one-frame lag; near-zero safe
   velocity = wait, don't shove). Gym: `level/nav_gym_crowd.tscn`, 8
   dummies. F10 now cycles the gym ring (nav_test → crowd → return).
6. ✅ **Perf** — `wander_tick_every` (4): wandering brains think every Nth
   physics frame with random stagger + delta accumulation; chase always
   full rate. Level-side culling: EnemyDistanceSleep node in the crowd gym
   (sleep 45m / wake 40m — dummies are in "enemies", works unmodified).
7. **Wander tether** — `_home` captured on first tick; wander picks around
   home. Test: 600-frame boot, final pos within radius+slack of spawn.
8. **LKP** — freeze last-seen position on sense break; steer there during
   memory; arriving without reacquire = drop (that IS the v1 search).
   `_can_see()` seam already in place.

**Tuning workflow:** every number is an export on its owning layer. Live:
F10 → editor Remote scene tree → select the pawn → drag brain/agent sliders
mid-chase → bank good values into the preset tscn.

## Port procedure (per archetype, when parity reached)

1. Preset the NavBrain exports to the archetype's numbers (wrapper tscn).
2. Bake the target level (`NavRegion` + AABB + `bake_nav.sh` entry).
3. Add a `NavigationAgent3D` child on that variant, swap `brain_scene`.
4. A/B in the level; old brain preset is one inspector revert away.
5. When all variants of a feature are ported, delete the old code path.

## Port status

| Archetype | Preset | Body variant | Live in |
|---|---|---|---|
| green | `enemy/brains/nav_green.tscn` | `enemy/enemy_kaykit_nav.tscn` | level_1 (placed + spawners), levels 2/3/4 (placed + spawners) |
| red (walking) | `enemy/brains/nav_red.tscn` | `enemy/enemy_kaykit_red_nav.tscn` | level_2 (13 placed; speed jitter 1.8–2.8) |
| red (skating) | `nav_red.tscn` | `enemy/enemy_kaykit_splice_nav.tscn` (agent mask 3 — SKATE tier) | level_3 (9 placed, idle-brain set-pieces keep their per-node override; 3 spawners), level_4 (51 placed + 1 spawner) |
| gold (ally) | `enemy/brains/nav_gold.tscn` | conversion product (set_faction pokes) | GOD blast / portals; FOLLOW state + follow_subject_group live |
| stealth | `enemy/brains/nav_stealth.tscn` | `enemy/enemy_kaykit_stealth_nav.tscn` | level_2 (8 placed). Cone 100°/45m + vertical ±1m, suspect_time 1.2, ARC_SCAN patrol, alerts 18m on splice_enemies, cone visual + alert tint children |

Build-plan #8 (LKP) landed with the perception integration: chase steers at
last-known position while unsensed; SUSPECT investigates the LKP and drops
on arrival/no-route (suspicion holds during a live investigation — decay is
sense memory, not intent). FOLLOW (`follow_subject_group` + follow_distance)
landed with the levels-3/4 port — set_faction's guarded poke now lights up
for nav pawns, so gold conversion = retarget + follow with zero brain code.
NavSteering honors the `jump_inhibit_count` refcounted meta (generic
convention; this game's boss-arena ConvertZones set it). The nav_test
`_probe_path` diagnostic is stripped (sandbox stabilized).
Known deferrals: legacy stealth's crouch-triggered ally-filter (build when
gold-vs-sentinel interplay is exercised); "skate" as the tier-2 name is
game-flavored — rename to STRONG_JUMP if the stack ships to another game.

Red parity note: the body's aggressive package (`set_aggressive_buffs`)
pokes `attack_cooldown` / `wind_up_duration` by name — NavBrain exposes
both, so red buff timing applies to nav pawns unmodified. Gold conversion
retargets nav pawns via `target_groups`; gold FOLLOW behavior
(`follow_subject_group`) is not yet a NavBrain concept — lands with the
ally preset.
