extends Node3D

const ModuleCatalog = preload("res://scripts/module_catalog.gd")
const GlobalConfig = preload("res://scripts/global_config.gd")
const WeaponRange = preload("res://scripts/weapon_range.gd")
# Battle-layer section timing. Inert (one static bool read) unless a profiling
# run has switched it on; auto_weapon.gd is shared with the old runtime, which
# never enables it.
const Profiler = preload("res://scripts/battle/battle_profiler.gd")
# Lifecycle log lines. Mirror to BattleLogger for the structured log
# (beacon, drone, mine, smoke) - one line per fire. Inert when the
# logger is off.
const BattleLogger = preload("res://scripts/battle/battle_logger.gd")
const VFXBurstScript = preload("res://scripts/vfx_burst.gd")
# Stance gate. The HOLD_FIRE short-circuit in _find_nearest_target and
# _is_current_target_still_valid is the only weapon-level enforcement of
# the stance - unit.gd's _tick_targeting also skips the auto-scan loop
# when stance is HOLD_FIRE, but a weapon on a unit whose stance just
# flipped needs to re-check the parent at fire time, not rely on the
# unit-level scan to have already cleared the cache.
const StanceScript = preload("res://scripts/battle/orders/stance.gd")
# Shared unit meshes + cached materials for every munition visual below. See
# munition_pool.gd's header for the measurements that motivated it; the short
# version is that a fresh primitive Mesh per projectile was costing more frame
# time at 8 units than the units themselves. Everything it returns is shared
# and must not be mutated - size munitions via the node's scale.
const MunitionPool = preload("res://scripts/munition_pool.gd")
# The simulation random stream. This file is the reason the split exists: it
# makes roughly forty cosmetic draws per engagement (sparks, muzzle scatter,
# debris, smoke) interleaved with a handful that decide outcomes - the hit roll,
# the reacquire stagger, the initial fire phase, and the salvo scatter that
# moves where an AoE centre lands. Cosmetic draws stay on the global randf();
# anything a second client must agree on goes through SimRNG. See its header for
# the rule and for why it is a static holder rather than an injected instance.
const SimRNG = preload("res://scripts/battle/sim_rng.gd")

var target: Node3D = null
var fire_range: float = 12.0
var fire_rate: float = 1.0 # Shot interval
var time_since_last_shot: float = 0.0

var dps: float = 10.0
# Crimson Concordat's passive (dps rises the closer this weapon's own
# vehicle is to death) needs a per-tick recompute, unlike every other
# faction dps/range bonus which is a fixed one-time value set in _ready() -
# base_dps is that fixed value; `dps` itself becomes the live, possibly-
# boosted number every _fire_*() function already reads.
var base_dps: float = 10.0
var heal_rate: float = 0.0
var laser_color: Color = Color.RED
var type_id: String = ""
var muzzle_offset: Vector3 = Vector3(0.0, 0.3, -0.6)
var _caliber: float = 1.0

var damage_class: String = "kinetic"
var bipod_deployed: bool = false
# Ray-start height for the LOS check - computed once from the catalog size in
# _ready() instead of re-fetching catalog data every physics tick.
var _los_height_offset: float = 0.5
var traverse_limit_angle: float = PI / 4.0
var traverse_speed: float = 4.0

# --- Traverse model (see the block in _ready that uses these) --------------
# How hard a heavier module is charged. 1.0 would be "moment of inertia is
# linear in mass", which it is - but mass and length are charged separately
# here and a slider usually moves both, so each is softened a little to keep a
# maxed-out gun slow rather than immobile.
const TRAVERSE_WEIGHT_EXPONENT: float = 0.80
# Length is charged on top of the mass it adds, because inertia goes with the
# SQUARE of the radius. A true 2.0 here made a max-length barrel unusable once
# combined with the weight term, so this is deliberately well under it.
const TRAVERSE_LENGTH_EXPONENT: float = 0.90
# Only the tweaks that ARE the long projecting tube the shot travels down.
# Everything else that makes a part bigger is already paid for through weight;
# listing it here too is the double-charge this model was built to remove.
const TRAVERSE_LENGTH_TWEAKS := ["barrel_length", "focal_length"]
# Floor and ceiling. The floor exists so an extreme build (a max-length barrel
# on the heaviest gun in the roster) is punishing rather than literally stuck -
# 0.08 rad/s is still 78 seconds for a full circle.
const TRAVERSE_SPEED_MIN: float = 0.08
const TRAVERSE_SPEED_MAX: float = 3.0
# Ceiling on how much FASTER tweaks can make a weapon than its published base.
# Not symmetrical with the penalty side on purpose - see the comment where it is
# applied.
const TRAVERSE_TWEAK_GAIN_MAX: float = 1.5
var resting_transform: Transform3D
var spin_up_timer: float = 0.0

# PERFORMANCE_PLAN.md P1: _is_current_target_still_valid() used to call
# _is_los_blocked_to() every single physics tick for every weapon on every
# unit - each call walks both this weapon's and the target's ENTIRE node
# tree to build a raycast exclude list, then fires up to two raycasts. That
# was the dominant cost behind the "falls off a cliff past ~5-6 units"
# report - O(units x weapons) tree-walks/raycasts every tick in steady
# state. LOS geometry doesn't meaningfully change within ~150ms at RTS unit
# speeds, so cache the result instead of re-querying every frame.
var _los_cache_blocked: bool = false
var _los_cache_target: Node3D = null
var _los_cache_timer: float = 0.0
const LOS_CACHE_TTL: float = 0.15

# PERFORMANCE_PLAN.md P1a: reacquiring a target (_find_nearest_target()'s
# full grid/roster scan) is the other expensive path, throttled the same
# way _try_auto_engage() already throttles its own O(n) scan.
# _ready() staggers each weapon's timer with a random phase so a mass
# target-loss event (an alpha strike, a scouted group dying) doesn't turn
# into every weapon re-scanning on the same physics frame.
var _reacquire_timer: float = 0.0
const REACQUIRE_INTERVAL: float = 0.2
var _fog_scan_timer: float = 0.0
const FOG_SCAN_INTERVAL: float = 1.8   # seconds between fog scans

# Heavy Barrier Projector (Aegis Field) state
var barrier_max_hp: float = 600.0
var barrier_current_hp: float = 600.0
var barrier_collapse_timer: float = 0.0
var is_barrier_active: bool = true
var field_width_mult: float = 1.0
var barrier_capacity_mult: float = 1.0
var projection_dist: float = 25.0

# frame_built weapons (ModuleCatalog.get_traverse_limit_angle == 0.0 exactly -
# the barrel is fixed to the hull, so the whole vehicle aims instead, see
# unit.gd's has_frame_built_weapon) still need a real, reachable
# ACQUISITION tolerance. Every target-scan below used to gate on
# `angle_to(dir) <= traverse_limit_angle` directly, which for a frame_built
# weapon means literally 0.0 - bit-exact alignment with a continuous slerp
# (unit.gd's _turn_toward) essentially never produces that, so target
# stayed permanently null and these weapons almost never fired regardless of
# how well the hull was actually aimed (the "flaky firing" bug report).
# Flooring the comparison at this tolerance (same 0.26 rad/~15 degrees the
# firing gate below already uses) lets acquisition succeed once the hull's
# real-time turn has it roughly on target, so the firing gate - which checks
# the true CURRENT angle every frame, not this stale acquisition snapshot -
# gets a real chance to close the rest of the way and fire. No effect on
# turret/pintle (traverse_limit_angle == PI already exceeds this).
const MIN_ACQUISITION_ARC: float = 0.26

# --- Elevation stops ------------------------------------------------------
# Set from ModuleCatalog.get_elevation_up/down() in _ready(). Radians above and
# below THIS WEAPON's own horizon, where "up" is the weapon's local +Y (the
# surface normal it was mounted on), so a belly mount's stops correctly point
# at the ground.
#
# Before these existed, acquisition gated on a single symmetric yaw cone with
# no vertical term whatsoever - so a howitzer could track an aircraft directly
# overhead just as well as a CIWS could, and the Design Lab drew every weapon
# with the same placeholder 88-degree stops. See ModuleCatalog.ELEVATION_LIMITS
# for the per-weapon values and for why an artillery piece's ENGAGEMENT
# elevation is low despite its barrel sitting steep.
var elevation_up_limit: float = deg_to_rad(55.0)
var elevation_down_limit: float = deg_to_rad(12.0)

# The elevation half of acquisition needs a floor for the same reason
# MIN_ACQUISITION_ARC exists on the yaw half: a target is a point, a unit has
# height, and a weapon sitting on top of a tall hull looks slightly DOWN at
# something standing right next to it. Without a tolerance, a mortar with 3
# degrees of depression would refuse point-blank ground targets that it is
# obviously able to hit, which reads as the weapon being broken rather than as
# a depression limit.
const MIN_ELEVATION_TOLERANCE: float = 0.26

# DEPRESSION IS DELIBERATELY PERMISSIVE, and much more so than elevation.
#
# At this game's scale, how far a weapon must look DOWN to hit something is
# dominated by where its muzzle sits, not by the gun's design: a basic_cannon
# mounted 1.2 units up on a defense foundation needs roughly 27 degrees of
# depression to engage a target 5 units away on flat ground. Enforcing a
# realistic 10-degree depression stop against that geometry made every
# elevated mount - every defense tower, every weapon on a tall hull - refuse
# adjacent ground targets, which is a bug and not a feature. It was caught by
# test_e1_low_power_disables_defense_weapon_and_dims_its_mesh, whose defense
# gun simply stopped acquiring anything.
#
# So the per-weapon "down" values in ModuleCatalog.ELEVATION_LIMITS exist to
# stop the genuinely absurd case - the old placeholder let every weapon in the
# roster shoot almost straight down - and to differentiate later if depression
# ever becomes a real lever. They are not a simulation of turret geometry, and
# this floor is what keeps them from breaking ordinary shots. Elevation, the
# axis Chris actually asked about, is enforced strictly and is unaffected.
const MIN_DEPRESSION_TOLERANCE: float = 0.785 # 45 degrees

# Makes the RATED angle inclusive. Without it, whether a weapon can engage at
# exactly its own published limit came down to which way asin() happened to
# round: basic_cannon (rated 45) refused a target at 45.0 degrees while
# heavy_laser (rated 60) accepted one at 60.0. A catalog number that is
# sometimes achievable and sometimes not is worse than either answer, and the
# player-facing figure should mean "this angle works".
const ELEVATION_EPSILON: float = 0.0087 # ~0.5 degrees

# repair_array's real fix (ENERGY_AND_BALANCE_SPEC.md #3): inverts
# targeting to same-team/HP-deficit candidates instead of hostiles.
var targets_allies: bool = false

# Energy weapons (ENERGY_AND_BALANCE_SPEC.md #4/#5): cost the FIRING unit's
# own current_energy per shot (checked/spent via spend_energy() on the
# vehicle root, duck-typed) and, for ion_cannon, drain the TARGET's energy
# pool alongside HP damage. arc_projector is the dedicated pure-drain weapon.
const ENERGY_WEAPON_TYPES = ["arc_projector", "ion_cannon", "microwave_emitter", "particle_lance", "heavy_laser", "pd_laser", "gauss_railgun", "coil_gun", "plasma_lobber"]
var energy_cost_per_shot: float = 0.0
var energy_drain_per_shot: float = 0.0

# damage_class reclassification (DECISIONS_NEEDED.md - deliberately
# deferred, then revisited once damage_resolver.gd actually had a real
# "energy" armor-table row to resolve against): heavy_laser/plasma_lobber/
# pd_laser are thematically directed-energy weapons, reclassified to
# damage_class "energy" for real armor-matchup purposes. This list and
# ENERGY_WEAPON_TYPES above stay separate because they answer different
# questions - which armor threshold a hit resolves against, versus whether
# firing costs the shooter's own capacitor - and every energy weapon happens
# to answer both the same way (Chris: "all the energy weapons should"), not
# because the two concepts are the same thing. A weapon that dealt energy
# damage without a capacitor cost, or vice versa, would still belong in only
# one of these two lists.
const ENERGY_DAMAGE_CLASS_TYPES = ["arc_projector", "ion_cannon", "heavy_laser", "plasma_lobber", "pd_laser", "microwave_emitter", "particle_lance"]

# --- Ammunition (ModuleCatalog.AMMO_TYPES) ---
# A design-time payload choice stored in the module's own tweaks dict,
# resolved once in _ready(). Its whole job is to reach two places:
#   1. damage_class - which armor threshold row damage_resolver.gd resolves
#      against. This is the big one: it turns the existing armor matrix from
#      a static property of which gun you mounted into a live counter-pick.
#   2. the per-shot damage and blast-radius multipliers applied in this
#      file's two damage funnels (_deal_weapon_damage/_deal_aoe_damage), so
#      no individual _fire_*() function had to learn about ammo at all.
# Plus the on-impact effects (smoke clouds, burn pools, flares) which hang
# off _apply_ammo_impact().
const SmokeVolume = preload("res://scripts/smoke_volume.gd")
const VFXEffects = preload("res://scripts/vfx_effects.gd")

var ammo_type: String = ModuleCatalog.AMMO_DEFAULT
var ammo_damage_mult: float = 1.0
var ammo_light_mult: float = 1.0
var ammo_aoe_mult: float = 1.0
# Transient per-shot size multiplier for the payload effect, set around an
# _apply_ammo_impact() call by any weapon whose own tweaks should change
# how big the resulting cloud/pool/flare is (smoke_discharger's tube count).
# A plain field rather than an argument so the three shared call sites
# (_deal_aoe_damage, _fire_kinetic_projectile, weapon_missile) don't all
# need to grow a parameter they'd always pass 1.0 for.
var _ammo_impact_scale: float = 1.0

# Blast radius floor for no-splash ammo (AP). _deal_aoe_damage() is shared
# by every explosive weapon, so rather than teach each of them to branch,
# an aoe_mult of 0.0 collapses the radius to this - small enough that only
# what was directly hit is caught, which is exactly "no splash".
const AMMO_NO_SPLASH_RADIUS: float = 0.6

# Obscurant cloud geometry. A shell-delivered smoke round makes a modest
# screen; the dedicated smoke_discharger makes a much bigger, longer-lived
# one - that's the whole reason to spend a mount on the specialist rather
# than just loading smoke in a gun you already have.
const SMOKE_SHELL_RADIUS: float = 4.5
const SMOKE_SHELL_LIFETIME: float = 10.0
const SMOKE_DISCHARGER_RADIUS: float = 7.5
const SMOKE_DISCHARGER_LIFETIME: float = 16.0

# Illumination: burns off fog of war in a radius where it lands, by feeding
# the same reveal path skirmish.gd's vision system already uses.
const ILLUM_RADIUS: float = 16.0
const ILLUM_LIFETIME: float = 12.0

# The true munition-interceptors. The AA autocannon deliberately is NOT one:
# it engages AIRCRAFT, which is a different job, and putting it here would
# have made it ignore the thing it exists to shoot.
const PD_WEAPON_TYPES = ["ciws", "pd_laser", "flak_cannon"]
# FABLE_REVIEW.md 1.8: the point-defense family finally gets a real anti-AIR
# identity (previously "flak = AA" was pure flavor - nothing anywhere
# distinguished air targets, and PD per-shot damage rounded to zero against
# any armor). A flat multiplier vs airborne hulls is deliberately gamey/C&C
# rather than simulationist - it makes flak the answer to armored fliers
# without touching its (intentionally weak) anti-ground numbers.
const PD_ANTI_AIR_DAMAGE_MULT: float = 3.0

# --- Evasion model (FABLE_REVIEW.md 1.4) ---
# Speed finally has DEFENSIVE value: a shot can miss a fast-moving target,
# scaled by the weapon's projectile class (ModuleCatalog.PROJECTILE_CLASS)
# and the target's actual current horizontal velocity (not its design-time
# move_speed - a fast unit standing still is an easy target). Bigger hulls
# are easier to hit (footprint factor), so compact scouts genuinely dodge
# better than stretched-out gun platforms. Hitscan beams and guided
# munitions never miss from speed - guided's counter is PD interception.
const MISS_SPEED_FACTOR = {"hitscan": 0.0, "ballistic": 0.035, "arc": 0.09, "guided": 0.0}
const MISS_CHANCE_CAP: float = 0.75

func _roll_hit(t: Node3D) -> bool:
	var cls = ModuleCatalog.get_projectile_class(type_id)
	var factor = MISS_SPEED_FACTOR.get(cls, 0.035)
	if factor <= 0.0:
		return true
	var target_speed = 0.0
	if t is CharacterBody3D:
		target_speed = Vector3(t.velocity.x, 0.0, t.velocity.z).length()
	if target_speed < 0.5:
		return true # stationary (or a building) - can't dodge standing still
	var size_factor = 1.0
	if "hull_node" in t and is_instance_valid(t.hull_node) and t.hull_node.has_meta("base_hull_size") and t.hull_node.has_meta("hull_scale"):
		var s = t.hull_node.get_meta("base_hull_size") * t.hull_node.get_meta("hull_scale")
		size_factor = clamp(sqrt((s.x * s.z) / (4.0 * 6.0)), 0.6, 1.6)
	var miss_chance = clamp(target_speed * factor / size_factor, 0.0, MISS_CHANCE_CAP)
	# SIM. The hit/miss roll - the single most outcome-defining draw in the file.
	# Note the early returns above deliberately do NOT draw: a hitscan weapon, a
	# guided round and a stationary target all return true without touching the
	# stream, so two clients that agree on the rules consume the same number of
	# draws whether or not the shot could have missed.
	return SimRNG.randf() >= miss_chance

# Parent node for spawned projectiles, tracers and impact VFX.
#
# Every _fire_*() below used to call _effects_parent().add_child()
# directly. current_scene is null whenever no scene has been marked current -
# briefly during a scene transition, and permanently in any harness that
# instantiates a scene straight under the tree root (which is exactly how
# run_tests.gd drives the Test Range). In that state the add_child() aborted
# the shot with "Cannot call method 'add_child' on a null value" AFTER the
# weapon had already reset its cooldown: the gun cycled, played its timing,
# and fired blanks - target dummies sat at full health while every other
# signal (target lock, line of sight, aim angle) looked perfectly healthy.
# Falling back to the tree root keeps the projectile real in that case.
#
# THE ROOT IS A Window, NOT A Node3D, so `t.root as Node3D` is always null and
# a fallback written that way is not a fallback at all - it reinstates the
# exact blank-firing bug described above for every harness that loads a scene
# under the root. The return type is worth keeping (a projectile parented to a
# non-spatial node inherits no transform), so the fallback has to find a real
# 3D node instead of casting one into existence: the unit's own top-level
# spatial ancestor, which is the match scene in play and the instantiated
# scene under the root in a harness.
func _effects_parent() -> Node3D:
	var t = get_tree()
	if t == null:
		return null
	if t.current_scene is Node3D:
		return t.current_scene as Node3D
	var best: Node3D = null
	var node: Node = self
	while node != null:
		if node is Node3D:
			best = node as Node3D
		node = node.get_parent()
	return best

# Small dirt-puff visual where a missed shot lands, so a miss reads as a
# miss instead of silent nothing.
func _spawn_miss_puff(t: Node3D):
	if not is_instance_valid(t) or not is_inside_tree():
		return
	var puff = MeshInstance3D.new()
	puff.mesh = MunitionPool.unit_sphere()
	puff.scale = Vector3(0.6, 0.6, 0.6)
	puff.material_override = MunitionPool.alpha(Color(0.5, 0.45, 0.35, 0.7))
	_effects_parent().add_child(puff)
	# COSMETIC. Where the dirt puff appears is presentation only - the miss has
	# already been decided by _roll_hit() and no damage is dealt here. Left on
	# the global stream on purpose: a client that culls this effect (offscreen,
	# low graphics settings) must not thereby shift the next hit roll.
	var side = Vector3(randf_range(-1.0, 1.0), 0, randf_range(-1.0, 1.0)).normalized()
	puff.global_position = t.global_position + side * randf_range(1.2, 2.2)
	var tween = create_tween()
	tween.tween_property(puff, "scale", Vector3.ZERO, 0.3)
	tween.finished.connect(func(): if is_instance_valid(puff): puff.queue_free())

# Single funnel for all weapon HP damage (every _fire_*() routes through
# here). Centralizes: the evasion roll, the PD anti-air bonus above, and
# the hit-origin altitude flattening below.
func _deal_weapon_damage(t: Node3D, amount: float):
	if not is_instance_valid(t) or not t.has_method("take_damage"):
		return
	if not _roll_hit(t):
		_spawn_miss_puff(t)
		return
	if type_id in PD_WEAPON_TYPES and "is_flying" in t and t.is_flying:
		amount *= PD_ANTI_AIR_DAMAGE_MULT

	# Ammo per-shot multiplier. A utility round (smoke/illumination) has a
	# damage_mult of 0.0 and deals literally nothing - the round still
	# flies and still lands its effect via _apply_ammo_impact(), it just
	# doesn't hurt anyone. That IS the tradeoff for loading it.
	amount *= ammo_damage_mult
	# Light-target modifier - the field that keeps the ammo roster from
	# collapsing into one right answer. Flechette multiplies here (3.5x),
	# AP divides (0.4x, over-penetration), so the two are genuine mirrors
	# rather than one being a free upgrade over the other. See
	# ModuleCatalog.AMMO_TYPES' light_mult comment for the worked numbers.
	if ammo_light_mult != 1.0 and _is_light_target(t):
		amount *= ammo_light_mult
	if amount <= 0.0:
		return

	t.take_damage(amount, damage_class, _hit_origin(t))

	# EMP shells drain the target's capacitor alongside their (deliberately
	# feeble) structural damage, reusing the exact drain_energy() contract
	# arc_projector already established.
	if ammo_type == "emp" and t.has_method("drain_energy"):
		t.drain_energy(amount * 1.5)

# Light/unarmoured target test, driving each round's light_mult. The
# "missiles" group is both real missiles and drone_carrier's drones (see
# drone_unit.gd, which deliberately joins that group to reuse PD
# interception), so it's the right handle for "small, fast, thin-skinned".
func _is_light_target(t: Node3D) -> bool:
	if t.is_in_group("missiles"):
		return true
	if "is_flying" in t and t.is_flying:
		return true
	return false

# Real AoE (FABLE_REVIEW.md 2.3) - the other missing leg of the counter-
# triangle ("AoE beats swarm"). A shared radius query around an impact
# point, called from the explosive weapons' hit callbacks instead of their
# old single-target-only _deal_weapon_damage() call. Linear falloff from
# full damage at the impact center to zero at the blast radius edge; each
# hit still routes through _deal_weapon_damage() so evasion/PD-anti-air/
# hit-origin-flattening all still apply per target. Hostiles only, matching
# every other weapon's own team filter - friendly fire is a real, separate
# design question (own units clustering would suddenly matter) deliberately
# not bundled into this pass; see DECISIONS_NEEDED.md.
func _deal_aoe_damage(center: Vector3, radius: float, amount: float):
	# Ammo reshapes the blast before anything else: HE and flechette widen
	# it, AP collapses it to effectively nothing (see
	# AMMO_NO_SPLASH_RADIUS). Every explosive weapon routes through here, so
	# no individual _fire_*() had to learn about ammo.
	radius = max(radius * ammo_aoe_mult, AMMO_NO_SPLASH_RADIUS)
	_maybe_crater(center, radius)
	# On-impact payload effects (clouds, burn pools, flares) fire once per
	# detonation - here, not in _deal_weapon_damage(), which runs once per
	# target caught in the blast.
	_apply_ammo_impact(center)

	var my_team = get_team()
	for c in get_tree().get_nodes_in_group("damageable"):
		if not is_instance_valid(c) or not c.has_method("take_damage"):
			continue
		if "is_dead" in c and c.is_dead:
			continue
		var c_team = c.get_meta("team") if c.has_meta("team") else -1
		if my_team >= 0 and c_team == my_team:
			continue
		var dist = center.distance_to(c.global_position)
		if dist > radius:
			continue
		var falloff = clamp(1.0 - (dist / radius), 0.0, 1.0)
		if falloff <= 0.0:
			continue
		_deal_weapon_damage(c, amount * falloff)

# FABLE_REVIEW.md 1.8 fix: flying units cruise at y=4.0, permanently above
# DamageResolver's 2.0 elevation-advantage threshold - so every air-to-ground
# shot silently collected the armor-pierce bonus meant to reward holding
# high TERRAIN. A flying attacker's hit origin is flattened to the target's
# own height (treated as level fire); ground attackers (including ones
# standing on a real hill) keep their true position and the earned bonus.
func _hit_origin(t: Node3D) -> Vector3:
	var origin = global_position
	var vehicle = get_vehicle_root()
	if vehicle and "is_flying" in vehicle and vehicle.is_flying and is_instance_valid(t):
		origin.y = min(origin.y, t.global_position.y + 0.5)
	return origin

# Helper to find all colliders recursively
func _get_colliders_recursive(node: Node, list: Array):
	if node is CollisionObject3D:
		list.append(node.get_rid())
	for child in node.get_children():
		_get_colliders_recursive(child, list)

# PERFORMANCE_PLAN.md P1b: _get_colliders_recursive() walks a node's ENTIRE
# subtree (for a full vehicle: the hull plus every mounted module) on every
# single LOS raycast - this weapon's own tree, plus whichever candidate is
# currently being checked, every tick a target is tracked and every
# candidate considered during reacquisition. Cache the result on the node
# itself via set_meta() (not a static Dictionary here - metadata dies with
# the node, so a freed vehicle can't leak a cache entry forever) with a
# short TTL. A module lost mid-battle (subsystem stripping) can leave one
# stale, already-invalid RID in a cached list for up to the TTL - Godot's
# exclude array silently skips RIDs that no longer resolve to a live
# collider, so this is a harmless, bounded imprecision, not a correctness
# bug.
const COLLIDER_CACHE_TTL_MS: int = 1000
func _cached_colliders_for(node: Node) -> Array:
	var now = Time.get_ticks_msec()
	if node.has_meta("_collider_cache_expires_at") and now < node.get_meta("_collider_cache_expires_at"):
		return node.get_meta("_collider_cache_list")
	var list = []
	_get_colliders_recursive(node, list)
	node.set_meta("_collider_cache_list", list)
	node.set_meta("_collider_cache_expires_at", now + COLLIDER_CACHE_TTL_MS)
	return list

# Helper to find vehicle root
# True when a deployed bipod should be holding fire. A bipod is planted on
# the ground; a vehicle that is driving is not a firing platform. Reads the
# owning vehicle's own horizontal velocity, ignoring Y so a unit riding
# terrain undulations doesn't count as "moving" - the same reason
# _find_nearest_target's evasion maths flattens target velocity.
#
# Fails OPEN (returns false) when there is no vehicle or no velocity to
# read: a Test Range dummy or a building-mounted rifle has no locomotion to
# begin with, and silently refusing to ever fire in those contexts would be
# a far worse bug than the mechanic is worth.
func _bipod_blocks_firing() -> bool:
	# Self-guarding on bipod_deployed, not just relying on the caller to
	# check first. The name is a claim about this weapon, and a weapon with
	# no bipod down is never blocked by one - a bare velocity check here
	# would answer "yes" for every stowed rifle and every other weapon in
	# the roster that ever called it.
	if not bipod_deployed:
		return false
	var root_vehicle = get_vehicle_root()
	if root_vehicle == null or not ("velocity" in root_vehicle):
		return false
	var v: Vector3 = root_vehicle.velocity
	return Vector3(v.x, 0.0, v.z).length() > BIPOD_MOVING_SPEED

func get_vehicle_root() -> Node3D:
	var p = get_parent()
	while p:
		if p.is_in_group("player_vehicle") or p.is_in_group("targets") or p.is_in_group("damageable"):
			return p
		p = p.get_parent()
	return null

# Team of the construct this weapon is mounted on (-1 = legacy test range, no team)
func get_team() -> int:
	var root_vehicle = get_vehicle_root()
	if root_vehicle and root_vehicle.has_meta("team"):
		return root_vehicle.get_meta("team")
	return -1

# RTS_CORE_ROADMAP.md B2: defers to skirmish.gd's is_allied() (slots'
# `allies` lists) wherever this file used to hardcode "same team = not
# hostile." Duck-typed via current_scene so this stays zero-dependency in
# every context without a real Skirmish (test range, legacy tests) - falls
# back to plain team equality there, i.e. unchanged old behavior.
func _teams_allied(a: int, b: int) -> bool:
	if a == b:
		return true
	var scene = get_tree().current_scene
	if scene and scene.has_method("is_allied"):
		return scene.is_allied(a, b)
	return false

# Line of sight raycast check.
#
# FABLE_REVIEW.md 3.1 fix: the old logic only reported "blocked" when the ray
# hit the weapon's OWN vehicle - a hit on a rock, urban building, or any other
# world geometry fell through to "clear," so units fired straight through
# cover the moment a target was team-spotted (the vision system blocked
# sightlines, the weapons didn't). Now ANY non-excluded hit blocks: world
# geometry (layer 1 - obstacles/rocks/urban buildings, the same layer
# skirmish.gd's vision LOS already checks), module bodies (layer 2 - own
# sibling masts etc., matching the Design Lab firing-arc visualization's
# blocked-segment behavior), and buildings (layer 8). Units (layer 4)
# deliberately do NOT block - firing through/past friendly units is standard
# RTS behavior and blocking on it would deadlock any grouped formation.
# The target's own colliders are excluded so the target can never "block"
# the shot at itself. Own-hull blocking (the logged sponson-through-own-hull
# question, DECISIONS_NEEDED.md 2026-07-17) is handled by a second, narrower
# check inside _is_los_blocked_to() below - see its comment - since the
# layer-4 omission above (needed to keep OTHER units from blocking) also
# happened to exempt a weapon's own vehicle, which lives on that same layer.
func _is_line_of_sight_blocked() -> bool:
	return _is_los_blocked_to(target)

# Line of sight from this weapon's muzzle to an arbitrary candidate.
#
# Pulled out of _is_line_of_sight_blocked() so target ACQUISITION can consult
# it too, not just the firing gate. A pintle mount has no mechanical traverse
# limit (see ModuleCatalog.get_traverse_limit_angle) - what actually decides
# whether it can engage a given direction is whether the hull or a neighbouring
# module is in the way. With acquisition blind to that, a weapon would lock
# onto the nearest enemy, discover at the firing gate that its own hull was
# between them, and then sit there aiming at it forever instead of picking a
# target it could actually hit.
func _is_los_blocked_to(candidate: Node3D) -> bool:
	if not candidate or not is_instance_valid(candidate): return true

	# Indirect fire arcs OVER whatever is in between, so a straight raycast to
	# the target is the wrong question to ask of it. Requiring an unbroken
	# sightline was survivable while a mortar reached 28 units; with artillery
	# at 140 (ModuleCatalog.RANGE_TIERS) there is essentially always a rock,
	# a building or a ridge somewhere in the intervening distance on a real
	# map, so the LOS check alone would have made the entire Operational tier
	# unable to fire. The set is exactly the weapons whose delivery IS a
	# ballistic arc - a 72-unit gauss railgun still has to see what it shoots.
	if ModuleCatalog.is_indirect_fire(type_id):
		return false

	var space_state = get_world_3d().direct_space_state
	# Weapons face forward along negative Z relative to their own local space
	var muzzle_forward = -global_transform.basis.z.normalized()

	# Offset along the weapon's OWN up axis, not world up. Since placement
	# aligns local +Y with the surface normal it was mounted on, this always
	# steps AWAY from the hull - whereas the old world-up offset pushed a
	# side- or belly-mounted weapon's ray start straight into the hull it was
	# bolted to.
	var muzzle_up = global_transform.basis.y.normalized()
	var ray_start = global_position + muzzle_up * _los_height_offset + muzzle_forward * 0.8
	var ray_end = candidate.global_position + Vector3(0, 1.25, 0) # target center (elevated to match hull center and avoid ground grazing)

	var query = PhysicsRayQueryParameters3D.create(ray_start, ray_end)
	# Ground/obstacles (1), Modules (2), Buildings (8), Smoke (32) - not
	# units (4). Smoke is an Area3D on its own layer (see smoke_volume.gd
	# for why it isn't just put on layer 1), which this query already picks
	# up because collide_with_areas is on below.
	query.collision_mask = 1 + 2 + 8 + SmokeVolume.SMOKE_COLLISION_LAYER
	query.collide_with_areas = true

	# Exclude this weapon's own colliders and everything belonging to the
	# candidate (a target can never "block" the shot at itself). Units
	# (layer 4) stay out of this query's mask - firing through/past other
	# units is standard RTS behavior, blocking on it would deadlock any
	# grouped formation.
	#
	# Excludes the whole VEHICLE ROOT's subtree, not just this weapon
	# module's own - a mobile unit's own hull collider lives on layer 4
	# (units), already outside this query's mask by construction, so using
	# just `self` here never mattered for those. A defense building's own
	# foundation collider (building.gd's CollisionShape3D) lives on layer 8
	# ("Buildings"), which this query's mask DOES include - excluding only
	# the weapon module's own (empty) subtree left every defense weapon's
	# own foundation box eligible to block its own first raycast, so a
	# defense's turret could permanently "see" its own base and treat every
	# target as blocked. get_vehicle_root() covers both cases uniformly.
	var vehicle_for_exclude = get_vehicle_root()
	var own_colliders = _cached_colliders_for(vehicle_for_exclude if vehicle_for_exclude else self) + _cached_colliders_for(candidate)
	query.exclude = own_colliders

	var result = space_state.intersect_ray(query)
	if not result.is_empty():
		return true

	# Own-hull self-occlusion (DECISIONS_NEEDED.md 2026-07-17 "sponson
	# weapons may be able to shoot through their own hull"): a battle-spawned
	# hull's collider lives on unit.gd's own CharacterBody3D (layer
	# 4, "units" - see setup()'s CollisionShape3D and the running-gear
	# collider), the very layer the query above deliberately omits so other
	# units never block a shot. That omission meant a weapon's OWN hull
	# could never block its own shot either - a sponson/pintle mounted on
	# the near side could "see" and hit a target its own vehicle's mass was
	# actually between it and. A second, narrower ray - units back in the
	# mask, but only this weapon's own vehicle counts as a block - catches
	# that case without reopening the ally-formation deadlock: if the first
	# thing hit is some OTHER unit standing in the way, that's disregarded
	# (same permissive behavior the first query already has for units);
	# only a hit on this weapon's own vehicle body counts as blocked.
	var vehicle = get_vehicle_root()
	if vehicle:
		var self_query = PhysicsRayQueryParameters3D.create(ray_start, ray_end)
		self_query.collision_mask = 4 # Units
		self_query.collide_with_areas = true
		self_query.exclude = _cached_colliders_for(candidate)
		var self_result = space_state.intersect_ray(self_query)
		if not self_result.is_empty() and self_result.get("collider") == vehicle:
			return true

	return false

# Basis pointing -Z along `dir`, safe for a target directly overhead or
# directly underneath.
#
# Basis.looking_at(dir, Vector3.UP) is undefined when dir is parallel to the
# up reference - it collapses to a singular matrix and Godot logs
# 'Condition "det == 0" is true'. That is exactly the straight-up and
# straight-down case, so a pintle weapon could traverse freely in azimuth but
# went haywire the moment it tried to fully depress onto something beneath it
# (or elevate onto something directly above). Swapping to a sideways
# reference vector in that cone keeps the basis well-conditioned, which is
# what lets a pintle actually cover the whole sphere rather than just a band
# around the horizon.
static func _looking_at_safe(dir: Vector3) -> Basis:
	var d = dir.normalized()
	if d.length_squared() < 0.5:
		return Basis.IDENTITY
	var up_ref = Vector3.UP
	if abs(d.dot(Vector3.UP)) > 0.999:
		up_ref = Vector3.BACK
	return Basis.looking_at(d, up_ref)


# AIM RELATIVE TO REST, not absolute. _looking_at_safe() returns a basis in the
# parent (hull) frame pointing -Z straight at the target with world-style up.
# Written ABSOLUTELY onto transform.basis it silently discards the mount's
# authored orientation - invisible on a roof mount whose rest is near identity,
# but a belly mount's rest carries the flip that points its barrel down/outward,
# so the absolute look-at made the whole module swing through the hull: the
# "the entire model rotates and pitches, not just the weapon" report. Instead,
# re-express the target direction in the REST frame (where the barrel's
# canonical forward is -Z), build only the offset from rest, and compose it
# back on top - preserving every mount's authored flip, roll and cant.
static func _aim_basis_from_rest(q_rest: Quaternion, parent_dir: Vector3) -> Basis:
	var d := parent_dir.normalized()
	if d.length_squared() < 0.5:
		return Basis(q_rest)
	var rest_dir := q_rest.inverse() * d
	var q_off := _looking_at_safe(rest_dir).get_rotation_quaternion()
	return Basis(q_rest * q_off)

func _ready():
	resting_transform = transform
	# PERFORMANCE_PLAN.md P1a: random phase so every weapon doesn't reacquire
	# on the same physics frame as every other weapon.
	#
	# SIM. This looks like a performance detail but it decides WHEN a weapon
	# re-scans for a target, and therefore which target it acquires when two come
	# into range within the same 0.2s window. Two clients that staggered
	# differently would pick different targets from the same world state.
	_reacquire_timer = SimRNG.randf() * REACQUIRE_INTERVAL
	if has_meta("module_data"):
		var data = get_meta("module_data")
		type_id = data.type_id
		var mount_faction = get_parent().get_meta("faction", "industrialists") if get_parent() and get_parent().has_meta("faction") else "industrialists"
		base_dps = data.get_dps()
		dps = base_dps
		heal_rate = data.get_heal_rate()
		
		# TRAVERSE SPEED. Starts from this weapon's own base
		# (ModuleCatalog.get_base_traverse - see its comment for the band and
		# how the values were derived) and is then moved by what has actually
		# been done to THIS module.
		#
		# The base used to be derived from the instance's weight instead, which
		# meant a weapon had no rate of its own to be modified away from: a
		# heavy archetype and a heavily-tweaked light one were indistinguishable
		# inputs to the same 200/weight expression.
		#
		# Weight now enters as a RATIO against the module's own untweaked mass,
		# so an untweaked weapon sits exactly on its published base and every
		# tweak that adds mass costs traverse in proportion. base_weight is the
		# catalog figure the ModuleData was constructed with; get_weight() is
		# that after tweaks, node scale and ammo stowage - so scaling a module
		# up or loading heavier rounds slows it too, which is correct.
		var base_traverse: float = ModuleCatalog.get_base_traverse(type_id)
		var live_weight: float = data.get_weight()
		var ref_weight: float = data.base_weight if data.base_weight > 0.0 else live_weight
		var weight_factor := 1.0
		if live_weight > 0.001 and ref_weight > 0.001:
			weight_factor = pow(ref_weight / live_weight, TRAVERSE_WEIGHT_EXPONENT)

		# Length is charged SEPARATELY from the mass it adds, because moment of
		# inertia goes with mass times the square of the radius - a longer
		# barrel is worse for traverse than the same extra mass bolted close in
		# (Chris: "the same with barrel length: longer makes it slower, shorter
		# makes it faster (angular momentum)").
		#
		# Only the tweaks that are literally the long tube the shot travels
		# down. Every other "bigger part" tweak still costs traverse, but
		# through the weight ratio above rather than twice.
		var length_factor := 1.0
		for tweak_name in TRAVERSE_LENGTH_TWEAKS:
			var v = data.tweaks.get(tweak_name, 1.0)
			if (typeof(v) == TYPE_FLOAT or typeof(v) == TYPE_INT) and float(v) > 0.001:
				length_factor *= pow(1.0 / float(v), TRAVERSE_LENGTH_EXPONENT)

		# The two factors compound, and going lighter AND shorter pushes them
		# both the same way: a 0.6x barrel on a light gun came out 2.4x its base
		# and hit the ceiling, where a cannon shaved to 0.5x hit the SAME
		# ceiling - two different weapons converging on one number, which is the
		# flattening this whole rework exists to remove. Penalties may run all
		# the way down to the floor; the bonus is capped, on the reading that a
		# mount's drive is rated for its weapon class and cannot be exploited
		# indefinitely by shaving the gun. Keeping the top tied to
		# base_traverse rather than to a shared clamp is what preserves
		# per-weapon differentiation among light, stripped-down builds.
		var tweak_factor: float = minf(weight_factor * length_factor, TRAVERSE_TWEAK_GAIN_MAX)
		traverse_speed = base_traverse * tweak_factor
		_los_height_offset = ModuleCatalog.get_module_data(type_id).size.y * 0.7
		
		# Traverse limit angle: shared with the Design Lab's firing-arc
		# visualization via ModuleCatalog.get_traverse_limit_angle() so the
		# two can never drift apart.
		var mount_facet = get_meta("facet", "")
		var mount_hull_type = ""
		var mount_parent = get_parent()
		if mount_parent and mount_parent.has_meta("type_id"):
			mount_hull_type = mount_parent.get_meta("type_id")
		# The sponson flag comes off the module the placer built, not
		# re-derived from the normal here - re-deriving is how the Lab and
		# combat drifted apart the last time (see
		# test_design_lab_firing_arc_matches_real_pintle_traverse).
		# Both sides read this same meta.
		traverse_limit_angle = ModuleCatalog.get_traverse_limit_angle(
			type_id, mount_facet, mount_hull_type, get_meta("sponson", false))
		# Elevation stops, same shared-with-the-visualiser arrangement as the
		# yaw limit above. Read once here rather than per-candidate, since
		# acquisition asks about them for every hostile in reach every scan.
		elevation_up_limit = ModuleCatalog.get_elevation_up(type_id, data.tweaks)
		elevation_down_limit = ModuleCatalog.get_elevation_down(type_id, data.tweaks)


		if type_id in ["basic_cannon", "heavy_machine_gun", "rotary_cannon", "gauss_railgun", "ciws", "coil_gun", "autocannon", "anti_materiel_rifle", "hypervelocity_missile", "aa_autocannon"]:
			damage_class = "kinetic"
		elif type_id in ["artillery", "mortar_array", "guided_missile", "missile_pod", "cluster_dispenser", "flak_cannon", "smoke_discharger", "mk19_grenade_launcher", "recoilless_rifle", "mine_layer", "spigot_mortar", "rocket_artillery", "sam_launcher", "loitering_munition", "anti_radiation_missile", "bunker_buster", "cruise_missile"]:
			damage_class = "explosive"
		elif type_id in ENERGY_DAMAGE_CLASS_TYPES:
			# See ENERGY_DAMAGE_CLASS_TYPES's own comment for the full
			# reasoning and DECISIONS_NEEDED.md for the concrete
			# before/after threshold numbers this reclassification changes.
			damage_class = "energy"
		else:
			damage_class = "thermal"

		if type_id == "heavy_barrier_projector":
			field_width_mult = float(data.tweaks.get("field_width", 1.0))
			barrier_capacity_mult = float(data.tweaks.get("barrier_capacity", 1.0))
			projection_dist = float(data.tweaks.get("projection_distance", 25.0))
			barrier_max_hp = 600.0 * barrier_capacity_mult
			barrier_current_hp = barrier_max_hp

		# Ammo resolution, applied AFTER the native damage_class chain above
		# so a loaded round overrides the weapon's own class rather than the
		# other way round. "standard" (and every weapon with no ammo
		# selection at all) leaves all three values exactly at their
		# pre-ammo defaults, so an old blueprint behaves identically.
		ammo_type = ModuleCatalog.get_ammo(type_id, data.tweaks)
		var ammo_profile = ModuleCatalog.get_ammo_profile(ammo_type)
		var ammo_class = ammo_profile.get("damage_class", "")
		if ammo_class != "":
			damage_class = ammo_class
		ammo_damage_mult = ammo_profile.get("damage_mult", 1.0)
		ammo_light_mult = ammo_profile.get("light_mult", 1.0)
		ammo_aoe_mult = ammo_profile.get("aoe_mult", 1.0)

		targets_allies = ModuleCatalog.targets_allies(type_id)
			
		# Base fire profile. These used to be a ~120-line if/elif chain right
		# here; they now live in ModuleCatalog.WEAPON_FIRE_PROFILES so balance
		# tooling can actually see and sweep them (fire_rate is the shot
		# interval, and per-shot damage `dps * fire_rate` is what the armor
		# thresholds gate on - so it's the strongest balance lever there is).
		# The tweak modifiers below still apply on top, unchanged.
		var fire_profile = ModuleCatalog.get_fire_profile(type_id)
		fire_rate = fire_profile.fire_rate
		laser_color = fire_profile.laser_color
		muzzle_offset = ModuleCatalog.get_muzzle_offset(type_id)

		# Range: the whole tweak chain lives in weapon_range.gd now, so the
		# Design Lab can show the same reach combat uses instead of having to
		# re-implement two dozen multipliers and then drift from them - which is
		# exactly what happened to weight capacity before drivetrain.gd.
		#
		# barrel_length is the headline modifier and the one Chris called out:
		# "longer barrel = greater velocity and range". Because munition speed is
		# derived from fire_range (see _munition_speed), the velocity half of that
		# falls out of the same number rather than needing its own parallel chain,
		# and a longer barrel is also charged against traverse below - so the
		# slider is a genuine trade rather than a free upgrade.
		fire_range = WeaponRange.compute(type_id, data.tweaks, mount_faction)

		# Read separately from the reach chain because it gates FIRING, not
		# distance: deployed, the rifle reaches much further and hits harder at
		# that reach, and it cannot shoot at all while its vehicle is moving
		# (_bipod_blocks_firing). WeaponRange.compute applies the reach half; this
		# is the capability half, and together they make the tweak a real question
		# about how you intend to use the vehicle instead of a slider where more
		# is simply better.
		bipod_deployed = data.tweaks.get("bipod_deploy", 0.0) >= 0.5

		# The blanket "divide traverse by every linear-scale tweak" pass that
		# used to sit here is gone. It dated from an audit that found most
		# tweaks had no direct traverse effect, and fixed that by charging EVERY
		# one of ModuleCatalog.LINEAR_SCALE_WEAPON_TWEAKS a full division - on
		# top of the weight-derived base, which those same tweaks had already
		# driven up. So a tweak was charged twice, and a weapon carrying four
		# such tweaks at 1.5 lost a factor of 5.06 in traverse from a mass
		# increase of the same 5.06 - compounding to a rate no amount of
		# per-type tuning could rescue.
		#
		# Weight is now charged exactly once, as a ratio (above), and length
		# gets its own separate term because inertia genuinely scales with the
		# square of the radius rather than with mass alone.
		traverse_speed = clamp(traverse_speed, TRAVERSE_SPEED_MIN, TRAVERSE_SPEED_MAX)

		# Apply Fire Rate Tweak Modifiers (Shot Intervals)
		_caliber = data.tweaks.get("caliber", 1.0)
		if data.tweaks.has("caliber"):
			fire_rate *= data.tweaks["caliber"]
		if data.tweaks.has("multi_barrel") and data.tweaks["multi_barrel"] == true:
			fire_rate /= 2.0
		if data.tweaks.has("tube_count") and data.tweaks["tube_count"] > 0.0:
			fire_rate *= (data.tweaks["tube_count"] / 2.0)
		if data.tweaks.has("grid_size") and data.tweaks["grid_size"] > 0.0:
			fire_rate *= (data.tweaks["grid_size"] / 4.0)
		if data.tweaks.has("pressure_valve") and data.tweaks["pressure_valve"] > 0.0:
			fire_rate /= data.tweaks["pressure_valve"]
		if data.tweaks.has("launch_catapult") and data.tweaks["launch_catapult"] > 0.0:
			fire_rate /= data.tweaks["launch_catapult"]

		# Energy weapons: cost to fire scales with the weapon's own damage
		# output (dps*fire_rate is the per-shot damage), so a bigger/harder-
		# hitting energy weapon also drains the capacitor faster per shot -
		# no separate catalog field needed, it falls out of existing stats.
		if type_id in ENERGY_WEAPON_TYPES:
			var per_shot_damage = dps * fire_rate
			energy_cost_per_shot = per_shot_damage * 0.4
			if type_id == "arc_projector":
				energy_drain_per_shot = per_shot_damage * 1.5
			elif type_id in ["ion_cannon", "microwave_emitter"]:
				energy_drain_per_shot = per_shot_damage * 0.5
			else:
				energy_drain_per_shot = 0.0


	# Desynchronize initial reload timers.
	#
	# SIM. The starting fire phase decides which of two identical units shoots
	# first, which decides which one dies. As outcome-defining as the hit roll,
	# despite reading like a presentation nicety.
	time_since_last_shot = SimRNG.randf_range(0.0, fire_rate)

# RTS_CORE_ROADMAP.md D4: a defense building's weapons are inert for its
# whole build_incomplete grace period (real construction time, not just a
# cosmetic scale-up) - walks up to whichever ancestor actually carries the
# flag (building.gd), since a weapon module sits several nodes below the
# building itself in the reconstructed hull hierarchy.
func _owner_building_incomplete() -> bool:
	var node = get_parent()
	while node:
		if "build_incomplete" in node:
			return node.build_incomplete
		node = node.get_parent()
	return false

# RTS_CORE_ROADMAP.md E1: "disabling defence weapons" while a team's power
# is Low or Critical - only ever applies to a "defense"-kind building.gd
# owner (a mobile unit's weapons run off its own onboard capacitor, never
# the team's base power - see ENERGY_AND_BALANCE_SPEC.md #1, the same
# boundary skirmish.gd's _recalc_energy_economy() already draws). Duck-
# typed through current_scene same as _teams_allied() - a real Skirmish's
# is_low_power(team), nothing in a synthetic test/test-range context.
func _owner_defense_low_power() -> bool:
	var node = get_parent()
	while node:
		if "kind" in node and node.kind == "defense":
			var scene = get_tree().current_scene
			if scene and scene.has_method("is_low_power"):
				return scene.is_low_power(node.team)
			return false
		node = node.get_parent()
	return false

func _physics_process(delta):
	if _owner_building_incomplete() or _owner_defense_low_power():
		return
	var _prof := Profiler.start()
	_tick_weapon(delta)
	Profiler.stop("weapons", _prof)


func _tick_weapon(delta):
	# Spin radar mast dish
	if type_id == "sensor_suite":
		var dish = get_node_or_null("sensor_suite_dish")
		if not dish:
			dish = get_node_or_null("RadarDish")
		if dish:
			dish.rotate_y(delta * 2.5)
		return

	if type_id == "heavy_sensor_suite":
		var radome = get_node_or_null("multispectrum_radome")
		if radome:
			radome.rotate_y(delta * 1.5)
		var pod = get_node_or_null("amr_sensor_pod")
		if pod:
			var t: float = float(Time.get_ticks_msec()) * 0.002
			pod.rotation.y = sin(t) * 0.35
		return

	if type_id == "directional_radar":
		var dish = get_node_or_null("directional_radar_dish")
		if dish:
			# Sector scan oscillation
			var t: float = float(Time.get_ticks_msec()) * 0.003
			dish.rotation.y = sin(t) * 0.4
		return

	if type_id == "energy_barrier_projector":
		var arr = get_node_or_null("energy_barrier_projector_array")
		if arr:
			arr.rotate_y(delta * 1.5)
		return

	if type_id == "heavy_barrier_projector":
		_tick_heavy_barrier(delta)
		return

	time_since_last_shot += delta
	_los_cache_timer -= delta
	_find_nearest_target(delta)
	_update_flame_jet()

	if target and is_instance_valid(target):
		var target_pos = target.global_position
		# Target center height
		if target.is_in_group("targets") or target.is_in_group("player_vehicle"):
			target_pos += Vector3(0, 0.5, 0)
			
		var dir_to_target = (target_pos - global_position).normalized()

		# frame_built (traverse_limit_angle == 0): the barrel is fixed
		# relative to the hull by definition - skip the independent-aim
		# slerp entirely and stay at resting_transform. The whole vehicle
		# has to turn to bring it to bear (unit.gd's
		# _has_frame_built_weapon/whole-vehicle-aim handles that), and the
		# angle_to_target check just below naturally reflects that since
		# global_transform now tracks the hull's own facing 1:1.
		if traverse_limit_angle > 0.001:
			# Target local direction relative to THIS WEAPON's own mount
			# point, not the hull's origin. Previously this normalized
			# target_local_pos directly - the target's position relative
			# to the hull's ORIGIN, not to the weapon's own (usually
			# off-center) mount position - which is only the correct aim
			# direction for a weapon sitting exactly at the hull's center.
			# Every other weapon (nearly all of them) aimed with a
			# permanent, never-converging angular error proportional to
			# its offset from hull-center and inversely proportional to
			# target distance (worse up close), so angle_to_target could
			# sit well above the 0.26 rad firing gate forever - a fully
			# independently-traversing pintle weapon that visibly slews
			# toward a target and then simply never actually fires.
			var target_local_pos = get_parent().to_local(target_pos)
			var local_dir = (target_local_pos - position).normalized()
			var target_local_basis = _aim_basis_from_rest(
				resting_transform.basis.get_rotation_quaternion(), local_dir)

			# Gradually rotate local basis towards target using Quaternions
			var q_current = transform.basis.get_rotation_quaternion()
			var q_target = target_local_basis.get_rotation_quaternion()
			var q_next = q_current.slerp(q_target, traverse_speed * delta)
			var local_scale = transform.basis.get_scale()
			transform.basis = Basis(q_next).scaled(local_scale)

		# Check if pointing close enough to fire
		var current_dir = -global_transform.basis.z.normalized()
		var angle_to_target = current_dir.angle_to(dir_to_target)
		
		# Only fire if pointing within ~15 degrees (0.26 rad) and not blocked.
		# Widened from 0.17 rad (10°): slow/heavy turrets that physically have
		# 360° arc were tracking targets indefinitely without ever closing into
		# the 10° cone tight enough to trigger a shot. 15° still requires the
		# weapon to be meaningfully pointed at the target while giving the
		# traverse mechanism realistic slack to complete its slew.
		if angle_to_target < 0.26 and not _is_line_of_sight_blocked():
			# Spin up check for Rotary Cannon
			if type_id == "rotary_cannon":
				var spin_needed = 0.8
				if has_meta("module_data"):
					var m_data = get_meta("module_data")
					var motor_size = m_data.tweaks.get("motor_size", 1.0)
					if motor_size > 0.0:
						spin_needed /= motor_size
				
				# Visually rotate barrels if spun up or spinning.
				var barrel_cluster = get_node_or_null("BarrelCluster")
				if not barrel_cluster:
					barrel_cluster = find_child("BarrelCluster", true, false)
				if barrel_cluster:
					barrel_cluster.rotate_object_local(Vector3.FORWARD, delta * (spin_up_timer / spin_needed) * 30.0)
				
				if spin_up_timer < spin_needed:
					spin_up_timer += delta
					return # still spinning up!
					
			if time_since_last_shot >= fire_rate:
				# Energy weapons need a charged capacitor to fire - a real
				# soft-limit on sustained fire, not just a stat number. If
				# the shooter has no current_energy field at all (a legacy/
				# test-harness node), fire freely rather than hard-blocking
				# on a duck-typed method that doesn't exist.
				var can_fire = true
				if _bipod_blocks_firing():
					can_fire = false
				if type_id in ENERGY_WEAPON_TYPES:
					var root_vehicle = get_vehicle_root()
					if root_vehicle and root_vehicle.has_method("spend_energy"):
						can_fire = root_vehicle.spend_energy(energy_cost_per_shot)
				if can_fire:
					time_since_last_shot = 0.0
					_fire_at_target()
		else:
			# Not pointing at target, spin down
			if type_id == "rotary_cannon":
				spin_up_timer = max(0.0, spin_up_timer - delta * 2.0)
	else:
		# Return to resting transform in local space using Quaternions
		var q_current = transform.basis.get_rotation_quaternion()
		var q_target = resting_transform.basis.get_rotation_quaternion()
		var q_next = q_current.slerp(q_target, traverse_speed * delta)
		var local_scale = transform.basis.get_scale()
		transform.basis = Basis(q_next).scaled(local_scale)
		
		# Spin down Gatling
		if type_id == "rotary_cannon":
			spin_up_timer = max(0.0, spin_up_timer - delta * 2.0)

# Target stickiness: re-scanning "nearest" from scratch every physics tick
# means two roughly-equidistant candidates (patrolling test dummies, two
# enemies converging on a flank) flip which one is "nearest" every single
# frame as they move, yanking the turret's slew back and forth and never
# letting angle_to_target close enough to fire - weapons could visibly
# track a target forever without ever landing a shot. Keeping the current
# target as long as it's still a legal pick (alive, in range, in arc, not
# fog-hidden, still the right kind of candidate for this weapon's mode)
# avoids the thrash; only reacquire once it's actually no longer valid.
# Can this weapon physically point at `dir`? Both halves of the envelope in one
# place, called from every acquisition scan and from the keep-current-target
# check, so no candidate can be accepted on one axis while failing the other.
#
# Previously all seven call sites tested yaw alone. That is why elevation had no
# gameplay effect at all before this: a weapon's reachable set was a cone about
# its resting heading, and a target directly overhead sat inside that cone for
# any pintle mount (traverse_limit_angle == PI), howitzer included.
func _can_aim_at(resting_forward: Vector3, dir: Vector3) -> bool:
	if resting_forward.angle_to(dir) > max(traverse_limit_angle, MIN_ACQUISITION_ARC):
		return false
	return _within_elevation(dir)

# Elevation half, split out so tests and the Design Lab can ask about it
# directly. `dir` is a world-space unit vector toward the target.
func _within_elevation(dir: Vector3) -> bool:
	# The weapon's own up axis, NOT world up. For a flush mount, placement
	# aligns local +Y with the mount surface normal, which is what makes a
	# belly-mounted weapon's stops mean the right thing (it correctly cannot
	# shoot up through its own hull).
	#
	# For a SPONSON (near-vertical face, module_placer._is_sponson_mount) local
	# +Y is hull-up instead, so this measures pitch against the real horizon.
	# That is the fix, not an exception: when such a weapon was flush-mounted
	# its +Y pointed outboard and this cone opened sideways - rejecting a
	# target level and outboard, accepting one directly overhead.
	var up := global_transform.basis.y.normalized()
	# Signed angle off the weapon's own horizon: positive is elevation toward
	# its up axis, negative is depression.
	var pitch := asin(clampf(dir.dot(up), -1.0, 1.0))
	if pitch > maxf(elevation_up_limit, MIN_ELEVATION_TOLERANCE) + ELEVATION_EPSILON:
		return false
	if -pitch > maxf(elevation_down_limit, MIN_DEPRESSION_TOLERANCE) + ELEVATION_EPSILON:
		return false
	return true

func _is_current_target_still_valid(resting_forward: Vector3) -> bool:
	if not target or not is_instance_valid(target):
		return false
	if "is_dead" in target and target.is_dead:
		return false
	if "health" in target and target.health <= 0.0:
		return false
	if target.is_in_group("missiles"):
		return true # transient - PD logic re-validates range/team itself below
	if targets_allies:
		if not ("hp" in target and "max_hp" in target) or target.hp >= target.max_hp:
			return false
	else:
		var my_team = get_team()
		if my_team >= 0:
			var t_team = target.get_meta("team") if target.has_meta("team") else -1
			if _teams_allied(t_team, my_team):
				return false
			if not _team_can_see(target):
				return false
	if global_position.distance_to(target.global_position) > fire_range:
		return false
	var dir = (target.global_position - global_position).normalized()
	if not _can_aim_at(resting_forward, dir):
		return false
	# Stop clinging to something our own hull is standing in front of -
	# otherwise the weapon tracks an unshootable target indefinitely instead
	# of reacquiring one it can actually engage.
	if _is_los_blocked_cached(target):
		return false

	# If the vehicle has acquired or switched to a primary combat target that we can range to,
	# and our current target is different, invalidate so we switch to the unit's target.
	var root_vehicle := get_vehicle_root()
	if root_vehicle != null and not targets_allies and not (type_id in PD_WEAPON_TYPES):
		var unit_target: Node3D = null
		if root_vehicle.has_method("get_combat_target"):
			unit_target = root_vehicle.get_combat_target()
		elif "target" in root_vehicle and root_vehicle.target is Node3D:
			unit_target = root_vehicle.target
		if is_instance_valid(unit_target) and target != unit_target and not ("is_dead" in unit_target and unit_target.is_dead):
			var u_dist := global_position.distance_to(unit_target.global_position)
			if u_dist <= fire_range and _team_can_see(unit_target):
				var u_dir := (unit_target.global_position - global_position).normalized()
				if _can_aim_at(resting_forward, u_dir) and not _is_los_blocked_cached(unit_target):
					return false

	return true

# PERFORMANCE_PLAN.md P1: cached wrapper around _is_los_blocked_to() for the
# "is my CURRENT target still valid" fast path - see the _los_cache_* var
# comments above. Reacquisition scans below call _is_los_blocked_to()
# directly (uncached), since those check many different one-off candidates
# rather than repeatedly re-checking the same target.
func _is_los_blocked_cached(candidate: Node3D) -> bool:
	if candidate == _los_cache_target and _los_cache_timer > 0.0:
		return _los_cache_blocked
	_los_cache_blocked = _is_los_blocked_to(candidate)
	_los_cache_target = candidate
	_los_cache_timer = LOS_CACHE_TTL
	return _los_cache_blocked

# PERFORMANCE_PLAN.md P1c: narrows the whole-roster "damageable" scan down
# to just the cells within `radius` of `pos` when a real Skirmish (with the
# spatial grid) is running the scene - duck-typed the same way
# _teams_allied() defers to current_scene.is_allied(), so the Test Range and
# every headless test fixture (neither has a real Skirmish) fall back to the
# exact old full-roster scan unchanged.
# The fog gate for target acquisition. Asks the skirmish controller for its
# per-team answer, so a weapon can engage anything its OWN TEAM has spotted
# rather than only what this one unit can see - the mechanic that makes the
# Overwatch and Operational range tiers (ModuleCatalog.RANGE_TIERS) mean
# anything, since those out-reach their own vision by 1.2x to 4.5x.
#
# Duck-typed through current_scene the same way _teams_allied() and
# _damageable_candidates() already are: the Test Range and every headless test
# fixture have no skirmish controller and fall back to the old per-construct
# fog_hidden flag, which in those contexts is never set - i.e. unchanged
# behaviour.
func _team_can_see(c) -> bool:
	if c == null or not is_instance_valid(c):
		return false
	var scene = get_tree().current_scene
	if scene and scene.has_method("is_visible_to_team"):
		return scene.is_visible_to_team(c, get_team())
	return not ("fog_hidden" in c and c.fog_hidden)

func _damageable_candidates(pos: Vector3, radius: float) -> Array:
	var scene = get_tree().current_scene
	if scene and scene.has_method("get_nearby_damageable"):
		return scene.get_nearby_damageable(pos, radius)
	return get_tree().get_nodes_in_group("damageable")
# delta defaults to -1.0 (a "forced/manual scan" sentinel, distinct from any
# real physics delta which is always >= 0.0) so every direct/manual caller in
# run_tests.gd - which calls this with no arguments and expects a synchronous,
# unthrottled scan - keeps working unchanged. Only real _physics_process(delta)
# ticks (delta >= 0.0) are subject to the throttle below.
func _find_nearest_target(delta: float = -1.0):
	if not is_inside_tree():
		return

	# A player-issued ground order outranks auto-acquisition for its whole
	# duration - the point of attack-ground is to shoot where you were TOLD
	# to, so a passing enemy must not silently steal the aim point.
	if _has_forced_target():
		target = _forced_target
		return

	# Obscurants do NOT auto-acquire.
	#
	# A smoke discharger used to ride this same targeting loop as every gun,
	# which meant it fired whenever any enemy came into range, at a point 70%
	# of the way toward them. That is the wrong trigger and the wrong aim
	# point for what smoke is: a screen exists to break line of sight for a
	# specific reason at a specific moment, and firing it off the instant
	# contact happens spends it before there is anything to hide.
	#
	# It now only fires when actually asked to, by one of two paths:
	#   - request_screen(), the automatic self-screen a unit triggers when it
	#     starts taking fire (unit.gd's take_damage) - aimed along the
	#     bearing the fire came FROM, which is the direction that needs
	#     blocking;
	#   - a player ctrl+right-click attack-ground order, handled by the
	#     forced-target branch above, which puts the cloud exactly where the
	#     player pointed.
	if type_id in OBSCURANT_TYPES:
		target = null
		return

	# sensor_beacon_launcher does not auto-acquire combat targets — it fires
	# into fog of war instead. A separate throttle prevents scanning every tick.
	if type_id == "sensor_beacon_launcher":
		target = null
		_scan_fog_and_fire_beacon(delta)
		return

	var resting_forward = get_parent().global_transform.basis * resting_transform.basis * Vector3.FORWARD

	if _is_current_target_still_valid(resting_forward):
		return

	# PERFORMANCE_PLAN.md P1a: the full-roster/grid scans below are the
	# expensive path - throttle them instead of running every tick while no
	# valid target exists. target stays whatever it currently is (usually
	# null) between scans. (Previously attempted and reverted this same
	# session over a suspected regression that turned out to be an
	# unrelated pre-existing flaky test - see git history / PROGRESS.md.)
	if delta >= 0.0:
		_reacquire_timer -= delta
		if _reacquire_timer > 0.0:
			return
		_reacquire_timer = REACQUIRE_INTERVAL

	# --- TEAM MODE (Skirmish): target any hostile "damageable" construct ---
	var my_team = get_team()
	if my_team >= 0:
		# repair_array's real fix: same-team, HP-deficit candidates instead
		# of hostiles - the opposite filter from every other weapon below.
		if targets_allies:
			var ally_candidates = _damageable_candidates(global_position, fire_range)
			var closest_ally: Node3D = null
			var closest_ally_dist: float = fire_range
			for c in ally_candidates:
				if not is_instance_valid(c) or not c.has_method("repair_hp"): continue
				var c_team = c.get_meta("team") if c.has_meta("team") else -1
				if not _teams_allied(c_team, my_team): continue
				if "is_dead" in c and c.is_dead: continue
				if not ("hp" in c and "max_hp" in c) or c.hp >= c.max_hp: continue
				var dist = global_position.distance_to(c.global_position)
				if dist < closest_ally_dist:
					var dir = (c.global_position - global_position).normalized()
					if _can_aim_at(resting_forward, dir):
						closest_ally = c
						closest_ally_dist = dist
			target = closest_ally
			return
		# Point defense still prioritizes missiles aimed at friendlies
		if type_id in PD_WEAPON_TYPES:
			var missiles = get_tree().get_nodes_in_group("missiles")
			var closest_m: Node3D = null
			var closest_m_dist: float = fire_range
			for m in missiles:
				if not is_instance_valid(m): continue
				var m_team = m.get_meta("team") if m.has_meta("team") else -1
				if _teams_allied(m_team, my_team): continue
				var dist_m = global_position.distance_to(m.global_position)
				if dist_m < closest_m_dist:
					var dir_m = (m.global_position - global_position).normalized()
					if _can_aim_at(resting_forward, dir_m):
						closest_m = m
						closest_m_dist = dist_m
			if closest_m:
				target = closest_m
				return
		# Prioritize the parent vehicle's designated combat target if in range, arc, and LOS
		var root_veh := get_vehicle_root()
		if root_veh != null:
			# HOLD_FIRE check: If the vehicle is in HOLD_FIRE stance, it only fires at its designated
			# combat target (e.g. ordered attack or retaliating against an attacker) and never auto-acquires ambient candidates.
			if "stance" in root_veh and root_veh.stance == StanceScript.Kind.HOLD_FIRE:
				var unit_target: Node3D = null
				if root_veh.has_method("get_combat_target"):
					unit_target = root_veh.get_combat_target()
				elif "target" in root_veh and root_veh.target is Node3D:
					unit_target = root_veh.target
				if is_instance_valid(unit_target) and not ("is_dead" in unit_target and unit_target.is_dead):
					var u_team = unit_target.get_meta("team") if unit_target.has_meta("team") else -1
					if not _teams_allied(u_team, my_team) and _team_can_see(unit_target):
						var u_dist := global_position.distance_to(unit_target.global_position)
						if u_dist <= fire_range:
							var u_dir := (unit_target.global_position - global_position).normalized()
							if _can_aim_at(resting_forward, u_dir) and not _is_los_blocked_to(unit_target):
								target = unit_target
								return
				target = null
				return

			var unit_target: Node3D = null
			if root_veh.has_method("get_combat_target"):
				unit_target = root_veh.get_combat_target()
			elif "target" in root_veh and root_veh.target is Node3D:
				unit_target = root_veh.target
			if is_instance_valid(unit_target) and not ("is_dead" in unit_target and unit_target.is_dead):
				var u_team = unit_target.get_meta("team") if unit_target.has_meta("team") else -1
				if not _teams_allied(u_team, my_team) and _team_can_see(unit_target):
					var u_dist := global_position.distance_to(unit_target.global_position)
					if u_dist <= fire_range:
						var u_dir := (unit_target.global_position - global_position).normalized()
						if _can_aim_at(resting_forward, u_dir) and not _is_los_blocked_to(unit_target):
							target = unit_target
							return

		var candidates = _damageable_candidates(global_position, fire_range)
		var closest_c: Node3D = null
		var closest_c_dist: float = fire_range
		for c in candidates:
			if not is_instance_valid(c) or not c.has_method("take_damage"): continue
			var c_team = c.get_meta("team") if c.has_meta("team") else -1
			if _teams_allied(c_team, my_team): continue
			if "is_dead" in c and c.is_dead: continue
			# Fog-of-war: can't target what the TEAM hasn't spotted. This is
			# the spotter mechanic - the unit doing the looking and the unit
			# doing the shooting are deliberately allowed to be different
			# units on opposite sides of the field, which is the only reason
			# a T5 weapon reaching 4x its own vision is usable at all.
			if not _team_can_see(c): continue
			var dist = global_position.distance_to(c.global_position)
			if dist < closest_c_dist:
				var dir = (c.global_position - global_position).normalized()
				if _can_aim_at(resting_forward, dir) and not _is_los_blocked_to(c):
					closest_c = c
					closest_c_dist = dist
		target = closest_c
		return

	# Point Defenses prioritize incoming missiles
	if type_id in PD_WEAPON_TYPES:
		var missiles = get_tree().get_nodes_in_group("missiles")
		var closest: Node3D = null
		var closest_dist: float = fire_range
		for m in missiles:
			if is_instance_valid(m):
				var dist = global_position.distance_to(m.global_position)
				if dist < closest_dist:
					var dir = (m.global_position - global_position).normalized()
					if _can_aim_at(resting_forward, dir):
						closest = m
						closest_dist = dist
		target = closest
		if target: return

	# Standard target dummies
	var targets = get_tree().get_nodes_in_group("targets")
	
	# If this weapon is on target dummy, target the player instead!
	var root_vehicle = get_vehicle_root()
	if root_vehicle and root_vehicle.is_in_group("targets"):
		var player = get_tree().get_first_node_in_group("player_vehicle")
		if player and is_instance_valid(player) and not player.is_dead:
			var dist = global_position.distance_to(player.global_position)
			if dist < fire_range:
				var dir = (player.global_position - global_position).normalized()
				if _can_aim_at(resting_forward, dir):
					target = player
					return
		target = null
		return

	# Player targeting dummies
	var closest: Node3D = null
	var closest_dist: float = fire_range
	for t in targets:
		if is_instance_valid(t) and t.has_method("take_damage"):
			if "health" in t and t.health <= 0.0:
				continue
			var dist = global_position.distance_to(t.global_position)
			if dist < closest_dist:
				var dir = (t.global_position - global_position).normalized()
				if _can_aim_at(resting_forward, dir) and not _is_los_blocked_to(t):
					closest = t
					closest_dist = dist
	target = closest

func _fire_at_target():
	if not target or not is_instance_valid(target): return
	
	# Point Defense intercepting a missile
	if target.is_in_group("missiles"):
		_fire_pd_at_missile()
		return
		
	# Spawn a directional muzzle flash (except for silent lasers/beams/harvester/welder).
	# Flash position is per-weapon from ModuleCatalog.MUZZLE_OFFSETS, scaled by caliber.
	# Directional cone emission sprays particles forward along the barrel axis.
	# OmniLight pop is sized by caliber for visibility at RTS zoom.
	if not type_id in ["heavy_laser", "pd_laser", "resource_harvester", "repair_array"]:
		var flash_pos = muzzle_offset * Vector3(_caliber, _caliber, _caliber)
		var light_r = 3.0 + _caliber * 3.0
		var light_e = 4.0 + _caliber * 3.0
		VFXEffects.muzzle_flash(self, flash_pos, -global_transform.basis.z, _caliber, laser_color, laser_color, light_r, light_e)

	# Each weapon family gets its own vocalised ordnance report. Empty string
	# means a non-firing module (sensor, booster) - no report at all. Keys map
	# 1:1 to voice.ORDNANCE entries, so a new weapon sound is a one-line add
	# here plus a generator in tools/audio/voice.py.
	var sfx_name := ""
	match type_id:
		"basic_cannon", "recoilless_rifle", "anti_materiel_rifle": sfx_name = "cannon"
		"artillery": sfx_name = "artillery"
		"heavy_machine_gun": sfx_name = "machine_gun"
		"rotary_cannon": sfx_name = "rotary"
		"flak_cannon", "flak_battery", "ciws", "autocannon", "aa_autocannon": sfx_name = "autocannon"
		"mk19_grenade_launcher": sfx_name = "grenade"
		"gauss_railgun", "coil_gun": sfx_name = "gauss"
		"heavy_laser", "pd_laser", "point_defense_laser", "laser_cannon", "arc_projector", "ion_cannon", "microwave_emitter", "particle_lance": sfx_name = "beam"
		"guided_missile", "missile_pod", "cluster_dispenser", "sam_launcher", "loitering_munition", "anti_radiation_missile", "bunker_buster", "cruise_missile", "drone_carrier": sfx_name = "missile"
		"hypervelocity_missile", "rocket_artillery": sfx_name = "rocket"
		"smoke_discharger", "mine_layer", "sensor_beacon_launcher": sfx_name = "smoke"
		"mortar_array", "napalm_mortar", "spigot_mortar": sfx_name = "mortar"
		"flamethrower": sfx_name = "flamethrower"
		"plasma_lobber", "plasma_launcher": sfx_name = "plasma"
		"resource_harvester", "repair_array": sfx_name = "harvest"
	if sfx_name != "" and get_node_or_null("/root/AudioManager"):
		get_node("/root/AudioManager").play_sfx_3d(sfx_name, global_position, null, 50.0)

	# Call unique visual functions
	match type_id:
		"basic_cannon", "heavy_machine_gun", "rotary_cannon":
			_fire_gun_tracer()
		"gauss_railgun":
			_fire_railgun_beam()
		"artillery":
			_fire_artillery()
		"mortar_array":
			_fire_mortar_salvo()
		"guided_missile":
			_fire_missile_projectile(false)
		"spigot_mortar":
			_fire_spigot_mortar()
		"rocket_artillery":
			_fire_rocket_artillery()
		"hypervelocity_missile":
			_fire_hypervelocity_missile()
		"sam_launcher":
			_fire_sam_launcher()
		"loitering_munition":
			_fire_loitering_munition()
		"anti_radiation_missile":
			_fire_anti_radiation_missile()
		"bunker_buster":
			_fire_bunker_buster()
		"cruise_missile":
			_fire_cruise_missile()
		"aa_autocannon":
			_fire_aa_autocannon()
		"sensor_beacon_launcher":
			_fire_sensor_beacon_launcher()
		"missile_pod":
			_fire_swarm_missiles()
		"drone_carrier":
			_fire_drone_swarm()
		"cluster_dispenser":
			_fire_cluster_dispenser()
		"flamethrower":
			_fire_flame_spray()
		"heavy_laser":
			_fire_continuous_beam()
		"plasma_lobber":
			_fire_plasma_lobber()
		"ciws":
			_fire_gun_tracer()
		"pd_laser":
			_fire_continuous_beam()
		"flak_cannon":
			_fire_flak_cannon()
		"smoke_discharger":
			_fire_smoke_discharger()
		"mk19_grenade_launcher":
			_fire_grenade_launcher()
		"recoilless_rifle":
			_fire_recoilless_rifle()
		"coil_gun":
			_fire_coil_gun()
		"autocannon":
			_fire_gun_tracer()
		"anti_materiel_rifle":
			_fire_anti_materiel_rifle()
		"napalm_mortar":
			_fire_napalm_mortar()
		"mine_layer":
			_fire_mine_layer()
		"resource_harvester":
			_fire_resource_harvester_tether()
		"repair_array":
			_fire_repair_array_beam()
		"arc_projector":
			_fire_arc_projector()
		"microwave_emitter":
			_fire_microwave_emitter()
		"particle_lance":
			_fire_particle_lance()
		"ion_cannon":
			_fire_ion_cannon()
		_:
			_fire_standard_laser()

func _fire_pd_at_missile():
	if type_id == "pd_laser":
		var beam = MeshInstance3D.new()
		beam.mesh = MunitionPool.unit_cylinder()
		beam.material_override = MunitionPool.emissive(Color.LIGHT_CORAL, Color.RED)
		_effects_parent().add_child(beam)
		MunitionPool.aim_beam(beam, global_position, target.global_position, 0.04)
		var timer = get_tree().create_timer(0.08)
		timer.timeout.connect(func(): if is_instance_valid(beam): beam.queue_free())
		
	if target.has_method("destroy_missile"):
		target.destroy_missile(true)

func _fire_gun_tracer():
	var v: Dictionary = ModuleCatalog.get_gun_tracer_visual(type_id)
	_fire_kinetic_projectile(
		v.get("radius", 0.03), v.get("length", 0.35), v.get("duration", 0.12),
		laser_color, v.get("explode_on_hit", false), v)

func _fire_kinetic_projectile(radius: float, length: float, duration: float, color: Color, explode_on_hit: bool, profile: Dictionary = {}):
	if profile.get("streak", false):
		radius *= 0.45
		length *= 1.3
	var energy := 1.6 if profile.get("streak", false) else 1.0
	var tracer = MeshInstance3D.new()
	tracer.mesh = MunitionPool.unit_cylinder()
	tracer.material_override = MunitionPool.emissive(color, color, energy)
	_effects_parent().add_child(tracer)

	var start = global_position + Vector3(0, 0.4, 0)
	var end = target.global_position if is_instance_valid(target) else start + (-global_transform.basis.z * 20.0)
	var delta = end - start
	var dir_len = delta.length()
	if dir_len > 0.001:
		var y_axis = delta / dir_len
		var up_candidate = Vector3.UP if absf(y_axis.dot(Vector3.UP)) < 0.99 else Vector3.FORWARD
		var x_axis = y_axis.cross(up_candidate).normalized()
		var z_axis = x_axis.cross(y_axis).normalized()
		var basis = Basis(x_axis * (radius * 2.0), y_axis * length, z_axis * (radius * 2.0))
		tracer.global_transform = Transform3D(basis, start)
	else:
		tracer.global_position = start
		tracer.scale = Vector3(radius * 2.0, length, radius * 2.0)
	
	var tween = create_tween()
	tween.tween_property(tracer, "global_position", end, duration)
	tween.finished.connect(func():
		if is_instance_valid(tracer): tracer.queue_free()
		# Flechette/HE/incendiary turn a direct-fire round into a spraying
		# one; standard and AP keep this single-target exactly as it always
		# was. _deal_aoe_damage() applies the payload impact itself, so the
		# two branches must not both do it.
		if ammo_aoe_mult > 1.0:
			_deal_aoe_damage(end, 1.0, dps * fire_rate)
		else:
			# Payload effects land wherever the round lands, target still
			# alive or not - a smoke round that arrives after its aim point
			# died still makes a cloud.
			_apply_ammo_impact(end)
			if is_instance_valid(target):
				_deal_weapon_damage(target, dps * fire_rate)
		if is_instance_valid(target) and explode_on_hit:
			_spawn_explosion_visual(end, 0.4, color)
	)
	if profile.get("trail", "") == "embers":
		for i in range(3):
			var t := (float(i) + 1.0) / 4.0
			_spawn_flight_mote(start.lerp(end, t), color, radius * 1.6, duration * t)

func _spawn_flight_mote(pos: Vector3, color: Color, size: float, delay: float):
	get_tree().create_timer(delay).timeout.connect(func():
		if not is_inside_tree(): return
		var scene = get_tree().current_scene if get_tree().current_scene != null else get_tree().root
		var mote = MeshInstance3D.new()
		mote.mesh = MunitionPool.unit_sphere()
		mote.scale = Vector3.ONE * size
		mote.material_override = MunitionPool.alpha_emissive(Color(color.r, color.g, color.b, 0.55), color, 0.8)
		scene.add_child(mote)
		mote.global_position = pos
		var mt = mote.create_tween()
		mt.tween_property(mote, "scale", Vector3.ZERO, 0.3)
		mt.finished.connect(func(): if is_instance_valid(mote): mote.queue_free())
	)

# Composite round bodies for the arcing paths: a pivot oriented along its own
# velocity each tick, so a bomb reads nose-forward with a visible tail and a
# rocket reads as a rocket instead of a coloured ball.
func _make_round_body(kind: String, radius: float, colour: Color) -> Node3D:
	var pivot = Node3D.new()
	var body = MeshInstance3D.new()
	body.material_override = MunitionPool.emissive(colour, colour)
	pivot.add_child(body)
	match kind:
		"bomb":
			body.mesh = MunitionPool.unit_sphere()
			body.scale = Vector3.ONE * radius
			var tail = MeshInstance3D.new()
			tail.mesh = MunitionPool.unit_taper(0.25)
			tail.scale = Vector3(radius * 0.7, radius * 1.4, radius * 0.7)
			tail.material_override = MunitionPool.albedo(Color(0.25, 0.23, 0.2))
			pivot.add_child(tail)
			tail.position = Vector3(0, 0, radius * 1.15)
			tail.rotate_x(-PI / 2)
		"rocket":
			body.mesh = MunitionPool.unit_cylinder()
			body.scale = Vector3(radius * 0.5, radius * 2.6, radius * 0.5)
			body.rotate_x(PI / 2)
			var nose = MeshInstance3D.new()
			nose.mesh = MunitionPool.unit_taper(0.0)
			nose.scale = Vector3(radius * 0.5, radius * 0.9, radius * 0.5)
			nose.material_override = MunitionPool.emissive(colour, Color.WHITE, 1.4)
			pivot.add_child(nose)
			nose.position = Vector3(0, 0, -radius * 1.75)
			nose.rotate_x(-PI / 2)
	return pivot

func _fire_railgun_beam():
	var beam = MeshInstance3D.new()
	beam.mesh = MunitionPool.unit_cylinder()
	beam.material_override = MunitionPool.emissive(Color.BLUE_VIOLET, Color.BLUE_VIOLET)
	_effects_parent().add_child(beam)

	var beam_len = MunitionPool.aim_beam(beam, global_position, target.global_position, 0.06)

	for i in range(4):
		var spark = MeshInstance3D.new()
		spark.mesh = MunitionPool.unit_sphere()
		spark.scale = Vector3(0.3, 0.3, 0.3)
		spark.material_override = MunitionPool.emissive(Color.CYAN, Color.CYAN)
		_effects_parent().add_child(spark)

		var pct = randf()
		spark.global_position = global_position.lerp(target.global_position, pct) + Vector3(randf_range(-0.2, 0.2), randf_range(-0.2, 0.2), randf_range(-0.2, 0.2))
		
		var stween = create_tween()
		stween.tween_property(spark, "scale", Vector3.ZERO, 0.1)
		stween.finished.connect(func(): spark.queue_free())
		
	if is_instance_valid(target):
		_deal_weapon_damage(target, dps * fire_rate)
		_spawn_explosion_visual(target.global_position, 0.6, Color.BLUE_VIOLET)

	# Collapses the beam's radius while holding its length - the y component
	# used to be a literal 1.0 because length lived in the mesh; it now lives
	# in scale.y, so it has to be preserved explicitly here.
	var tween = create_tween()
	tween.tween_property(beam, "scale", Vector3(0.0, beam_len, 0.0), 0.15)
	tween.finished.connect(func(): beam.queue_free())

func _fire_artillery():
	var shell = _make_round_body("bomb", 0.4, Color.SADDLE_BROWN)
	_effects_parent().add_child(shell)

	var start = global_position
	var end = target.global_position
	var tween = create_tween()
	var last_pos := [start]
	var puff_mark := [0.0]
	var callable = func(val: float):
		if not is_instance_valid(shell): return
		var current_target = end
		if is_instance_valid(target):
			current_target = target.global_position
		var pos = start.lerp(current_target, val)
		pos.y += sin(val * PI) * 12.0
		shell.global_position = pos
		if val > 0.01:
			var seg: Vector3 = pos - last_pos[0]
			if seg.length_squared() > 0.0001:
				shell.look_at(pos + seg, Vector3.UP)
			last_pos[0] = pos
			shell.rotate_object_local(Vector3(0, 0, 1), 0.18)
		if val > puff_mark[0]:
			puff_mark[0] = val + 0.2
			_spawn_flight_mote(pos + Vector3(0, -0.25, 0), Color(0.62, 0.6, 0.58), 0.35, 0.0)

	tween.tween_method(callable, 0.0, 1.0, 0.8)
	tween.finished.connect(func():
		if is_instance_valid(shell): shell.queue_free()
		_deal_aoe_damage(end, 6.0, dps * fire_rate)
		_spawn_explosion_visual(end, 1.2, Color.ORANGE)
	)

func _fire_mortar_salvo():
	var count = 3
	if has_meta("module_data"):
		var data = get_meta("module_data")
		count = int(data.tweaks.get("tube_count", 2.0))
		
	for i in range(count):
		get_tree().create_timer(i * 0.18).timeout.connect(func():
			if not is_instance_valid(target): return
			var shell = MeshInstance3D.new()
			shell.mesh = MunitionPool.unit_sphere()
			shell.scale = Vector3(0.2, 0.2, 0.2)
			shell.material_override = MunitionPool.emissive(Color.OLIVE, Color.YELLOW)
			_effects_parent().add_child(shell)
			
			var start = global_position
			# SIM. `end` is the AoE centre resolved in the tween's finished
			# handler below, not just where the shell mesh flies - the salvo's
			# spread is the weapon's accuracy, so it decides what gets hit.
			var end = target.global_position + SimRNG.scatter_xz(0.5)
			var tween = create_tween()
			var height = 6.0
			var callable = func(val: float):
				if not is_instance_valid(shell): return
				var pos = start.lerp(end, val)
				pos.y += sin(val * PI) * height
				shell.global_position = pos
				
			tween.tween_method(callable, 0.0, 1.0, 0.6)
			tween.finished.connect(func():
				if is_instance_valid(shell): shell.queue_free()
				_deal_aoe_damage(end, 4.0, (dps * fire_rate) / count)
				_spawn_explosion_visual(end, 0.5, Color.YELLOW)
			)
		)

const WeaponMissileScene = preload("res://scripts/weapon_missile.gd")

# --- Munition velocity -----------------------------------------------------
# Every missile speed in here used to be an absolute units-per-second literal,
# which silently coupled "how fast does this missile fly" to "how far does this
# weapon reach": the cruise missile's deliberately-slow 9 u/s crossed its old
# 42-unit range in 4.7s, and would have taken 19s to cross its new 170.
#
# Speed is now expressed as the time a munition takes to fly its weapon's OWN
# maximum range, which is the quantity that actually matters for feel and the
# one that should stay put when range is retuned. Two things fall out of it for
# free:
#
#   - Retuning a range never quietly changes how long a shot takes to arrive.
#     Every literal below is the weapon's old range divided by its old speed,
#     so flight times are unchanged from before the retune to two decimals.
#   - "Longer barrel = greater velocity and range" (Chris's spec) needs no
#     separate velocity term at all. barrel_length already multiplies
#     fire_range in _ready(); because speed is derived from fire_range, a
#     longer barrel now literally throws the round faster as well as further,
#     and the two stay consistent by construction rather than by two parallel
#     tweak chains that can drift apart.
#
# Relative character between weapons is preserved exactly - the cruise missile
# is still the slowest thing in the roster and the hypervelocity missile still
# arrives roughly 8x quicker for its reach.
func _munition_speed(seconds_to_max_range: float) -> float:
	return maxf(fire_range / maxf(seconds_to_max_range, 0.05), 1.0)

# Spawns a physical guided missile munition.
func _spawn_missile(tgt: Node, dmg: float, seconds_to_max: float, is_top: bool = false, y_offset: float = 0.5) -> void:
	if not is_instance_valid(tgt):
		return
	var missile = Node3D.new()
	missile.set_script(WeaponMissileScene)
	missile.mesh_part = ModuleCatalog.get_missile_mesh(type_id)
	missile.position = global_position + Vector3(0, y_offset, 0)
	missile.is_top_attack = is_top
	missile.speed = _munition_speed(seconds_to_max)
	missile.setup(tgt, self, dmg, damage_class, get_team())
	_effects_parent().add_child(missile)

# Real, interceptable missile (FABLE_REVIEW.md 2.2/2.2) instead of a cosmetic
# tween - see weapon_missile.gd. is_top_attack/target/damage must be set
# before add_child() since _ready() reads them immediately.
func _fire_missile_projectile(is_top_attack: bool):
	_spawn_missile(target, dps * fire_rate, 2.19, is_top_attack, 0.5)

func _fire_swarm_missiles():
	var count = 4
	if has_meta("module_data"):
		var data = get_meta("module_data")
		count = int(data.tweaks.get("grid_size", 4.0))
	count = max(1, count)
	var per_missile_damage = (dps * fire_rate) / count

	for i in range(count):
		get_tree().create_timer(i * 0.08).timeout.connect(func():
			if not is_instance_valid(target): return
			var missile = Node3D.new()
			missile.set_script(WeaponMissileScene)
			missile.mesh_part = ModuleCatalog.get_missile_mesh(type_id)
			# SIM. A weapon_missile is a real interceptable entity in the
			# "missiles" group, not a tweened visual - where it starts changes
			# its flight time and the geometry point defence gets to engage it
			# at, so the launch offset is part of the simulation.
			missile.position = global_position + SimRNG.scatter_xz(0.3) + Vector3(0.0, 0.3, 0.0)
			missile.speed = _munition_speed(1.50) # missile_pod: 30 / 20
			missile.salvo_jitter = 1.2
			missile.setup(target, self, per_missile_damage, damage_class, get_team())
			_effects_parent().add_child(missile)
		)


# --- Roster expansion: indirect fire + missiles -----------------------------

# The distance an arcing shell's authored flight_time/arc_height describe. Set
# to roughly the old mortar/artillery reach, so a mid-range lob looks and feels
# exactly as it did before range was retuned, and only the genuinely long shots
# get the longer, higher trajectory.
const ARC_REFERENCE_DISTANCE: float = 25.0

# A lobbed shell that arcs to a point and detonates. Extracted because the
# tween/AoE pattern was already inlined three times (artillery, mortar salvo,
# grenade launcher) and the spigot mortar plus rocket artillery would have
# made five. Takes the aim offset so a salvo can scatter.
func _fire_arcing_shell_at(shell_radius: float, arc_height: float, colour: Color,
						   blast_radius: float, damage: float, aim_offset: Vector3 = Vector3.ZERO,
						   flight_time: float = 0.8, profile: Dictionary = {}) -> void:
	if not is_instance_valid(target):
		return
	var parent = _effects_parent()
	if parent == null:
		return
	var shell: Node3D
	if profile.has("body"):
		shell = _make_round_body(profile.get("body", "bomb"), shell_radius, colour)
	else:
		var ball = MeshInstance3D.new()
		ball.mesh = MunitionPool.unit_sphere()
		ball.scale = Vector3.ONE * shell_radius
		ball.material_override = MunitionPool.emissive(colour, colour)
		shell = ball
	parent.add_child(shell)

	var start = global_position
	var end = target.global_position + aim_offset

	# Flight time and apex both scale with how far the shell actually has to
	# travel. `flight_time` and `arc_height` are the values for a shot at
	# ARC_REFERENCE_DISTANCE, not for every shot regardless of distance -
	# previously they were absolute, so an artillery round crossed its full
	# range in a flat 0.8s no matter what that range was. Harmless at the old
	# 28-50 unit reaches; at 140 (ModuleCatalog.RANGE_TIERS) a shell would
	# have crossed most of the map in under a second on a visually flat
	# trajectory, which reads as a laser rather than a howitzer.
	#
	# This is also what gives the Operational tier its real weakness. AoE is
	# resolved at `end`, which is locked in at launch (see the tween's
	# finished handler) - so the longer the shot, the further a moving target
	# can walk out of the impact point before it lands. Long-range indirect
	# fire is a weapon for shelling positions and slow formations, not for
	# hitting a scout, and now it plays that way instead of being a perfect
	# instant-delivery sniper at four times its own vision.
	var travel: float = start.distance_to(end)
	var reach_mult: float = maxf(travel / ARC_REFERENCE_DISTANCE, 0.35)
	var scaled_flight: float = flight_time * reach_mult
	var scaled_apex: float = arc_height * 12.0 * reach_mult

	var tween = create_tween()
	var last_pos := [start]
	var puff_mark := [0.0]
	tween.tween_method(func(val: float):
		if not is_instance_valid(shell):
			return
		var pos = start.lerp(end, val)
		pos.y += sin(val * PI) * scaled_apex
		shell.global_position = pos
		if profile.has("body") and val > 0.01:
			var seg: Vector3 = pos - last_pos[0]
			if seg.length_squared() > 0.0001:
				shell.look_at(pos + seg, Vector3.UP)
			last_pos[0] = pos
			if profile.get("tumble", false):
				shell.rotate_object_local(Vector3(0, 0, 1), 0.22)
		if profile.get("trail", "") == "smoke" and val > puff_mark[0]:
			puff_mark[0] = val + 0.16
			_spawn_flight_mote(pos + Vector3(0, -shell_radius * 0.5, 0), Color(0.62, 0.6, 0.58), shell_radius * 0.9, 0.0)
	, 0.0, 1.0, scaled_flight)
	tween.finished.connect(func():
		if is_instance_valid(shell):
			shell.queue_free()
		_deal_aoe_damage(end, blast_radius, damage)
	)

# Spigot mortar: one very large low-velocity bomb, enormous splash, derisory
# range. payload_size scales both the bomb and the crater it leaves.
const SPIGOT_BLAST_RADIUS: float = 5.5

func _fire_spigot_mortar():
	var pay = 1.0
	if has_meta("module_data"):
		pay = float(get_meta("module_data").tweaks.get("payload_size", 1.0))
	_fire_arcing_shell_at(0.5 * pay, 0.55, laser_color, SPIGOT_BLAST_RADIUS * pay,
						  dps * fire_rate, Vector3.ZERO, 1.1, {"body": "bomb", "tumble": true})

# Rocket artillery: the whole rack empties in a couple of seconds, then the
# long fire_rate interval is the reload. Damage is split across the salvo, so
# more rails is NOT more damage - it is the same damage spread wider, which
# is what `dispersion` then controls. Without that split, rail_count would be
# a pure upgrade slider and the spread tweak would be a downside with no
# matching upside.
func _fire_rocket_artillery():
	var rails = 4
	var spread = 1.0
	if has_meta("module_data"):
		var d = get_meta("module_data")
		rails = int(d.tweaks.get("tube_count", 4.0))
		spread = float(d.tweaks.get("dispersion", 1.0))
	rails = maxi(1, rails)
	var per_rocket = (dps * fire_rate) / float(rails)

	for i in range(rails):
		get_tree().create_timer(i * 0.14).timeout.connect(func():
			if not is_instance_valid(self):
				return
			# SIM. This is the dispersion the whole weapon is balanced around -
			# it becomes _fire_arcing_shell_at's aim_offset, which becomes the
			# `end` that _deal_aoe_damage() detonates on.
			var scatter = SimRNG.scatter_xz(1.0) * spread * 1.6
			_fire_arcing_shell_at(0.25, 0.45, laser_color, 2.4 * spread, per_rocket, scatter, 0.7,
				{"body": "rocket", "trail": "smoke"})
		)

# The six guided launchers all resolve through weapon_missile.gd, so they are
# all interceptable by point defence - that is the property that makes a
# missile a different proposition from a gun of the same per-shot number, and
# it is why they are excluded from the anti-materiel rifle's "biggest hit"
# claim rather than competing with it.

# Hypervelocity: beam-riding kinetic darts. Very fast, no warhead, fired as a
# short ripple from however many canisters are fitted.
func _fire_hypervelocity_missile():
	var tubes = 2
	if has_meta("module_data"):
		tubes = int(get_meta("module_data").tweaks.get("tube_count", 2.0))
	tubes = maxi(1, tubes)
	var per_dart = (dps * fire_rate) / float(tubes)
	for i in range(tubes):
		get_tree().create_timer(i * 0.06).timeout.connect(func():
			if not is_instance_valid(self) or not is_instance_valid(target):
				return
			var m = Node3D.new()
			m.set_script(WeaponMissileScene)
			m.mesh_part = ModuleCatalog.get_missile_mesh(type_id)
			# SIM, for the same reason as the swarm launcher above - a real
			# interceptable missile's start point. Written inline rather than
			# via scatter_xz() because the ripple offsets the tubes across the
			# rack only, with no depth component: one draw, not two.
			m.position = global_position + Vector3(SimRNG.randf_range(-0.15, 0.15), 0.35, 0.0)
			# Roughly three times a normal missile. The whole proposition is
			# that point defence has very little time to engage it.
			m.speed = _munition_speed(0.55) # hypervelocity: 26 / 48
			m.setup(target, self, per_dart, damage_class, get_team())
			_effects_parent().add_child(m)
		)

# SAM: air only. Refuses to engage anything that is not flying, which is
# checked here as well as in target selection so it can never be tricked into
# spending a round on a ground target by an unusual acquisition path.
func _fire_sam_launcher():
	if is_instance_valid(target) and _target_is_airborne(target):
		_spawn_missile(target, dps * fire_rate, 1.15, false, 0.5) # sam_launcher: 30 / 26

# Loitering munition: climbs, holds, then dives. Modelled as a top-attack
# missile with a deliberate delay before it starts tracking - the loiter is
# the weapon's cost, paid in time before anything happens.
func _fire_loitering_munition():
	var endurance = 1.0
	if has_meta("module_data"):
		endurance = float(get_meta("module_data").tweaks.get("seeker_size", 1.0))
	var loiter_delay = clampf(0.9 * endurance, 0.3, 2.5)
	var locked = target
	get_tree().create_timer(loiter_delay).timeout.connect(func():
		if is_instance_valid(self) and is_instance_valid(locked):
			_spawn_missile(locked, dps * fire_rate, 2.71, true, 0.6) # loitering_munition: 38 / 14
	)

# Anti-radiation: only engages units that actually carry a sensor module.
# That makes an enemy's radar into a liability, and makes this the one weapon
# whose usefulness is decided by what the OPPONENT chose to build - a
# genuinely different axis from everything else in the roster.
func _fire_anti_radiation_missile():
	if is_instance_valid(target) and _target_carries_sensors(target):
		_spawn_missile(target, dps * fire_rate, 1.55, false, 0.5) # anti_radiation_missile: 34 / 22

# Bunker buster: top-attack, and heavily biased toward structures. Against
# anything that moves it is clumsy and slow; against a building it is the
# best per-shot in the roster.
const BUNKER_BUSTER_STRUCTURE_BONUS: float = 2.1

func _fire_bunker_buster():
	if not is_instance_valid(target):
		return
	var dmg = dps * fire_rate * (BUNKER_BUSTER_STRUCTURE_BONUS if target.is_in_group("buildings") else 1.0)
	_spawn_missile(target, dmg, 1.60, true, 0.5) # bunker_buster: 24 / 15

# Cruise missile: the one point defence exists to eat. Big, slow, and it
# announces itself the whole way in.
func _fire_cruise_missile():
	_spawn_missile(target, dps * fire_rate, 4.67, false, 0.6) # cruise_missile: 42 / 9

# --- Shared predicates ------------------------------------------------------

# "Airborne" for the SAM's purposes. Reads the same flying flags battle_unit
# already maintains rather than inventing a parallel notion of flight.
func _target_is_airborne(t: Node) -> bool:
	if t == null or not is_instance_valid(t):
		return false
	if "is_flying" in t and t.is_flying:
		return true
	if t.is_in_group("air_units"):
		return true
	# Fallback for test harnesses and anything without the flag: treat a
	# target sitting well clear of the ground as airborne.
	if t is Node3D:
		return (t as Node3D).global_position.y > 3.0
	return false

# Does this target carry anything that emits? Walks its module children for a
# sensor/radar module, which is exactly the thing the missile homes on.
const SENSOR_MODULE_IDS := [
	"sensor_suite", "heavy_sensor_suite", "directional_radar",
	"ciws", "sam_launcher", "microwave_emitter"
]

func _target_carries_sensors(t: Node) -> bool:
	if t == null or not is_instance_valid(t):
		return false
	for child in t.get_children():
		if not child.has_meta("module_data"):
			continue
		var d = child.get_meta("module_data")
		if d and ("type_id" in d) and d.type_id in SENSOR_MODULE_IDS:
			return true
	return false


# --- Roster expansion: point defense, deployables ---------------------------

# AA autocannon: a real gun that happens to prefer aircraft. Fires a flak
# burst that damages air targets in a small radius, so near misses still
# count - which is what makes it useful against something fast.
const AA_FLAK_RADIUS: float = 2.8

func _fire_aa_autocannon():
	_fire_kinetic_projectile(0.035, 0.40, 0.10, laser_color, true)
	if is_instance_valid(target) and _target_is_airborne(target):
		_deal_aoe_damage(target.global_position, AA_FLAK_RADIUS, dps * fire_rate)

# Sensor beacon: lobs a beacon that reveals fog where it lands. Reuses
# skirmish.reveal_area(), the same beacon system illumination ammo uses.
const BEACON_REVEAL_RADIUS: float = 9.0
const BEACON_REVEAL_DURATION: float = 18.0
# The single beacon's sensor bubble is 9m. The launcher's *firing* range
# (how far it can lob a beacon into unexplored territory) is much further:
# ~11x that, so a launcher can paint fog across a real chunk of map instead
# of just over the next berm. The previous fire_range*0.75 (~34m) was the
# reason the launcher appeared to never fire at all in testing - in any map
# with a fog line further than that, every probe landed on explored ground.
const BEACON_SCAN_RANGE: float = 100.0
# Probe at three distances per direction so we don't miss fog that falls
# between the near ring and the far ring. Closest-first, so the beacon
# lands on the nearest unexplored tile we can reach.
const BEACON_SCAN_DISTANCES: Array[float] = [40.0, 70.0, 100.0]

# DEPLOYABLE_MODULES_OVERHAUL.md §3: when idle, the sensor beacon launcher
# scans 8 radial directions for unexplored fog and fires a beacon to reveal it.
func _scan_fog_and_fire_beacon(delta: float):
	_fog_scan_timer -= delta
	if _fog_scan_timer > 0.0:
		return
	_fog_scan_timer = FOG_SCAN_INTERVAL

	var scene = get_tree().current_scene
	if scene == null or not scene.has_method("cell_explored"):
		return

	var my_team = get_team()
	var directions := [
		Vector3(0, 0, -1), Vector3(0, 0, 1), Vector3(-1, 0, 0), Vector3(1, 0, 0),
		(Vector3(0, 0, -1) + Vector3(1, 0, 0)).normalized(),
		(Vector3(0, 0, -1) + Vector3(-1, 0, 0)).normalized(),
		(Vector3(0, 0, 1) + Vector3(1, 0, 0)).normalized(),
		(Vector3(0, 0, 1) + Vector3(-1, 0, 0)).normalized(),
	]

	for d in directions:
		var world_dir: Vector3 = (global_transform.basis * d).normalized()
		for dist in BEACON_SCAN_DISTANCES:
			var probe_pos: Vector3 = global_position + world_dir * dist
			probe_pos.y = global_position.y  # same elevation

			# cell_explored is team-aware — returns false for cells the team
			# has never seen, which is exactly "fog of war".
			if not scene.cell_explored(probe_pos.x, probe_pos.z):
				# Found unexplored fog. Fire a beacon to this point.
				_fire_sensor_beacon_toward(probe_pos)
				return   # one beacon per scan tick; throttle handles repetition

# Fires a sensor beacon toward an arbitrary world point (used by fog scan).
func _fire_sensor_beacon_toward(fog_point: Vector3):
	var parent = _effects_parent()
	if parent == null:
		return
	# Place the beacon slightly above the target so it lands on the ground.
	var aim = fog_point + Vector3(0.0, 0.5, 0.0)
	var beacon = MeshInstance3D.new()
	beacon.mesh = MunitionPool.unit_sphere()
	beacon.material_override = MunitionPool.emissive(laser_color, laser_color, 1.2)
	beacon.scale = Vector3.ONE * 0.18
	parent.add_child(beacon)
	var start = global_position
	var tween = create_tween()
	tween.tween_method(func(v: float):
		if not is_instance_valid(beacon):
			return
		var pos = start.lerp(aim, v)
		pos.y += sin(v * PI) * 5.0
		beacon.global_position = pos
	, 0.0, 1.0, 0.9)
	var team = get_team()
	tween.finished.connect(func():
		if is_instance_valid(beacon):
			beacon.queue_free()
		var sk = get_tree().current_scene
		if sk and sk.has_method("reveal_area"):
			sk.reveal_area(team, aim, BEACON_REVEAL_RADIUS, BEACON_REVEAL_DURATION)
	)

func _fire_sensor_beacon_launcher():
	var aim = target.global_position if is_instance_valid(target) else \
		global_position - global_transform.basis.z.normalized() * fire_range
	# One line per beacon, with the unit name and aim point. Pairs with
	# the deployable-modules investigation: the launcher's firing cadence
	# and the per-tick fog scan it now owns (see _scan_fog_and_fire_beacon)
	# are the kind of thing a stutter report needs to see.
	var _carrier_name := String(get_parent().name) if get_parent() != null else "?"
	BattleLogger.beacon_fired(_carrier_name, aim)
	_fire_sensor_beacon_toward(aim)

func _fire_drone_swarm():
	# Real autonomous drones (drone_unit.gd), not tweened throwaway meshes -
	# see ENERGY_AND_BALANCE_SPEC.md #3. Count driven by the "Hangar Size"
	# tweak (previously documented in Arsenal_Weapons_List.md but missing
	# from TWEAK_SPECS entirely).
	var count = 2
	var drone_type = "attack"
	var drone_speed = 14.0
	if has_meta("module_data"):
		var data = get_meta("module_data")
		count = int(data.tweaks.get("hangar_size", 2.0))
		drone_type = data.tweaks.get("drone_type", "attack")
		var profile = ModuleCatalog.get_drone_profile(drone_type)
		drone_speed = profile.get("speed", 14.0)
	count = max(1, count)
	var per_drone_damage = (dps * fire_rate) / count
	var my_team = get_team()
	var vehicle_root = get_vehicle_root()
	var carrier = vehicle_root if is_instance_valid(vehicle_root) else self

	# For repair drones the carrier weapon targets damaged allies so the
	# swarm launches toward useful repair candidates rather than enemies.
	if drone_type == "repair":
		targets_allies = true

	# Lifecycle log line: one per drone launch, with the carrier's name
	# and the type (attack / scout / repair). Lets a playtest report
	# correlate "X drones were in the air when the stutter hit" with
	# the actual spawn events rather than a count derived from
	# the "missiles" group at a later frame.
	BattleLogger.drone_launched(
		String(carrier.name) if is_instance_valid(carrier) else "?", drone_type, count)

	for i in range(count):
		var drone = Node3D.new()
		drone.set_script(load("res://scripts/drone_unit.gd"))
		_effects_parent().add_child(drone)
		# SIM. A drone_unit is an autonomous entity that flies, engages and can
		# be shot down - its launch position is world state, not decoration.
		drone.global_position = global_position + SimRNG.scatter_xz(0.5) + Vector3(0.0, 1.0, 0.0)
		drone.carrier = carrier
		drone.target = target
		drone.drone_type = drone_type
		drone.speed = drone_speed
		drone.damage_per_hit = per_drone_damage
		drone.damage_class = damage_class
		drone.team = my_team

func _fire_cluster_dispenser():
	# Housing recoil animation
	for c in get_children():
		if c is MeshInstance3D:
			var orig_pos = c.position
			var rec_tween = create_tween()
			rec_tween.tween_property(c, "position", orig_pos + Vector3(0, 0, 0.08), 0.05)
			rec_tween.tween_property(c, "position", orig_pos, 0.15)
			break

	var dispersion = 1.0
	var payload_size = 1.0
	var t_count = 2
	if has_meta("module_data"):
		var data = get_meta("module_data")
		dispersion = data.tweaks.get("dispersion", 1.0)
		payload_size = data.tweaks.get("payload_size", 1.0)
		t_count = int(data.tweaks.get("tube_count", 2.0))

	var submunitions_per_canister = 3
	var total_bomblets = t_count * submunitions_per_canister
	var per_bomblet_damage = (dps * fire_rate) / float(total_bomblets)
	var scatter_radius = 3.0 * dispersion

	for c_idx in range(t_count):
		get_tree().create_timer(c_idx * 0.10).timeout.connect(func():
			if not is_instance_valid(target): return
			var canister = MeshInstance3D.new()
			var can_scene = load("res://assets/models/parts/cluster_dispenser_canister.glb")
			if can_scene:
				var inst = can_scene.instantiate()
				for child in inst.get_children():
					if child is MeshInstance3D:
						canister.mesh = child.mesh
						break
			else:
				# Left un-pooled deliberately: this is the
				# authored-mesh-missing fallback, so it fires at most once per
				# canister on a broken install, not on the hot path.
				var box = BoxMesh.new()
				box.size = Vector3(0.12 * payload_size, 0.12 * payload_size, 0.24 * payload_size)
				canister.mesh = box
			canister.material_override = MunitionPool.emissive(Color(0.70, 0.40, 0.20), Color.ORANGE_RED)
			_effects_parent().add_child(canister)

			# COSMETIC, and this one is worth being explicit about because it
			# sits three lines from a SIM draw in the same function. `start`
			# only ever feeds the canister MESH's tween and the `mid` point the
			# bomblet meshes are released from; the damage is resolved at
			# `scatter_dest` below, which is computed from `end` and never from
			# `start`. Moving the canister's muzzle jitter cannot move a hit.
			var start = global_position + Vector3(randf_range(-0.1, 0.1), 0.3, randf_range(-0.1, 0.1))
			var end = target.global_position
			canister.global_position = start
			canister.scale = Vector3(payload_size, payload_size, payload_size)
			canister.look_at(end, Vector3.UP)

			var mid = start.lerp(end, 0.4) + Vector3(0, 1.5, 0)
			var tween = create_tween()
			tween.tween_property(canister, "global_position", mid, 0.25)
			tween.finished.connect(func():
				if is_instance_valid(canister): canister.queue_free()

				for i in range(submunitions_per_canister):
					var sub = MeshInstance3D.new()
					sub.mesh = MunitionPool.unit_sphere()
					sub.scale = Vector3.ONE * (0.12 * payload_size)
					sub.material_override = MunitionPool.emissive(Color.CHOCOLATE, Color.ORANGE)
					_effects_parent().add_child(sub)
					sub.global_position = mid

					# SIM. Each bomblet's own impact point - _deal_aoe_damage()
					# detonates on exactly this vector two lines below, so the
					# dispersion tweak's spread IS the weapon's damage pattern.
					var scatter_dest = end + SimRNG.scatter_xz(scatter_radius)
					var st = create_tween()
					st.tween_property(sub, "global_position", scatter_dest, 0.2)
					st.finished.connect(func():
						if is_instance_valid(sub): sub.queue_free()
						_deal_aoe_damage(scatter_dest, 2.5 * payload_size, per_bomblet_damage)
						_spawn_explosion_visual(scatter_dest, 0.3 * payload_size, Color.CHOCOLATE)
					)
			)
		)

# Persistent flamethrower jet + its smoke, created lazily on the first shot
# and reused for the life of the weapon (see _fire_flame_spray).
var _flame_jet: GPUParticles3D = null
var _flame_smoke: GPUParticles3D = null
var _flame_last_fired_at: int = 0

# A continuous emitter has to be told when to stop. The weapon fires in
# discrete shots, so "still firing" is defined as "fired recently" - the
# cutoff is generously longer than one shot interval so a jet doesn't
# stutter between shots at any fire_rate, but short enough that it dies
# promptly when the target does.
const FLAME_JET_CUTOFF_MS: int = 220

# --- Attack-ground (fire on a position, not a unit) ----------------------
#
# Implemented as a FORCED TARGET pointing at an invisible marker node, rather
# than as a parallel "aim at a Vector3" path through every _fire_* function.
# There are 20-odd firing routines in this file and they all reach for
# `target.global_position`; giving them a real Node3D to aim at means every
# weapon type supports attack-ground for free, including the lobbed and
# guided ones, with no per-weapon work.
#
# The marker deliberately has no take_damage() and is in no group, so
# _deal_weapon_damage() no-ops against it (see its guard) while
# _deal_aoe_damage()/_apply_ammo_impact(), which work off a POSITION, still
# land normally. That is exactly the semantics attack-ground should have:
# shells burst where you aimed and hurt whatever is actually there, and
# nothing takes a direct hit just for being the thing you pointed at.
var _forced_target: Node3D = null
var _forced_target_until: int = 0

# Weapons that lay an obscurant rather than trying to hurt anything, and so
# are excluded from auto-acquisition entirely (see _find_nearest_target).
# A gun loaded with smoke AMMO is not in here - that is a normal weapon
# making a normal engagement decision that happens to deliver smoke; this is
# about the dedicated launcher whose only job is screening.
const OBSCURANT_TYPES := ["smoke_discharger"]

# Automatic self-screen: put a cloud between me and whatever is shooting.
#
# `threat_pos` is where the fire came from (unit.gd passes
# take_damage's hit_origin). The screen goes on the line toward it rather
# than on top of it - a screen you hide behind has to be between you and the
# observer, and smoke blocks line of sight BOTH ways (it is checked by
# _is_los_blocked_to, skirmish's fog, and missile guidance alike), so
# dropping it directly on the enemy would blind you as much as them.
func request_screen(threat_pos: Vector3) -> void:
	if not (type_id in OBSCURANT_TYPES):
		return
	if _has_forced_target():
		return # already screening; don't stack requests
	var host = _effects_parent()
	if host == null:
		return
	var here = global_position
	var toward = threat_pos - here
	toward.y = 0.0
	if toward.length() < 0.5:
		return
	var screen_pos = here + toward.normalized() * (toward.length() * SMOKE_SCREEN_STANDOFF)
	screen_pos.y = threat_pos.y
	var marker = Node3D.new()
	marker.name = "SmokeScreenPoint"
	host.add_child(marker)
	marker.global_position = screen_pos
	set_forced_target(marker)
	get_tree().create_timer(10.0).timeout.connect(func():
		if is_instance_valid(marker):
			marker.queue_free())

# How long a ground order holds before the weapon reverts to auto-acquisition.
# Long enough to be a real order rather than one shot, short enough that a
# unit doesn't keep shelling an empty field forever after the fight moves on.
const FORCED_TARGET_DURATION_MS: int = 8000

func set_forced_target(marker: Node3D) -> void:
	_forced_target = marker
	_forced_target_until = Time.get_ticks_msec() + FORCED_TARGET_DURATION_MS
	target = marker

func clear_forced_target() -> void:
	_forced_target = null
	_forced_target_until = 0
	if target != null and not is_instance_valid(target):
		target = null

func _has_forced_target() -> bool:
	if _forced_target == null:
		return false
	if not is_instance_valid(_forced_target) or Time.get_ticks_msec() > _forced_target_until:
		clear_forced_target()
		return false
	return true

func _update_flame_jet() -> void:
	if not is_instance_valid(_flame_jet):
		return
	if _flame_jet.emitting and Time.get_ticks_msec() - _flame_last_fired_at > FLAME_JET_CUTOFF_MS:
		_flame_jet.emitting = false
		if is_instance_valid(_flame_smoke):
			_flame_smoke.emitting = false

func _fire_flame_spray():
	var n_width = 1.0
	var p_valve = 1.0
	if has_meta("module_data"):
		var data = get_meta("module_data")
		n_width = data.tweaks.get("nozzle_width", 1.0)
		p_valve = data.tweaks.get("pressure_valve", 1.0)

	# Body/Nozzle recoil vibration
	for c in get_children():
		if c is MeshInstance3D:
			var orig_pos = c.position
			var rec_tween = create_tween()
			rec_tween.tween_property(c, "position", orig_pos + Vector3(0, 0, 0.04 * p_valve), 0.04)
			rec_tween.tween_property(c, "position", orig_pos, 0.12)
			break

	# ONE persistent GPU-particle jet, created on the first shot and only
	# switched on thereafter (see scripts/vfx_effects.gd).
	#
	# This used to allocate SIX MeshInstance3D spheres and SIX Tweens per
	# shot. At the flamethrower's fire_rate that is roughly 100 nodes and 100
	# tweens created and destroyed every second, per weapon, all on the main
	# thread - and six shaded spheres flying in formation never read as fire
	# anyway, because fire has no surface. The jet now costs one draw call
	# and allocates nothing per shot.
	#
	# The jet is aimed by the weapon's own transform (it emits along local
	# -Z, the same axis the barrel points), so it tracks turret traverse for
	# free instead of being re-aimed at target.global_position per shot.
	if not is_instance_valid(_flame_jet):
		var reach = fire_range if fire_range > 0.0 else 8.0
		_flame_jet = VFXEffects.make_flame_emitter(self, reach, n_width)
		_flame_smoke = VFXEffects.make_flame_smoke_emitter(self, reach)
	_flame_jet.emitting = true
	if is_instance_valid(_flame_smoke):
		_flame_smoke.emitting = true
	# _physics_process shuts the jet off once firing stops; a continuous
	# emitter has no natural end the way a per-shot tween did.
	_flame_last_fired_at = Time.get_ticks_msec()

	# Damage timing is preserved EXACTLY as it was: one application per shot,
	# delayed by the same flight duration the old tween used, guarded by the
	# same is_instance_valid(target) check. Only the visual changed here, so
	# flamethrower DPS and its feel in combat are untouched.
	var flight_dur = 0.35 * p_valve
	var victim = target
	get_tree().create_timer(flight_dur).timeout.connect(func():
		if is_instance_valid(self) and is_instance_valid(victim):
			_deal_weapon_damage(victim, dps * fire_rate))

func _fire_continuous_beam():
	var beam = MeshInstance3D.new()
	beam.mesh = MunitionPool.unit_cylinder()
	beam.material_override = MunitionPool.emissive(laser_color, laser_color)
	_effects_parent().add_child(beam)

	MunitionPool.aim_beam(beam, global_position, target.global_position, 0.08)

	if is_instance_valid(target):
		_deal_weapon_damage(target, dps * fire_rate)

	var timer = get_tree().create_timer(0.06)
	timer.timeout.connect(func(): if is_instance_valid(beam): beam.queue_free())

func _fire_plasma_lobber():
	var plasma = MeshInstance3D.new()
	plasma.mesh = MunitionPool.unit_sphere()
	plasma.scale = Vector3(0.35, 0.35, 0.35)
	plasma.material_override = MunitionPool.emissive(Color.MEDIUM_SPRING_GREEN, Color.MEDIUM_SPRING_GREEN)
	_effects_parent().add_child(plasma)
	
	var start = global_position
	var end = target.global_position
	var tween = create_tween()
	var callable = func(val: float):
		if not is_instance_valid(plasma): return
		var pos = start.lerp(end, val)
		pos.y += sin(val * PI) * 4.0
		plasma.global_position = pos
		
	tween.tween_method(callable, 0.0, 1.0, 0.6)
	tween.finished.connect(func():
		if is_instance_valid(plasma): plasma.queue_free()
		_deal_aoe_damage(end, 4.5, dps * fire_rate)
		_spawn_explosion_visual(end, 0.8, Color.MEDIUM_SPRING_GREEN)

		var puddle = MeshInstance3D.new()
		puddle.mesh = MunitionPool.unit_cylinder()
		puddle.scale = Vector3(2.0, 0.05, 2.0)
		puddle.material_override = MunitionPool.alpha_emissive(
			Color(0.1, 0.8, 0.2, 0.4), Color.MEDIUM_SPRING_GREEN)
		_effects_parent().add_child(puddle)
		puddle.global_position = end

		var pt = create_tween()
		pt.tween_property(puddle, "scale", Vector3.ZERO, 1.5)
		pt.finished.connect(func(): puddle.queue_free())
	)

func _fire_flak_cannon():
	var shell = MeshInstance3D.new()
	shell.mesh = MunitionPool.unit_sphere()
	shell.scale = Vector3(0.18, 0.18, 0.18)
	shell.material_override = MunitionPool.emissive(Color.DARK_GOLDENROD, Color.GOLD)
	_effects_parent().add_child(shell)
	
	var start = global_position
	var end = target.global_position
	var detonate_pos = start.lerp(end, 0.85)
	
	var tween = create_tween()
	tween.tween_property(shell, "global_position", detonate_pos, 0.22)
	tween.finished.connect(func():
		if is_instance_valid(shell): shell.queue_free()
		
		var smoke = MeshInstance3D.new()
		smoke.mesh = MunitionPool.unit_sphere()
		smoke.scale = Vector3(1.6, 1.6, 1.6)
		smoke.material_override = MunitionPool.alpha(Color(0.15, 0.15, 0.15, 0.7))
		_effects_parent().add_child(smoke)
		smoke.global_position = detonate_pos
		
		var st = create_tween()
		st.tween_property(smoke, "scale", Vector3.ZERO, 0.4)
		st.finished.connect(func(): smoke.queue_free())

		_deal_aoe_damage(detonate_pos, 5.0, dps * fire_rate)
	)

# --- Roster expansion fire functions ---------------------------------------

# MK19: a low, fast arc with a small blast on arrival. Deliberately a
# shallower lob and a much tighter blast than mortar_array - it's a
# direct-lay weapon that happens to arc, not indirect fire.
func _fire_grenade_launcher():
	var grenade = MeshInstance3D.new()
	grenade.mesh = MunitionPool.unit_sphere()
	grenade.scale = Vector3(0.16, 0.16, 0.16)
	grenade.material_override = MunitionPool.emissive(Color(0.35, 0.38, 0.22), Color(0.7, 0.65, 0.2))
	var parent = _effects_parent()
	if parent == null: return
	parent.add_child(grenade)

	var start = global_position + Vector3(0, 0.35, 0)
	var end = target.global_position
	var tween = create_tween()
	var callable = func(val: float):
		if not is_instance_valid(grenade): return
		var pos = start.lerp(end, val)
		pos.y += sin(val * PI) * 1.8 # shallow arc
		grenade.global_position = pos
	tween.tween_method(callable, 0.0, 1.0, 0.35)
	tween.finished.connect(func():
		if is_instance_valid(grenade): grenade.queue_free()
		_deal_aoe_damage(end, 2.2, dps * fire_rate)
		_spawn_explosion_visual(end, 0.35, Color(0.9, 0.7, 0.2))
	)

# Recoilless rifle. The backblast is the point: a real recoilless weapon
# vents its propellant gases rearward hard enough to be lethal behind the
# tube, and this is the first weapon in the roster where WHERE it's mounted
# has a mechanical consequence rather than just an arc one. Mount one
# facing into your own hull and the danger zone lands on your own machine.
const MUZZLE_STANDOFF: float = 1.1
# Deployed bipod: a big reach bonus that costs the ability to shoot on the
# move. See _bipod_blocks_firing() for the other half of the trade.
const BIPOD_RANGE_BONUS: float = WeaponRange.BIPOD_RANGE_BONUS
const BIPOD_MOVING_SPEED: float = 0.35

const BACKBLAST_RANGE: float = 4.5
const BACKBLAST_DAMAGE_FRACTION: float = 0.45

func _fire_recoilless_rifle():
	var parent = _effects_parent()
	if parent == null: return

	# Forward: a single heavy HEAT round.
	_fire_kinetic_projectile(0.06, 0.55, 0.16, laser_color, true)

	# Rearward: the backblast cone. Damages ANYTHING in it, friend or foe -
	# the one deliberate exception to the hostiles-only rule every other
	# weapon in this file follows, because a backblast that politely spared
	# your own units would defeat the entire reason the weapon is
	# interesting. Own vehicle included.
	var back_dir = global_transform.basis.z.normalized() # +Z is behind a -Z-facing weapon
	var blast_origin = global_position + back_dir * 0.5
	var blast_damage = dps * fire_rate * BACKBLAST_DAMAGE_FRACTION

	for c in get_tree().get_nodes_in_group("damageable"):
		if not is_instance_valid(c) or not c.has_method("take_damage"):
			continue
		if "is_dead" in c and c.is_dead:
			continue
		var to_c = c.global_position - blast_origin
		var dist = to_c.length()
		if dist > BACKBLAST_RANGE or dist < 0.01:
			continue
		# Roughly a 60-degree cone directly behind the tube.
		if back_dir.dot(to_c.normalized()) < 0.5:
			continue
		c.take_damage(blast_damage * (1.0 - dist / BACKBLAST_RANGE), "thermal", blast_origin)

	# Visual: a short cone of exhaust out the back.
	for i in range(5):
		var puff = MeshInstance3D.new()
		puff.mesh = MunitionPool.unit_sphere()
		puff.material_override = MunitionPool.alpha(Color(0.75, 0.72, 0.66, 0.55))
		parent.add_child(puff)
		var t = float(i) / 4.0
		puff.global_position = blast_origin + back_dir * (t * BACKBLAST_RANGE * 0.7) \
			+ Vector3(randf_range(-0.3, 0.3), randf_range(-0.2, 0.3), randf_range(-0.3, 0.3))
		puff.scale = Vector3.ONE * (0.3 + t * 0.9)
		var pt = create_tween()
		pt.tween_property(puff, "scale", Vector3.ZERO, 0.3 + t * 0.2)
		pt.finished.connect(func(): if is_instance_valid(puff): puff.queue_free())

# Anti-materiel rifle: one very large, very fast round, and a lot of noise
# about it. The visual has to sell "precision, expensive, slow to repeat" -
# a tight bright tracer, a sharp muzzle flash with a real brake blast
# signature to either side, and a dust ring kicked up under the muzzle. No
# splash: this weapon's whole proposition is that it puts everything into
# one impact point.
func _fire_anti_materiel_rifle():
	var parent = _effects_parent()
	if parent == null: return

	_fire_kinetic_projectile(0.045, 0.85, 0.10, laser_color, false)

	var muzzle_forward = -global_transform.basis.z.normalized()
	var muzzle_right = global_transform.basis.x.normalized()
	var muzzle_pos = global_position + muzzle_forward * MUZZLE_STANDOFF

	# Brake blast: two side jets, which is exactly what a big muzzle
	# brake does and what makes it read as one at a glance.
	for side in [-1.0, 1.0]:
		var brake_pos = muzzle_pos + muzzle_right * side * 0.22
		VFXEffects.muzzle_flash(parent, brake_pos, muzzle_right * side, 1.5, Color(1.0, 0.86, 0.55))

	# Dust ring under the muzzle - the tell that something very large just
	# went off close to the ground.
	for i in range(6):
		var dust = MeshInstance3D.new()
		dust.mesh = MunitionPool.unit_sphere()
		dust.material_override = MunitionPool.alpha(Color(0.62, 0.58, 0.50, 0.42))
		parent.add_child(dust)
		var a = (float(i) / 6.0) * TAU
		dust.global_position = muzzle_pos + Vector3(cos(a) * 0.45, -0.35, sin(a) * 0.45)
		dust.scale = Vector3.ONE * 0.22
		var dt = create_tween()
		dt.tween_property(dust, "scale", Vector3.ONE * 0.55, 0.35)
		dt.parallel().tween_property(dust, "position", dust.position + Vector3(cos(a) * 0.5, 0.1, sin(a) * 0.5), 0.35)
		dt.finished.connect(func(): if is_instance_valid(dust): dust.queue_free())

# Coil gun: a hitscan slug, visually staged - a chain of accelerator
# flashes runs up the barrel before the slug leaves, so it reads as
# "magnetically staged" rather than as a laser.
func _fire_coil_gun():
	var parent = _effects_parent()
	if parent == null: return

	var muzzle_forward = -global_transform.basis.z.normalized()
	for i in range(4):
		var ring = MeshInstance3D.new()
		ring.mesh = MunitionPool.unit_sphere()
		ring.scale = Vector3(0.18, 0.18, 0.18)
		ring.material_override = MunitionPool.emissive(laser_color, laser_color, 1.6)
		parent.add_child(ring)
		ring.global_position = global_position + muzzle_forward * (0.3 + i * 0.45)
		var rt = create_tween()
		rt.tween_interval(i * 0.015)
		rt.tween_property(ring, "scale", Vector3.ZERO, 0.09)
		rt.finished.connect(func(): if is_instance_valid(ring): ring.queue_free())

	var beam = MeshInstance3D.new()
	beam.mesh = MunitionPool.unit_cylinder()
	beam.material_override = MunitionPool.emissive(laser_color, Color.WHITE, 1.4)
	parent.add_child(beam)
	var beam_len = MunitionPool.aim_beam(beam, global_position, target.global_position, 0.05)

	if is_instance_valid(target):
		_apply_ammo_impact(target.global_position)
		_deal_weapon_damage(target, dps * fire_rate)
		_spawn_explosion_visual(target.global_position, 0.4, laser_color)

	var tween = create_tween()
	tween.tween_property(beam, "scale", Vector3(0.0, beam_len, 0.0), 0.12)
	tween.finished.connect(func(): if is_instance_valid(beam): beam.queue_free())

# Napalm mortar: a high lob that leaves a large, long-lived burn pool.
# Reuses the incendiary-ammo pool wholesale rather than growing a parallel
# fire system - this weapon simply always does what incendiary ammo does,
# and does it bigger.
func _fire_napalm_mortar():
	var parent = _effects_parent()
	if parent == null: return
	var canister = MeshInstance3D.new()
	canister.mesh = MunitionPool.unit_sphere()
	canister.scale = Vector3(0.3, 0.3, 0.3)
	canister.material_override = MunitionPool.emissive(Color(0.85, 0.4, 0.1), Color(1.0, 0.55, 0.1))
	parent.add_child(canister)

	var start = global_position
	var end = target.global_position
	var tween = create_tween()
	var callable = func(val: float):
		if not is_instance_valid(canister): return
		var pos = start.lerp(end, val)
		pos.y += sin(val * PI) * 7.0
		canister.global_position = pos
	tween.tween_method(callable, 0.0, 1.0, 0.7)
	for i in range(3):
		var t := (float(i) + 1.0) / 4.0
		_spawn_flight_mote(start.lerp(end, t) + Vector3(0, sin(t * PI) * 7.0 - 0.2, 0), Color(1.0, 0.5, 0.15), 0.28, 0.7 * t)
	tween.finished.connect(func():
		if is_instance_valid(canister): canister.queue_free()
		_deal_aoe_damage(end, 4.0, dps * fire_rate)
		_spawn_explosion_visual(end, 0.9, Color(1.0, 0.5, 0.1))
		# Bigger and longer than an incendiary shell's pool - this is the
		# weapon's entire identity, not a side effect.
		_spawn_burn_pool(end, 1.7, 2.2)
	)

# Mine layer: lobs a proximity mine a short way out and leaves it. The mine
# is a real, persistent world entity that outlives its layer - see
# proximity_mine.gd.
const ProximityMine = preload("res://scripts/proximity_mine.gd")

func _fire_mine_layer():
	var parent = _effects_parent()
	if parent == null: return
	var count = 1
	if has_meta("module_data"):
		count = int(get_meta("module_data").tweaks.get("tube_count", 1.0))
	count = clamp(count, 1, 4)
	var per_mine_damage = (dps * fire_rate) * 1.6 / float(count)

	# Mines are laid toward the threat but well short of it - this is
	# area denial in front of your own position, not a thrown bomb.
	var aim = target.global_position if is_instance_valid(target) else (global_position - global_transform.basis.z * fire_range)
	var drop = global_position.lerp(aim, 0.45)

	# One log line per drop so the post-mortem can correlate a frame
	# where many mines landed (e.g. a layered minefield) with any
	# hitch. Carrier name comes from get_vehicle_root() so it is the
	# unit name, not the per-mount weapon node.
	var _carrier := get_vehicle_root()
	BattleLogger.mine_dropped(
		String(_carrier.name) if is_instance_valid(_carrier) else "?", drop)

	for i in range(count):
		# SIM. A proximity mine is a persistent world entity that outlives its
		# layer and detonates on whatever drives over it - where it comes to
		# rest is the minefield's actual coverage.
		var scatter = SimRNG.scatter_xz(1.6)
		var dest = drop + scatter
		dest.y = drop.y

		var casing = MeshInstance3D.new()
		casing.mesh = MunitionPool.unit_cylinder()
		casing.scale = Vector3(0.3, 0.1, 0.3)
		casing.material_override = MunitionPool.albedo(Color(0.35, 0.33, 0.22))
		parent.add_child(casing)
		casing.global_position = global_position + Vector3(0, 0.3, 0)

		var start = casing.global_position
		var tween = create_tween()
		var callable = func(val: float):
			if not is_instance_valid(casing): return
			var pos = start.lerp(dest, val)
			pos.y += sin(val * PI) * 1.5
			casing.global_position = pos
		tween.tween_method(callable, 0.0, 1.0, 0.4)
		tween.finished.connect(func():
			if is_instance_valid(casing): casing.queue_free()
			ProximityMine.spawn(parent, dest, get_team(), per_mine_damage, damage_class)
		)

# Ballista: one enormous bolt, slowly. Visually a real flying bolt rather
# than a tracer streak, because at this cycle rate the player will watch
# every single shot travel.
# The dedicated obscurant launcher. Lobs a canister short of the target
# rather than at it: a screen is only useful BETWEEN you and them, so
# putting the cloud on top of the enemy would defeat the entire purpose.
# 0.5 = midway between unit and threat (DEPLOYABLE_MODULES_OVERHAUL.md §2).
# 1.0 = player-triggered forced-target case; the aim point is already chosen.
const SMOKE_SCREEN_STANDOFF: float = 0.5

func _fire_smoke_discharger():
	# More tubes lay a wider screen. This is also why tube_count lengthens
	# the reload (auto_weapon's existing tube_count fire_rate modifier) -
	# a bigger screen takes longer to reload for, same tradeoff the mortar
	# array already makes.
	var tube_count = 4.0
	if has_meta("module_data"):
		tube_count = get_meta("module_data").tweaks.get("tube_count", 4.0)
	var spread_mult = sqrt(max(tube_count, 1.0) / 4.0)

	# Lifecycle log line. _try_emergency_smoke() in unit.gd also calls
	# this for the auto-pop at <10% HP, so the count covers BOTH the
	# player-triggered discharge and the unit's defensive pop - useful
	# when smoke volume dominates the renderer's batched draw list.
	var _smoke_carrier := get_vehicle_root()
	var _smoke_carrier_name := String(_smoke_carrier.name) if is_instance_valid(_smoke_carrier) else "?"
	var _smoke_hp_pct: float = 0.0
	if is_instance_valid(_smoke_carrier) and "hp" in _smoke_carrier and "max_hp" in _smoke_carrier \
			and _smoke_carrier.max_hp > 0.0:
		_smoke_hp_pct = float(_smoke_carrier.hp) / float(_smoke_carrier.max_hp) * 100.0
	BattleLogger.smoke_popped(_smoke_carrier_name, _smoke_hp_pct)

	var start = global_position + Vector3(0, 0.4, 0)
	var aim = target.global_position if is_instance_valid(target) else (start - global_transform.basis.z * fire_range)
	# The 70% standoff exists to convert "an enemy is over there" into "put
	# the screen between us". When the aim point is already a deliberate
	# ground target - a player's ctrl+right-click, or request_screen()'s
	# pre-computed screen position - it has ALREADY been chosen as where the
	# cloud should sit, and lerping toward it again would land the screen
	# short of the spot that was picked.
	var standoff := 1.0 if _has_forced_target() else SMOKE_SCREEN_STANDOFF
	var end = start.lerp(aim, standoff)
	end.y = aim.y

	var canister = MeshInstance3D.new()
	canister.mesh = MunitionPool.unit_cylinder()
	canister.scale = Vector3(0.12, 0.28, 0.12)
	canister.material_override = MunitionPool.albedo(Color(0.35, 0.36, 0.32))
	var parent = _effects_parent()
	if parent == null:
		return
	parent.add_child(canister)
	canister.global_position = start

	# Short, high lob - it's a mortar-ish tube, not a gun.
	var tween = create_tween()
	var callable = func(val: float):
		if not is_instance_valid(canister): return
		var pos = start.lerp(end, val)
		pos.y += sin(val * PI) * 3.0
		canister.global_position = pos
	tween.tween_method(callable, 0.0, 1.0, 0.45)
	tween.finished.connect(func():
		if is_instance_valid(canister): canister.queue_free()
		# Routes through the shared ammo impact path, so a discharger loaded
		# with illumination fires a flare instead - the one other thing it
		# is allowed to do (see WEAPON_AMMO_OPTIONS).
		_ammo_impact_scale = spread_mult
		_apply_ammo_impact(end)
		_ammo_impact_scale = 1.0
	)

func _fire_resource_harvester_tether():
	var tether = MeshInstance3D.new()
	tether.mesh = MunitionPool.unit_cylinder()
	tether.material_override = MunitionPool.emissive(Color.GOLD, Color.GOLD)
	_effects_parent().add_child(tether)

	var tether_len = MunitionPool.aim_beam(tether, global_position, target.global_position, 0.16)

	if is_instance_valid(target):
		_deal_weapon_damage(target, dps * fire_rate)

	# y holds the tether's length now that it is no longer baked into the mesh
	# (was a literal 1); only the radius collapses.
	var tween = create_tween()
	tween.tween_property(tether, "scale", Vector3(0, tether_len, 0), 0.08)
	tween.finished.connect(func(): tether.queue_free())

func _fire_repair_array_beam():
	var beam = MeshInstance3D.new()
	beam.mesh = MunitionPool.unit_cylinder()
	beam.material_override = MunitionPool.emissive(Color.CYAN, Color.CYAN)
	_effects_parent().add_child(beam)

	MunitionPool.aim_beam(beam, global_position, target.global_position, 0.06)

	var spark = MeshInstance3D.new()
	spark.mesh = MunitionPool.unit_sphere()
	spark.scale = Vector3(0.3, 0.3, 0.3)
	spark.material_override = MunitionPool.emissive(Color.WHITE, Color.CYAN)
	_effects_parent().add_child(spark)
	spark.global_position = target.global_position + Vector3(randf_range(-0.3, 0.3), randf_range(0.2, 0.8), randf_range(-0.3, 0.3))
	var st = create_tween()
	st.tween_property(spark, "scale", Vector3.ZERO, 0.1)
	st.finished.connect(func(): spark.queue_free())
	
	if is_instance_valid(target) and target.has_method("repair_hp"):
		target.repair_hp(heal_rate * fire_rate)

	var timer = get_tree().create_timer(0.08)
	timer.timeout.connect(func(): if is_instance_valid(beam): beam.queue_free())

# --- Energy weapons (ENERGY_AND_BALANCE_SPEC.md #4/#5) ---
# arc_projector/ion_cannon/microwave_emitter drain the TARGET's current_energy
# (duck-typed via has_method("drain_energy")) on top of whatever HP damage
# they deal - energy_drain_per_shot/energy_cost_per_shot are computed once in
# _ready() from the weapon's own dps*fire_rate, see there for the formula.

func _fire_arc_projector():
	# The dedicated pure-drain "disable" weapon - minor HP damage, big
	# energy drain (see _ready()'s energy_drain_per_shot formula).
	var beam = MeshInstance3D.new()
	# The only beam in the arsenal that widens along its length (0.02 -> 0.05),
	# so it takes the taper variant rather than the plain unit cylinder; the
	# 0.4 ratio is that same 0.02/0.05, with the 0.05 bottom carried by the
	# 0.10 diameter passed to aim_beam.
	beam.mesh = MunitionPool.unit_taper(0.4)
	beam.material_override = MunitionPool.emissive(laser_color, laser_color, 2.0)
	_effects_parent().add_child(beam)
	MunitionPool.aim_beam(beam, global_position, target.global_position, 0.10)

	if is_instance_valid(target):
		_deal_weapon_damage(target, (dps * fire_rate) * 0.2)
		if target.has_method("drain_energy"):
			target.drain_energy(energy_drain_per_shot)

	var timer = get_tree().create_timer(0.1)
	timer.timeout.connect(func(): if is_instance_valid(beam): beam.queue_free())


# Microwave emitter: a CONE, not a beam. Everything else in the energy
# bracket resolves on one target; this one sweeps everything inside its
# aperture, does very little HP damage, and empties their capacitors. It is
# the roster's only dedicated answer to an energy-hungry design.
#
# dish_aperture widens the cone and shortens the range (see _ready()), so
# the same tweak that makes it hit more things makes it reach less far.
const MICROWAVE_BASE_HALF_ANGLE: float = 0.26 # radians at aperture 1.0

func _fire_microwave_emitter():
	var parent = _effects_parent()
	if parent == null: return

	var aperture = 1.0
	if has_meta("module_data"):
		aperture = float(get_meta("module_data").tweaks.get("dish_aperture", 1.0))
	var half_angle = clampf(MICROWAVE_BASE_HALF_ANGLE * aperture, 0.08, 1.1)
	var forward = -global_transform.basis.z.normalized()
	var per_shot = dps * fire_rate

	# Everything hostile inside the cone takes the hit, so a tight dish
	# concentrates on one target and a wide one blankets a formation.
	var my_team = get_team()
	for c in get_tree().get_nodes_in_group("damageable"):
		if not is_instance_valid(c) or not c.has_method("take_damage"):
			continue
		if "is_dead" in c and c.is_dead:
			continue
		if c == get_vehicle_root():
			continue
		if c.has_meta("team") and my_team != -1 and c.get_meta("team") == my_team:
			continue
		var to_c = c.global_position - global_position
		var dist = to_c.length()
		if dist > fire_range or dist < 0.01:
			continue
		if forward.angle_to(to_c.normalized()) > half_angle:
			continue
		_deal_weapon_damage(c, per_shot)
		if c.has_method("drain_energy"):
			c.drain_energy(energy_drain_per_shot)

	# Visual: nested shells stepping out along the cone, so the aperture is
	# legible in the effect and not only in the model.
	var steps := 4
	for i in range(steps):
		var t = (float(i) + 1.0) / float(steps)
		var shell = MeshInstance3D.new()
		shell.mesh = MunitionPool.unit_sphere()
		shell.material_override = MunitionPool.alpha(Color(0.95, 0.85, 0.45, 0.20))
		parent.add_child(shell)
		shell.global_position = global_position + forward * (fire_range * t * 0.55)
		var spread = fire_range * t * 0.55 * tan(half_angle)
		shell.scale = Vector3(spread, spread, spread * 0.35)
		var st = create_tween()
		st.tween_property(shell, "scale", Vector3.ZERO, 0.16 + t * 0.10)
		st.finished.connect(func(): if is_instance_valid(shell): shell.queue_free())

# Particle lance: the roster's biggest single hit, at the roster's slowest
# cycle. Deliberately telegraphed - a charge glow builds on the accelerator
# before the shot, so an alert opponent gets a warning and a chance to kill
# it mid-wind-up. That warning is the balance for 660 damage in one hit.
func _fire_particle_lance():
	var parent = _effects_parent()
	if parent == null: return

	var forward = -global_transform.basis.z.normalized()

	# The beam itself: a thin, very bright core with a wider halo.
	for pass_i in range(2):
		var beam = MeshInstance3D.new()
		beam.mesh = MunitionPool.unit_cylinder()
		var col = laser_color if pass_i == 0 else Color(1.0, 1.0, 1.0)
		beam.material_override = MunitionPool.emissive(col, col, 3.0 if pass_i == 1 else 1.6)
		parent.add_child(beam)
		var aim = target.global_position if is_instance_valid(target) else global_position + forward * fire_range
		MunitionPool.aim_beam(beam, global_position, aim, 0.16 if pass_i == 0 else 0.05)
		var bt = create_tween()
		bt.tween_property(beam, "scale", Vector3(0.02, beam.scale.y, 0.02), 0.22)
		bt.finished.connect(func(): if is_instance_valid(beam): beam.queue_free())

	if is_instance_valid(target):
		_deal_weapon_damage(target, dps * fire_rate)
		if target.has_method("drain_energy"):
			target.drain_energy(energy_drain_per_shot)

	# Muzzle bloom and a hard recoil flare back down the spine.
	var bloom = MeshInstance3D.new()
	bloom.mesh = MunitionPool.unit_sphere()
	bloom.material_override = MunitionPool.emissive(laser_color, Color(0.8, 0.95, 1.0), 2.5)
	parent.add_child(bloom)
	bloom.global_position = global_position + forward * 1.2
	bloom.scale = Vector3.ONE * 0.55
	var blt = create_tween()
	blt.tween_property(bloom, "scale", Vector3.ZERO, 0.20)
	blt.finished.connect(func(): if is_instance_valid(bloom): bloom.queue_free())

func _fire_ion_cannon():
	# The "grounded" energy heavy-hitter - single strong beam, full HP
	# damage plus a real energy drain alongside it.
	var beam = MeshInstance3D.new()
	beam.mesh = MunitionPool.unit_cylinder()
	beam.material_override = MunitionPool.emissive(laser_color, laser_color, 1.2)
	_effects_parent().add_child(beam)
	var beam_len = MunitionPool.aim_beam(beam, global_position, target.global_position, 0.12)

	if is_instance_valid(target):
		_deal_weapon_damage(target, dps * fire_rate)
		if target.has_method("drain_energy"):
			target.drain_energy(energy_drain_per_shot)
		_spawn_explosion_visual(target.global_position, 0.7, laser_color)

	# Radius-only collapse; y preserves the length that now lives in scale.
	var tween = create_tween()
	tween.tween_property(beam, "scale", Vector3(0.0, beam_len, 0.0), 0.15)
	tween.finished.connect(func(): if is_instance_valid(beam): beam.queue_free())

# --- Ammo on-impact payload effects ---------------------------------------
#
# Called once per round that LANDS (not once per target damaged). Three call
# sites cover every ammo-capable weapon in the roster:
#   - _deal_aoe_damage()        - artillery, mortar, flak, cluster, HE/etc.
#   - _fire_kinetic_projectile() - the direct-fire guns and autocannons
#   - weapon_missile.gd's impact - guided_missile / missile_pod warheads
# Everything else in WEAPON_AMMO_OPTIONS routes through one of those three.
func _apply_ammo_impact(pos: Vector3):
	match ammo_type:
		"smoke":
			_spawn_smoke_cloud(pos)
		"incendiary":
			_spawn_burn_pool(pos)
		"illumination":
			_spawn_illumination_flare(pos)

func _spawn_smoke_cloud(pos: Vector3):
	var parent = _effects_parent()
	if parent == null:
		return
	var is_dedicated = type_id == "smoke_discharger"
	var r = SMOKE_DISCHARGER_RADIUS if is_dedicated else SMOKE_SHELL_RADIUS
	var life = SMOKE_DISCHARGER_LIFETIME if is_dedicated else SMOKE_SHELL_LIFETIME
	SmokeVolume.spawn(parent, pos, r * _ammo_impact_scale, life)

# Incendiary's lingering ground hazard. Deliberately built on the same
# shape as plasma_lobber's existing puddle (a flat translucent disc that
# shrinks away), but unlike that purely cosmetic one this actually ticks
# damage - it's the reason to load incendiary over plain HE against a
# position you expect the enemy to keep standing on.
const BURN_POOL_RADIUS: float = 3.5
const BURN_POOL_DURATION: float = 5.0
const BURN_POOL_TICK: float = 0.5
# How long the scorch mark lingers AFTER the fire is out. Long, deliberately -
# a battlefield that remembers where it burned is most of the value of having
# ground decals at all.
const BURN_POOL_SCORCH_FADE: float = 20.0

# Craters from explosive hits that actually land on the ground.
#
# Rate-limited rather than one-per-shell on purpose: a rotary autocannon
# firing HE would otherwise carpet the map in decals within seconds, and
# every live decal is real shading cost. A minimum blast radius filters out
# the small-arms end of the roster, so a crater means something hit hard.
const CRATER_MIN_RADIUS: float = 2.0
const CRATER_MIN_INTERVAL_MS: int = 900
const CRATER_GROUND_MAX_Y: float = 1.2
var _last_crater_ms: int = 0

func _maybe_crater(center: Vector3, radius: float) -> void:
	if radius < CRATER_MIN_RADIUS:
		return
	if Time.get_ticks_msec() - _last_crater_ms < CRATER_MIN_INTERVAL_MS:
		return
	# Only ground bursts leave a mark - an airburst against a flyer, or a hit
	# high on a building, has no ground to dig into.
	var scene = get_tree().current_scene
	if scene and scene.has_method("terrain_height_at"):
		if absf(center.y - scene.terrain_height_at(center)) > CRATER_GROUND_MAX_Y:
			return
	var parent = _effects_parent()
	if parent == null:
		return
	_last_crater_ms = Time.get_ticks_msec()
	VFXEffects.crater(parent, center, radius * 0.75)

func _spawn_burn_pool(pos: Vector3, radius_mult: float = 1.0, duration_mult: float = 1.0):
	var parent = _effects_parent()
	if parent == null:
		return
	var pool_radius = BURN_POOL_RADIUS * radius_mult
	var pool_duration = BURN_POOL_DURATION * duration_mult

	# A projected Decal plus real fire particles, replacing what used to be a
	# flat emissive CYLINDER laid on the ground and shrunk by a tween.
	#
	# The cylinder had two problems. Visually it was a disc of orange plastic
	# with a hard rim, at a single Y - so on any of the heightmap maps
	# (highland_chokepoint, twin_summits, scattered_peaks) it either floated
	# above a slope or sank into it, since every map in this game has real
	# elevation. A Decal projects down onto whatever is actually there and
	# wraps the contour for free. And "burning ground" reads as fire because
	# of flames, not because the ground is tinted orange.
	#
	# Purely a visual swap: pool damage is driven by the scene timers below,
	# which never referenced the puddle node at all.
	VFXEffects.scorch(parent, pos, pool_radius, pool_duration, BURN_POOL_SCORCH_FADE)
	VFXEffects.fire_pool(parent, pos, pool_radius, pool_duration)

	# Damage ticks are driven off scene timers rather than the puddle's own
	# _process so the pool keeps burning even if the firing weapon (and its
	# whole vehicle) is destroyed mid-burn.
	var ticks = int(pool_duration / BURN_POOL_TICK)
	var per_tick = dps * fire_rate * 0.12
	for i in range(ticks):
		get_tree().create_timer(i * BURN_POOL_TICK).timeout.connect(func():
			if not is_inside_tree():
				return
			_deal_burn_tick(pos, per_tick, pool_radius)
		)

# A burn tick bypasses the ammo multipliers in _deal_weapon_damage() - the
# pool's damage is already derived from them once, at spawn time, and it is
# always thermal regardless of anything else.
func _deal_burn_tick(center: Vector3, amount: float, pool_radius: float = BURN_POOL_RADIUS):
	var my_team = get_team()
	for c in get_tree().get_nodes_in_group("damageable"):
		if not is_instance_valid(c) or not c.has_method("take_damage"):
			continue
		if "is_dead" in c and c.is_dead:
			continue
		var c_team = c.get_meta("team") if c.has_meta("team") else -1
		if my_team >= 0 and c_team == my_team:
			continue
		if center.distance_to(c.global_position) > pool_radius:
			continue
		c.take_damage(amount, "thermal", center)

# Illumination flare: reveals fog of war where it lands. Duck-typed through
# current_scene exactly like _teams_allied()/_owner_defense_low_power() do,
# so a Test Range or headless fixture (neither of which has a real Skirmish
# or any fog at all) simply gets the visual and no reveal, rather than
# erroring on a method that isn't there.
func _spawn_illumination_flare(pos: Vector3):
	var parent = _effects_parent()
	if parent == null:
		return

	var scene = get_tree().current_scene
	if scene and scene.has_method("reveal_area"):
		scene.reveal_area(get_team(), pos, ILLUM_RADIUS, ILLUM_LIFETIME)

	var flare = MeshInstance3D.new()
	flare.mesh = MunitionPool.unit_sphere()
	flare.scale = Vector3.ONE * 0.8
	flare.material_override = MunitionPool.emissive(Color(1.0, 0.97, 0.8), Color(1.0, 0.95, 0.7), 2.0)
	parent.add_child(flare)
	flare.global_position = pos + Vector3(0, 1.0, 0)

	var light = OmniLight3D.new()
	light.light_color = Color(1.0, 0.96, 0.8)
	light.light_energy = 4.0
	light.omni_range = ILLUM_RADIUS
	# Distance-fade cosmetic light. Far-off flares don't pay the per-light
	# cost in the Forward+ cluster grid. light_cap.gd:1-30 sets the
	# cluster cap; this is the per-light self-cull that gets it down to it.
	light.distance_fade_enabled = true
	light.distance_fade_begin = ILLUM_RADIUS * 0.7
	light.distance_fade_length = ILLUM_RADIUS * 0.3
	light.shadow_enabled = false
	flare.add_child(light)

	# Drifts down under its parachute, then burns out.
	var ft = create_tween()
	ft.tween_property(flare, "global_position", pos + Vector3(0, 0.2, 0), ILLUM_LIFETIME)
	ft.parallel().tween_property(light, "light_energy", 0.0, ILLUM_LIFETIME)
	ft.finished.connect(func(): if is_instance_valid(flare): flare.queue_free())

func _spawn_explosion_visual(pos: Vector3, custom_scale: float = 0.6, color: Color = Color.ORANGE):
	var parent := _effects_parent()
	# Per-spawn entropy: every detonation looks slightly different so a
	# barrage doesn't read as a stamp of identical copies.
	var entropy := randf_range(0.82, 1.18)
	var scale_e := custom_scale * entropy
	var color_shift := Color(randf_range(0.90, 1.0), randf_range(0.85, 1.0), randf_range(0.80, 1.0))
	var final_color: Color = color * color_shift
	# Jitter the spawn position slightly so adjacent hits don't stack
	# perfectly on top of each other.
	var jitter := Vector3(randf_range(-0.15, 0.15), randf_range(-0.05, 0.15), randf_range(-0.15, 0.15))
	var impact_pos := pos + jitter

	# Spark shrapnel burst — particle count and speed scale with the
	# detonation size, plus entropy.
	var spark_count = int((12.0 + scale_e * 18.0) * entropy)
	VFXBurstScript.spawn(parent, impact_pos, final_color, spark_count, 0.25, 50.0,
		3.0 * entropy, 8.0 * entropy)
	VFXEffects.smoke_puff(parent, impact_pos, scale_e * 1.4, 8, Color(0.20, 0.19, 0.18, 0.65))

	# Particle-driven fireball — additive flame quads replace the old
	# scaling MeshInstance3D sphere. Reads as a bright flash at RTS zoom
	# and dissipates with the flipbook rather than popping to zero.
	VFXEffects.fire_burst(parent, impact_pos, scale_e * 1.2, final_color)

	# OmniLight impact flash — brief bright pop at the detonation point
	var light = OmniLight3D.new()
	light.light_color = final_color
	light.light_energy = (3.0 + scale_e * 4.0) * entropy
	light.omni_range = 3.0 + scale_e * 4.0
	light.omni_attenuation = 0.5
	light.light_bake_mode = Light3D.BAKE_DISABLED
	# Distance-fade cosmetic flash. Lifetime is 0.15s so this rarely
	# matters, but a single-frame un-faded light at long range is the
	# worst case for the per-light cluster-grid cost, and the property is
	# free to set.
	light.distance_fade_enabled = true
	light.distance_fade_begin = light.omni_range * 0.7
	light.distance_fade_length = light.omni_range * 0.3
	light.shadow_enabled = false
	parent.add_child(light)
	light.position = impact_pos
	var lt = create_tween()
	lt.tween_property(light, "light_energy", 0.0, 0.15)
	lt.finished.connect(func(): if is_instance_valid(light): light.queue_free())

	# Heavy detonations leave persistent terrain craters and scorch
	if custom_scale >= 1.0:
		VFXEffects.crater(parent, impact_pos, custom_scale * 1.2, 35.0)
		VFXEffects.scorch(parent, impact_pos, custom_scale * 1.4, 2.0, 15.0)

func _fire_standard_laser():
	var laser = MeshInstance3D.new()
	laser.mesh = MunitionPool.unit_cylinder()
	laser.material_override = MunitionPool.emissive(laser_color, laser_color)
	_effects_parent().add_child(laser)

	MunitionPool.aim_beam(laser, global_position, target.global_position, 0.10)


	if is_instance_valid(target):
		_deal_weapon_damage(target, dps * fire_rate)
	
	var timer = get_tree().create_timer(0.08)
	timer.timeout.connect(func(): if is_instance_valid(laser): laser.queue_free())

# --- Heavy Barrier Projector (Aegis Field) Logic ---

func _tick_heavy_barrier(delta: float) -> void:
	_find_nearest_target(delta)

	var turret_body = get_node_or_null("TurretBody")
	var pivot_node = turret_body if turret_body else self
	# The pivot's rest orientation: authored identity for a TurretBody child,
	# this module's own resting_transform when there is no child and the module
	# itself pivots (a belly mount keeps its authored flip).
	var pivot_rest_q := Quaternion.IDENTITY if pivot_node != self \
			else resting_transform.basis.get_rotation_quaternion()
	# Aim direction must be expressed in the PIVOT'S PARENT space - the weapon
	# module for a TurretBody child, the hull for the self case. The old code
	# always read hull space and wrote it onto a pivot living in weapon space,
	# which drifted whenever the weapon itself was mounted off-identity.
	var pivot_parent := pivot_node.get_parent() as Node3D

	# Smoothly pivot to aim at nearest enemy or face forward if none
	if target and is_instance_valid(target) and not ("is_dead" in target and target.is_dead):
		var target_pos = target.global_position + Vector3(0, 0.5, 0)
		var dir_in_pivot_parent: Vector3
		if pivot_parent != null and is_instance_valid(pivot_parent):
			dir_in_pivot_parent = (pivot_parent.to_local(target_pos) - pivot_node.position).normalized()
		else:
			dir_in_pivot_parent = (target_pos - pivot_node.global_position).normalized()
		var target_local_basis := _aim_basis_from_rest(pivot_rest_q, dir_in_pivot_parent)
		var q_current = pivot_node.transform.basis.get_rotation_quaternion()
		var q_target = target_local_basis.get_rotation_quaternion()
		var q_next = q_current.slerp(q_target, traverse_speed * delta)
		pivot_node.transform.basis = Basis(q_next).scaled(pivot_node.transform.basis.get_scale())
	else:
		# Return smoothly to the pivot's own resting orientation
		var q_current = pivot_node.transform.basis.get_rotation_quaternion()
		var q_target = pivot_rest_q
		var q_next = q_current.slerp(q_target, traverse_speed * delta)
		pivot_node.transform.basis = Basis(q_next).scaled(pivot_node.transform.basis.get_scale())

	# Barrier recharge / brownout lifecycle
	if barrier_collapse_timer > 0.0:
		barrier_collapse_timer -= delta
		is_barrier_active = false
		if barrier_collapse_timer <= 0.0:
			barrier_current_hp = barrier_max_hp
			is_barrier_active = true
	else:
		var root_veh = get_vehicle_root()
		if root_veh and root_veh.get("current_energy") != null and root_veh.current_energy <= 0.0:
			is_barrier_active = false
		else:
			is_barrier_active = true
			barrier_current_hp = minf(barrier_max_hp, barrier_current_hp + 20.0 * delta)

	# Update visual field node
	var field = get_node_or_null("ProjectedAegisField")
	if field:
		field.visible = is_barrier_active
		if is_barrier_active and field.material_override is ShaderMaterial:
			var mat = field.material_override as ShaderMaterial
			var current_flash: float = float(mat.get_shader_parameter("impact_flash")) if mat.get_shader_parameter("impact_flash") != null else 0.0
			if current_flash > 0.01:
				mat.set_shader_parameter("impact_flash", maxf(0.0, current_flash - delta * 2.5))

func get_aegis_field_info() -> Dictionary:
	if not is_barrier_active or barrier_current_hp <= 0.0:
		return {"is_active": false}
	var turret_body = get_node_or_null("TurretBody")
	var basis_to_use: Basis
	if turret_body:
		basis_to_use = turret_body.global_transform.basis if is_inside_tree() else turret_body.transform.basis
	else:
		basis_to_use = global_transform.basis if is_inside_tree() else transform.basis
	var forward = -basis_to_use.z.normalized()
	var pos = global_position if is_inside_tree() else position
	var center = pos + forward * projection_dist
	return {
		"is_active": true,
		"center": center,
		"radius": 9.0 * field_width_mult,
		"half_depth": 5.5 * field_width_mult,
		"height": 4.5 * sqrt(field_width_mult),
		"barrier_hp": barrier_current_hp,
		"max_barrier_hp": barrier_max_hp,
		"projector": self,
		"forward": forward
	}

func absorb_aegis_damage(amount: float) -> float:
	if not is_barrier_active or barrier_current_hp <= 0.0:
		return amount
	var absorbed = minf(amount, barrier_current_hp)
	barrier_current_hp -= absorbed
	var field = get_node_or_null("ProjectedAegisField")
	if field and field.material_override is ShaderMaterial:
		field.material_override.set_shader_parameter("impact_flash", 0.6)
	if barrier_current_hp <= 0.0:
		is_barrier_active = false
		barrier_collapse_timer = 6.0 # Collapse recharge cooldown
	return amount - absorbed
