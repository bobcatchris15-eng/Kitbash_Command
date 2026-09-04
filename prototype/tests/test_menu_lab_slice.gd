extends SceneTree
const UITheme = preload("res://scripts/ui_theme.gd")
# Task 4 regression runner. Supported validation: run this script headless.
# 2026-09-04: 46 checks passed, exit 0; headless editor/import also exited 0.
# Dummy renderer logs null-material errors during hull teardown/undo/redo;
# exit also reports 3 ObjectDB instances and 1 resource still in use.
# Rendered capture remains unvalidated: the following prior command crashed
# with exit -1073740791 (0xC0000409), before the selected-module capture:
# & C:/Misc/Kitbash_Command/Godot_v4.7.1-stable_win64_console.exe --path prototype --script res://tests/test_menu_lab_slice.gd -- --capture-dir C:/Misc/Kitbash_Command/.worktrees/industrial-design-ui-rebuild/playtest/task4
# It was not rerun after the user's instruction to use headless validation.
# The optional capture path is retained for future renderer diagnosis; passing
# headless checks does not establish rendered interaction or visual acceptance.
var checks := 0
var failures := 0
var capture_dir := ""

class RouteSpy extends Node:
	var destinations: Array[String] = []
	func goto(path: String) -> void:
		destinations.append(path)

func resolution(dimensions: Vector2i) -> void:
	root.content_scale_mode = Window.CONTENT_SCALE_MODE_DISABLED
	root.content_scale_size = dimensions
	root.size = dimensions
	DisplayServer.window_set_size(dimensions)
	await settle()
	check(root.size == dimensions, "exact viewport size " + str(dimensions))

func capture(label: String) -> void:
	if capture_dir == "" or DisplayServer.get_name() == "headless":
		return
	await RenderingServer.frame_post_draw
	var img := root.get_texture().get_image()
	check(img.save_png(capture_dir.path_join(label + ".png")) == OK, "capture " + label)

func action(name: String) -> InputEventAction:
	var event := InputEventAction.new()
	event.action = name
	event.pressed = true
	return event

func module_count(hull: Node) -> int:
	var count := 0
	for child in hull.get_children():
		if child.has_meta("module_data"):
			count += 1
	return count

func _init() -> void:
	call_deferred("_run")

func check(ok: bool, message: String) -> void:
	checks += 1
	if not ok:
		failures += 1
		print("[FAIL] ", message)

func settle() -> void:
	for i in range(12):
		await process_frame

func _run() -> void:
	var args := OS.get_cmdline_user_args()
	if args.size() == 2 and args[0] == "--capture-dir":
		capture_dir = args[1]
	# Let WindowFit finish before applying reproducible dimensions.
	await settle()
	await resolution(Vector2i(1280, 800))
	var real_router := root.get_node("SceneRouter")
	root.remove_child(real_router)
	var spy := RouteSpy.new()
	spy.name = "SceneRouter"
	root.add_child(spy)
	var menu = load("res://scenes/MainMenu.tscn").instantiate()
	root.add_child(menu)
	await settle()
	check(menu.find_child("DesignLabAction", true, false) != null, "Main Menu exposes Design Lab as primary destination")
	var design_lab_action := menu.find_child("DesignLabAction", true, false) as Button
	var match_setup_action := menu.find_child("MatchSetupAction", true, false) as Button
	check(design_lab_action != null and design_lab_action.icon == UITheme.industrial_icon("nav_design_lab"),
		"Main Menu uses the authored Design Lab navigation icon")
	check(match_setup_action != null and match_setup_action.icon == UITheme.industrial_icon("nav_match_setup"),
		"Main Menu uses the authored Match Setup navigation icon")
	for node_name in ["DesignLabAction", "MatchSetupAction"]:
		var button := menu.find_child(node_name, true, false) as Button
		if button:
			button.pressed.emit()
			check(spy.destinations.back() == button.get_meta("destination"), "button routes to " + node_name)
	for group in menu.GROUPS:
		for item in group.items:
			check(ResourceLoader.exists(item.scene), "destination exists: " + item.title)
	for dimensions in [Vector2i(1920, 1080), Vector2i(1280, 800), Vector2i(960, 720)]:
		await resolution(dimensions)
		var console := menu.find_child("DestinationConsole", true, false) as Control
		check(console.get_global_rect().end.x <= dimensions.x, "menu destinations fit " + str(dimensions))
		await capture("menu-%dx%d" % [dimensions.x, dimensions.y])
	menu.queue_free()
	await settle()
	await resolution(Vector2i(1280, 800))
	var lab = load("res://scenes/MainLab.tscn").instantiate()
	root.add_child(lab)
	await settle()
	var lab_nav_icon := lab.find_child("DesignLabNavigationIcon", true, false) as TextureRect
	check(lab_nav_icon != null and lab_nav_icon.texture == UITheme.industrial_icon("nav_design_lab"),
		"Design Lab toolbar uses its authored navigation icon")
	var slot_icon := lab.find_child("SlotModuleIcon", true, false) as TextureRect
	check(slot_icon != null and slot_icon.texture == UITheme.industrial_icon("slot_module"),
		"Design Lab module cards expose the authored slot icon")
	var operation_icon := lab.find_child("OperationStateIcon", true, false) as TextureRect
	check(operation_icon != null and operation_icon.texture == UITheme.industrial_icon("drop_target"),
		"Design Lab operation strip starts with the authored drop target icon")
	for fixture_name: String in [
		"LabFixtureConsoleFrame",
		"LabFixtureDocumentClamp",
		"LabFixtureRail",
		"LabInspectionLamp",
		"LabPartsTray",
		"LabServicePedestal",
	]:
		var fixture: Node = lab.get_node_or_null(fixture_name)
		check(fixture is Node3D, "Design Lab instances authored fixture: " + fixture_name)
		if fixture is Node3D:
			check(fixture.process_mode == Node.PROCESS_MODE_INHERIT, "fixture remains static: " + fixture_name)
			check(fixture.get_script() == null, "fixture has no runtime script: " + fixture_name)
	var doc = lab.get_node("UI_StatBlock")
	check(doc.has_method("set_document_expanded"), "bottom document can retract without losing actions")
	check(lab.has_signal("placement_feedback"), "placement feedback has a visible state contract")
	check(doc.console_root.get_global_rect().end.x <= 1280, "document fits narrow viewport")
	doc.set_document_expanded(false)
	await settle()
	check(not doc._document_body.is_visible_in_tree() and doc._document_toggle.is_visible_in_tree(), "document retracts with reachable handle")
	doc.set_document_expanded(true)
	doc._select_document_page("Design")
	await settle()
	check(doc.save_button.is_visible_in_tree() and doc.test_button.is_visible_in_tree(), "document exposes save and proving ground")
	doc._select_document_page("Performance")
	for dimensions in [Vector2i(1920, 1080), Vector2i(1280, 800), Vector2i(960, 720)]:
		await resolution(dimensions)
		check(doc.console_root.get_global_rect().end.x <= dimensions.x, "document fits " + str(dimensions))
		check(doc.lab_toolbar.toolbar.get_global_rect().end.x <= dimensions.x, "toolbar fits " + str(dimensions))
		await capture("lab-%dx%d" % [dimensions.x, dimensions.y])
	await resolution(Vector2i(1280, 800))
	var history: int = lab.undo_stack.size()
	var before := module_count(lab.hull)
	lab._place_weapon_from_ui("basic_cannon", Vector3(0, 1, 0), Vector3.UP, true)
	check(lab.undo_stack.size() == history and module_count(lab.hull) == before, "invalid placement preserves hull and history")
	check(doc._operation_label.text.begins_with("CANNOT FIT"), "invalid placement explains recovery")
	check(operation_icon != null and operation_icon.texture == UITheme.industrial_icon("state_invalid"),
		"invalid placement switches the operation icon to the authored invalid state")
	await capture("lab-invalid")
	lab._place_weapon_from_ui("basic_cannon", Vector3(0, 1, 0), Vector3.UP)
	await settle()
	check(module_count(lab.hull) == before + 1 and lab.can_undo(), "placement adds one part and undo entry")
	check(operation_icon != null and operation_icon.texture == UITheme.industrial_icon("state_ready"),
		"fitted placement switches the operation icon to the authored ready state")
	var part: Node3D
	for child in lab.hull.get_children():
		if child.has_meta("module_data"):
			part = child
	lab._select_module(part)
	await settle()
	check(doc.current_selected_module == part and doc._document_page == "Selected", "selection updates document inspector")
	check(operation_icon != null and operation_icon.texture == UITheme.industrial_icon("state_selected"),
		"selected module switches the operation icon to the authored selected state")
	var performance_tab: Button = null
	for tab: Button in doc._document_tabs.get_children():
		if tab.get_meta(&"destination_id", "") == "Performance":
			performance_tab = tab
	check(performance_tab != null, "document exposes Performance navigation")
	if performance_tab:
		performance_tab.pressed.emit()
	check(doc._document_page == "Performance" and doc._document_clusters["Performance"].is_visible_in_tree(), "Performance navigation remains available after selecting a module")
	doc._select_document_page("Selected")
	doc.update_stats_display({
		"weight": 200.0,
		"drivetrain": {"capacity": 100.0, "carried_weight": 200.0, "has_locomotion": true},
	}, lab.hull)
	await settle()
	var assembly_health := doc.find_child("AssemblyHealthIndicator", true, false) as Label
	check(assembly_health != null and assembly_health.is_visible_in_tree(), "assembly health remains visible while tuning an overloaded part")
	var ring = doc.tweak_callout_manager._action_ring
	check(ring != null and ring._is_open and ring.has_focus(), "radial opens with focus")
	var mirror_before: bool = lab.mirror_enabled
	ring._gui_input(action("ui_right"))
	ring._gui_input(action("ui_accept"))
	check(lab.mirror_enabled != mirror_before, "keyboard radial invokes mirror")
	ring.set_action_enabled("arc", false)
	ring._gui_input(action("ui_right"))
	check(ring._actions[ring._hovered].id == "discard", "radial skips disabled actions")
	await capture("lab-selected")
	ring._gui_input(action("ui_cancel"))
	check(not ring._is_open, "Escape closes radial")
	lab._deselect_module()
	doc.lab_toolbar._toolbar_undo()
	await settle()
	check(module_count(lab.hull) == before and lab.can_redo(), "toolbar undo restores assembly")
	doc.lab_toolbar._toolbar_redo()
	await settle()
	check(module_count(lab.hull) == before + 1, "toolbar redo restores fitted part")
	doc.lab_toolbar._return_to_menu()
	check(spy.destinations.back() == "res://scenes/MainMenu.tscn", "Lab returns to Main Menu")
	lab.queue_free()
	await settle()
	spy.free()
	root.add_child(real_router)
	print("[menu-lab] %d checks, %d failures" % [checks, failures])
	quit(1 if failures else 0)
