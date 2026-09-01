extends SceneTree
# Measures, for each spawned unit: terrain height under the unit, the unit's
# origin Y, and the world-space lowest point of every locomotion mesh. Answers
# "are the wheels touching the ground" with a number instead of a squint.

var _scene: Node = null
var _ready_flag := false
var _frames := 0


func _initialize() -> void:
	var mc = Node.new()
	mc.name = "MatchConfig"
	mc.set_script(load("res://scripts/match_config.gd"))
	var rs = load("res://scripts/match_rule_set.gd").skirmish(
		"the_great_valley", "industrialists", "crimson_concordat", [
			"res://data/loadout/bulwark_mbt.json",
			"res://data/loadout/rattler_scout.json",
			"res://data/loadout/vulture_harvester.json",
		])
	rs.log_profiling = false
	mc.rule_set = rs
	mc.selected_map_id = "the_great_valley"
	root.add_child(mc)
	_scene = load("res://scenes/Battle.tscn").instantiate()
	if _scene.has_signal("world_ready"):
		_scene.connect("world_ready", func(): _ready_flag = true)
	root.add_child(_scene)


var _low_path := ""
var _low_toplevel := false

func _lowest_mesh_y(n: Node3D) -> float:
	var lowest := INF
	var stack: Array = [n]
	while not stack.is_empty():
		var c = stack.pop_back()
		for k in c.get_children():
			stack.append(k)
		if c is MeshInstance3D and c.mesh != null and c.visible:
			var ab: AABB = c.mesh.get_aabb()
			var xf: Transform3D = (c as MeshInstance3D).global_transform
			for i in range(8):
				var y: float = (xf * ab.get_endpoint(i)).y
				if y < lowest:
					lowest = y
					_low_path = str(n.get_path_to(c))
					_low_toplevel = (c as Node3D).top_level
	return lowest


func _process(_dt: float) -> bool:
	if not _ready_flag:
		_frames += 1
		if _frames > 6000:
			print("TIMEOUT"); quit(1)
		return false
	_frames += 1
	if _frames < 300:
		return false

	var units: Array = []
	var stack: Array = [_scene]
	while not stack.is_empty():
		var n = stack.pop_back()
		for c in n.get_children():
			stack.append(c)
		if n is Node3D and n.is_in_group("units"):
			units.append(n)
	print("--- %d units ---" % units.size())
	for u in units:
		var terrain_y := 0.0
		if _scene.has_method("terrain_height_at"):
			terrain_y = _scene.terrain_height_at((u as Node3D).global_position)
		# Locomotion subtree only.
		var loco_low := INF
		var loco_n := 0
		var st: Array = [u]
		while not st.is_empty():
			var n = st.pop_back()
			for c in n.get_children():
				st.append(c)
			var nm := str(n.name).to_lower()
			if n is Node3D and (nm.contains("wheel") or nm.contains("track") or nm.contains("loco") or nm.contains("leg")):
				var l := _lowest_mesh_y(n)
				if l < INF:
					loco_low = minf(loco_low, l)
					loco_n += 1
		var all_low := _lowest_mesh_y(u)
		var off: float = u.get("_ground_offset") if "_ground_offset" in u else -999.0
		var measured: bool = u.get("_ground_offset_measured") if "_ground_offset_measured" in u else false
		var has_cs: bool = is_instance_valid(u.get("_contact_shadow")) if "_contact_shadow" in u else false
		print("%-16s origin_y=%7.3f terrain_y=%7.3f mesh_low=%7.3f | contact_gap=%+6.3f | ground_offset=%6.3f measured=%s shadow=%s footprint=%5.2f" % [
			str(u.name).substr(0, 16), (u as Node3D).global_position.y, terrain_y,
			all_low, all_low - terrain_y, off, measured, has_cs,
			(u.get("_footprint_extent") if "_footprint_extent" in u else -1.0)])
		print("    lowest mesh: %s  (top_level=%s)" % [_low_path, _low_toplevel])
		var hn = u.get("hull_node")
		print("    hull_node=%s  hull local y=%.3f  visible=%s" % [
			(hn.name if hn != null else "<null>"),
			(hn.position.y if hn != null else -999.0),
			(hn.visible if hn != null else false)])
	quit(0)
	return true
