shader_type canvas_item;

// Sample the texture once for the main image, then again offset + averaged
// over a small 3x3 tap for the shadow alpha. Composites main over shadow
// using standard porter-duff "over" so transparent regions of the source
// remain transparent in the output (no opaque shadow rect).

uniform vec4 shadow_color : source_color = vec4(0.0, 0.0, 0.0, 0.55);
uniform vec2 shadow_offset_px = vec2(6.0, 6.0);
uniform float shadow_softness_px : hint_range(0.0, 16.0) = 3.0;

void fragment() {
	vec2 tex_size = vec2(textureSize(TEXTURE, 0));
	vec2 ofs_uv = shadow_offset_px / tex_size;
	float soft = shadow_softness_px;

	float a = 0.0;
	float total = 0.0;
	for (float i = -1.0; i <= 1.0; i += 1.0) {
		for (float j = -1.0; j <= 1.0; j += 1.0) {
			vec2 b = vec2(i, j) * (soft / tex_size);
			a += texture(TEXTURE, UV - ofs_uv + b).a;
			total += 1.0;
		}
	}
	a /= total;

	vec4 main_color = texture(TEXTURE, UV);
	float sh_a = a * shadow_color.a;
	float out_a = main_color.a + sh_a * (1.0 - main_color.a);
	vec3 out_rgb = (main_color.rgb * main_color.a
		+ shadow_color.rgb * sh_a * (1.0 - main_color.a))
		/ max(out_a, 0.0001);
	COLOR = vec4(out_rgb, out_a);
}
