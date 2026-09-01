extends SceneTree
# hull_chine.chine_at(profile, z, side) must be mirror-symmetric: the port
# result should be the starboard result with x negated. Any z where it is not is
# a locomotion-station asymmetry, because that is the function the stations are
# seated from.
var _f := 0
var _holder: Node3D = null

func _initialize() -> void:
	_holder = Node3D.new()
	root.add_child(_holder)

func _hull_ids(filter: String) -> Array:
	var out: Array = []
	var dir := DirAccess.open("res://assets/models/hulls")
	dir.list_dir_begin()
	var f := dir.get_next()
	while f != "":
		if f.ends_with(".glb") and (filter == "" or f.contains(filter)):
			out.append(f.get_basename())
		f = dir.get_next()
	dir.list_dir_end()
	out.sort()
	return out

func _process(_d: float) -> bool:
	_f += 1
	if _f < 3:
		return false
	var HullChine = load("res://scripts/hull_chine.gd")
	var MeshLoader = load("res://scripts/mesh_asset_loader.gd")
	var filter := ""
	var a := OS.get_cmdline_user_args()
	for i in range(a.size()):
		if a[i] == "--filter" and i + 1 < a.size():
			filter = a[i + 1]
	var worst_overall := 0.0
	var bad_hulls := 0
	var total := 0
	for hull_id in _hull_ids(filter):
		var mesh: Mesh = MeshLoader.get_hull_mesh(hull_id)
		if mesh == null:
			continue
		var mi := MeshInstance3D.new()
		mi.mesh = mesh
		_holder.add_child(mi)
		var host := Node3D.new()
		_holder.add_child(host)
		mi.reparent(host)
		var profile: Dictionary = HullChine.build(host)
		total += 1
		if not HullChine.is_valid(profile):
			print("  %-22s profile INVALID" % hull_id)
			host.queue_free()
			continue
		var ab: AABB = profile.get("aabb", AABB())
		var worst := 0.0
		var worst_z := 0.0
		for i in range(21):
			var t := float(i) / 20.0
			var z: float = ab.position.z + ab.size.z * lerpf(0.08, 0.92, t)
			var s: Dictionary = HullChine.chine_at(profile, z, 1.0)
			var p: Dictionary = HullChine.chine_at(profile, z, -1.0)
			# chine_at returns "position" (plus normal / half_width / low / high);
			# `found` is false on the box fallback.
			if not bool(s.get("found", false)) or not bool(p.get("found", false)):
				continue
			var sp: Vector3 = s["position"]
			var pp: Vector3 = p["position"]
			# Mirror test: port.x should be -starboard.x, y and z equal.
			var d: float = maxf(absf(sp.x + pp.x), maxf(absf(sp.y - pp.y), absf(sp.z - pp.z)))
			if d > worst:
				worst = d
				worst_z = z
		host.queue_free()
		worst_overall = maxf(worst_overall, worst)
		if worst > 0.02:
			bad_hulls += 1
			print("  %-22s max mirror error %.4f m at z=%.2f" % [hull_id, worst, worst_z])
	print("checked %d hulls, %d with mirror error > 0.02 m, worst %.4f m" % [
		total, bad_hulls, worst_overall])
	quit(0)
	return true
