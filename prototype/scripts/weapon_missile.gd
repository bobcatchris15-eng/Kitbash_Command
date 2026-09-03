extends Node3D
const MunitionPool = preload("res://scripts/munition_pool.gd")
const SimRNG = preload("res://scripts/battle/sim_rng.gd")
const Profiler = preload("res://scripts/battle/battle_profiler.gd")
const MeshAssetLoader = preload("res://scripts/mesh_asset_loader.gd")
const VFXEffects = preload("res://scripts/vfx_effects.gd")
const VFXBurstScript = preload("res://scripts/vfx_burst.gd")

# Weapon VFX styles — per-missile trail/impact overrides (WEAPON_VFX_FRAMEWORK.md)
const WeaponVFXGuidedMissile = preload("res://scripts/vfx/weapon_vfx_guided_missile.gd")
const WeaponVFXMissilePod = preload("res://scripts/vfx/weapon_vfx_missile_pod.gd")
const WeaponVFXHypervelocityMissile = preload("res://scripts/vfx/weapon_vfx_hypervelocity_missile.gd")
const WeaponVFXSAMLauncher = preload("res://scripts/vfx/weapon_vfx_sam_launcher.gd")
const WeaponVFXCruiseMissile = preload("res://scripts/vfx/weapon_vfx_cruise_missile.gd")
const WeaponVFXBunkerBuster = preload("res://scripts/vfx/weapon_vfx_bunker_buster.gd")
# Real, interceptable weapon missile (FABLE_REVIEW.md 2.2). Fired by
# guided_missile / dual_stage_missile / missile_pod instead of the old
# cosmetic tweened meshes - those never registered in the "missiles" group,
# so point defense had literally nothing to intercept in a real Skirmish
# (only the Test Range's incoming_missile and drone_carrier drones were
# real). Modeled on incoming_missile.gd's shape: own _physics_process,
# "missiles" group + team meta for PD targeting, destroy_missile()
# interception contract, queue_free() lifecycle.
#
# Damage on arrival is routed back through the firing weapon's own
# _deal_weapon_damage() funnel when it still exists (keeps hit-origin
# flattening and any future funnel rules consistent); falls back to a plain
# take_damage if the launcher died mid-flight - the missile is already in
# the air, its warhead doesn't care.

var target: Node3D = null
var owner_weapon: Node3D = null
var damage_amount: float = 20.0
var damage_class: String = "explosive"
var team: int = -1
var speed: float = 16.0
var is_top_attack: bool = false
var salvo_jitter: float = 0.0 # missile_pod: sideways weave so a salvo reads as a swarm
var is_destroyed: bool = false
# Cosmetic round body (ModuleCatalog.GUIDED_MISSILE_MESH). Set before
# add_child() - _ready() builds the visual. Empty string keeps the
# procedural body+nose fallback.
var mesh_part: String = ""

var _climb_target_y: float = 0.0
var _phase: int = 0 # 0 = climb (top-attack only), 1 = terminal
var _weave_seed: float = 0.0

# Smoke lock-break (ammo pass). A guided round's counter used to be point
# defense and nothing else - it could not miss from target speed by design
# (ModuleCatalog.MISS_SPEED_FACTOR gives "guided" a factor of 0.0), so
# there was no counter available to a player without PD mounted. Obscurant
# ammo now provides one: a seeker that loses sight of its target keeps
# flying on its last known heading and goes dumb, rather than tracking
# through the cloud. Deliberately a POINT test on the target rather than a
# raycast along the flight path - a seeker cares whether it can still see
# what it locked onto, not whether some unrelated cloud sits off to one side.
const SmokeVolume = preload("res://scripts/smoke_volume.gd")
const BattleLayers = preload("res://scripts/battle/battle_layers.gd")
const LOCK_BREAK_GRACE: float = 0.35 # brief blindness is survivable; a real screen isn't
const DUMB_FLIGHT_TIME: float = 1.6

var _obscured_for: float = 0.0
var _lock_broken: bool = false
var _dumb_time: float = 0.0
var _dumb_heading: Vector3 = Vector3.ZERO
var _trail: GPUParticles3D = null
var _impact_pos: Vector3 = Vector3.ZERO

# Signal for missile_pod VFX wire-in: emitted on impact/interception with position and intercepted flag
signal destroyed(position: Vector3, intercepted: bool)

func setup(missile_target: Node3D, weapon: Node3D, dmg: float, dclass: String, missile_team: int):
	target = missile_target
	owner_weapon = weapon
	damage_amount = dmg
	damage_class = dclass
	team = missile_team
	set_meta("team", team)

func _ready():
	add_to_group("missiles")
	set_meta("team", team)
	# SIM. The weave is not a shader wobble - it is added to `dest` in
	# _physics_process, so it moves the missile's actual world position every
	# tick. That changes its flight time to impact and the geometry point
	# defence has to solve to intercept it, both of which a second client must
	# agree on.
	_weave_seed = SimRNG.randf() * TAU
	_phase = 0 if is_top_attack else 1
	_climb_target_y = global_position.y + 9.0

	# Visual: authored round body when the launcher has one (same shape as the
	# hardware mounted on the vehicle), else slim body + glowing nose cone
	# (the original read). Authored meshes follow the project's forward -Z,
	# which is also where look_at() aims this node.
	var body_mesh: Mesh = MeshAssetLoader.get_part_mesh(mesh_part) if mesh_part != "" else null
	if body_mesh != null:
		var vis = MeshInstance3D.new()
		vis.mesh = body_mesh
		var aabb := body_mesh.get_aabb()
		var s := aabb.size
		var longest: float = max(s.x, max(s.y, s.z))
		if longest > 0.001:
			vis.scale = Vector3.ONE * (0.85 / longest)
		if s.y >= s.x and s.y >= s.z:
			vis.rotation.x = -PI / 2
		elif s.x >= s.y and s.x >= s.z:
			vis.rotation.y = PI / 2
		add_child(vis)
	else:
		var body = MeshInstance3D.new()
		body.mesh = MunitionPool.unit_cylinder()
		body.scale = Vector3(0.12, 0.35, 0.12)
		body.material_override = MunitionPool.albedo(Color.DARK_SLATE_GRAY)
		add_child(body)
		body.rotate_x(PI / 2)

		var nose = MeshInstance3D.new()
		# top_radius 0.0 over bottom 0.06 - a true cone, so taper ratio 0.
		nose.mesh = MunitionPool.unit_taper(0.0)
		nose.scale = Vector3(0.12, 0.12, 0.12)
		nose.material_override = MunitionPool.emissive(Color.RED, Color.RED)
		add_child(nose)
		nose.position = Vector3(0, 0, -0.23)
		nose.rotate_x(-PI / 2)

	# Engine glow: bright emissive sphere at the rear (+Z) end, visible at
	# RTS zoom as a hot exhaust point during flight.
	var glow = MeshInstance3D.new()
	glow.mesh = MunitionPool.unit_sphere()
	glow.scale = Vector3(0.10, 0.10, 0.14)
	glow.material_override = MunitionPool.emissive(Color(1.0, 0.6, 0.2), Color(1.0, 0.8, 0.3), 2.0)
	add_child(glow)
	glow.position = Vector3(0, 0, 0.20)

	# Smoke trail: per-missile identity trail (WEAPON_VFX_FRAMEWORK.md).
	# Default falls back to generic missile trail.
	var launcher_type = owner_weapon.type_id if is_instance_valid(owner_weapon) else ""
	match launcher_type:
		"guided_missile":
			_trail = WeaponVFXGuidedMissile.make_missile_trail(self)
			_trail.position = Vector3(0, 0, 0.25)
		"missile_pod":
			_trail = WeaponVFXMissilePod.configure_missile_trail(self, 0.85)
			_trail.position = Vector3(0, 0, 0.20)
		"hypervelocity_missile":
			_trail = WeaponVFXHypervelocityMissile.make_dart_trail(self)
			_trail.position = Vector3(0, 0, 0.2)
		"sam_launcher":
			_trail = WeaponVFXSAMLauncher.make_missile_trail(self)
			_trail.position = Vector3(0, 0, 0.4)
		"cruise_missile":
			_trail = WeaponVFXCruiseMissile.make_missile_trail(self)
			_trail.position = Vector3(0, 0, 0.6)
		"bunker_buster":
			_trail = WeaponVFXBunkerBuster.make_penetrator_trail(self)
			_trail.position = Vector3(0, 0, 0.4)
		_:
			_trail = VFXEffects.make_missile_trail(self)
			_trail.position = Vector3(0, 0, 0.20)

func _physics_process(delta):
	if is_destroyed: return
	var _p := Profiler.start()
	# Profiler.stop("missiles", _p) is wired at every return below; the
	# single-entry/single-exit rewrite would have been clearer but the
	# function is hot enough that the per-call dict alloc for an extra
	# local would show up in the section's mean time.
	# Early-return helpers route through _missile_tick() so each path
	# only has to remember one Profiler.stop. Kept as a method rather
	# than an inline closure so the profiler section is the SAME name
	# the incoming_missile / decoy / sentry / proximity_mine wrappers
	# use, and a F4 dump can sum them into one "missiles" row.
	_missile_tick(delta)
	Profiler.stop("missiles", _p)


func _missile_tick(delta: float) -> void:
	# Gone dumb (lock broken by smoke): coast on the last heading, then
	# self-destruct. It can still be shot down by PD during this, and it
	# still explodes - it just isn't aimed at anything any more.
	if _lock_broken:
		_dumb_time += delta
		global_position += _dumb_heading * speed * delta
		if _dumb_time >= DUMB_FLIGHT_TIME:
			_impact_pos = global_position
			_spawn_impact_visual()
			destroyed.emit(_impact_pos, false)
			destroy_missile(false)
		return

	if not is_instance_valid(target) or ("is_dead" in target and target.is_dead):
		destroy_missile(false)
		return

	# Seeker check: sustained obscurement of the target breaks the lock.
	if SmokeVolume.is_point_obscured(get_tree(), target.global_position):
		_obscured_for += delta
		if _obscured_for >= LOCK_BREAK_GRACE:
			_lock_broken = true
			_dumb_heading = -global_transform.basis.z.normalized()
			if _dumb_heading.length_squared() < 0.5:
				_dumb_heading = Vector3.FORWARD
			return
	else:
		_obscured_for = 0.0

	var dest: Vector3
	if _phase == 0:
		# Top-attack climb phase: straight up over the launch point, then dive
		dest = Vector3(global_position.x, _climb_target_y, global_position.z)
		if global_position.y >= _climb_target_y - 0.3:
			_phase = 1
			return
	else:
		dest = target.get_nearest_surface_point(global_position) if target.has_method("get_nearest_surface_point") else target.global_position + Vector3(0, 0.5, 0)
		if salvo_jitter > 0.0:
			# A little sinusoidal weave, decaying near impact so it still hits
			var dist = global_position.distance_to(dest)
			var weave = sin(Time.get_ticks_msec() / 1000.0 * 6.0 + _weave_seed)
			dest += Vector3(weave, 0.3 * weave, 0).rotated(Vector3.UP, _weave_seed) * salvo_jitter * clamp(dist / 8.0, 0.0, 1.0)

	if global_position.distance_to(dest) > 0.05:
		look_at(dest, Vector3.UP)
	var dir = (dest - global_position).normalized()
	var eff_speed = speed * 1.35 if (target and target.has_meta("is_laser_painted") and target.get_meta("is_laser_painted")) else speed
	global_position += dir * eff_speed * delta

	var target_surf: Vector3 = target.get_nearest_surface_point(global_position) if (target and target.has_method("get_nearest_surface_point")) else (target.global_position + Vector3(0, 0.5, 0) if is_instance_valid(target) else global_position)
	if _phase == 1 and global_position.distance_to(target_surf) < 1.1:
		# Raycast from behind the missile toward the target to find the hull
		# skin contact point. By the time the distance check triggers the
		# missile may have penetrated past the outer surface into the mesh
		# volume, so using the missile's own position would place the
		# explosion inside the target rather than on its armour.
		_impact_pos = global_position
		var target_center = target_surf
		var to_target = target_center - global_position
		var dist = to_target.length()
		if dist > 0.01 and is_inside_tree():
			var space = get_world_3d().direct_space_state
			var approach = to_target.normalized()
			var query = PhysicsRayQueryParameters3D.create(
				global_position - approach * 3.0, target_center)
			query.collision_mask = BattleLayers.HULL_SURFACE | BattleLayers.TERRAIN
			var hit = space.intersect_ray(query)
			if not hit.is_empty():
				var collider = hit.get("collider")
				if collider != null:
					var walker: Node = collider if collider is Node else null
					while walker != null:
						if walker == target:
							_impact_pos = hit.get("position", global_position)
							break
						walker = walker.get_parent()
		# Warhead payload effects (smoke/incendiary/illumination ammo) land
		# at the impact point, same as a shell's would - the launcher owns
		# the ammo profile, so this defers to it. Guarded on the launcher
		# still existing; if it died mid-flight the warhead just does its
		# damage, which is the same fallback the damage path below uses.
		if is_instance_valid(owner_weapon) and owner_weapon.has_method("_apply_ammo_impact"):
			owner_weapon._apply_ammo_impact(_impact_pos)
		if is_instance_valid(owner_weapon) and owner_weapon.has_method("_deal_weapon_damage"):
			owner_weapon._deal_weapon_damage(target, damage_amount)
		elif target.has_method("take_damage"):
			target.take_damage(damage_amount, damage_class, _impact_pos)
		_spawn_impact_visual()
		destroyed.emit(_impact_pos, false)
		destroy_missile(false)

func _spawn_impact_visual():
	if not is_inside_tree(): return
	var scene = get_tree().current_scene if get_tree().current_scene != null else get_tree().root
	var launcher_type = owner_weapon.type_id if is_instance_valid(owner_weapon) else ""
	
	# Per-missile impact visuals (WEAPON_VFX_FRAMEWORK.md)
	match launcher_type:
		"guided_missile":
			WeaponVFXGuidedMissile.spawn_tandem_impact(scene, _impact_pos)
			return
		"hypervelocity_missile":
			WeaponVFXHypervelocityMissile.spawn_penetrator_impact(scene, _impact_pos, 1.0)
			return
		"sam_launcher":
			WeaponVFXSAMLauncher.spawn_proximity_burst(scene, _impact_pos)
			return
		"cruise_missile":
			WeaponVFXCruiseMissile.spawn_impact_sequence(scene, _impact_pos)
			return
		"bunker_buster":
			WeaponVFXBunkerBuster.spawn_impact_sequence(scene, _impact_pos)
			return
		"missile_pod":
			# missile_pod impacts handled via signal connection in _fire_swarm_missiles
			pass
	
	# Default generic missile impact (fallback)
	var entropy := randf_range(0.82, 1.18)
	var color_shift := Color(randf_range(0.90, 1.0), randf_range(0.85, 1.0), randf_range(0.80, 1.0))
	var final_color: Color = Color.ORANGE * color_shift
	var jitter := Vector3(randf_range(-0.1, 0.1), randf_range(-0.05, 0.1), randf_range(-0.1, 0.1))
	var impact_pos := _impact_pos + jitter
	# Spark shrapnel burst
	var spark_count := int(14.0 * entropy)
	VFXBurstScript.spawn(scene, impact_pos, final_color, spark_count, 0.25, 50.0,
		3.0 * entropy, 8.0 * entropy)
	# Smoke puff
	VFXEffects.smoke_puff(scene, impact_pos, 1.2 * entropy, 8, Color(0.20, 0.19, 0.18, 0.60))
	# Particle-driven fireball — additive flame quads
	VFXEffects.fire_burst(scene, impact_pos, 1.4 * entropy, final_color)
	# Impact light flash
	var light = OmniLight3D.new()
	light.light_color = Color(1.0, 0.7, 0.3)
	light.light_energy = 6.0 * entropy
	light.omni_range = 5.0 * entropy
	light.omni_attenuation = 0.5
	light.light_bake_mode = Light3D.BAKE_DISABLED
	scene.add_child(light)
	light.global_position = impact_pos
	var lt = scene.create_tween()
	lt.tween_property(light, "light_energy", 0.0, 0.15)
	lt.finished.connect(func(): if is_instance_valid(light): light.queue_free())

# Interception contract, same as incoming_missile.gd - PD calls this.
func destroy_missile(intercepted: bool):
	if is_destroyed: return
	is_destroyed = true
	# Emit destroyed signal for VFX wire-in (missile_pod, etc.)
	destroyed.emit(global_position, intercepted)
	
	# Detach the smoke trail so it can drain after the missile is freed.
	# Reparent to scene root, stop emitting, then free once the last
	# particles have aged out (lifetime 0.25s).
	if is_instance_valid(_trail) and _trail.is_inside_tree():
		var scene = get_tree().current_scene if get_tree().current_scene != null else get_tree().root
		_trail.get_parent().remove_child(_trail)
		scene.add_child(_trail)
		_trail.global_position = global_position
		_trail.emitting = false
		var drain = _trail.create_tween()
		drain.tween_interval(_trail.lifetime + 0.1)
		drain.finished.connect(func(): if is_instance_valid(_trail): _trail.queue_free())
	
	# Per-missile interception visuals (WEAPON_VFX_FRAMEWORK.md)
	if intercepted:
		var launcher_type = owner_weapon.type_id if is_instance_valid(owner_weapon) else ""
		if launcher_type == "hypervelocity_missile":
			var scene = get_tree().current_scene if get_tree().current_scene != null else get_tree().root
			WeaponVFXHypervelocityMissile.spawn_interception_flash(scene, global_position)
			queue_free()
			return
		# guided_missile, sam_launcher, loitering_munition, anti_radiation_missile,
		# bunker_buster, cruise_missile: keep existing cyan flash logic (no change)
	
	if is_inside_tree():
		var scene = get_tree().current_scene if get_tree().current_scene != null else get_tree().root
		var exp_color: Color = Color.CYAN if intercepted else Color.ORANGE
		var entropy := randf_range(0.85, 1.15)
		var color_shift := Color(randf_range(0.92, 1.0), randf_range(0.88, 1.0), randf_range(0.85, 1.0))
		var final_color: Color = exp_color * color_shift
		# Spark burst
		VFXBurstScript.spawn(scene, global_position, final_color, int(12.0 * entropy), 0.25, 50.0,
			3.0 * entropy, 7.0 * entropy)
		# Smoke puff
		VFXEffects.smoke_puff(scene, global_position, 1.0 * entropy, 6, Color(0.22, 0.21, 0.20, 0.55))
		# Fireball burst
		VFXEffects.fire_burst(scene, global_position, 1.2 * entropy, final_color)
		# Interception/impact flash
		var light = OmniLight3D.new()
		light.light_color = exp_color
		light.light_energy = 5.0 * entropy
		light.omni_range = 4.0 * entropy
		light.omni_attenuation = 0.5
		light.light_bake_mode = Light3D.BAKE_DISABLED
		scene.add_child(light)
		light.global_position = global_position
		var lt = scene.create_tween()
		lt.tween_property(light, "light_energy", 0.0, 0.15)
		lt.finished.connect(func(): if is_instance_valid(light): light.queue_free())
	queue_free()
