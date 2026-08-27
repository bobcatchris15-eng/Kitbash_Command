extends RefCounted
## Drivetrain: weight, load capacity, thrust and top speed for one design.
##
## WHY THIS FILE EXISTS. This math used to live twice - once in
## unit.gd's _recalculate_move_speed() (the real combat numbers) and
## once, abbreviated, in stat_calculator.gd's update_stats() (the Design Lab
## sidebar). The Design Lab copy carried its own comment admitting it was
## "deliberately a simplified re-derivation, not a shared function ... this
## only needs to be 'close enough to warn'". It had since drifted well past
## "close enough": the sidebar knew nothing about hover_engine's pad count or
## Electron Megavoltage, nothing about fixed_wing_engine's engine count or
## turbine compression, and nothing at all about the eleven expansion
## locomotors - so a player tuning those tweaks watched a capacity number
## that could not move, while the unit they fielded behaved differently.
##
## A design tool whose numbers disagree with the simulation is worse than no
## numbers, so the two callers now share this one function. The same principle
## already applied to HP/weight/cost via ModuleCatalog.compute_hull_*() (see
## FABLE_REVIEW.md 2.6, which fixed exactly this class of bug for those three
## stats); speed and load were the stats that pass missed.
##
## TUNED FOR THE UNIT (Chris, 2026-08-16). The locomotor is treated as a
## self-contained system whose carrying capacity is for what it carries
## beyond the chassis baseline, not for the chassis itself. `weight` (the
## design's total mass) is still reported, but `load_ratio` and
## `power_top_speed` are off `carried_weight` (= weapons, generators,
## sensors, harvesters, propulsion parts - everything that is NOT the hull
## or its locomotion). The chassis/loco split is also exposed as
## `carried_weight` and `loco_weight` so the Design Lab can show "this
## drive is N kg, the chassis M kg" without re-summing module weights.
##
## This is a static-only helper in the damage_resolver.gd mould - no state, no
## instance, nothing to add to a tree.

const ModuleCatalog = preload("res://scripts/module_catalog.gd")
const LiveryScript = preload("res://scripts/livery.gd")
const ArmorPaint = preload("res://scripts/armor_paint.gd")

## Thrust every unit gets before any locomotion module contributes. Keeps a
## barely-powered design from dividing by ~nothing and reading as immobile.
const BASE_THRUST := 100.0

## Converts a thrust/weight ratio into speed units. Retuned 5.0 -> 10.0 when
## hull mass entered the denominator (FABLE_REVIEW.md 1.2).
##
## Retuned again, 10.0 -> 11.0 (2026-08-08, "make speed a real, affectable
## factor"): a ~10% lift for every power-limited design, which pushes more of
## the roster up against its own chassis ceiling - the number the retuned
## base_top_speed band (module_catalog.gd) and the new propulsion parts
## actually change. At 10.0 too many designs sat comfortably under their
## ceiling with slack to spare, which made both the wider band and a part
## that raises the ceiling read as invisible.
const TW_GAIN := 11.0

## No design is slower than this, however overweight or underpowered - a unit
## that cannot visibly move reads as a bug rather than as a balance outcome.
const SPEED_FLOOR := 1.5

## Overload response. Past capacity, speed falls as (capacity/weight)^EXPONENT.
##
## Chris's ask was that going over capacity "drops the top speed the finished
## unit can achieve RAPIDLY", and the previous curve did not: it was linear at
## 0.6 per 100% over, so 10% overweight cost 6% of top speed - far too soft to
## register as a decision, let alone a warning worth showing. At 1.8, 10% over
## costs 15%, 25% over costs 33%, 50% over costs 52%, and 2x over costs 71%.
##
## Chosen as an exponential decay rather than a steeper straight line so it
## keeps resolving at the extremes: a straight line steep enough to bite at
## 10% over hits the floor by ~1.5x capacity, which would make every design
## past that point equally bad and remove any reason to care how far over you
## are. This form is also monotonic and smooth, which matters because the
## Design Lab draws it as a bar the player drags tweaks against.
##
## Tried at 2.5 first, which was too steep to be legible: because weight is
## ALREADY in the thrust/weight term, an overweight design is being slowed
## twice, and at 2.5 the product drove almost every overloaded design in the
## roster onto SPEED_FLOOR exactly (measured with scratch/probe_drivetrain.gd -
## 13 of 17 locomotors read an identical 1.50 at +500kg). Bottoming out that
## early is the same "every answer is the same answer" failure as the old
## universal speed ceiling, and it would make the Design Lab's own readout
## useless precisely where a player most needs to see which way is out.
const OVERLOAD_EXPONENT := 1.8

## Floor on the overload multiplier, for the same "never fully frozen" reason
## as SPEED_FLOOR. Reached at ~2.3x capacity.
const OVERLOAD_FLOOR := 0.2

## Underload response - the mirror of the three constants above, and Chris's
## ask that "being significantly under weight limit should give you a speed
## bonus as well".
##
## The point is to make running gear a real choice in BOTH directions. Before
## this, over-speccing the drivetrain bought you exactly one thing: headroom
## you were not using. Capacity was a wall you either hit or did not, so every
## design that came in under it played identically whether it had 1% of slack
## or 60%, and the only reason to fit more running gear than you needed was
## fear of a future refit. Now light-and-overpowered is a build.
##
## Why a DEADZONE rather than a bonus that starts the moment you are under:
## a design sitting at 0.95 load is not "light", it is merely legal, and
## paying it a bonus would mean literally every non-overloaded design in the
## game runs faster than its rated top speed - which makes the rating a lie
## and the bonus invisible, since a universal multiplier is the same as none.
## The bonus has to be earned by deliberately carrying less than you could,
## so nothing happens until you are a quarter under.
##
## Why the ceiling is modest: this multiplies a speed that has ALREADY been
## helped by being light, because weight is in the thrust/weight term feeding
## power_top_speed. A stripped design is being paid twice, exactly as an
## overweight one is punished twice (see OVERLOAD_EXPONENT). 1.25 is the
## largest ceiling that did not let a bare hull on heavy running gear
## out-run purpose-built scouts.
##
## The exponent is BELOW 1.0 where the overload exponent is above it, and
## that asymmetry is deliberate: the penalty should bite hard and early
## because it is a warning, while the reward should pay out early and then
## flatten because it is an incentive. Concave means the first slice of
## slack is worth the most and stripping a design to nothing has diminishing
## returns, so there is a point past which shedding more weight stops being
## the obvious answer.
##
##   load 0.75 -> 1.000   (nothing yet - this is the deadzone edge)
##   load 0.60 -> 1.079
##   load 0.50 -> 1.117
##   load 0.25 -> 1.189
##   load 0.00 -> 1.250
const UNDERLOAD_THRESHOLD := 0.75
const UNDERLOAD_CEILING := 1.25
const UNDERLOAD_EXPONENT := 0.7

## Ceiling on the combined top_speed_mult from every propulsion part fitted
## (turbocharger, hub_motor_array, ...). Without a cap, stacking boost parts
## is strictly the answer to every speed question a
## player has - this is the same "an unbounded multiplier makes the whole
## rest of the system optional" failure OVERLOAD_FLOOR/UNDERLOAD_CEILING
## already guard against, applied to the newest multiplier in the chain.
const MAX_CHASSIS_SPEED_MULT := 1.6

## Per-locomotor tweak response, replacing the if/elif chain that used to sit
## inside _recalculate_move_speed().
##
## Each factor is `(value / ref)` raised to the `thrust` and `capacity`
## exponents: 1.0 is proportional, 0.0 is no effect, and a NEGATIVE exponent
## is a real tradeoff (the tweak buys capacity by spending thrust, or the
## reverse). `keys` is tried in order so both the current tweak name and any
## legacy alias resolve - stat_calculator.gd writes "count" for legs and
## rotors but "num_axles"/"pad_count"/"engine_count" elsewhere, and
## locomotion_layout.gd declares its own count_key names on top of that.
##
## ---------------------------------------------------------------------------
## COUNT TWEAKS ARE DELIBERATELY ABSENT, AND THAT IS THE POINT OF THIS TABLE.
##
## analyze() sums capacity and thrust across every locomotion CHILD NODE, and
## LocomotionLayout.stations() spawns exactly one node per count: 8 axles is 8
## wheel nodes, 6 engines is 6 engine nodes (verified per type with
## scratch/probe_stations.gd). So raising a count already raises capacity and
## thrust proportionally, for free, via the sum.
##
## The old if/elif chain multiplied by the count AGAIN on top of that, which
## made both quantities grow with the SQUARE of the count while weight grew
## only linearly. Going from 4 axles to 8 quadrupled capacity (1400 -> 5600)
## for double the wheel mass, so "drag the count slider up" strictly dominated
## every other answer to being overweight - which is the opposite of the
## tradeoff Chris asked for, and it silently undercut the whole capacity
## mechanic. Any count tweak listed here therefore carries only the RESIDUAL
## effect beyond that linear growth:
##
##   exponent  0.0  proportional growth is already correct - say nothing
##            -0.5  grows, but sub-linearly (diminishing returns per unit)
##            -1.0  cancels the sum entirely (the quantity is per-DESIGN, not
##                  per-node - see buoyant_envelope's capacity)
##
## Geometry tweaks (tread_width, emv_level, turbine_compression, ...) do not
## change the node count, so they carry their full exponent.
## ---------------------------------------------------------------------------
##
## Why exponents and not the old formulas: legs and tracked_treads previously
## traded thrust ADDITIVELY - `1.0 + (4.0 - leg_count) / 8.0` and
## `1.0 + (1.0 - width) * 0.5`. Both go to zero and then NEGATIVE inside the
## range the sliders already allow: 12 legs produced exactly 0.0 thrust, and a
## 2.5-wide tread produced 0.25 while simultaneously multiplying capacity by
## 2.5 - a max-width tread was strictly self-defeating. A multiplicative form
## cannot cross zero, preserves the direction of both tradeoffs, and is far
## less punishing at the ends of sliders players actually drag.
##
## Types absent from this table respond to size (via node scale) and to count
## (via the per-node sum), but have no geometry tweak wired to thrust or load.
const TWEAK_RESPONSE := {
	# num_axles is a count - the node sum already handles it. wheels_per_axle
	# is NOT: duallies are extra wheels modelled inside the same axle node
	# (4 axles at 2-per-axle is still 4 nodes), so it needs its own factor to
	# count at all. That is Chris's "total wheel count, not just axle count".
	"wheels": [
		{"keys": ["wheels_per_axle"], "ref": 1.0, "thrust": 1.0, "capacity": 1.0},
	],
	# Wider track = more contact area = real flotation and load spread, paid
	# for in friction. Always 2 nodes, so this is pure geometry. See also
	# unit.gd's terrain multiplier, where width earns a second,
	# separate bonus on soft ground.
	"tracked_treads": [
		{"keys": ["tread_width", "width", "size"], "ref": 1.0, "thrust": -0.35, "capacity": 1.0},
	],
	# Capacity already grows linearly with leg count (more load-bearing
	# contact points), so capacity says nothing here. Thrust is where the
	# tradeoff Chris asked for lives: each added leg is more mechanical mass
	# to coordinate, so total thrust still rises but sub-linearly - 8 legs
	# out-pull 4, and by less than double. Fewer legs trades stability for
	# agility, which is now a genuine choice rather than a strict downgrade.
	"legs": [
		{"keys": ["leg_count", "count"], "ref": 4.0, "thrust": -0.5, "capacity": 0.0},
	],
	# Electron Megavoltage buys capacity and nothing else - Chris's ask,
	# "increases the weight capacity ... while requiring more resources to
	# build" (the cost/weight half of that lives in module_data.gd). Not a
	# count tweak: it is pad size, so it needs its own factor.
	"hover_engine": [
		{"keys": ["emv_level", "size"], "ref": 1.0, "thrust": 0.0, "capacity": 1.0},
	],
	"ornithopter_wing": [
		{"keys": ["wingspan", "size"], "ref": 1.0, "thrust": 1.0, "capacity": 1.0},
	],
	# An airship's lift is buoyancy, not thrust: extra cruise engines make it
	# faster and carry nothing extra. The -1.0 exactly cancels the per-node
	# sum, so capacity is set by the envelope alone however many engine pods
	# hang off it. This is the clearest case in the roster for that, and the
	# reason the -1.0 idiom is documented in the header above.
	"buoyant_envelope": [
		{"keys": ["prop_count", "count"], "ref": 2.0, "thrust": 0.0, "capacity": -1.0},
		{"keys": ["blade_pitch"], "ref": 1.0, "thrust": 0.6, "capacity": 0.0},
	],
	# --- Expansion types (LOCOMOTION_EXPANSION_PLAN.md 4) ---
	# These have no tweak sliders in the Design Lab yet, so today they always
	# resolve to their declared defaults and contribute a flat 1.0. Wired
	# anyway: the alternative is that whoever adds the sliders also has to
	# discover that capacity exists and find this table, which is exactly how
	# the drift this file was written to end got started.
	#
	# Every factor below is geometry, not a count - half_track/rocker_bogie
	# are always 2 nodes and air_cushion_skirt is always 1 (its fan count is
	# modelled inside the single skirt), so none of them double-count.
	"half_track": [
		{"keys": ["bogie_count"], "ref": 3.0, "thrust": 0.3, "capacity": 0.7},
		{"keys": ["tread_width"], "ref": 1.0, "thrust": -0.35, "capacity": 1.0},
	],
	"rocker_bogie": [
		{"keys": ["bogie_pairs"], "ref": 3.0, "thrust": 0.2, "capacity": 1.0},
		{"keys": ["wheel_size"], "ref": 1.0, "thrust": 0.5, "capacity": 0.3},
	],
	"air_cushion_skirt": [
		{"keys": ["lift_fan_count"], "ref": 3.0, "thrust": 1.0, "capacity": 0.5},
		{"keys": ["plenum_pressure"], "ref": 1.0, "thrust": 0.0, "capacity": 1.0},
		{"keys": ["skirt_diameter"], "ref": 1.0, "thrust": -0.2, "capacity": 0.8},
	],
	# plate_count is a count; field_strength is not.
	"anti_grav_plate": [
		{"keys": ["field_strength"], "ref": 1.0, "thrust": 0.0, "capacity": 1.0},
	],
	# Augers: a fatter drum floats and carries, a deeper helix bites harder.
	"screw_drive": [
		{"keys": ["drum_diameter", "drum_width", "size"], "ref": 1.0, "thrust": 0.5, "capacity": 1.0},
		{"keys": ["helix_depth"], "ref": 1.0, "thrust": 0.6, "capacity": 0.0},
	],
}

## Resolves one locomotor's tweak settings into multiplicative (thrust,
## capacity) factors. Returns 1.0/1.0 for any type absent from
## TWEAK_RESPONSE, so an unlisted locomotor behaves exactly as it would have
## before this table existed.
static func tweak_factors(locomotion_type: String, settings: Dictionary) -> Dictionary:
	var thrust := 1.0
	var capacity := 1.0
	for factor in TWEAK_RESPONSE.get(locomotion_type, []):
		var ref: float = float(factor["ref"])
		if ref <= 0.0:
			continue
		var raw = null
		for key in factor["keys"]:
			if settings.has(key):
				raw = settings[key]
				break
		if raw == null:
			continue
		# Booleans share the tweak dict with numbers (drive_sprocket, duct,
		# reverser, stabilizer_ring, paddle_vanes). They are geometry flags,
		# never load or thrust inputs, and float(true) == 1.0 would quietly
		# fold one into a ratio against its `ref`.
		if typeof(raw) == TYPE_BOOL:
			continue
		var value := float(raw)
		if value <= 0.0:
			continue
		var ratio := value / ref
		thrust *= pow(ratio, float(factor["thrust"]))
		capacity *= pow(ratio, float(factor["capacity"]))
	return {"thrust": thrust, "capacity": capacity}

## Full drivetrain analysis for a built hull.
##
## `hull_node` is the live Hull node in the Design Lab or the reconstructed
## hull under a battle_unit - both carry the same metadata and the same
## module children, which is what makes one function serve both.
##
## `locomotion_type`/`locomotion_settings` are passed in rather than read from
## the hull because unit.gd already holds them as fields (parsed from
## the blueprint) and they are the authority there; pass "" / {} to have them
## read from hull metadata instead, which is what the Design Lab does.
##
## `is_airborne` gates the Aerodrome Cartel's air-only speed passive. Left null
## it is derived from the trait system, which is what the Design Lab wants;
## unit.gd passes its own already-resolved is_flying instead, so the
## faction bonus cannot start disagreeing with the movement code that decides
## whether a unit actually flies.
##
## Returns a Dictionary - see the keys assembled at the bottom. Never returns
## null and never divides by zero; a hull with no locomotion at all comes back
## with has_locomotion false and every speed at 0.0.
static func analyze(hull_node: Node3D, locomotion_type: String = "", locomotion_settings: Dictionary = {}, is_airborne = null) -> Dictionary:
	var loco_type := locomotion_type
	var loco_settings := locomotion_settings
	if is_instance_valid(hull_node):
		if loco_type == "" and hull_node.has_meta("locomotion_type"):
			loco_type = str(hull_node.get_meta("locomotion_type"))
		if loco_settings.is_empty() and hull_node.has_meta("locomotion_settings"):
			loco_settings = hull_node.get_meta("locomotion_settings")

	var hull_type := "brenntal_medium_a"
	var thickness := 1.0
	var material := "hardened_steel"
	var hull_scale := Vector3.ONE
	# NO_FACTION, not "industrialists". A hull with no faction meta is a Design
	# Lab hull, and the Lab now shows base stats: defaulting to a real faction
	# here meant an unassigned design was silently quoted with the
	# Industrialists' -20% armour weight passive, so the weight and load figures
	# the player tuned against were wrong for nine of the ten factions they
	# could pick at match setup. Battle spawns always set the meta explicitly
	# (blueprint_manager.reconstruct_vehicle), so nothing there changes.
	var faction := LiveryScript.NO_LIVERY
	if is_instance_valid(hull_node):
		hull_type = str(hull_node.get_meta("type_id", "brenntal_medium_a"))
		if hull_node.has_meta("armor_thickness"):
			thickness = float(hull_node.get_meta("armor_thickness"))
		if hull_node.has_meta("armor_material"):
			material = str(hull_node.get_meta("armor_material"))
		if hull_node.has_meta("hull_scale"):
			hull_scale = hull_node.get_meta("hull_scale")
		if hull_node.has_meta("faction"):
			faction = str(hull_node.get_meta("faction"))

	# The hull's own mass, armor included, is REAL weight (FABLE_REVIEW.md
	# 1.2) - it was display-only before that pass, which meant armoring up
	# cost nothing in combat.
	var armor_wt_mult: float = 1.0
	var weight: float = ModuleCatalog.compute_hull_weight(hull_type, thickness, material, hull_scale, armor_wt_mult)
	# Painted armor is real bolt-on mass too (ArmorPaint: painted area x
	# thickness x per-material density). It counts as CARRIED weight - the
	# locomotor hauls every plate - which is what makes a max-thickness
	# turtle trade speed for protection instead of getting free threshold.
	# It was weightless until 2026-08-25 ("cosmetic likenesses"), which made
	# 3.0x everywhere the free optimum.
	var armor_weight := 0.0
	if is_instance_valid(hull_node):
		armor_weight = float(ArmorPaint.analyze(hull_node).get("weight", 0.0))
	weight += armor_weight
	# The locomotor is treated as a self-contained system "tuned for the
	# unit" (Chris, 2026-08-16): its carrying capacity is for what it
	# carries beyond the chassis baseline, not for the chassis itself.
	# Tracked separately here so `load_ratio` and `power_top_speed` can use
	# `carried_weight` (= everything except hull + locomotion) while `weight`
	# still reports the full design mass to the rest of the game.
	#   `loco_weight`     - one or more locomotion children, summed
	#   `carried_weight`  - painted armor, weapons/generators/sensors/harvesters/propulsion parts
	var loco_weight: float = 0.0
	var carried_weight: float = armor_weight

	var thrust := BASE_THRUST
	var capacity := 0.0
	var has_locomotion := false
	# The SLOWEST locomotor present sets the ceiling, not the fastest or an
	# average: a design carrying two kinds of running gear is limited by
	# whichever cannot keep up, the same way a real vehicle is. Tracked
	# separately from the loop so the Design Lab can name the figure.
	var slowest_top_speed := 0.0

	var factors := tweak_factors(loco_type, loco_settings)

	# Propulsion parts (turbocharger, hub_motor_array, ...)
	# raise the chassis ceiling and/or trade capacity for it, on top of the
	# thrust_bonus/weight_capacity_bonus hooks below. Multiplicative and
	# accumulated across every part fitted, then clamped once at the end -
	# see MAX_CHASSIS_SPEED_MULT for why a stack of gearboxes doesn't just
	# keep compounding.
	var chassis_speed_mult := 1.0
	var propulsion_capacity_mult := 1.0
	var booster_profiles: Array[Dictionary] = []
	var boost_summary := {}

	if is_instance_valid(hull_node):
		for child in hull_node.get_children():
			if not child.has_meta("module_data"):
				continue
			if child.is_queued_for_deletion():
				continue
			var data = child.get_meta("module_data")
			if data == null:
				continue
			weight += data.get_weight()
			# Node scale is the "how big is this instance" term; the tweak
			# factors above are the "how many / how wide" term. x and z only:
			# these are footprint parts, and y is ride height.
			var footprint: float = child.scale.x * child.scale.z
			if data.category == "locomotion":
				has_locomotion = true
				# Hull + locomotion is the "free baseline" the locomotor is
				# tuned for; carried_weight only accumulates non-locomotion
				# children. `loco_weight` is recorded so callers (e.g. the
				# Design Lab) can show "this drive is N kg, the chassis M
				# kg, you have K kg of payload" if they want to.
				loco_weight += data.get_weight()
				thrust += ModuleCatalog.get_thrust_coefficient(data.type_id) * footprint * factors["thrust"]
				# tweaks passed through so a legged chassis is rated for the leg
				# set actually fitted - an Excavator walker carries far more
				# than a Raptor one, and walks slower for it.
				capacity += ModuleCatalog.get_base_weight_capacity(data.type_id, data.tweaks) * footprint * factors["capacity"]
				var chassis_top: float = ModuleCatalog.get_base_top_speed(data.type_id, data.tweaks)
				if slowest_top_speed <= 0.0 or chassis_top < slowest_top_speed:
					slowest_top_speed = chassis_top
			else:
				# Support modules, weapons, generators, sensors, harvesters,
				# hull extensions - everything the locomotor actually
				# CARRIES. This is what the capacity is rated against.
				carried_weight += data.get_weight()
			# Mobility ADD-ONS (wings raise load budget, thrusters add real thrust)
			var catalog_entry := ModuleCatalog.get_module_data(data.type_id)
			var wc_bonus: float = catalog_entry.get("weight_capacity_bonus", 0.0)
			var thrust_bonus: float = catalog_entry.get("thrust_bonus", 0.0)
			if wc_bonus > 0.0:
				capacity += wc_bonus * footprint
			if thrust_bonus > 0.0:
				thrust += thrust_bonus * footprint

			if data.type_id == "booster_rack":
				var b_prof: Dictionary = data.get_boost_profile() if data.has_method("get_boost_profile") else catalog_entry.get("boost", {})
				if not b_prof.is_empty():
					booster_profiles.append(b_prof)

		# Aggregate all fitted rocket booster modules into a combined ability profile
		if not booster_profiles.is_empty():
			var total_racks: int = booster_profiles.size()
			var max_speed_mult: float = 1.0
			var max_duration: float = 0.0
			var sum_cooldown: float = 0.0
			var total_tubes: float = 0.0
			for b in booster_profiles:
				max_speed_mult = maxf(max_speed_mult, float(b.get("speed_mult", 1.8)))
				max_duration = maxf(max_duration, float(b.get("duration", 3.0)))
				sum_cooldown += float(b.get("cooldown", 24.0))
				total_tubes += float(b.get("tubes", 3.0))
			var avg_cd = sum_cooldown / max(1, total_racks)
			# Adding more booster modules shortens recharge!
			var combined_cd = avg_cd / (1.0 + 0.4 * (total_racks - 1))
			boost_summary = {
				"speed_mult": max_speed_mult,
				"duration": max_duration,
				"cooldown": combined_cd,
				"charges": 0,
				"energy_per_sec": 0.0,
				"booster_count": total_racks,
				"tubes_total": total_tubes
			}

	# A design with no locomotion does not move, and has no capacity to be
	# over - reporting a load ratio here would light the overweight warning
	# on every hull the moment it is spawned and before any running gear is
	# chosen.
	if not has_locomotion:
		return {
			"has_locomotion": false, "weight": weight, "capacity": 0.0,
			# Hull + any modules, then the chassis/loco split. Both are 0
			# when there is no locomotion; carried_weight would equal the
			# sum of every other child, which a player sees as the design
			# mass minus an unplaced chassis - same number they'd get from
			# `weight` minus nothing, but spelled out so consumers can read
			# into it unconditionally.
			"carried_weight": carried_weight, "loco_weight": loco_weight,
			"thrust": thrust, "load_ratio": 0.0, "is_overloaded": false,
			"overload_multiplier": 1.0, "chassis_top_speed": 0.0,
			"underload_multiplier": 1.0, "is_underloaded": false,
			"speed_gained_from_underload": 0.0,
			"power_top_speed": 0.0, "top_speed": 0.0, "move_speed": 0.0,
			"speed_lost_to_overload": 0.0, "capacity_limited": false,
			"chassis_speed_mult": 1.0, "boost": {},
		}

	# What the engines alone would deliver against the carried load.
	#
	# Driven off `carried_weight`, not `weight`, because the locomotor is
	# "tuned for the unit" (see header on `carried_weight` above). A heavy
	# hull + light chassis + light weapons is exactly the load the
	# locomotor is calibrated for, and the thrust/weight term says so -
	# a unit on the same chassis always hits the same power_top_speed for
	# the same weapons load, regardless of hull size. The chassis_top_speed
	# cap is still per-type, so the locomotor's hardware ceiling is the
	# binding constraint on a typical design.
	#
	# `carried_weight` of 0 (a bare hull) is a real input: the engines have
	# no load to push, so power_top_speed runs to infinity, and `minf` with
	# chassis_top_speed below picks the chassis cap as the design's
	# top_speed. SPEED_FLOOR is a separate underload for a unit that
	# overloads past the floor, not a guard here.
	var power_top_speed := 0.0
	if carried_weight > 0.0:
		power_top_speed = maxf(SPEED_FLOOR, (thrust / carried_weight) * TW_GAIN)
	else:
		power_top_speed = INF

	# Propulsion parts' capacity trade (a tall-geared booster's -15%, for
	# instance) lands on the raw chassis capacity, same place the leg-set and
	# per-locomotor tweak factors already land - so it participates in
	# load_ratio/overload/underload exactly like any other capacity change.
	capacity *= propulsion_capacity_mult

	# ...capped by what the chassis can physically do with it. This is the
	# per-locomotor "base top speed" (Chris's ask): a hull on legs does not
	# become a racing car because you bolted enough thrust to it, and the
	# universal 18.0 ceiling this replaces gave every locomotor in the roster
	# the same answer to that question.
	#
	# chassis_speed_mult is what a propulsion part (Overdrive Gearbox) buys:
	# the one way to raise this ceiling without changing locomotion type.
	# Clamped so stacking parts cannot make the cap meaningless - see
	# MAX_CHASSIS_SPEED_MULT.
	chassis_speed_mult = minf(chassis_speed_mult, MAX_CHASSIS_SPEED_MULT)
	var chassis_top_speed: float = (slowest_top_speed if slowest_top_speed > 0.0 else ModuleCatalog.BASE_TOP_SPEED_DEFAULT) * chassis_speed_mult
	var top_speed: float = minf(power_top_speed, chassis_top_speed)

	var load_ratio := 0.0
	if capacity > 0.0:
		# `carried_weight`, not `weight` - the locomotor's capacity is for
		# what it carries beyond the chassis baseline. See `carried_weight`'s
		# header for the design rationale.
		load_ratio = carried_weight / capacity
	var overload_multiplier := 1.0
	if load_ratio > 1.0:
		overload_multiplier = maxf(OVERLOAD_FLOOR, pow(1.0 / load_ratio, OVERLOAD_EXPONENT))

	# The mirror image. Gated on capacity > 0 as well as on the ratio, because
	# load_ratio is left at 0.0 when there is no capacity to divide by - a
	# design whose running gear carries nothing would otherwise read as
	# maximally light and collect the full bonus for having no drivetrain.
	var underload_multiplier := 1.0
	if capacity > 0.0 and load_ratio < UNDERLOAD_THRESHOLD:
		var slack: float = clampf((UNDERLOAD_THRESHOLD - load_ratio) / UNDERLOAD_THRESHOLD, 0.0, 1.0)
		underload_multiplier = 1.0 + (UNDERLOAD_CEILING - 1.0) * pow(slack, UNDERLOAD_EXPONENT)

	# Only one of the two can ever be off 1.0 - they are opposite sides of the
	# same threshold - so multiplying both is just the cheapest way to write
	# "whichever applies" without a branch that could disagree with the
	# reported figures below.
	#
	# Note this is applied AFTER the chassis cap rather than inside it, which
	# means a very light design genuinely exceeds its chassis rating by up to
	# 25%. That is intended: the cap is what a chassis does under its rated
	# load, and on most of the roster the chassis is the binding constraint,
	# so folding the bonus in underneath the cap would silently delete it for
	# exactly the designs it is meant to reward.
	var move_speed: float = maxf(SPEED_FLOOR, top_speed * overload_multiplier * underload_multiplier)

	# Faction speed passives (a flat speed_mult, plus an airborne-only
	# air_speed_mult) used to be applied here. They are gone with the factions
	# themselves (see livery.gd), so move_speed is now the drivetrain's answer
	# alone - which is the point: speed comes from what the player built.

	return {
		"has_locomotion": true,
		"weight": weight,
		# Chassis/loco split. `weight` is still the design's total mass for
		# the rest of the game (fleet panel, harvester cargo math, etc.) -
		# these two are published alongside it so the Lab can show "this
		# drive is N kg, the chassis M kg" without re-summing module
		# weights. The drivetrain's own speed and load math above is
		# already off `carried_weight`.
		"carried_weight": carried_weight,
		"loco_weight": loco_weight,
		"capacity": capacity,
		"thrust": thrust,
		"load_ratio": load_ratio,
		"is_overloaded": load_ratio > 1.0,
		"overload_multiplier": overload_multiplier,
		"underload_multiplier": underload_multiplier,
		"is_underloaded": underload_multiplier > 1.0,
		# Absolute speed gained from running light, in the same units as
		# speed_lost_to_overload, so the Lab can state the reward and the
		# penalty the same way.
		"speed_gained_from_underload": maxf(0.0, top_speed * underload_multiplier - top_speed),
		# What the chassis is rated for, before this design's mass.
		"chassis_top_speed": chassis_top_speed,
		# What thrust/weight alone would allow, before the chassis cap.
		"power_top_speed": power_top_speed,
		# The two above, combined - the design's clean top speed.
		"top_speed": top_speed,
		# ...and after overload and faction passives. This is combat speed.
		"move_speed": move_speed,
		"speed_lost_to_overload": maxf(0.0, top_speed - top_speed * overload_multiplier),
		# True when the chassis, not the powerplant, is what is holding this
		# design back - the Design Lab says so, because the fix is different
		# (change locomotion type, not add thrust or shed weight).
		"capacity_limited": chassis_top_speed < power_top_speed,
		# What propulsion parts did to the chassis ceiling, already folded
		# into chassis_top_speed above - reported separately so the Design
		# Lab can say an Overdrive Gearbox is why the number moved. 1.0 when
		# no propulsion part is fitted.
		"chassis_speed_mult": chassis_speed_mult,
		# The strongest burst-boost part fitted (nitrous_injector,
		# booster_rack, ...), or {} when none. NOT applied to move_speed/
		# top_speed above - see the header comment on boost_summary.
		"boost": boost_summary,
	}
