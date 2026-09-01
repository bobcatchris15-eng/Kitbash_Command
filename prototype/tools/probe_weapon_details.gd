@tool
extends SceneTree

const ModuleCatalog = preload("res://scripts/module_catalog.gd")
const VisualBuilder = preload("res://scripts/visual_builder.gd")

func _init() -> void:
	print("=== WEAPON VISUAL DETAILS ===")
	var root = Node3D.new()
	get_root().add_child(root)

	var weapon_ids := [
		"basic_cannon", "heavy_machine_gun", "rotary_cannon", "gauss_railgun",
		"artillery", "mortar_array", "flamethrower", "ion_cannon", "heavy_laser",
		"plasma_lobber", "ciws", "flak_cannon", "pd_laser", "mk19_grenade_launcher",
		"autocannon", "anti_materiel_rifle", "recoilless_rifle", "coil_gun",
		"spigot_mortar", "arc_projector", "microwave_emitter", "particle_lance",
		"aa_autocannon", "napalm_mortar", "rocket_artillery", "hypervelocity_missile",
		"sam_launcher", "guided_missile", "missile_pod", "cluster_dispenser",
		"loitering_munition", "anti_radiation_missile", "bunker_buster", "cruise_missile",
		"smoke_discharger", "mine_layer"
	]

	for tid in weapon_ids:
		var node = Node3D.new()
		root.add_child(node)
		var mdata = ModuleCatalog.get_module_data(tid)
		var size: Vector3 = mdata.get("size", Vector3.ONE)
		VisualBuilder.build_visual(tid, node, size, Color.WHITE, {})
		
		# Find the forward-most muzzle point in weapon local coordinates
		var min_z := 0.0
		var best_pt := Vector3.ZERO
		var meshes := []
		_collect_meshes(node, Transform3D.IDENTITY, meshes)
		
		for m in meshes:
			var t: Transform3D = m["transform"]
			var mi: MeshInstance3D = m["node"]
			if mi.mesh:
				var aabb: AABB = mi.mesh.get_aabb()
				for cx in [aabb.position.x, aabb.position.x + aabb.size.x]:
					for cy in [aabb.position.y, aabb.position.y + aabb.size.y]:
						for cz in [aabb.position.z, aabb.position.z + aabb.size.z]:
							var pt = t * Vector3(cx, cy, cz)
							if pt.z < min_z:
								min_z = pt.z
								best_pt = pt
		
		var cat_offset = ModuleCatalog.get_muzzle_offset(tid)
		# Find center of the forward face
		var front_center = Vector3(0.0, best_pt.y, min_z)
		print("{\"%s\", Vector3(0.0, %.2f, %.2f)}, // was %s" % [
			tid, best_pt.y, min_z, str(cat_offset)
		])
		
		node.queue_free()

	root.queue_free()
	quit(0)

func _collect_meshes(node: Node3D, current_transform: Transform3D, out: Array) -> void:
	for child in node.get_children():
		if child is Node3D:
			var next_transform = current_transform * child.transform
			if child is MeshInstance3D:
				out.append({"node": child, "transform": next_transform})
			_collect_meshes(child, next_transform, out)
