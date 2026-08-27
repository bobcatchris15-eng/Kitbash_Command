extends Node3D
# ONE DRAW CALL PER TREE SPECIES INSTEAD OF ONE PER TREE.
#
# The ambient scatter (terrain_builder.gd's _spawn_ambient_trees /
# _spawn_ambient_ores, up to 1000 trees + 800 ore) used to instantiate a full
# glTF subtree per scattered item. Measured on a built skirmish world with
# tools/probe_skirmish_census.gd, BEFORE a single unit spawns:
#
#     nodes 6977 | meshinst 2560 (surfaces 4292) | multimesh 0
#
# 4292 surfaces is 4292 draw calls of decorative scenery, submitted every
# frame, on a top-down camera that has most of the map on screen at once so
# frustum culling reclaims very little. That is the render-side half of the
# skirmish slowdown; the CPU half was the matching 1895 no-op _physics_process
# dispatches (see resource_node.gd setup()'s note).
#
# Nothing about a scattered tree varies per instance except its transform,
# which is exactly what MultiMesh is for - the same reasoning greeble_field.gd
# already applies to hull rivets, just at map scale.
#
# WHY THE ResourceNode STAYS. Only the VISUAL moves here. Each scattered item
# keeps its own ResourceNode (group membership, amount, harvest(), the
# no-regrow contract), because that is real gameplay state a harvester queries
# per item and it cannot be flattened into a vertex buffer. What the node
# loses is its own MeshInstance3D subtree; it gets a handle into a batch
# instead and drives its instance's transform through set_node_transform().
#
# ORDERING CONTRACT: register() during the scatter pass, then commit() ONCE.
# Registering after commit() is a no-op and pushes an error - the MultiMesh
# instance buffers are sized at commit time, and growing them per late arrival
# would reallocate the whole buffer on the RenderingServer for every one.
#
# register() takes the NODE, not a transform, and commit() reads
# global_transform off it at commit time. That is deliberate: terrain_greebles.
# gd's spawn_ambient_tree() applies its per-instance yaw AFTER setup() returns,
# so a transform captured during registration would bake in the pre-yaw pose
# and the whole forest would face the same way. Reading at commit means
# "however the scatter pass finally left this node" is what gets baked, with no
# ordering contract on the caller at all.

# Harvested from one throwaway instantiation of each distinct scatter scene:
# the flattened list of {mesh, local transform} that its glTF subtree
# contains. Instantiating the PackedScene once per SPECIES instead of once per
# TREE is itself a large chunk of the map-build time this replaces.
# Deliberately no `class_name` (project gotcha: class_name globals are not
# reliable in scripts run headless before the .godot cache exists) - reached
# through this helper off the node the scatter is being parented to, which is
# the only handle resource_node.gd has at setup() time.
const NODE_NAME := "AmbientScatter"

static func get_or_create(parent: Node) -> Node:
	if parent == null:
		return null
	var existing := parent.get_node_or_null(NODE_NAME)
	if existing != null:
		return existing
	var batcher = (load("res://scripts/ambient_scatter.gd") as GDScript).new()
	batcher.name = NODE_NAME
	parent.add_child(batcher)
	return batcher


static var _templates: Dictionary = {}      # scene_path -> Array[{mesh, xform, material}]
var _pending: Dictionary = {}        # scene_path -> Array[Node3D]
var _batches: Dictionary = {}        # scene_path -> Array[MultiMeshInstance3D]
var _committed: bool = false


# Returns a handle the caller keeps and hands back to set_node_transform().
# Null when the scene has no drawable geometry at all, so a caller can fall
# back to its own mesh path rather than silently rendering nothing.
func register(scene_path: String, node: Node3D):
	if _committed:
		push_error("AmbientScatter.register() after commit() - ignored: " + scene_path)
		return null
	if not _templates.has(scene_path):
		var t := _build_template(scene_path)
		if t.is_empty():
			return null
		_templates[scene_path] = t
	if not _pending.has(scene_path):
		_pending[scene_path] = []
	var slot: int = _pending[scene_path].size()
	_pending[scene_path].append(node)
	return {"path": scene_path, "slot": slot}


func commit() -> void:
	if _committed:
		return
	_committed = true
	for path in _pending:
		var nodes: Array = _pending[path]
		if nodes.is_empty():
			continue
		var xforms: Array = []
		for n in nodes:
			xforms.append(_world_xform(n))
		var parts: Array = _templates[path]
		var made: Array[MultiMeshInstance3D] = []
		for part in parts:
			var mm := MultiMesh.new()
			mm.transform_format = MultiMesh.TRANSFORM_3D
			mm.mesh = part["mesh"]
			mm.instance_count = xforms.size()
			var local: Transform3D = part["xform"]
			for i in range(xforms.size()):
				mm.set_instance_transform(i, (xforms[i] as Transform3D) * local)
			var mmi := MultiMeshInstance3D.new()
			mmi.multimesh = mm
			if part.has("material") and part["material"] != null:
				mmi.material_override = part["material"]
			mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
			mmi.name = "Scatter_%s_%d" % [path.get_file().get_basename(), made.size()]
			add_child(mmi)
			made.append(mmi)
		_batches[path] = made


# Re-place one scattered item - used for the depletion shrink. Scaling to zero
# is how an item is removed: MultiMesh has no per-instance visibility flag and
# resizing instance_count would renumber every slot after it, invalidating
# every other node's handle.
func set_node_transform(handle, xform: Transform3D) -> void:
	if handle == null or not _committed:
		return
	var path: String = handle["path"]
	if not _batches.has(path):
		return
	var slot: int = handle["slot"]
	var parts: Array = _templates[path]
	var mmis: Array = _batches[path]
	for i in range(mmis.size()):
		var mm: MultiMesh = (mmis[i] as MultiMeshInstance3D).multimesh
		if slot < mm.instance_count:
			mm.set_instance_transform(slot, xform * (parts[i]["xform"] as Transform3D))


# global_transform is only valid once the tree has PROPAGATED one, and a world
# built in a single call has not stepped a frame yet - so a whole scatter pass
# committed as identity and stacked every prop at the origin, invisibly, while
# pushing one "!is_inside_tree()" error per prop. Composing the local chain by
# hand gives the same answer with no dependency on frame timing.
static func _world_xform(n) -> Transform3D:
	if not is_instance_valid(n):
		return Transform3D().scaled(Vector3.ZERO)
	var node := n as Node3D
	if node == null:
		return Transform3D()
	if node.is_inside_tree():
		return node.global_transform
	var x := Transform3D.IDENTITY
	var cur: Node = node
	while cur is Node3D:
		x = (cur as Node3D).transform * x
		cur = cur.get_parent()
	return x


# One surface out of a multi-surface mesh, as its own single-surface mesh.
#
# MultiMeshInstance3D carries ONE material_override for the whole MultiMesh and
# does NOT implement per-surface overrides (GeometryInstance3D's
# surface_override_material_count is overridden by MeshInstance3D, not by
# MultiMeshInstance3D, so it reports 0). Batching a 2-surface mesh whole
# therefore paints the canopy with the TRUNK's material - which is precisely
# why every scattered tree rendered as a solid bark-coloured lollipop: white
# for the birches (bark albedo 0.72), orange for the pines (0.34, 0.22, 0.12).
# The canopy geometry and its leaf material were both there and neither was
# ever drawn. Splitting per surface is what lets each keep its own material.
static func _surface_mesh(src: Mesh, index: int) -> Mesh:
	if src.get_surface_count() <= 1:
		return src
	var out := ArrayMesh.new()
	out.add_surface_from_arrays(src.surface_get_primitive_type(index),
		src.surface_get_arrays(index))
	return out


func _build_template(scene_path: String) -> Array:
	if not ResourceLoader.exists(scene_path):
		return []
	var packed := load(scene_path) as PackedScene
	if packed == null:
		return []
	var probe := packed.instantiate() as Node3D
	if probe == null:
		return []
	var parts: Array = []
	var stack: Array = [{"node": probe, "xform": Transform3D.IDENTITY}]
	# MATERIAL CACHE (PR1, 2026-08-15). The previous rewrite created a fresh
	# StandardMaterial3D per part per template, which destroyed the batching
	# the MultiMesh was set up to deliver - a 9-species forest with 2 parts
	# each was 18 unique materials and 18 separate draw calls. Now: one
	# "matte" material per template (per glTF source), shared across every
	# part that resolves to the same source material. Same visual, 1/3 the
	# material count, full batching.
	var scene_materials: Dictionary = {}
	while not stack.is_empty():
		var entry: Dictionary = stack.pop_back()
		var node: Node = entry["node"]
		var xform: Transform3D = entry["xform"]
		if node is Node3D:
			xform = xform * (node as Node3D).transform
		for c in node.get_children():
			stack.append({"node": c, "xform": xform})
		if node is MeshInstance3D and node.mesh != null:
			# ONE PART PER SURFACE. See _surface_mesh() - batching a multi-
			# surface mesh as a unit silently repaints every surface with the
			# first one's material.
			var src_mesh: Mesh = node.mesh
			for si in range(maxi(src_mesh.get_surface_count(), 1)):
				var mat: Material = node.material_override
				if mat == null and si < node.get_surface_override_material_count():
					mat = node.get_surface_override_material(si)
				if mat == null and si < src_mesh.get_surface_count():
					mat = src_mesh.surface_get_material(si)

				# Key by source material's resource path so two parts that share
				# the same glTF material resolve to the same cached StandardMaterial3D.
				# Falls back to the instance id: the glTF importer leaves
				# embedded materials with an EMPTY resource_path, so keying on
				# path alone collapsed bark and foliage onto one key and undid
				# the split above.
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
							# Backlight REMOVED: StandardMaterial3D backlight adds a
							# translucent rim glow that makes foliage look like shiny
							# plastic at RTS zoom. Leaves should be matte.
					else:
						matte_mat.albedo_color = Color(0.22, 0.28, 0.18)
					matte_mat.roughness = 1.0
					matte_mat.metallic = 0.0
					matte_mat.metallic_specular = 0.0
					matte_mat.specular = 0.0
					scene_materials[mat_key] = matte_mat

				parts.append({
					"mesh": _surface_mesh(src_mesh, si),
					"xform": xform,
					"material": scene_materials[mat_key],
				})
	probe.free()
	return parts
