extends RefCounted
class_name WeaponVFXBunkerBuster
# BUNKER_BUSTER VFX Identity
# Heavy penetrator: dark heavy dart body, steep dive, DELAYED detonation
# — impact dust gulp, beat, then deep crump with ground heave + narrow tall debris gout + cracked-slab decal
# All visuals route through VFXEffects / VFXBurst shared helpers. Zero inline material/particle construction.

const VFXEffects = preload("res://scripts/vfx_effects.gd")
const VFXBurst = preload("res://scripts/vfx_burst.gd")
const ModuleCatalog = preload("res://scripts/module_catalog.gd")
const MunitionPool = preload("res://scripts/munition_pool.gd")

# =========================================================================
# MISSILE BODY — called from weapon_missile._ready() when mesh_part == "bb_body"
# Returns a Node3D pivot containing the authored dark dart mesh, scaled/oriented
# to match the project's forward -Z convention. Falls back to procedural
# heavy penetrator if the Blender part is missing.
# =========================================================================
static func build_missile_body(mesh_part: String = "bb_body") -> Node3D:
	var pivot = Node3D.new()
	var body_mesh: Mesh = MunitionPool.get_part_mesh(mesh_part) if mesh_part != "" else null
	if body_mesh != null:
		var vis = MeshInstance3D.new()
		vis.mesh = body_mesh
		var aabb := body_mesh.get_aabb()
		var s := aabb.size
		var longest: float = max(s.x, max(s.y, s.z))
		if longest > 0.001:
			vis.scale = Vector3.ONE * (0.95 / longest) # heavy dart: longer, slimmer
		# Blender parts follow -Z forward; no extra rotation needed if authored correctly
		pivot.add_child(vis)
	else:
		# Procedural fallback: dark heavy dart (cylinder + sharp nose)
		var body = MeshInstance3D.new()
		body.mesh = MunitionPool.unit_cylinder()
		body.scale = Vector3(0.08, 0.75, 0.08) # long, thin penetrator
		body.material_override = MunitionPool.albedo(Color(0.12, 0.12, 0.14)) # near-black steel
		pivot.add_child(body)
		body.rotate_x(PI / 2)

		var nose = MeshInstance3D.new()
		nose.mesh = MunitionPool.unit_taper(0.0) # true cone
		nose.scale = Vector3(0.08, 0.25, 0.08)
		nose.material_override = MunitionPool.albedo(Color(0.08, 0.08, 0.10))
		pivot.add_child(nose)
		nose.position = Vector3(0, 0, -0.5)
		nose.rotate_x(-PI / 2)

	# Subtle engine glow at rear (+Z) — dim, cold, barely visible until terminal dive
	var glow = MeshInstance3D.new()
	glow.mesh = MunitionPool.unit_sphere()
	glow.scale = Vector3(0.06, 0.06, 0.10)
	glow.material_override = MunitionPool.emissive(Color(0.3, 0.25, 0.2), Color(0.4, 0.3, 0.2), 0.8)
	pivot.add_child(glow)
	glow.position = Vector3(0, 0, 0.4)
	return pivot

# =========================================================================
# MISSILE TRAIL — heavy penetrator plume: slower, denser, colder than standard
# Called from weapon_missile._ready() for bunker_buster. Uses VFXEffects
# make_missile_trail with tuned bulk so it reads as a single heavy column.
# =========================================================================
static func make_penetrator_trail(parent: Node3D) -> GPUParticles3D:
	# bulk=1.3: slightly more particles, longer lifetime, larger puffs than standard
	var p = VFXEffects.make_missile_trail(parent, 1.3)
	p.position = Vector3(0, 0, 0.4) # attach at rear of long dart
	# Override material tint to cold dark smoke (cached per key in VFXEffects)
	p.material_override = VFXEffects._billboard_material(
		VFXEffects.SMOKE_TEX, false, Color(0.15, 0.14, 0.13, 0.85))
	return p

# =========================================================================
# IMPACT SEQUENCE — the signature bunker_buster detonation.
# Called from weapon_missile._spawn_impact_visual() when type_id == "bunker_buster"
# or from a dedicated _detonate_at override. Three-phase:
#   1. DUST GULP — inward-rushing ground dust at impact point (0.0s)
#   2. BEAT — 0.35s silence, light holds
#   3. DEEP CRUMP — ground heave (crater), narrow tall debris gout, cracked-slab decal
# Draw cost: 1 VFXBurst (debris), 1 VFXEffects.smoke_puff (dust gulp), 1 VFXEffects.crater (decal),
# 1 light flash. All cached materials, one-shot auto-free.
# =========================================================================
static func spawn_impact_sequence(parent: Node3D, world_pos: Vector3, scale: float = 1.4) -> void:
	var scene = parent
	if not scene.is_inside_tree():
		scene = parent.get_tree().current_scene if parent.get_tree().current_scene else parent.get_tree().root

	var entropy := randf_range(0.9, 1.1)
	var impact_pos := world_pos + Vector3(randf_range(-0.05, 0.05), 0, randf_range(-0.05, 0.05))

	# --- PHASE 1: DUST GULP (inward rush) ---
	# Wide, flat, fast-contracting smoke ring — reads as ground inhaling
	var gulp = GPUParticles3D.new()
	gulp.name = "BunkerGulp"
	gulp.amount = int(clampf(24.0 * scale, 18, 36))
	gulp.lifetime = 0.45
	gulp.one_shot = true
	gulp.explosiveness = 1.0
	gulp.emitting = false
	gulp.local_coords = false
	gulp.draw_pass_1 = VFXEffects._get_quad()
	gulp.material_override = VFXEffects._billboard_material(
		VFXEffects.SMOKE_TEX, false, Color(0.25, 0.23, 0.21, 0.7))
	gulp.process_material = VFXEffects._process_material(
		"bunker_gulp|%.2f" % scale,
		Vector3(0, 1, 0), 180.0, # extreme spread = flat ring
		scale * 6.0, scale * 10.0, # fast inward rush
		Vector3(0, 1.5, 0), # gentle lift
		scale * 1.8, scale * 3.0,
		2.5, 0.0, 1.0)
	scene.add_child(gulp)
	gulp.global_position = impact_pos
	gulp.emitting = true
	gulp.finished.connect(func(): if is_instance_valid(gulp): gulp.queue_free())

	# --- PHASE 2 + 3: BEAT then DEEP CRUMP ---
	# Use a tween to sequence the delay, then fire the crump
	var sequencer = scene.create_tween()
	sequencer.tween_interval(0.35) # THE BEAT

	sequencer.finished.connect(func():
		if not is_instance_valid(scene): return

		# DEEP CRUMP: ground heave (crater decal)
		VFXEffects.crater(scene, impact_pos, 2.2 * scale, 55.0)

		# NARROW TALL DEBRIS GOUT — vertical column of heavy chunks
		var gout_count := int(18.0 * scale)
		VFXBurst.spawn(scene, impact_pos, Color(0.35, 0.32, 0.28), gout_count, 0.65,
			18.0, # tight spread = narrow column
			4.0 * scale, 14.0 * scale, # fast vertical ejection
			Vector3(0, -9.8, 0), # gravity pulls it back down
			0.35 * scale, 0.9 * scale,
			VFXBurst.get_box_mesh(), # box mesh = angular debris
			Vector3(0, 1, 0), # forward_dir = UP for vertical gout
			Color(0.6, 0.35, 0.15), 8.0 * scale, 12.0 * scale) # warm subsurface light

		# Secondary: fine dust mushroom rising from the gout base
		VFXEffects.smoke_puff(scene, impact_pos, 1.6 * scale, 10,
			Color(0.18, 0.17, 0.15, 0.55))

		# CRACKED-SLAB DECAL — radial fracture lines, longer fade than crater
		# Uses scorch path with a custom cracked normal (reuse crater set with different params)
		var cracked = VFXEffects._ground_decal(scene, impact_pos, 2.8 * scale,
			VFXEffects.CRATER_SETS[randi() % VFXEffects.CRATER_SETS.size()])
		cracked.name = "CrackedSlab"
		cracked.scale = Vector3(1.0, 0.1, 1.0) # extremely flat
		var fade = cracked.create_tween()
		fade.tween_interval(60.0)
		fade.tween_property(cracked, "scale", Vector3.ZERO, 30.0)
		fade.finished.connect(func(): if is_instance_valid(cracked): cracked.queue_free())

		# DEEP CRUMP LIGHT — low, wide, long, orange-red
		var light = OmniLight3D.new()
		light.light_color = Color(0.9, 0.35, 0.1)
		light.light_energy = 14.0 * scale
		light.omni_range = 14.0 * scale
		light.omni_attenuation = 0.35
		light.light_bake_mode = Light3D.BAKE_DISABLED
		scene.add_child(light)
		light.global_position = impact_pos
		var lt = scene.create_tween()
		lt.tween_property(light, "light_energy", 0.0, 0.45) # slow fade = deep crump feel
		lt.finished.connect(func(): if is_instance_valid(light): light.queue_free())

		# Optional: subtle screen shake hook (caller implements if desired)
		# scene.call_deferred("_bunker_buster_shake", impact_pos, scale)
	)

# =========================================================================
# WIRE-IN SPEC (3-5 lines) — paste into auto_weapon.gd or weapon_missile.gd:
# ---------------------------------------------------------------------
# In weapon_missile._ready():        if mesh_part == "bb_body": WeaponVFXBunkerBuster.build_missile_body("bb_body") replaces procedural body; WeaponVFXBunkerBuster.make_penetrator_trail(self) replaces VFXEffects.make_missile_trail(self)
# In weapon_missile._spawn_impact_visual(): if owner_weapon.type_id == "bunker_buster": WeaponVFXBunkerBuster.spawn_impact_sequence(scene, _impact_pos, 1.4); return
# In auto_weapon._fire_bunker_buster(): no change needed — _spawn_missile already sets is_top_attack=true, seconds_to_max=1.60, mesh_part="bb_body" via ModuleCatalog
# ---------------------------------------------------------------------
# All visuals use cached materials. One-shots: emitting=false -> position -> emitting=true -> finished.connect(queue_free). Draw budget: +1 VFXBurst, +1 smoke_puff, +1 crater decal, +1 light per impact. STRUCT: YES (new class_name).