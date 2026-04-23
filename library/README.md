# Interactables Library — drop-in prefabs

Ready-to-place scenes for every interaction type. Drop one in your scene, set a couple of fields in the Inspector, done.

**See `docs/interactables.md` for the full architecture.** This README is the operator's manual.

---

## Quick start — try the demo

Open `res://demo/interactables_demo.tscn` in Godot and hit F6 (or command-line):

```bash
/Applications/Godot.app/Contents/MacOS/Godot res://demo/interactables_demo.tscn
```

You'll land on a flat plane with one of each interactable. Walk around with WASD. When you're close and facing something, a `[E] verb` prompt pops up. Press **E** (or **X** on gamepad).

What you can do:
- Open the **green door** (unlocked — just press E)
- Grab the **yellow key** → now the **red door** accepts E
- Hack the **terminal with the green screen** → solve the timing puzzle → the **purple door** unlocks
- Talk to the **yellow NPC** (currently push_warnings until the DialogueManager plugin is fixed — see "Known issues" below)
- Touch the **red spikes** and get knocked back

Background music loops throughout. When you trip the hacking puzzle, the SFX duck against the Dialogue bus (routed through the sidechain compressor from `default_bus_layout.tres`).

---

## The prefab library

All files live in `library/interactables/`. Each has a CSG mesh + pre-configured script + collision.

### `door_unlocked.tscn`
Opens on interact. No gate. Green mesh.
- **Set**: `interactable_id` (unique StringName, e.g. `&"lobby_door"`).

### `door_locked_key.tscn`
Red mesh. Needs an item in `GameState.inventory` to open.
- **Set**: `interactable_id`, `requires_key` (the StringName a matching `Pickup` grants).

### `door_locked_hack.tscn`
Purple mesh. Needs a world flag set to true.
- **Set**: `interactable_id`, `requires_flag` (usually the partner `HackingTerminal`'s `interactable_id`).

### `pickup_key.tscn`
Yellow cube. On interact, calls `GameState.add_item(item_id)` and removes itself.
- **Set**: `interactable_id` (for save-de-dupe), `item_id` (what it grants — e.g. `&"red_key"`).

### `hacking_terminal.tscn`
Dark box with glowing green screen. Launches the timing-tap hacking puzzle.
- **Set**: `interactable_id` (this becomes the flag set on solve — link matching doors' `requires_flag` to it).
- **Keep**: `puzzle_scene` already points at `res://puzzle/hacking/hacking_puzzle.tscn`.
- **Keep**: `one_shot = true` makes it non-interactable after solving (single hack).

### `dialogue_npc.tscn`
Yellow capsule. Opens a dialogue balloon.
- **Set**: `interactable_id`, `dialogue_resource` (drag a `.dialogue` file from `res://dialogue/`).

### `spike_trap.tscn`
Red cone cluster. On interact, calls `actor.take_hit(dir, knockback)`.
- **Set**: `interactable_id`, `knockback` (default 14.0), `single_use` (default true).

---

## The hacking → door chain (the cool one)

**This is the pattern you asked about.** Two files, two inspector fields, no scripting.

1. Place `hacking_terminal.tscn`. In Inspector, set `interactable_id = &"mainframe_01"`.
2. Place `door_locked_hack.tscn` nearby. Set `requires_flag = &"mainframe_01"` (same string).
3. Run.

When the player solves the puzzle, `PuzzleTerminal` calls `GameState.set_flag(&"mainframe_01", true)`. The door checks `GameState.get_flag(requires_flag)` in its `can_interact()` → now passes. Prompt lights up, E opens the door.

You can chain multiple doors to one terminal — just use the same `requires_flag` string.

---

## Wiring into YOUR scene (not the demo)

Your scene needs four pieces, and they don't have to be under a specific parent:

1. **A PlayerBody** (already in `game.tscn`).
2. **An `InteractionSensor`** — instance `res://interactable/interaction_sensor.tscn` anywhere in the scene tree. It auto-finds the player via the `"player"` group at `_ready`. Placement doesn't matter; the sphere inherits position from the nearest Node3D ancestor, but the sensor scores against `body.global_position` regardless.
3. **The `PromptUI`** — instance `res://interactable/prompt_ui/prompt_ui.tscn` as a sibling of your level. Already in `game.tscn`.
4. **Interactables** — drop any library prefab wherever, set the Inspector fields above.

**One sensor per scene.** It's a singleton-by-group. If you have multiple, PromptUI picks whichever the tree returns first — undefined.

---

## Audio — what plays when

Events fire → `Audio` autoload plays cues. Zero direct calls needed from your game code.

| Event | Cue | Defined in |
|---|---|---|
| `GameState.add_item(...)` → `Events.item_added` | `pickup_ding` (pool of 4 clicks) | `audio/cues/pickup_ding.tres` |
| Door's `interact()` → `Events.door_opened` | `door_open` (gunshot.wav) | `audio/cues/door_open.tres` |
| Puzzle solved → `Events.puzzle_solved` | `hack_success` (sound_teleport) | `audio/cues/hack_success.tres` |
| Puzzle failed/cancelled → `Events.puzzle_failed` | `hack_fail` (miss.wav) | `audio/cues/hack_fail.tres` |

Want a different sound? Open the `.tres`, swap the `streams` array. No code changes.

Want a new cue (e.g. `footstep`)?
1. Create `audio/cues/footstep.tres` (copy an existing one as template).
2. Add it to `audio/cue_registry.tres`'s `cues` dict with key `&"footstep"`.
3. Call `Audio.play_sfx(&"footstep")` from anywhere.

Missing cues fail **loud** (`push_error`), not silent.

---

## Music + ambience

Two options.

### Option A: drop-in starter node
Add a `Node` to your scene with `demo/demo_ambience_starter.gd` attached. Set `music_stream` and (optional) `ambience_stream` in the Inspector. Music plays at `_ready`.

### Option B: call Audio directly
From any script:
```gdscript
Audio.play_music(load("res://audio/music/disco_music.mp3"), 1.5)  # fade-in
Audio.play_ambience(load("res://audio/music/size_of_life_03.mp3"), 2.0)
Audio.stop_music(1.0)  # fade-out
```

**Sidechain ducking is automatic.** When dialogue plays (via `Audio.play_dialogue`), music and ambience duck by the compressor on those buses — no code needed.

---

## Dialogue — .dialogue files

Put `.dialogue` files in `res://dialogue/`. The plugin states (`GameState`, `Events`, `Audio`) are exposed inside `.dialogue` scripts via `project.godot`'s `[dialogue_manager]` section — so a line can call `GameState.add_item(&"thing")`, check `GameState.has_visited("Troll", ...)`, etc.

On the NPC side: place `dialogue_npc.tscn`, drag your `.dialogue` file onto `dialogue_resource` in Inspector. Done.

**Visited dimming** (ported from 3dPFormer): the balloon at `res://dialogue/balloon.gd` automatically greys response buttons that the player has already chosen (scoped per character). "End the conversation" is always exempt. No wiring needed — `GameState.visit_dialogue` is called on each choice.

---

## Known issues

**DialogueManager plugin parse error (Godot 4.6):** the vendored addon has a signature mismatch on `insert_text` vs Godot 4.6's `CodeEdit.insert_text`. Dialogue is non-functional until the plugin is updated to a 4.6-compatible release. The `DialogueNPC` prefab works structurally (prompt shows, E fires `interact()`), it just `push_warning`s on missing resource today.

**Fix path:** download the latest `godot_dialogue_manager` release from Nathan Hoad's GitHub, replace `addons/dialogue_manager/` wholesale. The NPC's `dialogue_resource` Inspector field then accepts `.dialogue` files.

---

## Temporary sensor placement (will change)

Today, `InteractionSensor` is instanced directly into scenes. **This is a demo convenience.** Per `docs/interactables.md` §4 and §19, the sensor's real home is as a child of `PlayerBrain` in `player_brain.tscn`. That wiring is blocked on character-controller dev's Patch A.

When Patch A lands:
- Sensor moves to be a child of `PlayerBrain`.
- Remove the standalone `InteractionSensor` node from your scene.
- Zero changes to interactable prefabs — they don't care where the sensor lives.

---

## Test suite

All smoke tests live in `res://tests/`:

```bash
godot --headless res://tests/test_game_state.tscn         # GameState API
godot --headless res://tests/test_audio_bus_layout.tscn   # 5 buses + sidechain wiring
godot --headless res://tests/test_puzzles_lifecycle.tscn  # Puzzle pause + modal + signals
godot --headless res://tests/test_door_e2e.tscn           # Door interact → flag → events
godot --headless --script res://tests/test_interaction_sensor.gd --quit  # scoring math
godot --headless --script res://tests/test_intent.gd --quit              # Intent (CC-owned)
```

All 6 should print `PASS …` and exit 0.
