extends RefCounted
class_name WeaponVFXHypervelocityMissile

# HYPERVELOCITY_MISSILE — Rail-Launched Kinetic Dart
# Identity: needle-thin white-hot streak, near-instant flat flight,
# kinetic penetrator impact — white-blue flash, minimal fireball,
# huge spark cone + dust lance, shallow gouge.
# Framework-only: zero inline GPUParticles3D/StandardMaterial3D allocation.
# Draw budget: 1 missile trail (bulk=1.0) + 1 penetrator impact per dart.
# Ripple fire (2–4 darts @ 0.06s stagger) multiplies draws linearly.

const VFXEffects = preload("res://scripts/vfx_effects.gd")
const VFXBurst = preload("res://scripts/vfx_burst.gd")
const ModuleCatalog = preload("res://scripts/module_catalog.gd")

# =====================================================================
# MISSILE TRAIL — Railgun dart: needle-thin white-hot streak
# =====================================================================

# Returns a configured GPUParticles3D for the hypervelocity dart trail.
# Call from weapon_missile._ready() when mesh_part == "hypervelocity_missile".
# parent = the missile node (weapon_missile instance).
static func make_dart_trail(parent: Node3D) -> GPUParticles3D:
	# White-hot contrail: extremely tight, short-lived, high-velocity particles
	# that read as a laser-straight line at RTS zoom. No buoyancy, no curl.
	var p = GPUParticles3D.new()
	p.name = "HVMDartTrail"
	p.amount = 60  # bulk=1.0 scaled: clamp(120*1.0, 24, 600) → 120, tuned down for needle line
	p.lifetime = 0.35  # very short — the dart crosses the map in ~0.55s
	p.emitting = false
	p.local_coords = false  # world-space trail (framework contract)
	p.draw_pass_1 = VFXEffects._get_quad()
	# White-blue hot streak, high alpha for visibility at speed
	p.material_override = VFXEffects._billboard_material(
		VFXEffects.SMOKE_TEX, true, Color(0.85, 0.95, 1.0, 0.85))

	# Process material: near-zero spread, high initial velocity, no gravity
	var mat_key = "hvm_dart_trail|rail_streak"
	if VFXEffects._process_cache.has(mat_key):
		p.process_material = VFXEffects._process_cache[mat_key]
	else:
		var mat = ParticleProcessMaterial.new()
		mat.direction = Vector3(0, 0, 1)  # missile flies +Z in local, world-space trail
		mat.spread = 0.8  # extremely tight — reads as a single line
		# Particles match missile velocity so they appear stationary relative to dart
		mat.initial_velocity_min = 0.5
		mat.initial_velocity_max = 2.0
		mat.gravity = Vector3.ZERO  # no droop — flat flight
		mat.scale_min = 0.05
		mat.scale_max = 0.12
		mat.damping_min = 0.0
		mat.damping_max = 0.0
		mat.angle_min = -180.0
		mat.angle_max = 180.0
		mat.anim_speed_min = 1.0
		mat.anim_speed_max = 1.0
		mat.anim_offset_min = 0.0
		mat.anim_offset_max = 0.25

		# Scale curve: born at max brightness, rapid fade to nothing
		var curve = CurveTexture.new()
		var c = Curve.new()
		c.add_point(Vector2(0.0, 1.0))     # full intensity at birth
		c.add_point(Vector2(0.25, 0.4))    # rapid taper
		c.add_point(Vector2(0.6, 0.15))    # thin line
		c.add_point(Vector2(1.0, 0.02))    # vanishes
		curve.curve = c
		mat.scale_curve = curve

		# No turbulence — rail dart is dead straight
		mat.turbulence_enabled = false

		VFXEffects._process_cache[mat_key] = mat
		p.process_material = mat

	parent.add_child(p)
	# Position at missile rear (+Z in missile local, but local_coords=false so world pos)
	p.position = Vector3(0, 0, 0.2)
	p.emitting = true
	return p


# =====================================================================
# IMPACT — Kinetic penetrator: white-blue flash, spark cone + dust lance, shallow gouge
# =====================================================================

# Spawns the penetrator impact sequence at intercept point.
# parent = scene root or effects parent (for world-space persistence).
# world_pos = intercept position in world space.
# scale = impact scale multiplier (default 1.0 from framework roster).
static func spawn_penetrator_impact(parent: Node3D, world_pos: Vector3, scale: float = 1.0) -> void:
	if not is_instance_valid(parent):
		return

	var scene = parent
	if not scene.is_inside_tree():
		scene = parent.get_tree().current_scene if parent.get_tree().current_scene else parent.get_tree().root

	var entropy := randf_range(0.9, 1.1)
	var impact_pos := world_pos + Vector3(randf_range(-0.03, 0.03), 0, randf_range(-0.03, 0.03))

	# --- WHITE-BLUE FLASH (minimal fireball) ---
	# Tiny, intense additive burst — reads as a kinetic "snap", not an explosion
	VFXEffects.fire_burst(scene, impact_pos, 0.35 * scale * entropy,
		Color(0.9, 0.95, 1.0, 1.0))

	# --- HUGE SPARK CONE (kinetic shrapnel spray) ---
	# Narrow forward cone, very high velocity, white-hot spark meshes
	var spark_count := int(36.0 * scale * entropy)
	VFXBurst.spawn(
		scene,
		impact_pos,
		Color(0.95, 1.0, 1.0, 1.0),   # white-hot with blue shift
		spark_count,
		0.28,                          # brief — penetrator debris vanishes fast
		18.0,                          # tight cone half-angle
		28.0 * scale, 55.0 * scale,    # very high speed (kinetic energy)
		Vector3(0, -4.0, 0),           # slight gravity droop
		0.15 * scale, 0.35 * scale,    # small angular shards
		VFXBurst.get_box_mesh(),       # box mesh = angular fragments
		Vector3(0, 0, -1),             # forward_dir = missile forward (-Z)
		Color(0.8, 0.9, 1.0, 1.0),     # light_color: white-blue
		5.0 * scale,                   # light_range
		14.0 * scale                   # light_energy
	)

	# --- DUST LANCE (ground interaction) ---
	# Flat, fast-expanding ring of fine dust along impact vector
	var dust = GPUParticles3D.new()
	dust.name = "HVMDustLance"
	dust.amount = int(clampf(18.0 * scale, 12, 28))
	dust.lifetime = 0.55
	dust.one_shot = true
	dust.explosiveness = 1.0
	dust.emitting = false
	dust.local_coords = false
	dust.draw_pass_1 = VFXEffects._get_quad()
	dust.material_override = VFXEffects._billboard_material(
		VFXEffects.SMOKE_TEX, false, Color(0.45, 0.42, 0.38, 0.6))
	dust.process_material = VFXEffects._process_material(
		"hvm_dust_lance|%.2f" % scale,
		Vector3(0, 1, 0), 160.0,       # near-hemisphere = flat ring
		scale * 8.0, scale * 16.0,     # fast radial expansion
		Vector3(0, 0.8, 0),            # gentle lift
		scale * 0.6, scale * 1.4,
		2.0, 0.0, 1.0)
	scene.add_child(dust)
	dust.global_position = impact_pos
	dust.emitting = true
	dust.finished.connect(func(): if is_instance_valid(dust): dust.queue_free())

	# --- SHALLOW GOUGE (crater decal) ---
	# Narrow, elongated crater — kinetic penetrator gouge, not a bomb crater
	VFXEffects.crater(scene, impact_pos, 0.65 * scale, 35.0)

	# --- IMPACT LIGHT POP — white-blue, sharp, fast fade ---
	var light = OmniLight3D.new()
	light.light_color = Color(0.85, 0.92, 1.0)
	light.light_energy = 8.0 * scale
	light.omni_range = 6.0 * scale
	light.omni_attenuation = 0.6
	light.light_bake_mode = Light3D.BAKE_DISABLED
	scene.add_child(light)
	light.global_position = impact_pos
	var lt = scene.create_tween()
	lt.tween_property(light, "light_energy", 0.0, 0.08)  # very fast — kinetic snap
	lt.finished.connect(func(): if is_instance_valid(light): light.queue_free())


# =====================================================================
# LAUNCH RAIL VFX — Optional: railgun muzzle flash at launcher
# =====================================================================

# One-shot railgun discharge at the weapon muzzle when a dart launches.
# parent = the weapon module node (auto_weapon instance).
# local_pos = muzzle position in weapon local space (get_muzzle_local_pos()).
static func spawn_rail_muzzle_flash(parent: Node3D, local_pos: Vector3) -> GPUParticles3D:
	var p = GPUParticles3D.new()
	p.name = "HVMRailMuzzle"
	p.amount = 14
	p.lifetime = 0.08
	p.one_shot = true
	p.explosiveness = 1.0
	p.emitting = false
	p.local_coords = true
	p.draw_pass_1 = VFXEffects._get_quad()
	# Intense white-blue electrical flash
	p.material_override = VFXEffects._billboard_material(
		VFXEffects.FLAME_TEX, true, Color(0.9, 0.95, 1.0, 1.0))
	p.process_material = VFXEffects._process_material(
		"hvm_rail_muzzle",
		Vector3(0, 0, -1), 8.0,        # narrow forward cone
		18.0, 35.0,                    # high velocity
		Vector3.ZERO,
		0.3, 0.8,                      # small
		1.5, 0.0, 0.0)
	parent.add_child(p)
	p.position = local_pos
	p.emitting = true
	p.finished.connect(func(): if is_instance_valid(p): p.queue_free())

	# Electrical arc tendrils (subtle, using VFXBurst sphere emission)
	VFXBurst.spawn(
		parent,
		local_pos,
		Color(0.6, 0.8, 1.0, 0.8),
		8,
		0.12,
		45.0,
		4.0, 10.0,
		Vector3.ZERO,
		0.1, 0.25,
		VFXBurst.get_sphere_mesh(),
		Vector3.ZERO,
		Color(0.5, 0.7, 1.0, 1.0),
		3.0, 6.0)

	return p


# =====================================================================
# INTERCEPTION — Dart destroyed by point defense
# =====================================================================

# Called when a hypervelocity dart is intercepted mid-flight.
# parent = scene root, world_pos = interception point.
static func spawn_interception_flash(parent: Node3D, world_pos: Vector3) -> void:
	if not is_instance_valid(parent):
		return
	var scene = parent
	if not scene.is_inside_tree():
		scene = parent.get_tree().current_scene if parent.get_tree().current_scene else parent.get_tree().root

	var entropy := randf_range(0.85, 1.15)

	# White-blue shatter burst — dart disintegrates
	VFXBurst.spawn(
		scene,
		world_pos,
		Color(0.7, 0.85, 1.0, 1.0),
		int(16.0 * entropy),
		0.2,
		60.0,
		6.0 * entropy, 14.0 * entropy,
		Vector3(0, -2.0, 0),
		0.12, 0.28,
		VFXBurst.get_box_mesh(),
		Vector3.ZERO,
		Color(0.6, 0.8, 1.0, 1.0),
		4.0, 8.0)

	# Minimal smoke puff
	VFXEffects.smoke_puff(scene, world_pos, 0.4 * entropy, 4,
		Color(0.25, 0.25, 0.3, 0.4))

	# Sharp cyan-white light
	var light = OmniLight3D.new()
	light.light_color = Color(0.7, 0.9, 1.0)
	light.light_energy = 5.0 * entropy
	light.omni_range = 3.5 * entropy
	light.omni_attenuation = 0.7
	light.light_bake_mode = Light3D.BAKE_DISABLED
	scene.add_child(light)
	light.global_position = world_pos
	var lt = scene.create_tween()
	lt.tween_property(light, "light_energy", 0.0, 0.06)
	lt.finished.connect(func(): if is_instance_valid(light): light.queue_free())


# =====================================================================
# WIRE-IN SPEC (for _fire_hypervelocity_missile in auto_weapon.gd)
# =====================================================================
# 1. In weapon_missile._ready():
#    if mesh_part == "hypervelocity_missile":
#        WeaponVFXHypervelocityMissile.make_dart_trail(self)  # replaces VFXEffects.make_missile_trail(self)
#        # Optional: replace procedural body with authored rail-dart mesh if available
#
# 2. In weapon_missile._spawn_impact_visual():
#    if owner_weapon and owner_weapon.type_id == "hypervelocity_missile":
#        WeaponVFXHypervelocityMissile.spawn_penetrator_impact(scene, _impact_pos, 1.0)
#        return
#
# 3. In weapon_missile.destroy_missile(intercepted):
#    if intercepted and owner_weapon and owner_weapon.type_id == "hypervelocity_missile":
#        WeaponVFXHypervelocityMissile.spawn_interception_flash(scene, global_position)
#        return  # skip default interception VFX
#
# 4. In auto_weapon._fire_hypervelocity_missile():
#    After _effects_parent().add_child(m) for each dart:
#    WeaponVFXHypervelocityMissile.spawn_rail_muzzle_flash(self, get_muzzle_local_pos())
#
# All calls use framework-cached materials; zero inline allocations.
# Draw cost per dart: 1 trail (persistent) + 1 impact (spark cone + dust lance + crater + light).
# Ripple of 4 darts = 4 trails + 4 impacts max concurrent.