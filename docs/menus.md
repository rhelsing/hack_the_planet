# Menus / Save / Settings / Pause / Scene-loader Spec (v1, Godot 4.6.2 Forward+)

Frontend umbrella: main menu, pause menu, settings menu, save/load slots, scene loader, and transitions. Sibling to `docs/materials.md` (shader materials + graphics preset values) and `docs/interactables.md` (GameState, Events, Audio, Dialogue — the runtime services this spec plugs into).

> **Sync rule:** This doc owns its domain (§0). Where it depends on siblings, it cites them by section — see §13 for the full contract surface and §13.3 for open contracts (yes/no questions the sibling devs need to resolve before implementation).
>
> **Amendment log:**
> - **v1** — initial spec.
> - **v1.1 amendments (2026-04-22)** — from `sync_up.md`:
>   1. Open contract (a) resolved: char_dev ships `PlayerBody.get_save_dict()` / `load_save_dict(d)` (not `apply_player_state`).
>   2. Open contract (b) resolved: `current_level` + `playtime_s` owned by `SaveService`, not `GameState`.
>   3. Open contract (c) resolved: pause menu swallows Esc during dialogue/puzzle (`PauseController.user_pause_allowed` flips off).
>   4. Single-writer pattern: `interactables_dev`'s `Audio` autoload owns **all** `AudioServer.set_bus_volume_db` writes. Settings just persists `audio.*_volume_db` keys.
>   5. Gamepad `interact` → **X (button_index 2)**, not B (avoids `ui_cancel` collision).
>   6. `camera.invert_y` default = **true** (char_dev's authored default).
>   7. `Events.modal_count_reset()` added as dev escape hatch.
>
> **v1 shipped state (ui_dev, 2026-04-22):**
> - All 4 autoloads (`Settings`, `SceneLoader`, `SaveService`, `PauseController`) shipped + wired in `project.godot` (autoload order matters — `SceneLoader` before `SaveService`).
> - All 8 menu scenes shipped (`main_menu`, `menu_world`, `pause_menu`, `settings_menu`, `save_slots`, `credits`, `scene_loader`, `menu_button`).
> - Transition system (`instant`, `glitch` + shader) shipped AND wired into `SceneLoader.goto()` — scene changes fade through the user-selected style.
> - `Events` extended additively with 7 signals; no removals.
> - `project.godot`: main scene is `res://menu/main_menu.tscn`; `pause` InputMap action added.
> - `game.tscn`: `PauseMenu` child instance added.
> - Tests: `res://tests/test_events_signals.gd` (`--script` mode) + `res://tests/test_runner.tscn` (scene mode: 4 suites — `menus_smoke`, `pause_controller`, `settings`, `save_service`).
> - Verified: full-boot headless (`godot --headless --path . --quit-after 60`) emits zero errors from ui_dev-owned files.
>
> **Known v1 limitations (deferred per §17):**
> - SFX cues (`ui_move` / `ui_confirm` / `ui_back` / `ui_type`) referenced but `.tres` files not authored — waits on `interactables_dev`'s `AudioCue` class shipping.
> - JetBrains Mono bundled font skipped; `SystemFont` with fallback chain instead.
> - End-to-end pause/resume and save/load round-trip not exercised by automated tests — covered via full-boot smoke only.
> - CRT overlay shader deferred to v1.1.
>
> **How to run the tests** (from the project root):
> ```
> godot --headless --path . --script res://tests/test_events_signals.gd --quit
> godot --headless --path . res://tests/test_runner.tscn
> ```

---

## 0. Project facts that constrain everything

| Fact | Value | Source |
|---|---|---|
| Engine version | **Godot 4.6.2 stable** | [`materials.md §0`](materials.md) |
| Renderer | **Forward+** | same |
| Release target | **Desktop only** | same |
| Doc house style | `materials.md`, `interactables.md` | same |
| Main scene (after change) | `res://menu/main_menu.tscn` | new |
| Boot flow | Menu-first. `Continue` resumes last save; disabled if no save exists. | user direction |
| UI aesthetic | **Terminal** — monospace, cyan/green on black, unicode box borders, optional CRT overlay | user direction |
| Save slots | Fixed `A / B / C` (no rename) + one hidden `autosave` | user direction |
| Autosave trigger | `Events.checkpoint_reached` (phone-booth touch; signal already in `autoload/events.gd`) | same |
| Settings file | `user://settings.cfg` (`ConfigFile`) | Godot idiom |
| Save files | `user://save_slot_<id>.json` + `user://save_slot_<id>.meta.json` | this doc §8.2 |
| Audio sliders | Master / Music / SFX (3) | user direction |
| Graphics presets | Low / Medium (default) / High / Max — preset *values* live in `materials.md §2.5` | same |
| Nav inputs | Arrow keys + mouse + gamepad D-pad, all concurrent. `ui_accept` = Enter / A button, `ui_cancel` = Esc / B button. Pause = Esc / Start button. | user direction |
| Transitions | Instant + glitch, swappable by Settings choice | user direction |
| Main menu items | Continue · New Game · Load · Settings · Credits · Quit | user direction |

**User-confirmed decisions (this conversation):**
1. Main menu uses a **dedicated 3D fly-through world** (`res://menu/menu_world.tscn`), not a stripped `level.tscn`.
2. First-run boot → main menu; `Continue` goes to last save.
3. Autosave **only** on `checkpoint_reached`; explicit save allowed from pause menu.
4. No slot renaming.
5. Terminal UI aesthetic.
6. Scene loader shown for any scene transition that loads a new `PackedScene` (not for overlays).

---

## 1. Godot 4.6 primitives we lean on

None of this is custom framework. All first-party engine features listed so future contributors know where to read the docs.

| Primitive | Used for | Source |
|---|---|---|
| Autoloads | `Settings`, `SaveService`, `SceneLoader`, `PauseController` as zero-import global services | [Singletons (Autoload) — 4.6](https://docs.godotengine.org/en/4.6/tutorials/scripting/singletons_autoload.html) |
| `ConfigFile` | `user://settings.cfg` with sections `[audio]`, `[graphics]`, `[ui]` | [ConfigFile](https://docs.godotengine.org/en/stable/classes/class_configfile.html) |
| `ResourceLoader.load_threaded_request` / `load_threaded_get_status` | Async scene loading with progress | [Background loading](https://docs.godotengine.org/en/stable/tutorials/io/background_loading.html) |
| `FileAccess` + `JSON.stringify` / `JSON.parse_string` | Save slot files (matches `interactables.md §7`'s `to_dict`/`from_dict` contract) | [JSON](https://docs.godotengine.org/en/stable/classes/class_json.html); [FileAccess](https://docs.godotengine.org/en/stable/classes/class_fileaccess.html) |
| `CanvasLayer` + `Control` with `process_mode = PROCESS_MODE_WHEN_PAUSED` | Pause menu survives `get_tree().paused = true` | [Pausing games and process mode](https://docs.godotengine.org/en/stable/tutorials/scripting/pausing_games.html) |
| `Path3D` + `PathFollow3D` | Camera rail for main menu fly-through | [PathFollow3D](https://docs.godotengine.org/en/stable/classes/class_pathfollow3d.html) |
| `AudioServer.set_bus_volume_db` + `linear_to_db` | Audio sliders drive real bus volumes on the 5-bus layout from `interactables.md §8.1` | [AudioServer](https://docs.godotengine.org/en/stable/classes/class_audioserver.html) |
| `SubViewport` + `get_texture().get_image()` | 64×36 save-slot screenshot thumbnails | [SubViewport](https://docs.godotengine.org/en/stable/classes/class_subviewport.html) |
| `Control.focus_neighbor_*` + `grab_focus` | Keyboard + gamepad nav through menus | [Control](https://docs.godotengine.org/en/stable/classes/class_control.html) |
| `Marshalls.raw_to_base64` / `base64_to_raw` | Encode screenshot PNG bytes into slot metadata | [Marshalls](https://docs.godotengine.org/en/stable/classes/class_marshalls.html) |

**4.6-specific notes:**
- `NOTIFICATION_PAUSED` / `NOTIFICATION_UNPAUSED` are **reversed** under `PROCESS_MODE_WHEN_PAUSED` ([godot#83160](https://github.com/godotengine/godot/issues/83160)). This spec checks `get_tree().paused` directly, same pattern as `interactables.md §1`.
- `ResourceLoader.load_threaded_get_status` `progress[0]` can stay at `0.0` until `THREAD_LOAD_LOADED` on some backends ([#56882](https://github.com/godotengine/godot/issues/56882), [#90076](https://github.com/godotengine/godot/issues/90076)). SceneLoader falls back to an indeterminate spinner when progress hasn't advanced in 250ms.

---

## 2. Architecture in one page

```
┌─────────────────────────────────────────────────────────────────────┐
│  Autoloads (globally reachable by name — NO imports)                │
│                                                                     │
│   Existing (from interactables.md + current):                       │
│     Events   GameState   Audio   Dialogue   DebugPanel              │
│                                                                     │
│   NEW (this doc):                                                   │
│     Settings  SaveService  SceneLoader  PauseController             │
└─────────────────────────────────────────────────────────────────────┘
         ▲              ▲              ▲              ▲
         │              │              │              │
 ┌───────┴───────┐  ┌───┴────┐  ┌──────┴───────┐  ┌───┴──────┐
 │ Settings UI   │  │ Save/  │  │ Scene Loader │  │ Pause    │
 │ (sliders,     │  │ Load   │  │ UI (progress │  │ Menu UI  │
 │  preset       │  │ UI     │  │  bar +       │  │ (Control,│
 │  dropdown)    │  │ (A/B/C │  │  flavor)     │  │  WHEN_   │
 │               │  │  cards)│  │              │  │  PAUSED) │
 └───────────────┘  └────────┘  └──────────────┘  └──────────┘

 ┌──────────────────────────────────────────────────────────────────┐
 │ Main Menu scene (res://menu/main_menu.tscn)                      │
 │   ├── MenuWorld (3D, Path3D + PathFollow3D + Camera3D)           │
 │   └── MenuUI (CanvasLayer: Title + VBox of buttons)              │
 └──────────────────────────────────────────────────────────────────┘

 ┌──────────────────────────────────────────────────────────────────┐
 │ Gameplay (game.tscn — existing, unchanged except pause hookup)   │
 └──────────────────────────────────────────────────────────────────┘
```

**Legend:** solid arrows = direct calls / signal wiring. All inter-subsystem chatter goes through `Events`; 1-to-1 wiring (e.g., SaveSlots UI → SaveService) is a local signal or direct call.

**Rule for bus vs. local signal (reaffirmed from `interactables.md §6`):**
- Cross-cutting: `Events.game_saved(slot)`, `Events.settings_applied`.
- 1-to-1: SaveSlots UI calls `SaveService.save_to_slot("a")` directly.

---

## 3. New autoloads

Each is a thin script. Sizes in the inline comments are estimates; if any grows past ~150 lines we split.

### 3.1 `Settings` — ConfigFile-backed, applies on load/change

```gdscript
extends Node
## Owns user preferences. Loads user://settings.cfg at startup, applies the
## resulting state to AudioServer / WorldEnvironment / materials. Emits
## Events.settings_applied whenever apply() completes.

const PATH := "user://settings.cfg"
const DEFAULTS := {
    "audio": {"master": 0.85, "music": 0.75, "sfx": 0.9},
    "graphics": {"quality": "medium", "transition_style": "glitch"},
}

var data: Dictionary = DEFAULTS.duplicate(true)

func _ready() -> void:
    load_from_disk()
    apply()

func load_from_disk() -> void:
    var cf := ConfigFile.new()
    if cf.load(PATH) != OK: return
    for section in data.keys():
        for key in data[section].keys():
            data[section][key] = cf.get_value(section, key, data[section][key])

func save_to_disk() -> void:
    var cf := ConfigFile.new()
    for section in data.keys():
        for key in data[section].keys():
            cf.set_value(section, key, data[section][key])
    cf.save(PATH)

func apply() -> void:
    _apply_audio()
    _apply_graphics()
    Events.settings_applied.emit()

## Callable from Settings UI. "audio.master" -> 0..1 linear; converted to dB
## for AudioServer internally.
func set_value(section: String, key: String, value) -> void:
    data[section][key] = value
    save_to_disk()
    apply()
```

- **Audio apply:** `Settings` persists the `audio.*_volume_db` keys but does *not* write to `AudioServer`. Per sync_up 2026-04-22, `interactables_dev`'s `Audio` autoload is the single writer to `AudioServer.set_bus_volume_db` for all 5 buses. `Audio._ready` subscribes to `Events.settings_applied` and re-reads the 5 audio keys.
- **Graphics apply:** maps `data.graphics.quality` to the preset tables in `materials.md §2.5` — toggles `ssr_enabled`, `ssil_enabled`, `volumetric_fog_density`, `msaa_3d`, `use_taa` on the active `WorldEnvironment`; writes shader uniform overrides to `platforms.tres` / `buildings.tres` via `ShaderMaterial.set_shader_parameter(...)`. See §7.2 for the preset→property mapping.

### 3.2 `SaveService` — the deferred service from interactables.md §17, owned here

```gdscript
extends Node
## Multi-slot save. interactables.md §17 deferred this; we own it now.
## File format: see §8.2. Listens to Events.checkpoint_reached for autosave.

const SLOTS := [&"a", &"b", &"c", &"autosave"]
const VERSION := 1

func _ready() -> void:
    Events.checkpoint_reached.connect(_on_checkpoint_reached)

func has_slot(id: StringName) -> bool:
    return FileAccess.file_exists(_save_path(id))

func slot_metadata(id: StringName) -> Dictionary:
    # Reads the adjacent .meta.json (fast — no full save parse).
    var p := _meta_path(id)
    if not FileAccess.file_exists(p): return {}
    var f := FileAccess.open(p, FileAccess.READ)
    return JSON.parse_string(f.get_as_text()) as Dictionary

func save_to_slot(id: StringName) -> void:
    var payload := {
        "version": VERSION,
        "timestamp": Time.get_unix_time_from_system(),
        "level_id": GameState.current_level,          # see §13.3 open contract
        "playtime_s": GameState.playtime_s,
        "game_state": GameState.to_dict(),            # interactables.md §7
        "player_state": _capture_player_state(),       # see §13.3 open contract
    }
    _write_json(_save_path(id), payload)
    _write_meta(id, payload)
    Events.game_saved.emit(id)

func load_from_slot(id: StringName) -> void:
    if not has_slot(id): return
    var f := FileAccess.open(_save_path(id), FileAccess.READ)
    var d := JSON.parse_string(f.get_as_text()) as Dictionary
    GameState.from_dict(d.get("game_state", {}))
    _pending_player_state = d.get("player_state", {})
    Events.game_loaded.emit(id)
    SceneLoader.goto(_level_scene_path(d.get("level_id", "")))

## After the scene loads (via SceneLoader.scene_entered), apply player state.
func _on_scene_entered(scene: Node) -> void:
    if _pending_player_state.is_empty(): return
    var player := scene.get_node_or_null("Player")
    if player and player.has_method(&"apply_player_state"):
        player.apply_player_state(_pending_player_state)
    _pending_player_state = {}
```

### 3.3 `SceneLoader` — the threaded loader + loader UI host

```gdscript
extends Node
## Owns the loader UI + ResourceLoader.load_threaded_request lifecycle.
## Use SceneLoader.goto("res://path/to/scene.tscn") anywhere.

signal scene_entered(scene: Node)

@onready var _loader_ui: PackedScene = preload("res://menu/scene_loader.tscn")

var _target_path: String = ""
var _active_ui: CanvasLayer = null
var _progress: Array[float] = [0.0]

func goto(path: String) -> void:
    if _target_path != "": return  # already loading
    _target_path = path
    _active_ui = _loader_ui.instantiate()
    get_tree().root.add_child(_active_ui)
    ResourceLoader.load_threaded_request(path)
    set_process(true)

func _process(_delta: float) -> void:
    var status := ResourceLoader.load_threaded_get_status(_target_path, _progress)
    _active_ui.set_progress(_progress[0])  # loader UI shows bar OR spinner
    match status:
        ResourceLoader.THREAD_LOAD_LOADED:
            var packed := ResourceLoader.load_threaded_get(_target_path) as PackedScene
            var tree := get_tree()
            tree.change_scene_to_packed(packed)
            # Defer one frame so the new scene is in-tree before emitting.
            await tree.process_frame
            scene_entered.emit(tree.current_scene)
            _active_ui.queue_free()
            _target_path = ""
            set_process(false)
        ResourceLoader.THREAD_LOAD_FAILED, ResourceLoader.THREAD_LOAD_INVALID_RESOURCE:
            push_error("SceneLoader failed: %s" % _target_path)
            _active_ui.queue_free()
            _target_path = ""
            set_process(false)
```

### 3.4 `PauseController` — tiny wrapper around `get_tree().paused`

```gdscript
extends Node
## Owns pause state and the ESC/Start global listener. Pause menu scene
## listens to `paused_changed`.

signal paused_changed(is_paused: bool)

## Some subsystems (dialogue, puzzle) pause the tree themselves and don't
## want the user-facing pause menu on top of their UI. They set this false.
var user_pause_allowed: bool = true

func _unhandled_input(event: InputEvent) -> void:
    if not event.is_action_pressed("pause"): return
    if not user_pause_allowed: return
    toggle()
    get_viewport().set_input_as_handled()

func toggle() -> void:
    set_paused(not get_tree().paused)

func set_paused(v: bool) -> void:
    if get_tree().paused == v: return
    get_tree().paused = v
    paused_changed.emit(v)
    if v: Events.menu_opened.emit(&"pause")
    else: Events.menu_closed.emit(&"pause")
```

---

## 4. Menu system overview

The frontend is a **scene-graph-driven** state machine — no central state enum. Each menu is its own scene. Transitions between them go through either:

- **Sibling swap** (instant) — free the current menu scene, instantiate the next under the same `CanvasLayer`. Used between main-menu sub-screens (Settings → back to main, etc.).
- **`SceneLoader.goto(...)`** — only for the main-menu → gameplay jump, or gameplay → main-menu return. Anything that actually loads a new `PackedScene`.

No full-frame modal state to track. "Are we on the main menu?" = "is `get_tree().current_scene` `main_menu.tscn`?"

---

## 5. Main menu

### 5.1 Menu world (`res://menu/menu_world.tscn`)

A dedicated 3D scene — does not reuse `level.tscn`. Components:

- A small skyline of `CSGBox3D` + `CSGPolygon3D` buildings using `buildings.tres`. Tight cluster — camera flies between them.
- A ground slab of `platforms.tres`.
- Moon + sky from the existing `sky_with_stars.tres` shader (reuse).
- A `Path3D` defining a looping spline roughly at rooftop height.
- A `PathFollow3D` (child of the path) with `loop = true`; a Camera3D parented to it.
- A `MenuCamera` script on the Camera3D adds subtle idle-wiggle via `FastNoiseLite` (translation jitter ±0.03m, rotation jitter ±0.5°) — cinematic-handheld feel. Pattern cribbed from [meloonics/3D-Menu-Cam](https://github.com/meloonics/3D-Menu-Cam).
- An `AnimationPlayer` tween drives `PathFollow3D.progress_ratio` 0→1 over 45 s and loops.
- Same `WorldEnvironment` settings as gameplay (SSR + volumetric fog + bloom all on) so the menu looks like a real slice of the world.

### 5.2 Main menu UI (`res://menu/main_menu.tscn`'s CanvasLayer child)

- Fullscreen `Control` root with terminal palette (§12).
- Top-centered title banner: `HACK THE PLANET` typewriter-revealed on scene enter (Tween over 0.9 s, one char at a time, terminal beep SFX per char via `Audio.play_sfx(&"ui_type")`).
- A centered VBox of 6 `MenuButton` nodes (terminal-themed, see §12):
  1. `Continue` — visible only if `SaveService.has_slot(&"autosave")` or any of `a/b/c`; otherwise disabled + dimmed with `[No save found]` suffix.
  2. `New Game` — `SceneLoader.goto("res://game.tscn")` after a `GameState.reset()` call.
  3. `Load` — push `save_slots.tscn` in "load" mode (§8.3).
  4. `Settings` — push `settings_menu.tscn`.
  5. `Credits` — push `credits.tscn`.
  6. `Quit` — `get_tree().quit()` (with a confirm prompt if any save-slot was written this session; bypass otherwise).
- Arrow keys / D-pad navigate via `focus_neighbor_top/bottom`. Mouse click also works. `Enter`/A confirms. `Esc`/B on main menu = noop (or focus `Quit`).

### 5.3 "Continue" logic

- If `autosave` exists, `Continue` loads that.
- If not but a manual slot exists, `Continue` loads the most recent (by timestamp from `.meta.json`).
- If no saves at all, button is disabled.

---

## 6. Pause menu

`res://menu/pause_menu.tscn` — `CanvasLayer` + root `Control` with `process_mode = PROCESS_MODE_WHEN_PAUSED`.

Added as a **child of `game.tscn`**, `visible = false` until `PauseController.paused_changed(true)` fires. Not an autoload — only present in gameplay scenes.

Items (terminal-themed buttons, same as main menu):
1. `Resume` — `PauseController.set_paused(false)`.
2. `Save` — push `save_slots.tscn` in save mode.
3. `Load` — push `save_slots.tscn` in load mode.
4. `Settings` — push `settings_menu.tscn`.
5. `Quit to Main Menu` — `PauseController.set_paused(false)` then `SceneLoader.goto("res://menu/main_menu.tscn")`.
6. `Quit to Desktop` — confirm prompt → `get_tree().quit()`.

**Visual:** game rendered frozen underneath; on top we draw a full-screen semi-transparent `ColorRect` (`Color(0, 0, 0, 0.55)`) plus a one-frame scanline sweep when opening (Tween-driven y offset on a gradient ColorRect, ~200 ms). Terminal panel appears on top.

**Suppression rule:** if `Dialogue.is_open()` (interactables.md §9.2) returns true, set `PauseController.user_pause_allowed = false` for its duration, then restore. Pause menu should not layer on top of dialogue — dialogue is already a "paused with its own UI" modal.

---

## 7. Settings menu

`res://menu/settings_menu.tscn`. Tabbed layout (Audio / Graphics). Back button returns to whatever pushed it (main menu or pause menu).

### 7.1 Audio tab

Three labeled `HSlider`s, range 0..1, step 0.01, current value from `Settings.data.audio.*`:
- Master
- Music
- SFX

On `value_changed`: `Settings.set_value("audio", "master", v)` → triggers `apply()` → `AudioServer.set_bus_volume_db(Bus.MASTER, linear_to_db(v))`. Real-time feedback — drag the slider while a test tone plays from `Audio.play_sfx(&"ui_volume_preview")`.

### 7.2 Graphics tab

**Preset dropdown** (`OptionButton`): Low / Medium / High / Max. Default Medium.

On change, `Settings.data.graphics.quality = <choice>` → `apply()` reaches into materials + environment:

| Preset | Shader uniforms | Environment |
|---|---|---|
| **Max** | full `pit_strength`/`smudge_strength`/`scratch_strength` from `materials.md §2.5` ("Ultra" preset values) | `ssr_enabled=true, ssr_max_steps=48, ssil_enabled=true, sdfgi_enabled=true, glow_enabled=true, volumetric_fog_density=0.01, msaa_3d=2, use_taa=true` |
| **High** | same shader | `sdfgi_enabled=false, volumetric_fog_density=0.005`, rest as Max |
| **Medium** (default) | `pit_strength=0, smudge=0.15` | `ssr_max_steps=16, ssil=false, vol_fog=0, taa=false` |
| **Low** | `pit=0, smudge=0, scratch=0, pulse_density=0.3, code_opacity=0` | `ssr=false, ssil=false, ssao=false, sdfgi=false, vol_fog=0, msaa=0, taa=false` |

**Transition style dropdown:** `Instant` / `Glitch`. Drives `Settings.data.graphics.transition_style`, read by the transition system (§10).

Additional toggles deferred to v1.1: fullscreen/windowed, resolution, vsync, individual feature overrides.

### 7.3 Persistence

Every change calls `Settings.set_value(...)` which: mutates `data`, writes `user://settings.cfg` immediately (small file, no debounce needed), re-calls `apply()`, emits `Events.settings_applied`.

---

## 8. Save / Load menus (slots A / B / C)

Shared scene `res://menu/save_slots.tscn` with a mode flag (`save` vs `load`) set by the pusher.

### 8.1 Slot IDs

`&"a"`, `&"b"`, `&"c"`, plus `&"autosave"` (hidden, never directly selectable from the slot grid; surfaces only through `Continue` on main menu).

### 8.2 File format

**Main payload — `user://save_slot_<id>.json`:**

```json
{
  "version": 1,
  "timestamp": 1760000000,
  "level_id": "level_01",
  "playtime_s": 3600.0,
  "game_state": {
    "inventory": ["floppy_disk_01", "key_server_room"],
    "flags": { "mainframe_hacked": true },
    "dialogue_visited": { "troll": { "...": true } },
    "version": 1
  },
  "player_state": {
    "position": [2.4, 0.0, -7.8],
    "velocity": [0.0, 0.0, 0.0],
    "facing_yaw": 1.57,
    "camera_yaw": 1.57,
    "camera_pitch": -0.2,
    "is_skating": false
  }
}
```

`game_state` is verbatim `GameState.to_dict()` from `interactables.md §7`. `player_state` is new to this doc — shape is a contract with the character-controller dev (§13.3 open contract a).

**Metadata sidecar — `user://save_slot_<id>.meta.json`:**

Small, fast to read. Slot-list UI reads only this, never the full save.

```json
{
  "timestamp": 1760000000,
  "level_id": "level_01",
  "level_display": "The Mainframe",
  "playtime_s": 3600.0,
  "screenshot_b64": "<base64-PNG 64x36>"
}
```

### 8.3 Save / Load UI

Row of 3 cards (A, B, C). Autosave card below, smaller, read-only (shown in load mode, not save mode).

Each card displays from `slot_metadata()`:
- Slot letter (`A`, `B`, `C`).
- Screenshot thumbnail (64×36 — a `TextureRect` whose texture is rebuilt from `slot.screenshot_b64`).
- Level display name.
- Formatted timestamp (`"2026-04-22 14:31"`) + playtime (`"1h 02m"`).
- `[Empty]` if no file.

**In save mode:** confirm click → `SaveService.save_to_slot(id)` → re-populate card.
**In load mode:** confirm click → `SaveService.load_from_slot(id)` → `SceneLoader.goto(level)` → close menu stack.

Navigation: Left/Right (or A/D / D-pad) between cards. Enter/A confirms. Esc/B backs out.

### 8.4 Autosave behavior

Connected in `SaveService._ready()`:
```gdscript
Events.checkpoint_reached.connect(_on_checkpoint_reached)
func _on_checkpoint_reached(_pos: Vector3) -> void:
    save_to_slot(&"autosave")
```

Autosave has no save-confirmation UI, no sound effect, no toast. It's silent. (Optionally add a subtle terminal blip at the corner of the screen — deferred.)

### 8.5 Screenshot capture

In `SaveService.save_to_slot`: request a screenshot via `get_viewport().get_texture().get_image()`, downscale to 64×36 via `Image.resize(64, 36, Image.INTERPOLATE_LANCZOS)`, `save_png_to_buffer()`, `Marshalls.raw_to_base64()`. Add to `.meta.json`. ~100ms cost on save — acceptable.

---

## 9. Scene loader (progress UI)

`res://menu/scene_loader.tscn` — a `CanvasLayer` with fullscreen terminal-themed panel:

- Centered: `LOADING...` label with animated trailing dots.
- Below: a `ProgressBar` styled as `[████████░░░░░░] 53%`. When `progress[0]` hasn't advanced in 250ms (common Godot quirk), swap to an `[░░░░░█░░░░░░░░]` bouncing-indeterminate animation instead.
- Flavor text rotator underneath: 2–3 second slots cycling hacker-flavored hints picked from a pool.

Instantiated and killed by `SceneLoader` (§3.3). Uses the same font / palette as all other menus.

**Flavor text pool** (grows over time; starting set):
- "Never trust a terminal you can't physically unplug."
- "The only way to win is not to play... except here."
- "She's 17 and doesn't know it's a felony."
- "Backdoor's in the BIOS."
- "Grind rails. Crash mainframes."

---

## 10. Transition effects — pluggable, two implementations for v1

Transitions are used when the scene-graph state changes (main menu → gameplay, pause menu → main menu, etc.). The effect played out of the old state and into the new state.

**Interface:**
```gdscript
class_name Transition
extends RefCounted
## Call play_out → await finished → swap scene → call play_in → await finished.
## root: the CanvasLayer the transition draws onto (usually shared overlay).
func play_out(root: CanvasLayer) -> Signal: return Signal()
func play_in(root: CanvasLayer) -> Signal: return Signal()
```

**`InstantTransition`** — no-op, emits finished next frame.

**`GlitchTransition`** — a full-screen `ColorRect` with a custom `glitch.gdshader`:
- RGB-channel split (offset red/green/blue UVs) growing over 180 ms.
- Horizontal scanline tear (displaces rows by hash-driven noise).
- Fades to solid palette black, holds 80 ms, then fades out with the same glitch.
- ~350 ms total one-way.

Selected by `Settings.data.graphics.transition_style`. Instant is the default fallback — if the user selects Glitch but the shader fails to compile, we log a warning and use Instant.

Shader lives at `res://menu/transitions/glitch.gdshader` — styled to match the terminal aesthetic (monochrome cyan/green tint in the RGB split).

---

## 11. Input

### 11.1 InputMap additions (`project.godot`)

Only `pause` is new. `ui_accept`, `ui_cancel`, `ui_up/down/left/right` are built-in defaults.

```ini
pause={
"deadzone": 0.5,
"events": [
  Object(InputEventKey, ..., "physical_keycode": 4194305, ...),  # Escape
  Object(InputEventJoypadButton, ..., "button_index": 6, ...)    # Select / Back
]
}
```

`interactables.md §13` added `interact`. No collision with `pause`.

**Collision check against `project.godot` as of today:**
- `toggle_fullscreen` on F11 — no conflict.
- `interact` (from interactables.md) on `E` + gamepad X — no conflict.
- `jump` on Space + A — no conflict.
- `attack` on J + mouse left — no conflict.

### 11.2 Focus management

Every menu scene grabs focus on `_ready`:
```gdscript
func _ready() -> void:
    %FirstButton.grab_focus()
```

Each `MenuButton` declares `focus_neighbor_top` / `focus_neighbor_bottom` to its sibling buttons. Lateral neighbors set to `.` (same button) unless there's a horizontal peer (like the A/B/C slot cards, which use `focus_neighbor_left/right`).

Mouse-over automatically grabs focus (`MenuButton._mouse_entered` → `grab_focus`) so keyboard + mouse agree on which item is selected.

### 11.3 Handled-input discipline

Menu buttons that accept `ui_accept` call `get_viewport().set_input_as_handled()` inside their pressed handler to prevent the event leaking to the game underneath. Same pattern as `interactables.md §11.2`'s `HackingPuzzle`.

---

## 12. Visual style (terminal aesthetic)

The whole frontend rides one `menu_theme.tres` + one optional CRT overlay shader.

### 12.1 Palette

| Role | Hex | Use |
|---|---|---|
| `bg_black` | `#000000` | All panel backgrounds |
| `primary_green` | `#33FF66` | Body text, button labels |
| `accent_cyan` | `#00FFFF` | Titles, focused/selected highlights |
| `dim_green` | `#198833` | Disabled state |
| `alert_red` | `#FF5577` | Destructive confirmations (`Quit to Desktop`) |
| `terminal_bg` | `rgba(0, 20, 10, 0.85)` | Panel backgrounds (over 3D menu world) |

### 12.2 Typography

- `JetBrains Mono` (bundled via `res://menu/fonts/JetBrainsMono-Regular.ttf`) or `Cousine` if we want a free-distribution fallback.
- All menu text uses the monospace font at either 18 (body) or 28 (title) px.

### 12.3 Box borders

Unicode box-drawing rendered as Labels:
```
┌──────────────────────────────────┐
│  > NEW GAME                      │
│    LOAD                          │
│    SETTINGS                      │
│    CREDITS                       │
│    QUIT                          │
└──────────────────────────────────┘
```
`>` prefix marks focus. No artful corners, no gradients. A deliberate "terminal from 1993" look.

### 12.4 Optional CRT overlay

`res://menu/crt_overlay.gdshader` — scanlines + slight barrel distortion + faint chromatic aberration + vignette. Toggleable per Settings (a future "Retro Mode" checkbox, deferred to v1.1). Shader runs on a fullscreen `ColorRect` at the top of the UI CanvasLayer.

### 12.5 SFX

Three cues, authored as `AudioCue` resources (format from `interactables.md §8.4`), routed to the `UI` bus:
- `ui_move` — pitch-randomized short terminal beep on focus change.
- `ui_confirm` — slightly higher note on `ui_accept`.
- `ui_back` — softer low note on `ui_cancel`.
- `ui_type` — typewriter tick for title-reveal effect.

Bus: `UI` — specifically not ducked by dialogue sidechain (per `interactables.md §8.1`). Menus should be audible during dialogue playback.

---

## 13. Interfaces with other specs

### 13.1 From `interactables.md`

**This doc depends on (won't modify):**
- `GameState` autoload, API: `to_dict()`, `from_dict(d)`, `set_flag(id, v)`, `get_flag(id, default)`, `add_item`, `has_item`, `remove_item`, `visit_dialogue`. Exact contract from `interactables.md §7`.
- `Events` autoload signal bus. This doc extends it (§14) additively — never removes signals.
- `Audio` autoload's `play_sfx(cue_id)` for all UI beeps. Bus layout from `interactables.md §8.1` (5 buses: Music / Ambience / SFX / Dialogue / UI). Our volume sliders target Master/Music/SFX on that bus hierarchy.
- `Dialogue.is_open()` to decide whether the pause menu is allowed to open (§6).
- Existing `Events.checkpoint_reached` signal (already in `autoload/events.gd`) as the autosave trigger.

**This doc claims for itself the `SaveService` autoload** that `interactables.md §17` explicitly deferred. The §7 `to_dict`/`from_dict` contract is treated as inviolable — SaveService is a thin wrapper, not a replacement.

### 13.2 From character-controller spec

**This doc depends on (assumes; see §13.3 for the question list):**
- `PlayerBody` scene at a stable path (currently `res://player/body/player_body.tscn`) instantiated in `game.tscn` under a `Player` node name.
- `PlayerBody.apply_player_state(d: Dictionary)` — accepts `position`, `velocity`, `facing_yaw`, `camera_yaw`, `camera_pitch`, `is_skating`. See open contract (a) below.
- Player pawn uses default `PROCESS_MODE_INHERIT`, so `get_tree().paused = true` freezes it automatically. If the char-controller has any node on `PROCESS_MODE_ALWAYS`, it must not cause gameplay drift while paused (e.g., a debug camera can remain live; the player pawn's physics must not).

### 13.3 Open contracts — questions for the sibling designers

Assumptions this spec is making. Each wants a yes/no from the respective dev before this spec is finalized.

- **(a)** *To char-controller dev:* Does `PlayerBody` expose `apply_player_state(d: Dictionary) -> void` (this doc's spec) — or should `SaveService` reach into raw properties like `global_position`, `velocity`, camera `rotation_y`, etc.? Preference here is strongly for the method (clean contract, easier to evolve), but we need a commit.
- **(b)** *To interactables dev (or you, designer):* Should `GameState` add two fields — `current_level: StringName` and `playtime_s: float` — so `SaveService` has one place to ask, or should those live on `SaveService` / `PlayerState`? This doc assumes they land on `GameState` (makes save a pure dump of `to_dict()`); `interactables.md §7` currently does not list them.
- **(c)** *To interactables dev:* When `Dialogue.is_open()` is true and the user presses `pause`, does the dialogue swallow the input (call `set_input_as_handled()` in its own `_unhandled_input`), or does `PauseController` observe `Dialogue.is_open()` and silently no-op its own handler? Former is cleaner. This doc currently assumes the latter via `PauseController.user_pause_allowed`.
- **(d)** *To char-controller dev:* Is the phone_booth interactable the sole emitter of `Events.checkpoint_reached`? Any other autosave triggers planned (flag-reached at end of level)? This doc currently only hooks the checkpoint signal.
- **(e)** *To char-controller dev:* During the scene-load transition (game → menu, menu → game), does the player pawn need any cleanup/shutdown hook before `change_scene_to_packed()`? (Most common issue: a `_physics_process` that holds a reference to a node that's about to be freed.)

---

## 14. Integration points with existing code

Minimally invasive. Files touched:

| File | Change (additive only) |
|---|---|
| `project.godot` | Set `application/run/main_scene = "res://menu/main_menu.tscn"` (was `game.tscn`). Add autoloads: `Settings`, `SaveService`, `SceneLoader`, `PauseController`. Add `pause` InputMap action. |
| `autoload/events.gd` | Add signals: `menu_opened(id: StringName)`, `menu_closed(id: StringName)`, `modal_opened(id: StringName)`, `modal_closed(id: StringName)`, `modal_count_reset()` (dev escape hatch from debug panel), `settings_applied`, `game_saved(slot: StringName)`, `game_loaded(slot: StringName)`. All `@warning_ignore("unused_signal")`. |
| `game.gd` | Add a `PauseMenu` child instance-ref + a `_ready()` hookup to `PauseController.paused_changed` → show/hide the pause menu. No changes to existing fullscreen toggle. |
| `game.tscn` | Add a `PauseMenu` child (instance of `res://menu/pause_menu.tscn`), `visible=false` by default. No existing nodes changed. |
| `GameState` | **Open contract (b)**: if adopted, adds `current_level: StringName` (set by scene on its `_ready`) and `playtime_s: float` (accumulated in `_process`). Modified in `interactables.md §7`, not here. |
| `PlayerBody` | **Open contract (a)**: if adopted, adds `apply_player_state(d: Dictionary) -> void`. Modified in char-controller spec, not here. |

**Nothing in `autoload/debug_panel.gd` is touched.** Nothing under `player/` is touched by *this* spec — the char-controller dev owns those edits.

---

## 15. Target file layout

```
menu/
  main_menu.tscn / .gd
  menu_world.tscn                          <-- dedicated 3D fly-through scene
  pause_menu.tscn / .gd
  settings_menu.tscn / .gd
  save_slots.tscn / .gd                    <-- shared for save + load modes
  scene_loader.tscn / .gd
  credits.tscn / .gd
  menu_button.tscn / .gd                   <-- reusable terminal-themed button
  menu_theme.tres
  fonts/
    JetBrainsMono-Regular.ttf              <-- or equivalent monospace
  transitions/
    transition.gd                          <-- abstract base
    instant_transition.gd
    glitch_transition.gd
    glitch.gdshader
  crt_overlay.gdshader                     <-- optional CRT look (deferred)
  sfx/
    ui_move.tres                           <-- AudioCue resources (interactables.md §8.4)
    ui_confirm.tres
    ui_back.tres
    ui_type.tres
autoload/
  settings.gd                              <-- NEW
  save_service.gd                          <-- NEW
  scene_loader.gd                          <-- NEW
  pause_controller.gd                      <-- NEW
user:// (runtime, gitignored)
  settings.cfg
  save_slot_a.json + save_slot_a.meta.json
  save_slot_b.json + save_slot_b.meta.json
  save_slot_c.json + save_slot_c.meta.json
  save_slot_autosave.json + save_slot_autosave.meta.json
```

---

## 16. Open risks before prototype

1. **Threaded load progress stuck at 0.** Known Godot issue on some backends ([#56882](https://github.com/godotengine/godot/issues/56882)). Mitigation designed in §9 (swap to indeterminate spinner after 250ms of no progress change). Worst case: user sees a spinner until done; acceptable.
2. **Settings.apply() at runtime can't trivially change shader uniform defaults inside `.tres` files.** Options: (i) mutate the loaded `ShaderMaterial` in memory (simple, doesn't persist to disk — that's what we want anyway, the persistence is `settings.cfg`); (ii) use `instance uniform`s where the preset needs to vary per-building (we already have a couple of these on `buildings.tres`). Going with (i).
3. **Screenshot capture hitch on save.** 64×36 downscale + PNG encode + base64 is ~30-100 ms. `SaveService.save_to_slot` could call `await get_tree().process_frame` twice before the capture to smooth out the hitch. Deferred tuning.
4. **Pause menu + dialogue pause collision.** Covered by §13.3 open contract (c). Picking the wrong resolution means the user can open the pause menu on top of a dialogue balloon. Easy to fix; a real risk until contract is signed off.
5. **Save-file-format migration.** `version: 1` is in every save. Plan: on load, if `version < CURRENT`, run a chain of migration functions. Until there are v2 saves this is free insurance. Deferred design.
6. **`MenuCamera` idle-wiggle through glass buildings.** The menu-world has transparent buildings (`buildings.tres`). With `cull_disabled` the back-face renders through the front. If the camera rail passes through a building, the viewer gets a full "inside a glass box" moment. Either route the path around all buildings OR accept it as atmospheric (arguably on-brand).

---

## 17. Deferred / out of scope

- **Controls rebinding UI.** v1 uses defaults; rebind UI is its own small spec.
- **Fullscreen toggle / resolution / vsync / DLSS etc.** Settings v2.
- **Cloud saves / Steam Cloud.** Out of scope for v1.
- **Save-file integrity / anti-tamper.** Plain JSON is trivially hand-editable; we don't care for a single-player game.
- **Save-file migration between versions.** Flagged in open risks. Plan when the first breaking change lands.
- **Credits content.** Scaffolding shipped; actual text is a drop-in later.
- **Retro CRT overlay toggle.** Shader file listed in layout (§15); UI toggle deferred to v1.1.
- **Localization.** All UI strings in English. i18n pipeline is its own story.
- **Settings "reset to defaults" button.** Useful but a late polish.
- **Animated background music for the main menu.** Reuses `Audio.play_music(...)`; picking the actual track is content, not structure.
- **Autosave toast notification.** Silent per user direction; flavor toast could be added later.

---

## Sources

**Godot 4.6 docs:**
- [Singletons (Autoload) — 4.6](https://docs.godotengine.org/en/4.6/tutorials/scripting/singletons_autoload.html)
- [ConfigFile](https://docs.godotengine.org/en/stable/classes/class_configfile.html)
- [Background loading / threaded ResourceLoader](https://docs.godotengine.org/en/stable/tutorials/io/background_loading.html)
- [JSON](https://docs.godotengine.org/en/stable/classes/class_json.html)
- [FileAccess](https://docs.godotengine.org/en/stable/classes/class_fileaccess.html)
- [Pausing games and process mode](https://docs.godotengine.org/en/stable/tutorials/scripting/pausing_games.html)
- [PathFollow3D](https://docs.godotengine.org/en/stable/classes/class_pathfollow3d.html)
- [AudioServer](https://docs.godotengine.org/en/stable/classes/class_audioserver.html)
- [SubViewport](https://docs.godotengine.org/en/stable/classes/class_subviewport.html)
- [Control](https://docs.godotengine.org/en/stable/classes/class_control.html)
- [Marshalls](https://docs.godotengine.org/en/stable/classes/class_marshalls.html)
- [File paths / user://](https://docs.godotengine.org/en/stable/tutorials/io/data_paths.html)

**Known Godot issues:**
- [#83160 — NOTIFICATION_PAUSED/UNPAUSED reversed under PROCESS_MODE_WHEN_PAUSED](https://github.com/godotengine/godot/issues/83160)
- [#56882, #90076 — load_threaded_get_status progress stuck at 0 on some platforms](https://github.com/godotengine/godot/issues/56882)

**Community / pattern references:**
- [meloonics/3D-Menu-Cam](https://github.com/meloonics/3D-Menu-Cam) — idle-wiggle + screenshake camera pattern for menus.
- [MarkVelez/godot-modular-settings-menu](https://github.com/MarkVelez/godot-modular-settings-menu) — modular settings menu reference.
- [gotut.net — Loading Screen in Godot 4](https://www.gotut.net/loading-screen-in-godot-4/) — threaded-load UI pattern.
- [GDQuest — Save systems cheat sheet](https://www.gdquest.com/library/cheatsheet_save_systems/) — JSON vs Resource save tradeoffs.

**In-project references:**
- `docs/materials.md` — graphics preset *values*, environment tweaks.
- `docs/interactables.md` — GameState, Events, Audio, Dialogue, bus layout; §7 save surface, §17 deferred SaveService now owned here.
- `autoload/events.gd` — existing signals (`checkpoint_reached`, `flag_reached`, etc.) consumed by this spec.
- `game.gd` / `game.tscn` — existing gameplay root; minimally extended.
- `project.godot` — existing InputMap, extended with `pause`.
