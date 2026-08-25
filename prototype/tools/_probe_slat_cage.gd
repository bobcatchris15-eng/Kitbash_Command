extends SceneTree
# Renders one hull flank painted with each armor material in turn, so the
# RELIEF signatures can be compared by eye. Materials are meant to be told apart
# without colour (livery repaints everything), so this is the only test that
# actually checks the thing that matters.
#
# WINDOWED, not headless: the headless dummy renderer does not rasterize, so a
# headless run writes blank images that agree with themselves.
#
# Run: Godot_v4.7.1-stable_win64.exe --path . --script res://tools/probe_armor_materials.gd

const MeshAssetLoader = preload("res://scripts/mesh_asset_loader.gd")
const HullFacets = preload("res://scripts/hull_facets.gd")
const ArmorPaint = preload("res://scripts/armor_paint.gd")
const ArmorPaintVisual = preload("res://scripts/armor_paint_visual.gd")

const HullMaterialBuilder = preload("res://scripts/hull_material_builder.gd")

const HULL := "brenntal_medium_a"
const SIDE := "left"
const OUT_DIR := "user://slat_cage_probe"
const MATERIALS := ["reactive_armor"]
const VIEWS := [
	Vector3(-0.90, 0.22, 0.10),
	Vector3(-0.55, 0.55, -0.55),
	Vector3(-0.30, 0.12, 0.85),
]


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
	e.ambient_light_color = Color(0.6, 0.62, 0.6)
	e.ambient_light_energy = 0.55
	env.environment = e
	world.add_child(env)

	var table := HullFacets.cached_segment(mesh)
	var normals: PackedVector3Array = table.get("normal", PackedVector3Array())
	var centroids: PackedVector3Array = table.get("centroid", PackedVector3Array())
	var areas: PackedFloat32Array = table.get("area", PackedFloat32Array())

	for material in MATERIALS:
		var hull := Node3D.new()
		world.add_child(hull)
		var mi := MeshInstance3D.new()
		mi.mesh = mesh
		HullMaterialBuilder.apply_hull_materials(mi, "nato_bronzegreen")
		hull.add_child(mi)

		var rows := []
		for f in ArmorPaint.facets_for_side(HULL, SIDE, mesh):
			rows.append({
				"facet_id": int(f), "side": SIDE,
				"type_id": "slat_armor", "material": material, "thickness": 1.0,
				"normal": {"x": normals[f].x, "y": normals[f].y, "z": normals[f].z},
				"centroid": {"x": centroids[f].x, "y": centroids[f].y, "z": centroids[f].z},
				"area": float(areas[f]),
			})
		hull.set_meta("armor_plan", ArmorPaint.build_plan(HULL, rows, mesh, Transform3D.IDENTITY, "nato_bronzegreen"))
		var built := ArmorPaintVisual.rebuild(hull, mi)
		print("rows=", rows.size())

		var tris := 0
		var holder = hull.get_node_or_null(ArmorPaintVisual.HOLDER_NAME)
		if holder:
			for c in holder.get_children():
				if c is MeshInstance3D and c.mesh:
					tris += c.mesh.get_faces().size() / 3

		for vi in range(VIEWS.size()):
			cam.position = aabb.get_center() + (VIEWS[vi] as Vector3) * d
			cam.look_at_from_position(cam.position, aabb.get_center(), Vector3.UP)
			for i in range(6):
				await process_frame
			var img := root.get_texture().get_image()
			var path := "%s/%s_view%d.png" % [OUT_DIR, material, vi]
			img.save_png(ProjectSettings.globalize_path(path))
			print("%-18s view%d  %d skins, %5d tris -> %s" % [material, vi, built, tris, path])

		world.remove_child(hull)
		hull.queue_free()
		await process_frame

	print("Wrote to ", ProjectSettings.globalize_path(OUT_DIR))
	quit(0)
