# CLAUDE.md — Hack The Planet

Working instructions for Claude on this project. Read this first, every session.

---

## What this is

A Godot 4.6 third-person skate platformer. Target: **AAA-level indie feel**, single-developer pace, shippable. Mario-level polish is the north star — small scope, deep tuning, no ugly corners.

Core gameplay loop: skate / jump / grind / wall-ride through an urban level, evade cop-style enemies, hit checkpoints, reach a flag. Interactables (doors, dialogue, puzzles) and audio ducking come next (see `docs/interactables.md`).

---

## Mindset: Jonathan Blow, applied

- **Understand before you build.** State back the problem in one sentence before writing code. If the one-sentence version reveals you don't know the problem, ask.
- **Use primary sources.** Godot 4.6 docs, the actual GDScript behavior, the files in this repo. Don't invent patterns from LLM intuition. When referencing an engine feature, cite the file or doc page you read.
- **Small fixes beat big refactors.** A one-line guard clause is the right fix for 90% of bugs. A 50-line restructure means you diagnosed wrong — re-read the logs.
- **YAGNI, hard.** No abstractions for hypothetical second consumers. No feature flags. No backwards-compat shims on code nobody else runs. No routing layers, managers, orchestrators unless there are three concrete call sites.
- **Duck-typing over inheritance hierarchies.** `has_method("take_hit")` beats a 4-level class tree when the contract is one method.
- **Silent failure is the enemy.** Missing sound? Log the cue name. Missing node? `push_error` with the path. Typoed group? Surface it, don't swallow.

Read `/Users/ryanhelsing/.claude/CLAUDE.md` for the debugging protocol — it's not optional. Never guess root cause; log first, diagnose from output, then write the small fix.

---

## Architecture: Brain / Body / Skin

**One pawn class drives everything** — player, enemy, companion, future remote peer. The body is dumb physics; the brain is the driver; the skin is the visual. Swap any of the three without touching the others.

```
PlayerBody (CharacterBody3D, universal)
├── [Brain subclass] (child, found by type not name)
│   ├── PlayerBrain    → reads Input + camera, writes Intent
│   ├── EnemyAIBrain   → reads world state, writes Intent
│   ├── ScriptedBrain  → replays a fixed Intent sequence (tests, cutscenes)
│   └── NetworkBrain   → replays remote peer's Intent (future)
├── [CharacterSkin subclass] (via @export var skin_scene: PackedScene)
│   ├── SophiaSkin     → AnimationTree-driven, full state machine
│   ├── CopRiotSkin    → simple AnimationPlayer wrapping a GLB
│   └── KayKitSkin     → KayKit mannequin + single anim pack
└── Camera rig + sounds + VFX (lives on the scene; AI variants set current=false)
```

**The `Intent` contract** (`player/body/intent.gd`) is the **only** data that flows brain→body each tick:

- `move_direction: Vector3` — world-space horizontal, magnitude [0, 1] fraction of max_speed
- `jump_pressed: bool` — edge-triggered
- `attack_pressed: bool` — edge-triggered

Adding a new pawn capability means extending Intent + wiring both the brain-fill side and the body-consume side. Never route input through any other path.

**Per-pawn config via `@export` on PlayerBody** — `skin_scene`, `brain_scene`, `pawn_group`, `attack_target_group`, `max_health`, `dies_permanently`, `walk_profile`, `skate_profile`. Variants (enemy_cop_riot.tscn, future NPCs) instance `player_body.tscn` and override these in the inspector. **Do not subclass PlayerBody. Do not create parallel body scripts.**

---

## Tuning is a first-class concern

The user iterates by tweaking numbers. Design for that.

- **Expose every feel-affecting value as `@export`.** Jump height, attack range, lean pivot, AI detection radius, chase speed fraction — all tunable without opening code.
- **Use `MovementProfile` resources for bundled tuning** — one `.tres` per archetype (player skate, player walk, enemy). Duplicate the resource file to create variants; don't hardcode a second set.
- **Per-character proportions live on the skin**, not on MovementProfile. `lean_pivot_height`, `body_center_y` are skin-local because Sophia and KayKit have different heights. When adding a new skin, set these in the scene.
- **When the user reports a feel issue** ("enemies too fast", "jumps dodge doesn't work"), find the export, surface the tradeoff, adjust. Don't invent new knobs unless the existing ones genuinely can't express the fix.

---

## Working style

1. **Prove understanding first.** In the user's words, "show that you are a great engineer and understand before proceeding." Before any non-trivial edit, state the root cause or design decision in one sentence. The user will redirect if wrong — cheap. Silent diving in is expensive.
2. **Small, verifiable steps.** Break work into steps that each have a smoke-test gate. The user has said explicitly: one step at a time. Mark steps done only when verified.
3. **Smoke-test as you go.** After any architectural change: `godot --headless --quit-after 120 2>&1 | grep -Ei "SCRIPT ERROR|Compile Error"`. Should return nothing. If it does, you're not done.
4. **Unit tests for pure logic.** `tests/test_intent.gd`, `test_player_brain.gd`, `test_*_skin_contract.gd` are the existing pattern. Add one per contract (new Brain subclass → new test). Run with `godot --headless --script res://tests/test_xxx.gd --quit`.
5. **Be honest about tech debt.** When shipping an MVP with a known gap (KayKit only has Idle_A, cop_riot has no jump animation, EnemyAI doesn't have wind-up phases), say so explicitly in the session summary. Don't hide it.
6. **Respect user edits.** When the system tells you a file was modified by the user, read the current state before editing — don't revert. If their edit breaks something, flag it and suggest a restoration, don't silently undo.

---

## Anti-patterns (learned the hard way this session)

- **Global `Events` signals broadcast to all listeners.** One enemy touching `KillPlane` killed every PlayerBody via shared subscription. Fix pattern: emit with the subject (`body`), filter at the handler (`if body != self: return`) or gate subscription at `_ready` (`if pawn_group == "player":`). Apply to all interactables: flag, kill plane, phone booth, etc.
- **Scoring by group membership without distinct groups.** Enemies defaulted to `pawn_group = "player"` because overrides got stripped; they started targeting each other. Explicit group config per variant is required.
- **Doubled inspector overrides in tscn.** Manual edits can append a property twice without Godot's parser complaining visibly. `max_health = 1; max_health = 1` silently misbehaves. Always `Read` the tscn after editing.
- **Using `%UniqueName` in the body for swappable parts.** `%SophiaSkin` was brittle once skin_scene replaced the child. Prefer type-based lookup (`_find_first_brain()`) for swappable slots.
- **Typed `@export var camera: Camera3D` with hand-written NodePath in tscn.** Doesn't resolve at runtime. Use `@export var camera_path: NodePath` + `get_node_or_null(path)` at `_ready`.
- **Horizontal-only range checks for ground combat.** Copied from drone-era code; meant jumping didn't dodge. Always include a vertical max-delta for melee range.
- **`class_name Skin`** — collides with Godot's native `Skin` (skeleton skinning). Use `CharacterSkin`. Check for native-class collisions before naming.

---

## Testing protocol

- `tests/` directory holds GDScript test scripts. Each extends `SceneTree`, runs assertions in `_init()`, calls `quit(0)` on pass / `quit(1)` on fail.
- Limitations: SceneTree-mode doesn't load autoloads. Tests that need `Events`, `GameState`, etc. must use the direct game-boot path (`godot --headless --quit-after N`) and grep the output for errors.
- Acceptance per feature: (a) existing tests still pass, (b) game boots for 120+ frames with no `SCRIPT ERROR`, (c) new test covers the new contract.
- Don't install GdUnit4 or other frameworks unless the test suite outgrows the plain-assertion style. Current scale doesn't need it.

---

## Current state of the refactor (2026-04-22)

**Done:**
- Intent contract + 3 Brain subclasses (PlayerBrain, EnemyAIBrain, ScriptedBrain).
- CharacterSkin contract + 3 skins (Sophia, cop_riot, KayKit).
- Unified PlayerBody used by player AND all enemies.
- Swap via inspector: `skin_scene`, `brain_scene`, `pawn_group`, `attack_target_group`, `max_health`, `dies_permanently`, `walk_profile`, `skate_profile`.
- Separate `enemy/enemy_profile.tres` for enemy speed tuning, independent of player.
- Legacy `enemy/enemy.gd` is retired from the level (no references) but files still exist on disk — safe to delete.
- Interactable signal filtering: kill_plane, flag, phone_booth, coin all gate on `is_in_group("player")`.
- Phone booth checkpoint has activation block: invisible by default, swaps to `glowing_green.tres` when active; one booth active at a time.
- Vertical attack dodge: jumping clears enemy swings.
- Test suite: 7 tests, all green.

**Pending / known gaps:**
- Enemies lack wind-up/slam attack phases (old enemy.gd feel). EnemyAIBrain just lunges via `_start_attack_jostle`. Port the state machine when combat feel needs it.
- KayKit skin only has `Idle_A`; move/jump/fall fall back to idle. Merge `Rig_Medium_MovementBasic.glb` animations via AnimationLibrary in Godot editor.
- Cop_riot skin only has `Riot_Idle` and `Riot_Run`; jump/fall/attack all fall back to Run.
- Camera rig still lives inside `player_body.tscn`. When split-screen or cinematic cameras arrive, extract to a `CameraRig` scene that attaches to the current local pawn.
- No post-respawn invulnerability. Dying near a checkpoint + enemy cluster = re-killed instantly.
- Interactables system (doors, dialogue, puzzles, audio ducking) — spec at `docs/interactables.md`. Not yet implemented.
- **Enemies inherit all of the player's power-ups.** Abilities live on PlayerBody and enemies share that body, so whatever the player owns, every enemy also has. Needs a per-pawn ownership gate (e.g., abilities check `pawn_group == "player"` or read from a per-pawn preset instead of `GameState.flags`). See `docs/character_next.md` §2.4 — design intent is per-enemy ability preset on the variant scene.

---

## When starting a new session

1. Read this file.
2. Read `docs/character_next.md` — character controller roadmap + power-up progression + new skin plans.
3. Read `sync_up.md` for the latest cross-dev decisions (boundaries, open asks, unresolved questions).
4. Read `docs/interactables.md` if touching interactables, `docs/menus.md` if touching UI/save/pause.
5. Check `git status` and recent commits — the user may have made edits between sessions.
6. If the user describes a bug, apply the debugging protocol from the global CLAUDE.md: logs before code.
7. Before non-trivial code changes: state the one-sentence design decision and wait for confirmation.
