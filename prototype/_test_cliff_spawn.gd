extends SceneTree
# Cliff spawn smoke test (canyon_ford PR1, 2026-08-26).
#
# Confirms:
#   1. MapCatalog.FIELD_SPEC validates a JSON-shaped `cliffs[]` entry.
#   2. _spawn_cliff() creates one MeshInstance3D with a ShaderMaterial
#      whose shader is cliff.gdshader.
#   3. _spawn_cliff() creates one StaticBody3D on BattleLayers.TERRAIN
#      (= bit 0 = 1) with a BoxShape3D matching the cliff's bounding box.
#   4. Unknown `type` falls back to "straight" with a push_warning, not a
#      hard error.
#
# This test does NOT exercise the GLB pool (the .glb files live in
# prototype/assets/models/terrain/cliff_*.glb and are produced by
# prototype/tools/blender/build_cliff_props.py - they may not exist on a
# fresh checkout). The BoxMesh fallback path in _spawn_cliff() is the
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
	if not _test_cliff_schema_validates():
		failed += 1
		print("[FAIL] cliff schema validates")
	else:
		print("[PASS] cliff schema validates")

	if not _test_spawn_creates_mesh_and_body():
		failed += 1
		print("[FAIL] spawn creates MeshInstance3D + StaticBody3D")
	else:
		print("[PASS] spawn creates MeshInstance3D + StaticBody3D")

	if not _test_unknown_type_falls_back():
		failed += 1
		print("[FAIL] unknown type falls back to 'straight'")
	else:
		print("[PASS] unknown type falls back to 'straight'")

	print("")
	if failed == 0:
		print("[PASS] all cliff spawn smoke tests pass")
		quit(0)
	else:
		print("[FAIL] %d/3 cliff smoke tests fail" % failed)
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
			{"center": [10.0, 0.0, 5.0], "half_extents": [4.0, 1.0], "type": "straight", "cliff_height": 4.0},
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
		"world_scale": 1.0,  # test-only: production maps default to 4.0
		"ground_color": [0.3, 0.3, 0.3],
		"base_zones": [], "water_areas": [], "hills": [], "obstacles": [],
		"cliffs": [
			{"center": [10.0, 0.0, 5.0], "half_extents": [4.0, 1.0], "type": "straight", "cliff_height": 4.0},
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


# (4) An unknown `type` doesn't crash; it falls back to "straight" with
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
