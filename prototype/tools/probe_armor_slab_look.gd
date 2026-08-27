extends SceneTree
# Visual check for the armor slab pass: paints the hull's FRONT facets in
# thick composite (3.0x), LEFT flank in thin steel (0.75x), TOP in mid
# ceramic (1.5x), so the screenshot shows real plate standoff and the seam
# steps where type and thickness change across facet boundaries.
#
# Run WINDOWED (headless Godot's dummy renderer does not rasterize):
#   Godot_v4.7.1-stable_win64_console.exe --path . --script tools/probe_armor_slab_look.gd

const HullFacets = preload("res://scripts/hull_facets.gd")
const ArmorPaint = preload("res://scripts/armor_paint.gd")
const ArmorPaintVisual = preload("res://scripts/armor_paint_visual.gd")

const OUT_DIR := "user://armor_look"


func _init() -> void:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(OUT_DIR))
	root.size = Vector2i(900, 700)

	var placer := Node3D.new()
	placer.set_script(preload("res://scripts/module_placer.gd"))
	root.add_child(placer)
	await process_frame
	await process_frame

	placer._place_hull_from_ui("brenntal_medium_a")
	var hull: Node3D = placer.hull
	if hull == null:
		print("[FAIL] no hull"); quit(1); return
	await process_frame

	var mesh_inst: MeshInstance3D = null
	for c in hull.get_children():
		if c is MeshInstance3D and c.name != "PhysicsMesh":
			mesh_inst = c
			break
	if mesh_inst == null or mesh_inst.mesh == null:
		print("[FAIL] no hull mesh instance"); quit(1); return
	var mesh := mesh_inst.mesh

	var assignments := []
	for fid in HullFacets.facets_for_side_mesh(mesh, "front"):
		assignments.append({"facet_id": int(fid), "type_id": "composite_plate",
			"material": "composite_plate", "thickness": 3.0})
	for fid in HullFacets.facets_for_side_mesh(mesh, "left"):
		assignments.append({"facet_id": int(fid), "type_id": "steel_plate",
			"material": "steel_plate", "thickness": 0.75})
	for fid in HullFacets.facets_for_side_mesh(mesh, "top"):
		assignments.append({"facet_id": int(fid), "type_id": "ceramic_ablative",
			"material": "ceramic_ablative", "thickness": 1.5})
	print("[info] assignments: %d facets" % assignments.size())

	hull.set_meta("armor_assignments", assignments)
	hull.set_meta("armor_plan", ArmorPaint.build_plan("brenntal_medium_a",
		assignments, mesh, mesh_inst.transform, "player"))
	var built := ArmorPaintVisual.rebuild(hull, mesh_inst)
	print("[info] plates built: %d" % built)

	var light := DirectionalLight3D.new()
	light.rotation_degrees = Vector3(-38.0, 145.0, 0.0)
	light.light_energy = 1.5
	root.add_child(light)
	var light2 := DirectionalLight3D.new()
	light2.rotation_degrees = Vector3(-20.0, -60.0, 0.0)
	light2.light_energy = 0.6
	root.add_child(light2)

	var cam := Camera3D.new()
	root.add_child(cam)
	cam.current = true

	# Front-left-above: thick composite nose vs thin steel flank.
	cam.position = Vector3(4.6, 2.6, -6.4)
	cam.look_at(Vector3(0, 0.2, -2.0), Vector3.UP)
	for i in range(12):
		await process_frame
	root.get_texture().get_image().save_png("%s/slab_front_left.png" % OUT_DIR)
	print("saved slab_front_left")

	# Dead-above: ceramic deck tiles next to the composite glacis.
	cam.position = Vector3(0.2, 7.5, -1.2)
	cam.look_at(Vector3(0, 0.0, -0.6), Vector3.UP)
	for i in range(12):
		await process_frame
	root.get_texture().get_image().save_png("%s/slab_top.png" % OUT_DIR)
	print("saved slab_top")

	# Close on the nose seam, low angle so the plate edge is in profile.
	cam.position = Vector3(2.2, 1.0, -5.2)
	cam.look_at(Vector3(0.0, 0.35, -2.9), Vector3.UP)
	for i in range(12):
		await process_frame
	root.get_texture().get_image().save_png("%s/slab_seam.png" % OUT_DIR)
	print("saved slab_seam")

	print("output dir: ", ProjectSettings.globalize_path(OUT_DIR))
	quit(0)
