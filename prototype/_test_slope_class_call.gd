extends SceneTree

# canyon_ford PR3 regression check: the disk source for
# match_director.gd must use the 3-arg call shape
# (map_def, x, z), not the old 2-arg (map_def, Vector3)
# shape. Run targeted to bypass run_tests.ps1 bytecode cache.
func _init() -> void:
	var MapCatalog = load("res://scripts/map_catalog.gd")
	var terrain = load("res://scripts/terrain_builder.gd")
	var map_def: Dictionary = MapCatalog.get_map("open_plains")
	if map_def.is_empty():
		print("FAIL: open_plains missing")
		quit(1); return
	var cls: String = terrain.slope_class_at(map_def, 0.0, 0.0)
	print("slope_class_at(0,0)=", cls)
	if cls not in ["walkable", "walkable_slow", "impassable", ""]:
		print("FAIL: bad class")
		quit(1); return
	var f = FileAccess.open("res://scripts/battle/match_director.gd", FileAccess.READ)
	var txt := f.get_as_text()
	f.close()
	if "TerrainBuilder.slope_class_at(current_map, pos.x, pos.z)" in txt:
		print("OK: source line 1104 has the fix")
		quit(0)
	else:
		print("FAIL: source line 1104 missing the fix")
		quit(1)
