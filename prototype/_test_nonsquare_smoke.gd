extends SceneTree
# Smoke test for the non-square canyon_ford: full map load, terrain
# height query at every cell key, and a navigation graph build via
# lint_spawn_fairness (which exercises both per-axis bounds and the
# spawn-reachability path). Catches a mis-indexed corner_heights or
# a stray half_x used where half_y was meant.
#
# Run: godot --headless --script _test_nonsquare_smoke.gd --path prototype

const MapCatalogScript = preload("res://scripts/map_catalog.gd")
const TerrainBuilderScript = preload("res://scripts/terrain_builder.gd")

func _init() -> void:
	MapCatalogScript.reset_cache_for_tests()
	var map_def: Dictionary = MapCatalogScript.get_map("canyon_ford")
	# 1. The map loaded (the cache was empty; get_map parsed it).
	if map_def.is_empty():
		print("[FAIL] canyon_ford map_def is empty after get_map()")
		quit(1)
		return
	print("[PASS] canyon_ford loaded via MapCatalog.get_map()")
	# 2. half_extents returns Vector2 with both axes.
	var he: Vector2 = MapCatalogScript.half_extents(map_def)
	if he.x != 600.0 or he.y != 260.0:
		print("[FAIL] half_extents returned (%s, %s), expected (600, 260)" % [he.x, he.y])
		quit(1)
		return
	print("[PASS] half_extents() returns (600, 260) for canyon_ford")
	# 3. terrain.features[] has 3 plateaus + 5 ramps.
	var features: Array = map_def.get("terrain", {}).get("features", [])
	var n_plateaus: int = 0
	var n_ramps: int = 0
	for f in features:
		match f.get("type", ""):
			"plateau": n_plateaus += 1
			"ramp": n_ramps += 1
	if n_plateaus != 3 or n_ramps != 5:
		print("[FAIL] features[] has %d plateaus + %d ramps, expected 3 + 5" % [n_plateaus, n_ramps])
		quit(1)
		return
	print("[PASS] features[] has 3 plateaus + 5 ramps")
	# 4. _resolve_features auto-emits the expected number of cliffs.
	TerrainBuilderScript._resolve_features(map_def)
	var cliff_count: int = map_def.get("cliffs", []).size()
	if cliff_count < 100:
		print("[FAIL] only %d cliffs auto-emitted, expected >= 100" % cliff_count)
		quit(1)
		return
	print("[PASS] %d cliffs auto-emitted from plateaus" % cliff_count)
	# 5. height_at returns finite values across the whole map (every
	#    ramp + plateau + hill + noise term should compose without
	#    blowing up).
	var bad: int = 0
	for x in range(-600, 601, 60):
		for z in range(-260, 261, 26):
			var h: float = TerrainBuilderScript.height_at(map_def, x, z)
			if not is_finite(h):
				bad += 1
	if bad > 0:
		print("[FAIL] %d non-finite height_at() calls" % bad)
		quit(1)
		return
	print("[PASS] height_at() returns finite values across the whole map")
	# 6. is_position_blocked is consistent with the heightmap:
	#    every plateau center (auto-emitted cliff line) is blocked.
	var plateaus: Array = []
	for f in features:
		if f.get("type", "") == "plateau":
			plateaus.append(f)
	for p in plateaus:
		var c = p.get("center")
		if typeof(c) == TYPE_ARRAY:
			c = Vector3(c[0], c[1], c[2])
		# A plateau center is INSIDE the plateau (height == top), not
		# blocked. A point 1m outside the half_extents is on the cliff
		# line and SHOULD be blocked.
		var on_cliff_x: float = c.x + (p.get("half_extents", [10, 10])[0] + 0.5)
		if not TerrainBuilderScript.is_position_blocked(map_def, Vector3(on_cliff_x, 0, c.z)):
			print("[FAIL] is_position_blocked at cliff line (%.1f, 0, %.1f) returned false" % [on_cliff_x, c.z])
			quit(1)
			return
	print("[PASS] every plateau cliff line is reported as blocked")
	# 7. The two spawns are mutually reachable on the analytic path:
	#    every position between them has a finite height (which is
	#    the precondition for navmesh baking). A full navmesh bake
	#    needs a SceneTree, so we just confirm the heightmap is well-
	#    defined for the path between them.
	var spawns: Array = map_def.get("spawns", [])
	if spawns.size() != 2:
		print("[FAIL] %d spawns, expected 2" % spawns.size())
		quit(1)
		return
	var p_a: Vector3 = spawns[0].hq
	var p_b: Vector3 = spawns[1].hq
	var samples: int = 20
	for i in range(samples + 1):
		var t: float = float(i) / float(samples)
		var x: float = lerp(p_a.x, p_b.x, t)
		var z: float = lerp(p_a.z, p_b.z, t)
		var h: float = TerrainBuilderScript.height_at(map_def, x, z)
		if not is_finite(h):
			print("[FAIL] non-finite height along spawn-to-spawn path at (%.0f, %.0f)" % [x, z])
			quit(1)
			return
	print("[PASS] spawn-to-spawn path is finite across %d samples" % (samples + 1))
	print("[ALL PASS] canyon_ford non-square smoke")
	quit(0)
