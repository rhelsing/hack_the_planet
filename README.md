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
    - [ ] future — love / sex / secret (mechanic design TBD)
  - **Pawn swap system** (player / enemy / companion / remote):
    - [x] Brain/Body/Skin architecture; swap via inspector `@export`s
    - [x] 3 skins shipped (Sophia, cop_riot, KayKit)
    - [ ] Universal Base Characters + Universal Animation Library 1+2 skin variants
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

- [ ] post processing effects / color grading