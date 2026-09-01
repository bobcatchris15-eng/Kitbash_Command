extends RefCounted
class_name HullChine
# Finds the LOWER CHINE of an arbitrary hull mesh: the line, running fore-aft
# down each flank, where the side wall turns into the belly.
#
# WHY THIS EXISTS
#
# Every locomotion station in the Design Lab used to be computed from the hull's
# fitted collision BOX - module_placer.gd read hull_size off the CollisionShape3D
# and locomotion_layout.gd laid stations out at fractions of it. That is exact on
# a literal box and wrong on everything else, and since the hull roster moved to
# the SDF/marching-cubes bake almost nothing is a literal box: hulls have
# chamfered lower edges, tapered keels, tumblehome flanks, curved envelopes.
#
# The two failure modes that produced, both visible in the Lab:
#
#   BELLY MOUNTING (wheels, legs, hover pads, grav plates) put the station at
#   -hull_size.y * 0.5, the bottom of the BOX. On a keeled or chamfered hull the
#   mesh has already pinched inboard by the time it gets that low, so the part
#   hangs in open air below the hull with a visible gap.
#
#   FLANK MOUNTING (treads, screw drums, half-tracks) put the station at
#   +/-hull_size.x * 0.5, the side of the BOX, at belly height. On a chamfered
#   hull that x is outside the mesh at that y - same gap - and on a slab-sided
#   hull with a flared skirt it is INSIDE the mesh, so the assembly clips through
#   the hull instead.
#
# There were exactly two patches for this and both were narrow.
# ModuleCatalog.get_underside_y_bias() is a hand-tuned scalar carried by 4 of the
# 94 hulls. module_placer.gd's _seat_legs_on_hull_skin() had the right idea -
# raycast the real triangles - but ran for legs only and corrected X only.
#
# WHY THE CHINE AND NOT JUST "THE NEAREST SURFACE POINT"
#
# Chris, 2026-08-12: "attach itself to the bottom edges of it. Not the bottom
# directly, but to the bottom of the sides without visual gaps and clashing."
#
# That is the correct call and it is also how real running gear is hung. A
# suspension arm, a track frame, a sponson bracket - all of them bolt to the
# turn of the bilge, because that is where the hull has a structural corner to
# take the load. Mounting to the flat belly reads as a part glued to the floor
# of the vehicle; mounting to the mid-flank reads as a part stuck to a wall.
# Mounting to the chine reads as running gear, and it is the one point that is
# simultaneously the outermost place the part can hang from and the lowest, so
# the arm never has to cross open space to reach it.
#
# HOW
#
# Slice the hull's triangles with the plane z = z0 to get an exact 2D
# cross-section, then find the section point closest to the outboard-bottom
# corner IN NORMALISED SECTION COORDINATES. Normalising is what makes this work
# across the whole roster without per-hull tuning:
#
#   - literal box            -> the exact bottom-outer vertex
#   - 45-degree chamfer      -> the middle of the chamfer face
#   - rounded bilge          -> the 45-degree tangent point on the curve
#   - tapered keel           -> the turn of the bilge, well above the keel line
#   - flared skirt           -> the widest point, which is also the lowest
#
# Plane-slicing rather than raycasting on purpose. A ray has to be aimed, and
# aiming it is the original problem restated - _seat_legs_on_hull_skin() needed
# a four-sample ladder up the flank precisely because a single ray fired at the
# station's own height passes under a hull that is pinching in. A section is
# aimed at nothing; it returns the hull's true shape at that station and the
# corner falls out of it.
#
# Pure math over Mesh.get_faces() (via HullProjection.build_surface) rather than
# a PhysicsDirectSpaceState query, for the reasons hull_projection.gd already
# documents: this runs during hull construction before the node is in the tree
# and before any physics step, and it has to work headless for the test suite.

const HullProjectionScript = preload("res://scripts/hull_projection.gd")

## A vertex within this distance of the slice plane counts as ON it, rather than
## being reached by interpolating along an edge. Keeps a triangle that happens to
## have a vertex exactly on the plane from being dropped by the strict
## opposite-sign edge test below.
const PLANE_EPS: float = 0.0001

## Below this many points a slice is not a real cross-section - the plane clipped
## a corner triangle or missed the hull's z-range - and chine_at() reports a miss
## rather than returning a corner derived from two points.
const MIN_SECTION_POINTS: int = 3

## Degenerate-section guard. A section thinner or shallower than this (in hull
## units) has no meaningful corner to find.
# Fractional port/starboard width difference under which a section is treated
# as mirror-symmetric and solved as one folded candidate set. Well above the
# float/triangulation noise of a symmetric bake (measured under 1e-3 on this
# roster) and well below any deliberate one-sided sponson.
const SECTION_SYMMETRY_TOL := 0.05
const MIN_SECTION_EXTENT: float = 0.001

## Radius of the tangent-fit neighbourhood at the chine, as a fraction of the
## SMALLER of the section's half-width and height. Large enough to span several
## triangles on a coarse bake (so the fit is not dominated by one facet's exact
## winding), small enough not to average the flank and the belly into a
## meaningless mean on a section with a tight bilge.
##
## Scaled to the smaller dimension and not to the section's diagonal, which is
## what it used to be. A corner fit has to sample both faces that meet there in
## roughly equal measure, and a radius set by the diagonal is set by the LARGER
## face - so on a tall narrow section it reached far up the wall while barely
## reaching along the short belly, and came back with the wall's normal.
## Measured: that put all nine foundation hulls (tower_main_*, bunker_main_*,
## battery_main_*, all vertical-walled and much taller than wide) on the
## shoulder, with normals around (0.99, -0.14) instead of the ~45 degrees a hard
## square bottom edge should give. Those hulls take locomotion - the mobile
## pillbox is a deliberately supported build - so getting them wrong is not
## academic.
const NORMAL_FIT_RADIUS_FRAC: float = 0.25

## Minimum neighbours needed for the tangent fit. Under this the fit is
## unconstrained and chine_at() falls back to the 45-degree bisector, which is
## the correct answer for a sharp corner anyway.
const MIN_FIT_POINTS: int = 2

## How far along the hull's length the fore and aft ends are pulled in before
## sampling a chine run. The extreme ends of a hull are a nose cone or a transom,
## where the section collapses toward a point and the "chine" is not a chine but
## the tip of the bow. Running gear is never hung there.
const RUN_END_INSET_FRAC: float = 0.06


# --- Profile construction ----------------------------------------------------

## Builds a chine profile for `host`, gathering triangles in host-LOCAL space.
##
## Placed modules, decals and greebles are excluded by HullProjection's own
## filters, which matters here for the same reason it matters for decals: a hull
## that already has treads on it must not report the tread frame as hull skin and
## hang the next assembly off that.
##
## The returned dict carries a memo of solved sections. Godot dictionaries are
## reference types, so a caller that holds the profile across a whole locomotion
## rebuild gets every repeated station z for free - which is the common case,
## since a paired pattern asks for the same z twice, once per side.
static func build(host: Node3D) -> Dictionary:
	return from_surface(HullProjectionScript.build_surface(host))


## Same, when the caller already has a HullProjection surface in hand and does
## not want to re-walk the scene tree to gather the triangles a second time.
static func from_surface(surface: Dictionary) -> Dictionary:
	return {
		"tris": surface.get("tris", PackedVector3Array()),
		"aabb": surface.get("aabb", AABB()),
		"surface": surface,
		"sections": {},
	}


## True when the profile has enough geometry to solve against. A false here is a
## legitimate result - a hull whose mesh has not finished importing, or a
## primitive fallback with no MeshInstance3D - and every caller is expected to
## fall back to plain AABB placement rather than treat it as an error.
static func is_valid(profile: Dictionary) -> bool:
	var tris: PackedVector3Array = profile.get("tris", PackedVector3Array())
	return tris.size() >= 3


# --- Cross sections ----------------------------------------------------------

## Exact cross-section of the hull at z, as an unordered point cloud in the
## section plane. Unordered is sufficient and deliberate: the two things built on
## top of this - an argmin over a corner metric and a local tangent fit - both
## work on a cloud, and reconstructing an ordered watertight polygon from a bake
## that is not guaranteed manifold is a much harder problem with no payoff here.
##
## Returns {"points": Array[Vector2] as (x, y), "low": float, "high": float,
## "left": float, "right": float}. `low`/`high` are the section's full y range
## across BOTH sides, which is what normalises the corner metric.
static func section(profile: Dictionary, z: float) -> Dictionary:
	# Memo on a quantised key. Two stations that differ by a micron are the same
	# section for every purpose here, and quantising keeps a float key from
	# missing a hit it should have had.
	var key := int(round(z * 1000.0))
	var memo: Dictionary = profile.get("sections", {})
	if memo.has(key):
		return memo[key]

	var pts: Array[Vector2] = []
	var tris: PackedVector3Array = profile.get("tris", PackedVector3Array())
	var i := 0
	while i + 2 < tris.size():
		var a := tris[i]
		var b := tris[i + 1]
		var c := tris[i + 2]
		var da := a.z - z
		var db := b.z - z
		var dc := c.z - z

		# Vertices sitting on the plane are added directly. The strict
		# opposite-sign test below deliberately misses these (a zero product is
		# not negative), and a triangle lying flat in the plane - which happens on
		# a hull with a vertical transom or a flat bulkhead exactly at a station -
		# would otherwise contribute nothing at all.
		if absf(da) < PLANE_EPS:
			pts.append(Vector2(a.x, a.y))
		if absf(db) < PLANE_EPS:
			pts.append(Vector2(b.x, b.y))
		if absf(dc) < PLANE_EPS:
			pts.append(Vector2(c.x, c.y))

		_cut_edge(pts, a, b, da, db)
		_cut_edge(pts, b, c, db, dc)
		_cut_edge(pts, c, a, dc, da)
		i += 3

	var out := {
		"points": pts, "low": 0.0, "high": 0.0, "left": 0.0, "right": 0.0,
	}
	if pts.size() >= MIN_SECTION_POINTS:
		var low := INF
		var high := -INF
		var left := INF
		var right := -INF
		for p in pts:
			low = minf(low, p.y)
			high = maxf(high, p.y)
			left = minf(left, p.x)
			right = maxf(right, p.x)
		out["low"] = low
		out["high"] = high
		out["left"] = left
		out["right"] = right
	memo[key] = out
	return out


## Adds the crossing point of edge (p, q) with the slice plane, if it crosses.
## Strict opposite sign only - the on-plane case is handled by the caller, and
## accepting it here as well would double-count every such vertex once per
## incident edge.
static func _cut_edge(pts: Array[Vector2], p: Vector3, q: Vector3,
		dp: float, dq: float) -> void:
	if dp * dq >= 0.0:
		return
	var t := dp / (dp - dq)
	pts.append(Vector2(p.x + (q.x - p.x) * t, p.y + (q.y - p.y) * t))


# --- The chine ---------------------------------------------------------------

## Solves the lower chine at station z on `side` (-1.0 port, +1.0 starboard).
##
## Returns {"found": bool, "position": Vector3, "normal": Vector3,
## "half_width": float, "low": float, "high": float}.
##
## `position` is hull-local and lies ON the mesh. `normal` is the outward surface
## direction there, pointing away from the hull's interior and (on any hull with
## a real chine) down-and-outboard - which is exactly the direction a suspension
## arm or a track-frame bracket wants to extend along. A caller mounts a part by
## placing it at `position` and running its structure back along `-normal`; there
## is no gap to bridge because the point is on the skin by construction.
##
## On a miss every field is still populated with the AABB-derived answer, so a
## caller may use the result unconditionally and only consult `found` when it
## wants to know whether it got mesh truth or the old box behaviour.
static func chine_at(profile: Dictionary, z: float, side: float) -> Dictionary:
	var s := signf(side)
	if is_zero_approx(s):
		s = 1.0
	var aabb: AABB = profile.get("aabb", AABB())
	var fallback := _box_chine(aabb, z, s)
	if not is_valid(profile):
		return fallback

	var sec := section(profile, z)
	var pts: Array[Vector2] = sec.get("points", [] as Array[Vector2])
	if pts.size() < MIN_SECTION_POINTS:
		return fallback

	var low: float = sec["low"]
	var high: float = sec["high"]
	var height := high - low
	# Half-width measured on the requested side only. A hull is not necessarily
	# symmetric (an asymmetric sponson, a bake that drifted), and using the full
	# section width would normalise the port side against the starboard side's
	# widest point.
	# Reassigned below when the section folds - see SIDE FOLDING.
	var half_width: float = (sec["right"] if s > 0.0 else -sec["left"])
	if height < MIN_SECTION_EXTENT or half_width < MIN_SECTION_EXTENT:
		return fallback

	# SIDE FOLDING - the fix for asymmetric locomotion stations.
	#
	# The corner metric below picks the best DISCRETE VERTEX of the section, and
	# section() returns an unordered point cloud harvested per triangle. A hull
	# mesh that is mirror-symmetric in SHAPE is not necessarily mirror-symmetric
	# in TRIANGULATION, so the two sides offer different candidate vertices at a
	# given z, and the argmin lands in different places. On a hull with long
	# flat chamfer faces the nearest candidates sit at opposite ENDS of the same
	# face, so the error is the size of the face, not of the noise.
	#
	# Measured with tools/probe_chine_symmetry.gd: 78 of 98 hulls in the roster
	# had a port/starboard chine mismatch over 20 mm, worst 0.89 m, and every
	# hexton hull was between 0.24 m and 0.78 m - which is the visible
	# "wheels and legs are not attached symmetrically" report.
	#
	# So when the section is symmetric to within SECTION_SYMMETRY_TOL, both
	# sides are solved from ONE candidate set built in |x| space, which makes
	# the two answers mirror images by construction rather than by luck. A
	# genuinely asymmetric section (an authored one-sided sponson) falls back to
	# the old per-side solve, so the original intent recorded above half_width
	# is preserved where it actually applies.
	var right_w: float = sec["right"]
	var left_w: float = -sec["left"]
	var widest: float = maxf(right_w, left_w)
	var folded: bool = widest > MIN_SECTION_EXTENT and absf(right_w - left_w) / widest <= SECTION_SYMMETRY_TOL
	if folded:
		# One shared half-width, or the normalisation itself stays per-side and
		# reintroduces the very asymmetry the folding removes.
		half_width = widest

	# THE CORNER METRIC.
	#
	# u = 1.0 at this section's widest point on this side, 0.0 on centreline.
	# v = 0.0 at the section's lowest point, 1.0 at its highest.
	# The chine is the point closest to (u, v) = (1, 0) - outermost and lowest.
	#
	# Both axes are normalised, so the answer is the PROPORTIONAL corner and
	# holds across the whole roster without tuning. Squared distance rather than
	# a linear (u - v) score because the linear form ties across an entire
	# 45-degree chamfer face and needs an arbitrary tie-break; squared distance
	# picks the middle of that face, which is where the bracket should sit.
	#
	# Candidates are held in |x| (outboard-positive) space so a folded solve and
	# a per-side solve run through identical code; the winner is mapped back
	# onto the requested side at the end.
	var best_out := -INF   # outboard distance of the winner
	var best_y := 0.0
	var best_cost := INF
	# Centroid of THIS SIDE's real points, accumulated in the same pass. Stays
	# per-side even when folded: it is the interior reference the normal fit is
	# oriented against, and that fit reads real geometry on the side being
	# solved - see _fit_normal().
	var interior := Vector2.ZERO
	var interior_n := 0
	for j in pts.size():
		var p := pts[j]
		var sx := p.x * s
		if sx > 0.0:
			interior += p
			interior_n += 1
		var out_x: float = sx
		if out_x <= 0.0:
			if not folded or absf(p.x) <= 0.0:
				continue  # other side of the keel, and not folding it in
			out_x = -sx   # mirror the far-side point onto this side
		var u := out_x / half_width
		var v := (p.y - low) / height
		var du := 1.0 - u
		var cost := du * du + v * v
		if cost < best_cost:
			best_cost = cost
			best_out = out_x
			best_y = p.y
	if best_out == -INF or interior_n == 0:
		return fallback
	interior /= float(interior_n)

	var chine := Vector2(best_out * s, best_y)
	return {
		"found": true,
		"position": Vector3(chine.x, chine.y, z),
		"normal": _fit_normal(pts, chine, s, half_width, height, interior),
		"half_width": half_width,
		"low": low,
		"high": high,
	}


## Outward surface normal at the chine, fitted from the section points around it.
##
## Fitted rather than taken from the winning triangle's own winding: a bake's
## per-facet normals flip locally (hull_projection.gd's raycast is two-sided for
## exactly this reason), and on a faceted chamfer the single incident facet's
## normal is a stair-step rather than the surface direction. A short local fit
## averages that out and, on a rounded bilge, returns the true tangent normal
## instead of one facet's approximation of it.
## `origin` is a POINT rather than an index into `pts`, because a folded chine
## solve (see SIDE FOLDING in chine_at) can win on a position mirrored in from
## the far side, which is not a vertex of this side. The neighbourhood scan
## below still reads real points, so the fitted normal is real local geometry on
## the side being solved either way.
static func _fit_normal(pts: Array[Vector2], origin: Vector2, s: float,
		half_width: float, height: float, interior: Vector2) -> Vector3:
	var radius := minf(half_width, height) * NORMAL_FIT_RADIUS_FRAC
	var r2 := radius * radius

	# Principal axis of the neighbourhood, by the 2x2 covariance. The dominant
	# eigenvector is the surface tangent; its perpendicular is the normal.
	var mean := Vector2.ZERO
	var n := 0
	for p in pts:
		if p.distance_squared_to(origin) <= r2:
			mean += p
			n += 1
	if n < MIN_FIT_POINTS:
		return _bisector(s)
	mean /= float(n)

	var sxx := 0.0
	var sxy := 0.0
	var syy := 0.0
	for p in pts:
		if p.distance_squared_to(origin) > r2:
			continue
		var d := p - mean
		sxx += d.x * d.x
		sxy += d.x * d.y
		syy += d.y * d.y

	# Closed-form dominant eigenvector of [[sxx, sxy], [sxy, syy]].
	var tr := sxx + syy
	var det := sxx * syy - sxy * sxy
	var disc := tr * tr * 0.25 - det
	if disc < 0.0:
		disc = 0.0
	var lambda := tr * 0.5 + sqrt(disc)
	var tangent := Vector2(sxy, lambda - sxx)
	if tangent.length_squared() < 1e-12:
		tangent = Vector2(lambda - syy, sxy)
	if tangent.length_squared() < 1e-12:
		return _bisector(s)
	tangent = tangent.normalized()

	var normal := Vector2(tangent.y, -tangent.x)

	# ORIENT OUTWARD AGAINST THE SECTION INTERIOR, NOT THE LOCAL NEIGHBOURHOOD.
	#
	# The obvious reference - the direction from the neighbourhood's own mean to
	# the chine point - is degenerate exactly where it matters most. On a
	# straight run of surface (a slab flank, a flat belly plate) the local mean
	# lies ON the run, so `origin - mean` is PARALLEL to the tangent and
	# therefore perpendicular to the normal: the dot product is ~0 and carries no
	# orientation information whatsoever. Measured before this was fixed: 379 of
	# 940 sampled stations came back with a normal pointing inboard or upward,
	# concentrated in the slab-sided hulls (tallow_transport_*, tower_main_*)
	# where the fit neighbourhood is a straight vertical wall.
	#
	# The centroid of this side's section points cannot degenerate that way. The
	# chine is by definition the outermost-and-lowest point of the section, so it
	# is never inside the hull of the other points, and the vector from their
	# centroid to it is always genuinely outward - and, because the centroid sits
	# up and inboard, naturally down-and-outboard as well.
	if normal.dot(origin - interior) < 0.0:
		normal = -normal

	# A fit on a nearly-flat patch can come back pointing along the flank or
	# along the belly rather than out of the corner. Either is a legal surface
	# normal but neither is a mount direction - a bracket laid along the hull
	# skin reads as a fin, not a mounting. Bias toward the corner enough to keep
	# the arm coming out of the chine, without discarding a genuinely measured
	# direction on a hull that really is rounded there.
	var blended := (normal + Vector2(s, -1.0).normalized() * 0.35).normalized()

	# HARD GUARD. A mount normal must point outboard and must not point up: a
	# bracket built along an inboard normal drives through the hull, and one
	# built along an upward normal hangs the running gear off the shoulder
	# instead of the chine. If a measured fit violates either - a pathological
	# section, a non-manifold patch in the bake - the sharp-corner bisector is
	# always safe, and it is what the surface would be if the hull had a clean
	# chine there at all.
	if blended.x * s <= 0.0 or blended.y >= 0.0:
		return _bisector(s)
	return Vector3(blended.x, blended.y, 0.0)


## The 45-degree out-and-down bisector: the exact normal of a sharp square
## corner, and the right default whenever the fit has nothing to work with.
static func _bisector(s: float) -> Vector3:
	return Vector3(s, -1.0, 0.0).normalized()


## Box-derived chine, used when there is no usable mesh. This is deliberately the
## OLD behaviour - the bottom-outer corner of the bounding box - so a hull that
## fails to slice degrades to exactly what the system did before this script
## existed, rather than to something new and differently wrong.
static func _box_chine(aabb: AABB, z: float, s: float) -> Dictionary:
	var half_width: float = aabb.size.x * 0.5
	var centre := aabb.position + aabb.size * 0.5
	return {
		"found": false,
		"position": Vector3(centre.x + s * half_width, aabb.position.y, z),
		"normal": _bisector(s),
		"half_width": half_width,
		"low": aabb.position.y,
		"high": aabb.position.y + aabb.size.y,
	}


# --- Chine runs --------------------------------------------------------------

## Samples the chine at `samples` evenly spaced stations along the hull's length.
##
## For continuous running gear - a track frame, a tread belt, a sponson rail -
## which has to FOLLOW the chine rather than hang off one point of it. A track
## frame built from a single chine point is straight, and on any hull with a
## tapered bow it either floats away from the skin at the front or drives into it.
##
## The extreme ends are inset (RUN_END_INSET_FRAC): a section taken at the very
## tip of a bow has collapsed to nearly a point, and its "chine" is the tip
## itself, which would drag the front of a track frame onto the hull centreline.
static func chine_run(profile: Dictionary, side: float, samples: int = 8) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	var n := maxi(2, samples)
	var aabb: AABB = profile.get("aabb", AABB())
	if aabb.size.z <= MIN_SECTION_EXTENT:
		return out
	var inset := aabb.size.z * RUN_END_INSET_FRAC
	var z0 := aabb.position.z + inset
	var z1 := aabb.position.z + aabb.size.z - inset
	for i in n:
		var t := float(i) / float(n - 1)
		out.append(chine_at(profile, lerpf(z0, z1, t), side))
	return out


# --- Mount frames ------------------------------------------------------------

## The full mounting frame at a station: where hardware goes and how it is
## oriented. This is the interface the locomotion builders consume; chine_at() is
## the geometry underneath it.
##
## THE PINNING RULE. Chris, 2026-08-12: "Pin the bottom edge of any running gear
## / attachment hardware generated to the chine, so that the bulk of it reads as
## attached above that, aligning the bottom of any running gear with the bottom
## of the hull."
##
## So the chine is a BASELINE, not a hang point. Hardware is authored with its
## origin at its own bottom-inboard edge and its mass extending +Y and +X from
## there, and placing that origin on the chine with this frame's basis gives, by
## construction:
##
##   - the gear's bottom edge exactly on the hull's lower edge line, so the two
##     read as one continuous bottom rather than as a body with something slung
##     under it;
##   - the gear's bulk above that line, laid against the flank it is bolted to,
##     which is what makes it read as structure attached to the hull rather than
##     as a separate object floating near it;
##   - no gap and no interpenetration at the contact line, because the origin is
##     ON the mesh and the +Y axis runs ALONG the surface rather than into it.
##
## Returns:
##   found        false when the section could not be solved and this is the
##                bounding-box fallback
##   position     hull-local, on the mesh, at the chine
##   basis        x = outboard surface normal, y = up along the flank,
##                z = the cross product, which comes out pointing aft on the
##                starboard side and forward on the port side - i.e. the frame
##                is self-mirroring and a builder needs no separate chirality
##                handling
##   normal       basis.x, broken out for callers that only want the direction
##   flank_up     basis.y, likewise
##   flank_height how much hull there is ABOVE the chine at this station, which
##                is the room a builder has to grow the gear into before it
##                overruns the shoulder
##   belly_drop   how far the hull's lowest point at this section sits BELOW the
##                chine. Zero on a slab-bottomed hull. Non-zero on a keeled or
##                strongly chamfered one, where "the bottom of the hull" is
##                ambiguous - the chine line is what the eye reads as the bottom
##                edge, but there is real geometry below it, and a builder that
##                must clear the true lowest point (a track belt, a skirt) needs
##                to know by how much.
##   half_width   the section's half-width on this side
static func mount_frame(profile: Dictionary, z: float, side: float) -> Dictionary:
	var s := signf(side)
	if is_zero_approx(s):
		s = 1.0
	var hit := chine_at(profile, z, s)
	var out: Vector3 = hit["normal"]
	var pos: Vector3 = hit["position"]

	# Up along the flank: the section-plane perpendicular of the outward normal,
	# picked so it rises. Multiplying by the side is what selects the correct one
	# of the two perpendiculars on each flank - without it the port side gets the
	# descending one and hardware grows downward into the ground.
	var up := Vector3(-out.y * s, out.x * s, 0.0)
	if up.length_squared() < 1e-12:
		up = Vector3.UP
	up = up.normalized()

	return {
		"found": hit["found"],
		"position": pos,
		"basis": Basis(out, up, out.cross(up)),
		"normal": out,
		"flank_up": up,
		"flank_height": maxf(0.0, float(hit["high"]) - pos.y),
		"belly_drop": maxf(0.0, pos.y - float(hit["low"])),
		"half_width": hit["half_width"],
	}


## Convenience for the common "I have an analytic station and I want it moved
## onto the real chine" call, which is what every locomotion pattern needs.
##
## Keeps the station's own Z - the layout owns fore-aft spacing and that spacing
## is load-bearing elsewhere (even spread along the hull, ground-contact solve) -
## and replaces X and Y with mesh truth. Same division of responsibility
## _seat_legs_on_hull_skin() established when it corrected X only; this extends
## it to Y and to every type rather than legs alone.
static func seat_station(profile: Dictionary, station_pos: Vector3) -> Dictionary:
	return mount_frame(profile, station_pos.z, signf(station_pos.x))
