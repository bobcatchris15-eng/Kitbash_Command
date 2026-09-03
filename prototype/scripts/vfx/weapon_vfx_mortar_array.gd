extends RefCounted
class_name WeaponVFXMortarArray

# MORTAR_ARRAY — Light Mortar Salvo (3-round ripple)
# Identity: steep plunging whistling bombs, rapid thump-thump-thump rhythm (0.18s),
# small dusty grey-brown pops with short smoke wisps, pockmark craters.
# Framework-only: zero inline GPUParticles3D/StandardMaterial3D allocation.
# Draw budget: salvo shares materials — 1 impact burst + 1 smoke wisp + 1 crater per shell.

const VFXEffects = preload("res://scripts/vfx_effects.gd")
const VFXBurst = preload("res://scripts/vfx_burst.gd")
const ModuleCatalog = preload("res://scripts/module_catalog.gd")

# =====================================================================
# SHELL FLIGHT — Discrete whistling indicator (no bulk trail)
# =====================================================================

# Spawns a subtle flight mote at the shell's apex to sell the "whistling"
# steep arc without a continuous trail. Called from the shell's tween at
# the halfway point (val=0.5) where the whistle is loudest.
# parent = scene root or effects parent (world-space persistence).
# world_pos = shell position at apex.
static func spawn_apex_whistle(parent: Node3D, world_pos: Vector3) -> void:
	# A single pale puff at the top of the arc — reads as a whistle
	# without adding draw calls per frame. One-shot, auto-free.
	VFXEffects.smoke_puff(
		parent,
		world_pos,
		0.35,                # small radius
		1,                   # single mote
		Color(0.55, 0.5, 0.42, 0.35))  # pale dusty grey-brown, transparent


# =====================================================================
# IMPACT — Dusty grey-brown pop + short smoke wisps + pockmark crater
# =====================================================================

# Spawns the complete mortar impact at the AoE centre.
# parent = scene root or effects parent (world-space persistence).
# world_pos = impact position in world space (from _deal_aoe_damage).
# Returns the burst GPUParticles3D (one-shot, auto-free).
static func spawn_impact(parent: Node3D, world_pos: Vector3) -> GPUParticles3D:
	# 1. Dusty grey-brown pop — spherical pellet burst, small and sharp.
	#    Uses VFXBurst with sphere emission for a true 3D "pop".
	var burst = VFXBurst.spawn(
		parent,
		Vector3.ZERO,                 # local_pos; we set global_position after
		Color(0.45, 0.38, 0.32, 1.0), # dusty grey-brown
		10,                           # pellet count — small pop
		0.25,                         # lifetime — quick
		180.0,                        # full sphere spread
		8.0,                          # speed_min
		14.0,                         # speed_max
		Vector3(0, -3.0, 0),          # gravity pulls dust down fast
		0.08,                         # scale_min — fine dust
		0.18,                         # scale_max
		VFXBurst.get_sphere_mesh(),   # round dust motes
		Vector3.ZERO,                 # forward_dir=0 → sphere emission
		Color(0.6, 0.5, 0.4, 1.0),    # light_color: warm dust glow
		3.0,                          # light_range
		8.0)                          # light_energy
	burst.global_position = world_pos

	# 2. Short smoke wisps — one-shot grey smoke puff, lingers briefly.
	VFXEffects.smoke_puff(
		parent,
		world_pos,
		0.9,                          # radius
		3,                            # amount — just a few wisps
		Color(0.28, 0.25, 0.22, 0.5)) # darker grey-brown smoke

	# 3. Pockmark crater — persistent displaced-earth decal.
	VFXEffects.crater(
		parent,
		world_pos,
		1.1,                          # radius — small pockmark
		45.0)                         # fade_seconds — battlefield memory

	# Light flash handled by VFXBurst.spawn (light_color/light_range/light_energy)
	return burst


# =====================================================================
# MUZZLE VENT — Optional: tube cold-gas puff on each round launch
# =====================================================================

# One-shot cold-gas vent at the mortar tube when a round ejects.
# parent = the weapon module node (auto_weapon instance).
# local_pos = muzzle position in weapon local space (get_muzzle_local_pos()).
static func spawn_tube_vent(parent: Node3D, local_pos: Vector3) -> GPUParticles3D:
	var p = GPUParticles3D.new()
	p.name = "MortarTubeVent"
	p.amount = 6
	p.lifetime = 0.25
	p.one_shot = true
	p.explosiveness = 1.0
	p.emitting = false
	p.local_coords = true
	p.draw_pass_1 = VFXEffects._get_quad()
	p.material_override = VFXEffects._billboard_material(
		VFXEffects.SMOKE_TEX, false, Color(0.55, 0.5, 0.42, 0.45))
	p.process_material = VFXEffects._process_material(
		"mortar_tube_vent",
		Vector3.UP, 60.0, 4.0, 10.0,
		Vector3(0, 1.5, 0), 0.25, 0.6, 0.6, 1.0, 0.7)
	parent.add_child(p)
	p.position = local_pos
	p.emitting = true
	p.finished.connect(func(): if is_instance_valid(p): p.queue_free())
	return p


# =====================================================================
# WIRE-IN SPEC (for _fire_mortar_salvo in auto_weapon.gd)
# =====================================================================
# 1. In the per-shell timer (inside the loop at line 1877), after shell creation:
#    call `WeaponVFXMortarArray.spawn_tube_vent(self, get_muzzle_local_pos())`
#    for the tube cold-gas puff on each "thump".
# 2. In the tween's `callable` (line 1892-1896), at the apex (val ≈ 0.5):
#    call `WeaponVFXMortarArray.spawn_apex_whistle(_effects_parent(), shell.global_position)`.
# 3. In the tween's `finished` handler (line 1899-1903), REPLACE the inline
#    `_spawn_explosion_visual(end, 0.5, Color.YELLOW)` with:
#    `WeaponVFXMortarArray.spawn_impact(_effects_parent(), end)`.
# All calls use framework-cached materials; zero inline allocations.
# Draw cost per shell: 1 vent (muzzle) + 1 whistle (flight) + 1 burst + 1 smoke_puff + 1 crater (impact).
# Salvo of 3 = 15 draws total, all one-shot and auto-freeing.