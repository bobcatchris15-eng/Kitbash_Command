class_name HarvesterFSM
extends RefCounted
# The harvest loop as an explicit state machine, with bay reservation.
#
# WHAT WAS WRONG BEFORE. The old loop was `_process_harvest()`, forty lines
# inside battle_unit.gd's order switch (battle_unit.gd:1363; battle_unit.gd
# retired 2026-08-10 in the unification's Phase 4). It had no states -
# it inferred what to do each tick from whether cargo was full and whether the
# node still existed - and, critically, no notion of a refinery having a finite
# number of places to stand. Every harvester steered at the refinery's ORIGIN. So
# four harvesters returning together all drove at the same point, arrived inside
# each other, and shoved. That is the jam.
#
# THE FIX IS THE RESERVATION, NOT THE STATES. A harvester claims a numbered bay
# BEFORE it sets off for home, and drives to that bay. If every bay is taken it
# enters QUEUED and orbits a holding point clear of the refinery until one frees
# up. Two harvesters can now never be routed to the same square metre.
#
# The states are what makes that expressible: "I have a reservation and am
# travelling to it" is a different thing from "I am waiting for one", and the old
# implementation had no way to say either.

const ModuleCatalogScript = preload("res://scripts/module_catalog.gd")
const ResourceCatalogScript = preload("res://scripts/battle/economy/resource_catalog.gd")

const HARVEST_TIME := 3.0

# How much comes out of a patch per HARVEST_TIME, before faction bonuses.
#
# 25, MATCHING THE OLD RUNTIME (battle_unit.gd:1396; retired 2026-08-10).
# The FSM rewrite quietly
# dropped this to 10, which is not a tuning difference - it is 5 cycles to fill a
# 50-unit hopper instead of 2, so the working half of a round trip went from 6 s
# to 15 s. Chris felt it as harvesters being sluggish, which they were.
#
# 2026-08-07, BALANCE PASS. Measured, not guessed - see ECONOMY_BALANCE.md.
#
# First to 40 (with capacity 50 -> 80) to hit the income target. Then back to 28
# (capacity 56) once value-weighted node selection landed: harvesters that chase
# credits rather than metres earn ~37% more from the same fleet, so the hopper
# had to come back down to hold the same target.
#
# THE CHUNK ALWAYS MOVES WITH THE HOPPER. A round trip on open_plains is ~10 s of
# which only ~6 s is spent filling, so scaling the hopper alone lengthens the trip
# by exactly what it adds to the load and delivers nothing - it looks like a
# change and measures as none. Both stay at capacity / chunk = 2 cycles.
const HARVEST_CHUNK := 28

# The old runtime delivered the INSTANT a harvester reached the refinery, with no
# unload phase at all. A short dwell is worth keeping - it is what makes a dock
# read as a dock, and it gives the bay queue something to queue for - but 2 s was
# invented, not measured, and on top of the chunk regression above it made the
# whole loop feel stuck.
#
# Note the dwell is NOT what makes bay reservation work: reservations stop two
# harvesters being routed to the same spot on the way IN, which matters whether
# or not they linger once there.
const UNLOAD_TIME := 0.6
# How close counts as being at the node / at the bay.
const WORK_DISTANCE := 3.0

# THE FLOOR, not the whole answer - see _dock_distance().
#
# A fixed 2.0 m was too tight to be reachable. A harvester's nav agent stops
# within its own arrive distance, which scales with speed, and the unit is a
# vehicle several metres long whose ORIGIN is what gets measured. Requiring that
# origin within 2 m of a point beside a building asks a truck to park with a
# tolerance smaller than its own arrive slop; it docked by centimetres when it
# docked at all.
const DOCK_DISTANCE := 2.0

# A harvester that cannot reach its reserved bay must eventually give it up.
#
# THIS IS THE ONE THAT MATTERS. Before it, a harvester that could not close the
# last metre stayed in MOVING_TO_BAY forever, holding a reservation nothing could
# reclaim - so a refinery with three bays permanently lost one to a single stuck
# truck, then another, and the economy quietly died. The geometry fixes above
# make that unlikely; this makes it non-permanent, which matters more, because
# any future building whose bays end up awkward reintroduces the same deadlock.
const DOCK_TIMEOUT := 20.0
# Progress means closing on the bay. Anything less than this over the timeout
# window is not "slow", it is stuck.
const DOCK_PROGRESS_EPSILON := 0.5
# Where a harvester with no bay waits. Far enough out that the orbit never
# obstructs the bays themselves, which would deadlock the queue it is waiting in.
const HOLDING_RADIUS := 14.0

enum State {
	# Nothing to do: look for a node.
	SEARCHING,
	MOVING_TO_NODE,
	HARVESTING,
	# Full, holding a bay reservation, driving to it.
	MOVING_TO_BAY,
	# Full, no bay free. Orbiting the refinery until one is.
	QUEUED,
	UNLOADING,
}

var state: State = State.SEARCHING
var node: Node3D = null
var refinery: Node3D = null
var bay_index: int = -1
# Which position on the ore patch's ring this harvester works from. Same idea as
# a dock bay: without it, every harvester on a patch steers at its exact origin
# and they stand inside each other.
var node_slot: int = -1
# THE HOPPER IS KEYED BY RESOURCE TYPE, not by destination pool.
#
# It used to be two ints, cargo_metal and cargo_crystal, which worked only while
# there were exactly two resources and each was its own pool. With lumber and oil
# added - and with all four heading for a single credits pool - what a truck is
# carrying and what it is worth are different questions, and the hopper is the
# wrong place to answer the second one. ResourceCatalog.deliver_value() does that
# at the refinery door.
var cargo_by_type: Dictionary = {}
# THE HOPPER, and it is a property of the DESIGN, not a constant.
#
# It used to be a flat 50 for everything, which in a game whose entire premise is
# that you design the units meant a purpose-built ore hauler carried exactly as
# much as a scout car with a harvester arm bolted on. Now it is
# BASE_CAPACITY x modules x hull tier, so mounting a second harvester arm or
# choosing a heavier chassis is a real economic decision with a real cost in
# metal, weight and speed.
#
# 56 is the balance number, measured against Chris's spec rather than chosen.
# See HARVEST_CHUNK above and ECONOMY_BALANCE.md for how it moved.
const BASE_CAPACITY := 56
# Bigger chassis, bigger hopper. Extraction scales with it (see _chunk_size) so
# fill TIME is constant across tiers - the advantage of a heavy hauler is fewer
# trips for the same ore, paid for in cost and speed, not in a longer dwell at
# the patch.
const TIER_CAPACITY_MULT := {"light": 0.7, "medium": 1.0, "heavy": 1.5}

var capacity: int = BASE_CAPACITY
# How many resource_harvester modules the design mounts. Scales hopper AND
# extraction together, so a second arm doubles throughput per trip rather than
# doubling the time spent filling.
var modules: int = 1
var _tier_mult: float = 1.0

var _timer: float = 0.0
var _orbit_phase: float = 0.0
# Stuck detection for the approach to a reserved bay.
var _stuck_timer: float = 0.0
var _closest_gap: float = INF
# Set when QUEUED was entered to escape a failed approach rather than to wait for
# a free bay. Gates re-reservation until the truck is actually clear.
var _must_clear: bool = false

var _unit: Node3D = null
var _world = null


func setup(unit: Node3D, world) -> void:
	_unit = unit
	_world = world


# Sizes the hopper and the extraction rate from the design. Called by unit.gd
# right after setup(); a harvester that never gets configured keeps the medium
# single-module defaults, which is what every synthetic test builds.
func configure(module_count: int, hull_type: String, bay_capacity: float = 0.0) -> void:
	modules = maxi(1, module_count)
	var tier: String = ModuleCatalogScript.get_hull_size_tier(hull_type)
	_tier_mult = float(TIER_CAPACITY_MULT.get(tier, 1.0))
	capacity = capacity_for(module_count, hull_type, bay_capacity)


# The hopper formula, as a static so a UI can quote it without instantiating a
# state machine. Extracted when the Blueprint Library and the match-setup roster
# cards started showing a harvester's payload: a card that re-derived the number
# is exactly how the Design Lab's stat rail drifted from combat twice before
# (see drivetrain.gd's header), and "how much does this thing carry" is precisely
# the figure a player picks a hauler on.
static func capacity_for(module_count: int, hull_type: String, bay_capacity: float = 0.0) -> int:
	var mods: int = maxi(1, module_count)
	var tier: String = ModuleCatalogScript.get_hull_size_tier(hull_type)
	var tier_mult: float = float(TIER_CAPACITY_MULT.get(tier, 1.0))
	# Resource Bays are added AFTER the tier multiplier, not multiplied by it.
	# A bay is a fixed physical volume bolted to the hull - it holds what it
	# holds whether the chassis under it is light or heavy - whereas the tier
	# multiplier models the hull's own built-in hopper. Folding bays inside it
	# would have made the same bay worth twice as much on a heavy as on a light,
	# which is backwards: bays exist so a LIGHT harvester has an answer to a long
	# haul without having to become a heavy one.
	#
	# Defaulted to 0.0 so the synthetic tests that call configure(1, "brenntal_medium_a")
	# keep their existing capacity exactly.
	return maxi(1, int(round(
		float(BASE_CAPACITY) * float(mods) * tier_mult + maxf(0.0, bay_capacity))))


func cargo() -> int:
	var total := 0
	for type_id in cargo_by_type:
		total += int(cargo_by_type[type_id])
	return total


func is_full() -> bool:
	return cargo() >= capacity


# Releases any held reservation. Called on death and on being given a manual
# order - a bay held by a harvester that is never coming back is a bay
# permanently removed from the economy, and three of those stop a refinery dead.
func release() -> void:
	if refinery != null and is_instance_valid(refinery) and bay_index >= 0:
		refinery.release_bay(_unit)
	bay_index = -1
	refinery = null


# Both ends of the round trip hold reservations, so both have to be given back.
func release_all() -> void:
	release()
	_release_node()


func _release_node() -> void:
	if node != null and _world != null and node_slot >= 0:
		_world.release_node_slot(node, _unit)
	node_slot = -1


func tick(delta: float) -> void:
	if _unit == null or _world == null:
		return
	match state:
		State.SEARCHING:
			_search()
		State.MOVING_TO_NODE:
			_move_to_node()
		State.HARVESTING:
			_harvest(delta)
		State.MOVING_TO_BAY:
			_move_to_bay(delta)
		State.QUEUED:
			_wait_for_bay(delta)
		State.UNLOADING:
			_unload(delta)


func _search() -> void:
	# Carrying something with nowhere to put it? Go home first. A harvester that
	# spawns full, or whose node is depleted mid-load, must not wander off to
	# find another node while holding cargo it could bank right now.
	if cargo() > 0:
		_head_home()
		return
	node = _world.nearest_resource_node(_unit.global_position, _unit)
	if node == null:
		return
	node_slot = _world.claim_node_slot(node, _unit)
	state = State.MOVING_TO_NODE
	_unit.set_internal_destination(_work_position())


# Where this harvester stands to work, which is a point on the patch's ring
# rather than the patch itself.
func _work_position() -> Vector3:
	if _world == null or node == null:
		return Vector3.ZERO
	return _world.node_slot_position(node, node_slot)


func _move_to_node() -> void:
	if not is_instance_valid(node) or node.amount <= 0:
		# Mined out from under us by someone else while we were in transit.
		_release_node()
		state = State.SEARCHING
		return
	if _unit.global_position.distance_to(_work_position()) <= WORK_DISTANCE:
		_unit.halt()
		state = State.HARVESTING
		_timer = 0.0


func _harvest(delta: float) -> void:
	if not is_instance_valid(node) or node.amount <= 0:
		if cargo() > 0:
			_head_home()
		else:
			_release_node()
			_to_searching()
		return
	_timer += delta
	if _timer < HARVEST_TIME:
		return
	_timer = 0.0
	var take: int = mini(_chunk_size(), mini(node.amount, capacity - cargo()))
	if take <= 0:
		_head_home()
		return
	node.amount -= take
	var type_id: String = ResourceCatalogScript.canonical(node.resource_type)
	cargo_by_type[type_id] = int(cargo_by_type.get(type_id, 0)) + take
	if is_full():
		_head_home()


# Claim a bay before setting off. The reservation is the whole point: without it
# this is the old behaviour with extra steps.
# Faction-scaled extraction rate.
#
# The `harvest_rate_mult` passive existed in the old runtime and the FSM rewrite
# dropped it entirely, so a faction whose whole identity is faster extraction had
# a passive that silently did nothing. Read off the hull, which is where
# reconstruct_vehicle() writes it.
func _chunk_size() -> int:
	var faction := "industrialists"
	if _unit != null and is_instance_valid(_unit.hull_node) and _unit.hull_node.has_meta("faction"):
		faction = _unit.hull_node.get_meta("faction")
	# Scaled by modules and tier exactly as capacity is, so the number of
	# extraction cycles per load - and therefore the time spent at the patch - is
	# the same whatever the design. Without this, a bigger hopper would simply
	# mean a longer dwell and no more ore per second.
	var rate: float = float(HARVEST_CHUNK) * float(modules) * _tier_mult
	return maxi(1, int(rate))


func _head_home() -> void:
	# Give the ore patch back on the way out. A slot held by a truck that is
	# halfway across the map is a slot removed from the economy for the whole
	# round trip.
	_release_node()
	refinery = _world.nearest_refinery(_unit.global_position, _unit.team)
	if refinery == null:
		# Nowhere to deliver. Sit on the cargo rather than dumping it - a
		# refinery may well be under construction right now.
		_unit.halt()
		state = State.SEARCHING
		return
	bay_index = refinery.reserve_bay(_unit)
	if bay_index < 0:
		state = State.QUEUED
		_orbit_phase = 0.0
		return
	_begin_bay_approach()


# Every entry into MOVING_TO_BAY resets the stuck watch, or a harvester that had
# a slow approach last trip arrives on this one with the clock already running.
func _begin_bay_approach() -> void:
	state = State.MOVING_TO_BAY
	_stuck_timer = 0.0
	_closest_gap = INF
	_unit.set_internal_destination(refinery.bay_position(bay_index))


# How close this particular harvester has to get before it counts as docked.
#
# Derived from the unit rather than fixed, because the thing that has to fit is
# the unit: its nav agent gives up inside its own arrive distance, and a bigger,
# faster truck has a bigger one. Asking every hull to hit the same 2 m is what
# made docking depend on centimetres.
func _dock_distance() -> float:
	var slop := 0.0
	if _unit != null and _unit.has_method("_arrive_distance"):
		slop = _unit._arrive_distance()
	return maxf(DOCK_DISTANCE, slop + 1.5)


func _move_to_bay(delta: float) -> void:
	if not is_instance_valid(refinery):
		# Blown up in transit. Find another one; the cargo survives.
		bay_index = -1
		refinery = null
		_head_home()
		return
	var bay: Vector3 = refinery.bay_position(bay_index)
	var gap: float = _unit.global_position.distance_to(bay)
	if gap <= _dock_distance():
		_unit.halt()
		state = State.UNLOADING
		_timer = 0.0
		return

	# Stuck check. Closing on the bay resets the clock; failing to close for
	# DOCK_TIMEOUT means this approach is not working.
	#
	# THE RECOVERY HAS TO MOVE THE TRUCK, not just re-decide. The obvious version -
	# release the bay and call _head_home() again - is a livelock: a harvester
	# wedged on the refinery's corner immediately re-reserves a bay, steers at it
	# from the exact spot it is jammed in, and re-jams. Measured doing precisely
	# that, cycling its own stuck timer forever while never delivering.
	#
	# So it backs off to the holding ring first, via the same QUEUED state a
	# harvester with no free bay uses. That clears the wall, and the re-approach
	# comes in from a different angle rather than the one that failed.
	if gap < _closest_gap - DOCK_PROGRESS_EPSILON:
		_closest_gap = gap
		_stuck_timer = 0.0
	else:
		_stuck_timer += delta
		if _stuck_timer >= DOCK_TIMEOUT:
			release()
			_stuck_timer = 0.0
			_closest_gap = INF
			_back_off()
			return
	_unit.set_internal_destination(bay)


# Retreat to the holding ring and re-queue. Keeps the cargo and the refinery, so
# this is a re-approach rather than starting the round trip over.
func _back_off() -> void:
	refinery = _world.nearest_refinery(_unit.global_position, _unit.team)
	if refinery == null:
		_unit.halt()
		state = State.SEARCHING
		return
	# A phase from the current bearing to the refinery, so the ring point it backs
	# out to is the way it came rather than through the building.
	var away: Vector3 = _unit.global_position - refinery.global_position
	_orbit_phase = atan2(away.z, away.x)
	state = State.QUEUED
	_must_clear = true
	_unit.set_internal_destination(refinery.global_position + Vector3(
		cos(_orbit_phase) * HOLDING_RADIUS, 0.0, sin(_orbit_phase) * HOLDING_RADIUS))


# Orbit a holding point rather than pressing against the refinery. Pressing is
# what turns a queue into a scrum: waiting harvesters block the bays that the
# docked ones need to leave by.
func _wait_for_bay(delta: float) -> void:
	if not is_instance_valid(refinery):
		refinery = null
		_head_home()
		return
	# A harvester that got here by backing OFF a failed approach must actually
	# reach the ring before it is allowed to reserve again. Without this gate it
	# re-reserves on the very next tick, from the same wedged spot, and the back-off
	# never happens - which is the livelock this whole path exists to break.
	if _must_clear:
		var out: float = _unit.global_position.distance_to(refinery.global_position)
		if out < HOLDING_RADIUS * 0.9:
			_unit.set_internal_destination(refinery.global_position + Vector3(
				cos(_orbit_phase) * HOLDING_RADIUS, 0.0, sin(_orbit_phase) * HOLDING_RADIUS))
			return
		_must_clear = false
	bay_index = refinery.reserve_bay(_unit)
	if bay_index >= 0:
		_begin_bay_approach()
		return
	_orbit_phase += delta * 0.6
	var centre: Vector3 = refinery.global_position
	_unit.set_internal_destination(centre + Vector3(
		cos(_orbit_phase) * HOLDING_RADIUS, 0.0, sin(_orbit_phase) * HOLDING_RADIUS))


func _unload(delta: float) -> void:
	if not is_instance_valid(refinery):
		# Destroyed while we were unloading. Whatever is left in the hopper is
		# lost with it.
		cargo_by_type.clear()
		bay_index = -1
		refinery = null
		_to_searching()
		return
	_timer += delta
	if _timer < UNLOAD_TIME:
		return
	# Converted per type at the door: a full hopper of oil is worth four times the
	# same hopper of lumber, and the truck never had to know that.
	var payout := 0
	for type_id in cargo_by_type:
		payout += ResourceCatalogScript.deliver_credits(type_id, int(cargo_by_type[type_id]))

	if _world != null and _world.has_method("structures_of_kinds"):
		var refineries: Array = _world.structures_of_kinds(_unit.team, ["advanced_refinery"])
		for r in refineries:
			if is_instance_valid(r) and not r.is_dead and refinery.global_position.distance_to(r.global_position) <= 25.0:
				payout = int(round(payout * 1.70))
				break

	_world.deliver(_unit.team, payout)
	cargo_by_type.clear()
	release()
	_to_searching()


func _to_searching() -> void:
	_release_node()
	state = State.SEARCHING
	node = null
	_timer = 0.0


# --- Death ------------------------------------------------------------------

# A loaded harvester detonates. Classic C&C, and a real tactical layer: it makes
# economic harassment worth timing, because killing a full harvester inside an
# enemy base does collateral damage rather than just denying income.
#
# Scales with what it was carrying, so an empty one is merely a dead truck.
func death_explosion_damage() -> float:
	if capacity <= 0:
		return 0.0
	return 60.0 * (float(cargo()) / float(capacity))


func death_explosion_radius() -> float:
	if cargo() <= 0:
		return 0.0
	return 6.0
