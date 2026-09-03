shader_type spatial;
render_mode blend_mix, depth_draw_always, cull_disabled, diffuse_lambert_wrap, specular_schlick_ggx;

// -----------------------------------------------------------------------------
// ARMOR SURFACE & LIVERY INHERITANCE SHADER
// -----------------------------------------------------------------------------
// In the Design Lab: renders the unpainted scale model plastic finish (grey-green)
// with the armor's physical tactile normal relief applied.
// In Match / Battle: seamlessly inherits the underlying hull's livery (zones,
// camouflage/patterns, textures, and weathering) with the armor normals on top.

uniform mat4 facet_to_hull = mat4(1.0);
uniform float scale_model_mode : hint_range(0.0, 1.0) = 0.0;
uniform vec4 scale_model_color : source_color = vec4(0.38, 0.44, 0.37, 1.0);

// --- Armor Type Finish & Relief ---
// pattern_id: 0=Steel Plate (rolled mill grain), 1=Composite Plate (tessellated triangles),
// 2=Ceramic Ablative (square tiles), 3=Ballistic Nylon (2x2 twill weave)
uniform int pattern_id : hint_range(-1, 4) = 0;
uniform float cell : hint_range(0.02, 2.0) = 0.45;
uniform float relief : hint_range(0.0, 3.0) = 0.75;
uniform float seam : hint_range(0.005, 0.3) = 0.05;
uniform float thickness : hint_range(0.2, 4.0) = 1.0;
uniform float armor_metallic : hint_range(0.0, 1.0) = 0.45;
uniform float armor_roughness : hint_range(0.0, 1.0) = 0.58;

// --- Livery & Hull Base Uniforms ---
uniform vec4 base_color : source_color = vec4(1.0, 1.0, 1.0, 1.0);
uniform vec4 accent_color : source_color = vec4(1.0, 1.0, 1.0, 1.0);
uniform float metallic : hint_range(0.0, 1.0) = 1.0;
uniform float roughness : hint_range(0.0, 1.0) = 0.42;
uniform float roughness_bias : hint_range(-0.3, 0.3) = 0.0;
uniform vec4 emissive_color : source_color = vec4(0.0, 0.0, 0.0, 1.0);
uniform float emissive_strength : hint_range(0.0, 2.0) = 0.0;

// Hull Surface Textures (panel lines, rivets, micro-grain)
uniform sampler2D albedo_tex : source_color, filter_linear_mipmap, repeat_enable;
uniform sampler2D normal_tex : hint_normal, filter_linear_mipmap, repeat_enable;
uniform sampler2D roughness_tex : hint_default_white, filter_linear_mipmap, repeat_enable;
uniform float texture_scale : hint_range(0.02, 1.0) = 0.12;
uniform vec3 mesh_scale = vec3(1.0, 1.0, 1.0);
uniform float normal_strength : hint_range(0.0, 2.0) = 0.45;

// Armor & Damage
uniform float shield_mode : hint_range(0.0, 1.0) = 0.0;
uniform float alpha_base : hint_range(0.0, 1.0) = 1.0;
uniform float flash_amount : hint_range(0.0, 1.0) = 0.0;
// 2026-08-31: 0.25 -> 0.06. At 0.25 every unit and building in the game
// self-illuminated at a quarter of its own albedo, which flattened the
// lighting (shadowed sides glowed), removed the dark end of the value
// range, and made saturated paint read as backlit plastic. It was a
// workaround for "the livery is unreadable on a face pointing away from the
// sun", and that problem is now solved properly: Battle.tscn's ambient
// source is the sky (was a flat colour), so an unlit face gets real sky
// fill. A small residual is kept so the read never fully collapses.
uniform float indirect_lift : hint_range(0.0, 1.0) = 0.06;

// ACCENT EMISSIVE - marker lights, and the new home of team identity.
// Mirrors the block of the same name in hull_faction_material.gdshader; these
// two shaders already duplicate evaluate_pattern, hash2d and the whole
// weathering stack, and this follows that existing structure rather than
// introducing an include for one feature.
//
// This file is the one that matters most for the effect: armor facets are the
// large visible plates on a built vehicle, and setting these uniforms on the
// hull shader alone was a silent no-op here (Godot drops unknown shader
// params), which is why the first attempt produced no lights at all.
uniform vec4 accent_emissive_color : source_color = vec4(0.0, 0.0, 0.0, 1.0);
uniform float accent_emissive_strength : hint_range(0.0, 8.0) = 0.0;
// Height up the hull, in normalised hull space, at which the marker lights sit -
// on the shoulder, just below the deck line.
const float ACCENT_LIGHT_HEIGHT = 0.62;
uniform float accent_light_length : hint_range(0.005, 0.2) = 0.045;

// --- Livery Zones ---
uniform vec4 zone_lower_color : source_color = vec4(1.0, 1.0, 1.0, 1.0);
uniform vec4 zone_upper_color : source_color = vec4(1.0, 1.0, 1.0, 1.0);
uniform vec4 stripe_color : source_color = vec4(1.0, 1.0, 1.0, 1.0);
uniform float zone_lower_metallic : hint_range(0.0, 1.0) = 1.0;
uniform float zone_lower_roughness : hint_range(0.0, 1.0) = 0.85;
uniform int zone_lower_surface : hint_range(0, 9) = 0;
uniform float zone_upper_metallic : hint_range(0.0, 1.0) = 1.0;
uniform float zone_upper_roughness : hint_range(0.0, 1.0) = 0.85;
uniform int zone_upper_surface : hint_range(0, 9) = 0;
uniform float zone_stripe_metallic : hint_range(0.0, 1.0) = 1.0;
uniform float zone_stripe_roughness : hint_range(0.0, 1.0) = 0.85;
uniform int zone_stripe_surface : hint_range(0, 9) = 0;

uniform float livery_mix : hint_range(0.0, 1.0) = 1.0;
uniform float zone_split : hint_range(0.0, 1.0) = 0.45;
uniform float zone_split_softness : hint_range(0.0, 0.2) = 0.012;
uniform float stripe_enabled : hint_range(0.0, 1.0) = 1.0;

// --- Procedural Pattern Engine ---
// 0=none, 1=stripe, 2=dual_stripe, 3=offset_stripe, 4=chevrons, 5=hazard, 6=hex_grid,
// 7=digital_camo, 8=splinter_camo, 9=tiger_camo, 10=nose_dip, 11=half_split, 12=gradient
uniform int pattern_type : hint_range(0, 12) = 1;
uniform float pattern_scale : hint_range(0.1, 5.0) = 1.0;
uniform float pattern_angle : hint_range(-180.0, 180.0) = 0.0;
uniform float pattern_offset : hint_range(-1.0, 1.0) = 0.0;
uniform float pattern_softness : hint_range(0.001, 0.3) = 0.015;
uniform float pattern_edge_darken : hint_range(0.0, 1.0) = 0.45;

// Mesh Local Bounds
uniform vec2 local_bounds_y = vec2(-0.5, 0.5);
uniform vec2 local_bounds_x = vec2(-0.5, 0.5);
uniform vec2 local_bounds_z = vec2(-0.5, 0.5);

// Weathering & Service Wear Dial
uniform float weathering : hint_range(0.0, 1.0) = 0.0;

// --- Toon Lighting Settings ---
uniform float toon_bands : hint_range(1.0, 6.0) = 3.0;
uniform float toon_softness : hint_range(0.0, 0.5) = 0.06;
uniform vec3 toon_shadow_tint : source_color = vec3(0.55, 0.50, 0.42);
uniform float toon_shadow_floor : hint_range(0.0, 0.8) = 0.28;
uniform float toon_specular_strength : hint_range(0.0, 2.0) = 0.35;
uniform float color_saturation : hint_range(0.0, 2.5) = 1.35;
uniform float color_lift : hint_range(0.0, 0.5) = 0.06;

varying vec3 world_pos;
varying vec3 world_normal;
varying vec3 model_pos;
varying vec2 facet_uv;

void vertex() {
	world_pos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	world_normal = normalize((MODEL_MATRIX * vec4(NORMAL, 0.0)).xyz);
	// Map vertex into hull model space so livery zones and patterns align perfectly
	model_pos = (facet_to_hull * vec4(VERTEX, 1.0)).xyz;
	facet_uv = UV;
}

vec3 triplanar_weights(vec3 n) {
	vec3 w = pow(abs(n), vec3(4.0));
	return w / max(w.x + w.y + w.z, 0.0001);
}

vec4 triplanar_sample(sampler2D tex, vec3 pos, vec3 w) {
	vec4 xaxis = texture(tex, pos.zy);
	vec4 yaxis = texture(tex, pos.xz);
	vec4 zaxis = texture(tex, pos.xy);
	return xaxis * w.x + yaxis * w.y + zaxis * w.z;
}

vec3 triplanar_normal(sampler2D tex, vec3 pos, vec3 n, vec3 w) {
	vec3 tx = texture(tex, pos.zy).rgb * 2.0 - 1.0;
	vec3 ty = texture(tex, pos.xz).rgb * 2.0 - 1.0;
	vec3 tz = texture(tex, pos.xy).rgb * 2.0 - 1.0;
	tx.z *= sign(n.x);
	ty.z *= sign(n.y);
	tz.z *= sign(n.z);
	vec3 world_nx = vec3(tx.z, tx.y, tx.x);
	vec3 world_ny = vec3(ty.x, ty.z, ty.y);
	vec3 world_nz = vec3(tz.x, tz.y, tz.x);
	return normalize(world_nx * w.x + world_ny * w.y + world_nz * w.z);
}

uvec3 pcg3d(uvec3 v) {
	v = v * 1664525u + 1013904223u;
	v.x += v.y * v.z; v.y += v.z * v.x; v.z += v.x * v.y;
	v ^= v >> 16u;
	v.x += v.y * v.z; v.y += v.z * v.x; v.z += v.x * v.y;
	return v;
}

float hash2d(vec2 p) {
	uvec2 u = uvec2(ivec2(p));
	uvec3 h = pcg3d(uvec3(u, 0u));
	return float(h.x) * (1.0 / 4294967295.0);
}

float edge_distance(vec2 p) {
	vec2 f = fract(p) - 0.5;
	vec2 d = 0.5 - abs(f);
	return min(d.x, d.y);
}

float hash21(vec2 p) {
	return fract(sin(dot(p, vec2(41.3, 289.1))) * 43758.5453);
}

// Procedural Pattern Synthesizer
void evaluate_pattern(vec3 norm_coords, vec2 uv_rot, out float pattern_mask, out float piping_mask) {
	float z_x = norm_coords.x;
	float z_y = norm_coords.y;
	float z_z = norm_coords.z;
	float sc = max(pattern_scale, 0.05);
	float soft = max(pattern_softness, 0.002);
	
	pattern_mask = 0.0;
	piping_mask = 0.0;
	
	if (pattern_type == 0) {
		pattern_mask = 0.0;
		piping_mask = 0.0;
	} else if (pattern_type == 1) {
		// Centerline Stripe
		float dist = abs(uv_rot.x) * 2.0;
		float w = 0.12 * sc;
		pattern_mask = 1.0 - smoothstep(w - soft, w + soft, dist);
		piping_mask = (smoothstep(w - soft, w + soft, dist) - smoothstep(w + soft * 2.0, w + soft * 5.0, dist)) * pattern_edge_darken;
	} else if (pattern_type == 2) {
		// Dual Racing Stripes
		float dist = abs(uv_rot.x) * 2.0;
		float band = abs(dist - 0.14 * sc);
		float w = 0.055 * sc;
		pattern_mask = 1.0 - smoothstep(w - soft, w + soft, band);
		piping_mask = (smoothstep(w - soft, w + soft, band) - smoothstep(w + soft * 2.0, w + soft * 5.0, band)) * pattern_edge_darken;
	} else if (pattern_type == 3) {
		// Offset Rally Stripe
		float dist = abs(uv_rot.x - 0.22 * sc) * 2.0;
		float w = 0.11 * sc;
		pattern_mask = 1.0 - smoothstep(w - soft, w + soft, dist);
		piping_mask = (smoothstep(w - soft, w + soft, dist) - smoothstep(w + soft * 2.0, w + soft * 5.0, dist)) * pattern_edge_darken;
	} else if (pattern_type == 4) {
		// Tactical Chevrons
		float chev = abs(uv_rot.x) * 1.6 - uv_rot.y * 1.4;
		float rep = fract(chev * 3.2 * sc + pattern_offset);
		float band = abs(rep - 0.5) * 2.0;
		pattern_mask = 1.0 - smoothstep(0.42 - soft, 0.42 + soft, band);
		piping_mask = (smoothstep(0.42 - soft, 0.42 + soft, band) - smoothstep(0.42 + soft * 2.0, 0.42 + soft * 5.0, band)) * pattern_edge_darken;
	} else if (pattern_type == 5) {
		// Hazard Caution Bands
		float diag = (uv_rot.x + uv_rot.y) * 5.5 * sc + pattern_offset;
		float rep = fract(diag);
		pattern_mask = 1.0 - smoothstep(0.5 - soft, 0.5 + soft, rep);
	} else if (pattern_type == 6) {
		// Hex Tactical Grid
		vec2 h_uv = uv_rot * 10.0 * sc;
		vec2 r = vec2(1.0, 1.7320508);
		vec2 h = r * 0.5;
		vec2 a = mod(h_uv, r) - h;
		vec2 b = mod(h_uv - h, r) - h;
		vec2 g = dot(a, a) < dot(b, b) ? a : b;
		float hex_dist = max(abs(g.x) * 1.7320508 + abs(g.y), abs(g.y) * 2.0);
		pattern_mask = 1.0 - smoothstep(0.8 - soft * 4.0, 0.8 + soft * 4.0, hex_dist);
	} else if (pattern_type == 7) {
		// Digital Pixel Camo
		vec2 grid_uv = floor((uv_rot + vec2(0.5)) * 14.0 * sc);
		float rand_val = hash2d(grid_uv + vec2(pattern_offset));
		pattern_mask = step(0.52, rand_val);
	} else if (pattern_type == 8) {
		// Splinter Dazzle Camo
		vec2 s_uv = vec2(uv_rot.x * 1.5 + uv_rot.y * 0.8, uv_rot.y * 1.5 - uv_rot.x * 0.8) * 3.8 * sc;
		float f1 = sin(s_uv.x * 2.5) + cos(s_uv.y * 3.0) + sin((s_uv.x + s_uv.y) * 2.0);
		pattern_mask = smoothstep(0.2 - soft * 2.0, 0.2 + soft * 2.0, f1);
	} else if (pattern_type == 9) {
		// Tiger Wave Camo
		float wave = uv_rot.y * 7.5 * sc + sin(uv_rot.x * 8.5 * sc) * 0.75 + pattern_offset;
		float rep = fract(wave);
		float band = abs(rep - 0.5) * 2.0;
		pattern_mask = 1.0 - smoothstep(0.40 - soft, 0.40 + soft, band);
	} else if (pattern_type == 10) {
		// Dipped Nose / Cowl
		float dip_dist = z_z;
		float w = 0.32 * sc;
		pattern_mask = smoothstep(1.0 - w - soft, 1.0 - w + soft, dip_dist);
		piping_mask = (smoothstep(1.0 - w - soft, 1.0 - w + soft, dip_dist) - smoothstep(1.0 - w + soft, 1.0 - w + soft * 4.0, dip_dist)) * pattern_edge_darken;
	} else if (pattern_type == 11) {
		// Longitudinal Half Split
		pattern_mask = smoothstep(0.5 - soft, 0.5 + soft, z_x);
	} else if (pattern_type == 12) {
		// Airbrush Gradient Fade
		pattern_mask = smoothstep(0.05, 0.95, z_z);
	}
	
	pattern_mask *= stripe_enabled;
	piping_mask *= stripe_enabled;
}

// Armor Height Field for Physical Tactile Surface
float height_at(vec2 uv) {
	if (pattern_id == 0) {
		// Steel Plate: Sparse structural panel lines that occasionally dogleg 45 degrees
		vec2 p = uv / cell;
		vec2 f = fract(p);
		// Dogleg jog along seams: 45-degree diagonal offset over a segment
		float phase_y = fract(p.y * 0.4);
		float jog_x = 0.0;
		if (phase_y > 0.35 && phase_y < 0.65) {
			jog_x = (phase_y < 0.50) ? (phase_y - 0.35) : (0.65 - phase_y);
		}
		float phase_x = fract(p.x * 0.4);
		float jog_y = 0.0;
		if (phase_x > 0.35 && phase_x < 0.65) {
			jog_y = (phase_x < 0.50) ? (phase_x - 0.35) : (0.65 - phase_x);
		}
		float dx = min(abs(f.x - jog_x), abs(1.0 - f.x + jog_x));
		float dy = min(abs(f.y - jog_y), abs(1.0 - f.y + jog_y));
		float seam_dist = min(dx, dy);
		float panel_groove = smoothstep(0.0, seam * 1.5, seam_dist);
		return panel_groove * 0.90 + 0.10;
	} else if (pattern_id == 1) {
		// Composite Plate: Calmed polygonal plate facets with softened bevels
		vec2 p = uv / cell;
		vec2 ip = floor(p);
		vec2 fp = fract(p);

		bool upper = (fp.x + fp.y) > 1.0;
		float d_hyp = abs(fp.x + fp.y - 1.0) * 0.70710678;
		float d_edge = min(d_hyp, min(fp.x, fp.y));
		if (upper) {
			d_edge = min(d_hyp, min(1.0 - fp.x, 1.0 - fp.y));
		}
		// Soft chamfered plate with gentle relief (calmed, not over-deep)
		float chamfer = smoothstep(0.0, seam * 2.5, d_edge);
		return 0.5 + chamfer * 0.22;
	} else if (pattern_id == 2) {
		// Ceramic Ablative: Thin, overlapping mechanical scales (stepped shingle geometry)
		vec2 p = uv / cell;
		float row = floor(p.y);
		p.x += mod(row, 2.0) * 0.5;
		vec2 fp = fract(p);
		// Overlapping stepped scale slope
		float scale_slope = fp.y * 0.70;
		float side_dist = min(fp.x, 1.0 - fp.x);
		float side_bevel = smoothstep(0.0, seam * 2.2, side_dist);
		float overlap_edge = smoothstep(0.0, seam * 1.4, fp.y);
		return (scale_slope + 0.20) * side_bevel * overlap_edge;
	} else if (pattern_id == 3) {
		// Ballistic Nylon: Finer micro-scale weave, subtle and tactile
		vec2 g = uv / cell;
		float check = mod(floor(g.x) + floor(g.y), 2.0);
		float warp = cos(fract(g.x) * 6.28318) * 0.5 + 0.5;
		float weft = cos(fract(g.y) * 6.28318) * 0.5 + 0.5;
		return mix(weft, warp, check) * 0.20;
	} else if (pattern_id == 4) {
		// Titanium Plate: Heavy aerospace plate with welded seam bead and corner fasteners
		vec2 p = uv / cell;
		vec2 fp = fract(p);
		float d_edge = min(min(fp.x, 1.0 - fp.x), min(fp.y, 1.0 - fp.y));
		float weld_bead = exp(-pow(d_edge / (seam * 2.8), 2.0)) * 0.30;
		float plate = smoothstep(0.0, seam * 2.2, d_edge) * 0.70;
		vec2 corner_vec = min(fp, 1.0 - fp) - vec2(seam * 3.5);
		float bolt_dist = length(corner_vec);
		float bolt = (1.0 - smoothstep(0.0, seam * 1.6, bolt_dist)) * 0.35;
		return plate + weld_bead - bolt;
	}
	return 0.0;
}

void fragment() {
	vec3 geo_normal = normalize(world_normal);
	float effective_relief = relief * thickness;

	// --- DESIGN LAB / UNPAINTED SCALE MODEL FINISH ---
	if (scale_model_mode > 0.5) {
		ALBEDO = scale_model_color.rgb;
		METALLIC = 0.0;
		ROUGHNESS = 0.8;
		ALPHA = 1.0;
		EMISSION = vec3(0.0);

		if (pattern_id >= 0 && effective_relief > 0.0) {
			float eps = 0.004;
			float h = height_at(facet_uv);
			float hx = height_at(facet_uv + vec2(eps, 0.0));
			float hy = height_at(facet_uv + vec2(0.0, eps));
			vec3 n = normalize(vec3((h - hx) * effective_relief / eps, (h - hy) * effective_relief / eps, 1.0));
			NORMAL_MAP = n * 0.5 + 0.5;
			NORMAL_MAP_DEPTH = 1.0;
			ROUGHNESS = clamp(0.8 + (1.0 - h) * 0.12, 0.0, 1.0);
		} else {
			NORMAL = normalize((VIEW_MATRIX * vec4(geo_normal, 0.0)).xyz);
		}
	} else {
		// --- MATCH / BATTLE LIVERY FINISH ---
		vec3 tri_w = triplanar_weights(geo_normal);
		vec3 tex_pos = model_pos * mesh_scale * texture_scale;

		vec3 tex_albedo = triplanar_sample(albedo_tex, tex_pos, tri_w).rgb;
		float tex_roughness = triplanar_sample(roughness_tex, tex_pos, tri_w).r;

		// Normalized local bounds coordinates in hull model space
		float zone_h = clamp((model_pos.y - local_bounds_y.x)
			/ max(local_bounds_y.y - local_bounds_y.x, 0.0001), 0.0, 1.0);
		float zone_x = clamp((model_pos.x - local_bounds_x.x)
			/ max(local_bounds_x.y - local_bounds_x.x, 0.0001), 0.0, 1.0);
		float zone_z = clamp((model_pos.z - local_bounds_z.x)
			/ max(local_bounds_z.y - local_bounds_z.x, 0.0001), 0.0, 1.0);

		float upper_mask = smoothstep(zone_split - zone_split_softness,
			zone_split + zone_split_softness, zone_h);

		// Angle rotation for patterns in XZ plane
		float rad = radians(pattern_angle);
		vec2 centered_xz = vec2(zone_x - 0.5, zone_z - 0.5);
		vec2 uv_rot = vec2(
			centered_xz.x * cos(rad) - centered_xz.y * sin(rad),
			centered_xz.x * sin(rad) + centered_xz.y * cos(rad)
		);

		// Evaluate procedural pattern engine
		float pattern_mask = 0.0;
		float piping = 0.0;
		evaluate_pattern(vec3(zone_x, zone_h, zone_z), uv_rot, pattern_mask, piping);

		// Blend zone colors
		vec3 zone_albedo = mix(zone_lower_color.rgb, zone_upper_color.rgb, upper_mask);
		zone_albedo = mix(zone_albedo, stripe_color.rgb, pattern_mask);
		zone_albedo *= (1.0 - piping);

		// Multiplicative tints
		vec3 color = tex_albedo * zone_albedo * base_color.rgb * accent_color.rgb;

		// Cold-War military color grading & desaturation
		float luma = dot(color, vec3(0.2126, 0.7152, 0.0722));
		color = mix(vec3(luma), color, min(color_saturation, 1.05));
		color = clamp(color, vec3(0.0), vec3(1.0));

		// Multi-tiered service weathering & edge wear
		vec3 d_normal = fwidth(world_normal);
		vec3 d_pos = fwidth(world_pos);
		float curvature = length(d_normal) / max(length(d_pos), 0.0001);
		float edge_curvature = clamp(curvature * 0.05, 0.0, 1.0);

		float effective_weathering = max(weathering, 0.15);
		float chip_threshold = 1.0 - effective_weathering * 0.65;
		float chip_noise = tex_roughness + (hash2d(floor(tex_pos.xz * 32.0)) - 0.5) * 0.4;
		float chip_mask = smoothstep(chip_threshold - 0.08, chip_threshold + 0.08, edge_curvature * chip_noise * 1.6);

		vec3 red_primer = vec3(0.38, 0.16, 0.11);
		vec3 oxidized_steel = vec3(0.16, 0.17, 0.18);
		vec3 wear_color = mix(red_primer, oxidized_steel, smoothstep(0.4, 0.8, chip_mask));

		color = mix(color, wear_color, chip_mask * 0.92);

		// Lower hull mud & dirt accumulation gradient
		float ground_clearance = clamp((model_pos.y - local_bounds_y.x) / max(local_bounds_y.y - local_bounds_y.x, 0.01), 0.0, 1.0);
		float mud_mask = (1.0 - smoothstep(0.0, 0.45, ground_clearance)) * (0.65 + 0.35 * tex_roughness);
		vec3 mud_color = vec3(0.20, 0.17, 0.13);
		color = mix(color, mud_color, mud_mask * 0.85);

		// Recess grease and crevice grime
		float grime_mask = (1.0 - edge_curvature) * (1.0 - tex_albedo.r) * effective_weathering * 0.65;
		color = mix(color, color * 0.28, grime_mask);

		color = mix(color, vec3(1.0, 0.05, 0.05), flash_amount);
		ALBEDO = color;

		// Physical Normal Map & Tactile Armor Surface
		float h = 0.0;
		if (pattern_id >= 0 && effective_relief > 0.0) {
			float eps = 0.004;
			h = height_at(facet_uv);
			float hx = height_at(facet_uv + vec2(eps, 0.0));
			float hy = height_at(facet_uv + vec2(0.0, eps));
			vec3 n = normalize(vec3((h - hx) * effective_relief / eps, (h - hy) * effective_relief / eps, 1.0));
			NORMAL_MAP = n * 0.5 + 0.5;
			NORMAL_MAP_DEPTH = 1.0;
		} else {
			vec3 tex_world_normal = triplanar_normal(normal_tex, tex_pos, geo_normal, tri_w);
			vec3 final_world_normal = normalize(mix(geo_normal, tex_world_normal, normal_strength));
			NORMAL = normalize((VIEW_MATRIX * vec4(final_world_normal, 0.0)).xyz);
		}

		METALLIC = clamp(armor_metallic * metallic, 0.0, 1.0);
		float seam_roughness = (pattern_id >= 0 && effective_relief > 0.0) ? ((1.0 - h) * 0.18) : 0.0;
		ROUGHNESS = clamp(armor_roughness + roughness_bias + (tex_roughness - 0.5) * 0.35 + seam_roughness, 0.15, 1.0);

		ALPHA = alpha_base;
		EMISSION = color * indirect_lift;
		if (shield_mode > 0.5) {
			EMISSION = base_color.rgb * 0.12;
		} else if (emissive_strength > 0.0) {
			EMISSION = emissive_color.rgb * emissive_strength;
		}

		// Marker lights - DELIBERATE STATIONS, mirroring the block of the same
		// name in hull_faction_material.gdshader. See that file for why the
		// original hashed-cell scatter was replaced.
		if (accent_emissive_strength > 0.0) {
			// COMPACT IN BOTH AXES. The first station attempt gated only Z
			// narrowly and used a broad smoothstep over flank and height, so each
			// "lamp" was a thin band that wrapped the entire shoulder contour and
			// rendered as a glowing racing stripe. A lamp has to be small in every
			// direction: a point in (height, length) on the outboard flank.
			float flank = abs(zone_x - 0.5) * 2.0;
			// Outboard only. A lamp on the belly glows into the mud, one on the
			// centreline is a sunroof.
			float outboard = smoothstep(0.68, 0.88, flank);
			float lamp = 0.0;
			for (int i = 0; i < 3; i++) {
				float zc = 0.22 + 0.28 * float(i);
				float dz = (zone_z - zc) / accent_light_length;
				float dh = (zone_h - ACCENT_LIGHT_HEIGHT) / accent_light_length;
				float r = sqrt(dz * dz + dh * dh);
				lamp = max(lamp, (1.0 - smoothstep(0.55, 1.0, r)) * outboard);
			}
			lamp *= (1.0 - mud_mask) * (1.0 - chip_mask);
			if (lamp > 0.001) {
				EMISSION += accent_emissive_color.rgb * accent_emissive_strength * lamp;
				ALBEDO = mix(ALBEDO, accent_emissive_color.rgb * 0.35, lamp * 0.8);
			}
		}
	}
}
