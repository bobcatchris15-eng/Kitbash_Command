shader_type spatial;
// fog_disabled: this is the MAP BORDER, a UI affordance drawn as geometry.
// Depth fog is a cue about distance through air; applying it to the border
// only bleaches the one element that has to stay legible at max zoom-out.
// The fog-of-war shroud in vision_service.gd declares the same for the same
// reason.
render_mode unshaded, cull_disabled, depth_draw_opaque, fog_disabled;

// Dark void of the holotable outside the map.
// Green phosphor grid drifts slowly; occasional brighter scan sweep.
//
// Tuned for 1920×1080 tactical zoom: base reads as dark grey in shade
// (not pure black which crushes against the fog), grid as CRT green.
// Animation is subtle — 1 cm/s drift + 4 s sweep — so it reads as
// "live display" not "dance floor".

uniform vec3 base_color : source_color = vec3(0.055, 0.06, 0.068);
uniform vec3 grid_color : source_color = vec3(0.16, 0.96, 0.36);
uniform vec3 scan_color : source_color = vec3(0.22, 1.0, 0.48);

uniform vec2 grid_scale = vec2(28.0);
uniform float line_thickness : hint_range(0.01, 0.2) = 0.055;
uniform float scan_speed : hint_range(0.0, 2.0) = 0.09;
uniform float drift_speed : hint_range(0.0, 0.5) = 0.06;
uniform float glow_strength : hint_range(0.0, 3.0) = 0.85;
uniform float sweep_speed : hint_range(0.0, 1.5) = 0.18;
uniform float sweep_width : hint_range(0.01, 0.3) = 0.08;

// Slight vignette toward far edge of the void so horizon doesn't read as a hard line.
uniform float vignette_strength : hint_range(0.0, 1.0) = 0.35;

// CRT distortion — barrel warp plus phosphor grille. Mirrors the live-layer
// logic in phosphor_display.gdshader but for world-space void walls. Warp is
// applied to the phosphor lines themselves (not just a screen filter) so the
// grid bows as a real tube would.
uniform float crt_barrel : hint_range(0.0, 0.4) = 0.14;
uniform float crt_barrel2 : hint_range(0.0, 0.2) = 0.06;
uniform float grille_depth : hint_range(0.0, 0.3) = 0.10;
uniform float scanline_depth : hint_range(0.0, 0.5) = 0.22;
uniform float scanline_pitch : hint_range(1.0, 8.0) = 3.0;
uniform float flicker_amount : hint_range(0.0, 0.1) = 0.025;
uniform float flicker_speed : hint_range(0.0, 200.0) = 73.0;
uniform float chroma_shift : hint_range(0.0, 0.02) = 0.004;

varying vec2 v_uv;
varying vec3 v_world;

void vertex() {
	v_uv = UV;
	v_world = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
}

vec2 barrel_warp(vec2 uv, float k1, float k2) {
	vec2 c = uv - vec2(0.5);
	float r2 = dot(c, c);
	float r4 = r2 * r2;
	float warp = 1.0 + k1 * r2 + k2 * r4;
	return c * warp + vec2(0.5);
}

void fragment() {
	// --- CRT barrel warp on the phosphor itself -----------------------------
	// Warp the local UV so the grid lines bow outward as a tube does.
	// Keep warp subtle (k1 0.14) — enough to read as glass curvature at
	// tactical zoom, not funhouse. Per-strip warp still reads as one
	// continuous holotable because the wall shader's vignette hides seams.
	vec2 warped_uv = barrel_warp(v_uv, crt_barrel, crt_barrel2);
	// Chromatic micro-shift: sample grid slightly offset per channel for
	// the classic CRT fringing when viewed close. Cheap — just offset the
	// warped UV before the grid calc and later mix channels.
	vec2 warped_r = barrel_warp(v_uv + vec2(chroma_shift, 0.0), crt_barrel * 1.08, crt_barrel2);
	vec2 warped_b = barrel_warp(v_uv - vec2(chroma_shift, 0.0), crt_barrel * 0.92, crt_barrel2);

	// --- Drift ---------------------------------------------------------------
	vec2 drift = vec2(TIME * drift_speed * 0.5, TIME * drift_speed);
	vec2 g_uv = warped_uv * grid_scale + drift;
	vec2 g_uv_r = warped_r * grid_scale + drift;
	vec2 g_uv_b = warped_b * grid_scale + drift;

	// Anti-aliased grid with chromatic offset: evaluate R/B channels on
	// slightly shifted barrels so edges fringe as a real phosphor.
	vec2 f = fract(g_uv);
	vec2 f_r = fract(g_uv_r);
	vec2 f_b = fract(g_uv_b);
	vec2 df = fwidth(g_uv) * 0.6;
	vec2 dist = min(f, vec2(1.0) - f);
	vec2 dist_r = min(f_r, vec2(1.0) - f_r);
	vec2 dist_b = min(f_b, vec2(1.0) - f_b);

	float lw = line_thickness * 0.5;
	float lx = 1.0 - smoothstep(lw - df.x, lw + df.x, dist.x);
	float ly = 1.0 - smoothstep(lw - df.y, lw + df.y, dist.y);
	float lx_r = 1.0 - smoothstep(lw - df.x, lw + df.x, dist_r.x);
	float ly_r = 1.0 - smoothstep(lw - df.y, lw + df.y, dist_r.y);
	float lx_b = 1.0 - smoothstep(lw - df.x, lw + df.x, dist_b.x);
	float ly_b = 1.0 - smoothstep(lw - df.y, lw + df.y, dist_b.y);
	float grid = max(lx, ly);
	float grid_r = max(lx_r, ly_r);
	float grid_b = max(lx_b, ly_b);
	float cross = lx * ly;
	grid = max(grid, cross * 0.85);

	// --- Slow scan sweep: bright band travelling along V --------------------
	float sweep_phase = fract(TIME * sweep_speed * 0.35 - warped_uv.y * 0.6 + warped_uv.x * 0.15);
	float sd = min(sweep_phase, 1.0 - sweep_phase);
	float sweep = exp(-sd * sd / max(sweep_width * sweep_width * 0.18, 0.0001)) * 0.55;
	sweep *= (0.35 + 0.65 * grid);

	// --- CRT scanlines + grille + flicker (from phosphor_display) -----------
	// Scanlines in screen pixels would need FRAGCOORD; use warped UV at a
	// pitch that maps ~3 px at 1080p so lines stay constant across strip sizes.
	float line_phase = warped_uv.y * 210.0 + TIME * 1.5;
	float scanline = 1.0 - scanline_depth * (0.5 + 0.5 * cos(line_phase));
	float grille_phase = warped_uv.x * 210.0;
	float grille = 1.0 - grille_depth * (0.5 + 0.5 * cos(grille_phase));
	float flicker = 1.0 - flicker_amount * (0.5 + 0.5 * sin(TIME * flicker_speed + warped_uv.x * 13.0));

	// --- Barrel-aware vignette (curvature falloff) --------------------------
	vec2 d = warped_uv - vec2(0.5);
	float vig = 1.0 - vignette_strength * dot(d, d) * 1.2;
	// Extra curvature darkening at extreme barrel — mimics tube edge
	float r2 = dot(d, d);
	vig *= 1.0 - 0.18 * r2;
	vig = clamp(vig, 0.58, 1.0);

	// --- Compose --------------------------------------------------------------
	// Chromatic phosphor: R slightly warm, B slightly cool fringe on grid edges
	vec3 phosphor = grid_color * grid * glow_strength;
	phosphor.r *= (0.88 + 0.22 * grid_r);
	phosphor.b *= (0.88 + 0.22 * grid_b);
	vec3 col = base_color;
	col += phosphor * flicker * scanline * grille;
	col += scan_color * sweep * 0.9;
	col *= vig;

	// Subtle world-height desaturation so vertical walls don't glow hotter than floor
	float wall_fade = clamp(1.0 - max(0.0, v_world.y - 40.0) * 0.006, 0.82, 1.0);
	col *= wall_fade;

	ALBEDO = col;
	EMISSION = col * (0.25 + grid * 0.65 + sweep * 0.5);
	ALPHA = 1.0;
}
