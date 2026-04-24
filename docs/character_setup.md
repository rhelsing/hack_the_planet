# character_setup.md — Importing a new character skin

Precise, tested walkthrough for adding a new character skin to the Brain/Body/Skin system. Every path, node name, and field in this doc is grounded in the current codebase — don't paraphrase from memory, match names exactly.

Reference skins already in-tree, in order of complexity:
- `player/skins/cop_riot/` — minimal (2 clips: `Riot_Idle`, `Riot_Run`, all other states fall back).
- `player/skins/kaykit/` — full polish (multi-GLB merge, directional dash, variant cycling, damage overlay).
- `player/sophia_skin/` — original reference; uses a different wheel-attachment pattern (editable-instance BoneAttachment3Ds inside the rig). For *new* skins follow the cop_riot / KayKit pattern below — it avoids editable-instance tscn fiddliness.

Duplicate the closest existing skin folder, rename, and edit — don't build from a blank scene.

---

## 1. Architecture recap

A skin is:
- A `Node3D` that extends `CharacterSkin` (class in `player/skins/skin.gd`).
- Swapped into `PlayerBody` via its `@export var skin_scene: PackedScene`.
- Driven by the body each tick via method calls (`idle() / move() / jump() / ...`) and transform rewrites. **The body overwrites `_skin.transform` every physics tick from yaw+pitch+roll and bakes in `uniform_scale`** — anything you set on the skin root's transform in the tscn is wiped. Per-skin scale goes on `uniform_scale`, not the root transform. (`player/body/player_body.gd:706–718`)

---

## 2. Required scene structure

Exact node names — the scripts look these up by literal strings.

```
<SkinRoot>  (Node3D, script extends CharacterSkin)
├── Model               ← PackedScene instance of the rig GLB (name MUST be "Model")
└── AnimationTree       ← AnimationTree, unique_name_in_owner = true
    (anim_player = NodePath("../Model/AnimationPlayer"))
    (root_node   = NodePath("%AnimationTree/../Model"))
    (tree_root   = AnimationNodeBlendTree containing a "StateMachine" node)
```

Optional, if the skin has rollerblade wheels:

```
<SkinRoot>
├── Model
├── WheelsLeft          ← Node3D, child at skin root (not inside Model)
│   └── RollerbladeWheels  (instance of player/rollerblade_wheels.tscn)
├── WheelsRight         ← Node3D
│   └── RollerbladeWheels
└── AnimationTree
```

Required for any skin that should leave a dust trail:

```
<SkinRoot>
├── ...
└── DustParticles       ← GPUParticles3D, unique_name_in_owner = true
    (process_material = library/fx/dust_particles.tres)
    (draw_pass_1      = library/fx/dust_sphere.tres)
    (transform: position ~(0, 0.137, 1.0) — roughly one unit behind the heels
     in skin-local +Z. Drag in the viewport to fine-tune per rig.)
```

Why `Model` specifically: `set_skate_mode(active)` calls `get_node_or_null("Model")` to toggle the skate Y lift (`kaykit_skin.gd:265`, `cop_riot_skin.gd:107`).

Why `WheelsLeft` / `WheelsRight` specifically: the `@onready var _wheels_left: Node3D = $WheelsLeft` lookup in each skin script. At `_ready`, the script reparents them under runtime-created `BoneAttachment3D`s bound to the foot bones, keeping global transform — so whatever you drag to in the viewport is preserved.

Why `DustParticles` specifically and at the skin root: the skin's yaw is rewritten by `PlayerBody` each tick to face the movement direction, so a dust emitter at skin-local `+Z` automatically trails behind as the character turns — no per-frame repositioning needed. `PlayerBody` computes the emit boolean (ground + speed + not-crouching) and calls `_skin.set_dust_emitting(enabled)`; each skin pipes the bool through to `%DustParticles.emitting`. Skins without dust inherit the `CharacterSkin.set_dust_emitting` no-op.

---

## 3. CharacterSkin contract

Methods defined in `player/skins/skin.gd`. All have no-op defaults — override only what your rig can animate. Everything unimplemented silently does nothing and the body keeps working.

| Method | When body calls it |
|---|---|
| `idle()` | grounded + zero horizontal speed |
| `move()` | grounded + moving |
| `jump()` | edge: just-jumped or air-jumped |
| `fall()` | airborne + `velocity.y < 0` |
| `edge_grab()` | legacy hook (not wired currently) |
| `wall_slide()` | wall-ride begins |
| `attack()` | on `attack_pressed` intent |
| `dash(direction)` | on `dash_pressed` intent (direction = world-space horizontal dash vector) |
| `crouch(active)` | on crouch press AND release (edge-triggered, both directions) |
| `die()` | start of death sequence |
| `land()` | first frame of airborne→grounded |
| `on_hit()` | each damage application via `take_hit` |
| `set_skate_mode(active)` | profile toggle (R key) |
| `set_damage_tint(0..1)` | fades red overlay post-hit |
| `set_dust_emitting(bool)` | per-tick ground-dust toggle |

**Don't call these from anywhere but PlayerBody.** The skin is visual-only; it doesn't drive physics or input.

---

## 4. @export tuning knobs

**Inherited from `CharacterSkin` (tune on every skin's root):**

| Export | Default | Used where |
|---|---|---|
| `lean_pivot_height` | 1.6 | body's lean origin (`player_body.gd:706`) |
| `body_center_y` | 0.9 | double-jump flip pivot (`player_body.gd:727`) |
| `uniform_scale` | 1.0 | baked into every-tick basis (`player_body.gd:715`) |
| `lean_multiplier` | 1.0 | scales forward/side lean (`player_body.gd:698`) |

**Skin-specific (promote these to @export on your own script if your skin needs them — they're not on the base):**

- `skate_root_y: float` — Y lift applied to the `Model` node in skate mode. KayKit and cop_riot have this. Default 0.134.
- `extra_animation_sources: Array[PackedScene]` — extra GLBs whose AnimationPlayer clips get merged into the primary library at `_ready`. KayKit uses this to pull in `movement_basic.glb`, `combat_melee.glb`, `movementadvanced.glb`. cop_riot doesn't (it uses a single multi-anim GLB).

**Dust position:** tuned by dragging the `DustParticles` node in the 3D viewport (no script export — it's a per-skin scene node). Good starting values: `y ≈ 0.137` (heel height), `z ≈ 1.0` (one unit behind the character in skin-local +Z). Shared visuals live at `library/fx/dust_particles.tres` and `library/fx/dust_sphere.tres` — change those and every skin's dust updates.

---

## 5. Step-by-step: importing a new rig

### 5.1 Drop in the GLB

1. Copy the `.glb` into a new folder under `player/skins/<name>/model/` (or `lib/<name>/` if it's vendored).
2. Let Godot auto-generate the `.glb.import`. No import settings to tweak unless you hit rotation/scale issues — the default GLTF importer works for Sophia, KayKit, and cop_riot.

### 5.2 Probe the skeleton

You need two pieces of data the scripts can't guess:
- The `Skeleton3D` node path inside the GLB (varies by exporter — Blender gives `Rig_Medium/Skeleton3D`, Mixamo→Sketchfab gives a deep path).
- The bone names for left and right feet (for wheel attachment).

Quick probe — write a one-shot `tests/probe_<name>_bones.gd`:

```gdscript
extends SceneTree
func _init() -> void:
    var scene: PackedScene = load("res://player/skins/<name>/model/<file>.glb")
    var inst: Node = scene.instantiate()
    var skel: Skeleton3D = _find(inst)
    print("Skeleton path: ", inst.get_path_to(skel))
    for i in skel.get_bone_count():
        print("  %d: %s" % [i, skel.get_bone_name(i)])
    quit(0)
func _find(n: Node) -> Skeleton3D:
    if n is Skeleton3D: return n
    for c in n.get_children():
        var r := _find(c)
        if r != null: return r
    return null
```

Run: `/Applications/Godot.app/Contents/MacOS/Godot --headless --script res://tests/probe_<name>_bones.gd --quit --path <project>`. Grep the output for `foot` / `Foot` / `LeftFoot`. Delete the probe when you're done.

Known bone names in-tree:
- KayKit (Blender rigify): `foot.l`, `foot.r`
- cop_riot (Mixamo): `mixamorig_LeftFoot_026`, `mixamorig_RightFoot_030`
- Sophia (Blender rigify-style): `DEF-foot.L`, `DEF-foot.R`

### 5.3 Duplicate the closest existing skin

**If your rig has only a couple clips** → copy `player/skins/cop_riot/`.
**If your rig has a full anim library (idle/run/jump/fall/dodge/punch/die/...)** → copy `player/skins/kaykit/`.

Rename:
- Folder: `player/skins/<name>/`
- `cop_riot_skin.gd` / `kaykit_skin.gd` → `<name>_skin.gd`
- `cop_riot_skin.tscn` / `kaykit_skin.tscn` → `<name>_skin.tscn`
- `class_name CopRiotSkin` / `KayKitSkin` → `class_name <Name>Skin`
- In the tscn, update the script `ExtResource` path, the `Model` `ExtResource` path+UID, the scene `uid` on line 1.

### 5.4 Wire the AnimationTree clips

Open the scene. In the AnimationTree, the state machine has a bunch of sub-resource `AnimationNodeAnimation`s each referencing a clip name by string. Replace those clip names with clips that actually exist in your rig's library.

A minimal clip map (for a rig with only 2 clips, like cop_riot):
- Every state points at one of your two clips.
- Attack, Dash, Crouch, Die, Land, Hit, etc., either fall back to the move clip or the idle clip — the body's state transitions still fire, so the visual cadence reads even if the clip is identical to Idle.

To see which states reference which clip names, grep your new tscn for `^animation = ` inside the `AnimationNodeAnimation` sub-resources — they're clustered near the top of the file. Edit in place.

### 5.5 Check loop modes

Godot's GLTF importer defaults every clip to `LOOP_NONE`. Any clip you want to loop (idle/run/crouch/sneak) will play once and freeze. Both cop_riot_skin.gd and kaykit_skin.gd patch this in `_ready`:

```gdscript
for n: String in ["Your_Idle", "Your_Run", ...]:
    if primary.has_animation(n):
        primary.get_animation(n).loop_mode = Animation.LOOP_LINEAR
```

Update the clip list to what your rig actually has. One-shot clips (attacks, dodges, hits, death, land) stay `LOOP_NONE`.

### 5.6 Set the foot-bone constants

In your script:

```gdscript
const _FOOT_L_BONE := &"<your left foot bone name>"
const _FOOT_R_BONE := &"<your right foot bone name>"
```

If the rig has no wheels (e.g., a non-skater character), delete the `WheelsLeft`/`WheelsRight` nodes from the scene and the `_reparent_under_bone` calls from `_ready`. The `set_skate_mode` override becomes a no-op (skate mode has no visual effect for this skin).

### 5.7 Tune proportions

Set on the skin root in the scene (inspector, not code):
- `lean_pivot_height` — roughly head height of the authored rig. Sophia: 1.3ish, KayKit: 1.55, cop_riot: 1.5.
- `body_center_y` — torso midpoint. KayKit + cop_riot: 0.85.
- `uniform_scale` — only if your rig imports too big / too small. cop_riot uses 2.0 (rig is half-size).
- `lean_multiplier` — 1.0 for dramatic skater feel (Sophia), 0.5 for stiff-gait cops and mannequins.
- `skate_root_y` (if your skin has it) — vertical lift so heels rest on the wheels in skate mode.

### 5.8 Position the wheels in the viewport

If the skin has wheels:
1. Open the skin scene.
2. Select `WheelsLeft`. Drag it in the 3D viewport to the left foot's contact point at the current bind pose. Rotate so the wheel axle is perpendicular to the foot's forward direction.
3. Repeat for `WheelsRight`.
4. At runtime the script reparents these nodes under `BoneAttachment3D`s with `keep_global_transform = true` — whatever you see in the editor is what you get in-game at bind pose, then they follow the foot bone through the animation.

Tip: temporarily set `uniform_scale` and the walk/skate position offset so you're tuning in the pose the character will actually use.

---

## 6. Plugging the skin into a pawn

A skin does nothing on its own — it lives inside a `PlayerBody`. Two ways to install it:

### 6.1 As the player character

Open `game.tscn`, select the PlayerBody node, set `Skin Scene` to your new `<name>_skin.tscn`. That's the whole change. The body also needs `walk_profile` and optionally `skate_profile` set.

**The active player skin is wired in exactly two lines of `game.tscn`:**

- The ext_resource near the top of the file (points at the skin tscn):
  ```
  [ext_resource type="PackedScene" uid="uid://..." path="res://player/skins/<name>/<name>_skin.tscn" id="99_playerskin"]
  ```
- The override on the Player node:
  ```
  [node name="Player" parent="." unique_id=604819286 instance=ExtResource("1_w0p8v")]
  ...
  skin_scene = ExtResource("99_playerskin")
  ```

`PlayerBody` defines `@export var skin_scene: PackedScene`; this override is the single source of truth for the player's look. To swap skins by hand-editing, change the ext_resource `path=` + `uid=` to another `*_skin.tscn` — no other code changes needed. (Same `skin_scene` export is what enemy variants override to get their own skins; see §6.2.)

### 6.2 As an enemy variant

Duplicate `enemy/enemy_kaykit.tscn` → `enemy/enemy_<name>.tscn`. Open it. Update the inspector overrides on the root PlayerBody:

| Field | Typical enemy value |
|---|---|
| `skin_scene` | your new skin |
| `brain_scene` | `enemy/brains/default_enemy_ai.tscn` |
| `pawn_group` | `"enemies"` |
| `attack_target_group` | `"player"` |
| `dies_permanently` | `true` |
| `max_health` | `1` |
| `walk_profile` | `enemy/enemy_profile.tres` |
| `start_in_walk_mode` | `true` (unless this enemy should skate) |

Drop the new enemy variant tscn into `level/level.tscn` anywhere to place instances.

---

## 7. Contract test

Copy `tests/test_cop_riot_skin_contract.gd` → `tests/test_<name>_skin_contract.gd`. Change the scene path and the prefix strings. The test verifies:
- Scene root extends `CharacterSkin`.
- `lean_pivot_height` and `body_center_y` are > 0.
- All 12 contract methods (`idle/move/fall/jump/edge_grab/wall_slide/attack/dash/crouch/die/land/on_hit`) exist.
- `damage_tint` clamps to `[0, 1]`.

Run:
```
/Applications/Godot.app/Contents/MacOS/Godot --headless --script res://tests/test_<name>_skin_contract.gd --quit --path <project>
```

For full-polish skins with a merged library (KayKit-style), also copy `tests/test_kaykit_skin_contract.gd` and update the expected-clips list — the test asserts the post-merge library contains the clips your AnimationTree references.

---

## 8. Smoke gate before calling it done

```
/Applications/Godot.app/Contents/MacOS/Godot --headless --quit-after 120 --path <project> 2>&1 | grep -Ei "SCRIPT ERROR|Compile Error|Parse Error"
```

Must return nothing. Also boot the game manually, press `R` to toggle skate, press `J` / click to attack, press `Q` to dash — confirm the skin plays the right states.

---

## 9. Known pitfalls (seen in-tree)

1. **Setting `scale` on the skin root in the tscn.** Wiped every tick. Use `uniform_scale` @export (`CharacterSkin`).
2. **Naming the rig instance anything other than `Model`.** `set_skate_mode` won't find it and the heel-on-wheels lift silently skips.
3. **Naming wheel nodes anything other than `WheelsLeft` / `WheelsRight`.** `$WheelsLeft` returns null → `_reparent_under_bone` no-ops → wheels stay at skin root and don't follow the foot.
4. **Putting `WheelsLeft` inside `Model` (inside the GLB instance).** Works in editor but Godot treats the GLB as a black box unless you explicitly enable editable children — avoid this; keep wheels at the skin root as siblings to `Model`.
5. **AnimationTree missing `unique_name_in_owner = true`.** Scripts do `%AnimationTree` — without the unique name it returns null and every state call crashes on a null dereference.
6. **Referencing clip names that don't exist in the merged library.** AnimationTree will silently skip the transition and the character freezes on the previous pose. After merging, assert the expected clips exist (kaykit's contract test is the template).
7. **Forgetting `LOOP_LINEAR` on the idle / run clips.** Character twitches for one beat then freezes. Patch in `_ready` like cop_riot and KayKit do.
8. **Class-name collision with Godot natives.** `class_name Skin` collides with Godot's native `Skin` (skeleton skinning). Use `CharacterSkin` / `<Name>Skin`.
9. **DustParticles missing `unique_name_in_owner = true`** or **not named exactly `DustParticles`**. `%DustParticles` in the skin script returns null → `set_dust_emitting` no-ops → dust never spawns. Either fix the node or delete the `@onready var _dust_particles = %DustParticles` line and the override (CharacterSkin's base no-op is fine for dustless skins).
10. **Putting `DustParticles` as a child of `Model` or `Skeleton3D`.** The emitter must be a direct child of the skin root so it inherits the skin's yaw rewrite and naturally trails. Nested in the Model, it rotates with bone transforms and looks wrong.

---

## 10. When something doesn't work

Follow the debug protocol in `CLAUDE.md`:
1. Add a log at `_ready`: `print("[<name>_skin] anim clips: ", primary.get_animation_list())`. Read what's actually there.
2. Add a log in each contract method: `print("[<name>_skin] move() -> ", state_machine.get_current_node())`.
3. The logs reveal the bug. Don't guess from symptoms.

Strip the logs when the fix ships.

---

## 11. Mixamo FBX → GLB pipeline (`tools/import_mixamo.py`)

For characters that come from Mixamo as separate `.fbx` files (one for the character mesh + bind pose, plus one per animation), Godot can't import them directly with full fidelity. The project ships a Blender batch script that merges a character + a folder of anim FBXs into one GLB with each anim as its own clip.

### Folder layout the script expects

```
~/Downloads/characters/        ← character FBXs (Aj.fbx, Ch29_nonPBR.fbx, ...)
~/Downloads/anims/             ← animation FBXs (Walking.fbx, Idle.fbx, ...)
~/Downloads/characters/output/ ← script writes one GLB per character here
```

Paths are passed in via CLI args, so you can flip them — but defaults to this convention.

### Mixamo download settings

For each character: download as **FBX, With Skin** (the rigged mesh).
For each animation: download as **FBX, Without Skin** (just the anim data — smaller, cleaner). Toggle **In Place: ON** so XZ root motion is zeroed; the script also strips Y root motion as a separate step (see below).
**FPS:** 30 is fine; the gltf exporter resamples on its own.

### Running the script

```bash
/Applications/Blender.app/Contents/MacOS/Blender --background --python \
  tools/import_mixamo.py -- \
  ~/Downloads/characters \
  ~/Downloads/anims \
  ~/Downloads/characters/output
```

It iterates every character FBX, imports each anim FBX in turn onto that character's armature as an NLA track, then exports a single GLB with every anim as a separate clip. **Per-character output filename is the lowercased FBX stem** (e.g. `Ch29_nonPBR.fbx` → `ch29_nonpbr.glb`).

### What the script handles automatically

These are problems we've already hit and fixed in the script — listed so you can recognize them in future work:

1. **Smooth shading lost.** Mixamo's smoothing groups can flatten during FBX→glTF conversion, producing visible polygon facets. The script forces `poly.use_smooth = True` on every mesh polygon before export.
2. **Hip-translation root motion.** Mixamo's "In Place" toggle only zeroes XZ; Y bob and any post-conversion axis-mangled forward motion stay in the Hips bone position track. With Hips Y values like 0 → 240 over 0.7s, the skeleton gets yanked above/below the body collider. The script strips every Hips-bone-location FCurve before pushing the action to NLA — physics drives root motion, animation drives bone rotation.
3. **Bone-namespace mismatch (T-pose bug).** Mixamo character variants don't share a bone namespace — Aj uses `mixamorig:`, Ch29 uses `mixamorig1:`, Ch32 uses `mixamorig8:`. The anim FBXs ship with `mixamorig:`. When pushing an action onto a character with a different prefix, the FCurves' `pose.bones["mixamorig:Hips"]` paths don't match the character's `mixamorig1:Hips` bones — Blender silently fails to bind, and the gltf exporter writes one keyframe per frame *all sampling the bind pose* (T-pose for every frame). The script detects each character's prefix from the actual armature, detects each action's prefix from FCurve data_paths, and recreates the FCurves under the corrected path before pushing to NLA. (Patching `data_path` in place isn't enough in Blender 4.4+ Animation 2.0 — the channelbag's internal binding doesn't refresh.)

### Diagnostic recipes

When a freshly-imported character looks wrong, run these mini-tests instead of guessing:

- **"Stuck in T-pose for every clip"** — bone-namespace mismatch. Probe: load the GLB, sample any rotation track at frame 0 vs `keys / 2`; if `angle_diff` is 0 across all clips, the fcurves never bound. Look at the `hips_prefix=` line in the script's output for that character and compare against the namespace in the anim FBX. The remap should fire and report `remapped <N> fcurves '<from>'→'<to>'`.
- **"Clip plays but character sinks/floats while running"** — hip translation wasn't stripped. Probe: dump the Hips position track per clip; look for `min`/`max` Y values in the hundreds (axis-mangled forward motion) or even small-magnitude variation that's enough to descend below the collider. Verify the script's `[stripped 3 hip-loc]` tag fired for the offending clip.
- **"Clip plays the wrong bones"** — the action bound to the *imported anim FBX's* armature, not the character's. The script removes the anim armature after extracting the action; if it's still in the scene, the gltf exporter writes both armatures' tracks. Confirm only the character's armature exists in the scene at export time.
- **"All clips faceted"** — `shade_smooth_all_meshes()` either didn't run or didn't reach the meshes. Confirm via Blender that `MeshInstance3D > Mesh > Polygon > use_smooth = True`. Edge-shade smoothing (per-edge angle thresholds) needs the Smooth-by-Angle modifier, not handled here.

### When to re-run the script

Any time you change which anim FBXs are in `~/Downloads/anims/`, OR when a new character FBX arrives. Output GLBs are deterministic per (character, anim-set, script-version) — no incremental mode, just nuke and rebuild. ~1 second per character on a modest Mac.

### Per-character bone-name surprises

Each Mixamo character variant has a different bone namespace, and Godot renames `:` to `_` on import. So the foot-bone constants in your skin script need to match what Godot sees, not what Blender sees:

| Character | Blender bone name | Godot bone name (use this in skin script) |
|---|---|---|
| Aj | `mixamorig:LeftFoot` | `mixamorig_LeftFoot` |
| Ch29_nonPBR | `mixamorig1:LeftFoot` | `mixamorig1_LeftFoot` |
| Ch32_nonPBR | `mixamorig8:LeftFoot` | `mixamorig8_LeftFoot` |
| Ch46_nonPBR | `mixamorig:LeftFoot` | `mixamorig_LeftFoot` |

Probe the imported GLB once with a one-shot SceneTree script (see `player/skins/cop_riot/cop_riot_skin.gd`'s comment about probing) and copy the exact bone names into `_FOOT_L_BONE` / `_FOOT_R_BONE` constants on your skin script.
