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
// Lowered from 0.30 (46 deg) to meet rock_strata_lo. The strata are mixed into
// the ROCK channel, so they are then weighted by that channel in the final
// blend - if rock has no weight at 45 deg, banding there is invisible no
// matter what the strata ramp says. On bimodal terrain (flat or near-vertical)
// this barely changes coverage; on a gentler map it is the difference between
// a banded cliff and a grassy one.
uniform float slope_rock_lo : hint_range(0.0, 1.0) = 0.22;
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
uniform int rock_pattern : hint_range(0, 3) = 0; // 0 = Layered Strata, 1 = Fractured Granite, 2 = Rugged Crag, 3 = Chiseled Slabs
// Clamped to 1.0 at the mix, so the old 0..2 hint was a lie above 1 and the
// 1.1 default spent 0.1 on nothing.
uniform float rock_strata_strength : hint_range(0.0, 1.0) = 0.92;
// The strata get their OWN slope ramp. They used to ride on `tri`, the
// triplanar gate (0.45..0.78 = 65..80 deg), but those answer different
// questions: triplanar is about a texture STRETCHING on a steep face, strata
// are about rock being EXPOSED. Sharing the gate meant a 65 deg face - a
// cliff by any reading - got essentially no banding.
// slope here is 1 - normal.y, so 0.23 is ~40 deg and 0.50 is ~60 deg.
uniform float rock_strata_lo : hint_range(0.0, 1.0) = 0.23;
uniform float rock_strata_hi : hint_range(0.0, 1.0) = 0.50;
// Authored band colours run 0.36..0.98 sRGB, which is 0.04..0.95 LINEAR -
// far above real rock (limestone sits near 0.25 linear). Harmless while the
// bands only multiplied the plate; with a real mix they would blow out.
// 0.62 was still far too bright once the mix actually asserted the colour:
// the fragment path later applies a 1.35 lift and the cliff tint, so a 0.88
// sandstone landed near 0.72 sRGB - white rock. Working back from a target of
// ~0.45 sRGB on the lit face: 0.45 / (0.88 * 0.85 * 1.35) = 0.45.
uniform float rock_albedo_gain : hint_range(0.1, 1.5) = 0.45;
uniform float rock_bump_strength : hint_range(0.0, 3.0) = 1.6;
// BED THICKNESS, and the single most important knob for whether a cliff reads
// as stratified. The band index is floor(bed_y * this), so 0.16 means one bed
// per 6.25 units - only three or four bands on a 22 m wall, which renders as
// large flat slabs of one colour rather than as bedding. 0.5 gives ~2 m beds,
// which is the real range for sandstone/shale sequences.
uniform float rock_strata_scale : hint_range(0.01, 1.0) = 0.5;
uniform float rock_joint_scale : hint_range(0.01, 1.0) = 0.08;

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

float sample_rock_height(vec3 p) {
	float h = 0.0;
	if (rock_pattern == 0) {
		// Pattern 0: Organic Tilted Sedimentary Strata (Tilted dip, folding & non-uniform bed thickness)
		float dip = p.x * 0.18 - p.z * 0.12; // Natural tectonic tilt (~12° dip)
		float fold1 = value_noise(p.xz * 0.022) * 6.0; // Large geological fold undulations
		float fold2 = value_noise(p.xz * 0.075 + vec2(p.y * 0.05)) * 1.8;
		float bed_y = p.y + dip + fold1 + fold2;

		// Non-uniform bedding thickness (mix of thick sandstone beds and thin shale laminations)
		float non_uniform_y = bed_y + sin(bed_y * 0.16 + 1.4) * 3.4 + sin(bed_y * 0.042) * 7.0;
		float bed_scaled = non_uniform_y * rock_strata_scale;
		float step_tier = pow(fract(bed_scaled), 0.32) * 1.4;
		float fine_strata = sin(bed_scaled * 16.0 + value_noise(p.xz * 0.1) * 2.0) * 0.22;
		
		// Irregular diagonal joint fractures & cross-bedding
		float vertical_crack = smoothstep(0.86, 0.98, abs(sin((p.x * 0.75 + p.z * 0.65) * rock_joint_scale * 3.14 + value_noise(p.yz * 0.05) * 2.2))) * 0.55;
		h = (step_tier + fine_strata - vertical_crack) * 1.25;
	} else if (rock_pattern == 1) {
		// Pattern 1: Organic Fractured Granite / Bedrock (Domain-warped multi-axial stress joints)
		vec2 warp = vec2(
			value_noise(p.xz * 0.032 + vec2(p.y * 0.04)),
			value_noise(p.zx * 0.032 - vec2(p.y * 0.04 + 19.3))
		) * 4.5;
		vec3 pw = p + vec3(warp.x, warp.y * 0.5, warp.y);

		float a1 = sin((pw.x * 0.866 + pw.z * 0.500) * rock_joint_scale * 3.5 + pw.y * 0.08);
		float a2 = sin((-pw.x * 0.500 + pw.z * 0.866) * rock_joint_scale * 3.1 - pw.y * 0.06);
		float a3 = sin((pw.x * 0.250 - pw.z * 0.968) * rock_joint_scale * 2.7 + pw.y * 0.11);
		
		float block_terr = floor(a1 * 1.6) * 0.32 + floor(a2 * 1.6) * 0.28 + floor(a3 * 1.4) * 0.24;
		float crack = -pow(clamp(1.0 - min(abs(a1), min(abs(a2), abs(a3))), 0.0, 1.0), 4.8) * 1.35;
		float micro = (value_noise(p.xz * 0.12 + vec2(p.y * 0.08)) - 0.5) * 0.45;
		h = (block_terr + crack + micro) * 1.35;
	} else if (rock_pattern == 2) {
		// Pattern 2: Rugged Mountain Crag (Multi-octave sharp jagged rock noise)
		float n1 = value_noise(p.xz * rock_strata_scale * 3.0 + vec2(p.y * 0.15));
		float n2 = value_noise(p.xz * rock_strata_scale * 7.5 - vec2(p.y * 0.35));
		float n3 = value_noise(p.xz * rock_strata_scale * 16.0 + vec2(p.y * 0.8));
		float crag = (n1 * 0.52 + n2 * 0.32 + n3 * 0.16) * 2.0 - 1.0;
		float ledge = sin(p.y * rock_strata_scale * 4.0 + (p.x * 0.2 - p.z * 0.15)) * 0.35;
		h = (crag + ledge) * 1.4;
	} else {
		// Pattern 3: Organic Chiseled Slabs / Limestone Bedrock (Domain-warped non-uniform bedding)
		vec2 slab_warp = vec2(
			value_noise(p.xz * 0.028 + vec2(p.y * 0.035)),
			value_noise(p.zx * 0.028 - vec2(p.y * 0.035 + 14.7))
		) * 3.8;
		vec3 spw = p + vec3(slab_warp.x, slab_warp.y * 0.4, slab_warp.y);

		float dip = spw.x * 0.14 - spw.z * 0.09;
		float non_uniform_bed = (spw.y + dip) + sin((spw.y + dip) * 0.18 + 1.2) * 2.8 + sin((spw.y + dip) * 0.05) * 5.2;
		float row = floor(non_uniform_bed * rock_strata_scale * 1.8);
		
		float u_shift = float(int(abs(row)) % 3) * 3.8 + value_noise(spw.xz * 0.05) * 4.0;
		float col_coord = (spw.x * 0.85 + spw.z * 0.52 + u_shift) * rock_joint_scale * 1.8;
		float col_idx = floor(col_coord);
		
		float block_seed = fract(sin(row * 12.9898 + col_idx * 78.233) * 43758.5453);
		float slab_lift = (block_seed - 0.5) * 0.9;
		
		float border = smoothstep(0.03, 0.12, fract(non_uniform_bed * rock_strata_scale * 1.8))
		             * smoothstep(0.03, 0.12, fract(col_coord));
		float chip = (value_noise(spw.xz * 0.15 + vec2(spw.y * 0.1)) - 0.5) * 0.35;
		h = (slab_lift + (border - 0.5) * 0.6 + chip) * 1.35;
	}
	return h;
}

vec3 sample_rock_color(vec3 p, vec2 wpos, float crevice_occ) {
	vec3 col = vec3(1.0);
	if (rock_pattern == 0) {
		// Pattern 0: Sedimentary Strata
		// Mostly light tan-yellow, with gray and black for some bands, and rare red ones
		float dip = p.x * 0.18 - p.z * 0.12;
		float fold1 = value_noise(p.xz * 0.022) * 6.0;
		float fold2 = value_noise(p.xz * 0.075 + vec2(p.y * 0.05)) * 1.8;
		float bed_y = p.y + dip + fold1 + fold2;
		float non_uniform_y = bed_y + sin(bed_y * 0.16 + 1.4) * 3.4 + sin(bed_y * 0.042) * 7.0;
		float bed_scaled = non_uniform_y * rock_strata_scale;
		
		float band_idx = floor(bed_scaled);
		float band_hash = fract(sin(band_idx * 127.1 + 311.7) * 43758.5453);
		
		vec3 tan_yellow = mix(vec3(0.88, 0.79, 0.58), vec3(0.98, 0.89, 0.68), fract(bed_scaled));
		vec3 dark_shale = mix(vec3(0.36, 0.36, 0.38), vec3(0.18, 0.18, 0.20), fract(bed_scaled));
		vec3 red_iron = mix(vec3(0.74, 0.28, 0.20), vec3(0.84, 0.36, 0.24), fract(bed_scaled));
		
		if (band_hash < 0.09) {
			// Rare red hematite/iron band (~9%)
			col = red_iron;
		} else if (band_hash < 0.30) {
			// Gray and black shale bands (~21%)
			col = dark_shale;
		} else {
			// Mostly light tan-yellow sandstone (~70%)
			col = tan_yellow;
		}
		
		// Fine sedimentary laminations
		float fine = sin(bed_scaled * 16.0 + value_noise(wpos * 0.08) * 2.0) * 0.08;
		col += vec3(fine);
		col *= mix(0.75, 1.15, crevice_occ);

	} else if (rock_pattern == 1) {
		// Pattern 1: Fractured Granite
		// Mottled various grey with occasional small patches of light green lichen
		float g1 = value_noise(wpos * 0.08 + vec2(p.y * 0.05));
		float g2 = value_noise(wpos * 0.28 + vec2(p.y * 0.15));
		float g_mottle = g1 * 0.6 + g2 * 0.4;
		vec3 granite_grey = mix(vec3(0.42, 0.42, 0.45), vec3(0.85, 0.85, 0.83), g_mottle);
		
		// Occasional light green lichen colonies
		float lichen_mask = value_noise(wpos * 0.07 + vec2(p.y * 0.04 + 31.4));
		float lichen_grain = value_noise(wpos * 0.42 - vec2(p.y * 0.2));
		float is_lichen = smoothstep(0.68, 0.78, lichen_mask) * smoothstep(0.35, 0.65, lichen_grain);
		vec3 lichen_green = vec3(0.55, 0.72, 0.40);
		
		col = mix(granite_grey, lichen_green, is_lichen * 0.88);
		col *= mix(0.70, 1.15, crevice_occ);

	} else if (rock_pattern == 2) {
		// Pattern 2: Rugged Crag
		// Light brownish-red
		float c_mottle = value_noise(wpos * 0.06) * 0.65 + value_noise(wpos * 0.22) * 0.35;
		vec3 brown_red = mix(vec3(0.72, 0.42, 0.30), vec3(0.88, 0.54, 0.38), c_mottle);
		col = brown_red * mix(0.75, 1.15, crevice_occ);

	} else {
		// Pattern 3: Limestone Bedrock / Chiseled Slabs
		// Limestone cream / yellow
		float l_mottle = value_noise(wpos * 0.05) * 0.7 + value_noise(wpos * 0.18) * 0.3;
		vec3 cream_yellow = mix(vec3(0.88, 0.82, 0.66), vec3(0.98, 0.94, 0.78), l_mottle);
		col = cream_yellow * mix(0.75, 1.15, crevice_occ);
	}
	return col;
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

	}

	// --- procedural geological strata ---------------------------------------
	// Deliberately OUTSIDE the triplanar block above: see rock_strata_lo.
	float strata_mask = smoothstep(rock_strata_lo, rock_strata_hi, slope);
	if (strata_mask > 0.001) {
		float strata_h = sample_rock_height(v_world_pos);
		float crevice_occ = clamp(1.0 + strata_h * 0.35, 0.45, 1.25);
		vec3 rock_color = sample_rock_color(v_world_pos, wpos, crevice_occ);

		// MIX, NOT MULTIPLY. `a1 * rock_color` can only ever make a band
		// DARKER than the rock plate under it, so a red hematite band on grey
		// stone came out as muddy pink staining rather than as a band - the
		// authored palette could tint but never assert itself. The old * 1.35
		// was compensating for that double-darkening.
		// Capped below 1.0 on purpose: a full replace throws away the rock
		// plate's own grain and leaves flat vertex-lit colour with only the
		// procedural bump on it. Keeping ~15% of the plate holds the fine
		// texture that stops a cliff face looking like painted card.
		// The biome tint is applied at PARTIAL strength here. It was authored
		// when the rock channel was just a plate that needed recolouring per
		// biome; now the pattern supplies its own geology, and the temperate
		// tint (0.85, 0.88, 0.82) is slightly green - measured, it pulled a
		// tan sandstone to a neutral cream (rendered 0.728/0.707/0.581, R and
		// G within 3%). Half strength keeps the biome shift without erasing
		// the rock's own hue.
		vec3 biome = mix(vec3(1.0), cliff_rock_tint, 0.45);
		a1 = mix(a1, rock_color * rock_albedo_gain * biome,
			strata_mask * clamp(rock_strata_strength, 0.0, 1.0) * 0.85);

		// Ledge relief. Three taps: the Y one is what actually carves the
		// horizontal bedding shelves, so it stays despite being the single
		// most expensive line here. If this ever costs too much on a weak
		// GPU, dropping the Y tap is the lever - it will flatten the ledges.
		float eps = 0.10;
		float hx = sample_rock_height(v_world_pos + vec3(eps, 0.0, 0.0));
		float hz = sample_rock_height(v_world_pos + vec3(0.0, 0.0, eps));
		float hy = sample_rock_height(v_world_pos + vec3(0.0, eps, 0.0));
		vec3 rock_grad = vec3(-(hx - strata_h) / eps, -(hy - strata_h) / eps * 0.35, -(hz - strata_h) / eps);
		vec3 n1_unpacked = n1 * 2.0 - 1.0;
		n1_unpacked = normalize(n1_unpacked + rock_grad * rock_bump_strength * 1.2 * strata_mask);
		n1 = n1_unpacked * 0.5 + 0.5;
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
