extends SceneTree
# Checks that locomotion stations land in mirror pairs across the hull's X axis.
# A station at (+x, y, z) must have a partner at (-x, y, z); anything unpaired is
# a placement asymmetry.
var _f := 0
var _holder: Node3D = null

func _initialize() -> void:
	_holder = Node3D.new()
	root.add_child(_holder)

func _hull_ids() -> Array:
	var out: Array = []
	var dir := DirAccess.open("res://assets/models/hulls")
	if dir == null:
		return out
	dir.list_dir_begin()
	var f := dir.get_next()
	while f != "":
		if f.ends_with(".glb"):
			out.append(f.get_basename())
		f = dir.get_next()
	dir.list_dir_end()
	out.sort()
	return out

func _check(bm, hull_id: String, loco: String) -> String:
	var bp := {
		"version": 3.0, "hull_type": hull_id,
		"hull_scale": {"x": 1.0, "y": 1.0, "z": 1.0},
		"armor_material": "hardened_steel", "faction": "player",
		# Locomotion is its OWN blueprint block, not an entry in `modules` -
		# reconstruct_vehicle reads blueprint_data["locomotion"]["type_id"].
		"locomotion": {"type_id": loco, "settings": {}},
		"modules": [],
	}
	var holder := Node3D.new()
	_holder.add_child(holder)
	var hull = bm.reconstruct_vehicle(bp, holder, false, "player")
	if hull == null:
		holder.queue_free()
		return "reconstruct failed"
	# Collect station positions in hull space: the spin pivots are the stations.
	var pts: Array = []
	var stack: Array = [[hull as Node3D, Transform3D.IDENTITY]]
	while not stack.is_empty():
		var e: Array = stack.pop_back()
		var n: Node = e[0]
		var xf: Transform3D = e[1]
		for c in n.get_children():
			if c is Node3D:
				stack.append([c, xf * (c as Node3D).transform])
		var nm := str(n.name)
		var low := nm.to_lower()
		if low.begins_with("wheelspin") or low.begins_with("legspin") 				or low.begins_with("axle") or low.begins_with("station") 				or low.begins_with("legroot") or low.begins_with("hip"):
			pts.append(xf.origin)
	holder.queue_free()
	if pts.is_empty():
		if "--dump" in OS.get_cmdline_user_args():
			print("  --- tree for %s / %s ---" % [hull_id, loco])
			var st2: Array = [[hull as Node3D, 0]]
			while not st2.is_empty():
				var en: Array = st2.pop_back()
				var nd: Node = en[0]
				var depth: int = en[1]
				if depth < 4:
					print("      %s%s (%s)" % ["  ".repeat(depth), nd.name, nd.get_class()])
				for c in nd.get_children():
					if c is Node3D:
						st2.append([c, depth + 1])
		return "no stations found"
	# Pair each +x station with a -x partner.
	var unpaired: Array = []
	var eps := 0.05
	for p in pts:
		if absf(p.x) < eps:
			continue
		var found := false
		for q in pts:
			if absf(q.x + p.x) < eps and absf(q.y - p.y) < eps and absf(q.z - p.z) < eps:
				found = true
				break
		if not found:
			unpaired.append(p)
	if unpaired.is_empty():
		return "OK (%d stations, symmetric)" % pts.size()
	var s := "ASYMMETRIC: %d/%d unpaired ->" % [unpaired.size(), pts.size()]
	for p in unpaired.slice(0, 4):
		s += " (%.2f,%.2f,%.2f)" % [p.x, p.y, p.z]
	return s

func _process(_d: float) -> bool:
	_f += 1
	if _f < 3:
		return false
	var bm = load("res://scripts/blueprint_manager.gd").new()
	root.add_child(bm)
	var only: String = ""
	var a := OS.get_cmdline_user_args()
	for i in range(a.size()):
		if a[i] == "--filter" and i + 1 < a.size():
			only = a[i + 1]
	var bad := 0
	var total := 0
	for hull_id in _hull_ids():
		if only != "" and not hull_id.contains(only):
			continue
		for loco in ["wheels", "legs"]:
			total += 1
			var r := _check(bm, hull_id, loco)
			if not r.begins_with("OK"):
				bad += 1
				print("  %-22s %-7s %s" % [hull_id, loco, r])
	print("checked %d combos, %d asymmetric" % [total, bad])
	quit(0)
	return true
