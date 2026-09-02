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
const ModuleCatalog = preload("res://scripts/module_catalog.gd")
const MeshAssetLoader = preload("res://scripts/mesh_asset_loader.gd")

# The paintable armor types: Steel Plate, Ceramic Ablative, Ballistic Nylon, Composite Plate.
const PAINT_TYPE_IDS := [
	"steel_plate", "ceramic_ablative", "ballistic_nylon", "composite_plate",
	"hardened_steel", "reactive_armor", "ablative_ceramic", "carbon_fiber", "titanium_plate",
	"armor_plating", "spaced_composite", "ablative_foam", "slat_armor"
]

const SIDES := ["front", "back", "left", "right", "top", "bottom"]

# The order a SIDE-KEYED plan (see data/armor/hull_defaults.json) is stamped
# onto facets in. It is not cosmetic: HullFacets' brush sets deliberately
# OVERLAP - a facet joins a side's set at cos 60 degrees, so a raked glacis is
# in `front` AND `top` - so a facet named by two sides in the same plan needs a
# documented winner. Later wins, and `front` is last because a sloped bow plate
# is authored as the bow whatever its normal says. `bottom` is first because it
# is the side a player least means when they also named anything else.
const SIDE_PAINT_PRIORITY := ["bottom", "top", "back", "left", "right", "front"]

# kg per square metre of painted facet per 1.0 thickness. Calibrated against
# the module catalog: a medium hull (brenntal_medium_a) is 496 kg with ~50 m2
# of paintable surface, so full 1.0x steel coverage adds ~100 kg - about a
# mid weapon module - and a full 3.0x turtle build adds ~300 kg, which is a
# real drivetrain trade rather than a free win. Slat is mostly daylight and
# nylon is a fabric; both are deliberately light.
# slat_armor is an ALIAS of steel_plate/hardened_steel/armor_plating in
# ARMOR_TABLE (damage_resolver.gd) - identical threshold/pass_through on every
# damage class, because it always was a literal copy of the same row. It used
# to also carry a lighter density (1.0 vs 2.0) and cheaper cost (0.6 vs 1.0),
# which made it a strict upgrade over steel_plate: same protection, half the
# weight, 60% the cost, no reason to ever pick steel. Equalized here rather
# than given a fake stat split, since the two are the same material by any
# combat measure that exists.
const MATERIAL_DENSITY := {
	"steel_plate": 2.0, "hardened_steel": 2.0, "armor_plating": 2.0,
	"titanium_plate": 1.5, "slat_armor": 2.0,
	"composite_plate": 1.5, "reactive_armor": 1.5, "spaced_composite": 1.5,
	"ceramic_ablative": 1.2, "ablative_ceramic": 1.2, "ablative_foam": 1.0,
	"ballistic_nylon": 0.5, "carbon_fiber": 0.5,
}

# metal/crystal per square metre per 1.0 thickness. Full 1.0x coverage of a
# medium hull lands around 50 metal for steel - meaningful next to the hull's
# 168, not a rounding error. Crystal attaches to the manufactured materials
# (composite, ceramic, nylon weave), not to rolled plate.
const MATERIAL_COST := {
	"steel_plate": Vector2(1.0, 0.0), "hardened_steel": Vector2(1.0, 0.0),
	"armor_plating": Vector2(1.0, 0.0), "titanium_plate": Vector2(1.2, 0.2),
	"slat_armor": Vector2(1.0, 0.0),
	"composite_plate": Vector2(1.4, 0.3), "reactive_armor": Vector2(1.4, 0.3),
	"spaced_composite": Vector2(1.4, 0.3),
	"ceramic_ablative": Vector2(1.2, 0.4), "ablative_ceramic": Vector2(1.2, 0.4),
	"ablative_foam": Vector2(1.0, 0.3),
	"ballistic_nylon": Vector2(0.6, 0.1), "carbon_fiber": Vector2(0.6, 0.1),
}


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
	var total_thick_w := 0.0
	var total_area := 0.0
	for f in range(count):
		total_area += world_area[f]
	var side_painted := {}
	var side_type_area := {}
	var side_mat_area := {}
	var side_thick_w := {}
	for s in SIDES:
		side_painted[s] = 0.0
		side_type_area[s] = {}
		side_mat_area[s] = {}
		side_thick_w[s] = 0.0

	# Weight and cost are real: painted area x thickness, scaled by the
	# material's density and unit cost. They used to be zero ("cosmetic
	# likenesses") which made 3.0x everywhere the free optimum; the plan now
	# carries the bill so drivetrain and design_stats can charge it.
	var weight := 0.0
	var cost := Vector2.ZERO

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
		total_thick_w += area * float(entry["thickness"])
		var thickness := float(entry["thickness"])
		var material := str(entry["material"])
		weight += area * thickness * float(MATERIAL_DENSITY.get(material,
			MATERIAL_DENSITY["hardened_steel"]))
		cost += area * thickness * (MATERIAL_COST.get(material,
			MATERIAL_COST["hardened_steel"]) as Vector2)
		for s in SIDES:
			var w: float = maxf(0.0, world_normal[fid].dot(HullFacets.SIDE_AXES[s]))
			if w <= 0.0:
				continue
			var wa: float = area * w
			side_painted[s] = float(side_painted[s]) + wa
			side_thick_w[s] = float(side_thick_w[s]) + wa * thickness
			var ta: Dictionary = side_type_area[s]
			ta[type_id] = float(ta.get(type_id, 0.0)) + wa
			var ma: Dictionary = side_mat_area[s]
			ma[entry["material"]] = float(ma.get(entry["material"], 0.0)) + wa

	# Per-side summary. `type_id` and `material` are the ones covering the most
	# projected area on that side - a side is allowed to be mixed, and the
	# summary is only ever consulted when the exact facet could not be
	# recovered, so picking the dominant one is the honest single answer.
	# `mean_thickness` is the area-weighted mean over painted facets only.
	var sides := {}
	for s in SIDES:
		var denom := float(side_total[s])
		var cov: float = (float(side_painted[s]) / denom) if denom > 1e-9 else 0.0
		var painted_area := float(side_painted[s])
		sides[s] = {
			"type_id": _dominant(side_type_area[s]),
			"material": _dominant(side_mat_area[s]),
			"coverage": clampf(cov, 0.0, 1.0),
			"area": painted_area,
			"total": denom,
			"mean_thickness": (float(side_thick_w[s]) / painted_area) if painted_area > 1e-9 else 0.0,
		}

	plan["facets"] = painted
	plan["sides"] = sides
	plan["coverage"] = (total_painted / total_area) if total_area > 1e-9 else 0.0
	# Hull-wide area-weighted mean thickness over painted facets only - the AoE
	# path (damage_resolver.gd's `whole` dict) needs a single thickness figure
	# for the same reason _blend_side's per-side one does: a 3.0x-thickness
	# build must not silently resolve as 1.0x just because the hit had no
	# direction to pin to a facet or side.
	plan["mean_thickness"] = (total_thick_w / total_painted) if total_painted > 1e-9 else 0.0
	plan["area"] = total_painted
	plan["total_area"] = total_area
	plan["weight"] = weight
	plan["cost_metal"] = int(round(cost.x))
	plan["cost_crystal"] = int(round(cost.y))
	plan["empty"] = painted.is_empty()
	plan["faction"] = faction if faction != "" else LiveryScript.NO_LIVERY
	# The triangle-to-facet map lets the resolver look up which facet a hit
	# triangle belongs to, without needing the mesh at resolve time.
	plan["tri_map"] = seg.get("map", PackedInt32Array())
	return plan


# Expands a SIDE-KEYED plan into the per-facet assignment array build_plan()
# and the Armor Bay already consume. This is how a hand-authored default plan
# (data/armor/hull_defaults.json, one entry per hull) becomes real paint: the
# author names a side, a material and a thickness, and the six brush sets do
# the geometry.
#
# It emits the SAME row shape the Armor Bay writes, so a pre-filled design is
# indistinguishable from a hand-painted one from here on - the player can
# repaint any facet, undo/redo works, and a Save serialises the resulting
# facets explicitly rather than a reference to the default. That is deliberate:
# a later edit to the defaults file must not be able to reach into a design
# somebody already saved.
#
# `spec` is {side_name: {"material": String, "thickness": float}}. A side that
# is absent is deliberately bare - partial coverage is a real authoring choice
# (a transport with an armored cab and an open bed), not an incomplete entry.
# An unknown material or an out-of-range thickness is skipped with a warning
# rather than substituted, because a silent substitution in balance data reads
# as a working plan while protecting the wrong thing.
static func assignments_from_side_plan(hull_type_id: String, spec: Dictionary,
		mesh: Mesh = null) -> Array:
	if spec.is_empty():
		return []
	var by_facet := {}
	for side in SIDE_PAINT_PRIORITY:
		if not spec.has(side):
			continue
		var row = spec[side]
		if not (row is Dictionary):
			continue
		var material := str((row as Dictionary).get("material", ""))
		if not PAINT_TYPE_IDS.has(material):
			push_warning("ArmorPaint: default plan for '%s' names unpaintable material '%s' on side '%s' - skipped." % [
				hull_type_id, material, side])
			continue
		var thickness := clampf(float((row as Dictionary).get("thickness", 1.0)), 0.5, 3.0)
		for fid in facets_for_side(hull_type_id, side, mesh):
			by_facet[int(fid)] = {
				"facet_id": int(fid),
				"side": side,
				# type_id and material are the same vocabulary here. The Armor
				# Bay writes them as a pair and build_plan() validates type_id
				# against PAINT_TYPE_IDS while charging weight off material, so
				# they must agree or a plan weighs one thing and resolves as
				# another.
				"type_id": material,
				"material": material,
				"thickness": thickness,
			}
	var out := by_facet.keys()
	out.sort()
	var rows := []
	for fid in out:
		rows.append(by_facet[fid])
	return rows


# Full exterior area of a hull's plating, for the drivetrain to charge the
# material/thickness the design declares - compute_hull_weight() scales the
# hull's structural mass by volume and ignores both sliders, so an ablative
# 3.0 hull used to weigh exactly what hardened 1.0 did. Mirrors build_plan's
# per-facet area math (|det(S)| * |S^-T n|) so a scaled hull is charged the
# same factor its painted facets would be. Falls back to the baked sidecar
# total_area when normals are absent, and to a bounding-box area when there
# is no facet bake at all (foundation/procedural hulls).
static func hull_total_area(hull_type_id: String, hull_scale: Vector3 = Vector3.ONE) -> float:
	var seg := HullFacets.load_map(hull_type_id)
	var count := int(seg.get("facet_count", seg.get("count", 0)))
	var normals: PackedVector3Array = seg.get("normal", PackedVector3Array())
	var areas: PackedFloat32Array = seg.get("area", PackedFloat32Array())
	if count <= 0 or normals.size() < count or areas.size() < count:
		# Only the foundation hulls ship a baked facet sidecar; the ship
		# roster resolves facets live off the mesh, exactly as build_plan()
		# does when given one. The mesh path is cached per-RID, so the first
		# call for a hull is the expensive one, same as anywhere else.
		seg = HullFacets.cached_segment(MeshAssetLoader.get_hull_mesh(hull_type_id))
		count = int(seg.get("facet_count", seg.get("count", 0)))
		normals = seg.get("normal", PackedVector3Array())
		areas = seg.get("area", PackedFloat32Array())
	if count <= 0 or normals.size() < count or areas.size() < count:
		# No facet bake and no resolvable mesh (foundation/procedural):
		# fall back to the sidecar box.
		var dims: Variant = ModuleCatalog.get_module_data(hull_type_id).get("size", null)
		if not (dims is Array) or dims.size() < 3:
			return 0.0
		var s := Vector3(float(dims[0]), float(dims[1]), float(dims[2])) * hull_scale
		return 2.0 * (s.x * s.y + s.x * s.z + s.y * s.z)
	var basis := Basis().scaled(hull_scale)
	var normal_xf := basis.inverse().transposed()
	var det: float = absf(basis.determinant())
	var total := 0.0
	for f in range(count):
		var raw: Vector3 = normal_xf * normals[f]
		var len_raw := raw.length()
		total += areas[f] * det * (len_raw if len_raw > 1e-9 else 1.0)
	return total


static func _empty_plan(hull_type_id: String) -> Dictionary:
	var sides := {}
	for s in SIDES:
		sides[s] = {"type_id": "", "material": "", "coverage": 0.0, "area": 0.0,
			"total": 0.0, "mean_thickness": 0.0}
	return {
		"hull_type": hull_type_id,
		"facets": {},
		"sides": sides,
		"coverage": 0.0,
		"mean_thickness": 0.0,
		"area": 0.0,
		"total_area": 0.0,
		"weight": 0.0,
		"cost_metal": 0,
		"cost_crystal": 0,
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

	# Weight and cost are REAL now: painted area x thickness x per-material
	# density / unit cost, computed in build_plan where the world facet areas
	# are known. analyze() only forwards them. Drivetrain adds the weight to
	# the carried load, so a max-thickness turtle pays for it in speed.
	var sides: Dictionary = plan.get("sides", {})
	var weakest := ""
	var weakest_cov := 2.0
	for s in SIDES:
		var cov := float((sides.get(s, {}) as Dictionary).get("coverage", 0.0))
		out["side_coverage"][s] = cov
		if cov < weakest_cov:
			weakest_cov = cov
			weakest = s

	out["weight"] = float(plan.get("weight", 0.0))
	out["cost_metal"] = int(plan.get("cost_metal", 0))
	out["cost_crystal"] = int(plan.get("cost_crystal", 0))
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
