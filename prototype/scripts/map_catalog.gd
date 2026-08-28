extends Node
class_name MapCatalog
const WorldScaleScript = preload("res://scripts/world_scale.gd")
# Skirmish map library. RTS_CORE_ROADMAP.md B3: maps are now JSON files
# under res://data/maps/*.json, scanned and cached once (same lazy
# scan-and-cache pattern as hull_loader.gd - a directory scan + N file
# reads/parses on every get_map() call would be a real perf regression;
# module_catalog.gd/enemy_ai.gd call through this on nearly every tick).
# D1's decision: shipped content (this directory) hard-fails loudly on
# invalid data (push_error + assert) rather than warn-and-skip - a broken
# map is a broken install, not a normal modding scenario. User-authored
# maps under user://maps/ (not built yet - no UI creates them) will get
# the warn-and-attempt treatment when that lands.
#
# JSON encodes Vector3/Vector2/Color as plain number arrays ([x,y,z] /
# [x,y] / [r,g,b]) since raw JSON has no vector/color type - FIELD_SPEC
# (originally B1's validator-only spec) now drives BOTH validation AND
# decoding back into real Godot types, so there's one schema description,
# not two things that could drift apart.
#
# Field shapes:
#   water_areas: [{center: Vector3, half_extents: Vector2}, ...]
#     (rectangular XZ footprints, Y ignored - flat-ground features)
#   obstacles: [{center, half_extents, type: "rock"/"building", building_height (opt)}, ...]
#     "type" defaults to "rock" (a jumbled boulder cluster) if omitted;
#     "building" is a single boxy structure with a flat roof and window
#     greebles - both are equally real cover (StaticBody3D on collision
#     layer 1), which is what makes them block weapon LOS (auto_weapon.gd)
#     and vision LOS (TerrainBuilder/skirmish.gd's _has_line_of_sight())
#     alike, not just movement.
#   bridges: [{center, half_extents, deck_height (opt)}, ...]
#     a rectangular strip carved through a water_areas hole, walkable for
#     ground/legged locomotion ONLY (not naval/amphibious, which don't need
#     it - see TerrainBuilder._collect_bridges()) - flanked by water on
#     both sides that ISN'T carved, so it's a genuine narrow chokepoint, not
#     a way to remove the water. Deliberately does not block water_map/
#     deep_water_map - naval units still float and pass freely underneath,
#     same as a real bridge over a river. A bridge's footprint should
#     always fully span a water_areas rect along the crossing axis (so
#     there's dry land - or at least the water's edge - on both ends);
#     nothing enforces this automatically, it's a map-authoring convention.
#   resource_nodes: [{position: Vector3, type: String, amount: int}, ...]
#     Each entry is a FIELD CENTRE, not a lump: resource_field.gd scatters
#     collectibles around it and replaces them as they are worked out, with the
#     scatter shape and respawn rate read per type from ResourceCatalog. `amount`
#     is the whole deposit, divided across the scatter. Types are "ore" (alias
#     "metal"), "crystal", "lumber" and "oil".
#   spawns: [{id: String, hq, factory, refinery, harvester: Vector3}, ...]
#     was player_start/enemy_start (B3) - "player"/"enemy" ids preserve the
#     exact 2-spawn runtime behavior; real N-player spawn assignment (pick
#     which slot uses which spawn) is B10's job, not this schema's.
#   players (optional): B2's slot fields, not yet authored by any map -
#     reserved for a future real N-player match-setup flow.
#   markers (optional): {name: {position, kind}} - OpenRA's named-map-actor
#     idea without the actor/trait machinery. Unused today.
#   terrain (optional): {heightmap, surfacemap, height_scale, features}
#     reserved for B4's Python heightmap generator - the field exists in
#     the schema now so B4 doesn't need a schema_version bump later.

const DEFAULT_MAP_ID: String = "lake_crossing"
const MAPS_DIR: String = "res://data/maps"

# Lazy scan-and-cache (hull_loader.gd's own established pattern) - the
# directory scan + N JSON parses happen once per process, not per call.
static var _cache: Dictionary = {}
static var _scanned: bool = false

# Test-only: forces the next get_map()/get_map_ids() call to rescan from
# disk. Production code never needs this (the cache lives for the process
# lifetime by design), but the automated suite runs everything in one
# process and B3's deep-equal test wants a guaranteed-fresh load.
static func reset_cache_for_tests() -> void:
	_cache = {}
	_scanned = false
	_last_load_error = ""

# The specific reason the most recent hard-fail was rejected - "" if
# nothing has failed to load yet this scan.
static func get_last_load_error() -> String:
	return _last_load_error

static func _ensure_scanned() -> void:
	if _scanned:
		return
	_scanned = true
	_cache = {}
	var dir = DirAccess.open(MAPS_DIR)
	if not dir:
		push_error("MapCatalog: could not open '%s' - no maps will load." % MAPS_DIR)
		return
	dir.list_dir_begin()
	var fname = dir.get_next()
	while fname != "":
		if not dir.current_is_dir() and fname.get_extension() == "json":
			_load_map_file(fname.get_basename(), "%s/%s" % [MAPS_DIR, fname])
		fname = dir.get_next()
	dir.list_dir_end()

# D1: shipped content (res://data/maps/) hard-fails loudly - matching the
# deliberately strict GLB _part() loader (visual_builder.gd), not
# hull_loader.gd's current warn-and-skip (that file predates D1's decision
# and is explicitly called out to get this same treatment "later"). "Hard
# fail" here means the broken map is REFUSED - never enters the usable
# catalog (get_map() for its id silently falls back to DEFAULT_MAP_ID,
# same graceful-fallback behavior an unknown id already had) - with a
# push_error() loud enough to show up in any log, debug or release.
# Deliberately not assert()-based: this needs to be exercisable by an
# automated test in the same process without pausing/aborting it, and a
# broken map shouldn't be able to take the whole game down anyway.
# _last_load_error mirrors blueprint_manager.gd's own last_load_error
# convention - the one place a test (or a future in-game error dialog)
# reads the specific reason from.
static var _last_load_error: String = ""

static func _load_map_file(map_id: String, path: String) -> void:
	var file = FileAccess.open(path, FileAccess.READ)
	if not file:
		_fail_load(path, "could not open file")
		return
	var text = file.get_as_text()
	file.close()

	var json = JSON.new()
	var parse_err = json.parse(text)
	if parse_err != OK:
		_fail_load(path, "JSON parse error: %s (line %d)" % [json.get_error_message(), json.get_error_line()])
		return
	var raw = json.get_data()
	if typeof(raw) != TYPE_DICTIONARY:
		_fail_load(path, "must be a JSON object at the top level")
		return

	# Decode BEFORE validating: raw JSON has no Vector3/Vector2/Color type,
	# so "center": [1,2,3] is a TYPE_ARRAY until _decode_dict() turns it
	# into a real Vector3 - validating the raw shape would reject every
	# single vector/color field as "wrong type." _decode_value() is
	# defensive (a malformed array is passed through unchanged rather than
	# indexed into and crashing), so a genuinely bad value still reaches
	# validate_map_def() and gets reported with a useful message instead.
	var decoded = _decode_dict(raw, FIELD_SPEC)
	# CORE_DESIGN_LANGUAGE.md §3.2 / Chunk 12: applied AFTER decode (needs
	# real Vector3/Vector2 to multiply, not JSON arrays) and BEFORE
	# validate (so a scaled map still has to satisfy the same "min"
	# bounds etc. everything else does - Chunk 13 makes those bounds
	# themselves scale-relative). map_half_extents on disk never changes;
	# this is the one place the multiplier actually touches map data.
	decoded = _apply_world_scale(decoded)
	var errors = validate_map_def(decoded)
	if not errors.is_empty():
		_fail_load(path, "failed schema validation:\n  %s" % "\n  ".join(errors))
		return

	# STAMP THE ID, after validation so the validator never sees it as an
	# unknown field. Without this, map_def.get("id") is empty on every map -
	# the terrain dressing's determinism seed silently fell back to the map's
	# display NAME, and anything wanting to find a per-map raster (the painted
	# water introduced alongside this) had no way to name it from a map_def
	# alone. Every consumer already assumed this key was there.
	decoded["id"] = map_id
	_cache[map_id] = decoded

static func _fail_load(path: String, reason: String) -> void:
	_last_load_error = "MapCatalog: '%s' %s" % [path, reason]
	push_error(_last_load_error)

static func get_map_ids() -> Array:
	_ensure_scanned()
	var ids = _cache.keys()
	ids.sort()
	return ids

static func get_map(map_id: String) -> Dictionary:
	_ensure_scanned()
	return _cache.get(map_id, _cache.get(DEFAULT_MAP_ID, {}))

static func get_map_name(map_id: String) -> String:
	return get_map(map_id).get("name", map_id)

# The one supported way to go from a map's spawns array to "the player's
# start" / "the enemy's start" - replaces the old direct
# current_map.player_start/.enemy_start access. "player"/"enemy" ids are
# what every bundled map's spawns array uses (B3); a real N-player spawn
# picker (which slot gets which spawn) is B10's job.
static func get_spawn(map_def: Dictionary, spawn_id: String) -> Dictionary:
	for s in map_def.get("spawns", []):
		if s.get("id") == spawn_id:
			return s
	return {}

# RTS_CORE_ROADMAP.md B10: spawn ASSIGNMENT - which slot gets which of a
# map's spawn points. Adopts OpenRA's algorithm verbatim (genuinely their
# entire runtime fairness logic, ~15 lines): explicit pick (if the slot
# asked for a specific spawn and it's still free) > when team_separation is
# on, whichever unclaimed spawn maximizes the summed squared distance to
# every spawn already claimed by an EARLIER entry in `order` (spreads
# players out, most valuable for keeping opposing teams apart) > uniform
# random among whatever's left otherwise (also the fallback for the very
# first pick, when nothing's claimed yet to measure distance against).
# Pure function over plain spawn dicts - no Skirmish/scene dependency, so
# it's testable in isolation and reusable by a future N-player match-setup
# slot picker without dragging in the whole match flow.
static func assign_spawns(spawn_defs: Array, order: Array, explicit_picks: Dictionary = {}, team_separation: bool = true, rng: RandomNumberGenerator = null) -> Dictionary:
	var claimed_ids: Array = []
	var claimed_hqs: Array = []
	var assignment: Dictionary = {}
	for slot_key in order:
		var candidates: Array = []
		for s in spawn_defs:
			if not claimed_ids.has(s.id):
				candidates.append(s)
		if candidates.is_empty():
			continue

		var picked: Dictionary = {}
		if explicit_picks.has(slot_key):
			for c in candidates:
				if c.id == explicit_picks[slot_key]:
					picked = c
					break

		if picked.is_empty() and team_separation and not claimed_hqs.is_empty():
			var best_score: float = -1.0
			for c in candidates:
				var score: float = 0.0
				for hq in claimed_hqs:
					score += c.hq.distance_squared_to(hq)
				if score > best_score:
					best_score = score
					picked = c

		if picked.is_empty():
			var r = rng if rng else RandomNumberGenerator.new()
			picked = candidates[r.randi() % candidates.size()]

		assignment[slot_key] = picked.id
		claimed_ids.append(picked.id)
		claimed_hqs.append(picked.hq)
	return assignment


# 2026-08-10 (Chris): base-zone assignment, the placement counterpart of
# assign_spawns(). One zone per slot, never the same zone twice, with
# the same OpenRA "maximise the squared distance to everything already
# claimed" spread algorithm assign_spawns() uses - on the zones' centres
# rather than on the HQs, because the HQs are no longer authored (the
# player drops them inside the zone). The match-level orchestrator
# (match_director.gd) calls BOTH assign_spawns and assign_base_zones
# with the same `order` so the i-th slot's spawn and zone are decided
# by the same distance-spread iteration, which keeps the result
# deterministic and testable in isolation.
#
# `base_zones`: a list of {id, center: Vector3, half_extents: Vector2}
# - the same shape FIELD_SPEC.base_zones validates, so the validator
# has already done the type-check before the assignment runs.
#
# Returns {slot_key -> zone_id} on success, or an empty Dictionary if
# there are fewer zones than slots in `order`. The orchestrator treats
# the under-provisioned case as a hard error (a future 4-player match
# against a 2-zone map needs explicit handling, not silent fallthrough
# to a "first zone wins" guess), and the early-empty return makes the
# failure surface here rather than at the placement-UI layer.
static func assign_base_zones(base_zones: Array, order: Array, rng: RandomNumberGenerator = null) -> Dictionary:
	if base_zones.is_empty():
		return {}
	if order.size() > base_zones.size():
		# Surface the mismatch here; the caller is the right place to
		# decide whether to fail the match, drop excess slots, or fall
		# back to something. Returning {} on purpose rather than picking
		# the first zone N times - that pattern silently passed two
		# related bugs already (see assign_spawns()'s own header for
		# the OpenRA "explicit pick > max-spread > uniform random"
		# ordering) and a per-zone distance metric is what the spread
		# step needs to do its job.
		return {}
	var claimed_ids: Array = []
	var claimed_centres: Array = []
	var assignment: Dictionary = {}
	for slot_key in order:
		var candidates: Array = []
		for z in base_zones:
			if not claimed_ids.has(z.id):
				candidates.append(z)
		if candidates.is_empty():
			break
		var picked: Dictionary = candidates[0]
		var best_score: float = -1.0
		for c in candidates:
			var score: float = 0.0
			for centre in claimed_centres:
				score += c.center.distance_squared_to(centre)
			if score > best_score:
				best_score = score
				picked = c
		assignment[slot_key] = picked.id
		claimed_ids.append(picked.id)
		claimed_centres.append(picked.center)
	return assignment


# The base zone a slot has been assigned to, in a map_def that's gone
# through the loader. Empty Dictionary if the map has no base_zones
# (older bundled maps, before the field existed) or the slot is
# unknown. Same lookup shape as get_spawn() so the orchestrator can
# resolve slot -> {spawn, base_zone} with two parallel calls.
static func get_base_zone(map_def: Dictionary, zone_id: String) -> Dictionary:
	for z in map_def.get("base_zones", []):
		if z.get("id") == zone_id:
			return z
	return {}

# 2026-08-26: per-axis half extents for non-square maps. Returns
# [half_x, half_z]; half_z defaults to half_x for square maps. The
# canonical entry point for layout code that needs the map's footprint
# (the nav grid, the ground visual mesh, the scatter area, etc) - prefer
# this over reading map_half_extents directly so a non-square map doesn't
# silently get its Z axis cropped.
static func half_extents(map_def: Dictionary) -> Vector2:
	var hx: float = map_def.get("map_half_extents", 80.0)
	var hz: float = map_def.get("map_half_extents_z", hx)
	return Vector2(hx, hz)

# RTS_CORE_ROADMAP.md B10: this project has a REAL baked navmesh at
# map-load time, unlike OpenRA (which only lints spawn counts/duplicates) -
# so this goes further and lints actual per-spawn FAIRNESS: is the HQ pad
# legal ground, is every spawn mutually reachable from every other spawn on
# the same ground navmesh, does it have a reasonable economy nearby, and
# are no two spawns wildly closer/farther apart than the rest (a lopsided
# map favors whoever gets the "good" spawn regardless of skill). Every
# check generalizes across however many spawns a map actually authors -
# trivially satisfied by today's fixed 2-spawn maps (a single pairwise
# distance has zero variance by definition), but the real target is
# whatever a future B8 map authors with 3+. Needs a REAL baked ground
# navmesh RID (TerrainBuilder.build_navmeshes()'s ground_map) - reachability
# can't be answered any other way - so this isn't a pure function like
# assign_spawns() above.
const FAIRNESS_RESOURCE_RADIUS_FRACTION: float = 0.6
const FAIRNESS_MIN_RESOURCES_PER_SPAWN: int = 2
const FAIRNESS_MAX_DISTANCE_COEFFICIENT_OF_VARIATION: float = 0.35
# RTS_CORE_ROADMAP.md C1: a spawn's HQ is itself a real building once a
# match is actually running, carving its own navmesh hole - a path can only
# get to that hole's edge, not the exact center point this lint queries
# against. Sized for the largest static building's footprint diagonal
# (~6.25, heavy_manufactory) plus up to one GRID_CELL (4.0) of navmesh
# quantization slop. Harmless before C1 too (no building yet = the real
# distance is ~0 regardless of how generous this margin is).
#
# CORE_DESIGN_LANGUAGE.md §3.2: this is the world_scale=1.0 BASELINE value -
# lint_spawn_fairness() multiplies it by the map's resolved world_scale
# before using it. The navmesh-quantization half of this margin genuinely
# grows at a larger world scale (terrain_builder.gd's GRID_CELL/cell_size
# both scale with it - see Chunk 14), so a fixed 12.0 would eventually read
# as "spawns unreachable" purely from grid slop, not a real fairness
# problem. The building-diagonal half does NOT grow (buildings are
# unit-space, fixed per world_scale.gd's whole design) - scaling the WHOLE
# margin is deliberately generous rather than precisely decomposing the
# two halves, since an overly permissive reachability check only risks
# missing a genuine problem, never manufacturing a false one.
const FAIRNESS_HQ_REACHABLE_MARGIN: float = 12.0

static func lint_spawn_fairness(map_def: Dictionary, ground_nav_map: RID) -> Array:
	var errors: Array = []
	var TerrainBuilderScript = load("res://scripts/terrain_builder.gd")
	var spawns: Array = map_def.get("spawns", [])
	if spawns.size() < 2:
		errors.append("Map needs at least 2 spawns, found %d" % spawns.size())
		return errors

	var half: float = map_def.get("map_half_extents", 80.0)
	var resource_radius: float = half * FAIRNESS_RESOURCE_RADIUS_FRACTION
	var resources: Array = map_def.get("resource_nodes", [])
	var reachable_margin: float = WorldScaleScript.scaled_f(FAIRNESS_HQ_REACHABLE_MARGIN, map_def)

	var distances: Array = []
	for i in range(spawns.size()):
		var a = spawns[i]
		if TerrainBuilderScript.is_position_blocked(map_def, a.hq):
			errors.append("Spawn '%s' HQ pad sits on blocked terrain" % a.id)

		var nearby := 0
		for r in resources:
			if a.hq.distance_to(r.position) <= resource_radius:
				nearby += 1
		if nearby < FAIRNESS_MIN_RESOURCES_PER_SPAWN:
			errors.append("Spawn '%s' has only %d resource node(s) within %.0f units (need >= %d)" % [a.id, nearby, resource_radius, FAIRNESS_MIN_RESOURCES_PER_SPAWN])

		for j in range(i + 1, spawns.size()):
			var b = spawns[j]
			var path = NavigationServer3D.map_get_path(ground_nav_map, a.hq, b.hq, true)
			if path.size() < 2 or path[path.size() - 1].distance_to(b.hq) > reachable_margin:
				errors.append("Spawns '%s' and '%s' are not mutually reachable on the ground navmesh" % [a.id, b.id])
			distances.append(a.hq.distance_to(b.hq))

	if distances.size() > 1:
		var mean: float = 0.0
		for d in distances:
			mean += d
		mean /= distances.size()
		var variance: float = 0.0
		for d in distances:
			variance += (d - mean) * (d - mean)
		variance /= distances.size()
		var stdev: float = sqrt(variance)
		var coeff: float = stdev / mean if mean > 0.0 else 0.0
		if coeff > FAIRNESS_MAX_DISTANCE_COEFFICIENT_OF_VARIATION:
			errors.append("Pairwise spawn distances vary too much (coefficient of variation %.2f > %.2f) - some spawn pairs are much closer/farther apart than others" % [coeff, FAIRNESS_MAX_DISTANCE_COEFFICIENT_OF_VARIATION])

	return errors

# RTS_CORE_ROADMAP.md B1: a declarative field -> type -> required -> range
# spec, walked by one reflective validator (validate_map()) instead of
# hand-written per-field asserts - the GDScript analogue of OpenRA's lint
# passes (D1's decision). Ships BEFORE the B3 JSON-format swap so that
# migration has a safety net to catch a transcription error against, per
# this file's own MAPS const being the only source of truth today.
#
# Each leaf spec: {"type": <below>, "required": bool, "min": num (opt),
# "enum": Array[String] (opt)}. Array/Dictionary specs additionally carry
# "item": a nested field-spec Dictionary, applied to every array element
# (Array) or directly (Dictionary) - same recursive shape used all the way
# down, so obstacles/surface_zones/etc. get free per-subkey + unknown-key
# checking without a bespoke validator each.
# CORE_DESIGN_LANGUAGE.md §3.2 / world_scale.gd: every leaf field below that
# represents a real-world-space position, extent, radius or length carries
# a "scale": true flag. Nothing reads it yet - Chunk 12 walks FIELD_SPEC
# off this flag to multiply every flagged value by the map's resolved
# world_scale at load time, so authored map JSON on disk never has to
# change and the flag list is the single place that decides what counts as
# "spatial" vs. gameplay data (resource_nodes.amount, obstacles.type,
# surface_zones.surface_type, spawns.id, schema_version, etc. are
# deliberately UNFLAGGED - they're either not spatial at all or (amount)
# a balance number the map-scale multiplier has no business touching).
const FIELD_SPEC: Dictionary = {
	"name": {"type": "string", "required": true},
	"description": {"type": "string", "required": true},
	"map_half_extents": {"type": "number", "required": true, "min": 1.0, "scale": true},
	# Optional per-axis Z half-extent for non-square maps. Defaults to
	# map_half_extents when absent, so existing square maps keep validating
	# unchanged. Most layout code reads half_extents() (below) and treats
	# the map as a [-half_x, +half_x] x [-half_z, +half_z] rectangle;
	# navmesh / ground mesh / scatter sizing use max(half_x, half_z) so
	# the coverage is right regardless of which axis is the long one.
	# 2026-08-26: hand-drawn canyon_ford (the new 3-plateau / 2-river map)
	# is a 1200x520 stage (2.31:1) - the wider rectangle needs this.
	"map_half_extents_z": {"type": "number", "required": false, "min": 1.0, "scale": true},
	"ground_color": {"type": "color", "required": true},
	# A playtest map can opt out of the ambient tree/ore scatter
	# (the 30-cluster pass that pads Skirmish-sized maps). The Test
	# Range uses this to keep its 80x80 stage clean - the player
	# needs to see their unit, not a forest the ambient code packed
	# into whatever space it found. Default false (ambient on).
	"disable_ambient_scatter": {"type": "bool", "required": false},
	# SKIRMISH_PERF_TROUBLESHOOTING.md §12. Per-map density multiplier on
	# the ambient tree / ore scatter. 1.0 is the default; lake_crossing
	# ships at 0.5 to cut the 23 s scatter cost on a populated map. The
	# field multiplies the cluster count and the per-cluster item cap,
	# so 0.5 yields ~25% of the original prop count (half the clusters,
	# half the per-cluster ceiling). Numbers under 0.3 start to read as
	# "the forest died", so the floor is more of a soft 0.25 than a hard
	# zero - use disable_ambient_scatter for "off entirely".
	"ambient_scatter_density": {"type": "number", "required": false, "min": 0.1, "max": 2.0},
	# SKIRMISH_PERF_TROUBLESHOOTING.md §12. Toggles the ground collider
	# from a real subdivided heightmap to a single flat box. The cost
	# of move_and_slide per unit changes from "convex hull against a
	# heightmap-cell grid" to "convex hull against a flat plane" - the
	# experiment in §11.5 that was hypothesized but never run. Set on
	# a map that is genuinely flat (open_plains), record the units
	# section cost, then unset it and re-record; the diff is the
	# ground-heightmap contribution. Default false.
	"flat_ground_collider": {"type": "bool", "required": false},
	"water_blobs": {"type": "array", "required": false, "item": {
		"center": {"type": "vector3", "required": true, "scale": true},
		"radius": {"type": "number", "required": true, "min": 0.01, "scale": true},
		"irregularity": {"type": "number", "required": false},
		"depth": {"type": "number", "required": false, "scale": true},
		"shore_blend": {"type": "number", "required": false, "scale": true},
	}},
	"water_areas": {"type": "array", "required": false, "item": {
		"center": {"type": "vector3", "required": true, "scale": true},
		"half_extents": {"type": "vector2", "required": true, "scale": true},
	}},
	"shallow_water_areas": {"type": "array", "required": false, "item": {
		"center": {"type": "vector3", "required": true, "scale": true},
		"half_extents": {"type": "vector2", "required": true, "scale": true},
	}},
	"obstacles": {"type": "array", "required": false, "item": {
		"center": {"type": "vector3", "required": true, "scale": true},
		"half_extents": {"type": "vector2", "required": true, "scale": true},
		"type": {"type": "string", "required": false, "enum": ["rock", "building", "fortification", "depot", "relay", "crater"]},
		"building_height": {"type": "number", "required": false, "min": 0.01, "scale": true},
	}},
	# Cliff mesh pieces (canyon_ford PR1, 2026-08-26). Hybrid heightmap+mesh
	# approach: heightmap handles ≤60° slopes, this array declares
	# hand-placed vertical faces the heightmap can't represent. Each cliff is
	# a StaticBody3D on BattleLayers.TERRAIN so the ground navmesh bake
	# reads it as an impassable hole and the vision_service LOS raycast
	# (TERRAIN | BUILDINGS) reads it as visual cover - same dual role
	# `obstacles` play today. Deliberately Vector2 half_extents (not
	# Vector3) - the footprint is a ground rect, Y is `cliff_height`, and
	# a stray Y in half_extents would silently pass validation (Z would
	# be checked, the Y component ignored), the same trap `base_zones`
	# already addresses in its own comment.
	#
	# `type` controls which GLB piece the runtime loads. Today the
	# authored pool is straight / corner_in / corner_out / end (PR1 ships
	# with a primitive-box fallback for each so the schema validates and
	# the spawn runs before the Blender regen produces the .glb files).
	# `rotation` is in radians, around the Y axis, so a "straight" piece
	# can face any cardinal direction.
	"cliffs": {"type": "array", "required": false, "item": {
		"center": {"type": "vector3", "required": true, "scale": true},
		"half_extents": {"type": "vector2", "required": true, "scale": true},
		# 2026-08-26 22:45 playtest: the prior pool
		# `["straight", "corner_in", "corner_out", "end"]` referred to
		# GLB file names the rebuild never produced on disk. The actual
		# pool is now face_X (4 straight variants, Y-scaled to the
		# requested cliff_height), corner_X (3 corner L-shapes, no
		# scale), and strata_X (3 layered-look variants, Y-scaled).
		# terrain_builder.gd has the matching CLIFF_POOL_TYPES constant.
		"type": {"type": "string", "required": false, "enum": [
			"face_0", "face_1", "face_2", "face_3",
			"corner_0", "corner_1", "corner_2",
			"strata_0", "strata_1", "strata_2",
		]},
		"cliff_height": {"type": "number", "required": false, "min": 0.5, "scale": true},
		"rotation": {"type": "number", "required": false},
		"cliff_tint": {"type": "color", "required": false},
	}},
	# Never previously in FIELD_SPEC at all, despite terrain_builder.gd's
	# _hill_contribution() reading it unconditionally on every non-heightmap
	# map - a hill authored at radius=20 rendered at exactly radius=20
	# regardless of world_scale, shrinking to a bump relative to a map that
	# had grown 4x around it. `height` is signed on purpose: the same
	# radial falloff formula that makes a positive height a hill (real
	# vantage - see vision_service.gd's ELEVATION_BONUS_PER_UNIT) makes a
	# negative one a ravine (real cover - the same formula reduces vision
	# for a unit standing in one), with no separate mechanism needed for
	# either. _slope_at() rejects a hill's edge and a ravine's edge
	# identically (it only measures magnitude), so both already produce a
	# genuine, gated navmesh feature rather than a purely visual bump.
	"hills": {"type": "array", "required": false, "item": {
		"center": {"type": "vector3", "required": true, "scale": true},
		"radius": {"type": "number", "required": false, "min": 0.0, "scale": true},
		"falloff": {"type": "number", "required": false, "min": 0.0, "scale": true},
		"height": {"type": "number", "required": false, "scale": true},
	}},
	"surface_zones": {"type": "array", "required": false, "item": {
		"center": {"type": "vector3", "required": true, "scale": true},
		"half_extents": {"type": "vector2", "required": true, "scale": true},
		"surface_type": {"type": "string", "required": true, "enum": ["marsh", "rocky", "snow_mud", "sand", "gravel", "forest", "ice", "dirt", "steppe_grass", "dry_grass", "mud", "cobble", "scree", "volcanic"]},
	}},
	"bridges": {"type": "array", "required": false, "item": {
		"center": {"type": "vector3", "required": true, "scale": true},
		"half_extents": {"type": "vector2", "required": true, "scale": true},
		"deck_height": {"type": "number", "required": false, "scale": true},
		"rotation_deg": {"type": "number", "required": false},
	}},
	"roads": {"type": "array", "required": false},
	"props": {"type": "array", "required": false},
	"resource_nodes": {"type": "array", "required": false, "item": {
		"position": {"type": "vector3", "required": true, "scale": true},
		# "metal" is the historical id for ore and every bundled map still uses
		# it; ResourceCatalog treats it as an alias rather than a rename, so both
		# spellings validate and mean the same field.
		"type": {"type": "string", "required": true,
			"enum": ["metal", "ore", "crystal", "lumber", "oil"]},
		# Deliberately unflagged: a resource node's yield is a balance
		# number, not a distance. Node amount/density re-tuning at a new
		# world scale is scoped to the separate resource-system rework,
		# not this pass - see CORE_DESIGN_LANGUAGE.md §3.2.
		"amount": {"type": "number", "required": true, "min": 1},
	}},
	# B3: was player_start/enemy_start (2 fixed dict fields); now a
	# spawns array with an id per entry. "player"/"enemy" are the ids
	# every bundled map uses today (see get_spawn()).
	# CORE_DESIGN_LANGUAGE.md §3.2: only "hq" is flagged here. A player's
	# base is unit-scale (buildings don't scale, same as units), not
	# environment-scale - factory/refinery/harvester are deliberately
	# UNFLAGGED and instead handled by _apply_world_scale()'s dedicated
	# spawn-compaction step, which scales "hq" as the base's anchor point
	# (so the whole base still lands in the right place on the bigger map)
	# but keeps the other three buildings at their ORIGINAL offset from
	# it - a compact base on a big map, not a base stretched 4x wider than
	# the units garrisoning it. See CHUNK11_NON_SPATIAL_VECTOR_FIELDS in
	# the test suite for why this isn't a "missing flag" bug.
	"spawns": {"type": "array", "required": true, "item": {
		"id": {"type": "string", "required": true},
		"hq": {"type": "vector3", "required": true, "scale": true},
		"factory": {"type": "vector3", "required": true},
		"refinery": {"type": "vector3", "required": true},
		"harvester": {"type": "vector3", "required": true},
	}},
	# 2026-08-10 (Chris): pre-game HQ-placement zones. Each map declares
	# one or more flat-enough rectangles a player may drop their HQ in,
	# and the spawn-assignment algorithm hands one zone per slot. The
	# the player places the HQ INSIDE the assigned zone (current
	# behaviour) or wherever the AI decides (next change). The other
	# three buildings (refinery/factories/harvester) are no longer
	# pre-placed at hard-coded offsets - the player has a starting bank
	# to build them normally, so the per-spawn factory/refinery/harvester
	# fields above are vestigial today and a future cleanup pass will
	# drop them once the runtime no longer reads them. Kept required here
	# so the existing 9 maps keep validating unchanged.
	#
	# `id` is the stable key the assignment algorithm returns; `center`/
	# `half_extents` are the rectangle the player may drop the HQ in.
	# Deliberately Vector2 half_extents (not Vector3) - these are XZ
	# ground rects, Y is the terrain height, and Vector3 half_extents
	# would invite a stray Y value to silently fail validation here
	# (Z would be checked, the Y component silently ignored).
	"base_zones": {"type": "array", "required": false, "item": {
		"id": {"type": "string", "required": true},
		"center": {"type": "vector3", "required": true, "scale": true},
		"half_extents": {"type": "vector2", "required": true, "scale": true},
	}},
	# CORE_DESIGN_LANGUAGE.md §3.2: per-map environment-scale multiplier.
	# Already read by _apply_world_scale() and WorldScaleScript.for_map();
	# formally declared here so the schema validator stops flagging it
	# as an "Unknown field" (canyon_ford PR1, 2026-08-26). Not
	# "scale": true on purpose - it IS the scale, scaling itself would
	# be circular. A min of 0.1 keeps the math sane; max is left open
	# so 16x (the project's stated target) validates without bumping
	# the cap every time world_scale.gd's DEFAULT moves.
	"world_scale": {"type": "number", "required": false, "min": 0.1},
	# Height of the map-wide water table, in world units. Was read by
	# TerrainBuilder with a hardcoded 0.05 default and never declared here, so
	# a map that set it had the value dropped by the schema and got the default
	# anyway. "scale": true because it is a height like any other length.
	#
	# The default is NEGATIVE (see TerrainBuilder.WATER_LEVEL_DEFAULT): a table
	# at 0.05 sits above the resting height of terrain that averages zero, so a
	# v2 map came up flooded from edge to edge.
	"water_level": {"type": "number", "required": false, "scale": true},
	# Painted water bodies - one RGBA raster per map, R = coverage, GB = a
	# 16-bit surface height. Lets a lake sit ABOVE the table (a mountain tarn)
	# instead of only where the ground dips below it.
	"water_paint": {"type": "string", "required": false},
	"schema_version": {"type": "number", "required": true, "min": 1},
	# The map's own id (its filename stem). Stamped in by _load_map after
	# validation, and declared here so a round trip - load, then validate the
	# loaded dictionary, which the sculpt tool's save path and the probes both
	# do - does not trip over it as an unknown field. Optional because a map on
	# disk does not have to carry it; the loader is the authority.
	"id": {"type": "string", "required": false},
	# Reserved fields (B3): not authored by any of the 8 bundled maps yet,
	# so deliberately shallow specs (no "item") - just type-checked, not
	# deeply validated, until something actually populates them.
	"players": {"type": "array", "required": false},
	"markers": {"type": "dictionary", "required": false},
	# RTS_CORE_ROADMAP.md B4: heightmap/surfacemap point at the PNGs
	# tools/terrain/build_terrain.py generates (paths, not filename
	# convention - see terrain_builder.gd's _get_heightmap_image()).
	# "features" is deliberately NOT deep-validated here - it's a
	# discriminated union (hill/basin/plateau/ridge/ravine/escarpment/
	# cliff each have different required params), which this validator's
	# single-shape-per-field engine doesn't model; build_terrain.py itself
	# raises a clear error on an unknown type or missing param. Worth
	# revisiting if/when B6 migrates real maps onto this.
	# height_scale is flagged: it converts the heightmap's normalized 0..1
	# sample into a real world-space Y, so it's exactly as spatial as any
	# other length here - Chunk 14 note: whether it should ALSO independently
	# track world_scale or be left to author intent is a heightmap-specific
	# call, not decided by this flag alone.
	"terrain": {"type": "dictionary", "required": false, "item": {
		# Which surfacing system builds this map's ground. Absent or "v1" is
		# the shipped path (shaders/terrain_ground.gdshader); "v2" selects the
		# splat-driven rebuild (shaders/terrain_ground_v2.gdshader). Chosen
		# per map so both systems can run side by side and be compared in the
		# same build - see TerrainBuilder.build_ground_material_for().
		"generator": {"type": "string", "required": false},
		"heightmap": {"type": "string", "required": false},
		"surfacemap": {"type": "string", "required": false},
		"height_scale": {"type": "number", "required": false, "min": 0.01, "scale": true},
		# canyon_ford PR2 (2026-08-26): explicit pixels-per-world-unit
		# for the heightmap PNG. Default in build_terrain.py is 1.0;
		# canyon_ford will use 2.0 on its bluff/plateau segments so the
		# navmesh bake reads a 60-degree slope as walkable-slow (not as
		# the binary "blocked" the 1px/unit quantization would give at
		# the same authored slope). Not "scale": true on purpose - the
		# pixel count is in pixel-space, not world-space, and the
		# world_scale multiplier is applied separately by build_terrain.py
		# at bake time (the heightmap is a baked asset, scale-relative
		# in its dim calculation, see _sample_heightmap_bilinear at
		# terrain_builder.gd:436).
		"pixels_per_unit": {"type": "number", "required": false, "min": 0.25, "max": 8.0},
		"features": {"type": "array", "required": false},
		"noise": {"type": "dictionary", "required": false},
		"erosion": {"type": "dictionary", "required": false},
		# What build_terrain.py's apply_terrain_post_pass() actually reads:
		# {noise: {frequency, amplitude, octaves}, thermal_erosion, hydraulic_
		# erosion, domain_warp}. The `noise`/`erosion` keys above sit at the
		# wrong level for it and were therefore never consumed by anything -
		# the baker looks for terrain.post_pass and nothing else.
		"post_pass": {"type": "dictionary", "required": false},
		# Multiplier for scattered prop SIZE, independent of world_scale.
		#
		# They are normally the same thing, but a v2 map has to declare
		# world_scale 1.0 - terrain.features is not in the scale table, so any
		# other value multiplies every field EXCEPT the features and scatters
		# the map. That correctly stops the geometry moving, and incorrectly
		# tells the prop scatter it is on a small map: a tree authored for a
		# 4x world came out 6 m tall on a 1920 m map and was invisible at
		# gameplay range. Defaults to world_scale when unset, so no existing
		# map changes.
		"prop_scale": {"type": "number", "required": false, "min": 0.05, "max": 32.0},
		"sculpt_grid": {"type": "dictionary", "required": false},
	}},
	"environment": {"type": "dictionary", "required": false, "item": {
		"sky_color": {"type": "color", "required": false},
		"horizon_color": {"type": "color", "required": false},
		"sun_color": {"type": "color", "required": false},
		"sun_energy": {"type": "number", "required": false, "min": 0.0},
		"ambient_light_energy": {"type": "number", "required": false, "min": 0.0},
		# Battle.tscn's ambient is a cool blue-grey (0.45, 0.50, 0.55). With a
		# low sun most ground faces away from the key, so that fill dominates
		# and every map ends up the same blue-teal regardless of its sky or
		# sun colour - a grass map cannot read as green. Per-map so a v1 map
		# keeps the blue it was authored against.
		"ambient_light_color": {"type": "color", "required": false},
		# Per-map exposure. Battle.tscn pins tonemap_exposure at 0.9 for every
		# map, and measured on sentinel_divide that puts a pure white surface
		# at 0.54 sRGB - the whole scene about two stops under, so ground with
		# a legitimately dark albedo (grassland is 0.115 linear) lands at 0.17
		# and reads as black. Raising the map's lights instead would only blow
		# out anything pale; this is an exposure problem and wants an exposure
		# control. Per-map so v1 maps keep the 0.9 they were authored against.
		"tonemap_exposure": {"type": "number", "required": false, "min": 0.05, "max": 8.0},
		# Sun angle, in degrees. Elevation 0 = on the horizon, 90 = overhead.
		# Battle.tscn bakes ~39 deg into the DirectionalLight3D's transform and
		# nothing overrides it, so every map in the game shares one time of day
		# - and a low sun is most of why flat ground reads dark, since NdotL on
		# level terrain is just sin(elevation).
		"sun_elevation_deg": {"type": "number", "required": false, "min": 1.0, "max": 89.0},
		"sun_azimuth_deg": {"type": "number", "required": false, "min": -360.0, "max": 360.0},
		"fog_enabled": {"type": "bool", "required": false},
		"fog_density": {"type": "number", "required": false, "min": 0.0},
		"fog_aerial_perspective": {"type": "number", "required": false, "min": 0.0},
		# 2026-08-26 22:45 playtest fix: Battle.tscn's
		# volumetric_fog_density = 0.0012 was the actual cause of "the
		# fog is overwhelming even barely zoomed out" - the per-map
		# fog_density override was being COMPOSITED with Battle.tscn's
		# volumetric fog. Per-map env block now also overrides
		# volumetric_fog_* so a map can dial it down (0.0003) or off.
		"volumetric_fog_enabled": {"type": "bool", "required": false},
		"volumetric_fog_density": {"type": "number", "required": false, "min": 0.0},
		"dof_blur_far_enabled": {"type": "bool", "required": false},
		"dof_blur_far_distance": {"type": "number", "required": false, "min": 0.0},
	}},
}

# Returns an Array[String] of human-readable errors; empty = valid.
# Re-validates the already-loaded (and already hard-fail-checked-at-load)
# cached map - mainly useful for tests. A raw/corrupted Dictionary that
# was never loaded through _load_map_file() should call validate_map_def()
# directly instead (see test_map_schema_validator()).
static func validate_map(map_id: String) -> Array:
	_ensure_scanned()
	if not _cache.has(map_id):
		return ["Unknown map id '%s'" % map_id]
	return validate_map_def(_cache[map_id])

# Walks FIELD_SPEC against any map Dictionary - no per-map hand-written
# asserts, so a 9th map (or a test's corrupted copy) gets the exact same
# coverage the first 8 already do.
static func validate_map_def(map_def: Dictionary) -> Array:
	var errors: Array = []
	_validate_dict(map_def, FIELD_SPEC, "", errors)

	# Cross-field check (not expressible in the per-field spec alone):
	# every resource node has to actually sit inside the map's own bounds -
	# nothing upstream of this enforces that today. Per-axis bounds now
	# (2026-08-26): a non-square map (map_half_extents_z different from
	# map_half_extents) would otherwise reject any resource authored in
	# the long axis's extra room.
	var hx: float = map_def.get("map_half_extents", 0.0)
	var hz: float = map_def.get("map_half_extents_z", hx)
	if (typeof(hx) == TYPE_FLOAT or typeof(hx) == TYPE_INT) and (typeof(hz) == TYPE_FLOAT or typeof(hz) == TYPE_INT):
		var nodes = map_def.get("resource_nodes", [])
		if typeof(nodes) == TYPE_ARRAY:
			for i in range(nodes.size()):
				var node = nodes[i]
				if typeof(node) == TYPE_DICTIONARY and typeof(node.get("position")) == TYPE_VECTOR3:
					var pos: Vector3 = node["position"]
					if abs(pos.x) > hx or abs(pos.z) > hz:
						errors.append("resource_nodes[%d].position %s is outside map bounds (+/-%s, +/-%s)" % [i, pos, hx, hz])
	return errors

static func _validate_dict(d: Dictionary, spec: Dictionary, prefix: String, errors: Array) -> void:
	for key in spec.keys():
		var full_key = prefix + key
		if not d.has(key):
			if spec[key].get("required", false):
				errors.append("Missing required field '%s'" % full_key)
			continue
		_validate_value(d[key], spec[key], full_key, errors)
	for key in d.keys():
		if not spec.has(key):
			errors.append("Unknown field '%s'" % (prefix + str(key)))

static func _validate_value(value, field_spec: Dictionary, full_key: String, errors: Array) -> void:
	var t: String = field_spec.get("type", "")
	match t:
		"string":
			if typeof(value) != TYPE_STRING:
				errors.append("'%s' should be a String, got type %d" % [full_key, typeof(value)])
				return
			if field_spec.has("enum") and not (value in field_spec["enum"]):
				errors.append("'%s' value '%s' not in allowed set %s" % [full_key, value, field_spec["enum"]])
		"number":
			if typeof(value) != TYPE_INT and typeof(value) != TYPE_FLOAT:
				errors.append("'%s' should be a number, got type %d" % [full_key, typeof(value)])
				return
			if field_spec.has("min") and value < field_spec["min"]:
				errors.append("'%s' value %s is below minimum %s" % [full_key, value, field_spec["min"]])
		"bool":
			if typeof(value) != TYPE_BOOL:
				errors.append("'%s' should be a Bool, got type %d" % [full_key, typeof(value)])
		"color":
			if typeof(value) != TYPE_COLOR:
				errors.append("'%s' should be a Color, got type %d" % [full_key, typeof(value)])
		"vector3":
			if typeof(value) != TYPE_VECTOR3:
				errors.append("'%s' should be a Vector3, got type %d" % [full_key, typeof(value)])
		"vector2":
			if typeof(value) != TYPE_VECTOR2:
				errors.append("'%s' should be a Vector2, got type %d" % [full_key, typeof(value)])
		"array":
			if typeof(value) != TYPE_ARRAY:
				errors.append("'%s' should be an Array, got type %d" % [full_key, typeof(value)])
				return
			if field_spec.has("item"):
				for i in range(value.size()):
					var elem = value[i]
					if typeof(elem) != TYPE_DICTIONARY:
						errors.append("'%s[%d]' should be a Dictionary, got type %d" % [full_key, i, typeof(elem)])
						continue
					_validate_dict(elem, field_spec["item"], "%s[%d]." % [full_key, i], errors)
		"dictionary":
			if typeof(value) != TYPE_DICTIONARY:
				errors.append("'%s' should be a Dictionary, got type %d" % [full_key, typeof(value)])
				return
			if field_spec.has("item"):
				_validate_dict(value, field_spec["item"], full_key + ".", errors)
		_:
			errors.append("Internal: unknown field-spec type '%s' for '%s'" % [t, full_key])

# CORE_DESIGN_LANGUAGE.md §3.2: multiplies every FIELD_SPEC-flagged
# ("scale": true, see Chunk 11) value in an already-DECODED map_def by the
# map's resolved world_scale - the generic mechanism behind "environment
# scales, units don't." Same recursive walk shape as _validate_dict/
# _decode_dict on purpose, driven by the identical FIELD_SPEC so there is
# still only one schema description.
#
# Deliberately a hard no-op at scale == 1.0 (today's default for every
# bundled map) rather than "multiply by 1.0 and trust it comes out the
# same" - multiplying an int field by a float scale would silently widen
# it to a float even at 1.0, which test_b3_maps_are_json_and_byte_
# identical_to_the_old_const and this chunk's own inertness test both
# depend on NOT happening.
static func _apply_world_scale(map_def: Dictionary) -> Dictionary:
	var scale: float = WorldScaleScript.for_map(map_def)
	if scale == 1.0:
		return map_def
	var result = _scale_dict(map_def, FIELD_SPEC, scale)
	if result.has("spawns"):
		result["spawns"] = _compact_spawns(map_def.get("spawns", []), result["spawns"])
	return result

# Keeps a base's internal layout compact even as the map around it grows -
# see FIELD_SPEC's "spawns" comment for why (buildings are unit-scale, not
# environment-scale). "hq" was already scaled by the generic walk above (it
# anchors the base to its correct position on the bigger map); factory/
# refinery/harvester are unflagged there, so they're still at their RAW
# world-space position here - this repositions each one at its ORIGINAL
# offset from hq, now measured from the hq's NEW scaled position, instead
# of at its own independently-scaled (and now much farther-flung) spot.
static func _compact_spawns(raw_spawns: Array, scaled_spawns: Array) -> Array:
	var out: Array = []
	for i in range(scaled_spawns.size()):
		var scaled = scaled_spawns[i]
		if i >= raw_spawns.size() or typeof(scaled) != TYPE_DICTIONARY:
			out.append(scaled)
			continue
		var raw = raw_spawns[i]
		var compacted: Dictionary = scaled.duplicate(true)
		var raw_hq = raw.get("hq")
		var scaled_hq = scaled.get("hq")
		if typeof(raw_hq) == TYPE_VECTOR3 and typeof(scaled_hq) == TYPE_VECTOR3:
			for key in ["factory", "refinery", "harvester"]:
				if typeof(raw.get(key)) == TYPE_VECTOR3:
					compacted[key] = scaled_hq + (raw[key] - raw_hq)
		out.append(compacted)
	return out

static func _scale_dict(d: Dictionary, spec: Dictionary, scale: float) -> Dictionary:
	var result: Dictionary = d.duplicate(true)
	for key in spec.keys():
		if not result.has(key):
			continue
		result[key] = _scale_value(result[key], spec[key], scale)
	return result

static func _scale_value(value, field_spec: Dictionary, scale: float):
	var t: String = field_spec.get("type", "")
	if field_spec.get("scale", false):
		match t:
			"number":
				if typeof(value) == TYPE_INT or typeof(value) == TYPE_FLOAT:
					return value * scale
			"vector3":
				if typeof(value) == TYPE_VECTOR3:
					return (value as Vector3) * scale
			"vector2":
				if typeof(value) == TYPE_VECTOR2:
					return (value as Vector2) * scale
	# Not itself a scaled leaf - still need to recurse into arrays/
	# dictionaries in case a NESTED field is flagged (e.g. spawns[].hq).
	match t:
		"array":
			if typeof(value) == TYPE_ARRAY and field_spec.has("item"):
				var out: Array = []
				for elem in value:
					if typeof(elem) == TYPE_DICTIONARY:
						out.append(_scale_dict(elem, field_spec["item"], scale))
					else:
						out.append(elem)
				return out
		"dictionary":
			if typeof(value) == TYPE_DICTIONARY and field_spec.has("item"):
				return _scale_dict(value, field_spec["item"], scale)
	return value

# RTS_CORE_ROADMAP.md B3: turns raw JSON (arrays of numbers) back into real
# Godot types, driven by the exact same FIELD_SPEC the validator walks -
# one schema description instead of a second, separately-maintained decode
# table that could drift out of sync with it. Same recursive shape as
# _validate_dict/_validate_value on purpose.
static func _decode_dict(d: Dictionary, spec: Dictionary) -> Dictionary:
	var result: Dictionary = {}
	for key in d.keys():
		if spec.has(key):
			result[key] = _decode_value(d[key], spec[key])
		else:
			result[key] = d[key] # unknown key - validate_map_def() will flag it; pass through so the error can name it
	return result

# Defensive on purpose: a malformed value (wrong array length, wrong
# element types) is passed through UNCHANGED rather than indexed into and
# crashing - validate_map_def() runs right after decoding and reports the
# mismatch with a real message instead of a stack trace.
static func _decode_value(value, field_spec: Dictionary):
	var t: String = field_spec.get("type", "")
	match t:
		"vector3":
			if typeof(value) == TYPE_ARRAY and value.size() == 3:
				return Vector3(value[0], value[1], value[2])
			return value
		"vector2":
			if typeof(value) == TYPE_ARRAY and value.size() == 2:
				return Vector2(value[0], value[1])
			return value
		"color":
			if typeof(value) == TYPE_ARRAY and (value.size() == 3 or value.size() == 4):
				return Color(value[0], value[1], value[2], value[3] if value.size() == 4 else 1.0)
			return value
		"array":
			if typeof(value) != TYPE_ARRAY:
				return value
			if not field_spec.has("item"):
				return value.duplicate()
			var out: Array = []
			for elem in value:
				if typeof(elem) == TYPE_DICTIONARY:
					out.append(_decode_dict(elem, field_spec["item"]))
				else:
					out.append(elem)
			return out
		"dictionary":
			if typeof(value) == TYPE_DICTIONARY and field_spec.has("item"):
				return _decode_dict(value, field_spec["item"])
			return value
		_:
			return value # string/number - JSON's own type already matches
