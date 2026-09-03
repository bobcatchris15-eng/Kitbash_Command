extends RefCounted
class_name WeaponVFXNapalmMortar
# NAPALM MORTAR — Incendiary Identity
#
# Fire bomb: tumbling canister trailing flame, splash of clinging fire via
# fire_pool + long-burning ground fire + tall black column, charred scorch
# decal — damage-over-area feel, not blast.
#
# Visual contract:
#   Flight: 0.3m canister, tumbles end-over-end, dense orange flame ribbon
#           (GPUParticles3D, BOX emission, local_coords=true) + discrete
#           ember motes along apex.
#   Impact: No flash burst. Immediate fire_pool (BOX, 4.0m radius, 8.5s)
#           + tall black smoke column (GPUParticles3D, 12m height, 10s)
#           + charred scorch decal (albedo+normal+ORM, 14s fade).
#   Damage: Thermal DoT ticks from fire_pool footprint, no upfront blast.

const VFXEffects = preload("res://scripts/vfx_effects.gd")
const VFXBurst = preload("res://scripts/vfx_burst.gd")
const MunitionPool = preload("res://scripts/munition_pool.gd")

# Projectile visual config for _fire_arcing_shell_at's profile dict.
static func get_projectile_profile() -> Dictionary:
	return {
		"body": "bomb",                    # _make_round_body kind
		"shell_radius": 0.3,               # Canister radius (m)
		"arc_height": 7.0,                 # Matches catalog flight_time 0.7s
		"tumble": true,                    # End-over-end rotation
		"trail": "napalm_flame",           # Custom trail key
		"trail_bulk": 1.4,                 # Flame ribbon density
		"flight_motes": true,              # Discrete ember puffs at apex
		"flight_mote_color": Color(1.0, 0.55, 0.1, 0.7),
		"flight_mote_size": 0.28,
		"flight_mote_count": 3,
	}

# Trail attachment config for _attach_trail_to_round.
# Returns a custom flame ribbon (GPUParticles3D, BOX emission, world-space).
static func make_napalm_trail(parent: Node3D, shell_radius: float) -> GPUParticles3D:
	var p = GPUParticles3D.new()
	p.name = "NapalmTrail"
	p.amount = 80
	p.lifetime = 0.65
	p.emitting = false
	p.local_coords = false
	p.draw_pass_1 = VFXEffects._get_quad()
	p.material_override = VFXEffects._billboard_material(
		VFXEffects.FLAME_TEX, true, Color(1.0, 0.55, 0.1, 0.85))
	p.process_material = VFXEffects._process_material(
		"napalm_trail|%.2f" % 1.4,
		Vector3(0, 0, 1), 14.0, 0.8, 1.8,
		Vector3(0, 0.3, 0), 0.35, 0.9, 0.6, 2.2, 1.1)
	parent.add_child(p)
	p.position = Vector3(0.0, 0.0, shell_radius * 0.85)
	p.emitting = true
	return p

# Detach helper mirrors framework pattern.
static func _detach_napalm_trail(round_node: Node3D, plume: GPUParticles3D) -> void:
	plume.reparent(round_node.get_tree().root)
	plume.emitting = false
	var drain = plume.create_tween()
	drain.tween_interval(plume.lifetime + 0.1)
	drain.finished.connect(func(): if is_instance_valid(plume): plume.queue_free())

# Impact config for _detonate_at / _spawn_explosion_visual override.
static func get_impact_config() -> Dictionary:
	return {
		"skip_explosion_burst": true,      # No fire_burst flash
		"spawn_fire_pool": true,           # Primary visual = fire_pool
		"pool_radius": 4.0,                # 4m radius (1.7x catalog base)
		"pool_duration": 8.5,              # 8.5s burn (2.2x catalog base)
		"spawn_smoke_column": true,        # Tall black column
		"column_height": 12.0,
		"column_duration": 10.0,
		"spawn_scorch": true,              # Charred decal
		"scorch_radius": 4.2,
		"scorch_burn_seconds": 8.5,
		"scorch_fade_seconds": 14.0,
		"light_color": Color(1.0, 0.35, 0.05, 0.0),  # No additive flash light
		"audio_key": "mortar_napalm_impact",
	}

# Builds the full impact visual stack at `position` using ONLY framework entries.
static func spawn_impact_visuals(parent: Node3D, position: Vector3, cfg = null) -> void:
	cfg = cfg if cfg else get_impact_config()
	var pool_r = cfg.pool_radius
	var pool_dur = cfg.pool_duration
	var col_h = cfg.column_height
	var col_dur = cfg.column_duration
	var scorch_r = cfg.scorch_radius

	# 1. Persistent napalm pool (BOX emission, framework function)
	VFXEffects.fire_pool(parent, position, pool_r, pool_dur)

	# 2. Tall black smoke column (framework wreck_smoke_column, tuned)
	var col = VFXEffects.wreck_smoke_column(parent, position, col_dur, col_h)
	if is_instance_valid(col):
		col.material_override = VFXEffects._billboard_material(
			VFXEffects.SMOKE_TEX, false, Color(0.04, 0.035, 0.03, 0.85))
		col.process_material = VFXEffects._process_material(
			"napalm_column|%.1f" % col_h,
			Vector3(0, 1, 0), 18.0, col_h / 2.8 * 0.7, col_h / 2.8 * 1.3,
			Vector3(0.8, 1.2, 0.4), 3.0, 7.0, 0.3, 3.0, 1.6)

	# 3. Charred scorch decal (framework scorch, ember emission)
	VFXEffects.scorch(parent, position, scorch_r, cfg.scorch_burn_seconds, cfg.scorch_fade_seconds)

	# 4. No fire_burst, no smoke_puff, no flash light — damage-over-area identity.

# Wire-in spec for auto_weapon._fire_napalm_mortar (3 lines):
#   var profile = WeaponVFXNapalmMortar.get_projectile_profile()
#   _fire_arcing_shell_at(profile.shell_radius, profile.arc_height, laser_color, 4.0, dps * fire_rate, Vector3.ZERO, 0.7, profile)
#   In finished handler: WeaponVFXNapalmMortar.spawn_impact_visuals(_effects_parent(), end)