shader_type spatial;
render_mode depth_draw_always;

// Kitbash Command Water Shader (Phase 6)
// Features:
// 1. Shoreline foam edge and depth-based color absorption via DEPTH_TEXTURE.
// 2. Animated dual scrolling normal map waves.
// 3. Painterly, low-specular water aesthetic matching 1:16 diorama scale.

uniform vec4 deep_color : source_color = vec4(0.08, 0.16, 0.22, 0.94);
uniform vec4 shallow_color : source_color = vec4(0.22, 0.35, 0.38, 0.82);
uniform vec4 foam_color : source_color = vec4(0.85, 0.90, 0.92, 0.95);
uniform float foam_distance : hint_range(0.05, 3.0) = 0.85;

uniform sampler2D normal_map_a : hint_normal, filter_linear_mipmap, repeat_enable;
uniform sampler2D normal_map_b : hint_normal, filter_linear_mipmap, repeat_enable;
uniform vec2 wave_speed_a = vec2(0.02, 0.015);
uniform vec2 wave_speed_b = vec2(-0.015, 0.025);
uniform float wave_scale = 0.12;

uniform float roughness : hint_range(0.0, 1.0) = 0.18;
uniform float specular : hint_range(0.0, 1.0) = 0.35;

uniform sampler2D depth_texture : hint_depth_texture, filter_linear_mipmap;

void fragment() {
	vec2 uv_a = UV * wave_scale + wave_speed_a * TIME;
	vec2 uv_b = UV * wave_scale + wave_speed_b * TIME;
	
	vec3 n_a = texture(normal_map_a, uv_a).rgb * 2.0 - 1.0;
	vec3 n_b = texture(normal_map_b, uv_b).rgb * 2.0 - 1.0;
	vec3 nrm = normalize(n_a + n_b);
	
	// Depth-based foam and absorption
	float depth_raw = texture(depth_texture, SCREEN_UV).r;
	vec3 ndc = vec3(SCREEN_UV * 2.0 - 1.0, depth_raw);
	vec4 view_pos = INV_PROJECTION_MATRIX * vec4(ndc, 1.0);
	view_pos.xyz /= view_pos.w;
	float depth_diff = VERTEX.z - view_pos.z;
	
	float depth_factor = clamp(depth_diff * 0.4, 0.0, 1.0);
	vec4 water_col = mix(shallow_color, deep_color, depth_factor);
	
	float foam_factor = 1.0 - clamp(depth_diff / foam_distance, 0.0, 1.0);
	foam_factor = pow(foam_factor, 1.8);
	
	vec3 final_color = mix(water_col.rgb, foam_color.rgb, foam_factor);
	float final_alpha = mix(water_col.a, foam_color.a, foam_factor);
	
	ALBEDO = final_color;
	NORMAL_MAP = nrm * 0.5 + 0.5;
	ROUGHNESS = roughness;
	SPECULAR = specular;
	// Vertex alpha feathers a PAINTED shoreline. The painted-water mesh is
	// built from raster texels, so its outline is a staircase; carrying the
	// brush's coverage falloff into alpha softens that edge instead of leaving
	// a hard 4 m step. Meshes without vertex colours get COLOR = white, so the
	// map-wide table and the authored water_areas are unaffected.
	ALPHA = final_alpha * COLOR.a;
}
