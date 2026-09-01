extends RefCounted
class_name HullGreebles
# Faction-specific decorative hull attachments - cheap, non-collidable
# geometry that may extend PAST the hull's real mesh/collision silhouette on
# purpose (a deliberate, faction-specific exception to the "goofy lives in
# detail-scale, never silhouette-scale" rule in VISUAL_ART_DIRECTION.md 1.2).
#
# ONE faction is treated: dune_runners get water barrels lashed along the
# flanks. Every other faction's apply_greebles() call is a no-op - an empty
# "HullGreebles" container with zero children.
#
# This file used to be an alpha-cutout CARD system: flat QuadMeshes with a
# procedurally-generated alpha-scissor texture, giving salvage_union scrap
# antennas, bayou_irregulars camo netting, crimson_concordat pennants and
# aerodrome_cartel tailfins. All of it was removed on 2026-08-31 - see the
# note in apply_greebles() for why. What survives is deliberately SOLID
# geometry, which is the same conclusion terrain_greebles.gd reached
# independently for terrain scatter: at an RTS camera distance a flat card
# reads as a coloured plane, and a cylinder reads as an object.

const HullProjectionScript = preload("res://scripts/hull_projection.gd")

static func _surface_for(hull: Node3D, hull_size: Vector3) -> Dictionary:
	var surface = HullProjectionScript.build_surface(hull)
	if surface["tris"].size() < 3:
		surface["aabb"] = AABB(-hull_size * 0.5, hull_size)
	return surface

static func _extents(surface: Dictionary, hull_size: Vector3) -> Vector3:
	if surface["tris"].size() >= 3:
		return (surface["aabb"] as AABB).size
	return hull_size

# Removes any previously-attached greebles (so faction changes in the
# Design Lab don't accumulate duplicates) and rebuilds from scratch. A
# no-op container (zero children) for every faction but dune_runners.
static func apply_greebles(hull: Node3D, faction: String, hull_size: Vector3):
	var old = hull.get_node_or_null("HullGreebles")
	if old:
		hull.remove_child(old)
		old.queue_free()
	var container = Node3D.new()
	container.name = "HullGreebles"
	hull.add_child(container)

	# Built once and shared by every builder - gathering the hull's triangles is
	# the expensive part, and all five treated factions project against the
	# same skin.
	var surface = _surface_for(hull, hull_size)
	var comp = HullProjectionScript.attach_compensation(hull)
	container.scale = comp["container_scale"]
	surface["position_scale"] = comp["position_scale"]

	# ALPHA-CUTOUT CARDS REMOVED, 2026-08-31 (Chris: "they render oddly on
	# almost everything and don't add anything really").
	#
	# Four factions used to get flat QuadMesh greebles built from a generated
	# alpha-scissor cutout - salvage_union scrap antennas, bayou_irregulars camo
	# netting, crimson_concordat pennants, aerodrome_cartel tailfins. Being flat
	# cards with cull_mode DISABLED, they read as untextured coloured planes the
	# moment they are seen anywhere near edge-on, and they take the hull's
	# livery colour, so a saturated scheme turned them into bright flat sheets
	# sticking out of the silhouette. The whole cutout subsystem
	# (_get_cutout_texture, the four _draw_* generators, _make_cutout_material,
	# _add_card, _project_card, _drape and the four builders) went with them.
	#
	# dune_runners' water barrels stay: they are real cylinders, not cards, and
	# terrain_greebles.gd's header calls them out as the example of the
	# solid-geometry approach that works at an RTS camera distance.
	match faction:
		"dune_runners": _build_barrels(container, hull_size, surface)
		_: pass # every other faction stays clean - no greebles at all
static func _build_barrels(container: Node3D, hull_size: Vector3, surface: Dictionary):
	var wood_color = Color(0.45, 0.32, 0.16)
	var band_color = Color(0.22, 0.19, 0.16)
	var ext = _extents(surface, hull_size)
	var radius = ext.y * 0.26
	var length = ext.y * 1.0
	for side in [-1.0, 1.0]:
		var barrel = MeshInstance3D.new()
		var cyl = CylinderMesh.new()
		cyl.top_radius = radius
		cyl.bottom_radius = radius
		cyl.height = length
		barrel.mesh = cyl
		var mat = StandardMaterial3D.new()
		mat.albedo_color = wood_color
		mat.roughness = 0.85
		barrel.material_override = mat
		container.add_child(barrel)
		# Lashed to the REAL flank: project inward from the side to find where
		# the hull skin actually is at this height, then sit the barrel just
		# outside it by its own radius. A tapered or curved flank now gets its
		# barrels tucked against it instead of held out at the bounding box.
		var flank = HullProjectionScript.project(surface,
			Vector3(0.5 + side * 0.5, 0.4, 0.56), Vector3(side, 0.0, 0.0))
		barrel.position = (flank["position"] + (flank["normal"] as Vector3) * radius * 0.85) \
			* surface.get("position_scale", Vector3.ONE)
		barrel.rotation_degrees = Vector3(90, 0, 0) # lying on its side, axis running fore-aft along the hull's flank
		for band_offset in [-0.32, 0.32]:
			var band = MeshInstance3D.new()
			var torus = TorusMesh.new()
			torus.inner_radius = radius * 0.92
			torus.outer_radius = radius * 1.08
			band.mesh = torus
			var band_mat = StandardMaterial3D.new()
			band_mat.albedo_color = band_color
			band_mat.roughness = 0.6
			band.material_override = band_mat
			barrel.add_child(band)
			# No extra rotation needed - band is a CHILD of barrel, so it
			# already inherits barrel's 90-degree tip via the parent
			# transform; in barrel's own local space the cylinder's axis is
			# still local Y, exactly matching TorusMesh's default normal.
			band.position = Vector3(0, length * band_offset, 0)
