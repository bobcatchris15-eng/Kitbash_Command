extends SceneTree
# capture_setup_screens.gd
# Captures rendered screenshots of the match setup flow stages.

const Tokens = preload("res://scripts/ui_tokens.gd")
const MapCatalog = preload("res://scripts/map_catalog.gd")

var _sub: SubViewport
var _scene: Control
var _frame: int = 0
var _out_dir: String = "res://data/ui_critique"

func _init() -> void:
	print("[capture_setup_screens] Initializing...")
	DirAccess.make_dir_recursive_absolute("res://data/ui_critique")

	# Seed MatchConfig autoload if not already present
	var mc: Node = root.get_node_or_null("MatchConfig")
	if mc == null:
		mc = Node.new()
		mc.name = "MatchConfig"
		mc.set_script(load("res://scripts/match_config.gd"))
		root.add_child(mc)

	# Seed SceneRouter autoload if not present
	var sr: Node = root.get_node_or_null("SceneRouter")
	if sr == null:
		sr = Node.new()
		sr.name = "SceneRouter"
		sr.set_script(load("res://scripts/scene_router.gd"))
		root.add_child(sr)

	# Build SubViewport at 1920x1080
	_sub = SubViewport.new()
	_sub.size = Vector2i(1920, 1080)
	_sub.transparent_bg = false
	_sub.own_world_3d = true
	_sub.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	_sub.msaa_3d = Viewport.MSAA_4X

	# SubViewport does not have a theme property; themes belong to Control nodes.
	root.add_child(_sub)

	# Instantiate MatchSetup
	var packed: PackedScene = load("res://scenes/MatchSetup.tscn")
	_scene = packed.instantiate() as Control
	_sub.add_child(_scene)
	print("[capture_setup_screens] MatchSetup instantiated in SubViewport (1920x1080)")

func _process(_dt: float) -> bool:
	_frame += 1

	# Frame 25: Capture Stage 1 (Theatre) - default map
	if _frame == 25:
		print("[capture_setup_screens] Capturing stage1_theatre...")
		_save_viewport("stage1_theatre.png")

	# Frame 30: Switch to another map in Theatre to see topo variety
	elif _frame == 30:
		if _scene.MAP_IDS.size() > 1:
			var second_map = str(_scene.MAP_IDS[1])
			print("[capture_setup_screens] Selecting map: ", second_map)
			_scene.select_map(second_map)

	# Frame 45: Capture stage1_theatre_alt
	elif _frame == 45:
		print("[capture_setup_screens] Capturing stage1_theatre_alt...")
		_save_viewport("stage1_theatre_alt.png")
		# Switch back to first map
		if not _scene.MAP_IDS.is_empty():
			_scene.select_map(str(_scene.MAP_IDS[0]))
		# Switch to Stage 2 (Roster)
		print("[capture_setup_screens] Navigating to Stage 1 (Roster)...")
		_scene._goto_stage(1, false)

	# Frame 70: Capture stage2_squadron (empty / auto-draft)
	elif _frame == 70:
		print("[capture_setup_screens] Capturing stage2_squadron (empty / auto-draft)...")
		_save_viewport("stage2_squadron.png")

		# Populate some designs into the roster slots for critique
		var picker = _scene.roster_picker
		if picker:
			var entries: Array = _scene.bp_manager.list_blueprints(true)
			print("[capture_setup_screens] Found ", entries.size(), " blueprints. Assigning to slots...")
			var assigned := 0
			for entry in entries:
				if assigned >= 8:
					break
				var p := str(entry.get("path", ""))
				if p != "" and picker.assign_to_next_free(p):
					assigned += 1
			print("[capture_setup_screens] Assigned ", assigned, " designs to roster.")

	# Frame 95: Capture stage2_squadron_populated
	elif _frame == 95:
		print("[capture_setup_screens] Capturing stage2_squadron_populated...")
		_save_viewport("stage2_squadron_populated.png")

		# Switch to Stage 3 (Launch in current code)
		print("[capture_setup_screens] Navigating to Stage 2 (Launch / Rules / Squadron)...")
		_scene._goto_stage(2, false)

	# Frame 135: Wait for 3D echelon hero view to settle, then capture
	elif _frame == 135:
		print("[capture_setup_screens] Capturing stage3_rules & stage4_launch...")
		_save_viewport("stage4_launch.png")
		_save_viewport("stage3_rules.png")

		# Also capture cropped / dedicated view of the rules section if possible
		_save_rules_panel("stage3_rules_detail.png")
		_save_hero_view("stage4_launch_hero.png")

	elif _frame >= 145:
		print("[capture_setup_screens] All captures complete! Exiting...")
		quit(0)
		return true

	return false

func _save_viewport(filename: String) -> void:
	var img: Image = _sub.get_texture().get_image()
	if img == null:
		print("[capture_setup_screens] ERROR: Null image from SubViewport")
		return
	var full_path = _out_dir + "/" + filename
	var err = img.save_png(full_path)
	print("[capture_setup_screens] Saved: ", full_path, " (err=", err, ", size=", img.get_size(), ")")

func _save_rules_panel(filename: String) -> void:
	# Crop the left half where Engagement Rules and Deployment Order live
	var img: Image = _sub.get_texture().get_image()
	if img == null:
		return
	# Crop left region (e.g. 0, 0 to 1100, 1080)
	var cropped := img.get_region(Rect2i(0, 0, 1150, 1080))
	var full_path = _out_dir + "/" + filename
	cropped.save_png(full_path)
	print("[capture_setup_screens] Saved rules detail: ", full_path)

func _save_hero_view(filename: String) -> void:
	# Crop the right half where SquadronHeroView lives
	var img: Image = _sub.get_texture().get_image()
	if img == null:
		return
	var cropped := img.get_region(Rect2i(1050, 60, 850, 940))
	var full_path = _out_dir + "/" + filename
	cropped.save_png(full_path)
	print("[capture_setup_screens] Saved hero detail: ", full_path)
