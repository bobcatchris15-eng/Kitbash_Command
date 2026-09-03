class_name PlacementService
extends RefCounted
# Where a structure may legally go - for the player's ghost AND for the AI's
# siting, through one function.
#
# WHY THIS IS ONE FUNCTION AND NOT TWO. The old runtime got this right and it is
# worth not losing: skirmish.gd deliberately factored `_placement_validity_for()`
# out of the player's ghost so the AI could ask the identical question, and said
# so in a comment. The rebuilt battle layer had drifted off that - the AI sited
# through `_site_is_clear()`, which checked bounds, water and structure overlap
# and nothing else, while the player had no placement path at all. Adding one for
# the player separately would have produced two rule sets that agree until
# somebody edits one, which is the exact asymmetry the whole rebuild exists to
# remove.
#
# WHAT WAS BEING SKIPPED. BuildingCatalog already carries
# `gives_buildable_area`, `requires_buildable_area` and `adjacent_m` for every
# structure - ported faithfully from the old PREFAB_STATS and then read by
# nothing. So the AI could drop a power plant six rings out in open field, which
# no player would be allowed to do. The data was already here; only its enforcer
# was missing.
#
# NOT A NODE. It takes the world it is asking about, like ProductionService does,
# so placement legality can be asserted against a stub instead of a live match.

const BuildingCatalogScript = preload("res://scripts/battle/economy/building_catalog.gd")

# Clearance ON TOP of both footprints, so buildings never end up flush against
# each other with no lane between them for a unit to path down. Matches the
# director's own BUILDING_CLEARANCE doubling, which this replaces.
const CLEARANCE := 1.5

# How far inside the map edge a building must sit. A structure on the boundary is
# a structure whose dock bays and factory exit are off the navmesh - the same
# class of bug the refinery bays hit twice.
const EDGE_MARGIN := 12.0

# Resource nodes are not buildable ground. Walling a node in with a power plant
# would let a player deny an ore patch with a building, and it strands the
# harvesters already routed to it.
const NODE_EXCLUSION := 6.0

# Reasons, so the ghost can say WHY it is red rather than just being red. The
# old runtime's ghost gave no reason and "why can't I build here" was a question
# players had to guess at.
const OK := ""
const OUT_OF_BOUNDS := "OUTSIDE THE MAP"
const ON_WATER := "ON WATER"
const OVERLAPS := "TOO CLOSE TO A BUILDING"
const ON_RESOURCE := "ON A RESOURCE NODE"
const NOT_ADJACENT := "TOO FAR FROM YOUR BASE"


# The whole rule set, as one answer. `world` needs `current_map`,
# `terrain_height_at()` and the scene tree groups; that is the same narrow
# surface ProductionService takes.
#
# The `structures` and `resource_nodes` arrays are PRE-HOISTED inputs the AI's
# find_site() passes in, because a 12-ring x 16-sample ring scan is 192
# candidates per build attempt and the per-candidate get_nodes_in_group() was
# the worst-frame cost in the commander section (PR8, 2026-08-16). Every other
# caller - the player's ghost, the tests, any future direct caller - takes the
# default-fetch path and pays one get_nodes_in_group() per call, which is fine
# for the per-frame ghost and the once-off test.
#
# Returns {"valid": bool, "reason": String}.
static func validity(world, team: int, at: Vector3, kind: String,
		blueprint: Dictionary = {}, structures: Array = [],
		resource_nodes: Array = []) -> Dictionary:
	if structures.is_empty() or resource_nodes.is_empty():
		var tree: SceneTree = world.get_tree()
		if structures.is_empty():
			structures = tree.get_nodes_in_group("structures")
		if resource_nodes.is_empty():
			# PR10 perf (2026-08-18). The default-fetch path now
			# also drops ambient trees up front, so the per-
			# candidate loop never sees them. find_site() pre-
			# filters even further, but every other caller (the
			# player's ghost, the placement tests) goes through
			# here and benefits from the same shrink.
			var all_nodes: Array = tree.get_nodes_in_group("resource_nodes")
			resource_nodes = []
			for n in all_nodes:
				if is_instance_valid(n) and not n.get("is_ambient"):
					resource_nodes.append(n)
	var footprint := footprint_for(kind, blueprint)
	var half: float = maxf(footprint.x, footprint.z) * 0.5

	var extent: float = world.current_map.get("map_half_extents", 80.0)
	if absf(at.x) > extent - EDGE_MARGIN or absf(at.z) > extent - EDGE_MARGIN:
		return _no(OUT_OF_BOUNDS)

	if TerrainBuilder.is_water_at(world.current_map, at.x, at.z):
		return _no(ON_WATER)

	# AMBIENT SCATTER DOES NOT VETO A BUILD SITE.
	#
	# The rule above is about DEPOSITS: a player should not be able to wall
	# in an ore patch, and a building on one strands the harvesters routed
	# to it. Both of those are arguments about the ~36 nodes belonging to
	# the four harvestable fields.
	#
	# The ambient forest/ore pass scatters up to 1000 trees + 800 ore at
	# roughly one per 82 m2 of map, with a floor of 8 m between them - and
	# every one of those joined this same group. With NODE_EXCLUSION 6.0
	# plus a building's own half-footprint, each scattered tree vetoes a
	# disc about as wide as the gap between trees, so the exclusion discs
	# tile the entire playable area and there is essentially nowhere legal
	# left to build. That is what these three placement suites were
	# reporting ("a clear spot beside the HQ was rejected: ON A RESOURCE
	# NODE", "the control site was not clear to begin with").
	#
	# A scattered tree is scenery you clear to build, not a deposit you
	# must not bury - so it is skipped here. It stays fully harvestable;
	# only its veto over construction goes away.
	#
	# PR10 perf (2026-08-18). The ambient filter (n.get("is_ambient"))
	# used to run inside this loop, once per candidate, against a list
	# that contains 1000+ ambient trees plus ~36 real deposits. The
	# per-candidate walk was 192 * 1000+ is_instance_valid + get calls
	# per AI build attempt. The pre-filter of resource_nodes to
	# non-ambient (in find_site() below) moves the is_ambient check out
	# of this loop - by the time we get here, every node in this list
	# is a real deposit.
	for n in resource_nodes:
		if not is_instance_valid(n):
			continue
		if at.distance_to(n.global_position) < half + NODE_EXCLUSION:
			return _no(ON_RESOURCE)

	# Adjacency is measured against structures that GIVE buildable area, and only
	# this team's - you may not build off the enemy's base. Checked before the
	# overlap loop reports success so the two reasons stay distinguishable.
	var near_base := not requires_area(kind, blueprint)
	var reach := adjacency_for(kind, blueprint)

	for s in structures:
		if not is_instance_valid(s) or s.is_dead or not s.is_inside_tree():
			continue
		var other_half: float = maxf(s.footprint.x, s.footprint.z) * 0.5
		var distance: float = at.distance_to(s.global_position)
		if distance < half + other_half + CLEARANCE * 2.0:
			return _no(OVERLAPS)
		# EDGE TO EDGE, counting BOTH footprints - the same way the overlap test
		# above measures. Measuring adjacency from the anchor's edge only made the
		# legal band the difference between two differently-derived numbers: a
		# power plant beside an HQ had to land between 8.75 m (overlap) and 11.5 m
		# (adjacency), a 2.75 m ring that is unusable with a ghost on a cursor and
		# which a larger building could close entirely.
		if not near_base and s.team == team \
				and BuildingCatalogScript.get_stat(s.kind, "gives_buildable_area", false) \
				and distance <= half + other_half + reach:
			near_base = true

	if not near_base:
		return _no(NOT_ADJACENT)

	var req_kind: String = BuildingCatalogScript.get_stat(kind, "requires_adjacent_kind", "")
	if req_kind != "":
		var found := false
		for s in structures:
			if is_instance_valid(s) and not s.is_dead and s.team == team and s.kind == req_kind:
				if at.distance_to(s.global_position) <= half + (maxf(s.footprint.x, s.footprint.z) * 0.5) + reach:
					found = true
					break
		if not found:
			return _no("MUST BE PLACED NEXT TO A " + req_kind.to_upper().replace("_", " "))

	return {"valid": true, "reason": OK}


static func _no(reason: String) -> Dictionary:
	return {"valid": false, "reason": reason}


# A defence design's footprint comes from its own foundation hull, not from the
# catalog - a bunker and a gun turret are both "defense" and are not the same
# size. Falls back to the catalog for prefab kinds.
static func footprint_for(kind: String, blueprint: Dictionary = {}) -> Vector3:
	if not blueprint.is_empty():
		var sc: Dictionary = blueprint.get("hull_scale", {"x": 1.0, "y": 1.0, "z": 1.0})
		var base := Vector3(5.0, 3.0, 5.0)
		return Vector3(base.x * float(sc.get("x", 1.0)), base.y * float(sc.get("y", 1.0)),
			base.z * float(sc.get("z", 1.0)))
	return BuildingCatalogScript.get_stat(kind, "size", Vector3(5, 3, 5))


static func requires_area(kind: String, blueprint: Dictionary = {}) -> bool:
	if not blueprint.is_empty():
		# A defence still has to connect to the base, just on a much longer leash -
		# picketing forward is the point of a turret.
		return true
	return BuildingCatalogScript.get_stat(kind, "requires_buildable_area", true)


static func adjacency_for(kind: String, blueprint: Dictionary = {}) -> float:
	if not blueprint.is_empty():
		return BuildingCatalogScript.DEFENSE_ADJACENT_M
	return BuildingCatalogScript.get_stat(kind, "adjacent_m",
		BuildingCatalogScript.DEFAULT_ADJACENT_M)


# --- Siting -------------------------------------------------------------------

# An outward ring search from `home` for the first legal spot, which is how the
# AI picks a site. A ring rather than a scatter so a base grows outward as a base
# instead of sprawling, and the first valid ring keeps new buildings close enough
# to defend together.
#
# It resolves through validity() above, so the AI is held to the player's rules -
# including the buildable-area adjacency it was previously ignoring.
const RING_STEP := 10.0
const RINGS := 12
const SAMPLES := 16


static func find_site(world, team: int, home: Vector3, kind: String,
		blueprint: Dictionary = {}) -> Vector3:
	# PR8 perf (2026-08-16). Hoist the structures / resource_nodes lookups
	# OUT of the per-candidate loop. The 12 rings x 16 samples grid is
	# 192 candidates per build attempt, and each used to call
	# get_nodes_in_group() and walk the full structure / resource_nodes
	# lists. With 30-50 structures and 1000+ resource_nodes, that is
	# ~200K node-iterations per AI build. A 1120ms worst frame in the
	# commander section was this loop on a busy match; the unit cost
	# is now amortised to a single fetch per build attempt.
	#
	# PR10 perf (2026-08-18). resource_nodes is now pre-filtered to
	# non-ambient on top of the get_nodes_in_group hoist. The ambient
	# filter used to run inside validity() once per candidate; with
	# 1000+ ambient trees on the map and 192 candidates per attempt,
	# that was 192,000 is_instance_valid + get() calls per AI build.
	# Filtering once here drops the per-candidate walk from 1000+ to
	# ~36. validity() also drops its own ambient check, so the pre-
	# filtered list is what the per-candidate loop sees.
	var tree: SceneTree = world.get_tree()
	var structures: Array = tree.get_nodes_in_group("structures")
	var all_resource_nodes: Array = tree.get_nodes_in_group("resource_nodes")
	var resource_nodes: Array = []
	for n in all_resource_nodes:
		if is_instance_valid(n) and not n.get("is_ambient"):
			resource_nodes.append(n)
	for ring in range(1, RINGS + 1):
		var radius := RING_STEP * float(ring)
		for i in range(SAMPLES):
			var angle := TAU * float(i) / float(SAMPLES)
			var candidate := home + Vector3(cos(angle) * radius, 0.0, sin(angle) * radius)
			candidate.y = world.terrain_height_at(candidate)
			if validity(world, team, candidate, kind, blueprint, structures, resource_nodes)["valid"]:
				return candidate
	return Vector3.INF
