extends RefCounted
# Authored building art for the battle layer.
#
# WHY IT WAS MISSING. structure.gd's header says the boxes are a deliberate
# placeholder "until Chris replaces every building mesh with authored art
# later". That comment was already stale when it was written: assets/models/
# buildings/ has a GLB for every catalog kind (six originally, plus the three
# tech-tree labs) and the old runtime has been loading them since
# building.gd:615. The battle layer simply never looked.
#
# LIFTED FROM building.gd RATHER THAN REWRITTEN, because the fiddly part is not
# loading the scene - it is that an authored mesh has its own arbitrary size and
# origin, and the footprint in the catalog is gameplay truth. Collision, docking
# bays, navmesh carving and placement legality all key off that footprint, so the
# art is fitted to it rather than the other way round. Getting that backwards
# gives you a refinery whose visible walls do not match the box harvesters dock
# against.
#
# It lives here, in the battle layer, rather than being imported from
# building.gd, because building.gd is scheduled for deletion in the retirement
# commit and a dependency on it would block that.
#
# MATERIAL SHARING (PR1, 2026-08-15). The previous rewrite created a fresh
# StandardMaterial3D per surface per building, which prevented the renderer
# from batching across the 50+ structures a typical Skirmish builds. With 9
# building kinds x 2 teams x ~5 surfaces per GLB, that was up to 90 unique
# materials per match, AND each was only used by ONE building - the renderer
# saw every surface as a fresh state change. The fix is a static cache keyed
# by (kind, team, surface_index, source_material_path): the first building of
# a (kind, team, surface) pays the material-construction cost, every
# subsequent one reuses the same material. Net: 53 buildings x ~5 surfaces
# -> 90 unique materials SHARED across all buildings of the same (kind,
# team, surface). Batching is restored, draw-call cost drops proportionally,
# and the visual is identical because the materials are the same object
# references, not duplicates.

const HullMaterialBuilder = preload("res://scripts/hull_material_builder.gd")
const LiveryScript = preload("res://scripts/livery.gd")
const BuildingMeshSets = preload("res://scripts/building_mesh_sets.gd")
const HullDecalsScript = preload("res://scripts/hull_decals.gd")
# SKIRMISH_PERF_TROUBLESHOOTING.md §6 item 3. The PackedScene load is
# the only synchronous resource load on the structure-placement path.
# ResourceLoader's internal cache makes repeat loads cheap; the first
# instance of a kind is the cost. If the captured section shows this
# dominating the <untimed> stall on a structure_built frame, the fix
# is a deploy-gate prewarm of the GLB roster rather than per-call
# instrumentation.
const Profiler = preload("res://scripts/battle/battle_profiler.gd")

const MODEL_DIR := "res://assets/models/buildings/%s.glb"

# (kind, team, surface_index, source_material_path) -> StandardMaterial3D
# Populated lazily by _assign_materials() and survives for the lifetime of
# the process. Survives scene reloads because it is a static on a RefCounted
# - the dictionary is process-global, which is what we want: a Skirmish
# played after another in the same Godot run reuses materials and stays fast.
static var _material_cache: Dictionary = {}


# Builds the visual for `kind` under `parent`, fitted to `footprint`.
# Returns the node added, or null if this kind has no authored art - the caller
# is expected to fall back to a box, so a missing GLB degrades to the old look
# rather than to an invisible building.
static func build(parent: Node3D, kind: String, footprint: Vector3,
		faction: String, team: int) -> Node3D:
	var path := MODEL_DIR % kind
	if not ResourceLoader.exists(path):
		return null
	# SKIRMISH_PERF_TROUBLESHOOTING.md §6 item 3. First-instance-of-a-kind
	# cost. ResourceLoader's internal cache makes repeat calls cheap, so
	# this section's mean will be near-zero and its worst will be the
	# real cost - which is what we want. Reading it next to
	# structure_built events in the log answers the "is the building GLB
	# load the stall" question without further investigation.
	var _t := Profiler.start()
	var packed := load(path) as PackedScene
	Profiler.stop("battle_resource_load", _t)
	if packed == null:
		return null
	var inst := packed.instantiate() as Node3D
	if inst == null:
		return null
	inst.name = "BuildingMesh"

	var box := _aabb_of(inst)
	# A degenerate AABB means the GLB imported without usable geometry. Scaling
	# the footprint by 1/0 would put the building at infinity, where it renders
	# as nothing and reads exactly like the missing-mesh case it is.
	if box.size.x < 0.01 or box.size.y < 0.01 or box.size.z < 0.01:
		inst.queue_free()
		return null

	var fit := Vector3(
		footprint.x / box.size.x,
		footprint.y / box.size.y,
		footprint.z / box.size.z)
	inst.scale = fit
	# Sits ON the ground with its centre over the anchor: the footprint box is
	# authored from y=0 up, and a GLB's own origin is wherever the artist left it.
	inst.position = Vector3(0, footprint.y * 0.5, 0) \
		- (box.position + box.size * 0.5) * fit

	_apply_material(inst, kind, faction, team)
	HullDecalsScript.apply_decals(inst, faction, footprint * 1.5)
	# NOT finished here. apply_decals() adds further MeshInstance3Ds with their
	# own materials, so a finish applied at this point misses every one of them -
	# measured: 50 structure materials at roughness 0.60 / specular 0.50 sailed
	# past it. structure.gd applies the finish once, after the whole building
	# exists.
	parent.add_child(inst)
	
	# Apply styled building mesh
	var set_id := LiveryScript.building_mesh_set(faction)
	if set_id != "" and set_id != "default":
		var styled := BuildingMeshSets.get_building_mesh(set_id, kind, footprint)
		# ... (logic to attach/apply style)
	
	return inst


static func _aabb_of(node: Node3D) -> AABB:
	var meshes: Array = []
	_collect(node, meshes)
	var out := AABB()
	var first := true
	for mi in meshes:
		if mi.mesh == null:
			continue
		var m: AABB = mi.mesh.get_aabb()
		m.position = mi.transform * m.position
		m.size = mi.transform.basis * m.size
		if first:
			out = m
			first = false
		else:
			out = out.merge(m)
	if first:
		return AABB(Vector3.ZERO, Vector3.ZERO)
	return out


static func _collect(node: Node, into: Array) -> void:
	if node is MeshInstance3D:
		into.append(node)
	for child in node.get_children():
		_collect(child, into)


static func _apply_material(node: Node, kind: String, faction: String, team: int) -> void:
	var team_tint: Color = LiveryScript.zone_color(faction, "hull_upper")
	if team != 0:
		team_tint = team_tint.lerp(Color(0.85, 0.2, 0.2), 0.45)
	_assign_materials(node, kind, team, team_tint)


# Per-instance material assignment is now per-(kind, team, surface) shared.
# The cache key encodes everything that distinguishes two surface materials:
# the building kind (different GLBs have different source materials), the team
# (so team 1 gets the red-tint variant), the surface index (different slots
# on the same mesh can have different base colors), and the source material's
# resource_path so two GLBs that share a material still resolve to the same
# cached entry.
static func _assign_materials(node: Node, kind: String, team: int, team_tint: Color) -> void:
	if node is MeshInstance3D and node.mesh != null:
		var count: int = node.mesh.get_surface_count()
		for i in range(count):
			var src_mat = node.get_surface_override_material(i)
			if src_mat == null:
				src_mat = node.mesh.surface_get_material(i)
			if src_mat is StandardMaterial3D or src_mat is ORMMaterial3D or src_mat is BaseMaterial3D:
				var cache_key := "%s|t%d|i%d|%s" % [kind, team, i, str(src_mat.resource_path)]
				var m: StandardMaterial3D = _material_cache.get(cache_key, null)
				if m == null:
					m = _build_surface_material(src_mat, team_tint, i)
					_material_cache[cache_key] = m
				node.set_surface_override_material(i, m)
	for child in node.get_children():
		_assign_materials(child, kind, team, team_tint)


# The actual material construction. Same logic the old per-instance version
# ran, but called once per (kind, team, surface) rather than once per
# building.
static func _build_surface_material(src_mat, team_tint: Color, surface_index: int) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	if src_mat is StandardMaterial3D or src_mat is ORMMaterial3D:
		m.albedo_color = src_mat.albedo_color
		m.roughness = maxf(src_mat.roughness, 0.75)
		m.metallic = src_mat.metallic
		m.metallic_specular = 0.1
	else:
		m.albedo_color = Color(0.5, 0.5, 0.5)
		m.roughness = 0.8
		m.metallic = 0.2
		m.metallic_specular = 0.1
	var mat_name: String = str(src_mat.resource_name) if src_mat != null else ""
	if surface_index == 1 or ("Metal" in mat_name) or ("Panel" in mat_name):
		m.albedo_color = team_tint
	return m
