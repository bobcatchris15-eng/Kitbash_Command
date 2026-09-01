extends SceneTree
# Turntable render of ONE blueprint under a given livery, for judging material
# and paint-zone work on a specific design without booting a match.
#
#   Godot_v4.7.1-stable_win64.exe --path . \
#     --script res://tools/capture_design_look.gd -- \
#     --bp res://data/loadout/bulwark_mbt.json --livery industrialists --out abs.png

var _out := "design.png"
var _bp := "res://data/loadout/bulwark_mbt.json"
var _livery := "industrialists"
var _f := 0
var _armed := false

func _arg(n: String, d: String) -> String:
	var a := OS.get_cmdline_user_args()
	for i in range(a.size()):
		if a[i] == n and i + 1 < a.size():
			return a[i + 1]
	return d

func _initialize() -> void:
	_out = _arg("--out", _out)
	_bp = _arg("--bp", _bp)
	_livery = _arg("--livery", _livery)
	DisplayServer.window_set_size(Vector2i(1400, 900))

	var world := Node3D.new()
	root.add_child(world)

	var we := WorldEnvironment.new()
	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color(0.10, 0.11, 0.12)
	# Sky-source ambient, matching the Battle.tscn fix, so metal has something
	# to reflect - otherwise every metallic role renders dead flat here.
	env.ambient_light_source = Environment.AMBIENT_SOURCE_SKY
	var sky := Sky.new()
	sky.sky_material = ProceduralSkyMaterial.new()
	env.sky = sky
	env.ambient_light_energy = 0.75
	env.tonemap_mode = Environment.TONE_MAPPER_AGX
	env.tonemap_exposure = 1.0
	env.ssao_enabled = true
	env.adjustment_enabled = true
	env.adjustment_contrast = 1.18
	env.adjustment_saturation = 0.94
	we.environment = env
	world.add_child(we)

	var key := DirectionalLight3D.new()
	key.rotation_degrees = Vector3(-40.0, 35.0, 0.0)
	key.light_energy = 1.15
	key.light_angular_distance = 1.0
	key.shadow_enabled = true
	world.add_child(key)

	var bm = load("res://scripts/blueprint_manager.gd").new()
	root.add_child(bm)
	var bp: Dictionary = bm.load_blueprint(_bp)
	if bp.is_empty():
		print("[design] could not load %s" % _bp); quit(1); return
	var hull = bm.reconstruct_vehicle(bp, world, false, _livery)
	if hull == null:
		print("[design] reconstruct failed"); quit(1); return
	print("[design] %s under livery '%s'" % [_bp.get_file(), _livery])

	# Frame from the silhouette, same maths as the Livery preview.
	var span := 0.0
	var stack: Array = [[hull as Node3D, Transform3D.IDENTITY]]
	while not stack.is_empty():
		var e: Array = stack.pop_back()
		var n: Node = e[0]
		var xf: Transform3D = e[1]
		for c in n.get_children():
			if c is Node3D:
				stack.append([c, xf * (c as Node3D).transform])
		if n is MeshInstance3D and (n as MeshInstance3D).mesh != null:
			var ab: AABB = (n as MeshInstance3D).mesh.get_aabb()
			for i in range(8):
				span = maxf(span, (xf * ab.get_endpoint(i)).length())

	var cam := Camera3D.new()
	cam.fov = 45.0
	world.add_child(cam)
	var dist: float = maxf(span / tan(deg_to_rad(cam.fov) * 0.5) * 1.05, 2.0)
	var at := Vector3(0, span * 0.25, 0)
	cam.look_at_from_position(at + Vector3(0.75, 0.55, 1.0).normalized() * dist, at, Vector3.UP)
	cam.current = true
	_armed = true

func _process(_d: float) -> bool:
	if not _armed:
		return false
	_f += 1
	if _f < 30:
		return false
	root.get_texture().get_image().save_png(_out)
	print("[design] wrote %s" % _out)
	quit(0)
	return true
