extends Node3D

# ModularHullBuilder — Grid-based 3D vehicle hull authoring suite.
#
# Core features:
#   * Block Library: Cubes, 45° Wedges, Inner Corners, Outer Corners.
#   * Strict 3D Grid Snapping (1-unit increments) & 90° Step Rotation.
#   * Interactive 3D Transform Gizmo with X/Y/Z translation arrows and rotation rings.
#   * Spatial dictionary (Vector3i coordinate mapping) preventing overlaps and preparing for mesh merging.
#   * Proportional-only power-of-2 scaling (1x, 2x, 4x, 8x) via radial menu.
#   * CSG weld & mesh export to game library.

const CSGMeshBaker = preload("res://scripts/csg_mesh_baker.gd")
const HullLoader = preload("res://scripts/hull_loader.gd")
const MeshAssetLoader = preload("res://scripts/mesh_asset_loader.gd")
const BlockMeshes = preload("res://scripts/block_meshes.gd")
const UIRadialMenu = preload("res://scripts/ui_radial_menu.gd")
const UIIcons = preload("res://scripts/ui_icons.gd")
const Tokens = preload("res://scripts/ui_tokens.gd")
const StampedLabelScript = preload("res://scripts/ui_stamped_label.gd")
const RadialDial = preload("res://scripts/ui/radial_dial.gd")
const UIShell = preload("res://scripts/ui_shell.gd")
const UIFeedbackScript = preload("res://scripts/ui_feedback.gd")
const StampedButtonScript = preload("res://scripts/ui_stamped_button.gd")
const ModuleVolume = preload("res://scripts/module_volume.gd")

@export var max_blocks: int = 400
@export var grid_unit: float = 1.0  # 1-unit increments for strict grid snapping

enum BlockType {
	CUBE,
	WEDGE_45,
}

const BLOCK_MESH_NAMES := {
	BlockType.CUBE: "block_cube",
	BlockType.WEDGE_45: "block_wedge",
}

const ROT_STEP := PI / 2.0  # 90 degrees

# State
var blocks: Array = []
var selected_block: int = -1
var current_block_type: BlockType = BlockType.CUBE
var has_origin: bool = false

# Spatial occupancy dictionary: Vector3i (grid cell) -> block Dictionary
var _spatial_dict: Dictionary = {}

# Palette drag state
var is_dragging_from_palette: bool = false
var dragged_palette_type: BlockType = BlockType.CUBE
var preview_node: Node3D = null

# UI Nodes
@onready var hull_container:    Node3D        = $HullContainer

var _canvas_layer: CanvasLayer = null
var properties_panel:  VBoxContainer = null
var status_label:      Label         = null
var back_button:       Button        = null
var clear_button:      Button        = null
var export_button:     Button        = null
var save_btn:          Button        = null
var load_btn:          Button        = null
var _right_dock_outer: Control       = null

var palette_buttons: Array = []

# Gizmo state
var _gizmo_root: Node3D = null
var _gizmo_drag_handle = null
var _gizmo_drag_axis: Vector3 = Vector3.ZERO
var _gizmo_drag_local_axis: Vector3 = Vector3.ZERO
var _gizmo_drag_mode: String = ""  # "translate" | "rotate"
var _gizmo_drag_start_mouse: Vector2 = Vector2.ZERO
var _gizmo_drag_start_pos: Vector3 = Vector3.ZERO
var _gizmo_drag_start_coord: Vector3i = Vector3i.ZERO
var _gizmo_drag_start_rot: Vector3 = Vector3.ZERO
var _gizmo_drag_start_angle: float = 0.0

const GIZMO_LAYER := 4
const GIZMO_ROTATE_LAYER := 8

const COL_X := Color(0.96, 0.28, 0.32, 0.75)
const COL_Y := Color(0.38, 0.88, 0.32, 0.75)
const COL_Z := Color(0.28, 0.58, 0.98, 0.75)
const HIGHLIGHT_EMISSION := Color(0.20, 0.50, 0.95)

# Bilateral Symmetry
var symmetry_enabled: bool = true
const SYMMETRY_CENTRE_EPS := 0.01

enum AuthoringStage {
	STAGE_BUILD,      # Stage 1: Block Placement & Manipulation
	STAGE_FINISH,     # Stage 2: Mesh Welding & Hull Finalization
}

var current_stage: AuthoringStage = AuthoringStage.STAGE_BUILD
var hull_color: Color = Color(0.45, 0.48, 0.52, 1.0)
var _grid_floor: MeshInstance3D = null
var _forward_arrow: Node3D = null
var _preview_mesh_instance: MeshInstance3D = null

var block_defs: Array = [
	{"name": "Cube",      "type": BlockType.CUBE,     "icon": "prim_box",   "subtext": "1x1x1 (3-Axis Deform)", "tooltip": "Standard box brick. Deformable along X, Y, Z in 1-unit steps (1-8)"},
	{"name": "45° Wedge", "type": BlockType.WEDGE_45, "icon": "prim_wedge", "subtext": "45° Ramp (Width 1-8)",  "tooltip": "45-degree slope brick. Extendable laterally in steps of 2 (1, 2, 4, 8)"},
]

const LIP_WIDTH := 16.0
const GASKET_WIDTH := 6.0
const TOTAL_INSET := LIP_WIDTH + GASKET_WIDTH
const DOCK_WIDTH := 280.0
const DOCK_LEFT_INSET := 20.0
const DOCK_TOP_INSET := 70.0
const DOCK_BOTTOM_INSET := 50.0

var _palette_dock_outer: Control = null
var _palette_vbox: VBoxContainer = null

# ── Lifecycle ────────────────────────────────────────────────────────────────

func _ready() -> void:
	call_deferred("_setup_environment")

func _setup_environment() -> void:
	_setup_grid_floor()
	_setup_forward_arrow()
	_setup_preview_mesh()
	_build_ui_layout()

	_update_properties_panel()
	_update_status("MODULAR HULL BUILDER — Place blocks on the 1.0-unit 3D grid!")

func _setup_grid_floor() -> void:
	_grid_floor = MeshInstance3D.new()
	_grid_floor.name = "GridFloor"
	var plane := PlaneMesh.new()
	plane.size = Vector2(40.0, 40.0)
	plane.subdivide_width = 40
	plane.subdivide_depth = 40
	_grid_floor.mesh = plane

	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.2, 0.25, 0.35, 0.35)
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	_grid_floor.material_override = mat
	_grid_floor.position = Vector3(0, -grid_unit * 0.5, 0)
	hull_container.add_child(_grid_floor)

func _setup_forward_arrow() -> void:
	_forward_arrow = Node3D.new()
	hull_container.add_child(_forward_arrow)

	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.25, 0.95, 0.35)
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.no_depth_test = true
	mat.render_priority = 2

	var shaft := MeshInstance3D.new()
	var shaft_mesh := CylinderMesh.new()
	shaft_mesh.top_radius = 0.06
	shaft_mesh.bottom_radius = 0.06
	shaft_mesh.height = 1.2
	shaft_mesh.radial_segments = 12
	shaft.mesh = shaft_mesh
	shaft.material_override = mat
	shaft.rotation = Vector3(-PI / 2.0, 0, 0)
	shaft.position = Vector3(0, 0, -0.6)
	_forward_arrow.add_child(shaft)

	var head := MeshInstance3D.new()
	var head_mesh := CylinderMesh.new()
	head_mesh.top_radius = 0.0
	head_mesh.bottom_radius = 0.22
	head_mesh.height = 0.45
	head_mesh.radial_segments = 14
	head.mesh = head_mesh
	head.material_override = mat
	head.rotation = Vector3(-PI / 2.0, 0, 0)
	head.position = Vector3(0, 0, -1.4)
	_forward_arrow.add_child(head)

func _setup_preview_mesh() -> void:
	_preview_mesh_instance = MeshInstance3D.new()
	_preview_mesh_instance.visible = false
	var mat := StandardMaterial3D.new()
	mat.albedo_color = hull_color
	mat.metallic = 0.5
	mat.roughness = 0.35
	_preview_mesh_instance.material_override = mat
	hull_container.add_child(_preview_mesh_instance)

func _build_ui_layout() -> void:
	_canvas_layer = CanvasLayer.new()
	_canvas_layer.name = "CanvasLayer"
	add_child(_canvas_layer)

	# Shared 3D UI prop stage for StampedButtons
	UIShell.stage(_canvas_layer)

	# Top-left back button
	var back_btn := StampedButtonScript.new()
	back_btn.name = "BackButton"
	back_btn.text = "< BACK TO MENU"
	back_btn.custom_minimum_size = Vector2(170, 38)
	back_btn.position = Vector2(DOCK_LEFT_INSET, 16.0)
	UIFeedbackScript.wire(back_btn, "default")
	back_btn.pressed.connect(_on_back_clicked)
	_canvas_layer.add_child(back_btn)
	back_button = back_btn

	# Left Palette Dock
	_build_palette_dock()

	# Right Properties & Actions Dock
	_build_right_dock()

	# Bottom Status Bar
	_build_bottom_bar()

func _build_palette_dock() -> void:
	var outer := Control.new()
	outer.name = "BlockCatalogDock"
	outer.anchor_left = 0.0
	outer.anchor_top = 0.0
	outer.anchor_right = 0.0
	outer.anchor_bottom = 1.0
	outer.offset_left = DOCK_LEFT_INSET
	outer.offset_right = DOCK_LEFT_INSET + DOCK_WIDTH
	outer.offset_top = DOCK_TOP_INSET
	outer.offset_bottom = -DOCK_BOTTOM_INSET
	outer.mouse_filter = Control.MOUSE_FILTER_STOP
	_canvas_layer.add_child(outer)
	_palette_dock_outer = outer

	outer.gui_input.connect(func(event: InputEvent):
		if event is InputEventMouseButton:
			outer.accept_event()
		elif event is InputEventMouseMotion and not get_viewport().gui_is_dragging():
			outer.accept_event()
	)

	var steel_lip := Panel.new()
	steel_lip.name = "SteelLip"
	steel_lip.set_anchors_preset(Control.PRESET_FULL_RECT)
	steel_lip.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var lip_style := StyleBoxFlat.new()
	lip_style.bg_color = Color.WHITE
	lip_style.corner_radius_top_left = 5
	lip_style.corner_radius_top_right = 5
	lip_style.corner_radius_bottom_left = 8
	lip_style.corner_radius_bottom_right = 8
	lip_style.border_width_top = 3
	lip_style.border_color = Tokens.BASE_500
	lip_style.set_content_margin_all(0)
	steel_lip.add_theme_stylebox_override("panel", lip_style)
	UITheme.apply_material(steel_lip, "steel", {"brightness": 0.62, "grime": 0.40})
	outer.add_child(steel_lip)

	var gasket := Panel.new()
	gasket.name = "RubberGasket"
	gasket.anchor_left = 0.0
	gasket.anchor_top = 0.0
	gasket.anchor_right = 1.0
	gasket.anchor_bottom = 1.0
	gasket.offset_left = LIP_WIDTH
	gasket.offset_top = LIP_WIDTH
	gasket.offset_right = -LIP_WIDTH
	gasket.offset_bottom = -LIP_WIDTH
	gasket.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var gasket_style := StyleBoxFlat.new()
	gasket_style.bg_color = Tokens.BASE_900
	gasket_style.corner_radius_top_left = 3
	gasket_style.corner_radius_top_right = 3
	gasket_style.corner_radius_bottom_left = 5
	gasket_style.corner_radius_bottom_right = 5
	gasket_style.set_content_margin_all(0)
	gasket.add_theme_stylebox_override("panel", gasket_style)
	var gasket_mat := ShaderMaterial.new()
	gasket_mat.shader = preload("res://shaders/rubber_gasket.gdshader")
	gasket.material = gasket_mat
	outer.add_child(gasket)

	var body := PanelContainer.new()
	body.name = "ToolboxBody"
	body.anchor_left = 0.0
	body.anchor_top = 0.0
	body.anchor_right = 1.0
	body.anchor_bottom = 1.0
	body.offset_left = TOTAL_INSET
	body.offset_top = TOTAL_INSET
	body.offset_right = -TOTAL_INSET
	body.offset_bottom = -TOTAL_INSET
	body.mouse_filter = Control.MOUSE_FILTER_STOP
	var body_style := StyleBoxFlat.new()
	body_style.bg_color = Color.WHITE
	body_style.corner_radius_top_left = 2
	body_style.corner_radius_top_right = 2
	body_style.corner_radius_bottom_left = 3
	body_style.corner_radius_bottom_right = 3
	body_style.set_content_margin_all(10)
	body.add_theme_stylebox_override("panel", body_style)
	UITheme.apply_material(body, "toolbox")
	outer.add_child(body)

	var dock_vbox := VBoxContainer.new()
	dock_vbox.set_anchors_preset(Control.PRESET_FULL_RECT)
	dock_vbox.add_theme_constant_override("separation", 10)
	body.add_child(dock_vbox)

	var header = StampedLabelScript.new()
	header.text = "BLOCK LIBRARY"
	header.font_size = 18
	header.custom_minimum_size = Vector2(0, 26)
	dock_vbox.add_child(header)

	var subhead := Label.new()
	subhead.text = "PRIMITIVE GEOMETRY (2 SHAPES)"
	subhead.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	subhead.theme_type_variation = "HintLabel"
	dock_vbox.add_child(subhead)

	dock_vbox.add_child(HSeparator.new())

	var scroller := ScrollContainer.new()
	scroller.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroller.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	dock_vbox.add_child(scroller)

	var vbox := VBoxContainer.new()
	vbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	vbox.add_theme_constant_override("separation", 8)
	scroller.add_child(vbox)
	_palette_vbox = vbox

	_populate_palette()

func _build_right_dock() -> void:
	var outer := Control.new()
	outer.name = "BlockInspectorDock"
	outer.anchor_left = 1.0
	outer.anchor_top = 0.0
	outer.anchor_right = 1.0
	outer.anchor_bottom = 1.0
	outer.offset_left = -(DOCK_WIDTH + DOCK_LEFT_INSET)
	outer.offset_right = -DOCK_LEFT_INSET
	outer.offset_top = DOCK_TOP_INSET
	outer.offset_bottom = -DOCK_BOTTOM_INSET
	outer.mouse_filter = Control.MOUSE_FILTER_STOP
	_canvas_layer.add_child(outer)
	_right_dock_outer = outer

	outer.gui_input.connect(func(event: InputEvent):
		if event is InputEventMouseButton or event is InputEventMouseMotion:
			outer.accept_event()
	)

	var steel_lip := Panel.new()
	steel_lip.name = "SteelLip"
	steel_lip.set_anchors_preset(Control.PRESET_FULL_RECT)
	steel_lip.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var lip_style := StyleBoxFlat.new()
	lip_style.bg_color = Color.WHITE
	lip_style.corner_radius_top_left = 5
	lip_style.corner_radius_top_right = 5
	lip_style.corner_radius_bottom_left = 8
	lip_style.corner_radius_bottom_right = 8
	lip_style.border_width_top = 3
	lip_style.border_color = Tokens.BASE_500
	lip_style.set_content_margin_all(0)
	steel_lip.add_theme_stylebox_override("panel", lip_style)
	UITheme.apply_material(steel_lip, "steel", {"brightness": 0.62, "grime": 0.40})
	outer.add_child(steel_lip)

	var gasket := Panel.new()
	gasket.name = "RubberGasket"
	gasket.anchor_left = 0.0
	gasket.anchor_top = 0.0
	gasket.anchor_right = 1.0
	gasket.anchor_bottom = 1.0
	gasket.offset_left = LIP_WIDTH
	gasket.offset_top = LIP_WIDTH
	gasket.offset_right = -LIP_WIDTH
	gasket.offset_bottom = -LIP_WIDTH
	gasket.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var gasket_style := StyleBoxFlat.new()
	gasket_style.bg_color = Tokens.BASE_900
	gasket_style.corner_radius_top_left = 3
	gasket_style.corner_radius_top_right = 3
	gasket_style.corner_radius_bottom_left = 5
	gasket_style.corner_radius_bottom_right = 5
	gasket_style.set_content_margin_all(0)
	gasket.add_theme_stylebox_override("panel", gasket_style)
	var gasket_mat := ShaderMaterial.new()
	gasket_mat.shader = preload("res://shaders/rubber_gasket.gdshader")
	gasket.material = gasket_mat
	outer.add_child(gasket)

	var body := PanelContainer.new()
	body.name = "InspectorBody"
	body.anchor_left = 0.0
	body.anchor_top = 0.0
	body.anchor_right = 1.0
	body.anchor_bottom = 1.0
	body.offset_left = TOTAL_INSET
	body.offset_top = TOTAL_INSET
	body.offset_right = -TOTAL_INSET
	body.offset_bottom = -TOTAL_INSET
	body.mouse_filter = Control.MOUSE_FILTER_STOP
	body.theme_type_variation = "DockPanel"
	UITheme.apply_material(body, "powdercoat")
	outer.add_child(body)

	var vbox := VBoxContainer.new()
	vbox.set_anchors_preset(Control.PRESET_FULL_RECT)
	vbox.add_theme_constant_override("separation", 8)
	body.add_child(vbox)

	var header = StampedLabelScript.new()
	header.text = "BLOCK INSPECTOR"
	header.font_size = 18
	header.custom_minimum_size = Vector2(0, 26)
	vbox.add_child(header)

	vbox.add_child(HSeparator.new())

	var scroller := ScrollContainer.new()
	scroller.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroller.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	vbox.add_child(scroller)

	properties_panel = VBoxContainer.new()
	properties_panel.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	properties_panel.add_theme_constant_override("separation", 6)
	scroller.add_child(properties_panel)

	vbox.add_child(HSeparator.new())

	var actions_vbox := VBoxContainer.new()
	actions_vbox.add_theme_constant_override("separation", 6)
	vbox.add_child(actions_vbox)

	save_btn = Button.new()
	save_btn.text = "Save Assembly"
	save_btn.custom_minimum_size = Vector2(0, 34)
	UIFeedbackScript.wire(save_btn, "default")
	save_btn.pressed.connect(_on_save_assembly_clicked)
	actions_vbox.add_child(save_btn)

	load_btn = Button.new()
	load_btn.text = "Load Assembly"
	load_btn.custom_minimum_size = Vector2(0, 34)
	UIFeedbackScript.wire(load_btn, "default")
	load_btn.pressed.connect(_on_load_assembly_clicked)
	actions_vbox.add_child(load_btn)

	clear_button = Button.new()
	clear_button.text = "Clear Grid"
	clear_button.custom_minimum_size = Vector2(0, 34)
	clear_button.theme_type_variation = "DangerButton"
	UIFeedbackScript.wire(clear_button, "danger")
	clear_button.pressed.connect(_on_clear_clicked)
	actions_vbox.add_child(clear_button)

	export_button = Button.new()
	export_button.text = "CSG Weld & Export"
	export_button.custom_minimum_size = Vector2(0, 42)
	export_button.theme_type_variation = "PrimaryButton"
	UIFeedbackScript.wire(export_button, "confirm")
	export_button.pressed.connect(_on_export_clicked)
	actions_vbox.add_child(export_button)

func _build_bottom_bar() -> void:
	var bar := PanelContainer.new()
	bar.name = "BottomBar"
	bar.anchor_left = 0.0
	bar.anchor_right = 1.0
	bar.anchor_top = 1.0
	bar.anchor_bottom = 1.0
	bar.offset_top = -36.0
	bar.mouse_filter = Control.MOUSE_FILTER_IGNORE
	bar.theme_type_variation = "DockRail"
	_canvas_layer.add_child(bar)

	var margin := MarginContainer.new()
	margin.add_theme_constant_override("margin_left", 24)
	margin.add_theme_constant_override("margin_right", 24)
	margin.mouse_filter = Control.MOUSE_FILTER_IGNORE
	bar.add_child(margin)

	status_label = Label.new()
	status_label.name = "StatusLabel"
	status_label.theme_type_variation = "StatLabel"
	status_label.text = "Ready"
	status_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	status_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	margin.add_child(status_label)

func _populate_palette() -> void:
	if _palette_vbox == null:
		return
	for child in _palette_vbox.get_children():
		child.queue_free()
	palette_buttons.clear()

	var first := true
	for d in block_defs:
		var card := Button.new()
		card.custom_minimum_size = Vector2(0, 56)
		card.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		card.toggle_mode = true
		card.tooltip_text = str(d["tooltip"])
		card.theme_type_variation = "TabButton"
		UIFeedbackScript.wire(card, "select")
		if first:
			card.button_pressed = true
			first = false

		var b_type := int(d["type"])

		var hbox := HBoxContainer.new()
		hbox.set_anchors_preset(Control.PRESET_FULL_RECT)
		hbox.offset_left = 10
		hbox.offset_right = -10
		hbox.mouse_filter = Control.MOUSE_FILTER_IGNORE
		hbox.add_theme_constant_override("separation", 10)
		card.add_child(hbox)

		var icon_tex := TextureRect.new()
		icon_tex.custom_minimum_size = Vector2(28, 28)
		icon_tex.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		icon_tex.texture = UIIcons.get_icon(str(d["icon"]))
		icon_tex.mouse_filter = Control.MOUSE_FILTER_IGNORE
		hbox.add_child(icon_tex)

		var text_col := VBoxContainer.new()
		text_col.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		text_col.alignment = BoxContainer.ALIGNMENT_CENTER
		text_col.mouse_filter = Control.MOUSE_FILTER_IGNORE
		hbox.add_child(text_col)

		var name_lbl := Label.new()
		name_lbl.text = str(d["name"]).to_upper()
		name_lbl.theme_type_variation = "HeadingLabel"
		name_lbl.mouse_filter = Control.MOUSE_FILTER_IGNORE
		text_col.add_child(name_lbl)

		var desc_lbl := Label.new()
		desc_lbl.text = str(d["subtext"])
		desc_lbl.theme_type_variation = "HintLabel"
		desc_lbl.mouse_filter = Control.MOUSE_FILTER_IGNORE
		text_col.add_child(desc_lbl)

		card.pressed.connect(func():
			current_block_type = b_type as BlockType
			for b in palette_buttons:
				if b != card:
					b.button_pressed = false
			_update_status("Selected " + str(d["name"]) + " — Drag or click to place")
		)

		card.gui_input.connect(func(ev: InputEvent):
			if ev is InputEventMouseButton and ev.button_index == MOUSE_BUTTON_LEFT and ev.pressed:
				_start_palette_drag(b_type as BlockType)
		)

		palette_buttons.append(card)
		_palette_vbox.add_child(card)

func _process(_delta: float) -> void:
	_update_forward_arrow()
	_update_gizmo_transform()

func _update_gizmo_transform() -> void:
	if not _gizmo_root or not is_instance_valid(_gizmo_root):
		return
	if selected_block < 0 or selected_block >= blocks.size():
		_detach_gizmo()
		return
	var blk = blocks[selected_block]
	if blk.get("node") and is_instance_valid(blk["node"]):
		_gizmo_root.global_position = blk["node"].global_position
		_gizmo_root.global_rotation = blk["node"].global_rotation

func _update_forward_arrow() -> void:
	if not _forward_arrow:
		return
	if blocks.is_empty():
		_forward_arrow.visible = false
		return
	_forward_arrow.visible = true
	var aabb := _calculate_aabb()
	var center_x := aabb.position.x + aabb.size.x * 0.5
	var center_y := aabb.position.y + aabb.size.y * 0.5
	var front_z := aabb.position.z - 0.8
	_forward_arrow.position = Vector3(center_x, center_y, front_z)

# ── Spatial Dictionary & Coordinate Math ─────────────────────────────────────

func pos_to_grid_coord(pos: Vector3, _dim: Vector3i = Vector3i.ONE) -> Vector3i:
	return Vector3i(
		roundi(pos.x / grid_unit),
		roundi(pos.y / grid_unit),
		roundi(pos.z / grid_unit)
	)

func grid_coord_to_pos(coord: Vector3i, _dim: Vector3i = Vector3i.ONE) -> Vector3:
	return Vector3(float(coord.x), float(coord.y), float(coord.z)) * grid_unit

static func get_occupied_cells(coord: Vector3i, dim: Vector3i = Vector3i.ONE, rot: Vector3 = Vector3.ZERO) -> Array[Vector3i]:
	var cells: Array[Vector3i] = []
	var b := Basis.from_euler(rot)
	for lx in range(dim.x):
		for ly in range(dim.y):
			for lz in range(dim.z):
				var local_offset := Vector3(
					float(lx) - float(dim.x - 1) * 0.5,
					float(ly) - float(dim.y - 1) * 0.5,
					float(lz) - float(dim.z - 1) * 0.5
				)
				var world_offset := b * local_offset
				var cell := coord + Vector3i(roundi(world_offset.x), roundi(world_offset.y), roundi(world_offset.z))
				if not cells.has(cell):
					cells.append(cell)
	return cells

func _can_occupy(coord: Vector3i, dim: Vector3i, rot: Vector3 = Vector3.ZERO, ignore_block: Dictionary = {}) -> bool:
	var cells := get_occupied_cells(coord, dim, rot)
	for c in cells:
		if _spatial_dict.has(c):
			var existing = _spatial_dict[c]
			if existing != ignore_block:
				return false
	return true

func _register_in_grid(block: Dictionary) -> void:
	var dim: Vector3i = block.get("dim", Vector3i.ONE)
	var rot: Vector3 = block.get("rotation", Vector3.ZERO)
	var cells := get_occupied_cells(block["grid_coord"], dim, rot)
	for c in cells:
		_spatial_dict[c] = block

func _unregister_from_grid(block: Dictionary) -> void:
	var dim: Vector3i = block.get("dim", Vector3i.ONE)
	var rot: Vector3 = block.get("rotation", Vector3.ZERO)
	var cells := get_occupied_cells(block["grid_coord"], dim, rot)
	for c in cells:
		if _spatial_dict.get(c) == block:
			_spatial_dict.erase(c)

# ── Palette Drag & Drop ──────────────────────────────────────────────────────

func _start_palette_drag(type: BlockType) -> void:
	is_dragging_from_palette = true
	dragged_palette_type = type
	if preview_node:
		preview_node.queue_free()

	preview_node = _make_preview_node(type, Vector3i.ONE)
	add_child(preview_node)
	_update_status("Dragging " + _block_name(type) + " — release to place on grid")

func _update_preview_position(mouse_pos: Vector2) -> void:
	if not preview_node:
		return

	# First block always snaps to center of workspace (0, 0, 0)
	if not has_origin or blocks.is_empty():
		var origin_pos := grid_coord_to_pos(Vector3i.ZERO, Vector3i.ONE)
		_set_preview_tint(true)
		preview_node.global_position = origin_pos
		preview_node.visible = true
		return

	var ray_result := _do_raycast(mouse_pos)
	var target_pos := Vector3.ZERO
	var can_place := true

	if not ray_result.is_empty():
		var hit_pos: Vector3 = ray_result["position"]
		var hit_norm: Vector3 = ray_result.get("normal", Vector3.UP)
		var center_cand := hit_pos + hit_norm * (grid_unit * 0.5)
		var coord := pos_to_grid_coord(center_cand, Vector3i.ONE)
		target_pos = grid_coord_to_pos(coord, Vector3i.ONE)
		can_place = _can_occupy(coord, Vector3i.ONE)
	else:
		var camera := get_viewport().get_camera_3d()
		if camera:
			var from := camera.project_ray_origin(mouse_pos)
			var to_dir := camera.project_ray_normal(mouse_pos)
			var plane := Plane(Vector3.UP, 0.0)
			var hit = plane.intersects_ray(from, to_dir)
			if hit != null:
				var coord := pos_to_grid_coord(hit, Vector3i.ONE)
				target_pos = grid_coord_to_pos(coord, Vector3i.ONE)
				can_place = _can_occupy(coord, Vector3i.ONE)
			else:
				target_pos = from + to_dir * 10.0

	_set_preview_tint(can_place)
	preview_node.global_position = target_pos
	preview_node.visible = true

func _set_preview_tint(valid: bool) -> void:
	if not preview_node:
		return
	var col := Color(0.2, 0.9, 0.4, 0.55) if valid else Color(0.95, 0.2, 0.2, 0.55)
	for child in preview_node.get_children():
		if child is MeshInstance3D:
			var mat = child.material_override as StandardMaterial3D
			if mat:
				mat.albedo_color = col

func _drop_from_palette(mouse_pos: Vector2) -> void:
	is_dragging_from_palette = false
	if not preview_node:
		return
	var drop_pos := preview_node.global_position
	preview_node.queue_free()
	preview_node = null

	var coord := Vector3i.ZERO if (not has_origin or blocks.is_empty()) else pos_to_grid_coord(drop_pos, Vector3i.ONE)
	if not _can_occupy(coord, Vector3i.ONE):
		_show_warning("Cannot place: Grid cell is already occupied!")
		return

	_add_block_at_grid(dragged_palette_type, coord, Vector3i.ONE)
	if blocks.size() == 1:
		_update_status("Placed origin block " + _block_name(dragged_palette_type) + " at (0, 0, 0)")
	else:
		_update_status("Placed " + _block_name(dragged_palette_type))

# ── Input Handling ───────────────────────────────────────────────────────────

func _input(event: InputEvent) -> void:
	if _gizmo_drag_handle != null:
		if event is InputEventMouseMotion:
			_on_gizmo_drag_motion(event)
			return
		elif event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT and not event.pressed:
			_on_gizmo_drag_end()
			return

	if is_dragging_from_palette:
		if event is InputEventMouseMotion:
			_update_preview_position(event.position)
		elif event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT and not event.pressed:
			_drop_from_palette(event.position)

func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed("lab_delete"):
		_delete_selected()
	elif event.is_action_pressed("lab_duplicate"):
		_duplicate_selected()
	elif event.is_action_pressed("ui_cancel"):
		if is_dragging_from_palette:
			is_dragging_from_palette = false
			if preview_node:
				preview_node.queue_free()
				preview_node = null
			_update_status("Cancelled drag")
		else:
			_deselect()
	elif event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_RIGHT and event.pressed:
		var ray_result := _do_raycast(event.position)
		var hit_idx := -1
		if not ray_result.is_empty():
			hit_idx = _hit_existing_block(ray_result)
		if hit_idx >= 0:
			_select_block(hit_idx)
			_open_block_radial_menu(hit_idx, event.position)
			return
		elif selected_block >= 0 and selected_block < blocks.size():
			_open_block_radial_menu(selected_block, event.position)
			return
		else:
			_close_radial_menu()

	_on_viewport_input(event)

func _on_viewport_input(event: InputEvent) -> void:
	if not hull_container:
		return

	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT and event.pressed:
		var gizmo_hit: Node3D = _raycast_gizmo(event.position)
		if gizmo_hit:
			_close_radial_menu()
			_on_gizmo_drag_start(gizmo_hit, event.position)
			return

		var ray_result := _do_raycast(event.position)
		var hit_idx := -1
		if not ray_result.is_empty():
			hit_idx = _hit_existing_block(ray_result)

		if hit_idx >= 0:
			_select_block(hit_idx)
		else:
			_close_radial_menu()
			if not has_origin or blocks.is_empty():
				# First block clicked anywhere snaps directly to center origin (0, 0, 0)
				_add_block_at_grid(current_block_type, Vector3i.ZERO, Vector3i.ONE)
				_update_status("Placed origin block " + _block_name(current_block_type) + " at (0, 0, 0)")
			elif not ray_result.is_empty():
				var hit_pos: Vector3 = ray_result["position"]
				var hit_norm: Vector3 = ray_result.get("normal", Vector3.UP)
				var center_cand := hit_pos + hit_norm * (grid_unit * 0.5)
				var coord := pos_to_grid_coord(center_cand, Vector3i.ONE)
				_add_block_at_grid(current_block_type, coord, Vector3i.ONE)
			else:
				_deselect()

# Active Radial Menu
var _active_radial_menu: UIRadialMenu = null

func _close_radial_menu() -> void:
	if _active_radial_menu and is_instance_valid(_active_radial_menu):
		_active_radial_menu.close()
	_active_radial_menu = null

# ── Selection & Highlight ────────────────────────────────────────────────────

func _select_block(idx: int) -> void:
	var prev := selected_block
	if prev != idx:
		_close_radial_menu()
	selected_block = idx

	if prev >= 0 and prev < blocks.size() and prev != idx:
		_set_highlight(prev, false)

	_set_highlight(idx, true)
	_attach_gizmo(idx)
	_update_properties_panel()
	_update_status("Selected " + _block_name(blocks[idx]["type"]) + " #" + str(idx + 1)
		+ " — Right-Click for Radial Menu (Rotate/Scale/Mirror/Delete)")

func _deselect() -> void:
	_close_radial_menu()
	if selected_block >= 0 and selected_block < blocks.size():
		_set_highlight(selected_block, false)
	selected_block = -1
	_detach_gizmo()
	_update_properties_panel()
	_update_status("Click a block to select, or drag from palette to add")

func _set_highlight(idx: int, on: bool) -> void:
	if idx < 0 or idx >= blocks.size():
		return
	var blk = blocks[idx]
	if not blk.get("node"):
		return
	for child in blk["node"].get_children():
		if child is MeshInstance3D:
			var mat = child.material_override as StandardMaterial3D
			if mat:
				mat.emission_enabled = on
				mat.emission = HIGHLIGHT_EMISSION if on else Color.BLACK
				mat.emission_energy_multiplier = 0.6 if on else 0.0

# ── 3D Transform Gizmo (Translate Only — Rotate is on Radial Menu) ───────────

const GIZMO_RADIUS := 1.25

func _attach_gizmo(idx: int) -> void:
	_detach_gizmo()
	if not hull_container:
		return
	if idx < 0 or idx >= blocks.size():
		return
	var blk = blocks[idx]
	if not blk.get("node"):
		return

	var root := Node3D.new()
	root.name = "ModularGizmo"
	hull_container.add_child(root)
	root.global_position = blk["node"].global_position
	root.global_rotation = blk["node"].global_rotation
	root.scale = Vector3.ONE  # Fixed scale, never scales with block
	_gizmo_root = root

	var giz_r := GIZMO_RADIUS

	# 3 Double-Headed Translation Arrows (snaps to 1.0 unit grid)
	_build_double_headed_axis_handle(root, "TranslateX", Vector3.RIGHT, COL_X, giz_r)
	_build_double_headed_axis_handle(root, "TranslateY", Vector3.UP,    COL_Y, giz_r)
	_build_double_headed_axis_handle(root, "TranslateZ", Vector3.BACK,  COL_Z, giz_r)

func _detach_gizmo() -> void:
	if _gizmo_root and is_instance_valid(_gizmo_root):
		_gizmo_root.queue_free()
	_gizmo_root = null
	_gizmo_drag_handle = null

func _build_double_headed_axis_handle(parent: Node3D, handle_name: String,
		axis: Vector3, color: Color, giz_r: float) -> void:
	var area := Area3D.new()
	area.name = handle_name
	area.set_meta("axis", axis)
	area.set_meta("kind", "translate")
	area.collision_layer = GIZMO_LAYER
	area.collision_mask = 0

	# Collision box spanning the full double-headed arrow
	var col := CollisionShape3D.new()
	var bs  := BoxShape3D.new()
	var handle_thickness := 0.18
	var total_span := giz_r * 1.3
	bs.size = Vector3(
		total_span if axis.x != 0 else handle_thickness,
		total_span if axis.y != 0 else handle_thickness,
		total_span if axis.z != 0 else handle_thickness
	)
	col.shape = bs
	area.add_child(col)

	# Shared partially transparent material
	var mat := StandardMaterial3D.new()
	mat.albedo_color = color
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.no_depth_test = true
	mat.render_priority = 3

	# 1. Central Shaft
	var shaft_len := giz_r * 0.9
	var shaft_thickness := 0.055
	var shaft_mi := MeshInstance3D.new()
	var shaft_mesh := BoxMesh.new()
	shaft_mesh.size = Vector3(
		shaft_len if axis.x != 0 else shaft_thickness,
		shaft_len if axis.y != 0 else shaft_thickness,
		shaft_len if axis.z != 0 else shaft_thickness
	)
	shaft_mi.mesh = shaft_mesh
	shaft_mi.material_override = mat
	area.add_child(shaft_mi)

	# 2. Positive Arrow Head (+axis)
	var tip_len := giz_r * 0.24
	var tip_rad := giz_r * 0.09
	var tip_pos_pos := axis * (shaft_len * 0.5 + tip_len * 0.5)

	var tip_pos := MeshInstance3D.new()
	var cone_pos := CylinderMesh.new()
	cone_pos.top_radius = 0.0
	cone_pos.bottom_radius = tip_rad
	cone_pos.height = tip_len
	cone_pos.radial_segments = 12
	tip_pos.mesh = cone_pos
	tip_pos.material_override = mat
	tip_pos.position = tip_pos_pos
	if axis == Vector3.RIGHT:
		tip_pos.rotation = Vector3(0, 0, -PI * 0.5)
	elif axis == Vector3.BACK:
		tip_pos.rotation = Vector3(PI * 0.5, 0, 0)
	area.add_child(tip_pos)

	# 3. Negative Arrow Head (-axis)
	var tip_neg_pos := -axis * (shaft_len * 0.5 + tip_len * 0.5)
	var tip_neg := MeshInstance3D.new()
	var cone_neg := CylinderMesh.new()
	cone_neg.top_radius = 0.0
	cone_neg.bottom_radius = tip_rad
	cone_neg.height = tip_len
	cone_neg.radial_segments = 12
	tip_neg.mesh = cone_neg
	tip_neg.material_override = mat
	tip_neg.position = tip_neg_pos
	if axis == Vector3.RIGHT:
		tip_neg.rotation = Vector3(0, 0, PI * 0.5)
	elif axis == Vector3.UP:
		tip_neg.rotation = Vector3(PI, 0, 0)
	elif axis == Vector3.BACK:
		tip_neg.rotation = Vector3(-PI * 0.5, 0, 0)
	area.add_child(tip_neg)

	parent.add_child(area)

func _build_rotate_ring(parent: Node3D, giz_r: float, axis: Vector3, ring_name: String, color: Color) -> void:
	var area := Area3D.new()
	area.name = ring_name
	area.set_meta("axis", axis)
	area.set_meta("kind", "rotate")
	area.collision_layer = GIZMO_ROTATE_LAYER
	area.collision_mask = 0

	var ring_radius := giz_r * 0.88
	var segment_count := 24
	var cube_size := giz_r * 0.16
	for i in range(segment_count):
		var ang := 2.0 * PI * i / segment_count
		var seg := CollisionShape3D.new()
		var bs := BoxShape3D.new()
		bs.size = Vector3(cube_size, 0.12, cube_size)
		seg.shape = bs
		seg.position = Vector3(cos(ang) * ring_radius, 0, sin(ang) * ring_radius)
		area.add_child(seg)

	var mi   := MeshInstance3D.new()
	var mesh := TorusMesh.new()
	mesh.inner_radius = ring_radius - cube_size * 0.5
	mesh.outer_radius = ring_radius + cube_size * 0.5
	mi.mesh = mesh
	var mat := StandardMaterial3D.new()
	mat.albedo_color = color
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.no_depth_test = true
	mat.render_priority = 3
	mi.material_override = mat
	area.add_child(mi)

	if axis.is_equal_approx(Vector3.RIGHT):
		area.rotation = Vector3(0, 0, PI / 2.0)
	elif axis.is_equal_approx(Vector3.BACK):
		area.rotation = Vector3(PI / 2.0, 0, 0)

	parent.add_child(area)

func _raycast_gizmo(mouse_pos: Vector2) -> Node3D:
	if _gizmo_root == null or not is_instance_valid(_gizmo_root):
		return null
	var camera := get_viewport().get_camera_3d()
	if not camera:
		return null

	var from   := camera.project_ray_origin(mouse_pos)
	var to_dir := camera.project_ray_normal(mouse_pos)
	var to     := from + to_dir * 1000.0
	var space  := get_world_3d().direct_space_state

	var hit := _raycast_gizmo_layer(space, from, to, GIZMO_LAYER)
	if hit == null:
		hit = _raycast_gizmo_layer(space, from, to, GIZMO_ROTATE_LAYER)
	return hit

func _raycast_gizmo_layer(space: PhysicsDirectSpaceState3D, from: Vector3, to: Vector3, mask: int) -> Node3D:
	var params := PhysicsRayQueryParameters3D.new()
	params.from = from
	params.to = to
	params.collision_mask = mask
	params.collide_with_areas = true
	params.collide_with_bodies = false
	var result := space.intersect_ray(params)
	if result.is_empty():
		return null

	var hit := result["collider"] as Node3D
	if not hit:
		return null
	while hit and hit.get_parent() != _gizmo_root:
		hit = hit.get_parent() as Node3D
		if not hit:
			return null
	return hit if is_instance_valid(hit) else null

func _on_gizmo_drag_start(handle: Node3D, mouse_pos: Vector2) -> void:
	_gizmo_drag_handle = handle
	_gizmo_drag_start_mouse = mouse_pos

	var kind: String = handle.get_meta("kind") if handle.has_meta("kind") else "translate"
	var axis_val = handle.get_meta("axis") if handle.has_meta("axis") else Vector3.ZERO
	var local_axis: Vector3 = axis_val if axis_val != null else Vector3.ZERO
	_gizmo_drag_local_axis = local_axis

	if selected_block >= 0 and selected_block < blocks.size():
		var blk = blocks[selected_block]
		_gizmo_drag_start_pos = blk["position"]
		_gizmo_drag_start_coord = blk["grid_coord"]
		_gizmo_drag_start_rot = blk["rotation"]

	var world_axis: Vector3 = local_axis
	if selected_block >= 0 and selected_block < blocks.size() and local_axis != Vector3.ZERO:
		world_axis = (Basis.from_euler(_gizmo_drag_start_rot) * local_axis).normalized()
	_gizmo_drag_axis = world_axis

	if kind == "rotate":
		_gizmo_drag_mode = "rotate"
		var blk_pos := Vector3.ZERO
		if selected_block >= 0 and selected_block < blocks.size():
			blk_pos = blocks[selected_block]["position"]
		_gizmo_drag_start_angle = _mouse_angle_in_xz(mouse_pos, blk_pos)
	else:
		_gizmo_drag_mode = "translate"

func _compute_axis_world_delta(event: InputEventMouseMotion, axis: Vector3, pivot: Vector3) -> Vector3:
	var camera := get_viewport().get_camera_3d()
	if not camera:
		return Vector3.ZERO
	var from_old := camera.project_ray_origin(_gizmo_drag_start_mouse)
	var to_old   := from_old + camera.project_ray_normal(_gizmo_drag_start_mouse) * 500.0
	var from_new := camera.project_ray_origin(event.position)
	var to_new   := from_new + camera.project_ray_normal(event.position) * 500.0

	var cam_dir := (to_new - from_new).normalized()
	var perp1   := axis.cross(cam_dir).normalized()
	var plane_n := axis.cross(perp1).normalized()

	var old_t := _ray_plane_t(from_old, (to_old - from_old).normalized(), pivot, plane_n)
	var new_t := _ray_plane_t(from_new, (to_new - from_new).normalized(), pivot, plane_n)

	if old_t < 0.0 or new_t < 0.0:
		return Vector3.ZERO

	var old_world := from_old + (to_old - from_old).normalized() * old_t
	var new_world := from_new + (to_new - from_new).normalized() * new_t
	return (new_world - old_world).dot(axis) * axis

func _on_gizmo_drag_motion(event: InputEventMouseMotion) -> void:
	if selected_block < 0 or selected_block >= blocks.size():
		return
	var blk = blocks[selected_block]

	if _gizmo_drag_mode == "translate":
		var delta := _compute_axis_world_delta(event, _gizmo_drag_axis, _gizmo_drag_start_pos)
		var raw_new_pos := _gizmo_drag_start_pos + delta
		var new_coord := pos_to_grid_coord(raw_new_pos)

		if new_coord != blk["grid_coord"]:
			var dim: Vector3i = blk.get("dim", Vector3i.ONE)
			var rot: Vector3 = blk.get("rotation", Vector3.ZERO)
			if _can_occupy(new_coord, dim, rot, blk):
				_unregister_from_grid(blk)
				blk["grid_coord"] = new_coord
				blk["position"] = grid_coord_to_pos(new_coord)
				if blk.get("node"):
					blk["node"].position = blk["position"]
				_register_in_grid(blk)
				_sync_mirror_partner(blk)
				_update_properties_panel()
				_update_status("Grid Position: %s" % str(new_coord))

	elif _gizmo_drag_mode == "rotate":
		var cur_angle := _mouse_angle_in_xz(event.position, blk["position"])
		var delta_ang := cur_angle - _gizmo_drag_start_angle

		# Snap rotation strictly in 90-degree steps
		var steps := roundi(delta_ang / ROT_STEP)
		var snapped_angle := float(steps) * ROT_STEP

		var start_basis := Basis.from_euler(_gizmo_drag_start_rot)
		var new_basis := Basis(_gizmo_drag_axis, snapped_angle) * start_basis
		var euler := new_basis.get_euler()

		euler.x = roundf(euler.x / ROT_STEP) * ROT_STEP
		euler.y = roundf(euler.y / ROT_STEP) * ROT_STEP
		euler.z = roundf(euler.z / ROT_STEP) * ROT_STEP

		blk["rotation"] = euler
		if blk.get("node"):
			blk["node"].rotation = blk["rotation"]
		_sync_mirror_partner(blk)
		_update_properties_panel()
		_update_status("Rotation: %d°, %d°, %d°" % [
			roundi(rad_to_deg(euler.x)),
			roundi(rad_to_deg(euler.y)),
			roundi(rad_to_deg(euler.z))
		])

func _on_gizmo_drag_end() -> void:
	_gizmo_drag_handle = null
	_gizmo_drag_mode = ""
	_update_status("Ready")

func _mouse_angle_in_xz(mouse_pos: Vector2, pivot: Vector3) -> float:
	var camera := get_viewport().get_camera_3d()
	if not camera:
		return 0.0
	var pivot_screen := camera.unproject_position(pivot)
	var rel := mouse_pos - pivot_screen
	if rel.length_squared() < 0.0001:
		return 0.0
	return atan2(rel.x, rel.y)

func _ray_plane_t(ray_origin: Vector3, ray_dir: Vector3,
		plane_point: Vector3, plane_normal: Vector3) -> float:
	var denom := plane_normal.dot(ray_dir)
	if abs(denom) < 0.0001:
		return -1.0
	return plane_normal.dot(plane_point - ray_origin) / denom

# ── Block Action Radial Menu (Rotate X/Y/Z, Mirror, Delete, + Outer Dials) ──

func _open_block_radial_menu(idx: int, screen_pos: Vector2) -> void:
	_close_radial_menu()
	if idx < 0 or idx >= blocks.size():
		return
	var blk = blocks[idx]

	var menu := UIRadialMenu.new()
	menu.target_node = blk.get("node")
	menu.subject_label = _block_name(blk["type"])

	# Main ring actions
	menu.add_action("rot_y", "ROT Y", "verb_rotate", true, false)
	menu.add_action("rot_z", "ROT Z", "verb_rotate", true, false)
	menu.add_action("rot_x", "ROT X", "verb_rotate", true, false)
	menu.add_action("mirror_x", "MIRROR X", "verb_mirror", true, true)
	menu.add_action("delete", "DELETE", "verb_discard", true, true)

	menu.action_invoked_button.connect(func(action_id: String, button_index: int):
		var dir := 1 if button_index == MOUSE_BUTTON_LEFT else -1
		match action_id:
			"rot_x":
				_step_block_rotation(idx, Vector3.RIGHT, dir)
			"rot_y":
				_step_block_rotation(idx, Vector3.UP, dir)
			"rot_z":
				_step_block_rotation(idx, Vector3.BACK, dir)
			"mirror_x":
				_mirror_selected_x()
			"delete":
				_delete_selected()
	)

	# Outer Satellite Radial Dials from Design Lab
	var b_type: BlockType = blk["type"]
	var dim: Vector3i = blk.get("dim", Vector3i.ONE)

	if b_type == BlockType.CUBE:
		# 3-Axis Deform Dials (1-unit increments, 1 to 8 units)
		# 1. LENGTH (X) at 0° (Right / 3:00)
		var dial_x := RadialDial.new("len_x", "Length X", 1.0, 8.0, 1.0, float(dim.x))
		dial_x.value_changed.connect(func(v: float): _set_block_dim_axis(idx, 0, roundi(v)))
		menu.add_satellite_control(dial_x, 0.0, 180.0)

		# 2. HEIGHT (Y) at -90° (Top / 12:00)
		var dial_y := RadialDial.new("hgt_y", "Height Y", 1.0, 8.0, 1.0, float(dim.y))
		dial_y.value_changed.connect(func(v: float): _set_block_dim_axis(idx, 1, roundi(v)))
		menu.add_satellite_control(dial_y, -PI * 0.5, 180.0)

		# 3. DEPTH (Z) at 180° (Left / 9:00)
		var dial_z := RadialDial.new("dep_z", "Depth Z", 1.0, 8.0, 1.0, float(dim.z))
		dial_z.value_changed.connect(func(v: float): _set_block_dim_axis(idx, 2, roundi(v)))
		menu.add_satellite_control(dial_z, PI, 180.0)

	elif b_type == BlockType.WEDGE_45:
		# Lateral Width Extension (1-unit increments, 1 to 8 units)
		var dial_w := RadialDial.new("width_x", "Width", 1.0, 8.0, 1.0, float(dim.x))
		dial_w.value_changed.connect(func(v: float): _step_wedge_width(idx, v, dial_w))
		menu.add_satellite_control(dial_w, -PI * 0.25, 180.0)

	menu.dismissed.connect(func():
		if _active_radial_menu == menu:
			_active_radial_menu = null
	)

	_active_radial_menu = menu
	add_child(menu)

	var target_screen_pos := screen_pos
	if menu.target_node and is_instance_valid(menu.target_node):
		var camera := get_viewport().get_camera_3d()
		if camera:
			var pos_3d := ModuleVolume.center_of_mass_world(menu.target_node)
			if not camera.is_position_behind(pos_3d):
				target_screen_pos = camera.unproject_position(pos_3d)

	menu.open_at(target_screen_pos)

func _step_block_rotation(idx: int, axis: Vector3, dir: int) -> void:
	if idx < 0 or idx >= blocks.size():
		return
	var blk = blocks[idx]
	var angle_delta := float(dir) * ROT_STEP
	var cur_basis := Basis.from_euler(blk["rotation"])
	var rot_basis := Basis(axis, angle_delta)
	var new_basis := rot_basis * cur_basis
	var euler := new_basis.get_euler()

	euler.x = roundf(euler.x / ROT_STEP) * ROT_STEP
	euler.y = roundf(euler.y / ROT_STEP) * ROT_STEP
	euler.z = roundf(euler.z / ROT_STEP) * ROT_STEP

	var dim: Vector3i = blk.get("dim", Vector3i.ONE)
	if not _can_occupy(blk["grid_coord"], dim, euler, blk):
		_show_warning("Cannot rotate: space is occupied!")
		return

	_unregister_from_grid(blk)
	blk["rotation"] = euler
	if blk.get("node"):
		blk["node"].rotation = blk["rotation"]
	_register_in_grid(blk)
	_attach_gizmo(idx)
	_sync_mirror_partner(blk)
	_update_properties_panel()
	_update_status("Rotated %s %s by %d° (Total: %d°, %d°, %d°)" % [
		_block_name(blk["type"]),
		"X" if axis == Vector3.RIGHT else ("Y" if axis == Vector3.UP else "Z"),
		roundi(rad_to_deg(angle_delta)),
		roundi(rad_to_deg(euler.x)),
		roundi(rad_to_deg(euler.y)),
		roundi(rad_to_deg(euler.z))
	])

func _set_block_dim_axis(idx: int, axis_idx: int, new_val: int) -> void:
	if idx < 0 or idx >= blocks.size():
		return
	var blk = blocks[idx]
	var target_dim: Vector3i = blk.get("dim", Vector3i.ONE)
	match axis_idx:
		0: target_dim.x = clamp(new_val, 1, 8)
		1: target_dim.y = clamp(new_val, 1, 8)
		2: target_dim.z = clamp(new_val, 1, 8)
	_set_block_dimensions(idx, target_dim)

func _step_wedge_width(idx: int, target_val: float, dial: RadialDial = null) -> void:
	if idx < 0 or idx >= blocks.size():
		return
	var blk = blocks[idx]
	var new_w := clampi(roundi(target_val), 1, 8)
	var target_dim := Vector3i(new_w, 1, 1)
	if _set_block_dimensions(idx, target_dim):
		if dial and is_instance_valid(dial):
			dial.value = float(new_w)
	else:
		if dial and is_instance_valid(dial):
			dial.value = float(blk.get("dim", Vector3i.ONE).x)

func _set_block_dimensions(idx: int, new_dim: Vector3i) -> bool:
	if idx < 0 or idx >= blocks.size():
		return false
	var blk = blocks[idx]
	if blk.get("dim", Vector3i.ONE) == new_dim:
		return true

	var rot: Vector3 = blk.get("rotation", Vector3.ZERO)
	var coord: Vector3i = blk["grid_coord"]

	if not _can_occupy(coord, new_dim, rot, blk):
		_show_warning("Cannot deform: space is occupied by an adjacent block!")
		return false

	_unregister_from_grid(blk)
	blk["dim"] = new_dim
	blk["scale"] = Vector3(float(new_dim.x), float(new_dim.y), float(new_dim.z)) * grid_unit

	if blk.get("node"):
		blk["node"].scale = blk["scale"]

	_register_in_grid(blk)
	_attach_gizmo(idx)
	_sync_mirror_partner(blk)
	_update_properties_panel()
	_update_status("Deformed %s to %dx%dx%d" % [_block_name(blk["type"]), new_dim.x, new_dim.y, new_dim.z])
	return true

# ── Block Operations & Instancing ───────────────────────────────────────────

func _add_block_at_grid(type: BlockType, coord: Vector3i, dim: Vector3i = Vector3i.ONE) -> Dictionary:
	if blocks.size() >= max_blocks:
		_show_warning("Maximum blocks reached (%d)" % max_blocks)
		return {}

	if not _can_occupy(coord, dim):
		_show_warning("Cannot place: space is occupied!")
		return {}

	var pos := grid_coord_to_pos(coord, dim)
	var node := _make_block_node(type, dim)
	node.position = pos

	var blk := {
		"type": type,
		"grid_coord": coord,
		"dim": dim,
		"position": pos,
		"rotation": Vector3.ZERO,
		"scale": Vector3(float(dim.x), float(dim.y), float(dim.z)) * grid_unit,
		"color": Color(0.72, 0.74, 0.78, 1.0),
		"node": node,
	}

	hull_container.add_child(node)
	blocks.append(blk)
	_register_in_grid(blk)
	has_origin = true

	var added_index := blocks.size() - 1

	var paired := false
	if symmetry_enabled and current_stage == AuthoringStage.STAGE_BUILD:
		_create_mirror_partner(blk)
		paired = _has_partner(blk)

	_select_block(added_index)
	if paired:
		_update_status("Added " + _block_name(type) + " (+ mirrored twin)")
	else:
		_update_status("Added " + _block_name(type))
	return blk

func _delete_selected() -> void:
	if selected_block < 0 or selected_block >= blocks.size():
		_update_status("Nothing selected to delete")
		return

	var blk = blocks[selected_block]
	_detach_gizmo()

	var partner_deleted := false
	if _has_partner(blk):
		var partner = blk["mirror_partner"]
		_unlink_mirror_partner(blk)
		var pidx: int = blocks.find(partner)
		if pidx >= 0:
			_unregister_from_grid(partner)
			if partner.get("node"):
				partner["node"].queue_free()
			blocks.remove_at(pidx)
			partner_deleted = true
			if pidx < selected_block:
				selected_block -= 1

	_unregister_from_grid(blk)
	if blk.get("node"):
		blk["node"].queue_free()
	blocks.remove_at(selected_block)

	if blocks.is_empty():
		has_origin = false
		selected_block = -1
		_update_properties_panel()
	else:
		var next = clamp(selected_block, 0, blocks.size() - 1)
		selected_block = -1
		_select_block(next)

	var confirm = "Deleted " + _block_name(blk["type"])
	if partner_deleted:
		confirm += " (+ mirrored twin)"
	_update_status(confirm)

func _duplicate_selected() -> void:
	if selected_block < 0 or selected_block >= blocks.size():
		return
	if blocks.size() >= max_blocks:
		_show_warning("Maximum blocks reached")
		return

	var src = blocks[selected_block]
	var dim: Vector3i = src.get("dim", Vector3i.ONE)
	var offsets := [Vector3i(dim.x, 0, 0), Vector3i(0, 0, dim.z), Vector3i(0, dim.y, 0), Vector3i(-dim.x, 0, 0)]
	var target_coord: Vector3i = src["grid_coord"]
	var found := false

	for off in offsets:
		var cand: Vector3i = src["grid_coord"] + off
		if _can_occupy(cand, dim):
			target_coord = cand
			found = true
			break

	if not found:
		_show_warning("Cannot duplicate: adjacent spaces occupied!")
		return

	var dup = _add_block_at_grid(src["type"], target_coord, dim)
	if not dup.is_empty():
		dup["rotation"] = src["rotation"]
		dup["color"] = src["color"]
		if dup.get("node"):
			dup["node"].rotation = dup["rotation"]
			_apply_node_color(dup["node"], dup["color"])
		_sync_mirror_partner(dup)

# ── Node Construction & Mesh Retrieval ───────────────────────────────────────

func _make_preview_node(type: BlockType, dim: Vector3i = Vector3i.ONE) -> Node3D:
	var mi := MeshInstance3D.new()
	mi.mesh = _get_block_mesh(type)
	mi.scale = Vector3(float(dim.x), float(dim.y), float(dim.z)) * grid_unit

	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.2, 0.9, 0.4, 0.55)
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	mi.material_override = mat
	return mi

func _make_block_node(type: BlockType, dim: Vector3i = Vector3i.ONE) -> StaticBody3D:
	var body := StaticBody3D.new()
	var mi   := MeshInstance3D.new()
	mi.mesh = _get_block_mesh(type)
	body.scale = Vector3(float(dim.x), float(dim.y), float(dim.z)) * grid_unit

	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.72, 0.74, 0.78, 1.0)
	mat.metallic = 0.12
	mat.roughness = 0.84
	mat.specular = 0.25
	mat.normal_enabled = true
	mat.normal_texture = BlockMeshes.get_chamfer_normal_map()
	mat.normal_scale = 0.85
	mi.material_override = mat
	body.add_child(mi)

	var collision := CollisionShape3D.new()
	collision.name = "BlockCollider"
	var box_shape := BoxShape3D.new()
	box_shape.size = Vector3.ONE
	collision.shape = box_shape
	body.add_child(collision)

	return body

func _get_block_mesh(type: BlockType) -> Mesh:
	if BLOCK_MESH_NAMES.has(type):
		var mesh_name: String = BLOCK_MESH_NAMES[type]
		var authored = MeshAssetLoader.get_hull_primitive_mesh(mesh_name)
		if authored:
			return authored

	match type:
		BlockType.CUBE: return BlockMeshes.build_cube()
		BlockType.WEDGE_45: return BlockMeshes.build_wedge()
		_: return BoxMesh.new()

func _apply_node_color(node: Node3D, col: Color) -> void:
	for child in node.get_children():
		if child is MeshInstance3D:
			var mat = child.material_override as StandardMaterial3D
			if mat:
				mat.albedo_color = col
				mat.metallic = 0.12
				mat.roughness = 0.84
				mat.specular = 0.25
				mat.normal_enabled = true
				mat.normal_texture = BlockMeshes.get_chamfer_normal_map()
				mat.normal_scale = 0.85

func _hit_existing_block(ray_result: Dictionary) -> int:
	var hit_node := ray_result.get("collider") as Node3D
	if not hit_node:
		return -1
	for i in range(blocks.size()):
		if blocks[i].get("node") == hit_node:
			return i
	return -1

func _do_raycast(mouse_pos: Vector2) -> Dictionary:
	var camera := get_viewport().get_camera_3d()
	if not camera:
		return {}
	var from   := camera.project_ray_origin(mouse_pos)
	var to_dir := camera.project_ray_normal(mouse_pos)
	var to     := from + to_dir * 1000.0

	var space      := get_world_3d().direct_space_state
	var ray_params := PhysicsRayQueryParameters3D.new()
	ray_params.from = from
	ray_params.to = to
	ray_params.collision_mask = 1
	var result := space.intersect_ray(ray_params)
	return result if not result.is_empty() else {}

func _block_name(type: int) -> String:
	for d in block_defs:
		if int(d["type"]) == type:
			return str(d["name"])
	return "Block"

# ── Properties Panel ─────────────────────────────────────────────────────────

func _update_properties_panel() -> void:
	if not properties_panel:
		return
	for child in properties_panel.get_children():
		child.queue_free()

	if selected_block < 0 or selected_block >= blocks.size():
		var lbl := Label.new()
		lbl.text = "Select a block to inspect & edit\n\nRight-Click — Radial Menu & Outer Dials\nDEL — delete\nCtrl+D — duplicate\nGizmo handles — translate"
		lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		lbl.theme_type_variation = "HintLabel"
		properties_panel.add_child(lbl)
		return

	var blk = blocks[selected_block]
	var dim: Vector3i = blk.get("dim", Vector3i.ONE)

	var title := Label.new()
	title.text = "%s #%d" % [_block_name(blk["type"]), selected_block + 1]
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.theme_type_variation = "HeadingLabel"
	properties_panel.add_child(title)
	properties_panel.add_child(HSeparator.new())

	_add_section_header("Transform (Grid Snapped)")
	var pos_lbl := Label.new()
	var coord: Vector3i = blk["grid_coord"]
	pos_lbl.text = "Grid Cell: [%d, %d, %d]" % [coord.x, coord.y, coord.z]
	pos_lbl.theme_type_variation = "StatLabel"
	properties_panel.add_child(pos_lbl)

	var rot: Vector3 = blk["rotation"]
	var rot_lbl := Label.new()
	rot_lbl.text = "Rotation: %d°, %d°, %d°" % [
		roundi(rad_to_deg(rot.x)),
		roundi(rad_to_deg(rot.y)),
		roundi(rad_to_deg(rot.z))
	]
	rot_lbl.theme_type_variation = "StatLabel"
	properties_panel.add_child(rot_lbl)

	var dim_header := Label.new()
	if blk["type"] == BlockType.CUBE:
		dim_header.text = "Dimensions: %d x %d x %d [m]" % [dim.x, dim.y, dim.z]
	else:
		dim_header.text = "Width: %d [m] | Slope: 1x1 [45°]" % dim.x
	dim_header.theme_type_variation = "StatLabel"
	properties_panel.add_child(dim_header)

	var scale_btn := Button.new()
	scale_btn.text = "Open Radial Action Ring & Dials"
	scale_btn.custom_minimum_size = Vector2(0, 36)
	UIFeedbackScript.wire(scale_btn, "select")
	scale_btn.pressed.connect(func():
		var vp_center = get_viewport().get_visible_rect().size * 0.5
		_open_block_radial_menu(selected_block, vp_center)
	)
	properties_panel.add_child(scale_btn)

	properties_panel.add_child(HSeparator.new())
	_add_section_header("Material Tint")

	var idx := selected_block
	var cpb := ColorPickerButton.new()
	cpb.color = blk["color"]
	cpb.custom_minimum_size = Vector2(0, 36)
	cpb.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	cpb.color_changed.connect(func(c: Color):
		_on_color_changed(idx, c)
	)
	properties_panel.add_child(cpb)

	properties_panel.add_child(HSeparator.new())
	_add_section_header("Actions")

	var dup_btn := Button.new()
	dup_btn.text = "[+] Duplicate (Ctrl+D)"
	dup_btn.custom_minimum_size = Vector2(0, 36)
	UIFeedbackScript.wire(dup_btn, "default")
	dup_btn.pressed.connect(_duplicate_selected)
	properties_panel.add_child(dup_btn)

	var mirror_btn := Button.new()
	mirror_btn.text = "Mirror Across X Axis"
	mirror_btn.custom_minimum_size = Vector2(0, 36)
	UIFeedbackScript.wire(mirror_btn, "default")
	mirror_btn.pressed.connect(_mirror_selected_x)
	properties_panel.add_child(mirror_btn)

	var del_btn := Button.new()
	del_btn.text = "[x] Delete Block (Del)"
	del_btn.custom_minimum_size = Vector2(0, 36)
	del_btn.theme_type_variation = "DangerButton"
	UIFeedbackScript.wire(del_btn, "danger")
	del_btn.pressed.connect(_delete_selected)
	properties_panel.add_child(del_btn)

	properties_panel.add_child(HSeparator.new())
	var sym_chk := CheckBox.new()
	sym_chk.text = "Enforce Left/Right Symmetry"
	sym_chk.button_pressed = symmetry_enabled
	UIFeedbackScript.wire(sym_chk, "default")
	sym_chk.toggled.connect(func(t: bool):
		symmetry_enabled = t
		if t:
			_relink_mirror_pairs()
			_update_status("Symmetry ON — Mirrored blocks linked")
		else:
			for b in blocks:
				b["mirror_partner"] = null
			_update_status("Symmetry OFF — Blocks edit independently")
	)
	properties_panel.add_child(sym_chk)

func _add_section_header(text: String) -> void:
	var lbl := Label.new()
	lbl.text = text.to_upper()
	lbl.theme_type_variation = "HeadingLabel"
	properties_panel.add_child(lbl)

func _on_color_changed(idx: int, color: Color) -> void:
	if idx < 0 or idx >= blocks.size():
		return
	blocks[idx]["color"] = color
	if blocks[idx].get("node"):
		_apply_node_color(blocks[idx]["node"], color)
	_sync_mirror_partner(blocks[idx])

# ── Bilateral Symmetry Logic ────────────────────────────────────────────────

func _mirror_selected_x() -> void:
	if selected_block < 0 or selected_block >= blocks.size():
		return
	if blocks.size() >= max_blocks:
		_show_warning("Maximum blocks reached")
		return

	var src = blocks[selected_block]
	var dim: Vector3i = src.get("dim", Vector3i.ONE)
	var new_coord := Vector3i(-src["grid_coord"].x, src["grid_coord"].y, src["grid_coord"].z)
	var mirr_rot := Vector3(src["rotation"].x, -src["rotation"].y, -src["rotation"].z)

	if not _can_occupy(new_coord, dim, mirr_rot):
		_show_warning("Cannot mirror: opposite grid space is occupied!")
		return

	var mirr = _add_block_at_grid(src["type"], new_coord, dim)
	if not mirr.is_empty():
		mirr["rotation"] = mirr_rot
		mirr["color"] = src["color"]
		if mirr.get("node"):
			mirr["node"].rotation = mirr["rotation"]
			_apply_node_color(mirr["node"], mirr["color"])
		_select_block(blocks.size() - 1)
		_update_status("Mirrored " + _block_name(src["type"]) + " across X")

func _has_partner(blk: Dictionary) -> bool:
	return blk.has("mirror_partner") and blk["mirror_partner"] != null

func _create_mirror_partner(blk: Dictionary) -> void:
	if _has_partner(blk):
		return
	if absf(blk["position"].x) <= SYMMETRY_CENTRE_EPS:
		return
	if blocks.size() >= max_blocks:
		return

	var dim: Vector3i = blk.get("dim", Vector3i.ONE)
	var new_coord := Vector3i(-blk["grid_coord"].x, blk["grid_coord"].y, blk["grid_coord"].z)
	var mirr_rot := Vector3(blk["rotation"].x, -blk["rotation"].y, -blk["rotation"].z)
	if not _can_occupy(new_coord, dim, mirr_rot):
		return

	var partner := {
		"type": blk["type"],
		"grid_coord": new_coord,
		"dim": dim,
		"position": grid_coord_to_pos(new_coord),
		"rotation": mirr_rot,
		"scale": blk["scale"],
		"color": blk["color"],
	}
	var node := _make_block_node(blk["type"], dim)
	node.position = partner["position"]
	node.rotation = partner["rotation"]
	_apply_node_color(node, partner["color"])
	partner["node"] = node

	partner["mirror_partner"] = blk
	blk["mirror_partner"] = partner

	hull_container.add_child(node)
	blocks.append(partner)
	_register_in_grid(partner)

func _sync_mirror_partner(blk: Dictionary) -> void:
	if not _has_partner(blk):
		return
	var partner = blk["mirror_partner"]
	var dim: Vector3i = blk.get("dim", Vector3i.ONE)
	var want_coord := Vector3i(-blk["grid_coord"].x, blk["grid_coord"].y, blk["grid_coord"].z)
	var mirr_rot := Vector3(blk["rotation"].x, -blk["rotation"].y, -blk["rotation"].z)

	if _can_occupy(want_coord, dim, mirr_rot, partner):
		_unregister_from_grid(partner)
		partner["grid_coord"] = want_coord
		partner["dim"] = dim
		partner["scale"] = blk["scale"]
		partner["position"] = grid_coord_to_pos(want_coord)
		partner["rotation"] = mirr_rot
		partner["color"] = blk["color"]
		if partner.get("node"):
			partner["node"].position = partner["position"]
			partner["node"].rotation = partner["rotation"]
			partner["node"].scale = partner["scale"]
			_apply_node_color(partner["node"], partner["color"])
		_register_in_grid(partner)

func _unlink_mirror_partner(blk: Dictionary) -> void:
	if not _has_partner(blk):
		return
	var partner = blk["mirror_partner"]
	if partner is Dictionary:
		partner["mirror_partner"] = null
	blk["mirror_partner"] = null

func _relink_mirror_pairs() -> void:
	for b in blocks:
		b["mirror_partner"] = null
	for i in range(blocks.size()):
		var a = blocks[i]
		if _has_partner(a) or absf(a["position"].x) <= SYMMETRY_CENTRE_EPS:
			continue
		var dim: Vector3i = a.get("dim", Vector3i.ONE)
		var exp_coord := Vector3i(-a["grid_coord"].x, a["grid_coord"].y, a["grid_coord"].z)
		for j in range(i + 1, blocks.size()):
			var b = blocks[j]
			if _has_partner(b) or b["type"] != a["type"]:
				continue
			if b["grid_coord"] == exp_coord and b.get("dim", Vector3i.ONE) == dim:
				a["mirror_partner"] = b
				b["mirror_partner"] = a
				break

# ── Export & Finalization (CSG Weld) ────────────────────────────────────────

func _on_export_clicked() -> void:
	if blocks.is_empty():
		_show_error("No blocks to export")
		return
	_show_export_dialog()

func _show_export_dialog() -> void:
	var dialog = AcceptDialog.new()
	dialog.title = "Save & Finalize Modular Hull"
	dialog.ok_button_text = "Save Hull"
	dialog.size = Vector2i(480, 520)

	var vbox = VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 10)
	dialog.add_child(vbox)

	var name_label = Label.new()
	name_label.text = "Hull Name:"
	vbox.add_child(name_label)

	var name_edit = LineEdit.new()
	name_edit.placeholder_text = "My_Modular_Hull"
	name_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	vbox.add_child(name_edit)
	vbox.add_child(HSeparator.new())

	var aabb := _calculate_aabb()
	var volume := aabb.size.x * aabb.size.y * aabb.size.z
	var hp: float = snappedf(100.0 + volume * 20.0, 0.1)
	var weight: float = snappedf(50.0 + volume * 15.0, 0.1)
	var metal := int(20 + volume * 5.0)
	var crystal := int(5 + volume * 1.0)

	var stats_display = Label.new()
	stats_display.text = "HP: %.1f\nWeight: %.1f\nMetal Cost: %d\nCrystal Cost: %d\nSize: %.2f x %.2f x %.2f m" % [
		hp, weight, metal, crystal, aabb.size.x, aabb.size.y, aabb.size.z
	]
	vbox.add_child(stats_display)
	vbox.add_child(HSeparator.new())

	var domain_label = Label.new()
	domain_label.text = "Domain:"
	vbox.add_child(domain_label)

	var domain_option = OptionButton.new()
	domain_option.add_item("Ground")
	domain_option.add_item("Naval")
	domain_option.add_item("Air")
	domain_option.add_item("Static Defense")
	domain_option.selected = 0
	vbox.add_child(domain_option)

	dialog.set_meta("name_edit", name_edit)
	dialog.set_meta("domain_option", domain_option)
	dialog.set_meta("aabb", aabb)
	dialog.set_meta("volume", volume)

	dialog.connect("confirmed", _on_export_confirmed.bind(dialog))
	dialog.connect("canceled", func(): dialog.queue_free())
	add_child(dialog)
	dialog.popup_centered()

func _on_export_confirmed(dialog: AcceptDialog) -> void:
	var name_edit = dialog.get_meta("name_edit")
	var domain_option = dialog.get_meta("domain_option")
	var aabb: AABB = dialog.get_meta("aabb")
	var volume: float = dialog.get_meta("volume")

	var display_name = name_edit.text.strip_edges()
	var hull_name = display_name
	if hull_name == "":
		hull_name = "custom_hull_%d" % Time.get_ticks_msec()
	hull_name = hull_name.to_lower().replace(" ", "_")
	if display_name == "":
		display_name = hull_name

	var domain = domain_option.get_item_text(domain_option.selected)
	dialog.queue_free()

	_update_status("CSG welding block assembly...")
	await get_tree().process_frame

	var baker_prims := _prepare_baker_primitives()
	var mesh := CSGMeshBaker.bake(baker_prims)
	if mesh == null:
		_show_error("CSG weld produced no geometry")
		return

	var mod_dir = "user://mods/hulls"
	DirAccess.make_dir_recursive_absolute(mod_dir)

	var mesh_path = "%s/%s.res" % [mod_dir, hull_name]
	var save_err = ResourceSaver.save(mesh, mesh_path)
	if save_err != OK:
		_show_error("Failed to save baked mesh: error %d" % save_err)
		return

	var baked_aabb := mesh.get_aabb()
	var baked_size := baked_aabb.size
	if baked_size.length_squared() < 0.01:
		baked_size = aabb.size

	var hp: float = snappedf(100.0 + volume * 20.0, 0.1)
	var weight: float = snappedf(50.0 + volume * 15.0, 0.1)
	var metal := int(20 + volume * 5.0)
	var crystal := int(5 + volume * 1.0)
	var sidecar = {
		"name": display_name,
		"hp": hp,
		"weight": weight,
		"metal": metal,
		"crystal": crystal,
		"size": [baked_size.x, baked_size.y, baked_size.z],
		"color": [hull_color.r, hull_color.g, hull_color.b, hull_color.a],
		"domain": domain,
		"category": "hull",
	}
	var write_err = _write_hull_sidecar(hull_name, sidecar)
	if not write_err:
		return

	HullLoader.reset_cache_for_tests()
	var tri_count = mesh.get_faces().size() / 3
	_update_status("Exported '%s' — %d triangles welded to %s" % [hull_name, tri_count, mesh_path])

func _prepare_baker_primitives() -> Array:
	var result := []
	for b in blocks:
		var csg_type := 0
		match b["type"]:
			BlockType.CUBE: csg_type = 0
			BlockType.WEDGE_45: csg_type = 3
		result.append({
			"type": csg_type,
			"position": b["position"],
			"rotation": b["rotation"],
			"scale": b.get("scale", Vector3.ONE),
		})
	return result

func _write_hull_sidecar(hull_name: String, data: Dictionary) -> bool:
	var json = JSON.new()
	var text = json.stringify(data, "\t")
	var path = "user://mods/hulls/%s.json" % hull_name
	var file = FileAccess.open(path, FileAccess.WRITE)
	if not file:
		_show_error("Failed to write hull sidecar to %s" % path)
		return false
	file.store_string(text)
	file.close()
	return true

func _calculate_aabb() -> AABB:
	var aabb := AABB()
	var first := true
	if blocks.is_empty():
		return aabb

	for blk in blocks:
		if not blk.get("node"):
			continue
		for mi in _find_mesh_instances(blk["node"]):
			if not mi.mesh:
				continue
			var world_aabb: AABB = mi.global_transform * mi.mesh.get_aabb()
			if first:
				aabb = world_aabb
				first = false
			else:
				aabb = aabb.merge(world_aabb)
	return aabb

func _find_mesh_instances(node: Node3D) -> Array:
	var result = []
	if not node or node == _gizmo_root:
		return result
	if node is MeshInstance3D:
		result.append(node)
	for child in node.get_children():
		if child == _gizmo_root:
			continue
		result.append_array(_find_mesh_instances(child))
	return result

# ── Assembly Serialization ──────────────────────────────────────────────────

const ASSEMBLY_DIR := "user://hull_assemblies"

func serialize_assembly(hull_name: String = "", sidecar: Dictionary = {}) -> Dictionary:
	var blk_list := []
	for blk in blocks:
		var c: Vector3i = blk["grid_coord"]
		var d: Vector3i = blk.get("dim", Vector3i.ONE)
		var r: Vector3 = blk["rotation"]
		var col: Color = blk["color"]
		blk_list.append({
			"type": _block_type_to_string(blk["type"]),
			"grid_coord": [c.x, c.y, c.z],
			"dim": [d.x, d.y, d.z],
			"rotation": [r.x, r.y, r.z],
			"color": [col.r, col.g, col.b, col.a],
		})
	return {
		"schema_version": 3,
		"hull_name": hull_name,
		"grid_unit": grid_unit,
		"sidecar": sidecar,
		"blocks": blk_list,
	}

func deserialize_assembly(data: Dictionary) -> bool:
	if typeof(data) != TYPE_DICTIONARY:
		_show_error("Not a valid hull assembly file")
		return false

	_on_clear_clicked()
	if data.has("blocks"):
		for entry in data["blocks"]:
			var type := _string_to_block_type(str(entry.get("type", "CUBE")))
			var coord_arr = entry.get("grid_coord", [0, 0, 0])
			var coord := Vector3i(int(coord_arr[0]), int(coord_arr[1]), int(coord_arr[2]))
			var dim_arr = entry.get("dim", [1, 1, 1])
			var dim := Vector3i(int(dim_arr[0]), int(dim_arr[1]), int(dim_arr[2]))
			var blk = _add_block_at_grid(type, coord, dim)
			if not blk.is_empty():
				var rot_arr = entry.get("rotation", [0, 0, 0])
				blk["rotation"] = Vector3(float(rot_arr[0]), float(rot_arr[1]), float(rot_arr[2]))
				var col_arr = entry.get("color", [0.7, 0.7, 0.8, 1.0])
				blk["color"] = Color(col_arr[0], col_arr[1], col_arr[2], col_arr[3] if col_arr.size() > 3 else 1.0)
				if blk.get("node"):
					blk["node"].rotation = blk["rotation"]
					_apply_node_color(blk["node"], blk["color"])

	_relink_mirror_pairs()
	_deselect()
	return true

func _block_type_to_string(type: BlockType) -> String:
	match type:
		BlockType.CUBE: return "CUBE"
		BlockType.WEDGE_45: return "WEDGE_45"
		_: return "CUBE"

func _string_to_block_type(name: String) -> BlockType:
	match name.to_upper():
		"CUBE", "BOX", "CHAMFER_BOX": return BlockType.CUBE
		"WEDGE_45", "WEDGE", "SLOPE", "INNER_CORNER", "OUTER_CORNER": return BlockType.WEDGE_45
		_: return BlockType.CUBE

func _on_save_assembly_clicked() -> void:
	if blocks.is_empty():
		_show_error("Nothing to save")
		return
	DirAccess.make_dir_recursive_absolute(ASSEMBLY_DIR)
	var dialog := FileDialog.new()
	dialog.file_mode = FileDialog.FILE_MODE_SAVE_FILE
	dialog.access = FileDialog.ACCESS_FILESYSTEM
	dialog.current_dir = ProjectSettings.globalize_path(ASSEMBLY_DIR)
	dialog.add_filter("*.json", "Hull Assembly")
	dialog.size = Vector2i(700, 500)
	dialog.file_selected.connect(func(path: String):
		var stem := path.get_file().get_basename()
		var data := serialize_assembly(stem)
		var f := FileAccess.open(path, FileAccess.WRITE)
		if not f:
			_show_error("Could not write %s" % path)
			return
		f.store_string(JSON.stringify(data, "\t"))
		f.close()
		_update_status("Saved assembly: %s (%d blocks)" % [stem, blocks.size()])
		dialog.queue_free()
	)
	dialog.canceled.connect(func(): dialog.queue_free())
	add_child(dialog)
	dialog.popup_centered()

func _on_load_assembly_clicked() -> void:
	DirAccess.make_dir_recursive_absolute(ASSEMBLY_DIR)
	var dialog := FileDialog.new()
	dialog.file_mode = FileDialog.FILE_MODE_OPEN_FILE
	dialog.access = FileDialog.ACCESS_FILESYSTEM
	dialog.current_dir = ProjectSettings.globalize_path(ASSEMBLY_DIR)
	dialog.add_filter("*.json", "Hull Assembly")
	dialog.size = Vector2i(700, 500)
	dialog.file_selected.connect(func(path: String):
		var f := FileAccess.open(path, FileAccess.READ)
		if not f:
			_show_error("Could not read %s" % path)
			return
		var text := f.get_as_text()
		f.close()
		var json := JSON.new()
		if json.parse(text) != OK:
			_show_error("Bad JSON: %s" % json.get_error_message())
			return
		if deserialize_assembly(json.get_data()):
			_update_status("Loaded assembly: %s (%d blocks)" % [path.get_file().get_basename(), blocks.size()])
		dialog.queue_free()
	)
	dialog.canceled.connect(func(): dialog.queue_free())
	add_child(dialog)
	dialog.popup_centered()

func _on_clear_clicked() -> void:
	_detach_gizmo()
	for b in blocks:
		if b.get("node"):
			b["node"].queue_free()
	blocks.clear()
	_spatial_dict.clear()
	selected_block = -1
	has_origin = false
	_update_properties_panel()
	_update_status("Cleared all blocks")

func _on_back_clicked() -> void:
	var router = get_node_or_null("/root/SceneRouter")
	if router:
		router.goto("res://scenes/MainMenu.tscn")
	else:
		get_tree().change_scene_to_file("res://scenes/MainMenu.tscn")

# ── Status Helpers ───────────────────────────────────────────────────────────

func _update_status(msg: String) -> void:
	if status_label:
		status_label.text = msg

func _show_error(msg: String) -> void:
	_update_status("ERROR: " + msg)
	if get_tree():
		await get_tree().create_timer(3.0).timeout
		_update_status("Ready")

func _show_warning(msg: String) -> void:
	_update_status("WARNING: " + msg)
	if get_tree():
		await get_tree().create_timer(3.0).timeout
		_update_status("Ready")
