extends RefCounted
class_name TerrainGreebles
# Real 3D ground-clutter props scattered across surface_zones/shallow_water_
# areas - the terrain-scatter counterpart to hull_greebles.gd's faction
# detail cards. Deliberately uses real primitive geometry (cylinders, boxes,
# spheres), not hull_greebles.gd's flat alpha-cutout cards: an RTS camera
# orbits/pans around scattered ground clutter across a much wider range of
# viewing angles than it ever sees a hull silhouette from, and terrain
# already has real-geometry precedent (terrain_builder.gd's rock-cluster
# obstacles, HullGreebles' own dune_runners water barrels) - a flat card
# would visibly pop/flatten out at a grazing camera angle in a way a real
# mesh doesn't. No Blender asset pipeline needed either, same reasoning as
# every other decoration in this file's neighborhood: cheap primitives are
# plenty for small background clutter.
#
# Every scatter_*() call is purely decorative - no StaticBody3D, no navmesh
# awareness. Surface zones stay fully walkable by every locomotor at their
# get_terrain_speed_multiplier() penalty (see terrain_builder.gd's own
# comment on this); clutter that physically blocked movement would silently
# turn a speed penalty into a hard obstacle, which is not what surface_zones
# means to model. Seeded deterministically from zone.center (same
# hash(position)-as-seed convention TerrainBuilder's own rock/obstacle
# decorations already use) so a given map always scatters identically
# run to run - required for the screenshot-based verification convention
# this project uses.
#
# CORE_DESIGN_LANGUAGE.md §3.1/§3.2: every prop function below takes a
# `prop_scale` parameter (default 1.0, i.e. today's exact sizes) multiplying
# every physical size, length, radius and within-clump jitter magnitude -
# the mechanism that turns a pebble into a boulder and a grass blade into a
# tree once WorldScale actually drives it (a later, separate commit; this
# one is a pure refactor and must be visually IDENTICAL at prop_scale=1.0).
# Deliberately NOT applied to _rand_point()'s placement offset - that's
# bounded by zone.half_extents, which is already real map-space and scales
# on its own once map geometry scales (see map_catalog.gd), so scaling it
# again here would double-count.

const TerrainBuilderScript = preload("res://scripts/terrain_builder.gd")

static func _get_zone_height(map_def: Dictionary, pos: Vector3, fallback_y: float = 0.0) -> float:
	if not map_def.is_empty():
		return TerrainBuilderScript.terrain_height_at(map_def, pos)
	return fallback_y

static func scatter(zone: Dictionary, parent: Node3D, prop_scale: float = 1.0, map_def: Dictionary = {}):
	match zone.get("surface_type", ""):
		"marsh": _scatter_marsh(zone, parent, prop_scale, map_def)
		"rocky": _scatter_rocky(zone, parent, prop_scale, map_def)
		"snow_mud": _scatter_snow_mud(zone, parent, prop_scale, map_def)
		"sand": _scatter_sand(zone, parent, prop_scale, map_def)
		"gravel": _scatter_gravel(zone, parent, prop_scale, map_def)
		"forest": _scatter_forest(zone, parent, prop_scale, map_def)
		"ice": _scatter_ice(zone, parent, prop_scale, map_def)

static func scatter_shallow_water(zone: Dictionary, parent: Node3D, prop_scale: float = 1.0, map_def: Dictionary = {}):
	_scatter_tide_pool_rocks(zone, parent, prop_scale, map_def)

static func _seeded_rng(center: Vector3) -> RandomNumberGenerator:
	var rng = RandomNumberGenerator.new()
	rng.seed = hash(center)
	return rng

static func _rand_point(rng: RandomNumberGenerator, zone: Dictionary, margin: float = 0.85) -> Vector2:
	var ox = rng.randf_range(-zone.half_extents.x * margin, zone.half_extents.x * margin)
	var oz = rng.randf_range(-zone.half_extents.y * margin, zone.half_extents.y * margin)
	return Vector2(ox, oz)

static func _flat_material(color: Color, roughness: float = 0.85) -> StandardMaterial3D:
	var mat = StandardMaterial3D.new()
	mat.albedo_color = color
	mat.roughness = roughness
	mat.metallic = 0.0
	mat.metallic_specular = 0.0
	mat.specular_mode = BaseMaterial3D.SPECULAR_DISABLED
	return mat

static func _scaled_count(base_count: int, prop_scale: float) -> int:
	if prop_scale <= 0.0:
		return 0
	return int(round(float(base_count) / (prop_scale * prop_scale)))

static func _create_faceted_rock_mesh(rng: RandomNumberGenerator, size: Vector3) -> ArrayMesh:
	var st = SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var sx = size.x * 0.5
	var sy = size.y * 0.5
	var sz = size.z * 0.5
	
	var base_pts: Array[Vector3] = [
		Vector3(-sx, -sy, -sz), Vector3(sx, -sy, -sz), Vector3(sx, -sy, sz), Vector3(-sx, -sy, sz),
		Vector3(-sx * 0.8, sy, -sz * 0.8), Vector3(sx * 0.8, sy, -sz * 0.8), Vector3(sx * 0.8, sy, sz * 0.8), Vector3(-sx * 0.8, sy, sz * 0.8),
		Vector3(0, sy * 1.15, 0)
	]
	# Jitter vertices organically
	for i in range(base_pts.size()):
		var jx = rng.randf_range(-0.15, 0.15) * sx
		var jy = rng.randf_range(-0.12, 0.12) * sy
		var jz = rng.randf_range(-0.15, 0.15) * sz
		base_pts[i] += Vector3(jx, jy, jz)
		
	# Bottom
	st.add_vertex(base_pts[0]); st.add_vertex(base_pts[1]); st.add_vertex(base_pts[2])
	st.add_vertex(base_pts[0]); st.add_vertex(base_pts[2]); st.add_vertex(base_pts[3])
	# Sides
	for i in range(4):
		var n = (i + 1) % 4
		st.add_vertex(base_pts[i]); st.add_vertex(base_pts[4 + i]); st.add_vertex(base_pts[n])
		st.add_vertex(base_pts[n]); st.add_vertex(base_pts[4 + i]); st.add_vertex(base_pts[4 + n])
	# Top pyramid cap
	for i in range(4):
		var n = (i + 1) % 4
		st.add_vertex(base_pts[4 + i]); st.add_vertex(base_pts[8]); st.add_vertex(base_pts[4 + n])
		
	st.generate_normals()
	return st.commit()

static func _create_ice_shard_mesh(rng: RandomNumberGenerator, size: Vector3) -> ArrayMesh:
	var st = SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var sx = size.x * 0.4
	var sz = size.z * 0.4
	var h = size.y
	var apex = Vector3(rng.randf_range(-0.1, 0.1) * sx, h, rng.randf_range(-0.1, 0.1) * sz)
	var segs = 5
	var bot_pts: Array[Vector3] = []
	for i in range(segs):
		var a = (TAU / float(segs)) * i + rng.randf_range(-0.15, 0.15)
		bot_pts.append(Vector3(cos(a) * sx, 0, sin(a) * sz))
	for i in range(segs):
		var n = (i + 1) % segs
		st.add_vertex(bot_pts[i]); st.add_vertex(bot_pts[n]); st.add_vertex(apex)
		st.add_vertex(Vector3.ZERO); st.add_vertex(bot_pts[i]); st.add_vertex(bot_pts[n])
	st.generate_normals()
	return st.commit()

# Marsh/swamp: reed tufts plus driftwood logs
static func _scatter_marsh(zone: Dictionary, parent: Node3D, prop_scale: float = 1.0, map_def: Dictionary = {}):
	var rng = _seeded_rng(zone.center)
	var reed_color = Color(0.28, 0.34, 0.16)
	var wood_color = Color(0.24, 0.19, 0.13)

	for cluster_i in range(_scaled_count(7, prop_scale)):
		var p = _rand_point(rng, zone)
		var stalk_count = rng.randi_range(4, 7)
		for i in range(stalk_count):
			var reed = MeshInstance3D.new()
			var cyl = CylinderMesh.new()
			var height = rng.randf_range(0.9, 1.6) * prop_scale
			cyl.top_radius = 0.02 * prop_scale
			cyl.bottom_radius = 0.06 * prop_scale
			cyl.height = height
			reed.mesh = cyl
			reed.material_override = _flat_material(reed_color.lightened(rng.randf_range(-0.08, 0.08)), 0.75)
			parent.add_child(reed)
			var jitter = Vector2(rng.randf_range(-0.35, 0.35), rng.randf_range(-0.35, 0.35)) * prop_scale
			var target_pos = Vector3(zone.center.x + p.x + jitter.x, 0.0, zone.center.z + p.y + jitter.y)
			var ground_y = _get_zone_height(map_def, target_pos, zone.center.y)
			reed.global_position = Vector3(target_pos.x, ground_y + height / 2.0, target_pos.z)
			reed.rotation = Vector3(rng.randf_range(-0.18, 0.18), rng.randf_range(0, TAU), rng.randf_range(-0.18, 0.18))

	for i in range(_scaled_count(3, prop_scale)):
		var p = _rand_point(rng, zone, 0.7)
		var log_inst = MeshInstance3D.new()
		var cyl = CylinderMesh.new()
		var length = rng.randf_range(1.6, 2.8) * prop_scale
		var radius = rng.randf_range(0.12, 0.2) * prop_scale
		cyl.top_radius = radius * 0.8
		cyl.bottom_radius = radius
		cyl.height = length
		log_inst.mesh = cyl
		log_inst.material_override = _flat_material(wood_color.lightened(rng.randf_range(-0.05, 0.05)), 0.9)
		parent.add_child(log_inst)
		var target_pos = Vector3(zone.center.x + p.x, 0.0, zone.center.z + p.y)
		var ground_y = _get_zone_height(map_def, target_pos, zone.center.y)
		log_inst.global_position = Vector3(target_pos.x, ground_y + radius * 0.6, target_pos.z)
		log_inst.rotation = Vector3(0, rng.randf_range(0, TAU), PI / 2.0 + rng.randf_range(-0.08, 0.08))

# Rocky: boulder jumble and faceted rock fragments
static func _scatter_rocky(zone: Dictionary, parent: Node3D, prop_scale: float = 1.0, map_def: Dictionary = {}):
	var rng = _seeded_rng(zone.center)

	for i in range(_scaled_count(4, prop_scale)):
		var p = _rand_point(rng, zone, 0.6)
		var boulder = MeshInstance3D.new()
		var size = Vector3(rng.randf_range(2.0, 3.5), rng.randf_range(1.2, 2.2), rng.randf_range(2.0, 3.5)) * prop_scale
		boulder.mesh = _create_faceted_rock_mesh(rng, size)
		var shade = rng.randf_range(0.28, 0.42)
		var warmth = rng.randf_range(-0.03, 0.03)
		boulder.material_override = _flat_material(Color(shade + warmth, shade * 0.95, shade * 0.88), rng.randf_range(0.85, 0.95))
		parent.add_child(boulder)
		var target_pos = Vector3(zone.center.x + p.x, 0.0, zone.center.z + p.y)
		var ground_y = _get_zone_height(map_def, target_pos, zone.center.y)
		boulder.global_position = Vector3(target_pos.x, ground_y + size.y * 0.4, target_pos.z)
		boulder.rotation.y = rng.randf_range(0, TAU)

	for i in range(_scaled_count(12, prop_scale)):
		var p = _rand_point(rng, zone)
		var rock = MeshInstance3D.new()
		var size = Vector3(rng.randf_range(0.8, 1.5), rng.randf_range(0.5, 1.1), rng.randf_range(0.8, 1.5)) * prop_scale
		rock.mesh = _create_faceted_rock_mesh(rng, size)
		var shade = rng.randf_range(0.30, 0.45)
		var warmth = rng.randf_range(-0.03, 0.03)
		rock.material_override = _flat_material(Color(shade + warmth, shade * 0.95, shade * 0.88), rng.randf_range(0.85, 0.95))
		parent.add_child(rock)
		var target_pos = Vector3(zone.center.x + p.x, 0.0, zone.center.z + p.y)
		var ground_y = _get_zone_height(map_def, target_pos, zone.center.y)
		rock.global_position = Vector3(target_pos.x, ground_y + size.y * 0.35, target_pos.z)
		rock.rotation.y = rng.randf_range(0, TAU)

# Snow/mud: snowdrifts and mud ruts
static func _scatter_snow_mud(zone: Dictionary, parent: Node3D, prop_scale: float = 1.0, map_def: Dictionary = {}):
	var rng = _seeded_rng(zone.center)
	var snow_color = Color(0.85, 0.84, 0.8)
	var mud_color = Color(0.18, 0.13, 0.09)

	for i in range(_scaled_count(5, prop_scale)):
		var p = _rand_point(rng, zone)
		var mound = MeshInstance3D.new()
		var sphere = SphereMesh.new()
		var radius = rng.randf_range(1.0, 2.0) * prop_scale
		sphere.radius = radius
		sphere.height = radius * 1.1
		mound.mesh = sphere
		mound.material_override = _flat_material(snow_color.lightened(rng.randf_range(-0.04, 0.04)), 0.7)
		mound.scale = Vector3(1.0, 0.45, 1.0)
		parent.add_child(mound)
		var target_pos = Vector3(zone.center.x + p.x, 0.0, zone.center.z + p.y)
		var ground_y = _get_zone_height(map_def, target_pos, zone.center.y)
		mound.global_position = Vector3(target_pos.x, ground_y + radius * 0.45 * 0.5, target_pos.z)

	for i in range(_scaled_count(3, prop_scale)):
		var p = _rand_point(rng, zone, 0.7)
		var rut = MeshInstance3D.new()
		var box = BoxMesh.new()
		var length = rng.randf_range(2.5, 5.0) * prop_scale
		box.size = Vector3(0.5, 0.06, length) * Vector3(prop_scale, prop_scale, 1.0)
		rut.mesh = box
		var mat = _flat_material(mud_color.lightened(rng.randf_range(-0.03, 0.03)), 0.2)
		rut.material_override = mat
		parent.add_child(rut)
		var target_pos = Vector3(zone.center.x + p.x, 0.0, zone.center.z + p.y)
		var ground_y = _get_zone_height(map_def, target_pos, zone.center.y)
		rut.global_position = Vector3(target_pos.x, ground_y + 0.03 * prop_scale, target_pos.z)
		rut.rotation.y = rng.randf_range(0, TAU)

# Soft sand: dune ripples and bleached rocks
static func _scatter_sand(zone: Dictionary, parent: Node3D, prop_scale: float = 1.0, map_def: Dictionary = {}):
	var rng = _seeded_rng(zone.center)
	var sand_ridge_color = Color(0.7, 0.61, 0.42)
	var bleached_color = Color(0.68, 0.63, 0.56)

	for i in range(_scaled_count(4, prop_scale)):
		var p = _rand_point(rng, zone, 0.65)
		var ridge = MeshInstance3D.new()
		var box = BoxMesh.new()
		var length = rng.randf_range(3.0, 6.0) * prop_scale
		box.size = Vector3(length, 0.35 * prop_scale, rng.randf_range(1.2, 2.0) * prop_scale)
		ridge.mesh = box
		ridge.material_override = _flat_material(sand_ridge_color.lightened(rng.randf_range(-0.03, 0.05)), 0.9)
		parent.add_child(ridge)
		var target_pos = Vector3(zone.center.x + p.x, 0.0, zone.center.z + p.y)
		var ground_y = _get_zone_height(map_def, target_pos, zone.center.y)
		ridge.global_position = Vector3(target_pos.x, ground_y + 0.06 * prop_scale, target_pos.z)
		ridge.rotation.y = rng.randf_range(0, TAU)

	for i in range(_scaled_count(2, prop_scale)):
		var p = _rand_point(rng, zone)
		var rock = MeshInstance3D.new()
		var size = Vector3(rng.randf_range(0.28, 0.55), rng.randf_range(0.2, 0.38), rng.randf_range(0.28, 0.55)) * prop_scale
		rock.mesh = _create_faceted_rock_mesh(rng, size)
		rock.material_override = _flat_material(bleached_color.lightened(rng.randf_range(-0.04, 0.04)), 0.85)
		parent.add_child(rock)
		var target_pos = Vector3(zone.center.x + p.x, 0.0, zone.center.z + p.y)
		var ground_y = _get_zone_height(map_def, target_pos, zone.center.y)
		rock.global_position = Vector3(target_pos.x, ground_y + size.y * 0.35, target_pos.z)
		rock.rotation.y = rng.randf_range(0, TAU)

# Gravel: angular scree chunks and pebble heaps
static func _scatter_gravel(zone: Dictionary, parent: Node3D, prop_scale: float = 1.0, map_def: Dictionary = {}):
	var rng = _seeded_rng(zone.center)
	var gravel_color = Color(0.42, 0.40, 0.36)

	for i in range(_scaled_count(12, prop_scale)):
		var p = _rand_point(rng, zone, 0.9)
		var rock = MeshInstance3D.new()
		var size = Vector3(rng.randf_range(0.5, 1.1), rng.randf_range(0.3, 0.7), rng.randf_range(0.5, 1.1)) * prop_scale
		rock.mesh = _create_faceted_rock_mesh(rng, size)
		var shade_val = rng.randf_range(-0.08, 0.08)
		rock.material_override = _flat_material(gravel_color.lightened(shade_val), rng.randf_range(0.85, 0.95))
		parent.add_child(rock)
		var target_pos = Vector3(zone.center.x + p.x, 0.0, zone.center.z + p.y)
		var ground_y = _get_zone_height(map_def, target_pos, zone.center.y)
		rock.global_position = Vector3(target_pos.x, ground_y + size.y * 0.35, target_pos.z)
		rock.rotation = Vector3(rng.randf_range(-0.1, 0.1), rng.randf_range(0, TAU), rng.randf_range(-0.1, 0.1))

# Forest floor: fallen branch cylinders and dark humus mounds
static func _scatter_forest(zone: Dictionary, parent: Node3D, prop_scale: float = 1.0, map_def: Dictionary = {}):
	var rng = _seeded_rng(zone.center)
	var bark_color = Color(0.22, 0.17, 0.11)
	var mulch_color = Color(0.18, 0.22, 0.12)

	for i in range(_scaled_count(5, prop_scale)):
		var p = _rand_point(rng, zone, 0.8)
		var branch = MeshInstance3D.new()
		var cyl = CylinderMesh.new()
		var length = rng.randf_range(1.2, 2.2) * prop_scale
		var radius = rng.randf_range(0.06, 0.12) * prop_scale
		cyl.top_radius = radius * 0.7
		cyl.bottom_radius = radius
		cyl.height = length
		branch.mesh = cyl
		branch.material_override = _flat_material(bark_color.lightened(rng.randf_range(-0.05, 0.05)), 0.88)
		parent.add_child(branch)
		var target_pos = Vector3(zone.center.x + p.x, 0.0, zone.center.z + p.y)
		var ground_y = _get_zone_height(map_def, target_pos, zone.center.y)
		branch.global_position = Vector3(target_pos.x, ground_y + radius * 0.5, target_pos.z)
		branch.rotation = Vector3(0, rng.randf_range(0, TAU), PI / 2.0 + rng.randf_range(-0.05, 0.05))

	for i in range(_scaled_count(4, prop_scale)):
		var p = _rand_point(rng, zone, 0.85)
		var shrub = MeshInstance3D.new()
		var sphere = SphereMesh.new()
		var radius = rng.randf_range(0.3, 0.6) * prop_scale
		sphere.radius = radius
		sphere.height = radius * 1.2
		shrub.mesh = sphere
		shrub.material_override = _flat_material(mulch_color.lightened(rng.randf_range(-0.06, 0.06)), 0.85)
		shrub.scale = Vector3(1.0, 0.5, 1.0)
		parent.add_child(shrub)
		var target_pos = Vector3(zone.center.x + p.x, 0.0, zone.center.z + p.y)
		var ground_y = _get_zone_height(map_def, target_pos, zone.center.y)
		shrub.global_position = Vector3(target_pos.x, ground_y + radius * 0.25, target_pos.z)

# Ice: frosted angular shards and blue-tinted ice blocks
static func _scatter_ice(zone: Dictionary, parent: Node3D, prop_scale: float = 1.0, map_def: Dictionary = {}):
	var rng = _seeded_rng(zone.center)
	var ice_color = Color(0.72, 0.82, 0.88)

	for i in range(_scaled_count(6, prop_scale)):
		var p = _rand_point(rng, zone, 0.75)
		var shard = MeshInstance3D.new()
		var size = Vector3(rng.randf_range(0.5, 1.1), rng.randf_range(0.4, 0.9), rng.randf_range(0.5, 1.1)) * prop_scale
		shard.mesh = _create_ice_shard_mesh(rng, size)
		var mat = _flat_material(ice_color.lightened(rng.randf_range(-0.04, 0.05)), 0.25)
		shard.material_override = mat
		parent.add_child(shard)
		var target_pos = Vector3(zone.center.x + p.x, 0.0, zone.center.z + p.y)
		var ground_y = _get_zone_height(map_def, target_pos, zone.center.y)
		shard.global_position = Vector3(target_pos.x, ground_y, target_pos.z)
		shard.rotation = Vector3(rng.randf_range(-0.1, 0.1), rng.randf_range(0, TAU), rng.randf_range(-0.1, 0.1))

# Shallow water: tide-pool rocks poking above the surface
static func _scatter_tide_pool_rocks(zone: Dictionary, parent: Node3D, prop_scale: float = 1.0, map_def: Dictionary = {}):
	var rng = _seeded_rng(zone.center)
	var wet_rock_color = Color(0.22, 0.24, 0.23)

	for i in range(_scaled_count(6, prop_scale)):
		var p = _rand_point(rng, zone, 0.8)
		var rock = MeshInstance3D.new()
		var size = Vector3(rng.randf_range(0.4, 0.9), rng.randf_range(0.3, 0.7), rng.randf_range(0.4, 0.9)) * prop_scale
		rock.mesh = _create_faceted_rock_mesh(rng, size)
		var mat = _flat_material(wet_rock_color.lightened(rng.randf_range(-0.03, 0.05)), 0.35)
		rock.material_override = mat
		parent.add_child(rock)
		var exposure = rng.randf_range(0.25, 0.75)
		var target_pos = Vector3(zone.center.x + p.x, 0.0, zone.center.z + p.y)
		var ground_y = _get_zone_height(map_def, target_pos, zone.center.y)
		rock.global_position = Vector3(target_pos.x, ground_y + size.y * exposure - size.y * 0.4 + 0.06 * prop_scale, target_pos.z)
		rock.rotation.y = rng.randf_range(0, TAU)

# --- Baseline grassland/blue_water clutter ---
static func place_grassland_prop(pos: Vector3, variant_seed: int, parent: Node3D, prop_scale: float = 1.0, tall: bool = false):
	var rng = RandomNumberGenerator.new()
	rng.seed = variant_seed
	if tall:
		_place_tall_brush(pos, rng, parent, prop_scale)
		return
	var roll = rng.randf()
	if roll < 0.5:
		_place_grass_tuft(pos, rng, parent, prop_scale)
	elif roll < 0.8:
		_place_grassland_rock(pos, rng, parent, prop_scale)
	else:
		_place_brush_clump(pos, rng, parent, prop_scale)

static func _place_grass_tuft(pos: Vector3, rng: RandomNumberGenerator, parent: Node3D, prop_scale: float = 1.0):
	var color = Color(0.3, 0.4, 0.17)
	var blade_count = rng.randi_range(3, 5)
	for i in range(blade_count):
		var blade = MeshInstance3D.new()
		var cyl = CylinderMesh.new()
		var height = rng.randf_range(0.22, 0.42) * prop_scale
		cyl.top_radius = 0.015 * prop_scale
		cyl.bottom_radius = 0.035 * prop_scale
		cyl.height = height
		blade.mesh = cyl
		blade.material_override = _flat_material(color.lightened(rng.randf_range(-0.1, 0.1)), 0.8)
		parent.add_child(blade)
		var jitter = Vector2(rng.randf_range(-0.12, 0.12), rng.randf_range(-0.12, 0.12)) * prop_scale
		blade.global_position = Vector3(pos.x + jitter.x, pos.y + height / 2.0, pos.z + jitter.y)
		blade.rotation = Vector3(rng.randf_range(-0.2, 0.2), rng.randf_range(0, TAU), rng.randf_range(-0.2, 0.2))

static func _place_grassland_rock(pos: Vector3, rng: RandomNumberGenerator, parent: Node3D, prop_scale: float = 1.0):
	var rock = MeshInstance3D.new()
	var size = Vector3(rng.randf_range(0.6, 1.2), rng.randf_range(0.4, 0.8), rng.randf_range(0.6, 1.2)) * prop_scale
	rock.mesh = _create_faceted_rock_mesh(rng, size)
	var shade = rng.randf_range(0.32, 0.42)
	var warmth = rng.randf_range(-0.03, 0.03)
	rock.material_override = _flat_material(Color(shade + warmth, shade * 0.95, shade * 0.85), rng.randf_range(0.85, 0.95))
	parent.add_child(rock)
	rock.global_position = Vector3(pos.x, pos.y + size.y * 0.35, pos.z)
	rock.rotation.y = rng.randf_range(0, TAU)

# A low scrubby clump of brush - a squashed sphere reads as a rounded bush
# silhouette at RTS distance without needing real branch geometry.
static func _place_brush_clump(pos: Vector3, rng: RandomNumberGenerator, parent: Node3D, prop_scale: float = 1.0):
	var bush = MeshInstance3D.new()
	var sphere = SphereMesh.new()
	var radius = rng.randf_range(0.3, 0.55) * prop_scale
	sphere.radius = radius
	sphere.height = radius * 1.4
	bush.mesh = sphere
	bush.material_override = _flat_material(Color(0.27, 0.29, 0.15).lightened(rng.randf_range(-0.06, 0.06)), 0.85)
	bush.scale = Vector3(1.0, 0.6, 1.0)
	parent.add_child(bush)
	bush.global_position = Vector3(pos.x, pos.y + radius * 0.3, pos.z)

# CORE_DESIGN_LANGUAGE.md §3.1: a genuinely tall clump - roughly 3-5x a
# regular _place_brush_clump()'s radius, so at 16x prop_scale it stands
# close to unit height, the "dense forest is a clump of marsh grass" cue at
# full strength. terrain_builder.gd's _spawn_grassland_clutter() is the only
# caller, and only for positions it has already determined are off the
# playable surface (map edge margin or a slope too steep to fight on) - see
# that function's own comment for why unit readability during a fight
# forbids this everywhere else. A tuft of tall blades rather than a solid
# clump reads better at the greater height than a single squashed sphere
# would (a sphere stretched 3-5x tall stops reading as foliage).
static func _place_tall_brush(pos: Vector3, rng: RandomNumberGenerator, parent: Node3D, prop_scale: float = 1.0):
	var color = Color(0.22, 0.32, 0.13)
	var blade_count = rng.randi_range(4, 6)
	for i in range(blade_count):
		var blade = MeshInstance3D.new()
		var cyl = CylinderMesh.new()
		var height = rng.randf_range(1.0, 1.8) * prop_scale
		cyl.top_radius = 0.05 * prop_scale
		cyl.bottom_radius = 0.11 * prop_scale
		cyl.height = height
		blade.mesh = cyl
		blade.material_override = _flat_material(color.lightened(rng.randf_range(-0.1, 0.1)), 0.8)
		parent.add_child(blade)
		var jitter = Vector2(rng.randf_range(-0.4, 0.4), rng.randf_range(-0.4, 0.4)) * prop_scale
		blade.global_position = Vector3(pos.x + jitter.x, pos.y + height / 2.0, pos.z + jitter.y)
		blade.rotation = Vector3(rng.randf_range(-0.12, 0.12), rng.randf_range(0, TAU), rng.randf_range(-0.12, 0.12))

# Blue water: a small fixed handful of floating driftwood/flotsam planks
# per water rect - deliberately NOT area-scaled (see this section's header
# comment) since real open water should read as mostly empty.
static func scatter_blue_water(zone: Dictionary, parent: Node3D, prop_scale: float = 1.0):
	var rng = _seeded_rng(zone.center)
	var flotsam_color = Color(0.32, 0.26, 0.18)
	var count = rng.randi_range(3, 6)
	for i in range(count):
		var p = _rand_point(rng, zone, 0.85)
		var plank = MeshInstance3D.new()
		var box = BoxMesh.new()
		var length = rng.randf_range(0.8, 1.6) * prop_scale
		box.size = Vector3(length, 0.06 * prop_scale, rng.randf_range(0.18, 0.32) * prop_scale)
		plank.mesh = box
		plank.material_override = _flat_material(flotsam_color.lightened(rng.randf_range(-0.05, 0.08)), 0.75)
		parent.add_child(plank)
		plank.global_position = Vector3(zone.center.x + p.x, 0.07 * prop_scale, zone.center.z + p.y)
		plank.rotation.y = rng.randf_range(0, TAU)

# --- Ambient harvestable trees -------------------------------------------------
#
# THE "AMBIENT FOREST" PASS. Scatters individual ResourceNode instances
# (one tree each) across the whole map's baseline ground, NOT under a
# ResourceField - so the trees are in the resource_nodes group (harvesters
# find them) but have no field, no respawn, no regrow. resource_node.gd's
# is_ambient flag is what enforces the no-regrow contract once a
# harvester empties one.
#
# WHY A NEW PASS INSTEAD OF REUSING place_grassland_prop(). The grassland
# scatter produces DECORATION (a MeshInstance3D with no game logic).
# These are GAME ENTITIES (a StaticBody3D that takes harvest calls, holds
# an amount, joins the resource_nodes group). They share the same
# avoidance set and seeded-RNG discipline - just produce a different
# thing at each accepted point.
#
# CALLED FROM terrain_builder.gd._spawn_ambient_trees(), which owns the
# avoidance lists (water/obstacles/bridges/surface_zones/spawns/
# resource_nodes) and the density budget. This function is the
# per-point WHAT: load the ambient pool, build one ResourceNode, set
# is_ambient=true, place at the validated point.
#
# Density and avoidance are NOT this function's job. The reason
# mirrors every other greeble function in this file: the WHAT (one
# ambient tree) and the WHERE (which positions to even consider) live
# in different files so the "where" can change without churning the
# "what" and vice versa.
const ResourceNodeScript = preload("res://scripts/resource_node.gd")
const AMBIENT_TREE_Y_LIFT: float = 0.0
# Yaw is a free rotation, not from a normal. Trees are NOT surface-
# aligned props (that's the place_grassland_prop convention); each one
# is a vertical silhouette and a yaw per-instance is what stops the
# forest reading as a "lollipop" field where every trunk faces the
# camera.
static func spawn_ambient_tree(pos: Vector3, parent: Node3D, variant_seed: int, amount: int):
	var node = ResourceNodeScript.new()
	node.is_ambient = true
	parent.add_child(node)
	node.global_position = pos
	# The variant_seed already incorporates the position via the caller's
	# hash-per-position seeding (same convention _try_spawn_ambient_
	# authored() inside resource_node.gd uses for re-rolling at load
	# time), so a given scatter point always picks the same variant.
	# We don't pass the seed in - resource_node.gd seeds off its own
	# global_position at setup() time, which is identical to the
	# caller's seed, so the two paths stay in lockstep.
	node.setup("lumber", amount)
	# Per-instance yaw for visual variety. The authored meshes are
	# already radially-symmetric cylinders/cones/spheres, so a pure
	# yaw rotation never breaks the silhouette. Z rotation would
	# tip the tree, which is wrong for an upright tree.
	node.rotation.y = float(variant_seed & 0xFF) / 256.0 * TAU


# AMBIENT ORE (2026-08-10, paired with the ambient-tree trim above).
# Same shape as spawn_ambient_tree() - a bare ResourceNode with
# is_ambient=true, no field, no regrow - but with resource_type="ore"
# and a different visual family. The ore visual comes from the
# EXISTING 3-variant resource_ore_*.glb pool (no new Blender
# authoring) because the harvestable outcrop is already the right
# "single find" silhouette; a separate ambient_ore_* family would
# just be a parallel set that drifted over time. See
# _try_spawn_ambient_authored()'s own branch in resource_node.gd for
# why lumber is the special case and everything else isn't.
static func spawn_ambient_ore(pos: Vector3, parent: Node3D, variant_seed: int, amount: int):
	var node = ResourceNodeScript.new()
	node.is_ambient = true
	parent.add_child(node)
	node.global_position = pos
	# Same position-seeded determinism as spawn_ambient_tree - the
	# scatter point hash picks the variant, not the variant_seed arg
	# (which is only used for the per-instance yaw below).
	node.setup("ore", amount)
	# Per-instance yaw. Ore outcrops are roughly rock-shaped, so a
	# pure yaw rotation is the only legal one - tipping the rock
	# (any X or Z rotation) would make it look like it fell over.
	node.rotation.y = float(variant_seed & 0xFF) / 256.0 * TAU
