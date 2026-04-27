shader_type spatial;
render_mode unshaded, blend_mix, depth_draw_opaque, cull_back;

// Combined body-overlay shader. Drives:
//   - damage_alpha: solid-red flush for take_hit (replaces the StandardMaterial3D
//     overlay KayKit used to use; same effect, single overlay slot).
//   - glitch_progress: cyan/magenta scanline tear + vertex jitter, used by the
//     death-burst flicker and the ambient 5/7/13s flicker. Outputs solid bands
//     plus EMISSION so the effect glows even on dark body parts.
//   - faction_tint / faction_amount: persistent color flush for faction state
//     (red splice corruption, gold ally conversion). Composites under the
//     transient damage + glitch passes so a hit-flush still reads on top of
//     the persistent tint.

uniform float damage_alpha : hint_range(0.0, 1.0) = 0.0;
uniform vec3 damage_color : source_color = vec3(1.0, 0.12, 0.12);
uniform float glitch_progress : hint_range(0.0, 1.0) = 0.0;
uniform vec3 glitch_color_a : source_color = vec3(1.0, 0.1, 0.7);
uniform vec3 glitch_color_b : source_color = vec3(0.1, 1.0, 1.0);
uniform vec3 faction_tint : source_color = vec3(1.0, 1.0, 1.0);
uniform float faction_amount : hint_range(0.0, 1.0) = 0.0;

float hash21(vec2 p) {
	p = fract(p * vec2(443.897, 441.423));
	p += dot(p, p.yx + 19.19);
	return fract((p.x + p.y) * p.x);
}

void vertex() {
	float row = floor(VERTEX.y * 30.0);
	float jitter = (hash21(vec2(row, floor(TIME * 18.0))) - 0.5) * 0.06 * glitch_progress;
	VERTEX.x += jitter;
}

void fragment() {
	float t = TIME;
	float row = floor(UV.y * 50.0 + t * 6.0);
	float noise = hash21(vec2(row, floor(t * 14.0)));
	vec3 glitch_col = mix(glitch_color_a, glitch_color_b, step(0.5, noise));
	// Sharp band: ~70% of rows light up at peak progress (no half-alpha).
	float band = step(0.3, noise) * glitch_progress;
	// Layer order: faction tint (persistent floor) → damage flush → glitch
	// bands (top). Faction's alpha contribution is just `faction_amount`,
	// so a low amount = subtle wash; transient damage/glitch override above.
	vec3 col = mix(damage_color, glitch_col, band);
	float alpha = max(faction_amount, max(damage_alpha, band));
	// Where there's NO transient effect, ALBEDO falls to the faction tint.
	float transient = max(damage_alpha, band);
	col = mix(faction_tint, col, transient);
	ALBEDO = col;
	ALPHA = alpha;
	// Glow: EMISSION ignores ALPHA so the bands punch through dark albedo.
	EMISSION = glitch_col * band * 1.8;
}
