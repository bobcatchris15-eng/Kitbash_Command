extends SceneTree
# Behavioral probe for the 2026-08-23 incremental-shroud rewrite of
# VisionService._update_shroud(). The skirmish log this rewrite answers
# (battle_2026-08-24T00-33-21) had vision mean 22 ms -> 394 ms as constructs
# piled up, because every tick rescanned EVERY viewer's cell disc. These tests
# pin the new contract:
#
#   1. A viewer whose inputs did not change is NOT rescanned (cost collapses
#      to fingerprint compares; pixels and shroud_version stay put).
#   2. A viewer that DID move is rescanned; idle siblings are not.
#   3. invalidate_los_cache(pos, radius) drops only discs within sight of the
#      event; far discs survive untouched.
#   4. invalidate_los_cache() with no position falls back to dropping all.
#   5. Beacon discs are acquired on reveal and released on burnout.
#   6. When every viewer is gone, _cell_refs drains to empty - no coverage
#      leaks as a permanently-visible blob.
#   7. A cached LOS pair inside an invalidated region re-raycasts on next
#      lookup (lazy refresh); a pair outside it stays cached and untouched.
#
# Run: Godot_v4.7.1-stable_win64_console.exe --headless --path . \
#          --script res://tools/probe_vision_incremental.gd --quit

const VisionService = preload("res://scripts/battle/vision/vision_service.gd")
const MapCatalog = preload("res://scripts/map_catalog.gd")
const TerrainBuilder = preload("res://scripts/terrain_builder.gd")

class MockController extends Node3D:
	var current_map: Dictionary = {}
	func terrain_height_at(pos: Vector3) -> float:
		return TerrainBuilder.terrain_height_at(current_map, pos)

var _failures: int = 0

func _check(cond: bool, label: String) -> void:
	if cond:
		print("  [PASS] %s" % label)
	else:
		print("  [FAIL] %s" % label)
		_failures += 1

func _make_viewer(parent: Node, pos: Vector3, range_v: float) -> Node3D:
	var v := Node3D.new()
	parent.add_child(v)
	v.position = pos
	v.set_meta("team", 0)
	v.set_meta("vision_range", range_v)
	return v

func _image_snapshot(vs) -> PackedByteArray:
	return vs._image.get_data()

func _init() -> void:
	print("=== PROBING INCREMENTAL SHROUD ===")
	var map_def = MapCatalog.get_map("lake_crossing")
	var controller := MockController.new()
	controller.current_map = map_def
	get_root().add_child(controller)

	var vs = VisionService.new()
	vs.setup(controller, 0, map_def.get("map_half_extents", 960.0), 4.0)

	# --- Test 1: static viewers cost nothing on the second tick -------------
	print("Test 1: idle static viewers are not rescanned")
	var viewers: Array = []
	for i in range(8):
		var p := Vector3(-420.0 + float(i) * 120.0, 0.0, -300.0 + 40.0 * float(i % 3))
		p.y = controller.terrain_height_at(p)
		viewers.append(_make_viewer(controller, p, 240.0))

	var t0 := Time.get_ticks_usec()
	vs._update_shroud(viewers, [])
	var build_us := Time.get_ticks_usec() - t0
	var version_after_build: int = vs.shroud_version
	var snap_after_build := _image_snapshot(vs)

	t0 = Time.get_ticks_usec()
	vs._update_shroud(viewers, [])
	var idle_us := Time.get_ticks_usec() - t0
	print("  first build %d us, idle tick %d us" % [build_us, idle_us])
	_check(idle_us * 4 < maxi(build_us, 200), "idle tick is <25% of first build")
	_check(snap_after_build == _image_snapshot(vs), "idle tick leaves image byte-identical")
	_check(vs.shroud_version == version_after_build, "idle tick does not bump shroud_version")

	# --- Test 2: moving one viewer rescans only that one ---------------------
	print("Test 2: a moved viewer rescans; idle siblings keep their discs")
	var mover: Node3D = viewers[3]
	var sibling_disc_before: Dictionary = vs._viewer_discs[viewers[0].get_instance_id()]
	mover.position.x += 60.0
	t0 = Time.get_ticks_usec()
	vs._update_shroud(viewers, [])
	var moved_us := Time.get_ticks_usec() - t0
	print("  moved-viewer tick %d us (single-disc rebuild)" % moved_us)
	_check(moved_us * 4 < maxi(build_us, 200), "one mover costs <25% of full rebuild")
	_check(vs._viewer_discs[viewers[0].get_instance_id()] == sibling_disc_before,
		"idle sibling disc entry untouched")
	_check(int(vs._viewer_discs[mover.get_instance_id()].pos.x * 2.0) == int(mover.position.x * 2.0),
		"mover disc fingerprint updated")

	# --- Test 3: region invalidation spares far discs ------------------------
	print("Test 3: invalidate_los_cache(pos, radius) drops only nearby discs")
	var id_of := func(v: Node) -> int: return v.get_instance_id()
	var near_pos: Vector3 = viewers[2].position
	vs.invalidate_los_cache(near_pos, 10.0)
	_check(not vs._viewer_discs.has(id_of.call(viewers[2])), "disc within reach of event dropped")
	_check(vs._viewer_discs.has(id_of.call(viewers[6])), "far disc survives region invalidation")
	vs._update_shroud(viewers, [])
	_check(vs._viewer_discs.has(id_of.call(viewers[2])), "dropped disc rebuilt on next tick")
	_check(vs._viewer_discs.has(id_of.call(viewers[6])), "far disc still present after tick")

	# --- Test 4: no-arg invalidation falls back wholesale --------------------
	print("Test 4: no-position invalidation clears every disc")
	vs.invalidate_los_cache()
	_check(vs._viewer_discs.is_empty(), "all viewer discs dropped")
	_check(vs._beacon_discs.is_empty(), "all beacon discs dropped")

	# --- Test 8: budgeted mode defers rebuilds to the frame pump -------------
	print("Test 8: amortized (budgeted) shroud updates enqueue then drain")
	vs._update_shroud(viewers, []) # restore the discs Test 4's wholesale drop removed
	var mover8: Node3D = viewers[1]
	var disc_before_8: Dictionary = vs._viewer_discs[mover8.get_instance_id()]
	mover8.position.x += 40.0
	vs._update_shroud(viewers, [], 3.0)
	_check(vs._viewer_discs[mover8.get_instance_id()] == disc_before_8,
		"budgeted update leaves the stale disc acquired (coverage never flickers)")
	_check(vs._disc_queue.size() == 1, "changed viewer was enqueued exactly once")
	vs._update_shroud(viewers, [], 3.0)
	_check(vs._disc_queue.size() == 1, "a re-changed queued viewer does not duplicate its entry")
	vs.process_pending_discs(10000.0)
	_check(vs._disc_queue.is_empty(), "pump drained the queue")
	_check(int(vs._viewer_discs[mover8.get_instance_id()].pos.x * 2.0) == int(mover8.position.x * 2.0),
		"queued viewer rebuilt from live node state by the pump")

	# --- Test 5+6: sweep, beacon lifecycle, refcount integrity ---------------
	print("Test 5: freed viewers are swept without leaking coverage")
	for v in viewers:
		v.queue_free()
	await process_frame
	vs._update_shroud([], [])
	_check(vs._viewer_discs.is_empty(), "sweep removed freed viewers' discs")
	_check(vs._cell_refs.is_empty(), "cell refs drained after all viewers gone")

	print("Test 6: flare reveals, burns out, releases its cells")
	var flare_pos := Vector3(0.0, controller.terrain_height_at(Vector3.ZERO), 0.0)
	vs.reveal_area(0, flare_pos, 150.0, 5.0)
	var beacons: Array = vs._live_beacons(0)
	vs._update_shroud([], beacons)
	_check(vs._beacon_discs.size() == 1, "beacon disc acquired")
	_check(not vs._cell_refs.is_empty(), "flare cells held")
	var flare_cell: Vector2i = vs._world_to_cell(flare_pos.x, flare_pos.z)
	_check(vs._image.get_pixelv(flare_cell).a < 0.1, "flare centre visible")
	version_after_build = vs.shroud_version
	vs._update_shroud([], beacons)
	_check(vs.shroud_version == version_after_build, "steady beacon does not bump shroud_version")

	vs._beacons[0].expires_at = Time.get_ticks_msec() - 1
	beacons = vs._live_beacons(0)
	_check(beacons.is_empty(), "expired beacon pruned from live list")
	vs._update_shroud([], beacons)
	_check(vs._beacon_discs.is_empty(), "burnt beacon disc released")
	_check(vs._cell_refs.is_empty(), "cell refs drained after beacon burnout")
	_check(absf(vs._image.get_pixelv(flare_cell).a - vs.EXPLORED_ALPHA) < 0.01,
		"flare ground back to explored, not unexplored")

	# --- Test 7: LOS cache respects dirty regions -----------------------------
	print("Test 7: region-scoped LOS cache invalidation")
	var los_a := Node3D.new()
	controller.add_child(los_a)
	los_a.position = Vector3(100.0, 0.0, 100.0)
	los_a.set_meta("team", 0)
	var los_b := Node3D.new()
	controller.add_child(los_b)
	los_b.position = Vector3(160.0, 0.0, 100.0)
	los_b.set_meta("team", 1)
	var los_c := Node3D.new()
	controller.add_child(los_c)
	los_c.position = Vector3(-800.0, 0.0, -800.0)
	los_c.set_meta("team", 1)

	_check(vs._check_los_cached(los_a, los_b, false), "a->b pair caches (result either way)")
	# a->c runs across lake_crossing's hills and MAY legitimately be occluded;
	# the test only cares about cache behaviour, so seed it without asserting.
	vs._check_los_cached(los_a, los_c, false)

	var cs: float = vs._LOS_CELL_SIZE
	var cell_of := func(p: Vector3) -> Vector2i:
		return Vector2i(int(floor(p.x / cs)), int(floor(p.z / cs)))
	var key_of := func(x: Node, y: Node) -> String:
		var ac: Vector2i = cell_of.call(x.position)
		var bc: Vector2i = cell_of.call(y.position)
		return "%d:%d:%d:%d:%d:%d:%d:%d" % [
			vs._los_geom_version, x.get_instance_id(), y.get_instance_id(),
			ac.x, ac.y, bc.x, bc.y, 0,
		]
	var key_ab: String = key_of.call(los_a, los_b)
	var key_ac: String = key_of.call(los_a, los_c)
	_check(vs._los_cache.has(key_ab), "a->b pair resident in cache")
	_check(vs._los_cache.has(key_ac), "a->c pair resident in cache")
	var ab_written_before: int = int(vs._los_cache[key_ab].written_at)
	var ac_written_before: int = int(vs._los_cache[key_ac].written_at)
	var ac_result_before: bool = vs._los_cache[key_ac].result

	# Drop geometry between a and b. The region must flag the a->b line dirty
	# while leaving the a->c line alone - entries stay resident; the LOOKUP
	# decides staleness (lazy refresh, no wholesale clear).
	vs.invalidate_los_cache(Vector3(130.0, 0.0, 100.0), 20.0)

	var mid_cell: Vector2i = cell_of.call(Vector3(130.0, 0.0, 100.0))
	_check(vs._pair_in_dirty_region(mid_cell, mid_cell, 0),
		"region contains its own centre cells")
	var ab_pair: Array = [cell_of.call(los_a.position), cell_of.call(los_b.position)]
	_check(vs._pair_in_dirty_region(ab_pair[0], ab_pair[1], ab_written_before),
		"a->b endpoints flagged dirty against pre-region entry")
	_check(not vs._pair_in_dirty_region(ab_pair[0], ab_pair[1], Time.get_ticks_msec()),
		"a->b endpoints clean for a post-region entry")

	_check(vs._check_los_cached(los_a, los_b, false), "a->b re-check succeeds post-region")
	_check(int(vs._los_cache[key_ab].written_at) >= ab_written_before,
		"a->b entry refreshed by the lookup")
	_check(int(vs._los_cache[key_ac].written_at) == ac_written_before,
		"a->c entry untouched by the region")
	_check(vs._check_los_cached(los_a, los_c, false) == ac_result_before,
		"a->c served with its pre-region answer (terrain may occlude it)")

	if _failures == 0:
		print(">>> ALL INCREMENTAL SHROUD TESTS PASSED <<<")
	else:
		print(">>> %d TEST(S) FAILED <<<" % _failures)
	quit(0 if _failures == 0 else 1)
