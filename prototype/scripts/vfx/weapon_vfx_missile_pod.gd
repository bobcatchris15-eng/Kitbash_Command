extends RefCounted
class_name WeaponVFXMissilePod

# MISSILE_POD identity: Swarm Launcher
# - Stubby fat rockets (authored mesh_part "missile_pod_missile")
# - Chaotic corkscrew ripple trails (per-missile weave via salvo_jitter + trail turbulence)
# - Staggered mini-burst peppering impacts (salvo timer 0.08s × count)
# - Scattered small craters (per-impact crater 0.7× blast, decal LRU)
# Draw budget: one shared trail material key per bulk, one shared impact burst/smoke/light pattern.
# Wire-in for auto_weapon._fire_swarm_missiles (3–5 lines):
#   var scene = _effects_parent()
#   for i in missile_salvo:
#       WeaponVFXMissilePod.configure_missile_trail(missile, 0.85)
#       missile.salvo_jitter = 1.2
#       missile.connect("destroyed", Callable(WeaponVFXMissilePod, "on_missile_impact").bind(scene, missile.global_position))
#       _effects_parent().add_child(missile)

const VFXEffects = preload("res://scripts/vfx_effects.gd")
const VFXBurstScript = preload("res://scripts/vfx_burst.gd")

# Configure the missile's trail for the swarm identity (stubby, fat, corkscrew ripple).
# bulk=0.85 keeps plume tight per rocket; turbulence gives the corkscrew.
static func configure_missile_trail(missile_node: Node3D, bulk: float = 0.85) -> GPUParticles3D:
	var trail = VFXEffects.make_missile_trail(missile_node, bulk)
	trail.position = Vector3(0, 0, 0.20)
	# Corkscrew ripple: turbulence on the trail process material (world-space, local_coords=false)
	var pm: ParticleProcessMaterial = trail.process_material
	if pm:
		pm.turbulence_enabled = true
		pm.turbulence_noise_strength = 0.55 * bulk
		pm.turbulence_noise_scale = 0.9
		pm.turbulence_noise_speed = Vector3(0.6, 0.3, 0.6)
		pm.turbulence_influence_min = 0.5
		pm.turbulence_influence_max = 1.0
	return trail

# Called when a swarm missile impacts (intercepted or on-target).
# Spawns a mini-burst + small crater; shares materials via framework caches.
static func on_missile_impact(scene_parent: Node3D, impact_pos: Vector3, intercepted: bool = false) -> void:
	if not is_instance_valid(scene_parent):
		return
	var entropy = randf_range(0.85, 1.15)
	var color_shift = Color(randf_range(0.90, 1.05), randf_range(0.85, 1.0), randf_range(0.75, 0.95))
	var final_color = Color.DARK_ORANGE * color_shift
	var jitter = Vector3(randf_range(-0.15, 0.15), randf_range(-0.05, 0.1), randf_range(-0.15, 0.15))
	var pos = impact_pos + jitter

	# Mini spark burst (staggered peppering)
	VFXBurstScript.spawn(scene_parent, pos, final_color, int(8.0 * entropy), 0.18, 45.0,
		2.5 * entropy, 6.0 * entropy, Vector3(0, 1.5, 0), 0.35, 0.9)

	# Thin smoke puff
	VFXEffects.smoke_puff(scene_parent, pos, 0.7 * entropy, 5, Color(0.22, 0.20, 0.18, 0.5))

	# Small additive fireball
	VFXEffects.fire_burst(scene_parent, pos, 0.85 * entropy, final_color)

	# Impact light pop
	var light = OmniLight3D.new()
	light.light_color = Color(1.0, 0.55, 0.15)
	light.light_energy = 4.0 * entropy
	light.omni_range = 3.5 * entropy
	light.omni_attenuation = 0.5
	light.light_bake_mode = Light3D.BAKE_DISABLED
	scene_parent.add_child(light)
	light.global_position = pos
	var lt = scene_parent.create_tween()
	lt.tween_property(light, "light_energy", 0.0, 0.12)
	lt.finished.connect(func(): if is_instance_valid(light): light.queue_free())

	# Scattered small crater (decal budget respected via VFXEffects global cap)
	if not intercepted:
		VFXEffects.crater(scene_parent, pos, 0.7 * entropy, 28.0)