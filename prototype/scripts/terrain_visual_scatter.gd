class_name TerrainVisualScatter
extends Node3D

# MultiMesh Visual Scatter System for Terrain Greebling.
#
# Generates thousands of high-coverage environmental visual details:
#  - Authored Grass Tufts & Wildflower Clusters (MultiMesh instancing)
#  - Authored Woody Shrubs, Bushes & Desert Scrub
#  - Authored Ambient Trees (20 distinct high-fidelity species silhouettes)
#  - Authored Scree, Talus & Pebble Clusters on slopes
#  - Authored Wetland Cattails & Marsh Reeds near water edges
#  - Authored Rock Spires & Cliff Facades along escarpments and ravine walls
#
# PERFORMANCE CONTRACT:
#  - 100% pure visual: zero StaticBody3D, zero CollisionShape3D, zero navigation footprint.
#  - Zero shadow caster overhead: cast_shadow = SHADOW_CASTING_SETTING_OFF.
#  - Single draw-call batching per mesh part via MultiMeshInstance3D.
#  - Deterministic generation seeded by map name and seed parameters.

const TerrainBuilderScript = preload("res://scripts/terrain_builder.gd")
const InteractiveGrassShader = preload("res://shaders/interactive_grass.gdshader")

const GRASS_TUFT_MODEL_DIR := "res://assets/models/terrain/grass_tuft_%d.glb"
const GRASS_TUFT_POOL_SIZE := 6
const WILDFLOWER_MODEL_DIR := "res://assets/models/terrain/wildflower_tuft_%d.glb"
const WILDFLOWER_POOL_SIZE := 3
const SHRUB_MODEL_DIR := "res://assets/models/terrain/shrub_%d.glb"
const SHRUB_POOL_SIZE := 4
const REEDS_MODEL_DIR := "res://assets/models/terrain/reeds_%d.glb"
const REEDS_POOL_SIZE := 3
const AMBIENT_TREE_MODEL_DIR := "res://assets/models/terrain/ambient_tree_%d.glb"
const AMBIENT_TREE_POOL_SIZE := 36
const BOULDER_MODEL_DIR := "res://assets/models/terrain/boulder_%d.glb"
const BOULDER_POOL_SIZE := 35
const ROCK_SPIRE_MODEL_DIR := "res://assets/models/terrain/rock_spire_%d.glb"
const ROCK_SPIRE_POOL_SIZE := 4
const PEBBLE_MODEL_DIR := "res://assets/models/terrain/pebble_cluster_%d.glb"
const PEBBLE_POOL_SIZE := 4
const CLIFF_FACE_MODEL_DIR := "res://assets/models/terrain/cliff_face_%d.glb"
const CLIFF_FACE_POOL_SIZE := 4
const CLIFF_CORNER_MODEL_DIR := "res://assets/models/terrain/cliff_corner_%d.glb"
const CLIFF_CORNER_POOL_SIZE := 3

const BASE_ZONE_CLEAR_RADIUS := 24.0

static var _material_cache: Dictionary = {}
static var _template_cache: Dictionary = {}
var _grass_shader_mat: ShaderMaterial = null


static func get_or_create(parent: Node3D) -> Node3D:
	var existing = parent.get_node_or_null("TerrainVisualScatter")
	if existing != null:
		return existing
	var scatter_script = load("res://scripts/terrain_visual_scatter.gd")
	var s: Node3D = scatter_script.new()
	s.name = "TerrainVisualScatter"
	parent.add_child(s)
	return s


func update_unit_interaction(units: Array) -> void:
	if _grass_shader_mat == null:
		return
	var count = mini(units.size(), 32)
	var u_pos_array: Array[Vector4] = []
	for i in range(count):
		var u = units[i]
		if is_instance_valid(u) and u is Node3D:
			var node3d = u as Node3D
			var p = node3d.global_position if node3d.is_inside_tree() else node3d.position
			var r: float = 3.5
			if u.has_method("get_hull_radius"):
				r = u.get_hull_radius()
			elif "radius" in u:
				r = float(u.radius)
			u_pos_array.append(Vector4(p.x, p.y, p.z, r))
	while u_pos_array.size() < 32:
		u_pos_array.append(Vector4.ZERO)
	
	_grass_shader_mat.set_shader_parameter("unit_positions", u_pos_array)
	_grass_shader_mat.set_shader_parameter("unit_count", count)


func _process(_delta: float) -> void:
	if _grass_shader_mat == null or not is_inside_tree():
		return
	var tree_root = get_tree()
	if tree_root == null:
		return
	var units = tree_root.get_nodes_in_group("units")
	update_unit_interaction(units)


func _get_interactive_grass_material(base_color: Color) -> ShaderMaterial:
	if _grass_shader_mat != null:
		return _grass_shader_mat
	var mat = ShaderMaterial.new()
	mat.shader = InteractiveGrassShader
	mat.set_shader_parameter("base_color", Vector3(base_color.r * 0.78, base_color.g * 0.85, base_color.b * 0.68))
	mat.set_shader_parameter("tip_color", Vector3(base_color.r * 1.22, base_color.g * 1.30, base_color.b * 1.08))
	mat.set_shader_parameter("roughness", 1.0)
	mat.set_shader_parameter("specular", 0.0)
	mat.set_shader_parameter("wind_speed", 2.4)
	mat.set_shader_parameter("wind_strength", 0.18)
	_grass_shader_mat = mat
	return _grass_shader_mat


func _get_material(color: Color, roughness: float = 0.9, metallic: float = 0.0) -> StandardMaterial3D:
	var key = "%s_%.2f_%.2f" % [color.to_html(false), roughness, metallic]
	if _material_cache.has(key):
		return _material_cache[key]
	var mat = StandardMaterial3D.new()
	mat.albedo_color = color
	mat.roughness = roughness
	mat.metallic = metallic
	mat.metallic_specular = 0.0
	mat.specular_mode = BaseMaterial3D.SPECULAR_DISABLED
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_PER_PIXEL
	_material_cache[key] = mat
	return mat


# ------------------------------------------------------------------------------
# Procedural Fallback Mesh Generators
# ------------------------------------------------------------------------------

func _build_grass_mesh(prop_scale: float = 1.0) -> ArrayMesh:
	var st = SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	
	var blade_w = 0.06 * prop_scale
	var blade_h = 0.65 * prop_scale
	var num_blades = 5
	
	for i in range(num_blades):
		var angle = (TAU / float(num_blades)) * i + 0.2 * sin(float(i))
		var r_offset = 0.08 * prop_scale
		var bx = cos(angle) * r_offset
		var bz = sin(angle) * r_offset
		var lean = 0.25 * prop_scale
		var tip_x = bx + cos(angle) * lean
		var tip_z = bz + sin(angle) * lean
		
		var perp_x = -sin(angle) * blade_w * 0.5
		var perp_z = cos(angle) * blade_w * 0.5
		
		var v0 = Vector3(bx - perp_x, 0.0, bz - perp_z)
		var v1 = Vector3(bx + perp_x, 0.0, bz + perp_z)
		var v2 = Vector3(tip_x, blade_h, tip_z)
		
		var normal = Vector3(0, 1, 0)
		st.set_normal(normal)
		st.set_uv(Vector2(0, 0))
		st.add_vertex(v0)
		st.set_uv(Vector2(1, 0))
		st.add_vertex(v1)
		st.set_uv(Vector2(0.5, 1))
		st.add_vertex(v2)
		
		st.add_vertex(v0)
		st.add_vertex(v2)
		st.add_vertex(v1)
		
	st.generate_normals()
	return st.commit()


func _build_shrub_mesh(prop_scale: float = 1.0) -> ArrayMesh:
	var st = SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	
	var r = 0.75 * prop_scale
	var h = 0.65 * prop_scale
	var segments = 6
	
	for i in range(segments):
		var a1 = (TAU / float(segments)) * i
		var a2 = (TAU / float(segments)) * (i + 1)
		var p1 = Vector3(cos(a1) * r, h * 0.4, sin(a1) * r)
		var p2 = Vector3(cos(a2) * r, h * 0.4, sin(a2) * r)
		var apex = Vector3(0, h, 0)
		var bot1 = Vector3(cos(a1) * r * 0.4, 0.0, sin(a1) * r * 0.4)
		var bot2 = Vector3(cos(a2) * r * 0.4, 0.0, sin(a2) * r * 0.4)
		
		st.add_vertex(bot1); st.add_vertex(p2); st.add_vertex(p1)
		st.add_vertex(bot1); st.add_vertex(bot2); st.add_vertex(p2)
		st.add_vertex(p1); st.add_vertex(p2); st.add_vertex(apex)
		
	st.generate_normals()
	return st.commit()


func _build_pebble_mesh(prop_scale: float = 1.0) -> ArrayMesh:
	var st = SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var r = 0.3 * prop_scale
	var h = 0.2 * prop_scale
	var segs = 5
	for i in range(segs):
		var a1 = (TAU / float(segs)) * i
		var a2 = (TAU / float(segs)) * (i + 1)
		var p1 = Vector3(cos(a1) * r, 0.0, sin(a1) * r)
		var p2 = Vector3(cos(a2) * r, 0.0, sin(a2) * r)
		var apex = Vector3(0, h, 0)
		st.add_vertex(p1); st.add_vertex(p2); st.add_vertex(apex)
	st.generate_normals()
	return st.commit()


func _build_reed_mesh(prop_scale: float = 1.0) -> ArrayMesh:
	var st = SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var h = 1.4 * prop_scale
	var w = 0.04 * prop_scale
	for i in range(3):
		var a = i * 2.1
		var ox = cos(a) * 0.1 * prop_scale
		var oz = sin(a) * 0.1 * prop_scale
		var v0 = Vector3(ox - w, 0.0, oz)
		var v1 = Vector3(ox + w, 0.0, oz)
		var v2 = Vector3(ox + cos(a) * 0.15, h, oz + sin(a) * 0.15)
		st.add_vertex(v0); st.add_vertex(v1); st.add_vertex(v2)
		st.add_vertex(v0); st.add_vertex(v2); st.add_vertex(v1)
	st.generate_normals()
	return st.commit()


# ------------------------------------------------------------------------------
# GLTF Template Extraction (MultiMesh Part Loader)
# ------------------------------------------------------------------------------

static func _surface_mesh(src: Mesh, index: int) -> Mesh:
	if src.get_surface_count() <= 1:
		return src
	var out := ArrayMesh.new()
	out.add_surface_from_arrays(src.surface_get_primitive_type(index),
		src.surface_get_arrays(index))
	return out


static func _load_gltf_parts(scene_path: String) -> Array:
	if _template_cache.has(scene_path):
		return _template_cache[scene_path]
	if not ResourceLoader.exists(scene_path):
		return []
	var packed = load(scene_path) as PackedScene
	if packed == null:
		return []
	var inst = packed.instantiate()
	if inst == null:
		return []
	var parts: Array = []
	var stack: Array = [[inst, Transform3D.IDENTITY]]
	var scene_materials: Dictionary = {}
	while not stack.is_empty():
		var item: Array = stack.pop_back()
		var n: Node = item[0]
		var cur_xform: Transform3D = item[1]
		if n is Node3D and n != inst:
			cur_xform = cur_xform * (n as Node3D).transform
		if n is MeshInstance3D and n.mesh != null:
			var src_mesh: Mesh = n.mesh
			for si in range(maxi(src_mesh.get_surface_count(), 1)):
				var mat: Material = n.material_override
				if mat == null and si < n.get_surface_override_material_count():
					mat = n.get_surface_override_material(si)
				if mat == null and si < src_mesh.get_surface_count():
					mat = src_mesh.surface_get_material(si)

				var mat_key: String = "default"
				if mat != null:
					mat_key = str(mat.resource_path) if str(mat.resource_path) != "" else "id:%d" % mat.get_instance_id()
				if not scene_materials.has(mat_key):
					var matte_mat := StandardMaterial3D.new()
					if mat is StandardMaterial3D or mat is ORMMaterial3D or mat is BaseMaterial3D:
						matte_mat.albedo_color = mat.albedo_color
						matte_mat.albedo_texture = mat.albedo_texture
						if mat.normal_enabled or mat.normal_texture != null:
							matte_mat.normal_enabled = true
							matte_mat.normal_texture = mat.normal_texture
						if mat.transparency != BaseMaterial3D.TRANSPARENCY_DISABLED or (mat.albedo_texture != null and mat.albedo_texture.has_alpha()):
							matte_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA_SCISSOR
							matte_mat.alpha_scissor_threshold = 0.45
							matte_mat.cull_mode = BaseMaterial3D.CULL_DISABLED
					else:
						matte_mat.albedo_color = Color(0.22, 0.28, 0.18)
					matte_mat.roughness = 1.0
					matte_mat.metallic = 0.0
					matte_mat.metallic_specular = 0.0
					matte_mat.specular_mode = BaseMaterial3D.SPECULAR_DISABLED
					scene_materials[mat_key] = matte_mat

				parts.append({
					"mesh": _surface_mesh(src_mesh, si),
					"xform": cur_xform,
					"material": scene_materials[mat_key],
				})
		for c in n.get_children():
			stack.append([c, cur_xform])
	inst.free()
	_template_cache[scene_path] = parts
	return parts


func _add_multimesh_batch(mesh: Mesh, material: Material, transforms: Array[Transform3D], colors: Array[Color], batch_name: String, vis_begin: float = 0.0, vis_end: float = 0.0) -> MultiMeshInstance3D:
	if transforms.is_empty() or mesh == null:
		return null
	var mm = MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.use_colors = true
	mm.mesh = mesh
	mm.instance_count = transforms.size()
	for i in range(transforms.size()):
		mm.set_instance_transform(i, transforms[i])
		if i < colors.size():
			mm.set_instance_color(i, colors[i])
		else:
			mm.set_instance_color(i, Color.WHITE)
	
	var mmi = MultiMeshInstance3D.new()
	mmi.multimesh = mm
	if material != null:
		mmi.material_override = material
	mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	# Scatter meshes don't meaningfully contribute to bounce light.
	# GI_MODE_DISABLED skips them in the SDFGI / voxel-GI bake and the
	# per-frame scattering pass; the visible result is identical for
	# foliage / pebble / clutter, and the bake is much cheaper at 200+
	# instances per MultiMesh.
	mmi.gi_mode = MultiMeshInstance3D.GI_MODE_DISABLED
	if vis_end > 0.0:
		mmi.visibility_range_begin = vis_begin
		mmi.visibility_range_end = vis_end
		mmi.visibility_range_fade_mode = GeometryInstance3D.VISIBILITY_RANGE_FADE_SELF
	mmi.name = batch_name
	mmi.add_to_group("visual_scatter")
	add_child(mmi)
	return mmi


func _add_gltf_variant_batches(model_template_path: String, pool_size: int, variant_xforms: Dictionary, variant_colors: Dictionary, fallback_mesh: Mesh, fallback_mat: Material, batch_prefix: String, vis_begin: float = 0.0, vis_end: float = 0.0, ticker: Node = null, gate: Dictionary = {}, material_override: Material = null) -> void:
	for var_idx in variant_xforms.keys():
		var xf_list: Array = variant_xforms[var_idx]
		var sz: int = xf_list.size()
		if sz == 0:
			continue
		await _scatter_slice(ticker, gate)
		var col_list: Array = variant_colors.get(var_idx, [])
		var glb_path: String = model_template_path % var_idx if ("%d" in model_template_path or "%s" in model_template_path) else model_template_path
		var parts = _load_gltf_parts(glb_path)
		if parts.is_empty():
			if fallback_mesh != null:
				var casted_xforms: Array[Transform3D] = []
				var casted_cols: Array[Color] = []
				casted_xforms.resize(sz)
				casted_cols.resize(sz)
				for i in range(sz):
					casted_xforms[i] = xf_list[i]
					casted_cols[i] = col_list[i] if i < col_list.size() else Color.WHITE
				var mat = material_override if material_override != null else fallback_mat
				_add_multimesh_batch(fallback_mesh, mat, casted_xforms, casted_cols, "%s_Fallback_%d" % [batch_prefix, var_idx], vis_begin, vis_end)
			continue
		for p_idx in range(parts.size()):
			var part = parts[p_idx]
			var mesh: Mesh = part["mesh"]
			var local_xform: Transform3D = part["xform"]
			var composed_xforms: Array[Transform3D] = []
			var composed_cols: Array[Color] = []
			composed_xforms.resize(sz)
			composed_cols.resize(sz)
			for i in range(sz):
				composed_xforms[i] = (xf_list[i] as Transform3D) * local_xform
				composed_cols[i] = col_list[i] if i < col_list.size() else Color.WHITE
			var mat: Material = material_override if material_override != null else part.get("material")
			_add_multimesh_batch(mesh, mat, composed_xforms, composed_cols, "%s_%d_%d" % [batch_prefix, var_idx, p_idx], vis_begin, vis_end)


func spawn_authored_props(props: Array, prop_scale: float = 1.0, ticker: Node = null) -> void:
	await _spawn_authored_props(props, prop_scale, ticker)

func _spawn_authored_props(props: Array, prop_scale: float = 1.0, ticker: Node = null) -> void:
	var tree_xforms: Dictionary = {}
	var tree_colors: Dictionary = {}
	var boulder_xforms: Dictionary = {}
	var boulder_colors: Dictionary = {}
	var spire_xforms: Dictionary = {}
	var spire_colors: Dictionary = {}
	var shrub_xforms: Dictionary = {}
	var shrub_colors: Dictionary = {}
	var cliff_xforms: Dictionary = {}
	var cliff_colors: Dictionary = {}
	var building_xforms: Dictionary = {}
	var building_colors: Dictionary = {}

	for prop in props:
		var ptype: String = str(prop.get("type", "tree"))
		var pos_arr = prop.get("pos", [0, 0, 0])
		var pos := Vector3(float(pos_arr[0]), float(pos_arr[1]), float(pos_arr[2]))
		var s: float = float(prop.get("scale", 1.0)) * prop_scale
		var yaw: float = float(prop.get("yaw", 0.0))
		var var_id: int = int(prop.get("variant", 0))
		var col_arr = prop.get("color", [1.0, 1.0, 1.0])
		var col := Color(col_arr[0], col_arr[1], col_arr[2]) if col_arr.size() >= 3 else Color.WHITE

		var basis := Basis(Vector3.UP, yaw).scaled(Vector3.ONE * s)
		var xf := Transform3D(basis, pos)

		if ptype == "building" or ptype.begins_with("bld_") or prop.has("building_id"):
			var b_id: String = str(prop.get("building_id", prop.get("model", "")))
			if b_id != "":
				if not building_xforms.has(b_id):
					building_xforms[b_id] = []
					building_colors[b_id] = []
				building_xforms[b_id].append(xf)
				building_colors[b_id].append(col)
		elif ptype.begins_with("tree") or ptype.begins_with("ambient_tree"):
			var v := var_id % AMBIENT_TREE_POOL_SIZE
			if not tree_xforms.has(v): tree_xforms[v] = []; tree_colors[v] = []
			tree_xforms[v].append(xf)
			tree_colors[v].append(col)
		elif ptype.begins_with("boulder") or ptype.begins_with("rock"):
			var v := var_id % BOULDER_POOL_SIZE
			if not boulder_xforms.has(v): boulder_xforms[v] = []; boulder_colors[v] = []
			boulder_xforms[v].append(xf)
			boulder_colors[v].append(col)
		elif ptype.begins_with("spire") or ptype.begins_with("rock_spire"):
			var v := var_id % ROCK_SPIRE_POOL_SIZE
			if not spire_xforms.has(v): spire_xforms[v] = []; spire_colors[v] = []
			spire_xforms[v].append(xf)
			spire_colors[v].append(col)
		elif ptype.begins_with("shrub") or ptype.begins_with("bush"):
			var v := var_id % SHRUB_POOL_SIZE
			if not shrub_xforms.has(v): shrub_xforms[v] = []; shrub_colors[v] = []
			shrub_xforms[v].append(xf)
			shrub_colors[v].append(col)
		elif ptype.begins_with("cliff") or ptype.begins_with("rock_face"):
			var cliff_names = ["face_0", "face_1", "face_2", "face_3", "strata_0", "strata_1", "strata_2"]
			var v := var_id % cliff_names.size()
			if not cliff_xforms.has(v): cliff_xforms[v] = []; cliff_colors[v] = []
			cliff_xforms[v].append(xf)
			cliff_colors[v].append(col)

	var gate := {"t": Time.get_ticks_usec() + int(TerrainBuilderScript.BUILD_FRAME_BUDGET_MS * 1000.0)}

	if not building_xforms.is_empty():
		for b_id in building_xforms.keys():
			var glb_path := "res://assets/models/buildings/civic/%s.glb" % b_id
			var single_batch: Dictionary = {0: building_xforms[b_id]}
			var single_col: Dictionary = {0: building_colors[b_id]}
			var fb_mat := _get_material(Color(0.55, 0.52, 0.48))
			await _add_gltf_variant_batches(glb_path, 1, single_batch, single_col, null, fb_mat, "Authored_Bld_" + b_id, 0.0, 3000.0, ticker, gate)

	if not tree_xforms.is_empty():
		var fb_mat := _get_material(Color(0.24, 0.40, 0.20))
		await _add_gltf_variant_batches(AMBIENT_TREE_MODEL_DIR, AMBIENT_TREE_POOL_SIZE, tree_xforms, tree_colors, null, fb_mat, "Authored_Tree", 0.0, 1800.0, ticker, gate)

	if not boulder_xforms.is_empty():
		var fb_mat := _get_material(Color(0.48, 0.44, 0.40))
		await _add_gltf_variant_batches(BOULDER_MODEL_DIR, BOULDER_POOL_SIZE, boulder_xforms, boulder_colors, null, fb_mat, "Authored_Boulder", 0.0, 1500.0, ticker, gate)

	if not spire_xforms.is_empty():
		var fb_mat := _get_material(Color(0.42, 0.38, 0.35))
		await _add_gltf_variant_batches(ROCK_SPIRE_MODEL_DIR, ROCK_SPIRE_POOL_SIZE, spire_xforms, spire_colors, null, fb_mat, "Authored_Spire", 0.0, 1600.0, ticker, gate)

	if not shrub_xforms.is_empty():
		var fb_shrub := _build_shrub_mesh(prop_scale)
		var fb_mat := _get_material(Color(0.28, 0.45, 0.22))
		await _add_gltf_variant_batches(SHRUB_MODEL_DIR, SHRUB_POOL_SIZE, shrub_xforms, shrub_colors, fb_shrub, fb_mat, "Authored_Shrub", 0.0, 1200.0, ticker, gate)

	if not cliff_xforms.is_empty():
		var cliff_names = ["face_0", "face_1", "face_2", "face_3", "strata_0", "strata_1", "strata_2"]
		var fb_mat := _get_material(Color(0.46, 0.44, 0.42))
		for v in cliff_xforms.keys():
			var glb_name: String = cliff_names[v % cliff_names.size()]
			var glb_path := "res://assets/models/terrain/cliff_%s.glb" % glb_name
			var single_batch: Dictionary = {v: cliff_xforms[v]}
			var single_col: Dictionary = {v: cliff_colors[v]}
			await _add_gltf_variant_batches(glb_path.replace(glb_name, "%s"), 1, single_batch, single_col, null, fb_mat, "Authored_Cliff_" + glb_name, 0.0, 2200.0, ticker, gate)


# ------------------------------------------------------------------------------
# Main Scatter Pipeline
# ------------------------------------------------------------------------------

# One frame-budget slice for scatter_all's loops. `gate` is a {"t": usec}
# Dictionary because the deadline has to survive between call sites - a plain
# local would be captured per-call and never advance.
func _scatter_slice(ticker: Node, gate: Dictionary) -> void:
	if ticker == null or Time.get_ticks_usec() < int(gate["t"]):
		return
	await get_tree().process_frame
	gate["t"] = Time.get_ticks_usec() + int(TerrainBuilderScript.BUILD_FRAME_BUDGET_MS * 1000.0)


func scatter_all(map_def: Dictionary, prop_scale: float = 1.0, ticker: Node = null) -> void:
	if bool(map_def.get("disable_ambient_scatter", false)):
		return

	# If the map has authored painted props, load them directly and bypass procedural loops!
	var authored_props: Array = map_def.get("props", [])
	if not authored_props.is_empty():
		await _spawn_authored_props(authored_props, prop_scale, ticker)
		return

	# FRAME-CHUNKING (2026-08-23). This pass measured 60 s wall-clock on a
	# 960-half map - by far the largest single continuous freeze in the world
	# build, long enough that the loading screen read as dead. Pass a ticker
	# (any Node in the tree) and every loop below yields process_frame
	# whenever the frame has spent TerrainBuilderScript.BUILD_FRAME_BUDGET_MS;
	# without one the whole function is the old single-frame call. The gates
	# are pure scheduling: RNG draws, iteration order and every placement
	# decision are unchanged, so output is identical either way.
	var gate := {"t": Time.get_ticks_usec() + int(TerrainBuilderScript.BUILD_FRAME_BUDGET_MS * 1000.0)}

	var half: float = map_def.get("map_half_extents", 100.0)
	var map_name: String = map_def.get("name", "battlefield")
	var area: float = (half * 2.0) * (half * 2.0)
	
	# Precalculate clear points
	var clear_points_2d: Array = []
	for bz in map_def.get("base_zones", []):
		var c = bz.get("center", Vector3.ZERO)
		clear_points_2d.append({"p": Vector2(c.x, c.z), "r_sq": BASE_ZONE_CLEAR_RADIUS * BASE_ZONE_CLEAR_RADIUS})
	for sp in map_def.get("spawns", []):
		for k in sp.keys():
			if k != "id" and sp[k] is Vector3:
				var sv: Vector3 = sp[k]
				clear_points_2d.append({"p": Vector2(sv.x, sv.z), "r_sq": 64.0})
	for rn in map_def.get("resource_nodes", []):
		var rv: Vector3 = rn.get("position", Vector3.ZERO)
		clear_points_2d.append({"p": Vector2(rv.x, rv.z), "r_sq": 49.0})
		
	# Water & Bridges
	var water_areas: Array = map_def.get("water_areas", [])
	var bridges: Array = map_def.get("bridges", [])
	var surface_zones: Array = map_def.get("surface_zones", [])
	
	var ground_color_arr = map_def.get("ground_color", [0.30, 0.38, 0.23])
	var base_green = Color(ground_color_arr[0], ground_color_arr[1], ground_color_arr[2])
	
	var _h = func(pos: Vector3) -> float:
		return TerrainBuilderScript.terrain_height_at(map_def, pos)

	var _sl = func(sx: float, sz: float) -> float:
		return TerrainBuilderScript.slope_at(map_def, sx, sz)

	var _fast_xform = func(pos: Vector3, yaw: float, scale_jitter: float) -> Transform3D:
		var basis = Basis(Vector3.UP, yaw).scaled(Vector3.ONE * scale_jitter)
		return Transform3D(basis, pos)

	# --------------------------------------------------------------------------
	# 1. SPARSE ACCENT GRASS (Minimal 3D scatter — the ground texture does
	#    the heavy lifting. Grass here is accent tufts and wildflowers only,
	#    not a dense carpet. The old dense carpet (step 2.4) produced ~30k
	#    instances that fought with the ground texture and read as "shrubs
	#    scattered on rock" rather than as grassland.)
	# --------------------------------------------------------------------------
	var grass_rng = RandomNumberGenerator.new()
	grass_rng.seed = hash(map_name + "_grass_lawn_continuous")
	
	var grass_xforms_by_variant: Dictionary = {}
	var grass_colors_by_variant: Dictionary = {}
	for v in range(GRASS_TUFT_POOL_SIZE):
		grass_xforms_by_variant[v] = []
		grass_colors_by_variant[v] = []
		
	var flower_xforms_by_variant: Dictionary = {}
	var flower_colors_by_variant: Dictionary = {}
	for v in range(WILDFLOWER_POOL_SIZE):
		flower_xforms_by_variant[v] = []
		flower_colors_by_variant[v] = []
	
	var step_size = 7.0 * prop_scale
	var grid_steps = int((half * 1.88) / step_size)
	var point_counter = 0
	
	for ix in range(grid_steps):
		if ix % 8 == 0:
			await _scatter_slice(ticker, gate)
		var base_gx = -half * 0.94 + float(ix) * step_size
		for iz in range(grid_steps):
			point_counter += 1
			if point_counter % 1200 == 0:
				await _scatter_slice(ticker, gate)
				
			var gx = base_gx + grass_rng.randf_range(-step_size * 0.45, step_size * 0.45)
			var gz = -half * 0.94 + float(iz) * step_size + grass_rng.randf_range(-step_size * 0.45, step_size * 0.45)
			
			if absf(gx) > half * 0.96 or absf(gz) > half * 0.96:
				continue
			var p2 = Vector2(gx, gz)
			var too_close = false
			for cp in clear_points_2d:
				if (p2 - (cp["p"] as Vector2)).length_squared() < cp["r_sq"]:
					too_close = true
					break
			if too_close:
				continue
				
			var pos = Vector3(gx, 0.0, gz)
			if _is_in_water(pos, water_areas, bridges):
				continue
				
			pos.y = _h.call(pos)
			var slope = _sl.call(pos.x, pos.z)
			if slope > 0.65:
				continue
				
			var yaw = grass_rng.randf_range(0, TAU)
			var scale_jitter = grass_rng.randf_range(1.05, 1.40) * prop_scale
			var t = _fast_xform.call(pos, yaw, scale_jitter)
			
			var tint = Color(
				1.0 + grass_rng.randf_range(-0.08, 0.08),
				1.0 + grass_rng.randf_range(-0.05, 0.07),
				1.0 + grass_rng.randf_range(-0.10, 0.05),
				1.0
			)
			
			# Low-frequency wildflower blooms
			if grass_rng.randf() < 0.04:
				var flower_var = grass_rng.randi() % WILDFLOWER_POOL_SIZE
				flower_xforms_by_variant[flower_var].append(t)
				flower_colors_by_variant[flower_var].append(tint)
			else:
				var grass_var = grass_rng.randi() % GRASS_TUFT_POOL_SIZE
				grass_xforms_by_variant[grass_var].append(t)
				grass_colors_by_variant[grass_var].append(tint)
		
	var fallback_grass_mesh = _build_grass_mesh(prop_scale)
	var interactive_grass_mat = _get_interactive_grass_material(base_green)
	await _scatter_slice(ticker, gate)
	await _add_gltf_variant_batches(GRASS_TUFT_MODEL_DIR, GRASS_TUFT_POOL_SIZE, grass_xforms_by_variant, grass_colors_by_variant,
		fallback_grass_mesh, interactive_grass_mat, "Batch_GrassLawn", 0.0, 0.0, ticker, gate, interactive_grass_mat)
	await _add_gltf_variant_batches(WILDFLOWER_MODEL_DIR, WILDFLOWER_POOL_SIZE, flower_xforms_by_variant, flower_colors_by_variant,
		fallback_grass_mesh, interactive_grass_mat, "Batch_Wildflower", 0.0, 0.0, ticker, gate, interactive_grass_mat)
	
	# --------------------------------------------------------------------------
	# 2. AUTHORED SHRUBS & BUSHES
	# --------------------------------------------------------------------------
	var shrub_count = clampi(int(area / 200.0), 40, 250)
	var shrub_rng = RandomNumberGenerator.new()
	shrub_rng.seed = hash(map_name + "_shrubs_v2")
	
	var shrub_xforms_by_variant: Dictionary = {}
	var shrub_colors_by_variant: Dictionary = {}
	for v in range(SHRUB_POOL_SIZE):
		shrub_xforms_by_variant[v] = []
		shrub_colors_by_variant[v] = []
	
	var num_shrub_clusters = maxi(6, int(shrub_count / 20))
	var shrubs_per_cluster = int(shrub_count / num_shrub_clusters)
	
	for c_idx in range(num_shrub_clusters):
		await _scatter_slice(ticker, gate)
		var cluster_cx = shrub_rng.randf_range(-half * 0.93, half * 0.93)
		var cluster_cz = shrub_rng.randf_range(-half * 0.93, half * 0.93)
		var cluster_radius = shrub_rng.randf_range(14.0, 32.0) * prop_scale
		
		for i in range(shrubs_per_cluster):
			var r_jitter = (shrub_rng.randf_range(-1.0, 1.0) + shrub_rng.randf_range(-1.0, 1.0)) * 0.5 * cluster_radius
			var theta = shrub_rng.randf_range(0, TAU)
			var sx = cluster_cx + cos(theta) * r_jitter
			var sz = cluster_cz + sin(theta) * r_jitter
			if absf(sx) > half * 0.95 or absf(sz) > half * 0.95:
				continue
			var p2 = Vector2(sx, sz)
			var too_close = false
			for cp in clear_points_2d:
				if (p2 - (cp["p"] as Vector2)).length_squared() < cp["r_sq"]:
					too_close = true
					break
			if too_close:
				continue
				
			var pos = Vector3(sx, 0.0, sz)
			if _is_in_water(pos, water_areas, bridges):
				continue
				
			pos.y = _h.call(pos)
			var slope = _sl.call(pos.x, pos.z)
			if slope > 0.60:
				continue
				
			var yaw = shrub_rng.randf_range(0, TAU)
			var scale_jitter = shrub_rng.randf_range(0.85, 1.5) * prop_scale
			var t = _fast_xform.call(pos, yaw, scale_jitter)
			
			var tint = Color(
				1.0 + shrub_rng.randf_range(-0.10, 0.10),
				1.0 + shrub_rng.randf_range(-0.08, 0.08),
				1.0 + shrub_rng.randf_range(-0.12, 0.08),
				1.0
			)
			
			var shrub_var = shrub_rng.randi() % SHRUB_POOL_SIZE
			shrub_xforms_by_variant[shrub_var].append(t)
			shrub_colors_by_variant[shrub_var].append(tint)
		
	var fallback_shrub_mesh = _build_shrub_mesh(prop_scale)
	var fallback_shrub_mat = _get_material(base_green.darkened(0.08), 0.85)
	await _scatter_slice(ticker, gate)
	await _add_gltf_variant_batches(SHRUB_MODEL_DIR, SHRUB_POOL_SIZE, shrub_xforms_by_variant, shrub_colors_by_variant,
		fallback_shrub_mesh, fallback_shrub_mat, "Batch_Shrub", 0.0, 320.0, ticker, gate)
	
	# --------------------------------------------------------------------------
	# 3. AUTHORED VISUAL TREES (Clustered Forest Belts)
	# --------------------------------------------------------------------------
	var tree_count = clampi(int(area / 1400.0), 80, 800)
	var tree_rng = RandomNumberGenerator.new()
	tree_rng.seed = hash(map_name + "_visual_trees")
	
	var tree_xforms_by_variant: Dictionary = {}
	var tree_colors_by_variant: Dictionary = {}
	for sp_idx in range(AMBIENT_TREE_POOL_SIZE):
		tree_xforms_by_variant[sp_idx] = []
		tree_colors_by_variant[sp_idx] = []
		
	var num_tree_groves = maxi(8, int(tree_count / 14))
	var trees_per_grove = int(tree_count / num_tree_groves)
	
	for g_idx in range(num_tree_groves):
		var grove_cx = tree_rng.randf_range(-half * 0.90, half * 0.90)
		var grove_cz = tree_rng.randf_range(-half * 0.90, half * 0.90)
		var grove_radius = tree_rng.randf_range(18.0, 42.0) * prop_scale
		var grove_species_base = (tree_rng.randi() % 12) * 3
		
		for i in range(trees_per_grove):
			var r_j = (tree_rng.randf_range(-1.0, 1.0) + tree_rng.randf_range(-1.0, 1.0)) * 0.5 * grove_radius
			var theta = tree_rng.randf_range(0, TAU)
			var tx = grove_cx + cos(theta) * r_j
			var tz = grove_cz + sin(theta) * r_j
			if absf(tx) > half * 0.94 or absf(tz) > half * 0.94:
				continue
			var p2 = Vector2(tx, tz)
			var too_close = false
			for cp in clear_points_2d:
				if (p2 - (cp["p"] as Vector2)).length_squared() < cp["r_sq"]:
					too_close = true
					break
			if too_close:
				continue
				
			var pos = Vector3(tx, 0.0, tz)
			if _is_in_water(pos, water_areas, bridges):
				continue
				
			pos.y = _h.call(pos)
			var slope = _sl.call(pos.x, pos.z)
			if slope > 0.55:
				continue
				
			var sp_variant_offset = tree_rng.randi() % 3
			var sp_choice = (grove_species_base + sp_variant_offset) % AMBIENT_TREE_POOL_SIZE
			var yaw = tree_rng.randf_range(0, TAU)
			var scale_jitter = tree_rng.randf_range(1.15, 1.7) * prop_scale
			var t = _fast_xform.call(pos, yaw, scale_jitter)
			
			var tint = Color(
				1.0 + tree_rng.randf_range(-0.10, 0.08),
				1.0 + tree_rng.randf_range(-0.08, 0.08),
				1.0 + tree_rng.randf_range(-0.10, 0.08),
				1.0
			)
			tree_xforms_by_variant[sp_choice].append(t)
			tree_colors_by_variant[sp_choice].append(tint)
		
	await _scatter_slice(ticker, gate)
	await _add_gltf_variant_batches(AMBIENT_TREE_MODEL_DIR, AMBIENT_TREE_POOL_SIZE, tree_xforms_by_variant, tree_colors_by_variant,
		null, null, "Batch_VisualTree", 0.0, 750.0, ticker, gate)
	
	# --------------------------------------------------------------------------
	# 4. AUTHORED SLOPE SCREE & TALUS
	# --------------------------------------------------------------------------
	var scree_count = clampi(int(area / 250.0), 30, 150)
	var scree_rng = RandomNumberGenerator.new()
	scree_rng.seed = hash(map_name + "_scree_talus")
	
	var pebble_xforms_by_variant: Dictionary = {}
	var pebble_colors_by_variant: Dictionary = {}
	for v in range(PEBBLE_POOL_SIZE):
		pebble_xforms_by_variant[v] = []
		pebble_colors_by_variant[v] = []
	
	for i in range(scree_count):
		var rx = scree_rng.randf_range(-half * 0.98, half * 0.98)
		var rz = scree_rng.randf_range(-half * 0.98, half * 0.98)
		var pos = Vector3(rx, 0.0, rz)
		
		if _is_in_water(pos, water_areas, bridges):
			continue
			
		var slope = _sl.call(pos.x, pos.z)
		if slope < 0.12:
			continue
			
		pos.y = _h.call(pos)
		var yaw = scree_rng.randf_range(0, TAU)
		var scale_jitter = scree_rng.randf_range(0.7, 1.8) * prop_scale
		var t = _fast_xform.call(pos, yaw, scale_jitter)
		
		var tint = Color(
			1.0 + scree_rng.randf_range(-0.14, 0.12),
			1.0 + scree_rng.randf_range(-0.14, 0.12),
			1.0 + scree_rng.randf_range(-0.14, 0.12),
			1.0
		)
		
		var p_var = scree_rng.randi() % PEBBLE_POOL_SIZE
		pebble_xforms_by_variant[p_var].append(t)
		pebble_colors_by_variant[p_var].append(tint)
		
	var fallback_pebble_mesh = _build_pebble_mesh(prop_scale)
	var fallback_pebble_mat = _get_material(Color(0.38, 0.36, 0.33), 0.95)
	await _scatter_slice(ticker, gate)
	await _add_gltf_variant_batches(PEBBLE_MODEL_DIR, PEBBLE_POOL_SIZE, pebble_xforms_by_variant, pebble_colors_by_variant,
		fallback_pebble_mesh, fallback_pebble_mat, "Batch_PebbleCluster", 0.0, 220.0, ticker, gate)
	
	# --------------------------------------------------------------------------
	# 5. AUTHORED ROCK SPIRES & MONOLITHS
	# --------------------------------------------------------------------------
	var spire_count = clampi(int(area / 1500.0), 10, 40)
	var spire_rng = RandomNumberGenerator.new()
	spire_rng.seed = hash(map_name + "_rock_spires")
	
	var spire_xforms_by_variant: Dictionary = {}
	var spire_colors_by_variant: Dictionary = {}
	for v in range(ROCK_SPIRE_POOL_SIZE):
		spire_xforms_by_variant[v] = []
		spire_colors_by_variant[v] = []
		
	for i in range(spire_count):
		var rx = spire_rng.randf_range(-half * 0.94, half * 0.94)
		var rz = spire_rng.randf_range(-half * 0.94, half * 0.94)
		var p2 = Vector2(rx, rz)
		var too_close = false
		for cp in clear_points_2d:
			if (p2 - (cp["p"] as Vector2)).length_squared() < 144.0:
				too_close = true
				break
		if too_close:
			continue
			
		var pos = Vector3(rx, 0.0, rz)
		if _is_in_water(pos, water_areas, bridges):
			continue
			
		pos.y = _h.call(pos)
		var slope = _sl.call(pos.x, pos.z)
		if slope < 0.20 or slope > 0.55:
			continue
			
		var yaw = spire_rng.randf_range(0, TAU)
		var scale_jitter = spire_rng.randf_range(0.8, 1.4) * prop_scale
		var t = _fast_xform.call(pos, yaw, scale_jitter)
		
		var tint = Color(
			1.0 + spire_rng.randf_range(-0.12, 0.12),
			1.0 + spire_rng.randf_range(-0.12, 0.12),
			1.0 + spire_rng.randf_range(-0.12, 0.12),
			1.0
		)
		
		var sp_var = spire_rng.randi() % ROCK_SPIRE_POOL_SIZE
		spire_xforms_by_variant[sp_var].append(t)
		spire_colors_by_variant[sp_var].append(tint)
		
	await _scatter_slice(ticker, gate)
	await _add_gltf_variant_batches(ROCK_SPIRE_MODEL_DIR, ROCK_SPIRE_POOL_SIZE, spire_xforms_by_variant, spire_colors_by_variant,
		fallback_pebble_mesh, fallback_pebble_mat, "Batch_RockSpire", 0.0, 650.0, ticker, gate)
	
	# --------------------------------------------------------------------------
	# 6. AUTHORED CLIFF FACADES & CORNERS
	# --------------------------------------------------------------------------
	var cliff_count = clampi(int(area / 1500.0), 15, 40)
	var cliff_rng = RandomNumberGenerator.new()
	cliff_rng.seed = hash(map_name + "_cliff_facades")
	
	var cliff_xforms_by_variant: Dictionary = {}
	var cliff_colors_by_variant: Dictionary = {}
	for v in range(CLIFF_FACE_POOL_SIZE):
		cliff_xforms_by_variant[v] = []
		cliff_colors_by_variant[v] = []
		
	var cliff_corner_xforms: Dictionary = {}
	var cliff_corner_colors: Dictionary = {}
	for v in range(CLIFF_CORNER_POOL_SIZE):
		cliff_corner_xforms[v] = []
		cliff_corner_colors[v] = []
		
	for i in range(cliff_count):
		var cx = cliff_rng.randf_range(-half * 0.94, half * 0.94)
		var cz = cliff_rng.randf_range(-half * 0.94, half * 0.94)
		var pos = Vector3(cx, 0.0, cz)
		
		if _is_in_water(pos, water_areas, bridges):
			continue
			
		var slope = _sl.call(pos.x, pos.z)
		if slope < 0.55:
			continue
			
		pos.y = _h.call(pos)
		var cliff_yaw = cliff_rng.randf_range(0, TAU)
		var scale_jitter = cliff_rng.randf_range(0.85, 1.25) * prop_scale
		var t = _fast_xform.call(pos, cliff_yaw, scale_jitter)
		
		var tint = Color(
			1.0 + cliff_rng.randf_range(-0.12, 0.12),
			1.0 + cliff_rng.randf_range(-0.12, 0.12),
			1.0 + cliff_rng.randf_range(-0.12, 0.12),
			1.0
		)
		
		if cliff_rng.randf() < 0.30:
			var cc_var = cliff_rng.randi() % CLIFF_CORNER_POOL_SIZE
			cliff_corner_xforms[cc_var].append(t)
			cliff_corner_colors[cc_var].append(tint)
		else:
			var c_var = cliff_rng.randi() % CLIFF_FACE_POOL_SIZE
			cliff_xforms_by_variant[c_var].append(t)
			cliff_colors_by_variant[c_var].append(tint)
		
	await _scatter_slice(ticker, gate)
	await _add_gltf_variant_batches(CLIFF_FACE_MODEL_DIR, CLIFF_FACE_POOL_SIZE, cliff_xforms_by_variant, cliff_colors_by_variant,
		null, null, "Batch_CliffFace", 0.0, 650.0, ticker, gate)
	await _add_gltf_variant_batches(CLIFF_CORNER_MODEL_DIR, CLIFF_CORNER_POOL_SIZE, cliff_corner_xforms, cliff_corner_colors,
		null, null, "Batch_CliffCorner", 0.0, 650.0, ticker, gate)
	
	# --------------------------------------------------------------------------
	# 7. AUTHORED WETLAND REEDS
	# --------------------------------------------------------------------------
	if not water_areas.is_empty() or _has_marsh_zones(surface_zones):
		var reed_xforms_by_variant: Dictionary = {}
		var reed_colors_by_variant: Dictionary = {}
		for v in range(REEDS_POOL_SIZE):
			reed_xforms_by_variant[v] = []
			reed_colors_by_variant[v] = []
			
		var reed_rng = RandomNumberGenerator.new()
		reed_rng.seed = hash(map_name + "_wetland_reeds")
		
		for water in water_areas:
			var c = water.get("center", Vector3.ZERO)
			var he = water.get("half_extents", Vector2(10, 10))
			var perimeter_points = mini(60, int((he.x + he.y) * 1.5))
			for p in range(perimeter_points):
				var side = reed_rng.randi() % 4
				var ox = 0.0
				var oz = 0.0
				match side:
					0:
						ox = reed_rng.randf_range(-he.x, he.x)
						oz = he.y + reed_rng.randf_range(-0.5, 2.0)
					1:
						ox = reed_rng.randf_range(-he.x, he.x)
						oz = -he.y - reed_rng.randf_range(-0.5, 2.0)
					2:
						ox = he.x + reed_rng.randf_range(-0.5, 2.0)
						oz = reed_rng.randf_range(-he.y, he.y)
					3:
						ox = -he.x - reed_rng.randf_range(-0.5, 2.0)
						oz = reed_rng.randf_range(-he.y, he.y)
				var pos = Vector3(c.x + ox, 0.0, c.z + oz)
				pos.y = _h.call(pos)
				var yaw = reed_rng.randf_range(0, TAU)
				var scale_jitter = reed_rng.randf_range(0.8, 1.4) * prop_scale
				var t = _fast_xform.call(pos, yaw, scale_jitter)
				
				var tint = Color(
					1.0 + reed_rng.randf_range(-0.10, 0.10),
					1.0 + reed_rng.randf_range(-0.08, 0.10),
					1.0 + reed_rng.randf_range(-0.12, 0.08),
					1.0
				)
				var r_var = reed_rng.randi() % REEDS_POOL_SIZE
				reed_xforms_by_variant[r_var].append(t)
				reed_colors_by_variant[r_var].append(tint)
				
		var fallback_reed_mesh = _build_reed_mesh(prop_scale)
		var fallback_reed_mat = _get_material(Color(0.28, 0.36, 0.18), 0.75)
		await _scatter_slice(ticker, gate)
		await _add_gltf_variant_batches(REEDS_MODEL_DIR, REEDS_POOL_SIZE, reed_xforms_by_variant, reed_colors_by_variant,
			fallback_reed_mesh, fallback_reed_mat, "Batch_WetlandReeds", 0.0, 250.0, ticker, gate)

static func _is_in_water(pos: Vector3, water_areas: Array, bridges: Array) -> bool:
	for b in bridges:
		var c = b.get("center", Vector3.ZERO)
		var he = b.get("half_extents", Vector2(4, 10))
		if absf(pos.x - c.x) <= he.x and absf(pos.z - c.z) <= he.y:
			return false
	for w in water_areas:
		var c = w.get("center", Vector3.ZERO)
		var he = w.get("half_extents", Vector2(10, 10))
		if absf(pos.x - c.x) <= he.x and absf(pos.z - c.z) <= he.y:
			return true
	return false

static func _has_marsh_zones(surface_zones: Array) -> bool:
	for z in surface_zones:
		if z.get("surface_type", "") == "marsh":
			return true
	return false
