extends RefCounted
class_name WeaponVFXCruiseMissile

# CRUISE_MISSILE — Long-Range Heavy Strategic Missile
# Identity: fat body, long persistent cruise trail (terrain-hugging, low dispersion),
# MASSIVE fuel-air fireball on impact (largest of the set) + wide scorch + long smoke column.
# Framework-only: zero inline GPUParticles3D/StandardMaterial3D allocation.
# Draw budget: 1 missile trail (bulk=1.0) + 1 impact sequence per engagement.

const VFXEffects = preload("res://scripts/vfx_effects.gd")
const VFXBurst = preload("res://scripts/vfx_burst.gd")
const ModuleCatalog = preload("res://scripts/module_catalog.gd")

# =====================================================================
# MISSILE TRAIL — Heavy cruise contrail, terrain-hugging persistence
# =====================================================================

# Returns a configured GPUParticles3D for the cruise missile's sustained trail.
# Call from weapon_missile._ready() after mesh_part assignment.
# parent = the missile node (weapon_missile instance).
static func make_missile_trail(parent: Node3D) -> GPUParticles3D:
	# Heavy cruise missile: thick, low-dispersion contrail that hugs terrain.
	# Single emitter with process material encoding sustained cruise phase.
	var p = GPUParticles3D.new()
	p.name = "CruiseMissileTrail"
	p.amount = 150  # bulk=1.0 scaled: clamp(120*1.0, 24, 600) → 120, tuned UP for persistent heavy trail
	p.lifetime = 4.5
	p.emitting = false
	p.local_coords = false  # world-space contrail (framework contract)
	p.draw_pass_1 = VFXEffects._get_quad()
	# Dense white-grey contrail, slight warmth for hydrocarbon burn
	p.material_override = VFXEffects._billboard_material(
		VFXEffects.SMOKE_TEX, false, Color(0.85, 0.82, 0.78, 0.75))
	
	# Process material: sustained low-altitude cruise plume
	var mat_key = "cruise_trail|terrain_hug"
	if VFXEffects._process_cache.has(mat_key):
		p.process_material = VFXEffects._process_cache[mat_key]
	else:
		var mat = ParticleProcessMaterial.new()
		mat.direction = Vector3(0, 0, 1)  # missile flies +Z in local, world-space trail
		mat.spread = 5.0  # wider than SAM for heavy engine exhaust
		# Speed curve: cruise velocity (12 m/s), low dispersion
		mat.initial_velocity_min = 2.0
		mat.initial_velocity_max = 12.0
		mat.gravity = Vector3(0, 0.15, 0)  # slight buoyancy for terrain-hugging hang
		mat.scale_min = 0.35
		mat.scale_max = 1.1
		mat.damping_min = 0.12
		mat.damping_max = 0.12
		mat.angle_min = -180.0
		mat.angle_max = 180.0
		mat.anim_speed_min = 0.8
		mat.anim_speed_max = 1.2
		mat.anim_offset_min = 0.0
		mat.anim_offset_max = 0.3
		
		# Scale curve: steady heavy plume, slow fade to wide dissipation
		var curve = CurveTexture.new()
		var c = Curve.new()
		c.add_point(Vector2(0.0, 1.0))    # full plume at engine
		c.add_point(Vector2(0.2, 0.95))   # sustained cruise
		c.add_point(Vector2(0.6, 0.7))    # gradual expansion
		c.add_point(Vector2(1.0, 0.25))   # long dissipation tail
		curve.curve = c
		mat.scale_curve = curve
		
		# Turbulence: terrain-hugging ground effect curl + atmospheric dispersion
		mat.turbulence_enabled = true
		mat.turbulence_noise_strength = 0.35
		mat.turbulence_noise_scale = 2.2
		mat.turbulence_noise_speed = Vector3(0.4, 0.15, 0.4)
		mat.turbulence_influence_min = 0.4
		mat.turbulence_influence_max = 1.0
		
		VFXEffects._process_cache[mat_key] = mat
		p.process_material = mat
	
	parent.add_child(p)
	# Position at missile rear (+Z in missile local, but local_coords=false so world pos)
	p.position = Vector3(0, 0, 0.6)
	p.emitting = true
	return p


# =====================================================================
# LAUNCH VFX — Heavy booster ignition at VLS cell / rail
# =====================================================================

# One-shot heavy booster ignition at launch point.
# parent = the weapon module node (auto_weapon instance).
# local_pos = muzzle position in weapon local space (get_muzzle_local_pos()).
static func spawn_launch_boost(parent: Node3D, local_pos: Vector3) -> GPUParticles3D:
	var p = GPUParticles3D.new()
	p.name = "CruiseLaunchBoost"
	p.amount = 35
	p.lifetime = 0.6
	p.one_shot = true
	p.explosiveness = 1.0
	p.emitting = false
	p.local_coords = true
	p.draw_pass_1 = VFXEffects._get_quad()
	p.material_override = VFXEffects._billboard_material(
		VFXEffects.FLAME_TEX, true, Color(1.0, 0.7, 0.25, 0.95))
	p.process_material = VFXEffects._process_material(
		"cruise_launch_boost",
		Vector3(0, 0.1, -1.0).normalized(), 18.0, 25.0, 55.0,
		Vector3(0, 1.5, 0), 0.8, 2.2, 0.05, 0.8, 1.5)
	parent.add_child(p)
	p.position = local_pos
	p.emitting = true
	p.finished.connect(func(): if is_instance_valid(p): p.queue_free())
	return p


# =====================================================================
# IMPACT — MASSIVE fuel-air fireball + wide scorch + long smoke column
# =====================================================================

# Spawns the cruise missile impact sequence at detonation point.
# parent = scene root or effects parent (for world-space persistence).
# world_pos = impact position in world space.
# Returns an Array of created VFX nodes for caller reference.
static func spawn_impact_sequence(parent: Node3D, world_pos: Vector3) -> Array:
	var created = []
	
	# 1. MASSIVE fuel-air fireball (largest of the set)
	# Uses fire_burst with maximum capped radius for visual scale.
	# fire_burst amount clamps at 24 particles; radius scales visual size.
	var fireball = VFXEffects.fire_burst(
		parent,
		world_pos,
		3.5,  # radius: largest in roster (others: 1.0-2.4)
		Color(1.0, 0.85, 0.35, 1.0)  # intense hydrocarbon fireball yellow-orange
	)
	created.append(fireball)
	
	# 2. Fuel-air debris burst: fine aerosol ignition cloud (sphere emission)
	# VFXBurst handles the mesh-particle "flaming aerosol" look.
	var aerosol_burst = VFXBurst.spawn(
		parent,
		Vector3.ZERO,  # local_pos; we set global_position after
		Color(1.0, 0.7, 0.2, 1.0),  # hot fuel-rich orange
		55,                              # particle count (capped for budget)
		0.85,                            # lifetime: lingers as fireball expands
		180.0,                           # full sphere spread
		8.0,                             # speed_min: slow expansion
		18.0,                            # speed_max
		Vector3(0, -0.8, 0),             # slight gravity settle
		0.25,                            # scale_min: fine droplets
		0.55,                            # scale_max
		VFXBurst.get_sphere_mesh(),      # round aerosol particles
		Vector3.ZERO,                    # forward_dir=0 → sphere emission
		Color(1.0, 0.9, 0.4, 1.0),       # light_color: intense warm flash
		18.0,                            # light_range: wide illumination
		45.0                             # light_energy: MASSIVE flash
	)
	aerosol_burst.global_position = world_pos
	created.append(aerosol_burst)
	
	# 3. Wide ground scorch (fuel-air carpet burn)
	# burn_seconds > 0 makes it a live napalm pool first, then cold scorch.
	var scorch = VFXEffects.scorch(
		parent,
		world_pos,
		6.0,        # radius: wide carpet (others: 2.0-4.0)
		2.5,        # burn_seconds: fuel-air surface burn
		20.0        # fade_seconds: long persistence
	)
	created.append(scorch)
	
	# 4. Long smoke column rising from impact
	# Large amount, long lifetime, tall column.
	var smoke_column = VFXEffects.smoke_puff(
		parent,
		world_pos,
		4.5,   # radius: wide base
		35,    # amount: dense column (capped reasonable)
		Color(0.15, 0.13, 0.11, 0.65)  # dense oily black smoke
	)
	created.append(smoke_column)
	
	# 5. Secondary rising smoke plume (persistent column, separate emitter)
	# Uses wreck_smoke_column pattern but shorter duration for impact.
	var rising_smoke = GPUParticles3D.new()
	rising_smoke.name = "CruiseImpactSmokeColumn"
	rising_smoke.amount = 24
	rising_smoke.lifetime = 4.0
	rising_smoke.emitting = false
	rising_smoke.draw_pass_1 = VFXEffects._get_quad()
	rising_smoke.material_override = VFXEffects._billboard_material(
		VFXEffects.SMOKE_TEX, false, Color(0.12, 0.10, 0.09, 0.7))
	var speed = 10.0 / rising_smoke.lifetime
	rising_smoke.process_material = VFXEffects._process_material(
		"cruise_impact_smoke_column|10.0",
		Vector3(0, 1, 0), 22.0, speed * 0.6, speed * 1.1,
		Vector3(0.3, 0.6, 0.15), 1.8, 4.5, 0.5, 2.5, 1.3)
	parent.add_child(rising_smoke)
	rising_smoke.global_position = world_pos
	rising_smoke.emitting = true
	VFXEffects._stop_and_free_after(rising_smoke, 12.0)
	created.append(rising_smoke)
	
	# 6. Massive omnidirectional light flash (handled by fire_burst + VFXBurst lights above)
	# Additional directional "blast wave" light for the fuel-air overpressure
	var blast_light = OmniLight3D.new()
	blast_light.light_color = Color(1.0, 0.85, 0.4)
	blast_light.light_energy = 60.0
	blast_light.omni_range = 22.0
	blast_light.omni_attenuation = 0.4
	blast_light.light_bake_mode = Light3D.BAKE_DISABLED
	parent.add_child(blast_light)
	blast_light.global_position = world_pos
	var lt = parent.create_tween()
	lt.tween_property(blast_light, "light_energy", 0.0, 0.25)
	lt.finished.connect(func(): if is_instance_valid(blast_light): blast_light.queue_free())
	created.append(blast_light)
	
	return created


# =====================================================================
# WIRE-IN SPEC (for _fire_cruise_missile in auto_weapon.gd)
# =====================================================================
# 1. weapon_missile._ready(): after `mesh_part = ModuleCatalog.get_missile_mesh("cruise_missile")`,
#    call `WeaponVFXCruiseMissile.make_missile_trail(self)` and store ref for cleanup.
# 2. weapon_missile.on_impact(): call
#    `WeaponVFXCruiseMissile.spawn_impact_sequence(_effects_parent(), global_position)`.
# 3. auto_weapon._fire_cruise_missile(): after `_spawn_missile(...)` returns missile,
#    call `WeaponVFXCruiseMissile.spawn_launch_boost(self, get_muzzle_local_pos())`.
# All calls use framework-cached materials; zero inline allocations.
# Draw cost: 1 trail (150 particles) + 1 impact sequence (1 fire_burst + 1 VFXBurst + 1 scorch + 1 smoke_puff + 1 rising column + 1 light) per shot.