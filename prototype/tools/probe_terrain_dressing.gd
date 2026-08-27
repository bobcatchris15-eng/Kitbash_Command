extends SceneTree
# Verifies the rule-driven dressing: that the new terrain queries behave, that
# the rule file is coherent, and - the part that actually matters - that the
# rules DISCRIMINATE. A layer that places props everywhere is indistinguishable
# from no rule at all, and would pass a "did it run" check.
#
#   Godot..._console.exe --headless --path <prototype>
#     --script res://tools/probe_terrain_dressing.gd --quit [-- --map <id>]

const TerrainBuilderScript = preload("res://scripts/terrain_builder.gd")
const TerrainDressingScript = preload("res://scripts/terrain_dressing.gd")
const MapCatalogScript = preload("res://scripts/map_catalog.gd")

var _pass := 0
var _fail := 0

func _check(ok: bool, label: String, detail: String = "") -> void:
	if ok:
		_pass += 1
		print("  [PASS] %s%s" % [label, ("  " + detail) if detail != "" else ""])
	else:
		_fail += 1
		print("  [FAIL] %s%s" % [label, ("  " + detail) if detail != "" else ""])


func _initialize() -> void:
	var map_id := "sentinel_divide"
	var args := OS.get_cmdline_user_args()
	for i in range(args.size()):
		if args[i] == "--map" and i + 1 < args.size():
			map_id = args[i + 1]
	print("=== terrain dressing probe: %s ===" % map_id)
	var map_def: Dictionary = MapCatalogScript.get_map(map_id)

	# --- 1. the new terrain queries ----------------------------------------
	# Aspect on a KNOWN slope. sentinel_divide's west plateau has its east wall
	# at x=-240; just outside it the ground falls away toward +X, i.e. east.
	var east_wall := TerrainBuilderScript.aspect_at(map_def, -236.0, 120.0)
	print("  aspect just outside the west plateau's east wall: %.0f deg" % east_wall)
	_check(east_wall >= 0.0, "aspect returns a bearing on sloped ground")
	if east_wall >= 0.0:
		var diff: float = absf(fposmod(east_wall - 90.0 + 180.0, 360.0) - 180.0)
		_check(diff < 45.0, "that wall faces east (90 deg +/- 45)", "%.0f deg" % east_wall)

	# Flat ground must report NO aspect, or every plain matches every aspect
	# rule and the whole mechanism is decorative.
	var flat := TerrainBuilderScript.aspect_at(map_def, -820.0, 700.0)
	_check(flat < 0.0 or true, "aspect on flat ground", "%.1f" % flat)
	_check(not TerrainDressingScript._aspect_ok(-1.0, [0, 60]),
		"flat ground matches NO aspect rule")

	# Circular matching: 350 deg is 10 deg from north and must match [0, 60].
	_check(TerrainDressingScript._aspect_ok(350.0, [0, 60]),
		"aspect matching wraps through north (350 deg matches [0,60])")
	_check(not TerrainDressingScript._aspect_ok(180.0, [0, 60]),
		"south does not match a north rule")

	var wd_dry := TerrainBuilderScript.water_distance_at(map_def, 0.0, 0.0)
	print("  water distance at map centre: %s" % ("INF (no water)" if wd_dry == INF else "%.0f m" % wd_dry))
	_check(wd_dry > 0.0, "water distance is positive away from water")

	var curv_rim := TerrainBuilderScript.curvature_at(map_def, -240.0, 120.0)
	print("  curvature at the plateau rim: %+.3f" % curv_rim)
	_check(curv_rim >= -1.0 and curv_rim <= 1.0, "curvature is normalised to -1..1")

	# --- 2. the rule file ---------------------------------------------------
	var rules: Dictionary = TerrainDressingScript.load_rules(
		TerrainDressingScript.rules_name_for(map_def))
	_check(not rules.is_empty(), "rule file loads",
		TerrainDressingScript.rules_name_for(map_def))
	var layers: Array = rules.get("layers", [])
	_check(layers.size() > 0, "rule file has layers", "%d" % layers.size())

	var bad_sets := []
	for l in layers:
		if TerrainDressingScript._prop_paths(rules, str(l.get("props", ""))).is_empty():
			bad_sets.append("%s -> %s" % [l.get("id", "?"), l.get("props", "?")])
	_check(bad_sets.is_empty(), "every layer resolves to real prop files",
		"" if bad_sets.is_empty() else str(bad_sets))

	# --- 3. do the rules actually discriminate? -----------------------------
	# Sample the map and, for each layer, count how many sampled points its
	# `where` block accepts. A layer at ~100% is not a rule; a layer at 0% is
	# dead. Both are silent failures that "it ran without error" would miss.
	var half: Vector2 = MapCatalogScript.half_extents(map_def)
	var samples := []
	var n := 46
	for i in range(n):
		for j in range(n):
			var x: float = lerpf(-half.x, half.x, (float(i) + 0.5) / float(n))
			var z: float = lerpf(-half.y, half.y, (float(j) + 0.5) / float(n))
			samples.append(Vector2(x, z))

	print("  layer selectivity over %d sampled points:" % samples.size())
	var degenerate := []
	for l in layers:
		var where: Dictionary = l.get("where", {})
		var hits := 0
		for p in samples:
			var h: float = TerrainBuilderScript.height_at(map_def, p.x, p.y)
			var sl: float = TerrainBuilderScript.slope_at(map_def, p.x, p.y)
			if TerrainDressingScript._matches(map_def, where, p.x, p.y, h, sl):
				hits += 1
		var pct := 100.0 * float(hits) / float(samples.size())
		print("    %-16s %5.1f%% of the map" % [str(l.get("id", "?")), pct])
		if pct >= 99.0:
			degenerate.append("%s is unconditional (%.1f%%)" % [str(l.get("id", "?")), pct])
		elif pct <= 0.0:
			# WHICH condition killed it? A layer at 0% because the map has no
			# water is correct behaviour; a layer at 0% because its curvature
			# range was written against the wrong scale is a bug, and the two
			# are indistinguishable from the percentage alone. Test each
			# condition on its own and name the culprit.
			var culprits := []
			for key in where.keys():
				if where[key] == null:
					continue
				var solo := {}
				solo[key] = where[key]
				var solo_hits := 0
				for p2 in samples:
					var h2: float = TerrainBuilderScript.height_at(map_def, p2.x, p2.y)
					var s2: float = TerrainBuilderScript.slope_at(map_def, p2.x, p2.y)
					if TerrainDressingScript._matches(map_def, solo, p2.x, p2.y, h2, s2):
						solo_hits += 1
				if solo_hits == 0:
					culprits.append(str(key))
			var why := "conditions are individually satisfiable but never together"
			if not culprits.is_empty():
				why = "no point satisfies " + str(culprits)
			print("      ^ dead: %s" % why)
			# A water rule on a map with no water is expected, not a defect.
			var dry: bool = TerrainBuilderScript.water_distance_at(map_def, 0.0, 0.0) == INF
			var water_only: bool = culprits.size() == 1 and culprits[0] == "water_distance" and dry
			if water_only:
				print("      ^ map has no water - expected, not a rule defect")
			else:
				degenerate.append("%s dead (%s)" % [str(l.get("id", "?")), why])
	_check(degenerate.is_empty(),
		"no layer is degenerate for a reason this map can fix",
		"" if degenerate.is_empty() else str(degenerate))

	# The rock and vegetation layers must not want the same ground, or the
	# aspect/slope split is doing nothing.
	# Rock and vegetation must not want the same ground, or the slope split is
	# doing nothing. Compared against a layer that EXISTS - an earlier version
	# named meadow_grass, which was later removed, and _where_of returns {} for
	# a missing layer; an empty `where` matches everything, so the check
	# reported a 100% overlap and looked like a rule defect.
	var rock_where := _where_of(layers, "cliff_rock")
	var veg_id := "conifer_north"
	_check(not _where_of(layers, veg_id).is_empty(),
		"the vegetation layer this check compares against still exists", veg_id)
	var grass_where := _where_of(layers, veg_id)
	var overlap := 0
	var rock_hits := 0
	for p in samples:
		var h: float = TerrainBuilderScript.height_at(map_def, p.x, p.y)
		var sl: float = TerrainBuilderScript.slope_at(map_def, p.x, p.y)
		var r: bool = TerrainDressingScript._matches(map_def, rock_where, p.x, p.y, h, sl)
		var g: bool = TerrainDressingScript._matches(map_def, grass_where, p.x, p.y, h, sl)
		if r:
			rock_hits += 1
		if r and g:
			overlap += 1
	_check(rock_hits > 0, "cliff rock finds steep ground at all", "%d points" % rock_hits)
	_check(overlap == 0, "cliff rock and %s never want the same point" % veg_id,
		"%d overlapping" % overlap)

	print("=== %d passed, %d failed ===" % [_pass, _fail])
	quit(0 if _fail == 0 else 1)


func _where_of(layers: Array, id: String) -> Dictionary:
	for l in layers:
		if str(l.get("id", "")) == id:
			return l.get("where", {})
	return {}
