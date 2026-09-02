shader_type spatial;
render_mode unshaded, blend_mix, cull_disabled;

group_uniforms Color;
uniform vec3 primary_color : source_color = vec3(1.0, 0.68, 0.18);
uniform vec3 secondary_color : source_color = vec3(0.65, 0.10, 0.02);
uniform float emission : hint_range(0.0, 16.0) = 3.5;

group_uniforms Shape;
uniform sampler2D noise_texture : repeat_enable;
uniform vec2 noise_scale = vec2(1.2, 1.0);
uniform vec2 noise_scroll = vec2(0.0, 2.5);
uniform float flame_density : hint_range(0.0, 1.0) = 0.5;

group_uniforms Wobble;
uniform float wobble_amount = 1.0;
uniform float wobble_frequency = 10.0;
uniform float wobble_speed = 6.0;

group_uniforms Alpha;
uniform float edge_hardness : hint_range(0.0, 1.0) = 0.85;
uniform float edge_position : hint_range(0.0, 1.0) = 0.20;

void vertex() {
	// Particle Camera Billboard
	mat4 billboard = mat4(
			INV_VIEW_MATRIX[0],
			INV_VIEW_MATRIX[1],
			INV_VIEW_MATRIX[2],
			MODEL_MATRIX[3]);
	MODELVIEW_MATRIX = VIEW_MATRIX * mat4(
			INV_VIEW_MATRIX[0],
			INV_VIEW_MATRIX[1],
			INV_VIEW_MATRIX[2],
			vec4(VERTEX, 1.0));
}

void fragment() {
	// Radial mask centered on quad
	vec2 centered_uv = UV * 2.0 - 1.0;
	float radial_dist = length(centered_uv);
	float shape_mask = clamp(1.0 - radial_dist, 0.0, 1.0);
	
	// Flame heat wobble
	float wobble = sin(UV.y * wobble_frequency - TIME * wobble_speed) * (wobble_amount * 0.08);
	
	// Fast upward scrolling simplex noise
	vec2 uv_sample = vec2(UV.x * noise_scale.x + wobble, UV.y * noise_scale.y - TIME * noise_scroll.y);
	vec2 uv_sample2 = vec2(UV.x * noise_scale.x * 1.6 - wobble, UV.y * noise_scale.y * 1.8 - TIME * noise_scroll.y * 1.4);
	
	float n1 = texture(noise_texture, uv_sample).r;
	float n2 = texture(noise_texture, uv_sample2).r;
	float noise = mix(n1, n2, 0.4);
	
	// Dissolve / shape calculation
	float flame_val = shape_mask * (noise * 0.8 + 0.3) + pow(shape_mask, (1.0 - flame_density) * 6.0) * 0.4;
	
	float r_edge = mix(1.0, edge_position + 0.02, edge_hardness);
	float alpha = smoothstep(edge_position, r_edge, flame_val);
	
	// Modulate by particle vertex alpha if provided
	alpha *= clamp(COLOR.a, 0.0, 1.0);
	
	// Multi-color temperature gradient (hot center -> cooler edges)
	float heat = clamp(pow(shape_mask, 1.2) * 1.3 + noise * 0.3 - (UV.y * 0.2), 0.0, 1.0);
	vec3 color = mix(secondary_color, primary_color, heat);
	
	ALBEDO = color * emission;
	ALPHA = clamp(alpha, 0.0, 0.95);
}
