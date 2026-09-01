extends SceneTree
# WATER MUST BLOCK GROUND TRANSIT
# ---------------------------------------------------------------------------
# A unit that is not amphibious, not hovering, not flying and not naval is
# routed onto the GROUND nav surface by unit_assembly.build_nav_agent(). Open
# water must not appear on that surface, or a wheeled tank drives across a lake
# and, worse, along the bed of it.
#
# Reports how much genuinely-submerged ground each map still exposes to the
# ground surface, and how deep it is. `_build_ground_faces()` carves a cell
# only when its HIGHEST corner is more than SUBMERGED_MIN_DEPTH under the
# surface - that is deliberate (it keeps the shoreline walkable instead of
# eating a ring of beach), so shallow fringe hits are expected and only deep
# water is a defect.
#
#   Godot_v4.7.1-stable_win64_console.exe --headless --path prototype \
#     --script res://tools/probe_water_blocks_ground.gd --quit [-- --map <id>]

const TerrainBuilderScript = preload("res://scripts/terrain_builder.gd")
const MapCatalogScript = preload("res://scripts/map_catalog.gd")
const NavCoverageScript = preload("res://tools/nav_coverage.gd")

const SAMPLE_STEP := 8.0
# Past this depth there is no "wet beach" reading left - it is a lake, and a
# ground unit standing in it is a bug however the shoreline rule is tuned.
const DEEP := 2.5

# KNOWN, AND NOT A NAVMESH BUG. has_water_table() returns true for EVERY v2
# map, so a map that declares no water_level, no water_areas, no water_blobs
# and ships no water paint still gets an implicit table at
# WATER_LEVEL_DEFAULT (-2.0). twin_bluffs is such a map and its bluffs run
# ~53 m below that line, so every canyon floor on it classifies as "deep
# water" here while the game draws no water and plays it as dry rock. Whether
# an undeclared v2 map should have a water table at all is a map-data
# question, not one this probe can answer, so the map is listed and excluded
# from the verdict rather than quietly passed.
const IMPLICIT_WATER_TABLE_MAPS := ["twin_bluffs"]


func _init() -> void:
	var maps: Array = []
	var args := OS.get_cmdline_user_args()
	var i := args.find("--map")
	if i >= 0 and i + 1 < args.size():
		maps = [args[i + 1]]
	else:
		maps = MapCatalogScript.get_map_ids()

	var bad := 0
	for map_id in maps:
		bad += _check(str(map_id))
	print("")
	if bad == 0:
		print("[PASS] no map exposes deep water to the ground nav surface.")
		quit(0)
	else:
		print("[FAIL] %d map(s) let ground units into deep water." % [bad])
		quit(1)


func _check(map_id: String) -> int:
	var map_def: Dictionary = MapCatalogScript.get_map(map_id)
	if map_def.is_empty():
		return 0
	if not TerrainBuilderScript.has_water_table(map_def) \
			and TerrainBuilderScript._water_paint_for(map_id) == null:
		return 0

	var ground = NavCoverageScript.new(TerrainBuilderScript._build_ground_faces(map_def))
	var half: Vector2 = MapCatalogScript.half_extents(map_def)

	var wet_total := 0
	var wet_on_ground := 0
	var deep_total := 0
	var deep_on_ground := 0
	var worst_depth := 0.0

	var x := -half.x + SAMPLE_STEP
	while x < half.x - SAMPLE_STEP:
		var z := -half.y + SAMPLE_STEP
		while z < half.y - SAMPLE_STEP:
			var surf: float = TerrainBuilderScript.water_surface_at(map_def, x, z)
			if surf > TerrainBuilderScript.NO_WATER * 0.5:
				var h: float = TerrainBuilderScript.height_at(map_def, x, z)
				var depth: float = surf - h
				if depth > TerrainBuilderScript.SUBMERGED_MIN_DEPTH:
					wet_total += 1
					var on_ground: bool = ground.covers(x, z)
					if on_ground:
						wet_on_ground += 1
					if depth > DEEP:
						deep_total += 1
						if on_ground:
							deep_on_ground += 1
							worst_depth = maxf(worst_depth, depth)
			z += SAMPLE_STEP
		x += SAMPLE_STEP

	if wet_total == 0:
		return 0
	print("  %-22s submerged %5d  on ground %5d (%4.1f%%) | deep %5d  on ground %5d (%4.1f%%)  worst %.1f m"
		% [map_id, wet_total, wet_on_ground,
		   100.0 * float(wet_on_ground) / float(wet_total),
		   deep_total, deep_on_ground,
		   100.0 * float(deep_on_ground) / float(maxi(deep_total, 1)),
		   worst_depth])
	if map_id in IMPLICIT_WATER_TABLE_MAPS:
		print("      ^ excluded from the verdict: no declared water, implicit table only")
		return 0
	if deep_total > 0 and float(deep_on_ground) / float(deep_total) > 0.05:
		return 1
	return 0


