# probe_repair_array.gd
# Verification probe for the redesigned folded factory robot arm repair array

@tool
extends SceneTree

const ModuleCatalog = preload("res://scripts/module_catalog.gd")
const ModuleData = preload("res://scripts/module_data.gd")
const VisualBuilder = preload("res://scripts/visual_builder.gd")

func _init() -> void:
	print("=== PROBING REDESIGNED REPAIR WELDER ARRAY ===")
	var success := true
	var root = Node3D.new()
	get_root().add_child(root)

	# 1. Verify Catalog Registration
	if not ModuleCatalog.module_exists("repair_array"):
		print("FAIL: repair_array not found in catalog!")
		success = false
	else:
		var data = ModuleCatalog.get_module_data("repair_array")
		var role = ModuleCatalog.get_module_role("repair_array")
		print("PASS: repair_array registered (Role: ", role, ", Heal Rate: ", data.get("heal_rate"), ")")

	# 2. Verify GLB Assets Exist and Load
	var mount_res = load("res://assets/models/parts/repair_array_mount.glb")
	var arm_res = load("res://assets/models/parts/repair_array_arm.glb")
	var welder_res = load("res://assets/models/parts/repair_array_welder.glb")

	if mount_res == null or arm_res == null or welder_res == null:
		print("FAIL: One or more repair array GLBs failed to load! mount=", mount_res != null, " arm=", arm_res != null, " welder=", welder_res != null)
		success = false
	else:
		print("PASS: All 3 repair array GLB meshes loaded successfully.")

	# 3. Test Visual Assembly & Arm Dimensions
	var parent_node = Node3D.new()
	root.add_child(parent_node)

	VisualBuilder.build_visual("repair_array", parent_node, Vector3.ONE, Color(0.2, 0.6, 0.8), {
		"welder_count": 2.0,
		"arm_reach": 1.0
	})

	var visual_root = parent_node
	if parent_node.get_child_count() == 1 and parent_node.get_child(0).name == "ModularScaleWrapper":
		visual_root = parent_node.get_child(0)

	var child_count = visual_root.get_child_count()
	print("Visual assembly child count: ", child_count, " (1 mount + 2 arms + 2 welders)")
	if child_count < 5:
		print("FAIL: Expected 5 child nodes for 2-arm repair array (found: ", child_count, ")")
		success = false
	else:
		print("PASS: Successfully assembled multi-arm repair welder array.")

	# Test 4-arm assembly with max reach
	var parent_node_4 = Node3D.new()
	root.add_child(parent_node_4)
	VisualBuilder.build_visual("repair_array", parent_node_4, Vector3.ONE, Color(0.2, 0.6, 0.8), {
		"welder_count": 4.0,
		"arm_reach": 1.5
	})
	var visual_root_4 = parent_node_4
	if parent_node_4.get_child_count() == 1 and parent_node_4.get_child(0).name == "ModularScaleWrapper":
		visual_root_4 = parent_node_4.get_child(0)

	if visual_root_4.get_child_count() < 9:
		print("FAIL: Expected 9 child nodes for 4-arm repair array (found: ", visual_root_4.get_child_count(), ")")
		success = false
	else:
		print("PASS: Successfully assembled 4-arm repair array configuration.")

	root.queue_free()

	if success:
		print(">>> ALL REPAIR ARRAY REDESIGN TESTS PASSED! <<<")
	else:
		print(">>> SOME TESTS FAILED! <<<")
	quit(0 if success else 1)
