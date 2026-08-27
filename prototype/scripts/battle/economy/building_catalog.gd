class_name BuildingCatalog
extends RefCounted
# Structure stats as DATA, and the map from a structure to the queue it feeds.
#
# Ported from building.gd's PREFAB_STATS, which mixed the numbers in with the
# node behaviour - so reading "what does a refinery cost" meant opening a
# 687-line scene script, and nothing could ask the question without instantiating
# one. The numbers are unchanged; only their home is.
#
# Placeholder box geometry is deliberate and inherited: Chris is replacing every
# building mesh with authored art later, so this is data and wiring only.

const DEFAULT_ADJACENT_M := 24.0
# A defence reaches further from the base than anything else, matching OpenRA's
# long-range defence class - a wall of turrets should be able to picket forward.
const DEFENSE_ADJACENT_M := 84.0

# THE FIVE PRODUCTION QUEUES (Chris's model, this rebuild).
#
# One global queue per TYPE, per team. Every live structure that contributes to a
# type feeds that one queue and speeds it up; there is no per-building queue.
#
# This differs from the old runtime in exactly one way that matters: `structures`
# was a single fourth queue holding both buildings and defences, and defences had
# no build time at all - you paid and placed instantly. They are now two queues
# and a defence takes real time, so walling up is a decision with a tempo cost
# rather than a pure money question.
const QUEUE_LIGHT := "light"
const QUEUE_MEDIUM := "medium"
const QUEUE_HEAVY := "heavy"
const QUEUE_BUILDING := "building"
const QUEUE_DEFENSE := "defense"

const QUEUES: Array[String] = [
	QUEUE_LIGHT, QUEUE_MEDIUM, QUEUE_HEAVY, QUEUE_BUILDING, QUEUE_DEFENSE,
]

# Which structures speed up which queue.
#
# The three manufactories map to their own weight tier, as before. Buildings and
# defences are both contributed by the HQ, which means they run as two
# independent lines off one structure - you can be putting up a refinery and a
# turret at the same time, which is the point of splitting them.
#
# OPEN QUESTION FOR CHRIS: this gives the building and defence queues no way to
# scale, since a team has exactly one HQ. A dedicated Construction Yard (or
# letting each manufactory contribute to `building` as well) would give them the
# same "more structures, faster line" pressure the unit queues have. Left as one
# HQ for now rather than inventing a building the design has not asked for.
const CONTRIBUTORS := {
	QUEUE_LIGHT: ["light_manufactory"],
	QUEUE_MEDIUM: ["medium_manufactory"],
	QUEUE_HEAVY: ["heavy_manufactory"],
	QUEUE_BUILDING: ["hq"],
	QUEUE_DEFENSE: ["hq"],
}

const MANUFACTORY_KINDS: Array[String] = [
	"light_manufactory", "medium_manufactory", "heavy_manufactory",
]

const STATS := {
	"hq": {
		# 2026-08-26 22:14 playtest: bumped from 85 -> 120. A base
		# command building sees furthest - it is the one structure a
		# team always has, so its reach is what stops a match opening
		# inside a fog bubble. Per the playtest: "buildings should be
		# able to see farther than hulls by default" - hulls typically
		# see 20-40m (computed from sensor modules in unit.gd), so
		# the building floor of 80m here means EVERY building out-sees
		# every hull, with the HQ at 120m reaching 3x the best hull.
		# See Structure.vision_range for why any of these are needed.
		"vision_range": 120.0,
		"hp": 3000.0, "size": Vector3(7, 4, 7), "color": Color(0.75, 0.72, 0.55),
		"cost_metal": 0, "cost_crystal": 0, "build_time": 0.0,
		"gives_buildable_area": true, "requires_buildable_area": true,
		"adjacent_m": DEFAULT_ADJACENT_M,
	},
	"refinery": {
		"vision_range": 90.0,
		# A grain elevator, not a shed. The refinery is where the economy is
		# visibly happening, so it reads as the largest thing in the base and
		# its docks are legible from the RTS camera as actual parking bays.
		"hp": 1600.0, "size": Vector3(12, 9, 10), "color": Color(0.55, 0.62, 0.75),
		"cost_metal": 150, "cost_crystal": 0, "build_time": 14.0,
		"gives_buildable_area": true, "requires_buildable_area": true,
		"adjacent_m": DEFAULT_ADJACENT_M,
		"dock_bays": [],
	},
	"light_manufactory": {
		"vision_range": 80.0,
		"hp": 1400.0, "size": Vector3(5, 2.4, 6), "color": Color(0.68, 0.6, 0.42),
		"cost_metal": 150, "cost_crystal": 30, "build_time": 16.0,
		"gives_buildable_area": true, "requires_buildable_area": true,
		"adjacent_m": DEFAULT_ADJACENT_M,
		"exit_offset": Vector3(0, 0.5, 6.0), "exit_facing": Vector3(0, 0, 1),
	},
	"medium_manufactory": {
		"vision_range": 85.0,
		"hp": 1800.0, "size": Vector3(6, 3, 8), "color": Color(0.72, 0.55, 0.42),
		"cost_metal": 220, "cost_crystal": 55, "build_time": 22.0,
		"gives_buildable_area": true, "requires_buildable_area": true,
		"adjacent_m": DEFAULT_ADJACENT_M,
		"exit_offset": Vector3(0, 0.5, 7.0), "exit_facing": Vector3(0, 0, 1),
	},
	"heavy_manufactory": {
		"vision_range": 95.0,
		"hp": 2400.0, "size": Vector3(7.5, 3.8, 10), "color": Color(0.6, 0.42, 0.35),
		"cost_metal": 320, "cost_crystal": 85, "build_time": 30.0,
		"gives_buildable_area": true, "requires_buildable_area": true,
		"adjacent_m": DEFAULT_ADJACENT_M,
		"exit_offset": Vector3(0, 0.5, 8.0), "exit_facing": Vector3(0, 0, 1),
	},
	"power_plant": {
		"vision_range": 75.0,
		"hp": 1000.0, "size": Vector3(4.5, 4.2, 4.5), "color": Color(0.85, 0.65, 0.2),
		"cost_metal": 180, "cost_crystal": 40, "build_time": 12.0,
		"energy_capacity": 20.0,
		"gives_buildable_area": true, "requires_buildable_area": true,
		"adjacent_m": DEFAULT_ADJACENT_M,
	},

	# THE TECH TREE.
	"tech_lab": {
		"vision_range": 90.0,
		"hp": 900.0, "size": Vector3(4.4, 2.9, 4.4), "color": Color(0.42, 0.55, 0.58),
		"cost_metal": 200, "cost_crystal": 60, "build_time": 18.0,
		"gives_buildable_area": true, "requires_buildable_area": true,
		"adjacent_m": DEFAULT_ADJACENT_M,
	},
	"physics_lab": {
		"vision_range": 100.0,
		"hp": 1100.0, "size": Vector3(4.8, 3.8, 4.8), "color": Color(0.45, 0.48, 0.62),
		"cost_metal": 280, "cost_crystal": 110, "build_time": 26.0,
		"gives_buildable_area": true, "requires_buildable_area": true,
		"adjacent_m": DEFAULT_ADJACENT_M,
	},
	"exotics_lab": {
		"vision_range": 110.0,
		"hp": 1300.0, "size": Vector3(5.4, 4.5, 5.4), "color": Color(0.55, 0.38, 0.58),
		"cost_metal": 340, "cost_crystal": 180, "build_time": 34.0,
		"gives_buildable_area": true, "requires_buildable_area": true,
		"adjacent_m": DEFAULT_ADJACENT_M,
	},
}

# The three tech-tree kinds, in unlock-tier order. Kept alongside STATS as the
# canonical list rather than re-derived (e.g. "every kind CONTRIBUTORS has no
# entry for" would also catch a future non-lab, non-queue building), since the
# tests and the tree UI both need this exact set and this exact order.
const TECH_LAB_KINDS: Array[String] = ["tech_lab", "physics_lab", "exotics_lab"]


static func is_tech_lab(kind: String) -> bool:
	return kind in TECH_LAB_KINDS


static func has_kind(kind: String) -> bool:
	return STATS.has(kind)


static func get_stats(kind: String) -> Dictionary:
	return STATS.get(kind, {})


static func get_stat(kind: String, key: String, fallback = null):
	return STATS.get(kind, {}).get(key, fallback)


# Clearance a dock bay needs BEYOND the building's own half-extent, so the bay
# lands on walkable navmesh rather than inside the hole the building carves.
#
# Covers three separate erosions that a raw footprint offset does not see:
# match_director's BUILDING_CLEARANCE (2.5) widening the hole, the navmesh
# grid quantising that hole outward, and Recast shrinking the walkable surface
# by the agent radius on top. Measured worst case across the bundled maps was
# about 3 m of quantisation-plus-erosion past the cleared footprint
# (tools/probe_factory_exit.gd), so this is that plus a working margin.
const DOCK_BAY_CLEARANCE := 6.5


# Where harvesters park, derived from the footprint instead of hardcoded.
#
# Three bays: one off the front face, one off each side. Each sits clear of the
# relevant half-extent, so changing the building's size moves its docks with it
# instead of leaving them buried inside the new walls.
static func dock_bays_for(kind: String) -> Array:
	var stats: Dictionary = STATS.get(kind, {})
	var authored: Array = stats.get("dock_bays", [])
	if not authored.is_empty():
		return authored
	if kind != "refinery":
		return []
	var size: Vector3 = stats.get("size", Vector3(5, 3, 5))
	var front: float = size.z * 0.5 + DOCK_BAY_CLEARANCE
	var side: float = size.x * 0.5 + DOCK_BAY_CLEARANCE
	return [
		Vector3(0.0, 0.0, front),
		Vector3(side, 0.0, 0.0),
		Vector3(-side, 0.0, 0.0),
	]


static func is_manufactory(kind: String) -> bool:
	return kind in MANUFACTORY_KINDS


# Which queue a structure of this kind speeds up, or "" if it produces nothing.
static func queue_for_kind(kind: String) -> String:
	for queue in CONTRIBUTORS:
		if kind in CONTRIBUTORS[queue]:
			return queue
	return ""


# Every structure kind that feeds `queue`.
static func contributors_for(queue: String) -> Array:
	return CONTRIBUTORS.get(queue, [])


# The queue a UNIT design belongs in, from its hull's own weight tier. A small
# boat and a light ground hull both come off the Light line - the split is by
# weight, not by domain.
static func queue_for_hull_tier(tier: String) -> String:
	match tier:
		"light":
			return QUEUE_LIGHT
		"medium":
			return QUEUE_MEDIUM
		"heavy":
			return QUEUE_HEAVY
	return QUEUE_MEDIUM


# Structures the player can order, in build-bar order. Excludes the HQ, which is
# never built - a team starts with one and loses when it dies.
static func buildable_kinds() -> Array:
	var out: Array = []
	for kind in STATS:
		if kind != "hq":
			out.append(kind)
	out.sort()
	return out
