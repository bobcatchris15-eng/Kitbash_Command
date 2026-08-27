extends SceneTree
# Verifies the cliff y_offset fix from the 2026-08-26 22:14 playtest:
# plateau auto-emitted cliffs must sit at the SURROUNDING ground (0m)
# and extend UP to wall_height, NOT at the heightmap level (14m) and
# extend UP to 28m (the "opposite of a ramp" the user saw).
#
# Approach: _spawn_cliff only writes the visual/collision to the
# scene tree, so we can inspect the children's positions directly.
#
# Run: godot --headless --script _test_cliff_y_offset.gd --path prototype

const TerrainBuilderScript = preload("res://scripts/terrain_builder.gd")

func _init() -> void:
	# Build a minimal map_def with one plateau (height 14) and resolve
	# the features so the plateau emits its auto-cliff pieces.
	var map_def: Dictionary = {
		"name": "cliff_y_offset_test",
		"map_half_extents": 100.0,
		"map_half_extents_z": 100.0,
		"world_scale": 1.0,
		"hills": [],
		"water_blobs": [],
		"water_areas": [],
		"cliffs": [],
		"terrain": {
			"features": [
				{"type": "plateau", "center": Vector3(0, 0, 0), "half_extents": Vector2(20, 20), "height": 14, "wall_height": 14}
			],
			"noise": {"amplitude": 0.0, "frequency": 0.0},
		},
	}
	TerrainBuilderScript._resolve_features(map_def)
	# Now spawn the cliffs. _spawn_cliff reads `cliffs[]` and writes to
	# parent. Use a parent Node3D to capture the output.
	var parent: Node3D = Node3D.new()
	root.add_child(parent)
	TerrainBuilderScript._spawn_cliffs(map_def, parent, 1.0)
	# Pick the first straight piece and read its y position. After
	# the fix, the visual mesh should be at y=0 (or thereabouts - the
	# heightmap at the cliff line is exactly wall_height=14, so base_y
	# = 14 + y_offset(-14) = 0). Before the fix, the visual was at
	# y=14 (the heightmap level) and the body at y=21.
	var visuals_at_wrong_y: int = 0
	var bodies_at_wrong_y: int = 0
	var wrong_examples: Array = []
	var cliff_count: int = 0
	# Tolerance ±1.5m accounts for the heightmap's smoothstep falloff
	# at the exact plateau edge (the heightmap there is slightly less
	# than full wall_height, so base_y is slightly negative).
	const TOL: float = 1.5
	for child in parent.get_children():
		if child is MeshInstance3D:
			# _spawn_cliff writes exactly one MeshInstance3D and one
			# StaticBody3D per cliff, so counting mesh instances gives
			# the actual cliff count (get_child_count() would double it).
			cliff_count += 1
			# Visual: y should be ~0 (surrounding ground, with
			# y_offset = -wall_height negating the heightmap level).
			# Before the fix: y was 14m (heightmap level at edge).
			if absf(child.position.y) > TOL:
				visuals_at_wrong_y += 1
				if wrong_examples.size() < 3:
					wrong_examples.append("MESH y=%.2f (expected ~0 +/- %.1f)" % [child.position.y, TOL])
		elif child is StaticBody3D:
			# Body: y should be cliff_height/2 (so the box spans
			# 0 to cliff_height). For a 14m cliff that's 7m. Before
			# the fix it was 21m (heightmap 14 + cliff_height/2 7).
			if absf(child.position.y - 7.0) > TOL:
				bodies_at_wrong_y += 1
				if wrong_examples.size() < 6:
					wrong_examples.append("BODY y=%.2f (expected ~7 +/- %.1f)" % [child.position.y, TOL])
	if visuals_at_wrong_y > 0 or bodies_at_wrong_y > 0:
		print("[FAIL] %d visuals at wrong y, %d bodies at wrong y" % [visuals_at_wrong_y, bodies_at_wrong_y])
		for ex in wrong_examples:
			print("        %s" % ex)
		quit(1)
		return
	print("[PASS] %d cliffs all at correct y: visuals at ~0, bodies at ~7" % cliff_count)
	quit(0)
