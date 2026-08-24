extends RefCounted
class_name MountReach
# Solves how long a piece of mounting hardware has to be to actually reach the
# hull, instead of being a fixed length that is wrong on most hulls.
#
# Chris, 2026-08-12: "the current running gear that is manufactured, is all a set
# length. Can we change that so that the length gets modified on build to reach
# the skin of the hull, and then extend like 0.05 more in-game units so that it
# intersects and reads as attached? This would help the wheels axles not poke up
# through small hulls, and the hover pads brackets the same way, and help the
# helicopter rotors mounting hardware actually reach the hull."
#
# Those are the same bug twice, in opposite directions. A strut authored at a
# length that looked right on the reference hull (4 x 1 x 6) is too LONG on a
# small hull, where it punches out through the roof, and too SHORT on a large or
# oddly-proportioned one, where it stops in mid-air. Seating the station onto the
# real chine fixed where hardware STARTS; this fixes how far it goes.
#
# THE RULE, one line: cast from the gear end toward the hull, and make the member
# exactly long enough to hit the skin plus OVERLAP. The overlap is what makes it
# read as attached rather than butted - a member that stops exactly on the
# surface shows a seam under any camera angle, and one that stops short shows
# daylight.
#
# WHY A RAYCAST AND NOT MORE PUBLISHED SCALARS. locomotion_mount.gd could compute
# a reach per station and hand it over as a float, and an early sketch did. It
# does not survive contact with the types: a wheel driveshaft runs up and inboard
# at 55 degrees, a rotor pylon runs straight down, a hover-pad standoff runs
# straight up, a track strut runs horizontally inboard. Each needs the distance
# along ITS OWN axis, so the only thing that generalises is the query, not the
# answer. Builders ask their own question here.

const HullProjectionScript = preload("res://scripts/hull_projection.gd")

## Extra distance past the skin, in world units, so the member visibly bites into
## the hull instead of touching it. Chris's number.
const OVERLAP: float = 0.05

## Cast this far. Any hull is comfortably inside this, and a miss is cheap.
const MAX_DISTANCE: float = 100.0

## Surfaces are cached per hull mesh for the duration of a build pass. Rebuilding
## the triangle list per module would re-walk and re-transform the whole hull mesh
## once per wheel, and the Design Lab rebuilds every instance on every tweak drag
## frame. Keyed on the Mesh resource's id, which is stable for as long as the hull
## keeps that mesh and changes the moment it does not.
static var _surface_cache: Dictionary = {}
static var _active_surface: Dictionary = {}


static func _find_mesh_instance(node: Node) -> MeshInstance3D:
	if node is MeshInstance3D and (node as MeshInstance3D).mesh != null:
		return node as MeshInstance3D
	for child in node.get_children():
		var mi := _find_mesh_instance(child)
		if mi != null:
			return mi
	return null


## Explicitly caches the surface of a hull being rebuilt.
static func cache_hull(hull: Node3D) -> void:
	if hull == null or not is_instance_valid(hull):
		return
	var mesh_inst := _find_mesh_instance(hull)
	if mesh_inst == null or mesh_inst.mesh == null:
		return
	var key := mesh_inst.mesh.get_instance_id()
	if _surface_cache.has(key):
		_active_surface = _surface_cache[key]
		return
	var surface: Dictionary = HullProjectionScript.build_surface(hull)
	if (surface.get("tris", PackedVector3Array()) as PackedVector3Array).size() >= 3:
		_surface_cache[key] = surface
		_active_surface = surface


## Drops every cached surface. Called by locomotion_mount.gd at the start of a
## rebuild so a hull that was rescaled or swapped is never measured against the
## triangles it used to have.
static func clear_cache() -> void:
	_surface_cache.clear()
	_active_surface.clear()


## Length, in the module's own local units, that a member starting at
## `from_local` and running along `dir_local` must have to reach the hull skin and
## bite OVERLAP into it.
##
## Returns `fallback` when there is no hull to measure or the ray misses - a miss
## is a legitimate result (a station outboard of a hull that curves away, an
## airborne type nowhere near the body), and every caller keeps its authored
## length in that case rather than collapsing to zero.
##
## `module` must be the locomotion module node, parented to the hull. `station` is
## the module's FINAL hull-local position, passed in rather than read off the node
## because at build time the node may still be carrying _place_weapon()'s
## grid-snapped position - locomotion_mount.gd overwrites it with the seated one
## immediately afterwards, but the visual is built in between.
##
## `node_scale` is the scale the module WILL be given after the build. Lengths are
## authored in unscaled module space and scaled with the node afterwards, so the
## hull-space distance has to be divided back through it or every member on a
## non-uniformly scaled type comes out wrong by that factor.
static func solve(module: Node3D, station: Vector3, from_local: Vector3,
		dir_local: Vector3, fallback: float, node_scale: Vector3 = Vector3.ONE,
		overlap: float = OVERLAP) -> float:
	if dir_local.length_squared() < 1e-12:
		return fallback
	var surface := surface_for(module)
	if surface.is_empty():
		return fallback

	var side_sign := signf(station.x)
	if is_zero_approx(side_sign):
		side_sign = 1.0
	var eff_from := Vector3(from_local.x * side_sign, from_local.y, from_local.z)
	var eff_dir := Vector3(dir_local.x * side_sign, dir_local.y, dir_local.z)

	# One unit along dir_local in module space is |v| units in hull space. That
	# factor is what converts the measured distance back into the units the
	# builder is authoring in.
	var v := eff_dir * node_scale
	var v_len := v.length()
	if v_len < 1e-9:
		return fallback

	var from_hull := station + eff_from * node_scale
	var hit: Dictionary = HullProjectionScript.raycast(surface, from_hull, v / v_len)
	if not hit.get("hit", false):
		return fallback
	var dist: float = from_hull.distance_to(hit["position"])
	return (dist + overlap) / v_len


## The hull's triangle surface, in hull-local space, for the hull `module` hangs
## off. Empty when the module is not parented to a hull with a mesh yet.
static func surface_for(module: Node3D) -> Dictionary:
	if module != null and is_instance_valid(module):
		var hull := module.get_parent() as Node3D
		if hull != null:
			var mesh_inst := _find_mesh_instance(hull)
			if mesh_inst != null and mesh_inst.mesh != null:
				var key := mesh_inst.mesh.get_instance_id()
				if _surface_cache.has(key):
					return _surface_cache[key]
				var surface: Dictionary = HullProjectionScript.build_surface(hull)
				if (surface.get("tris", PackedVector3Array()) as PackedVector3Array).size() >= 3:
					_surface_cache[key] = surface
					return surface
	return _active_surface


## Reads the station position a builder was handed. locomotion_mount.gd publishes
## it as three floats for the reason given on solve().
static func station_from(tweaks: Dictionary) -> Vector3:
	return Vector3(
		float(tweaks.get("station_x", 0.0)),
		float(tweaks.get("station_y", 0.0)),
		float(tweaks.get("station_z", 0.0)))


## The node scale a builder's output will be given after it returns.
static func node_scale_from(tweaks: Dictionary) -> Vector3:
	return Vector3(
		float(tweaks.get("node_scale_x", 1.0)),
		float(tweaks.get("node_scale_y", 1.0)),
		float(tweaks.get("node_scale_z", 1.0)))
