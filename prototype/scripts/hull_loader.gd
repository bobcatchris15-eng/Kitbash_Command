# HullLoader (use via preload, e.g. const HullLoader = preload("res://scripts/hull_loader.gd"))
# Hull modding (HULL_MODDING_PLAN.md): scans same-stem .glb+.json pairs from
# two directories - built-in hulls under res://assets/models/hulls (packed
# into the exported .pck, read-only to a real player) and player-added mod
# hulls under user://mods/hulls (writable after ship, same principle as this
# project's existing user://blueprints/ - see blueprint_manager.gd) - and
# merges them into one hull-only catalog dict, shaped exactly like the hull
# entries ModuleCatalog.get_catalog() used to hardcode.
#
# Scanned once, lazily, on first get_hulls() call - NOT per call. get_catalog()
# is a static func that rebuilds a brand-new dict literal on every single call
# and get_module_data() (the hottest function in the whole catalog system)
# calls it on nearly every stat calc/mount decision/AI tick - a directory
# scan + N file reads + N JSON parses on every one of those calls would be a
# real, immediate performance regression. This class owns the one-time scan;
# ModuleCatalog just merges the cached result in cheaply.
#
# Deliberately no `class_name` here (project gotcha: class_name globals
# aren't reliable in scripts run headless before the .godot cache exists -
# this bit module_placer.gd once) - always access via preload(), same
# convention as mesh_asset_loader.gd.

const BUILTIN_DIR = "res://assets/models/hulls"
const MOD_DIR = "user://mods/hulls"

# Hand-authored default armor plans, one entry per hull id. A SEPARATE FILE
# rather than a key in the sidecars for a hard reason: every
# assets/models/hulls/*.json is regenerated wholesale by
# tools/blender/build_vehicle_hulls.py, so a balance key added there survives
# exactly until the next hull bake. Mesh pipeline and balance data are kept
# apart on purpose.
#
# Purely additive - a hull with no entry (including every mod hull, which has
# no way to ship into a res:// file) returns {} and loads bare, which is the
# behaviour that predates this file.
const ARMOR_DEFAULTS_PATH = "res://data/armor/hull_defaults.json"

const REQUIRED_FIELDS = ["name", "hp", "weight", "metal", "crystal", "size", "color"]
const NUMERIC_TYPES = [TYPE_INT, TYPE_FLOAT]

# brenntal_medium_a is the default hull: Brenntal Schwerbau, Medium class,
# variant A - the plainest two-tier casemate in the catalogue, which is what a
# fallback should be. The same 7+ call sites (battle_unit.gd, battlefield.gd,
# blueprint_manager.gd, module_placer.gd, stat_calculator.gd, enemy_ai.gd,
# skirmish.gd) that hardcode a safe fallback hull name this one, so it must
# always exist and always be loadable. A moddable hull system can't let that
# guarantee depend on a third-party-editable sidecar file never going
# missing/corrupt, so this is a last-resort embedded copy of its own shipped
# sidecar (assets/models/hulls/brenntal_medium_a.json) - only ever used if
# that file is somehow missing or fails validation, which should never happen
# in a normal install and is loud (push_error) specifically because it
# indicates a broken installation, not a normal modding scenario.
#
# Keep the numbers below in sync with that sidecar by hand if it is
# regenerated: tools/blender/build_vehicle_hulls.py derives them from the
# hull's volume, so changing its design envelope changes these.
const PROTECTED_DEFAULT_HULL_ID := "brenntal_medium_a"
const PROTECTED_DEFAULT_HULL_FALLBACK = {
	"name": "Brenntal Casemate Medium", "hp": 694.7, "weight": 496.0, "metal": 168, "crystal": 34,
	# base_energy (storage) and base_power (generation) are scaled off the
	# hull's volume so every hull has an intrinsic baseline power budget.
	"dps": 0.0, "is_foundation": false, "base_energy": 74.6, "base_power": 5.57,
	"base_vision": 20.0,
	"draught": 0.5, "underside_y_bias": 0.0, "turreted_capable": true, "category": "hull",
	# Authored nose-at--Z with the AABB already equal to `size`, so the
	# orientation search must not run - see build_vehicle_hulls.py's
	# write_sidecar().
	"visual_yaw_offset_deg": 0.0, "visual_pitch_offset_deg": 0.0,
	"visual_roll_offset_deg": 0.0,
}

static var _cache: Dictionary = {}
static var _mod_ids: Dictionary = {}
static var _scanned: bool = false
static var _armor_defaults: Dictionary = {}
static var _armor_defaults_loaded: bool = false

static func get_hulls() -> Dictionary:
	_ensure_scanned()
	return _cache

# Whether a given hull id was sourced from user://mods/hulls (as opposed to
# the built-in res:// directory) - not currently surfaced in any UI, but
# cheap to track and useful for a future "modded" badge / for tests.
static func is_modded(type_id: String) -> bool:
	_ensure_scanned()
	return _mod_ids.has(type_id)

# Test-only: forces the next get_hulls() call to rescan from disk instead of
# reusing the cached result. Production code never needs this - the whole
# point of the cache is that it lives for the process lifetime - but the
# automated test suite runs everything in one process and needs to add a
# temp mod file mid-run and see it picked up.
static func reset_cache_for_tests() -> void:
	_cache = {}
	_mod_ids = {}
	_scanned = false
	_armor_defaults = {}
	_armor_defaults_loaded = false


# The authored default armor plan for a hull, as {side: {material, thickness}},
# or {} when the hull has no entry. Read once per process, same lifetime
# argument as the hull scan above.
#
# Deliberately NOT merged into the hull catalog entry: _validate_and_default()
# rebuilds that dict field by field and every consumer of it treats its keys as
# hull STATS. An armor plan is a starting suggestion for the Design Lab, and
# folding it in would put it in front of code (costing, drivetrain, the AI's
# hull picker) that has no business reading it.
static func get_armor_default(type_id: String) -> Dictionary:
	_ensure_armor_defaults()
	var entry = _armor_defaults.get(type_id, null)
	if not (entry is Dictionary):
		return {}
	var sides = (entry as Dictionary).get("sides", null)
	if not (sides is Dictionary):
		return {}
	return sides


static func _ensure_armor_defaults() -> void:
	if _armor_defaults_loaded:
		return
	# Set before any early return: a missing or malformed file must degrade to
	# "no hull has a default", not retry the parse on every hull load.
	_armor_defaults_loaded = true
	_armor_defaults = {}
	if not FileAccess.file_exists(ARMOR_DEFAULTS_PATH):
		return
	var text := FileAccess.get_file_as_string(ARMOR_DEFAULTS_PATH)
	if text.is_empty():
		push_warning("HullLoader: '%s' is empty - no hull will pre-fill armor." % ARMOR_DEFAULTS_PATH)
		return
	var json := JSON.new()
	if json.parse(text) != OK:
		push_warning("HullLoader: '%s' failed to parse at line %d (%s) - no hull will pre-fill armor." % [
			ARMOR_DEFAULTS_PATH, json.get_error_line(), json.get_error_message()])
		return
	var raw = json.get_data()
	if not (raw is Dictionary):
		push_warning("HullLoader: '%s' must be a JSON object." % ARMOR_DEFAULTS_PATH)
		return
	var hulls = (raw as Dictionary).get("hulls", null)
	if not (hulls is Dictionary):
		push_warning("HullLoader: '%s' has no \"hulls\" object." % ARMOR_DEFAULTS_PATH)
		return
	_armor_defaults = hulls

static func _ensure_scanned() -> void:
	if _scanned:
		return
	_cache = {}
	_mod_ids = {}
	DirAccess.make_dir_recursive_absolute(MOD_DIR)
	_scan_directory(BUILTIN_DIR, false)
	_scan_directory(MOD_DIR, true)
	_ensure_default_hull_protected()
	_scanned = true

static func _scan_directory(dir_path: String, is_mod: bool) -> void:
	var dir = DirAccess.open(dir_path)
	if not dir:
		return # directory doesn't exist yet - not an error (mods dir starts empty)
	# Scan .json sidecars, not .glb files.
	#
	# The scan used to be driven by the .glb, which made a mesh file mandatory
	# for a hull to exist at all. That is wrong for a hull whose shape is a
	# declared primitive ("primitive_shape" - the cube/orb/rod/slab): they
	# have no mesh to ship, and deleting their placeholder .glb made all four
	# vanish from the catalog entirely rather than fall back to a primitive.
	# The sidecar is the actual hull definition, so it is what defines
	# existence; _try_load_hull still warns about a sidecar that names neither
	# a mesh nor a primitive.
	dir.list_dir_begin()
	var fname = dir.get_next()
	while fname != "":
		if not dir.current_is_dir() and fname.get_extension() == "json":
			_try_load_hull(dir_path, fname.get_basename(), is_mod)
		fname = dir.get_next()
	dir.list_dir_end()

static func _try_load_hull(dir_path: String, stem: String, is_mod: bool) -> void:
	var regex = RegEx.new()
	regex.compile("^[a-z0-9_]+$")
	if not regex.search(stem):
		push_warning("HullLoader: skipping '%s.json' in %s - type_id must be lowercase snake_case [a-z0-9_]+" % [stem, dir_path])
		return

	var json_path = "%s/%s.json" % [dir_path, stem]
	if not FileAccess.file_exists(json_path):
		return

	var file = FileAccess.open(json_path, FileAccess.READ)
	if not file:
		push_warning("HullLoader: skipping '%s' - could not open file" % json_path)
		return
	var text = file.get_as_text()
	file.close()

	var json = JSON.new()
	var parse_err = json.parse(text)
	if parse_err != OK:
		push_warning("HullLoader: skipping '%s' - JSON parse error: %s (line %d)" % [json_path, json.get_error_message(), json.get_error_line()])
		return
	var raw = json.get_data()
	if typeof(raw) != TYPE_DICTIONARY:
		push_warning("HullLoader: skipping '%s' - sidecar JSON must be an object" % json_path)
		return

	var validated = _validate_and_default(raw, json_path)
	if validated == null:
		return # _validate_and_default already logged the specific reason

	validated["category"] = "hull" # never trusted from the sidecar - see class header

	# A hull needs SOME shape: a mesh beside it (.glb, or a baked .res from
	# sdf_mesh_baker.gd/hull_builder.gd's export) or a declared primitive.
	# Neither is not fatal (module_placer falls back to a plain box), but it is
	# almost always a mistake worth surfacing.
	if not validated.has("primitive_shape") \
			and not FileAccess.file_exists("%s/%s.glb" % [dir_path, stem]) \
			and not FileAccess.file_exists("%s/%s.res" % [dir_path, stem]):
		push_warning("HullLoader: '%s' has neither a matching .glb/.res nor a \"primitive_shape\" - it will render as a plain box" % json_path)

	if _cache.has(stem):
		if is_mod:
			push_warning("HullLoader: mod hull '%s' (%s) OVERRIDES the built-in hull of the same id - the mod's data wins" % [stem, json_path])
		else:
			push_warning("HullLoader: duplicate built-in hull id '%s' at '%s' - keeping the first one found" % [stem, json_path])
			return

	_cache[stem] = validated
	if is_mod:
		_mod_ids[stem] = true
	elif _mod_ids.has(stem):
		_mod_ids.erase(stem) # built-in shouldn't be scanned after mods, but stay correct either way

static func _validate_and_default(raw: Dictionary, source_path: String):
	for field in REQUIRED_FIELDS:
		if not raw.has(field):
			push_warning("HullLoader: skipping '%s' - missing required field '%s'" % [source_path, field])
			return null

	if typeof(raw["name"]) != TYPE_STRING or raw["name"].strip_edges() == "":
		push_warning("HullLoader: skipping '%s' - 'name' must be a non-empty string" % source_path)
		return null

	for field in ["hp", "weight", "metal", "crystal"]:
		if typeof(raw[field]) not in NUMERIC_TYPES:
			push_warning("HullLoader: skipping '%s' - '%s' must be a number" % [source_path, field])
			return null

	var size_raw = raw["size"]
	if typeof(size_raw) != TYPE_ARRAY or size_raw.size() != 3:
		push_warning("HullLoader: skipping '%s' - 'size' must be a 3-element array [x, y, z]" % source_path)
		return null
	for v in size_raw:
		if typeof(v) not in NUMERIC_TYPES:
			push_warning("HullLoader: skipping '%s' - 'size' must contain only numbers" % source_path)
			return null

	var color_raw = raw["color"]
	if typeof(color_raw) != TYPE_ARRAY or (color_raw.size() != 3 and color_raw.size() != 4):
		push_warning("HullLoader: skipping '%s' - 'color' must be a 3 or 4-element array [r, g, b] or [r, g, b, a]" % source_path)
		return null
	for v in color_raw:
		if typeof(v) not in NUMERIC_TYPES:
			push_warning("HullLoader: skipping '%s' - 'color' must contain only numbers" % source_path)
			return null

	# Defaults mirror the exact getter defaults ModuleCatalog already used
	# for these optional fields (HULL_MODDING_PLAN.md §1/§3) - a sparse
	# sidecar that only fills in the required fields behaves identically to
	# today's code path for anything it omits.
	var out = {
		"name": raw["name"],
		"hp": float(raw["hp"]),
		"weight": float(raw["weight"]),
		"metal": int(raw["metal"]),
		"crystal": int(raw["crystal"]),
		"dps": float(raw.get("dps", 0.0)),
		"size": Vector3(size_raw[0], size_raw[1], size_raw[2]),
		"color": Color(color_raw[0], color_raw[1], color_raw[2], color_raw[3] if color_raw.size() == 4 else 1.0),
		"is_foundation": bool(raw.get("is_foundation", false)),
		"base_energy": float(raw.get("base_energy", 0.0)),
		# Generation, and a separate stat from base_energy (storage) - see
		# ModuleCatalog.get_base_power(). Copied through explicitly like
		# everything else here: this dict is built field by field rather than
		# merged wholesale, so a sidecar key with no line of its own is silently
		# dropped no matter how many files declare it.
		#
		# Defaulted to 0.0 rather than to some fraction of base_energy, which
		# would quietly reintroduce the "storage manufactures generation"
		# derivation this stat was split out to remove. A hull that declares no
		# generation has none, and its designs will need a fusion generator -
		# which is a legible outcome, unlike a hidden formula.
		"base_power": float(raw.get("base_power", 0.0)),
		"base_vision": float(raw.get("base_vision", 20.0)),
		"draught": float(raw.get("draught", 0.5)),
		"underside_y_bias": float(raw.get("underside_y_bias", 0.0)),
		"turreted_capable": bool(raw.get("turreted_capable", true)),
	}

	# Catalogue provenance, written by tools/blender/build_vehicle_hulls.py.
	# Copied through explicitly because this dict is rebuilt field by field and
	# silently drops anything without a line of its own.
	#
	# "hull_class" is load-bearing, not cosmetic: ModuleCatalog's
	# get_hull_size_tier() prefers it over the weight breakpoints, so a hull
	# that declares "Medium" lands in the medium production tier and gets the
	# medium harvester-hopper multiplier regardless of how the weight formula
	# drifts. Optional - a mod hull that omits it falls back to weight.
	for passthrough in ["manufacturer", "hull_class"]:
		if raw.has(passthrough) and typeof(raw[passthrough]) == TYPE_STRING:
			out[passthrough] = raw[passthrough]

	# A hull whose shape IS a plain primitive declares it here instead of
	# shipping a .glb (see MeshAssetLoader.get_hull_mesh). "box" | "sphere" |
	# "cylinder", built at unit size and stretched to the hull's own `size` by
	# ModuleCatalog.get_hull_mesh_fit() like any other mesh.
	if raw.has("primitive_shape") and typeof(raw["primitive_shape"]) == TYPE_STRING:
		out["primitive_shape"] = raw["primitive_shape"]

	# Explicit mesh-orientation overrides. Copied through ONLY when actually
	# present: ModuleCatalog.has_explicit_hull_orientation() keys off whether
	# these exist at all, so defaulting them here would permanently disable
	# the automatic orientation search for every JSON-defined hull. This
	# dictionary is rebuilt field by field, so anything not named here is
	# silently dropped - which is what used to happen to these three, making
	# the documented escape hatch unreachable for exactly the hulls (authored
	# .glb ones) that need it most.
	for override_field in ["visual_yaw_offset_deg", "visual_pitch_offset_deg", "visual_roll_offset_deg"]:
		if raw.has(override_field) and typeof(raw[override_field]) in NUMERIC_TYPES:
			out[override_field] = float(raw[override_field])

	return out

static func _ensure_default_hull_protected() -> void:
	if _cache.has(PROTECTED_DEFAULT_HULL_ID):
		return
	push_error("HullLoader: %s sidecar is missing or invalid at %s/%s.json - falling back to an embedded protected default. This should never happen in a normal install; 7+ scripts hardcode %s as their safe fallback hull." % [PROTECTED_DEFAULT_HULL_ID, BUILTIN_DIR, PROTECTED_DEFAULT_HULL_ID, PROTECTED_DEFAULT_HULL_ID])
	var fallback = PROTECTED_DEFAULT_HULL_FALLBACK.duplicate()
	# Typed values the dictionary literal above can't hold. Both mirror
	# assets/models/hulls/brenntal_medium_a.json.
	fallback["size"] = Vector3(3.6, 1.4, 5.9)
	fallback["color"] = Color(0.298, 0.302, 0.322, 1.0)
	_cache[PROTECTED_DEFAULT_HULL_ID] = fallback
