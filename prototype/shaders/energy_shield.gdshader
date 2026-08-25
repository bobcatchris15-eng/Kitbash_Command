shader_type spatial;
render_mode blend_add, cull_disabled, unshaded, depth_draw_never;

// The energy_shielding hull material's visible bubble.
//
// Chris's brief: "mostly transparent but for occasional crackles that pass
// through the ellipsoid it generates". So the base state is very nearly
// invisible - a faint fresnel rim so the volume reads as present at all -
// and the interest is in discrete arcs that TRAVEL across the surface rather
// than a uniform shimmer. A constantly-glowing bubble would read as a solid
// object and would fight every silhouette inside it.
//
// blend_add + depth_draw_never so the hull, its greebles and its modules all
// remain fully visible through it; the shield brightens what is behind it
// instead of hiding it. cull_back rather than disabled so we see one surface
// at a time and the far side does not double the brightness.
//
// WHAT THIS REPLACES AND WHY (PR 6, 2026-08-13):
// v1 used uncorrupted local-space coordinates for both crackle noise fields.
// The two fields were two independent planar noise samples sliding over each
// other over time — mechanically correct, but the arc paths read as too uniform
// and regular, the kind of procedural shimmer the document describes as "flat
// and homogeneous."
// v2 adds spatial domain warping: a low-frequency noise field is sampled and
// its gradient is applied as a coordinate offset to the primary crackle
// samples. The warp field itself does not move over time; only the crackle
// samples slide through it. This bends the crackle paths organically without
// making the warp field itself a moving pattern. The quintic interpolation
// upgrade (same as terrain_ground.gdshader v2) keeps transitions smooth.

uniform vec4 shield_color : source_color = vec4(0.35, 0.72, 1.0, 1.0);
uniform float fresnel_power : hint_range(0.5, 8.0) = 3.2;
uniform float base_opacity : hint_range(0.0, 0.5) = 0.055;
uniform float crackle_speed : hint_range(0.0, 4.0) = 0.9;
uniform float crackle_sharpness : hint_range(1.0, 64.0) = 46.0;
uniform float crackle_gain : hint_range(0.0, 4.0) = 0.85;
uniform float impact_flash : hint_range(0.0, 1.0) = 0.0;
// Strength of the spatial warp applied to crackle paths. 0 = uncorrupted
// v1 behaviour; higher = more organic, less mechanical arc geometry.
uniform float warp_strength : hint_range(0.0, 2.0) = 0.35;

varying vec3 v_local;
varying vec3 v_normal_v;
varying vec3 v_view;

// --- Noise primitives (same as terrain_ground.gdshader v2) ---

float hash13(vec3 p) {
	p = fract(p * 0.1031);
	p += dot(p, p.yzx + 33.33);
	return fract((p.x + p.y) * p.z);
}

// Quintic Hermite interpolation — continuous second derivative, eliminates
// the staircase artifact that smoothstep produces at grazing angles.
vec3 quintic(vec3 f) {
	return f * f * f * (f * (f * 6.0 - 15.0) + 10.0);
}

float vnoise(vec3 p) {
	vec3 i = floor(p);
	vec3 f = fract(p);
	vec3 u = quintic(f);
	float n000 = hash13(i + vec3(0.0, 0.0, 0.0));
	float n100 = hash13(i + vec3(1.0, 0.0, 0.0));
	float n010 = hash13(i + vec3(0.0, 1.0, 0.0));
	float n110 = hash13(i + vec3(1.0, 1.0, 0.0));
	float n001 = hash13(i + vec3(0.0, 0.0, 1.0));
	float n101 = hash13(i + vec3(1.0, 0.0, 1.0));
	float n011 = hash13(i + vec3(0.0, 1.0, 1.0));
	float n111 = hash13(i + vec3(1.0, 1.0, 1.0));
	return mix(
		mix(mix(n000, n100, u.x), mix(n010, n110, u.x), u.y),
		mix(mix(n001, n101, u.x), mix(n011, n111, u.x), u.y),
		u.z
	);
}

// Domain warp: samples two low-frequency noise fields and uses their gradient
// as a coordinate offset. The warp field is static — only the primary
// crackle field slides through it over time — so the arc paths bend
// organically without introducing a second moving pattern.
vec3 domain_warp(vec3 p, float freq) {
	float wx = vnoise(p * freq + vec3(2.3, 5.7, 1.1));
	float wy = vnoise(p * freq + vec3(7.1, 3.4, 6.2));
	float wz = vnoise(p * freq + vec3(4.9, 8.8, 2.8));
	return vec3(wx, wy, wz) * warp_strength;
}

void vertex() {
	v_local = VERTEX;
	v_normal_v = NORMAL;
	v_view = VERTEX;
}

void fragment() {
	vec3 n = normalize(NORMAL);
	float fres = pow(1.0 - clamp(abs(dot(n, normalize(VIEW))), 0.0, 1.0), fresnel_power);

	float t = TIME * crackle_speed;

	// Domain-warped crackle samples: the warp bends the noise space so the
	// arc paths are organic rather than mechanically regular. Each field uses
	// a different warp frequency so they don't sync up.
	vec3 base1 = v_local * 3.1 + vec3(0.0, t, t * 0.6);
	vec3 base2 = v_local * 5.7 + vec3(-t * 0.8, t * 0.3, 0.0);
	vec3 wp1 = domain_warp(v_local, 0.65);
	vec3 wp2 = domain_warp(v_local, 1.05);

	float n1 = vnoise(base1 + wp1);
	float n2 = vnoise(base2 + wp2);

	// Ridge extraction: pow on a thin slice of the noise, so the surface is
	// dark almost everywhere and briefly very bright along a moving filament.
	float ridge1 = pow(1.0 - abs(n1 - 0.5) * 2.0, crackle_sharpness);
	float ridge2 = pow(1.0 - abs(n2 - 0.5) * 2.0, crackle_sharpness * 0.7);

	// Gated by a slow travelling envelope so arcs come in BURSTS with quiet
	// stretches between them. Without this the two ridges are always
	// somewhere on the surface and the shield reads as a permanent glowing
	// web rather than as something that occasionally crackles.
	float gate = smoothstep(0.35, 0.75,
		vnoise(v_local * 0.9 + vec3(t * 0.5, 0.0, -t * 0.35)));

	float crackle = clamp(ridge1 + ridge2 * 0.6, 0.0, 1.0) * crackle_gain * gate;

	// Occasional whole-surface pulses, so the shield does something even when
	// no arc happens to be crossing the visible face.
	float pulse = smoothstep(0.86, 1.0, vnoise(vec3(t * 0.35)));

	float a = base_opacity + fres * 0.30 + crackle + pulse * 0.10 + impact_flash;
	ALBEDO = shield_color.rgb * (0.25 + crackle * 1.4 + impact_flash * 2.0);
	ALPHA = clamp(a, 0.0, 1.0);
}
