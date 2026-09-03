extends RefCounted
class_name WeaponVFXSpigotMortar

# SPIGOT_MORTAR VFX Identity
# Crude heavy lobber: fat tumbling canister, oversized muzzle smoke ring,
# slow high lob, huge low-velocity WHUMP — wide dust doughnut + shallow scuff,
# more blast wave than fireball.

const VFXEffects = preload("res://scripts/vfx_effects.gd")
const VFXBurst = preload("res://scripts/vfx_burst.gd")
const MunitionPool = preload("res://scripts/munition_pool.gd")

# --- Muzzle ---
# Oversized smoke ring at the spigot mouth — the "pop" of a crude black-powder
# charge shoving a canister off a rod. One fat ring, no flame tongue.
# parent = weapon module node (auto_weapon instance), local_pos = muzzle local pos,
# forward_dir = barrel forward in parent local space, scale = payload_size multiplier.
static func spawn_muzzle_ring(parent: Node3D, local_pos: Vector3, forward_dir: Vector3, scale: float = 1.0) -> void:
	var p = GPUParticles3D.new()
	p.name = "SpigotMuzzleRing"
	p.amount = 1
	p.lifetime = 0.6
	p.one_shot = true
	p.explosiveness = 1.0
	p.emitting = false
	p.local_coords = true
	p.draw_pass_1 = VFXEffects._get_quad()
	p.material_override = VFXEffects._billboard_material(
		VFXEffects.SMOKE_TEX, false, Color(0.25, 0.23, 0.20, 0.75))
	var ring_key = "spigot_muzzle_ring|%.2f" % scale
	if VFXEffects._process_cache.has(ring_key):
		p.process_material = VFXEffects._process_cache[ring_key]
	else:
		var mat = ParticleProcessMaterial.new()
		mat.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_RING
		mat.emission_ring_inner_radius = 0.15 * scale
		mat.emission_ring_radius = 0.35 * scale
		mat.direction = forward_dir.normalized()
		mat.spread = 5.0
		mat.initial_velocity_min = 0.5 * scale
		mat.initial_velocity_max = 1.2 * scale
		mat.gravity = Vector3(0, 0.8, 0)
		mat.scale_min = 0.9 * scale
		mat.scale_max = 1.8 * scale
		mat.damping_min = 1.5
		mat.damping_max = 2.5
		mat.angle_min = -180.0
		mat.angle_max = 180.0
		mat.anim_speed_min = 1.0
		mat.anim_speed_max = 1.0
		mat.anim_offset_min = 0.0
		mat.anim_offset_max = 0.25
		var curve = CurveTexture.new()
		var c = Curve.new()
		c.add_point(Vector2(0.0, 0.4))
		c.add_point(Vector2(0.5, 1.0))
		c.add_point(Vector2(1.0, 0.0))
		curve.curve = c
		mat.scale_curve = curve
		VFXEffects._process_cache[ring_key] = mat
		p.process_material = mat
	parent.add_child(p)
	p.position = local_pos
	p.emitting = true
	p.finished.connect(func(): if is_instance_valid(p): p.queue_free())

# --- Flight motes (tumble highlight) ---
# Discrete ember flecks shed by the tumbling canister — NOT a continuous trail.
# Called from _fire_arcing_shell_at via profile["tumble"] == true.
# parent = shell node (the lobbed round), world_pos = mote world position,
# shell_radius = for scaling the mote size.
static func spawn_tumble_mote(parent: Node3D, world_pos: Vector3, shell_radius: float) -> void:
	var mote = MeshInstance3D.new()
	mote.mesh = MunitionPool.unit_sphere()
	mote.scale = Vector3.ONE * (shell_radius * 0.35)
	mote.material_override = MunitionPool.additive_emissive(
		Color(1.0, 0.55, 0.15, 0.6), Color(1.0, 0.45, 0.08), 0.7)
	parent.add_child(mote)
	mote.global_position = world_pos + Vector3(randf_range(-0.15, 0.15), -0.1, randf_range(-0.15, 0.15))
	var mt = mote.create_tween()
	mt.tween_property(mote, "scale", Vector3.ZERO, 0.4)
	mt.finished.connect(func(): if is_instance_valid(mote): mote.queue_free())

# --- Impact: the WHUMP ---
# Wide dust doughnut (horizontal blast wave) + shallow scuff (ground kiss),
# minimal fireball. More blast wave than fireball.
# parent = effects parent (scene root or match node), world_pos = impact world position,
# blast_radius = scaled by payload, color = team tint for light flash.
static func spawn_impact_whump(parent: Node3D, world_pos: Vector3, blast_radius: float, color: Color) -> void:
	# 1. Wide horizontal dust ring — the blast wave pushing out at ground level
	var ring = GPUParticles3D.new()
	ring.name = "SpigotBlastRing"
	ring.amount = int(clampf(blast_radius * 14.0, 24, 80))
	ring.lifetime = 1.1
	ring.one_shot = true
	ring.explosiveness = 1.0
	ring.emitting = false
	ring.draw_pass_1 = VFXEffects._get_quad()
	ring.material_override = VFXEffects._billboard_material(
		VFXEffects.SMOKE_TEX, false, Color(0.45, 0.42, 0.36, 0.65))
	var ring_key = "spigot_blast_ring|%.1f" % blast_radius
	if VFXEffects._process_cache.has(ring_key):
		ring.process_material = VFXEffects._process_cache[ring_key]
	else:
		var mat = ParticleProcessMaterial.new()
		mat.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_RING
		mat.emission_ring_inner_radius = blast_radius * 0.15
		mat.emission_ring_radius = blast_radius * 0.95
		mat.direction = Vector3.UP
		mat.spread = 8.0
		mat.initial_velocity_min = blast_radius * 0.6
		mat.initial_velocity_max = blast_radius * 1.3
		mat.gravity = Vector3(0, 0.3, 0)
		mat.scale_min = blast_radius * 0.35
		mat.scale_max = blast_radius * 0.85
		mat.damping_min = 0.8
		mat.damping_max = 1.4
		mat.angle_min = -180.0
		mat.angle_max = 180.0
		mat.anim_speed_min = 1.0
		mat.anim_speed_max = 1.0
		mat.anim_offset_min = 0.0
		mat.anim_offset_max = 0.3
		var curve = CurveTexture.new()
		var c = Curve.new()
		c.add_point(Vector2(0.0, 0.2))
		c.add_point(Vector2(0.3, 1.0))
		c.add_point(Vector2(1.0, 0.0))
		curve.curve = c
		mat.scale_curve = curve
		VFXEffects._process_cache[ring_key] = mat
		ring.process_material = mat
	parent.add_child(ring)
	ring.global_position = world_pos
	ring.emitting = true
	ring.finished.connect(func(): if is_instance_valid(ring): ring.queue_free())

	# 2. Shallow scuff — ground-hugging dust skim (very flat, wide)
	var scuff = GPUParticles3D.new()
	scuff.name = "SpigotScuff"
	scuff.amount = int(clampf(blast_radius * 8.0, 16, 48))
	scuff.lifetime = 0.7
	scuff.one_shot = true
	scuff.explosiveness = 1.0
	scuff.emitting = false
	scuff.draw_pass_1 = VFXEffects._get_quad()
	scuff.material_override = VFXEffects._billboard_material(
		VFXEffects.SMOKE_TEX, false, Color(0.55, 0.52, 0.46, 0.5))
	var scuff_key = "spigot_scuff|%.1f" % blast_radius
	if VFXEffects._process_cache.has(scuff_key):
		scuff.process_material = VFXEffects._process_cache[scuff_key]
	else:
		var mat = ParticleProcessMaterial.new()
		mat.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_BOX
		mat.emission_box_extents = Vector3(blast_radius * 0.9, 0.05, blast_radius * 0.9)
		mat.direction = Vector3.UP
		mat.spread = 12.0
		mat.initial_velocity_min = blast_radius * 0.4
		mat.initial_velocity_max = blast_radius * 0.9
		mat.gravity = Vector3(0, 0.6, 0)
		mat.scale_min = blast_radius * 0.4
		mat.scale_max = blast_radius * 0.9
		mat.damping_min = 1.2
		mat.damping_max = 2.0
		mat.angle_min = -180.0
		mat.angle_max = 180.0
		mat.anim_speed_min = 1.0
		mat.anim_speed_max = 1.0
		mat.anim_offset_min = 0.0
		mat.anim_offset_max = 0.25
		var curve = CurveTexture.new()
		var c = Curve.new()
		c.add_point(Vector2(0.0, 0.6))
		c.add_point(Vector2(0.4, 1.0))
		c.add_point(Vector2(1.0, 0.0))
		curve.curve = c
		mat.scale_curve = curve
		VFXEffects._process_cache[scuff_key] = mat
		scuff.process_material = mat
	parent.add_child(scuff)
	scuff.global_position = world_pos
	scuff.emitting = true
	scuff.finished.connect(func(): if is_instance_valid(scuff): scuff.queue_free())

	# 3. Minimal fire pop — just enough to sell "explosive", not a fireball
	VFXEffects.fire_burst(parent, world_pos, blast_radius * 0.35, Color(1.0, 0.55, 0.12, 0.7))

	# 4. Heavy smoke mushroom (slow, lazy) — the "WHUMP" aftermath
	VFXEffects.smoke_puff(parent, world_pos, blast_radius * 0.9, int(clampf(blast_radius * 6.0, 12, 36)),
		Color(0.22, 0.20, 0.18, 0.55))

	# 5. Ground decals: wide scorch (blast kiss) + shallow crater if big enough
	if blast_radius >= 3.5:
		VFXEffects.scorch(parent, world_pos, blast_radius * 0.75, 0.0, 18.0)
	if blast_radius >= 6.5:
		VFXEffects.crater(parent, world_pos, blast_radius * 0.5, 50.0)

	# 6. Light flash — warm, broad, brief
	var light = OmniLight3D.new()
	light.light_color = Color(1.0, 0.5, 0.1)
	light.light_energy = blast_radius * 3.0
	light.omni_range = blast_radius * 3.5
	light.light_bake_mode = Light3D.BAKE_DISABLED
	parent.add_child(light)
	light.global_position = world_pos
	var lt = parent.create_tween()
	lt.tween_property(light, "light_energy", 0.0, 0.18)
	lt.finished.connect(func(): if is_instance_valid(light): light.queue_free())

# --- Wire-in Spec for _fire_spigot_mortar (3-5 lines) ---
# 1. In _fire_spigot_mortar, after shell creation: call WeaponVFXSpigotMortar.spawn_muzzle_ring(self, get_muzzle_local_pos(), -global_transform.basis.z, payload_size)
# 2. In _fire_arcing_shell_at tween (when profile["tumble"]): call WeaponVFXSpigotMortar.spawn_tumble_mote(shell, pos, shell_radius) at ~0.15s intervals
# 3. Replace _deal_aoe_damage + _spawn_explosion_visual at tween.finished with: WeaponVFXSpigotMortar.spawn_impact_whump(_effects_parent(), end, blast_radius, color)
# 4. Audio: caller (auto_weapon) must call AudioManager.play_sfx_3d("mortar", muzzle_world_pos, null, -6.0) at muzzle; AudioManager.play_sfx_3d("artillery_impact", impact_pos, null, 2.0) at impact
# 5. All emitters use cached materials (VFXEffects._process_cache), one-shot GPUParticles3D, ring/box emission — draw budget: ~3 draw calls/shot