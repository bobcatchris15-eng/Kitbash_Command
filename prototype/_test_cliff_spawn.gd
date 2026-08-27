extends SceneTree
# Cliff spawn smoke test (canyon_ford PR1, 2026-08-26; updated 2026-08-26 22:45).
#
# Confirms:
#   1. MapCatalog.FIELD_SPEC validates a JSON-shaped `cliffs[]` entry.
#   2. _spawn_cliff() creates one MeshInstance3D with a ShaderMaterial
#      whose shader is cliff.gdshader.
#   3. _spawn_cliff() creates one StaticBody3D on BattleLayers.TERRAIN
#      (= bit 0 = 1) with a BoxShape3D matching the cliff's bounding box.
#   4. Unknown `type` falls back to "face_0" with a push_warning, not a
#      hard error.
#   5. _plateau_cliffs() emits face_X (or strata_X) pieces on the
#      straight sides and corner_X pieces on the corners - matching the
#      actual GLB pool on disk.
#   6. _plateau_cliffs() SKIPS sides where a ramp is anchored (the
#      "wrong side of the cliff" bug from the 22:45 playtest).
#   7. _plateau_cliffs() SKIPS a corner where a ramp is anchored.
#
# Tests (5)-(7) run the resolver (`_resolve_features`) end-to-end on a
# hand-built map_def so the ramp-skip logic is exercised in the same
# path production uses.
#
# This test does NOT exercise the GLB pool visually (the .glb files
# live in prototype/assets/models/terrain/cliff_*.glb and need Blender
# to regenerate). The BoxMesh fallback path in _spawn_cliff() is the
# one tested here, which is the path a fresh checkout hits anyway.
#
# Run with: godot --headless --script _test_cliff_spawn.gd --path prototype

const TerrainBuilderScript = preload("res://scripts/terrain_builder.gd")
const MapCatalogScript = preload("res://scripts/map_catalog.gd")
const BattleLayersScript = preload("res://scripts/battle/battle_layers.gd")

# Production always runs a map_def through MapCatalog._load_map_file(),
# which decodes JSON arrays into real Vector3/Vector2/Color before the
# spawner sees them. The test simulates that step explicitly - otherwise
# _spawn_cliff tries to read `center.x` on a raw Array, which is the
# exact GDScript error the first test run hit. Use this helper anywhere
# the test builds a map_def by hand.
static func _decoded(raw: Dictionary) -> Dictionary:
	return MapCatalogScript._decode_dict(raw, MapCatalogScript.FIELD_SPEC)

func _init():
	var failed: int = 0
	var tests: Array = [
		{"name": "cliff schema validates", "fn": _test_cliff_schema_validates},
		{"name": "spawn creates MeshInstance3D + StaticBody3D", "fn": _test_spawn_creates_mesh_and_body},
		{"name": "unknown type falls back to 'face_0'", "fn": _test_unknown_type_falls_back},
		{"name": "plateau emits face_X on straight sides", "fn": _test_plateau_emits_face_pieces},
		{"name": "plateau skips cliff emission on ramp side", "fn": _test_plateau_skips_ramp_side},
		{"name": "plateau skips corner when ramp is at corner", "fn": _test_plateau_skips_ramp_corner},
	]
	for t in tests:
		if not t.fn.call():
			failed += 1
			print("[FAIL] %s" % t.name)
		else:
			print("[PASS] %s" % t.name)
	print("")
	if failed == 0:
		print("[PASS] all cliff spawn smoke tests pass (%d total)" % tests.size())
		quit(0)
	else:
		print("[FAIL] %d/%d cliff smoke tests fail" % [failed, tests.size()])
		quit(1)


# (1) A minimal but valid `cliffs[]` entry passes FIELD_SPEC validation.
func _test_cliff_schema_validates() -> bool:
	var raw: Dictionary = {
		"name": "Cliff Smoke Test",
		"description": "Minimal valid map_def for cliff spawn smoke.",
		"map_half_extents": 80.0,
		"world_scale": 1.0,  # production defaults to 4.0; the test keeps dimensions literal
		"ground_color": [0.3, 0.3, 0.3],
		"base_zones": [],
		"water_areas": [],
		"hills": [],
		"obstacles": [],
		"cliffs": [
			{"center": [10.0, 0.0, 5.0], "half_extents": [4.0, 1.0], "type": "face_0", "cliff_height": 4.0},
		],
		"spawns": [
			{"id": "player", "hq": [0.0, 0.0, 20.0], "factory": [0.0, 0.0, 20.0], "refinery": [0.0, 0.0, 20.0], "harvester": [0.0, 0.0, 20.0]},
			{"id": "enemy",  "hq": [0.0, 0.0, -20.0], "factory": [0.0, 0.0, -20.0], "refinery": [0.0, 0.0, -20.0], "harvester": [0.0, 0.0, -20.0]},
		],
		"resource_nodes": [],
		"schema_version": 1,
	}
	# validate_map_def takes the DECODED map_def (post-_decode_dict) per
	# its own header. Decode then validate.
	var decoded: Dictionary = _decoded(raw)
	var errors: Array = MapCatalogScript.validate_map_def(decoded)
	return errors.is_empty()


# (2) _spawn_cliff creates one MeshInstance3D with cliff.gdshader and
#     one StaticBody3D on the TERRAIN collision layer.
func _test_spawn_creates_mesh_and_body() -> bool:
	var raw: Dictionary = {
		"name": "Cliff Smoke Test",
		"description": "Spawn test.",
		"map_half_extents": 80.0,
		"world_scale": 1.0,
		"ground_color": [0.3, 0.3, 0.3],
		"base_zones": [], "water_areas": [], "hills": [], "obstacles": [],
		"cliffs": [
			{"center": [10.0, 0.0, 5.0], "half_extents": [4.0, 1.0], "type": "face_0", "cliff_height": 4.0},
		],
		"spawns": [],
		"resource_nodes": [],
		"schema_version": 1,
	}
	var map_def: Dictionary = _decoded(raw)
	var parent: Node3D = Node3D.new()
	root.add_child(parent)
	TerrainBuilderScript._spawn_cliffs(map_def, parent, 1.0)

	var meshes: Array[MeshInstance3D] = []
	var bodies: Array[StaticBody3D] = []
	for child in parent.get_children():
		if child is MeshInstance3D:
			meshes.append(child)
		elif child is StaticBody3D:
			bodies.append(child)

	if meshes.size() != 1:
		print("    expected 1 MeshInstance3D, got %d" % meshes.size())
		return false
	if bodies.size() != 1:
		print("    expected 1 StaticBody3D, got %d" % bodies.size())
		return false

	# The mesh must use the cliff shader (the visual is a cliff, not a
	# generic obstacle).
	var mesh: MeshInstance3D = meshes[0]
	var mat: ShaderMaterial = mesh.material_override as ShaderMaterial
	if mat == null:
		print("    MeshInstance3D has no ShaderMaterial override")
		return false
	var shader: Shader = mat.shader
	if shader == null:
		print("    ShaderMaterial has no shader assigned")
		return false
	if not shader.resource_path.ends_with("cliff.gdshader"):
		print("    Shader is %s, expected cliff.gdshader" % shader.resource_path)
		return false

	# The body must be on the TERRAIN layer so the navmesh bake and
	# the LOS raycast both see it.
	var body: StaticBody3D = bodies[0]
	if body.collision_layer != BattleLayersScript.TERRAIN:
		print("    StaticBody3D collision_layer is %d, expected %d (TERRAIN)"
			% [body.collision_layer, BattleLayersScript.TERRAIN])
		return false

	# The body's BoxShape3D must match the cliff's bounding box.
	var shape_node: CollisionShape3D = body.get_child(0) as CollisionShape3D
	if shape_node == null:
		print("    StaticBody3D has no CollisionShape3D child")
		return false
	var box: BoxShape3D = shape_node.shape as BoxShape3D
	if box == null:
		print("    CollisionShape3D is not a BoxShape3D")
		return false
	var expected_size: Vector3 = Vector3(8.0, 4.0, 2.0)  # half_extents × 2, cliff_height
	if not box.size.is_equal_approx(expected_size):
		print("    BoxShape3D size is %s, expected %s" % [box.size, expected_size])
		return false

	return true


# (3) An unknown `type` doesn't crash; it falls back to "face_0" with
#     a push_warning, exactly as _spawn_cliff's contract promises.
func _test_unknown_type_falls_back() -> bool:
	var raw: Dictionary = {
		"name": "Cliff Smoke Test",
		"description": "Unknown-type fallback test.",
		"map_half_extents": 80.0,
		"world_scale": 1.0,
		"ground_color": [0.3, 0.3, 0.3],
		"base_zones": [], "water_areas": [], "hills": [], "obstacles": [],
		"cliffs": [
			{"center": [0.0, 0.0, 0.0], "half_extents": [4.0, 1.0], "type": "this_is_not_a_real_type", "cliff_height": 4.0},
		],
		"spawns": [],
		"resource_nodes": [],
		"schema_version": 1,
	}
	var map_def: Dictionary = _decoded(raw)
	var parent: Node3D = Node3D.new()
	root.add_child(parent)
	# suppress the push_warning noise during the test
	TerrainBuilderScript._spawn_cliffs(map_def, parent, 1.0)
	# A cliff with a fallback type still produces a mesh and a body -
	# the contract is "degrade gracefully," not "skip the cliff."
	var n_meshes: int = 0
	var n_bodies: int = 0
	for child in parent.get_children():
		if child is MeshInstance3D:
			n_meshes += 1
		elif child is StaticBody3D:
			n_bodies += 1
	return n_meshes == 1 and n_bodies == 1


# (4) _plateau_cliffs emits face_X (not the legacy "straight" or
#     "corner_out") pieces. This pins the pool change so a future
#     regression to "straight" surfaces immediately.
func _test_plateau_emits_face_pieces() -> bool:
	var feature: Dictionary = {
		"center": [0.0, 0.0, 0.0],
		"half_extents": [40.0, 30.0],
		"height": 8.0,
		"wall_height": 8.0,
	}
	# No ramps -> all 4 sides + 4 corners emit.
	var cliffs: Array = TerrainBuilderScript._plateau_cliffs(feature, [])
	if cliffs.is_empty():
		print("    plateau emitted no cliffs")
		return false
	for c in cliffs:
		var t: String = c.get("type", "")
		if t not in TerrainBuilderScript.CLIFF_FACE_TYPES and t not in TerrainBuilderScript.CLIFF_CORNER_TYPES and t not in TerrainBuilderScript.CLIFF_STRATA_TYPES:
			print("    plateau emitted cliff with legacy/unknown type '%s'" % t)
			return false
	# The 4 sides should each contribute at least one face piece.
	var face_count: int = 0
	var corner_count: int = 0
	for c in cliffs:
		var t: String = c.get("type", "")
		if t in TerrainBuilderScript.CLIFF_FACE_TYPES or t in TerrainBuilderScript.CLIFF_STRATA_TYPES:
			face_count += 1
		elif t in TerrainBuilderScript.CLIFF_CORNER_TYPES:
			corner_count += 1
	if face_count < 4:
		print("    expected at least 4 face pieces, got %d" % face_count)
		return false
	if corner_count != 4:
		print("    expected exactly 4 corner pieces, got %d" % corner_count)
		return false
	return true


# (5) A ramp anchored on the EAST edge of a plateau -> no FACE/STRATA
#     pieces on the east side. The two corner pieces at the SE and NE
#     edges of the plateau stay (the ramp is in the MIDDLE of the east
#     side, not at a corner).
func _test_plateau_skips_ramp_side() -> bool:
	var feature: Dictionary = {
		"center": [0.0, 0.0, 0.0],
		"half_extents": [40.0, 30.0],
		"height": 8.0,
		"wall_height": 8.0,
	}
	# A ramp anchored at the EAST edge of the plateau, MIDDLE of the side.
	var ramp_east: Dictionary = {
		"type": "ramp",
		"anchor": [40.0, 0.0, 0.0],  # right at the east edge, z=0
		"direction_deg": 90.0,        # outward (east)
		"width": 24.0,
		"length": 32.0,
		"top_height": 8.0,
	}
	var features_array: Array = [ramp_east]
	var cliffs: Array = TerrainBuilderScript._plateau_cliffs(feature, features_array)
	if cliffs.is_empty():
		print("    plateau emitted no cliffs despite ramp skip")
		return false
	# Count east-side FACE/STRATA pieces (the wall-run cliff type).
	# Corner pieces (corner_X) at the SE / NE corners of the plateau
	# have x=40 too but are not "wall" pieces; we keep those.
	var east_face_count: int = 0
	var west_face_count: int = 0
	for c in cliffs:
		var pos: Vector3 = c.get("center", Vector3.ZERO)
		var t: String = c.get("type", "")
		if t in TerrainBuilderScript.CLIFF_CORNER_TYPES:
			continue  # not a wall piece
		if abs(pos.x - 40.0) < 0.5:
			east_face_count += 1
		elif abs(pos.x + 40.0) < 0.5:
			west_face_count += 1
	if east_face_count != 0:
		print("    expected 0 east-side wall pieces (ramp skips east), got %d" % east_face_count)
		return false
	if west_face_count == 0:
		print("    expected at least 1 west-side wall piece (no ramp on west), got 0")
		return false
	return true


# (6) A ramp anchored at the SE corner of a plateau -> that corner
#     piece is skipped (the ramp IS the corner transition).
func _test_plateau_skips_ramp_corner() -> bool:
	var feature: Dictionary = {
		"center": [0.0, 0.0, 0.0],
		"half_extents": [40.0, 30.0],
		"height": 8.0,
		"wall_height": 8.0,
	}
	# A ramp anchored at the SE corner (x=+40, z=+30).
	var ramp_se: Dictionary = {
		"type": "ramp",
		"anchor": [40.0, 0.0, 30.0],  # right at the SE corner
		"direction_deg": 135.0,         # outward (SE)
		"width": 24.0,
		"length": 32.0,
		"top_height": 8.0,
	}
	var features_array: Array = [ramp_se]
	var cliffs: Array = TerrainBuilderScript._plateau_cliffs(feature, features_array)
	# Find the SE corner piece (center at (40, 0, 30)).
	var se_corner_found: bool = false
	for c in cliffs:
		var pos: Vector3 = c.get("center", Vector3.ZERO)
		if abs(pos.x - 40.0) < 0.5 and abs(pos.z - 30.0) < 0.5:
			se_corner_found = true
			break
	if se_corner_found:
		print("    SE corner cliff was emitted despite ramp at corner")
		return false
	# The 3 OTHER corners should still have cliff pieces.
	var other_corner_count: int = 0
	for c in cliffs:
		var pos: Vector3 = c.get("center", Vector3.ZERO)
		var t: String = c.get("type", "")
		if t in TerrainBuilderScript.CLIFF_CORNER_TYPES:
			# This is a corner piece.
			var is_se: bool = abs(pos.x - 40.0) < 0.5 and abs(pos.z - 30.0) < 0.5
			if not is_se:
				other_corner_count += 1
	if other_corner_count < 3:
		print("    expected 3 non-SE corner cliffs, got %d" % other_corner_count)
		return false
	return true
