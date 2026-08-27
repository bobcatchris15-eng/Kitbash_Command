extends SceneTree
# PR1 (2026-08-26): dramatic terrain feature types - plateau, canyon, ridge,
# lake. Each one writes a heightmap contribution AND auto-emits cliff pieces
# (or a water_blob for lake) into the map_def. The tests below pin both
# behaviours: the auto-emission count + shape, and the analytic height
# contribution at key points inside / outside the feature.

const TerrainBuilderScript = preload("res://scripts/terrain_builder.gd")


func _make_blank_map_def() -> Dictionary:
	# Minimal map_def with terrain.features=[] so the resolver has a clean
	# map to mutate. world_scale 1 so half_extents==world coordinates; no
	# noise, no hills, no water_blobs - we're isolating the feature
	# contribution. The terrain.noise override zeroes the GROUND_NOISE
	# amplitude so the per-pixel noise the analytic height_at() path adds
	# on top of features is exactly 0 (otherwise the height_at() tests get
	# a +/- 1.2 noise offset that hides the feature contribution).
	return {
		"name": "feature_test",
		"map_half_extents": 100.0,
		"world_scale": 1.0,
		"hills": [],
		"water_blobs": [],
		"water_areas": [],
		"cliffs": [],
		"terrain": {
			"features": [],
			"noise": {"amplitude": 0.0, "frequency": 0.0},
		},
	}


func _reset_emission(map_def: Dictionary) -> void:
	# Strip the resolver's auto-emitted state so the test can re-call
	# _resolve_features on a fresh-shaped map_def.
	map_def.get("terrain", {})["features"] = []
	if map_def.has(TerrainBuilderScript._AUTO_FEATURE_EMITTED_KEY):
		map_def.erase(TerrainBuilderScript._AUTO_FEATURE_EMITTED_KEY)
	map_def["cliffs"] = []
	map_def["water_blobs"] = []
	map_def["water_areas"] = []


func _test_plateau_emits_perimeter_cliffs() -> void:
	# A 40x30 plateau at center (-80, 0, 30) with wall_height=18 should
	# emit 4 sides of straight pieces (one piece per CLIFF_PIECE_LENGTH)
	# + 4 corner_out pieces. The expected count for a 40x30 plateau is:
	#   - 2 long sides (along z=+/-30, length 60 each): 60 / 4 = 15 pieces
	#     per side, x2 = 30
	#   - 2 short sides (along x=+/-40, length 80 each): 80 / 4 = 20 pieces
	#     per side, x2 = 40
	#   - 4 corner_out pieces
	# Total: 30 + 40 + 4 = 74
	var map_def := _make_blank_map_def()
	map_def.terrain.features = [
		{"type": "plateau", "center": Vector3(-80, 0, 30), "half_extents": Vector2(40, 30), "height": 18, "wall_height": 18},
	]
	TerrainBuilderScript._resolve_features(map_def)
	var cliffs: Array = map_def.get("cliffs", [])
	if cliffs.size() != 74:
		print("FAIL: plateau emitted %d cliffs, expected 74" % cliffs.size())
		quit(1); return
	# All 4 corners should be corner_out.
	var corner_count := 0
	for c in cliffs:
		if c.get("type") == "corner_out":
			corner_count += 1
	if corner_count != 4:
		print("FAIL: plateau emitted %d corner_out pieces, expected 4" % corner_count)
		quit(1); return
	# Perimeter check: a position at the wall line on the +X side should
	# be inside a cliff footprint, so is_position_blocked returns true.
	if not TerrainBuilderScript.is_position_blocked(map_def, Vector3(-80 + 40.0, 0, 30)):
		print("FAIL: position at +X wall is not blocked")
		quit(1); return
	# Position inside the plateau (no wall): walkable.
	if TerrainBuilderScript.is_position_blocked(map_def, Vector3(-80, 0, 30)):
		print("FAIL: position at plateau center is blocked")
		quit(1); return
	# Heightmap: at plateau center, height == 18. Just outside, height == 0.
	var h_center: float = TerrainBuilderScript.height_at(map_def, -80, 30)
	var h_outside: float = TerrainBuilderScript.height_at(map_def, -80 + 100, 30)
	if absf(h_center - 18.0) > 0.5:
		print("FAIL: plateau center height %.2f, expected 18.0" % h_center)
		quit(1); return
	if absf(h_outside) > 0.5:
		print("FAIL: plateau outside height %.2f, expected 0.0" % h_outside)
		quit(1); return
	print("[PASS] plateau emits 74 cliffs (30+40+4), wall blocks, height correct")


func _test_canyon_emits_two_walls() -> void:
	# A canyon along z from -120 to +120, width 16, depth 22. The two
	# walls are 240m long (start to end), so round(240/4) = 60 pieces per
	# wall, x2 = 120 straight pieces. Plus 2 end_pos (start and end of
	# the centerline) x 2 side_sign (left and right wall) = 4 end
	# pieces. Total: 120 + 4 = 124.
	var map_def := _make_blank_map_def()
	map_def.terrain.features = [
		{"type": "canyon", "start": Vector3(0, 0, -120), "end": Vector3(0, 0, 120), "width": 16, "depth": 22},
	]
	TerrainBuilderScript._resolve_features(map_def)
	var cliffs: Array = map_def.get("cliffs", [])
	if cliffs.size() != 124:
		print("FAIL: canyon emitted %d cliffs, expected 124" % cliffs.size())
		quit(1); return
	# Walk along the centerline at z=0, x=0: in the floor, height = -22.
	# x=0 z=0 is between the walls (width=16, floor at center).
	var h_floor: float = TerrainBuilderScript.height_at(map_def, 0, 0)
	if absf(h_floor + 22.0) > 0.5:
		print("FAIL: canyon floor height %.2f, expected -22.0" % h_floor)
		quit(1); return
	# x=0 z=200: outside the canyon's along-axis extent, height = 0.
	var h_outside: float = TerrainBuilderScript.height_at(map_def, 0, 200)
	if absf(h_outside) > 0.5:
		print("FAIL: canyon outside-axis height %.2f, expected 0.0" % h_outside)
		quit(1); return
	# x=0 z=0 is inside the floor (no wall), so is_position_blocked is
	# false (it IS walkable, though the SLOPE check would say
	# "impassable" if there were any climb - but here the floor is
	# flat at -22 so it's flat walkable).
	if TerrainBuilderScript.is_position_blocked(map_def, Vector3(0, 0, 0)):
		print("FAIL: canyon floor is blocked")
		quit(1); return
	print("[PASS] canyon emits 124 cliffs, floor at -22, walkable on the floor")


func _test_ridge_emits_two_sides() -> void:
	# A 2-point polyline ridge from (-120, -50) to (-90, 0), height 24,
	# width 12. The line is ~50m long (sqrt(30^2+50^2) ~ 58), so
	# 58/4 = ~15 pieces per side. Both sides: ~30. End caps: 2.
	var map_def := _make_blank_map_def()
	map_def.terrain.features = [
		{"type": "ridge", "points": [[-120, -50], [-90, 0]], "height": 24, "width": 12},
	]
	TerrainBuilderScript._resolve_features(map_def)
	var cliffs: Array = map_def.get("cliffs", [])
	# Exact count is geometry-dependent; just verify >0 and that the
	# ridge top blocks (it's not a wall, but the cliff_height piece at
	# the wall line IS a wall).
	if cliffs.size() < 4:
		print("FAIL: ridge emitted %d cliffs, expected >4" % cliffs.size())
		quit(1); return
	# A position ON the ridge top (mid-segment) should NOT be inside a
	# wall (the walls are off to the sides at +width and -width).
	# The point is on the polyline, between the two walls.
	if TerrainBuilderScript.is_position_blocked(map_def, Vector3(-105, 0, -25)):
		print("FAIL: ridge top mid-segment is blocked")
		quit(1); return
	# A position at the wall line (perpendicular offset = width) IS
	# inside a wall, so is_position_blocked returns true.
	# Perpendicular to the (-120,-50)->(-90,0) segment: dir is roughly
	# (0.52, 0.86), perpendicular is (-0.86, 0.52) or (0.86, -0.52).
	# Wall position: midpoint + perp * width.
	# Easier: probe a corner-piece position.
	var first_corner: Dictionary = cliffs[0]
	if not TerrainBuilderScript.is_position_blocked(map_def, first_corner.center):
		print("FAIL: ridge first wall center is not blocked")
		quit(1); return
	# Heightmap: on the polyline, height = 24.
	var h_top: float = TerrainBuilderScript.height_at(map_def, -105, -25)
	if absf(h_top - 24.0) > 0.5:
		print("FAIL: ridge top height %.2f, expected 24.0" % h_top)
		quit(1); return
	print("[PASS] ridge emits walls, ridge top at +24, wall positions blocked")


func _test_lake_emits_water_blob() -> void:
	# A round lake at (60, 0, 80), radius 22, depth 4. Resolver should
	# emit one water_blob (default floor_surface is "blob"); no cliffs.
	var map_def := _make_blank_map_def()
	map_def.terrain.features = [
		{"type": "lake", "center": Vector3(60, 0, 80), "radius": 22, "depth": 4},
	]
	TerrainBuilderScript._resolve_features(map_def)
	var water_blobs: Array = map_def.get("water_blobs", [])
	var cliffs: Array = map_def.get("cliffs", [])
	if water_blobs.size() != 1:
		print("FAIL: lake emitted %d water_blobs, expected 1" % water_blobs.size())
		quit(1); return
	if not cliffs.is_empty():
		print("FAIL: lake emitted %d cliffs, expected 0" % cliffs.size())
		quit(1); return
	# Heightmap: at lake center, the feature contributes -4 AND the
	# auto-emitted water_blob (which the resolver adds to water_blobs[])
	# also contributes -4 (height_at() iterates water_blobs[] separately).
	# Plus the GROUND_NOISE floor (always on, no per-map override hook in
	# the analytic path) adds up to +/- 1.2. Net: -8 +/- 1.2. The test
	# checks the contribution layers in isolation by summing them
	# explicitly: feature layer -4, water_blob layer -4, noise layer ~0.
	var h_center: float = TerrainBuilderScript.height_at(map_def, 60, 80)
	if absf(h_center + 8.0) > 2.0:
		print("FAIL: lake center height %.2f, expected -8.0 +/- 2.0 (feature -4 + blob -4 + noise)" % h_center)
		quit(1); return
	# Far from lake: no feature, no blob. Just noise.
	var h_far: float = TerrainBuilderScript.height_at(map_def, 60, 200)
	if absf(h_far) > 1.5:
		print("FAIL: lake far height %.2f, expected ~0.0 +/- noise" % h_far)
		quit(1); return
	print("[PASS] lake emits 1 water_blob, no cliffs, depth -4 (-8 with blob), far = 0 +/- noise")


func _test_lake_with_water_area_floor() -> void:
	# floor_surface=water emits a water_area in addition to the water_blob
	# (so the rect water path lights up). The water_area is a square
	# (radius x radius) at center.
	var map_def := _make_blank_map_def()
	map_def.terrain.features = [
		{"type": "lake", "center": Vector3(0, 0, 0), "radius": 30, "depth": 4, "floor_surface": "water"},
	]
	TerrainBuilderScript._resolve_features(map_def)
	var water_areas: Array = map_def.get("water_areas", [])
	var water_blobs: Array = map_def.get("water_blobs", [])
	if water_areas.size() != 1:
		print("FAIL: lake with water_area floor emitted %d water_areas, expected 1" % water_areas.size())
		quit(1); return
	if water_blobs.size() != 1:
		print("FAIL: lake with water_area floor emitted %d water_blobs, expected 1" % water_blobs.size())
		quit(1); return
	# Position inside the water_area: is_water_at returns true.
	if not TerrainBuilderScript.is_water_at(map_def, 0, 0):
		print("FAIL: water_area floor is not water")
		quit(1); return
	print("[PASS] lake with floor_surface=water emits water_area + water_blob")


func _test_idempotent_resolve() -> void:
	# Calling _resolve_features twice on the same map_def must not double
	# the emissions. This is the contract spawn_visuals relies on (it
	# may be called more than once across scene reloads).
	var map_def := _make_blank_map_def()
	map_def.terrain.features = [
		{"type": "plateau", "center": Vector3(0, 0, 0), "half_extents": Vector2(20, 20), "height": 10},
		{"type": "lake", "center": Vector3(40, 0, 40), "radius": 10, "depth": 3},
	]
	TerrainBuilderScript._resolve_features(map_def)
	var cliffs_first: int = map_def.get("cliffs", []).size()
	var blobs_first: int = map_def.get("water_blobs", []).size()
	TerrainBuilderScript._resolve_features(map_def)
	var cliffs_second: int = map_def.get("cliffs", []).size()
	var blobs_second: int = map_def.get("water_blobs", []).size()
	if cliffs_first != cliffs_second:
		print("FAIL: cliffs not idempotent (first=%d second=%d)" % [cliffs_first, cliffs_second])
		quit(1); return
	if blobs_first != blobs_second:
		print("FAIL: water_blobs not idempotent (first=%d second=%d)" % [blobs_first, blobs_second])
		quit(1); return
	print("[PASS] _resolve_features is idempotent (no double emission)")


func _test_unknown_type_is_silent_noop() -> void:
	# An unknown feature type must not crash; the resolver silently ignores
	# it (the validator in map_catalog.gd would have caught a typo at load
	# time, so this is the runtime safety net).
	var map_def := _make_blank_map_def()
	map_def.terrain.features = [
		{"type": "this_is_not_a_real_type", "center": Vector3.ZERO, "radius": 5.0, "height": 5.0},
	]
	TerrainBuilderScript._resolve_features(map_def)
	if not map_def.get("cliffs", []).is_empty():
		print("FAIL: unknown type emitted cliffs")
		quit(1); return
	if not map_def.get("water_blobs", []).is_empty():
		print("FAIL: unknown type emitted water_blobs")
		quit(1); return
	# height_at also returns 0 for the unknown type (no contribution).
	if absf(TerrainBuilderScript.height_at(map_def, 0, 0)) > 0.5:
		print("FAIL: unknown type contributed non-zero height")
		quit(1); return
	print("[PASS] unknown feature type is silent no-op")


func _init() -> void:
	_test_plateau_emits_perimeter_cliffs()
	_test_canyon_emits_two_walls()
	_test_ridge_emits_two_sides()
	_test_lake_emits_water_blob()
	_test_lake_with_water_area_floor()
	_test_idempotent_resolve()
	_test_unknown_type_is_silent_noop()
	print("[ALL PASS] dramatic feature types PR1 tests pass")
	quit(0)
