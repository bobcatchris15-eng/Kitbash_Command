@tool
extends SceneTree

const ModuleCatalog = preload("res://scripts/module_catalog.gd")
const VisualBuilder = preload("res://scripts/visual_builder.gd")

func _init() -> void:
	print("--- WEAPON MUZZLE ALIGNMENT PROBE ---")
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
		
		var min_z := 0.0
		var min_z_y := 0.0
		var mesh_count := 0
		
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
								min_z_y = pt.y
				mesh_count += 1
		
		var catalog_offset = ModuleCatalog.get_muzzle_offset(tid)
		print("Weapon: %-24s | Visual min_z: %6.2f (y=%5.2f) | MuzzleOffset: %-24s | Diff Z: %5.2f" % [
			tid, min_z, min_z_y, str(catalog_offset), absf(catalog_offset.z - min_z)
		])
		
		node.queue_free()

	root.queue_free()
	print("--- PROBE DONE ---")
	quit(0)

func _collect_meshes(node: Node3D, current_transform: Transform3D, out: Array) -> void:
	for child in node.get_children():
		if child is Node3D:
			var next_transform = current_transform * child.transform
			if child is MeshInstance3D:
				out.append({"node": child, "transform": next_transform})
			_collect_meshes(child, next_transform, out)
