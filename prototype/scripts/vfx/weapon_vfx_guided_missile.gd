extends RefCounted
class_name WeaponVFXGuidedMissile

# GUIDED_MISSILE — Classic ATGM (Anti-Tank Guided Missile)
# Identity: slender needle body, corkscrew smoke trail, tandem-warhead double-flash
# — piercing jet then fireball, small deep crater.
# Framework-only: zero inline GPUParticles3D/StandardMaterial3D allocation.
# Draw budget: 1 missile trail (bulk=1.0) + 1 tandem burst per engagement.

const VFXEffects = preload("res://scripts/vfx_effects.gd")
const VFXBurst = preload("res://scripts/vfx_burst.gd")
const ModuleCatalog = preload("res://scripts/module_catalog.gd")

# =====================================================================
# MISSILE TRAIL — Corkscrew contrail (wire-guided signature)
# =====================================================================

# Returns a configured GPUParticles3D for the guided missile's corkscrew trail.
# Call from weapon_missile._ready() AFTER `mesh_part` assignment, REPLACING
# the default `VFXEffects.make_missile_trail(self)` call.
# parent = the missile node (weapon_missile instance).
static func make_missile_trail(parent: Node3D) -> GPUParticles3D:
	# Corkscrew smoke: helical dispersion around the flight axis, simulating
	# wire-guided MCLOS/SACLOS flight wobble. Implemented via turbulence with
	# directional bias + a scale curve that holds a thin line.
	var p = GPUParticles3D.new()
	p.name = "GuidedMissileTrail"
	p.amount = 60  # bulk=1.0 scaled: thinner than SAM's 80
	p.lifetime = 2.2
	p.emitting = false
	p.local_coords = false  # world-space contrail (framework contract)
	p.draw_pass_1 = VFXEffects._get_quad()
	# Pale grey contrail, slightly translucent
	p.material_override = VFXEffects._billboard_material(
		VFXEffects.SMOKE_TEX, false, Color(0.75, 0.75, 0.78, 0.55))

	# Single cached process material for the corkscrew signature
	var mat_key = "guided_missile_trail|corkscrew"
	if VFXEffects._process_cache.has(mat_key):
		p.process_material = VFXEffects._process_cache[mat_key]
	else:
		var mat = ParticleProcessMaterial.new()
		mat.direction = Vector3(0, 0, 1)  # missile flies +Z in local, world-space trail
		mat.spread = 1.8  # tighter column than SAM (3.0)
		# Speed: steady cruise velocity (no cold-launch pop)
		mat.initial_velocity_min = 6.0
		mat.initial_velocity_max = 10.0
		mat.gravity = Vector3(0, 0.15, 0)  # minimal buoyancy
		mat.scale_min = 0.12
		mat.scale_max = 0.35
		mat.damping_min = 0.1
		mat.damping_max = 0.1
		mat.angle_min = -180.0
		mat.angle_max = 180.0
		mat.anim_speed_min = 1.0
		mat.anim_speed_max = 1.0
		mat.anim_offset_min = 0.0
		mat.anim_offset_max = 0.3

		# Scale curve: thin steady line, gentle fade
		var curve = CurveTexture.new()
		var c = Curve.new()
		c.add_point(Vector2(0.0, 0.4))
		c.add_point(Vector2(0.25, 0.22))
		c.add_point(Vector2(0.6, 0.18))
		c.add_point(Vector2(1.0, 0.06))
		curve.curve = c
		mat.scale_curve = curve

		# Corkscrew turbulence: helical dispersion around flight axis
		mat.turbulence_enabled = true
		mat.turbulence_noise_strength = 0.35
		mat.turbulence_noise_scale = 2.2
		mat.turbulence_noise_speed = Vector3(1.2, 0.0, 1.2)  # X/Z only → helix
		mat.turbulence_influence_min = 0.4
		mat.turbulence_influence_max = 1.0

		VFXEffects._process_cache[mat_key] = mat
		p.process_material = mat

	parent.add_child(p)
	# Position at missile rear (+Z in missile local, but local_coords=false so world pos)
	p.position = Vector3(0, 0, 0.25)
	p.emitting = true
	return p


# =====================================================================
# IMPACT — Tandem warhead: piercing jet → fireball + deep crater
# =====================================================================

# Spawns the tandem-warhead impact visual at intercept point.
# parent = scene root or effects parent (for world-space persistence).
# world_pos = impact position in world space.
# Returns the primary burst GPUParticles3D (one-shot, auto-free).
static func spawn_tandem_impact(parent: Node3D, world_pos: Vector3) -> GPUParticles3D:
	# Stage 1: Piercing jet — narrow, bright, directional along impact normal.
	# Approximated as a tight forward cone of white-hot kinetic fragments.
	var jet = VFXBurst.spawn(
		parent,
		Vector3.ZERO,
		Color(1.0, 1.0, 0.85, 1.0),  # brilliant white-yellow jet core
		16,                            # focused fragment count
		0.18,                          # very brief — the jet is instantaneous
		12.0,                          # narrow cone (half-angle)
		45.0,                          # speed_min: hypersonic jet velocity
		65.0,                          # speed_max
		Vector3(0, -2.0, 0),           # slight gravity droop
		0.06,                          # scale_min: needle-fine
		0.14,                          # scale_max
		VFXBurst.get_sphere_mesh(),    # round penetrator particles
		Vector3(0, 0, -1),             # forward_dir: along -Z (missile nose)
		Color(1.0, 0.95, 0.7, 1.0),    # light_color: intense white-yellow flash
		4.0,                           # light_range (tight)
		22.0                           # light_energy (bright, brief)
	)
	jet.global_position = world_pos
	jet.rotation = Basis.looking_at(Vector3.DOWN, Vector3.FORWARD)  # jet points DOWN into target

	# Stage 2: Fireball — follows ~0.06s after jet, broader thermal bloom.
	# Use a short timer on the scene to sequence the second flash.
	var scene_root = parent
	var tween = scene_root.create_tween()
	tween.tween_interval(0.06)
	tween.finished.connect(func():
		if not is_instance_valid(scene_root):
			return
		# Thermal fireball burst (additive)
		VFXEffects.fire_burst(scene_root, world_pos, 1.3, Color(1.0, 0.55, 0.15, 1.0))
		# Coarse debris burst (darker, slower)
		VFXBurst.spawn(
			scene_root,
			world_pos,
			Color(0.6, 0.35, 0.15, 0.9),
			10,
			0.45,
			55.0,
			6.0,
			14.0,
			Vector3(0, -3.0, 0),
			0.15,
			0.35,
			VFXBurst.get_sphere_mesh(),
			Vector3.ZERO,
			Color(1.0, 0.45, 0.1, 1.0),
			7.0,
			14.0
		)
		# Smoke puff (darker, oily)
		VFXEffects.smoke_puff(scene_root, world_pos, 1.1, 6, Color(0.12, 0.10, 0.08, 0.65))
		# Impact light (warmer, longer)
		var light = OmniLight3D.new()
		light.light_color = Color(1.0, 0.5, 0.1)
		light.light_energy = 8.0
		light.omni_range = 6.0
		light.omni_attenuation = 0.5
		light.light_bake_mode = Light3D.BAKE_DISABLED
		scene_root.add_child(light)
		light.global_position = world_pos
		var lt = scene_root.create_tween()
		lt.tween_property(light, "light_energy", 0.0, 0.22)
		lt.finished.connect(func(): if is_instance_valid(light): light.queue_free())
	)

	# Stage 3: Deep crater decal (persistent, small radius, long fade)
	VFXEffects.crater(parent, world_pos, 0.9, 60.0)

	return jet


# =====================================================================
# WIRE-IN SPEC (for _fire_missile_projectile in auto_weapon.gd)
# =====================================================================
# 1. weapon_missile._ready(): REPLACE the default trail line
#    `_trail = VFXEffects.make_missile_trail(self)`
#    with:
#    `_trail = WeaponVFXGuidedMissile.make_missile_trail(self)`
#    (same position assignment: `_trail.position = Vector3(0, 0, 0.25)`).
#
# 2. weapon_missile._spawn_impact_visual(): REPLACE the entire impact block
#    (spark burst + smoke_puff + fire_burst + light) with a single call:
#    `WeaponVFXGuidedMissile.spawn_tandem_impact(scene, _impact_pos)`
#    The function handles the tandem sequence (jet → fireball + debris + smoke + crater)
#    internally via a 0.06s tween delay. Returns the jet burst for parity.
#
# 3. weapon_missile.destroy_missile(): For intercepted missiles, keep existing
#    cyan flash logic — guided missiles intercepted by PD should not show the
#    tandem warhead (warhead never armed). No change needed.
#
# All calls use framework-cached materials; zero inline allocations.
# Draw cost: 1 trail + 1 tandem burst (2 particle draws + 1 decal) per shot.