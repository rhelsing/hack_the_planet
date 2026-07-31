#!/bin/bash
# Offline nav bake — regenerates level/nav/baked/<level>.res for each level
# listed below. Boots each level headless with full autoloads (so CSG,
# inherited scenes, and physics behave exactly like the running game), bakes
# the navmesh + auto-links, and writes the sidecar artifact. Level .tscn
# files are never touched.
#
# Run from anywhere:  ./tools/bake_nav.sh
set -uo pipefail

GODOT="/Applications/Godot.app/Contents/MacOS/Godot"
cd "$(dirname "$0")/.."

LEVELS=(
  "level/nav_test.tscn"
  "level/nav_gym_crowd.tscn"
  "level/level_1.tscn"
  "level/level_2.tscn"
  "level/level_3.tscn"
  "level/level_4.tscn"
  "level/hub.tscn"
)

fail=0
for lvl in "${LEVELS[@]}"; do
  name="$(basename "${lvl%.tscn}")"
  echo "=== baking $lvl"
  "$GODOT" --headless --path . "res://$lvl" -- --nav-bake 2>&1 \
    | grep -E "nav_bake|SCRIPT ERROR" || true
  if [ -f "level/nav/baked/$name.res" ]; then
    echo "=== ok: level/nav/baked/$name.res"
  else
    echo "=== FAILED: no artifact for $name"
    fail=1
  fi
done
exit $fail
