extends RefCounted
## PowerBudget: generation, storage and draw for one design.
##
## The single answer to "what is this design's power situation", read by the
## Design Lab's stat rail, the roster cards, and both unit runtimes. Shaped
## deliberately like drivetrain.gd, because it is the same kind of object - one
## static analyze() over a live hull returning a fully-populated dictionary -
## and because that file's header documents at length what happened the two
## times a stat of this kind grew a second, local re-derivation (a capacity
## calculation that knew four locomotion types out of seventeen, and an armour
## table showing the explosive threshold mislabelled as energy). There is one
## copy of this arithmetic and everything reads it.
##
## THE MODEL. Three quantities that used to be two, and the split is the point:
##
##   STORAGE     energy       hull base_energy + capacitor modules
##   GENERATION  energy/sec   hull base_power  + generator modules
##   DRAW        energy/sec   ModuleCatalog.POWER_DRAW, summed over modules
##
## Generation refills storage; draw empties it; `net` is the difference. Before
## the split there was no generation stat at all - the refill rate was derived
## as `storage * 0.08`, so storage manufactured generation and the two most
## interesting shapes a power system has (big buffer that trickles, small buffer
## that refills fast) were both inexpressible. Now they are two modules.
##
## WHY STORAGE MATTERS SEPARATELY: it is entirely possible - and often correct -
## to field a design whose draw exceeds its generation. Storage is what decides
## whether that is a brief burst you can afford or a design that browns out
## thirty seconds into every engagement. `endurance` below is that number.

const ModuleCatalog = preload("res://scripts/module_catalog.gd")

## Buffer fractions at which systems shed load, in the order they shed.
##
## Shields first, then electronics, then weapons. That order is not arbitrary:
## it runs from the system whose loss is most recoverable to the one whose loss
## ends the fight. Losing the barrier costs you the next hit. Losing vision
## costs you the ability to pick your fights, which is worse but survivable.
## Losing your guns is the end of the argument, so it goes last.
##
## WEAPONS_OFFLINE is not enforced by any new code - spend_energy() already
## returns false on an empty buffer, and has since energy weapons were added.
## The constant exists so the threshold has a NAME and appears in the same
## ordered list as the other two, rather than being an emergent property of an
## unrelated function that a reader would have to go find.
const SHIELDS_OFFLINE := 0.50
const ELECTRONICS_BROWNOUT := 0.25
const WEAPONS_OFFLINE := 0.10

## How far vision falls once electronics brown out. Not to zero: a unit that
## goes completely blind reads as a bug rather than as a consequence, and it
## would also make a drained scout permanently useless rather than temporarily
## degraded. 0.55 is enough to feel immediately at RTS camera distance while
## leaving the unit able to see what is shooting it.
const BROWNOUT_VISION_MULT := 0.55

## Added to each threshold on the way back UP, so a design sitting exactly on a
## boundary does not flicker its vision radius every physics frame as the buffer
## crosses back and forth. Standard Schmitt-trigger hysteresis; the value only
## has to exceed one frame's worth of regen at a plausible rate.
const RECOVERY_HYSTERESIS := 0.05


## The full analysis. Every key is present on every path - including the
## null-hull early return below - and that is load bearing rather than tidy:
## design_stats.gd calls its analyzers UNCONDITIONALLY, before its own hull
## validity check, precisely because the Design Lab calls update_stats(null) on
## clear_hull(). An analyzer that returned a partial dictionary there has
## already broken the Lab once (see the comment at design_stats.gd:64).
## `hull_type_override` exists for callers that already hold the authoritative
## type - unit_assembly.compute_energy() is handed it by its caller, and a
## standalone or test-built hull does not always carry the meta. Passing it
## explicitly is better than having this function guess and the caller patch the
## result afterwards, which double-counts the hull's own contribution.
static func analyze(hull_node, hull_type_override: String = "") -> Dictionary:
	# No hull and no declared type means there is no design to analyse, and the
	# honest answer is zeros rather than some default hull's figures.
	#
	# This matters because it is a state the Design Lab is IN, not a defensive
	# guard against something that cannot happen: clear_hull() calls
	# update_stats(null), and an earlier cut of this function fell back to
	# medium_hull there - so an empty Lab confidently reported 70 storage and
	# 5.6 generation for a design that did not exist. `has_hull` is what the
	# rail branches on to hide the rows, the same way the drivetrain readout
	# branches on has_locomotion.
	if not is_instance_valid(hull_node) and hull_type_override == "":
		return _empty()

	# medium_hull only as a last resort for a hull that exists but carries no
	# type_id - a standalone or test-built node. Something has to be assumed
	# there, and the roster's own default is the least surprising choice.
	var hull_type := "brenntal_medium_a"
	if hull_type_override != "":
		hull_type = hull_type_override
	elif is_instance_valid(hull_node) and hull_node.has_meta("type_id"):
		hull_type = str(hull_node.get_meta("type_id"))

	var storage: float = ModuleCatalog.get_base_energy(hull_type)
	var generation: float = ModuleCatalog.get_base_power(hull_type)
	var draw := 0.0
	var burst_draw := 0.0

	if is_instance_valid(hull_node):
		for child in hull_node.get_children():
			if not child.has_meta("module_data") or child.is_queued_for_deletion():
				continue
			var data = child.get_meta("module_data")
			if data == null:
				continue
			# Generators and capacitors. Asked for both quantities regardless of
			# category, because a module having one of them and not the other is
			# a catalog fact, not something this function should assume - a
			# future part that both generates and stores would work here with no
			# change.
			storage += data.get_energy_capacity()
			generation += data.get_power_output()
			draw += ModuleCatalog.get_power_draw(data.type_id)
			burst_draw += _sustained_weapon_draw(data)

	# Only the hull's own storage can be zero-or-less in practice, but guard
	# anyway: endurance divides by the deficit and load_fraction by storage.
	storage = maxf(0.0, storage)

	var total_draw: float = draw + burst_draw

	# TWO net figures, and the distinction is the useful part of this whole
	# analysis.
	#
	# `net` excludes weapon draw, so it describes the design AT REST - idling,
	# moving, scouting, doing everything except shooting. A negative `net` is a
	# permanent problem: the design cannot even keep its own lights on and will
	# brown out eventually no matter what the player does with it.
	#
	# `firing_net` includes it, and a negative one is a completely different and
	# much more forgivable situation: the design is fine until it opens fire and
	# then runs a tab against its buffer. That is a legitimate build - burst
	# damage paid for with capacitors and recharged between engagements - and
	# reporting it as the same failure as the first case would tell the player to
	# fix something that is not broken.
	#
	# Folding them into one number, which an earlier cut of this did, makes every
	# energy-weapon design read as permanently under-powered.
	var net: float = generation - draw
	var firing_net: float = generation - total_draw

	# How long a full buffer lasts at each deficit. INF when there is none, which
	# is the honest answer and reads correctly at the call site ("indefinitely")
	# rather than making every caller branch before it can divide.
	var endurance := INF
	if net < 0.0:
		endurance = storage / absf(net)
	var firing_endurance := INF
	if firing_net < 0.0:
		firing_endurance = storage / absf(firing_net)

	return {
		"has_hull": true,
		"storage": storage,
		"generation": generation,
		# Continuous draw from electronics and shield upkeep - the part that is
		# always happening, whatever the unit is doing.
		"draw": draw,
		# The sustained-fire equivalent of the design's energy weapons. Reported
		# separately as well as inside total_draw, because it is conditional in a
		# way the rest is not: a unit that is not shooting is not paying it.
		"weapon_draw": burst_draw,
		"total_draw": total_draw,
		"net": net,
		"firing_net": firing_net,
		"has_deficit": net < 0.0,
		# True only when firing is what tips it over - deliberately false when
		# the design is already in deficit at rest, so the two states are
		# mutually exclusive and a caller can branch on them in either order.
		"firing_deficit_only": net >= 0.0 and firing_net < 0.0,
		"endurance": endurance,
		"firing_endurance": firing_endurance,
	}


## The no-design result. Written out in full rather than built by zeroing a
## template, so it is impossible for it to drift out of key-parity with the real
## return above without the mismatch being visible in one screenful.
##
## endurance is INF, not 0: a design with nothing running is not about to brown
## out in no time at all, it is never going to brown out. Zero would read as the
## worst possible case at exactly the moment there is no case.
static func _empty() -> Dictionary:
	return {
		"has_hull": false,
		"storage": 0.0,
		"generation": 0.0,
		"draw": 0.0,
		"weapon_draw": 0.0,
		"total_draw": 0.0,
		"net": 0.0,
		"firing_net": 0.0,
		"has_deficit": false,
		"firing_deficit_only": false,
		"endurance": INF,
		"firing_endurance": INF,
	}


## An energy weapon's per-shot cost expressed as energy per second, so it can be
## added to a budget denominated in per-second terms.
##
## Display-and-planning only. The actual spend stays exactly where it was, in
## auto_weapon.gd's per-shot spend_energy() call - this function does not change
## when or whether a weapon fires. It exists so the Design Lab can answer "can
## this design sustain its own guns", which is a real question a player has and
## which no amount of staring at a per-shot number answers.
##
## Mirrors auto_weapon.gd:826 (`energy_cost_per_shot = dps * fire_rate * 0.4`)
## and then divides by fire_rate to get the rate, which cancels to `dps * 0.4`.
## Written out in both steps rather than pre-cancelled: the cancellation is only
## valid while auto_weapon derives the cost that way, and someone changing that
## formula needs to see this one is downstream of it.
const ENERGY_WEAPON_TYPES := ["arc_projector", "ion_cannon", "microwave_emitter", "particle_lance", "heavy_laser", "pd_laser", "gauss_railgun", "coil_gun", "plasma_lobber"]
const ENERGY_COST_FRACTION := 0.4

static func _sustained_weapon_draw(data) -> float:
	if not (data.type_id in ENERGY_WEAPON_TYPES):
		return 0.0
	# dps is already per-second, so cost_per_shot/fire_rate reduces to this.
	return data.get_dps() * ENERGY_COST_FRACTION


## Which systems are shed at a given buffer fraction, as an ordered report.
##
## One function rather than three threshold comparisons scattered across the two
## unit runtimes, so the runtimes cannot disagree with each other or with the
## Design Lab's warning panel about what browns out first.
##
## `previous` carries the last frame's state so hysteresis can apply: a system
## sheds at its threshold but does not come back until the buffer has recovered
## past it by RECOVERY_HYSTERESIS.
static func brownout_state(buffer_fraction: float, previous: Dictionary = {}) -> Dictionary:
	var f: float = clampf(buffer_fraction, 0.0, 1.0)
	return {
		"shields_offline": _shed(f, SHIELDS_OFFLINE, previous.get("shields_offline", false)),
		"electronics_brownout": _shed(f, ELECTRONICS_BROWNOUT, previous.get("electronics_brownout", false)),
		"weapons_offline": _shed(f, WEAPONS_OFFLINE, previous.get("weapons_offline", false)),
	}


## The vision multiplier implied by a brownout state. Separate from
## brownout_state() so a caller that only wants the number does not have to know
## which key carries it.
static func vision_multiplier(state: Dictionary) -> float:
	return BROWNOUT_VISION_MULT if state.get("electronics_brownout", false) else 1.0


static func _shed(fraction: float, threshold: float, was_shed: bool) -> bool:
	if was_shed:
		# Already off - stays off until the buffer clears the threshold by the
		# hysteresis margin.
		return fraction < threshold + RECOVERY_HYSTERESIS
	return fraction < threshold
