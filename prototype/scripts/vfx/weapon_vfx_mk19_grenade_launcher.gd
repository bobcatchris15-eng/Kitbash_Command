extends RefCounted
class_name WeaponVFXMK19GrenadeLauncher

# MK19_GRENADE_LAUNCHER — Belt-fed automatic 40mm thumper
# Identity: stubby grenades on fast flat arcs, rapid thump-thump rhythm,
# small sharp grey puff-pops with crack + tiny scuffs, cheapest effect of the set.
# Framework-only: zero inline GPUParticles3D/StandardMaterial3D allocation.
# Draw budget: 1 flight mote per round (no trail) + 1 micro-burst on impact.
# Fires at 2 Hz (fire_rate=0.5) — minimal particles, maximum rhythm.

const VFXEffects = preload("res://scripts/vfx_effects.gd")
const VFXBurst = preload("res://scripts/vfx_burst.gd")
const MunitionPool = preload("res://scripts/munition_pool.gd")

# =====================================================================
# GRENADE BODY — Stubby 40mm casing, no trail (fast flat arc)
# =====================================================================

# Returns the visual body for a single grenade in flight.
# Call from _fire_grenade_launcher after creating the round node.
# parent = the round node (MeshInstance3D or Node3D pivot).
# Returns the configured MeshInstance3D (child of parent).
static func make_grenade_body(parent: Node3D) -> MeshInstance3D:
	var body = MeshInstance3D.new()
	body.name = "MK19GrenadeBody"
	body.mesh = MunitionPool.unit_sphere()
	# Small, stubby 40mm profile — 0.16m diameter matches legacy visual
	body.scale = Vector3(0.16, 0.16, 0.16)
	# Olive-drab casing with warm emissive core (thumper aesthetic)
	body.material_override = MunitionPool.emissive(
		Color(0.32, 0.36, 0.22),  # casing albedo
		Color(0.65, 0.55, 0.15)   # warm core glow
	)
	parent.add_child(body)
	return body


# =====================================================================
# FLIGHT MOTE — Discrete puff along the shallow arc (no bulk trail)
# =====================================================================

# Spawns a single grey smoke mote at a point along the grenade's arc.
# Cheap, one-shot, auto-free — fired 2-3 times per flight at 2 Hz.
# parent = effects parent (scene root for world-space persistence).
# world_pos = position along arc in world space.
# Returns the mote GPUParticles3D (one-shot, auto-free).
static func spawn_flight_mote(parent: Node3D, world_pos: Vector3) -> GPUParticles3D:
	# Tiny sharp grey puff — 4 particles, 0.35s lifetime, no turbulence.
	var p = GPUParticles3D.new()
	p.name = "MK19FlightMote"
	p.amount = 4
	p.lifetime = 0.35
	p.one_shot = true
	p.explosiveness = 0.6
	p.emitting = false
	p.local_coords = false  # world-space so it stays at arc position
	p.draw_pass_1 = VFXEffects._get_quad()
	p.material_override = VFXEffects._billboard_material(
		VFXEffects.SMOKE_TEX, false, Color(0.45, 0.43, 0.40, 0.55))
	
	var mat_key = "mk19_flight_mote"
	if VFXEffects._process_cache.has(mat_key):
		p.process_material = VFXEffects._process_cache[mat_key]
	else:
		var mat = ParticleProcessMaterial.new()
		mat.direction = Vector3(0, 1, 0)  # slight upward drift
		mat.spread = 60.0
		mat.initial_velocity_min = 0.3
		mat.initial_velocity_max = 0.8
		mat.gravity = Vector3(0, 0.2, 0)  # gentle settle
		mat.scale_min = 0.12
		mat.scale_max = 0.22
		mat.damping_min = 1.5
		mat.damping_max = 1.5
		mat.angle_min = -180.0
		mat.angle_max = 180.0
		mat.anim_speed_min = 1.0
		mat.anim_speed_max = 1.0
		mat.anim_offset_min = 0.0
		mat.anim_offset_max = 0.25
		
		# Quick bloom then fade — sells "sharp puff" not "lingering smoke"
		var curve = CurveTexture.new()
		var c = Curve.new()
		c.add_point(Vector2(0.0, 0.25))
		c.add_point(Vector2(0.15, 1.0))
		c.add_point(Vector2(0.5, 0.6))
		c.add_point(Vector2(1.0, 0.05))
		curve.curve = c
		mat.scale_curve = curve
		
		VFXEffects._process_cache[mat_key] = mat
		p.process_material = mat
	
	parent.add_child(p)
	p.global_position = world_pos
	p.emitting = true
	p.finished.connect(func(): if is_instance_valid(p): p.queue_free())
	return p


# =====================================================================
# IMPACT — Micro burst: grey puff-pop + crack debris + tiny scuff decal
# =====================================================================

# Spawns the impact visual at grenade detonation point.
# parent = effects parent (scene root).
# world_pos = impact position in world space.
# blast_radius = from _fire_grenade_launcher (2.2).
# Returns the primary burst GPUParticles3D (one-shot, auto-free).
static func spawn_impact(parent: Node3D, world_pos: Vector3, blast_radius: float) -> GPUParticles3D:
	# 1. Grey puff-pop — sharp, fast, small (VFXEffects.smoke_puff path)
	VFXEffects.smoke_puff(
		parent,
		world_pos,
		blast_radius * 0.55,  # ~1.2m — tight blast visual
		6,                    # minimal particle count
		Color(0.38, 0.36, 0.33, 0.65)  # sharp grey, not brown
	)
	
	# 2. Crack debris — VFXBurst with sphere mesh, kinetic "pop"
	var burst = VFXBurst.spawn(
		parent,
		Vector3.ZERO,  # local_pos; we set global_position after
		Color(0.55, 0.52, 0.48, 1.0),  # pale concrete-grey
		8,                              # tiny count
		0.25,                           # very short lifetime
		180.0,                          # full sphere spread
		6.0,                            # speed_min — sharp crack
		14.0,                           # speed_max
		Vector3(0, -4.0, 0),            # sharp gravity drop
		0.06,                           # scale_min — tiny fragments
		0.14,                           # scale_max
		VFXBurst.get_sphere_mesh(),     # round pellets = "crack"
		Vector3.ZERO,                   # forward_dir=0 → sphere emission
		Color(0.9, 0.7, 0.3, 1.0),      # light_color: warm thump flash
		3.0,                            # light_range — tiny
		6.0                             # light_energy
	)
	burst.global_position = world_pos
	
	# 3. Tiny scuff decal — ground mark, fades fast
	VFXEffects.scorch(
		parent,
		world_pos,
		blast_radius * 0.4,  # ~0.9m — tiny footprint
		0.0,                 # no burn phase
		6.0                  # fade fast — cheap effect
	)
	
	return burst


# =====================================================================
# MUZZLE THUMP — The "thump" visual at the launcher mouth
# =====================================================================

# One-shot muzzle flash for each grenade fired.
# parent = the weapon module node (auto_weapon instance).
# local_pos = muzzle position in weapon local space (get_muzzle_local_pos()).
# Returns the flash GPUParticles3D (one-shot, auto-free).
static func spawn_muzzle_thump(parent: Node3D, local_pos: Vector3) -> GPUParticles3D:
	# Sharp, directional "cough" — not a flame tongue, a pressure pop.
	var p = GPUParticles3D.new()
	p.name = "MK19MuzzleThump"
	p.amount = 6
	p.lifetime = 0.08
	p.one_shot = true
	p.explosiveness = 1.0
	p.emitting = false
	p.local_coords = true
	p.draw_pass_1 = VFXEffects._get_quad()
	# Pale grey-white pressure flash, slightly additive
	p.material_override = VFXEffects._billboard_material(
		VFXEffects.SMOKE_TEX, true, Color(0.85, 0.82, 0.78, 0.85))
	
	var mat_key = "mk19_muzzle_thump"
	if VFXEffects._process_cache.has(mat_key):
		p.process_material = VFXEffects._process_cache[mat_key]
	else:
		var mat = ParticleProcessMaterial.new()
		# Forward along -Z (weapon forward), tight cone
		mat.direction = Vector3(0, 0, -1)
		mat.spread = 18.0
		mat.initial_velocity_min = 8.0
		mat.initial_velocity_max = 18.0
		mat.gravity = Vector3(0, -2.0, 0)  # slight drop — heavy gas
		mat.scale_min = 0.25
		mat.scale_max = 0.6
		mat.damping_min = 3.0
		mat.damping_max = 3.0
		mat.angle_min = -180.0
		mat.angle_max = 180.0
		mat.anim_speed_min = 1.0
		mat.anim_speed_max = 1.0
		mat.anim_offset_min = 0.0
		mat.anim_offset_max = 0.15
		
		# Instant flash, instant gone
		var curve = CurveTexture.new()
		var c = Curve.new()
		c.add_point(Vector2(0.0, 1.0))
		c.add_point(Vector2(0.3, 0.4))
		c.add_point(Vector2(1.0, 0.0))
		curve.curve = c
		mat.scale_curve = curve
		
		VFXEffects._process_cache[mat_key] = mat
		p.process_material = mat
	
	parent.add_child(p)
	p.position = local_pos
	p.emitting = true
	p.finished.connect(func(): if is_instance_valid(p): p.queue_free())
	return p


# =====================================================================
# WIRE-IN SPEC (for _fire_grenade_launcher in auto_weapon.gd)
# =====================================================================
# 1. Replace inline grenade MeshInstance3D creation:
#    var round = Node3D.new()
#    WeaponVFXMK19GrenadeLauncher.make_grenade_body(round)
#    parent.add_child(round)  # round is the tween target
#
# 2. During flight tween (0.35s), emit 2-3 flight motes at intervals:
#    tween.tween_callback(WeaponVFXMK19GrenadeLauncher.spawn_flight_mote.bind(
#        _effects_parent(), lerp_position_along_arc)).set_delay(0.12)
#    (repeat at ~0.24s) — OR use a sub-tween with parallel callbacks.
#
# 3. At impact (tween.finished), REPLACE inline _deal_aoe_damage + _spawn_explosion_visual:
#    _deal_aoe_damage(end, 2.2, dps * fire_rate)  # KEEP damage
#    WeaponVFXMK19GrenadeLauncher.spawn_impact(_effects_parent(), end, 2.2)
#
# 4. At fire start, add muzzle thump:
#    WeaponVFXMK19GrenadeLauncher.spawn_muzzle_thump(self, get_muzzle_local_pos())
#
# All calls use framework-cached materials; zero inline allocations.
# Draw cost per shot: 1 body (shared mesh) + 2-3 motes (4 pts each) + 1 impact burst (8 pts) + 1 scuff decal + 1 muzzle thump (6 pts).
# At 2 Hz sustained: ~40 particles max concurrent — cheapest weapon VFX in the roster.