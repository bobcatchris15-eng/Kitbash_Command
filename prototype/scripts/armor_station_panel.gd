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
#   3. The module_placer strips the hull's modules and accepts paint
#      input on the bare hull instead
# The top toolbar button changes to "BACK TO WORKBENCH" to reverse all three.

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

var _modules_before_strip: Array = []

# Coverage labels
var _coverage_label: Label = null
var _side_strip: Label = null
var _weight_label: Label = null
var _status_label: Label = null

# Public state
var is_paint_mode: bool = false


func _ready() -> void:
	set_anchors_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	_build_header()
	_build_dock()


func enter(hull: Node3D, placer: Node) -> void:
	_hull = hull
	_placer = placer
	_bp_manager = get_node_or_null("/root/MainLab/BlueprintManager")
	is_paint_mode = true
	if _placer and "paint_mode_active" in _placer:
		_placer.paint_mode_active = true
	if _placer and _placer.has_method("capture_modules_for_paint"):
		_modules_before_strip = _placer.capture_modules_for_paint()
	if _placer and _placer.has_method("strip_modules_for_paint"):
		_placer.strip_modules_for_paint(_modules_before_strip)
	if _hull:
		var mesh_instance := _find_hull_mesh(_hull)
		if mesh_instance and mesh_instance.mesh:
			HullFacets.cached_segment(mesh_instance.mesh)
		for a in _hull.get_meta("armor_assignments", []):
			if a is Dictionary:
				_assignments[int(a.get("facet_id", -1))] = a
	_refresh_readout()


func exit() -> void:
	is_paint_mode = false
	if _placer and "paint_mode_active" in _placer:
		_placer.paint_mode_active = false
	_persist_assignments()
	if _placer and _placer.has_method("restore_modules_after_paint"):
		_placer.restore_modules_after_paint(_modules_before_strip)
	_modules_before_strip.clear()
	_hull = null
	_placer = null


func _unhandled_input(event: InputEvent) -> void:
	if not is_paint_mode:
		return
	if event is InputEventMouseButton:
		if event.button_index == MOUSE_BUTTON_LEFT and event.pressed:
			_paint_at_world(event.position)
			get_viewport().set_input_as_handled()


# --- Layout -----------------------------------------------------------------

func _build_header() -> void:
	pass


func _build_dock() -> void:
	var dock := PanelContainer.new()
	dock.theme_type_variation = "WoodPanel"
	UITheme.apply_material(dock, "wood")

	var dlc := Control.new()
	dlc.set_anchors_preset(Control.PRESET_TOP_LEFT)
	dlc.offset_left = 20.0
	dlc.offset_top = 76.0
	dlc.offset_right = 340.0
	dlc.offset_bottom = 0.0
	dlc.anchor_bottom = 1.0
	dlc.add_child(dock)
	add_child(dlc)

	var inner := VBoxContainer.new()
	inner.add_theme_constant_override("separation", Tokens.SPACE_SM)
	dock.add_child(inner)

	# Section: brush mode & erase
	inner.add_child(_section_label("BRUSH"))
	var mode_row := HBoxContainer.new()
	mode_row.add_theme_constant_override("separation", Tokens.SPACE_XS)
	inner.add_child(mode_row)
	var side_btn := _toggle(mode_row, "SIDE", not _refine)
	var facet_btn := _toggle(mode_row, "FACET", _refine)
	side_btn.pressed.connect(func():
		_refine = false
		side_btn.button_pressed = true
		facet_btn.button_pressed = false)
	facet_btn.pressed.connect(func():
		_refine = true
		facet_btn.button_pressed = true
		side_btn.button_pressed = false)

	var erase := Button.new()
	erase.text = "ERASE"
	erase.toggle_mode = true
	erase.custom_minimum_size = Vector2(0, Tokens.HIT_TARGET_MIN)
	erase.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	UIFeedbackScript.wire(erase)
	erase.toggled.connect(func(p: bool): _erase = p)
	mode_row.add_child(erase)

	# Section: armor type (consolidated)
	inner.add_child(_section_label("ARMOR TYPE"))
	var type_hint := Label.new()
	type_hint.theme_type_variation = "HintLabel"
	type_hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	type_hint.text = str(ARMOR_TYPE_HINTS.get(_brush_armor_type, ""))

	inner.add_child(_swatch_grid(ARMOR_TYPES, ARMOR_TYPE_LABELS,
		func(id: String):
			_brush_armor_type = id
			type_hint.text = str(ARMOR_TYPE_HINTS.get(id, "")),
		func(): return _brush_armor_type))
	inner.add_child(type_hint)

	# Section: thickness
	inner.add_child(_section_label("THICKNESS"))
	var thick_row := HBoxContainer.new()
	thick_row.add_theme_constant_override("separation", Tokens.SPACE_SM)
	inner.add_child(thick_row)
	var thick := HSlider.new()
	thick.min_value = 0.5
	thick.max_value = 3.0
	thick.step = 0.25
	thick.value = _brush_thickness
	thick.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	thick_row.add_child(thick)
	var thick_val := Label.new()
	thick_val.text = "1.00x"
	thick_row.add_child(thick_val)
	thick.value_changed.connect(func(v: float):
		_brush_thickness = v
		thick_val.text = "%.2fx" % v)

	# Section: schemes
	inner.add_child(_section_label("SCHEMES"))
	var preset_grid := GridContainer.new()
	preset_grid.columns = 2
	preset_grid.add_theme_constant_override("h_separation", Tokens.SPACE_XS)
	preset_grid.add_theme_constant_override("v_separation", Tokens.SPACE_XS)
	inner.add_child(preset_grid)
	for name in PRESETS.keys():
		var b := Button.new()
		b.text = str(name)
		b.custom_minimum_size = Vector2(0, Tokens.HIT_TARGET_MIN)
		b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		UIFeedbackScript.wire(b)
		b.pressed.connect(_on_preset.bind(str(name)))
		preset_grid.add_child(b)

	var strip_all := Button.new()
	strip_all.text = "STRIP ALL ARMOR"
	strip_all.custom_minimum_size = Vector2(0, Tokens.HIT_TARGET_MIN)
	UIFeedbackScript.wire(strip_all)
	strip_all.pressed.connect(func():
		_assignments.clear()
		_apply_and_refresh("Stripped all armor."))
	inner.add_child(strip_all)

	inner.add_child(HSeparator.new())
	inner.add_child(_section_label("COVERAGE"))
	_coverage_label = Label.new()
	_coverage_label.text = "ARMOR 0%"
	inner.add_child(_coverage_label)
	_side_strip = Label.new()
	_side_strip.theme_type_variation = "HintLabel"
	_side_strip.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	inner.add_child(_side_strip)
	_weight_label = Label.new()
	_weight_label.theme_type_variation = "HintLabel"
	inner.add_child(_weight_label)

	_status_label = Label.new()
	_status_label.theme_type_variation = "HintLabel"
	_status_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	inner.add_child(_status_label)


func _section_label(text: String) -> Label:
	var l := Label.new()
	l.text = text
	l.theme_type_variation = "HeadingLabel"
	return l


func _toggle(parent: Control, text: String, on: bool) -> Button:
	var b := Button.new()
	b.text = text
	b.toggle_mode = true
	b.button_pressed = on
	b.custom_minimum_size = Vector2(0, Tokens.HIT_TARGET_MIN)
	b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	UIFeedbackScript.wire(b)
	parent.add_child(b)
	return b


func _swatch_grid(ids: Array, labels: Dictionary, on_pick: Callable, get_current: Callable) -> Control:
	var well := PanelContainer.new()
	well.theme_type_variation = "InsetPanel"
	var grid := GridContainer.new()
	grid.columns = 2
	grid.add_theme_constant_override("h_separation", Tokens.SPACE_XS)
	grid.add_theme_constant_override("v_separation", Tokens.SPACE_XS)
	well.add_child(grid)
	var buttons := []
	for id in ids:
		var b := Button.new()
		b.text = str(labels.get(id, id))
		b.toggle_mode = true
		b.button_pressed = (str(id) == str(get_current.call()))
		b.custom_minimum_size = Vector2(0, Tokens.HIT_TARGET_MIN)
		b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		UIFeedbackScript.wire(b)
		grid.add_child(b)
		buttons.append(b)
		b.pressed.connect(func():
			on_pick.call(str(id))
			for other in buttons:
				other.button_pressed = (other == b))
	return well


# --- Paint logic ------------------------------------------------------------

func _paint_at_world(screen_pos: Vector2) -> void:
	if not is_instance_valid(_hull):
		return
	var camera := get_viewport().get_camera_3d()
	if camera == null:
		return
	var from := camera.project_ray_origin(screen_pos)
	var to := from + camera.project_ray_normal(screen_pos) * 200.0
	var space := get_viewport().get_world_3d().direct_space_state
	var q := PhysicsRayQueryParameters3D.create(from, to)
	q.collision_mask = HullSurface.SURFACE_COLLISION_LAYER
	var hit := space.intersect_ray(q)
	if hit.is_empty():
		return
	var mesh_instance := _find_hull_mesh(_hull)
	if mesh_instance == null or mesh_instance.mesh == null:
		return
	var tri_index := int(hit.get("face_index", -1))
	var fid := HullFacets.facet_for_tri(mesh_instance.mesh, tri_index)
	if fid < 0:
		return

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
			"", rows, mesh, xform, str(_bp_manager.get_meta("player_faction", LiveryScript.PLAYER_ID) if _bp_manager else LiveryScript.PLAYER_ID)))
		ArmorPaintVisual.rebuild(_hull, mesh_instance)
	_persist_assignments()
	_refresh_readout()
	if status != "":
		_set_status(status)


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
	_coverage_label.text = "ARMOR %d%%" % int(round(float(stats["coverage"]) * 100.0))
	var parts := []
	for s in ArmorPaint.SIDES:
		parts.append("%s %d" % [s.substr(0, 1).to_upper(),
			int(round(float(stats["side_coverage"][s]) * 100.0))])
	var weakest := str(stats["weakest_side"])
	_side_strip.text = " · ".join(parts) + ("    weakest: %s" % weakest if weakest != "" else "")
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