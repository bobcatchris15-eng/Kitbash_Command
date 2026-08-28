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
		_sculpt._tab_container.current_tab = 2 # Roads & Bridges tab
		_sculpt._mode = 2
		
		# Build Bridge across river
		_sculpt._bridge_width = 18.0
		_sculpt._bridge_deck_height = 1.6
		_sculpt._bridge_point_a = Vector3(-120.0, 3.5, 0.0)
		_sculpt._bridge_click_step = 1
		_sculpt._handle_roads_bridges_click(Vector3(120.0, 3.5, 0.0))
		
		# Set Camera close to bridge
		_sculpt._cam_pivot.position = Vector3(0.0, 3.0, 0.0)
		_sculpt._cam_dist = 280.0
		_sculpt._cam_yaw = 1.25
		_sculpt._cam_pitch = -0.35
		_sculpt._update_camera()
		_armed = true

	if _armed and _frames > 35:
		var img := root.get_texture().get_image()
		if img != null:
			var os_path := ProjectSettings.globalize_path("res://terrain_sculpt_roads_bridges_tab.png")
			img.save_png(os_path)
			print("[CAPTURE] Saved screenshot to: ", os_path)
		quit(0)
		return true

	return false
