shader_type canvas_item;

// Chromatic glitch transition. Samples the rendered scene below the
// CanvasLayer and applies horizontal RGB channel separation that ramps
// with `alpha`. No scanline overlay — the scene (and any loading UI)
// stays visible throughout; the glitch is purely a distort-and-resolve
// pass. The scene swap during alpha == 1 is visible by design.

uniform float alpha : hint_range(0.0, 1.0) = 0.0;
// Chromatic aberration peak at alpha == 1. Channels split horizontally
// in opposite directions, with green held centered.
uniform float aberration_max : hint_range(0.0, 0.05) = 0.012;
// Sparse horizontal jitter rows that tear left/right at the glitch peak.
// Set to 0 to disable.
uniform float jitter_amplitude : hint_range(0.0, 0.2) = 0.04;
uniform sampler2D screen_texture : hint_screen_texture, filter_nearest;

float hash21(vec2 p) {
	p = fract(p * vec2(443.897, 441.423));
	p += dot(p, p.yx + 19.19);
	return fract((p.x + p.y) * p.x);
}

void fragment() {
	// Sparse horizontal jitter — only ~15% of rows tear in any given frame,
	// scaled by alpha so the world is steady at rest.
	float jitter_row = floor(UV.y * 40.0 + TIME * 10.0);
	float jitter_on = step(0.85, hash21(vec2(jitter_row, floor(TIME * 12.0))));
	float jitter_v  = (hash21(vec2(jitter_row, 7.7)) - 0.5) * jitter_amplitude * jitter_on * alpha;

	vec2 uv = UV;
	uv.x += jitter_v;

	// Horizontal RGB split. R and B sample at opposite offsets, G stays
	// centered. Aberration scales with alpha — clean at rest.
	float aberr = aberration_max * alpha;
	vec3 col;
	col.r = textureLod(screen_texture, uv + vec2(aberr, 0.0), 0.0).r;
	col.g = textureLod(screen_texture, uv,                    0.0).g;
	col.b = textureLod(screen_texture, uv - vec2(aberr, 0.0), 0.0).b;

	// Edge vignette during the glitch — fades out cleanly when alpha hits 0.
	vec2 c = uv - vec2(0.5);
	float vignette = 1.0 - smoothstep(0.55, 0.95, length(c));
	col *= mix(1.0, vignette, alpha);

	COLOR = vec4(col, 1.0);
}
