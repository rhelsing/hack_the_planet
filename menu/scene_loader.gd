extends CanvasLayer
## Loader UI shown by the SceneLoader autoload. Renders a fake-terminal
## progress bar that falls back to an indeterminate spinner when the engine's
## threaded-load progress is stuck (known Godot 4.6 quirk on some backends —
## see docs/menus.md §9 + GH #56882 / #90076).

const BAR_WIDTH := 32   # characters in the ascii bar
const FLAVOR_ROT := 2.6 # seconds between flavor text swaps

const FLAVOR := [
	"> Bypassing ICE layer...",
	"> Probing firewall handshake...",
	"> Grinding rail data stream...",
	"> Spoofing badge RFID...",
	"> Injecting payload [█░░░]...",
	"> Mess with the best, die like the rest.",
	"> Never trust a terminal you can't physically unplug.",
	"> Backdoor's in the BIOS.",
	"> Mainframe responding on port 23...",
]

@onready var _bar_label: Label = %BarLabel
@onready var _pct_label: Label = %PctLabel
@onready var _flavor_label: Label = %FlavorLabel
@onready var _dots_label: Label = %DotsLabel

var _dots_accum: float = 0.0
var _flavor_accum: float = 0.0
var _indeterminate_phase: float = 0.0


func _ready() -> void:
	layer = 1000
	_flavor_label.text = FLAVOR.pick_random()
	set_progress(0.0)


func _process(delta: float) -> void:
	_dots_accum += delta
	_flavor_accum += delta
	_indeterminate_phase = fmod(_indeterminate_phase + delta * 8.0, float(BAR_WIDTH * 2))
	var dot_ct := int(fmod(_dots_accum * 2.5, 4.0))
	_dots_label.text = ".".repeat(dot_ct)
	if _flavor_accum >= FLAVOR_ROT:
		_flavor_accum = 0.0
		_flavor_label.text = FLAVOR.pick_random()


## Called by SceneLoader every tick. `p` is in [0, 1] for determinate, or
## a negative number to signal "stalled — show spinner."
func set_progress(p: float) -> void:
	if p < 0.0:
		_render_indeterminate()
	else:
		_render_determinate(clampf(p, 0.0, 1.0))


func _render_determinate(p: float) -> void:
	var filled := int(round(p * BAR_WIDTH))
	var bar := "█".repeat(filled) + "░".repeat(BAR_WIDTH - filled)
	_bar_label.text = "[%s]" % bar
	_pct_label.text = "%3d %%" % int(round(p * 100.0))


func _render_indeterminate() -> void:
	# Two-cell slug bouncing inside the bar.
	var width := BAR_WIDTH
	var pos := int(_indeterminate_phase) % (width * 2)
	if pos >= width:
		pos = (width * 2) - pos - 1
	var bar := ""
	for i in width:
		bar += "█" if (i == pos or i == pos + 1) else "░"
	_bar_label.text = "[%s]" % bar
	_pct_label.text = " --- "
