extends SceneTree
var _f := 0
var _holder: Node3D = null

func _initialize() -> void:
	_holder = Node3D.new()
	root.add_child(_holder)

func _process(_d: float) -> bool:
	_f += 1
	if _f < 3:
		return false
	var BM = load("res://scripts/blueprint_manager.gd").new()
	root.add_child(BM)
	var bp: Dictionary = BM.load_blueprint("res://data/loadout/bastion_gun_turret.json")
	var hull = BM.reconstruct_vehicle(bp, _holder, false, "crimson_concordat")
	if hull == null:
		print("reconstruct failed"); quit(1); return true
	print("=== planar / near-zero-thickness meshes ===")
	var stack: Array = [[hull as Node3D, Transform3D.IDENTITY]]
	while not stack.is_empty():
		var e: Array = stack.pop_back()
		var n: Node = e[0]
		var xf: Transform3D = e[1]
		for c in n.get_children():
			if c is Node3D:
				stack.append([c, xf * (c as Node3D).transform])
		if not (n is MeshInstance3D) or (n as MeshInstance3D).mesh == null:
			continue
		var mi := n as MeshInstance3D
		var ab: AABB = mi.mesh.get_aabb()
		var sz: Vector3 = ab.size * xf.basis.get_scale()
		var mn: float = minf(sz.x, minf(sz.y, sz.z))
		var mx: float = maxf(sz.x, maxf(sz.y, sz.z))
		# Planar = one axis under 4 cm while another is over 30 cm.
		if mn < 0.04 and mx > 0.30:
			var path := str(hull.get_path_to(mi))
			print("  size=%.3v  ratio=%.0f  mesh=%s  path=%s" % [
				sz, mx / maxf(mn, 0.001), mi.mesh.get_class(), path])
			var pnode: Node = mi
			var chain: Array = []
			for i in range(5):
				if pnode == null: break
				chain.append(str(pnode.name))
				if pnode.has_meta("type_id"):
					chain.append("[type_id=%s]" % pnode.get_meta("type_id"))
				pnode = pnode.get_parent()
			print("      chain: %s" % " < ".join(chain))
	quit(0)
	return true
