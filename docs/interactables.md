# Interactables, Dialogue & Audio Engine Spec (v1.2, Godot 4.6.2)

Implementation spec for the interaction system, the dialogue engine port, and the AAA audio layer that supports sidechain ducking. Every technical claim is tied to a Godot 4.6 doc page, an in-project reference file, or a file in the reference project at `/Users/ryanhelsing/GodotProjects/3dPFormer` — see **§ Sources** at the end.

> **v1.2 — implementation landed.** All interactables_dev-owned files from §14 exist, boot clean, and have passing smoke tests. **Status of the world:**
>
> **Shipped & tested (4 green smoke tests):**
> - `autoload/layers.gd` — 4-layer bitmask constants.
> - `autoload/events.gd` — all new signals added (§6 + ui_dev's modal/settings/save).
> - `autoload/game_state.gd` — inventory, flags, dialogue_visited, to_dict/from_dict (tested: `tests/test_game_state.tscn`).
> - `autoload/audio.gd` — 5-bus management, AudioCue registry, Events subscription, Settings integration.
> - `autoload/dialogue.gd` — Nathan Hoad wrapper, TTS queue, lifecycle, modal coordination.
> - `autoload/puzzles.gd` — lifecycle + pause + modal coordination (tested: `tests/test_puzzles_lifecycle.tscn`).
> - `interactable/interactable.gd` — base class.
> - `interactable/interaction_sensor.gd` + `interactable/scoring.gd` — hybrid scoring (tested: `tests/test_interaction_sensor.gd`).
> - `interactable/{door,dialogue_trigger,pickup,trap,puzzle_terminal}/` — all 5 concrete interactables + scenes.
> - `interactable/prompt_ui/` — CanvasLayer, integrated into `game.tscn`.
> - `audio/audio_cue.gd` + `audio/cue_registry.gd` + `audio/cue_registry.tres` + 4 initial cue files.
> - `default_bus_layout.tres` — 5-bus layout with sidechain compressors on Music + Ambience (sidechain = "Dialogue").
> - `puzzle/puzzle.gd` — base class.
> - `puzzle/hacking/hacking_puzzle.gd` + `.tscn` — timing-tap puzzle.
> - `addons/dialogue_manager/` — Nathan Hoad plugin vendored, enabled in project.godot.
> - `dialogue/voices.gd` + `dialogue/voices.tres` — character → ElevenLabs voice_id map (seeded from 3dPFormer).
> - project.godot: layer names, 5 autoloads, dialogue_manager plugin + section.
>
> **Deviations from v1.1 spec (recorded for future contributors):**
> - `Interactable.priority` renamed to `focus_priority` — `priority` shadows Area3D's built-in audio-reverb property.
> - `InteractionSensor.score_candidate` extracted to `interactable/scoring.gd` as `InteractionScoring.score` (dependency-free pure math) — enables clean `--script`-mode unit tests.
> - Static types on several autoloads loosened to `Resource` (instead of `AudioCue`/`CueRegistry`/`DialogueResource`) because plugin/class_name registration isn't guaranteed at autoload parse time. Runtime behavior unchanged.
> - `HackingPuzzle` uses `extends "res://puzzle/puzzle.gd"` (path-based) instead of `extends Puzzle` (class_name) for the same reason.
> - `Puzzles.start` duck-checks for the `finished` signal instead of `is Puzzle` — decoupled from class_name timing.
> - **Balloon source:** v1.2 ships with the plugin's `example_balloon.tscn`. Custom 3dPFormer-style balloon port (with `GameState.visit_dialogue` dimming of visited responses) deferred to a follow-up.
>
> **Blocked on CC Patch A (not on me):**
> - Wiring `InteractionSensor` as a child of `player_brain.tscn` (CC creates the scene).
> - Removing the `has_method("is_attacking")` safety net in `interaction_sensor.gd` after `PlayerBody.is_attacking()` accessor lands.
> - `Dialogue.start` / `Puzzles.start` consuming `PlayerBrain.capture_mouse(on)` (helper ships with Patch A; I call through `has_method` safety meanwhile).
>
> **Blocked on ui_dev:**
> - `PromptUI` glyph-swap reading from `PlayerBrain.last_device` — depends on CC Patch A.
> - Pre-existing menu code parse errors (unrelated to my changes; ui_dev's domain).
>
> **Smoke tests — 4 passing:**
> ```
> tests/test_intent.gd                   (existing, CC-owned)
> tests/test_game_state.tscn             (NEW, interactables_dev)
> tests/test_interaction_sensor.gd       (NEW, interactables_dev)
> tests/test_puzzles_lifecycle.tscn      (NEW, interactables_dev)
> ```

> **v1.1 amendments** — character-controller dev sync resolved five structural decisions that v1 had open:
> 1. **Sensor lives on `PlayerBrain`, not `PlayerBody`** (drivers own the senses they need). `PlayerBody` is the universal pawn — enemies are `PlayerBody` with `EnemyAIBrain`; putting a sensor there would spam `get_overlapping_areas()` on every NPC. Body dispatches via `brain.try_activate(self)`; base `Brain` has a no-op default.
> 2. **Gamepad `interact` → X (button_index 2)**, not A. A is already `jump`. Keyboard `E` unchanged.
> 3. **`Intent.interact_held: bool` reserved** now. Enables "hold to lockpick" later at zero cost.
> 4. **Layers.gd covers all four layers at once** — `world=1`, `player=2`, `enemy=3`, `interactable=10`. Named in Project Settings too, one source of truth.
> 5. **Focus gate during attack** — sensor suppresses `try_activate` while `body.is_attack_active()` is true (prevents door-open mid-swing).
>
> AudioCue registry also flipped from auto-scan to **explicit manifest** (§8.4) per JB "no silent failures" principle.

---

## 0. Project facts that constrain everything

| Fact | Value | Source |
|---|---|---|
| Engine version | **Godot 4.6.2 stable** | runtime log (from `materials.md` §0) |
| Renderer | **Forward+** | same |
| Release target | **Desktop only** | user direction |
| Existing architecture | **Brain / Body / Skin** — `Brain` pushes an `Intent` per physics tick; `PlayerBody` consumes | `player/brains/brain.gd`, `player/body/intent.gd`, `player/body/player_body.gd` |
| Central dispatch | `Events` autoload already present; autoloads are globally reachable by name, so signals on it act as a zero-import bus | `autoload/events.gd`; [Singletons (Autoload) — 4.6](https://docs.godotengine.org/en/4.6/tutorials/scripting/singletons_autoload.html) |
| Perspective | **Third-person platformer** on a spring-arm camera | `player/body/player_body.gd` |
| Dialogue plugin to vendor | [Nathan Hoad — godot-dialogue-manager](https://github.com/nathanhoad/godot_dialogue_manager) (Godot 4) | reference project: `/Users/ryanhelsing/GodotProjects/3dPFormer/addons/dialogue_manager` |
| TTS backend | ElevenLabs HTTP API, disk-cached | reference: `/Users/ryanhelsing/GodotProjects/3dPFormer/dialogue_balloon/balloon.gd` lines 200–261 |

**User-confirmed decisions (this conversation):**
1. Detection: **hybrid** — proximity Area3D + body-forward scoring, optional camera-crosshair weight.
2. Visual feedback: **prompt label + outline** on the focused interactable.
3. Pause behavior: **opt-in per interactable** (`pauses_game: bool`). Default pauses for dialogue + puzzles, not doors/pickups.
4. GameState: **save-ready now**, wire disk save later.
5. Audio ducking: **real sidechain compressor**, not tween-based fake.
6. Dialogue: port from `3dPFormer` using Nathan Hoad's addon.
7. Mini-puzzle scope: generic `Puzzle` base + one concrete "hacking" rhythm-tap puzzle.
8. Add `interact` InputMap action (keyboard + gamepad).

---

## 1. Godot 4.6 primitives we lean on

None of this is custom framework — these are stock engine features. Listed so future contributors know where to read the first-party docs.

| Primitive | Used for | Source |
|---|---|---|
| Autoloads | `Events`, `GameState`, `Audio`, `Dialogue` as zero-import global services | [Singletons (Autoload) — 4.6](https://docs.godotengine.org/en/4.6/tutorials/scripting/singletons_autoload.html) |
| Groups | Loose discovery of interactables via `add_to_group("interactable")` + `get_tree().get_nodes_in_group(...)` | [Groups — 4.6](https://docs.godotengine.org/en/4.6/tutorials/scripting/groups.html) |
| `Area3D` | Proximity sphere around the player; detects overlapping interactables | [Area3D — stable](https://docs.godotengine.org/en/stable/classes/class_area3d.html) |
| Camera ray | Optional crosshair-bias for hybrid detection: `camera.project_ray_origin()` + `project_ray_normal()` → `PhysicsRayQueryParameters3D` → `space_state.intersect_ray()` | [Ray-casting — stable](https://docs.godotengine.org/en/stable/tutorials/physics/ray-casting.html) |
| `AudioServer` + buses | Bus hierarchy with `AudioEffectCompressor.sidechain = "Dialogue"` for real ducking | [Audio buses](https://docs.godotengine.org/en/latest/tutorials/audio/audio_buses.html); [AudioEffectCompressor](https://docs.godotengine.org/en/stable/classes/class_audioeffectcompressor.html) |
| `AudioStreamPlayer3D` | Positional SFX attached to interactables (door creak *at* the door) | [Audio streams](https://docs.godotengine.org/en/stable/tutorials/audio/audio_streams.html) |
| Process modes | `PROCESS_MODE_ALWAYS` for sensor, `PROCESS_MODE_WHEN_PAUSED` for dialogue/puzzle UI | [Pausing games and process mode](https://docs.godotengine.org/en/stable/tutorials/scripting/pausing_games.html) |
| `Resource` subclasses | Save-ready `GameStateData.gd` serialized via `ResourceSaver` later | [Resources — saving & loading](https://docs.godotengine.org/en/stable/tutorials/scripting/resources.html) |
| `HTTPRequest` | TTS call to ElevenLabs + cache-to-disk | [HTTPRequest](https://docs.godotengine.org/en/stable/classes/class_httprequest.html) |

**4.6-specific notes:**
- Signals with `_` prefix are hidden from autocomplete. Internal Events signals may use `_`; public ones don't. ([4.6 release notes](https://godotengine.org/releases/4.6/))
- `NOTIFICATION_PAUSED`/`UNPAUSED` are reversed when `PROCESS_MODE_WHEN_PAUSED` is set ([godot#83160](https://github.com/godotengine/godot/issues/83160)). We won't rely on those notifications; we use `get_tree().paused` directly.

---

## 2. Architecture in one page

```
           ┌─────────────────────────────────────────────────────────┐
           │  Autoloads (globally reachable by name — NO imports)    │
           │                                                         │
           │   Events        GameState       Audio       Dialogue    │
           │   (bus)         (data)          (playback)  (story)     │
           └─────────────────────────────────────────────────────────┘
                 ▲              ▲               ▲          ▲
                 │              │               │          │
 ┌─────────────────────────────┐ │               │          │
 │ PlayerBody (CharacterBody3D)│ │               │          │
 │  ├─ Brain (PlayerBrain)     │ │               │          │
 │  │    └─ InteractionSensor ─┤─┴───────┐       │          │
 │  │         (Area3D sphere)  │         │      ┌┴──────────┴──┐
 │  └─ Skin (SophiaSkin)       │         ▼      │  Narrative   │
 └────────────┬────────────────┘  ┌──────────────┐  services    │
              │ intent.interact_  │ Interactable │  react to    │
              │ pressed           │    (base)    │  Events       │
              │                   │  ├─ Door     │  broadcasts  │
              │ brain.try_activate│  ├─ Dialogue-│              │
              └──────────────────►│  │   Trigger │              │
                                  │  ├─ Trap     │              │
                                  │  ├─ Pickup   │ PromptUI ◄──┤
                                  │  │ (quest)   │ (sibling     │
                                  │  └─ Puzzle-  │  CanvasLayer │
                                  │     Terminal │  in game.tscn)│
                                  └──────────────┘              │
                                                                │
  Enemies (PlayerBody + EnemyAIBrain) have NO sensor —          │
  AI brains leave interact_pressed = false. Zero physics cost.  │
```

**Legend:** solid arrows = direct calls / signal connections. The sensor lives on the brain precisely so enemy pawns (same `PlayerBody` class, different brain) don't carry interaction machinery they never use.

**Data flow for one interaction tick:**

1. `InteractionSensor` (child of `PlayerBrain`, which is itself a child of `PlayerBody`) runs every physics frame. Its `Area3D` child holds a sphere collider; it calls `get_overlapping_areas()` to get candidates in the `interactable` group.
2. Sensor scores each candidate by a weighted sum (proximity + body-forward alignment + optional camera-crosshair), picks the best.
3. When focused candidate changes, sensor emits a **local** signal `focus_changed(node_or_null)`. `PromptUI` (a sibling `CanvasLayer` in `game.tscn`) finds the sensor via `get_tree().get_first_node_in_group("interaction_sensor")` at `_ready` and connects. PromptUI shows/hides its label and calls `candidate.set_highlighted(true/false)`. No bus involvement — this is 1-to-1 wiring.
4. `PlayerBrain` fills `Intent.interact_pressed` (and `interact_held`) from `Input.is_action_just_pressed/pressed("interact")`.
5. `PlayerBody` on `intent.interact_pressed` calls `_brain.try_activate(self)`. `Brain.try_activate` is a no-op; `PlayerBrain.try_activate` overrides to delegate to its child sensor. The sensor suppresses activation while `body.is_attack_active()` is true, then calls `focused.interact(actor)`. The interactable *does the thing* — opens itself, calls `Dialogue.start(...)`, calls `Puzzles.start(...)`, mutates `GameState`.
6. The interactable (or the service it called) emits **broadcast** lifecycle signals on `Events` — `door_opened(id)`, `dialogue_started`, `puzzle_solved` — so anyone who cares (audio, game state, analytics) can react *without* being directly wired in.

**Rule for bus vs. local signal:** broadcasts that multiple subsystems legitimately want (`door_opened`, `flag_reached`) go on `Events`. 1-to-1 wiring (sensor → PromptUI, puzzle UI → PuzzleTerminal) stays local. The bus isn't a garbage can for every signal.

**This is the whole mental model.** No manager, no orchestrator, no routing layer. The base `Interactable` has a single virtual method and ~50 lines. `Brain.try_activate` is a 1-line no-op.

---

## 3. The `Interactable` base class

```gdscript
class_name Interactable
extends Area3D

## Every door, NPC trigger, pickup, or terminal extends this. A subclass
## overrides interact(). Everything else is optional.

## Text shown in the prompt UI while this object is focused. "Press [E] to "
## is prepended by the UI. Example: "hack terminal", "open door", "talk to Troll".
@export var prompt_verb: String = "interact"

## Stable ID used by GameState for world flags, save keys, and de-dupe.
## Example: "village_gate", "troll_conversation", "mainframe_terminal".
@export var interactable_id: StringName

## If set, GameState.inventory must contain this item for can_interact() to pass.
## Reads cleanly: a Door with requires_key="village_gate_key" does exactly that.
@export var requires_key: StringName = &""

## Pause get_tree() while this interaction is "open." Default false; dialogue
## triggers + puzzle terminals flip this to true.
@export var pauses_game: bool = false

## Score weight override — lets designers nudge one important interactable to
## win ties over clutter. Default 1.0.
@export var priority: float = 1.0


func _ready() -> void:
    add_to_group(&"interactable")
    collision_layer = Layers.INTERACTABLE  # see §10
    collision_mask = 0  # detection goes the other way — sensor scans us


## Subclasses override. Default checks requires_key.
func can_interact(_actor: Node3D) -> bool:
    if requires_key.is_empty():
        return true
    return GameState.has_item(requires_key)


## Subclasses MUST override. No call to super.interact() — base is a no-op.
func interact(_actor: Node3D) -> void:
    push_warning("Interactable %s has no interact() override" % interactable_id)


## Subclasses override if they have visuals worth highlighting. Default no-op
## so simple script-only interactables don't have to implement it.
func set_highlighted(_on: bool) -> void:
    pass
```

**Why Area3D and not Node3D?** Follows the reference project's working pattern (`/Users/ryanhelsing/GodotProjects/3dPFormer/helpers/actionable.gd`). Area3D gives us a collider for the sensor to detect. Alternatives (plain Node3D + distance check) lose the physics-layer filtering, which we want for skipping interactables the player isn't supposed to see yet (stealthed, locked-area-only, etc.).

**Accepted limitation:** an interactable must have one CollisionShape3D child. That's trivially authored in each interactable's .tscn.

---

## 4. `InteractionSensor` — hybrid scoring, on the brain

Lives as a child of `PlayerBrain`. One Area3D sphere + one script. Enemy brains don't have one — enemies carry zero interaction cost.

**Spatial-hierarchy note:** `PlayerBrain extends Node`, not `Node3D`. The sensor's `Area3D` is a Node3D — Godot's 3D transform system walks up past non-Node3D parents to find the nearest Node3D ancestor (which is `PlayerBody`), so the sphere tracks the body automatically with no per-frame sync. If this assumption ever breaks in a future Godot version, fallback is one line in `_physics_process`: `_area.global_position = _body.global_position`.

```gdscript
class_name InteractionSensor
extends Node

## Detection radius, meters. 2.5 feels right for a third-person platformer —
## you can point-blank clutter without the sphere swallowing background props.
@export var range: float = 2.5

## Weights for the scoring function. They don't need to sum to 1.0 — final
## score is just their weighted sum; only relative ordering matters.
@export_group("Scoring Weights")
@export_range(0.0, 1.0) var weight_proximity: float = 0.4
@export_range(0.0, 1.0) var weight_body_facing: float = 0.4
## Camera-crosshair bias. Small in third-person — camera can be whipping
## around and shouldn't dominate selection. 0 disables the camera sample.
@export_range(0.0, 1.0) var weight_camera_facing: float = 0.2

## Cap candidates at this dot-product floor (body.forward · dir) to prevent
## "interact with the thing behind me." -0.5 allows slight over-shoulder.
@export var facing_cutoff: float = -0.5

## Local signal — 1-to-1 wire between sensor and PromptUI. Not on Events bus.
signal focus_changed(focused: Interactable)

var focused: Interactable = null

## Body is injected by PlayerBrain at _ready so the sensor has no hard
## assumption about tree shape above it.
var body: CharacterBody3D

@onready var _area: Area3D = %SensorArea


func _ready() -> void:
    add_to_group(&"interaction_sensor")  # PromptUI discovers us this way


func _physics_process(_delta: float) -> void:
    var best: Interactable = null
    var best_score: float = -INF
    for a in _area.get_overlapping_areas():
        var it := a as Interactable
        if it == null: continue
        if not it.can_interact(body): continue
        var score := _score(it)
        if score > best_score:
            best_score = score
            best = it
    _set_focused(best)


func try_activate(actor: Node3D) -> void:
    if focused == null: return
    # Gate: no interactions while the player is mid-swing. Prevents
    # accidental door-opens during an attack jostle — per character-
    # controller dev sync (v1.1).
    if body.has_method(&"is_attack_active") and body.is_attack_active(): return
    if not focused.can_interact(actor): return
    focused.interact(actor)


func _score(it: Interactable) -> float:
    var to_it := it.global_position - body.global_position
    var dist := to_it.length()
    if dist > range: return -INF
    var dir := to_it / max(dist, 0.0001)
    # Godot convention: -Z is "forward" for Node3Ds. Matches player_body.gd.
    var facing := (-body.global_basis.z).dot(dir)
    if facing < facing_cutoff: return -INF

    var s := 0.0
    s += weight_proximity * (1.0 - dist / range)
    s += weight_body_facing * max(0.0, facing)
    if weight_camera_facing > 0.0:
        var cam := body.get_viewport().get_camera_3d()
        if cam != null:
            var cam_facing := (-cam.global_basis.z).dot(dir)
            s += weight_camera_facing * max(0.0, cam_facing)
    # Priority is additive (not multiplicative): a score near 0 shouldn't
    # zero out priority. Small bonus, not a multiplier.
    return s + (it.priority - 1.0) * 0.25


func _set_focused(next: Interactable) -> void:
    if next == focused: return
    if focused != null:
        focused.set_highlighted(false)
    focused = next
    if focused != null:
        focused.set_highlighted(true)
    focus_changed.emit(focused)  # local signal only
```

**Why scan every physics frame, not signal-driven on body_entered/exited?** `get_overlapping_areas()` updates before `area_entered` emits in 4.x (see [Area3D docs](https://docs.godotengine.org/en/stable/classes/class_area3d.html)), so polling gives a consistent scored pick each frame. Cost is O(candidates) — for ~10 overlapping interactables (already overkill) it's a rounding error. Event-driven focus switches to a different scoring function would leak logic.

**PlayerBrain wiring (~10 lines added to `player_brain.gd`):**

```gdscript
@onready var _sensor: InteractionSensor = $InteractionSensor  # scene child

func _ready() -> void:
    # ...existing ready...
    _sensor.body = get_parent() as CharacterBody3D

func try_activate(actor_body: Node3D) -> void:
    _sensor.try_activate(actor_body)
```

**Base `Brain.try_activate` (char-controller dev stubs this):**

```gdscript
## Body calls this on intent.interact_pressed. Base no-op; PlayerBrain
## overrides. AI/network brains leave it unimplemented.
func try_activate(_body: Node3D) -> void:
    pass
```

---

## 5. `Intent` extension

Two fields added. Everything else in the existing file (`player/body/intent.gd`) stays.

```gdscript
## Edge-triggered: true for exactly one physics tick when interact is pressed.
## Same contract as jump_pressed and attack_pressed.
var interact_pressed: bool = false

## Level-triggered: true as long as interact is held down. Reserved for "hold
## to lockpick" style interactions — v1 interactables only read _pressed.
## Filled by PlayerBrain regardless; consumers opt in.
var interact_held: bool = false
```

`PlayerBrain.tick()` fills both:
```gdscript
_intent.interact_pressed = Input.is_action_just_pressed("interact")
_intent.interact_held = Input.is_action_pressed("interact")
```

`PlayerBody._physics_process` reads `intent.interact_pressed` and calls `_brain.try_activate(self)`. Placement per char-controller dev sync: grouped with other edge-triggered intent dispatches (`attack_pressed` handler), before the main movement block — so if interact pauses the tree, physics settles cleanly.

AI brains leave both false — they don't interact with doors. They also don't have a sensor, so `try_activate` is a no-op.

---

## 6. `Events` — extending the existing signal bus

Adds to `autoload/events.gd`. Keep the existing signals — nothing breaks.

```gdscript
# Door
@warning_ignore("unused_signal") signal door_opened(id: StringName)

# Dialogue lifecycle (emitted by the Dialogue autoload)
@warning_ignore("unused_signal") signal dialogue_started(conversation_id: StringName)
@warning_ignore("unused_signal") signal dialogue_line_shown(character: StringName, text: String)
@warning_ignore("unused_signal") signal dialogue_ended(conversation_id: StringName)

# Puzzle lifecycle (emitted by the Puzzles autoload)
@warning_ignore("unused_signal") signal puzzle_started(puzzle_id: StringName)
@warning_ignore("unused_signal") signal puzzle_solved(puzzle_id: StringName)
@warning_ignore("unused_signal") signal puzzle_failed(puzzle_id: StringName)

# Inventory (emitted by GameState when it mutates)
@warning_ignore("unused_signal") signal item_added(id: StringName)
@warning_ignore("unused_signal") signal item_removed(id: StringName)

# World flags (emitted by GameState)
@warning_ignore("unused_signal") signal flag_set(id: StringName, value: Variant)
```

**Rule of thumb for what belongs on `Events` vs. a local signal:**
- **On the bus** — cross-cutting world events many subsystems legitimately want. `door_opened` (audio plays a cue, state writes a flag, analytics logs it, tutorial checks completion). Existing: `flag_reached`, `checkpoint_reached`, `coin_collected`.
- **Local signal** — 1-to-1 wiring. Sensor → PromptUI, Puzzle → PuzzleTerminal. Use a direct `signal` on the emitter and let the consumer `connect` to it (or find the emitter via a group).

**v1.1 revision:** earlier draft put `interactable_focused/unfocused` on `Events`. That was a mistake — one sensor, one PromptUI, 1-to-1 wiring. Moved to `InteractionSensor.focus_changed(focused)` local signal. Keeps the bus reserved for genuine broadcasts, in line with the emitter-side-filter convention already established across `flag_3d.gd`, `phone_booth.gd`, `coin.gd`.

---

## 7. `GameState` — save-ready from day one

New autoload. The store is two fields: a typed inventory and a generic flag dictionary. Any save/load code is a 10-line pair of methods; we implement them now so we don't retrofit.

```gdscript
extends Node
## Save-serializable world state. Single source of truth for: player inventory,
## world flags (doors opened, NPCs talked to, puzzles solved), and per-NPC
## dialogue-visited tracking (ported from 3dPFormer/state.gd).

var inventory: Array[StringName] = []
var flags: Dictionary = {}  # StringName -> Variant
var dialogue_visited: Dictionary = {}  # character(String) -> {zipped_response(String): true}


func has_item(id: StringName) -> bool:
    return inventory.has(id)

func add_item(id: StringName) -> void:
    if inventory.has(id): return
    inventory.append(id)
    Events.item_added.emit(id)

func remove_item(id: StringName) -> void:
    if not inventory.has(id): return
    inventory.erase(id)
    Events.item_removed.emit(id)

func set_flag(id: StringName, value: Variant = true) -> void:
    flags[id] = value
    Events.flag_set.emit(id, value)

func get_flag(id: StringName, default: Variant = null) -> Variant:
    return flags.get(id, default)

## Dialogue Manager .dialogue files can call these directly (see §9.1).
func visit_dialogue(character: String, response_id: String, text: String) -> void:
    var zipped := "%s_%s" % [response_id, text]
    if not dialogue_visited.has(character):
        dialogue_visited[character] = {}
    dialogue_visited[character][zipped] = true

func has_visited(character: String, zipped: String) -> bool:
    return dialogue_visited.get(character, {}).has(zipped)


## ---- Save / load (wire to disk via SaveService later) ----
func to_dict() -> Dictionary:
    return {
        "inventory": inventory.duplicate(),
        "flags": flags.duplicate(true),
        "dialogue_visited": dialogue_visited.duplicate(true),
        "version": 1,
    }

func from_dict(d: Dictionary) -> void:
    inventory.assign(d.get("inventory", []))
    flags = d.get("flags", {}).duplicate(true)
    dialogue_visited = d.get("dialogue_visited", {}).duplicate(true)
```

**Why autoload-with-dictionary, not a `Resource` subclass?** Resources are load-heavy and tie save file format to class versioning headaches. A plain `Dictionary` serialized to JSON at `user://save.json` via `FileAccess` is trivial, diffable, and version-resilient. The autoload is the in-memory hot copy; disk persistence is a future 20-line `SaveService.gd` that calls `to_dict()` / `from_dict()`.

**Deferred:** the actual `SaveService` (write-to-disk, load-on-startup, checkpoint rotation). Out of scope for this doc — but the API above is the contract it'll use.

**Migration from reference project:** the reference's `state.gd` mixes game state with audio calls (`AudioManager.got.play()` inside `add_acorn()`). We *don't* port that coupling. `GameState` emits `Events.item_added`; `Audio` listens and decides what sound to play. Clean pipe, testable in isolation.

---

## 8. `Audio` — AAA bus layout + sidechain ducking

New autoload. Owns non-positional playback (music, UI SFX, dialogue voice) and the bus layout. Positional SFX lives on the interactables themselves as `AudioStreamPlayer3D` nodes routed to the SFX bus.

### 8.1 Bus layout

Saved to `default_bus_layout.tres`.

```
Master
├── Music       (AudioEffectCompressor with sidechain = "Dialogue")
├── Ambience    (AudioEffectCompressor with sidechain = "Dialogue")
├── SFX         (no ducking — gunshots and footsteps shouldn't duck)
├── Dialogue    (drives the sidechains on Music + Ambience)
└── UI          (UI sounds unaffected by world audio)
```

**Why sidechain on Music *and* Ambience but not SFX?** When an NPC is talking, you want music and world ambience to dip so the voice is intelligible. You don't want door creaks and footfalls to dip — those are diegetic and fine at full volume. This is the exact design Valve's Source engine uses.

### 8.2 Compressor settings (starting values — iterate in-editor)

Per the [AudioEffectCompressor docs](https://docs.godotengine.org/en/stable/classes/class_audioeffectcompressor.html) and common voice-over ducking tutorials:

| Property | Music bus | Ambience bus |
|---|---|---|
| `threshold` (dB) | `-30` | `-30` |
| `ratio` | `8.0` | `6.0` |
| `attack_us` | `20000` (20 ms) | `20000` |
| `release_ms` | `250` | `400` |
| `gain` (dB) | `0` | `0` |
| `mix` | `1.0` | `1.0` |
| `sidechain` | `"Dialogue"` | `"Dialogue"` |

Ambience has a slower release so it breathes back more naturally after a dialogue line ends.

### 8.3 `Audio` autoload API

```gdscript
extends Node

## SFX cues — authored as Resources so designers can define pools with pitch/
## volume variance without code changes. See §8.4.
@export var cues: Dictionary = {}  # StringName -> AudioCue resource

var _music_player: AudioStreamPlayer
var _ambience_player: AudioStreamPlayer
var _sfx_players: Array[AudioStreamPlayer] = []  # small pool, round-robin
var _dialogue_player: AudioStreamPlayer


func play_sfx(cue_id: StringName) -> void: ...
func play_music(stream: AudioStream, fade_in: float = 0.8) -> void: ...
func play_ambience(stream: AudioStream, fade_in: float = 1.5) -> void: ...
func play_dialogue(stream: AudioStream) -> void: ...  # used by Dialogue autoload
func stop_music(fade_out: float = 1.0) -> void: ...
```

Positional SFX skips this API entirely — doors and props use their own `AudioStreamPlayer3D` with `bus = "SFX"`.

### 8.4 `AudioCue` resource + explicit registry

Authored as `.tres` files so a "door open" cue is a data file, not a script.

```gdscript
class_name AudioCue
extends Resource

@export var streams: Array[AudioStream] = []  # random pick from pool
@export var volume_db_min: float = 0.0
@export var volume_db_max: float = 0.0
@export var pitch_min: float = 1.0
@export var pitch_max: float = 1.0
@export var bus: StringName = &"SFX"
```

**Registry is explicit, not auto-scan.** One file — `res://audio/cue_registry.tres` — is a `CueRegistry` resource with `@export var cues: Dictionary` mapping `StringName → AudioCue`. Editable in the inspector.

```gdscript
class_name CueRegistry
extends Resource

@export var cues: Dictionary = {}  # StringName -> AudioCue
```

`Audio._ready()` loads the registry. `Audio.play_sfx(&"door_open")` looks up the cue; **missing entries push a loud error** — `push_error("Audio cue not registered: %s" % id)` — rather than silently playing nothing. This is the anti-cargo-cult principle: silent failure in a shipped game is a week of bug-hunting; loud failure is a 5-second fix.

**Why explicit over auto-scan of `res://audio/cues/`:** auto-scan makes `play_sfx(&"door_opne")` silently play nothing when the filename typo happens. The registry makes it a push_error with the exact missing ID. Also: one file to grep for "what cues exist."

### 8.5 Audio-reacts-to-Events pattern

`Audio._ready()` connects to a handful of `Events` signals and plays cues. This is the "how the audio engine stays decoupled" trick:

```gdscript
func _ready() -> void:
    Events.item_added.connect(func(_id): play_sfx(&"pickup_ding"))
    Events.door_opened.connect(func(_id): play_sfx(&"door_open"))
    Events.puzzle_solved.connect(func(_id): play_sfx(&"hack_success"))
    Events.puzzle_failed.connect(func(_id): play_sfx(&"hack_fail"))
```

One file owns "what sound plays when what happens." Game code just mutates state and emits signals — it never calls Audio directly for these reactions.

---

## 9. `Dialogue` — Nathan Hoad + TTS port

### 9.1 Plugin install

Vendor `addons/dialogue_manager/` from the reference project. Enable in `project.godot`:

```ini
[editor_plugins]
enabled=PackedStringArray("res://addons/gdquest_colorpicker_presets/plugin.cfg", "res://addons/dialogue_manager/plugin.cfg")

[dialogue_manager]
general/wrap_lines=true
general/states=["GameState", "Events", "Audio"]
general/balloon_path="res://dialogue/balloon.tscn"
```

`general/states` is the key line — it exposes these autoloads as globals inside .dialogue files, so a line can do `when GameState.has_item(&"key")` or call mutators like `GameState.add_item(&"apple")` directly. Exactly how the reference project uses it.

### 9.2 `Dialogue` autoload — thin wrapper + lifecycle signals

```gdscript
extends Node

var _open: bool = false
var _active_id: StringName = &""


func start(resource: DialogueResource, title: String = "start", id: StringName = &"") -> void:
    if _open: return
    _open = true
    _active_id = id if not id.is_empty() else StringName(title)
    get_tree().paused = true
    Events.dialogue_started.emit(_active_id)
    var balloon := preload("res://dialogue/balloon.tscn").instantiate()
    get_tree().root.add_child(balloon)
    balloon.start(resource, title)
    balloon.tree_exited.connect(_on_balloon_closed, CONNECT_ONE_SHOT)


func is_open() -> bool:
    return _open


func _on_balloon_closed() -> void:
    get_tree().paused = false
    Events.dialogue_ended.emit(_active_id)
    _open = false
    _active_id = &""
```

**Why wrap DialogueManager instead of calling `DialogueManager.show_dialogue_balloon()` directly?** So callers use a stable API we own (`Dialogue.start(...)`), we control pause behavior in one place, and `Events.dialogue_started/ended` fire automatically. The plugin can change; our game code doesn't.

### 9.3 TTS port — fix the reference bugs on the way over

Port the TTS logic from `dialogue_balloon/balloon.gd` lines 200–261, but fix these issues as we copy:

| Reference bug | Fix |
|---|---|
| API key hardcoded in source (`"6d55209ea42585939fb4650dbefe92d1"`) | Read from `user://tts_config.tres` (a `Resource` with `@export var api_key: String`), or env var `ELEVEN_LABS_API_KEY`. If neither present, skip TTS silently (dialogue still reads). |
| Cache path `res://generated_audio/` — `res://` is **read-only in exported builds** | Move to `user://tts_cache/`. ([File paths in Godot](https://docs.godotengine.org/en/stable/tutorials/io/data_paths.html)) |
| Voice ID → character map hardcoded in balloon | Move to `dialogue/voices.tres` — an authored `Resource` with `Dictionary` field. |
| `HTTPRequest` node owned by the balloon (dies with it) | Owned by `Dialogue` autoload. Survives balloon close, lets next line fetch while previous plays. Requests are FIFO-queued — a second line starting before the first fetch completes no longer clobbers `current_file_name`; the queue tracks pending requests with their target filenames. |
| Cache filename uses `md5_text().left(15)` of character+text+voice | **Keep.** Works fine, stable across runs. |
| Playback via a local `AudioStreamPlayer` in the balloon | Route through `Audio.play_dialogue(stream)` so the Dialogue bus drives sidechain ducking on Music+Ambience. **This is the whole point** — voice-over must hit the Dialogue bus to duck music. |

### 9.4 Dialogue-balloon scene

Port `dialogue_balloon/balloon.tscn` + `balloon.gd` to `res://dialogue/balloon.tscn`. Strip the TTS code out (now in `Dialogue`); keep the typed-out line rendering, response menu, and `State.visit_dialogue(...)` calls (now `GameState.visit_dialogue(...)`).

Balloon node's `process_mode = PROCESS_MODE_WHEN_PAUSED` so the game freezes under it but the balloon updates.

**Deferred:** portrait lookup improvements, controller-button glyph on responses. Port as-is first.

---

## 10. The concrete interactables (each is tiny)

### 10.1 Physics layers

Per char-controller dev sync — codify all four layers at once in Project Settings → Layer Names → 3D Physics, so we have a single source of truth and no scattered magic numbers. Currently only layer 1 is implicitly used; this formalizes layers 2 and 3 while adding 10.

| Layer # | Name | Used by |
|---|---|---|
| 1 | `world` | existing static geo, level CSG |
| 2 | `player` | PlayerBody (when `pawn_group == "player"`) |
| 3 | `enemy` | PlayerBody (when `pawn_group == "enemies"`) |
| 10 | `interactable` | All `Interactable` subclasses |

`Layers.gd` autoload covers all four as bitmask constants so they're usable directly in `collision_layer`/`collision_mask` assignments:

```gdscript
extends Node

const WORLD        = 1 << 0   # layer 1
const PLAYER       = 1 << 1   # layer 2
const ENEMY        = 1 << 2   # layer 3
const INTERACTABLE = 1 << 9   # layer 10
```

Usage: `sensor_area.collision_mask = Layers.INTERACTABLE`. The body stays on its existing default layer 1 for now (char-controller owns that migration).

### 10.2 `Door`

```gdscript
class_name Door
extends Interactable

@export var open_animation: String = "open"
@onready var _anim: AnimationPlayer = %AnimationPlayer

func interact(_actor: Node3D) -> void:
    _anim.play(open_animation)
    GameState.set_flag(interactable_id, true)
    Events.door_opened.emit(interactable_id)
    queue_free()  # or keep + disable if re-close is a thing
```

If `requires_key` is set on the door, `can_interact` rejects prior to `interact` being called — door stays focused but the sensor will keep showing the prompt (with a "Locked" variant if we want; deferred).

### 10.3 `DialogueTrigger`

```gdscript
class_name DialogueTrigger
extends Interactable

@export var dialogue_resource: DialogueResource
@export var dialogue_start: String = "start"

func _ready() -> void:
    super._ready()
    pauses_game = true

func interact(_actor: Node3D) -> void:
    Dialogue.start(dialogue_resource, dialogue_start, interactable_id)
```

### 10.4 `Pickup` — narrative items only

**Scope clarification per §18:** `Pickup` is specifically for **press-E narrative items** — a village gate key on a pedestal, a story-relevant floppy disk, an NPC's handed item. Platformer collectibles (coins, scattered floppies, power-ups) are **not** `Interactable` subclasses; they stay on the existing `body_entered` auto-trigger pattern (see `level/interactable/coin/coin.gd`) so players can vacuum them up while running.

```gdscript
class_name Pickup
extends Interactable

@export var item_id: StringName

func interact(_actor: Node3D) -> void:
    GameState.add_item(item_id)  # fires Events.item_added → Audio plays ding
    queue_free()
```

### 10.5 `Trap` — interactable that damages

Added per char-controller dev sync. Example of an interactable that harms the actor. Uses the existing unified damage API on `PlayerBody.take_hit(dir, force)`.

```gdscript
class_name Trap
extends Interactable

@export var knockback: float = 14.0
@export var activation_knocks_self_offline: bool = true

func interact(actor: Node3D) -> void:
    if actor.has_method(&"take_hit"):
        var dir := (actor.global_position - global_position).normalized()
        actor.take_hit(dir, knockback)
    if activation_knocks_self_offline:
        queue_free()  # single-use spike; remove to make resettable
```

Trap's `pauses_game` stays `false` — you want movement to continue so the knockback reads. Prompt verb like "disarm" or "touch" is author's choice.

### 10.6 `PuzzleTerminal`

```gdscript
class_name PuzzleTerminal
extends Interactable

@export var puzzle_scene: PackedScene  # e.g. res://puzzle/hacking/hacking_puzzle.tscn

func _ready() -> void:
    super._ready()
    pauses_game = true

func interact(_actor: Node3D) -> void:
    Puzzles.start(puzzle_scene, interactable_id)
```

`Puzzles` is a thin autoload mirror of `Dialogue`: instantiates the scene under a CanvasLayer, awaits its `finished(success)` signal, pauses tree, emits `Events.puzzle_solved/failed`, unpauses.

---

## 11. The `Puzzle` base and the `HackingPuzzle`

### 11.1 `Puzzle` base

Intentionally boring. All puzzle scenes extend it.

```gdscript
class_name Puzzle
extends CanvasLayer

signal finished(success: bool)

func _ready() -> void:
    process_mode = Node.PROCESS_MODE_WHEN_PAUSED


## Subclasses call this when done.
func _complete(success: bool) -> void:
    finished.emit(success)
    queue_free()
```

### 11.2 `HackingPuzzle` — the timing tap

Concrete design per user spec: slider moves across screen, tap `interact` in the target zone. Hit → 5/5 solved; miss → regress one. Hits speed the slider up; misses slow it.

```gdscript
class_name HackingPuzzle
extends Puzzle

@export var required_hits: int = 5
@export var zone_width_px: float = 80.0  # size of the target area on the bar
@export var base_speed_px_s: float = 420.0
@export var speed_increase_per_hit: float = 90.0  # additive each successful hit
@export var speed_decrease_per_miss: float = 60.0  # clamped to base_speed
@export var max_speed_px_s: float = 1200.0

var _hits: int = 0
var _speed: float = 0.0
var _direction: int = 1  # +1 right, -1 left (bounces at edges)

@onready var _bar: Control = %Bar
@onready var _indicator: Control = %Indicator
@onready var _zone: Control = %TargetZone
@onready var _progress_label: Label = %ProgressLabel


func _ready() -> void:
    super._ready()
    _speed = base_speed_px_s
    _position_zone_randomly()
    _update_label()


func _process(delta: float) -> void:
    var new_x := _indicator.position.x + _direction * _speed * delta
    if new_x <= 0.0:
        new_x = 0.0
        _direction = 1
    elif new_x >= _bar.size.x:
        new_x = _bar.size.x
        _direction = -1
    _indicator.position.x = new_x


func _input(event: InputEvent) -> void:
    if not event.is_action_pressed("interact"): return
    get_viewport().set_input_as_handled()
    if _indicator_in_zone():
        _on_hit()
    else:
        _on_miss()


func _indicator_in_zone() -> bool:
    var x := _indicator.position.x + _indicator.size.x * 0.5
    return x >= _zone.position.x and x <= _zone.position.x + _zone.size.x


func _on_hit() -> void:
    _hits += 1
    _speed = minf(_speed + speed_increase_per_hit, max_speed_px_s)
    _position_zone_randomly()
    _update_label()
    # Play audio cue via signal so the Audio engine owns the sound choice
    # (we could emit a more specific one; pass-through puzzle_solved is only
    # on completion — add a finer "puzzle_step" signal if needed, deferred)
    if _hits >= required_hits:
        _complete(true)


func _on_miss() -> void:
    _hits = maxi(_hits - 1, 0)
    _speed = maxf(_speed - speed_decrease_per_miss, base_speed_px_s)
    _position_zone_randomly()
    _update_label()


func _position_zone_randomly() -> void:
    var max_x := _bar.size.x - zone_width_px
    _zone.position.x = randf_range(0.0, max_x)
    _zone.size.x = zone_width_px


func _update_label() -> void:
    _progress_label.text = "%d / %d" % [_hits, required_hits]
```

**No fail state** — the user didn't ask for one, and a puzzle you can't lose is a valid design choice (like picking a lock in Fallout 4). If we want fail later, add a timer and call `_complete(false)`. One line.

**"Tap too fast" abuse:** player can mash `interact`. Mitigation: add a `cooldown_ms` between taps (default 150ms). Deferred — try it un-cooldowned first; mashing tends not to win because zones move.

---

## 12. Prompt UI & outline

### 12.1 Prompt UI

A single `CanvasLayer` scene autoloaded or added to `game.tscn`. Listens to `Events.interactable_focused/unfocused`, shows/hides a label at bottom-center: `[E] Hack terminal`.

- Keyboard glyph shown by default (`E`).
- Gamepad glyph when last input was a JoypadButton/JoypadMotion. Track via `Input.is_joy_known(0)` + listen in `_input` for the most recent device type.
- Text = `"[%s] %s %s" % [glyph, verb_prefix, focused.prompt_verb]` where `verb_prefix` is inferred or "Press".

**Deferred:** world-space prompt bubbles (floating above each interactable) — harder to read in clutter. Center-bottom is the platformer standard.

### 12.2 Outline

Two-stage implementation.

**Stage 1 (ship first):** `Interactable.set_highlighted(on: bool)` default override in subclasses that have a `MeshInstance3D` — tween the `StandardMaterial3D.emission_energy_multiplier` up ~20% when highlighted. Cheap, works without a shader.

**Stage 2 (polish pass):** inverted-hull outline. A dedicated `OutlineTarget` child Node3D on each interactable holds a duplicate `MeshInstance3D` with a back-face-culled inverted-hull shader, hidden by default, shown on highlight. Based on [godotshaders.com outline-inverted-hull](https://godotshaders.com/shader/simple-inverted-hull-outline-shader/). **Deferred** until the interactables exist and feel under-emphasized.

Don't build Stage 2 first — we'll know what the feel needs only after playing with Stage 1.

---

## 13. InputMap addition

Add to `project.godot`:

```ini
interact={
"deadzone": 0.5,
"events": [Object(InputEventKey,...,"physical_keycode":69,...)
, Object(InputEventJoypadButton,...,"button_index":2,...)
]
}
```

`physical_keycode 69` = `E`. `button_index 2` = **X on Xbox / Square on PlayStation / Y on Switch**.

**v1.1 fix:** earlier draft put `interact` on gamepad button 0 (A/Cross). That's already `jump` — pressing would double-trigger. Moved to button 2 (X/Square), which matches the Mario Odyssey / It Takes Two / A Hat in Time convention (A=jump, X=interact/action). Button 1 (B/Circle) is the pan-game "cancel" and must stay clear for UI.

Keyboard `E` collides with nothing. Existing: `toggle_skate=Q`, `attack=J+LMB`, `jump=Space`, `toggle_follow_mode=F`, `toggle_fullscreen=F11`.

---

## 14. Integration points with existing code

Minimally invasive. Responsibility split between char-controller dev (CC) and interactables work (IX):

| File | Change | Owner |
|---|---|---|
| `autoload/events.gd` | Add signals from §6. No removals. | IX |
| `player/body/intent.gd` | Add `interact_pressed: bool` + `interact_held: bool`. | IX (one field pair) |
| `player/brains/brain.gd` | Add `func try_activate(_body: Node3D) -> void: pass` base no-op. | **CC — pre-commits this stub to unblock IX** |
| `player/brains/player_brain.gd` | Fill `_intent.interact_pressed/held` from Input. Add `@onready var _sensor: InteractionSensor = $InteractionSensor`, inject `_sensor.body = get_parent()` at `_ready`, override `try_activate(b) -> _sensor.try_activate(b)`. | IX |
| `player/brains/player_brain.tscn` | Add `InteractionSensor` child node, which owns a child `Area3D` named `%SensorArea` with a `SphereShape3D` of radius 2.5 and `collision_mask = Layers.INTERACTABLE`. | IX |
| `player/body/player_body.gd` | **Two changes:** (1) in `_physics_process` after `attack_pressed` handling: `if intent.interact_pressed: _brain.try_activate(self)`. (2) Expose `func is_attack_active() -> bool: return _attack_active_timer > 0.0` so sensor can gate. | CC (or CC-approved IX edit) |
| `player/brains/enemy_ai_brain.gd`, `scripted_brain.gd` | **Unchanged.** They inherit base `Brain.try_activate` no-op. Zero risk of enemies stealing your door. | — |
| `project.godot` | Add autoloads (`GameState`, `Audio`, `Dialogue`, `Puzzles`, `Layers`). Add 3D Physics Layer names (`world`, `player`, `enemy`, `interactable`). Add `interact` InputMap action (keyboard E + gamepad button 2). Enable `dialogue_manager` plugin. Add `[dialogue_manager]` section. | IX |
| `game.tscn` | Add `PromptUI` CanvasLayer sibling to `ControlsHint`. | IX |
| `default_bus_layout.tres` | Replace with the 5-bus layout from §8.1. | IX |

**Char-controller dev in-flight work noted:** filtering interactables by `pawn_group == "player"`, damage gating by group, vertical attack range. None conflicts with IX changes above.

---

## 15. Target file layout

```
addons/
  dialogue_manager/                  <-- vendored from 3dPFormer
autoload/
  events.gd                          <-- existing, extended
  game_state.gd                      <-- NEW
  audio.gd                           <-- NEW
  dialogue.gd                        <-- NEW
  puzzles.gd                         <-- NEW
  layers.gd                          <-- NEW (physics-layer constants)
audio/
  cue_registry.tres                  <-- CueRegistry manifest (explicit)
  cues/
    door_open.tres
    pickup_ding.tres
    hack_success.tres
    hack_fail.tres
dialogue/
  balloon.tscn / balloon.gd          <-- ported, TTS stripped
  voices.tres                        <-- character→voice_id map
  *.dialogue                         <-- authored per level
interactable/
  interactable.gd
  interaction_sensor.gd              <-- child of PlayerBrain (v1.1)
  prompt_ui/
    prompt_ui.gd / prompt_ui.tscn    <-- CanvasLayer sibling in game.tscn
  door/              door.gd / .tscn
  dialogue_trigger/  dialogue_trigger.gd / .tscn
  pickup/            pickup.gd / .tscn       (narrative only — §10.4)
  trap/              trap.gd / .tscn         (§10.6)
  puzzle_terminal/   puzzle_terminal.gd / .tscn
puzzle/
  puzzle.gd
  hacking/ hacking_puzzle.gd / .tscn
player/body/
  intent.gd                          <-- +interact_pressed, +interact_held
  player_body.gd                     <-- +_brain.try_activate dispatch, +is_attack_active()
player/brains/
  brain.gd                           <-- +try_activate no-op (CC pre-stub)
  player_brain.gd                    <-- +sensor child, +try_activate override
  player_brain.tscn                  <-- +InteractionSensor + SensorArea subtree
game.tscn                            <-- +PromptUI CanvasLayer sibling
default_bus_layout.tres              <-- REPLACED (5 buses w/ sidechain)
project.godot                        <-- autoloads, layer names, InputMap, plugin, dialogue_manager section
user:// (runtime)
  tts_cache/*.mp3                    <-- generated at runtime
  tts_config.tres                    <-- API key (gitignored)
```

---

## 16. Open risks before prototype

1. **Sensor under non-Node3D parent (brain) global-transform inheritance.** Godot's 3D transform system walks up past `Node` parents to the nearest `Node3D` ancestor, so the sensor's Area3D should correctly track the body's world position even with `PlayerBrain (Node)` as its direct parent. Verified by convention; if the first wiring shows the sensor stuck at origin instead of following the player, the fix is one line in `_physics_process`: `_area.global_position = body.global_position`. **Test this first when implementing.**
2. **Third-person hybrid scoring feel.** `weight_camera_facing = 0.2` is a guess. If the camera bias is too strong (player turning camera randomly retargets focus), drop to `0.0`. If too weak (player can't choose between two adjacent interactables), raise to `0.4`. Tune against a scene with 3+ close interactables.
3. **ElevenLabs latency on first line.** A cold-cache response can take 1–3 seconds. The balloon should show the text immediately and play TTS whenever it arrives — don't block on the request. Reference code does this correctly; preserve that.
4. **Sidechain threshold tuning.** `-30 dB` threshold assumes music is sitting around `-20 dB` average. If music mix is quieter, dialogue won't trigger ducking. Verify with a scene after music tracks are in.
5. **`PROCESS_MODE_WHEN_PAUSED` notification reversal** ([godot#83160](https://github.com/godotengine/godot/issues/83160)). We don't rely on the notifications, but if a future contributor does, they'll be confused. Note it in a code comment at the pause site.
6. **Input handling during dialogue/puzzle.** Balloon + Puzzle call `get_viewport().set_input_as_handled()` to swallow `interact` presses. Verify `PlayerBrain._unhandled_input` doesn't re-process them. Existing project uses `_input`/`_unhandled_input` inconsistently — audit during wiring.
7. **Outline Stage 1 emission tween on shared materials.** If two interactables share a material (common with pickups), highlighting one lights both. Committed fix: `surface_material_override = mesh.get_active_material(0).duplicate()` at `_ready()` on any Interactable subclass that overrides `set_highlighted`. Pay the duplication cost once per instance; no shared-material bleed.

---

## 17. Deferred / out of scope

- **Disk save/load** — `SaveService` autoload wrapping `GameState.to_dict()/from_dict()` and JSON at `user://save.json`. API is designed for it; implementation is next ticket.
- **Outline Stage 2** — inverted-hull shader outline. Ship emission tween first.
- **World-space prompt bubbles** — floating labels per-interactable. Center-bottom for now.
- **Controller glyph textures** — show `[E]` for keyboard + generic button icon for gamepad v1. Proper per-platform PlayStation/Xbox glyphs later.
- **Interactable "locked" prompt variant** — when `requires_key` fails, show "Locked — needs [key]" instead of hiding. v1 just hides.
- **AI interaction** — enemies opening doors. `Intent.interact_pressed` exists on all brains but only `PlayerBrain` fills it. Trivially extensible.
- **Save-compatible puzzle state** — saving mid-puzzle progress. v1 puzzles are short (~30s) and reset on retry.
- **Puzzle tap cooldown** — mash protection for `HackingPuzzle`. Test without first.
- **Dialogue-driven camera cuts** — cinematic framing during dialogue. v1 freezes the existing camera.
- **Audio-reacts-to-GameState subtlety** — different pickup sounds per item. v1 plays one `pickup_ding` for everything. Add per-item cues when there are >3 item types.

---

## 18. Two interaction patterns — don't unify them

Hack The Planet has **two distinct interaction paradigms** in the codebase. This section exists so future contributors stop trying to force one into the other.

### 18.1 Auto-trigger (walk into it)

Existing pattern across `level/interactable/flag/flag_3d.gd`, `level/interactable/phone_booth/phone_booth.gd`, `level/interactable/coin/coin.gd`, `level/interactable/rail/rail.gd`, `level/interactable/kill_plane/kill_plane_3d.gd`. Shape:

- Area3D + `body_entered` signal.
- Handler filters by `body.is_in_group("player")` (or similar) — the **emitter-side filter** convention.
- Emits a broadcast on `Events` (`flag_reached`, `checkpoint_reached`, `coin_collected`).
- No input required; no prompt; no focus.

Use for: level volumes, scattered collectibles, checkpoints, hazards, grind rails.

### 18.2 Action-activated (press E)

New pattern specced in §3–§11:

- Subclass of `Interactable` (Area3D + virtual `interact(actor)`).
- Focused via `InteractionSensor`'s scored candidate loop.
- Prompt label shown while focused; outline highlight optional.
- Activated on `Intent.interact_pressed`.

Use for: doors, NPCs / dialogue triggers, narrative pickups, puzzle terminals, traps.

### 18.3 The decision tree

> **Does the player need a moment of deliberation to activate it?**
> - **Yes** → `Interactable` subclass. They need to choose to engage.
> - **No** → plain Area3D + group-filtered emit. They walk into it and the game responds.

| Interaction | Pattern | Reasoning |
|---|---|---|
| Coin / floppy disk | auto-trigger | Arcade-y feel; running pickup is the point |
| Kill plane | auto-trigger | Not a choice — it's a falling death |
| Checkpoint booth | auto-trigger | Drive-by banking; "press E to save" breaks flow |
| Flag (level end) | auto-trigger | Contact = win, no deliberation |
| Grind rail | auto-trigger | Jump onto it, commit = grind |
| Door | `Interactable` | Deliberate gate — key check, prompt, commit |
| NPC dialogue | `Interactable` | Commit to the conversation |
| Puzzle terminal | `Interactable` | Commit to the minigame |
| Narrative key pickup | `Interactable` | It's a story beat, not loot |
| Trap | `Interactable` (§10.6) | Player chooses to poke the spike |

### 18.4 Explicit non-migration

**Do not convert existing auto-triggers to `Interactable` subclasses.** Char-controller dev flagged this specifically: "checkpoint booths stay on the old Events-based path — different UX from press-E interactables." Auto-trigger interactables in `level/interactable/*` are correct as-is. Leaving them alone.

---

## 19. Sync log — character-controller dev amendments

v1.1 amendments originated from direct sync with the character-controller dev (who owns `player/body/player_body.{gd,tscn}`, `player/body/intent.gd`, `player/brains/*`, and skin contracts). Recording decisions here so the rationale survives.

| v1 decision | v1.1 replacement | Why it changed |
|---|---|---|
| `InteractionSensor` child of `PlayerBody` | Child of `PlayerBrain`; `Brain.try_activate()` base no-op; body calls `_brain.try_activate(self)` | Body is the *universal* pawn — enemies are `PlayerBody` + `EnemyAIBrain`. Senses on body = ~7 Area3Ds ticking on NPCs for nothing. "Drivers own the senses they need" mirrors existing Brain/Body/Skin separation. |
| `interact` gamepad = button 0 (A/Cross) | button 2 (X/Square) | Button 0 is already `jump`. Would double-trigger. |
| Only `interact_pressed` on Intent | Also `interact_held: bool` reserved | Free to reserve for "hold to lockpick." Brain fills regardless; consumers opt in. |
| Layer 10 (`interactable`) named in isolation | All four layers named at once in Project Settings (`world`, `player`, `enemy`, `interactable`); `Layers.gd` covers all as constants | Single source of truth. Prevents scattered magic numbers during the char-controller dev's concurrent damage-gating work. |
| Sensor always activates on `intent.interact_pressed` | Gated: suppress if `body.is_attack_active()` | Prevents accidental door-open mid-attack-swing. One-line check on sensor side; body exposes `is_attack_active()`. |
| `interactable_focused/unfocused` on `Events` bus | Local signal `InteractionSensor.focus_changed(node)`; PromptUI discovers sensor via group | 1-to-1 wire doesn't belong on a broadcast bus. Keeps bus reserved for world events multiple subsystems want. |
| `AudioCue` registry via folder auto-scan | Explicit `CueRegistry.tres` manifest; missing cues `push_error` | No silent failures. Typo in `play_sfx(&"door_opne")` becomes a loud error, not a quiet miss. |
| `Pickup` as generic "press E to collect" | `Pickup` narrative-only; arcade collectibles stay auto-trigger (§18) | Two different UX paradigms shouldn't share a base class. Running-coin-vacuum ≠ picking up a story item. |

**Char-controller dev in-flight work (ongoing, no IX conflict):** pawn_group filtering on interactables, damage gating by group, vertical attack range. IX changes in §14 preserve these.

**Stub agreement:** char-controller dev pre-commits `Brain.try_activate(_body: Node3D) -> void: pass` in `brain.gd`, unblocking IX implementation with zero risk to AI brain logic.

---

## Sources

**Godot 4.6 docs:**
- [Singletons (Autoload) — 4.6](https://docs.godotengine.org/en/4.6/tutorials/scripting/singletons_autoload.html)
- [Groups — 4.6](https://docs.godotengine.org/en/4.6/tutorials/scripting/groups.html)
- [Area3D — stable](https://docs.godotengine.org/en/stable/classes/class_area3d.html)
- [PhysicsRayQueryParameters3D — stable](https://docs.godotengine.org/en/stable/classes/class_physicsrayqueryparameters3d.html)
- [Ray-casting — stable](https://docs.godotengine.org/en/stable/tutorials/physics/ray-casting.html)
- [AudioEffectCompressor — stable](https://docs.godotengine.org/en/stable/classes/class_audioeffectcompressor.html)
- [Audio buses](https://docs.godotengine.org/en/latest/tutorials/audio/audio_buses.html)
- [Audio effects — stable](https://docs.godotengine.org/en/stable/tutorials/audio/audio_effects.html)
- [Audio streams — stable](https://docs.godotengine.org/en/stable/tutorials/audio/audio_streams.html)
- [Pausing games and process mode — stable](https://docs.godotengine.org/en/stable/tutorials/scripting/pausing_games.html)
- [Resources — saving and loading](https://docs.godotengine.org/en/stable/tutorials/scripting/resources.html)
- [File paths / user:// — stable](https://docs.godotengine.org/en/stable/tutorials/io/data_paths.html)
- [HTTPRequest — stable](https://docs.godotengine.org/en/stable/classes/class_httprequest.html)
- [4.6 release notes](https://godotengine.org/releases/4.6/)

**Known Godot issues referenced:**
- [#83160 — NOTIFICATION_PAUSED/UNPAUSED reversed under PROCESS_MODE_WHEN_PAUSED](https://github.com/godotengine/godot/issues/83160)
- [#16036 — AudioEffectCompressor sidechain (historical; resolved in 4.x)](https://github.com/godotengine/godot/issues/16036)

**Community / addon:**
- [Nathan Hoad — godot-dialogue-manager](https://github.com/nathanhoad/godot_dialogue_manager)
- [godotshaders — Simple Inverted Hull Outline (Stage 2 outline reference)](https://godotshaders.com/shader/simple-inverted-hull-outline-shader/)

**In-project references (existing):**
- `autoload/events.gd` — existing signal bus.
- `player/brains/brain.gd`, `player/brains/player_brain.gd` — Brain pattern we match.
- `player/body/intent.gd` — the Intent contract we extend.
- `player/body/player_body.gd` — the consumer we wire the sensor into.
- `docs/materials.md` — doc house style this file follows.

**Reference project (`/Users/ryanhelsing/GodotProjects/3dPFormer`) — ported from:**
- `helpers/actionable.gd` / `actionable.tscn` — the Area3D-with-`action()` pattern.
- `Scripts/player.gd` — the `get_overlapping_areas()` focus loop.
- `state.gd` — dialogue-visited tracking; item counts; bad-pattern mixing audio into state (fixed here by `Audio` listening to `Events`).
- `Scripts/GameManager.gd` — reference for generic `score`/`items_on_person` dictionary store.
- `Scripts/AudioManager.gd` — named-child AudioStreamPlayer slots; simple but loses bus/ducking structure we need.
- `dialogue_balloon/balloon.gd` — DialogueResource + DialogueLabel usage; ElevenLabs `HTTPRequest` + cache-by-md5 filename (keep); hardcoded API key (fix); `res://generated_audio/` cache path (fix to `user://`); character→voice_id map (externalize).
- `dialogue/*.dialogue` — example conversation format to carry over style.
- `project.godot` — reference for `[dialogue_manager] general/states=[...]` exposing autoloads inside `.dialogue` files.
