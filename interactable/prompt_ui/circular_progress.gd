extends Control
class_name CircularProgress

## Donut-shaped progress indicator. Used by PromptUI's hold-to-confirm
## affordance — a dark blue track with a cyan glowing arc that fills
## clockwise from 12 o'clock as `value` rises 0 → 1.
##
## Drawn via three arc passes per frame (cheap on _draw): full track,
## halo (thicker + faded for the "glowing" effect), then the core
## bright arc on top. queue_redraw fires only on value changes.

@export_range(0.0, 1.0) var value: float = 0.0:
	set(v):
		var nv: float = clampf(v, 0.0, 1.0)
		if nv == value:
			return
		value = nv
		queue_redraw()

## Radius of the arc centerline (inner+outer radii are ±thickness/2 from this).
@export var radius: float = 40.0
## Stroke width in pixels. Halo is drawn at 2.5× this with reduced alpha.
@export var thickness: float = 10.0

## Track behind the fill — visible at all times. Default deep navy at 0.8α.
@export var track_color: Color = Color(0.04, 0.10, 0.32, 0.8)
## The progressing arc. Cyan, fully opaque so it pops against the track.
@export var fill_color: Color = Color(0.2, 1.0, 1.0, 1.0)
## Faded duplicate of `fill_color` drawn thicker — gives the "glow" feel
## without needing a real bloom shader pass. ~0.35 alpha reads as halo.
@export var glow_color: Color = Color(0.2, 1.0, 1.0, 0.35)

const _ARC_SEGMENTS: int = 64


func _ready() -> void:
	# Reserve enough space for the halo to render without clipping.
	var span: float = (radius + thickness * 2.0) * 2.0
	custom_minimum_size = Vector2(span, span)


func _draw() -> void:
	var center: Vector2 = size / 2.0
	# Full track ring — drawn first, so the fill paints over it.
	draw_arc(center, radius, 0.0, TAU, _ARC_SEGMENTS, track_color, thickness, true)
	if value <= 0.0:
		return
	# Start at 12 o'clock (-PI/2), wind clockwise (positive angle increase).
	var start_angle: float = -PI / 2.0
	var end_angle: float = start_angle + value * TAU
	# Halo first, core on top — gives the appearance of the bright stroke
	# bleeding outward without any actual blur or shader work.
	draw_arc(center, radius, start_angle, end_angle, _ARC_SEGMENTS,
			glow_color, thickness * 2.5, true)
	draw_arc(center, radius, start_angle, end_angle, _ARC_SEGMENTS,
			fill_color, thickness, true)
