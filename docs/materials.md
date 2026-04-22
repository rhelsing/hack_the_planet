# Materials Spec — Platform & Building (v3, Forward+)

Implementation spec for the two `ShaderMaterial`s used by every CSG piece of level geometry. Every technical claim is tied to a Godot 4 doc page, an in-project reference file, or a community shader we'll model on — see **§ Sources** at the end.

---

## 0. Project facts that constrain everything

| Fact | Value | Source |
|---|---|---|
| Engine version | **Godot 4.6.2 stable** | runtime log: `Godot Engine v4.6.2.stable.official.71f334935` |
| Renderer | **Forward+** (Metal 4.0) | runtime log: `Metal 4.0 - Forward+ - Apple M1 Max (Apple7)` |
| Release target | **Desktop only** (no web, no mobile) | user direction |
| Per-user perf handled by | in-game settings menu (outside this doc) | user direction |
| House-style template | `level/interactable/flag/water.gdshader` | uses `hint_screen_texture`, `source_color`, `RADIANCE`/`IRRADIANCE`, terse comments, explicit `render_mode` |
| UID preservation | `platforms.tres` → `uid://da188d7yrcfr8`; `buildings.tres` → `uid://ucfwprjqe6oq` | existing files; referenced from `level/level.tscn` |

> `project.godot` line 19 still says `config/features=PackedStringArray("4.6", "Mobile")` — that's stale metadata from project creation. The authoritative fact is the runtime log. If this confuses future contributors, open Project Settings → Rendering → Rendering Method and re-save to rewrite the features line.

**Forward+ unlocks everything we need** ([Godot docs: renderers](https://docs.godotengine.org/en/stable/tutorials/3d/standard_material_3d.html)):
- SSR (screen-space reflections), including SSR contribution via standard PBR outputs.
- `hint_screen_texture` with mipmapped sampling — cheap blur for frosted glass.
- `hint_depth_texture` and `hint_normal_roughness_texture` — edge-aware blur, depth-based effects.
- Volumetric fog (already partially configured in `level.tscn`).
- SSIL (screen-space indirect lighting), SDFGI (optional, heavier).
- TAA — critical for thin Tron traces to not alias at distance.
- Clustered light culling (many small point lights are fine).

**House conventions (from `water.gdshader`):**
- `shader_type spatial;` + explicit `render_mode` line.
- `uniform vec3 foo_color : source_color = vec3(r,g,b);` for colors, `hint_range(…)` for sliders, `hint_normal` for normal maps, `hint_screen_texture` for screen grabs.
- Minimal comments — only where "what" is non-obvious.
- Normals composed in fragment via `TANGENT * nx + BINORMAL * ny + NORMAL * nz`.
- `RADIANCE` / `IRRADIANCE` writes permitted (used in `water.gdshader` Snell's-window code).

---

## 1. Godot-3-→-4 migration landmines

Get these right on the first pass ([docs: upgrading to Godot 4](https://docs.godotengine.org/en/stable/tutorials/migrating/upgrading_to_godot_4.html)):

| Godot 3 | Godot 4 |
|---|---|
| `WORLD_MATRIX` | `MODEL_MATRIX` |
| `WORLD_NORMAL_MATRIX` | `MODEL_NORMAL_MATRIX` |
| `CAMERA_MATRIX` | `INV_VIEW_MATRIX` |
| `INV_CAMERA_MATRIX` | `VIEW_MATRIX` |
| `SCREEN_TEXTURE` (builtin) | `uniform sampler2D screen_texture : hint_screen_texture, …` |
| `DEPTH_TEXTURE` (builtin) | `uniform sampler2D depth_texture : hint_depth_texture, …` (Forward+ ✓) |

Add `render_mode world_vertex_coords;` if we want `VERTEX` to be world-space inside `vertex()` (saves a `MODEL_MATRIX * VERTEX` multiply). Known quirk: breaks at large world offsets from origin. Our level is near origin (worst CSG is at x ≈ −163); verify early.

---

## 2. Shared foundation

### 2.1 Color cascade — 3 uniforms only

| Role | Default | Used in |
|---|---|---|
| `palette_black` | `vec3(0.0)` | substrate of both materials |
| `palette_purple` | `vec3(0.48, 0.17, 0.91)` | platform circuit traces, trace pulses |
| `palette_blue` | `vec3(0.12, 0.48, 1.00)` | building base glow, rim, code stripes |

Every derived color = `mix(palette_black, palette_*, t)` or a brightness scalar of those. No other color uniforms. Skybox reflections (sky purple + moon yellow) will leak in via SSR/radiance — accepted as ambient.

### 2.2 Triplanar — community-standard formula

CSG has no usable UVs, so both shaders project by world-space triplanar.

```glsl
// render_mode world_vertex_coords;  (VERTEX is world-space in vertex())
// Pass world_vertex varying to fragment.

vec3 triplanar_sample_pattern(vec3 world_pos, vec3 n, float scale, float sharp) {
    vec3 wx = pattern_1d(world_pos.yz * scale);
    vec3 wy = pattern_1d(world_pos.xz * scale);
    vec3 wz = pattern_1d(world_pos.xy * scale);
    vec3 w  = pow(abs(n), vec3(sharp));
    return (wx * w.x + wy * w.y + wz * w.z) / (w.x + w.y + w.z);
}
```

Formula reference: [godotshaders.com triplanar-mapping](https://godotshaders.com/shader/triplanar-mapping/). Current Godot default sharpness is `4.0` ([PR #50440](https://github.com/godotengine/godot/pull/50440)); our existing `platforms.tres` uses `10.0`. Start at `4.0`, expose the knob.

Uniforms:
- `triplanar_scale` (float, default `0.5`).
- `triplanar_sharpness` (float, default `4.0`).

**Accepted limitation:** triplanar produces visible "pattern change" at face boundaries on CSG. Fixing it requires real UVs, which CSG can't provide. Live with it.

### 2.3 Reflections — write PBR, let Forward+ compose

**Strategy:** write `ALBEDO`, `ROUGHNESS`, `METALLIC`, `NORMAL` from `fragment()`. Forward+ then composes:
1. Sky radiance (baked from the sky shader).
2. `ReflectionProbe` contribution if any probes cover the surface.
3. **SSR** for real-time reflections of screen-visible geometry.
4. SSIL / SDFGI if enabled on the environment.

Custom shaders cannot *manually* sample probes ([forum](https://forum.godotengine.org/t/access-reflection-probe-in-shader/103375)), but Forward+ does the right thing automatically when we output standard PBR. Good — this is less code, not a limitation.

For the platform's glassy acrylic look specifically, we want:
- `METALLIC` between `0.0` (plastic-like fresnel) and `0.3` (slight sheen). We'll stay non-metallic.
- `ROUGHNESS` in `0.1–0.25` range — low enough to reflect cleanly, not mirror-sharp.
- Forward+ SSR kicks in automatically whenever it's enabled on the `WorldEnvironment` (see §2.7).

### 2.4 Bump layer — three procedural passes, tangent-space

Shared across both materials. Implemented as `level/shaders/shared_bump.gdshaderinc`, included via `#include "res://level/shaders/shared_bump.gdshaderinc"`.

Three stacked height contributions:

1. **Micro-scratches:** anisotropic value noise, high frequency along one axis (`~60`), low on the other (`~6`). `scratch_strength`, default `0.35`. ([IQ value-noise derivatives](https://iquilezles.org/articles/morenoise/))
2. **Smudges:** low-frequency FBM, 3 octaves. `smudge_strength`, default `0.25`. ([IQ FBM](https://iquilezles.org/articles/fbm/))
3. **Pitting:** inverted smooth voronoi. `pit_strength`, default `0.15`. ([IQ smooth voronoi](https://iquilezles.org/articles/smoothvoronoi/))

Normal composition: produce scalar height `h`, derive a perturbed tangent-space normal, write `NORMAL_MAP` — Godot composes with `TANGENT`/`BINORMAL`/`NORMAL` automatically (same pattern as `water.gdshader` lines 27-29). No `dFdx(WORLD_VERTEX)` hacks.

### 2.5 Performance: uniforms are the settings-menu surface

The user's in-game settings menu will bind to these (and to `WorldEnvironment` properties in §2.7). Design guideline: every heavy pass should have a strength uniform that *zero* cleanly disables the work, guarded by `if (strength > 0.0)` for a real early-out.

**Shader-side uniforms a quality menu should expose:**
| Setting | Uniforms |
|---|---|
| "Surface detail: High/Med/Low/Off" | `pit_strength`, `smudge_strength` (0 disables voronoi/FBM work) |
| "Circuit animation: On/Static" | `pulse_density` (0 disables pulse loop) |
| "Code overlay: On/Off" | `code_opacity` (0 disables) |

**Scene-side settings to bind in the menu (on `WorldEnvironment`):**
SSR on/off, SSIL on/off, SDFGI on/off, TAA on/off, volumetric fog density. These are where the real perf lives on Forward+, not the shaders.

### 2.6 Emission + bloom + fog budget

`level.tscn`'s `Environment_5pwhg` has `glow_hdr_threshold = 0.26`, `glow_intensity = 4.98`, and `volumetric_fog_density = 0.01` with a yellow fog emission color. Forward+ runs the volumetric fog for real.

**HDR emission budget** (values picked so bloom reads as glow, not blown-out blobs; fog scattering eats a little brightness so we can sit slightly higher than the pure-bloom-only case):
- Faint always-on (traces, ambient glow): `0.15 – 0.30` (sub-threshold; no bloom, reads as "lit from within").
- Animated peaks (trace pulses, base-glow band): `0.8 – 1.5` (gentle bloom + fog scatter).
- Hard accents, rare (rim at grazing, brightest pulses): `1.8 – 2.5` max.

Volumetric fog note: our emission will **scatter through the air**, contributing significantly to the "hologram city" feel in the reference images. The `volumetric_fog_emission` color in `level.tscn` is currently yellow; for our palette we'd want to retint that — likely to a low-saturation purple/blue mix, or zero it out and let our materials' own emission drive fog light. Flagged for a scene pass after shaders land.

### 2.7 Forward+ environment tweaks to enable in `level.tscn`

These live on the `WorldEnvironment` node's `Environment_5pwhg` resource. Not shader changes — scene edits — but they're the other half of making the materials look right. Apply these *once* after shaders are in:

| Property | Value | Why |
|---|---|---|
| `ssr_enabled` | `true` | SSR on the acrylic platforms; currently off (default). Free once enabled. |
| `ssr_max_steps` | `32` (default) | Tune only if perf needs it. |
| `ssr_fade_in`/`fade_out` | defaults fine | |
| `ssil_enabled` | `true` | Soft indirect from emissive traces onto nearby surfaces. Small perf cost, nice look. |
| `sdfgi_enabled` | `false` initially, reconsider | Beautiful but expensive; "true" GI where the purple circuit lights up actual adjacent geometry. Worth trying once shaders are in. |
| `volumetric_fog_emission` | retint from yellow to palette-neutral (e.g. `vec3(0.05, 0.05, 0.08)`) | Don't double up — let shaders drive fog color via their own emission. |

Viewport (not environment): on the main `SubViewport` or the root viewport, set `use_taa = true` and `msaa_3d = 2` (your project.godot already has msaa_3d=2). Without TAA, 1-pixel-wide Tron traces will crawl.

**All of these should be bound to the user's settings menu** so low-end desktops can drop SSR/SSIL/SDFGI independently.

---

## 3. Platform material

### 3.1 Visual goal

Scratched acrylic sheet, slightly reflective via SSR+sky, with a **sparse Tron-style** purple circuit network visible underneath. Traces are angular, orthogonal, **connect across cells** (not per-cell stubs), with brighter purple pulses sliding along them at variable speeds. Reference: `Screenshots/Screenshot 2026-04-18 at 11.12.53 AM.png`.

### 3.2 Layer stack, back to front

1. **Substrate:** `palette_black`, flat.
2. **Connected Tron trace network** (see §3.3).
3. **Animated pulses** along traces (see §3.4).
4. **Acrylic coat:** bump + low roughness → Forward+ composes sky + SSR + probe radiance automatically (see §2.3).

### 3.3 Connected trace generation — Truchet tiling

Per-cell-hash of independent segments DOES NOT produce connected routing; use **Truchet tiling with edge-matched tile variants** ([Wikipedia](https://en.wikipedia.org/wiki/Truchet_tile); shader writeup: [Reinder Nijhoff](https://reindernijhoff.net/2019/10/truchet-tiles-simple-rules-infinite-patterns/)).

Implementation shape:
- Define 4–6 tile variants. Each tile has purple traces entering/exiting a subset of its 4 edges, from a pre-designed set that guarantees adjacent-tile edge compatibility under all rotations.
- `hash(cell)` picks tile type + rotation.
- One tile variant is "empty"; weight it to control sparseness via `trace_probability`.
- Optional: light domain warp before tile lookup ([IQ warp](https://iquilezles.org/articles/warp/)) so the grid isn't ruler-straight.

Anchor references: Shadertoy [Circuit Board (XsSXzR)](https://www.shadertoy.com/view/XsSXzR), [truchet 2 (4dS3Dc)](https://www.shadertoy.com/view/4dS3Dc).

Uniforms:
- `circuit_density` (float, default `4.0`) — cells per world unit.
- `trace_probability` (float, 0..1, default `0.35`).
- `trace_width` (float, default `0.08`) — fraction of cell size.
- `trace_glow` (float, default `0.22`) — sub-bloom-threshold ambient emission.

### 3.4 Pulse animation

Each tile eval outputs `mask` + `distance_along`. Phase is hashed per tile, speed has a variance knob:

```glsl
float phase  = hash(tile_id) * TAU + TIME * pulse_speed_base * (0.5 + hash2(tile_id) * pulse_speed_variance);
float pulse  = smoothstep(pulse_width, 0.0, fract(distance_along - phase));
vec3  color  = palette_purple * pulse_brightness * pulse;
```

Uniforms:
- `pulse_speed_base` (float, default `0.6`).
- `pulse_speed_variance` (float, default `1.5`).
- `pulse_width` (float, default `0.12`).
- `pulse_brightness` (float, default `1.0`) — slight bloom per §2.6.
- `pulse_density` (float, 0..1, default `0.6`) — fraction of tiles that carry a pulse.

### 3.5 Acrylic coat — Forward+ PBR, no transparency needed

The platform stays **opaque** (no `blend_mix`). We fake "circuit visible under acrylic" via emissive modulation, and let Forward+ SSR + sky radiance do the "glass sheen." Shader writes `ROUGHNESS` + `METALLIC` and Forward+ composes.

Uniforms:
- `acrylic_roughness` (float, default `0.18`).
- `acrylic_metallic` (float, default `0.0`).
- `acrylic_fresnel_power` (float, default `3.0`).
- `acrylic_reflect_strength` (float, default `0.6`) — tints how much of the reflected color contributes vs. the circuit underneath.

### 3.6 Full platform uniform list

```
palette_black, palette_purple, palette_blue : source_color
triplanar_scale, triplanar_sharpness

circuit_density, trace_probability, trace_width, trace_glow
pulse_speed_base, pulse_speed_variance, pulse_width, pulse_brightness, pulse_density

acrylic_roughness, acrylic_metallic, acrylic_fresnel_power, acrylic_reflect_strength

scratch_strength, smudge_strength, pit_strength
```

---

## 4. Building material

### 4.1 Visual goal

Real semi-transparent frosted glass with a `glass_clarity` slider driving both transparency and blur. At the base, a blue emissive band reads as light pouring up from under the building, bleeding 20–40% up the walls. On the side walls, an abstract procedural "code overlay" in blue — mostly static, with occasional drift on individual rows. Silhouette edges carry a classic fresnel rim in blue. Micro-scratches + smudges + pitting bump. Slight blue body tint. Reference: `Screenshots/Screenshot 2026-04-18 at 11.13.15 AM.png`.

### 4.2 Transparency — real frosted glass via screen-texture LOD blur

We're on Forward+, so we do this for real, not faked. Approach:

- `render_mode blend_mix, depth_prepass_alpha, cull_back;` — actual alpha blending, with a depth prepass so the building still receives shadows and writes depth for SSAO/SSR (this is what `water.gdshader` uses).
- `uniform sampler2D screen_texture : hint_screen_texture, filter_linear_mipmap;` — mipmap-filtered back-buffer.
- `uniform sampler2D depth_texture : hint_depth_texture, filter_linear_mipmap;` — Forward+ only; used for edge-aware blur so blur doesn't bleed across depth discontinuities.

**Blur strategy:** sample the screen texture at a mipmap LOD; LOD rises with `(1 - glass_clarity)`. This is the same trick used by [godotshaders.com frosted-glass-3](https://godotshaders.com/shader/frosted-glass-3/) and [Apple-blur-recreation](https://godotshaders.com/shader/apple-blur-shader-recreation/). Cheap, looks correct, no multi-tap loop. For slight refraction, offset SCREEN_UV by the bump-layer's tangent-space XY × a small scalar (identical to the `water.gdshader` screen-space-refraction pattern on line 31-32).

```glsl
vec2 distort = normal_perturbation.xy * refraction_strength;
float lod    = mix(max_blur_lod, 0.0, glass_clarity);
vec3 behind  = textureLod(screen_texture, SCREEN_UV + distort, lod).rgb;
```

**Sort-order caveat:** overlapping transparent buildings can flicker in z-sort. Mitigations: keep buildings spatially separated (current level does), or set `render_priority` per-material if needed. Not solving this preemptively.

### 4.3 Glass body

- `glass_clarity` (float, 0..1, default `0.35`) — drives:
  - `ALPHA = mix(0.55, 0.15, glass_clarity)` — thicker glass is more opaque.
  - `blur_lod` (see above) — thicker glass blurs more.
  - `roughness = mix(0.45, 0.10, glass_clarity)` — low roughness even when frosted; thick glass is softer.
- `glass_tint_strength` (float, default `0.08`) — `palette_blue` contribution to `ALBEDO`.
- `refraction_strength` (float, default `0.02`) — small SCREEN_UV offset from the bump normal.
- `max_blur_lod` (float, default `4.0`) — cap on mipmap LOD sampling.

### 4.4 Base emissive glow band

Keyed to **local-space Y** (not world Y), so rotated CSGs still glow from the correct face. In `vertex()`, pass `VERTEX.y` before `world_vertex_coords` transform as a varying. In `fragment()`, compute `glow = smoothstep(base_glow_height, 0.0, local_y_normalized) * base_glow_intensity`.

`base_glow_height` is a **fraction of the CSG's local-Y extent** (0..1), not world-units. Default `0.3` = glow fades out at 30% of the building's height.

Uniforms:
- `base_glow_height` (float, 0..1, default `0.3`).
- `base_glow_intensity` (float, default `1.5`) — slight bloom + volumetric scatter per §2.6.
- `base_glow_falloff` (float, default `2.0`) — >1 = concentrated at bottom.

(Per-instance `base_glow_axis` for odd CSGs where local-Y isn't "up" — deferred. Users can rotate the node transform instead.)

### 4.5 Code overlay on side walls

Abstract procedural stripes suggesting rows of terminal output (NOT readable text).

- Side-wall gate: `side_weight = 1.0 - pow(abs(normal.y), 2.0)` (maxes on vertical faces, zero on horizontal). Skips top/bottom.
- Rows along local-Y: `row = floor(local_y * code_row_density)`.
- Per row, two independent hashes drive an on/off sequence of variable-length blocks.
- **Occasional drift (sync-free):** per-row phase comes from `hash3(row)`, and motion is gated by `step(code_drift_threshold, hash4(row + floor(TIME * 0.3)))` — re-rolled every ~3s. Rows drift independently, never in a correlated wave.

Uniforms:
- `code_row_density` (float, default `18.0`).
- `code_opacity` (float, default `0.35`).
- `code_scroll_speed` (float, default `0.15`).
- `code_drift_threshold` (float, 0..1, default `0.92`) — higher = rarer drift.

### 4.6 Rim fresnel

```glsl
float rim = pow(1.0 - max(dot(NORMAL, VIEW), 0.0), rim_power);
EMISSION += palette_blue * rim * rim_intensity;
```

Uniforms:
- `rim_power` (float, default `3.0`).
- `rim_intensity` (float, default `0.6`) — sub-bloom, soft silhouette glow.

### 4.7 Full building uniform list

```
palette_black, palette_purple, palette_blue : source_color
triplanar_scale, triplanar_sharpness

glass_clarity, glass_tint_strength, refraction_strength, max_blur_lod

base_glow_height, base_glow_intensity, base_glow_falloff

code_row_density, code_opacity, code_scroll_speed, code_drift_threshold

rim_power, rim_intensity

scratch_strength, smudge_strength, pit_strength
```

---

## 5. Tweak cheat sheet

| Want to… | Change |
|---|---|
| Retint all platform circuits/pulses | `palette_purple` on `platforms.tres` |
| Retint all building glows/rim | `palette_blue` on `buildings.tres` |
| More glass-like platforms | `acrylic_roughness` ↓, `acrylic_reflect_strength` ↑ |
| More or fewer traces | `trace_probability` |
| Faster/more variable pulses | `pulse_speed_base`, `pulse_speed_variance` |
| Clearer buildings | `glass_clarity` ↑ |
| Frostier buildings | `glass_clarity` ↓, `max_blur_lod` ↑ |
| Glow creeps higher up walls | `base_glow_height` ↑ (0..1 fraction) |
| More/less code overlay | `code_row_density`, `code_opacity` |
| Code drifts more often | `code_drift_threshold` ↓ |
| Tighter rim | `rim_power` ↑ |
| Less surface noise | `scratch_/smudge_/pit_strength` all ↓ |
| Emission blowing out | Lower `pulse_brightness` / `base_glow_intensity` / `rim_intensity`, or raise scene `glow_hdr_threshold` |
| Real-time reflections off | Toggle `ssr_enabled` on `WorldEnvironment` |

---

## 6. Deferred / out of scope

- **Edge-aware blur refinement** using `hint_depth_texture` — straightforward LOD blur ships first; depth-aware multi-tap refinement if edges bleed unacceptably across foreground characters.
- **Compiled-out quality variants** (preprocessor `#define`s). Deferred; uniforms-to-zero with `if`-guards is v1 approach.
- **Per-instance `base_glow_axis`** for CSGs where local-Y isn't "up". Users rotate the transform instead for now.
- **Triplanar trace continuity across CSG seams.** Accepted limitation — CSG has no UVs.
- **Fallback opaque-glass variant** (former v2 Option A) — dropped entirely. Forward+ makes real transparency correct.
- **Retinting `volumetric_fog_emission`** to palette-neutral — scene-pass after shaders ship.

---

## 7. Target file layout (on implementation)

```
docs/
  materials.md                       <-- this file
level/
  shaders/
    shared_bump.gdshaderinc          <-- scratches + smudges + pitting
    platform.gdshader
    building.gdshader
  platforms.tres                     <-- ShaderMaterial (uid://da188d7yrcfr8 preserved)
  buildings.tres                     <-- ShaderMaterial (uid://ucfwprjqe6oq preserved)
  level.tscn                         <-- no edits to CSG nodes; materials swap in place.
                                         Separate scene pass: toggle SSR/SSIL on WorldEnvironment
                                         and re-tint volumetric_fog_emission (§2.7).
```

---

## 8. Open risks before prototype

1. **Truchet with smooth `distance_along_trace` across tile boundaries.** The hardest bit. If it looks jumpy, fall back to "pulses are per-tile dots that light up sequentially" — still reads.
2. **`world_vertex_coords` at the level's far-x extents** (CSGs at x ≈ −163). Verify no pattern jitter. ([upstream issue](https://github.com/godotengine/godot-docs/issues/7860))
3. **Transparent building sort-order** if two overlap in view — may need `render_priority` tuning per-instance.
4. **Bloom + volumetric scatter co-tuning.** Emission defaults are a starting estimate; expect one pass of tuning against the fog contribution.
5. **SSR reflection banding** at low roughness — SSR can show stepping artifacts on mirror-smooth surfaces. If so, raise `acrylic_roughness` default from `0.18` to `0.22` or enable TAA (we plan to anyway).

---

## Sources

Godot docs:
- [Spatial shaders reference](https://docs.godotengine.org/en/stable/tutorials/shaders/shader_reference/spatial_shader.html)
- [Shading language reference](https://docs.godotengine.org/en/stable/tutorials/shaders/shader_reference/shading_language.html)
- [Screen-reading shaders](https://docs.godotengine.org/en/stable/tutorials/shaders/screen-reading_shaders.html)
- [Upgrading from Godot 3 to 4](https://docs.godotengine.org/en/stable/tutorials/migrating/upgrading_to_godot_4.html)
- [Reflection probes](https://docs.godotengine.org/en/stable/tutorials/3d/global_illumination/reflection_probes.html)
- [StandardMaterial3D / ORMMaterial3D](https://docs.godotengine.org/en/stable/tutorials/3d/standard_material_3d.html)

Godot community / engine:
- [Triplanar mapping shader](https://godotshaders.com/shader/triplanar-mapping/)
- [Frosted glass shader](https://godotshaders.com/shader/frosted-glass-3/)
- [Apple-blur recreation (LOD-blur reference)](https://godotshaders.com/shader/apple-blur-shader-recreation/)
- [Forum: accessing reflection probes in a custom shader](https://forum.godotengine.org/t/access-reflection-probe-in-shader/103375)
- [PR #50440: default triplanar sharpness → 4.0](https://github.com/godotengine/godot/pull/50440)
- [PR #70967: SCREEN_TEXTURE et al. removed → hint_ texture uniforms](https://github.com/godotengine/godot/pull/70967)

Procedural pattern references:
- [IQ: FBM](https://iquilezles.org/articles/fbm/)
- [IQ: value noise + derivatives](https://iquilezles.org/articles/morenoise/)
- [IQ: smooth voronoi](https://iquilezles.org/articles/smoothvoronoi/)
- [IQ: voronoi edges](https://iquilezles.org/articles/voronoilines/)
- [IQ: domain warping](https://iquilezles.org/articles/warp/)
- [Truchet tiles (Wikipedia)](https://en.wikipedia.org/wiki/Truchet_tile)
- [Truchet tiling patterns — Reinder Nijhoff](https://reindernijhoff.net/2019/10/truchet-tiles-simple-rules-infinite-patterns/)
- [Shadertoy: Circuit Board](https://www.shadertoy.com/view/XsSXzR)
- [Shadertoy: SH16C Tron](https://www.shadertoy.com/view/4l33W4)
- [Shadertoy: truchet 2](https://www.shadertoy.com/view/4dS3Dc)
- [Shadertoy: Extruded Truchet](https://www.shadertoy.com/view/ttVBzd)

In-project references:
- `level/interactable/flag/water.gdshader` — canonical house-style spatial shader; covers `hint_screen_texture`, normal-map composition, RADIANCE/IRRADIANCE writes, blend_mix + depth_prepass_alpha pattern.
- `level/cactus/Plants.gdshader` — minimal house-style (vertex wind, alpha scissor).
- `level/interactable/flag/goal_flag.gdshader` — minimal (wave + albedo).
- `project.godot` + runtime log — confirms **Godot 4.6.2 / Forward+ / Metal / Apple M1 Max**.
