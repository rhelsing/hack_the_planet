extends CanvasLayer
## HUD root. Thin — holds the anchor shells and instanced components.
## Each component owns its own subscriptions in its own _ready; the root
## doesn't mediate traffic. The only reason this script exists at all is
## so future HUD-wide concerns (freeze during cutscene, fade-all on death,
## etc.) have one clear landing spot.

func _ready() -> void:
	# HUD belongs to gameplay only — never on the main menu. The scene tree
	# guarantees this (we're a child of game.tscn), but call it out.
	layer = 0
	# Register so the cutscene engine (and anything else that wants to
	# show/hide gameplay UI wholesale) can find us via the "hud" group.
	# See docs/cutscene_engine.md §10.6.
	add_to_group(&"hud")
