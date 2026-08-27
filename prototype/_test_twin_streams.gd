extends SceneTree
# Twin_streams map smoke test (2026-08-26 22:14 playtest rebuild).
#
# The user asked for a NEW map based on twin_streams_crude.png: 2 main
# plateaus (left and right) with streams cutting through, a small NE
# plateau outcrop, twin rivers (one SW, one NE), 5 ramps, opposite-
# corner spawns, and forest groves that read as distinctly different
# from open grassland.
#
# Pins the new shape:
#   1. Validates against FIELD_SPEC.
#   2. Each spawn has >= 2 resources within radius.
#   3. Cliffs are reported as "blocked" by is_position_blocked.
#   4. The 3 plateaus are present in terrain.features[].
#   5. The 5 ramps are present in terrain.features[].
#   6. The 2 rivers (water_areas, multi-segment) are present.
#   7. Spawns are at opposite corners of the map.
#   8. The forest surface zones are large enough to read as groves
#      (each >= 50x50m footprint), not "tiny patches".
#
# Run: godot --headless --script _test_twin_streams.gd --path prototype

const MapCatalogScript = preload("res://scripts/map_catalog.gd")
const TerrainBuilderScript = preload("res://scripts/terrain_builder.gd")
const BattleLayersScript = preload("res://scripts/battle/battle_layers.gd")

func _init():
	var failed: int = 0
	if not _test_json_validates():
		failed += 1
		print("[FAIL] twin_streams.json validates against FIELD_SPEC")
	else:
		print("[PASS] twin_streams.json validates against FIELD_SPEC")
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
		print("[FAIL] twin_streams has 3 plateaus (left, right, small NE)")
	else:
		print("[PASS] twin_streams has 3 plateaus (left, right, small NE)")
	if not _test_five_ramps():
		failed += 1
		print("[FAIL] twin_streams has 5 ramps (2+2+1)")
	else:
		print("[PASS] twin_streams has 5 ramps (2+2+1)")
	if not _test_twin_rivers():
		failed += 1
		print("[FAIL] twin_streams has rivers (water_areas >= 8)")
	else:
		print("[PASS] twin_streams has rivers (water_areas >= 8)")
	if not _test_spawns_at_opposite_corners():
		failed += 1
		print("[FAIL] spawns at opposite corners of the map")
	else:
		print("[PASS] spawns at opposite corners of the map")
	if not _test_forests_are_groves():
		failed += 1
		print("[FAIL] forest zones are large enough to read as groves")
	else:
		print("[PASS] forest zones are large enough to read as groves")
	if not _test_cliffs_at_correct_y():
		failed += 1
		print("[FAIL] auto-emitted plateau cliffs sit at surrounding ground (y~0), not at heightmap level (y~14)")
	else:
		print("[PASS] auto-emitted plateau cliffs sit at surrounding ground (y~0), not at heightmap level (y~14)")
	print("")
	if failed == 0:
		print("[PASS] all twin_streams smoke tests pass")
		quit(0)
	else:
		print("[FAIL] %d/9 twin_streams tests fail" % failed)
		quit(1)


func _test_json_validates() -> bool:
	var map_def: Dictionary = _load_decoded()
	var errors: Array = MapCatalogScript.validate_map_def(map_def)
	if not errors.is_empty():
		for e in errors:
			print("    validation error: %s" % e)
		return false
	return true


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


func _test_cliffs_are_blocked() -> bool:
	var map_def: Dictionary = _load_decoded()
	TerrainBuilderScript._resolve_features(map_def)
	for c in map_def.get("cliffs", []):
		if not TerrainBuilderScript.is_position_blocked(map_def, c.center):
			print("    is_position_blocked at cliff center %s = false, expected true" % c.center)
			return false
	return true


func _test_three_plateaus() -> bool:
	var map_def: Dictionary = _load_decoded()
	var features: Array = map_def.get("terrain", {}).get("features", [])
	var plateau_count: int = 0
	var heights: Array = []
	for f in features:
		if f.get("type", "") == "plateau":
			plateau_count += 1
			heights.append(f.get("height", 0.0))
	if plateau_count != 3:
		print("    twin_streams has %d plateaus, expected 3 (left, right, small NE)" % plateau_count)
		return false
	# All plateaus should have a positive height (rocky upland, not flat).
	for h in heights:
		if h <= 0.0:
			print("    plateau has non-positive height %.1f" % h)
			return false
	TerrainBuilderScript._resolve_features(map_def)
	if map_def.get("cliffs", []).size() < 100:
		print("    twin_streams plateau auto-emission produced only %d cliffs, expected >= 100" % map_def.get("cliffs", []).size())
		return false
	return true


func _test_five_ramps() -> bool:
	var map_def: Dictionary = _load_decoded()
	var features: Array = map_def.get("terrain", {}).get("features", [])
	var ramps: Array = []
	for f in features:
		if f.get("type", "") == "ramp":
			ramps.append(f)
	if ramps.size() != 5:
		print("    twin_streams has %d ramps, expected 5 (2 left, 2 right, 1 NE)" % ramps.size())
		return false
	# Each ramp's top_height should match the plateau it ascends.
	# 4m <= top_height <= 16m (the 3 plateaus are 8, 12, 14).
	for r in ramps:
		var h: float = r.get("top_height", 0.0)
		if h < 4.0 or h > 16.0:
			print("    ramp top_height %.1f, expected 4-16m" % h)
			return false
	return true


func _test_twin_rivers() -> bool:
	var map_def: Dictionary = _load_decoded()
	var water_areas: Array = map_def.get("water_areas", [])
	if water_areas.size() < 8:
		print("    twin_streams has %d water_areas, expected >= 8 (SW river + NE river, multi-segment)" % water_areas.size())
		return false
	var he: Vector2 = MapCatalogScript.half_extents(map_def)
	for w in water_areas:
		var c: Vector3 = w.center
		if abs(c.x) > he.x or abs(c.z) > he.y:
			print("    water_area at %s is outside map bounds" % c)
			return false
	# Two distinct river corridors: one in the SW (negative x, negative z),
	# one in the NE (positive x, positive z). At least one water_area
	# in each quadrant.
	var has_sw: bool = false
	var has_ne: bool = false
	for w in water_areas:
		var c: Vector3 = w.center
		if c.x < 0.0 and c.z < 0.0:
			has_sw = true
		elif c.x > 0.0 and c.z > 0.0:
			has_ne = true
	if not (has_sw and has_ne):
		print("    twin_streams missing SW or NE river corridor (sw=%s ne=%s)" % [has_sw, has_ne])
		return false
	return true


func _test_spawns_at_opposite_corners() -> bool:
	var map_def: Dictionary = _load_decoded()
	var spawns: Array = map_def.get("spawns", [])
	if spawns.size() != 2:
		print("    twin_streams has %d spawns, expected 2" % spawns.size())
		return false
	var p: Vector3 = spawns[0].hq
	var e: Vector3 = spawns[1].hq
	var he: Vector2 = MapCatalogScript.half_extents(map_def)
	var diagonal: float = sqrt((he.x * 2.0) * (he.x * 2.0) + (he.y * 2.0) * (he.y * 2.0))
	var min_dist: float = diagonal * 0.70
	var spawn_dist: float = p.distance_to(e)
	if spawn_dist < min_dist:
		print("    spawns at %s and %s are %.0f units apart, need >= %.0f (70%% of map diagonal)" % [p, e, spawn_dist, min_dist])
		return false
	return true


# 2026-08-26 22:14 playtest feedback: "The terrain types are still
# tiny patches, nothing to worry about just an obstacle for an
# obstacles sake." Each forest zone must be at least 50x50m so it
# reads as a GROVE (multiple trees clustered), not a single tree.
func _test_forests_are_groves() -> bool:
	var map_def: Dictionary = _load_decoded()
	var surface_zones: Array = map_def.get("surface_zones", [])
	var forest_count: int = 0
	for s in surface_zones:
		if s.surface_type == "forest":
			forest_count += 1
			var he: Vector2 = s.half_extents
			if he.x < 25.0 or he.y < 25.0:
				print("    forest zone at %s has half_extents %s, both should be >= 25m to read as a grove" % [s.center, s.half_extents])
				return false
	if forest_count < 3:
		print("    twin_streams has %d forest zones, expected >= 3 groves" % forest_count)
		return false
	return true


# 2026-08-26 22:14 playtest fix: plateau auto-emitted cliffs were at
# the heightmap level (y=14 for a 14m plateau) and extended UP into
# the sky ("opposite of a ramp"). The fix: auto-emission sets
# y_offset = -wall_height so the cliff sits at the surrounding
# ground (y=0) and extends UP to wall_height. This test pins the
# corrected Y position.
func _test_cliffs_at_correct_y() -> bool:
	var map_def: Dictionary = _load_decoded()
	# Override the small plateaus to test in isolation - we want to
	# check a single 14m plateau, not the full 3-plateau map (the
	# small 8m NE plateau's cliffs are at different expected y).
	var test_map: Dictionary = map_def.duplicate(true)
	test_map.terrain.features = [
		{"type": "plateau", "center": Vector3(0, 0, 0), "half_extents": Vector2(20, 20), "height": 14, "wall_height": 14}
	]
	test_map["_auto_feature_emitted"] = {}
	TerrainBuilderScript._resolve_features(test_map)
	var parent: Node3D = Node3D.new()
	root.add_child(parent)
	TerrainBuilderScript._spawn_cliffs(test_map, parent, 1.0)
	# All auto-emitted cliffs from a 14m plateau should have:
	#   - visual mesh y ~0 (surrounding ground)
	#   - body y ~7 (collision box centered)
	# If the visual is at y=14 (heightmap level) it's the BUG.
	var wrong_visuals: int = 0
	var wrong_bodies: int = 0
	for child in parent.get_children():
		if child is MeshInstance3D:
			# Visual should be near y=0 (heightmap at plateau edge
			# is full wall_height, y_offset = -wall_height cancels it).
			if absf(child.position.y) > 2.0:
				wrong_visuals += 1
		elif child is StaticBody3D:
			# Body should be at cliff_height/2 = 7m.
			if absf(child.position.y - 7.0) > 2.0:
				wrong_bodies += 1
	if wrong_visuals > 0 or wrong_bodies > 0:
		print("    %d visuals at wrong y (expected ~0), %d bodies at wrong y (expected ~7)" % [wrong_visuals, wrong_bodies])
		return false
	return true


func _load_decoded() -> Dictionary:
	var path: String = "res://data/maps/twin_streams.json"
	var text: String = FileAccess.get_file_as_string(path)
	var parsed: Variant = JSON.parse_string(text)
	MapCatalogScript.reset_cache_for_tests()
	return MapCatalogScript._decode_dict(parsed, MapCatalogScript.FIELD_SPEC)
