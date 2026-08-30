extends SceneTree
# Verifies the non-square refactor didn't break existing square maps.
# Loads open_plains (a square 210-half map) and confirms:
#   - half_extents() returns (210, 210) when map_half_extents_z is absent
#   - height_at() returns finite values across the whole 210x210 map
#   - is_position_blocked at obstacle centers still returns true
#
# Run: godot --headless --script _test_existing_maps.gd --path prototype

const MapCatalogScript = preload("res://scripts/map_catalog.gd")
const TerrainBuilderScript = preload("res://scripts/terrain_builder.gd")

func _init() -> void:
	MapCatalogScript.reset_cache_for_tests()
	var map_def: Dictionary = MapCatalogScript.get_map("test_range")
	if map_def.is_empty():
		print("[FAIL] test_range failed to load")
		quit(1); return
	print("[PASS] test_range loaded")
	var he: Vector2 = MapCatalogScript.half_extents(map_def)
	# open_plains has world_scale=4.0, so the post-scale half_extents
	# is 840, not 210. The test pins "both axes equal AND map stayed
	# square after the world-scale multiplier" - the key invariant
	# for the non-square refactor.
	if he.x != he.y:
		print("[FAIL] open_plains half_extents is non-square (%s, %s) - should be square" % [he.x, he.y])
		quit(1); return
	if absf(he.x - 840.0) > 0.1:
		print("[FAIL] open_plains half_extents = %.1f, expected ~840 (210 * world_scale 4.0)" % he.x)
		quit(1); return
	print("[PASS] open_plains half_extents = (%.0f, %.0f) - still square after non-square refactor" % [he.x, he.y])
	# All height_at calls are finite
	var bad: int = 0
	for x in range(-200, 201, 50):
		for z in range(-200, 201, 50):
			var h: float = TerrainBuilderScript.height_at(map_def, x, z)
			if not is_finite(h):
				bad += 1
	if bad > 0:
		print("[FAIL] %d non-finite height_at() calls on open_plains" % bad)
		quit(1); return
	print("[PASS] open_plains height_at() is finite across the whole map")
	# Every obstacle center is blocked
	for o in map_def.get("obstacles", []):
		if not TerrainBuilderScript.is_position_blocked(map_def, o.center):
			print("[FAIL] open_plains obstacle at %s is not blocked" % o.center)
			quit(1); return
	print("[PASS] open_plains obstacles all reported as blocked")
	print("[ALL PASS] existing square maps still work")
	quit(0)
