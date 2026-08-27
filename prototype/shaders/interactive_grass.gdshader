shader_type spatial;
render_mode cull_disabled, depth_draw_opaque;

// -----------------------------------------------------------------------------
// Interactive Reactive Grass Shader
// -----------------------------------------------------------------------------
// High-visibility, lush tactical grass with GPU-driven wind sway and real-time
// unit avoidance / push-aside displacement.

uniform vec3 base_color : source_color = vec3(0.23, 0.32, 0.16);
uniform vec3 tip_color : source_color = vec3(0.32, 0.42, 0.21);
uniform float roughness : hint_range(0.0, 1.0) = 0.98;
uniform float specular : hint_range(0.0, 1.0) = 0.0;

uniform float grass_height : hint_range(0.1, 2.0) = 0.22;
uniform float wind_speed : hint_range(0.1, 10.0) = 2.4;
uniform float wind_strength : hint_range(0.0, 1.0) = 0.22;
uniform vec2 wind_direction = vec2(0.707, 0.707);

// Up to 32 active moving units in the vicinity
// xyz = global world position, w = repulsion radius
uniform vec4 unit_positions[32];
uniform int unit_count = 0;

varying float v_height;
varying vec3 v_world_pos;

void vertex() {
	vec3 world_pos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	v_world_pos = world_pos;
	
	// Local height from root (ground level = 0.0)
	float h = clamp(VERTEX.y / max(grass_height, 0.08), 0.0, 1.0);
	float bend_factor = h * h;
	v_height = h;

	// 1. Procedural dual-frequency wind sway on GPU
	float time = TIME * wind_speed;
	float gust = sin(time + world_pos.x * 0.35 + world_pos.z * 0.25) * 0.7
	           + sin(time * 1.8 + world_pos.x * 0.8 - world_pos.z * 0.6) * 0.3;
	vec2 wind_disp = wind_direction * gust * wind_strength * bend_factor;
	world_pos.x += wind_disp.x;
	world_pos.z += wind_disp.y;

	// 2. Unit dynamic repulsion / bending away from hulls, wheels, and walkers
	for (int i = 0; i < unit_count; i++) {
		vec3 u_pos = unit_positions[i].xyz;
		float u_radius = unit_positions[i].w;
		if (u_radius > 0.05) {
			vec2 delta_xz = world_pos.xz - u_pos.xz;
			float dist_sq = dot(delta_xz, delta_xz);
			float rad_sq = u_radius * u_radius;
			if (dist_sq < rad_sq && dist_sq > 0.0001) {
				float dist = sqrt(dist_sq);
				float push_intensity = (1.0 - (dist / u_radius)) * bend_factor;
				vec2 push_dir = delta_xz / dist;
				
				// Push outward horizontally and compress downward
				world_pos.xz += push_dir * push_intensity * 0.95;
				world_pos.y -= push_intensity * 0.05;
			}
		}
	}

	// Convert back from displaced world position to model vertex space
	VERTEX = (inverse(MODEL_MATRIX) * vec4(world_pos, 1.0)).xyz;
	
	// Re-orient normal slightly upward for soft foliage lighting
	NORMAL = normalize(vec3(NORMAL.x * 0.3, 0.9, NORMAL.z * 0.3));
}

void fragment() {
	vec3 col = mix(base_color, tip_color, v_height) * COLOR.rgb;
	
	ALBEDO = col;
	ROUGHNESS = roughness;
	SPECULAR = specular;
	// No backlight — grass must never outshine units. The old 0.35 tip
	// backlight made grass brighter than unit hulls when backlit by sun.
}
