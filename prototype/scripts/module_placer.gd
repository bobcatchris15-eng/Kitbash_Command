extends Node3D
const ModuleDataResource = preload("res://scripts/module_data.gd")


const Gizmo3D = preload("res://scenes/Gizmo3D.tscn")
const ModuleCatalog = preload("res://scripts/module_catalog.gd")
const MeshAssetLoader = preload("res://scripts/mesh_asset_loader.gd")
const ModuleMirrorScript = preload("res://scripts/module_mirror.gd")
const HullMaterialBuilderScript = preload("res://scripts/hull_material_builder.gd")
const VisualBuilderScript = preload("res://scripts/visual_builder.gd")
# Only for the shared elevation/depression tolerances the firing-arc envelope
# has to match - see _build_firing_arc().
const AutoWeaponScript = preload("res://scripts/auto_weapon.gd")
const HullGreeblesScript = preload("res://scripts/hull_greebles.gd")
const UITokens = preload("res://scripts/ui_tokens.gd")
const ArmorPaintScript = preload("res://scripts/armor_paint.gd")
# hull_decals.gd is deliberately NOT preloaded any more - the Lab draws no
# faction insignia. Battle spawns still get theirs via blueprint_manager.
const LiveryScript = preload("res://scripts/livery.gd")
const HullSurfaceScript = preload("res://scripts/hull_surface.gd")
const HullProjectionScript = preload("res://scripts/hull_projection.gd")
const LocomotionLayoutScript = preload("res://scripts/locomotion_layout.gd")
const LocomotionMountScript = preload("res://scripts/locomotion_mount.gd")
const ModuleVolumeScript = preload("res://scripts/module_volume.gd")
# Only for apply_facet_plate's no-mesh-child fallback, which is the one path
# that has to resolve a part material rather than preserve the one build_visual
# already applied.
const PartMaterialsScript = preload("res://scripts/part_materials.gd")
const HullFacetsScript = preload("res://scripts/hull_facets.gd")

@export var hull_path: NodePath
# Lifts the hull above the parent's ground plane by this many units.
# Default 0 = hull bottom at y = 0 (the existing behaviour, which the
# unit tests, blueprint restore and most callers still depend on).
# MainLab sets this to the pedestal height so the hull sits on the
# stand instead of clipping into the cutting mat.
@export var stage_y_offset: float = 0.0
var hull: Node3D

# Set by UI_ArmorStationPanel on enter()/exit() to gate the placer's
# _unhandled_input. When true, the placer ignores mouse input - the
# panel is doing paint input instead and we don't want both fighting
# over the same click.
var paint_mode_active: bool = false

var mirror_enabled: bool = true
var selected_module: Node3D = null


var clipping_detected: bool = false
var log_mutex: Mutex = Mutex.new()

var drag_pending: bool = false
var is_dragging_module: bool = false
var drag_start_mouse_pos: Vector2
var drag_start_module: Node3D = null
var drag_original_transform: Transform3D
var drag_original_mirror_transform: Transform3D
var drag_has_mirror: bool = false
var _facet_highlight: MeshInstance3D = null

# --- Undo/Redo (Design_Lab_UI_UX.md top-bar spec) ---
# Snapshot-based: each entry is a full serialized-hull dictionary (same shape
# blueprint_manager.gd saves to disk), captured just before a mutation. Undo
# restores the previous snapshot by tearing down and reconstructing the hull.
const MAX_UNDO_HISTORY = 50
var undo_stack: Array = []
var redo_stack: Array = []

func push_undo_snapshot():
	if not hull:
		return
	var bm = get_node_or_null("BlueprintManager")
	if not bm:
		return
	var snapshot = bm.serialize_hull(hull)
	if snapshot.is_empty():
		return
	undo_stack.append(snapshot.duplicate(true))
	if undo_stack.size() > MAX_UNDO_HISTORY:
		undo_stack.pop_front()
	redo_stack.clear()

func can_undo() -> bool:
	return undo_stack.size() > 0

func can_redo() -> bool:
	return redo_stack.size() > 0

func undo():
	if undo_stack.is_empty():
		return
	var bm = get_node_or_null("BlueprintManager")
	if not bm:
		return
	var current = bm.serialize_hull(hull) if hull else {}
	if not current.is_empty():
		redo_stack.append(current.duplicate(true))
	var snapshot = undo_stack.pop_back()
	_reconstruct_from_snapshot(snapshot)
	_log("Undo applied. History remaining: " + str(undo_stack.size()))

func redo():
	if redo_stack.is_empty():
		return
	var bm = get_node_or_null("BlueprintManager")
	if not bm:
		return
	var current = bm.serialize_hull(hull) if hull else {}
	if not current.is_empty():
		undo_stack.append(current.duplicate(true))
	var snapshot = redo_stack.pop_back()
	_reconstruct_from_snapshot(snapshot)
	_log("Redo applied. Redo remaining: " + str(redo_stack.size()))

func _reconstruct_from_snapshot(snapshot: Dictionary):
	var bm = get_node_or_null("BlueprintManager")
	if not bm:
		return
	if selected_module:
		_select_module(null)
	if hull and is_instance_valid(hull):
		var parent = hull.get_parent()
		if parent:
			parent.remove_child(hull)
		hull.free()
	hull = null
	clipping_detected = false
	hull = bm.reconstruct_vehicle(snapshot, self, true)
	get_tree().call_group("stat_ui", "update_stats", hull)
	get_tree().call_group("stat_ui", "sync_hull_ui", hull)
	check_all_clipping()

func _ready():
	# (Former: spawned two 1x1x1m orange scale-reference boxes at
	# (-8, 0.5, -4) and (8, 0.5, -4). Removed 2026-08-18 with the
	# Design Lab visual overhaul - the mat is now at y = -12 and
	# the model floats at y = 2.5, so boxes anchored at y = 0.5
	# hung in mid-air and read as floating crates. The Lab now
	# gets its workshop dressing from the shared LabEnvironment
	# (cutting mat + cardboard boxes), not from a debug pair of
	# boxes the placer was making for itself.)
	if has_node("Hull"):
		hull = get_node("Hull")
		if hull:
			if not hull.has_meta("base_hull_size"):
				# No-hull-loaded safety net. Should never fire in normal use:
				# MainLab's hand-authored startup Hull node never has
				# base_hull_size set, and the freshly placed hull (the only
				# other path that reaches this) sets it in
				# _place_hull_from_ui before calling update_hull_appearance().
				# The reference anchor (4, 1, 6) is the same size that drives
				# auto_weapon.gd's miss-chance size_factor - if the fallback
				# ever runs, it should at least look right at zoom-out.
				hull.set_meta("base_hull_size", Vector3(ModuleCatalog.REFERENCE_HULL_SIZE))
			if not hull.has_meta("hull_scale"):
				hull.set_meta("hull_scale", Vector3(1.0, 1.0, 1.0))
			if not hull.has_meta("type_id"):
				hull.set_meta("type_id", "brenntal_medium_a")
			update_hull_appearance()

	# Coming back from the Test Range: rebuild whatever the player was
	# working on instead of dropping them onto the default bare hull.
	#
	# Deferred because the restore runs reconstruct_vehicle() against this
	# node and calls into the stat sidebar via the "stat_ui" group - during
	# _ready() the sidebar's own _ready() may not have run yet, so its
	# @onready references would still be null.
	call_deferred("_restore_test_session")
	call_deferred("_check_first_time_instructions")

func _restore_test_session() -> void:
	var bp_manager = get_node_or_null("BlueprintManager")
	if bp_manager and bp_manager.has_pending_lab_restore():
		bp_manager.restore_scratch_into_designer()
		
func _process(delta: float):
	# Live idle spin for helicopter_rotors blades while designing - the
	# Design Lab canvas never had this at all (unit.gd in combat now,
	# spin them in combat/Test Range, but nothing did it here), which read
	# as "the animation is broken" when the actual issue was that it never
	# existed on this screen. Same rotate_y(15/sec) on the "RotorBlades"
	# pivot as the combat paths, so it looks consistent everywhere.
	if not is_instance_valid(hull): return
	for child in hull.get_children():
		if not child.has_meta("module_data"): continue
		var type_id = child.get_meta("module_data").type_id
		if type_id == "helicopter_rotors":
			var rotor = child.get_node_or_null("RotorBlades")
			if rotor:
				rotor.rotate_y(15.0 * delta)
		elif type_id == "hover_engine":
			# Same idle spin as helicopter_rotors' blades - outer ring stays
			# fixed/horizontal, middle ring spins around X, inner ring
			# around Y (Chris's ask).
			var mid_ring = child.get_node_or_null("HoverRingMid")
			if mid_ring:
				mid_ring.rotate_x(12.0 * delta)
			var inner_ring = child.get_node_or_null("HoverRingInner")
			if inner_ring:
				inner_ring.rotate_y(18.0 * delta)
				# Chris: the innermost ring should turn about a horizontal axis
				# as well. One axis alone reads as a flat spin like the outer
				# rings; a second, slower one about Z makes it tumble, which is
				# what sells the gimbal.
				inner_ring.rotate_z(7.0 * delta)

func set_mirror_enabled(enabled: bool):
	mirror_enabled = enabled
	_log("Mirror toggled via UI: " + str(mirror_enabled))
		
func _log(msg: String):
	print(msg)
	WorkerThreadPool.add_task(Callable(self, "_async_write_log").bind(msg))

func _async_write_log(msg: String):
	if log_mutex == null:
		return
	log_mutex.lock()
	var file = FileAccess.open("user://game_log.txt", FileAccess.READ_WRITE)
	if not file:
		file = FileAccess.open("user://game_log.txt", FileAccess.WRITE)
	if file:
		file.seek_end()
		file.store_line(msg)
		file.close()
	if log_mutex != null:
		log_mutex.unlock()

func _unhandled_input(event):
	# Paint mode is owned by UI_ArmorStationPanel while it's active.
	# The panel raycasts clicks into the hull; if the placer also
	# processed the same click, the two would race on the ghosted
	# modules (the placer would try to drag-or-rotate a module the
	# player meant to paint past). One line guard.
	if paint_mode_active:
		return
	if event is InputEventKey and event.pressed and not event.echo:
		# Actions, not keycodes - see InputService's header for why this file's
		# raw comparisons had to go. REDO IS TESTED BEFORE UNDO: its Ctrl+Shift+Z
		# form also satisfies a permissively-matched Ctrl+Z, so checking undo
		# first would swallow every redo. InputService._descriptors_equal()
		# compares modifiers exactly for the same reason.
		if event.is_action_pressed("lab_mirror"):
			mirror_enabled = not mirror_enabled
			_log("Mirror toggled: " + str(mirror_enabled))
			var tree = get_tree()
			if tree: tree.call_group("stat_ui", "set_mirror_toggle", mirror_enabled)
		elif event.is_action_pressed("lab_delete"):
			delete_selected_module()
		elif event.is_action_pressed("lab_rotate"):
			rotate_selected_module()
		elif event.is_action_pressed("lab_redo"):
			redo()
		elif event.is_action_pressed("lab_undo"):
			undo()
		elif event.is_action_pressed("ui_cancel"):
			if is_dragging_module:
				is_dragging_module = false
				selected_module.transform = drag_original_transform
				if drag_has_mirror:
					var mirror = selected_module.get_meta("mirrored_counterpart")
					if mirror and is_instance_valid(mirror):
						mirror.transform = drag_original_mirror_transform
				_select_module(selected_module)
				check_all_clipping()
				_hide_facet_highlight()
				_log("Module dragging cancelled.")

	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
		if event.pressed:
			_log("Left click detected in module_placer.gd!")
			
			if not hull:
				_log("ERROR: Hull is null! Cannot proceed.")
				return
				
			var camera = get_viewport().get_camera_3d()
			if not camera: 
				_log("ERROR: Camera is null! Cannot raycast.")
				return
			
			var space_state = get_world_3d().direct_space_state
			
			var mouse_pos = event.position
			var ray_origin = camera.project_ray_origin(mouse_pos)
			var ray_end = ray_origin + camera.project_ray_normal(mouse_pos) * 1000.0
			
			_log("Casting ray from " + str(ray_origin) + " to " + str(ray_end))
			
			var query = PhysicsRayQueryParameters3D.create(ray_origin, ray_end)
			query.collision_mask = 7 # Layer 1 (Hull), Layer 2 (Modules), Layer 3 (Gizmos)
			query.collide_with_areas = true
			var result = space_state.intersect_ray(query)
			
			if result:
				_log("Raycast hit! Collider: " + str(result.collider.name))
				if result.collider.has_method("start_drag"):
					# We clicked a Gizmo Handle!
					result.collider.start_drag(event, result.position)
				elif result.collider == hull or (result.collider.get_parent() == hull and not result.collider.has_meta("module_data") and not (result.collider.get_parent() and result.collider.get_parent().has_meta("module_data"))):
					# Hit the Hull itself
					_select_module(hull)
				else:
					# We clicked a Module or sub-node!
					var module: Node = result.collider
					var curr: Node = module
					while curr != null and curr != hull and curr != get_tree().root:
						if curr.has_meta("module_data"):
							module = curr
							break
						curr = curr.get_parent()
					_select_module(module if (module != null and module.has_meta("module_data")) else result.collider)
					
					# Initialize drag movement if not locomotion
					if module and module.has_meta("module_data"):
						var data = module.get_meta("module_data")
						if data.category != "locomotion":
							drag_pending = true
							drag_start_mouse_pos = event.position
							drag_start_module = module
							drag_original_transform = module.transform
							drag_has_mirror = module.has_meta("mirrored_counterpart")
							if drag_has_mirror:
								var mirror = module.get_meta("mirrored_counterpart")
								if mirror and is_instance_valid(mirror):
									drag_original_mirror_transform = mirror.transform
			else:
				_log("Raycast missed. Deselecting.")
				_select_module(null)
		else:
			# Left click released
			if is_dragging_module:
				is_dragging_module = false
				if selected_module and is_instance_valid(selected_module):
					var final_normal = selected_module.get_meta("_last_drag_normal", Vector3.UP)
					_reclassify_module_after_drag(selected_module, final_normal)
				_select_module(selected_module)
				get_tree().call_group("stat_ui", "update_stats", hull)
				check_all_clipping()
				_hide_facet_highlight()
				_log("Module dragging finished.")
			drag_pending = false
			drag_start_module = null

	if event is InputEventMouseMotion:
		if drag_pending and drag_start_module and is_instance_valid(drag_start_module):
			if event.position.distance_to(drag_start_mouse_pos) > 8:
				push_undo_snapshot()
				is_dragging_module = true
				drag_pending = false
				_free_gizmo(selected_module)
				_log("Module dragging started.")
				
		if is_dragging_module and selected_module and is_instance_valid(selected_module):
			var camera = get_viewport().get_camera_3d()
			if camera:
				var space_state = get_world_3d().direct_space_state
				var mouse_pos = event.position
				var ray_origin = camera.project_ray_origin(mouse_pos)
				var ray_end = ray_origin + camera.project_ray_normal(mouse_pos) * 1000.0
				
				var exclude_list = []
				_get_colliders_recursive(selected_module, exclude_list)
				if selected_module.has_meta("mirrored_counterpart"):
					var mirror = selected_module.get_meta("mirrored_counterpart")
					if mirror and is_instance_valid(mirror):
						_get_colliders_recursive(mirror, exclude_list)
						
				# Precise hull surface first, bounding box only as a fallback -
				# same rule initial placement uses, so a dragged module tracks
				# the visible hull instead of jumping onto its bounding shell.
				var result = surface_raycast(ray_origin, camera.project_ray_normal(mouse_pos), 1000.0, exclude_list)
				if result:
					# Same refusal the build bar applies, so a lobbing weapon
					# cannot be dragged onto a wall it was not allowed to be
					# placed on. Enforced HERE rather than inside
					# _update_module_placement() so the rule lives on the one
					# interactive path and direct callers (tests, scripted
					# setup) keep working unchanged. The module simply stops
					# following the cursor over a face it cannot occupy, which
					# reads as "it won't go there" without a toast firing every
					# frame of the drag.
					var drag_data = selected_module.get_meta("module_data", null)
					var drag_refused = false
					if drag_data != null:
						drag_refused = _placement_refusal_reason(
							drag_data.type_id, drag_data.category, result.normal) != ""
					if not drag_refused:
						_update_module_placement(selected_module, result.position, result.normal)
						check_all_clipping()

func rotate_selected_module():
	if not selected_module or selected_module == hull: return
	push_undo_snapshot()

	var yaw = selected_module.get_meta("yaw_offset", 0.0)
	yaw += PI / 2.0
	if yaw >= 2.0 * PI - 0.01:
		yaw = 0.0
	selected_module.set_meta("yaw_offset", yaw)
	
	selected_module.rotate_object_local(Vector3.UP, PI / 2.0)
	# A sponson blister is welded to the hull face, not to the gun spinning on
	# it, so its counter-rotation has to be re-applied whenever yaw changes
	# outside of a full rebuild.
	VisualBuilderScript.refresh_sponson_blister(selected_module)

	if selected_module.has_meta("mirrored_counterpart"):
		var mirror = selected_module.get_meta("mirrored_counterpart")
		if mirror and is_instance_valid(mirror):
			mirror.set_meta("yaw_offset", -yaw)
			mirror.rotate_object_local(Vector3.UP, -PI / 2.0)
			VisualBuilderScript.refresh_sponson_blister(mirror)

	check_all_clipping()
	_log("Rotated module to yaw_offset: " + str(yaw))
	
	# Trigger UI updates
	get_tree().call_group("stat_ui", "on_module_selected", selected_module)
	get_tree().call_group("stat_ui", "update_stats", hull)

func _select_module(module: Node3D):
	if selected_module and is_instance_valid(selected_module):
		_deselect_module()
		_free_gizmo(selected_module)

	selected_module = module
	get_tree().call_group("stat_ui", "on_module_selected", selected_module)
	
	if selected_module:
		var new_gizmo = Gizmo3D.instantiate()
		new_gizmo.name = "Gizmo3D"
		selected_module.add_child(new_gizmo)
		
		# Show/hide handles based on module category
		if selected_module.has_meta("module_data") or selected_module == hull:
			var cat = "module"
			if selected_module == hull:
				cat = "hull"
			elif selected_module.has_meta("module_data"):
				var data = selected_module.get_meta("module_data")
				cat = data.get("category") if "category" in data else "module"
			
			# Stretch handles (X/Y/Z scale) are retired - Instrument Console
			# Pass Phase B - so HandleRotate is now the only handle a
			# category decision can gate. Armor stays facet-fitted rather
			# than freely rotatable (MOUNTING_AND_ARMOR_SPEC.md #2); the
			# whole hull's orientation isn't a placement tweak either.
			var hrot = new_gizmo.get_node_or_null("HandleRotate")

			if cat == "locomotion" or cat == "armor" or cat == "hull":
				if hrot: hrot.queue_free()
			# cat == "weapon" or "module": keep the free-form yaw rotation
			# ring (MOUNTING_AND_ARMOR_SPEC.md #3).
				
		# Firing Arc Visualization ("Radar Sweep", Design_Lab_UI_UX.md): a
		# horizontal wedge spanning the weapon's actual traverse_limit_angle
		# (shared with combat via ModuleCatalog.get_traverse_limit_angle),
		# raycast per-segment against the hull/other modules so blocked
		# angles read alert-red and clear angles read hazard-orange - not a
		# fixed decorative cone. Kept live via _refresh_firing_arc(), called
		# from check_all_clipping() so it updates after drags/tweaks/rotation.
		if show_firing_arc and selected_module.has_meta("module_data"):
			var m_data = selected_module.get_meta("module_data")
			if m_data and m_data.category == "weapon":
				selected_module.add_child(_build_firing_arc(selected_module, m_data))

func delete_selected_module():
	if selected_module:
		# Deleting the hull itself would leave nothing to snapshot; only guard
		# undo history for module deletions (the common case).
		if selected_module != hull:
			push_undo_snapshot()
		_log("Deleting selected module")
		_deselect_module()
		var is_hull = (selected_module == hull)
		
		# Symmetrical Deletion
		if selected_module.has_meta("mirrored_counterpart"):
			var mirror = selected_module.get_meta("mirrored_counterpart")
			if is_instance_valid(mirror):
				_log("Deleting mirrored counterpart as well")
				mirror.queue_free()
				
		# Locomotion Group Symmetrical Deletion
		if selected_module.has_meta("locomotion_group"):
			var group = selected_module.get_meta("locomotion_group")
			for wheel in group:
				if is_instance_valid(wheel) and wheel != selected_module:
					_log("Deleting locomotion group member")
					wheel.queue_free()
					
			if hull:
				var hull_scale = Vector3(1, 1, 1)
				if hull.has_meta("hull_scale"):
					hull_scale = hull.get_meta("hull_scale")
				# base_hull_size is now the fitted AABB (set in _place_hull_from_ui
				# / update_hull_appearance), so reading it here keeps this lift
				# consistent with whatever the collider and meta report everywhere
				# else - no separate catalog round-trip.
				var base_hull_size: Vector3 = Vector3(ModuleCatalog.REFERENCE_HULL_SIZE)
				if hull.has_meta("base_hull_size"):
					base_hull_size = hull.get_meta("base_hull_size")
				hull.position.y = (base_hull_size.y * hull_scale.y) / 2.0 + stage_y_offset
				hull.remove_meta("locomotion_type")
				hull.remove_meta("locomotion_settings")
		
		if is_hull:
			hull = null
		selected_module.queue_free()
		selected_module = null
		get_tree().call_group("stat_ui", "update_stats", hull)
		check_all_clipping()
	
func clear_hull():
	# Used by the Blueprint Library to swap the active design out entirely.
	if selected_module:
		_select_module(null)
	if hull and is_instance_valid(hull):
		var parent = hull.get_parent()
		if parent:
			parent.remove_child(hull)
		hull.free()
	hull = null
	clipping_detected = false
	get_tree().call_group("stat_ui", "update_stats", null)


# --- Armor station (paint workspace) bridge --------------------------------
#
# The Armor Station is a sub-mode of the Design Lab, not a separate scene
# (see UI_ArmorStationPanel.gd's header for the rationale). When the
# player clicks "ARMOR STATION" in the toolbar, the parts bin swaps for the
# paint toolkit and the cutting mat swaps for the wood-desktop workbench
# behind a pan_blur sweep. The hull's MODULES STAY ON, ghosted: they used to
# be reparented away so the player painted a bare chassis, but the armor plan
# is a property of the WHOLE design - where a glacis plate meets the turret
# ring is exactly the decision the player is making - and the paint raycast
# masks to SURFACE_COLLISION_LAYER (16), which only the hull's own surface
# body is on (lab modules are layer 2), so modules never blocked a paint
# click anyway. Ghosting makes the mode a layer over the design instead of
# an amputation of it.
#
# The ghost is GeometryInstance3D.transparency on every module mesh. No
# reparent, no queue_free, no re-instantiation - selection, sub-meshes and
# firing-arc visualisations all survive the round trip untouched, and the
# stat rail keeps quoting the FULL design while the player paints.
func capture_modules_for_paint() -> Array:
	# Returns the live module children of the hull, in their current
	# scene-tree order. The caller (the panel) owns the list across the
	# paint session.
	if not is_instance_valid(hull):
		return []
	var captured: Array = []
	for child in hull.get_children():
		# Skip non-modules: the chassis mesh instance, the physics
		# mesh, and any other decoration. A module is anything that
		# carries the placer's `module_data` meta (set in
		# _place_weapon() / _place_hull_from_ui()).
		if not child.has_meta("module_data"):
			continue
		captured.append(child)
	return captured

func ghost_modules_for_paint(captured: Array) -> void:
	# Fade the captured modules and make the placer's input inert while the
	# panel owns the hull. Selection is cleared so the placer's
	# _unhandled_input doesn't try to operate on a ghosted module.
	if selected_module and captured.has(selected_module):
		_select_module(null)
	for m in captured:
		if is_instance_valid(m):
			_set_module_ghost(m, true)

func unghost_modules_after_paint(captured: Array) -> void:
	for m in captured:
		if is_instance_valid(m):
			_set_module_ghost(m, false)
			_reposition_module_for_armor(m)

func _reposition_module_for_armor(module: Node3D) -> void:
	if not hull or not is_instance_valid(hull):
		return
	var base_pos = module.get_meta("armor_base_pos", module.position)
	var mount_normal = module.get_meta("mount_normal", Vector3.UP)
	module.position = _apply_armor_lift(module, base_pos, mount_normal)

func _set_module_ghost(module: Node, ghosted: bool) -> void:
	for mi in module.find_children("*", "MeshInstance3D", true, false):
		(mi as MeshInstance3D).transparency = 0.78 if ghosted else 0.0

## Lift a module along the surface normal so its base sits on top of the
## painted armor slab rather than inside it.  Stores the pre-lift hull-
## surface position as `armor_base_pos` so re-lift after paint exit can
## start from the same surface point without reverse-raycasting.
func _apply_armor_lift(module: Node3D, local_pos: Vector3,
		local_normal: Vector3) -> Vector3:
	if not hull or not is_instance_valid(hull):
		return local_pos
	var mesh_inst = hull.get_node_or_null("MeshInstance3D") as MeshInstance3D
	if not mesh_inst:
		mesh_inst = hull.get_node_or_null("PhysicsMesh") as MeshInstance3D
	if not mesh_inst or not mesh_inst.mesh:
		return local_pos
	var hull_type = hull.get_meta("type_id", "")
	var facet_result = HullFacetsScript.measure(mesh_inst, hull_type,
		local_pos, local_normal, module.transform.basis)
	var facet_id = facet_result.get("facet_id", -1)
	if facet_id < 0:
		return local_pos
	var plan: Dictionary = hull.get_meta("armor_plan", {})
	var facets: Dictionary = plan.get("facets", {})
	var thickness: float = facets.get(facet_id, {}).get("thickness", 0.0)
	# Always store the hull-surface position so re-lift after paint exit
	# starts from the correct point even if the module was dragged to a
	# different facet since placement.
	module.set_meta("armor_base_pos", local_pos)
	if thickness <= 0.0:
		return local_pos
	var lift := thickness * HullFacetsScript.THICKNESS_LIFT_PER_UNIT
	return local_pos + local_normal * lift


func _place_hull_from_ui(type_id: String):
	if hull:
		_log("Hull already exists, cannot place another until deleted.")
		return

	var catalog_data = ModuleCatalog.get_module_data(type_id)

	hull = StaticBody3D.new()
	hull.name = "Hull"
	hull.collision_layer = 1
	hull.collision_mask = 0
	# Fitted AABB drives BOTH the height this sits at on the ground (y/2) and
	# the meta every dimension consumer reads. See the "Hull-local AABB the
	# visual mesh actually occupies" block in module_catalog.gd for the
	# rationale; the short version is that the catalog `size` is a hand-tuned
	# box the mesh is squashed to fit, and using it here made the hull float
	# above or sink into the ground on every hull whose actual silhouette is
	# smaller than the catalog box.
	var fitted_size: Vector3 = catalog_data.get("size", Vector3.ONE)
	hull.position = Vector3(0, fitted_size.y / 2.0 + stage_y_offset, 0)

	hull.set_meta("base_hull_size", fitted_size)
	hull.set_meta("hull_scale", Vector3(1, 1, 1))
	hull.set_meta("type_id", type_id)

	var phys_mesh = MeshInstance3D.new()
	phys_mesh.name = "PhysicsMesh"
	var authored_mesh = MeshAssetLoader.get_hull_mesh(type_id)
	var fit: Dictionary = {}
	if authored_mesh:
		phys_mesh.mesh = authored_mesh
		fit = ModuleCatalog.get_hull_mesh_fit(type_id, authored_mesh)
		phys_mesh.rotation = fit["rotation"]
		phys_mesh.scale = fit["scale"]
		phys_mesh.position = fit["position"]
		# Re-derive the hull's footprint from the actual fitted mesh. For a
		# primitive-shape hull (the_cube, the_orb, the_rod, the_slab) the
		# fitted AABB is exactly the catalog box, so this is a no-op there;
		# for any authored hull whose proportions disagree with the catalog
		# box, this collapses the box down to the mesh's real extent.
		var fitted_aabb: AABB = ModuleCatalog.get_fitted_aabb_from_fit(authored_mesh, fit)
		if fitted_aabb.size.length_squared() > 0.0:
			fitted_size = fitted_aabb.size
			hull.set_meta("base_hull_size", fitted_size)
			hull.position.y = fitted_size.y / 2.0 + stage_y_offset
	else:
		var box = BoxMesh.new()
		box.size = catalog_data.get("size", Vector3.ONE)
		phys_mesh.mesh = box

	# Never drawn: it carries the same mesh at the same transform as the
	# visual MeshInstance3D below, so rendering both just z-fights (and this
	# one has no material, so the fight is against untextured white). It
	# exists as the hull's physical-shape reference for code that wants the
	# mesh independent of whatever the visual copy is currently showing.
	phys_mesh.visible = false
	hull.add_child(phys_mesh)

	var mesh_inst = MeshInstance3D.new()
	mesh_inst.name = "MeshInstance3D"
	mesh_inst.mesh = phys_mesh.mesh
	mesh_inst.rotation = phys_mesh.rotation
	mesh_inst.scale = phys_mesh.scale
	mesh_inst.position = phys_mesh.position
	hull.add_child(mesh_inst)

	var mat = StandardMaterial3D.new()
	mat.albedo_color = catalog_data.color
	mesh_inst.material_override = mat

	_rebuild_surface_body(hull, phys_mesh)

	# Axis-aligned in hull-local space, and NOT rotated to match the mesh.
	# get_hull_mesh_fit() recentres the visual on the hull's local origin, so
	# this box is too - size is the fitted AABB's size, position stays at the
	# hull node's local origin (the mesh's recentred centre). It used to be
	# the CATALOG box, which (for every hull whose actual silhouette is
	# smaller than the catalog box) was larger than the visible mesh - and
	# every dimension consumer that read this shape (locomotion stations,
	# armor auto-fit, hull.position.y in locomotion-cleared paths, unit.gd's
	# separation/selection/cargo radii) silently read a value that disagreed
	# with what the player could see. Worst on SDF-baked hulls, the spire/
	# catamaran/pillbox/interceptor families, and airship_hull's curved
	# envelope. Now matches the visible mesh, so module placement, click
	# targets, locomotion layout and battle spawns all agree.
	var col = CollisionShape3D.new()
	col.name = "CollisionShape3D"
	var col_box = BoxShape3D.new()
	col_box.size = fitted_size
	col.shape = col_box
	hull.add_child(col)

	add_child(hull)
	update_hull_appearance()
	_log("New hull spawned: " + type_id)
	get_tree().call_group("stat_ui", "update_stats", hull)

var default_locomotion_settings = {
	"wheels": {"wheel_size": 1.0, "num_axles": 4, "wheels_per_axle": 1},
	"tracked_treads": {"tread_width": 1.0},
	# Legs had no entry here at all, so a freshly-dragged set arrived with an
	# empty settings dict and every default had to be re-derived downstream.
	# leg_type in particular has to be present from the first placement, because
	# it decides whether the stations go under the hull or on its flank.
	"legs": {"leg_length": 1.0, "leg_width": 1.0, "count": 4, "leg_type": "stryker"},
	"hover_engine": {},
	"helicopter_rotors": {"size": 1.0, "count": 4},
	"ornithopter_wing": {"size": 1.0, "count": 2},
	"buoyant_envelope": {"prop_count": 2, "blade_count": 3, "blade_pitch": 1.0},
	"screw_drive": {"drum_diameter": 1.0, "helix_depth": 1.0}
}

# `would_clip` is the drag ghost's OWN verdict, handed down by
# drag_drop_manager rather than recomputed here - see _ghost_is_clipping for why
# the answer has to be the same one that tinted the ghost red.
#
# A clipping drop is REFUSED. This is a second deliberate exception to the
# no-hard-blocking rule at MOUNTING_AND_ARMOR_SPEC.md:58, alongside the
# indirect-fire-on-a-wall refusal at :95, and Chris called it on 2026-08-13.
# The rule protects janky-but-interesting outcomes; two parts occupying the same
# cubic metre is not one of those. It previously placed anyway, and the overlap
# was then "shown" by a CSG volume that was itself miscomputed into a duplicate
# of both parts - so the only feedback the player got for a bad drop was the
# vehicle appearing to grow a second copy of itself.
#
# Callers that place programmatically (the test suites, blueprint
# reconstruction) leave `would_clip` false and are unaffected: nothing gates on
# a recomputed overlap, so no existing placement path changes behaviour.
func _place_weapon_from_ui(type_id: String, pos: Vector3, normal: Vector3, would_clip: bool = false):
	var catalog_data = ModuleCatalog.get_module_data(type_id)
	var category = catalog_data.get("category", "module")

	# Refused BEFORE push_undo_snapshot(), so a rejected click does not leave a
	# do-nothing entry on the undo stack for the player to step back through.
	var refusal = _placement_refusal_reason(type_id, category, normal)
	# Not locomotion: a drive ignores `pos` entirely and re-lays its stations out
	# across the hull (update_locomotion, below), so where the ghost happened to
	# be hovering has no bearing on where the drive actually ends up. Refusing on
	# that verdict would reject a perfectly good drive for hovering over a gun.
	if refusal == "" and would_clip and category != "locomotion":
		refusal = "%s would overlap a part already fitted." % catalog_data.get("name", type_id)
	if refusal != "":
		var bm_toast = get_node_or_null("BlueprintManager")
		if bm_toast and bm_toast.has_method("_show_toast"):
			bm_toast._show_toast(refusal, true)
		_log("Placement refused: " + refusal)
		return

	push_undo_snapshot()

	if category == "locomotion":
		# Foundations CAN take locomotion now - per Chris's explicit
		# no-hard-blocking constraint (MOUNTING_AND_ARMOR_SPEC.md addendum),
		# this pre-existing validation gate was removed rather than kept as
		# an exception. A mobile pillbox is exactly the kind of "janky or
		# suboptimal" emergent outcome that's acceptable by design now -
		# see DECISIONS_NEEDED.md.
		var settings = default_locomotion_settings.get(type_id, {}).duplicate()
		update_locomotion(type_id, settings)
	else:
		# Standard weapon/armor placement
		var primary = _place_weapon(type_id, pos, normal)
		var should_mirror = would_mirror(category, pos, normal)
		if should_mirror:
			var mirrored_pos = Vector3(-pos.x, pos.y, pos.z)
			var mirrored_normal = Vector3(-normal.x, normal.y, normal.z)
			var mirror = _place_weapon(type_id, mirrored_pos, mirrored_normal)
			if primary and mirror:
				primary.set_meta("mirrored_counterpart", mirror)
				mirror.set_meta("mirrored_counterpart", primary)

## Lightweight per-instance geometry update for locomotion tweaks that DON'T
## change how many module instances exist (wheel_size, wheels_per_axle,
## tread_width, blade_length, etc. - anything that isn't a "count" tweak).
## Unlike update_locomotion(), this never destroys/recreates any node: it
## just updates each existing instance's own data.tweaks and rebuilds its
## mesh in place, exactly like a weapon's tweak slider does via
## VisualBuilder.rebuild_visual(). That means it's cheap enough to call on
## EVERY value_changed tick during a drag (no debounce needed) and never
## disturbs the current selection or the floating tweak popup's position -
## unlike a full update_locomotion() respawn, which reselects an arbitrary
## instance and visibly jumps the popup around mid-drag (confirmed via a
## real simulated-mouse-drag test - this was the actual cause of the wheels
## size slider feeling "laggy"/unresponsive compared to weapon tweaks).
## Re-fits a placed module's click target to whatever it currently renders.
## Shared by initial placement and by live tweak drags so the two cannot drift.
## Same click-margin policy as _place_weapon() so a tweak drag cannot shrink
## the click area back down to the bare visual bounds.
const _CLICK_MARGIN := 0.10
static func _resize_collider_to_visual(module: Node3D) -> void:
	var bounds := _visual_bounds(module)
	if bounds.size.length_squared() <= 0.0:
		return
	var size := bounds.size
	size.x += _CLICK_MARGIN * 2.0
	size.y += _CLICK_MARGIN * 2.0
	size.z += _CLICK_MARGIN * 2.0
	# Floor: a tweak can in principle strip every visible mesh (e.g. setting
	# every authorable dimension to 0). Without a floor the click target
	# collapses to a point, which a player would experience as the
	# module suddenly becoming unselectable mid-drag.
	var _min_dim = 0.35
	size.x = maxf(size.x, _min_dim)
	size.y = maxf(size.y, _min_dim)
	size.z = maxf(size.z, _min_dim)
	for child in module.get_children():
		if not (child is StaticBody3D):
			continue
		child.position = bounds.get_center()
		for shape_node in child.get_children():
			if shape_node is CollisionShape3D and shape_node.shape is BoxShape3D:
				# Shapes are shared resources by default; resizing one in place
				# would silently resize every other module using the same box.
				if not shape_node.shape.resource_local_to_scene:
					shape_node.shape = shape_node.shape.duplicate()
				shape_node.shape.size = size
				shape_node.position = Vector3.ZERO
		return

func update_locomotion_geometry_tweak(type_id: String, tweak_key: String, value) -> void:
	if not hull: return
	var settings: Dictionary = hull.get_meta("locomotion_settings", {}).duplicate() if hull.has_meta("locomotion_settings") else {}
	settings[tweak_key] = value
	hull.set_meta("locomotion_settings", settings)
	for child in hull.get_children():
		if child.has_meta("module_data"):
			var m_data = child.get_meta("module_data")
			if m_data and m_data.type_id == type_id:
				m_data.tweaks[tweak_key] = value
				VisualBuilderScript.rebuild_visual(child)
				# _apply_mirror_flip() (called once at initial placement for
				# the mirrored side) doesn't scale the module itself - it
				# individually mirrors each of the module's CHILDREN's own
				# transforms and marks them "_mirrored", one time. rebuild_
				# visual() just destroyed those mirrored children and built
				# fresh, un-mirrored ones, and nothing re-applied the mirror
				# afterward - the mirrored-side wheel's driveshaft/gearbox
				# would silently un-mirror (render on the wrong side) on the
				# very first live wheel_size/wheels_per_axle drag. Redo it
				# here since this is the only path that rebuilds children
				# after initial placement.
				if child.get_meta("scale_flip_x", false):
					_apply_mirror_flip(child)
					# rebuild_visual()/build_visual() deliberately skip
					# StaticBody3D children when clearing/rebuilding a module's
					# mesh (so the click-target collider survives visual
					# rebuilds), which means it is never resized on its own -
					# and a tweak that just reshaped the mesh has, by
					# definition, moved the thing the player is trying to click.
					# Re-measured from the geometry that was just rebuilt, the
					# same way _place_weapon() sizes it initially, so the two
					# paths cannot disagree.
					_resize_collider_to_visual(child)
	get_tree().call_group("stat_ui", "update_stats", hull)

## Re-runs the current locomotion layout against the hull as it is NOW.
##
## Every station position is derived from hull_size (x_offset, z_limit, the
## ellipse radii, the drum span), but update_locomotion() only ever ran at
## initial placement and on a count tweak - nothing re-ran it when the hull
## itself changed. Dragging a hull scale handle after choosing locomotion left
## the wheels spaced for the hull you used to have, getting worse the further
## you dragged. gizmo_3d.gd's rescale handler calls this now.
##
## No-ops when the hull has no locomotion, so it is safe to call unconditionally.
func refresh_locomotion() -> void:
	if not hull or not hull.has_meta("locomotion_type"):
		return
	var type_id: String = str(hull.get_meta("locomotion_type"))
	if type_id == "":
		return
	var settings: Dictionary = hull.get_meta("locomotion_settings", {})
	update_locomotion(type_id, settings.duplicate())

func update_locomotion(type_id: String, settings: Dictionary) -> void:
	if not hull:
		return
	var had_loco_selection: bool = (selected_module != null and is_instance_valid(selected_module) and selected_module.has_meta("module_data") and selected_module.get_meta("module_data").category == "locomotion")
	var existing_gear := hull.get_node_or_null("RunningGear")
	if existing_gear:
		existing_gear.queue_free()
	var existing_agp := hull.get_node_or_null("AGPRunningGear")
	if existing_agp:
		existing_agp.queue_free()
	var spawned = LocomotionMountScript.rebuild(self, type_id, settings)
	if had_loco_selection and spawned is Array and not spawned.is_empty():
		_select_module(spawned[0])
	
## The bounds of everything a module actually renders, in the module's own
## local space. Empty AABB if it has no meshes yet.
##
## Deliberately walks MeshInstance3D children rather than trusting the catalog
## size: a locomotion assembly's parts are positioned and scaled by its builder
## from tweaks the catalog knows nothing about, so the catalog box and the thing
## on screen routinely disagree by a factor of several.
# Moved to visual_builder.gd's measure_visual_bounds() so the battle spawner can
# measure ride height with the identical code - see that function's header. Kept
# as a thin alias because this file calls it from four places.
static func _visual_bounds(module: Node3D) -> AABB:
	return VisualBuilderScript.measure_visual_bounds(module)

# Re-fits a module's click collider to whatever geometry it currently has.
#
# Needed because a module can BECOME (or stop being) a sponson by being dragged
# between facets, and the collider is otherwise only ever sized once at initial
# placement. A weapon dragged onto a wall keeps its catalog-sized box, which is
# then buried in the hull and unclickable; one dragged back off keeps an
# oversized box measured around a blister it no longer has.
static func _refit_module_collider(module: Node3D) -> void:
	if module == null or not is_instance_valid(module):
		return
	# Found BY TYPE, not by name. The click body is added unnamed, so Godot
	# names it after its class - but only while that name is free; on a
	# collision it silently becomes "@StaticBody3D@N" instead, the same trap
	# VisualBuilder._hardware() documents. A get_node_or_null("StaticBody3D")
	# here would then no-op without a word and the collider would never re-fit.
	var bodies: Array = module.find_children("*", "StaticBody3D", false, false)
	if bodies.is_empty():
		return
	var body := bodies[0] as StaticBody3D
	var shapes: Array = body.find_children("*", "CollisionShape3D", false, false)
	var shape: CollisionShape3D
	if shapes.is_empty():
		# An EMPTY body is a legitimate starting state, not a broken one:
		# blueprint_manager's reconstruction creates the body up front (so
		# build_visual's "skip StaticBody3D children" rule preserves it through
		# the rebuild) and leaves the fitting to this function, because the
		# geometry to fit against does not exist yet at that point. Bailing out
		# here left every module in a LOADED blueprint with a body and no shape,
		# i.e. unclickable.
		shape = CollisionShape3D.new()
		shape.shape = BoxShape3D.new()
		body.add_child(shape)
	else:
		shape = shapes[0] as CollisionShape3D
		if not (shape.shape is BoxShape3D):
			return
	var bounds := _visual_bounds(module)
	if bounds.size.length_squared() <= 0.0:
		return
	var fit_size = bounds.size
	# Same click-margin policy as initial placement. Without this, a
	# module dragged across a facet and re-fit would lose the +0.10 comfort
	# margin that _place_weapon() gave it on the way in - the same
	# "hard to select" symptom recurring mid-edit, on a part the player
	# already proved they could click once.
	fit_size.x += _CLICK_MARGIN * 2.0
	fit_size.y += _CLICK_MARGIN * 2.0
	fit_size.z += _CLICK_MARGIN * 2.0
	var min_dim = 0.35
	fit_size.x = maxf(fit_size.x, min_dim)
	fit_size.y = maxf(fit_size.y, min_dim)
	fit_size.z = maxf(fit_size.z, min_dim)
	(shape.shape as BoxShape3D).size = fit_size
	body.position = bounds.get_center()

static func _snap_local_to_grid(pos: Vector3, normal: Vector3, interval: float = 0.25) -> Vector3:
	var snapped := pos
	if absf(normal.x) < 0.9:
		snapped.x = roundf(snapped.x / interval) * interval
	if absf(normal.y) < 0.9:
		snapped.y = roundf(snapped.y / interval) * interval
	if absf(normal.z) < 0.9:
		snapped.z = roundf(snapped.z / interval) * interval
	return snapped

func _place_weapon(type_id: String, pos: Vector3, normal: Vector3, is_mirror: bool = false, tweaks: Dictionary = {}) -> Node3D:
	var catalog_data = ModuleCatalog.get_module_data(type_id)
	var category = catalog_data.get("category", "module")
	
	var new_weapon = Node3D.new()

	# Mount classification is hoisted ABOVE build_visual() deliberately. The
	# sponson blister is built inside build_visual() off the "sponson" meta
	# (it has to be - build_visual clears every non-StaticBody3D child on
	# entry, so anything attached afterwards is destroyed by the next rebuild),
	# which means the meta must already exist by the time it runs. The rest of
	# the mount metas are set here too rather than left at the bottom of this
	# function, so there is one place that decides them instead of two.
	#
	# Only the NORMAL is needed this early; the grid snap below moves the
	# position but cannot change which facet was hit.
	var hull_type_for_mount = hull.get_meta("type_id", "") if hull else ""
	var early_local_normal = normal
	if hull:
		early_local_normal = hull.global_transform.basis.inverse() * normal
	var mount_style = ""
	var wall_mount = false
	var sponson = false
	if category == "weapon":
		mount_style = ModuleCatalog.get_mount_style(type_id, hull_type_for_mount)
		wall_mount = _is_wall_mount(category, mount_style, type_id, early_local_normal)
		sponson = wall_mount and ModuleCatalog.is_sponson_capable(type_id)
		new_weapon.set_meta("mount_style", mount_style)
		new_weapon.set_meta("mount_normal", normal)
		new_weapon.set_meta("facet", ModuleCatalog.classify_facet(early_local_normal))
		new_weapon.set_meta("sponson", sponson)

	VisualBuilderScript.build_visual(type_id, new_weapon, catalog_data.get("size", Vector3.ONE), catalog_data.color, tweaks)
	
	var static_body = StaticBody3D.new()
	static_body.collision_layer = 2 # Modules layer
	static_body.collision_mask = 0
	var col_size = catalog_data.get("size", Vector3.ONE)
	var col_center = Vector3(0, col_size.y / 2.0, 0)
	# Locomotion click targets are measured from the geometry that was just
	# built, not re-derived from the tweaks.
	#
	# This used to be a per-type override block: wheels, tracked_treads and legs
	# each had a hand-written box here that restated, in the placer, whatever
	# _build_wheels()/_build_tracked_treads()/_build_legs() had done to the
	# mesh. The same formulas also existed a THIRD time in
	# update_locomotion_geometry_tweak(), to keep the collider in sync during a
	# live slider drag. Three copies of one formula, synchronised by hand, drifted
	# exactly as often as you would expect - "needing to be clicked very close to
	# dead center" once wheel_size moved the wheel away from the box, and a tread
	# collider that stayed a ~2.5-unit stub while the rendered loop spanned the
	# whole hull. Both were fixed by copying the builder's math across again.
	#
	# The builder already knows where it put things, so ask it. The other seven
	# locomotion types never got an override at all and had been silently wrong
	# in the same way; they are fixed by the same change.
	#
	# WEAPONS need it for the same reason, and this is a PRE-EXISTING bug that
	# has nothing to do with sponsons - Chris hit it on ordinary top-deck
	# pintle mounts too ("difficult to select in the normal pintle mount as
	# well"). Two compounding causes:
	#
	#  1. Every monolithic authored mesh is yawed 90 degrees about Y at
	#     visual_builder.gd:441 (the TripoSG orientation offset), which swings
	#     the barrel from Z onto X. The catalog `size` it is NOT rotated with -
	#     heavy_machine_gun is (0.3, 0.3, 1.0), so the click box is a thin
	#     sliver lying ACROSS the gun rather than along it.
	#  2. The mesh is then uniformly fit-scaled to the largest catalog axis, so
	#     the other two axes rarely match the box either.
	#
	# Measuring solves both at once, because measure_visual_bounds() walks the
	# child transforms and so accounts for that yaw and that scale. Same
	# argument as the locomotion case above, which is where this was first
	# found and fixed for one category only.
	#
	# Armor and structural are deliberately excluded: armor is auto-scaled to
	# its facet right after this and structural colliders are separately kept
	# in step with struct_scale (see blueprint_manager and gizmo_3d), so both
	# have their own sizing story that this must not fight.
	if category != "armor":
		var visual_aabb := _visual_bounds(new_weapon)
		if visual_aabb.size.length_squared() > 0.0:
			col_size = visual_aabb.size
			col_center = visual_aabb.get_center()
	# CLICK COMFORT MARGIN. The old code floored each axis at 0.35, which
	# made the X/Y of a thin gun (HMG receiver is 0.14 wide) a little wider
	# than the visible part, but did nothing for the other two thirds of
	# the visible mesh - the barrel is the longest part of a gun and the
	# "near miss" the player keeps hitting is the gap between barrel and
	# receiver. A per-axis margin extends the collider uniformly OUTSIDE
	# the visible bounds (not into them, so it cannot make clipping
	# detection fire on an already-correctly-placed part), and the floor
	# stays as a backstop for the rare part that builds no mesh.
	#
	# Tuned: at 0.10 the autocannon and HMG are noticeably easier to hit,
	# adjacent modules (typically 0.5+ apart on a deck) do not start
	# stealing each other's clicks. A larger value is tempting, but a 0.20
	# margin over a small part (e.g. a 0.3x0.3 catalog) pushes the click
	# box out to 0.7 - bigger than the part itself, which is the exact
	# "click a different part by accident" failure this is trying to avoid.
	var click_margin := 0.10
	col_size.x += click_margin * 2.0
	col_size.y += click_margin * 2.0
	col_size.z += click_margin * 2.0
	var min_dim = 0.35
	col_size.x = maxf(col_size.x, min_dim)
	col_size.y = maxf(col_size.y, min_dim)
	col_size.z = maxf(col_size.z, min_dim)
	static_body.position = col_center
	var collision_shape = CollisionShape3D.new()
	var col_box = BoxShape3D.new()
	col_box.size = col_size
	collision_shape.shape = col_box
	static_body.add_child(collision_shape)
	new_weapon.add_child(static_body)
	var data = ModuleDataResource.new()
	data.type_id = type_id
	data.module_name = catalog_data.name
	data.category = category
	data.base_hp = catalog_data.hp
	data.base_weight = catalog_data.weight
	data.cost_metal = catalog_data.metal
	data.cost_crystal = catalog_data.crystal
	data.base_dps = catalog_data.dps
	data.base_heal_rate = catalog_data.get("heal_rate", 0.0)
	data.base_energy_capacity = catalog_data.get("energy_capacity", 0.0)
	data.base_power_output = catalog_data.get("power_output", 0.0)
	data.base_vision_bonus = catalog_data.get("vision_bonus", 0.0)
	data.tweaks = tweaks.duplicate()
	new_weapon.set_meta("module_data", data)
	
	hull.add_child(new_weapon)

	# Snap to 0.25m grid relative to hull local space
	var local_pos = Vector3.ZERO
	var local_normal = early_local_normal
	if hull:
		local_pos = _snap_local_to_grid(hull.to_local(pos), local_normal, 0.25)

	# Weapon meshes are authored with their own mounting post/base baked in
	# (bottom of the mesh sits at local Y=0 - see build_visual()'s
	# monolithic-mesh placement above). For a flush mount, rotating local-up to
	# the surface normal puts that baked-in post against whatever facet it
	# landed on - flat deck, sloped glacis, or underside alike - replacing the
	# old column-extrusion + procedurally-drawn hardware model (abandoned; see
	# MOUNTING_AND_ARMOR_SPEC.md addendum, 2026-07-21).
	#
	# For a sponson the module is instead pushed INBOARD along the outboard
	# axis so its post and body end up inside the hull and only the barrel
	# protrudes - which is why position and basis are decided together by
	# _mount_transform() rather than separately. See _is_sponson_mount().
	#
	# Every category goes through this, not just weapons: a radar mast, armor
	# plate or fuel tank dropped on the underside has the same "base against
	# the hull, body projecting outward" requirement a gun does (non-weapons
	# never sponson, so they always take the flush branch). See _align_up_to()
	# for the antiparallel bug this fixes.
	# build_visual() ran above and, for a sponson, measured the real geometry
	# to pick an embed that still leaves barrel showing. Use that exact number
	# so the weapon and its housing agree on where the hull skin is.
	var mount_xf := _mount_transform(local_pos, local_normal, type_id, wall_mount, sponson,
		new_weapon.get_meta("sponson_embed", -1.0))
	if hull:
		new_weapon.position = _apply_armor_lift(new_weapon, mount_xf.origin,
			local_normal)
	else:
		new_weapon.global_position = pos
	new_weapon.transform.basis = mount_xf.basis

	# Bottom-facet vertical flip: mirrors _update_module_placement()'s treatment so
	# the initial-drop path matches the drag-and-place path exactly. Weapons need
	# rebuild_visual() + _refit_module_collider() because their collider was sized
	# from the upright geometry before the flip was applied; the rebuild re-measures
	# the now-correctly-oriented visual and the refit re-sizes the collider to it.
	if local_normal.y < -0.7:
		new_weapon.transform.basis = new_weapon.transform.basis * Basis(Vector3.UP, PI)
		if category == "weapon":
			VisualBuilderScript.rebuild_visual(new_weapon)
			_refit_module_collider(new_weapon)

	# Auto-scale armor to fit facet.
	# The PAINT_TYPE_IDS entries (armor_plating, slat_armor, spaced_composite,
	# ablative_foam) are cosmetic armor-station paints, not placeable modules.
	# The only real "category: armor" module is the energy
	# barrier projector, which is filtered through this branch.
	if category == "armor" and not ArmorPaintScript.PAINT_TYPE_IDS.has(type_id):
		if hull:
			var facet_meas = _measure_hull_facet(hull, new_weapon.position, local_normal, new_weapon.transform.basis)
			var target_x = 1.0
			var target_z = 1.0
			var armor_pos = new_weapon.position

			if facet_meas["valid"]:
				target_x = facet_meas["size"].x
				target_z = facet_meas["size"].z
				armor_pos = facet_meas["center"]
				# ORIENT TO THE FACET, NOT TO THE CLICKED TRIANGLE. The mount
				# basis above came from the raycast hit normal, which on a
				# curved facet tilts with the drop point - so two plates on the
				# same face used to sit at different angles. The facet's own
				# mean normal is the face's orientation, and it is the frame
				# build_plate lays the draped geometry out in, so the two cannot
				# disagree. The bottom-facet flip is deliberately not re-applied:
				# it exists to keep asymmetric hardware upright, and a plate has
				# no up.
				if facet_meas.has("basis"):
					new_weapon.transform.basis = facet_meas["basis"]
			else:
				# Same fallback as update_locomotion's - the collider's box is
				# the fitted AABB; the reference constant is the "no hull loaded"
				# safety net.
				var hull_size: Vector3 = Vector3(ModuleCatalog.REFERENCE_HULL_SIZE)
				var hull_shape = hull.get_node_or_null("CollisionShape3D")
				if hull_shape and hull_shape.shape is BoxShape3D:
					hull_size = hull_shape.shape.size

				var local_x = new_weapon.transform.basis.x.abs()
				var local_z = new_weapon.transform.basis.z.abs()

				if local_x.x > 0.5: target_x = hull_size.x
				elif local_x.y > 0.5: target_x = hull_size.y
				elif local_x.z > 0.5: target_x = hull_size.z

				if local_z.x > 0.5: target_z = hull_size.x
				elif local_z.y > 0.5: target_z = hull_size.y
				elif local_z.z > 0.5: target_z = hull_size.z

				var armor_facet = ModuleCatalog.classify_facet(local_normal)
				match armor_facet:
					"left", "right":
						var x_off = sign(local_normal.x) * hull_size.x / 2.0 if hull_shape else armor_pos.x
						armor_pos = Vector3(x_off, 0, 0)
					"front", "back":
						var z_off = sign(local_normal.z) * hull_size.z / 2.0 if hull_shape else armor_pos.z
						armor_pos = Vector3(0, 0, z_off)
					_:
						var y_off = sign(local_normal.y) * hull_size.y / 2.0 if hull_shape else armor_pos.y
						armor_pos = Vector3(0, y_off, 0)

			var cat_size = catalog_data.get("size", Vector3.ONE)
			if type_id in ["energy_barrier_projector", "bubble_shield_projector"]:
				new_weapon.scale = Vector3.ONE
				new_weapon.position = armor_pos
			else:
				new_weapon.scale.x = target_x / cat_size.x
				new_weapon.scale.z = target_z / cat_size.z
				new_weapon.position = armor_pos

			var mod_data = new_weapon.get_meta("module_data", null) as ModuleData
			if mod_data:
				mod_data.scale_multiplier = Vector3(new_weapon.scale.x, 1.0, new_weapon.scale.z)

			new_weapon.set_meta("facet", ModuleCatalog.classify_facet(local_normal))
			# SHAPE CONFORM. Replace the BoxMesh the visual-builder fallback
			# created (line ~3587 in visual_builder.gd, the "Simple box mesh
			# for armor and basic parts" branch) with a polygonal plate whose
			# outline is the facet's convex hull. Skipped for the energy
			# barrier & bubble shield projectors because those modules have their
			# own procedural visual rebuilt and their scale is forced to (1,1,1).
			if not (type_id in ["energy_barrier_projector", "bubble_shield_projector"]) and facet_meas.get("valid", false):
				if apply_facet_plate(new_weapon, facet_meas, type_id, cat_size, hull):
					# Mesh's vertices are already in the new_weapon's local
					# frame at the right extent and thickness, so the
					# stretch that the auto-scale above applied is now
					# wrong - reset it. Same for the scale_multiplier the
					# collider refit reads.
					new_weapon.scale = Vector3.ONE
					if mod_data:
						mod_data.scale_multiplier = Vector3.ONE
					# NOW the click box can be fitted, against geometry that
					# finally describes the plate. The blanket `category !=
					# "armor"` skip further up is justified by "armor is
					# auto-scaled to its facet right after this" - which was
					# true while the fit WAS a node scale the box inherited,
					# and false the moment the plate started carrying its own
					# extent. Without this a facet-wide plate keeps the
					# catalog-sized 2 x 0.2 x 2 click target at its centre and
					# is unselectable everywhere else.
					_refit_module_collider(new_weapon)
			if type_id in ["energy_barrier_projector", "bubble_shield_projector"]:
				VisualBuilderScript.build_visual(type_id, new_weapon, catalog_data.size, catalog_data.color, tweaks)

	elif type_id == "resource_harvester":
		if hull:
			var facet_meas = _measure_hull_facet(hull, new_weapon.position, local_normal, new_weapon.transform.basis)
			var target_x = 1.0
			var target_z = 1.0
			var harvester_pos = new_weapon.position

			if facet_meas["valid"]:
				target_x = facet_meas["size"].x
				target_z = facet_meas["size"].z
				harvester_pos = facet_meas["center"]
			else:
				var hull_size: Vector3 = Vector3(ModuleCatalog.REFERENCE_HULL_SIZE)
				var hull_shape = hull.get_node_or_null("CollisionShape3D")
				if hull_shape and hull_shape.shape is BoxShape3D:
					hull_size = hull_shape.shape.size
				target_x = hull_size.x
				target_z = hull_size.y
				harvester_pos = Vector3(0, 0, -hull_size.z / 2.0)

			new_weapon.position = harvester_pos
			new_weapon.set_meta("facet_size", Vector2(target_x, target_z))
			new_weapon.set_meta("facet", "front")
			VisualBuilderScript.build_visual(type_id, new_weapon, catalog_data.get("size", Vector3.ONE), catalog_data.color, tweaks)

	# The weapon mount metas (mount_style, mount_normal, facet, sponson) are
	# set at the TOP of this function, not here: build_visual() needs the
	# sponson flag before it runs, and having one place decide them is what
	# keeps the four placement paths from drifting apart again.

	# Notify the UI that a module was added
	if get_tree():
		get_tree().call_group("stat_ui", "update_stats", hull)
	check_all_clipping()
	return new_weapon

func update_hull_appearance():
	if not hull: return
	var mesh_inst = hull.get_node_or_null("MeshInstance3D") as MeshInstance3D
	if not mesh_inst: return
	# MainLab.tscn's hand-authored startup Hull node predates the
	# PhysicsMesh/MeshInstance3D split and only ships the visual one. Bailing
	# out when PhysicsMesh was missing meant the hull the player actually
	# opens the Design Lab looking at never got its authored mesh, faction
	# material, greebles, decals, front arrow or correctly-sized collider -
	# and every later call (armor thickness, faction, scale) silently no-oped
	# for the same reason. Create the node instead of giving up.
	var phys_mesh = hull.get_node_or_null("PhysicsMesh") as MeshInstance3D
	if not phys_mesh:
		phys_mesh = MeshInstance3D.new()
		phys_mesh.name = "PhysicsMesh"
		phys_mesh.visible = false
		hull.add_child(phys_mesh)

	var type_id = hull.get_meta("type_id") if hull.has_meta("type_id") else "brenntal_medium_a"
	var catalog_data = ModuleCatalog.get_module_data(type_id)
	
	var hull_scale = hull.get_meta("hull_scale") if hull.has_meta("hull_scale") else Vector3(1,1,1)
	var armor_thick = hull.get_meta("armor_thickness") if hull.has_meta("armor_thickness") else 1.0
	var armor_mat_name = hull.get_meta("armor_material") if hull.has_meta("armor_material") else "hardened_steel"
	# Bulk size based on thickness
	var armor_bulk = Vector3(1.0 + (armor_thick - 1.0) * 0.15, 1.0 + (armor_thick - 1.0) * 0.15, 1.0)
	var authored_mesh = MeshAssetLoader.get_hull_mesh(type_id)
	var fit: Dictionary = {}
	if authored_mesh:
		# Per-hull-type custom deform (MOUNTING_AND_ARMOR_SPEC.md #4),
		# proof-of-concept for interceptor_hull only. Genuine regional
		# reshaping of the actual authored mesh via MeshDataTool, not a mesh
		# swap - apply_nose_taper() returns a fresh ArrayMesh each time, so
		# this never mutates MeshAssetLoader's cached shared resource.
			# nose_taper removed with interceptor_hull - hook point for future per-hull mesh deform
		phys_mesh.mesh = authored_mesh
		fit = ModuleCatalog.get_hull_mesh_fit(type_id, authored_mesh, hull_scale * armor_bulk)
		phys_mesh.rotation = fit["rotation"]
		phys_mesh.scale = fit["scale"]
		phys_mesh.position = fit["position"]
	else:
		var box = BoxMesh.new()
		box.size = catalog_data.get("size", Vector3.ONE) * hull_scale * armor_bulk
		phys_mesh.mesh = box
		phys_mesh.scale = Vector3.ONE
		phys_mesh.position = Vector3.ZERO

	mesh_inst.mesh = phys_mesh.mesh
	mesh_inst.scale = phys_mesh.scale
	mesh_inst.rotation = phys_mesh.rotation
	mesh_inst.position = phys_mesh.position

	# The box collider and the base_hull_size meta have to track the visual
	# mesh's actual extent at the CURRENT (hull_scale * armor_bulk), not the
	# catalog box - everything that reads hull_size (locomotion stations,
	# armor auto-fit, unit.gd's separation / selection / cargo radii) flows
	# off these, so leaving them stale at the catalog value made every later
	# rebuild silently disagree with what the player could see.
	#
	# For an authored mesh, the fitted AABB at the current scale is the
	# honest answer; for a primitive / no-mesh hull, the catalog box is the
	# only answer, and the gizmo's BoxMesh path (which sets box.size to
	# `base_hull_size * new_scale`) keeps the collider in sync with the
	# visual mesh.
	var current_size: Vector3 = catalog_data.get("size", Vector3.ONE) * hull_scale * armor_bulk
	if authored_mesh and not fit.is_empty():
		var fitted_aabb: AABB = ModuleCatalog.get_fitted_aabb_from_fit(authored_mesh, fit)
		if fitted_aabb.size.length_squared() > 0.0:
			current_size = fitted_aabb.size
	hull.set_meta("base_hull_size", current_size)
	var col_shape_node := hull.get_node_or_null("CollisionShape3D") as CollisionShape3D
	if col_shape_node and col_shape_node.shape is BoxShape3D:
		if not col_shape_node.shape.resource_local_to_scene:
			col_shape_node.shape = col_shape_node.shape.duplicate()
		(col_shape_node.shape as BoxShape3D).size = current_size

	# Precise placement surface has to track every change to the visual mesh
	# (hull swap, rescale, armor bulk, nose taper) or modules would snap to a
	# stale silhouette.
	_rebuild_surface_body(hull, mesh_inst)

	# UNPAINTED, DELIBERATELY. The Lab used to render the hull in a faction's
	# full livery via apply_hull_materials(), plus that faction's greeble tint
	# and its insignia decals. All three are gone from this screen.
	#
	# Faction is chosen at match setup, and reconstruct_vehicle()'s
	# match_faction_override has always had the last word at spawn - so the
	# livery shown here was a preview of a paint job the match would overwrite,
	# picked from a dropdown whose only other effect (passives on the stat rail)
	# was also wrong for nine factions out of ten. Showing a design in one
	# faction's colours while it is being built implies a commitment the design
	# does not actually carry.
	#
	# What replaces it is the finish the main menu turntable and the Blueprint
	# Library previews already use - flat grey-green injection-moulded plastic,
	# the kit before it is painted. That is the honest read for a screen whose
	# whole subject is the SHAPE you are building, and it is the same call, so
	# the Lab and the previews cannot drift apart.
	#
	# apply_greebles() is still CALLED with NO_FACTION rather than skipped, and
	# the distinction matters: its first act is to delete any existing
	# HullGreebles container, so calling it is what CLEARS the scrap, nets and
	# pennants off a hull that was built under a faction before this change.
	# Skipping the call would have left them attached forever. Under an unknown
	# id its match statement falls to `_: pass`, so what it rebuilds is an empty
	# container - faction greebles are identity, not silhouette, and there is no
	# neutral version of a jury-rigged scrap antenna.
	#
	# The repaint pass below still walks that container, because
	# apply_scale_model_finish() skips a node named "HullGreebles" by design
	# (the right call on a battle mesh, where flattening the greebling costs the
	# silhouette its read). It is a no-op today and stops being one the moment
	# any faction-independent greeble is added.
	var body_size: Vector3 = catalog_data.get("size", Vector3.ONE) * hull_scale * armor_bulk
	HullGreeblesScript.apply_greebles(hull, LiveryScript.NO_LIVERY, body_size)

	var kit_mat := HullMaterialBuilderScript.build_scale_model_material()
	HullMaterialBuilderScript.apply_scale_model_finish(mesh_inst, kit_mat)
	var greebles := hull.get_node_or_null("HullGreebles")
	if greebles:
		for child in greebles.get_children():
			HullMaterialBuilderScript.apply_scale_model_finish(child, kit_mat)

	# No HullDecals call at all. Decals are faction insignia - there is no
	# neutral version of a unit marking, so the answer is not to draw one. Any
	# decal node left over from a hull that was built before this change is
	# removed rather than hidden, so a rebuild cannot resurrect it.
	var stale_decals := hull.get_node_or_null("HullDecals")
	if stale_decals:
		stale_decals.queue_free()

	# Also update collision shape size in the designer
	var col = hull.get_node_or_null("CollisionShape3D") as CollisionShape3D
	if col:
		col.scale = Vector3.ONE
		var col_box = BoxShape3D.new()
		col_box.size = catalog_data.get("size", Vector3.ONE) * hull_scale * armor_bulk
		col.shape = col_box
		# Deliberately left unrotated - see _place_hull_from_ui() for why
		# inheriting the mesh's orientation correction here is wrong.
		col.rotation = Vector3.ZERO
			
	# Manage Front Arrow Indicator (Green triangle pointing along -Z)
	var arrow = hull.get_node_or_null("FrontArrow")
	if not arrow:
		arrow = Node3D.new()
		arrow.name = "FrontArrow"
		
		# Tip: a cone pointing forward (-Z)
		var tip = MeshInstance3D.new()
		tip.name = "Tip"
		var cone = CylinderMesh.new()
		cone.top_radius = 0.0
		cone.bottom_radius = 0.18
		cone.height = 0.35
		tip.mesh = cone
		tip.rotation.x = -PI / 2.0
		tip.position = Vector3(0, 0, -0.175)
		arrow.add_child(tip)
		
		# Shaft: a cylinder behind the tip
		var shaft = MeshInstance3D.new()
		shaft.name = "Shaft"
		var cyl = CylinderMesh.new()
		cyl.top_radius = 0.07
		cyl.bottom_radius = 0.07
		cyl.height = 0.35
		shaft.mesh = cyl
		shaft.rotation.x = -PI / 2.0
		shaft.position = Vector3(0, 0, 0.175)
		arrow.add_child(shaft)
		
		# Vibrant green material
		var mat = StandardMaterial3D.new()
		mat.albedo_color = Color(0.1, 0.9, 0.1)
		mat.emission_enabled = true
		mat.emission = Color(0.1, 0.7, 0.1)
		mat.shading_mode = StandardMaterial3D.SHADING_MODE_UNSHADED
		tip.material_override = mat
		shaft.material_override = mat
		
		hull.add_child(arrow)
		
	var vis_size = catalog_data.get("size", Vector3.ONE) * hull_scale * armor_bulk
	# Position at the front-center of the deck, slightly raised
	arrow.position = Vector3(0, vis_size.y / 2.0 + 0.3, -vis_size.z / 2.0 - 0.5)
	
	# Recalculate stats
	get_tree().call_group("stat_ui", "update_stats", hull)
	check_all_clipping()

# Immediate free (not queue_free) for exactly the same reason _deselect_module()
# frees the "ArcCone" immediately: a gizmo is routinely torn down and rebuilt
# within a SINGLE frame - _select_module(m) is called with m already selected
# on every drag release, and the drag-start handler drops the gizmo just before
# the drag begins. queue_free()'s deferred removal leaves the old node in the
# tree long enough that Godot renames the incoming "Gizmo3D" to "Gizmo3D2" to
# avoid the sibling name collision, after which this by-name lookup can never
# find it again - so the gizmo is orphaned from cleanup and a fresh one stacks
# on top of it on every subsequent drag.
func _free_gizmo(module: Node3D):
	if not module or not is_instance_valid(module):
		return
	# Loop rather than a single lookup so any gizmos already orphaned under a
	# generated name by the old code get cleaned up too.
	for child in module.get_children():
		if child.name.begins_with("Gizmo3D"):
			module.remove_child(child)
			child.free()

func _deselect_module():
	# is_instance_valid guard (2026-07-23 locomotion-tweak fix): a
	# count-changing locomotion tweak (num_axles etc.) calls
	# update_locomotion() synchronously, which queue_free()s every existing
	# instance of that type INCLUDING the currently-selected one, then
	# _apply_tweaks() call_deferred()s a reselect of one of the freshly
	# respawned instances. By the time that deferred _select_module() runs
	# (and reaches here via _deselect_module()), `selected_module` still
	# points at the OLD, by-then-actually-freed instance - selected_module
	# alone is a stale Object reference, not null, so the old `if
	# selected_module:` check passed and get_children() below threw on a
	# freed instance. With the debugger attached (the normal editor Play
	# session) an uncaught script error like that pauses/freezes the running
	# game - exactly the "game locks up" symptom reported when adjusting
	# axle/wheel count.
	if selected_module and is_instance_valid(selected_module):
		# Immediate free (not queue_free) - same reasoning as
		# _refresh_firing_arc()'s own old-arc cleanup: _select_module()
		# calls this and then immediately adds a fresh "ArcCone" (e.g. the
		# reselect-after-drag path in _unhandled_input's mouse-release
		# handler, in the SAME frame). queue_free()'s deferred removal
		# would leave the stale node around long enough for Godot to
		# auto-rename the new one to "ArcCone2" to avoid the name
		# collision - after that, this exact by-name lookup can never find
		# it again, and the firing arc is permanently orphaned from
		# cleanup (visible forever, even after later real deselects).
		for child in selected_module.get_children():
			if child.name == "ArcCone":
				selected_module.remove_child(child)
				child.free()

# Firing envelope preview.
#
# Rewritten 2026-07-21 (Chris: pintle mounts fire in a full sphere, and line
# of sight against the hull/other modules is what limits them). This used to
# draw a flat horizontal wedge at the weapon's own height, which said nothing
# about elevation or depression and so could not express either half of that:
# a pintle's envelope is a SPHERE, minus whatever its own vehicle occludes.
#
# Samples directions over a sphere and raycasts each one against the hull
# (layer 1) and sibling modules (layer 2) - the same two layers auto_weapon.gd
# checks before it fires - so a blocked patch here is a shot combat will
# genuinely refuse to take. Clear directions read blue, occluded ones red.
const ARC_AZIMUTH_SEGMENTS := 24
const ARC_ELEVATION_SEGMENTS := 12
# How far outside the hull's own bounding radius the envelope is drawn.
const ARC_HULL_CLEARANCE := 3.2
const ARC_RADIUS_MIN := 6.0

# --- TRAVERSE ENVELOPE MODEL ------------------------------------------------
#
# Deliberately isolated in one place, because Chris intends to make traverse
# genuinely meaningful later - traverse SPEED as a real cost, and hard vertical
# limits on most weapons. Everything the visualiser knows about "can this
# weapon point here, and how far out of its way is it" goes through
# _traverse_intensity(); adding per-weapon yaw/pitch caps or a speed-weighted
# falloff means editing that one function and the constants below, not the mesh
# builder.
#
# Elevation limits are now per-weapon and live in
# ModuleCatalog.ELEVATION_LIMITS, read through get_elevation_up/down() - the
# same accessors auto_weapon.gd gates real acquisition on, so the envelope drawn
# here and the set of targets the weapon will actually accept cannot drift
# apart.
#
# This replaces a single hardcoded pair (88 degrees up AND down, for every
# weapon in the roster) that was left here as an explicit placeholder for
# exactly this work - "a gun that cannot shoot straight up is the common case
# and this is where that will be expressed". Chris, 2026-08-03: "we need to
# differentiate the elevation available to each different weapon."

# How dim the envelope gets at the far edge of the weapon's traverse. The point
# is to make "this is where the gun already points" instantly separable from
# "this is reachable, but the turret has to swing all the way round for it" -
# which becomes a real cost once traverse speed matters.
const ARC_FALLOFF_MIN := 0.14

func _build_firing_arc(module: Node3D, data) -> Node3D:
	var container = Node3D.new()
	container.name = "ArcCone"

	var arc_facet = module.get_meta("facet", "")
	if arc_facet == "" and module.has_meta("mount_normal") and hull:
		var local_mount_normal = hull.global_transform.basis.inverse() * module.get_meta("mount_normal")
		arc_facet = ModuleCatalog.classify_facet(local_mount_normal)
	var arc_hull_type = hull.get_meta("type_id", "") if hull else ""
	# Same "sponson" meta auto_weapon._ready() reads, so the drawn envelope and
	# the arc combat actually enforces come from one source.
	var limit = ModuleCatalog.get_traverse_limit_angle(data.type_id, arc_facet, arc_hull_type,
		module.get_meta("sponson", false))
	# Read from the instance's own tweaks, not the bare type - the `elevation`
	# tweak raises the ceiling, and the envelope has to show the weapon the
	# player actually built rather than the catalog default.
	var arc_tweaks: Dictionary = data.tweaks if "tweaks" in data else {}
	var pitch_up: float = ModuleCatalog.get_elevation_up(data.type_id, arc_tweaks)
	# Same permissive depression floor combat applies - see
	# auto_weapon.gd's MIN_DEPRESSION_TOLERANCE for why depression is not
	# enforced strictly. Drawing the strict authored value here while combat
	# honours the floor would show the player an envelope narrower than the
	# weapon they actually have.
	var pitch_down: float = maxf(
		ModuleCatalog.get_elevation_down(data.type_id, arc_tweaks),
		AutoWeaponScript.MIN_DEPRESSION_TOLERANCE)

	var exclude_list = []
	_get_colliders_recursive(module, exclude_list)
	var space_state = get_world_3d().direct_space_state
	# Trace from just off the weapon's own mounting face, along ITS up axis -
	# world-up would start a side- or belly-mounted weapon's rays inside the
	# hull it is bolted to and report everything as blocked.
	var origin = module.global_position + module.global_transform.basis.y.normalized() * 0.35

	# frame_built: no independent traverse at all, the whole vehicle aims.
	# A sphere would be a lie, so draw a single forward spike instead.
	if limit <= 0.001:
		container.add_child(_build_fixed_forward_indicator(module, origin, exclude_list, space_state))
		return container

	# Two representations per state, and both matter:
	#   *_fill  translucent triangles, so the covered VOLUME reads at a glance
	#   *_grid  line segments along every cell boundary, so the player can
	#           actually judge WHERE the boundary falls
	#
	# The fill alone (which is all this used to draw) is a soft translucent blob
	# whose edge is impossible to locate - fine for "roughly forward", useless
	# for "can this actually cover the left flank". The grid is what makes it a
	# readable instrument, and it is why the mesh is built as a projected
	# lat/long lattice rather than a smooth shell.
	var radius = _arc_radius_for(module)
	# Per-vertex colour carries the traverse falloff, so one draw call covers
	# the whole gradient. Requires vertex_color_use_as_albedo on the material.
	var fill_v = []
	var fill_c = []
	var grid_v = []
	var grid_c = []

	for ei in range(ARC_ELEVATION_SEGMENTS):
		# Polar angle from +Y (0 = straight up, PI = straight down), so the
		# band genuinely covers full elevation AND full depression.
		var t0 = float(ei) / ARC_ELEVATION_SEGMENTS
		var t1 = float(ei + 1) / ARC_ELEVATION_SEGMENTS
		var phi0 = t0 * PI
		var phi1 = t1 * PI
		for ai in range(ARC_AZIMUTH_SEGMENTS):
			var u0 = float(ai) / ARC_AZIMUTH_SEGMENTS * TAU
			var u1 = float(ai + 1) / ARC_AZIMUTH_SEGMENTS * TAU
			var u_mid = (u0 + u1) * 0.5
			var phi_mid = (phi0 + phi1) * 0.5

			# ONLY DRAW WHERE THE WEAPON CAN ACTUALLY TARGET (Chris, 2026-08-02).
			#
			# Two separate reasons a direction can be unavailable, and both now
			# result in nothing being drawn rather than in a red cell:
			#   * MECHANICAL - outside the mount's traverse envelope.
			#   * OBSTRUCTED - the vehicle's own hull or another module is in
			#     the way.
			# Drawing obstructed cells in red made the envelope a full sphere
			# with a red patch, which reads as "the gun covers everything" at a
			# glance - the opposite of the truth. An envelope that simply is not
			# there where the gun cannot shoot needs no reading at all.
			var intensity = _traverse_intensity(u_mid, phi_mid, limit, pitch_up, pitch_down)
			if intensity <= 0.0:
				continue

			var mid = _sphere_point(phi_mid, u_mid, 1.0)
			var world_dir = (module.global_transform.basis * mid).normalized()

			var query = PhysicsRayQueryParameters3D.create(origin, origin + world_dir * radius)
			query.collision_mask = 3 # Layer 1 (Hull) + Layer 2 (Modules)
			query.exclude = exclude_list
			if not space_state.intersect_ray(query).is_empty():
				continue

			var a = _sphere_point(phi0, u0, radius)
			var b = _sphere_point(phi0, u1, radius)
			var c = _sphere_point(phi1, u1, radius)
			var d = _sphere_point(phi1, u0, radius)

			# Low, because the material is CULL_DISABLED: every fragment is
			# painted twice, once by the near face and once by the far one, so
			# the on-screen alpha is roughly double this. At 0.10 the envelope
			# went milky and swallowed the model inside it.
			var fill_col = Color(UITokens.SIGNAL_HAZARD, 0.045 * intensity)
			for v in [a, b, c, a, c, d]:
				fill_v.append(v)
				fill_c.append(fill_col)

			# All four edges per cell. Shared edges get drawn twice, which is
			# cheaper than de-duplicating them and visually identical.
			var grid_col = Color(UITokens.SIGNAL_HAZARD, 0.90 * intensity)
			for pair in [[a, b], [b, c], [c, d], [d, a]]:
				grid_v.append(pair[0])
				grid_c.append(grid_col)
				grid_v.append(pair[1])
				grid_c.append(grid_col)

	if not fill_v.is_empty():
		container.add_child(_arc_surface("ArcFill", fill_v,
			UITokens.SIGNAL_HAZARD * 0.5, fill_c))
	if not grid_v.is_empty():
		container.add_child(_arc_surface("ArcGrid", grid_v,
			UITokens.SIGNAL_HAZARD, grid_c, Mesh.PRIMITIVE_LINES))

	return container


# Envelope radius for a module: outside the hull by a clear margin, so the grid
# reads as a field of fire AROUND the vehicle rather than as a bubble stuck to
# the turret. Sized from the hull rather than fixed, so it stays correct across
# a 70kg roadster and an 800kg heavy.
func _arc_radius_for(_module: Node3D) -> float:
	var hull_radius := 0.0
	if hull and hull.has_meta("type_id"):
		var hsize: Vector3 = ModuleCatalog.get_module_data(
			hull.get_meta("type_id")).get("size", Vector3.ONE)
		hull_radius = hsize.length() * 0.5
	return maxf(ARC_RADIUS_MIN, hull_radius + ARC_HULL_CLEARANCE)


# How strongly the envelope draws in a given direction, in the module's own
# frame. Returns 0 for "cannot point here at all", otherwise 0..1 where 1 is
# the weapon's default heading.
#
# THIS IS THE EXTENSION POINT for the traverse work Chris has planned. Today it
# models a yaw limit, fixed pitch stops, and a falloff with angular distance
# from the default heading. When traverse becomes a real per-weapon stat, this
# is where per-weapon yaw/pitch caps and a speed-weighted cost go; nothing in
# the mesh builder needs to change, because it already just asks for a number.
#
# `azimuth` is measured the same way _sphere_point() measures it (0 = the
# barrel's forward, -Z). `phi` is polar from +Y.
func _traverse_intensity(azimuth: float, phi: float, yaw_limit: float,
						 pitch_up: float = PI * 0.5, pitch_down: float = PI * 0.5) -> float:
	# Yaw: how far the turret must swing from its default heading.
	var yaw = absf(wrapf(azimuth, -PI, PI))
	if yaw > yaw_limit + 0.001:
		return 0.0

	# Pitch: elevation above / depression below the weapon's own horizon.
	# Per-weapon now (see the ARC_PITCH comment block above). The defaults are
	# a full hemisphere so any caller that does not pass limits gets the old
	# unrestricted behaviour rather than a silently clipped envelope.
	var pitch = PI * 0.5 - phi
	if pitch > pitch_up + 0.001 or -pitch > pitch_down + 0.001:
		return 0.0

	# Falloff with total angular distance off the default heading. Normalised
	# against the actual yaw limit so a 60-degree mount fades across its own
	# 60 degrees rather than across a notional 180.
	var span = maxf(yaw_limit, 0.001)
	var t = clampf(yaw / span, 0.0, 1.0)
	# Squared, so the bright region genuinely reads as "where it already
	# points" instead of as a slow linear wash across the whole envelope.
	return lerpf(1.0, ARC_FALLOFF_MIN, t * t)

# Point on a sphere in the module's local frame. phi is measured from +Y so
# phi=0 is straight up and phi=PI straight down; azimuth 0 faces -Z, matching
# the barrel-forward convention used everywhere else.
static func _sphere_point(phi: float, azimuth: float, radius: float) -> Vector3:
	var sin_phi = sin(phi)
	return Vector3(sin_phi * sin(azimuth), cos(phi), -sin_phi * cos(azimuth)) * radius

# `colors` is a per-vertex array parallel to `vertices`, carrying the traverse
# falloff. Passing it per-vertex rather than baking several meshes at different
# alphas keeps the whole gradient in one draw call and lets the falloff be
# continuous instead of banded.
func _arc_surface(surface_name: String, vertices: Array, emission: Color,
		colors: Array = [], primitive: int = Mesh.PRIMITIVE_TRIANGLES) -> MeshInstance3D:
	var mesh = ImmediateMesh.new()
	mesh.surface_begin(primitive)
	for i in vertices.size():
		if i < colors.size():
			mesh.surface_set_color(colors[i])
		mesh.surface_add_vertex(vertices[i])
	mesh.surface_end()

	var mi = MeshInstance3D.new()
	mi.name = surface_name
	mi.mesh = mesh

	var mat = StandardMaterial3D.new()
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.emission_enabled = true
	# White albedo so the per-vertex colours come through unmultiplied - the
	# falloff lives entirely in vertex alpha.
	mat.albedo_color = Color.WHITE
	mat.vertex_color_use_as_albedo = true
	mat.emission = emission
	mat.emission_energy_multiplier = 0.5
	# The envelope wraps the weapon, so without this it z-fights its own far
	# side and the module inside it.
	mat.depth_draw_mode = BaseMaterial3D.DEPTH_DRAW_DISABLED
	mi.material_override = mat
	return mi

# A frame_built weapon aims by turning the whole vehicle, so its "arc" is one
# fixed direction - drawn as a short spike, coloured by whether that single
# line of fire is clear.
func _build_fixed_forward_indicator(module: Node3D, origin: Vector3, exclude_list: Array, space_state) -> MeshInstance3D:
	var reach = _arc_radius_for(module)
	var world_dir = -module.global_transform.basis.z.normalized()
	var query = PhysicsRayQueryParameters3D.create(origin, origin + world_dir * reach)
	query.collision_mask = 3
	query.exclude = exclude_list
	var blocked = not space_state.intersect_ray(query).is_empty()

	# Two crossed triangles, so the spike reads from any camera angle. Stays
	# PRIMITIVE_TRIANGLES - it is a solid marker, not a lattice like the
	# envelope, and drawing these six verts as lines would give three
	# disconnected segments.
	var half = 0.08
	var tip = Vector3(0, 0, -reach)
	var verts = [
		Vector3(-half, 0, 0), Vector3(half, 0, 0), tip,
		Vector3(0, -half, 0), Vector3(0, half, 0), tip,
	]
	# A frame-built gun with its ONE line of fire obstructed is worth saying
	# out loud, so this is the only place alert-red survives in the arc
	# visualiser - there is no envelope here to simply omit.
	var col = UITokens.SIGNAL_ALERT if blocked else UITokens.SIGNAL_HAZARD
	var cols = []
	for i in verts.size():
		cols.append(Color(col, 0.85))
	return _arc_surface("BlockedArc" if blocked else "ClearArc", verts, col, cols)

# Whether the firing envelope is drawn. Toggled from the radial menu's Arc
# wedge. Persisted across selections because it is a VIEW preference - a player
# comparing coverage across several turrets should not have to re-enable it on
# every part they click.
var show_firing_arc: bool = true


func toggle_firing_arc() -> void:
	show_firing_arc = not show_firing_arc
	if not show_firing_arc:
		if is_instance_valid(selected_module):
			var existing = selected_module.get_node_or_null("ArcCone")
			if existing:
				selected_module.remove_child(existing)
				existing.free()
	else:
		_refresh_firing_arc()


func _refresh_firing_arc():
	if not show_firing_arc: return
	if not selected_module or not is_instance_valid(selected_module): return
	if not selected_module.has_meta("module_data"): return
	var data = selected_module.get_meta("module_data")
	if data.category != "weapon": return
	var old = selected_module.get_node_or_null("ArcCone")
	if old:
		# Immediate free (not queue_free): this can be called multiple times
		# within the same frame during a drag, and queue_free's deferred
		# removal would leave a stale same-named node around long enough to
		# cause the new one to be auto-renamed "ArcCone2", breaking the
		# name-based lookup/cleanup used everywhere else in this file.
		selected_module.remove_child(old)
		old.free()
	selected_module.add_child(_build_firing_arc(selected_module, data))

# --- Precise placement surface ---------------------------------------------
#
# The hull's CollisionShape3D is an axis-aligned BOX of the catalog size,
# because that is what every dimension-reading caller needs (locomotion
# mounting, armor facet fitting, clipping). But a hull mesh only touches that
# box where it is widest: everywhere it curves, tapers or slopes, the visible
# surface sits well inside its own bounding box. Placement raycasts hit the
# box, so modules landed on an invisible shell and floated off the hull -
# worst on the tapered ship keels and the airship's curved envelope.
#
# HullSurface is a second StaticBody3D carrying a trimesh of the ACTUAL hull
# mesh, on its own collision layer so placement can query it alone. Layer 5
# (bit value 16) is unused by the hull(1)/modules(2)/gizmos(4)/buildings(8)
# assignments already in play. Placement prefers a HullSurface hit and falls
# back to the box when there is no authored mesh to trace against.
const SURFACE_COLLISION_LAYER := HullSurfaceScript.SURFACE_COLLISION_LAYER

# Delegates to scripts/hull_surface.gd so blueprint_manager.gd's designer
# reconstruction can build an identical surface body for a loaded blueprint.
func _rebuild_surface_body(target_hull: Node3D, source_mesh_inst: MeshInstance3D):
	HullSurfaceScript.rebuild(target_hull, source_mesh_inst)

static func _measure_hull_facet(hull: Node3D, local_pos: Vector3, local_normal: Vector3, module_basis: Basis) -> Dictionary:
	var result = {
		"size": Vector3.ZERO,
		"center": local_pos,
		"outline": PackedVector2Array(),
		"valid": false
	}
	if not hull or not is_instance_valid(hull):
		return result

	var mesh_inst = hull.get_node_or_null("MeshInstance3D") as MeshInstance3D
	if not mesh_inst:
		mesh_inst = hull.get_node_or_null("PhysicsMesh") as MeshInstance3D
	if not mesh_inst or not mesh_inst.mesh:
		return result

	# BAKED FACET MAP FIRST. hull_facets.gd answers "which face is this" from a
	# segmentation computed once per hull, so the result depends only on WHICH
	# facet was hit and never on where within it - measured across 216 drop
	# points per hull, zero facets came back ambiguous, against 15 of 15 on the
	# Brenntal for the live flood below.
	#
	# The live measurement stays as the fallback, for three real cases: a hull
	# whose sidecar has not been baked yet, one whose .glb was re-exported so
	# the triangle-count guard trips, and the Hull Builder's in-progress
	# assemblies, which have no sidecar at all.
	var baked := HullFacetsScript.measure(mesh_inst, hull.get_meta("type_id", ""),
		local_pos, local_normal, module_basis)
	if baked.get("valid", false):
		return baked

	var xform = mesh_inst.transform

	var faces: PackedVector3Array = mesh_inst.mesh.get_faces()
	if faces.is_empty() or faces.size() % 3 != 0:
		return result

	var norm = local_normal.normalized()
	var bx = module_basis.x.normalized()
	var bz = module_basis.z.normalized()

	var num_tris = faces.size() / 3
	var matching_tris = []
	var tri_centers = []
	var tri_verts_hull = []

	for i in range(num_tris):
		var v0 = xform * faces[i * 3 + 0]
		var v1 = xform * faces[i * 3 + 1]
		var v2 = xform * faces[i * 3 + 2]
		var tri_n = (v1 - v0).cross(v2 - v0)
		if tri_n.length_squared() < 1e-8:
			continue
		tri_n = tri_n.normalized()

		if abs(tri_n.dot(norm)) > 0.90:
			var center = (v0 + v1 + v2) / 3.0
			var plane_dist = abs((center - local_pos).dot(norm))
			if plane_dist < 0.20:
				matching_tris.append(i)
				tri_centers.append(center)
				tri_verts_hull.append([v0, v1, v2])

	if matching_tris.is_empty():
		return result

	# Find closest matching triangle to clicked local_pos
	var start_idx = 0
	var best_d = 1e9
	for i in range(matching_tris.size()):
		var d = (tri_centers[i] - local_pos).length_squared()
		if d < best_d:
			best_d = d
			start_idx = i

	# Flood-fill connected coplanar triangles from start_idx. The plate's
	# intent is to be the WHOLE FACET, slightly thickened - so the
	# facet_verts set has to grow out to every triangle that shares the
	# facet's normal and is vertex-connected to the initial click hit,
	# not stop at the 0.20m plane_dist filter. (The 0.20m filter is
	# still used above to pick the STARTING triangle - the click
	# registration; everything connected past that is in.)
	var visited = {}
	var queue = [start_idx]
	visited[start_idx] = true
	var facet_verts: Array = []

	while not queue.is_empty():
		var curr = queue.pop_back()
		var tv = tri_verts_hull[curr]
		facet_verts.append(tv[0])
		facet_verts.append(tv[1])
		facet_verts.append(tv[2])

		for n in range(matching_tris.size()):
			if visited.has(n):
				continue
			var nv = tri_verts_hull[n]
			var shares = false
			for v_a in tv:
				for v_b in nv:
					if (v_a - v_b).length_squared() < 0.005:
						shares = true
						break
				if shares:
					break
			if shares:
				visited[n] = true
				queue.append(n)

	if facet_verts.is_empty():
		return result

	var min_x = 1e9
	var max_x = -1e9
	var min_z = 1e9
	var max_z = -1e9
	# Outline points are collected in 2D tangent coordinates (relative to the
	# clicked position). The convex hull of these is the facet's actual outline
	# in the (bx, bz) plane - used by the armor visual to take the shape of the
	# facet instead of just the bounding rectangle. The 2D coords are kept
	# raw here; the caller can re-centre against `mid_x`/`mid_z` (returned via
	# the existing `center` field) before passing them to mesh builders.
	var outline_pts: PackedVector2Array = PackedVector2Array()
	outline_pts.resize(facet_verts.size())

	for v in facet_verts:
		var rel = v - local_pos
		var px = rel.dot(bx)
		var pz = rel.dot(bz)
		min_x = min(min_x, px)
		max_x = max(max_x, px)
		min_z = min(min_z, pz)
		max_z = max(max_z, pz)

	for i in range(facet_verts.size()):
		var rel = facet_verts[i] - local_pos
		outline_pts[i] = Vector2(rel.dot(bx), rel.dot(bz))

	var size_x = max_x - min_x
	var size_z = max_z - min_z
	if size_x > 0.1 and size_z > 0.1:
		var mid_x = (min_x + max_x) * 0.5
		var mid_z = (min_z + max_z) * 0.5
		result["size"] = Vector3(size_x, 0, size_z)
		result["center"] = local_pos + bx * mid_x + bz * mid_z
		result["valid"] = true
		# 2D convex hull of the facet's vertices, in the (bx, bz) tangent
		# plane. Re-centred on the bounding-box midpoint so the resulting
		# mesh's local origin = the bbox centre, matching where the placer
		# positions the module. The input set is the whole facet
		# (flood-filled above), so the convex hull is the facet's actual
		# outline, not just a small clicked area. The placer then extrudes
		# the polygon along +Y (the new_weapon's Y axis, which is the
		# surface normal because the basis is _align_up_to(local_normal))
		# by the catalog thickness, and the result reads as a slightly
		# thicker bit of hull with the facet's shape, size, and
		# orientation. Geometry2D.convex_hull handles degenerate input
		# (collinear points, duplicates) by returning the largest subset,
		# but the caller still has to guard against `size() < 3` for a
		# polygon mesh.
		if outline_pts.size() >= 3:
			var centred := PackedVector2Array()
			centred.resize(outline_pts.size())
			for i in range(outline_pts.size()):
				centred[i] = Vector2(outline_pts[i].x - mid_x, outline_pts[i].y - mid_z)
			var hull_pts := Geometry2D.convex_hull(centred)
			if hull_pts.size() >= 3:
				result["outline"] = hull_pts

	return result


# Builds the polygonal plate that replaces an armor module's BoxMesh once the
# facet's outline is known. The plate is built in the new_weapon's LOCAL frame
# (X = bx tangent, Y = hull normal, Z = bz tangent), with its bottom face at
# Y=0 (the hull skin) and its top face at Y=thickness (the catalog's stated
# plate depth). The outline must already be centred on the bounding-box
# midpoint - see _measure_hull_facet's "outline" field.
#
# WHAT THIS IS AND ISN'T
# ---------------------------------------------------------------------------
# It IS a polygonal plate whose outline matches the facet's convex hull, so a
# plate dropped on a pentagon-shaped hull facet reads as a pentagon and not as
# a rectangle stretched over the same bounding box. UVs on the top face are
# normalised to the outline's own bounding box (0..1), so the catalog's
# color/pattern scales with the facet - a thin long facet gets a thin long
# plate, a fat short facet gets a fat short one, with no per-facet tweaking.
#
# It IS NOT a concave hull. Geometry2D.convex_hull fills concavities. For the
# roster's hulls (mostly boxy, simple convex facets) this is exact; for a
# hypothetical notched or L-shaped facet the plate will smooth over the
# notch. That is a deliberate "good enough for now" - going to a real concave
# hull means an alpha shape / re-rim algorithm, which is out of scope for the
# facet-fitting pass.
#
# It IS NOT a CSG cut against the hull mesh. The plate sits flat on the
# hull surface; the hull's own micro-curvature is the only thing that
# prevents a perfect flush on non-planar facets. For a true coplanar fit the
# hull mesh's UVs would have to be reused and the plate projected onto them,
# which is a different architecture.
static func _build_facet_polygon_mesh(outline: PackedVector2Array, thickness: float) -> ArrayMesh:
	if outline.size() < 3 or thickness <= 0.0:
		return null
	# Outline bbox for UV mapping on the top face. Bbox-relative UVs are the
	# same frame the BoxMesh was implicitly using (its size.x/.z was the
	# catalog extent, with the same default UV stretch).
	var min_x = 1e9
	var max_x = -1e9
	var min_y = 1e9
	var max_y = -1e9
	for p in outline:
		min_x = min(min_x, p.x)
		max_x = max(max_x, p.x)
		min_y = min(min_y, p.y)
		max_y = max(max_y, p.y)
	var w = max_x - min_x
	var h = max_y - min_y
	if w < 0.001 or h < 0.001:
		return null

	# Centroid in 2D - the apex of the top and bottom fan. The fan's apex is
	# the mean of the outline vertices; for a symmetric outline (rectangle,
	# regular polygon) this matches the bounding-box midpoint already encoded
	# in the outline's frame, and for an irregular one it just makes the fan
	# tessellate a bit more evenly.
	var c := Vector2.ZERO
	for p in outline:
		c += p
	c /= float(outline.size())

	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)

	# --- TOP FACE (triangular fan from centroid, normal +Y) ----------------
	# Godot's default mesh winding is CCW for front faces, and Geometry2D's
	# convex_hull returns vertices in CCW order viewed from +Y. Fan triangles
	# (centroid, p_i, p_{i+1}) therefore face UP, which is what an armor plate
	# wants - the visible side is the one facing the camera/player.
	#
	# UV channel gotcha: SurfaceTool 4.x has set_uv(), NOT add_uv(). The UV
	# is bound to the NEXT vertex added - so set_uv() has to be called before
	# add_vertex(), not after, or the wrong vertex carries the UV. (Stacking
	# three add_uv()s then three add_vertex()s is the silent failure mode the
	# original draft shipped with - the mesh was built but every vertex
	# carried UV (0,0) and the armor's color stretched across the whole top
	# face. set_uv() is the correct API.)
	var centroid_top_uv := Vector2((c.x - min_x) / w, (c.y - min_y) / h)
	var centroid_top := Vector3(c.x, thickness, c.y)
	for i in range(outline.size()):
		var p := outline[i]
		var p_next := outline[(i + 1) % outline.size()]
		var p_top := Vector3(p.x, thickness, p.y)
		var p_next_top := Vector3(p_next.x, thickness, p_next.y)
		var p_uv := Vector2((p.x - min_x) / w, (p.y - min_y) / h)
		var p_next_uv := Vector2((p_next.x - min_x) / w, (p_next.y - min_y) / h)
		st.set_uv(centroid_top_uv)
		st.add_vertex(centroid_top)
		st.set_uv(p_uv)
		st.add_vertex(p_top)
		st.set_uv(p_next_uv)
		st.add_vertex(p_next_top)

	# --- BOTTOM FACE (same fan, reversed winding, normal -Y) ---------------
	# Reversed so the bottom face's triangles face DOWN. Visible from below
	# the hull, which is the only place a viewer ever sees it.
	#
	# UV channel note (carried over from the top-face block): set_uv() binds
	# to the NEXT vertex and stays bound. The top-fan loop ends with the
	# last outline vertex's UV still active, so every add_vertex() below
	# would inherit that UV silently and pin all the bottom / side verts
	# to a single texel. Explicitly binding (0, 0) before each add_vertex()
	# below resets the binding to a known value - safe for these faces
	# because the standard material does not texture the underside anyway.
	var centroid_bot := Vector3(c.x, 0.0, c.y)
	for i in range(outline.size()):
		var p := outline[i]
		var p_next := outline[(i + 1) % outline.size()]
		var p_bot := Vector3(p.x, 0.0, p.y)
		var p_next_bot := Vector3(p_next.x, 0.0, p_next.y)
		st.set_uv(Vector2.ZERO)
		st.add_vertex(centroid_bot)
		st.set_uv(Vector2.ZERO)
		st.add_vertex(p_next_bot)
		st.set_uv(Vector2.ZERO)
		st.add_vertex(p_bot)

	# --- SIDE FACES (quads between top and bottom edges) --------------------
	# Two triangles per side. The exact winding is left to generate_normals()
	# below; for an armor plate the side faces are a thin strip whose normals
	# mostly matter for shading, not for visibility. Same UV-clear rule as
	# the bottom face: explicit (0, 0) before each add_vertex().
	for i in range(outline.size()):
		var p := outline[i]
		var p_next := outline[(i + 1) % outline.size()]
		var p_top := Vector3(p.x, thickness, p.y)
		var p_next_top := Vector3(p_next.x, thickness, p_next.y)
		var p_bot := Vector3(p.x, 0.0, p.y)
		var p_next_bot := Vector3(p_next.x, 0.0, p_next.y)
		st.set_uv(Vector2.ZERO)
		st.add_vertex(p_top)
		st.set_uv(Vector2.ZERO)
		st.add_vertex(p_bot)
		st.set_uv(Vector2.ZERO)
		st.add_vertex(p_next_top)
		st.set_uv(Vector2.ZERO)
		st.add_vertex(p_next_top)
		st.set_uv(Vector2.ZERO)
		st.add_vertex(p_bot)
		st.set_uv(Vector2.ZERO)
		st.add_vertex(p_next_bot)

	st.generate_normals()
	return st.commit()


# Installs the facet-conforming plate onto an armor module. THE ONLY PLACE that
# does it: _place_weapon, _reclassify_module_after_drag and
# blueprint_manager.reconstruct_vehicle all route through here, so a plate is
# identical whether it was just dropped, dragged onto a new facet, loaded from
# disk, or spawned into a match.
#
# WHY THE CHILD'S TRANSFORM IS RESET, AND WHY THAT IS THE WHOLE FIX
# ---------------------------------------------------------------------------
# Every armor type in the catalog ships an authored .glb and none are in
# MODULAR_ASSEMBLY_TYPES, so build_visual() takes its MONOLITHIC branch, which
# leaves the mesh child carrying three things the authored plate needs and the
# conform plate must not inherit:
#
#   * rotation.y = 90 deg - the TripoSG native orientation offset
#   * scale = fit_scale   - uniform fit onto the catalog's largest axis
#                           (measured: 2.50x armor_plating, 2.00x slat_armor,
#                            1.96x spaced_composite, 2.01x ablative_foam)
#   * position.y          - the authored mesh's bottom-anchor correction
#
# Assigning `.mesh` alone - which is what this used to do - therefore rendered a
# plate measured at 2.81 x 3.46 as 8.64 x 7.02, 0.50 thick, floating 0.10 above
# the skin, with its two tangent axes swapped by the yaw. That is exactly the
# "much too large, rotated 90 degrees" symptom tests/test_facet_polygon_visual.gd's
# own header describes, and NEITHER of the two polygon tests could catch it:
# both build a fresh MeshInstance3D at identity instead of reusing the one
# build_visual() made, so they verify the mesh math and never touch the
# transform that was destroying it.
#
# The polygon mesh's vertices are ALREADY in the module's local frame, at the
# measured extent and the catalog thickness, spanning y = 0 (the hull skin) to
# y = thickness. Identity is the only correct transform for it.
#
# THE MATERIAL IS DELIBERATELY LEFT ALONE (Chris, 2026-08-17). Only the SHAPE
# conforms to the hull; the plate keeps its own armor material and colour, which
# is what makes it legible as armor rather than as a bulge in the hull. That
# material is already correct on the way in: the authored .glb goes through
# _mesh_inst(), which resolves PartMaterials' "armor" role (metallic 0.45,
# roughness 0.58, hull_upper livery zone) against the catalog colour. Swapping
# `.mesh` alone preserves it, so this function must NOT repaint - an earlier
# draft applied the hull's own finish here and erased exactly the distinction
# the role was added to draw.
static func apply_facet_plate(module: Node3D, facet_meas: Dictionary,
		type_id: String, cat_size: Vector3, hull: Node3D = null) -> bool:
	if module == null or not is_instance_valid(module):
		return false
	# CONFORMED when the measurement came from a baked facet map, flat
	# otherwise. A flat plate is only defensible on a facet that is actually
	# flat, and most are not - so the extruded convex-hull polygon is now the
	# FALLBACK for un-baked hulls rather than the normal case.
	var poly: ArrayMesh = null
	if hull != null and is_instance_valid(hull) and facet_meas.has("facet_id"):
		var mesh_inst := hull.get_node_or_null("MeshInstance3D") as MeshInstance3D
		if mesh_inst == null:
			mesh_inst = hull.get_node_or_null("PhysicsMesh") as MeshInstance3D
		poly = HullFacetsScript.build_plate(mesh_inst, hull.get_meta("type_id", ""),
			int(facet_meas["facet_id"]), type_id, cat_size,
			facet_meas.get("center", module.position),
			facet_meas.get("basis", module.transform.basis))
	if poly == null:
		poly = _build_facet_polygon_mesh(facet_meas.get("outline", PackedVector2Array()), cat_size.y)
	if poly == null:
		return false
	var inst: MeshInstance3D = null
	for child in module.get_children():
		if child is MeshInstance3D:
			inst = child as MeshInstance3D
			break
	if inst == null:
		# No DIRECT mesh child: either the monolithic branch wrapped its mesh in
		# an animation pivot, or the .glb is missing and the procedural fallback
		# drew nothing. The plate still has to exist, and it has to be a direct
		# child so the next call through here finds it rather than stacking a
		# second one on top. Only THIS path has no material to preserve, so it
		# is the only one that resolves one - the same role and colour the
		# authored path would have produced.
		inst = MeshInstance3D.new()
		var plate_type := ""
		if module.has_meta("module_data") and module.get_meta("module_data") != null:
			plate_type = module.get_meta("module_data").type_id
		var plate_cat: Dictionary = ModuleCatalog.get_module_data(plate_type) if plate_type != "" else {}
		inst.material_override = PartMaterialsScript.get_material(
			PartMaterialsScript.role_for_part(plate_type),
			plate_cat.get("color", Color.WHITE))
		module.add_child(inst)
	inst.mesh = poly
	inst.transform = Transform3D.IDENTITY
	return true


# Raycast used by every placement path. Traces the precise hull surface first
# and only falls back to the bounding box if that misses, so a dropped module
# sits on the hull you can see rather than on its bounding shell.
func surface_raycast(ray_origin: Vector3, ray_dir: Vector3, length: float = 1000.0, exclude: Array = []):
	var space_state = get_world_3d().direct_space_state
	var to = ray_origin + ray_dir * length
	var precise = PhysicsRayQueryParameters3D.create(ray_origin, to)
	precise.collision_mask = SURFACE_COLLISION_LAYER
	precise.exclude = exclude
	var hit = space_state.intersect_ray(precise)
	if hit:
		_update_facet_highlight(hit.position, hit.normal)
		return hit
	var fallback = PhysicsRayQueryParameters3D.create(ray_origin, to)
	fallback.collision_mask = 1
	fallback.exclude = exclude
	var fb_hit = space_state.intersect_ray(fallback)
	if fb_hit:
		_update_facet_highlight(fb_hit.position, fb_hit.normal)
		return fb_hit
	_hide_facet_highlight()
	return {}

func _update_facet_highlight(pos: Vector3, normal: Vector3):
	if not _facet_highlight:
		_facet_highlight = MeshInstance3D.new()
		var quad = QuadMesh.new()
		quad.size = Vector2(1, 1)
		_facet_highlight.mesh = quad
		var mat = StandardMaterial3D.new()
		mat.albedo_color = Color(0.2, 0.8, 0.2, 0.5)
		mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		mat.emission_enabled = true
		mat.emission = Color(0.2, 0.8, 0.2)
		mat.emission_energy_multiplier = 0.5
		_facet_highlight.material_override = mat
		add_child(_facet_highlight)
	
	_facet_highlight.visible = true
	# Default orientation from the raycast hit normal -- used only until
	# _measure_hull_facet returns the facet's own frame, which replaces it.
	var base_basis = _align_up_to(normal)
	_facet_highlight.global_transform.basis = base_basis * Basis(Vector3.RIGHT, -PI/2.0)
	_facet_highlight.global_position = pos + normal * 0.02
	
	if hull and is_instance_valid(hull):
		var local_pos = hull.to_local(pos)
		var local_normal = hull.global_transform.basis.inverse() * normal
		var mod_basis = _align_up_to(local_normal)
		var facet_info = _measure_hull_facet(hull, local_pos, local_normal, mod_basis)
		if facet_info.get("valid", false):
			var facet_size = facet_info["size"]
			if _facet_highlight.mesh is QuadMesh:
				_facet_highlight.mesh.size = Vector2(max(0.1, facet_size.x), max(0.1, facet_size.z))
			# Use the facet's OWN basis and normal for orientation and position,
			# not the raycast hit normal. On curved hulls the hit normal and the
			# facet mean normal diverge -- the size was measured in the facet's
			# tangent frame, so the QuadMesh must be oriented in that same frame,
			# otherwise the highlight is stretched and rotated relative to the
			# actual facet surface.
			var facet_normal: Vector3 = facet_info.get("normal", normal)
			var facet_basis: Basis = facet_info.get("basis", _align_up_to(facet_normal))
			_facet_highlight.global_transform.basis = facet_basis * Basis(Vector3.RIGHT, -PI/2.0)
			var global_center = hull.to_global(facet_info["center"])
			_facet_highlight.global_position = global_center + facet_normal * 0.02
		else:
			if _facet_highlight.mesh is QuadMesh:
				_facet_highlight.mesh.size = Vector2(1, 1)

func _hide_facet_highlight():
	if _facet_highlight:
		_facet_highlight.visible = false

# Basis that rotates the module's local +Y (its "up", i.e. the direction the
# body projects away from its baked-in mounting base) onto `n`, the surface
# normal of the facet it was dropped on. Every category uses this now, so a
# module's base always sits flush against the hull and its body always
# projects outward - including straight down off the underside.
#
# Two bugs this replaces:
#
# 1. Godot's Quaternion(from, to) constructor special-cases ANTIPARALLEL
#    inputs to the quaternion (0,1,0,0) - a 180-degree spin about Y - which
#    maps UP straight back to UP. So Basis(Quaternion(UP, DOWN)) is not a
#    flip at all, and anything mounted on the hull's underside kept pointing
#    UP, burying its body inside the hull instead of hanging below it.
# 2. Non-weapon categories additionally guarded the whole rotation behind
#    `abs(normal.dot(UP)) < 0.999`, which skips the top and bottom faces
#    entirely - the two facets most likely to need it.
static func _align_up_to(n: Vector3) -> Basis:
	var target = n.normalized()
	if target.length_squared() < 0.5:
		return Basis.IDENTITY
	var d = Vector3.UP.dot(target)
	if d > 1.0 - 0.000001:
		return Basis.IDENTITY
	if d < -1.0 + 0.000001:
		# Genuine flip: rotate a half turn about a HORIZONTAL axis, so +Y
		# really does end up pointing at -Y.
		return Basis(Vector3.RIGHT, PI)
	return Basis(Quaternion(Vector3.UP, target))

# --- Wall and sponson mounting ---------------------------------------------
# TWO decisions, deliberately separate, because conflating them got artillery
# boxed into a housing it cannot shoot out of.
#
#   _is_wall_mount()    - should this module be LEVELLED, muzzle outboard?
#   _is_sponson_mount() - should it additionally be EMBEDDED IN A HOUSING with
#                         a narrowed arc?
#
# The first is a geometry fix and applies to every weapon. _align_up_to() puts
# local +Y on the surface normal, which is right for a deck, a slope or a
# belly but incoherent on a near-VERTICAL face, where "up" is horizontal.
# Measured directly, that put a front-facet weapon's muzzle straight into the
# ground, a rear-facet one straight at the sky, and rolled the side-facet ones
# 90 degrees so their elevation cone opened sideways
# (auto_weapon._within_elevation reads basis.y as "up").
#
# The second is a capability question, and for a mortar the answer is no - a
# housing and a 60-degree arc deny exactly the open sky a lobbing weapon needs.
# See ModuleCatalog.is_sponson_capable(). So an artillery piece on a wall is
# levelled and aimed outboard on an open mount, keeping its full elevation and
# full traverse; a machine gun in the same spot gets the blister.
#
# Deliberately narrow:
#   * non-weapons never wall-mount. An armor plate MUST stay flush to the
#     facet it auto-fits, and a fuel tank in a gun housing is nonsense.
#   * absf(), so the BELLY stays a flush inverted pintle. That is spec'd
#     behaviour (spec #3 "bottom"), not an accident of the old code.
#
# EVERY mount style wall-mounts, including "turret" and "frame_built". A first
# pass admitted only "pintle", reading MOUNTING_AND_ARMOR_SPEC.md:25's "the
# existing tank-cannon (enclosed turret) is already handled correctly - leave
# it as-is" as covering all facets. It does not: that line is about the TOP
# DECK, where a turret genuinely was already right. On a vertical face
# basic_cannon was broken in exactly the same way as everything else - its
# muzzle went into the ground on the front facet - and excluding it just left
# the reported bug in place. A tank cannon buried in a hull side firing through
# a housing is a casemate, which is a real thing and the correct read here.
#
# frame_built is admitted for the same reason: a railgun in the front glacis
# should aim out of it, not at the dirt. Its traverse stays zero regardless,
# because get_traverse_limit_angle() tests frame_built BEFORE the sponson flag.
# `_mount_style` is kept in the signature (and unused) because every caller
# already has it to hand and a future rule may well need it again - the four
# call sites should not have to change shape for that.
static func _is_wall_mount(category: String, _mount_style: String,
						   type_id: String, local_normal: Vector3) -> bool:
	if category != "weapon":
		return false
	if local_normal.length_squared() < 0.5:
		return false
	var n := local_normal.normalized()
	if Vector3(n.x, 0.0, n.z).length_squared() < 0.000001:
		return false
	return absf(n.y) < ModuleCatalog.get_sponson_up_alignment(type_id)

static func _is_sponson_mount(category: String, mount_style: String,
							  type_id: String, local_normal: Vector3) -> bool:
	return _is_wall_mount(category, mount_style, type_id, local_normal) \
		and ModuleCatalog.is_sponson_capable(type_id)

# Why a placement is refused, or "" to allow it.
#
# A DELIBERATE EXCEPTION to the no-hard-blocking rule
# (MOUNTING_AND_ARMOR_SPEC.md:58, "traits compose and drive simulation
# behavior - whatever that produces, including janky/suboptimal outcomes -
# never validation logic that prevents 'weird' combinations"). Chris called
# this one explicitly on 2026-08-04: an artillery piece or mortar on a vertical
# hull face is not an interestingly-janky outcome, it is a nonsense one, and
# there is no orientation that makes a lobbing weapon work off a wall. An
# earlier pass tried levelling them on an open mount instead of blocking; the
# call was that they should simply not go there.
#
# Kept as narrow as possible so it does not become a precedent: it refuses
# exactly one combination - a weapon whose catalog says it cannot be sponsoned,
# on a face steep enough to require one. Everything else, including every
# genuinely weird trait combination the spec is protecting, still goes through.
# Will placing this module at this point ALSO produce a mirrored copy?
#
# THE SINGLE PLACE THIS IS DECIDED, for the same reason _mount_transform is:
# the rule had two implementations that disagreed, and the disagreement was
# total rather than subtle.
#
# _place_weapon_from_ui asked THIS rule (mirror_enabled, off the centreline,
# and for armor only on a left/right facet). drag_drop_manager's ghost asked a
# different one - `catalog_data.get("is_symmetric", true)`, showing the mirror
# preview only for a part whose catalog entry said it was asymmetric. No entry
# in module_catalog.gd sets is_symmetric at all, so that default made the ghost
# preview a mirrored copy for exactly zero parts in the game, while
# mirror_enabled defaults to true and placement mirrored nearly everything.
#
# The player therefore never saw the second part they were about to get, and -
# once drops started being refused for clipping - the mirrored half was the one
# copy nobody had checked for overlaps. Both paths call this now.
func would_mirror(category: String, pos: Vector3, normal: Vector3) -> bool:
	if not mirror_enabled:
		return false
	if category == "armor":
		# Armor auto-fits and centers on its whole facet (see _place_weapon's
		# "Auto-scale armor to fit facet" block). Only left/right facets have a
		# distinct mirror position - top/bottom/front/back are already centered
		# on the symmetry plane, so mirroring them would stack an identical
		# duplicate plate directly on top of the original
		# (MOUNTING_AND_ARMOR_SPEC.md #2).
		var local_n = hull.global_transform.basis.inverse() * normal if hull else normal
		var abs_n = local_n.abs()
		return abs_n.x > abs_n.y and abs_n.x > abs_n.z
	if hull == null:
		return true
	# Placing ANY module dead-center (local x ~= 0, e.g. a railgun/howitzer on
	# the front/back centerline - a very natural placement for "frame_built"
	# weapons) would otherwise mirror it onto its own position, producing a
	# fully-overlapping duplicate that reads as a clipping-red bug. Surfaced by
	# testing frame_built weapons for MOUNTING_AND_ARMOR_SPEC.md #3, but the
	# underlying issue isn't mount-style-specific.
	return abs(hull.to_local(pos).x) > 0.15


func _placement_refusal_reason(type_id: String, category: String, normal: Vector3) -> String:
	if hull == null:
		return ""
	if type_id == "resource_harvester":
		var local_normal = (hull.global_transform.basis.inverse() * normal).normalized()
		if ModuleCatalog.classify_facet(local_normal) != "front" or local_normal.z > -0.85:
			return "Resource Harvester can only be mounted on a flat front facet."
		return ""
	if category != "weapon":
		return ""
	if ModuleCatalog.is_sponson_capable(type_id):
		return ""
	var local_normal = hull.global_transform.basis.inverse() * normal
	var hull_type_for_mount = hull.get_meta("type_id", "")
	var mount_style = ModuleCatalog.get_mount_style(type_id, hull_type_for_mount)
	if not _is_wall_mount(category, mount_style, type_id, local_normal):
		return ""
	var display_name = ModuleCatalog.get_module_data(type_id).get("name", type_id)
	return "%s can't mount on a vertical face - it needs to fire upward." % display_name

# Orientation AND position for one placed module, in hull-local space.
#
# The single place this is decided. All four placement paths call it -
# _place_weapon(), _update_module_placement(), that function's mirror block,
# and _reclassify_module_after_drag() - because four hand-synchronised copies
# of the rule is exactly how two facets ended up broken without anyone
# noticing.
#
# `local_pos` must be the RAW snapped surface point, never an already-offset
# one: the embed offset is applied HERE, and the mirror path derives its
# position by negating X on the raw point, so passing a pre-offset position
# would double the offset on one side only.
#
# `wall` levels the module and aims it outboard. `housed` additionally sinks it
# inboard so its body sits inside the hull behind a blister. A wall mount that
# is NOT housed stays at the clicked surface point: with no housing to cover
# an aperture, embedding it would just look like the gun melting into the hull.
#
# `embed_override` is the depth VisualBuilder actually used when it built the
# housing, measured off the real geometry (see sponson_geometry_for). Passing
# it through rather than re-deriving is what keeps the weapon and its housing
# on the same hole - a stubby barrel gets a shallower embed than the catalog
# default so the muzzle still clears the hull, and the module has to move by
# that same reduced amount. Negative means "no measurement available, use the
# catalog default".
static func _mount_transform(local_pos: Vector3, local_normal: Vector3,
							 type_id: String, wall: bool, housed: bool,
							 embed_override: float = -1.0) -> Transform3D:
	if not wall:
		return Transform3D(_align_up_to(local_normal), local_pos)
	# Outboard is the surface normal with its vertical component dropped: on a
	# truly vertical wall that IS the normal, and on one raked a few degrees it
	# is the horizontal heading the housing is welded to face.
	var outboard := Vector3(local_normal.x, 0.0, local_normal.z)
	if outboard.length_squared() < 0.000001:
		# No horizontal component at all means a deck or a belly, not a wall.
		# Unreachable through _is_wall_mount()'s own guard; kept so this
		# function is total for any caller.
		return Transform3D(_align_up_to(local_normal), local_pos)
	outboard = outboard.normalized()
	# -Z is the muzzle axis everywhere in this project and +Y is hull-up, so
	# the gun sits level, traverses about hull-up and elevates about its own X.
	# This is the same Basis.looking_at idiom auto_weapon._looking_at_safe()
	# uses to build its TRACKING basis - which is why resting and tracking now
	# agree, instead of the weapon visibly snapping upright on acquisition.
	var depth := 0.0
	if housed:
		depth = embed_override if embed_override >= 0.0 \
			else ModuleCatalog.get_sponson_embed_depth(type_id)
	return Transform3D(Basis.looking_at(outboard, Vector3.UP),
					   local_pos - outboard * depth)

# Flags every pair of modules whose VISIBLE geometry actually intersects, and
# draws the offending volume as a red CSG intersection.
#
# THE TEST USED TO BE THREE STACKED OVER-ESTIMATES, which is why parts read red
# while visibly clear of each other (Chris, 2026-08-13):
#
#   1. It sized each module from ModuleCatalog's `size` - an AUTHORING box that,
#      for a monolithic authored mesh, does not even share the mesh's
#      ORIENTATION (build_visual yaws those 90 degrees about Y), so a gun was
#      tested as a sliver lying ACROSS the gun.
#   2. It transformed that box's eight corners and RE-AXIS-ALIGNED the result,
#      so a module at 45 degrees was tested at its diagonal envelope.
#   3. It multiplied by `get_meta("struct_scale", module.scale)` and then
#      applied `module.transform`, which already carried that scale.
#
# Now: ModuleVolume measures the real meshes once, caches it, and runs a
# merged-AABB broad phase followed by a per-mesh separating-axis test. A barrel
# passing OVER a neighbour's base is no longer an overlap, because the barrel
# and the receiver are separate volumes instead of one box around both.
func check_all_clipping():
	clipping_detected = false
	if not hull:
		return
		
	var clipping_root = hull.get_node_or_null("ClippingVolumes")
	if not clipping_root:
		clipping_root = Node3D.new()
		clipping_root.name = "ClippingVolumes"
		hull.add_child(clipping_root)
	else:
		for child in clipping_root.get_children():
			child.queue_free()
			
	var modules = []
	for child in hull.get_children():
		if child.has_meta("module_data") and not child.is_queued_for_deletion():
			modules.append(child)
			
	var clipping_set = {}
	for m in modules:
		clipping_set[m] = false
		
	for i in range(modules.size()):
		var my_module = modules[i]
		var my_data = my_module.get_meta("module_data")
		# No size lookup any more. ModuleVolume measures the module's real
		# meshes, which means struct_scale needs no special case either: a
		# stretched structural piece is REBUILT at its new size by
		# rebuild_visual(), so the measurement already carries the stretch and
		# the old `catalog.size * struct_scale` correction would double it.

		for j in range(i + 1, modules.size()):
			var other_module = modules[j]
			
			if my_module == other_module:
				continue
			if my_module.is_ancestor_of(other_module) or other_module.is_ancestor_of(my_module):
				continue
			if my_module.has_meta("mirrored_counterpart") and my_module.get_meta("mirrored_counterpart") == other_module:
				continue
			if my_module.has_meta("locomotion_group") and other_module in my_module.get_meta("locomotion_group"):
				continue

			var other_data_early = other_module.get_meta("module_data")
			# Armor is a skin, not an obstruction. Armor modules do not affect
			# clipping of other modules or other armor modules.
			if my_data.category == "armor" or other_data_early.category == "armor":
				continue

			# Both modules are children of the hull, so their own transforms are
			# already in the shared frame. ModuleVolume runs the merged-AABB
			# broad phase itself and only pays for the separating-axis test on
			# pairs that are genuinely close.
			if ModuleVolumeScript.overlaps(my_module, my_module.transform,
					other_module, other_module.transform):
				clipping_set[my_module] = true
				clipping_set[other_module] = true
				clipping_detected = true
				
				# Generate CSG Intersection.
				#
				# THE OPERATION LIVES ON group_b, NOT ON THE ROOT. A CSG tree is
				# evaluated by folding each child into the accumulated result using
				# THAT CHILD's operation; the root's own operation only describes
				# how the root would merge into a CSG parent, and this root has no
				# CSG parent. Setting the root to INTERSECTION and leaving both
				# children on UNION therefore computed A UNION B - a solid red
				# duplicate of both clipping modules, hovering over the vehicle,
				# which is exactly the "second instance of everything that's
				# clipping" Chris reported on 2026-08-13.
				var intersection_root = CSGCombiner3D.new()
				# We don't want the CSG to be solid, we want it glowing red.
				var csg_mat = _clipping_material()
				intersection_root.material_override = csg_mat
				clipping_root.add_child(intersection_root)

				# Group A is the BASE of the fold - first child, so its own
				# operation is never consulted.
				var group_a = CSGCombiner3D.new()
				group_a.operation = CSGShape3D.OPERATION_UNION
				intersection_root.add_child(group_a)
				var meshes_a = []
				_find_meshes_recursive(my_module, meshes_a)
				for m_inst in meshes_a:
					var csg_m = CSGMesh3D.new()
					csg_m.mesh = m_inst.mesh
					csg_m.global_transform = m_inst.global_transform
					group_a.add_child(csg_m)
					
				# Group B carries the INTERSECTION - folding B into A is what
				# leaves only the overlapping volume behind.
				var group_b = CSGCombiner3D.new()
				group_b.operation = CSGShape3D.OPERATION_INTERSECTION
				intersection_root.add_child(group_b)
				var meshes_b = []
				_find_meshes_recursive(other_module, meshes_b)
				for m_inst in meshes_b:
					var csg_m = CSGMesh3D.new()
					csg_m.mesh = m_inst.mesh
					csg_m.global_transform = m_inst.global_transform
					group_b.add_child(csg_m)
				
	# Restore all visual materials (since we no longer override them for clipping)
	# The clipping VERDICT is drawn by the CSG intersection volumes above, not by
	# recolouring the modules, so this loop only ever restores - it read
	# clipping_set/module_data/catalog into locals it never used.
	for m in modules:
		var meshes = []
		_find_meshes_recursive(m, meshes)

		# SWAP the override, never MUTATE it. Two separate reasons, both real:
		#
		# 1. Materials are now shared per role+tint (part_materials.gd), for
		#    the sake of bake_module_visual()'s identity-keyed merge. Writing
		#    albedo_color on one part's material here would repaint every
		#    other part in the scene that happens to share that role - one
		#    clipping module would turn the entire vehicle red.
		#
		# 2. Even before sharing, the "not clipping" branch flattened EVERY
		#    mesh in the module to the catalog colour on every single pass -
		#    and this runs on every placement, drag, rotation and tweak. So
		#    the per-part colours the builders carefully assign (dark barrel,
		#    pale lens, warm brass) survived only until the first clipping
		#    check, which is to say never. Remembering the original override
		#    and restoring THAT is what lets per-part material roles actually
		#    reach the screen in the Design Lab.
		for mesh in meshes:
			if not mesh.has_meta("base_material"):
				mesh.set_meta("base_material", mesh.material_override)
			mesh.material_override = mesh.get_meta("base_material")

	_refresh_firing_arc()

# Would a module of `ghost_type_id`, sitting at `ghost_transform`, overlap
# anything already on the hull?
#
# `ghost_transform` is the DRAG GHOST's own transform, which drag_drop_manager
# parents to MainLab - not to the hull. Every placed module is a child of the
# hull, and _get_parent_space_aabb measures them in hull-local space. Those two
# frames are not the same: _place_hull_from_ui sits the hull at
# y = fitted_size.y / 2, so comparing the raw ghost transform against
# hull-local AABBs tested the ghost against a copy of the vehicle floating half
# a hull-height above where it really is. Near misses read as clips and real
# overlaps read as clear, which is survivable while this only tints a ghost red
# and is NOT survivable now that it also refuses the drop.
#
# So convert first. Both the ghost and the hull are children of MainLab, so the
# hull's inverse takes the ghost the rest of the way into hull-local space.
#
# `ghost_node` is the live ghost. Pass it whenever you have it: the ghost is a
# real built module tree, so its own meshes can be measured exactly like a
# placed module's, and the preview then agrees with what check_all_clipping()
# will say a moment later about the same part in the same place. Without it this
# falls back to a catalog-sized box, which is the estimate this whole change
# exists to stop trusting - so the fallback is deliberately GENEROUS about
# calling things clear rather than risk refusing a legal drop.
func is_ghost_clipping(ghost_transform: Transform3D, ghost_type_id: String,
		ghost_node: Node3D = null) -> bool:
	if hull == null:
		return false

	var my_catalog = ModuleCatalog.get_module_data(ghost_type_id)
	var local_transform := hull.transform.affine_inverse() * ghost_transform

	# The ghost's measured volume, in the ghost's own local space. The fallback
	# builds a single box from the catalog size so the shape of the test is
	# identical either way and only its accuracy differs.
	var my_boxes: Array = []
	if ghost_node != null and is_instance_valid(ghost_node):
		my_boxes = ModuleVolumeScript.clip_boxes(ghost_node)
	if my_boxes.is_empty():
		var half: Vector3 = (my_catalog.size as Vector3) * 0.5
		my_boxes = [{
			"c": Vector3.ZERO,
			"h0": Vector3(half.x, 0, 0),
			"h1": Vector3(0, half.y, 0),
			"h2": Vector3(0, 0, half.z),
		}]

	var ghost_boxes: Array = []
	for b in my_boxes:
		ghost_boxes.append(ModuleVolumeScript.to_frame(b, local_transform))
	var ghost_aabb := ModuleVolumeScript.merged_aabb(ghost_boxes)

	var modules = hull.get_children().filter(func(c): return c is Node3D and c.has_meta("module_data"))

	for other_module in modules:
		var other_data = other_module.get_meta("module_data")
		if my_catalog.category == "armor" or other_data.category == "armor":
			continue

		# Broad phase, matching ModuleVolume.overlaps()' own structure. Derived
		# from the SAME framed list the narrow phase then walks, so a module
		# that fell back to its catalog box cannot be rejected here by an empty
		# measured AABB it never used.
		var framed_other: Array = []
		for other_box in ModuleVolumeScript.clip_boxes(other_module):
			framed_other.append(ModuleVolumeScript.to_frame(other_box, other_module.transform))
		if framed_other.is_empty():
			continue
		if not ghost_aabb.intersects(ModuleVolumeScript.merged_aabb(framed_other)):
			continue

		for ob in framed_other:
			for gb in ghost_boxes:
				if ModuleVolumeScript.pair_overlaps_with_margin(gb, ob):
					return true

	return false

# Collects the module's own body meshes for clipping recolouring. Skips the
# editor-overlay subtrees entirely: "ArcCone" (firing-arc wedges, which carry
# their own deliberate blue/red materials) and "Gizmo3D" (the manipulator
# handles). The gizmo was previously walked into and had material_override
# assigned on every clipping pass, so selecting a module repainted its own
# transform handles in the module's catalog colour - and turned them solid red
# whenever the module was clipping, which is precisely when you need to see
# the handles to drag it back out.
# One shared "this part is clipping" material for the whole scene. Built once
# rather than per mesh so swapping it in is free, and so it can never be
# confused with a part's own material by the base_material bookkeeping above.
static var _clipping_mat: StandardMaterial3D = null

static func _clipping_material() -> StandardMaterial3D:
	if _clipping_mat == null:
		_clipping_mat = StandardMaterial3D.new()
		_clipping_mat.albedo_color = Color(1.0, 0.0, 0.0)
		_clipping_mat.emission_enabled = true
		_clipping_mat.emission = Color(1.0, 0.0, 0.0)
		_clipping_mat.emission_energy_multiplier = 1.0
		_clipping_mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	return _clipping_mat

func _find_meshes_recursive(node: Node, result: Array):
	if node.name == "ArcCone" or node.name.begins_with("Gizmo3D"):
		return
	if node is MeshInstance3D:
		result.append(node)
	for child in node.get_children():
		_find_meshes_recursive(child, result)

func _update_module_placement(module: Node3D, world_pos: Vector3, normal: Vector3):
	if not module or not is_instance_valid(module): return

	var data = module.get_meta("module_data")
	var catalog_data = ModuleCatalog.get_module_data(data.type_id)
	var category = data.category

	var local_normal = hull.global_transform.basis.inverse() * normal
	var local_pos = _snap_local_to_grid(hull.to_local(world_pos), local_normal, 0.25)

	var hull_type_for_mount = hull.get_meta("type_id", "") if hull else ""
	var mount_style = ""
	var wall_mount = false
	var sponson = false
	if category == "weapon":
		mount_style = ModuleCatalog.get_mount_style(data.type_id, hull_type_for_mount)
		wall_mount = _is_wall_mount(category, mount_style, data.type_id, local_normal)
		sponson = wall_mount and ModuleCatalog.is_sponson_capable(data.type_id)
		module.set_meta("mount_style", mount_style)
		module.set_meta("mount_normal", normal)
		# Weapons get a facet now too, not just armor. auto_weapon.gd reads
		# this and has always received "" - it is what lets combat and the
		# Design Lab arc agree on a sponson's narrowed traverse.
		module.set_meta("facet", ModuleCatalog.classify_facet(local_normal))
		# Must be set BEFORE rebuild_visual() below, which is what builds the
		# blister off this meta.
		module.set_meta("sponson", sponson)

	# Non-weapons used to get an extra `normal * size.y / 2` push-off here,
	# which _place_weapon() never applies. Module meshes are built with their
	# base at local Y=0 (build_visual() offsets the mesh up by half its height
	# so the BOTTOM lands on the origin), so the origin belongs exactly on the
	# surface - that extra half-height left every non-weapon module hovering
	# off the hull the moment it was dragged, at a different height than where
	# it was originally dropped.
	#
	# Position and basis both come from _mount_transform() now: a sponson
	# weapon is pushed INBOARD of the clicked point, so the two cannot be
	# decided separately. Assigning .origin and .basis rather than the whole
	# Transform3D, because the whole-transform form would drop node scale that
	# the armor fit re-applies afterwards.
	var mount_xf := _mount_transform(local_pos, local_normal, data.type_id, wall_mount, sponson,
		module.get_meta("sponson_embed", -1.0))
	module.position = _apply_armor_lift(module, mount_xf.origin, local_normal)
	module.transform.basis = mount_xf.basis

	var yaw_offset = module.get_meta("yaw_offset", 0.0)
	module.rotate_object_local(Vector3.UP, yaw_offset)

	# Vertical flip for bottom facets: a 180° rotation about the module's local Z
	# (which is perpendicular to the surface normal, pointing INTO the surface).
	# On the belly of a helicopter, this makes a missile pod face the correct
	# direction instead of upside-down / backward relative to the hull. Applied
	# as a basis modification in module-local space so it composes correctly
	# with yaw, mirroring, and the mount orientation.
	if local_normal.y < -0.7:
		module.transform.basis = module.transform.basis * Basis(Vector3.UP, PI)

	if category == "weapon":
		VisualBuilderScript.rebuild_visual(module)
		if module.get_meta("is_mirror", false):
			_apply_mirror_flip(module)
		
	if module.has_meta("mirrored_counterpart"):
		var mirror = module.get_meta("mirrored_counterpart")
		if mirror and is_instance_valid(mirror):
			var mirrored_local_pos = Vector3(-local_pos.x, local_pos.y, local_pos.z)
			var mirrored_normal = Vector3(-normal.x, normal.y, normal.z)
			var local_mirrored_normal = hull.global_transform.basis.inverse() * mirrored_normal
			# Classified independently rather than copying the primary's flag:
			# mirroring is X-only, so outboard.x negates while outboard.z
			# survives, and a right-side sponson becomes a genuine left-side
			# one aiming outboard-left. Note this branch takes the RAW mirrored
			# surface point - _mount_transform() applies the embed offset, and
			# passing the primary's already-offset position would put the twin
			# at the wrong depth.
			var mirror_wall = _is_wall_mount(category, mount_style, data.type_id,
				local_mirrored_normal)
			var mirror_sponson = mirror_wall and ModuleCatalog.is_sponson_capable(data.type_id)
			if category == "weapon":
				mirror.set_meta("mount_style", mount_style)
				mirror.set_meta("mount_normal", mirrored_normal)
				mirror.set_meta("facet", ModuleCatalog.classify_facet(local_mirrored_normal))
				mirror.set_meta("sponson", mirror_sponson)

			var mirror_xf := _mount_transform(mirrored_local_pos, local_mirrored_normal,
				data.type_id, mirror_wall, mirror_sponson,
				mirror.get_meta("sponson_embed", -1.0))
			mirror.position = mirror_xf.origin
			mirror.transform.basis = mirror_xf.basis

			mirror.rotate_object_local(Vector3.UP, -yaw_offset)
			if local_mirrored_normal.y < -0.7:
				mirror.transform.basis = mirror.transform.basis * Basis(Vector3.UP, PI)
			if category == "weapon":
				VisualBuilderScript.rebuild_visual(mirror)
			_apply_mirror_flip(mirror)

# Non-static wrapper around the static _mount_transform, so drag_drop_manager.gd
# can call it via root.ghost_mount_transform() without needing to preload the script.
func ghost_mount_transform(local_pos: Vector3, local_normal: Vector3, type_id: String) -> Transform3D:
	return _mount_transform(local_pos, local_normal, type_id, false, false)

# Re-runs the same facet/mount classification _place_weapon() does at initial placement.
func _reclassify_module_after_drag(module: Node3D, normal: Vector3, is_mirror: bool = false):
	if not module or not is_instance_valid(module) or not module.has_meta("module_data"):
		return
	var data = module.get_meta("module_data")
	var category = data.category
	if category != "armor" and category != "weapon":
		return
	if not hull:
		return
	var catalog_data = ModuleCatalog.get_module_data(data.type_id)

	# collider's box is the fitted AABB; the reference constant is the
	# "no hull loaded" safety net.
	var hull_size: Vector3 = Vector3(ModuleCatalog.REFERENCE_HULL_SIZE)
	var hull_shape = hull.get_node_or_null("CollisionShape3D")
	if hull_shape and hull_shape.shape is BoxShape3D:
		hull_size = hull_shape.shape.size
	var local_normal = hull.global_transform.basis.inverse() * normal
	if category == "armor":
		var facet_meas = _measure_hull_facet(hull, module.position, local_normal, module.transform.basis)
		var target_x = 1.0
		var target_z = 1.0
		var armor_pos = module.position

		if facet_meas["valid"]:
			target_x = facet_meas["size"].x
			target_z = facet_meas["size"].z
			armor_pos = facet_meas["center"]
			# Same facet-derived orientation as the initial-placement path, so a
			# plate dragged onto a face lands identically to one dropped there.
			if facet_meas.has("basis"):
				module.transform.basis = facet_meas["basis"]
		else:
			var hull_x = module.transform.basis.x.abs()
			var hull_z = module.transform.basis.z.abs()
			if hull_x.x > 0.5: target_x = hull_size.x
			elif hull_x.y > 0.5: target_x = hull_size.y
			elif hull_x.z > 0.5: target_x = hull_size.z

			if hull_z.x > 0.5: target_z = hull_size.x
			elif hull_z.y > 0.5: target_z = hull_size.y
			elif hull_z.z > 0.5: target_z = hull_size.z

			var armor_facet_fb = ModuleCatalog.classify_facet(local_normal)
			match armor_facet_fb:
				"left", "right":
					var x_off = sign(local_normal.x) * hull_size.x / 2.0 if hull_shape else armor_pos.x
					armor_pos = Vector3(x_off, 0, 0)
				"front", "back":
					var z_off = sign(local_normal.z) * hull_size.z / 2.0 if hull_shape else armor_pos.z
					armor_pos = Vector3(0, 0, z_off)
				_:
					var y_off = sign(local_normal.y) * hull_size.y / 2.0 if hull_shape else armor_pos.y
					armor_pos = Vector3(0, y_off, 0)

		module.scale.x = target_x / catalog_data.get("size", Vector3.ONE).x
		module.scale.z = target_z / catalog_data.get("size", Vector3.ONE).z
		module.position = armor_pos

		var mod_data = module.get_meta("module_data", null) as ModuleData
		if mod_data:
			mod_data.scale_multiplier = Vector3(module.scale.x, 1.0, module.scale.z)

		module.set_meta("facet", ModuleCatalog.classify_facet(local_normal))
		# SHAPE CONFORM. Mirrors the same swap _place_weapon does at initial
		# placement: the BoxMesh the visual-builder fallback created is the
		# old "rectangle stretched to the bounding box" approximation, and
		# for any facet with a measurable outline it is replaced with a
		# polygonal plate whose outline is the convex hull. The auto-scale
		# above is then wrong (the new mesh is already at the right extent),
		# so scale and scale_multiplier are reset to (1,1,1).
		if facet_meas.get("valid", false):
			if apply_facet_plate(module, facet_meas, data.type_id,
					catalog_data.get("size", Vector3.ONE), hull):
				module.scale = Vector3.ONE
				if mod_data:
					mod_data.scale_multiplier = Vector3.ONE
				# Same reasoning as the initial-placement path: the plate now
				# carries its own extent, so the click box has to be re-fitted
				# against it or a dragged plate keeps a catalog-sized target.
				_refit_module_collider(module)

	elif data.type_id == "resource_harvester":
		var facet_meas = _measure_hull_facet(hull, module.position, local_normal, module.transform.basis)
		var target_x = 1.0
		var target_z = 1.0
		var harvester_pos = module.position

		if facet_meas["valid"]:
			target_x = facet_meas["size"].x
			target_z = facet_meas["size"].z
			harvester_pos = facet_meas["center"]
		else:
			target_x = hull_size.x
			target_z = hull_size.y
			harvester_pos = Vector3(0, 0, -hull_size.z / 2.0)

		module.position = harvester_pos
		module.set_meta("facet_size", Vector2(target_x, target_z))
		module.set_meta("facet", "front")

		VisualBuilderScript.rebuild_visual(module)
		_refit_module_collider(module)

	elif category == "weapon":
		var hull_type_for_mount = hull.get_meta("type_id", "") if hull else ""
		var mount_style = ModuleCatalog.get_mount_style(data.type_id, hull_type_for_mount)
		module.set_meta("mount_style", mount_style)
		module.set_meta("mount_normal", normal)
		module.set_meta("facet", ModuleCatalog.classify_facet(local_normal))
		# Recomputed, and set BEFORE rebuild_visual() below - a weapon dragged
		# from the deck onto a wall has to grow a blister here, and one dragged
		# the other way has to lose it. rebuild_visual() reads this meta.
		module.set_meta("sponson",
			_is_sponson_mount(category, mount_style, data.type_id, local_normal))
		# Position/rotation are already mounted to the new facet by the last
		# _update_module_placement() call during the drag - this just finalizes
		# the classification and rebuilds the visual for the new facet's mesh
		# (e.g. tweak deformations, and the blister).
		VisualBuilderScript.rebuild_visual(module)
		# AFTER the rebuild, so the collider is fitted to the geometry the
		# module actually has now - with a blister if it just landed on a wall,
		# without one if it just left. Otherwise a weapon dragged onto a facet
		# becomes unclickable, which is the same bug initial placement has.
		_refit_module_collider(module)
		if module.get_meta("is_mirror", false):
			_apply_mirror_flip(module)

	if not is_mirror and module.has_meta("mirrored_counterpart"):
		var mirror = module.get_meta("mirrored_counterpart")
		if mirror and is_instance_valid(mirror):
			var mirrored_normal = Vector3(-normal.x, normal.y, normal.z)
			_reclassify_module_after_drag(mirror, mirrored_normal, true)

func _get_colliders_recursive(node: Node, list: Array):
	if node is CollisionObject3D:
		list.append(node.get_rid())
	for child in node.get_children():
		_get_colliders_recursive(child, list)

# Mirrors a module's visuals across the module's own YZ plane, so a left-side
# instance is the true reflection of the right-side one rather than a second
# copy of it. Applied to the module's DIRECT visual children (nested geometry
# inherits it) - never to the module node's own scale, which would put a
# negative factor into collision shapes and into module_data.scale_multiplier,
# where the stat maths reads it.
#
# Rewritten 2026-07-21. The old version walked the whole subtree flipping each
# MeshInstance3D's LOCAL scale.z, which only mirrors across module-X for a
# mesh that happens to carry the authored parts' 90-degree yaw offset - the
# procedural-fallback meshes have no such offset, so it mirrored them along
# the wrong axis. Reflecting the child's whole transform in module space is
# correct whatever orientation the child is in.
#
# The "_mirrored" marker keeps this idempotent: a reflection is its own
# inverse, so calling it twice on the same node would silently undo it, and
# it IS called repeatedly - once per mouse-motion frame while dragging a
# mirrored module. rebuild_visual() destroys and recreates these children, so
# fresh geometry is correctly unmarked and gets mirrored again.
# The reflection itself, and the cull-mode compensation it requires, now live
# in ModuleMirror - blueprint_manager.gd's reconstruct path needs the exact
# same behaviour, and when these were two separate copies that copy silently
# lost the compensation.
func _apply_mirror_flip(module: Node3D):
	if not module or not is_instance_valid(module): return
	if not module.get_meta("scale_flip_x", false): return
	ModuleMirrorScript.apply(module)

# --- First-Time Instructions Modal & Persistent Help ---
var instructions_canvas_layer: CanvasLayer = null

# On a first visit the player is now OFFERED THE TUTORIAL rather than shown the
# manual. The manual is not gone - it can be opened from the toolbar, and it
# works better as a reference you reach for than as a wall of text that greets
# you before you have seen the thing it describes.
#
# TutorialManager owns the "have they been offered this" flag, so there is one
# first-run gate rather than two that can disagree. It no-ops when a run is
# already active, which is the case when the player arrived here by pressing
# TUTORIAL on the main menu.
func _check_first_time_instructions() -> void:
	var tutorial = get_node_or_null("/root/TutorialManager")
	if tutorial == null:
		return
	tutorial.offer_first_run()

func show_instructions_dialog(is_manual_reopen: bool = false) -> void:
	if is_instance_valid(instructions_canvas_layer):
		instructions_canvas_layer.queue_free()

	instructions_canvas_layer = CanvasLayer.new()
	instructions_canvas_layer.name = "InstructionsModalLayer"
	instructions_canvas_layer.layer = 100
	add_child(instructions_canvas_layer)

	var scrim = ColorRect.new()
	scrim.name = "Scrim"
	scrim.set_anchors_preset(Control.PRESET_FULL_RECT)
	scrim.color = Color(0.04, 0.04, 0.04, 0.78)
	instructions_canvas_layer.add_child(scrim)

	var center = CenterContainer.new()
	center.set_anchors_preset(Control.PRESET_FULL_RECT)
	scrim.add_child(center)

	var panel = PanelContainer.new()
	panel.custom_minimum_size = Vector2(760, 520)

	var panel_style = StyleBoxFlat.new()
	panel_style.bg_color = UITokens.BASE_800
	panel_style.border_width_left = 2
	panel_style.border_width_top = 2
	panel_style.border_width_right = 2
	panel_style.border_width_bottom = 2
	panel_style.border_color = UITokens.SIGNAL_HAZARD
	panel_style.set_corner_radius_all(8)
	panel_style.content_margin_left = 28
	panel_style.content_margin_top = 24
	panel_style.content_margin_right = 28
	panel_style.content_margin_bottom = 24
	panel.add_theme_stylebox_override("panel", panel_style)
	center.add_child(panel)

	var vbox = VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 16)
	panel.add_child(vbox)

	var title_lbl = Label.new()
	title_lbl.text = "DESIGN LAB MANUAL & CONTROLS"
	title_lbl.add_theme_font_size_override("font_size", 22)
	title_lbl.add_theme_color_override("font_color", UITokens.SIGNAL_HAZARD)
	title_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vbox.add_child(title_lbl)

	var sub_lbl = Label.new()
	sub_lbl.text = "Quick-start reference for constructing, customizing, and testing vehicles."
	sub_lbl.add_theme_font_size_override("font_size", 13)
	sub_lbl.add_theme_color_override("font_color", UITokens.TEXT_SECONDARY)
	sub_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vbox.add_child(sub_lbl)

	var div = ColorRect.new()
	div.custom_minimum_size = Vector2(0, 1)
	div.color = UITokens.BASE_500
	vbox.add_child(div)

	var grid = HBoxContainer.new()
	grid.add_theme_constant_override("separation", 24)
	grid.size_flags_vertical = Control.SIZE_EXPAND_FILL
	vbox.add_child(grid)

	var col1 = VBoxContainer.new()
	col1.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	col1.add_theme_constant_override("separation", 12)
	grid.add_child(col1)

	_add_section_header(col1, "🎥 CAMERA & NAVIGATION")
	_add_bullet_item(col1, "Right Mouse (RMB)", "Hold & drag to orbit camera around vehicle")
	_add_bullet_item(col1, "Middle Mouse / Shift+RMB", "Hold & drag to pan camera view")
	_add_bullet_item(col1, "Scroll Wheel", "Zoom in & out on your vehicle")
	_add_bullet_item(col1, "Focus Key (F)", "Focus camera on selected part or hull")

	_add_section_header(col1, "🧱 BUILDING & ATTACHING")
	_add_bullet_item(col1, "Drag & Drop Parts", "Drag components from left menu onto hull facets")
	_add_bullet_item(col1, "Facet Auto-Snapping", "Modules & armor automatically align to hull faces")
	_add_bullet_item(col1, "Mirror Mode (M)", "Toggle symmetry to mirror parts on opposite side")

	var col2 = VBoxContainer.new()
	col2.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	col2.add_theme_constant_override("separation", 12)
	grid.add_child(col2)

	_add_section_header(col2, "🔄 MANIPULATION & EDITING")
	_add_bullet_item(col2, "Select Part", "Click any attached module to highlight & edit")
	_add_bullet_item(col2, "Rotate Part", "Drag 3D gizmo rings or press R / E / Q")
	_add_bullet_item(col2, "Remove Part", "Press Delete / Backspace or click Delete Part")

	_add_section_header(col2, "⚡ STATS & FIELD TESTING")
	_add_bullet_item(col2, "Live Vehicle Stats", "Monitor DPS, Armor, HP, Mass & Speed on right panel")
	_add_bullet_item(col2, "Test Range / Combat", "Click Test Range to test-drive & fight in combat")

	var div2 = ColorRect.new()
	div2.custom_minimum_size = Vector2(0, 1)
	div2.color = UITokens.BASE_500
	vbox.add_child(div2)

	var btn_center = CenterContainer.new()
	vbox.add_child(btn_center)

	var close_btn = Button.new()
	close_btn.text = "GOT IT! START BUILDING"
	close_btn.custom_minimum_size = Vector2(260, 44)

	var btn_style = StyleBoxFlat.new()
	btn_style.bg_color = UITokens.SIGNAL_GO
	btn_style.set_corner_radius_all(6)

	var btn_hover = StyleBoxFlat.new()
	btn_hover.bg_color = UITokens.SIGNAL_GO.lightened(0.15)
	btn_hover.set_corner_radius_all(6)

	close_btn.add_theme_stylebox_override("normal", btn_style)
	close_btn.add_theme_stylebox_override("hover", btn_hover)
	close_btn.add_theme_font_size_override("font_size", 15)
	close_btn.add_theme_color_override("font_color", Color.WHITE)

	close_btn.pressed.connect(func():
		var f = FileAccess.open("user://lab_instructions_seen.cfg", FileAccess.WRITE)
		if f:
			f.store_line("seen=true")
			f.close()
		instructions_canvas_layer.queue_free()
		instructions_canvas_layer = null
	)
	btn_center.add_child(close_btn)

func _add_section_header(parent: Control, title: String) -> void:
	var lbl = Label.new()
	lbl.text = title
	lbl.add_theme_font_size_override("font_size", 14)
	lbl.add_theme_color_override("font_color", UITokens.SIGNAL_HAZARD)
	parent.add_child(lbl)

func _add_bullet_item(parent: Control, key_name: String, desc: String) -> void:
	var hbox = HBoxContainer.new()
	hbox.add_theme_constant_override("separation", 6)

	var k_lbl = Label.new()
	k_lbl.text = "• " + key_name + ":"
	k_lbl.add_theme_font_size_override("font_size", 12)
	k_lbl.add_theme_color_override("font_color", UITokens.TEXT_PRIMARY)
	hbox.add_child(k_lbl)

	var d_lbl = Label.new()
	d_lbl.text = desc
	d_lbl.add_theme_font_size_override("font_size", 12)
	d_lbl.add_theme_color_override("font_color", UITokens.TEXT_SECONDARY)
	d_lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	d_lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	hbox.add_child(d_lbl)

	parent.add_child(hbox)
