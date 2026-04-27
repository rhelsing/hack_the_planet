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