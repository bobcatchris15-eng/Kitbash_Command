shader_type spatial;
render_mode blend_mix, depth_draw_always, cull_disabled, diffuse_lambert_wrap, specular_schlick_ggx;

// -----------------------------------------------------------------------------
// HULL LIVERY & SURFACE SHADER
// -----------------------------------------------------------------------------
// Unified spatial shader supporting:
// 1. Three hull livery zones (lower, upper, pattern/stripe) with unique colors and finishes
// 2. Procedural pattern & camouflage engine (13 distinct pattern types)
// 3. Tactile micro-surface synthesis for finishes (carbon weave, hammered, zinc flakes, brushed grain, etc.)
// 4. Dynamic toon/comic-book lighting with true metallic specular response
// 5. Service weathering and edge wear/chipping modulation

uniform vec4 base_color : source_color = vec4(1.0, 1.0, 1.0, 1.0);
uniform vec4 accent_color : source_color = vec4(1.0, 1.0, 1.0, 1.0);
uniform float metallic : hint_range(0.0, 1.0) = 1.0;
uniform float roughness : hint_range(0.0, 1.0) = 0.42;
uniform float roughness_bias : hint_range(-0.3, 0.3) = 0.0;
uniform vec4 emissive_color : source_color = vec4(0.0, 0.0, 0.0, 1.0);
uniform float emissive_strength : hint_range(0.0, 2.0) = 0.0;

// Shared hull surface textures (panel lines, rivets, micro-grain)
uniform sampler2D albedo_tex : source_color, filter_linear_mipmap, repeat_enable;
uniform sampler2D normal_tex : hint_normal, filter_linear_mipmap, repeat_enable;
uniform sampler2D roughness_tex : hint_default_white, filter_linear_mipmap, repeat_enable;
uniform float texture_scale : hint_range(0.02, 1.0) = 0.12;
uniform vec3 mesh_scale = vec3(1.0, 1.0, 1.0);
uniform float normal_strength : hint_range(0.0, 2.0) = 1.0;
// Procedural micro-surface (carbon-fibre weave, hammered dimples, etc.):
// layered ON TOP of the shared panel/bolts normal. Kept separate from
// normal_strength so the shared texture can be at full lab-equivalent
// strength while the procedural detail stays dialed. Defaults to a
// moderate level so the shared normal still reads.
uniform float micro_surface_strength : hint_range(0.0, 1.0) = 0.35;

// Armor & damage uniforms
uniform float shield_mode : hint_range(0.0, 1.0) = 0.0;
uniform float alpha_base : hint_range(0.0, 1.0) = 1.0;
uniform float flash_amount : hint_range(0.0, 1.0) = 0.0;
// Indirect / ambient lift. Without this, PBR diffuse is 0 on back-facing
// surfaces and the livery is unreadable from the side/back of the hull.
// The default 0.25 is in the realistic IBL range for non-metals (metals
// get less lift from real IBL because their reflectance eats the diffuse,
// but the simple version here lifts everything uniformly - dial down to
// 0.0 if you want the back to be properly black on a metallic livery).
// Added as EMISSION so it stacks on top of the PBR diffuse without
// interfering with the diffuse_lambert_wrap model; for the front face
// the PBR already gives full diffuse, and the EMISSION clamps to 1.0.
// 2026-08-31: 0.25 -> 0.06. At 0.25 every unit and building in the game
// self-illuminated at a quarter of its own albedo, which flattened the
// lighting (shadowed sides glowed), removed the dark end of the value
// range, and made saturated paint read as backlit plastic. It was a
// workaround for "the livery is unreadable on a face pointing away from the
// sun", and that problem is now solved properly: Battle.tscn's ambient
// source is the sky (was a flat colour), so an unlit face gets real sky
// fill. A small residual is kept so the read never fully collapses.
uniform float indirect_lift : hint_range(0.0, 1.0) = 0.06;
uniform float edge_ink_strength : hint_range(0.0, 1.0) = 0.95;
uniform float ink_width : hint_range(0.05, 0.9) = 0.32;
uniform vec3 ink_color : source_color = vec3(0.04, 0.035, 0.05);
uniform float ink_curvature_gain : hint_range(0.005, 1.0) = 0.06;
uniform float ink_rim_strength : hint_range(0.0, 1.0) = 0.55;

// Friendly rim-light: adds a subtle bright edge on silhouette-facing
// surfaces. 0.0 = off (used for enemies who get the inverted-hull outline
// instead), >0.0 = friendly rim强度. Set by unit_assembly.gd per-team.
uniform float friendly_rim_strength : hint_range(0.0, 1.0) = 0.0;
uniform vec3 friendly_rim_color : source_color = vec3(1.0, 0.95, 0.85);
uniform float friendly_rim_power : hint_range(0.5, 8.0) = 3.0;

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

// ACCENT EMISSIVE - marker lights, and the new home of team identity.
//
// Team colour used to be applied as PAINT, over whole objects: a fully
// saturated hull plus a ~50%-coverage camo/hazard pattern in a second
// saturated tone. When most of the frame is saturated, none of it reads, and
// the objects look like toys. Reference RTS frames run a desaturated base and
// spend chroma on a few percent of pixels - almost always as small bright
// lights.
//
// So the paint is now a desaturated camo pair (see livery.gd's PRESETS) and
// the saturated faction hue moved here. The mask is deliberately tiny: a
// sparse scatter of cells off the panel grid, biased to the upper hull, which
// reads as running lights on a vehicle and lit windows on a building.
//
// Applied ADDITIVELY and after the existing emissive branch, so it composes
// with the indirect lift and the shield/flash overrides instead of replacing
// them - a glowing shield still wins, but a shielded unit keeps its marker
// lights.
uniform vec4 accent_emissive_color : source_color = vec4(0.0, 0.0, 0.0, 1.0);
uniform float accent_emissive_strength : hint_range(0.0, 8.0) = 0.0;
// Half-length of a lamp along the hull, in normalised hull space. 0.035 makes
// each station about 7% of the hull's length - a fitting, not a stripe.
// Height up the hull, in normalised hull space, at which the marker lights sit -
// on the shoulder, just below the deck line.
const float ACCENT_LIGHT_HEIGHT = 0.62;
uniform float accent_light_length : hint_range(0.005, 0.2) = 0.045;
// Cells per world unit for the light scatter. Independent of texture_scale so
// light SIZE stays physical even where the panel texture does not (see the
// texel-density note in hull_material_builder.gd).

uniform float livery_mix : hint_range(0.0, 1.0) = 0.0;
uniform float zone_split : hint_range(0.0, 1.0) = 0.45;
uniform float zone_split_softness : hint_range(0.0, 0.2) = 0.012;
uniform float stripe_enabled : hint_range(0.0, 1.0) = 1.0;

// --- Procedural Pattern Engine ---
// 0=none, 1=stripe, 2=dual_stripe, 3=offset_stripe, 4=chevrons, 5=hazard, 6=hex_grid,
// 7=digital_camo, 8=splinter_camo, 9=tiger_camo, 10=nose_dip, 11=half_split, 12=gradient,
// 13=checkerboard, 14=zigzag, 15=urban_camo, 16=arrowhead_flash
uniform int pattern_type : hint_range(0, 16) = 1;
uniform float pattern_scale : hint_range(0.1, 5.0) = 1.0;
uniform float pattern_angle : hint_range(-180.0, 180.0) = 0.0;
uniform float pattern_offset : hint_range(-1.0, 1.0) = 0.0;
uniform float pattern_softness : hint_range(0.001, 0.3) = 0.015;
uniform float pattern_edge_darken : hint_range(0.0, 1.0) = 0.45;

// Legacy stripe controls (maintained for compatibility)
uniform float stripe_axis : hint_range(0.0, 1.0) = 0.0;
uniform float stripe_center : hint_range(0.0, 1.0) = 0.62;
uniform float stripe_width : hint_range(0.0, 0.5) = 0.11;
uniform float stripe_softness : hint_range(0.0, 0.2) = 0.015;
uniform float stripe_edge_darken : hint_range(0.0, 1.0) = 0.45;

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

void vertex() {
	world_pos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	world_normal = normalize((MODEL_MATRIX * vec4(NORMAL, 0.0)).xyz);
	model_pos = VERTEX;
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

// PCG3D integer hash (X5 fix): Bit-exact on every GPU and immune to coordinate precision loss.
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
		// None / Clean Split
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
		// Offset Rally Stripe (Port flank)
		float dist = abs(uv_rot.x - 0.22 * sc) * 2.0;
		float w = 0.11 * sc;
		pattern_mask = 1.0 - smoothstep(w - soft, w + soft, dist);
		piping_mask = (smoothstep(w - soft, w + soft, dist) - smoothstep(w + soft * 2.0, w + soft * 5.0, dist)) * pattern_edge_darken;
	} else if (pattern_type == 4) {
		// Tactical Chevrons (V-Stripes)
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
	} else if (pattern_type == 13) {
		// Checkerboard Flash
		vec2 c_uv = floor(uv_rot * 6.0 * sc);
		pattern_mask = mod(c_uv.x + c_uv.y, 2.0);
	} else if (pattern_type == 14) {
		// Zigzag Lightning Stripe - a stripe whose x-offset sawtooths along y
		float period = 0.5 / sc;
		float saw = abs(fract(uv_rot.y / period) - 0.5) * 2.0;
		float x_off = (saw - 0.5) * period;
		float dist = abs(uv_rot.x - x_off) * 2.0;
		float w = 0.10 * sc;
		pattern_mask = 1.0 - smoothstep(w - soft, w + soft, dist);
		piping_mask = (smoothstep(w - soft, w + soft, dist) - smoothstep(w + soft * 2.0, w + soft * 5.0, dist)) * pattern_edge_darken;
	} else if (pattern_type == 15) {
		// Urban Brick Camo - offset rectangular block camouflage
		vec2 b_uv = uv_rot * 4.0 * sc;
		float row = floor(b_uv.y);
		b_uv.x += mod(row, 2.0) * 0.5;
		vec2 uc_cell = floor(b_uv);
		float rand_val = hash2d(uc_cell + vec2(pattern_offset));
		pattern_mask = step(0.5, rand_val);
	} else if (pattern_type == 16) {
		// Arrowhead Flash - single bold forward-pointing arrow marking
		float chev = abs(uv_rot.x) * 1.2 + uv_rot.y * 2.0 * sc;
		pattern_mask = 1.0 - smoothstep(0.14 - soft, 0.14 + soft, abs(chev));
	}

	pattern_mask *= stripe_enabled;
	piping_mask *= stripe_enabled;
}

// Procedural Micro-Surface Synthesis
vec3 synthesize_micro_surface(int s_type, vec3 p, vec3 geo_n, vec3 tri_w, inout float r_mod, inout float m_mod) {
	vec3 pert = vec3(0.0);
	if (s_type == 1) {
		// Carbon Fibre (2x2 twill weave)
		vec2 c_uv = (p.xz * tri_w.y + p.xy * tri_w.z + p.zy * tri_w.x) * 48.0;
		float wx = sin(c_uv.x * 3.14159);
		float wy = cos(c_uv.y * 3.14159);
		pert = vec3(cos(c_uv.x * 3.14159) * 0.28, sin(c_uv.y * 3.14159) * 0.28, 0.0);
		r_mod += (wx * wy * 0.12);
	} else if (s_type == 2) {
		// Hammered Metal (Crater dimples)
		vec2 h_uv = (p.xz * tri_w.y + p.xy * tri_w.z + p.zy * tri_w.x) * 16.0;
		vec2 cell_f = fract(h_uv) - vec2(0.5);
		float d = length(cell_f);
		float pit = smoothstep(0.12, 0.42, d);
		pert = vec3(cell_f * (1.0 - pit) * 0.45, 0.0);
		r_mod += (pit - 0.5) * 0.22;
	} else if (s_type == 3) {
		// Cast Iron / Phosphate (Sand-cast granular micro-pitting)
		vec3 np = p * 60.0;
		float g = sin(np.x * 8.0) * sin(np.y * 8.0) * sin(np.z * 8.0);
		pert = vec3(sin(np.y * 12.0) * 0.22, cos(np.x * 12.0) * 0.22, 0.0);
		r_mod += g * 0.16;
	} else if (s_type == 4) {
		// Galvanised Zinc (Crystalline Voronoi Spangle Flakes)
		vec2 z_uv = (p.xz * tri_w.y + p.xy * tri_w.z + p.zy * tri_w.x) * 12.0;
		vec2 cell = floor(z_uv);
		float rnd = hash2d(cell);
		m_mod += (rnd - 0.5) * 0.35;
		r_mod += (rnd - 0.5) * 0.24;
		pert = vec3((rnd - 0.5) * 0.18, (rnd - 0.5) * 0.18, 0.0);
	} else if (s_type == 5) {
		// Brushed Metal (Linear longitudinal grain)
		float grain = sin(p.x * 110.0 + p.y * 110.0);
		pert = vec3(grain * 0.14, 0.0, 0.0);
		r_mod += grain * 0.08;
	} else if (s_type == 6) {
		// Cerakote / Matte Primer (Micro-stipple chalk absorption)
		r_mod += 0.06;
		m_mod -= 0.15;
	} else if (s_type == 7) {
		// Rubberised (Deep light absorption)
		r_mod += 0.08;
		m_mod -= 0.20;
	} else if (s_type == 8) {
		// Fiberglass (Strand bundle relief)
		vec2 f_uv = (p.xz * tri_w.y + p.xy * tri_w.z + p.zy * tri_w.x) * 32.0;
		float fib = sin(f_uv.x * 6.0 + sin(f_uv.y * 14.0));
		pert = vec3(fib * 0.20, cos(f_uv.y * 10.0) * 0.15, 0.0);
		r_mod += fib * 0.12;
	} else if (s_type == 9) {
		// Anodised Aluminum (Smooth high-chroma metallic pop)
		m_mod += 0.15;
		r_mod -= 0.08;
	}
	return pert;
}

void fragment() {
	vec3 geo_normal = normalize(world_normal);
	vec3 tri_w = triplanar_weights(geo_normal);
	vec3 tex_pos = model_pos * mesh_scale * texture_scale;

	vec3 tex_albedo = triplanar_sample(albedo_tex, tex_pos, tri_w).rgb;
	float tex_roughness = triplanar_sample(roughness_tex, tex_pos, tri_w).r;

	// Normalized local bounds coordinates
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

	// Blend zone colors and finishes
	vec3 zone_albedo = mix(zone_lower_color.rgb, zone_upper_color.rgb, upper_mask);
	float zone_metallic = mix(zone_lower_metallic, zone_upper_metallic, upper_mask);
	float zone_roughness = mix(zone_lower_roughness, zone_upper_roughness, upper_mask);
	int zone_surface = int(mix(float(zone_lower_surface), float(zone_upper_surface), upper_mask));

	zone_albedo = mix(zone_albedo, stripe_color.rgb, pattern_mask);
	zone_metallic = mix(zone_metallic, zone_stripe_metallic, pattern_mask);
	zone_roughness = mix(zone_roughness, zone_stripe_roughness, pattern_mask);
	if (pattern_mask > 0.5) {
		zone_surface = zone_stripe_surface;
	}
	zone_albedo *= (1.0 - piping);

	// Multiplicative tints
	vec3 color = tex_albedo * zone_albedo * base_color.rgb * accent_color.rgb;

	// Cold-War military color grading & desaturation
	float luma = dot(color, vec3(0.2126, 0.7152, 0.0722));
	color = mix(vec3(luma), color, min(color_saturation, 1.05));
	color = clamp(color, vec3(0.0), vec3(1.0));

	// Multi-tiered service weathering & edge wear (red-lead primer + dark oxidized steel)
	vec3 d_normal = fwidth(world_normal);
	vec3 d_pos = fwidth(world_pos);
	float curvature = length(d_normal) / max(length(d_pos), 0.0001);
	float edge_curvature = clamp(curvature * 0.05, 0.0, 1.0);

	float effective_weathering = max(weathering, 0.15); // Authentic baseline military service wear
	float chip_threshold = 1.0 - effective_weathering * 0.65;
	float chip_noise = tex_roughness + (hash2d(floor(tex_pos.xz * 32.0)) - 0.5) * 0.4;
	float chip_mask = smoothstep(chip_threshold - 0.08, chip_threshold + 0.08, edge_curvature * chip_noise * 1.6);

	vec3 red_primer = vec3(0.38, 0.16, 0.11);
	vec3 oxidized_steel = vec3(0.16, 0.17, 0.18);
	vec3 wear_color = mix(red_primer, oxidized_steel, smoothstep(0.4, 0.8, chip_mask));

	color = mix(color, wear_color, chip_mask * 0.92);
	zone_metallic = mix(zone_metallic, 0.75, chip_mask);
	zone_roughness = mix(zone_roughness, 0.62, chip_mask);

	// Lower hull mud & dirt accumulation gradient
	float ground_clearance = clamp((model_pos.y - local_bounds_y.x) / max(local_bounds_y.y - local_bounds_y.x, 0.01), 0.0, 1.0);
	float mud_mask = (1.0 - smoothstep(0.0, 0.45, ground_clearance)) * (0.65 + 0.35 * tex_roughness);
	vec3 mud_color = vec3(0.20, 0.17, 0.13);
	color = mix(color, mud_color, mud_mask * 0.85);
	zone_metallic = mix(zone_metallic, 0.05, mud_mask);
	zone_roughness = mix(zone_roughness, 0.95, mud_mask);

	// Recess grease and crevice grime
	float grime_mask = (1.0 - edge_curvature) * (1.0 - tex_albedo.r) * effective_weathering * 0.65;
	color = mix(color, color * 0.28, grime_mask);

	color = mix(color, vec3(1.0, 0.05, 0.05), flash_amount);
	ALBEDO = color;

	// Procedural Micro-Surface Synthesis (Pitted cast steel & rolled armor)
	float rough_mod = 0.0;
	float metal_mod = 0.0;
	vec3 micro_pert = synthesize_micro_surface(zone_surface, tex_pos, geo_normal, tri_w, rough_mod, metal_mod);

	METALLIC = clamp((zone_metallic + metal_mod) * metallic, 0.0, 1.0);

	float base_roughness = mix(roughness, zone_roughness + rough_mod, livery_mix);
	float rough_floor = mix(0.15, 0.40, livery_mix);
	ROUGHNESS = clamp(base_roughness + roughness_bias + (tex_roughness - 0.5) * 0.65, rough_floor, 1.0);

	// Combined normal: shared panel/bolts texture at normal_strength, plus
	// the procedural micro-surface layer scaled independently. Splitting the
	// two (instead of adding micro_pert into the mix) is what lets the test
	// range show the same shared normal at full strength that the lab's
	// StandardMaterial3D already shows - the lab doesn't have a micro-surface
	// at all, so a viewer expecting the lab's "square and bolts" read was
	// previously getting a 45%-strong shared normal + a 45%-strong micro layer
	// on top, which read as a different surface.
	vec3 tex_world_normal = triplanar_normal(normal_tex, tex_pos, geo_normal, tri_w);
	vec3 base_normal = mix(geo_normal, tex_world_normal, normal_strength);
	vec3 final_world_normal = normalize(base_normal + micro_pert * micro_surface_strength);
	NORMAL = normalize((VIEW_MATRIX * vec4(final_world_normal, 0.0)).xyz);

	ALPHA = alpha_base;
	// Indirect/ambient lift: the PBR diffuse contribution is zero on a
	// face that points away from the light, so the livery is unreadable
	// from the back/side of the unit without an indirect term. Set the
	// baseline EMISSION to a fraction of the weathered+grimed colour so
	// the back reads as the same material in shadow rather than as a
	// black silhouette. The shield / emissive_strength overrides below
	// win when active, so a glowing shield or a true emissive accent
	// still override the ambient lift.
	EMISSION = color * indirect_lift;
	if (shield_mode > 0.5) {
		EMISSION = base_color.rgb * 0.12;
	} else if (emissive_strength > 0.0) {
		EMISSION = emissive_color.rgb * emissive_strength;
	}

	// Marker lights. See accent_emissive_color's note above for why team
	// identity lives here rather than in the paint.
	if (accent_emissive_strength > 0.0) {
		// DELIBERATE STATIONS, not a hashed scatter.
		//
		// The first version picked a sparse set of cells off a hashed grid,
		// which is random by construction: the lamps landed wherever the hash
		// said, in different places on the two flanks, and read as arbitrary
		// glowing blobs rather than as fittings. Chris, on seeing them: "they
		// seem to just be randomly placed".
		//
		// Now they sit at three fixed stations along the length, on the
		// shoulder line, MIRRORED across the centreline by construction
		// (`flank` uses abs, so port and starboard are identical). Six lamps on
		// a vehicle, in the places a real machine carries marker lights.
		//
		// Normalised hull space rather than physical: a lamp scaling with the
		// vehicle is correct here - a bigger machine carries bigger lights -
		// and it keeps the stations at the same proportional positions on every
		// hull in the roster.
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
		// Mud drowns a lamp; a chipped-through panel no longer has one.
		lamp *= (1.0 - mud_mask) * (1.0 - chip_mask);
		if (lamp > 0.001) {
			EMISSION += accent_emissive_color.rgb * accent_emissive_strength * lamp;
			// A lamp is not painted metal.
			ALBEDO = mix(ALBEDO, accent_emissive_color.rgb * 0.35, lamp * 0.8);
		}
	}

	// Friendly rim-light: brightens silhouette edges on friendly units so
	// they read clearly against terrain without the heavy outline used on
	// enemies. The rim is directional (stronger on the sun-facing side)
	// and composited additively via EMISSION so it doesn't wash out the
	// livery underneath.
	if (friendly_rim_strength > 0.0) {
		vec3 view_dir = normalize(CAMERA_POSITION_WORLD - (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz);
		float rim = 1.0 - max(dot(view_dir, final_world_normal), 0.0);
		rim = pow(rim, friendly_rim_power);
		EMISSION += friendly_rim_color * rim * friendly_rim_strength;
	}
}
