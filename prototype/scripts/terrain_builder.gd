extends Node
class_name TerrainBuilder
const TerrainGreeblesScript = preload("res://scripts/terrain_greebles.gd")
const WorldScaleScript = preload("res://scripts/world_scale.gd")
const ResourceNodeScript = preload("res://scripts/resource_node.gd")
const AmbientScatterScript = preload("res://scripts/ambient_scatter.gd")
const TerrainVisualScatterScript = preload("res://scripts/terrain_visual_scatter.gd")
const TerrainDressingScript = preload("res://scripts/terrain_dressing.gd")
# 2026-08-26: half_extents() lives on MapCatalog for the non-square map
# support (map_half_extents_z). Loading it here so the nav-tile and
# ground-mesh code can read both axes without a circular import.
const MapCatalogScript = preload("res://scripts/map_catalog.gd")
# Turns a MapCatalog map Dictionary into: baked NavigationServer3D ground/
# water maps, decorative terrain meshes (water planes, rock-cluster
# obstacles), and pure query functions (terrain_height_at / is_position_
# blocked) that unit.gd (and match_director.gd before it) consult for Y-positioning,
# buildability, and (indirectly, via real Y coordinates) vision/combat
# elevation bonuses.
#
# Ground navmesh technique: the 160x160 (or whatever map_half_extents
# says) area is walked in GRID_CELL-sized quads, and any cell overlapping
# a water/obstacle footprint is simply omitted. RTS_CORE_ROADMAP.md B6
# retired the old rect elevation_zones/ramp system entirely (real
# elevation now comes from a heightmap - see height_at()'s own header
# comment) - every map has real per-cell slope rejection instead of a
# hand-authored single-direction ramp.

const GRID_CELL: float = 4.0

# RTS_CORE_ROADMAP.md B8: NavigationServer3D's Recast baker doesn't just
# get slow past a triangle-count threshold, it SEGFAULTS outright -
# confirmed empirically at scattered_peaks' 550 half-extent with the flat
# GRID_CELL=4.0 (151,250 ground triangles alone). Keeps the grid's total
# triangle count roughly constant regardless of map size by widening the
# cell for anything bigger than the ~300 half-extent every map up to
# twin_bridges already used successfully - GRID_CELL itself is untouched
# (and this returns exactly GRID_CELL) for every map at or under that
# size, so this is zero-risk for the 9 maps that already worked.
# CORE_DESIGN_LANGUAGE.md §3.2 / Chunk 14: this formula is a pure function
# of `half`, which itself now grows under world_scale (map_half_extents is
# a FIELD_SPEC-flagged field - see _apply_world_scale() in map_catalog.gd).
# No separate re-tuning turned out to be needed: source-triangle grid cell
# scales LINEARLY with half beyond the ~300 knee, so triangle count per
# axis (half / grid_cell) converges toward a constant (~75) as half grows
# without bound, rather than growing with it. A map that's 16x bigger
# because world_scale=16 costs the SAME source-triangle budget as a map
# that's 16x bigger because someone authored it that size by hand - the
# formula can't tell the difference, which is exactly the point.
static func _nav_grid_cell(map_def: Dictionary) -> float:
	# 2026-08-26: non-square map support - use the larger half-extent so
	# the cell is wide enough to cover whichever axis is the long one.
	# The cell is square, so a single value must work for both axes; the
	# shorter axis just gets a finer-than-needed resolution (harmless).
	var he: Vector2 = MapCatalogScript.half_extents(map_def)
	var half: float = max(he.x, he.y)
	return max(GRID_CELL, half / 75.0)

# RTS_CORE_ROADMAP.md B8: even AFTER _nav_grid_cell() brought scattered_peaks'
# source triangle count back down to twin_bridges' working scale, the bake
# still segfaulted - the actual cause was Recast's internal voxel grid,
# sized from NavigationMesh.cell_size (Godot's own default: 0.25), not from
# triangle count at all. At 550 half-extent (1100 world units) that's a
# ~4400x4400 voxel heightfield; confirmed empirically that cell_size=1.0
# bakes successfully in ~500ms. Every map at or under 300 half-extent
# (twin_bridges' size, the largest that already worked) keeps EXACTLY
# Godot's own 0.25 default - zero behavior change for the 9 original maps.
#
# 2026-07-31 (performance): the "zero behavior change for the 9 original
# maps" conservatism above was costing more than it was protecting. Recast's
# cost is O(voxels), i.e. quadratic in 1/cell_size, and at 0.25 a 480-unit
# map (lake_crossing) bakes a 1920x1920 heightfield. Measured on that map
# with scratch/probe_nav_cell_size.gd:
#
#   cell_size   grid        bake      nav polys (lake / highland)
#   0.25        1920x1920   1585 ms   62 / 544
#   0.50         960x960     346 ms   56 / 144
#   1.00         480x480     106 ms   48 /  80
#
# That 1.5s is paid TWICE per rebake (ground + amphibious), and
# skirmish.gd rebakes on every building placement and every building death -
# a measured 3.2s main-thread freeze per placement, which is the "placing a
# building freezes the game" report. It is also ~3.5s of the ~6.4s cold
# match load that makes Windows mark the process Not Responding.
#
#
# 2026-07-31 (performance): DELIBERATELY LEFT AT 0.25 after trying to widen
# it, because widening buys speed by spending pathing correctness, and there
# turned out to be a way to get the speed without paying that. Recorded here
# so the next person doesn't re-run the same experiment:
#
#   flat 1.0          4 tests fail - plateau ramp unreachable, a resource
#                     node unreachable, repath-around-building broken
#   flat 0.5          plateau ramp still unreachable (max_y 1.0 vs 2.5)
#   scaled by size    plateau fixed, but a unit's path then cut straight
#                     THROUGH lake_crossing's lake instead of detouring
#
# Measured per-surface bake cost, for reference (probe_nav_cell_size.gd):
# 0.25 -> 1585ms, 0.5 -> 346ms, 1.0 -> 106ms. Tempting, and wrong: the
# navmesh is what stops units driving into lakes and off plateaus.
#
# The freeze it was meant to fix is solved instead by
# rebake_ground_and_amphibious_async() below, which moves Recast off the
# main thread entirely - full resolution, no stall. Cost stays high, but
# it is no longer paid where the player can feel it.
# CORE_DESIGN_LANGUAGE.md §3.2 / Chunk 14: same self-bounding property as
# _nav_grid_cell() above, and for the same reason - a pure function of
# `half`, which now grows with world_scale automatically (Chunk 12). The
# voxel grid dimension is 2*half/cell_size; beyond the 300 knee that's
# 2*half / (0.25 + (half-300)*0.003), which converges to 2/0.003 =~ 667
# voxels per axis as half -> infinity, REGARDLESS of how large half gets -
# it does not keep growing the way a naive fixed cell_size would. Verified
# directly (not just algebraically) by
# test_scattered_peaks_navmesh_bakes_cleanly_at_world_scale_4 below:
# scattered_peaks is the map that originally segfaulted the baker at its
# native 550 half-extent, and it still bakes cleanly at 4x that.
static func _nav_cell_size(map_def: Dictionary) -> float:
	# 2026-08-26: non-square map support - max of the two half extents
	# drives the cell_size formula, same logic as _nav_grid_cell above.
	var he: Vector2 = MapCatalogScript.half_extents(map_def)
	var half: float = max(he.x, he.y)
	if half <= 300.0:
		return 0.25
	return 0.25 + (half - 300.0) * 0.003

# Chunk 21: navmesh TILING. _nav_cell_size() above solves BAKE COST by
# widening the cell as the map grows - it keeps Recast from segfaulting, but
# the tradeoff is fidelity: tools/probe_streaming_wall.gd measured cell_size
# reaching ~105 units on scattered_peaks at world_scale=16, wide enough for a
# single voxel to swallow a whole building. That coarseness is what produced
# the exit-position, dock-bay and vertical-slack bugs already fixed at
# world_scale=4 (a few units of error each) - at 16x the same mechanism
# would be measured in tens of units.
#
# Tiling changes what bounds Recast's voxel grid: instead of ONE region
# covering the whole map (voxel count grows with map area), each surface
# becomes many regions on the SAME NavigationServer3D map, one per
# NAV_TILE_SIZE-square tile, and NavigationServer3D stitches same-map
# regions together automatically wherever their edges meet - no consumer
# (NavigationAgent3D, vision, flow fields, every existing test) has to know
# or care, because they all query the MAP RID, never a region directly.
# Per-tile voxel count now depends only on NAV_TILE_SIZE, so cell_size can
# go back to a small, near-fixed value regardless of how large the map (or
# world_scale) gets - fidelity and map size are decoupled.
# Self-bounding the same way _nav_grid_cell() is (see that function's own
# header) - a FIXED tile size would make tile COUNT grow as (2*half/size)^2.
# On scattered_peaks at world_scale=4 (half=8800) a naive 128-unit tile
# produced roughly 19,000 tiles: thousands of near-empty Recast bakes, and
# the O(triangles x tiles) first pass at _bucket_verts_by_tile() (before it
# was rewritten below to index directly) turned map load into a hang rather
# than a slowdown. Widening the tile alongside half keeps tile count per
# axis converging toward a constant instead of growing without bound - the
# same trick, for the same reason, as _nav_grid_cell/_nav_cell_size.
const NAV_TILE_SIZE_BASE: float = 128.0
const NAV_TILES_PER_AXIS: float = 12.0

# Target voxels per tile axis. A first version of this used a FLAT
# a flat cell_size regardless of tile size - measured on
# scattered_peaks (144 tiles, tile_size ~367), that gave each tile a
# ~733x733 voxel grid, comparable to the ENTIRE old single-region bake
# (Chunk 20 measured ~675x675 total), done 288 times: an 85-SECOND load
# where the old approach took ~210ms. cell_size has to be derived from a
# genuine per-tile voxel budget, not guessed - this is that budget, sized
# so total voxel count across every tile stays in the same ballpark as the
# old single-region bake (tools/probe_tile_bake.gd verifies the result).
# 110, not 56. A voxel budget picked to reproduce the OLD single-region
# formula's TOTAL voxel count turns out to reproduce very nearly its same
# per-unit cell_size too (both converge toward ~half * 0.003 for large
# half) - real at any map size, but it bought no actual fidelity, only the
# tile architecture Chunk 22 needs. Measured (tools/probe_tile_bake.gd):
# 110 roughly halves cell_size at scattered_peaks' scale while keeping the
# full sync bake around 10s, in the same order of magnitude as the ~4s the
# codebase already accepts for a full four-surface load.
const NAV_TILE_VOXELS_PER_AXIS: float = 110.0

# Tiled-bake border, in voxels. This is the fix for "units stop at an
# arbitrary straight line / route off on a tangent along it" (2026-08-23
# playtest).
#
# THE BUG. Chunk 21 split each surface into per-tile regions but baked each
# tile as a STANDALONE ISLAND: no filter_baking_aabb, no border_size, just
# the bucket of triangles whose first vertex fell in the tile. Recast then
# applied agent_radius erosion to the tile's artificial perimeter - every
# interior seam lost up to one snapped agent radius of walkable surface ON
# EACH SIDE - and the two edges were quantized independently because each
# bake anchors its voxel grid at its own bounds. The only thing stitching
# the tiles back together was map edge_connection_margin at 4x cell_size,
# a fallback connector for NEARBY parallel edges. Wherever the erosion and
# quantization produced a gap wider than that margin, the seam simply did
# not connect: a hard, invisible, perfectly straight wall across open
# terrain. Where it connected in only a few places, units detoured along
# the seam to the surviving portal - the "tangent" behaviour.
#
# THE FIX is Godot's chunk-baking contract (NavigationMesh.border_size):
#   * each tile's bake AABB is its nominal rect GROWN by this border, so the
#     bake sees the neighbouring tiles' geometry;
#   * border_size discards that same ring from the FINISHED surface, so
#     agent_radius erosion and contour simplification happen in the
#     discarded ring instead of at the shared seam;
#   * the remaining surface ends exactly at the nominal rect on both sides,
#     so adjacent tiles' edges coincide and the navigation map merges them
#     directly instead of relying on the margin fallback.
#
# 6 cells: must strictly exceed the snapped agent radius (always <= 1 voxel,
# see NAV_AGENT_RADIUS/_snap_up_to_voxel) with headroom for edge_max_error
# simplification (1.0) - 6 covers both at every cell_size the project
# produces. Kept an exact cell multiple so the border clip lands EXACTLY on
# the nominal rect (border_size is ceiled to whole cells internally; the
# clip plane is measured from the AABB edge, so (rect - k*cell) + k*cell =
# rect regardless of where the tile sits on any absolute grid).
const NAV_TILE_BORDER_CELLS: float = 6.0

# SINGLE-REGION BAKE (v2). The tiled bake's seams are the problem: give the
# ground any relief and each tile bakes 30-70 polygons instead of 2, the two
# sides of a seam stop coinciding, and the map fragments into unreachable
# islands (see POST_PASS_NAVMESH_LIMIT). A map with no seams cannot have that
# failure.
#
# It is also not more expensive, which is the surprising part. 144 tiles at
# ~122 voxels a side is ~2.1M voxels because every tile re-bakes a 6-cell
# border its neighbours already covered; one region at _nav_cell_size (2.23 m
# on a 960-half map) is 861 x 861 = ~0.74M. The tiling was introduced to bound
# per-tile cost on very large maps, not because one region was unaffordable at
# this scale.
#
# The trade is mid-match rebaking: buildings currently re-bake only the tiles
# they touch, and with one region that becomes the whole surface. Gated to v2
# so no shipped map changes, and revisit if a v2 map ever shows a hitch on
# placement.
static func _nav_single_region(map_def: Dictionary) -> bool:
	if terrain_generator(map_def) == "v2":
		return true
	var he: Vector2 = MapCatalogScript.half_extents(map_def)
	return (he.x * 2.0 <= NAV_TILE_SIZE_BASE) and (he.y * 2.0 <= NAV_TILE_SIZE_BASE)


static func _nav_tile_size(map_def: Dictionary) -> float:
	# 2026-08-26: non-square map support - max of the two half extents
	# so a 1200x520 map (half_x=600) gets the same 200-unit tile size
	# the 1200x1200 square map would have. The Z axis (520) then fits
	# in 3 tiles; the X axis (1200) in 6 tiles.
	var he: Vector2 = MapCatalogScript.half_extents(map_def)
	var half: float = max(he.x, he.y)
	return maxf(NAV_TILE_SIZE_BASE, (half * 2.0) / NAV_TILES_PER_AXIS)

# Never coarser than the pre-tiling formula, even though the tile budget
# above is sized for LARGE maps. A map small enough to fit in a single tile
# (test_terrain.json's 60-half fixture: span 120 < NAV_TILE_SIZE_BASE 128,
# exactly one tile, no boundary crossing at all) got cell_size 2.29 instead
# of the old formula's crisp 0.25 purely because the tile-size FLOOR is
# much larger than the whole map - a real regression on the one class of
# map that already had headroom to spare, caught by
# test_b5_heightmap_navmesh_rejects_steep_slope's flat-ground control path
# landing 18 units short of its target.
static func _nav_tile_cell_size(map_def: Dictionary) -> float:
	# One region is not a tile, so the per-tile voxel budget does not apply -
	# it would give a 1920 m span a 17 m cell. Use the pre-tiling formula.
	if _nav_single_region(map_def):
		return _nav_cell_size(map_def)
	return minf(_nav_tile_size(map_def) / NAV_TILE_VOXELS_PER_AXIS, _nav_cell_size(map_def))

static func _nav_tile_rects(map_def: Dictionary) -> Array:
	var he: Vector2 = MapCatalogScript.half_extents(map_def)
	var half_x: float = he.x
	var half_z: float = he.y
	if _nav_single_region(map_def):
		return [{"x0": -half_x, "x1": half_x, "z0": -half_z, "z1": half_z}]
	var tile_size := _nav_tile_size(map_def)
	var rects: Array = []
	var x := -half_x
	while x < half_x:
		var x1 := minf(x + tile_size, half_x)
		var z := -half_z
		while z < half_z:
			var z1 := minf(z + tile_size, half_z)
			rects.append({"x0": x, "x1": x1, "z0": z, "z1": z1})
			z = z1
		x = x1
	return rects

# Splits a flat quad-soup (verts is 3 entries per triangle, see
# _add_nav_quad) into one PackedVector3Array per tile rect.
#
# `pad` (the tiled bake border, NAV_TILE_BORDER_CELLS cells, or 0 for probe
# callers inspecting the raw layout) widens every tile's bucket: a triangle
# goes into EVERY tile whose rect-grown-by-pad intersects the triangle's
# bounds. This is the other half of the seam fix documented at
# NAV_TILE_BORDER_CELLS - a tile's bake must see the geometry on the FAR
# side of its seams, or the border discard has nothing to erode into and
# the seam edge erodes instead. Two consequences of the old first-vertex
# ownership mattered here: it was already false that "a quad never
# straddles a tile boundary" (at large map scale tile_size/grid_cell =
# 12.5, so every second boundary cuts a quad), and selective rebakes keyed
# on nominal rects missed geometry just over the line. Both are moot once
# membership is an intersection test.
#
# Indexes directly via floor division rather than scanning every rect per
# triangle (an O(triangles x tiles) first version of this function, back
# when tile count could reach five figures on a large map, turned a several-
# hundred-millisecond face build into an effective hang). `rects` must be
# the grid _nav_tile_rects() produces - a regular row-major sweep from
# (-half,-half) in `tile_size` steps - so cols/rows derived from that same
# tile_size reproduce the exact same indexing without re-deriving rects.
static func _bucket_verts_by_tile(verts: PackedVector3Array, map_def: Dictionary, rects: Array, pad: float = 0.0) -> Array:
	var buckets: Array = []
	buckets.resize(rects.size())
	for i in range(buckets.size()):
		buckets[i] = PackedVector3Array()
	if rects.is_empty():
		return buckets
	# ONE rect means one region covering the whole map, so every triangle
	# belongs to it and there is nothing to sort. The grid walk below derives
	# its col/row count from _nav_tile_size() rather than from `rects`, so on
	# a single-region map it would still compute a 12x12 index space and write
	# past the end of a one-element bucket list.
	if rects.size() == 1:
		buckets[0] = verts.duplicate()
		return buckets
	var he: Vector2 = MapCatalogScript.half_extents(map_def)
	var tile_size := _nav_tile_size(map_def)
	# Per-axis col/row count. The bucket index is col * rows + row, so
	# the X-axis stride must be the Z-axis count (rows) and vice versa.
	# With max(half_x, half_z) the two axes would have the same col/row
	# count, so the indexing is degenerate; the non-square map needs the
	# actual Z-axis count here.
	var cols := int(ceil((he.x * 2.0) / tile_size))
	var rows := int(ceil((he.y * 2.0) / tile_size))
	var vcount := verts.size()
	var i := 0
	while i + 2 < vcount:
		var a: Vector3 = verts[i]
		var b: Vector3 = verts[i + 1]
		var c: Vector3 = verts[i + 2]
		var min_x: float = minf(a.x, minf(b.x, c.x)) - pad
		var max_x: float = maxf(a.x, maxf(b.x, c.x)) + pad
		var min_z: float = minf(a.z, minf(b.z, c.z)) - pad
		var max_z: float = maxf(a.z, maxf(b.z, c.z)) + pad
		var c0: int = clampi(int(floor((min_x + he.x) / tile_size)), 0, cols - 1)
		var c1: int = clampi(int(floor((max_x + he.x) / tile_size)), 0, cols - 1)
		var r0: int = clampi(int(floor((min_z + he.y) / tile_size)), 0, rows - 1)
		var r1: int = clampi(int(floor((max_z + he.y) / tile_size)), 0, rows - 1)
		for col in range(c0, c1 + 1):
			for row in range(r0, r1 + 1):
				var idx: int = col * rows + row
				var bucket: PackedVector3Array = buckets[idx]
				bucket.append(a); bucket.append(b); bucket.append(c)
				buckets[idx] = bucket
		i += 3
	return buckets

# Bridge deck height above water/ground level - just enough to read as a
# real raised structure (and to keep the deck mesh visibly above the water
# plane's own y=0.05) without needing an approach ramp of its own; bridges
# sit flush with the surrounding ground on both banks.
const BRIDGE_DECK_HEIGHT: float = 0.6

# --- Heightmap terrain ---
#
# height_at(map_def, x, z) is the ONE source of truth for continuous
# ground elevation. It combines three things:
#   - low-amplitude deterministic noise everywhere (real, but subtle rolling
#     ground rather than perfectly dead-flat terrain)
#   - "hills": [{center, radius, height, falloff}] - a radially-symmetric
#     smoothstep bump
#   - "water_blobs": [{center, radius, irregularity, depth, shore_blend}] -
#     an organic (non-rectangular) lake shape: a per-angle radius wobble
#     defines the coastline, and the ground dips smoothly below sea level
#     inside it, blending back to 0 over `shore_blend` units past the edge.
# A map with terrain.heightmap set (RTS_CORE_ROADMAP.md B4) REPLACES all
# three with a bilinear sample of the baked heightmap PNG instead - see
# height_at()'s own header comment for the exact precedence.
#
# Every map gets the noise pass "for free" now that the ground is a real
# subdivided mesh instead of one flat box (see build_ground_visual_mesh())
# - a mismatch between a bumpy navmesh/height query and a visually flat
# ground would look like units floating/sinking, so the two MUST move
# together, which is exactly what this single function-plus-mesh-generator
# pairing guarantees.
# Raised 0.4 -> 1.2 after playtest: "the rest of the 'flat' terrain needs more
# noise, it's far too flat and featureless." At the old value, an open_plains
# grown to 840 half-extent had 2.75 units of ambient relief across 1680 units
# of map - genuinely invisible from RTS camera height, and the reason authored
# hills read as the ONLY terrain on the map.
#
# 3x is not a guess: tools/probe_noise_amplitude.gd measures the ambient noise
# term's own slope distribution (hills and water_blobs stripped, so the
# measurement isn't swamped by their authored slope) and projects it, which is
# exact because height_at()'s noise term is linear in this constant. At 3x the
# p99 slope is 0.37 against MAX_WALKABLE_SLOPE 0.7 - roughly half, real
# headroom. 6x is where ordinary ground starts being rejected as unwalkable.
# Re-run that probe before moving this again; amplitude and walkability are
# coupled, and the coupling is not obvious from either constant alone.
const GROUND_NOISE_AMPLITUDE: float = 1.2
const GROUND_NOISE_FREQUENCY: float = 0.035
const MAX_WALKABLE_SLOPE: float = 0.7 # ~35 degrees

static var _noise_cache: Dictionary = {}

# CORE_DESIGN_LANGUAGE.md §3.2: at a larger world scale, ground undulation
# needs a longer wavelength to stay the same size RELATIVE to the (also
# larger) greeble dressing scattered on top of it - otherwise the terrain
# itself would look like it shrank while everything standing on it grew.
# Frequency is inverted (lower frequency = longer wavelength) so a bigger
# world_scale stretches the noise out rather than compressing it. The
# world_scale is folded into the cache key (not just used to build the
# FastNoiseLite once) so a map can genuinely change scale between calls -
# not that anything does yet at DEFAULT_WORLD_SCALE=1.0, but the naive
# single-entry-per-map-name cache would otherwise silently keep serving a
# stale frequency from before a scale change.
static func _get_noise(map_def: Dictionary) -> FastNoiseLite:
	var scale = WorldScaleScript.for_map(map_def)
	var map_name: String = map_def.get("name", "default")
	var key: String = "%s@%s" % [map_name, scale]
	if _noise_cache.has(key):
		return _noise_cache[key]
	var n = FastNoiseLite.new()
	n.seed = hash(map_name)
	n.noise_type = FastNoiseLite.TYPE_SIMPLEX
	n.frequency = GROUND_NOISE_FREQUENCY / scale
	_noise_cache[key] = n
	return n

# --- Heightmap-backed elevation (RTS_CORE_ROADMAP.md B4) ---
#
# tools/terrain/build_terrain.py's counterpart: bilinear-samples the
# 16-bit heightmap PNG a map's "terrain" block points at, instead of the
# noise+hills+water_blobs analytic path above. Flag-gated on
# map_def.terrain.heightmap actually being set - highland_chokepoint/
# twin_summits do (B6, migrated off the old elevation_zones/ramp system);
# the other 6 bundled maps don't, so they keep the analytic path.
#
# Encoding MUST exactly mirror build_terrain.py's encode_heightmap():
# normalized = pixel / 32767.5 - 1.0 (range [-1, 1]), world height =
# normalized * height_scale. Pixel (px, pz) <-> world (px - half, pz -
# half) at 1 pixel/world-unit (PIXELS_PER_UNIT in the Python script).
const HEIGHT_PIXEL_HALF_RANGE: float = 32767.5

static var _heightmap_cache: Dictionary = {}
static var _surfacemap_cache: Dictionary = {}

# null (not false) signals "no heightmap for this map" vs. "load failed" -
# both fall back to the old analytic path identically, but a null cache
# entry lets a failed load be retried instead of permanently wedged.
static func _get_heightmap_image(map_def: Dictionary) -> Image:
	var terrain: Dictionary = map_def.get("terrain", {})
	var path: String = terrain.get("heightmap", "")
	if path == "":
		return null
	if _heightmap_cache.has(path):
		return _heightmap_cache[path]
	var img: Image = null
	if ResourceLoader.exists(path):
		img = load(path) as Image
	elif FileAccess.file_exists(path):
		img = Image.load_from_file(ProjectSettings.globalize_path(path))
	_heightmap_cache[path] = img
	return img

static func _get_surfacemap_image(map_def: Dictionary) -> Image:
	var terrain: Dictionary = map_def.get("terrain", {})
	var path: String = terrain.get("surfacemap", "")
	if path == "":
		return null
	if _surfacemap_cache.has(path):
		return _surfacemap_cache[path]
	var img: Image = null
	if ResourceLoader.exists(path):
		img = load(path) as Image
	elif FileAccess.file_exists(path):
		img = Image.load_from_file(ProjectSettings.globalize_path(path))
	_surfacemap_cache[path] = img
	return img

# Test-only: forces the next _get_heightmap_image()/_get_surfacemap_image()
# call to reload from disk instead of reusing a cached Image - production
# never needs this (a map's heightmap is static for the process lifetime),
# but the automated suite runs everything in one process.
static func reset_heightmap_cache_for_tests() -> void:
	_heightmap_cache = {}
	_surfacemap_cache = {}
	# _corner_height_cache is derived from height_at(), which reads
	# _heightmap_cache - so it is exactly as stale as the caches above and
	# has to be dropped with them. A test that regenerates a fixture's
	# heightmap PNG and rebakes would otherwise keep baking the OLD
	# elevation, silently, with no error to show for it.
	_corner_height_cache = {}

# Clamped addressing at the edges (roadmap's own noted risk: without this,
# a unit standing exactly on the map boundary would sample past the image
# and jitter) - matches Image's own get_pixel() bounds, just done manually
# since bilinear needs the 4 neighbor pixels, one of which can be
# out-of-bounds by exactly 1 at the extreme edge.
# CORE_DESIGN_LANGUAGE.md §3.2 (Chunk 19): the heightmap PNG is a BAKED
# asset - build_terrain.py wrote it once at 1 pixel per world_scale=1.0
# world unit, for the map's ORIGINAL half_extents. It does not, and cannot,
# re-bake itself just because world_scale changed. `world_scale` maps the
# (already-scaled, per _apply_world_scale) incoming half_extents/x/z back
# down to the ORIGINAL space the pixel grid was actually authored in -
# without this, a scaled map's half_extents massively overshoots the real
# image bounds and every sample clamps to the edge, reading whatever
# happens to be there instead of the real terrain.
static func _sample_heightmap_bilinear(img: Image, half_extents: float, x: float, z: float, world_scale: float = 1.0) -> float:
	var dim = img.get_width()
	var original_half = half_extents / world_scale
	var original_x = x / world_scale
	var original_z = z / world_scale
	# World -> pixel space (float, sub-pixel precision for the bilinear lerp).
	# Scale-aware mapping so explicit pixels_per_unit or custom resolution sample accurately.
	var fx = clamp((original_x + original_half) / max(2.0 * original_half, 1e-6) * float(dim - 1), 0.0, float(dim - 1))
	var fz = clamp((original_z + original_half) / max(2.0 * original_half, 1e-6) * float(dim - 1), 0.0, float(dim - 1))
	var x0 = int(floor(fx))
	var z0 = int(floor(fz))
	var x1 = min(x0 + 1, dim - 1)
	var z1 = min(z0 + 1, dim - 1)
	var tx = fx - x0
	var tz = fz - z0

	var h00 = _decode_heightmap_pixel(img.get_pixel(x0, z0))
	var h10 = _decode_heightmap_pixel(img.get_pixel(x1, z0))
	var h01 = _decode_heightmap_pixel(img.get_pixel(x0, z1))
	var h11 = _decode_heightmap_pixel(img.get_pixel(x1, z1))
	var h0 = lerp(h00, h10, tx)
	var h1 = lerp(h01, h11, tx)
	return lerp(h0, h1, tz)

# build_terrain.py packs the 16-bit pixel value into R (high byte) + G (low
# byte) of an ordinary RGBA8 PNG - Godot's Image.load_from_file() does NOT
# reliably preserve a true 16-bit-grayscale PNG (verified empirically: it
# silently collapsed to 8-bit with every pixel saturating to 1.0), so this
# is the standard byte-split workaround, not the naive single-channel read.
static func _decode_heightmap_pixel(color: Color) -> float:
	var high_byte = round(color.r * 255.0)
	var low_byte = round(color.g * 255.0)
	var pixel16 = high_byte * 256.0 + low_byte
	return pixel16 / HEIGHT_PIXEL_HALF_RANGE - 1.0

# Nearest-sample (not bilinear - a surface TYPE can't be interpolated)
# palette index -> name. Must match build_terrain.py's SURFACE_PALETTE
# order exactly.
const SURFACE_PALETTE: Array = ["", "marsh", "rocky", "snow_mud", "sand", "gravel", "forest", "ice", "dirt", "steppe_grass", "dry_grass", "mud", "cobble", "scree", "volcanic"]

# Same "baked asset, not re-derived" reasoning as _sample_heightmap_
# bilinear() above - see that function's comment.
static func _sample_surfacemap(img: Image, half_extents: float, x: float, z: float, world_scale: float = 1.0) -> String:
	var dim = img.get_width()
	var original_half = half_extents / world_scale
	var original_x = x / world_scale
	var original_z = z / world_scale
	var fx = clamp((original_x + original_half) / max(2.0 * original_half, 1e-6) * float(dim - 1), 0.0, float(dim - 1))
	var fz = clamp((original_z + original_half) / max(2.0 * original_half, 1e-6) * float(dim - 1), 0.0, float(dim - 1))
	var px = int(round(fx))
	var pz = int(round(fz))
	var index = int(round(img.get_pixel(px, pz).r * 255.0))
	if index < 0 or index >= SURFACE_PALETTE.size():
		return ""
	return SURFACE_PALETTE[index]

static func _hill_contribution(hill: Dictionary, x: float, z: float) -> float:
	var c := _vec3_of(hill.get("center", Vector3.ZERO))
	var dist = Vector2(x - c.x, z - c.z).length()
	var radius: float = float(hill.get("radius", 10.0))
	var falloff: float = float(hill.get("falloff", 15.0))
	var height: float = float(hill.get("height", 8.0))
	if dist <= radius:
		return height
	if dist >= radius + falloff or falloff <= 0.0:
		return 0.0
	var t = (dist - radius) / falloff
	var s = t * t * (3.0 - 2.0 * t) # smoothstep, 0 at radius -> 1 at radius+falloff
	return height * (1.0 - s)


# --- Dramatic feature types -------------------------------------------------
#
# The new authoring vocabulary for hand-shaped terrain: plateau, canyon, ridge,
# lake. Each one writes BOTH a heightmap contribution (so height_at() returns
# the new ground level) AND auto-emits cliffs[] entries (so the sheer walls
# get colliders, navmesh holes, and the cliff.gdshader triplanar rock look
# without the user hand-placing every wall piece). The four new types reuse
# the existing hills[] / cliffs[] / water_areas[] / water_blobs[] machinery
# underneath - they're a higher-level authoring convenience, not a new
# runtime path. build_terrain.py mirrors the same functions for the heightmap
# PNG bake so the feature survives a non-runtime test.
#
# These are flat-topped rectangles with sheer walls. Replaces the old
# workaround of "lots of small hills in a square to fake a mesa" - the walls
# of that approach were the smooth falloff of the Gaussians, which is the
# exact "drive up it and it doesn't read as a wall" the user reported.
# Auto-emits 4 wall lines + 4 corner pieces around the perimeter so the
# edge reads as vertical rock at runtime, not as a gentle hill.
static func _plateau_contribution(feature: Dictionary, x: float, z: float) -> float:
	var c: Vector3 = _vec3_of(feature.get("center", Vector3.ZERO))
	# half_extents may be a JSON Array or Vector2 - the features[]
	# schema is unvalidated, so the decoder doesn't normalize. _vec_of
	# accepts both shapes.
	var he: Vector2 = _vec_of(feature.get("half_extents", Vector2(10, 10)))
	var hx: float = feature.get("half_extents_x", he.x)
	var hz: float = feature.get("half_extents_z", he.y)
	var height: float = feature.get("height", 8.0)
	var falloff: float = feature.get("wall_falloff", 2.0)
	# Distance to the AABB, signed positive outside.
	var dx = maxf(absf(x - c.x) - hx, 0.0)
	var dz = maxf(absf(z - c.z) - hz, 0.0)
	var outside = sqrt(dx * dx + dz * dz)
	if outside <= 0.0:
		return height
	if outside >= falloff or falloff <= 0.0:
		return 0.0
	var t = outside / falloff
	var s = t * t * (3.0 - 2.0 * t)
	return height * (1.0 - s)


# Sheer-walled depression between two parallel walls. start/end are the
# centerline endpoints; width is the floor width; depth is how far below
# the surrounding ground the floor sits (positive = below). Walls are
# vertical cliffs, the floor is a flat strip at the lowered height.
static func _canyon_contribution(feature: Dictionary, x: float, z: float) -> float:
	var start: Vector3 = _vec3_of(feature.get("start", Vector3.ZERO))
	var end: Vector3 = _vec3_of(feature.get("end", Vector3.ZERO))
	var width: float = feature.get("width", 12.0)
	var depth: float = feature.get("depth", 12.0)
	var wall_falloff: float = feature.get("wall_falloff", 2.0)
	# Project (x, z) onto the centerline.
	var axis := end - start
	var axis_len := axis.length()
	if axis_len < 1e-3:
		return 0.0
	var axis_dir := axis / axis_len
	var to_pt := Vector2(x - start.x, z - start.z)
	var along := to_pt.x * axis_dir.x + to_pt.y * axis_dir.z
	if along < 0.0 or along > axis_len:
		return 0.0  # outside the canyon's along-axis extent
	# Perpendicular distance from the centerline.
	var perp := to_pt.x * (-axis_dir.z) + to_pt.y * axis_dir.x
	var abs_perp := absf(perp)
	var floor_half := width * 0.5
	if abs_perp <= floor_half:
		return -depth  # inside the floor
	# In the wall band: from floor_half to floor_half + wall_falloff.
	var into_wall := abs_perp - floor_half
	if into_wall >= wall_falloff or wall_falloff <= 0.0:
		return 0.0  # outside the canyon entirely
	var t = into_wall / wall_falloff
	var s = t * t * (3.0 - 2.0 * t)
	return -depth * (1.0 - s)


# A polyline of high points with a flat ridge top. points is an array of
# [x, z] (or Vector2/Vector3) pairs. width is the ridge width on each
# side; height is the ridge top above the surrounding ground.
static func _ridge_contribution(feature: Dictionary, x: float, z: float) -> float:
	var pts = feature.get("points", [])
	if pts.size() < 2:
		return 0.0
	var width: float = feature.get("width", 6.0)
	var height: float = feature.get("height", 10.0)
	var falloff: float = feature.get("falloff", 2.0)
	# Find the nearest point on any segment of the polyline.
	var best_perp := INF
	var best_along_within := true
	for i in range(pts.size() - 1):
		var a: Vector2 = _vec_of(pts[i])
		var b: Vector2 = _vec_of(pts[i + 1])
		var seg: Vector2 = b - a
		var seg_len: float = seg.length()
		if seg_len < 1e-3:
			continue
		var seg_dir := seg / seg_len
		# _vec_of stores world-Z as Vector2.y, so the offset from point
		# a to the test point (x, z) is (test_x - a.x, test_z - a.y).
		var to_pt := Vector2(x - a.x, z - a.y)
		# Polylines are stored as Vector2 where .x = world-X, .y = world-Z
		# (per _vec_of at the bottom of this file), so the cross-product
		# math reads .x and .y on a Vector2, NOT .z. The previous untyped
		# `var seg := b - a` form was Variant-by-typing and hid this; now
		# that seg is strictly Vector2 the .z on a 2D was a parse error.
		var along := to_pt.x * seg_dir.x + to_pt.y * seg_dir.y
		if along < 0.0 or along > seg_len:
			best_along_within = false
			continue
		var perp := to_pt.x * (-seg_dir.y) + to_pt.y * seg_dir.x
		var abs_perp := absf(perp)
		if abs_perp < best_perp:
			best_perp = abs_perp
	if not best_along_within:
		return 0.0
	if best_perp == INF:
		return 0.0
	if best_perp <= width:
		return height
	if best_perp >= width + falloff or falloff <= 0.0:
		return 0.0
	var t = (best_perp - width) / falloff
	var s = t * t * (3.0 - 2.0 * t)
	return height * (1.0 - s)


# A round water feature with a soft shoreline. The center drops to
# -depth; the shoreline falls off smoothly to 0 over shoreline_falloff.
# Auto-emits a water_blob so the visible water mesh and the navmesh
# amphibious region both light up - same pattern as the existing
# hand-authored lakes on open_plains.
static func _lake_contribution(feature: Dictionary, x: float, z: float) -> float:
	var c: Vector3 = _vec3_of(feature.get("center", Vector3.ZERO))
	var radius: float = feature.get("radius", 12.0)
	var depth: float = feature.get("depth", 3.0)
	var falloff: float = feature.get("shoreline_falloff", 4.0)
	var dist = Vector2(x - c.x, z - c.z).length()
	if dist <= radius:
		return -depth
	if dist >= radius + falloff or falloff <= 0.0:
		return 0.0
	var t = (dist - radius) / falloff
	var s = t * t * (3.0 - 2.0 * t)
	return -depth * (1.0 - s)


# Single dispatch entry point. height_at() calls this once per feature per
# sample, so it must stay cheap - each type's contribution is a couple of
# mults and a smoothstep, the worst case is a 4-point ridge walking a 4-
# segment polyline (~30 ops per call). Verified negligible against the
# 90,000-sample navmesh rebake that already runs every match.
static func _feature_contribution(feature: Dictionary, x: float, z: float) -> float:
	match feature.get("type", ""):
		"plateau":
			return _plateau_contribution(feature, x, z)
		"canyon":
			return _canyon_contribution(feature, x, z)
		"ridge":
			return _ridge_contribution(feature, x, z)
		"lake":
			return _lake_contribution(feature, x, z)
		"ramp":
			return _ramp_contribution(feature, x, z)
		_:
			return 0.0


# Rectangular ramp descending from a plateau edge to ground level. 2026-08-26:
# canyon_ford from-scratch rebuild - the hand-drawn map has 5 ramps (yellow
# blobs) connecting plateau tops to the surrounding grassland, and the only
# sensible way to author them in JSON is "an anchor point at the plateau
# edge, a direction the ramp points outward, a width, a length, and a
# top_height (= the plateau's height)". The contribution is a clean wedge:
# full top_height at the anchor, linearly descending to 0 at the outer
# end, with hard width edges. Smooth side-falloff is left for v2 - the
# plateau's own wall_falloff (which the heightmap blends into the
# surrounding ground at the cliff line) already provides the visual
# "rocky slopes merging into the traversible ramp" the user described in
# the sketch.
#
# Convention: 0 deg = +X (east), 90 deg = -Z (north), 180 deg = -X (west),
# 270 deg = +Z (south). The ramp points OUT from the anchor in that
# direction. Auto-emission is a no-op - the ramp only contributes to the
# heightmap, the cliff piece at the anchor stays in place (it sits at the
# bottom of the ramp, the heightmap ramp goes from top_height at the
# anchor down to 0 over `length`).
static func _ramp_contribution(feature: Dictionary, x: float, z: float) -> float:
	var anchor: Vector3 = _vec3_of(feature.get("anchor", Vector3.ZERO))
	var direction_deg: float = feature.get("direction_deg", 0.0)
	var width: float = feature.get("width", 12.0)
	var length: float = feature.get("length", 30.0)
	var top_height: float = feature.get("top_height", 8.0)
	var rad: float = deg_to_rad(direction_deg)
	# 0 deg = +X (east), 90 deg = -Z (north), 180 deg = -X, 270 deg = +Z.
	# In screen-space Y, north is up; in Godot's XZ plane, -Z is "into the
	# scene" (the conventional forward direction). sin/cos here give the
	# (dx, -dz) decomposition so a 90 deg ramp really does go north.
	var dir_x: float = cos(rad)
	var dir_z: float = -sin(rad)
	var dx: float = x - anchor.x
	var dz: float = z - anchor.z
	# Along the ramp's outward axis (positive = away from the anchor).
	var along: float = dx * dir_x + dz * dir_z
	if along < 0.0 or along > length:
		return 0.0
	# Perpendicular distance from the ramp's centerline.
	var perp_x: float = -dir_z
	var perp_z: float = dir_x
	var perp: float = dx * perp_x + dz * perp_z
	if absf(perp) > width * 0.5:
		return 0.0
	# Linear descent from top_height at the anchor to 0 at the outer end.
	var t: float = along / length  # 0 at anchor, 1 at outer end
	return top_height * (1.0 - t)


# Convert a JSON point entry to Vector2 - the user might author as [x, z],
# as Vector2, or as a full Vector3. Same point in the bridge/cliff parsers
# in this file use the same shape; kept local here so the features don't
# reach into the existing helpers.
static func _vec_of(pt) -> Vector2:
	if pt is Vector3:
		return Vector2(pt.x, pt.z)
	if pt is Vector2:
		return pt
	if pt is Array and pt.size() >= 2:
		return Vector2(float(pt[0]), float(pt[1]))
	return Vector2.ZERO


# Convert a JSON 3D point to Vector3. Same pattern as _vec_of: accepts
# Array ([x, y, z]), Vector3, or Vector2 (treated as XZ with y=0).
# The features[] entries in canyon_ford.json are authored as raw Arrays
# (the FIELD_SPEC has features as an unvalidated discriminated union;
# the deep-decoder doesn't convert them), so the auto-emission code
# has to accept both shapes. Same point: in the bridge / hill parsers
# earlier in this file the assumption is that the decoder already
# converted Array -> Vector3; that's not true for features[].
static func _vec3_of(pt) -> Vector3:
	if pt is Vector3:
		return pt
	if pt is Vector2:
		return Vector3(pt.x, 0.0, pt.y)
	if pt is Array and pt.size() >= 3:
		return Vector3(float(pt[0]), float(pt[1]), float(pt[2]))
	if pt is Array and pt.size() >= 2:
		return Vector3(float(pt[0]), 0.0, float(pt[1]))
	return Vector3.ZERO

# Deterministic per-blob coastline wobble - a couple of harmonics gives a
# smooth organic curve (not a perfect circle, not jagged/noisy), seeded from
# the blob's own center so it's stable across reloads without needing to
# store an authored polygon.
static func _water_blob_radius_at_angle(blob: Dictionary, theta: float) -> float:
	var base: float = blob.get("radius", 10.0)
	var irregularity: float = blob.get("irregularity", 0.25)
	var s: float = float(hash(blob.get("center", Vector3.ZERO)) % 1000) * 0.01
	var wobble = sin(theta * 3.0 + s) * 0.6 + sin(theta * 5.0 + s * 1.7) * 0.4
	return base * (1.0 + irregularity * wobble * 0.5)

static func _point_in_water_blob(blob: Dictionary, x: float, z: float) -> bool:
	var c := _vec3_of(blob.get("center", Vector3.ZERO))
	var dx = x - c.x
	var dz = z - c.z
	var theta = atan2(dz, dx)
	return Vector2(dx, dz).length() <= _water_blob_radius_at_angle(blob, theta)

static func _water_blob_height_contribution(blob: Dictionary, x: float, z: float) -> float:
	var c := _vec3_of(blob.get("center", Vector3.ZERO))
	var dx = x - c.x
	var dz = z - c.z
	var dist = Vector2(dx, dz).length()
	var theta = atan2(dz, dx)
	var edge = _water_blob_radius_at_angle(blob, theta)
	var blend: float = blob.get("shore_blend", 4.0)
	var depth: float = blob.get("depth", 1.2)
	if dist <= edge:
		return -depth
	if dist >= edge + blend or blend <= 0.0:
		return 0.0
	var t = (dist - edge) / blend
	var s = t * t * (3.0 - 2.0 * t) # smoothstep, 0 at edge -> 1 at edge+blend
	return -depth * (1.0 - s)

# The single continuous elevation query - noise everywhere, plus authored
# hills/water_blobs layered on top (or a real heightmap replacing all
# three - see below). Deliberately does NOT know about water_areas/
# bridges; terrain_height_at() below still owns that logic entirely,
# falling back to this function only where none of those apply.
# The highest the terrain can reach on this map, without sampling it.
#
# Exists for the fog shroud, which is a flat plane and therefore has to be
# placed above EVERY piece of ground or the ground renders through it. The
# shroud constant used to be 0.4, silently equal to GROUND_NOISE_AMPLITUDE -
# it was not "a small offset", it was exactly the terrain maximum, and the
# equality was never written down. Chunk 9 scaled the noise and left the
# shroud behind, so hilltops punched through the fog in elevation-shaped
# patches, and any heightmap map (height_scale 20, scaled) was far worse.
#
# Deliberately an upper BOUND rather than a measured maximum: cheap, stable,
# and erring high only lifts the shroud slightly.
static func max_height(map_def: Dictionary) -> float:
	if bool(map_def.get("flat_ground_collider", false)):
		return 0.0
	if _get_heightmap_image(map_def):
		# Heightmap samples are normalized 0..1, so height_scale IS the ceiling.
		return float(map_def.get("terrain", {}).get("height_scale", 20.0))
	var h: float = WorldScaleScript.scaled_f(GROUND_NOISE_AMPLITUDE, map_def)
	for hill in map_def.get("hills", []):
		h += absf(float(hill.get("height", 0.0)))
	return h


# How far the navmesh surface can sit from where a unit's body actually
# stands, vertically.
#
# The ground navmesh SOURCE geometry is deliberately flat on maps without a
# heightmap (see _build_ground_faces), while terrain_height_at() - which is
# what actually positions a body - is not. That gap is by design and was
# harmless at 0.4 units of relief. Scaling the world multiplied the relief
# without touching NavigationAgent3D.path_desired_distance, which is measured
# in 3D: at world_scale=4 the vertical error alone (~1 unit) consumed the
# entire 1-unit corner tolerance, so an agent sat exactly at the threshold of
# its first corner and never advanced. The unit then steered on a corner
# offset of a few centimetres that flipped sign every tick - a stationary
# wobble, which is what this looked like on screen.
#
# Heightmap maps emit real corner heights, so only the bake quantisation
# applies there.
static func nav_vertical_slack(map_def: Dictionary) -> float:
	return NAV_CELL_HEIGHT * 2.0


static func height_at(map_def: Dictionary, x: float, z: float) -> float:
	if bool(map_def.get("flat_ground_collider", false)):
		return 0.0
	# RTS_CORE_ROADMAP.md B4/B6: a real heightmap FULLY REPLACES the
	# analytic noise+hills+water_blobs path below (not layered on top of
	# it - a map authoring real terrain.features doesn't also want
	# procedural noise added in). Flag-gated on map_def.terrain.heightmap
	# actually being set - highland_chokepoint/twin_summits do (B6); the
	# other 6 bundled maps don't, so they still take the analytic path.
	var heightmap_img = _get_heightmap_image(map_def)
	if heightmap_img:
		# 2026-08-26: canyon_ford's from-scratch rebuild uses the
		# analytic features[] path (plateau / ramp / etc), NOT a baked
		# heightmap PNG, so the heightmap sampler is still square-aware
		# for now. The non-square map is sized by half_extents() above
		# (X for the ground mesh and navmesh, Z via _build_ground_faces'
		# per-axis walk). A non-square heightmap PNG is a follow-up
		# refactor - the bilinear sampler below currently assumes a
		# square image and a square world footprint; the analytic path
		# this rebuild actually uses doesn't touch it.
		var half: float = map_def.get("map_half_extents", 80.0)
		var height_scale: float = map_def.get("terrain", {}).get("height_scale", 20.0)
		# height_scale is itself a FIELD_SPEC-flagged field (already scaled
		# by _apply_world_scale, on purpose - a taller map should have
		# taller hills) - only the PIXEL SAMPLING position needs the
		# world_scale correction below, not the height magnitude.
		return _sample_heightmap_bilinear(heightmap_img, half, x, z, WorldScaleScript.for_map(map_def)) * height_scale

	var h = _get_noise(map_def).get_noise_2d(x, z) * WorldScaleScript.scaled_f(GROUND_NOISE_AMPLITUDE, map_def)
	for hill in map_def.get("hills", []):
		h += _hill_contribution(hill, x, z)
	for blob in map_def.get("water_blobs", []):
		h += _water_blob_height_contribution(blob, x, z)
	# Dramatic features: plateau / canyon / ridge / lake. Each writes its own
	# analytic height contribution on top of the noise + hills + water_blobs
	# above, so a map can mix legacy hills with new feature types in the
	# same file without one path stomping the other. (See _resolve_features()
	# for the cliffs[] / water_areas[] auto-emission that runs once at load.)
	var terr = map_def.get("terrain", {})
	var features: Array = terr.get("features", []) if typeof(terr) == TYPE_DICTIONARY else []
	if not features.is_empty() and str(terr.get("generator", "")) == "v2":
		h += _v2_feature_height(features, x, z)
	else:
		for feature in features:
			h += _feature_contribution(feature, x, z)
	if typeof(terr) == TYPE_DICTIONARY and terr.has("sculpt_grid"):
		var sg = terr["sculpt_grid"]
		if typeof(sg) == TYPE_DICTIONARY:
			var s_data: Array = sg.get("data", [])
			var s_dim: int = int(sg.get("dim", 0))
			var s_half: float = float(sg.get("half_extents", map_def.get("map_half_extents", 80.0)))
			if s_dim > 1 and s_data.size() >= s_dim * s_dim and s_half > 0.0:
				var u: float = clampf((x + s_half) / (s_half * 2.0), 0.0, 1.0) * float(s_dim - 1)
				var v: float = clampf((z + s_half) / (s_half * 2.0), 0.0, 1.0) * float(s_dim - 1)
				var ix: int = clampi(int(floor(u)), 0, s_dim - 2)
				var iz: int = clampi(int(floor(v)), 0, s_dim - 2)
				var fx: float = u - float(ix)
				var fz: float = v - float(iz)
				var h00: float = float(s_data[iz * s_dim + ix])
				var h10: float = float(s_data[iz * s_dim + (ix + 1)])
				var h01: float = float(s_data[(iz + 1) * s_dim + ix])
				var h11: float = float(s_data[(iz + 1) * s_dim + (ix + 1)])
				var sh: float = lerpf(lerpf(h00, h10, fx), lerpf(h01, h11, fx), fz)
				h += sh

	# Dynamic Building Flattening Pads (In-Game base buildings, HQ, Refinery & outer dock bays)
	if map_def.has("building_pads"):
		var pads: Array = map_def.get("building_pads", [])
		for pad in pads:
			var cx: float = float(pad.get("center_x", 0.0))
			var cz: float = float(pad.get("center_z", 0.0))
			var hx: float = float(pad.get("half_x", 5.0))
			var hz: float = float(pad.get("half_z", 5.0))
			var yaw: float = float(pad.get("yaw", 0.0))
			var target_h: float = float(pad.get("target_h", 0.0))
			var falloff: float = float(pad.get("falloff", 4.0))

			var dx: float = x - cx
			var dz: float = z - cz
			var lx: float = dx
			var lz: float = dz
			if absf(yaw) > 0.001:
				var cos_y := cos(-yaw)
				var sin_y := sin(-yaw)
				lx = dx * cos_y - dz * sin_y
				lz = dx * sin_y + dz * cos_y
			var ox: float = maxf(0.0, absf(lx) - hx)
			var oz: float = maxf(0.0, absf(lz) - hz)
			var dist: float = sqrt(ox * ox + oz * oz)
			if dist <= 0.0:
				h = target_h
			elif dist < falloff:
				var t := dist / falloff
				var w := (1.0 - t) * (1.0 - t) * (1.0 + 2.0 * t)
				h = lerpf(h, target_h, w)
	return h

# v2 feature composition: raised features take the TALLEST, carved features the
# DEEPEST, instead of every feature summing.
#
# Summation is wrong for the one thing plateaus exist to support - a ramp.
# A ramp's anchor sits ON the plateau edge and carries top_height, and the
# plateau's own contribution is still full `height` there (it decays only
# OUTSIDE its AABB), so the two add: a 15 m plateau with a 15 m ramp builds a
# 30 m spike at the lip, decaying back to 15 m across the wall_falloff band.
# That is a ~15 m rise over ~3.5 m, slope ~4.3 - far past MAX_WALKABLE_SLOPE
# of 0.7. The ramp ends in a wall, and the plateau it was meant to open up is
# unreachable. Anchoring outside the falloff instead trades the spike for a
# notch, because the ramp contributes nothing behind its anchor.
#
# max/min composes the way the author means it: where a ramp and a plateau
# overlap, the ground is whichever is higher, so the ramp runs cleanly from
# the plateau top down to grade with no lip at all. Two overlapping plateaus
# give the taller; two overlapping canyons give the deeper.
#
# Gated to generator "v2" and applied only when a map actually declares
# features, so every v1 map takes the summing path unchanged.
static func _v2_feature_height(features: Array, x: float, z: float) -> float:
	var raised: float = 0.0
	var carved: float = 0.0
	for feature in features:
		var c: float = _feature_contribution(feature, x, z)
		if c > 0.0:
			raised = maxf(raised, c)
		elif c < 0.0:
			carved = minf(carved, c)
	return raised + carved

static func slope_at(map_def: Dictionary, x: float, z: float) -> float:
	return _slope_at(map_def, x, z)


# --- Dressing inputs --------------------------------------------------------
#
# Which compass direction a slope FACES, in degrees: 0 = north (downhill runs
# toward -Z), 90 = east, 180 = south, 270 = west. Returns -1.0 on ground flat
# enough to have no meaningful aspect, which callers must treat as "matches no
# aspect rule" rather than as north.
#
# Needed because sun exposure is what actually sorts vegetation in the real
# world - conifers and moss hold the shaded north face, dry scrub takes the
# sunny south - and the scatter had no way to ask. Every rule was slope-only,
# so a hillside looked identical whichever way it pointed.
static func aspect_at(map_def: Dictionary, x: float, z: float) -> float:
	const D := 1.0
	var h0 := height_at(map_def, x, z)
	var dh_dx := (height_at(map_def, x + D, z) - h0) / D
	var dh_dz := (height_at(map_def, x, z + D) - h0) / D
	if absf(dh_dx) < 1e-5 and absf(dh_dz) < 1e-5:
		return -1.0
	# Downhill is the NEGATIVE gradient; atan2(down.x, -down.z) puts 0 at -Z.
	return fposmod(rad_to_deg(atan2(-dh_dx, dh_dz)), 360.0)


# Distance in world units to the nearest water, or INF when the map has none.
# Reeds belong at the shoreline and pines do not; without this the scatter
# could only express "inside water" or "not", which is not the same question.
# Distance to the nearest water, INCLUDING the table and painted bodies.
#
# Rects and blobs are analytic, but the table and painted lakes are an
# arbitrary raster shape, so those go through a cached distance field. Building
# one is not optional at this scale: the dressing asks this question once per
# candidate placement - tens of thousands of times per map - and a radial search
# per query would cost more than the whole dressing pass.
#
# ~6 m per texel, capped at 384 on a side. The threshold that matters is
# shore_reed's 13 m; bilinear sampling of a 6 m field lands inside ~3 m of the
# true distance there, which is finer than the reeds are big.
const WATER_FIELD_TARGET_TEXEL: float = 6.0
const WATER_FIELD_MAX_DIM: int = 384

static var _water_field_cache: Dictionary = {}


static func clear_water_field_cache() -> void:
	_water_field_cache = {}


static func _water_distance_field(map_def: Dictionary) -> Dictionary:
	var key: String = "%s|%.3f" % [str(map_def.get("id", "")), water_level_of(map_def)]
	if _water_field_cache.has(key):
		return _water_field_cache[key]
	var half: Vector2 = MapCatalogScript.half_extents(map_def)
	var span: float = maxf(half.x, half.y) * 2.0
	var dim: int = clampi(int(round(span / WATER_FIELD_TARGET_TEXEL)), 16, WATER_FIELD_MAX_DIM)
	var step_x: float = (half.x * 2.0) / float(dim)
	var step_z: float = (half.y * 2.0) / float(dim)

	var dist := PackedFloat32Array()
	dist.resize(dim * dim)
	var any := false
	for j in range(dim):
		var z: float = -half.y + (float(j) + 0.5) * step_z
		for i in range(dim):
			var x: float = -half.x + (float(i) + 0.5) * step_x
			if submerged_at(map_def, x, z):
				dist[j * dim + i] = 0.0
				any = true
			else:
				dist[j * dim + i] = 1.0e9

	var out := {"dim": dim, "step": maxf(step_x, step_z), "half": half, "any": any, "dist": dist}
	if not any:
		_water_field_cache[key] = out
		return out

	# Two-pass chamfer transform. Exact Euclidean would need a much heavier
	# algorithm for an accuracy nobody can see at prop scale; chamfer's error
	# is a couple of percent, well under the field's own 6 m quantisation.
	var d_ortho: float = maxf(step_x, step_z)
	var d_diag: float = d_ortho * 1.41421356
	for j in range(dim):
		for i in range(dim):
			var idx: int = j * dim + i
			var v: float = dist[idx]
			if i > 0:
				v = minf(v, dist[idx - 1] + d_ortho)
			if j > 0:
				v = minf(v, dist[idx - dim] + d_ortho)
				if i > 0:
					v = minf(v, dist[idx - dim - 1] + d_diag)
				if i < dim - 1:
					v = minf(v, dist[idx - dim + 1] + d_diag)
			dist[idx] = v
	for j in range(dim - 1, -1, -1):
		for i in range(dim - 1, -1, -1):
			var idx2: int = j * dim + i
			var v2: float = dist[idx2]
			if i < dim - 1:
				v2 = minf(v2, dist[idx2 + 1] + d_ortho)
			if j < dim - 1:
				v2 = minf(v2, dist[idx2 + dim] + d_ortho)
				if i < dim - 1:
					v2 = minf(v2, dist[idx2 + dim + 1] + d_diag)
				if i > 0:
					v2 = minf(v2, dist[idx2 + dim - 1] + d_diag)
			dist[idx2] = v2
	out["dist"] = dist
	_water_field_cache[key] = out
	return out


static func _sample_water_field(map_def: Dictionary, x: float, z: float) -> float:
	var f: Dictionary = _water_distance_field(map_def)
	if not bool(f.get("any", false)):
		return INF
	var dim: int = int(f["dim"])
	var half: Vector2 = f["half"]
	var u: float = clampf((x / (half.x * 2.0) + 0.5) * float(dim) - 0.5, 0.0, float(dim - 1))
	var v: float = clampf((z / (half.y * 2.0) + 0.5) * float(dim) - 0.5, 0.0, float(dim - 1))
	var i0: int = int(u)
	var j0: int = int(v)
	var i1: int = mini(i0 + 1, dim - 1)
	var j1: int = mini(j0 + 1, dim - 1)
	var fu: float = u - float(i0)
	var fv: float = v - float(j0)
	var d: PackedFloat32Array = f["dist"]
	var a: float = lerpf(d[j0 * dim + i0], d[j0 * dim + i1], fu)
	var b: float = lerpf(d[j1 * dim + i0], d[j1 * dim + i1], fu)
	return lerpf(a, b, fv)


static func water_distance_at(map_def: Dictionary, x: float, z: float) -> float:
	_resolve_features(map_def)
	var best := _sample_water_field(map_def, x, z)
	for w in map_def.get("water_areas", []):
		var c: Vector3 = _vec3_of(w.get("center", Vector3.ZERO))
		var he: Vector2 = _vec_of(w.get("half_extents", Vector2(1, 1)))
		var dx: float = maxf(absf(x - c.x) - he.x, 0.0)
		var dz: float = maxf(absf(z - c.z) - he.y, 0.0)
		best = minf(best, sqrt(dx * dx + dz * dz))
	for b in map_def.get("water_blobs", []):
		var cb: Vector3 = _vec3_of(b.get("center", Vector3.ZERO))
		var r: float = float(b.get("radius", 10.0))
		best = minf(best, maxf(Vector2(x - cb.x, z - cb.z).length() - r, 0.0))
	return best


# Local convexity: positive on ridges and rims, negative in hollows and gullies.
# Normalised roughly to -1..1 over `d`. Scree collects in hollows; exposed rock
# sits on the convex edges.
static func curvature_at(map_def: Dictionary, x: float, z: float, d: float = 4.0) -> float:
	var h := height_at(map_def, x, z)
	var sum := height_at(map_def, x + d, z) + height_at(map_def, x - d, z) \
		+ height_at(map_def, x, z + d) + height_at(map_def, x, z - d)
	return clampf((h - sum * 0.25) / maxf(d * 0.5, 0.001), -1.0, 1.0)

static func _slope_at(map_def: Dictionary, x: float, z: float) -> float:
	const D = 0.5
	var h0 = height_at(map_def, x, z)
	var hx = height_at(map_def, x + D, z)
	var hz = height_at(map_def, x, z + D)
	return Vector2((hx - h0) / D, (hz - h0) / D).length()

const WATER_BLOB_SEGMENTS: int = 24

static func _water_blob_polygon(blob: Dictionary) -> PackedVector2Array:
	var pts = PackedVector2Array()
	for i in range(WATER_BLOB_SEGMENTS):
		var theta = (float(i) / WATER_BLOB_SEGMENTS) * TAU
		var r = _water_blob_radius_at_angle(blob, theta)
		pts.append(Vector2(cos(theta) * r, sin(theta) * r))
	return pts

# Triangle fan from the blob's center out to its (organic) boundary ring, at
# a fixed Y - used both for the flat water navmesh faces and the visual
# water mesh. Winding follows the same low-to-high-angle sweep already
# proven to bake correctly for the rect water/ground quads elsewhere in
# this file (Recast silently drops a triangle whose winding doesn't match
# its walkable-surface convention) - increasing theta is the same
# rotational sense as those quads' x0->x1/z0->z1 sweep.
static func _water_blob_fan_verts(blob: Dictionary, y: float) -> PackedVector3Array:
	var c: Vector3 = blob.center
	var poly = _water_blob_polygon(blob)
	var verts = PackedVector3Array()
	for i in range(poly.size()):
		var p0 = poly[i]
		var p1 = poly[(i + 1) % poly.size()]
		verts.append(Vector3(c.x, y, c.z))
		verts.append(Vector3(c.x + p0.x, y, c.z + p0.y))
		verts.append(Vector3(c.x + p1.x, y, c.z + p1.y))
	return verts

# --- Geometry helpers ---

static func _rect_from(center: Vector3, half_extents: Vector2) -> Dictionary:
	return {"x0": center.x - half_extents.x, "x1": center.x + half_extents.x,
		"z0": center.z - half_extents.y, "z1": center.z + half_extents.y}

static func _rect_overlaps(cx0: float, cx1: float, cz0: float, cz1: float, rect: Dictionary) -> bool:
	return cx0 < rect.x1 and cx1 > rect.x0 and cz0 < rect.z1 and cz1 > rect.z0

static func _point_in_rect(pos: Vector3, rect: Dictionary) -> bool:
	return pos.x >= rect.x0 and pos.x <= rect.x1 and pos.z >= rect.z0 and pos.z <= rect.z1

static func _add_nav_quad(verts: PackedVector3Array, a: Vector3, b: Vector3, c: Vector3, d: Vector3):
	verts.append(a); verts.append(b); verts.append(c)
	verts.append(a); verts.append(c); verts.append(d)

# Organic water_blobs can't be tested with the same rect-overlap check the
# rest of this file uses - a grid cell counts as "on" a blob if its CENTER
# point falls inside the blob's per-angle radius. At GRID_CELL (4.0)
# resolution against a blob typically tens of units across, a center-point
# sample tracks the true organic boundary closely enough that the resulting
# navmesh hole reads as a real coastline, not a blocky approximation.
static func _cell_on_water_blob(x0: float, x1: float, z0: float, z1: float, map_def: Dictionary) -> bool:
	var blobs = map_def.get("water_blobs", [])
	if blobs.is_empty(): return false
	var cx = (x0 + x1) / 2.0
	var cz = (z0 + z1) / 2.0
	for blob in blobs:
		if _point_in_water_blob(blob, cx, cz):
			return true
	return false

# Obstacles/elevation always block ground faces; water normally does too,
# EXCEPT where a bridge crosses it - bridges carve a walkable strip straight
# through the water hole so ground units get a real, narrow crossing point
# flanked by water on both sides (a genuine tactical chokepoint), rather than
# being a flag that just turns water off entirely. Not used by
# _build_amphibious_faces() - water there is already walkable for every
# amphibious unit, so a bridge carve-out would be a no-op - and deliberately
# NOT used by _build_deep_water_faces()/water_map either, so naval units keep
# floating and passing freely underneath, same as a real bridge over a river.
static func _collect_bridges(map_def: Dictionary) -> Array:
	var bridges = []
	for b in map_def.get("bridges", []):
		bridges.append(_rect_from(b.center, b.half_extents))
	return bridges

static func _cell_on_bridge(x0: float, x1: float, z0: float, z1: float, bridges: Array) -> bool:
	for b in bridges:
		if _rect_overlaps(x0, x1, z0, z1, b):
			return true
	return false

# --- Navmesh source geometry ---
#
# Flat (Y=0 baseline, real Y only for bridges) for a map with no
# heightmap - real per-vertex noise across a ~240-half-extent map pushed a
# single Recast bake from milliseconds to 10+ seconds (unacceptable at 4
# navmeshes per match start), and neither navmesh Y precision nor Recast's
# own slope-walkability check are actually consumed anywhere for that path
# - every unit/building's real on-screen Y comes from a fresh
# terrain_height_at() query every tick, never from a navmesh path point's
# Y - so staying flat loses nothing gameplay depends on. A heightmap-
# backed map (RTS_CORE_ROADMAP.md B4/B5) samples REAL corner heights
# instead and REJECTS any cell whose slope exceeds MAX_WALKABLE_SLOPE - an
# O(1) image lookup per corner, not the expensive noise+hill/blob loop
# stack, so the same bake-time problem doesn't apply.
# Corner-height grid, computed once per (map, grid) and reused.
#
# _build_ground_faces() samples height_at() at all four corners of every grid
# cell. Adjacent cells share corners, so every interior corner was being
# resampled four times: on highland_chokepoint (a 150x150 grid) that is
# ~90,000 bilinear heightmap samples, measured at 469ms of a 676ms rebake
# once _nav_cell_size() had brought the Recast bake itself down to ~90ms.
#
# Caching across calls (not just within one) is what makes the mid-match
# rebake cheap, and it is safe because terrain height is immutable for the
# life of a match - height_at() reads the map's heightmap/hills/noise, none
# of which change. Only the building holes change between rebakes, and those
# are applied separately below as rect tests, never through this grid.
#
# Float64 (not 32) deliberately: these values feed the max_slope >
# MAX_WALKABLE_SLOPE comparison, and a cell sitting exactly on that
# threshold should not flip walkability because the cache rounded it.
static var _corner_height_cache: Dictionary = {}

static func _corner_heights(map_def: Dictionary, half: Vector2, cell: float) -> Dictionary:
	# Keyed on the heightmap PATH as well as the name: two map dicts can
	# share a name (or have none at all - test fixtures and inline dicts
	# like {"map_half_extents": 300.0} are common in run_tests.gd) while
	# describing completely different elevation, and silently serving one
	# map's heights for another would be near-impossible to diagnose from
	# the symptom (a subtly wrong navmesh).
	# 2026-08-26: non-square map support - `half` is now Vector2 [hx, hz].
	# Cache key includes both axes; the grid is now per-axis (n_x, n_z)
	# rather than a single n, since the same cell size on a 1200x520 map
	# gives 150 X-samples and 65 Z-samples (not 150x150, which would
	# over-sample Z by ~2.3x and bake navmesh nav-poly vertices outside
	# the actual playable ground).
	var terrain: Dictionary = map_def.get("terrain", {})
	var key = "%s:%s:%s:%s:%s" % [map_def.get("name", ""), terrain.get("heightmap", ""), half.x, half.y, cell]
	if _corner_height_cache.has(key):
		return _corner_height_cache[key]
	# Exactly the boundary sequence the while-loops below walk (v = min(v +
	# cell, half_axis), terminating at half_axis), so corner i is always
	# grid line i.
	var coords_x := PackedFloat64Array()
	var v_x := -half.x
	coords_x.append(v_x)
	while v_x < half.x:
		v_x = min(v_x + cell, half.x)
		coords_x.append(v_x)
	var coords_z := PackedFloat64Array()
	var v_z := -half.y
	coords_z.append(v_z)
	while v_z < half.y:
		v_z = min(v_z + cell, half.y)
		coords_z.append(v_z)
	var n_x := coords_x.size()
	var n_z := coords_z.size()
	var heights := PackedFloat64Array()
	heights.resize(n_x * n_z)
	for i in range(n_x):
		for j in range(n_z):
			heights[i * n_z + j] = height_at(map_def, coords_x[i], coords_z[j])
	var out := {"heights": heights, "n_x": n_x, "n_z": n_z}
	_corner_height_cache[key] = out
	return out

# CORE_DESIGN_LANGUAGE.md §3.2 (2026-08-08 playtest): _nav_grid_cell()'s
# formula (Chunk 14) deliberately widens the terrain SOURCE quad size as
# map_half_extents grows, to keep triangle count bounded on huge maps - a
# self-bounding choice proven safe for OPEN terrain. It was not, until now,
# tested against small clustered features: at open_plains' world_scale=4
# quad size (~11.2 units), a single building's few-metre footprint touching
# ANY part of a quad OMITS THE ENTIRE QUAD (see the loop below - "blocked"
# skips emitting it at all), and a compact base's several buildings each
# swallowing a full quad can MERGE into a hole many times larger than the
# buildings themselves. Confirmed live: a harvester's own compacted spawn
# point ended up stranded in a ~20-unit hole next to its base, with
# NavigationAgent3D permanently stuck offering the same near-spawn waypoint
# (tools/probe_navmesh_grid.gd maps the exact shape). Below this threshold,
# a coarse quad that touches a hard hole is re-tested at fine resolution
# instead of omitted wholesale, so a small building only removes the area
# it actually occupies.
#
# 1.0, not 2.0. At 2.0 the re-test still rounded every hole OUTWARD by up to
# two units, which is not a rounding error at this scale - it is larger than
# the margin the exit_offset and dock_bay constants were tuned against. Every
# manufactory's exit_position() measured 1.0-2.5 units INSIDE the baked hole
# (tools/probe_factory_exit.gd), so a factory-built unit spawned off-mesh,
# accepted its move order, turned to face it, and then circled forever with
# no valid path start.
const HOLE_SUBDIVISION_CELL: float = 1.0
# Shoreline cells subdivide too (see _build_ground_faces), but NOT at the hole
# resolution. A building edge is a hard line a metre matters on; a waterline is
# not, and the difference is measured in seconds of load time.
#
# _emit_subdivided_ground_quad() calls terrain_height_at() four times per
# sub-quad, so the cost of this constant is quadratic in 1/sub_cell. At 1.0 m
# the ground-face build on delta_blues went 175 ms -> 2421 ms and
# saltpan_crossing 461 ms -> 4640 ms, for a final navmesh Recast voxelises back
# down to almost the same polygon count (delta_blues 1308 -> 1344). Those
# triangles were bought and then thrown away.
#
# 3.0 m still resolves a channel inside a ~5.8 m nav cell, which is the whole
# point, at a fraction of the build cost. Raise it if load time regresses;
# lower it only with a tools/probe_water_blocks_ground.gd number in hand
# showing it bought something.
const WATERLINE_SUBDIVISION_CELL: float = 3.0

# PR-2 cleanup (2026-08-19). Hole spatial index for the face-build cell
# walk.
#
# The 23:50:41 playtest: navmesh_dispatch 900 ms mean, 1505 ms max. Per-call
# cost analysis: 2x face gens at ~400 ms each + bucket + dispatch. The face
# gen was the bottleneck - and the dominant cost inside it was the per-cell
# check `for h in col_hard_holes: if z < h.z1 and z1 > h.z0`, which iterates
# the FULL hole list for every cell.
#
# With 107 structures the brute-force walk was:
#   40 x-columns * 107 holes = 4,280 ops to build col_hard_holes, then
#   1600 z-cells per map * 1-2 holes_per_column = 2,400 ops
# Total: ~6,700 ops per call. At ~60 us/op that's 400 ms - matches the
# 400 ms face-gen estimate.
#
# A per-cell hole bucket makes the inner check O(holes_in_cell) instead of
# O(total_holes). For 107 holes spread across a 40x40 cell grid, average
# 1-2 holes per cell - and the bucket build itself is O(holes * cells_per_hole)
# which is O(107 * 4) = 428 ops. The walk is O(1600 * 2) = 3,200 ops. Total
# ~3,600 ops. ~2x faster, but more importantly the cost is INDEPENDENT of
# total hole count - the walk scales with the cell grid, not the hole list.
#
# Bucket key is (xi, zi) - the same integer indices the existing walk already
# uses for corner_heights, so no coordinate-system translation is needed.
# 2026-08-26: non-square map support - `half` is now Vector2 so the
# cell index is per-axis. Passing half.x for the Z axis (or vice versa)
# would silently shift holes by N cells.
static func _bucket_holes_by_cell(holes: Array, half: Vector2, cell: float) -> Dictionary:
	var out: Dictionary = {}
	for h in holes:
		var hx0: float = h.x0
		var hx1: float = h.x1
		var hz0: float = h.z0
		var hz1: float = h.z1
		# Cell index from world XZ. `floor((x + half_axis) / cell)` gives
		# the column/row index the existing cell walk uses (the same
		# Vector2i indexing _build_ground_faces uses for its corner
		# height lookup), so the bucket key is directly comparable.
		var cx0: int = int(floor((hx0 + half.x) / cell))
		var cx1: int = int(floor((hx1 + half.x) / cell))
		var cz0: int = int(floor((hz0 + half.y) / cell))
		var cz1: int = int(floor((hz1 + half.y) / cell))
		# Clamp to non-negative - a hole exactly at the map edge can
		# compute a fractional index that floors to -1, and we don't
		# want that in the dict.
		if cx0 < 0: cx0 = 0
		if cz0 < 0: cz0 = 0
		for cx in range(cx0, cx1 + 1):
			for cz in range(cz0, cz1 + 1):
				var key := Vector2i(cx, cz)
				if not out.has(key):
					out[key] = []
				out[key].append(h)
	return out

static func _build_ground_faces(map_def: Dictionary, extra_holes: Array = [], grid_cell: float = -1.0) -> PackedVector3Array:
	var verts = PackedVector3Array()
	var half: Vector2 = MapCatalogScript.half_extents(map_def)
	var water_holes = []
	for w in map_def.get("water_areas", []):
		water_holes.append(_rect_from(w.center, w.half_extents))
	var hard_holes = []
	for o in map_def.get("obstacles", []):
		hard_holes.append(_rect_from(o.center, o.half_extents))
	# canyon_ford PR1 (2026-08-26): hand-placed cliff mesh pieces are
	# impassable - they need to carve the ground navmesh the same way
	# obstacles do, NOT just have a visual StaticBody3D that the unit
	# walks into. Without this, the navmesh routes a unit straight
	# through a canyon wall and the unit gets stuck against the cliff
	# mesh. _spawn_cliff's own StaticBody3D is still useful (it stops
	# any unit that does end up at the cliff's footprint, e.g. one
	# pushed there by combat) but the navmesh bake is the primary
	# routing layer and needs the cliff as a hard hole.
	for c in map_def.get("cliffs", []):
		hard_holes.append(_rect_from(c.center, c.half_extents))
	# RTS_CORE_ROADMAP.md C1: extra_holes are building footprints ({center,
	# half_extents}, same rect shape obstacles already use) - a live
	# building blocks the ground navmesh exactly like a map-authored
	# obstacle does. Empty for the initial map-load bake; populated by
	# skirmish.gd's dynamic rebake on building placed/destroyed.
	for eh in extra_holes:
		hard_holes.append(_rect_from(eh.center, eh.half_extents))
	# PR-5 (2026-08-19). `grid_cell` is the source-geometry cell size, not
	# the bake's `cell_size` (those are independent - the bake cell_size
	# is set by the region, the grid_cell is the quad walk stride).
	# Coarsening it 1.5x for the rebake path cuts the number of verts
	# in the per-tile bucket by 2.25x, which translates to a similar
	# Recast cost reduction (Recast's per-tile cost is mostly
	# voxelization, which is O(verts) once the grid is set up). A
	# coarser source means a slightly less precise carve around a
	# building - the carve is still a hard obstacle, but its boundary
	# is one grid_cell fuzzier. For tactical RTS with 1m+ unit
	# clearance that's invisible. Pass -1.0 (the default) to use the
	# map's standard cell - the boot path does.
	if grid_cell < 0.0:
		grid_cell = _nav_grid_cell(map_def)
	var bridges = _collect_bridges(map_def)
	var has_blobs = not map_def.get("water_blobs", []).is_empty()
	# PR-5. `grid_cell` is the parameter (defaults to _nav_grid_cell above);
	# use it for both the walk and the corner-height grid so they stay
	# in step at whichever coarseness the caller asked for.
	var cell: float = grid_cell
	# 2026-08-26: _corner_heights now takes a Vector2 half (non-square
	# map support); returns n_x and n_z separately so the index arithmetic
	# below stays correct for both axes.
	var grid = _corner_heights(map_def, half, cell)
	var corner_heights: PackedFloat64Array = grid["heights"]
	var corner_nx: int = grid["n_x"]
	var corner_nz: int = grid["n_z"]

	# PR-2 cleanup (2026-08-19). Hole spatial index - the inner check
	# is now O(holes_in_cell) rather than O(total_holes). See
	# _bucket_holes_by_cell above for the cost analysis.
	# 2026-08-26: now passes the Vector2 half (non-square refactor);
	# the bucket key is per-axis, consistent with the walk below.
	var hard_buckets: Dictionary = _bucket_holes_by_cell(hard_holes, half, cell)
	var water_buckets: Dictionary = _bucket_holes_by_cell(water_holes, half, cell)

	var xi = 0
	var x = -half.x
	while x < half.x:
		var x1 = min(x + cell, half.x)
		var zi = 0
		var z = -half.y
		while z < half.y:
			var z1 = min(z + cell, half.y)
			var cell_key := Vector2i(xi, zi)
			var hard_blocked := false
			var cell_hard: Array = []
			if hard_buckets.has(cell_key):
				cell_hard = hard_buckets[cell_key]
				for h in cell_hard:
					if z < h.z1 and z1 > h.z0:
						hard_blocked = true
						break
				var cell_water: Array = water_buckets[cell_key] if water_buckets.has(cell_key) else []
				_emit_subdivided_ground_quad(verts, x, x1, z, z1, cell_hard, cell_water, bridges, has_blobs, map_def, true, "block")
				z = z1
				zi += 1
				continue
			var blocked = hard_blocked
			if not blocked and water_buckets.has(cell_key):
				for w in water_buckets[cell_key]:
					if z < w.z1 and z1 > w.z0 and not _cell_on_bridge(x, x1, z, z1, bridges):
						blocked = true
						break
			if not blocked and has_blobs and _cell_on_water_blob(x, x1, z, z1, map_def):
				blocked = true
			if not blocked:
				# Grid line xi is world x, zi is world z (see
				# _corner_heights() - it walks the same sequence). With
				# the non-square refactor, the X stride is n_z and the
				# Z stride is 1.
				var h00 = corner_heights[xi * corner_nz + zi]
				var h10 = corner_heights[(xi + 1) * corner_nz + zi]
				var h01 = corner_heights[xi * corner_nz + zi + 1]
				var h11 = corner_heights[(xi + 1) * corner_nz + zi + 1]
				var max_slope = max(
					max(abs(h10 - h00), abs(h01 - h00)),
					max(abs(h11 - h10), abs(h11 - h01))
				) / cell
				# UNDER WATER IS NOT WALKABLE. The table and any painted body
				# were visual-only until now, so a ground unit happily drove
				# along the bed of a lake that was being drawn over its head.
				# Tested against the HIGHEST corner, so a cell is carved only
				# when the whole of it is under - which leaves the shoreline
				# cells walkable instead of eating a ring of beach.
				var surf_c: float = water_surface_at(map_def, (x + x1) * 0.5, (z + z1) * 0.5)
				var top: float = max(max(h00, h10), max(h01, h11))
				var low: float = min(min(h00, h10), min(h01, h11))
				var waterline: float = surf_c - SUBMERGED_MIN_DEPTH
				# A CELL THAT STRADDLES THE WATERLINE HAS TO BE RESOLVED FINER
				# THAN THE CELL.
				# The highest-corner test below is deliberate and stays - it is
				# what keeps a wet beach walkable instead of carving a ragged
				# fringe of holes along every shore. But applied to a whole nav
				# cell it also means ANY dry corner saves the entire cell, and
				# `cell` is max(GRID_CELL, half/75) - about 5.8 m on
				# delta_blues. A braided delta channel is narrower than that, so
				# every channel kept a dry bank corner and stayed fully
				# walkable: measured 2026-09-01 with
				# tools/probe_water_blocks_ground.gd, 45.4% of delta_blues'
				# submerged area was on the ground surface, up to 6.6 m deep,
				# and wheeled units drove the riverbed.
				#
				# The fix is not to change the corner rule, it is to stop asking
				# it a question at the wrong scale. A straddling cell goes
				# through the same subdivider the building holes already use,
				# which re-runs exactly this test per 1 m sub-quad
				# (water_mode "block"). Beach stays, channel goes.
				#
				# Only STRADDLING cells pay for this. Fully dry and fully
				# drowned cells still resolve in one test at cell resolution,
				# so the extra triangles are a one-cell-wide band along the
				# shoreline rather than a global refinement.
				if surf_c > NO_WATER * 0.5 and low < waterline and top >= waterline 						and cell > WATERLINE_SUBDIVISION_CELL:
					var cell_water_s: Array = water_buckets[cell_key] if water_buckets.has(cell_key) else []
					_emit_subdivided_ground_quad(verts, x, x1, z, z1, [], cell_water_s, bridges, has_blobs, map_def, true, "block", WATERLINE_SUBDIVISION_CELL)
					z = z1
					zi += 1
					continue
				var submerged: bool = top < waterline
				if submerged and _cell_on_bridge(x, x1, z, z1, bridges):
					submerged = false
				if max_slope > MAX_WALKABLE_SLOPE or submerged:
					blocked = true
				else:
					_add_nav_quad(verts, Vector3(x, h00, z), Vector3(x1, h10, z), Vector3(x1, h11, z1), Vector3(x, h01, z1))
			z = z1
			zi += 1
		x = x1
		xi += 1
	return verts

# Re-tests a single coarse quad at HOLE_SUBDIVISION_CELL resolution instead
# of omitting it wholesale - see _build_ground_faces()'s header comment for
# why. Deliberately re-runs the SAME hard_holes/water_holes/blob checks the
# coarse loop already ran, just at finer granularity within this one quad,
# so a fine sub-cell not actually touching any hole still gets emitted.
# `water_mode` decides what this does about the water table and painted bodies,
# and it has to be told because the same subdivision serves two surfaces that
# want opposite answers:
#   "block" - ground: a submerged sub-cell is not walkable.
#   "float" - amphibious: a submerged sub-cell IS walkable, at the surface.
# Neither happened before, so an obstacle cell - the only kind that gets
# subdivided - was a hole in both fixes at once: ground kept a patch of
# lakebed walkable, and amphibious sank a patch to the bed.
static func _emit_subdivided_ground_quad(verts: PackedVector3Array, x0: float, x1: float, z0: float, z1: float,
		hard_holes: Array, water_holes: Array, bridges: Array, has_blobs: bool, map_def: Dictionary, has_heightmap: bool = true,
		water_mode: String = "", sub_cell: float = -1.0) -> void:
	# sub_cell defaults to the building-hole resolution. The waterline pass
	# overrides it - see WATERLINE_SUBDIVISION_CELL for why they differ.
	var sub: float = sub_cell if sub_cell > 0.0 else HOLE_SUBDIVISION_CELL
	var sx = x0
	while sx < x1:
		var sx1 = minf(sx + sub, x1)
		var sz = z0
		while sz < z1:
			var sz1 = minf(sz + sub, z1)
			var blocked = false
			for h in hard_holes:
				if _rect_overlaps(sx, sx1, sz, sz1, h):
					blocked = true
					break
			if not blocked:
				for w in water_holes:
					if _rect_overlaps(sx, sx1, sz, sz1, w) and not _cell_on_bridge(sx, sx1, sz, sz1, bridges):
						blocked = true
						break
			if not blocked and has_blobs and _cell_on_water_blob(sx, sx1, sz, sz1, map_def):
				blocked = true
			if not blocked:
				var h00 = terrain_height_at(map_def, Vector3(sx, 0, sz))
				var h10 = terrain_height_at(map_def, Vector3(sx1, 0, sz))
				var h11 = terrain_height_at(map_def, Vector3(sx1, 0, sz1))
				var h01 = terrain_height_at(map_def, Vector3(sx, 0, sz1))
				var drowned := false
				if water_mode != "":
					var surf: float = water_surface_at(map_def, (sx + sx1) * 0.5, (sz + sz1) * 0.5)
					if surf > NO_WATER * 0.5:
						if water_mode == "float":
							h00 = maxf(h00, surf)
							h10 = maxf(h10, surf)
							h11 = maxf(h11, surf)
							h01 = maxf(h01, surf)
						elif water_mode == "block":
							var top: float = maxf(maxf(h00, h10), maxf(h01, h11))
							drowned = top < surf - SUBMERGED_MIN_DEPTH 								and not _cell_on_bridge(sx, sx1, sz, sz1, bridges)
				if not drowned:
					var max_slope = maxf(
						maxf(absf(h10 - h00), absf(h01 - h00)),
						maxf(absf(h11 - h10), absf(h11 - h01))
					) / maxf(sx1 - sx, 0.001)
					if max_slope <= MAX_WALKABLE_SLOPE:
						_add_nav_quad(verts, Vector3(sx, h00, sz), Vector3(sx1, h10, sz), Vector3(sx1, h11, sz1), Vector3(sx, h01, sz1))
			sz = sz1
		sx = sx1

# Same grid-quad sweep as _build_ground_faces(), but water is walkable
# terrain here instead of a hole - only real obstacles block it. This is
# what makes screw_drive locomotion (the amphibious auger-drum type)
# genuinely different from a plain ground unit: it can path straight
# across a lake in one continuous route instead of being confined to
# ground_nav_map like every other ground/legged type. water_blobs are
# deliberately NOT excluded here either, for the same reason water_areas
# never was - amphibious units cross water freely.
static func _build_amphibious_faces(map_def: Dictionary, extra_holes: Array = [], grid_cell: float = -1.0) -> PackedVector3Array:
	var verts = PackedVector3Array()
	var half: Vector2 = MapCatalogScript.half_extents(map_def)
	var holes = []
	for o in map_def.get("obstacles", []):
		holes.append(_rect_from(o.center, o.half_extents))
	# RTS_CORE_ROADMAP.md C1: same building-footprint holes as
	# _build_ground_faces() above - a screw_drive unit can cross open
	# water, but not through a building sitting on land.
	for eh in extra_holes:
		holes.append(_rect_from(eh.center, eh.half_extents))
	# PR-5. See _build_ground_faces' own PR-5 comment for why this
	# is coarsenable and what it costs in fidelity.
	if grid_cell < 0.0:
		grid_cell = _nav_grid_cell(map_def)
	var cell: float = grid_cell
	# 2026-08-26: see _build_ground_faces for the non-square refactor
	# notes - same Vector2 half, same per-axis n_x/n_z.
	var grid = _corner_heights(map_def, half, cell)
	var corner_heights: PackedFloat64Array = grid["heights"]
	var corner_nx: int = grid["n_x"]
	var corner_nz: int = grid["n_z"]
	# PR-2 cleanup (2026-08-19). Hole spatial index - see
	# _bucket_holes_by_cell in _build_ground_faces for the rationale.
	# 2026-08-26: Vector2 half (non-square refactor).
	var hole_buckets: Dictionary = _bucket_holes_by_cell(holes, half, cell)

	var x = -half.x
	var xi: int = 0
	while x < half.x:
		var x1 = min(x + cell, half.x)
		var z = -half.y
		var zi: int = 0
		while z < half.y:
			var z1 = min(z + cell, half.y)
			var cell_key := Vector2i(xi, zi)
			var blocked = false
			if hole_buckets.has(cell_key):
				for h in hole_buckets[cell_key]:
					if z < h.z1 and z1 > h.z0:
						blocked = true
						break
			if blocked and cell > HOLE_SUBDIVISION_CELL:
				# Same fix as _build_ground_faces() - see that function's
				# header comment. A screw_drive unit hits the exact same
				# building-swallows-a-whole-coarse-quad failure on land.
				# Per-cell bucket slice for the subdivided quad - see
				# _build_ground_faces' equivalent comment for why this is correct.
				var cell_holes: Array = hole_buckets[cell_key] if hole_buckets.has(cell_key) else []
				_emit_subdivided_ground_quad(verts, x, x1, z, z1, cell_holes, [], [], false, map_def, true, "float")
			elif not blocked:
				var h00 = corner_heights[xi * corner_nz + zi]
				var h10 = corner_heights[(xi + 1) * corner_nz + zi]
				var h01 = corner_heights[xi * corner_nz + zi + 1]
				var h11 = corner_heights[(xi + 1) * corner_nz + zi + 1]
				# FLOAT, do not crawl the bed. This surface carries amphibious
				# and hovering units, both of which sit ON the water. Emitting
				# it at terrain height sent a path down to the bottom of a
				# 30 m deep lake and the unit followed it under.
				var surface: float = water_surface_at(map_def, (x + x1) * 0.5, (z + z1) * 0.5)
				if surface > NO_WATER * 0.5:
					h00 = maxf(h00, surface)
					h10 = maxf(h10, surface)
					h01 = maxf(h01, surface)
					h11 = maxf(h11, surface)
				# A CLIFF IS A CLIFF FOR A HOVER PAD TOO.
				# This test was missing and it was the only thing separating
				# this surface from _build_ground_faces() - which meant every
				# `hovering` locomotor (hover_engine, anti_grav_plate,
				# air_cushion_skirt, plasma_thruster; unit_assembly routes them
				# all here) could path straight up a vertical rock face. A pad
				# that floats a metre off the deck is not a helicopter; the
				# things that genuinely ignore terrain carry the `airborne`
				# trait, get no NavigationAgent3D at all, and never reach this
				# mesh. Note _emit_subdivided_ground_quad() below has always
				# applied exactly this test on its own water_mode == "float"
				# path, so the two halves of this very function disagreed.
				#
				# Deliberately computed AFTER the water-surface raise above,
				# which is what makes one test do the right thing everywhere:
				#   open water   - corners all pinned to a flat surface, slope
				#                  ~0, stays passable however deep the bed is
				#   dry land     - real terrain slope, gated like any wheel
				#   shoreline    - only the exposed part of the bank counts,
				#                  so a hovercraft still drives up a beach
				# Same MAX_WALKABLE_SLOPE as the ground mesh, per the design
				# call that hover should read "similar to wheels" rather than
				# get a bespoke allowance.
				var max_slope: float = maxf(
					maxf(absf(h10 - h00), absf(h01 - h00)),
					maxf(absf(h11 - h10), absf(h11 - h01))
				) / maxf(cell, 0.001)
				if max_slope <= MAX_WALKABLE_SLOPE:
					_add_nav_quad(verts, Vector3(x, h00, z), Vector3(x1, h10, z), Vector3(x1, h11, z1), Vector3(x, h01, z1))
			z = z1
			zi += 1
		x = x1
		xi += 1
	return verts

# Deep-draught-only water: the same water_areas footprint as water_map,
# grid-swept (like _build_ground_faces()) so shallow_water_areas sub-
# regions can be carved out as holes - a deep-draught hull (heavy_
# cruiser_hull) literally cannot float there, the real physical
# impossibility the task called out as worth an actual navmesh block
# rather than just a speed penalty. Shallow-draught naval hulls
# (small_boat_hull, naval_hull) keep using the unmodified water_map, which
# still includes these areas.
static func _build_deep_water_faces(map_def: Dictionary) -> PackedVector3Array:
	var verts = PackedVector3Array()
	var shallow_holes = []
	for sw in map_def.get("shallow_water_areas", []):
		shallow_holes.append(_rect_from(sw.center, sw.half_extents))
	var cell = _nav_grid_cell(map_def)
	for w in map_def.get("water_areas", []):
		var rect = _rect_from(w.center, w.half_extents)
		var x = rect.x0
		while x < rect.x1:
			var x1 = min(x + cell, rect.x1)
			var z = rect.z0
			while z < rect.z1:
				var z1 = min(z + cell, rect.z1)
				var blocked = false
				for h in shallow_holes:
					if _rect_overlaps(x, x1, z, z1, h):
						blocked = true
						break
				if not blocked:
					_add_nav_quad(verts, Vector3(x, 0, z), Vector3(x1, 0, z), Vector3(x1, 0, z1), Vector3(x, 0, z1))
				z = z1
			x = x1
	return verts

# Shared by build_navmeshes() below AND rebake_ground_and_amphibious() (C1's
# dynamic rebake) - one place that knows how to turn source verts into a
# baked NavigationMesh, so the two bakers can't silently drift apart on
# cell_size/agent settings.
# CORE_DESIGN_LANGUAGE.md §3.2 (2026-08-08 playtest): NavigationMesh.
# agent_max_climb was never set here, leaving it at Godot's own default
# (0.25) - fine at cell_size 0.25 (quantizes to exactly 1 cell), silently
# LETHAL once cell_size grows past 0.25 (Chunk 14's self-bounding formula
# widens it well beyond that on any map bigger than 300 half-extent). Recast
# quantizes agent_max_climb to whole cell_height units, FLOORING - confirmed
# via the engine's own "agent_max_climb is floored to cell_height voxel
# units" warning, and at cell_size 1.87 (open_plains, world_scale=4) that
# floors 0.25 all the way to ZERO. A navmesh baked with zero climb tolerance
# treats every tiny bit of terrain noise (GROUND_NOISE_AMPLITUDE, itself
# real and present) as an impassable micro-cliff, fragmenting connectivity
# right around wherever a unit happens to be standing - which reproduced
# exactly as "units sit in place and go in a circle" (a live NavigationAgent3D
# permanently stuck offering the same near-start corner - see tools/probe_
# nav_scale_stall.gd) despite a raw NavigationServer3D.map_get_path() query
# between the same two points succeeding, because that query doesn't hit the
# SAME connectivity holes the agent's own local corridor search does. Scaled
# with cell_size (not left flat) so it always survives the floor - 1.5 cells
# of headroom regardless of how large a map's cell_size grows.
const AGENT_MAX_CLIMB_CELLS: float = 1.5

# CORE_DESIGN_LANGUAGE.md §3.2 (2026-08-08 playtest): cell_HEIGHT used to
# just mirror cell_SIZE, which was fine while both were the same small
# number (0.25 at world_scale=1) but silently broke vertical precision once
# _nav_cell_size() started widening cell_size for big maps (Chunk 14 - a
# deliberate, correct choice for HORIZONTAL triangle count, never meant to
# also degrade vertical accuracy). Confirmed live: on a flat, non-heightmap
# map the navmesh source geometry is deliberately Y=0 (see
# _build_ground_faces()'s own comment), yet every query near a scaled-up
# map returned Y~3.74 - exactly 2x cell_height at world_scale=4's cell_size
# (1.87) - Recast's vertical voxelisation quantizing the flat ground up by
# whole cell_height steps. That put the baked navmesh surface several units
# above where a real unit's body actually stands (terrain_height_at() drives
# the unit's real Y, and does NOT share this quantization), and the
# resulting vertical mismatch was enough to make NavigationAgent3D's 3D-aware
# path queries misbehave near real bases even though the horizontal geometry
# (proven separately, see the HOLE_SUBDIVISION_CELL fix above) was already
# correct. Decoupled from cell_size and kept fixed, small, and world_scale-
# independent - vertical precision has no reason to get coarser just
# because the map got wider.
const NAV_CELL_HEIGHT: float = 0.25

# 2026-08-10 (Chris playtest): harvesters were driving into the SIDE of
# buildings and stopping, instead of routing around. The cause was a
# WAS 0.1 m, and that was the bug: Recast uses this radius to erode
# walkable area near walls and buildings, so the resulting paths had
# 10 cm clearance to a structure. A harvester hull is ~3 m wide; it
# could not fit through the gap the path reserved, so it followed the
# path until its own CharacterBody3D (collision_mask = TERRAIN |
# BUILDINGS) physically stopped it against the wall.
#
# The fix below originally reached only ONE of the three bake sites in
# this file - the synchronous one, which is the path the TEST SUITE
# uses. Both async paths kept 0.1, and those are the paths a real match
# uses for its initial load AND its mid-match rebake, so the shipping
# game went on pathing at 10 cm clearance while every test validated
# 1.0 m. All three now go through _configure_nav_mesh().
#
# Measured before changing it (tools/probe_agent_radius_effect.gd):
# because Recast quantises the radius to whole cell_size voxels, 1.0 and
# 0.1 are IDENTICAL on 24 of the roster's 28 ground/amphibious surfaces -
# every map whose cell_size is >= 1.0 collapses both to a single voxel.
# Only close_quarters (cell 0.97) and test_range (cell 0.25) move, each
# losing under 1% of walkable area, which is precisely the intended
# clearance appearing around obstacles.
#
# 1.0 m. Recast quantises agent_radius to whole cell_size voxels and
# warns about it ("agent_radius is ceiled to cell_size voxel units and
# loses precision") - the warning is loud but on the maps the project
# ships, 1.0 m maps to 1 voxel at every cell_size from 0.25 (the
# small-map floor) up to ~1.87 (open_plains at world_scale=4), so the
# effective clearance is 1.0 m or one cell, whichever is larger. A
# wider value (1.5) was tried and BROKE test_spawn_fairness_lint_
# passes_a_real_map_scaled_up_4x - at large world_scale the cells get
# bigger and the ceiling makes a 1.5 m radius effectively 2-3 cells,
# eating the corridors that the existing maps rely on. 1.0 m is the
# largest value that stays legal everywhere the project has been
# tested; per-agent radius (set on NavigationAgent3D per hull size)
# is the right shape for the very widest hulls and a separate change.
#
# Not the navmesh's NAV_TILE_VOXELS_PER_AXIS or cell_size - those are
# spatial discretisations, this is the agent's physical size. A single
# constant is the limit of what one shared navmesh can offer; the
# right long-term shape is per-actor types so a scout is not
# constrained by a hauler's width, but the wide-unit case does not
# exist yet in practice (no scout is going to clip a building today)
# and the per-actor-types refactor is a much bigger lift.
const NAV_AGENT_RADIUS: float = 1.0

# Recast quantises agent_radius UP to whole cell_size voxels and
# agent_max_climb DOWN to whole cell_height voxels, and Godot 4.7.1 warns
# about each every single bake ("Property agent_radius is ceiled to
# cell_size voxel units and loses precision",
# nav_mesh_generator_3d.cpp:370/373). Both warnings are accurate and both
# are harmless - but build_ground_amphibious_tiles() bakes 12x12 tiles x 2
# surfaces = 288 navmeshes per map load, so "harmless" arrives as several
# hundred lines of stderr per match and buries real errors in the test log.
#
# Passing the ALREADY-quantised value silences both without moving a single
# baked polygon: ceil(r / cell_size) * cell_size re-ceils to the same
# integer voxel count Recast would have computed itself, and likewise
# floor(c / cell_height) * cell_height. tools/probe_agent_radius_warning.gd
# verifies this across every cell_size the project actually produces (0.25,
# the small-map floor, through 5.95, scattered_peaks' open water) and
# asserts the re-ceil never drifts a voxel WIDER. Drifting wider is the
# thing to fear here: a wider effective radius eats corridor clearance,
# which is exactly what broke test_spawn_fairness_lint_passes_a_real_map_
# scaled_up_4x when NAV_AGENT_RADIUS was tried at 1.5 (see that constant).
#
# All three call sites now pass NAV_AGENT_RADIUS. They did not always -
# see that constant's comment for the split this closed and what it was
# measured to cost.
static func _snap_up_to_voxel(value: float, unit: float) -> float:
	if value <= 0.0 or unit <= 0.0:
		return maxf(value, 0.0)
	return float(maxi(1, int(ceil(value / unit)))) * unit

static func _snap_down_to_voxel(value: float, unit: float) -> float:
	if value <= 0.0 or unit <= 0.0:
		return maxf(value, 0.0)
	return float(maxi(1, int(floor(value / unit)))) * unit

# The single place a NavigationMesh's shared bake parameters are set. There
# are three construction sites in this file (sync, the async mid-match
# rebake, and the async tiled load path) and they have already drifted apart
# once - the comment in _bake_region_async() recording that the same fixes
# were needed in both places is what this exists to make unnecessary.
#
# `tile_rect` is the seam fix (NAV_TILE_BORDER_CELLS): when non-null the bake
# is one tile of a tiled surface, and the mesh is configured with Godot's
# chunk-baking contract - filter_baking_aabb grown by the border, border_size
# to discard that ring from the finished surface, edge_max_error at the 1.0
# the docs require for aligned tiled edges. Non-tiled callers (water,
# deep_water, the legacy whole-map rebakes) pass null and get exactly the
# pre-tiling configuration.
static func _configure_nav_mesh(nav_mesh: NavigationMesh, cell_size: float, agent_radius: float, tile_rect: Variant = null) -> void:
	nav_mesh.cell_size = cell_size
	nav_mesh.cell_height = NAV_CELL_HEIGHT
	nav_mesh.agent_max_climb = _snap_down_to_voxel(cell_size * AGENT_MAX_CLIMB_CELLS, NAV_CELL_HEIGHT)
	nav_mesh.agent_radius = _snap_up_to_voxel(agent_radius, cell_size)
	if tile_rect != null:
		var border: float = cell_size * NAV_TILE_BORDER_CELLS
		# Y span deliberately dwarfs any terrain amplitude the heightfield
		# can produce - the AABB is an XZ chunk boundary, not a height clip.
		nav_mesh.filter_baking_aabb = AABB(
			Vector3(tile_rect.x0 - border, -500.0, tile_rect.z0 - border),
			Vector3((tile_rect.x1 - tile_rect.x0) + 2.0 * border, 1000.0,
				(tile_rect.z1 - tile_rect.z0) + 2.0 * border))
		nav_mesh.border_size = border
		nav_mesh.edge_max_error = 1.0

static func _bake_nav_mesh(verts: PackedVector3Array, cell_size: float, tile_rect: Variant = null) -> NavigationMesh:
	var nav_mesh = NavigationMesh.new()
	if verts.is_empty():
		return nav_mesh
	_configure_nav_mesh(nav_mesh, cell_size, NAV_AGENT_RADIUS, tile_rect)
	var source = NavigationMeshSourceGeometryData3D.new()
	source.add_faces(verts, Transform3D.IDENTITY)
	NavigationServer3D.bake_from_source_geometry_data(nav_mesh, source)
	return nav_mesh

# RTS_CORE_ROADMAP.md C1: dynamic navmesh for buildings blocking movement.
# Re-bakes ONLY ground+amphibious (the two surfaces a building actually
# footprints on - water/deep_water are never affected by a building
# placement) against the SAME region RIDs build_navmeshes() already
# created, via region_set_navigation_mesh() rather than region_create() -
# reuses the existing region/map RIDs instead of leaking new ones every
# time a building goes up or down. extra_holes is the live building
# footprint list (skirmish.gd's job to gather from the "buildings" group).
static func rebake_ground_and_amphibious(map_def: Dictionary, extra_holes: Array, ground_region: RID, amphibious_region: RID) -> void:
	var cell_size = _nav_cell_size(map_def)
	var ground_verts = _build_ground_faces(map_def, extra_holes)
	NavigationServer3D.region_set_navigation_mesh(ground_region, _bake_nav_mesh(ground_verts, cell_size))
	var amphibious_verts = _build_amphibious_faces(map_def, extra_holes)
	NavigationServer3D.region_set_navigation_mesh(amphibious_region, _bake_nav_mesh(amphibious_verts, cell_size))

# Async twin of rebake_ground_and_amphibious(), for the MID-MATCH rebake.
#
# Even after _nav_cell_size() dropped the per-surface Recast bake from
# ~1585ms to ~327ms, a placement still stalled the main thread for ~766ms
# (two surfaces plus face generation) - short of a freeze, but well past a
# dropped frame, and paid on every building placed or destroyed.
#
# Recast itself is the bulk of that and does not need to run on the main
# thread: NavigationServer3D.bake_from_source_geometry_data_async() hands it
# to a worker and invokes the callback when the mesh is ready. What stays
# synchronous here is only the GDScript face generation (~70-100ms with the
# corner-height cache), because it walks map_def and has to see a consistent
# snapshot of the building holes.
#
# The INITIAL map-load bake deliberately keeps using the synchronous version
# above: units spawn and take their first orders within a frame or two of
# _ready(), so a navmesh that arrives "soon" instead of "now" would let the
# very first path query run against an empty region. Load already blocks;
# the mid-match rebake is the one that must not.
#
# on_ready is invoked once BOTH surfaces have finished baking, so callers
# can repath units against a fully-updated navmesh rather than a half-
# updated one.
static func rebake_ground_and_amphibious_async(map_def: Dictionary, extra_holes: Array, ground_region: RID, amphibious_region: RID, on_ready: Callable = Callable()) -> void:
	var cell_size = _nav_cell_size(map_def)
	var ground_verts = _build_ground_faces(map_def, extra_holes)
	var amphibious_verts = _build_amphibious_faces(map_def, extra_holes)
	# Shared countdown so on_ready fires exactly once, after the second of
	# the two bakes lands (order between them is not guaranteed).
	var remaining = {"n": 2}
	_bake_region_async(ground_region, ground_verts, cell_size, remaining, on_ready)
	_bake_region_async(amphibious_region, amphibious_verts, cell_size, remaining, on_ready)

static func _bake_region_async(region: RID, verts: PackedVector3Array, cell_size: float, remaining: Dictionary, on_ready: Callable, tile_rect: Variant = null) -> void:
	var nav_mesh = NavigationMesh.new()
	if verts.is_empty():
		NavigationServer3D.region_set_navigation_mesh(region, nav_mesh)
		remaining["n"] -= 1
		if remaining["n"] <= 0 and on_ready.is_valid():
			on_ready.call()
		return
	_configure_nav_mesh(nav_mesh, cell_size, NAV_AGENT_RADIUS, tile_rect)
	var source = NavigationMeshSourceGeometryData3D.new()
	source.add_faces(verts, Transform3D.IDENTITY)
	NavigationServer3D.bake_from_source_geometry_data_async(nav_mesh, source, func():
		NavigationServer3D.region_set_navigation_mesh(region, nav_mesh)
		remaining["n"] -= 1
		if remaining["n"] <= 0 and on_ready.is_valid():
			on_ready.call())

# Tiled twin of rebake_ground_and_amphibious_async(). Rebakes EVERY tile
# rather than only the ones a changed building actually touches - simpler
# and, per Chunk 20's own finding, not a real cost regression: the async
# mid-match rebake already moved Recast off the main thread, so the thing
# tiling improves here is fidelity (a per-tile cell_size derived from a fixed voxel budget
# regardless of map size), not placement latency. Selective per-tile rebake
# (Chunk 22) is a further optimization on top of an already-non-blocking
# path, not a correctness requirement.
#
# PR-2 (2026-08-19). `affected_tile_indices` lets the urgent placement path
# scope the rebake to the tiles a new building actually touches. With
# lake_crossing's 16-tile default and a 3-8m footprint, that's 1-4 tiles
# out of 16 - so the worker-thread cost (not the main-thread one) drops by
# 4-16x. Empty list = "rebuild all" (the boot/death path).
#
# PR-5 (2026-08-19). `grid_cell_mult` (default 1.5) coarsens the source
# geometry by 1.5x for the rebake path. Cuts the per-tile vertex count
# by 2.25x, which Recast voxelizes 2-3x faster. The bake cell_size is
# unchanged (it has to match the region's setup), so the navmesh fidelity
# is the same; only the carve around a building is one grid cell fuzzier
# at the boundary. Set to 1.0 for boot-quality fidelity.
# REVERTED 2026-08-19: the 1.5x grid_cell triggers the
# `cell > HOLE_SUBDIVISION_CELL` branch in _build_ground_faces for
# every hard-blocked cell, which emits 36 verts per blocked cell
# instead of 6. With 107+ structures the per-call cost went from
# ~200 ms to ~900 ms. The face-bucketing fix (also PR-2 cleanup) is
# the right path to dropping navmesh_dispatch, not the coarsening.
# Caller now defaults to 1.0 (the boot path explicitly).
#
# PR-C (2026-08-19). Moved the GDScript face gen + bucketing off the
# main thread onto a Thread, so the calling code (match_director's
# _mark_navmesh_dirty urgent path) returns within a frame instead of
# blocking for 5-10 ms (post-bucket-fix) or 400+ ms (pre-fix). The
# Recast bake itself was always on Recast workers via
# bake_from_source_geometry_data_async; only the prep work was on
# main. The thread runs face gen + bucketing + bake dispatch, then
# terminates. The on_ready callback fires on the main thread when
# the LAST Recast bake completes (existing Godot behaviour - the
# callback is always called on main). Threads are kept in
# _active_rebake_threads so the GDScript GC doesn't kill them mid-run;
# the list is cleaned up by the thread's own deferred self-removal.
static var _active_rebake_threads: Array = []

static func rebake_ground_amphibious_tiles_async(map_def: Dictionary, extra_holes: Array,
		ground_regions: Array, amphibious_regions: Array, tile_rects: Array,
		on_ready: Callable = Callable(),
		affected_tile_indices: Array = [],
		grid_cell_mult: float = 1.0) -> void:
	# PR-C: dispatch the whole prep + bake-dispatch on a thread. Args are
	# duplicated where mutation is possible (extra_holes, ground_regions,
	# amphibious_regions arrays - the regions are RIDs so they're safe, but
	# duplicating the Arrays prevents the main thread from mutating them
	# while the worker is reading).
	var thread := Thread.new()
	thread.start(_rebuild_thread.bind(
		map_def,
		extra_holes.duplicate(true),
		ground_regions,
		amphibious_regions,
		tile_rects,
		on_ready,
		affected_tile_indices.duplicate(true),
		grid_cell_mult,
		thread))
	_active_rebake_threads.append(thread)


# PR-C (2026-08-19). Runs on a worker thread, NOT the main thread.
# Does the GDScript face gen + bucketing + dispatches the Recast bakes
# (which themselves run on Recast workers). The on_ready callback fires
# on the main thread when the LAST Recast bake completes (Godot
# NavigationServer3D guarantees the callback is called on main).
#
# Thread safety notes:
#   * _build_ground_faces / _build_amphibious_faces / _bucket_verts_by_tile
#     are pure GDScript data manipulation - safe on any thread.
#   * NavigationServer3D.bake_from_source_geometry_data_async is
#     designed to be called from any thread.
#   * The bake callback is invoked on the main thread by Godot, so
#     region_set_navigation_mesh + on_ready run on main.
#   * extra_holes / affected_tile_indices are duplicated in the caller
#     so a parallel placement on main doesn't mutate them mid-read.
static func _rebuild_thread(map_def: Dictionary, extra_holes: Array,
		ground_regions: Array, amphibious_regions: Array, tile_rects: Array,
		on_ready: Callable, affected_tile_indices: Array,
		grid_cell_mult: float, self_thread: Thread) -> void:
	var tile_cell_size = _nav_tile_cell_size(map_def)
	var grid_cell: float = _nav_grid_cell(map_def) * grid_cell_mult
	var ground_verts = _build_ground_faces(map_def, extra_holes, grid_cell)
	var amphibious_verts = _build_amphibious_faces(map_def, extra_holes, grid_cell)
	# Buckets padded by the bake border, so every tile's bake sees the far
	# side of its own seams (see NAV_TILE_BORDER_CELLS).
	var single_region: bool = _nav_single_region(map_def)
	# No border to bucket into when there is only one region.
	var pad: float = 0.0 if single_region else tile_cell_size * NAV_TILE_BORDER_CELLS
	var ground_buckets = _bucket_verts_by_tile(ground_verts, map_def, tile_rects, pad)
	var amphibious_buckets = _bucket_verts_by_tile(amphibious_verts, map_def, tile_rects, pad)
	# Empty list = "rebuild all" - the path a full-rebake caller (boot,
	# building-destroyed) takes.
	var indices: Array = affected_tile_indices
	if indices.is_empty():
		indices = []
		for i in range(tile_rects.size()):
			indices.append(i)
	# Each tile dispatches two bakes (ground + amphibious).
	var remaining = {"n": indices.size() * 2}
	for i in indices:
		_bake_region_async(ground_regions[i], ground_buckets[i], tile_cell_size, remaining, on_ready, tile_rects[i])
		_bake_region_async(amphibious_regions[i], amphibious_buckets[i], tile_cell_size, remaining, on_ready, tile_rects[i])
	# PR-C: cleanup is done by the on_ready callback (called on main
	# when the last Recast bake completes) via _cleanup_finished_threads.
	# We can't call_deferred from a static method, and the thread
	# terminates on its own the moment this callable returns - all
	# that's needed is to keep the Thread reference alive (the static
	# array does that) until the Recast bakes finish.


# PR-C (2026-08-19). Removes finished worker threads from the
# active-list. Called by match_director's _on_navmesh_rebaked (which
# runs on main when the last Recast bake completes) so the list
# doesn't grow unbounded across a long match.
static func _cleanup_finished_threads() -> void:
	var i := _active_rebake_threads.size() - 1
	while i >= 0:
		var t: Thread = _active_rebake_threads[i]
		if t == null or not t.is_alive():
			if t != null:
				t.wait_to_finish()
			_active_rebake_threads.remove_at(i)
		i -= 1


# PR8 (2026-08-16). Sync twin of rebake_ground_amphibious_tiles_async().
# Used by the urgent navmesh-dirty path so a freshly placed building
# has its carve applied to the live navmesh RID IMMEDIATELY rather
# than 100-200ms later when the async bake finishes. The previous
# design was a unit heading for a path that routed through the new
# building for that 100-200ms window: the unit's collider would
# stop it at the wall, which read to the player as 'the unit drove
# into the building'. The fix: for the urgent case, block the
# main thread until the bake completes. Each region's bake runs
# on a Recast worker (NavigationServer3D.bake_from_source_geometry_data
# dispatches internally), so the block is on the result, not on
# the work; the bakes themselves are parallel and finish in
# roughly the time of one bake.
#
# `affected_tile_indices` lets the caller scope the rebake to
# only the tiles the new building actually touches. With a small
# structure (3x3 to 8x8 m footprint) on a 4-tile-per-side map
# (the lake_crossing default), that's 1-4 tiles out of 16 - so
# the bake time is 1/16th of a full rebake. The cost is paid
# once per structure placement; a player spamming the build
# menu sees N frames of N/60 sec hitch, which is acceptable for
# the correctness it buys.
static func rebake_ground_amphibious_tiles_sync(map_def: Dictionary, extra_holes: Array,
		ground_regions: Array, amphibious_regions: Array, tile_rects: Array,
		affected_tile_indices: Array = []) -> void:
	var tile_cell_size = _nav_tile_cell_size(map_def)
	var ground_verts = _build_ground_faces(map_def, extra_holes)
	var amphibious_verts = _build_amphibious_faces(map_def, extra_holes)
	var single_region: bool = _nav_single_region(map_def)
	# No border to bucket into when there is only one region.
	var pad: float = 0.0 if single_region else tile_cell_size * NAV_TILE_BORDER_CELLS
	var ground_buckets = _bucket_verts_by_tile(ground_verts, map_def, tile_rects, pad)
	var amphibious_buckets = _bucket_verts_by_tile(amphibious_verts, map_def, tile_rects, pad)
	# Empty list means "rebuild all tiles" - the path a full-rebake
	# caller would take, used for the boot path or for the "I
	# destroyed a building, refresh everything" case.
	var indices: Array = affected_tile_indices
	if indices.is_empty():
		indices = []
		for i in range(tile_rects.size()):
			indices.append(i)
	for i in indices:
		var g_nav := _bake_nav_mesh(ground_buckets[i], tile_cell_size, tile_rects[i])
		NavigationServer3D.region_set_navigation_mesh(ground_regions[i], g_nav)
		var a_nav := _bake_nav_mesh(amphibious_buckets[i], tile_cell_size, tile_rects[i])
		NavigationServer3D.region_set_navigation_mesh(amphibious_regions[i], a_nav)


# Returns the indices of navmesh tiles that overlap `hole` (a
# {_building_holes()-shaped} rect, i.e. {center: Vector3,
# half_extents: Vector2}). Used by the urgent placement path to
# scope a sync rebake to only the tiles the new building actually
# carves, so the 100-200ms block scales with the building size, not
# the whole map.
static func tiles_overlapping_hole(map_def: Dictionary, hole: Dictionary) -> Array:
	var tile_rects = _nav_tile_rects(map_def)
	# Unwrap the {center, half_extents} shape into the AABB the overlap
	# test wants. center is XZ, half_extents is the X/Z half-size in
	# metres. The Y axis does not matter for tile overlap - tiles are
	# vertical columns in the navmesh layout.
	var cx: float = float(hole["center"].x)
	var cz: float = float(hole["center"].z)
	var hx: float = float(hole["half_extents"].x)
	var hz: float = float(hole["half_extents"].y)
	# Expand by the bake border plus one source-grid cell: a tile must
	# rebake whenever changed geometry can fall inside its PADDED bake AABB
	# (border) or inside a source quad that straddles into that AABB
	# (grid_cell). Without this, a building placed just over a seam left
	# the far tile's bake reading stale geometry - the selective-rebake
	# version of the seam bug NAV_TILE_BORDER_CELLS fixes structurally.
	var pad: float = _nav_tile_cell_size(map_def) * NAV_TILE_BORDER_CELLS + _nav_grid_cell(map_def)
	var hole_x0: float = cx - hx - pad
	var hole_x1: float = cx + hx + pad
	var hole_z0: float = cz - hz - pad
	var hole_z1: float = cz + hz + pad
	var out: Array = []
	for i in range(tile_rects.size()):
		var t = tile_rects[i]
		if hole_x1 > t.x0 and hole_x0 < t.x1 and hole_z1 > t.z0 and hole_z0 < t.z1:
			out.append(i)
	return out


# Ground+amphibious halves of build_navmeshes()/build_navmeshes_deferred(),
# tiled - see NAV_TILE_SIZE's own header comment for why. `ground_map` and
# `amphibious_map` must already exist (map_create() + map_set_cell_size(...,
# _nav_tile_cell_size(map_def)) + map_set_cell_height(..., NAV_CELL_HEIGHT) +
# map_set_active(true)) - the B8 gotcha that a map's cell_size must match
# every region assigned to it applies per-tile-region exactly as it did to
# the old single region.
#
# `sync`: true bakes every tile to completion before returning (the headless/
# initial-load path); false returns unbaked "pending" entries for the caller
# to bake one at a time, exactly like build_navmeshes_deferred()'s water/
# deep_water halves already do.
static func build_ground_amphibious_tiles(map_def: Dictionary, extra_holes: Array,
		ground_map: RID, amphibious_map: RID, sync: bool) -> Dictionary:
	var tile_rects = _nav_tile_rects(map_def)
	var tile_cell_size = _nav_tile_cell_size(map_def)
	var ground_verts = _build_ground_faces(map_def, extra_holes)
	var amphibious_verts = _build_amphibious_faces(map_def, extra_holes)
	# Padded buckets + per-tile bake AABB/border: the seam fix documented at
	# NAV_TILE_BORDER_CELLS. `rect` rides each pending entry so the deferred
	# bake paths (bake_pending_entry / _async) can apply the same config the
	# sync branch applies inline here.
	var single_region: bool = _nav_single_region(map_def)
	# No border to bucket into when there is only one region.
	var pad: float = 0.0 if single_region else tile_cell_size * NAV_TILE_BORDER_CELLS
	var ground_buckets = _bucket_verts_by_tile(ground_verts, map_def, tile_rects, pad)
	var amphibious_buckets = _bucket_verts_by_tile(amphibious_verts, map_def, tile_rects, pad)

	var ground_regions: Array = []
	var amphibious_regions: Array = []
	var pending: Array = []
	for i in range(tile_rects.size()):
		var g_region = NavigationServer3D.region_create()
		NavigationServer3D.region_set_map(g_region, ground_map)
		ground_regions.append(g_region)
		var a_region = NavigationServer3D.region_create()
		NavigationServer3D.region_set_map(a_region, amphibious_map)
		amphibious_regions.append(a_region)
		# null rect on the single-region path: filter_baking_aabb + border_size
		# exist to trim a TILE back to the edge it shares with a neighbour.
		# With one region there is no neighbour, and the border would clip the
		# map's own outer perimeter off the navmesh.
		var bake_rect = null if single_region else tile_rects[i]
		if sync:
			NavigationServer3D.region_set_navigation_mesh(g_region, _bake_nav_mesh(ground_buckets[i], tile_cell_size, bake_rect))
			NavigationServer3D.region_set_navigation_mesh(a_region, _bake_nav_mesh(amphibious_buckets[i], tile_cell_size, bake_rect))
		else:
			pending.append({"region": g_region, "verts": ground_buckets[i], "label": "Surveying ground", "cell_size": tile_cell_size, "rect": bake_rect})
			pending.append({"region": a_region, "verts": amphibious_buckets[i], "label": "Marking fording points", "cell_size": tile_cell_size, "rect": bake_rect})

	return {"ground_regions": ground_regions, "amphibious_regions": amphibious_regions,
		"tile_rects": tile_rects, "pending": pending, "cell_size": tile_cell_size}


# Water+deep_water halves of build_navmeshes()/build_navmeshes_deferred() -
# NOT tiled. Neither surface is ever rebaked mid-match (buildings do not
# carve water) and neither was the fidelity problem Chunk 20 found, so a
# single region per surface stays correct and simple. `water_map`/
# `deep_water_map` must already exist (map_create() + cell_size/cell_height/
# active), same as build_ground_amphibious_tiles().
# Navigable surface over everything the table or a painted body covers. Emitted
# AT the water surface, not at the bed: a boat floats on the top.
static func _build_submerged_water_faces(map_def: Dictionary) -> PackedVector3Array:
	var verts := PackedVector3Array()
	var img := _water_paint_for(str(map_def.get("id", "")))
	if not has_water_table(map_def) and img == null:
		return verts
	var half: Vector2 = MapCatalogScript.half_extents(map_def)
	var cell: float = _nav_grid_cell(map_def)
	var x := -half.x
	while x < half.x:
		var x1: float = minf(x + cell, half.x)
		var z := -half.y
		while z < half.y:
			var z1: float = minf(z + cell, half.y)
			var cx: float = (x + x1) * 0.5
			var cz: float = (z + z1) * 0.5
			var surface: float = water_surface_at(map_def, cx, cz)
			if surface > NO_WATER * 0.5 and height_at(map_def, cx, cz) < surface - SUBMERGED_MIN_DEPTH:
				_add_nav_quad(verts, Vector3(x, surface, z), Vector3(x1, surface, z),
					Vector3(x1, surface, z1), Vector3(x, surface, z1))
			z = z1
		x = x1
	return verts


static func build_water_and_deep_water(map_def: Dictionary, water_map: RID, deep_water_map: RID, sync: bool) -> Dictionary:
	var cell_size = _nav_cell_size(map_def)
	var pending: Array = []

	var water_verts = PackedVector3Array()
	for w in map_def.get("water_areas", []):
		var rect = _rect_from(w.center, w.half_extents)
		_add_nav_quad(water_verts, Vector3(rect.x0, 0, rect.z0), Vector3(rect.x1, 0, rect.z0),
			Vector3(rect.x1, 0, rect.z1), Vector3(rect.x0, 0, rect.z1))
	for blob in map_def.get("water_blobs", []):
		water_verts.append_array(_water_blob_fan_verts(blob, 0.0))
	# The table and painted bodies are navigable water too, or a boat could
	# only ever use a hand-authored water_areas rect and a painted lake would
	# be scenery.
	water_verts.append_array(_build_submerged_water_faces(map_def))
	var water_region: RID = RID()
	if water_verts.size() > 0:
		water_region = NavigationServer3D.region_create()
		NavigationServer3D.region_set_map(water_region, water_map)
		if sync:
			NavigationServer3D.region_set_navigation_mesh(water_region, _bake_nav_mesh(water_verts, cell_size))
		else:
			pending.append({"region": water_region, "verts": water_verts, "label": "Charting waterways", "cell_size": cell_size})

	var deep_water_verts = _build_deep_water_faces(map_def)
	var deep_water_region: RID = RID()
	if deep_water_verts.size() > 0:
		deep_water_region = NavigationServer3D.region_create()
		NavigationServer3D.region_set_map(deep_water_region, deep_water_map)
		if sync:
			NavigationServer3D.region_set_navigation_mesh(deep_water_region, _bake_nav_mesh(deep_water_verts, cell_size))
		else:
			pending.append({"region": deep_water_region, "verts": deep_water_verts, "label": "Sounding deep water", "cell_size": cell_size})

	return {"water_region": water_region, "deep_water_region": deep_water_region, "pending": pending, "cell_size": cell_size}


# Creates and configures all four NavigationServer3D maps a match uses.
# Ground/amphibious get _nav_tile_cell_size() (tiling bounds their voxel count
# independent of map size); water/deep_water keep the old widening
# _nav_cell_size() (untiled, and were never the fidelity problem).
static func _create_nav_maps(map_def: Dictionary) -> Dictionary:
	var tile_cell_size = _nav_tile_cell_size(map_def)
	var open_water_cell_size = _nav_cell_size(map_def)
	var maps := {}
	for entry in [["ground_map", tile_cell_size], ["amphibious_map", tile_cell_size],
			["water_map", open_water_cell_size], ["deep_water_map", open_water_cell_size]]:
		var m = NavigationServer3D.map_create()
		NavigationServer3D.map_set_cell_size(m, entry[1])
		NavigationServer3D.map_set_cell_height(m, NAV_CELL_HEIGHT)
		NavigationServer3D.map_set_active(m, true)
		# Chunk 21 fallout, revisited by the 2026-08-23 seam fix. This margin
		# is the FALLBACK connector for nearby parallel region edges; it was
		# 4x cell_size because that had to bridge the erosion+quantization
		# gap left by baking each tile as a standalone island - and wherever
		# the gap exceeded it, the seam silently did not connect (the
		# "arbitrary line units won't cross" playtest bug). With
		# NAV_TILE_BORDER_CELLS the two sides of a seam end on the same
		# plane, so the margin only has to absorb residual float noise and
		# any corner-vertex mismatch: 1.5x a cell. That is deliberately too
		# small to bridge REAL holes (a genuine obstacle carve is many cells
		# wide plus agent-radius erosion on each side), which the 4x value
		# could do at large map scales - bridging a lake shore at a tile
		# boundary is the same class of wrong as not connecting the seam.
		# NOTE (2026-08-27): raising this to 4x cell was tried as a fix for the
		# islanding described in terrain_dressing.gd's header - terrain relief
		# makes tiles bake 30-70 polygons instead of 2, and the seams then stop
		# connecting. It did NOT help, so the margin is not the mechanism and
		# the value is left where it was rather than carrying a speculative
		# change. The real constraint is recorded on POST_PASS_NAVMESH_LIMIT.
		NavigationServer3D.map_set_edge_connection_margin(m, entry[1] * 1.5)
		maps[entry[0]] = m
	return maps


# RTS_CORE_ROADMAP.md B8: a NavigationServer3D MAP has its own cell_size/
# cell_height (default 0.25, independent of whatever a NavigationMesh
# RESOURCE assigned to one of its regions uses) - region_set_navigation_
# mesh() silently REJECTS the mesh (real error, not just a warning) if the
# two don't match, which a region-to-map association check alone doesn't
# reveal. Every map/region created below goes through _create_nav_maps()
# and build_ground_amphibious_tiles()/build_water_and_deep_water() for
# exactly that reason - one place sets a map's cell_size, one place bakes
# regions at that same cell_size, instead of the two drifting apart.
#
# Chunk 21: "ground_region"/"amphibious_region" (singular) are now
# "ground_regions"/"amphibious_regions" (Array) - one per navmesh tile, see
# NAV_TILE_SIZE's header comment. No caller outside this file and
# match_director.gd's three touch points (assignment, teardown, mid-match
# rebake) ever held a region RID directly; everything else - NavigationAgent3D,
# vision, flow fields, every existing test - queries the MAP RID, which is
# still exactly one RID per surface and completely unchanged in shape.
static func build_navmeshes(map_def: Dictionary, extra_holes: Array = []) -> Dictionary:
	# Resolve features once at the top so the navmesh bake sees the
	# auto-emitted cliffs[] from plateaus / canyons / ridges, and the
	# auto-emitted water_areas[] from lakes. Without this, the ground
	# navmesh would route units straight through a plateau's wall, which
	# is the same bug class canyon_ford PR1 hit on hand-authored cliffs.
	_resolve_features(map_def)
	var maps = _create_nav_maps(map_def)
	var ga = build_ground_amphibious_tiles(map_def, extra_holes, maps.ground_map, maps.amphibious_map, true)
	var wd = build_water_and_deep_water(map_def, maps.water_map, maps.deep_water_map, true)
	return {"ground_map": maps.ground_map, "water_map": maps.water_map,
		"amphibious_map": maps.amphibious_map, "deep_water_map": maps.deep_water_map,
		"ground_regions": ga.ground_regions, "amphibious_regions": ga.amphibious_regions,
		"tile_rects": ga.tile_rects,
		"water_region": wd.water_region, "deep_water_region": wd.deep_water_region}


# Same as build_navmeshes(), but WITHOUT baking: every map and region RID is
# created and wired up, and the source geometry for each surface is returned
# unbaked in "pending" so the caller can bake them one at a time (or, since
# bake_pending_entry_async() exists now, all at once off the main thread).
#
# The load path still creates and returns every region before baking starts -
# units spawn and take their first orders within a frame or two of _ready(),
# and scene_router.gd's Deploy gate (see match_director.gd's
# bake_pending_entry_async() wiring) is what makes it safe for the ACTUAL
# bake to happen off-thread: nothing can query a region before world_is_ready
# flips, regardless of how the mesh assignment itself is scheduled.
#
# Each pending entry is {"region": RID, "verts": PackedVector3Array, "label":
# String, "cell_size": float}; feed them to bake_pending_entry() or
# bake_pending_entry_async() in order (or all at once - see match_director.gd).
static func build_navmeshes_deferred(map_def: Dictionary, extra_holes: Array = []) -> Dictionary:
	var maps = _create_nav_maps(map_def)
	var ga = build_ground_amphibious_tiles(map_def, extra_holes, maps.ground_map, maps.amphibious_map, false)
	var wd = build_water_and_deep_water(map_def, maps.water_map, maps.deep_water_map, false)
	var pending: Array = ga.pending + wd.pending
	return {"ground_map": maps.ground_map, "water_map": maps.water_map,
		"amphibious_map": maps.amphibious_map, "deep_water_map": maps.deep_water_map,
		"ground_regions": ga.ground_regions, "amphibious_regions": ga.amphibious_regions,
		"tile_rects": ga.tile_rects,
		"water_region": wd.water_region, "deep_water_region": wd.deep_water_region,
		"pending": pending, "cell_size": ga.cell_size}

static func bake_pending_entry(entry: Dictionary, cell_size: float = 0.0) -> void:
	# cell_size param kept (defaulted, unused when the entry carries its own -
	# every current producer of "pending" entries now does, since ground/
	# amphibious tiles and water/deep_water need DIFFERENT cell_size values)
	# only so any external caller passing the old two-arg form still parses.
	var effective: float = entry.get("cell_size", cell_size)
	# Ground/amphibious tile entries carry their rect for the border-bake
	# config (NAV_TILE_BORDER_CELLS); water entries predate that and get the
	# plain whole-surface configuration.
	NavigationServer3D.region_set_navigation_mesh(entry["region"],
		_bake_nav_mesh(entry["verts"], effective, entry.get("rect", null)))


# Async twin of bake_pending_entry(). build_navmeshes_deferred() already
# spreads Recast's ~1s-per-surface cost across separate FRAMES, but each of
# those frames still blocks the main thread for the full duration of that
# surface's bake - a scale=4 map's four surfaces are enough back-to-back
# near-1-second stalls (with the message pump stalled between them, not
# during) for Windows to grey the title bar and report Not Responding, which
# is what a scale=1 map's much smaller surfaces never triggered. Recast
# itself does not need the main thread - the mid-match rebake path already
# proved that (_bake_region_async). The only reason the LOAD path used the
# synchronous version was that a match with no loading gate needs the
# navmesh before the first unit can act - but scene_router.gd's Deploy gate
# already withholds control until world_is_ready flips, which is exactly
# the synchronization point this needs: bake off-thread, and simply hold
# world_is_ready (and therefore Deploy) until every surface reports back.
static func bake_pending_entry_async(entry: Dictionary, cell_size: float, on_done: Callable) -> void:
	# See bake_pending_entry()'s matching comment - entries now carry their
	# own cell_size because ground/amphibious tiles and water/deep_water no
	# longer share one. Tile entries also carry their rect for the
	# border-bake config (NAV_TILE_BORDER_CELLS).
	var effective: float = entry.get("cell_size", cell_size)
	var nav_mesh = NavigationMesh.new()
	_configure_nav_mesh(nav_mesh, effective, NAV_AGENT_RADIUS, entry.get("rect", null))
	var source = NavigationMeshSourceGeometryData3D.new()
	source.add_faces(entry["verts"], Transform3D.IDENTITY)
	var region: RID = entry["region"]
	NavigationServer3D.bake_from_source_geometry_data_async(nav_mesh, source, func():
		NavigationServer3D.region_set_navigation_mesh(region, nav_mesh)
		on_done.call())

# --- Visuals ---

static func spawn_visuals(map_def: Dictionary, parent: Node3D, ticker: Node = null, map_id: String = ""):
	# Pass a `ticker` node (the loading screen passes itself) to spread this
	# pass over multiple frames: each sub-phase below checks the same
	# BUILD_FRAME_BUDGET_MS gate build_ground_visual_mesh() uses, and yields
	# process_frame when the slice is spent. Without a ticker every branch is
	# dead and this is exactly the old single-frame synchronous call.
	#
	# This function was the second-largest continuous freeze in the world build
	# (after the ground mesh): merged water, authored obstacles/zones/bridges,
	# grass clutter, two ambient cluster passes and the slope-rock walk all ran
	# back to back inside one frame, several seconds on a large map - long
	# enough that the loading screen's lamps visibly stopped.
	var deadline_state := {"t": Time.get_ticks_usec() + int(BUILD_FRAME_BUDGET_MS * 1000.0)}
	# The deadline lives in a Dictionary because lambdas capture locals by
	# value - reassigning a plain local here would advance a private copy and
	# the gate would fire on every call forever. Mutating the dict's contents
	# propagates back out.
	var _slice = func() -> void:
		# Headless / probe callers (no SceneTree ticker): fall back to a
		# busy wait rather than a real await. See _build_conforming_zone_
		# mesh_stepwise (terrain_builder.gd:3843+) for the same fix.
		if Time.get_ticks_usec() >= deadline_state["t"]:
			if ticker == null:
				deadline_state["t"] = Time.get_ticks_usec() + int(BUILD_FRAME_BUDGET_MS * 1000.0)
			else:
				await ticker.get_tree().process_frame
				deadline_state["t"] = Time.get_ticks_usec() + int(BUILD_FRAME_BUDGET_MS * 1000.0)

	# Snapshot children before scatter so we can tag new terrain props with
	# the "terrain_debris" group. Buildings use this group to find and
	# displace overlapping props when placed.
	var _pre_ids: Dictionary = {}
	for _c in parent.get_children():
		_pre_ids[_c.get_instance_id()] = true
	# terrain.prop_scale overrides the world_scale-derived size for scattered
	# props - see map_catalog.gd's FIELD_SPEC entry for why the two have to be
	# separable on a v2 map.
	var prop_scale = float(map_def.get("terrain", {}).get("prop_scale",
		WorldScaleScript.for_map(map_def)))
	_spawn_merged_water(map_def, parent, prop_scale, map_id)
	await _slice.call()
	# Cliffs between water and obstacles: terrain infrastructure sits
	# underneath everything decorative, so the visual order is water →
	# cliffs → obstacles → surface zones, and cliffs draw on top of the
	# ground mesh but underneath every prop that should occlude them.
	# canyon_ford PR1, 2026-08-26.
	#
	# Auto-emit cliffs[] / water_areas[] from terrain.features[] BEFORE
	# _spawn_cliffs runs, so the new feature types (plateau, canyon, ridge,
	# lake) light up the same spawn path the hand-authored entries use.
	# The resolver is idempotent: re-running with the same map_def produces
	# the same emissions, and a second call is a no-op (the auto-emitted
	# entries are tagged with an "auto" meta so we don't double-emit if
	# spawn_visuals is called more than once - which it is on scene reload).
	_resolve_features(map_def)
	# CLIFF PROPS ARE A v1 COMPENSATION AND v2 MUST NOT SPAWN THEM.
	#
	# They exist because v1's ground mesh cannot draw a wall: at (span / 280)
	# a 6-8 m wall is about one quad across, so the mesh renders a ramp and
	# discrete 8 m cliff GLBs get stamped along the wall line to stand in for
	# it. On sentinel_divide that is 1472 props at 4 m spacing, and at this
	# scale a line of small repeated pieces reads as a picket fence rather
	# than as rock - which is exactly how it looked in play.
	#
	# v2 subdivides the mesh where the ground is steep (DETAIL_TRIGGER_RISE),
	# so the wall is real geometry and the props are redundant.
	#
	# NOTE the split: _resolve_features() still runs, so the cliffs[] entries
	# are still emitted into map_def. The NAVMESH bake consumes those, and
	# skipping the emission would route units straight through a plateau wall.
	# Only the visual/collider spawn is skipped.
	if terrain_generator(map_def) != "v2":
		_spawn_cliffs(map_def, parent, prop_scale)
	await _slice.call()
	for o in map_def.get("obstacles", []):
		_spawn_obstacle(o, parent, map_def)
	await _slice.call()
	# v2 paints surface types into the GROUND ITSELF from the splat raster,
	# with a real height blend and a noise-warped boundary. Laying the v1
	# overlay meshes on top of that would stamp the exact hard-edged
	# rectangles the splat exists to replace - and it did: the first capture
	# of a v2 map showed sharp green/grey/brown rectangles sitting on
	# correctly-blended ground. The zones still drive their greeble scatter
	# and their forest LOS volumes; only the overlay QUAD is skipped.
	var v2_ground := terrain_generator(map_def) == "v2"
	for s in map_def.get("surface_zones", []):
		if v2_ground:
			TerrainGreeblesScript.scatter(s, parent, prop_scale, map_def)
		else:
			# Each zone builds its own conforming mesh (one height sample per
			# vertex), so zones are chunked individually AND internally - the
			# zone mesh builder carries the same budget gate. A zone is itself a
			# coroutine now, so it must be awaited or the next phases would run
			# detached underneath it.
			await _spawn_surface_zone(s, parent, prop_scale, map_def, ticker)
		await _slice.call()
	# canyon_ford PR5 (2026-08-26): per-forest-zone LOS-blocking AABBs
	# are added AFTER the visual surface zones so the body sits on
	# top of the (already-built) visual mesh, and so the LOS raycast
	# hits a body whose AABB is exactly aligned with what the player
	# sees. Cheap (1-2 StaticBody3D + BoxShape3D per map), no frame
	# budget hit, the navmesh bake is unaffected (see _spawn_forest_
	# zone_aabbs's own header for why).
	_spawn_forest_zone_aabbs(map_def, parent, prop_scale)
	for sw in map_def.get("shallow_water_areas", []):
		_spawn_shallow_water_marker(sw, parent, prop_scale)
	for b in map_def.get("bridges", []):
		_spawn_bridge(b, parent)
	await _slice.call()
	# --- DRESSING -----------------------------------------------------------
	#
	# v2 replaces the four hardcoded visual passes below with one rule-driven
	# pass (scripts/terrain_dressing.gd + data/terrain_dressing/*.json). The
	# old passes could only ask about SLOPE, so a hillside looked identical
	# whichever way it faced and nothing could be placed relative to water.
	#
	# AMBIENT ORE IS NOT DRESSING and still runs on both paths - those are
	# harvestable deposits, i.e. economy, and moving them into a cosmetic rule
	# file would put gameplay balance in an art asset.
	if v2_ground:
		# If the map has authored props (trees, boulders, cliff meshes, etc. painted in editor),
		# spawn them directly via TerrainVisualScatter!
		var authored_props: Array = map_def.get("props", [])
		if not authored_props.is_empty():
			var visual_scatter = TerrainVisualScatterScript.get_or_create(parent)
			if visual_scatter != null:
				await visual_scatter.spawn_authored_props(authored_props, prop_scale, ticker)
				await _slice.call()

		# ORE FIRST. The dressing commits the shared MultiMesh batcher itself
		# (it has to - see its own note on global_transform), and registering
		# after a commit is refused. Ore is economy, not dressing, so it keeps
		# its own pass either way.
		if not bool(map_def.get("disable_ambient_scatter", false)):
			await _spawn_ambient_ores(map_def, parent, prop_scale, [], ticker)
			await _slice.call()
		if authored_props.is_empty():
			var dressed: Dictionary = await TerrainDressingScript.scatter(
				map_def, parent, prop_scale, ticker, str(map_def.get("id", "")))
			var total := 0
			for k in dressed:
				total += int(dressed[k])
			BattleLogger.log_build_step("terrain.dressing_v2", 0.0, {"placed": total})
			await _slice.call()
		# ONE commit for everything registered above. The dressing commits as
		# part of its own pass, and commit() is idempotent, so this only does
		# real work on the authored-props path where the dressing is skipped -
		# without it the cliff strata would register and never be built.
		var batcher = AmbientScatterScript.get_or_create(parent)
		if batcher != null:
			batcher.commit()
		_tag_terrain_debris(parent, _pre_ids)
		return

	_spawn_grassland_clutter(map_def, parent, prop_scale)
	await _slice.call()
	# Ambient forest + ambient ore (2026-08-10, paired passes).
	# _spawn_ambient_trees runs first and RETURNS the placed positions,
	# which _spawn_ambient_ores then uses as an extra avoidance set
	# so an ore and a tree never overlap. Order matters: flipping it
	# would let trees land on top of ore deposits, which reads as a
	# single composite prop rather than two distinct finds.
	#
	# `disable_ambient_scatter` (default false) lets a small playtest
	# map opt out entirely. The Test Range uses this to keep its 80x80
	# stage clean - the player needs to see THEIR unit, not a forest
	# the ambient code packed into the available space.
	if not bool(map_def.get("disable_ambient_scatter", false)):
		var ambient_tree_positions: Array = await _spawn_ambient_trees(map_def, parent, prop_scale, ticker)
		await _slice.call()
		# Both passes contain awaits when a ticker was supplied, so both MUST
		# be awaited here. A detached call would keep scattering in the
		# background while the lines below ran - the batcher would commit
		# underneath it and every late registration would be silently dropped
		# (this exact bug shipped briefly: the ore pass lost most of a grove).
		await _spawn_ambient_ores(map_def, parent, prop_scale, ambient_tree_positions, ticker)
		await _slice.call()
	# Both ambient passes register their visuals with a shared MultiMesh
	# batcher instead of building a glTF subtree each (ambient_scatter.gd).
	# Nothing is drawn until this commit, and it must come after BOTH passes
	# because they share one batcher - see that file's ordering contract.
	var scatter := AmbientScatterScript.get_or_create(parent)
	if scatter != null:
		scatter.commit()
	var visual_scatter = TerrainVisualScatterScript.get_or_create(parent)
	if visual_scatter != null:
		await visual_scatter.scatter_all(map_def, prop_scale, ticker)
	await _spawn_slope_rocks(map_def, parent, ticker)
	await _slice.call()
	_tag_terrain_debris(parent, _pre_ids)


# Tag every MeshInstance3D added by this pass so buildings can displace it on
# placement. Extracted because the v2 dressing path returns early and would
# otherwise skip it - leaving props that a factory could be dropped straight
# on top of.
static func _tag_terrain_debris(parent: Node3D, pre_ids: Dictionary) -> void:
	for c in parent.get_children():
		if pre_ids.has(c.get_instance_id()):
			continue
		if c is MeshInstance3D and not c.is_in_group("terrain_debris"):
			c.add_to_group("terrain_debris")

# Real baked ground textures (see tools/generate_terrain_textures.gd) tiled
# across each surface_zone's real-world footprint, replacing the old flat
# albedo_color patches - one texture set per surface_type, cached the same
# way HullMaterialBuilder caches per-faction textures (this runs once per
# zone per map load, cheap either way, but no reason to reload the same 3
# PNGs for every zone that shares a surface_type). Every zone plus the
# shallow_water marker also gets non-collidable ground clutter scattered by
# TerrainGreebles - see that file for why real 3D props, not flat cards.
# EVERY PNG UNDER HERE MUST IMPORT AS "VRAM Compressed" WITH MIPMAPS ON.
# ---------------------------------------------------------------------------
# 2026-09-01: all 220 of them were importing as `compress/mode=0` (Lossless)
# with `mipmaps/generate=false`, which put 2048x2048 RGBA8 plates in VRAM with
# no mip chain. terrain_ground_v2.gdshader takes ~30 taps per fragment across
# four of those layers, so a ground plane at a grazing angle sampled full-res
# 2K textures for every pixel of the screen. Measured with
# tools/probe_terrain_fillrate.gd on delta_blues at 1080p:
#
#                              before      after
#   ground mesh, flat mat      +5.83 ms    +7.37 ms
#   the terrain material     +250.21 ms    +6.36 ms      <- 39x
#   whole scene               259.02 ms   19.88 ms
#
# That 250 ms was the skirmish frame rate. Nothing about the shader, the mesh,
# the grass carpet or the sim was wrong; the textures were being fed to the GPU
# in the most expensive form available.
#
# HOW IT HAPPENED, so it does not happen again. These .import files carry
# `detect_3d/compress_to=1`, which is Godot re-importing a texture as VRAM
# compressed the first time it sees it used on 3D geometry - and that detection
# runs in the EDITOR, on materials it can see in a scene. These plates are never
# in a scene: they are `load()`ed here and pushed into a ShaderMaterial
# parameter at runtime, so the editor never witnessed the 3D use and the
# fallback never fired. Any texture assigned this way needs its import settings
# set by hand. The same was true of assets/textures/factions and
# assets/textures/hull, fixed at the same time.
const TERRAIN_TEXTURE_DIR = "res://assets/textures/terrain/"
# Texture repeats once per this many world units - fixed, not derived from
# zone size, since (unlike a Design Lab hull) these zones are static map
# geometry that's never scaled at runtime; a plain tiled UV is enough.
const TERRAIN_TILE_WORLD_SIZE: float = 24.0

static var _terrain_texture_cache: Dictionary = {}
# surface_type -> Array of variant suffixes that actually exist on disk
# (always includes "" for the procedural bake). Probed once per surface.
static var _terrain_variant_cache: Dictionary = {}

# Every surface type has a base bake ({surface}_albedo.png) plus however many
# photographic variants tools/process_flow_terrain_textures.gd has produced
# ({surface}_v1_albedo.png and up). Zones pick between them so that a map
# isn't one identical 6-unit tile stamped out end to end - at RTS zoom the
# camera holds dozens of repeats at once, and the regularity of the grid is
# far more obvious than any individual tile's quality.
#
# The list is DISCOVERED rather than declared, so dropping new variant PNGs in
# (or deleting ones that don't work out) changes the amount of variety with no
# code change here.
#
# Variant 0 (suffix "", the procedural bake from
# tools/generate_terrain_textures.gd) is used ONLY when no photographic
# variant exists. It is deliberately NOT mixed in alongside them: a side-by-
# side grid capture of all four variants per surface made the quality gap
# obvious - the procedural marsh reads as blue blobs on green and the
# procedural snow_mud as pen scribbles, next to actual photographic ground.
# Blending them together doesn't average to something in between, it just
# drags a good surface back toward the clip-art one and reintroduces the
# regular procedural pattern the blend exists to hide. So it stays as the
# guaranteed-present fallback for surfaces no plate has been produced for
# (blue_water, shallow_water, ice), and nothing more.
const MAX_TERRAIN_VARIANTS = 8

static func _get_terrain_variants(surface_type: String) -> Array:
	if _terrain_variant_cache.has(surface_type):
		return _terrain_variant_cache[surface_type]
	var found: Array = []
	for n in range(1, MAX_TERRAIN_VARIANTS + 1):
		var suffix = "_v%d" % n
		if ResourceLoader.exists(TERRAIN_TEXTURE_DIR + surface_type + suffix + "_albedo.png"):
			found.append(suffix)
	if found.is_empty():
		found = [""]
	_terrain_variant_cache[surface_type] = found
	return found

# Deterministic variant choice from a world position. Seeded from the zone's
# own centre rather than a global RNG for the same reason the coastline wobble
# above is: map geometry has to look identical every time a map loads, or a
# saved game / rejoined match would repaint the ground. Quantised to whole
# units first so floating-point noise in a zone centre can't flip the choice
# between two runs.
static func _variant_for_position(surface_type: String, x: float, z: float) -> String:
	var variants = _get_terrain_variants(surface_type)
	if variants.size() <= 1:
		return ""
	var seed_val = hash("%s:%d:%d" % [surface_type, int(round(x)), int(round(z))])
	return variants[abs(seed_val) % variants.size()]

static func _get_terrain_textures(surface_type: String, variant: String = "") -> Dictionary:
	var v_suffix = ""
	if variant != "" and variant != "base":
		v_suffix = variant if variant.begins_with("_") else ("_" + variant)
	var key = surface_type + v_suffix
	if _terrain_texture_cache.has(key):
		return _terrain_texture_cache[key]
	var base = TERRAIN_TEXTURE_DIR + surface_type + v_suffix
	var alb_path = base + "_albedo.png"
	var nrm_path = base + "_normal.png"
	var rgh_path = base + "_roughness.png"
	var textures = {
		"albedo": load(alb_path) if ResourceLoader.exists(alb_path) else null,
		"normal": load(nrm_path) if ResourceLoader.exists(nrm_path) else null,
		"roughness": load(rgh_path) if ResourceLoader.exists(rgh_path) else null,
	}
	_terrain_texture_cache[key] = textures
	return textures

# `tile_scale` multiplies TERRAIN_TILE_WORLD_SIZE - CORE_DESIGN_LANGUAGE.md
# §3.2: at a larger world scale, the ground texture's own texel density has
# to grow along with the greeble dressing sitting on top of it (see Chunk 5-
# 8 above), or the texture would read as shrinking relative to everything
# else. Callers that already resolved a prop_scale for their greeble calls
# (Chunk 7) pass the same value here - one resolved scale per call site, not
# two independently-drifting ones.
static func _build_terrain_material(surface_type: String, footprint: Vector2, tint: Color = Color.WHITE, variant: String = "", tile_scale: float = 1.0) -> StandardMaterial3D:
	var mat = StandardMaterial3D.new()
	var tex = _get_terrain_textures(surface_type, variant)
	mat.albedo_texture = tex.albedo
	mat.albedo_color = tint
	mat.roughness_texture = tex.roughness
	mat.roughness = 1.0
	mat.normal_enabled = true
	mat.normal_texture = tex.normal
	var tile_size = TERRAIN_TILE_WORLD_SIZE * tile_scale
	mat.uv1_scale = Vector3(footprint.x / tile_size, footprint.y / tile_size, 1.0)
	return mat

# The baseline ground plane's material - called by skirmish.gd for the map-
# wide Ground box mesh (everywhere that isn't a special surface_zone/water/
# obstacle/elevation footprint). Unlike the 5 special-case types, this one
# gets a real per-map TINT on top of the baked "grassland" texture: each
# map's own ground_color (map_catalog.gd) used to be the ONLY visual
# variation between maps' baseline ground, and dropping that entirely in
# favor of one identical texture everywhere would flatten a real (if
# subtle) piece of per-map identity. lightened() first so multiplying by
# the baked texture's own mid-tone albedo doesn't compound into something
# far darker than either color alone.
static func build_ground_material(ground_color: Color, footprint: Vector2) -> StandardMaterial3D:
	return _build_terrain_material("grassland", footprint, v2_ground_tint(ground_color))

# Same baked grassland texture as build_ground_material(), but for
# build_ground_visual_mesh()'s dense heightmap mesh, which bakes its own
# absolute-world-position UVs directly into the mesh (see that function) -
# no footprint-relative uv1_scale needed on the material itself.
#
# This one uses the multi-variant blend shader rather than a plain
# StandardMaterial3D, because it's the single worst repetition offender in the
# game: one 6-unit tile stretched over the entire map. See
# shaders/terrain_ground.gdshader for why the blend is a fade driven by
# low-frequency noise rather than a hard per-patch choice.
#
# Returns Material, not StandardMaterial3D - callers assign it straight to
# material_override, which is typed Material anyway.
const GROUND_BLEND_SHADER = preload("res://shaders/terrain_ground.gdshader")

static func build_ground_material_heightmap(ground_color: Color, map_def: Dictionary = {}) -> Material:
	var mat: ShaderMaterial = build_blended_surface_material("grassland", v2_ground_tint(ground_color), map_def) as ShaderMaterial
	# VISUAL polish 2026-08-23: rock triplanar overlay switched from
	# "base" to "_v1". The base rocky_albedo.png is the GDScript-generated
	# procedural brickwork (32x32 faceted cells with ink-seam cracks)
	# and reads as a stylized brick wall at tactical zoom once the new
	# env (auto-exposure + contrast grade) accentuates the contrast
	# between stone tops and dark cracks. The _v1 variant is the
	# photo-realistic cracked-earth plate from process_flow_terrain_
	# textures.gd and reads as actual rock in the same context. The
	# triplanar pass is gated to slope > 0.65 (terrain_ground.gdshader:45)
	# so flat maps (test range) are unaffected; the swap only changes
	# what shows on hilly maps' slopes.
	var rock_tex = _get_terrain_textures("rocky", "_v1")
	mat.set_shader_parameter("rock_albedo", rock_tex.albedo)
	mat.set_shader_parameter("rock_normal", rock_tex.normal)
	mat.set_shader_parameter("rock_rough", rock_tex.roughness)
	
	if not map_def.is_empty():
		var half = map_def.get("map_half_extents", 100.0)
		mat.set_shader_parameter("map_half_extents", half)
		var map_id = map_def.get("id", "")
		if map_id != "":
			var wet_path = "res://data/maps/%s_wetness.png" % map_id
			if ResourceLoader.exists(wet_path):
				mat.set_shader_parameter("wetness_tex", load(wet_path))
				mat.set_shader_parameter("use_wetness", true)
			var macro_path = "res://data/maps/%s_macro.png" % map_id
			if ResourceLoader.exists(macro_path):
				mat.set_shader_parameter("macro_tex", load(macro_path))
				mat.set_shader_parameter("use_macro", true)
			var curv_path = "res://data/maps/%s_curvature.png" % map_id
			if ResourceLoader.exists(curv_path):
				mat.set_shader_parameter("curvature_tex", load(curv_path))
				mat.set_shader_parameter("use_curvature", true)
	return mat

# --- Terrain v2 ------------------------------------------------------------
#
# A map opts in with `"terrain": { "generator": "v2" }`. Anything else - which
# is every map shipping today - takes the v1 path above, byte for byte. The
# split is deliberate: v1's surfacing has known defects (see
# shaders/terrain_ground_v2.gdshader's header for the list) but it is also what
# every existing map was authored against, so it is frozen rather than fixed.
const GROUND_BLEND_SHADER_V2 = preload("res://shaders/terrain_ground_v2.gdshader")

# Splat channel -> surface type. Must match build_terrain.py's build_splatmap()
# channel order (R grass, G rock, B dirt, A sand); they are two halves of one
# contract and there is no runtime check that they agree.
# The `ground_*` plates are 2048 px and built for a ~28 m tile
# (tools/generate_ground_plates.py). The v1 plates they replace are 256-512 px
# and were tiling every 6 m - 320 repeats across a 1920 m map.
#
# NOT named `<surface>_v<n>`: that suffix is what v1's variant discovery probes
# for, so calling one `grassland_v2` would silently pull it into every v1 map's
# blend and restyle terrain that is meant to be frozen.
const V2_LAYERS: Array = ["ground_grass", "ground_rock", "ground_dirt", "ground_sand"]
const V2_LAYER_VARIANTS: Array = ["", "", "", ""]
# Falls back to the v1 plates if the wide ones have not been generated yet, so
# a fresh checkout that has not run the generator still renders something.
const V2_LAYERS_FALLBACK: Array = ["grassland", "rocky", "dirt", "sand"]
const V2_LAYER_VARIANTS_FALLBACK: Array = ["", "_v1", "_v1", "_v1"]
const V2_DETAIL_NORMAL := "res://assets/textures/terrain/detail_normal.png"

static func terrain_generator(map_def: Dictionary) -> String:
	var t = map_def.get("terrain", {})
	if typeof(t) != TYPE_DICTIONARY:
		return "v1"
	var g := str(t.get("generator", "")).strip_edges().to_lower()
	return g if g != "" else "v1"

# The one entry point callers should use. Dispatches on the map's declared
# generator so the call site does not need to know which system it is on.
#
# `map_id` is passed EXPLICITLY rather than read off map_def. MapCatalog keys
# its cache by filename and never injects an "id" key into the dictionary it
# returns, so `map_def.get("id", "")` is empty for every map in the game. v1's
# build_ground_material_heightmap() gates its wetness/macro/curvature loads on
# exactly that value, which means none of those three rasters has ever been
# bound at runtime on any map - they are baked, and then not used. That is a
# v1 defect, and per the freeze it stays as it is; v2 simply must not inherit
# it, so it takes the id from the caller who actually knows it.
# --- water ------------------------------------------------------------------
#
# The map-wide water table. NEGATIVE by default, and that is the whole point:
# the old default was +0.05, which sits ABOVE the resting height of terrain
# that averages zero, so every v2 map came up flooded from edge to edge with
# only the plateaus and ridges above the surface. -2.0 puts the table below
# ordinary ground and leaves it visible in genuine depressions - canyon floors,
# carved basins - which is what a water table is for.
#
# Per-map override: `water_level` in the map JSON.
const WATER_LEVEL_DEFAULT: float = -2.0

# Painted water encoding, shared by the sculpt tool's brush and the mesh
# builder below. R is coverage; G and B carry a 16-bit surface height mapped
# over WATER_PAINT_RANGE. 8 bits alone would quantise a lake surface to ~0.5 m
# steps, which is enough to make a shoreline visibly wrong; the second byte
# costs nothing and takes that to millimetres.
const WATER_PAINT_RANGE := Vector2(-64.0, 64.0)
const WATER_PAINT_RES: int = 512
const WATER_PAINT_MIN_COVER: float = 0.35


# --- the one water query -----------------------------------------------------
#
# Everything that needs to know "is there water here" goes through
# submerged_at(). Before this there were three separate notions of water -
# water_areas rects, water_blobs, and (visual only) the table plane - and the
# table was invisible to every one of them, so a unit walked across the bottom
# of a lake the renderer was drawing over its head.
#
# The painted raster is cached per map id: it is sampled tens of thousands of
# times per navmesh bake, and re-loading a 512x512 PNG for each would dominate.
static var _water_paint_cache: Dictionary = {}


static func _water_paint_for(map_id: String) -> Image:
	if map_id == "":
		return null
	if _water_paint_cache.has(map_id):
		return _water_paint_cache[map_id]
	var img := load_water_paint(map_id)
	_water_paint_cache[map_id] = img
	return img


static func clear_water_paint_cache() -> void:
	_water_paint_cache = {}


# Height of the water surface over (x, z). Painted bodies WIN over the table: a
# tarn painted at +18 m on a map whose table is -2 m has to read as +18 m, or
# painting it was pointless.
# Does this map have a water table at all? v1 maps are frozen, and they were
# authored when water meant "a water_areas rect" - giving them a table
# retroactively would flood any of them whose terrain dips below -2 and change
# a shipped map's pathing. Same opt-in condition the table PLANE already uses,
# so the visual and the navmesh agree about which maps have one.
static func has_water_table(map_def: Dictionary) -> bool:
	if map_def.has("water_level"):
		return true
	if terrain_generator(map_def) == "v2":
		return true
	var terr = map_def.get("terrain", {})
	return typeof(terr) == TYPE_DICTIONARY and terr.has("sculpt_grid")


# Well below any terrain: "there is no water here", without needing an
# is-there-water boolean threaded alongside every height comparison.
const NO_WATER: float = -1.0e9


static func water_surface_at(map_def: Dictionary, x: float, z: float) -> float:
	var surface: float = water_level_of(map_def) if has_water_table(map_def) else NO_WATER
	var img := _water_paint_for(str(map_def.get("id", "")))
	if img != null:
		var half: Vector2 = MapCatalogScript.half_extents(map_def)
		var u: float = (x / (half.x * 2.0)) + 0.5
		var v: float = (z / (half.y * 2.0)) + 0.5
		if u >= 0.0 and u <= 1.0 and v >= 0.0 and v <= 1.0:
			var px: int = clampi(int(u * float(img.get_width())), 0, img.get_width() - 1)
			var pz: int = clampi(int(v * float(img.get_height())), 0, img.get_height() - 1)
			var c: Color = img.get_pixel(px, pz)
			if c.r >= WATER_PAINT_MIN_COVER:
				surface = maxf(surface, decode_water_height(c.g, c.b))
	return surface


# A shoreline is not a step function. Terrain a couple of centimetres under the
# surface is a wet beach, not a lake, and carving the navmesh at exactly the
# waterline leaves a ragged fringe of single-cell holes along every shore. A
# unit can drive through a puddle.
const SUBMERGED_MIN_DEPTH: float = 0.6


static func submerged_at(map_def: Dictionary, x: float, z: float) -> bool:
	return height_at(map_def, x, z) < water_surface_at(map_def, x, z) - SUBMERGED_MIN_DEPTH


static func water_level_of(map_def: Dictionary) -> float:
	return float(map_def.get("water_level", WATER_LEVEL_DEFAULT))


static func water_paint_path(map_id: String) -> String:
	return "res://data/maps/%s_water.png" % map_id


static func encode_water_height(h: float) -> Vector2:
	var t: float = clampf((h - WATER_PAINT_RANGE.x)
		/ maxf(WATER_PAINT_RANGE.y - WATER_PAINT_RANGE.x, 0.001), 0.0, 1.0)
	var q: int = clampi(int(round(t * 65535.0)), 0, 65535)
	return Vector2(float(q >> 8) / 255.0, float(q & 0xFF) / 255.0)


static func decode_water_height(g: float, b: float) -> float:
	var q: float = (g * 255.0) * 256.0 + (b * 255.0)
	return WATER_PAINT_RANGE.x + (q / 65535.0) * (WATER_PAINT_RANGE.y - WATER_PAINT_RANGE.x)


static func load_water_paint(map_id: String) -> Image:
	if map_id == "":
		return null
	var p := water_paint_path(map_id)
	if ResourceLoader.exists(p):
		var t: Texture2D = load(p)
		if t != null:
			return t.get_image()
	if FileAccess.file_exists(p):
		return Image.load_from_file(ProjectSettings.globalize_path(p))
	return null


# Coverage at a texel CORNER: the mean of the up-to-four texels touching it.
# Sampling per corner rather than per texel makes neighbouring quads agree on
# their shared edge, so the alpha gradient is continuous instead of flat per
# quad - which would just move the staircase from the outline into the shading.
static func _water_corner_alpha(img: Image, cx: int, cy: int) -> float:
	var w := img.get_width()
	var h := img.get_height()
	var acc := 0.0
	var n := 0
	for dy in [-1, 0]:
		for dx in [-1, 0]:
			var px: int = cx + dx
			var py: int = cy + dy
			if px < 0 or py < 0 or px >= w or py >= h:
				continue
			acc += img.get_pixel(px, py).r
			n += 1
	if n == 0:
		return 0.0
	return smoothstep(0.06, WATER_PAINT_MIN_COVER, acc / float(n))


# One mesh for every painted body. Texels are emitted as quads at their own
# encoded height, so two lakes at different altitudes come out of a single
# raster without needing to be separated into regions first.
static func build_painted_water_mesh(map_def: Dictionary, map_id: String) -> ArrayMesh:
	var img := load_water_paint(map_id)
	if img == null:
		return null
	var half: Vector2 = MapCatalogScript.half_extents(map_def)
	var w := img.get_width()
	var h := img.get_height()
	if w < 2 or h < 2:
		return null
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var emitted := 0
	var step_x: float = (half.x * 2.0) / float(w)
	var step_z: float = (half.y * 2.0) / float(h)
	# Emit BELOW the visible threshold and let alpha carry the edge, so the
	# shoreline fades over two or three texels instead of ending on a hard
	# raster step. A painted lake is a staircase in geometry no matter what;
	# the fade is what stops it looking like one.
	var emit_at: float = WATER_PAINT_MIN_COVER * 0.35
	for py in range(h):
		for px in range(w):
			var c: Color = img.get_pixel(px, py)
			if c.r < emit_at:
				continue
			var y: float = decode_water_height(c.g, c.b)
			var x0: float = -half.x + float(px) * step_x
			var z0: float = -half.y + float(py) * step_z
			var x1: float = x0 + step_x
			var z1: float = z0 + step_z
			var quad := [
				[Vector3(x0, y, z0), _water_corner_alpha(img, px, py)],
				[Vector3(x1, y, z0), _water_corner_alpha(img, px + 1, py)],
				[Vector3(x1, y, z1), _water_corner_alpha(img, px + 1, py + 1)],
				[Vector3(x0, y, z1), _water_corner_alpha(img, px, py + 1)],
			]
			for k in [0, 1, 2, 0, 2, 3]:
				var v: Vector3 = quad[k][0]
				st.set_color(Color(1.0, 1.0, 1.0, quad[k][1]))
				st.set_normal(Vector3.UP)
				st.set_uv(Vector2(v.x, v.z) / TERRAIN_TILE_WORLD_SIZE)
				st.add_vertex(v)
			emitted += 1
	if emitted == 0:
		return null
	st.generate_tangents()
	return st.commit()


const GRASS_SHELL_SHADER = preload("res://shaders/terrain_grass_shells.gdshader")

# Shell-grass tuning. See shaders/terrain_grass_shells.gdshader for what a
# shell is and why this is affordable.
#
# The two numbers that matter together are GRASS_CHUNK_SIZE and
# GRASS_VIEW_DISTANCE. Godot culls by distance from the camera to an
# instance's AABB, so a single whole-map carpet could never be range-culled -
# its AABB is the map. Chunking it is what lets the carpet cost nothing at
# battle altitude, and the chunk has to be small enough that a chunk near the
# camera does not drag in geometry 500 m away.
#
# 2026-09-01, MEASURED, because this carpet has twice now been blamed for the
# skirmish frame rate on the strength of a plausible story rather than a
# number. tools/probe_terrain_fillrate.gd, delta_blues, camera at the real
# 26 m default, 1080p:
#
#                            before tex fix   after
#   control (sky only)          2.98 ms GPU    2.71 ms
#   + ground mesh, flat mat     8.81 ms GPU   10.08 ms
#   + real terrain material   259.02 ms GPU   16.45 ms
#   + grass carpet            259.19 ms GPU   19.88 ms
#
# The carpet is 0.17 ms of a 259 ms frame, or 3.4 ms of a 20 ms one. It was
# never the cost - the ground material was, see TERRAIN_TEXTURE_DIR - and
# tuning these four numbers down buys a few milliseconds at best while
# visibly shortening the grass.
#
# One thing the shader's own header gets wrong, though, and it is worth
# knowing: it claims the battle camera sits ~150 m up so every chunk
# range-culls and the carpet costs nothing. RTSCamera.height defaults to 26 m.
# The carpet DOES draw at the default zoom. It is simply cheap when it does,
# which is the opposite of the reason the header gives.
#
# Re-run the probe before changing any of these four numbers.
const GRASS_CHUNK_SIZE: float = 96.0
const GRASS_MESH_STEP: float = 4.0     # carpet follows terrain, not blades
const GRASS_SHELL_COUNT: int = 8
const GRASS_VIEW_DISTANCE: float = 110.0
const GRASS_VIEW_FADE: float = 25.0
# Below this mean splat-grass coverage a chunk is not built at all - no point
# submitting a carpet over the canyon floor to have every texel discarded.
const GRASS_CHUNK_MIN_COVER: float = 0.12
# Slope at which grass cover reaches zero. 0.70 is MAX_WALKABLE_SLOPE; grass
# gives up well before a vehicle does.
const GRASS_MAX_SLOPE: float = 0.38


# The spiky carpet. v2 maps only; v1 keeps its own scattered grass meshes.
# Returns the number of chunks built, which the probe reports.
static func build_grass_shells(map_def: Dictionary, parent: Node3D, map_id: String = "") -> int:
	if parent == null or terrain_generator(map_def) != "v2":
		return 0
	var half: Vector2 = MapCatalogScript.half_extents(map_def)

	# Read the splat once on the CPU so empty chunks are never built. The
	# shader also samples it per fragment, but that only saves shading - this
	# saves the mesh, the MultiMesh and the draw call.
	var splat_img: Image = null
	if map_id != "":
		var sp := "res://data/maps/%s_splat.png" % map_id
		if ResourceLoader.exists(sp):
			var t: Texture2D = load(sp)
			if t != null:
				splat_img = t.get_image()
		elif FileAccess.file_exists(sp):
			splat_img = Image.load_from_file(ProjectSettings.globalize_path(sp))

	var root := Node3D.new()
	root.name = "GrassShells"
	parent.add_child(root)

	var mat := ShaderMaterial.new()
	mat.shader = GRASS_SHELL_SHADER
	mat.set_shader_parameter("map_half_extents", maxf(half.x, half.y))
	if splat_img != null:
		mat.set_shader_parameter("splat_tex", ImageTexture.create_from_image(splat_img))
		mat.set_shader_parameter("use_splat", true)

	var built := 0
	var cz := -half.y
	while cz < half.y:
		var cz1: float = minf(cz + GRASS_CHUNK_SIZE, half.y)
		var cx := -half.x
		while cx < half.x:
			var cx1: float = minf(cx + GRASS_CHUNK_SIZE, half.x)
			if _grass_chunk_cover(map_def, splat_img, half, cx, cx1, cz, cz1) >= GRASS_CHUNK_MIN_COVER:
				var mesh := _build_grass_chunk_mesh(map_def, cx, cx1, cz, cz1)
				if mesh != null:
					root.add_child(_grass_chunk_instance(mesh, mat, built))
					built += 1
			cx = cx1
		cz = cz1
	return built


static func _grass_chunk_instance(mesh: ArrayMesh, mat: Material, index: int) -> MultiMeshInstance3D:
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.use_custom_data = true
	mm.mesh = mesh
	mm.instance_count = GRASS_SHELL_COUNT
	for i in range(GRASS_SHELL_COUNT):
		# Shell 0 sits ON the ground; the top shell reaches grass_height. The
		# index rides in custom data so all N shells are one draw call.
		var t: float = float(i + 1) / float(GRASS_SHELL_COUNT)
		mm.set_instance_transform(i, Transform3D.IDENTITY)
		mm.set_instance_custom_data(i, Color(t, 0.0, 0.0, 1.0))
	var mmi := MultiMeshInstance3D.new()
	mmi.multimesh = mm
	mmi.material_override = mat
	mmi.name = "GrassChunk_%d" % index
	mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	# The cull that makes this free at battle zoom.
	mmi.visibility_range_end = GRASS_VIEW_DISTANCE
	mmi.visibility_range_end_margin = GRASS_VIEW_FADE
	mmi.visibility_range_fade_mode = GeometryInstance3D.VISIBILITY_RANGE_FADE_SELF
	return mmi


static func _grass_chunk_cover(map_def: Dictionary, splat: Image, half: Vector2,
		x0: float, x1: float, z0: float, z1: float) -> float:
	if splat == null:
		return 1.0
	var acc := 0.0
	var n := 0
	for i in range(4):
		for j in range(4):
			var x: float = lerpf(x0, x1, (float(i) + 0.5) / 4.0)
			var z: float = lerpf(z0, z1, (float(j) + 0.5) / 4.0)
			var u: float = clampf(x / (maxf(half.x, half.y) * 2.0) + 0.5, 0.0, 1.0)
			var v: float = clampf(z / (maxf(half.x, half.y) * 2.0) + 0.5, 0.0, 1.0)
			var px: int = clampi(int(u * float(splat.get_width())), 0, splat.get_width() - 1)
			var pz: int = clampi(int(v * float(splat.get_height())), 0, splat.get_height() - 1)
			acc += splat.get_pixel(px, pz).r
			n += 1
	return acc / float(maxi(n, 1))


static func _build_grass_chunk_mesh(map_def: Dictionary, x0: float, x1: float,
		z0: float, z1: float) -> ArrayMesh:
	var nx: int = maxi(int(ceil((x1 - x0) / GRASS_MESH_STEP)), 1)
	var nz: int = maxi(int(ceil((z1 - z0) / GRASS_MESH_STEP)), 1)
	var verts := PackedVector3Array()
	var norms := PackedVector3Array()
	var cols := PackedColorArray()
	var idx := PackedInt32Array()
	for i in range(nx + 1):
		var x: float = lerpf(x0, x1, float(i) / float(nx))
		for j in range(nz + 1):
			var z: float = lerpf(z0, z1, float(j) / float(nz))
			verts.append(Vector3(x, height_at(map_def, x, z), z))
			# Central differences on the height field - the carpet has to sit
			# on the same surface the ground mesh draws.
			const D := 1.5
			var hx: float = height_at(map_def, x + D, z) - height_at(map_def, x - D, z)
			var hz: float = height_at(map_def, x, z + D) - height_at(map_def, x, z - D)
			norms.append(Vector3(-hx, 2.0 * D, -hz).normalized())
			# GRASS FIT IN VERTEX COLOUR, from the real height field rather than
			# from this carpet's own normal. The carpet is a 4 m grid and a
			# canyon wall is 6-8 m across, so the carpet's normal on a wall is a
			# smoothed ramp, not a vertical - the shader's normal-based slope
			# test passed and grass grew up the cliffs. slope_at() is the same
			# source of truth the dressing rules and the navmesh use, and it
			# does not care what resolution the carpet happens to be.
			var sl: float = slope_at(map_def, x, z)
			cols.append(Color(clampf(1.0 - sl / GRASS_MAX_SLOPE, 0.0, 1.0), 0.0, 0.0, 1.0))
	for i in range(nx):
		for j in range(nz):
			var a: int = i * (nz + 1) + j
			var b: int = (i + 1) * (nz + 1) + j
			var c: int = (i + 1) * (nz + 1) + j + 1
			var d: int = i * (nz + 1) + j + 1
			# Same winding as the ground mesh (see _emit_quad's note).
			idx.append_array([a, b, c, a, c, d])
	if verts.is_empty():
		return null
	var arr := []
	arr.resize(Mesh.ARRAY_MAX)
	arr[Mesh.ARRAY_VERTEX] = verts
	arr[Mesh.ARRAY_NORMAL] = norms
	arr[Mesh.ARRAY_COLOR] = cols
	arr[Mesh.ARRAY_INDEX] = idx
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arr)
	return mesh


static func build_ground_material_for(ground_color: Color, map_def: Dictionary = {}, map_id: String = "") -> Material:
	if terrain_generator(map_def) == "v2":
		return build_ground_material_v2(ground_color, map_def, map_id)
	return build_ground_material_heightmap(ground_color, map_def)

# Per-map identity WITHOUT the brightness penalty. v1 multiplied albedo by
# ground_color.lightened(0.55) through a `source_color` uniform, which is a
# 0.39 LINEAR multiply - it read as "a light grey" to whoever authored it and
# behaved as a 2.5x darkening. Here the map's colour is reduced to hue and a
# little saturation at FULL value, so it shifts the ground's cast without
# spending any of its range.
static func v2_ground_tint(ground_color: Color) -> Color:
	var v: float = maxf(ground_color.r, maxf(ground_color.g, ground_color.b))
	if v <= 0.001:
		return Color.WHITE
	return Color.from_hsv(ground_color.h, ground_color.s * 0.45, 1.0)

# Green enough that no amount of darkness makes it volcanic or arid.
static func _is_green_hue(c: Color) -> bool:
	var h: float = c.h * 360.0
	return c.s > 0.06 and h > 70.0 and h < 175.0


static func build_ground_material_v2(ground_color: Color, map_def: Dictionary, map_id: String = "") -> Material:
	var mat := ShaderMaterial.new()
	mat.shader = GROUND_BLEND_SHADER_V2
	var layers: Array = V2_LAYERS
	var variants: Array = V2_LAYER_VARIANTS
	if not ResourceLoader.exists(TERRAIN_TEXTURE_DIR + str(V2_LAYERS[0]) + "_albedo.png"):
		push_warning("TerrainBuilder v2: wide ground plates missing - falling back to the v1 plates, which tile every few metres. Run: python tools/generate_ground_plates.py")
		layers = V2_LAYERS_FALLBACK
		variants = V2_LAYER_VARIANTS_FALLBACK
	for i in range(layers.size()):
		var tex: Dictionary = _get_terrain_textures(layers[i], variants[i])
		mat.set_shader_parameter("albedo_%d" % i, tex.albedo)
		mat.set_shader_parameter("normal_%d" % i, tex.normal)
		mat.set_shader_parameter("rough_%d" % i, tex.roughness)
	if ResourceLoader.exists(V2_DETAIL_NORMAL):
		mat.set_shader_parameter("detail_normal_tex", load(V2_DETAIL_NORMAL))
	mat.set_shader_parameter("ground_tint", v2_ground_tint(ground_color))

	var theme_name: String = str(map_def.get("theme", "")).to_lower()
	if theme_name == "":
		if ground_color.r > 0.6 and ground_color.g > 0.5:
			theme_name = "desert"
		elif ground_color.r > 0.5 and ground_color.b < 0.4:
			theme_name = "arid"
		elif ground_color.b > 0.6 and ground_color.r > 0.6:
			theme_name = "tundra"
		elif (ground_color.r < 0.35 and ground_color.g < 0.35 and ground_color.b < 0.35
				and not _is_green_hue(ground_color)):
			# "Dark" is not the same as "volcanic". sentinel_divide's ground
			# colour is (0.30, 0.34, 0.28) - a dark GREEN, and a temperate map -
			# and the darkness test alone classified it volcanic, which handed
			# its cliffs the grey-purple ash tint. Excluding green hues costs
			# nothing and a real volcanic map is never green.
			theme_name = "volcanic"
		else:
			theme_name = "temperate"

	var cliff_tint := Color.WHITE
	# Per-theme strata prominence. This had been computed and then silently
	# dropped when the shader uniform was renamed - every theme got the same
	# banding. Values are rescaled for the mix: as a multiply they could only
	# ever darken, so 0.45 read as "barely there".
	var strata_str: float = 0.85
	match theme_name:
		"arid":
			cliff_tint = Color(0.92, 0.72, 0.54)
			strata_str = 1.0
		"desert":
			cliff_tint = Color(0.95, 0.58, 0.38)
			strata_str = 1.0
		"tundra":
			cliff_tint = Color(0.68, 0.74, 0.85)
			strata_str = 0.72
		"volcanic":
			cliff_tint = Color(0.42, 0.40, 0.44)
			strata_str = 0.90
		_: # temperate
			cliff_tint = Color(0.85, 0.88, 0.82)
			strata_str = 0.85

	mat.set_shader_parameter("cliff_rock_tint", cliff_tint)

	var terr: Dictionary = map_def.get("terrain", {}) if typeof(map_def.get("terrain", {})) == TYPE_DICTIONARY else {}
	var r_pat: int = int(terr.get("rock_pattern", 0))
	var r_strata: float = float(terr.get("rock_strata_strength", strata_str))
	var r_bump: float = float(terr.get("rock_bump_strength", 2.1))
	# BED THICKNESS. Note these defaults are the ones that count - the shader's
	# own uniform defaults are dead the moment this sets the parameter, which
	# is why raising the default in the .gdshader alone changed nothing.
	# 0.16 put one bed per ~6 units, i.e. three or four bands on a 22 m wall,
	# and a cliff rendered as a couple of big flat slabs. 0.5 is ~2 m beds.
	var r_scale: float = float(terr.get("rock_strata_scale", 0.5))
	var r_joint: float = float(terr.get("rock_joint_scale", 0.16))
	# SET BY MEASUREMENT, because the render response to this is heavily
	# compressed and reasoning about it from albedo alone gives the wrong
	# answer. Measured rendered cliff luminance against grass at 0.543:
	#     gain 0.45 -> 0.703   gain 0.30 -> 0.670
	#     gain 0.18 -> 0.594   gain 0.10 -> 0.513
	# A 33% albedo cut (0.45 -> 0.30) moved the output 5%, because AgX is well
	# into its shoulder at this map's exposure. 0.18 puts the face just above
	# the grass, which is what a sunlit rock face should be. The value looks
	# unphysically dark as an albedo precisely BECAUSE the scene exposure is
	# hot - the honest fix for that lives in the map environment, not here.
	var r_gain: float = float(terr.get("rock_albedo_gain", 0.18))

	mat.set_shader_parameter("rock_pattern", r_pat)
	mat.set_shader_parameter("rock_strata_strength", r_strata)
	mat.set_shader_parameter("rock_bump_strength", r_bump)
	mat.set_shader_parameter("rock_strata_scale", r_scale)
	mat.set_shader_parameter("rock_joint_scale", r_joint)
	mat.set_shader_parameter("rock_albedo_gain", r_gain)

	var half: float = float(map_def.get("map_half_extents", 100.0))
	mat.set_shader_parameter("map_half_extents", half)

	var mid := map_id if map_id != "" else str(map_def.get("id", ""))
	if mid == "":
		push_warning("TerrainBuilder v2: no map id supplied - per-map rasters (splat/macro/curvature/wetness) cannot be located and the ground will render as base layer + slope rock only.")
	else:
		var splat_path := "res://data/maps/%s_splat.png" % mid
		var splat_tex: Texture2D = null
		if ResourceLoader.exists(splat_path):
			splat_tex = load(splat_path)
		elif FileAccess.file_exists(splat_path):
			var img := Image.load_from_file(ProjectSettings.globalize_path(splat_path))
			if img != null:
				splat_tex = ImageTexture.create_from_image(img)
		
		if splat_tex != null:
			mat.set_shader_parameter("splat_tex", splat_tex)
			mat.set_shader_parameter("use_splat", true)
		else:
			push_warning("TerrainBuilder v2: no splat raster for map '%s' (%s) - ground will be base layer + slope rock only." % [mid, splat_path])
		for entry in [["macro", "macro_tex", "use_macro"], ["curvature", "curvature_tex", "use_curvature"], ["wetness", "wetness_tex", "use_wetness"]]:
			var p := "res://data/maps/%s_%s.png" % [mid, entry[0]]
			if ResourceLoader.exists(p):
				mat.set_shader_parameter(entry[1], load(p))
				mat.set_shader_parameter(entry[2], true)
	return mat


# Builds a variant-blending material for any surface type. Falls back to
# whatever variants actually exist - a surface with only its procedural bake
# gets variant_count 1 and behaves exactly as before, so this is safe to point
# at a surface no photographic plate has been produced for yet.
static func build_blended_surface_material(surface_type: String, tint: Color = Color.WHITE, _map_def: Dictionary = {}) -> Material:
	var variants = _get_terrain_variants(surface_type)
	var mat = ShaderMaterial.new()
	mat.shader = GROUND_BLEND_SHADER
	var count = mini(variants.size(), 8)
	mat.set_shader_parameter("variant_count", count)
	for i in range(count):
		var tex = _get_terrain_textures(surface_type, variants[i])
		mat.set_shader_parameter("albedo_%d" % i, tex.albedo)
		mat.set_shader_parameter("normal_%d" % i, tex.normal)
		mat.set_shader_parameter("rough_%d" % i, tex.roughness)
	mat.set_shader_parameter("ground_tint", tint)
	return mat

# Skirmish refinement pass: replaces the old flat single BoxMesh "Ground"
# node with a real subdivided surface whose every vertex samples height_at()
# - this is what makes the visual ground, the navmesh, and every unit/
# building's Y-snap all agree on the same terrain instead of a flat plane
# hiding a bumpy navmesh underneath it (which would look like floating/
# sinking units). Returns both the renderable mesh AND a matching
# HeightMapShape3D so weapon-LOS raycasts and click-to-ground order/
# placement raycasts (which hit this same collider, see skirmish.gd's
# _raycast_ground()/_has_line_of_sight()) resolve against the real surface
# too, not a stale flat one.
#
# Two different sample resolutions on purpose: the collision heightmap
# samples every 1 world unit (HeightMapShape3D's native, cheapest-correct
# resolution - a 300-unit map is still only ~90k samples, built once at
# scene setup) while the visual mesh uses a coarser GROUND_MESH_RESOLUTION
# grid (fewer triangles to render/light). Both sample the exact same
# height_at() function, so the difference between them is sub-unit smoothing
# imperceptible at gameplay camera distances, not a real mismatch.
# KNOWN LIMIT: v2 MAPS CANNOT YET HAVE ROLLING GROUND BETWEEN THEIR FEATURES.
#
# Adding terrain relief via build_terrain.py's post_pass noise - even a single
# 91 m wavelength at 3 m amplitude, which is gentle enough that every point on
# it measures walkable - makes each navmesh tile bake 30-70 polygons where
# smooth ground bakes 2. At that complexity the tiled navmesh's seam
# connection stops bridging reliably, and whole regions become unreachable
# islands: on sentinel_divide it stranded the entire south-east corner and its
# HQ, while tools/probe_terrain_ascii.gd showed every square metre of the
# corridor to it as walkable. tools/probe_terrain_reach.gd is what makes it
# visible, because it asks a different question - not "is this ground
# walkable" but "can a unit get there".
#
# Measured, removing the noise takes tiles back to 2 polygons and the map back
# to fully connected. Widening map_set_edge_connection_margin to 4x cell was
# tried and did not help, so the margin is not the mechanism.
#
# This matters beyond looks: aspect-conditioned dressing rules (north-facing
# conifers, south-facing scrub) need gentle slopes to sort on, and a map of
# dead-flat plains and vertical walls gives them almost nothing. Fixing it
# means addressing the tiled bake - larger tiles, a stitched bake, or a single
# region - which is its own piece of work.
const POST_PASS_NAVMESH_LIMIT := true

# --- Adaptive relief detail (v2 generator) ---------------------------------
#
# A quad whose corners differ in height by more than this is a wall, not
# ground, and gets re-emitted at DETAIL_SUBDIV x DETAIL_SUBDIV. 2.0 m is
# comfortably above the noise on rolling terrain and far below any authored
# wall (the shallowest here is a 22 m plateau over a 6 m falloff).
const DETAIL_TRIGGER_RISE: float = 2.0
# 5x5 sub-quads takes a 6.86 m quad to ~1.4 m - enough for a wall to read as a
# vertical face with a lit top edge rather than a smooth ramp.
const DETAIL_SUBDIV: int = 5

# Re-emits one coarse quad as an n x n grid, sampling real heights at every
# sub-corner. Takes the emit and height callables rather than closing over them
# so it can stay a plain static function next to the rest of the mesh builder.
static func _emit_detailed_quad(emit: Callable, h: Callable,
		x0: float, x1: float, z0: float, z1: float, n: int) -> void:
	var dx: float = (x1 - x0) / float(n)
	var dz: float = (z1 - z0) / float(n)
	for i in range(n):
		var sx0: float = x0 + dx * float(i)
		var sx1: float = x0 + dx * float(i + 1)
		for j in range(n):
			var sz0: float = z0 + dz * float(j)
			var sz1: float = z0 + dz * float(j + 1)
			emit.call(
				Vector3(sx0, h.call(sx0, sz0), sz0),
				Vector3(sx1, h.call(sx1, sz0), sz0),
				Vector3(sx1, h.call(sx1, sz1), sz1),
				Vector3(sx0, h.call(sx0, sz1), sz1))


const GROUND_MESH_RESOLUTION: float = 3.0
# Collision heightmap sample spacing, in world units. Kept coarser than the
# visual mesh on purpose: HeightMapShape3D always spaces samples exactly 1
# LOCAL unit apart (no separate "cell size" it exposes), so covering a big
# map at 1 WORLD unit per sample means a literal quadratic map_half_extents^2
# blowup in GDScript-side height_at() calls at scene load - harmless at the
# old ~80-120 half-extent range, but genuinely slow (tens of seconds per
# match, times every Skirmish instance the test suite spins up) once maps
# grew to the ~200-240 range. Instead, sample every COLLISION_STEP world
# units and stretch the collision shape's OWN node scale (X/Z only, Y stays
# 1.0 so real height values are untouched) to cover the full map - see
# build_ground_visual_mesh()'s returned "collision_scale", applied by
# skirmish.gd to the CollisionShape3D node. A few world units of horizontal
# collision resolution is imperceptible for raycasts (weapon LOS, click-to-
# ground) against terrain this gently undulating.
const COLLISION_HEIGHTMAP_STEP: float = 3.0

# How much main-thread work one frame may spend inside build_ground_visual_mesh()
# before it hands the frame back to the engine. Only consulted when a `ticker`
# node is passed (the live loading screen passes itself); null keeps the whole
# build in one synchronous call, which is what headless probes want.
#
# WHY 8ms: at 60 fps a frame is ~16.6 ms, so an 8 ms slice leaves over half the
# frame for rendering, input and the loading screen's lamps/turntable. Measured
# against the alternative budgets, 8 ms keeps every visible hitch under about a
# third of a frame-pair while adding only a few percent wall-clock overhead to
# the bake from the per-frame bookkeeping.
const BUILD_FRAME_BUDGET_MS: float = 8.0

# Builds the playable ground mesh + collision heightmap, optionally SPREAD OVER
# FRAMES.
#
# Pass `ticker` (any Node inside the SceneTree) to make this a coroutine that
# yields `process_frame` whenever the current frame's work exceeds
# BUILD_FRAME_BUDGET_MS. That is what keeps the loading screen animating through
# the single most expensive synchronous step of the world build - on large maps
# this function used to hold the main thread for several uninterrupted seconds,
# which froze every lamp, tween and SubViewport on screen regardless of any
# PROCESS_MODE setting, because a blocked main thread renders no frames at all.
#
# Callers without a ticker get the old behaviour exactly: no awaits execute, the
# function is an ordinary synchronous call (this is the contract every probe and
# headless tool relies on).
#
# The SurfaceTool pipeline this replaces (begin/add_vertex/index/generate_
# normals/commit) could not be paused mid-build, so the same geometry is now
# accumulated directly into packed-array buffers. Welding is by exact vertex
# position (the same dedup SurfaceTool.index() performed - UVs here are derived
# purely from position, so equal positions always carry equal UVs) and smooth
# normals are accumulated per welded vertex from each touching face, matching
# generate_normals()'s indexed average. Output geometry is identical up to
# floating-point noise.
static func build_ground_visual_mesh(map_def: Dictionary, ticker: Node = null) -> Dictionary:
	var he: Vector2 = MapCatalogScript.half_extents(map_def)
	# v2 only: every shipped map was authored against the uniform grid, and
	# subdividing their terrain would change silhouettes they were balanced on.
	var adaptive_detail: bool = terrain_generator(map_def) == "v2"

	# Scale resolution dynamically with extent so large maps don't explode into millions of quads
	# 2026-08-26: per-axis step so a wide non-square map (1200x520) gets
	# a mesh_stride that's correct in BOTH directions - not the X
	# half-extent's stride on a 520m Z axis (would over-resolve) or the
	# Z half-extent's stride on a 1200m X axis (would under-resolve).
	var span: Vector2 = he * 2.0
	var mesh_step_x: float = maxf(GROUND_MESH_RESOLUTION, span.x / 280.0)
	var mesh_step_z: float = maxf(GROUND_MESH_RESOLUTION, span.y / 280.0)
	var col_step_x: float = maxf(COLLISION_HEIGHTMAP_STEP, span.x / 180.0)
	var col_step_z: float = maxf(COLLISION_HEIGHTMAP_STEP, span.y / 180.0)
	var mesh_step: float = mesh_step_x  # legacy single var for any caller that reads it
	var col_step: float = col_step_x

	var h_cache: Dictionary = {}
	var _h = func(hx: float, hz: float) -> float:
		var key = Vector2(round(hx * 4.0) / 4.0, round(hz * 4.0) / 4.0)
		if h_cache.has(key): return h_cache[key]
		var v = height_at(map_def, hx, hz)
		h_cache[key] = v
		return v

	# Accumulator state. The containers are reference types on purpose: the two
	# lambdas below mutate their CONTENTS (which propagates out of the capture)
	# but never reassign them (which would not).
	var weld: Dictionary = {}      # Vector3 position -> index into verts/uvs/nrm_acc
	var verts: Array = []
	var uvs: Array = []
	var nrm_acc: Array = []        # un-normalized normal sums per welded vertex
	var indices := PackedInt32Array()

	var _vert_id = func(v: Vector3) -> int:
		if weld.has(v):
			return weld[v]
		var id: int = verts.size()
		weld[v] = id
		verts.append(v)
		uvs.append(Vector2(v.x, v.z) / TERRAIN_TILE_WORLD_SIZE)
		nrm_acc.append(Vector3.ZERO)
		return id

	var _emit_quad = func(a: Vector3, b: Vector3, c: Vector3, d: Vector3) -> void:
		var ia: int = _vert_id.call(a)
		var ib: int = _vert_id.call(b)
		var ic: int = _vert_id.call(c)
		var idd: int = _vert_id.call(d)
		indices.append(ia)
		indices.append(ib)
		indices.append(ic)
		indices.append(ia)
		indices.append(ic)
		indices.append(idd)
		# THE GROUND FACES UP. Corners arrive as a(x,z) b(x1,z) c(x1,z1)
		# d(x,z1) with x1>x and z1>z, which is CLOCKWISE seen from above -
		# correct for Godot's front-face winding, but it means the right-hand
		# rule points the face normal DOWN. Both (b-a)x(c-a) and (b-a)x(d-a)
		# give -Y here; the operands have to be swapped, not relabelled.
		#
		# Measured with tools/probe_ground_material.gd, the whole ground mesh
		# had a mean normal of (0.000, -0.999, 0.000). Two consequences, and
		# the second is the one that hid the first:
		#   - the terrain caught no sun, so it rendered at value_floor.
		#   - the v2 shader derives slope as 1.0 - clamp(normal.y, 0, 1), which
		#     with y = -1 is slope 1.0 EVERYWHERE. Every pixel of every map was
		#     therefore drawn as full triplanar cliff rock under the biome
		#     cliff tint. The grass layer was never sampled at all.
		# So this reads as "the ground texture is dark mud" rather than as a
		# lighting fault, which is why it survived several passes over the
		# plates themselves.
		var n: Vector3 = (c - a).cross(b - a).normalized()
		nrm_acc[ia] += n
		nrm_acc[ib] += n
		nrm_acc[ic] += n
		nrm_acc[idd] += n

	# Frame-budget gate. Inlined at each chunk boundary rather than wrapped in a
	# helper because a helper containing await would itself be a coroutine.
	var deadline: int = Time.get_ticks_usec() + int(BUILD_FRAME_BUDGET_MS * 1000.0)

	# 1. Playable ground surface - one budget slice per x-row band
	# 2026-08-26: per-axis mesh_step so the Z walk stride scales with
	# the map's Z half-extent, not its X half-extent. A 1200x520 map
	# gets a ~4.3m Z stride instead of a 2.1m Z stride (which would
	# over-resolve Z by 2x).
	var x = -he.x
	while x < he.x:
		# Headless / probe callers (no SceneTree ticker): fall back to a
		# busy wait rather than a real await. See _build_conforming_zone_
		# mesh_stepwise (terrain_builder.gd:3843+) for the same fix.
		if Time.get_ticks_usec() >= deadline:
			if ticker == null:
				deadline = Time.get_ticks_usec() + int(BUILD_FRAME_BUDGET_MS * 1000.0)
			else:
				await ticker.get_tree().process_frame
				deadline = Time.get_ticks_usec() + int(BUILD_FRAME_BUDGET_MS * 1000.0)
		var x1 = min(x + mesh_step_x, he.x)
		var z = -he.y
		while z < he.y:
			var z1 = min(z + mesh_step_z, he.y)
			var a = Vector3(x, _h.call(x, z), z)
			var b = Vector3(x1, _h.call(x1, z), z)
			var c = Vector3(x1, _h.call(x1, z1), z1)
			var d = Vector3(x, _h.call(x, z1), z1)
			# ADAPTIVE SUBDIVISION. A quad whose corners disagree in height by
			# more than DETAIL_TRIGGER_RISE is re-emitted at finer resolution.
			#
			# Why this exists: mesh_step is (span / 280) - 6.86 m on a 1920 m
			# map - while a cliff wall is the feature's wall_falloff wide, 6-8 m.
			# That is ONE QUAD ACROSS, so a 22 m plateau wall had a vertex on
			# top and the next at the bottom and rendered as a smooth ramp. The
			# relief was correct in the heightmap and correct to pathfinding
			# (the navmesh samples corner deltas and marked it impassable) and
			# simply absent from the picture. That gap is also why the old
			# system stamped 1472 discrete cliff GLBs along the wall lines to
			# fake what the mesh could not draw.
			#
			# Cost is bounded by geometry: walls are LINES through the grid, so
			# only a few hundred of ~78k quads trigger, and each becomes
			# DETAIL_SUBDIV^2. Measured on sentinel_divide this is a low
			# single-digit percentage of extra triangles.
			var rise: float = maxf(maxf(absf(b.y - a.y), absf(d.y - a.y)),
				maxf(absf(c.y - b.y), absf(c.y - d.y)))
			if adaptive_detail and rise > DETAIL_TRIGGER_RISE:
				_emit_detailed_quad(_emit_quad, _h, x, x1, z, z1, DETAIL_SUBDIV)
			else:
				_emit_quad.call(a, b, c, d)
			z = z1
		x = x1

	# 2. Outer terrain skirt: extends outward to the horizon so map borders never expose empty void
	# Per-axis skirt distance too - the wider axis needs more skirt to hide its edge.
	var skirt_dist_x: float = maxf(he.x * 3.5, 450.0)
	var skirt_dist_z: float = maxf(he.y * 3.5, 450.0)
	var skirt_step_x: float = maxf(mesh_step_x * 3.0, 32.0)
	var skirt_step_z: float = maxf(mesh_step_z * 3.0, 32.0)
	var outer_min_x: float = -he.x - skirt_dist_x
	var outer_max_x: float = he.x + skirt_dist_x
	var outer_min_z: float = -he.y - skirt_dist_z
	var outer_max_z: float = he.y + skirt_dist_z

	# North, South, West, East perimeter skirt sections - budget-checked per
	# row band like the ground pass above (each full rect is cheap, but its
	# inner loops sample height along the whole perimeter).
	for rect_bounds in [[outer_min_x, outer_max_x, outer_min_z, -he.y],
			[outer_min_x, outer_max_x, he.y, outer_max_z],
			[outer_min_x, -he.x, -he.y, he.y],
			[he.x, outer_max_x, -he.y, he.y]]:
		var curr_x: float = rect_bounds[0]
		while curr_x < rect_bounds[1]:
			# Headless / probe callers (no SceneTree ticker): fall back to a
			# busy wait rather than a real await. See _build_conforming_zone_
			# mesh_stepwise (terrain_builder.gd:3843+) for the same fix.
			if Time.get_ticks_usec() >= deadline:
				if ticker == null:
					deadline = Time.get_ticks_usec() + int(BUILD_FRAME_BUDGET_MS * 1000.0)
				else:
					await ticker.get_tree().process_frame
					deadline = Time.get_ticks_usec() + int(BUILD_FRAME_BUDGET_MS * 1000.0)
			var next_x = min(curr_x + skirt_step_x, rect_bounds[1])
			var curr_z: float = rect_bounds[2]
			while curr_z < rect_bounds[3]:
				var next_z = min(curr_z + skirt_step_z, rect_bounds[3])
				var sa = Vector3(curr_x, _h.call(curr_x, curr_z), curr_z)
				var sb = Vector3(next_x, _h.call(next_x, curr_z), curr_z)
				var sc = Vector3(next_x, _h.call(next_x, next_z), next_z)
				var sd = Vector3(curr_x, _h.call(curr_x, next_z), next_z)
				_emit_quad.call(sa, sb, sc, sd)
				curr_z = next_z
			curr_x = next_x

	# Normalize the accumulated face normals into per-vertex smooth normals -
	# the same indexed average SurfaceTool.generate_normals() produced. A
	# degenerate (zero-area) corner normalizes to ZERO, which the shader treats
	# as up-facing; the old path never produced those on this grid anyway.
	# Chunked per vertex: on a 960-half map this loop plus the Array->Packed
	# conversions below touch ~150k vertices of Variant data, which was the
	# last remaining multi-hundred-ms gap in the phase.
	var mesh := ArrayMesh.new()
	if not indices.is_empty():
		var normals := PackedVector3Array()
		normals.resize(verts.size())
		var packed_verts := PackedVector3Array()
		packed_verts.resize(verts.size())
		var packed_uvs := PackedVector2Array()
		packed_uvs.resize(uvs.size())
		for i in range(verts.size()):
			normals[i] = (nrm_acc[i] as Vector3).normalized()
			packed_verts[i] = verts[i]
			packed_uvs[i] = uvs[i]
			# Headless / probe callers (no SceneTree ticker): fall back to a
			# busy wait rather than a real await. See _build_conforming_zone_
			# mesh_stepwise (terrain_builder.gd:3843+) for the same fix.
			if Time.get_ticks_usec() >= deadline:
				if ticker == null:
					deadline = Time.get_ticks_usec() + int(BUILD_FRAME_BUDGET_MS * 1000.0)
				else:
					await ticker.get_tree().process_frame
					deadline = Time.get_ticks_usec() + int(BUILD_FRAME_BUDGET_MS * 1000.0)
		var arrays := []
		arrays.resize(Mesh.ARRAY_MAX)
		arrays[Mesh.ARRAY_VERTEX] = packed_verts
		arrays[Mesh.ARRAY_TEX_UV] = packed_uvs
		arrays[Mesh.ARRAY_NORMAL] = normals
		arrays[Mesh.ARRAY_INDEX] = indices
		mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)

	# Collision heightmap - sampled per row so big maps also spread this across
	# frames instead of spending tens of thousands of height_at() calls in one.
	# 2026-08-26: per-axis sample count + stride so the collision heightmap
	# actually covers the full non-square map. HeightMapShape3D is
	# square, so a 1200x520 map gets a `samples_x` X `samples_z` shape
	# whose X and Z dimensions are independent (Godot's HeightMapShape3D
	# supports this - map_width and map_depth are separate fields).
	var samples_x = int(he.x * 2.0 / col_step_x) + 1
	var samples_z = int(he.y * 2.0 / col_step_z) + 1
	var height_data = PackedFloat32Array()
	height_data.resize(samples_x * samples_z)
	for row in range(samples_z):
		# Headless / probe callers (no SceneTree ticker): fall back to a
		# busy wait rather than a real await. See _build_conforming_zone_
		# mesh_stepwise (terrain_builder.gd:3843+) for the same fix.
		if Time.get_ticks_usec() >= deadline:
			if ticker == null:
				deadline = Time.get_ticks_usec() + int(BUILD_FRAME_BUDGET_MS * 1000.0)
			else:
				await ticker.get_tree().process_frame
				deadline = Time.get_ticks_usec() + int(BUILD_FRAME_BUDGET_MS * 1000.0)
		var wz = -he.y + row * col_step_z
		for col in range(samples_x):
			var wx = -he.x + col * col_step_x
			height_data[row * samples_x + col] = height_at(map_def, wx, wz)
	var shape = HeightMapShape3D.new()
	shape.map_width = samples_x
	shape.map_depth = samples_z
	shape.map_data = height_data

	return {"mesh": mesh, "shape": shape, "samples_x": samples_x, "samples_z": samples_z, "collision_scale": Vector3(col_step_x, 1.0, col_step_z)}


# A rectangular zone footprint as a real subdivided mesh whose every vertex
# samples height_at() - the same one source of truth build_ground_visual_mesh(),
# _slope_at() and every unit's Y-snap already agree on.
#
# WHY THIS EXISTS. Surface zones (marsh/rocky/sand/...) used to be a single
# un-subdivided PlaneMesh pinned at a FIXED y=0.03, which is correct only on
# genuinely flat ground. Once the map has real relief - ambient ground noise,
# and now authored hills/ravines - the ground mesh rises straight through the
# zone's flat plane and the surface texture reads as a sheet of paper laid over
# a lumpy floor, with the real ground poking out of it in patches. Raising
# GROUND_NOISE_AMPLITUDE makes that strictly worse, which is why this landed
# first.
#
# y_lift is a small constant offset ABOVE the sampled terrain height (not an
# absolute Y): the zone is a dressing layer drawn on top of the base ground, so
# it needs a consistent hair of clearance everywhere to avoid z-fighting,
# rather than a single altitude that's only right in one spot.
#
# UVs are baked from ABSOLUTE world position, matching
# build_ground_visual_mesh(), so adjacent zones and the base ground all share
# one continuous texture grid instead of each restarting its own 0..1 sweep at
# its own corner. Callers must therefore leave the material's uv1_scale at 1.
# Public entry point for any full-map overlay that has to lie ON the terrain
# rather than float above its highest point - the fog shroud is the first
# caller. resolution is exposed because a map-wide overlay cannot afford the
# ground mesh's own 3-unit grid (an 840 half-extent map would be ~1.8M verts of
# fog), and does not need it: it is following the same low-frequency relief the
# ground noise produces, not rendering detail.
static func build_conforming_overlay_mesh(map_def: Dictionary, half: float, y_lift: float, resolution: float) -> ArrayMesh:
	return _build_conforming_zone_mesh(map_def, Vector3.ZERO, Vector2(half, half), y_lift, 1.0, resolution)

static func _build_conforming_zone_mesh(map_def: Dictionary, center: Vector3, half_extents: Vector2, y_lift: float, tile_scale: float, resolution: float = GROUND_MESH_RESOLUTION) -> ArrayMesh:
	var h_cache: Dictionary = {}
	var _h = func(hx: float, hz: float) -> float:
		var key = Vector2(hx, hz)
		if h_cache.has(key): return h_cache[key]
		var v = height_at(map_def, hx, hz) + y_lift
		h_cache[key] = v
		return v

	var x0: float = center.x - half_extents.x
	var x_max: float = center.x + half_extents.x
	var z0: float = center.z - half_extents.y
	var z_max: float = center.z + half_extents.y
	var tile: float = TERRAIN_TILE_WORLD_SIZE * tile_scale

	var st = SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var x = x0
	while x < x_max:
		var x1 = min(x + resolution, x_max)
		var z = z0
		while z < z_max:
			var z1 = min(z + resolution, z_max)
			var a = Vector3(x, _h.call(x, z), z)
			var b = Vector3(x1, _h.call(x1, z), z)
			var c = Vector3(x1, _h.call(x1, z1), z1)
			var d = Vector3(x, _h.call(x, z1), z1)
			# Slope factor: steep slopes fade the zone out so the base ground
			# (which has triplanar rock on slopes) shows through. This creates
			# natural transitions — flat areas keep their surface type, slopes
			# erode to rock. Threshold 0.35 is gentle enough that walking-pace
			# hills keep their surface, while real escarpments lose it.
			var avg_y = (a.y + b.y + c.y + d.y) * 0.25
			var dx = abs(b.y - a.y) + abs(c.y - d.y)
			var dz = abs(d.y - a.y) + abs(c.y - b.y)
			var slope = sqrt(dx * dx + dz * dz) / (resolution * 2.0)
			var slope_factor = smoothstep(0.25, 0.55, 1.0 - slope)
			for v in [a, b, c, a, c, d]:
				st.set_uv(Vector2(v.x, v.z) / tile)
				var edge_alpha = _zone_edge_alpha(v, center, half_extents)
				st.set_color(Color(1, 1, 1, edge_alpha * slope_factor))
				st.add_vertex(v)
			z = z1
		x = x1
	st.generate_normals()
	return st.commit()

# Frame-chunked twin of _build_conforming_zone_mesh() for the LOAD path only.
# The sync original above stays single-frame on purpose: build_conforming_
# overlay_mesh() runs MID-MATCH (fog shroud rebuilds) where there is no load
# gate to spread work into. Only the loading screen's ticker reaches here.
# Geometry output is identical; only scheduling differs.
static func _build_conforming_zone_mesh_stepwise(map_def: Dictionary, center: Vector3, half_extents: Vector2, y_lift: float, tile_scale: float, resolution: float, ticker: Node) -> ArrayMesh:
	var h_cache: Dictionary = {}
	var _h = func(hx: float, hz: float) -> float:
		var key = Vector2(hx, hz)
		if h_cache.has(key): return h_cache[key]
		var v = height_at(map_def, hx, hz) + y_lift
		h_cache[key] = v
		return v

	var x0: float = center.x - half_extents.x
	var x_max: float = center.x + half_extents.x
	var z0: float = center.z - half_extents.y
	var z_max: float = center.z + half_extents.y
	var tile: float = TERRAIN_TILE_WORLD_SIZE * tile_scale

	var st = SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var deadline: int = Time.get_ticks_usec() + int(BUILD_FRAME_BUDGET_MS * 1000.0)
	var x = x0
	while x < x_max:
		if Time.get_ticks_usec() >= deadline:
			# Headless / probe callers (no SceneTree ticker): fall back to a
			# busy wait rather than a real await. The load path is the one
			# that calls this with a ticker, and the load path is a real
			# windowed run - so a headless probe that wanders in here would
			# otherwise hit the same null.get_tree() the chunked slope-rock
			# walker fixed (terrain_builder.gd:3176+).
			if ticker == null:
				deadline = Time.get_ticks_usec() + int(BUILD_FRAME_BUDGET_MS * 1000.0)
			else:
				await ticker.get_tree().process_frame
				deadline = Time.get_ticks_usec() + int(BUILD_FRAME_BUDGET_MS * 1000.0)
		var x1 = min(x + resolution, x_max)
		var z = z0
		while z < z_max:
			var z1 = min(z + resolution, z_max)
			var a = Vector3(x, _h.call(x, z), z)
			var b = Vector3(x1, _h.call(x1, z), z)
			var c = Vector3(x1, _h.call(x1, z1), z1)
			var d = Vector3(x, _h.call(x, z1), z1)
			var dx = abs(b.y - a.y) + abs(c.y - d.y)
			var dz = abs(d.y - a.y) + abs(c.y - b.y)
			var slope = sqrt(dx * dx + dz * dz) / (resolution * 2.0)
			var slope_factor = smoothstep(0.25, 0.55, 1.0 - slope)
			for v in [a, b, c, a, c, d]:
				st.set_uv(Vector2(v.x, v.z) / tile)
				var edge_alpha = _zone_edge_alpha(v, center, half_extents)
				st.set_color(Color(1, 1, 1, edge_alpha * slope_factor))
				st.add_vertex(v)
			z = z1
		x = x1
	st.generate_normals()
	return st.commit()

# Fraction of a zone's footprint, measured inward from each edge, over which it
# fades out. Playtest: "the separate terrain types need to blend better into
# each other." Each zone is its own opaque quad with a hard rectangular
# footprint, so two adjacent zones met at a visible straight seam and every zone
# met the base ground at one too - there was no blend mask, no vertex alpha, and
# no shared shader anywhere that could have produced a gradient.
#
# This is the cheap half of the fix: fade each zone's own alpha to 0 over its
# outer margin so it dissolves into whatever is beneath it, using the existing
# StandardMaterial3D rather than new shader infrastructure. It genuinely blends
# a zone into the BASE GROUND; where two zones overlap it blends them into each
# other only in the ordinary alpha-over sense, which softens the seam but is not
# a true splat. A real multi-texture blend shader is the correct long-term
# answer and is deliberately scoped as its own task - see the plan.
#
# Updated: zone edges also fade based on terrain slope (see conforming mesh
# builders). Steep slopes lose their surface zone to reveal the base ground's
# triplanar rock, creating natural erosion transitions.
const ZONE_EDGE_FADE_FRACTION: float = 0.25

static func _zone_edge_alpha(v: Vector3, center: Vector3, half_extents: Vector2) -> float:
	# Distance from this vertex to the nearest footprint edge, expressed as a
	# fraction of the fade margin on that axis, so a long thin zone fades over a
	# proportionate band on each axis rather than one absolute distance that
	# would swallow the short axis entirely.
	var fx: float = half_extents.x * ZONE_EDGE_FADE_FRACTION
	var fz: float = half_extents.y * ZONE_EDGE_FADE_FRACTION
	var tx: float = 1.0 if fx <= 0.0 else clampf((half_extents.x - absf(v.x - center.x)) / fx, 0.0, 1.0)
	var tz: float = 1.0 if fz <= 0.0 else clampf((half_extents.y - absf(v.z - center.z)) / fz, 0.0, 1.0)
	# smoothstep, not linear: a linear ramp has a visible crease where it meets
	# full opacity, which is the same hard-line artifact this is here to remove.
	return smoothstep(0.0, 1.0, minf(tx, tz))

# Clearance above the sampled terrain for each dressing layer. Ordered so the
# stack is unambiguous where they overlap: surface zone lowest, water above it,
# the shallow-water marker on top of the water it annotates. Same relative
# ordering the old fixed-Y constants (0.03/0.05/0.06) encoded, now expressed as
# offsets from real terrain rather than from absolute zero.
const ZONE_Y_LIFT: float = 0.03

static func _spawn_surface_zone(zone: Dictionary, parent: Node3D, prop_scale: float = 1.0, map_def: Dictionary = {}, ticker: Node = null):
	var footprint = Vector2(zone.half_extents.x * 2.0, zone.half_extents.y * 2.0)
	var surface_type = zone.get("surface_type", "")
	var mesh_inst = MeshInstance3D.new()
	var mat = _build_terrain_material(
		surface_type, footprint, Color.WHITE,
		_variant_for_position(surface_type, zone.center.x, zone.center.z), prop_scale)

	if map_def.is_empty():
		# No map_def (a direct caller in a test fixture, or a future call site
		# that hasn't threaded it through): fall back to the old flat plane
		# rather than to nothing, same degrade-gracefully contract the authored-
		# asset paths use.
		var plane = PlaneMesh.new()
		plane.size = footprint
		mesh_inst.mesh = plane
		mesh_inst.material_override = mat
		parent.add_child(mesh_inst)
		mesh_inst.global_position = Vector3(zone.center.x, ZONE_Y_LIFT, zone.center.z)
	else:
		# World-position UVs are baked into the mesh, so the footprint-relative
		# tiling _build_terrain_material() set up would double-apply.
		mat.uv1_scale = Vector3.ONE
		# The mesh carries a per-vertex edge-fade alpha (_zone_edge_alpha); none
		# of it does anything unless the material both reads vertex color and
		# has real alpha blending turned on.
		mat.vertex_color_use_as_albedo = true
		mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		# A transparent surface lying flat on opaque ground it barely clears
		# would otherwise flicker against it depth-sorted per-frame.
		mat.depth_draw_mode = BaseMaterial3D.DEPTH_DRAW_OPAQUE_ONLY
		mesh_inst.mesh = await _build_conforming_zone_mesh_stepwise(
			map_def, zone.center, zone.half_extents, ZONE_Y_LIFT, prop_scale, GROUND_MESH_RESOLUTION, ticker)
		mesh_inst.material_override = mat
		parent.add_child(mesh_inst)

	TerrainGreeblesScript.scatter(zone, parent, prop_scale, map_def)


# canyon_ford PR5 (2026-08-26): per-forest-zone StaticBody3D AABB that
# blocks the LOS raycast (vision_service.gd:770-784) without carving
# the navmesh. A tree's collision box would also work but trees are
# MultiMeshInstance3D (no collider today) and adding per-tree colliders
# for the ~1000 ambient trees is a per-frame cost the existing scatter
# budget doesn't tolerate. One AABB per forest zone = 1-2 colliders per
# map, regardless of tree count.
#
# Why a collision layer at all (instead of a sensor / Area3D): the
# vision raycast is a PhysicsRayQueryParameters3D against the world's
# physics layers, and the cheapest way to make it hit a forest is to
# put a real physics body in the world. The body's collision_mask is
# 0 (it doesn't query anything; the world's queries hit IT), and
# collision_layer = TERRAIN (1) is what the existing LOS raycast
# already masks (`mask = BattleLayers.TERRAIN | BattleLayers.BUILDINGS`,
# vision_service.gd:777). Navmesh is unaffected: the navmesh bake reads
# JSON (`_build_ground_faces` at line 843), not scene-tree colliders,
# and forest zones aren't in the obstacles[] / extra_holes arrays the
# bake consumes - so units walk through forests normally, but cannot
# see through them.
#
# Sized to the zone's half_extents and a constant FOREST_LOS_HEIGHT so
# the AABB reaches the height of a tree canopy, ~6m. A viewer at eye
# height (2m-ish, vision_service.gd:65-67 EYE_HEIGHT) inside or above
# the AABB still sees out the top; a viewer at eye height OUTSIDE the
# AABB cannot see in. That asymmetry is the "concealment" the flavor
# text claims.
const FOREST_LOS_HEIGHT: float = 6.0

static func _spawn_forest_zone_aabbs(map_def: Dictionary, parent: Node3D, prop_scale: float = 1.0) -> void:
	for z in map_def.get("surface_zones", []):
		if z.get("surface_type", "") != "forest":
			continue
		var area: Area3D = Area3D.new()
		area.collision_layer = 1 << 5  # Bit 5 (32): SMOKE / sensor occlusion layer, queried by vision LOS
		area.collision_mask = 0
		var shape: CollisionShape3D = CollisionShape3D.new()
		var box: BoxShape3D = BoxShape3D.new()
		# World-space size: zone's XZ footprint × FOREST_LOS_HEIGHT in Y.
		# The position is the zone's center, lifted so the box's bottom
		# sits at y=0 (ground level) and the top reaches FOREST_LOS_HEIGHT.
		var size: Vector3 = Vector3(z.half_extents.x * 2.0 * prop_scale, FOREST_LOS_HEIGHT * prop_scale, z.half_extents.y * 2.0 * prop_scale)
		box.size = size
		shape.shape = box
		area.add_child(shape)
		area.position = Vector3(z.center.x, FOREST_LOS_HEIGHT * prop_scale * 0.5, z.center.z)
		parent.add_child(area)

# A lighter, sandier-toned marker over the shallow sub-area of a water
# zone (drawn on top of the main water plane, slightly higher Y) - purely
# a visual cue that this patch is shallow-draught-only; the real
# passability distinction lives in the deep_water_map navmesh (see
# build_navmeshes()).
static func _spawn_shallow_water_marker(zone: Dictionary, parent: Node3D, prop_scale: float = 1.0, map_def: Dictionary = {}):
	var mesh_inst = MeshInstance3D.new()
	var plane = PlaneMesh.new()
	var footprint = Vector2(zone.half_extents.x * 2.0, zone.half_extents.y * 2.0)
	plane.size = footprint
	mesh_inst.mesh = plane
	var mat = _build_terrain_material("shallow_water", footprint, Color.WHITE, "", prop_scale)
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.albedo_color = Color(1, 1, 1, 0.8)
	mesh_inst.material_override = mat
	parent.add_child(mesh_inst)
	mesh_inst.global_position = Vector3(zone.center.x, 0.06, zone.center.z)

	TerrainGreeblesScript.scatter_shallow_water(zone, parent, prop_scale, map_def)

const WATER_SHADER = preload("res://shaders/water.gdshader")

# The water material, in one place. Three call sites built it inline with
# slightly different parameters, so a change to the water look had to be made
# three times and one of them was always missed.
static func _make_water_material() -> ShaderMaterial:
	var mat := ShaderMaterial.new()
	mat.shader = WATER_SHADER
	var tex_a = _get_terrain_textures("blue_water")
	mat.set_shader_parameter("normal_map_a", tex_a.normal)
	var tex_b = _get_terrain_textures("blue_water", "v1")
	mat.set_shader_parameter("normal_map_b", tex_b.normal if tex_b.normal else tex_a.normal)
	mat.set_shader_parameter("shallow_color", Color(0.12, 0.42, 0.65, 0.85))
	mat.set_shader_parameter("deep_color", Color(0.04, 0.15, 0.32, 0.95))
	return mat


# Painted bodies are INDEPENDENT of the table and of water_areas: a map can
# have all three. Added before the branch below because that branch returns
# early when the map has no water_areas, which is the common case for a v2 map
# and would otherwise skip painted water entirely.
static func _spawn_painted_water(map_def: Dictionary, parent: Node3D, map_id: String) -> void:
	if map_id == "":
		return
	var mesh := build_painted_water_mesh(map_def, map_id)
	if mesh == null:
		return
	var mi := MeshInstance3D.new()
	mi.mesh = mesh
	mi.name = "PaintedWater"
	mi.material_override = _make_water_material()
	parent.add_child(mi)


static func _spawn_merged_water(map_def: Dictionary, parent: Node3D, prop_scale: float = 1.0, map_id: String = "") -> void:
	_spawn_painted_water(map_def, parent, map_id)
	var water_areas = map_def.get("water_areas", [])
	var water_blobs = map_def.get("water_blobs", [])
	if water_areas.is_empty() and water_blobs.is_empty():
		if terrain_generator(map_def) == "v2" or map_def.has("water_level") or map_def.get("terrain", {}).has("sculpt_grid"):
			var he: Vector2 = MapCatalogScript.half_extents(map_def)
			var half_dim: float = maxf(he.x, he.y)
			var w_mesh := PlaneMesh.new()
			w_mesh.size = Vector2(half_dim * 2.5, half_dim * 2.5)
			var mesh_inst := MeshInstance3D.new()
			mesh_inst.mesh = w_mesh
			mesh_inst.name = "WaterTablePlane"
			
			mesh_inst.material_override = _make_water_material()
			mesh_inst.position = Vector3(0.0, water_level_of(map_def), 0.0)
			parent.add_child(mesh_inst)
		return

	var st = SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var vert_count = 0

	for w in water_areas:
		var c: Vector3 = w.center
		var h: Vector2 = w.half_extents
		var y = 0.05
		var v0 = Vector3(c.x - h.x, y, c.z - h.y)
		var v1 = Vector3(c.x + h.x, y, c.z - h.y)
		var v2 = Vector3(c.x + h.x, y, c.z + h.y)
		var v3 = Vector3(c.x - h.x, y, c.z + h.y)

		st.set_normal(Vector3.UP)
		st.set_uv(Vector2(v0.x, v0.z) / (TERRAIN_TILE_WORLD_SIZE * prop_scale))
		st.add_vertex(v0)
		st.set_uv(Vector2(v1.x, v1.z) / (TERRAIN_TILE_WORLD_SIZE * prop_scale))
		st.add_vertex(v1)
		st.set_uv(Vector2(v2.x, v2.z) / (TERRAIN_TILE_WORLD_SIZE * prop_scale))
		st.add_vertex(v2)

		st.set_uv(Vector2(v0.x, v0.z) / (TERRAIN_TILE_WORLD_SIZE * prop_scale))
		st.add_vertex(v0)
		st.set_uv(Vector2(v2.x, v2.z) / (TERRAIN_TILE_WORLD_SIZE * prop_scale))
		st.add_vertex(v2)
		st.set_uv(Vector2(v3.x, v3.z) / (TERRAIN_TILE_WORLD_SIZE * prop_scale))
		st.add_vertex(v3)
		vert_count += 6

		TerrainGreeblesScript.scatter_blue_water(w, parent, prop_scale)

	for blob in water_blobs:
		var verts = _water_blob_fan_verts(blob, 0.05)
		for v in verts:
			st.set_normal(Vector3.UP)
			st.set_uv(Vector2(v.x, v.z) / (TERRAIN_TILE_WORLD_SIZE * prop_scale))
			st.add_vertex(v)
			vert_count += 1

		TerrainGreeblesScript.scatter_blue_water({"center": blob.center, "half_extents": Vector2(blob.get("radius", 10.0), blob.get("radius", 10.0))}, parent, prop_scale)

	if vert_count > 0:
		st.generate_normals()
		st.generate_tangents()
		var mesh_inst = MeshInstance3D.new()
		mesh_inst.mesh = st.commit()
		mesh_inst.name = "MergedWaterVisuals"
		
		var mat = ShaderMaterial.new()
		mat.shader = WATER_SHADER
		var tex_a = _get_terrain_textures("blue_water")
		mat.set_shader_parameter("normal_map_a", tex_a.normal)
		var tex_b = _get_terrain_textures("blue_water", "v1")
		mat.set_shader_parameter("normal_map_b", tex_b.normal if tex_b.normal else tex_a.normal)
		mesh_inst.material_override = mat
		parent.add_child(mesh_inst)

# Ground level under an obstacle/prop, or 0 when no map_def was threaded
# through (direct callers in probes and test fixtures).
#
# Everything in the obstacle path used to assume the ground was at exactly
# y=0, which was very nearly true while ambient relief was 0.4 units. It is
# not true now: boulders hung in the air over a dip and sank into a rise, and
# their colliders with them. Grounding each footprint at its own centre keeps a
# cluster internally consistent (one rock pile, one plinth) rather than each
# rock independently chasing the surface and shearing the pile apart.
static func _obstacle_ground_y(map_def: Dictionary, x: float, z: float) -> float:
	if map_def.is_empty():
		return 0.0
	return terrain_height_at(map_def, Vector3(x, 0.0, z))

static func _spawn_obstacle(obstacle: Dictionary, parent: Node3D, map_def: Dictionary = {}):
	var obstacle_type = obstacle.get("type", "rock")
	var base_y = _obstacle_ground_y(map_def, obstacle.center.x, obstacle.center.z)
	var collider_height = 3.0
	if obstacle_type == "building":
		collider_height = _spawn_building_obstacle(obstacle, parent, base_y)
	elif obstacle_type == "fortification":
		collider_height = _spawn_fortification_obstacle(obstacle, parent, base_y)
	elif obstacle_type == "depot":
		collider_height = _spawn_depot_obstacle(obstacle, parent, base_y)
	elif obstacle_type == "relay":
		collider_height = _spawn_relay_obstacle(obstacle, parent, base_y)
	elif obstacle_type == "crater":
		collider_height = _spawn_crater_obstacle(obstacle, parent, base_y)
	else:
		collider_height = _spawn_rock_obstacle(obstacle, parent, base_y)

	var body = StaticBody3D.new()
	body.collision_layer = 1
	body.collision_mask = 0
	var shape = CollisionShape3D.new()
	var box_shape = BoxShape3D.new()
	box_shape.size = Vector3(obstacle.half_extents.x * 2.0, collider_height, obstacle.half_extents.y * 2.0)
	shape.shape = box_shape
	body.add_child(shape)
	parent.add_child(body)
	body.global_position = Vector3(obstacle.center.x, base_y + collider_height / 2.0, obstacle.center.z)

# --- Cliff mesh spawn (canyon_ford PR1, 2026-08-26) ---
#
# Hybrid heightmap+mesh terrain: heightmap handles ≤60° slopes, this is
# what handles the >60° vertical faces a heightmap cannot represent cleanly
# at world_scale=4 without quadratically-blowing Recast's voxel grid (see
# the 6-PR plan's PR2 for the resolution-bound reasoning). Each cliff is a
# StaticBody3D on BattleLayers.TERRAIN so the ground navmesh bake (Recast)
# reads it as an impassable hole, and vision_service._has_line_of_sight's
# raycast (TERRAIN | BUILDINGS, vision_service.gd:777) reads it as visual
# cover - same dual role `obstacles` play today.
#
# Schema: FIELD_SPEC.cliffs in map_catalog.gd - {center: Vector3,
# half_extents: Vector2, type: straight|corner_in|corner_out|end,
# cliff_height: number, rotation: number (rad), cliff_tint: Color}.
# `type` selects the .glb piece; `rotation` is around Y so a "straight"
# can face any cardinal direction; `cliff_tint` is an optional per-piece
# material override (a "Mars canyon" can push warmth, a "frozen fjord" can
# desaturate) - defaults to neutral white.
#
# Pool size: 4. All-or-nothing fallback to BoxMesh + cliff material,
# matching the boulder pool's "degrade to primitives, never a mix"
# contract (_spawn_authored_boulders's own header, line 2640-2661) so a
# fresh checkout before the Blender regen has run still ships a working
# map - the cliffs are boxes, but the layout, collision, and the cliff
# shader's triplanar rock look are all in place.
# GLB pool. The 4 face pieces are 8m long × 4m tall × 2m thick (origin at
# the bottom-center, same convention as the old `build_cliff_props.py`
# straight piece). The 3 corner pieces are L-shapes for convex corners
# (4m on each face). The 3 strata pieces are layered-look variants
# that read as a taller cliff with horizontal bedding. All authored in
# the same units, all share the same `cliff_rock_*` matte material.
#
# 2026-08-26 22:45 playtest: the prior pool `["straight", "corner_in",
# "corner_out", "end"]` referred to file names that the rebuild never
# produced on disk (the actual files are `cliff_face_X.glb` etc., as
# listed below). _spawn_cliff silently fell through to BoxMesh, so every
# cliff rendered as a 1m × 4m × 14m vertical pillar - "the slabs with
# rock stickers" the user saw. This pool matches the on-disk assets.
const CLIFF_MODEL_DIR := "res://assets/models/terrain/cliff_%s.glb"
const CLIFF_POOL_TYPES: Array = [
	"face_0", "face_1", "face_2", "face_3",
	"corner_0", "corner_1", "corner_2",
	"strata_0", "strata_1", "strata_2",
]
const CLIFF_FACE_TYPES: Array = ["face_0", "face_1", "face_2", "face_3"]
const CLIFF_CORNER_TYPES: Array = ["corner_0", "corner_1", "corner_2"]
const CLIFF_STRATA_TYPES: Array = ["strata_0", "strata_1", "strata_2"]
# Natural face-piece length. With CLIFF_PIECE_LENGTH = 4.0 the
# auto-emission packs two face pieces per "step", which gives a wall of
# 16m per step (overlapping into a continuous strip). For corners the
# natural footprint is a 4m × 4m L-shape, so a 4m step is correct.
const CLIFF_FACE_LENGTH: float = 8.0
const CLIFF_FALLBACK_HEIGHT: float = 4.0

static func _spawn_cliffs(map_def: Dictionary, parent: Node3D, prop_scale: float = 1.0) -> void:
	for c in map_def.get("cliffs", []):
		_spawn_cliff(c, parent, map_def)

static func _spawn_cliff(cliff: Dictionary, parent: Node3D, map_def: Dictionary = {}) -> void:
	var cliff_type: String = cliff.get("type", "face_0")
	if cliff_type not in CLIFF_POOL_TYPES:
		# Unknown type = treat as 'face_0' rather than refusing the map.
		# A validator's strict-fail (push_error in map_catalog.gd's loader)
		# already catches typos before we get here, so this is a second
		# line of defense for an in-test hand-built dict.
		push_warning("TerrainBuilder: unknown cliff type '%s' - falling back to 'face_0'" % cliff_type)
		cliff_type = "face_0"
	var height_scale: float = WorldScaleScript.for_map(map_def)
	var cliff_height: float = cliff.get("cliff_height", CLIFF_FALLBACK_HEIGHT) * height_scale
	# base_y is the SURROUNDING ground level (0 for a plateau cliff
	# that's INSIDE the plateau's heightmap, since the heightmap
	# there already returns wall_height). y_offset from the cliff
	# dict shifts the visual DOWN by that amount so a plateau cliff
	# sits with its bottom at the surrounding ground (0m) and its
	# top at wall_height (14m) - a proper wall, not the "opposite
	# of a ramp" the 2026-08-26 22:14 playtest saw.
	var base_y: float = _obstacle_ground_y(map_def, cliff.center.x, cliff.center.z)
	base_y += cliff.get("y_offset", 0.0)

	# 2026-08-26 22:45 playtest (cliff rework): the old code only loaded
	# the "straight" type from the pool, and "straight" was a file name
	# the rebuild never produced on disk, so EVERY cliff silently fell
	# through to a BoxMesh with a 1m × 4m × 14m footprint - a vertical
	# pillar. "Slabs with rock stickers" per the user.
	#
	# The new pool (`face_X`, `corner_X`, `strata_X`) all live on disk.
	# The visual logic per type:
	#   - face_X (4 variants): 8m long × 4m tall × 2m thick, Y-scaled to
	#     match the requested cliff_height (so a 14m plateau wall reads
	#     as 14m visually).
	#   - strata_X (3 variants): same 8m × 4m × 2m box but with layered
	#     silhouette detail. Y-scaled the same way.
	#   - corner_X (3 variants): 4m L-shape, no Y-scale (scaling would
	#     distort the L into a non-cornered box).
	#   - unknown: BoxMesh fallback with WALL-LIKE dimensions (4m wide
	#     along the cliff line, 1m thick, cliff_height tall) instead of
	#     the prior pillar dimensions. Reads as a continuous wall even
	#     without GLB geometry.
	var mesh_inst: MeshInstance3D = null
	var glb_path: String = CLIFF_MODEL_DIR % cliff_type
	if ResourceLoader.exists(glb_path):
		var packed: PackedScene = load(glb_path)
		if packed != null:
			var inst: Node = packed.instantiate()
			if inst != null:
				mesh_inst = MeshInstance3D.new()
				# Re-parent any mesh children onto a single MeshInstance3D
				# so material_override is one assignment, not a recursive
				# walk. A .glb authored as a Node3D containing a Mesh + a
				# collision body lands as one MeshInstance3D with the mesh.
				for child in inst.get_children():
					inst.remove_child(child)
					mesh_inst.add_child(child)
				inst.queue_free()
	if mesh_inst == null:
		mesh_inst = MeshInstance3D.new()
		var box: BoxMesh = BoxMesh.new()
		# Wall-like dimensions: the FIRST axis (X for "axis=z" sides,
		# Z for "axis=x" sides) is the wall's thickness (1m), the SECOND
		# axis is the wall's length along the cliff line (step). This
		# reads as a continuous wall instead of a row of pillars. The
		# cliff_height comes through as the box's Y (vertical).
		box.size = Vector3(cliff.half_extents.x * 2.0, cliff_height, cliff.half_extents.y * 2.0)
		mesh_inst.mesh = box

	# Y-scale the face/strata GLBs so a 14m plateau wall reads as 14m.
	# The X/Z scales stay at 1.0: the auto-emission authors straight
	# pieces at half_extents (step*0.5, 0.5) which is a different XZ
	# footprint than the GLB's canonical 8m × 2m, so rescaling XZ would
	# either oversize the collision or undersize the visual; leaving the
	# GLB at its authored 8m × 2m and accepting the slight XZ mismatch is
	# the trade-off for v1 (the cliff visual is wider than the collider,
	# but the slope-based navmesh carve at the cliff line keeps units
	# off the wall either way).
	if mesh_inst.mesh != null and not (mesh_inst.mesh is BoxMesh):
		if cliff_type in CLIFF_FACE_TYPES or cliff_type in CLIFF_STRATA_TYPES:
			mesh_inst.scale = Vector3(1.0, cliff_height / CLIFF_FALLBACK_HEIGHT, 1.0)

	# Material: cliff.gdshader with the rock triplanar texture set. The
	# triplanar_scale is world_scale-aware so a 4x map doesn't get
	# tile-stretched rocks (the same world-space-driven scale that
	# terrain_ground.gdshader's `map_half_extents` uniform already does
	# for the heightmap ground).
	#
	# 2026-08-26 22:14 playtest fix: previously only `triplanar_scale`
	# and `cliff_tint` were set; the shader's rock_albedo / rock_normal
	# / rock_rough samplers were uninitialized so the texture() calls
	# returned Godot's default white, and cliffs rendered as solid
	# white blocks (the "what are these white obelisks" complaint).
	# Load the same rocky_* textures build_ground_material() sets on
	# the heightmap ground, so a cliff mesh and a steep heightmap face
	# in the same map read as continuous rock instead of two materials.
	var mat: ShaderMaterial = ShaderMaterial.new()
	mat.shader = load("res://shaders/cliff.gdshader")
	mat.set_shader_parameter("triplanar_scale", 0.2 * height_scale)
	var cliff_rock_tex = _get_terrain_textures("rocky", "_v1")
	mat.set_shader_parameter("rock_albedo", cliff_rock_tex.albedo)
	mat.set_shader_parameter("rock_normal", cliff_rock_tex.normal)
	mat.set_shader_parameter("rock_rough", cliff_rock_tex.roughness)
	if cliff.has("cliff_tint"):
		mat.set_shader_parameter("cliff_tint", cliff.cliff_tint)
	mesh_inst.material_override = mat

	mesh_inst.position = Vector3(cliff.center.x, base_y, cliff.center.z)
	var rotation_y: float = cliff.get("rotation", 0.0)
	if rotation_y != 0.0:
		mesh_inst.rotation.y = rotation_y
	parent.add_child(mesh_inst)

	# Collision: StaticBody3D on BattleLayers.TERRAIN (bit 0 = 1), with
	# a BoxShape3D matching the cliff's bounding box. Mirrors the
	# _spawn_obstacle collision block (line 2553-2562). The box is sized
	# to half_extents × cliff_height, so the navmesh bake reads it as a
	# cliff_height-tall hole the player can't path through, and the LOS
	# raycast reads it as cover.
	#
	# `position`, not `global_position` - the body is added to `parent`
	# which sits at world origin in every real call site (Battle.tscn's
	# terrain root), so local == global. Using `position` here also
	# makes the spawn tree-independent, which the smoke test
	# (_test_cliff_spawn.gd) needs - `global_position` would assert
	# `is_inside_tree()` and the headless run would log a stack of
	# "Returning: Transform3D()" errors for no reason.
	var body: StaticBody3D = StaticBody3D.new()
	body.collision_layer = 1
	body.collision_mask = 0
	var shape: CollisionShape3D = CollisionShape3D.new()
	var box_shape: BoxShape3D = BoxShape3D.new()
	box_shape.size = Vector3(cliff.half_extents.x * 2.0, cliff_height, cliff.half_extents.y * 2.0)
	shape.shape = box_shape
	body.add_child(shape)
	body.position = Vector3(cliff.center.x, base_y + cliff_height / 2.0, cliff.center.z)
	if rotation_y != 0.0:
		body.rotation.y = rotation_y
	parent.add_child(body)


# --- Feature auto-emission --------------------------------------------------
#
# Convert a map's terrain.features[] into the lower-level map_def entries
# (cliffs[], water_blobs[]) so the existing spawn machinery handles the
# visuals, collision, navmesh, and LOS without per-type special cases.
# Idempotent: a second call with the same features[] sees the "auto"
# tag on the previously-emitted entries and skips them.
#
# EMISSION SUMMARY.
#   plateau   → 4 wall lines around the perimeter + 4 corner_out pieces,
#               one per convex corner of the AABB.
#   canyon    → 2 parallel wall lines along the centerline + 2 end pieces
#               at each terminus (4 total). The flat floor at -depth is
#               handled by _canyon_contribution in the heightmap; no
#               water_area is emitted unless `floor_surface: "water"` is
#               set on the feature.
#   ridge     → 2 parallel wall lines along the polyline (one per side),
#               + corner pieces at each polyline vertex. The polyline
#               turn angle drives corner_in vs corner_out per vertex.
#   lake      → one water_blob at center (so the existing water mesh,
#               amphibious navmesh region, and shoreline all light up).
#               No cliffs - it's water, not a wall.
#
# The "auto" tag is set on each emitted entry's `meta` set, NOT in the
# dict itself - map_def is a plain Dictionary and adding a key would
# show up in FIELD_SPEC validation. We use a parallel `auto_emitted`
# dict (keyed by feature index) so the sidecar state is invisible to
# the validator and to the test fixtures.
const _AUTO_FEATURE_EMITTED_KEY := "_auto_feature_emitted"


static func _resolve_features(map_def: Dictionary) -> void:
	var features_root: Dictionary = map_def.get("terrain", {})
	var features: Array = features_root.get("features", [])
	if features.is_empty():
		return
	# Idempotency: if spawn_visuals ran once and the resolver is being
	# called again (scene reload, test fixture), skip already-emitted
	# features. The "emitted" set lives on map_def itself; the keys are
	# the JSON-stable feature index. The set is re-initialised when the
	# features array is replaced (different map_def), but stable across
	# repeated calls on the same map_def.
	var emitted: Dictionary = map_def.get(_AUTO_FEATURE_EMITTED_KEY, {})
	var ensure_cliffs: Array = map_def.get("cliffs", [])
	var ensure_water: Array = map_def.get("water_blobs", [])
	var ensure_water_areas: Array = map_def.get("water_areas", [])
	for i in range(features.size()):
		if emitted.has(i):
			continue
		var feature: Dictionary = features[i]
		var ftype: String = feature.get("type", "")
		match ftype:
			"plateau":
				# Pass the whole features array so _plateau_cliffs can
				# skip cliff emission on sides where a ramp is anchored
				# (the "wrong side of the cliff" bug from the 2026-08-26
				# 22:45 playtest). The "open" sides are decided here at
				# feature-resolution time, not at spawn time, so the
				# cliffs[] entry is never even generated.
				ensure_cliffs.append_array(_plateau_cliffs(feature, features))
			"canyon":
				ensure_cliffs.append_array(_canyon_cliffs(feature))
			"ridge":
				ensure_cliffs.append_array(_ridge_cliffs(feature))
			"lake":
				ensure_water.append(_lake_water_blob(feature))
				# If the author asked for a water_area (rect water)
				# rather than a blob, emit that instead.
				if feature.get("floor_surface", "blob") == "water":
					ensure_water_areas.append(_lake_water_area(feature))
		emitted[i] = true
	map_def["cliffs"] = ensure_cliffs
	map_def["water_blobs"] = ensure_water
	map_def["water_areas"] = ensure_water_areas
	map_def[_AUTO_FEATURE_EMITTED_KEY] = emitted


# Helper: place cliff pieces around the 4 sides of a plateau's perimeter.
# Each side gets straight pieces at intervals matching CLIFF_PIECE_LENGTH,
# with corner_out pieces at the 4 convex corners. The piece is oriented so
# the wall face points OUT (away from the plateau), which is the same
# convention the hand-authored cliffs[] use.
const CLIFF_PIECE_LENGTH := 4.0


static func _plateau_cliffs(feature: Dictionary, features_array: Array = []) -> Array:
	var c: Vector3 = _vec3_of(feature.get("center", Vector3.ZERO))
	# half_extents may be authored as a JSON Array ([x, z]) or as a
	# Vector2 - the FIELD_SPEC for features[] is unvalidated, so the
	# decoder doesn't normalize the shape. _vec_of accepts both.
	var he: Vector2 = _vec_of(feature.get("half_extents", Vector2(10, 10)))
	var hx: float = feature.get("half_extents_x", he.x)
	var hz: float = feature.get("half_extents_z", he.y)
	var wall_height: float = feature.get("wall_height", feature.get("height", 8.0))
	if hx < CLIFF_PIECE_LENGTH * 0.5 or hz < CLIFF_PIECE_LENGTH * 0.5:
		# Plateau too small for a 4-piece wall - skip the auto-emission.
		# The user can still hand-author cliffs[] for tiny plateaus.
		return []
	var cliffs: Array = []
	# 2026-08-26 22:45 playtest: a ramp's anchor sits at the plateau
	# edge, with direction_deg pointing OUTWARD (into the surrounding
	# ground). For a ramp to be a legal ascent, the cliff emission on
	# that edge must be skipped - otherwise the player walks up the
	# ramp and hits a cliff face ("the ramps are on the wrong side of
	# the cliff"). For each ramp in the same map, compute which side
	# of THIS plateau it sits on and mark that side as "open".
	#
	# Geometry: a ramp anchor is at the plateau edge. If its X coord is
	# within (cx-hx, cx+hx) and its Z coord is within (cz-hz, cz+hz),
	# the ramp's anchor is on the plateau's perimeter. Then we decide
	# which side by checking how close the anchor is to each edge.
	# A 2-metre slack is enough to absorb heightmap falloff at the
	# plateau's wall_falloff band.
	var open_sides := {"east": false, "west": false, "south": false, "north": false}
	var open_corners := {}  # corner index -> true if a ramp is at that corner
	for f in features_array:
		if f.get("type", "") != "ramp":
			continue
		var ramp_anchor: Vector3 = _vec3_of(f.get("anchor", Vector3.ZERO))
		var ramp_width: float = float(f.get("width", 16.0))
		# The anchor is the inner end of the ramp - it sits ON the
		# plateau edge. Allow some slack because the heightmap falloff
		# zone smooths the edge.
		var slack: float = max(2.0, ramp_width * 0.5)
		var dx: float = ramp_anchor.x - c.x
		var dz: float = ramp_anchor.z - c.z
		var on_east: bool = abs(dx - hx) < slack and abs(dz) <= hz
		var on_west: bool = abs(dx + hx) < slack and abs(dz) <= hz
		var on_south: bool = abs(dz - hz) < slack and abs(dx) <= hx
		var on_north: bool = abs(dz + hz) < slack and abs(dx) <= hx
		if on_east: open_sides["east"] = true
		if on_west: open_sides["west"] = true
		if on_south: open_sides["south"] = true
		if on_north: open_sides["north"] = true
		# Corner: the anchor is on two adjacent edges at once.
		if on_east and on_south: open_corners[0] = true
		if on_east and on_north: open_corners[1] = true
		if on_west and on_south: open_corners[2] = true
		if on_west and on_north: open_corners[3] = true
	# The 4 sides in order: +X (east), -X (west), +Z (south), -Z (north).
	# For each side, the side length is 2*h_dim where h_dim is the
	# perpendicular half_extent. Place straight pieces along it, and
	# corner pieces at the 2 ends.
	var sides := [
		{"axis": "z", "sign": 1, "x_offset": hx, "z_extent": hz, "rotation": 0.0, "open_key": "east"},
		{"axis": "z", "sign": -1, "x_offset": -hx, "z_extent": hz, "rotation": PI, "open_key": "west"},
		{"axis": "x", "sign": 1, "z_offset": hz, "x_extent": hx, "rotation": -PI * 0.5, "open_key": "south"},
		{"axis": "x", "sign": -1, "z_offset": -hz, "x_extent": hx, "rotation": PI * 0.5, "open_key": "north"},
	]
	# Deterministic per-side face variant. Same plateau, same map load
	# -> same face variant per side. Different plateaus in the same map
	# still vary (each side uses the side index as the offset, so all
	# east sides are the same face but east and west differ).
	var side_seed: int = int(c.x * 0.1) + int(c.z * 0.07) & 0xFFFF
	for side_idx in range(sides.size()):
		var side: Dictionary = sides[side_idx]
		if open_sides.get(side.get("open_key", ""), false):
			# A ramp opens this side - skip the wall emission.
			# The ramp is the transition from ground to plateau top.
			continue
		var along_extent: float = side.get("z_extent", side.get("x_extent", 0.0))
		# Face pieces are 8m long; pack them along the side at 8m
		# spacing. End-pieces overlap into the corner zone which the
		# corner emission covers.
		var n_pieces: int = max(1, int(round(along_extent * 2.0 / CLIFF_FACE_LENGTH)))
		var step: float = (along_extent * 2.0) / n_pieces
		# Pick a face variant for this side. Use side index as offset
		# so adjacent sides pick different variants.
		var face_variant: int = (side_seed + side_idx) % CLIFF_FACE_TYPES.size()
		var face_type: String = CLIFF_FACE_TYPES[face_variant]
		for j in range(n_pieces):
			var along := -along_extent + step * (j + 0.5)
			var center: Vector3
			if side.axis == "z":
				center = Vector3(c.x + side.x_offset, c.y, c.z + along)
			else:
				center = Vector3(c.x + along, c.y, c.z + side.z_offset)
			# Box fallback dimensions (only used if the GLB fails to
			# load) are wall-like: 1m thick × step long × cliff_height.
			# When the face_X GLB DOES load, it has its own 8m × 2m
			# footprint and these half_extents are ignored (the
			# collision uses them, the visual uses the GLB).
			var half_extents: Vector2
			if side.axis == "z":
				half_extents = Vector2(1.0, step * 0.5)
			else:
				half_extents = Vector2(step * 0.5, 1.0)
			cliffs.append({
				"center": center,
				"half_extents": half_extents,
				"type": face_type,
				"cliff_height": wall_height,
				"rotation": side.rotation,
				# 2026-08-26 22:14 playtest fix: _spawn_cliff positions
				# the visual at base_y = _obstacle_ground_y(x, z). For
				# an auto-emitted plateau cliff that's INSIDE the
				# plateau's heightmap contribution, the heightmap at
				# the cliff line is already wall_height (e.g. 14m), so
				# the visual sits at 14m and extends UP to 28m - "the
				# opposite of a ramp" (per user). The wall has to sit
				# at the SURROUNDING ground (0m) and extend UP to
				# wall_height so the visual is a 14m wall from y=0 to
				# y=14, not from y=14 to y=28. y_offset = -wall_height
				# achieves that without breaking the rest of
				# _spawn_cliff (obstacles, hand-authored cliffs, etc.
				# all use base_y as-is).
				"y_offset": -wall_height,
			})
	# 4 corner pieces at the convex corners. Use a corner_X variant
	# (L-shape, 4m on each face). Skip the corner if a ramp is
	# anchored there - the ramp IS the corner transition.
	var corner_positions := [
		Vector3(c.x + hx, c.y, c.z + hz),
		Vector3(c.x + hx, c.y, c.z - hz),
		Vector3(c.x - hx, c.y, c.z + hz),
		Vector3(c.x - hx, c.y, c.z - hz),
	]
	var corner_rotations := [0.0, -PI * 0.5, PI * 0.5, PI]
	for k in range(4):
		if open_corners.get(k, false):
			# Ramp at this corner - no need for a corner cliff.
			continue
		var corner_variant: int = (side_seed + k) % CLIFF_CORNER_TYPES.size()
		cliffs.append({
			"center": corner_positions[k],
			"half_extents": Vector2(2.0, 2.0),
			"type": CLIFF_CORNER_TYPES[corner_variant],
			"cliff_height": wall_height,
			"rotation": corner_rotations[k],
			# Same y_offset as the straight pieces - see comment above.
			"y_offset": -wall_height,
		})
	return cliffs


# Two parallel wall lines + 2 end pieces at each terminus of a canyon.
# The floor between the walls is a flat strip at -depth (heightmap only,
# no extra geometry); `floor_surface: "water"` on the feature adds a
# water_area along the floor.
static func _canyon_cliffs(feature: Dictionary) -> Array:
	var start: Vector3 = _vec3_of(feature.get("start", Vector3.ZERO))
	var end: Vector3 = _vec3_of(feature.get("end", Vector3.ZERO))
	var width: float = feature.get("width", 12.0)
	var depth: float = feature.get("depth", 12.0)
	var axis := end - start
	var axis_len := axis.length()
	if axis_len < CLIFF_PIECE_LENGTH:
		return []
	var axis_dir := axis / axis_len
	# Perpendicular (left of the axis as you walk start -> end).
	var perp: Vector2 = Vector2(-axis_dir.z, axis_dir.x)
	var floor_half := width * 0.5
	var cliffs: Array = []
	for side_sign in [-1.0, 1.0]:
		var side_dir: Vector2 = perp * (side_sign * floor_half)
		var along_pieces: int = max(1, int(round(axis_len / CLIFF_PIECE_LENGTH)))
		var step: float = axis_len / along_pieces
		for j in range(along_pieces):
			var along: float = step * (j + 0.5)
			var world_pos: Vector2 = Vector2(start.x, start.z) + Vector2(axis_dir.x, axis_dir.z) * along + side_dir
			var center := Vector3(world_pos.x, start.y, world_pos.y)
			# Wall piece faces perpendicular to axis. cliff.rotation y =
			# atan2(perp.x, perp.y) in the XZ plane, but Godot's atan2
			# gives the angle from +X; we want the wall face aligned with
			# the perpendicular. The sign of side_dir picks the orientation.
			var rot: float = atan2(axis_dir.x, axis_dir.z) + (PI * 0.5 if side_sign > 0 else -PI * 0.5)
			cliffs.append({
				"center": center,
				"half_extents": Vector2(0.5, step * 0.5),
				"type": "straight",
				"cliff_height": depth,
				"rotation": rot,
			})
	# End pieces at the start and end of each wall.
	for end_pos in [Vector2(start.x, start.z), Vector2(end.x, end.z)]:
		for side_sign in [-1.0, 1.0]:
			var side_dir: Vector2 = perp * (side_sign * floor_half)
			var center2 := Vector3(end_pos.x + side_dir.x, start.y, end_pos.y + side_dir.y)
			var rot: float = atan2(perp.x, perp.y)
			cliffs.append({
				"center": center2,
				"half_extents": Vector2(1.0, 1.0),
				"type": "end",
				"cliff_height": depth,
				"rotation": rot,
			})
	return cliffs


# Walk both sides of the polyline, emit straight pieces; at each vertex
# emit a corner piece. The corner type (in vs out) depends on whether the
# polyline turns left or right at that vertex. Convex turns read as
# corner_out, concave as corner_in.
static func _ridge_cliffs(feature: Dictionary) -> Array:
	var pts = feature.get("points", [])
	if pts.size() < 2:
		return []
	var width: float = feature.get("width", 6.0)
	var height: float = feature.get("height", 10.0)
	var cliffs: Array = []
	for i in range(pts.size() - 1):
		var a: Vector2 = _vec_of(pts[i])
		var b: Vector2 = _vec_of(pts[i + 1])
		var seg: Vector2 = b - a
		var seg_len: float = seg.length()
		if seg_len < CLIFF_PIECE_LENGTH * 0.5:
			continue
		var seg_dir := seg / seg_len
		var perp: Vector2 = Vector2(-seg_dir.y, seg_dir.x)
		for side_sign in [-1.0, 1.0]:
			var side_dir: Vector2 = perp * (side_sign * width)
			var n_pieces: int = max(1, int(round(seg_len / CLIFF_PIECE_LENGTH)))
			var step: float = seg_len / n_pieces
			for j in range(n_pieces):
				var along: float = step * (j + 0.5)
				var world_pos: Vector2 = a + seg_dir * along + side_dir
				var rot: float = atan2(seg_dir.x, seg_dir.y) + (PI * 0.5 if side_sign > 0 else -PI * 0.5)
				cliffs.append({
					"center": Vector3(world_pos.x, 0.0, world_pos.y),
					"half_extents": Vector2(0.5, step * 0.5),
					"type": "straight",
					"cliff_height": height,
					"rotation": rot,
				})
		# Corner at the END of this segment (the START vertex is owned by
		# the previous iteration, except for the first segment which gets
		# the corner at the start vertex as well so the first wall has a
		# proper end-cap).
		if i == 0:
			cliffs.append_array(_ridge_end_corners(a, perp, width, height))
		# At the end of this segment, the next segment takes over - emit
		# the corner pieces at the join here based on the turn direction.
		if i + 1 < pts.size() - 1:
			var c_pt := _vec_of(pts[i + 1])
			var next_seg := _vec_of(pts[i + 2]) - c_pt
			var turn := _ridge_turn(seg, next_seg)
			cliffs.append_array(_ridge_turn_corners(c_pt, perp, next_seg.normalized(), width, height, turn))
		else:
			# Last segment's end vertex - emit end-cap.
			cliffs.append_array(_ridge_end_corners(b, perp, width, height))
	return cliffs


static func _ridge_turn(seg: Vector2, next_seg: Vector2) -> float:
	# Cross product gives the sign of the turn (positive = left, negative = right).
	return seg.x * next_seg.y - seg.y * next_seg.x


static func _ridge_turn_corners(vertex: Vector2, perp: Vector2, next_dir: Vector2, width: float, height: float, turn: float) -> Array:
	var corner_type: String = "corner_out" if turn > 0.0 else "corner_in"
	var rot: float = atan2(perp.x, perp.y)
	# Two corner pieces - one on each side of the polyline - so both walls
	# meet the turn cleanly.
	return [
		{
			"center": Vector3(vertex.x + perp.x * width, 0.0, vertex.y + perp.y * width),
			"half_extents": Vector2(1.0, 1.0),
			"type": corner_type,
			"cliff_height": height,
			"rotation": rot,
		},
		{
			"center": Vector3(vertex.x - perp.x * width, 0.0, vertex.y - perp.y * width),
			"half_extents": Vector2(1.0, 1.0),
			"type": corner_type,
			"cliff_height": height,
			"rotation": rot + PI,
		},
	]


static func _ridge_end_corners(vertex: Vector2, perp: Vector2, width: float, height: float) -> Array:
	# End-cap at a polyline terminus: a single end piece on each side, no
	# corner piece (the polyline ends, so there's no "outside corner" to
	# resolve). The end piece's own footprint is 2x2 so it sits at the tip.
	var rot: float = atan2(perp.x, perp.y)
	return [
		{
			"center": Vector3(vertex.x + perp.x * width, 0.0, vertex.y + perp.y * width),
			"half_extents": Vector2(1.0, 1.0),
			"type": "end",
			"cliff_height": height,
			"rotation": rot,
		},
		{
			"center": Vector3(vertex.x - perp.x * width, 0.0, vertex.y - perp.y * width),
			"half_extents": Vector2(1.0, 1.0),
			"type": "end",
			"cliff_height": height,
			"rotation": rot + PI,
		},
	]


static func _lake_water_blob(feature: Dictionary) -> Dictionary:
	var c: Vector3 = _vec3_of(feature.get("center", Vector3.ZERO))
	var radius: float = feature.get("radius", 12.0)
	var depth: float = feature.get("depth", 3.0)
	# Map the feature's `shoreline_falloff` to the water_blob's
	# `shore_blend` (the existing water_blob convention) so the shoreline
	# reads the same.
	var shore_blend: float = feature.get("shoreline_falloff", 4.0) / max(radius, 1.0)
	return {
		"center": c,
		"radius": radius,
		"depth": depth,
		"irregularity": 0.0,  # authored lakes are circles, not organic blobs
		"shore_blend": shore_blend,
	}


static func _lake_water_area(feature: Dictionary) -> Dictionary:
	# Rect-water variant of a lake. Used when the author sets
	# `floor_surface: "water"` on a canyon. The center is the feature
	# center; the rect spans the requested area.
	var c: Vector3 = _vec3_of(feature.get("center", Vector3.ZERO))
	var radius: float = feature.get("radius", 12.0)
	return {
		"center": c,
		"half_extents": Vector2(radius, radius),
	}


static func _spawn_fortification_obstacle(obstacle: Dictionary, parent: Node3D, base_y: float = 0.0) -> float:
	var h: float = obstacle.get("building_height", 3.2)
	var mesh_inst = MeshInstance3D.new()
	var box = BoxMesh.new()
	box.size = Vector3(obstacle.half_extents.x * 1.8, h, obstacle.half_extents.y * 1.8)
	mesh_inst.mesh = box
	var mat = StandardMaterial3D.new()
	mat.albedo_color = Color(0.28, 0.29, 0.28)
	mat.roughness = 0.92
	mesh_inst.material_override = mat
	mesh_inst.position = Vector3(obstacle.center.x, base_y + h / 2.0, obstacle.center.z)
	parent.add_child(mesh_inst)
	return h

static func _spawn_depot_obstacle(obstacle: Dictionary, parent: Node3D, base_y: float = 0.0) -> float:
	var h: float = 2.4
	var mesh_inst = MeshInstance3D.new()
	var box = BoxMesh.new()
	box.size = Vector3(obstacle.half_extents.x * 2.0, 0.4, obstacle.half_extents.y * 2.0)
	mesh_inst.mesh = box
	var mat = StandardMaterial3D.new()
	mat.albedo_color = Color(0.32, 0.31, 0.29)
	mat.roughness = 0.88
	mesh_inst.material_override = mat
	mesh_inst.position = Vector3(obstacle.center.x, base_y + 0.2, obstacle.center.z)
	parent.add_child(mesh_inst)

	# Fuel drums on slab
	for ox in [-obstacle.half_extents.x * 0.4, obstacle.half_extents.x * 0.4]:
		var tank_inst = MeshInstance3D.new()
		var cyl = CylinderMesh.new()
		cyl.top_radius = 1.0
		cyl.bottom_radius = 1.0
		cyl.height = 2.0
		tank_inst.mesh = cyl
		var tank_mat = StandardMaterial3D.new()
		tank_mat.albedo_color = Color(0.22, 0.26, 0.28)
		tank_mat.roughness = 0.65
		tank_inst.material_override = tank_mat
		tank_inst.position = Vector3(obstacle.center.x + ox, base_y + 1.2, obstacle.center.z)
		parent.add_child(tank_inst)
	return h

static func _spawn_relay_obstacle(obstacle: Dictionary, parent: Node3D, base_y: float = 0.0) -> float:
	var h: float = 5.0
	var mesh_inst = MeshInstance3D.new()
	var cyl = CylinderMesh.new()
	cyl.top_radius = 0.8
	cyl.bottom_radius = 1.4
	cyl.height = h
	mesh_inst.mesh = cyl
	var mat = StandardMaterial3D.new()
	mat.albedo_color = Color(0.35, 0.36, 0.38)
	mat.roughness = 0.7
	mesh_inst.material_override = mat
	mesh_inst.position = Vector3(obstacle.center.x, base_y + h / 2.0, obstacle.center.z)
	parent.add_child(mesh_inst)
	return h

static func _spawn_crater_obstacle(obstacle: Dictionary, parent: Node3D, base_y: float = 0.0) -> float:
	var h: float = 1.8
	var mesh_inst = MeshInstance3D.new()
	var cyl = CylinderMesh.new()
	cyl.top_radius = maxf(obstacle.half_extents.x, obstacle.half_extents.y) * 0.9
	cyl.bottom_radius = maxf(obstacle.half_extents.x, obstacle.half_extents.y) * 1.1
	cyl.height = h
	mesh_inst.mesh = cyl
	var mat = StandardMaterial3D.new()
	mat.albedo_color = Color(0.15, 0.14, 0.13)
	mat.roughness = 0.95
	mesh_inst.material_override = mat
	mesh_inst.position = Vector3(obstacle.center.x, base_y + h / 2.0, obstacle.center.z)
	parent.add_child(mesh_inst)
	return h

# Authored boulders now exist (tools/blender/build_terrain_props.py) - a
# rock cluster prefers a pool of 4 real boulder_N.glb variants, picked
# deterministically from the obstacle's own position so a given map's
# obstacles still look the same run to run. Falls back to the original
# box-primitive jumble below if the authored assets are missing (a fresh
# checkout before the Blender build has run, or an art pipeline hiccup) -
# same "degrade to boxes rather than to nothing" contract as
# building_mesh.gd's own build().
# 6, not 4: the pool now covers three distinct silhouette families (weathered,
# slab, shelf), two variants each - see build_meshes.py's BOULDER_STYLES, which
# this MUST stay in step with. A pool size larger than what Blender actually
# exports rolls indices at .glb files that do not exist and drops silently to
# the primitive fallback, which is the exact failure AUTHORED_POOL_SIZES in
# 35 high-fidelity geological rock models (7 formations x 5 variants)
const BOULDER_POOL_SIZE := 35
const BOULDER_MODEL_DIR := "res://assets/models/terrain/boulder_%d.glb"

# Checked ONCE, before adding anything - the whole pool is generated in a
# single Blender batch (tools/blender/build_terrain_props.py), so "some but
# not all of boulder_0..3.glb exist" isn't a real state worth handling. This
# keeps the fallback all-or-nothing too: either every rock in a cluster is
# authored art, or every rock is the box-primitive placeholder, never a mix.
static func _spawn_authored_boulders(obstacle: Dictionary, parent: Node3D, rng: RandomNumberGenerator, base_y: float = 0.0) -> bool:
	if not ResourceLoader.exists(BOULDER_MODEL_DIR % 0):
		return false
	for i in range(4):
		var idx: int = rng.randi() % BOULDER_POOL_SIZE
		var packed := load(BOULDER_MODEL_DIR % idx) as PackedScene
		if packed == null:
			continue
		var inst := packed.instantiate() as Node3D
		if inst == null:
			continue
		var scale_factor := rng.randf_range(0.8, 1.4)
		inst.scale = Vector3.ONE * scale_factor
		var ox = rng.randf_range(-obstacle.half_extents.x * 0.7, obstacle.half_extents.x * 0.7)
		var oz = rng.randf_range(-obstacle.half_extents.y * 0.7, obstacle.half_extents.y * 0.7)
		inst.position = Vector3(obstacle.center.x + ox, base_y, obstacle.center.z + oz)
		inst.rotation.y = rng.randf_range(0, TAU)
		parent.add_child(inst)
	return true

# A rough rock cluster filling the footprint - primitive meshes, the
# fallback when the authored boulder pool above is unavailable (avoids the
# fragile import pipeline entirely breaking obstacle visuals). Seeded from
# position so a given map's obstacles still look the same run to run
# (deterministic for screenshot verification). Returns the collider height
# _spawn_obstacle() should use for this obstacle.
static func _spawn_rock_obstacle(obstacle: Dictionary, parent: Node3D, base_y: float = 0.0) -> float:
	var rng = RandomNumberGenerator.new()
	rng.seed = hash(obstacle.center)
	if _spawn_authored_boulders(obstacle, parent, rng, base_y):
		return 3.0
	for i in range(5):
		var rock = MeshInstance3D.new()
		var box = BoxMesh.new()
		var size = Vector3(rng.randf_range(1.2, 2.4), rng.randf_range(1.0, 2.2), rng.randf_range(1.2, 2.4))
		box.size = size
		rock.mesh = box
		var mat = StandardMaterial3D.new()
		var shade = rng.randf_range(0.35, 0.5)
		mat.albedo_color = Color(shade, shade * 0.95, shade * 0.9)
		mat.roughness = 0.95
		rock.material_override = mat
		parent.add_child(rock)
		var ox = rng.randf_range(-obstacle.half_extents.x * 0.7, obstacle.half_extents.x * 0.7)
		var oz = rng.randf_range(-obstacle.half_extents.y * 0.7, obstacle.half_extents.y * 0.7)
		rock.global_position = Vector3(obstacle.center.x + ox, base_y + size.y / 2.0, obstacle.center.z + oz)
		rock.rotation.y = rng.randf_range(0, TAU)
	return 3.0

# A single boxy building filling the footprint - flat walls, a flat roof
# cap, and a few window-slit/AC-unit greebles, deliberately a different
# silhouette from the rock cluster's jumble of boulders (a single solid
# structure, not a pile of debris) since it's meant to read as real urban
# cover, not decoration. Taller than a rock cluster by default (real
# buildings are taller than a rock pile, and a taller collider makes the
# vision/weapon LOS-blocking this enables much more visually legible).
static func _spawn_building_obstacle(obstacle: Dictionary, parent: Node3D, base_y: float = 0.0) -> float:
	var rng = RandomNumberGenerator.new()
	rng.seed = hash(obstacle.center)
	var height = obstacle.get("building_height", rng.randf_range(5.0, 8.0))

	var walls = MeshInstance3D.new()
	var box = BoxMesh.new()
	box.size = Vector3(obstacle.half_extents.x * 2.0, height, obstacle.half_extents.y * 2.0)
	walls.mesh = box
	var mat = StandardMaterial3D.new()
	var shade = rng.randf_range(0.32, 0.42)
	mat.albedo_color = Color(shade * 0.9, shade * 0.92, shade)
	mat.roughness = 0.8
	walls.material_override = mat
	parent.add_child(walls)
	walls.global_position = Vector3(obstacle.center.x, base_y + height / 2.0, obstacle.center.z)

	var roof = MeshInstance3D.new()
	var roof_box = BoxMesh.new()
	roof_box.size = Vector3(obstacle.half_extents.x * 2.05, 0.3, obstacle.half_extents.y * 2.05)
	roof.mesh = roof_box
	var roof_mat = StandardMaterial3D.new()
	roof_mat.albedo_color = Color(0.25, 0.24, 0.24)
	roof_mat.roughness = 0.9
	roof.material_override = roof_mat
	parent.add_child(roof)
	roof.global_position = Vector3(obstacle.center.x, base_y + height + 0.15, obstacle.center.z)
	return height

# A raised deck spanning the bridge's full footprint (real geometry, not
# just a color patch - it's the visual proof the navmesh carve-out actually
# corresponds to a walkable structure).
static func _spawn_bridge(bridge: Dictionary, parent: Node3D):
	var c: Vector3 = _vec3_of(bridge.get("center", Vector3.ZERO))
	var he_raw = bridge.get("half_extents", Vector2(10.0, 10.0))
	var he: Vector2 = he_raw if he_raw is Vector2 else Vector2(float(he_raw[0]), float(he_raw[1]))
	var deck_h: float = float(bridge.get("deck_height", BRIDGE_DECK_HEIGHT))
	var rot: float = float(bridge.get("rotation_deg", 0.0))

	var b_root := Node3D.new()
	b_root.name = "Bridge"
	b_root.position = Vector3(c.x, c.y + deck_h * 0.5, c.z)
	b_root.rotation_degrees.y = rot
	parent.add_child(b_root)

	# 1. Main Deck
	var deck := MeshInstance3D.new()
	var box := BoxMesh.new()
	box.size = Vector3(he.x * 2.0, deck_h, he.y * 2.0)
	deck.mesh = box
	var dmat := StandardMaterial3D.new()
	dmat.albedo_color = Color(0.42, 0.40, 0.38) # Concrete road deck
	dmat.roughness = 0.85
	deck.material_override = dmat
	b_root.add_child(deck)

	# 2. Side Guardrails
	var rail_mat := StandardMaterial3D.new()
	rail_mat.albedo_color = Color(0.72, 0.70, 0.65) # Steel/concrete barrier
	rail_mat.roughness = 0.6
	for side in [-1.0, 1.0]:
		var rail := MeshInstance3D.new()
		var r_box := BoxMesh.new()
		r_box.size = Vector3(0.6, 1.2, he.y * 2.0)
		rail.mesh = r_box
		rail.material_override = rail_mat
		rail.position = Vector3((he.x - 0.3) * side, deck_h * 0.5 + 0.6, 0)
		b_root.add_child(rail)

	# 3. Support Piers extending downwards
	var pier_mat := StandardMaterial3D.new()
	pier_mat.albedo_color = Color(0.35, 0.34, 0.32)
	pier_mat.roughness = 0.9
	var pier_count := maxi(1, int(he.y / 25.0))
	for p_idx in range(pier_count):
		var p_z := -he.y + (float(p_idx + 0.5) / float(pier_count)) * (he.y * 2.0)
		var pier := MeshInstance3D.new()
		var p_mesh := BoxMesh.new()
		p_mesh.size = Vector3(he.x * 0.8, 14.0, 4.0)
		pier.mesh = p_mesh
		pier.material_override = pier_mat
		pier.position = Vector3(0, -7.0, p_z)
		b_root.add_child(pier)

# Sparse grassland ground clutter (grass tufts/rocks/brush) scattered
# across the WHOLE map's baseline ground - deliberately not per-area-dense
# like the small surface_zone scatters (see terrain_greebles.gd's own
# comment on why: hundreds of props across a 100+ half-extent map would be
# a real, pointless cost). Count is capped low and rejects any point that
# would land somewhere already visually claimed by something else: water/
# obstacles/ramps (is_position_blocked - covers the common cases), bridges
# (not covered by is_position_blocked, real decking shouldn't have grass
# tufts through it), any surface_zone's own footprint (already gets its
# OWN dedicated texture+greebles - stacking grassland clutter on top would
# look like two terrain treatments fighting), and a fixed radius around
# every start structure/resource node (keeps HQs/factories/harvester spots
# visually clear). A point that survives all that still gets its real
# terrain_height_at() Y, not an assumed 0 - a scattered point can legally
# land on an elevation zone's plateau TOP (is_position_blocked deliberately
# doesn't exclude that - see that function's own comment), and a grass
# tuft placed at y=0 under a raised plateau would look buried.
const GRASSLAND_CLUTTER_AVOID_RADIUS: float = 7.0

static func _spawn_grassland_clutter(map_def: Dictionary, parent: Node3D, prop_scale: float = 1.0):
	var he: Vector2 = MapCatalogScript.half_extents(map_def)
	# 2026-08-26: area is the actual map area (4 * hx * hz), not the
	# square (4 * hx^2) the legacy formula gave. A 1200x520 map is
	# 624,000 sqm, not 1,440,000 - the latter would over-dress the map
	# by 2.3x for a non-square layout.
	var area = (he.x * 2.0) * (he.y * 2.0)
	var count = clamp(int(area / 2000.0), 20, 50)

	var avoid_points: Array = []
	# RTS_CORE_ROADMAP.md B3: player_start/enemy_start became a spawns
	# array - same "every position field in each start group" collection,
	# just skipping the new "id" string field.
	for spawn in map_def.get("spawns", []):
		for key in spawn.keys():
			if key == "id": continue
			avoid_points.append(spawn[key])
	for r in map_def.get("resource_nodes", []):
		avoid_points.append(r.position)

	var bridge_rects = _collect_bridges(map_def)
	var surface_rects = []
	for s in map_def.get("surface_zones", []):
		surface_rects.append(_rect_from(s.center, s.half_extents))

	var rng = RandomNumberGenerator.new()
	rng.seed = hash(map_def.get("name", "grassland"))
	var placed = 0
	var attempts = 0
	while placed < count and attempts < count * 8:
		attempts += 1
		var pos = Vector3(rng.randf_range(-he.x * 0.94, he.x * 0.94), 0, rng.randf_range(-he.y * 0.94, he.y * 0.94))
		if is_position_blocked(map_def, pos):
			continue
		var rejected = false
		for rect in bridge_rects:
			if _point_in_rect(pos, rect):
				rejected = true
				break
		if not rejected:
			for rect in surface_rects:
				if _point_in_rect(pos, rect):
					rejected = true
					break
		if not rejected:
			for a in avoid_points:
				if Vector2(pos.x - a.x, pos.z - a.z).length() < GRASSLAND_CLUTTER_AVOID_RADIUS:
					rejected = true
					break
		if rejected:
			continue
		pos.y = terrain_height_at(map_def, pos)
		TerrainGreeblesScript.place_grassland_prop(pos, rng.randi(), parent, prop_scale)
		placed += 1

	# CORE_DESIGN_LANGUAGE.md §2.1/§7.1: tall clutter (TerrainGreebles.
	# _place_tall_brush()) is only legal OFF the playable surface - the map's
	# outer edge margin (beyond the 0.94 band the sprinkle above stays
	# within) or a position a steep slope has already made unreachable
	# (is_position_blocked() true for that reason, not because it's water or
	# an obstacle, where nothing should render at all). Unit readability
	# during a fight is a gameplay requirement, so this pass deliberately
	# never lands on the interior navigable surface the loop above sprinkles
	# short props across - full-height brush there would let a unit vanish
	# behind foliage mid-engagement.
	var tall_rng = RandomNumberGenerator.new()
	tall_rng.seed = hash(map_def.get("name", "grassland")) + 1
	var tall_placed = 0
	var tall_attempts = 0
	while tall_placed < count and tall_attempts < count * 8:
		tall_attempts += 1
		# 2026-08-26: per-axis range so the tall-brush edge band follows
		# the actual non-square map bounds, not the legacy square.
		var pos = Vector3(tall_rng.randf_range(-he.x, he.x), 0, tall_rng.randf_range(-he.y, he.y))
		if _is_over_water_or_obstacle(map_def, pos):
			continue
		var on_edge = absf(pos.x) > he.x * 0.94 or absf(pos.z) > he.y * 0.94
		var steep_slope = not on_edge and is_position_blocked(map_def, pos)
		if not (on_edge or steep_slope):
			continue
		var rejected = false
		for rect in bridge_rects:
			if _point_in_rect(pos, rect):
				rejected = true
				break
		if rejected:
			continue
		pos.y = terrain_height_at(map_def, pos)
		TerrainGreeblesScript.place_grassland_prop(pos, tall_rng.randi(), parent, prop_scale, true)
		tall_placed += 1

# --- Ambient harvestable trees ------------------------------------------------
#
# The "ambient forest" pass. Spawns individual ResourceNode trees across
# the whole map's baseline ground, parented to the world root (NOT to a
# ResourceField), each carrying a small lumber amount. resource_node.gd's
# is_ambient=true flag is what makes them: (a) draw from the
# ambient_tree_*.glb pool instead of the 3-variant resource_lumber_* one,
# (b) NEVER regrow once depleted.
#
# AVOIDANCE (Chris, 2026-08-23: "trees avoid lakes but not marshes"):
# water is _pos_on_lake() - rect water_areas AND shallow_water_areas AND
# organic water_blobs, with AMBIENT_SHORE_MARGIN of standoff past each
# shoreline (blobs enforce at least their own shore_blend, since the bed
# stays below sea level that far out - see that function's comment).
# Marshes are surface_zones, NOT water - a marsh reed bed is exactly where
# a tree may stand - so the tree pass deliberately passes NO surface_rects
# down to the cluster helpers and grows through marsh, forest-floor, ice
# and every other land zone alike. Still avoided: bridges, spawn
# structures, and the harvestable resource_nodes themselves (the lumber
# fields that DO regrow). The avoid radius is larger than the grass-tuft
# 7.0 because trees are bigger and a forest grown right up to an HQ is
# busy enough to compete visually with the buildings.
#
# DENSITY: grove-shaped, capped so a 4x-scaled map (world_scale) doesn't
# multiply the tree count by 16x the way area does. The cap is the same
# order of magnitude as `_spawn_slope_rocks` (SLOPE_ROCK_MAX_COUNT = 260)
# - deliberately NOT a fixed-per-half-extent, since the user-facing
# constraint is "looks like a forest" rather than "exactly N trees per
# map."
#
# CLUSTER-BASED AMBIENT SCATTER (Chris, 2026-08-10).
#
# Old: Poisson-disc-style random scatter across the whole map at ~1 item
# per 150 m², with 1000 trees and 800 ore as upper bounds. A typical
# 210-half map produced ~900 trees + ~750 ore = ~1650 ambient items, all
# of them living as ResourceNode instances in the scene tree and in
# the `resource_nodes` group.
#
# New: K cluster centers, each carrying M items in a Gaussian falloff
# around the center.
#
# 2026-08-23 retune (second playtest ask, "more in groves/forests"). The
# first-pass numbers could not physically fill: CLUSTER_RADIUS 9 with an
# 8.0 per-tree clearance fits ~4-6 trees in a whole grove (hexagonal
# packing at 8-unit spacing gives one tree per ~55 m² against a 254 m²
# disc), so requesting 22-32 mostly failed and the map showed scattered
# pairs instead of woods. Radius 14 + clearance 6.0 fits ~15+ per grove -
# canopies nearly touching, which is what reads as FOREST from RTS camera
# height - while the typical placed total (~30 x ~17 = ~510) lands BELOW
# the old nominal ~810, because bigger clusters waste far fewer attempts
# on mutual-clearance rejections.
#
# Why the count cut matters. Every ResourceNode is a node in the scene
# tree and an entry in the `resource_nodes` group. match_director.gd's
# nearest_resource_node() (called by every harvester decision) and
# _nearest_ambient_to() (called on every right-click that targets a
# tree) iterate the whole group - O(N) per call, N being the scatter
# count. Dropping from ~1650 to ~450 cuts that iteration cost by
# ~3.7x. The MultiMesh draw batching in ambient_scatter.gd is unchanged
# (visual draw-call cost was already addressed there).
#
# The avoidance lists are unchanged: an ore cannot be on a spawn point, an
# ore and a tree cannot be at the same world point. Cluster centers are
# mutually-avoided at the cluster scale (no two clusters within CLUSTER_AVOID_RADIUS of each
# other) so the patches read as discrete, not a single mega-patch.
# Bumped 2026-08-10 (second pass, ~30 min after first): playtest saw the
# first-pass clusters as too small / too sparse to read as forest groves
# from RTS camera height. FPS at ~47 is the "acceptable for dev" budget;
# these numbers trade iteration cost for visual weight and stay well
# under the pre-cluster ~1650-instance total.
#
# 2026-08-23: see the AVOIDANCE/DENSITY paragraphs above for the lake rule
# and the grove-size retune rationale.
const AMBIENT_SHORE_MARGIN: float = 1.5
const AMBIENT_TREE_AVOID_RADIUS: float = 6.0
const AMBIENT_TREE_CLUSTER_COUNT: int = 30
const AMBIENT_TREE_CLUSTER_RADIUS: float = 14.0
const AMBIENT_TREE_CLUSTER_AVOID_RADIUS: float = 54.0
const AMBIENT_TREE_ITEMS_MIN: int = 26
const AMBIENT_TREE_ITEMS_MAX: int = 40
const AMBIENT_TREE_MIN_COUNT: int = 40
const AMBIENT_TREE_MAX_COUNT: int = 1200  # = 30 clusters * 40 items ceiling

const AMBIENT_ORE_AVOID_RADIUS: float = 9.0
const AMBIENT_ORE_CLUSTER_COUNT: int = 20
const AMBIENT_ORE_CLUSTER_RADIUS: float = 7.0
const AMBIENT_ORE_CLUSTER_AVOID_RADIUS: float = 38.0
const AMBIENT_ORE_ITEMS_MIN: int = 16
const AMBIENT_ORE_ITEMS_MAX: int = 22
const AMBIENT_ORE_MIN_COUNT: int = 30
const AMBIENT_ORE_MAX_COUNT: int = 440   # = 20 clusters * 22 items ceiling

# Pre-cluster constants, kept commented so a future "revert to random
# scatter" edit can grep them and replace the cluster loop with the
# pre-2026-08-10 version.
# const AMBIENT_TREE_DENSITY_M2: float = 150.0
# const AMBIENT_TREE_MAX_COUNT: int = 1000
# const AMBIENT_ORE_DENSITY_M2: float = 180.0
# const AMBIENT_ORE_MAX_COUNT: int = 800

# canyon_ford PR5 (2026-08-26): tree placement slope cap. Below the
# cap (~26°), a tree sits naturally on the slope. Above the cap, a
# tree either stands on a vertical-ish face (visually wrong - the
# trunk pokes through the slope) or on a hand-placed cliff mesh
# (the cliff's geometry is hostile to a tree's collision box). The
# 0.5 figure is well below the SLOPE_IMPASSABLE threshold (0.7) and
# above the SLOPE_WALKABLE_SLOW threshold (0.3) - i.e. trees don't
# appear even on moderate slopes, leaving those to greebles
# (terrain_greebles.gd's _scatter_rocky / _scatter_* already slope-
# reject). Matches what a real forest does on a steep hillside:
# the trees bunch up at the base, the slope above is bare rock.
const AMBIENT_TREE_MAX_SLOPE: float = 0.5

static func _spawn_ambient_trees(map_def: Dictionary, parent: Node3D, prop_scale: float = 1.0, ticker: Node = null) -> Array:
	var he: Vector2 = MapCatalogScript.half_extents(map_def)
	# SKIRMISH_PERF_TROUBLESHOOTING.md §12. Per-map density multiplier.
	# Multiplies both the cluster count and the per-cluster item cap,
	# so the prop total scales as density^2. Default 1.0; lake_crossing
	# ships at 0.5 to halve the scatter cost.
	var density: float = clampf(float(map_def.get("ambient_scatter_density", 1.0)), 0.1, 2.0)
	var cluster_count: int = int(round(float(AMBIENT_TREE_CLUSTER_COUNT) * density))
	var items_max: int = int(round(float(AMBIENT_TREE_ITEMS_MAX) * density))
	var items_min: int = int(round(float(AMBIENT_TREE_ITEMS_MIN) * density))
	var max_count: int = cluster_count * items_max

	# Avoidance set. Deliberately NOT identical to _spawn_grassland_clutter()
	# anymore (Chris, 2026-08-23): the grass pass keeps its blanket
	# surface-zone rejection because its props would fight each zone's own
	# dedicated dressing, but a TREE is exactly what a forest/marsh zone
	# wants standing in it - so this pass passes NO surface_rects and
	# relies on _pos_on_lake() for everything watery. Bridges, spawns and
	# harvestable fields stay rejected.
	var avoid_points := _ambient_avoid_points(map_def)
	var bridge_rects = _collect_bridges(map_def)

	# Seeded off the map name (same convention as _spawn_grassland_
	# clutter): a given map dresses identically run to run, which is
	# what the screenshot-verification convention this project uses
	# requires. The seed is OFFSET (vs. grassland's seed) so the two
	# passes never draw the same RNG sequence for the same map.
	var rng = RandomNumberGenerator.new()
	rng.seed = hash(map_def.get("name", "ambient")) + 0xA1B2C3D4
	var placed = 0
	# Frame-budget deadline for the per-cluster yield below; only advanced when
	# a ticker was supplied (see spawn_visuals()).
	var deadline: int = Time.get_ticks_usec() + int(BUILD_FRAME_BUDGET_MS * 1000.0)
	# Returned for the ambient-ore pass to consume as an avoidance set,
	# so an ore and a tree never overlap.
	var placed_positions: Array = []
	var clusters := _pick_cluster_centers(
		rng, he, cluster_count, AMBIENT_TREE_CLUSTER_AVOID_RADIUS,
		avoid_points, bridge_rects, [], map_def)
	for cluster_center in clusters:
		# Headless / probe callers (no SceneTree ticker): fall back to a
		# busy wait rather than a real await. See _build_conforming_zone_
		# mesh_stepwise (terrain_builder.gd:3843+) for the same fix.
		if Time.get_ticks_usec() >= deadline:
			if ticker == null:
				deadline = Time.get_ticks_usec() + int(BUILD_FRAME_BUDGET_MS * 1000.0)
			else:
				await ticker.get_tree().process_frame
				deadline = Time.get_ticks_usec() + int(BUILD_FRAME_BUDGET_MS * 1000.0)
		var items := rng.randi_range(items_min, items_max)
		var placed_in_cluster := _place_in_cluster(
			rng, cluster_center, AMBIENT_TREE_CLUSTER_RADIUS, items,
			avoid_points, bridge_rects, [],
			AMBIENT_TREE_AVOID_RADIUS, max_count - placed, map_def)
		for pos in placed_in_cluster:
			# canyon_ford PR5 (2026-08-26): reject any item whose
			# terrain slope exceeds AMBIENT_TREE_MAX_SLOPE. The
			# cluster-center pick does the same at the cluster scale
			# (via _pick_cluster_centers' lake check), but the per-
			# item jitter inside a cluster can still land an item on
			# a slope that the cluster center was flat against.
			# Cheap filter - _slope_at reads the same heightmap cache
			# height_at uses, no extra cost beyond a 4-tap sample.
			if _slope_at(map_def, pos.x, pos.z) > AMBIENT_TREE_MAX_SLOPE:
				continue
			pos.y = terrain_height_at(map_def, pos)
			TerrainGreeblesScript.spawn_ambient_tree(pos, parent, rng.randi(), ResourceNodeScript.AMBIENT_TREE_AMOUNT)
			placed_positions.append(pos)
			placed += 1
			if placed >= max_count:
				return placed_positions
	return placed_positions

# AMBIENT ORE PASS. Same overall pattern as _spawn_ambient_trees above
# (sparse scatter across playable ground, no field, no regrow), but:
#   * Spawns via TerrainGreeblesScript.spawn_ambient_ore, which routes
#     through resource_node.gd's existing 3-variant resource_ore_* pool
#     (no new Blender work; the harvestable outcrop IS the ambient
#     silhouette, deliberately - see resource_node.gd's
#     _try_spawn_ambient_authored comment).
#   * Density, avoid radius, and per-find amount are smaller-bigger-
#     same respectively vs. the trees (see the constants above).
#   * MUST RUN AFTER _spawn_ambient_trees, and consumes the trees'
#     already-placed positions as an extra avoidance set so an ore
#     doesn't land on top of a tree (or vice versa on a future pass).
#   * Same avoidance rules as the trees EXCEPT surface zones: an ore keeps
#     the blanket surface_rects rejection (an outcrop fighting a marsh's
#     reeds reads as two terrain treatments, unlike a tree in a marsh),
#     and gains _pos_on_lake() via the shared cluster helpers - the
#     2026-08-10 rewrite dropped the pre-cluster scatter's water check
#     for BOTH passes; the trees got it back first (2026-08-23), the ore
#     with it.
#   * Uses its OWN RNG seed (off the map name, +0xB5C6D7E8) so the
#     same map-name determinism contract holds and the two passes
#     never draw the same RNG sequence for the same attempt.
static func _spawn_ambient_ores(map_def: Dictionary, parent: Node3D, prop_scale: float = 1.0, ambient_tree_positions: Array = [], ticker: Node = null):
	var he: Vector2 = MapCatalogScript.half_extents(map_def)
	# Same density multiplier as the trees, so a 0.5 map cuts the ore
	# scatter by the same proportion (see the _spawn_ambient_trees
	# header for the math).
	var density: float = clampf(float(map_def.get("ambient_scatter_density", 1.0)), 0.1, 2.0)
	var cluster_count: int = int(round(float(AMBIENT_ORE_CLUSTER_COUNT) * density))
	var items_max: int = int(round(float(AMBIENT_ORE_ITEMS_MAX) * density))
	var items_min: int = int(round(float(AMBIENT_ORE_ITEMS_MIN) * density))
	var max_count: int = cluster_count * items_max

	# Same avoidance set as the trees, plus the trees themselves (an
	# ore and a tree are NOT allowed to overlap - a 2x2 metre stack
	# of foliage on an outcrop reads as a glitch, not a feature).
	var avoid_points := _ambient_avoid_points(map_def)
	for t in ambient_tree_positions:
		avoid_points.append(t)
	var bridge_rects = _collect_bridges(map_def)
	var surface_rects = _surface_rects(map_def)

	var rng = RandomNumberGenerator.new()
	rng.seed = hash(map_def.get("name", "ambient_ore")) + 0xB5C6D7E8
	var placed = 0
	var deadline: int = Time.get_ticks_usec() + int(BUILD_FRAME_BUDGET_MS * 1000.0)
	var clusters := _pick_cluster_centers(
		rng, he, cluster_count, AMBIENT_ORE_CLUSTER_AVOID_RADIUS,
		avoid_points, bridge_rects, surface_rects, map_def)
	for cluster_center in clusters:
		# Headless / probe callers (no SceneTree ticker): fall back to a
		# busy wait rather than a real await. See _build_conforming_zone_
		# mesh_stepwise (terrain_builder.gd:3843+) for the same fix.
		if Time.get_ticks_usec() >= deadline:
			if ticker == null:
				deadline = Time.get_ticks_usec() + int(BUILD_FRAME_BUDGET_MS * 1000.0)
			else:
				await ticker.get_tree().process_frame
				deadline = Time.get_ticks_usec() + int(BUILD_FRAME_BUDGET_MS * 1000.0)
		var items := rng.randi_range(items_min, items_max)
		var placed_in_cluster := _place_in_cluster(
			rng, cluster_center, AMBIENT_ORE_CLUSTER_RADIUS, items,
			avoid_points, bridge_rects, surface_rects,
			AMBIENT_ORE_AVOID_RADIUS, max_count - placed, map_def)
		for pos in placed_in_cluster:
			pos.y = terrain_height_at(map_def, pos)
			TerrainGreeblesScript.spawn_ambient_ore(pos, parent, rng.randi(), ResourceNodeScript.AMBIENT_ORE_AMOUNT)
			placed += 1
			if placed >= max_count:
				return

# --- Slope-driven rock exposure ---
#
# Playtest: "the terrain / boulder greebles should be heaviest on slopes, the
# steeper the slope the more boulders it will ordinarily expose", and "the
# cliffs and ravines should match the boulders and rocks shapewise, so they
# look like the same regions geography."
#
# Both asks are one mechanism. Nothing in terrain_greebles.gd was ever
# slope-aware - every scatter function places props by zone and density alone -
# so a steep hillside was dressed exactly like flat ground and read as steep
# only because the navmesh silently declined to cover it. This pass walks the
# map on its own coarse grid, samples the _slope_at() that already exists, and
# biases boulder placement toward steep ground: near-flat terrain gets nothing,
# ground approaching MAX_WALKABLE_SLOPE gets real rock cover, and genuinely
# unwalkable slope gets the most (nothing needs to path through it anyway).
#
# The geology question answers itself as a consequence rather than needing its
# own system: a ravine wall and a hillside cliff are both just "steep" to
# _slope_at(), so both get dressed from the SAME boulder pool that the map's
# authored rock obstacles use. Continuous geology, no cliff-specific asset
# family, no second placement rule that could drift out of agreement with this
# one.
#
# Purely decorative - no StaticBody3D, matching terrain_greebles.gd's own
# contract. Rock that appeared on a slope and also blocked movement would turn
# a visual cue into a silent gameplay change.
#
# CLUSTERED (Chris, 2026-08-23: "boulders need to cluster together too").
# The pass above placed each slope-approved boulder immediately at its own
# grid sample - geologically honest about WHERE rock sheds (steep ground)
# but visually wrong about HOW: real talus gathers in fields at a cliff's
# toe and in ravine mouths, not as uniformly spaced single stones down the
# whole hillside. Two phases now:
#
#   Phase 1 (unchanged gate): walk the coarse grid, jitter each sample,
#   roll against slope_rock_density() - but COLLECT accepted points
#   instead of placing them.
#   Phase 2: seeds are picked from those candidates with mutual avoidance
#   (BOULDER_SEED_AVOID_RADIUS), then every candidate within
#   BOULDER_CLUSTER_RADIUS of a seed is placed; candidates claimed by no
#   seed are dropped. Steepness still decides whether rock exists at all -
#   clustering just decides which of it survives - so the densest fields
#   still land on the steepest, least walkable ground.
#
# Determinism is preserved end to end: one seeded RNG, phase 1 walks and
# rolls exactly as before, so a given map proposes an identical candidate
# set run to run.
const SLOPE_ROCK_GRID_DIVISIONS: int = 44
# Below this slope, bare ground: flat terrain has no reason to be shedding
# bedrock, and rocks everywhere would read as noise rather than as a cue.
const SLOPE_ROCK_MIN_SLOPE: float = 0.12
# Hard cap on how many this pass may add regardless of map size or how
# mountainous the terrain turns out to be. A map that is steep nearly
# everywhere would otherwise scale straight into a wall of geometry, which is
# the same trap terrain_greebles.gd's _scaled_count() exists to avoid.
const SLOPE_ROCK_MAX_COUNT: int = 260
# Field shape: candidates within BOULDER_CLUSTER_RADIUS of a seed form one
# boulder field; seeds sit at least BOULDER_SEED_AVOID_RADIUS apart so the
# fields read as discrete talus piles, not one continuous apron. Sized
# against the grid step ((2*half)/44 ~= 9.5 units on a 210-half map): a
# 16-unit radius spans several cells of steep ground per field.
const BOULDER_CLUSTER_RADIUS: float = 16.0
const BOULDER_SEED_AVOID_RADIUS: float = 42.0
const BOULDER_MAX_SEEDS: int = 48

# Placement probability for a given local slope, 0..1. Reaches 1 only at
# genuinely unwalkable ground, so the densest rock cover always coincides with
# the terrain a unit cannot cross - the cue and the rule agree.
static func slope_rock_density(slope: float) -> float:
	if slope <= SLOPE_ROCK_MIN_SLOPE:
		return 0.0
	return clampf((slope - SLOPE_ROCK_MIN_SLOPE) / (MAX_WALKABLE_SLOPE - SLOPE_ROCK_MIN_SLOPE), 0.0, 1.0)

static func _spawn_slope_rocks(map_def: Dictionary, parent: Node3D, ticker: Node = null) -> int:
	if not ResourceLoader.exists(BOULDER_MODEL_DIR % 0):
		return 0
	var he: Vector2 = MapCatalogScript.half_extents(map_def)
	# 2026-08-26: per-axis step so the slope-rock grid actually covers
	# the map on both axes. The grid is square and step is the same on
	# both axes (Recast's slope_at() reads the same heightmap either way),
	# so using max(he.x, he.y) keeps the grid step identical for both
	# axes while ensuring the larger axis is the one that drives it.
	var half: float = max(he.x, he.y)
	var step: float = (half * 2.0) / float(SLOPE_ROCK_GRID_DIVISIONS)
	# Frame-budget deadline for the per-grid-row yield in phase 1; only
	# consulted when a ticker was supplied (see spawn_visuals()).
	var deadline: int = Time.get_ticks_usec() + int(BUILD_FRAME_BUDGET_MS * 1000.0)

	var bridge_rects = _collect_bridges(map_def)
	var avoid_points: Array = []
	for spawn in map_def.get("spawns", []):
		for key in spawn.keys():
			if key == "id": continue
			avoid_points.append(spawn[key])
	for r in map_def.get("resource_nodes", []):
		avoid_points.append(r.position)

	# Seeded off the map name, like every other scatter here, so a given map
	# dresses identically run to run - the screenshot-verification convention
	# this project uses depends on it.
	var rng = RandomNumberGenerator.new()
	rng.seed = hash(map_def.get("name", "slope_rocks")) + 977

	# Phase 1: propose slope-approved candidates (no placement yet).
	var candidates: Array = []
	var y := -half + step * 0.5
	while y < half:
		# Headless / probe callers (no SceneTree ticker): fall back to a
		# busy wait rather than a real await. See _build_conforming_zone_
		# mesh_stepwise (terrain_builder.gd:3843+) for the same fix.
		if Time.get_ticks_usec() >= deadline:
			if ticker == null:
				deadline = Time.get_ticks_usec() + int(BUILD_FRAME_BUDGET_MS * 1000.0)
			else:
				await ticker.get_tree().process_frame
				deadline = Time.get_ticks_usec() + int(BUILD_FRAME_BUDGET_MS * 1000.0)
		var x := -half + step * 0.5
		while x < half:
			var px: float = x + rng.randf_range(-step * 0.4, step * 0.4)
			var pz: float = y + rng.randf_range(-step * 0.4, step * 0.4)
			x += step
			if rng.randf() > slope_rock_density(_slope_at(map_def, px, pz)):
				continue
			var pos := Vector3(px, 0.0, pz)
			# Water and existing obstacles own their own footprints; a bridge
			# deck should not sprout bedrock through it.
			if _is_over_water_or_obstacle(map_def, pos):
				continue
			var rejected := false
			for rect in bridge_rects:
				if _point_in_rect(pos, rect):
					rejected = true
					break
			if not rejected:
				for a in avoid_points:
					if Vector2(pos.x - a.x, pos.z - a.z).length() < GRASSLAND_CLUTTER_AVOID_RADIUS:
						rejected = true
						break
			if not rejected:
				candidates.append(pos)
		y += step

	# Phase 2a: pick field seeds from the candidates themselves - a seed IS
	# a slope-approved point, so every field is anchored on genuine rock
	# ground by construction.
	var seeds: Array = []
	for c in candidates:
		if seeds.size() >= BOULDER_MAX_SEEDS:
			break
		var too_close := false
		for s in seeds:
			if Vector2(c.x - s.x, c.z - s.z).length() < BOULDER_SEED_AVOID_RADIUS:
				too_close = true
				break
		if not too_close:
			seeds.append(c)

	# Phase 2b: place each candidate that falls inside some seed's field;
	# drop the stragglers. `claimed` stops a candidate shared between two
	# overlapping fields from placing twice.
	var placed := 0
	var claimed := {}
	for s in seeds:
		for i in range(candidates.size()):
			if claimed.has(i):
				continue
			var c: Vector3 = candidates[i]
			if Vector2(c.x - s.x, c.z - s.z).length() > BOULDER_CLUSTER_RADIUS:
				continue
			claimed[i] = true
			var packed := load(BOULDER_MODEL_DIR % (rng.randi() % BOULDER_POOL_SIZE)) as PackedScene
			if packed == null:
				continue
			var inst := packed.instantiate() as Node3D
			if inst == null:
				continue
			inst.scale = Vector3.ONE * rng.randf_range(0.55, 1.5)
			inst.rotation.y = rng.randf_range(0, TAU)
			# A slight lean, and partly sunk into the slope rather than perched
			# on it: exposed bedrock is embedded in the hillside, and a boulder
			# sitting perfectly level on a steep face reads as a prop dropped
			# onto the terrain instead of as part of it.
			inst.rotation.x = rng.randf_range(-0.22, 0.22)
			inst.rotation.z = rng.randf_range(-0.22, 0.22)
			# position, not global_position, matching _spawn_authored_boulders()
			# above: a Node3D outside the tree has no global transform, so a
			# global_position assignment here would silently fall back to local
			# (and log) for any caller whose parent isn't in the tree yet -
			# tests and probes especially. See _spawn_bridge()'s own note on
			# exactly this trap.
			inst.position = Vector3(c.x, terrain_height_at(map_def, c) - rng.randf_range(0.05, 0.45), c.z)
			parent.add_child(inst)
			placed += 1
			if placed >= SLOPE_ROCK_MAX_COUNT:
				return placed
	return placed

# --- Queries (pure functions, no Node dependency - callable from tests
# directly against a MapCatalog dictionary) ---

# The single source of truth for "what Y should something at this XZ sit
# at" - consulted for building placement, unit spawn positions, and every
# moving ground unit's per-tick Y snap. Because it's the ONLY place Y gets
# set for elevated terrain, vision (fog-of-war distance check) and combat
# (damage_resolver's hit_origin/defender Y comparison) automatically react
# to real elevation differences without needing their own map awareness -
# they just compare whatever Y values units/buildings already carry.
static func terrain_height_at(map_def: Dictionary, pos: Vector3) -> float:
	for b in map_def.get("bridges", []):
		if _point_in_rect(pos, _rect_from(b.center, b.half_extents)):
			return b.get("deck_height", BRIDGE_DECK_HEIGHT)
	# Real continuous terrain (noise + any authored hills/water_blobs, or a
	# real heightmap - see height_at()'s own header comment) for everywhere
	# a bridge deck doesn't apply.
	return height_at(map_def, pos.x, pos.z)

# Water, obstacles, and (on a heightmap-backed map) steep slopes are all
# "can't stand/build here" - a plateau's flat TOP is deliberately walkable
# (legitimate, valuable buildable high ground - the whole point of holding
# it), only the slope leading up to it can exceed MAX_WALKABLE_SLOPE.
# Surface terrain type at a point ("" if not inside any surface_zones entry -
# plain ground). Purely a speed-multiplier lookup (see ModuleCatalog.
# get_terrain_speed_multiplier()) consulted every physics tick by
# unit.gd, NOT a navmesh/passability concern - unlike water/
# obstacles/elevation, surface_zones never appear in _collect_holes() or
# any navmesh build, since every locomotor type CAN physically enter marsh/
# rock/mud/sand, just at a different speed. Overlapping zones resolve to
# whichever is listed first (maps are expected to keep these non-
# overlapping in practice; not worth a more elaborate blend for a cosmetic-
# adjacent terrain-flavor system).
static func get_surface_type_at(map_def: Dictionary, pos: Vector3) -> String:
	# RTS_CORE_ROADMAP.md B4: a surfacemap FULLY REPLACES the rect
	# surface_zones lookup below (build_terrain.py bakes surface_zones
	# INTO the surfacemap at generation time - see its build_surfacemap(),
	# same first-listed-wins overlap rule - so this isn't a second,
	# divergent source of truth once a map actually has one). Flag-gated:
	# none of the 8 bundled maps set terrain.surfacemap yet.
	var surfacemap_img = _get_surfacemap_image(map_def)
	if surfacemap_img:
		# 2026-08-26: see height_at() above - surfacemap sampling is
		# still square-aware (canyon_ford's rebuild doesn't use a baked
		# surfacemap PNG, only the analytic features[] + the
		# surface_zones[] rectangles that the new ramp / plateau tests
		# don't traverse).
		var half: float = map_def.get("map_half_extents", 80.0)
		return _sample_surfacemap(surfacemap_img, half, pos.x, pos.z, WorldScaleScript.for_map(map_def))

	for z in map_def.get("surface_zones", []):
		if _point_in_rect(pos, _rect_from(z.center, z.half_extents)):
			return z.get("surface_type", "")
	return ""

# Water only (no obstacles/slope) - RTS_CORE_ROADMAP.md B9's minimap bake
# wants "is this cell water" for its blue tint, not "is this cell
# unwalkable" (an obstacle or over-slope cell should still read as its
# normal ground color on the minimap, just with a blip/prop on top of it).
static func is_water_at(map_def: Dictionary, x: float, z: float) -> bool:
	# Resolve feature emissions so a `lake` feature's auto-emitted water_area
	# is in the iteration below. Idempotent.
	_resolve_features(map_def)
	if submerged_at(map_def, x, z):
		return true
	var pos = Vector3(x, 0, z)
	for w in map_def.get("water_areas", []):
		if _point_in_rect(pos, _rect_from(w.center, w.half_extents)):
			return true
	for blob in map_def.get("water_blobs", []):
		if _point_in_water_blob(blob, x, z):
			return true
	return false

# Lake avoidance for the ambient scatter passes (Chris, 2026-08-23: "trees
# avoid lakes but not marshes"). Covers all three water footprints - rect
# water_areas, rect shallow_water_areas, and organic water_blobs - with a
# `margin` standoff past the shoreline.
#
# The margin is NOT optional for blobs: a water_blob's ground doesn't rise
# back to sea level at the coastline, it rises over `shore_blend` units
# OUTSIDE the per-angle radius (see _water_blob_height_contribution), so a
# tree accepted exactly AT the blob boundary still stands in the submerged
# blend ring. Blobs therefore always get max(margin, shore_blend); rects
# get the plain margin (their bed is flat and the visual water plane ends
# at the rect edge, so a small aesthetic standoff is enough).
#
# Marshes are deliberately absent: a marsh is a surface_zone (walkable,
# just slow - see get_surface_type_at()), not water. Trees are ALLOWED in
# marshes and every other land surface zone; this function is the only
# water-facing gate the tree pass uses.
static func _pos_on_lake(map_def: Dictionary, pos: Vector3, margin: float = 0.0) -> bool:
	for w in map_def.get("water_areas", []):
		var r := _rect_from(w.center, w.half_extents)
		if pos.x > r.x0 - margin and pos.x < r.x1 + margin \
				and pos.z > r.z0 - margin and pos.z < r.z1 + margin:
			return true
	for sw in map_def.get("shallow_water_areas", []):
		var rs := _rect_from(sw.center, sw.half_extents)
		if pos.x > rs.x0 - margin and pos.x < rs.x1 + margin \
				and pos.z > rs.z0 - margin and pos.z < rs.z1 + margin:
			return true
	for blob in map_def.get("water_blobs", []):
		var c: Vector3 = blob.center
		var dx = pos.x - c.x
		var dz = pos.z - c.z
		var theta = atan2(dz, dx)
		var standoff = maxf(margin, float(blob.get("shore_blend", 4.0)))
		if Vector2(dx, dz).length() <= _water_blob_radius_at_angle(blob, theta) + standoff:
			return true
	return false

# Water or an obstacle footprint, with no slope check - split out of
# is_position_blocked() so the grassland-clutter tall/short decor split
# (see _spawn_grassland_clutter()'s CORE_DESIGN_LANGUAGE.md §3.1 comment)
# can ask "is this actually submerged/occupied" separately from "is this
# unreachable because of slope" - grass shouldn't ever render floating on
# water or poking through a building regardless of which decor tier it's
# in, but a steep slope is exactly the terrain tall brush is FOR.
static func _is_over_water_or_obstacle(map_def: Dictionary, pos: Vector3) -> bool:
	# The table and painted bodies count. Without this a painted lake grew
	# trees out of it, because every scatter pass asked this question and this
	# question only knew about authored rects and blobs.
	if submerged_at(map_def, pos.x, pos.z):
		return true
	for w in map_def.get("water_areas", []):
		if _point_in_rect(pos, _rect_from(w.center, w.half_extents)):
			return true
	for o in map_def.get("obstacles", []):
		if _point_in_rect(pos, _rect_from(o.center, o.half_extents)):
			return true
	for blob in map_def.get("water_blobs", []):
		if _point_in_water_blob(blob, pos.x, pos.z):
			return true
	return false

static func is_position_blocked(map_def: Dictionary, pos: Vector3) -> bool:
	# Make sure plateau / canyon / ridge auto-emitted cliffs are in the
	# cliffs[] array before we check it. The resolver is idempotent and
	# cheap (a few AABBs per feature) so calling it on every probe is
	# fine. spawn_visuals() already calls this once at scene-build time;
	# this call covers the lint / pathing / unit-placement paths that
	# run on a raw map_def.
	_resolve_features(map_def)
	if _is_over_water_or_obstacle(map_def, pos):
		return true
	# canyon_ford PR1 (2026-08-26): cliff footprints are impassable.
	# The cliff mesh is a hand-placed wall; spawning a unit inside its
	# footprint would put the unit inside solid rock. Without this
	# check, `lint_spawn_fairness` and the per-spawn placement check
	# both happily drop a unit onto a cliff, where it then can't move
	# because the cliff's StaticBody3D is in the way.
	for c in map_def.get("cliffs", []):
		if _point_in_rect(pos, _rect_from(c.center, c.half_extents)):
			return true
	for prop in map_def.get("props", []):
		var ptype: String = str(prop.get("type", ""))
		if ptype == "building" or prop.has("building_id"):
			var p_pos = _vec3_of(prop.get("pos", [0, 0, 0]))
			var s: float = float(prop.get("scale", 1.0))
			var rad: float = 6.0 * s
			var d_sq: float = (pos.x - p_pos.x) * (pos.x - p_pos.x) + (pos.z - p_pos.z) * (pos.z - p_pos.z)
			if d_sq < (rad * rad):
				return true
	# RTS_CORE_ROADMAP.md B4: a heightmap makes slope-blocking meaningful
	# everywhere, not just near authored hills (_slope_at() calls
	# height_at(), which already checks the heightmap first internally).
	# canyon_ford PR3 (2026-08-26): the bare MAX_WALKABLE_SLOPE check
	# that lived here before has been replaced with the same slope-class
	# classification the speed-multiplier path uses, so the
	# walkable/walkable-slow/impassable threshold is the same number
	# everywhere - one source of truth, no chance of the navmesh
	# excluding a 0.69 slope that the speed path then penalises as
	# impassable.
	var has_heightmap = _get_heightmap_image(map_def) != null
	if (has_heightmap or not map_def.get("hills", []).is_empty()) and slope_class_at(map_def, pos.x, pos.z) == SLOPE_IMPASSABLE:
		return true
	return false


# canyon_ford PR3 (2026-08-26): walkable / walkable-slow / impassable
# classification by raw slope (= rise/run, not degrees). Returned as a
# string (not an enum) so module_catalog.gd's SLOPE_SPEED_MULTIPLIERS
# table can use the same keys without a translation hop.
#
# Thresholds:
#   < SLOPE_WALKABLE_SLOW_THRESHOLD (0.3, ~17°)  -> "walkable"     - full speed
#   0.3 .. MAX_WALKABLE_SLOPE (0.7, ~35°)        -> "walkable_slow" - per-locomotion penalty
#   >= MAX_WALKABLE_SLOPE (0.7)                  -> "impassable"   - excluded by navmesh
#
# MAX_WALKABLE_SLOPE was the pre-PR3 cutoff (line 331) and is unchanged
# here. The "walkable_slow" tier is the new gameplay-relevant band
# between full-speed and navmesh-excluded - a unit CAN traverse it, but
# SLOPE_SPEED_MULTIPLIERS in module_catalog.gd assigns per-locomotion
# penalties (wheels slow to 0.6×, hover and air-cushion stay at 1.0×,
# etc.). This is the per-locomotion slope differentiation the user's
# spec asked for, with one source of truth for the threshold and one
# table for the multipliers.
#
# No-cliff maps: every existing map with a heightmap (scattered_peaks,
# highland_chokepoint, twin_summits per the B6 migration) gets the
# walkable_slow tier populated by its authored hills for free. The 11
# open_plains hills (height 9, radius 16-20, falloff 14-28) produce
# ~30-50° slopes on their faces - squarely in the "walkable_slow"
# band, so PR3's gameplay effect ships on every existing heightmap
# map without any per-map authoring work.
const SLOPE_WALKABLE_SLOW_THRESHOLD: float = 0.3
const SLOPE_WALKABLE: String = "walkable"
const SLOPE_WALKABLE_SLOW: String = "walkable_slow"
const SLOPE_IMPASSABLE: String = "impassable"

static func slope_class_at(map_def: Dictionary, x: float, z: float) -> String:
	var slope: float = _slope_at(map_def, x, z)
	if slope >= MAX_WALKABLE_SLOPE:
		return SLOPE_IMPASSABLE
	if slope >= SLOPE_WALKABLE_SLOW_THRESHOLD:
		return SLOPE_WALKABLE_SLOW
	return SLOPE_WALKABLE


# --- Cluster-scatter helpers (2026-08-10, Chris) ---
#
# Reused by both _spawn_ambient_trees and _spawn_ambient_ores; the
# avoid-points collection is identical between the two passes. The
# surface-rects list is NOT: since 2026-08-23 the tree pass passes none
# (trees belong in marsh/forest zones - see _spawn_ambient_trees), the
# ore pass keeps the full set. Both passes DO share the map_def-driven
# lake rejection inside these helpers. Cluster-center picking and
# per-cluster item placement are the structural change that turned the
# random scatter into the patchy scatter the playtest asked for.

# Same avoid-set the two ambient passes AND _spawn_grassland_clutter() use.
# Spawns + resource_node field centers - nothing of a resource_node's own
# group membership, since the field resources are stored under the
# resource_nodes top-level field of the map def.
static func _ambient_avoid_points(map_def: Dictionary) -> Array:
	var out: Array = []
	for spawn in map_def.get("spawns", []):
		for key in spawn.keys():
			if key == "id": continue
			out.append(spawn[key])
	for r in map_def.get("resource_nodes", []):
		out.append(r.position)
	return out


static func _surface_rects(map_def: Dictionary) -> Array:
	var out: Array = []
	for s in map_def.get("surface_zones", []):
		out.append(_rect_from(s.center, s.half_extents))
	return out


# Picks up to `count` cluster centers with mutual avoidance. A cluster
# center is rejected if it lands on a bridge/a surface zone/a spawn/
# resource_node (the same rules _spawn_grassland_clutter()
# uses), OR if it is within `cluster_avoid_radius` of an already-accepted
# cluster, OR - when the caller passes a map_def - if it lands on or near
# a lake (_pos_on_lake; the ambient passes are the only callers that do,
# and both want it: the 2026-08-10 cluster rewrite silently dropped the
# water check the pre-cluster scatter had, which is how trees ended up
# standing in lakes). The 0.94 inner-edge of the playable rectangle keeps
# every cluster on real ground (not on the lip of the map).
#
# Returns an Array of Vector2 (xz, y=0). The caller is responsible for
# sampling the actual terrain height at the item-placement phase.
# 2026-08-26: non-square map support - `half` is now Vector2 so the
# random range uses the actual X and Z bounds of the map, not the
# larger of the two (which would scatter trees outside the Z bounds of
# a 1200x520 map).
static func _pick_cluster_centers(
		rng: RandomNumberGenerator, half: Vector2, count: int, cluster_avoid_radius: float,
		avoid_points: Array, bridge_rects: Array, surface_rects: Array,
		map_def: Dictionary = {}) -> Array:
	var out: Array = []
	var max_attempts: int = count * 16
	var attempts := 0
	while out.size() < count and attempts < max_attempts:
		attempts += 1
		var pos := Vector2(rng.randf_range(-half.x * 0.94, half.x * 0.94),
				rng.randf_range(-half.y * 0.94, half.y * 0.94))
		if is_position_blocked_in_dict(pos, avoid_points, bridge_rects, surface_rects, 0.0):
			continue
		if not map_def.is_empty() and _pos_on_lake(map_def, Vector3(pos.x, 0, pos.y), AMBIENT_SHORE_MARGIN):
			continue
		# Mutual cluster avoidance: no two cluster centers within the
		# cluster_avoid_radius of each other. Tested as a flat 2D distance
		# (cluster centers are on a heightmap, the radius is in world
		# units, the Y component would just add noise).
		var too_close := false
		for c in out:
			if (c - pos).length() < cluster_avoid_radius:
				too_close = true
				break
		if too_close:
			continue
		out.append(pos)
	return out


# Per-item placement inside one cluster. The cluster center is the mean
# of a Gaussian; items land with a small per-axis jitter scaled by the
# cluster radius so most sit near the center but a few stragglers drift
# to the edge - the visual that says "this is a patch, not a perfect
# grid." Items are rejected against the same avoid set as the cluster
# center, AND against the already-placed items in this cluster, using
# `per_item_avoid_radius` as the per-item clearance - and against lakes,
# exactly like _pick_cluster_centers above (a whole grove's worth of
# individual rejections near a shoreline is what keeps a forest edge
# reading as a coastline instead of a grid of drowned trunks).
#
# Returns an Array of Vector3 with y=0. The caller resolves the actual
# terrain height for each item.
static func _place_in_cluster(
		rng: RandomNumberGenerator, center: Vector2, cluster_radius: float, max_items: int,
		avoid_points: Array, bridge_rects: Array, surface_rects: Array,
		per_item_avoid_radius: float, hard_cap: int, map_def: Dictionary = {}) -> Array:
	var out: Array = []
	var attempts := 0
	var placed_in_cluster := 0
	var placed_local: Array = []
	while placed_in_cluster < max_items and attempts < max_items * 6 and out.size() < hard_cap:
		attempts += 1
		# Gaussian-ish: two randf_range calls centered on 0, summed, then
		# scaled. The triangular distribution's standard deviation is
		# ~0.4 * cluster_radius, so most items land within the inner half
		# of the cluster and a few sit at the rim.
		var jitter_x: float = (rng.randf_range(-1.0, 1.0) + rng.randf_range(-1.0, 1.0)) * 0.5 * cluster_radius
		var jitter_z: float = (rng.randf_range(-1.0, 1.0) + rng.randf_range(-1.0, 1.0)) * 0.5 * cluster_radius
		var pos := Vector2(center.x + jitter_x, center.y + jitter_z)
		if is_position_blocked_in_dict(pos, avoid_points, bridge_rects, surface_rects, 0.0):
			continue
		if not map_def.is_empty() and _pos_on_lake(map_def, Vector3(pos.x, 0, pos.y), AMBIENT_SHORE_MARGIN):
			continue
		# Per-item mutual avoidance inside the cluster.
		var too_close := false
		for p in placed_local:
			if (p - pos).length() < per_item_avoid_radius:
				too_close = true
				break
		if too_close:
			continue
		placed_local.append(pos)
		out.append(Vector3(pos.x, 0, pos.y))
		placed_in_cluster += 1
	return out


# Lightweight avoidance check used by the cluster helpers. Skips the
# slope check (clusters and items are picked fast; the slope check
# belongs in is_position_blocked()'s full gate at item acceptance
# time, and the cluster center is the same call from the old code
# path that the full gate also runs). `extra_radius` is added to the
# per-point radius (0.0 for cluster centers, AMBIENT_*_AVOID_RADIUS
# for items - the per-item radius handles in-cluster mutual avoidance
# separately above, so this stays at 0 for both).
static func is_position_blocked_in_dict(
		pos2: Vector2, avoid_points: Array, bridge_rects: Array, surface_rects: Array,
		extra_radius: float) -> bool:
	var pos := Vector3(pos2.x, 0, pos2.y)
	for rect in bridge_rects:
		if _point_in_rect(pos, rect):
			return true
	for rect in surface_rects:
		if _point_in_rect(pos, rect):
			return true
	for a in avoid_points:
		if Vector2(pos.x - a.x, pos.z - a.z).length() < extra_radius:
			return true
	return false


# ==============================================================================
# IN-GAME DYNAMIC BUILDING & DOCK BAY TERRAIN FLATTENING
# ==============================================================================

static func apply_building_pad_flattening(map_def: Dictionary, ground_node: Node, center: Vector3, half_extents: Vector2, yaw: float, target_h: float, falloff: float = 4.0) -> void:
	if not map_def.has("building_pads"):
		map_def["building_pads"] = []
	var pad_entry := {
		"center_x": center.x,
		"center_z": center.z,
		"half_x": half_extents.x,
		"half_z": half_extents.y,
		"yaw": yaw,
		"target_h": target_h,
		"falloff": falloff
	}
	(map_def["building_pads"] as Array).append(pad_entry)

	if ground_node == null:
		return

	var max_radius: float = maxf(half_extents.x, half_extents.y) + falloff + 6.0
	var max_rad_sq: float = max_radius * max_radius

	# 1. Deform visual ground ArrayMesh vertices
	var mesh_inst: MeshInstance3D = ground_node.get_node_or_null("MeshInstance3D") as MeshInstance3D
	if mesh_inst != null and mesh_inst.mesh is ArrayMesh:
		var arr_mesh: ArrayMesh = mesh_inst.mesh as ArrayMesh
		if arr_mesh.get_surface_count() > 0:
			var arrays: Array = arr_mesh.surface_get_arrays(0)
			var verts: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
			var updated := false
			for i in range(verts.size()):
				var v: Vector3 = verts[i]
				var d2: float = (v.x - center.x) * (v.x - center.x) + (v.z - center.z) * (v.z - center.z)
				if d2 <= max_rad_sq:
					var new_y := height_at(map_def, v.x, v.z)
					if absf(v.y - new_y) > 0.001:
						v.y = new_y
						verts[i] = v
						updated = true
			if updated:
				arrays[Mesh.ARRAY_VERTEX] = verts
				arr_mesh.clear_surfaces()
				arr_mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)

	# 2. Deform physics collision HeightMapShape3D
	var col_shape_node: CollisionShape3D = ground_node.get_node_or_null("CollisionShape3D") as CollisionShape3D
	if col_shape_node != null and col_shape_node.shape is HeightMapShape3D:
		var hm: HeightMapShape3D = col_shape_node.shape as HeightMapShape3D
		var he: Vector2 = MapCatalogScript.half_extents(map_def)
		var span: Vector2 = he * 2.0
		var col_step_x: float = maxf(COLLISION_HEIGHTMAP_STEP, span.x / 180.0)
		var col_step_z: float = maxf(COLLISION_HEIGHTMAP_STEP, span.y / 180.0)
		var sx: int = hm.map_width
		var sz: int = hm.map_depth
		var data: PackedFloat32Array = hm.map_data
		var col_min: int = clampi(int(floor((center.x - max_radius + he.x) / col_step_x)), 0, sx - 1)
		var col_max: int = clampi(int(ceil((center.x + max_radius + he.x) / col_step_x)), 0, sx - 1)
		var row_min: int = clampi(int(floor((center.z - max_radius + he.y) / col_step_z)), 0, sz - 1)
		var row_max: int = clampi(int(ceil((center.z + max_radius + he.y) / col_step_z)), 0, sz - 1)
		for r in range(row_min, row_max + 1):
			var wz: float = -he.y + float(r) * col_step_z
			for c in range(col_min, col_max + 1):
				var wx: float = -he.x + float(c) * col_step_x
				var d2: float = (wx - center.x) * (wx - center.x) + (wz - center.z) * (wz - center.z)
				if d2 <= max_rad_sq:
					data[r * sx + c] = height_at(map_def, wx, wz)
		hm.map_data = data
