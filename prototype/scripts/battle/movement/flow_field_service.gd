class_name FlowFieldService
extends RefCounted
# Decides when a flow field is worth building, and keeps the ones that are.
#
# THE GATE MATTERS AS MUCH AS THE FIELD. A field is one search shared by many
# units; below a handful of units it is strictly more expensive than letting each
# one path for itself, because the search covers the whole reachable map rather
# than one corridor. So a field is built only for group moves at or above
# FIELD_MIN_UNITS, and everything else keeps its NavigationAgent3D.
#
# HOW IT COMPOSES WITH FORMATIONS. These look like they conflict - a field drives
# every unit to ONE destination, a formation gives every unit a DIFFERENT one -
# and resolving that is the whole design:
#
#   far from the destination : follow the field toward the group's clicked point
#   near it                  : steer directly to your own formation slot
#
# The field does the long haul, where all the units genuinely want to go the same
# way and the pathfinding cost is real. The slot does the arrival, where they
# want to spread out and the distances are short enough that direct steering is
# correct. The handover radius is HANDOVER_DISTANCE below.

const FlowFieldScript = preload("res://scripts/battle/movement/flow_field.gd")

# Below this, per-unit agents are cheaper and just as good.
const FIELD_MIN_UNITS := 8

# Distance from the group destination at which a unit is entirely on its own
# slot and ignoring the field.
const HANDOVER_DISTANCE := 28.0

# Over this band above HANDOVER_DISTANCE, field influence ramps from none to
# full. A HARD SWITCH WAS MEASURABLY WORSE THAN NO FIELD AT ALL, and the numbers
# are worth recording because the failure is counter-intuitive:
#
#   pure agents (field silently broken)  median 2.1 m from slot, 11/12 arrived
#   hard switch to a working field       median 49 m from slot,  3/12 arrived,
#                                        closest pair 0.90 m - stacked
#
# The reason is that a field gives every unit in a cell the IDENTICAL direction.
# That is the whole point when the goal is one point, and exactly wrong once
# formations have given each unit its own slot: the field collapses twelve
# distinct destinations back onto one line and they jam, with separation and the
# field pushing against each other in equilibrium.
#
# Blending keeps what the field is actually for - one search instead of N, and a
# route that already knows where the terrain is - while never letting it fully
# override the fact that these units are going to different places.
#
# MEASURED, and the first two rows above were not a fair fight. Both were taken on
# a ~60 m trip, which is under MIN_TRIP_DISTANCE, so no field was ever built: the
# "pure agents" row is honest but the "hard switch" row was the fallback path too,
# and the probe passed while never once exercising the thing it existed to test.
# Re-measured on a 204 m cross-map trip with the field confirmed steering at
# departure (weight 1.00, non-zero direction):
#
#   blend + trip gate, field genuinely engaged    median 2.6 m from slot,
#                                                 8-9/12 arrived,
#                                                 closest pair 4.4-7.3 m
#
# So the blend holds the formation while the field does the long haul - which is
# the whole claim - and nothing stacks. What it does NOT yet do is get everyone
# home: two or three units per run take a bad route and are still travelling at
# cutoff, and WHICH units varies run to run. That is a straggler/route problem,
# not a blend problem, and it is the next thing to chase here.
const BLEND_BAND := 45.0

# Below this trip length a field is not built at all. Its benefit is amortising
# one search across many units on a LONG haul; over a short hop the search covers
# the whole reachable map to save twelve corridor searches that were cheap
# anyway, and the convergence cost is paid for nothing.
#
# CALLERS MUST PASS THE TRIP LENGTH RECORDED AT ISSUE TIME (Order.trip_length),
# not the distance still to run. Passing the live remaining distance - which is
# what match_director did originally - makes this gate fire mid-journey: on a
# 200 m trip the field vanished the moment the unit came within 90 m, which is
# still outside the blend band (HANDOVER_DISTANCE + BLEND_BAND = 73 m), so field
# influence fell from 1.0 to 0.0 in a single frame. That is precisely the hard
# switch BLEND_BAND exists to remove, reintroduced at the far end of the trip.
const MIN_TRIP_DISTANCE := 90.0


# How much the field should govern, from 0 (entirely the unit's own slot) to 1
# (entirely the field), given how far the unit still is from the group's
# destination. Pure function so the ramp can be asserted directly.
static func field_weight(distance_to_group_destination: float) -> float:
	if distance_to_group_destination <= HANDOVER_DISTANCE:
		return 0.0
	return clampf((distance_to_group_destination - HANDOVER_DISTANCE) / BLEND_BAND, 0.0, 1.0)

# Fields are keyed on the destination snapped to this, so a dozen orders clicked
# at nearly the same spot share one field instead of building a dozen.
const KEY_SNAP := 8.0

# Cheap ceiling. Each field is a few hundred KB at most and they are only built
# on a group order, so this is really just a guard against a long match
# accumulating hundreds of stale ones.
const MAX_CACHED := 12

var _nav_map: RID
var _map_half_extents: float = 80.0
# CORE_DESIGN_LANGUAGE.md §3.2: threaded through to FlowField.build() so its
# cell size scales with the map instead of staying a flat 4m constant while
# map_half_extents grows - see flow_field.gd's BASE_CELL_SIZE comment for
# why an unscaled cell size is NOT self-bounding the way the navmesh bake's
# own cell-size formula is.
var _world_scale: float = 1.0
var _fields: Dictionary = {}
var _order: Array = []


func setup(nav_map: RID, map_half_extents: float, world_scale: float = 1.0) -> void:
	_nav_map = nav_map
	_map_half_extents = map_half_extents
	_world_scale = world_scale


# Flow field generation in GDScript requires ~14k NavigationServer3D point queries
# and whole-map Dijkstra traversal, which blocks the main thread for ~20 seconds
# per build on maps like lake_crossing. NavigationAgent3D in C++ runs in <0.05ms
# per unit, so flow field generation is disabled by default.
const ENABLE_FLOW_FIELDS := false

static func should_use_field(unit_count: int) -> bool:
	if not ENABLE_FLOW_FIELDS:
		return false
	return unit_count >= FIELD_MIN_UNITS


# The field for `destination`, building it if this is the first ask. Returns null
# when fields are switched off for this group size, so callers can treat "no
# field" and "small group" identically.
#
# STALE-WHILE-REVALIDATE (2026-08-24, tools/probe_navmesh_repath_storm.gd).
# A field build is a whole-map passability sample (one NavigationServer3D
# map_get_closest_point PER CELL - ~14 k calls on lake_crossing at scale 4,
# seconds of main-thread time) plus a GDScript Dijkstra over the same grid.
# invalidate() fires on EVERY navmesh rebake, so before this change the first
# unit to ask after each bake rebuilt its field synchronously inside
# unit.steer_nav. Now invalidated fields move to a stale shelf and keep
# serving - their routes predate the newest holes by at most one sync interval,
# and units slide along any new building's collision body regardless - while
# fresh builds are gated to one per FIELD_REBUILD_MIN_INTERVAL_MS, spread well
# away from the navmesh sync storms the same events cause. A destination never
# built before also waits out the gate rather than freezing a frame; its units
# steer on their NavigationAgent3Ds until then, which is measured cheap.
const FIELD_REBUILD_MIN_INTERVAL_MS := 20000

var _fields_stale: Dictionary = {}
var _stale_order: Array = []
var _last_build_ms: int = -(1 << 30)

func field_for(destination: Vector3, unit_count: int, trip_distance: float = INF) -> FlowField:
	if not should_use_field(unit_count) or trip_distance < MIN_TRIP_DISTANCE:
		return null
	var key := _key(destination)
	if _fields.has(key):
		return _fields[key]
	var now_ms := Time.get_ticks_msec()
	var gate_open := now_ms - _last_build_ms >= FIELD_REBUILD_MIN_INTERVAL_MS
	if not gate_open:
		# Serve whatever previous knowledge exists; agents carry the unit
		# meanwhile. No build is attempted, so nothing bills to this tick.
		return _fields_stale.get(key)
	var field: FlowField = FlowFieldScript.build(_nav_map, _map_half_extents, destination, _world_scale)
	_last_build_ms = now_ms
	_fields[key] = field
	_order.append(key)
	while _order.size() > MAX_CACHED:
		_fields.erase(_order.pop_front())
	return field


# Every cached field is invalidated when the navmesh changes - a building going
# up or coming down alters exactly the passability the fields were sampled from,
# and a stale field routes units straight through the new structure. Called from
# the same place that repaths live agents, for the same reason.
#
# Since 2026-08-24 the fields are DEMOTED rather than dropped: see the
# stale-while-revalidate note on field_for().
func invalidate() -> void:
	for key in _fields:
		if not _fields_stale.has(key):
			_fields_stale[key] = _fields[key]
			_stale_order.append(key)
	_fields.clear()
	_order.clear()
	while _stale_order.size() > MAX_CACHED:
		_fields_stale.erase(_stale_order.pop_front())


func _key(destination: Vector3) -> Vector2i:
	return Vector2i(
		int(round(destination.x / KEY_SNAP)),
		int(round(destination.z / KEY_SNAP)))
