extends RefCounted
class_name VFXBurst
# VISUAL_AND_UX_POLISH_PLAN.md A2: replaces ad-hoc per-shot VFX
# (auto_weapon.gd's muzzle flash, battle_unit.gd's _flash_shield()/
# _spawn_explosion()) - each of which allocated a fresh MeshInstance3D +
# StandardMaterial3D + Tween and hand-animated it by hand every single shot/
# hit - with one shared GPUParticles3D-driven burst. Real particle spread/
# falloff (GPU-simulated) instead of a single scaling mesh, and a genuine
# performance win: the ParticleProcessMaterial + StandardMaterial3D pair is
# CACHED per (color, mesh) combination and reused across every future call
# with the same look, rather than allocated fresh per shot - the common
# case, since most weapons fire the same color/mesh combination repeatedly.
# Safe to share: neither cached resource is ever mutated after creation, so
# many simultaneous GPUParticles3D instances referencing the same cached
# resource can't stomp on each other's color/settings.

static var _material_cache: Dictionary = {} # "R,G,B,mesh_id" -> ParticleProcessMaterial
static var _override_cache: Dictionary = {} # same key -> StandardMaterial3D
static var _sphere_mesh: SphereMesh = null
static var _box_mesh: BoxMesh = null

static func get_sphere_mesh() -> SphereMesh:
	if _sphere_mesh == null:
		_sphere_mesh = SphereMesh.new()
		_sphere_mesh.radius = 0.12
		_sphere_mesh.height = 0.24
	return _sphere_mesh

static func get_box_mesh() -> BoxMesh:
	if _box_mesh == null:
		_box_mesh = BoxMesh.new()
		_box_mesh.size = Vector3(0.2, 0.2, 0.2)
	return _box_mesh

static func _cache_key(color: Color, mesh: Mesh) -> String:
	return "%s|%s" % [color.to_html(), mesh.get_instance_id()]

static func _get_process_material(color: Color, mesh: Mesh, spread: float, speed_min: float, speed_max: float, gravity: Vector3, scale_min: float, scale_max: float) -> ParticleProcessMaterial:
	var key = _cache_key(color, mesh)
	if _material_cache.has(key):
		return _material_cache[key]
	var mat = ParticleProcessMaterial.new()
	mat.direction = Vector3(0, 0, -1)
	mat.spread = spread
	mat.initial_velocity_min = speed_min
	mat.initial_velocity_max = speed_max
	mat.gravity = gravity
	mat.scale_min = scale_min
	mat.scale_max = scale_max
	mat.color = color
	_material_cache[key] = mat
	return mat

static func _get_override_material(color: Color, mesh: Mesh) -> StandardMaterial3D:
	var key = _cache_key(color, mesh)
	if _override_cache.has(key):
		return _override_cache[key]
	var mat = StandardMaterial3D.new()
	mat.albedo_color = color
	mat.emission_enabled = true
	mat.emission = color
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_override_cache[key] = mat
	return mat

# `local_pos` is in `parent`'s local space (matches the old MeshInstance3D
# calls' own `.position = ...` convention) - the particle node is added as
# parent's child so it moves with it (e.g. a muzzle flash at a weapon's
# barrel tip) unless `parent` is about to be freed itself, in which case
# pass a scene root instead (matching how _spawn_explosion() already did
# for a dying unit).
#
# Optional params:
#   forward_dir  — non-zero switches from sphere emission to a forward-
#                  pointing cone. The cone axis is this direction (local
#                  space of parent), spread is halved to form the cone
#                  half-angle. Used for directional muzzle flashes.
#   light_color  — if non-null, spawns a child OmniLight3D at the burst
#                  position for a bright "pop" visible at RTS zoom.
#   light_range  — omni_range of the light (default 4.0).
#   light_energy — light_energy of the light (default 5.0).
static func spawn(parent: Node3D, local_pos: Vector3, color: Color, count: int = 10, lifetime: float = 0.15, spread: float = 35.0, speed_min: float = 2.0, speed_max: float = 5.0, gravity: Vector3 = Vector3.ZERO, scale_min: float = 0.5, scale_max: float = 1.2, mesh: Mesh = null, forward_dir: Vector3 = Vector3.ZERO, light_color: Color = Color(0, 0, 0, 0), light_range: float = 4.0, light_energy: float = 5.0) -> GPUParticles3D:
	var use_mesh = mesh if mesh != null else get_sphere_mesh()
	var particles = GPUParticles3D.new()
	particles.emitting = false
	particles.one_shot = true
	particles.amount = count
	particles.lifetime = lifetime
	particles.explosiveness = 1.0
	particles.local_coords = true
	particles.position = local_pos

	# Directional cone emission: particles spray forward along the barrel
	# axis instead of radiating uniformly outward. The cone half-angle is
	# spread/2, so a 30° total spread becomes a 15° half-angle cone.
	if forward_dir.length_squared() > 0.001:
		var mat = ParticleProcessMaterial.new()
		mat.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_SPHERE
		mat.direction = forward_dir.normalized()
		mat.spread = spread * 0.5
		mat.initial_velocity_min = speed_min
		mat.initial_velocity_max = speed_max
		mat.gravity = gravity
		mat.scale_min = scale_min
		mat.scale_max = scale_max
		mat.color = color
		particles.process_material = mat
	else:
		particles.process_material = _get_process_material(color, use_mesh, spread, speed_min, speed_max, gravity, scale_min, scale_max)

	particles.draw_pass_1 = use_mesh
	particles.material_override = _get_override_material(color, use_mesh)
	parent.add_child(particles)
	particles.emitting = true

	# OmniLight flash: brief bright pop visible at RTS zoom distance.
	# Used for muzzle flashes where the particle sphere alone is too subtle.
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
		lt.tween_property(light, "light_energy", 0.0, lifetime * 0.8)
		lt.finished.connect(func(): if is_instance_valid(light): light.queue_free())

	# one_shot GPUParticles3D emits `finished` once every particle has
	# completed its lifetime and emitting has gone back to false on its
	# own - the real auto-cleanup signal, not a guessed timer.
	particles.finished.connect(func():
		if is_instance_valid(particles):
			particles.queue_free())
	return particles
