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
		_hover_key = ""
		side_btn.button_pressed = true
		facet_btn.button_pressed = false)
	facet_btn.pressed.connect(func():
		_refine = true
		_hover_key = ""
		facet_btn.button_pressed = true
		side_btn.button_pressed = false)

	var erase := Button.new()
	erase.text = "ERASE"
	erase.toggle_mode = true
	erase.custom_minimum_size = Vector2(0, Tokens.HIT_TARGET_MIN)
	erase.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	UIFeedbackScript.wire(erase)
	erase.toggled.connect(func(p: bool):
		_erase = p
		_hover_key = "")
	mode_row.add_child(erase)

	# Section: armor type (consolidated)
	inner.add_child(_section_label("ARMOR TYPE"))
	_type_hint = Label.new()
	_type_hint.theme_type_variation = "HintLabel"
	_type_hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_type_hint.text = str(ARMOR_TYPE_HINTS.get(_brush_armor_type, ""))

	inner.add_child(_swatch_grid(ARMOR_TYPES, ARMOR_TYPE_LABELS,
		func(id: String):
			_brush_armor_type = id
			_type_hint.text = str(ARMOR_TYPE_HINTS.get(id, ""))
			_hover_key = "",
		func(): return _brush_armor_type,
		_type_buttons))
	inner.add_child(_type_hint)

	# Section: thickness
	inner.add_child(_section_label("THICKNESS"))
	var thick_row := HBoxContainer.new()
	thick_row.add_theme_constant_override("separation", Tokens.SPACE_SM)
	inner.add_child(thick_row)
	_thickness_slider = HSlider.new()
	_thickness_slider.min_value = 0.5
	_thickness_slider.max_value = 3.0
	_thickness_slider.step = 0.25
	_thickness_slider.value = _brush_thickness
	_thickness_slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_thickness_slider.tooltip_text = "Plate thickness - real geometry on the hull and real weight in the drivetrain"
	thick_row.add_child(_thickness_slider)
	var thick_val := Label.new()
	thick_val.text = "1.00x"
	thick_row.add_child(thick_val)
	_thickness_slider.value_changed.connect(func(v: float):
		_brush_thickness = v
		thick_val.text = "%.2fx" % v
		_hover_key = "")

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
		b.toggle_mode = true
		b.custom_minimum_size = Vector2(0, Tokens.HIT_TARGET_MIN)
		b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		b.theme_type_variation = "ListButton"
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
	inner.add_child(_section_label("ARMOR MAP"))
	_coverage_label = Label.new()
	_coverage_label.text = "ARMOR 0%"
	inner.add_child(_coverage_label)

	# Six side buttons, one per hull face. Each shows that side's weighted
	# coverage, dominant material and mean thickness - the plan at a glance,
	# including the back and bottom the camera can't see. Clicking applies
	# the current brush (or erase) to the whole side, same as clicking the
	# hull with the SIDE brush; the weakest side is marked ">".
	var map_grid := GridContainer.new()
	map_grid.columns = 2
	map_grid.add_theme_constant_override("h_separation", Tokens.SPACE_XS)
	map_grid.add_theme_constant_override("v_separation", Tokens.SPACE_XS)
	inner.add_child(map_grid)
	for s in MAP_SIDES:
		var b := Button.new()
		b.text = s.to_upper()
		b.custom_minimum_size = Vector2(0, Tokens.HIT_TARGET_MIN)
		b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		UIFeedbackScript.wire(b)
		b.tooltip_text = "Apply the current brush to the whole %s." % s
		b.pressed.connect(_on_map_side.bind(str(s)))
		_map_buttons[str(s)] = b
		map_grid.add_child(b)

	_weight_label = Label.new()
	_weight_label.theme_type_variation = "HintLabel"
	inner.add_child(_weight_label)

	_status_label = Label.new()
	_status_label.theme_type_variation = "HintLabel"
	_status_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	inner.add_child(_status_label)

	var controls_hint := Label.new()
	controls_hint.theme_type_variation = "HintLabel"
	controls_hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	controls_hint.text = "LMB paint. Alt+LMB pick the facet's type and thickness up. RMB orbits."
	inner.add_child(controls_hint)


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


func _swatch_grid(ids: Array, labels: Dictionary, on_pick: Callable, get_current: Callable,
		register: Dictionary = {}) -> Control:
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
		b.theme_type_variation = "ListButton"
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
	_coverage_label.text = "ARMOR %d%%" % int(round(float(stats["coverage"]) * 100.0))
	var plan: Dictionary = _hull.get_meta("armor_plan", {})
	var plan_sides: Dictionary = plan.get("sides", {})
	var weakest := str(stats["weakest_side"])
	for s in _map_buttons.keys():
		var b: Button = _map_buttons[s]
		var sd: Dictionary = plan_sides.get(s, {})
		var cov := float(sd.get("coverage", 0.0))
		var marker := "> " if s == weakest and weakest != "" else ""
		if cov <= 0.001:
			b.text = "%s%s\n- bare -" % [marker, s.to_upper()]
		else:
			b.text = "%s%s\n%d%% %s %.2fx" % [marker, s.to_upper(), int(round(cov * 100.0)),
				_mat_abbrev(str(sd.get("material", ""))), float(sd.get("mean_thickness", 0.0))]
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