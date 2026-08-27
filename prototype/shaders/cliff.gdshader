shader_type spatial;
// Cliff mesh shader (canyon_ford PR1, 2026-08-26).
// Triplanar PBR rock so the same .glb tile reads as realistic rock from any
// placement angle, on any cliff orientation. Heightmap-based terrain can
// represent up to ~60° slopes cleanly; >60° is hand-placed mesh and this is
// the material the mesh uses.
//
// Used by terrain_builder.gd._spawn_cliff() for the cliff wall geometry
// declared in a map's `cliffs[]` array (FIELD_SPEC.cliffs in map_catalog.gd).
// The cliff pieces are StaticBody3D children on BattleLayers.TERRAIN so the
// ground navmesh bake (Recast) reads them as impassable holes, and the
// vision_service.gd LOS raycast (TERRAIN | BUILDINGS) reads them as visual
// cover - same dual role obstacles play today.
//
// VISUAL_ART_DIRECTION §3.1: matte rock, no faction tint, no human-scale
// detail (no doors, no windows, no road markings). The diorama rule
// survives: a cliff reads as a piece of geology, not a real cliff face.
// Match the terrain_ground.gdshader rock triplanar block (lines 255-282)
// for visual continuity - same rock_albedo, rock_normal, rock_rough
// textures can drive both, so a steep heightmap face and a cliff mesh face
// in the same map read as the same rock.

uniform sampler2D rock_albedo : source_color, filter_linear_mipmap, repeat_enable;
uniform sampler2D rock_normal : hint_normal, filter_linear_mipmap, repeat_enable;
uniform sampler2D rock_rough : hint_default_white, filter_linear_mipmap, repeat_enable;
uniform float triplanar_scale : hint_range(0.05, 1.0) = 0.2;
uniform float normal_strength : hint_range(0.0, 2.0) = 0.5;
// Per-cliff tint: most maps use 1.0,1.0,1.0 (let the rock texture speak),
// but a "Mars canyon" map can push warmth and a "frozen_fjord" map can
// desaturate. Kept on the material so each map can author a different
// tint without forking the shader.
uniform vec3 cliff_tint : source_color = vec3(1.0, 1.0, 1.0);

varying vec3 v_world_pos;
varying vec3 v_world_normal;

void vertex() {
	v_world_pos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	v_world_normal = normalize((MODEL_MATRIX * vec4(NORMAL, 0.0)).xyz);
}

void fragment() {
	// Triplanar blend weights from world-space normal. Same shape as the
	// rock triplanar in terrain_ground.gdshader:255-282 so a cliff mesh
	// face and a steep heightmap face in the same map sample the same
	// world-space texture grid - the seam between "hand-placed" and
	// "heightmap" reads as continuous, not as two different rocks.
	vec3 blending = abs(v_world_normal);
	blending = normalize(max(blending, vec3(0.00001)));
	float b_sum = blending.x + blending.y + blending.z;
	blending /= vec3(b_sum);

	// Three orthogonal projections. YZ is the "side" face, XZ is the
	// "top/bottom", XY is the "front/back". sampler2D takes vec2, so the
	// .yz / .xz / .xy swizzles go directly into texture() - no vec3
	// intermediate needed (and not allowed: a 2-component swizzle assigned
	// to a vec3 is the exact shader compile error this comment is here to
	// prevent a repeat of).
	vec3 alb_yz = texture(rock_albedo, v_world_pos.zy * triplanar_scale).rgb;
	vec3 alb_xz = texture(rock_albedo, v_world_pos.xz * triplanar_scale).rgb;
	vec3 alb_xy = texture(rock_albedo, v_world_pos.xy * triplanar_scale).rgb;
	vec3 alb = alb_yz * blending.x + alb_xz * blending.y + alb_xy * blending.z;

	vec3 nrm_yz = texture(rock_normal, v_world_pos.zy * triplanar_scale).rgb;
	vec3 nrm_xz = texture(rock_normal, v_world_pos.xz * triplanar_scale).rgb;
	vec3 nrm_xy = texture(rock_normal, v_world_pos.xy * triplanar_scale).rgb;
	vec3 nrm_unpacked = nrm_yz * blending.x + nrm_xz * blending.y + nrm_xy * blending.z;
	vec3 nrm = nrm_unpacked * 2.0 - 1.0;
	nrm.xy *= normal_strength;
	nrm = normalize(nrm);

	float rgh_yz = texture(rock_rough, v_world_pos.zy * triplanar_scale).r;
	float rgh_xz = texture(rock_rough, v_world_pos.xz * triplanar_scale).r;
	float rgh_xy = texture(rock_rough, v_world_pos.xy * triplanar_scale).r;
	float rgh = rgh_yz * blending.x + rgh_xz * blending.y + rgh_xy * blending.z;

	ALBEDO = alb * cliff_tint;
	NORMAL_MAP = nrm * 0.5 + 0.5;
	// Matte rock, per §3.1: rough enough that no specular highlight reads
	// through at any angle. The 0.85 floor kills the (rare) 0.0 rough
	// pixels some rock texture authors use to mean "any value".
	ROUGHNESS = clamp(rgh, 0.85, 0.99);
	SPECULAR = 0.0;
	METALLIC = 0.0;
}
