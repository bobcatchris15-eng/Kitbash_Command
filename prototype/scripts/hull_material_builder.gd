extends RefCounted
class_name HullMaterialBuilder
# Shared hull material construction - parameterized ShaderMaterial/shader for every
# faction and armor material, supporting 3 zones, 13 procedural patterns, tactile micro-surfaces,
# and service weathering.

const LiveryScript = preload("res://scripts/livery.gd")
const HULL_SHADER = preload("res://shaders/hull_faction_material.gdshader")
const VisualTuningScript = preload("res://scripts/visual_tuning.gd")

const ARMOR_PBR = {
	"hardened_steel": {"metallic": 0.65, "roughness": 0.42, "shield_mode": 0.0, "alpha": 1.0},
	"reactive_armor": {"metallic": 0.1, "roughness": 0.7, "shield_mode": 0.0, "alpha": 1.0},
	"ablative_ceramic": {"metallic": 0.0, "roughness": 0.5, "shield_mode": 0.0, "alpha": 1.0},
	"energy_shielding": {"metallic": 0.1, "roughness": 0.1, "shield_mode": 1.0, "alpha": 0.94},
}

const TEXTURE_DIR = "res://assets/textures/hull/"
static var _texture_cache: Dictionary = {}

static func _get_surface_textures() -> Dictionary:
	if not _texture_cache.is_empty():
		return _texture_cache
	_texture_cache = {
		"albedo": load(TEXTURE_DIR + "hull_surface_albedo.png"),
		"normal": load(TEXTURE_DIR + "hull_surface_normal.png"),
		"roughness": load(TEXTURE_DIR + "hull_surface_roughness.png"),
	}
	return _texture_cache


# Pushes the player's three HULL zones, pattern engine, and weathering onto a material.
static func apply_livery_zones(mat: ShaderMaterial, livery_id: String) -> void:
	for zone in [["hull_lower", "zone_lower"], ["hull_upper", "zone_upper"], ["hull_stripe", "zone_stripe"]]:
		var zid: String = zone[0]
		var uni: String = zone[1]
		var finish := LiveryScript.zone_finish(livery_id, zid)
		var color_uniform := "stripe_color" if zid == "hull_stripe" else uni + "_color"
		mat.set_shader_parameter(color_uniform, LiveryScript.zone_color(livery_id, zid))
		mat.set_shader_parameter(uni + "_metallic", LiveryScript.finish_metallic(finish))
		mat.set_shader_parameter(uni + "_roughness", LiveryScript.finish_roughness(finish))
		mat.set_shader_parameter(uni + "_surface", LiveryScript.finish_surface_type(finish))
	
	mat.set_shader_parameter("pattern_type", LiveryScript.pattern_type_int(livery_id))
	mat.set_shader_parameter("pattern_scale", LiveryScript.pattern_scale(livery_id))
	mat.set_shader_parameter("pattern_angle", LiveryScript.pattern_angle(livery_id))
	mat.set_shader_parameter("pattern_softness", LiveryScript.pattern_softness(livery_id))
	mat.set_shader_parameter("weathering", LiveryScript.weathering(livery_id))

	# Marker lights. The saturated half of a livery's identity - see the colour
	# rule above PRESETS in livery.gd and accent_emissive_color in
	# hull_faction_material.gdshader.
	mat.set_shader_parameter("accent_emissive_color",
		LiveryScript.accent_emissive_color(livery_id))
	mat.set_shader_parameter("accent_emissive_strength",
		LiveryScript.accent_emissive_strength(livery_id))

	mat.set_shader_parameter("livery_mix", 1.0)
	mat.set_shader_parameter("stripe_enabled", 1.0)

const _DEFAULT_TEXTURE_WORLD_SIZE = 3.0
# The 0.5 divisor halves the apparent panel-line density relative to the
# previous "1 tile per AABB" mapping. The source hull_surface_*.png textures
# were procedurally baked once and ship a uniform grid pattern; at one tile
# per AABB the grid cells were ~12cm on a 2m unit, which read as a tiled
# floor rather than panel breaks. 0.5 makes the cells ~24cm on the same
# unit, in the range of actual armor plate seams. The chip-noise pattern in
# the shader uses the same tex_pos and scales coherently, so the chipping
# stays consistent with the panel grid spacing. If the source texture is
# ever replaced with a hand-authored panel layout, the divisor can come
# back to 1.0 and the panel density will be governed by the source art.
static func _texture_scale_for_size(world_size: float) -> float:
	return clamp(0.5 / max(world_size, 0.1), 0.05, 1.0)

static func build_hull_material(p1: String, p2: String = "", texture_world_size: float = _DEFAULT_TEXTURE_WORLD_SIZE) -> ShaderMaterial:
	var livery_id = p2 if p2 != "" else p1
	var mat = ShaderMaterial.new()
	mat.shader = HULL_SHADER
	mat.set_shader_parameter("texture_scale", _texture_scale_for_size(texture_world_size))
	mat.set_shader_parameter("metallic", 1.0)
	mat.set_shader_parameter("roughness", 0.42)
	mat.set_shader_parameter("shield_mode", 0.0)
	mat.set_shader_parameter("alpha_base", 1.0)
	var textures = _get_surface_textures()
	mat.set_shader_parameter("albedo_tex", textures.albedo)
	mat.set_shader_parameter("normal_tex", textures.normal)
	mat.set_shader_parameter("roughness_tex", textures.roughness)
	apply_livery_zones(mat, livery_id)
	VisualTuningScript.apply(mat)
	return mat

static func apply_local_bounds(mat: ShaderMaterial, bounds_y: Vector2, bounds_x: Vector2 = Vector2.ZERO, bounds_z: Vector2 = Vector2.ZERO) -> void:
	if mat == null:
		return
	if absf(bounds_y.y - bounds_y.x) < 0.0001:
		bounds_y = Vector2(-0.5, 0.5)
	mat.set_shader_parameter("local_bounds_y", bounds_y)
	if absf(bounds_x.y - bounds_x.x) < 0.0001:
		bounds_x = Vector2(-0.5, 0.5)
	mat.set_shader_parameter("local_bounds_x", bounds_x)
	if absf(bounds_z.y - bounds_z.x) < 0.0001:
		bounds_z = Vector2(-0.5, 0.5)
	mat.set_shader_parameter("local_bounds_z", bounds_z)

# The STRUCTURAL slot (surface 0).
#
# Originally intended to be the hidden interior / bare frame, with the
# assumption that surface 0 was never visible from outside the hull. The
# assumption broke when multi-surface hull meshes were authored with the
# REAR (or most of the body) as surface 0: a large fraction of the
# visible hull then rendered as a flat gray slab with no livery at all.
# The user also dropped the original "surface 0 is invisible collide
# geometry" intent, so the structural is now genuinely a part of the
# rendered unit.
#
# The structural slot is now identical to the armor slot for COLOR, ZONE
# FINISH, and PATTERN (livery applied in full), and differs from the
# armor slot only in PBR (metallic=0.015 / roughness=0.97 vs whatever
# the armor carries) and in base_color (darkened to 0.7 so the
# structural reads as ~70% of the livery, a touch duller than the
# painted armor it sits behind - what the "bare frame" character was
# meant to convey).
static func build_structural_material(livery_id: String, texture_world_size: float = _DEFAULT_TEXTURE_WORLD_SIZE) -> ShaderMaterial:
	var mat = ShaderMaterial.new()
	mat.shader = HULL_SHADER
	apply_livery_zones(mat, livery_id)
	mat.set_shader_parameter("base_color", Color(1.0, 1.0, 1.0, 1.0).darkened(0.3))
	mat.set_shader_parameter("texture_scale", _texture_scale_for_size(texture_world_size))
	mat.set_shader_parameter("metallic", 0.015)
	mat.set_shader_parameter("roughness", 0.97)
	VisualTuningScript.apply(mat)
	mat.set_shader_parameter("shield_mode", 0.0)
	mat.set_shader_parameter("alpha_base", 1.0)
	var textures = _get_surface_textures()
	mat.set_shader_parameter("albedo_tex", textures.albedo)
	mat.set_shader_parameter("normal_tex", textures.normal)
	mat.set_shader_parameter("roughness_tex", textures.roughness)
	return mat

static func apply_hull_materials(mesh_inst: MeshInstance3D, p1: String, p2: String = "") -> void:
	var livery_id = p2 if p2 != "" else p1
	mesh_inst.material_override = null
	var texture_world_size = _DEFAULT_TEXTURE_WORLD_SIZE
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
	var armor_mat = build_hull_material(livery_id, "", texture_world_size)
	armor_mat.set_shader_parameter("mesh_scale", mesh_inst.scale)
	apply_local_bounds(armor_mat, bounds_y, bounds_x, bounds_z)
	var surface_count = mesh_inst.mesh.get_surface_count() if mesh_inst.mesh else 1
	if surface_count <= 1:
		mesh_inst.set_surface_override_material(0, armor_mat)
		return
	var structural_mat = build_structural_material(livery_id, texture_world_size)
	structural_mat.set_shader_parameter("mesh_scale", mesh_inst.scale)
	apply_local_bounds(structural_mat, bounds_y, bounds_x, bounds_z)
	mesh_inst.set_surface_override_material(0, structural_mat)
	for surf in range(1, surface_count):
		mesh_inst.set_surface_override_material(surf, armor_mat)

static func flash_hull(mesh_inst: MeshInstance3D, amount: float) -> void:
	if not mesh_inst or not mesh_inst.mesh:
		return
	for surf in range(mesh_inst.mesh.get_surface_count()):
		var mat = mesh_inst.get_surface_override_material(surf)
		if mat is ShaderMaterial:
			mat.set_shader_parameter("flash_amount", amount)

const SCALE_MODEL_ALBEDO = Color(0.38, 0.44, 0.37)

static func build_scale_model_material() -> StandardMaterial3D:
	var mat := StandardMaterial3D.new()
	mat.albedo_color = SCALE_MODEL_ALBEDO
	mat.metallic = 0.0
	mat.roughness = 0.8
	return mat

static func apply_scale_model_finish(node: Node, mat: StandardMaterial3D = null) -> void:
	if node.name == "HullGreebles":
		return
	if mat == null:
		mat = build_scale_model_material()
	if node is GeometryInstance3D:
		node.material_override = mat
		node.material_overlay = null
	if node is MeshInstance3D and node.mesh:
		for i in range(node.mesh.get_surface_count()):
			node.set_surface_override_material(i, mat)
	for child in node.get_children():
		apply_scale_model_finish(child, mat)
