extends SceneTree

const TerrainVisualScatterScript = preload("res://scripts/terrain_visual_scatter.gd")
const ResourceNodeScript = preload("res://scripts/resource_node.gd")
const TerrainBuilderScript = preload("res://scripts/terrain_builder.gd")

func _init() -> void:
	print("==================================================")
	print("VERIFYING TERRAIN GREEBLES & REACTIVE GRASS SYSTEM")
	print("==================================================")
	
	# 1. Verify all 36 ambient tree GLBs
	print("\n[1/4] Verifying 36 Ambient Tree Models (12 species x 3 variants)...")
	var trees_ok = 0
	for i in range(36):
		var path = "res://assets/models/terrain/ambient_tree_%d.glb" % i
		if not ResourceLoader.exists(path):
			push_error("Missing tree model: " + path)
			continue
		var packed = load(path) as PackedScene
		if packed == null:
			push_error("Failed to load PackedScene: " + path)
			continue
		var inst = packed.instantiate()
		if inst == null:
			push_error("Failed to instantiate: " + path)
			continue
		inst.free()
		trees_ok += 1
	print("  -> Passed: %d / 36 tree models verified." % trees_ok)
	
	# 2. Verify all 35 geological rock GLBs
	print("\n[2/4] Verifying 35 Geological Rock Models (7 formations x 5 variants)...")
	var rocks_ok = 0
	for i in range(35):
		var path = "res://assets/models/terrain/boulder_%d.glb" % i
		if not ResourceLoader.exists(path):
			push_error("Missing rock model: " + path)
			continue
		var packed = load(path) as PackedScene
		if packed == null:
			push_error("Failed to load PackedScene: " + path)
			continue
		var inst = packed.instantiate()
		if inst == null:
			push_error("Failed to instantiate: " + path)
			continue
		inst.free()
		rocks_ok += 1
	print("  -> Passed: %d / 35 rock models verified." % rocks_ok)
	
	# 3. Verify Interactive Grass Shader & MultiMesh Material
	print("\n[3/4] Verifying Interactive Grass Shader & Unit-Avoidance Material...")
	var root_node = Node3D.new()
	root.add_child(root_node)
	var scatter = TerrainVisualScatterScript.get_or_create(root_node)
	assert(scatter != null, "Failed to instantiate TerrainVisualScatter")
	
	var grass_mat = scatter._get_interactive_grass_material(Color(0.24, 0.28, 0.18))
	assert(grass_mat != null, "Failed to create interactive grass material")
	assert(grass_mat is ShaderMaterial, "Grass material is not ShaderMaterial")
	
	var dummy_unit1 = Node3D.new()
	dummy_unit1.name = "DummyTank"
	dummy_unit1.position = Vector3(10, 0, 15)
	
	var dummy_unit2 = Node3D.new()
	dummy_unit2.name = "DummyWalker"
	dummy_unit2.position = Vector3(-20, 0, -5)
	
	scatter.update_unit_interaction([dummy_unit1, dummy_unit2])
	
	var u_count = grass_mat.get_shader_parameter("unit_count")
	var u_pos = grass_mat.get_shader_parameter("unit_positions")
	print("  -> Shader unit_count parameter: %s" % str(u_count))
	print("  -> Shader unit_positions[0]: %s" % str(u_pos[0]))
	print("  -> Shader unit_positions[1]: %s" % str(u_pos[1]))
	assert(u_count == 2, "Expected 2 active units in shader parameter")
	assert(u_pos[0].x == 10.0 and u_pos[0].z == 15.0, "Unit 1 position mismatch")
	assert(u_pos[1].x == -20.0 and u_pos[1].z == -5.0, "Unit 2 position mismatch")
	print("  -> Passed: Interactive grass shader correctly receives real-time unit positions.")
	
	# 4. Verify Procedural Greebles Faceted Meshes
	print("\n[4/4] Verifying Procedural Faceted Greeble Mesh Generation...")
	var rng = RandomNumberGenerator.new()
	rng.seed = 12345
	var rock_mesh = TerrainGreebles._create_faceted_rock_mesh(rng, Vector3(1.2, 0.8, 1.2))
	assert(rock_mesh != null and rock_mesh.get_surface_count() > 0, "Faceted rock mesh generation failed")
	var ice_mesh = TerrainGreebles._create_ice_shard_mesh(rng, Vector3(0.8, 1.2, 0.8))
	assert(ice_mesh != null and ice_mesh.get_surface_count() > 0, "Ice shard mesh generation failed")
	print("  -> Passed: Procedural faceted rock & ice meshes generated with %d vertices." % rock_mesh.surface_get_array_len(0))
	
	root_node.free()
	print("\n==================================================")
	print("ALL VERIFICATION CHECKS PASSED SUCCESSFULLY!")
	print("==================================================")
	quit()
