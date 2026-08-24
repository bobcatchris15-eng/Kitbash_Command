class_name TweakCalloutManager
extends RefCounted

const ModuleDataResource = preload("res://scripts/module_data.gd")
const ResourceCatalogScript = preload("res://scripts/battle/economy/resource_catalog.gd")
const ModuleActionRingScript = preload("res://scripts/ui/module_action_ring.gd")
const RadialDialScript = preload("res://scripts/ui/radial_dial.gd")
const RadialAmmoSelectorScript = preload("res://scripts/ui/radial_ammo_selector.gd")
const TweakStations = preload("res://scripts/ui/tweak_stations.gd")
const VisualBuilderScript = preload("res://scripts/visual_builder.gd")

var lab: Node
var _action_ring: ModuleActionRing = null

func _init(p_lab: Node):
	lab = p_lab

# --- Live read-throughs to `lab`, NOT cached copies ---
var locomotion_tweaks:
	get: return lab.locomotion_tweaks
var size_container:
	get: return lab.size_container
var size_label:
	get: return lab.size_label
var size_slider:
	get: return lab.size_slider
var count_container:
	get: return lab.count_container
var count_slider:
	get: return lab.count_slider
var count_label:
	get: return lab.count_label
var tweak_canvas:
	get: return lab.tweak_canvas
var popup_name_label:
	get: return lab.popup_name_label
var popup_tweaks_container:
	get: return lab.popup_tweaks_container

var size_label_base := "Size"
var count_label_base := "Count"


func _open_action_ring(module: Node3D, designation: String) -> void:
	_close_action_ring()
	if tweak_canvas == null or module == null:
		return

	var ring = ModuleActionRingScript.new()
	ring.add_action("rotate", "Rotate", "", _module_can_rotate(module))
	ring.add_action("mirror", "Mirror")
	ring.add_action("arc", "Arc")
	ring.add_action("discard", "Discard")
	ring.action_invoked.connect(_on_ring_action)
	tweak_canvas.add_child(ring)
	ring.open_for_module(module, designation)
	_action_ring = ring


func _selected_gizmo() -> Node:
	if not is_instance_valid(lab.current_selected_module):
		return null
	return lab.current_selected_module.get_node_or_null("Gizmo3D")


func _module_can_rotate(module: Node3D) -> bool:
	if module == null or not module.has_meta("module_data"):
		return false
	var data = module.get_meta("module_data")
	var cat = data.get("category") if "category" in data else "module"
	return cat == "weapon" or cat == "module"


func _close_action_ring() -> void:
	if is_instance_valid(_action_ring):
		_action_ring.close()
	_action_ring = null


func _on_ring_action(action_id: String) -> void:
	match action_id:
		"rotate":
			var giz = _selected_gizmo()
			if giz and giz.has_method("set_rotate_mode"):
				giz.set_rotate_mode(true)
		"mirror":
			if lab.mirror_checkbox:
				lab.mirror_checkbox.button_pressed = not lab.mirror_checkbox.button_pressed
		"arc":
			var root = lab.get_node_or_null("/root/MainLab")
			if root and root.has_method("toggle_firing_arc"):
				root.toggle_firing_arc()
		"discard":
			lab.lab_toolbar._on_delete_pressed()


func _add_callout(module: Node3D, title: String, control: Control):
	if not tweak_canvas or not popup_tweaks_container or control == null:
		return
	if is_instance_valid(_action_ring):
		var angle := TweakStations.angle_for(title.to_lower().replace(" ", "_"))
		if angle < 0.0:
			angle = TweakStations.CLOCK_1
		_action_ring.add_tweak_station(title.to_lower(), title, control, angle)
		return
	if control.get_parent():
		control.reparent(tweak_canvas)
	var dir = lab._callout_dirs[lab._current_callout_idx % lab._callout_dirs.size()]
	var dist = 100.0 + (lab._current_callout_idx / lab._callout_dirs.size()) * 70.0
	var callout = load("res://scripts/tweak_callout.gd").new(title, control, dir, dist)
	callout.target_node = module
	callout.stash = popup_tweaks_container
	tweak_canvas.add_child(callout)
	lab._current_callout_idx += 1


func _persistent_tweak_widgets() -> Array:
	return [size_container, count_container, lab.wheels_per_axle_container,
		lab.blade_count_container, lab.blade_pitch_container, lab.helix_depth_container,
		lab.duct_container, lab.leg_type_container, lab.leg_width_container,
		popup_name_label, lab.popup_stats_label, lab.popup_rotate_btn]


func _clear_callouts():
	_close_action_ring()
	if tweak_canvas == null or popup_tweaks_container == null:
		return

	for w in _persistent_tweak_widgets():
		if w and is_instance_valid(w) and w.get_parent() != popup_tweaks_container:
			w.reparent(popup_tweaks_container)

	for child in tweak_canvas.get_children():
		if child is TweakCallout:
			child.queue_free()

	lab._current_callout_idx = 0


func on_module_selected(module: Node3D):
	if module and not is_instance_valid(module):
		module = null
	lab.current_selected_module = module

	_clear_callouts()

	size_container.visible = false
	count_container.visible = false
	lab.wheels_per_axle_container.visible = false
	lab.blade_count_container.visible = false
	lab.blade_pitch_container.visible = false
	lab.helix_depth_container.visible = false
	lab.duct_container.visible = false
	lab.leg_type_container.visible = false
	lab.leg_width_container.visible = false

	var root = lab.get_node_or_null("/root/MainLab")
	var hull = root.get_node_or_null("Hull") if root else null

	if hull and (module == null or module == hull or module.name == "Hull"):
		lab.sync_hull_ui(hull)
		if lab.has_method("update_inspector"):
			lab.update_inspector(null, null)

	if not locomotion_tweaks:
		return

	if not module or not module.has_meta("module_data"):
		if lab.has_method("update_inspector"):
			lab.update_inspector(null, null)
		return

	var data: ModuleDataResource = module.get_meta("module_data")
	if lab.has_method("update_inspector"):
		lab.update_inspector(module, data)

	_open_action_ring(module, data.module_name.to_upper())

	var hp := data.get_hp()
	var wt := data.get_weight()
	var cost := data.get_cost()
	var dps := data.get_dps()
	var heal := data.get_heal_rate()
	var last_line := "Heal Rate: %.1f/s" % heal if heal > 0.0 else "DPS: %.1f" % dps
	var mount_line := _mount_style_line(module.get_meta("mount_style", ""))
	var spec_text := "HP: %.1f | WT: %.1f kg | %d cr\n%s%s" % [hp, wt, ResourceCatalogScript.credits_from_materials(cost), last_line, mount_line]
	
	if is_instance_valid(_action_ring):
		_action_ring.set_spec_info(spec_text)

	if data.category != "locomotion":
		_generate_custom_tweaks(module, data)
		return

	_generate_locomotion_radial_tweaks(module, data)


func _generate_locomotion_radial_tweaks(module: Node3D, data: ModuleDataResource) -> void:
	var root = lab.get_node_or_null("/root/MainLab")
	var hull = root.get_node_or_null("Hull") if root else null
	if not hull or not is_instance_valid(_action_ring):
		return

	var type_id: String = data.type_id
	var settings: Dictionary = {}
	if hull.has_meta("locomotion_settings"):
		settings = hull.get_meta("locomotion_settings")

	lab.is_updating_sliders = true

	# 1. Primary Size Dial
	var size_key: String = LabDocument.LOCOMOTION_SIZE_KEY.get(type_id, "size")
	var size_val: float = settings.get(size_key, settings.get("size", 1.0))
	size_slider.value = size_val
	var size_dial = RadialDialScript.new(size_key, "Size", 0.5, 2.5, 0.05, 1.0)
	size_dial.value = size_val
	size_dial.drag_started.connect(lab._push_undo)
	size_dial.value_changed.connect(func(v: float):
		size_slider.value = v
		_on_size_value_changed(v)
	)
	var size_angle: float = TweakStations.angle_for(size_key)
	if size_angle < 0.0:
		size_angle = TweakStations.CLOCK_1
	_action_ring.add_tweak_station(size_key, "Size", size_dial, size_angle)

	# 2. Count Dial (if applicable)
	if type_id != "tracked_treads" and type_id != "screw_drive" and type_id != "ornithopter_wing":
		var count_key := "count"
		var count_min := 2.0
		var count_max := 8.0
		var count_step := 2.0
		var count_val := 4.0
		
		if type_id == "wheels":
			count_key = "num_axles"
			count_min = 4.0
			count_max = 8.0
			count_val = float(settings.get("num_axles", 4))
		elif type_id == "hover_engine":
			count_key = "pad_count"
			count_min = 4.0
			count_max = 8.0
			count_step = 1.0
			count_val = float(settings.get("pad_count", 4))
		elif type_id == "fixed_wing_engine":
			count_key = "engine_count"
			count_min = 2.0
			count_max = 6.0
			count_step = 1.0
			count_val = float(settings.get("engine_count", 2))
		elif type_id == "buoyant_envelope":
			count_key = "prop_count"
			count_min = 1.0
			count_max = 6.0
			count_step = 1.0
			count_val = float(settings.get("prop_count", 2))
		elif type_id == "half_track":
			count_key = "bogie_count"
			count_min = 2.0
			count_max = 5.0
			count_step = 1.0
			count_val = float(settings.get("bogie_count", 3))
		elif type_id == "rocker_bogie":
			count_key = "bogie_pairs"
			count_min = 2.0
			count_max = 5.0
			count_step = 1.0
			count_val = float(settings.get("bogie_pairs", 3))
		elif type_id == "air_cushion_skirt":
			count_key = "lift_fan_count"
			count_min = 2.0
			count_max = 6.0
			count_step = 1.0
			count_val = float(settings.get("lift_fan_count", 3))
		elif type_id == "anti_grav_plate":
			count_key = "plate_count"
			count_min = 3.0
			count_max = 8.0
			count_step = 1.0
			count_val = float(settings.get("plate_count", 4))
		elif type_id == "heavy_quad_tracks":
			count_key = "track_count"
			count_min = 4.0
			count_max = 6.0
			count_step = 2.0
			count_val = float(settings.get("track_count", 4))
		else:
			count_val = float(settings.get("count", 4))

		count_slider.value = count_val
		var count_dial = RadialDialScript.new(count_key, "Count", count_min, count_max, count_step, count_val)
		count_dial.value = count_val
		count_dial.drag_started.connect(_on_loco_drag_started)
		count_dial.value_changed.connect(func(v: float):
			count_slider.value = v
			_on_count_value_changed(v)
		)
		count_dial.drag_ended.connect(_on_loco_drag_ended)
		var count_angle: float = TweakStations.angle_for(count_key)
		if count_angle < 0.0:
			count_angle = TweakStations.CLOCK_11
		_action_ring.add_tweak_station(count_key, "Count", count_dial, count_angle)

	# 3. Secondary dials
	if type_id == "wheels":
		var dually_dial = RadialDialScript.new("wheels_per_axle", "Tires/Axle", 1.0, 2.0, 1.0, float(settings.get("wheels_per_axle", 1)))
		dually_dial.drag_started.connect(lab._push_undo)
		dually_dial.value_changed.connect(func(v: float):
			lab.wheels_per_axle_slider.value = v
			_on_wheels_per_axle_changed(v)
		)
		_action_ring.add_tweak_station("wheels_per_axle", "Tires/Axle", dually_dial, TweakStations.CLOCK_8)
	elif type_id == "helicopter_rotors":
		var blade_dial = RadialDialScript.new("blade_count", "Blades", 2.0, 6.0, 1.0, float(settings.get("blade_count", 4)))
		blade_dial.drag_started.connect(lab._push_undo)
		blade_dial.value_changed.connect(func(v: float):
			lab.blade_count_slider.value = v
			_on_blade_count_changed(v)
		)
		_action_ring.add_tweak_station("blade_count", "Blades", blade_dial, TweakStations.CLOCK_5)
	elif type_id == "buoyant_envelope":
		var pitch_dial = RadialDialScript.new("blade_pitch", "Pitch", 0.5, 2.0, 0.1, float(settings.get("blade_pitch", 1.0)))
		pitch_dial.drag_started.connect(lab._push_undo)
		pitch_dial.value_changed.connect(func(v: float):
			lab.blade_pitch_slider.value = v
			_on_blade_pitch_changed(v)
		)
		_action_ring.add_tweak_station("blade_pitch", "Pitch", pitch_dial, TweakStations.CLOCK_8)
	elif type_id == "screw_drive":
		var depth_dial = RadialDialScript.new("helix_depth", "Helix", 0.5, 2.0, 0.1, float(settings.get("helix_depth", 1.0)))
		depth_dial.drag_started.connect(lab._push_undo)
		depth_dial.value_changed.connect(func(v: float):
			lab.helix_depth_slider.value = v
			_on_helix_depth_changed(v)
		)
		_action_ring.add_tweak_station("helix_depth", "Helix", depth_dial, TweakStations.CLOCK_5)
	elif type_id == "legs":
		var width_dial = RadialDialScript.new("leg_width", "Width", 0.5, 2.0, 0.1, float(settings.get("leg_width", 1.0)))
		width_dial.drag_started.connect(lab._push_undo)
		width_dial.value_changed.connect(func(v: float):
			lab.leg_width_slider.value = v
			_on_leg_width_changed(v)
		)
		_action_ring.add_tweak_station("leg_width", "Width", width_dial, TweakStations.CLOCK_2)

		var leg_options: Array = ModuleCatalog.get_leg_options()
		var current_leg: String = ModuleCatalog.get_leg_type(settings)
		var leg_selector = RadialAmmoSelectorScript.new()
		leg_selector.set_options(leg_options, current_leg, ModuleCatalog, "LEG PROFILE")
		leg_selector.ammo_selected.connect(func(picked: String):
			_on_leg_picked(picked)
		)
		_action_ring.add_tweak_station(ModuleCatalog.LEG_TWEAK_KEY, "Leg Profile", leg_selector, TweakStations.CLOCK_12)

	if type_id == "helicopter_rotors":
		var duct_check = CheckBox.new()
		var duct_label := "Duct"
		duct_check.text = duct_label
		duct_check.button_pressed = bool(settings.get("duct", false))
		duct_check.toggled.connect(func(pressed: bool):
			lab.duct_checkbox.button_pressed = pressed
			_on_duct_toggled(pressed)
		)
		_action_ring.add_tweak_station("duct", duct_label, duct_check, TweakStations.CLOCK_7)

	lab.is_updating_sliders = false


func _refresh_locomotion_labels():
	size_label.text = "%s: %.2fx" % [size_label_base, size_slider.value]
	if lab.leg_width_container.visible:
		lab.leg_width_label.text = "Leg Width: %.2fx" % lab.leg_width_slider.value
	if count_container.visible:
		count_label.text = "%s: %d" % [count_label_base, int(count_slider.value)]
	if lab.wheels_per_axle_container.visible:
		var dually = int(lab.wheels_per_axle_slider.value) >= 2
		lab.wheels_per_axle_label.text = "Wheels Per Axle: %d%s" % [int(lab.wheels_per_axle_slider.value), " (dually)" if dually else ""]
	if lab.blade_count_container.visible:
		lab.blade_count_label.text = "Blade Count: %d" % int(lab.blade_count_slider.value)
	if lab.blade_pitch_container.visible:
		lab.blade_pitch_label.text = "Blade Pitch: %.2fx" % lab.blade_pitch_slider.value
	if lab.helix_depth_container.visible:
		lab.helix_depth_label.text = "Helix Depth: %.2fx" % lab.helix_depth_slider.value


func _on_size_value_changed(value: float):
	_refresh_locomotion_labels()
	if lab.is_updating_sliders or not lab.current_selected_module or not is_instance_valid(lab.current_selected_module): return
	var root = lab.get_node_or_null("/root/MainLab")
	if not root or not root.has_method("update_locomotion_geometry_tweak"): return
	var data = lab.current_selected_module.get_meta("module_data")
	var type_id = data.type_id
	var key = LabDocument.LOCOMOTION_SIZE_KEY.get(type_id, "size")
	root.update_locomotion_geometry_tweak(type_id, key, value)
	if root.hull:
		lab.update_stats(root.hull)


func _on_count_value_changed(value: float):
	_refresh_locomotion_labels()
	if lab.is_updating_sliders or not lab.current_selected_module or lab._loco_slider_dragging: return
	_apply_tweaks()


func _on_wheels_per_axle_changed(value: float):
	_refresh_locomotion_labels()
	if lab.is_updating_sliders or not lab.current_selected_module or not is_instance_valid(lab.current_selected_module): return
	var root = lab.get_node_or_null("/root/MainLab")
	if not root or not root.has_method("update_locomotion_geometry_tweak"): return
	root.update_locomotion_geometry_tweak("wheels", "wheels_per_axle", int(value))
	if root.hull:
		lab.update_stats(root.hull)


func _on_blade_count_changed(value: float):
	_refresh_locomotion_labels()
	if lab.is_updating_sliders or not lab.current_selected_module or not is_instance_valid(lab.current_selected_module): return
	var root = lab.get_node_or_null("/root/MainLab")
	if not root or not root.has_method("update_locomotion_geometry_tweak"): return
	var data = lab.current_selected_module.get_meta("module_data")
	root.update_locomotion_geometry_tweak(data.type_id, "blade_count", int(value))
	if root.hull:
		lab.update_stats(root.hull)


func _on_blade_pitch_changed(value: float):
	_refresh_locomotion_labels()
	if lab.is_updating_sliders or not lab.current_selected_module or not is_instance_valid(lab.current_selected_module): return
	var root = lab.get_node_or_null("/root/MainLab")
	if not root or not root.has_method("update_locomotion_geometry_tweak"): return
	var data = lab.current_selected_module.get_meta("module_data")
	var key = LabDocument.LOCOMOTION_SECONDARY_SIZE_KEY.get(data.type_id, "blade_pitch")
	root.update_locomotion_geometry_tweak(data.type_id, key, value)
	if root.hull:
		lab.update_stats(root.hull)


func _on_helix_depth_changed(value: float):
	_refresh_locomotion_labels()
	if lab.is_updating_sliders or not lab.current_selected_module or not is_instance_valid(lab.current_selected_module): return
	var root = lab.get_node_or_null("/root/MainLab")
	if not root or not root.has_method("update_locomotion_geometry_tweak"): return
	var data = lab.current_selected_module.get_meta("module_data")
	root.update_locomotion_geometry_tweak(data.type_id, "helix_depth", value)
	if root.hull:
		lab.update_stats(root.hull)


func _on_leg_width_changed(value: float):
	_refresh_locomotion_labels()
	if lab.is_updating_sliders or not lab.current_selected_module or not is_instance_valid(lab.current_selected_module): return
	var root = lab.get_node_or_null("/root/MainLab")
	if not root or not root.has_method("update_locomotion_geometry_tweak"): return
	var data = lab.current_selected_module.get_meta("module_data")
	root.update_locomotion_geometry_tweak(data.type_id, "leg_width", value)
	if root.hull:
		lab.update_stats(root.hull)


func _on_duct_toggled(pressed: bool):
	if lab.is_updating_sliders or not lab.current_selected_module or not is_instance_valid(lab.current_selected_module): return
	lab._push_undo()
	var root = lab.get_node_or_null("/root/MainLab")
	if not root or not root.has_method("update_locomotion_geometry_tweak"): return
	var data = lab.current_selected_module.get_meta("module_data")
	root.update_locomotion_geometry_tweak(data.type_id, lab.bool_tweak_key, pressed)
	if root.hull:
		lab.update_stats(root.hull)


func _on_leg_picked(picked: String) -> void:
	if lab.is_updating_sliders or not lab.current_selected_module or not is_instance_valid(lab.current_selected_module):
		return
	var options: Array = ModuleCatalog.get_leg_options()
	if not options.has(picked):
		return
	lab._push_undo()
	if is_instance_valid(lab.leg_type_desc):
		lab.leg_type_desc.text = ModuleCatalog.get_leg_profile(picked).desc

	var root = lab.get_node_or_null("/root/MainLab")
	if not root or not root.has_method("update_locomotion"):
		return
	var settings: Dictionary = {}
	if root.hull and root.hull.has_meta("locomotion_settings"):
		settings = root.hull.get_meta("locomotion_settings").duplicate()
	settings[ModuleCatalog.LEG_TWEAK_KEY] = picked
	root.update_locomotion("legs", settings)
	lab.update_stats(root.hull)


func _on_leg_type_selected(index: int) -> void:
	if lab.is_updating_sliders or not lab.current_selected_module or not is_instance_valid(lab.current_selected_module):
		return
	var options: Array = ModuleCatalog.get_leg_options()
	if index < 0 or index >= options.size():
		return
	_on_leg_picked(options[index])


func _on_loco_drag_started():
	lab._loco_slider_dragging = true
	lab._push_undo()


func _on_loco_drag_ended(value_changed: bool):
	lab._loco_slider_dragging = false
	if lab.is_updating_sliders or not lab.current_selected_module: return
	if value_changed:
		_apply_tweaks()


func _apply_tweaks():
	var root = lab.get_node("/root/MainLab")
	var hull = root.get_node_or_null("Hull")
	if not root or not hull or not lab.current_selected_module: return
	
	var data = lab.current_selected_module.get_meta("module_data")
	var type_id = data.type_id
	var settings = {}
	
	if hull.has_meta("locomotion_settings"):
		settings = hull.get_meta("locomotion_settings").duplicate()
	
	if type_id == "wheels":
		settings["wheel_size"] = size_slider.value
		settings["num_axles"] = int(count_slider.value)
		settings["wheels_per_axle"] = int(lab.wheels_per_axle_slider.value)
	elif type_id == "tracked_treads":
		settings["tread_width"] = size_slider.value
	elif type_id == "helicopter_rotors":
		settings["size"] = size_slider.value
		settings["count"] = int(count_slider.value)
		settings["blade_count"] = int(lab.blade_count_slider.value)
		settings["duct"] = lab.duct_checkbox.button_pressed
	elif type_id == "legs":
		settings["leg_length"] = size_slider.value
		settings["count"] = int(count_slider.value)
		settings["leg_width"] = lab.leg_width_slider.value
	elif type_id == "hover_engine":
		settings["emv_level"] = size_slider.value
		settings["pad_count"] = int(count_slider.value)
	elif type_id == "fixed_wing_engine":
		settings["turbine_compression"] = size_slider.value
		settings["engine_count"] = int(count_slider.value)
	elif type_id == "buoyant_envelope":
		settings["prop_count"] = int(count_slider.value)
		settings["blade_count"] = int(lab.blade_count_slider.value)
		settings["blade_pitch"] = lab.blade_pitch_slider.value
	elif type_id == "screw_drive":
		settings["drum_diameter"] = size_slider.value
		settings["helix_depth"] = lab.helix_depth_slider.value
	elif type_id == "ornithopter_wing":
		settings["wingspan"] = size_slider.value
		settings["wing_sweep"] = lab.blade_pitch_slider.value
	elif type_id == "half_track":
		settings["tread_width"] = size_slider.value
		settings["front_axle_size"] = lab.blade_pitch_slider.value
		settings["bogie_count"] = int(count_slider.value)
	elif type_id == "rocker_bogie":
		settings["wheel_size"] = size_slider.value
		settings["arm_length"] = lab.blade_pitch_slider.value
		settings["bogie_pairs"] = int(count_slider.value)
	elif type_id == "air_cushion_skirt":
		settings["skirt_diameter"] = size_slider.value
		settings["plenum_pressure"] = lab.blade_pitch_slider.value
		settings["lift_fan_count"] = int(count_slider.value)
	elif type_id == "anti_grav_plate":
		settings["field_strength"] = size_slider.value
		settings["plate_count"] = int(count_slider.value)
	elif type_id == "heavy_quad_tracks":
		settings["tread_width"] = size_slider.value
		settings["track_count"] = int(count_slider.value)

	root.update_locomotion(type_id, settings)
	lab.update_stats(hull)


func _on_tweak_changed():
	if not lab.current_selected_module or not is_instance_valid(lab.current_selected_module): return
	var root = lab.get_node_or_null("/root/MainLab")
	var hull = root.get_node_or_null("Hull") if root else null
	if not root or not hull: return
	var module = lab.current_selected_module
	var data = module.get_meta("module_data")
	
	# 1. Rebuild the visual mesh of the module directly using VisualBuilder
	VisualBuilderScript.rebuild_visual(module)
	
	# 2. Refit module collider if root (module_placer) has the method
	if root.has_method("_refit_module_collider"):
		root._refit_module_collider(module)
	
	# 3. Mirror counterpart synchronization
	var mirror = null
	if module.has_meta("mirrored_counterpart"):
		mirror = module.get_meta("mirrored_counterpart")
	elif module.has_meta("mirror_partner"):
		mirror = module.get_meta("mirror_partner")
	
	if mirror and is_instance_valid(mirror) and mirror.has_meta("module_data"):
		var m_data = mirror.get_meta("module_data")
		m_data.tweaks = data.tweaks.duplicate()
		VisualBuilderScript.rebuild_visual(mirror)
		if root.has_method("_refit_module_collider"):
			root._refit_module_collider(mirror)
	
	# 4. Update stats in the telemetry rail
	lab.update_stats(hull)
	
	# 5. Update the spec placard text on the ring
	var hp = data.get_hp()
	var wt = data.get_weight()
	var cost = data.get_cost()
	var dps = data.get_dps()
	var heal = data.get_heal_rate()
	var last_line = "Heal Rate: %.1f/s" % heal if heal > 0.0 else "DPS: %.1f" % dps
	var mount_line = _mount_style_line(module.get_meta("mount_style", ""))
	var spec_text := "HP: %.1f | WT: %.1f kg | %d cr\n%s%s" % [hp, wt, ResourceCatalogScript.credits_from_materials(cost), last_line, mount_line]
	if is_instance_valid(_action_ring):
		_action_ring.set_spec_info(spec_text)


func _mount_style_line(style: String) -> String:
	var desc := ""
	match style:
		"turret": desc = "Turret mount (full traverse)"
		"frame_built": desc = "Frame-built (fixed - whole vehicle aims)"
		"pintle": desc = "Pintle mount (full traverse)"
	return "\n%s" % desc if desc != "" else ""


func _generate_custom_tweaks(module: Node3D, data: ModuleDataResource):
	var type_id = data.type_id
	if not is_instance_valid(_action_ring):
		return

	# 1. Ammo Selector at 12:00
	if ModuleCatalog.is_ammo_capable(type_id):
		var ammo_options = ModuleCatalog.get_ammo_options(type_id)
		var current_ammo = ModuleCatalog.get_ammo(type_id, data.tweaks)
		var ammo_selector = RadialAmmoSelectorScript.new()
		ammo_selector.set_options(ammo_options, current_ammo, ModuleCatalog)
		ammo_selector.ammo_selected.connect(func(picked: String):
			lab._push_undo()
			data.tweaks[ModuleCatalog.AMMO_TWEAK_KEY] = picked
			_on_tweak_changed()
		)
		_action_ring.add_tweak_station(ModuleCatalog.AMMO_TWEAK_KEY, "Ammo", ammo_selector, TweakStations.CLOCK_12)

	# drone_carrier's drone_type selector at 12:00 (sits above ammo if both exist).
	# Placed after the ammo branch so both can occupy CLOCK_12; the ring stacks them.
	if type_id == "drone_carrier":
		var drone_options = ModuleCatalog.get_drone_options()
		var current_drone = data.tweaks.get("drone_type", "attack")
		var drone_selector = RadialAmmoSelectorScript.new()
		drone_selector.set_options(drone_options, current_drone, ModuleCatalog, "DRONE PROFILE")
		drone_selector.ammo_selected.connect(func(picked: String):
			lab._push_undo()
			data.tweaks["drone_type"] = picked
			_on_tweak_changed()
		)
		_action_ring.add_tweak_station("drone_type", "Drone Type", drone_selector, TweakStations.CLOCK_12)

	if not LabDocument.TWEAK_SPECS.has(type_id):
		return

	# 2. Parametric Tweaks at fixed clock stations
	var specs = LabDocument.TWEAK_SPECS[type_id]
	for spec in specs:
		var spec_name: String = spec["name"]
		var spec_label: String = spec["label"]
		var angle: float = TweakStations.angle_for(spec_name)
		if angle < 0.0:
			angle = TweakStations.CLOCK_1

		if spec.get("type", "") == "bool":
			var check = CheckBox.new()
			check.button_pressed = data.tweaks.get(spec_name, spec.get("default", false))
			check.text = spec_label
			check.toggled.connect(func(pressed: bool):
				lab._push_undo()
				data.tweaks[spec_name] = pressed
				_on_tweak_changed()
			)
			_action_ring.add_tweak_station(spec_name, spec_label, check, angle)
		else:
			var min_v: float = spec.get("min", 0.5)
			var max_v: float = spec.get("max", 2.0)
			var step_v: float = spec.get("step", 0.1)
			var def_v: float = spec.get("default", 1.0)
			var cur_v: float = data.tweaks.get(spec_name, def_v)

			var dial = RadialDialScript.new(spec_name, spec_label, min_v, max_v, step_v, def_v)
			dial.value = cur_v
			dial.drag_started.connect(lab._push_undo)
			dial.value_changed.connect(func(val: float):
				data.tweaks[spec_name] = val
				_on_tweak_changed()
			)
			_action_ring.add_tweak_station(spec_name, spec_label, dial, angle)
