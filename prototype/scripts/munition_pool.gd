extends Node
# Shared, cached geometry and materials for transient combat visuals
# (tracers, beams, flames, explosions, shells, sparks, smoke, puddles).
#
# WHY THIS EXISTS - measured, not assumed (PERFORMANCE_PLAN.md, 2026-07-31).
# Every _fire_* / _spawn_explosion_visual in auto_weapon.gd used to build a
# fresh MeshInstance3D + a fresh primitive Mesh + a fresh StandardMaterial3D
# per projectile; _fire_flame_spray() did it six times per trigger pull at
# fire_rate 0.06, and rotary_cannon fires every 0.05s. scratch/perf_probe.gd
# measured 8 units so loaded at mean 102ms / p95 285ms per frame, against
# 20ms for the same 8 units idle AND 20ms for the same 8 units in full combat
# with a slow single-tracer weapon - so the cost was never the unit meshes,
# the targeting, or the turret animation. It was munition allocation.
#
# scratch/perf_munition_bench.gd then split the per-projectile allocation into
# its parts, at a fixed 100 spawns/frame:
#
#   new mesh + new material (what shipped)   41.8ms/frame
#   new mesh + SHARED material               37.5ms   (-10%)
#   SHARED mesh + new material               19.7ms   (-53%)
#   SHARED mesh + SHARED material            18.8ms   (-55%)
#
# The freshly-built primitive Mesh dominated: it generates vertex data on the
# CPU and uploads a new GPU vertex buffer per projectile. The per-projectile
# material is real but secondary. Both are cached here.
#
# THE SIZING CONVENTION. Caching meshes keyed by their dimensions would not
# work for the beam weapons, whose height is `distance_to(target)` - a
# continuous value, so the key set would grow without bound over a match.
# Instead every mesh here is a UNIT primitive and all sizing moves to the
# MeshInstance3D's scale, which is free (a transform, not a buffer upload).
# That also collapses the cache to a handful of entries no matter how many
# weapon types or ranges exist.
#
#   unit_sphere()  radius 0.5, height 1.0  -> scale by DIAMETER
#   unit_cylinder() radius 0.5, height 1.0 -> scale (diameter, length, diameter)
#   unit_taper(r)  bottom 0.5, top 0.5*r   -> same, for the tapered arc beam
#
# Note that Godot's default SphereMesh is already radius 0.5 / height 1.0, so
# the call sites that previously used a default SphereMesh plus an explicit
# scale needed no scale change at all when they moved onto unit_sphere().
#
# SEGMENT COUNTS. Godot's primitive defaults are 64 radial segments (and 32
# rings for a sphere) - about 4,000 triangles for a flame puff drawn at 0.15
# scale, roughly ten pixels across. These unit meshes are deliberately coarse;
# at munition scale and munition lifetime (0.08-0.35s) the silhouette
# difference is not perceptible, and it cuts vertex-shading load alongside the
# buffer-upload saving that motivated the file.
#
# MUTATION RULE. Everything returned here is SHARED and must be treated as
# immutable by callers - never assign to a returned mesh's radius/height or a
# returned material's albedo/emission. Size via the node's scale, and get a
# differently-coloured material by asking for one. A single stray mutation
# would silently restyle or resize every munition in the match.

const _SPHERE_RADIAL := 8
const _SPHERE_RINGS := 4
const _CYL_RADIAL := 8

static var _unit_sphere: SphereMesh = null
static var _unit_cylinder: CylinderMesh = null
static var _unit_box: BoxMesh = null
static var _unit_prism: PrismMesh = null
static var _tapers: Dictionary = {}
static var _materials: Dictionary = {}

static func unit_sphere() -> SphereMesh:
	if _unit_sphere == null:
		_unit_sphere = SphereMesh.new()
		_unit_sphere.radius = 0.5
		_unit_sphere.height = 1.0
		_unit_sphere.radial_segments = _SPHERE_RADIAL
		_unit_sphere.rings = _SPHERE_RINGS
	return _unit_sphere

static func unit_cylinder() -> CylinderMesh:
	if _unit_cylinder == null:
		_unit_cylinder = CylinderMesh.new()
		_unit_cylinder.top_radius = 0.5
		_unit_cylinder.bottom_radius = 0.5
		_unit_cylinder.height = 1.0
		_unit_cylinder.radial_segments = _CYL_RADIAL
	return _unit_cylinder

static func unit_box() -> BoxMesh:
	if _unit_box == null:
		_unit_box = BoxMesh.new()
		_unit_box.size = Vector3.ONE
	return _unit_box

# Drone bodies (drone_unit.gd) - a carrier can have many in the air at once.
static func unit_prism() -> PrismMesh:
	if _unit_prism == null:
		_unit_prism = PrismMesh.new()
		_unit_prism.size = Vector3.ONE
	return _unit_prism

# A unit cylinder whose top radius is `top_over_bottom` x its bottom radius,
# for beams that visibly widen along their length (the arc projector). Keyed
# on the ratio, which is a per-weapon-type constant, so this stays at one or
# two entries for the whole match.
static func unit_taper(top_over_bottom: float) -> CylinderMesh:
	var key := snappedf(top_over_bottom, 0.01)
	if not _tapers.has(key):
		var cyl := CylinderMesh.new()
		cyl.bottom_radius = 0.5
		cyl.top_radius = 0.5 * key
		cyl.height = 1.0
		cyl.radial_segments = _CYL_RADIAL
		_tapers[key] = cyl
	return _tapers[key]

# Emissive munition material (the overwhelming majority - tracers, beams,
# flames, plasma, sparks). Cached on the full visual identity, so two weapons
# firing the same colour share one material and one descriptor set.
static func emissive(albedo: Color, emission: Color, energy: float = 1.0) -> StandardMaterial3D:
	var key := "e|%s|%s|%s" % [albedo, emission, snappedf(energy, 0.01)]
	if not _materials.has(key):
		var mat := StandardMaterial3D.new()
		mat.albedo_color = albedo
		mat.emission_enabled = true
		mat.emission = emission
		mat.emission_energy_multiplier = energy
		_materials[key] = mat
	return _materials[key]

# Plain opaque, non-emissive (a missile's body shell - the only unlit munition
# geometry in the game; everything else either glows or fades).
static func albedo(color: Color) -> StandardMaterial3D:
	var key := "o|%s" % color
	if not _materials.has(key):
		var mat := StandardMaterial3D.new()
		mat.albedo_color = color
		_materials[key] = mat
	return _materials[key]

# Alpha-blended, non-emissive munition material (miss puffs, flak smoke).
static func alpha(albedo: Color) -> StandardMaterial3D:
	var key := "a|%s" % albedo
	if not _materials.has(key):
		var mat := StandardMaterial3D.new()
		mat.albedo_color = albedo
		mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		_materials[key] = mat
	return _materials[key]

# Alpha-blended AND emissive (the plasma puddle).
static func alpha_emissive(albedo: Color, emission: Color, energy: float = 1.0) -> StandardMaterial3D:
	var key := "ae|%s|%s|%s" % [albedo, emission, snappedf(energy, 0.01)]
	if not _materials.has(key):
		var mat := StandardMaterial3D.new()
		mat.albedo_color = albedo
		mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		mat.emission_enabled = true
		mat.emission = emission
		mat.emission_energy_multiplier = energy
		_materials[key] = mat
	return _materials[key]

static func additive_emissive(albedo: Color, emission: Color, energy: float = 1.0) -> StandardMaterial3D:
	var key := "add|%s|%s|%s" % [albedo, emission, snappedf(energy, 0.01)]
	if not _materials.has(key):
		var mat := StandardMaterial3D.new()
		mat.albedo_color = albedo
		mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		mat.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
		mat.emission_enabled = true
		mat.emission = emission
		mat.emission_energy_multiplier = energy
		mat.depth_draw_mode = BaseMaterial3D.DEPTH_DRAW_DISABLED
		_materials[key] = mat
	return _materials[key]

# --- Beam helper -----------------------------------------------------------
#
# Every beam-shaped weapon repeated the same six lines: build a cylinder as
# long as the gap to the target, park it at the midpoint, look_at the target,
# then rotate 90 degrees about local X because a CylinderMesh runs along Y
# while look_at aims down -Z. With length now carried by scale rather than by
# mesh height, that idiom is identical for every caller, so it lives here.
#
# Returns the beam's length, because the callers that collapse a beam by
# tweening its scale to Vector3(0, 1, 0) must now tween to Vector3(0, len, 0)
# to hold the beam's length steady while only its radius shrinks.
static func aim_beam(beam: MeshInstance3D, from: Vector3, to: Vector3, diameter: float) -> float:
	var delta := to - from
	var length := delta.length()
	if length <= 0.001:
		beam.scale = Vector3.ZERO
		return 0.0

	var y_axis := delta / length
	var up_candidate := Vector3.UP if absf(y_axis.dot(Vector3.UP)) < 0.99 else Vector3.FORWARD
	var x_axis := y_axis.cross(up_candidate).normalized()
	var z_axis := x_axis.cross(y_axis).normalized()

	var basis := Basis(x_axis * diameter, y_axis * length, z_axis * diameter)
	var mid := from.lerp(to, 0.5)

	if beam.is_inside_tree():
		beam.global_transform = Transform3D(basis, mid)
	else:
		beam.transform = Transform3D(basis, mid)

	return length
