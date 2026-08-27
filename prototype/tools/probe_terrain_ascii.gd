extends SceneTree
# Prints a coarse ASCII passability map. '.' walkable, ':' walkable_slow,
# '#' impassable. Fast way to see a barrier that a path query only reports
# as "stopped 693 m short".
#
#   Godot..._console.exe --headless --path <prototype>
#     --script res://tools/probe_terrain_ascii.gd --quit -- --map <id>

const TerrainBuilderScript = preload("res://scripts/terrain_builder.gd")
const MapCatalogScript = preload("res://scripts/map_catalog.gd")

func _initialize() -> void:
	var map_id := "sentinel_divide"
	var args := OS.get_cmdline_user_args()
	for i in range(args.size()):
		if args[i] == "--map" and i + 1 < args.size():
			map_id = args[i + 1]
	var map_def: Dictionary = MapCatalogScript.get_map(map_id)
	var half: float = float(map_def.get("map_half_extents", 100.0))
	var cols := 96
	var rows := 48
	print("=== %s passability (x -> right, z -> down), half=%.0f ===" % [map_id, half])
	var legend := {
		TerrainBuilderScript.SLOPE_WALKABLE: ".",
		TerrainBuilderScript.SLOPE_WALKABLE_SLOW: ":",
		TerrainBuilderScript.SLOPE_IMPASSABLE: "#",
	}
	for r in range(rows):
		var z: float = lerpf(-half, half, (float(r) + 0.5) / float(rows))
		var line := ""
		for c in range(cols):
			var x: float = lerpf(-half, half, (float(c) + 0.5) / float(cols))
			line += legend.get(TerrainBuilderScript.slope_class_at(map_def, x, z), "?")
		print("%5.0f %s" % [z, line])
	quit(0)
