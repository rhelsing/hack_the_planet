// Shared procedural bump layer: micro-scratches + smudges + pitting.
// Included by both platform.gdshader and building.gdshader. Uniforms declared
// here appear in the including material's inspector — keep names unique.

group_uniforms bump;
uniform float scratch_strength : hint_range(0.0, 1.0) = 0.35;
uniform float smudge_strength  : hint_range(0.0, 1.0) = 0.25;
uniform float pit_strength     : hint_range(0.0, 1.0) = 0.15;
uniform float bump_scale       : hint_range(0.05, 5.0) = 1.0;
group_uniforms;

float bump_hash21(vec2 p) {
	p = fract(p * vec2(443.897, 441.423));
	p += dot(p, p.yx + 19.19);
	return fract((p.x + p.y) * p.x);
}

vec2 bump_hash22(vec2 p) {
	return vec2(bump_hash21(p), bump_hash21(p + 17.0));
}

// Value noise in [0,1].
float bump_value_noise(vec2 p) {
	vec2 i = floor(p);
	vec2 f = fract(p);
	vec2 u = f * f * (3.0 - 2.0 * f);
	float a = bump_hash21(i);
	float b = bump_hash21(i + vec2(1.0, 0.0));
	float c = bump_hash21(i + vec2(0.0, 1.0));
	float d = bump_hash21(i + vec2(1.0, 1.0));
	return mix(mix(a, b, u.x), mix(c, d, u.x), u.y);
}

// 3-octave FBM for smudges.
float bump_fbm(vec2 p) {
	float v = 0.0;
	float amp = 0.5;
	for (int i = 0; i < 3; i++) {
		v += amp * bump_value_noise(p);
		p *= 2.03;
		amp *= 0.5;
	}
	return v;
}

// Smooth voronoi F1 — returns a continuous scalar with dark centers (pits).
float bump_smooth_voronoi(vec2 p) {
	vec2 n = floor(p);
	vec2 f = fract(p);
	float res = 0.0;
	for (int j = -1; j <= 1; j++) {
		for (int i = -1; i <= 1; i++) {
			vec2 g = vec2(float(i), float(j));
			vec2 o = bump_hash22(n + g);
			vec2 r = g + o - f;
			float d = dot(r, r);
			res += exp(-32.0 * d);
		}
	}
	return -(1.0 / 32.0) * log(res);
}

// Anisotropic scratches: high freq along X, low freq along Y of the sample uv.
float bump_scratches(vec2 uv) {
	vec2 p = uv * vec2(60.0, 6.0);
	return bump_value_noise(p);
}

// Combined height scalar in [0,1]-ish. Each layer contributes proportional to
// its strength uniform, so zeroing a uniform cleanly kills that pass's cost.
float bump_height(vec2 uv) {
	float h = 0.0;
	if (scratch_strength > 0.0) {
		h += bump_scratches(uv) * scratch_strength;
	}
	if (smudge_strength > 0.0) {
		h += bump_fbm(uv * 0.8) * smudge_strength;
	}
	if (pit_strength > 0.0) {
		h += (1.0 - bump_smooth_voronoi(uv * 3.0)) * pit_strength;
	}
	return h;
}

// Triplanar-projected bump height from world position.
float bump_height_triplanar(vec3 world_pos, vec3 world_normal, float triplanar_sharpness) {
	vec3 p = world_pos * bump_scale;
	float hx = bump_height(p.yz);
	float hy = bump_height(p.xz);
	float hz = bump_height(p.xy);
	vec3 w = pow(abs(world_normal), vec3(triplanar_sharpness));
	float wsum = max(w.x + w.y + w.z, 1e-4);
	return (hx * w.x + hy * w.y + hz * w.z) / wsum;
}

// World-space gradient bump: perturbs the world-space normal using central
// differences of the height field. No tangent frame required — well-suited
// to CSG, which doesn't supply reliable tangents.
vec3 bump_perturb_normal(vec3 world_pos, vec3 world_normal, float triplanar_sharpness, float strength) {
	if (strength <= 0.0) return world_normal;
	float eps = 0.02 / max(bump_scale, 0.01);
	float h  = bump_height_triplanar(world_pos, world_normal, triplanar_sharpness);
	float hx = bump_height_triplanar(world_pos + vec3(eps, 0.0, 0.0), world_normal, triplanar_sharpness);
	float hy = bump_height_triplanar(world_pos + vec3(0.0, eps, 0.0), world_normal, triplanar_sharpness);
	float hz = bump_height_triplanar(world_pos + vec3(0.0, 0.0, eps), world_normal, triplanar_sharpness);
	vec3 grad = vec3(hx - h, hy - h, hz - h) / eps;
	return normalize(world_normal - grad * strength);
}
