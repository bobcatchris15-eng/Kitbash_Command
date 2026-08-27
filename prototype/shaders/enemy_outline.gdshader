shader_type spatial;
render_mode cull_front, depth_draw_opaque, unshaded;

// Inverted-hull outline: renders back faces only, pushes vertices outward
// along their normals to create a silhouette edge around the unit. Used
// for ENEMY units to make them readable against terrain at any angle.

uniform vec4 outline_color : source_color = vec4(0.0, 0.0, 0.0, 1.0);
uniform float outline_width : hint_range(0.0, 0.1) = 0.025;

void vertex() {
	VERTEX += NORMAL * outline_width;
}

void fragment() {
	ALBEDO = outline_color.rgb;
	ALPHA = outline_color.a;
}
