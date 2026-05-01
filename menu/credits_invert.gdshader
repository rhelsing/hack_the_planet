shader_type canvas_item;

// Every text pixel = inverse of the screen pixel directly under it,
// then rotated in HSV by `hue_shift` and saturated by `saturation_boost`.
// Tune both via the ShaderMaterial inspector; defaults push the inverted
// color a third of the way around the wheel and bump saturation 1.5x for
// a punchier glitch read.

// hue_shift iteration log (value baked into credits.tscn, NOT this default):
//   0.33 — shader default, gentle shift
//   0.53 — approved (Apr 2026), keep as fallback
//   0.73 — approved (May 2026), better
//   0.83 — testing
uniform sampler2D screen_tex : hint_screen_texture, repeat_disable, filter_linear_mipmap;
uniform float hue_shift : hint_range(-1.0, 1.0) = 0.33;
uniform float saturation_boost : hint_range(0.0, 3.0) = 1.5;
uniform float brightness : hint_range(0.0, 3.0) = 1.0;

vec3 rgb_to_hsv(vec3 c) {
	vec4 K = vec4(0.0, -1.0 / 3.0, 2.0 / 3.0, -1.0);
	vec4 p = mix(vec4(c.bg, K.wz), vec4(c.gb, K.xy), step(c.b, c.g));
	vec4 q = mix(vec4(p.xyw, c.r), vec4(c.r, p.yzx), step(p.x, c.r));
	float d = q.x - min(q.w, q.y);
	float e = 1.0e-10;
	return vec3(abs(q.z + (q.w - q.y) / (6.0 * d + e)), d / (q.x + e), q.x);
}

vec3 hsv_to_rgb(vec3 c) {
	vec4 K = vec4(1.0, 2.0 / 3.0, 1.0 / 3.0, 3.0);
	vec3 p = abs(fract(c.xxx + K.xyz) * 6.0 - K.www);
	return c.z * mix(K.xxx, clamp(p - K.xxx, 0.0, 1.0), c.y);
}

void fragment() {
	vec4 tex = texture(TEXTURE, UV);
	if (tex.a < 0.01) {
		discard;
	}
	vec3 screen_rgb = texture(screen_tex, SCREEN_UV).rgb;
	vec3 inverted = 1.0 - screen_rgb;
	vec3 hsv = rgb_to_hsv(inverted);
	hsv.x = fract(hsv.x + hue_shift);
	hsv.y = clamp(hsv.y * saturation_boost, 0.0, 1.0);
	hsv.z = clamp(hsv.z * brightness, 0.0, 1.0);
	vec3 final_rgb = hsv_to_rgb(hsv);
	COLOR = vec4(final_rgb, COLOR.a * tex.a);
}
