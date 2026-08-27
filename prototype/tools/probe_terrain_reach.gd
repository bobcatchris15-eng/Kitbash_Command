extends SceneTree
# ASCII map of NAVMESH REACHABILITY from a seed point. '#' = no navmesh here,
# '+' = on the navmesh and reachable from the seed, '-' = on the navmesh but
# NOT reachable (a separate island), 'S' = the seed.
#
# slope_class_at() answers "is this ground walkable", which is not the same
# question as "can a unit get there" - a perfectly walkable pocket sealed by a
# ring of cliff reads as all-clear on a passability map and is still
# unreachable. This is the map that shows islands.
#
#   Godot..._console.exe --headless --path <prototype>
#     --script res://tools/probe_terrain_reach.gd -- --map <id>

const TerrainBuilderScript = preload("res://scripts/terrain_builder.gd")
const MapCatalogScript = preload("res://scripts/map_catalog.gd")

var _map_def: Dictionary = {}
var _ground: RID = RID()
var _frames: int = 0
var _seed_pt: Vector3 = Vector3.ZERO


func _initialize() -> void:
	var map_id := "sentinel_divide"
	var args := OS.get_cmdline_user_args()
	for i in range(args.size()):
		if args[i] == "--map" and i + 1 < args.size():
			map_id = args[i + 1]
	_map_def = MapCatalogScript.get_map(map_id)
	print("=== %s navmesh reachability ===" % map_id)
	var nav: Dictionary = TerrainBuilderScript.build_navmeshes(_map_def)
	_ground = nav.get("ground_map", RID())
	# Seed on the FIRST spawn's HQ - the side the player starts on.
	var spawns: Array = _map_def.get("spawns", [])
	if spawns.size() >= 1:
		_seed_pt = TerrainBuilderScript._vec3_of(spawns[0].get("hq", Vector3.ZERO))
		_seed_pt.y = TerrainBuilderScript.height_at(_map_def, _seed_pt.x, _seed_pt.z)


func _process(_delta: float) -> bool:
	_frames += 1
	NavigationServer3D.map_force_update(_ground)
	if not _ready() and _frames < 600:
		return false
	_dump()
	quit(0)
	return true


func _ready_point(p: Vector3) -> Vector3:
	return NavigationServer3D.map_get_closest_point(_ground, p)


func _ready() -> bool:
	if NavigationServer3D.map_get_regions(_ground).is_empty():
		return false
	return _ready_point(_seed_pt).distance_to(_seed_pt) < 12.0


func _dump() -> void:
	var half: float = float(_map_def.get("map_half_extents", 100.0))
	var seed_on := _ready_point(_seed_pt)
	var cols := 72
	var rows := 36
	var reachable := 0
	var island := 0
	var offmesh := 0
	print("seed %s -> on-mesh %s (synced after %d frames)" % [_seed_pt, seed_on, _frames])
	for r in range(rows):
		var z: float = lerpf(-half, half, (float(r) + 0.5) / float(rows))
		var line := ""
		for c in range(cols):
			var x: float = lerpf(-half, half, (float(c) + 0.5) / float(cols))
			var q := Vector3(x, TerrainBuilderScript.height_at(_map_def, x, z), z)
			var on := _ready_point(q)
			if on.distance_to(q) > 20.0:
				line += "#"
				offmesh += 1
				continue
			var path: PackedVector3Array = NavigationServer3D.map_get_path(_ground, seed_on, on, true)
			if path.size() >= 2 and path[path.size() - 1].distance_to(on) < 25.0:
				line += "+"
				reachable += 1
			else:
				line += "-"
				island += 1
		print("%5.0f %s" % [z, line])
	print("reachable %d | unreachable-island %d | no-navmesh %d" % [reachable, island, offmesh])
