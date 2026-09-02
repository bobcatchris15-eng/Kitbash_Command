extends SceneTree
# Diagnostic: build one module at two tweak values and print the merged
# AABB plus every MeshInstance3D (mesh size, global scale, global pos) so we
# can see whether a tweak's effect is genuinely invisible or just buried
# under a dominant sibling. Run WITHOUT --quit:
#   godot --headless --path . --script res://tools/probe_tweak_vis.gd

const VisualBuilder = preload("res://scripts/visual_builder.gd")
const ModuleCatalogScript = preload("res://scripts/module_catalog.gd")

const CASES := [
	["helicopter_rotors", "blade_length", 1.0, 2.0],
	["screw_drive", "helix_depth", 1.0, 1.5],
	["spigot_mortar", "barrel_length", 1.0, 2.0],
	["spigot_mortar", "rod_thickness", 1.0, 1.8],
	["flak_cannon", "fuse_setting", 1.0, 2.0],
	["energy_barrier_projector", "coil_count", 4.0, 6.0],
	["buoyant_envelope", "prop_count", 2.0, 5.0],
]

func _init() -> void:
	for c in CASES:
		await _case(str(c[0]), str(c[1]), float(c[2]), float(c[3]))
	print("done")
	quit(0)


func _case(type_id: String, key: String, lo: float, hi: float) -> void:
	print("\n=== %s.%s  (%s -> %s) ===" % [type_id, key, lo, hi])
	for tag in ["LO", "HI"]:
		var value := lo if tag == "LO" else hi
		var catalog_data: Dictionary = ModuleCatalogScript.get_module_data(type_id)
		var chassis := Node3D.new()
		root.add_child(chassis)
		var container := Node3D.new()
		chassis.add_child(container)
		VisualBuilder.build_visual(type_id, container,
			catalog_data.get("size", Vector3.ONE),
			catalog_data.get("color", Color.WHITE), {key: value})
		await process_frame
		var total := AABB()
		var first := true
		var stack: Array = [container]
		while not stack.is_empty():
			var node: Node = stack.pop_back()
			if node is MeshInstance3D and node.mesh != null:
				var mi := node as MeshInstance3D
				var wa: AABB = mi.global_transform * mi.mesh.get_aabb()
				if first:
					total = wa
					first = false
				else:
					total = total.merge(wa)
				print("  [%s] %-40s mesh=%.3f,%.3f,%.3f scale=%s pos=%s" % [
					tag, str(mi.name).left(40),
					mi.mesh.get_aabb().size.x, mi.mesh.get_aabb().size.y, mi.mesh.get_aabb().size.z,
					mi.scale, Vector3(roundf(mi.global_position.x), roundf(mi.global_position.y), roundf(mi.global_position.z))])
			for child in node.get_children():
				stack.append(child)
		if first:
			print("  %s: NO MESHES" % tag)
		else:
			print("  %s TOT aabb pos=%s size=%s" % [tag,
				Vector3(roundf(total.position.x), roundf(total.position.y), roundf(total.position.z)),
				Vector3(roundf(total.size.x), roundf(total.size.y), roundf(total.size.z))])
		chassis.free()