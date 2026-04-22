# Interactables, Dialogue & Audio Engine Spec (v1, Godot 4.6.2)

Implementation spec for the interaction system, the dialogue engine port, and the AAA audio layer that supports sidechain ducking. Every technical claim is tied to a Godot 4.6 doc page, an in-project reference file, or a file in the reference project at `/Users/ryanhelsing/GodotProjects/3dPFormer` — see **§ Sources** at the end.

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
                 │              │               │          │
 ┌───────────────────────┐    ┌─────────────────┴────┐   ┌─┴──────────┐
 │   PlayerBody          │    │ Interactable (base)  │   │ Puzzles    │
 │  ├─ Brain ─► Intent ──┼───►│  ├─ Door             │   │  └─ Hacking│
 │  └─ InteractionSensor │    │  ├─ DialogueTrigger  │   │     Puzzle │
 │        (Area3D sphere)│    │  ├─ Pickup           │   └────────────┘
 │        ↓ focused node │    │  └─ PuzzleTerminal   │
 └───────────────────────┘    └──────────────────────┘
```

**Data flow for one interaction tick:**

1. `InteractionSensor` (child of `PlayerBody`) runs every physics frame. Its `Area3D` child holds a sphere collider; it calls `get_overlapping_areas()` to get candidates in the `interactable` group.
2. Sensor scores each candidate by a weighted sum (proximity + body-forward alignment + optional camera-crosshair), picks the best.
3. When focused candidate changes, sensor emits `Events.interactable_focused(node)` / `Events.interactable_unfocused()`. The `PromptUI` autoload listens and shows/hides the label + invokes `candidate.set_highlighted(true/false)`.
4. `PlayerBrain` fills `Intent.interact_pressed` from `Input.is_action_just_pressed("interact")`.
5. `PlayerBody` on `intent.interact_pressed` calls `interaction_sensor.try_activate(self)`. Sensor calls `focused.interact(actor)` on the focused interactable. The interactable *does the thing* — opens itself, calls `Dialogue.start(...)`, calls `Puzzles.start(...)`, mutates `GameState`.
6. The interactable (or the service it called) emits lifecycle signals on `Events` — `door_opened(id)`, `dialogue_started`, `puzzle_solved` — so anyone who cares (audio, game state, analytics) can react *without* being directly wired in.

**This is the whole mental model.** No manager, no orchestrator, no routing layer. The base `Interactable` has a single virtual method and ~50 lines.

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

## 4. `InteractionSensor` — hybrid scoring, on the body

Lives as a child of `PlayerBody`. One Area3D sphere + one script.

```gdscript
class_name InteractionSensor
extends Node3D

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

## Optional: cap candidates at this dot-product floor (body.forward · dir) to
## prevent "interact with the thing behind me." -0.5 allows slight over-shoulder.
@export var facing_cutoff: float = -0.5

var focused: Interactable = null

@onready var _area: Area3D = %SensorArea
@onready var _body: CharacterBody3D = get_parent() as CharacterBody3D


func _physics_process(_delta: float) -> void:
    var best: Interactable = null
    var best_score: float = -INF
    for a in _area.get_overlapping_areas():
        var it := a as Interactable
        if it == null: continue
        if not it.can_interact(_body): continue
        var score := _score(it)
        if score > best_score:
            best_score = score
            best = it
    _set_focused(best)


func try_activate(actor: Node3D) -> void:
    if focused == null: return
    if not focused.can_interact(actor): return
    focused.interact(actor)


func _score(it: Interactable) -> float:
    var to_it := it.global_position - _body.global_position
    var dist := to_it.length()
    if dist > range: return -INF
    var dir := to_it / max(dist, 0.0001)
    var facing := _body.global_basis.z.dot(-dir)  # -Z is body "forward" in Godot
    if facing < facing_cutoff: return -INF

    var s := 0.0
    s += weight_proximity * (1.0 - dist / range)
    s += weight_body_facing * max(0.0, facing)
    if weight_camera_facing > 0.0:
        var cam := _body.get_viewport().get_camera_3d()
        if cam != null:
            var cam_facing := (-cam.global_basis.z).dot(dir)
            s += weight_camera_facing * max(0.0, cam_facing)
    return s * it.priority


func _set_focused(next: Interactable) -> void:
    if next == focused: return
    if focused != null:
        focused.set_highlighted(false)
        Events.interactable_unfocused.emit(focused)
    focused = next
    if focused != null:
        focused.set_highlighted(true)
        Events.interactable_focused.emit(focused)
```

**Why scan every physics frame, not signal-driven on body_entered/exited?** `get_overlapping_areas()` updates before `area_entered` emits in 4.x (see [Area3D docs](https://docs.godotengine.org/en/stable/classes/class_area3d.html)), so polling gives a consistent scored pick each frame. Cost is O(candidates) — for ~10 overlapping interactables (already overkill) it's a rounding error. Event-driven focus switches to a different scoring function would leak logic.

**Why `-Z` for body forward?** Godot's convention: the default `-Z` axis of a Node3D is "forward" (same as camera default). Matches the existing `player_body.gd` which already uses `global_basis.z` for its skin-facing math.

---

## 5. `Intent` extension

One field added. Everything else in the existing file (`player/body/intent.gd`) stays.

```gdscript
## Edge-triggered: true for exactly one physics tick when interact is pressed.
## Same contract as jump_pressed and attack_pressed.
var interact_pressed: bool = false
```

`PlayerBrain.tick()` fills it from `Input.is_action_just_pressed("interact")`. `PlayerBody._physics_process` reads `intent.interact_pressed` and calls `$InteractionSensor.try_activate(self)`. AI brains leave it false by default — enemies don't interact with doors (yet).

---

## 6. `Events` — extending the existing signal bus

Adds to `autoload/events.gd`. Keep the existing signals — nothing breaks.

```gdscript
# Focus / activation lifecycle (consumed by prompt UI, outline shader host)
@warning_ignore("unused_signal") signal interactable_focused(node: Interactable)
@warning_ignore("unused_signal") signal interactable_unfocused(node: Interactable)

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
- Cross-cutting (audio wants to know about dialogue starts; UI wants to know about inventory adds) → `Events`.
- Parent-child only (a door telling its own animation to play) → local signal or direct call.

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

### 8.4 `AudioCue` resource

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

`Audio.play_sfx(&"door_open")` picks a random stream from the pool, randomizes volume/pitch in the configured range, routes to the declared bus. Twenty lines.

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
| `HTTPRequest` node owned by the balloon (dies with it) | Owned by `Dialogue` autoload. Survives balloon close, lets next line fetch while previous plays. |
| Cache filename uses `md5_text().left(15)` of character+text+voice | **Keep.** Works fine, stable across runs. |
| Playback via a local `AudioStreamPlayer` in the balloon | Route through `Audio.play_dialogue(stream)` so the Dialogue bus drives sidechain ducking on Music+Ambience. **This is the whole point** — voice-over must hit the Dialogue bus to duck music. |

### 9.4 Dialogue-balloon scene

Port `dialogue_balloon/balloon.tscn` + `balloon.gd` to `res://dialogue/balloon.tscn`. Strip the TTS code out (now in `Dialogue`); keep the typed-out line rendering, response menu, and `State.visit_dialogue(...)` calls (now `GameState.visit_dialogue(...)`).

Balloon node's `process_mode = PROCESS_MODE_WHEN_PAUSED` so the game freezes under it but the balloon updates.

**Deferred:** portrait lookup improvements, controller-button glyph on responses. Port as-is first.

---

## 10. The concrete interactables (each is tiny)

### 10.1 Physics layers

Assigned once in Project Settings → Layer Names → 3D Physics:

| Layer # | Name | Used by |
|---|---|---|
| 1 | `world` | existing static geo |
| 2 | `player` | PlayerBody |
| 3 | `enemy` | Enemy |
| 10 | `interactable` | All `Interactable` subclasses |

A `Layers.gd` autoload or const file exposes `const INTERACTABLE = 1 << 9` for code use.

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

### 10.4 `Pickup`

```gdscript
class_name Pickup
extends Interactable

@export var item_id: StringName

func interact(_actor: Node3D) -> void:
    GameState.add_item(item_id)  # fires Events.item_added → Audio plays ding
    queue_free()
```

### 10.5 `PuzzleTerminal`

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
, Object(InputEventJoypadButton,...,"button_index":0,...)
]
}
```

`physical_keycode 69` = `E`. `button_index 0` = A on Xbox / Cross on PlayStation / B on Switch (Godot uses the Xbox convention).

Collides with nothing existing. `toggle_skate` is on `Q`, `attack` on `J`+mouse, `jump` on `Space`.

---

## 14. Integration points with existing code

Minimally invasive. Files touched:

| File | Change |
|---|---|
| `autoload/events.gd` | Add signals from §6. No removals. |
| `player/body/intent.gd` | Add `interact_pressed: bool = false`. |
| `player/brains/player_brain.gd` | Fill `_intent.interact_pressed = Input.is_action_just_pressed("interact")`. |
| `player/body/player_body.gd` | In `_physics_process` after reading intent: `if intent.interact_pressed and _sensor: _sensor.try_activate(self)`. Add `@onready var _sensor: InteractionSensor = $InteractionSensor` (optional — absent on NPC pawns). |
| `player/body/player_body.tscn` (or the player pawn scene wrapping it) | Add `InteractionSensor` child with an `Area3D` child with a `SphereShape3D` of radius 2.5. |
| `project.godot` | Add the four new autoloads (`GameState`, `Audio`, `Dialogue`, `Puzzles`). Add `interact` InputMap action. Enable `dialogue_manager` plugin. Add `[dialogue_manager]` section. |
| `default_bus_layout.tres` | Replace with the 5-bus layout from §8.1. |

**AI brains (`enemy_ai_brain.gd`, `scripted_brain.gd`) unchanged** — they'll leave `Intent.interact_pressed = false`, and NPC bodies won't have an `InteractionSensor` child. Zero risk of enemies stealing your door.

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
  prompt_ui.gd / prompt_ui.tscn      <-- NEW (CanvasLayer autoload)
  layers.gd                          <-- NEW (physics-layer constants)
audio/
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
  interaction_sensor.gd / .tscn
  door/        door.gd / .tscn
  dialogue_trigger/  dialogue_trigger.gd / .tscn
  pickup/      pickup.gd / .tscn
  puzzle_terminal/   puzzle_terminal.gd / .tscn
puzzle/
  puzzle.gd
  hacking/ hacking_puzzle.gd / .tscn
player/body/
  intent.gd                          <-- +interact_pressed
  player_body.gd                     <-- +sensor hookup
  player_body.tscn                   <-- +InteractionSensor child
player/brains/
  player_brain.gd                    <-- +interact_pressed fill
default_bus_layout.tres              <-- REPLACED (5 buses w/ sidechain)
project.godot                        <-- autoloads, InputMap, plugin, dialogue_manager section
user:// (runtime)
  tts_cache/*.mp3                    <-- generated at runtime
  tts_config.tres                    <-- API key (gitignored)
```

---

## 16. Open risks before prototype

1. **Third-person hybrid scoring feel.** `weight_camera_facing = 0.2` is a guess. If the camera bias is too strong (player turning camera randomly retargets focus), drop to `0.0`. If too weak (player can't choose between two adjacent interactables), raise to `0.4`. Tune against a scene with 3+ close interactables.
2. **ElevenLabs latency on first line.** A cold-cache response can take 1–3 seconds. The balloon should show the text immediately and play TTS whenever it arrives — don't block on the request. Reference code does this correctly; preserve that.
3. **Sidechain threshold tuning.** `-30 dB` threshold assumes music is sitting around `-20 dB` average. If music mix is quieter, dialogue won't trigger ducking. Verify with a scene after music tracks are in.
4. **`PROCESS_MODE_WHEN_PAUSED` notification reversal** ([godot#83160](https://github.com/godotengine/godot/issues/83160)). We don't rely on the notifications, but if a future contributor does, they'll be confused. Note it in a code comment at the pause site.
5. **Input handling during dialogue/puzzle.** Balloon + Puzzle call `get_viewport().set_input_as_handled()` to swallow `interact` presses. Verify `PlayerBrain._unhandled_input` doesn't re-process them. Existing project uses `_input`/`_unhandled_input` inconsistently — audit during wiring.
6. **Outline Stage 1 emission tween on shared materials.** If two interactables share a material (common with pickups), highlighting one lights both. Fix: `surface_material_override` or per-instance material duplication at `_ready()`. Known Godot gotcha; trivial once you hit it.

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
