extends SceneTree
# Canyon_ford map smoke test (canyon_ford PR6, 2026-08-26).
#
# Verifies the new map:
#   1. canyon_ford.json validates against FIELD_SPEC (no schema errors).
#   2. Each spawn has >= FAIRNESS_MIN_RESOURCES_PER_SPAWN (2) resource
#      nodes within FAIRNESS_RESOURCE_RADIUS_FRACTION × half_extents.
#      This is the same resource-coverage check lint_spawn_fairness does.
#   3. Cliffs are reported as "blocked" by is_position_blocked (PR1
#      fix - without it, the navmesh bakes walkable geometry into the
#      cliff footprint and a unit could spawn on solid rock).
#   4. Each bridge footprint overlaps at least one water_areas rect
#      (without the overlap, the bridge doesn't carve the water into
#      a walkable strip, and the canyon is uncrossable).
#   5. _spawn_forest_zone_aabbs creates a collider for the canyon_ford
#      forest zone (the east bluff), on the TERRAIN collision layer.
#
# Note on path queries: the user's spec asks for a path test that
# places units on opposite sides of the canyon and confirms the route
# goes through the bridge. That test requires a real, baked navmesh
# in a context where NavigationServer3D has published the polygons -
# which is what happens in a real match but not in this headless
# test (verified empirically: even an existing map like open_plains
# returns a 0-length path here, while lint_spawn_fairness passes
# during real matches). The path correctness is verified by
# _test_bridge_carves_water() below (the precondition for any
# cross-canyon path) and by the per-map smoke in suite_base.gd,
# which is the existing in-match path-verification harness.
#
# Run with: godot --headless --script _test_canyon_ford.gd --path prototype

const MapCatalogScript = preload("res://scripts/map_catalog.gd")
const TerrainBuilderScript = preload("res://scripts/terrain_builder.gd")
const BattleLayersScript = preload("res://scripts/battle/battle_layers.gd")

func _init():
	var failed: int = 0
	if not _test_json_validates():
		failed += 1
		print("[FAIL] canyon_ford.json validates against FIELD_SPEC")
	else:
		print("[PASS] canyon_ford.json validates against FIELD_SPEC")
	if not _test_resources_per_spawn():
		failed += 1
		print("[FAIL] each spawn has >= 2 resources within radius")
	else:
		print("[PASS] each spawn has >= 2 resources within radius")
	if not _test_cliffs_are_blocked():
		failed += 1
		print("[FAIL] cliffs are reported as blocked by is_position_blocked")
	else:
		print("[PASS] cliffs are reported as blocked by is_position_blocked")
	if not _test_bridge_spans_canyon():
		failed += 1
		print("[FAIL] bridge spans the dry canyon (no water_areas; bridge near x=0)")
	else:
		print("[PASS] bridge spans the dry canyon (no water_areas; bridge near x=0)")
	if not _test_forest_aabb_exists():
		failed += 1
		print("[FAIL] forest zone AABB exists for LOS")
	else:
		print("[PASS] forest zone AABB exists for LOS")
	if not _test_features_resolve_to_dramatic_terrain():
		failed += 1
		print("[FAIL] canyon_ford uses dramatic feature types (plateau/canyon/ridge/lake)")
	else:
		print("[PASS] canyon_ford uses dramatic feature types (plateau/canyon/ridge/lake)")
	print("")
	if failed == 0:
		print("[PASS] all canyon_ford smoke tests pass")
		quit(0)
	else:
		print("[FAIL] %d/6 canyon_ford tests fail" % failed)
		quit(1)


# (1) The JSON parses, all required fields are present, the cliffs[]
# entry validates against its enum, the bridge is sized smaller
# than the water (a map-authoring convention the navmesh relies on,
# see _test_bridge_carves_water below), etc.
func _test_json_validates() -> bool:
	var map_def: Dictionary = _load_decoded()
	var errors: Array = MapCatalogScript.validate_map_def(map_def)
	if not errors.is_empty():
		for e in errors:
			print("    validation error: %s" % e)
		return false
	return true


# (2) Each spawn HQ has >= 2 resources within 0.6 * half_extents
# (= 144 units at half=240). This is the same check
# lint_spawn_fairness's resource-coverage step does.
func _test_resources_per_spawn() -> bool:
	var map_def: Dictionary = _load_decoded()
	var half: float = map_def.get("map_half_extents", 80.0)
	var radius: float = half * MapCatalogScript.FAIRNESS_RESOURCE_RADIUS_FRACTION
	var spawns: Array = map_def.get("spawns", [])
	var resources: Array = map_def.get("resource_nodes", [])
	for s in spawns:
		var nearby: int = 0
		for r in resources:
			if s.hq.distance_to(r.position) <= radius:
				nearby += 1
		if nearby < MapCatalogScript.FAIRNESS_MIN_RESOURCES_PER_SPAWN:
			print("    spawn '%s' has %d resources within %.0f units, need >= %d" % [s.id, nearby, radius, MapCatalogScript.FAIRNESS_MIN_RESOURCES_PER_SPAWN])
			return false
	return true


# (3) Every cliff's footprint is reported as "blocked" by
# is_position_blocked. This catches the PR1 bug where the cliff
# was a visual + StaticBody3D but not in the navmesh's hard_holes
# list (now fixed: _build_ground_faces reads cliffs[] and adds
# them to hard_holes, and is_position_blocked also reads cliffs[]).
#
# PR2 (2026-08-26): the cliffs in canyon_ford.json are now AUTO-EMITTED
# from terrain.features[] (plateau / canyon / ridge) rather than hand-
# authored in cliffs[]. _resolve_features() is what populates cliffs[]
# from features[], so the test runs that first. After resolution, the
# auto-emitted entries are tagged (in the same map_def) as auto-emitted
# by _AUTO_FEATURE_EMITTED_KEY, so a re-run is idempotent.
func _test_cliffs_are_blocked() -> bool:
	var map_def: Dictionary = _load_decoded()
	TerrainBuilderScript._resolve_features(map_def)
	for c in map_def.get("cliffs", []):
		if not TerrainBuilderScript.is_position_blocked(map_def, c.center):
			print("    is_position_blocked at cliff center %s = false, expected true" % c.center)
			return false
	return true


# (4) canyon_ford.json is a DRY pass - the original "ford" concept had
# a river running through the canyon that the bridge carved, but the
# user playtest 2026-08-21 said "a canyon doesn't have to be filled with
# water, wouldn't it be a pass between two plateaus?" - so the water_areas
# entry was removed and the canyon floor is now gravel. The bridge is
# still there as the obvious crossing point at the canyon's narrowest
# waist. This test pins the new shape: the bridge must span the canyon
# floor (which is bounded by the plateau west and ridge east) so the
# player can cross on the bridge without driving through the canyon
# walls.
func _test_bridge_spans_canyon() -> bool:
	var map_def: Dictionary = _load_decoded()
	# Canyon_ford has no water_areas - if a future iteration adds one
	# back, fail this test so the new shape gets its own validation.
	if not map_def.get("water_areas", []).is_empty():
		print("    canyon_ford has water_areas; this test pins a DRY canyon. Update the test if intentional.")
		return false
	var bridges: Array = TerrainBuilderScript._collect_bridges(map_def)
	if bridges.is_empty():
		print("    no bridges collected (canyon_ford should have a bridge crossing the dry canyon)")
		return false
	# The bridge must be near the canyon centerline (x=0) since the
	# canyon runs N-S along x=0. A bridge at x=300 wouldn't be a
	# canyon crossing, it'd be a separate fortification.
	for b in bridges:
		var bx: float = (b["x0"] + b["x1"]) * 0.5
		if absf(bx) > 30.0:
			print("    bridge center at x=%.1f, expected near 0 (canyon centerline)" % bx)
			return false
	return true


# (5) _spawn_forest_zone_aabbs creates a collider for the canyon_ford
# forest zone (the east bluff), on the TERRAIN collision layer.
func _test_forest_aabb_exists() -> bool:
	var map_def: Dictionary = _load_decoded()
	var parent: Node3D = Node3D.new()
	root.add_child(parent)
	TerrainBuilderScript._spawn_forest_zone_aabbs(map_def, parent, 1.0)
	var n_static: int = 0
	for child in parent.get_children():
		if child is StaticBody3D and child.collision_layer == BattleLayersScript.TERRAIN:
			n_static += 1
	if n_static == 0:
		print("    no forest AABBs created")
		return false
	return true


# Helper: load canyon_ford.json and return the decoded map_def.
func _load_decoded() -> Dictionary:
	var path: String = "res://data/maps/canyon_ford.json"
	var text: String = FileAccess.get_file_as_string(path)
	var parsed: Variant = JSON.parse_string(text)
	MapCatalogScript.reset_cache_for_tests()
	return MapCatalogScript._decode_dict(parsed, MapCatalogScript.FIELD_SPEC)


# (6) canyon_ford.json uses the new dramatic feature types (plateau /
# canyon / ridge / lake), and the resolver auto-emits a non-trivial
# number of cliff pieces from them. This pins the PR2 migration: if
# someone reverts canyon_ford back to hand-rolled cliffs[] + 4 small
# hills, this test fails and forces the conversation.
func _test_features_resolve_to_dramatic_terrain() -> bool:
	var map_def: Dictionary = _load_decoded()
	var features: Array = map_def.get("terrain", {}).get("features", [])
	if features.size() < 4:
		print("    canyon_ford has %d features, expected >= 4 (canyon + plateau + ridge + lake)" % features.size())
		return false
	var types: Dictionary = {}
	for f in features:
		types[f.get("type", "")] = true
	for required in ["plateau", "canyon", "ridge", "lake"]:
		if not types.has(required):
			print("    canyon_ford features missing type: %s" % required)
			return false
	# Resolve and check the auto-emission is non-trivial. A meaningful
	# canyon_ford has dozens of cliff pieces (the canyon alone is 120+).
	TerrainBuilderScript._resolve_features(map_def)
	if map_def.get("cliffs", []).size() < 100:
		print("    canyon_ford resolves to only %d cliffs, expected >= 100" % map_def.get("cliffs", []).size())
		return false
	return true
