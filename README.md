# Hack The Planet

- [x] Rollerblade - add wheels
- [x] Checkpoints -> Phone booth
- [x] Floppy Disks as Collectables
- [x] pool on a roof?
- [x] FBI lil enemy guys with guns but they dont shoot, they just arrest you
- [ ] you shoot flares?
- [ ] quarter pipes? downward slopes?
- [ ] panels slide to block, but you can time them with music?
- [ ] elevator / platforms / bouncy ones

- [ ] Character Controllers — full scope in [docs/character_next.md](docs/character_next.md)
  - **Standard movements** (always available, no pickups required):
    - [x] Walk / run
    - [x] Jump + double jump
    - [x] Attack (forward lunge + sweep)
    - [ ] Dash / Dodge
    - [ ] Crouch
  - **Skate-only movements** (require the Skate power-up pickup):
    - [x] Wall-ride / wallrun
    - [x] Rail grind
  - **Power-ups** (one unlocks every 4 levels — stackable, persisted in `GameState.flags`):
    - [ ] P1 — Skate / Grind (currently always-on; wrap in unlock gate)
    - [ ] P2 — Grapple Hook
    - [ ] P3 — Shoot Flares
    - [ ] P4 — Sunglasses / Hack mode
    - [ ] future — love / sex / secret / god (mechanic design TBD)
  - **Pawn swap system** (player / enemy / companion / remote):
    - [x] Brain/Body/Skin architecture; swap via inspector `@export`s
    - [x] 5 skins shipped — any can be the main character:
      - Sophia → `res://player/sophia_skin/sophia_skin.tscn`
      - cop_riot → `res://player/skins/cop_riot/cop_riot_skin.tscn`
      - KayKit → `res://player/skins/kaykit/kaykit_skin.tscn`
      - Quaternius → `res://player/skins/quaternius/quaternius_skin.tscn`
      - Anime Character → `res://player/skins/anime_character/anime_character_skin.tscn`
    - **How to swap the main character:** open `game.tscn`, select the `Player` node, and set `skin_scene` to any of the five `.tscn` files above. Every enemy variant under `enemy/` (enemy_sophia, enemy_kaykit, enemy_quaternius) uses the same mechanism — they instance `player_body.tscn` and override `skin_scene` + `brain_scene`.
  - **Enemy AI**:
    - [x] Wander + chase + contact-lunge (EnemyAIBrain)
    - [ ] Ranged, ambusher, static-watcher archetypes
    - [ ] Visual debug cone of vision (editor gizmo)
  - **Camera**:
    - [x] Third-person spring-arm follow
    - [ ] Dynamic lock-on for focused interactables (character_next §-TBD)
  - [x] Gamepad controls (jump, attack, interact, move)

- [ ] interactable - hacking, open (key required) - dialogue engine chatting, impact global world state
- [ ] music and sound effects triggers - dipping on dialouge
- [ ] UI, begin menu, loading.. stages, pause menu

- [x] **Voice line variant pre-caching** — voice line templates (`Companion.speak`, `Walkie.speak`, respawn zones) accept `{player_handle}` for the player's chosen hacker name and `{jump}` / `{dash}` / `{interact}` / etc. for device-specific glyphs. At speak-time, every other variant (cartesian of HandlePicker.POOL × Glyphs.DEVICES) is enqueued in the background through `VoicePrimer` so swapping name or controller mid-game never causes a TTS stutter. Glyph table lives in `autoload/glyphs.gd`; resolution + variant logic in `dialogue/line_localizer.gd`. Spec: [docs/dynamic_dialogue_engine.md](docs/dynamic_dialogue_engine.md).

- [ ] post processing effects / color grading

- [ ] **Player handle picker** — early NPC (Glitch?) prompts the player to choose their hacker name during the tutorial. Persisted on `GameState` and surfaced in HUD/dialogue (`{player_name}` substitution in `.dialogue` files). Pick from a curated stereotype list (Crash Override / Acid Burn / Cipher / Phantom / Cereal Killer / etc.) or enter a custom one.

---

## Beacon system (objective waypoints)

World-space arrows + labels that point the player at a target. Rendered by the HUD as a diamond when on-screen and an edge-clamped arrow when off-screen, with a distance readout.

**Three pieces:**
- `Beacons` autoload (`autoload/beacons.gd`) — global registry. Each Beacon registers itself at `_ready` and unregisters at `_exit_tree`.
- `Beacon` component (`hud/components/beacon.tscn` + `beacon.gd`) — Node3D you parent under any target. Its own `global_position` is what the HUD projects, so offset it (typically `+2 Y`) to float above a head.
- `BeaconLayer` renderer (`hud/components/beacon_layer.gd`) — full-screen Control inside the HUD that iterates `Beacons.list()` each frame and draws every beacon whose `beacon_visible == true`.

**To add a beacon:** drop `hud/components/beacon.tscn` as a child of any Node3D, set `label`, optionally set the visibility gates (all combined as AND):

| Property | Behavior |
|---|---|
| `visible_when_flag: StringName` | Hidden until this `GameState` flag becomes true. |
| `hide_when_flag: StringName` | Hidden once this flag becomes true. |
| `visible_when_voice_ends: StringName` | Speaker name (e.g. `&"DialTone"`, `&"Glitch"`). Beacon turns ON after a matching line ends. |
| `visible_when_voice_match: String` | Optional case-insensitive substring required in the spoken text. Empty = any line from that speaker. |

The voice trigger listens to BOTH the `Companion` bus (in-world voices like Glitch, Nyx) and the `Walkie` bus (radio chatter — DialTone). Whichever fires first arms the beacon; it flips visible when the line ends.

**Example — Glitch (in `level/level_1.tscn`):** beacon child on the Glitch node, hidden once the lift sequence has been triggered, revealed when Glitch finishes a line containing "see me":

```gdscript
[node name="Beacon" parent="glitch_set/Glitch" instance=ExtResource("24_beacon")]
transform = Transform3D(1, 0, 0, 0, 1, 0, 0, 0, 1, 0, 2, 0)
label = "GLITCH"
hide_when_flag = &"glitch_lift_ready"
visible_when_voice_ends = &"Glitch"
visible_when_voice_match = "see me"
```

**Example — Nyx:** beacon flips on after the DialTone walkie line "Wiring her location to you now!" ends:

```gdscript
[node name="Beacon" parent="Nyx" instance=ExtResource("24_beacon")]
transform = Transform3D(1, 0, 0, 0, 1, 0, 0, 0, 1, 0, 2, 0)
label = "NYX"
visible_when_voice_ends = &"DialTone"
visible_when_voice_match = "Wiring her location"
```

**Manual control:** call `beacon.set_beacon_visible(true/false)` from any script if the gates aren't expressive enough.

---

## Voice / dialogue audio (TTS cache + variants)

NPC dialogue is voiced via ElevenLabs TTS. Synthesized mp3s are cached on disk so production builds **never** hit the API. Single source of truth: `res://audio/voice_cache/`.

### Variants the system bakes per template

When a `.dialogue` line contains tokens, the cache splits into all live combinations:

- **Player handle**: `{player_handle}` substitutes from `HandlePicker.POOL = ["Pixel", "Neon", "Cipher", "Byte"]` → up to **4 variants per template**.
- **Input device**: glyph tokens like `{jump}`, `{interact}` substitute from `Glyphs.DEVICES = ["keyboard", "gamepad"]` → up to **2 variants per template**.
- **Both tokens together** → 4 × 2 = **8 variants**.
- **Neither token** → 1 variant (single static line).

Cache filenames are MD5-hashed on `(character, resolved_text, voice_id)`, so the same template across two builds maps to the same file. Hashes are deterministic; deleting and re-baking is idempotent.

### Single-command bake — `tools/bake_voices.sh`

Run before any export:

```bash
tools/bake_voices.sh             # bake + import + delete orphans (default)
tools/bake_voices.sh --no-prune  # bake + import, list orphans without deleting
```

Three stages:
1. **Prime** (`tools/prime_all_dialogue.gd`) — walks every `.dialogue` file plus every level `.tscn` (for inline `voice_line` exports on RespawnMessageZones AND `line` properties on WalkieTrigger nodes — the walkie scan does a 2-pass detection of nodes whose `instance=ExtResource("X")` matches `walkie_trigger.tscn`). Expands the {handle × device} cartesian via `LineLocalizer.all_variants`. Already-cached variants skip; only missing ones POST to ElevenLabs. Sequential with a 0.4s gap between requests; runs ~10–20 min on a fresh clone, seconds when already populated.
2. **Re-import** (`godot --headless --import`) — generates `.mp3.import` sidecars + the imported `.mp3str` form for any new mp3s. Required so `ResourceLoader` can find them in exported builds.
3. **Orphan prune** (`tools/find_orphan_voices.gd -- delete`) — deletes cache files whose hash doesn't match any live `(character, template, voice_id)` triple. Lines with un-checkable runtime primitives (`{{HandlePicker.chosen_name()}}`, `[[a|b]]` alternations) are correctly excluded from the orphan list, so they don't get deleted. Pass `--no-prune` to the bake script to inspect first instead of deleting.

After running: `git add audio/voice_cache/ && git commit`. Both `.mp3` and `.mp3.import` files must ship together; deletions of orphans need to be committed too.

### How playback resolves the cache

`autoload/dialogue.gd::_play_cached` branches on build type:

- **Editor / playtest**: `FileAccess.open(path, READ)` reads the raw mp3 bytes and wraps them in a runtime `AudioStreamMP3`. Works for freshly-synthed files even before Godot's filesystem watcher imports them (no `.import` sidecar required).
- **Exports** (`OS.has_feature("template")`): `ResourceLoader.load(path)` resolves the imported `.mp3str` form via the `.import` sidecar. Required because exports strip the raw mp3 source from the `.pck`.

### Production never hits ElevenLabs

`_maybe_dispatch_next_tts` (and the parallel walkie path) gate on `OS.has_feature("template")`. In an exported build, a cache miss silently clears the queue and returns — no HTTP request, no API quota burn. If a player encounters a missing line, that means the bake step was skipped before export; re-bake + re-export.

### Setup

One-time per machine: store the ElevenLabs API key:

```bash
godot --headless --script res://tools/setup_tts.gd --quit -- <api_key>
```

Or set the `ELEVEN_LABS_API_KEY` env var (CI / per-shell override; takes precedence). The committed fallback `res://dialogue/tts_config.tres` is repo-private so a fresh clone "just works."

### Inspection helpers

- `tools/list_voices.gd` — print configured `character → voice_id` mappings from `dialogue/voices.tres`.
- `tools/browse_voices.gd` — print all available voices from your ElevenLabs account.
- `tools/find_orphan_voices.gd` — orphan scan as a standalone command (without prime + import).
- `tools/compile_dialogue_brief.gd` — aggregate every `.dialogue` file + walkie + respawn voice line into a single readable Markdown brief at `story/dialogue_brief.md`. Run after any dialogue/walkie change to refresh. Round-trippable: HTML comments above each chunk identify its source so paste-back edits can be mapped to source files.

### Per-line model overrides

The project default model is `eleven_flash_v2_5` (cheap, fast, neutral delivery). Specific lines can opt into a different model — most often `eleven_v3` for dramatic moments, audio tags (`[laughs]`, `[sighs]`, `[whispering]`, etc.), or richer emotional performance.

**Tag a line with `[#model=<id>]`** to bake + cache + play it on a different model:

In a `.dialogue` file:
```
Splice: ...wow. [sighs] Wow okay. [#model=eleven_v3]
Splice: [whispering] I'll find you again. [#model=eleven_v3]
```

In a `WalkieTrigger` node's `line` property (a string field in the inspector):
```
"Interesting. Do I detect a **new trace** on the wire? [#model=eleven_v3]"
```

The tag itself is stripped from both the displayed subtitle and the TTS payload (regex match against `[#model=…]` runs in Walkie / Companion / Dialogue paths). DialogueManager parses it natively for `.dialogue` files via `line.has_tag("model")` / `line.get_tag_value("model")`.

**How the cache stays clean during a model swap:**

The cache filename hash includes `model_id` ONLY when it's not the default. So:

| Line | Default flash | Tagged `eleven_v3` |
|------|---------------|---------------------|
| Hash key | `character__text__voice_id` | `character__text__voice_id__eleven_v3` |
| Cache file | `splice_a1b2c3d4.mp3` | `splice_x7y8z9w0.mp3` (different) |

Both versions can coexist on disk. Untagged lines keep using their existing flash mp3s — no rebake needed. Tagged lines synth fresh on the override model.

**Workflow to test a line on `eleven_v3`:**

1. Add the tag: `Splice: line text. [#model=eleven_v3]` in the `.dialogue` file (or walkie node's `line` string).
2. Run `tools/bake_voices.sh` (or `tools/bake_voices.sh --no-prune` if you don't want orphan removal yet).
3. The new mp3 synthesizes on `eleven_v3`. The old flash mp3 (different hash) becomes an orphan and gets cleaned on the prune step.
4. Play the line in-game — it loads from cache and plays on the v3 voice.

**Cost expectation per ElevenLabs Starter tier ($5/mo, 30,000 credits/month):**
- `eleven_flash_v2_5` (default): ~0.5 credits/character — full-game baseline bake fits comfortably.
- `eleven_v3`: ~1.0 credits/character — roughly 2× cost. Tagging ~30-60 lines on v3 fits within ~10-20% of a monthly budget. A full v3 migration would exceed Starter limits — bump to Creator ($22/mo) for that.

**Cost-control tips:**
- Tag *individual lines* (the dramatic moments), not whole files.
- Listen to a single tagged line first; if v3 isn't dramatically better for that voice, revert the tag. The flash mp3 stays cached so reverting just makes the v3 mp3 an orphan on next prune.
- Use `tools/bake_voices.sh --no-prune` if you want to A/B both versions on disk before committing.

---

## Maze editor (browser-based authoring tool)

`HackTerminal` puzzles are Witness-style maze traces — strict no-cross path from a perimeter Start node to a perimeter End node, with optional Witness-style "oil/water" cell markers (purple square / blue circle) that the trail must separate into monochromatic regions to solve.

Mazes are authored in a vanilla HTML/CSS/JS app at **`tools/maze_editor/`**. No build step, no server — double-click `index.html` and it runs.

### Editing flow

1. Open `tools/maze_editor/index.html` in a browser.
2. Set grid size (cols × rows, 3–15 each).
3. Pick a mode in the toolbar:
   - **edges** (default) — click an edge slot to toggle, or click-and-drag to paint a continuous run of edges open/closed.
   - **set start** / **set end** — click any *perimeter* node (edge of grid only) to place. One S, one E.
   - **water** / **oil** — click any cell interior to drop a marker; click the same cell again to clear.
4. Optionally toggle **timed** + set a seconds value (5–600). Saved into the file; the in-game puzzle reads it and runs a countdown with a glitch-warning ramp in the last 5 seconds.
5. **Verify** runs BFS from S to E. Download stays disabled until the maze is solvable.
6. **Download .maze** — saves a JSON file. Drop it under `puzzle/maze/mazes/` and point a `PuzzleTerminal.maze_path` export at it.
7. **Load .maze** round-trips an existing file back into the editor for tweaks.

### Format (`.maze` is plain JSON)

```jsonc
{
  "version": 1,
  "cols": 5, "rows": 5,
  "start": [0, 2], "end": [4, 2],
  "time_limit": 0,                            // seconds; 0 = untimed
  "h": [[0,1,0,0], ...],                      // rows × (cols-1)  open horizontal edges
  "v": [[0,1,1,0,0], ...],                    // (rows-1) × cols  open vertical edges
  "cells": [[0,1,0,0], ...]                   // (rows-1) × (cols-1)  0=none, 1=water, 2=oil
}
```

`cells` is optional (defaults to all-zero). Loaded by `puzzle/maze/maze_data.gd` via `JSON.parse_string` + shape validation. Tested against the level-2 fixture in `tests/test_maze_data.gd`.

### How a level uses a maze

`PuzzleTerminal` (`interactable/puzzle_terminal/puzzle_terminal.gd`) has a `maze_path: String` `@export_file("*.maze")` field. The level scene sets it per-instance — e.g., on `level_2.tscn` the HackTerminal points at `res://puzzle/maze/mazes/l2_hack_terminal.maze`. On interact, `Puzzles.start` injects `maze_path` into the spawned `MazePuzzle` via setup-data; the puzzle reads the file, builds the graph, and runs.