class_name ModuleCatalog

const HullLoader = preload("res://scripts/hull_loader.gd")
const GlobalConfigScript = preload("res://scripts/global_config.gd")

# --- Hull-level derived stats (FABLE_REVIEW.md 1.2 / 1.3 / 2.6) ---
# Single source of truth for what a hull's armor material, thickness slider,
# and scale handles actually DO - shared by combat (battle_unit/building),
# the economy (skirmish.blueprint_cost), and the Design Lab sidebar
# (stat_calculator), so the number a player sees is the number the sim uses.
# Before this, material/thickness multiplied HP for free (no cost, no combat
# weight - the weight increase existed only in the sidebar display) and
# hull_scale affected nothing but mounting area - both were solved dominant
# choices, the exact Forged-Battalion failure DESIGN_VISION.md warns about.

const HULL_SCALE_MIN: float = 0.5
const HULL_SCALE_MAX: float = 2.0

static func get_hull_volume_factor(hull_scale: Vector3) -> float:
	return hull_scale.x * hull_scale.y * hull_scale.z

static func _volume_scaled(base: float, hull_scale: Vector3, factor: float) -> float:
	var v = get_hull_volume_factor(hull_scale)
	return base + base * (v - 1.0) * factor

static func compute_hull_max_hp(hull_type_id: String, _thickness: float = 1.0, _material: String = "hardened_steel", hull_scale: Vector3 = Vector3.ONE) -> float:
	var base = get_module_data(hull_type_id).get("hp", 400.0)
	return _volume_scaled(base, hull_scale, GlobalConfigScript.hp_scale_factor)

static func compute_hull_weight(hull_type_id: String, _thickness: float = 1.0, _material: String = "hardened_steel", hull_scale: Vector3 = Vector3.ONE, _armor_weight_mult: float = 1.0) -> float:
	var base = get_module_data(hull_type_id).get("weight", 250.0)
	return _volume_scaled(base, hull_scale, GlobalConfigScript.weight_scale_factor)

static func compute_hull_cost(hull_type_id: String, _thickness: float = 1.0, _material: String = "hardened_steel", hull_scale: Vector3 = Vector3.ONE) -> Vector2i:
	var data = get_module_data(hull_type_id)
	var m = _volume_scaled(float(data.get("metal", 100)), hull_scale, GlobalConfigScript.cost_scale_factor)
	var c = _volume_scaled(float(data.get("crystal", 0)), hull_scale, GlobalConfigScript.cost_scale_factor)
	return Vector2i(int(round(m)), int(round(c)))

# Merged catalog cache (FABLE_REVIEW.md 3.5): get_catalog() used to rebuild
# the entire ~60-entry dict literal on every call - and it's called from
# genuinely hot paths (per-hit damage resolution, per-tick terrain/draught
# lookups). Built once and reused; invalidated automatically whenever
# HullLoader's own cache is rebuilt (reset_cache_for_tests/rescan returns a
# NEW Dictionary instance, detected by identity below), so the hull-modding
# tests' reset flow keeps working unchanged. Callers must treat returned
# entries as read-only - they're shared, not copies (that was already true
# for hull entries before this change).
static var _catalog_cache: Dictionary = {}
static var _cached_hull_dict: Dictionary = {}

# Returns a dictionary containing all module types. Hull entries (category
# "hull") are no longer hardcoded here - see hull_loader.gd, which lazily
# scans same-stem .glb+.json pairs from res://assets/models/hulls (built-in)
# and user://mods/hulls (player-added mods) once and caches the result
# (HULL_MODDING_PLAN.md §3).
static func get_catalog() -> Dictionary:
	var hulls = HullLoader.get_hulls()
	if not _catalog_cache.is_empty() and is_same(hulls, _cached_hull_dict):
		return _catalog_cache
	var catalog = _build_catalog_literal()
	for hull_id in hulls:
		catalog[hull_id] = hulls[hull_id]
	_catalog_cache = catalog
	_cached_hull_dict = hulls
	return _catalog_cache

# Real existence check for any catalog entry (weapon/module/locomotion/hull),
# mirroring hull_exists() below - reconstruct_vehicle uses this to SKIP an
# unknown module type_id instead of get_module_data()'s silent
# basic_cannon-weapon-data fallback (FABLE_REVIEW.md 3.4).
static func module_exists(type_id: String) -> bool:
	return get_catalog().has(type_id)

# --- Drone carrier profiles (DEPLOYABLE_MODULES_OVERHAUL.md §1) ---
# drone_type is the 12 o'clock tweak on the drone_carrier in the Design Lab.
# Each profile overrides speed, damage, and the state machine behaviour in drone_unit.gd.
const DRONE_PROFILES = {
	"attack": {
		"label": "Attack Drone",
		"desc": "Strikes hostile target with kinetic/explosive damage on arrival, loiters briefly, and returns.",
		"speed": 14.0,
	},
	"scout": {
		"label": "Scout Drone",
		"desc": "High-speed reconnaissance. Orbits target area, reveals fog of war across a wide radius, then returns.",
		"speed": 18.0,
	},
	"repair": {
		"label": "Repair Drone",
		"desc": "Seeks damaged friendly units, channels repair HP while tethered, then returns.",
		"speed": 12.0,
	},
}

static func get_drone_profile(drone_type: String) -> Dictionary:
	return DRONE_PROFILES.get(drone_type, DRONE_PROFILES.get("attack", {}))

static func get_drone_options() -> Array:
	return DRONE_PROFILES.keys()

# --- Weapon fire profiles (balance harness migration) ---
# fire_rate/fire_range/laser_color used to live in a ~120-line if/elif chain
# in auto_weapon.gd's _ready(), which made them invisible to every balance
# tool: balance_report.gd scored weapons on `dps` alone, and `dps` is the
# LEAST interesting of the three, because the armor system gates on PER-SHOT
# damage and per-shot damage is `dps * fire_rate` (see auto_weapon.gd's
# _deal_weapon_damage callers). A weapon's threshold behaviour is therefore
# driven mostly by fire_rate, which nothing could see or tune.
#
# Kept as ONE contiguous table rather than folded into each catalog entry
# specifically so tools/run_simulations.gd can rewrite it mechanically after
# a sweep - a 21-entry block is patchable, 21 edits scattered through a
# 1700-line dict literal are not.
#
# fire_rate is a shot INTERVAL in seconds (lower = faster), not shots/sec.
# Merged into the catalog entries by _build_catalog_literal() below, so
# `get_module_data(id).fire_rate` is the single source of truth.
const WEAPON_FIRE_PROFILES = {
	"basic_cannon":       {"fire_rate": 1.8,  "fire_range": 38.0, "laser_color": Color.ORANGE},
	# 0.22 -> 0.66 is the largest single change the balance sweep asked for,
	# and the one most likely to need a feel check: at 0.22s the HMG's
	# per-shot damage (dps * fire_rate) was ~5.5, permanently under every
	# real armor threshold, so it spent the whole game in CHIP_THROUGH_FACTOR
	# territory dealing 15% damage to anything armored. At 0.66s it clears
	# the lighter thresholds and becomes a real gun - but it also fires 3x
	# slower, which reads more like a light autocannon than a machine gun.
	"heavy_machine_gun":  {"fire_rate": 0.66, "fire_range": 26.0, "laser_color": Color.GOLD},
	"rotary_cannon":      {"fire_rate": 0.05, "fire_range": 28.0, "laser_color": Color.GOLD},
	"gauss_railgun":      {"fire_rate": 3.5,  "fire_range": 72.0, "laser_color": Color.BLUE_VIOLET},
	"artillery":          {"fire_rate": 4.5,  "fire_range": 140.0, "laser_color": Color.SADDLE_BROWN},
	"mortar_array":       {"fire_rate": 2.0,  "fire_range": 55.0, "laser_color": Color.OLIVE},
	"guided_missile":     {"fire_rate": 3.0,  "fire_range": 55.0, "laser_color": Color.YELLOW},
	"missile_pod":        {"fire_rate": 2.8,  "fire_range": 48.0, "laser_color": Color.DARK_ORANGE},
	"drone_carrier":      {"fire_rate": 5.0,  "fire_range": 55.0, "laser_color": Color.NAVY_BLUE},
	"cluster_dispenser":  {"fire_rate": 3.0,  "fire_range": 34.0, "laser_color": Color.CHOCOLATE},
	"flamethrower":       {"fire_rate": 0.06, "fire_range": 11.0,  "laser_color": Color.CRIMSON},
	"heavy_laser":        {"fire_rate": 0.05, "fire_range": 34.0, "laser_color": Color.DARK_RED},
	"plasma_lobber":      {"fire_rate": 2.2,  "fire_range": 32.0, "laser_color": Color.MEDIUM_SPRING_GREEN},
	"tesla_coil":         {"fire_rate": 1.4,  "fire_range": 18.0, "laser_color": Color.LIGHT_SKY_BLUE},
	"arc_projector":      {"fire_rate": 0.9,  "fire_range": 12.0, "laser_color": Color.CYAN},
	"ion_cannon":         {"fire_rate": 3.2,  "fire_range": 50.0, "laser_color": Color.SKY_BLUE},
	# Cone denial. Short interval and low per-shot on purpose: it is not
	# supposed to kill things, it is supposed to make their electronics stop
	# working, which it does through the energy drain rather than the damage.
	"microwave_emitter":  {"fire_rate": 0.35, "fire_range": 20.0, "laser_color": Color(0.95, 0.85, 0.45)},
	# The slowest cycle in the roster by a wide margin, and the biggest energy
	# bill. 120 dps at a 5.5s interval is 660 per shot - well past even the
	# anti-materiel rifle - but you only get it every five and a half seconds
	# and only if the capacitor is charged.
	"particle_lance":     {"fire_rate": 5.5,  "fire_range": 58.0, "laser_color": Color(0.70, 0.90, 1.0)},
	"spigot_mortar":      {"fire_rate": 5.0,  "fire_range": 16.0, "laser_color": Color(0.85, 0.70, 0.40)},
	"rocket_artillery":   {"fire_rate": 3.0,  "fire_range": 100.0, "laser_color": Color(0.95, 0.60, 0.25)},
	"hypervelocity_missile": {"fire_rate": 2.2, "fire_range": 44.0, "laser_color": Color(0.85, 0.92, 1.0)},
	"sam_launcher":       {"fire_rate": 2.6,  "fire_range": 62.0, "laser_color": Color(0.80, 0.85, 0.90)},
	"loitering_munition": {"fire_rate": 4.0,  "fire_range": 120.0, "laser_color": Color(0.70, 0.78, 0.66)},
	"anti_radiation_missile": {"fire_rate": 3.4, "fire_range": 60.0, "laser_color": Color(0.75, 0.80, 0.78)},
	"bunker_buster":      {"fire_rate": 4.2,  "fire_range": 36.0, "laser_color": Color(0.70, 0.72, 0.75)},
	"cruise_missile":     {"fire_rate": 5.0,  "fire_range": 170.0, "laser_color": Color(0.78, 0.80, 0.72)},
	"chaff_dispenser":    {"fire_rate": 3.5,  "fire_range": 12.0,  "laser_color": Color(0.85, 0.86, 0.80)},
	"laser_dazzler":      {"fire_rate": 0.7,  "fire_range": 28.0, "laser_color": Color(0.40, 0.95, 0.55)},
	"aps_interceptor":    {"fire_rate": 0.9,  "fire_range": 9.0,  "laser_color": Color(1.0, 0.75, 0.35)},
	"aa_autocannon":      {"fire_rate": 0.20, "fire_range": 38.0, "laser_color": Color(1.0, 0.85, 0.45)},
	"jammer_mast":        {"fire_rate": 2.0,  "fire_range": 30.0, "laser_color": Color(0.55, 0.85, 0.90)},
	"sentry_deployer":    {"fire_rate": 8.0,  "fire_range": 16.0, "laser_color": Color(0.70, 0.75, 0.60)},
	"sensor_beacon_launcher": {"fire_rate": 6.0, "fire_range": 46.0, "laser_color": Color(0.65, 0.90, 0.75)},
	"decoy_projector":    {"fire_rate": 10.0, "fire_range": 14.0, "laser_color": Color(0.80, 0.80, 0.65)},
	"ciws":               {"fire_rate": 0.06, "fire_range": 22.0, "laser_color": Color.WHITE_SMOKE},
	"pd_laser":           {"fire_rate": 0.1,  "fire_range": 24.0, "laser_color": Color.LIGHT_CORAL},
	"flak_cannon":        {"fire_rate": 1.2,  "fire_range": 40.0, "laser_color": Color.DARK_GOLDENROD},
	# --- Roster expansion ---
	# Belt-fed: fast for a grenade weapon, slow for an autogun.
	"mk19_grenade_launcher": {"fire_rate": 0.5, "fire_range": 30.0, "laser_color": Color(0.55, 0.62, 0.30)},
	# The slowest direct-fire cycle in the roster bar the ballista - one
	# enormous HEAT round, then a long, exposed reload.
	"recoilless_rifle":   {"fire_rate": 3.2,  "fire_range": 38.0, "laser_color": Color(1.0, 0.72, 0.35)},
	# Roughly half gauss_railgun's 3.5s cycle at a shorter reach - the
	# turreted, affordable hitscan option.
	"coil_gun":           {"fire_rate": 1.6,  "fire_range": 52.0, "laser_color": Color(0.55, 0.85, 1.0)},
	"autocannon":         {"fire_rate": 0.28, "fire_range": 30.0, "laser_color": Color.GOLDENROD},
	# The roster's only PRECISION weapon. Everything else is DPS or splash;
	# this one is a single very large per-shot number, which is the most
	# interesting place on the damage curve because per-shot damage
	# (dps * fire_rate) is exactly what the armor thresholds gate on. At a
	# 4.5s interval its 78 dps becomes 351 per shot - straight through every
	# armor threshold in the table, and utterly wasted on a scout it can only
	# hit once every four and a half seconds.
	"anti_materiel_rifle": {"fire_rate": 4.5, "fire_range": 66.0, "laser_color": Color(0.95, 0.92, 0.80)},
	"napalm_mortar":      {"fire_rate": 2.6,  "fire_range": 40.0, "laser_color": Color(1.0, 0.45, 0.1)},
	# Short "range" because it is not really shooting - it lobs a mine a
	# short way ahead and leaves it there.
	"mine_layer":         {"fire_rate": 3.5,  "fire_range": 14.0, "laser_color": Color(0.62, 0.56, 0.30)},
	# The slowest weapon in the game, by a distance. A torsion frame does
	# not cycle quickly.
	"ballista":           {"fire_rate": 4.0,  "fire_range": 34.0, "laser_color": Color(0.60, 0.46, 0.30)},
	# Short-ranged and quick-cycling: a discharger lays a screen right in
	# front of its own vehicle, it doesn't shell a distant position. dps is
	# 0.0 in the catalog and every round it fires is a zero-damage
	# obscurant, so fire_rate here is purely "how fast can it re-screen".
	"smoke_discharger":   {"fire_rate": 2.5,  "fire_range": 20.0, "laser_color": Color(0.72, 0.72, 0.74)},
	"resource_harvester": {"fire_rate": 0.1,  "fire_range": 18.0, "laser_color": Color.GOLD},
	"repair_array":       {"fire_rate": 0.15, "fire_range": 22.0, "laser_color": Color.CYAN},
}
# Matches the old chain's trailing `else:` branch - any weapon-ish entry with
# no profile row (including modded/hull-loaded ones) still gets sane values.
const DEFAULT_FIRE_PROFILE = {"fire_rate": 1.0, "fire_range": 15.0, "laser_color": Color.WHITE}

static func get_fire_profile(type_id: String) -> Dictionary:
	return WEAPON_FIRE_PROFILES.get(type_id, DEFAULT_FIRE_PROFILE)

# --- Range tiers -----------------------------------------------------------
# Chris, 2026-08-03: "even the high range weapons are engaging at about the
# same distance as everything else. The longest ranged ones should absolutely
# be range-able out beyond the unit's vision, i.e. the artillery can make use
# of a spotter."
#
# The old band was 7-50 across 45 weapons, which LOOKED like a 7x spread but
# played as a single distance, because range was never the binding constraint:
# a weapon refuses to target anything fog_hidden, fog is driven by
# vision_range, and 26 of those 45 weapons out-ranged the vision of a standard
# hull (scratch/probe_range.gd measured this). Everything past ~20 was reach
# the game could not use. On real maps - map_half_extents runs 135 to 550, so
# 270 to 1100 units across - the whole band also occupied 4-18% of the field.
#
# fire_range is now anchored to vision in explicit tiers, so the number tells
# you HOW a weapon is meant to be used rather than just how big it is. VISION
# below is nominal (medium_hull), not any particular hull's:
#
#   T1 point-blank   0.2-0.4x vision   self-defence; dies to anything kiting it
#   T2 close         0.4-0.6x          has to be in the fight to contribute
#   T3 direct        0.7-1.0x          shoots what its own hull can see
#   T4 overwatch     1.2-1.9x          out-ranges its own eyes; a spotter helps
#   T5 operational   2.6-4.5x          CANNOT self-acquire; spotter-only
#
# T4 and T5 are the point of the exercise. A T5 weapon's reach is 2.6x its own
# vision or more, so it is structurally incapable of finding its own targets -
# it is only useful when some other unit on the team is looking, which is what
# makes a scout worth building and what "artillery can make use of a spotter"
# means mechanically.
const RANGE_TIERS = {
	"point_blank": {"max_vision_mult": 0.4,  "label": "Point Blank"},
	"close":       {"max_vision_mult": 0.65, "label": "Close"},
	"direct":      {"max_vision_mult": 1.1,  "label": "Direct Fire"},
	"overwatch":   {"max_vision_mult": 2.0,  "label": "Overwatch"},
	"operational": {"max_vision_mult": INF,  "label": "Operational"},
}

# The vision every tier boundary above is expressed against - a plain
# medium_hull's, post-VISION_SCALE. Used for classification and for the Design
# Lab readout, never for a real unit's actual sight radius (that always comes
# from its own hull).
const NOMINAL_VISION: float = 38.0

# A weapon's authored reach before any tweak touches it. Same role
# base_traverse plays for traverse - the one number a design starts from.
static func get_base_range(type_id: String) -> float:
	return get_fire_profile(type_id).fire_range

# Which tier a reach falls in, against nominal vision. Drives the Design Lab
# label and the "needs a spotter" warning.
static func get_range_tier(reach: float) -> String:
	for tier in RANGE_TIERS:
		if reach <= RANGE_TIERS[tier].max_vision_mult * NOMINAL_VISION:
			return tier
	return "operational"

static func get_range_tier_label(reach: float) -> String:
	return RANGE_TIERS[get_range_tier(reach)].label

# Indirect fire: a lobbed round arcs over whatever is between the gun and the
# target, so requiring an unbroken raycast to the target - which every other
# weapon does, and rightly - would defeat the entire tier. Without this, a
# 140-unit artillery piece is stopped by any rock or building in the 140 units
# in front of it, which on a real map is essentially always. These are exactly
# the weapons whose fire path is a ballistic arc (see auto_weapon.gd's
# _fire_arcing_shell_at callers), not a general "long range" exemption:
# gauss_railgun reaches 72 and still needs to see what it is shooting.
const INDIRECT_FIRE_TYPES = [
	"artillery", "mortar_array", "rocket_artillery", "spigot_mortar",
	"napalm_mortar", "mk19_grenade_launcher", "cruise_missile",
	"loitering_munition",
]

static func is_indirect_fire(type_id: String) -> bool:
	return type_id in INDIRECT_FIRE_TYPES

static func _build_catalog_literal() -> Dictionary:
	var catalog = {
		# --- BALLISTIC & KINETIC ---
		"basic_cannon": {
			"name": "Main Cannon",
			"category": "weapon",
			"hp": 100.0,
			"weight": 80.0,
			"base_traverse": 1.018,
			"metal": 30,
			"crystal": 0,
			"dps": 40.0,
			# Baseline turret traverse - every other weapon's agility is
			# reasoned relative to this 1.0 anchor.
			"size": Vector3(1.0, 1.0, 3.3),
			"color": Color.DIM_GRAY
		},
		"heavy_machine_gun": {
			"name": "Heavy Machine Gun",
			"category": "weapon",
			"hp": 60.0,
			"weight": 40.0,
			"base_traverse": 1.937,
			"metal": 15,
			"crystal": 0,
			"dps": 32.5,
			# Pintle-mount eligibility (MOUNTING_AND_ARMOR_SPEC.md #3 second
			# correction - see get_sponson_up_alignment()'s comment): a
			# small, light, classic pintle weapon in real life - bolts onto
			# almost anything short of a genuinely vertical wall.
			"pintle_min_up_alignment": 0.15,
			# Small, light gun on a light mount - swings fast, same real-world
			# intuition as its pintle tolerance above.
			"size": Vector3(0.3, 0.3, 1.0),
			"color": Color.SLATE_GRAY
		},
		"rotary_cannon": {
			"name": "Rotary Gatling",
			"category": "weapon",
			"required_building": "tech_lab",
			"hp": 80.0,
			"weight": 110.0,
			"base_traverse": 1.025,
			"metal": 45,
			"crystal": 5,
			"dps": 105.0,
			# Compact gatling housing, same "bolts on anywhere" logic as
			# heavy_machine_gun.
			"pintle_min_up_alignment": 0.15,
			# Motor-driven gatling on a powered gimbal - agile but not as
			# featherweight-quick as the single-barrel MG.
			"size": Vector3(0.8, 0.8, 2.0),
			"color": Color(0.2, 0.2, 0.2) # Charcoal
		},
		"gauss_railgun": {
			"name": "Gauss Railgun",
			"category": "weapon",
			"required_building": "physics_lab",
			"hp": 120.0,
			"weight": 180.0,
			"base_traverse": 0.261,
			"metal": 80,
			"crystal": 40,
			"dps": 99.0,
			# Frame_built (see get_mount_style() below), so it never
			# independently traverses in practice - this number only matters
			# if that override is ever lifted, kept low for consistency with
			# its long rigid accelerator rail.
			"size": Vector3(1.2, 1.2, 5.0),
			"color": Color.BLUE_VIOLET
		},

		# --- INDIRECT FIRE ---
		"artillery": {
			"name": "Artillery",
			"category": "weapon",
			"required_building": "tech_lab",
			# Indirect fire - needs open sky, so it is levelled on a vertical
			# face but never enclosed in a sponson housing. See
			# ModuleCatalog.is_sponson_capable().
			"sponson_capable": false,
			"hp": 150.0,
			"weight": 250.0,
			"base_traverse": 0.217,
			"metal": 100,
			"crystal": 10,
			"dps": 90.0,
			# Frame_built like gauss_railgun - traverse is moot in practice,
			# a low number matches its bulky fixed-elevation mount either way.
			"size": Vector3(1.8, 1.8, 6.4),
			"color": Color.SADDLE_BROWN
		},
		"mortar_array": {
			"name": "Mortar Array",
			"category": "weapon",
			# Indirect fire - needs open sky, so it is levelled on a vertical
			# face but never enclosed in a sponson housing. See
			# ModuleCatalog.is_sponson_capable().
			"sponson_capable": false,
			"hp": 80.0,
			"weight": 90.0,
			"base_traverse": 0.477,
			"metal": 40,
			"crystal": 0,
			"dps": 50.0,
			# Indirect-fire arc trajectory is calculated off a baseline
			# elevation - a mortar bolted onto a steep slope would be lobbing
			# shells at an already-skewed angle before the tube even elevates,
			# so this wants a much closer-to-level base than a direct-fire gun.
			"pintle_min_up_alignment": 0.55,
			# Indirect-fire tube array - traverses slowly and deliberately,
			# same "needs a level, stable aim" character as its pintle stance.
			"size": Vector3(1.6, 0.8, 1.6),
			"color": Color.OLIVE
		},

		# --- MISSILES & DRONES ---
		"guided_missile": {
			"name": "Guided Missile TOW",
			"category": "weapon",
			# Indirect fire - needs open sky, so it is levelled on a vertical
			# face but never enclosed in a sponson housing. See
			# ModuleCatalog.is_sponson_capable().
			"sponson_capable": false,
			"hp": 70.0,
			"weight": 60.0,
			"base_traverse": 1.073,
			"metal": 30,
			"crystal": 15,
			"dps": 55.0,
			# A single-rail launcher whose own guidance corrects for a
			# less-than-level launch angle mid-flight, so it tolerates a
			# steeper mounting slope than an unguided arcing weapon would.
			"pintle_min_up_alignment": 0.25,
			# Self-correcting guidance means the launch rail doesn't need to
			# snap-track a moving target the way a direct-fire gun does.
			"size": Vector3(0.8, 0.5, 2.0),
			"color": Color.GOLD
		},
		"missile_pod": {
			"name": "Swarm Missile Pod",
			"category": "weapon",
			"required_building": "tech_lab",
			# Indirect fire - needs open sky, so it is levelled on a vertical
			# face but never enclosed in a sponson housing. See
			# ModuleCatalog.is_sponson_capable().
			"sponson_capable": false,
			"hp": 100.0,
			"weight": 150.0,
			"base_traverse": 0.576,
			"metal": 50,
			"crystal": 10,
			"dps": 72.0,
			# A boxy multi-tube launcher, unguided at launch (swarm-fire, not
			# precision-guided per shot) - wants a more level base than a
			# single guided missile does, but nowhere near as strict as a
			# mortar's ballistic-arc requirement.
			"pintle_min_up_alignment": 0.35,
			# Boxy multi-tube launcher, unguided at launch - needs to actually
			# aim the whole pod rather than let guidance correct after the
			# fact, so it traverses slower than the guided missiles above.
			"size": Vector3(1.6, 1.2, 2.2),
			"color": Color.DARK_ORANGE
		},
		"drone_carrier": {
			"name": "Drone Carrier Bay",
			"category": "module",
			"required_building": "exotics_lab",
			"hp": 250.0,
			"weight": 350.0,
			"metal": 180,
			"crystal": 90,
			"dps": 85.0,
			"size": Vector3(2.0, 1.2, 3.0),
			"color": Color.NAVY_BLUE
		},

		# --- AOE & AREA DENIAL ---
		"cluster_dispenser": {
			"name": "Cluster Dispenser",
			"category": "weapon",
			"required_building": "tech_lab",
			# Indirect fire - needs open sky, so it is levelled on a vertical
			# face but never enclosed in a sponson housing. See
			# ModuleCatalog.is_sponson_capable().
			"sponson_capable": false,
			"hp": 90.0,
			"weight": 100.0,
			"base_traverse": 0.540,
			"metal": 45,
			"crystal": 10,
			"dps": 65.0,
			# Lobs submunitions in an area pattern - close enough to
			# mortar_array's ballistic-arc reasoning to want a fairly level
			# base, though the shorter lob range makes it a bit more
			# forgiving than a dedicated indirect-fire mortar.
			"pintle_min_up_alignment": 0.45,
			# Lobbing arc weapon like mortar_array/plasma_lobber, but a
			# shorter lob range makes it a bit less deliberate to aim.
			"size": Vector3(2.0, 1.2, 2.0),
			"color": Color.CHOCOLATE
		},
		"flamethrower": {
			"name": "Flamethrower Emitter",
			"category": "weapon",
			"hp": 70.0,
			"weight": 50.0,
			"base_traverse": 1.647,
			# A hose-fed nozzle, not a rigid ballistic tube - shrugs off a
			# steep mounting angle same as the light autoguns.
			"pintle_min_up_alignment": 0.15,
			# A free-swinging hose, not a rigid barrel - whips onto a target
			# fast, forgiving of imprecise aim since it hits an area anyway.
			# Balance pass: value/cost was 5.49 against a 2.86 category
			# average - cheap for its dps relative to comparable short-range
			# weapons (heavy_machine_gun aside, which is an intentionally
			# cheap starter weapon and left alone).
			"metal": 35,
			"crystal": 15,
			"dps": 112.0,
			"size": Vector3(0.6, 0.6, 2.0),
			"color": Color.CRIMSON
		},

		# --- ENERGY WEAPONS ---
		# "energy" damage_class weapons (ENERGY_AND_BALANCE_SPEC.md #4) - the
		# only weapons that cost the firing unit's own current_energy per
		# shot and, for tesla_coil/ion_cannon, also drain the TARGET's
		# energy pool alongside HP damage.
		"tesla_coil": {
			"name": "Tesla Coil",
			"category": "weapon",
			"hp": 70.0,
			"weight": 70.0,
			"base_traverse": 0.876,
			"metal": 40,
			"crystal": 45,
			"dps": 72.0,
			# Tall and top-heavy (size.y=1.6 vs a 0.6x0.6 footprint) - a real
			# structure this slender wants a level base to not look/feel like
			# it's about to topple, so it's less tolerant of a steep slope
			# than the compact autoguns.
			"pintle_min_up_alignment": 0.4,
			# Tall, top-heavy precision emitter - deliberate, controlled
			# traverse rather than a fast snap-track.
			"size": Vector3(1.0, 3.0, 1.0),
			"color": Color.LIGHT_SKY_BLUE
		},
		"ion_cannon": {
			"name": "Ion Cannon",
			"category": "weapon",
			"hp": 130.0,
			"weight": 150.0,
			"base_traverse": 0.540,
			# The heaviest, longest energy weapon (2.6 long, 150kg) - wants a
			# more stable base than the compact energy emitters, similar
			# reasoning to the heavier kinetic guns.
			"pintle_min_up_alignment": 0.4,
			# Heaviest, longest energy weapon - a stable, deliberate-aim
			# platform rather than a fast tracker.
			# Balance pass: was the single worst value/cost weapon in the
			# game (1.03 vs 2.86 average) even before accounting for its
			# energy-drain utility (which this cost-model can't see) - the
			# heavy crystal cost was double-counted against a flagship
			# "grounded energy heavy-hitter" that's supposed to be a real
			# alternative to gauss_railgun/plasma_lobber, not strictly worse.
			"metal": 70,
			"crystal": 65,
			"dps": 97.5,
			"size": Vector3(1.5, 1.5, 4.5),
			"color": Color.SKY_BLUE
		},
		# Activating a module that was already 80% built: fire profile, fire
		# function, energy-drain maths, tweak specs and an authored mesh all
		# existed, but with no catalog entry it could never be placed. The
		# dedicated disabler - trivial HP damage, enormous energy drain.
		# --- INDIRECT FIRE EXPANSION ---------------------------------------
		# The bomb is bigger than the weapon. A spigot mortar has no barrel:
		# the projectile slides over a rod. Enormous splash, derisory range -
		# a demolition tool that has to be driven up to what it demolishes.
		"spigot_mortar": {
			"name": "Spigot Mortar",
			"category": "weapon",
			# Indirect fire - needs open sky, so it is levelled on a vertical
			# face but never enclosed in a sponson housing. See
			# ModuleCatalog.is_sponson_capable().
			"sponson_capable": false,
			"hp": 80.0,
			"weight": 130.0,
			"base_traverse": 0.428,
			"metal": 38,
			"crystal": 0,
			"dps": 55.0,
			"size": Vector3(1.0, 1.0, 1.8),
			"color": Color(0.32, 0.34, 0.28)
		},

		# Saturation rather than precision: a rack of rails that empties fast
		# and then spends a long time reloading, which is the whole trade.
		"rocket_artillery": {
			"name": "Rocket Artillery",
			"category": "weapon",
			# Indirect fire - needs open sky, so it is levelled on a vertical
			# face but never enclosed in a sponson housing. See
			# ModuleCatalog.is_sponson_capable().
			"sponson_capable": false,
			"hp": 95.0,
			"weight": 190.0,
			"base_traverse": 0.379,
			"metal": 52,
			"crystal": 8,
			"dps": 85.0,
			"size": Vector3(2.0, 1.8, 5.5),
			"color": Color(0.30, 0.33, 0.28)
		},

		# --- MISSILE EXPANSION ---------------------------------------------
		# Beam-riding kinetic darts. No warhead - the round IS the damage -
		# and fast enough that point defence struggles, which is what it buys
		# with its short reach and its need to hold a designator on target.
		"hypervelocity_missile": {
			"name": "Hypervelocity Missile",
			"category": "weapon",
			# Indirect fire - needs open sky, so it is levelled on a vertical
			# face but never enclosed in a sponson housing. See
			# ModuleCatalog.is_sponson_capable().
			"sponson_capable": false,
			"hp": 70.0,
			"weight": 110.0,
			"base_traverse": 0.854,
			"metal": 34,
			"crystal": 18,
			"dps": 92.0,
			"size": Vector3(0.8, 0.6, 3.0),
			"color": Color(0.30, 0.32, 0.34)
		},

		# Air only. Useless against anything on the ground, and the longest
		# reach against anything that isn't.
		"sam_launcher": {
			"name": "SAM Launcher",
			"category": "weapon",
			# Indirect fire - needs open sky, so it is levelled on a vertical
			# face but never enclosed in a sponson housing. See
			# ModuleCatalog.is_sponson_capable().
			"sponson_capable": false,
			"hp": 75.0,
			"weight": 130.0,
			"base_traverse": 0.857,
			"metal": 40,
			"crystal": 20,
			"dps": 70.0,
			"size": Vector3(1.5, 1.2, 4.0),
			"color": Color(0.33, 0.35, 0.33)
		},

		# Launches, circles, then dives. The longest reach in the roster,
		# bought with a long flight time before anything happens at all.
		"loitering_munition": {
			"name": "Loitering Munition",
			"category": "weapon",
			# Indirect fire - needs open sky, so it is levelled on a vertical
			# face but never enclosed in a sponson housing. See
			# ModuleCatalog.is_sponson_capable().
			"sponson_capable": false,
			"hp": 65.0,
			"weight": 120.0,
			"base_traverse": 0.733,
			"metal": 36,
			"crystal": 22,
			"dps": 65.0,
			"size": Vector3(1.0, 0.8, 2.5),
			"color": Color(0.28, 0.31, 0.27)
		},

		# Only locks units carrying sensors, which turns radar into a
		# liability and makes it the one weapon whose usefulness depends
		# entirely on what the enemy chose to build.
		"anti_radiation_missile": {
			"name": "Anti-Radiation Missile",
			"category": "weapon",
			# Indirect fire - needs open sky, so it is levelled on a vertical
			# face but never enclosed in a sponson housing. See
			# ModuleCatalog.is_sponson_capable().
			"sponson_capable": false,
			"hp": 70.0,
			"weight": 115.0,
			"base_traverse": 0.792,
			"metal": 33,
			"crystal": 26,
			"dps": 75.0,
			"size": Vector3(0.8, 0.8, 2.6),
			"color": Color(0.29, 0.31, 0.30)
		},

		# Top-attack anti-structure. Heavily biased toward buildings, and
		# clumsy against anything that moves.
		"bunker_buster": {
			"name": "Bunker Buster",
			"category": "weapon",
			# Indirect fire - needs open sky, so it is levelled on a vertical
			# face but never enclosed in a sponson housing. See
			# ModuleCatalog.is_sponson_capable().
			"sponson_capable": false,
			"hp": 85.0,
			"weight": 175.0,
			"base_traverse": 0.331,
			"metal": 48,
			"crystal": 16,
			"dps": 95.0,
			"size": Vector3(1.0, 1.0, 3.6),
			"color": Color(0.27, 0.28, 0.30)
		},

		# Long range, slow, big warhead, and very interceptable - the missile
		# point defence exists to eat. Ships in a sealed container.
		"cruise_missile": {
			"name": "Cruise Missile",
			"category": "weapon",
			# Indirect fire - needs open sky, so it is levelled on a vertical
			# face but never enclosed in a sponson housing. See
			# ModuleCatalog.is_sponson_capable().
			"sponson_capable": false,
			"hp": 80.0,
			"weight": 200.0,
			"base_traverse": 0.246,
			"metal": 55,
			"crystal": 24,
			"dps": 88.0,
			"size": Vector3(1.2, 1.2, 4.0),
			"color": Color(0.31, 0.33, 0.29)
		},

		# --- POINT DEFENSE EXPANSION ---------------------------------------
		# Consumable lock-break. Unlike smoke it does not obscure vision - it
		# breaks a seeker's lock directly and then it is gone.
		"chaff_dispenser": {
			"name": "Chaff Dispenser",
			"category": "weapon",
			"hp": 45.0,
			"weight": 35.0,
			"base_traverse": 1.603,
			"metal": 16,
			"crystal": 4,
			"dps": 0.0,
			"size": Vector3(0.8, 0.6, 0.8),
			"color": Color(0.42, 0.44, 0.38)
		},

		# Directional seeker blinding. Has to be pointed, so it competes for
		# arc with a real weapon - which is its cost.
		"laser_dazzler": {
			"name": "Laser Dazzler",
			"category": "weapon",
			"hp": 50.0,
			"weight": 55.0,
			"base_traverse": 2.001,
			"metal": 18,
			"crystal": 22,
			"dps": 4.0,
			"size": Vector3(0.8, 0.8, 1.2),
			"color": Color(0.36, 0.42, 0.46)
		},

		# Hard kill. Covers the whole arc at once rather than traversing,
		# which is what an active protection system does - and why it has
		# almost no range.
		"aps_interceptor": {
			"name": "APS Interceptor",
			"category": "weapon",
			"hp": 60.0,
			"weight": 75.0,
			"base_traverse": 2.109,
			"metal": 28,
			"crystal": 14,
			"dps": 26.0,
			"size": Vector3(0.8, 0.6, 0.8),
			"color": Color(0.34, 0.36, 0.38)
		},

		# Dedicated flak. Engages AIRCRAFT, not just incoming munitions,
		# which is the gap between the CIWS and having no answer to air.
		"aa_autocannon": {
			"name": "AA Autocannon",
			"category": "weapon",
			"hp": 80.0,
			"weight": 125.0,
			"base_traverse": 1.194,
			"metal": 42,
			"crystal": 6,
			"dps": 68.0,
			"size": Vector3(1.2, 1.0, 2.5),
			"color": Color(0.28, 0.31, 0.27)
		},

		# Passive aura. No barrel, no traverse, no shot - it degrades guided
		# weapons within its radius simply by existing, and advertises the
		# vehicle's position while doing it.
		"jammer_mast": {
			"name": "Jammer Mast",
			"category": "weapon",
			"hp": 55.0,
			"weight": 70.0,
			"base_traverse": 0.876,
			"metal": 22,
			"crystal": 30,
			"dps": 0.0,
			"size": Vector3(0.8, 3.5, 0.8),
			"color": Color(0.33, 0.37, 0.35)
		},

		# --- DEPLOYABLE EXPANSION ------------------------------------------
		# Drops an autonomous turret that fights on after the carrier leaves.
		"sentry_deployer": {
			"name": "Sentry Deployer",
			"category": "weapon",
			"hp": 75.0,
			"weight": 140.0,
			"base_traverse": 0.524,
			"metal": 46,
			"crystal": 12,
			"dps": 45.0,
			"size": Vector3(1.2, 1.0, 1.5),
			"color": Color(0.31, 0.34, 0.27)
		},

		# Lobs a beacon that reveals fog where it lands. Reuses the reveal
		# beacons built for illumination ammo - vision as a weapon.
		"sensor_beacon_launcher": {
			"name": "Sensor Beacon Launcher",
			"category": "weapon",
			"hp": 55.0,
			"weight": 60.0,
			"base_traverse": 1.311,
			"metal": 22,
			"crystal": 18,
			"dps": 0.0,
			# Scaled with VISION_SCALE - a vision bonus is added to a hull's
			# post-scale base_vision, so leaving these on the authoring scale
			# would quietly shrink every sensor module relative to the band it
			# is meant to extend.
			"vision_bonus": 5.5,
			"size": Vector3(0.8, 0.6, 1.2),
			"color": Color(0.34, 0.40, 0.36)
		},

		# Deploys a false contact that draws fire. Zero damage; its entire
		# output is other people's wasted shots.
		"decoy_projector": {
			"name": "Decoy Projector",
			"category": "weapon",
			"hp": 50.0,
			"weight": 50.0,
			"base_traverse": 1.318,
			"metal": 20,
			"crystal": 10,
			"dps": 0.0,
			"size": Vector3(0.8, 0.6, 0.8),
			"color": Color(0.38, 0.39, 0.32)
		},

		# --- PAINT REFERENCE PATCHES (non-placeable) -------------------------
		# Stats source for ArmorPaint.PAINT_TYPE_IDS: a row per paintable armor
		# material, kept here so designers can tune hp/weight/metal/crystal in
		# one place. NOT placeable as modules - module_placer.gd:1061 skips
		# everything in PAINT_TYPE_IDS, leaving only energy_barrier_projector as
		# a real "category: armor" module. Three of the four damage-class biases
		# (FABLE_REVIEW.md 1.2) live in ARMOR_MODULE_BIAS, not on these rows -
		# the rows carry the patch cost, the resolver reads the bias.
		"slat_armor": {
			"name": "Slat Armor",
			"category": "armor",
			"hp": 260.0,
			"weight": 45.0,
			"metal": 22,
			"crystal": 0,
			"dps": 0.0,
			"size": Vector3(2.0, 0.25, 2.0),
			"color": Color(0.40, 0.42, 0.36)
		},
		"spaced_composite": {
			"name": "Spaced Composite",
			"category": "armor",
			"required_building": "tech_lab",
			"hp": 620.0,
			"weight": 155.0,
			"metal": 68,
			"crystal": 10,
			"dps": 0.0,
			"size": Vector3(2.0, 0.3, 2.0),
			"color": Color(0.44, 0.45, 0.46)
		},
		"ablative_foam": {
			"name": "Ablative Foam",
			"category": "armor",
			"required_building": "tech_lab",
			"hp": 340.0,
			"weight": 70.0,
			"metal": 26,
			"crystal": 14,
			"dps": 0.0,
			"size": Vector3(2.0, 0.28, 2.0),
			"color": Color(0.60, 0.58, 0.50)
		},

		"arc_projector": {
			"name": "Arc Projector",
			"category": "weapon",
			"required_building": "tech_lab",
			"hp": 70.0,
			"weight": 85.0,
			"base_traverse": 0.886,
			"metal": 24,
			"crystal": 26,
			"dps": 22.0,
			"energy_capacity": 0.0,
			"size": Vector3(0.8, 0.8, 1.8),
			"color": Color(0.30, 0.40, 0.48)
		},

		# Area denial by cooking electronics. The counter to energy-hungry
		# designs specifically, which nothing else in the roster targets.
		"microwave_emitter": {
			"name": "Microwave Emitter",
			"category": "weapon",
			"required_building": "tech_lab",
			"hp": 65.0,
			"weight": 105.0,
			"base_traverse": 0.657,
			"metal": 30,
			"crystal": 32,
			"dps": 30.0,
			"size": Vector3(1.0, 0.8, 1.5),
			"color": Color(0.52, 0.50, 0.42)
		},

		# Charge, then one devastating beam. The heaviest and most expensive
		# weapon in the roster, and the only one that can be caught mid-charge.
		"particle_lance": {
			"name": "Particle Lance",
			"category": "weapon",
			"required_building": "exotics_lab",
			"hp": 90.0,
			"weight": 220.0,
			"base_traverse": 0.262,
			"metal": 60,
			"crystal": 55,
			"dps": 120.0,
			"size": Vector3(1.2, 1.2, 5.5),
			"color": Color(0.34, 0.44, 0.52)
		},

		"heavy_laser": {
			"name": "Continuous Laser",
			"category": "weapon",
			"hp": 75.0,
			"weight": 60.0,
			"base_traverse": 0.894,
			"metal": 30,
			"crystal": 20,
			"dps": 112.0,
			# A precision continuous beam over a long (2.5) housing benefits
			# from a stable base for sustained aim - same logic as heavy_laser's
			# kinetic-precision cousins.
			"pintle_min_up_alignment": 0.4,
			# Continuous-beam precision weapon over a long housing - benefits
			# from a stable, deliberate traverse for sustained aim.
			"size": Vector3(1.0, 1.0, 3.5),
			"color": Color.DARK_RED
		},
		"plasma_lobber": {
			"name": "Plasma Lobber",
			"category": "weapon",
			"required_building": "exotics_lab",
			# Indirect fire - needs open sky, so it is levelled on a vertical
			# face but never enclosed in a sponson housing. See
			# ModuleCatalog.is_sponson_capable().
			"sponson_capable": false,
			"hp": 110.0,
			"weight": 120.0,
			"base_traverse": 0.448,
			"metal": 50,
			"crystal": 60,
			"dps": 95.0,
			# "Lobber" is in the name - an arcing projectile weapon, same
			# ballistic-baseline reasoning as mortar_array/cluster_dispenser.
			"pintle_min_up_alignment": 0.5,
			# Arcing lob weapon, same slow-deliberate character as the
			# mortars/cluster_dispenser.
			"size": Vector3(1.2, 1.2, 2.5),
			"color": Color.MEDIUM_SPRING_GREEN
		},

		# --- POINT DEFENSE ---
		"ciws": {
			"name": "CIWS Gatling PD",
			"category": "weapon",
			"hp": 80.0,
			"weight": 90.0,
			"base_traverse": 1.717,
			"metal": 40,
			"crystal": 15,
			"dps": 10.0, # Visual DPS low, specialized vs ammo
			# Real-world CIWS mounts are routinely bolted to steeply angled
			# deck/superstructure positions and still track fine - tolerant.
			"pintle_min_up_alignment": 0.15,
			# Point defense lives and dies by how fast it can snap onto a
			# small, fast-moving threat - the quickest traverse in the roster.
			"size": Vector3(1.2, 3.0, 1.2),
			"color": Color.WHITE_SMOKE
		},
		"pd_laser": {
			"name": "Point Defense Laser",
			"category": "weapon",
			"hp": 50.0,
			"weight": 35.0,
			"base_traverse": 2.565,
			"metal": 20,
			"crystal": 30,
			# Small, light PD turret - tolerant like the other compact
			# point-defense/autogun weapons.
			"pintle_min_up_alignment": 0.15,
			# Small, light PD laser - the second-fastest tracker after CIWS,
			# same reflex-driven point-defense logic.
			"dps": 5.0,
			"size": Vector3(0.6, 0.8, 0.6),
			"color": Color.LIGHT_CORAL
		},
		"flak_cannon": {
			"name": "Flak Cannon PD",
			"category": "weapon",
			"required_building": "tech_lab",
			"hp": 90.0,
			"weight": 110.0,
			"base_traverse": 1.196,
			"metal": 45,
			"crystal": 10,
			"dps": 15.0,
			# Bulkier than the other PD weapons (110kg, boxier housing) but
			# still an anti-air mount that needs to swing to steep elevations
			# routinely - moderate tolerance, between the light PD guns and
			# the heavier precision/ballistic weapons.
			"pintle_min_up_alignment": 0.3,
			# Bulkier than the other PD weapons but still needs to swing to
			# steep anti-air elevations routinely - fast, just not CIWS-fast.
			"size": Vector3(1.0, 1.0, 2.8),
			"color": Color.DARK_GOLDENROD
		},

		# --- ROSTER EXPANSION: new base archetypes ---------------------------
		# Each of these fills a gap the existing roster genuinely had rather
		# than being a stat-shifted copy of something already present - the
		# "arsenal pool is incredibly WIDE" principle in
		# Arsenal_Weapons_List.md's own preamble.

		# The hole between mortar_array (slow, heavy, high arc) and
		# heavy_machine_gun (fast, flat, no splash): belt-fed rapid-fire
		# grenades. Small blast per round, but a lot of rounds.
		"mk19_grenade_launcher": {
			"name": "MK19 Grenade Launcher",
			"category": "weapon",
			"hp": 70.0,
			"weight": 55.0,
			"base_traverse": 1.375,
			"metal": 28,
			"crystal": 0,
			"dps": 58.0,
			# Belt-fed and shoulder-height in real life - a classic pintle
			# weapon, though its low arc wants a slightly better stance than
			# a pure flat-shooting autogun.
			"pintle_min_up_alignment": 0.3,
			"size": Vector3(0.4, 0.4, 0.8),
			"color": Color(0.32, 0.36, 0.22)
		},

		# Huge per-shot HEAT damage on a light, cheap mount, paid for with a
		# brutal reload AND a genuine backblast danger zone behind the
		# weapon (see auto_weapon.gd's _fire_recoilless_rifle) - the first
		# weapon in the roster where WHERE you mount it has a real
		# mechanical consequence, not just an arc consequence.
		"recoilless_rifle": {
			"name": "Recoilless Rifle",
			"category": "weapon",
			# Indirect fire - needs open sky, so it is levelled on a vertical
			# face but never enclosed in a sponson housing. See
			# ModuleCatalog.is_sponson_capable().
			"sponson_capable": false,
			"hp": 80.0,
			"weight": 70.0,
			"base_traverse": 0.986,
			"metal": 40,
			"crystal": 5,
			"dps": 85.0,
			"pintle_min_up_alignment": 0.25,
			"size": Vector3(0.5, 0.5, 1.5),
			"color": Color(0.42, 0.40, 0.34)
		},

		# The sane sibling to gauss_railgun: genuinely turreted (pintle, not
		# frame_built), less per-shot punch, roughly twice the cycle rate,
		# and far cheaper on crystal. Gives a mid-tier design a way into
		# hitscan kinetic without committing a whole hull to a fixed rail.
		"coil_gun": {
			"name": "Coil Gun",
			"category": "weapon",
			"required_building": "physics_lab",
			"hp": 90.0,
			"weight": 120.0,
			"base_traverse": 0.570,
			"metal": 55,
			"crystal": 30,
			"dps": 88.0,
			"pintle_min_up_alignment": 0.3,
			"size": Vector3(0.8, 0.8, 3.0),
			"color": Color(0.45, 0.62, 0.78)
		},

		# The missing rung between heavy_machine_gun and basic_cannon -
		# rapid enough to matter against light armor, with real per-shot
		# weight behind it.
		"autocannon": {
			"name": "Autocannon",
			"category": "weapon",
			"hp": 75.0,
			"weight": 65.0,
			"base_traverse": 1.426,
			"metal": 26,
			"crystal": 0,
			"dps": 62.0,
			"pintle_min_up_alignment": 0.15,
			"size": Vector3(0.5, 0.5, 1.8),
			"color": Color(0.28, 0.30, 0.32)
		},

		# The roster had no precision weapon at all. Deliberately expensive
		# in crystal (that is the sensor package, not the gun) and slow to
		# traverse - it is an ambush/overwatch piece, not something you
		# swing onto a target that is already close.
		"anti_materiel_rifle": {
			"name": "Anti-Materiel Rifle",
			"category": "weapon",
			"required_building": "tech_lab",
			"hp": 60.0,
			"weight": 95.0,
			"base_traverse": 0.509,
			"metal": 34,
			"crystal": 18,
			"dps": 78.0,
			"pintle_min_up_alignment": 0.20,
			"size": Vector3(0.5, 0.5, 2.2),
			"color": Color(0.24, 0.28, 0.26)
		},

		# Area denial by fire rather than by fragments: modest impact
		# damage, but it leaves a large, long-lived burning pool that
		# makes ground genuinely expensive to stand on.
		"napalm_mortar": {
			"name": "Napalm Mortar",
			"category": "weapon",
			"required_building": "tech_lab",
			# Indirect fire - needs open sky, so it is levelled on a vertical
			# face but never enclosed in a sponson housing. See
			# ModuleCatalog.is_sponson_capable().
			"sponson_capable": false,
			"hp": 85.0,
			"weight": 95.0,
			"base_traverse": 0.463,
			"metal": 42,
			"crystal": 12,
			"dps": 45.0,
			# Arcing tube, same ballistic-baseline reasoning as mortar_array.
			"pintle_min_up_alignment": 0.55,
			"size": Vector3(1.0, 0.8, 1.2),
			"color": Color(0.78, 0.35, 0.12)
		},

		# Nothing in the roster could HOLD ground - every weapon had to keep
		# shooting to keep denying space. Mines persist without the layer,
		# survive its death, and punish a chokepoint indefinitely.
		"mine_layer": {
			"name": "Mine Layer",
			"category": "weapon",
			"required_building": "tech_lab",
			"hp": 90.0,
			"weight": 85.0,
			"base_traverse": 0.787,
			"metal": 45,
			"crystal": 5,
			"dps": 40.0,
			"pintle_min_up_alignment": 0.4,
			"size": Vector3(1.4, 0.8, 1.4),
			"color": Color(0.48, 0.44, 0.26)
		},

		# Straight-faced absurdity, exactly where VISUAL_ART_DIRECTION.md
		# says it belongs: a torsion-spring bolt thrower, bolted to a
		# machine that also mounts railguns. Mechanically it earns its
		# place - enormous per-shot kinetic damage (so it clears armor
		# thresholds outright rather than chipping) at almost no crystal
		# cost, paid for with the slowest cycle in the roster. The cheap
		# answer to heavy armor for a design that can't afford a railgun.
		"ballista": {
			"name": "Ballista",
			"category": "weapon",
			"required_building": "tech_lab",
			# Indirect fire - needs open sky, so it is levelled on a vertical
			# face but never enclosed in a sponson housing. See
			# ModuleCatalog.is_sponson_capable().
			"sponson_capable": false,
			"hp": 110.0,
			"weight": 140.0,
			"base_traverse": 0.337,
			"metal": 35,
			"crystal": 0,
			"dps": 70.0,
			# A big timber-and-torsion frame - it needs a level, solid base
			# the way a mortar does, for much the same reason.
			"pintle_min_up_alignment": 0.5,
			"size": Vector3(2.0, 1.5, 4.0),
			"color": Color(0.44, 0.33, 0.20)
		},

		# The dedicated obscurant launcher (complement to shell-based smoke -
		# see WEAPON_AMMO_OPTIONS). Categorised "weapon" so it gets
		# auto_weapon.gd's targeting/firing logic like every other launcher,
		# but its dps is a real 0.0: it cannot hurt anything, ever. Its whole
		# value is denying sightlines, which the LOS systems now honour.
		# Cheap, light and small enough to bolt onto a corner of anything.
		"smoke_discharger": {
			"name": "Smoke Discharger",
			"category": "weapon",
			"hp": 40.0,
			"weight": 30.0,
			"base_traverse": 2.356,
			"metal": 18,
			"crystal": 0,
			"dps": 0.0,
			# A cluster of stubby mortar tubes on a light bracket - the
			# classic hull-corner discharger, bolts onto almost anything.
			"pintle_min_up_alignment": 0.15,
			# Light, small, and aiming a cloud rather than a point target -
			# it only needs to be pointed roughly the right way.
			"size": Vector3(0.8, 0.6, 0.8),
			"color": Color(0.55, 0.56, 0.58)
		},

		# --- UTILITY & SUPPORT ---
		"resource_harvester": {
			"name": "Resource Harvester",
			"category": "module",
			"hp": 150.0,
			"weight": 80.0,
			"metal": 100,
			"crystal": 50,
			"dps": 0.0,
			"size": Vector3(1.5, 1.0, 1.5),
			"color": Color.DARK_GOLDENROD
		},
		# Cargo volume for a harvester, and nothing else. The harvester loop is
		# drive out, fill up, drive back, unload - so a harvester's real output
		# is capacity divided by round-trip time, and until now the ONLY lever on
		# either half was the extractor arm (which buys fill rate and reach, not
		# volume). Every harvester therefore made the same 50-unit trip whatever
		# the map looked like, which meant a distant crystal patch was simply
		# worse than a near metal one with no design answer available.
		#
		# A bay is the answer: it trades weight - a lot of it, 90kg for a part
		# that shoots nothing - for fewer trips. On a short haul that trade is
		# bad, because the drivetrain penalty costs you more round trips than the
		# volume saves; on a long haul it is the difference between an economy
		# that scales and one that does not. That is the decision the module
		# exists to create, and it is why the weight is deliberately high enough
		# to notice against the new underload speed bonus (see drivetrain.gd):
		# bays are exactly the kind of mass that pushes a light harvester out of
		# its bonus band.
		#
		# Deliberately NOT folded into resource_harvester as another tweak: it
		# stacks, it mounts anywhere on the hull, and "how many bays fit on this
		# chassis" is a shape question the Lab is already good at asking. A
		# slider on the harvester could not express any of that.
		"resource_bay": {
			"name": "Resource Bay",
			"category": "module",
			"hp": 120.0,
			"weight": 90.0,
			"metal": 60,
			"crystal": 10,
			"dps": 0.0,
			"size": Vector3(1.4, 1.0, 1.8),
			"color": Color.DARK_GOLDENROD
		},
		"repair_array": {
			"name": "Repair Welder Array",
			"category": "module",
			"required_building": "tech_lab",
			"hp": 100.0,
			"weight": 70.0,
			"metal": 40,
			"crystal": 20,
			# Real dps: 0.0 - repair_array deals no damage. Its heal-per-
			# second rate is its own dedicated "heal_rate" stat (see
			# module_data.gd's get_heal_rate()), not a reuse of dps, so it
			# no longer pollutes the Design Lab's "Total DPS" aggregate.
			# Previously reused dps as a stopgap - see DECISIONS_NEEDED.md
			# for that history.
			"dps": 0.0,
			"heal_rate": 30.0,
			"targets_allies": true,
			"size": Vector3(0.8, 0.8, 1.0),
			"color": Color.DARK_TURQUOISE
		},
		"sensor_suite": {
			"name": "Radar Mast Suite",
			"category": "module",
			"hp": 60.0,
			"weight": 50.0,
			"metal": 30,
			"crystal": 30,
			"dps": 0.0,
			"vision_bonus": 47.5,
			"size": Vector3(0.5, 2.5, 0.5),
			"color": Color.MEDIUM_PURPLE
		},
		"directional_radar": {
			"name": "Phased Array Sector Radar",
			"category": "module",
			"required_building": "tech_lab",
			"hp": 75.0,
			"weight": 65.0,
			"metal": 40,
			"crystal": 50,
			"dps": 0.0,
			"vision_bonus": 85.0,
			"scan_arc": 60.0,
			"size": Vector3(0.9, 2.2, 0.6),
			"color": Color.ROYAL_BLUE
		},
		"topographic_radar": {
			"name": "Topographic Lidar Surveyor",
			"category": "module",
			"required_building": "tech_lab",
			"hp": 90.0,
			"weight": 75.0,
			"metal": 45,
			"crystal": 60,
			"dps": 0.0,
			"survey_radius": 140.0,
			"size": Vector3(1.2, 2.0, 1.2),
			"color": Color.MEDIUM_SEA_GREEN
		},
		"seismic_sensor": {
			"name": "Seismic Acoustic Array",
			"category": "module",
			"required_building": "physics_lab",
			"hp": 110.0,
			"weight": 85.0,
			"metal": 50,
			"crystal": 25,
			"dps": 0.0,
			"seismic_range": 75.0,
			"size": Vector3(0.8, 1.0, 0.8),
			"color": Color.DARK_SLATE_GRAY
		},
		"thermal_imager": {
			"name": "Cryo FLIR Thermal Imager",
			"category": "module",
			"required_building": "physics_lab",
			"hp": 50.0,
			"weight": 40.0,
			"metal": 25,
			"crystal": 45,
			"dps": 0.0,
			"vision_bonus": 35.0,
			"thermal_sight": true,
			"size": Vector3(0.6, 1.8, 0.6),
			"color": Color.ORANGE_RED
		},
		"laser_designator": {
			"name": "Laser Target Painter",
			"category": "module",
			"required_building": "tech_lab",
			"hp": 80.0,
			"weight": 40.0,
			"metal": 25,
			"crystal": 35,
			"dps": 0.0,
			"size": Vector3(0.6, 0.7, 0.6),
			"color": Color.PALE_VIOLET_RED
		},
		"energy_barrier_projector": {
			"name": "Energy Barrier Projector",
			"category": "armor",
			"required_building": "exotics_lab",
			"hp": 250.0,
			"weight": 110.0,
			"metal": 60,
			"crystal": 50,
			"dps": 0.0,
			"size": Vector3(1.0, 0.4, 1.0),
			"color": Color.DEEP_SKY_BLUE
		},
		"fire_control_radar": {
			"name": "Fire Control Radar",
			"category": "module",
			"required_building": "tech_lab",
			"hp": 90.0,
			"weight": 65.0,
			"metal": 45,
			"crystal": 40,
			"dps": 0.0,
			"size": Vector3(0.7, 1.8, 0.7),
			"color": Color.DODGER_BLUE
		},

		"armor_plating": {
			"name": "Armor Plating",
			"category": "armor",
			"hp": 500.0,
			"weight": 100.0,
			"metal": 50,
			"crystal": 0,
			"dps": 0.0,
			"size": Vector3(2.0, 0.2, 2.0),
			"color": Color.SLATE_GRAY
		},

		# --- GENERATORS (Energy resource, ENERGY_AND_BALANCE_SPEC.md #1) ---
		# "generator" is its own module category, not a weapon/utility
		# variant - it contributes to a unit's power budget exactly like armor
		# contributes to a facet's threshold: a placeable design choice, not a
		# fixed hull number.
		#
		# THE TWO MODULES DO DIFFERENT JOBS, AND THAT IS NEW.
		#
		# Both used to carry energy_capacity AND energy_regen, which made them
		# near-duplicates - the capacitor was simply a smaller, cheaper fusion
		# generator. Worse, it made half of each module's tweaks dead: look at
		# stat_calculator.gd's rows for them. fusion_generator's tweaks are
		# reactor_length and cooling_radiator, which scale REGEN only
		# (module_data.get_power_output). capacitor_bank's are bank_capacity and
		# busbar_gauge, which scale CAPACITY only (get_energy_capacity). So
		# nothing could tune the capacitor's regen and nothing could tune the
		# generator's capacity - four sliders, two of them inert, on two modules
		# whose own tweak lists had already assumed the split the catalog
		# refused to make.
		#
		# Now the split is real, and all four tweaks are live:
		#
		#   fusion_generator  GENERATION - refills the buffer, holds nothing
		#   capacitor_bank    STORAGE    - holds charge, generates nothing
		#
		# Which turns "I need more power" into an actual question. A design that
		# is always slightly short wants a generator. One that is fine except
		# during a firefight wants capacitors: the buffer covers the burst and
		# refills between engagements. The two answers have different weights,
		# different prices and different failure modes, which is the whole point.
		"fusion_generator": {
			"name": "Fusion Generator",
			"category": "generator",
			"required_building": "tech_lab",
			"hp": 140.0,
			"weight": 160.0,
			"metal": 90,
			"crystal": 60,
			"dps": 0.0,
			"energy_capacity": 0.0,
			"power_output": 14.0,
			"size": Vector3(0.56, 0.48, 0.72),
			"color": Color.ORANGE_RED
		},
		"diesel_generator": {
			"name": "Turbine Generator",
			"category": "generator",
			"hp": 110.0,
			"weight": 110.0,
			"metal": 60,
			"crystal": 10,
			"dps": 0.0,
			"energy_capacity": 0.0,
			"power_output": 8.5,
			"size": Vector3(0.48, 0.36, 0.60),
			"color": Color.SLATE_GRAY
		},
		"thermo_generator": {
			"name": "Stirling Generator",
			"category": "generator",
			"hp": 70.0,
			"weight": 55.0,
			"metal": 40,
			"crystal": 20,
			"dps": 0.0,
			"energy_capacity": 0.0,
			"power_output": 4.5,
			"size": Vector3(0.36, 0.28, 0.40),
			"color": Color.PERU
		},
		"capacitor_bank": {
			"name": "Capacitor Bank",
			"category": "generator",
			"hp": 60.0,
			"weight": 50.0,
			"metal": 35,
			"crystal": 25,
			"dps": 0.0,
			"energy_capacity": 45.0,
			"power_output": 0.0,
			"size": Vector3(0.32, 0.32, 0.40),
			"color": Color.GOLD
		},
		"flywheel_storage": {
			"name": "Flywheel Battery",
			"category": "generator",
			"hp": 130.0,
			"weight": 140.0,
			"metal": 80,
			"crystal": 15,
			"dps": 0.0,
			"energy_capacity": 85.0,
			"power_output": 0.0,
			"size": Vector3(0.48, 0.36, 0.48),
			"color": Color.CADET_BLUE
		},
		"solid_state_battery": {
			"name": "Solid-State Battery",
			"category": "generator",
			"hp": 80.0,
			"weight": 70.0,
			"metal": 45,
			"crystal": 40,
			"dps": 0.0,
			"energy_capacity": 60.0,
			"power_output": 0.0,
			"size": Vector3(0.44, 0.24, 0.56),
			"color": Color.STEEL_BLUE
		},

		# --- PROPULSION MODULES ---
		# Speed as a real, affectable stat (2026-08-08): weight, armor and every
		# module up to now only ever COST speed - there was no "go faster"
		# decision anywhere in the Design Lab. These are ordinary category
		# "module" parts, not a new locomotion category: they carry no
		# base_top_speed/base_weight_capacity of their own and mount on any
		# hull, contributing through the same weight_capacity_bonus/
		# thrust_bonus hooks every mobility add-on already used (see
		# Drivetrain.analyze()), plus two new hooks - top_speed_mult and
		# capacity_mult - that raise or trade against the chassis ceiling
		# itself. A hull carrying only one of these and no weapon/support
		# module is still correctly an illegal build (validate_build_legality
		# never treats "module" category as satisfying that check on its own).
		#
		# role "Propulsion" (see MODULE_ROLES/MODULE_ROLE_ORDER below) routes
		# them to the Design Lab's Drives toolbox alongside the locomotion
		# types they modify, not into Support with the generators.
		"turbocharger": {
			"name": "Turbocharger",
			"category": "module",
			"description": "Forced induction for the drivetrain. Real thrust, real weight - does nothing once the chassis is already at its own speed ceiling.",
			"hp": 45.0,
			"weight": 40.0,
			"metal": 30,
			"crystal": 5,
			"dps": 0.0,
			# Pure thrust, no ceiling change - the honest turbo. A design
			# already capacity_limited (see Drivetrain.analyze()) gains
			# nothing from this, and the Lab says so.
			"thrust_bonus": 90.0,
			"size": Vector3(0.6, 0.5, 0.6),
			"color": Color(0.5, 0.5, 0.55)
		},
		"overdrive_gearbox": {
			"name": "Overdrive Gearbox",
			"category": "module",
			"description": "Taller final drive gearing. Raises the chassis's own speed ceiling; trades away some of its load capacity to do it.",
			"hp": 50.0,
			"weight": 45.0,
			"metal": 35,
			"crystal": 10,
			"dps": 0.0,
			# The pure trade: +18% chassis ceiling for -15% capacity. Unlike
			# turbocharger, this raises the ceiling itself, so it helps a
			# design that is ALREADY capacity_limited - which is exactly the
			# case a bigger engine cannot fix.
			"top_speed_mult": 1.18,
			"capacity_mult": 0.85,
			"size": Vector3(0.55, 0.55, 0.7),
			"color": Color(0.45, 0.42, 0.4)
		},
		"hub_motor_array": {
			"name": "Electric Hub Motors",
			"category": "module",
			"description": "Direct-drive motors at each wheel or drum. Real thrust and a real ceiling gain, paid for out of the power budget rather than the load budget.",
			"hp": 40.0,
			"weight": 35.0,
			"metal": 25,
			"crystal": 35,
			"dps": 0.0,
			"thrust_bonus": 70.0,
			"top_speed_mult": 1.08,
			"size": Vector3(0.5, 0.4, 0.5),
			"color": Color(0.3, 0.55, 0.75)
		},
		"nitrous_injector": {
			"name": "Coolant Injection",
			"category": "module",
			"description": "A chemical speed burst: markedly faster for a short window, then a real cooldown before it can fire again. Drains the energy buffer while lit.",
			"hp": 30.0,
			"weight": 25.0,
			"metal": 15,
			"crystal": 15,
			"dps": 0.0,
			# See BoostController - the burst is applied to live movement, not
			# to this design-time analysis, so it never inflates the quoted
			# top speed. duration/cooldown in seconds; energy_per_sec drains
			# the buffer only while the boost is actually lit.
			"boost": {"speed_mult": 1.45, "duration": 5.0, "cooldown": 14.0, "energy_per_sec": 6.0, "charges": 0},
			"size": Vector3(0.5, 0.5, 0.9),
			"color": Color(0.65, 0.85, 0.95)
		},
		"booster_rack": {
			"name": "Solid-Fuel Booster Rack",
			"category": "module",
			"description": "Strap-on solid rocket motors. Absurd and short-lived: three of the hardest kicks in the game, and once they're spent, they're spent.",
			"hp": 35.0,
			"weight": 55.0,
			"metal": 40,
			"crystal": 5,
			"dps": 0.0,
			# The wild card. No cooldown at all - only three charges, ever,
			# for this design's whole battle. Heavy enough that fitting it is
			# a real decision, not a free extra gear.
			"boost": {"speed_mult": 2.2, "duration": 2.5, "cooldown": 0.0, "energy_per_sec": 0.0, "charges": 3},
			"size": Vector3(0.9, 0.5, 1.1),
			"color": Color(0.75, 0.25, 0.2)
		},

		"grav_lifter_assist": {
			"name": "Grav-Lifter Assist",
			"category": "module",
			"required_building": "exotics_lab",
			"description": "Provides a clean 25% boost to load capacity with no speed penalty.",
			"hp": 55.0,
			"weight": 35.0,
			"metal": 40,
			"crystal": 85,
			"dps": 0.0,
			"capacity_mult": 1.25,
			"size": Vector3(0.7, 0.3, 0.7),
			"color": Color(0.3, 0.7, 0.9)
		},
		"jet_thrusters": {
			"name": "Jet Thrusters",
			"category": "module",
			"required_building": "tech_lab",
			"description": "Extreme speed upgrade. High thrust and raises the chassis speed ceiling, at the cost of high energy drain.",
			"hp": 60.0,
			"weight": 75.0,
			"metal": 60,
			"crystal": 40,
			"dps": 0.0,
			"thrust_bonus": 150.0,
			"top_speed_mult": 1.25,
			"capacity_mult": 0.90,
			"size": Vector3(0.8, 0.6, 1.2),
			"color": Color(0.8, 0.3, 0.1)
		},

		# --- LOCOMOTION ARCHETYPES ---
		"wheels": {
			"name": "Wheels",
			"category": "locomotion",
			"hp": 100.0,
			"weight": 50.0,
			"metal": 20,
			"crystal": 0,
			"dps": 0.0,
			# Weight capacity (task: "weight in excess of what a locomotor is
			# built for slows the unit down" - see get_base_weight_capacity()
			# below): a light, high-speed wheeled chassis handles poorly
			# overloaded - a real overloaded car sags and struggles - so this
			# tolerates less excess weight than the heavier ground types.
			"base_weight_capacity": 360.0,
			# Base top speed (Chris: "each locomotor should also have a base
			# top speed"): the hard ceiling on how fast this chassis can be
			# driven, however much thrust is bolted to it. Replaces the single
			# universal 18.0 clamp every type used to share - see
			# Drivetrain.analyze() and get_base_top_speed() below.
			# Fastest thing that touches the ground - the archetype's whole
			# point, and what its low capacity pays for.
			#
			# 15.0, not the original 12.0 (2026-08-08 speed pass): the mainline
			# ground band was too flat top-to-bottom to read as different
			# vehicles, so the fast end was pushed further from it rather than
			# the slow end pulled up.
			"base_top_speed": 15.0,
			"size": Vector3(0.6, 0.6, 0.6),
			"color": Color.BLACK,
			"traits": ["ground_contact", "high_speed"]
		},
		"tracked_treads": {
			"name": "Tracked Treads",
			"category": "locomotion",
			"hp": 200.0,
			"weight": 120.0,
			"metal": 40,
			"crystal": 0,
			"dps": 0.0,
			# Heaviest, toughest ground locomotor - literally what tanks use
			# to carry heavy armor. Highest ground-type capacity.
			"base_weight_capacity": 1080.0,
			# Base top speed (Chris: "each locomotor should also have a base
			# top speed"): the hard ceiling on how fast this chassis can be
			# driven, however much thrust is bolted to it. Replaces the single
			# universal 18.0 clamp every type used to share - see
			# Drivetrain.analyze() and get_base_top_speed() below.
			# Tanks are not fast. Middling ceiling to go with the roster's
			# highest ground capacity.
			#
			# 9.0, not 8.0 (2026-08-08 speed pass): part of a general lift to
			# the whole band, kept proportionally behind wheels.
			"base_top_speed": 9.0,
			"size": Vector3(0.8, 0.6, 2.5),
			"color": Color.DARK_OLIVE_GREEN,
			"traits": ["ground_contact"]
		},
		"heavy_quad_tracks": {
			"name": "Heavy Quad Tracks",
			"category": "locomotion",
			"hp": 250.0,
			"weight": 180.0,
			"metal": 60,
			"crystal": 10,
			"dps": 0.0,
			"base_weight_capacity": 1500.0,
			"base_top_speed": 7.5,
			"size": Vector3(0.9, 0.7, 1.4),
			"color": Color.DARK_SLATE_GRAY,
			"traits": ["ground_contact"]
		},
		"helicopter_rotors": {
			"name": "Helicopter Rotors",
			"category": "locomotion",
			"required_building": "tech_lab",
			"hp": 30.0,
			"weight": 30.0,
			"metal": 30,
			"crystal": 10,
			"dps": 0.0,
			# Real helicopters have a notoriously strict max-takeoff-weight -
			# rotary lift is the most weight-sensitive locomotion in the
			# roster, so this gets the lowest capacity of all.
			"base_weight_capacity": 252.0,
			# Base top speed (Chris: "each locomotor should also have a base
			# top speed"): the hard ceiling on how fast this chassis can be
			# driven, however much thrust is bolted to it. Replaces the single
			# universal 18.0 clamp every type used to share - see
			# Drivetrain.analyze() and get_base_top_speed() below.
			# Quick, but rotary lift trades forward speed for the ability to
			# hover - a fixed wing outruns it comfortably.
			#
			# 13.0, not 11.0 (2026-08-08 speed pass): the air band was widened
			# along with the ground band, keeping the same ordering.
			"base_top_speed": 13.0,
			"size": Vector3(4.0, 0.2, 4.0),
			"color": Color.SILVER,
			"traits": ["airborne", "rotary_wing", "hovering"]
		},
		"hover_engine": {
			"name": "Hover Pad",
			"category": "locomotion",
			"required_building": "tech_lab",
			"hp": 50.0,
			"weight": 20.0,
			"metal": 20,
			"crystal": 40,
			"dps": 0.0,
			# Ground-effect lift is weight-sensitive like a real hovercraft,
			# though less extreme than a helicopter's rotor lift.
			"base_weight_capacity": 279.0,
			# Base top speed (Chris: "each locomotor should also have a base
			# top speed"): the hard ceiling on how fast this chassis can be
			# driven, however much thrust is bolted to it. Replaces the single
			# universal 18.0 clamp every type used to share - see
			# Drivetrain.analyze() and get_base_top_speed() below.
			# Nothing is dragging on the ground, so this is the fastest
			# ground-following option in the roster.
			#
			# 16.0, not 13.0 (2026-08-08 speed pass): part of the general lift,
			# kept ahead of wheels since nothing here touches the ground.
			"base_top_speed": 16.0,
			"size": Vector3(1.2, 0.3, 1.2),
			"color": Color.CYAN,
			"traits": ["hovering"]
		},
		"legs": {
			"name": "Mechanical Legs",
			"category": "locomotion",
			"hp": 120.0,
			"weight": 80.0,
			"metal": 40,
			"crystal": 10,
			"dps": 0.0,
			# A mech walker's legs are built to bear real structural load,
			# closer to tracked_treads than to a wheeled chassis.
			"base_weight_capacity": 468.0,
			# Base top speed (Chris: "each locomotor should also have a base
			# top speed"): the hard ceiling on how fast this chassis can be
			# driven, however much thrust is bolted to it. Replaces the single
			# universal 18.0 clamp every type used to share - see
			# Drivetrain.analyze() and get_base_top_speed() below.
			# Slowest of the mainline ground types: a walking gait cannot be
			# geared up the way a wheel can, whatever you power it with.
			#
			# 7.0, not 6.5 (2026-08-08 speed pass): the smallest bump in the
			# roster, on purpose - legs stay the archetype's floor.
			"base_top_speed": 7.0,
			"size": Vector3(0.5, 1.5, 0.5),
			"color": Color.DARK_RED,
			"traits": ["ground_contact"]
		},
		"fixed_wing_engine": {
			"name": "AGP Strike Drive",
			"category": "locomotion",
			"required_building": "tech_lab",
			"description": "Atmospheric Gravity Planing (AGP) Strike Drive - High-speed gravity planing drive for fast offensive strike vectoring.",
			"hp": 70.0,
			"weight": 60.0,
			"metal": 60,
			"crystal": 20,
			"dps": 0.0,
			"base_weight_capacity": 432.0,
			# 22.0, not the original 18.0 (2026-08-08 speed pass): still the
			# roster's outright top speed, widened along with everything else
			# to keep the gap over wheels/hover meaningful.
			"base_top_speed": 22.0,
			"size": Vector3(1.0, 0.5, 1.5),
			"color": Color.SLATE_BLUE,
			"traits": ["airborne", "fixed_wing", "high_speed"]
		},
		"ornithopter_wing": {
			"name": "Ornithopter Wing",
			"category": "locomotion",
			"required_building": "tech_lab",
			"hp": 65.0,
			"weight": 55.0,
			"metal": 45,
			"crystal": 25,
			"dps": 0.0,
			"base_weight_capacity": 360.0,
			# 10.5, not 9.0 (2026-08-08 speed pass): part of the general lift.
			"base_top_speed": 10.5,
			"thrust_coefficient": 120.0,
			"size": Vector3(2.0, 0.2, 1.0),
			"color": Color(0.42, 0.32, 0.22),
			"traits": ["airborne", "flapping_wing"]
		},
		"buoyant_envelope": {
			"name": "AGP Loiter Drive",
			"category": "locomotion",
			"required_building": "tech_lab",
			"description": "Atmospheric Gravity Planing (AGP) Loiter Drive - Sustained low-draw gravity planing drive optimized for long-endurance loitering and heavy payload transport.",
			"hp": 40.0,
			"weight": 35.0,
			"metal": 25,
			"crystal": 15,
			"dps": 0.0,
			"base_weight_capacity": 1260.0,
			# 4.5, not 4.0 (2026-08-08 speed pass): the smallest bump in the
			# roster, on purpose - this stays the floor.
			"base_top_speed": 4.5,
			"thrust_coefficient": 55.0,
			"size": Vector3(1.0, 0.5, 1.0),
			"color": Color(0.75, 0.72, 0.6),
			"traits": ["airborne", "buoyant"]
		},
		# --- LOCOMOTION EXPANSION (LOCOMOTION_EXPANSION_PLAN.md 4) ---
		# The roster was 3 ground / 1 hover / 4 air / 1 naval / 1 amphibious -
		# air was the DEEPEST group in a game whose primary theatre is ground.
		# These seven bring ground to 5, hover to 3, naval to 3 and amphibious
		# to 2, and air stays at 4. Every one exists to offer a decision the
		# roster could not previously express; none is a stat reshuffle.
		#
		# The naval trio (naval_propeller, hydrofoil, water_jet) was later
		# removed outright - naval units and naval building never got real
		# design attention, so the theatre they served does not exist. Water
		# navmeshes, hull draught and the amphibious drives below stay: those
		# are ground/hover locomotion whose water-crossing is a terrain
		# answer, not a naval one.
		"half_track": {
			"name": "Half-Track",
			"category": "locomotion",
			# The explicit compromise slot, and the one the roster most
			# obviously lacked: wheels and treads were a binary with nothing
			# between them. Historically the obvious answer (Sd.Kfz. 251, M3) -
			# steered wheels forward for road speed, a short track bogie aft for
			# the soft ground that stops a wheeled vehicle dead.
			"hp": 150.0,
			"weight": 85.0,
			"metal": 30,
			"crystal": 0,
			"dps": 0.0,
			# Between wheels (350) and tracked_treads (700), nearer the middle
			# than either - that IS the pitch.
			"base_weight_capacity": 720.0,
			# Base top speed (Chris: "each locomotor should also have a base
			# top speed"): the hard ceiling on how fast this chassis can be
			# driven, however much thrust is bolted to it. Replaces the single
			# universal 18.0 clamp every type used to share - see
			# Drivetrain.analyze() and get_base_top_speed() below.
			# Wheels up front for steering, belt at the back for load - splits
			# the difference between its two parents, as the archetype should.
			#
			# 10.0, not 8.5 (2026-08-08 speed pass): part of the general lift,
			# kept between tracked_treads and wheels.
			"base_top_speed": 10.0,
			"size": Vector3(0.7, 0.6, 2.2),
			"color": Color(0.30, 0.31, 0.26),
			"traits": ["ground_contact"]
		},
		"rocker_bogie": {
			"name": "Rocker-Bogie Suspension",
			"category": "locomotion",
			"required_building": "tech_lab",
			# The terrain specialist: slow everywhere, but the only ground
			# locomotor that is FASTER on rock than on gravel. A rocker-bogie
			# keeps every wheel loaded over broken ground by letting the arms
			# pivot freely, which is why it is what actually gets driven on
			# Mars. The answer to a map whose best ground is bad ground.
			"hp": 170.0,
			"weight": 110.0,
			"metal": 45,
			"crystal": 5,
			"dps": 0.0,
			"base_weight_capacity": 810.0,
			# Base top speed (Chris: "each locomotor should also have a base
			# top speed"): the hard ceiling on how fast this chassis can be
			# driven, however much thrust is bolted to it. Replaces the single
			# universal 18.0 clamp every type used to share - see
			# Drivetrain.analyze() and get_base_top_speed() below.
			# A rover linkage is built to crawl over obstacles without ever
			# lifting a wheel. Deliberately near the bottom of the roster.
			#
			# 6.0 rather than the 4.5 first written here, for the same reason
			# screw_drive was raised: this type's niche is rocky (1.15) and
			# forest (1.00), and a bottom-of-roster ceiling multiplied by those
			# left it slower on its OWN best ground than legs are. Not forced
			# by a failing test the way screw_drive was - nothing asserts a
			# rocker_bogie win - but it is the identical defect, and leaving it
			# in place would just mean discovering it later.
			#
			# 6.5, not 6.0 (2026-08-08 speed pass): the smallest bump in the
			# roster, on purpose - this stays near the floor.
			"base_top_speed": 6.5,
			"thrust_coefficient": 105.0,
			"size": Vector3(0.65, 0.9, 2.6),
			"color": Color(0.42, 0.38, 0.30),
			"traits": ["ground_contact"]
		},
		"air_cushion_skirt": {
			"name": "Air-Cushion Skirt",
			"category": "locomotion",
			"required_building": "tech_lab",
			# A real hovercraft rather than a sci-fi pad: a big flexible skirt
			# and lift fans. Crosses water AND marsh at full speed - it carries
			# "amphibious" so it routes onto the combined navmesh - and is
			# punished hard by anything it can catch on. Deliberately the
			# widest footprint in the roster, which is a real cost in a game
			# where modules clip.
			"hp": 90.0,
			"weight": 65.0,
			"metal": 35,
			"crystal": 20,
			"dps": 0.0,
			"base_weight_capacity": 1116.0,
			# Base top speed (Chris: "each locomotor should also have a base
			# top speed"): the hard ceiling on how fast this chassis can be
			# driven, however much thrust is bolted to it. Replaces the single
			# universal 18.0 clamp every type used to share - see
			# Drivetrain.analyze() and get_base_top_speed() below.
			# A hovercraft rides on air over land AND water, with nothing to
			# grip and nothing to slow it - near the top of the roster.
			#
			# 15.0, not 12.5 (2026-08-08 speed pass): part of the general lift.
			"base_top_speed": 15.0,
			"thrust_coefficient": 135.0,
			"size": Vector3(1.6, 0.45, 1.6),
			"color": Color(0.55, 0.52, 0.42),
			"traits": ["hovering", "amphibious"]
		},
		"anti_grav_plate": {
			"name": "Anti-Grav Plate",
			"category": "locomotion",
			"required_building": "exotics_lab",
			# The crystal sink. Flat 1.0 on every surface is the entire product
			# - it is the only locomotor that does not care what it is over -
			# and it pays for that with the roster's worst capacity-per-cost and
			# a crystal bill nothing else approaches. Reintroduces the anti-grav
			# ring the rebuild removed, but as a real trade rather than a free
			# upgrade.
			"hp": 60.0,
			"weight": 30.0,
			"metal": 20,
			"crystal": 75,
			"dps": 0.0,
			"base_weight_capacity": 288.0,
			# Base top speed (Chris: "each locomotor should also have a base
			# top speed"): the hard ceiling on how fast this chassis can be
			# driven, however much thrust is bolted to it. Replaces the single
			# universal 18.0 clamp every type used to share - see
			# Drivetrain.analyze() and get_base_top_speed() below.
			# Frictionless like hover_engine, but the plates are lift rather
			# than propulsion, so the ceiling is lower.
			#
			# 12.0, not 10.5 (2026-08-08 speed pass): part of the general lift,
			# kept behind hover_engine.
			"base_top_speed": 12.0,
			"thrust_coefficient": 125.0,
			"size": Vector3(0.9, 0.25, 0.9),
			"color": Color(0.35, 0.65, 0.85),
			"traits": ["hovering"]
		},
		"screw_drive": {
			"name": "Amphibious Screw Drive",
			"category": "locomotion",
			"required_building": "tech_lab",
			# Real historical "screw-propelled vehicle" (SPV) locomotion -
			# Soviet ZIL screw-drive trucks, the Fordson "Snow Devil" - twin
			# helical auger drums replace wheels/tracks entirely, letting
			# the vehicle churn through mud, snow, swamp, AND open water
			# using the exact same drums. Genuinely amphibious per the
			# no-hard-gating trait philosophy: carries BOTH "ground_contact"
			# (it drives on land like any tracked vehicle) and "amphibious"
			# (it also crosses water - routed onto a real combined
			# ground+water navmesh, see terrain_builder.gd's
			# build_navmeshes()/skirmish.gd's get_amphibious_nav_map()).
			# Slower and heavier than plain tracked_treads (churning
			# through mud/water is not a speed proposition) but tolerates
			# real payload like a tracked vehicle would.
			"hp": 160.0,
			"weight": 150.0,
			"metal": 55,
			"crystal": 15,
			"dps": 0.0,
			"base_weight_capacity": 810.0,
			# Base top speed (Chris: "each locomotor should also have a base
			# top speed"): the hard ceiling on how fast this chassis can be
			# driven, however much thrust is bolted to it. Replaces the single
			# universal 18.0 clamp every type used to share - see
			# Drivetrain.analyze() and get_base_top_speed() below.
			# Augers claw through mud and snow at a walking pace. Slow by
			# design; the terrain table is where it wins.
			#
			# 6.5, not the 5.0 first written here. A chassis ceiling and a
			# terrain multiplier both scale the same speed, so a type whose
			# entire niche is bad ground gets penalised TWICE if it also gets a
			# bottom-of-roster ceiling: at 5.0 a tracked_treads unit was faster
			# than this on ICE (5.0 x 0.75 = 3.75 against treads' 8.0 x 0.50 =
			# 4.00), which erased the one surface screw_drive is supposed to
			# own and broke test_terrain_types_differentiate_locomotion. Still
			# the second-slowest ground type on good ground, which is the
			# archetype; just not so slow that its bonus cannot show.
			#
			# 8.0, not 6.5 (2026-08-08 speed pass): raised more than its
			# neighbours specifically to preserve this same wheels/screw ratio
			# on ice under the retuned band - both moved, so the margin the
			# test above depends on had to move with them.
			"base_top_speed": 8.0,
			"thrust_coefficient": 110.0,
			"size": Vector3(0.8, 0.8, 3.0),
			"color": Color(0.32, 0.3, 0.24),
			"traits": ["ground_contact", "amphibious"]
		},
	}

	# Fold the fire profiles in so `get_module_data(id).fire_rate` works
	# everywhere - see WEAPON_FIRE_PROFILES for why they're authored as a
	# separate table instead of inline in each entry above.
	for profile_id in WEAPON_FIRE_PROFILES:
		if catalog.has(profile_id):
			for k in WEAPON_FIRE_PROFILES[profile_id]:
				catalog[profile_id][k] = WEAPON_FIRE_PROFILES[profile_id][k]

	return catalog

# --- Flavor text (VISUAL_ART_DIRECTION.md 1.2) ---
# The art doc restricts "where goofy lives" to DETAIL SCALE only, never
# silhouette or color-blocking. Copy is the cheapest detail-scale channel in
# the project - it costs no art production and no shader work - so the tone
# target (straight-faced military-industrial surface, cartoon absurdity
# underneath, per Chris's Starship Troopers / Tremors reference) lands here
# first, ahead of the decal atlas that will eventually carry the same voice
# visually.
#
# Voice rules, so this stays consistent as modules get added:
#  - Written as procurement/field-manual copy by someone with no sense of
#    humor about their job. The joke is never acknowledged by the writer.
#  - The absurdity is a FACT stated flatly, not a punchline ("rated for
#    continuous fire well past the point the crew compartment is habitable"),
#    never a wink at the player.
#  - Bureaucratic register: ratings, clearances, advisories, revisions,
#    liability-shaped hedging. Passive voice is correct here.
#  - One line, roughly <90 chars so the tooltip card doesn't reflow.
#
# Kept as a separate keyed block rather than a "flavor" key inside each of
# the 40 catalog literals above: one contiguous, reviewable place to tune
# voice, and it can't perturb the stat data the sim reads.
const MODULE_FLAVOR = {
	# Ballistic
	"basic_cannon": "Standard issue. Accurate, dependable, and entirely unremarkable in every after-action report.",
	"heavy_machine_gun": "Suppression rated. Barrel life is measured in engagements, not rounds. Spares are your problem.",
	"rotary_cannon": "Sustained fire well past the point the crew compartment remains habitable.",
	"gauss_railgun": "Capacitor discharge may interfere with nearby avionics, radios, and crew fillings.",
	"artillery": "Indirect fire. Observer required. Do not attempt to observe from the impact area.",
	"mortar_array": "Cheap, arcing, and imprecise. Effectiveness scales with quantity rather than skill.",
	# Guided
	"guided_missile": "Operator must maintain line of sight until impact. Operator discomfort is anticipated.",
	"missile_pod": "Fires everything at once. There is no partial-salvo setting. This was a design decision.",
	"drone_carrier": "Drones are considered expendable. Recovery is not a supported operation.",
	"cluster_dispenser": "Wide dispersal pattern. Confirm no friendly units are downrange, or thereabouts.",
	# Energy / exotic
	"flamethrower": "Short range by design. Crews are advised to be certain about wind direction.",
	"tesla_coil": "Arcs to the nearest conductive mass, which is not always the intended target.",
	"ion_cannon": "Draws heavily from base power. Scheduling with the generator crew is recommended.",
	"heavy_laser": "Continuous beam. Performance degrades in dust, smoke, rain, and general atmosphere.",
	"arc_projector": "Empties capacitors at range. Does almost no damage and is almost never forgiven.",
	"microwave_emitter": "Cooks electronics through armour. Crews report the taste of metal beforehand.",
	"particle_lance": "Five seconds of charging for one second of consequence. Do not be interrupted.",
	"spigot_mortar": "The bomb is larger than the launcher. Range is measured generously and still disappoints.",
	"rocket_artillery": "Empties in seconds. Reloads in considerably more than seconds.",
	"hypervelocity_missile": "No warhead. At this speed a warhead would be an affectation.",
	"sam_launcher": "Excellent against aircraft. Perfectly useless against everything else, including infantry standing still.",
	"loitering_munition": "Launches, circles, considers its options, then commits. Patience is a munition now.",
	"anti_radiation_missile": "Homes on anyone using a radar. Encourages the enemy to switch theirs off, which is also a win.",
	"bunker_buster": "Arrives from directly above. Structures were not consulted about this.",
	"cruise_missile": "Long ranged, generously proportioned, and entirely visible on approach.",
	"chaff_dispenser": "Fills the air with tinsel. Seekers find this more persuasive than seems reasonable.",
	"laser_dazzler": "Blinds seekers and optics. Harmless to anything that navigates by hope.",
	"aps_interceptor": "Shoots down what was shot at you. Bystanders are advised to stand considerably by.",
	"aa_autocannon": "For aircraft. Will engage ground targets only under protest and with poor grace.",
	"jammer_mast": "Degrades guided weapons nearby. Also announces exactly where you are.",
	"sentry_deployer": "Leaves a turret behind. The turret does not ask when you are coming back.",
	"sensor_beacon_launcher": "Throws an eye over the hill. Retrieval was not part of the design brief.",
	"decoy_projector": "Inflates something vaguely vehicle-shaped. Works far more often than anyone admits.",
	"slat_armor": "A cage held off the hull. Defeats shaped charges and almost nothing else.",
	"spaced_composite": "Two plates and an argument between them. Heavy in every sense.",
	"ablative_foam": "Sacrificial quilting. Burns away instead of you, once.",
	"plasma_lobber": "Containment is temporary by design. Everything downrange is briefly reclassified.",
	# Point defense
	"ciws": "Engages incoming ordnance automatically. Do not walk in front of it while powered.",
	"pd_laser": "Silent, precise, and invisible. Confirming that it is working is an ongoing challenge.",
	"flak_cannon": "Fills the sky with fragments. Aircraft are discouraged from entering that sky.",
	"smoke_discharger": "Produces concealment. Conceals friendly and hostile forces with equal diligence.",
	# Roster expansion
	"mk19_grenade_launcher": "Belt-fed grenades. Sustained fire is possible. Sustained resupply is not.",
	"recoilless_rifle": "Recoilless by design. The recoil is instead emitted rearward. Stand elsewhere.",
	"coil_gun": "Staged magnetic acceleration. Quieter than the rail. Everything else is unchanged.",
	"autocannon": "Intermediate calibre. Chosen because neither adjacent option was satisfactory either.",
	"anti_materiel_rifle": "One round, correctly placed, at considerable expense. The sight costs more than the gun.",
	"napalm_mortar": "Deploys thickened fuel. The affected area remains affected for some time.",
	"mine_layer": "Emplaces area denial. Minefield records are maintained to the extent practicable.",
	"ballista": "Torsion-spring bolt thrower. Procurement has twice declined to explain this line item.",
	# Support
	"resource_harvester": "Extracts and hauls. Slow, unarmed, and statistically the first thing shot at.",
	"repair_array": "Field repair. Restores structure. Does not restore crews, morale, or paperwork.",
	"sensor_suite": "Extends detection range. Emits constantly, and is therefore also easily detected.",
	"directional_radar": "High-gain phased sector array. Exceptional reach forward; utterly blind behind.",
	"topographic_radar": "Interferometric contour surveyor. Maps terrain elevations and horizons; ignores tactical contacts.",
	"seismic_sensor": "Subsurface acoustic geophone. Detects moving ground hulls through solid rock; oblivious to air and idle units.",
	"thermal_imager": "Cryogenically cooled infrared optics. Sees heat straight through smoke screens and obscurants.",
	"armor_plating": "Additional plate. Adds mass. Physics has been consulted and remains unsympathetic.",
	# Power
	"fusion_generator": "Supplies heavy base power. Rated safe. Rating issued by the manufacturer.",
	"diesel_generator": "Internal combustion turbine. Rugged, thirsty, and loud enough to mask minor engineering errors.",
	"thermo_generator": "Thermoelectric Stirling generator. Compact trickle output scavenged from core temperature differential.",
	"capacitor_bank": "Stores surplus power for demand spikes. Discharges spectacularly when destroyed.",
	"flywheel_storage": "High-velocity kinetic storage rotor. Armored containment ring doubles as structural ballistic reinforcement.",
	"solid_state_battery": "Matrix energy cell array. Flat hull-conforming profile with modular cell banks.",
	# Locomotion
	"wheels": "Fast on hard ground. Enthusiasm for soft ground is not shared by the wheels.",
	"tracked_treads": "Slow, heavy, and indifferent to terrain. Throws a track at the worst opportunity.",
	"helicopter_rotors": "Vertical lift. Loud enough to announce arrival well ahead of arrival.",
	"hover_engine": "Ignores ground conditions entirely. Also ignores most attempts at braking.",
	"legs": "Walks over what others drive around. Complexity per kilometre is considerable.",
	"fixed_wing_engine": "Requires forward speed to stay airborne. Hovering is not among the options.",
	"ornithopter_wing": "Flaps. Reviewed twice by engineering. Approved twice. Nobody is entirely sure why.",
	"buoyant_envelope": "Lighter than air, slower than everything, and a generously sized target.",
	"screw_drive": "Amphibious augers. Crosses land and water equally badly, which counts as versatility.",
}

# Empty string when a module has no authored line - callers append
# conditionally, so a missing entry degrades to "no flavor row" rather than
# a blank row or an error.



static func get_module_flavor(type_id: String) -> String:
	return MODULE_FLAVOR.get(type_id, "")

static func is_foundation(type_id: String) -> bool:
	var data = get_module_data(type_id)
	return data.get("is_foundation", false)

# Real existence check for a hull id, distinct from get_module_data()'s
# always-succeeds-with-a-fallback contract - needed now that hulls are
# scanned from disk and a blueprint can reference a hull id that simply
# isn't installed (mod uninstalled, typo, hand-edited save). Callers that
# need to tell "this hull is really missing" apart from "this hull exists
# and happens to have field X at its default" must use this, not
# get_module_data(id).is_empty() (which is never empty - see get_module_data()).
static func hull_exists(type_id: String) -> bool:
	var cat = get_catalog()
	return cat.has(type_id) and cat[type_id].get("category", "") == "hull"

# Every authored hull mesh (Chris confirmed, 2026-07-19) visually faces the
# opposite way from the -Z front convention every other system in this
# codebase already agrees on (weapon mounting, movement, facet
# classification, AI targeting - none of that logic is wrong, only the
# authored mesh's visual nose direction is). Rather than re-export/re-author
# every .glb, this is a purely VISUAL yaw correction applied only to the
# MeshInstance3D the mesh is displayed on - it never touches the hull's
# collision shape, module local coordinates, or any gameplay-facing
# direction math, all of which already work correctly. Defaults to the
# 180-degree flip every current hull needs; a future hull authored with its
# nose already at -Z can opt out via its own "visual_yaw_offset_deg" catalog
# field (or JSON sidecar field, for HullLoader-scanned mod hulls).
const HULL_VISUAL_YAW_OFFSET_DEFAULT_DEG: float = 90.0
# --- Hull mesh orientation + fit (single source of truth) -------------------
#
# module_placer.gd (fresh hull placed in the Design Lab) and
# blueprint_manager.gd (hull reconstructed from a saved blueprint, in the lab
# or in battle) each used to compute this independently and DISAGREED, so the
# same design looked and collided differently depending on how it got on
# screen. Both call get_hull_mesh_fit() now.
#
# Two separate problems this solves, both found 2026-07-21:
#
# 1. ORIENTATION. The old code applied a blanket 90-degree yaw to every hull
#    (HULL_VISUAL_YAW_OFFSET_DEFAULT_DEG). That happens to be right for the
#    ~13 authored meshes whose long axis is X, but it is wrong for the ones
#    authored along Z (bunker_main_meridian and the since-retired flying wing),
#    wrong for a mod hull authored correctly in the first place,
#    and useless for the ones standing on their tail with their long axis on
#    Y (interceptor_hull, fuselage_hull) - a yaw can never lay those down.
#    We now pick the axis-aligned orientation whose ASPECT RATIO best matches
#    the catalog size, which reproduces the old 90-degree answer wherever the
#    old answer was right and fixes it everywhere it wasn't.
#
# 2. FIT. The old code scaled uniformly so the mesh's LARGEST axis matched the
#    catalog's LARGEST axis. For any mesh whose proportions differ from the
#    catalog's that silently inflates the other two axes - interceptor_hull
#    rendered 7 units TALL and under 1 wide, naval_hull as a 12 x 1.76 x 1.76
#    pencil. Since the collision box, module placement, locomotion mounting,
#    armor auto-fit, clipping and stats are ALL defined in catalog space, the
#    visual has to occupy catalog space too or none of them line up. We fit
#    per-axis so the mesh exactly fills its catalog box.
#
# A hull whose .glb is authored at its true catalog dimensions (which is the
# convention) gets rotation 0 and scale 1
# here and is passed through untouched. Anything else is being corrected for
# a mis-authored source mesh; see get_hull_mesh_fit_warnings().
#
# An author can bypass the auto-detection entirely by setting any of
# "visual_yaw_offset_deg" / "visual_pitch_offset_deg" / "visual_roll_offset_deg"
# in the hull's catalog entry or .json sidecar - if any is present, those
# angles are used verbatim and no orientation search runs. That is the escape
# hatch for a mesh the AABB heuristic lands upside down (an axis-aligned
# bounding box cannot tell "nose up" from "nose down").
static func has_explicit_hull_orientation(hull_type_id: String) -> bool:
	var d = get_module_data(hull_type_id)
	return d.has("visual_yaw_offset_deg") or d.has("visual_pitch_offset_deg") or d.has("visual_roll_offset_deg")

# The axis-aligned orientations we search. Restricted to the 6 that map the
# mesh's three axes onto the hull's three axes without mirroring; the further
# 180-degree spins produce identical extents, so they cannot be distinguished
# by an AABB and are left to the explicit override above.
const _HULL_ORIENTATION_CANDIDATES: Array = [
	Vector3(0, 0, 0),
	Vector3(0, PI / 2.0, 0),
	Vector3(PI / 2.0, 0, 0),
	Vector3(PI / 2.0, PI / 2.0, 0),
	Vector3(0, 0, PI / 2.0),
	Vector3(0, PI / 2.0, PI / 2.0),
]

# Extents of an AABB after being rotated by an axis-aligned euler.
static func _oriented_extents(size: Vector3, euler: Vector3) -> Vector3:
	var b = Basis.from_euler(euler)
	var e = (b * Vector3(size.x, 0, 0)).abs() + (b * Vector3(0, size.y, 0)).abs() + (b * Vector3(0, 0, size.z)).abs()
	# Kill float fuzz from the 90-degree rotations so scale comes out exact.
	return Vector3(snappedf(e.x, 0.000001), snappedf(e.y, 0.000001), snappedf(e.z, 0.000001))

# Scale-invariant distance between two boxes' proportions: how far the
# per-axis scale factors are from being a single uniform scale. 0 means the
# mesh already has exactly the catalog's proportions.
static func _aspect_distance(extents: Vector3, target: Vector3) -> float:
	var ln := []
	for axis in ["x", "y", "z"]:
		if extents[axis] <= 0.0001 or target[axis] <= 0.0001:
			return INF
		ln.append(log(target[axis] / extents[axis]))
	var mean = (ln[0] + ln[1] + ln[2]) / 3.0
	return abs(ln[0] - mean) + abs(ln[1] - mean) + abs(ln[2] - mean)

# Returns {"rotation": Vector3 euler, "scale": Vector3, "position": Vector3}
# to apply to a MeshInstance3D so the authored mesh fills exactly `cat_size`,
# CENTERED on the hull's own origin. `extra_scale` (hull_scale * armor_bulk)
# is folded in for callers.
#
# "position" exists because an authored .glb's geometry is not necessarily
# centered on its own origin - medium_hull's sits about 0.32 units high after
# fitting. Nothing re-centered it, so the visible hull floated off-centre
# inside its own collision box, and every module placed against that box
# landed at a different height than the hull skin it was supposed to touch.
static func get_hull_mesh_fit(hull_type_id: String, mesh: Mesh, extra_scale: Vector3 = Vector3.ONE) -> Dictionary:
	var cat_size: Vector3 = get_module_data(hull_type_id).get("size", Vector3.ONE)
	if not mesh:
		return {"rotation": Vector3.ZERO, "scale": extra_scale, "position": Vector3.ZERO}
	var aabb = mesh.get_aabb()
	var aabb_size = aabb.size
	if aabb_size.x <= 0.0001 or aabb_size.y <= 0.0001 or aabb_size.z <= 0.0001:
		return {"rotation": Vector3.ZERO, "scale": extra_scale, "position": Vector3.ZERO}

	var euler: Vector3
	if has_explicit_hull_orientation(hull_type_id):
		var d = get_module_data(hull_type_id)
		euler = Vector3(
			deg_to_rad(d.get("visual_pitch_offset_deg", 0.0)),
			deg_to_rad(d.get("visual_yaw_offset_deg", 0.0)),
			deg_to_rad(d.get("visual_roll_offset_deg", 0.0)))
	else:
		var best = _HULL_ORIENTATION_CANDIDATES[0]
		var best_score = INF
		for candidate in _HULL_ORIENTATION_CANDIDATES:
			var score = _aspect_distance(_oriented_extents(aabb_size, candidate), cat_size)
			# Candidates run least-rotated first, and a challenger has to be
			# meaningfully better (not merely luckier on float noise) to
			# displace the incumbent. Without a real margin, a near-symmetric
			# mesh like airship_hull's cigar envelope - whose two minor axes
			# differ by under 10% - gets rolled onto its side for a scoring
			# gain small enough to be indistinguishable from rounding.
			if score < best_score - 0.05:
				best_score = score
				best = candidate
		euler = best

	# Godot composes a node's basis as rotation * scale, so `scale` is applied
	# along MESH-local axes and only then rotated into hull space. The fit
	# factors we just derived are per HULL axis, so they have to be permuted
	# back through the rotation before being handed to the node - otherwise
	# every hull needing a non-zero rotation gets its fit factors applied to
	# the wrong axes (which is exactly what the resulting-extents check in
	# run_tests.gd's hull suite now guards against).
	var oriented = _oriented_extents(aabb_size, euler)
	var hull_axis_fit = Vector3(cat_size.x / oriented.x, cat_size.y / oriented.y, cat_size.z / oriented.z)
	var mesh_axis_fit = (Basis.from_euler(euler).transposed() * hull_axis_fit).abs()
	var final_scale = mesh_axis_fit * extra_scale

	# Recentre: a node's transform maps a mesh point p to
	# position + R*S*p, so putting the geometry's own AABB centre on the hull
	# origin means position = -R*S*centre.
	var basis = Basis.from_euler(euler).scaled(final_scale)
	var position = -(basis * aabb.get_center())

	return {"rotation": euler, "scale": final_scale, "position": position}

# Hull-local AABB the visual mesh actually occupies, given the fit dict that
# get_hull_mesh_fit() just produced. Centre is at (0, 0, 0) - the fit recentres
# the mesh on the hull's local origin - and the size is the per-axis hull-local
# extent of the rotated, scaled mesh.
#
# This is the hull's TRUE footprint. The catalog `size` field is a hand-tuned
# bounding box the mesh is squashed to fit, not the mesh's actual extents, and
# using it as the collider/source-of-truth made every dimension consumer
# (locomotion station positions, armor auto-fit, running-gear placement,
# hull.position.y, unit.gd's separation/selection/cargo radii) read a value
# that disagreed with what the player could see. For hulls whose actual
# silhouette is smaller than the catalog box along one axis (SDF-baked hulls,
# tapered keels, airship envelopes, the spire/catamaran/pillbox/interceptor
# families) the visual mesh sat well inside the box, and every module placed
# against the box floated in air around the actual hull.
#
# `get_hull_fitted_aabb()` below is the convenience wrapper for callers that
# don't already hold a fit dict. Both return an AABB; pass `.size` for the
# box collider / base_hull_size / locomotion hull_size, and `.get_center()` is
# (0, 0, 0) so the collider's position stays at the hull node's local origin
# (the mesh's recentred centre, not its raw AABB corner).
static func get_fitted_aabb_from_fit(mesh: Mesh, fit: Dictionary) -> AABB:
	if not mesh:
		return AABB(Vector3.ZERO, Vector3.ZERO)
	var aabb: AABB = mesh.get_aabb()
	if aabb.size.x <= 0.0001 or aabb.size.y <= 0.0001 or aabb.size.z <= 0.0001:
		return AABB(Vector3.ZERO, Vector3.ZERO)
	var euler: Vector3 = fit.get("rotation", Vector3.ZERO)
	var final_scale: Vector3 = fit.get("scale", Vector3.ONE)
	# _oriented_extents() takes a size vector and returns the AABB size after a
	# rotation - which is exactly the per-axis hull-local extent of the mesh
	# after final_scale is applied in mesh-local axes and then rotated.
	var oriented_size: Vector3 = _oriented_extents(aabb.size * final_scale, euler)
	return AABB(-oriented_size * 0.5, oriented_size)

# Top-level convenience: one orientation search, then the AABB. Use this
# unless the caller already called get_hull_mesh_fit() for the visual placement
# (in which case get_fitted_aabb_from_fit() saves the duplicate search).
static func get_hull_fitted_aabb(hull_type_id: String, mesh: Mesh, extra_scale: Vector3 = Vector3.ONE) -> AABB:
	if not mesh:
		return AABB(Vector3.ZERO, Vector3.ZERO)
	var fit: Dictionary = get_hull_mesh_fit(hull_type_id, mesh, extra_scale)
	return get_fitted_aabb_from_fit(mesh, fit)

# Energy resource (ENERGY_AND_BALANCE_SPEC.md #1): a hull's base_energy is
# the starting point for max_energy before any generator modules are
# mounted. Defaults to 0.0 for anything without a base_energy field
# (weapons/locomotion/etc - only hull/foundation entries carry this stat).
static func get_base_energy(hull_type_id: String) -> float:
	var data = get_module_data(hull_type_id)
	return data.get("base_energy", 0.0)

# A hull's base_power is its GENERATION - energy per second, the refill rate -
# and is a genuinely separate stat from base_energy, which is STORAGE.
#
# They used to be one number. The refill rate was derived as
# `base_energy * 0.08`, so storage manufactured generation and there was no way
# to author a hull that holds a large buffer but trickles, or a small one that
# refills fast. Those are the two most interesting shapes a power system has,
# and neither was expressible.
#
# The shipped values are seeded at exactly that old 0.08 ratio, so introducing
# the field changed no hull's behaviour on its own - every behavioural change
# comes from consumption, which did not exist before (see POWER_DRAW). A
# handful are then hand-graded off that ratio where the fiction argues for it:
# locomotive_hull and pressure_hull generate above their storage tier because a
# powerplant is the premise of both, airship_hull below because its lift budget
# leaves little over, and scout hulls slightly above because a tiny buffer still
# has to sustain the optics that are the hull's entire job.
#
# Same "absent means 0.0" contract as get_base_energy above, and for the same
# reason: only hull and foundation entries carry the stat, and a weapon being
# asked for its generation should answer "none" rather than error. That also
# makes the field optional for mod hulls - see hull_loader.gd's REQUIRED_FIELDS,
# which this is deliberately NOT added to.
static func get_base_power(hull_type_id: String) -> float:
	var data = get_module_data(hull_type_id)
	return data.get("base_power", 0.0)

# Fog-of-war (built this pass, see PROGRESS.md): a hull's base_vision is
# the starting sight radius before any sensor_suite modules are mounted -
# same "hull base + module bonus" shape as Energy's base_energy.
#
# Vision is what actually gated engagement distance before the range retune
# (see RANGE_TIERS): a hull saw 14-28 units, so nothing could be shot at
# further than that no matter how far its guns reached. The tiers need a
# bigger anchor than 20 to sit against, but the authored per-hull values are
# duplicated across 21 mesh sidecars in assets/models/hulls, 14 assembly
# JSONs in data/hull_assemblies, and tools/gen_kitbash_hulls.py - 35+ files
# that would all have to move together and would leave every future hull
# authored against a stale scale.
#
# So the scale-up is ONE multiplier, here, at the single point every caller
# already goes through (unit.gd and building.gd both read vision only
# via this function). The JSON keeps saying 20 and means "20 on the authoring
# scale"; the game sees 38. Retuning a specific hull still means editing that
# hull's own base_vision, exactly as before - this only moves the whole band.
const VISION_SCALE: float = 1.9

static func get_base_vision(hull_type_id: String) -> float:
	var data = get_module_data(hull_type_id)
	return data.get("base_vision", 20.0) * VISION_SCALE

# Whether this weapon-slot module's targeting should invert to same-team,
# HP-deficit candidates instead of hostiles (repair_array's real fix -
# previously it reused the universal hostile-only targeting and could never
# select an ally at all). Single source of truth so auto_weapon.gd doesn't
# need a hardcoded type_id check.
static func targets_allies(type_id: String) -> bool:
	var data = get_module_data(type_id)
	return data.get("targets_allies", false)

# Real bug found while fixing repair_array/drone_carrier for real (Energy
# batch): every _setup_weapons()-equivalent (unit.gd, building.gd, and the
# retired battle_unit.gd / battlefield.gd when they ran the old Skirmish
# scene) only attaches auto_weapon.gd when category=="weapon" -
# repair_array and drone_carrier are catalogued as category="module" (like
# resource_harvester/sensor_suite/logistics_tank, which don't need the
# script - they're driven by other systems entirely). That meant neither
# module EVER got its firing/targeting script in real gameplay, only in
# synthetic tests that manually attached it, bypassing this gate. Single
# source of truth so the three spawn paths can't drift on this again.
static func needs_combat_script(type_id: String) -> bool:
	var data = get_module_data(type_id)
	if data.get("category", "") == "weapon":
		return true
	return type_id in ["repair_array", "drone_carrier"]

# Categories that count as a "legitimate non-combat purpose" - a design
# with one of these and no weapon is intentionally support/utility, not an
# accident. Anything else with zero weapons and none of these categories
# is a motionless, harmless brick the player almost certainly forgot to
# finish, not a deliberate build.
# --- Bolt-on armor bias -----------------------------------------------------
# Each plate multiplies the armor THRESHOLD against one damage class and is
# punished against another, so the three of them form a rock-paper-scissors
# among themselves. Deliberately applied on top of the hull's own armor
# MATERIAL rather than replacing it: the material dropdown is a separate,
# already-balanced 4-vs-4 (FABLE_REVIEW.md 1.2), and adding a fifth row there
# would break a system that took real work to get right. A plate biases; it
# does not redefine.
#
# Anything absent from a plate's row is 1.0 - unaffected.
const ARMOR_MODULE_BIAS = {
	# A cage held off the hull. Pre-detonates shaped charges beautifully and
	# does essentially nothing against solid shot, which is honest: you can
	# see straight through it.
	"slat_armor": {"explosive": 1.95, "kinetic": 0.55, "thermal": 0.85},
	# Two plates and an air gap. The kinetic answer, and heavy enough that
	# committing to it is a real payload decision.
	"spaced_composite": {"kinetic": 1.85, "explosive": 1.15, "energy": 0.70},
	# Sacrificial quilting. Burns away instead of the hull, once.
	"ablative_foam": {"thermal": 2.10, "energy": 1.25, "kinetic": 0.60},
}

static func get_armor_module_bias(type_id: String, damage_type: String) -> float:
	if not ARMOR_MODULE_BIAS.has(type_id):
		return 1.0
	return float(ARMOR_MODULE_BIAS[type_id].get(damage_type, 1.0))

const SUPPORT_CATEGORIES = ["generator"]
const SUPPORT_TYPE_IDS = [
	"repair_array", "drone_carrier", "resource_harvester", "sensor_suite",
	"laser_designator", "energy_barrier_projector", "fire_control_radar",
	"directional_radar", "topographic_radar", "seismic_sensor", "thermal_imager"
]

# --- Continuous power draw --------------------------------------------------
# Energy per second a module consumes just by being alive and switched on.
#
# CONSUMPTION DID NOT EXIST BEFORE THIS TABLE. Energy was only ever spent in
# discrete per-shot bites by five weapons (auto_weapon.ENERGY_WEAPON_TYPES),
# which meant a generator was worth fitting only on an energy-weapon platform
# and every other design carried a full, permanently untouched buffer. The
# electronics in particular were free: a scout could mount a sensor suite, a
# radar and a jammer, see half the map, and pay nothing for it.
#
# Everything here is a device that is doing work continuously, and the numbers
# are ordered by how loud that work is rather than by how big the part is:
# jammer_mast is the hungriest because flooding a band is genuinely the most
# power-intensive thing on this list, and its own catalog blurb ("also
# announces exactly where you are") already sold it as the loud option - now it
# is loud in the budget too. fire_control_radar costs more than sensor_suite
# because it is actively tracking rather than passively listening.
#
# ENERGY WEAPONS ARE DELIBERATELY ABSENT. They spend per shot through
# spend_energy(), which is a burst cost, and putting them here as well would
# bill them twice. Their sustained equivalent is derived for DISPLAY only, in
# PowerBudget - so the Design Lab can quote one comparable "draw" figure -
# without changing anything about how firing works.
#
# energy_barrier_projector appears because a field that is up is drawing even
# when nothing has hit it. That upkeep is separate from, and much smaller than,
# the pool it spends to absorb a hit (unit.gd's _absorb_with_barrier).
const POWER_DRAW := {
	"sensor_suite": 2.5,
	"directional_radar": 3.5,
	"topographic_radar": 5.0,
	"seismic_sensor": 1.5,
	"thermal_imager": 2.0,
	"fire_control_radar": 4.0,
	"jammer_mast": 6.0,
	"laser_designator": 2.0,
	"decoy_projector": 1.5,
	"energy_barrier_projector": 5.0,
	"repair_array": 3.5,
	"drone_carrier": 4.0,
	"aps_interceptor": 2.0,
}

static func get_power_draw(type_id: String) -> float:
	return float(POWER_DRAW.get(type_id, 0.0))

# --- Roles (parts-menu grouping) -------------------------------------------
# `category` is a mechanical classification - it tells the placer which gizmo
# handles to show and the stat calculator how to score the part. It is far too
# coarse to browse by: 25 of the catalog's entries are category "weapon", which
# is one undifferentiated wall of buttons in the Design Lab sidebar.
#
# `role` is the BROWSING classification, and it lives here rather than in
# parts_menu.gd on purpose. A grouping table sitting in the UI layer is the
# exact failure HULL_MODDING_PLAN.md 4c calls out for hulls: a modded part
# would need a code change in a UI script to appear anywhere sensible. Kept
# next to the catalog, a mod that adds a part just declares its role like it
# already declares its category, and get_module_role()'s category fallback
# means one that declares nothing still lands somewhere reasonable instead of
# vanishing.
const MODULE_ROLES = {
	# Flat-trajectory barrels you point at what you want to hit.
	"heavy_machine_gun": "Direct-Fire Guns",
	"flamethrower": "Direct-Fire Guns",
	"autocannon": "Direct-Fire Guns",
	"anti_materiel_rifle": "Direct-Fire Guns",
	"recoilless_rifle": "Direct-Fire Guns",
	"basic_cannon": "Direct-Fire Guns",
	"rotary_cannon": "Direct-Fire Guns",
	"ballista": "Direct-Fire Guns",

	# Anything whose damage arrives as charge rather than mass - includes the
	# electromagnetic launchers, which fire a slug but are built, costed and
	# powered like energy weapons (crystal + capacitors, not a powder charge).
	"heavy_laser": "Energy & Electromagnetic",
	"arc_projector": "Energy & Electromagnetic",
	"microwave_emitter": "Energy & Electromagnetic",
	"particle_lance": "Energy & Electromagnetic",
	"spigot_mortar": "Indirect Fire",
	"rocket_artillery": "Indirect Fire",
	"hypervelocity_missile": "Missiles",
	"sam_launcher": "Missiles",
	"loitering_munition": "Missiles",
	"anti_radiation_missile": "Missiles",
	"bunker_buster": "Missiles",
	"cruise_missile": "Missiles",
	"chaff_dispenser": "Point Defense",
	"laser_dazzler": "Point Defense",
	"aps_interceptor": "Point Defense",
	"aa_autocannon": "Point Defense",
	"jammer_mast": "Point Defense",
	"sentry_deployer": "Deployables",
	"sensor_beacon_launcher": "Deployables",
	"decoy_projector": "Deployables",
	"slat_armor": "Armor",
	"spaced_composite": "Armor",
	"ablative_foam": "Armor",
	"tesla_coil": "Energy & Electromagnetic",
	"coil_gun": "Energy & Electromagnetic",
	"ion_cannon": "Energy & Electromagnetic",
	"gauss_railgun": "Energy & Electromagnetic",

	# Lobbed, arcing, or otherwise fired at something you cannot see.
	"mk19_grenade_launcher": "Indirect Fire",
	"mortar_array": "Indirect Fire",
	"napalm_mortar": "Indirect Fire",
	"cluster_dispenser": "Indirect Fire",
	"plasma_lobber": "Indirect Fire",
	"artillery": "Indirect Fire",

	"guided_missile": "Missiles",
	"missile_pod": "Missiles",

	"pd_laser": "Point Defense",
	"ciws": "Point Defense",
	"flak_cannon": "Point Defense",

	# Weapons that leave something behind on the field instead of resolving
	# damage at a target - the reason smoke_discharger (0 dps) and mine_layer
	# read as odd ducks in a flat weapon list.
	"smoke_discharger": "Deployables",
	"mine_layer": "Deployables",
	"drone_carrier": "Deployables",

	"armor_plating": "Armor",
	"capacitor_bank": "Power",
	"fusion_generator": "Power",
	"diesel_generator": "Power",
	"thermo_generator": "Power",
	"flywheel_storage": "Power",
	"solid_state_battery": "Power",
	"repair_array": "Support",
	"resource_harvester": "Support",
	"sensor_suite": "Support",
	"directional_radar": "Support",
	"topographic_radar": "Support",
	"seismic_sensor": "Support",
	"thermal_imager": "Support",

	# Speed as a real, affectable stat (2026-08-08): category "module" like
	# everything above, but browsed with the locomotion types they modify
	# rather than with the generators - see the TIERS/DRIVE_ROLES comment in
	# parts_menu.gd for why that split doesn't need a new top-level toolbox.
	"turbocharger": "Propulsion",
	"overdrive_gearbox": "Propulsion",
	"hub_motor_array": "Propulsion",
	"nitrous_injector": "Propulsion",
	"booster_rack": "Propulsion",
	"jet_thrusters": "Propulsion",
}

# Display order for the module tab's drawers. Roughly "things that shoot" ->
# "things that survive" -> "things that hold other things up", which is the
# order a build actually gets assembled in.
const MODULE_ROLE_ORDER = [
	"Direct-Fire Guns", "Energy & Electromagnetic", "Indirect Fire", "Missiles",
	"Point Defense", "Deployables", "Armor", "Propulsion", "Power", "Support",
]

# Fallback for anything MODULE_ROLES doesn't name (a mod, or a part added here
# and not yet given a role). Deliberately never returns "" - an unroled part
# must still land in a visible drawer, not silently disappear from the menu.
const ROLE_BY_CATEGORY = {
	"weapon": "Direct-Fire Guns",
	"armor": "Armor",
	"generator": "Power",
	"module": "Support",
}

static func get_module_role(type_id: String, category: String = "") -> String:
	if MODULE_ROLES.has(type_id):
		return MODULE_ROLES[type_id]
	if category != "" and ROLE_BY_CATEGORY.has(category):
		return ROLE_BY_CATEGORY[category]
	return "Support"

# --- Tech Tree Building Prerequisites ---
const HULL_REQUIREMENTS = {
	"block_heavy_meridian_a": "tech_lab",
	"interceptor_hull": "tech_lab",
	"sponson_hull": "tech_lab",
	"fuselage_hull": "tech_lab",
	"small_boat_hull": "tech_lab",
	"amphibious_hull": "tech_lab",
	"dreadnought_hull": "physics_lab",
	"heavy_cruiser_hull": "physics_lab",
	"airship_hull": "exotics_lab",
}

const ARMOR_MATERIAL_REQUIREMENTS = {
	"hardened_steel": "",
	"reactive_armor": "tech_lab",
	"ablative_ceramic": "tech_lab",
	"energy_shielding": "exotics_lab",
	"carbon_fiber": "tech_lab",
	"titanium_plate": "exotics_lab",
}

static func get_required_building(type_id: String) -> String:
	if HULL_REQUIREMENTS.has(type_id):
		return HULL_REQUIREMENTS[type_id]
	if ARMOR_MATERIAL_REQUIREMENTS.has(type_id):
		return ARMOR_MATERIAL_REQUIREMENTS[type_id]
	if AMMO_TYPES.has(type_id):
		return AMMO_TYPES[type_id].get("required_building", "")
	if module_exists(type_id):
		return get_module_data(type_id).get("required_building", "")
	return ""

# Build-legality gate (ENERGY_AND_BALANCE_SPEC.md #3/DECISIONS_NEEDED.md):
# a design must have a hull, must have a weapon or a legitimate support/
# utility purpose, and must have locomotion or be intentionally static
# (a foundation). Returns {"valid": bool, "reason": String} - reason is
# empty when valid, a player-facing explanation otherwise. Pure/static so
# both the Skirmish match-queue gate and (if ever needed) the Design Lab
# can call the exact same check.
static func validate_build_legality(blueprint_data: Dictionary) -> Dictionary:
	var hull_type = blueprint_data.get("hull_type", "")
	if hull_type == "" or not get_catalog().has(hull_type):
		return {"valid": false, "reason": "No hull selected."}

	var has_weapon = false
	var has_support = false
	var has_locomotion = false
	for mod in blueprint_data.get("modules", []):
		var type_id = mod.get("type_id", "")
		if type_id == "": continue
		var data = get_module_data(type_id)
		var category = data.get("category", "")
		if category == "weapon":
			has_weapon = true
		elif category in SUPPORT_CATEGORIES or type_id in SUPPORT_TYPE_IDS:
			has_support = true
		if category == "locomotion":
			has_locomotion = true

	if not has_weapon and not has_support:
		return {"valid": false, "reason": "No weapon or support module - this design doesn't do anything."}
	if not has_locomotion and not is_foundation(hull_type):
		return {"valid": false, "reason": "No locomotion - this design can't move (use a foundation hull for a static build)."}
	return {"valid": true, "reason": ""}

# --- Unit-class traits (MOUNTING_AND_ARMOR_SPEC.md addendum) ---
# Composable tags, not a hard ship/land/air/building enum, so a helicopter
# that behaves like a ground vehicle at scale and three different fixed-wing
# archetypes aren't forced into one box. DELIBERATELY NO VALIDATION HERE -
# traits describe whatever combination of hull+locomotion is actually
# present and let simulation code (movement, mounting, AI) branch on that;
# they never block a placement. A player can put treads on a naval hull if
# they want to - the traits would just describe a "ground_contact" trait on
# a hull that (once naval hulls exist) might also carry a "buoyant" trait,
# and whatever movement/behavior code reads those traits decides what to do
# with the combination. See DECISIONS_NEEDED.md.
static func get_traits(hull_type_id: String, locomotion_type_id: String = "") -> Array:
	var traits = []
	var hull_data = get_module_data(hull_type_id)
	for t in hull_data.get("traits", []):
		if t not in traits:
			traits.append(t)
	if is_foundation(hull_type_id) and "static" not in traits:
		traits.append("static")
	if locomotion_type_id != "":
		var loco_data = get_module_data(locomotion_type_id)
		for t in loco_data.get("traits", []):
			if t not in traits:
				traits.append(t)
	return traits

# Whether a hull supports independent weapon traverse (turrets/pintles/
# sponsons that aim separately from the hull) vs. everything mounted on it
# being fixed-forward, whole-vehicle-aims (see get_mount_style()'s
# "frame_built" - this is what generalizes that from weapon-type-gated to
# trait-gated). Defaults to true so every hull that exists today keeps its
# current mounting behavior unchanged; future hull types (e.g. a fixed-wing
# airframe) can set "turreted_capable": false in their catalog entry.
static func is_turreted_capable(hull_type_id: String) -> bool:
	var data = get_module_data(hull_type_id)
	return data.get("turreted_capable", true)

# Single source of truth for weapon mount style, shared between the runtime
# combat AI (auto_weapon.gd), the Design Lab placement code (module_placer.gd),
# and the Design Lab firing-arc visualizer - they must never drift apart,
# since the whole point is that they all agree on the same classification.
# Collapsed from an original 5-bucket system (turret / frame_built /
# pintle_top / pintle_bottom / sponson) to 3 buckets, then (2026-07-21) the
# visual side was simplified further: mount_style no longer drives HOW a
# weapon is placed (module_placer.gd flush-mounts every style the same way,
# rotating the module's authored mesh - post and all - flat against
# whichever facet it landed on) - it now only drives combat traverse.
#   "turret"      - existing enclosed-turret visual, unchanged (basic_cannon only), full traverse
#   "frame_built" - built into the vehicle frame; the whole vehicle aims, not the weapon, zero traverse
#   "pintle"      - independent-traverse mount, 360 azimuth
#
# hull_type_id generalizes "frame_built" from weapon-type-gated to
# turreted_capable-trait-gated (MOUNTING_AND_ARMOR_SPEC.md addendum): on a
# hull that doesn't support independent traverse, EVERYTHING mounts
# frame_built, including basic_cannon - nothing should carry visible
# independent-traverse hardware on a unit that can't actually traverse
# weapons independently. Omitting hull_type_id keeps the weapon-type-only
# behavior (used by the few legacy call sites that don't yet know the
# hull context).
static func get_mount_style(type_id: String, hull_type_id: String = "") -> String:
	if hull_type_id != "" and not is_turreted_capable(hull_type_id):
		return "frame_built"
	if type_id == "basic_cannon":
		return "turret"
	if type_id in ["gauss_railgun", "heavy_howitzer"]:
		return "frame_built"
	return "pintle"

# --- Sponson eligibility ---------------------------------------------------
# Revives the "pintle_min_up_alignment" field that has sat on 23 weapon entries
# unread since the 2026-07-21 flush-mount addendum deleted its only consumer.
# Its meaning is unchanged: the least vertical alignment - dot(surface normal,
# UP) - at which this weapon will still stand its own authored post directly
# on the surface it was dropped on.
#
# Below it the face is too close to vertical for that to mean anything: "up"
# there is horizontal, which is what left a front-facet gun pointing at the
# ground and a rear-facet one at the sky. Those weapons get embedded into the
# hull and fire out through a sponson blister instead - see
# module_placer._is_sponson_mount(), which is the only caller.
#
# Per-type because it is a per-type judgement, and the authored values already
# encode it: a compact MG bolts to almost anything (0.15), a mortar needs a
# near-level base to aim its arc at all (0.55). Full per-weapon reasoning is in
# DECISIONS_NEEDED.md's 2026-07-12 entry. Note the highest authored value is
# 0.55, so a 45-degree glacis (0.707) stays flush for every weapon in the
# roster - that is deliberate, not an oversight.
const SPONSON_MAX_UP_ALIGNMENT_DEFAULT := 0.3

static func get_sponson_up_alignment(type_id: String) -> float:
	return get_module_data(type_id).get("pintle_min_up_alignment",
		SPONSON_MAX_UP_ALIGNMENT_DEFAULT)

# Whether this weapon can be ENCLOSED in a sponson housing, as opposed to
# merely being levelled on a wall.
#
# These are two different questions and conflating them got it backwards
# first time round. get_sponson_up_alignment() above answers "how level a base
# does this weapon need before it has to be re-levelled" - and a mortar needs
# a very level one (0.55), so it re-levels EAGERLY. This answers "can it live
# in a box", and for the same mortar the answer is no: a housing plus a 60
# degree arc denies exactly the open sky a lobbing weapon exists to use.
# Reading the first field as if it answered the second made artillery the most
# eager thing in the roster to be boxed in, which is precisely wrong.
#
# A weapon that is NOT sponson_capable is REFUSED outright on a near-vertical
# face (module_placer._placement_refusal_reason) rather than mounted some other
# way. An intermediate version levelled them on an open unhoused mount, which
# looked fine and still left an artillery piece bolted to a wall - Chris's call
# on 2026-08-04 was that they simply do not go there. This is the one
# deliberate exception to MOUNTING_AND_ARMOR_SPEC.md:58's no-hard-blocking
# rule; see that file's 2026-08-04 addendum for the argument.
#
# Defaults TRUE: direct-fire weapons are the common case, and a new weapon
# author who wants otherwise should have to say so.
static func is_sponson_capable(type_id: String) -> bool:
	return get_module_data(type_id).get("sponson_capable", true)

# How far INBOARD of the clicked surface point a sponson-mounted weapon's
# origin sits, so its body and its authored post end up inside the hull and
# only the barrel protrudes.
#
# This lives here, next to the blister scale below, for one reason: two
# separate copies of "how deep" would drift, and the moment they do the
# housing no longer lines up with the hole it is supposed to be covering.
# module_placer._mount_transform() offsets the weapon by this, and
# visual_builder._sponson_blister() places the housing at the same distance
# back out along the muzzle axis. One number, two readers.
const SPONSON_EMBED_FRACTION := 0.5
const SPONSON_EMBED_MIN := 0.2
const SPONSON_EMBED_MAX := 0.8

static func get_sponson_embed_depth(type_id: String) -> float:
	var size: Vector3 = get_module_data(type_id).get("size", Vector3.ONE)
	return clampf(size.z * SPONSON_EMBED_FRACTION, SPONSON_EMBED_MIN, SPONSON_EMBED_MAX)

# Uniform scale for the blister housing. sponson_blister.glb is authored one
# unit wide, so the returned value IS the housing's final width in metres.
#
# Uniform on purpose - _hardware()'s contract (visual_builder.gd:208) is that
# authored geometry never stretches anisotropically, and the blister is held
# to the same rule even though it is painted plate rather than hardware. The
# cover factor makes the housing wider than the weapon's own cross-section,
# since it has to enclose the body rather than just abut it.
#
# Starting values, expected to be eyeballed in the Lab and adjusted - they are
# a plausible ratio, not a derived truth.
const SPONSON_BLISTER_COVER := 1.8
const SPONSON_BLISTER_MIN := 0.4
const SPONSON_BLISTER_MAX := 2.0

static func get_sponson_blister_scale(type_id: String) -> float:
	var size: Vector3 = get_module_data(type_id).get("size", Vector3.ONE)
	return clampf(maxf(size.x, size.y) * SPONSON_BLISTER_COVER,
		SPONSON_BLISTER_MIN, SPONSON_BLISTER_MAX)

# Per-weapon BASE traverse speed, in radians/second, before any tweak on the
# instance. Chris, 2026-08-03: "the traverse speed of a weapons module should
# start from a base value per weapon module, and then be impacted by tweaks."
#
# WHAT THIS REPLACES. auto_weapon.gd used to derive the base from the
# instance's own weight - clamp(200/weight, 0.4, 8.0) - times a separate
# per-type `traverse_agility` multiplier. Two problems:
#
#   1. Deriving the base from the TWEAKED weight conflated two different
#      things: "this archetype is a heavy slow gun" and "this particular one
#      has been built heavy". A weapon had no base of its own to be modified
#      away from.
#   2. The resulting band was 0.32 - 9.14 rad/s, i.e. 18 - 524 deg/s. At the
#      top of that a gun crosses a full circle in 0.7 seconds, so traverse
#      simply was not a consideration for half the roster, and whatever
#      differentiation existed among the fast weapons was invisible because
#      they were all effectively instant.
#
# The values here are 12 - 147 deg/s (a full circle in 2.4s at the fastest,
# 29s at the slowest), and were generated as
#     0.9 * (100 / catalog_weight)^0.55 * old_traverse_agility
# so every weapon keeps its previously authored archetype character and its
# relative ordering, on a band where the differences are felt. The 0.55
# exponent is deliberately sub-linear: at 1.0 a 10x heavier weapon traverses
# 10x slower, which is what stretched the old band across a 28x spread and
# left the clamps doing the balancing.
#
# The archetype tiers folded in here, kept for whoever tunes these next:
# point-defense snaps onto small fast targets (fastest), light autoguns are
# quick, guided munitions do not need to snap-track since the warhead corrects
# after launch, precision energy weapons favour a stable deliberate aim, and
# indirect/ballistic-arc weapons are slowest because the arc depends on a
# controlled aim. Non-weapon modules (resource_harvester, repair_array,
# sensor_suite, logistics_tank, drone_carrier) deliberately have no entry -
# they are not being aimed in this sense - and fall through to the default.
const BASE_TRAVERSE_DEFAULT: float = 0.9

static func get_base_traverse(type_id: String) -> float:
	return get_module_data(type_id).get("base_traverse", BASE_TRAVERSE_DEFAULT)

# --- Projectile class (FABLE_REVIEW.md 1.4 - the evasion model) ---
# How a weapon's shot travels, which decides whether target SPEED can make
# it miss (auto_weapon.gd's _roll_hit()):
#   "hitscan"   - beams/rails: effectively instant, speed can't dodge them
#   "ballistic" - fast direct-fire shells: fast movers shake some hits
#   "arc"       - slow lobbed trajectories: the easiest to simply drive out
#                 from under - mortars are area/siege tools, not anti-scout
#   "guided"    - self-correcting: never misses from speed; its counter is
#                 point-defense interception (weapon_missile.gd), not dodging
const PROJECTILE_CLASS = {
	"gauss_railgun": "hitscan", "heavy_laser": "hitscan", "pd_laser": "hitscan",
	"tesla_coil": "hitscan", "ion_cannon": "hitscan",
	"arc_projector": "hitscan", "microwave_emitter": "hitscan", "particle_lance": "hitscan",
	"resource_harvester": "hitscan", "repair_array": "hitscan",
	"basic_cannon": "ballistic", "heavy_machine_gun": "ballistic", "rotary_cannon": "ballistic",
	"ciws": "ballistic", "flak_cannon": "ballistic", "flamethrower": "ballistic",
	"artillery": "arc", "mortar_array": "arc", "smoke_discharger": "arc",
	"spigot_mortar": "arc", "rocket_artillery": "arc",
	"chaff_dispenser": "arc", "sensor_beacon_launcher": "arc", "sentry_deployer": "arc",
	"decoy_projector": "arc",
	"laser_dazzler": "hitscan", "jammer_mast": "hitscan",
	"aps_interceptor": "ballistic", "aa_autocannon": "ballistic",
	# Every one of these is interceptable by point defence (they register in
	# the "missiles" group via weapon_missile.gd), which is the property that
	# makes them a different proposition from a gun of the same per-shot number.
	"hypervelocity_missile": "guided", "sam_launcher": "guided",
	"loitering_munition": "guided", "anti_radiation_missile": "guided",
	"bunker_buster": "guided", "cruise_missile": "guided",
	# Roster expansion: a coil gun accelerates a slug the same way a rail
	# does (hitscan); the recoilless/autocannon/ballista all throw a real
	# projectile fast and flat; the grenade launcher, napalm mortar and
	# mine layer all lob.
	"coil_gun": "hitscan",
	"recoilless_rifle": "ballistic", "autocannon": "ballistic", "ballista": "ballistic",
	"anti_materiel_rifle": "ballistic",
	"mk19_grenade_launcher": "arc", "napalm_mortar": "arc", "mine_layer": "arc",
	"cluster_dispenser": "arc", "plasma_lobber": "arc",
	"guided_missile": "guided", "missile_pod": "guided",
	"drone_carrier": "guided",
}

static func get_projectile_class(type_id: String) -> String:
	return PROJECTILE_CLASS.get(type_id, "ballistic")

# Cosmetic-only projectile identity. Nothing here feeds stats, damage,
# range or interception - those stay in FIRE_PROFILES / PROJECTILE_CLASS /
# auto_weapon.gd. Two tables, two readers:
#
# GUN_TRACER_VISUALS drives _fire_kinetic_projectile() for the direct-fire
# guns, which used to share one tracer differing only in radius/length.
# Fields: radius, length, duration (the old positional args), optional
# explode_on_hit, streak (thinner, hotter dart read).
#
# GUIDED_MISSILE_MESH maps a guided launcher to the Blender-authored round
# body its mounted hardware already carries (parts/*.glb), so the round in
# flight is the same shape as the launcher on the vehicle. Missing parts
# fall back to weapon_missile.gd's procedural body.
const GUN_TRACER_VISUALS := {
	"basic_cannon":       {"radius": 0.05, "length": 0.50, "duration": 0.18, "explode_on_hit": true},
	"heavy_machine_gun":  {"radius": 0.015, "length": 0.25, "duration": 0.08},
	"rotary_cannon":      {"radius": 0.012, "length": 0.20, "duration": 0.06, "streak": true},
	"ciws":               {"radius": 0.010, "length": 0.22, "duration": 0.06, "streak": true},
	"autocannon":         {"radius": 0.03, "length": 0.35, "duration": 0.12, "explode_on_hit": true},
}

const GUIDED_MISSILE_MESH := {
	"guided_missile": "missile_body",
	"missile_pod": "missile_pod_missile",
	"sam_launcher": "sam_missile",
	"cruise_missile": "cruise_body",
	"loitering_munition": "loiter_body",
	"anti_radiation_missile": "arm_missile",
	"bunker_buster": "bb_body",
	"hypervelocity_missile": "hvm_body",
}

static func get_gun_tracer_visual(type_id: String) -> Dictionary:
	return GUN_TRACER_VISUALS.get(type_id, {})

static func get_missile_mesh(type_id: String) -> String:
	return GUIDED_MISSILE_MESH.get(type_id, "")

# --- Ammunition types (cross-cutting payload selection) --------------------
#
# Chris's framing: "something firing a shell or payload can also do smoke or
# incendiary or HE". Ammo is a DESIGN-TIME choice per weapon module, stored
# as a plain string in the module's own `tweaks` dict - exactly the pattern
# armor_plating's "material" already uses (see stat_calculator.gd's
# ARMOR_MATERIALS block: "stored in the same tweaks dict so it rides the
# existing save/load path for free"). That choice is load-bearing:
#   - module_data.gd's get_weight()/get_cost()/get_dps() loops all gate on
#     `tweak_name in [...numeric names...]`, so a string under a NEW key
#     falls straight through untouched - no accidental stat corruption.
#   - blueprint_manager.gd copies the whole tweaks dict verbatim on save and
#     load, so persistence needs no new code at all.
#
# The real payoff is `damage_class`. damage_resolver.gd already carries a
# full armor-material x damage-class threshold table, but until now a
# weapon's class was hardcoded once in auto_weapon.gd's _ready() and never
# changed - so that whole matrix was a static property of WHICH GUN you
# bolted on. Ammo makes it a live counter-pick: the same cannon fires AP
# (kinetic - tears ablative_ceramic, bounces off hardened_steel) or HE
# (explosive - good against steel, eaten alive by reactive_armor) or
# incendiary (thermal - melts steel, useless against ablative). None of that
# resolution math is new; it was built and sitting idle.
#
# "standard" is deliberately the default and a genuine no-op (native damage
# class, all multipliers 1.0), so every blueprint saved before this system
# existed behaves EXACTLY as it did before - loading an old design must not
# silently re-tune its guns.
#
# Fields:
#   damage_class  - "" keeps the weapon's own native class, else overrides it
#   damage_mult   - per-shot damage multiplier (0.0 = deals no HP damage)
#   light_mult    - EXTRA multiplier against light/unarmoured targets only
#                   (drones, missiles, aircraft - see auto_weapon.gd's
#                   _is_light_target). This field is what stops the roster
#                   collapsing into one right answer, so it is not optional
#                   flavour: worked through against the real armor tables,
#                   AP came out a STRICT upgrade over standard on every
#                   armor material (81.6 vs 53.6 damage on hardened steel,
#                   94.8 vs 70.2 on ablative), with its only stated cost -
#                   no splash - being nearly free on a single-target gun.
#                   That is precisely the solved-dominant-choice failure
#                   DESIGN_VISION.md warns about. A solid penetrator
#                   over-penetrating a thin-skinned drone (0.4x) gives it a
#                   real class of target it is genuinely bad against, and
#                   makes it the exact mirror of flechette (3.5x) rather
#                   than a free damage upgrade.
#   aoe_mult      - blast radius multiplier (0.0 = no splash, single target)
#   weight_mult   - ammo stowage mass, applied to the module's weight
#   metal_mult /
#   crystal_mult  - per-round cost of the payload
const AMMO_TYPES = {
	"standard": {
		"label": "Standard",
		"damage_class": "", "damage_mult": 1.0, "light_mult": 1.0, "aoe_mult": 1.0,
		"weight_mult": 1.0, "metal_mult": 1.0, "crystal_mult": 1.0,
		"required_building": "",
		"desc": "Balanced service round. No specialisation, no surprises.",
	},
	# Kinetic penetrator: all the energy in one spot, nothing left over for
	# splash. Best against ablative_ceramic (kinetic threshold 8, the lowest
	# in the table); worst against hardened_steel (15, the highest).
	"ap": {
		"label": "Armor-Piercing",
		"damage_class": "kinetic", "damage_mult": 1.25, "light_mult": 0.4, "aoe_mult": 0.0,
		"weight_mult": 1.15, "metal_mult": 1.25, "crystal_mult": 1.0,
		"required_building": "",
		"desc": "Solid penetrator. Concentrates everything on one point and splashes nothing.",
	},
	# Blast round: trades per-shot punch for a much wider blast. Reactive
	# armor's explosive threshold is 30 - by far the hardest wall in the
	# table - so this is the round that gets genuinely countered.
	"he": {
		"label": "High-Explosive",
		"damage_class": "explosive", "damage_mult": 0.85, "light_mult": 1.3, "aoe_mult": 1.6,
		"weight_mult": 1.1, "metal_mult": 1.15, "crystal_mult": 1.0,
		"required_building": "",
		"desc": "Blast-fragmentation filler. Wide effect, poor penetration against sloped plate.",
	},
	# Thermal: hardened_steel's thermal threshold is 5 (its softest row),
	# ablative_ceramic's is 25 (the hardest) - a clean inversion of AP.
	# Also leaves a lingering burn pool at the impact point.
	"incendiary": {
		"label": "Incendiary",
		"damage_class": "thermal", "damage_mult": 0.7, "light_mult": 1.2, "aoe_mult": 1.2,
		"weight_mult": 1.1, "metal_mult": 1.1, "crystal_mult": 1.3,
		"required_building": "tech_lab",
		"desc": "Thickened fuel filler. Burns on after impact. Ineffective against ablative plate.",
	},
	# Anti-swarm: a wide cone of sub-projectiles. Weak per fragment, but
	# carries a large bonus against unarmoured light targets (drones,
	# missiles, anything in the "missiles" group) - see auto_weapon.gd's
	# AMMO_LIGHT_TARGET_MULT.
	"flechette": {
		"label": "Flechette Canister",
		"damage_class": "kinetic", "damage_mult": 0.55, "light_mult": 3.5, "aoe_mult": 2.2,
		"weight_mult": 1.0, "metal_mult": 1.1, "crystal_mult": 1.0,
		"required_building": "tech_lab",
		"desc": "Sub-calibre dart canister. Devastating to light frames, irrelevant to armour.",
	},
	# Energy shell: drains the target's capacitor alongside light HP damage,
	# reusing the same drain_energy() contract tesla_coil/arc_projector use.
	# Gives ballistic weapons a door into the energy tier.
	"emp": {
		"label": "EMP Shell",
		"damage_class": "energy", "damage_mult": 0.5, "light_mult": 1.0, "aoe_mult": 1.0,
		"weight_mult": 1.05, "metal_mult": 1.0, "crystal_mult": 1.7,
		"required_building": "exotics_lab",
		"desc": "Capacitor-discharge warhead. Strips power reserves. Barely scratches structure.",
	},
	# Utility rounds: no HP damage at all. That IS the tradeoff - a gun
	# loaded with smoke is not shooting anyone this reload.
	"smoke": {
		"label": "Smoke",
		"damage_class": "", "damage_mult": 0.0, "light_mult": 1.0, "aoe_mult": 1.0,
		"weight_mult": 0.95, "metal_mult": 0.8, "crystal_mult": 1.0,
		"required_building": "tech_lab",
		"desc": "Obscurant round. Deals no damage. Blocks sightlines and breaks missile lock.",
	},
	"illumination": {
		"label": "Illumination",
		"damage_class": "", "damage_mult": 0.0, "light_mult": 1.0, "aoe_mult": 1.0,
		"weight_mult": 0.95, "metal_mult": 0.8, "crystal_mult": 1.1,
		"required_building": "tech_lab",
		"desc": "Parachute flare. Deals no damage. Burns off fog of war where it lands.",
	},
}

const AMMO_DEFAULT: String = "standard"
# The tweaks-dict key ammo is stored under. Deliberately NOT any name in
# module_data.gd's numeric-tweak lists or LINEAR_SCALE_WEAPON_TWEAKS, so the
# string value can never be fed into a multiplication.
const AMMO_TWEAK_KEY: String = "ammo"

# Which weapons can load which rounds. A weapon absent from this table has
# no ammo selection at all - that's the correct answer for anything without
# a discrete shell or payload to swap (continuous beams, the flamethrower's
# fuel stream, tesla/arc/ion discharges, plasma's self-contained bolt) and
# for the support modules. Per-weapon lists rather than one global list
# because plenty of combinations are nonsense: a CIWS gatling has no
# business firing an illumination flare, and a railgun slug cannot be
# "high-explosive" in any meaningful sense.
const WEAPON_AMMO_OPTIONS = {
	# Full-service artillery pieces and general-purpose guns
	"basic_cannon":      ["standard", "ap", "he", "incendiary", "flechette", "emp", "smoke", "illumination"],
	"artillery":         ["standard", "he", "incendiary", "emp", "smoke", "illumination"],
	"mortar_array":      ["standard", "he", "incendiary", "smoke", "illumination"],
	# HE first and by default: this thing exists to demolish, and a plain
	# service round in a demolition bomb is a wasted trip.
	"spigot_mortar":     ["he", "standard", "incendiary", "smoke"],
	"rocket_artillery":  ["standard", "he", "incendiary", "flechette", "smoke", "illumination"],
	# Deliberately absent: every guided launcher except the bunker buster.
	# A seeker missile carries the warhead it was built with - offering a
	# smoke or flechette option on a SAM would be an ammo dropdown that
	# exists only because the dropdown exists.
	"bunker_buster":     ["standard", "he"],
	"cluster_dispenser": ["standard", "he", "incendiary", "flechette", "smoke"],
	# Automatic weapons - small rounds, so no illumination/blast-filler
	"heavy_machine_gun": ["standard", "ap", "incendiary", "flechette"],
	"rotary_cannon":     ["standard", "ap", "incendiary", "flechette"],
	"ciws":              ["standard", "ap", "flechette"],
	"flak_cannon":       ["standard", "he", "flechette", "emp"],
	# A rail slug is a kinetic mass by definition - only variants that stay
	# kinetic-ish make sense.
	"gauss_railgun":     ["standard", "ap", "emp"],
	# Missiles swap warheads rather than shells, same idea mechanically
	"guided_missile":    ["standard", "he", "incendiary", "emp", "smoke"],
	"missile_pod":       ["standard", "he", "incendiary", "emp"],
	# Roster expansion
	"mk19_grenade_launcher": ["standard", "he", "incendiary", "flechette", "smoke"],
	"recoilless_rifle":  ["standard", "ap", "he", "incendiary", "smoke"],
	"coil_gun":          ["standard", "ap", "emp"],
	"autocannon":        ["standard", "ap", "incendiary", "flechette"],
	# No flechette and no smoke: a precision rifle firing a cloud of darts or
	# a screening round is fighting its own premise. AP listed first is
	# deliberate - it is the round this weapon is FOR.
	"anti_materiel_rifle": ["ap", "standard", "he", "incendiary", "emp"],
	# A dedicated fire weapon - incendiary is its DEFAULT, not an option,
	# hence it heading the list (get_ammo() falls back to options[0]).
	"napalm_mortar":     ["incendiary", "standard", "smoke"],
	"mine_layer":        ["standard", "he", "incendiary"],
	# Flaming ballista bolts are both period-appropriate and, per the
	# straight-faced tone rule, never acknowledged as funny by anyone.
	"ballista":          ["standard", "ap", "incendiary", "smoke"],
	# The dedicated obscurant launcher - the complement to the shell-based
	# smoke above, not a duplicate of it: far larger, faster-blooming clouds,
	# but it can do nothing else whatsoever.
	"smoke_discharger":  ["smoke", "illumination"],
}

static func get_ammo_options(type_id: String) -> Array:
	return WEAPON_AMMO_OPTIONS.get(type_id, [])

static func is_ammo_capable(type_id: String) -> bool:
	return WEAPON_AMMO_OPTIONS.has(type_id)

# Resolves the ammo a module is actually loaded with, validating it against
# that weapon's own allowed list. An unknown or illegal ammo id (a
# hand-edited blueprint, a save from a build where that weapon allowed a
# round it no longer does, a mod) degrades to the weapon's first legal
# option rather than erroring - same forgiving contract get_module_data()
# has for unknown type_ids.
static func get_ammo(type_id: String, tweaks: Dictionary) -> String:
	var options = get_ammo_options(type_id)
	if options.is_empty():
		return AMMO_DEFAULT
	var chosen = tweaks.get(AMMO_TWEAK_KEY, "")
	if typeof(chosen) == TYPE_STRING and chosen in options:
		return chosen
	return options[0]

static func get_ammo_profile(ammo_id: String) -> Dictionary:
	return AMMO_TYPES.get(ammo_id, AMMO_TYPES[AMMO_DEFAULT])


# --- Resource bays ----------------------------------------------------------
# How much cargo one Resource Bay adds to a harvester, before its size tweak.
#
# 40 against a 50-unit base hopper, so the first bay is worth a bit less than
# doubling the trip and the tweak spans 20 to 80. That ratio is the whole
# balance of the module: big enough that one bay is obviously worth fitting on
# a long haul, small enough that bays cannot trivially out-scale the extractor
# arm, which is the other half of harvester throughput. Chosen against the 90kg
# the bay weighs - a medium chassis fits two or three before the drivetrain
# starts arguing, which is the band where the decision is interesting.
const RESOURCE_BAY_CAPACITY := 40.0
const RESOURCE_BAY_TWEAK_KEY: String = "bay_volume"


# Total cargo a hull's Resource Bays contribute, tweaks included.
#
# Lives here rather than in either unit script because there are TWO harvester
# implementations in the tree - unit.gd feeding HarvesterFSM is the only one
# now (battle_unit.gd's inline loop was retired 2026-08-10 in the unification's
# Phase 4) - and a bay that only counted in some past version of the tree
# would be a module that silently did nothing depending on which runtime it
# was loaded under.
# battle runtime spawned the unit. This is the shared answer both ask for.
#
# Bays STACK, unlike most support modules: three bays are three times the
# volume. That is intended - a dedicated hauler is a legitimate design, and the
# thing that stops it running away with the economy is its own mass, not a cap
# written here.
# The same two questions, answered off a SERIALIZED blueprint instead of a live
# hull. The Blueprint Library lists designs straight out of its JSON index and
# never reconstructs them - reconstructing a dozen vehicles to draw a list would
# be absurd - so "is this a harvester" has to be answerable from the modules
# array alone.
#
# Kept beside the live-hull version deliberately: they read the same two type_ids
# and the same tweak key, and splitting them across two files is how one of them
# would eventually learn about a new harvesting module and the other would not.
static func blueprint_harvester_modules(data: Dictionary) -> int:
	var n := 0
	for mod in data.get("modules", []):
		if str(mod.get("type_id", "")) == "resource_harvester":
			n += 1
	return n


static func blueprint_is_harvester(data: Dictionary) -> bool:
	return blueprint_harvester_modules(data) > 0


static func blueprint_bay_capacity(data: Dictionary) -> float:
	var total := 0.0
	for mod in data.get("modules", []):
		if str(mod.get("type_id", "")) != "resource_bay":
			continue
		var tweaks: Dictionary = mod.get("tweaks", {})
		var vol: float = float(tweaks.get(RESOURCE_BAY_TWEAK_KEY, 1.0))
		total += RESOURCE_BAY_CAPACITY * clampf(vol, 0.5, 2.0)
	return total


static func resource_bay_capacity(hull_node) -> float:
	if hull_node == null or not is_instance_valid(hull_node):
		return 0.0
	var total := 0.0
	for child in hull_node.get_children():
		if not child.has_meta("module_data"):
			continue
		var data = child.get_meta("module_data")
		if data == null or data.type_id != "resource_bay":
			continue
		var vol: float = float(data.tweaks.get(RESOURCE_BAY_TWEAK_KEY, 1.0))
		total += RESOURCE_BAY_CAPACITY * clampf(vol, 0.5, 2.0)
	return total

# Tweak names that scale a single part's physical size/mass (shared meaning
# with module_data.gd's get_weight() tweak list, weapon-relevant subset only
# - excludes non-weapon module tweaks like extractor_size/mast_height/
# tank_capacity, and excludes count-type tweaks like multi_barrel/
# barrel_count/tube_count/grid_size/hangar_size, which represent "more
# copies of a part" rather than "one bigger part" and so already affect
# traverse/range purely through the resulting weight change, not an
# additional direct penalty/bonus). Used by auto_weapon.gd to apply a
# consistent per-tweak traverse_speed effect across every weapon type that
# has ANY such tweak, instead of only the two tweak names (barrel_length,
# elevation) that happened to be wired up before.
const LINEAR_SCALE_WEAPON_TWEAKS = ["caliber", "barrel_length", "barrel_count", "drum_size", "motor_size", "rod_thickness", "seeker_size", "ascent_thruster", "payload_size", "nozzle_width", "pressure_valve", "lens_aperture", "containment", "radar_dish", "cooling_jacket", "dispersion", "elevation", "fuse_setting", "optic_power", "focal_length", "charge_rate", "burst_length", "burst_size", "arc_frequency", "surge_capacity", "tracking_speed"]


# --- Leg sets ---------------------------------------------------------------
# Which walking gear a legged chassis is fitted with. Structurally this is the
# AMMO PATTERN above, and deliberately so: one catalog entry ("legs") whose
# character is picked by a single string tweak, rather than six near-duplicate
# locomotion entries that would each need their own layout row, tweak branch,
# terrain table and drivetrain line.
#
# Every set is a three-segment authored chain
# (Bone_Part1_HipMount > Bone_Part2_Thigh > Bone_Part3_ShinFoot) under
# assets/models/parts/leg_<id>.glb, replacing the procedural thigh/shin/foot
# build that visual_builder._build_legs() used to assemble from primitives.
#
# FIELDS
#   mount     Where the leg attaches. "underside" bolts to the hull's belly;
#             "flank" bolts to its side. Not cosmetic - it selects a different
#             GEOMETRY row in locomotion_layout.gd, so the stations genuinely
#             move. Mantis and Crawler are "flank" because they are built with
#             a shoulder: their Part1 reaches outboard before the limb starts,
#             and bolted under a hull that shoulder would be buried in it.
#   drop      MEASURED hip-to-sole distance of the authored mesh, in its own
#             units. _build_legs() divides the target ride height by this to
#             get a uniform scale, which is what stops a taller model from
#             standing the vehicle higher off the ground than a shorter one.
#             If a .glb is re-exported at a different size, THIS NUMBER MUST
#             BE REMEASURED - a stale value silently changes ride height.
#   *_mult    Applied on top of the "legs" entry's own weight (80),
#             base_weight_capacity (468) and base_top_speed (6.5).
#
# The spread is a starting shape to play against, not a balance claim: heavy
# gear carries more and walks slower, light gear the reverse. Crawler is the
# fastest because its foot is a wheel - it rolls rather than steps - and
# Excavator is the load-bearer.
const LEG_TYPES = {
	"stryker": {
		"label": "Stryker",
		"mount": "underside", "drop": 3.55,
		"weight_mult": 1.00, "capacity_mult": 1.00, "speed_mult": 1.00,
		"desc": "Slim tubular strut on a square gearbox. The service standard: no bias in any direction.",
	},
	"apex": {
		"label": "Apex",
		"mount": "underside", "drop": 3.26,
		"weight_mult": 1.10, "capacity_mult": 1.15, "speed_mult": 0.95,
		"desc": "Carbon-shelled thigh over a heavier hip. Carries more than it costs you in pace.",
	},
	"raptor": {
		"label": "Raptor",
		"mount": "underside", "drop": 3.85,
		"weight_mult": 0.90, "capacity_mult": 0.85, "speed_mult": 1.25,
		"desc": "Long digitigrade stride. Quick and light, and it will not carry a heavy turret.",
	},
	"excavator": {
		"label": "Excavator",
		"mount": "underside", "drop": 3.83,
		"weight_mult": 1.45, "capacity_mult": 1.60, "speed_mult": 0.75,
		"desc": "Trussed thigh on hydraulic pistons. Plant-grade load capacity at a walking pace.",
	},
	"mantis": {
		"label": "Mantis",
		"mount": "flank", "drop": 2.50,
		"weight_mult": 1.05, "capacity_mult": 0.95, "speed_mult": 1.10,
		"desc": "Shoulder-mounted coxa with a spiked tibia. Mounts to the hull flank, not the belly.",
	},
	"crawler": {
		"label": "Crawler",
		"mount": "flank", "drop": 3.15,
		"weight_mult": 1.20, "capacity_mult": 1.10, "speed_mult": 1.35,
		"desc": "Suspension arm ending in a driven wheel. Rolls where the others step. Flank-mounted.",
	},
}

const LEG_DEFAULT: String = "stryker"

# The tweaks-dict key the leg set is stored under. Same constraint AMMO_TWEAK_KEY
# documents for itself: deliberately NOT any name in module_data.gd's numeric
# tweak lists or LINEAR_SCALE_WEAPON_TWEAKS, so this string value can never be
# reached by code that expects to multiply by it.
const LEG_TWEAK_KEY: String = "leg_type"


static func get_leg_options() -> Array:
	return LEG_TYPES.keys()


# Resolves the leg set a module is actually fitted with. An unknown id - a
# hand-edited blueprint, a save from a build that shipped a set since renamed,
# a mod - degrades to the default rather than erroring, the same forgiving
# contract get_ammo() and get_module_data() both have.
static func get_leg_type(tweaks: Dictionary) -> String:
	var chosen = tweaks.get(LEG_TWEAK_KEY, "")
	if typeof(chosen) == TYPE_STRING and LEG_TYPES.has(chosen):
		return chosen
	return LEG_DEFAULT


static func get_leg_profile(leg_id: String) -> Dictionary:
	return LEG_TYPES.get(leg_id, LEG_TYPES[LEG_DEFAULT])


## The .glb basename for a leg set. One place that knows the naming convention,
## so renaming an asset is a one-line change rather than a grep.
static func get_leg_part_name(leg_id: String) -> String:
	return "leg_%s" % (leg_id if LEG_TYPES.has(leg_id) else LEG_DEFAULT)

# Weight capacity fallback for any locomotion type_id missing its own
# "base_weight_capacity" entry - a reasonable middle ground between the
# most weight-sensitive type (helicopter_rotors, 252) and the most
# tolerant (buoyant_envelope, 1260).
#
# 2026-08-12: every base_weight_capacity in this file, and this default, were
# multiplied by 1.8. The 60-hull catalogue that replaced the old one is
# substantially heavier - the baseline medium chassis went from 293 to 496, and
# the lightest hull in the game from 104 to 197 - so drives tuned against the
# old weights left most designs overloaded before a single weapon was mounted.
# A uniform factor was used deliberately: the RELATIVE spread between drive
# types is tuned balance (heavy gear carries more and moves slower, light gear
# the reverse) and scaling everything by the same number lifts the band without
# disturbing any of those tradeoffs.
const BASE_WEIGHT_CAPACITY_DEFAULT: float = 720.0

# Per-locomotor-type weight capacity (task: "make the overall vehicle
# Weight stat actually matter" - build a formula, per locomotor type, for
# how much weight it's "built for" carrying, with weight in excess of that
# slowing the unit down). Real-world load-bearing intuition drives each
# value - full reasoning logged as a comment on each locomotion type's own
# catalog entry above. unit.gd's _recalculate_move_speed() sums
# this across every locomotion module actually present (scaled by the same
# size/count factors already used for motor_thrust), then applies a speed
# penalty if the vehicle's total weight exceeds the sum.
## `tweaks` is optional and today only matters for legs, where the fitted set
## (Excavator vs Raptor and so on) genuinely changes what the chassis will
## carry. Optional rather than required so the ~dozen call sites that ask about
## a type in the abstract - catalogue tooltips, balance tables - keep working
## unchanged and keep getting the type's own baseline.
static func get_base_weight_capacity(type_id: String, tweaks: Dictionary = {}) -> float:
	var base: float = get_module_data(type_id).get("base_weight_capacity", BASE_WEIGHT_CAPACITY_DEFAULT)
	return base * _leg_stat_mult(type_id, tweaks, "capacity_mult")

# Per-locomotor-type thrust output. Every existing locomotion type used the
# same flat 150.0-per-scaled-unit coefficient in unit.gd's
# _recalculate_move_speed() - fine when every locomotor's propulsion was
# "an engine/motor fighting for speed," but buoyant_envelope's lift is
# free (buoyancy, not thrust), so its actual engines are small
# cruise/steering motors, not speed engines - it needed a genuinely lower
# coefficient to read as "slow but can carry a lot" rather than identical
# speed to everything else at the same weight. Defaults to the original
# universal 150.0 for every locomotion type that doesn't set its own
# (i.e. everything except buoyant_envelope/screw_drive) so this is a pure
# generalization, not a behavior change for the existing roster.
const THRUST_COEFFICIENT_DEFAULT: float = 150.0

static func get_thrust_coefficient(type_id: String) -> float:
	return get_module_data(type_id).get("thrust_coefficient", THRUST_COEFFICIENT_DEFAULT)

# Per-locomotor-type top speed - the ceiling on how fast a chassis can be
# driven no matter how much thrust is bolted to it (Chris: "each locomotor
# should also have a base top speed").
#
# This replaces the universal 18.0 that used to be hardcoded as the upper
# bound of unit.gd's speed clamp. That single number meant a walker,
# a tank, an airship and a jet all shared one answer to "how fast can this
# possibly go", and the only thing separating them was how much thrust they
# happened to make against their own mass - so a light enough design on ANY
# locomotion converged on the same ceiling, which is exactly the flattening
# FABLE_REVIEW.md 1.4 flagged for the speed band generally.
#
# Every value is set on each locomotion type's own catalog entry above, with
# its reasoning; Drivetrain.analyze() applies them.
#
# The default is the old universal ceiling, so any locomotion type added
# without one keeps the pre-existing behavior rather than silently becoming
# the slowest thing in the game.
const BASE_TOP_SPEED_DEFAULT: float = 18.0

static func get_base_top_speed(type_id: String, tweaks: Dictionary = {}) -> float:
	var base: float = get_module_data(type_id).get("base_top_speed", BASE_TOP_SPEED_DEFAULT)
	return base * _leg_stat_mult(type_id, tweaks, "speed_mult")


## The fitted leg set's multiplier on one stat, or 1.0 for anything that is not
## a leg. One helper rather than an `if type_id == "legs"` at each of the three
## stat sites, so a set can never end up heavier without also being slower
## because someone patched two of the three.
static func _leg_stat_mult(type_id: String, tweaks: Dictionary, key: String) -> float:
	if type_id != "legs":
		return 1.0
	return float(get_leg_profile(get_leg_type(tweaks)).get(key, 1.0))

# Per-locomotor-type x per-surface-type speed multiplier (terrain variety
# task: "genuinely differentiate locomotor types" via terrain, not just
# elevation/water/obstacles). Only ground-contact locomotion types that
# actually touch the surface are listed - airborne types (helicopter_rotors/
# hover_engine/anti_grav/fixed_wing_engine/buoyant_envelope) skip ground
# navigation entirely already (unit.gd's is_flying branch), so they
# never consult this table at all; that's what "hover/anti-grav ignore it"
# means mechanically, not a row of 1.0s here. naval_propeller doesn't touch
# land surface zones either (is_naval routes to water_map only). Any
# (locomotion_type, surface_type) pair not listed defaults to 1.0
# (unaffected) via get_terrain_speed_multiplier()'s fallback - covers those
# irrelevant types automatically and any future locomotion type added
# without terrain tuning.
#
# Real-world handling reasoning per surface, consistent across all four:
#   marsh/swamp   - screw_drive is BUILT for this (real screw-propelled
#                   vehicles are marketed on exactly this capability), gets
#                   a genuine bonus (1.1), not just "unaffected." wheels
#                   sink hardest, treads better but still bog, legs pick
#                   through reasonably (worst of the three, best-off).
#   rocky         - legs are the one locomotion type actually built for
#                   uneven point-contact ground, gets a slight bonus (1.1).
#                   treads spread load across broken rock reasonably.
#                   wheels are worst (a wheel needs a continuous surface).
#                   screw_drive's augers have nothing to dig into on solid
#                   rock - a real penalty, not its best terrain.
#   snow_mud      - wheels bog down hardest (per the task's explicit ask).
#                   treads are the best-suited (wide flotation, historically
#                   the reason tracked vehicles exist). legs sink less than
#                   wheels but still worse than treads. screw_drive does
#                   reasonably (augers grip mud/snow well, just not quite
#                   tread-level flotation).
#   sand          - same shape as snow_mud but slightly gentler penalties
#                   (dry sand isn't as immobilizing as deep mud) - wheels
#                   still worst, treads/legs both handle it well, screw_
#                   drive moderate (augers work best with real grip/water,
#                   dry sand offers less than mud does).
#
# RTS_CORE_ROADMAP.md B7 additions - cross-checked against OpenRA's own
# locomotor-speed convention as a balance reference (RA's Road tileset is
# a genuine speed BONUS over Clear for every locomotor, not just "less of
# a penalty"; Rough/dense terrain hits wheeled harder than tracked/legged):
#   gravel        - the one surface that's a genuine BONUS across the
#                   board (packed road-grade surface, matching RA's Road
#                   tiles), not just "least-penalized" - gives every
#                   surface_zones map a real reason to fight for specific
#                   ground instead of only ever avoiding bad ground.
#                   wheels benefit most (a wheel's ideal surface is
#                   exactly this), legs least (already at their own
#                   natural pace, gravel doesn't help bipedal footing
#                   much).
#   forest        - dense vegetation/undergrowth. Worst for wheels (can't
#                   push through trunks/roots), treads do reasonably
#                   (tracked vehicles historically log/clear terrain),
#                   legs pick through best (weave around obstacles a
#                   wheeled/tracked vehicle can't), screw_drive middling
#                   (augers aren't built for this, but aren't blocked
#                   either).
#   ice           - uniformly slippery - the one surface type that
#                   penalizes every locomotor at least somewhat (unlike
#                   the others, which always have one clear "winner"),
#                   since loss of traction is a whole-vehicle problem, not
#                   a locomotor-specific one. screw_drive suffers least
#                   (its auger bites into ice rather than relying on
#                   friction the way wheels/treads/legs all do).
# Every GROUND-NAVIGATING locomotion type must appear in every row. Airborne
# types (the "airborne" trait sets unit.gd's is_flying) and naval ones
# skip ground navigation entirely and never consult this table, so they are
# deliberately absent rather than missing - see TERRAIN_EXEMPT_TRAITS below,
# which is what test_every_ground_locomotion_type_has_terrain_character()
# checks against so the distinction cannot rot into an accidental omission.
#
# hover_engine WAS an accidental omission: it carries "hovering", not
# "airborne", so it ground-navigates like a wheeled vehicle and was silently
# returning 1.0 on every surface - the one locomotor in the roster with no
# terrain character at all. Ground effect is the whole point of the thing, so
# it now ignores what a wheel sinks into (marsh, snow, sand) and hates what a
# skirt catches on (rocky, forest).
const TERRAIN_SPEED_MULTIPLIERS = {
	"marsh":        {"wheels": 0.25, "tracked_treads": 0.45, "legs": 0.6,  "screw_drive": 1.1,  "hover_engine": 1.15, "half_track": 0.4,  "rocker_bogie": 0.5,  "air_cushion_skirt": 1.2,  "anti_grav_plate": 1.0},
	"rocky":        {"wheels": 0.35, "tracked_treads": 0.75, "legs": 1.1,  "screw_drive": 0.5,  "hover_engine": 0.55, "half_track": 0.5,  "rocker_bogie": 1.15, "air_cushion_skirt": 0.4,  "anti_grav_plate": 1.0},
	"snow_mud":     {"wheels": 0.2,  "tracked_treads": 0.8,  "legs": 0.75, "screw_drive": 0.7,  "hover_engine": 1.1,  "half_track": 0.6,  "rocker_bogie": 0.6,  "air_cushion_skirt": 1.15, "anti_grav_plate": 1.0},
	"sand":         {"wheels": 0.3,  "tracked_treads": 0.85, "legs": 0.8,  "screw_drive": 0.6,  "hover_engine": 1.15, "half_track": 0.55, "rocker_bogie": 0.7,  "air_cushion_skirt": 1.1,  "anti_grav_plate": 1.0},
	"gravel":       {"wheels": 1.25, "tracked_treads": 1.1,  "legs": 1.02, "screw_drive": 1.0,  "hover_engine": 0.95, "half_track": 1.1,  "rocker_bogie": 0.8,  "air_cushion_skirt": 0.85, "anti_grav_plate": 1.0},
	"forest":       {"wheels": 0.3,  "tracked_treads": 0.65, "legs": 0.95, "screw_drive": 0.55, "hover_engine": 0.45, "half_track": 0.5,  "rocker_bogie": 1.0,  "air_cushion_skirt": 0.35, "anti_grav_plate": 1.0},
	"ice":          {"wheels": 0.45, "tracked_treads": 0.5,  "legs": 0.4,  "screw_drive": 0.75, "hover_engine": 1.2,  "half_track": 0.5,  "rocker_bogie": 0.55, "air_cushion_skirt": 1.25, "anti_grav_plate": 1.0},
	"dirt":         {"wheels": 1.05, "tracked_treads": 1.0,  "legs": 1.0,  "screw_drive": 0.9,  "hover_engine": 1.0,  "half_track": 1.0,  "rocker_bogie": 1.0,  "air_cushion_skirt": 1.0,  "anti_grav_plate": 1.0},
	"steppe_grass": {"wheels": 1.0,  "tracked_treads": 1.0,  "legs": 1.0,  "screw_drive": 0.95, "hover_engine": 1.0,  "half_track": 1.0,  "rocker_bogie": 1.0,  "air_cushion_skirt": 1.0,  "anti_grav_plate": 1.0},
	"dry_grass":    {"wheels": 1.02, "tracked_treads": 1.0,  "legs": 1.0,  "screw_drive": 0.95, "hover_engine": 1.0,  "half_track": 1.0,  "rocker_bogie": 1.0,  "air_cushion_skirt": 1.0,  "anti_grav_plate": 1.0},
	"mud":          {"wheels": 0.25, "tracked_treads": 0.6,  "legs": 0.65, "screw_drive": 1.05, "hover_engine": 1.15, "half_track": 0.45, "rocker_bogie": 0.55, "air_cushion_skirt": 1.15, "anti_grav_plate": 1.0},
	"cobble":       {"wheels": 1.3,  "tracked_treads": 1.15, "legs": 1.05, "screw_drive": 0.9,  "hover_engine": 0.9,  "half_track": 1.15, "rocker_bogie": 0.9,  "air_cushion_skirt": 0.8,  "anti_grav_plate": 1.0},
	"scree":        {"wheels": 0.35, "tracked_treads": 0.7,  "legs": 0.95, "screw_drive": 0.5,  "hover_engine": 0.6,  "half_track": 0.5,  "rocker_bogie": 1.1,  "air_cushion_skirt": 0.4,  "anti_grav_plate": 1.0},
	"volcanic":     {"wheels": 0.4,  "tracked_treads": 0.75, "legs": 1.0,  "screw_drive": 0.6,  "hover_engine": 0.7,  "half_track": 0.55, "rocker_bogie": 1.05, "air_cushion_skirt": 0.5,  "anti_grav_plate": 1.0},
}

# A locomotion type carrying any of these never touches a ground surface, so it
# is exempt from the terrain table by design rather than by oversight.
const TERRAIN_EXEMPT_TRAITS := ["airborne", "naval"]

# anti_grav_plate is the deliberate exception: flat 1.0 on every surface is not
# a missing row, it is the entire product. It is listed explicitly, at cost,
# rather than being allowed to fall through to the default - the whole reason
# hover_engine went unnoticed for so long is that a missing row and an
# intentionally flat one looked identical.
const TERRAIN_INTENTIONALLY_FLAT := ["anti_grav_plate"]

static func get_terrain_speed_multiplier(locomotion_type_id: String, surface_type: String) -> float:
	return TERRAIN_SPEED_MULTIPLIERS.get(surface_type, {}).get(locomotion_type_id, 1.0)

# Hull draught (terrain variety task - "shallow water that doesn't allow
# deep-draught hulls" is specifically a hull property, not a locomotor
# one, since two hulls sharing the same naval_propeller locomotion can
# have wildly different real-world draught). Default (0.5) is deliberately
# UNDER the shallow-water threshold - a hull with no explicit "draught"
# entry (i.e. any hull other than the 3 purpose-built naval ones, if
# someone bolts naval_propeller onto a non-naval hull) is NOT blocked from
# shallow water by default, consistent with the no-hard-gating philosophy;
# only hulls that explicitly opt into a real deep-draught number
# (heavy_cruiser_hull) get the hard navmesh block.
# Baseline hull footprint used to derive hull-relative scale factors for
# locomotion visuals (module_placer.gd's underside_y_bias-style block below
# get_underside_y_bias()) - medium_hull's own size, since that's the hull
# every locomotion part's absolute size was originally eyeballed against.
const REFERENCE_HULL_SIZE: Vector3 = Vector3(4.0, 1.0, 6.0)

const HULL_DRAUGHT_DEFAULT: float = 0.5

# Deep-draught-vs-shallow-water cutoff. naval_hull (0.9) and small_boat_hull
# (0.35) both stay under this; heavy_cruiser_hull (1.8) is well over it -
# see unit.gd's _setup_navigation() for where this actually routes
# a unit onto deep_water_map instead of water_map.
const SHALLOW_WATER_DRAUGHT_THRESHOLD: float = 1.0

static func get_hull_draught(hull_type_id: String) -> float:
	return get_module_data(hull_type_id).get("draught", HULL_DRAUGHT_DEFAULT)

# Size-tiered manufactories (base-building batch): which of the 3 production
# tiers (light/medium/heavy) a mobile hull belongs to, by its own base
# weight - domain-agnostic on purpose (a small_boat_hull and an
# interceptor_hull both land in "light" despite one being naval and one
# ground; a heavy_cruiser_hull and a heavy_hull both land in "heavy"), per
# Chris's explicit correction away from an earlier land/sea/air-specific
# shipyard/airfield idea. Foundations (pillbox/tower/fortress_wall) return
# "" - static defenses are built directly via the Armory placement flow,
# never queued from a manufactory at all, so a tier is meaningless for them.
# The tier comes from the hull's DECLARED class when it has one, and only
# falls back to weight breakpoints when it doesn't.
#
# Weight alone used to decide it, with breakpoints picked to split a
# 12-mobile-hull catalogue into even 4/4/4 groups. That catalogue is gone, and
# the breakpoints did not survive it: every hull in the current 60-hull
# catalogue weighs more than the old 150 "light" ceiling (the lightest, a
# Tallow Runabout, is 197), so nothing would have been light and almost
# everything would have been heavy. The concrete symptom was
# brenntal_medium_a - the catalogue's own baseline medium - tiering as HEAVY
# and handing every default harvester a 1.5x hopper.
#
# Deriving from hull_class instead makes the mapping legible and immune to the
# stat formula drifting: build_vehicle_hulls.py writes the class into every
# sidecar, and the six classes collapse onto the three production tiers below.
# Transports and oddballs sit in "heavy" because both are big-chassis hulls -
# the lightest transport still outweighs every medium.
const HULL_TIER_BY_CLASS := {
	"scout": "light", "light": "light",
	"medium": "medium",
	"heavy": "heavy", "transport": "heavy", "oddball": "heavy",
}
# Fallback only, for mod hulls that declare no class. Recalibrated to the
# current catalogue's weight distribution: mediums run 451-666, and the
# heaviest light-class hull is 352.
const HULL_TIER_LIGHT_MAX_WEIGHT: float = 400.0
const HULL_TIER_MEDIUM_MAX_WEIGHT: float = 690.0

static func get_hull_size_tier(hull_type_id: String) -> String:
	var data = get_module_data(hull_type_id)
	if data.get("is_foundation", false):
		return ""
	var declared: String = str(data.get("hull_class", "")).to_lower()
	if HULL_TIER_BY_CLASS.has(declared):
		return HULL_TIER_BY_CLASS[declared]
	var weight = data.get("weight", 0.0)
	if weight <= HULL_TIER_LIGHT_MAX_WEIGHT:
		return "light"
	elif weight <= HULL_TIER_MEDIUM_MAX_WEIGHT:
		return "medium"
	else:
		return "heavy"

# Visual bug pass finding: module_placer.gd's underside-mount locomotion
# placement (wheels/legs/hover_engine) assumes a hull's visual
# bottom sits exactly at its collision box's -halfHeight - true for the
# wedge/box-ish hulls (medium_hull, sponson_hull, etc.) but not for hulls
# whose mesh doesn't fill its box symmetrically (ship hulls' tapered keel,
# airship_hull's curved envelope). Default 0.0 - only the 4 hulls that
# actually need it carry a nonzero value; every box-ish hull is unaffected.
static func get_underside_y_bias(hull_type_id: String) -> float:
	return get_module_data(hull_type_id).get("underside_y_bias", 0.0)

# --- Running gear (locomotion chassis slab) --------------------------------
# Locomotion archetypes whose visible mount point is the underside of the
# hull, and which therefore benefit from a procedural running-gear slab to
# sit between hull and locomotion parts (the test arena's "vehicle slides on
# its belly" bug - the CharacterBody3D's collider was sized to the hull only,
# so a wheeled unit sat on the hull's underside with wheels dangling below
# the collider; a deterministic running-gear slab gives the unit a real flat
# bottom at the right height AND gives the side-mount types a chassis to
# visually attach to, not float against the hull skin).
#
# Excluded: helicopter_rotors, fixed_wing_engine, ornithopter_wing (all
# mounted ABOVE the hull, not on the underside), naval_propeller (stern),
# buoyant_envelope (under the envelope, not the hull). Foundation hulls
# (bunker_main_meridian, rampart_main_meridian, tower_main_meridian) take no
# locomotion at all, so they never need a running gear either.
const LOCOMOTION_TYPES_USING_RUNNING_GEAR: Array = [
	"wheels", "tracked_treads",
	"legs", "screw_drive", "hover_engine",
	# The new ground/amphibious types mount to the chassis for the same reason
	# the originals do: they need a real surface to bolt to, and the unit's
	# collider rests on the chassis bottom. anti_grav_plate is deliberately
	# absent - it projects from the underside, and a slab under it would be
	# visual noise.
	"half_track", "rocker_bogie", "air_cushion_skirt",
]

const LOCOMOTION_TWEAK_SPECS = {
	"wheels": [
		{"name": "wheel_size", "label": "Wheel Size", "min": 0.5, "max": 2.5, "step": 0.1, "default": 1.0},
		{"name": "num_axles", "label": "Axle Count", "min": 2.0, "max": 8.0, "step": 2.0, "default": 4.0},
		{"name": "wheels_per_axle", "label": "Wheels per Axle Side", "min": 1.0, "max": 3.0, "step": 1.0, "default": 1.0}
	],
	"helicopter_rotors": [
		{"name": "rotor_units", "label": "Rotor Units", "min": 1.0, "max": 4.0, "step": 1.0, "default": 1.0},
		{"name": "blade_count", "label": "Blades per Rotor", "min": 2.0, "max": 8.0, "step": 1.0, "default": 4.0},
		{"name": "blade_length", "label": "Blade Length", "min": 0.5, "max": 2.0, "step": 0.1, "default": 1.0},
		{"name": "duct", "label": "Ducted Shroud", "type": "bool", "default": false}
	],
	"tracked_treads": [
		{"name": "tread_width", "label": "Tread Track Width", "min": 0.5, "max": 2.5, "step": 0.1, "default": 1.0},
		{"name": "drive_sprocket", "label": "Exposed Sprocket", "type": "bool", "default": true}
	],
	"heavy_quad_tracks": [
		{"name": "track_count", "label": "Track Pod Count", "min": 4.0, "max": 6.0, "step": 2.0, "default": 4.0},
		{"name": "tread_width", "label": "Tread Track Width", "min": 0.5, "max": 2.5, "step": 0.1, "default": 1.0}
	],
	# Knee Height is gone. It was meaningful while the limb was solved as two
	# spans between computed points - it decided where the knee sat. The six
	# authored sets have the knee where the artist put it, so the slider had
	# nothing left to move; Leg Length and Leg Width are the two dimensions that
	# still genuinely apply to a finished model.
	"legs": [
		{"name": "leg_count", "label": "Leg Count", "min": 2.0, "max": 8.0, "step": 2.0, "default": 4.0},
		{"name": "leg_length", "label": "Leg Length", "min": 0.5, "max": 2.0, "step": 0.05, "default": 1.0},
		{"name": "leg_width", "label": "Leg Width", "min": 0.5, "max": 2.0, "step": 0.05, "default": 1.0},
		{"name": "foot_size", "label": "Foot Pad Size", "min": 0.5, "max": 2.0, "step": 0.1, "default": 1.0}
	],
	"hover_engine": [
		{"name": "pad_count", "label": "Pad Count", "min": 4.0, "max": 8.0, "step": 1.0, "default": 4.0},
		{"name": "emv_level", "label": "Electron Megavoltage", "min": 0.5, "max": 2.5, "step": 0.1, "default": 1.0}
	],
	"fixed_wing_engine": [
		{"name": "engine_count", "label": "Engine Count", "min": 2.0, "max": 6.0, "step": 1.0, "default": 2.0},
		{"name": "turbine_compression", "label": "Turbine Compression", "min": 0.5, "max": 2.0, "step": 0.1, "default": 1.0},
		{"name": "afterburner", "label": "Afterburner Ring", "type": "bool", "default": false}
	],
	"ornithopter_wing": [
		{"name": "wingspan", "label": "Wingspan", "min": 0.5, "max": 2.5, "step": 0.1, "default": 1.0},
		{"name": "wing_sweep", "label": "Wing Sweep Angle", "min": 0.5, "max": 1.5, "step": 0.1, "default": 1.0}
	],
	# Was one of a pair with naval_propeller, which shared this pylon-mounted
	# propeller geometry (a 2026-07-24 rebuild) and got its own unique slider
	# so the two were a design choice, not just a stats choice. naval_propeller
	# is gone (the naval theatre never got real design attention); this stays,
	# since buoyant_envelope is airborne, not naval.
	"buoyant_envelope": [
		{"name": "prop_count", "label": "Propeller Count", "min": 1.0, "max": 5.0, "step": 1.0, "default": 2.0},
		{"name": "blade_count", "label": "Blades per Propeller", "min": 2.0, "max": 6.0, "step": 1.0, "default": 3.0},
		{"name": "blade_pitch", "label": "Blade Pitch", "min": 0.5, "max": 1.5, "step": 0.1, "default": 1.0},
		# Lift is free and scales with displaced volume, so a bigger envelope
		# carries far more - and pushes far more air out of the way doing it.
		{"name": "envelope_volume", "label": "Envelope Volume", "min": 0.6, "max": 2.0, "step": 0.1, "default": 1.0}
	],
	"half_track": [
		{"name": "bogie_count", "label": "Track Bogie Count", "min": 2.0, "max": 5.0, "step": 1.0, "default": 3.0},
		{"name": "front_axle_size", "label": "Front Axle Size", "min": 0.6, "max": 1.8, "step": 0.1, "default": 1.0},
		{"name": "tread_width", "label": "Track Width", "min": 0.5, "max": 2.0, "step": 0.1, "default": 1.0}
	],
	"rocker_bogie": [
		{"name": "bogie_pairs", "label": "Bogie Pairs", "min": 2.0, "max": 5.0, "step": 1.0, "default": 3.0},
		{"name": "arm_length", "label": "Rocker Arm Length", "min": 0.6, "max": 1.8, "step": 0.1, "default": 1.0},
		{"name": "wheel_size", "label": "Wheel Size", "min": 0.6, "max": 2.0, "step": 0.1, "default": 1.0}
	],
	"air_cushion_skirt": [
		{"name": "skirt_diameter", "label": "Skirt Diameter", "min": 0.6, "max": 2.0, "step": 0.1, "default": 1.0},
		{"name": "lift_fan_count", "label": "Lift Fan Count", "min": 2.0, "max": 6.0, "step": 1.0, "default": 3.0},
		{"name": "plenum_pressure", "label": "Plenum Pressure", "min": 0.5, "max": 1.8, "step": 0.1, "default": 1.0}
	],
	"anti_grav_plate": [
		{"name": "plate_count", "label": "Plate Count", "min": 3.0, "max": 8.0, "step": 1.0, "default": 4.0},
		{"name": "field_strength", "label": "Field Strength", "min": 0.5, "max": 2.2, "step": 0.1, "default": 1.0},
		{"name": "stabilizer_ring", "label": "Stabiliser Ring", "type": "bool", "default": true}
	],
	# Rebuilt (Chris's ask, 2026-07-24): drum_count is gone - always one
	# drum per side now (like tracked_treads), spanning the hull's real
	# fore-aft length with a gearbox at each end instead of a fixed-length
	# floating shaft. drum_width renamed to drum_diameter; helix_depth is
	# new (picks among 3 discrete authored flighting-depth variants - see
	# _build_screw_drive()).
	"screw_drive": [
		{"name": "drum_diameter", "label": "Drum Diameter", "min": 0.5, "max": 2.0, "step": 0.1, "default": 1.0},
		{"name": "helix_depth", "label": "Helix Depth", "min": 0.5, "max": 1.5, "step": 0.1, "default": 1.0}
	]
}

# --- Count-style tweak normalization ---------------------------------------
# A "count" tweak is declared as a raw quantity - 4 tubes, 6 barrels, 3 lift
# fans - but every stat that reads one wants a MULTIPLIER relative to the
# module as shipped. module_data.gd used to get that multiplier by dividing by
# a literal: barrel_count/6.0, tube_count/2.0, grid_size/4.0. Each of those
# literals is exactly one module's declared default and therefore the wrong
# number for every other module that owns the same tweak.
#
# It stayed invisible because `tweaks` is empty until a slider is touched. An
# untouched basic_cannon is 40 dps / 80 kg / 30 metal; the first nudge of its
# Barrel Count slider rewrote it to 6.7 dps / 13 kg / 5 metal - a 1/6 haircut,
# because its default is one barrel and the divisor was six - and the Design
# Lab then saved that into the blueprint. Nine weapons were mis-scaled this
# way. rotary_cannon, the module the 6.0 was copied from, was the only one the
# divisor ever fitted.
#
# So the normalizer is keyed by (type_id, tweak) and IS the module's own
# declared default. The multiplier is then exactly 1.0 for an untouched module
# and scales linearly from there, which is what every call site already
# assumed it did.

# Mirror of the "default" field of every count-style tweak in
# stat_calculator.gd's TWEAK_SPECS. A mirror because the dependency runs one
# way only: stat_calculator.gd preloads module_data.gd, which preloads this
# file, so this file cannot reach back for TWEAK_SPECS without a cycle.
#
# Mirrored tables in this codebase drift - see the comments in
# design_verdict.gd and drivetrain.gd for the last two times one did. The
# guard here is tests/test_stat_model.gd's
# test_count_tweak_normalizer_matches_declared_defaults, which walks both spec
# tables and fails the moment one of these numbers stops matching its slider.
const COUNT_TWEAK_DEFAULTS := {
	"basic_cannon":             {"barrel_count": 1.0},
	"rotary_cannon":            {"barrel_count": 6.0},
	"artillery":                {"barrel_count": 1.0},
	"guided_missile":           {"barrel_count": 1.0},
	"flak_cannon":              {"barrel_count": 2.0},
	"mortar_array":             {"tube_count": 2.0},
	"cluster_dispenser":        {"tube_count": 2.0},
	"chaff_dispenser":          {"tube_count": 4.0},
	"rocket_artillery":         {"tube_count": 4.0},
	"hypervelocity_missile":    {"tube_count": 2.0},
	"sam_launcher":             {"tube_count": 2.0},
	"loitering_munition":       {"tube_count": 2.0},
	"anti_radiation_missile":   {"tube_count": 2.0},
	"mine_layer":               {"tube_count": 1.0},
	"smoke_discharger":         {"tube_count": 4.0},
	"missile_pod":              {"grid_size": 4.0},
	"sentry_deployer":          {"hangar_size": 2.0},
	"drone_carrier":            {"hangar_size": 2.0},
	"repair_array":             {"welder_count": 2.0},
	"energy_barrier_projector": {"coil_count": 4.0},
	"hub_motor_array":          {"coil_count": 4.0},
	"fire_control_radar":       {"array_faces": 2.0},
	"capacitor_bank":           {"bank_capacity": 4.0},
	"solid_state_battery":      {"cell_layers": 4.0},
	"booster_rack":             {"nozzle_count": 3.0},
}

# Which tweak names are counts at all, mapped to the literal divisor
# module_data.gd applied before any of this was per-module. Serves two jobs:
# it is the membership test ("is this a count tweak?") and it is the fallback
# for a type that carries one of these tweaks without declaring it in either
# spec table. Falling back to the old literal means such a type keeps behaving
# exactly as it did rather than dividing by zero, or by a 1.0 nobody chose.
#
# foil_count is declared by nothing in TWEAK_SPECS or LOCOMOTION_TWEAK_SPECS -
# it is a leftover in module_data.gd's list. Kept at its old 2.0 because
# deleting it is an unrelated change, not because anything reaches it.
const COUNT_TWEAK_LEGACY_DIVISORS := {
	"barrel_count": 6.0,
	"tube_count": 2.0,
	"welder_count": 2.0,
	"hangar_size": 2.0,
	"prop_count": 2.0,
	"engine_count": 2.0,
	"array_faces": 2.0,
	"nozzle_count": 2.0,
	"foil_count": 2.0,
	"grid_size": 4.0,
	"num_axles": 4.0,
	"blade_count": 4.0,
	"rotor_units": 4.0,
	"leg_count": 4.0,
	"pad_count": 4.0,
	"coil_count": 4.0,
	"bank_capacity": 4.0,
	"bogie_count": 4.0,
	"bogie_pairs": 4.0,
	"lift_fan_count": 4.0,
	"plate_count": 4.0,
}

static func is_count_tweak(tweak_name: String) -> bool:
	return COUNT_TWEAK_LEGACY_DIVISORS.has(tweak_name)

# The divisor that turns a raw count into a multiplier for this module. Returns
# the module's declared default, so count == default yields exactly 1.0.
static func count_tweak_normalizer(type_id: String, tweak_name: String) -> float:
	var declared := -1.0
	var per_type: Dictionary = COUNT_TWEAK_DEFAULTS.get(type_id, {})
	if per_type.has(tweak_name):
		declared = float(per_type[tweak_name])
	elif LOCOMOTION_TWEAK_SPECS.has(type_id):
		# Locomotion needs no mirror at all: LOCOMOTION_TWEAK_SPECS is declared
		# forty lines up in this same file, so the declared default is read
		# straight off it and there is nothing that can drift.
		for spec in LOCOMOTION_TWEAK_SPECS[type_id]:
			if spec.get("name", "") == tweak_name:
				declared = float(spec.get("default", -1.0))
				break
	# A count of zero is not a real default and dividing by it produces INF
	# rather than a stat, so anything without a usable declared default drops
	# to the pre-fix literal - which at worst reproduces the old behaviour
	# instead of inventing a new one.
	if declared > 0.0:
		return declared
	return float(COUNT_TWEAK_LEGACY_DIVISORS.get(tweak_name, 1.0))

static func get_locomotion_contribs(type_id: String, settings: Dictionary) -> Dictionary:
	var thrust = 1.0
	var capacity = 0.0
	match type_id:
		"wheels":
			var num_axles = settings.get("num_axles", settings.get("count", 4.0) / 2.0)
			var w_per_axle = settings.get("wheels_per_axle", 1.0)
			var size = settings.get("wheel_size", settings.get("size", 1.0))
			thrust = (num_axles * w_per_axle * 2.0) / 4.0 * size
			capacity = (num_axles * w_per_axle * 2.0) / 4.0 * size * 100.0
		"tracked_treads":
			var width = settings.get("tread_width", settings.get("width", 1.0))
			var sprocket = settings.get("drive_sprocket", true)
			# An exposed drive sprocket meshes directly with the track and puts
			# power down harder; tucking it inside the hull line protects it but
			# costs some of that drive. This toggle was purely cosmetic until
			# test_every_locomotion_type_is_fully_declared caught it - the only
			# tweak in the roster that changed the model and nothing else.
			thrust = width * (1.0 if sprocket else 0.88)
			capacity = width * 150.0
		"legs":
			var count = settings.get("leg_count", settings.get("count", 4.0))
			var length = settings.get("leg_length", settings.get("size", 1.0))
			var foot_size = settings.get("foot_size", 1.0)
			var width = settings.get("leg_width", 1.0)
			# The two dimensions pull in opposite directions, which is what makes
			# choosing between them a decision rather than a slider to max out.
			# LENGTH is stride: a longer leg covers more ground per step, so it
			# drives thrust. WIDTH is section: a thicker limb bears more load but
			# is more mass to swing, so it buys capacity and costs a little
			# thrust. Both are 1.0 at their defaults, so a design that never
			# touches them is unpenalised.
			#
			# This replaces knee_height, which had the same shape of tradeoff
			# (stride vs stance) but no longer has any geometry to move now the
			# limbs are authored - see the LOCOMOTION_TWEAKS comment above.
			thrust = (count / 4.0) * length * (1.10 - 0.10 * clampf(width, 0.5, 2.0))
			capacity = (count / 4.0) * foot_size * 120.0 * (0.72 + 0.28 * clampf(width, 0.5, 2.0))
		"hover_engine":
			var count = settings.get("pad_count", 4.0)
			var emv = settings.get("emv_level", 1.0)
			thrust = count / 4.0
			capacity = (count / 4.0) * emv * 160.0
		"helicopter_rotors":
			var units = settings.get("rotor_units", settings.get("count", 1.0))
			var blades = settings.get("blade_count", 4.0)
			var length = settings.get("blade_length", settings.get("size", 1.0))
			var duct = settings.get("duct", false)
			thrust = units * (0.8 + 0.05 * blades) * length * (1.15 if duct else 1.0)
			# Rotary lift carries payload as well as speed - a bigger rotor
			# raises max-takeoff-weight, it does not just go faster. Five types
			# (this, fixed_wing, ornithopter, naval, envelope) returned capacity
			# 0.0, so every tweak on half the roster moved speed and nothing
			# else, while every ground type's tweaks moved both. Coefficients
			# are set so a default build lands near its base_weight_capacity
			# and the extremes stay inside the band the ground types occupy.
			capacity = units * (blades / 4.0) * length * 60.0
		"fixed_wing_engine":
			var count = settings.get("engine_count", settings.get("count", 2.0))
			var compression = settings.get("turbine_compression", 1.0)
			var afterburner = settings.get("afterburner", false)
			thrust = (count / 2.0) * compression * (1.3 if afterburner else 1.0)
			# Airspeed-assisted lift: more engine means more payload, but an
			# afterburner is thrust only - it buys nothing you can carry.
			capacity = (count / 2.0) * compression * 80.0
		"ornithopter_wing":
			var wingspan = settings.get("wingspan", settings.get("size", 1.0))
			var sweep = settings.get("wing_sweep", 1.0)
			# Sweeping the wings back trades lift for speed, as it does on
			# anything that flies. Cosmetic until now - it reshaped the membrane
			# and changed nothing the player was choosing between.
			thrust = wingspan * (0.85 + 0.30 * sweep)
			capacity = wingspan * 70.0 * (1.15 - 0.25 * sweep)
		"buoyant_envelope":
			# Same pylon-mounted prop formula the old naval_propeller used, but
			# attenuated (0.6x) - buoyancy does the lifting here, not the
			# motors (see the catalog entry's own comment), so a bigger
			# prop cluster shouldn't scale thrust as hard as it does for a
			# real thrust-driven boat screw.
			var count = settings.get("prop_count", settings.get("count", 2.0))
			var pitch = settings.get("blade_pitch", 1.0)
			var blades = settings.get("blade_count", 3.0)
			var volume = settings.get("envelope_volume", 1.0)
			# Lift is free and scales with displaced volume, so envelope_volume
			# is almost pure capacity - and costs thrust, because a bigger gasbag
			# is a bigger thing to push through the air.
			thrust = (count / 2.0) * pitch * (0.85 + 0.05 * blades) * 0.6 / max(0.6, volume * 0.85 + 0.15)
			capacity = (count / 2.0) * pitch * volume * 90.0
		"half_track":
			# Reads as the compromise it is: the tracked bogies carry the load,
			# the front axle contributes speed rather than payload.
			var bogies = settings.get("bogie_count", 3.0)
			var front = settings.get("front_axle_size", 1.0)
			var tw = settings.get("tread_width", 1.0)
			thrust = (bogies / 3.0) * 0.7 + front * 0.45
			capacity = (bogies / 3.0) * tw * 190.0
		"rocker_bogie":
			# Every wheel stays loaded over broken ground, so capacity scales
			# with wheel count directly; long arms buy articulation, not speed.
			var pairs = settings.get("bogie_pairs", 3.0)
			var arm = settings.get("arm_length", 1.0)
			var wsize = settings.get("wheel_size", 1.0)
			# Long arms articulate further over obstacles but put the wheels on
			# more leverage, which costs drive - the type's own slow/sure pitch
			# expressed as a slider.
			thrust = (pairs / 3.0) * wsize * 0.85 * (1.15 - 0.20 * arm)
			capacity = (pairs / 3.0) * wsize * 210.0 * (0.90 + 0.14 * arm)
		"air_cushion_skirt":
			var diameter = settings.get("skirt_diameter", 1.0)
			var fans = settings.get("lift_fan_count", 3.0)
			var plenum = settings.get("plenum_pressure", 1.0)
			# Cushion area carries the weight; fans and pressure move it.
			thrust = (fans / 3.0) * plenum
			capacity = diameter * diameter * plenum * 210.0
		"anti_grav_plate":
			var plates = settings.get("plate_count", 4.0)
			var field = settings.get("field_strength", 1.0)
			var ring = settings.get("stabilizer_ring", true)
			thrust = (plates / 4.0) * field * (1.0 if ring else 1.15)
			# The stabiliser ring is the trade: steadier and stronger lift, or
			# drop it for raw speed and carry less.
			capacity = (plates / 4.0) * field * (110.0 if ring else 70.0)
		"screw_drive":
			# drum_count is gone (always a fixed pair now) - matches
			# tracked_treads' pattern, no count factor.
			var diameter = settings.get("drum_diameter", settings.get("drum_width", settings.get("size", 1.0)))
			var depth = settings.get("helix_depth", 1.0)
			# Deeper flighting bites harder into mud, snow and water - which is
			# the entire reason a screw drive exists - at the cost of dragging
			# more of it along. Cosmetic until now.
			thrust = diameter * (0.80 + 0.24 * depth)
			capacity = diameter * 160.0 * (1.08 - 0.10 * depth)
	return {"thrust": thrust, "capacity": capacity}

# Per-axis scale of the running-gear slab relative to the hull footprint.
# 0.95 inset on XZ (so the chassis tucks inside the hull edge by 2.5% per
# side, a sensible default for a chassis that's not wider than the vehicle
# it supports) and a clamped fraction of hull height for Y (so tall hulls
# get a more prominent chassis without becoming comical, short hulls still
# get enough clearance for default-size wheels).
# 0.90: the subframe sits 5% in from each edge of the hull (Chris's ask). At
# 0.95 it tracked the hull's silhouette so closely that it read as part of the
# hull rather than as a chassis slung under it, and on hulls whose sides taper
# it poked out past the skin.
const RUNNING_GEAR_XZ_INSET: float = 0.90
const RUNNING_GEAR_HEIGHT_MIN: float = 0.2
const RUNNING_GEAR_HEIGHT_MAX: float = 0.6
const RUNNING_GEAR_HEIGHT_FRACTION: float = 0.4

## Whether a locomotion type rests on the ground, and so whether the hull should
## be lifted until its lowest geometry touches. Airborne, naval and buoyant types
## hold themselves up and must NOT be pushed down onto the terrain.
static func locomotion_touches_ground(locomotion_type: String) -> bool:
	var traits: Array = get_module_data(locomotion_type).get("traits", [])
	for t in ["airborne", "naval", "buoyant"]:
		if t in traits:
			return false
	return "ground_contact" in traits or "hovering" in traits


## Always false now. Chris asked for the running-gear slab dropped from
## everything (2026-08-02), along with the subframe. Both existed to give
## locomotion a structure to mount to under the hull; both ended up as a second
## body under every vehicle that the per-type mounting had to fight. Ground
## contact is measured from where the locomotion geometry actually ends
## (module_placer.gd's lift block), which is what the slab was really for.
##
## Kept as a function rather than deleted so the three call sites - the
## designer placer, the battle spawner and battle_unit's collider - stay
## visibly wired to one decision instead of each growing its own copy of it.
## LOCOMOTION_TYPES_USING_RUNNING_GEAR is left in place for the same reason:
## it records which types ever wanted one.
static func needs_running_gear(_locomotion_type: String) -> bool:
	return false

# Deterministic running-gear dimensions for a given (already-scaled) hull
# size. Pure/static so unit.gd can compute the chassis height for
# the CharacterBody3D's collider without needing the chassis to actually
# exist as a node yet - and so it stays in sync with whatever
# module_placer.gd / blueprint_manager.gd build.
static func get_running_gear_size(hull_size: Vector3) -> Vector3:
	return Vector3(
		hull_size.x * RUNNING_GEAR_XZ_INSET,
		clamp(hull_size.y * RUNNING_GEAR_HEIGHT_FRACTION, RUNNING_GEAR_HEIGHT_MIN, RUNNING_GEAR_HEIGHT_MAX),
		hull_size.z * RUNNING_GEAR_XZ_INSET
	)

# Facet = one of the hull's 6 axis-aligned box faces (see
# MOUNTING_AND_ARMOR_SPEC.md's "Known architecture constraint"). Shared
# between placement (module_placer.gd - armor centering, mount style) and
# combat (damage_resolver.gd - directional armor hit resolution), so both
# always agree on what "the front" or "the left side" means for a given
# local-space direction vector. "front" matches the -Z barrel-forward
# convention used throughout the codebase.
static func classify_facet(local_direction: Vector3) -> String:
	var abs_n = local_direction.abs()
	if abs_n.x > abs_n.y and abs_n.x > abs_n.z:
		return "right" if local_direction.x > 0 else "left"
	elif abs_n.z > abs_n.y:
		return "back" if local_direction.z > 0 else "front"
	else:
		return "top" if local_direction.y > 0 else "bottom"

# Single source of truth for weapon traverse limits, shared between the
# runtime combat AI (auto_weapon.gd) and the Design Lab firing-arc
# visualization (module_placer.gd) - they must never drift apart, since the
# whole point of the visualization is to show players what the weapon will
# actually do in combat. Per mount style (3 buckets, see get_mount_style()):
#   frame_built -> 0  (whole vehicle aims, the barrel is fixed)
#   turret      -> 2pi (basic_cannon's enclosed rotating structure - the
#                        existing tank-cannon visual stays, per spec)
#   pintle      -> 2pi (column-axis independent-traverse mount - 360 azimuth
#                        + 90 elevation away from the hull. This replaces
#                        the old per-facet dispatch where sponson got a
#                        60-degree arc and top/bottom pintles got 360. Now
#                        every independent-traverse mount is the same.)
# hull_type_id (optional) generalizes "frame_built" from weapon-type-gated
# to turreted_capable-trait-gated (MOUNTING_AND_ARMOR_SPEC.md addendum):
# on a hull that doesn't support independent traverse, EVERYTHING gets zero
# traverse - whole vehicle aims, no matter what the weapon type is.
# Omitting hull_type_id keeps the original weapon-type-only behavior.
# facet arg is kept for backward compat with any callers that still pass
# it; it's ignored now since the new model is mount-style-only.
#
# `sponson` narrows that: a weapon embedded in a near-vertical face
# (module_placer._is_sponson_mount) sits in a housing and cannot swing back
# through the hull it is buried in, so it gets a real forward arc rather than
# free rotation. It is passed as its own flag and NOT derived from `facet`,
# because facet is a dominant-axis label - a 45-degree glacis mount is facet
# "front" too, and it is flush, not sponsoned. Combat reads the module's
# "sponson" meta (auto_weapon._ready) and the Design Lab arc visualiser reads
# the same meta, so the two cannot disagree.
#
# Half-angle, like every value this function returns: SPONSON_TRAVERSE_LIMIT
# of 60 degrees means 60 either side of the housing's outboard heading, a
# 120-degree total sweep. Comfortably above auto_weapon's
# MIN_ACQUISITION_ARC (0.26 rad) floor, so it is never silently widened.
const SPONSON_TRAVERSE_LIMIT := deg_to_rad(60.0)

static func get_traverse_limit_angle(type_id: String, _facet: String = "", hull_type_id: String = "", sponson: bool = false) -> float:
	if hull_type_id != "" and not is_turreted_capable(hull_type_id):
		return 0.0
	var style = get_mount_style(type_id, hull_type_id)
	if style == "frame_built":
		return 0.0
	if sponson:
		return SPONSON_TRAVERSE_LIMIT
	if style in ["turret", "pintle"]:
		return PI # 360 degrees
	return PI # 360 degrees (every other mount is a pintle, all get 360)

# --- Elevation limits ------------------------------------------------------
# Chris, 2026-08-03: "we need to differentiate the elevation available to each
# different weapon. PD weapons should absolutely be able to point straight up
# and target units or missiles directly above. Machine gun and gatling too, as
# well as SAM launcher and Anti-radiation missile. Then it needs to move down
# from there, an artillery piece isn't being used to engage things above you
# for example, where a cannon may, but it isn't going to be able to elevate to
# above a 45 degree angle."
#
# Before this, elevation was not modelled AT ALL. auto_weapon.gd gated targets
# on a single symmetric yaw cone with no vertical term, and the Design Lab's
# arc visualiser used one hardcoded pair of stops (88 degrees up AND down) for
# every weapon in the roster, with a comment saying it was a placeholder for
# exactly this work. So a howitzer could track an aircraft directly overhead,
# and a CIWS was no better at it than the howitzer.
#
# WHAT "up" MEANS HERE. This is ENGAGEMENT elevation - the angle above its own
# horizon at which the weapon can acquire and hit something. It is deliberately
# NOT the barrel's mechanical elevation. A howitzer's tube physically sits at
# 45-70 degrees, but it is throwing a shell at a GROUND target over a distance;
# it cannot service a target that is itself above it. Conflating the two would
# hand artillery an anti-air capability it should never have. The ballistic use
# of barrel angle is already modelled separately, and unchanged: the `elevation`
# tweak buys fire_range in weapon_range.gd.
#
# Angles are degrees from the weapon's own horizon, and "up" is along the
# weapon's OWN local +Y. For a flush mount that IS the surface normal it was
# mounted on - so a belly-mounted gun's "up" points at the ground, and it
# correctly cannot shoot up through its own hull. For a sponson (2026-08-04,
# near-vertical faces) local +Y is hull-up instead, so these stops measure
# against the real horizon; see auto_weapon._within_elevation() for why that
# is the correct reading and not an exception. Same convention
# auto_weapon.gd's LOS offset uses.
const ELEVATION_DEFAULT := {"up": 55.0, "down": 12.0}

const ELEVATION_LIMITS := {
	# --- Straight up (90) -----------------------------------------------
	# Point defence, named explicitly by Chris. Their entire job is killing
	# things directly overhead, and a PD gun that cannot look up is furniture.
	"pd_laser":            {"up": 90.0, "down": 20.0},
	"ciws":                {"up": 90.0, "down": 20.0},
	"aps_interceptor":     {"up": 90.0, "down": 25.0},
	# Machine gun and gatling, also named. A pintle MG on a high ring mount
	# genuinely does point vertically, and it is the classic light-AA answer.
	"heavy_machine_gun":   {"up": 90.0, "down": 15.0},
	"rotary_cannon":       {"up": 90.0, "down": 18.0},
	# Named: both are launch rails, and a rail can be brought fully vertical.
	"sam_launcher":        {"up": 90.0, "down": 5.0},
	"anti_radiation_missile": {"up": 90.0, "down": 8.0},
	# NOT in Chris's list, but included deliberately: these are the roster's
	# two DEDICATED anti-air guns. It would be incoherent for a general-purpose
	# machine gun to out-elevate the purpose-built AA autocannon sitting next
	# to it, and an AA gun that cannot engage overhead has no reason to exist.
	"aa_autocannon":       {"up": 88.0, "down": 10.0},
	"flak_cannon":         {"up": 85.0, "down": 8.0},
	# --- High, but not vertical (70-80) ---------------------------------
	# Light/medium autoguns and short-range missiles: high-angle capable,
	# stopping short of true vertical because the mount or the feed gets in
	# the way.
	"autocannon":          {"up": 78.0, "down": 12.0},
	"missile_pod":         {"up": 75.0, "down": 6.0},
	"hypervelocity_missile": {"up": 72.0, "down": 6.0},
	"guided_missile":      {"up": 70.0, "down": 6.0},
	"laser_dazzler":       {"up": 80.0, "down": 20.0},
	"jammer_mast":         {"up": 85.0, "down": 20.0},
	"chaff_dispenser":     {"up": 85.0, "down": 10.0},
	"decoy_projector":     {"up": 80.0, "down": 15.0},
	"sensor_beacon_launcher": {"up": 70.0, "down": 5.0},
	# --- Directed energy (50-65) ----------------------------------------
	# A beam has no recoil path to fight, but the emitter housing and its
	# cooling still limit how far the whole assembly tips back.
	"heavy_laser":         {"up": 60.0, "down": 15.0},
	"ion_cannon":          {"up": 55.0, "down": 12.0},
	"particle_lance":      {"up": 50.0, "down": 10.0},
	"tesla_coil":          {"up": 65.0, "down": 15.0},
	"arc_projector":       {"up": 60.0, "down": 20.0},
	"microwave_emitter":   {"up": 65.0, "down": 18.0},
	# --- Direct-fire guns (~45) -----------------------------------------
	# Chris's own figure for a cannon: "a cannon may, but it isn't going to be
	# able to elevate to above a 45 degree angle (probably)". The breech comes
	# back into the turret roof or the hull deck long before vertical.
	"basic_cannon":        {"up": 45.0, "down": 10.0},
	"recoilless_rifle":    {"up": 45.0, "down": 12.0},
	"anti_materiel_rifle": {"up": 42.0, "down": 15.0},
	"coil_gun":            {"up": 40.0, "down": 10.0},
	"gauss_railgun":       {"up": 30.0, "down": 8.0},
	"ballista":            {"up": 45.0, "down": 10.0},
	"flamethrower":        {"up": 40.0, "down": 20.0},
	"plasma_lobber":       {"up": 50.0, "down": 10.0},
	"cluster_dispenser":   {"up": 45.0, "down": 8.0},
	"bunker_buster":       {"up": 40.0, "down": 10.0},
	"smoke_discharger":    {"up": 60.0, "down": 5.0},
	"sentry_deployer":     {"up": 30.0, "down": 5.0},
	"mine_layer":          {"up": 15.0, "down": 10.0},
	"resource_harvester":  {"up": 30.0, "down": 30.0},
	"repair_array":        {"up": 60.0, "down": 30.0},
	# --- Indirect fire: LOW engagement elevation (10-25) ----------------
	# The counter-intuitive tier, and the one Chris called out. These weapons
	# point their tubes STEEPLY - that is what makes them indirect - but every
	# one of them is lobbing at something on the ground. None can service a
	# target above it, which is exactly the capability being denied here. The
	# steep barrel earns its keep through fire_range (the `elevation` tweak),
	# not through overhead engagement.
	"artillery":           {"up": 20.0, "down": 3.0},
	"rocket_artillery":    {"up": 25.0, "down": 3.0},
	"cruise_missile":      {"up": 25.0, "down": 3.0},
	"loitering_munition":  {"up": 30.0, "down": 3.0},
	"mortar_array":        {"up": 20.0, "down": 3.0},
	"napalm_mortar":       {"up": 18.0, "down": 3.0},
	"spigot_mortar":       {"up": 15.0, "down": 3.0},
	"mk19_grenade_launcher": {"up": 35.0, "down": 8.0},
	"drone_carrier":       {"up": 40.0, "down": 5.0},
}

# How much the `elevation` tweak can raise a weapon's ceiling. That tweak
# already buys fire_range through the ballistic arc (weapon_range.gd); letting
# it also raise the engagement ceiling is what makes the slider's NAME honest,
# and it gives a player a real way to buy a bit of high-angle capability on a
# gun that starts without it. Capped at 90 regardless - straight up is straight
# up, and no tweak turns a howitzer into an AA mount.
const ELEVATION_TWEAK_GAIN_MAX: float = 1.6
const ELEVATION_CEILING: float = 90.0

static func _elevation_entry(type_id: String) -> Dictionary:
	return ELEVATION_LIMITS.get(type_id, ELEVATION_DEFAULT)

# Max engagement elevation above the weapon's own horizon, in RADIANS.
static func get_elevation_up(type_id: String, tweaks: Dictionary = {}) -> float:
	var deg: float = _elevation_entry(type_id).get("up", ELEVATION_DEFAULT.up)
	var t = tweaks.get("elevation", null)
	if (typeof(t) == TYPE_FLOAT or typeof(t) == TYPE_INT) and float(t) > 0.0:
		deg *= minf(float(t), ELEVATION_TWEAK_GAIN_MAX)
	return deg_to_rad(minf(deg, ELEVATION_CEILING))

# Max depression below the weapon's own horizon, in RADIANS. Kept separate
# because it is a genuinely different mechanical constraint (the breech rising
# into the mount, rather than the muzzle fouling it) and because the values are
# far smaller - the old placeholder let every weapon in the game shoot almost
# straight DOWN as well, which is just as wrong as the overhead case.
static func get_elevation_down(type_id: String, _tweaks: Dictionary = {}) -> float:
	return deg_to_rad(_elevation_entry(type_id).get("down", ELEVATION_DEFAULT.down))

# Whether this weapon can meaningfully engage a target above it - the
# capability the PD / MG / SAM group is supposed to have and the artillery
# group is not. Threshold is 60 degrees: enough to service something high
# overhead rather than merely up a hill.
const OVERHEAD_ENGAGEMENT_MIN_DEG: float = 60.0

static func can_engage_overhead(type_id: String, tweaks: Dictionary = {}) -> bool:
	return get_elevation_up(type_id, tweaks) >= deg_to_rad(OVERHEAD_ENGAGEMENT_MIN_DEG)

static func get_module_data(type_id: String) -> Dictionary:
	var cat = get_catalog()
	if cat.has(type_id):
		return cat[type_id]
	return cat["basic_cannon"] # Fallback
