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