# probe_sensor_suites.gd
# Comprehensive test probe for simplified 3-tier sensor suites

@tool
extends SceneTree

const ModuleCatalog = preload("res://scripts/module_catalog.gd")
const ModuleData = preload("res://scripts/module_data.gd")
const VisualBuilder = preload("res://scripts/visual_builder.gd")
const VisionService = preload("res://scripts/battle/vision/vision_service.gd")

func _init() -> void:
	print("--- SIMPLIFIED SENSOR SUITES PROBE ---")
	var success := true
	var root = Node3D.new()
	get_root().add_child(root)

	# 1. Test Catalog Registration
	var sensor_ids := ["sensor_suite", "heavy_sensor_suite", "directional_radar"]
	for tid in sensor_ids:
		if not ModuleCatalog.module_exists(tid):
			print("FAIL: Module not found in catalog: ", tid)
			success = false
		else:
			var data = ModuleCatalog.get_module_data(tid)
			print("PASS: Found in catalog: ", tid, " (", data.get("name"), ")")

	# 2. Test Costs and Range Relationships
	var m1_data = ModuleCatalog.get_module_data("sensor_suite")
	var m2_data = ModuleCatalog.get_module_data("heavy_sensor_suite")
	var m3_data = ModuleCatalog.get_module_data("directional_radar")

	var m1_cost = m1_data.get("metal", 0) + m1_data.get("crystal", 0)
	var m2_cost = m2_data.get("metal", 0) + m2_data.get("crystal", 0)
	var m3_cost = m3_data.get("metal", 0) + m3_data.get("crystal", 0)

	print("Costs: Tier 1=", m1_cost, ", Tier 2=", m2_cost, ", Tier 3=", m3_cost)
	if m2_cost != m1_cost * 3:
		print("FAIL: Tier 2 cost is not 3x Tier 1 cost!")
		success = false
	else:
		print("PASS: Tier 2 cost is exactly 3x Tier 1 cost (", m1_cost, " -> ", m2_cost, ")")

	if m3_cost != m2_cost:
		print("FAIL: Tier 3 cost does not match Tier 2 cost!")
		success = false
	else:
		print("PASS: Tier 3 cost matches Tier 2 cost (", m3_cost, ")")

	# Standard Hull base vision = 20.0 * 2.28 = 45.6m
	var standard_base_vision = ModuleCatalog.get_base_vision("ballard_medium_a")
	print("Standard hull base vision: ", standard_base_vision, "m")

	# Tier 1 total range = 45.6 + 45.6 = 91.2m (Double base vision)
	var t1_total = standard_base_vision + m1_data.get("vision_bonus", 0.0)
	print("Tier 1 total vision range: ", t1_total, "m (approx 2x base vision)")
	if absf(t1_total - standard_base_vision * 2.0) > 1.0:
		print("FAIL: Tier 1 does not double hull base vision!")
		success = false
	else:
		print("PASS: Tier 1 doubles hull base vision (", standard_base_vision, " -> ", t1_total, "m)")

	# Tier 2 total range = 45.6 + 136.8 = 182.4m (Doubles Tier 1 range again: 2 * 91.2m)
	var t2_total = standard_base_vision + m2_data.get("vision_bonus", 0.0)
	print("Tier 2 total vision range: ", t2_total, "m (doubles Tier 1 range again)")
	if absf(t2_total - t1_total * 2.0) > 1.0:
		print("FAIL: Tier 2 does not double Tier 1 vision range again!")
		success = false
	else:
		print("PASS: Tier 2 doubles Tier 1 vision range again (", t1_total, " -> ", t2_total, "m)")

	# Tier 3 directional range
	var t3_total = standard_base_vision + m3_data.get("vision_bonus", 0.0)
	print("Tier 3 forward directional reach: ", t3_total, "m (extremely long range)")
	if t3_total < 300.0:
		print("FAIL: Tier 3 directional reach is not extremely long range!")
		success = false
	else:
		print("PASS: Tier 3 directional reach is extremely long range (", t3_total, "m)")

	# 3. Test ModuleData & Tweak Calculations for all 3 modules
	# Tier 1 tweaks
	var mod1 = ModuleData.new()
	mod1.type_id = "sensor_suite"
	mod1.base_vision_bonus = 45.6
	mod1.tweaks = {"mast_height": 1.0, "dish_aperture": 1.0, "whip_length": 1.0}
	var b1_base = mod1.get_vision_bonus()
	mod1.tweaks = {"mast_height": 1.5, "dish_aperture": 1.2, "whip_length": 1.3}
	var b1_tweaked = mod1.get_vision_bonus()
	if b1_tweaked <= b1_base:
		print("FAIL: Sensor suite tweaks failed to scale vision bonus!")
		success = false
	else:
		print("PASS: Sensor suite tweaks scaled vision bonus: ", b1_base, " -> ", b1_tweaked)

	# Tier 2 tweaks
	var mod2 = ModuleData.new()
	mod2.type_id = "heavy_sensor_suite"
	mod2.base_vision_bonus = 136.8
	mod2.tweaks = {"pylon_height": 1.0, "radome_scale": 1.0, "optics_aperture": 1.0}
	var b2_base = mod2.get_vision_bonus()
	mod2.tweaks = {"pylon_height": 1.4, "radome_scale": 1.2, "optics_aperture": 1.3}
	var b2_tweaked = mod2.get_vision_bonus()
	if b2_tweaked <= b2_base:
		print("FAIL: Heavy sensor suite tweaks failed to scale vision bonus!")
		success = false
	else:
		print("PASS: Heavy sensor suite tweaks scaled vision bonus: ", b2_base, " -> ", b2_tweaked)

	# Tier 3 tweaks
	var mod3 = ModuleData.new()
	mod3.type_id = "directional_radar"
	mod3.base_vision_bonus = 276.0
	mod3.tweaks = {"scan_arc": 60.0, "mast_height": 1.0, "array_gain": 1.0}
	var b3_base = mod3.get_vision_bonus()
	mod3.tweaks = {"scan_arc": 40.0, "mast_height": 1.2, "array_gain": 1.2}
	var b3_tweaked = mod3.get_vision_bonus()
	if b3_tweaked <= b3_base:
		print("FAIL: Directional radar narrow scan_arc and gain failed to scale bonus!")
		success = false
	else:
		print("PASS: Directional radar narrow focusing & gain scaled vision bonus: ", b3_base, " -> ", b3_tweaked)

	# 4. Test Visual Builder Assembly with new authored meshes
	var dummy_parent = Node3D.new()
	root.add_child(dummy_parent)
	for tid in sensor_ids:
		var node = Node3D.new()
		dummy_parent.add_child(node)
		VisualBuilder.build_visual(tid, node, Vector3.ONE, Color.WHITE, {
			"mast_height": 1.4, "dish_aperture": 1.3, "whip_length": 1.2,
			"pylon_height": 1.4, "radome_scale": 1.2, "optics_aperture": 1.3,
			"scan_arc": 50.0, "array_gain": 1.2
		})
		var count = node.get_child_count()
		if count == 1 and node.get_child(0).name == "ModularScaleWrapper":
			count = node.get_child(0).get_child_count()
		if count < 3:
			print("FAIL: Visual builder assembled too few parts for ", tid, " (", count, ")")
			success = false
		else:
			print("PASS: Visual builder assembled ", tid, " with ", count, " multi-part meshes.")
		node.queue_free()

	# 5. Test VisionService Simulator Behaviors
	var vs = VisionService.new()
	vs.setup(root, 0, 100.0, 1.0)

	# Directional Radar Viewer facing -Z (North)
	var dir_viewer = Node3D.new()
	root.add_child(dir_viewer)
	dir_viewer.position = Vector3.ZERO
	dir_viewer.set_meta("team", 0)
	dir_viewer.set_meta("vision_range", 45.6)
	dir_viewer.set_meta("directional_sensors", [{
		"range": 321.6,
		"arc_deg": 60.0,
		"arc_rad": deg_to_rad(60.0)
	}])

	# Target directly ahead at 200m (inside 60 deg cone)
	var target_front = Node3D.new()
	root.add_child(target_front)
	target_front.position = Vector3(0, 0, -200)
	target_front.set_meta("team", 1)

	# Target directly behind at 100m (outside cone and past 45.6m base vision)
	var target_behind = Node3D.new()
	root.add_child(target_behind)
	target_behind.position = Vector3(0, 0, 100)
	target_behind.set_meta("team", 1)

	var dir_profiles = vs._viewer_profiles([dir_viewer])
	var spotted_front = vs._is_spotted(target_front, dir_profiles, [], false)
	var spotted_behind = vs._is_spotted(target_behind, dir_profiles, [], false)

	if not spotted_front:
		print("FAIL: Directional radar failed to spot long-range target inside forward sector at 200m!")
		success = false
	else:
		print("PASS: Directional radar spotted long-range target inside forward sector at 200m.")

	if spotted_behind:
		print("FAIL: Directional radar erroneously spotted target behind it at 100m!")
		success = false
	else:
		print("PASS: Directional radar correctly ignored target outside sector cone (behind).")

	# Heavy Omni Sensor Viewer
	var heavy_viewer = Node3D.new()
	root.add_child(heavy_viewer)
	heavy_viewer.position = Vector3.ZERO
	heavy_viewer.set_meta("team", 0)
	heavy_viewer.set_meta("vision_range", 182.4)

	var target_omni_far = Node3D.new()
	root.add_child(target_omni_far)
	target_omni_far.position = Vector3(0, 0, 130.0)
	target_omni_far.set_meta("team", 1)

	var heavy_profiles = vs._viewer_profiles([heavy_viewer])
	var spotted_omni = vs._is_spotted(target_omni_far, heavy_profiles, [], false)
	if not spotted_omni:
		print("FAIL: Heavy omni sensor array failed to spot 360-deg target at 130m!")
		success = false
	else:
		print("PASS: Heavy omni sensor array spotted 360-deg target at 130m.")

	# Clean up
	root.queue_free()

	if success:
		print(">>> ALL SIMPLIFIED SENSOR SUITE VERIFICATION TESTS COMPLETED SUCCESSFULLY! <<<")
	else:
		print(">>> SOME SENSOR SUITE TESTS FAILED! <<<")
	quit(0 if success else 1)
