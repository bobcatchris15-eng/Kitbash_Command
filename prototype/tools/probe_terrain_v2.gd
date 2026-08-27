extends SceneTree
# Headless verification for the terrain v2 path and its showcase map.
#
# The brief's acceptance criteria are geometric claims - "a canyon forcing a
# routing decision", "a plateau with defined access", "correct pathfinding
# around impassable terrain" - and every one of them is checkable without a
# window. This probe is what says whether the map delivers them, rather than
# an eyeball on a screenshot that only shows the quarter of the map in frame.
#
# Run:
#   Godot_v4.7.1-stable_win64_console.exe --headless --path <prototype>
#     --script res://tools/probe_terrain_v2.gd --quit
#
# Optional: `-- --map <id>` to point it at a different map.

const TerrainBuilderScript = preload("res://scripts/terrain_builder.gd")
const MapCatalogScript = preload("res://scripts/map_catalog.gd")

var _fail: int = 0
var _pass: int = 0

func _check(ok: bool, label: String, detail: String = "") -> void:
	if ok:
		_pass += 1
		print("  [PASS] %s%s" % [label, ("  " + detail) if detail != "" else ""])
	else:
		_fail += 1
		print("  [FAIL] %s%s" % [label, ("  " + detail) if detail != "" else ""])


func _map_id_from_args() -> String:
	var args := OS.get_cmdline_user_args()
	for i in range(args.size()):
		if args[i] == "--map" and i + 1 < args.size():
			return args[i + 1]
	return "sentinel_divide"


func _initialize() -> void:
	var map_id := _map_id_from_args()
	print("=== terrain v2 probe: %s ===" % map_id)

	# --- 1. Loads and validates -------------------------------------------
	var errors: Array = MapCatalogScript.validate_map(map_id)
	_check(errors.is_empty(), "schema validates", "" if errors.is_empty() else str(errors))

	var map_def: Dictionary = MapCatalogScript.get_map(map_id)
	# get_map() falls back to DEFAULT_MAP_ID for an unknown or refused id
	# rather than erroring, so confirm we got the map we asked for. It cannot
	# be checked via map_def.id - MapCatalog keys its cache by filename and
	# never puts an "id" key in the dictionary it hands back - so the catalog
	# listing is the source of truth for "this map is loadable at all".
	var in_catalog: bool = MapCatalogScript.get_map_ids().has(map_id)
	_check(in_catalog, "map is in the catalog (loaded without being refused)")
	if not in_catalog:
		print("  load error: %s" % MapCatalogScript.get_last_load_error())
		_finish()
		return

	_check(TerrainBuilderScript.terrain_generator(map_def) == "v2",
		"declares generator v2",
		"got '%s'" % TerrainBuilderScript.terrain_generator(map_def))

	var half: float = float(map_def.get("map_half_extents", 100.0))

	# --- 2. Height range ---------------------------------------------------
	var lo := INF
	var hi := -INF
	var step := half / 60.0
	var x := -half
	while x <= half:
		var z := -half
		while z <= half:
			var h: float = TerrainBuilderScript.height_at(map_def, x, z)
			lo = minf(lo, h)
			hi = maxf(hi, h)
			z += step
		x += step
	print("  height range: %.1f .. %.1f (relief %.1f m)" % [lo, hi, hi - lo])
	_check(hi - lo > 20.0, "has dramatic relief (>20 m)", "%.1f m" % (hi - lo))

	# --- 3. The ramps are actually walkable all the way up -----------------
	# This is the check that would have caught the summing bug: with features
	# adding, a ramp anchored on a plateau edge builds a ~30 m spike at the lip
	# and the "access point" is a wall.
	_probe_ramp(map_def, "west ramp", Vector3(-270.0, 0.0, 120.0), Vector3(-140.0, 0.0, 120.0))
	_probe_ramp(map_def, "east ramp", Vector3(270.0, 0.0, -120.0), Vector3(140.0, 0.0, -120.0))

	# --- 4. The plateau is NOT walkable anywhere else -----------------------
	# Sample the west plateau's perimeter, skipping the ramp corridor, and
	# require every other approach to be impassable. "Reachable only via
	# defined access points" is a claim about the other 95% of the edge.
	_probe_plateau_rim(map_def, "west plateau",
		Vector3(-450.0, 0.0, 120.0), Vector2(210.0, 165.0),
		Vector3(-240.0, 0.0, 120.0), 70.0, 3.0)
	_probe_plateau_rim(map_def, "east plateau",
		Vector3(450.0, 0.0, -120.0), Vector2(210.0, 165.0),
		Vector3(240.0, 0.0, -120.0), 70.0, 3.0)

	# --- 5. Canyon walls impassable, chokepoint gaps walkable --------------
	_probe_cross_section(map_def, "canyon wall @ z=0", 0.0, -160.0, 160.0, true)
	_probe_cross_section(map_def, "north neck @ z=277", 277.0, -160.0, 160.0, false)
	_probe_cross_section(map_def, "south neck @ z=-277", -277.0, -160.0, 160.0, false)

	# --- 6. Navmesh bakes, and the two sides are connected ONLY via the necks
	var gf: PackedVector3Array = TerrainBuilderScript._build_ground_faces(map_def)
	print("  ground nav source: %d verts / %d tris | nav grid cell %.2f | tile %.1f | tile cell %.2f"
		% [gf.size(), gf.size() / 3,
			TerrainBuilderScript._nav_grid_cell(map_def),
			TerrainBuilderScript._nav_tile_size(map_def),
			TerrainBuilderScript._nav_tile_cell_size(map_def)])
	# Bake a few tiles by hand to separate "the bake produced nothing" from
	# "the server did not accept it".
	var rects: Array = TerrainBuilderScript._nav_tile_rects(map_def)
	var buckets: Array = TerrainBuilderScript._bucket_verts_by_tile(gf, map_def, rects, 0.0)
	var tile_cell: float = TerrainBuilderScript._nav_tile_cell_size(map_def)
	var nonempty_src := 0
	var nonempty_baked := 0
	var sample_report := ""
	for i in range(buckets.size()):
		var bv: PackedVector3Array = buckets[i]
		if bv.is_empty():
			continue
		nonempty_src += 1
		if nonempty_src <= 4:
			var nm: NavigationMesh = TerrainBuilderScript._bake_nav_mesh(bv, tile_cell, rects[i])
			var nv := nm.get_vertices().size()
			var np := nm.get_polygon_count()
			if nv > 0:
				nonempty_baked += 1
			sample_report += " [tile %d: src %d tris -> %d verts / %d polys]" % [i, bv.size() / 3, nv, np]
	print("  tiles with source geometry: %d/%d%s" % [nonempty_src, buckets.size(), sample_report])
	_check(nonempty_baked > 0, "tile bake produces polygons")

	print("  baking navmeshes (sync)...")
	var t0 := Time.get_ticks_msec()
	var nav: Dictionary = TerrainBuilderScript.build_navmeshes(map_def)
	print("  navmesh bake: %d ms" % (Time.get_ticks_msec() - t0))
	var ground_map: RID = nav.get("ground_map", RID())
	_check(ground_map.is_valid(), "ground nav map created")

	# The path query has to wait for the server to synchronise, and
	# NavigationServer3D synchronises on a PHYSICS FRAME. _initialize() runs
	# before the main loop has stepped even once, so querying here returns an
	# empty path on a perfectly good navmesh - which is exactly what the first
	# run of this probe reported. Hand off to _process() and let frames tick.
	_map_def = map_def
	_ground_map = ground_map
	if not ground_map.is_valid():
		_finish()


var _map_def: Dictionary = {}
var _ground_map: RID = RID()
var _frames: int = 0
# POLL, do not count frames. Godot 4.4+ iterates navigation maps
# ASYNCHRONOUSLY (navigation/world/map_use_async_iterations), so
# map_force_update() schedules the rebuild rather than guaranteeing the next
# query sees it. A fixed 8-frame wait passed on one run and failed on the very
# next with identical inputs - 49/49 closest-point hits, then 0/49. Waiting
# until the map answers a query is the only stable signal.
const NAV_SYNC_MAX_FRAMES: int = 600


func _process(_delta: float) -> bool:
	if _map_def.is_empty():
		return false
	_frames += 1
	NavigationServer3D.map_force_update(_ground_map)
	if not _nav_ready() and _frames < NAV_SYNC_MAX_FRAMES:
		return false
	_run_nav_checks()
	_finish()
	return true


var _last_iteration: int = -1
var _stable_frames: int = 0
# How many consecutive frames the iteration id must hold before the map counts
# as settled.
const NAV_STABLE_FRAMES: int = 6


# The map is ready when its ITERATION ID has stopped advancing, not merely when
# one probe point answers.
#
# Checking a single point was not enough: a partially-synced map can resolve a
# point near the centre while regions further out are still being merged, and a
# path query then returns a short, suboptimal or partial route. That showed up
# as the mid-map crossing reporting 27% detour and a complete route on one run,
# then 8% and "stops 40 m short" on the next, with identical inputs and no code
# change in between. map_get_iteration_id() is what Godot's own navmesh warning
# points at for exactly this.
func _nav_ready() -> bool:
	if NavigationServer3D.map_get_regions(_ground_map).is_empty():
		return false
	var it: int = NavigationServer3D.map_get_iteration_id(_ground_map)
	if it != _last_iteration:
		_last_iteration = it
		_stable_frames = 0
		return false
	_stable_frames += 1
	if _stable_frames < NAV_STABLE_FRAMES:
		return false
	var probe := Vector3(0.0, 0.0, 0.0)
	probe.z = float(_map_def.get("map_half_extents", 100.0)) * 0.28
	probe.y = TerrainBuilderScript.height_at(_map_def, probe.x, probe.z)
	return NavigationServer3D.map_get_closest_point(_ground_map, probe).distance_to(probe) < 12.0


func _run_nav_checks() -> void:
	var map_def := _map_def
	var ground_map := _ground_map
	_map_def = {}
	NavigationServer3D.map_force_update(ground_map)
	var regions: int = NavigationServer3D.map_get_regions(ground_map).size()
	print("  nav regions on ground map: %d (map became queryable after %d frames)" % [regions, _frames])
	_check(regions > 0, "ground map has baked regions", "%d" % regions)

	# Is ANY of the map queryable, or none of it? A grid of closest-point
	# queries separates "one bad endpoint" from "the whole map is empty".
	var half: float = float(map_def.get("map_half_extents", 100.0))
	var hits := 0
	var tries := 0
	for gx in range(-3, 4):
		for gz in range(-3, 4):
			var q := Vector3(float(gx) * half / 3.5, 0.0, float(gz) * half / 3.5)
			q.y = TerrainBuilderScript.height_at(map_def, q.x, q.z)
			tries += 1
			if NavigationServer3D.map_get_closest_point(ground_map, q).distance_to(q) < 12.0:
				hits += 1
	print("  closest-point grid: %d/%d queries landed on navmesh" % [hits, tries])
	if true:
		var spawns: Array = map_def.get("spawns", [])
		if spawns.size() >= 2:
			var a: Vector3 = TerrainBuilderScript._vec3_of(spawns[0].get("hq", Vector3.ZERO))
			var b: Vector3 = TerrainBuilderScript._vec3_of(spawns[1].get("hq", Vector3.ZERO))
			a.y = TerrainBuilderScript.height_at(map_def, a.x, a.z)
			b.y = TerrainBuilderScript.height_at(map_def, b.x, b.z)
			var ca: Vector3 = NavigationServer3D.map_get_closest_point(ground_map, a)
			var cb: Vector3 = NavigationServer3D.map_get_closest_point(ground_map, b)
			print("  A %s -> nearest navmesh %s (%.1f m away)" % [a, ca, a.distance_to(ca)])
			print("  B %s -> nearest navmesh %s (%.1f m away)" % [b, cb, b.distance_to(cb)])
			# Query from the ON-MESH points. An HQ pad sits wherever the map
			# author put it, which is not necessarily inside a navmesh polygon
			# (agent-radius erosion alone pulls the mesh in by 1 m), and
			# map_get_path returns an EMPTY path rather than a nearest-point
			# path when an endpoint is off-mesh.
			var path: PackedVector3Array = NavigationServer3D.map_get_path(ground_map, ca, cb, true)
			var straight := a.distance_to(b)
			var walked := 0.0
			for i in range(1, path.size()):
				walked += path[i - 1].distance_to(path[i])
			# map_get_path returns a PARTIAL path to the closest reachable
			# point when the destination cannot be reached, rather than an
			# empty one - so "a path came back" is not the same as "B is
			# reachable", and a partial path can be shorter than the straight
			# line. Check where it actually ended.
			var end_gap := 0.0 if path.is_empty() else path[path.size() - 1].distance_to(cb)
			if not path.is_empty():
				var tail := path[path.size() - 1]
				print("  path ends at %s (slope class there: %s, height %.1f)"
					% [tail, TerrainBuilderScript.slope_class_at(map_def, tail.x, tail.z),
						TerrainBuilderScript.height_at(map_def, tail.x, tail.z)])
			print("  HQ->HQ: straight %.0f m, path %.0f m over %d points, ends %.1f m from B"
				% [straight, walked, path.size(), end_gap])
			_check(path.size() >= 2, "a ground route between the two HQs exists")
			_check(end_gap < 25.0, "the route actually reaches the far HQ",
				"stops %.0f m short" % end_gap)
			# Informational only. These two HQs sit diagonally opposite, so a
			# route between them passes near a neck anyway and the detour is
			# small by construction - it says little about whether the canyon
			# works. The real test is a straight-across crossing, below.
			print("  HQ->HQ detour: %.0f%% over the straight line"
				% ((walked / maxf(straight, 1.0) - 1.0) * 100.0))
			# And it must pass through one of the two necks, not the middle.
			var crossed_at_z := _crossing_z(path)
			_check(crossed_at_z != INF, "path crosses the divide", "at z=%.0f" % crossed_at_z)
			if crossed_at_z != INF:
				_check(absf(absf(crossed_at_z) - 277.0) < 75.0,
					"crossing happens at a neck (|z| ~ 207..347)",
					"z=%.0f" % crossed_at_z)

	# The canyon's actual job: anything trying to cross the middle must be
	# pushed out to a neck. This is where a failure to block would show up.
	_probe_forced_detour(map_def, ground_map)


# Walk the ramp from its top to its foot and require a continuous, walkable
# descent - no spike, no notch, no over-slope step.
func _probe_ramp(map_def: Dictionary, label: String, top: Vector3, foot: Vector3) -> void:
	var samples := 26
	var worst_slope := 0.0
	var worst_at := Vector3.ZERO
	var heights: Array = []
	for i in range(samples + 1):
		var t := float(i) / float(samples)
		var p: Vector3 = top.lerp(foot, t)
		heights.append(TerrainBuilderScript.height_at(map_def, p.x, p.z))
		var s: float = TerrainBuilderScript.slope_at(map_def, p.x, p.z)
		if s > worst_slope:
			worst_slope = s
			worst_at = p
	var top_h: float = heights[0]
	var foot_h: float = heights[heights.size() - 1]
	print("  %s: top %.1f m -> foot %.1f m, worst slope %.2f at (%.0f, %.0f)"
		% [label, top_h, foot_h, worst_slope, worst_at.x, worst_at.z])
	_check(top_h > 10.0, "%s starts on the plateau" % label, "%.1f m" % top_h)
	_check(foot_h < 3.0, "%s reaches grade" % label, "%.1f m" % foot_h)
	# Monotonic: a spike at the lip shows up as a rise partway down.
	var max_rise := 0.0
	for i in range(1, heights.size()):
		max_rise = maxf(max_rise, float(heights[i]) - float(heights[i - 1]))
	_check(max_rise < 1.0, "%s descends monotonically (no lip)" % label,
		"largest rise %.2f m" % max_rise)
	_check(worst_slope <= TerrainBuilderScript.MAX_WALKABLE_SLOPE,
		"%s is walkable end to end" % label,
		"worst %.2f vs limit %.2f" % [worst_slope, TerrainBuilderScript.MAX_WALKABLE_SLOPE])


# Everything around a plateau except the named access corridor should be
# impassable.
func _probe_plateau_rim(map_def: Dictionary, label: String, center: Vector3,
		he: Vector2, access: Vector3, access_radius: float, margin: float) -> void:
	# Walk the four EDGES of the AABB, offset outward by `margin`.
	#
	# The first version of this swept a bearing around a circle and placed each
	# sample at (he.x + m, he.y + m) scaled by (cos, sin) - which traces an
	# ELLIPSE INSCRIBED IN THE RECTANGLE. Away from the four axis points every
	# sample landed on the plateau TOP, which is flat, so it reported 71% of
	# the rim "walkable" on a plateau whose walls are a 3.6 slope. The probe
	# was wrong, not the terrain.
	var pts: Array = []
	var per_edge := 20
	for i in range(per_edge):
		var t := (float(i) + 0.5) / float(per_edge)
		var ex: float = lerpf(center.x - he.x, center.x + he.x, t)
		var ez: float = lerpf(center.z - he.y, center.z + he.y, t)
		pts.append(Vector3(ex, 0.0, center.z - he.y - margin))
		pts.append(Vector3(ex, 0.0, center.z + he.y + margin))
		pts.append(Vector3(center.x - he.x - margin, 0.0, ez))
		pts.append(Vector3(center.x + he.x + margin, 0.0, ez))

	var walkable_off_ramp := 0
	var total := 0
	for p in pts:
		if Vector2(p.x - access.x, p.z - access.z).length() < access_radius:
			continue  # the ramp corridor is supposed to be walkable
		total += 1
		if TerrainBuilderScript.slope_class_at(map_def, p.x, p.z) != TerrainBuilderScript.SLOPE_IMPASSABLE:
			walkable_off_ramp += 1
	var pct := 100.0 * float(walkable_off_ramp) / maxf(float(total), 1.0)
	print("  %s rim: %d/%d sampled approaches walkable off-ramp (%.0f%%)"
		% [label, walkable_off_ramp, total, pct])
	_check(pct < 12.0, "%s is gated to its ramp" % label, "%.0f%% of rim walkable" % pct)


# Sample a line across the divide at a given z. `expect_blocked` says whether
# there should be impassable ground somewhere in the span.
func _probe_cross_section(map_def: Dictionary, label: String, z: float,
		x0: float, x1: float, expect_blocked: bool) -> void:
	var blocked := 0
	var total := 0
	var samples := 120
	for i in range(samples + 1):
		var x: float = lerpf(x0, x1, float(i) / float(samples))
		total += 1
		if TerrainBuilderScript.slope_class_at(map_def, x, z) == TerrainBuilderScript.SLOPE_IMPASSABLE:
			blocked += 1
	print("  %s: %d/%d samples impassable" % [label, blocked, total])
	if expect_blocked:
		# A wall is narrow by design - depth 26 over an 8 m falloff - so what
		# matters is that an impassable band EXISTS across the line, not what
		# fraction of the span it covers. The first version required a quarter
		# of all samples and failed a canyon that was blocking correctly.
		_check(blocked >= 2, "%s blocks movement" % label, "%d/%d" % [blocked, total])
	else:
		_check(blocked == 0, "%s is clear" % label, "%d/%d impassable" % [blocked, total])


# A crossing that WANTS to go straight through the middle. If the canyon is
# doing its job this has to divert to one of the necks, which is a large,
# measurable detour - unlike a diagonal route that passes a neck anyway.
func _probe_forced_detour(map_def: Dictionary, ground_map: RID) -> void:
	var half: float = float(map_def.get("map_half_extents", 100.0))
	# Endpoints north of BOTH plateaus, so this measures the canyon and only
	# the canyon. At z=0 the straight line also runs into the east plateau,
	# which made the test report a 40 m shortfall that had nothing to do with
	# the divide.
	var a := Vector3(-half * 0.72, 0.0, half * 0.5)
	var b := Vector3(half * 0.72, 0.0, half * 0.5)
	a.y = TerrainBuilderScript.height_at(map_def, a.x, a.z)
	b.y = TerrainBuilderScript.height_at(map_def, b.x, b.z)
	var ca: Vector3 = NavigationServer3D.map_get_closest_point(ground_map, a)
	var cb: Vector3 = NavigationServer3D.map_get_closest_point(ground_map, b)
	var path: PackedVector3Array = NavigationServer3D.map_get_path(ground_map, ca, cb, true)
	var straight := ca.distance_to(cb)
	var walked := 0.0
	for i in range(1, path.size()):
		walked += path[i - 1].distance_to(path[i])
	var gap := 0.0 if path.is_empty() else path[path.size() - 1].distance_to(cb)
	var pct := (walked / maxf(straight, 1.0) - 1.0) * 100.0
	print("  mid-map crossing: straight %.0f m, path %.0f m (%.0f%% longer), ends %.1f m short"
		% [straight, walked, pct, gap])
	_check(gap < 25.0, "mid-map crossing completes", "stops %.0f m short" % gap)
	# NOT a percentage threshold. How big the detour looks depends entirely on
	# how far the necks sit off the straight line relative to its length - on a
	# 1382 m span with necks ~230 m off-centre it is ~8% however well the
	# canyon works, and an earlier >25% assertion was measuring map proportions
	# rather than whether the divide does its job. What matters is that the
	# route is longer than the straight line and is forced through a neck.
	_check(walked > straight, "the crossing costs distance",
		"%.0f m vs %.0f m straight" % [walked, straight])
	var cz := _crossing_z(path)
	_check(cz != INF and absf(absf(cz) - 277.0) < 75.0,
		"mid-map crossing is pushed out to a neck", "crosses at z=%.0f" % cz)


# Where (in z) does a path cross x = 0?
func _crossing_z(path: PackedVector3Array) -> float:
	for i in range(1, path.size()):
		var a := path[i - 1]
		var b := path[i]
		if (a.x < 0.0) != (b.x < 0.0):
			var t: float = absf(a.x) / maxf(absf(a.x) + absf(b.x), 1e-4)
			return lerpf(a.z, b.z, t)
	return INF


func _finish() -> void:
	print("=== %d passed, %d failed ===" % [_pass, _fail])
	quit(0 if _fail == 0 else 1)
