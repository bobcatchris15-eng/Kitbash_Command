extends SceneTree
# WHAT THIS DOES. Loads Battle.tscn with a real test_range MatchConfig, waits
# for world_ready, then renders the scene into a SubViewport and saves the
# image to disk. We use a SubViewport because in headless mode the main
# viewport's texture isn't reliably present.

var _scene: Node = null
var _done: bool = false
var _start_ms: int = 0


func _init() -> void:
	var mc_script = load("res://scripts/match_config.gd")
	var mc = Node.new()
	mc.name = "MatchConfig"
	mc.set_script(mc_script)
	var rule_script = load("res://scripts/match_rule_set.gd")
	var rule = rule_script.test_range(
		"res://data/loadout/bulwark_mbt.json",
		["res://data/loadout/bulwark_mbt.json",
		 "res://data/loadout/rattler_scout.json",
		 "res://data/loadout/dart_skirmisher.json"])
	mc.rule_set = rule
	mc.selected_map_id = "test_range"
	root.add_child(mc)
	var scene = load("res://scenes/Battle.tscn")
	_scene = scene.instantiate()
	root.add_child(_scene)
	if _scene.has_signal("world_ready"):
		_scene.connect("world_ready", _on_world_ready)
	else:
		_render_screenshot()
	_start_ms = Time.get_ticks_msec()


func _process(_dt: float) -> bool:
	if _done:
		return true
	if Time.get_ticks_msec() - _start_ms > 90_000:
		_render_screenshot()
		return true
	return false


func _on_world_ready() -> void:
	print("[render] world_ready")
	for i in range(5):
		await process_frame
	_render_screenshot()


func _render_screenshot() -> void:
	if _done:
		return
	_done = true
	# Build a SubViewport to render the scene through.
	var sub := SubViewport.new()
	sub.size = Vector2i(808, 468)
	sub.transparent_bg = false
	sub.own_world_3d = true
	# Make a camera that mimics the user's view.
	var cam := Camera3D.new()
	cam.global_position = Vector3(-15.0, 6.43, 15.24)
	cam.look_at(Vector3(-15.0, 0.0, 0.0), Vector3.UP)
	cam.current = true
	cam.fov = 70.0
	sub.add_child(cam)
	root.add_child(sub)
	# Re-parent the scene's world to the SubViewport by re-adding the
	# nodes that matter (the world, light, ground).
	# Easiest: re-instance the scene inside the SubViewport.
	var scene = load("res://scenes/Battle.tscn")
	var scene2 = scene.instantiate()
	# Disable the original instance's main camera / chase camera so they
	# don't fight the new camera in the SubViewport.
	var orig_main = scene2.get_node_or_null("Camera3D")
	if orig_main != null:
		orig_main.queue_free()
	var orig_chase = scene2.get_node_or_null("ChaseCamera")
	if orig_chase != null:
		orig_chase.queue_free()
	sub.add_child(scene2)
	# Wait for the new instance to settle.
	for i in range(20):
		await process_frame
	# Pull the rendered image.
	var img: Image = sub.get_texture().get_image()
	if img == null:
		print("[render] no image from SubViewport")
		# Try the main viewport
		var vp := root.get_viewport()
		img = vp.get_texture().get_image() if vp != null else null
	if img == null:
		print("[render] still no image; quitting")
		quit(0)
		return
	var out_path := "res://_rendered_test_range.png"
	var err := img.save_png(out_path)
	print("[render] saved %s err=%s size=%s" % [out_path, err, img.get_size()])
	quit(0)
