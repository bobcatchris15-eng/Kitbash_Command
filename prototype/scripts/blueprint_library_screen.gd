extends Control

const UITheme = preload("res://scripts/ui_theme.gd")
const Tokens = preload("res://scripts/ui_tokens.gd")
const BlueprintManagerScript = preload("res://scripts/blueprint_manager.gd")
const MeshAssetLoader = preload("res://scripts/mesh_asset_loader.gd")
const ModuleCatalogScript = preload("res://scripts/module_catalog.gd")
const HullMaterialBuilderScript = preload("res://scripts/hull_material_builder.gd")
const SceneRouter = preload("res://scripts/scene_router.gd")
const UIShell = preload("res://scripts/ui_shell.gd")
const UIAnimScript = preload("res://scripts/ui_anim.gd")
const UIFeedbackScript = preload("res://scripts/ui_feedback.gd")
const TestRangeLauncherScript = preload("res://scripts/test_range_launcher.gd")
const ToolboxPlateScript = preload("res://scripts/ui_toolbox_plate.gd")
const StampedLabelScript = preload("res://scripts/ui_stamped_label.gd")

# The Library is two-pane: a list of saved designs on the left, a single
# rotating preview in the 3D viewport behind everything. The list rows
# USED to drive a per-row hover preview - hover a row, the turntable
# swaps to that design. That fell into the "preview on every button"
# trap: every row owned its own preview slot, none of them were the
# canonical "look at this design" view, and the layout was carrying
# per-row Edit / Test / Duplicate / Rename / Delete buttons that didn't
# fit widthwise inside the 500px left panel.
#
# The fix: ONE selection state, ONE preview. A row is selected (clicked,
# or auto-selected if it's the only / first one), the viewport's turntable
# shows that design, the action footer operates on that design. Per-row
# buttons are gone - they were the thing pushing the panel past 500px.
# The panel is widened to fit the footer's five toolbox buttons.
#
# Width math: 5 toolbox buttons, each ~150px wide to fit the longest
# legend (DUPLICATE) at the design lab's HEADER_FONT_SIZE (19) with the
# StampedLabel's 2px glyph spacing, plus 2*SPACE_MD (24) of panel margin
# and 4*SPACE_SM (32) of inter-button separation = ~806px. 820 gives
# each button a couple of px of headroom so the chamfered plate edges
# do not kiss the next button's chamfer.
const LEFT_PANEL_WIDTH := 820.0
# Matches HEADER_FONT_SIZE in production_hud.gd / parts_menu.gd - the
# stamped lettering is the same primitive those toolboxes use, and the
# "design lab toolboxes" look only reads correctly when the font is the
# same size as theirs. Going smaller would visually sever the footer
# from the catalogue the Lab shows.
const FOOTER_FONT_SIZE := 19
# 44 = the design lab's HEADER_HEIGHT, the height a chamfered plate
# needs to read as a plate rather than a tab. Hits Tokens.HIT_TARGET_MIN
# (32) with room to spare for the chamfer's own drop shadow.
const FOOTER_HEIGHT := 44.0
# The 3px hazard strip on the left edge of a selected row. UI_STYLE_GUIDE
# says the "ListButton" pattern is a flat row with a hazard left edge when
# selected - we draw that strip on a plain HBoxContainer so the row can
# still host the multi-line VBox of labels it needs to show.
const SELECT_INDICATOR_WIDTH := 3.0

var list_vbox: VBoxContainer
# Footer action buttons in display order. Populated once by
# _build_action_footer; _update_footer_state walks this to enable/disable
# based on _selected_entry. Stored by reference so we can read each
# button's "action" meta to apply the per-action disabled rules
# (Rename / Delete are disabled for read-only / mod-authored entries).
var _action_buttons: Array = []
# The StampedLabel that sits on top of each action button. Mirrors the
# button's disabled state via StampedLabel.set_live() - the only
# visual signal a disabled toolbox button can carry, since the plate
# itself has no disabled look and the engraved button has no theme
# stateboxes left to draw one.
var _stamp_of: Dictionary = {}
# Single source of truth for "what design is the preview showing". A row
# reference so the previous selection's indicator can be cleared, and
# the entry dict so action handlers can read id / path / name without
# re-scanning the list.
var _selected_row: Control = null
var _selected_entry: Dictionary = {}
var blueprint_manager: Node

var _turntable_node: Node3D = null
var _turntable_model_container: Node3D = null

func _ready() -> void:
	blueprint_manager = BlueprintManagerScript.new()
	add_child(blueprint_manager)

	if DisplayServer.get_name() != "headless":
		_build_3d_background()

	_build_ui()
	_refresh_list()

func _process(delta: float) -> void:
	if is_instance_valid(_turntable_node):
		_turntable_node.rotation.y += 0.25 * delta

func _build_3d_background() -> void:
	var vp_container = SubViewportContainer.new()
	vp_container.set_anchors_preset(Control.PRESET_FULL_RECT)
	vp_container.stretch = true
	vp_container.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(vp_container)

	var vp = SubViewport.new()
	vp.size = Vector2i(1920, 1080)
	vp.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	vp.msaa_3d = Viewport.MSAA_4X
	vp_container.add_child(vp)

	var scene = Node3D.new()
	vp.add_child(scene)

	# Studio WorldEnvironment
	var env_node = WorldEnvironment.new()
	var env = Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color(0.38, 0.40, 0.42, 1.0)
	env.tonemap_mode = Environment.TONE_MAPPER_ACES
	env.tonemap_exposure = 1.15
	env.ssao_enabled = true
	env.ssao_radius = 1.4
	env.ssao_intensity = 2.4
	env.glow_enabled = true
	env.glow_intensity = 0.5
	env.glow_bloom = 0.08
	env_node.environment = env
	scene.add_child(env_node)

	var sun = DirectionalLight3D.new()
	sun.light_color = Color(1.0, 0.96, 0.88)
	sun.light_energy = 1.35
	sun.rotation_degrees = Vector3(-38, -30, 0)
	sun.shadow_enabled = true
	scene.add_child(sun)

	var rim = DirectionalLight3D.new()
	rim.light_color = Color(0.65, 0.75, 0.85)
	rim.light_energy = 0.85
	rim.rotation_degrees = Vector3(25, 145, 0)
	scene.add_child(rim)

	var cam = Camera3D.new()
	cam.position = Vector3(1.2, 4.8, 15.5)
	cam.rotation_degrees = Vector3(-16, 12, 0)
	cam.fov = 46.0
	scene.add_child(cam)

	_turntable_node = Node3D.new()
	_turntable_node.position = Vector3(0.5, -0.4, 0.0)
	scene.add_child(_turntable_node)

	var platform_mesh = MeshInstance3D.new()
	var cyl = CylinderMesh.new()
	cyl.top_radius = 4.8
	cyl.bottom_radius = 5.2
	cyl.height = 0.4
	platform_mesh.mesh = cyl
	platform_mesh.position = Vector3(0, -0.2, 0)
	var mat = StandardMaterial3D.new()
	mat.albedo_color = Color(0.30, 0.32, 0.34, 1.0)
	mat.metallic = 0.2
	mat.roughness = 0.65
	platform_mesh.material_override = mat
	_turntable_node.add_child(platform_mesh)

	_turntable_model_container = Node3D.new()
	_turntable_node.add_child(_turntable_model_container)

func _build_ui() -> void:
	# L0 workbench (D7). This screen had NO backdrop at all - it went
	# straight to screen_frame() - so its panels sat on whatever the scene
	# root happened to clear to, and it was the only out-of-match screen
	# with no surface under it. Cork because a library of saved designs is
	# a pinboard of them; its only reuse is operations_draft, which is in a
	# different flow and never adjacent to this screen.
	#
	# workbench() also creates the UIPropStage, which this screen's five
	# StampedButton action controls need in their ancestor chain.
	UIShell.workbench(self, "cork")
	var frame := UIShell.screen_frame(self)

	var hbox = HBoxContainer.new()
	hbox.mouse_filter = Control.MOUSE_FILTER_IGNORE
	frame.add_child(hbox)

	# Left Side: Library List. Widened from 500 to LEFT_PANEL_WIDTH so the
	# footer of five StampedButtons fits without overflowing the panel.
	# The viewport fills the rest of the screen behind this panel, so a
	# wider panel simply covers more of the left side - the preview
	# stays centered in the 3D scene.
	var left_panel = PanelContainer.new()
	left_panel.custom_minimum_size = Vector2(LEFT_PANEL_WIDTH, 0)
	left_panel.size_flags_horizontal = Control.SIZE_SHRINK_END
	var style = StyleBoxFlat.new()
	style.bg_color = Color(0.12, 0.13, 0.15, 0.85)
	left_panel.add_theme_stylebox_override("panel", style)
	hbox.add_child(left_panel)

	var margin = MarginContainer.new()
	margin.add_theme_constant_override("margin_left", Tokens.SPACE_MD)
	margin.add_theme_constant_override("margin_right", Tokens.SPACE_MD)
	margin.add_theme_constant_override("margin_top", Tokens.SPACE_MD)
	margin.add_theme_constant_override("margin_bottom", Tokens.SPACE_MD)
	left_panel.add_child(margin)

	var vbox = VBoxContainer.new()
	vbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	vbox.add_theme_constant_override("separation", Tokens.SPACE_SM)
	margin.add_child(vbox)

	var header_row := HBoxContainer.new()
	header_row.add_theme_constant_override("separation", Tokens.SPACE_SM)
	var blueprint_icon := UITheme.industrial_icon("blueprint_status")
	if blueprint_icon != null:
		var icon_rect := TextureRect.new()
		icon_rect.name = "BlueprintStatusIcon"
		icon_rect.texture = blueprint_icon
		icon_rect.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		icon_rect.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		icon_rect.custom_minimum_size = Vector2(Tokens.SPINE_ICON, Tokens.SPINE_ICON)
		icon_rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
		header_row.add_child(icon_rect)
	var header := Label.new()
	header.text = "BLUEPRINT LIBRARY"
	header.theme_type_variation = "TitleLabel"
	header.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	header_row.add_child(header)
	vbox.add_child(header_row)

	var scroll = ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	vbox.add_child(scroll)

	list_vbox = VBoxContainer.new()
	list_vbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	list_vbox.add_theme_constant_override("separation", 0)
	scroll.add_child(list_vbox)

	# Thin divider above the action footer. Reads as "control surface
	# boundary" - the rows above are a picker, the buttons below act on
	# the picker. Without it, the footer floats in space attached to
	# nothing.
	vbox.add_child(HSeparator.new())
	_build_action_footer(vbox)

	# Back / Return. Sits below the action footer with a thin divider of
	# its own so the row reads as "screen-level navigation" and not as a
	# fifth action. Uses the same toolbox chrome so the screen is one
	# chamfered strip rather than a strip plus a stranded lone button.
	vbox.add_child(HSeparator.new())
	var back_btn := _make_toolbox_button(vbox, "RETURN")
	back_btn.pressed.connect(func():
		var router = get_node_or_null("/root/SceneRouter")
		var target = "res://scenes/MainMenu.tscn"
		if router and router.pending_context != "":
			target = router.pending_context
		# goto(), not change_scene_async(): `target` is often MainMenu, which has no
		# WARM_SOURCES entry, and change_scene_async() put it behind the loading
		# screen regardless. goto() only uses the loading screen for scenes that
		# actually stall.
		if router:
			router.goto(target)
		else:
			get_tree().change_scene_to_file(target)
	)

# The single set of action buttons for the selected design. Each button
# reads _selected_entry at click time - the per-row closures that lived
# in _add_entry_ui are gone, replaced by a single bound entry updated
# by _select_entry(). The buttons themselves are toolbox-styled: a flat
# chamfered plate behind an engraved Button with a StampedLabel on top,
# exactly the chrome the Design Lab's hardware catalogue uses.
#
# Action order is fixed (Edit, Test, Duplicate, Rename, Delete) because
# "Edit" is the row's primary commitment (it changes which scene you
# go to) and "Delete" is the only destructive action. Position carries
# the hierarchy now that the 3D-mesh variant tints are gone - the same
# reasoning ui_toolbox.gd uses for putting its accordion tier headers
# in a fixed order, and the same reasoning the Skirmish build queue
# uses for putting its only destructive action at the right end of the
# strip.
#
# Legends are short ("EDIT", "TEST", "DUPLICATE", "RENAME", "DELETE")
# to match the design lab's terse toolbox labels ("HULLS", "WEAPONS",
# "SUPPORT", "DRIVES", "FIND"). "EDIT" in this context clearly means
# "open the selected design in the Lab" and "TEST" clearly means
# "drive the selected design in the Test Range" - the row's selected
# state supplies the object, the footer supplies the verb.
func _build_action_footer(parent: VBoxContainer) -> void:
	var action_hbox = HBoxContainer.new()
	action_hbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	action_hbox.add_theme_constant_override("separation", Tokens.SPACE_SM)
	parent.add_child(action_hbox)

	var actions := [
		{"legend": "EDIT", "action": "edit"},
		{"legend": "TEST", "action": "test"},
		{"legend": "DUPLICATE", "action": "duplicate"},
		{"legend": "RENAME", "action": "rename"},
		{"legend": "DELETE", "action": "delete"},
	]
	for spec in actions:
		var btn := _make_toolbox_button(action_hbox, spec["legend"])
		btn.set_meta("action", spec["action"])
		match spec["action"]:
			"edit": btn.pressed.connect(_on_edit_pressed)
			"test": btn.pressed.connect(_on_test_pressed)
			"duplicate": btn.pressed.connect(_on_duplicate_pressed)
			"rename": btn.pressed.connect(_on_rename_pressed)
			"delete": btn.pressed.connect(_on_delete_pressed)
		# NO add_child HERE. _make_toolbox_button() already parented the
		# button into its wrapper Control and the wrapper into action_hbox;
		# re-adding the button pushed an "already has a parent" error for
		# every one of the five, fifteen per test run. The button was
		# already in the right place - the second add was pure noise, and
		# noise that test_probe_scene_loads was reporting as a clean load.
		_action_buttons.append(btn)


# The "toolbox button" assembly: a wrapper Control holding a flat
# ToolboxPlate behind an engraved Button, with a StampedLabel as the
# button's only child. The Button's own theme styleboxes are all blanked
# so the theme's procedural moulded does not double-paint over the
# plate - the plate IS the visible chrome, the button is just a hit
# target, the StampedLabel is the lettering.
#
# VERBATIM COPY of the pattern in production_hud.gd:239-260 and
# parts_menu.gd:340-353. The plate+button sibling arrangement is what
# makes the row read as one chamfered metal strip with five enamel
# labels on it, rather than as five separate widget-styled buttons
# sitting on top of a row. The 3D-mesh StampedButton alternative
# looked right for a single primary action but became noise with
# five of them in a row - every button had its own little 3D scene
# going on behind the label.
#
# The wrapper Control is what the parent container holds. It accepts
# the HBox's SIZE_EXPAND_FILL width; the plate and button inside it
# both fill the wrapper at PRESET_FULL_RECT, the plate drawing first
# (sibling draw order, which is also why the plate is added before
# the button here).
func _make_toolbox_button(parent: Container, legend: String) -> Button:
	var wrapper := Control.new()
	wrapper.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	wrapper.custom_minimum_size = Vector2(0, FOOTER_HEIGHT)
	parent.add_child(wrapper)

	var plate := ToolboxPlateScript.new()
	plate.set_anchors_preset(Control.PRESET_FULL_RECT)
	wrapper.add_child(plate)

	var btn := Button.new()
	btn.alignment = HORIZONTAL_ALIGNMENT_CENTER
	btn.custom_minimum_size = Vector2(0, FOOTER_HEIGHT)
	_engrave(btn)
	btn.set_anchors_preset(Control.PRESET_FULL_RECT)
	wrapper.add_child(btn)

	var stamp: Control = StampedLabelScript.new()
	stamp.text = legend
	stamp.font_size = FOOTER_FONT_SIZE
	stamp.set_anchors_preset(Control.PRESET_FULL_RECT)
	btn.add_child(stamp)

	UIFeedbackScript.wire(btn, "select")

	# The button is what _action_buttons holds; the stamp sits on top
	# of the engraved button and is what set_live() flips when the
	# button's disabled state changes. Keeping the pair in a dict means
	# _update_footer_state does not have to walk the button's children
	# to find the right Control to dim.
	_stamp_of[btn] = stamp

	return btn


# Strips a header Button back to a bare hit target, exactly as
# production_hud.gd:331-335 and parts_menu.gd:379-382 do. The drawn
# plate behind it already IS the surface and the StampedLabel on top
# of it is already the lettering, so everything the theme would
# contribute here is a second copy of both - a themed button body
# over a drawn plate is two plates, and the button's own text render
# is the flat printed-on fill the stamped lettering replaced.
func _engrave(button: Button) -> void:
	for state in ["normal", "hover", "pressed", "focus", "disabled"]:
		button.add_theme_stylebox_override(state, StyleBoxEmpty.new())

func _refresh_list() -> void:
	# Remember the previously selected id so a refresh (e.g. after a
	# delete of a non-selected row, or after a rename) keeps the same
	# row visually selected instead of jumping back to the top. If the
	# selected id is gone (the user deleted it), we fall through to
	# selecting the first available row.
	var prev_id: String = _selected_entry.get("id", "")

	for child in list_vbox.get_children():
		child.queue_free()
	_selected_row = null
	_selected_entry = {}

	var roster = blueprint_manager.list_blueprints(false)
	if roster.is_empty():
		var empty_lbl = Label.new()
		empty_lbl.text = "No saved blueprints found."
		# HintLabel rather than a 50% alpha modulate. Fading white to half opacity
		# over a textured backdrop lets the grain read straight through the glyphs;
		# TEXT_SECONDARY is a real colour that stays legible on it.
		empty_lbl.theme_type_variation = "HintLabel"
		list_vbox.add_child(empty_lbl)
		_update_footer_state()
		_clear_preview()
		return

	# First pass: build every row, remembering the first row as the
	# default selection and any row whose id matches prev_id as the
	# preferred selection. Same-id wins over first so a refresh keeps
	# the user's place.
	var target_row: Control = null
	var target_entry: Dictionary = {}
	for entry in roster:
		var row := _add_entry_ui(entry)
		if target_row == null:
			target_row = row
			target_entry = entry
		if prev_id != "" and entry.get("id", "") == prev_id:
			target_row = row
			target_entry = entry

	# _select_entry fires the turntable update and sets footer state.
	# When target_row is null the list is empty - the early-return above
	# already handled that case.
	if target_row != null:
		_select_entry(target_row, target_entry)

	# Deferred: stagger_in reads each child's position, which is not final until
	# the VBox has laid the new rows out.
	call_deferred("_animate_list_entrance")

func _animate_list_entrance() -> void:
	if is_instance_valid(list_vbox):
		UIAnimScript.stagger_in(list_vbox)


func _add_entry_ui(entry: Dictionary) -> Control:
	# Each row is an HBoxContainer: a hazard strip on the left (the
	# selection indicator, hidden at rest) and a VBoxContainer of label
	# rows on the right. The whole HBox is the click target via
	# gui_input; the labels themselves pass clicks through so a click
	# anywhere on the row - even on the name text - selects it.
	var row := HBoxContainer.new()
	row.mouse_filter = Control.MOUSE_FILTER_PASS
	row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.set_meta("entry", entry)
	list_vbox.add_child(row)

	var indicator := ColorRect.new()
	indicator.name = "SelectIndicator"
	indicator.custom_minimum_size = Vector2(SELECT_INDICATOR_WIDTH, 0)
	indicator.color = Tokens.SIGNAL_HAZARD
	indicator.visible = false
	indicator.size_flags_vertical = Control.SIZE_EXPAND_FILL
	indicator.mouse_filter = Control.MOUSE_FILTER_IGNORE
	row.add_child(indicator)

	var entry_vbox = VBoxContainer.new()
	entry_vbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	entry_vbox.mouse_filter = Control.MOUSE_FILTER_IGNORE
	row.add_child(entry_vbox)

	var name_lbl = Label.new()
	name_lbl.text = entry.get("name", "Untitled Design")
	name_lbl.theme_type_variation = "HeadingLabel"
	name_lbl.mouse_filter = Control.MOUSE_FILTER_IGNORE
	entry_vbox.add_child(name_lbl)

	var meta_hbox = HBoxContainer.new()
	meta_hbox.mouse_filter = Control.MOUSE_FILTER_IGNORE
	entry_vbox.add_child(meta_hbox)

	var hull_lbl = Label.new()
	hull_lbl.text = _prettify(entry.get("hull_type", ""))
	hull_lbl.modulate = Color(1, 1, 1, 0.6)
	hull_lbl.mouse_filter = Control.MOUSE_FILTER_IGNORE
	meta_hbox.add_child(hull_lbl)

	var abbr: String = str(entry.get("abbreviation", "")).strip_edges()
	if abbr != "":
		var abbr_lbl = Label.new()
		abbr_lbl.text = " | \"%s\"" % abbr
		abbr_lbl.modulate = Color(0.75, 0.85, 0.95, 0.75)
		abbr_lbl.mouse_filter = Control.MOUSE_FILTER_IGNORE
		meta_hbox.add_child(abbr_lbl)

	var date_lbl = Label.new()
	date_lbl.text = " | " + _format_modified(entry.get("modified_unix", 0))
	date_lbl.modulate = Color(1, 1, 1, 0.4)
	date_lbl.mouse_filter = Control.MOUSE_FILTER_IGNORE
	meta_hbox.add_child(date_lbl)

	# The one row in this list that says what a design is FOR rather than what
	# it is made of. Hull type and date do not distinguish an ore hauler from a
	# tank built on the same chassis, and the Library is where a player goes to
	# find "the harvester I made" among thirty saves.
	#
	# A tag, not another dim meta label: it is deliberately the brightest thing
	# in this row after the name, because scanning for it is the whole job. It
	# also carries the payload, so two harvesters in the list are comparable
	# without opening either. It reads off the roster index entry rather than
	# reconstructing the design - see list_blueprints(), which derives it while
	# the blueprint JSON is already parsed and in hand.
	if bool(entry.get("is_harvester", false)):
		var harv_lbl = Label.new()
		harv_lbl.text = "  HARVESTER %d" % int(entry.get("cargo_capacity", 0))
		harv_lbl.theme_type_variation = "StatLabel"
		harv_lbl.modulate = Color(1.0, 0.82, 0.35, 1.0)
		harv_lbl.tooltip_text = "Mounts a Resource Harvester - this design can gather metal and crystal.\nThe number is its hopper: how much it carries per trip, Resource Bays included."
		harv_lbl.mouse_filter = Control.MOUSE_FILTER_IGNORE
		meta_hbox.add_child(harv_lbl)

	# HSeparator is a child of the row's VBox so it sits at the bottom of
	# THIS row and visually separates this row from the next one. With
	# list_vbox's separation set to 0, the separator is what reads as
	# "different row", not layout spacing.
	entry_vbox.add_child(HSeparator.new())

	row.gui_input.connect(func(event: InputEvent):
		if event is InputEventMouseButton:
			var mb := event as InputEventMouseButton
			if mb.pressed and mb.button_index == MOUSE_BUTTON_LEFT:
				_select_entry(row, entry)
	)

	return row


# Selection is the single source of truth for "what is the turntable
# showing" and "what do the footer buttons operate on". Setting it clears
# the previous indicator, lights the new one, refreshes the preview, and
# re-evaluates which footer buttons should be enabled.
func _select_entry(row: Control, entry: Dictionary) -> void:
	if _selected_row == row:
		return
	if is_instance_valid(_selected_row):
		var prev_ind := _selected_row.get_node_or_null("SelectIndicator")
		if prev_ind:
			prev_ind.visible = false
	_selected_row = row
	_selected_entry = entry
	var ind := row.get_node_or_null("SelectIndicator")
	if ind:
		ind.visible = true
	_preview_blueprint(entry.get("path", ""))
	_update_footer_state()


# Per-action enable/disable. The base rule is "no selection, no action",
# but Rename and Delete are additionally blocked for read-only / mod-
# authored entries - the same rule the per-row buttons used, just lifted
# out of the row closure and into the footer.
#
# The StampedLabel is the ONLY visual channel for a disabled state in
# the toolbox pattern - the plate has no disabled look and the engraved
# button has no theme styleboxes left to draw one. set_live(false) dims
# the enamel without touching the chamfered wall (modulate would smear
# the wall into the dim), so a disabled button reads as "the face is
# the same, but it is unpowered".
func _update_footer_state() -> void:
	var has_selection := not _selected_entry.is_empty()
	var read_only := bool(_selected_entry.get("read_only", false))
	for btn in _action_buttons:
		var action: String = btn.get_meta("action", "")
		var disabled: bool
		if action in ["delete", "rename"] and read_only:
			disabled = true
		else:
			disabled = not has_selection
		btn.disabled = disabled
		var stamp: Control = _stamp_of.get(btn, null)
		if stamp != null and stamp.has_method("set_live"):
			stamp.set_live(not disabled)


func _clear_preview() -> void:
	if not is_instance_valid(_turntable_model_container):
		return
	for child in _turntable_model_container.get_children():
		child.queue_free()


func _preview_blueprint(path: String) -> void:
	if not is_instance_valid(_turntable_model_container):
		return
	for child in _turntable_model_container.get_children():
		child.queue_free()

	var bp = blueprint_manager.load_blueprint(path)
	if bp.is_empty():
		return

	var model_root = Node3D.new()
	model_root.position = Vector3(0, 0.1, 0)
	var vehicle = blueprint_manager.reconstruct_vehicle(bp, model_root, true)
	if vehicle == null:
		var hull_id = str(bp.get("hull_type", "brenntal_medium_a"))
		var mesh = MeshAssetLoader.get_hull_mesh(hull_id)
		var mesh_inst = MeshInstance3D.new()
		mesh_inst.mesh = mesh
		model_root.add_child(mesh_inst)

	# Apply scale model look
	HullMaterialBuilderScript.apply_scale_model_finish(model_root)
	_turntable_model_container.add_child(model_root)

# _apply_unpainted_scale_model_material() lived here as a verbatim duplicate of
# main_menu.gd's copy. Both now call HullMaterialBuilder.apply_scale_model_finish(),
# which is the file that exists to end exactly this copy-paste - and which also
# holds the albedo colour that previously had two definitions as well as two
# implementations.

func _on_edit_pressed():
	# The library is now a separate scene, so the Lab isn't in the tree to load into directly.
	# We write the design to the scratch slot and flag it for restore, then transition to the Lab.
	if _selected_entry.is_empty():
		return
	var path: String = _selected_entry.get("path", "")
	var data = blueprint_manager.load_blueprint(path)
	if data.is_empty():
		_show_error("Could not read blueprint data.")
		return

	# Important: Make sure the ID and Name are retained in the scratch file so it doesn't fork on save.
	data["pending_lab_restore"] = true
	var json_string = JSON.stringify(data, "\t")

	var dir = DirAccess.open("user://")
	if not dir.dir_exists("blueprints"):
		dir.make_dir("blueprints")

	var f = FileAccess.open(BlueprintManagerScript.SCRATCH_PATH, FileAccess.WRITE)
	if f:
		f.store_string(json_string)
		f.close()
		var router = get_node_or_null("/root/SceneRouter")
		if router:
			router.goto("res://scenes/MainLab.tscn")
		else:
			get_tree().change_scene_to_file("res://scenes/MainLab.tscn")
	else:
		_show_error("Failed to write design to scratch slot.")

func _on_test_pressed():
	# Save the selected blueprint to the scratch slot for the arena to pick up
	if _selected_entry.is_empty():
		return
	var path: String = _selected_entry.get("path", "")
	var data = blueprint_manager.load_blueprint(path)
	if data.is_empty():
		return
	data["pending_lab_restore"] = false
	var json_string = JSON.stringify(data, "\t")
	var f = FileAccess.open(BlueprintManagerScript.SCRATCH_PATH, FileAccess.WRITE)
	if f:
		f.store_string(json_string)
		f.close()
		# 2026-08-10: Battlefield.tscn retired; the Test Range now boots on
		# Battle.tscn via TestRangeLauncher. Same flow as stat_calculator's
		# "Test in Arena" button - the launcher writes a Test Range rule
		# set and routes through SceneRouter so the loading screen and fade
		# are still the same as every other launcher.
		var launcher = TestRangeLauncherScript.new()
		add_child(launcher)
		if not launcher.launch("blueprint_library"):
			launcher.queue_free()
			get_tree().change_scene_to_file("res://scenes/Battle.tscn")
	else:
		_show_error("Failed to write test scratch file.")

func _on_rename_pressed():
	if _selected_entry.is_empty():
		return
	var id: String = _selected_entry.get("id", "")
	var current_name: String = _selected_entry.get("name", "Untitled Design")
	var dialog = ConfirmationDialog.new()
	dialog.title = "Rename Blueprint"
	dialog.dialog_text = "New name:"
	add_child(dialog)
	var line_edit = LineEdit.new()
	line_edit.text = current_name if BlueprintManagerScript.is_named(current_name) else ""
	line_edit.custom_minimum_size = Vector2(300, 0)
	dialog.add_child(line_edit)
	dialog.confirmed.connect(func():
		blueprint_manager.rename_blueprint(id, line_edit.text)
		_refresh_list()
	)
	dialog.canceled.connect(func(): dialog.queue_free())
	dialog.confirmed.connect(func(): dialog.queue_free())
	dialog.popup_centered()
	line_edit.grab_focus()
	line_edit.select_all()

func _on_duplicate_pressed():
	if _selected_entry.is_empty():
		return
	var id: String = _selected_entry.get("id", "")
	blueprint_manager.duplicate_blueprint(id)
	_refresh_list()

func _on_delete_pressed():
	if _selected_entry.is_empty():
		return
	var id: String = _selected_entry.get("id", "")
	var display_name: String = _selected_entry.get("name", "Untitled Design")
	var confirm = ConfirmationDialog.new()
	confirm.dialog_text = "Permanently delete \"%s\"?" % display_name
	confirm.title = "Delete Blueprint"
	add_child(confirm)
	confirm.confirmed.connect(func():
		blueprint_manager.delete_blueprint(id)
		_refresh_list()
	)
	confirm.canceled.connect(func(): confirm.queue_free())
	confirm.confirmed.connect(func(): confirm.queue_free())
	confirm.popup_centered()

func _show_error(msg: String):
	var dialog = AcceptDialog.new()
	dialog.dialog_text = msg
	dialog.title = "Error"
	add_child(dialog)
	dialog.confirmed.connect(func(): dialog.queue_free())
	dialog.canceled.connect(func(): dialog.queue_free())
	dialog.popup_centered()

func _format_modified(unix_time: int) -> String:
	if unix_time <= 0: return "Unknown date"
	var dt = Time.get_datetime_dict_from_unix_time(unix_time)
	return "%04d-%02d-%02d %02d:%02d" % [dt.year, dt.month, dt.day, dt.hour, dt.minute]

func _prettify(id: String) -> String:
	if id == "": return "Unknown"
	var words = id.split("_")
	var out: Array = []
	for w in words:
		if w.length() > 0:
			out.append(w[0].to_upper() + w.substr(1))
	return " ".join(PackedStringArray(out))
