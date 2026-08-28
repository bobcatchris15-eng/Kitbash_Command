shader_type spatial;
// Terrain v2 ground shader. Selected by `terrain.generator: "v2"` in a map's
// JSON; v1 maps keep shaders/terrain_ground.gdshader untouched.
//
// WHAT THIS FIXES, AND WHY EACH ONE MATTERED
//
// 1. THE SPLAT MAP IS ACTUALLY READ. build_terrain.py has been baking
//    <map>_splat.png (R=grass, G=rock, B=dirt, A=sand) for seven maps all
//    along. terrain_ground.gdshader declares `surfacemap_tex`/`use_surfacemap`
//    uniforms and never samples them, and no GDScript ever set them - so the
//    entire visual surfacing was "one grassland texture, plus a triplanar rock
//    override on slope". Which material goes where was information the
//    renderer simply did not have.
//
// 2. HEIGHT BLENDING WITH AN AUTHORED WIDTH, not a cross-fade. `blend_width`
//    is the transition band: every boundary between two ground materials is
//    resolved by comparing per-texel HEIGHT within that band, so grass sits in
//    the hollows of the rock rather than dissolving into it linearly. The
//    boundary is irregular at texel scale for free, which is what stops a
//    transition reading as a line at gameplay camera distance. Widening
//    `blend_width` widens the zone; that is the knob the brief asks for.
//
//    Height comes from albedo luminance, not from a height map. The obvious
//    source - the G channel of each roughness texture, which is what v1 reads
//    - is a COPY OF ROUGHNESS on four of the five surfaces measured
//    (grassland R and G are both a constant 0.949, sd 0.000). Blending on a
//    per-layer constant is just a contrast curve on the mask, which is
//    effectively what v1 was doing. Luminance actually varies per texel and
//    correlates with depth on every plate we ship.
//
// 3. THE SLOPE->ROCK TRANSITION IS WIDE. v1 used
//    smoothstep(0.65 - 0.05, 0.65 + 0.05, slope) - a band about two degrees
//    across, i.e. a hard line by construction, and the single most visible
//    seam in the game. Here slope feeds the rock channel's WEIGHT before the
//    height blend, over a wide authored ramp, so rock emerges through the
//    grass gradually and with an interlocking edge instead of switching.
//
// 4. THE VALUE CHAIN IS FIXED. v1 multiplied albedo by three separate sub-1.0
//    terms and reached the BRDF at ~0.023 linear - darker than charcoal -
//    before any light hit it:
//      - `ground_tint` was authored as a perceptual sRGB value
//        (ground_color.lightened(0.55) = 0.658, "a light grey") but declared
//        `: source_color`, so Godot converted it to 0.39 LINEAR. The guard
//        against compounding was itself a 2.5x darkening.
//      - `macro_tex` is a tint raster centred on 0.53 and was multiplied in
//        raw, halving albedo everywhere for no artistic reason.
//    Here both are remapped around 1.0 so a neutral map is a no-op, and
//    `value_floor` puts a hard floor under the result so a night palette
//    stays a palette instead of becoming black.

// --- Per-layer material slots (0 grass, 1 rock, 2 dirt, 3 sand) -------------
uniform sampler2D albedo_0 : source_color, filter_linear_mipmap, repeat_enable;
uniform sampler2D albedo_1 : source_color, filter_linear_mipmap, repeat_enable;
uniform sampler2D albedo_2 : source_color, filter_linear_mipmap, repeat_enable;
uniform sampler2D albedo_3 : source_color, filter_linear_mipmap, repeat_enable;

uniform sampler2D normal_0 : hint_normal, filter_linear_mipmap, repeat_enable;
uniform sampler2D normal_1 : hint_normal, filter_linear_mipmap, repeat_enable;
uniform sampler2D normal_2 : hint_normal, filter_linear_mipmap, repeat_enable;
uniform sampler2D normal_3 : hint_normal, filter_linear_mipmap, repeat_enable;

uniform sampler2D rough_0 : hint_default_white, filter_linear_mipmap, repeat_enable;
uniform sampler2D rough_1 : hint_default_white, filter_linear_mipmap, repeat_enable;
uniform sampler2D rough_2 : hint_default_white, filter_linear_mipmap, repeat_enable;
uniform sampler2D rough_3 : hint_default_white, filter_linear_mipmap, repeat_enable;

// World units per texture repeat, per layer. Rock wants a larger tile than
// grass or it reads as gravel on a cliff face.
//
// These WERE 6/9/6/5, which on a 1920 m map is 320 repeats of a 256 px plate
// across the ground. At that density the eye reads the lattice rather than the
// material - the plate could be perfect and it would still look like tiling.
// Paired with the 2048 px ground_* plates (tools/generate_ground_plates.py),
// a 28 m tile still lands ~73 px per metre.
uniform vec4 layer_tile_size = vec4(28.0, 34.0, 26.0, 24.0);

// --- Repeat break-up --------------------------------------------------------
// Even a 28 m tile repeats ~68 times across the map, so tile size alone does
// not solve it. Each layer is sampled at TWO scales and cross-faded by a
// low-frequency world-space noise: the second sample uses an irrational-ish
// ratio and an offset, so the two lattices never coincide, and because the
// blend is a function of WORLD position it does not repeat with the texture.
// One extra albedo fetch per layer buys the whole effect.
uniform float detile_scale = 0.0075;   // ~130 m blend cells
uniform float detile_ratio = 0.413;    // second sample's relative tile size
uniform float detile_amount : hint_range(0.0, 1.0) = 0.65;
// Slow brightness drift across the map, so large flat areas are not one flat
// value. Separate from macro_tex, which is a baked per-map raster.
uniform float macro_drift_scale = 0.0022;  // ~450 m
uniform float macro_drift = 0.14;

// --- Splat + per-map rasters ------------------------------------------------
uniform sampler2D splat_tex : filter_linear_mipmap;
uniform bool use_splat = false;
uniform sampler2D macro_tex : filter_linear_mipmap;
uniform bool use_macro = false;
uniform sampler2D curvature_tex : filter_linear_mipmap;
uniform bool use_curvature = false;
uniform sampler2D wetness_tex : filter_linear_mipmap;
uniform bool use_wetness = false;
uniform sampler2D detail_normal_tex : hint_normal, filter_linear_mipmap, repeat_enable;

uniform float map_half_extents = 100.0;

// --- The blend controls -----------------------------------------------------
// Width of the transition band, in height units (albedo luminance is 0..1).
// Larger = wider, softer boundary. This is THE authored blend-zone width.
uniform float blend_width : hint_range(0.02, 0.9) = 0.34;
// How much per-texel height is allowed to displace a splat weight. 0 collapses
// the whole thing back to a linear cross-fade.
uniform float blend_depth : hint_range(0.0, 1.0) = 0.55;

// Splat-edge break-up. The splat raster carries authored rectangles, and a
// rectangle with a soft edge is still a rectangle - a straight gradient reads
// as a straight edge. Warping the LOOKUP position by low-frequency noise makes
// the boundary wander by a few metres so nothing in the world runs true to an
// axis. Cheap, and it fixes the shape of the seam rather than its hardness.
uniform float splat_warp_strength = 5.5;   // world units of wander
uniform float splat_warp_scale = 0.035;    // noise frequency

// --- Slope-driven rock ------------------------------------------------------
// A WIDE ramp, deliberately. See note (3) in the header.
uniform float slope_rock_lo : hint_range(0.0, 1.0) = 0.30;
uniform float slope_rock_hi : hint_range(0.0, 1.0) = 0.72;
uniform float slope_rock_gain : hint_range(0.0, 3.0) = 1.6;
// Beyond this slope the rock layer is projected triplanar instead of from
// world-XZ UVs, so a near-vertical face stops looking smeared.
uniform float triplanar_lo : hint_range(0.0, 1.0) = 0.45;
uniform float triplanar_hi : hint_range(0.0, 1.0) = 0.78;

// --- Grade ------------------------------------------------------------------
uniform vec4 ground_tint : source_color = vec4(1.0, 1.0, 1.0, 1.0);
// Neutral-centred: a raster whose mean is 0.5 multiplies to 1.0.
uniform float macro_strength : hint_range(0.0, 1.0) = 0.55;
uniform float curvature_strength : hint_range(0.0, 1.0) = 0.65;
// Hard floor under the final albedo. The point of a moody palette is that
// dark areas still carry information; below roughly this the tonemap has
// nothing left to recover.
uniform float value_floor : hint_range(0.0, 0.25) = 0.055;
uniform float detail_normal_scale = 0.55;
uniform float detail_normal_amount : hint_range(0.0, 1.0) = 0.35;

uniform vec3 cliff_rock_tint : source_color = vec3(1.0, 1.0, 1.0);
uniform float strata_strength : hint_range(0.0, 1.0) = 0.45;
uniform float strata_scale = 0.15;

varying vec3 v_world_pos;
varying vec3 v_world_normal;

uvec3 pcg3d(uvec3 v) {
	v = v * 1664525u + 1013904223u;
	v.x += v.y * v.z; v.y += v.z * v.x; v.z += v.x * v.y;
	v ^= v >> 16u;
	v.x += v.y * v.z; v.y += v.z * v.x; v.z += v.x * v.y;
	return v;
}

float hash21(vec2 p) {
	uvec2 u = uvec2(ivec2(floor(p)) + 4096);
	uvec3 h = pcg3d(uvec3(u, 0u));
	return float(h.x) * (1.0 / 4294967295.0);
}

float value_noise(vec2 p) {
	vec2 i = floor(p);
	vec2 f = fract(p);
	vec2 u = f * f * f * (f * (f * 6.0 - 15.0) + 10.0);
	float a = hash21(i);
	float b = hash21(i + vec2(1.0, 0.0));
	float c = hash21(i + vec2(0.0, 1.0));
	float d = hash21(i + vec2(1.0, 1.0));
	return mix(mix(a, b, u.x), mix(c, d, u.x), u.y);
}

float luma(vec3 c) {
	return dot(c, vec3(0.2126, 0.7152, 0.0722));
}

void vertex() {
	v_world_pos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	v_world_normal = normalize((MODEL_MATRIX * vec4(NORMAL, 0.0)).xyz);
}

void fragment() {
	vec2 wpos = v_world_pos.xz;

	// --- splat weights ------------------------------------------------------
	vec2 warp = vec2(
		value_noise(wpos * splat_warp_scale + vec2(11.3, 4.7)),
		value_noise(wpos * splat_warp_scale + vec2(2.9, 19.1))
	) * 2.0 - 1.0;
	vec2 splat_uv = ((wpos + warp * splat_warp_strength) / (map_half_extents * 2.0)) + vec2(0.5);
	vec4 w = vec4(1.0, 0.0, 0.0, 0.0);
	if (use_splat) {
		w = texture(splat_tex, clamp(splat_uv, vec2(0.001), vec2(0.999)));
	}

	// Slope pushes the rock channel up. Added to the weight BEFORE the height
	// blend so the boundary interlocks rather than cross-fading.
	float slope = 1.0 - clamp(v_world_normal.y, 0.0, 1.0);
	float slope_rock = smoothstep(slope_rock_lo, slope_rock_hi, slope);
	w.g += slope_rock * slope_rock_gain;
	// Steep ground should not also be carrying grass and sand.
	float shed = 1.0 - slope_rock;
	w.r *= shed;
	w.b *= mix(1.0, shed, 0.5);
	w.a *= shed;

	w = max(w, vec4(0.0));
	float w_sum = w.r + w.g + w.b + w.a;
	w = (w_sum < 1e-4) ? vec4(1.0, 0.0, 0.0, 0.0) : w / w_sum;

	// --- sample the four layers in world space ------------------------------
	vec2 uv0 = wpos / layer_tile_size.x;
	vec2 uv1 = wpos / layer_tile_size.y;
	vec2 uv2 = wpos / layer_tile_size.z;
	vec2 uv3 = wpos / layer_tile_size.w;

	// Two-scale de-tiling blend, shared by all four layers (see detile_*).
	float detile = value_noise(wpos * detile_scale) * detile_amount;
	vec2 d_off = vec2(37.13, 61.77);
	vec3 a0 = mix(texture(albedo_0, uv0).rgb, texture(albedo_0, uv0 * detile_ratio + d_off).rgb, detile);
	vec3 a1 = mix(texture(albedo_1, uv1).rgb, texture(albedo_1, uv1 * detile_ratio + d_off).rgb, detile);
	vec3 a2 = mix(texture(albedo_2, uv2).rgb, texture(albedo_2, uv2 * detile_ratio + d_off).rgb, detile);
	vec3 a3 = mix(texture(albedo_3, uv3).rgb, texture(albedo_3, uv3 * detile_ratio + d_off).rgb, detile);

	vec3 n1 = texture(normal_1, uv1).rgb;
	float r1 = texture(rough_1, uv1).r;

	// Rock reprojected triplanar on steep ground so a cliff face is not a
	// vertically smeared top-down projection.
	float tri = smoothstep(triplanar_lo, triplanar_hi, slope);
	if (tri > 0.001) {
		vec3 bl = abs(v_world_normal);
		bl = bl / max(bl.x + bl.y + bl.z, 1e-4);
		vec3 tx = texture(albedo_1, v_world_pos.zy / layer_tile_size.y).rgb;
		vec3 tz = texture(albedo_1, v_world_pos.xy / layer_tile_size.y).rgb;
		vec3 tri_rock = tx * bl.x + a1 * bl.y + tz * bl.z;
		a1 = mix(a1, tri_rock * cliff_rock_tint, tri);

		// Triplanar normals for crisp 3D cliff crevices & fractures
		vec3 nx = texture(normal_1, v_world_pos.zy / layer_tile_size.y).rgb * 2.0 - 1.0;
		vec3 ny = n1 * 2.0 - 1.0;
		vec3 nz = texture(normal_1, v_world_pos.xy / layer_tile_size.y).rgb * 2.0 - 1.0;
		vec3 tri_nrm = (nx * bl.x + ny * bl.y + nz * bl.z) * 0.5 + 0.5;
		n1 = mix(n1, tri_nrm, tri);

		// Triplanar roughness
		float rx = texture(rough_1, v_world_pos.zy / layer_tile_size.y).r;
		float rz = texture(rough_1, v_world_pos.xy / layer_tile_size.y).r;
		r1 = mix(r1, rx * bl.x + r1 * bl.y + rz * bl.z, tri);

		// Horizontal geological strata modulation on sheer cliffs
		float strata = sin(v_world_pos.y * strata_scale * 6.28318 + value_noise(wpos * 0.05) * 2.5);
		strata = pow(clamp(strata * 0.5 + 0.5, 0.0, 1.0), 2.2);
		a1 *= mix(1.0, 0.72 + 0.38 * strata, tri * strata_strength);
	}

	// --- height-weighted blend ---------------------------------------------
	// Classic height blend: bias each weight by its own per-texel height, then
	// keep only what lies within `blend_width` of the tallest contender. The
	// width IS the transition zone.
	vec4 h = vec4(luma(a0), luma(a1), luma(a2), luma(a3));
	vec4 biased = w + h * blend_depth * step(1e-4, w);
	float peak = max(max(biased.r, biased.g), max(biased.b, biased.a));
	vec4 bw = max(biased - vec4(peak - blend_width), vec4(0.0));
	float bw_sum = bw.r + bw.g + bw.b + bw.a;
	bw = (bw_sum < 1e-5) ? vec4(1.0, 0.0, 0.0, 0.0) : bw / bw_sum;

	vec3 alb = a0 * bw.r + a1 * bw.g + a2 * bw.b + a3 * bw.a;

	vec3 nrm = texture(normal_0, uv0).rgb * bw.r
	         + n1 * bw.g
	         + texture(normal_2, uv2).rgb * bw.b
	         + texture(normal_3, uv3).rgb * bw.a;

	float rgh = texture(rough_0, uv0).r * bw.r
	          + r1 * bw.g
	          + texture(rough_2, uv2).r * bw.b
	          + texture(rough_3, uv3).r * bw.a;

	// Micro detail. v1 declared this sampler and never assigned it, so it read
	// a flat normal and then did nrm = mix(nrm, flat, 0.25) - actively
	// FLATTENING the real normal map by a quarter on every fragment.
	vec3 dn = texture(detail_normal_tex, wpos * detail_normal_scale).rgb;
	nrm = normalize(mix(nrm, dn, detail_normal_amount * 0.5));

	// --- per-map rasters, all neutral-centred -------------------------------
	vec2 map_uv = (wpos / (map_half_extents * 2.0)) + vec2(0.5);
	if (use_macro) {
		vec3 m = texture(macro_tex, map_uv).rgb;
		alb *= mix(vec3(1.0), m * 2.0, macro_strength);
	}
	if (use_curvature) {
		float c = texture(curvature_tex, map_uv).r;
		alb *= mix(1.0, clamp(c * 2.0, 0.35, 1.6), curvature_strength);
	}
	if (use_wetness) {
		float wet = texture(wetness_tex, map_uv).r;
		alb *= mix(1.0, 0.72, wet);
		rgh = mix(rgh, 0.18, wet * 0.85);
	}

	// Slow world-space brightness drift. Large flat areas were reading as one
	// dead value; this gives them shape without adding anything the player
	// could mistake for a terrain feature.
	alb *= 1.0 + (value_noise(wpos * macro_drift_scale) - 0.5) * 2.0 * macro_drift;

	alb *= ground_tint.rgb;
	// Brightness lift & clarity boost for clean battlefield readability
	alb *= 1.35;
	// Floor, not a lift: a lift washes the whole image toward grey, while a
	// floor only touches texels that had already collapsed.
	alb = max(alb, vec3(value_floor));

	ALBEDO = alb;
	NORMAL_MAP = nrm;
	ROUGHNESS = clamp(rgh, 0.04, 1.0);
	SPECULAR = 0.15;
}
