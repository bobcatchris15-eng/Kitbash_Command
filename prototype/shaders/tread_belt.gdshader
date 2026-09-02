shader_type spatial;
render_mode cull_back, diffuse_burley, specular_schlick_ggx;

// Scrolling tread-link band. unit.gd advances uv_offset every frame by
// surface_speed * delta so the band visibly scrolls in the direction of
// travel and freezes when the vehicle is stationary. One ShaderMaterial
// instance per belt (see VisualBuilder._belt_material) - uv_offset is
// per-vehicle state, never shared.
uniform vec4 albedo_color : source_color = vec4(0.2, 0.2, 0.22, 1.0);
uniform float metallic_amount : hint_range(0.0, 1.0) = 0.55;
uniform float roughness_amount : hint_range(0.0, 1.0) = 0.75;
uniform float uv_offset = 0.0;
uniform float stripe_freq = 14.0;

void fragment() {
	float scrolled = fract(UV.y * stripe_freq - uv_offset);
	float band = smoothstep(0.0, 0.10, scrolled) - smoothstep(0.45, 0.55, scrolled);
	vec3 col = mix(albedo_color.rgb * 0.55, albedo_color.rgb, band);
	ALBEDO = col;
	METALLIC = metallic_amount;
	ROUGHNESS = roughness_amount;
}
