extends RefCounted
class_name VFXEffects
# Textured, GPU-simulated combat VFX: flame, smoke, and projected ground
# scorch. The companion to vfx_burst.gd, which covers short MESH-particle
# bursts (sparks, debris, muzzle flash); this file covers the effects that
# want a real texture instead of geometry.
#
# WHY THIS EXISTS. auto_weapon.gd builds its continuous effects out of solid
# primitive meshes: _fire_flame_spray() allocates six MeshInstance3D spheres
# and six Tweens PER SHOT, and at the flamethrower's 0.06s fire rate that is
# ~100 nodes and ~100 tweens created and destroyed per second, per weapon,
# all on the main thread. There are 33 MeshInstance3D.new() and 30
# create_tween() sites in that file in the same style. Beyond the cost, a
# cluster of shaded spheres simply does not read as fire - fire has no
# surface, which is exactly why every engine draws it as textured billboards.
#
# THE APPROACH, in both cases the standard one:
#   - Flame/smoke are ONE GPUParticles3D with a flipbook-animated billboard
#     quad. The simulation runs on the GPU, the whole emitter is a single
#     draw call, and a continuous emitter (a flamethrower) allocates NOTHING
#     per shot - it just toggles `emitting`.
#   - Ground scorch/napalm is a Decal node, which projects onto whatever
#     geometry is beneath it and conforms to terrain contours for free. The
#     project had zero Decal nodes before this; hull_decals.gd raycasts hull
#     triangles to place oriented quads instead, which is the right call for
#     a curved hull and unnecessary machinery for ground splatter.
#
# Textures are generated procedurally by generate_effect_textures.py at the
# repo root (a 4x4 flipbook each for flame and smoke, plus scorch albedo and
# an ember emission mask), not authored by hand - same
# regenerate-from-source convention as tools/generate_terrain_textures.gd.
#
# Every material is cached per look and never mutated after creation, same
# rule (and same reason) as vfx_burst.gd: many live emitters share one
# resource, so mutating a cached material would stomp every other user.

const MunitionPool = preload("res://scripts/munition_pool.gd")

const FLAME_TEX = preload("res://assets/textures/effects/flame_flipbook.png")
const SMOKE_TEX = preload("res://assets/textures/effects/smoke_flipbook.png")
const SCORCH_EMISSION_TEX = preload("res://assets/textures/effects/scorch_emission.png")

# Ground-damage decal sets, each {albedo, normal, orm}.
#
# THREE channels, not just albedo. An albedo-only decal is a flat sticker: it
# never reacts to the scene light, so it reads as a texture painted on the
# floor no matter how well drawn. The normal map is what makes a crater rim
# catch the sun and a burn look like sunken, crusted ground, and it is by
# some margin the biggest quality win available here. The ORM map carries
# roughness, which is how a FRESH burn reads wet and glossy while old ash
# reads bone dry - the same silhouette telling you how recent the damage is.
#
# Several variants per kind because the RTS camera holds a dozen marks at
# once and one repeated silhouette is instantly legible as a repeat - the
# same reasoning terrain_builder.gd applies to its ground tiles.
const SCORCH_SETS := [
	{"albedo": preload("res://assets/textures/effects/scorch_0_albedo.png"),
	 "normal": preload("res://assets/textures/effects/scorch_0_normal.png"),
	 "orm": preload("res://assets/textures/effects/scorch_0_orm.png")},
	{"albedo": preload("res://assets/textures/effects/scorch_1_albedo.png"),
	 "normal": preload("res://assets/textures/effects/scorch_1_normal.png"),
	 "orm": preload("res://assets/textures/effects/scorch_1_orm.png")},
	{"albedo": preload("res://assets/textures/effects/scorch_2_albedo.png"),
	 "normal": preload("res://assets/textures/effects/scorch_2_normal.png"),
	 "orm": preload("res://assets/textures/effects/scorch_2_orm.png")},
]

const CRATER_SETS := [
	{"albedo": preload("res://assets/textures/effects/crater_0_albedo.png"),
	 "normal": preload("res://assets/textures/effects/crater_0_normal.png"),
	 "orm": preload("res://assets/textures/effects/crater_0_orm.png")},
	{"albedo": preload("res://assets/textures/effects/crater_1_albedo.png"),
	 "normal": preload("res://assets/textures/effects/crater_1_normal.png"),
	 "orm": preload("res://assets/textures/effects/crater_1_orm.png")},
]

# Both flipbooks are 4x4. Kept as constants rather than read off the image so
# a regenerated sheet with a different layout fails loudly here instead of
# silently animating garbage.
const FLIPBOOK_H := 4
const FLIPBOOK_V := 4

static var _quad: QuadMesh = null
static var _billboard_cache: Dictionary = {}   # key -> StandardMaterial3D
static var _process_cache: Dictionary = {}     # key -> ParticleProcessMaterial

# One shared unit quad for every billboard particle in the game. Particle
# scale is set per-emitter through the process material, so a single 1x1
# quad serves a pilot light and a napalm bloom alike.
static func _get_quad() -> QuadMesh:
	if _quad == null:
		_quad = QuadMesh.new()
		_quad.size = Vector2.ONE
	return _quad

# BILLBOARD_PARTICLES + particles_anim_* is what makes one quad play a
# flipbook: Godot advances the frame from each particle's own normalised
# lifetime, so a particle born now and one born ten frames ago show
# different cells of the sheet with no per-particle script work at all.
static func _billboard_material(tex: Texture2D, additive: bool, tint: Color) -> StandardMaterial3D:
	var key = "%s|%s|%s" % [tex.resource_path, str(additive), tint.to_html()]
	if _billboard_cache.has(key):
		return _billboard_cache[key]
	var mat = StandardMaterial3D.new()
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.albedo_texture = tex
	mat.albedo_color = tint
	mat.billboard_mode = BaseMaterial3D.BILLBOARD_PARTICLES
	mat.particles_anim_h_frames = FLIPBOOK_H
	mat.particles_anim_v_frames = FLIPBOOK_V
	# Each particle plays the sheet ONCE over its own lifetime rather than
	# cycling - a looping flame visibly restarts mid-air.
	mat.particles_anim_loop = false
	mat.vertex_color_use_as_albedo = true
	# Fire is emissive light, so it ADDS to what's behind it; smoke occludes,
	# so it blends normally. Getting this backwards is what makes engine fire
	# look like orange cellophane.
	if additive:
		mat.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
	# Never let a billboard z-fight or clip into the surface it sits on.
	mat.no_depth_test = false
	mat.depth_draw_mode = BaseMaterial3D.DEPTH_DRAW_DISABLED
	_billboard_cache[key] = mat
	return mat

static var _stream_scale_curve: CurveTexture = null
static func _get_stream_scale_curve() -> CurveTexture:
	if _stream_scale_curve == null:
		var curve = CurveTexture.new()
		var c = Curve.new()
		c.add_point(Vector2(0.0, 0.22))
		c.add_point(Vector2(0.25, 0.75))
		c.add_point(Vector2(0.60, 2.0))
		c.add_point(Vector2(0.90, 3.5))
		c.add_point(Vector2(1.0, 4.0))
		curve.curve = c
		_stream_scale_curve = curve
	return _stream_scale_curve

static func _process_material(key: String, direction: Vector3, spread: float,
		speed_min: float, speed_max: float, gravity: Vector3,
		scale_min: float, scale_max: float, damping: float = 0.0,
		turbulence: float = 0.0, turbulence_scale: float = 1.0,
		custom_scale_curve: CurveTexture = null) -> ParticleProcessMaterial:
	if _process_cache.has(key):
		return _process_cache[key]
	var mat = ParticleProcessMaterial.new()
	mat.direction = direction
	mat.spread = spread
	mat.initial_velocity_min = speed_min
	mat.initial_velocity_max = speed_max
	mat.gravity = gravity
	mat.scale_min = scale_min
	mat.scale_max = scale_max
	mat.damping_min = damping
	mat.damping_max = damping
	mat.angle_min = -180.0
	mat.angle_max = 180.0
	mat.anim_speed_min = 1.0
	mat.anim_speed_max = 1.0
	mat.anim_offset_min = 0.0
	mat.anim_offset_max = 0.3

	if custom_scale_curve != null:
		mat.scale_curve = custom_scale_curve
	else:
		# Particles shrink as they age - the flipbook already fades them out, and
		# scaling down as well is what sells a flame tapering rather than
		# vanishing at full size.
		var curve = CurveTexture.new()
		var c = Curve.new()
		c.add_point(Vector2(0.0, 0.35))
		c.add_point(Vector2(0.35, 1.0))
		c.add_point(Vector2(1.0, 0.15))
		curve.curve = c
		mat.scale_curve = curve

	# Godot 4.3's built-in turbulence: a noise field that pushes particles
	# around as they travel, evaluated on the GPU with the rest of the
	# simulation, so it costs nothing on the main thread.
	#
	# This is what stops a jet or a plume looking like particles on rails.
	# Spread alone fans them out in straight lines from the emitter; real fire
	# and smoke curl and tumble, and no amount of per-particle randomisation
	# at BIRTH reproduces that, because the motion has to keep changing over
	# the particle's life.
	if turbulence > 0.0:
		mat.turbulence_enabled = true
		mat.turbulence_noise_strength = turbulence
		mat.turbulence_noise_scale = turbulence_scale
		# A slow drift keeps two particles born in the same spot from
		# following identical paths.
		mat.turbulence_noise_speed = Vector3(0.4, 0.2, 0.4)
		mat.turbulence_influence_min = 0.4
		mat.turbulence_influence_max = 1.0

	_process_cache[key] = mat
	return mat


# --- Flamethrower Stream (Reference-accurate military liquid-fuel stream) ---

# Tight incandescent liquid fuel core jet that arcs through the air under gravity
static func make_flame_core_emitter(parent: Node3D, length: float = 11.0, width: float = 1.0, valve: float = 1.0) -> GPUParticles3D:
	var p = GPUParticles3D.new()
	p.name = "FlameCore"
	p.amount = 140
	p.lifetime = clampf(0.52 / maxf(valve, 0.5), 0.3, 0.7)
	p.emitting = false
	p.local_coords = true
	p.draw_pass_1 = _get_quad()
	p.material_override = _billboard_material(FLAME_TEX, true, Color(1.1, 0.75, 0.22, 0.95))
	var speed = (length / p.lifetime) * 1.05
	p.process_material = _process_material(
		"milspec_flame_core|%.1f|%.1f|%.2f" % [length, width, valve],
		Vector3(0, 0.20, -1.0).normalized(), 2.5 * width, speed * 0.92, speed,
		Vector3(0, -13.0 * valve, 0), 0.8 * width, 1.5 * width, 0.02, 0.35, 1.2,
		_get_stream_scale_curve())
	parent.add_child(p)
	return p

# Massive roiling outer flame envelope that billows from the liquid fuel
static func make_flame_emitter(parent: Node3D, length: float = 11.0, width: float = 1.0, valve: float = 1.0) -> GPUParticles3D:
	var p = GPUParticles3D.new()
	p.name = "FlameJet"
	p.amount = 110
	p.lifetime = clampf(0.60 / maxf(valve, 0.5), 0.35, 0.8)
	p.emitting = false
	p.local_coords = true
	p.draw_pass_1 = _get_quad()
	p.material_override = _billboard_material(FLAME_TEX, true, Color(0.95, 0.40, 0.06, 0.90))
	var speed = (length / p.lifetime) * 0.95
	p.process_material = _process_material(
		"milspec_flame_env|%.1f|%.1f|%.2f" % [length, width, valve],
		Vector3(0, 0.18, -1.0).normalized(), 4.5 * width, speed * 0.80, speed,
		Vector3(0, -10.0 * valve, 0), 1.4 * width, 2.5 * width, 0.10, 0.75, 1.4,
		_get_stream_scale_curve())
	parent.add_child(p)
	return p

# Thick black smoke that billows off the top of the fiery plume
static func make_flame_smoke_emitter(parent: Node3D, length: float = 11.0, valve: float = 1.0) -> GPUParticles3D:
	var p = GPUParticles3D.new()
	p.name = "FlameSmoke"
	p.amount = 50
	p.lifetime = 1.15
	p.emitting = false
	p.local_coords = true
	p.draw_pass_1 = _get_quad()
	p.material_override = _billboard_material(SMOKE_TEX, false, Color(0.10, 0.09, 0.08, 0.70))
	p.process_material = _process_material(
		"milspec_flamesmoke|%.1f|%.2f" % [length, valve],
		Vector3(0, 0.25, -1.0).normalized(), 8.0, length * 0.40, length * 0.75,
		Vector3(0, 3.2, 0), 1.8, 4.2, 0.8, 1.5, 1.2,
		_get_stream_scale_curve())
	parent.add_child(p)
	return p

const FLAME_ARC_SHADER = preload("res://assets/BinbunVFX_Vol2/FlameFX/shader/flame_arc.gdshader")
static var _flame_arc_mat: ShaderMaterial = null

static func get_flame_arc_material() -> ShaderMaterial:
	if _flame_arc_mat == null:
		var mat = ShaderMaterial.new()
		mat.shader = FLAME_ARC_SHADER
		var fnl = FastNoiseLite.new()
		fnl.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
		fnl.frequency = 0.02
		fnl.fractal_octaves = 2
		var noise_tex = NoiseTexture2D.new()
		noise_tex.noise = fnl
		noise_tex.seamless = true
		mat.set_shader_parameter("noise_texture", noise_tex)
		mat.set_shader_parameter("core_color", Color(1.15, 0.80, 0.26))
		mat.set_shader_parameter("flame_color", Color(0.95, 0.38, 0.04))
		mat.set_shader_parameter("edge_color", Color(0.45, 0.05, 0.01))
		mat.set_shader_parameter("smoke_color", Color(0.10, 0.09, 0.08))
		mat.set_shader_parameter("emission_strength", 1.8)
		mat.set_shader_parameter("scroll_speed", 9.0)
		mat.set_shader_parameter("turbulence_strength", 0.35)
		_flame_arc_mat = mat
	return _flame_arc_mat

static func update_flame_arc_mesh(im: ImmediateMesh, start_pos: Vector3, end_pos: Vector3, n_width: float = 1.0, valve: float = 1.0) -> void:
	im.clear_surfaces()
	var dist = start_pos.distance_to(end_pos)
	if dist <= 0.2:
		return

	var N = 22
	var max_arc = clampf(dist * 0.16 * valve, 0.35, 2.5)

	var pts: Array[Vector3] = []
	var tangents: Array[Vector3] = []

	for i in range(N + 1):
		var t = float(i) / float(N)
		var p = start_pos.lerp(end_pos, t)
		var arc_h = 4.0 * t * (1.0 - t) * max_arc
		p.y += arc_h
		pts.append(p)

	for i in range(N + 1):
		if i == 0:
			tangents.append((pts[1] - pts[0]).normalized())
		elif i == N:
			tangents.append((pts[N] - pts[N - 1]).normalized())
		else:
			tangents.append((pts[i + 1] - pts[i - 1]).normalized())

	var mat = get_flame_arc_material()

	# 3-Plane Volumetric Cross-Ribbon (0°, 60°, 120°)
	var angles = [0.0, PI / 3.0, (2.0 * PI) / 3.0]
	for angle in angles:
		im.surface_begin(Mesh.PRIMITIVE_TRIANGLE_STRIP, mat)
		for i in range(N + 1):
			var t = float(i) / float(N)
			# Exponential expansion profile matching military liquid flamethrower reference
			var width = lerpf(0.25, 3.4, pow(t, 0.70)) * n_width
			var p = pts[i]
			var tang = tangents[i]
			
			var side = tang.cross(Vector3.UP).normalized()
			if side.length_squared() < 0.01:
				side = tang.cross(Vector3.FORWARD).normalized()
			var vert = side.cross(tang).normalized()

			var plane_normal = (side * cos(angle) + vert * sin(angle)).normalized()
			var offset_vec = plane_normal * (width * 0.5)
			
			var p_left = p - offset_vec
			var p_right = p + offset_vec
			
			im.surface_set_normal(plane_normal)
			im.surface_set_uv(Vector2(0.0, t))
			im.surface_add_vertex(p_left)

			im.surface_set_normal(plane_normal)
			im.surface_set_uv(Vector2(1.0, t))
			im.surface_add_vertex(p_right)
		im.surface_end()


# --- Target burning (DoT flame clinging to hit vehicles and structures) --
#
# Attaches persistent burning flame + smoke particles to a target node.
# Reuses the existing TargetBurnVFX node if already present, extending its
# lifetime so continuous flame keeps the target burning without duplicating
# nodes.
static func attach_target_burn(target: Node3D, duration: float = 3.0, intensity: float = 1.0) -> Node3D:
	if not is_instance_valid(target):
		return null

	var tree: SceneTree = target.get_tree() if target.is_inside_tree() else null
	if tree == null:
		var main_loop = Engine.get_main_loop()
		if main_loop is SceneTree:
			tree = main_loop

	var existing = target.get_node_or_null("TargetBurnVFX")
	if existing != null and is_instance_valid(existing):
		existing.set_meta("burn_until", Time.get_ticks_msec() + int(duration * 1000.0))
		for child in existing.get_children():
			if child is GPUParticles3D:
				child.emitting = true
		return existing

	var root = Node3D.new()
	root.name = "TargetBurnVFX"
	target.add_child(root)

	# Position near the target center/top
	if target.has_method("get_nearest_surface_point"):
		root.position = Vector3(0, 0.4, 0)

	# Flames licking up from the target
	var flames = GPUParticles3D.new()
	flames.name = "BurnFlames"
	flames.amount = int(clampf(24.0 * intensity, 12.0, 48.0))
	flames.lifetime = 0.65
	flames.local_coords = false
	flames.draw_pass_1 = _get_quad()
	flames.material_override = _billboard_material(FLAME_TEX, true, Color(1.0, 0.65, 0.18, 0.95))
	flames.process_material = _process_material(
		"targetburn_flames|%.1f" % intensity,
		Vector3(0, 1, 0), 32.0, 0.8, 2.2,
		Vector3(0, 2.0, 0), 0.6 * intensity, 1.4 * intensity, 0.5, 1.2, 0.8)
	root.add_child(flames)
	flames.emitting = true

	# Dense smoke rising from the target
	var smoke = GPUParticles3D.new()
	smoke.name = "BurnSmoke"
	smoke.amount = int(clampf(14.0 * intensity, 8.0, 28.0))
	smoke.lifetime = 1.2
	smoke.local_coords = false
	smoke.draw_pass_1 = _get_quad()
	smoke.material_override = _billboard_material(SMOKE_TEX, false, Color(0.15, 0.14, 0.13, 0.55))
	smoke.process_material = _process_material(
		"targetburn_smoke|%.1f" % intensity,
		Vector3(0, 1, 0), 24.0, 1.2, 2.6,
		Vector3(0, 2.6, 0), 0.8 * intensity, 1.8 * intensity, 0.6, 1.8, 1.0)
	root.add_child(smoke)
	smoke.emitting = true

	root.set_meta("burn_until", Time.get_ticks_msec() + int(duration * 1000.0))

	if tree != null:
		var check_timer = tree.create_timer(duration)
		var update_check: Callable
		update_check = func():
			if not is_instance_valid(root) or not is_instance_valid(target):
				return
			var remaining = root.get_meta("burn_until", 0) - Time.get_ticks_msec()
			if remaining > 50:
				tree.create_timer(float(remaining) / 1000.0).timeout.connect(update_check)
				return
			flames.emitting = false
			smoke.emitting = false
			var drain_timer = tree.create_timer(1.3)
			drain_timer.timeout.connect(func():
				if is_instance_valid(root):
					root.queue_free()
			)

		check_timer.timeout.connect(update_check)
	return root


# Dense grey smoke trail behind a missile in flight. Parent to the missile
# node with local_coords on so it follows the body; position at the rear
# end (+Z). Created once in _ready(), emitting toggled off on destruction
# and the emitter freed once the last particle drains.
# `bulk` scales the plume without forking the function: 1.0 is the guided
# missile_pod rocket, and rocket artillery asks for more. It multiplies count,
# lifetime and puff size together, because raising any one alone reads wrong -
# more particles at the same size is grainy, bigger particles at the same count
# is lumpy, and a longer lifetime alone just leaves a thin streak hanging.
#
# The cache key has to carry `bulk`. _process_material() memoises on its key
# string, so two different bulks under one key silently hand the second caller
# the first one's material - which is precisely how the artillery ends up with
# the pod's trail and nothing appears to change.
static func make_missile_trail(parent: Node3D, bulk: float = 1.0) -> GPUParticles3D:
	var p = GPUParticles3D.new()
	p.name = "MissileTrail"
	p.amount = int(clampf(120.0 * bulk, 24.0, 600.0))
	p.lifetime = clampf(1.0 * sqrt(bulk), 0.5, 3.0)
	p.emitting = false
	p.local_coords = false
	p.draw_pass_1 = _get_quad()
	p.material_override = _billboard_material(SMOKE_TEX, false, Color(0.8, 0.8, 0.8, 0.7)) # brighter thicker smoke
	p.process_material = _process_material(
		"missile_trail_thick|%.2f" % bulk,
		Vector3(0, 0, 1), 10.0, 0.5, 1.5,
		Vector3(0, 0.5, 0), 0.3 * bulk, 0.8 * bulk, 1.0, 1.5, 1.0)
	parent.add_child(p)
	p.emitting = true
	return p


# Directional muzzle flash using textured flame flipbooks (stabbing tongue of flame)
static func muzzle_flash(parent: Node3D, local_pos: Vector3, forward_dir: Vector3, radius: float = 1.0, tint: Color = Color(1, 0.8, 0.3, 1), light_color: Color = Color(0, 0, 0, 0), light_range: float = 4.0, light_energy: float = 5.0) -> GPUParticles3D:
	var p = GPUParticles3D.new()
	p.name = "MuzzleFlash"
	p.amount = int(clampf(radius * 20.0, 12, 36))
	p.lifetime = 0.15
	p.one_shot = true
	p.explosiveness = 1.0
	p.emitting = false
	p.local_coords = true
	p.draw_pass_1 = _get_quad()
	p.material_override = _billboard_material(FLAME_TEX, true, tint)
	
	# Narrow spread, high speed forward to create a "stabbing tongue"
	p.process_material = _process_material(
		"muzzleflash|%.1f" % radius,
		forward_dir.normalized(), 12.0, radius * 12.0, radius * 22.0,
		Vector3(0, 0, 0), radius * 0.4, radius * 1.5, 2.0, 0.0, 0.0)
	
	parent.add_child(p)
	p.position = local_pos
	p.emitting = true
	p.finished.connect(func():
		if is_instance_valid(p):
			p.queue_free())

	if light_color.a > 0.0:
		var light = OmniLight3D.new()
		light.light_color = Color(light_color.r, light_color.g, light_color.b)
		light.light_energy = light_energy
		light.omni_range = light_range
		light.omni_attenuation = 0.5
		light.light_bake_mode = Light3D.BAKE_DISABLED
		parent.add_child(light)
		light.position = local_pos
		var lt = parent.create_tween()
		lt.tween_property(light, "light_energy", 0.0, 0.12)
		lt.finished.connect(func(): if is_instance_valid(light): light.queue_free())

	return p


# Thin grey trickle off a module knocked below its damage threshold
# (module_damage_fx.gd). Continuous like the flame jet, not a one-shot puff:
# the wound keeps smoking until the module is stripped, so the emitter is
# created once, parented to the caller - the damaged MODULE - with
# local_coords on, and rides the vehicle. Nothing ever toggles it; freeing the
# module frees it. `intensity` scales amount/speed/size with the module's bulk
# and is part of both cache keys, keeping the never-mutate-a-cached-material
# rule intact.
static func make_damage_smoke(parent: Node3D, intensity: float = 1.0) -> GPUParticles3D:
	var p = GPUParticles3D.new()
	p.name = "DamageSmoke"
	p.amount = int(clampf(10.0 * intensity, 6, 18))
	p.lifetime = 1.6
	p.emitting = false
	p.local_coords = true
	p.draw_pass_1 = _get_quad()
	p.material_override = _billboard_material(SMOKE_TEX, false, Color(0.18, 0.17, 0.16, 0.45))
	p.process_material = _process_material(
		"damagesmoke|%.2f" % intensity,
		Vector3(0, 1, 0), 24.0, 0.6 * intensity, 1.2 * intensity,
		Vector3(0, 0.6, 0), 0.45 * intensity, 1.0 * intensity, 0.8, 1.6, 0.7)
	parent.add_child(p)
	p.emitting = true
	return p


# --- One-shot puffs -----------------------------------------------------

# A single burst of smoke (impact, wreck, cover). one_shot + `finished`
# self-cleanup, same lifecycle rule vfx_burst.spawn() uses - no guessed
# timers.
static func smoke_puff(parent: Node3D, world_pos: Vector3, radius: float = 1.5,
		amount: int = 12, tint: Color = Color(0.3, 0.29, 0.28, 0.55)) -> GPUParticles3D:
	var p = GPUParticles3D.new()
	p.name = "SmokePuff"
	p.amount = amount
	p.lifetime = 1.4
	p.one_shot = true
	p.explosiveness = 0.85
	p.emitting = false
	p.draw_pass_1 = _get_quad()
	p.material_override = _billboard_material(SMOKE_TEX, false, tint)
	p.process_material = _process_material(
		"puff|%.1f" % radius,
		Vector3(0, 1, 0), 75.0, radius * 0.8, radius * 1.6,
		Vector3(0, 0.8, 0), radius * 0.9, radius * 1.7, 1.6, 2.2, 0.8)
	parent.add_child(p)
	p.global_position = world_pos
	p.emitting = true
	p.finished.connect(func():
		if is_instance_valid(p):
			p.queue_free())
	return p


# One-shot fireball burst for weapon impacts — the particle-driven replacement
# for the old MeshInstance3D scaling sphere. Additive flame quads read as a
# bright flash at RTS zoom and dissipate with the flipbook rather than
# popping to zero size.
static func fire_burst(parent: Node3D, world_pos: Vector3, radius: float = 1.0,
		tint: Color = Color(1, 0.8, 0.3, 1)) -> GPUParticles3D:
	var p = GPUParticles3D.new()
	p.name = "FireBurst"
	p.amount = int(clampf(radius * 10.0, 6, 24))
	p.lifetime = 0.35
	p.one_shot = true
	p.explosiveness = 0.9
	p.emitting = false
	p.draw_pass_1 = _get_quad()
	p.material_override = _billboard_material(FLAME_TEX, true, tint)
	p.process_material = _process_material(
		"fireburst|%.1f" % radius,
		Vector3(0, 1, 0), 65.0, radius * 1.5, radius * 3.5,
		Vector3(0, 2.0, 0), radius * 0.5, radius * 1.2, 1.2, 2.2, 0.8)
	parent.add_child(p)
	p.global_position = world_pos
	p.emitting = true
	p.finished.connect(func():
		if is_instance_valid(p):
			p.queue_free())
	return p


# Persistent billowing black diesel smoke plume rising from a destroyed vehicle carcass.
static func wreck_smoke_column(parent: Node3D, world_pos: Vector3, duration: float = 60.0, height: float = 12.0) -> GPUParticles3D:
	var p = GPUParticles3D.new()
	p.name = "WreckSmokeColumn"
	p.amount = 28
	p.lifetime = 2.8
	p.emitting = false
	p.draw_pass_1 = _get_quad()
	p.material_override = _billboard_material(SMOKE_TEX, false, Color(0.12, 0.11, 0.10, 0.75))
	var speed = height / p.lifetime
	p.process_material = _process_material(
		"wrecksmoke|%.1f" % height,
		Vector3(0, 1, 0), 28.0, speed * 0.7, speed * 1.2,
		Vector3(0.5, 0.8, 0.2), 2.2, 5.0, 0.4, 2.8, 1.4)
	parent.add_child(p)
	p.global_position = world_pos
	p.emitting = true
	_stop_and_free_after(p, duration)
	return p


# Internal flickering fire escaping from an engine bay or breached hull.
static func wreck_fire(parent: Node3D, world_pos: Vector3, duration: float = 45.0, radius: float = 1.2) -> GPUParticles3D:
	var p = GPUParticles3D.new()
	p.name = "WreckFire"
	p.amount = 18
	p.lifetime = 0.85
	p.emitting = false
	p.draw_pass_1 = _get_quad()
	p.material_override = _billboard_material(FLAME_TEX, true, Color(1, 0.8, 0.4, 1))
	p.process_material = _process_material(
		"wreckfire|%.1f" % radius,
		Vector3(0, 1, 0), 22.0, 1.5, 3.2,
		Vector3(0, 1.8, 0), radius * 0.8, radius * 1.8, 0.6, 2.2, 1.0)
	parent.add_child(p)
	p.global_position = world_pos
	p.emitting = true
	_stop_and_free_after(p, duration)
	return p


# Flames licking up off a burning area (a napalm pool, a wreck). Emits for
# `duration` and then frees itself - a pool that outlives its weapon needs a
# visual that outlives it too, which is why this parents to the caller's
# chosen node (the scene root) rather than to the gun.
static func fire_pool(parent: Node3D, world_pos: Vector3, radius: float, duration: float) -> GPUParticles3D:
	var p = GPUParticles3D.new()
	p.name = "FirePool"
	p.amount = int(clamp(radius * 10.0, 14, 60))
	p.lifetime = 0.9
	p.emitting = false
	p.draw_pass_1 = _get_quad()
	p.material_override = _billboard_material(FLAME_TEX, true, Color(1, 1, 1, 1))
	var mat = _process_material(
		"firepool|%.1f" % radius,
		Vector3(0, 1, 0), 18.0, 1.2, 2.6,
		Vector3(0, 1.6, 0), radius * 0.9, radius * 1.5, 0.8, 1.9, 1.2)
	# Emit across the whole pool footprint rather than from a point, so a wide
	# pool burns across its area instead of as one central bonfire. Assigning
	# unconditionally is safe despite the never-mutate-a-cached-material rule
	# in this file's header, because `radius` is part of the cache key - every
	# caller that reaches a given cached material writes the identical value.
	mat.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_BOX
	mat.emission_box_extents = Vector3(radius * 0.8, 0.1, radius * 0.8)
	p.process_material = mat
	parent.add_child(p)
	p.global_position = world_pos
	p.emitting = true
	_stop_and_free_after(p, duration)
	return p

# GPUParticles3D has no "emit for N seconds then stop" of its own, and a
# one_shot burst is the wrong shape for a pool that burns for many seconds.
# Stop emitting at `duration`, then free once the last particle has aged out.
static func _stop_and_free_after(p: GPUParticles3D, duration: float) -> void:
	var stop = p.create_tween()
	stop.tween_interval(max(duration, 0.05))
	stop.finished.connect(func():
		if not is_instance_valid(p):
			return
		p.emitting = false
		var drain = p.create_tween()
		drain.tween_interval(p.lifetime + 0.1)
		drain.finished.connect(func():
			if is_instance_valid(p):
				p.queue_free()))


# --- Building placement dust --------------------------------------------
#
# A ring of yellow-brown dust puffs spawned when a structure is placed.
# Draws the eye away from terrain intersection at the building's edges
# (especially noticeable under refinery dock bays) without modifying the
# terrain mesh. The puffs expand, drift upward, and despawn.
static func dust_cloud(parent: Node3D, center: Vector3, half_extents: Vector2) -> void:
	const PERIMETER_COUNT := 10
	const CENTER_COUNT := 4
	const DUST_COLOR := Color(0.62, 0.58, 0.50, 0.5)
	const TOTAL_LIFE := 2.0
	const FADE_START := 0.9
	const BLOOM_TIME := 0.3

	var mesh := MunitionPool.unit_sphere()
	var mat := MunitionPool.alpha(DUST_COLOR)
	var puffs: Array[MeshInstance3D] = []
	# Scale puffs relative to the building footprint so they're visible at
	# RTS zoom. The unit_sphere has radius 0.5 (diameter 1.0), so a scale
	# of 2.0 gives a 2.0m-diameter puff — visible against a 6-12m building.
	var foot_span: float = maxf(half_extents.x, half_extents.y) * 2.0
	var puff_size: float = clampf(foot_span * 0.18, 1.2, 3.0)

	# Perimeter puffs along the building edges.
	for i in range(PERIMETER_COUNT):
		var puff := MeshInstance3D.new()
		puff.mesh = mesh
		puff.material_override = mat
		parent.add_child(puff)
		var t := float(i) / float(PERIMETER_COUNT)
		var edge_pos := Vector3(
			center.x + lerpf(-half_extents.x, half_extents.x, fmod(t * 2.0, 1.0)),
			center.y + 0.2,
			center.z + (half_extents.y if t < 0.5 else -half_extents.y) * (1.0 if t < 0.25 or t >= 0.75 else -1.0))
		if t < 0.25:
			edge_pos.x = center.x - half_extents.x
			edge_pos.z = center.z + lerpf(-half_extents.y, half_extents.y, t * 4.0)
		elif t < 0.5:
			edge_pos.x = center.x + lerpf(-half_extents.x, half_extents.x, (t - 0.25) * 4.0)
			edge_pos.z = center.z + half_extents.y
		elif t < 0.75:
			edge_pos.x = center.x + half_extents.x
			edge_pos.z = center.z + lerpf(half_extents.y, -half_extents.y, (t - 0.5) * 4.0)
		else:
			edge_pos.x = center.x + lerpf(half_extents.x, -half_extents.x, (t - 0.75) * 4.0)
			edge_pos.z = center.z - half_extents.y
		edge_pos.x += randf_range(-0.6, 0.6)
		edge_pos.z += randf_range(-0.6, 0.6)
		puff.position = edge_pos
		var base_scale := puff_size * randf_range(0.8, 1.2)
		puff.scale = Vector3.ONE * base_scale
		puffs.append(puff)

	# Center puffs under the building for density.
	for i in range(CENTER_COUNT):
		var puff := MeshInstance3D.new()
		puff.mesh = mesh
		puff.material_override = mat
		parent.add_child(puff)
		puff.position = Vector3(
			center.x + randf_range(-half_extents.x * 0.5, half_extents.x * 0.5),
			center.y + 0.15,
			center.z + randf_range(-half_extents.y * 0.5, half_extents.y * 0.5))
		var base_scale := puff_size * randf_range(0.9, 1.4)
		puff.scale = Vector3.ONE * base_scale
		puffs.append(puff)

	# Animate: bloom in, drift upward, shrink out, then free.
	for puff in puffs:
		var base_pos: Vector3 = puff.position
		var base_scale: float = puff.scale.x
		var drift := Vector3(randf_range(-0.15, 0.15), randf_range(0.3, 0.8), randf_range(-0.15, 0.15))
		var stagger := randf_range(0.0, 0.25)
		var dt := puff.create_tween()
		# Stagger before bloom in.
		puff.scale = Vector3.ZERO
		dt.tween_interval(stagger)
		# Bloom in.
		dt.tween_property(puff, "scale", Vector3.ONE * base_scale, BLOOM_TIME)
		# Drift upward for the remaining life.
		dt.parallel().tween_property(puff, "position", base_pos + drift * TOTAL_LIFE, TOTAL_LIFE - stagger)
		# Shrink out over the last portion of life. Scale to zero is the
		# standard 3D fade pattern in this codebase — modulate is
		# CanvasItem-only and does not exist on Node3D / MeshInstance3D.
		var shrink_delay: float = FADE_START - stagger
		if shrink_delay > 0.0:
			dt.tween_interval(shrink_delay)
		dt.tween_property(puff, "scale", Vector3.ZERO, maxf(TOTAL_LIFE - FADE_START, 0.1))
		dt.finished.connect(func():
			if is_instance_valid(puff):
				puff.queue_free())


# --- Ground scorch / burning pool --------------------------------------
#
# A Decal, not a flat MeshInstance3D laid on the ground. The difference
# matters on this game's terrain specifically: every map has real elevation
# (terrain_builder.gd's heightmap/hills), so a quad placed at one Y either
# floats above a slope or sinks into it, while a Decal projects down its
# local -Y and wraps whatever is actually there.
#
# `burn_seconds` > 0 makes it a live napalm pool first: the ember emission
# map glows and then fades to nothing, leaving the cold scorch albedo
# behind. Same decal, same texture pair, one animated property - which is
# why the generator emits a matching emission mask instead of a second
# scorch texture.
static func scorch(parent: Node3D, world_pos: Vector3, radius: float = 3.0,
		burn_seconds: float = 0.0, fade_seconds: float = 14.0) -> Decal:
	var d = _ground_decal(parent, world_pos, radius, SCORCH_SETS[randi() % SCORCH_SETS.size()])
	d.name = "Scorch"

	if burn_seconds > 0.0:
		d.texture_emission = SCORCH_EMISSION_TEX
		d.emission_energy = 2.6
		var burn = d.create_tween()
		burn.tween_property(d, "emission_energy", 0.0, burn_seconds)

	# Then the mark itself weathers away, so a long match doesn't accumulate
	# unbounded decals - each one frees itself.
	var fade = d.create_tween()
	fade.tween_interval(max(burn_seconds, 0.0))
	# Decal inherits Node3D, which has no modulate property. Shrink to
	# zero instead — same pattern as dust_cloud and every other Mesh-
	# based VFX in this codebase.
	fade.tween_property(d, "scale", Vector3.ZERO, fade_seconds)
	fade.finished.connect(func():
		if is_instance_valid(d):
			d.queue_free())
	return d


# An impact crater: displaced earth, not a surface stain.
#
# Kept separate from scorch() rather than being a recoloured variant of it,
# because the difference between the two lives almost entirely in the normal
# map - a burn is flat ground that changed colour, a crater is a bowl with a
# raised rim. That distinction only became expressible once decals carried a
# normal map at all.
#
# Craters persist much longer than burns by default: a shell hole is terrain
# damage, and a battlefield that remembers where it was shelled is most of
# the reason to have ground decals.
static func crater(parent: Node3D, world_pos: Vector3, radius: float = 2.0,
		fade_seconds: float = 45.0) -> Decal:
	var d = _ground_decal(parent, world_pos, radius, CRATER_SETS[randi() % CRATER_SETS.size()])
	d.name = "Crater"
	var fade = d.create_tween()
	fade.tween_interval(fade_seconds * 0.7)
	fade.tween_property(d, "scale", Vector3.ZERO, fade_seconds * 0.3)
	fade.finished.connect(func():
		if is_instance_valid(d):
			d.queue_free())
	return d


const MAX_ACTIVE_DECALS := 36
static var _active_decals: Array = []


static func _register_decal(d: Decal) -> void:
	for i in range(_active_decals.size() - 1, -1, -1):
		if not is_instance_valid(_active_decals[i]):
			_active_decals.remove_at(i)
	while _active_decals.size() >= MAX_ACTIVE_DECALS:
		var oldest: Decal = _active_decals.pop_front()
		if is_instance_valid(oldest):
			oldest.queue_free()
	_active_decals.append(d)


# Shared Decal setup for anything stamped on the ground.
static func _ground_decal(parent: Node3D, world_pos: Vector3, radius: float, set: Dictionary) -> Decal:
	var d = Decal.new()
	# size.y is the PROJECTION DEPTH (how far down the decal reaches), not a
	# visual height - it has to comfortably exceed local terrain relief or
	# the mark clips off the side of a slope.
	d.size = Vector3(radius * 2.0, max(4.0, radius), radius * 2.0)
	d.texture_albedo = set["albedo"]
	d.texture_normal = set["normal"]
	d.texture_orm = set["orm"]
	d.albedo_mix = 1.0
	# Stop the decal smearing down cliff faces: past ~60 degrees from the
	# projection axis a downward-projected mark is being stretched across a
	# near-vertical surface, which looks like a paint drip rather than damage.
	d.normal_fade = 0.55
	# Distant marks fade out - both a clutter control at RTS zoom and a real
	# saving, since every decal in view is extra shading work.
	d.distance_fade_enabled = true
	d.distance_fade_begin = 90.0
	d.distance_fade_length = 30.0
	# Random yaw so repeated hits in one area don't stamp an obvious
	# repeating silhouette.
	d.rotation.y = randf() * TAU
	parent.add_child(d)
	d.global_position = world_pos
	_register_decal(d)
	return d
