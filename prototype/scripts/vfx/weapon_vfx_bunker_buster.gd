extends RefCounted
class_name WeaponVFXBunkerBuster
# BUNKER_BUSTER VFX Identity
# Heavy penetrator: dark heavy dart body, steep dive, DELAYED detonation
# -- impact dust gulp, beat, then deep crump with ground heave + narrow tall debris gout + cracked-slab decal
# All visuals route through VFXEffects / VFXBurst shared helpers. Zero inline material/particle construction.

const VFXEffects = preload("res://scripts/vfx_effects.gd")
const VFXBurst = preload("res://scripts/vfx_burst.gd")
const ModuleCatalog = preload("res://scripts/module_catalog.gd")

# =========================================================================
# MISSILE TRAIL -- heavy penetrator plume: slower, denser, colder than standard
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
# IMPACT SEQUENCE -- the signature bunker_buster detonation.
# Called from weapon_missile._spawn_impact_visual() when type_id == "bunker_buster"
# Three-phase:
#   1. DUST GULP -- inward-rushing ground dust at impact point (0.0s)
#   2. BEAT -- 0.35s silence, light holds
#   3. DEEP CRUMP -- ground heave (crater), narrow tall debris gout, cracked-slab decal
# Draw cost: 1 VFXBurst (debris), 1 VFXEffects.smoke_puff (dust gulp), 1 VFXEffects.crater (decal),
# 1 light flash. All cached materials, one-shot auto-free.
# =========================================================================
static func spawn_impact_sequence(parent: Node3D, world_pos: Vector3, scale: float = 1.4) -> void:
	var scene = parent
	if not scene.is_inside_tree():
		var tree = parent.get_tree()
		var current = tree.current_scene
		scene = current if current else tree.root

	var entropy := randf_range(0.9, 1.1)
	var impact_pos := world_pos + Vector3(randf_range(-0.05, 0.05), 0, randf_range(-0.05, 0.05))

	# --- PHASE 1: DUST GULP (inward rush) ---
	# Wide, flat, fast-contracting smoke ring -- reads as ground inhaling
	var gulp = VFXEffects.smoke_puff(scene, impact_pos, scale * 2.5, int(clampf(24.0 * scale, 18, 36)),
		Color(0.25, 0.23, 0.21, 0.7))
	# smoke_puff emits outward; reverse the velocity via negative gravity to simulate inward rush
	if gulp.process_material:
		gulp.process_material.gravity = Vector3(0, -1.5, 0)

	# --- PHASE 2 + 3: BEAT then DEEP CRUMP ---
	var sequencer = scene.create_tween()
	sequencer.tween_interval(0.35) # THE BEAT

	sequencer.finished.connect(func():
		if not is_instance_valid(scene): return

		# DEEP CRUMP: ground heave (crater decal)
		VFXEffects.crater(scene, impact_pos, 2.2 * scale, 55.0)

		# NARROW TALL DEBRIS GOUT -- vertical column of heavy chunks
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

		# CRACKED-SLAB DECAL -- radial fracture lines, longer fade than crater
		# Uses crater path with larger radius and extended fade
		var cracked = VFXEffects.crater(scene, impact_pos, 2.8 * scale, 90.0)
		cracked.name = "CrackedSlab"
		cracked.scale = Vector3(1.0, 0.1, 1.0) # extremely flat
		var fade = cracked.create_tween()
		fade.tween_interval(60.0)
		fade.tween_property(cracked, "scale", Vector3.ZERO, 30.0)
		fade.finished.connect(func(): if is_instance_valid(cracked): cracked.queue_free())

		# DEEP CRUMP LIGHT -- low, wide, long, orange-red
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
# WIRE-IN SPEC (3-5 lines) -- paste into auto_weapon.gd or weapon_missile.gd:
# ---------------------------------------------------------------------
# In weapon_missile._ready():        "bunker_buster": _trail = WeaponVFXBunkerBuster.make_penetrator_trail(self); _trail.position = Vector3(0,0,0.4)
# In weapon_missile._spawn_impact_visual(): "bunker_buster": WeaponVFXBunkerBuster.spawn_impact_sequence(scene, _impact_pos); return
# In auto_weapon._fire_bunker_buster(): no change needed -- _spawn_missile already sets is_top_attack=true, seconds_to_max=1.60, mesh_part="bb_body" via ModuleCatalog.get_missile_mesh
# ---------------------------------------------------------------------
# All visuals use cached materials. One-shots: emitting=false -> position -> emitting=true -> finished.connect(queue_free). Draw budget: +1 VFXBurst, +1 smoke_puff, +1 crater decal, +1 light per impact. STRUCT: YES (new class_name).