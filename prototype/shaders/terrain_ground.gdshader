shader_type spatial;
// Baseline ground for the heightmap Skirmish terrain (skirmish.gd's Ground
// mesh, built by TerrainBuilder.build_ground_visual_mesh()).
//
// Features:
// 1. Up to 8 surface variants with domain-warped quintic fBM blending.
// 2. Height-aware interlocking boundary transitions.
// 3. Slope-aware rock/scree triplanar projection on steep escarpments.
// 4. Per-map rasters: surfacemap (splat), wetness (shoreline gloss/darkening),
//    macro tint, and curvature ambient occlusion.
// 5. Distance-based micro-normal detail layer.
// 6. Calibrated desaturation & exposure grading for painterly diorama aesthetic.

uniform sampler2D albedo_0 : source_color, filter_linear_mipmap, repeat_enable;
uniform sampler2D albedo_1 : source_color, filter_linear_mipmap, repeat_enable;
uniform sampler2D albedo_2 : source_color, filter_linear_mipmap, repeat_enable;
uniform sampler2D albedo_3 : source_color, filter_linear_mipmap, repeat_enable;
uniform sampler2D albedo_4 : source_color, filter_linear_mipmap, repeat_enable;
uniform sampler2D albedo_5 : source_color, filter_linear_mipmap, repeat_enable;
uniform sampler2D albedo_6 : source_color, filter_linear_mipmap, repeat_enable;
uniform sampler2D albedo_7 : source_color, filter_linear_mipmap, repeat_enable;

uniform sampler2D normal_0 : hint_normal, filter_linear_mipmap, repeat_enable;
uniform sampler2D normal_1 : hint_normal, filter_linear_mipmap, repeat_enable;
uniform sampler2D normal_2 : hint_normal, filter_linear_mipmap, repeat_enable;
uniform sampler2D normal_3 : hint_normal, filter_linear_mipmap, repeat_enable;
uniform sampler2D normal_4 : hint_normal, filter_linear_mipmap, repeat_enable;
uniform sampler2D normal_5 : hint_normal, filter_linear_mipmap, repeat_enable;
uniform sampler2D normal_6 : hint_normal, filter_linear_mipmap, repeat_enable;
uniform sampler2D normal_7 : hint_normal, filter_linear_mipmap, repeat_enable;

uniform sampler2D rough_0 : hint_default_white, filter_linear_mipmap, repeat_enable;
uniform sampler2D rough_1 : hint_default_white, filter_linear_mipmap, repeat_enable;
uniform sampler2D rough_2 : hint_default_white, filter_linear_mipmap, repeat_enable;
uniform sampler2D rough_3 : hint_default_white, filter_linear_mipmap, repeat_enable;
uniform sampler2D rough_4 : hint_default_white, filter_linear_mipmap, repeat_enable;
uniform sampler2D rough_5 : hint_default_white, filter_linear_mipmap, repeat_enable;
uniform sampler2D rough_6 : hint_default_white, filter_linear_mipmap, repeat_enable;
uniform sampler2D rough_7 : hint_default_white, filter_linear_mipmap, repeat_enable;

// Steep slope triplanar rock projection
uniform sampler2D rock_albedo : source_color, filter_linear_mipmap, repeat_enable;
uniform sampler2D rock_normal : hint_normal, filter_linear_mipmap, repeat_enable;
uniform sampler2D rock_rough : hint_default_white, filter_linear_mipmap, repeat_enable;
uniform float slope_threshold : hint_range(0.1, 1.0) = 0.65;
uniform float slope_falloff : hint_range(0.01, 0.4) = 0.05;
uniform float triplanar_scale = 0.15;

// Per-map bake rasters
uniform sampler2D surfacemap_tex : filter_linear_mipmap;
uniform bool use_surfacemap = false;
uniform sampler2D wetness_tex : filter_linear_mipmap;
uniform bool use_wetness = false;
uniform sampler2D macro_tex : filter_linear_mipmap;
uniform bool use_macro = false;
uniform sampler2D curvature_tex : filter_linear_mipmap;
uniform bool use_curvature = false;
uniform sampler2D detail_normal_tex : hint_normal, filter_linear_mipmap, repeat_enable;
uniform float detail_normal_scale = 1.8;

uniform int variant_count : hint_range(1, 8) = 3;
uniform vec4 ground_tint : source_color = vec4(1.0);
uniform float map_half_extents = 100.0;

uniform float macro_scale = 0.06;
uniform float detail_scale = 0.19;
uniform float blend_contrast : hint_range(0.5, 8.0) = 2.2;

uniform float terrain_desaturate : hint_range(0.0, 1.0) = 0.0;
uniform float terrain_exposure_lift : hint_range(0.0, 0.5) = 0.0;

// VISUAL polish 2026-08-23: parallax offset (close-range depth illusion).
// Off by default; the GDScript / Python material setup leaves parallax_scale
// at 0 and the per-fragment `if` is a uniform branch (no divergence cost).
// When set > 0, a single-iteration height offset is applied using slot 0's
// height (the G channel of its roughness) - 1 extra texture sample per
// fragment, multiplied into all subsequent texture reads. close_fade
// ramps out the effect past parallax_max_distance so distant ground doesn't
// swim and so the extra sample + offset is skipped at long view (the
// close_fade is computed against a uniform, so the GPU can short-circuit
// the offset math entirely at long range via the if branch).
uniform float parallax_scale = 0.0;
uniform float parallax_min_distance = 40.0;
uniform float parallax_max_distance = 80.0;

varying vec3 v_world_pos;
varying vec3 v_world_normal;

// --- Noise primitives ---
uvec3 pcg3d(uvec3 v) {
	v = v * 1664525u + 1013904223u;
	v.x += v.y * v.z; v.y += v.z * v.x; v.z += v.x * v.y;
	v ^= v >> 16u;
	v.x += v.y * v.z; v.y += v.z * v.x; v.z += v.x * v.y;
	return v;
}

float hash21(vec2 p) {
	uvec2 u = uvec2(ivec2(p));
	uvec3 h = pcg3d(uvec3(u, 0u));
	return float(h.x) * (1.0 / 4294967295.0);
}

vec2 quintic(vec2 f) {
	return f * f * f * (f * (f * 6.0 - 15.0) + 10.0);
}

float value_noise(vec2 p) {
	vec2 i = floor(p);
	vec2 f = fract(p);
	vec2 u = quintic(f);
	float a = hash21(i);
	float b = hash21(i + vec2(1.0, 0.0));
	float c = hash21(i + vec2(0.0, 1.0));
	float d = hash21(i + vec2(1.0, 1.0));
	return mix(mix(a, b, u.x), mix(c, d, u.x), u.y);
}

vec2 domain_warp(vec2 p, float freq) {
	float wx = value_noise(p * freq + vec2(3.7, 9.1));
	float wy = value_noise(p * freq + vec2(8.2, 4.3));
	return p + vec2(wx, wy) * 0.31;
}

float fbm(vec2 p) {
	float v = 0.0;
	float amp = 0.5;
	float freq = 1.0;
	for (int i = 0; i < 2; i++) {
		v += amp * value_noise(p * freq);
		freq *= 1.73;
		amp *= 0.5;
	}
	return v;
}

void vertex() {
	v_world_pos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	v_world_normal = normalize((MODEL_MATRIX * vec4(NORMAL, 0.0)).xyz);
}

void _sample_slot(int idx, vec2 uv, out vec3 alb, out vec3 nrm, out float rgh, out float hgt) {
	switch (idx) {
		case 0:
			alb = texture(albedo_0, uv).rgb;
			nrm = texture(normal_0, uv).rgb;
			rgh = texture(rough_0, uv).r;
			hgt = texture(rough_0, uv).g;
			break;
		case 1:
			alb = texture(albedo_1, uv).rgb;
			nrm = texture(normal_1, uv).rgb;
			rgh = texture(rough_1, uv).r;
			hgt = texture(rough_1, uv).g;
			break;
		case 2:
			alb = texture(albedo_2, uv).rgb;
			nrm = texture(normal_2, uv).rgb;
			rgh = texture(rough_2, uv).r;
			hgt = texture(rough_2, uv).g;
			break;
		case 3:
			alb = texture(albedo_3, uv).rgb;
			nrm = texture(normal_3, uv).rgb;
			rgh = texture(rough_3, uv).r;
			hgt = texture(rough_3, uv).g;
			break;
		case 4:
			alb = texture(albedo_4, uv).rgb;
			nrm = texture(normal_4, uv).rgb;
			rgh = texture(rough_4, uv).r;
			hgt = texture(rough_4, uv).g;
			break;
		case 5:
			alb = texture(albedo_5, uv).rgb;
			nrm = texture(normal_5, uv).rgb;
			rgh = texture(rough_5, uv).r;
			hgt = texture(rough_5, uv).g;
			break;
		case 6:
			alb = texture(albedo_6, uv).rgb;
			nrm = texture(normal_6, uv).rgb;
			rgh = texture(rough_6, uv).r;
			hgt = texture(rough_6, uv).g;
			break;
		default:
			alb = texture(albedo_7, uv).rgb;
			nrm = texture(normal_7, uv).rgb;
			rgh = texture(rough_7, uv).r;
			hgt = texture(rough_7, uv).g;
			break;
	}
}

void fragment() {
	vec2 uv = UV;
	vec2 map_uv = (v_world_pos.xz / (map_half_extents * 2.0)) + vec2(0.5);

	// Domain-warped macro blend mask
	vec2 warped_uv = domain_warp(uv, macro_scale * 0.73);
	float n_macro = fbm(warped_uv);
	float n_detail = value_noise(uv * detail_scale + vec2(37.2, 11.7));
	float m = clamp((n_macro * 0.75 + n_detail * 0.25 - 0.5) * blend_contrast + 0.5, 0.0, 1.0);

	// VISUAL polish 2026-08-23: parallax offset. The blend mask `m` above
	// uses the un-parallaxed `uv` (so neighbouring variants stay blended in
	// their original positions, not in the parallaxed-shadowed positions),
	// while the texture samples below use `parallaxed_uv` (so the visible
	// surface appears to shift with the camera as a depth illusion).
	vec2 parallaxed_uv = uv;
	if (parallax_scale > 0.0) {
		vec3 view_to_frag = normalize(v_world_pos - CAMERA_POSITION_WORLD);
		float dist = length(v_world_pos - CAMERA_POSITION_WORLD);
		float close_fade = 1.0 - smoothstep(parallax_min_distance, parallax_max_distance, dist);
		float h = texture(rough_0, uv).g;
		parallaxed_uv = uv + view_to_frag.xz * h * parallax_scale * close_fade;
	}

	vec3 alb;
	vec3 nrm;
	float rgh;
	float hgt;

	int active_count = clamp(variant_count, 1, 8);
	if (active_count == 1) {
		_sample_slot(0, parallaxed_uv, alb, nrm, rgh, hgt);
	} else if (active_count == 2) {
		vec3 a0, a1, n0, n1;
		float r0, r1, h0, h1;
		_sample_slot(0, parallaxed_uv, a0, n0, r0, h0);
		_sample_slot(1, parallaxed_uv, a1, n1, r1, h1);
		// Height-aware blending
		float h_weight = clamp(((1.0 - m) * (h0 + 0.1) - m * (h1 + 0.1)) * 3.0 + 0.5, 0.0, 1.0);
		alb = mix(a1, a0, h_weight);
		nrm = mix(n1, n0, h_weight);
		rgh = mix(r1, r0, h_weight);
	} else {
		// Multi-variant ladder with height-aware interpolation
		float scaled_m = m * float(active_count - 1);
		int slot0 = int(floor(scaled_m));
		int slot1 = min(slot0 + 1, active_count - 1);
		float frac_m = fract(scaled_m);

		vec3 a0, a1, n0, n1;
		float r0, r1, h0, h1;
		_sample_slot(slot0, parallaxed_uv, a0, n0, r0, h0);
		_sample_slot(slot1, parallaxed_uv, a1, n1, r1, h1);

		float h_weight = clamp(((1.0 - frac_m) * (h0 + 0.1) - frac_m * (h1 + 0.1)) * 3.0 + 0.5, 0.0, 1.0);
		alb = mix(a1, a0, h_weight);
		nrm = mix(n1, n0, h_weight);
		rgh = mix(r1, r0, h_weight);
	}

	// Triplanar rock on steep slopes
	float slope_factor = 1.0 - clamp(v_world_normal.y, 0.0, 1.0);
	float rock_blend = smoothstep(slope_threshold - slope_falloff, slope_threshold + slope_falloff, slope_factor);
	if (rock_blend > 0.001) {
		vec3 blending = abs(v_world_normal);
		blending = normalize(max(blending, 0.00001));
		float b_sum = blending.x + blending.y + blending.z;
		blending /= vec3(b_sum);

		vec3 rock_alb_x = texture(rock_albedo, v_world_pos.zy * triplanar_scale).rgb;
		vec3 rock_alb_y = texture(rock_albedo, v_world_pos.xz * triplanar_scale).rgb;
		vec3 rock_alb_z = texture(rock_albedo, v_world_pos.xy * triplanar_scale).rgb;
		vec3 rock_alb = rock_alb_x * blending.x + rock_alb_y * blending.y + rock_alb_z * blending.z;

		vec3 rock_nrm_x = texture(rock_normal, v_world_pos.zy * triplanar_scale).rgb;
		vec3 rock_nrm_y = texture(rock_normal, v_world_pos.xz * triplanar_scale).rgb;
		vec3 rock_nrm_z = texture(rock_normal, v_world_pos.xy * triplanar_scale).rgb;
		vec3 rock_nrm = rock_nrm_x * blending.x + rock_nrm_y * blending.y + rock_nrm_z * blending.z;

		float rock_rgh_x = texture(rock_rough, v_world_pos.zy * triplanar_scale).r;
		float rock_rgh_y = texture(rock_rough, v_world_pos.xz * triplanar_scale).r;
		float rock_rgh_z = texture(rock_rough, v_world_pos.xy * triplanar_scale).r;
		float rock_rgh = rock_rgh_x * blending.x + rock_rgh_y * blending.y + rock_rgh_z * blending.z;

		alb = mix(alb, rock_alb, rock_blend);
		nrm = mix(nrm, rock_nrm, rock_blend);
		rgh = mix(rgh, rock_rgh, rock_blend);
	}

	// Micro detail normal layer
	vec3 detail_n = texture(detail_normal_tex, parallaxed_uv * detail_normal_scale).rgb;
	if (length(detail_n) > 0.1) {
		nrm = normalize(mix(nrm, detail_n, 0.25));
	}

	// Wetness modulation (darkens and boosts gloss near water edges)
	if (use_wetness) {
		float wetness = texture(wetness_tex, map_uv).r;
		alb *= mix(1.0, 0.65, wetness);
		rgh = mix(rgh, 0.15, wetness * 0.85);
	}

	// Macro tint modulation
	if (use_macro) {
		vec3 macro_tint = texture(macro_tex, map_uv).rgb;
		alb *= macro_tint;
	}

	// Curvature ambient occlusion
	if (use_curvature) {
		float curv = texture(curvature_tex, map_uv).r;
		alb *= mix(0.7, 1.15, curv);
	}

	alb *= ground_tint.rgb;

	// Grade: desaturate & exposure lift
	float luma = dot(alb, vec3(0.2126, 0.7152, 0.0722));
	alb = mix(alb, vec3(luma), terrain_desaturate);
	alb = alb * (1.0 - terrain_exposure_lift) + terrain_exposure_lift;

	ALBEDO = alb;
	NORMAL_MAP = nrm;
	ROUGHNESS = rgh;
	SPECULAR = 0.15;
}
