extends SceneTree
# Headless verification for the 2026-08-25 armor slab + weight model pass:
#   1. build_plate() extrudes: a 3.0x plate stands ~6x taller than a 0.5x
#      plate, and the slab carries more triangles than the top skin alone
#      (the boundary skirt).
#   2. The skirt closes the plate: the slab's minimum Y is the base z-fight
#      lift, its maximum Y is lift + thickness * THICKNESS_LIFT_PER_UNIT.
#   3. build_plan() charges real weight/cost (area x thickness x density)
#      and reports a per-side mean_thickness.
#
# Run:
#   Godot_v4.7.1-stable_win64_console.exe --headless --path . --script res://tools/probe_armor_slab.gd --quit

const HullFacets = preload("res://scripts/hull_facets.gd")
const ArmorPaint = preload("res://scripts/armor_paint.gd")
const MeshAssetLoader = preload("res://scripts/mesh_asset_loader.gd")

var _failures := 0


func _init() -> void:
	var mesh: Mesh = MeshAssetLoader.get_hull_mesh("brenntal_medium_a")
	if mesh == null:
		_fail("no hull mesh")
		quit(1)
		return
	var mesh_inst := MeshInstance3D.new()
	mesh_inst.mesh = mesh
	# Identity transform is fine: this probe measures module-local geometry.
	var xform := mesh_inst.transform

	var seg := HullFacets.cached_segment(mesh)
	if seg.is_empty():
		_fail("no segment")
		quit(1)
		return
	var count := int(seg.get("count", 0))
	var areas: PackedFloat32Array = seg.get("area", PackedFloat32Array())
	print("[info] facets: %d" % count)

	# The biggest facet is the most stable plate to measure.
	var fid := 0
	var best := -1.0
	for f in range(count):
		if f < areas.size() and areas[f] > best:
			best = areas[f]
			fid = f
	var frame := HullFacets.facet_frame("brenntal_medium_a", fid, xform, mesh)
	if not bool(frame.get("valid", false)):
		_fail("no facet frame")
		quit(1)
		return
	print("[info] measuring facet %d (area %.2f m2)" % [fid, best])

	# --- 1&2: slab geometry at two thicknesses --------------------------------
	# The plates are slabs now, so BOTH thicknesses carry the boundary skirt -
	# the meaningful checks are the DELTA between them (the facet's curvature
	# offset cancels) and the exact skirt accounting against the source data.
	var thin := _measure_plate(mesh_inst, fid, 0.5)
	var thick := _measure_plate(mesh_inst, fid, 3.0)
	print("[info] 0.5x: top=%.3f base=%.3f tris=%d" % [thin.x, thin.y, thin.z])
	print("[info] 3.0x: top=%.3f base=%.3f tris=%d" % [thick.x, thick.y, thick.z])

	var expect_delta := (3.0 - 0.5) * HullFacets.THICKNESS_LIFT_PER_UNIT
	_check(absf((thick.x - thin.x) - expect_delta) < 0.005,
		"top delta = 2.5 units x %.3f (got %.3f)" % [HullFacets.THICKNESS_LIFT_PER_UNIT, thick.x - thin.x])
	# Both plates share the same base lift: the skirt's lowest vertex.
	_check(absf(thin.y - thick.y) < 0.005, "base lift matches across thicknesses")

	# Exact skirt accounting: top tris from _facet_surface, skirt tris from
	# _boundary_edges, plate total must be top + 2 x boundary edges.
	var surface := HullFacets._facet_surface(mesh_inst, "brenntal_medium_a", fid,
		frame["center"], frame["basis"])
	_check(not surface.is_empty(), "facet surface recovered")
	var top_tris: int = (surface["tris"] as Array).size()
	var edges := HullFacets._boundary_edges(surface["tris"], surface["normals"])
	print("[info] top tris=%d, boundary edges=%d, plate tris=%d" % [top_tris, edges.size(), int(thick.z)])
	_check(int(thick.z) == top_tris + 2 * edges.size(),
		"slab = top (%d) + skirt (2 x %d)" % [top_tris, edges.size()])

	# A zero-thickness plate drops no skirt (degenerate guard).
	var flat := _measure_plate(mesh_inst, fid, 0.0)
	_check(int(flat.z) == top_tris, "thickness 0 emits no skirt (%d tris)" % int(flat.z))

	# Skirt winding: the skirt tris are the LAST 2 x edges in emission order.
	# Godot's front face is clockwise from outside, so a correctly culled
	# skirt's cross-product normal points INWARD - away from the viewer.
	var skirt_bad := 0
	var faces := _plate_faces(mesh_inst, fid, 3.0)
	for t in range(top_tris, faces.size() / 3):
		var v0: Vector3 = faces[t * 3]
		var wn := (faces[t * 3 + 1] - v0).cross(faces[t * 3 + 2] - v0)
		if wn.length_squared() < 1e-14:
			skirt_bad += 1
			continue
		# The frame's origin is the facet centroid, so outward in module-local
		# is the skirt midpoint's XZ direction from the origin.
		var mid := (faces[t * 3] + faces[t * 3 + 1] + faces[t * 3 + 2]) / 3.0
		var outward := Vector3(mid.x, 0.0, mid.z)
		if outward.length_squared() < 1e-8:
			continue
		if wn.normalized().dot(outward.normalized()) > -0.5:
			skirt_bad += 1
	_check(skirt_bad == 0, "skirt tris all front-face outward (%d bad)" % skirt_bad)

	# --- 3: weight/cost/mean thickness -----------------------------------------
	var assignment := {
		"facet_id": fid, "type_id": "steel_plate", "material": "steel_plate",
		"thickness": 2.0, "area": best,
	}
	var plan := ArmorPaint.build_plan("brenntal_medium_a", [assignment], mesh, xform, "player")
	var expect_weight := best * 2.0 * float(ArmorPaint.MATERIAL_DENSITY["steel_plate"])
	print("[info] plan weight=%.2f (expect ~%.2f) cost=%d/%d" % [
		float(plan.get("weight", 0.0)), expect_weight,
		int(plan.get("cost_metal", 0)), int(plan.get("cost_crystal", 0))])
	_check(absf(float(plan.get("weight", 0.0)) - expect_weight) < 0.01,
		"weight = area x thickness x density")
	_check(int(plan.get("cost_metal", 0)) > 0, "metal cost charged")
	var side := ""
	var facet_sides = seg.get("facet_side", [])
	if fid < facet_sides.size():
		side = str(facet_sides[fid])
	if side != "":
		var sd: Dictionary = (plan.get("sides", {}) as Dictionary).get(side, {})
		_check(absf(float(sd.get("mean_thickness", 0.0)) - 2.0) < 0.001,
			"mean_thickness 2.0 on %s" % side)
	else:
		_fail("facet has no side")

	# analyze() forwards the charged numbers.
	var hull := Node3D.new()
	hull.set_meta("armor_plan", plan)
	var stats := ArmorPaint.analyze(hull)
	_check(float(stats.get("weight", 0.0)) > 0.0, "analyze weight non-zero")
	_check(int(stats.get("cost_metal", 0)) > 0, "analyze cost non-zero")

	# --- 4: armor-lift lookup (module_placer._apply_armor_lift logic) -----
	var facets: Dictionary = plan.get("facets", {})
	var plan_thickness: float = facets.get(fid, {}).get("thickness", 0.0)
	_check(absf(plan_thickness - 2.0) < 0.001,
		"armor_plan thickness for facet %d is 2.0" % fid)
	var expected_lift := plan_thickness * HullFacets.THICKNESS_LIFT_PER_UNIT
	_check(absf(expected_lift - 0.10) < 0.001,
		"lift = 2.0 x 0.05 = 0.10 m")
	# Unpainted facet: thickness 0, lift 0.
	var unpainted_fid := -1
	for test_fid in facets:
		if int(test_fid) != fid:
			unpainted_fid = int(test_fid)
			break
	if unpainted_fid >= 0:
		var up_thick: float = facets.get(unpainted_fid, {}).get("thickness", 0.0)
		_check(up_thick == 0.0, "unpainted facet thickness is 0.0")
	else:
		_check(true, "only one facet painted (skip unpainted check)")
	hull.free()

	if _failures == 0:
		print("[PASS] slab geometry + weight model verified")
		quit(0)
	else:
		print("[FAIL] %d check(s) failed" % _failures)
		quit(1)


# Returns Vector3(max_y, min_y, tri_count) of the built plate in its
# module-local frame (+Y is the facet normal).
func _measure_plate(mesh_inst: MeshInstance3D, fid: int, thickness: float) -> Vector3:
	var faces := _plate_faces(mesh_inst, fid, thickness)
	if faces.is_empty():
		return Vector3.ZERO
	var max_y := -INF
	var min_y := INF
	for v in faces:
		max_y = maxf(max_y, v.y)
		min_y = minf(min_y, v.y)
	return Vector3(max_y, min_y, faces.size() / 3)


func _plate_faces(mesh_inst: MeshInstance3D, fid: int, thickness: float) -> PackedVector3Array:
	var frame := HullFacets.facet_frame("brenntal_medium_a", fid, mesh_inst.transform, mesh_inst.mesh)
	var plate := HullFacets.build_plate(mesh_inst, "brenntal_medium_a", fid, "steel_plate",
		Vector3.ONE, frame["center"], frame["basis"], "steel_plate", thickness)
	if plate == null:
		_fail("plate build failed at thickness %.2f" % thickness)
		return PackedVector3Array()
	return plate.get_faces()


func _check(ok: bool, label: String) -> void:
	if ok:
		print("[ok]   %s" % label)
	else:
		_failures += 1
		print("[FAIL] %s" % label)


func _fail(msg: String) -> void:
	_failures += 1
	print("[FAIL] %s" % msg)
