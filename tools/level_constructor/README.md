# Level Constructor

Browser tool for sketching Hack The Planet levels at the cell-grid level. Compiles to a JSON brief; the Godot-side compiler (TBD) reads that brief and emits a `.tscn`.

## Run

```
cd tools/level_constructor
npm install
npm run dev
```

Open the URL Vite prints (default `http://127.0.0.1:5173/`).

## Controls

| Action | Binding |
|---|---|
| Look | Right-mouse drag |
| Fly forward/back/strafe | `W` `A` `S` `D` |
| Fly up/down | `E` / `Q` (or `Space` / `Ctrl`) |
| Boost | `Shift` |
| Place cell | Drag from drawer onto grid (snaps to 20-unit cells) |
| Select cell | Left-click |
| Delete selected | `Delete` / `Backspace` |
| Cancel drag | `Esc` |
| Save brief | top-bar **save** (downloads JSON) |
| Load brief | top-bar **load…** (file picker) |
| Reset | top-bar **new** |

## Brief schema (v0.1)

```json
{
  "level_num": 1,
  "biome": { "primary": "#hex", "accent": "#hex" },
  "seed": 1,
  "cells": [
    { "id": "c1", "pos": [x, y, z], "kind": "spawn|checkpoint|flag|npc|..." }
  ]
}
```

`pos` is integer cell coordinates. World-space position is `pos × 20`.

Cell kinds available in v0.1: `spawn`, `checkpoint`, `flag`, `npc`, `hacking_terminal`, `platforming`, `convert_zone`, `cutscene_anchor`, `kill_counter`, `buried_reveal`.

## Roadmap

- v0.1 — cells only (this) ✓
- v0.2 — primitives bag inside each cell (coins, bouncy, rail, walkie, …)
- v0.3 — chain wirer (flag DAG)
- v0.4 — NPC dialogue + waypoints panel
- v0.5 — solveability checker
- v1.0 — Godot-side `tools/compile_level.gd` reads briefs, emits `.tscn`
