shader_type spatial;
render_mode unshaded, blend_mix, cull_disabled;

group_uniforms Color;
uniform vec3 core_color : source_color = vec3(1.15, 0.80, 0.26);
uniform vec3 flame_color : source_color = vec3(0.95, 0.38, 0.04);
uniform vec3 edge_color : source_color = vec3(0.45, 0.05, 0.01);
uniform vec3 smoke_color : source_color = vec3(0.10, 0.09, 0.08);
uniform float emission_strength : hint_range(0.5, 6.0) = 1.8;

group_uniforms Noise;
uniform sampler2D noise_texture : repeat_enable;
uniform vec2 noise_scale = vec2(1.8, 1.0);
uniform float scroll_speed = 9.0;
uniform float turbulence_strength = 0.45;

void vertex() {
	// 3D volumetric turbulence: makes the flame stream roil and ripple in 3D
	float t = UV.y;
	float disp_x = sin(UV.y * 16.0 - TIME * scroll_speed * 1.5 + UV.x * 6.28);
	float disp_y = cos(UV.y * 12.0 - TIME * scroll_speed * 1.2);
	vec3 disp = (NORMAL * disp_x + vec3(0.0, disp_y, 0.0)) * (turbulence_strength * t);
	VERTEX += disp;
}

void fragment() {
	// UV.x runs across ribbon width (0.0 to 1.0, center is 0.5)
	// UV.y runs along the stream from nozzle (0.0) to impact (1.0)
	float center_dist = 1.0 - abs(UV.x - 0.5) * 2.0;
	
	// Fast dual-octave scrolling fluid noise
	vec2 uv_n1 = vec2(UV.x * noise_scale.x, UV.y * noise_scale.y * 3.5 - TIME * scroll_speed);
	vec2 uv_n2 = vec2(UV.x * noise_scale.x * 2.2 + 0.3, UV.y * noise_scale.y * 6.0 - TIME * scroll_speed * 1.6);
	vec2 uv_n3 = vec2(UV.x * noise_scale.x * 0.8 - 0.2, UV.y * noise_scale.y * 2.0 - TIME * scroll_speed * 0.8);
	
	float n1 = texture(noise_texture, uv_n1).r;
	float n2 = texture(noise_texture, uv_n2).r;
	float n3 = texture(noise_texture, uv_n3).r;
	float noise = n1 * 0.5 + n2 * 0.3 + n3 * 0.2;
	
	// Ragged fluid edge erosion (eliminates flat / straight pipe look)
	float edge_mask = smoothstep(0.06, 0.58, center_dist * (0.35 + noise * 0.95));
	
	// Fade in smoothly at nozzle and splash near impact
	float start_fade = smoothstep(0.0, 0.04, UV.y);
	float end_fade = smoothstep(1.0, 0.82, UV.y);
	
	float alpha = edge_mask * start_fade * (0.88 + 0.12 * end_fade);
	
	// Temperature gradient: golden core -> roaring orange mantle -> dark ember edges
	float heat = clamp(pow(center_dist, 1.3) * 1.25 + noise * 0.35 - (UV.y * 0.35), 0.0, 1.0);
	
	vec3 col = edge_color;
	if (heat > 0.55) {
		col = mix(flame_color, core_color, (heat - 0.55) / 0.45);
	} else {
		col = mix(edge_color, flame_color, heat / 0.55);
	}
	
	// Dark smoke blending on outer envelope near the tail
	if (UV.y > 0.4 && center_dist < 0.35) {
		float smoke_factor = (UV.y - 0.4) * (1.0 - center_dist / 0.35) * (1.0 - noise * 0.5);
		col = mix(col, smoke_color, clamp(smoke_factor * 0.65, 0.0, 0.85));
	}
	
	ALBEDO = col * emission_strength;
	ALPHA = clamp(alpha, 0.0, 0.94);
}
