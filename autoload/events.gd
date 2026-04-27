extends Node

## Central signal bus. Autoloads are globally reachable by name, so signals
## here act as a zero-import broadcast — `Events.door_opened.connect(...)`
## from anywhere. See docs/interactables.md §6 + sync_up.md for the bus-vs-
## local-signal contract.

# ── Existing world events (auto-trigger interactables — see docs §18) ────

@warning_ignore("unused_signal")
signal kill_plane_touched(body: PhysicsBody3D)
@warning_ignore("unused_signal")
signal enemy_hit_player(impulse: Vector3)
@warning_ignore("unused_signal")
signal coin_collected(coin: Node)
@warning_ignore("unused_signal")
signal flag_reached
@warning_ignore("unused_signal")
signal rail_touched(rail: Node, body: Node)
@warning_ignore("unused_signal")
signal checkpoint_reached(position: Vector3)

# ── interactables_dev / docs/interactables.md additions ─────────────────

# Action-activated interactables.
@warning_ignore("unused_signal")
signal door_opened(id: StringName)

# Dialogue lifecycle (emitted by the Dialogue autoload).
@warning_ignore("unused_signal")
signal dialogue_started(conversation_id: StringName)
@warning_ignore("unused_signal")
signal dialogue_line_shown(character: StringName, text: String)
@warning_ignore("unused_signal")
signal dialogue_ended(conversation_id: StringName)

# Puzzle lifecycle (emitted by the Puzzles autoload).
@warning_ignore("unused_signal")
signal puzzle_started(puzzle_id: StringName)
@warning_ignore("unused_signal")
signal puzzle_solved(puzzle_id: StringName)
@warning_ignore("unused_signal")
signal puzzle_failed(puzzle_id: StringName)

# Inventory + world flags (emitted by GameState).
@warning_ignore("unused_signal")
signal item_added(id: StringName)
@warning_ignore("unused_signal")
signal item_removed(id: StringName)
@warning_ignore("unused_signal")
signal flag_set(id: StringName, value: Variant)

# Pawn faction lifecycle (emitted by PlayerBody.set_faction). Listeners can
# react to enemy → ally conversions, splice corruption, etc.
@warning_ignore("unused_signal")
signal faction_changed(pawn: Node, faction: StringName)

# Skill-check lifecycle (emitted by Skills autoload). For animation/SFX hooks
# and HUD stat readouts later. succeeded: true/false; chance_pct: 0-100.
# chance_pct carries the EFFECTIVE chance (base + level bonus, post-clamp).
@warning_ignore("unused_signal")
signal skill_check_rolled(skill: StringName, chance_pct: int, succeeded: bool)
@warning_ignore("unused_signal")
signal skill_cooldown_started(skill: StringName, seconds: float)
@warning_ignore("unused_signal")
signal skill_granted(skill: StringName, new_level: int)

# ── ui_dev / menus.md additions ──────────────────────────────────────────
# Modal stack: anyone (Dialogue, Puzzles, PauseMenu, SettingsMenu, etc.) that
# wants consumers to know "a modal is up" emits modal_opened(&"id") on show
# and modal_closed(&"id") on hide. Consumers keep a counter; they're up when
# the count > 0. modal_count_reset is a debug-panel escape hatch only.
@warning_ignore("unused_signal")
signal modal_opened(id: StringName)
@warning_ignore("unused_signal")
signal modal_closed(id: StringName)
@warning_ignore("unused_signal")
signal modal_count_reset

# Settings lifecycle: broad re-read signal. Audio, Dialogue, PlayerBrain, etc.
# subscribe in _ready and re-pull the Settings keys they consume.
@warning_ignore("unused_signal")
signal settings_applied

# Save/load lifecycle.
@warning_ignore("unused_signal")
signal game_saved(slot: StringName)
@warning_ignore("unused_signal")
signal game_loaded(slot: StringName)

# Menu navigation — for SFX hooks, analytics, per-menu background tweaks.
@warning_ignore("unused_signal")
signal menu_opened(id: StringName)
@warning_ignore("unused_signal")
signal menu_closed(id: StringName)

# Respawn-message zones. Player walks/falls into a RespawnMessageZone Area3D →
# zone fires armed(text). PlayerBody stores it; on the next death-respawn it
# fires show(text). RespawnMessageOverlay (CanvasLayer) listens to show() and
# fades a centered label. Latest-armed wins; cleared after one show.
@warning_ignore("unused_signal")
signal respawn_message_armed(text: String)
@warning_ignore("unused_signal")
signal respawn_message_show(text: String)

# Voiced sibling of respawn_message_*. Same arm-on-entry / fire-on-respawn
# semantics, but routes to the Companion bus (reverb voice) instead of the
# center-screen label. RespawnMessageZone fires armed when its voice_line is
# set; PlayerBody queues, then on respawn waits a settle window and calls
# Companion.speak per entry. No visual label appears for these.
@warning_ignore("unused_signal")
signal respawn_voice_armed(character: String, line: String)
