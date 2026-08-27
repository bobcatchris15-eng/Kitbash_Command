extends SceneTree

const TerrainBuilderScript = preload("res://scripts/terrain_builder.gd")
const MapCatalogScript = preload("res://scripts/map_catalog.gd")

func _init():
	var map_def = MapCatalogScript.get_map("scattered_peaks")
	print("==========================================================")
	print("PROBING SCATTERED PEAKS MAP (half=%s)" % str(map_def.get("map_half_extents", 550.0)))
	print("==========================================================")
	
	var parent = Node3D.new()
	root.add_child(parent)
	
	var t0 = Time.get_ticks_msec()
	await TerrainBuilderScript.spawn_visuals(map_def, parent)
	var total_ms = Time.get_ticks_msec() - t0
	
	print("Scattered Peaks spawn_visuals total time: %d ms" % total_ms)
	
	# Count children and multimeshes created
	var mm_count = 0
	var total_instances = 0
	for c in parent.get_children():
		if c is MultiMeshInstance3D and c.multimesh != null:
			mm_count += 1
			total_instances += c.multimesh.instance_count
			print("Batch: '%s' (instances=%d, mesh=%s)" % [c.name, c.multimesh.instance_count, c.multimesh.mesh])
		for gc in c.get_children():
			if gc is MultiMeshInstance3D and gc.multimesh != null:
				mm_count += 1
				total_instances += gc.multimesh.instance_count
				print("SubBatch: '%s' (instances=%d)" % [gc.name, gc.multimesh.instance_count])
				
	print("Total MultiMesh Batches: %d, Total Rendered Instances: %d" % [mm_count, total_instances])
	print("==========================================================")
	parent.free()
	quit()
