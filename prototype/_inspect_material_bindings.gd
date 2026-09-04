extends SceneTree
# WHAT THIS DOES. Loads Battle.tscn with a real test_range MatchConfig, waits
# for the match_director to emit `world_ready`, then walks the entire scene
# tree printing every material binding it can find. The point is to find
# which texture is actually on the ground mesh at the player's spawn, since
# the user's screenshot shows the procedural rocky_albedo.png even though
# no production code path should be loading that texture any more (defensive
# fix at terrain_builder.gd:1976 swapped the rock overlay from "base" to
# "_v1").

var _scene: Node = null
var _matches: Array = []
var _done: bool = false
var _start_ms: int = 0


func _init() -> void:
	# 1. Set up MatchConfig autoload before the scene loads.
	var mc_script = load("res://scripts/match_config.gd")
	if mc_script == null:
		push_error("[probe] no match_config.gd")
		quit(1)
		return
	var mc = Node.new()
	mc.name = "MatchConfig"
	mc.set_script(mc_script)
	var rule_script = load("res://scripts/match_rule_set.gd")
	if rule_script == null:
		push_error("[probe] no match_rule_set.gd")
		quit(1)
		return
	var rule = rule_script.test_range(
		"res://data/loadout/bulwark_mbt.json",
		["res://data/loadout/bulwark_mbt.json",
		 "res://data/loadout/rattler_scout.json",
		 "res://data/loadout/wasp_rocket_buggy.json"])
	mc.rule_set = rule
	mc.selected_map_id = "test_range"
	root.add_child(mc)
	# 2. Load the scene.
	var scene = load("res://scenes/Battle.tscn")
	_scene = scene.instantiate()
	root.add_child(_scene)
	print("[probe] Battle scene instantiated")
	if _scene.has_signal("world_ready"):
		_scene.connect("world_ready", _on_world_ready)
	else:
		print("[probe] scene has no world_ready signal - walking immediately")
		_walk_and_quit.call_deferred()
	_start_ms = Time.get_ticks_msec()


func _process(_dt: float) -> bool:
	# SceneTree._process. Returns true to quit.
	if _done:
		return true
	if Time.get_ticks_msec() - _start_ms > 90_000:
		print("[probe] 90s hard cap reached")
		_walk_and_quit()
		return true
	return false


func _on_world_ready() -> void:
	print("[probe] world_ready signal received")
	# Report what the match director actually resolved to.
	var director = _scene
	if director != null and director.has_method("get"):
		var cm = director.get("current_map")
		if cm is Dictionary:
			print("[probe] current_map.name = %s" % str(cm.get("name", "?")))
			print("[probe] current_map.map_half_extents = %s" % str(cm.get("map_half_extents", "?")))
			print("[probe] current_map keys = %s" % str(cm.keys()))
		var mid = director.get("map_id")
		print("[probe] map_id = %s" % str(mid))
	_walk_and_quit()


func _walk_and_quit() -> void:
	if _done:
		return
	_done = true
	# Give the engine one tick to flush any pending _ready work that ran
	# in the same frame as world_ready (the deploy-gate / HUD autoloads).
	await process_frame
	_visit(_scene, "Battle", "")
	if _matches.is_empty():
		print("[probe] NO materials found")
	for m in _matches:
		print(m)
	quit(0)


func _visit(node: Node, path: String, indent: String) -> void:
	if node is MeshInstance3D:
		var mi: MeshInstance3D = node
		var mat := mi.material_override
		var mat_label := "material_override"
		if mat == null and mi.mesh != null and mi.get_surface_override_material(0) != null:
			mat = mi.get_surface_override_material(0)
			mat_label = "surface_override[0]"
		if mat == null and mi.mesh != null and mi.mesh.get_surface_count() > 0:
			mat = mi.mesh.surface_get_material(0)
			mat_label = "mesh.surface[0]"
		var pos := mi.global_position
		var size_str := "<no mesh>"
		if mi.mesh != null:
			var aabb := mi.get_aabb()
			size_str = "(%.1f x %.1f x %.1f)" % [aabb.size.x, aabb.size.y, aabb.size.z]
		var pos_str := "pos=(%.1f, %.1f, %.1f)" % [pos.x, pos.y, pos.z]
		_matches.append("%s%s %s %s" % [indent, path, pos_str, size_str])
		if mat != null:
			var label := "%s%s %s" % [indent, path, mat_label]
			if mat is ShaderMaterial:
				var sm: ShaderMaterial = mat
				var shader := sm.shader
				var shader_path := "<no shader>" if shader == null else shader.resource_path
				_matches.append("%s -> ShaderMaterial (shader=%s)" % [label, shader_path])
				for prop in sm.get_property_list():
					var n: String = prop.name
					if n.begins_with("shader_parameter/") and prop.usage & PROPERTY_USAGE_STORAGE:
						var v = sm.get(n)
						if v is Texture2D:
							var t: Texture2D = v
							_matches.append("    %s = %s" % [n, t.resource_path])
			elif mat is StandardMaterial3D:
				var std: StandardMaterial3D = mat
				var tex_str := "<no texture>"
				if std.albedo_texture != null:
					tex_str = std.albedo_texture.resource_path
				_matches.append("%s -> StandardMaterial3D (albedo=%s)" % [label, tex_str])
			else:
				_matches.append("%s -> %s" % [label, mat.get_class()])
	for child in node.get_children():
		_visit(child, path + "/" + child.name, indent)
