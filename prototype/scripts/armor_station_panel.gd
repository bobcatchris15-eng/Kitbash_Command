extends Control
# The Armor Station's LEFT-SIDE TOOLKIT. A permanent vertical panel that
# replaces the parts bin when the player enters the paint workspace.
#
# NOT A SEPARATE SCREEN. The MainLab scene is the only one the player
# ever sees for both build AND paint workflows. The toolbar's "ARMOR
# STATION" button plays a horizontal pan_blur sweep; behind that blur,
# three things swap simultaneously:
#   1. UI_PartsMenu hides, UI_ArmorStationPanel shows (this file)
#   2. LabEnvironment's cutting mat hides, PaintStationEnvironment's
#      wood desktop + paint supplies show
#   3. The module_placer ghosts the hull's modules (they stay attached
#      at 0.78 transparency) and accepts paint input on the hull instead
# The top toolbar button changes to "BACK TO WORKBENCH" to reverse all three.
#
# Modules USED to be stripped off entirely for painting; that amputated the
# design exactly when the player was deciding how armor wraps around it.
# The paint raycast masks to HullSurface.SURFACE_COLLISION_LAYER (16) and
# lab modules live on layer 2, so the strip never bought anything
# mechanical - ghosting keeps the full design (and the full stat rail,
# which keeps quoting real weight now that armor weighs) in view.

signal back_requested

const Tokens = preload("res://scripts/ui_tokens.gd")
const UITheme = preload("res://scripts/ui_theme.gd")
const UIFeedbackScript = preload("res://scripts/ui_feedback.gd")
const StampedLabelScript = preload("res://scripts/ui_stamped_label.gd")
const BlueprintManagerScript = preload("res://scripts/blueprint_manager.gd")
const ArmorPaint = preload("res://scripts/armor_paint.gd")
const ArmorPaintVisual = preload("res://scripts/armor_paint_visual.gd")
const HullFacets = preload("res://scripts/hull_facets.gd")
const HullSurface = preload("res://scripts/hull_surface.gd")
const ModuleCatalog = preload("res://scripts/module_catalog.gd")
const LiveryScript = preload("res://scripts/livery.gd")
const PanTransitionOverlayScript = preload("res://scripts/pan_transition.gd")

const ARMOR_TYPES := [
	"steel_plate",
	"ceramic_ablative",
	"ballistic_nylon",
	"composite_plate",
]

const ARMOR_TYPE_LABELS := {
	"steel_plate": "STEEL PLATE",
	"ceramic_ablative": "CERAMIC ABLATIVE",
	"ballistic_nylon": "BALLISTIC NYLON",
	"composite_plate": "COMPOSITE PLATE",
}

const ARMOR_TYPE_HINTS := {
	"steel_plate": "Rolled homogeneous steel plate. Reliable baseline kinetic protection.",
	"ceramic_ablative": "Dense ceramic tile matrix. High-temperature thermal ablation.",
	"ballistic_nylon": "High-tensile woven fiber weave. Lightweight structural reinforcement.",
	"composite_plate": "Thick layered composite with tessellated triangle bulges and divots.",
}

const PRESETS := {
	"FRONTAL": ["front"],
	"ALL-ROUND": ["front", "back", "left", "right", "top", "bottom"],
	"FLANKS": ["left", "right"],
	"TURTLE": ["front", "left", "right", "top"],
}

# The armor-map strip's button order: rows of opposed pairs in a 2-col grid.
const MAP_SIDES := ["front", "back", "left", "right", "top", "bottom"]

# Hover-preview tint per brush type. Chosen to read against the grey-green
# scale-model plastic without pretending to be the final finish - the real
# plate material is the shader's business, this is a targeting reticle.
const BRUSH_TINTS := {
	"steel_plate": Color(0.62, 0.70, 0.80, 0.45),
	"ceramic_ablative": Color(0.85, 0.72, 0.45, 0.45),
	"ballistic_nylon": Color(0.50, 0.65, 0.35, 0.45),
	"composite_plate": Color(0.45, 0.48, 0.42, 0.50),
}
const ERASE_TINT := Color(0.85, 0.25, 0.18, 0.45)

# Short codes for the armor map's cramped buttons.
const MATERIAL_ABBREV := {
	"steel_plate": "STL", "hardened_steel": "STL", "armor_plating": "STL",
	"titanium_plate": "TI", "slat_armor": "SLT",
	"composite_plate": "CMP", "reactive_armor": "CMP", "spaced_composite": "CMP",
	"ceramic_ablative": "CER", "ablative_ceramic": "CER", "ablative_foam": "CER",
	"ballistic_nylon": "NYL", "carbon_fiber": "NYL",
}

# External handles wired in by MainLab / the placer via enter()/exit().
var _hull: Node3D = null
var _placer: Node = null
var _bp_manager: Node = null

# Paint state
var _assignments: Dictionary = {}        # facet_id -> assignment dict
var _brush_armor_type: String = "steel_plate"
var _brush_thickness: float = 1.0
var _refine: bool = false                # false = whole side, true = one facet
var _erase: bool = false

var _ghosted_modules: Array = []

# Coverage labels
var _coverage_label: Label = null
var _weight_label: Label = null
var _status_label: Label = null

# Brush controls, kept as members so the eyedropper can set them back.
var _type_buttons := {}            # armor type id -> Button
var _thickness_slider: HSlider = null
var _type_hint: Label = null

# Armor map: side -> Button
var _map_buttons := {}

# Hover preview: a transient MeshInstance per facet under this holder,
# showing exactly what the current brush would lay down (same slab builder
# as the real skins, translucent). Rebuilt only when the hovered
# facet/side or the brush changes, not per mouse-motion event.
var _hover_holder: Node3D = null
var _hover_key := ""

# Public state
var is_paint_mode: bool = false


func _ready() -> void:
	set_anchors_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE


func enter(hull: Node3D, placer: Node) -> void:
	_hull = hull
	_placer = placer
	_bp_manager = get_node_or_null("/root/MainLab/BlueprintManager")
	is_paint_mode = true
	if _placer and "paint_mode_active" in _placer:
		_placer.paint_mode_active = true
	if _placer and _placer.has_method("capture_modules_for_paint"):
		_ghosted_modules = _placer.capture_modules_for_paint()
	if _placer and _placer.has_method("ghost_modules_for_paint"):
		_placer.ghost_modules_for_paint(_ghosted_modules)
	if _hull:
		var mesh_instance := _find_hull_mesh(_hull)
		if mesh_instance and mesh_instance.mesh:
			HullFacets.cached_segment(mesh_instance.mesh)
		for a in _hull.get_meta("armor_assignments", []):
			if a is Dictionary:
				_assignments[int(a.get("facet_id", -1))] = a
	_hover_key = ""
	_refresh_readout()
	var toolbar = get_tree().get_first_node_in_group("lab_toolbar")
	if toolbar and toolbar.has_method("update_undo_redo_state"):
		toolbar.update_undo_redo_state()


func exit() -> void:
	is_paint_mode = false
	if _placer and "paint_mode_active" in _placer:
		_placer.paint_mode_active = false
	_persist_assignments()
	if _placer and _placer.has_method("unghost_modules_after_paint"):
		_placer.unghost_modules_after_paint(_ghosted_modules)
	_ghosted_modules.clear()
	_clear_hover()
	if is_instance_valid(_hover_holder):
		if _hover_holder.get_parent():
			_hover_holder.get_parent().remove_child(_hover_holder)
		_hover_holder.free()
		_hover_holder = null
	_hover_key = ""
	_hull = null
	_placer = null
	var toolbar = get_tree().get_first_node_in_group("lab_toolbar")
	if toolbar and toolbar.has_method("update_undo_redo_state"):
		toolbar.update_undo_redo_state()


func sync_from_hull() -> void:
	_assignments.clear()
	if _hull:
		for a in _hull.get_meta("armor_assignments", []):
			if a is Dictionary:
				_assignments[int(a.get("facet_id", -1))] = a
	_refresh_readout()


func _unhandled_input(event: InputEvent) -> void:
	if not is_paint_mode:
		return
	if event is InputEventMouseMotion:
		# Hover preview only; never consumed, so camera orbit still works.
		_update_hover(event.position)
		return
	if event is InputEventMouseButton:
		if event.button_index == MOUSE_BUTTON_LEFT and event.pressed:
			# Alt+LMB is the eyedropper (RMB orbits the camera, MMB pans).
			if event.alt_pressed:
				_pick_from_world(event.position)
			else:
				_paint_at_world(event.position)
			get_viewport().set_input_as_handled()


# --- Layout -----------------------------------------------------------------

var _built: bool = false
var _standalone_dock: Control = null


func build_into(parent: Control) -> void:
	if _built:
		return
	_built = true
	var inner := VBoxContainer.new()
	inner.name = "ArmorControls"
	inner.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	inner.add_theme_constant_override("separation", Tokens.SPACE_SM)
	parent.add_child(inner)
	_build_inner_controls(inner)


func _build_dock() -> void:
	if _built:
		return
	_built = true
	var dock := PanelContainer.new()
	dock.theme_type_variation = "WoodPanel"
	UITheme.apply_material(dock, "wood")

	var dlc := Control.new()
	dlc.name = "StandaloneArmorDock"
	dlc.set_anchors_preset(Control.PRESET_TOP_LEFT)
	dlc.offset_left = 20.0
	dlc.offset_top = 76.0
	dlc.offset_right = 340.0
	dlc.offset_bottom = 0.0
	dlc.anchor_bottom = 1.0
	dlc.add_child(dock)
	add_child(dlc)
	_standalone_dock = dlc

	var inner := VBoxContainer.new()
	inner.add_theme_constant_override("separation", Tokens.SPACE_SM)
	dock.add_child(inner)
	_build_inner_controls(inner)


func _build_inner_controls(inner: VBoxContainer) -> void:
	# Section: brush mode & erase
	inner.add_child(_section_label("BRUSH"))
	var mode_well := PanelContainer.new()
	mode_well.add_theme_stylebox_override("panel", _stylebox_flat(Tokens.BASE_900, Tokens.BASE_700, 1, 4, 4, 4))
	inner.add_child(mode_well)

	var mode_row := HBoxContainer.new()
	mode_row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	mode_row.add_theme_constant_override("separation", Tokens.SPACE_XS)
	mode_well.add_child(mode_row)

	var side_btn := Button.new()
	side_btn.text = "SIDE"
	side_btn.toggle_mode = true
	side_btn.button_pressed = not _refine
	side_btn.custom_minimum_size = Vector2(0, 28)
	side_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_style_button(side_btn, Tokens.BASE_800, Tokens.BASE_600, Tokens.BASE_600, Tokens.SIGNAL_HAZARD, 12)
	UIFeedbackScript.wire(side_btn)
	mode_row.add_child(side_btn)

	var facet_btn := Button.new()
	facet_btn.text = "FACET"
	facet_btn.toggle_mode = true
	facet_btn.button_pressed = _refine
	facet_btn.custom_minimum_size = Vector2(0, 28)
	facet_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_style_button(facet_btn, Tokens.BASE_800, Tokens.BASE_600, Tokens.BASE_600, Tokens.SIGNAL_HAZARD, 12)
	UIFeedbackScript.wire(facet_btn)
	mode_row.add_child(facet_btn)

	var erase := Button.new()
	erase.text = "ERASE"
	erase.toggle_mode = true
	erase.button_pressed = _erase
	erase.custom_minimum_size = Vector2(0, 28)
	erase.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_style_button(erase, Tokens.BASE_800, Tokens.BASE_600, Color(0.28, 0.10, 0.08), Tokens.SIGNAL_ALERT, 12)
	UIFeedbackScript.wire(erase)
	mode_row.add_child(erase)

	side_btn.pressed.connect(func():
		_refine = false
		_hover_key = ""
		side_btn.button_pressed = true
		facet_btn.button_pressed = false)
	facet_btn.pressed.connect(func():
		_refine = true
		_hover_key = ""
		facet_btn.button_pressed = true
		side_btn.button_pressed = false)
	erase.toggled.connect(func(p: bool):
		_erase = p
		_hover_key = "")

	# Section: armor type
	inner.add_child(_section_label("ARMOR TYPE"))
	inner.add_child(_swatch_grid(ARMOR_TYPES, ARMOR_TYPE_LABELS,
		func(id: String):
			_brush_armor_type = id
			_type_hint.text = str(ARMOR_TYPE_HINTS.get(id, ""))
			_hover_key = "",
		func(): return _brush_armor_type,
		_type_buttons))
		
	var hint_well := PanelContainer.new()
	hint_well.add_theme_stylebox_override("panel", _stylebox_flat(Tokens.BASE_900, Tokens.BASE_700, 1, 3, 6, 6))
	_type_hint = Label.new()
	_type_hint.add_theme_font_size_override("font_size", 11)
	_type_hint.add_theme_color_override("font_color", Tokens.TEXT_SECONDARY)
	_type_hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_type_hint.text = str(ARMOR_TYPE_HINTS.get(_brush_armor_type, ""))
	hint_well.add_child(_type_hint)
	inner.add_child(hint_well)

	# Section: thickness
	inner.add_child(_section_label("THICKNESS"))
	var thick_well := PanelContainer.new()
	thick_well.add_theme_stylebox_override("panel", _stylebox_flat(Tokens.BASE_900, Tokens.BASE_700, 1, 4, 6, 4))
	inner.add_child(thick_well)
	
	var thick_row := HBoxContainer.new()
	thick_row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	thick_row.add_theme_constant_override("separation", Tokens.SPACE_SM)
	thick_well.add_child(thick_row)
	
	_thickness_slider = HSlider.new()
	_thickness_slider.min_value = 0.5
	_thickness_slider.max_value = 3.0
	_thickness_slider.step = 0.25
	_thickness_slider.value = _brush_thickness
	_thickness_slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_thickness_slider.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	_thickness_slider.tooltip_text = "Plate thickness - real geometry on the hull and real weight in the drivetrain"
	thick_row.add_child(_thickness_slider)
	
	var thick_badge := PanelContainer.new()
	thick_badge.add_theme_stylebox_override("panel", _stylebox_flat(Tokens.BASE_800, Tokens.BASE_600, 1, 3, 6, 2))
	var thick_val := Label.new()
	thick_val.text = "%.2fx" % _brush_thickness
	thick_val.add_theme_font_size_override("font_size", 12)
	thick_val.add_theme_color_override("font_color", Tokens.SIGNAL_HAZARD)
	thick_badge.add_child(thick_val)
	thick_row.add_child(thick_badge)
	
	_thickness_slider.value_changed.connect(func(v: float):
		_brush_thickness = v
		thick_val.text = "%.2fx" % v
		_hover_key = "")

	# Section: schemes (Presets)
	inner.add_child(_section_label("SCHEMES"))
	var preset_well := PanelContainer.new()
	preset_well.add_theme_stylebox_override("panel", _stylebox_flat(Tokens.BASE_900, Tokens.BASE_700, 1, 4, 4, 4))
	inner.add_child(preset_well)

	var preset_vbox := VBoxContainer.new()
	preset_vbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	preset_vbox.add_theme_constant_override("separation", Tokens.SPACE_XS)
	preset_well.add_child(preset_vbox)

	var preset_grid := GridContainer.new()
	preset_grid.columns = 2
	preset_grid.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	preset_grid.add_theme_constant_override("h_separation", Tokens.SPACE_XS)
	preset_grid.add_theme_constant_override("v_separation", Tokens.SPACE_XS)
	preset_vbox.add_child(preset_grid)

	var preset_buttons: Array = []
	for name in PRESETS.keys():
		var b := Button.new()
		b.text = str(name)
		b.custom_minimum_size = Vector2(0, 32)
		b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		b.toggle_mode = true
		_style_button(b, Tokens.BASE_800, Tokens.BASE_500, Tokens.BASE_600, Tokens.SIGNAL_HAZARD, 12)
		UIFeedbackScript.wire(b)
		preset_grid.add_child(b)
		preset_buttons.append(b)
		b.pressed.connect(func():
			_on_preset(str(name))
			for other in preset_buttons:
				other.button_pressed = (other == b))

	var strip_all := Button.new()
	strip_all.text = "STRIP ALL ARMOR"
	strip_all.custom_minimum_size = Vector2(0, 30)
	strip_all.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_style_button(strip_all, Tokens.BASE_800, Color(0.55, 0.22, 0.18), Color(0.35, 0.12, 0.10), Tokens.SIGNAL_ALERT, 12)
	strip_all.add_theme_color_override("font_color", Color(0.95, 0.55, 0.50))
	UIFeedbackScript.wire(strip_all)
	strip_all.pressed.connect(func():
		if _placer and _placer.has_method("push_armor_undo_snapshot"):
			_placer.push_armor_undo_snapshot()
		_assignments.clear()
		for b in preset_buttons:
			b.button_pressed = false
		_apply_and_refresh("Stripped all armor."))
	preset_vbox.add_child(strip_all)

	# Section: armor map
	inner.add_child(_section_label("ARMOR MAP"))
	var map_well := PanelContainer.new()
	map_well.add_theme_stylebox_override("panel", _stylebox_flat(Tokens.BASE_900, Tokens.BASE_700, 1, 4, 4, 4))
	inner.add_child(map_well)

	var map_vbox := VBoxContainer.new()
	map_vbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	map_vbox.add_theme_constant_override("separation", Tokens.SPACE_XS)
	map_well.add_child(map_vbox)

	var cov_bar := HBoxContainer.new()
	cov_bar.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	map_vbox.add_child(cov_bar)

	var cov_title := Label.new()
	cov_title.text = "COVERAGE"
	cov_title.add_theme_font_size_override("font_size", 11)
	cov_title.add_theme_color_override("font_color", Tokens.TEXT_SECONDARY)
	cov_bar.add_child(cov_title)

	var cov_spacer := Control.new()
	cov_spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	cov_bar.add_child(cov_spacer)

	_coverage_label = Label.new()
	_coverage_label.text = "0%"
	_coverage_label.add_theme_font_size_override("font_size", 12)
	_coverage_label.add_theme_color_override("font_color", Tokens.SIGNAL_HAZARD)
	cov_bar.add_child(_coverage_label)

	var map_grid := GridContainer.new()
	map_grid.columns = 2
	map_grid.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	map_grid.add_theme_constant_override("h_separation", Tokens.SPACE_XS)
	map_grid.add_theme_constant_override("v_separation", Tokens.SPACE_XS)
	map_vbox.add_child(map_grid)

	for s in MAP_SIDES:
		var b := Button.new()
		b.text = s.to_upper()
		b.custom_minimum_size = Vector2(0, 36)
		b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		_style_button(b, Tokens.BASE_800, Tokens.BASE_600, Tokens.BASE_700, Tokens.SIGNAL_HAZARD, 11)
		UIFeedbackScript.wire(b)
		b.tooltip_text = "Apply current brush to %s." % s
		b.pressed.connect(_on_map_side.bind(str(s)))
		_map_buttons[str(s)] = b
		map_grid.add_child(b)

	# Footer info
	var footer_well := PanelContainer.new()
	footer_well.add_theme_stylebox_override("panel", _stylebox_flat(Tokens.BASE_900, Tokens.BASE_700, 1, 3, 6, 6))
	inner.add_child(footer_well)

	var footer_vbox := VBoxContainer.new()
	footer_vbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	footer_vbox.add_theme_constant_override("separation", 2)
	footer_well.add_child(footer_vbox)

	_weight_label = Label.new()
	_weight_label.add_theme_font_size_override("font_size", 12)
	_weight_label.add_theme_color_override("font_color", Tokens.SIGNAL_GO)
	footer_vbox.add_child(_weight_label)

	_status_label = Label.new()
	_status_label.add_theme_font_size_override("font_size", 11)
	_status_label.add_theme_color_override("font_color", Tokens.TEXT_SECONDARY)
	_status_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	footer_vbox.add_child(_status_label)

	var controls_hint := Label.new()
	controls_hint.add_theme_font_size_override("font_size", 10)
	controls_hint.add_theme_color_override("font_color", Tokens.BASE_400)
	controls_hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	controls_hint.text = "LMB: Paint • Alt+LMB: Pick • RMB: Orbit"
	footer_vbox.add_child(controls_hint)


func _stylebox_flat(bg: Color, border: Color, border_w: int = 1, radius: int = 3, pad_h: int = 6, pad_v: int = 4) -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = bg
	sb.border_color = border
	sb.set_border_width_all(border_w)
	sb.corner_radius_top_left = radius
	sb.corner_radius_top_right = radius
	sb.corner_radius_bottom_left = radius
	sb.corner_radius_bottom_right = radius
	sb.content_margin_left = pad_h
	sb.content_margin_right = pad_h
	sb.content_margin_top = pad_v
	sb.content_margin_bottom = pad_v
	return sb


func _style_button(btn: Button, normal_bg: Color = Tokens.BASE_800, normal_border: Color = Tokens.BASE_600,
		active_bg: Color = Tokens.BASE_700, active_border: Color = Tokens.SIGNAL_HAZARD,
		font_sz: int = 12) -> void:
	btn.focus_mode = Control.FOCUS_NONE
	btn.add_theme_font_size_override("font_size", font_sz)
	btn.add_theme_color_override("font_color", Tokens.TEXT_PRIMARY)
	btn.add_theme_color_override("font_hover_color", Color.WHITE)
	btn.add_theme_color_override("font_pressed_color", Tokens.SIGNAL_HAZARD)
	btn.add_theme_color_override("font_focus_color", Tokens.TEXT_PRIMARY)
	
	var sb_norm := _stylebox_flat(normal_bg, normal_border, 1, 3, 6, 4)
	var sb_hover := _stylebox_flat(Tokens.BASE_700, Tokens.BASE_400, 1, 3, 6, 4)
	var sb_press := _stylebox_flat(active_bg, active_border, 2, 3, 6, 4)
	var sb_dis := _stylebox_flat(Tokens.BASE_900, Tokens.BASE_700, 1, 3, 6, 4)
	
	btn.add_theme_stylebox_override("normal", sb_norm)
	btn.add_theme_stylebox_override("hover", sb_hover)
	btn.add_theme_stylebox_override("pressed", sb_press)
	btn.add_theme_stylebox_override("focus", sb_norm)
	btn.add_theme_stylebox_override("disabled", sb_dis)


func _section_label(text: String) -> Control:
	var container := HBoxContainer.new()
	container.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	container.add_theme_constant_override("separation", Tokens.SPACE_XS)
	
	var l := Label.new()
	l.text = text
	l.add_theme_font_size_override("font_size", 12)
	l.add_theme_color_override("font_color", Tokens.SIGNAL_HAZARD)
	container.add_child(l)
	
	var sep := HSeparator.new()
	sep.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	sep.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	var sep_style := StyleBoxLine.new()
	sep_style.color = Tokens.BASE_600
	sep_style.thickness = 1
	sep.add_theme_stylebox_override("separator", sep_style)
	container.add_child(sep)
	
	return container


func _swatch_grid(ids: Array, labels: Dictionary, on_pick: Callable, get_current: Callable,
		register: Dictionary = {}) -> Control:
	var well := PanelContainer.new()
	well.add_theme_stylebox_override("panel", _stylebox_flat(Tokens.BASE_900, Tokens.BASE_700, 1, 4, 4, 4))
	var grid := GridContainer.new()
	grid.columns = 2
	grid.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	grid.add_theme_constant_override("h_separation", Tokens.SPACE_XS)
	grid.add_theme_constant_override("v_separation", Tokens.SPACE_XS)
	well.add_child(grid)
	var buttons := []
	for id in ids:
		var b := Button.new()
		b.text = str(labels.get(id, id))
		b.toggle_mode = true
		b.button_pressed = (str(id) == str(get_current.call()))
		b.custom_minimum_size = Vector2(0, 30)
		b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		_style_button(b, Tokens.BASE_800, Tokens.BASE_600, Tokens.BASE_600, Tokens.SIGNAL_HAZARD, 11)
		UIFeedbackScript.wire(b)
		grid.add_child(b)
		buttons.append(b)
		register[str(id)] = b
		b.pressed.connect(func():
			on_pick.call(str(id))
			for other in buttons:
				other.button_pressed = (other == b))
	return well


# --- Paint logic ------------------------------------------------------------

func _paint_at_world(screen_pos: Vector2) -> void:
	if not is_instance_valid(_hull):
		return
	var fid := _raycast_facet(screen_pos)
	if fid < 0:
		return
	var mesh_instance := _find_hull_mesh(_hull)
	if mesh_instance == null or mesh_instance.mesh == null:
		return

	if _placer and _placer.has_method("push_armor_undo_snapshot"):
		_placer.push_armor_undo_snapshot()

	if _refine:
		_paint_facet(fid)
		_apply_and_refresh("%s facet %d." % ["Stripped" if _erase else "Painted", fid])
	else:
		var seg := HullFacets.cached_segment(mesh_instance.mesh)
		var facet_sides = seg.get("facet_side", [])
		var side := str(facet_sides[fid]) if fid < facet_sides.size() else ""
		if side == "":
			return
		for f in HullFacets.facets_for_side_mesh(mesh_instance.mesh, side):
			_paint_facet(int(f))
		_apply_and_refresh("%s the %s." % ["Stripped" if _erase else "Painted", side])


func _paint_facet(fid: int) -> void:
	if _erase:
		_assignments.erase(fid)
		return
	if not is_instance_valid(_hull):
		return
	var mesh_instance := _find_hull_mesh(_hull)
	if mesh_instance == null or mesh_instance.mesh == null:
		return
	var seg := HullFacets.cached_segment(mesh_instance.mesh)
	var normals: PackedVector3Array = seg.get("normal", PackedVector3Array())
	var centroids: PackedVector3Array = seg.get("centroid", PackedVector3Array())
	var areas: PackedFloat32Array = seg.get("area", PackedFloat32Array())
	var facet_sides = seg.get("facet_side", [])
	if fid < 0 or fid >= normals.size():
		return
	_assignments[fid] = {
		"facet_id": fid,
		"side": str(facet_sides[fid]) if fid < facet_sides.size() else "",
		"type_id": _brush_armor_type,
		"material": _brush_armor_type,
		"thickness": _brush_thickness,
		"normal": {"x": normals[fid].x, "y": normals[fid].y, "z": normals[fid].z},
		"centroid": {"x": centroids[fid].x, "y": centroids[fid].y, "z": centroids[fid].z},
		"area": float(areas[fid]) if fid < areas.size() else 0.0,
	}


func _on_preset(name: String) -> void:
	if not is_instance_valid(_hull):
		return
	var mesh_instance := _find_hull_mesh(_hull)
	if mesh_instance == null or mesh_instance.mesh == null:
		return
	var mesh := mesh_instance.mesh
	if _placer and _placer.has_method("push_armor_undo_snapshot"):
		_placer.push_armor_undo_snapshot()
	for side in PRESETS.get(name, []):
		for fid in HullFacets.facets_for_side_mesh(mesh, str(side)):
			_paint_facet(int(fid))
	_apply_and_refresh("Applied the %s scheme." % name)


func _apply_and_refresh(status: String = "") -> void:
	if not is_instance_valid(_hull):
		return
	var mesh_instance := _find_hull_mesh(_hull)
	var mesh := mesh_instance.mesh if mesh_instance else null
	var xform := mesh_instance.transform if mesh_instance else Transform3D.IDENTITY
	var rows := _assignments.values()
	if mesh_instance:
		_hull.set_meta("armor_assignments", rows)
		_hull.set_meta("armor_plan", ArmorPaint.build_plan(
			"", rows, mesh, xform, LiveryScript.PLAYER_ID))
		ArmorPaintVisual.rebuild(_hull, mesh_instance)
	_persist_assignments()
	_refresh_readout()
	# The plan under the cursor just changed; let the next motion event
	# rebuild the preview against it.
	_hover_key = ""
	_update_hover(get_viewport().get_mouse_position())
	if status != "":
		_set_status(status)


# --- Hover preview & eyedropper ---------------------------------------------
#
# The preview is the same slab HullFacets.build_plate() would emit for a real
# assignment, in a translucent tint, so what you see hovering IS what clicking
# lays down - pattern, footprint and, since 2026-08-25, real thickness.

func _raycast_facet(screen_pos: Vector2) -> int:
	if not is_instance_valid(_hull):
		return -1
	var camera := get_viewport().get_camera_3d()
	if camera == null:
		return -1
	var from := camera.project_ray_origin(screen_pos)
	var to := from + camera.project_ray_normal(screen_pos) * 200.0
	var space := get_viewport().get_world_3d().direct_space_state
	var q := PhysicsRayQueryParameters3D.create(from, to)
	q.collision_mask = HullSurface.SURFACE_COLLISION_LAYER
	var hit := space.intersect_ray(q)
	if hit.is_empty():
		return -1
	var mesh_instance := _find_hull_mesh(_hull)
	if mesh_instance == null or mesh_instance.mesh == null:
		return -1
	return HullFacets.facet_for_tri(mesh_instance.mesh, int(hit.get("face_index", -1)))


func _update_hover(screen_pos: Vector2) -> void:
	if not is_paint_mode or not is_instance_valid(_hull):
		return
	var key := ""
	var fids := PackedInt32Array()
	var fid := _raycast_facet(screen_pos)
	if fid >= 0:
		var mesh_instance := _find_hull_mesh(_hull)
		if mesh_instance and mesh_instance.mesh:
			if _refine:
				key = "f:%d" % fid
				fids.append(fid)
			else:
				var seg := HullFacets.cached_segment(mesh_instance.mesh)
				var facet_sides = seg.get("facet_side", [])
				var side := str(facet_sides[fid]) if fid < facet_sides.size() else ""
				if side != "":
					key = "s:" + side
					fids = HullFacets.facets_for_side_mesh(mesh_instance.mesh, side)
	if key == _hover_key:
		return
	_hover_key = key
	_rebuild_hover(fids)


func _rebuild_hover(fids: PackedInt32Array) -> void:
	_clear_hover()
	if fids.is_empty() or not is_instance_valid(_hull):
		return
	var mesh_instance := _find_hull_mesh(_hull)
	if mesh_instance == null or mesh_instance.mesh == null:
		return
	if _hover_holder == null:
		_hover_holder = Node3D.new()
		_hover_holder.name = "ArmorHoverPreview"
		_hull.add_child(_hover_holder)
	var tint: Color = ERASE_TINT if _erase else BRUSH_TINTS.get(_brush_armor_type, Color(1, 1, 1, 0.4))
	var mat := StandardMaterial3D.new()
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.albedo_color = tint
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	for fid in fids:
		var frame := HullFacets.facet_frame("", int(fid), mesh_instance.transform, mesh_instance.mesh)
		if not bool(frame.get("valid", false)):
			continue
		# Erase previews the footprint, not a slab - thickness is irrelevant
		# when the result is bare hull.
		var thickness := 0.0 if _erase else _brush_thickness
		var mesh := HullFacets.build_plate(mesh_instance, "", int(fid), _brush_armor_type,
			Vector3.ONE, frame["center"], frame["basis"], _brush_armor_type, thickness)
		if mesh == null:
			continue
		var inst := MeshInstance3D.new()
		inst.name = "Hover_%d" % int(fid)
		inst.mesh = mesh
		inst.transform = Transform3D(frame["basis"], frame["center"])
		inst.material_override = mat
		_hover_holder.add_child(inst)


func _clear_hover() -> void:
	if is_instance_valid(_hover_holder):
		# Immediate remove+free, not queue_free: _rebuild_hover adds the new
		# "Hover_%d" instances in the same frame, and queued-for-deletion
		# children would still occupy those names until frame end.
		for c in _hover_holder.get_children():
			_hover_holder.remove_child(c)
			c.free()


# The eyedropper: load the brush with whatever the hovered facet already
# carries, so "match the plating next door" is one click.
func _pick_from_world(screen_pos: Vector2) -> void:
	var fid := _raycast_facet(screen_pos)
	if fid < 0:
		return
	if not _assignments.has(fid):
		_set_status("Facet %d is bare hull." % fid)
		return
	var a: Dictionary = _assignments[fid]
	_brush_armor_type = str(a.get("type_id", _brush_armor_type))
	_brush_thickness = float(a.get("thickness", 1.0))
	for id in _type_buttons.keys():
		(_type_buttons[id] as Button).button_pressed = (str(id) == _brush_armor_type)
	if _type_hint:
		_type_hint.text = str(ARMOR_TYPE_HINTS.get(_brush_armor_type, ""))
	if _thickness_slider:
		# Emits value_changed, which refreshes the label and brush var.
		_thickness_slider.value = _brush_thickness
	_hover_key = ""
	_update_hover(screen_pos)
	_set_status("Picked up %s at %.2fx." % [
		str(ARMOR_TYPE_LABELS.get(_brush_armor_type, _brush_armor_type)), _brush_thickness])


# --- Armor map ---------------------------------------------------------------

# One click applies the current brush to the whole side - the same stroke as
# clicking the hull with the SIDE brush, but available for faces the camera
# can't see (back, bottom) without orbiting.
func _on_map_side(side: String) -> void:
	if not is_instance_valid(_hull):
		return
	var mesh_instance := _find_hull_mesh(_hull)
	if mesh_instance == null or mesh_instance.mesh == null:
		return
	if _placer and _placer.has_method("push_armor_undo_snapshot"):
		_placer.push_armor_undo_snapshot()
	for fid in HullFacets.facets_for_side_mesh(mesh_instance.mesh, side):
		_paint_facet(int(fid))
	_apply_and_refresh("%s the %s." % ["Stripped" if _erase else "Painted", side])


func _mat_abbrev(material: String) -> String:
	return str(MATERIAL_ABBREV.get(material, material.substr(0, 3).to_upper()))


func _persist_assignments() -> void:
	if not is_instance_valid(_hull):
		return
	_hull.set_meta("armor_assignments", _assignments.values())
	var main_lab = get_parent()
	if is_instance_valid(main_lab):
		var rail: Control = main_lab.get_node_or_null("UI_StatBlock")
		if is_instance_valid(rail):
			rail.update_stats(_hull)


func _refresh_readout() -> void:
	if not is_instance_valid(_hull):
		return
	var stats: Dictionary = ArmorPaint.analyze(_hull)
	if _coverage_label:
		_coverage_label.text = "%d%%" % int(round(float(stats["coverage"]) * 100.0))
	var plan: Dictionary = _hull.get_meta("armor_plan", {})
	var plan_sides: Dictionary = plan.get("sides", {})
	var weakest := str(stats["weakest_side"])
	for s in _map_buttons.keys():
		var b: Button = _map_buttons[s]
		var sd: Dictionary = plan_sides.get(s, {})
		var cov := float(sd.get("coverage", 0.0))
		var is_weakest: bool = (s == weakest and weakest != "")
		var marker := "> " if is_weakest else ""
		if cov <= 0.001:
			b.text = "%s%s\n- bare -" % [marker, s.to_upper()]
		else:
			b.text = "%s%s\n%d%% %s %.2fx" % [marker, s.to_upper(), int(round(cov * 100.0)),
				_mat_abbrev(str(sd.get("material", ""))), float(sd.get("mean_thickness", 0.0))]
		if is_weakest:
			b.add_theme_color_override("font_color", Tokens.SIGNAL_HAZARD)
		else:
			b.add_theme_color_override("font_color", Tokens.TEXT_PRIMARY)
	if _weight_label:
		_weight_label.text = "+%.0f kg   %d metal / %d crystal" % [
			float(stats["weight"]), int(stats["cost_metal"]), int(stats["cost_crystal"])]


func _set_status(msg: String) -> void:
	if _status_label:
		_status_label.text = msg


func _find_hull_mesh(hull: Node3D) -> MeshInstance3D:
	for c in hull.get_children():
		if c is MeshInstance3D and c.name != "PhysicsMesh":
			return c
	return null