extends SceneTree
# Why is the v2 ground black? Separates the three candidates:
# textures not loading, shader params not set, or mesh normals wrong.
const TB = preload("res://scripts/terrain_builder.gd")
const MC = preload("res://scripts/map_catalog.gd")

func _initialize() -> void:
	_run()

func _run() -> void:
	var map_id := "sentinel_divide"
	var args := OS.get_cmdline_user_args()
	for i in range(args.size()):
		if args[i] == "--map" and i + 1 < args.size():
			map_id = args[i + 1]
	var map_def: Dictionary = MC.get_map(map_id)
	print("=== ground material probe: %s (generator %s) ===" % [map_id, TB.terrain_generator(map_def)])

	var gc := Color(0.3, 0.34, 0.28)
	var raw = map_def.get("ground_color", null)
	if raw is Array and (raw as Array).size() >= 3:
		gc = Color(float(raw[0]), float(raw[1]), float(raw[2]))
	var mat = TB.build_ground_material_for(gc, map_def, map_id)
	print("material class: %s  shader: %s" % [mat.get_class(), (mat as ShaderMaterial).shader.resource_path if mat is ShaderMaterial else "-"])
	if mat is ShaderMaterial:
		var sm := mat as ShaderMaterial
		for p in ["albedo_0","albedo_1","albedo_2","albedo_3","normal_0","rough_0",
				"splat_tex","macro_tex","curvature_tex","wetness_tex","detail_normal_tex"]:
			var v = sm.get_shader_parameter(p)
			print("  %-18s %s" % [p, "NULL" if v == null else "%s %dx%d" % [v.get_class(), v.get_width(), v.get_height()]])
		for p in ["use_splat","use_macro","use_curvature","use_wetness","ground_tint",
				"value_floor","map_half_extents","layer_tile_size"]:
			print("  %-18s %s" % [p, str(sm.get_shader_parameter(p))])

	# Mesh normals: if these point anywhere but up on flat ground, the surface
	# gets no sun and only ambient reaches it - which looks exactly like a
	# black albedo.
	var built: Dictionary = await TB.build_ground_visual_mesh(map_def, null)
	for k in built.keys():
		var m = built[k]
		if not (m is ArrayMesh):
			continue
		var am := m as ArrayMesh
		if am.get_surface_count() == 0:
			continue
		var arr = am.surface_get_arrays(0)
		var nrm: PackedVector3Array = arr[Mesh.ARRAY_NORMAL]
		if nrm.size() == 0:
			print("  mesh %-14s HAS NO NORMAL ARRAY - unlit, renders ambient-only" % str(k))
			continue
		var acc := Vector3.ZERO
		var n := mini(nrm.size(), 8000)
		for i in range(n):
			acc += nrm[i]
		acc /= float(n)
		print("  mesh %-14s verts=%-7d mean normal (%.3f, %.3f, %.3f)" % [str(k), nrm.size(), acc.x, acc.y, acc.z])
	quit(0)
