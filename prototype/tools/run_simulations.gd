extends SceneTree
# Automated Combat Simulation & Balance HARNESS + OPTIMIZER.
#
# Run with:
#   Godot_v4.3-stable_win64_console.exe --headless --script tools/run_simulations.gd
#   ... --headless --script tools/run_simulations.gd -- --apply
#
# ---------------------------------------------------------------------------
# WHAT THIS REPLACED, AND WHY
# ---------------------------------------------------------------------------
# The first version of this file simulated five INVENTED weapons
# ("machine_gun_small", "heavy_cannon", ...) that exist nowhere in the
# catalog, against an armor model of its own invention
# (`max(0, damage - threshold)`), and then "analyzed" the results with three
# hardcoded print statements that would have printed the same text no matter
# what the numbers did. Nothing it reported was about this game.
#
# This version:
#   * reads the REAL catalog (ModuleCatalog.get_catalog()),
#   * resolves damage through the REAL shared math (DamageResolver.
#     compute_hull_damage / get_material_threshold - the same functions
#     battle_unit.gd and building.gd call on every hit, so chip-through,
#     the brute-force blend and the per-material reduction multipliers all
#     apply exactly as they do in a match),
#   * builds its target archetypes out of REAL hulls at REAL computed HP
#     (ModuleCatalog.compute_hull_max_hp),
#   * and then actually OPTIMIZES, rather than asserting a conclusion.
#
# ---------------------------------------------------------------------------
# THE OBJECTIVE (Chris's call, 2026-07-30)
# ---------------------------------------------------------------------------
# Two objectives, deliberately NOT "flatten every value/cost ratio" (that's
# what balance_report.gd already does, and it flattens intended asymmetry):
#
#   1. NO DOMINATED WEAPONS. Weapon B is dominated if some weapon A is at
#      good as B against EVERY target archetype on BOTH damage-per-resource
#      and damage-per-kilogram, and strictly better somewhere. Weight is the
#      second axis because mount slots aren't scarce in this game - you can
#      always add another gun if you'll pay the resources and accept a
#      slower vehicle, and weight IS that mobility price. A dominated
#      weapon is a trap
#      pick - there is no board state where building it is correct. This is
#      the direct mechanical statement of DESIGN_VISION.md's Forged
#      Battalion warning.
#   2. COUNTER-PLAY SPREAD. Each weapon's effective DPS should vary
#      meaningfully across the four armor materials, so the defender's
#      material choice is a live decision and the attacker's weapon choice
#      is a real read. Measured as coefficient of variation across
#      materials; weapons below MIN_SPREAD are penalized.
#
# Regularized toward the hand-authored values (DEVIATION_WEIGHT) so the
# optimizer nudges rather than rewrites - the shipped numbers encode design
# intent this loss function cannot see.
#
# ---------------------------------------------------------------------------
# WHAT THIS MODEL DOES *NOT* CAPTURE - read before trusting a number
# ---------------------------------------------------------------------------
# Flagged loudly rather than buried, in the spirit of ENERGY_AND_BALANCE_
# SPEC.md #7's own "known-shaky areas":
#   * No positioning, no range, no accuracy, no travel time. A 50m artillery
#     piece and a 9m flamethrower are compared as if both are always in
#     range. fire_range is swept as a COST dimension only (see RANGE_VALUE),
#     not simulated. This is the single biggest gap.
#   * No armor MODULES, no facets, no slope, no elevation. resolve() needs
#     live Node3Ds; this uses the hull-baseline path only.
#   * Multi-projectile weapons (missile_pod, cluster_dispenser, drone_
#     carrier) split `dps * fire_rate` across submunitions in auto_weapon.gd,
#     which changes their per-shot threshold behaviour substantially. Modeled
#     here as a single pooled hit - their numbers are the least trustworthy.
#   * Point-defense weapons are scored but NOT tuned (see LOCKED_TYPES):
#     their value is missile interception, which has no representation here.
#   * Energy weapons' capacitor drain limits sustained fire and is not
#     modeled; their true DPS is lower than shown against a dry capacitor.

const DamageResolverScript = preload("res://scripts/damage_resolver.gd")
const ModuleCatalog = preload("res://scripts/module_catalog.gd")
# The shared damage classifier, mirroring auto_weapon.gd's _ready() chain
# verbatim. Called rather than re-typed - see _damage_class_for() below for
# what the previous hand-copy had drifted into.
const WeaponAlphaScript = preload("res://scripts/weapon_alpha.gd")

# --- Tuning knobs for the optimizer itself ---

# Multiplier grids applied to each weapon's authored dps / fire_rate. Kept
# as multipliers (not absolute values) so the search space is the same shape
# for a 25-dps HMG and a 110-dps railgun.
const DPS_MULTIPLIERS = [0.7, 0.8, 0.9, 1.0, 1.1, 1.2, 1.3, 1.4]
# Deliberately WIDE on the upside. A rapid-fire weapon's per-shot damage
# (dps * fire_rate) sits so far under every real armor threshold that it
# lives permanently in CHIP_THROUGH_FACTOR territory; a grid capped near
# 1.6x cannot lift it out, so the optimizer would report "fire_rate doesn't
# matter" when what it actually found was that it couldn't reach far enough
# to find out. 4x an 0.05s interval is still 5 shots/sec - fast enough to
# read as a gatling, which is what bounds the top of this range.
const RATE_MULTIPLIERS = [0.6, 0.8, 1.0, 1.25, 1.5, 2.0, 2.5, 3.0, 4.0]

const OPTIMIZER_PASSES: int = 6
# Coefficient-of-variation floor across armor materials, below which a
# weapon is "material-blind" and armor choice stops mattering against it.
const MIN_SPREAD: float = 0.22

# Loss weights. DOMINATION_WEIGHT dwarfs the rest on purpose: a dominated
# weapon is a design failure, an imperfect spread is a missed opportunity.
const DOMINATION_WEIGHT: float = 100.0
const SPREAD_WEIGHT: float = 25.0
# TTK is a SANITY GUARD here, not a driver, and its weight is deliberately
# low. Two things were learned getting to this number; both look like bugs
# and neither is:
#
# 1. Nothing in this loss REWARDS raw power - domination, spread and
#    deviation are all relative or conservative terms - so the TTK band is
#    the only term that can ever argue for making a weapon STRONGER. With
#    DEVIATION_WEIGHT at its original 12.0 it lost that argument outright,
#    and the optimizer reported "fire_rate never wants to move" even though
#    raising a chip-through weapon's shot interval lifts it over the armor
#    threshold and improves effective DPS ~6x. fire_rate mattered
#    enormously; the loss just wouldn't pay for it. Hence DEVIATION_WEIGHT
#    12.0 -> 6.0.
#
# 2. But turning TTK_WEIGHT up far enough to chase the long TTKs (tried at
#    30.0) stops being balance and becomes power creep - it buffs 13 of 14
#    weapons at once. The cause is structural and HULL-side, not
#    weapon-side: see the archetype HP list this tool prints every run.
#    Hull HP spans 96 (scout/steel @0.6) to 4000 (heavy/shield @2.0), ~42x,
#    because thickness and material multiply on top of base HP - while
#    weapon DPS spans roughly 4x. No weapon-side tuning can cover a 42x
#    spread; a high TTK_WEIGHT just inflates the whole roster toward the
#    heaviest hull and calls it balance.
#
# 8.0 keeps TTK as a guard against absurd matchups while leaving domination
# and spread as the real objectives. The long TTKs against heavy hulls are
# genuine, but the lever for them is hull HP scaling, not weapon DPS.
const TTK_WEIGHT: float = 8.0
const DEVIATION_WEIGHT: float = 6.0

# TTK sanity band, in seconds, for a single weapon against a single hull.
# Below MIN it's an unreactable alpha strike; above MAX the weapon simply
# cannot meaningfully hurt that hull and the matchup is a stalemate.
const TTK_MIN: float = 2.5
const TTK_MAX: float = 45.0

# Range is real combat value this model can't simulate (no positioning), so
# it's credited rather than ignored: a weapon's damage is scaled by its
# reach relative to REFERENCE_RANGE before either currency is computed.
#
# This is on the VALUE side, not the cost side. An earlier revision of this
# file multiplied COST by the range factor, which is backwards - it made
# every long-range weapon look less efficient the further it shot, and
# flagged artillery as "dominated by basic_cannon" purely because 50m reach
# inflated its price. Outranging an opponent is an advantage, so it belongs
# in the numerator.
#
# Exponent is deliberately sub-linear (0.5): doubling reach is worth real
# value but not double the damage, and a linear credit let a 50m artillery
# piece justify almost any DPS number.
const RANGE_VALUE: float = 0.5
const REFERENCE_RANGE: float = 25.0

# Crystal counts double, matching balance_report.gd's CRYSTAL_WEIGHT, so
# the two tools price a module the same way.
const CRYSTAL_WEIGHT: float = 2.0

# Scored but never tuned. Point-defense weapons earn their cost by shooting
# down missiles - a capability with zero representation in this model, so
# any change the optimizer made to them would be based on a number that
# describes the wrong job. repair_array/resource_harvester/drone_carrier are
# excluded for the same class of reason (heal, economy, and sub-entity
# spawning respectively).
const LOCKED_TYPES = [
	"pd_laser", "ciws", "flak_cannon",
	"repair_array", "resource_harvester", "drone_carrier",
]

# Target archetypes are built from these real hulls x every armor material,
# at the thickness shown, using ModuleCatalog.compute_hull_max_hp() - the
# same function the Design Lab sidebar and battle_unit.gd use.
const TARGET_HULLS = [
	{"hull": "wedge_scout_meridian_a", "thickness": 0.6},
	{"hull": "kestrel_scout_a", "thickness": 1.0},
	{"hull": "brenntal_medium_a", "thickness": 1.4},
	{"hull": "block_heavy_meridian_a", "thickness": 2.0},
]
const TARGET_MATERIALS = ["hardened_steel", "reactive_armor", "ablative_ceramic", "energy_shielding"]

var _targets: Array = []
var _weapons: Array = []       # type_id order, tuned + locked
var _tunable: Array = []       # subset actually swept
var _base: Dictionary = {}     # type_id -> {dps, fire_rate, cost, damage_class}
var _current: Dictionary = {}  # type_id -> {dps, fire_rate}
var _rows: Dictionary = {}     # type_id -> cached metrics row


func _init():
	print("\n=======================================================")
	print("    KITBASH COMMAND COMBAT BALANCE OPTIMIZER")
	print("=======================================================\n")

	_build_targets()
	_build_weapons()

	print("Targets:  %d archetypes (%d hulls x %d materials)" % [
		_targets.size(), TARGET_HULLS.size(), TARGET_MATERIALS.size()])
	for t in _targets:
		print("   %-16s hp=%8.1f  (%s @ %.1f)" % [t.name, t.hp, t.material, t.thickness])
	print("Weapons:  %d scored, %d tunable, %d role-locked" % [
		_weapons.size(), _tunable.size(), _weapons.size() - _tunable.size()])
	print("Search:   %d x %d grid, %d passes -> %d evaluations\n" % [
		DPS_MULTIPLIERS.size(), RATE_MULTIPLIERS.size(), OPTIMIZER_PASSES,
		DPS_MULTIPLIERS.size() * RATE_MULTIPLIERS.size() * OPTIMIZER_PASSES * _tunable.size()])

	_recompute_all()
	var before_loss = _total_loss()
	var before_report = _diagnose()

	print("--- BASELINE (shipped values) ---")
	_print_diagnosis(before_report, before_loss)
	print("\n--- PER-WEAPON BASELINE MATRIX ---")
	_print_matrix()

	print("\n--- OPTIMIZING ---")
	_optimize()

	var after_loss = _total_loss()
	var after_report = _diagnose()
	print("\n--- RESULT (tuned values) ---")
	_print_diagnosis(after_report, after_loss)
	print("\n--- PER-WEAPON TUNED MATRIX ---")
	_print_matrix()

	print("\n--- PROPOSED CHANGES ---")
	_print_changes()
	_write_output()

	print("\nNOTE: this model has no range, no positioning, no armor modules,")
	print("and no missile interception. See this file's header for the full")
	print("list. Treat the output as candidates for playtest, not as truth.")

	quit(0)


# --- Setup -----------------------------------------------------------------

func _build_targets() -> void:
	for spec in TARGET_HULLS:
		for material in TARGET_MATERIALS:
			var hp = ModuleCatalog.compute_hull_max_hp(spec.hull, spec.thickness, material)
			_targets.append({
				"name": "%s/%s" % [spec.hull.replace("_hull", ""), _short_material(material)],
				"hp": hp,
				"material": material,
				"thickness": spec.thickness,
			})


func _build_weapons() -> void:
	var catalog = ModuleCatalog.get_catalog()
	for type_id in catalog.keys():
		var data = catalog[type_id]
		if data.get("category", "") != "weapon":
			continue
		if data.get("dps", 0.0) <= 0.0:
			continue
		var profile = ModuleCatalog.get_fire_profile(type_id)
		var cost = float(data.get("metal", 0)) + float(data.get("crystal", 0)) * CRYSTAL_WEIGHT
		_base[type_id] = {
			"dps": data.get("dps", 0.0),
			"fire_rate": profile.fire_rate,
			"cost": maxf(1.0, cost),
			"weight": maxf(1.0, data.get("weight", 1.0)),
			# Reach credited as value, not charged as cost - see RANGE_VALUE.
			"range_value": pow(profile.fire_range / REFERENCE_RANGE, RANGE_VALUE),
			"damage_class": _damage_class_for(type_id),
		}
		_current[type_id] = {"dps": _base[type_id].dps, "fire_rate": _base[type_id].fire_rate}
		_weapons.append(type_id)
		if not LOCKED_TYPES.has(type_id):
			_tunable.append(type_id)
	_weapons.sort()
	_tunable.sort()


# Delegates to the shared classifier. The old comment here said this was
# duplicated "because that logic is inline in a Node's _ready() and can't be
# called headlessly - if it ever moves to a static helper, call it here
# instead." It has (weapon_alpha.gd, 2026-08-11), so it does.
#
# WHAT THE HAND-COPY WAS GETTING WRONG, because it is worth recording. The
# three lists here had drifted to 5 kinetic / 6 explosive / 3 energy against
# combat's 12 / 17 / 10. Every list was a strict SUBSET, so all 25 missing
# weapons fell through to the `else` and were classified THERMAL. 23 of them
# actually reach the sweep - smoke_discharger and jammer_mast carry dps <= 0
# and are filtered out above - which is 23 of the 40 armed weapons this tool
# tunes, i.e. well over half:
#
#   kinetic   -> thermal : coil_gun, autocannon, anti_materiel_rifle,
#                          hypervelocity_missile, aa_autocannon, aps_interceptor
#   explosive -> thermal : smoke_discharger, mk19_grenade_launcher,
#                          recoilless_rifle, mine_layer, spigot_mortar,
#                          rocket_artillery, sam_launcher, loitering_munition,
#                          anti_radiation_missile, bunker_buster, cruise_missile
#   energy    -> thermal : heavy_laser, plasma_lobber, pd_laser,
#                          microwave_emitter, particle_lance, laser_dazzler,
#                          jammer_mast
#
# That is over half the armed roster tuned against the wrong ARMOR_TABLE
# column, and the error ran in BOTH directions rather than as a constant bias:
# the kinetic guns read far too weak against ablative_ceramic (thermal 25/0.30
# vs kinetic 8/0.90), while the explosive launchers read far too strong against
# reactive_armor (thermal 10/0.80 vs explosive 30/0.40) - reactive armour's
# entire purpose - and the energy weapons too strong against energy_shielding
# (thermal 20/0.50 vs energy 35/0.30). Since _simulate() compares per-shot
# alpha against these thresholds, a misclassification flips whole weapons
# between the chip regime and full penetration.
#
# Passing an empty tweaks dict is correct here and not a shortcut: this sweep
# reads BASE catalog stats with no per-design tweaks, and get_ammo(type_id, {})
# resolves the weapon's default round - the same thing auto_weapon.gd does for
# an untouched module. It also means the simulator now honours a default
# round's own damage_class override, which the hand-copy could not see at all.
func _damage_class_for(type_id: String) -> String:
	return WeaponAlphaScript.damage_class(type_id, {})


# --- Simulation ------------------------------------------------------------

# One weapon vs one target, through the real shared damage math.
func _simulate(type_id: String, target: Dictionary) -> Dictionary:
	var cur = _current[type_id]
	var dmg_class = _base[type_id].damage_class
	var per_shot = cur.dps * cur.fire_rate

	var pair = DamageResolverScript.get_material_threshold(
		target.material, dmg_class, target.thickness)
	var applied = DamageResolverScript.compute_hull_damage(per_shot, pair.x, pair.y)

	var eff_dps = applied / maxf(0.001, cur.fire_rate)
	var ttk = target.hp / eff_dps if eff_dps > 0.001 else 9999.0
	return {
		"eff_dps": eff_dps,
		"ttk": ttk,
		# The two currencies the domination test is expressed in - see
		# _diagnose() for why there are two and why neither alone works.
		# Both divide the same range-credited combat value.
		"efficiency": (eff_dps * _base[type_id].range_value) / _base[type_id].cost,
		"per_weight": (eff_dps * _base[type_id].range_value) / _base[type_id].weight,
		"chipping": per_shot < pair.x,
		# Whether DamageResolver's brute-force blend is engaging on this
		# matchup - see the alpha classification in _recompute_row().
		"brute": pair.x > 0.0 and per_shot >= pair.x * DamageResolverScript.BRUTE_FORCE_RATIO,
	}


func _recompute_row(type_id: String) -> void:
	var sims = []
	for t in _targets:
		sims.append(_simulate(type_id, t))

	# Counter-play spread: coefficient of variation of effective DPS across
	# armor MATERIALS (averaged over hulls), so a weapon that all four
	# materials answer identically scores 0.
	var by_material = {}
	for i in range(_targets.size()):
		var mat = _targets[i].material
		by_material[mat] = by_material.get(mat, 0.0) + sims[i].eff_dps
	var means = by_material.values()
	var mean = 0.0
	for v in means:
		mean += v
	mean /= maxf(1.0, float(means.size()))
	var variance = 0.0
	for v in means:
		variance += (v - mean) * (v - mean)
	variance /= maxf(1.0, float(means.size()))
	var spread = sqrt(variance) / mean if mean > 0.001 else 0.0

	# "Alpha" classification. A weapon whose per-shot damage clears
	# BRUTE_FORCE_RATIO x threshold on most archetypes is being resolved
	# almost entirely through DamageResolver's brute-force blend, which
	# lerps every material's reduction multiplier toward 1.0 - so all four
	# materials converge and its spread is near zero BY DESIGN. That is the
	# documented identity of a heavy weapon ("an overwhelmingly large hit
	# punches straight through the mitigation multipliers"), not a balance
	# failure, and penalizing it would mean gutting exactly the weapons the
	# mechanic exists to serve. Alpha weapons are therefore exempt from the
	# spread floor and reported separately.
	var brute_hits = 0
	for s in sims:
		if s.brute:
			brute_hits += 1
	var is_alpha = brute_hits > sims.size() / 2

	_rows[type_id] = {"sims": sims, "spread": spread, "alpha": is_alpha}


func _recompute_all() -> void:
	for type_id in _weapons:
		_recompute_row(type_id)


# --- Loss ------------------------------------------------------------------

func _total_loss() -> float:
	var loss = 0.0
	var d = _diagnose()

	loss += float(d.dominated.size()) * DOMINATION_WEIGHT

	for type_id in _weapons:
		var row = _rows[type_id]
		# Spread shortfall - only a penalty below the floor, never a reward
		# for going higher (an infinitely spiky weapon isn't better, it's
		# just unusable half the time). Alpha weapons are exempt: their
		# armor-blindness is the brute-force rule working as designed.
		if not row.alpha:
			loss += maxf(0.0, MIN_SPREAD - row.spread) * SPREAD_WEIGHT

		# TTK band, averaged so one bad matchup doesn't dominate the term.
		var ttk_pen = 0.0
		for s in row.sims:
			if s.ttk < TTK_MIN:
				ttk_pen += (TTK_MIN - s.ttk) / TTK_MIN
			elif s.ttk > TTK_MAX:
				# Cap raised from 3.0: at 3.0 a 150s TTK and a 900s TTK
				# scored identically, so the optimizer saw no reason to
				# improve a matchup that is completely hopeless rather than
				# merely bad. Still capped, so one unwinnable matchup can't
				# swamp the whole objective - a weapon IS allowed to have a
				# bad answer to something, that's the counter-play.
				ttk_pen += minf(8.0, (s.ttk - TTK_MAX) / TTK_MAX)
		loss += (ttk_pen / float(row.sims.size())) * TTK_WEIGHT

		# Regularizer: stay near the authored numbers unless there's a real
		# reason to move. Symmetric in log space so a 2x buff and a 2x nerf
		# are penalized equally.
		if _tunable.has(type_id):
			var dps_dev = abs(log(_current[type_id].dps / _base[type_id].dps))
			var rate_dev = abs(log(_current[type_id].fire_rate / _base[type_id].fire_rate))
			loss += (dps_dev + rate_dev) * DEVIATION_WEIGHT

	return loss


# Domination + niche analysis over the current matrix.
func _diagnose() -> Dictionary:
	var dominated = []
	var niches = {}
	for type_id in _weapons:
		niches[type_id] = 0

	# Best-in-class per archetype, in BOTH currencies (see below) - a weapon
	# holds a niche if it's the best damage-per-resource OR the best
	# damage-per-kilogram against some archetype.
	for i in range(_targets.size()):
		for metric in ["efficiency", "per_weight"]:
			var best = ""
			var best_val = -1.0
			for type_id in _weapons:
				var v = _rows[type_id].sims[i][metric]
				if v > best_val:
					best_val = v
					best = type_id
			if best != "":
				niches[best] += 1

	# Pairwise domination, as PARETO dominance over the two currencies a
	# player actually pays a weapon in:
	#
	#   efficiency  = effective DPS per resource spent (Metal + 2x Crystal)
	#   per_weight  = effective DPS per kilogram
	#
	# Mount slots are deliberately NOT one of them (Chris's correction,
	# 2026-07-30): a hull has plenty of surface, and nothing stops a player
	# bolting on another gun as long as they'll pay for it in resources and
	# accept a slower, less maneuverable vehicle. So "damage per slot" isn't
	# a scarce currency here - but WEIGHT is exactly the price that
	# willingness costs (recalculate_move_speed divides thrust by total
	# weight), which makes damage-per-kilogram the real second axis.
	#
	# Both matter and neither subsumes the other: a cheap gun that
	# out-damages per Metal is genuinely good, and so is a heavy-hitting gun
	# that gets more damage out of each kilogram of the mobility budget,
	# even at worse value-per-resource. Judging on cost-efficiency alone
	# declares nearly every heavy weapon "dominated" by basic_cannon, which
	# is an artifact of the metric rather than a balance finding.
	#
	# So A only dominates B if A is at least as good on BOTH axes against
	# EVERY archetype, and strictly better somewhere. That is a real "there
	# is no reason to ever build B" claim.
	#
	# Only tunable weapons are compared: a locked point-defense weapon
	# "losing" to a real gun on raw damage is its job description, not a bug.
	for b in _tunable:
		for a in _tunable:
			if a == b:
				continue
			var dominates = true
			var strictly_better = false
			for i in range(_targets.size()):
				var sa = _rows[a].sims[i]
				var sb = _rows[b].sims[i]
				if sa.efficiency < sb.efficiency - 0.0001 or sa.per_weight < sb.per_weight - 0.0001:
					dominates = false
					break
				if sa.efficiency > sb.efficiency + 0.0001 or sa.per_weight > sb.per_weight + 0.0001:
					strictly_better = true
			if dominates and strictly_better:
				dominated.append({"loser": b, "winner": a})
				break

	return {"dominated": dominated, "niches": niches}


# --- Optimizer -------------------------------------------------------------

# Coordinate descent: one weapon at a time, try every (dps, fire_rate) pair
# on the grid, keep the best by GLOBAL loss. The per-weapon metric rows are
# independent of each other (only the aggregation is coupled), so a move
# only requires recomputing the one row that changed.
func _optimize() -> void:
	# Greedy coordinate descent is order-dependent: whichever weapon moves
	# first constrains what the rest can do. Shuffling the visit order each
	# pass keeps one arbitrary alphabetical ordering from baking itself into
	# the result. Seeded so runs stay reproducible - change the seed to
	# check whether a result is a stable optimum or an artifact of the path.
	seed(20260730)
	var order = _tunable.duplicate()
	for p in range(OPTIMIZER_PASSES):
		order.shuffle()
		var improved = 0
		var pass_loss = _total_loss()
		for type_id in order:
			var saved = {"dps": _current[type_id].dps, "fire_rate": _current[type_id].fire_rate}
			var best = saved
			var best_loss = _total_loss()
			for dm in DPS_MULTIPLIERS:
				for rm in RATE_MULTIPLIERS:
					_current[type_id] = {
						"dps": _base[type_id].dps * dm,
						"fire_rate": _base[type_id].fire_rate * rm,
					}
					_recompute_row(type_id)
					var l = _total_loss()
					if l < best_loss - 0.0001:
						best_loss = l
						best = _current[type_id]
			_current[type_id] = best
			_recompute_row(type_id)
			if best.dps != saved.dps or best.fire_rate != saved.fire_rate:
				improved += 1
		var new_loss = _total_loss()
		print("  pass %d: loss %.2f -> %.2f (%d weapons moved)" % [
			p + 1, pass_loss, new_loss, improved])
		if improved == 0:
			print("  converged.")
			break


# --- Reporting -------------------------------------------------------------

func _print_diagnosis(d: Dictionary, loss: float) -> void:
	print("  total loss: %.2f" % loss)
	print("  dominated weapons: %d" % d.dominated.size())
	for entry in d.dominated:
		print("    %-20s is dominated by %s" % [entry.loser, entry.winner])
	var homeless = []
	for type_id in _tunable:
		if d.niches[type_id] == 0:
			homeless.append(type_id)
	print("  weapons holding no best-in-slot niche: %d" % homeless.size())
	if homeless.size() > 0:
		print("    %s" % ", ".join(homeless))
	var low_spread = []
	var alphas = []
	for type_id in _tunable:
		if _rows[type_id].alpha:
			alphas.append("%s(%.2f)" % [type_id, _rows[type_id].spread])
		elif _rows[type_id].spread < MIN_SPREAD:
			low_spread.append("%s(%.2f)" % [type_id, _rows[type_id].spread])
	print("  weapons below counter-play spread floor: %d" % low_spread.size())
	if low_spread.size() > 0:
		print("    %s" % ", ".join(low_spread))
	print("  armor-blind by brute force (exempt, by design): %d" % alphas.size())
	if alphas.size() > 0:
		print("    %s" % ", ".join(alphas))


func _print_matrix() -> void:
	var header = "  %-20s %6s %6s" % ["weapon", "dps", "rate"]
	for t in _targets:
		header += " %9s" % t.name
	header += "  spread"
	print(header)
	for type_id in _weapons:
		var row = _rows[type_id]
		var line = "  %-20s %6.1f %6.2f" % [
			type_id, _current[type_id].dps, _current[type_id].fire_rate]
		for s in row.sims:
			# TTK in seconds; "--" where the weapon can't realistically kill.
			line += " %9s" % ("    --" if s.ttk > 999.0 else "%9.1f" % s.ttk)
		line += "  %6.2f" % row.spread
		if LOCKED_TYPES.has(type_id):
			line += "  [locked]"
		print(line)


func _print_changes() -> void:
	var any = false
	print("  %-20s %18s %18s" % ["weapon", "dps", "fire_rate"])
	for type_id in _tunable:
		var b = _base[type_id]
		var c = _current[type_id]
		if is_equal_approx(b.dps, c.dps) and is_equal_approx(b.fire_rate, c.fire_rate):
			continue
		any = true
		print("  %-20s %8.1f -> %6.1f %8.2f -> %6.2f" % [
			type_id, b.dps, c.dps, b.fire_rate, c.fire_rate])
	if not any:
		print("  (none - shipped values already satisfy the objective)")


# Machine-readable output so the changes can be reviewed and applied without
# re-reading the printed table.
func _write_output() -> void:
	var out = {}
	for type_id in _tunable:
		out[type_id] = {
			"dps": snappedf(_current[type_id].dps, 0.5),
			"fire_rate": snappedf(_current[type_id].fire_rate, 0.01),
		}
	var path = "res://tools/balance_tuning_output.json"
	var f = FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		print("  (could not write %s)" % path)
		return
	f.store_string(JSON.stringify(out, "\t", true))
	f.close()
	print("\n  wrote %s" % path)


func _short_material(m: String) -> String:
	match m:
		"hardened_steel": return "steel"
		"reactive_armor": return "react"
		"ablative_ceramic": return "cer"
		"energy_shielding": return "shield"
	return m
