extends RefCounted
class_name WeaponVFXSAMLauncher

# SAM_LAUNCHER — Vertical-Launch Interceptor (VLS)
# Identity: cold-launch pop-up from cell, rapid tip-over to intercept vector,
# thin persistent white contrail, proximity-fuze spherical pellet burst at air targets.
# Framework-only: zero inline GPUParticles3D/StandardMaterial3D allocation.
# Draw budget: 1 missile trail (bulk=1.0) + 1 proximity burst per engagement.

const VFXEffects = preload("res://scripts/vfx_effects.gd")
const VFXBurst = preload("res://scripts/vfx_burst.gd")
const ModuleCatalog = preload("res://scripts/module_catalog.gd")

# =====================================================================
# MISSILE TRAIL — Cold-launch signature + sustained contrail
# =====================================================================

# Returns a configured GPUParticles3D for the SAM's missile trail.
# Call from weapon_missile._ready() after mesh_part assignment.
# parent = the missile node (weapon_missile instance).
static func make_missile_trail(parent: Node3D) -> GPUParticles3D:
	# Cold-launch pop-up phase: brief high-volume plume at cell exit,
	# then transitions to thin sustained contrail. Implemented as a single
	# emitter whose process material encodes both phases via lifetime curve.
	var p = GPUParticles3D.new()
	p.name = "SAMMissileTrail"
	p.amount = 80  # bulk=1.0 scaled: clamp(120*1.0, 24, 600) → 120, tuned down for thin contrail
	p.lifetime = 2.5
	p.emitting = false
	p.local_coords = false  # world-space contrail (framework contract)
	p.draw_pass_1 = VFXEffects._get_quad()
	# White contrail, slight blue tint for IR-seeker aesthetic
	p.material_override = VFXEffects._billboard_material(
		VFXEffects.SMOKE_TEX, false, Color(0.95, 0.95, 1.0, 0.65))
	
	# Two-phase process material: pop-up burst (0-0.4s) → thin contrail (0.4-2.5s)
	var mat_key = "sam_trail|cold_launch"
	if VFXEffects._process_cache.has(mat_key):
		p.process_material = VFXEffects._process_cache[mat_key]
	else:
		var mat = ParticleProcessMaterial.new()
		mat.direction = Vector3(0, 0, 1)  # missile flies +Z in local, world-space trail
		mat.spread = 3.0  # tight column
		# Speed curve: fast initial pop (40 m/s), then cruise (8 m/s)
		mat.initial_velocity_min = 4.0
		mat.initial_velocity_max = 40.0
		mat.gravity = Vector3(0, 0.3, 0)  # slight buoyancy for contrail hang
		mat.scale_min = 0.15
		mat.scale_max = 0.5
		mat.damping_min = 0.15
		mat.damping_max = 0.15
		mat.angle_min = -180.0
		mat.angle_max = 180.0
		mat.anim_speed_min = 1.0
		mat.anim_speed_max = 1.0
		mat.anim_offset_min = 0.0
		mat.anim_offset_max = 0.25
		
		# Scale curve: large puff at birth (cold gas), rapid shrink to thin line
		var curve = CurveTexture.new()
		var c = Curve.new()
		c.add_point(Vector2(0.0, 1.2))    # cold-launch pop
		c.add_point(Vector2(0.15, 0.35))  # rapid collapse
		c.add_point(Vector2(0.4, 0.18))   # contrail steady
		c.add_point(Vector2(1.0, 0.08))   # fade to wisps
		curve.curve = c
		mat.scale_curve = curve
		
		# Turbulence: tip-over maneuver curl + contrail dispersion
		mat.turbulence_enabled = true
		mat.turbulence_noise_strength = 0.25
		mat.turbulence_noise_scale = 1.8
		mat.turbulence_noise_speed = Vector3(0.6, 0.3, 0.6)
		mat.turbulence_influence_min = 0.3
		mat.turbulence_influence_max = 0.9
		
		VFXEffects._process_cache[mat_key] = mat
		p.process_material = mat
	
	parent.add_child(p)
	# Position at missile rear (+Z in missile local, but local_coords=false so world pos)
	p.position = Vector3(0, 0, 0.4)
	p.emitting = true
	return p


# =====================================================================
# IMPACT — Proximity-fuze spherical pellet burst
# =====================================================================

# Spawns the proximity burst at intercept point.
# parent = scene root or effects parent (for world-space persistence).
# world_pos = intercept position in world space.
# Returns the burst GPUParticles3D (one-shot, auto-free).
static func spawn_proximity_burst(parent: Node3D, world_pos: Vector3) -> GPUParticles3D:
	# Spherical pellet cloud: white-hot kinetic fragments, proximity-fuzed.
	# Uses VFXBurst.spawn with sphere emission for true 3D burst.
	var burst = VFXBurst.spawn(
		parent,
		Vector3.ZERO,  # local_pos; we set global_position after
		Color(1.0, 1.0, 0.95, 1.0),  # white-hot with barely-warm tint
		28,                              # pellet count
		0.35,                            # lifetime
		180.0,                           # full sphere spread
		18.0,                            # speed_min (pellet velocity)
		32.0,                            # speed_max
		Vector3(0, -1.5, 0),             # slight gravity droop
		0.12,                            # scale_min (small pellets)
		0.22,                            # scale_max
		VFXBurst.get_sphere_mesh(),      # round pellets
		Vector3.ZERO,                    # forward_dir=0 → sphere emission
		Color(1.0, 0.95, 0.8, 1.0),      # light_color: warm white flash
		6.0,                             # light_range
		18.0                             # light_energy
	)
	burst.global_position = world_pos
	return burst


# =====================================================================
# LAUNCH CELL VFX — Optional: VLS cell cold-gas vent on fire
# =====================================================================

# One-shot cold-gas vent at the VLS cell when missile ejects.
# parent = the weapon module node (auto_weapon instance).
# local_pos = muzzle position in weapon local space (get_muzzle_local_pos()).
static func spawn_cell_vent(parent: Node3D, local_pos: Vector3) -> GPUParticles3D:
	var p = GPUParticles3D.new()
	p.name = "VLSCellVent"
	p.amount = 18
	p.lifetime = 0.4
	p.one_shot = true
	p.explosiveness = 1.0
	p.emitting = false
	p.local_coords = true
	p.draw_pass_1 = VFXEffects._get_quad()
	p.material_override = VFXEffects._billboard_material(
		VFXEffects.SMOKE_TEX, false, Color(0.85, 0.85, 0.95, 0.55))
	p.process_material = VFXEffects._process_material(
		"vls_cell_vent",
		Vector3.UP, 70.0, 6.0, 14.0,
		Vector3(0, 2.0, 0), 0.3, 0.9, 0.5, 1.2, 0.8)
	parent.add_child(p)
	p.position = local_pos
	p.emitting = true
	p.finished.connect(func(): if is_instance_valid(p): p.queue_free())
	return p


# =====================================================================
# WIRE-IN SPEC (for _fire_sam_launcher in auto_weapon.gd)
# =====================================================================
# 1. weapon_missile._ready(): after `mesh_part = ModuleCatalog.get_missile_mesh("sam_launcher")`,
#    call `WeaponVFXSAMLauncher.make_missile_trail(self)` and store ref for cleanup.
# 2. weapon_missile.on_intercept(): call
#    `WeaponVFXSAMLauncher.spawn_proximity_burst(_effects_parent(), global_position)`.
# 3. auto_weapon._fire_sam_launcher(): after `_spawn_missile(...)` returns missile,
#    call `WeaponVFXSAMLauncher.spawn_cell_vent(self, get_muzzle_local_pos())`.
# All calls use framework-cached materials; zero inline allocations. Draw cost: 1 trail + 1 burst per shot.