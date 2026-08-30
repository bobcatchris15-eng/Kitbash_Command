extends Node
# Rule-driven terrain dressing for v2 maps.
#
# WHAT THIS REPLACES
# ------------------
# The v1 scatter is a set of hardcoded passes with the rules baked into
# constants scattered across terrain_builder.gd:
#
#   slope_rock_density(slope)          boulders, slope only
#   AMBIENT_TREE_MAX_SLOPE = 0.5       trees, slope only
#   GRASSLAND_CLUTTER_AVOID_RADIUS     grass, position only
#
# Two consequences. Retuning any of it needs a code edit, and - more
# importantly - the rules could only ask about SLOPE. A hillside looked the
# same whichever way it faced, and nothing could be placed in relation to
# water. Aspect and water proximity are the two inputs that make terrain look
# like it grew rather than like it was sprinkled.
#
# Here the rules are data (data/terrain_dressing/*.json). A layer names a prop
# set, a density, and a `where` block of ranges over slope / height / aspect /
# water distance / curvature. Adding a layer, or retuning one, is a JSON edit.
#
# DETERMINISM. Placement is seeded from the map id, the layer id and the grid
# cell index - never from a global RNG or from frame timing. The same map
# dresses identically every load, which matters because a saved game or a
# rejoin would otherwise rearrange the scenery.

const TerrainBuilderScript = preload("res://scripts/terrain_builder.gd")
const AmbientScatterScript = preload("res://scripts/ambient_scatter.gd")
const MapCatalogScript = preload("res://scripts/map_catalog.gd")

const RULES_DIR := "res://data/terrain_dressing/"
const DEFAULT_RULES := "standard"

# A whole-map ceiling across every layer. The per-layer `max_count` bounds one
# rule; this bounds a rule FILE, so a badly-tuned set cannot melt a large map.
# Raised from 6000: the per-layer caps needed to be several times larger to
# read as terrain on a 1920 m map, and MultiMesh batching means the cost is
# instance count rather than draw calls.
const GLOBAL_PROP_CEILING := 12000

static var _rules_cache: Dictionary = {}


static func rules_name_for(map_def: Dictionary) -> String:
	var terr = map_def.get("terrain", {})
	if typeof(terr) != TYPE_DICTIONARY:
		return DEFAULT_RULES
	var n := str(terr.get("dressing", "")).strip_edges()
	return n if n != "" else DEFAULT_RULES


static func load_rules(rules_name: String) -> Dictionary:
	if _rules_cache.has(rules_name):
		return _rules_cache[rules_name]
	var path := RULES_DIR + rules_name + ".json"
	var out := {}
	if not FileAccess.file_exists(path):
		push_error("TerrainDressing: no rule file at %s" % path)
	else:
		var f := FileAccess.open(path, FileAccess.READ)
		var parsed = JSON.parse_string(f.get_as_text())
		f.close()
		if parsed is Dictionary:
			out = parsed
		else:
			push_error("TerrainDressing: %s is not a JSON object" % path)
	_rules_cache[rules_name] = out
	return out


static func reset_cache_for_tests() -> void:
	_rules_cache = {}


# Resolve a prop set to a list of scene paths. Declared as dir/prefix/count in
# the rule file rather than as an explicit list, so adding boulder_35.glb is a
# one-number edit rather than a 36-line one.
static func _prop_paths(rules: Dictionary, set_name: String) -> Array:
	var sets: Dictionary = rules.get("prop_sets", {})
	if not sets.has(set_name):
		push_warning("TerrainDressing: unknown prop set '%s'" % set_name)
		return []
	var spec: Dictionary = sets[set_name]
	if spec.has("paths"):
		return spec["paths"]
	var out := []
	var dir := str(spec.get("dir", "res://assets/models/terrain/"))
	var prefix := str(spec.get("prefix", ""))
	for i in range(int(spec.get("count", 0))):
		var p := "%s%s%d.glb" % [dir, prefix, i]
		if ResourceLoader.exists(p):
			out.append(p)
	return out


# --- condition matching -----------------------------------------------------

# `null` at either end of a range means UNBOUNDED.
#
# This matters more than it looks. water_distance_at() returns INF on a map
# with no water, and a rule meaning "well away from water" written as
# [16, 99999] then rejects every point on a dry map - because INF > 99999.
# That silently killed the conifer layer on sentinel_divide: the rule was
# correct, the map had no water, and the layer placed nothing.
static func _in_range(v: float, r) -> bool:
	if r == null:
		return true
	if not (r is Array) or r.size() < 2:
		return true
	if r[0] != null and v < float(r[0]):
		return false
	if r[1] != null and v > float(r[1]):
		return false
	return true


# Aspect is CIRCULAR, so it cannot use _in_range: a rule wanting "north-ish"
# spans 315..45 and wraps through 0. Expressed instead as [centre, tolerance].
static func _aspect_ok(aspect: float, spec) -> bool:
	if spec == null:
		return true
	if aspect < 0.0:
		# Flat ground has no aspect. A rule that asks about aspect does not
		# apply to it - returning "matches" here would carpet every flat plain
		# with north-facing moss.
		return false
	if not (spec is Array) or spec.size() < 2:
		return true
	var centre := float(spec[0])
	var tol := float(spec[1])
	var diff: float = absf(fposmod(aspect - centre + 180.0, 360.0) - 180.0)
	return diff <= tol


static func _matches(map_def: Dictionary, where: Dictionary, x: float, z: float,
		h: float, slope: float) -> bool:
	if not _in_range(slope, where.get("slope")):
		return false
	if not _in_range(h, where.get("height")):
		return false
	if where.has("aspect") and where["aspect"] != null:
		if not _aspect_ok(TerrainBuilderScript.aspect_at(map_def, x, z), where["aspect"]):
			return false
	if where.has("water_distance") and where["water_distance"] != null:
		if not _in_range(TerrainBuilderScript.water_distance_at(map_def, x, z), where["water_distance"]):
			return false
	if where.has("curvature") and where["curvature"] != null:
		if not _in_range(TerrainBuilderScript.curvature_at(map_def, x, z), where["curvature"]):
			return false
	return true


# --- the pass ---------------------------------------------------------------

# Returns per-layer placement counts, which the probe and the sculpt tool both
# report. `ticker` spreads the walk across frames exactly as the v1 passes do.
static func scatter(map_def: Dictionary, parent: Node3D, prop_scale: float = 1.0,
		ticker: Node = null, map_id: String = "") -> Dictionary:
	var rules := load_rules(rules_name_for(map_def))
	var stats := {}
	if rules.is_empty() or parent == null:
		return stats

	var half: Vector2 = MapCatalogScript.half_extents(map_def)
	var batcher = AmbientScatterScript.get_or_create(parent)
	var avoid: Array = TerrainBuilderScript._ambient_avoid_points(map_def)
	# Absolute world units, NOT scaled by prop_scale. prop_scale means "how big
	# is a prop", and multiplying the SPACING by it as well quadrupled every
	# gap the moment prop size went to 4x - 1657 props became 219 and the map
	# went bare. Spacing is a property of the map's extent, which the rule
	# author already knows; prop size is a property of the models.
	var avoid_r: float = float(rules.get("avoid_radius", 14.0))
	var placed_total := 0
	var placements: Array = []
	var seed_base := hash(map_id if map_id != "" else str(map_def.get("name", "map")))

	var deadline: int = Time.get_ticks_usec() + 8000

	for layer in rules.get("layers", []):
		if placed_total >= GLOBAL_PROP_CEILING:
			push_warning("TerrainDressing: global ceiling %d reached - later layers skipped." % GLOBAL_PROP_CEILING)
			break
		var lid := str(layer.get("id", "?"))
		var paths := _prop_paths(rules, str(layer.get("props", "")))
		if paths.is_empty():
			stats[lid] = 0
			continue
		var where: Dictionary = layer.get("where", {})
		var spacing: float = maxf(float(layer.get("spacing", 30.0)), 2.0)
		var density: float = clampf(float(layer.get("density", 0.5)), 0.0, 1.0)
		var max_count: int = int(layer.get("max_count", 400))
		var scale_range: Array = layer.get("scale", [0.8, 1.3])
		var sink_range: Array = layer.get("sink", [0.0, 0.0])
		var align: bool = bool(layer.get("align_to_slope", false))
		var lean: float = float(layer.get("lean", 0.0))
		var count := 0

		var rng := RandomNumberGenerator.new()
		var gz := -half.y
		var row := 0
		while gz < half.y and count < max_count:
			# Headless / probe callers (no SceneTree ticker): fall back to a
			# busy wait rather than a real await. See _build_conforming_zone_
			# mesh_stepwise (terrain_builder.gd:3843+) for the same fix.
			if Time.get_ticks_usec() >= deadline:
				if ticker == null:
					deadline = Time.get_ticks_usec() + 8000
				else:
					await ticker.get_tree().process_frame
					deadline = Time.get_ticks_usec() + 8000
			var col := 0
			var gx := -half.x
			while gx < half.x and count < max_count:
				# Seeded per CELL, so the same cell always decides the same way
				# regardless of what any other layer did first.
				rng.seed = hash("%d:%s:%d:%d" % [seed_base, lid, row, col])
				col += 1
				var x: float = gx + rng.randf_range(-spacing * 0.42, spacing * 0.42)
				var z: float = gz + rng.randf_range(-spacing * 0.42, spacing * 0.42)
				gx += spacing
				if rng.randf() > density:
					continue
				var pos := Vector3(x, 0.0, z)
				if TerrainBuilderScript._is_over_water_or_obstacle(map_def, pos):
					continue
				var h: float = TerrainBuilderScript.height_at(map_def, x, z)
				var slope: float = TerrainBuilderScript.slope_at(map_def, x, z)
				if not _matches(map_def, where, x, z, h, slope):
					continue
				var too_close := false
				for a in avoid:
					if Vector2(x - a.x, z - a.z).length() < avoid_r:
						too_close = true
						break
				if too_close:
					continue

				var scene_path: String = paths[rng.randi() % paths.size()]
				var inst := Node3D.new()
				var s: float = rng.randf_range(float(scale_range[0]), float(scale_range[1])) * prop_scale
				inst.scale = Vector3.ONE * s
				inst.rotation.y = rng.randf_range(0.0, TAU)
				if lean > 0.0:
					inst.rotation.x = rng.randf_range(-lean, lean)
					inst.rotation.z = rng.randf_range(-lean, lean)
				var sink: float = rng.randf_range(float(sink_range[0]), float(sink_range[1])) * s
				inst.position = Vector3(x, h - sink, z)
				if align:
					_align_to_ground(inst, map_def, x, z)
				parent.add_child(inst)
				if batcher != null:
					# MultiMesh: a thousand loose glTF subtrees is a thousand
					# draw calls, which is what the batcher exists to avoid.
					var handle = batcher.register(scene_path, inst)
					if handle != null:
						# Keep the transform to re-apply AFTER commit. See
						# _finalise() - commit() reads global_transform, which
						# is identity until a frame has propagated it.
						placements.append([handle, inst.transform])
				count += 1
				placed_total += 1
			gz += spacing
			row += 1
		stats[lid] = count

	# COMMIT HERE, then re-apply every transform explicitly.
	#
	# AmbientScatter.commit() builds its MultiMesh instance transforms from
	# each registered node's GLOBAL transform. A Node3D only has a valid
	# global transform once the tree has propagated one, which has not
	# happened while the world is still being built in a single call - so
	# every prop committed as identity and all 3300 of them stacked at the
	# origin, invisibly. Depending on frame timing for placement is the bug;
	# set_node_transform() works after commit and takes the value directly.
	if batcher != null:
		batcher.commit()
		for pair in placements:
			batcher.set_node_transform(pair[0], pair[1])
	return stats


# Tilt a prop so it sits ON the slope rather than standing vertically out of
# it. A boulder standing plumb on a 40-degree face reads as a dropped prop.
static func _align_to_ground(node: Node3D, map_def: Dictionary, x: float, z: float) -> void:
	const D := 2.0
	var h0 := TerrainBuilderScript.height_at(map_def, x, z)
	var dx := TerrainBuilderScript.height_at(map_def, x + D, z) - h0
	var dz := TerrainBuilderScript.height_at(map_def, x, z + D) - h0
	var n := Vector3(-dx, D, -dz).normalized()
	if n.is_equal_approx(Vector3.UP):
		return
	var axis := Vector3.UP.cross(n)
	if axis.length() < 1e-4:
		return
	node.rotate(axis.normalized(), Vector3.UP.angle_to(n))
