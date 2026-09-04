# ModuleVolume: the one description of the space a module's visible geometry
# actually occupies.
#
# No class_name / no `extends` - same convention as hull_surface.gd,
# hull_loader.gd and mesh_asset_loader.gd (class_name globals aren't reliable in
# scripts run headless before the .godot cache exists). Preload it.
#
# WHY THIS FILE EXISTS. The Design Lab held two disagreeing ideas of how big a
# module is, and used the wrong one for the thing players actually notice:
#
#   * The CLICK collider was measured from the real MeshInstance3D children
#     (module_placer._refit_module_collider / _resize_collider_to_visual).
#   * The CLIP test was not. check_all_clipping() sized every module from
#     ModuleCatalog's `size` - a hand-tuned AUTHORING box which, for an authored
#     .glb, does not even share the mesh's ORIENTATION: build_visual() yaws
#     monolithic meshes 90 degrees about Y, so heavy_machine_gun's
#     (0.3, 0.3, 1.0) is a sliver lying ACROSS the gun, and the mesh is then
#     uniformly fit-scaled to the largest catalog axis so the other two axes
#     miss too. That box was then re-AXIS-ALIGNED after rotation (a module at
#     45 degrees got tested at its diagonal envelope) and multiplied by
#     `module.scale` a SECOND time on top of the transform that already carried
#     it. Three compounding over-estimates, which is why parts read red while
#     visibly clear of each other.
#
# So: one measurement, two consumers, and it cannot drift again.
#
# THE REPRESENTATION IS A LIST OF PARALLELEPIPEDS, not one box. A module is
# routinely several meshes with very different extents - a gun is a short fat
# receiver plus a long thin barrel plus a pintle - and merging them into a
# single box re-introduces most of the error this file exists to remove. Each
# entry is one MeshInstance3D's own local AABB carried into module space by its
# accumulated parent chain, stored as a centre plus three HALF-EDGE VECTORS.
# Half-edges rather than an axis+extent pair because a nested non-uniform scale
# (locomotion builders do this constantly) shears the box: it stays a
# parallelepiped, but its edges stop being perpendicular, and every axis-and-
# extent formulation silently assumes they are.

# Overlay subtrees that are drawn but are NOT part of the module. Matched
# against the mesh's own name AND every node between it and the module root,
# because these are containers: "ArcCone" holds unnamed wedge meshes and
# "Gizmo3D" holds handle meshes all named plain "MeshInstance3D".
#
# This unifies two filters that had drifted apart - module_placer's
# _find_meshes_recursive() skipped the SUBTREES but visual_builder's
# measure_visual_bounds() only matched the MESH's own name, so a module that
# happened to be selected measured its own gizmo handles into its click
# collider (the handles sit out at the module's extents, so the box grew by
# roughly the handle offset in every direction the moment you clicked it).
const OVERLAY_PREFIXES := ["Gizmo3D", "ArcCone", "FiringArc", "BarrierShield", "DamageFX", "SelectedHighlight"]
# DamageFX is the runtime battle-damage overlay (module_damage_fx.gd: smoke
# leak emitter plus cracked stencil cards). It draws ON the module but must not
# measure AS the module - its sticker quads would otherwise fatten click
# colliders and ride-height solves for any module damaged mid-battle.

# Cached on the module node. Invalidated by VisualBuilder.build_visual(), which
# is the only thing that changes a module's geometry - tweak drags, struct_scale
# resizes and sponson blister rebuilds all route through it.
const META_BOXES := "_module_volume_boxes"

# Past this many meshes a module collapses to its single merged box. Nothing in
# the catalog comes close (a 4-barrel cannon is ~9, a multi-axle wheel set ~16),
# so this is a backstop against a future builder emitting hundreds of greebles
# and turning the O(n*m) narrow phase below into a frame-rate problem, not a
# limit anyone should be designing against.
const MAX_BOXES := 24

# How far each box is pulled in before the overlap test, in metres. Parts are
# MEANT to touch - a gun sits ON the deck, armour lies flush against a facet -
# so a test with no tolerance calls every correctly-mounted module a clip. This
# replaces the old AABB.grow(-0.05) and keeps the same 5cm feel, but applies it
# along each box's OWN axes instead of the world's.
const DEFAULT_MARGIN := 0.05

# A shrink never removes more than 95% of an axis. A 2cm-thick armour plate
# would otherwise vanish entirely at a 5cm margin and stop registering any
# overlap at all, which reads as "modules pass straight through plating".
const MIN_SHRINK_FRACTION := 0.05


## The module's visible geometry as parallelepipeds in the module's OWN local
## space, so the result is independent of where the module currently sits and
## can be cached across drags. Each entry is
## {"c": Vector3, "h0": Vector3, "h1": Vector3, "h2": Vector3}.
static func boxes(module: Node3D) -> Array:
	if module == null or not is_instance_valid(module):
		return []
	if module.has_meta(META_BOXES):
		return module.get_meta(META_BOXES)
	var collected := _collect(module)
	module.set_meta(META_BOXES, collected)
	return collected


## The boxes the CLIP test should use: the measured ones, or - for a module that
## draws nothing at all - a single box of its catalog size.
##
## The fallback is not hypothetical. VisualBuilder.build_module() has an
## explicit branch for a part whose .glb is missing AND whose procedural
## fallback produced nothing, and a module stub built by hand (several tests do
## exactly this: a Node3D carrying only the module_data meta) has no meshes
## either. Measuring returns nothing for both, and "no geometry, therefore
## overlaps nothing" is the wrong answer for a thing that still occupies a
## mount point - it silently makes the module transparent to the one check that
## is supposed to stop parts sharing a space.
##
## Kept OUT of boxes()/bounds() deliberately. Those two define what the module
## DRAWS, and several callers rely on an empty result meaning exactly that -
## blueprint_manager's ground-contact pass skips a locomotion module with no
## measurable bounds rather than seating the hull on a phantom catalog box, and
## _refit_module_collider leaves a click target alone rather than resizing it to
## something invisible. Only the overlap test wants the substitute.
static func clip_boxes(module: Node3D) -> Array:
	var measured := boxes(module)
	if not measured.is_empty():
		return measured
	var size := _catalog_size(module)
	if size.length_squared() <= 0.0:
		return []
	var half: Vector3 = size * 0.5
	return [{
		"c": Vector3.ZERO,
		"h0": Vector3(half.x, 0, 0),
		"h1": Vector3(0, half.y, 0),
		"h2": Vector3(0, 0, half.z),
	}]


# Runtime load rather than a preload, matching mesh_asset_loader's own
# _primitive_shape_for(): module_catalog.gd sits upstream of this file in the
# preload graph (visual_builder preloads both), so a preload here would close a
# cycle. Only ever reached on the no-geometry path, so the lookup cost is paid
# by nothing that runs per frame.
static var _catalog_script = null

static func _catalog_size(module: Node3D) -> Vector3:
	if module == null or not module.has_meta("module_data"):
		return Vector3.ZERO
	var data = module.get_meta("module_data")
	if data == null or not ("type_id" in data):
		return Vector3.ZERO
	if _catalog_script == null:
		_catalog_script = load("res://scripts/module_catalog.gd")
	if _catalog_script == null:
		return Vector3.ZERO
	return _catalog_script.get_module_data(data.type_id).get("size", Vector3.ZERO)


## Drop the cached measurement. Called by VisualBuilder.build_visual() on entry;
## anything else that adds or moves a module's meshes by hand must call it too.
static func invalidate(module: Node3D) -> void:
	if module == null or not is_instance_valid(module):
		return
	if module.has_meta(META_BOXES):
		module.remove_meta(META_BOXES)


## The tight AABB of everything the module draws, in its own local space. This
## is what VisualBuilder.measure_visual_bounds() now returns - kept as a
## separate entry point because ride-height and click-collider callers want the
## single box, not the list.
static func bounds(module: Node3D) -> AABB:
	return merged_aabb(boxes(module))


## The same bounds carried into some parent frame - hull space, usually.
##
## Measured geometry only, like bounds(): a caller asking where a module's
## drawn extent lands in hull space is asking about what is on screen. The clip
## test does NOT use this - it derives its broad-phase AABB from the very box
## list its narrow phase walks, so a module falling back to its catalog box
## cannot be rejected by an empty measured AABB it never used.
static func bounds_in_frame(module: Node3D, xf: Transform3D) -> AABB:
	var out: Array = []
	for b in boxes(module):
		out.append(to_frame(b, xf))
	return merged_aabb(out)


## Calculates the module's center of mass (volume-weighted geometric center)
## in the module's own local space. Weights each constituent mesh box by its
## volume so large bodies (receivers, main chassis) dominate over thin barrels/greebles.
static func center_of_mass(module: Node3D) -> Vector3:
	if module == null or not is_instance_valid(module):
		return Vector3.ZERO
	var b_list := boxes(module)
	if b_list.is_empty():
		return Vector3.ZERO
	var total_vol := 0.0
	var weighted_pos := Vector3.ZERO
	for b in b_list:
		var h0: Vector3 = b.get("h0", Vector3.ZERO)
		var h1: Vector3 = b.get("h1", Vector3.ZERO)
		var h2: Vector3 = b.get("h2", Vector3.ZERO)
		var l0 := h0.length()
		var l1 := h1.length()
		var l2 := h2.length()
		var vol := 8.0 * l0 * l1 * l2
		if vol <= 0.000001:
			vol = 0.001
		var c: Vector3 = b.get("c", Vector3.ZERO)
		weighted_pos += c * vol
		total_vol += vol
	if total_vol > 0.0:
		return weighted_pos / total_vol
	return merged_aabb(b_list).get_center()


## Calculates the module's center of mass in world space.
static func center_of_mass_world(module: Node3D) -> Vector3:
	if module == null or not is_instance_valid(module):
		return Vector3.ZERO
	return module.global_transform * center_of_mass(module)


# --- Overlap ------------------------------------------------------------------

## Do two modules' visible meshes actually intersect?
##
## `a_xf` / `b_xf` are each module's transform in a SHARED frame (hull space for
## placed modules; see module_placer.is_ghost_clipping for the drag ghost, which
## lives under MainLab and has to be converted first). Passed explicitly rather
## than read off the nodes so the ghost - which is not a child of the hull - can
## use the identical test as everything else.
##
## Broad phase first: merged AABBs, no margin, so it can only ever be more
## permissive than the narrow phase and never rejects a real overlap. That keeps
## the O(boxes_a * boxes_b) separating-axis work off the ~95% of module pairs
## that are nowhere near each other, which is what makes this affordable on
## every drag tick.
static func overlaps(a_module: Node3D, a_xf: Transform3D,
		b_module: Node3D, b_xf: Transform3D,
		margin: float = DEFAULT_MARGIN) -> bool:
	var fa := _frame_boxes(a_module, a_xf, margin)
	if fa.is_empty():
		return false
	var fb := _frame_boxes(b_module, b_xf, margin)
	if fb.is_empty():
		return false
	if not merged_aabb(fa).intersects(merged_aabb(fb)):
		return false
	for x in fa:
		for y in fb:
			if _pair_overlaps(x, y):
				return true
	return false


## Narrow-phase test for two boxes ALREADY carried into a shared frame,
## applying the contact margin to both. The drag ghost needs this because it
## assembles its box list by hand (it may have no measurable geometry yet and
## fall back to a catalog-sized box), so it cannot go through overlaps().
static func pair_overlaps_with_margin(a: Dictionary, b: Dictionary,
		margin: float = DEFAULT_MARGIN) -> bool:
	return _pair_overlaps(_shrink(a, margin), _shrink(b, margin))


static func _frame_boxes(module: Node3D, xf: Transform3D, margin: float) -> Array:
	var out: Array = []
	for b in clip_boxes(module):
		out.append(_shrink(to_frame(b, xf), margin))
	return out


## Separating-axis test for two parallelepipeds.
##
## 15 candidate axes: three face normals each (the CROSS of the other two
## half-edges, not the half-edge itself - for a sheared box those are different
## vectors and using the edge gives false separations), plus the nine
## edge-pair crosses. Degenerate axes (a flat mesh's zero-length half-edge, or
## two parallel edges crossing to zero) are skipped rather than normalised.
static func _pair_overlaps(a: Dictionary, b: Dictionary) -> bool:
	var a0: Vector3 = a["h0"]
	var a1: Vector3 = a["h1"]
	var a2: Vector3 = a["h2"]
	var b0: Vector3 = b["h0"]
	var b1: Vector3 = b["h1"]
	var b2: Vector3 = b["h2"]
	var d: Vector3 = (b["c"] as Vector3) - (a["c"] as Vector3)

	var axes: Array = [
		a1.cross(a2), a2.cross(a0), a0.cross(a1),
		b1.cross(b2), b2.cross(b0), b0.cross(b1),
		a0.cross(b0), a0.cross(b1), a0.cross(b2),
		a1.cross(b0), a1.cross(b1), a1.cross(b2),
		a2.cross(b0), a2.cross(b1), a2.cross(b2),
	]
	for axis in axes:
		var n: Vector3 = axis
		if n.length_squared() < 0.000000000001:
			continue
		var ra := absf(a0.dot(n)) + absf(a1.dot(n)) + absf(a2.dot(n))
		var rb := absf(b0.dot(n)) + absf(b1.dot(n)) + absf(b2.dot(n))
		if absf(d.dot(n)) > ra + rb:
			return false
	return true


# --- Box maths ----------------------------------------------------------------

static func to_frame(b: Dictionary, xf: Transform3D) -> Dictionary:
	return {
		"c": xf * (b["c"] as Vector3),
		"h0": xf.basis * (b["h0"] as Vector3),
		"h1": xf.basis * (b["h1"] as Vector3),
		"h2": xf.basis * (b["h2"] as Vector3),
	}


static func _shrink(b: Dictionary, margin: float) -> Dictionary:
	if margin <= 0.0:
		return b
	var out := {"c": b["c"]}
	for key in ["h0", "h1", "h2"]:
		var h: Vector3 = b[key]
		var l := h.length()
		if l <= 0.0001:
			out[key] = h
		else:
			out[key] = h * (maxf(l - margin, l * MIN_SHRINK_FRACTION) / l)
	return out


## The enclosing AABB of a box list, in whatever frame the boxes are already in.
## The half-edge form makes this exact: a parallelepiped's enclosing box is its
## centre plus the componentwise sum of the absolute half-edges.
static func merged_aabb(box_list: Array) -> AABB:
	var seen := false
	var out := AABB()
	for b in box_list:
		var e: Vector3 = (b["h0"] as Vector3).abs() \
			+ (b["h1"] as Vector3).abs() \
			+ (b["h2"] as Vector3).abs()
		var part := AABB((b["c"] as Vector3) - e, e * 2.0)
		out = part if not seen else out.merge(part)
		seen = true
	return out if seen else AABB()


# --- Measurement --------------------------------------------------------------

static func _collect(module: Node3D) -> Array:
	var out: Array = []
	for mesh_inst in module.find_children("*", "MeshInstance3D", true, false):
		if mesh_inst.mesh == null:
			continue
		if _is_overlay(mesh_inst, module):
			continue
		var aabb: AABB = mesh_inst.mesh.get_aabb()
		if aabb.size.length_squared() <= 0.0:
			continue
		# Walks up through intermediate pivots deliberately: locomotion builders
		# nest parts under named pivots (rotor hubs, leg knees) that carry real
		# offsets, so a mesh's own AABB means nothing without them.
		var xf := Transform3D.IDENTITY
		var walker: Node = mesh_inst
		while walker != null and walker != module:
			if walker is Node3D:
				xf = (walker as Node3D).transform * xf
			walker = walker.get_parent()
		var half: Vector3 = aabb.size * 0.5
		out.append({
			"c": xf * aabb.get_center(),
			"h0": xf.basis.x * half.x,
			"h1": xf.basis.y * half.y,
			"h2": xf.basis.z * half.z,
		})
	if out.size() > MAX_BOXES:
		var merged := merged_aabb(out)
		var mh: Vector3 = merged.size * 0.5
		out = [{
			"c": merged.get_center(),
			"h0": Vector3(mh.x, 0, 0),
			"h1": Vector3(0, mh.y, 0),
			"h2": Vector3(0, 0, mh.z),
		}]
	return out


static func _is_overlay(mesh_inst: Node, module: Node) -> bool:
	var walker: Node = mesh_inst
	while walker != null and walker != module:
		for prefix in OVERLAY_PREFIXES:
			if walker.name.begins_with(prefix):
				return true
		walker = walker.get_parent()
	return false


# --- Collision shapes ---------------------------------------------------------

## Populates `body` with one BoxShape3D per volume box, so a collider matches
## the silhouette instead of swallowing it in a single envelope. Clears any
## CollisionShape3D children it finds first, so it is safe to call repeatedly.
##
## `margin` GROWS each shape here rather than shrinking it - the clip test wants
## to be forgiving about contact, a hit volume wants to err towards catching the
## shot that visibly connected. Pass 0.0 for an exact fit.
##
## `max_shapes` collapses the module to its single merged box rather than
## emitting more than that many. A spawned unit pays for these in the physics
## server for its whole life and a match can hold a hundred units, so a
## sixteen-mesh multi-axle wheel set is not worth sixteen shapes - the win is in
## going from "one envelope around the whole gun" to "receiver, pintle, barrel",
## and that is already had at three or four. Most weapons need no cap at all:
## a monolithic authored .glb is a single MeshInstance3D.
##
## Returns the number of shapes added.
static func build_collision_shapes(module: Node3D, body: CollisionObject3D,
		margin: float = 0.0, max_shapes: int = 0) -> int:
	if module == null or body == null:
		return 0
	for child in body.get_children():
		if child is CollisionShape3D:
			body.remove_child(child)
			child.queue_free()
	var source := boxes(module)
	if max_shapes > 0 and source.size() > max_shapes:
		var merged := merged_aabb(source)
		var mh: Vector3 = merged.size * 0.5
		source = [{
			"c": merged.get_center(),
			"h0": Vector3(mh.x, 0, 0),
			"h1": Vector3(0, mh.y, 0),
			"h2": Vector3(0, 0, mh.z),
		}]
	var added := 0
	for b in source:
		var h0: Vector3 = b["h0"]
		var h1: Vector3 = b["h1"]
		var h2: Vector3 = b["h2"]
		# BoxShape3D is axis-aligned in its own node's space, so the box's own
		# orientation has to go on the CollisionShape3D's basis. Normalised
		# because the shape carries the extent as `size`; leaving the scale in
		# the basis would apply it twice.
		var l0 := h0.length()
		var l1 := h1.length()
		var l2 := h2.length()
		if l0 <= 0.0001 or l1 <= 0.0001 or l2 <= 0.0001:
			continue
		var basis := Basis(h0 / l0, h1 / l1, h2 / l2)
		var shape := BoxShape3D.new()
		shape.size = Vector3(l0, l1, l2) * 2.0 + Vector3(margin, margin, margin) * 2.0
		var col := CollisionShape3D.new()
		col.shape = shape
		col.transform = Transform3D(basis, b["c"])
		body.add_child(col)
		added += 1
	return added
