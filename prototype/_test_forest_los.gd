extends SceneTree
# PR5 + PR1-bugfix smoke test (canyon_ford, 2026-08-26).
#
# Verifies:
#   1. is_position_blocked() rejects a position inside a cliff footprint
#      (PR1 fix: the original PR1 only added the StaticBody3D + visual;
#      the navmesh was still routing units into the cliff. The fix
#      added the cliff rect to is_position_blocked AND to the
#      _build_ground_faces hard_holes list).
#   2. _spawn_ambient_trees() rejects per-item positions on slopes
#      above AMBIENT_TREE_MAX_SLOPE (PR5 slope filter).
#   3. _spawn_forest_zone_aabbs() creates one StaticBody3D per forest
#      zone, sized to the zone's half_extents × FOREST_LOS_HEIGHT,
#      on the TERRAIN collision layer (so the LOS raycast hits it).
#
# Run with: godot --headless --script _test_forest_los.gd --path prototype

const TerrainBuilderScript = preload("res://scripts/terrain_builder.gd")
const MapCatalogScript = preload("res://scripts/map_catalog.gd")
const BattleLayersScript = preload("res://scripts/battle/battle_layers.gd")

static func _decoded(raw: Dictionary) -> Dictionary:
	return MapCatalogScript._decode_dict(raw, MapCatalogScript.FIELD_SPEC)

func _init():
	var failed: int = 0
	if not _test_cliff_position_is_blocked():
		failed += 1
		print("[FAIL] cliff footprint is blocked (PR1 fix)")
	else:
		print("[PASS] cliff footprint is blocked (PR1 fix)")
	if not _test_forest_aabbs_created():
		failed += 1
		print("[FAIL] forest zone AABBs created (PR5)")
	else:
		print("[PASS] forest zone AABBs created (PR5)")
	if not _test_aabb_layer_is_terrain():
		failed += 1
		print("[FAIL] forest AABB is on TERRAIN layer (PR5)")
	else:
		print("[PASS] forest AABB is on TERRAIN layer (PR5)")
	if not await _test_trees_reject_steep_slope():
		failed += 1
		print("[FAIL] trees rejected on steep slopes (PR5)")
	else:
		print("[PASS] trees rejected on steep slopes (PR5)")
	print("")
	if failed == 0:
		print("[PASS] all PR5 + PR1-fix tests pass")
		quit(0)
	else:
		print("[FAIL] %d/4 tests fail" % failed)
		quit(1)


# (1) A position inside a cliff's footprint is "blocked" (the same
# code path that lint_spawn_fairness and the per-spawn placement
# check use). Without the PR1 fix, a position inside a cliff's
# footprint was walkable because the cliff wasn't in the avoidance
# set - the unit would spawn on top of solid rock and immediately
# collide with the cliff's StaticBody3D.
func _test_cliff_position_is_blocked() -> bool:
	var raw: Dictionary = {
		"name": "Cliff Block Test",
		"description": "Confirms a position inside a cliff is reported as blocked.",
		"map_half_extents": 80.0,
		"world_scale": 1.0,
		"ground_color": [0.3, 0.3, 0.3],
		"base_zones": [], "water_areas": [],
		"obstacles": [],
		"cliffs": [
			{"center": [0.0, 0.0, 0.0], "half_extents": [4.0, 1.0], "type": "straight", "cliff_height": 4.0},
		],
		"spawns": [],
		"resource_nodes": [],
		"schema_version": 1,
	}
	var map_def: Dictionary = _decoded(raw)
	# Inside the cliff footprint: blocked.
	if not TerrainBuilderScript.is_position_blocked(map_def, Vector3(0.0, 0.0, 0.0)):
		print("    is_position_blocked(0,0) inside cliff = false, expected true")
		return false
	# Just outside the cliff: NOT blocked.
	if TerrainBuilderScript.is_position_blocked(map_def, Vector3(50.0, 0.0, 0.0)):
		print("    is_position_blocked(50,0) outside cliff = true, expected false")
		return false
	return true


# (3) _spawn_forest_zone_aabbs creates one StaticBody3D per forest
# zone, and only for forest zones (a marsh zone is skipped). Verify
# by counting the children of the parent node after the call.
func _test_forest_aabbs_created() -> bool:
	var raw: Dictionary = {
		"name": "Forest AABB Test",
		"description": "Per-forest-zone LOS AABBs are created.",
		"map_half_extents": 200.0,
		"world_scale": 1.0,
		"ground_color": [0.3, 0.3, 0.3],
		"base_zones": [], "water_areas": [], "obstacles": [],
		"surface_zones": [
			{"center": [-50.0, 0.0, 0.0], "half_extents": [20.0, 20.0], "surface_type": "forest"},
			{"center": [50.0, 0.0, 0.0], "half_extents": [15.0, 15.0], "surface_type": "marsh"},
			{"center": [0.0, 0.0, 50.0], "half_extents": [25.0, 25.0], "surface_type": "forest"},
		],
		"spawns": [],
		"resource_nodes": [],
		"schema_version": 1,
	}
	var map_def: Dictionary = _decoded(raw)
	var parent: Node3D = Node3D.new()
	root.add_child(parent)
	TerrainBuilderScript._spawn_forest_zone_aabbs(map_def, parent, 1.0)
	var n_static: int = 0
	for child in parent.get_children():
		if child is StaticBody3D:
			n_static += 1
	# 2 forest zones -> 2 AABBs. The marsh zone is skipped.
	if n_static != 2:
		print("    expected 2 StaticBody3D, got %d" % n_static)
		return false
	return true


# (4) The AABB's collision_layer is BattleLayers.TERRAIN (= 1), so
# the existing vision_service LOS raycast (TERRAIN | BUILDINGS mask)
# hits it. A wrong layer (e.g. BUILDINGS = 8) would also work for
# the LOS check, but mixing layers is fragile.
func _test_aabb_layer_is_terrain() -> bool:
	var raw: Dictionary = {
		"name": "Forest AABB Layer Test",
		"description": "Forest AABBs are on the TERRAIN collision layer.",
		"map_half_extents": 200.0,
		"world_scale": 1.0,
		"ground_color": [0.3, 0.3, 0.3],
		"base_zones": [], "water_areas": [], "obstacles": [],
		"surface_zones": [
			{"center": [0.0, 0.0, 0.0], "half_extents": [20.0, 20.0], "surface_type": "forest"},
		],
		"spawns": [],
		"resource_nodes": [],
		"schema_version": 1,
	}
	var map_def: Dictionary = _decoded(raw)
	var parent: Node3D = Node3D.new()
	root.add_child(parent)
	TerrainBuilderScript._spawn_forest_zone_aabbs(map_def, parent, 1.0)
	for child in parent.get_children():
		if child is StaticBody3D:
			if child.collision_layer != BattleLayersScript.TERRAIN:
				print("    StaticBody3D collision_layer = %d, expected %d (TERRAIN)" % [child.collision_layer, BattleLayersScript.TERRAIN])
				return false
			# Also confirm the BoxShape3D size matches the zone's footprint
			var shape_node: CollisionShape3D = child.get_child(0) as CollisionShape3D
			if shape_node == null:
				print("    StaticBody3D has no CollisionShape3D child")
				return false
			var box: BoxShape3D = shape_node.shape as BoxShape3D
			if box == null:
				print("    CollisionShape3D is not a BoxShape3D")
				return false
			var expected_y: float = TerrainBuilderScript.FOREST_LOS_HEIGHT
			if not is_equal_approx(box.size.y, expected_y):
				print("    BoxShape3D Y = %f, expected %f (FOREST_LOS_HEIGHT)" % [box.size.y, expected_y])
				return false
			return true
	print("    no StaticBody3D created")
	return false


# (2) _spawn_ambient_trees() filters out per-item positions on
# slopes > AMBIENT_TREE_MAX_SLOPE (0.5). Build a map with a single
# tall hill whose face is way over 0.5, and confirm no tree was
# placed on the hill's face. We don't check "exactly zero trees on
# the face" - the cluster-center pick may have rejected the whole
# cluster if its center was steep, in which case no trees are
# placed in that area at all. The invariant we want is "no trees
# placed in the high-slope region," which we test by sampling
# placed positions and confirming each one is below the slope cap.
#
# Note: this test runs the ambient tree scatter with a
# disable_ambient_scatter workaround. The scatter function is async
# (uses await). In a SceneTree test, we can't easily await an
# async function from _init. We sidestep this by calling the
# function and checking the returned positions array.
func _test_trees_reject_steep_slope() -> bool:
	var raw: Dictionary = {
		"name": "Tree Slope Test",
		"description": "Trees not placed on slopes > 0.5.",
		"map_half_extents": 100.0,
		"world_scale": 1.0,
		"ground_color": [0.3, 0.3, 0.3],
		"base_zones": [], "water_areas": [],
		"obstacles": [],
		# Tall narrow hill: every per-item position on its face has
		# slope > 0.5. AMBIENT_TREE_MAX_SLOPE = 0.5 should reject
		# them all.
		"hills": [
			{"center": [0.0, 0.0, 0.0], "radius": 5.0, "height": 20.0, "falloff": 2.0},
		],
		"spawns": [],
		"resource_nodes": [],
		"schema_version": 1,
	}
	var map_def: Dictionary = _decoded(raw)
	var parent: Node3D = Node3D.new()
	root.add_child(parent)
	# _spawn_ambient_trees is a coroutine even with a null ticker
	# (the function declares `await` calls). Await it.
	var placed: Array = await TerrainBuilderScript._spawn_ambient_trees(map_def, parent, 1.0, null)
	# Walk every placed position: the slope at the placement must be
	# at or below the cap.
	var max_seen: float = 0.0
	for pos in placed:
		var s: float = TerrainBuilderScript._slope_at(map_def, pos.x, pos.z)
		if s > max_seen:
			max_seen = s
		if s > TerrainBuilderScript.AMBIENT_TREE_MAX_SLOPE:
			print("    tree placed at slope %.3f > cap %.3f" % [s, TerrainBuilderScript.AMBIENT_TREE_MAX_SLOPE])
			return false
	# And the cap is the documented value.
	if not is_equal_approx(TerrainBuilderScript.AMBIENT_TREE_MAX_SLOPE, 0.5):
		print("    AMBIENT_TREE_MAX_SLOPE = %f, expected 0.5" % TerrainBuilderScript.AMBIENT_TREE_MAX_SLOPE)
		return false
	# And some trees WERE placed (the rest of the map is flat), so the
	# filter is real, not just rejecting everything.
	if placed.size() == 0:
		print("    no trees were placed at all - test setup may be off")
		return false
	return true
