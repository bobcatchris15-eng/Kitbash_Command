extends StaticBody3D
const Profiler = preload("res://scripts/battle/battle_profiler.gd")
# One harvestable collectible: a rock, a crystal cluster, a tree, a well.
#
# WHAT CHANGED, 2026-08-07. These used to BE the deposit - one node at one
# coordinate holding the whole 1,100 units of ore, which made a "field" a single
# point four trucks queued at and shoved over. They are now the scattered
# children of resource_field.gd, which spawns them around a centre and replaces
# them as they are worked out.
#
# resource_type is a ResourceCatalog id: "ore" (alias "metal"), "crystal",
# "lumber" or "oil". Appearance and colour come from the catalog rather than from
# an if/else chain here, so adding a fifth resource does not mean editing this
# file.

const ResourceCatalogScript = preload("res://scripts/battle/economy/resource_catalog.gd")
const AmbientScatterScript = preload("res://scripts/ambient_scatter.gd")

var resource_type: String = "metal"
var amount: int = 1000
var start_amount: int = 1000

# Node3D, not MeshInstance3D: an authored pool asset (see AUTHORED_POOL_SIZE
# below) is instantiated whole, and its root may carry its own child
# MeshInstance3D(s) with two real material slots (e.g. a tree's trunk vs.
# canopy) rather than being a single flat mesh. Only .position/.scale are
# ever read on this from outside setup() (the depletion shrink at
# update_amount() below), which both surfaces (procedural and authored)
# equally support as Node3D members.
var mesh_inst: Node3D = null
var label: Label3D = null

# Set only on an ambient node whose visual was taken over by the shared
# MultiMesh batcher (ambient_scatter.gd). When these are non-null mesh_inst is
# null and vice versa - the two are mutually exclusive rendering paths, and
# every read of mesh_inst outside setup() has a matching branch here.
var _scatter: Node3D = null
var _scatter_handle = null

# Crib from C&C/Tiberium fields (Chris's own call, 2026-07-27): a node left
# alone for a while gradually regrows, whether it's merely been picked at
# or fully depleted - a contested field rewards holding it even after the
# obvious harvest, and a fully-mined field isn't gone forever. Adapted from
# OpenRA's own SeedsResource (a per-cell regrowth tick with a density cap)
# to this game's discrete nodes rather than a cell/density grid - see
# RTS_CORE_ROADMAP.md's own "explicitly out of scope... but worth having
# eventually" note for this exact feature. Deliberately self-contained in
# this script (own _physics_process, no external ticking from skirmish.gd
# needed) rather than a second timer skirmish.gd has to remember to drive.
const REGROW_DELAY: float = 15.0 # seconds since the last successful harvest before regrowth starts
const REGROW_RATE_FRACTION: float = 0.01 # fraction of start_amount regenerated per second, once active
var _time_since_harvest: float = REGROW_DELAY # a freshly-spawned full node has nothing to regrow anyway
var _regrow_accum: float = 0.0

# Authored pool (tools/blender/build_terrain_props.py), one family per
# resource type, N variants each so a field reads as real variety rather
# than one asset stamped at every node. Picked deterministically from this
# node's own spawn position, same convention _spawn_rock_obstacle() in
# terrain_builder.gd already uses for boulders.
#
# PER-FAMILY, not one global count. build_meshes.generate_terrain_props()
# exports three ore, three crystal and three lumber variants but only TWO oil
# derricks, so a flat pool size of 3 rolled index 2 for roughly a third of all
# oil wells, failed to load resource_oil_2.glb, and quietly fell through to the
# procedural derrick box - with a resource-load error on the way past. It never
# looked broken because the fallback is a plausible-looking derrick, which is
# exactly what made it worth pinning here.
#
# A family absent from this dict falls back to 1, so adding a new resource type
# without an entry renders its variant 0 everywhere rather than erroring - the
# same "degrade to something" contract as the procedural fallback itself.
const AUTHORED_POOL_SIZES := {
	"ore": 3,
	"crystal": 3,
	"lumber": 3,
	"oil": 2,
}
const AUTHORED_MODEL_DIR := "res://assets/models/terrain/resource_%s_%d.glb"
# The lookup uses the CANONICAL type, which is why the asset family is named
# resource_ore_N.glb and not resource_metal_N.glb: ResourceCatalog.ALIASES is
# {"metal": "ore"}, so canonical("metal") returns "ore", not the reverse. No
# separate alias table is needed here - but the naming only works in that one
# direction, so an asset family added under a non-canonical id would silently
# never load and every node of that type would sit on the procedural fallback
# with nothing logged.

# AMBIENT TREE POOL - the per-tree mesh family for the ambient
# harvestable trees scattered across the whole map (see
# terrain_greebles.gd's scatter_ambient_trees). Separate family from
# AUTHORED_POOL_SIZES above on purpose:
#   * These are SCATTERED DIRECTLY as individual ResourceNode instances
#     by terrain_greebles.gd, never parented under a ResourceField
#     (so they have NO field, NO respawn, NO regrow).
#   * They use lumber credits (resource_type = "lumber") - a harvester
#     can pick one up the same way it picks up a regular lumber node,
#     the difference is just "this one is gone after you cut it."
#   * The model files (ambient_tree_0..N.glb) are a SEPARATE family from
#     resource_lumber_*.glb - the harvestable 3-tree "stand" that
#     ResourceField scatters is its own visual species, deliberately
#     different so the per-tree ambient mesh doesn't read as a piece of
#     a "real" lumber deposit. See CHRIS 2026-08-10 direction.
#
# AMBIENT_TREE_POOL_SIZE MUST match the count build_terrain_props.py
# exports (36: 12 species x 3 variants); a size larger than what is
# on disk rolls indices at missing files and the same silent-fallback
# to the procedural cylinder that AUTHORED_POOL_SIZES exists to
# prevent.
const AMBIENT_TREE_POOL_SIZE: int = 36
const AMBIENT_TREE_MODEL_DIR := "res://assets/models/terrain/ambient_tree_%d.glb"
# Per-tree amount for ambient trees. Deliberately MUCH smaller than a
# field's per-node amount (~100 for a 9-node lumber field): a single
# tree holds a small trickle, not a deposit, and the whole point is
# "you can always grab a little." Summed across the ~900 scattered
# trees on a 210-half-extent map (post-2026-08-10 trim), the total
# ambient lumber pool is a real income source but still firmly below
# the harvestable lumber fields' yield.
const AMBIENT_TREE_AMOUNT: int = 40
# Ambient ore amount. Pairs with AMBIENT_TREE_AMOUNT above. Scaled
# 1.5x to mirror ResourceCatalog.TYPES.ore.credits / lumber.credits
# (1.5 / 1.0), so per-find ore is worth the same credit-chunk as
# per-find lumber at the same density - the value-curve is preserved
# in the ambient pass exactly the way it is in the harvestable
# fields. As with the trees, deliberately MUCH smaller than a
# harvestable ore field's per-node amount (~157 for a 7-node field):
# a single ambient find is a trickle, not a deposit.
const AMBIENT_ORE_AMOUNT: int = 60

# True for trees scattered by terrain_greebles.gd.scatter_ambient_trees
# (and ONLY for those). The flag controls three things:
#   * harvest() does NOT arm the regrow timer (no regrow ever).
#   * _physics_process() does not run the regrow tick (the node stays
#     "DEPLETED" and is removed from the resource_nodes group forever,
#     so harvesters can no longer pick it).
#   * The authored mesh comes from AMBIENT_TREE_MODEL_DIR, not the
#     resource-type pool (otherwise every ambient tree would be one of
#     the 3 harvestable stand variants - wrong species, wrong scale).
# Default FALSE so the existing 4 type's spawn paths (lumber/ore/
# crystal/oil fields) are byte-for-byte unchanged.
var is_ambient: bool = false

func _try_spawn_authored(res_type: String) -> Node3D:
	if not ResourceLoader.exists(AUTHORED_MODEL_DIR % [res_type, 0]):
		return null
	var rng = RandomNumberGenerator.new()
	rng.seed = hash(global_position)
	var pool: int = maxi(1, int(AUTHORED_POOL_SIZES.get(res_type, 1)))
	var idx: int = rng.randi() % pool
	var packed := load(AUTHORED_MODEL_DIR % [res_type, idx]) as PackedScene
	if packed == null:
		return null
	return packed.instantiate() as Node3D


# Separate path for the ambient-tree family. Same deterministic-per-
# position contract as _try_spawn_authored (seeded off global_position
# so a given scatter point always picks the same variant, run to run),
# but reads AMBIENT_TREE_POOL_SIZE / AMBIENT_TREE_MODEL_DIR. Returns
# null (and the caller falls through to the procedural cylinder) if
# the first ambient_tree_0.glb is missing, mirroring the
# "degrade to something" contract the harvestable pool already has.
#
# TYPE-AWARE (2026-08-10): ambient LUMBER uses the dedicated
# 20-variant ambient_tree_* family (the "separate species" Chris
# asked for); ambient ORE/CRYSTAL/OIL fall through to the regular
# harvestable pool (e.g. resource_ore_*.glb), which is the same
# visual a real ore field uses. A separate ambient_ore_* family was
# considered and rejected - the existing 3-variant outcrop IS the
# "ambient" look, and a second family would just drift. Lumber is
# the one type where the harvestable visual (3-tree clumped "stand")
# is the wrong silhouette for a single scattered find, which is why
# it gets its own pool and nothing else does.
# Which .glb an ambient node WOULD instantiate, as a path rather than an
# instance. ambient_scatter.gd keys its per-species MultiMesh on this path and
# instantiates each species exactly once, so handing it an instance to inspect
# and throw away would reintroduce the per-item instantiation cost that
# batching exists to remove.
#
# RNG consumption is identical to the two _try_spawn_* functions below (same
# seed = hash(global_position), same single randi() against the same pool
# size), so the batched path picks the SAME variant per scatter point as the
# per-node path did. That equality is the whole reason this is a separate
# function rather than a rewrite of them - map scatter has to stay
# deterministic run-to-run.
func _ambient_scene_path(res_type: String) -> String:
	var rng = RandomNumberGenerator.new()
	rng.seed = hash(global_position)
	if res_type == "lumber":
		if not ResourceLoader.exists(AMBIENT_TREE_MODEL_DIR % 0):
			return ""
		return AMBIENT_TREE_MODEL_DIR % (rng.randi() % AMBIENT_TREE_POOL_SIZE)
	if not ResourceLoader.exists(AUTHORED_MODEL_DIR % [res_type, 0]):
		return ""
	var pool: int = maxi(1, int(AUTHORED_POOL_SIZES.get(res_type, 1)))
	return AUTHORED_MODEL_DIR % [res_type, rng.randi() % pool]


func _try_spawn_ambient_authored(res_type: String) -> Node3D:
	if res_type == "lumber":
		if not ResourceLoader.exists(AMBIENT_TREE_MODEL_DIR % 0):
			return null
		var rng = RandomNumberGenerator.new()
		rng.seed = hash(global_position)
		var idx: int = rng.randi() % AMBIENT_TREE_POOL_SIZE
		var packed := load(AMBIENT_TREE_MODEL_DIR % idx) as PackedScene
		if packed == null:
			return null
		return packed.instantiate() as Node3D
	# Non-lumber ambient types share the regular harvestable pool.
	# The is_ambient flag still suppresses regrow on the resulting
	# node, so the gameplay side is fully "no refill"; the visual is
	# just the standard outcrop / crystal / derrick at that type.
	return _try_spawn_authored(res_type)


func setup(res_type: String, res_amount: int):
	resource_type = ResourceCatalogScript.canonical(res_type)
	amount = res_amount
	start_amount = res_amount
	add_to_group("resource_nodes")
	# AMBIENT NODES HAVE NO PHYSICS BODY. A 1000-tree + 800-ore scatter
	# makes 1800 StaticBody3D entries in Godot's broadphase, which is
	# catastrophic: per-frame AABB sweeps against every moving unit,
	# per-click raycasts, and a per-tree bookkeeping overhead that
	# scales linearly with the scatter count. The body class itself
	# stays (so the existing StaticBody3D-shaped callers still see
	# valid RIDs on the harvestable field nodes), but the per-tree
	# CollisionShape3D is gated to NON-AMBIENT ONLY.
	#
	# The right-click pick on a single ambient tree is the cost of this:
	# match_director.gd's _raycast against RESOURCE_NODES (layer 16) no
	# longer hits an individual ambient tree. The harvester's auto-find
	# path (unit.gd's _auto_find_harvest_work, group iteration)
	# still works - and it is the right UX for a 1000-tree scatter
	# anyway, since clicking through a forest to find the specific tree
	# you want is exactly the friction the auto-find was designed to
	# remove. The 4 harvestable field stands keep their full colliders
	# (36 of them, visible gameplay element, picking is the
	# affordance the player uses).
	collision_layer = 0 if is_ambient else 16
	collision_mask = 0

	# AND NO PER-TREE PHYSICS TICK EITHER. The collider gate above removed
	# these nodes from the broadphase, but every one of them was still
	# registered as a _physics_process callback - and an idle scatter is
	# the common case, so all 1895 of them ran only to hit the `if
	# is_ambient: return` guard on the first line of _physics_process().
	#
	# That guard made the FUNCTION free while leaving the DISPATCH in
	# place, which is the part that actually costs: measured headless with
	# tools/probe_skirmish_census.gd on a built skirmish world, turning
	# these off is -40.6% of total physics-tick CPU (4.03 ms -> 2.40 ms at
	# 16 units), making decorative scenery the single largest consumer of
	# the tick - larger than every unit, weapon and the match director
	# combined. An early return cannot fix that; only not being registered
	# can.
	#
	# Non-ambient nodes are gated too, on the same reasoning one level in:
	# a field node at full amount also returns immediately (nothing to
	# regrow), so it only needs to tick while a regrow is actually pending.
	# harvest() re-arms it; _physics_process() switches itself back off on
	# reaching start_amount.
	set_physics_process(not is_ambient and amount < start_amount)

	# Authored art first, procedural primitive second - same "degrade to the
	# placeholder rather than to nothing" contract as building_mesh.gd's own
	# build(). The authored asset keeps its own baked-in glTF materials (a
	# tree's trunk vs. canopy, an outcrop's rock vs. ore vein), so it is
	# NEVER given a flat material_override the way the procedural fallback
	# below is.
	# Ambient trees route through their own pool (AMBIENT_TREE_MODEL_DIR),
	# not AUTHORED_POOL_SIZES, for the species reason noted at the top of
	# this file - and so an ambient tree's pick is seeded from the same
	# hash(global_position) contract as every other resource, so scatter is
	# deterministic. Ambient ore (and any future ambient type) falls
	# through to the regular harvestable pool via _try_spawn_ambient_
	# authored's own internal branch - see that function's header.
	#
	# AMBIENT NODES DRAW THROUGH A SHARED MULTIMESH, NOT THEIR OWN SUBTREE.
	# Registering with the batcher hands off only the VISUAL; everything below
	# this node (group membership, amount, harvest(), the no-regrow contract)
	# is untouched, because that is per-item gameplay state a harvester
	# queries and it cannot live in a vertex buffer. See ambient_scatter.gd's
	# header for the measurement that motivated this (4292 scenery surfaces
	# before a single unit spawns). Falls through to the per-node path if the
	# batcher can't take it - a missing species asset must degrade to a
	# visible placeholder, not to nothing.
	if is_ambient:
		var scatter := AmbientScatterScript.get_or_create(get_parent())
		var path := _ambient_scene_path(resource_type)
		if scatter != null and path != "":
			_scatter_handle = scatter.register(path, self)
			if _scatter_handle != null:
				_scatter = scatter
	if _scatter_handle == null:
		mesh_inst = _try_spawn_ambient_authored(resource_type) if is_ambient else _try_spawn_authored(resource_type)
	# AMBIENT SHADOWS ARE OFF. A 10-20-variant ambient scatter places 60-1000
	# static trees across the whole map; with Godot's default 4096x4096 shadow
	# atlas that's hundreds of shadow casters doing a full depth pass per
	# frame for no visual gain (the top-down RTS camera looks straight down on
	# the tree's own canopy, so a self-shadow reads as a tiny smudge on the
	# canopy, not a ground shadow). Worse: those tree shadows fall on the
	# SAME ground pixels where a unit's gameplay-relevant shadow is, and a
	# dark tree shadow under a tank obscures the tank's shadow the player
	# actually needs. The harvestable 4-field stands keep their shadows on
	# because there are 36 trees total, not 300, and the stand is a visible
	# gameplay element (not a decorative scatter) so the visual is part of
	# the silhouette. Only the ambient branch opts out.
	#
	# WHY WALK DESCENDANTS. The pool's PackedScene root is a Node3D (a glTF
	# import always wraps a node around the mesh tree), not a MeshInstance3D
	# itself - setting cast_shadow on the root has no effect. The actual
	# MeshInstance3D children are at the leaves of the imported tree, so
	# disable shadows on every GeometryInstance3D under the root. The
	# fallback MeshInstance3D branch on the procedural cylinder IS itself a
	# GeometryInstance3D, so the recursive walk hits it without a separate
	# code path.
	if is_ambient:
		_disable_shadows_recursive(mesh_inst)
	# A batched ambient node has no subtree of its own and must NOT fall
	# through to the procedural placeholder below - it is already being drawn,
	# by the MultiMesh, and a cylinder here would render a second time inside
	# the tree it registered.
	if mesh_inst == null and _scatter_handle == null:
		var fallback := MeshInstance3D.new()
		var mat = StandardMaterial3D.new()
		mat.albedo_color = ResourceCatalogScript.color(resource_type)
		match resource_type:
			"crystal":
				var prism = PrismMesh.new()
				prism.size = Vector3(1.6, 2.2, 1.6)
				fallback.mesh = prism
				mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
				mat.albedo_color.a = 0.85
				mat.emission_enabled = true
				mat.emission = Color(0.3, 0.6, 1.0)
				mat.emission_energy_multiplier = 0.7
				fallback.position = Vector3(0, 1.1, 0)
			"lumber":
				# A seedling cone, per Chris: a forest stand is "really just a group
				# of tree seedlings" - the field spawns nine of these, so one of them
				# is a tree, not a wood.
				var tree = CylinderMesh.new()
				tree.top_radius = 0.0
				tree.bottom_radius = 1.0
				tree.height = 3.0
				fallback.mesh = tree
				mat.roughness = 1.0
				fallback.position = Vector3(0, 1.5, 0)
			"oil":
				# A squat derrick block. Deliberately dark and low - a well reads as
				# infrastructure sitting on the ground, not as a mineral growing out
				# of it, which is what says "neutral, and worth taking".
				var derrick = BoxMesh.new()
				derrick.size = Vector3(1.8, 2.6, 1.8)
				fallback.mesh = derrick
				mat.metallic = 0.6
				mat.roughness = 0.4
				fallback.position = Vector3(0, 1.3, 0)
			_:
				var sphere = SphereMesh.new()
				sphere.radius = 1.2
				sphere.height = 1.6
				fallback.mesh = sphere
				mat.roughness = 0.9
				fallback.position = Vector3(0, 0.6, 0)
		fallback.material_override = mat
		mesh_inst = fallback
	if mesh_inst != null:
		_matte_authored_mesh(mesh_inst)
		var finish_script = load("res://scripts/battle/battle_finish.gd")
		if finish_script != null:
			finish_script.apply(mesh_inst)
		add_child(mesh_inst)

	# Per-tree collider: NON-AMBIENT ONLY. See the collision_layer gate
	# at the top of setup() for the why. Ambient nodes are still in the
	# "resource_nodes" group and still respond to harvest() - what they
	# lose is the right-click pickability on a single tree, which the
	# harvester's auto-find replaces.
	if not is_ambient:
		var col = CollisionShape3D.new()
		var shape = BoxShape3D.new()
		shape.size = Vector3(2.4, 2.4, 2.4)
		col.shape = shape
		col.position = Vector3(0, 1.2, 0)
		add_child(col)

	# Skip the per-tree label on ambient trees. A 4-field map scatters
	# 9 labels per field, so 36 billboards total - cheap. The ambient
	# pass scatters up to AMBIENT_TREE_MAX_COUNT (=1500) trees across
	# the same map, and an always-on "LUMBER: 40" billboard on every
	# one of them is a real visual + perf cost (Label3D is its own
	# GeometryInstance3D + text-shader draw). The existing 4 harvestable
	# fields still get their labels (they're the "this is a deposit"
	# affordance the player wants to see) - ambient trees get the
	# resource_nodes group membership instead, which is what the
	# harvester actually uses to find them.
	if not is_ambient:
		label = Label3D.new()
		label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
		label.font_size = 20
		label.outline_size = 4
		label.position = Vector3(0, 3.0, 0)
		add_child(label)
		_update_label()


func _matte_authored_mesh(root: Node) -> void:
	if root == null:
		return
	if root is MeshInstance3D:
		var mi: MeshInstance3D = root
		if mi.mesh != null:
			for si in range(mi.mesh.get_surface_count()):
				var src_mat = mi.mesh.surface_get_material(si)
				if src_mat is StandardMaterial3D or src_mat is ORMMaterial3D or src_mat is BaseMaterial3D:
					var matte_mat = StandardMaterial3D.new()
					matte_mat.albedo_color = src_mat.albedo_color
					matte_mat.albedo_texture = src_mat.albedo_texture
					if src_mat.normal_enabled or src_mat.normal_texture != null:
						matte_mat.normal_enabled = true
						matte_mat.normal_texture = src_mat.normal_texture
					if src_mat.transparency != BaseMaterial3D.TRANSPARENCY_DISABLED or (src_mat.albedo_texture != null and src_mat.albedo_texture.has_alpha()):
						matte_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA_SCISSOR
						matte_mat.alpha_scissor_threshold = 0.45
						matte_mat.cull_mode = BaseMaterial3D.CULL_DISABLED
					matte_mat.roughness = 1.0
					matte_mat.metallic = 0.0
					matte_mat.metallic_specular = 0.0
					matte_mat.specular_mode = BaseMaterial3D.SPECULAR_DISABLED
					mi.set_surface_override_material(si, matte_mat)
	for c in root.get_children():
		_matte_authored_mesh(c)


# Walk the imported scene tree under `root` and set cast_shadow=OFF on every
# GeometryInstance3D. Used only by the ambient branch - see the block at the
# top of setup() for why. Bounded by the tree depth of a single glTF import
# (a few levels), so a plain recursive walk is fine; a BFS via an Array
# stack would be no faster in practice.
func _disable_shadows_recursive(root: Node) -> void:
	if root == null:
		return
	if root is GeometryInstance3D:
		root.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	for c in root.get_children():
		_disable_shadows_recursive(c)


func _update_label():
	if not is_instance_valid(label): return
	if amount <= 0:
		label.text = "DEPLETED"
		label.modulate = Color(0.5, 0.5, 0.5)
	else:
		label.text = "%s: %d" % [ResourceCatalogScript.label(resource_type), amount]
		label.modulate = ResourceCatalogScript.color(resource_type)

func _update_visual_scale():
	if start_amount <= 0:
		return
	var pct = clamp(float(amount) / float(start_amount), 0.15, 1.0) if amount > 0 else 0.15
	if is_instance_valid(mesh_inst):
		mesh_inst.scale = Vector3(pct, pct, pct)
	elif _scatter_handle != null and is_instance_valid(_scatter):
		# Same shrink, applied to this item's slot in the shared MultiMesh.
		# scaled_local (not scaled) so the shrink happens about the item's own
		# origin the way a child MeshInstance3D's .scale did - scaling the
		# global transform instead would drag the tree toward the map origin
		# as it depleted.
		_scatter.set_node_transform(_scatter_handle, global_transform.scaled_local(Vector3(pct, pct, pct)))

func harvest(want: int) -> int:
	var got = min(want, amount)
	amount -= got
	# Ambient trees do NOT regrow. The regrow timer is what eventually
	# refills a node, and a partially-depleted ambient tree should NOT
	# inch its way back to full between harvester trips - the design
	# contract is "you cut it, it's gone, for the whole match." Leaving
	# _time_since_harvest alone here would do nothing on its own
	# (this function never reads it), but _physics_process() does, so
	# the gate is on _physics_process() side; this comment is the
	# "and no, the timer is NOT being armed either" record.
	# If NOT ambient, arm the regrow timer on every successful harvest
	# (C&C Tiberium-style - a contested field rewards holding it).
	if got > 0 and not is_ambient:
		_time_since_harvest = 0.0
		# Re-arm the regrow tick this node switched off when it last
		# topped up (see the set_physics_process() note in setup()).
		set_physics_process(true)
	_update_label()
	_update_visual_scale() # Shrink visually as it depletes
	if amount <= 0:
		remove_from_group("resource_nodes")
	return got

func _physics_process(delta: float) -> void:
	# Ambient trees: no regrow, period. Once depleted, the node sits
	# DEPLETED for the rest of the match and harvesters walk past it
	# (the resource_nodes group removal in harvest() above is what
	# gates "find nearest resource" - by the time _physics_process
	# sees amount<=0, the node is already invisible to harvesters).
	# Bailing out before the regrow tick is what makes that contract
	# enforceable; the alternative (setting regrow rate to 0) would
	# still tick the timer and waste cycles.
	var _p := Profiler.start()
	if is_ambient:
		set_physics_process(false)
		Profiler.stop("resource_node", _p)
		return
	if amount >= start_amount:
		# Fully regrown - nothing left to do until the next harvest()
		# re-arms us. Stop being dispatched rather than early-returning
		# forever; see setup()'s note on why the dispatch is the cost.
		set_physics_process(false)
		Profiler.stop("resource_node", _p)
		return
	_time_since_harvest += delta
	if _time_since_harvest < REGROW_DELAY:
		Profiler.stop("resource_node", _p)
		return
	_regrow_accum += start_amount * REGROW_RATE_FRACTION * delta
	if _regrow_accum < 1.0:
		Profiler.stop("resource_node", _p)
		return
	var whole = int(_regrow_accum)
	_regrow_accum -= whole
	var was_depleted = amount <= 0
	amount = min(start_amount, amount + whole)
	if was_depleted and amount > 0 and not is_in_group("resource_nodes"):
		add_to_group("resource_nodes")
	_update_label()
	_update_visual_scale()
	Profiler.stop("resource_node", _p)
