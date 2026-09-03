extends RefCounted
class_name WeaponVFXAntiRadiationMissile

# ANTI_RADIATION_MISSILE — SEAD Dart (Suppression of Enemy Air Defenses)
# Identity: violet-white seeker glow, straight fast flight, electronics-kill impact
# — blue-white EMP-style bloom + spark shower, minimal crater.
# Framework-only: zero inline GPUParticles3D/StandardMaterial3D allocation.
# Draw budget: 1 missile trail (bulk=1.0) + 1 EMP burst per engagement.

const VFXEffects = preload("res://scripts/vfx_effects.gd")
const VFXBurst = preload("res://scripts/vfx_burst.gd")
const ModuleCatalog = preload("res://scripts/module_catalog.gd")

# =====================================================================
# MISSILE TRAIL — Violet-white seeker signature + thin ionised contrail
# =====================================================================

# Returns a configured GPUParticles3D for the ARM's missile trail.
# Call from weapon_missile._ready() after mesh_part assignment.
# parent = the missile node (weapon_missile instance).
static func make_missile_trail(parent: Node3D) -> GPUParticles3D:
	# Violet-white seeker head glow with thin ionised contrail behind.
	# Single emitter encoding both phases via lifetime curves.
	var p = GPUParticles3D.new()
	p.name = "ARMMissileTrail"
	p.amount = 60  # bulk=1.0 scaled: clamp(120*1.0, 24, 600) → 120, tuned down for thin contrail
	p.lifetime = 2.0
	p.emitting = false
	p.local_coords = false  # world-space contrail (framework contract)
	p.draw_pass_1 = VFXEffects._get_quad()
	# Violet-white seeker glow, additive for the ionised core
	p.material_override = VFXEffects._billboard_material(
		VFXEffects.SMOKE_TEX, true, Color(0.75, 0.55, 1.0, 0.75))
	
	# Process material: bright seeker head (0-0.2s) → thin ionised contrail (0.2-2.0s)
	var mat_key = "arm_trail|seeker_glow"
	if VFXEffects._process_cache.has(mat_key):
		p.process_material = VFXEffects._process_cache[mat_key]
	else:
		var mat = ParticleProcessMaterial.new()
		mat.direction = Vector3(0, 0, 1)  # missile flies +Z in local, world-space trail
		mat.spread = 1.5  # very tight — straight flight
		# Speed curve: seeker head bloom fast, contrail slow drift
		mat.initial_velocity_min = 2.0
		mat.initial_velocity_max = 25.0
		mat.gravity = Vector3(0, 0.15, 0)  # slight buoyancy for ionised trail
		mat.scale_min = 0.1
		mat.scale_max = 0.35
		mat.damping_min = 0.1
		mat.damping_max = 0.1
		mat.angle_min = -180.0
		mat.angle_max = 180.0
		mat.anim_speed_min = 1.0
		mat.anim_speed_max = 1.0
		mat.anim_offset_min = 0.0
		mat.anim_offset_max = 0.2
		
		# Scale curve: bright seeker head at birth, rapid collapse to thin ionised line
		var curve = CurveTexture.new()
		var c = Curve.new()
		c.add_point(Vector2(0.0, 1.0))      # seeker head bloom
		c.add_point(Vector2(0.1, 0.4))      # rapid collapse
		c.add_point(Vector2(0.25, 0.2))     # contrail steady
		c.add_point(Vector2(1.0, 0.05))     # fade to nothing
		curve.curve = c
		mat.scale_curve = curve
		
		# Turbulence: minimal — straight SEAD dart flight path
		mat.turbulence_enabled = true
		mat.turbulence_noise_strength = 0.12
		mat.turbulence_noise_scale = 2.5
		mat.turbulence_noise_speed = Vector3(0.3, 0.15, 0.3)
		mat.turbulence_influence_min = 0.2
		mat.turbulence_influence_max = 0.6
		
		VFXEffects._process_cache[mat_key] = mat
		p.process_material = mat
	
	parent.add_child(p)
	# Position at missile rear (+Z in missile local, but local_coords=false so world pos)
	p.position = Vector3(0, 0, 0.4)
	p.emitting = true
	return p


# =====================================================================
# IMPACT — EMP-style blue-white bloom + spark shower, minimal crater
# =====================================================================

# Spawns the electronics-kill impact at intercept point.
# parent = scene root or effects parent (for world-space persistence).
# world_pos = intercept position in world space.
# Returns the burst GPUParticles3D (one-shot, auto-free).
static func spawn_impact(parent: Node3D, world_pos: Vector3) -> GPUParticles3D:
	# EMP burst: blue-white ionisation bloom + sharp spark shower.
	# Uses VFXBurst.spawn with sphere emission for true 3D burst.
	var burst = VFXBurst.spawn(
		parent,
		Vector3.ZERO,  # local_pos; we set global_position after
		Color(0.4, 0.7, 1.0, 1.0),  # blue-white EMP core
		36,                              # spark count
		0.25,                            # lifetime (sharp, fast)
		180.0,                           # full sphere spread
		22.0,                            # speed_min (fast spark shower)
		42.0,                            # speed_max
		Vector3(0, -0.8, 0),             # slight gravity droop
		0.08,                            # scale_min (fine sparks)
		0.18,                            # scale_max
		VFXBurst.get_box_mesh(),         # angular spark mesh — electronics debris
		Vector3.ZERO,                    # forward_dir=0 → sphere emission
		Color(0.3, 0.6, 1.0, 1.0),       # light_color: blue-white EMP flash
		8.0,                             # light_range
		22.0                             # light_energy (bright, brief)
	)
	burst.global_position = world_pos
	
	# Minimal crater — electronics kill, not kinetic excavation
	VFXEffects.crater(parent, world_pos, 0.8, 18.0)
	
	return burst


# =====================================================================
# LAUNCH VFX — Optional: seeker uncage vent on fire
# =====================================================================

# One-shot violet-white uncage vent at the launcher when missile ejects.
# parent = the weapon module node (auto_weapon instance).
# local_pos = muzzle position in weapon local space (get_muzzle_local_pos()).
static func spawn_launch_vent(parent: Node3D, local_pos: Vector3) -> GPUParticles3D:
	var p = GPUParticles3D.new()
	p.name = "ARMLAunchVent"
	p.amount = 14
	p.lifetime = 0.3
	p.one_shot = true
	p.explosiveness = 1.0
	p.emitting = false
	p.local_coords = true
	p.draw_pass_1 = VFXEffects._get_quad()
	p.material_override = VFXEffects._billboard_material(
		VFXEffects.SMOKE_TEX, true, Color(0.7, 0.5, 1.0, 0.6))
	p.process_material = VFXEffects._process_material(
		"arm_launch_vent",
		Vector3.UP, 60.0, 8.0, 16.0,
		Vector3(0, 2.5, 0), 0.25, 0.7, 0.4, 1.0, 1.0)
	parent.add_child(p)
	p.position = local_pos
	p.emitting = true
	p.finished.connect(func(): if is_instance_valid(p): p.queue_free())
	return p


# =====================================================================
# WIRE-IN SPEC (for _fire_anti_radiation_missile in auto_weapon.gd)
# =====================================================================
# 1. weapon_missile._ready(): after `mesh_part = ModuleCatalog.get_missile_mesh("anti_radiation_missile")`,
#    call `WeaponVFXAntiRadiationMissile.make_missile_trail(self)` and store ref for cleanup.
# 2. weapon_missile.on_intercept(): call
#    `WeaponVFXAntiRadiationMissile.spawn_impact(_effects_parent(), global_position)`.
# 3. auto_weapon._fire_anti_radiation_missile(): after `_spawn_missile(...)` returns missile,
#    call `WeaponVFXAntiRadiationMissile.spawn_launch_vent(self, get_muzzle_local_pos())`.
# All calls use framework-cached materials; zero inline allocations. Draw cost: 1 trail + 1 burst per shot.