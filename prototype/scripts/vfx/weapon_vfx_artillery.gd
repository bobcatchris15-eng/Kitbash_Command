extends RefCounted
class_name WeaponVFXArtillery

# ARTILLERY — Heavy Howitzer (T5 Operational tier)
# Identity: screaming high-arc shell with faint tracer whistle trail,
# classic HE impact — orange fireball + black smoke + tall dirt fountain
# + wide crater + heavy dust ring.
# Framework-only: zero inline GPUParticles3D/StandardMaterial3D allocation.
# Draw budget: 1 shell trail (bulk=0.25) + 1 impact burst per shot.

const VFXEffects = preload("res://scripts/vfx_effects.gd")
const VFXBurst = preload("res://scripts/vfx_burst.gd")
const ModuleCatalog = preload("res://scripts/module_catalog.gd")

# =====================================================================
# SHELL TRAIL — Faint tracer whistle on the high arc
# =====================================================================

# Returns a configured GPUParticles3D for the artillery shell's faint tracer trail.
# Call from auto_weapon._fire_arcing_shell_at via _attach_trail_to_round()
# after shell node creation, for the "artillery" type_id.
# parent = the shell node (Node3D pivot from _make_round_body).
# Returns the trail GPUParticles3D (world-space, reparented on shell death).
static func make_shell_trail(parent: Node3D) -> GPUParticles3D:
	# Faint whistle trail: thin, pale grey-white streaks that mark the
	# high parabola without reading as a missile plume. Low particle count,
	# short lifetime, subtle scale — the "scream" is visual, not volumetric.
	var p = GPUParticles3D.new()
	p.name = "ArtilleryShellTrail"
	p.amount = 18  # bulk=0.25 scaled: clamp(120*0.25, 24, 600) → 24, tuned down for whisper-thin line
	p.lifetime = 1.2
	p.emitting = false
	p.local_coords = false  # world-space trail (framework contract)
	p.draw_pass_1 = VFXEffects._get_quad()
	# Pale blue-white tracer, barely visible — reads as a "whistle" at RTS zoom
	p.material_override = VFXEffects._billboard_material(
		VFXEffects.SMOKE_TEX, false, Color(0.75, 0.78, 0.85, 0.25))
	
	# Process material: slow, straight, minimal turbulence
	var mat_key = "artillery_shell_trail|whistle"
	if VFXEffects._process_cache.has(mat_key):
		p.process_material = VFXEffects._process_cache[mat_key]
	else:
		var mat = ParticleProcessMaterial.new()
		mat.direction = Vector3(0, 0, 1)  # shell flies +Z in local, world-space trail
		mat.spread = 1.5  # extremely tight — a line, not a cloud
		mat.initial_velocity_min = 0.5
		mat.initial_velocity_max = 1.5  # nearly stationary relative to shell
		mat.gravity = Vector3(0, 0.1, 0)  # slight buoyancy for high-arc hang
		mat.scale_min = 0.08
		mat.scale_max = 0.18
		mat.damping_min = 0.05
		mat.damping_max = 0.05
		mat.angle_min = -180.0
		mat.angle_max = 180.0
		mat.anim_speed_min = 1.0
		mat.anim_speed_max = 1.0
		mat.anim_offset_min = 0.0
		mat.anim_offset_max = 0.2
		
		# Scale curve: born visible, fades to nothing by mid-life
		var curve = CurveTexture.new()
		var c = Curve.new()
		c.add_point(Vector2(0.0, 0.5))    # initial whisper
		c.add_point(Vector2(0.3, 0.35))   # steady
		c.add_point(Vector2(0.6, 0.15))   # thinning
		c.add_point(Vector2(1.0, 0.0))    # gone
		curve.curve = c
		mat.scale_curve = curve
		
		# Minimal turbulence: just enough to sell "air disturbance"
		mat.turbulence_enabled = true
		mat.turbulence_noise_strength = 0.08
		mat.turbulence_noise_scale = 2.5
		mat.turbulence_noise_speed = Vector3(0.2, 0.1, 0.2)
		mat.turbulence_influence_min = 0.2
		mat.turbulence_influence_max = 0.5
		
		VFXEffects._process_cache[mat_key] = mat
		p.process_material = mat
	
	parent.add_child(p)
	# Position at shell rear (+Z in shell local, but local_coords=false so world pos)
	p.position = Vector3(0, 0, 0.3)
	p.emitting = true
	return p


# =====================================================================
# IMPACT — Classic HE: orange fireball + black smoke + tall dirt fountain
#         + wide crater + heavy dust ring
# =====================================================================

# Spawns the full artillery HE impact at world position.
# parent = scene root or effects parent (for world-space persistence).
# world_pos = impact position in world space.
# Returns nothing; spawns multiple one-shot emitters + decals via framework.
static func spawn_artillery_impact(parent: Node3D, world_pos: Vector3) -> void:
	# 1. ORANGE FIREBALL — additive flame burst, large and brief
	VFXEffects.fire_burst(parent, world_pos, 2.8, Color(1.0, 0.55, 0.15, 1.0))
	
	# 2. BLACK SMOKE COLUMN — dense, rising, oil-black
	VFXEffects.smoke_puff(
		parent, world_pos + Vector3(0, 1.5, 0),
		2.2, 14, Color(0.06, 0.05, 0.04, 0.75))
	
	# 3. TALL DIRT FOUNTAIN — VFXBurst with upward velocity, brown debris
	var dirt_burst = VFXBurst.spawn(
		parent,
		Vector3.ZERO,  # local_pos; we set global_position after
		Color(0.45, 0.38, 0.30, 1.0),  # earth tone
		36,                              # debris count
		1.2,                             # lifetime
		110.0,                           # wide cone spread (near-hemisphere)
		8.0,                             # speed_min
		18.0,                            # speed_max
		Vector3(0, -6.0, 0),             # strong gravity pull-down
		0.18,                            # scale_min
		0.35,                            # scale_max
		VFXBurst.get_sphere_mesh(),      # round dirt clods
		Vector3(0, 1, 0),                # upward cone
		Color(1.0, 0.5, 0.1, 1.0),       # light_color: warm fireball fringe
		8.0,                             # light_range
		22.0                             # light_energy
	)
	dirt_burst.global_position = world_pos
	
	# 4. HEAVY DUST RING — ground-hugging radial burst, wide and flat
	var dust_ring = VFXBurst.spawn(
		parent,
		Vector3.ZERO,
		Color(0.55, 0.50, 0.45, 0.9),  # pale dust
		28,
		1.5,
		20.0,                            # very flat spread (ground ring)
		6.0,
		14.0,
		Vector3(0, -2.0, 0),             # quick settle
		0.6,
		1.4,
		VFXBurst.get_sphere_mesh(),
		Vector3(0, 0.1, 0),              # nearly horizontal
		Color(0.0, 0.0, 0.0, 0.0),       # no light
		0.0,
		0.0
	)
	dust_ring.global_position = world_pos + Vector3(0, 0.15, 0)
	
	# 5. GROUND DECALS — handled by auto_weapon._detonate_at() via framework
	#    (scorch at blast_radius*0.7, crater at blast_radius*0.5 for radius>=6.0)
	#    This function only spawns the aerial/particle components.


# =====================================================================
# LAUNCH VFX — Optional: breech gas vent on fire
# =====================================================================

# One-shot breech vent at the weapon mount when the howitzer fires.
# parent = the weapon module node (auto_weapon instance).
# local_pos = muzzle position in weapon local space (get_muzzle_local_pos()).
static func spawn_breech_vent(parent: Node3D, local_pos: Vector3) -> GPUParticles3D:
	var p = GPUParticles3D.new()
	p.name = "HowitzerBreechVent"
	p.amount = 12
	p.lifetime = 0.35
	p.one_shot = true
	p.explosiveness = 1.0
	p.emitting = false
	p.local_coords = true
	p.draw_pass_1 = VFXEffects._get_quad()
	p.material_override = VFXEffects._billboard_material(
		VFXEffects.SMOKE_TEX, false, Color(0.45, 0.42, 0.38, 0.5))
	p.process_material = VFXEffects._process_material(
		"howitzer_breech_vent",
		Vector3(0, 1, 0), 45.0, 4.0, 10.0,
		Vector3(0, 3.0, 0), 0.5, 1.2, 0.8, 1.0, 1.0)
	parent.add_child(p)
	p.position = local_pos
	p.emitting = true
	p.finished.connect(func(): if is_instance_valid(p): p.queue_free())
	return p


# =====================================================================
# WIRE-IN SPEC (for _fire_artillery in auto_weapon.gd)
# =====================================================================
# 1. auto_weapon._fire_arcing_shell_at() for type_id "artillery":
#    - profile = {"body":"bomb", "trail":"whistle", "trail_bulk":0.25}
#    - Inside _fire_arcing_shell_at, when profile.has("trail") and
#      profile["trail"] == "whistle", call:
#        var trail = WeaponVFXArtillery.make_shell_trail(shell)
#        _detach_trail_on_free(shell, trail)
#    - This replaces the discrete _spawn_flight_mote puffs currently used.
#
# 2. auto_weapon._detonate_at() (or _fire_artillery finished handler):
#    - After _deal_aoe_damage() and before _spawn_explosion_visual(),
#      call: WeaponVFXArtillery.spawn_artillery_impact(_effects_parent(), impact_pos)
#    - This REPLACES the current _spawn_explosion_visual() call for artillery.
#      The impact visual (fireball + smoke + dirt fountain + dust ring) is now
#      fully defined here; _spawn_explosion_visual should NOT also run for
#      artillery, or the fireball/smoke will double.
#
# 3. auto_weapon._fire_artillery() (the wrapper that calls _fire_arcing_shell_at):
#    - After _fire_arcing_shell_at() returns, call:
#      WeaponVFXArtillery.spawn_breech_vent(self, get_muzzle_local_pos())
#    - Optional but recommended for the "heavy howitzer" feel.
#
# All calls use framework-cached materials; zero inline allocations.
# Draw cost per shot: 1 shell trail (18 particles) + 1 fire_burst + 1 smoke_puff
# + 2 VFXBurst (dirt fountain + dust ring) = 4 draw calls + 2 decals (scorch+crater).