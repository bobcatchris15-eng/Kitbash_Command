shader_type spatial;
render_mode cull_disabled, depth_draw_opaque;

// SHELL-TEXTURED GRASS CARPET
// ---------------------------------------------------------------------------
// Real blade silhouettes without a blade of geometry per blade. The carpet is
// drawn N times, each copy lifted a little further along the surface normal,
// and each copy keeps fewer texels than the one below it. Stacked, the
// surviving texels form tapered tufts - so the grass has an actual silhouette
// against the sky and against units, which no amount of normal mapping gives.
//
// WHY THIS IS CHEAP HERE, which is the whole reason it is worth doing:
//   - the shells are ONE MultiMesh per chunk, N instances, so N shells cost
//     one draw call, with the shell index arriving in INSTANCE_CUSTOM.
//   - the carpet is CHUNKED, so each chunk has a small AABB and Godot's
//     visibility_range culls it by distance. At battle altitude the camera is
//     ~150 m up, every chunk is out of range, and the carpet costs NOTHING.
//     It only draws when the camera comes down - the proving-ground chase cam,
//     or a zoomed-in view - which is also the only time a 20 cm blade is
//     bigger than a pixel. Paying for blades at battle zoom would be paying
//     for something strictly invisible.
//   - discard, not alpha blending: no sorting, no blend cost, depth stays
//     correct so the shells self-occlude properly.

uniform float grass_height = 0.45;
uniform float blade_scale = 9.0;        // blade cells per world unit
uniform float density : hint_range(0.0, 1.0) = 0.72;
uniform float taper : hint_range(0.0, 1.0) = 0.85;

// Sat against the turf plate underneath (linear albedo 0.085), so the
// carpet does not read as a differently-coloured patch laid over the ground.
uniform vec3 root_color : source_color = vec3(0.070, 0.090, 0.045);
uniform vec3 tip_color : source_color = vec3(0.285, 0.375, 0.160);

// Grass only where the splat says grass, so the carpet stops at the rock and
// the dirt instead of growing up a cliff face.
uniform sampler2D splat_tex : filter_linear_mipmap;
uniform bool use_splat = false;
uniform float map_half_extents = 100.0;
// Backstop only. The real slope rejection arrives per-vertex in COLOR.r,
// baked from the terrain's own slope_at() at carpet build time.
uniform float slope_cutoff : hint_range(0.0, 1.0) = 0.30;

uniform float wind_speed = 1.15;
uniform float wind_strength = 0.10;

// CONTINUOUS DISTANCE FADE, and it is not optional.
// visibility_range culls a whole CHUNK at once, so on its own the carpet
// vanished in hard 96 m rectangles - clearly visible as squares of grass on a
// mid-range shot. Fading coverage per fragment means a blade has already
// thinned to nothing before its chunk is culled, so the chunk boundary never
// shows. fade_end must stay below TerrainBuilder.GRASS_VIEW_DISTANCE.
uniform float fade_start = 62.0;
uniform float fade_end = 98.0;

varying float v_t;
varying vec3 v_world;
varying float v_up;
varying float v_fit;

float hash21(vec2 p) {
	p = fract(p * vec2(123.34, 456.21));
	p += dot(p, p + 45.32);
	return fract(p.x * p.y);
}

void vertex() {
	v_t = INSTANCE_CUSTOM.r;
	vec3 w0 = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	v_up = NORMAL.y;
	v_fit = COLOR.r;

	VERTEX += NORMAL * (grass_height * v_t);

	// Wind, quadratic in height so the blade bends rather than shears.
	float gust = sin(TIME * wind_speed + w0.x * 0.22 + w0.z * 0.18)
	           + 0.4 * sin(TIME * wind_speed * 1.7 - w0.x * 0.5);
	float bend = v_t * v_t * wind_strength;
	VERTEX.x += gust * bend;
	VERTEX.z += gust * 0.6 * bend;

	v_world = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	// Bias the shading normal skyward - lighting a blade by the ground normal
	// it grew from is what makes shell grass read as painted-on carpet.
	NORMAL = normalize(mix(NORMAL, vec3(0.0, 1.0, 0.0), 0.55));
}

void fragment() {
	float cover = density;
	if (use_splat) {
		vec2 suv = v_world.xz / (map_half_extents * 2.0) + 0.5;
		cover *= texture(splat_tex, suv).r;
	}
	// No grass on ground too steep to hold it.
	cover *= v_fit;
	cover *= smoothstep(slope_cutoff, slope_cutoff + 0.25, v_up);
	if (cover <= 0.001) {
		discard;
	}

	cover *= 1.0 - smoothstep(fade_start, fade_end,
		distance(v_world, CAMERA_POSITION_WORLD));
	if (cover <= 0.001) {
		discard;
	}

	vec2 cell = floor(v_world.xz * blade_scale);
	if (hash21(cell) > cover) {
		discard;
	}

	// EVERY BLADE A DIFFERENT HEIGHT. With one height for all of them the
	// shells all terminate on the same plane and the carpet reads as corduroy
	// - a regular ribbed lattice, which is exactly what the first version
	// looked like. Ending each blade at its own height also hides the lattice
	// itself, because neighbouring tips no longer line up.
	float bh = 0.42 + 0.58 * hash21(cell + 31.7);
	if (v_t > bh) {
		discard;
	}
	float tt = v_t / bh;

	// One tuft per cell, jittered off the lattice and narrowing with height.
	vec2 jitter = vec2(hash21(cell + 3.17), hash21(cell + 7.41)) - 0.5;
	float radius = (0.22 + 0.40 * hash21(cell + 17.9)) * (1.0 - tt * taper);
	vec2 f = fract(v_world.xz * blade_scale) - 0.5 - jitter * 0.9;
	if (dot(f, f) > radius * radius) {
		discard;
	}

	// Per-blade brightness, so a field is not one flat green.
	float shade = 0.82 + 0.36 * hash21(cell + 53.1);
	ALBEDO = mix(root_color, tip_color, tt * tt * 0.7 + tt * 0.3) * shade;
	ROUGHNESS = 0.95;
	SPECULAR = 0.0;
}
