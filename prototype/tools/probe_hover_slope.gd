extends SceneTree
# HOVER SLOPE GATING
# ---------------------------------------------------------------------------
# Every `hovering` locomotor - hover_engine, anti_grav_plate,
# air_cushion_skirt, plasma_thruster - is routed onto the AMPHIBIOUS nav
# surface by unit_assembly.build_nav_agent(). That surface used to emit a quad
# for every cell that was not a building hole, with no slope test whatsoever,
# so a hover pad could path straight up a vertical rock face while a wheeled
# unit standing next to it could not.
#
# This probe walks a map's cells and cross-checks the two surfaces:
#
#   steep + dry    must be absent from BOTH ground and amphibious
#   steep + water  must be present on amphibious (a hover unit floats over a
#                  30 m deep lake; the bed's slope is not its problem)
#   gentle + dry   must be present on BOTH
#
# The steep-and-dry row is the regression. The steep-and-water row is the
# reason the slope test has to be taken AFTER the water-surface raise rather
# than off raw terrain heights - test it off the bed and hovercraft lose every
# lake with a steep shore.
#
#   Godot_v4.7.1-stable_win64_console.exe --headless --path prototype \
#     --script res://tools/probe_hover_slope.gd --quit [-- --map delta_blues]

const TerrainBuilderScript = preload("res://scripts/terrain_builder.gd")
const MapCatalogScript = preload("res://scripts/map_catalog.gd")
const NavCoverageScript = preload("res://tools/nav_coverage.gd")

# Sampling step across the map, in metres. Independent of the nav grid cell on
# purpose - this probe asks "is there navigable surface near this world point",
# which is the question a unit asks, not "did cell (i,j) emit".
const SAMPLE_STEP := 12.0


func _init() -> void:
	var maps: Array = []
	var args := OS.get_cmdline_user_args()
	var i := args.find("--map")
	if i >= 0 and i + 1 < args.size():
		maps = [args[i + 1]]
	else:
		maps = ["delta_blues", "the_great_valley", "sentinel_divide", "the_reef"]

	var failures := 0
	for map_id in maps:
		failures += _check(str(map_id))
	print("")
	if failures == 0:
		print("[PASS] hover slope gating holds on all %d map(s)." % [maps.size()])
		quit(0)
	else:
		print("[FAIL] %d violation class(es)." % [failures])
		quit(1)


func _check(map_id: String) -> int:
	var map_def: Dictionary = MapCatalogScript.get_map(map_id)
	if map_def.is_empty():
		print("[skip] unknown map: ", map_id)
		return 0

	var ground = NavCoverageScript.new(TerrainBuilderScript._build_ground_faces(map_def))
	var amph = NavCoverageScript.new(TerrainBuilderScript._build_amphibious_faces(map_def))

	var half: Vector2 = MapCatalogScript.half_extents(map_def)
	# DIFFERENTIAL, not absolute. Coverage is exact (see nav_coverage.gd), but
	# the two surfaces still disagree harmlessly at cell boundaries and near
	# the map edge. The question that matters is only whether amphibious grants
	# reach onto steep ground that the ground surface refuses.
	var steep_dry_extra := 0
	var steep_dry_total := 0
	var steep_wet_on_amph := 0
	var steep_wet_total := 0
	var gentle_dry_lost := 0
	var gentle_dry_total := 0

	var x := -half.x + SAMPLE_STEP
	while x < half.x - SAMPLE_STEP:
		var z := -half.y + SAMPLE_STEP
		while z < half.y - SAMPLE_STEP:
			var slope: float = TerrainBuilderScript.slope_at(map_def, x, z)
			var surf: float = TerrainBuilderScript.water_surface_at(map_def, x, z)
			var h: float = TerrainBuilderScript.terrain_height_at(map_def, Vector3(x, 0.0, z))
			var wet: bool = surf > TerrainBuilderScript.NO_WATER * 0.5 and h < surf
			var on_amph: bool = amph.covers(x, z)
			var on_ground: bool = ground.covers(x, z)
			if slope > TerrainBuilderScript.MAX_WALKABLE_SLOPE:
				if wet:
					steep_wet_total += 1
					if on_amph:
						steep_wet_on_amph += 1
				else:
					steep_dry_total += 1
					if on_amph and not on_ground:
						steep_dry_extra += 1
			elif not wet:
				gentle_dry_total += 1
				if on_ground and not on_amph:
					gentle_dry_lost += 1
			z += SAMPLE_STEP
		x += SAMPLE_STEP

	print("")
	print("== %s   (ground tris %d, amphibious tris %d)"
		% [map_id, ground.triangle_count(), amph.triangle_count()])
	_row("steep+dry  amph-but-not-ground", steep_dry_extra, steep_dry_total)
	_row("steep+water on amph (want ~all)", steep_wet_on_amph, steep_wet_total)
	_row("gentle+dry ground-but-not-amph", gentle_dry_lost, gentle_dry_total)

	var bad := 0
	# Hover must not reach steep dry ground that a wheeled unit cannot. A few
	# samples either way are cell-boundary noise; the regression was ~100%.
	if steep_dry_total > 0 and float(steep_dry_extra) / float(steep_dry_total) > 0.05:
		print("   [FAIL] hover reaches steep dry ground that ground units cannot.")
		bad += 1
	if steep_wet_total > 0 and float(steep_wet_on_amph) / float(steep_wet_total) < 0.5:
		print("   [FAIL] hover lost navigable water - slope test is reading the bed.")
		bad += 1
	if gentle_dry_total > 0 and float(gentle_dry_lost) / float(gentle_dry_total) > 0.05:
		print("   [FAIL] hover lost ordinary walkable ground that wheels keep.")
		bad += 1
	return bad


func _row(label: String, hit: int, total: int) -> void:
	var pct: float = 100.0 * float(hit) / float(maxi(total, 1))
	print("   %-32s %6d / %-6d  %5.1f%%" % [label, hit, total, pct])


