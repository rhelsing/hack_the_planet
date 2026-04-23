shader_type canvas_item;

// Full-screen glitch overlay. Renders terminal-style static + scanlines +
// a slight chromatic aberration, faded by `alpha`. No screen_texture sample
// — the scene swap happens while alpha == 1, so we don't care what's behind.

uniform float alpha : hint_range(0.0, 1.0) = 0.0;
uniform vec3 tint : source_color = vec3(0.2, 1.0, 0.4);
uniform float scan_density : hint_range(0.5, 512.0) = 256.0;
uniform float noise_strength : hint_range(0.0, 2.0) = 1.1;

float hash21(vec2 p) {
	p = fract(p * vec2(443.897, 441.423));
	p += dot(p, p.yx + 19.19);
	return fract((p.x + p.y) * p.x);
}

void fragment() {
	// Time-jittered scanlines — rows march downward during the glitch.
	float row = UV.y * scan_density + TIME * 40.0;
	float scan = step(0.5, fract(row));

	// Per-row noise block — rows flicker as blocks.
	float block = hash21(vec2(floor(row), floor(TIME * 30.0))) * noise_strength;
	block = clamp(block, 0.0, 1.0);

	// Horizontal jitter stripes (smaller regions tear left/right).
	float jitter_row = floor(UV.y * 40.0 + TIME * 10.0);
	float jitter_on = step(0.85, hash21(vec2(jitter_row, floor(TIME * 12.0))));
	float jitter_v  = (hash21(vec2(jitter_row, 7.7)) - 0.5) * 0.08 * jitter_on;

	vec2 uv = UV;
	uv.x += jitter_v;

	float luminance = scan * block + block * 0.3;
	vec3 col = tint * luminance;

	// Vignette so edges darken — a little less "uniform wash," more CRT-y.
	vec2 c = uv - vec2(0.5);
	float vignette = 1.0 - smoothstep(0.55, 0.95, length(c));

	COLOR = vec4(col * vignette, alpha);
}
