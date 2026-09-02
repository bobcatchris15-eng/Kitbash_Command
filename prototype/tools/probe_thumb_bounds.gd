extends SceneTree
# DIAGNOSTIC ONLY. Measures the same merged_aabb() blueprint_thumbnail.gd and
# part_thumbnail.gd use to frame their cameras, for every default-roster
# blueprint and a spread of catalog parts, and names the single child node
# that most inflates each subject's bounds. No production file is touched or
# imported for its side effects beyond preload.

const BlueprintManagerScript = preload("res://scripts/blueprint_manager.gd")
const ModuleCatalog = preload("res://scripts/module_catalog.gd")
const VisualBuilder = preload("res://scripts/visual_builder.gd")
const BlueprintThumbnail = preload("res://scripts/blueprint_thumbnail.gd")

const PART_IDS := [
	"plasma_thruster", "anti_grav_plate", "wheels", "air_cushion_skirt",
	"tracked_treads", "basic_cannon", "railgun", "sensor_mast",
]

var _holder: Node3D = null


func _initialize() -> void:
	_holder = Node3D.new()
	get_root().add_child(_holder)

	var results: Array = []

	# --- Default roster blueprints ---
	var dir := DirAccess.open("res://assets/blueprints/default_roster")
	if dir:
		dir.list_dir_begin()
		var fname := dir.get_next()
		while fname != "":
			if not dir.current_is_dir() and fname.ends_with(".json"):
				var path := "res://assets/blueprints/default_roster/" + fname
				var data := _load_json(path)
				if not data.is_empty():
					var bp := BlueprintManagerScript.new()
					_holder.add_child(bp)
					var model: Node3D = bp.reconstruct_vehicle(data, _holder, true)
					bp.queue_free()
					if model != null:
						var name_str: String = str(data.get("name", fname))
						results.append(_measure(name_str, model))
						model.queue_free()
			fname = dir.get_next()
		dir.list_dir_end()

	# --- Representative catalog parts ---
	for type_id in PART_IDS:
		if not ModuleCatalog.module_exists(type_id):
			print("PART MISSING FROM CATALOG: %s" % type_id)
			continue
		var catalog_data: Dictionary = ModuleCatalog.get_module_data(type_id)
		var model := Node3D.new()
		_holder.add_child(model)
		if String(catalog_data.get("category", "")) != "hull":
			VisualBuilder.build_visual(type_id, model, catalog_data.get("size", Vector3.ONE),
				catalog_data.get("color", Color.WHITE), {})
		if model.get_child_count() > 0:
			results.append(_measure(str(catalog_data.get("name", type_id)), model))
		model.queue_free()

	# --- Print per-subject lines ---
	print("=== PER-SUBJECT MEASUREMENTS ===")
	for r in results:
		print("%s | extent=%.3f | aabb_size=%s | aabb_pos=%s | node_count=%d | widest_contributor=%s" % [
			r.name, r.extent, _v3(r.aabb_size), _v3(r.aabb_pos), r.node_count, r.widest
		])

	# --- Summary: outliers > 2x roster median extent ---
	var extents: Array = []
	for r in results:
		extents.append(r.extent)
	extents.sort()
	var median: float = 0.0
	if extents.size() > 0:
		var mid := extents.size() / 2
		median = extents[mid] if extents.size() % 2 == 1 else (extents[mid - 1] + extents[mid]) * 0.5

	print("\n=== SUMMARY (roster median extent = %.3f) ===" % median)
	var any_outlier := false
	for r in results:
		if median > 0.0 and r.extent > median * 2.0:
			any_outlier = true
			print("OUTLIER: %s | extent=%.3f (%.1fx median) | widest_contributor=%s" % [
				r.name, r.extent, r.extent / median, r.widest
			])
	if not any_outlier:
		print("No outliers found (nothing > 2x median extent).")

	quit()


func _load_json(path: String) -> Dictionary:
	if not FileAccess.file_exists(path):
		return {}
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return {}
	var parsed = JSON.parse_string(f.get_as_text())
	f.close()
	return parsed if parsed is Dictionary else {}


func _v3(v: Vector3) -> String:
	return "%.2f,%.2f,%.2f" % [v.x, v.y, v.z]


# Measures via the real shared helper, BlueprintThumbnail.merged_aabb(), so
# this probe proves the actual framing behavior rather than a stale replica of
# it. Widest-contributor tracking walks the same tree but applies the same
# exclusion filter as merged_aabb() (skip Light3D / GPUParticles3D /
# CPUParticles3D) so it never names a node the shared helper wouldn't count.
func _measure(subject_name: String, model: Node3D) -> Dictionary:
	var out: AABB = BlueprintThumbnail.merged_aabb(model, Transform3D.IDENTITY)
	var has_any: bool = out.size != Vector3.ZERO

	var node_count := 0
	var widest_name := "<none>"
	var widest_extent := -1.0

	var stack: Array = [[model, Transform3D.IDENTITY]]
	while stack.size() > 0:
		var top: Array = stack.pop_back()
		var node: Node = top[0]
		var xform: Transform3D = top[1]
		node_count += 1

		var local := xform
		if node is Node3D:
			local = xform * (node as Node3D).transform

		if node is VisualInstance3D and not (node is Light3D) and not (node is GPUParticles3D) and not (node is CPUParticles3D):
			var vi := node as VisualInstance3D
			var box: AABB = vi.get_aabb()
			if box.size != Vector3.ZERO:
				var world_box: AABB = local * box
				var this_extent: float = world_box.size.length()
				if this_extent > widest_extent:
					widest_extent = this_extent
					widest_name = "%s (%s)" % [node.name, node.get_class()]

		for child in node.get_children():
			stack.append([child, local])

	return {
		"name": subject_name,
		"extent": out.size.length() if has_any else 0.0,
		"aabb_size": out.size if has_any else Vector3.ZERO,
		"aabb_pos": out.position if has_any else Vector3.ZERO,
		"node_count": node_count,
		"widest": widest_name,
	}
