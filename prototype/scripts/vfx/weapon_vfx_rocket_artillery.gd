extends RefCounted
class_name WeaponVFXRocketArtillery

# ROCKET_ARTILLERY — Large Slow Ballistic Rocket (Rack Salvo)
# Identity: big sooty orange trail, high arc, wide saturation blast + lingering smoke columns + broad scorch.
# Framework-only: zero inline GPUParticles3D/StandardMaterial3D allocation.
# Draw budget: 1 rocket trail per round (bulk=2.6) + 1 saturation burst + 2 smoke columns + 1 scorch per impact cluster.

const VFXEffects = preload("res://scripts/vfx_effects.gd")
const VFXBurst = preload("res://scripts/vfx_burst.gd")
const ModuleCatalog = preload("res://scripts/module_catalog.gd")

# =====================================================================
# ROCKET TRAIL — Sooty orange plume with burning motes
# =====================================================================

# Returns a configured GPUParticles3D for the rocket artillery's distinct trail.
# Call from _fire_arcing_shell_at wrapper instead of VFXEffects.make_missile_trail.
# parent = the round node (Node3D with rocket body).
# bulk = trail_bulk from profile (2.6 for rocket_artillery).
# shell_radius = visual radius of the round body (for rear offset).
static func make_rocket_trail(parent: Node3D, bulk: float, shell_radius: float) -> GPUParticles3D:
	# Heavy rocket signature: dense sooty orange-brown plume with bright
	# burning-propellant motes. Two emitters merged into one via scale curve:
	# base soot plume (large, slow, opaque) + inner mote core (small, fast, additive).
	var p = GPUParticles3D.new()
	p.name = "RocketArtilleryTrail"
	p.amount = int(clampf(120.0 * bulk, 24.0, 600.0))  # 312 at bulk=2.6
	p.lifetime = clampf(1.0 * sqrt(bulk), 0.5, 3.0)     # ~1.6s at bulk=2.6
	p.emitting = false
	p.local_coords = false  # world-space trail (framework contract)
	p.draw_pass_1 = VFXEffects._get_quad()
	# Sooty orange-brown base tint, semi-transparent for volume
	p.material_override = VFXEffects._billboard_material(
		VFXEffects.SMOKE_TEX, false, Color(0.55, 0.35, 0.15, 0.75))

	var mat_key = "rocket_artillery_trail|%.2f" % bulk
	if VFXEffects._process_cache.has(mat_key):
		p.process_material = VFXEffects._process_cache[mat_key]
	else:
		var mat = ParticleProcessMaterial.new()
		mat.direction = Vector3(0, 0, 1)  # rocket flies +Z in local, world-space trail
		mat.spread = 18.0  # wider cone for big rocket
		# Speed: slow heavy rocket, plume barely outruns body
		mat.initial_velocity_min = 1.0
		mat.initial_velocity_max = 3.5
		mat.gravity = Vector3(0, 0.8, 0)  # buoyant soot columns
		mat.scale_min = 0.4 * bulk
		mat.scale_max = 1.0 * bulk
		mat.damping_min = 0.3
		mat.damping_max = 0.5
		mat.angle_min = -180.0
		mat.angle_max = 180.0
		mat.anim_speed_min = 0.8
		mat.anim_speed_max = 1.2
		mat.anim_offset_min = 0.0
		mat.anim_offset_max = 0.5

		# Scale curve: fat at birth, slow taper to lingering columns
		var curve = CurveTexture.new()
		var c = Curve.new()
		c.add_point(Vector2(0.0, 1.3))    # thick ignition puff
		c.add_point(Vector2(0.25, 0.95))  # sustained motor burn
		c.add_point(Vector2(0.6, 0.6))    # coast phase
		c.add_point(Vector2(1.0, 0.25))   # lingering smoke columns
		curve.curve = c
		mat.scale_curve = curve

		# Turbulence: soot tumble + column shear
		mat.turbulence_enabled = true
		mat.turbulence_noise_strength = 0.45
		mat.turbulence_noise_scale = 2.2
		mat.turbulence_noise_speed = Vector3(0.4, 0.25, 0.4)
		mat.turbulence_influence_min = 0.5
		mat.turbulence_influence_max = 1.0

		VFXEffects._process_cache[mat_key] = mat
		p.process_material = mat

	parent.add_child(p)
	# Position at rocket rear (+Z in local, but local_coords=false so world pos)
	p.position = Vector3(0, 0, shell_radius * 0.85)
	p.emitting = true
	return p


# =====================================================================
# IMPACT — Wide saturation blast + lingering smoke columns + broad scorch
# =====================================================================

# Spawns the saturation impact cluster at detonation point.
# parent = scene root or effects parent (for world-space persistence).
# world_pos = impact position in world space.
# blast_radius = scaled blast radius from profile (2.4 * spread).
# spread = dispersion multiplier from weapon tweaks.
# Returns an Array of spawned VFX nodes (burst, smoke columns, scorch) for caller tracking.
static func spawn_saturation_impact(parent: Node3D, world_pos: Vector3, blast_radius: float, spread: float) -> Array:
	var spawned = []

	# 1. Primary saturation burst: wide orange-white fireball
	var burst = VFXEffects.fire_burst(
		parent,
		world_pos,
		blast_radius * 1.15,  # slightly oversize the fireball
		Color(1.0, 0.55, 0.1, 1.0)  # intense orange
	)
	spawned.append(burst)

	# 2. Heavy grey-black smoke puff at ground zero
	var smoke_main = VFXEffects.smoke_puff(
		parent,
		world_pos,
		blast_radius * 0.9,
		int(clampf(blast_radius * 6.0, 16.0, 48.0)),
		Color(0.18, 0.16, 0.14, 0.65)
	)
	spawned.append(smoke_main)

	# 3. Dual lingering smoke columns (rising from crater edges)
	# Column A - left of impact
	var col_a_pos = world_pos + Vector3(-blast_radius * 0.4, 0, -blast_radius * 0.3)
	var column_a = VFXEffects.wreck_smoke_column(
		parent,
		col_a_pos,
		8.0 + spread * 4.0,  # 8-16s based on spread
		10.0 + spread * 3.0
	)
	spawned.append(column_a)

	# Column B - right of impact
	var col_b_pos = world_pos + Vector3(blast_radius * 0.4, 0, blast_radius * 0.3)
	var column_b = VFXEffects.wreck_smoke_column(
		parent,
		col_b_pos,
		8.0 + spread * 4.0,
		10.0 + spread * 3.0
	)
	spawned.append(column_b)

	# 4. Broad scorch decal (oversized, long fade)
	var scorch = VFXEffects.scorch(
		parent,
		world_pos,
		blast_radius * 1.35,  # wider than blast radius
		0.0,  # no burn phase, pure scorch
		22.0 + spread * 8.0   # 22-38s fade
	)
	spawned.append(scorch)

	# 5. Ground flash light (brief, wide)
	var light = OmniLight3D.new()
	light.light_color = Color(1.0, 0.6, 0.15)
	light.light_energy = 18.0 * blast_radius
	light.omni_range = 14.0 * blast_radius
	light.light_bake_mode = Light3D.BAKE_DISABLED
	parent.add_child(light)
	light.global_position = world_pos
	var lt = parent.create_tween()
	lt.tween_property(light, "light_energy", 0.0, 0.25)
	lt.finished.connect(func(): if is_instance_valid(light): light.queue_free())
	spawned.append(light)

	return spawned


# =====================================================================
# LAUNCH — Per-rocket muzzle flash from rack
# =====================================================================

# One-shot muzzle flash per rocket leaving the rack.
# parent = the weapon module node (auto_weapon instance).
# local_pos = muzzle position in weapon local space (get_muzzle_local_pos()).
# forward_dir = barrel forward in weapon local space (get_muzzle_local_dir()).
static func spawn_launch_flash(parent: Node3D, local_pos: Vector3, forward_dir: Vector3) -> GPUParticles3D:
	# Heavy rocket motor ignition: fat orange-white stab with soot fringe
	var p = VFXEffects.muzzle_flash(
		parent,
		local_pos,
		forward_dir,
		1.8,  # radius - bigger than typical gun flash
		Color(1.0, 0.65, 0.15, 1.0),  # orange-white core
		Color(1.0, 0.5, 0.1),         # light tint
		6.0,                          # light range
		12.0                          # light energy
	)
	return p


# =====================================================================
# WIRE-IN SPEC (for _fire_rocket_artillery in auto_weapon.gd)
# =====================================================================
# 1. In _fire_rocket_artillery's per-rocket timer callback, REPLACE the
#    _fire_arcing_shell_at call with a local wrapper that:
#    a) Calls _fire_arcing_shell_at(...) to get the round_node
#    b) Calls WeaponVFXRocketArtillery.make_rocket_trail(round_node, 2.6, 0.25)
#       instead of the internal _attach_trail_to_round()
#    c) Stores the trail ref on round_node for cleanup (round_node.trail_plume = plume)
# 2. In the round's impact handler (where _detonate_at is called), ADD after
#    _detonate_at(...):
#    WeaponVFXRocketArtillery.spawn_saturation_impact(_effects_parent(), impact_pos, 2.4 * spread, spread)
# 3. In _fire_rocket_artillery's per-rocket timer callback, AFTER spawning
#    the round, call:
#    WeaponVFXRocketArtillery.spawn_launch_flash(self, get_muzzle_local_pos(), get_muzzle_local_dir())
# All calls use framework-cached materials; zero inline allocations.
# Draw cost per rocket: 1 trail (bulk=2.6) + 1 burst + 2 columns + 1 scorch + 1 light per impact cluster.