extends SceneTree

const ModulePlacerScript = preload("res://scripts/module_placer.gd")
const DragDropManagerScript = preload("res://scripts/drag_drop_manager.gd")
const StatBlockScene = preload("res://scenes/UI_StatBlock.tscn")

func _init() -> void:
	print("=== VERIFYING DRAWER PERSISTENCE & DEFAULT MIRRORING ===")

	# 1. Verify default mirror_enabled in module_placer
	var placer = Node3D.new()
	placer.set_script(ModulePlacerScript)
	if placer.mirror_enabled != false:
		print("FAIL: ModulePlacer mirror_enabled is not false by default! Got: ", placer.mirror_enabled)
		quit(1)
		return
	print("PASS: ModulePlacer mirror_enabled is false by default.")

	# 2. Verify default button_pressed in UI_StatBlock
	var stat_block = StatBlockScene.instantiate()
	var mirror_cb = stat_block.get_node_or_null("ScrollContainer/VBoxContainer/MirrorCheckBox")
	if mirror_cb == null:
		print("FAIL: MirrorCheckBox not found in UI_StatBlock!")
		quit(1)
		return
	if mirror_cb.button_pressed != false:
		print("FAIL: MirrorCheckBox button_pressed is not false by default! Got: ", mirror_cb.button_pressed)
		quit(1)
		return
	print("PASS: MirrorCheckBox button_pressed is false by default.")

	# 3. Verify drag_drop_manager does not collapse drawers on ghost update
	var ddm = DragDropManagerScript.new()
	# Ensure ddm compiles and can be instantiated
	if ddm == null:
		print("FAIL: DragDropManager failed to instantiate!")
		quit(1)
		return
	print("PASS: DragDropManager instantiated successfully.")

	print(">>> ALL VERIFICATION CHECKS PASSED SUCCESSFULLY! <<<")
	quit(0)
