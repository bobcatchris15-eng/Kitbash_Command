extends SceneTree
# One-off: boots a REAL Battle.tscn skirmish (real Environment_bt, real units,
# real buildings) and saves screenshots at gameplay camera heights so the
# in-match look can be judged. Not part of any suite.
#
#   Godot_v4.7.1-stable_win64.exe --path . \
#     --script res://tools/capture_battle_look.gd -- --out-dir C:/tmp --map sentinel_divide

var _out_dir := "."
var _map := "sentinel_divide"
var _scene: Node = null
var _ready_flag := false
var _frames := 0
var _shot := 0
var _cam: Camera3D = null
var _shots: Array = []


func _arg(n: String, d: String) -> String:
	var a := OS.get_cmdline_user_args()
	for i in range(a.size()):
		if a[i] == n and i + 1 < a.size():
			return a[i + 1]
	return d


func _initialize() -> void:
	_out_dir = _arg("--out-dir", _out_dir)
	_map = _arg("--map", _map)
	DisplayServer.window_set_size(Vector2i(1920, 1080))
	root.content_scale_size = Vector2i(1920, 1080)

	var mc_script = load("res://scripts/match_config.gd")
	var mc = Node.new()
	mc.name = "MatchConfig"
	mc.set_script(mc_script)
	var rule_script = load("res://scripts/match_rule_set.gd")
	var rs = rule_script.skirmish(_map, load("res://scripts/livery.gd").PLAYER_ID, "", [
		"res://data/loadout/bulwark_mbt.json",
		"res://data/loadout/rattler_scout.json",
		"res://data/loadout/dart_skirmisher.json",
		"res://data/loadout/vulture_harvester.json",
		"res://data/loadout/raptor_striker.json",
	])
	rs.log_profiling = false
	mc.rule_set = rs
	mc.selected_map_id = _map
	root.add_child(mc)

	_scene = load("res://scenes/Battle.tscn").instantiate()
	if _scene.has_signal("world_ready"):
		_scene.connect("world_ready", func(): _ready_flag = true)
	root.add_child(_scene)
	print("[look] booting %s" % _map)


func _find_focus() -> Vector3:
	# Centre on the densest cluster of player units/structures.
	var pts: Array = []
	var stack: Array = [_scene]
	while not stack.is_empty():
		var n = stack.pop_back()
		for c in n.get_children():
			stack.append(c)
		if n is Node3D and (n.has_method("get_team") or "team" in n):
			var t = n.get("team")
			if t == 0:
				pts.append((n as Node3D).global_position)
	if pts.is_empty():
		return Vector3.ZERO
	var s := Vector3.ZERO
	for p in pts:
		s += p
	print("[look] %d team-0 nodes, centroid %s" % [pts.size(), s / pts.size()])
	return s / float(pts.size())


func _process(_dt: float) -> bool:
	if not _ready_flag:
		_frames += 1
		if _frames > 5000:
			print("[look] TIMEOUT waiting for world_ready")
			quit(1)
		return false

	_frames += 1
	# Let the AI produce units and the sim settle before shooting.
	if _shots.is_empty():
		if _frames < 900:
			return false
		var focus := _find_focus()
		_shots = [
			{"name": "01_tactical", "eye": Vector3(22, 26, 34), "at": focus},
			{"name": "02_close", "eye": Vector3(9, 8, 13), "at": focus},
			{"name": "03_ground", "eye": Vector3(5, 3.0, 7), "at": focus},
			{"name": "04_wide", "eye": Vector3(70, 85, 110), "at": focus},
		]
		# Find the live camera.
		for c in _scene.get_children():
			if c is Camera3D:
				_cam = c
				break
		if _cam == null:
			print("[look] no camera found")
			quit(1)
		# rts_camera.gd drives the transform every frame; kill its script.
		_cam.set_script(null)
		_cam.current = true
		_frames = 0
		return false

	if _frames < 20:
		return false
	var s: Dictionary = _shots[_shot]
	if _frames == 20:
		_cam.look_at_from_position(s["at"] + s["eye"], s["at"], Vector3.UP)
		return false
	if _frames < 40:
		return false
	var img := root.get_texture().get_image()
	var path := "%s/%s.png" % [_out_dir, s["name"]]
	img.save_png(path)
	print("[look] wrote %s (eye %s)" % [path, s["eye"]])
	_shot += 1
	_frames = 0
	if _shot >= _shots.size():
		quit(0)
		return true
	return false
