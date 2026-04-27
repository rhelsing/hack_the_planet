#!/usr/bin/env bash
# bake_voices.sh — single-command voice cache bake.
#
# 1. Walks every .dialogue file + level .tscn + Companion.speak / Walkie.speak
#    code call. For each (character, template), expands the {handle × device}
#    cartesian via LineLocalizer.all_variants:
#      - Handles: HandlePicker.POOL = [Pixel, Neon, Cipher, Byte]    (4 names)
#      - Devices: Glyphs.DEVICES    = [keyboard, gamepad]            (2 inputs)
#      → Up to 1 / 2 / 4 / 8 variants per template depending on tokens used.
#    Already-cached variants skip; only missing ones POST to ElevenLabs.
#    Output lands in res://audio/voice_cache/.
#
# 2. Re-imports the project so newly-written .mp3 files get .import sidecars
#    + their .mp3str imported form (required for ResourceLoader to find them
#    in exported builds).
#
# 3. Prunes orphan cache files (audio with no matching live dialogue line).
#    Default behavior: DELETES orphans. Pass --no-prune for read-only inspection.
#    Lines with un-checkable runtime primitives ({{...}} mustache, [[a|b]]
#    alternations) are correctly skipped — only true orphans get removed.
#
# Run from the repo root:
#   tools/bake_voices.sh             # bake + import + delete orphans
#   tools/bake_voices.sh --no-prune  # bake + import, list orphans without deleting
#
# Requires:
#   - ElevenLabs API key configured (tools/setup_tts.gd, or ELEVEN_LABS_API_KEY env)
#   - Godot at /Applications/Godot.app/Contents/MacOS/Godot
#
# Total runtime: 10-20 min on a fresh clone, seconds if everything's cached.

set -e

GODOT="/Applications/Godot.app/Contents/MacOS/Godot"
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PRUNE=1

for arg in "$@"; do
	case "$arg" in
		--no-prune) PRUNE=0 ;;
		--prune) PRUNE=1 ;;  # legacy alias — was the opt-in flag, now default
		*) echo "Unknown arg: $arg"; exit 1 ;;
	esac
done

cd "$REPO_ROOT"

echo "=== [1/3] Priming dialogue + level audio (variants × handles × devices) ==="
"$GODOT" --headless res://tools/prime_all_dialogue.tscn --quit-after 1800

echo
echo "=== [2/3] Re-importing res:// so new mp3s get .import sidecars ==="
"$GODOT" --headless --import --path .

echo
echo "=== [3/3] Orphan cache scan ==="
if [ "$PRUNE" -eq 1 ]; then
	"$GODOT" --headless res://tools/find_orphan_voices.tscn --quit-after 60 -- delete
else
	"$GODOT" --headless res://tools/find_orphan_voices.tscn --quit-after 60
fi

echo
echo "=== Counts ==="
MP3=$(ls audio/voice_cache/*.mp3 2>/dev/null | wc -l | tr -d ' ')
IMPORTS=$(ls audio/voice_cache/*.mp3.import 2>/dev/null | wc -l | tr -d ' ')
echo "  mp3:     $MP3"
echo "  .import: $IMPORTS"
if [ "$MP3" -ne "$IMPORTS" ]; then
	echo "  ⚠️  COUNT MISMATCH — re-run --import or check for orphan .import files"
	exit 1
fi
echo
echo "Done. Run 'git add audio/voice_cache/ && git status' to see new cache files."
