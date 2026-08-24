extends RefCounted
class_name LocomotionMount
# Mounts a locomotion set onto a hull. Extracted wholesale from
# module_placer.gd's update_locomotion(), which had grown to ~490 lines inside a
# 3,094-line node script that also owned undo/redo, input handling, weapon
# placement, firing arcs, clipping and a hand-built dialog.
#
# WHAT CHANGED IN THE EXTRACTION, beyond moving code
#
# Every station used to be positioned from the hull's fitted collision BOX and
# handed straight to _place_weapon(). Now each one is SEATED: the analytic
# station the layout produces is treated as an intent ("fourth axle, starboard,
# 62% aft"), and HullChine converts it into a point on the hull's actual mesh at
# the turn of the bilge. See hull_chine.gd for why the chine specifically.
#
# Measured across the whole roster before this landed: the box corner every
# station was derived from sat a mean of 0.335 units - max 2.09 - away from the
# hull's real lower edge. That distance was the gap.
#
# THE GRID SNAP IS BYPASSED FOR SEATED STATIONS, and that is load-bearing.
# _place_weapon() snaps a placement to a 0.25m grid, which is right for a player
# dragging a turret onto a facet and catastrophic for a point that was just
# solved to lie exactly on a curved surface: snapping it would put it back off
# the skin by up to 0.125 in each axis and reintroduce the gap this whole pass
# exists to remove. The layout already had an `override_pos` flag for wheels and
# legs, for a related reason (a snapped wheel row visibly steps in and out); a
# seated station always overrides, because mesh truth and a grid are mutually
# exclusive by construction.

const ModuleCatalog = preload("res://scripts/module_catalog.gd")
const LocomotionLayoutScript = preload("res://scripts/locomotion_layout.gd")
const HullChineScript = preload("res://scripts/hull_chine.gd")
const MountReachScript = preload("res://scripts/mount_reach.gd")

## Types whose running gear is a continuous belt wrapping road wheels, rather
## than a discrete unit hung off a mount.
##
## These do not sit ON the chine the way a wheel station does. Chris, 2026-08-12:
## "The treaded tracks need to be much lower so the treads actually are below the
## hull, AND to the side." That is correct for what a track IS - the belt has to
## clear the hull's belly to reach the ground and clear its flank so the sprockets
## are not buried in the side - so the chine is the reference these are measured
## FROM, not the point they sit at.
const BELT_TYPES := ["tracked_treads", "half_track", "heavy_quad_tracks"]

## How far a belt stands outboard of the hull's widest point as a fraction of
## hull width so the track clears the flank.
const BELT_OUTBOARD_CLEAR_FRAC: float = 0.04


## A station this close to the centreline has no flank to seat against - it is a
## belly or spine mount (the odd pod in SIDE_PODS, the single FOOTPRINT station)
## and it keeps its analytic position.
const CENTRELINE_EPS: float = 0.001

## Keys written into each station's `geo` dict so the mesh builders receive the
## measured mount frame through the tweaks channel they already read. Named as
## constants because they are a contract between this file and visual_builder.gd
## and a typo in either half fails silently as a 0.0 default.
const GEO_SEATED := "chine_seated"
const GEO_NORMAL_X := "chine_normal_x"
const GEO_NORMAL_Y := "chine_normal_y"
const GEO_UP_X := "chine_up_x"
const GEO_UP_Y := "chine_up_y"
const GEO_FLANK_HEIGHT := "chine_flank_height"
const GEO_BELLY_DROP := "chine_belly_drop"
const GEO_HALF_WIDTH := "chine_half_width"
const GEO_CLEAR_X := "chine_clear_x"

## The station's final hull-local position and the scale the node will be given,
## published so a builder can solve its own member lengths against the hull via
## MountReach. Both are needed because the visual is built BEFORE either is
## applied to the node - _place_weapon() creates the node with a grid-snapped
## position and unit scale, and this file corrects both immediately afterwards.
const GEO_STATION_X := "station_x"
const GEO_STATION_Y := "station_y"
const GEO_STATION_Z := "station_z"
const GEO_NODE_SCALE_X := "node_scale_x"
const GEO_NODE_SCALE_Y := "node_scale_y"
const GEO_NODE_SCALE_Z := "node_scale_z"


## Rebuilds the hull's entire locomotion set as `type_id`.
##
## `placer` is the Design Lab root (module_placer.gd). This takes the node rather
## than being wholly static because placement itself - collider sizing, mirror
## flips, clipping - is genuinely the placer's job and dragging those along would
## have meant moving half the file. The seam is narrow and explicit: the six
## members listed in _placer_ready() are the entire surface this depends on.
static func rebuild(placer: Node3D, type_id: String, settings: Dictionary) -> Array:
	if not _placer_ready(placer):
		return []
	var hull: Node3D = placer.hull
	hull.set_meta("locomotion_type", type_id)
	hull.set_meta("locomotion_settings", settings)

	clear(placer)
	# The hull may have been rescaled or swapped since the last rebuild, so any
	# cached triangle surface is stale by definition.
	MountReachScript.clear_cache()
	MountReachScript.cache_hull(hull)

	var catalog_data: Dictionary = ModuleCatalog.get_module_data(type_id)
	var hull_size := _hull_box(hull)
	var hull_scale: Vector3 = hull.get_meta("hull_scale") if hull.has_meta("hull_scale") \
		else Vector3.ONE

	# See module_placer.gd's original note: running_gear_size stays a zero vector
	# rather than being deleted, because several layout patterns still read it and
	# zeroing it is what tells them there is nothing under the hull.
	var running_gear_size := Vector3.ZERO

	var underside_y_bias := 0.0
	if hull.has_meta("type_id"):
		underside_y_bias = ModuleCatalog.get_underside_y_bias(hull.get_meta("type_id"))

	var hull_height_factor: float = clampf(
		hull_size.y / ModuleCatalog.REFERENCE_HULL_SIZE.y, 0.45, 2.25)
	var hull_footprint_factor: float = clampf(sqrt(
		(hull_size.x * hull_size.z)
		/ (ModuleCatalog.REFERENCE_HULL_SIZE.x * ModuleCatalog.REFERENCE_HULL_SIZE.z)),
		0.45, 2.25)

	# Solved once and shared by every station on this rebuild. HullChine memoises
	# each section it slices, so a paired pattern asking for the same z twice -
	# once per side, which is most of them - pays for the slice once.
	var profile: Dictionary = _chine_profile(hull)
	var aabb_mesh: AABB = profile.get("aabb", AABB())
	if aabb_mesh.size != Vector3.ZERO:
		hull_size = aabb_mesh.size * hull_scale
		hull_height_factor = clampf(hull_size.y / ModuleCatalog.REFERENCE_HULL_SIZE.y, 0.45, 2.25)
		hull_footprint_factor = clampf(sqrt(
			(hull_size.x * hull_size.z)
			/ (ModuleCatalog.REFERENCE_HULL_SIZE.x * ModuleCatalog.REFERENCE_HULL_SIZE.z)),
			0.45, 2.25)

	var seats_to_chine := _seats_to_chine(type_id)

	var layout_ctx := {
		"hull_size": hull_size,
		"running_gear_size": running_gear_size,
		"underside_y_bias": underside_y_bias,
		"catalog_size": catalog_data.get("size", Vector3.ONE),
	}
	var node_scale: Vector3 = LocomotionLayoutScript.node_scale_for(type_id,
		hull_height_factor, hull_footprint_factor)
	var scale_mult: Vector3 = LocomotionLayoutScript.scale_multiplier_for(type_id,
		hull_height_factor, hull_footprint_factor)

	var spawned: Array = []
	for station in LocomotionLayoutScript.stations(type_id, settings, layout_ctx):
		var local_pos: Vector3 = station["position"]
		var normal: Vector3 = station["normal"]
		var geo: Dictionary = station["geo"]
		var seated := false

		if seats_to_chine and absf(local_pos.x) > CENTRELINE_EPS \
				and HullChineScript.is_valid(profile):
			var frame: Dictionary = HullChineScript.mount_frame(
				profile, local_pos.z, signf(local_pos.x))
			if frame["found"]:
				local_pos = frame["position"]
				normal = frame["normal"]
				_write_frame_geo(geo, frame, bool(station["mirror"]))
				seated = true
				if type_id in BELT_TYPES:
					local_pos = _offset_belt(local_pos, frame, hull_size, profile, settings)

		# Published for every station, not just seated ones: an airborne type is
		# exactly the case that needs to solve its own reach DOWN to the hull, and
		# it is never seated.
		geo[GEO_STATION_X] = local_pos.x
		geo[GEO_STATION_Y] = local_pos.y
		geo[GEO_STATION_Z] = local_pos.z
		geo[GEO_NODE_SCALE_X] = node_scale.x
		geo[GEO_NODE_SCALE_Y] = node_scale.y
		geo[GEO_NODE_SCALE_Z] = node_scale.z

		var part: Node3D = placer._place_weapon(
			type_id, hull.global_position + local_pos, normal, false, geo)
		if part == null:
			continue

		part.scale = node_scale
		part.rotation = Vector3.ZERO
		# A seated station always overrides, for the grid-snap reason in the
		# header. An unseated one keeps the layout's own override flag.
		if seated:
			part.position = local_pos
		elif station["has_final_position"]:
			part.position = station["final_position"]

		if part.has_meta("module_data"):
			part.get_meta("module_data").scale_multiplier = scale_mult
		for meta_key in station["meta"]:
			part.set_meta(meta_key, station["meta"][meta_key])
		part.set_meta("chine_seated", seated)

		if station["mirror"]:
			part.set_meta("scale_flip_x", true)
			placer._apply_mirror_flip(part)
			# The mirror reflects each child's transform in module space, so
			# asymmetric geometry lands somewhere new and the collider measured
			# before that no longer matches what the player sees or clicks.
			placer._resize_collider_to_visual(part)
		spawned.append(part)

	_clamp_width(placer, type_id, spawned, hull_size)
	_seat_on_ground(placer, hull, type_id, spawned, hull_size, hull_scale, running_gear_size)

	for w in spawned:
		w.set_meta("locomotion_group", spawned)

	# Each _place_weapon() above already ran a clipping check, but at that point
	# locomotion_group was not yet set on any instance, so a same-group pair could
	# be flagged red by a stale mid-placement check and never re-evaluated.
	# Re-checking now, with the group exemption finally in place, clears the false
	# positive immediately instead of leaving it stuck until the next click.
	placer.check_all_clipping()
	if placer.get_tree():
		placer.get_tree().call_group("stat_ui", "update_stats", hull)
	return spawned


## Removes every locomotion module currently on the hull, and returns how many
## went.
##
## ONE MAIN CHASSIS PER HULL. This used to be an unnamed side effect of the
## rebuild loop - update_locomotion() freed all locomotion children before
## placing, so picking a second type silently replaced the first and nothing
## anywhere stated that as a rule. It is a rule (Chris, 2026-08-12: "The only
## enforcement should be one main locomotion chassis per hull"), so it is now a
## named operation with a single owner.
##
## Deliberately keyed on category == "locomotion" and not on a narrower "is this
## the main chassis" test. Secondary propulsion - the thing that would make this
## distinction meaningful - is not designed yet, and a speculative split here
## would be a guess baked into the one place that must not guess. When it lands,
## it gets its own category or a role field on the catalog entry, and this
## function grows a filter; nothing else has to move.
static func clear(placer: Node3D) -> int:
	if not is_instance_valid(placer.hull):
		return 0
	var removed := 0
	for child in placer.hull.get_children():
		if not child.has_meta("module_data"):
			continue
		if child.get_meta("module_data").category != "locomotion":
			continue
		child.queue_free()
		placer.hull.remove_child(child)
		removed += 1
	return removed


# --- Internals ---------------------------------------------------------------

## Moves a belt station off the chine: outboard past the hull's widest point and
## down past its lowest, so the track reads as running alongside and under the
## hull rather than embedded in its lower edge.
##
## Measured from the solved frame rather than from the bounding box, so it clears
## the geometry that is actually there - the gap to `half_width` is the hull's own
## bulge above the chine, and `belly_drop` is how much hull hangs below it. Both
## are zero on a slab-sided box and both matter on a chamfered or keeled one.
static func _offset_belt(pos: Vector3, frame: Dictionary, hull_size: Vector3, profile: Dictionary = {}, settings: Dictionary = {}) -> Vector3:
	var side: float = signf(pos.x)
	if is_zero_approx(side):
		side = 1.0
	var widest_x: float = float(frame.get("half_width", absf(pos.x)))
	var aabb: AABB = profile.get("aabb", AABB())
	if aabb.size != Vector3.ZERO:
		widest_x = maxf(widest_x, aabb.size.x * 0.5)
	var target_length: float = aabb.size.z if aabb.size != Vector3.ZERO else hull_size.z
	var belt_scale: float = target_length / 7.0
	var sprocket_scale: float = (0.46 * belt_scale) / 0.4
	var width_val: float = float(settings.get("tread_width", settings.get("width", settings.get("size", 1.0))))
	var sprocket_width: float = 0.3 * sprocket_scale * width_val
	var station_x: float = widest_x + sprocket_width + 0.02
	var out: float = station_x - absf(pos.x)
	return Vector3(pos.x + side * maxf(0.0, out), pos.y, pos.z)


static func _placer_ready(placer: Node3D) -> bool:
	return placer != null and is_instance_valid(placer.hull)


## The hull's fitted AABB from its actual visible mesh. Falls back to
## CollisionShape3D and then to the reference hull.
static func _hull_box(hull: Node3D) -> Vector3:
	var mesh_inst := MountReachScript._find_mesh_instance(hull)
	if mesh_inst and mesh_inst.mesh:
		var aabb: AABB = mesh_inst.get_aabb()
		if aabb.size.length_squared() > 0.001:
			var hscale: Vector3 = hull.get_meta("hull_scale") if hull.has_meta("hull_scale") else Vector3.ONE
			return aabb.size * hscale
	var shape := hull.get_node_or_null("CollisionShape3D")
	if shape and shape.shape is BoxShape3D:
		return (shape.shape as BoxShape3D).size
	return Vector3(ModuleCatalog.REFERENCE_HULL_SIZE)


static func _chine_profile(hull: Node3D) -> Dictionary:
	if hull == null:
		return {}
	return HullChineScript.build(hull)


## Whether this type's stations belong on the chine.
##
## Keyed on locomotion_touches_ground(), which is trait-derived (true for
## ground_contact and hovering, false for airborne / buoyant) and is already the
## predicate the ground-contact lift uses. That is exactly the right split:
## something that carries the vehicle's weight hangs off the lower hull and wants
## the bilge, while rotors, fixed wings, ornithopter shoulders and envelope pods
## mount above or around the hull and have no business being dragged down to it.
static func _seats_to_chine(type_id: String) -> bool:
	return ModuleCatalog.locomotion_touches_ground(type_id)


## Publishes the measured frame into the station's tweaks dict.
##
## Replaces the synthetic kit_reach / kit_anchor_* channel, which computed a
## reach of `-hull_size.y * 0.5 - station_y` - a distance to the bottom of the
## BOUNDING BOX. On any hull that is not a literal box that number was the size
## of the error, not the size of the gap, so a bracket built to span it finished
## in the wrong place. These values are measured off the mesh instead.
## WRITTEN IN CANONICAL STARBOARD FORM WHEN THE STATION WILL BE MIRRORED.
##
## ModuleMirror.apply() reflects every child of a mirrored module across local X
## (basis and origin both, determinant -1). The frame HullChine returns is already
## side-correct - chine_at() takes the side and hands back a port-form normal for
## a port station - so writing it verbatim on a mirrored station meant the
## reflection was applied to an already-reflected frame. The bracket came out
## pointing INBOARD and rendered buried inside the hull, which is why the port
## side showed no mounting blocks at all while the starboard side showed them
## sticking out.
##
## Flipping the X components here rather than teaching the builder about sides
## keeps chirality in exactly one place. The builder always receives an outboard
## normal in ITS OWN space, and whether that space is later reflected is the
## mirror system's business, not the geometry's.
static func _write_frame_geo(geo: Dictionary, frame: Dictionary, mirrored: bool) -> void:
	var n: Vector3 = frame["normal"]
	var up: Vector3 = frame["flank_up"]
	var xs := -1.0 if mirrored else 1.0
	geo[GEO_SEATED] = 1.0
	geo[GEO_NORMAL_X] = n.x * xs
	geo[GEO_NORMAL_Y] = n.y
	geo[GEO_UP_X] = up.x * xs
	geo[GEO_UP_Y] = up.y
	geo[GEO_FLANK_HEIGHT] = frame["flank_height"]
	geo[GEO_BELLY_DROP] = frame["belly_drop"]
	geo[GEO_HALF_WIDTH] = frame["half_width"]

	# HOW FAR OUTBOARD THE HULL STILL BULGES ABOVE THIS STATION.
	#
	# The chine is the widest point of the LOWER hull, not of the section: above
	# it a slab-sided or tumblehome hull keeps going out. Running gear placed at
	# the chine's own X is therefore tucked against the body - which is what put
	# the wheels hard up against the hull once seating replaced the old box
	# placement, because the box corner used to sit outboard of the mesh and was
	# accidentally providing the clearance.
	#
	# This is the amount a builder has to stand its gear off by to clear the
	# widest part of the hull above it. Zero on a hull whose chine IS its widest
	# point, so a slab-sided box is unaffected.
	var chine_x: float = absf((frame["position"] as Vector3).x)
	geo[GEO_CLEAR_X] = maxf(0.0, float(frame["half_width"]) - chine_x)


## Shrinks an assembly that reaches further outboard than its hull can justify.
##
## Unchanged in behaviour from the original; see the long note it carries. Scales
## about each station rather than moving stations, so the mount stays exactly
## where the layout - and now the chine solve - put it, and only the outboard
## reach comes in.
static func _clamp_width(placer: Node3D, type_id: String, spawned: Array,
		hull_size: Vector3) -> void:
	var width_limit: float = LocomotionLayoutScript.max_width_factor(type_id)
	if width_limit <= 0.0 or spawned.is_empty():
		return

	# OUTBOARD extent, not |x|: a part reaching INBOARD, toward the centreline,
	# is not sticking out sideways, and counting it as if it were is what made
	# the clamp fire on screw_drive's inboard driveshaft and shrink the whole
	# assembly uniformly.
	var mount_reach := 0.0
	var local_extent := 0.0
	for w in spawned:
		var wb: AABB = placer._visual_bounds(w)
		if wb.size.length_squared() <= 0.0:
			continue
		var out_sign: float = signf(w.position.x)
		if out_sign == 0.0:
			out_sign = 1.0
		mount_reach = maxf(mount_reach, absf(w.position.x))
		local_extent = maxf(local_extent, out_sign * wb.position.x * w.scale.x)
		local_extent = maxf(local_extent, out_sign * (wb.position.x + wb.size.x) * w.scale.x)
	local_extent = maxf(local_extent, 0.0)

	var allowed: float = hull_size.x * 0.5 * width_limit
	if mount_reach + local_extent <= allowed or local_extent <= 0.001:
		return
	# Never invert or vanish the part, even if the mount alone already exceeds
	# the budget - a sliver reads worse than a slight overhang.
	var shrink: float = clampf((allowed - mount_reach) / local_extent, 0.35, 1.0)
	for w in spawned:
		w.scale *= shrink
		if w.has_meta("module_data"):
			w.get_meta("module_data").scale_multiplier *= shrink
		placer._resize_collider_to_visual(w)


## Lifts the hull so the locomotion geometry rests on the ground plane.
##
## Unchanged in behaviour. Measures where the geometry ACTUALLY ends rather than
## assuming a chassis height, which is what made this correct for every type at
## once. Kept numerically identical to blueprint_manager.gd's matching block so a
## design sits at the same height in the Lab, the Test Range and a match.
static func _seat_on_ground(placer: Node3D, hull: Node3D, type_id: String,
		spawned: Array, hull_size: Vector3, hull_scale: Vector3,
		running_gear_size: Vector3) -> void:
	hull.position.y = (hull_size.y * hull_scale.y) / 2.0 + running_gear_size.y
	if not ModuleCatalog.locomotion_touches_ground(type_id):
		return
	var lowest := INF
	for w in spawned:
		var wb: AABB = placer._visual_bounds(w)
		if wb.size.length_squared() <= 0.0:
			continue
		lowest = minf(lowest, w.position.y + wb.position.y * w.scale.y)
	if lowest == INF:
		return
	# Floored at the hull's own half-height: locomotion that does not reach past
	# the hull's underside would otherwise sink the hull through the ground.
	# Measured from hull_size - the hull's own collision box, the same source
	# every station is derived from - and NOT from the catalog entry, which falls
	# back to a medium hull and once hoisted a 0.6-tall hull to a 0.9 floor.
	hull.position.y = maxf(-lowest, hull_size.y / 2.0)
