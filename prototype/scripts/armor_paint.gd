# ArmorPaint: armor as PAINTED COVERAGE of a hull's facets, not as modules
# bolted onto it.
#
# No class_name / no `extends` - same convention as hull_facets.gd and
# hull_surface.gd, so this loads in a headless tool or a test with no scene tree
# and no .godot class cache.
#
# WHY THIS REPLACED ARMOR MODULES. A plate used to be a Node3D you dropped on a
# facet, and combat found it by linear-scanning a unit's modules for one whose
# `facet` meta string equalled the six-way side the shot came from, breaking on
# the first match because "a facet only ever has one plate" - an invariant that
# lived in placement-time mirror-skip logic rather than in the data. Coverage
# was therefore binary and per-side, weight was flat per plate regardless of how
# much hull it actually covered, and the per-plate material branch in
# damage_resolver was unreachable because nothing ever wrote one.
#
# THE PLAN is the single object every consumer reads - the stat rail, the
# resolver, the Armor Bay. It is built once at reconstruct time and hung on the
# hull as the `armor_plan` meta, because damage_model already forwards the hull
# node into the resolver and structures pass none at all (their absent plan
# correctly means "bare").
#
# SIDES ARE WEIGHTED, NOT WINNER-TAKE-ALL. See HullFacets.BRUSH_SIDE_MIN_WEIGHT:
# dominant-axis classification left 15 of the 94 shipped hulls with no `front`
# facet whatsoever, because a raked glacis points more up than forward. Every
# per-side number here is therefore weighted by each facet's projected area from
# that direction, which is also the physically honest reading - one sloped plate
# really does stop both frontal and plunging fire.

const HullFacets = preload("res://scripts/hull_facets.gd")
const LiveryScript = preload("res://scripts/livery.gd")

# The paintable armor types: Steel Plate, Ceramic Ablative, Ballistic Nylon, Composite Plate.
const PAINT_TYPE_IDS := [
	"steel_plate", "ceramic_ablative", "ballistic_nylon", "composite_plate",
	"hardened_steel", "reactive_armor", "ablative_ceramic", "carbon_fiber", "titanium_plate",
	"armor_plating", "spaced_composite", "ablative_foam", "slat_armor"
]

const SIDES := ["front", "back", "left", "right", "top", "bottom"]


# --- The plan ---------------------------------------------------------------

# Builds the plan from a list of assignment dictionaries (the blueprint's
# `armor.assignments`) against a hull's facet data.
#
# When `mesh` is provided (the common path), facets are computed live from the
# mesh geometry via HullFacets.cached_segment(). When `mesh` is null (backward
# compat for tests/tools that only have a hull_type string), falls back to the
# baked sidecar.
#
# `xform` is the hull mesh instance's transform, and it matters for two separate
# reasons: a non-uniform hull_scale changes each facet's AREA, and it can also
# rotate a facet's normal far enough to move it between sides - a chine that
# reads as `front` on the authored mesh can read as `top` once the hull is
# stretched. Both are recomputed here from the facet normals rather than by
# re-walking the mesh's hundreds of triangles.
static func build_plan(hull_type_id: String, assignments: Array,
		mesh: Mesh = null,
		xform: Transform3D = Transform3D.IDENTITY, faction: String = "") -> Dictionary:
	var plan := _empty_plan(hull_type_id)

	# Prefer live segment over baked sidecar.
	var seg := {}
	if mesh != null:
		seg = HullFacets.cached_segment(mesh)
	else:
		seg = HullFacets.load_map(hull_type_id)
	if seg.is_empty():
		return plan

	var normals: PackedVector3Array = seg.get("normal", PackedVector3Array())
	var areas: PackedFloat32Array = seg.get("area", PackedFloat32Array())
	var count := int(seg.get("facet_count", seg.get("count", 0)))
	if normals.size() < count or areas.size() < count:
		return plan

	# Normals transform by the inverse transpose, not the basis - a non-uniform
	# scale would otherwise tilt them wrongly and misclassify the sides.
	var basis := xform.basis
	var normal_xf := basis.inverse().transposed()
	var det: float = absf(basis.determinant())

	var world_normal := PackedVector3Array()
	var world_area := PackedFloat32Array()
	world_normal.resize(count)
	world_area.resize(count)
	for f in range(count):
		var raw: Vector3 = normal_xf * normals[f]
		var len_raw := raw.length()
		world_normal[f] = (raw / len_raw) if len_raw > 1e-9 else normals[f]
		# Exact for a planar facet: area scales by |det(S)| * |S^-T n|.
		# Sanity-check with a uniform scale s: det = s^3 and |S^-T n| = 1/s,
		# so the product is s^2, which is what scaling an area by s must give.
		world_area[f] = areas[f] * det * (len_raw if len_raw > 1e-9 else 1.0)

	# Per-side denominators: the projected area of the WHOLE hull as seen from
	# each side, armored or not. Coverage divides by this.
	var side_total := {}
	for s in SIDES:
		side_total[s] = 0.0
	for f in range(count):
		for s in SIDES:
			var w: float = maxf(0.0, world_normal[f].dot(HullFacets.SIDE_AXES[s]))
			side_total[s] = float(side_total[s]) + world_area[f] * w

	# Fold the assignments in.
	var painted := {}
	var total_painted := 0.0
	var total_area := 0.0
	for f in range(count):
		total_area += world_area[f]
	var side_painted := {}
	var side_type_area := {}
	var side_mat_area := {}
	for s in SIDES:
		side_painted[s] = 0.0
		side_type_area[s] = {}
		side_mat_area[s] = {}

	for a in assignments:
		if not (a is Dictionary):
			continue
		var fid := int(a.get("facet_id", -1))
		if fid < 0 or fid >= count:
			continue
		var type_id := str(a.get("type_id", ""))
		if not PAINT_TYPE_IDS.has(type_id):
			continue
		var area: float = world_area[fid]
		var entry := {
			"type_id": type_id,
			"material": str(a.get("material", "hardened_steel")),
			"thickness": float(a.get("thickness", 1.0)),
			"area": area,
		}
		painted[fid] = entry
		total_painted += area
		for s in SIDES:
			var w: float = maxf(0.0, world_normal[fid].dot(HullFacets.SIDE_AXES[s]))
			if w <= 0.0:
				continue
			var wa: float = area * w
			side_painted[s] = float(side_painted[s]) + wa
			var ta: Dictionary = side_type_area[s]
			ta[type_id] = float(ta.get(type_id, 0.0)) + wa
			var ma: Dictionary = side_mat_area[s]
			ma[entry["material"]] = float(ma.get(entry["material"], 0.0)) + wa

	# Per-side summary. `type_id` and `material` are the ones covering the most
	# projected area on that side - a side is allowed to be mixed, and the
	# summary is only ever consulted when the exact facet could not be
	# recovered, so picking the dominant one is the honest single answer.
	var sides := {}
	for s in SIDES:
		var denom := float(side_total[s])
		var cov: float = (float(side_painted[s]) / denom) if denom > 1e-9 else 0.0
		sides[s] = {
			"type_id": _dominant(side_type_area[s]),
			"material": _dominant(side_mat_area[s]),
			"coverage": clampf(cov, 0.0, 1.0),
			"area": float(side_painted[s]),
			"total": denom,
		}

	plan["facets"] = painted
	plan["sides"] = sides
	plan["coverage"] = (total_painted / total_area) if total_area > 1e-9 else 0.0
	plan["area"] = total_painted
	plan["total_area"] = total_area
	plan["empty"] = painted.is_empty()
	plan["faction"] = faction if faction != "" else LiveryScript.NO_LIVERY
	# The triangle-to-facet map lets the resolver look up which facet a hit
	# triangle belongs to, without needing the mesh at resolve time.
	plan["tri_map"] = seg.get("map", PackedInt32Array())
	return plan


static func _empty_plan(hull_type_id: String) -> Dictionary:
	var sides := {}
	for s in SIDES:
		sides[s] = {"type_id": "", "material": "", "coverage": 0.0, "area": 0.0, "total": 0.0}
	return {
		"hull_type": hull_type_id,
		"facets": {},
		"sides": sides,
		"coverage": 0.0,
		"area": 0.0,
		"total_area": 0.0,
		"empty": true,
		"faction": LiveryScript.NO_LIVERY,
	}


static func _dominant(by_area: Dictionary) -> String:
	var best := ""
	var best_a := 0.0
	for k in by_area.keys():
		var v := float(by_area[k])
		if v > best_a:
			best_a = v
			best = str(k)
	return best


# --- Analyzer contract ------------------------------------------------------

# Same shape as Drivetrain.analyze()/WeaponRange.analyze(): guards a null hull
# internally and ALWAYS returns a fully-keyed dictionary, because the stat rail
# reads into it without a validity check of its own. See design_stats.gd's
# header for what breaks otherwise.
static func analyze(hull_node: Node3D = null) -> Dictionary:
	var out := {
		"weight": 0.0,
		"cost_metal": 0,
		"cost_crystal": 0,
		"coverage": 0.0,
		"facet_count": 0,
		"side_coverage": {},
		"weakest_side": "",
		"has_armor": false,
	}
	for s in SIDES:
		out["side_coverage"][s] = 0.0
	if not is_instance_valid(hull_node):
		return out

	var plan: Dictionary = hull_node.get_meta("armor_plan", {})
	if plan.is_empty() or bool(plan.get("empty", true)):
		return out

	# Armor paint carries NO weight or cost - the types are cosmetic likenesses
	# (see PAINT_TYPE_IDS). The keys stay because the stat rail reads them
	# unconditionally; they are always zero now.

	var sides: Dictionary = plan.get("sides", {})
	var weakest := ""
	var weakest_cov := 2.0
	for s in SIDES:
		var cov := float((sides.get(s, {}) as Dictionary).get("coverage", 0.0))
		out["side_coverage"][s] = cov
		if cov < weakest_cov:
			weakest_cov = cov
			weakest = s

	out["weight"] = 0.0
	out["cost_metal"] = 0
	out["cost_crystal"] = 0
	out["coverage"] = float(plan.get("coverage", 0.0))
	out["facet_count"] = (plan.get("facets", {}) as Dictionary).size()
	out["weakest_side"] = weakest
	out["has_armor"] = not (plan.get("facets", {}) as Dictionary).is_empty()
	return out


# --- Brush helpers ----------------------------------------------------------

# The facet ids a side-brush stroke should paints. When a mesh is provided,
# reads the live cached segment; otherwise falls back to the baked sidecar.
static func facets_for_side(hull_type_id: String, side: String,
		mesh: Mesh = null) -> PackedInt32Array:
	if mesh != null:
		return HullFacets.facets_for_side_mesh(mesh, side)
	var out := PackedInt32Array()
	var table := HullFacets.load_map(hull_type_id)
	var sides = table.get("sides", {})
	if not (sides is Dictionary) or not sides.has(side):
		return out
	for v in sides[side]:
		out.append(int(v))
	return out


# The facet a triangle belongs to, or -1. This is the exact-hit path: combat
# hands in the `face_index` from the raycast it already fired.
# When a mesh is provided, uses the live cached segment; otherwise falls back
# to the baked sidecar.
static func facet_for_triangle(hull_type_id: String, tri_index: int,
		mesh: Mesh = null) -> int:
	if tri_index < 0:
		return -1
	if mesh != null:
		return HullFacets.facet_for_tri(mesh, tri_index)
	var table := HullFacets.load_map(hull_type_id)
	if not table.has("map"):
		return -1
	var m: PackedInt32Array = table["map"]
	if tri_index >= m.size():
		return -1
	return m[tri_index]
