class_name VisionService
extends RefCounted

# Who can see what, and the grey sheet drawn over what they cannot.
#
# PORTED, NOT REDESIGNED. The old implementation (skirmish.gd:735-1017) is good
# and its comments record real bugs found the hard way - boundary flicker, the
# wallhack a shroud-only fog allows, the asymmetry a single fog_hidden flag
# creates once weapons out-range vision. All of that survives; what changes is
# that it lives in a service the director delegates to rather than in 280 lines
# of the match controller.
#
# The research pass proposed a SubViewport mask instead. That is a downgrade
# here: a viewport mask is a two-state answer, and this is a three-state system -
# unexplored, explored-but-not-currently-seen, and visible. Losing the middle
# state would mean a base you scouted an hour ago vanishes the moment you look
# away, which is worse than the cost it saves.
#
# TWO SEPARATE QUESTIONS, both respecting real terrain and obstacle occluders:
#
#   GAMEPLAY visibility (is_visible_to_team) uses real line-of-sight raycasts
#   and continuous terrain checks so units behind ridges or structures cannot
#   be targeted through them.
#
#   The VISUAL shroud performs efficient grid-space raymarching against the
#   continuous terrain elevation and obstacle bounding volumes so fog contours
#   reflect hills, valleys, boulders, and buildings accurately.

const BattleLayersScript = preload("res://scripts/battle/battle_layers.gd")
const LiveryScript = preload("res://scripts/livery.gd")
const SmokeVolumeScript = preload("res://scripts/smoke_volume.gd")
const WorldScaleScript = preload("res://scripts/world_scale.gd")

# SKIRMISH_PERF_TROUBLESHOOTING.md §12.6. Vision scans on a timer, not per frame.
# Visibility changing 2x a second is imperceptible and the scan is O(viewers x targets)
# per team. Was 0.3 s (= 3.33 Hz); doubled to 0.6 s (= 1.67 Hz) because the §12.1
# capture's `vision` section went 21 ms mean -> 56 ms mean after the cull landed
# and stopped hiding behind 4-7 fps render frames. Halving the per-second
# cost directly halves the per-second vision budget. The cache TTL (§_LOS_CACHE_TTL_MS
# below) was sized 2.5x against the OLD TICK_INTERVAL (0.75s / 0.3s = ~2.5 ticks);
# against the new interval it is now 1.25x, which is still warm across one
# TICK_INTERVAL and improves the hit rate rather than degrading it.
const TICK_INTERVAL := 0.6

# Height the LOS ray is cast at, so a unit in a shallow dip is not blindfolded by
# the lip of it.
#
# CORE_DESIGN_LANGUAGE.md §3.2: deliberately NOT scaled - this is an offset
# above a UNIT's own origin, and units are unit-space, fixed regardless of
# world_scale (the whole "environment scales, units don't" premise).
const EYE_HEIGHT := 1.5

# Higher ground sees further, capped so a mountain is not an all-seeing eye.
#
# CORE_DESIGN_LANGUAGE.md §3.2: these ARE world_scale=1.0 baselines -
# effective_vision() below scales them, unlike EYE_HEIGHT above. The
# elevation they read (terrain_height_at()) is real terrain Y, which
# already grows with world_scale (ground noise amplitude - Chunk 9 - and
# any heightmap's terrain.height_scale, both FIELD_SPEC-flagged). Left
# unscaled, a hill authored to just reach ELEVATION_CAP at world_scale=1
# would tower 16x higher at world_scale=16 while the cap stayed put, so
# the SAME relative hilltop would trip the cap at a small fraction of its
# climb instead of at the top - elevation bonus would stop meaning "you're
# on high ground" and start meaning "you're on ANY ground with the
# faintest slope." ELEVATION_CAP scales WITH world_scale (same relative
# hill still caps the bonus at the same relative height) and
# ELEVATION_BONUS_PER_UNIT scales INVERSELY (so the maximum total bonus at
# the cap - a balance number, not a distance - stays identical regardless
# of scale).
const ELEVATION_BONUS_PER_UNIT := 0.02
const ELEVATION_CAP := 12.0

# Reveal happens at plain vision range; something ALREADY visible only drops out
# past this multiple of it. The gap is a dead zone: without it a construct
# sitting exactly on the boundary flickers in and out every single tick as
# millimetre position deltas cross one threshold.
const HIDE_RANGE_MULT := 1.15

# PR-4 (2026-08-19). LOS result cache.
#
# The 22:54:40 capture: 25 ms mean per tick, 665 ticks. The dominant cost
# is the per-(viewer, target) LOS raycast in _is_spotted(), and the same
# pair re-tests hundreds of times in a row for the same answer - a unit
# that LOS checks at frame N is in the same place at frame N+30. Caching
# the result for `_LOS_CACHE_TTL_MS` cuts the raycast count by roughly
# `TTL / TICK_INTERVAL` = 0.75 seconds / 0.3 = ~2.5x on the existing
# 3.33 Hz TICK_INTERVAL, and more on the in-between ticks where the
# cache stays warm across multiple TICK_INTERVALs.
#
# The cache is invalidated on structure events (`invalidate_los_cache`, called
# from match_director on _place_structure / structure death). Since 2026-08-23
# that invalidation is REGION-scoped when the caller passes the event position:
# only pairs with an endpoint near the change re-raycast. It expires naturally
# on TTL otherwise. The cell granularity (`_LOS_CELL_SIZE`) is
# deliberately coarser than GRID_CELL: a unit that moved 2 m between
# cache writes still has the same cell, so the cache hit rate stays
# high during normal movement.
#
# TTL must be >= TICK_INTERVAL (750ms vs 300ms). The previous value of
# 250ms expired BEFORE the next tick, making the cache a no-op and
# re-raycasting every viewer×target pair every tick — the exact problem
# the cache was meant to solve. 750ms = 2.5× TICK_INTERVAL; a pair
# tested at tick N is still warm at tick N+1 and N+2.
const _LOS_CACHE_TTL_MS := 750
const _LOS_CELL_SIZE := 4.0
var _los_cache: Dictionary = {}
# Bumped on structure events. Included in the cache key so any entry written
# before the bump misses the next lookup - the wholesale clear that follows
# in `invalidate_los_cache` is just a defensive backup.
var _los_geom_version: int = 0
var _obstacles: Array = []
var _grid_heights: PackedFloat32Array = PackedFloat32Array()
var _grid_obstacles: PackedFloat32Array = PackedFloat32Array()

# SKIRMISH_PERF_TROUBLESHOOTING.md §12.6. Shroud resolution and the two dimmed
# states. Unexplored is opaque; explored is partly lifted and never returns to
# full black once seen.
#
# §12.6 made this 6.0 m (was 4.0 m). The 4 m resolution was a screen-space fog
# convention from the era when the shroud was a flat plane and needed fine
# subdivision to avoid the "stair-step" edge as a unit walked a vision boundary.
# Since §11 the shroud is a fullscreen depth-buffer pass (see the SHROUD IS
# SCREEN-SPACE block below), so the per-cell resolution no longer drives edge
# appearance; the cells are only the buckets the visibility logic writes into.
# Coarsening to 6 m drops per-viewer cell count from 729 to ~441 (a viewer with
# 50 m vision covers a 13x13 box at 4 m vs 9x9 at 6 m), saving ~40% of the
# _update_shroud scan. The shroud image is 120x120 -> 80x80 on lake_crossing;
# the minimap re-samples it (its own texture, see hud_minimap.gd) so the
# change is invisible to the player.
const GRID_CELL := 6.0
# Playtest: "the VISION needs to be brighter in comparison to the non-visible
# parts of the explored map." Currently-visible ground is alpha 0 - fully clear,
# and already as bright as the terrain itself gets - so the contrast has to come
# from the other end: explored-but-not-currently-visible is dimmed harder.
# Raised 0.55 -> 0.74, which keeps remembered terrain legible (that is the whole
# point of explored state persisting) while making the lit, actively-seen area
# read as unmistakably the live one.
const EXPLORED_ALPHA := 0.74
const UNEXPLORED_ALPHA := 1.0
# THE SHROUD IS SCREEN-SPACE, and this is its third design. The history is
# worth keeping because each step failed for a reason the next one had to fix:
#
#   1. A flat plane. Had to sit above the HIGHEST ground anywhere on the map or
#      hilltops rendered through it. Fine while maps were nearly flat.
#   2. A mesh conforming to height_at() at a small local clearance, because (1)
#      left the fog floating like a ceiling over every low-lying area once maps
#      had real hills and ravines.
#
# (2) fixed the terrain, but a sheet lying ON the ground can only ever hide the
# ground. Anything TALLER than its clearance punches straight through, and the
# terrain layer is now full of exactly that: trees, boulders, rock spires,
# cliff facades, buildings, resource nodes. The playtest report - fog "only
# covers the base ground" - is that geometry, not a bug in the sheet.
#
# Raising the sheet cannot fix it. Any clearance high enough to cover the
# tallest prop is a ceiling again, and the cure re-introduces (1).
#
# So the fog is no longer geometry in the world at all. It is a fullscreen pass
# that reads the depth buffer, reconstructs each pixel's world position, and
# looks that up in the same shroud texture as before. Whatever is nearest the
# camera at that pixel gets fogged, at any height - ground, a tree's canopy, a
# cliff face, a unit - because the test is "where is this pixel in the world",
# not "is this pixel under the sheet".
#
# Two consequences worth knowing:
#   - The conforming mesh, and with it the per-map shroud mesh build, is gone.
#     One quad replaces a grid that spanned the entire map.
#   - Sky pixels are skipped (nothing was drawn there to fog), so the horizon
#     stays clear instead of the fog climbing up it.
const SHROUD_SHADER := """
shader_type spatial;
render_mode unshaded, blend_mix, cull_disabled, depth_draw_never, depth_test_disabled, shadows_disabled, fog_disabled;

// repeat_disable matters: a pixel off the edge of the map produces a UV
// outside 0..1, and with repeat on that wraps to fog from the opposite side.
uniform sampler2D shroud_tex : hint_default_black, filter_linear, repeat_disable;
uniform sampler2D depth_tex : hint_depth_texture, filter_nearest;
uniform float map_half = 80.0;
uniform vec3 fog_color = vec3(0.015, 0.015, 0.02);

void vertex() {
	// Drive clip space directly so the quad covers the viewport wherever the
	// instance happens to sit in the scene tree. QuadMesh spans -0.5..0.5, so
	// x2 fills -1..1. z = 1.0 is the near plane under Godot's reverse-Z, which
	// with depth_test_disabled just guarantees it is never clipped away.
	POSITION = vec4(VERTEX.xy * 2.0, 1.0, 1.0);
}

void fragment() {
	float d = texture(depth_tex, SCREEN_UV).r;
	// Both extremes are rejected on purpose, rather than just the far plane.
	// One of them IS the far plane - the sky, where nothing was drawn and
	// fogging would paint a grey wall up the horizon - but WHICH one depends
	// on whether the renderer is using reverse-Z, and that is a detail of the
	// engine build rather than something this shader should encode. Nothing
	// legitimately renders exactly at the near plane either, so discarding
	// both is correct under either convention.
	if (d <= 0.000001 || d >= 0.999999) {
		discard;
	}
	vec3 ndc = vec3(SCREEN_UV * 2.0 - 1.0, d);
	vec4 view = INV_PROJECTION_MATRIX * vec4(ndc, 1.0);
	view.xyz /= view.w;
	vec3 world = (INV_VIEW_MATRIX * vec4(view.xyz, 1.0)).xyz;
	vec2 uv = (world.xz + vec2(map_half)) / (2.0 * map_half);
	// Off the edge of the map there is no fog state to read.
	if (uv.x < 0.0 || uv.x > 1.0 || uv.y < 0.0 || uv.y > 1.0) {
		discard;
	}
	ALBEDO = fog_color;
	ALPHA = texture(shroud_tex, uv).a;
}
"""

var _controller: Node = null
var _local_team: int = 0
var reveal_all: bool = false

# viewing team -> { instance_id: true }. One set per team rather than one flag
# per construct: a single flag can only describe ONE side's knowledge, which left
# the AI with no visibility gate at all while the player had one. Vision is a
# TEAM property - if a scout sees it, the artillery on the far side of the map
# may shoot it - so it needs a per-team answer.
var _team_visible: Dictionary = {}

var _beacons: Array = []

# Increments whenever the shroud image actually changes. See _update_shroud().
var shroud_version: int = 0

var _half: float = 80.0
var _dim: int = 0
var _image: Image = null
var _texture: ImageTexture = null
# CORE_DESIGN_LANGUAGE.md §3.2: scales the shroud grid cell (below) and the
# elevation-bonus constants (effective_vision()) - see GRID_CELL and
# ELEVATION_CAP's own comments for why each needs it.
var _world_scale: float = 1.0


func setup(controller: Node, local_team: int, map_half_extents: float, world_scale: float = 1.0) -> void:
	_controller = controller
	_local_team = local_team
	_half = map_half_extents
	_world_scale = world_scale
	# Same self-bounding fix as flow_field.gd's BASE_CELL_SIZE: left flat,
	# the shroud IMAGE would grow O(world_scale^2) as _half grows with it -
	# the "77MB fog image" the plan's own cost table warns about. Scaling
	# the cell alongside _half keeps _dim (and image memory) roughly
	# constant regardless of world_scale.
	_dim = maxi(1, int(ceil((_half * 2.0) / _cell_size())))
	_image = Image.create(_dim, _dim, false, Image.FORMAT_RGBA8)
	_image.fill(Color(0, 0, 0, UNEXPLORED_ALPHA))
	_texture = ImageTexture.create_from_image(_image)
	_grid_heights.resize(_dim * _dim)
	_grid_obstacles.resize(_dim * _dim)
	var cell_sz := _cell_size()
	for gz in range(_dim):
		var wz := -_half + (gz + 0.5) * cell_sz
		for gx in range(_dim):
			var wx := -_half + (gx + 0.5) * cell_sz
			_grid_heights[gz * _dim + gx] = _get_terrain_y(wx, wz)
	_refresh_obstacles()


# The shroud plane. Returned rather than self-parented so the director owns the
# scene tree and this owns the rules.
func build_shroud() -> MeshInstance3D:
	var inst := MeshInstance3D.new()
	inst.name = "FogShroud"
	inst.mesh = QuadMesh.new()
	# The vertex shader writes POSITION directly, so this instance's transform
	# never reaches the rasterizer - but the CULLER still uses its AABB, and a
	# unit quad parked at the origin is culled the moment the camera looks away
	# from it, taking the whole fog pass with it. An AABB larger than any map
	# keeps it permanently in frame.
	inst.custom_aabb = AABB(Vector3(-1e6, -1e6, -1e6), Vector3(2e6, 2e6, 2e6))
	inst.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var shader := Shader.new()
	shader.code = SHROUD_SHADER
	var mat := ShaderMaterial.new()
	mat.shader = shader
	mat.set_shader_parameter("shroud_tex", _texture)
	mat.set_shader_parameter("map_half", _half)
	# Last of the transparent pass. Water and the shallow-water markers are
	# transparent too, and the fog has to land on top of them rather than
	# underneath.
	mat.render_priority = 127
	inst.material_override = mat
	return inst


# The live fog image: alpha 0 where currently seen, EXPLORED_ALPHA where seen
# before, UNEXPLORED_ALPHA where never seen. Exposed so the minimap can shade
# itself from the SAME source the world shroud uses, rather than keeping a
# second copy of the rules that could drift out of step with this one.
func shroud_image() -> Image:
	return _image


# --- Queries -----------------------------------------------------------------

# How far `o` can see from where it is standing. Flying units skip the elevation
# bonus - they are already up, and stacking altitude on altitude is double-
# counting the same advantage.
func effective_vision(o) -> float:
	var vision: float = float(_get_prop(o, "vision_range", 0.0))
	if bool(_get_prop(o, "is_flying", false)):
		return vision
	var elevation := 0.0
	if _controller != null and _controller.has_method("terrain_height_at"):
		elevation = _controller.terrain_height_at(_pos_of(o))
	var cap := ELEVATION_CAP * _world_scale
	var bonus_per_unit := ELEVATION_BONUS_PER_UNIT / _world_scale
	return vision * (1.0 + minf(elevation, cap) * bonus_per_unit)


# Can `viewing_team` see `c` right now?
#
# FAILS OPEN before the first scan. A closed default would make every weapon in
# the game refuse to fire until the first fog tick landed - a far louder and more
# confusing failure than one tick of over-sharing on a map nobody has moved on.
const DebugSettingsScript = preload("res://scripts/debug_settings.gd")

func _reveal_all_cheat() -> bool:
	var ds = DebugSettingsScript.get_active()
	return ds != null and ds.reveal_all_fog


func is_visible_to_team(c, viewing_team: int) -> bool:
	if c == null or not is_instance_valid(c):
		return false
	if reveal_all or _reveal_all_cheat():
		return true
	var c_team: int = c.get_meta("team") if c.has_meta("team") else -1
	if c_team == viewing_team:
		return true
	if not _team_visible.has(viewing_team):
		return true
	return _team_visible[viewing_team].has(c.get_instance_id())


# PR-4 (2026-08-19), reworked 2026-08-23 after the skirmish playtest whose log
# showed vision at 394 ms mean per tick late-game: the old WHOLESALE wipe (every
# cache entry dropped, every shroud disc rescanned) ran once per structure event,
# and that match built 104 structures - each wipe landing exactly when construct
# counts made a full rescan most expensive.
#
# Now the caller passes WHERE geometry changed:
#   - LOS cache: only entries whose either endpoint sits in the dirty region
#     miss. Entries written AFTER the region was recorded stay valid even inside
#     it (regions carry their timestamp and are pruned once older than any live
#     cache line could be).
#   - Shroud discs: a sightline to a cell can only cross obstacles within the
#     viewer's reach of that cell, so a viewer farther than reach+event_radius
#     from the change cannot see any difference. Only discs that close rescan.
# A null position falls back to the old conservative behaviour.
func invalidate_los_cache(pos = null, radius: float = 0.0) -> void:
	_refresh_obstacles()
	if pos == null:
		_los_geom_version += 1
		_los_cache.clear()
		_los_dirty_regions.clear()
		_drop_all_discs()
		return
	var cell_r := int(ceil(radius / _LOS_CELL_SIZE))
	var cx := int(floor(pos.x / _LOS_CELL_SIZE))
	var cz := int(floor(pos.z / _LOS_CELL_SIZE))
	_los_dirty_regions.append({
		"x0": cx - cell_r, "x1": cx + cell_r,
		"z0": cz - cell_r, "z1": cz + cell_r,
		"at_ms": Time.get_ticks_msec(),
	})
	_prune_los_regions(Time.get_ticks_msec())
	# Drop shroud discs (with their cell refcounts) for viewers that could see
	# the changed ground; they rebuild on the next tick.
	var slack := radius + _cell_size() * 2.0
	for oid in _viewer_discs.keys():
		var disc: Dictionary = _viewer_discs[oid]
		if Vector3(disc.pos.x, 0.0, disc.pos.z).distance_to(Vector3(pos.x, 0.0, pos.z)) \
				<= float(disc.vision) + slack:
			_release_cells(disc.cells)
			_viewer_discs.erase(oid)
	for uid in _beacon_discs.keys():
		var bd: Dictionary = _beacon_discs[uid]
		if Vector3(bd.pos.x, 0.0, bd.pos.z).distance_to(Vector3(pos.x, 0.0, pos.z)) \
				<= float(bd.radius) + slack:
			_release_cells(bd.cells)
			_beacon_discs.erase(uid)


# Regions outlive every cache entry they could invalidate: entries expire after
# _LOS_CACHE_TTL_MS, so a region older than TTL plus one tick of slack cannot
# flip any live result. Pruned lazily here rather than per-lookup.
const _LOS_REGION_RETENTION_MS := _LOS_CACHE_TTL_MS + 1500

var _los_dirty_regions: Array = []


func _prune_los_regions(now_ms: int) -> void:
	if _los_dirty_regions.is_empty():
		return
	var cutoff := now_ms - _LOS_REGION_RETENTION_MS
	for i in range(_los_dirty_regions.size() - 1, -1, -1):
		if int(_los_dirty_regions[i].at_ms) < cutoff:
			_los_dirty_regions.remove_at(i)


# True when a cached pair must be considered stale against this region set:
# either endpoint sits inside a region that predates the entry, OR the segment
# BETWEEN the endpoints clips one. The second case matters - an occluder placed
# between two far-apart constructs changes their LOS while neither endpoint
# moves, which is precisely the stale answer regions exist to catch. Segment
# vs rectangle is a Liang-Barsky slab clip, a handful of compares; conservative
# over-flagging just costs one re-raycast.
func _pair_in_dirty_region(a: Vector2i, b: Vector2i, written_at: int) -> bool:
	for r in _los_dirty_regions:
		if written_at >= int(r.at_ms):
			continue
		if (a.x >= r.x0 and a.x <= r.x1 and a.y >= r.z0 and a.y <= r.z1) \
				or (b.x >= r.x0 and b.x <= r.x1 and b.y >= r.z0 and b.y <= r.z1):
			return true
		var dx := float(b.x - a.x)
		var dy := float(b.y - a.y)
		var t0 := 0.0
		var t1 := 1.0
		var clipped := true
		for i in range(4):
			var p: float
			var q: float
			if i == 0:
				p = -dx; q = float(a.x - r.x0)
			elif i == 1:
				p = dx; q = float(r.x1 - a.x)
			elif i == 2:
				p = -dy; q = float(a.y - r.z0)
			else:
				p = dy; q = float(r.z1 - a.y)
			if absf(p) < 0.000001:
				if q < 0.0:
					clipped = false
					break
			else:
				var t := q / p
				if p < 0.0:
					t0 = maxf(t0, t)
				else:
					t1 = minf(t1, t)
				if t0 > t1:
					clipped = false
					break
		if clipped:
			return true
	return false


# Illumination ammo and sensor beacons. A flare is simply a stationary observer
# owned by the team that fired it, so it folds into the same scan rather than
# getting a parallel visibility path.
#
# Deliberately no line-of-sight requirement: a flare lights an area from above,
# which is the entire reason you fire one over a ridge you cannot see behind.
func reveal_area(for_team: int, pos: Vector3, radius: float, duration: float) -> void:
	_beacons.append({
		"pos": pos, "radius": radius, "team": for_team,
		"expires_at": Time.get_ticks_msec() + int(duration * 1000.0),
		# Stable identity so the shroud can cache the beacon's visibility disc
		# and drop it exactly once when the flare burns out.
		"uid": _next_beacon_uid,
	})
	_next_beacon_uid += 1


func _live_beacons(viewing_team: int) -> Array:
	var now := Time.get_ticks_msec()
	var mine: Array = []
	var kept: Array = []
	for b in _beacons:
		if b.expires_at <= now:
			continue
		kept.append(b)
		if b.team == viewing_team:
			mine.append(b)
	_beacons = kept
	return mine


# --- The scan ----------------------------------------------------------------

func tick() -> void:
	var by_team: Dictionary = {}
	for c in _all_constructs():
		var t: int = c.get_meta("team") if c.has_meta("team") else -1
		if not by_team.has(t):
			by_team[t] = []
		by_team[t].append(c)

	var next: Dictionary = {}
	for viewing_team in by_team:
		var viewers: Array = []
		var targets: Array = []
		for t in by_team:
			if t == viewing_team:
				viewers += by_team[t]
			else:
				targets += by_team[t]
		var beacons := _live_beacons(viewing_team)
		var previous: Dictionary = _team_visible.get(viewing_team, {})
		var seen: Dictionary = {}
		for c in targets:
			if not is_instance_valid(c):
				continue
			# Hysteresis needs THIS team's own previous answer. For a non-local
			# team that cannot come off a shared flag, which is the second reason
			# visibility is stored per team.
			var was_visible: bool = previous.has(c.get_instance_id())
			if reveal_all or _is_spotted(c, viewers, beacons, was_visible):
				seen[c.get_instance_id()] = true
		next[viewing_team] = seen
	_team_visible = next

	# The local team's answer additionally drives rendering.
	var local_seen: Dictionary = _team_visible.get(_local_team, {})
	var local_constructs: Array = []
	for c in _all_constructs():
		var t: int = c.get_meta("team") if c.has_meta("team") else -1
		if t == _local_team:
			local_constructs.append(c)
		elif c.has_method("set_fog_visible"):
			c.set_fog_visible(reveal_all or local_seen.has(c.get_instance_id()))
	_update_shroud(local_constructs, _live_beacons(_local_team))


func _pos_of(n: Node) -> Vector3:
	if not is_instance_valid(n):
		return Vector3.ZERO
	if n is Node3D:
		return n.global_position if n.is_inside_tree() else n.position
	return Vector3.ZERO


func _forward_of(n: Node) -> Vector3:
	if not is_instance_valid(n) or not (n is Node3D):
		return Vector3.FORWARD
	var b: Basis = n.global_transform.basis if n.is_inside_tree() else n.transform.basis
	return -b.z.normalized()


func _get_prop(o: Object, prop: String, default_val = null):
	if o == null or not is_instance_valid(o):
		return default_val
	var v = o.get(prop)
	if v != null:
		return v
	if o.has_meta(prop):
		return o.get_meta(prop)
	return default_val


func _is_spotted(c, viewers: Array, beacons: Array, was_visible: bool) -> bool:
	var c_flying: bool = bool(_get_prop(c, "is_flying", false))
	var c_moving: bool = false
	var vel = _get_prop(c, "velocity")
	if vel is Vector3:
		c_moving = vel.length() > 0.2
	elif bool(_get_prop(c, "is_moving", false)):
		c_moving = true

	var c_pos := _pos_of(c)

	for o in viewers:
		if not is_instance_valid(o):
			continue

		var o_pos := _pos_of(o)

		# 1. Seismic Sensing: Non-line-of-sight ground vibration sensing
		var seismic: float = float(_get_prop(o, "seismic_range", 0.0))
		if seismic > 0.0 and not c_flying and c_moving:
			var reach_seis := seismic * HIDE_RANGE_MULT if was_visible else seismic
			if c_pos.distance_to(o_pos) <= reach_seis:
				return true

		# 2. Check Directional Radar Sensors (focused sector reach)
		var dir_sensors = _get_prop(o, "directional_sensors")
		if dir_sensors is Array and not dir_sensors.is_empty():
			var fwd := _forward_of(o)
			var fwd_2d := Vector2(fwd.x, fwd.z).normalized()
			for ds in dir_sensors:
				var ds_range: float = float(ds.get("range", 0.0))
				var ds_arc_rad: float = float(ds.get("arc_rad", PI / 3.0))
				var ds_reach := ds_range * HIDE_RANGE_MULT if was_visible else ds_range
				var to_c: Vector3 = c_pos - o_pos
				var dist: float = to_c.length()
				if dist <= ds_reach and dist > 0.001:
					var to_c_2d := Vector2(to_c.x, to_c.z).normalized()
					var dot_val := clampf(fwd_2d.dot(to_c_2d), -1.0, 1.0)
					var angle := acos(dot_val)
					if angle <= ds_arc_rad * 0.5:
						var o_flying: bool = bool(_get_prop(o, "is_flying", false))
						if o_flying or c_flying:
							return true
						var has_thermal: bool = bool(_get_prop(o, "has_thermal_sight", false)) or \
							(is_instance_valid(o.get("hull_node")) and o.hull_node.has_meta("has_thermal_sight") and o.hull_node.get_meta("has_thermal_sight"))
						if _check_los_cached(o, c, has_thermal):
							return true

		# 3. Standard Omni Vision (and Thermal FLIR Sight)
		var vision := effective_vision(o)
		if vision > 0.0:
			var reach := vision * HIDE_RANGE_MULT if was_visible else vision
			if c_pos.distance_to(o_pos) <= reach:
				var o_flying: bool = bool(_get_prop(o, "is_flying", false))
				if o_flying or c_flying:
					return true
				var has_thermal: bool = bool(_get_prop(o, "has_thermal_sight", false)) or \
					(is_instance_valid(o.get("hull_node")) and o.hull_node.has_meta("has_thermal_sight") and o.hull_node.get_meta("has_thermal_sight"))
				if _check_los_cached(o, c, has_thermal):
					return true

	for b in beacons:
		if c_pos.distance_to(b.pos) <= b.radius:
			return true
	return false


func _check_los_cached(o: Node, c: Node, has_thermal: bool) -> bool:
	var o_pos := _pos_of(o)
	var c_pos := _pos_of(c)
	# Endpoint cells are computed up front (not parsed back out of the key) so
	# the dirty-region test below stays a couple of integer compares.
	var o_cell := Vector2i(int(floor(o_pos.x / _LOS_CELL_SIZE)), int(floor(o_pos.z / _LOS_CELL_SIZE)))
	var c_cell := Vector2i(int(floor(c_pos.x / _LOS_CELL_SIZE)), int(floor(c_pos.z / _LOS_CELL_SIZE)))
	var key := "%d:%d:%d:%d:%d:%d:%d:%d" % [
		_los_geom_version,
		o.get_instance_id(), c.get_instance_id(),
		o_cell.x, o_cell.y,
		c_cell.x, c_cell.y,
		1 if has_thermal else 0,
	]
	var now := Time.get_ticks_msec()
	if _los_cache.has(key):
		var entry: Dictionary = _los_cache[key]
		if entry.expires_at > now \
				and not _pair_in_dirty_region(o_cell, c_cell, int(entry.get("written_at", 0))):
			return entry.result
	var visible: bool = _has_line_of_sight(o_pos, c_pos, has_thermal)
	_los_cache[key] = {"result": visible, "expires_at": now + _LOS_CACHE_TTL_MS, "written_at": now}
	return visible


func _refresh_obstacles() -> void:
	_obstacles.clear()
	if _grid_obstacles.size() != _dim * _dim:
		_grid_obstacles.resize(_dim * _dim)
	_grid_obstacles.fill(-9999.0)
	if _controller == null:
		return
	var map_def: Dictionary = _controller.get("current_map") if "current_map" in _controller else {}
	if map_def.is_empty() and _controller.has_method("get_current_map"):
		map_def = _controller.get_current_map()

	for obs in map_def.get("obstacles", []):
		var c = obs.get("center", [0, 0, 0])
		var cx: float = float(c.x if c is Vector3 or c is Vector2 else (c[0] if c is Array else 0.0))
		var cz: float = float(c.z if c is Vector3 else (c.y if c is Vector2 else (c[2] if c is Array and c.size() > 2 else (c[1] if c is Array else 0.0))))
		var he = obs.get("half_extents", [4, 4])
		var hx: float = float(he.x if he is Vector2 or he is Vector3 else (he[0] if he is Array else 4.0))
		var hz: float = float(he.y if he is Vector2 else (he.z if he is Vector3 else (he[1] if he is Array else 4.0)))
		var o_type = obs.get("type", "rock")
		var base_y := _get_terrain_y(cx, cz)
		var col_h := 3.0 * _world_scale
		if o_type == "building":
			col_h = float(obs.get("building_height", 4.0 * _world_scale))
		elif o_type == "fortification":
			col_h = float(obs.get("building_height", 3.2 * _world_scale))
		elif o_type == "relay":
			col_h = 5.0 * _world_scale
		elif o_type == "depot":
			col_h = 2.4 * _world_scale
		elif o_type == "crater":
			col_h = 1.8 * _world_scale
		var top_y := base_y + col_h
		var obs_entry := {
			"x0": cx - hx, "x1": cx + hx,
			"z0": cz - hz, "z1": cz + hz,
			"base_y": base_y, "top_y": top_y,
		}
		_obstacles.append(obs_entry)

		var min_c := _world_to_cell(obs_entry.x0, obs_entry.z0)
		var max_c := _world_to_cell(obs_entry.x1, obs_entry.z1)
		for gz in range(clampi(min_c.y, 0, _dim - 1), clampi(max_c.y, 0, _dim - 1) + 1):
			for gx in range(clampi(min_c.x, 0, _dim - 1), clampi(max_c.x, 0, _dim - 1) + 1):
				var idx := gz * _dim + gx
				_grid_obstacles[idx] = maxf(_grid_obstacles[idx], top_y)

	if _controller.is_inside_tree():
		for s in _controller.get_tree().get_nodes_in_group("damageable"):
			if not is_instance_valid(s):
				continue
			if "is_dead" in s and s.is_dead:
				continue
			if s is StaticBody3D and ("footprint" in s or s.has_meta("is_building") or "kind" in s):
				var spos: Vector3 = _pos_of(s)
				var fp: Vector3 = s.footprint if "footprint" in s else Vector3(4, 3, 4)
				var hx: float = fp.x * 0.5
				var hz: float = fp.z * 0.5
				var h: float = fp.y
				var top_y := spos.y + h
				var struct_entry := {
					"x0": spos.x - hx, "x1": spos.x + hx,
					"z0": spos.z - hz, "z1": spos.z + hz,
					"base_y": spos.y, "top_y": top_y,
				}
				_obstacles.append(struct_entry)
				var min_c := _world_to_cell(struct_entry.x0, struct_entry.z0)
				var max_c := _world_to_cell(struct_entry.x1, struct_entry.z1)
				for gz in range(clampi(min_c.y, 0, _dim - 1), clampi(max_c.y, 0, _dim - 1) + 1):
					for gx in range(clampi(min_c.x, 0, _dim - 1), clampi(max_c.x, 0, _dim - 1) + 1):
						var idx := gz * _dim + gx
						_grid_obstacles[idx] = maxf(_grid_obstacles[idx], top_y)


func _get_terrain_y(x: float, z: float) -> float:
	if _controller != null and _controller.has_method("terrain_height_at"):
		return _controller.terrain_height_at(Vector3(x, 0.0, z))
	return 0.0


func _has_cell_los(from_eye: Vector3, to_target: Vector3, is_flying: bool = false) -> bool:
	if is_flying:
		return true
	var dx := to_target.x - from_eye.x
	var dz := to_target.z - from_eye.z
	var dist_sq := dx * dx + dz * dz
	var cell_sz := _cell_size()
	if dist_sq <= cell_sz * cell_sz * 1.5:
		return true

	var dist := sqrt(dist_sq)
	var step_dist := cell_sz * 0.6
	var num_steps := int(dist / step_dist)
	if num_steps <= 1:
		return true

	var dy := to_target.y - from_eye.y
	var tolerance := 0.4 * _world_scale
	for s in range(1, num_steps):
		var t := float(s) / float(num_steps)
		var sx := from_eye.x + dx * t
		var sz := from_eye.z + dz * t
		var ray_y := from_eye.y + dy * t

		var cell := _world_to_cell(sx, sz)
		if cell.x < 0 or cell.x >= _dim or cell.y < 0 or cell.y >= _dim:
			continue
		var idx := cell.y * _dim + cell.x

		# 1. Terrain elevation occlusion
		var gy := _grid_heights[idx] if _grid_heights.size() == _dim * _dim else _get_terrain_y(sx, sz)
		if gy > ray_y + tolerance:
			return false

		# 2. Obstacle / structure bounding occlusion
		var obs_y := _grid_obstacles[idx] if _grid_obstacles.size() == _dim * _dim else -9999.0
		if obs_y > ray_y:
			return false

	return true


func _has_line_of_sight(from_pos: Vector3, to_pos: Vector3, ignore_smoke: bool = false) -> bool:
	if _controller == null or not _controller.is_inside_tree():
		return true
	var space: PhysicsDirectSpaceState3D = _controller.get_world_3d().direct_space_state
	var from_eye := from_pos + Vector3(0, EYE_HEIGHT, 0)
	var to_eye := to_pos + Vector3(0, EYE_HEIGHT, 0)
	var query := PhysicsRayQueryParameters3D.create(from_eye, to_eye)
	var mask: int = BattleLayersScript.TERRAIN | BattleLayersScript.BUILDINGS
	if not ignore_smoke:
		mask += SmokeVolumeScript.SMOKE_COLLISION_LAYER
	query.collision_mask = mask
	query.collide_with_areas = not ignore_smoke
	if not space.intersect_ray(query).is_empty():
		return false
	return _has_cell_los(from_eye, to_eye, false)


func _faction_of(c) -> String:
	if "faction" in c and c.faction != "":
		return c.faction
	if "hull_node" in c and is_instance_valid(c.hull_node) and c.hull_node.has_meta("faction"):
		return c.hull_node.get_meta("faction")
	return LiveryScript.PLAYER_ID


func _all_constructs() -> Array:
	if _controller == null or not _controller.is_inside_tree():
		return []
	var out: Array = []
	for c in _controller.get_tree().get_nodes_in_group("damageable"):
		if not is_instance_valid(c):
			continue
		# `damageable` is a TREE-WIDE group and this service does not own who joins
		# it. Reading .is_dead off whatever is in there crashed the whole scan the
		# moment something joined without one - which is not hypothetical: it is
		# how the vision suite first failed, on a node another suite had left
		# behind. A construct that cannot say whether it is alive is not a thing
		# vision has an opinion about, so it is skipped rather than assumed.
		if not ("is_dead" in c) or c.is_dead:
			continue
		if not c.has_meta("team"):
			continue
		out.append(c)
	return out


# --- Shroud ------------------------------------------------------------------

# The resolved (world_scale-scaled) shroud cell size, matching setup()'s
# own _dim computation. Every spatial use of GRID_CELL must go through this,
# not the raw constant - a mismatch between how the shroud IMAGE is sized
# and how world positions are mapped INTO it produces exactly the "strange
# patches exposed and not exposed" bug this comment is here to prevent a
# repeat of (GRID_CELL was scaled here in setup() but not in the three
# other places that convert world position to a cell index, so vision
# writes landed in different cells than the shroud reader expected).
func _cell_size() -> float:
	return GRID_CELL * _world_scale

func _world_to_cell(x: float, z: float) -> Vector2i:
	var cell := _cell_size()
	return Vector2i(int(floor((x + _half) / cell)), int(floor((z + _half) / cell)))


# SHROUD, INCREMENTAL (2026-08-23). The skirmish playtest log
# (battle_2026-08-24T00-33-21, vision mean 22 ms -> 394 ms across four quarters)
# showed why "rescan every viewer whenever anything moved" cannot survive a
# mature base: with 104 structures + 25 units EVERY construct is a viewer, and
# ~130 discs x ~440 cells x grid-march each is hundreds of milliseconds of
# GDScript every 0.6 s tick. So the shroud keeps ONE cached visibility disc per
# viewer plus a per-cell reference count across overlapping discs. A viewer
# rescans only when ITS OWN inputs changed - moved >0.5 m, turned >~14 degrees,
# vision range / flying flag / sensors changed, died, or invalidate_los_cache()
# dropped its disc because geometry changed within its reach. Structures never
# move, so a developed base costs one dictionary compare per structure per tick.
# Pixels are rewritten only on 0<->1 coverage transitions (see acquire/release),
# which replaces the old whole-set diff against _prev_cells.
func _update_shroud(local_constructs: Array, beacons: Array) -> void:
	if _texture == null:
		return
	_shroud_dirty = false
	var geo := _los_geom_version
	var seen_ids := {}
	var cell_size := _cell_size()

	for o in local_constructs:
		if not is_instance_valid(o):
			continue
		var oid: int = o.get_instance_id()
		seen_ids[oid] = true
		var o_pos := _pos_of(o)
		var o_fwd := _forward_of(o)
		var o_flying: bool = bool(_get_prop(o, "is_flying", false))
		var v := effective_vision(o)
		var dir_sensors = _get_prop(o, "directional_sensors")
		var has_dir: bool = dir_sensors is Array and not (dir_sensors as Array).is_empty()
		var topo_r: float = float(_get_prop(o, "topographic_range", 0.0))

		var disc: Dictionary = _viewer_discs.get(oid, {})
		# Fingerprint keeps the old _inputs_unchanged quantisation (0.5 m steps,
		# ~14-degree heading buckets) and extends it to everything else the
		# disc depends on - including vision RANGE, which the old fast path
		# never checked, so a stripped sensor module used to keep its old
		# radius until the unit happened to walk.
		var same: bool = not disc.is_empty() \
				and int(disc.geo) == geo \
				and absf(v - float(disc.vision)) < 0.05 \
				and bool(disc.is_flying) == o_flying \
				and bool(disc.has_dir) == has_dir \
				and int(o_pos.x * 2.0) == int(disc.pos.x * 2.0) \
				and int(o_pos.y * 2.0) == int(disc.pos.y * 2.0) \
				and int(o_pos.z * 2.0) == int(disc.pos.z * 2.0) \
				and int(o_fwd.x * 4.0) == int(disc.fwd.x * 4.0) \
				and int(o_fwd.z * 4.0) == int(disc.fwd.z * 4.0)
		if same:
			continue

		if not disc.is_empty():
			_release_cells(disc.cells)
		var cells := {}
		if v > 0.0:
			cells = _scan_viewer_cells(o_pos, v, o_flying)
		if has_dir:
			# Directional sensors add sector-clipped discs on top of the omni
			# one; both land in the same refcounted cell set.
			var fwd_2d := Vector2(o_fwd.x, o_fwd.z).normalized()
			for ds in dir_sensors:
				var ds_r: float = float(ds.get("range", 0.0))
				if ds_r > 0.0:
					var sub := _scan_viewer_cells(
						o_pos, ds_r, o_flying, fwd_2d, float(ds.get("arc_rad", PI / 3.0)))
					for k in sub:
						cells[k] = true
		_viewer_discs[oid] = {
			"cells": cells, "geo": geo, "pos": o_pos, "fwd": o_fwd,
			"vision": v, "is_flying": o_flying, "has_dir": has_dir,
		}
		_acquire_cells(cells)

		# Topographic survey mapping rides along with the rebuild. Like the
		# disc itself, it can only uncover something new when the scanner
		# moved or its range changed - terrain does not move under it.
		if topo_r > 0.0:
			var t_radius := int(ceil(topo_r / cell_size)) + 1
			var t0 := _world_to_cell(o_pos.x, o_pos.z)
			for dz in range(-t_radius, t_radius + 1):
				var gz := t0.y + dz
				if gz < 0 or gz >= _dim:
					continue
				for dx in range(-t_radius, t_radius + 1):
					var gx := t0.x + dx
					if gx < 0 or gx >= _dim:
						continue
					var cc := Vector2i(gx, gz)
					if _cell_refs.has(cc):
						continue
					var wx := -_half + (gx + 0.5) * cell_size
					var wz := -_half + (gz + 0.5) * cell_size
					if Vector2(wx - o_pos.x, wz - o_pos.z).length() <= topo_r:
						var cur_col := _image.get_pixel(gx, gz)
						if cur_col.a >= UNEXPLORED_ALPHA - 0.01:
							_image.set_pixel(gx, gz, Color(0, 0, 0, EXPLORED_ALPHA))
							_shroud_dirty = true

	# Sweep discs whose construct vanished this tick (death, despawn). Their
	# cells MUST be released or the coverage leaks as a permanently-visible
	# blob where the wreck used to stand.
	for oid in _viewer_discs.keys():
		if not seen_ids.has(oid):
			_release_cells(_viewer_discs[oid].cells)
			_viewer_discs.erase(oid)

	# Flares: transient omni discs keyed by uid, released when the live beacon
	# list stops carrying theirs (burnout or prune in _live_beacons).
	var live_uids := {}
	for b in beacons:
		var uid: int = int(b.get("uid", 0))
		live_uids[uid] = true
		if not _beacon_discs.has(uid):
			var cells := _scan_viewer_cells(b.pos, float(b.radius), true)
			_beacon_discs[uid] = {"cells": cells, "pos": b.pos, "radius": b.radius}
			_acquire_cells(cells)
	for uid in _beacon_discs.keys():
		if not live_uids.has(uid):
			_release_cells(_beacon_discs[uid].cells)
			_beacon_discs.erase(uid)

	if _shroud_dirty:
		_texture.update(_image)
		# Bumped only on a real change so readers that keep a derived copy (the
		# minimap builds a re-shaded one) can skip rebuilding on the many ticks
		# where nothing uncovered a new cell.
		shroud_version += 1


# Per-viewer cached visibility discs. Keyed by instance_id (constructs) and
# beacon uid (flares). Swept every tick against who is actually alive, so a
# recycled instance_id can never inherit a dead node's disc.
var _viewer_discs: Dictionary = {}
var _beacon_discs: Dictionary = {}
var _next_beacon_uid: int = 1
# Vector2i cell -> how many live discs claim it. The authoritative "currently
# visible" set is the key set; the image pixels mirror it on transitions.
var _cell_refs: Dictionary = {}
var _shroud_dirty: bool = false


# One viewer's visibility disc: every shroud cell within `reach` that survives
# the grid LOS march from the viewer's eye point. Directional callers pass an
# arc to clip to their sensor sector. Pure w.r.t. world state, which is what
# makes caching the result sound.
func _scan_viewer_cells(pos: Vector3, reach: float, is_flying: bool,
		fwd_2d: Vector2 = Vector2.ZERO, arc_rad: float = TAU) -> Dictionary:
	var out := {}
	var cell_size := _cell_size()
	var eye_y := pos.y + (0.0 if is_flying else EYE_HEIGHT)
	var from_eye := Vector3(pos.x, eye_y, pos.z)
	var cell_radius := int(ceil(reach / cell_size)) + 1
	var c0 := _world_to_cell(pos.x, pos.z)
	var directional := arc_rad != TAU
	for dz in range(-cell_radius, cell_radius + 1):
		var gz := c0.y + dz
		if gz < 0 or gz >= _dim:
			continue
		for dx in range(-cell_radius, cell_radius + 1):
			var gx := c0.x + dx
			if gx < 0 or gx >= _dim:
				continue
			var wx := -_half + (gx + 0.5) * cell_size
			var wz := -_half + (gz + 0.5) * cell_size
			var d_x := wx - pos.x
			var d_z := wz - pos.z
			var dist_sq := d_x * d_x + d_z * d_z
			if dist_sq > reach * reach:
				continue
			if directional and dist_sq > 0.0001:
				var d_len := sqrt(dist_sq)
				var angle := acos(clampf(fwd_2d.dot(Vector2(d_x / d_len, d_z / d_len)), -1.0, 1.0))
				if angle > arc_rad * 0.5:
					continue
			var target_y: float = _grid_heights[gz * _dim + gx] if _grid_heights.size() == _dim * _dim else _get_terrain_y(wx, wz)
			var to_target := Vector3(wx, target_y + EYE_HEIGHT, wz)
			if not _has_cell_los(from_eye, to_target, is_flying):
				continue
			out[Vector2i(gx, gz)] = true
	return out


func _set_cell_alpha(cell: Vector2i, alpha: float) -> void:
	if cell.x < 0 or cell.x >= _dim or cell.y < 0 or cell.y >= _dim:
		return
	var px := _image.get_pixel(cell.x, cell.y)
	if absf(px.a - alpha) < 0.004:
		return
	_image.set_pixel(cell.x, cell.y, Color(0, 0, 0, alpha))
	_shroud_dirty = true


# Discs overlap, so cells are reference-counted and the pixel only moves on
# the 0->1 and ->0 transitions. This is also what makes dropping ONE disc's
# contribution safe when only that viewer rescans.
func _acquire_cells(cells: Dictionary) -> void:
	for cell in cells:
		var c: int = int(_cell_refs.get(cell, 0)) + 1
		_cell_refs[cell] = c
		if c == 1:
			_set_cell_alpha(cell, 0.0)


func _release_cells(cells: Dictionary) -> void:
	for cell in cells:
		var c: int = int(_cell_refs.get(cell, 0)) - 1
		if c > 0:
			_cell_refs[cell] = c
		else:
			_cell_refs.erase(cell)
			# Back to EXPLORED, not to unexplored. Somewhere you have been stays known.
			_set_cell_alpha(cell, EXPLORED_ALPHA)


func _drop_all_discs() -> void:
	for oid in _viewer_discs.keys():
		_release_cells(_viewer_discs[oid].cells)
	_viewer_discs.clear()
	for uid in _beacon_discs.keys():
		_release_cells(_beacon_discs[uid].cells)
	_beacon_discs.clear()
# Whether a map cell has ever been seen. Exposed for the minimap, which draws
# terrain only where the player has been.
func cell_explored(x: float, z: float) -> bool:
	if _reveal_all_cheat():
		return true
	if _image == null:
		return false
	var cell := _world_to_cell(x, z)
	if cell.x < 0 or cell.x >= _dim or cell.y < 0 or cell.y >= _dim:
		return false
	return _image.get_pixel(cell.x, cell.y).a < UNEXPLORED_ALPHA
