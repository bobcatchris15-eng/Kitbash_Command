extends RefCounted
class_name WeaponVFXLoiteringMunition

# LOITERING_MUNITION — Buzzing Kamikaze Drone (Loitering Shaped-Charge)
# Identity: wobbling prop-driven loiter with sputtering thin trail, diving
# top-attack with small shaped-charge pop + brief smoke puff. Not a missile —
# a slow, noisy drone that loiters then commits. Framework-only: zero inline
# GPUParticles3D/StandardMaterial3D allocation.
# Draw budget: 1 loiter trail (bulk=1.0) + 1 shaped-charge impact burst per engagement.

const VFXEffects = preload("res://scripts/vfx_effects.gd")
const VFXBurst = preload("res://scripts/vfx_burst.gd")
const ModuleCatalog = preload("res://scripts/module_catalog.gd")

# =====================================================================
# LOITER TRAIL — Wobbling prop-driven sputtering trail
# =====================================================================

# Returns a configured GPUParticles3D for the loitering munition's flight trail.
# Call from weapon_missile._ready() after mesh_part assignment.
# parent = the missile node (weapon_missile instance).
static func make_loiter_trail(parent: Node3D) -> GPUParticles3D:
	# Sputtering 2-stroke buzz: thin intermittent puff trail, world-space
	# so it hangs in air as the drone wobbles. Single emitter with a
	# lifetime curve that pulses emission density — no per-frame logic.
	var p = GPUParticles3D.new()
	p.name = "LoiterTrail"
	p.amount = 45  # bulk=1.0: clamp(60*1.0, 18, 300) → 60, tuned down for thin trail
	p.lifetime = 3.0
	p.emitting = false
	p.local_coords = false  # world-space trail (framework contract)
	p.draw_pass_1 = VFXEffects._get_quad()
	# Pale blue-grey exhaust, faint — reads as unburnt hydrocarbon sputter
	p.material_override = VFXEffects._billboard_material(
		VFXEffects.SMOKE_TEX, false, Color(0.55, 0.55, 0.65, 0.35))

	# Process material: wobble + sputter encoded in curves
	var mat_key = "loiter_trail|sputter"
	if VFXEffects._process_cache.has(mat_key):
		p.process_material = VFXEffects._process_cache[mat_key]
	else:
		var mat = ParticleProcessMaterial.new()
		mat.direction = Vector3(0, 0, 1)  # drone flies +Z in local, world-space trail
		mat.spread = 18.0  # wider than a missile — drone wobbles
		# Speed: slow sputter (2-6 m/s) — drone putters along
		mat.initial_velocity_min = 1.5
		mat.initial_velocity_max = 6.0
		mat.gravity = Vector3(0, 0.8, 0)  # slight buoyancy for loiter hang
		mat.scale_min = 0.12
		mat.scale_max = 0.28
		mat.damping_min = 0.25
		mat.damping_max = 0.25
		mat.angle_min = -180.0
		mat.angle_max = 180.0
		mat.anim_speed_min = 1.0
		mat.anim_speed_max = 1.0
		mat.anim_offset_min = 0.0
		mat.anim_offset_max = 0.3

		# Scale curve: pulse on/off — sputter rhythm (0.8s cycle over 3s life)
		var curve = CurveTexture.new()
		var c = Curve.new()
		c.add_point(Vector2(0.00, 0.10))  # quiet at birth
		c.add_point(Vector2(0.12, 0.55))  # first sputter puff
		c.add_point(Vector2(0.25, 0.08))  # gap
		c.add_point(Vector2(0.37, 0.50))  # second puff
		c.add_point(Vector2(0.50, 0.06))  # gap
		c.add_point(Vector2(0.62, 0.48))  # third puff
		c.add_point(Vector2(0.75, 0.05))  # gap
		c.add_point(Vector2(0.87, 0.45))  # final puff before dive
		c.add_point(Vector2(1.00, 0.03))  # fade at intercept
		curve.curve = c
		mat.scale_curve = curve

		# Turbulence: prop wash + wobble
		mat.turbulence_enabled = true
		mat.turbulence_noise_strength = 0.45
		mat.turbulence_noise_scale = 2.2
		mat.turbulence_noise_speed = Vector3(0.4, 0.2, 0.4)
		mat.turbulence_influence_min = 0.5
		mat.turbulence_influence_max = 1.0

		VFXEffects._process_cache[mat_key] = mat
		p.process_material = mat

	parent.add_child(p)
	# Position at drone rear (+Z in missile local, world-space trail)
	p.position = Vector3(0, 0, 0.35)
	p.emitting = true
	return p


# =====================================================================
# IMPACT — Top-attack shaped-charge pop + brief smoke puff
# =====================================================================

# Spawns the shaped-charge impact at intercept point (top-down dive).
# parent = scene root or effects parent (for world-space persistence).
# world_pos = intercept position in world space.
# Returns the impact GPUParticles3D (one-shot, auto-free).
static func spawn_shaped_charge_impact(parent: Node3D, world_pos: Vector3) -> GPUParticles3D:
	# Small shaped-charge pop: focused kinetic jet, not a spherical explosion.
	# Uses VFXBurst.sphere_emission with a tight downward cone to sell
	# the top-attack penetrator. Brief white-hot flash + dark smoke puff.
	var burst = VFXBurst.spawn(
		parent,
		Vector3.ZERO,  # local_pos; we set global_position after
		Color(1.0, 0.95, 0.85, 1.0),  # white-hot copper jet tint
		14,                              # pellet count — tight focused jet
		0.18,                            # lifetime — brief
		22.0,                            # tight cone half-angle (44° total)
		28.0,                            # speed_min (jet velocity)
		42.0,                            # speed_max
		Vector3(0, -4.0, 0),             # gravity pulls jet down
		0.08,                            # scale_min (fine jet particles)
		0.18,                            # scale_max
		VFXBurst.get_sphere_mesh(),      # round jet particles
		Vector3.DOWN,                    # forward_dir=DOWN → cone emission
		Color(1.0, 0.7, 0.3, 1.0),       # light_color: warm orange flash
		4.0,                             # light_range
		12.0                             # light_energy
	)
	burst.global_position = world_pos

	# Follow-up smoke puff: brief dark puff at the entry hole
	var smoke = VFXEffects.smoke_puff(
		parent,
		world_pos,
		0.9,                             # small radius
		6,                               # few puffs
		Color(0.18, 0.16, 0.14, 0.55)    # dark oily smoke
	)
	# The burst auto-frees; smoke_puff auto-frees. Return burst as primary.
	return burst


# =====================================================================
# LAUNCH POP — Optional: launcher cell vent on eject
# =====================================================================

# One-shot eject pop at the launcher when drone separates.
# parent = the weapon module node (auto_weapon instance).
# local_pos = muzzle position in weapon local space (get_muzzle_local_pos()).
static func spawn_launch_pop(parent: Node3D, local_pos: Vector3) -> GPUParticles3D:
	var p = GPUParticles3D.new()
	p.name = "LoiterLaunchPop"
	p.amount = 10
	p.lifetime = 0.35
	p.one_shot = true
	p.explosiveness = 1.0
	p.emitting = false
	p.local_coords = true
	p.draw_pass_1 = VFXEffects._get_quad()
	p.material_override = VFXEffects._billboard_material(
		VFXEffects.SMOKE_TEX, false, Color(0.5, 0.48, 0.45, 0.5))
	p.process_material = VFXEffects._process_material(
		"loiter_launch_pop",
		Vector3.UP, 65.0, 4.0, 10.0,
		Vector3(0, 1.5, 0), 0.2, 0.6, 0.4, 1.0, 0.9)
	parent.add_child(p)
	p.position = local_pos
	p.emitting = true
	p.finished.connect(func(): if is_instance_valid(p): p.queue_free())
	return p


# =====================================================================
# WIRE-IN SPEC (for _fire_loitering_munition in auto_weapon.gd)
# =====================================================================
# 1. weapon_missile._ready(): after `mesh_part = ModuleCatalog.get_missile_mesh("loitering_munition")`,
#    call `WeaponVFXLoiteringMunition.make_loiter_trail(self)` and store ref for cleanup.
# 2. weapon_missile.on_intercept(): call
#    `WeaponVFXLoiteringMunition.spawn_shaped_charge_impact(_effects_parent(), global_position)`.
# 3. auto_weapon._fire_loitering_munition(): after `_spawn_missile(...)` returns missile,
#    call `WeaponVFXLoiteringMunition.spawn_launch_pop(self, get_muzzle_local_pos())`.
# All calls use framework-cached materials; zero inline allocations.
# Draw cost: 1 loiter trail + 1 shaped-charge impact + 1 launch pop per shot.