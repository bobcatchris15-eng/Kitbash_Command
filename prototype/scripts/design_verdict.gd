class_name DesignVerdict
extends RefCounted
# Turns a DesignStats.analyze() result into plain-language judgements.
#
# WHY THIS EXISTS. The Design Lab's telemetry rail is accurate and asks the
# player to be an engineer: it prints structure, weight, cost, DPS and drivetrain
# load, and leaves them to work out whether any of that is GOOD. A parametric
# tool leads with the constraint state - Fusion 360 says "Fully Constrained" in
# two words before showing a single dimension, and Onshape colours an
# over-defined sketch. The numbers stay; they stop being the first thing read.
#
# THE HARD RULE: THIS FILE COMPUTES NOTHING. Every value comes from the analyze()
# result it is handed. stat_calculator.gd has twice had to delete a local
# re-derivation that drifted from the real model - a capacity calculation that
# knew 4 locomotion types out of 17, and an armour table that showed the
# explosive threshold labelled as energy. A verdict that disagreed with the row
# beneath it would be worse than no verdict at all, so this only ever reads,
# compares against a threshold, and phrases.
#
# PURE AND SCENE-FREE ON PURPOSE. It takes a Dictionary and returns an Array of
# Dictionaries. That is what lets it be tested directly, without a Lab, without a
# hull, and without a rendered frame - which is why it is the first piece of the
# Design Lab work rather than a detail of the rail.

const Tokens = preload("res://scripts/ui_tokens.gd")

# Ordered worst-first. The rail shows the highest severity present, so the order
# here IS the priority order.
enum Severity { BLOCKING, WARNING, NOTE, GOOD }

# A design is "over capacity" the moment load_ratio exceeds 1.0 - that is
# drivetrain.gd's own is_overloaded flag, not a threshold invented here. But a
# 2% overload is not worth shouting about, so the VERDICT threshold is a little
# above the mechanical one and says so.
const OVERLOAD_NAG_RATIO := 1.05
# Below this fraction of the chassis rating, a design is leaving speed unused.
const UNDERLOAD_NOTE_RATIO := 0.55
# Power headroom under this fraction of generation reads as brownout risk.
const POWER_TIGHT_FRACTION := 0.1


# Returns an Array of {severity, headline, detail} dictionaries, worst first.
# Empty only when handed something that is not an analyze() result at all.
static func evaluate(stats: Dictionary) -> Array:
	var out: Array = []
	if stats.is_empty():
		return out

	var dt: Dictionary = stats.get("drivetrain", {})
	var wr: Dictionary = stats.get("weapon_range", {})
	var power: Dictionary = stats.get("power", {})
	var alpha: Dictionary = stats.get("alpha", {})

	# --- Blocking: the design cannot do its job at all ------------------------

	# No locomotion is not automatically wrong - a pillbox foundation is a real,
	# intentional design - so this is phrased as a statement of what it IS rather
	# than as an error. Getting this wrong would nag every defence structure the
	# player ever builds.
	if not bool(dt.get("has_locomotion", false)):
		out.append(_v(Severity.NOTE, "STATIC EMPLACEMENT",
			"No drive fitted. This design cannot move; it can still be placed as a defence."))
	elif bool(dt.get("is_overloaded", false)) \
			and float(dt.get("load_ratio", 0.0)) >= OVERLOAD_NAG_RATIO:
		var lost := float(dt.get("speed_lost_to_overload", 0.0))
		# `carried_weight` here, not `weight` - the load_ratio is off the
		# carried weight (Chris, 2026-08-16, "tuned for the unit"), so the
		# numerator on the verdict has to be the same figure the bar shows,
		# or the rail reads two different stories.
		var carried := float(dt.get("carried_weight", dt.get("weight", 0.0)))
		out.append(_v(Severity.BLOCKING, "OVER CAPACITY",
			"%s kg on %s kg of drive. Top speed cut by %.1f m/s." % [
				_round(carried), _round(dt.get("capacity", 0.0)), lost]))

	if not bool(stats.get("has_weapons", false)):
		# Harvesters and scouts are legitimately unarmed, and DesignStats already
		# knows which is which - so this distinguishes them instead of calling a
		# harvester a mistake.
		if bool(stats.get("is_harvester", false)):
			out.append(_v(Severity.NOTE, "HARVESTER",
				"Unarmed by design. This is the only unit that earns rather than spends."))
		else:
			out.append(_v(Severity.WARNING, "UNARMED",
				"No weapon fitted. This design cannot damage anything."))

	# --- Power ----------------------------------------------------------------
	var generation := float(power.get("generation", 0.0))
	var draw := float(power.get("draw", 0.0))
	var storage := float(power.get("storage", 0.0))
	var max_shot_cost := float(power.get("max_shot_cost", 0.0))
	
	if draw > 0.0 and generation <= 0.0:
		out.append(_v(Severity.BLOCKING, "UNPOWERED",
			"Draws %s power and generates none. Energy systems will not run." % _round(draw)))
	elif generation > 0.0 and draw > generation:
		out.append(_v(Severity.WARNING, "POWER DEFICIT",
			"Draws %s against %s generated." % [_round(draw), _round(generation)]))
	elif generation > 0.0 and (generation - draw) < generation * POWER_TIGHT_FRACTION:
		out.append(_v(Severity.NOTE, "POWER TIGHT",
			"Only %s spare. One more energy system will brown out." % _round(generation - draw)))

	if max_shot_cost > storage:
		print("Adding PEAK DRAW EXCESSIVE: max_shot_cost=", max_shot_cost, " storage=", storage)
		out.append(_v(Severity.BLOCKING, "PEAK DRAW EXCESSIVE",
			"A weapon needs %s energy to fire, but capacity is only %s. It will never fire." % [_round(max_shot_cost), _round(storage)]))
	else:
		print("No PEAK DRAW EXCESSIVE: max_shot_cost=", max_shot_cost, " storage=", storage)

	# --- Speed notes ----------------------------------------------------------
	# CAPACITY-LIMITED IS ITS OWN VERDICT because the fix is different, and that
	# distinction is drivetrain.gd's, not one invented here: when the chassis
	# rather than the powerplant is the ceiling, adding thrust or shedding weight
	# does nothing and the answer is a different locomotion type.
	if bool(dt.get("capacity_limited", false)) and not bool(dt.get("is_overloaded", false)):
		out.append(_v(Severity.NOTE, "CHASSIS LIMITED",
			"The drive type caps this design at %.1f m/s. More thrust will not help." % [
				float(dt.get("chassis_top_speed", 0.0))]))
	elif bool(dt.get("is_underloaded", false)) \
			and float(dt.get("load_ratio", 1.0)) <= UNDERLOAD_NOTE_RATIO:
		out.append(_v(Severity.NOTE, "RUNNING LIGHT",
			"Well under capacity: +%.1f m/s from the spare drive." % [
				float(dt.get("speed_gained_from_underload", 0.0))]))

	# --- Spotting -------------------------------------------------------------
	# A weapon that outranges its own vision is a real and very unintuitive trap:
	# the unit cannot see what it could shoot, so it needs a spotter to be worth
	# anything. weapon_range.gd already works out which weapons those are.
	var needs_spotter: Array = wr.get("spotter_required", [])
	if not needs_spotter.is_empty():
		out.append(_v(Severity.WARNING, "OUTRANGES ITS OWN VISION",
			"%d weapon(s) reach past this design's sight. Without a spotter they cannot engage." % [
				needs_spotter.size()]))

	# --- Striking power -------------------------------------------------------
	# A design whose HARDEST single hit lands under EVERY armour threshold in the
	# table is not just weak - it is weak in a way the rail's own Total DPS row
	# actively conceals. damage_resolver.gd delivers a sub-threshold hit at
	# CHIP_THROUGH_FACTOR of its already-reduced value, so a unit can print a
	# large DPS figure and still be unable to meaningfully hurt anything plated.
	# Nothing else on this screen says so, and the fix - fewer, heavier shots -
	# is not inferable from a DPS number that does not move when you make the
	# trade. WeaponAlpha did the measuring; this only reads its chipped_by list.
	#
	# ONLY the every-material case is a verdict, deliberately. Chipping against
	# SOME plate is ARMOR_TABLE working exactly as designed - it is a rock-paper-
	# scissors table, and every material is supposed to have something it answers.
	# A note for the partial case would fire on most legitimate designs and bury
	# BALANCED under noise. The rail prints the per-material regime rows directly
	# beneath the DPS row, so "which plates stop me" is already on screen; the
	# verdict is reserved for "all of them do".
	var chipped: Array = alpha.get("chipped_by", [])
	var material_count: int = int(alpha.get("material_count", 0))
	if bool(alpha.get("has_weapons", false)) and material_count > 0 \
			and chipped.size() >= material_count:
		# The lowest threshold among the ones being chipped: the cheapest line to
		# cross, so the verdict names a target and not only a problem. A min-scan
		# over figures already in the result - the thresholds were resolved by
		# DamageResolver.get_material_threshold() inside WeaponAlpha, and nothing
		# here re-derives one.
		var lowest := INF
		var lowest_label := ""
		for c in chipped:
			var t := float(c.get("threshold", 0.0))
			if t < lowest:
				lowest = t
				lowest_label = str(c.get("label", ""))
		# %.1f rather than _round() here, unlike every other figure in this file.
		# Weights and power budgets run to hundreds and a decimal on them reads as
		# machine output; alpha and thresholds live in single and double digits,
		# where the decimal IS the difference between clearing a threshold and not.
		out.append(_v(Severity.WARNING, "CHIPS ONLY",
			("Hardest hit is %.1f, under every armour threshold there is - these shots chip rather than penetrate, "
			+ "and land a fraction of their face value. %s is the lowest line at %.1f. "
			+ "Fewer, heavier shots is what crosses it: more caliber, and accept the slower cadence.") % [
				float(alpha.get("per_shot", 0.0)), lowest_label, lowest]))

	# --- All clear ------------------------------------------------------------
	# Only when nothing else fired. "BALANCED" alongside a warning would be the
	# interface contradicting itself.
	if out.is_empty():
		out.append(_v(Severity.GOOD, "BALANCED",
			"Within capacity, armed, and powered."))

	out.sort_custom(func(a, b): return a["severity"] < b["severity"])
	return out


# The single verdict the rail leads with: the worst one present.
static func headline(stats: Dictionary) -> Dictionary:
	var all := evaluate(stats)
	return all[0] if not all.is_empty() else {}


# The colour a severity is drawn in. Maps onto the SIGNAL palette rather than
# inventing one, so a blocking verdict is the same red as damage everywhere else.
static func color_for(severity: int) -> Color:
	match severity:
		Severity.BLOCKING: return Tokens.SIGNAL_ALERT
		Severity.WARNING: return Tokens.SIGNAL_HAZARD
		Severity.GOOD: return Tokens.SIGNAL_GO
		_: return Tokens.SIGNAL_INFO


static func _v(severity: int, headline_text: String, detail: String) -> Dictionary:
	return {"severity": severity, "headline": headline_text, "detail": detail}


# Whole numbers with thousands separators. A weight or a power figure with three
# decimal places in a headline reads as machine output rather than as a verdict.
static func _round(value) -> String:
	var n := int(round(float(value)))
	var s := str(absi(n))
	var out := ""
	var count := 0
	for i in range(s.length() - 1, -1, -1):
		out = s[i] + out
		count += 1
		if count % 3 == 0 and i > 0:
			out = "," + out
	return ("-" if n < 0 else "") + out


# Derives a high-level combat archetype, rating, and description for the unit profile.
static func get_combat_archetype(stats: Dictionary) -> Dictionary:
	if stats.is_empty():
		return {"role": "UNASSIGNED", "stars": 1, "desc": "Chassis incomplete."}

	var is_harv: bool = bool(stats.get("is_harvester", false))
	if is_harv:
		return {"role": "RESOURCE HARVESTER", "stars": 3, "desc": "Specialized logistics & economy vehicle."}

	var dt: Dictionary = stats.get("drivetrain", {})
	var wr: Dictionary = stats.get("weapon_range", {})
	var dps: float = float(stats.get("dps", 0.0))
	var top_spd: float = float(dt.get("top_speed", 0.0))
	var hp: float = float(stats.get("hull_hp", 0.0))
	var alpha: Dictionary = stats.get("alpha", {})
	var per_shot: float = float(alpha.get("per_shot", 0.0))
	var longest_rng: float = float(wr.get("longest", 0.0))
	var has_wpn: bool = bool(stats.get("has_weapons", false)) or dps > 0.0

	if not bool(dt.get("has_locomotion", false)):
		if has_wpn:
			return {"role": "STATIC DEFENSE TURRET", "stars": 3, "desc": "Immobile fortified weapon platform."}
		return {"role": "STATIC FOUNDATION", "stars": 1, "desc": "Unarmed static structure."}

	if not has_wpn:
		if top_spd >= 14.0:
			return {"role": "FAST RECON / SCOUT", "stars": 3, "desc": "High-speed tactical reconnaissance."}
		return {"role": "UTILITY / TRANSPORT", "stars": 2, "desc": "Support platform without offensive armament."}

	var role_name := "COMBAT VEHICLE"
	var desc := "All-round combatant."
	var stars := 3

	if longest_rng >= 90.0:
		if hp >= 900.0:
			role_name = "HEAVY SIEGE ARTILLERY"
			desc = "Massive range bombardment platform."
			stars = 5 if dps >= 80.0 else 4
		else:
			role_name = "MOBILE BVR ARTILLERY"
			desc = "Long-range fire support; requires spotter."
			stars = 4
	elif per_shot >= 250.0:
		role_name = "PRECISION TANK DESTROYER"
		desc = "Heavy single-shot armor penetrator."
		stars = 5 if top_spd >= 10.0 else 4
	elif top_spd >= 16.0:
		if dps >= 60.0:
			role_name = "FAST STRIKE SKIRMISHER"
			desc = "High-mobility hit-and-run raider."
			stars = 4
		else:
			role_name = "LIGHT FLANKING RAIDER"
			desc = "Fast harassment unit."
			stars = 3
	elif hp >= 1200.0:
		role_name = "HEAVY FRONTLINE JUGGERNAUT"
		desc = "Absorbs incoming fire while pushing objectives."
		stars = 5 if dps >= 70.0 else 4
	elif dps >= 90.0:
		role_name = "HIGH-DPS ASSAULT PLATFORM"
		desc = "Devastating close/medium range firepower."
		stars = 4
	else:
		role_name = "MEDIUM BATTLE UNIT"
		desc = "Balanced frontline combatant."
		stars = 3

	return {"role": role_name, "stars": stars, "desc": desc}
