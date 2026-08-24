extends RefCounted
class_name DesignStats
# The design's numbers, computed once, from a live hull node.
#
# WHY THIS FILE EXISTS. Every figure below was previously computed inside
# stat_calculator.gd's update_stats() - a 100-line block of locals interleaved
# with the label assignments that displayed them. That made the numbers reachable
# only by the Design Lab sidebar, which is why:
#
#   * fleet_comparison_panel.gd tried to read them off the stat_calculator node
#     (`stat_calc.total_weight if "total_weight" in stat_calc`). They were
#     function LOCALS, so that guard never passed and its comparison column
#     silently showed 0 HP / 0 kg / 0 DPS. update_stats() now publishes them as
#     members specifically to fix that - see its own comment - which is a
#     workaround for the computation not being callable.
#   * the roster cards in roster_picker.gd had no way to show real stats at all.
#
# THE RULE THIS FILE PROTECTS. Every number here comes from the same static call
# combat makes. Nothing is re-derived. stat_calculator.gd learned that lesson
# twice already and left the scars in its comments: a local weight/capacity
# re-derivation that "only needed to be close enough to warn" knew about four
# locomotion types out of seventeen, and a local armour-threshold table had
# drifted so far it was showing the EXPLOSIVE threshold labelled as Energy. Both
# were fixed by deleting the copy, not by correcting it.
#
# So: if a figure is wanted that is not here, add it here and let both callers
# read it. Do not compute it at the call site.

const ResourceCatalogScript = preload("res://scripts/battle/economy/resource_catalog.gd")

const ModuleCatalog = preload("res://scripts/module_catalog.gd")
const LiveryScript = preload("res://scripts/livery.gd")
# For its static hopper formula only - no state machine is instantiated here.
const HarvesterFSMScript = preload("res://scripts/battle/economy/harvester_fsm.gd")
const PowerBudgetScript = preload("res://scripts/power_budget.gd")
const Drivetrain = preload("res://scripts/drivetrain.gd")
const WeaponRange = preload("res://scripts/weapon_range.gd")
const WeaponAlpha = preload("res://scripts/weapon_alpha.gd")


# `hull` must be a reconstructed or in-editor hull node: the metadata this reads
# (type_id, hull_scale, armor_material, armor_thickness, faction,
# locomotion_type, locomotion_settings) is set by
# BlueprintManager.reconstruct_vehicle() and by the Design Lab's own placer, and
# module figures come from each child's "module_data" meta.
static func analyze(hull: Node3D) -> Dictionary:
	var out := {
		"hull_hp": 0.0,
		"module_hp_pool": 0.0,
		"dps": 0.0,
		"weight": 0.0,
		"cost_metal": 0,
		"cost_crystal": 0,
		# What the design actually PRICES AT. Materials above are the authoring
		# inputs - crystal is the "advanced" one and converts at 2x - and this is
		# the single number the economy spends. See ResourceCatalog.
		"cost_credits": 0,
		"energy_capacity": 0.0,
		"move_speed": 0.0,
		"top_speed": 0.0,
		"longest_range": 0.0,
		"shortest_range": 0.0,
		"vision": 0.0,
		"has_weapons": false,
		"drivetrain": {},
		"weapon_range": {},
		# What one HIT is worth, and what it is worth once it meets armour.
		#
		# `dps` above is the figure the Design Lab has always shown, and it is
		# the one figure the caliber slider CANNOT move in an interesting way:
		# caliber multiplies get_dps(), get_weight() and get_cost() by the same
		# factor, so DPS-per-kg and DPS-per-credit are flat across the whole
		# slider. The trade it actually makes is one layer down - caliber also
		# multiplies the shot INTERVAL, so a bigger bore is fewer, harder hits -
		# and only alpha decides which side of an armour threshold a hit lands
		# on. Between the chip regime and the brute-force regime that is roughly
		# a 6.7x swing in delivered damage off the same nominal DPS. See
		# weapon_alpha.gd's header; the whole point of carrying this alongside
		# `dps` is that the two disagree, and the disagreement is the design.
		"alpha": {},
		# The power budget - generation, storage, draw and net. Empty here and
		# filled from PowerBudget.analyze() below, alongside the other two
		# analyzers and for the same reason: it returns a full key set on every
		# path, so consumers can read into it unconditionally.
		"power": {},
		# Harvesting. A design that mounts a harvester arm is a fundamentally
		# different KIND of thing from everything else in a roster - it is the
		# only unit that makes money rather than spends it - and until now the
		# only sign of that on a roster card was the word "unarmed", which a
		# scout and a sensor platform also earn. Fielding twelve unarmed cards
		# and discovering none of them harvest is a real way to lose a match.
		"is_harvester": false,
		"harvester_modules": 0,
		"cargo_capacity": 0,
	}
	# Called UNCONDITIONALLY, before the hull validity check below, and this is
	# load-bearing: both analyzers guard against a null hull internally and return
	# a FULLY POPULATED dictionary for one (Drivetrain returns its
	# has_locomotion: false variant, WeaponRange returns its zeroed `out`).
	#
	# An earlier version of this function returned `"drivetrain": {}` when the hull
	# was invalid, which broke the Design Lab on load: clear_hull() calls
	# update_stats(null), and _update_drivetrain_readout() then read
	# dt["has_locomotion"] off an empty dictionary. The consumers reasonably expect
	# these dictionaries to always carry their full key set, because that is what
	# calling the analyzers directly always gave them.
	#
	# Same call unit.gd makes when it spawns the unit for real, with no
	# arguments because reconstruct_vehicle() writes locomotion_type and
	# locomotion_settings onto the hull as metadata.
	var dt: Dictionary = Drivetrain.analyze(hull)
	var wr: Dictionary = WeaponRange.analyze(hull)
	var pb: Dictionary = PowerBudgetScript.analyze(hull)
	# Fourth analyzer, same contract as the other three: guards a null hull
	# internally and returns its fully-keyed zeroed `out`, so the rail and the
	# verdict can read into it without a validity check of their own.
	var wa: Dictionary = WeaponAlpha.analyze(hull)
	out["drivetrain"] = dt
	out["weapon_range"] = wr
	out["power"] = pb
	out["alpha"] = wa
	out["weight"] = float(dt.get("weight", 0.0))
	out["move_speed"] = float(dt.get("move_speed", 0.0))
	out["top_speed"] = float(dt.get("top_speed", 0.0))
	out["longest_range"] = float(wr.get("longest", 0.0))
	out["shortest_range"] = float(wr.get("shortest", 0.0))
	out["vision"] = float(wr.get("vision", 0.0))
	out["has_weapons"] = bool(wr.get("has_weapons", false))

	if not is_instance_valid(hull):
		return out

	var armor_material := str(hull.get_meta("armor_material", "hardened_steel"))
	var armor_thickness := float(hull.get_meta("armor_thickness", 1.0))
	# See drivetrain.gd's matching default: absent meta means "no faction yet",
	# which is the Design Lab, and NO_FACTION resolves every passive to its
	# unmodified base value.
	var faction := str(hull.get_meta("faction", LiveryScript.NO_LIVERY))
	var hull_type := str(hull.get_meta("type_id", "brenntal_medium_a"))
	var hull_scale = hull.get_meta("hull_scale", Vector3.ONE)

	# Hull HP is the unit's REAL combat health pool, from the shared
	# ModuleCatalog function unit.gd and building.gd also read, times the
	# faction's hp passive. Module HP is a separate per-part pool that subsystem
	# stripping drains without touching hull HP - so the two are reported
	# separately rather than summed, which is a distinction an earlier version of
	# the sidebar got wrong (an empty hull displayed 0 HP and fielded at 400).
	out["hull_hp"] = ModuleCatalog.compute_hull_max_hp(
		hull_type, armor_thickness, armor_material, hull_scale
	)
	# Painted armor adds NO HP: the paint types are cosmetic likenesses (see
	# ArmorPaint.PAINT_TYPE_IDS). Their catalog stat rows were retired; the
	# hull's own material/thickness plate is the whole armor pool.

	var hull_cost = ModuleCatalog.compute_hull_cost(
		hull_type, armor_thickness, armor_material, hull_scale
	)
	out["cost_metal"] = int(hull_cost.x)
	out["cost_crystal"] = int(hull_cost.y)

	for child in hull.get_children():
		if not child.has_meta("module_data"):
			continue
		if child.is_queued_for_deletion():
			continue
		var data = child.get_meta("module_data")
		if data == null:
			continue
		out["module_hp_pool"] += data.get_hp()
		out["dps"] += data.get_dps()
		var c = data.get_cost()
		out["cost_metal"] += int(c.x)
		out["cost_crystal"] += int(c.y)
		if data.category == "generator":
			out["energy_capacity"] += data.get_energy_capacity()
		if data.type_id == "resource_harvester":
			out["harvester_modules"] += 1

	# Payload, quoted from HarvesterFSM's own formula rather than re-derived.
	# The Design Lab's stat rail has twice had to delete a local re-derivation
	# that drifted from combat (see drivetrain.gd's header); a roster card
	# promising a hopper size the match does not honour would be the same bug
	# in a new place, and "how much does it carry" is exactly what a player
	# picks a hauler on.
	out["is_harvester"] = out["harvester_modules"] > 0
	if out["is_harvester"]:
		out["cargo_capacity"] = HarvesterFSMScript.capacity_for(
			out["harvester_modules"], hull_type,
			ModuleCatalog.resource_bay_capacity(hull))

	# The price, from the materials. Crystal converts at 2x, so a design leaning
	# on advanced modules simply costs more - see ResourceCatalog.
	out["cost_credits"] = ResourceCatalogScript.credits_from_materials(
		Vector2i(out["cost_metal"], out["cost_crystal"]))

	# The drivetrain- and range-derived figures (weight, move_speed, top_speed,
	# ranges, vision, has_weapons) are already set above, before the validity
	# guard, so they are correct for an empty hull too. Weight in particular is
	# taken from the drivetrain analysis rather than re-added here, so the
	# displayed weight is the same number Drivetrain.analyze() reports.
	#
	# On weight vs the load ratio: since the "tuned for the unit" change
	# (Chris, 2026-08-16), Drivetrain's `weight` is the design's total mass
	# and `load_ratio` is off `carried_weight` (= total - hull - locomotion).
	# The Lab shows both: the unit weighs X (the total) and is at Y% of its
	# drive's load rating (carried/total). The two intentionally can
	# disagree - a heavy hull on light treads shows "this weighs a lot" and
	# "you're nowhere near capacity" at the same time.
	out["carried_weight"] = float(dt.get("carried_weight", 0.0))
	out["loco_weight"] = float(dt.get("loco_weight", 0.0))
	#
	# On move_speed vs top_speed: move_speed is COMBAT speed, after the overload
	# penalty and faction passives. top_speed is the design's clean figure before
	# those. Callers showing one number to the player want move_speed.
	return out
