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

// Scroll coordinate comes from the mesh's own local Z (the belt's authored
// travel axis in every builder - tracked_treads' deformed loop, half_track's
// and heavy_quad_tracks' ht_track_bogie block), NOT from UV.y. ht_track_bogie
// is exported as many discrete unwrapped boxes (see
// tools/blender/build_locomotion_rework.py:build_ht_track_bogie) with no
// continuous V gradient along the belt's length, so a UV-driven scroll reads
// as a static/frozen band on that mesh even though uv_offset is genuinely
// advancing every frame. VERTEX in vertex() is local (pre-MODEL-matrix)
// space, so this works regardless of the source mesh's UV quality.
varying float v_length_coord;

void vertex() {
	v_length_coord = VERTEX.z;
}

void fragment() {
	float scrolled = fract(v_length_coord * stripe_freq - uv_offset);
	float band = smoothstep(0.0, 0.10, scrolled) - smoothstep(0.45, 0.55, scrolled);
	vec3 col = mix(albedo_color.rgb * 0.55, albedo_color.rgb, band);
	ALBEDO = col;
	METALLIC = metallic_amount;
	ROUGHNESS = roughness_amount;
}
