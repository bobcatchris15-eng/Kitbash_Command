extends SceneTree
# Places a refinery on sloped ground and checks each dock pad sits ON the
# (flattened) terrain rather than floating above or buried in it.
var _scene: Node = null
var _ready_flag := false
var _f := 0

func _initialize() -> void:
	var mc = Node.new(); mc.name = "MatchConfig"
	mc.set_script(load("res://scripts/match_config.gd"))
	var L = load("res://scripts/livery.gd")
	var rs = load("res://scripts/match_rule_set.gd").skirmish(
		"sentinel_divide", L.PLAYER_ID, "", ["res://data/loadout/bulwark_mbt.json"])
	rs.log_profiling = false
	mc.rule_set = rs; mc.selected_map_id = "sentinel_divide"
	root.add_child(mc)
	_scene = load("res://scenes/Battle.tscn").instantiate()
	if _scene.has_signal("world_ready"):
		_scene.connect("world_ready", func(): _ready_flag = true)
	root.add_child(_scene)

func _process(_d: float) -> bool:
	if not _ready_flag:
		_f += 1
		if _f > 6000: print("TIMEOUT"); quit(1)
		return false
	_f += 1
	if _f < 60:
		return false
	var TB = load("res://scripts/terrain_builder.gd")
	var map: Dictionary = _scene.current_map
	var worst := 0.0
	var n := 0
	# Place refineries at several spots, preferring sloped ground.
	for spot in [Vector3(-300, 0, -40), Vector3(-260, 0, 10), Vector3(-340, 0, 30),
			Vector3(-220, 0, -80), Vector3(-380, 0, -10)]:
		var at := Vector3(spot.x, _scene.terrain_height_at(spot), spot.z)
		var st = _scene._place_structure("refinery", 0, at, false)
		if st == null:
			continue
		var pads = st.get_node_or_null("DockPads")
		if pads == null:
			continue
		for pad in pads.get_children():
			# Only the driving Surface: the Plinth is buried on purpose, so
			# measuring it would report the plinth depth as an error.
			# begins_with, not ==: Godot uniquifies duplicate sibling names, so
			# a three-bay refinery has Surface / Surface2 / Surface3.
			if not (pad is MeshInstance3D) or not str(pad.name).begins_with("Surface"):
				continue
			var mi := pad as MeshInstance3D
			var wp: Vector3 = mi.global_position
			# Corners, not just the centre: the visible gap is at the edges,
			# where a rigid slab lifts off a piecewise-linear ground mesh.
			var ab: AABB = mi.mesh.get_aabb()
			var gap: float = 0.0
			for cx in [-0.5, 0.5]:
				for cz in [-0.5, 0.5]:
					var c := Vector3(wp.x + ab.size.x * cx, wp.y, wp.z + ab.size.z * cz)
					var g: float = c.y - TB.height_at(map, c.x, c.z)
					if absf(g) > absf(gap):
						gap = g
			# A pad is a thin slab sitting on the ground: its centre should be
			# within a few cm of the surface.
			if absf(gap) > absf(worst):
				worst = gap
			n += 1
			if absf(gap) > 0.20:
				print("  pad at (%.0f,%.0f) gap %+.3f m" % [wp.x, wp.z, gap])
	print("checked %d pads, worst CORNER gap %+.3f m (plinth depth 0.70 must exceed it)" % [n, worst])
	quit(0)
	return true
