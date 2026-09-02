extends SceneTree
# Regression probe for module re-selection on ANGLED hull faces.
#
# The lab's hull carries a single axis-aligned BoxShape3D click body (layer 1)
# around the whole mesh. On an angled face that box hangs ABOVE modules mounted
# flush to the slope, so a single nearest-hit raycast that masks hull+module
# together (mask 7) returns the hull no matter how precisely you aim at the
# module. The fix is a two-pass pick in module_placer._unhandled_input:
#
#   pass 1: modules(2) | gizmos(4) | hull SURFACE(16) - the box is excluded
#   pass 2: hull box(1) only, if pass 1 found nothing
#
# This probe rebuilds that exact scenario against the real MainLab scene and
# asserts the coordinate the user cares about: a ray aimed at the PROTRUDING
# module must pick the module's own click body, while a ray at bare hull or a
# hidden (far-side) module must still resolve to the hull.
#
# NOTE: runs on real frames, so do NOT pass --quit - it quits itself (0/1).

func _init():
	var packed = load("res://scenes/MainLab.tscn")
	var inst = packed.instantiate()
	root.add_child(inst)
	for _i in range(8):
		await process_frame
	await physics_frame

	var placer = inst

	# Replace the default box hull with a wedge whose top face slopes up
	# toward +z - the canonical "angled hull face".
	var old_hull = placer.get_node_or_null("Hull")
	if old_hull:
		old_hull.free()

	var hull = StaticBody3D.new()
	hull.name = "Hull"
	hull.collision_layer = 1
	hull.collision_mask = 0
	hull.set_meta("type_id", "wedge_probe")
	hull.set_meta("base_hull_size", Vector3(4, 2.0, 4))
	hull.set_meta("hull_scale", Vector3.ONE)
	hull.position = Vector3(0, 1.5, 0)

	var col = CollisionShape3D.new()
	col.name = "CollisionShape3D"
	var box = BoxShape3D.new()
	box.size = Vector3(4, 2.0, 4)
	col.shape = box
	hull.add_child(col)

	placer.add_child(hull)
	placer.hull = hull
	placer.mirror_enabled = false

	var wedge = MeshInstance3D.new()
	wedge.name = "MeshInstance3D"
	wedge.mesh = _make_wedge()
	hull.add_child(wedge)
	placer._rebuild_surface_body(hull, wedge)
	await physics_frame
	await physics_frame

	var space = placer.get_world_3d().direct_space_state
	var ModuleVolume = preload("res://scripts/module_volume.gd")
	var HullSurfaceScript = preload("res://scripts/hull_surface.gd")
	var NEW_MASK = 2 | 4 | HullSurfaceScript.SURFACE_COLLISION_LAYER
	var OLD_MASK = 7

	var failures := []
	var slope_module: Node3D = null

	# --- 1. Place a module flush on the LOW end of the slope (well below the
	# hull box's top face, so the old single-pass mask would hit the box).
	var drop_at_local := Vector3(0.0, 0.0, -1.2)  # low back slope
	var drop_world := hull.to_global(drop_at_local)
	var sr: Dictionary = placer.surface_raycast(drop_world + Vector3(0, 4, 0), Vector3(0, -1, 0), 10.0)
	if sr.is_empty():
		failures.append("placement: surface_raycast failed on the slope")
	else:
		placer._place_weapon_from_ui("heavy_machine_gun", sr.position, sr.normal, false)
		await physics_frame
		var module: Node3D = null
		for child in hull.get_children():
			if child.has_meta("module_data"):
				module = child
				break
		if module == null:
			failures.append("placement: no module landed on the slope")
		else:
			slope_module = module
			var mw := module.global_position
			var n := Vector3(sr.normal).normalized()
			# Aim at the module's protruding body, from outboard along the face normal.
			var from := mw + n * 2.0
			var to := mw - n * 0.5

			var old_hit := _cast(space, from, to, OLD_MASK)
			var new_hit := _cast(space, from, to, NEW_MASK)

			_checks(module, old_hit, new_hit,
				"module-on-slope", failures, inst)

	# --- 2. A module on the underside must NOT be reachable through the hull.
	var belly := Vector3(0, -0.05, 0.0)
	var belly_hit: Dictionary = placer.surface_raycast(hull.to_global(belly) + Vector3(0, -4, 0), Vector3(0, 1, 0), 10.0)
	if belly_hit.is_empty():
		failures.append("hidden-check: no underside surface found")
	else:
		placer._place_weapon_from_ui("heavy_machine_gun", belly_hit.position, belly_hit.normal, false)
		await physics_frame
		var belly_mod: Node3D = null
		for child in hull.get_children():
			if child.has_meta("module_data") and child != slope_module:
				belly_mod = child
				break
		if belly_mod == null:
			failures.append("hidden-check: no belly module found")
		else:
			var ray_from := belly_mod.global_position + Vector3(0, 6, 0)
			var ray_to := belly_mod.global_position
			var pass1 := _cast(space, ray_from, ray_to, NEW_MASK)
			if pass1.is_empty():
				failures.append("hidden-check: pass-1 ray missed entirely")
			elif _owner_module(pass1.collider, inst) != null:
				failures.append("hidden-check: pass-1 reached the far-side module (%s)"
					% str(_owner_module(pass1.collider, inst).name))
			elif str(pass1.collider.name) != "HullSurface":
				failures.append("hidden-check: pass-1 hit %s, expected HullSurface" % str(pass1.collider.name))

	# --- 3. Bare hull click still selects the hull (via the surface body).
	var bare := hull.to_global(Vector3(0.0, 0.0, 0.0))  # mid-slope, module-free zone
	var bh := _cast(space, bare + Vector3(0, 4, 0), bare, NEW_MASK)
	if bh.is_empty():
		failures.append("hull-click: pass-1 missed bare hull")
	elif _owner_module(bh.collider, inst) != null:
		failures.append("hull-click: pass-1 picked a module at a bare point")
	else:
		print("  bare-hull click -> %s (walk-up: hull)" % str(bh.collider.name))

	# --- 4. Box-envelope click (empty corner, no surface crossed) still
	# resolves via pass 2.
	var empty_corner_from := Vector3(-4, 1.0, -1.8)
	var empty_corner_to := Vector3(4, 1.0, -1.8)
	var p1 := _cast(space, empty_corner_from, empty_corner_to, NEW_MASK)
	var p2 := _cast(space, empty_corner_from, empty_corner_to, 1)
	if p1.is_empty() and not p2.is_empty():
		print("  box-envelope click -> hull box (pass 2)")
	else:
		failures.append("box-envelope click: pass2=%s (expected hull box)" % str(not p2.is_empty()))

	print("")
	if failures.is_empty():
		print("[PASS] all click-target checks passed")
		quit(0)
	else:
		for f in failures:
			print("[FAIL] " + f)
		quit(1)


func _cast(space, from: Vector3, to: Vector3, mask: int) -> Dictionary:
	var q = PhysicsRayQueryParameters3D.create(from, to)
	q.collision_mask = mask
	q.collide_with_areas = true
	var r: Dictionary = space.intersect_ray(q)
	if r.is_empty():
		return {}
	return r


# Same walk-up the fixed click handler uses: nearest non-null module_data owner,
# else null (hull).
func _owner_module(n: Node, inst: Node) -> Node:
	var curr: Node = n
	while curr != null and curr != inst and curr != root:
		if curr.has_meta("module_data"):
			return curr
		curr = curr.get_parent()
	return null


func _checks(module: Node3D, old_hit: Dictionary, new_hit: Dictionary,
		label: String, failures: Array, inst: Node) -> void:
	var new_owner = _owner_module(new_hit.collider, inst) if not new_hit.is_empty() else null
	var old_owner = _owner_module(old_hit.collider, inst) if not old_hit.is_empty() else null

	print("--- %s ---" % label)
	print("  old single-pass (mask 7): %s (owner: %s)"
		% [str(old_hit.collider.name) if not old_hit.is_empty() else "MISS",
		   str(old_owner.name) if old_owner else
			   (str(old_hit.collider.name) if not old_hit.is_empty() else "none")])
	print("  new pass-1 (mask 2|4|16):  %s (owner: %s)"
		% [str(new_hit.collider.name) if not new_hit.is_empty() else "MISS",
		   str(new_owner.name) if new_owner else
			   (str(new_hit.collider.name) if not new_hit.is_empty() else "none")])

	if new_hit.is_empty():
		failures.append("%s: pass-1 raycast missed the module" % label)
		return
	if new_owner == null:
		failures.append("%s: pass-1 did not resolve to the module (owner null)" % label)
		return
	if new_owner != module and not new_owner.is_ancestor_of(module) \
			and not module.is_ancestor_of(new_owner):
		# owner is a module_data-bearing node; it must BE our placed module.
		if new_owner != module:
			failures.append("%s: pass-1 picked a different module (%s) than the placed one"
				% [label, str(new_owner.name)])
	if not new_owner.is_queued_for_deletion():
		if old_owner != module:
			print("  (the old single-pass cast would have FAILED to select the module - this is the bug being fixed)")


func _make_wedge() -> ArrayMesh:
	var v: Array[Vector3] = [
		Vector3(-2, 0.0, -2), Vector3(2, 0.0, -2), Vector3(2, 0.0, 2), Vector3(-2, 0.0, 2),
		Vector3(-2, 0.4, -2), Vector3(2, 0.4, -2), Vector3(2, 2.0, 2), Vector3(-2, 2.0, 2),
	]
	var quads: Array = [
		[0, 1, 2, 3],  # bottom
		[4, 6, 5, 7],  # top slope (wound up)
		[0, 1, 5, 4],  # back
		[2, 3, 7, 6],  # front
		[3, 0, 4, 7],  # left
		[1, 2, 6, 5],  # right
	]
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	for q in quads:
		var tris: Array = [[q[0], q[1], q[2]], [q[0], q[2], q[3]]]
		for tri in tris:
			var a: Vector3 = v[tri[0]]
			var b: Vector3 = v[tri[1]]
			var c: Vector3 = v[tri[2]]
			var n: Vector3 = (b - a).cross(c - a).normalized()
			st.set_normal(n)
			st.add_vertex(a)
			st.set_normal(n)
			st.add_vertex(b)
			st.set_normal(n)
			st.add_vertex(c)
	return st.commit()