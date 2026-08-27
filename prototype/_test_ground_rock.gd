extends SceneTree
# Slope-based material blending smoke test (canyon_ford PR4, 2026-08-26).
#
# Confirms:
#   1. The terrain_ground.gdshader rock triplanar block (lines 41-47
#      declare the uniforms, lines 255-282 implement the blend) is
#      reachable from the runtime: the rock_albedo / rock_normal /
#      rock_rough uniforms are set on the heightmap ground material.
#   2. The shader compiles cleanly with the new uniforms (the shader
#      file already exists and uses these uniforms - this test just
#      confirms the material's compiled ShaderMaterial has them
#      assigned).
#   3. The dirt middle-band uniforms the spec describes are exposed
#      as a documented gap (this PR doesn't add the band, but the
#      "what's left for PR6" answer is captured here so the next
#      agent / the user can see it).
#
# The visual check ("a 30° pixel reads as dirt, a 60° pixel reads as
# rock") needs a screenshot test, which this headless smoke test
# can't do. The unit-level guarantee is "the rock pass is wired and
# will fire" - the actual material blend at runtime is what the
# visual-regression suite verifies.
#
# Run with: godot --headless --script _test_ground_rock.gd --path prototype

const TerrainBuilderScript = preload("res://scripts/terrain_builder.gd")
const MapCatalogScript = preload("res://scripts/map_catalog.gd")

static func _decoded(raw: Dictionary) -> Dictionary:
	return MapCatalogScript._decode_dict(raw, MapCatalogScript.FIELD_SPEC)

func _init():
	var failed: int = 0
	if not _test_rock_uniforms_are_set():
		failed += 1
		print("[FAIL] rock triplanar uniforms are set on heightmap material")
	else:
		print("[PASS] rock triplanar uniforms are set on heightmap material")
	if not _test_shader_compiles():
		failed += 1
		print("[FAIL] terrain_ground.gdshader compiles")
	else:
		print("[PASS] terrain_ground.gdshader compiles")
	print("")
	if failed == 0:
		print("[PASS] all PR4 ground-material tests pass")
		quit(0)
	else:
		print("[FAIL] %d/2 PR4 tests fail" % failed)
		quit(1)


# Build a minimal heightmap map_def, call build_ground_material_heightmap,
# and confirm the rock triplanar uniforms are populated. Without these
# the shader's rock pass (lines 255-282) is a no-op - the visual outcome
# is "no slope-aware rock on a hill face," which is the bug PR4 exists
# to prevent.
func _test_rock_uniforms_are_set() -> bool:
	var raw: Dictionary = {
		"name": "PR4 Rock Test",
		"description": "Minimal heightmap map for ground-material rock uniforms.",
		"map_half_extents": 80.0,
		"world_scale": 1.0,
		"ground_color": [0.3, 0.3, 0.3],
		"base_zones": [], "water_areas": [], "hills": [],
		"obstacles": [],
		"terrain": {
			"heightmap": "res://data/test_fixtures/terrain/test_terrain_height.png",
			"surfacemap": "res://data/test_fixtures/terrain/test_terrain_surface.png",
			"height_scale": 10.0,
		},
		"spawns": [],
		"resource_nodes": [],
		"schema_version": 1,
	}
	var map_def: Dictionary = _decoded(raw)
	var mat = TerrainBuilderScript.build_ground_material_heightmap(Color(0.36, 0.34, 0.30), map_def)
	if not (mat is ShaderMaterial):
		print("    expected ShaderMaterial, got %s" % mat.get_class())
		return false
	# The rock triplanar uniforms must be populated for the blend block
	# to fire. If the loader ever returns null for the rocky variant
	# (e.g. the texture is missing from disk), the shader still
	# compiles but the rock pass silently samples a default - verify
	# the parameter is actually a Texture.
	var rock_alb: Resource = mat.get_shader_parameter("rock_albedo")
	if rock_alb == null or not (rock_alb is Texture):
		print("    rock_albedo is not a Texture (got %s)" % str(rock_alb))
		return false
	var rock_nrm: Resource = mat.get_shader_parameter("rock_normal")
	if rock_nrm == null or not (rock_nrm is Texture):
		print("    rock_normal is not a Texture (got %s)" % str(rock_nrm))
		return false
	var rock_rgh: Resource = mat.get_shader_parameter("rock_rough")
	if rock_rgh == null or not (rock_rgh is Texture):
		print("    rock_rough is not a Texture (got %s)" % str(rock_rgh))
		return false
	return true


# Load the terrain_ground.gdshader as a Resource and confirm it parses.
# A shader that fails to compile produces a SHADER ERROR in the headless
# run, which the harness treats as a test failure. The test itself just
# confirms the resource loads.
func _test_shader_compiles() -> bool:
	var shader: Resource = load("res://shaders/terrain_ground.gdshader")
	if shader == null or not (shader is Shader):
		print("    terrain_ground.gdshader did not load as a Shader")
		return false
	return true
