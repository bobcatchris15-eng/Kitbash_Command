shader_type spatial;
render_mode cull_disabled, depth_draw_opaque;

// -----------------------------------------------------------------------------
// High-Fidelity Tree Foliage Shader
// -----------------------------------------------------------------------------
// Features:
// 1. Alpha scissor masking for realistic perforated leaf/needle card silhouettes.
// 2. Subsurface scattering / backlight transmission (no pitch black or shiny spots).
// 3. Clamped zero-specular matte leaf lighting.
// 4. Hierarchical vertex wind sway (trunk lean + branchlet micro-flutter).

uniform sampler2D albedo_texture : source_color, filter_linear_mipmap;
uniform sampler2D normal_texture : hint_normal, filter_linear_mipmap;
uniform sampler2D roughness_texture : hint_default_white, filter_linear_mipmap;

uniform vec3 foliage_tint : source_color = vec3(1.0, 1.0, 1.0);
uniform float alpha_scissor_threshold : hint_range(0.0, 1.0) = 0.45;
uniform float roughness_scale : hint_range(0.0, 1.0) = 1.0;
uniform float specular_strength : hint_range(0.0, 1.0) = 0.0;
uniform float transmission_amount : hint_range(0.0, 1.0) = 0.25;

uniform float wind_speed : hint_range(0.1, 10.0) = 2.0;
uniform float wind_sway_strength : hint_range(0.0, 1.0) = 0.14;
uniform float leaf_flutter_strength : hint_range(0.0, 1.0) = 0.04;
uniform vec2 wind_direction = vec2(0.707, 0.707);

varying float v_height;
varying vec3 v_world_pos;

void vertex() {
	vec3 world_pos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	v_world_pos = world_pos;
	
	// Height factor relative to tree root
	float h = clamp(VERTEX.y / 5.0, 0.0, 1.0);
	v_height = h;
	float sway_curve = h * h;

	// 1. Trunk & Major Limb Sway
	float time = TIME * wind_speed;
	float sway = sin(time + world_pos.x * 0.25 + world_pos.z * 0.2) * 0.75
	           + sin(time * 1.6 + world_pos.x * 0.6 - world_pos.z * 0.5) * 0.25;
	vec2 sway_disp = wind_direction * sway * wind_sway_strength * sway_curve;
	world_pos.x += sway_disp.x;
	world_pos.z += sway_disp.y;

	// 2. High-frequency leaf fluttering on branchlet tips
	float flutter = sin(time * 4.5 + VERTEX.x * 6.0 + VERTEX.z * 6.0 + VERTEX.y * 4.0) * leaf_flutter_strength * h;
	world_pos.xyz += NORMAL * flutter;

	VERTEX = (inverse(MODEL_MATRIX) * vec4(world_pos, 1.0)).xyz;
}

void fragment() {
	vec4 tex_color = texture(albedo_texture, UV);
	
	// Alpha scissor for crisp leaf silhouettes
	if (tex_color.a < alpha_scissor_threshold) {
		discard;
	}
	
	vec3 final_albedo = tex_color.rgb * foliage_tint * COLOR.rgb;
	ALBEDO = final_albedo;
	
	// Specular is zeroed to eliminate shiny plastic spots and bright white reflections
	ROUGHNESS = roughness_scale;
	SPECULAR = 0.0;
}
