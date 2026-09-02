extends SceneTree
# Regression sweep for the Design Lab rule: every exposed tweak must drive
# BOTH a visible change to the module's rendered bounds AND a stat change.
#
# For each module with tweak sliders (LabDocument.TWEAK_SPECS for weapons
# and utility, ModuleCatalog.LOCOMOTION_TWEAK_SPECS for locomotion) we
# rebuild the module visual three times - every dial at its default, then
# one dial dragged to min and to max - and compare three visual
# fingerprints: the merged mesh AABB, the MeshInstance3D count, and a
# per-mesh geometry histogram (mesh resource / local size, world size,
# world position). The histogram catches changes a merged AABB blind-spots
# because a dominant sibling swallows them - fuse rings that grow inside a
# housing, a rod that thickens, an emitter array that lengthens, a rotor
# drum that swaps mesh variant - while a pure AABB contract stays fairly
# stable against procedural rebuild noise.
# On the stat side we diff weight, cost, dps, range, energy capacity, power
# output, heal rate and vision bonus (the full ModuleData getter surface)
# plus thrust/capacity (drivetrain.gd) across the same variants.
#
# Two proven carve-outs (each verified by code inspection, not guessed):
#   - "layout"  - a locomotion count tweak (num_axles, leg_count, etc.) that
#     station-placement consumes at VEHICLE ASSEMBLY, not inside the single
#     module's visual. The module here is built in isolation, so the probe
#     cannot see the extra wheel/leg/prop stations the real Lab puts around
#     the hull; the layout code demonstrably reads them. Stat still asserted.
#   - "material" - a tweak that only repaints the module (plasma thruster's
#     afterburner glow). Color changes are invisible to every geometry
#     fingerprint. Stat still asserted.
#
# Deferred builds (the blimp envelope attaches on tree_entered) need real
# frames, so run WITHOUT --quit:
#   godot --headless --path . --script res://tools/probe_tweak_drive.gd

const VisualBuilder = preload("res://scripts/visual_builder.gd")
const ModuleCatalogScript = preload("res://scripts/module_catalog.gd")
const LabDocumentScript = preload("res://scripts/lab_document.gd")
const WeaponRangeScript = preload("res://scripts/weapon_range.gd")
const DrivetrainScript = preload("res://scripts/drivetrain.gd")

# Tweak names whose visual effect lives outside the isolated module build.
const CARVE_OUT := {
	"wheels": {"num_axles": "layout"},
	"legs": {"leg_count": "layout"},
	"helicopter_rotors": {"rotor_units": "layout"},
	"hover_engine": {"pad_count": "layout"},
	"buoyant_envelope": {"prop_count": "layout"},
	"plasma_thruster": {"thruster_count": "layout", "afterburner": "material"},
}

const EPS := 1e-4
var _failures: Array = []
var _checked := 0

func _init() -> void:
	var weapon_specs: Dictionary = LabDocumentScript.TWEAK_SPECS
	var loco_specs: Dictionary = ModuleCatalogScript.LOCOMOTION_TWEAK_SPECS

	var rows: Array = []
	for type_id in weapon_specs:
		var wspecs: Array = weapon_specs[type_id]
		if wspecs.size() > 0:
			rows.append({"id": type_id, "specs": wspecs, "loco": false})
	for type_id in loco_specs:
		var lspecs: Array = loco_specs[type_id]
		if lspecs.size() > 0:
			rows.append({"id": type_id, "specs": lspecs, "loco": true})
	rows.sort_custom(func(a, b): return str(a["id"]) < str(b["id"]))

	for row in rows:
		for spec in row["specs"]:
			await _check_one(str(row["id"]), row["specs"], spec, bool(row["loco"]))
		await process_frame

	print("")
	if _failures.is_empty():
		print("[PASS] %d tweaks: every one drives a visual AND a stat change" % _checked)
		quit(0)
	else:
		print("[FAIL] %d tweak(s) not doubly backed:" % _failures.size())
		for f in _failures:
			print("  " + f)
		quit(1)


func _check_one(type_id: String, specs: Array, spec: Dictionary, is_loco: bool) -> void:
	var name: String = str(spec.get("name", "?"))
	var label: String = str(spec.get("label", name))
	var is_bool: bool = str(spec.get("type", "")) == "bool" \
		or typeof(spec.get("default")) == TYPE_BOOL

	var defaults := {}
	for s in specs:
		if str(s.get("type", "")) == "bool" or typeof(s.get("default")) == TYPE_BOOL:
			defaults[str(s.get("name", ""))] = bool(s.get("default", false))
		else:
			defaults[str(s.get("name", ""))] = s.get("default", 1.0)

	var var_min: Dictionary = defaults.duplicate()
	var var_def: Dictionary = defaults.duplicate()
	var var_max: Dictionary = defaults.duplicate()
	if is_bool:
		var_min[name] = false
		var_max[name] = true
	else:
		var v_min: float = float(spec.get("min", 1.0))
		var v_max: float = float(spec.get("max", v_min + 1.0))
		if absf(v_max - v_min) < 1e-6:
			return
		var_min[name] = v_min
		var_max[name] = v_max

	var sig_min: Array = await _stats_and_bounds(type_id, var_min, is_loco)
	var sig_def: Array = await _stats_and_bounds(type_id, var_def, is_loco)
	var sig_max: Array = await _stats_and_bounds(type_id, var_max, is_loco)

	var problems: Array = []
	var vis_kind := _bounds_note(sig_def, sig_max)
	var bounds_moved := _bounds_differ(sig_min, sig_def) or _bounds_differ(sig_max, sig_def)
	var count_moved := _mesh_count_differs(sig_def, sig_min, sig_max)
	var hist_moved := _hist_differs(sig_def, sig_min, sig_max)
	if bounds_moved:
		vis_kind = "bounds"
	elif count_moved:
		vis_kind = "count"
	elif hist_moved:
		vis_kind = "histogram"
	else:
		vis_kind = "none"
	var carve: String = str(CARVE_OUT.get(type_id, {}).get(name, ""))
	if carve != "":
		vis_kind = carve
	elif vis_kind == "none":
		problems.append("NO visual delta")
	var moved_stats: Array = _moved_stats(sig_def, sig_min, sig_max)
	if moved_stats.is_empty():
		problems.append("NO stat delta")
	_checked += 1

	if problems.is_empty():
		print("OK   %-24s %-22s vis(%-12s) stat(%s)" % [
			type_id, label, vis_kind, "|".join(moved_stats)])
	else:
		_failures.append("%s.%s (\"%s\"): %s" % [type_id, name, label, ", ".join(problems)])


# Builds one module visual in a fresh chassis (in the tree so deferred builds
# like the blimp envelope and facet arcs attach) and reads its merged mesh
# bounds, mesh count, per-mesh histogram and a full stat fingerprint. Returns
# a flat array:
# [bounds pos.xyz, bounds size.xyz, weight, cost_m, cost_c, dps, range,
#  energy_cap, power_out, heal, vision, thrust, capacity, mesh_count, histogram]
# (thrust/capacity only for locomotion types).
func _stats_and_bounds(type_id: String, tweaks: Dictionary, is_loco: bool) -> Array:
	var catalog_data: Dictionary = ModuleCatalogScript.get_module_data(type_id)
	var chassis := Node3D.new()
	chassis.name = "probe_chassis"
	root.add_child(chassis)
	var container := Node3D.new()
	container.name = "probe_module"
	chassis.add_child(container)
	VisualBuilder.build_visual(type_id, container,
		catalog_data.get("size", Vector3.ONE),
		catalog_data.get("color", Color.WHITE), tweaks)
	await process_frame
	await process_frame

	var aabb: AABB = _merged_aabb(chassis)
	var sig: Array = [
		aabb.position.x, aabb.position.y, aabb.position.z,
		aabb.size.x, aabb.size.y, aabb.size.z,
	]
	var md = VisualBuilder.make_module_data(type_id)
	md.tweaks = tweaks.duplicate()
	sig.append(md.get_weight())
	var cost: Vector2i = md.get_cost()
	sig.append(float(cost.x))
	sig.append(float(cost.y))
	sig.append(md.get_dps())
	sig.append(WeaponRangeScript.compute(type_id, tweaks))
	sig.append(md.get_energy_capacity())
	sig.append(md.get_power_output())
	sig.append(md.get_heal_rate())
	sig.append(md.get_vision_bonus())
	if is_loco:
		var tf: Dictionary = DrivetrainScript.tweak_factors(type_id, tweaks)
		sig.append(float(tf.get("thrust", 1.0)))
		sig.append(float(tf.get("capacity", 1.0)))
	sig.append(float(_mesh_count(chassis)))
	sig.append(_mesh_histogram(chassis))

	chassis.free()
	return sig


# Stable per-mesh geometry signature: for every visible MeshInstance3D, the
# mesh's identity (authored resource path, or "proc:" + its local size for
# procedural boxes so two identical boxes merge), its world-extent size and
# its world centre. Sorted and joined so ordering noise never matters.
func _mesh_histogram(root_node: Node3D) -> String:
	var rows: Array = []
	var stack: Array = [root_node]
	while not stack.is_empty():
		var node: Node = stack.pop_back()
		if node is MeshInstance3D and is_instance_valid(node) and node.mesh != null and node.visible:
			var mi := node as MeshInstance3D
			var lp := mi.mesh.resource_path
			if lp == "":
				lp = "proc:%s" % _q3(mi.mesh.get_aabb().size)
			var wa: AABB = mi.global_transform * mi.mesh.get_aabb()
			rows.append("%s|%s|%s" % [lp, _q3(wa.size), _q3(wa.position + wa.size * 0.5)])
		for child in node.get_children():
			stack.append(child)
	rows.sort()
	return "\n".join(rows)


func _q3(v: Vector3) -> String:
	return "%.3f,%.3f,%.3f" % [v.x, v.y, v.z]


func _merged_aabb(root_node: Node3D) -> AABB:
	var total := AABB()
	var first := true
	var stack: Array = [root_node]
	while not stack.is_empty():
		var node: Node = stack.pop_back()
		if node is MeshInstance3D and is_instance_valid(node) and node.mesh != null and node.visible:
			var mi := node as MeshInstance3D
			var wa: AABB = mi.global_transform * mi.mesh.get_aabb()
			if first:
				total = wa
				first = false
			else:
				total = total.merge(wa)
		for child in node.get_children():
			stack.append(child)
	return total


func _mesh_count(root_node: Node3D) -> int:
	var n := 0
	var stack: Array = [root_node]
	while not stack.is_empty():
		var node: Node = stack.pop_back()
		if node is MeshInstance3D and is_instance_valid(node) and node.visible:
			n += 1
		for child in node.get_children():
			stack.append(child)
	return n


func _mesh_count_differs(def_sig: Array, min_sig: Array, max_sig: Array) -> bool:
	var k: int = def_sig.size() - 2
	return int(min_sig[k]) - int(def_sig[k]) != 0 or int(max_sig[k]) - int(def_sig[k]) != 0


func _hist_differs(def_sig: Array, min_sig: Array, max_sig: Array) -> bool:
	var k: int = def_sig.size() - 1
	return def_sig[k] != min_sig[k] or def_sig[k] != max_sig[k]


func _bounds_differ(a: Array, b: Array) -> bool:
	for i in range(6):
		if absf(float(a[i]) - float(b[i])) > EPS:
			return true
	return false


func _moved_stats(def_sig: Array, min_sig: Array, max_sig: Array) -> Array:
	var labels := [
		[6, "weight"], [7, "cost"], [8, "cost"],
		[9, "dps"], [10, "range"],
		[11, "energy"], [12, "power"], [13, "heal"], [14, "vision"],
		[15, "thrust"], [16, "capacity"],
	]
	var moved: Array = []
	for row in labels:
		var k: int = row[0]
		if k >= def_sig.size():
			continue
		if absf(float(min_sig[k]) - float(def_sig[k])) > EPS or absf(float(max_sig[k]) - float(def_sig[k])) > EPS:
			if not moved.has(row[1]):
				moved.append(row[1])
	return moved


func _bounds_note(def_sig: Array, max_sig: Array) -> String:
	var dy: float = float(max_sig[4]) - float(def_sig[4])
	var dz: float = float(max_sig[5]) - float(def_sig[5])
	var dx: float = float(max_sig[3]) - float(def_sig[3])
	return "dx%.2f dy%.2f dz%.2f" % [dx, dy, dz]