extends RefCounted
class_name WeaponVFXClusterDispenser

# CLUSTER_DISPENSER — Airburst Carrier (Canister → Bomblets)
# Identity: clean carrier flight, mid-air POP scattering glowing submunition
# sparkles across a footprint, many tiny crackling pops + micro-craters,
# NO single big fireball. Framework-only: zero inline GPUParticles3D/StandardMaterial3D allocation.
# Draw budget: 1 canister trail (bulk=0.6) per canister + 1 pop burst per canister
# + 1 micro-burst per bomblet (capped: max 12 bomblets/shot = 4 canisters × 3).

const VFXEffects = preload("res://scripts/vfx_effects.gd")
const VFXBurst = preload("res://scripts/vfx_burst.gd")
const ModuleCatalog = preload("res://scripts/module_catalog.gd")

# =====================================================================
# CANISTER TRAIL — Clean lobbed flight signature (thin, dark, gravity-stable)
# =====================================================================

# Returns a configured GPUParticles3D for the cluster canister's flight trail.
# Call from _fire_cluster_dispenser() after instantiating the canister mesh.
# parent = the canister MeshInstance3D (or its pivot Node3D).
static func make_canister_trail(parent: Node3D) -> GPUParticles3D:
	# Thin dark smoke trail behind the lobbed canister. World-space so it
	# stays in the air while the canister arcs forward.
	var p = GPUParticles3D.new()
	p.name = "ClusterCanisterTrail"
	p.amount = 36  # bulk=0.6 scaled: clamp(120*0.6, 24, 600) → 72, tuned to 36 for thin trace
	p.lifetime = 1.2
	p.emitting = false
	p.local_coords = false  # world-space trail (framework contract)
	p.draw_pass_1 = VFXEffects._get_quad()
	# Dark grey smoke, slightly warm tint for "ordnance" feel
	p.material_override = VFXEffects._billboard_material(
		VFXEffects.SMOKE_TEX, false, Color(0.25, 0.23, 0.20, 0.55))

	var mat_key = "cluster_canister_trail|thin"
	if VFXEffects._process_cache.has(mat_key):
		p.process_material = VFXEffects._process_cache[mat_key]
	else:
		var mat = ParticleProcessMaterial.new()
		mat.direction = Vector3(0, 0, 1)  # canister flies +Z in local, world-space trail
		mat.spread = 8.0  # narrow column
		# Slow drift: canister lob is subsonic, trail hangs and disperses
		mat.initial_velocity_min = 0.5
		mat.initial_velocity_max = 2.0
		mat.gravity = Vector3(0, 0.8, 0)  # gentle buoyancy for hang
		mat.scale_min = 0.12
		mat.scale_max = 0.35
		mat.damping_min = 0.4
		mat.damping_max = 0.4
		mat.angle_min = -180.0
		mat.angle_max = 180.0
		mat.anim_speed_min = 1.0
		mat.anim_speed_max = 1.0
		mat.anim_offset_min = 0.0
		mat.anim_offset_max = 0.3

		# Scale curve: small puff at birth, steady thin line, fade to nothing
		var curve = CurveTexture.new()
		var c = Curve.new()
		c.add_point(Vector2(0.0, 0.6))
		c.add_point(Vector2(0.2, 0.4))
		c.add_point(Vector2(0.6, 0.25))
		c.add_point(Vector2(1.0, 0.05))
		curve.curve = c
		mat.scale_curve = curve

		# Subtle turbulence: air dispersion over the lob arc
		mat.turbulence_enabled = true
		mat.turbulence_noise_strength = 0.18
		mat.turbulence_noise_scale = 1.2
		mat.turbulence_noise_speed = Vector3(0.3, 0.15, 0.3)
		mat.turbulence_influence_min = 0.2
		mat.turbulence_influence_max = 0.6

		VFXEffects._process_cache[mat_key] = mat
		p.process_material = mat

	parent.add_child(p)
	# Position at canister rear (+Z in local, but local_coords=false so world pos)
	p.position = Vector3(0, 0, 0.2)
	p.emitting = true
	return p


# =====================================================================
# AIRBURST POP — The signature "canister opens" moment at mid-point
# =====================================================================

# Spawns the airburst pop at the canister's midpoint (where it opens).
# parent = scene root or effects parent (for world-space persistence).
# world_pos = midpoint position in world space (where canister pops).
# Returns the pop GPUParticles3D (one-shot, auto-free).
static func spawn_airburst_pop(parent: Node3D, world_pos: Vector3) -> GPUParticles3D:
	# Sharp "pop" — brief white-hot flash + dark ejecta ring. Not a fireball.
	# Uses VFXBurst.spawn with sphere emission for true 3D burst.
	var pop = VFXBurst.spawn(
		parent,
		Vector3.ZERO,  # local_pos; we set global_position after
		Color(1.0, 0.95, 0.85, 1.0),  # white-hot flash core
		18,                              # pop particle count (sharp, not cloudy)
		0.18,                            # lifetime (snappy)
		180.0,                           # full sphere spread
		14.0,                            # speed_min (ejection velocity)
		24.0,                            # speed_max
		Vector3(0, -3.0, 0),             # gravity droop for falling ejecta
		0.08,                            # scale_min (tiny fragments)
		0.18,                            # scale_max
		VFXBurst.get_sphere_mesh(),      # round pop fragments
		Vector3.ZERO,                    # forward_dir=0 → sphere emission
		Color(1.0, 0.9, 0.6, 1.0),       # light_color: warm white pop flash
		4.0,                             # light_range
		14.0                             # light_energy
	)
	pop.global_position = world_pos
	return pop


# =====================================================================
# BOMBLET IMPACT — Each submunition's tiny crackling pop + micro-crater
# =====================================================================

# Spawns a single bomblet impact at its scatter destination.
# parent = scene root or effects parent (for world-space persistence).
# world_pos = bomblet impact position in world space.
# payload_size = scales the micro-effect (from weapon tweaks).
# Returns the micro-burst GPUParticles3D (one-shot, auto-free).
static func spawn_bomblet_impact(parent: Node3D, world_pos: Vector3, payload_size: float = 1.0) -> GPUParticles3D:
	# Micro-burst: tiny kinetic pop + dark sparkle + micro-crater decal.
	# Count scales with payload_size but capped for draw budget.
	var count = int(clamp(8 * payload_size, 4, 12))
	var scale_base = 0.07 * payload_size

	# Sparkle burst: bright kinetic fragments, very short lived.
	var burst = VFXBurst.spawn(
		parent,
		Vector3.ZERO,
		Color(1.0, 0.75, 0.35, 1.0),  # kinetic gold-orange sparkle
		count,
		0.22,                            # lifetime (crackle speed)
		160.0,                           # wide but not full sphere (ground-hugging)
		8.0,                             # speed_min
		16.0,                            # speed_max
		Vector3(0, -6.0, 0),             # sharp gravity drop
		scale_base * 0.7,                # scale_min
		scale_base * 1.4,                # scale_max
		VFXBurst.get_sphere_mesh(),
		Vector3.ZERO,                    # sphere emission
		Color(1.0, 0.6, 0.2, 1.0),       # light_color: orange crackle
		2.5 * payload_size,              # light_range
		6.0 * payload_size               # light_energy
	)
	burst.global_position = world_pos

	# Micro-crater decal (handled by caller via VFXEffects.crater in _detonate_at).
	# This func only returns the particle burst; the decal is framework-driven.
	return burst


# =====================================================================
# CANISTER MUZZLE VENT — Optional: brief vent at launch cell on fire
# =====================================================================

# One-shot dark vent at the weapon muzzle when canister ejects.
# parent = the weapon module node (auto_weapon instance).
# local_pos = muzzle position in weapon local space (get_muzzle_local_pos()).
static func spawn_muzzle_vent(parent: Node3D, local_pos: Vector3) -> GPUParticles3D:
	var p = GPUParticles3D.new()
	p.name = "ClusterMuzzleVent"
	p.amount = 10
	p.lifetime = 0.25
	p.one_shot = true
	p.explosiveness = 1.0
	p.emitting = false
	p.local_coords = true
	p.draw_pass_1 = VFXEffects._get_quad()
	p.material_override = VFXEffects._billboard_material(
		VFXEffects.SMOKE_TEX, false, Color(0.2, 0.18, 0.15, 0.5))
	p.process_material = VFXEffects._process_material(
		"cluster_muzzle_vent",
		Vector3.UP, 60.0, 4.0, 10.0,
		Vector3(0, 1.5, 0), 0.2, 0.7, 0.6, 1.0, 0.7)
	parent.add_child(p)
	p.position = local_pos
	p.emitting = true
	p.finished.connect(func(): if is_instance_valid(p): p.queue_free())
	return p


# =====================================================================
# WIRE-IN SPEC (for _fire_cluster_dispenser in auto_weapon.gd)
# =====================================================================
# 1. Inside the per-canister timer callback, AFTER `canister` is instantiated
#    and added to the scene, call:
#       var trail = WeaponVFXClusterDispenser.make_canister_trail(canister)
#    (Store on canister if cleanup needed; trail dies with canister since local_coords=false
#     but parented to canister — reparent to scene root on canister queue_free if desired.)
#
# 2. At the canister's midpoint (the `mid` variable, where bomblets release),
#    call:
#       WeaponVFXClusterDispenser.spawn_airburst_pop(_effects_parent(), mid)
#
# 3. Inside each bomblet's finished handler (where `_deal_aoe_damage` +
#    `_spawn_explosion_visual` currently run), REPLACE the explosion visual
#    with:
#       WeaponVFXClusterDispenser.spawn_bomblet_impact(_effects_parent(), scatter_dest, payload_size)
#    The micro-crater decal is already produced by `_detonate_at`/`_spawn_explosion_visual`
#    blast_radius logic — keep the `_deal_aoe_damage` call, drop the custom
#    `_spawn_explosion_visual` for bomblets.
#
# 4. At the top of `_fire_cluster_dispenser` (after recoil, before the canister loop),
#    call once per shot:
#       WeaponVFXClusterDispenser.spawn_muzzle_vent(self, get_muzzle_local_pos())
#
# All calls use framework-cached materials; zero inline allocations.
# Draw cost per shot: t_count × (1 trail + 1 pop) + total_bomblets × 1 micro-burst.
# Capped: tube_count max 4 → 4 trails + 4 pops + 12 micro-bursts = 20 draw calls max.