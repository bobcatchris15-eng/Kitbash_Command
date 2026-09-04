extends SceneTree
# Task 7: deterministic state/bounds audit with optional real-renderer captures.
# Run via tools/run_ui_polish_matrix.ps1. Never saves designs or launches Battle.
const Tokens = preload("res://scripts/ui_tokens.gd")
const Anim = preload("res://scripts/ui_anim.gd")
const Audit = preload("res://scripts/ui_audit.gd")
const SIZES = [Vector2i(1920, 1080), Vector2i(1280, 800), Vector2i(960, 720)]
var checks := 0
var failures: Array[String] = []
var rows: Array[Dictionary] = []
var output_dir := ""
var screen := "all"

class EmptyLibrary extends Node:
	func list_blueprints(_include_defaults: bool = false) -> Array:
		return []

func _init() -> void:
	call_deferred("_run")

func check(ok: bool, message: String) -> void:
	checks += 1
	if not ok:
		failures.append(message)
		print("[FAIL] ", message)

func settle() -> void:
	await create_timer(0.5).timeout

func resolution(dimensions: Vector2i) -> void:
	root.content_scale_mode = Window.CONTENT_SCALE_MODE_DISABLED
	root.content_scale_size = dimensions
	root.size = dimensions
	DisplayServer.window_set_size(dimensions)
	await settle()
	check(root.size == dimensions, "viewport " + str(dimensions))

func fits(control: Control, label: String) -> void:
	var rect := control.get_global_rect()
	var bounds := Rect2(Vector2.ZERO, Vector2(root.size)).grow(1.0)
	check(bounds.encloses(rect), label + " fits " + str(root.size) + " rect=" + str(rect))

func record(subject: Node, state: String) -> void:
	var row: Dictionary = {"screen": subject.name, "state": state,
		"viewport": [root.size.x, root.size.y], "capture": "unavailable-headless",
		"offscreen": Audit.find_offscreen_controls(subject, Rect2(Vector2.ZERO, Vector2(root.size)), []),
		"overflow": Audit.find_overflowing_panels(subject, [])}
	if subject.name == "MatchSetup" and subject._stage == 2:
		var page: Control = subject._stage_pages[2]
		var content := page.get_child(0) as Control
		row.launch_geometry = {"page": page.get_global_rect(),
			"content": content.get_global_rect(), "content_min": content.get_combined_minimum_size(),
			"rules_min": (content.get_child(0) as Control).get_combined_minimum_size(),
			"hero": subject._hero_view.get_global_rect(), "hero_min": subject._hero_view.get_combined_minimum_size()}
	# Persist the attempted row BEFORE drawing, so a native renderer crash leaves evidence.
	if DisplayServer.get_name() != "headless":
		row.capture = "pending"
	rows.append(row)
	write_report()
	if DisplayServer.get_name() != "headless":
		await RenderingServer.frame_post_draw
		var filename := "%s-%s-%dx%d.png" % [subject.name, state, root.size.x, root.size.y]
		var img := root.get_texture().get_image()
		var result := img.save_png(output_dir.path_join(filename))
		check(result == OK, "save " + filename)
		row.capture = filename if result == OK else "failed"
		write_report()

func write_report() -> void:
	if output_dir.is_empty():
		return
	var file := FileAccess.open(output_dir.path_join("matrix-" + screen + ".json"), FileAccess.WRITE)
	if file:
		file.store_string(JSON.stringify({"checks": checks, "failures": failures,
			"renderer": DisplayServer.get_name(), "rows": rows}, "\t"))

func _run() -> void:
	var args := OS.get_cmdline_user_args()
	for i in range(args.size() - 1):
		if args[i] == "--output-dir": output_dir = args[i + 1]
		if args[i] == "--screen": screen = args[i + 1]
	if output_dir.is_empty():
		push_error("Pass --output-dir pointing to an ignored playtest directory")
		quit(2)
		return
	DirAccess.make_dir_recursive_absolute(output_dir)
	await settle() # WindowFit owns initial size; override only after it finishes.
	if screen in ["all", "menu"]: await menu_matrix()
	if screen in ["all", "lab"]: await lab_matrix()
	if screen in ["all", "setup"]: await setup_matrix()
	write_report()
	print("[ui-polish] %d checks, %d failures, %d matrix rows" % [checks, failures.size(), rows.size()])
	quit(1 if not failures.is_empty() else 0)

func menu_matrix() -> void:
	await resolution(SIZES[0])
	var menu = load("res://scenes/MainMenu.tscn").instantiate()
	root.add_child(menu)
	await settle()
	var primary := menu.find_child("DesignLabAction", true, false) as Button
	for dimensions in SIZES:
		await resolution(dimensions)
		fits(menu.find_child("DestinationConsole", true, false), "destination console")
		fits(menu.find_child("Showcase", true, false), "showcase and record")
		await record(menu, "default" if dimensions == SIZES[0] else "narrow-viewport")
	await resolution(SIZES[1])
	primary.grab_focus()
	check(primary.has_focus() and primary.has_theme_stylebox_override("focus"), "primary keyboard focus")
	await record(menu, "focus")
	# Mouse events drive Godot's actual hover/pressed drawing state. Release outside
	# the target cancels activation, keeping this runner away from scene navigation.
	primary.release_focus()
	var motion := InputEventMouseMotion.new()
	motion.position = primary.get_global_rect().get_center()
	root.push_input(motion)
	await settle()
	check(primary.is_hovered(), "primary actual hover")
	await record(menu, "hover")
	var press := InputEventMouseButton.new()
	press.position = motion.position
	press.button_index = MOUSE_BUTTON_LEFT
	press.pressed = true
	root.push_input(press)
	check(primary.is_pressed(), "primary actual pressed state")
	await record(menu, "pressed")
	motion.position = Vector2(2, 2)
	root.push_input(motion)
	press.position = motion.position
	press.pressed = false
	root.push_input(press)
	primary.disabled = true
	await settle()
	primary.mouse_entered.emit()
	await settle()
	check(primary.scale.is_equal_approx(Vector2.ONE), "disabled button stays at rest")
	await record(menu, "disabled")
	primary.disabled = false
	var heading := Label.new()
	heading.theme_type_variation = "HeadingLabel"
	menu.add_child(heading)
	check(heading.get_theme_font("font").get_font_name() != menu.get_theme_font("font", "TitleLabel").get_font_name(),
		"operational headings use readable sans rather than display face")
	check(heading.get_theme_font_size("font_size") >= 18, "operational heading size")
	var field := LineEdit.new()
	menu.add_child(field)
	check(field.get_theme_font("font").get_font_name() == menu.get_theme_default_font().get_font_name(), "name fields use UI sans")
	var list := VBoxContainer.new()
	menu.add_child(list)
	for i in range(40): list.add_child(Label.new())
	Anim.stagger_in(list)
	await create_timer(0.48).timeout
	check(list.get_child(39).modulate.a > 0.999, "40-item entrance completes within 450ms plus frame tolerance")
	menu.queue_free()
	await settle()

func lab_matrix() -> void:
	await resolution(SIZES[1])
	var lab = load("res://scenes/MainLab.tscn").instantiate()
	root.add_child(lab)
	await settle()
	var doc = lab.get_node("UI_StatBlock")
	for dimensions in SIZES:
		await resolution(dimensions)
		fits(doc.console_root, "bottom document")
		fits(doc.lab_toolbar.toolbar, "Lab toolbar")
		for page in ["Design", "Performance", "Build", "Selected"]:
			doc._select_document_page(page)
			await settle()
			fits(doc.console_root, "document " + page)
		await record(lab, "default" if dimensions == SIZES[0] else "narrow-viewport")
	await resolution(SIZES[1])
	var history: int = lab.undo_stack.size()
	lab._place_weapon_from_ui("basic_cannon", Vector3(0, 1, 0), Vector3.UP, true)
	check(lab.undo_stack.size() == history and doc._operation_label.text.begins_with("CANNOT FIT"), "invalid drop explains rejection without editing hull")
	await record(lab, "invalid-drop")
	var armor = lab.get_node("UI_ArmorStationPanel")
	doc.lab_toolbar._apply_paint_mode_swap(lab)
	await settle()
	check(armor.visible, "Armor Station enters")
	await record(lab, "armor-station")
	await resolution(SIZES[2])
	await record(lab, "armor-station-narrow")
	armor.exit()
	doc.lab_toolbar._apply_build_mode_swap(lab)
	await settle()
	check(not armor.visible, "Armor Station returns")
	lab.queue_free()
	await settle()

func setup_matrix() -> void:
	await resolution(SIZES[0])
	var setup = load("res://scenes/MatchSetup.tscn").instantiate()
	root.add_child(setup)
	await settle()
	for dimensions in SIZES:
		await resolution(dimensions)
		for stage in range(3):
			setup._goto_stage(stage, false)
			await settle()
			fits(setup._stage_pages[stage], "setup stage %d" % stage)
			if stage == 2:
				var page := setup._stage_pages[stage] as ScrollContainer
				var content := page.get_child(0) as Control
				check(content.size.x <= page.size.x + 1.0, "launch content fits its scroll viewport without horizontal clipping")
				fits(setup._hero_view, "launch squadron preview")
			fits(setup._nav_bar, "setup navigation")
			for chip in setup._spine_chips: fits(chip, "stage chip")
			await record(setup, ["default", "empty", "launch"][stage] + ("-narrow" if dimensions != SIZES[0] else ""))
	await resolution(SIZES[1])
	setup._goto_stage(1, false)
	var picker = setup.roster_picker
	check(picker.ordered_paths().is_empty(), "empty roster uses auto-draft")
	var path := ""
	for entry in setup.bp_manager.list_blueprints(true):
		if not entry.get("is_defensive", false) and not entry.get("is_harvester", false):
			path = entry.path
			break
	check(not path.is_empty(), "bundled playable blueprint fixture exists")
	picker.assign_to_next_free(path)
	await settle()
	check(picker.ordered_paths().size() == 1, "populated roster assigns exactly one design")
	await record(setup, "populated")
	var invalid := {"type": "roster_blueprint", "path": path, "name": "Unit"}
	check(not picker._building_slots[0]._can_drop_data(Vector2.ZERO, invalid), "unit rejected by defence slot")
	check(picker.ordered_paths().size() == 1, "invalid drop preserves roster")
	await record(setup, "invalid-drop")
	setup._goto_stage(2, false)
	await settle()
	check(setup._readiness.text.begins_with("READY"), "populated launch readiness")
	await record(setup, "populated-launch")
	for slot in picker._all_slots(): slot.clear_slot()
	var library: Node = setup.bp_manager
	var empty := EmptyLibrary.new()
	setup.add_child(empty)
	setup.bp_manager = empty
	setup._refresh_readiness()
	check(setup._readiness.text.begins_with("BLOCKED"), "no library explains blocked launch")
	check(setup._launch_btn.disabled, "blocked launch disables commit control")
	await record(setup, "blocked-launch")
	setup.bp_manager = library
	setup._refresh_readiness()
	check(not setup._launch_btn.disabled, "restored library re-enables launch")
	setup.queue_free()
	await settle()
