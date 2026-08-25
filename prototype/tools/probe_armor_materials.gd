extends SceneTree
# Renders one hull flank painted with each armor material in turn, so the
# RELIEF signatures can be compared by eye.

const MeshAssetLoader = preload("res://scripts/mesh_asset_loader.gd")
const HullFacets = preload("res://scripts/hull_facets.gd")
const ArmorPaint = preload("res://scripts/armor_paint.gd")
const ArmorPaintVisual = preload("res://scripts/armor_paint_visual.gd")
const HullMaterialBuilder = preload("res://scripts/hull_material_builder.gd")

const HULL := "brenntal_medium_a"
const SIDE := "left"
const OUT_DIR := "user://armor_materials"
const MATERIALS := ["steel_plate", "composite_plate", "ceramic_ablative", "ballistic_nylon"]


func _init() -> void:
	await process_frame
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(OUT_DIR))

	var mesh: Mesh = MeshAssetLoader.get_hull_mesh(HULL)
	if mesh == null:
		print("[FAIL] no mesh for ", HULL)
		quit(1)
		return

	var world := Node3D.new()
	root.add_child(world)

	var cam := Camera3D.new()
	var aabb := mesh.get_aabb()
	var d: float = aabb.size.length() * 0.95
	cam.position = aabb.get_center() + Vector3(-d * 0.90, d * 0.22, d * 0.10)
	cam.look_at_from_position(cam.position, aabb.get_center(), Vector3.UP)
	world.add_child(cam)

	var key := DirectionalLight3D.new()
	key.rotation_degrees = Vector3(-18.0, 62.0, 0.0)
	key.light_energy = 1.5
	world.add_child(key)
	var fill := DirectionalLight3D.new()
	fill.rotation_degrees = Vector3(-40.0, -120.0, 0.0)
	fill.light_energy = 0.25
	world.add_child(fill)

	var env := WorldEnvironment.new()
	var e := Environment.new()
	e.background_mode = Environment.BG_COLOR
	e.background_color = Color(0.05, 0.05, 0.06)
	e.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	e.ambient_light_color = Color(0.35, 0.35, 0.38)
	e.ambient_light_energy = 0.4
	e.tonemap_mode = Environment.TONE_MAPPER_FILMIC
	env.environment = e
	world.add_child(env)

	var table := HullFacets.cached_segment(mesh)
	var normals: PackedVector3Array = table.get("normal", PackedVector3Array())
	var centroids: PackedVector3Array = table.get("centroid", PackedVector3Array())
	var areas: PackedFloat32Array = table.get("area", PackedFloat32Array())

	for material in MATERIALS:
		for thick in [1.0, 2.5]:
			var thick_suffix := "" if thick == 1.0 else ("_thick%.1f" % thick)

			# 1. DESIGN LAB (Scale model finish)
			var hull_lab := Node3D.new()
			world.add_child(hull_lab)
			var mi_lab := MeshInstance3D.new()
			mi_lab.mesh = mesh
			HullMaterialBuilder.apply_scale_model_finish(mi_lab)
			hull_lab.add_child(mi_lab)

			var rows := []
			for f in ArmorPaint.facets_for_side(HULL, SIDE, mesh):
				rows.append({
					"facet_id": int(f), "side": SIDE,
					"type_id": material, "material": material, "thickness": thick,
					"normal": {"x": normals[f].x, "y": normals[f].y, "z": normals[f].z},
					"centroid": {"x": centroids[f].x, "y": centroids[f].y, "z": centroids[f].z},
					"area": float(areas[f]),
				})
			hull_lab.set_meta("armor_plan", ArmorPaint.build_plan(HULL, rows, mesh, Transform3D.IDENTITY, ""))
			var built_lab := ArmorPaintVisual.rebuild(hull_lab, mi_lab)

			for i in range(6):
				await process_frame
			var img_lab := root.get_texture().get_image()
			var path_lab := "%s/lab_%s%s.png" % [OUT_DIR, material, thick_suffix]
			img_lab.save_png(ProjectSettings.globalize_path(path_lab))
			print("LAB:   %-18s (thick %.1fx) %d skins -> %s" % [material, thick, built_lab, path_lab])

			world.remove_child(hull_lab)
			hull_lab.queue_free()
			await process_frame

			# 2. MATCH / BATTLE (Livery finish)
			var hull_match := Node3D.new()
			world.add_child(hull_match)
			var mi_match := MeshInstance3D.new()
			mi_match.mesh = mesh
			HullMaterialBuilder.apply_hull_materials(mi_match, "nato_bronzegreen")
			hull_match.add_child(mi_match)

			hull_match.set_meta("armor_plan", ArmorPaint.build_plan(HULL, rows, mesh, Transform3D.IDENTITY, "nato_bronzegreen"))
			var built_match := ArmorPaintVisual.rebuild(hull_match, mi_match)

			for i in range(6):
				await process_frame
			var img_match := root.get_texture().get_image()
			var path_match := "%s/match_%s%s.png" % [OUT_DIR, material, thick_suffix]
			img_match.save_png(ProjectSettings.globalize_path(path_match))
			print("MATCH: %-18s (thick %.1fx) %d skins -> %s" % [material, thick, built_match, path_match])

			world.remove_child(hull_match)
			hull_match.queue_free()
			await process_frame

	print("Wrote to ", ProjectSettings.globalize_path(OUT_DIR))
	quit(0)
