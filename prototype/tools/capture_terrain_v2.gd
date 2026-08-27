extends SceneTree
# Renders a map's terrain to a PNG at the ACTUAL in-game light level.
#
# Deliberately NOT the whole match: this builds only the ground mesh, its
# material, and the terrain dressing, under an environment copied from
# Battle.tscn plus the map's own `environment` block. That is everything the
# terrain brief asks to be judged, with none of the HUD, units or AI in the
# way - and it boots in seconds instead of going through the whole match
# loading path.
#
# MUST run WITHOUT --headless (it needs a rendering device):
#   Godot_v4.7.1-stable_win64.exe --path <prototype>
#     --script res://tools/capture_terrain_v2.gd --
#     --map <id> --out <abs.png> [--at x,y,z] [--eye x,y,z]

const TerrainBuilderScript = preload("res://scripts/terrain_builder.gd")
const MapCatalogScript = preload("res://scripts/map_catalog.gd")

# Mirrors scenes/Battle.tscn's Environment_bt / DirectionalLight3D. Kept as
# explicit values rather than instancing Battle.tscn, because instancing it
# would also start match_director and run a whole skirmish.
const TONEMAP_EXPOSURE := 0.9
const AMBIENT_COLOR := Color(0.45, 0.50, 0.55)
const AMBIENT_SUN_ENERGY := 0.15
const SUN_ENERGY_DEFAULT := 0.7
const SSAO_RADIUS := 0.5
const SSAO_INTENSITY := 1.0
const GLOW_INTENSITY := 0.4
const GLOW_BLOOM := 0.04
const ADJ_SATURATION := 1.05
const ADJ_CONTRAST := 1.02

var _out := "terrain_v2.png"
var _map_id := "sentinel_divide"
var _at := Vector3(-240.0, 8.0, 150.0)
var _eye := Vector3(140.0, 150.0, 260.0)  # offset from _at
var _frames := 0
var _armed := false


func _arg(name: String, def: String) -> String:
	var a := OS.get_cmdline_user_args()
	for i in range(a.size()):
		if a[i] == name and i + 1 < a.size():
			return a[i + 1]
	return def


func _vec(s: String, def: Vector3) -> Vector3:
	var p := s.split(",")
	if p.size() != 3:
		return def
	return Vector3(float(p[0]), float(p[1]), float(p[2]))


func _initialize() -> void:
	_map_id = _arg("--map", _map_id)
	_out = _arg("--out", _out)
	_at = _vec(_arg("--at", ""), _at)
	_eye = _vec(_arg("--eye", ""), _eye)

	var map_def: Dictionary = MapCatalogScript.get_map(_map_id)
	var env_data: Dictionary = map_def.get("environment", {})
	print("[capture] map=%s generator=%s" % [_map_id, TerrainBuilderScript.terrain_generator(map_def)])

	var vp := root
	vp.transparent_bg = false
	DisplayServer.window_set_size(Vector2i(1600, 900))

	var world := Node3D.new()
	world.name = "TerrainWorld"
	vp.add_child(world)

	# --- environment ------------------------------------------------------
	var we := WorldEnvironment.new()
	var env := Environment.new()
	env.background_mode = Environment.BG_SKY
	var sky := Sky.new()
	var sky_mat := ProceduralSkyMaterial.new()
	if env_data.has("sky_color"):
		sky_mat.sky_top_color = env_data["sky_color"]
	if env_data.has("horizon_color"):
		sky_mat.sky_horizon_color = env_data["horizon_color"]
		# ProceduralSkyMaterial's GROUND hemisphere defaults to a pale grey,
		# and an RTS camera looks down - so the bright band under the horizon
		# in these captures was the sky's own ground, not the map's. Tie it to
		# the horizon colour or the calibration reads against the wrong sky.
		sky_mat.ground_horizon_color = env_data["horizon_color"]
		sky_mat.ground_bottom_color = Color(env_data["horizon_color"]).darkened(0.45)
	sky.sky_material = sky_mat
	env.sky = sky
	env.tonemap_mode = Environment.TONE_MAPPER_AGX
	env.tonemap_exposure = float(env_data.get("tonemap_exposure", TONEMAP_EXPOSURE))
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = env_data.get("ambient_light_color", AMBIENT_COLOR)
	env.ambient_light_sky_contribution = 0.0
	env.ambient_light_energy = float(env_data.get("ambient_light_energy", 1.0))
	env.ssao_enabled = true
	env.ssao_radius = SSAO_RADIUS
	env.ssao_intensity = SSAO_INTENSITY
	env.glow_enabled = true
	env.glow_intensity = GLOW_INTENSITY
	env.glow_bloom = GLOW_BLOOM
	env.sdfgi_enabled = false
	env.adjustment_enabled = true
	env.adjustment_saturation = ADJ_SATURATION
	env.adjustment_contrast = ADJ_CONTRAST
	if env_data.get("fog_enabled", false):
		env.fog_enabled = true
		env.fog_density = float(env_data.get("fog_density", 0.0002))
		env.fog_aerial_perspective = float(env_data.get("fog_aerial_perspective", 0.2))
	if env_data.has("volumetric_fog_enabled"):
		env.volumetric_fog_enabled = bool(env_data["volumetric_fog_enabled"])
		env.volumetric_fog_density = float(env_data.get("volumetric_fog_density", 0.0003))
	we.environment = env
	world.add_child(we)

	var sun := DirectionalLight3D.new()
	sun.light_energy = float(env_data.get("sun_energy", SUN_ENERGY_DEFAULT))
	if env_data.has("sun_color"):
		sun.light_color = env_data["sun_color"]
	sun.shadow_enabled = true
	sun.directional_shadow_max_distance = 900.0
	sun.rotation_degrees = Vector3(
		-float(env_data.get("sun_elevation_deg", 39.0)),
		float(env_data.get("sun_azimuth_deg", 35.0)), 0.0)
	world.add_child(sun)

	# --- terrain ----------------------------------------------------------
	var t0 := Time.get_ticks_msec()
	var generated: Dictionary = await TerrainBuilderScript.build_ground_visual_mesh(map_def, null)
	var mi := MeshInstance3D.new()
	mi.name = "Ground"
	mi.mesh = generated.mesh
	mi.material_override = TerrainBuilderScript.build_ground_material_for(
		map_def.get("ground_color", Color(0.2, 0.26, 0.21)), map_def, _map_id)
	world.add_child(mi)
	print("[capture] ground mesh + material: %d ms" % (Time.get_ticks_msec() - t0))

	# --no-props isolates the GROUND. spawn_visuals with a null ticker runs
	# fully synchronously - 162 s and ~3900 nodes on a map this size - which is
	# far too slow a loop for judging a shader, and the props hide the surface
	# being judged anyway.
	if "--no-props" in OS.get_cmdline_user_args():
		print("[capture] props SKIPPED")
	else:
		var t1 := Time.get_ticks_msec()
		await TerrainBuilderScript.spawn_visuals(map_def, world, null)
		print("[capture] terrain dressing: %d ms, %d children" % [Time.get_ticks_msec() - t1, world.get_child_count()])

	# --refplane drops calibration patches of KNOWN albedo beside the target.
	# "The ground is too dark" has two possible causes - the terrain shader is
	# producing a dark albedo, or the scene lighting/tonemap is crushing
	# everything - and they need completely different fixes. A surface whose
	# albedo is known settles it: if the 50% patch renders bright and the
	# terrain does not, the shader is at fault; if both are dark, the light is.
	if "--refplane" in OS.get_cmdline_user_args():
		var shades := [0.18, 0.50, 1.0]
		for i in range(shades.size()):
			var pm := PlaneMesh.new()
			pm.size = Vector2(70, 70)
			var pmi := MeshInstance3D.new()
			pmi.mesh = pm
			var sm := StandardMaterial3D.new()
			# albedo_color is sRGB-authored; these are the linear values the
			# BRDF should see, so convert to keep the label honest.
			var lin: float = shades[i]
			sm.albedo_color = Color(lin, lin, lin).linear_to_srgb()
			sm.roughness = 1.0
			sm.specular_mode = BaseMaterial3D.SPECULAR_DISABLED
			pmi.material_override = sm
			pmi.position = Vector3(_at.x - 110.0 + i * 80.0, TerrainBuilderScript.height_at(
				map_def, _at.x - 110.0 + i * 80.0, _at.z + 60.0) + 0.4, _at.z + 60.0)
			world.add_child(pmi)
		print("[capture] reference patches at linear albedo 0.18 / 0.50 / 1.00")

	# --- camera -----------------------------------------------------------
	var cam := Camera3D.new()
	cam.fov = 45.0
	cam.far = 4000.0
	cam.position = _at + _eye
	cam.look_at(_at, Vector3.UP)
	world.add_child(cam)
	cam.current = true
	print("[capture] camera at %s looking at %s" % [cam.position, _at])
	_armed = true


func _process(_delta: float) -> bool:
	if not _armed:
		return false
	_frames += 1
	# Let shadows, SSAO and the sky settle before grabbing the frame.
	if _frames < 30:
		return false
	var img := root.get_texture().get_image()
	img.save_png(_out)
	# Report the value distribution, since "is it crushed to black" is the
	# actual question and eyeballing a thumbnail does not answer it.
	var w := img.get_width()
	var h := img.get_height()
	var buckets := PackedInt32Array()
	buckets.resize(10)
	var total := 0
	for y in range(0, h, 3):
		for x in range(0, w, 3):
			var c := img.get_pixel(x, y)
			var l: float = 0.2126 * c.r + 0.7152 * c.g + 0.0722 * c.b
			buckets[clampi(int(l * 10.0), 0, 9)] += 1
			total += 1
	var line := ""
	for i in range(10):
		line += "%d%%-%d%%:%.1f%%  " % [i * 10, (i + 1) * 10, 100.0 * float(buckets[i]) / float(maxi(total, 1))]
	print("[capture] wrote %s" % _out)
	print("[capture] luminance histogram: %s" % line)
	print("[capture] below 5%% luminance: %.1f%%" % (100.0 * float(buckets[0]) / float(maxi(total, 1))))
	quit(0)
	return true
