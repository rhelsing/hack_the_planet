// Platform material — scratched acrylic over sparse Tron-style purple circuitry.
//
// Reflections: sky-only today via PBR outputs. To enable SSR + ReflectionProbe
// contributions, toggle them on the scene's WorldEnvironment — no shader edits.

shader_type spatial;
render_mode specular_schlick_ggx, cull_back;

#include "res://level/shaders/shared_bump.gdshaderinc"

group_uniforms palette;
uniform vec3 palette_black  : source_color = vec3(0.0, 0.0, 0.0);
uniform vec3 palette_purple : source_color = vec3(0.48, 0.17, 0.91);
group_uniforms;

group_uniforms triplanar;
uniform float triplanar_scale     : hint_range(0.05, 5.0)  = 0.5;
uniform float triplanar_sharpness : hint_range(1.0, 16.0)  = 4.0;
group_uniforms;

group_uniforms circuit;
uniform float circuit_density       : hint_range(0.5, 16.0) = 4.0;
uniform float trace_probability     : hint_range(0.0, 1.0)  = 0.35;
uniform float trace_width           : hint_range(0.01, 0.3) = 0.08;
uniform float trace_glow            : hint_range(0.0, 4.0)  = 0.22;
// Clustering: 0 = uniform grid; 1 = traces pool into organic hotspots separated
// by dead zones. Drives trace_probability per region via low-freq FBM so you
// can push density high and still read as clustered circuitry, not a grid.
uniform float circuit_clustering    : hint_range(0.0, 1.0)  = 0.6;
uniform float circuit_cluster_scale : hint_range(0.05, 5.0) = 0.3;
group_uniforms;

group_uniforms pulses;
uniform float pulse_speed_base     : hint_range(0.0, 4.0)  = 0.6;
uniform float pulse_speed_variance : hint_range(0.0, 4.0)  = 1.5;
uniform float pulse_width          : hint_range(0.01, 0.5) = 0.12;
uniform float pulse_brightness     : hint_range(0.0, 4.0)  = 1.0;
uniform float pulse_density        : hint_range(0.0, 1.0)  = 0.6;
group_uniforms;

group_uniforms acrylic;
uniform float acrylic_roughness        : hint_range(0.0, 1.0) = 0.18;
uniform float acrylic_metallic         : hint_range(0.0, 1.0) = 0.0;
uniform float acrylic_fresnel_power    : hint_range(0.5, 8.0) = 3.0;
uniform float acrylic_reflect_strength : hint_range(0.0, 2.0) = 0.6;
group_uniforms;

varying vec3 v_world_pos;
varying vec3 v_world_normal;

void vertex() {
	v_world_pos    = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	v_world_normal = normalize((MODEL_MATRIX * vec4(NORMAL, 0.0)).xyz);
}

float circuit_hash21(vec2 p) {
	p = fract(p * vec2(443.897, 441.423));
	p += dot(p, p.yx + 19.19);
	return fract((p.x + p.y) * p.x);
}

// Evaluate one 2D projection's circuit contribution.
// Returns (trace_mask, pulse_mask). trace_mask is the always-on faint trace;
// pulse_mask is the animated bright pulse sliding from edge toward center.
//
// Routing: 4 edges of the unit cell are each hashed by their shared position
// with the neighbor cell, so activity agrees across cells → traces connect.
// Inside the cell, each active edge draws a line from its midpoint to center.
// Local density at a given edge midpoint. FBM is sampled at the shared midpoint
// so both cells touching the edge evaluate the same threshold → traces stay
// connected across cell boundaries even with aggressive clustering.
float circuit_edge_threshold(vec2 edge_pos) {
	float n = bump_fbm(edge_pos * circuit_cluster_scale);
	float lo = mix(1.0, 0.0, circuit_clustering);
	float hi = mix(1.0, 2.0, circuit_clustering);
	float p  = clamp(trace_probability * mix(lo, hi, n), 0.0, 1.0);
	return 1.0 - p;
}

vec2 eval_circuit_2d(vec2 uv) {
	vec2 cell = floor(uv);
	vec2 f    = uv - cell;

	vec2 ep_l = vec2(cell.x,        cell.y + 0.5);
	vec2 ep_r = vec2(cell.x + 1.0,  cell.y + 0.5);
	vec2 ep_b = vec2(cell.x + 0.5,  cell.y);
	vec2 ep_t = vec2(cell.x + 0.5,  cell.y + 1.0);

	float a_l = step(circuit_edge_threshold(ep_l), circuit_hash21(ep_l));
	float a_r = step(circuit_edge_threshold(ep_r), circuit_hash21(ep_r));
	float a_b = step(circuit_edge_threshold(ep_b), circuit_hash21(ep_b));
	float a_t = step(circuit_edge_threshold(ep_t), circuit_hash21(ep_t));

	vec2 center = vec2(0.5);
	float min_d = 1e9;
	float along = 0.0;

	// For each active edge, compute SDF distance to line (edge_midpoint → center)
	// and capture the along-trace parameter h of the nearest line.
	if (a_l > 0.5) {
		vec2 e = vec2(0.0, 0.5);
		vec2 ba = center - e;
		vec2 pa = f - e;
		float h = clamp(dot(pa, ba) / dot(ba, ba), 0.0, 1.0);
		float d = length(pa - ba * h);
		if (d < min_d) { min_d = d; along = h; }
	}
	if (a_r > 0.5) {
		vec2 e = vec2(1.0, 0.5);
		vec2 ba = center - e;
		vec2 pa = f - e;
		float h = clamp(dot(pa, ba) / dot(ba, ba), 0.0, 1.0);
		float d = length(pa - ba * h);
		if (d < min_d) { min_d = d; along = h; }
	}
	if (a_b > 0.5) {
		vec2 e = vec2(0.5, 0.0);
		vec2 ba = center - e;
		vec2 pa = f - e;
		float h = clamp(dot(pa, ba) / dot(ba, ba), 0.0, 1.0);
		float d = length(pa - ba * h);
		if (d < min_d) { min_d = d; along = h; }
	}
	if (a_t > 0.5) {
		vec2 e = vec2(0.5, 1.0);
		vec2 ba = center - e;
		vec2 pa = f - e;
		float h = clamp(dot(pa, ba) / dot(ba, ba), 0.0, 1.0);
		float d = length(pa - ba * h);
		if (d < min_d) { min_d = d; along = h; }
	}

	float mask = 1.0 - smoothstep(trace_width * 0.6, trace_width, min_d);

	// Per-cell pulse timing — hash drives phase and speed variance.
	float ch = circuit_hash21(cell + 17.3);
	float speed = pulse_speed_base * (0.5 + ch * pulse_speed_variance);
	float pulse_pos = fract(TIME * speed + ch);
	float pulse = smoothstep(pulse_width, 0.0, abs(along - pulse_pos));
	float pulse_gate = step(1.0 - pulse_density, circuit_hash21(cell + 101.0));

	return vec2(mask, mask * pulse * pulse_gate);
}

void fragment() {
	vec3 world_n = normalize(v_world_normal);
	vec3 wp = v_world_pos * triplanar_scale;

	// Circuit sampled in three world-space planes, blended by squared normal.
	vec2 cx = eval_circuit_2d(wp.yz * circuit_density);
	vec2 cy = eval_circuit_2d(wp.xz * circuit_density);
	vec2 cz = eval_circuit_2d(wp.xy * circuit_density);
	vec3 w  = pow(abs(world_n), vec3(triplanar_sharpness));
	float wsum = max(w.x + w.y + w.z, 1e-4);
	float trace_mask = (cx.x * w.x + cy.x * w.y + cz.x * w.z) / wsum;
	float pulse_amt  = (cx.y * w.x + cy.y * w.y + cz.y * w.z) / wsum;

	// Albedo: substrate + faint purple tint where traces sit.
	vec3 base_color = mix(palette_black, palette_purple, trace_mask * 0.35);

	// Emission: normalize the purple by its max channel so trace_glow and
	// pulse_brightness map directly to HDR luminance. Without this, a dark
	// palette_purple caps the brightest channel below the bloom threshold
	// and the glow never engages regardless of the slider values.
	float palette_max = max(max(palette_purple.r, palette_purple.g), max(palette_purple.b, 1e-4));
	vec3  emit_color  = palette_purple / palette_max;
	vec3  emission    = emit_color * (trace_mask * trace_glow + pulse_amt * pulse_brightness);

	// Bump — triplanar-blended height → world-space normal perturbation.
	float bump_str = max(scratch_strength, max(smudge_strength, pit_strength));
	vec3 world_n_perturbed = bump_perturb_normal(v_world_pos, world_n, triplanar_sharpness, bump_str);

	// Fresnel boost on the acrylic — grazing angles reflect more.
	vec3 view_world = normalize((INV_VIEW_MATRIX * vec4(VIEW, 0.0)).xyz);
	float fres = pow(1.0 - max(dot(world_n_perturbed, view_world), 0.0), acrylic_fresnel_power);

	ALBEDO    = base_color;
	EMISSION  = emission;
	ROUGHNESS = acrylic_roughness;
	METALLIC  = acrylic_metallic;
	SPECULAR  = clamp(0.5 + fres * acrylic_reflect_strength * 0.5, 0.0, 1.0);
	NORMAL    = (VIEW_MATRIX * vec4(world_n_perturbed, 0.0)).xyz;
}
