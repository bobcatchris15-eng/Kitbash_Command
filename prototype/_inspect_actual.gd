extends SceneTree
# VISUAL polish 2026-08-23: load Battle.tscn, set up the test range
# rule set the way test_range_launcher does, wait for match_director to
# finish, and dump every material/texture on every ground-related mesh
# in the tree. This is the only way to see what's actually being rendered.

const TestRangeLauncherScript = preload("res://scripts/test_range_launcher.gd")
const MatchRuleSetScript = preload("res://scripts/match_rule_set.gd")
const MatchConfigScript = preload("res://scripts/match_config.gd")

func _init() -> void:
	# Set up MatchConfig the way test_range_launcher.gd does.
	var mc = MatchConfigScript.new()
	mc.name = "MatchConfig"
	get_root().add_child(mc)
	mc.selected_map_id = "test_range"
	var rule = MatchRuleSetScript.test_range(
		"res://data/loadout/bulwark_mbt.json",
		["res://data/loadout/bulwark_mbt.json",
		 "res://data/loadout/rattler_scout.json",
		 "res://data/loadout/dart_skirmisher.json"])
	mc.rule_set = rule

	# Load Battle.tscn
	var packed: PackedScene = load("res://scenes/Battle.tscn")
	if packed == null:
		print("FAIL: cannot load Battle.tscn")
		quit(1)
		return
	var battle = packed.instantiate()
	get_root().add_child(battle)

	# Let match_director's _ready and _setup_terrain coroutine run. The
	# probe earlier dumped at frame 3 and saw the pre-replacement
	# BoxMesh/StandardMaterial3D; the BattleLogger log said "match closed"
	# at frame 17, so wait long enough for _setup_terrain to complete.
	for i in range(30):
		await process_frame

	# Walk the tree. Find every MeshInstance3D whose name contains "Ground"
	# or whose parent is the Ground node, and dump their materials.
	print("=== Ground-related meshes ===")
	_dump_ground_meshes(battle)

	# Also dump the heightmap material's full slot map.
	print("\n=== Heightmap material slot dump ===")
	_dump_heightmap_slots(battle)

	# And dump the Battle.tscn Ground's MeshInstance3D material (which
	# match_director should have replaced with the heightmap material).
	print("\n=== Battle.tscn Ground's MeshInstance3D material ===")
	var ground: Node = battle.get_node_or_null("Ground")
	if ground == null:
		print("  no Ground node found in Battle.tscn")
	else:
		var mi: MeshInstance3D = ground.get_node_or_null("MeshInstance3D")
		if mi == null:
			print("  no MeshInstance3D under Ground")
		else:
			print("  mesh: ", mi.mesh.resource_path if mi.mesh else "(null)")
			print("  material_override: ", mi.material_override.resource_path if mi.material_override else "(null)")
			if mi.material_override is ShaderMaterial:
				var sm: ShaderMaterial = mi.material_override
				print("  shader: ", sm.shader.resource_path)
				for prop in sm.get_property_list():
					if prop.name.begins_with("shader_parameter/"):
						var v = sm.get(prop.name)
						if v is Texture:
							print("    ", prop.name.substr(17), " -> ", v.resource_path)
						elif v is Color:
							print("    ", prop.name.substr(17), " -> color ", v)

	quit(0)


func _dump_ground_meshes(root: Node) -> void:
	# Recursive walk.
	var stack: Array = [root]
	while not stack.is_empty():
		var n: Node = stack.pop_back()
		if n is MeshInstance3D:
			var mi: MeshInstance3D = n
			var p: Node = mi.get_parent()
			var is_ground: bool = (p and p.name == "Ground") or mi.name.contains("Ground")
			if is_ground:
				print("  MeshInstance3D '%s' (parent '%s')" % [mi.name, p.name if p else "?"])
				print("    mesh: ", mi.mesh.resource_path if mi.mesh else "(null)")
				var mat = mi.material_override if mi.material_override else mi.get_active_material(0)
				if mat:
					print("    material: ", mat.resource_path if mat.resource_path else mat.get_class())
					if mat is ShaderMaterial:
						var sm: ShaderMaterial = mat
						print("    shader: ", sm.shader.resource_path)
						for prop in sm.get_property_list():
							if prop.name.begins_with("shader_parameter/"):
								var v = sm.get(prop.name)
								if v is Texture:
									print("      ", prop.name.substr(17), " -> ", v.resource_path)
				else:
					print("    material: (none)")
		for c in n.get_children():
			stack.push_back(c)


func _dump_heightmap_slots(root: Node) -> void:
	# Find the ground's MeshInstance3D and dump all its shader params.
	var ground: Node = root.get_node_or_null("Ground")
	if ground == null: return
	var mi: MeshInstance3D = ground.get_node_or_null("MeshInstance3D")
	if mi == null: return
	var mat = mi.material_override
	if mat is ShaderMaterial:
		var sm: ShaderMaterial = mat
		for prop in sm.get_property_list():
			if prop.name.begins_with("shader_parameter/"):
				var v = sm.get(prop.name)
				if v != null:
					print("    ", prop.name.substr(17), " -> ", v)
