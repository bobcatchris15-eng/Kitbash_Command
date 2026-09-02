shader_type spatial;
render_mode unshaded, blend_add, cull_disabled;

group_uniforms Color;
uniform vec3 core_color : source_color = vec3(1.0, 0.95, 0.7);
uniform vec3 flame_color : source_color = vec3(1.0, 0.45, 0.08);
uniform vec3 edge_color : source_color = vec3(0.8, 0.1, 0.02);
uniform float emission_core : hint_range(0.0, 16.0) = 5.0;
uniform float emission_flame : hint_range(0.0, 16.0) = 3.0;

group_uniforms Stream;
uniform sampler2D noise_texture : repeat_enable;
uniform vec2 noise_scale = vec2(2.0, 0.4);
uniform float stream_speed = 6.0;
uniform float turbulence_strength = 0.25;
uniform float stream_taper = 0.6;

void vertex() {
	float width_mult = mix(0.4, 1.0 + stream_taper, UV.y);
	VERTEX.x *= width_mult;
	VERTEX.z *= width_mult;
	
	float wave = sin(UV.y * 14.0 - TIME * stream_speed * 1.5) * turbulence_strength * UV.y;
	VERTEX.x += wave * 0.15;
	VERTEX.z += cos(UV.y * 11.0 - TIME * stream_speed * 1.2) * turbulence_strength * 0.15 * UV.y;
}

void fragment() {
	vec2 uv_scroll = vec2(UV.x * noise_scale.x, (UV.y * noise_scale.y) - TIME * stream_speed);
	vec2 uv_scroll_fast = vec2(UV.x * noise_scale.x * 1.5 + 0.3, (UV.y * noise_scale.y * 2.0) - TIME * stream_speed * 1.6);
	
	float n1 = texture(noise_texture, uv_scroll).r;
	float n2 = texture(noise_texture, uv_scroll_fast).r;
	float noise = mix(n1, n2, 0.4);
	
	float center_dist = abs(dot(NORMAL, VIEW));
	float erosion = smoothstep(0.15, 0.75, noise * 0.7 + center_dist * 0.6);
	float length_fade = smoothstep(0.0, 0.08, UV.y) * smoothstep(1.0, 0.85, UV.y);
	float alpha = erosion * length_fade;
	
	float heat = clamp(center_dist * 1.4 + noise * 0.5 - (1.0 - UV.y) * 0.2, 0.0, 1.0);
	
	vec3 col = edge_color;
	if (heat > 0.5) {
		col = mix(flame_color * emission_flame, core_color * emission_core, (heat - 0.5) * 2.0);
	} else {
		col = mix(edge_color * 1.5, flame_color * emission_flame, heat * 2.0);
	}
	
	ALBEDO = col;
	ALPHA = clamp(alpha, 0.0, 1.0);
}
