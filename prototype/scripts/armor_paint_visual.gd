# ArmorPaintVisual: turns an armor plan into the skins you can see on a hull.
#
# In the Design Lab: renders the unpainted scale model plastic finish (grey-green)
# with the armor's physical tactile normal relief applied.
# In Match / Battle: seamlessly inherits the underlying hull's livery (zones,
# camouflage/patterns, textures, and weathering) with the armor normals on top.

const HullFacets = preload("res://scripts/hull_facets.gd")
const ModuleCatalog = preload("res://scripts/module_catalog.gd")
const PartMaterials = preload("res://scripts/part_materials.gd")
const LiveryScript = preload("res://scripts/livery.gd")
const HullMaterialBuilder = preload("res://scripts/hull_material_builder.gd")
const VisualTuning = preload("res://scripts/visual_tuning.gd")

const HOLDER_NAME := "ArmorPaint"

# Per-material surface signature. `pattern` selects the shader branch, `cell`
# is the feature size IN METRES (UVs are metres of facet surface), `relief` how
# hard the normal is pushed, `seam` the groove width as a fraction of a cell.
const MATERIAL_FINISH := {
	"steel_plate": {"metallic": 0.65, "roughness": 0.45, "pattern": 0, "cell": 0.50, "relief": 0.15, "seam": 0.06},
	"composite_plate": {"metallic": 0.40, "roughness": 0.50, "pattern": 1, "cell": 0.45, "relief": 0.75, "seam": 0.05},
	"ceramic_ablative": {"metallic": 0.05, "roughness": 0.85, "pattern": 2, "cell": 0.22, "relief": 0.50, "seam": 0.10},
	"ballistic_nylon": {"metallic": 0.25, "roughness": 0.45, "pattern": 3, "cell": 0.07, "relief": 0.35, "seam": 0.06},
	# Backward-compatibility aliases
	"hardened_steel": {"metallic": 0.65, "roughness": 0.45, "pattern": 0, "cell": 0.50, "relief": 0.15, "seam": 0.06},
	"armor_plating": {"metallic": 0.65, "roughness": 0.45, "pattern": 0, "cell": 0.50, "relief": 0.15, "seam": 0.06},
	"reactive_armor": {"metallic": 0.40, "roughness": 0.50, "pattern": 1, "cell": 0.45, "relief": 0.75, "seam": 0.05},
	"spaced_composite": {"metallic": 0.40, "roughness": 0.50, "pattern": 1, "cell": 0.45, "relief": 0.75, "seam": 0.05},
	"ablative_ceramic": {"metallic": 0.05, "roughness": 0.85, "pattern": 2, "cell": 0.22, "relief": 0.50, "seam": 0.10},
	"ablative_foam": {"metallic": 0.05, "roughness": 0.85, "pattern": 2, "cell": 0.22, "relief": 0.50, "seam": 0.10},
	"carbon_fiber": {"metallic": 0.25, "roughness": 0.45, "pattern": 3, "cell": 0.07, "relief": 0.35, "seam": 0.06},
	"titanium_plate": {"metallic": 0.80, "roughness": 0.38, "pattern": 0, "cell": 0.85, "relief": 0.25, "seam": 0.035},
	"slat_armor": {"metallic": 0.65, "roughness": 0.45, "pattern": 0, "cell": 0.50, "relief": 0.15, "seam": 0.06},
}

const ARMOR_SHADER = preload("res://shaders/armor_surface.gdshader")


# Rebuilds every painted skin on `hull` from its `armor_plan` meta.
# `mesh_inst` is the hull's own MeshInstance3D - the same one the surface body
# traces, so the skin sits on the surface that is actually drawn.
static func rebuild(hull: Node3D, mesh_inst: MeshInstance3D) -> int:
	if not is_instance_valid(hull):
		return 0
	clear(hull)
	clear_material_cache()
	if mesh_inst == null or mesh_inst.mesh == null:
		return 0

	var plan: Dictionary = hull.get_meta("armor_plan", {})
	if plan.is_empty() or bool(plan.get("empty", true)):
		return 0
	var hull_type := str(plan.get("hull_type", ""))
	var facets: Dictionary = plan.get("facets", {})
	if facets.is_empty():
		return 0

	var holder := Node3D.new()
	holder.name = HOLDER_NAME
	hull.add_child(holder)

	var faction := str(plan.get("faction", LiveryScript.PLAYER_ID))
	if faction == "" or faction == LiveryScript.NO_LIVERY:
		faction = LiveryScript.PLAYER_ID

	# Detect whether the hull is in Design Lab / scale model mode (grey-green plastic)
	var is_scale_model := false
	if plan.get("is_designer", false):
		is_scale_model = true
	elif mesh_inst != null:
		var mat: Material = mesh_inst.material_override
		if mat == null and mesh_inst.mesh != null and mesh_inst.mesh.get_surface_count() > 0:
			mat = mesh_inst.get_surface_override_material(0)
			if mat == null:
				mat = mesh_inst.get_active_material(0)
		if mat is StandardMaterial3D:
			is_scale_model = true

	var texture_world_size := HullMaterialBuilder._DEFAULT_TEXTURE_WORLD_SIZE
	var bounds_y := Vector2(-0.5, 0.5)
	var bounds_x := Vector2(-0.5, 0.5)
	var bounds_z := Vector2(-0.5, 0.5)
	if mesh_inst.mesh:
		var aabb = mesh_inst.mesh.get_aabb()
		var extents = aabb.size * mesh_inst.scale
		texture_world_size = (extents.x + extents.y + extents.z) / 3.0
		bounds_y = Vector2(aabb.position.y, aabb.position.y + aabb.size.y)
		bounds_x = Vector2(aabb.position.x, aabb.position.x + aabb.size.x)
		bounds_z = Vector2(aabb.position.z, aabb.position.z + aabb.size.z)

	var built := 0
	for fid in facets.keys():
		var entry: Dictionary = facets[fid]
		var type_id := str(entry.get("type_id", "steel_plate"))
		var material_id := str(entry.get("material", type_id))
		var thickness := float(entry.get("thickness", 1.0))
		var frame := HullFacets.facet_frame(hull_type, int(fid), mesh_inst.transform, mesh_inst.mesh)
		if not bool(frame.get("valid", false)):
			continue
		var cat: Dictionary = ModuleCatalog.get_module_data(type_id)
		var mesh := HullFacets.build_plate(mesh_inst, hull_type, int(fid), type_id,
			cat.get("size", Vector3.ONE), frame["center"], frame["basis"],
			material_id, thickness)
		if mesh == null:
			continue

		var inst := MeshInstance3D.new()
		inst.name = "Armor_%d" % int(fid)
		inst.mesh = mesh
		inst.transform = Transform3D(frame["basis"], frame["center"])

		inst.material_override = _armor_material(material_id, is_scale_model, faction,
			bounds_y, bounds_x, bounds_z, mesh_inst.scale, texture_world_size, inst.transform, thickness)
		inst.set_meta("armor_facet_id", int(fid))
		holder.add_child(inst)
		built += 1
	return built


static func _armor_material(material_id: String, is_scale_model: bool, faction: String,
		bounds_y: Vector2, bounds_x: Vector2, bounds_z: Vector2,
		mesh_scale: Vector3, texture_world_size: float,
		facet_xf: Transform3D, thickness: float = 1.0) -> ShaderMaterial:
	var f: Dictionary = MATERIAL_FINISH.get(material_id, MATERIAL_FINISH["steel_plate"])
	var mat := ShaderMaterial.new()
	mat.shader = ARMOR_SHADER
	mat.set_shader_parameter("scale_model_mode", 1.0 if is_scale_model else 0.0)
	mat.set_shader_parameter("scale_model_color", HullMaterialBuilder.SCALE_MODEL_ALBEDO)
	mat.set_shader_parameter("texture_scale", HullMaterialBuilder._texture_scale_for_size(texture_world_size))
	mat.set_shader_parameter("mesh_scale", mesh_scale)
	mat.set_shader_parameter("shield_mode", 0.0)
	mat.set_shader_parameter("alpha_base", 1.0)

	var textures = HullMaterialBuilder._get_surface_textures()
	mat.set_shader_parameter("albedo_tex", textures.albedo)
	mat.set_shader_parameter("normal_tex", textures.normal)
	mat.set_shader_parameter("roughness_tex", textures.roughness)

	HullMaterialBuilder.apply_livery_zones(mat, faction)
	HullMaterialBuilder.apply_local_bounds(mat, bounds_y, bounds_x, bounds_z)
	VisualTuning.apply(mat)

	mat.set_shader_parameter("facet_to_hull", facet_xf)
	mat.set_shader_parameter("pattern_id", int(f["pattern"]))
	mat.set_shader_parameter("cell", float(f["cell"]))
	mat.set_shader_parameter("relief", float(f["relief"]))
	mat.set_shader_parameter("seam", float(f["seam"]))
	mat.set_shader_parameter("thickness", float(thickness))
	mat.set_shader_parameter("armor_metallic", float(f["metallic"]))
	mat.set_shader_parameter("armor_roughness", float(f["roughness"]))
	return mat


static func clear_material_cache() -> void:
	pass


static func clear(hull: Node3D) -> void:
	if not is_instance_valid(hull):
		return
	var existing = hull.get_node_or_null(HOLDER_NAME)
	if existing:
		hull.remove_child(existing)
		existing.queue_free()
