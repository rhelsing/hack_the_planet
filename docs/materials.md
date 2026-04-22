# Materials Spec — Platform & Building (v2, web-grounded)

Implementation spec for the two `ShaderMaterial`s used by every CSG piece of level geometry. Every technical claim below is tied to either a Godot 4 doc page, an in-project reference file, or a community shader we'll model on — see **§ Sources** at the end.

---

## 0. Project facts that constrain everything

Before touching a line of shader code, these are the concrete constraints from this project specifically:

| Fact | Value | Source |
|---|---|---|
| Engine version | **Godot 4.6** | `project.godot` → `config/features = PackedStringArray("4.6", "Mobile")` |
| Renderer | **Mobile** | same line |
| In-project shader template to match style | `level/interactable/flag/water.gdshader` | reads cleanly, uses `hint_screen_texture`, `source_color`, `RADIANCE`/`IRRADIANCE`, terse comments, explicit `render_mode` |
| Existing usage of `platforms.tres` | referenced by ~20 CSG nodes in `level/level.tscn` via `uid://da188d7yrcfr8` | must preserve this UID on conversion |
| Existing usage of `buildings.tres` | unused in scene, uid `uid://ucfwprjqe6oq` | preserve uid anyway |

**Mobile renderer implications we must design around:**

1. **Reflection probes do work**, but a custom shader cannot sample them directly. The engine only adds probe contribution when you write to the standard PBR outputs (`ALBEDO`, `METALLIC`, `ROUGHNESS`, `NORMAL`). A custom emission-only shader gets no probe reflections. — [Godot forum](https://forum.godotengine.org/t/access-reflection-probe-in-shader/103375)
2. **SSR (screen-space reflections) does not work on transparent materials** and is minimal on Mobile anyway. — [Godot proposals discussion #7274](https://github.com/godotengine/godot-proposals/discussions/7274)
3. **`hint_screen_texture` works on Mobile** and is the replacement for the Godot-3-era `SCREEN_TEXTURE` builtin. Syntax: `uniform sampler2D screen_texture : hint_screen_texture, filter_linear_mipmap;` — [Godot docs: screen-reading shaders](https://docs.godotengine.org/en/stable/tutorials/shaders/screen-reading_shaders.html)
4. **`hint_normal_roughness_texture` and `hint_depth_texture` are Forward+ only** — we will not use them.

**House conventions (from `water.gdshader`):**

- `shader_type spatial;` + explicit `render_mode` line.
- Uniforms at top; `uniform vec3 foo_color : source_color = vec3(r,g,b);` for colors; `hint_range(…)` for sliders; `hint_normal` for normal maps.
- Minimal in-code comments — 2–3 short ones per file, only where "what" is non-obvious.
- Mix-space normals composed via `TANGENT * nx + BINORMAL * ny + NORMAL * nz`.
- Writes `RADIANCE`/`IRRADIANCE` for custom env contribution.

---

## 1. Godot-3-→-4 migration landmines

I need to get these right the first time. Renamed built-ins ([docs: upgrading to Godot 4](https://docs.godotengine.org/en/stable/tutorials/migrating/upgrading_to_godot_4.html)):

| Godot 3 | Godot 4 |
|---|---|
| `WORLD_MATRIX` | `MODEL_MATRIX` |
| `WORLD_NORMAL_MATRIX` | `MODEL_NORMAL_MATRIX` |
| `CAMERA_MATRIX` | `INV_VIEW_MATRIX` |
| `INV_CAMERA_MATRIX` | `VIEW_MATRIX` |
| `SCREEN_TEXTURE` (built-in) | `uniform sampler2D screen_texture : hint_screen_texture, …` |
| `DEPTH_TEXTURE` (built-in) | `uniform sampler2D depth_texture : hint_depth_texture, …` (Forward+ only) |

Add `render_mode world_vertex_coords;` if we want `VERTEX` to be in world-space inside `vertex()` (saves a `MODEL_MATRIX * VERTEX` multiply). Known quirk: breaks down at large world offsets from origin, but our level sits near origin so we're fine.

---

## 2. Shared foundation

### 2.1 Color cascade — 3 uniforms only

| Role | Default | Used in |
|---|---|---|
| `palette_black` | `#000000` | substrate of both materials |
| `palette_purple` | `vec3(0.48, 0.17, 0.91)` | platform circuit traces, trace pulses |
| `palette_blue` | `vec3(0.12, 0.48, 1.00)` | building base glow, rim, code stripes |

Every derived color inside either shader is `mix(palette_black, palette_purple, t)` / `mix(palette_black, palette_blue, t)` or a brightness-scaled version. No other color uniforms.

**Known leak:** skybox reflections pull in sky colors (our sky shader tints purple-blue-yellow from the moon). Those are not constrained to the palette. Accepted — they read as "ambient lighting," not "the material picked a new color."

### 2.2 Triplanar — use the community-standard formula

Both shaders need triplanar projection because CSG has no useful UVs.

Formula to use ([godotshaders.com: triplanar-mapping](https://godotshaders.com/shader/triplanar-mapping/)):

```glsl
// in render_mode: world_vertex_coords
// VERTEX is now world-space in vertex()
// pass world_vertex to fragment via varying

vec3 triplanar_sample(vec3 wx, vec3 wy, vec3 wz, vec3 n) {
    n = n * n;                         // quadratic weights
    return (wx * n.x + wy * n.y + wz * n.z) / (n.x + n.y + n.z);
}
// use: sample pattern at world.yz, world.xz, world.xy — blend by abs(NORMAL)
```

Sharpness ergonomics: for a punchier blend (less smearing on angled faces), pre-raise weights: `n = pow(abs(n), vec3(triplanar_sharpness));` with `triplanar_sharpness` defaulting to `4.0` — the current Godot default ([PR #50440](https://github.com/godotengine/godot/pull/50440)). Our existing `platforms.tres` uses `10.0` (very sharp). Start at `4.0`, expose the knob.

Shared uniforms:
- `triplanar_scale` (float, default `0.5`) — world-units-per-tile.
- `triplanar_sharpness` (float, default `4.0`).

**Triplanar seams on CSG corners are real:** each axis sees an independent pattern, so a circuit trace running across a top face does not continue across the edge onto the side face. This is a known limitation of triplanar; fixing it would require per-mesh UVs which CSG does not produce. We accept the visible "pattern change at face boundaries" as the cost of using CSG.

### 2.3 Reflections — write PBR, let the engine handle it

**Strategy:** write `ALBEDO`, `ROUGHNESS`, `METALLIC`, `NORMAL` from the fragment shader. The engine then combines sky radiance + any `ReflectionProbe` contribution automatically. No manual `textureLod(RADIANCE, …)` — custom probe sampling is not supported in Godot 4 ([forum](https://forum.godotengine.org/t/access-reflection-probe-in-shader/103375)).

**Now:** skybox-only reflections; no probe in the scene.
**Later (path to add local reflections):** drop a `ReflectionProbe` node covering the play area in `level.tscn`, set `update_mode = ONCE`, bake. No shader edits needed. ([Godot docs: reflection probes](https://docs.godotengine.org/en/stable/tutorials/3d/global_illumination/reflection_probes.html))

Top-of-shader comment to leave in both files:

```glsl
// Reflections: sky-only today. To enable local reflections, drop a
// ReflectionProbe into level.tscn covering the play area — the engine
// routes probe contribution automatically via the PBR outputs we write.
```

### 2.4 Bump layer — three-pass procedural, tangent-space

Shared across both materials. Implemented as `.gdshaderinc` at `level/shaders/shared_bump.gdshaderinc`, included via `#include "res://level/shaders/shared_bump.gdshaderinc"`.

Three stacked height contributions, each from IQ primitives:

1. **Micro-scratches:** anisotropic value noise, frequency much higher along one axis than the other. Per-axis frequency pair: `vec2(60.0, 6.0)`. Uniform `scratch_strength`, default `0.35`. ([IQ value-noise derivatives](https://iquilezles.org/articles/morenoise/))
2. **Smudges:** low-frequency FBM, 3 octaves. Uniform `smudge_strength`, default `0.25`. ([IQ FBM](https://iquilezles.org/articles/fbm/))
3. **Pitting:** inverted smooth voronoi — `1 - smoothvoronoi(...)`. Uniform `pit_strength`, default `0.15`. ([IQ smooth voronoi](https://iquilezles.org/articles/smoothvoronoi/))

Normal perturbation: produce scalar height `h`; write `NORMAL_MAP` with the perturbed tangent-space normal and rely on Godot composing it via `TANGENT`/`BINORMAL`/`NORMAL` (same pattern as `water.gdshader` lines 27-29). **Do not** use a `dFdx(WORLD_VERTEX)` frame — it aliases on small triangles and flips at edges. Godot provides `TANGENT`/`BINORMAL` automatically on CSG.

### 2.5 Performance: honest variant strategy

The v1 spec proposed a runtime `uniform int quality_level` — that doesn't actually skip shader work (Godot uniform-int branches evaluate both sides per-pixel). Two honest paths:

- **Option A (recommended):** keep a single shader, expose `scratch_strength`/`smudge_strength`/`pit_strength`/`pulse_density`/etc. as floats. User turns effects down-to-zero for perf. Zero multiplier still costs an ALU, but voronoi/FBM early-out via `if (pit_strength > 0.0)` gives a real skip on Mobile.
- **Option B (defer):** if we really need compiled-out variants, duplicate into `platform_high.gdshader`/`platform_low.gdshader` using `#include` of a shared body + different `#define` gates. Leaving this as a deferred item.

### 2.6 Bloom interaction — do not blow out

`level/level.tscn`'s `Environment_5pwhg` has `glow_hdr_threshold = 0.26`, `glow_intensity = 4.98`. Any emission value above `0.26` blooms aggressively; values above ~`2.0` will smear into white blobs, not crisp lines.

**Budget for HDR emission values in both shaders:**
- Faint always-on traces / base ambient glow: `0.15 – 0.25` (sub-threshold — no bloom, subtle glow).
- Active trace pulses / glow peaks: `0.6 – 1.2` (slight bloom).
- Hard accents (never go higher without retuning the environment): `1.5 – 2.0`.

v1 had `pulse_brightness = 3.0`, `base_glow_intensity = 4.0` — those would blow out. Corrected defaults below.

---

## 3. Platform material

### 3.1 Visual goal

Scratched acrylic/glass sheet, slightly reflective, with a **sparse Tron-style** purple circuit board visible underneath. Traces are angular, orthogonal, connect across cells (not per-cell stubs), with brighter purple pulses sliding along them at variable speeds. Reference: `Screenshots/Screenshot 2026-04-18 at 11.12.53 AM.png`.

### 3.2 Layer stack, back to front

1. **Substrate:** `palette_black`, flat.
2. **Connected Tron trace network** (see §3.3).
3. **Animated pulses** along traces (see §3.4).
4. **Acrylic coat:** scratches + smudges + pitting bump, low roughness, skybox reflection via PBR outputs.

### 3.3 Connected trace generation — Truchet tiles, not per-cell hashes

The v1 spec's "each cell independently picks 0–2 segments via hash" does NOT produce connected routing — traces end at cell boundaries and restart unrelatedly on the other side. Correct approach: **Truchet tiling with a small handful of tile variants designed so adjacent edges always match.** ([Truchet intro on Wikipedia](https://en.wikipedia.org/wiki/Truchet_tile); good shader-oriented writeup: [Reinder Nijhoff](https://reindernijhoff.net/2019/10/truchet-tiles-simple-rules-infinite-patterns/))

Specifically:
- Define 4 tile types where each tile has a purple trace entering/exiting through a subset of its 4 edges, picked from a pre-designed set that guarantees edge compatibility in all rotations.
- `hash(cell)` chooses tile-type + rotation.
- To get sparseness, one of the tile types is "empty" and is weighted more heavily (`trace_probability`, default `0.35`).

This is the thing the v1 spec got wrong. Anchor references for implementation: Shadertoy "Circuit Board" ([XsSXzR](https://www.shadertoy.com/view/XsSXzR)) and "truchet 2" ([4dS3Dc](https://www.shadertoy.com/view/4dS3Dc)).

Optional quality bump: apply light domain warp before tile lookup ([IQ domain warp](https://iquilezles.org/articles/warp/)) so the grid isn't ruler-straight — subtle organic offset.

Uniforms:
- `circuit_density` (float, default `4.0`) — cells per world unit.
- `trace_probability` (float, 0..1, default `0.35`).
- `trace_width` (float, default `0.08`) — fraction of cell size.
- `trace_glow` (float, default `0.20`) — emission multiplier, sub-threshold so lines are visible but don't bloom.

### 3.4 Pulse animation

Each trace segment carries an `along-trace` parameter (stored as a second channel in the Truchet tile eval — output both `mask` and `distance_along`). A pulse is:

```glsl
float phase = hash(tile_id) * TAU + TIME * pulse_speed_base * (0.5 + hash2(tile_id) * pulse_speed_variance);
float pulse = smoothstep(pulse_width, 0.0, fract(distance_along - phase));
```

Color: `mix(palette_black, palette_purple, 1.0) * pulse_brightness * pulse`.

Uniforms:
- `pulse_speed_base` (float, default `0.6`).
- `pulse_speed_variance` (float, default `1.5`).
- `pulse_width` (float, default `0.12`).
- `pulse_brightness` (float, default `1.0`) — HDR, stays in the "slight bloom" band per §2.6.
- `pulse_density` (float, 0..1, default `0.6`) — fraction of trace tiles that carry an animated pulse.

### 3.5 Acrylic coat — opaque glass, not transparent

Do **not** enable `blend_mix`. We want the acrylic to look like glass via low roughness + fresnel-weighted spec, *without* real transparency. Transparency on Mobile + having emissive content underneath was the shakiest part of the v1 spec; eliminating it removes a class of problems (sort order, no SSAO, no shadow-receive). The "circuit visible underneath the acrylic" effect is achieved entirely by modulating the emissive layer, not by actual depth layering.

Uniforms:
- `acrylic_roughness` (float, default `0.18`).
- `acrylic_fresnel_power` (float, default `3.0`) — higher = tighter rim reflection.
- `acrylic_reflect_strength` (float, default `0.6`).

### 3.6 Full platform uniform list

```
// Palette (shared across both materials conceptually; declared per material)
palette_black, palette_purple, palette_blue : source_color

// Triplanar
triplanar_scale, triplanar_sharpness

// Circuit
circuit_density, trace_probability, trace_width, trace_glow

// Pulses
pulse_speed_base, pulse_speed_variance, pulse_width, pulse_brightness, pulse_density

// Acrylic
acrylic_roughness, acrylic_fresnel_power, acrylic_reflect_strength

// Bump
scratch_strength, smudge_strength, pit_strength
```

---

## 4. Building material

### 4.1 Visual goal

Semi-opaque glass slab with a `glass_clarity` knob. At the base, a blue emissive band reads as light pouring up from under the building. The glow bleeds 20–40% up the walls and falls off. On the side walls, an abstract procedural "code overlay" (stripes of varying lengths) in blue, mostly static, with occasional drift on individual rows. Silhouette edges carry a classic fresnel rim in blue. Micro-scratches + smudges + pitting bump. Overall slight blue tint. Reference: `Screenshots/Screenshot 2026-04-18 at 11.13.15 AM.png`.

### 4.2 Transparency decision

Two options considered; picking A.

**(A) Opaque "glass-look":** `render_mode cull_back, specular_schlick_ggx;` (no blend). Low roughness + fresnel + slight blue tint + high reflection strength does the job. No sort-order, no SSAO loss, no Mobile caveats. The "code overlay" and "base glow" ride on top as emissive modulations, not as content behind real glass.

**(B) Real transparency + screen-space blur:** `render_mode blend_mix, depth_prepass_alpha;` + `uniform sampler2D screen_texture : hint_screen_texture, filter_linear_mipmap;` + bicubic blur à la [godotshaders.com frosted-glass-3](https://godotshaders.com/shader/frosted-glass-3/). Works on Mobile but: no SSAO on the surface, no SSR, overlapping buildings can sort-flicker, shadows don't land on the material. Much costlier per fragment.

**Recommendation:** A. Ship A first, keep B as a documented follow-up. `glass_clarity` becomes a *visual* lerp between "thick opaque glass" (more reflective, less emission show-through) and "thin glass" (less reflective, more emission show-through) — same *look* as a real clarity slider for our purposes, without the transparency tax. If at review you decide A doesn't read right, we switch to B and accept the costs.

### 4.3 Glass body

- `glass_clarity` (float, 0..1, default `0.35`). Drives: `roughness = mix(0.45, 0.08, clarity)` (frosted→clear), `reflect_strength = mix(0.3, 0.85, clarity)`, `emission_visibility = mix(0.4, 1.0, clarity)` (emission reads brighter on "clear" glass).
- `glass_tint_strength` (float, default `0.08`) — how much `palette_blue` tints ALBEDO vs. `palette_black`.

### 4.4 Base emissive glow band

v1 had two bugs here:
1. Default `base_glow_height = 0.3` was interpreted as world units — invisible on a 29-unit-tall building.
2. Keyed to world-Y, which is wrong for rotated CSGs.

Corrections:

- Use **local space Y** (object-space) not world Y. In `vertex()`, pass a `VERTEX.y`-based varying to `fragment()`. CSG rotation no longer matters — "up" is the CSG's local up.
- `base_glow_height` is a **fraction of the CSG box's height along local Y**, default `0.3`. For a box of `size.y = 29`, that means the glow fades out by local-y = 8.7 (consistent with the intent).
- For odd-shaped CSG combiners, the local space may not align with "which face is the bottom." In that case the user either adjusts the CSG's own transform or we expose a per-instance uniform `base_glow_axis` (vec3, default `(0,1,0)`). Ship without per-instance `base_glow_axis`; add it later if needed.

Uniforms:
- `base_glow_height` (float, 0..1 fraction, default `0.3`).
- `base_glow_intensity` (float, default `1.2`) — HDR, slight bloom per §2.6.
- `base_glow_falloff` (float, default `2.0`).

### 4.5 Code overlay on side walls

Abstract procedural stripes suggesting rows of terminal output (NOT readable text). House approach:

- In triplanar: compute weight `side_weight = 1.0 - pow(abs(normal.y), 2.0)` — maxes on vertical faces, zero on horizontal.
- Tile rows along local-Y: `row = floor(local_y * code_row_density)`.
- Per row: two independent hashes `h1 = hash(row)`, `h2 = hash(row + 0.5)`. A row is a sequence of on/off blocks whose lengths come from `h1` and starts from `h2`.
- **Occasional drift (fixed from v1):** each row has an independent **per-row random phase** `hash3(row)` — no shared sin wave. Motion gating: `drift_gate = step(code_drift_threshold, hash4(row + floor(TIME * 0.3)))` — re-rolls every ~3 seconds; when a row wins the dice, it drifts for one cycle. Result: uncorrelated, truly occasional row motion.

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
- `rim_intensity` (float, default `0.6`) — sub-bloom-threshold so the rim is a soft glow, not a blown-out band.

### 4.7 Full building uniform list

```
palette_black, palette_purple, palette_blue : source_color   // purple carried for palette-cascade consistency; unused here

triplanar_scale, triplanar_sharpness

glass_clarity, glass_tint_strength

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
| Faster pulses, or more variable | `pulse_speed_base` / `pulse_speed_variance` |
| Clearer buildings | `glass_clarity` ↑ |
| Glow creeps higher up walls | `base_glow_height` ↑ (0..1 fraction of building height) |
| More/less code on walls | `code_row_density`, `code_opacity` |
| Code drifts more often | `code_drift_threshold` ↓ |
| Tighter rim | `rim_power` ↑ |
| Less surface noise | `scratch_/smudge_/pit_strength` all ↓ |
| Perf: kill the expensive passes | Set `pit_strength = 0`, `pulse_density = 0`, `smudge_strength = 0`. |
| Emission starts blowing out | Lower `pulse_brightness` / `base_glow_intensity` / `rim_intensity` OR raise `level.tscn` `glow_hdr_threshold` |

---

## 6. Deferred / out of scope

- **Real frosted-glass blur** via `SCREEN_TEXTURE` bicubic (Option B in §4.2). Deferred; reinstate if §4.2 Option A doesn't read right. Reference implementation: [godotshaders.com frosted-glass-3](https://godotshaders.com/shader/frosted-glass-3/).
- **Compiled-out quality variants** (shader permutations via `#include` + `#define`). Deferred; uniforms-to-zero is the interim perf path (§2.5).
- **`ReflectionProbe` in scene.** Deferred; spec for adding one documented in §2.3 — no shader changes required.
- **Per-instance `base_glow_axis`** for CSGs where local-Y isn't "up" (§4.4). Deferred; users rotate the CSG transform instead for now.
- **Triplanar trace continuity across CSG face seams.** Not solvable without proper UVs; accepted limitation (§2.2).
- **Forward+ features** (hint_normal_roughness_texture, hint_depth_texture, SSR-on-transparents) — unavailable on Mobile; not planning around them.

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
  platforms.tres                     <-- ShaderMaterial, uid preserved (uid://da188d7yrcfr8)
  buildings.tres                     <-- ShaderMaterial, uid preserved (uid://ucfwprjqe6oq)
  level.tscn                         <-- no edits; material swaps in place
```

---

## 8. What's still un-verified and could still bite

Pre-prototype risks remaining, even after this grounding:

1. **Truchet-with-animated-along-trace distance** — connecting `distance_along_trace` coherently across 4 tile variants so pulses flow smoothly across cell boundaries is the hardest bit. If it looks jumpy, fall back to "pulses are per-tile dots that light up sequentially" — still reads well.
2. **`render_mode world_vertex_coords` at large world offsets** — the level origin is near (0, 0, 0) but some CSGs are at x = -160. Worth verifying early that the triplanar pattern doesn't numerically jitter at that distance. ([upstream issue](https://github.com/godotengine/godot-docs/issues/7860))
3. **Emission on Mobile + our bloom tune** — actual bloom look depends on tonemap settings. The §2.6 budget is an estimate; expect one round of retuning.
4. **"Glass-look without real transparency"** (§4.2) — this is a taste call. If at the first prototype review it reads as "plastic slab, not glass," Option B is the escape hatch.

---

## Sources

Godot docs:
- [Spatial shaders reference](https://docs.godotengine.org/en/stable/tutorials/shaders/shader_reference/spatial_shader.html)
- [Shading language reference](https://docs.godotengine.org/en/stable/tutorials/shaders/shader_reference/shading_language.html)
- [Screen-reading shaders](https://docs.godotengine.org/en/stable/tutorials/shaders/screen-reading_shaders.html)
- [Upgrading from Godot 3 to 4](https://docs.godotengine.org/en/stable/tutorials/migrating/upgrading_to_godot_4.html)
- [Reflection probes](https://docs.godotengine.org/en/stable/tutorials/3d/global_illumination/reflection_probes.html)
- [StandardMaterial3D class ref](https://docs.godotengine.org/en/stable/classes/class_standardmaterial3d.html)

Godot community / engine:
- [Triplanar mapping shader (godotshaders.com)](https://godotshaders.com/shader/triplanar-mapping/)
- [Frosted glass shader (godotshaders.com)](https://godotshaders.com/shader/frosted-glass-3/)
- [Forum: accessing reflection probes in a custom shader](https://forum.godotengine.org/t/access-reflection-probe-in-shader/103375)
- [PR #50440: default triplanar sharpness raised to 4.0](https://github.com/godotengine/godot/pull/50440)
- [PR #70967: SCREEN_TEXTURE et al. removed in favor of hint_ texture uniforms](https://github.com/godotengine/godot/pull/70967)
- [Godot-proposals #7274: SSR on transparents](https://github.com/godotengine/godot-proposals/discussions/7274)

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
- `level/interactable/flag/water.gdshader` — canonical house-style spatial shader, covers screen-texture usage, normal map composition, RADIANCE/IRRADIANCE writes.
- `level/cactus/Plants.gdshader` — minimal house-style shader (vertex wind + alpha scissor).
- `level/interactable/flag/goal_flag.gdshader` — minimal shader (wave + albedo).
- `project.godot` → `config/features` confirms **Godot 4.6 / Mobile renderer**.
