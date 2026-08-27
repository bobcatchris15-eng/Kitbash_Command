extends Node3D
class_name TerrainSculpt
# In-engine terrain authoring for v2 maps.
#
# WHY THIS EXISTS
# ---------------
# Maps were authored by typing coordinates into JSON and finding out what they
# looked like by starting a match. That is authoring blind, and it hid a real
# defect for a long time: the ground mesh could not draw a wall narrower than
# one quad, so a canyon that was correct in the heightmap AND correct to
# pathfinding rendered as a smooth dune, and 1472 prop cliffs were stamped
# along the wall lines to fake what the mesh would not draw. Nobody could see
# that from a JSON file.
#
# So this previews with the REAL height function and the REAL v2 material. What
# you place is what loads.
#
# SHAPES FIRST, BRUSHES LATER. This edits terrain.features[] - the plateau /
# canyon / ridge / ramp / hill / lake vocabulary the runtime already
# understands - by placing and sizing them in the 3D view. Freehand
# heightfield brushes are the intended follow-up and will write to the same
# baked heightmap; the feature list stays useful either way because features
# are what the navmesh emission and the auto-dressing rules read.
#
# THE PREVIEW IS ANALYTIC ON PURPOSE. height_at() returns from the baked
# heightmap PNG when a map declares one, which would make edits invisible
# until the Python bake re-ran. The tool therefore works on a copy of the map
# with terrain.heightmap removed, so features evaluate live. build_terrain.py
# composes features with the same max/min rule (see _v2_feature_height), so
# the preview and the bake agree.

const TerrainBuilderScript = preload("res://scripts/terrain_builder.gd")
const MapCatalogScript = preload("res://scripts/map_catalog.gd")
const Tokens = preload("res://scripts/ui_tokens.gd")

# Preview grid resolution. Deliberately NOT build_ground_visual_mesh(): that
# walks the shipped 280-division grid with adaptive subdivision and takes
# ~1.7 s on a 1920 m map, which is far too slow to sit behind a slider. This
# is a fixed grid the tool controls, rebuilt in well under a frame budget.
const PREVIEW_DIVS := 190
# The full builder, on demand, for a faithful look before saving.
const FULL_PREVIEW_LABEL := "Full-quality preview"

const FEATURE_TYPES := ["plateau", "canyon", "ridge", "ramp", "hill", "lake"]

# Per-type defaults, in world units, sized for a ~960 half-extent map. These
# are starting points a drag then adjusts - not constraints.
const FEATURE_DEFAULTS := {
	"plateau": {"half_extents": [180.0, 140.0], "height": 22.0, "wall_falloff": 6.0},
	"canyon": {"width": 130.0, "depth": 26.0, "wall_falloff": 8.0, "length": 400.0},
	"ridge": {"width": 90.0, "height": 18.0, "falloff": 46.0, "length": 300.0},
	"ramp": {"width": 84.0, "length": 70.0, "top_height": 22.0, "direction_deg": 0.0},
	"hill": {"radius": 150.0, "height": 26.0, "falloff": 90.0},
	"lake": {"radius": 130.0, "depth": 12.0, "shoreline_falloff": 40.0},
}

var map_id: String = ""
var _map: Dictionary = {}          # working copy, heightmap stripped
var _selected: int = -1
var _dirty: bool = false

var _ground: MeshInstance3D = null
var _handles: Node3D = null
var _cam_pivot: Node3D = null
var _cam: Camera3D = null
var _cam_dist: float = 900.0
var _cam_yaw: float = 0.6
var _cam_pitch: float = -0.62

var _ui: Control = null
var _list: ItemList = null
var _props: VBoxContainer = null
var _status: Label = null
var _rebuild_queued: bool = false


func _ready() -> void:
	name = "TerrainSculpt"
	_build_world()
	_build_ui()
	var want := map_id if map_id != "" else _first_v2_map()
	if want != "":
		load_map(want)
	else:
		_set_status("No v2 map found. Use New Map to start one.", Tokens.SIGNAL_HAZARD)


static func _first_v2_map() -> String:
	for mid in MapCatalogScript.get_map_ids():
		if TerrainBuilderScript.terrain_generator(MapCatalogScript.get_map(mid)) == "v2":
			return str(mid)
	return ""


# --- world ------------------------------------------------------------------

func _build_world() -> void:
	var env := WorldEnvironment.new()
	var e := Environment.new()
	e.background_mode = Environment.BG_SKY
	var sky := Sky.new()
	var sm := ProceduralSkyMaterial.new()
	sm.sky_top_color = Color(0.20, 0.26, 0.36)
	sm.sky_horizon_color = Color(0.42, 0.45, 0.48)
	sm.ground_horizon_color = Color(0.30, 0.30, 0.30)
	sm.ground_bottom_color = Color(0.16, 0.16, 0.16)
	sky.sky_material = sm
	e.sky = sky
	e.tonemap_mode = Environment.TONE_MAPPER_AGX
	# Brighter than a match on purpose. This is a workbench: the point is to
	# see the SHAPE clearly, not to evaluate the map's mood - and judging a
	# silhouette through a night palette is how the cliff problem stayed
	# invisible for so long. Use the capture tool to judge lighting.
	e.tonemap_exposure = 2.0
	e.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	e.ambient_light_color = Color(0.52, 0.52, 0.50)
	e.ambient_light_energy = 0.9
	e.ssao_enabled = true
	e.ssao_radius = 2.0
	env.environment = e
	add_child(env)

	var sun := DirectionalLight3D.new()
	sun.light_energy = 1.9
	sun.rotation_degrees = Vector3(-52.0, 34.0, 0.0)
	sun.shadow_enabled = true
	sun.directional_shadow_max_distance = 2600.0
	add_child(sun)

	_ground = MeshInstance3D.new()
	_ground.name = "Ground"
	add_child(_ground)

	_handles = Node3D.new()
	_handles.name = "Handles"
	add_child(_handles)

	_cam_pivot = Node3D.new()
	add_child(_cam_pivot)
	_cam = Camera3D.new()
	_cam.fov = 50.0
	_cam.far = 12000.0
	_cam_pivot.add_child(_cam)
	_update_camera()


func _update_camera() -> void:
	if _cam == null:
		return
	# _cam_pitch is NEGATIVE for looking down, so the camera's height above the
	# pivot is -sin(pitch). Getting this sign wrong puts the camera under the
	# terrain, which looks like a black screen rather than like a bug.
	var dir := Vector3(
		cos(_cam_pitch) * sin(_cam_yaw),
		-sin(_cam_pitch),
		cos(_cam_pitch) * cos(_cam_yaw))
	_cam.position = dir.normalized() * _cam_dist
	if _cam.is_inside_tree() and _cam_pivot != null:
		# Look at the PIVOT, not the origin: the pivot is what middle-drag pans,
		# and aiming at the origin would swing the view back every pan.
		_cam.look_at(_cam_pivot.global_position, Vector3.UP)


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		if event.button_index == MOUSE_BUTTON_WHEEL_UP and event.pressed:
			_cam_dist = maxf(60.0, _cam_dist * 0.9)
			_update_camera()
		elif event.button_index == MOUSE_BUTTON_WHEEL_DOWN and event.pressed:
			_cam_dist = minf(6000.0, _cam_dist * 1.1)
			_update_camera()
		elif event.button_index == MOUSE_BUTTON_LEFT and event.pressed:
			_click_terrain(event.position)
	elif event is InputEventMouseMotion and (event.button_mask & MOUSE_BUTTON_MASK_RIGHT):
		_cam_yaw -= event.relative.x * 0.006
		_cam_pitch = clampf(_cam_pitch - event.relative.y * 0.005, -1.45, -0.08)
		_update_camera()
	elif event is InputEventMouseMotion and (event.button_mask & MOUSE_BUTTON_MASK_MIDDLE):
		var right := _cam.global_transform.basis.x
		var fwd := Vector3(right.z, 0.0, -right.x)
		_cam_pivot.position -= (right * event.relative.x + fwd * -event.relative.y) * (_cam_dist * 0.0016)


# Ray from the cursor onto the terrain, by marching against height_at(). No
# collider is built for the preview mesh, and a HeightMapShape3D would have to
# be rebuilt on every edit; marching is cheap and always agrees with what is
# drawn because it asks the same function.
func _click_terrain(screen_pos: Vector2) -> void:
	if _map.is_empty() or _cam == null:
		return
	var from := _cam.project_ray_origin(screen_pos)
	var dir := _cam.project_ray_normal(screen_pos)
	# Untyped: _raymarch returns Vector3 or null, which GDScript cannot infer.
	var hit = _raymarch(from, dir)
	if hit == null:
		return
	if _selected < 0:
		return
	_move_selected_to(hit)


func _raymarch(from: Vector3, dir: Vector3):
	var half: float = float(_map.get("map_half_extents", 960.0))
	var t := 0.0
	var max_t := _cam_dist * 4.0 + half * 3.0
	var step := maxf(2.0, half / 240.0)
	var prev_above := true
	while t < max_t:
		var p := from + dir * t
		if absf(p.x) <= half * 1.6 and absf(p.z) <= half * 1.6:
			var h: float = TerrainBuilderScript.height_at(_map, p.x, p.z)
			var above := p.y > h
			if not above and prev_above:
				return Vector3(p.x, h, p.z)
			prev_above = above
		t += step
	return null


# --- map ---------------------------------------------------------------------

func load_map(mid: String) -> void:
	var src: Dictionary = MapCatalogScript.get_map(mid)
	if src.is_empty():
		_set_status("Could not load '%s'." % mid, Tokens.SIGNAL_ALERT)
		return
	map_id = mid
	_map = src.duplicate(true)
	# Strip the baked raster so features evaluate live - see the header.
	var terr: Dictionary = _map.get("terrain", {})
	terr.erase("heightmap")
	terr.erase("surfacemap")
	if not terr.has("generator"):
		terr["generator"] = "v2"
	_map["terrain"] = terr
	_selected = -1
	_dirty = false
	_cam_dist = float(_map.get("map_half_extents", 960.0)) * 1.5
	_update_camera()
	_refresh_list()
	_rebuild_preview()
	_set_status("Loaded %s - %d features." % [mid, _features().size()], Tokens.TEXT_SECONDARY)


func _features() -> Array:
	var terr = _map.get("terrain", {})
	if typeof(terr) != TYPE_DICTIONARY:
		return []
	return terr.get("features", [])


func _mark_dirty() -> void:
	_dirty = true
	if not _rebuild_queued:
		_rebuild_queued = true
		# Coalesce: dragging a slider fires many changes per frame and each
		# rebuild walks the whole grid.
		call_deferred("_flush_rebuild")


func _flush_rebuild() -> void:
	_rebuild_queued = false
	_rebuild_preview()
	_refresh_handles()


# --- preview mesh ------------------------------------------------------------

func _rebuild_preview(full: bool = false) -> void:
	if _map.is_empty():
		return
	var t0 := Time.get_ticks_msec()
	if full:
		var generated: Dictionary = await TerrainBuilderScript.build_ground_visual_mesh(_map, null)
		_ground.mesh = generated.mesh
	else:
		_ground.mesh = _preview_mesh()
	if _ground.material_override == null:
		_ground.material_override = TerrainBuilderScript.build_ground_material_for(
			_map.get("ground_color", Color(0.3, 0.34, 0.28)), _map, map_id)
	_set_status("%s rebuilt in %d ms" % ["Full mesh" if full else "Preview", Time.get_ticks_msec() - t0],
		Tokens.TEXT_SECONDARY)


func _preview_mesh() -> ArrayMesh:
	var half: float = float(_map.get("map_half_extents", 960.0))
	var n := PREVIEW_DIVS
	var step := (half * 2.0) / float(n)
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var heights := PackedFloat32Array()
	heights.resize((n + 1) * (n + 1))
	for i in range(n + 1):
		var x := -half + step * float(i)
		for j in range(n + 1):
			var z := -half + step * float(j)
			heights[i * (n + 1) + j] = TerrainBuilderScript.height_at(_map, x, z)
	for i in range(n):
		for j in range(n):
			var x0 := -half + step * float(i)
			var x1 := x0 + step
			var z0 := -half + step * float(j)
			var z1 := z0 + step
			var a := Vector3(x0, heights[i * (n + 1) + j], z0)
			var b := Vector3(x1, heights[(i + 1) * (n + 1) + j], z0)
			var c := Vector3(x1, heights[(i + 1) * (n + 1) + j + 1], z1)
			var d := Vector3(x0, heights[i * (n + 1) + j + 1], z1)
			for v in [a, b, c, a, c, d]:
				st.set_uv(Vector2(v.x, v.z))
				st.add_vertex(v)
	st.generate_normals()
	return st.commit()


# --- feature geometry --------------------------------------------------------
#
# Each feature type carries its position differently - plateau/hill/lake have a
# `center`, ramp has an `anchor`, canyon has `start`/`end`, ridge has a
# `points` polyline. These two functions are the only place that has to be
# known, so the UI and the drag handles can treat every feature the same.

static func _xz(v) -> Vector2:
	var p: Vector3 = TerrainBuilderScript._vec3_of(v)
	return Vector2(p.x, p.z)


static func _pt(v: Vector2) -> Array:
	# 2-element [x, z]. Both the GDScript decoder and build_terrain.py accept
	# this shape; the 3-element form is accepted too, but only this one is
	# unambiguous across both.
	return [snappedf(v.x, 0.1), snappedf(v.y, 0.1)]


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
	if _selected < 0 or _selected >= feats.size():
		return
	_set_feature_centre(feats[_selected], Vector2(hit.x, hit.z))
	_mark_dirty()
	_refresh_props()


# --- feature list / properties ----------------------------------------------

func _add_feature(type_name: String) -> void:
	if _map.is_empty():
		return
	var f := {"type": type_name}
	for k in FEATURE_DEFAULTS.get(type_name, {}):
		f[k] = FEATURE_DEFAULTS[type_name][k]
	# Seed the shape at the camera pivot so a new feature appears where the
	# author is looking, not at the origin.
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
	_selected = feats.size() - 1
	_refresh_list()
	_mark_dirty()
	_refresh_props()


func _delete_selected() -> void:
	var feats := _features()
	if _selected < 0 or _selected >= feats.size():
		return
	feats.remove_at(_selected)
	_selected = mini(_selected, feats.size() - 1)
	_refresh_list()
	_mark_dirty()
	_refresh_props()


func _feature_label(f: Dictionary, i: int) -> String:
	var c := _feature_centre(f)
	return "%d  %s  (%.0f, %.0f)" % [i + 1, str(f.get("type", "?")), c.x, c.y]


func _refresh_list() -> void:
	if _list == null:
		return
	_list.clear()
	var feats := _features()
	for i in range(feats.size()):
		_list.add_item(_feature_label(feats[i], i))
	if _selected >= 0 and _selected < feats.size():
		_list.select(_selected)


func _refresh_props() -> void:
	if _props == null:
		return
	for c in _props.get_children():
		c.queue_free()
	var feats := _features()
	if _selected < 0 or _selected >= feats.size():
		var hint := Label.new()
		hint.text = "Select or add a feature."
		hint.theme_type_variation = "HintLabel"
		_props.add_child(hint)
		return
	var f: Dictionary = feats[_selected]

	var head := Label.new()
	head.text = str(f.get("type", "?")).to_upper()
	head.theme_type_variation = "HeadingLabel"
	_props.add_child(head)

	var pos := Label.new()
	var c := _feature_centre(f)
	pos.text = "centre (%.0f, %.0f) - left-click the terrain to move" % [c.x, c.y]
	pos.theme_type_variation = "StatLabel"
	_props.add_child(pos)

	# Every numeric scalar on the feature gets a spinbox. Driven off the dict
	# rather than a per-type form, so a feature key added to terrain_builder
	# shows up here without this file changing.
	for key in f.keys():
		var v = f[key]
		if typeof(v) == TYPE_FLOAT or typeof(v) == TYPE_INT:
			_props.add_child(_spin_row(str(key), float(v), key))
		elif typeof(v) == TYPE_ARRAY and str(key) == "half_extents" and v.size() >= 2:
			_props.add_child(_spin_row("half_extents.x", float(v[0]), "half_extents.x"))
			_props.add_child(_spin_row("half_extents.z", float(v[1]), "half_extents.z"))


func _spin_row(label_text: String, value: float, key: String) -> HBoxContainer:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", Tokens.SPACE_SM)
	var l := Label.new()
	l.text = label_text
	l.custom_minimum_size = Vector2(140, 0)
	l.theme_type_variation = "StatLabel"
	row.add_child(l)
	var sb := SpinBox.new()
	sb.min_value = -4000.0
	sb.max_value = 4000.0
	sb.step = 0.5
	sb.value = value
	sb.custom_minimum_size = Vector2(112, 0)
	sb.value_changed.connect(_on_prop_changed.bind(key))
	row.add_child(sb)
	return row


func _on_prop_changed(new_value: float, key: String) -> void:
	var feats := _features()
	if _selected < 0 or _selected >= feats.size():
		return
	var f: Dictionary = feats[_selected]
	if key == "half_extents.x":
		var he: Array = f.get("half_extents", [10.0, 10.0])
		f["half_extents"] = [new_value, float(he[1])]
	elif key == "half_extents.z":
		var he2: Array = f.get("half_extents", [10.0, 10.0])
		f["half_extents"] = [float(he2[0]), new_value]
	else:
		f[key] = new_value
	_mark_dirty()
	_refresh_list()


# --- handles -----------------------------------------------------------------

func _refresh_handles() -> void:
	if _handles == null or _map.is_empty():
		return
	for c in _handles.get_children():
		c.queue_free()
	var feats := _features()
	var r: float = float(_map.get("map_half_extents", 960.0)) * 0.012
	for i in range(feats.size()):
		var f: Dictionary = feats[i]
		var c := _feature_centre(f)
		var m := MeshInstance3D.new()
		var sphere := SphereMesh.new()
		sphere.radius = r
		sphere.height = r * 2.0
		m.mesh = sphere
		var mat := StandardMaterial3D.new()
		mat.albedo_color = Tokens.SIGNAL_HAZARD if i == _selected else Tokens.TEXT_SECONDARY
		mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		# Drawn on top: a handle sunk inside a plateau is unreachable otherwise.
		mat.no_depth_test = true
		m.material_override = mat
		m.position = Vector3(c.x, TerrainBuilderScript.height_at(_map, c.x, c.y) + r * 2.0, c.y)
		_handles.add_child(m)


# --- UI ----------------------------------------------------------------------

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
	panel.custom_minimum_size = Vector2(330, 0)
	panel.mouse_filter = Control.MOUSE_FILTER_STOP
	_ui.add_child(panel)

	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", Tokens.SPACE_SM)
	panel.add_child(col)

	var title := Label.new()
	title.text = "TERRAIN SCULPT"
	title.theme_type_variation = "TitleLabel"
	col.add_child(title)

	var map_row := HBoxContainer.new()
	map_row.add_theme_constant_override("separation", Tokens.SPACE_SM)
	col.add_child(map_row)
	var map_lbl := Label.new()
	map_lbl.text = "Map"
	map_lbl.theme_type_variation = "StatLabel"
	map_row.add_child(map_lbl)
	var map_btn := OptionButton.new()
	var v2_ids: Array = []
	for mid in MapCatalogScript.get_map_ids():
		if TerrainBuilderScript.terrain_generator(MapCatalogScript.get_map(mid)) == "v2":
			v2_ids.append(str(mid))
			map_btn.add_item(str(mid))
	map_btn.item_selected.connect(func(idx: int):
		if idx >= 0 and idx < v2_ids.size():
			load_map(str(v2_ids[idx])))
	map_row.add_child(map_btn)

	var add_lbl := Label.new()
	add_lbl.text = "Add feature"
	add_lbl.theme_type_variation = "HeadingLabel"
	col.add_child(add_lbl)
	var add_grid := GridContainer.new()
	add_grid.columns = 3
	add_grid.add_theme_constant_override("h_separation", Tokens.SPACE_XS)
	add_grid.add_theme_constant_override("v_separation", Tokens.SPACE_XS)
	col.add_child(add_grid)
	for t in FEATURE_TYPES:
		var b := Button.new()
		b.text = t
		b.pressed.connect(_add_feature.bind(t))
		add_grid.add_child(b)

	_list = ItemList.new()
	_list.custom_minimum_size = Vector2(0, 260)
	_list.item_selected.connect(func(idx: int):
		_selected = idx
		_refresh_props()
		_refresh_handles())
	col.add_child(_list)

	var del := Button.new()
	del.text = "Delete selected"
	del.pressed.connect(_delete_selected)
	col.add_child(del)

	var sep := HSeparator.new()
	col.add_child(sep)

	_props = VBoxContainer.new()
	_props.add_theme_constant_override("separation", Tokens.SPACE_XS)
	col.add_child(_props)

	var sep2 := HSeparator.new()
	col.add_child(sep2)

	var full_btn := Button.new()
	full_btn.text = FULL_PREVIEW_LABEL
	full_btn.pressed.connect(func(): _rebuild_preview(true))
	col.add_child(full_btn)

	var save_btn := Button.new()
	save_btn.text = "Save map JSON"
	save_btn.pressed.connect(_save)
	col.add_child(save_btn)

	_status = Label.new()
	_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_status.custom_minimum_size = Vector2(300, 0)
	_status.theme_type_variation = "StatLabel"
	col.add_child(_status)

	var help := Label.new()
	help.text = "LMB terrain: move selected  |  RMB drag: orbit  |  MMB drag: pan  |  wheel: zoom"
	help.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	help.custom_minimum_size = Vector2(300, 0)
	help.theme_type_variation = "HintLabel"
	col.add_child(help)

	_refresh_props()


# --- save --------------------------------------------------------------------

func _save() -> void:
	if _map.is_empty() or map_id == "":
		return
	var path := "res://data/maps/%s.json" % map_id
	# Restore the baked-raster references the editing copy strips. They are
	# what the SHIPPED map uses; the tool only hides them so features stay
	# live while editing.
	var out: Dictionary = _map.duplicate(true)
	var terr: Dictionary = out.get("terrain", {})
	terr["heightmap"] = "res://data/maps/%s_height.png" % map_id
	terr["surfacemap"] = "res://data/maps/%s_surface.png" % map_id
	out["terrain"] = terr
	# world_scale 1.0 means "these coordinates are final". terrain.features is
	# NOT in FIELD_SPEC's scale table, so on a map that lets world_scale
	# default to 4.0 every other field is multiplied and the features are left
	# behind - see world_scale.gd.
	if not out.has("world_scale"):
		out["world_scale"] = 1.0

	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		_set_status("Could not write %s" % path, Tokens.SIGNAL_ALERT)
		return
	f.store_string(JSON.stringify(out, "  "))
	f.close()
	_dirty = false
	_set_status("Saved. Re-bake: python tools/terrain/build_terrain.py data/maps/%s.json" % map_id,
		Tokens.SIGNAL_GO)
	print("[sculpt] saved %s" % path)
	print("[sculpt] re-bake:  python tools/terrain/build_terrain.py data/maps/%s.json" % map_id)
	print("[sculpt] reimport: Godot --headless --path . --editor --import")


func _set_status(text: String, colour: Color) -> void:
	if _status == null:
		return
	_status.text = text
	_status.add_theme_color_override("font_color", colour)
