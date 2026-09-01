extends SceneTree
# TERRAIN FILLRATE SWEEP
# ---------------------------------------------------------------------------
# Boots ONLY the ground mesh, its material and the grass carpet under a
# Battle-like environment, parks a camera at the RTS camera's real default
# height, and times four scene configurations back to back. The DIFFERENCES
# between them are the answer; no single number here is meaningful alone.
#
#   control   nothing but the sky
#   plain     ground mesh + a bare StandardMaterial3D
#   shaded    ground mesh + the real terrain material
#   full      shaded + the grass carpet
#
#   control -> plain   the mesh itself: vertex cost and terrain overdraw
#   plain   -> shaded  the terrain shader alone
#   shaded  -> full    the grass carpet
#
# WHY THERE IS A CONTROL PHASE. The first version of this probe had no empty
# baseline and reported ~270 ms for a scene holding one ground mesh, which
# might have been a real cost or might have been the measurement. Windows
# throttles an unfocused window's swapchain present, and a probe launched from
# a shell is unfocused by definition - the wall-clock version of this tool
# returned a dead-flat 133.33 ms (7.5 fps) for every configuration it was
# given. If `control` comes back at the same magnitude as the others, the
# instrument is measuring the throttle and every other row is noise. That is
# the first thing to read in the output.
#
# MUST run WITHOUT --headless: headless has no rendering device and every
# phase reports 0.0.
#
#   Godot_v4.7.1-stable_win64.exe --path prototype \
#     --script res://tools/probe_terrain_fillrate.gd -- --map delta_blues

const TerrainBuilderScript = preload("res://scripts/terrain_builder.gd")
const MapCatalogScript = preload("res://scripts/map_catalog.gd")

const WARMUP_FRAMES := 30
const SAMPLE_FRAMES := 60
# rts_camera.gd's `height` default and _apply_pitch()'s close-zoom angle. The
# original bug here was tuning terrain for a camera at 150 m that does not
# exist, so this probe hard-codes the pose the player actually starts at.
const CAMERA_HEIGHT := 26.0
const CAMERA_PITCH_DEG := -35.0

const PHASES := ["control", "plain", "shaded", "full"]

var _map_id := "delta_blues"
var _ground: MeshInstance3D = null
var _grass: Node3D = null
var _real_mat: Material = null
var _plain_mat: Material = null
var _cam: Camera3D = null

var _phase := 0
var _warming := true
var _left := WARMUP_FRAMES
var _gpu := 0.0
var _cpu := 0.0
var _wall := 0.0
var _n := 0
var _results: Array = []


func _arg(name: String, def: String) -> String:
	var a := OS.get_cmdline_user_args()
	for i in range(a.size()):
		if a[i] == name and i + 1 < a.size():
			return a[i + 1]
	return def


func _initialize() -> void:
	_map_id = _arg("--map", _map_id)
	var map_def: Dictionary = MapCatalogScript.get_map(_map_id)
	if map_def.is_empty():
		print("[FAIL] unknown map: ", _map_id)
		quit(1)
		return

	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
	Engine.max_fps = 0
	DisplayServer.window_set_size(Vector2i(1920, 1080))

	var world := Node3D.new()
	root.add_child(world)

	var env_data: Dictionary = map_def.get("environment", {})
	var we := WorldEnvironment.new()
	var env := Environment.new()
	env.background_mode = Environment.BG_SKY
	var sky := Sky.new()
	sky.sky_material = ProceduralSkyMaterial.new()
	env.sky = sky
	env.tonemap_mode = Environment.TONE_MAPPER_AGX
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color(0.45, 0.50, 0.55)
	env.ssao_enabled = true
	we.environment = env
	world.add_child(we)

	var sun := DirectionalLight3D.new()
	sun.shadow_enabled = true
	sun.directional_shadow_max_distance = 900.0
	sun.rotation_degrees = Vector3(
		-float(env_data.get("sun_elevation_deg", 39.0)),
		float(env_data.get("sun_azimuth_deg", 35.0)), 0.0)
	world.add_child(sun)

	var generated: Dictionary = await TerrainBuilderScript.build_ground_visual_mesh(map_def, null)
	_real_mat = TerrainBuilderScript.build_ground_material_for(
		map_def.get("ground_color", Color(0.2, 0.26, 0.21)), map_def, _map_id)
	var pm := StandardMaterial3D.new()
	pm.albedo_color = map_def.get("ground_color", Color(0.2, 0.26, 0.21))
	pm.roughness = 1.0
	_plain_mat = pm

	_ground = MeshInstance3D.new()
	_ground.mesh = generated.mesh
	_ground.material_override = _real_mat
	world.add_child(_ground)

	TerrainBuilderScript.build_grass_shells(map_def, world, _map_id)
	_grass = world.get_node_or_null("GrassShells")
	if _grass != null:
		# The zoom-cull script would drive `visible` underneath the probe and
		# turn the A/B into "hidden vs hidden". The probe owns visibility here.
		_grass.set_process(false)

	var ground_y: float = TerrainBuilderScript.height_at(map_def, 0.0, 0.0)
	_cam = Camera3D.new()
	_cam.far = 2000.0
	# Position AFTER add_child: global_position on a node outside the tree
	# returns identity and silently drops the write.
	world.add_child(_cam)
	_cam.rotation_degrees = Vector3(CAMERA_PITCH_DEG, 0.0, 0.0)
	_cam.position = Vector3(0.0, ground_y + CAMERA_HEIGHT, 0.0)
	_cam.current = true

	RenderingServer.viewport_set_measure_render_time(root.get_viewport_rid(), true)
	DisplayServer.window_move_to_foreground()

	print("[probe] map=%s  camera_height=%.0f m  viewport=1920x1080"
		% [_map_id, CAMERA_HEIGHT])
	print("[probe] window_focused=%s  (if the control row is not near zero, read the header of this file)"
		% [DisplayServer.window_is_focused()])
	_apply(0)


func _apply(phase: int) -> void:
	var pname: String = PHASES[phase]
	_ground.visible = pname != "control"
	_ground.material_override = _plain_mat if pname == "plain" else _real_mat
	if _grass != null:
		_grass.visible = pname == "full"


func _process(delta: float) -> bool:
	if _cam == null:
		return false
	if not _warming:
		var rid := root.get_viewport_rid()
		_gpu += RenderingServer.viewport_get_measured_render_time_gpu(rid)
		_cpu += RenderingServer.viewport_get_measured_render_time_cpu(rid)
		_wall += delta * 1000.0
		_n += 1
	_left -= 1
	if _left > 0:
		return false

	if _warming:
		_warming = false
		_left = SAMPLE_FRAMES
		_gpu = 0.0
		_cpu = 0.0
		_wall = 0.0
		_n = 0
		return false

	var d := float(maxi(_n, 1))
	_results.append({
		"name": PHASES[_phase],
		"gpu": _gpu / d,
		"cpu": _cpu / d,
		"wall": _wall / d,
		"objects": int(Performance.get_monitor(
			Performance.RENDER_TOTAL_OBJECTS_IN_FRAME)),
		"draws": int(Performance.get_monitor(
			Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME)),
	})
	_phase += 1
	if _phase >= PHASES.size():
		_report()
		return true
	_apply(_phase)
	_warming = true
	_left = WARMUP_FRAMES
	return false


func _report() -> void:
	print("")
	print("  %-9s %10s %10s %10s %9s %7s"
		% ["phase", "gpu ms", "cpu ms", "wall ms", "objects", "draws"])
	for r in _results:
		print("  %-9s %10.2f %10.2f %10.2f %9d %7d"
			% [r.name, r.gpu, r.cpu, r.wall, r.objects, r.draws])
	print("")
	var by := {}
	for r in _results:
		by[r.name] = r
	_delta_line("ground mesh   ", by, "control", "plain")
	_delta_line("terrain shader", by, "plain", "shaded")
	_delta_line("grass carpet  ", by, "shaded", "full")
	print("")
	if by.has("control") and by["control"].gpu > 20.0:
		print("  [WARN] control phase is %.1f ms GPU with an empty scene."
			% [by["control"].gpu])
		print("         The instrument is measuring something other than the scene - treat every row above as unusable.")
	print("")


func _delta_line(label: String, by: Dictionary, a: String, b: String) -> void:
	if not (by.has(a) and by.has(b)):
		return
	print("  %s : %+8.2f ms GPU  %+8.2f ms CPU  %+5d objects"
		% [label, by[b].gpu - by[a].gpu, by[b].cpu - by[a].cpu,
		   by[b].objects - by[a].objects])
