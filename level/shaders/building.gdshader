// Building material — frosted glass slab, blue-lit from beneath, procedural
// code stripes on the side walls, fresnel rim.
//
// Reflections: sky-only + SSR via PBR outputs. Toggle SSR/SSIL on the scene's
// WorldEnvironment — no shader edits required.

shader_type spatial;
render_mode blend_mix, depth_prepass_alpha, cull_disabled;

#include "res://level/shaders/shared_bump.gdshaderinc"

// Kept declared so the v2 frosted-blur path can reactivate without reimport.
// When re-enabling, see "frosted v2" block near the bottom of fragment().
uniform sampler2D screen_texture : hint_screen_texture, filter_linear_mipmap, repeat_disable;

group_uniforms palette;
uniform vec3 palette_black : source_color = vec3(0.0, 0.0, 0.0);
uniform vec3 palette_blue  : source_color = vec3(0.12, 0.48, 1.0);
group_uniforms;

group_uniforms triplanar;
uniform float triplanar_scale     : hint_range(0.05, 5.0)  = 0.5;
uniform float triplanar_sharpness : hint_range(1.0, 16.0)  = 4.0;
group_uniforms;

group_uniforms glass;
uniform float glass_clarity        : hint_range(0.0, 1.0) = 0.35;
uniform float glass_tint_strength  : hint_range(0.0, 1.0) = 0.08;
uniform float refraction_strength  : hint_range(0.0, 0.2) = 0.02;
uniform float max_blur_lod         : hint_range(0.0, 6.0) = 4.0;
uniform float glass_roughness_min  : hint_range(0.0, 1.0) = 0.10;
uniform float glass_roughness_max  : hint_range(0.0, 1.0) = 0.45;
group_uniforms;

group_uniforms base_glow;
// Per-instance: set these on each CSGBox to match its local-Y bounds.
// bottom = VERTEX.y at the bottom face, top_of_glow = how far up it bleeds.
instance uniform float base_glow_bottom    = -3.0;
instance uniform float base_glow_top_local = 5.0;
uniform float base_glow_intensity   : hint_range(0.0, 4.0) = 1.5;
uniform float base_glow_falloff     : hint_range(0.5, 6.0) = 2.0;
// Solid-blue "floor" override for the bottom face of the CSG (local-Y down).
// Picked via the box's local normal so rotated CSGs still hit the correct face.
uniform float bottom_face_intensity : hint_range(0.0, 8.0) = 2.5;
group_uniforms;

group_uniforms code_overlay;
uniform float code_row_density    : hint_range(1.0, 60.0) = 18.0;
uniform float code_opacity        : hint_range(0.0, 1.0)  = 0.35;
uniform float code_scroll_speed   : hint_range(0.0, 2.0)  = 0.15;
uniform float code_drift_threshold: hint_range(0.0, 1.0)  = 0.92;
group_uniforms;

group_uniforms rim;
uniform float rim_power     : hint_range(0.5, 8.0) = 3.0;
uniform float rim_intensity : hint_range(0.0, 4.0) = 0.6;
group_uniforms;

varying vec3  v_world_pos;
varying vec3  v_world_normal;
varying vec3  v_local_normal;
varying float v_local_y;

void vertex() {
	v_local_y      = VERTEX.y;
	v_local_normal = NORMAL;
	v_world_pos    = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	v_world_normal = normalize((MODEL_MATRIX * vec4(NORMAL, 0.0)).xyz);
}

float code_hash1(float x) {
	return fract(sin(x * 91.3458) * 47453.5453);
}

float code_hash2(vec2 p) {
	return fract(sin(dot(p, vec2(12.9898, 78.233))) * 43758.5453);
}

// One 2D projection of the code-stripes pattern. wall_uv.y runs vertically
// (rows), wall_uv.x runs horizontally along the wall (blocks in a row).
//
// Drift: rows whose hash beats code_drift_threshold scroll at code_scroll_speed
// in a hash-derived direction. Smoothstep'd so speed ramps instead of snapping.
float eval_code_2d(vec2 wall_uv) {
	float row = floor(wall_uv.y * code_row_density);
	float rh  = code_hash1(row);
	float drift_mask = smoothstep(code_drift_threshold, code_drift_threshold + 0.08, rh);
	float row_dir = sign(code_hash1(row + 31.7) - 0.5);
	float x = wall_uv.x * 2.4 + rh * 13.0 + TIME * drift_mask * row_dir * code_scroll_speed;
	float block = floor(x);
	float on = step(0.55, code_hash2(vec2(row, block)));
	return on;
}

void fragment() {
	vec3 world_n = normalize(v_world_normal);

	// Emission color: normalize palette_blue so *_intensity sliders map
	// directly to HDR luminance regardless of how dark the blue is (same
	// fix as platform.gdshader — keeps bloom engaging on any hue).
	float palette_max = max(max(palette_blue.r, palette_blue.g), max(palette_blue.b, 1e-4));
	vec3  emit_color  = palette_blue / palette_max;

	// Bottom-face override: the local-Y-down face is a solid opaque blue
	// emissive plate — the building's "floor" glowing up through the glass.
	// Using the local normal (pre-MODEL transform) so rotated CSGs still
	// pick the box's own bottom, not world-down.
	bool is_bottom = v_local_normal.y < -0.5;

	// Bump: three-pass procedural, triplanar-projected.
	float bump_str = max(scratch_strength, max(smudge_strength, pit_strength));
	vec3 world_n_perturbed = bump_perturb_normal(v_world_pos, world_n, triplanar_sharpness, bump_str);

	// Glass body: a milky-blue tint that Godot will alpha-blend over whatever
	// sits behind. ALPHA (set below) is what actually makes it transparent —
	// we're not manually compositing the back-buffer. That keeps transparency
	// honest regardless of what's behind the building (sky, other objects…).
	vec3 milky = palette_blue * 0.5 + vec3(0.05);
	vec3 clear_tint = mix(vec3(1.0), palette_blue, glass_tint_strength);
	vec3 albedo_out = mix(milky, clear_tint, glass_clarity);

	// frosted v2: to re-enable a screen-space blur "frosted" overlay, compute
	//   vec2 refract_offset = (world_n_perturbed - world_n).xy * refraction_strength;
	//   float blur_lod = mix(max_blur_lod, 0.0, glass_clarity);
	//   vec3 behind = textureLod(screen_texture, SCREEN_UV + refract_offset, blur_lod).rgb;
	// then blend `behind` into `albedo_out` and pin ALPHA to 1.0 (manual composite).
	// That path double-counts the back-buffer if ALPHA<1, so it replaces the
	// alpha-blending path entirely, not composes with it.

	// Base glow — keyed to local-Y so rotated CSGs still glow from the bottom.
	float glow_t = smoothstep(base_glow_top_local, base_glow_bottom, v_local_y);
	float glow   = pow(glow_t, base_glow_falloff) * base_glow_intensity;
	vec3  glow_emission = emit_color * glow;

	// Code overlay — side walls only, built in the two horizontal triplanar axes.
	float cx = eval_code_2d(v_world_pos.zy);
	float cz = eval_code_2d(v_world_pos.xy);
	vec3  n_abs = abs(world_n);
	vec3  n_wt  = pow(vec3(n_abs.x, 0.0, n_abs.z), vec3(triplanar_sharpness));
	float wsum  = max(n_wt.x + n_wt.z, 1e-4);
	float code  = (cx * n_wt.x + cz * n_wt.z) / wsum;
	float side_weight = 1.0 - pow(n_abs.y, 2.0);
	code *= code_opacity * side_weight;
	vec3  code_emission = emit_color * code;

	// Rim — classic fresnel at silhouette.
	vec3 view_world = normalize((INV_VIEW_MATRIX * vec4(VIEW, 0.0)).xyz);
	float rim = pow(1.0 - max(dot(world_n_perturbed, view_world), 0.0), rim_power);
	vec3  rim_emission = emit_color * rim * rim_intensity;

	if (is_bottom) {
		ALBEDO   = emit_color * 0.15;
		EMISSION = emit_color * bottom_face_intensity;
		ROUGHNESS= 1.0;
		METALLIC = 0.0;
		NORMAL   = (VIEW_MATRIX * vec4(world_n, 0.0)).xyz;
		ALPHA    = 1.0;
	} else {
		ALBEDO   = albedo_out;
		EMISSION = glow_emission + code_emission + rim_emission;
		ROUGHNESS= mix(glass_roughness_max, glass_roughness_min, glass_clarity);
		METALLIC = 0.0;
		NORMAL   = (VIEW_MATRIX * vec4(world_n_perturbed, 0.0)).xyz;
		// Real Godot alpha blending. 0 = transparent, 1 = opaque.
		// clarity=0 → frosted-opaque; clarity=1 → clear-see-through.
		ALPHA    = mix(0.85, 0.15, glass_clarity);
	}
}
