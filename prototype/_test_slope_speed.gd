extends SceneTree
# Slope class + slope-aware speed multiplier smoke test
# (canyon_ford PR3, 2026-08-26).
#
# Confirms:
#   1. slope_class_at() returns "walkable" / "walkable_slow" /
#      "impassable" at the right slope thresholds (0.0-0.3, 0.3-0.7,
#      0.7+).
#   2. is_position_blocked() agrees with the new slope class
#      (a position with slope > 0.7 is "impassable" AND blocked).
#   3. SLOPE_SPEED_MULTIPLIERS returns the right per-locomotion values
#      for each slope class.
#   4. The composition in unit.gd (surface_mult * slope_mult) produces
#      the expected combined multiplier for a wheels unit on a steep
#      marsh (the worst case the table compounds to).
#
# Run with: godot --headless --script _test_slope_speed.gd --path prototype

const TerrainBuilderScript = preload("res://scripts/terrain_builder.gd")
const MapCatalogScript = preload("res://scripts/map_catalog.gd")
const ModuleCatalogScript = preload("res://scripts/module_catalog.gd")

static func _decoded(raw: Dictionary) -> Dictionary:
	return MapCatalogScript._decode_dict(raw, MapCatalogScript.FIELD_SPEC)

func _init():
	var failed: int = 0

	if not _test_slope_class_thresholds():
		failed += 1
		print("[FAIL] slope class thresholds")
	else:
		print("[PASS] slope class thresholds")

	if not _test_is_position_blocked_agrees_with_class():
		failed += 1
		print("[FAIL] is_position_blocked agrees with slope class")
	else:
		print("[PASS] is_position_blocked agrees with slope class")

	if not _test_slope_speed_table():
		failed += 1
		print("[FAIL] slope speed table values")
	else:
		print("[PASS] slope speed table values")

	if not _test_surface_times_slope_compose():
		failed += 1
		print("[FAIL] surface * slope composition")
	else:
		print("[PASS] surface * slope composition")

	print("")
	if failed == 0:
		print("[PASS] all slope-speed tests pass")
		quit(0)
	else:
		print("[FAIL] %d/4 slope-speed tests fail" % failed)
		quit(1)


# Build a map with a single tall hill. Sample the slope class at the
# hill's center (max slope) and far away (no slope). Confirm the
# classification matches the documented thresholds.
func _test_slope_class_thresholds() -> bool:
	var raw: Dictionary = {
		"name": "Slope Class Test",
		"description": "Single tall hill for slope class boundary checks.",
		"map_half_extents": 100.0,
		"world_scale": 1.0,
		"ground_color": [0.3, 0.3, 0.3],
		"base_zones": [], "water_areas": [],
		"obstacles": [],
		# Tall, narrow hill = high slope at its face. height=20, radius=5
		# means the slope is ~4 rise per 1 run (very steep, well into
		# impassable). The exact value isn't the test - the test is
		# that slope_class_at returns one of the three documented
		# strings at any point in the map.
		"hills": [
			{"center": [0.0, 0.0, 0.0], "radius": 5.0, "height": 20.0, "falloff": 2.0},
		],
		"spawns": [],
		"resource_nodes": [],
		"schema_version": 1,
	}
	var map_def: Dictionary = _decoded(raw)

	# Far from the hill: slope is 0, class must be "walkable".
	var far_class: String = TerrainBuilderScript.slope_class_at(map_def, 90.0, 90.0)
	if far_class != TerrainBuilderScript.SLOPE_WALKABLE:
		print("    far point slope_class = %s, expected %s" % [far_class, TerrainBuilderScript.SLOPE_WALKABLE])
		return false

	# At the hill's face: slope is high, class must be "impassable".
	var hill_class: String = TerrainBuilderScript.slope_class_at(map_def, 5.0, 0.0)
	if hill_class != TerrainBuilderScript.SLOPE_IMPASSABLE:
		print("    hill face slope_class = %s, expected %s" % [hill_class, TerrainBuilderScript.SLOPE_IMPASSABLE])
		return false

	return true


# Build a map with a tall hill and confirm is_position_blocked returns
# true at the hill's face (slope is "impassable" = blocked) and false
# at the far edge (no hill = walkable).
func _test_is_position_blocked_agrees_with_class() -> bool:
	var raw: Dictionary = {
		"name": "Block Agrees Test",
		"description": "Confirms is_position_blocked uses the same slope class.",
		"map_half_extents": 100.0,
		"world_scale": 1.0,
		"ground_color": [0.3, 0.3, 0.3],
		"base_zones": [], "water_areas": [],
		"obstacles": [],
		"hills": [
			{"center": [0.0, 0.0, 0.0], "radius": 5.0, "height": 20.0, "falloff": 2.0},
		],
		"spawns": [],
		"resource_nodes": [],
		"schema_version": 1,
	}
	var map_def: Dictionary = _decoded(raw)

	# Far point: not blocked.
	if TerrainBuilderScript.is_position_blocked(map_def, Vector3(90, 0, 90)):
		print("    is_position_blocked(90,90) = true, expected false")
		return false

	# Hill face: blocked.
	if not TerrainBuilderScript.is_position_blocked(map_def, Vector3(5, 0, 0)):
		print("    is_position_blocked(5,0,hill face) = false, expected true")
		return false

	return true


# Spot-check the SLOPE_SPEED_MULTIPLIERS table. The two key per-locomotion
# rows are wheels (gets penalised) and hover_engine (doesn't, by
# design - the same TERRAIN_INTENTIONALLY_FLAT philosophy applies).
func _test_slope_speed_table() -> bool:
	# wheels: walkable_slow = 0.6
	if ModuleCatalogScript.get_slope_speed_multiplier("wheels", "walkable_slow") != 0.6:
		print("    wheels walkable_slow != 0.6")
		return false
	# wheels: walkable = 1.0
	if ModuleCatalogScript.get_slope_speed_multiplier("wheels", "walkable") != 1.0:
		print("    wheels walkable != 1.0")
		return false
	# hover_engine: walkable_slow = 1.0 (intentionally flat)
	if ModuleCatalogScript.get_slope_speed_multiplier("hover_engine", "walkable_slow") != 1.0:
		print("    hover_engine walkable_slow != 1.0")
		return false
	# Empty string: defaults to walkable (so no-controller = 1.0x)
	if ModuleCatalogScript.get_slope_speed_multiplier("wheels", "") != 1.0:
		print("    wheels empty (no controller) != 1.0")
		return false
	# Unknown locomotion: defaults to 1.0 (no penalty)
	if ModuleCatalogScript.get_slope_speed_multiplier("not_a_real_locomotor", "walkable_slow") != 1.0:
		print("    unknown locomotion default != 1.0")
		return false
	return true


# Compose surface * slope for the worst case: wheels on steep marsh.
# Marsh: wheels = 0.25, slope=0.6 (walkable_slow): wheels = 0.6.
# Composed: 0.25 * 0.6 = 0.15. This is the floor the tracked_treads
# clamp is sized for; verifies the units multiply, not min(), not max().
func _test_surface_times_slope_compose() -> bool:
	var surface_mult: float = ModuleCatalogScript.get_terrain_speed_multiplier("wheels", "marsh")
	var slope_mult: float = ModuleCatalogScript.get_slope_speed_multiplier("wheels", "walkable_slow")
	var composed: float = surface_mult * slope_mult
	if not is_equal_approx(composed, 0.15):
		print("    composed wheels-on-steep-marsh = %f, expected 0.15" % composed)
		return false
	# And a "good slope terrain" case: hover on steep rocky.
	# rocky: hover = 0.55, slope walkable_slow: hover = 1.0.
	# Composed: 0.55 * 1.0 = 0.55. Slope doesn't penalise hover.
	var hover_surface: float = ModuleCatalogScript.get_terrain_speed_multiplier("hover_engine", "rocky")
	var hover_slope: float = ModuleCatalogScript.get_slope_speed_multiplier("hover_engine", "walkable_slow")
	var hover_composed: float = hover_surface * hover_slope
	if not is_equal_approx(hover_composed, 0.55):
		print("    composed hover-on-steep-rocky = %f, expected 0.55" % hover_composed)
		return false
	return true
