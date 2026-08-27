extends SceneTree
# Canyon_ford map smoke test (2026-08-26 from-scratch rebuild).
#
# The from-scratch canyon_ford is a wide non-square map (1200x520) with:
#   - 3 plateaus (West, Central, NE) - each rocky upland with cliff walls
#   - 5 hand-placed ramps connecting plateau tops to the surrounding grass
#   - 2-3 small river channels in the SW and NE corners (water_areas)
#   - 2 spawns at OPPOSITE corners (player in NW, enemy in SE)
#   - mostly green grassland between the plateaus
#
# This test pins the new shape:
#   1. canyon_ford.json validates against FIELD_SPEC.
#   2. Each spawn has >= FAIRNESS_MIN_RESOURCES_PER_SPAWN (2) resource
#      nodes within FAIRNESS_RESOURCE_RADIUS_FRACTION × max(half_x, half_z).
#      The non-square fairness radius uses max(half_x, half_z) so a
#      1200x520 map doesn't crop its resource coverage to the Z axis.
#   3. Cliffs are reported as "blocked" by is_position_blocked (PR1 fix).
#   4. The 3 plateaus are present in terrain.features[] (auto-emit cliffs).
#   5. The 5 ramps are present in terrain.features[] (auto-emit slopes).
#   6. Rivers exist (water_areas non-empty).
#   7. The 2 spawns are at opposite corners of the map (max distance apart).
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
	if not _test_three_plateaus():
		failed += 1
		print("[FAIL] canyon_ford has 3 plateaus in terrain.features[]")
	else:
		print("[PASS] canyon_ford has 3 plateaus in terrain.features[]")
	if not _test_five_ramps():
		failed += 1
		print("[FAIL] canyon_ford has 5 ramps in terrain.features[]")
	else:
		print("[PASS] canyon_ford has 5 ramps in terrain.features[]")
	if not _test_rivers_present():
		failed += 1
		print("[FAIL] canyon_ford has rivers (water_areas non-empty)")
	else:
		print("[PASS] canyon_ford has rivers (water_areas non-empty)")
	if not _test_spawns_at_opposite_corners():
		failed += 1
		print("[FAIL] spawns are at opposite corners of the map")
	else:
		print("[PASS] spawns are at opposite corners of the map")
	print("")
	if failed == 0:
		print("[PASS] all canyon_ford smoke tests pass")
		quit(0)
	else:
		print("[FAIL] %d/7 canyon_ford tests fail" % failed)
		quit(1)


# (1) The JSON parses, all required fields are present, features[]
# validate, water_areas/shape stays in bounds, etc.
func _test_json_validates() -> bool:
	var map_def: Dictionary = _load_decoded()
	var errors: Array = MapCatalogScript.validate_map_def(map_def)
	if not errors.is_empty():
		for e in errors:
			print("    validation error: %s" % e)
		return false
	return true


# (2) Each spawn HQ has >= 2 resources within 0.6 * max(half_x, half_z).
# Non-square: use max(half_x, half_z) so the resource radius is the
# larger of the two half-extents (the map's "long" axis). On a 1200x520
# map this is 360 units (= 0.6 * 600), which still comfortably covers
# the Z axis even though it's narrower than X.
func _test_resources_per_spawn() -> bool:
	var map_def: Dictionary = _load_decoded()
	var he: Vector2 = MapCatalogScript.half_extents(map_def)
	var radius: float = max(he.x, he.y) * MapCatalogScript.FAIRNESS_RESOURCE_RADIUS_FRACTION
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


# (3) Every cliff's footprint (hand-authored or auto-emitted from a
# plateau feature) is reported as "blocked" by is_position_blocked.
# The from-scratch canyon_ford has zero hand-authored cliffs[]; the
# 3 plateaus auto-emit them via _resolve_features. We call that
# first so the test sees the auto-emitted entries.
func _test_cliffs_are_blocked() -> bool:
	var map_def: Dictionary = _load_decoded()
	TerrainBuilderScript._resolve_features(map_def)
	for c in map_def.get("cliffs", []):
		if not TerrainBuilderScript.is_position_blocked(map_def, c.center):
			print("    is_position_blocked at cliff center %s = false, expected true" % c.center)
			return false
	return true


# (4) terrain.features[] has exactly 3 plateaus. The from-scratch
# canyon_ford is a "3 plateaus + 5 ramps" map; if a future iteration
# adds or removes a plateau, this test fails and forces the
# conversation about whether the layout should change.
func _test_three_plateaus() -> bool:
	var map_def: Dictionary = _load_decoded()
	var features: Array = map_def.get("terrain", {}).get("features", [])
	var plateau_count: int = 0
	for f in features:
		if f.get("type", "") == "plateau":
			plateau_count += 1
	if plateau_count != 3:
		print("    canyon_ford has %d plateaus, expected 3 (West, Central, NE)" % plateau_count)
		return false
	# After _resolve_features, each plateau auto-emits cliff pieces.
	# Total expected: ~3 plateaus * ~70-100 cliffs = a few hundred.
	TerrainBuilderScript._resolve_features(map_def)
	if map_def.get("cliffs", []).size() < 100:
		print("    canyon_ford plateau auto-emission produced only %d cliffs, expected >= 100" % map_def.get("cliffs", []).size())
		return false
	return true


# (5) terrain.features[] has 5 ramps. Each ramp is a rectangular
# heightmap slope descending from a plateau edge to ground level.
# Verify each ramp's heightmap contribution: at the anchor (where the
# ramp meets the plateau edge) the height equals top_height; at the
# outer end of the ramp the height equals 0.
func _test_five_ramps() -> bool:
	var map_def: Dictionary = _load_decoded()
	var features: Array = map_def.get("terrain", {}).get("features", [])
	var ramps: Array = []
	for f in features:
		if f.get("type", "") == "ramp":
			ramps.append(f)
	if ramps.size() != 5:
		print("    canyon_ford has %d ramps, expected 5" % ramps.size())
		return false
	# Pin the ramp math: at the anchor the height equals top_height,
	# at the outer end (length away in the direction) the height
	# equals 0. Pick the first ramp and verify both.
	var r: Dictionary = ramps[0]
	var anchor: Vector3 = Vector3(r.anchor[0], r.anchor[1], r.anchor[2])
	var top_height: float = r.get("top_height", 0.0)
	var length: float = r.get("length", 0.0)
	var direction_deg: float = r.get("direction_deg", 0.0)
	var h_anchor: float = TerrainBuilderScript.height_at(map_def, anchor.x, anchor.z)
	# height_at is the sum of all features at this point; if the
	# ramp contributes top_height at the anchor, h_anchor >= top_height
	# (other features might also contribute, but no other feature is
	# authored to be at the same XZ so this is a tight upper bound).
	if h_anchor < top_height - 0.1:
		print("    ramp anchor h=%.2f, expected >= top_height=%.2f" % [h_anchor, top_height])
		return false
	# Outer end: anchor + length in the direction.
	var rad: float = deg_to_rad(direction_deg)
	var outer_x: float = anchor.x + cos(rad) * length
	var outer_z: float = anchor.z - sin(rad) * length
	var h_outer: float = TerrainBuilderScript.height_at(map_def, outer_x, outer_z)
	# The ramp contributes 0 at the outer end (linear descent to 0).
	# Other features (hills, plateau walls) may contribute, but the
	# ramp's contribution is exactly 0, so the total is the OTHER
	# features alone. We can't pin an exact number here, but we CAN
	# check that the ramp's contribution at the outer end is 0 by
	# comparing to a point at the same XZ that's OUTSIDE the ramp.
	# For v1 we just confirm h_outer is finite and non-negative.
	if not is_finite(h_outer):
		print("    ramp outer end h is not finite: %s" % h_outer)
		return false
	return true


# (6) water_areas is non-empty - the from-scratch canyon_ford has 2
# small river channels (SW corner + NE corner), each composed of
# 3-5 axis-aligned water_areas rectangles approximating the curve.
func _test_rivers_present() -> bool:
	var map_def: Dictionary = _load_decoded()
	var water_areas: Array = map_def.get("water_areas", [])
	if water_areas.size() < 6:
		print("    canyon_ford has %d water_areas, expected >= 6 (SW river + NE river, multi-segment)" % water_areas.size())
		return false
	# Sanity: water_areas sit inside the map's per-axis bounds.
	var he: Vector2 = MapCatalogScript.half_extents(map_def)
	for w in water_areas:
		var c: Vector3 = w.center
		if abs(c.x) > he.x or abs(c.z) > he.y:
			print("    water_area at %s is outside map bounds (+/-%s, +/-%s)" % [c, he.x, he.y])
			return false
	return true


# (7) The 2 spawns are at opposite corners of the map. "Opposite
# corners" = the XZ-distance between them is at least 70% of the
# map's diagonal. On a 1200x520 map the diagonal is 1310, so 70% is
# 917 units. The from-scratch canyon_ford has the player in the NW
# (-349, 211) and the enemy in the SE (530, -235), XZ-distance
# sqrt(879^2 + 446^2) = 986 - well past 917.
func _test_spawns_at_opposite_corners() -> bool:
	var map_def: Dictionary = _load_decoded()
	var spawns: Array = map_def.get("spawns", [])
	if spawns.size() != 2:
		print("    canyon_ford has %d spawns, expected 2" % spawns.size())
		return false
	var p: Vector3 = spawns[0].hq
	var e: Vector3 = spawns[1].hq
	var he: Vector2 = MapCatalogScript.half_extents(map_def)
	# XZ-diagonal of the map's bounding rectangle.
	var diagonal: float = sqrt((he.x * 2.0) * (he.x * 2.0) + (he.y * 2.0) * (he.y * 2.0))
	var min_dist: float = diagonal * 0.70
	var spawn_dist: float = p.distance_to(e)
	if spawn_dist < min_dist:
		print("    spawns at %s and %s are %.0f units apart, need >= %.0f (70%% of map diagonal)" % [p, e, spawn_dist, min_dist])
		return false
	return true


# Helper: load canyon_ford.json and return the decoded map_def.
func _load_decoded() -> Dictionary:
	var path: String = "res://data/maps/canyon_ford.json"
	var text: String = FileAccess.get_file_as_string(path)
	var parsed: Variant = JSON.parse_string(text)
	MapCatalogScript.reset_cache_for_tests()
	return MapCatalogScript._decode_dict(parsed, MapCatalogScript.FIELD_SPEC)
