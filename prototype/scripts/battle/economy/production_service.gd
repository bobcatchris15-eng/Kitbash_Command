class_name ProductionService
extends RefCounted
# Five global queues per team: Light, Medium, Heavy, Building, Defense.
#
# THE MODEL (Chris's call for this rebuild). Each type has exactly ONE queue per
# team. Every live structure contributing to that type feeds the same queue and
# speeds it up - a second heavy manufactory does not open a second heavy line, it
# makes the one heavy line faster. That is the Westwood macroeconomic tension:
# expanding your base is an investment in tempo rather than in parallelism.
#
# WHAT CHANGED FROM THE OLD RUNTIME. Very little on the unit side - it already
# had per-tier queues with the same speed table. Two real differences:
#
#   * `structures` was ONE queue holding both buildings and defences. It is now
#     two, so a refinery and a turret can be under construction at once.
#   * A defence had NO build time - you paid and placed it instantly. It now
#     takes real time, making a defensive wall a tempo decision and not purely a
#     money one.
#
# WHAT WAS KEPT, AND WHY IT WAS KEPT. The research this rebuild is following
# proposes a logarithmic speed curve, T = T_base * max(M_min, 1 - a*ln(N)). That
# is an invented formula with two free parameters and no shipped game behind it.
# The table below is Red Alert's actual build_time_speed_reduction. It is already
# tuned, already benchmarked, and already what the old suites assert. Keeping it.

const BuildingCatalogScript = preload("res://scripts/battle/economy/building_catalog.gd")
const DesignCostingScript = preload("res://scripts/battle/economy/design_costing.gd")
# SKIRMISH_PERF_TROUBLESHOOTING.md §10.8 item 6. `production` measured 4.27 ms
# mean on EVERY frame with a 429 ms worst, and reached 9.2 s of CPU inside one
# 30 s window late in the 2026-08-19T19-57-23 match. That is far too much for
# what is mostly arithmetic over a handful of queue entries, so the cost is in
# the parts that leave this file: the completion emits (which spawn a unit or
# finish a building) and the exit-blocker query (which walks the scene).
# Reached through preload rather than the `BattleProfiler` class name, matching
# match_director.gd - see profile_battle_run.gd's header for why the two must
# not be mixed.
const Profiler = preload("res://scripts/battle/battle_profiler.gd")

# Percent of normal build time, indexed by (contributing structures - 1), held at
# the last entry for 4 or more. Straight from RA.
const SPEED_PCT: Array[int] = [100, 75, 60, 50]

signal queue_changed(team: int, queue: String)
signal unit_completed(team: int, queue: String, blueprint: Dictionary, slot: int)
signal structure_ready(team: int, queue: String, job: Dictionary)

var _queues: Dictionary = {}
var _economy: EconomyService = null
# Duck-typed back to the match director for "how many live contributors does this
# team have" and "is the exit blocked". Kept to two narrow questions rather than
# the whole controller, which is what the old ProductionQueue took.
var _world = null


func setup(economy: EconomyService, world) -> void:
	_economy = economy
	_world = world


func add_team(team: int) -> void:
	var lanes := {}
	for q in BuildingCatalogScript.QUEUES:
		lanes[q] = []
	_queues[team] = lanes


func queue(team: int, name: String) -> Array:
	return _queues.get(team, {}).get(name, [])


func depth(team: int, name: String) -> int:
	return queue(team, name).size()


# --- Enqueueing --------------------------------------------------------------

# Adds a unit design to the queue its hull weight puts it in.
#
# Returns the job, or an empty dictionary if the team has no live structure
# feeding that queue - queueing a heavy tank with no heavy manufactory has to
# fail loudly at the door rather than sit in a line that can never advance.
func enqueue_unit(team: int, blueprint: Dictionary, cost: int,
		base_time: float, queue_name: String, slot: int = -1) -> Dictionary:
	var contributors := _contributor_count(team, queue_name)
	if contributors <= 0:
		return {}
	if not _missing_required_buildings(team, blueprint).is_empty():
		return {}
	var job := _make_job(blueprint.get("name", "UNIT"), cost, base_time, contributors, team)
	job["blueprint"] = blueprint
	job["is_structure"] = false
	job["slot"] = slot
	queue(team, queue_name).append(job)
	queue_changed.emit(team, queue_name)
	return job


# Adds a structure. `kind` is a BuildingCatalog key for the Building queue, or
# the blueprint is a custom defence design for the Defense queue.
func enqueue_structure(team: int, queue_name: String, kind: String,
		cost: int, base_time: float, blueprint: Dictionary = {},
		structure_node: Node = null) -> Dictionary:
	var contributors := _contributor_count(team, queue_name)
	if contributors <= 0:
		return {}
	# Only a blueprint-built defence has anything to gate on - a prefab kind off
	# the Building queue (a manufactory, a lab itself) is never itself required
	# to already own a lab.
	if not blueprint.is_empty() and not _missing_required_buildings(team, blueprint).is_empty():
		return {}
	var job := _make_job(kind, cost, base_time, contributors, team)
	job["kind"] = kind
	job["blueprint"] = blueprint
	job["is_structure"] = true
	job["structure_node"] = structure_node
	queue(team, queue_name).append(job)
	queue_changed.emit(team, queue_name)
	return job


# The build time modifier is LATCHED at enqueue time, deliberately. Building or
# losing a contributor later never retroactively re-times an item already in the
# line - a job that was quoted 20 seconds takes 20 seconds. Only the low-power
# rate is live, because that one is a penalty the player can see and fix.
const DebugSettingsScript = preload("res://scripts/debug_settings.gd")

func _instant_build_cheat() -> bool:
	var ds = DebugSettingsScript.get_active()
	return ds != null and ds.instant_build


func _make_job(label: String, cost: int, base_time: float, contributors: int, team: int = -1) -> Dictionary:
	var index: int = clampi(contributors - 1, 0, SPEED_PCT.size() - 1)
	var build_time: float = base_time * float(SPEED_PCT[index]) / 100.0

	if team >= 0 and _world != null and _world.has_method("structures_of_kinds"):
		if not _world.structures_of_kinds(team, ["ancillary_facility"]).is_empty():
			build_time *= 0.80

	if _instant_build_cheat():
		build_time = 0.001
	return {
		"label": label,
		"time_left": build_time,
		"total_time": maxf(build_time, 0.001),
		"total_cost": cost,
		"remaining_cost": float(cost),
		"paused": false,
		"stalled": false,
		"done": false,
	}


# Takes the finished structure sitting at the head of `queue_name`, or {} if the
# head is not one.
#
# A COMPLETED STRUCTURE BLOCKS ITS OWN QUEUE until this is called. That is by
# design - the building is paid for and waiting for somewhere to go, and dropping
# it because nobody claimed it in time would silently burn the player's money -
# but it does mean an unconnected structure_ready signal stops that line dead.
# Which is exactly how it first failed: the AI paid for a manufactory, the job
# sat done at the head forever, and its economy froze with the money already
# spent and nothing to show.
func claim_structure(team: int, queue_name: String) -> Dictionary:
	var q := queue(team, queue_name)
	if q.is_empty():
		return {}
	var job: Dictionary = q[0]
	if not job.get("is_structure", false) or not job.get("done", false):
		return {}
	q.pop_front()
	queue_changed.emit(team, queue_name)
	return job


func cancel(team: int, queue_name: String, index: int) -> Dictionary:
	var q := queue(team, queue_name)
	if index < 0 or index >= q.size():
		return {}
	var job: Dictionary = q[index]
	var s_node = job.get("structure_node", null)
	if s_node != null and is_instance_valid(s_node):
		s_node.queue_free()
	# Refund what was actually DRAWN, not the full price. Under the drip-fed
	# model a job part-way through has only paid part of its cost, and refunding
	# the whole thing would make queue-and-cancel a money printer.
	var spent: int = int(job["total_cost"]) - int(round(job["remaining_cost"]))
	q.remove_at(index)
	if _economy:
		_economy.credit(team, spent)
	queue_changed.emit(team, queue_name)
	return job


func set_paused(team: int, queue_name: String, paused: bool) -> void:
	var q := queue(team, queue_name)
	if not q.is_empty():
		q[0]["paused"] = paused
		queue_changed.emit(team, queue_name)


# Losing the last contributor to a queue refunds everything in it - the line can
# never advance again, so holding the player's money hostage is just a bug with
# extra steps. Losing ONE of several leaves the queue alone.
func cancel_unbuildable(team: int) -> void:
	for queue_name in BuildingCatalogScript.QUEUES:
		if _contributor_count(team, queue_name) > 0:
			continue
		while not queue(team, queue_name).is_empty():
			cancel(team, queue_name, 0)


# --- Tick --------------------------------------------------------------------

func tick(delta: float) -> void:
	if _economy == null:
		return
	for team in _queues:
		var rate := _economy.production_rate(team)
		for queue_name in BuildingCatalogScript.QUEUES:
			_tick_queue(team, queue_name, delta * rate)


func _tick_queue(team: int, queue_name: String, delta: float) -> void:
	var q := queue(team, queue_name)
	if q.is_empty():
		return
	var job: Dictionary = q[0]
	if job["paused"]:
		job["stalled"] = true
		if job.get("is_structure", false):
			var s_node = job.get("structure_node", null)
			if s_node != null and is_instance_valid(s_node):
				var progress: float = 1.0 - (job["time_left"] / job["total_time"])
				s_node.update_construction_progress(progress, true)
		return

	# DRIP-FED COST, from OpenRA's ProductionItem.Tick adapted to continuous
	# delta-seconds. The cost is drawn gradually across the build rather than up
	# front, so a queue you cannot afford stalls instead of refusing, and the
	# money is committed at the rate the work happens.
	#
	# `expected_remaining` is computed against the PROSPECTIVE time_left - how
	# much of the total cost should still be outstanding once this tick's work is
	# done - not the current one.
	var new_time_left: float = maxf(0.0, job["time_left"] - delta)
	var expected_fraction: float = new_time_left / job["total_time"]
	var draw := int(round(maxf(0.0,
		job["remaining_cost"] - job["total_cost"] * expected_fraction)))

	if not _economy.spend(team, draw):
		# NO progress this tick - a pause, not a slowdown. time_left and the
		# remaining cost both stay exactly where they were, so a team that comes
		# into money resumes rather than having silently lost ground.
		job["stalled"] = true
		if job.get("is_structure", false):
			var s_node = job.get("structure_node", null)
			if s_node != null and is_instance_valid(s_node):
				var progress: float = 1.0 - (job["time_left"] / job["total_time"])
				s_node.update_construction_progress(progress, true)
		return

	job["stalled"] = false
	job["remaining_cost"] -= draw
	job["time_left"] = new_time_left

	if job.get("is_structure", false):
		var s_node = job.get("structure_node", null)
		if s_node != null and is_instance_valid(s_node):
			var progress: float = 1.0 - (job["time_left"] / job["total_time"])
			s_node.update_construction_progress(progress, false)

	if job["time_left"] > 0.0:
		return

	# --- Complete ---
	# Everything below runs on the ONE frame a job finishes, which is exactly
	# the shape of `production`'s 429 ms worst against its 0.19 ms mean. Split
	# into structure-completion and unit-completion because they leave this
	# file through different doors: finish_construction() rebuilds a building's
	# mesh, unit_completed spawns a vehicle (already timed as `spawn_unit`, and
	# it nests inside this).
	job["done"] = true
	if job["is_structure"]:
		var _t_cs := Profiler.start()
		var s_node = job.get("structure_node", null)
		if s_node != null and is_instance_valid(s_node):
			s_node.finish_construction()
			q.pop_front()
			structure_ready.emit(team, queue_name, job)
			queue_changed.emit(team, queue_name)
			Profiler.stop("production.complete_structure", _t_cs)
			return
		structure_ready.emit(team, queue_name, job)
		Profiler.stop("production.complete_structure", _t_cs)
		return

	# A finished unit waits for a clear exit rather than spawning on top of
	# whatever is parked there. Blockers get a real nudge instead of being
	# silently phased through.
	#
	# 2026-08-19: this block was DUPLICATED verbatim, twice in a row, with no
	# return between the copies (present in HEAD as of 9474128c, lines 274-296).
	# The second copy re-ran on every unit completion: a second q.pop_front()
	# discarded the NEXT queued job without building it, and a second
	# unit_completed.emit() spawned a second vehicle from the same blueprint.
	# The duplicate is removed here. It is a behaviour change rather than pure
	# instrumentation, and it was not optional for this pass - profiling tokens
	# around one copy while the other ran unwrapped would have reported half the
	# real cost. `spawn_unit` measured 124.8 ms mean, so the phantom spawn was
	# also paying that a second time per unit.
	#
	# Timed separately: this runs on EVERY frame a completed unit is waiting
	# for its exit to clear, not just once, and it asks the world to walk its
	# unit list. A factory blocked for several seconds pays this repeatedly,
	# which makes it a candidate for the steady 4.27 ms rather than the spike.
	if _world != null and _world.has_method("exit_blockers_for"):
		var _t_bl := Profiler.start()
		var blockers: Array = _world.exit_blockers_for(team, queue_name)
		if not blockers.is_empty():
			if _world.has_method("nudge_blockers"):
				_world.nudge_blockers(team, queue_name, blockers)
			Profiler.stop("production.exit_blockers", _t_bl)
			return
		Profiler.stop("production.exit_blockers", _t_bl)
	var _t_cu := Profiler.start()
	q.pop_front()
	unit_completed.emit(team, queue_name, job["blueprint"], int(job.get("slot", -1)))
	queue_changed.emit(team, queue_name)
	Profiler.stop("production.complete_unit", _t_cu)


# --- Contributors ------------------------------------------------------------

# How many live structures feed `queue_name` for this team. This is the number
# the RA speed table is indexed by, and the gate on whether the queue accepts
# anything at all.
func _contributor_count(team: int, queue_name: String) -> int:
	if _world == null or not _world.has_method("structures_of_kinds"):
		# No world (a test exercising the queue maths directly). Assume a single
		# contributor so the table's first entry applies and nothing is gated.
		return 1
	return _world.structures_of_kinds(team, BuildingCatalogScript.contributors_for(queue_name)).size()


func contributor_count(team: int, queue_name: String) -> int:
	return _contributor_count(team, queue_name)


# --- Tech tree gate ------------------------------------------------------------

# The design's required labs the team does NOT currently have a live copy of.
# Empty means the design is clear to queue.
#
# No world means no gate, same reasoning as _contributor_count(): a test
# exercising the queue maths directly (no match_director behind it) has no
# structures to check against, and refusing every enqueue in that context would
# make the maths untestable rather than making the gate correct.
func _missing_required_buildings(team: int, blueprint: Dictionary) -> Array[String]:
	var required: Array[String] = DesignCostingScript.blueprint_required_buildings(blueprint)
	if required.is_empty():
		return []
	if _world == null or not _world.has_method("structures_of_kinds"):
		return []
	var missing: Array[String] = []
	for kind in required:
		if _world.structures_of_kinds(team, [kind]).is_empty():
			missing.append(kind)
	return missing


func missing_required_buildings(team: int, blueprint: Dictionary) -> Array[String]:
	return _missing_required_buildings(team, blueprint)


# What the HUD needs to draw one queue strip, without reaching into the job dicts.
func status(team: int, queue_name: String) -> Dictionary:
	var q := queue(team, queue_name)
	if q.is_empty():
		return {"empty": true, "depth": 0, "progress": 0.0, "label": "", "stalled": false}
	var job: Dictionary = q[0]
	return {
		"empty": false,
		"depth": q.size(),
		"progress": 1.0 - (job["time_left"] / job["total_time"]),
		"label": job["label"],
		"stalled": job["stalled"],
		"done": job["done"],
	}
