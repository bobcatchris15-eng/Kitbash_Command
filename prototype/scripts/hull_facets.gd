extends RefCounted
class_name HullFacets
# Stable per-hull facet segmentation: which triangles of a hull mesh belong to
# the same FACE, decided once at bake time and looked up at runtime.
#
# WHY THIS IS BAKED AND NOT DERIVED AT PLACEMENT TIME
# ---------------------------------------------------------------------------
# module_placer used to work out "the facet you clicked" live, by flooding out
# from the clicked triangle across coplanar neighbours. Measured across 25 drop
# points on the same face, that is not a function of the FACE - it is a function
# of where the player happened to let go:
#
#   Rackham deck   2.68 x 3.50 .. 2.68 x 3.50   centre wander 0.00m
#   Brenntal deck  2.81 x 2.54 .. 2.81 x 3.46   centre wander 0.47m
#   Brenntal flank 0.51 x 2.54 .. 1.19 x 5.60   centre wander 1.17m
#   Kestrel deck   0.22 x 0.15 .. 3.20 x 5.30   centre wander 2.10m
#
# Boxy hulls were already stable; lofted ones were not, and the Kestrel could
# hand back anything from a postage stamp to the whole hull.
#
# The obvious repair - grow until a hard edge - does not work on this roster,
# and that is a property of the art, not of the algorithm. These hulls are
# SMOOTH LOFTS (see hull_forge.py's cross-section peaks), so there is no crease
# to stop at: on the Brenntal deck a 15-degree tolerance captures 6 triangles
# (2.81 x 0.27 x 2.53) and 30 degrees captures 36 that have already spilled over
# the deck edge and down both sides (3.60 x 1.13 x 4.21). Nothing in between
# means "the deck". Seeding the tolerance from the clicked triangle instead of a
# fixed axis does not help either, because on a curved face the seed's own
# normal moves with the drop point - that variant still left 1.3-5.5m of centre
# wander.
#
# So the segmentation is computed ONCE per hull, offline, where it can afford a
# global greedy partition with a canonical ordering instead of a local flood
# from an arbitrary seed. Runtime then only has to answer "which facet contains
# this triangle", which is a lookup and therefore identical for every drop point
# on that face - drop-independence becomes structural rather than tuned.
#
# Same precedent, and the same reasoning, as the baked convex decomposition in
# tools/bake_hull_roster.gd: derive it from the shipped mesh, store it next to
# the mesh, never make the game pay for it at runtime.

# --- Segmentation tuning ----------------------------------------------------

# Half-angle of the cone a triangle must stay inside to join a facet. Applied
# TWICE, against different references, and both are load-bearing:
#
#   * against the facet's running MEAN normal, which is what lets a facet follow
#     a gentle curve (a tumblehome flank is one face, not fourteen);
#   * against the facet's SEED normal, which is what stops it following that
#     curve all the way round the hull - without it, a chain of individually
#     shallow steps walks the deck facet onto the belly.
#
# TIGHTENED from 25/42 (Chris, 2026-08-17: armor "draping across everything per
# side"). At 42 degrees of seed drift a single facet may span 84 degrees, which
# is most of a quarter turn - so the Brenntal's "front" swallowed its glacis and
# its chin and a plate on the nose wrapped around onto surfaces the player
# thinks of as different faces. The cost of tightening is more facets per hull,
# which is the right trade: a face the player can point at is worth more than a
# face that is cheap to store.
const FACET_CONE_DEG := 14.0

# Still wider than the step cone, because it bounds TOTAL drift rather than
# local smoothness - a face may legitimately curve further overall than any one
# of its triangles does from its neighbour. 20 keeps a tumblehome flank whole
# while refusing to turn a corner.
const FACET_SEED_CONE_DEG := 20.0

# Facets smaller than this fraction of the hull's total surface area are merged
# into the neighbour whose normal is closest. Without it every mast mesa and
# barbette cap authored as a cross-section peak (hull_forge.py) becomes its own
# clickable facet, and a plate dropped on the Kestrel's spine fits the spine -
# which is technically correct and useless.
const MIN_FACET_AREA_FRACTION := 0.015

# Position quantisation for vertex adjacency. mesh_weld.gd's reasoning applies:
# a faceted hull's coincident corners carry different normals, so adjacency has
# to be decided on POSITION alone or nothing is adjacent to anything.
const WELD_QUANTUM := 10000.0

# --- Plate construction tuning ---------------------------------------------

# Corner normals are averaged only across neighbouring facet triangles within
# this angle of each other. It is what keeps a hull's CHAMFERS CRISP: past this
# angle the two sides of an edge keep their own normals, so the armor turns the
# corner instead of rolling over it. Averaging across everything makes a plate
# read as a soft layer laid on top of the hull rather than as part of it.
#
# Comfortably below the 25-degree segmentation cone, so a crease that is sharp
# enough to be visible is still well inside the same facet - this splits
# SHADING and displacement, not the facet itself.
const CREASE_SPLIT_DEG := 12.0

# How far the skin's BASE floats off the hull. This is a z-fighting epsilon
# and NOTHING ELSE - the plate's visible standoff comes from its thickness
# (below), not from this.
const PLATE_LIFT_FRACTION := 0.0025
const PLATE_LIFT_MIN := 0.004

# Real geometric thickness per unit of the Armor Station's brush thickness,
# in metres. 1.0x stands the plate 5cm proud of the hull; the slider's 0.5-3.0x
# range reads as 2.5-15cm. That is a plate, not a block - and because each
# facet extrudes by its OWN thickness, a thickness or type change across a
# facet boundary shows as a real step at the seam, which is the read the
# player uses to see the plan at a glance.
const THICKNESS_LIFT_PER_UNIT := 0.05

const SIDECAR_DIR := "res://assets/models/hulls"
const SIDECAR_KEY := "facets"

# The six canonical sides, and the outward direction each one means. Matches
# ModuleCatalog.classify_facet()'s convention exactly - forward is local -Z.
const SIDE_AXES := {
	"front": Vector3(0, 0, -1), "back": Vector3(0, 0, 1),
	"left": Vector3(-1, 0, 0), "right": Vector3(1, 0, 0),
	"top": Vector3(0, 1, 0), "bottom": Vector3(0, -1, 0),
}

# A facet belongs to a side's BRUSH SET if it faces that side by at least this
# much (cos 60 degrees).
#
# WHY A FACET GETS MORE THAN ONE SIDE. classify_facet() is winner-take-all on
# the dominant axis, which is right for "which way did this shot come from" but
# wrong for "what does the front of this hull consist of". A raked glacis has a
# normal more vertical than horizontal, so dominant-axis files it under `top`
# and the front of the vehicle ends up with NO facets at all. Measured on the
# shipped roster: 15 of 94 hulls had an empty `front` that way - including every
# Kestrel, whose whole identity is a steeply sloped nose - and 16 had some side
# empty. A side-first armor brush cannot work if the most important side is
# unpaintable.
#
# So membership is weighted by max(0, dot(normal, axis)), which is just the
# facet's PROJECTED area as seen from that side. A 50-degree glacis counts ~0.64
# toward the front and ~0.77 toward the top, and is paintable from either - the
# same plate really does stop both frontal and plunging fire, which is the thing
# compute_slope_multiplier() already models on the damage side.
#
# THE THRESHOLD IS LOW ON PURPOSE, and 0.5 was measurably wrong. Coverage for a
# side divides painted projected area by the projected area of the WHOLE hull
# from that direction - so a facet excluded from the brush set still sits in the
# denominator. At 0.5, painting a side covered a mean of 0.85 of it and as
# little as 0.13 (kestrel_medium_b's front): the player clicks a flank, and most
# of that flank stays bare. Measured across all 94 hulls x 6 sides:
#
#   threshold   mean coverage   sides under 70%   mean fraction of hull painted
#     0.50          0.85              101                  0.19
#     0.25          0.92               29                  0.22
#     0.05          0.98                1                  0.28
#     0.001         1.00                0                  0.38
#
# 0.05 is where coverage becomes essentially complete without the brush turning
# greedy - at 0.001 a side brush grabs up to 80% of some hulls, because every
# facet not actively facing away counts. Sides overlapping is expected and
# correct: a chine belongs to the flank AND the deck, and armoring either should
# armor it.
const BRUSH_SIDE_MIN_WEIGHT := 0.05

# hull_type_id -> {"tri_count": int, "map": PackedInt32Array} or {} for "looked
# and there is none". Cached because every mouse-move during a drag asks.
static var _map_cache: Dictionary = {}


# --- Bake side --------------------------------------------------------------

# Partitions `mesh` into facets. Returns {"map": PackedInt32Array (one facet id
# per triangle), "count": int, "tri_count": int}.
#
# Deterministic: triangles are seeded in descending area order with the triangle
# index as tiebreak, so the same mesh always yields the same partition. That is
# the whole point - a segmentation that varied between bakes would reintroduce
# exactly the instability it exists to remove.
static func segment(mesh: Mesh) -> Dictionary:
	var faces := mesh.get_faces()
	var tri_count := faces.size() / 3
	if tri_count <= 0:
		return {"map": PackedInt32Array(), "count": 0, "tri_count": 0}

	var flip := winding_sign(mesh)
	var normals := PackedVector3Array()
	var areas := PackedFloat32Array()
	normals.resize(tri_count)
	areas.resize(tri_count)
	var total_area := 0.0
	for i in range(tri_count):
		var v0 := faces[i * 3]
		var cross := (faces[i * 3 + 1] - v0).cross(faces[i * 3 + 2] - v0)
		var len2 := cross.length_squared()
		if len2 < 1e-16:
			normals[i] = Vector3.ZERO
			areas[i] = 0.0
			continue
		var l := sqrt(len2)
		normals[i] = (cross / l) * flip
		areas[i] = l * 0.5
		total_area += areas[i]

	var adjacency := _build_adjacency(faces, tri_count)

	# Canonical seeding order: biggest triangle first. A large triangle is far
	# more likely to sit in the middle of a real face than a sliver is, so the
	# facet a face ends up with is grown from its own interior rather than from
	# whichever edge triangle happened to come first in the vertex buffer.
	var order := []
	order.resize(tri_count)
	for i in range(tri_count):
		order[i] = i
	order.sort_custom(func(a, b):
		if is_equal_approx(areas[a], areas[b]):
			return a < b
		return areas[a] > areas[b])

	var facet_of := PackedInt32Array()
	facet_of.resize(tri_count)
	facet_of.fill(-1)
	var step_cos := cos(deg_to_rad(FACET_CONE_DEG))
	var seed_cos := cos(deg_to_rad(FACET_SEED_CONE_DEG))
	var facet_count := 0

	for seed in order:
		if facet_of[seed] != -1 or areas[seed] <= 0.0:
			continue
		var id := facet_count
		facet_count += 1
		var seed_n: Vector3 = normals[seed]
		var mean := seed_n * areas[seed]
		var mean_n := seed_n
		facet_of[seed] = id
		var queue := [seed]
		while not queue.is_empty():
			var cur: int = queue.pop_back()
			for nb in adjacency[cur]:
				if facet_of[nb] != -1 or areas[nb] <= 0.0:
					continue
				var nn: Vector3 = normals[nb]
				if nn.dot(mean_n) < step_cos or nn.dot(seed_n) < seed_cos:
					continue
				facet_of[nb] = id
				mean += nn * areas[nb]
				if mean.length_squared() > 1e-12:
					mean_n = mean.normalized()
				queue.append(nb)

	var merged := _merge_small_facets(facet_of, normals, areas, adjacency,
		facet_count, total_area, tri_count)
	var summary := _summarize(faces, merged["map"], normals, areas, merged["count"])
	return {"map": merged["map"], "count": merged["count"], "tri_count": tri_count,
		"winding": flip, "normal": summary["normal"], "centroid": summary["centroid"],
		"area": summary["area"], "total_area": total_area}


# Per-facet outward normal, centroid and area, in the mesh's own (unscaled)
# local space. Everything here is a by-product of sums the segmentation already
# computes and then discards - the alternative is re-walking every triangle at
# spawn time, once per unit, for numbers that cannot change without the mesh
# changing.
#
# Both accumulators are AREA-WEIGHTED. A facet's triangles vary wildly in size
# on a lofted hull, so an unweighted mean lets a fan of slivers at one corner
# outvote the large quads that actually define where the face points and where
# its middle is.
static func _summarize(faces: PackedVector3Array, facet_of: PackedInt32Array,
		normals: PackedVector3Array, areas: PackedFloat32Array,
		count: int) -> Dictionary:
	var f_normal := PackedVector3Array()
	var f_centroid := PackedVector3Array()
	var f_area := PackedFloat32Array()
	f_normal.resize(count)
	f_centroid.resize(count)
	f_area.resize(count)

	for i in range(facet_of.size()):
		var f := facet_of[i]
		if f < 0 or f >= count:
			continue
		var a := areas[i]
		if a <= 0.0:
			continue
		var tri_c := (faces[i * 3] + faces[i * 3 + 1] + faces[i * 3 + 2]) / 3.0
		f_normal[f] += normals[i] * a
		f_centroid[f] += tri_c * a
		f_area[f] += a

	for f in range(count):
		if f_area[f] > 0.0:
			f_centroid[f] = f_centroid[f] / f_area[f]
		f_normal[f] = f_normal[f].normalized() if f_normal[f].length_squared() > 1e-12 else Vector3.UP
	return {"normal": f_normal, "centroid": f_centroid, "area": f_area}


# +1 if the mesh's triangle winding already yields outward normals, -1 if it is
# inverted. Baked rather than recomputed at runtime so a facet's outward
# direction never has to be inferred from the click - see measure().
static func winding_sign(mesh: Mesh) -> float:
	return -1.0 if _signed_volume(mesh.get_faces()) < 0.0 else 1.0


# Rolls facets below MIN_FACET_AREA_FRACTION into the adjacent facet whose mean
# normal is closest, smallest first so a chain of slivers collapses inward
# rather than each one capturing the next. Facet ids are then compacted, so the
# stored map has no holes.
static func _merge_small_facets(facet_of: PackedInt32Array, normals: PackedVector3Array,
		areas: PackedFloat32Array, adjacency: Array, facet_count: int,
		total_area: float, tri_count: int) -> Dictionary:
	if facet_count <= 1 or total_area <= 0.0:
		return {"map": facet_of, "count": facet_count}

	var facet_area := PackedFloat32Array()
	var facet_normal := PackedVector3Array()
	facet_area.resize(facet_count)
	facet_normal.resize(facet_count)
	for i in range(tri_count):
		var f := facet_of[i]
		if f < 0:
			continue
		facet_area[f] += areas[i]
		facet_normal[f] += normals[i] * areas[i]

	var small := []
	for f in range(facet_count):
		if facet_area[f] < total_area * MIN_FACET_AREA_FRACTION:
			small.append(f)
	small.sort_custom(func(a, b): return facet_area[a] < facet_area[b])

	for f in small:
		if facet_area[f] <= 0.0:
			continue
		var my_n: Vector3 = facet_normal[f].normalized() if facet_normal[f].length_squared() > 1e-12 else Vector3.UP
		var best := -1
		var best_dot := -2.0
		for i in range(tri_count):
			if facet_of[i] != f:
				continue
			for nb in adjacency[i]:
				var other := facet_of[nb]
				if other == f or other < 0:
					continue
				var on: Vector3 = facet_normal[other]
				var d: float = my_n.dot(on.normalized()) if on.length_squared() > 1e-12 else -1.0
				if d > best_dot:
					best_dot = d
					best = other
		if best < 0:
			continue
		for i in range(tri_count):
			if facet_of[i] == f:
				facet_of[i] = best
		facet_normal[best] += facet_normal[f]
		facet_area[best] += facet_area[f]
		facet_area[f] = 0.0
		facet_normal[f] = Vector3.ZERO

	# Compact ids so the stored map is 0..n-1 with no gaps.
	var remap := {}
	var next := 0
	for i in range(tri_count):
		var f := facet_of[i]
		if f < 0:
			continue
		if not remap.has(f):
			remap[f] = next
			next += 1
		facet_of[i] = remap[f]
	return {"map": facet_of, "count": next}


static func _signed_volume(faces: PackedVector3Array) -> float:
	# The shipped roster is wound INWARD - measured, only 2/180 (Brenntal),
	# 14/204 (Kestrel) and 24/284 (Orrin) triangles point away from the mesh
	# centroid. That is consistent rather than random, which is what makes a
	# single global sign flip valid and lets everything downstream use a SIGNED
	# normal test. module_placer's old abs() existed because of this and cost it
	# the ability to tell a deck from a belly.
	var vol := 0.0
	for i in range(faces.size() / 3):
		vol += faces[i * 3].cross(faces[i * 3 + 1]).dot(faces[i * 3 + 2]) / 6.0
	return vol


static func _build_adjacency(faces: PackedVector3Array, tri_count: int) -> Array:
	var by_vertex := {}
	for i in range(tri_count):
		for k in range(3):
			var key := _vkey(faces[i * 3 + k])
			if not by_vertex.has(key):
				by_vertex[key] = []
			by_vertex[key].append(i)
	var adjacency := []
	adjacency.resize(tri_count)
	for i in range(tri_count):
		var seen := {}
		for k in range(3):
			for j in by_vertex[_vkey(faces[i * 3 + k])]:
				if j != i:
					seen[j] = true
		adjacency[i] = seen.keys()
	return adjacency


static func _vkey(v: Vector3) -> Vector3i:
	return Vector3i(roundi(v.x * WELD_QUANTUM), roundi(v.y * WELD_QUANTUM), roundi(v.z * WELD_QUANTUM))


# --- Runtime side -----------------------------------------------------------

# Reads a hull's baked facet map, or {} when there is none. Cached per hull type.
static func load_map(hull_type_id: String) -> Dictionary:
	if hull_type_id == "":
		return {}
	if _map_cache.has(hull_type_id):
		return _map_cache[hull_type_id]
	var result := {}
	var path := "%s/%s.json" % [SIDECAR_DIR, hull_type_id]
	if FileAccess.file_exists(path):
		var text := FileAccess.get_file_as_string(path)
		var parsed = JSON.parse_string(text)
		if parsed is Dictionary and parsed.has(SIDECAR_KEY):
			var block = parsed[SIDECAR_KEY]
			if block is Dictionary and block.has("map"):
				var raw = block["map"]
				var ints := PackedInt32Array()
				for v in raw:
					ints.append(int(v))
				result = {
					"tri_count": int(block.get("tri_count", ints.size())),
					"map": ints,
					# Defaulting to +1 keeps a sidecar baked before the winding
					# field existed loading rather than erroring; such a map
					# simply resolves outward the old way for meshes that are
					# already wound outward.
					"winding": float(block.get("winding", 1.0)),
				}
				# Per-facet geometry and the six-side grouping, added for the
				# armor paint model. Every one is OPTIONAL: a sidecar baked
				# before these existed still loads and simply reports no facet
				# summary, which callers treat the same as no map at all.
				result["facet_count"] = int(block.get("facet_count", 0))
				result["normal"] = _to_vec3_array(block.get("facet_normal", []))
				result["centroid"] = _to_vec3_array(block.get("facet_centroid", []))
				result["area"] = _to_float_array(block.get("facet_area", []))
				result["side"] = block.get("facet_side", [])
				result["side_weight"] = block.get("facet_side_weight", [])
				result["sides"] = block.get("sides", {})
				result["side_area"] = block.get("side_area", {})
				result["total_area"] = float(block.get("total_area", 0.0))
	_map_cache[hull_type_id] = result
	return result


static func _to_vec3_array(raw) -> PackedVector3Array:
	var out := PackedVector3Array()
	if not (raw is Array):
		return out
	for v in raw:
		if v is Array and v.size() >= 3:
			out.append(Vector3(float(v[0]), float(v[1]), float(v[2])))
	return out


static func _to_float_array(raw) -> PackedFloat32Array:
	var out := PackedFloat32Array()
	if not (raw is Array):
		return out
	for v in raw:
		out.append(float(v))
	return out


static func clear_cache() -> void:
	_map_cache.clear()


# The facet measurement. Returns the same shape
# module_placer._measure_hull_facet always has - {"size", "center", "outline",
# "valid"} - so callers cannot tell which path produced it, and an empty result
# means "fall back to the live measurement".
#
# Prefers the live cached segment (no bake required) and falls back to the
# baked sidecar for hulls not yet segmented.
#
# `local_pos`/`local_normal` are in HULL-local space, and the mesh instance's
# own transform is applied to the baked triangles here, so hull_scale, the fit
# rotation and any non-uniform stretch are all accounted for. That is also why
# only the SEGMENTATION is baked and never the outline: the outline depends on
# the transform the hull is currently wearing, the segmentation does not.
static func measure(mesh_inst: MeshInstance3D, hull_type_id: String, local_pos: Vector3,
		local_normal: Vector3, module_basis: Basis) -> Dictionary:
	var empty := {"size": Vector3.ZERO, "center": local_pos, "outline": PackedVector2Array(), "valid": false}
	if mesh_inst == null or mesh_inst.mesh == null:
		return empty
	# Prefer the live segment -- no baked sidecar needed.
	var seg := cached_segment(mesh_inst.mesh)
	if seg.is_empty():
		seg = load_map(hull_type_id)
	if seg.is_empty():
		return empty
	var faces := mesh_inst.mesh.get_faces()
	var tri_count := faces.size() / 3
	var map: PackedInt32Array = seg.get("map", PackedInt32Array())
	# GUARD. The map is indexed by triangle, so it is only meaningful against
	# the exact mesh it was baked from. A re-exported or re-imported .glb with a
	# different triangle count must fall back to the live measurement rather
	# than silently assigning plates to whatever facet now holds that index.
	if map.size() != tri_count or tri_count <= 0:
		return empty

	var xform := mesh_inst.transform
	var norm := local_normal.normalized()
	# Seed: the nearest triangle that actually faces the way the ray came from.
	var seed := -1
	var best := INF
	for i in range(tri_count):
		var v0: Vector3 = xform * faces[i * 3]
		var v1: Vector3 = xform * faces[i * 3 + 1]
		var v2: Vector3 = xform * faces[i * 3 + 2]
		var n := (v1 - v0).cross(v2 - v0)
		if n.length_squared() < 1e-12:
			continue
		# Winding is inverted on this roster, so agreement is tested with abs()
		# HERE and only here - picking the triangle under the cursor, where the
		# click normal already tells us which side we are on. The segmentation
		# itself used the global sign and needed no such thing.
		if absf(n.normalized().dot(norm)) < 0.5:
			continue
		var d: float = (((v0 + v1 + v2) / 3.0) - local_pos).length_squared()
		if d < best:
			best = d
			seed = i
	if seed < 0:
		return empty

	var facet_id := map[seed]

	# EVERYTHING BELOW IS DERIVED FROM THE FACET, NOT FROM THE CLICK - which is
	# the half of drop-independence that a stable segmentation alone does not
	# buy. The first version of this still took its tangent frame from
	# `module_basis` (built from the raycast hit normal) and anchored the centre
	# on `local_pos`. Both move with the drop point on a curved face, so the
	# same facet still measured differently from different drops even though the
	# triangle SET was identical - measured, every facet on the Brenntal came
	# back ambiguous. The facet's own mean normal and centroid do not move, so
	# they are what the frame and the anchor are built from now.
	#
	# `module_basis` survives only as the tie-breaker for the frame's in-plane
	# spin, and `local_normal` only to orient the mean normal outward.
	var mean_n := Vector3.ZERO
	var centroid := Vector3.ZERO
	var vert_count := 0
	var tri_verts := PackedVector3Array()
	for i in range(tri_count):
		if map[i] != facet_id:
			continue
		var v0: Vector3 = xform * faces[i * 3]
		var v1: Vector3 = xform * faces[i * 3 + 1]
		var v2: Vector3 = xform * faces[i * 3 + 2]
		# Cross product of the TRANSFORMED edges, so hull_scale and any
		# non-uniform stretch are already in it. Transforming a baked normal
		# instead would need the inverse-transpose and would be wrong here.
		var cr := (v1 - v0).cross(v2 - v0)
		mean_n += cr
		centroid += v0 + v1 + v2
		vert_count += 3
		tri_verts.append(v0)
		tri_verts.append(v1)
		tri_verts.append(v2)
	if vert_count < 3 or mean_n.length_squared() < 1e-12:
		return empty
	centroid /= float(vert_count)
	mean_n = mean_n.normalized()
	# Outward direction comes from the BAKED winding sign, not from the click.
	#
	# Using the click normal to settle the sign looks equivalent and is not: a
	# facet that wraps more than 90 degrees (the Orrin's tumblehome flank, the
	# Kestrel's blended chine) has drop points whose hit normal disagrees with
	# the facet's own mean, so the plate flipped depending on which end of the
	# facet was clicked. Measured, that was the last ambiguity left after the
	# frame and the anchor were made facet-derived. A mesh's winding is a
	# property of the mesh, so it belongs in the bake.
	#
	# `xform` can itself mirror (a negative-determinant hull fit), which flips
	# the handedness of every cross product computed above - so the baked sign
	# is corrected by the transform's determinant rather than trusted raw.
	var det_sign := signf(xform.basis.determinant())
	if det_sign == 0.0:
		det_sign = 1.0
	var outward: float = float(seg.get("winding", 1.0)) * det_sign
	if outward < 0.0:
		mean_n = -mean_n

	var frame := _tangent_frame(mean_n)
	var bx: Vector3 = frame.x
	var bz: Vector3 = frame.z
	var pts := PackedVector2Array()
	var min_x := INF
	var max_x := -INF
	var min_z := INF
	var max_z := -INF
	for v in tri_verts:
		var rel: Vector3 = v - centroid
		var px := rel.dot(bx)
		var pz := rel.dot(bz)
		min_x = minf(min_x, px)
		max_x = maxf(max_x, px)
		min_z = minf(min_z, pz)
		max_z = maxf(max_z, pz)
		pts.append(Vector2(px, pz))
	if pts.size() < 3 or (max_x - min_x) <= 0.1 or (max_z - min_z) <= 0.1:
		return empty

	var mid_x := (min_x + max_x) * 0.5
	var mid_z := (min_z + max_z) * 0.5
	var centred := PackedVector2Array()
	centred.resize(pts.size())
	for i in range(pts.size()):
		centred[i] = Vector2(pts[i].x - mid_x, pts[i].y - mid_z)
	var outline := Geometry2D.convex_hull(centred)
	return {
		"size": Vector3(max_x - min_x, 0.0, max_z - min_z),
		"center": centroid + bx * mid_x + bz * mid_z,
		"outline": outline if outline.size() >= 3 else PackedVector2Array(),
		"normal": mean_n,
		"basis": frame,
		"facet_id": facet_id,
		"valid": true,
	}


# Per-type surface pattern. Not every paintable armor type wants the same
# geometry: plate, composite, foam, and the steel/carbon/titanium *finishes* on
# top of them read as surface treatments on the hull, but slat is a real cage
# and ceramic is a tile with thickness, and the difference is load-bearing.
#
# Each entry now has a `mode`:
#
#   skin  - the existing flat cut-and-lift pipeline. The type shows in how the
#           skin is cut and in the shader's height field; the geometry itself
#           sits 4mm off the hull and has no rim.
#   cage  - emit N thin closed boxes standing off the hull, one per bar. Used
#           by slat armor, where the daylight BETWEEN the bars is the actual
#           protection mechanism - a 2D cut in a flat plane would not read as
#           the same thing. See _cage() for why this is not the failed
#           2026-08-17 cage attempt.
#   skin+lift - the skin path with a per-type `lift_override` (e.g. 10mm for
#           ceramic tiles). Used when the type needs the tile to clearly stand
#           proud of the hull but the surface is still essentially flat - a
#           bigger lift alone reads correctly because the tile top is a
#           uniform plane, so a rim is not required for the read.
#
# The skin fields remain:
#
#   period - pattern repeat in metres along the facet's tangent axes
#   duty   - fraction of each period that is solid (1.0 = no gaps at all)
#   axis   - 0 strips along U, 1 strips along V, 2 a grid in both
#
# The cage fields are:
#
#   bar_thickness - bar width across the U axis in metres. The gap between bars
#                   is (period - bar_thickness); duty is unused in cage mode.
#   bar_height    - how far the bar's top sits above the hull, in metres. The
#                   real-world number is 25-50cm; 0.30 reads correctly at RTS
#                   camera distance and is the lower bound of "obviously a
#                   cage" rather than a thick plate.
#
# The skin+lift field is:
#
#   lift_override - skin's z-fight epsilon is replaced with this absolute lift,
#                   in metres. Used so a ceramic tile clearly reads as a tile
#                   on top of the hull, not as part of its surface.
const SURFACE_PATTERNS := {
	# Plain plate: no cuts. Corner bolts and the like are the authored mesh's
	# business and are deliberately not reproduced here - a solid shell is the
	# honest read for "additional plate".
	"armor_plating": {"period": 0.0, "duty": 1.0, "axis": 0, "mode": "skin"},
	# A cage of bars with real gaps between them. The gaps ARE the module: slat
	# armor works by catching a shaped charge early, and a slat plate with no
	# daylight through it is just plate. Mode "cage" because the daylight must
	# be a 3D gap you can see through, not a 2D cut in a flat plane - the
	# physics of standoff munitions demands the visible standoff, and a
	# 0.25-0.50m gap is what reads as "this stops shaped charges" rather than
	# "this is plate with slots in it".
	"slat_armor": {"period": 0.42, "duty": 0.52, "axis": 0, "mode": "cage",
		"bar_thickness": 0.05, "bar_height": 0.30},
	# Discrete panels with a visible seam between them.
	"spaced_composite": {"period": 0.85, "duty": 0.86, "axis": 2, "mode": "skin"},
	# A fine mosaic - the smallest period here, because tiles only read as
	# tiles when there are many of them. Mode "skin+lift" because ceramic
	# tiles are physically thin plates on the outside of a backing layer;
	# 10mm of lift makes the tile clearly stand proud of the hull without
	# adding a rim or turning it into a 3D block.
	"ablative_foam": {"period": 0.46, "duty": 0.88, "axis": 2, "mode": "skin+lift",
		"lift_override": 0.010},
}


# Public accessor for the SURFACE_PATTERNS dict. Exists so consumers outside
# this file (armor_paint_visual.gd, mainly) can ask "is this type cage or
# skin" without re-declaring the dict or preloading this script in a way
# that would close a preload cycle. The return is a live reference; callers
# that mutate it would be evil, but the const declaration here is the
# language-level signal not to.
static func get_surface_patterns() -> Dictionary:
	return SURFACE_PATTERNS

# Builds the armor plate for a facet, in the MODULE's local frame (X/Z tangent,
# +Y the facet normal, origin at `center`).
#
# THE PLATE IS A SLAB. The facet's own triangles, lifted off the hull by the
# z-fight epsilon PLUS the assignment's real thickness (THICKNESS_LIFT_PER_UNIT
# per 1.0x), with a skirt dropped round the facet's boundary edges back down to
# the base lift. The top still carries the type's pattern cut; there is no
# underside (it would sit inside the hull). Thickness was a shader-only normal
# relief until 2026-08-25, which left 0.5x and 3.0x plates with identical
# silhouettes and no visible seam where plating changed across a facet
# boundary - the skirt IS the seam: a thick plate meeting a thin or bare
# neighbour shows its exposed edge.
#
# SLAT AND CERAMIC ARE DIFFERENT GEOMETRY. The per-type `mode` in SURFACE_PATTERNS picks the
# path:
#
#   * slat_armor uses the cage path (see _cage). The cage is a row of closed
#     boxes standing off the hull by `bar_height` with daylight between them.
#     The daylight IS the protection mechanism: a slat plate with no visible
#     standoff is just plate with slots cut into it, and a shaped charge
#     detonating on the slat's surface has the same focused jet at the hull as
#     a hit on bare armor. The visible 0.30m gap is what reads as "this
#     defeats standoff munitions" and is what makes the design choice honest.
#   * ablative_foam uses the skin path with a per-type `lift_override` (10mm
#     vs 4mm). The tile is still flat; the bigger lift just makes it read as
#     a tile ON the hull rather than a continuation of it. A real rim is not
#     added because the tile top is a uniform plane, so an oblique view that
#     would expose the underside is rare at RTS camera distance.
#
# Three earlier versions are worth naming, because each was rejected for a
# different reason and it would be easy to re-derive any of them:
#
#   * A FLAT extruded polygon. Wrong on curvature - measured, only 3/10 facets
#     on the Brenntal are flat to within 5cm and the worst departs 2.30m, so a
#     flat plate is buried at the centre and floating at the rim.
#   * The type's AUTHORED MESH wrapped onto the surface. Faithful to the art
#     and still wrong: slat_armor's authored form is a full-vehicle cage, so
#     wrapping it produced a bulky block hanging off the face rather than
#     armor on it. The 2026-08-17 cage attempt is THIS failure mode. The
#     current cage is NOT this version: it emits N bars at the bar's own
#     scale (bar_thickness wide, bar_height tall), one per pattern period, so
#     the geometry is the cage's BARS, not a wrapped full-cage mesh. Do not
#     regress to wrapping `slat_armor.glb` here.
#   * A conformed SLAB with real thickness and a rim. Correct in shape, still
#     read as a thick blocky plate sitting on the hull rather than as armor on
#     its surface. This is what the cage's `bar_height` could become if it
#     grew to e.g. 0.5m of solid plate material - keep bar_height in the
#     0.25-0.40m range so the bars stay bars, not thick plates.
#
# CRISP EDGES ARE A PROPERTY OF THE NORMAL FIELD. The skin's lift runs along
# corner normals averaged only across neighbours within CREASE_SPLIT_DEG, so a
# chamfer keeps a distinct normal each side and the skin turns the corner
# instead of rolling over it. The cage does not need this - each bar's
# bottom, top and side faces are flat by construction (set per face in
# _emit_cage_bar), and the bars do not conform to the chamfer anyway, so
# crease-splitting would only soften the bar's edges.
# MATERIAL RELIEF: the surface treatment that tells two materials apart.
#
# Colour cannot carry this. The player's livery repaints the whole vehicle, so
# an armor material identified by its tint is identified by nothing the moment
# anyone picks a different scheme. Relief survives livery, survives the faction
# shader, and reads at gameplay camera distance because it catches light.
#
# `cell` is the tile size in metres, `height` how far a tile stands proud (scaled
# by the facet's thickness), `stagger` offsets alternate rows like brickwork.
# Tiles are CUT, not displaced per-vertex: a facet can be two big triangles, so
# vertex displacement would have nothing to displace. Clipping into cells and
# lifting each cell as a unit gives flat tops and crisp steps at any facet size,
# reusing the same Sutherland-Hodgman clip the slat pattern already uses.
const MATERIAL_RELIEF := {
	# ALL ZERO, AND THAT IS THE ANSWER, not a stub.
	#
	# This cut real tiles into the skin and raised them. It worked exactly as
	# specified - triangle counts scaled with cell size, 57 flat vs 395 reactive
	# vs 2309 carbon - and rendered INVISIBLE. Only the tile TOPS were emitted,
	# so the result was a set of parallel quads at slightly different heights
	# with no vertical face anywhere for light to hit. A step you cannot see is
	# not a step. Emitting skirts round every tile would have fixed it and
	# multiplied the triangle count on something that rides on every unit in a
	# skirmish.
	#
	# The signature moved into the shader instead (shaders/armor_surface.gdshader),
	# where it costs no geometry and cannot have this failure mode. The machinery
	# below is kept because a per-material height field is still the right hook
	# if a material ever needs a genuine silhouette change rather than a surface
	# one - set a cell and a height and it comes back.
	"hardened_steel": {"cell": 0.0, "height": 0.0, "stagger": false},
	"reactive_armor": {"cell": 0.0, "height": 0.0, "stagger": true},
	"ablative_ceramic": {"cell": 0.0, "height": 0.0, "stagger": false},
	"carbon_fiber": {"cell": 0.0, "height": 0.0, "stagger": true},
	"titanium_plate": {"cell": 0.0, "height": 0.0, "stagger": false},
}


static func build_plate(mesh_inst: MeshInstance3D, hull_type_id: String, facet_id: int,
		type_id: String, cat_size: Vector3, center: Vector3, frame: Basis,
		material_id: String = "hardened_steel", thickness: float = 1.0) -> ArrayMesh:
	if mesh_inst == null or mesh_inst.mesh == null:
		return null
	var surface := _facet_surface(mesh_inst, hull_type_id, facet_id, center, frame)
	if surface.is_empty():
		return null
	var pattern: Dictionary = SURFACE_PATTERNS.get(type_id,
		{"period": 0.0, "duty": 1.0, "axis": 0, "mode": "skin"})
	var mode: String = str(pattern.get("mode", "skin"))
	# Cage mode skips the lift / relief / shader-height pipeline entirely -
	# the bars carry the visual structure themselves, and applying the skin's
	# z-fight lift to their bases is correct, but their height comes from
	# `bar_height`, not from any relief or per-material offset.
	if mode == "cage":
		return _cage(surface, pattern, thickness)
	var bounds: Rect2 = surface["bounds"]
	# Scaled to the facet so it stays invisible on a 2m scout panel and on a 12m
	# airship flank alike, with an absolute floor for tiny facets. Same reasoning
	# (and the same order of magnitude) as HullProjection's decal offset.
	# A per-type `lift_override` (e.g. 10mm for ceramic tiles) is a FLOOR, not
	# an exact value: the type sits at LEAST this far above the hull, but on
	# a large facet the bounds-scaled lift may already be higher (z-fight
	# epsilon scales with the facet), in which case we keep that instead of
	# letting the ceramic end up BELOW the skin it is supposed to be sitting
	# ON TOP of. The order is: bounds-scaled z-fight epsilon, then floor by
	# the type's minimum visible offset, then capped by nothing - the type's
	# value is the "this far is the minimum read" line, not "this far is the
	# exact offset".
	var lift: float = maxf(bounds.size.length() * PLATE_LIFT_FRACTION, PLATE_LIFT_MIN)
	if pattern.has("lift_override"):
		lift = maxf(lift, float(pattern["lift_override"]))
	var relief: Dictionary = MATERIAL_RELIEF.get(material_id, MATERIAL_RELIEF["hardened_steel"])
	return _skin(surface, lift, pattern, relief, thickness)


# The cage: a row of closed rectangular prisms, one per period, where each
# bar's footprint is the HULL's surface clipped to the bar's U range
# (Sutherland-Hodgman against the bar's two parallel U planes - the same
# _clip_slab the skin pattern uses) and extruded vertically by `bar_height`.
#
# Slat armor is a real 3D cage, not a 2D pattern with slots cut into it - the
# daylight between the bars is the entire protection mechanism, and a slat
# plate with no visible standoff is just plate. The 2026-08-17 attempt to wrap
# slat_armor.glb onto a facet failed because the WHOLE CAGE was wrapped, at
# vehicle scale, as a single bulky block. The 2026-08-19 attempt to use the
# full facet's V range per bar failed for the OPPOSITE reason: a bar at one
# U position ran the full V length of the facet, so on any non-rectangular
# facet (a tumblehome flank, a chamfered nose) the bar projected past the
# hull's actual edge in world space - the V tangent in module-local space
# points at an angle, and the full V range sits outside the hull's surface
# at most U positions. The current version uses the V range of the
# triangles that overlap the bar's U range, computed per bar.
#
# WHY A CLOSED RECTANGULAR PRISM, NOT A LOFTED CURTAIN. The curtain-walls
# version (one wall quad per polyline segment of the cut surface) produced
# a chaotic zigzag of triangles at very different angles - the polyline
# segments came from individual facet triangles that were at slightly
# different angles even within one facet. A real slat bar is a clean
# rectangular prism, and the cage reads as a cage because the bars have
# flat tops and flat sides.
#
# WHY A STRAIGHT BOX, NOT A LOFTED TOP. Earlier versions (2026-08-17)
# lifted the bar by the facet's max |Y| (its curvature) so the bar's
# bottom sat at or above the highest point of the hull's surface in
# the facet, the way the hull's surface "grew out of" the bar. On a
# curved facet that produced visibly FLOATING bars - measured ~0.5m
# above the hull's mean plane on the Brenntal's tumblehome, which the
# user described as "a separate object hovering in front of the hull,
# not as armor on it". The user accepted the bar's bottom clipping
# into the hull at curvature peaks ("they would be attached there"),
# so the current version drops the curvature lift and uses the
# z-fight epsilon only. The bar's bottom is a few cm above the hull's
# mean plane; the hull's surface can push up through the bar's bottom
# at curvature peaks and that is the intended "growing out of" read,
# not a bug. The cage's visual structure (a row of solid bars standing
# off the hull) is unchanged.
#
# Triangle cost is 12 triangles per bar (6 faces, 2 triangles each) - a
# clean closed box. A 2m × 2m facet at 0.42m period is ~5 bars = 60
# triangles, comparable to the rejected curtain-walls path. The bars
# share no vertex with the hull and have no CollisionObject3D parent, so
# the hull's collision shape is unaffected.
static func _cage(surface: Dictionary, pattern: Dictionary, thickness: float = 1.0) -> ArrayMesh:
	var bounds: Rect2 = surface["bounds"]
	var period: float = float(pattern.get("period", 0.42))
	# Default `bar_thickness` to the legacy `period * duty` so a row that
	# only knew duty still gets something sensible. With explicit
	# bar_thickness, duty is unused in cage mode - the gap is (period - thickness).
	var bar_thickness: float = float(pattern.get("bar_thickness",
		period * float(pattern.get("duty", 0.5))))
	var bar_height: float = float(pattern.get("bar_height", 0.30))
	if period <= 0.0 or bar_thickness <= 0.0 or bar_height <= 0.0:
		return null

	# Z-fight lift on the bar's bottom: same 4mm the skin uses, so the cut
	# surface's bottom doesn't fuse with the hull at the lift's Y level.
	# The bar_height is the additional standoff above that - 0.30m is the
	# lower bound of "obviously a cage" rather than a thick plate.
	#
	# On a curved hull, the bar (a flat-topped box) needs an additional
	# lift equal to the facet's max curvature: the bar sits at the facet's
	# mean plane in module-local space, and a flat-bottomed box would
	# otherwise sink below the hull at the curvature peaks. The user is
	# OK with the bar's bottom "growing out of" the hull, but it should
	# not disappear into the hull at the high points.
	var tris: Array = surface["tris"]
	var normals: Array = surface["normals"]
	var u_lo: float = bounds.position.x
	var u_hi: float = bounds.position.x + bounds.size.x
	# The bar's V range is NOT the full facet's V range. Each bar gets the
	# V range of the hull's surface in its OWN U slice, computed by
	# clipping the facet's triangles to the bar's U range (see _bar_v_range
	# below). On a rectangular facet where every triangle spans the full
	# V range, every bar gets the full V range anyway; on a tumblehome
	# flank or any facet where the V extent varies along U, each bar gets
	# a V range that matches the hull's surface at that U position, so no
	# bar projects past the hull's actual edge in world space.
	#
	# Lift is the z-fight epsilon ONLY - no curvature compensation. The
	# earlier `max(bounds_scaled_lift, max_curvature)` formula lifted the
	# bar by the facet's highest |Y| of any triangle, so on a curved
	# facet the bars floated visibly above the hull (measured: ~0.5m on
	# the Brenntal's tumblehome, the bars read as a separate object
	# hovering in front of the hull, not as armor on it). The user
	# accepted the bar's bottom clipping into the hull at curvature
	# peaks ("they would be attached there"), so the right answer is to
	# drop the curvature lift and let the bar sit at the hull's mean
	# plane with the bar's bottom a few cm above the lowest point of the
	# hull's surface. The hull's curvature at the bar's U slice can
	# still push the hull's surface up through the bar's bottom - that
	# is the intended "growing out of" read, not a bug.
	var lift: float = maxf(bounds.size.length() * PLATE_LIFT_FRACTION,
		PLATE_LIFT_MIN)
	var y_top: float = lift + bar_height

	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var emitted := 0
	# Walk the bar positions left to right along U. A bar that runs past the
	# facet's U extent is clipped to it, so a partial leading/trailing bar is
	# possible but never a bar that overshoots into the next facet.
	var u_pos: float = u_lo
	while u_pos < u_hi:
		var bar_u_lo: float = u_pos
		var bar_u_hi: float = minf(u_pos + bar_thickness, u_hi)
		if bar_u_hi > bar_u_lo + 1e-4:
			var v_extent := _bar_v_range(tris, bar_u_lo, bar_u_hi)
			if v_extent.y > v_extent.x + 1e-4:
				emitted += _emit_cage_bar(st, bar_u_lo, bar_u_hi,
					v_extent.x, v_extent.y, lift, y_top)
		u_pos += period
	if emitted == 0:
		return null
	# Normals were set per face inside _emit_cage_bar; tangents are unnecessary
	# for the cage's StandardMaterial3D (no normal map, no shader UVs).
	return st.commit()


# V range of the hull's surface clipped to a bar's U range.
#
# Why this exists: a bar that runs the FULL facet's V range projects past
# the hull's actual edge on any non-rectangular facet. The module-local
# V tangent points at an angle in world space, so a V range covering the
# whole facet sits outside the hull's surface at most U positions. The
# fix is to ask "where does the hull's surface actually exist in this
# bar's U slice?" and use THAT V range.
#
# Done per bar, not once, because each bar has a different U position
# and a different V range as a result. A bar near the U end has a V
# range biased toward that end; a bar across the middle has the V
# range of the triangles that span the middle.
#
# The clip is Sutherland-Hodgman against the bar's two parallel U
# planes (the same _clip_slab the skin pattern uses), reusing the
# existing infrastructure rather than introducing a new shape math.
# Triangles entirely outside the bar's U range are quick-rejected by
# their bounding U; triangles that overlap are clipped to the bar's
# U range and their surviving polygon's V extent contributes to the
# bar's V range.
static func _bar_v_range(tris: Array, bar_u_lo: float, bar_u_hi: float) -> Vector2:
	var v_lo: float = INF
	var v_hi: float = -INF
	for tri in tris:
		# Quick reject: triangle entirely outside the bar's U range.
		# Computing the triangle's U range is 3 minf/maxf calls on
		# already-loaded vertices, much cheaper than building a poly
		# and running _clip_slab for nothing.
		var tri_u_lo: float = minf(tri[0].x, minf(tri[1].x, tri[2].x))
		var tri_u_hi: float = maxf(tri[0].x, maxf(tri[1].x, tri[2].x))
		if tri_u_hi < bar_u_lo or tri_u_lo > bar_u_hi:
			continue
		# Clip the triangle to the bar's U range and aggregate the
		# surviving polygon's V extent. Triangles with fewer than 3
		# surviving vertices contribute nothing (a line or a point
		# has no V extent).
		var poly := []
		for v in tri:
			poly.append({"p": v, "n": Vector3.UP})
		var clipped: Array = _clip_slab(poly, 0, bar_u_lo, bar_u_hi)
		if clipped.size() < 3:
			continue
		for v in clipped:
			var vz: float = (v["p"] as Vector3).z
			if vz < v_lo: v_lo = vz
			if vz > v_hi: v_hi = vz
	return Vector2(v_lo, v_hi)


# Build one cage bar as a single closed rectangular prism.
#
# The bar's footprint is a rectangle (U_lo..U_hi) × (V_lo..V_hi) in
# module-local space, and the bar's height is `bar_height` along the
# facet normal (Y). Six faces, twelve triangles, thirty-six vertices
# per bar, identical triangle count for every bar in the cage (which
# is what makes the test count and visual rhythm predictable).
#
# A REAL SLAT BAR IS A CLEAN RECTANGULAR PRISM, not a stitched-together
# curtain. The previous "curtain walls" version emitted one quad per
# polyline segment of the hull's surface, and the segments came from
# individual triangles of the facet at very different angles. The
# result was a chaotic zigzag of triangles pointing in every direction
# - which is what the screenshot showed, and is what the user described
# as the lateral surfaces inside the slat. Real slat bars are flat-
# topped, flat-walled, and read as a single shape.
#
# The hull's curvature is NOT followed exactly here: the bar sits at
# the mean Y of the cut surface (which is the facet's plane in
# module-local), with the hull's surface curving around it. The
# caller lifts the bar by `max(bounds_scaled_lift, max_curvature)` so
# the bar's bottom is always at or above the highest point of the
# hull's surface on this facet - the bar never pokes through at a
# curvature peak.
static func _emit_cage_bar(st: SurfaceTool,
		u_lo: float, u_hi: float, v_lo: float, v_hi: float,
		lift: float, y_top: float) -> int:
	# Eight corners of the bar, named by (U_bit, Y_bit, V_bit).
	var p000 := Vector3(u_lo, lift, v_lo)
	var p100 := Vector3(u_hi, lift, v_lo)
	var p010 := Vector3(u_lo, y_top, v_lo)
	var p110 := Vector3(u_hi, y_top, v_lo)
	var p001 := Vector3(u_lo, lift, v_hi)
	var p101 := Vector3(u_hi, lift, v_hi)
	var p011 := Vector3(u_lo, y_top, v_hi)
	var p111 := Vector3(u_hi, y_top, v_hi)
	var emitted := 0
	# Six faces, each listed as a quad in CCW-from-outside corner order.
	# _emit_cage_quad reverses that when it writes the triangles, because
	# Godot's front face is CLOCKWISE - see the note on that function.
	#
	# GODOT 4 VECTOR3 CONSTANTS: Vector3.FORWARD = (0, 0, -1) and
	# Vector3.BACK = (0, 0, +1). A previous version of this code wrote
	# `Vector3.FORWARD` for the +Z face and `Vector3.BACK` for the -Z
	# face, which is REVERSED: the WINDINGS were correct (CCW from the
	# outside) so back-face culling was fine, but the stored normals
	# pointed the wrong way and the bar's V-end faces rendered as
	# unlit black under a default sun-direction light, which read as
	# "I can see through the bar to its dark interior". The +Z face
	# uses Vector3.BACK and the -Z face uses Vector3.FORWARD, matching
	# the actual face directions.
	# +Y top: corners in CCW order looking down from +Y are p010, p011, p111, p110.
	emitted += _emit_cage_quad(st, p010, p011, p111, p110, Vector3.UP)
	# -Y bottom: CCW from below (looking up at the -Y face) is p000, p100, p101, p001.
	emitted += _emit_cage_quad(st, p000, p100, p101, p001, Vector3.DOWN)
	# +X right: CCW from +X (looking at the right side) is p100, p110, p111, p101.
	emitted += _emit_cage_quad(st, p100, p110, p111, p101, Vector3.RIGHT)
	# -X left: CCW from -X (looking at the left side) is p001, p011, p010, p000.
	emitted += _emit_cage_quad(st, p001, p011, p010, p000, Vector3.LEFT)
	# +Z front (the V_hi end of the bar): CCW from +Z is p001, p101, p111, p011.
	# Normal is (0, 0, +1) = Vector3.BACK. See the GODOT 4 VECTOR3 CONSTANTS
	# note above.
	emitted += _emit_cage_quad(st, p001, p101, p111, p011, Vector3.BACK)
	# -Z back (the V_lo end of the bar): CCW from -Z is p000, p010, p110, p100.
	# Normal is (0, 0, -1) = Vector3.FORWARD. See the GODOT 4 VECTOR3 CONSTANTS
	# note above.
	emitted += _emit_cage_quad(st, p000, p010, p110, p100, Vector3.FORWARD)
	return emitted


# Emit a single quad as 2 triangles with the given normal. The 4 vertices
# a, b, c, d are given in CCW order from outside (looking back along the
# normal), which is how the caller lists them because that is how the
# corners of a box read on paper.
#
# GODOT'S FRONT FACE IS CLOCKWISE, so this emits them REVERSED. Verified
# against Godot 4.7.1's own BoxMesh: for all 12 of its triangles,
# (b - a).cross(c - a) points AGAINST the stored normal, i.e. a correctly
# facing Godot triangle is wound clockwise as seen from outside. The
# earlier version added the corners in the listed CCW order, so every one
# of the cage's six faces was back-facing: back-face culling removed the
# near wall of each bar and left the far wall's interior visible, which
# is the "I can see straight through the slat to its opposite face"
# report. Note that the stored normals were and are correct - only the
# winding was inverted, which is why lighting looked plausible and the
# bug read as transparency rather than as inside-out geometry.
#
# Reversing here rather than at the six call sites keeps the readable
# CCW corner lists (p010, p011, p111, p110 ... ) intact and means there
# is exactly one place that knows about the winding convention.
static func _emit_cage_quad(st: SurfaceTool, a: Vector3, b: Vector3, c: Vector3, d: Vector3,
		n: Vector3) -> int:
	for v in [c, b, a, d, c, a]:
		st.set_normal(n)
		st.add_vertex(v)
	return 6


# The skin, now a SLAB: the facet's triangles lifted by `lift` + the plate's
# real thickness, cut by the pattern, with a skirt round the facet's boundary
# edges closing the plate's side back down to the base lift. No underside - it
# would sit inside the hull and never render.
#
# THE SKIRT IS THE SEAM. Every painted facet extrudes by its own thickness and
# drops a skirt at its boundary, so the player reads the plan as geometry: a
# 3.0x composite facet beside a 1.0x steel facet shows a step; any plate
# beside bare hull shows a welded edge. Two adjacent plates each drop their
# own skirt along the shared boundary, and because their crease-split corner
# normals differ across the facet break (segmentation guarantees the break is
# a real angle - see FACET_CONE_DEG), the two skirts are never coplanar, so
# they do not z-fight.
#
# Boundary edges come from the facet's ORIGINAL triangles (an edge used by
# exactly one triangle), not from the cut pieces, so pattern-cut interior
# edges keep their flat shader seam and only the plate's outline gets a side.
#
# THE CUT IS AN ANALYTIC CLIP, NOT A DROPPED SUBDIVISION. The first version
# subdivided each facet triangle and discarded cells whose centre fell in a gap.
# Rendered, that produced a TRIANGULAR SAWTOOTH rather than bars: cell edges run
# along the subdivision, not along the pattern, so no cell boundary is ever a
# straight line across the facet. Clipping each triangle against the band's two
# parallel planes puts the cut exactly where the pattern says it is, at any
# facet size, with no subdivision to resolve.
static func _skin(surface: Dictionary, lift: float, pattern: Dictionary,
		relief: Dictionary = {}, thickness: float = 1.0) -> ArrayMesh:
	var tris: Array = surface["tris"]
	var normals: Array = surface["normals"]
	var bounds: Rect2 = surface["bounds"]
	var period := float(pattern.get("period", 0.0))
	var duty := float(pattern.get("duty", 1.0))
	var axis := int(pattern.get("axis", 0))
	var solid: bool = period <= 0.0 or duty >= 0.999

	# The top sits at the z-fight epsilon PLUS the real plate thickness. All
	# four Armor Station types are solid skins, so every painted facet pays
	# this; cut-pattern legacy types lift the same way and keep flat cut edges.
	var top_lift: float = lift + maxf(0.0, thickness) * THICKNESS_LIFT_PER_UNIT
	var skirt_edges := _boundary_edges(tris, normals)

	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var emitted := 0
	for t in range(tris.size()):
		var poly := []
		for k in range(3):
			poly.append({"p": tris[t][k], "n": normals[t][k]})
		if solid:
			emitted += _emit_relief(st, poly, top_lift, bounds, relief, thickness)
			continue
		var pieces := [poly]
		# Component 0 is the facet's U tangent, 2 its V tangent - the same axes
		# the pattern period is quoted in metres along.
		if axis == 0 or axis == 2:
			pieces = _cut_bands(pieces, 0, period, duty)
		if axis == 1 or axis == 2:
			pieces = _cut_bands(pieces, 2, period, duty)
		for pc in pieces:
			emitted += _emit_relief(st, pc, top_lift, bounds, relief, thickness)
	for e in skirt_edges:
		emitted += _emit_skirt(st, e[0], e[1], e[2], e[3], lift, top_lift, bounds)
	if emitted == 0:
		return null
	# NO generate_normals(): every vertex above carries an explicit normal (the
	# top uses the crease-split corner field, the skirt its outward face
	# normal), and generate_normals would overwrite them with position-smoothed
	# ones, rounding the plate's rim into the skirt. generate_tangents() still
	# needs the normals and UVs we set; the armor shader's normal mapping does.
	st.generate_tangents()
	return st.commit()


# Clips every polygon to the SOLID part of each band it overlaps along `comp`,
# returning the surviving pieces. A band is [k*period, k*period + duty*period];
# the remainder of the period is the gap.
static func _cut_bands(pieces: Array, comp: int, period: float, duty: float) -> Array:
	var out := []
	var solid_width := period * duty
	for poly in pieces:
		if (poly as Array).size() < 3:
			continue
		var lo := INF
		var hi := -INF
		for v in poly:
			var c: float = (v["p"] as Vector3)[comp]
			lo = minf(lo, c)
			hi = maxf(hi, c)
		var first := int(floor(lo / period))
		var last := int(floor(hi / period))
		for k in range(first, last + 1):
			var band_lo := float(k) * period
			var clipped := _clip_slab(poly, comp, band_lo, band_lo + solid_width)
			if clipped.size() >= 3:
				out.append(clipped)
	return out


# Sutherland-Hodgman against the two parallel planes of a slab, interpolating
# the corner normal along with the position so the lift stays continuous across
# a cut edge.
static func _clip_slab(poly: Array, comp: int, lo: float, hi: float) -> Array:
	var a := _clip_half(poly, comp, lo, true)
	if a.size() < 3:
		return []
	return _clip_half(a, comp, hi, false)


static func _clip_half(poly: Array, comp: int, limit: float, keep_greater: bool) -> Array:
	var out := []
	var n := poly.size()
	for i in range(n):
		var cur: Dictionary = poly[i]
		var nxt: Dictionary = poly[(i + 1) % n]
		var cv: float = (cur["p"] as Vector3)[comp]
		var nv: float = (nxt["p"] as Vector3)[comp]
		var cur_in: bool = (cv >= limit) if keep_greater else (cv <= limit)
		var nxt_in: bool = (nv >= limit) if keep_greater else (nv <= limit)
		if cur_in:
			out.append(cur)
		if cur_in != nxt_in:
			var denom := nv - cv
			if absf(denom) < 1e-12:
				continue
			var s: float = (limit - cv) / denom
			out.append({
				"p": (cur["p"] as Vector3).lerp(nxt["p"], s),
				"n": ((cur["n"] as Vector3).lerp(nxt["n"], s)).normalized(),
			})
	return out


# Cuts a piece into relief cells and emits each raised as a unit, giving flat
# tops and a crisp step at every seam.
#
# THIS IS WHAT TELLS TWO MATERIALS APART. Colour cannot: the player's livery
# repaints the whole vehicle, so a material identified by its tint is identified
# by nothing as soon as anyone picks a scheme. Relief survives livery and the
# faction shader, and catches light at gameplay distance.
#
# The lift is per CELL, not per vertex, and that is the whole reason it works: a
# facet can be two large triangles, so there are no interior vertices to push -
# the tiles have to be CUT into existence. Reuses the same Sutherland-Hodgman
# slab clip the slat pattern uses, so seams land exactly on the grid at any
# facet size with no subdivision to resolve.
#
# A cell size of 0 means no relief and the piece is emitted whole. That is
# hardened_steel, deliberately flat, so every other material reads as a
# departure from a baseline the player has already seen.
static func _emit_relief(st: SurfaceTool, poly: Array, lift: float, bounds: Rect2,
		relief: Dictionary, thickness: float) -> int:
	var cell := float(relief.get("cell", 0.0))
	var height := float(relief.get("height", 0.0)) * maxf(0.35, thickness)
	if cell <= 0.0 or height <= 0.0:
		return _emit_poly(st, poly, lift, bounds)

	var stagger: bool = bool(relief.get("stagger", false))
	var lo := INF
	var hi := -INF
	for v in poly:
		var c: float = (v["p"] as Vector3).z
		lo = minf(lo, c)
		hi = maxf(hi, c)
	var first := int(floor(lo / cell))
	var last := int(floor(hi / cell))

	var count := 0
	for row in range(first, last + 1):
		var strip := _clip_slab(poly, 2, float(row) * cell, float(row + 1) * cell)
		if strip.size() < 3:
			continue
		# Brick offset: alternate rows shift half a cell along u.
		var shift: float = (cell * 0.5) if (stagger and (row % 2 != 0)) else 0.0
		var ulo := INF
		var uhi := -INF
		for v in strip:
			var u: float = (v["p"] as Vector3).x
			ulo = minf(ulo, u)
			uhi = maxf(uhi, u)
		var ufirst := int(floor((ulo - shift) / cell))
		var ulast := int(floor((uhi - shift) / cell))
		for col in range(ufirst, ulast + 1):
			var tile := _clip_slab(strip, 0, shift + float(col) * cell,
				shift + float(col + 1) * cell)
			if tile.size() < 3:
				continue
			# Two depths, checkerboarded, so the seams read as a GRID rather
			# than as one uniformly raised sheet - a uniform lift is invisible,
			# because it has no edge for the light to catch.
			var raised: bool = ((row + col) % 2) == 0
			var h: float = height if raised else height * 0.25
			count += _emit_poly(st, tile, lift + h, bounds)
	return count


# Fan-triangulates a convex piece and emits it lifted off the hull. Returns how
# many triangles were written. The normal is the piece's crease-split corner
# normal, set explicitly: _skin no longer calls generate_normals() because the
# slab's skirt must keep its own flat outward normals, and a position-smoothed
# regenerate would round the rim into the skirt.
static func _emit_poly(st: SurfaceTool, poly: Array, lift: float, bounds: Rect2) -> int:
	var n := poly.size()
	if n < 3:
		return 0
	var count := 0
	for i in range(1, n - 1):
		for idx in [0, i, i + 1]:
			var v: Dictionary = poly[idx]
			var p: Vector3 = (v["p"] as Vector3) + (v["n"] as Vector3) * lift
			st.set_normal(v["n"])
			st.set_uv(_shell_uv(p, bounds))
			st.add_vertex(p)
		count += 1
	return count


# The edges of the facet used by exactly ONE triangle - the plate's outline.
# Each entry is [a, na, b, nb]: the two corner positions and their crease-split
# corner normals as the owning triangle carries them. Quantisation on position
# (WELD_QUANTUM) for the same reason as _build_adjacency: a faceted hull's
# coincident corners carry different normals, so only position can key an edge.
static func _boundary_edges(tris: Array, normals: Array) -> Array:
	var counts := {}
	var edges := {}
	for t in range(tris.size()):
		for k in range(3):
			var key := _edge_key(_vkey(tris[t][k]), _vkey(tris[t][(k + 1) % 3]))
			counts[key] = int(counts.get(key, 0)) + 1
			if not edges.has(key):
				edges[key] = [tris[t][k], normals[t][k],
					tris[t][(k + 1) % 3], normals[t][(k + 1) % 3]]
	var out := []
	for key in counts.keys():
		if int(counts[key]) == 1:
			out.append(edges[key])
	return out


# Direction-independent key for an edge: the two quantised endpoints in
# lexicographic order, so (a,b) and (b,a) from adjacent triangles collide.
static func _edge_key(a: Vector3i, b: Vector3i) -> String:
	if b.x < a.x or (b.x == a.x and b.y < a.y) or (b.x == a.x and b.y == a.y and b.z < a.z):
		var t := a
		a = b
		b = t
	return "%d,%d,%d|%d,%d,%d" % [a.x, a.y, a.z, b.x, b.y, b.z]


# One skirt quad closing the plate's side, from the base lift up to the slab
# top, along one boundary edge. Wound to face outward: the facet's triangles
# are oriented CCW from outside (see _facet_surface's per-triangle flip), so a
# boundary edge a->b has the facet interior on edge_dir.cross(up)'s negative
# side - verified against a flat CCW tri: edge (0,0,0)->(0,0,1) with interior
# at +X gives (0,0,1)x(0,1,0) = (-1,0,0), i.e. outward.
static func _emit_skirt(st: SurfaceTool, a: Vector3, na: Vector3, b: Vector3, nb: Vector3,
		base_lift: float, top_lift: float, bounds: Rect2) -> int:
	var edge := b - a
	var up := na + nb
	if edge.length_squared() < 1e-14 or up.length_squared() < 1e-12:
		return 0
	# A zero-height skirt (thickness 0, e.g. the erase preview) would be two
	# zero-area triangles - invisible, but wasteful and degenerate for tangents.
	if top_lift <= base_lift + 1e-4:
		return 0
	var outward := edge.cross(up).normalized()
	var a_base := a + na * base_lift
	var b_base := b + nb * base_lift
	var a_top := a + na * top_lift
	var b_top := b + nb * top_lift
	# Godot's front face is CLOCKWISE from outside (see _emit_cage_quad), so the
	# CCW-from-outside quad (a_base, b_base, b_top, a_top) is emitted reversed.
	for idx in [2, 1, 0, 2, 0, 3]:
		var p: Vector3 = [a_base, b_base, b_top, a_top][idx]
		st.set_normal(outward)
		st.set_uv(_shell_uv(p, bounds))
		st.add_vertex(p)
	return 2


# The facet as a liftable surface, in module-local space: its triangles, their
# crease-split corner normals, and the tangential bounds used for UVs.
static func _facet_surface(mesh_inst: MeshInstance3D, hull_type_id: String, facet_id: int,
		center: Vector3, frame: Basis) -> Dictionary:
	var seg := cached_segment(mesh_inst.mesh) if mesh_inst and mesh_inst.mesh else {}
	if seg.is_empty():
		seg = load_map(hull_type_id)
	if seg.is_empty():
		return {}
	var faces := mesh_inst.mesh.get_faces()
	var tri_count := faces.size() / 3
	var map: PackedInt32Array = seg.get("map", PackedInt32Array())
	if map.size() != tri_count:
		return {}
	var xform := mesh_inst.transform
	var to_local := Transform3D(frame, center).affine_inverse()

	var tris := []
	var face_normals := []
	for i in range(tri_count):
		if map[i] != facet_id:
			continue
		var a: Vector3 = to_local * (xform * faces[i * 3])
		var b: Vector3 = to_local * (xform * faces[i * 3 + 1])
		var c: Vector3 = to_local * (xform * faces[i * 3 + 2])
		var cr := (b - a).cross(c - a)
		if cr.length_squared() < 1e-14:
			continue
		# Orient so the facet's outward side is +Y in module space, and so the
		# emitted triangle faces the camera. Done per triangle so a mirroring
		# hull transform cannot invert the skin.
		if cr.y < 0.0:
			var swap := b
			b = c
			c = swap
			cr = -cr
		tris.append([a, b, c])
		face_normals.append(cr.normalized())
	if tris.is_empty():
		return {}

	# Crease-split corner normals: average the face normals meeting at a vertex,
	# but only those within CREASE_SPLIT_DEG of THIS triangle's own normal.
	var by_vertex := {}
	for t in range(tris.size()):
		for k in range(3):
			var key := _vkey(tris[t][k])
			if not by_vertex.has(key):
				by_vertex[key] = []
			by_vertex[key].append(t)
	var crease := cos(deg_to_rad(CREASE_SPLIT_DEG))
	var corner_normals := []
	var min_u := INF
	var max_u := -INF
	var min_v := INF
	var max_v := -INF
	for t in range(tris.size()):
		var own: Vector3 = face_normals[t]
		var trio := []
		for k in range(3):
			var acc := Vector3.ZERO
			for other in by_vertex[_vkey(tris[t][k])]:
				var on: Vector3 = face_normals[other]
				if on.dot(own) >= crease:
					acc += on
			trio.append(acc.normalized() if acc.length_squared() > 1e-12 else own)
			var p: Vector3 = tris[t][k]
			min_u = minf(min_u, p.x); max_u = maxf(max_u, p.x)
			min_v = minf(min_v, p.z); max_v = maxf(max_v, p.z)
		corner_normals.append(trio)
	return {
		"tris": tris,
		"normals": corner_normals,
		"bounds": Rect2(min_u, min_v, max_u - min_u, max_v - min_v),
	}


# UVs in METRES of facet-local surface, not normalised 0..1.
#
# Normalised was wrong for the armor shader: it makes one UV unit mean "the
# width of this facet", so the same material tiled at a different density on
# every panel of the same vehicle - a small facet got the same number of blocks
# as a large one. In metres, a 0.5m reactive block is 0.5m everywhere, which is
# the only way a material can have a recognisable SCALE.
#
# `bounds` is retained so the offset stays stable as the facet moves, and so a
# facet straddling the origin does not get negative UVs on half of itself.
static func _shell_uv(p: Vector3, bounds: Rect2) -> Vector2:
	return Vector2(p.x - bounds.position.x, p.z - bounds.position.y)


# Orthonormal frame with +Y on the facet normal, and a PURE FUNCTION OF THAT
# NORMAL - no reference to the click, deliberately.
#
# Taking the in-plane spin from the caller's hit-normal basis was the last drop
# dependence left: on a curved facet the hit normal moves, so the frame span,
# and the measured bbox spun with it even after the facet set and the anchor
# were both stable. Since it reproduces module_placer._align_up_to() exactly,
# the module's own +Y still lands on the surface normal and every downstream
# convention (mirror flip, bottom-facet flip, yaw_offset) is unaffected.
# The centre and orientation of a facet, in HULL space - i.e. exactly the
# `center`/`frame` pair build_plate() wants, so a painted facet can be skinned
# from its id alone with no click and no measurement.
#
# When `mesh` is provided, uses the live cached segment; otherwise falls back
# to the baked sidecar.
#
# measure() cannot serve this: it exists to answer "which facet did the player
# just point at" and needs a ray to do it. Painting already knows the answer.
static func facet_frame(hull_type_id: String, facet_id: int, xform: Transform3D,
		mesh: Mesh = null) -> Dictionary:
	var seg := {}
	if mesh != null:
		seg = cached_segment(mesh)
	else:
		seg = load_map(hull_type_id)
	if seg.is_empty():
		return {"valid": false}
	var normals: PackedVector3Array = seg.get("normal", PackedVector3Array())
	var centroids: PackedVector3Array = seg.get("centroid", PackedVector3Array())
	if facet_id < 0 or facet_id >= normals.size() or facet_id >= centroids.size():
		return {"valid": false}
	# Normals take the inverse transpose, positions the transform itself.
	var n: Vector3 = (xform.basis.inverse().transposed() * normals[facet_id])
	if n.length_squared() < 1e-12:
		return {"valid": false}
	n = n.normalized()
	return {
		"valid": true,
		"center": xform * centroids[facet_id],
		"normal": n,
		"basis": _tangent_frame(n),
	}


static func _tangent_frame(n: Vector3) -> Basis:
	var target := n.normalized()
	if target.length_squared() < 0.5:
		return Basis.IDENTITY
	var d := Vector3.UP.dot(target)
	if d > 1.0 - 0.000001:
		return Basis.IDENTITY
	if d < -1.0 + 0.000001:
		return Basis(Vector3.RIGHT, PI)
	return Basis(Quaternion(Vector3.UP, target))


# ---------------------------------------------------------------------------
# Live facet computation -- replaces the baked sidecar for UI paths.
# ---------------------------------------------------------------------------

# Cached per-mesh adjacency + normals + areas.  Keyed by RID (unique per mesh
# resource within a session).  Built once, reused by every find_facet() call on
# that mesh -- the adjacency build is O(n) and not something we want on every
# mouse-move or paint click.
static var _facet_cache: Dictionary = {}  # RID -> _FCache

class _FCache:
	var adjacency: Array = []
	var normals: PackedVector3Array = PackedVector3Array()
	var areas: PackedFloat32Array = PackedFloat32Array()
	var tri_count: int = 0


static func _ensure_facet_cache(mesh: Mesh) -> _FCache:
	if mesh == null:
		return null
	var rid: RID = mesh.get_rid()
	if _facet_cache.has(rid):
		return _facet_cache[rid] as _FCache
	var faces := mesh.get_faces()
	var tc := faces.size() / 3
	var c := _FCache.new()
	c.tri_count = tc
	c.normals.resize(tc)
	c.areas.resize(tc)
	for i in range(tc):
		var v0: Vector3 = faces[i * 3]
		var v1: Vector3 = faces[i * 3 + 1]
		var v2: Vector3 = faces[i * 3 + 2]
		var cr: Vector3 = (v1 - v0).cross(v2 - v0)
		var l := cr.length()
		c.normals[i] = cr / l if l > 1e-12 else Vector3.UP
		c.areas[i] = l * 0.5
	c.adjacency = _build_adjacency(faces, tc)
	_facet_cache[rid] = c
	return c


static func invalidate_facet_cache() -> void:
	_facet_cache.clear()


# Computes a facet by flood-filling from `tri_index`. Returns a dictionary:
#   { "tris": PackedInt32Array, "centroid": Vector3, "normal": Vector3,
#     "area": float, "valid": bool }
#
# Uses the same dual-check drift cap as segment() (FACET_CONE_DEG for the
# running mean, FACET_SEED_CONE_DEG for the hard seed cap).  This exploits the
# hard creases already present in the geometry: chine/deck/flank transitions
# create 38-52 degree dihedrals, which exceed both thresholds.
#
# Adjacency and per-triangle normals are cached per Mesh resource so the O(n)
# build happens once per hull type.
static func find_facet(mesh: Mesh, tri_index: int) -> Dictionary:
	var empty := {"tris": PackedInt32Array(), "centroid": Vector3.ZERO,
		"normal": Vector3.ZERO, "area": 0.0, "valid": false}
	if mesh == null or tri_index < 0:
		return empty
	var c := _ensure_facet_cache(mesh)
	if c == null or tri_index >= c.tri_count:
		return empty
	var faces := mesh.get_faces()
	var step_cos := cos(deg_to_rad(FACET_CONE_DEG))
	var seed_cos := cos(deg_to_rad(FACET_SEED_CONE_DEG))
	var seed_n: Vector3 = c.normals[tri_index]
	var mean := seed_n * c.areas[tri_index]
	var mean_n := seed_n
	var visited := {}
	var queue: Array = [tri_index]
	visited[tri_index] = true
	while queue.size() > 0:
		var cur: int = queue.pop_back()
		for nb in c.adjacency[cur]:
			if visited.has(nb):
				continue
			if c.areas[nb] <= 0.0:
				continue
			var nn: Vector3 = c.normals[nb]
			if nn.dot(mean_n) < step_cos or nn.dot(seed_n) < seed_cos:
				continue
			visited[nb] = true
			mean += nn * c.areas[nb]
			if mean.length_squared() > 1e-12:
				mean_n = mean.normalized()
			queue.append(nb)
	# Collect results.
	var tris := PackedInt32Array()
	tris.resize(visited.size())
	var idx := 0
	var centroid := Vector3.ZERO
	var total_area := 0.0
	var vert_count := 0
	for t in visited:
		tris[idx] = t
		idx += 1
		var v0: Vector3 = faces[t * 3]
		var v1: Vector3 = faces[t * 3 + 1]
		var v2: Vector3 = faces[t * 3 + 2]
		centroid += v0 + v1 + v2
		vert_count += 3
		total_area += c.areas[t]
	if vert_count < 3 or total_area < 1e-12:
		return empty
	centroid /= float(vert_count)
	# Orient the mean normal outward using the mesh's winding sign.
	# The flood fill is sign-invariant (dot products are unaffected by a global
	# flip), but the RETURNED normal must face outward for side classification.
	var flip := winding_sign(mesh)
	var n_len := mean.length()
	var out_n := mean / n_len if n_len > 1e-12 else seed_n
	if flip < 0.0:
		out_n = -out_n
	return {
		"tris": tris,
		"centroid": centroid,
		"normal": out_n,
		"area": total_area,
		"valid": true,
	}


# Finds the triangle nearest to `local_pos` whose normal agrees with
# `local_normal`.  Returns the triangle index, or -1.  Used by the highlight
# and by re-finding a facet after save/load (centroid proximity).
static func find_nearest_tri(mesh: Mesh, local_pos: Vector3,
		local_normal: Vector3) -> int:
	if mesh == null:
		return -1
	var c := _ensure_facet_cache(mesh)
	if c == null or c.tri_count <= 0:
		return -1
	var faces := mesh.get_faces()
	var norm := local_normal.normalized()
	var best_idx := -1
	var best_dist := INF
	for i in range(c.tri_count):
		if c.areas[i] <= 0.0:
			continue
		var nn: Vector3 = c.normals[i]
		if absf(nn.dot(norm)) < 0.5:
			continue
		var v0: Vector3 = faces[i * 3]
		var v1: Vector3 = faces[i * 3 + 1]
		var v2: Vector3 = faces[i * 3 + 2]
		var d: float = (((v0 + v1 + v2) / 3.0) - local_pos).length_squared()
		if d < best_dist:
			best_dist = d
			best_idx = i
	return best_idx


# Cached full-mesh segmentation.  Runs segment() once per Mesh and caches the
# result.  Used by the side-brush (needs all facets grouped by side) and by
# build_plan() (needs the tri_to_facet map).  The cache is keyed by RID, same
# as the facet cache.
static var _seg_cache: Dictionary = {}  # RID -> Dictionary (segment() output + sides)

static func cached_segment(mesh: Mesh) -> Dictionary:
	if mesh == null:
		return {}
	var rid: RID = mesh.get_rid()
	if _seg_cache.has(rid):
		return _seg_cache[rid] as Dictionary
	var result := segment(mesh)
	if result.is_empty() or int(result.get("count", 0)) <= 0:
		_seg_cache[rid] = {}
		return {}
	# Classify each facet into a side from its area-weighted normal.
	var count := int(result["count"])
	var facet_normals: PackedVector3Array = result.get("normal", PackedVector3Array())
	var side_arr := []
	side_arr.resize(count)
	var sides_map: Dictionary = {}  # side_name -> Array[int]
	for s in SIDE_AXES.keys():
		sides_map[s] = []
	for f in range(count):
		var n: Vector3 = facet_normals[f] if f < facet_normals.size() else Vector3.UP
		var best_side := ""
		var best_dot := -INF
		for s_name in SIDE_AXES.keys():
			var d: float = n.dot(SIDE_AXES[s_name])
			if d > best_dot:
				best_dot = d
				best_side = s_name
		side_arr[f] = best_side
		if best_side != "":
			(sides_map[best_side] as Array).append(f)
	result["facet_side"] = side_arr
	result["sides"] = sides_map
	_seg_cache[rid] = result
	return result


# Looks up which facet a triangle belongs to, using the cached segmentation.
# Returns the facet id, or -1.  This is the fast path for the resolver --
# direct PackedInt32Array index into the cached map.
static func facet_for_tri(mesh: Mesh, tri_index: int) -> int:
	if tri_index < 0:
		return -1
	var seg := cached_segment(mesh)
	if seg.is_empty():
		return -1
	var m: PackedInt32Array = seg.get("map", PackedInt32Array())
	if tri_index >= m.size():
		return -1
	return m[tri_index]


# Returns all facet ids belonging to `side` (e.g. "front", "top"), or [].
# Used by the side-brush.
static func facets_for_side_mesh(mesh: Mesh, side: String) -> PackedInt32Array:
	var out := PackedInt32Array()
	var seg := cached_segment(mesh)
	if seg.is_empty():
		return out
	var sides_map: Dictionary = seg.get("sides", {})
	var arr = sides_map.get(side, [])
	for v in arr:
		out.append(int(v))
	return out


# Builds a reverse map { triangle_index: facet_id } from the cached
# segmentation.  Used by build_plan() and the resolver.
static func build_tri_to_facet(mesh: Mesh) -> Dictionary:
	var seg := cached_segment(mesh)
	if seg.is_empty():
		return {}
	var m: PackedInt32Array = seg.get("map", PackedInt32Array())
	# Note: the previous version did `var result := {}; result.resize(m.size())`
	# but `{}` infers as Dictionary in GDScript, and Dictionary has no resize().
	# The pre-allocation was a no-op for a Dictionary anyway (you can write
	# `result[i] = v` without sizing), so the fix is just to drop the resize.
	var result: Dictionary = {}
	for i in range(m.size()):
		result[i] = m[i]
	return result


static func invalidate_seg_cache() -> void:
	_seg_cache.clear()
