extends SceneTree

const TerrainSculptScript = preload("res://scripts/terrain_sculpt.gd")

var _frames := 0
var _armed := false
var _sculpt: TerrainSculpt = null

func _initialize() -> void:
	_sculpt = TerrainSculpt.new()
	root.add_child(_sculpt)

func _process(_delta: float) -> bool:
	_frames += 1
	if _frames == 3:
		_sculpt.load_map("twin_streams_v2")
		
		# 1. Build a 2-Point Bridge across the river
		_sculpt._bridge_width = 18.0
		_sculpt._bridge_deck_height = 1.6
		_sculpt._bridge_point_a = Vector3(-120.0, 3.5, 0.0)
		_sculpt._bridge_click_step = 1
		_sculpt._handle_roads_bridges_click(Vector3(120.0, 3.5, 0.0))
		
		# 2. Build a Road connecting to the bridge
		_sculpt._road_width = 16.0
		_sculpt._road_surface = "dirt"
		_sculpt._road_point_a = Vector3(-120.0, 3.5, 0.0)
		_sculpt._road_click_step = 1
		_sculpt._handle_roads_bridges_click(Vector3(-250.0, 0.0, -80.0))
		
		# 3. Paint Tree Groves and Boulder Clusters
		_sculpt._greeble_tool = 0 # TREE
		_sculpt._greeble_radius = 45.0
		_sculpt._greeble_density = 0.9
		for p in [Vector3(-160, 0, -120), Vector3(-140, 0, 100), Vector3(160, 0, -80), Vector3(140, 0, 120)]:
			_sculpt._apply_greeble_stroke(p, 0.4)
			
		_sculpt._greeble_tool = 1 # BOULDER
		_sculpt._greeble_radius = 35.0
		for p in [Vector3(-80, 0, -180), Vector3(90, 0, -160), Vector3(0, 0, 180)]:
			_sculpt._apply_greeble_stroke(p, 0.4)

		# Set Camera angle for great scenic view
		_sculpt._cam_dist = 620.0
		_sculpt._cam_yaw = 0.75
		_sculpt._cam_pitch = -0.55
		_sculpt._update_camera()
		_armed = true

	if _armed and _frames > 35:
		var img := root.get_texture().get_image()
		if img != null:
			var os_path := ProjectSettings.globalize_path("res://terrain_sculpt_roads_bridges_greebles.png")
			img.save_png(os_path)
			print("[CAPTURE] Saved screenshot to: ", os_path)
		quit(0)
		return true

	return false
