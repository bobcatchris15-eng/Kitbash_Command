extends Control

const ModuleCatalog = preload("res://scripts/module_catalog.gd")
const VisualBuilder = preload("res://scripts/visual_builder.gd")
const MeshAssetLoader = preload("res://scripts/mesh_asset_loader.gd")

var ghost_mesh: Node3D = null
var ghost_mesh_mirror: Node3D = null
var current_ghost_type: String = ""
# Cached "where the bottom of this part's visual is" in module-local space.
# Recomputed only when the type_id changes, not every mouse move - the
# same part dragged across the whole hull has the same AABB.
var _ghost_visual_bottom_y: float = 0.0
# Whether the ghost, as last previewed, overlapped something already on the
# hull - i.e. whether the player is currently looking at a RED ghost.
#
# Cached rather than recomputed at drop time on purpose. The drop must refuse
# exactly when the preview said it would, and the only way to guarantee that is
# to reuse the identical answer rather than ask the same question twice from a
# slightly different transform. Recomputing gave "it was red but it placed
# anyway" on the boundary cases, which is the worst possible read.
var _ghost_is_clipping: bool = false
var _cached_ghost_material: Material = null
var _ghost_shader: Shader = null

func _get_ghost_shader() -> Shader:
	if _ghost_shader != null:
		return _ghost_shader

	var shader = Shader.new()
	shader.code = """
shader_type spatial;
render_mode unshaded, blend_mix, depth_draw_always, cull_back;

uniform vec4 line_color : source_color = vec4(0.95, 0.95, 0.55, 0.9);

void fragment() {
	float NdotV = abs(dot(NORMAL, VIEW));
	float fresnel = pow(1.0 - clamp(NdotV, 0.0, 1.0), 2.0);
	float line_alpha = smoothstep(0.10, 0.55, fresnel);

	ALBEDO = line_color.rgb;
	ALPHA = line_alpha;
}
"""
	_ghost_shader = shader
	return _ghost_shader

# Ghost material the rest of the lab reads as "preview, not real".
#
# Earlier: 0.42 alpha teal-green across the whole part. The player could
# not tell a placed module from the ghost preview at a glance - they were
# both dim teal blobs, with the ghost being a thinner blob because the
# mesh's thin barrel is barely visible through 42% alpha. The "the
# autocannon ghost is just a plain box" symptom was this: the part's
# actual mesh was being drawn, but at 42% on a thin barrel over a
# textured hull it visually collapsed to a smudge.
#
# Now: catalog color at 0.78 alpha (still translucent, so the player can
# see the hull surface through the part - "where it will land" stays a
# read, not a paint-over) plus the edge contour at a brighter outline
# yellow that survives against a busy hull. Same family as the green
# material the firing arc uses; the interface is signalling "this is
# metadata, not a real object" by the same colour cue throughout.
func _get_foggy_part_material() -> Material:
	if _cached_ghost_material != null:
		return _cached_ghost_material

	var foggy_mat = StandardMaterial3D.new()
	foggy_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	foggy_mat.albedo_color = Color(0.10, 0.26, 0.20, 0.78)
	foggy_mat.roughness = 0.2
	foggy_mat.depth_draw_mode = BaseMaterial3D.DEPTH_DRAW_ALWAYS
	foggy_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED

	# Feature Edge Contour Pass (renders clean vector lines around part contours, avoiding micro-triangle shell clutter)
	var edge_mat = ShaderMaterial.new()
	edge_mat.shader = _get_ghost_shader()

	foggy_mat.next_pass = edge_mat
	_cached_ghost_material = foggy_mat
	return _cached_ghost_material

var _cached_invalid_material: Material = null

func _get_invalid_part_material() -> Material:
	if _cached_invalid_material != null:
		return _cached_invalid_material

	var invalid_mat = StandardMaterial3D.new()
	invalid_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	invalid_mat.albedo_color = Color(1.0, 0.1, 0.1, 0.78)
	invalid_mat.roughness = 0.2
	invalid_mat.depth_draw_mode = BaseMaterial3D.DEPTH_DRAW_ALWAYS
	invalid_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED

	var edge_mat = ShaderMaterial.new()
	var shader = Shader.new()
	shader.code = """
shader_type spatial;
render_mode unshaded, blend_mix, depth_draw_always, cull_back;
uniform vec4 line_color : source_color = vec4(1.0, 0.2, 0.2, 0.9);
void fragment() {
	float NdotV = abs(dot(NORMAL, VIEW));
	float fresnel = pow(1.0 - clamp(NdotV, 0.0, 1.0), 2.0);
	float line_alpha = smoothstep(0.10, 0.55, fresnel);
	ALBEDO = line_color.rgb;
	ALPHA = line_alpha;
}
"""
	edge_mat.shader = shader
	invalid_mat.next_pass = edge_mat
	_cached_invalid_material = invalid_mat
	return _cached_invalid_material

func _apply_ghost_materials_recursive(node: Node, mat: Material):
	if node is MeshInstance3D:
		(node as MeshInstance3D).material_override = mat
	for child in node.get_children():
		_apply_ghost_materials_recursive(child, mat)

func _build_module_ghost_node(type_id: String) -> Node3D:
	# VisualBuilder.build_module() is the shared version of what used to be
	# inlined here - same node, same "module_data" ModuleData payload, same
	# missing-mesh box fallback. It also builds the visual in the CATALOG's own
	# colour rather than Color.WHITE, which is what stopped every ghost being
	# the same washed-out teal: the player could not tell an autocannon from a
	# radar mast from a missile pod without stopping to read the parts menu.
	#
	# The only thing left here is the ghost material, which is this drag
	# preview's business and not the builder's.
	var container := VisualBuilder.build_module(type_id)
	_apply_ghost_materials_recursive(container, _get_foggy_part_material())
	return container

func _build_hull_ghost_node(type_id: String) -> Node3D:
	var container = Node3D.new()
	var catalog_data = ModuleCatalog.get_module_data(type_id)
	var cat_size = catalog_data.get("size", Vector3.ONE)

	var hull_mesh = MeshAssetLoader.get_hull_mesh(type_id)
	var mi = MeshInstance3D.new()
	if hull_mesh != null:
		mi.mesh = hull_mesh
	else:
		var box = BoxMesh.new()
		box.size = cat_size
		mi.mesh = box
	container.add_child(mi)

	_apply_ghost_materials_recursive(container, _get_foggy_part_material())
	return container

# Called by the parts menu as soon as the cursor leaves the toolbox during a drag,
# so the 3D ghost appears the moment the user moves toward the viewport.
func show_ghost_for_drag(type_id: String, screen_pos: Vector2) -> void:
	if type_id.is_empty():
		return
	var catalog_data = ModuleCatalog.get_module_data(type_id)
	if catalog_data.is_empty():
		return
	var category = catalog_data.get("category", "module")
	var root = get_node_or_null("/root/MainLab")
	if not root:
		return
	if category == "hull":
		_update_ghost_mesh_hull(type_id)
	else:
		if root.get_node_or_null("Hull") != null:
			_update_ghost_mesh(screen_pos, type_id)

func _can_drop_data(at_position: Vector2, data: Variant) -> bool:
	if typeof(data) == TYPE_DICTIONARY and data.has("type") and data["type"] == "module_part":
		var type_id = data["id"]
		var catalog_data = ModuleCatalog.get_module_data(type_id)
		var category = catalog_data.get("category", "module")

		var root = get_node("/root/MainLab")
		if category == "hull":
			_update_ghost_mesh_hull(type_id)
			return true

		# Normal modules require a hull to exist first!
		if not root or root.get_node_or_null("Hull") == null:
			_destroy_ghost_mesh()
			return false

		# Normal modules require raycast
		_update_ghost_mesh(at_position, type_id)
		return true

	_destroy_ghost_mesh()
	return false

func _drop_data(at_position: Vector2, data: Variant):
	# Read BEFORE _destroy_ghost_mesh(), which clears it. This is the state the
	# player was actually looking at when they let go of the mouse.
	var was_clipping := _ghost_is_clipping
	_destroy_ghost_mesh()

	if typeof(data) == TYPE_DICTIONARY and data.has("type") and data["type"] == "module_part":
		var type_id = data["id"]
		var catalog_data = ModuleCatalog.get_module_data(type_id)
		var category = catalog_data.get("category", "module")

		var root = get_node("/root/MainLab")
		if category == "hull":
			if root:
				# clear_hull() detaches and frees the old hull IMMEDIATELY.
				if root.has_method("clear_hull"):
					root.clear_hull()
				if root.has_method("_place_hull_from_ui"):
					root._place_hull_from_ui(type_id)
		else:
			if root and root.has_method("_place_weapon_from_ui"):
				var result = _raycast_from_screen(at_position)
				if result:
					root._place_weapon_from_ui(type_id, result.position, result.normal, was_clipping)

func _collapse_parts_menu():
	var root = get_node_or_null("/root/MainLab")
	if root:
		var parts_menu = root.get_node_or_null("UI_PartsMenu")
		if parts_menu and parts_menu.has_method("collapse_all_drawers"):
			parts_menu.collapse_all_drawers()

func _update_ghost_mesh_hull(type_id: String):
	var root = get_node_or_null("/root/MainLab")
	if not root: return

	if current_ghost_type != type_id or ghost_mesh == null:
		_destroy_ghost_mesh()
		ghost_mesh = _build_hull_ghost_node(type_id)
		root.add_child(ghost_mesh)
		current_ghost_type = type_id
		# Hull is centred on its own origin (the catalog `size` is its
		# box, not its base). Lift it by half its height so the bottom
		# of the hull sits on the ground plane, matching the placement
		# code in _place_hull_from_ui().
		var catalog_data = ModuleCatalog.get_module_data(type_id)
		_ghost_visual_bottom_y = -catalog_data.get("size", Vector3.ONE).y / 2.0

	ghost_mesh.visible = true
	ghost_mesh.position = Vector3(0, -_ghost_visual_bottom_y, 0)

# Helper to create/update the ghost mesh preview
func _update_ghost_mesh(screen_pos: Vector2, type_id: String):
	var result = _raycast_from_screen(screen_pos)
	if not result:
		if ghost_mesh: ghost_mesh.visible = false
		if ghost_mesh_mirror: ghost_mesh_mirror.visible = false
		# Nothing under the cursor is not the same as "clipping". Clearing it
		# keeps a stale red from an earlier hover out of the next drop.
		_ghost_is_clipping = false
		return

	var root = get_node_or_null("/root/MainLab")
	if not root: return

	if current_ghost_type != type_id or ghost_mesh == null:
		_destroy_ghost_mesh()
		ghost_mesh = _build_module_ghost_node(type_id)
		root.add_child(ghost_mesh)
		current_ghost_type = type_id
		# Cache the visual's bottom-Y in the module's own local frame. The
		# module's local origin is conventionally at the bottom of its
		# mount/base, so the bottom is 0 for everything that has a mount
		# at y=0 (most weapons and support modules) and a non-zero value
		# for the few parts whose bottom is offset (sensor masts that
		# float above a base ring, etc.). Measured from the actually-built
		# visual, not from the catalog `size` - the two disagree for
		# every authored weapon because the catalog box is a fitting
		# envelope, not the actual mesh AABB.
		#
		# Old code: position = result + Vector3(0, cat_size.y/2, 0),
		# i.e. the ghost was placed so its AABB CENTRE was at the surface
		# plus half the catalog height. For a 0.3-high HMG that lifted
		# the ghost 0.15 above the surface, which combined with the
		# visual AABB being centred slightly above y=0 (the receiver
		# top is around y=0.28) put the ghost entirely above the hull
		# instead of on it. This measured-from-visual path is the fix.
		var aabb := _ghost_visual_aabb(ghost_mesh)
		_ghost_visual_bottom_y = aabb.position.y if aabb.size.length_squared() > 0.0 else 0.0

	ghost_mesh.visible = true
	# The placement normal in the module's local frame is +Y (mount
	# axis), so the offset the ghost needs is along its own +Y. The
	# surface position from the raycast is the CONTACT point, and the
	# ghost's local origin sits at the bottom of the mount, so we lift
	# the ghost by however far the visual's bottom is above the
	# local origin.
	ghost_mesh.position = result.position + Vector3(0, _ghost_visual_bottom_y, 0)

	# Apply the same mount + bottom-facet-flip transform the placer uses,
	# so the ghost preview shows the module's correct orientation before the
	# drop rather than the ghost-builder's default upright frame.
	var hull_ghost: Node3D = null
	if root and root.has_method("ghost_mount_transform") and root.has_node("Hull"):
		hull_ghost = root.get_node("Hull")
		if hull_ghost:
			var local_normal: Vector3 = hull_ghost.global_transform.basis.inverse() * result.normal
			var mount_xf: Transform3D = root.ghost_mount_transform(
				hull_ghost.to_local(result.position), local_normal, type_id)
			ghost_mesh.transform.basis = mount_xf.basis
			if local_normal.y < -0.7:
				ghost_mesh.transform.basis = ghost_mesh.transform.basis * Basis(Vector3.UP, PI)
	
	# ASK THE PLACER, don't re-derive. This used to test
	# `catalog_data.get("is_symmetric", true)`, a key no catalog entry defines -
	# so the preview showed a mirrored copy for no part in the game, while the
	# placer went on to mirror nearly everything. See would_mirror().
	var category := str(catalog_data_for(type_id).get("category", "module"))
	var will_mirror: bool = root.would_mirror(category, result.position, result.normal) \
		if root.has_method("would_mirror") else false
	if will_mirror and abs(result.position.x) > 0.1:
		if ghost_mesh_mirror == null:
			ghost_mesh_mirror = _build_module_ghost_node(type_id)
			root.add_child(ghost_mesh_mirror)
		ghost_mesh_mirror.visible = true
		ghost_mesh_mirror.position = Vector3(-result.position.x, ghost_mesh.position.y, result.position.z)
		# Same mount + bottom-facet-flip as the primary ghost.
		if hull_ghost:
			var mirrored_normal := Vector3(-result.normal.x, result.normal.y, result.normal.z)
			var local_mirrored_normal: Vector3 = hull_ghost.global_transform.basis.inverse() * mirrored_normal
			var mirrored_local_pos := hull_ghost.to_local(result.position)
			mirrored_local_pos.x = -mirrored_local_pos.x
			var mirror_xf: Transform3D = root.ghost_mount_transform(
				mirrored_local_pos, local_mirrored_normal, type_id)
			ghost_mesh_mirror.transform.basis = mirror_xf.basis
			if local_mirrored_normal.y < -0.7:
				ghost_mesh_mirror.transform.basis = ghost_mesh_mirror.transform.basis * Basis(Vector3.UP, PI)
	else:
		if ghost_mesh_mirror:
			ghost_mesh_mirror.visible = false
			
	var is_clipping = false
	if root.has_method("is_ghost_clipping"):
		# The ghost NODE goes with the transform. The ghost is a real built
		# module tree, so passing it lets the test measure its actual meshes
		# instead of a catalog-sized box - which is what makes the red preview
		# agree with the verdict check_all_clipping() reaches about the same
		# part once it is placed.
		is_clipping = root.is_ghost_clipping(ghost_mesh.transform, type_id, ghost_mesh)
		if not is_clipping and ghost_mesh_mirror and ghost_mesh_mirror.visible:
			is_clipping = root.is_ghost_clipping(
				ghost_mesh_mirror.transform, type_id, ghost_mesh_mirror)

	if not is_clipping and root.has_method("_placement_refusal_reason"):
		var refusal: String = root._placement_refusal_reason(type_id, category, result.normal)
		if refusal != "":
			is_clipping = true

	_ghost_is_clipping = is_clipping

	if is_clipping:
		_apply_ghost_materials_recursive(ghost_mesh, _get_invalid_part_material())
		if ghost_mesh_mirror and ghost_mesh_mirror.visible:
			_apply_ghost_materials_recursive(ghost_mesh_mirror, _get_invalid_part_material())
	else:
		_apply_ghost_materials_recursive(ghost_mesh, _get_foggy_part_material())
		if ghost_mesh_mirror and ghost_mesh_mirror.visible:
			_apply_ghost_materials_recursive(ghost_mesh_mirror, _get_foggy_part_material())
			
	var lab_doc = root.get_node_or_null("LabDocument")
	if lab_doc and lab_doc.telemetry_rail:
		lab_doc.telemetry_rail.update_preview_stats(ghost_mesh, ghost_mesh_mirror)

func catalog_data_for(type_id: String) -> Dictionary:
	return ModuleCatalog.get_module_data(type_id)

func _ghost_visual_aabb(node: Node3D) -> AABB:
	# Walk every MeshInstance3D under the ghost, transform each mesh's
	# AABB by its world transform, and merge. Same walk
	# measure_visual_bounds() does, but written here against the ghost
	# rather than reaching into VisualBuilder - the ghost has its own
	# material overrides and possible fallback box, so passing a
	# different subtree to the existing helper would mean carving up
	# that helper's API.
	var bounds := AABB()
	var seen := false
	for mi in node.find_children("*", "MeshInstance3D", true, false):
		if mi.mesh == null:
			continue
		var xf := Transform3D.IDENTITY
		var walker: Node = mi
		while walker != null and walker != node:
			if walker is Node3D:
				xf = walker.transform * xf
			walker = walker.get_parent()
		var part: AABB = xf * mi.mesh.get_aabb()
		bounds = part if not seen else bounds.merge(part)
		seen = true
	return bounds

func _notification(what: int):
	if what == NOTIFICATION_DRAG_END:
		_destroy_ghost_mesh()
		# THE FACET HIGHLIGHT IS CLEARED HERE, NOT IN _destroy_ghost_mesh().
		#
		# MainLab.surface_raycast() shows the highlight as a side effect of every
		# successful ray, which is what makes it track the cursor while a part is
		# being dragged over the hull. Nothing turned it back off on this path, so
		# after a drop the highlighted facet stayed lit for the rest of the
		# session (Chris, 2026-08-12: "the facet gets highlighted, and the
		# highlight never goes away"). Re-dragging an ALREADY-PLACED module did
		# clear it - module_placer.gd hides it on drag finish and cancel - which
		# is why this only showed up when placing something new.
		#
		# It has to be this notification and not _destroy_ghost_mesh(), even
		# though that is the other "the preview is over" hook: _drop_data() calls
		# _destroy_ghost_mesh() FIRST and then raycasts again to find the drop
		# point, so hiding it there would be immediately undone by the very drop
		# that needs it cleared. DRAG_END fires after _drop_data() returns, and
		# fires on a cancelled drag too, so it covers both exits.
		var root = get_node_or_null("/root/MainLab")
		if root and root.has_method("_hide_facet_highlight"):
			root._hide_facet_highlight()

func _destroy_ghost_mesh():
	var cleared_something = false
	if ghost_mesh:
		ghost_mesh.queue_free()
		ghost_mesh = null
		cleared_something = true
	if ghost_mesh_mirror:
		ghost_mesh_mirror.queue_free()
		ghost_mesh_mirror = null
		cleared_something = true
	current_ghost_type = ""
	_ghost_visual_bottom_y = 0.0
	_ghost_is_clipping = false
	
	if cleared_something:
		var root = get_node_or_null("/root/MainLab")
		if root:
			var lab_doc = root.get_node_or_null("LabDocument")
			if lab_doc and lab_doc.telemetry_rail:
				lab_doc.telemetry_rail.clear_preview()

func _raycast_from_screen(screen_pos: Vector2):
	var camera = get_viewport().get_camera_3d()
	if not camera: return null

	var ray_origin = camera.project_ray_origin(screen_pos)
	var ray_dir = camera.project_ray_normal(screen_pos)
	var root = get_node_or_null("/root/MainLab")

	# Prefer module_placer's precise-surface raycast so a dropped part lands on
	# the hull's visible skin. Hitting only the hull's bounding box (which is
	# what a plain layer-1 query returns) left parts floating wherever the mesh
	# curves away from that box.
	if root and root.has_method("surface_raycast"):
		var precise = root.surface_raycast(ray_origin, ray_dir)
		if precise:
			return precise

	var space_state = get_node("/root/MainLab").get_world_3d().direct_space_state
	var query = PhysicsRayQueryParameters3D.create(ray_origin, ray_origin + ray_dir * 1000.0)
	query.collision_mask = 3 # Hits Hull (1) and Modules (2)
	return space_state.intersect_ray(query)
