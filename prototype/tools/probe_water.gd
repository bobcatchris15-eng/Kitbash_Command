extends SceneTree
# Verifies the water table and painted water bodies.
#
# The thing actually worth testing is the MOUNTAIN LAKE case: a painted body
# must be able to sit ABOVE the map-wide table. The old "paint water" brush
# could not express that at all - it dug the terrain down to a fixed depth so
# the table showed through - so a test that only checked "water appears" would
# have passed on the broken behaviour.
#
#   Godot..._console.exe --headless --path <prototype>
#     --script res://tools/probe_water.gd --quit

const TB = preload("res://scripts/terrain_builder.gd")
const MC = preload("res://scripts/map_catalog.gd")

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
	print("=== water probe ===")

	# --- 1. the table -----------------------------------------------------
	_check(TB.WATER_LEVEL_DEFAULT < 0.0,
		"default water table is below zero", "%.2f m" % TB.WATER_LEVEL_DEFAULT)
	_check(is_equal_approx(TB.water_level_of({}), TB.WATER_LEVEL_DEFAULT),
		"a map with no water_level gets the default")
	_check(is_equal_approx(TB.water_level_of({"water_level": 7.5}), 7.5),
		"a map's own water_level wins", "7.5")

	# The regression this default exists to prevent: terrain that averages
	# zero must NOT be underwater.
	var map_def: Dictionary = MC.get_map("sentinel_divide")
	var half: Vector2 = MC.half_extents(map_def)
	var level: float = TB.water_level_of(map_def)
	var flooded := 0
	var n := 0
	for i in range(48):
		for j in range(48):
			var x: float = lerpf(-half.x, half.x, (float(i) + 0.5) / 48.0)
			var z: float = lerpf(-half.y, half.y, (float(j) + 0.5) / 48.0)
			if TB.height_at(map_def, x, z) < level:
				flooded += 1
			n += 1
	var pct := 100.0 * float(flooded) / float(n)
	print("  sentinel_divide: table at %.1f m, %.1f%% of the map below it" % [level, pct])
	_check(pct < 25.0, "the map is not flooded edge to edge", "%.1f%% underwater" % pct)
	_check(pct > 0.0, "genuine depressions still hold water", "%.1f%%" % pct)

	# --- 2. height encoding ----------------------------------------------
	var worst := 0.0
	for h in [-64.0, -33.3, -2.0, 0.0, 0.25, 12.75, 41.6, 64.0]:
		var e: Vector2 = TB.encode_water_height(h)
		var d: float = TB.decode_water_height(e.x, e.y)
		worst = maxf(worst, absf(d - h))
	_check(worst < 0.01, "16-bit height survives the round trip",
		"worst error %.4f m" % worst)
	# 8 bits would be ~0.5 m here, which visibly misplaces a shoreline.
	_check(worst < 0.05, "encoding is finer than a visible shoreline step")

	# --- 3. a painted mountain lake --------------------------------------
	var res: int = TB.WATER_PAINT_RES
	var img := Image.create(res, res, false, Image.FORMAT_RGBA8)
	img.fill(Color(0.0, 0.0, 0.0, 1.0))
	# A tarn at +18 m, well above the table, in the middle of the raster.
	var lake_level := 18.0
	var enc: Vector2 = TB.encode_water_height(lake_level)
	var c := res / 2
	for py in range(c - 20, c + 20):
		for px in range(c - 20, c + 20):
			img.set_pixel(px, py, Color(1.0, enc.x, enc.y, 1.0))
	var tmp := "user://_probe_water.png"
	img.save_png(tmp)
	var reloaded := Image.load_from_file(ProjectSettings.globalize_path(tmp))
	_check(reloaded != null, "painted raster survives a PNG round trip")
	if reloaded != null:
		var c2: Color = reloaded.get_pixel(c, c)
		var got: float = TB.decode_water_height(c2.g, c2.b)
		_check(absf(got - lake_level) < 0.05,
			"a painted level survives PNG quantisation",
			"wrote %.2f, read %.2f" % [lake_level, got])
		_check(got > TB.water_level_of(map_def) + 10.0,
			"the painted lake sits ABOVE the table (the mountain-tarn case)",
			"lake %.1f m vs table %.1f m" % [got, TB.water_level_of(map_def)])

	# --- 4. schema --------------------------------------------------------
	var probe_def: Dictionary = MC.get_map("sentinel_divide").duplicate(true)
	probe_def["water_level"] = -5.0
	probe_def["water_paint"] = "res://data/maps/sentinel_divide_water.png"
	var errors: Array = MC.validate_map_def(probe_def)
	_check(errors.is_empty(), "water_level and water_paint validate",
		"" if errors.is_empty() else str(errors))

	# --- 5. the map id ----------------------------------------------------
	_check(str(map_def.get("id", "")) == "sentinel_divide",
		"a loaded map carries its own id", str(map_def.get("id", "<empty>")))

	# --- 6. water actually reaches the navmesh ----------------------------
	# Raising the table has to REMOVE ground navmesh and ADD water navmesh.
	# Comparing two water levels on one map isolates the water contribution
	# from everything else the bake does.
	var dry: Dictionary = map_def.duplicate(true)
	dry["water_level"] = -40.0
	var wet: Dictionary = map_def.duplicate(true)
	wet["water_level"] = 6.0

	var g_dry: int = TB._build_ground_faces(dry).size()
	var g_wet: int = TB._build_ground_faces(wet).size()
	print("  ground nav verts: dry %d -> flooded %d" % [g_dry, g_wet])
	_check(g_wet < g_dry, "flooding CARVES the ground navmesh",
		"%d fewer verts" % (g_dry - g_wet))
	_check(g_wet > 0, "dry land is still walkable when flooded", "%d verts" % g_wet)

	var w_dry: int = TB._build_submerged_water_faces(dry).size()
	var w_wet: int = TB._build_submerged_water_faces(wet).size()
	print("  water nav verts:  dry %d -> flooded %d" % [w_dry, w_wet])
	_check(w_wet > w_dry, "flooding ADDS navigable water", "%d more verts" % (w_wet - w_dry))

	# Amphibious must NOT lose anything to water - that is the whole point.
	var a_dry: int = TB._build_amphibious_faces(dry).size()
	var a_wet: int = TB._build_amphibious_faces(wet).size()
	print("  amphibious verts: dry %d -> flooded %d" % [a_dry, a_wet])
	_check(a_wet == a_dry, "amphibious cover is unchanged by water",
		"%d both" % a_wet)

	# ...and it must float, not crawl the bed.
	var deep := TB._build_amphibious_faces(wet)
	var below := 0
	for i in range(deep.size()):
		if deep[i].y < 6.0 - TB.SUBMERGED_MIN_DEPTH - 0.01:
			below += 1
	var sunk := 0
	for i in range(deep.size()):
		var vy: float = deep[i].y
		if vy < 6.0 - 0.01 and TB.height_at(wet, deep[i].x, deep[i].z) < 6.0 - TB.SUBMERGED_MIN_DEPTH:
			sunk += 1
	_check(sunk == 0, "amphibious surface floats ON the water, not on the bed",
		"%d sunk verts" % sunk)

	# --- 7. who crosses water --------------------------------------------
	var UA = load("res://scripts/battle/units/unit_assembly.gd")
	var stub := _StubController.new()
	get_root().add_child(stub)
	for spec in [
			{"label": "flying", "facts": {"is_flying": true}, "expect": "none"},
			{"label": "hovering", "facts": {"is_hovering": true}, "expect": "amphibious"},
			{"label": "amphibious", "facts": {"is_amphibious": true}, "expect": "amphibious"},
			{"label": "plain ground", "facts": {}, "expect": "ground"}]:
		var body := CharacterBody3D.new()
		stub.add_child(body)
		var agent = UA.build_nav_agent(body, spec["facts"], stub)
		var got := "none"
		if agent != null:
			got = stub.label_for(agent.get_navigation_map())
		_check(got == spec["expect"], "%s unit routes to the %s map" % [spec["label"], spec["expect"]], got)
		body.queue_free()

	# hover_engine is the case that was broken: hovering, but not amphibious,
	# so the old amphibious-only test sent it onto the ground map.
	var traits: Array = ModuleCatalog.get_traits("", "hover_engine")
	_check("hovering" in traits and not ("amphibious" in traits),
		"hover_engine is hovering but NOT amphibious (the case that was missed)",
		str(traits))

	print("=== %d passed, %d failed ===" % [_pass, _fail])
	quit(0 if _fail == 0 else 1)


# Minimal stand-in for the match controller: build_nav_agent duck-types the
# four nav-map getters off it, which is what makes this testable at all.
class _StubController extends Node:
	var ground := NavigationServer3D.map_create()
	var water := NavigationServer3D.map_create()
	var amphibious := NavigationServer3D.map_create()
	var deep := NavigationServer3D.map_create()
	func get_ground_nav_map() -> RID: return ground
	func get_water_nav_map() -> RID: return water
	func get_amphibious_nav_map() -> RID: return amphibious
	func get_deep_water_nav_map() -> RID: return deep
	func label_for(m: RID) -> String:
		if m == ground: return "ground"
		if m == water: return "water"
		if m == amphibious: return "amphibious"
		if m == deep: return "deep_water"
		return "unknown"
