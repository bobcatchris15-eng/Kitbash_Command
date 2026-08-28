extends Node3D
class_name TerrainSculpt
# In-engine high-performance terrain authoring workbench for v2 maps.
#
# Features:
# 1. 3D Brush Sculpting (Raise, Lower, Smooth, Flatten) - ultra-fast local mesh updates.
# 2. Real Live Splat Texture Painting (Grass, Rock, Forest, Sand, Mud).
# 3. 2-Point Click-to-Build Bridges (Click Point A -> Click Point B across rivers/chasms with live preview).
# 4. 2-Point Click-to-Build Roads (Click Point A -> Click Point B with smooth leveling & splat painting).
# 5. Direct Tree & Rock Greeble Painting & Erasing with Live MultiMesh Preview & instant Authored Props saving.
# 6. Full Multi-Level Undo System (Ctrl+Z and UI button) covering sculpting, painting, props, bridges, roads & spawns.
# 7. Streamlined Friendly & Enemy Spawns with 1-click symmetry and base zone bounds.
# 8. Full Camera Orbit, WASD / Arrow Pan, Q/E rotation, R/F tilt, Home reset.

const TerrainBuilderScript = preload("res://scripts/terrain_builder.gd")
const MapCatalogScript = preload("res://scripts/map_catalog.gd")
const Tokens = preload("res://scripts/ui_tokens.gd")

enum Mode {
	SCULPT = 0,
	PAINT = 1,
	ROADS_BRIDGES = 2,
	GREEBLES = 3,
	FEATURES = 4,
	SPAWNS = 5,
	SETTINGS = 6,
}

enum SculptTool {
	RAISE = 0,
	LOWER = 1,
	SMOOTH = 2,
	FLATTEN = 3,
}

enum GreebleType {
	TREE = 0,
	BOULDER = 1,
	SPIRE = 2,
	SHRUB = 3,
	ERASER = 4,
}

const PREVIEW_DIVS := 128
const SCULPT_GRID_DIM := 192
const SPLAT_RES := 512

const AMBIENT_TREE_MODEL_DIR := "res://assets/models/terrain/ambient_tree_%d.glb"
const AMBIENT_TREE_POOL_SIZE := 36
const BOULDER_MODEL_DIR := "res://assets/models/terrain/boulder_%d.glb"
const BOULDER_POOL_SIZE := 35
const ROCK_SPIRE_MODEL_DIR := "res://assets/models/terrain/rock_spire_%d.glb"
const ROCK_SPIRE_POOL_SIZE := 4
const SHRUB_MODEL_DIR := "res://assets/models/terrain/shrub_%d.glb"
const SHRUB_POOL_SIZE := 4

const FEATURE_TYPES := ["plateau", "canyon", "ridge", "ramp", "hill", "lake"]
const FEATURE_DEFAULTS := {
	"plateau": {"half_extents": [180.0, 140.0], "height": 22.0, "wall_falloff": 6.0},
	"canyon": {"width": 130.0, "depth": 26.0, "wall_falloff": 8.0, "length": 400.0},
	"ridge": {"width": 90.0, "height": 18.0, "falloff": 46.0, "length": 300.0},
	"ramp": {"width": 84.0, "length": 70.0, "top_height": 22.0, "direction_deg": 0.0},
	"hill": {"radius": 150.0, "height": 26.0, "falloff": 90.0},
	"lake": {"radius": 130.0, "depth": 12.0, "shoreline_falloff": 40.0},
}

const SURFACE_TYPES := [
	{"id": "grass", "name": "Grassland / Plains (Base)", "color": Color(0.35, 0.75, 0.30, 0.95), "channel": "r"},
	{"id": "rock", "name": "Rocky / Mountain Stone", "color": Color(0.65, 0.60, 0.55, 0.95), "channel": "g"},
	{"id": "forest", "name": "Forest / Dirt / Mud", "color": Color(0.18, 0.52, 0.22, 0.95), "channel": "b"},
	{"id": "sand", "name": "Sand / Desert Dune", "color": Color(0.88, 0.78, 0.40, 0.95), "channel": "a"},
	{"id": "water", "name": "Water (Carve Lake/River)", "color": Color(0.20, 0.55, 0.95, 0.95), "channel": "water"},
]

const THEME_PRESETS := {
	"grassland": {
		"name": "Grassland Valley",
		"ground_color": Color(0.30, 0.35, 0.26),
		"sky_top": Color(0.24, 0.35, 0.48),
		"sky_horizon": Color(0.55, 0.58, 0.55),
	},
	"steppe": {
		"name": "Arid Steppe",
		"ground_color": Color(0.36, 0.32, 0.22),
		"sky_top": Color(0.30, 0.38, 0.46),
		"sky_horizon": Color(0.62, 0.58, 0.48),
	},
	"desert": {
		"name": "Desert / Canyon",
		"ground_color": Color(0.48, 0.40, 0.28),
		"sky_top": Color(0.32, 0.42, 0.52),
		"sky_horizon": Color(0.70, 0.62, 0.50),
	},
	"tundra": {
		"name": "Tundra / Fjord",
		"ground_color": Color(0.55, 0.58, 0.60),
		"sky_top": Color(0.20, 0.28, 0.40),
		"sky_horizon": Color(0.50, 0.54, 0.60),
	},
	"volcanic": {
		"name": "Volcanic Ash",
		"ground_color": Color(0.22, 0.22, 0.22),
		"sky_top": Color(0.20, 0.20, 0.24),
		"sky_horizon": Color(0.40, 0.36, 0.35),
	},
}

# --- State ---
var map_id: String = ""
var _map: Dictionary = {}
var _selected_feature: int = -1
var _selected_bridge: int = -1
var _dragging_spawn_id: String = ""
var _is_click_placing: bool = false
var _click_place_type: String = ""
var _dirty: bool = false

# Undo System
var _undo_stack: Array = []
const MAX_UNDO_STATES := 35

# Preallocated Mesh Buffers
var _grid_heights := PackedFloat32Array()
var _grid_verts := PackedVector3Array()
var _grid_norms := PackedVector3Array()
var _grid_uvs := PackedVector2Array()
var _grid_indices := PackedInt32Array()
var _mesh_allocated: bool = false

# Live Splat Texture Painting Buffers
var _splat_img: Image = null
var _splat_tex: ImageTexture = null

# 2-Point Road & Bridge State
# 0 = Idle, 1 = Waiting for Point A click, 2 = Point A set, waiting for Point B click
var _bridge_click_step: int = 0
var _bridge_point_a: Vector3 = Vector3.ZERO
var _bridge_width: float = 18.0
var _bridge_deck_height: float = 1.2

# 0 = Idle, 1 = Waiting for Point A click, 2 = Point A set, waiting for Point B click
var _road_click_step: int = 0
var _road_point_a: Vector3 = Vector3.ZERO
var _road_width: float = 14.0
var _road_surface: String = "dirt" # dirt, gravel, sand

# Direct Greebles & Props Painting State
var _greeble_tool: int = GreebleType.TREE
var _greeble_radius: float = 35.0
var _greeble_density: float = 1.2
var _greeble_scale_min: float = 1.8
var _greeble_scale_max: float = 3.2
var _greeble_single_click: bool = false
var _props_list: Array = [] # Array of {type, variant, pos: [x,y,z], scale, yaw}

# Mode & Tool state
var _mode: int = Mode.SCULPT
var _sculpt_tool: int = SculptTool.RAISE
var _brush_radius: float = 45.0
var _brush_strength: float = 8.0
var _brush_falloff: String = "smooth"
var _flatten_target_h: float = 0.0
var _flatten_anchor_set: bool = false

var _paint_surface: String = "forest"
# Painted water. _water_img is the RGBA raster TerrainBuilder decodes (R
# coverage, GB a 16-bit surface height); _water_paint_level is the height the
# brush lays down, and _water_level_follow_ground samples the terrain under the
# cursor instead, which is how you fill a valley you just carved without
# reading its depth off a spinbox first.
var _water_img: Image = null
var _water_paint_level: float = 0.0
var _water_level_follow_ground: bool = true
var _water_paint_erase: bool = false
var _painted_water_node: MeshInstance3D = null
var _paint_brush_size: float = 35.0
var _paint_strength: float = 0.75

# 3D Scene Nodes
var _ground: MeshInstance3D = null
var _water_node: MeshInstance3D = null
var _bridges_node: Node3D = null
var _props_node: Node3D = null
var _handles: Node3D = null
var _spawn_markers: Node3D = null
var _preview_line: MeshInstance3D = null
var _cursor_ring: MeshInstance3D = null
var _cam_pivot: Node3D = null
var _cam: Camera3D = null
var _cam_dist: float = 600.0
var _cam_yaw: float = 0.6
var _cam_pitch: float = -0.62
var _is_topdown: bool = false

# Mouse tracking
var _is_mouse_down: bool = false
var _mouse_screen_pos: Vector2 = Vector2.ZERO
var _last_hit_point: Vector3 = Vector3.ZERO
var _has_valid_hit: bool = false

# UI Nodes
var _ui: Control = null
var _map_selector: OptionButton = null
var _tab_container: TabContainer = null
var _feature_list: ItemList = null
var _feature_props: VBoxContainer = null
var _bridges_list: ItemList = null
var _bridge_props: VBoxContainer = null
var _spawns_container: VBoxContainer = null
var _status: Label = null
var _scale_readout: Label = null
var _new_map_dialog: PanelContainer = null
var _ring_material: StandardMaterial3D = null
var _last_ring_radius: float = -1.0
var _cursor_dirty: bool = true
var _last_flat_stamp_pos: Vector3 = Vector3(INF, INF, INF)


func _ready() -> void:
	name = "TerrainSculpt"
	_build_world()
	_build_cursor_ring()
	_build_preview_line()
	_build_ui()
	
	var want := map_id if map_id != "" else _first_v2_map()
	if want != "":
		load_map(want)
	else:
		_set_status("No v2 map found. Click 'New Map' to start one.", Tokens.SIGNAL_HAZARD)


static func _first_v2_map() -> String:
	for mid in MapCatalogScript.get_map_ids():
		if TerrainBuilderScript.terrain_generator(MapCatalogScript.get_map(mid)) == "v2":
			return str(mid)
	return ""


# ==============================================================================
# UNDO SYSTEM
# ==============================================================================

func _push_undo() -> void:
	if _map.is_empty():
		return
	var snapshot := {
		"map": _map.duplicate(true),
		"props": _props_list.duplicate(true),
		"splat_img": _splat_img.duplicate() if _splat_img != null else null,
		"water_img": _water_img.duplicate() if _water_img != null else null
	}
	_undo_stack.append(snapshot)
	if _undo_stack.size() > MAX_UNDO_STATES:
		_undo_stack.pop_front()


func _undo() -> void:
	if _undo_stack.is_empty():
		_set_status("Nothing to undo.", Tokens.TEXT_SECONDARY)
		return
	var snapshot: Dictionary = _undo_stack.pop_back()
	_map = snapshot["map"].duplicate(true)
	_props_list = snapshot["props"].duplicate(true)
	_map["props"] = _props_list

	if snapshot.has("water_img"):
		var wi = snapshot["water_img"]
		_water_img = (wi as Image).duplicate() if wi != null else null
		_refresh_painted_water_preview()
	if snapshot.has("splat_img") and snapshot["splat_img"] != null:
		var img_copy: Image = snapshot["splat_img"]
		_splat_img = img_copy.duplicate()
		if _splat_tex != null:
			_splat_tex.update(_splat_img)

	_bridge_click_step = 0
	_road_click_step = 0
	if _preview_line != null:
		_preview_line.visible = false

	_refresh_bridges_in_scene()
	_refresh_bridges_ui()
	_refresh_props_multimesh()
	_refresh_spawn_markers()
	_build_spawns_tab_content()
	_refresh_feature_list()
	_refresh_feature_props()
	_refresh_handles()
	_rebuild_preview()
	_set_status("Undid action.", Tokens.SIGNAL_GO)


# ==============================================================================
# WORLD & CAMERA SETUP
# ==============================================================================

func _build_world() -> void:
	var env := WorldEnvironment.new()
	var e := Environment.new()
	e.background_mode = Environment.BG_SKY
	var sky := Sky.new()
	var sm := ProceduralSkyMaterial.new()
	sm.sky_top_color = Color(0.22, 0.28, 0.38)
	sm.sky_horizon_color = Color(0.48, 0.50, 0.52)
	sm.ground_horizon_color = Color(0.32, 0.32, 0.32)
	sm.ground_bottom_color = Color(0.16, 0.16, 0.16)
	sky.sky_material = sm
	e.sky = sky
	e.tonemap_mode = Environment.TONE_MAPPER_AGX
	e.tonemap_exposure = 1.6
	e.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	e.ambient_light_color = Color(0.55, 0.55, 0.52)
	e.ambient_light_energy = 0.95
	e.ssao_enabled = false
	env.environment = e
	add_child(env)

	var sun := DirectionalLight3D.new()
	sun.light_energy = 1.8
	sun.rotation_degrees = Vector3(-52.0, 34.0, 0.0)
	sun.shadow_enabled = true
	sun.directional_shadow_max_distance = 600.0
	add_child(sun)

	_ground = MeshInstance3D.new()
	_ground.name = "Ground"
	add_child(_ground)

	_water_node = MeshInstance3D.new()
	_water_node.name = "Water"
	_water_node.visible = false
	add_child(_water_node)

	_bridges_node = Node3D.new()
	_bridges_node.name = "Bridges"
	add_child(_bridges_node)

	_props_node = Node3D.new()
	_props_node.name = "Props"
	add_child(_props_node)

	_handles = Node3D.new()
	_handles.name = "Handles"
	_handles.visible = false
	add_child(_handles)

	_spawn_markers = Node3D.new()
	_spawn_markers.name = "SpawnMarkers"
	_spawn_markers.visible = true
	add_child(_spawn_markers)

	_cam_pivot = Node3D.new()
	add_child(_cam_pivot)
	_cam = Camera3D.new()
	_cam.fov = 50.0
	_cam.far = 14000.0
	_cam_pivot.add_child(_cam)
	_update_camera()


func _build_cursor_ring() -> void:
	_cursor_ring = MeshInstance3D.new()
	_cursor_ring.name = "CursorRing"
	
	var im := ImmediateMesh.new()
	_cursor_ring.mesh = im
	
	_ring_material = StandardMaterial3D.new()
	_ring_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_ring_material.albedo_color = Color(0.2, 1.0, 0.4, 0.95)
	_ring_material.no_depth_test = true
	_ring_material.cull_mode = BaseMaterial3D.CULL_DISABLED
	_ring_material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	_ring_material.render_priority = 15
	_cursor_ring.material_override = _ring_material
	_cursor_ring.visible = false
	add_child(_cursor_ring)


func _build_preview_line() -> void:
	_preview_line = MeshInstance3D.new()
	_preview_line.name = "PreviewLine"
	var im := ImmediateMesh.new()
	_preview_line.mesh = im
	var lmat := StandardMaterial3D.new()
	lmat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	lmat.albedo_color = Color(1.0, 0.85, 0.2, 0.95)
	lmat.no_depth_test = true
	lmat.render_priority = 16
	_preview_line.material_override = lmat
	_preview_line.visible = false
	add_child(_preview_line)


func _update_preview_line(p_start: Vector3, p_end: Vector3, width: float = 14.0) -> void:
	if _preview_line == null:
		return
	var im: ImmediateMesh = _preview_line.mesh as ImmediateMesh
	if im == null:
		return
	im.clear_surfaces()
	
	var span_xz := Vector3(p_end.x - p_start.x, 0.0, p_end.z - p_start.z)
	if span_xz.length_squared() < 0.1:
		_preview_line.visible = false
		return
		
	var fwd := span_xz.normalized()
	var right := Vector3(-fwd.z, 0.0, fwd.x) * (width * 0.5)
	
	im.surface_begin(Mesh.PRIMITIVE_TRIANGLE_STRIP)
	im.surface_add_vertex(p_start - right + Vector3(0, 0.5, 0))
	im.surface_add_vertex(p_start + right + Vector3(0, 0.5, 0))
	im.surface_add_vertex(p_end - right + Vector3(0, 0.5, 0))
	im.surface_add_vertex(p_end + right + Vector3(0, 0.5, 0))
	im.surface_end()
	
	im.surface_begin(Mesh.PRIMITIVE_LINES)
	im.surface_add_vertex(p_start + Vector3(0, 0.8, 0))
	im.surface_add_vertex(p_end + Vector3(0, 0.8, 0))
	im.surface_end()
	_preview_line.visible = true


func _update_cursor_ring_mesh(radius: float) -> void:
	if _cursor_ring == null:
		return
	if is_equal_approx(radius, _last_ring_radius):
		return
	_last_ring_radius = radius
	var im: ImmediateMesh = _cursor_ring.mesh as ImmediateMesh
	if im == null:
		return
	im.clear_surfaces()
	
	im.surface_begin(Mesh.PRIMITIVE_TRIANGLE_STRIP)
	var segs := 64
	var half_thick := maxf(2.0, radius * 0.045)
	var r_in := maxf(0.1, radius - half_thick)
	var r_out := radius + half_thick
	for i in range(segs + 1):
		var ang := (float(i) / float(segs)) * TAU
		var ca := cos(ang)
		var sa := sin(ang)
		im.surface_add_vertex(Vector3(ca * r_out, 0.4, sa * r_out))
		im.surface_add_vertex(Vector3(ca * r_in, 0.4, sa * r_in))
	im.surface_end()
	
	im.surface_begin(Mesh.PRIMITIVE_LINES)
	var ch_len := minf(radius * 0.5, 12.0)
	im.surface_add_vertex(Vector3(-ch_len, 0.4, 0.0))
	im.surface_add_vertex(Vector3(ch_len, 0.4, 0.0))
	im.surface_add_vertex(Vector3(0.0, 0.4, -ch_len))
	im.surface_add_vertex(Vector3(0.0, 0.4, ch_len))
	im.surface_end()


func _update_camera() -> void:
	if _cam == null or _cam_pivot == null:
		return
	if _is_topdown:
		_cam.position = Vector3(0.0, _cam_dist, 0.001)
		if _cam.is_inside_tree():
			_cam.look_at(_cam_pivot.global_position, Vector3.FORWARD)
	else:
		var dir := Vector3(
			cos(_cam_pitch) * sin(_cam_yaw),
			-sin(_cam_pitch),
			cos(_cam_pitch) * cos(_cam_yaw))
		_cam.position = dir.normalized() * _cam_dist
		if _cam.is_inside_tree():
			_cam.look_at(_cam_pivot.global_position, Vector3.UP)


func _rotate_camera_degrees(deg: float) -> void:
	_cam_yaw += deg_to_rad(deg)
	if _is_topdown:
		_is_topdown = false
	_update_camera()
	_set_status("Camera Rotation: %.0f°" % rad_to_deg(_cam_yaw), Tokens.TEXT_SECONDARY)


func _reset_camera_view() -> void:
	_cam_yaw = 0.6
	_cam_pitch = -0.62
	_is_topdown = false
	if _cam_pivot != null:
		_cam_pivot.position = Vector3.ZERO
	_cam_dist = float(_map.get("map_half_extents", 960.0)) * 1.4
	_update_camera()
	_set_status("Camera reset to center isometric view.", Tokens.TEXT_SECONDARY)


# ==============================================================================
# INPUT & INTERACTION
# ==============================================================================

func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed:
		if event.keycode == KEY_Z and event.ctrl_pressed:
			_undo()
		elif event.keycode == KEY_T:
			_is_topdown = not _is_topdown
			_update_camera()
			_set_status("Camera: %s" % ["Top-Down 2D" if _is_topdown else "3D Orbit"], Tokens.TEXT_SECONDARY)
		elif event.keycode == KEY_F and not event.ctrl_pressed:
			_toggle_commander_view()
		elif event.keycode == KEY_HOME or event.keycode == KEY_BACKSPACE:
			_reset_camera_view()
		elif event.keycode == KEY_ESCAPE:
			if _bridge_click_step > 0:
				_bridge_click_step = 0
				if _preview_line != null: _preview_line.visible = false
				_set_status("Cancelled bridge placement.", Tokens.TEXT_SECONDARY)
			elif _road_click_step > 0:
				_road_click_step = 0
				if _preview_line != null: _preview_line.visible = false
				_set_status("Finished / cancelled road placement.", Tokens.TEXT_SECONDARY)
			elif _is_click_placing:
				_is_click_placing = false
				if _cursor_ring != null: _cursor_ring.visible = false
				_set_status("Cancelled placement.", Tokens.TEXT_SECONDARY)
		elif event.keycode == KEY_BRACKETLEFT:
			if _mode == Mode.SCULPT:
				_brush_radius = maxf(5.0, _brush_radius - 5.0)
				_update_cursor_ring_mesh(_brush_radius)
			elif _mode == Mode.PAINT:
				_paint_brush_size = maxf(5.0, _paint_brush_size - 5.0)
				_update_cursor_ring_mesh(_paint_brush_size)
			elif _mode == Mode.GREEBLES:
				_greeble_radius = maxf(5.0, _greeble_radius - 5.0)
				_update_cursor_ring_mesh(_greeble_radius)
		elif event.keycode == KEY_BRACKETRIGHT:
			if _mode == Mode.SCULPT:
				_brush_radius = minf(300.0, _brush_radius + 5.0)
				_update_cursor_ring_mesh(_brush_radius)
			elif _mode == Mode.PAINT:
				_paint_brush_size = minf(300.0, _paint_brush_size + 5.0)
				_update_cursor_ring_mesh(_paint_brush_size)
			elif _mode == Mode.GREEBLES:
				_greeble_radius = minf(300.0, _greeble_radius + 5.0)
				_update_cursor_ring_mesh(_greeble_radius)
		elif event.keycode == KEY_MINUS and not event.ctrl_pressed:
			if _mode == Mode.GREEBLES:
				_greeble_scale_min = maxf(0.2, _greeble_scale_min * 0.85)
				_greeble_scale_max = maxf(0.3, _greeble_scale_max * 0.85)
				_set_status("Prop Placement Scale: %.1fx - %.1fx" % [_greeble_scale_min, _greeble_scale_max], Tokens.SIGNAL_GO)
		elif (event.keycode == KEY_EQUAL or event.keycode == KEY_PLUS) and not event.ctrl_pressed:
			if _mode == Mode.GREEBLES:
				_greeble_scale_min = minf(30.0, _greeble_scale_min * 1.15)
				_greeble_scale_max = minf(40.0, _greeble_scale_max * 1.15)
				_set_status("Prop Placement Scale: %.1fx - %.1fx" % [_greeble_scale_min, _greeble_scale_max], Tokens.SIGNAL_GO)

	if event is InputEventMouseButton:
		if event.button_index == MOUSE_BUTTON_WHEEL_UP and event.pressed:
			_cam_dist = maxf(40.0, _cam_dist * 0.88)
			_update_camera()
		elif event.button_index == MOUSE_BUTTON_WHEEL_DOWN and event.pressed:
			_cam_dist = minf(8000.0, _cam_dist * 1.14)
			_update_camera()
		elif event.button_index == MOUSE_BUTTON_LEFT:
			if not event.alt_pressed:
				_is_mouse_down = event.pressed
				if event.pressed:
					_mouse_screen_pos = event.position
					_flatten_anchor_set = false
					_handle_click(event.position, event.ctrl_pressed, event.shift_pressed)
				else:
					_flatten_anchor_set = false
					_dragging_spawn_id = ""

	elif event is InputEventMouseMotion:
		_mouse_screen_pos = event.position
		_cursor_dirty = true
		
		var is_orbit: bool = ((event.button_mask & MOUSE_BUTTON_MASK_RIGHT) != 0) or (((event.button_mask & MOUSE_BUTTON_MASK_LEFT) != 0) and event.alt_pressed)
		if is_orbit:
			_cam_yaw -= event.relative.x * 0.006
			_cam_pitch = clampf(_cam_pitch - event.relative.y * 0.005, -1.50, -0.08)
			if _is_topdown:
				_is_topdown = false
			_update_camera()
		elif (event.button_mask & MOUSE_BUTTON_MASK_MIDDLE) != 0:
			var right := _cam.global_transform.basis.x
			var fwd := Vector3(right.z, 0.0, -right.x) if not _is_topdown else -_cam.global_transform.basis.y
			_cam_pivot.position -= (right * event.relative.x + fwd * -event.relative.y) * (_cam_dist * 0.0015)
		elif _is_mouse_down and (event.button_mask & MOUSE_BUTTON_MASK_LEFT) != 0 and not event.alt_pressed:
			_update_cursor_position(event.position)
			_cursor_dirty = false
			_handle_drag(event.position, event.ctrl_pressed, event.shift_pressed)


func _process(delta: float) -> void:
	var vp := get_viewport()
	var focus_owner = vp.gui_get_focus_owner() if vp != null else null
	var is_typing: bool = (focus_owner is LineEdit or focus_owner is TextEdit)
	
	if not is_typing:
		var rot_speed := 2.2 * delta
		var pan_speed := maxf(90.0, _cam_dist * 0.85) * delta
		
		if Input.is_key_pressed(KEY_Q):
			_cam_yaw += rot_speed
			if _is_topdown: _is_topdown = false
			_update_camera()
		if Input.is_key_pressed(KEY_E):
			_cam_yaw -= rot_speed
			if _is_topdown: _is_topdown = false
			_update_camera()
			
		if Input.is_key_pressed(KEY_R) and not Input.is_key_pressed(KEY_CTRL):
			_cam_pitch = clampf(_cam_pitch + rot_speed * 0.7, -1.50, -0.08)
			if _is_topdown: _is_topdown = false
			_update_camera()
		if Input.is_key_pressed(KEY_F) and not Input.is_key_pressed(KEY_CTRL):
			_cam_pitch = clampf(_cam_pitch - rot_speed * 0.7, -1.50, -0.08)
			if _is_topdown: _is_topdown = false
			_update_camera()

		var p_dir := Vector3.ZERO
		var fwd := Vector3(sin(_cam_yaw), 0.0, cos(_cam_yaw))
		var right := Vector3(cos(_cam_yaw), 0.0, -sin(_cam_yaw))
		if Input.is_key_pressed(KEY_W) or Input.is_key_pressed(KEY_UP):
			p_dir -= fwd
		if Input.is_key_pressed(KEY_S) or Input.is_key_pressed(KEY_DOWN):
			p_dir += fwd
		if Input.is_key_pressed(KEY_A) or Input.is_key_pressed(KEY_LEFT):
			p_dir -= right
		if Input.is_key_pressed(KEY_D) or Input.is_key_pressed(KEY_RIGHT):
			p_dir += right
			
		if p_dir != Vector3.ZERO:
			_cam_pivot.position += p_dir.normalized() * pan_speed
			_update_camera()

	if _cursor_dirty and not _is_mouse_down:
		_cursor_dirty = false
		_update_cursor_position(_mouse_screen_pos)

	if _is_mouse_down and _has_valid_hit:
		if _mode == Mode.SCULPT:
			var ctrl := Input.is_key_pressed(KEY_CTRL)
			var shift := Input.is_key_pressed(KEY_SHIFT)
			if _brush_falloff != "flat":
				_apply_sculpt_stroke(_last_hit_point, delta, ctrl, shift)
			else:
				var dist_moved := (_last_hit_point - _last_flat_stamp_pos).length()
				if dist_moved >= _brush_radius * 0.35:
					_apply_sculpt_stroke(_last_hit_point, delta, ctrl, shift)
					_last_flat_stamp_pos = _last_hit_point
		elif _mode == Mode.PAINT:
			_apply_paint_stroke(_last_hit_point, delta)
		elif _mode == Mode.GREEBLES and not _greeble_single_click:
			_apply_greeble_stroke(_last_hit_point, delta)


func _update_cursor_position(screen_pos: Vector2) -> void:
	if _map.is_empty() or _cam == null or _cursor_ring == null:
		return
	var from := _cam.project_ray_origin(screen_pos)
	var dir := _cam.project_ray_normal(screen_pos)
	var hit = _fast_raymarch(from, dir)
	if hit != null:
		_has_valid_hit = true
		_last_hit_point = hit
		var norm: Vector3 = _get_terrain_normal(hit.x, hit.z)
		_cursor_ring.position = hit + norm * 0.35
		if norm.cross(Vector3.UP).length_squared() > 0.001:
			_cursor_ring.look_at(hit + norm, Vector3.UP if absf(norm.y) < 0.95 else Vector3.FORWARD)
			_cursor_ring.rotate_object_local(Vector3.RIGHT, deg_to_rad(-90.0))
		else:
			_cursor_ring.rotation = Vector3.ZERO
		_cursor_ring.visible = (_mode == Mode.SCULPT or _mode == Mode.PAINT or _mode == Mode.GREEBLES or _mode == Mode.ROADS_BRIDGES or _is_click_placing)
		
		if _scale_readout != null:
			var slope_deg := rad_to_deg(acos(clampf(norm.y, 0.0, 1.0)))
			var active_rad := _brush_radius if _mode == Mode.SCULPT else (_paint_brush_size if _mode == Mode.PAINT else _greeble_radius)
			var tank_equiv := maxf(1.0, (active_rad * 2.0) / 4.5)
			_scale_readout.text = "Elevation: %.1fm (Slope: %.0f°) | Brush: %.0fm (~%.0f tanks)" % [hit.y, slope_deg, active_rad * 2.0, tank_equiv]

		if _mode == Mode.SCULPT:
			_update_cursor_ring_mesh(_brush_radius)
			match _sculpt_tool:
				SculptTool.RAISE:
					_ring_material.albedo_color = Color(0.2, 1.0, 0.35, 0.95)
				SculptTool.LOWER:
					_ring_material.albedo_color = Color(1.0, 0.25, 0.2, 0.95)
				SculptTool.SMOOTH:
					_ring_material.albedo_color = Color(0.2, 0.7, 1.0, 0.95)
				SculptTool.FLATTEN:
					_ring_material.albedo_color = Color(1.0, 0.9, 0.2, 0.95)
		elif _mode == Mode.PAINT:
			_update_cursor_ring_mesh(_paint_brush_size)
			_ring_material.albedo_color = _get_surface_color(_paint_surface)
		elif _mode == Mode.GREEBLES:
			_update_cursor_ring_mesh(_greeble_radius)
			if _greeble_tool == GreebleType.TREE:
				_ring_material.albedo_color = Color(0.2, 0.85, 0.3, 0.95)
			elif _greeble_tool == GreebleType.BOULDER or _greeble_tool == GreebleType.SPIRE:
				_ring_material.albedo_color = Color(0.8, 0.75, 0.7, 0.95)
			elif _greeble_tool == GreebleType.SHRUB:
				_ring_material.albedo_color = Color(0.5, 0.8, 0.2, 0.95)
			elif _greeble_tool == GreebleType.ERASER:
				_ring_material.albedo_color = Color(1.0, 0.2, 0.2, 0.95)
		elif _mode == Mode.ROADS_BRIDGES:
			_update_cursor_ring_mesh(_road_width if _road_click_step > 0 else _bridge_width)
			_ring_material.albedo_color = Color(1.0, 0.85, 0.25, 0.95)
			if _bridge_click_step == 2:
				_update_preview_line(_bridge_point_a, hit, _bridge_width)
			elif _road_click_step == 2:
				_update_preview_line(_road_point_a, hit, _road_width)
		elif _is_click_placing:
			_update_cursor_ring_mesh(22.0)
			if _click_place_type == "friendly_spawn":
				_ring_material.albedo_color = Color(0.2, 0.8, 1.0, 0.95)
			elif _click_place_type == "enemy_spawn":
				_ring_material.albedo_color = Color(1.0, 0.3, 0.25, 0.95)
			else:
				_ring_material.albedo_color = Color(1.0, 0.85, 0.2, 0.95)
	else:
		_has_valid_hit = false
		if _cursor_ring != null:
			_cursor_ring.visible = false


func _handle_click(screen_pos: Vector2, ctrl: bool, shift: bool) -> void:
	if not _has_valid_hit:
		_update_cursor_position(screen_pos)
	if not _has_valid_hit:
		return

	if _is_click_placing:
		_push_undo()
		if _click_place_type == "friendly_spawn":
			_set_spawn_hq_pos("player", _last_hit_point)
			_set_status("Friendly Spawn placed at (%.1f, %.1f)" % [_last_hit_point.x, _last_hit_point.z], Tokens.SIGNAL_GO)
		elif _click_place_type == "enemy_spawn":
			_set_spawn_hq_pos("enemy", _last_hit_point)
			_set_status("Enemy Spawn placed at (%.1f, %.1f)" % [_last_hit_point.x, _last_hit_point.z], Tokens.SIGNAL_GO)
		elif _click_place_type.begins_with("resource_"):
			var rtype := _click_place_type.trim_prefix("resource_")
			_add_resource_at(rtype, _last_hit_point)
			_set_status("Resource (%s) placed at (%.1f, %.1f)" % [rtype, _last_hit_point.x, _last_hit_point.z], Tokens.SIGNAL_GO)
		_is_click_placing = false
		if _cursor_ring != null: _cursor_ring.visible = false
		return

	if _mode == Mode.ROADS_BRIDGES:
		_handle_roads_bridges_click(_last_hit_point)
	elif _mode == Mode.GREEBLES:
		_push_undo()
		if _greeble_single_click:
			_place_single_greeble(_last_hit_point)
		else:
			_apply_greeble_stroke(_last_hit_point, 0.1)
	elif _mode == Mode.SCULPT:
		_push_undo()
		_last_flat_stamp_pos = _last_hit_point
		if _sculpt_tool == SculptTool.FLATTEN and not _flatten_anchor_set:
			_flatten_target_h = _last_hit_point.y
			_flatten_anchor_set = true
			_apply_sculpt_stroke(_last_hit_point, 0.05, ctrl, shift)
		else:
			_apply_sculpt_stroke(_last_hit_point, 0.05, ctrl, shift)
	elif _mode == Mode.PAINT:
		_push_undo()
		_apply_paint_stroke(_last_hit_point, 0.1)
	elif _mode == Mode.FEATURES:
		_push_undo()
		_move_selected_to(_last_hit_point)
	elif _mode == Mode.SPAWNS:
		var p_hq := _get_spawn_hq("player")
		var e_hq := _get_spawn_hq("enemy")
		var d_p := Vector2(_last_hit_point.x - p_hq.x, _last_hit_point.z - p_hq.z).length()
		var d_e := Vector2(_last_hit_point.x - e_hq.x, _last_hit_point.z - e_hq.z).length()
		if d_p <= 28.0:
			_push_undo()
			_dragging_spawn_id = "player"
			_set_status("Dragging Friendly Spawn (Player HQ)...", Tokens.SIGNAL_GO)
		elif d_e <= 28.0:
			_push_undo()
			_dragging_spawn_id = "enemy"
			_set_status("Dragging Enemy Spawn (Enemy HQ)...", Tokens.SIGNAL_GO)
		else:
			_dragging_spawn_id = ""


func _handle_drag(screen_pos: Vector2, ctrl: bool, shift: bool) -> void:
	_update_cursor_position(screen_pos)
	if not _has_valid_hit:
		return
	if _mode == Mode.FEATURES:
		_move_selected_to(_last_hit_point)
	elif _mode == Mode.SPAWNS and _dragging_spawn_id != "":
		_set_spawn_hq_pos(_dragging_spawn_id, _last_hit_point)


# ==============================================================================
# 2-POINT CLICK ROADS & BRIDGES SYSTEM
# ==============================================================================

func _handle_roads_bridges_click(hit: Vector3) -> void:
	if _bridge_click_step == 1:
		# Step 1 -> Step 2: First click sets Point A on bank 1
		_bridge_point_a = hit
		_bridge_click_step = 2
		_set_status("Bridge Point A set at (%.1f, %.1f). Now CLICK Point B on opposite bank." % [hit.x, hit.z], Tokens.SIGNAL_GO)

	elif _bridge_click_step == 2:
		# Step 2 -> Complete Bridge between Point A and Point B
		var pA := _bridge_point_a
		var pB := hit
		var span_vec := pB - pA
		var length := span_vec.length()
		if length < 6.0:
			_set_status("Bridge span too short (minimum 6m).", Tokens.SIGNAL_ALERT)
			return
			
		_push_undo()
		var center := (pA + pB) * 0.5
		var angle_deg := rad_to_deg(atan2(span_vec.x, span_vec.z))
		var deck_elevation := maxf(pA.y, pB.y) + _bridge_deck_height * 0.5
		center.y = deck_elevation

		var new_b := {
			"center": [snappedf(center.x, 0.5), snappedf(center.y, 0.5), snappedf(center.z, 0.5)],
			"half_extents": [snappedf(_bridge_width * 0.5, 0.5), snappedf(length * 0.5, 0.5)],
			"deck_height": _bridge_deck_height,
			"rotation_deg": snappedf(angle_deg, 0.5)
		}
		var b_list: Array = _map.get("bridges", [])
		b_list.append(new_b)
		_map["bridges"] = b_list
		
		_bridge_click_step = 0
		if _preview_line != null:
			_preview_line.visible = false
		_refresh_bridges_in_scene()
		_refresh_bridges_ui()
		_dirty = true
		_set_status("Built Bridge (Span: %.1fm, Angle: %.1f°) successfully!" % [length, angle_deg], Tokens.SIGNAL_GO)

	elif _road_click_step == 1:
		# Step 1 -> Step 2: First click sets Road Start Point A
		_road_point_a = hit
		_road_click_step = 2
		_set_status("Road Start set at (%.1f, %.1f). Now CLICK Point B to build road segment." % [hit.x, hit.z], Tokens.SIGNAL_GO)

	elif _road_click_step == 2:
		# Step 2 -> Build Road segment between Point A and Point B
		var pA := _road_point_a
		var pB := hit
		var dist := (pB - pA).length()
		if dist < 4.0:
			_set_status("Road segment too short (minimum 4m).", Tokens.SIGNAL_ALERT)
			return

		_push_undo()
		_build_road_segment(pA, pB, _road_width, _road_surface)
		_road_point_a = pB # Remain in step 2 to allow continuous chaining!
		_set_status("Road segment built (Length: %.1fm). Click next point to chain, or Esc to finish." % dist, Tokens.SIGNAL_GO)

	else:
		# Check if clicking on an existing bridge to select
		for i in range(_map.get("bridges", []).size()):
			var b: Dictionary = _map["bridges"][i]
			var bc := TerrainBuilderScript._vec3_of(b.get("center", [0, 0, 0]))
			var bhe: Vector2 = _xz(b.get("half_extents", [10, 10]))
			if Vector2(hit.x - bc.x, hit.z - bc.z).length() <= maxf(bhe.x, bhe.y):
				_selected_bridge = i
				_refresh_bridges_ui()
				_set_status("Selected Bridge #%d" % (i + 1), Tokens.TEXT_SECONDARY)
				return


func _start_2point_bridge() -> void:
	_mode = Mode.ROADS_BRIDGES
	if _tab_container != null:
		_tab_container.current_tab = Mode.ROADS_BRIDGES
	_bridge_click_step = 1 # Awaiting 1st click on terrain
	_road_click_step = 0
	if _preview_line != null: _preview_line.visible = false
	_set_status("Bridge Mode: CLICK on the terrain (Point A) to start bridge.", Tokens.SIGNAL_GO)


func _start_2point_road() -> void:
	_mode = Mode.ROADS_BRIDGES
	if _tab_container != null:
		_tab_container.current_tab = Mode.ROADS_BRIDGES
	_road_click_step = 1 # Awaiting 1st click on terrain
	_bridge_click_step = 0
	if _preview_line != null: _preview_line.visible = false
	_set_status("Road Mode: CLICK on the terrain (Point A) to start road.", Tokens.SIGNAL_GO)


func _build_road_segment(pA: Vector3, pB: Vector3, width: float, surface_type: String) -> void:
	var total_len := (pB - pA).length()
	var steps := maxi(2, int(total_len / 2.0))
	var half: float = float(_map.get("map_half_extents", 960.0))
	var w := _splat_img.get_width()
	var h := _splat_img.get_height()

	var sg := _get_or_create_sculpt_grid()
	var sdim: int = int(sg["dim"])
	var sdata: Array = sg["data"]
	var g_step := (half * 2.0) / float(sdim - 1)

	# Target Splat Channel: B=Dirt Road (default), G=Gravel/Pavement, A=Sand Road
	var target_col := Color(0.0, 0.0, 1.0, 0.0) # Dirt path
	if surface_type == "gravel" or surface_type == "pavement":
		target_col = Color(0.0, 1.0, 0.0, 0.0)
	elif surface_type == "sand":
		target_col = Color(0.0, 0.0, 0.0, 1.0)

	for step_idx in range(steps + 1):
		var t := float(step_idx) / float(steps)
		var p_center := pA.lerp(pB, t)
		var target_y := lerpf(pA.y, pB.y, t)

		# 1. Level / Grade Terrain Roadbed
		var rad := width * 0.75
		var i_min_x := clampi(int(floor((p_center.x - rad + half) / g_step)), 0, sdim - 1)
		var i_max_x := clampi(int(ceil((p_center.x + rad + half) / g_step)), 0, sdim - 1)
		var i_min_z := clampi(int(floor((p_center.z - rad + half) / g_step)), 0, sdim - 1)
		var i_max_z := clampi(int(ceil((p_center.z + rad + half) / g_step)), 0, sdim - 1)

		for iz in range(i_min_z, i_max_z + 1):
			var cz := -half + float(iz) * g_step
			for ix in range(i_min_x, i_max_x + 1):
				var cx := -half + float(ix) * g_step
				var d := Vector2(cx - p_center.x, cz - p_center.z).length()
				if d <= rad:
					var fall := cos((d / rad) * PI * 0.5)
					fall = fall * fall
					var curr_h := TerrainBuilderScript.height_at(_map, cx, cz)
					var dh := (target_y - curr_h) * 0.85 * fall
					sdata[iz * sdim + ix] = float(sdata[iz * sdim + ix]) + dh

		# 2. Paint Road Splat Texture
		var u := (p_center.x / (half * 2.0) + 0.5) * float(w)
		var v := (p_center.z / (half * 2.0) + 0.5) * float(h)
		var r_pix := (width / (half * 2.0)) * float(w)
		var px_min := clampi(int(floor(u - r_pix)), 0, w - 1)
		var px_max := clampi(int(ceil(u + r_pix)), 0, w - 1)
		var py_min := clampi(int(floor(v - r_pix)), 0, h - 1)
		var py_max := clampi(int(ceil(v + r_pix)), 0, h - 1)

		for py in range(py_min, py_max + 1):
			for px in range(px_min, px_max + 1):
				var dist := Vector2(float(px) - u, float(py) - v).length() / maxf(1.0, r_pix)
				if dist <= 1.0:
					var f := cos(dist * PI * 0.5)
					f = f * f * 0.95
					var cur: Color = _splat_img.get_pixel(px, py)
					var mixed: Color = cur.lerp(target_col, f)
					var sum: float = mixed.r + mixed.g + mixed.b + mixed.a
					if sum > 0.001:
						mixed = Color(mixed.r / sum, mixed.g / sum, mixed.b / sum, mixed.a / sum)
					_splat_img.set_pixel(px, py, mixed)

	# Record road segment in map JSON
	var roads_list: Array = _map.get("roads", [])
	roads_list.append({
		"start": [snappedf(pA.x, 0.5), snappedf(pA.y, 0.5), snappedf(pA.z, 0.5)],
		"end": [snappedf(pB.x, 0.5), snappedf(pB.y, 0.5), snappedf(pB.z, 0.5)],
		"width": width,
		"surface": surface_type
	})
	_map["roads"] = roads_list

	if _splat_tex != null:
		_splat_tex.update(_splat_img)
	_update_local_mesh_region((pA + pB) * 0.5, total_len * 0.6 + width * 2.0)
	_dirty = true


func _refresh_bridges_in_scene() -> void:
	if _bridges_node == null or _map.is_empty():
		return
	for c in _bridges_node.get_children():
		c.queue_free()

	var b_list: Array = _map.get("bridges", [])
	for i in range(b_list.size()):
		var b: Dictionary = b_list[i]
		TerrainBuilderScript._spawn_bridge(b, _bridges_node)


# ==============================================================================
# DIRECT TREE & ROCK GREEBLE PAINTING SYSTEM
# ==============================================================================

func _init_props_list() -> void:
	_props_list = _map.get("props", []).duplicate(true)
	_refresh_props_multimesh()



func _update_rock_shader_params() -> void:
	if _ground == null or _ground.material_override == null:
		return
	var sm = _ground.material_override as ShaderMaterial
	if sm == null:
		return
	var terr: Dictionary = _map.get("terrain", {}) if typeof(_map.get("terrain", {})) == TYPE_DICTIONARY else {}
	sm.set_shader_parameter("rock_pattern", int(terr.get("rock_pattern", 0)))
	sm.set_shader_parameter("rock_strata_strength", float(terr.get("rock_strata_strength", 1.1)))
	sm.set_shader_parameter("rock_bump_strength", float(terr.get("rock_bump_strength", 1.6)))
	sm.set_shader_parameter("rock_strata_scale", float(terr.get("rock_strata_scale", 0.16)))
	sm.set_shader_parameter("rock_joint_scale", float(terr.get("rock_joint_scale", 0.08)))


func _scale_all_props(factor: float) -> void:
	if _props_list.is_empty():
		return
	_push_undo()
	for p in _props_list:
		var s: float = float(p.get("scale", 1.0)) * factor
		p["scale"] = snappedf(clampf(s, 0.2, 50.0), 0.05)
	_map["props"] = _props_list
	_refresh_props_multimesh()
	_dirty = true
	_set_status("Scaled %d props by %.2fx (Undo with Ctrl+Z)." % [_props_list.size(), factor], Tokens.SIGNAL_GO)

func _scale_rock_props(factor: float) -> void:
	if _props_list.is_empty():
		return
	_push_undo()
	var count := 0
	for p in _props_list:
		var ptype: String = str(p.get("type", ""))
		if ptype.begins_with("boulder") or ptype.begins_with("rock") or ptype.begins_with("spire"):
			var s: float = float(p.get("scale", 1.0)) * factor
			p["scale"] = snappedf(clampf(s, 0.2, 50.0), 0.05)
			count += 1
	if count > 0:
		_map["props"] = _props_list
		_refresh_props_multimesh()
		_dirty = true
		_set_status("Scaled %d boulders & rocks by %.2fx (Undo with Ctrl+Z)." % [count, factor], Tokens.SIGNAL_GO)
	else:
		_set_status("No boulders or rocks found on map.", Tokens.TEXT_SECONDARY)

func _place_single_greeble(hit: Vector3) -> void:
	var ptype := "tree"
	var var_id := randi() % AMBIENT_TREE_POOL_SIZE
	if _greeble_tool == GreebleType.BOULDER:
		ptype = "boulder"
		var_id = randi() % BOULDER_POOL_SIZE
	elif _greeble_tool == GreebleType.SPIRE:
		ptype = "spire"
		var_id = randi() % ROCK_SPIRE_POOL_SIZE
	elif _greeble_tool == GreebleType.SHRUB:
		ptype = "shrub"
		var_id = randi() % SHRUB_POOL_SIZE

	var scale_val := randf_range(_greeble_scale_min, _greeble_scale_max)
	var yaw_val := randf_range(0.0, TAU)

	_props_list.append({
		"type": ptype,
		"variant": var_id,
		"pos": [snappedf(hit.x, 0.2), snappedf(hit.y, 0.2), snappedf(hit.z, 0.2)],
		"scale": snappedf(scale_val, 0.05),
		"yaw": snappedf(yaw_val, 0.05)
	})
	_map["props"] = _props_list
	_refresh_props_multimesh()
	_dirty = true
	_set_status("Placed %s (Total props: %d)" % [ptype.capitalize(), _props_list.size()], Tokens.SIGNAL_GO)


func _apply_greeble_stroke(hit: Vector3, dt: float) -> void:
	if _greeble_tool == GreebleType.ERASER:
		# Remove props within radius
		var rad := _greeble_radius
		var new_props: Array = []
		var removed_count := 0
		for prop in _props_list:
			var p_arr = prop.get("pos", [0, 0, 0])
			var d := Vector2(float(p_arr[0]) - hit.x, float(p_arr[2]) - hit.z).length()
			if d > rad:
				new_props.append(prop)
			else:
				removed_count += 1
		if removed_count > 0:
			_props_list = new_props
			_map["props"] = _props_list
			_refresh_props_multimesh()
			_dirty = true
			_set_status("Erased %d props (Remaining: %d)" % [removed_count, _props_list.size()], Tokens.SIGNAL_ALERT)
		return

	# Scatter new props within radius
	var spawn_rate := maxi(1, int(round(_greeble_density * dt * 90.0)))
	var rad := _greeble_radius
	var added := 0
	for i in range(spawn_rate):
		var ang := randf_range(0.0, TAU)
		var r := sqrt(randf()) * rad
		var px := hit.x + cos(ang) * r
		var pz := hit.z + sin(ang) * r
		var py := TerrainBuilderScript.height_at(_map, px, pz)

		# Avoid dropping underwater unless intentional
		if py < -0.5:
			continue

		var ptype := "tree"
		var var_id := randi() % AMBIENT_TREE_POOL_SIZE
		if _greeble_tool == GreebleType.BOULDER:
			ptype = "boulder"
			var_id = randi() % BOULDER_POOL_SIZE
		elif _greeble_tool == GreebleType.SPIRE:
			ptype = "spire"
			var_id = randi() % ROCK_SPIRE_POOL_SIZE
		elif _greeble_tool == GreebleType.SHRUB:
			ptype = "shrub"
			var_id = randi() % SHRUB_POOL_SIZE

		var scale_val := randf_range(_greeble_scale_min, _greeble_scale_max)
		var yaw_val := randf_range(0.0, TAU)

		_props_list.append({
			"type": ptype,
			"variant": var_id,
			"pos": [snappedf(px, 0.2), snappedf(py, 0.2), snappedf(pz, 0.2)],
			"scale": snappedf(scale_val, 0.05),
			"yaw": snappedf(yaw_val, 0.05)
		})
		added += 1

	if added > 0:
		_map["props"] = _props_list
		_refresh_props_multimesh()
		_dirty = true


func _refresh_props_multimesh() -> void:
	if _props_node == null:
		return
	for c in _props_node.get_children():
		c.queue_free()

	if _props_list.is_empty():
		return

	# Group by model type & variant
	var tree_xforms: Dictionary = {}
	var boulder_xforms: Dictionary = {}
	var spire_xforms: Dictionary = {}
	var shrub_xforms: Dictionary = {}

	for prop in _props_list:
		var ptype: String = str(prop.get("type", "tree"))
		var pos_arr = prop.get("pos", [0, 0, 0])
		var pos := Vector3(float(pos_arr[0]), float(pos_arr[1]), float(pos_arr[2]))
		var s: float = float(prop.get("scale", 1.0))
		var yaw: float = float(prop.get("yaw", 0.0))
		var var_id: int = int(prop.get("variant", 0))

		var basis := Basis(Vector3.UP, yaw).scaled(Vector3.ONE * s)
		var xf := Transform3D(basis, pos)

		if ptype == "tree" or ptype.begins_with("ambient_tree"):
			var v := var_id % AMBIENT_TREE_POOL_SIZE
			if not tree_xforms.has(v): tree_xforms[v] = []
			tree_xforms[v].append(xf)
		elif ptype == "boulder" or ptype.begins_with("rock"):
			var v := var_id % BOULDER_POOL_SIZE
			if not boulder_xforms.has(v): boulder_xforms[v] = []
			boulder_xforms[v].append(xf)
		elif ptype == "spire" or ptype.begins_with("rock_spire"):
			var v := var_id % ROCK_SPIRE_POOL_SIZE
			if not spire_xforms.has(v): spire_xforms[v] = []
			spire_xforms[v].append(xf)
		elif ptype == "shrub" or ptype.begins_with("bush"):
			var v := var_id % SHRUB_POOL_SIZE
			if not shrub_xforms.has(v): shrub_xforms[v] = []
			shrub_xforms[v].append(xf)

	# Batch into MultiMeshes
	_spawn_editor_multimeshes(AMBIENT_TREE_MODEL_DIR, tree_xforms, Color(0.24, 0.40, 0.20))
	_spawn_editor_multimeshes(BOULDER_MODEL_DIR, boulder_xforms, Color(0.48, 0.44, 0.40))
	_spawn_editor_multimeshes(ROCK_SPIRE_MODEL_DIR, spire_xforms, Color(0.42, 0.38, 0.35))
	_spawn_editor_multimeshes(SHRUB_MODEL_DIR, shrub_xforms, Color(0.28, 0.45, 0.22))


func _spawn_editor_multimeshes(template_path: String, xforms_by_variant: Dictionary, fallback_color: Color) -> void:
	for v in xforms_by_variant.keys():
		var xf_list: Array = xforms_by_variant[v]
		if xf_list.is_empty():
			continue
		var glb_path := template_path % v if ("%d" in template_path or "%s" in template_path) else template_path
		var parts := TerrainVisualScatter._load_gltf_parts(glb_path)
		if parts.is_empty():
			# Fallback primitive mesh
			var mmi := MultiMeshInstance3D.new()
			var mm := MultiMesh.new()
			mm.transform_format = MultiMesh.TRANSFORM_3D
			mm.instance_count = xf_list.size()
			var cyl := CylinderMesh.new()
			cyl.top_radius = 0.0
			cyl.bottom_radius = 2.5
			cyl.height = 7.0
			mm.mesh = cyl
			for i in range(xf_list.size()):
				mm.set_instance_transform(i, xf_list[i])
			mmi.multimesh = mm
			var mat := StandardMaterial3D.new()
			mat.albedo_color = fallback_color
			mmi.material_override = mat
			mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
			_props_node.add_child(mmi)
			continue

		for p in parts:
			var mesh: Mesh = p["mesh"]
			var local_xf: Transform3D = p["xform"]
			var mmi := MultiMeshInstance3D.new()
			var mm := MultiMesh.new()
			mm.transform_format = MultiMesh.TRANSFORM_3D
			mm.instance_count = xf_list.size()
			mm.mesh = mesh
			for i in range(xf_list.size()):
				mm.set_instance_transform(i, (xf_list[i] as Transform3D) * local_xf)
			mmi.multimesh = mm
			if p.has("material") and p["material"] != null:
				mmi.material_override = p["material"]
			mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
			_props_node.add_child(mmi)


# ==============================================================================
# FAST RAYMARCH & NORMAL HELPERS
# ==============================================================================

func _sample_height_fast(x: float, z: float) -> float:
	var half: float = float(_map.get("map_half_extents", 960.0))
	var divs: int = PREVIEW_DIVS
	var stride: int = divs + 1
	if _grid_heights.size() == stride * stride and absf(x) <= half and absf(z) <= half:
		var step_size: float = (half * 2.0) / float(divs)
		var gx: float = (x + half) / step_size
		var gz: float = (z + half) / step_size
		var ix: int = clampi(int(floor(gx)), 0, divs - 1)
		var iz: int = clampi(int(floor(gz)), 0, divs - 1)
		var fx: float = gx - float(ix)
		var fz: float = gz - float(iz)
		var h00: float = _grid_heights[ix * stride + iz]
		var h10: float = _grid_heights[(ix + 1) * stride + iz]
		var h01: float = _grid_heights[ix * stride + (iz + 1)]
		var h11: float = _grid_heights[(ix + 1) * stride + (iz + 1)]
		var h0: float = h00 + (h10 - h00) * fx
		var h1: float = h01 + (h11 - h01) * fx
		return h0 + (h1 - h0) * fz
	return TerrainBuilderScript.height_at(_map, x, z)


func _get_terrain_normal(x: float, z: float) -> Vector3:
	var delta := 1.5
	var hl := _sample_height_fast(x - delta, z)
	var hr := _sample_height_fast(x + delta, z)
	var hd := _sample_height_fast(x, z - delta)
	var hu := _sample_height_fast(x, z + delta)
	var dh_dx := (hr - hl) / (2.0 * delta)
	var dh_dz := (hu - hd) / (2.0 * delta)
	return Vector3(-dh_dx, 1.0, -dh_dz).normalized()


func _fast_raymarch(from: Vector3, dir: Vector3):
	var half: float = float(_map.get("map_half_extents", 960.0))
	if dir.length_squared() < 0.0001:
		return null

	# 1. Fast Bounding Box Clipping: Map bounds [-half, half] XZ, [-150, 200] Y
	var box_min := Vector3(-half * 1.05, -150.0, -half * 1.05)
	var box_max := Vector3(half * 1.05, 200.0, half * 1.05)
	var inv_dir := Vector3(
		1.0 / dir.x if absf(dir.x) > 1e-6 else 1e6,
		1.0 / dir.y if absf(dir.y) > 1e-6 else 1e6,
		1.0 / dir.z if absf(dir.z) > 1e-6 else 1e6
	)
	var t1 := (box_min.x - from.x) * inv_dir.x
	var t2 := (box_max.x - from.x) * inv_dir.x
	var t3 := (box_min.y - from.y) * inv_dir.y
	var t4 := (box_max.y - from.y) * inv_dir.y
	var t5 := (box_min.z - from.z) * inv_dir.z
	var t6 := (box_max.z - from.z) * inv_dir.z
	var t_min := maxf(maxf(minf(t1, t2), minf(t3, t4)), minf(t5, t6))
	var t_max := minf(minf(maxf(t1, t2), maxf(t3, t4)), maxf(t5, t6))
	if t_max < 0.0 or t_min > t_max:
		return null

	var t_start := maxf(0.0, t_min)
	var t_end := t_max

	var divs: int = PREVIEW_DIVS
	var step_size: float = (half * 2.0) / float(divs)
	var stride: int = divs + 1
	var has_grid: bool = _grid_heights.size() == stride * stride

	var t := t_start
	var prev_t := t
	var p := from + dir * t
	var h_init: float = 0.0
	if has_grid and absf(p.x) <= half and absf(p.z) <= half:
		var gx := (p.x + half) / step_size
		var gz := (p.z + half) / step_size
		var ix := clampi(int(floor(gx)), 0, divs - 1)
		var iz := clampi(int(floor(gz)), 0, divs - 1)
		var fx := gx - float(ix)
		var fz := gz - float(iz)
		var h0 := _grid_heights[ix * stride + iz] + (_grid_heights[(ix + 1) * stride + iz] - _grid_heights[ix * stride + iz]) * fx
		var h1 := _grid_heights[ix * stride + (iz + 1)] + (_grid_heights[(ix + 1) * stride + (iz + 1)] - _grid_heights[ix * stride + (iz + 1)]) * fx
		h_init = h0 + (h1 - h0) * fz
	else:
		h_init = TerrainBuilderScript.height_at(_map, p.x, p.z)

	var prev_diff := p.y - h_init
	var iters: int = 0
	while t <= t_end and iters < 80:
		iters += 1
		var abs_d := absf(prev_diff)
		var step := clampf(abs_d * 0.65, 1.2, 80.0)
		t += step
		p = from + dir * t

		var h: float = 0.0
		if has_grid and absf(p.x) <= half and absf(p.z) <= half:
			var gx := (p.x + half) / step_size
			var gz := (p.z + half) / step_size
			var ix := clampi(int(floor(gx)), 0, divs - 1)
			var iz := clampi(int(floor(gz)), 0, divs - 1)
			var fx := gx - float(ix)
			var fz := gz - float(iz)
			var h0 := _grid_heights[ix * stride + iz] + (_grid_heights[(ix + 1) * stride + iz] - _grid_heights[ix * stride + iz]) * fx
			var h1 := _grid_heights[ix * stride + (iz + 1)] + (_grid_heights[(ix + 1) * stride + (iz + 1)] - _grid_heights[ix * stride + (iz + 1)]) * fx
			h = h0 + (h1 - h0) * fz
		else:
			h = TerrainBuilderScript.height_at(_map, p.x, p.z)

		var diff := p.y - h
		if (diff <= 0.0 and prev_diff >= 0.0) or (diff >= 0.0 and prev_diff <= 0.0 and iters > 1):
			var t_low := prev_t
			var t_high := t
			for _i in range(5):
				var t_mid := (t_low + t_high) * 0.5
				var p_mid := from + dir * t_mid
				var h_mid := TerrainBuilderScript.height_at(_map, p_mid.x, p_mid.z)
				if p_mid.y < h_mid:
					t_high = t_mid
				else:
					t_low = t_mid
			var t_final := (t_low + t_high) * 0.5
			var p_final := from + dir * t_final
			var h_final := TerrainBuilderScript.height_at(_map, p_final.x, p_final.z)
			return Vector3(p_final.x, h_final, p_final.z)

		prev_diff = diff
		prev_t = t

	return null


# ==============================================================================
# ULTRA-FAST SCULPTING ENGINE
# ==============================================================================

func _get_or_create_sculpt_grid() -> Dictionary:
	var terr: Dictionary = _map.get("terrain", {})
	if not terr.has("sculpt_grid"):
		var dim := SCULPT_GRID_DIM
		var half: float = float(_map.get("map_half_extents", 960.0))
		var data := []
		data.resize(dim * dim)
		data.fill(0.0)
		terr["sculpt_grid"] = {
			"dim": dim,
			"half_extents": half,
			"data": data
		}
		_map["terrain"] = terr
	return terr["sculpt_grid"]


func _calc_falloff(t: float, mode_str: String) -> float:
	t = clampf(t, 0.0, 1.0)
	match mode_str:
		"linear":
			return 1.0 - t
		"flat":
			return 1.0
		"gaussian":
			return exp(-3.5 * t * t)
		_: # "smooth"
			return t * t * (2.0 * t - 3.0) + 1.0



func _scale_all_heights(factor: float) -> void:
	if _map.is_empty():
		return
	_push_undo()
	
	# 1. Scale sculpt grid
	var sg = _map.get("terrain", {}).get("sculpt_grid", null)
	if sg != null and sg.has("data"):
		var data: Array = sg["data"]
		for i in range(data.size()):
			data[i] = float(data[i]) * factor
	
	# 2. Scale features
	var feats := _features()
	for f in feats:
		if f.has("height"):
			f["height"] = float(f["height"]) * factor
		if f.has("top_height"):
			f["top_height"] = float(f["top_height"]) * factor
		if f.has("depth"):
			f["depth"] = float(f["depth"]) * factor

	_mark_dirty()
	_refresh_feature_props()
	_set_status("Scaled all terrain heights by %.2fx (Undo with Ctrl+Z)." % factor, Tokens.SIGNAL_GO)


func _toggle_commander_view() -> void:
	if _cam_dist < 80.0:
		_reset_camera_view()
	else:
		var target_pivot := _last_hit_point if _has_valid_hit else Vector3.ZERO
		_cam_pivot.position = target_pivot
		_cam_dist = 38.0
		_cam_pitch = -0.61
		_is_topdown = false
		_update_camera()
		_set_status("Commander Tactical View (skirmish scale). Press F or Reset (Home) to return.", Tokens.SIGNAL_GO)


func _apply_sculpt_stroke(hit: Vector3, dt: float, ctrl: bool = false, shift: bool = false) -> void:
	var sg := _get_or_create_sculpt_grid()
	var dim: int = int(sg["dim"])
	var half: float = float(sg["half_extents"])
	var data: Array = sg["data"]
	
	var active_tool := _sculpt_tool
	if shift:
		active_tool = SculptTool.SMOOTH
	elif ctrl:
		active_tool = SculptTool.LOWER if _sculpt_tool == SculptTool.RAISE else SculptTool.RAISE

	var rad := _brush_radius
	var flat_falloff := _brush_falloff == "flat"
	var str_val := _brush_strength if flat_falloff else (_brush_strength * dt * 4.0)
	
	var min_x := hit.x - rad
	var max_x := hit.x + rad
	var min_z := hit.z - rad
	var max_z := hit.z + rad
	
	var grid_step := (half * 2.0) / float(dim - 1)
	var i_min_x := clampi(int(floor((min_x + half) / grid_step)), 0, dim - 1)
	var i_max_x := clampi(int(ceil((max_x + half) / grid_step)), 0, dim - 1)
	var i_min_z := clampi(int(floor((min_z + half) / grid_step)), 0, dim - 1)
	var i_max_z := clampi(int(ceil((max_z + half) / grid_step)), 0, dim - 1)
	
	if active_tool == SculptTool.SMOOTH:
		var avg_acc := 0.0
		var avg_count := 0
		for iz in range(i_min_z, i_max_z + 1):
			var cz := -half + float(iz) * grid_step
			for ix in range(i_min_x, i_max_x + 1):
				var cx := -half + float(ix) * grid_step
				var d := Vector2(cx - hit.x, cz - hit.z).length()
				if d <= rad:
					avg_acc += TerrainBuilderScript.height_at(_map, cx, cz)
					avg_count += 1
		if avg_count > 0:
			var target_avg := avg_acc / float(avg_count)
			for iz in range(i_min_z, i_max_z + 1):
				var cz := -half + float(iz) * grid_step
				for ix in range(i_min_x, i_max_x + 1):
					var cx := -half + float(ix) * grid_step
					var d := Vector2(cx - hit.x, cz - hit.z).length()
					if d <= rad:
						var f := _calc_falloff(d / rad, _brush_falloff)
						var curr_h := TerrainBuilderScript.height_at(_map, cx, cz)
						var rate := 1.0 if flat_falloff else minf(1.0, str_val * 0.4)
						var delta_h := (target_avg - curr_h) * rate * f
						data[iz * dim + ix] = float(data[iz * dim + ix]) + delta_h
	elif active_tool == SculptTool.FLATTEN:
		for iz in range(i_min_z, i_max_z + 1):
			var cz := -half + float(iz) * grid_step
			for ix in range(i_min_x, i_max_x + 1):
				var cx := -half + float(ix) * grid_step
				var d := Vector2(cx - hit.x, cz - hit.z).length()
				if d <= rad:
					var f := _calc_falloff(d / rad, _brush_falloff)
					var curr_h := TerrainBuilderScript.height_at(_map, cx, cz)
					var rate := 1.0 if flat_falloff else minf(1.0, str_val * 0.4)
					var delta_h := (_flatten_target_h - curr_h) * rate * f
					data[iz * dim + ix] = float(data[iz * dim + ix]) + delta_h
	else:
		var sign_mult := 1.0 if active_tool == SculptTool.RAISE else -1.0
		for iz in range(i_min_z, i_max_z + 1):
			var cz := -half + float(iz) * grid_step
			for ix in range(i_min_x, i_max_x + 1):
				var cx := -half + float(ix) * grid_step
				var d := Vector2(cx - hit.x, cz - hit.z).length()
				if d <= rad:
					var f := _calc_falloff(d / rad, _brush_falloff)
					data[iz * dim + ix] = float(data[iz * dim + ix]) + sign_mult * str_val * f

	_update_local_mesh_region(hit, rad + 24.0)
	_dirty = true


func _update_local_mesh_region(hit: Vector3, radius: float) -> void:
	if not _mesh_allocated or _ground == null or _map.is_empty():
		_rebuild_preview()
		return
		
	var n := PREVIEW_DIVS
	var half: float = float(_map.get("map_half_extents", 960.0))
	var step := (half * 2.0) / float(n)
	var inv_2step := 1.0 / (2.0 * step)
	
	var i_min := clampi(int(floor((hit.x - radius + half) / step)), 0, n)
	var i_max := clampi(int(ceil((hit.x + radius + half) / step)), 0, n)
	var j_min := clampi(int(floor((hit.z - radius + half) / step)), 0, n)
	var j_max := clampi(int(ceil((hit.z + radius + half) / step)), 0, n)

	# 1. Update Heights in local box
	for i in range(i_min, i_max + 1):
		var x := -half + step * float(i)
		for j in range(j_min, j_max + 1):
			var z := -half + step * float(j)
			var idx := i * (n + 1) + j
			var h := TerrainBuilderScript.height_at(_map, x, z)
			_grid_heights[idx] = h
			_grid_verts[idx] = Vector3(x, h, z)

	# 2. Update Fast Analytical Normals in local box
	var ni_min := maxi(0, i_min - 1)
	var ni_max := mini(n, i_max + 1)
	var nj_min := maxi(0, j_min - 1)
	var nj_max := mini(n, j_max + 1)
	for i in range(ni_min, ni_max + 1):
		var i_prev := maxi(0, i - 1)
		var i_next := mini(n, i + 1)
		for j in range(nj_min, nj_max + 1):
			var idx := i * (n + 1) + j
			var j_prev := maxi(0, j - 1)
			var j_next := mini(n, j + 1)
			var dh_dx := (_grid_heights[i_next * (n + 1) + j] - _grid_heights[i_prev * (n + 1) + j]) * inv_2step
			var dh_dz := (_grid_heights[i * (n + 1) + j_next] - _grid_heights[i * (n + 1) + j_prev]) * inv_2step
			_grid_norms[idx] = Vector3(-dh_dx, 1.0, -dh_dz).normalized()

	# 3. Commit Arrays to Mesh
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = _grid_verts
	arrays[Mesh.ARRAY_NORMAL] = _grid_norms
	arrays[Mesh.ARRAY_TEX_UV] = _grid_uvs
	arrays[Mesh.ARRAY_INDEX] = _grid_indices

	var am := ArrayMesh.new()
	am.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	_ground.mesh = am


# ==============================================================================
# REAL IN-ENGINE SPLAT TEXTURE PAINTING
# ==============================================================================

func _init_splat_texture() -> void:
	var mid := map_id
	var splat_path := "res://data/maps/%s_splat.png" % mid
	if mid != "" and FileAccess.file_exists(splat_path):
		var loaded_img := Image.load_from_file(splat_path)
		if loaded_img != null:
			_splat_img = loaded_img
			_splat_img.convert(Image.FORMAT_RGBA8)
	
	if _splat_img == null:
		_splat_img = Image.create(SPLAT_RES, SPLAT_RES, false, Image.FORMAT_RGBA8)
		_splat_img.fill(Color(1.0, 0.0, 0.0, 0.0))

	_water_img = TerrainBuilderScript.load_water_paint(map_id)
	if _water_img != null:
		_water_img.convert(Image.FORMAT_RGBA8)
		_refresh_painted_water_preview()

	_splat_tex = ImageTexture.create_from_image(_splat_img)


func _get_surface_color(stype: String) -> Color:
	for entry in SURFACE_TYPES:
		if entry["id"] == stype:
			return entry["color"]
	return Color(0.35, 0.75, 0.30, 0.95)


func _apply_paint_stroke(hit: Vector3, dt: float) -> void:
	if _splat_img == null or _splat_tex == null or _map.is_empty():
		return
		
	var half: float = float(_map.get("map_half_extents", 960.0))
	var w := _splat_img.get_width()
	var h := _splat_img.get_height()
	
	# WATER IS PAINTED, NOT DUG.
	#
	# This used to drive the terrain down to a hardcoded y = -6 so the map-wide
	# water plane showed through the hole. That makes "paint water" mean "dig a
	# trench to the sea": a lake could only ever exist at table height, and a
	# mountain tarn was impossible - painting one on a hilltop would have
	# excavated the hilltop. Now the brush writes a separate raster carrying a
	# per-texel water SURFACE HEIGHT and leaves the terrain alone.
	if _paint_surface == "water":
		_paint_water_stroke(hit, dt)
		return

	var target_col := Color(1.0, 0.0, 0.0, 0.0)
	if _paint_surface == "rock":
		target_col = Color(0.0, 1.0, 0.0, 0.0)
	elif _paint_surface == "forest":
		target_col = Color(0.0, 0.0, 1.0, 0.0)
	elif _paint_surface == "sand" or _paint_surface == "water":
		target_col = Color(0.0, 0.0, 0.0, 1.0)
	elif _paint_surface == "grass":
		target_col = Color(1.0, 0.0, 0.0, 0.0)

	var u := (hit.x / (half * 2.0) + 0.5) * float(w)
	var v := (hit.z / (half * 2.0) + 0.5) * float(h)
	var r_pix := (_paint_brush_size / (half * 2.0)) * float(w)
	
	var px_min := clampi(int(floor(u - r_pix)), 0, w - 1)
	var px_max := clampi(int(ceil(u + r_pix)), 0, w - 1)
	var py_min := clampi(int(floor(v - r_pix)), 0, h - 1)
	var py_max := clampi(int(ceil(v + r_pix)), 0, h - 1)

	var rate := clampf(_paint_strength * dt * 8.0, 0.05, 1.0)
	for py in range(py_min, py_max + 1):
		for px in range(px_min, px_max + 1):
			var dist := Vector2(float(px) - u, float(py) - v).length() / maxf(1.0, r_pix)
			if dist <= 1.0:
				var f := cos(dist * PI * 0.5)
				f = f * f * rate
				var cur: Color = _splat_img.get_pixel(px, py)
				var mixed: Color = cur.lerp(target_col, f)
				var sum: float = mixed.r + mixed.g + mixed.b + mixed.a
				if sum > 0.001:
					mixed = Color(mixed.r / sum, mixed.g / sum, mixed.b / sum, mixed.a / sum)
				_splat_img.set_pixel(px, py, mixed)

	_splat_tex.update(_splat_img)
	_dirty = true


func _get_or_create_water_img() -> Image:
	if _water_img == null:
		var r: int = TerrainBuilderScript.WATER_PAINT_RES
		_water_img = Image.create(r, r, false, Image.FORMAT_RGBA8)
		_water_img.fill(Color(0.0, 0.0, 0.0, 1.0))
	return _water_img


func _paint_water_stroke(hit: Vector3, dt: float) -> void:
	if _map.is_empty():
		return
	var img := _get_or_create_water_img()
	var half: float = float(_map.get("map_half_extents", 960.0))
	var res := img.get_width()

	# The level this stroke lays down. Following the ground puts the surface
	# just above whatever is under the cursor, so dragging along a valley floor
	# fills it; a fixed level is what you want for a flat lake.
	var level: float = _water_paint_level
	if _water_level_follow_ground:
		level = TerrainBuilderScript.height_at(_map, hit.x, hit.z) + 1.0
	var enc: Vector2 = TerrainBuilderScript.encode_water_height(level)

	var u := (hit.x / (half * 2.0) + 0.5) * float(res)
	var v := (hit.z / (half * 2.0) + 0.5) * float(res)
	var r_pix := (_paint_brush_size / (half * 2.0)) * float(res)
	var px_min := clampi(int(floor(u - r_pix)), 0, res - 1)
	var px_max := clampi(int(ceil(u + r_pix)), 0, res - 1)
	var py_min := clampi(int(floor(v - r_pix)), 0, res - 1)
	var py_max := clampi(int(ceil(v + r_pix)), 0, res - 1)
	var rate := clampf(_paint_strength * dt * 8.0, 0.05, 1.0)

	for py in range(py_min, py_max + 1):
		for px in range(px_min, px_max + 1):
			var dist := Vector2(float(px) - u, float(py) - v).length() / maxf(1.0, r_pix)
			if dist > 1.0:
				continue
			var f := cos(dist * PI * 0.5)
			f = f * f * rate
			var cur: Color = img.get_pixel(px, py)
			if _water_paint_erase:
				img.set_pixel(px, py, Color(maxf(cur.r - f, 0.0), cur.g, cur.b, 1.0))
			else:
				# Height is SET, not blended. Averaging two lakes' heights
				# across an overlap would tilt both their surfaces.
				img.set_pixel(px, py, Color(minf(cur.r + f, 1.0), enc.x, enc.y, 1.0))

	_refresh_painted_water_preview()
	_dirty = true


func _refresh_painted_water_preview() -> void:
	if _water_img == null or _map.is_empty():
		return
	if _painted_water_node == null:
		_painted_water_node = MeshInstance3D.new()
		_painted_water_node.name = "PaintedWaterPreview"
		if _water_node != null and _water_node.get_parent() != null:
			_water_node.get_parent().add_child(_painted_water_node)
		else:
			add_child(_painted_water_node)
		var m := ShaderMaterial.new()
		m.shader = preload("res://shaders/water.gdshader")
		m.set_shader_parameter("water_color", Color(0.12, 0.42, 0.65, 0.85))
		_painted_water_node.material_override = m
	_painted_water_node.mesh = _build_painted_water_preview_mesh()


# Same texel-quad scheme as TerrainBuilder.build_painted_water_mesh, but run
# off the in-memory image so the preview updates mid-stroke without a save.
func _build_painted_water_preview_mesh() -> ArrayMesh:
	var img := _water_img
	if img == null or _map.is_empty():
		return null
	var half: float = float(_map.get("map_half_extents", 960.0))
	var res := img.get_width()
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var step := (half * 2.0) / float(res)
	var emitted := 0
	for py in range(res):
		for px in range(res):
			var c: Color = img.get_pixel(px, py)
			if c.r < TerrainBuilderScript.WATER_PAINT_MIN_COVER:
				continue
			var y: float = TerrainBuilderScript.decode_water_height(c.g, c.b)
			var x0: float = -half + float(px) * step
			var z0: float = -half + float(py) * step
			for vtx in [Vector3(x0, y, z0), Vector3(x0 + step, y, z0),
					Vector3(x0 + step, y, z0 + step), Vector3(x0, y, z0),
					Vector3(x0 + step, y, z0 + step), Vector3(x0, y, z0 + step)]:
				st.set_normal(Vector3.UP)
				st.set_uv(Vector2(vtx.x, vtx.z) / 40.0)
				st.add_vertex(vtx)
			emitted += 1
	if emitted == 0:
		return null
	return st.commit()


func _refresh_water_mesh() -> void:
	if _water_node == null or _map.is_empty():
		return
	var half: float = float(_map.get("map_half_extents", 960.0))
	var plane_mesh := PlaneMesh.new()
	plane_mesh.size = Vector2(half * 2.2, half * 2.2)
	_water_node.mesh = plane_mesh
	
	var water_mat := ShaderMaterial.new()
	water_mat.shader = preload("res://shaders/water.gdshader")
	water_mat.set_shader_parameter("water_color", Color(0.12, 0.42, 0.65, 0.85))
	water_mat.set_shader_parameter("deep_color", Color(0.04, 0.15, 0.32, 0.95))
	_water_node.material_override = water_mat
	_water_node.position = Vector3(0.0, 0.05, 0.0)
	_water_node.visible = true


# ==============================================================================
# SPAWNS & BASES WORKBENCH
# ==============================================================================

func _ensure_spawns_exist() -> void:
	var sps: Array = _map.get("spawns", [])
	var bzs: Array = _map.get("base_zones", [])
	var half: float = float(_map.get("map_half_extents", 400.0))

	var has_player := false
	var has_enemy := false
	for s in sps:
		if str(s.get("id", "")) == "player":
			has_player = true
		elif str(s.get("id", "")) == "enemy":
			has_enemy = true

	if not has_player:
		var px := -half * 0.6
		var pz := 0.0
		var ph := TerrainBuilderScript.height_at(_map, px, pz)
		sps.insert(0, {
			"id": "player",
			"hq": [px, ph, pz],
			"factory": [px - 15.0, ph, pz - 10.0],
			"refinery": [px + 15.0, ph, pz - 10.0],
			"harvester": [px, ph, pz + 15.0]
		})
		bzs.insert(0, {
			"id": "player",
			"center": [px, ph, pz],
			"half_extents": [25.0, 25.0]
		})

	if not has_enemy:
		var ex := half * 0.6
		var ez := 0.0
		var eh := TerrainBuilderScript.height_at(_map, ex, ez)
		sps.append({
			"id": "enemy",
			"hq": [ex, eh, ez],
			"factory": [ex + 15.0, eh, ez + 10.0],
			"refinery": [ex - 15.0, eh, ez + 10.0],
			"harvester": [ex, eh, ez - 15.0]
		})
		bzs.append({
			"id": "enemy",
			"center": [ex, eh, ez],
			"half_extents": [25.0, 25.0]
		})

	_map["spawns"] = sps
	_map["base_zones"] = bzs


func _get_spawn(spawn_id: String) -> Dictionary:
	_ensure_spawns_exist()
	for s in _map.get("spawns", []):
		if str(s.get("id", "")) == spawn_id:
			return s
	return _map.get("spawns", [])[0] if not _map.get("spawns", []).is_empty() else {}


func _get_spawn_hq(spawn_id: String) -> Vector3:
	var s := _get_spawn(spawn_id)
	return TerrainBuilderScript._vec3_of(s.get("hq", [0, 0, 0]))


func _get_base_zone(spawn_id: String) -> Dictionary:
	_ensure_spawns_exist()
	for bz in _map.get("base_zones", []):
		if str(bz.get("id", "")) == spawn_id:
			return bz
	return {}


func _set_spawn_hq_pos(spawn_id: String, hit: Vector3) -> void:
	_ensure_spawns_exist()
	var s := _get_spawn(spawn_id)
	if s.is_empty():
		return

	var nh := TerrainBuilderScript.height_at(_map, hit.x, hit.z)
	var new_hq := Vector3(snappedf(hit.x, 1.0), nh, snappedf(hit.z, 1.0))
	s["hq"] = [new_hq.x, new_hq.y, new_hq.z]

	var sign_x := -1.0 if new_hq.x < 0.0 else 1.0
	var f_pos := Vector3(new_hq.x + sign_x * 15.0, 0.0, new_hq.z - 10.0)
	f_pos.y = TerrainBuilderScript.height_at(_map, f_pos.x, f_pos.z)
	s["factory"] = [f_pos.x, f_pos.y, f_pos.z]

	var r_pos := Vector3(new_hq.x - sign_x * 15.0, 0.0, new_hq.z - 10.0)
	r_pos.y = TerrainBuilderScript.height_at(_map, r_pos.x, r_pos.z)
	s["refinery"] = [r_pos.x, r_pos.y, r_pos.z]

	var h_pos := Vector3(new_hq.x, 0.0, new_hq.z + 15.0)
	h_pos.y = TerrainBuilderScript.height_at(_map, h_pos.x, h_pos.z)
	s["harvester"] = [h_pos.x, h_pos.y, h_pos.z]

	var bz := _get_base_zone(spawn_id)
	if not bz.is_empty():
		bz["center"] = [new_hq.x, new_hq.y, new_hq.z]

	_refresh_spawn_markers()
	_build_spawns_tab_content()
	_mark_dirty()


func _symmetrize_enemy_opposite_player(mode_str: String = "rotational") -> void:
	_push_undo()
	_ensure_spawns_exist()
	var p_hq := _get_spawn_hq("player")
	var e_target := Vector3.ZERO
	if mode_str == "rotational":
		e_target = Vector3(-p_hq.x, 0.0, -p_hq.z)
	elif mode_str == "mirror_x":
		e_target = Vector3(-p_hq.x, 0.0, p_hq.z)
	else:
		e_target = Vector3(p_hq.x, 0.0, -p_hq.z)
	_set_spawn_hq_pos("enemy", e_target)
	_set_status("Symmetrized Enemy spawn opposite Player (%s)." % mode_str, Tokens.SIGNAL_GO)


func _add_resource_at(rtype: String, hit: Vector3) -> void:
	var rnodes: Array = _map.get("resource_nodes", [])
	var amt := 6000 if rtype == "metal" else (4000 if rtype == "crystal" else 2000)
	var pos := [snappedf(hit.x, 1.0), TerrainBuilderScript.height_at(_map, hit.x, hit.z), snappedf(hit.z, 1.0)]
	rnodes.append({
		"type": rtype,
		"position": pos,
		"amount": amt
	})
	_map["resource_nodes"] = rnodes
	_refresh_spawn_markers()
	_build_spawns_tab_content()
	_mark_dirty()


func _refresh_spawn_markers() -> void:
	if _spawn_markers == null or _map.is_empty():
		return
	for c in _spawn_markers.get_children():
		c.queue_free()

	_ensure_spawns_exist()
	var sps: Array = _map.get("spawns", [])
	var bzs: Array = _map.get("base_zones", [])

	for i in range(sps.size()):
		var s: Dictionary = sps[i]
		var sid: String = str(s.get("id", "spawn"))
		var is_friendly := (sid == "player" or i == 0)
		var col := Color(0.2, 0.75, 1.0) if is_friendly else Color(1.0, 0.35, 0.25)
		
		var hq_pos := TerrainBuilderScript._vec3_of(s.get("hq", [0, 0, 0]))
		hq_pos.y = TerrainBuilderScript.height_at(_map, hq_pos.x, hq_pos.z)

		var beacon := MeshInstance3D.new()
		var cyl := CylinderMesh.new()
		cyl.top_radius = 0.5
		cyl.bottom_radius = 0.5
		cyl.height = 16.0
		beacon.mesh = cyl
		var pmat := StandardMaterial3D.new()
		pmat.albedo_color = col
		pmat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		pmat.no_depth_test = true
		beacon.material_override = pmat
		beacon.position = hq_pos + Vector3(0, 8.0, 0)
		_spawn_markers.add_child(beacon)

		var tip := MeshInstance3D.new()
		var sp_m := SphereMesh.new()
		sp_m.radius = 2.4
		sp_m.height = 4.8
		tip.mesh = sp_m
		tip.material_override = pmat
		tip.position = hq_pos + Vector3(0, 16.0, 0)
		_spawn_markers.add_child(tip)

		var hq_box := MeshInstance3D.new()
		var bm := BoxMesh.new()
		bm.size = Vector3(7.0, 4.5, 7.0)
		hq_box.mesh = bm
		hq_box.material_override = pmat
		hq_box.position = hq_pos + Vector3(0, 2.25, 0)
		_spawn_markers.add_child(hq_box)

		for b_info in [["factory", Vector3(8.0, 3.5, 8.0), Color(0.35, 0.55, 0.85)],
					   ["refinery", Vector3(7.0, 4.0, 7.0), Color(0.85, 0.75, 0.25)],
					   ["harvester", Vector3(4.0, 2.5, 4.0), Color(0.25, 0.85, 0.45)]]:
			var b_key: String = b_info[0]
			if s.has(b_key):
				var bp := TerrainBuilderScript._vec3_of(s[b_key])
				bp.y = TerrainBuilderScript.height_at(_map, bp.x, bp.z)
				var b_node := MeshInstance3D.new()
				var b_mesh := BoxMesh.new()
				b_mesh.size = b_info[1]
				b_node.mesh = b_mesh
				var b_mat := StandardMaterial3D.new()
				b_mat.albedo_color = b_info[2]
				b_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
				b_node.material_override = b_mat
				b_node.position = bp + Vector3(0, b_info[1].y * 0.5, 0)
				_spawn_markers.add_child(b_node)

		for bz in bzs:
			if str(bz.get("id", "")) == sid:
				var bz_c := TerrainBuilderScript._vec3_of(bz.get("center", [hq_pos.x, hq_pos.y, hq_pos.z]))
				var bz_he: Vector2 = _xz(bz.get("half_extents", [25.0, 25.0]))
				var bz_box := MeshInstance3D.new()
				var bz_mesh := BoxMesh.new()
				bz_mesh.size = Vector3(bz_he.x * 2.0, 0.25, bz_he.y * 2.0)
				bz_box.mesh = bz_mesh
				var bz_mat := StandardMaterial3D.new()
				bz_mat.albedo_color = Color(col.r, col.g, col.b, 0.35)
				bz_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
				bz_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
				bz_mat.cull_mode = BaseMaterial3D.CULL_DISABLED
				bz_box.material_override = bz_mat
				bz_box.position = Vector3(bz_c.x, hq_pos.y + 0.15, bz_c.z)
				_spawn_markers.add_child(bz_box)

	var rnodes: Array = _map.get("resource_nodes", [])
	for i in range(rnodes.size()):
		var rn: Dictionary = rnodes[i]
		var rpos := TerrainBuilderScript._vec3_of(rn.get("position", [0, 0, 0]))
		rpos.y = TerrainBuilderScript.height_at(_map, rpos.x, rpos.z)
		var rtype: String = str(rn.get("type", "metal"))
		var rcol := Color(0.3, 0.6, 1.0) if rtype == "crystal" else (Color(0.85, 0.65, 0.2) if rtype == "metal" else (Color(0.2, 0.2, 0.2) if rtype == "oil" else Color(0.4, 0.6, 0.2)))

		var r_mi := MeshInstance3D.new()
		var r_mesh := CylinderMesh.new()
		r_mesh.top_radius = 0.0
		r_mesh.bottom_radius = 2.6
		r_mesh.height = 5.0
		r_mi.mesh = r_mesh
		var r_mat := StandardMaterial3D.new()
		r_mat.albedo_color = rcol
		r_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		r_mi.material_override = r_mat
		r_mi.position = rpos + Vector3(0, 2.5, 0)
		_spawn_markers.add_child(r_mi)


# ==============================================================================
# MAP LOADING, CREATION & SAVING
# ==============================================================================

func load_map(mid: String) -> void:
	MapCatalogScript.reset_cache_for_tests()
	var src: Dictionary = MapCatalogScript.get_map(mid)
	if src.is_empty():
		_set_status("Could not load '%s'." % mid, Tokens.SIGNAL_ALERT)
		return
	map_id = mid
	_map = src.duplicate(true)
	
	var terr: Dictionary = _map.get("terrain", {})
	terr.erase("heightmap")
	terr.erase("surfacemap")
	if not terr.has("generator"):
		terr["generator"] = "v2"
	_map["terrain"] = terr
	
	_init_splat_texture()
	_init_props_list()
	_ensure_spawns_exist()
	_selected_feature = -1
	_selected_bridge = -1
	_dragging_spawn_id = ""
	_is_click_placing = false
	_bridge_click_step = 0
	_road_click_step = 0
	_undo_stack.clear()
	_dirty = false
	_cam_dist = float(_map.get("map_half_extents", 960.0)) * 1.4
	if _cam_pivot != null:
		_cam_pivot.position = Vector3.ZERO
	_update_camera()
	_refresh_feature_list()
	_refresh_bridges_ui()
	_build_spawns_tab_content()
	_refresh_spawn_markers()
	_refresh_water_mesh()
	_refresh_bridges_in_scene()
	_rebuild_preview()
	_set_status("Loaded %s (%s m)" % [mid, str(_map.get("map_half_extents", 400))], Tokens.TEXT_SECONDARY)


func _open_new_map_dialog() -> void:
	if _new_map_dialog != null:
		_new_map_dialog.visible = true
		return
		
	_new_map_dialog = PanelContainer.new()
	_new_map_dialog.set_anchors_preset(Control.PRESET_CENTER)
	_new_map_dialog.custom_minimum_size = Vector2(400, 360)
	_new_map_dialog.position = Vector2(400, 180)
	_ui.add_child(_new_map_dialog)

	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", Tokens.SPACE_SM)
	_new_map_dialog.add_child(box)

	var title := Label.new()
	title.text = "CREATE NEW MAP"
	title.theme_type_variation = "TitleLabel"
	box.add_child(title)

	var name_row := HBoxContainer.new()
	box.add_child(name_row)
	var n_lbl := Label.new()
	n_lbl.text = "Map Name"
	n_lbl.custom_minimum_size = Vector2(120, 0)
	name_row.add_child(n_lbl)
	var n_edit := LineEdit.new()
	n_edit.text = "Valley Pass"
	n_edit.custom_minimum_size = Vector2(220, 0)
	name_row.add_child(n_edit)

	var id_row := HBoxContainer.new()
	box.add_child(id_row)
	var id_lbl := Label.new()
	id_lbl.text = "Map ID"
	id_lbl.custom_minimum_size = Vector2(120, 0)
	id_row.add_child(id_lbl)
	var id_edit := LineEdit.new()
	id_edit.text = "valley_pass"
	id_edit.custom_minimum_size = Vector2(220, 0)
	id_row.add_child(id_edit)

	n_edit.text_changed.connect(func(t: String):
		id_edit.text = t.to_lower().replace(" ", "_").replace("-", "_"))

	var size_row := HBoxContainer.new()
	box.add_child(size_row)
	var s_lbl := Label.new()
	s_lbl.text = "Half Extents"
	s_lbl.custom_minimum_size = Vector2(120, 0)
	size_row.add_child(s_lbl)
	var s_opt := OptionButton.new()
	s_opt.add_item("200 m (Small Skirmish)", 200)
	s_opt.add_item("400 m (Tactical Arena)", 400)
	s_opt.add_item("600 m (Large Battlefield)", 600)
	s_opt.add_item("800 m (Epic Valley)", 800)
	s_opt.add_item("960 m (Grand War)", 960)
	s_opt.select(1)
	size_row.add_child(s_opt)

	var theme_row := HBoxContainer.new()
	box.add_child(theme_row)
	var th_lbl := Label.new()
	th_lbl.text = "Biome Theme"
	th_lbl.custom_minimum_size = Vector2(120, 0)
	theme_row.add_child(th_lbl)
	var th_opt := OptionButton.new()
	for k in THEME_PRESETS:
		th_opt.add_item(THEME_PRESETS[k]["name"])
	th_opt.select(0)
	theme_row.add_child(th_opt)

	var btn_row := HBoxContainer.new()
	btn_row.add_theme_constant_override("separation", Tokens.SPACE_MD)
	box.add_child(btn_row)

	var create_btn := Button.new()
	create_btn.text = "Create Map"
	create_btn.pressed.connect(func():
		var final_name := n_edit.text.strip_edges()
		var final_id := id_edit.text.strip_edges().to_lower()
		if final_id == "":
			final_id = "custom_map"
		var half_val := float(s_opt.get_selected_id())
		var theme_keys := THEME_PRESETS.keys()
		var th_key: String = theme_keys[th_opt.selected]
		_create_new_map(final_name, final_id, half_val, th_key)
		_new_map_dialog.visible = false)
	btn_row.add_child(create_btn)

	var cancel_btn := Button.new()
	cancel_btn.text = "Cancel"
	cancel_btn.pressed.connect(func(): _new_map_dialog.visible = false)
	btn_row.add_child(cancel_btn)


func _create_new_map(mname: String, mid: String, half: float, theme_key: String) -> void:
	var th: Dictionary = THEME_PRESETS.get(theme_key, THEME_PRESETS["grassland"])
	var gc: Color = th.get("ground_color", Color(0.30, 0.35, 0.26))
	
	var new_def: Dictionary = {
		"schema_version": 1.0,
		"name": mname,
		"description": "Custom authored battlefield created in TerrainSculpt.",
		"map_half_extents": half,
		"world_scale": 1.0,
		"ground_color": [gc.r, gc.g, gc.b],
		"terrain": {
			"generator": "v2",
			"features": [],
		},
		"base_zones": [
			{"id": "player", "center": [-half * 0.6, 0.0, 0.0], "half_extents": [25.0, 25.0]},
			{"id": "enemy", "center": [half * 0.6, 0.0, 0.0], "half_extents": [25.0, 25.0]},
		],
		"spawns": [
			{
				"id": "player",
				"hq": [-half * 0.6, 0.0, 0.0],
				"factory": [-half * 0.6 - 15.0, 0.0, -10.0],
				"refinery": [-half * 0.6 + 15.0, 0.0, -10.0],
				"harvester": [-half * 0.6, 0.0, 15.0]
			},
			{
				"id": "enemy",
				"hq": [half * 0.6, 0.0, 0.0],
				"factory": [half * 0.6 + 15.0, 0.0, 10.0],
				"refinery": [half * 0.6 - 15.0, 0.0, 10.0],
				"harvester": [half * 0.6, 0.0, -15.0]
			}
		],
		"resource_nodes": [
			{"type": "metal", "position": [-half * 0.45, 0.0, 20.0], "amount": 6000},
			{"type": "crystal", "position": [-half * 0.45, 0.0, -20.0], "amount": 4000},
			{"type": "metal", "position": [half * 0.45, 0.0, -20.0], "amount": 6000},
			{"type": "crystal", "position": [half * 0.45, 0.0, 20.0], "amount": 4000}
		],
		"bridges": [],
		"roads": [],
		"props": [],
		"surface_zones": [],
		"water_areas": [],
		"obstacles": []
	}
	
	var path := "res://data/maps/%s.json" % mid
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f != null:
		f.store_string(JSON.stringify(new_def, "  "))
		f.close()
	
	map_id = mid
	_map = new_def.duplicate(true)
	
	if _map_selector != null:
		_map_selector.add_item(mid)
		_map_selector.select(_map_selector.item_count - 1)
		
	load_map(mid)
	_set_status("Created new map '%s' (%s m)." % [mname, str(half)], Tokens.SIGNAL_GO)


func _save() -> void:
	if _map.is_empty() or map_id == "":
		return
	var path := "res://data/maps/%s.json" % map_id
	var out: Dictionary = _map.duplicate(true)
	var terr: Dictionary = out.get("terrain", {})
	terr["heightmap"] = "res://data/maps/%s_height.png" % map_id
	terr["surfacemap"] = "res://data/maps/%s_surface.png" % map_id
	out["terrain"] = terr
	if not out.has("world_scale"):
		out["world_scale"] = 1.0

	out["props"] = _props_list
	if _water_img != null:
		out["water_paint"] = TerrainBuilderScript.water_paint_path(map_id)

	var gc = out.get("ground_color", [0.3, 0.35, 0.26])
	if gc is Color:
		out["ground_color"] = [gc.r, gc.g, gc.b]
	elif gc is Array and gc.size() >= 3:
		out["ground_color"] = [float(gc[0]), float(gc[1]), float(gc[2])]

	for bz in out.get("base_zones", []):
		var bc: Vector3 = TerrainBuilderScript._vec3_of(bz.get("center", [0, 0, 0]))
		bz["center"] = [bc.x, bc.y, bc.z]
		var bhe: Vector2 = _xz(bz.get("half_extents", [25.0, 25.0]))
		bz["half_extents"] = [bhe.x, bhe.y]

	for b in out.get("bridges", []):
		var bc: Vector3 = TerrainBuilderScript._vec3_of(b.get("center", [0, 0, 0]))
		b["center"] = [bc.x, bc.y, bc.z]
		var bhe: Vector2 = _xz(b.get("half_extents", [10.0, 10.0]))
		b["half_extents"] = [bhe.x, bhe.y]

	for sp in out.get("spawns", []):
		for bk in ["hq", "factory", "refinery", "harvester"]:
			if sp.has(bk):
				var bp: Vector3 = TerrainBuilderScript._vec3_of(sp[bk])
				sp[bk] = [bp.x, bp.y, bp.z]

	for rn in out.get("resource_nodes", []):
		if rn.has("position"):
			var rp: Vector3 = TerrainBuilderScript._vec3_of(rn["position"])
			rn["position"] = [rp.x, rp.y, rp.z]

	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		_set_status("Could not write %s" % path, Tokens.SIGNAL_ALERT)
		return
	f.store_string(JSON.stringify(out, "  "))
	f.close()
	
	if _splat_img != null:
		var splat_path := "res://data/maps/%s_splat.png" % map_id
		_splat_img.save_png(splat_path)
		print("[sculpt] saved %s" % splat_path)

	if _water_img != null:
		var water_path: String = TerrainBuilderScript.water_paint_path(map_id)
		_water_img.save_png(water_path)
		print("[sculpt] saved %s" % water_path)
		
	_dirty = false
	_set_status("Saved %s.json, splat texture, and %d authored props successfully." % [map_id, _props_list.size()], Tokens.SIGNAL_GO)
	print("[sculpt] saved %s" % path)


# ==============================================================================
# PREVIEW MESH GENERATION
# ==============================================================================

func _mark_dirty() -> void:
	_dirty = true
	_rebuild_preview()
	_refresh_handles()


func _rebuild_preview(full: bool = false) -> void:
	if _map.is_empty() or _ground == null:
		return
	var t0 := Time.get_ticks_msec()
	
	_ground.mesh = _build_full_grid_mesh(128 if full else PREVIEW_DIVS)
		
	var mat: ShaderMaterial = TerrainBuilderScript.build_ground_material_for(
		_map.get("ground_color", Color(0.3, 0.34, 0.28)), _map, map_id) as ShaderMaterial
	
	if _splat_tex != null and mat != null:
		mat.set_shader_parameter("splat_tex", _splat_tex)
		mat.set_shader_parameter("use_splat", true)
		
	_ground.material_override = mat
	_refresh_water_mesh()
	_refresh_bridges_in_scene()
	_refresh_props_multimesh()
	_update_rock_shader_params()
		
	_set_status("%s updated (%d ms)" % ["Full mesh" if full else "Preview", Time.get_ticks_msec() - t0],
		Tokens.TEXT_SECONDARY)


func _build_full_grid_mesh(n_divs: int = PREVIEW_DIVS) -> ArrayMesh:
	var half: float = float(_map.get("map_half_extents", 960.0))
	var n := n_divs
	var step := (half * 2.0) / float(n)
	var grid_pts := (n + 1) * (n + 1)
	
	var heights := PackedFloat32Array()
	var verts := PackedVector3Array()
	var norms := PackedVector3Array()
	var uvs := PackedVector2Array()
	heights.resize(grid_pts)
	verts.resize(grid_pts)
	norms.resize(grid_pts)
	uvs.resize(grid_pts)

	# 1. Height Sample
	for i in range(n + 1):
		var x := -half + step * float(i)
		for j in range(n + 1):
			var z := -half + step * float(j)
			var idx := i * (n + 1) + j
			var h := TerrainBuilderScript.height_at(_map, x, z)
			heights[idx] = h
			verts[idx] = Vector3(x, h, z)
			uvs[idx] = Vector2(x, z) / 24.0

	# 2. Fast Analytical Normals
	var inv_2step := 1.0 / (2.0 * step)
	for i in range(n + 1):
		var i_prev := maxi(0, i - 1)
		var i_next := mini(n, i + 1)
		for j in range(n + 1):
			var idx := i * (n + 1) + j
			var j_prev := maxi(0, j - 1)
			var j_next := mini(n, j + 1)
			var dh_dx := (heights[i_next * (n + 1) + j] - heights[i_prev * (n + 1) + j]) * inv_2step
			var dh_dz := (heights[i * (n + 1) + j_next] - heights[i * (n + 1) + j_prev]) * inv_2step
			norms[idx] = Vector3(-dh_dx, 1.0, -dh_dz).normalized()

	# 3. Indices (Counter-Clockwise front-facing)
	var indices := PackedInt32Array()
	indices.resize(n * n * 6)
	var ptr := 0
	for i in range(n):
		for j in range(n):
			var i00 := i * (n + 1) + j
			var i10 := (i + 1) * (n + 1) + j
			var i11 := (i + 1) * (n + 1) + j + 1
			var i01 := i * (n + 1) + j + 1
			indices[ptr] = i00
			indices[ptr + 1] = i10
			indices[ptr + 2] = i11
			indices[ptr + 3] = i00
			indices[ptr + 4] = i11
			indices[ptr + 5] = i01
			ptr += 6

	if n == PREVIEW_DIVS:
		_grid_heights = heights
		_grid_verts = verts
		_grid_norms = norms
		_grid_uvs = uvs
		_grid_indices = indices
		_mesh_allocated = true

	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_NORMAL] = norms
	arrays[Mesh.ARRAY_TEX_UV] = uvs
	arrays[Mesh.ARRAY_INDEX] = indices

	var am := ArrayMesh.new()
	am.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	return am


# ==============================================================================
# PARAMETRIC FEATURES
# ==============================================================================

static func _xz(v) -> Vector2:
	var p: Vector3 = TerrainBuilderScript._vec3_of(v)
	return Vector2(p.x, p.z)


static func _pt(v: Vector2) -> Array:
	return [snappedf(v.x, 0.1), snappedf(v.y, 0.1)]


func _features() -> Array:
	var terr = _map.get("terrain", {})
	if typeof(terr) != TYPE_DICTIONARY:
		return []
	return terr.get("features", [])


func _feature_centre(f: Dictionary) -> Vector2:
	match str(f.get("type", "")):
		"ramp":
			return _xz(f.get("anchor", [0, 0]))
		"canyon":
			return (_xz(f.get("start", [0, 0])) + _xz(f.get("end", [0, 0]))) * 0.5
		"ridge":
			var pts: Array = f.get("points", [])
			if pts.is_empty():
				return Vector2.ZERO
			var acc := Vector2.ZERO
			for p in pts:
				acc += _xz(p)
			return acc / float(pts.size())
		_:
			return _xz(f.get("center", [0, 0]))


func _set_feature_centre(f: Dictionary, to: Vector2) -> void:
	var delta := to - _feature_centre(f)
	match str(f.get("type", "")):
		"ramp":
			f["anchor"] = _pt(_xz(f.get("anchor", [0, 0])) + delta)
		"canyon":
			f["start"] = _pt(_xz(f.get("start", [0, 0])) + delta)
			f["end"] = _pt(_xz(f.get("end", [0, 0])) + delta)
		"ridge":
			var out := []
			for p in f.get("points", []):
				out.append(_pt(_xz(p) + delta))
			f["points"] = out
		_:
			f["center"] = _pt(_xz(f.get("center", [0, 0])) + delta)


func _move_selected_to(hit: Vector3) -> void:
	var feats := _features()
	if _selected_feature < 0 or _selected_feature >= feats.size():
		return
	_set_feature_centre(feats[_selected_feature], Vector2(hit.x, hit.z))
	_mark_dirty()
	_refresh_feature_props()


func _add_feature(type_name: String) -> void:
	if _map.is_empty():
		return
	_push_undo()
	var f := {"type": type_name}
	for k in FEATURE_DEFAULTS.get(type_name, {}):
		f[k] = FEATURE_DEFAULTS[type_name][k]
	var c := Vector2(_cam_pivot.position.x, _cam_pivot.position.z)
	match type_name:
		"ramp":
			f["anchor"] = _pt(c)
		"canyon":
			var l: float = float(f.get("length", 400.0))
			f.erase("length")
			f["start"] = _pt(c - Vector2(0.0, l * 0.5))
			f["end"] = _pt(c + Vector2(0.0, l * 0.5))
		"ridge":
			var rl: float = float(f.get("length", 300.0))
			f.erase("length")
			f["points"] = [_pt(c - Vector2(0.0, rl * 0.5)), _pt(c), _pt(c + Vector2(0.0, rl * 0.5))]
		_:
			f["center"] = _pt(c)
	var terr: Dictionary = _map.get("terrain", {})
	var feats: Array = terr.get("features", [])
	feats.append(f)
	terr["features"] = feats
	_map["terrain"] = terr
	_selected_feature = feats.size() - 1
	_refresh_feature_list()
	_mark_dirty()
	_refresh_feature_props()


func _delete_selected_feature() -> void:
	var feats := _features()
	if _selected_feature < 0 or _selected_feature >= feats.size():
		return
	_push_undo()
	feats.remove_at(_selected_feature)
	_selected_feature = mini(_selected_feature, feats.size() - 1)
	_refresh_feature_list()
	_mark_dirty()
	_refresh_feature_props()


func _refresh_handles() -> void:
	if _handles == null or _map.is_empty():
		return
	for c in _handles.get_children():
		c.queue_free()
	if _mode != Mode.FEATURES:
		return
	var feats := _features()
	var r: float = float(_map.get("map_half_extents", 960.0)) * 0.014
	for i in range(feats.size()):
		var f: Dictionary = feats[i]
		var c := _feature_centre(f)
		var m := MeshInstance3D.new()
		var sphere := SphereMesh.new()
		sphere.radius = r
		sphere.height = r * 2.0
		m.mesh = sphere
		var mat := StandardMaterial3D.new()
		mat.albedo_color = Tokens.SIGNAL_HAZARD if i == _selected_feature else Tokens.TEXT_SECONDARY
		mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		mat.no_depth_test = true
		m.material_override = mat
		m.position = Vector3(c.x, TerrainBuilderScript.height_at(_map, c.x, c.y) + r * 2.0, c.y)
		_handles.add_child(m)


func _refresh_feature_list() -> void:
	if _feature_list == null:
		return
	_feature_list.clear()
	var feats := _features()
	for i in range(feats.size()):
		var c := _feature_centre(feats[i])
		_feature_list.add_item("%d  %s  (%.0f, %.0f)" % [i + 1, str(feats[i].get("type", "?")), c.x, c.y])
	if _selected_feature >= 0 and _selected_feature < feats.size():
		_feature_list.select(_selected_feature)


func _refresh_feature_props() -> void:
	if _feature_props == null:
		return
	for c in _feature_props.get_children():
		c.queue_free()
	var feats := _features()
	if _selected_feature < 0 or _selected_feature >= feats.size():
		var hint := Label.new()
		hint.text = "Select or add a feature shape."
		hint.theme_type_variation = "HintLabel"
		_feature_props.add_child(hint)
		return
	var f: Dictionary = feats[_selected_feature]

	var head := Label.new()
	head.text = str(f.get("type", "?")).to_upper()
	head.theme_type_variation = "HeadingLabel"
	_feature_props.add_child(head)

	var pos := Label.new()
	var c := _feature_centre(f)
	pos.text = "Centre (%.0f, %.0f)" % [c.x, c.y]
	pos.theme_type_variation = "StatLabel"
	_feature_props.add_child(pos)

	for key in f.keys():
		var v = f[key]
		if typeof(v) == TYPE_FLOAT or typeof(v) == TYPE_INT:
			_feature_props.add_child(_spin_row(str(key), float(v), key))
		elif typeof(v) == TYPE_ARRAY and str(key) == "half_extents" and v.size() >= 2:
			_feature_props.add_child(_spin_row("half_extents.x", float(v[0]), "half_extents.x"))
			_feature_props.add_child(_spin_row("half_extents.z", float(v[1]), "half_extents.z"))


func _spin_row(label_text: String, value: float, key: String) -> HBoxContainer:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", Tokens.SPACE_SM)
	var l := Label.new()
	l.text = label_text
	l.custom_minimum_size = Vector2(130, 0)
	l.theme_type_variation = "StatLabel"
	row.add_child(l)
	var sb := SpinBox.new()
	sb.min_value = -4000.0
	sb.max_value = 4000.0
	sb.step = 0.5
	sb.value = value
	sb.custom_minimum_size = Vector2(110, 0)
	sb.value_changed.connect(func(nv: float):
		var feats := _features()
		if _selected_feature >= 0 and _selected_feature < feats.size():
			var f: Dictionary = feats[_selected_feature]
			if key == "half_extents.x":
				var he: Array = f.get("half_extents", [10.0, 10.0])
				f["half_extents"] = [nv, float(he[1])]
			elif key == "half_extents.z":
				var he2: Array = f.get("half_extents", [10.0, 10.0])
				f["half_extents"] = [float(he2[0]), nv]
			else:
				f[key] = nv
			_mark_dirty()
			_refresh_feature_list())
	row.add_child(sb)
	return row


# ==============================================================================
# UI CONSTRUCTION
# ==============================================================================

func _build_ui() -> void:
	var layer := CanvasLayer.new()
	add_child(layer)
	_ui = Control.new()
	_ui.set_anchors_preset(Control.PRESET_FULL_RECT)
	_ui.mouse_filter = Control.MOUSE_FILTER_IGNORE
	layer.add_child(_ui)

	var panel := PanelContainer.new()
	panel.set_anchors_preset(Control.PRESET_TOP_LEFT)
	panel.position = Vector2(16, 16)
	panel.custom_minimum_size = Vector2(380, 820)
	panel.mouse_filter = Control.MOUSE_FILTER_STOP
	_ui.add_child(panel)

	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", Tokens.SPACE_SM)
	panel.add_child(col)

	var title_row := HBoxContainer.new()
	title_row.add_theme_constant_override("separation", Tokens.SPACE_SM)
	col.add_child(title_row)
	
	var title := Label.new()
	title.text = "TERRAIN SCULPT"
	title.theme_type_variation = "TitleLabel"
	title_row.add_child(title)

	var new_btn := Button.new()
	new_btn.text = "+ New Map"
	new_btn.pressed.connect(_open_new_map_dialog)
	title_row.add_child(new_btn)

	var map_row := HBoxContainer.new()
	map_row.add_theme_constant_override("separation", Tokens.SPACE_SM)
	col.add_child(map_row)
	var map_lbl := Label.new()
	map_lbl.text = "Map:"
	map_lbl.theme_type_variation = "StatLabel"
	map_row.add_child(map_lbl)
	
	_map_selector = OptionButton.new()
	_map_selector.custom_minimum_size = Vector2(250, 0)
	for mid in MapCatalogScript.get_map_ids():
		if TerrainBuilderScript.terrain_generator(MapCatalogScript.get_map(mid)) == "v2":
			_map_selector.add_item(str(mid))
	_map_selector.item_selected.connect(func(idx: int):
		var selected_id := _map_selector.get_item_text(idx)
		load_map(selected_id))
	map_row.add_child(_map_selector)

	var cam_row := HBoxContainer.new()
	cam_row.add_theme_constant_override("separation", Tokens.SPACE_XS)
	col.add_child(cam_row)

	var undo_btn := Button.new()
	undo_btn.text = "↶ Undo (Ctrl+Z)"
	undo_btn.tooltip_text = "Undo Last Action (Ctrl+Z)"
	undo_btn.pressed.connect(_undo)
	cam_row.add_child(undo_btn)

	var rot_l_btn := Button.new()
	rot_l_btn.text = "⟲ 45°"
	rot_l_btn.tooltip_text = "Rotate Camera Left (Q)"
	rot_l_btn.pressed.connect(func(): _rotate_camera_degrees(45.0))
	cam_row.add_child(rot_l_btn)

	var rot_r_btn := Button.new()
	rot_r_btn.text = "⟳ 45°"
	rot_r_btn.tooltip_text = "Rotate Camera Right (E)"
	rot_r_btn.pressed.connect(func(): _rotate_camera_degrees(-45.0))
	cam_row.add_child(rot_r_btn)

	var reset_cam_btn := Button.new()
	reset_cam_btn.text = "Reset"
	reset_cam_btn.tooltip_text = "Reset Camera View & Center (Home)"
	reset_cam_btn.pressed.connect(_reset_camera_view)
	cam_row.add_child(reset_cam_btn)

	var topdown_btn := Button.new()
	topdown_btn.text = "2D/3D (T)"
	topdown_btn.pressed.connect(func():
		_is_topdown = not _is_topdown
		_update_camera()
		_set_status("Camera: %s" % ["Top-Down 2D" if _is_topdown else "3D Orbit"], Tokens.TEXT_SECONDARY))
	cam_row.add_child(topdown_btn)

	var cmd_btn := Button.new()
	cmd_btn.text = "👁 Cam (F)"
	cmd_btn.tooltip_text = "Toggle Commander Tactical Ground View (F)"
	cmd_btn.pressed.connect(_toggle_commander_view)
	cam_row.add_child(cmd_btn)

	_tab_container = TabContainer.new()
	_tab_container.custom_minimum_size = Vector2(350, 480)
	_tab_container.tab_changed.connect(func(tab: int):
		_mode = tab
		_handles.visible = (_mode == Mode.FEATURES)
		_refresh_handles()
		_bridge_click_step = 0
		_road_click_step = 0
		if _preview_line != null: _preview_line.visible = false
		if _cursor_ring != null:
			_cursor_ring.visible = (_mode == Mode.SCULPT or _mode == Mode.PAINT or _mode == Mode.GREEBLES or _mode == Mode.ROADS_BRIDGES or _is_click_placing))
	col.add_child(_tab_container)

	# 1. Sculpt Tab
	var sculpt_tab := VBoxContainer.new()
	sculpt_tab.name = "Sculpt"
	sculpt_tab.add_theme_constant_override("separation", Tokens.SPACE_SM)
	_tab_container.add_child(sculpt_tab)
	_build_sculpt_tab(sculpt_tab)

	# 2. Paint Tab
	var paint_tab := VBoxContainer.new()
	paint_tab.name = "Paint"
	paint_tab.add_theme_constant_override("separation", Tokens.SPACE_SM)
	_tab_container.add_child(paint_tab)
	_build_paint_tab(paint_tab)

	# 3. Roads & Bridges Tab
	var rb_tab := VBoxContainer.new()
	rb_tab.name = "Roads / Bridges"
	rb_tab.add_theme_constant_override("separation", Tokens.SPACE_SM)
	_tab_container.add_child(rb_tab)
	_build_roads_bridges_tab(rb_tab)

	# 4. Greebles & Props Tab
	var greeb_tab := VBoxContainer.new()
	greeb_tab.name = "Greebles"
	greeb_tab.add_theme_constant_override("separation", Tokens.SPACE_SM)
	_tab_container.add_child(greeb_tab)
	_build_greebles_tab(greeb_tab)

	# 5. Shapes Tab
	var feat_tab := VBoxContainer.new()
	feat_tab.name = "Shapes"
	feat_tab.add_theme_constant_override("separation", Tokens.SPACE_SM)
	_tab_container.add_child(feat_tab)
	_build_features_tab(feat_tab)

	# 6. Spawns Tab
	_spawns_container = VBoxContainer.new()
	_spawns_container.name = "Spawns"
	_spawns_container.add_theme_constant_override("separation", Tokens.SPACE_SM)
	_tab_container.add_child(_spawns_container)
	_build_spawns_tab_content()

	# 7. Map Tab
	var props_tab := VBoxContainer.new()
	props_tab.name = "Map"
	props_tab.add_theme_constant_override("separation", Tokens.SPACE_SM)
	_tab_container.add_child(props_tab)
	_build_map_tab(props_tab)

	var bot_sep := HSeparator.new()
	col.add_child(bot_sep)

	var btn_row := HBoxContainer.new()
	btn_row.add_theme_constant_override("separation", Tokens.SPACE_SM)
	col.add_child(btn_row)

	var undo_btn2 := Button.new()
	undo_btn2.text = "↶ Undo"
	undo_btn2.pressed.connect(_undo)
	btn_row.add_child(undo_btn2)

	var full_btn := Button.new()
	full_btn.text = "Full Preview"
	full_btn.pressed.connect(func(): _rebuild_preview(true))
	btn_row.add_child(full_btn)

	var save_btn := Button.new()
	save_btn.text = "Save Map JSON"
	save_btn.pressed.connect(_save)
	btn_row.add_child(save_btn)

	_scale_readout = Label.new()
	_scale_readout.text = "Elevation: 0.0m (Slope: 0°) | Brush: 90m (~20 tanks)"
	_scale_readout.theme_type_variation = "StatLabel"
	_scale_readout.add_theme_color_override("font_color", Color(0.85, 0.85, 0.45))
	col.add_child(_scale_readout)

	_status = Label.new()
	_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_status.custom_minimum_size = Vector2(340, 36)
	_status.theme_type_variation = "StatLabel"
	col.add_child(_status)

	var help := Label.new()
	help.text = "Ctrl+Z: Undo | F: Commander View | RMB / Alt+LMB: Rotate | Q/E: Rotate | WASD / MMB: Pan | Wheel: Zoom | T: 2D/3D"
	help.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	help.custom_minimum_size = Vector2(340, 0)
	help.theme_type_variation = "HintLabel"
	col.add_child(help)


func _build_sculpt_tab(parent: VBoxContainer) -> void:
	var tool_lbl := Label.new()
	tool_lbl.text = "Sculpt Brush Tool:"
	tool_lbl.theme_type_variation = "HeadingLabel"
	parent.add_child(tool_lbl)

	var tool_grid := GridContainer.new()
	tool_grid.columns = 2
	tool_grid.add_theme_constant_override("h_separation", Tokens.SPACE_XS)
	tool_grid.add_theme_constant_override("v_separation", Tokens.SPACE_XS)
	parent.add_child(tool_grid)

	var tools := [
		{"name": "Raise (Elevation)", "tool": SculptTool.RAISE},
		{"name": "Lower (Depression)", "tool": SculptTool.LOWER},
		{"name": "Smooth (Blend)", "tool": SculptTool.SMOOTH},
		{"name": "Flatten (Level)", "tool": SculptTool.FLATTEN},
	]
	for t in tools:
		var b := Button.new()
		b.text = t["name"]
		b.pressed.connect(func():
			_sculpt_tool = t["tool"]
			_set_status("Active Tool: %s" % t["name"], Tokens.TEXT_SECONDARY))
		tool_grid.add_child(b)

	var rad_row := HBoxContainer.new()
	parent.add_child(rad_row)
	var r_lbl := Label.new()
	r_lbl.text = "Brush Radius"
	r_lbl.custom_minimum_size = Vector2(120, 0)
	rad_row.add_child(r_lbl)
	var r_sb := SpinBox.new()
	r_sb.min_value = 5.0
	r_sb.max_value = 300.0
	r_sb.step = 5.0
	r_sb.value = _brush_radius
	r_sb.value_changed.connect(func(v: float):
		_brush_radius = v
		_update_cursor_ring_mesh(_brush_radius))
	rad_row.add_child(r_sb)

	var str_row := HBoxContainer.new()
	parent.add_child(str_row)
	var s_lbl := Label.new()
	s_lbl.text = "Strength"
	s_lbl.custom_minimum_size = Vector2(120, 0)
	str_row.add_child(s_lbl)
	var s_sb := SpinBox.new()
	s_sb.min_value = 0.5
	s_sb.max_value = 30.0
	s_sb.step = 0.5
	s_sb.value = _brush_strength
	s_sb.value_changed.connect(func(v: float): _brush_strength = v)
	str_row.add_child(s_sb)

	var fall_row := HBoxContainer.new()
	parent.add_child(fall_row)
	var f_lbl := Label.new()
	f_lbl.text = "Falloff"
	f_lbl.custom_minimum_size = Vector2(120, 0)
	fall_row.add_child(f_lbl)
	var f_opt := OptionButton.new()
	f_opt.add_item("Smooth (Cosine Curve)")
	f_opt.add_item("Gaussian (Soft)")
	f_opt.add_item("Linear (Cone)")
	f_opt.add_item("Flat (Zero Falloff - Sheer Cliff)")
	var falloff_keys := ["smooth", "gaussian", "linear", "flat"]
	f_opt.item_selected.connect(func(idx: int):
		_brush_falloff = falloff_keys[idx]
		_set_status("Falloff: %s" % f_opt.get_item_text(idx), Tokens.TEXT_SECONDARY))
	fall_row.add_child(f_opt)

	var tip := Label.new()
	tip.text = "Tip: Hold Ctrl+Drag to invert brush, Shift+Drag to smooth."
	tip.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	tip.theme_type_variation = "HintLabel"
	parent.add_child(tip)

	var scale_sep := HSeparator.new()
	parent.add_child(scale_sep)

	var scale_lbl := Label.new()
	scale_lbl.text = "Scale Entire Map Heights:"
	scale_lbl.theme_type_variation = "HeadingLabel"
	parent.add_child(scale_lbl)

	var scale_btn_row := HBoxContainer.new()
	scale_btn_row.add_theme_constant_override("separation", Tokens.SPACE_XS)
	parent.add_child(scale_btn_row)

	for factor in [0.25, 0.5, 0.75, 1.25, 1.5]:
		var sb := Button.new()
		sb.text = str(factor) + "x"
		sb.tooltip_text = "Scale all map terrain heights by " + str(factor) + "x"
		sb.pressed.connect(_scale_all_heights.bind(factor))
		scale_btn_row.add_child(sb)


func _build_paint_tab(parent: VBoxContainer) -> void:
	var p_lbl := Label.new()
	p_lbl.text = "Texture & Terrain Material:"
	p_lbl.theme_type_variation = "HeadingLabel"
	parent.add_child(p_lbl)

	var p_grid := GridContainer.new()
	p_grid.columns = 2
	p_grid.add_theme_constant_override("h_separation", Tokens.SPACE_XS)
	p_grid.add_theme_constant_override("v_separation", Tokens.SPACE_XS)
	parent.add_child(p_grid)

	for s in SURFACE_TYPES:
		var b := Button.new()
		b.text = s["name"]
		b.pressed.connect(func():
			_paint_surface = s["id"]
			_set_status("Painting Ground: %s" % s["name"], s["color"]))
		p_grid.add_child(b)

	var bsize_row := HBoxContainer.new()
	parent.add_child(bsize_row)
	var bs_lbl := Label.new()
	bs_lbl.text = "Brush Size"
	bs_lbl.custom_minimum_size = Vector2(120, 0)
	bsize_row.add_child(bs_lbl)
	var bs_sb := SpinBox.new()
	bs_sb.min_value = 5.0
	bs_sb.max_value = 300.0
	bs_sb.step = 5.0
	bs_sb.value = _paint_brush_size
	bs_sb.value_changed.connect(func(v: float):
		_paint_brush_size = v
		_update_cursor_ring_mesh(_paint_brush_size))
	bsize_row.add_child(bs_sb)

	# Water brush controls. Only meaningful with the Water surface selected,
	# but kept visible rather than hidden so the level is readable before you
	# start a stroke - a lake painted at the wrong height is invisible until
	# you look at it from the side.
	var wsep := HSeparator.new()
	parent.add_child(wsep)
	var w_head := Label.new()
	w_head.text = "Water Brush:"
	w_head.theme_type_variation = "StatLabel"
	parent.add_child(w_head)

	var wfollow := CheckBox.new()
	wfollow.text = "Surface follows ground (+1 m)"
	wfollow.button_pressed = _water_level_follow_ground
	wfollow.tooltip_text = "On: each stroke sits just above the terrain under the cursor - drag along a valley to flood it.
Off: every stroke uses the fixed level below, which is what a flat lake needs."
	wfollow.toggled.connect(func(v: bool): _water_level_follow_ground = v)
	parent.add_child(wfollow)

	var wlv_row := HBoxContainer.new()
	parent.add_child(wlv_row)
	var wlv_lbl := Label.new()
	wlv_lbl.text = "Surface Height"
	wlv_lbl.custom_minimum_size = Vector2(120, 0)
	wlv_row.add_child(wlv_lbl)
	var wlv_sb := SpinBox.new()
	wlv_sb.min_value = TerrainBuilderScript.WATER_PAINT_RANGE.x
	wlv_sb.max_value = TerrainBuilderScript.WATER_PAINT_RANGE.y
	wlv_sb.step = 0.5
	wlv_sb.value = _water_paint_level
	wlv_sb.value_changed.connect(func(v: float): _water_paint_level = v)
	wlv_row.add_child(wlv_sb)

	var werase := CheckBox.new()
	werase.text = "Erase water"
	werase.button_pressed = _water_paint_erase
	werase.toggled.connect(func(v: bool): _water_paint_erase = v)
	parent.add_child(werase)

	var wpick := Button.new()
	wpick.text = "Set Height From Terrain Under Cursor"
	wpick.pressed.connect(func():
		if not _has_valid_hit:
			_set_status("Point the cursor at the terrain first.", Tokens.SIGNAL_ALERT)
			return
		var hit: Vector3 = _last_hit_point
		_water_paint_level = TerrainBuilderScript.height_at(_map, hit.x, hit.z) + 1.0
		wlv_sb.value = _water_paint_level
		_water_level_follow_ground = false
		wfollow.button_pressed = false
		_set_status("Water surface set to %.1f m" % _water_paint_level, Tokens.SIGNAL_GO))
	parent.add_child(wpick)

	var pstr_row := HBoxContainer.new()
	parent.add_child(pstr_row)
	var pstr_lbl := Label.new()
	pstr_lbl.text = "Flow Rate"
	pstr_lbl.custom_minimum_size = Vector2(120, 0)
	pstr_row.add_child(pstr_lbl)
	var pstr_sb := SpinBox.new()
	pstr_sb.min_value = 0.1
	pstr_sb.max_value = 2.0
	pstr_sb.step = 0.05
	pstr_sb.value = _paint_strength
	pstr_sb.value_changed.connect(func(v: float): _paint_strength = v)
	pstr_row.add_child(pstr_sb)

	var clear_btn := Button.new()
	clear_btn.text = "Fill Entire Map with Base Grass"
	clear_btn.pressed.connect(func():
		if _splat_img != null and _splat_tex != null:
			_push_undo()
			_splat_img.fill(Color(1.0, 0.0, 0.0, 0.0))
			_splat_tex.update(_splat_img)
			_dirty = true
			_set_status("Filled ground with Base Grass.", Tokens.SIGNAL_GO))
	parent.add_child(clear_btn)

	var r_sep := HSeparator.new()
	parent.add_child(r_sep)

	var r_head := Label.new()
	r_head.text = "⛰️ Rock & Cliff Stone Face Styling:"
	r_head.theme_type_variation = "HeadingLabel"
	parent.add_child(r_head)

	var pat_row := HBoxContainer.new()
	parent.add_child(pat_row)
	var pat_lbl := Label.new()
	pat_lbl.text = "Stone Pattern"
	pat_lbl.custom_minimum_size = Vector2(120, 0)
	pat_row.add_child(pat_lbl)
	var pat_opt := OptionButton.new()
	pat_opt.add_item("Sedimentary Strata (Tan / Shale / Iron)", 0)
	pat_opt.add_item("Fractured Granite (Grey / Lichen)", 1)
	pat_opt.add_item("Rugged Crag (Brownish-Red)", 2)
	pat_opt.add_item("Limestone Bedrock (Cream / Yellow)", 3)
	var terr: Dictionary = _map.get("terrain", {}) if typeof(_map.get("terrain", {})) == TYPE_DICTIONARY else {}
	pat_opt.selected = int(terr.get("rock_pattern", 0))
	pat_opt.item_selected.connect(func(idx: int):
		if not _map.has("terrain") or typeof(_map["terrain"]) != TYPE_DICTIONARY:
			_map["terrain"] = {}
		_map["terrain"]["rock_pattern"] = idx
		_update_rock_shader_params()
		_dirty = true
		_set_status("Selected Stone Pattern: %s" % pat_opt.get_item_text(idx), Tokens.SIGNAL_GO))
	pat_row.add_child(pat_opt)

	var rstr_row := HBoxContainer.new()
	parent.add_child(rstr_row)
	var rstr_lbl := Label.new()
	rstr_lbl.text = "Strata Banding"
	rstr_lbl.custom_minimum_size = Vector2(120, 0)
	rstr_row.add_child(rstr_lbl)
	var rstr_sb := SpinBox.new()
	rstr_sb.min_value = 0.0
	rstr_sb.max_value = 2.0
	rstr_sb.step = 0.05
	rstr_sb.value = float(terr.get("rock_strata_strength", 1.1))
	rstr_sb.value_changed.connect(func(v: float):
		if not _map.has("terrain") or typeof(_map["terrain"]) != TYPE_DICTIONARY:
			_map["terrain"] = {}
		_map["terrain"]["rock_strata_strength"] = v
		_update_rock_shader_params()
		_dirty = true)
	rstr_row.add_child(rstr_sb)

	var rbump_row := HBoxContainer.new()
	parent.add_child(rbump_row)
	var rbump_lbl := Label.new()
	rbump_lbl.text = "3D Relief / Bump"
	rbump_lbl.custom_minimum_size = Vector2(120, 0)
	rbump_row.add_child(rbump_lbl)
	var rbump_sb := SpinBox.new()
	rbump_sb.min_value = 0.0
	rbump_sb.max_value = 3.0
	rbump_sb.step = 0.1
	rbump_sb.value = float(terr.get("rock_bump_strength", 1.6))
	rbump_sb.value_changed.connect(func(v: float):
		if not _map.has("terrain") or typeof(_map["terrain"]) != TYPE_DICTIONARY:
			_map["terrain"] = {}
		_map["terrain"]["rock_bump_strength"] = v
		_update_rock_shader_params()
		_dirty = true)
	rbump_row.add_child(rbump_sb)

	var rscale_row := HBoxContainer.new()
	parent.add_child(rscale_row)
	var rscale_lbl := Label.new()
	rscale_lbl.text = "Strata Layer Scale"
	rscale_lbl.custom_minimum_size = Vector2(120, 0)
	rscale_row.add_child(rscale_lbl)
	var rscale_sb := SpinBox.new()
	rscale_sb.min_value = 0.02
	rscale_sb.max_value = 0.6
	rscale_sb.step = 0.02
	rscale_sb.value = float(terr.get("rock_strata_scale", 0.16))
	rscale_sb.value_changed.connect(func(v: float):
		if not _map.has("terrain") or typeof(_map["terrain"]) != TYPE_DICTIONARY:
			_map["terrain"] = {}
		_map["terrain"]["rock_strata_scale"] = v
		_update_rock_shader_params()
		_dirty = true)
	rscale_row.add_child(rscale_sb)


func _build_roads_bridges_tab(parent: VBoxContainer) -> void:
	# === 1. 2-POINT BRIDGES ===
	var b_head := Label.new()
	b_head.text = "2-Point Bridges:"
	b_head.theme_type_variation = "HeadingLabel"
	parent.add_child(b_head)

	var b_build_btn := Button.new()
	b_build_btn.text = "Build Bridge (Click 2 Points)"
	b_build_btn.pressed.connect(_start_2point_bridge)
	parent.add_child(b_build_btn)

	var bw_row := HBoxContainer.new()
	parent.add_child(bw_row)
	var bw_lbl := Label.new()
	bw_lbl.text = "Bridge Width"
	bw_lbl.custom_minimum_size = Vector2(120, 0)
	bw_row.add_child(bw_lbl)
	var bw_sb := SpinBox.new()
	bw_sb.min_value = 8.0
	bw_sb.max_value = 60.0
	bw_sb.step = 2.0
	bw_sb.value = _bridge_width
	bw_sb.value_changed.connect(func(v: float): _bridge_width = v)
	bw_row.add_child(bw_sb)

	_bridges_list = ItemList.new()
	_bridges_list.custom_minimum_size = Vector2(0, 100)
	_bridges_list.item_selected.connect(func(idx: int):
		_selected_bridge = idx
		_refresh_bridges_ui())
	parent.add_child(_bridges_list)

	_bridge_props = VBoxContainer.new()
	_bridge_props.add_theme_constant_override("separation", Tokens.SPACE_XS)
	parent.add_child(_bridge_props)
	_refresh_bridges_ui()

	# === 2. 2-POINT ROADS ===
	var r_sep := HSeparator.new()
	parent.add_child(r_sep)

	var r_head := Label.new()
	r_head.text = "2-Point Roads & Paths:"
	r_head.theme_type_variation = "HeadingLabel"
	parent.add_child(r_head)

	var r_build_btn := Button.new()
	r_build_btn.text = "Build Road (Click 2 Points / Chain)"
	r_build_btn.pressed.connect(_start_2point_road)
	parent.add_child(r_build_btn)

	var rw_row := HBoxContainer.new()
	parent.add_child(rw_row)
	var rw_lbl := Label.new()
	rw_lbl.text = "Road Width"
	rw_lbl.custom_minimum_size = Vector2(120, 0)
	rw_row.add_child(rw_lbl)
	var rw_sb := SpinBox.new()
	rw_sb.min_value = 6.0
	rw_sb.max_value = 50.0
	rw_sb.step = 2.0
	rw_sb.value = _road_width
	rw_sb.value_changed.connect(func(v: float): _road_width = v)
	rw_row.add_child(rw_sb)

	var rsurf_row := HBoxContainer.new()
	parent.add_child(rsurf_row)
	var rs_lbl := Label.new()
	rs_lbl.text = "Road Surface"
	rs_lbl.custom_minimum_size = Vector2(120, 0)
	rsurf_row.add_child(rs_lbl)
	var rs_opt := OptionButton.new()
	rs_opt.add_item("Dirt / Mud Trail")
	rs_opt.add_item("Gravel / Pavement")
	rs_opt.add_item("Sand Track")
	var surf_keys := ["dirt", "gravel", "sand"]
	rs_opt.item_selected.connect(func(idx: int): _road_surface = surf_keys[idx])
	rsurf_row.add_child(rs_opt)


func _refresh_bridges_ui() -> void:
	if _bridges_list == null:
		return
	_bridges_list.clear()
	var b_list: Array = _map.get("bridges", [])
	for i in range(b_list.size()):
		var b: Dictionary = b_list[i]
		var c = b.get("center", [0, 0, 0])
		var he = b.get("half_extents", [10, 10])
		_bridges_list.add_item("Bridge #%d: (%.0f, %.0f) - Span %.0fm" % [i + 1, float(c[0]), float(c[2]), float(he[1]) * 2.0])

	if _selected_bridge >= 0 and _selected_bridge < b_list.size():
		_bridges_list.select(_selected_bridge)

	if _bridge_props != null:
		for c in _bridge_props.get_children():
			c.queue_free()
		if _selected_bridge >= 0 and _selected_bridge < b_list.size():
			var del_btn := Button.new()
			del_btn.text = "Delete Selected Bridge"
			del_btn.pressed.connect(func():
				_push_undo()
				b_list.remove_at(_selected_bridge)
				_selected_bridge = mini(_selected_bridge, b_list.size() - 1)
				_refresh_bridges_in_scene()
				_refresh_bridges_ui()
				_dirty = true
				_set_status("Deleted Bridge.", Tokens.SIGNAL_ALERT))
			_bridge_props.add_child(del_btn)


func _build_greebles_tab(parent: VBoxContainer) -> void:
	var g_head := Label.new()
	g_head.text = "Direct Tree & Rock Greeble Painting:"
	g_head.theme_type_variation = "HeadingLabel"
	parent.add_child(g_head)

	var g_grid := GridContainer.new()
	g_grid.columns = 2
	g_grid.add_theme_constant_override("h_separation", Tokens.SPACE_XS)
	g_grid.add_theme_constant_override("v_separation", Tokens.SPACE_XS)
	parent.add_child(g_grid)

	var g_tools := [
		{"name": "🌲 Paint Trees", "tool": GreebleType.TREE, "col": Color(0.2, 0.85, 0.3)},
		{"name": "🪨 Paint Boulders", "tool": GreebleType.BOULDER, "col": Color(0.8, 0.75, 0.7)},
		{"name": "⛰️ Paint Rock Spires", "tool": GreebleType.SPIRE, "col": Color(0.65, 0.6, 0.55)},
		{"name": "🌿 Paint Shrubs", "tool": GreebleType.SHRUB, "col": Color(0.5, 0.8, 0.2)},
		{"name": "🧹 Eraser Brush", "tool": GreebleType.ERASER, "col": Color(1.0, 0.25, 0.25)},
	]
	for gt in g_tools:
		var b := Button.new()
		b.text = gt["name"]
		b.pressed.connect(func():
			_greeble_tool = gt["tool"]
			_set_status("Active Greeble Brush: %s" % gt["name"], gt["col"]))
		g_grid.add_child(b)

	var rad_row := HBoxContainer.new()
	parent.add_child(rad_row)
	var r_lbl := Label.new()
	r_lbl.text = "Brush Radius"
	r_lbl.custom_minimum_size = Vector2(120, 0)
	rad_row.add_child(r_lbl)
	var r_sb := SpinBox.new()
	r_sb.min_value = 5.0
	r_sb.max_value = 200.0
	r_sb.step = 5.0
	r_sb.value = _greeble_radius
	r_sb.value_changed.connect(func(v: float):
		_greeble_radius = v
		_update_cursor_ring_mesh(_greeble_radius))
	rad_row.add_child(r_sb)

	var den_row := HBoxContainer.new()
	parent.add_child(den_row)
	var d_lbl := Label.new()
	d_lbl.text = "Scatter Density"
	d_lbl.custom_minimum_size = Vector2(120, 0)
	den_row.add_child(d_lbl)
	var d_sb := SpinBox.new()
	d_sb.min_value = 0.1
	d_sb.max_value = 2.0
	d_sb.step = 0.05
	d_sb.value = _greeble_density
	d_sb.value_changed.connect(func(v: float): _greeble_density = v)
	den_row.add_child(d_sb)

	# --- PROP PLACEMENT SCALE CONTROLS ---
	var s_head := Label.new()
	s_head.text = "Prop Placement Scale (Use - / + keys):"
	s_head.theme_type_variation = "SubheadingLabel"
	parent.add_child(s_head)

	var smin_row := HBoxContainer.new()
	parent.add_child(smin_row)
	var smin_lbl := Label.new()
	smin_lbl.text = "Min Scale"
	smin_lbl.custom_minimum_size = Vector2(120, 0)
	smin_row.add_child(smin_lbl)
	var smin_sb := SpinBox.new()
	smin_sb.min_value = 0.2
	smin_sb.max_value = 25.0
	smin_sb.step = 0.1
	smin_sb.value = _greeble_scale_min
	smin_sb.value_changed.connect(func(v: float): _greeble_scale_min = v)
	smin_row.add_child(smin_sb)

	var smax_row := HBoxContainer.new()
	parent.add_child(smax_row)
	var smax_lbl := Label.new()
	smax_lbl.text = "Max Scale"
	smax_lbl.custom_minimum_size = Vector2(120, 0)
	smax_row.add_child(smax_lbl)
	var smax_sb := SpinBox.new()
	smax_sb.min_value = 0.2
	smax_sb.max_value = 25.0
	smax_sb.step = 0.1
	smax_sb.value = _greeble_scale_max
	smax_sb.value_changed.connect(func(v: float): _greeble_scale_max = v)
	smax_row.add_child(smax_sb)

	# Quick presets row
	var preset_row := HBoxContainer.new()
	preset_row.add_theme_constant_override("separation", Tokens.SPACE_XS)
	parent.add_child(preset_row)
	var presets := [
		{"label": "Tiny (0.8x)", "min": 0.6, "max": 1.0},
		{"label": "Standard (2x)", "min": 1.6, "max": 2.8},
		{"label": "Large (5x)", "min": 3.8, "max": 6.2},
		{"label": "Colossal (12x)", "min": 9.0, "max": 15.0},
	]
	for pr in presets:
		var pb := Button.new()
		pb.text = pr["label"]
		pb.pressed.connect(func():
			_greeble_scale_min = pr["min"]
			_greeble_scale_max = pr["max"]
			smin_sb.value = _greeble_scale_min
			smax_sb.value = _greeble_scale_max
			_set_status("Selected Prop Scale: %.1fx - %.1fx" % [_greeble_scale_min, _greeble_scale_max], Tokens.SIGNAL_GO))
		preset_row.add_child(pb)

	var single_check := CheckBox.new()
	single_check.text = "Single Prop Click (1 per click)"
	single_check.toggled.connect(func(t: bool): _greeble_single_click = t)
	parent.add_child(single_check)

	# --- SCALE EXISTING PLACED PROPS ---
	var scale_sep := HSeparator.new()
	parent.add_child(scale_sep)

	var ex_head := Label.new()
	ex_head.text = "Scale Existing Placed Props:"
	ex_head.theme_type_variation = "SubheadingLabel"
	parent.add_child(ex_head)

	var rock_scale_grid := GridContainer.new()
	rock_scale_grid.columns = 2
	rock_scale_grid.add_theme_constant_override("h_separation", Tokens.SPACE_XS)
	rock_scale_grid.add_theme_constant_override("v_separation", Tokens.SPACE_XS)
	parent.add_child(rock_scale_grid)

	var rock_btn_p25 := Button.new()
	rock_btn_p25.text = "🪨 Enlarge Rocks (+25%)"
	rock_btn_p25.pressed.connect(func(): _scale_rock_props(1.25))
	rock_scale_grid.add_child(rock_btn_p25)

	var rock_btn_m25 := Button.new()
	rock_btn_m25.text = "🪨 Shrink Rocks (-25%)"
	rock_btn_m25.pressed.connect(func(): _scale_rock_props(0.80))
	rock_scale_grid.add_child(rock_btn_m25)

	var rock_btn_2x := Button.new()
	rock_btn_2x.text = "🪨 2.0x Giant Rocks"
	rock_btn_2x.pressed.connect(func(): _scale_rock_props(2.0))
	rock_scale_grid.add_child(rock_btn_2x)

	var rock_btn_half := Button.new()
	rock_btn_half.text = "🪨 0.5x Half Size"
	rock_btn_half.pressed.connect(func(): _scale_rock_props(0.5))
	rock_scale_grid.add_child(rock_btn_half)

	var all_scale_grid := GridContainer.new()
	all_scale_grid.columns = 2
	all_scale_grid.add_theme_constant_override("h_separation", Tokens.SPACE_XS)
	all_scale_grid.add_theme_constant_override("v_separation", Tokens.SPACE_XS)
	parent.add_child(all_scale_grid)

	var all_btn_p25 := Button.new()
	all_btn_p25.text = "🌐 Scale All (+25%)"
	all_btn_p25.pressed.connect(func(): _scale_all_props(1.25))
	all_scale_grid.add_child(all_btn_p25)

	var all_btn_m25 := Button.new()
	all_btn_m25.text = "🌐 Scale All (-25%)"
	all_btn_m25.pressed.connect(func(): _scale_all_props(0.80))
	all_scale_grid.add_child(all_btn_m25)

	var clear_btn := Button.new()
	clear_btn.text = "Clear All Authored Props"
	clear_btn.pressed.connect(func():
		_push_undo()
		_props_list = []
		_map["props"] = []
		_refresh_props_multimesh()
		_dirty = true
		_set_status("Cleared all authored props.", Tokens.SIGNAL_ALERT))
	parent.add_child(clear_btn)

	var prop_count_lbl := Label.new()
	prop_count_lbl.text = "Authored Props: %d" % _props_list.size()
	prop_count_lbl.theme_type_variation = "StatLabel"
	parent.add_child(prop_count_lbl)


func _build_features_tab(parent: VBoxContainer) -> void:
	var add_lbl := Label.new()
	add_lbl.text = "Add Shape Feature:"
	add_lbl.theme_type_variation = "HeadingLabel"
	parent.add_child(add_lbl)

	var add_grid := GridContainer.new()
	add_grid.columns = 3
	add_grid.add_theme_constant_override("h_separation", Tokens.SPACE_XS)
	add_grid.add_theme_constant_override("v_separation", Tokens.SPACE_XS)
	parent.add_child(add_grid)
	for t in FEATURE_TYPES:
		var b := Button.new()
		b.text = t.capitalize()
		b.pressed.connect(_add_feature.bind(t))
		add_grid.add_child(b)

	_feature_list = ItemList.new()
	_feature_list.custom_minimum_size = Vector2(0, 120)
	_feature_list.item_selected.connect(func(idx: int):
		_selected_feature = idx
		_refresh_feature_props()
		_refresh_handles())
	parent.add_child(_feature_list)

	var del := Button.new()
	del.text = "Delete Selected Shape"
	del.pressed.connect(_delete_selected_feature)
	parent.add_child(del)

	_feature_props = VBoxContainer.new()
	_feature_props.add_theme_constant_override("separation", Tokens.SPACE_XS)
	parent.add_child(_feature_props)
	_refresh_feature_props()


func _build_spawns_tab_content() -> void:
	if _spawns_container == null:
		return
	for c in _spawns_container.get_children():
		c.queue_free()

	_ensure_spawns_exist()
	var p_hq := _get_spawn_hq("player")
	var e_hq := _get_spawn_hq("enemy")
	var p_bz := _get_base_zone("player")
	var e_bz := _get_base_zone("enemy")

	# === 1. FRIENDLY SPAWN (PLAYER) ===
	var p_card := PanelContainer.new()
	_spawns_container.add_child(p_card)
	var p_box := VBoxContainer.new()
	p_box.add_theme_constant_override("separation", Tokens.SPACE_XS)
	p_card.add_child(p_box)

	var p_title := Label.new()
	p_title.text = "FRIENDLY SPAWN (PLAYER HQ)"
	p_title.add_theme_color_override("font_color", Color(0.3, 0.8, 1.0))
	p_title.theme_type_variation = "HeadingLabel"
	p_box.add_child(p_title)

	var p_btn := Button.new()
	p_btn.text = "Click to Place Friendly HQ on Map"
	p_btn.pressed.connect(func():
		_is_click_placing = true
		_click_place_type = "friendly_spawn"
		_set_status("Click anywhere on terrain to place Friendly Spawn (Player HQ)...", Color(0.3, 0.8, 1.0)))
	p_box.add_child(p_btn)

	var p_pos_row := HBoxContainer.new()
	p_box.add_child(p_pos_row)
	var p_lbl := Label.new()
	p_lbl.text = "Position (X, Z):"
	p_lbl.custom_minimum_size = Vector2(100, 0)
	p_lbl.theme_type_variation = "StatLabel"
	p_pos_row.add_child(p_lbl)
	var p_x_sb := SpinBox.new()
	p_x_sb.min_value = -2000.0
	p_x_sb.max_value = 2000.0
	p_x_sb.step = 1.0
	p_x_sb.value = p_hq.x
	p_x_sb.custom_minimum_size = Vector2(95, 0)
	p_x_sb.value_changed.connect(func(v: float):
		_push_undo()
		_set_spawn_hq_pos("player", Vector3(v, 0, p_hq.z)))
	p_pos_row.add_child(p_x_sb)
	var p_z_sb := SpinBox.new()
	p_z_sb.min_value = -2000.0
	p_z_sb.max_value = 2000.0
	p_z_sb.step = 1.0
	p_z_sb.value = p_hq.z
	p_z_sb.custom_minimum_size = Vector2(95, 0)
	p_z_sb.value_changed.connect(func(v: float):
		_push_undo()
		_set_spawn_hq_pos("player", Vector3(p_hq.x, 0, v)))
	p_pos_row.add_child(p_z_sb)

	var p_bz_row := HBoxContainer.new()
	p_box.add_child(p_bz_row)
	var p_bz_lbl := Label.new()
	p_bz_lbl.text = "Base Size:"
	p_bz_lbl.custom_minimum_size = Vector2(100, 0)
	p_bz_lbl.theme_type_variation = "StatLabel"
	p_bz_row.add_child(p_bz_lbl)
	var p_bz_sb := SpinBox.new()
	p_bz_sb.min_value = 10.0
	p_bz_sb.max_value = 120.0
	p_bz_sb.step = 2.5
	var p_he: Vector2 = _xz(p_bz.get("half_extents", [25.0, 25.0]))
	p_bz_sb.value = p_he.x
	p_bz_sb.value_changed.connect(func(v: float):
		_push_undo()
		p_bz["half_extents"] = [v, v]
		_refresh_spawn_markers()
		_mark_dirty())
	p_bz_row.add_child(p_bz_sb)

	# === 2. ENEMY SPAWN ===
	var e_card := PanelContainer.new()
	_spawns_container.add_child(e_card)
	var e_box := VBoxContainer.new()
	e_box.add_theme_constant_override("separation", Tokens.SPACE_XS)
	e_card.add_child(e_box)

	var e_title := Label.new()
	e_title.text = "ENEMY SPAWN (ENEMY HQ)"
	e_title.add_theme_color_override("font_color", Color(1.0, 0.4, 0.3))
	e_title.theme_type_variation = "HeadingLabel"
	e_box.add_child(e_title)

	var e_btn := Button.new()
	e_btn.text = "Click to Place Enemy HQ on Map"
	e_btn.pressed.connect(func():
		_is_click_placing = true
		_click_place_type = "enemy_spawn"
		_set_status("Click anywhere on terrain to place Enemy Spawn (Enemy HQ)...", Color(1.0, 0.4, 0.3)))
	e_box.add_child(e_btn)

	var e_pos_row := HBoxContainer.new()
	e_box.add_child(e_pos_row)
	var e_lbl := Label.new()
	e_lbl.text = "Position (X, Z):"
	e_lbl.custom_minimum_size = Vector2(100, 0)
	e_lbl.theme_type_variation = "StatLabel"
	e_pos_row.add_child(e_lbl)
	var e_x_sb := SpinBox.new()
	e_x_sb.min_value = -2000.0
	e_x_sb.max_value = 2000.0
	e_x_sb.step = 1.0
	e_x_sb.value = e_hq.x
	e_x_sb.custom_minimum_size = Vector2(95, 0)
	e_x_sb.value_changed.connect(func(v: float):
		_push_undo()
		_set_spawn_hq_pos("enemy", Vector3(v, 0, e_hq.z)))
	e_pos_row.add_child(e_x_sb)
	var e_z_sb := SpinBox.new()
	e_z_sb.min_value = -2000.0
	e_z_sb.max_value = 2000.0
	e_z_sb.step = 1.0
	e_z_sb.value = e_hq.z
	e_z_sb.custom_minimum_size = Vector2(95, 0)
	e_z_sb.value_changed.connect(func(v: float):
		_push_undo()
		_set_spawn_hq_pos("enemy", Vector3(e_hq.x, 0, v)))
	e_pos_row.add_child(e_z_sb)

	var e_bz_row := HBoxContainer.new()
	e_box.add_child(e_bz_row)
	var e_bz_lbl := Label.new()
	e_bz_lbl.text = "Base Size:"
	e_bz_lbl.custom_minimum_size = Vector2(100, 0)
	e_bz_lbl.theme_type_variation = "StatLabel"
	e_bz_row.add_child(e_bz_lbl)
	var e_bz_sb := SpinBox.new()
	e_bz_sb.min_value = 10.0
	e_bz_sb.max_value = 120.0
	e_bz_sb.step = 2.5
	var e_he: Vector2 = _xz(e_bz.get("half_extents", [25.0, 25.0]))
	e_bz_sb.value = e_he.x
	e_bz_sb.value_changed.connect(func(v: float):
		_push_undo()
		e_bz["half_extents"] = [v, v]
		_refresh_spawn_markers()
		_mark_dirty())
	e_bz_row.add_child(e_bz_sb)

	var sym_row := HBoxContainer.new()
	sym_row.add_theme_constant_override("separation", Tokens.SPACE_XS)
	e_box.add_child(sym_row)

	var sym_btn := Button.new()
	sym_btn.text = "Mirror Enemy Opposite (180°)"
	sym_btn.pressed.connect(func(): _symmetrize_enemy_opposite_player("rotational"))
	sym_row.add_child(sym_btn)

	# === 3. RESOURCE NODES ===
	var r_sep := HSeparator.new()
	_spawns_container.add_child(r_sep)

	var rhead := Label.new()
	rhead.text = "Add Resource Nodes:"
	rhead.theme_type_variation = "HeadingLabel"
	_spawns_container.add_child(rhead)

	var r_grid := GridContainer.new()
	r_grid.columns = 4
	r_grid.add_theme_constant_override("h_separation", Tokens.SPACE_XS)
	_spawns_container.add_child(r_grid)

	for rtype in ["metal", "crystal", "oil", "lumber"]:
		var b := Button.new()
		b.text = "+ %s" % rtype.capitalize()
		b.pressed.connect(func():
			_is_click_placing = true
			_click_place_type = "resource_%s" % rtype
			_set_status("Click on terrain to place %s node." % rtype.capitalize(), Tokens.SIGNAL_HAZARD))
		r_grid.add_child(b)

	var clear_r_btn := Button.new()
	clear_r_btn.text = "Clear All Resource Nodes"
	clear_r_btn.pressed.connect(func():
		_push_undo()
		_map["resource_nodes"] = []
		_refresh_spawn_markers()
		_mark_dirty())
	_spawns_container.add_child(clear_r_btn)


func _build_map_tab(parent: VBoxContainer) -> void:
	var head := Label.new()
	head.text = "Map Parameters:"
	head.theme_type_variation = "HeadingLabel"
	parent.add_child(head)

	var n_row := HBoxContainer.new()
	parent.add_child(n_row)
	var nl := Label.new()
	nl.text = "Name"
	nl.custom_minimum_size = Vector2(100, 0)
	n_row.add_child(nl)
	var ne := LineEdit.new()
	ne.text = str(_map.get("name", "Custom Map"))
	ne.custom_minimum_size = Vector2(200, 0)
	ne.text_changed.connect(func(t: String): _map["name"] = t)
	n_row.add_child(ne)

	var h_row := HBoxContainer.new()
	parent.add_child(h_row)
	var hl := Label.new()
	hl.text = "Half Extents"
	hl.custom_minimum_size = Vector2(100, 0)
	h_row.add_child(hl)
	var hsb := SpinBox.new()
	hsb.min_value = 100.0
	hsb.max_value = 2000.0
	hsb.step = 20.0
	hsb.value = float(_map.get("map_half_extents", 400.0))
	hsb.value_changed.connect(func(v: float):
		_push_undo()
		_map["map_half_extents"] = v
		_mark_dirty())
	h_row.add_child(hsb)

	# The map-wide water table. Default is negative (see
	# TerrainBuilder.WATER_LEVEL_DEFAULT); a positive one floods any map whose
	# terrain averages zero.
	var wt_row := HBoxContainer.new()
	parent.add_child(wt_row)
	var wt_lbl := Label.new()
	wt_lbl.text = "Water Table"
	wt_lbl.custom_minimum_size = Vector2(100, 0)
	wt_row.add_child(wt_lbl)
	var wt_sb := SpinBox.new()
	wt_sb.min_value = -80.0
	wt_sb.max_value = 40.0
	wt_sb.step = 0.5
	wt_sb.value = TerrainBuilderScript.water_level_of(_map)
	wt_sb.tooltip_text = "Height of the map-wide water plane. Painted lakes are independent of this and can sit above it."
	wt_sb.value_changed.connect(func(v: float):
		_push_undo()
		_map["water_level"] = v
		if _water_node != null:
			_water_node.position.y = v
		_mark_dirty())
	wt_row.add_child(wt_sb)

	var theme_lbl := Label.new()
	theme_lbl.text = "Theme Palette Preset:"
	theme_lbl.theme_type_variation = "StatLabel"
	parent.add_child(theme_lbl)

	var th_opt := OptionButton.new()
	for k in THEME_PRESETS:
		th_opt.add_item(THEME_PRESETS[k]["name"])
	th_opt.item_selected.connect(func(idx: int):
		_push_undo()
		var keys := THEME_PRESETS.keys()
		var k: String = keys[idx]
		var col: Color = THEME_PRESETS[k]["ground_color"]
		_map["ground_color"] = [col.r, col.g, col.b]
		_mark_dirty())
	parent.add_child(th_opt)


func _set_status(text: String, colour: Color) -> void:
	if _status == null:
		return
	_status.text = text
	_status.add_theme_color_override("font_color", colour)
