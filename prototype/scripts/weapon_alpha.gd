extends RefCounted
# Single source of truth for a weapon's PER-SHOT ALPHA, and for what that alpha
# is actually worth once it meets armour.
#
# WHY THIS EXISTS. `fire_rate` is a shot INTERVAL, not a rate, so a weapon's real
# hit is `dps * fire_rate` - and damage_resolver.gd gates on THAT number, never on
# dps. A shot under the material's threshold delivers only CHIP_THROUGH_FACTOR
# (0.15) of its already-reduced damage; a shot at BRUTE_FORCE_RATIO (4x) threshold
# or more starts blending the reduction back toward 1.0. Between those two regimes
# there is roughly a 6.7x swing in what a hit is worth, decided entirely by alpha
# against the defender's armour.
#
# None of that was visible anywhere in the Design Lab, and the way the stats are
# built actively hid it. `caliber` and `barrel_length` sit in the linear
# multiplier list of ModuleData.get_dps(), get_weight() AND get_cost() alike, so
# dragging the caliber slider moved all three numbers by the same factor:
# DPS-per-kg and DPS-per-credit were perfectly FLAT across the whole slider range,
# the rail showed nothing else, and a player who concluded the slider did not
# matter was reading the interface correctly. The trade is real, but it lives one
# layer down - caliber also multiplies the shot interval, so a bigger calibre is
# FEWER, HARDER hits, and only harder hits cross a threshold. DESIGN_VISION.md's
# test ("two players building the same concept must diverge through continuous
# tweaks") is decided here and essentially nowhere else, so this is the figure the
# rail has to print.
#
# SAME REASON weapon_range.gd EXISTS, AND THE SAME SHAPE. The cadence chain below
# was inline in auto_weapon._ready(), which meant COMBAT knew a weapon's real
# cadence and nothing else did; any readout added elsewhere would have had to
# re-implement it and then drift from it, which is exactly what happened to weight
# capacity before drivetrain.gd. It lives here once now, and:
#
#   * auto_weapon.gd should call shot_interval() in place of its own
#     lines ~806-818, and damage_class() in place of its ~731-752 chain.
#   * tools/run_simulations.gd's _damage_class_for() already carries a comment
#     saying "if it ever moves to a static helper, call it here instead". It has.
#
# NOTHING HERE RE-IMPLEMENTS THE DAMAGE MATH. Thresholds come from
# DamageResolver.get_material_threshold() and delivered damage from
# DamageResolver.compute_hull_damage() - the identical calls unit.gd makes through
# damage_model.gd. Even the regime test below reads the resolver's own
# BRUTE_FORCE_RATIO rather than restating 4.0. A readout that disagreed with
# combat would be worse than no readout at all, which this codebase has now
# learned twice over (see drivetrain.gd's and design_verdict.gd's headers).

const ModuleCatalog = preload("res://scripts/module_catalog.gd")
const DamageResolverScript = preload("res://scripts/damage_resolver.gd")

# The thickness every comparison in analyze() is quoted at. A REFERENCE figure,
# deliberately not the design's own armour: this readout is about what the design
# DEALS, and the defender it will meet has whatever plate its own builder chose.
# 1.0 is the table's authored baseline, so the four numbers are directly the
# ARMOR_TABLE rows and a player can reason about them without a second variable
# moving underneath.
const REFERENCE_THICKNESS: float = 1.0

# Guard for the divisions that turn per-shot damage back into per-second damage.
# Every shipped tweak range keeps the interval well above this (see
# stat_calculator.gd's TWEAK_SPECS minimums); it exists so a hand-edited blueprint
# cannot produce an infinity in a label.
const MIN_INTERVAL: float = 0.001

# The three regimes compute_hull_damage() actually has. Named because the whole
# point of the readout is to make the transition between them legible, and a
# stringly-typed "chip" scattered across a UI file and a verdict file is how those
# two end up disagreeing about spelling.
const REGIME_CHIP := "chip"
const REGIME_THROUGH := "through"
const REGIME_BRUTE := "brute"

# --- Damage classification (copied out of auto_weapon.gd's _ready) -----------
# Verbatim from the if/elif chain at auto_weapon.gd:731-741, split into three
# named lists so the classification can be called rather than re-typed. The
# energy list is auto_weapon.ENERGY_DAMAGE_CLASS_TYPES; see its comment there and
# damage_resolver.gd's "energy" row for why those weapons stopped resolving as
# explosive.
const KINETIC_TYPES := [
	"basic_cannon", "heavy_machine_gun", "rotary_cannon", "gauss_railgun", "ciws",
	"coil_gun", "autocannon", "anti_materiel_rifle",
	"hypervelocity_missile", "aa_autocannon",
]
const EXPLOSIVE_TYPES := [
	"artillery", "mortar_array", "guided_missile", "missile_pod",
	"cluster_dispenser", "flak_cannon", "smoke_discharger",
	"mk19_grenade_launcher", "recoilless_rifle", "mine_layer", "spigot_mortar",
	"rocket_artillery", "sam_launcher", "loitering_munition",
	"anti_radiation_missile", "bunker_buster", "cruise_missile",
]
const ENERGY_TYPES := [
	"arc_projector", "ion_cannon", "heavy_laser", "plasma_lobber",
	"pd_laser", "microwave_emitter", "particle_lance",
]

# Short display names for the armour columns. The full names the Lab's material
# dropdown uses ("Hardened Steel", "Energy Shielding") are twice the width the
# telemetry rail has for a table column. The fallback derives a label from the id
# rather than returning "", so a material added to ARMOR_TABLE renders as
# something readable on the day it lands instead of as a blank row.
const MATERIAL_LABELS := {
	"hardened_steel": "Steel",
	"reactive_armor": "Reactive",
	"ablative_ceramic": "Ceramic",
	"energy_shielding": "Shielding",
}


static func short_label(material: String) -> String:
	if MATERIAL_LABELS.has(material):
		return MATERIAL_LABELS[material]
	return material.split("_")[0].capitalize()


static func _num(tweaks: Dictionary, key: String) -> float:
	var v = tweaks.get(key, null)
	if v == null:
		return 0.0
	if typeof(v) == TYPE_BOOL:
		return 1.0 if v else 0.0
	if typeof(v) != TYPE_FLOAT and typeof(v) != TYPE_INT:
		return 0.0
	return float(v)


# Seconds between shots, from the weapon's authored profile through every tweak
# that touches cadence. A MIRROR of auto_weapon.gd:806-818 down to the order of
# operations, because the two must agree exactly - the guards below are the same
# `> 0.0` guards that chain already has.
#
# Only `caliber` differs, and only in a case the sliders cannot produce:
# auto_weapon multiplies by the raw tweak value, so a non-numeric caliber from a
# hand-edited blueprint would error there and reads as 0.0 here. A numeric
# caliber - which is the only thing TWEAK_SPECS can emit - gives an identical
# result.
static func shot_interval(type_id: String, tweaks: Dictionary) -> float:
	var interval: float = ModuleCatalog.get_fire_profile(type_id).fire_rate
	if tweaks.has("caliber"):
		interval *= _num(tweaks, "caliber")
	if tweaks.get("multi_barrel", false) == true:
		interval /= 2.0
	if _num(tweaks, "tube_count") > 0.0:
		interval *= (_num(tweaks, "tube_count") / 2.0)
	if _num(tweaks, "grid_size") > 0.0:
		interval *= (_num(tweaks, "grid_size") / 4.0)
	if _num(tweaks, "pressure_valve") > 0.0:
		interval /= _num(tweaks, "pressure_valve")
	if _num(tweaks, "launch_catapult") > 0.0:
		interval /= _num(tweaks, "launch_catapult")
	return interval


# Which column of ARMOR_TABLE this weapon's hits are resolved against.
#
# The loaded round wins over the weapon's native class, exactly as it does in
# auto_weapon.gd - an AP round out of a cannon is still kinetic, but a thermal
# round out of the same cannon is thermal, and that swap moves the weapon from one
# armour column to a completely different one. Every weapon with no ammo selection
# at all falls through get_ammo_profile()'s neutral default and keeps its native
# class.
static func damage_class(type_id: String, tweaks: Dictionary) -> String:
	var native := "thermal"
	if type_id in KINETIC_TYPES:
		native = "kinetic"
	elif type_id in EXPLOSIVE_TYPES:
		native = "explosive"
	elif type_id in ENERGY_TYPES:
		native = "energy"
	var ammo_class: String = str(ModuleCatalog.get_ammo_profile(
		ModuleCatalog.get_ammo(type_id, tweaks)).get("damage_class", ""))
	return ammo_class if ammo_class != "" else native


# One shot's raw damage, before armour: what every _fire_*() in auto_weapon.gd
# hands to _deal_weapon_damage() as `dps * fire_rate`, times the loaded round's
# own multiplier (applied at auto_weapon.gd:341, on the way into take_damage).
#
# get_dps() is CALLED, never cached or re-derived, so this figure inherits every
# fix to the tweak multipliers inside it automatically.
#
# The two situational multipliers auto_weapon applies further down that funnel -
# the point-defence anti-air bonus and each round's light_mult - are deliberately
# left out: both depend on what is being shot at, and a rail figure that silently
# assumed an aerial target would be wrong against every ground unit.
static func per_shot(data, interval: float = -1.0) -> float:
	if data == null:
		return 0.0
	var cadence: float = interval if interval >= 0.0 else shot_interval(data.type_id, data.tweaks)
	var ammo_mult: float = float(ModuleCatalog.get_ammo_profile(
		ModuleCatalog.get_ammo(data.type_id, data.tweaks)).get("damage_mult", 1.0))
	return data.get_dps() * cadence * ammo_mult


# Which branch of compute_hull_damage() a shot of this size takes. The two tests
# are that function's own two tests, reading its own constant - this is a
# classification of the resolver's behaviour, not a second copy of it.
static func regime(shot: float, threshold: float) -> String:
	if threshold <= 0.0:
		return REGIME_THROUGH
	if shot < threshold:
		return REGIME_CHIP
	if shot >= threshold * DamageResolverScript.BRUTE_FORCE_RATIO:
		return REGIME_BRUTE
	return REGIME_THROUGH


# What one weapon delivers against one armour material.
#
# `dps` here is EFFECTIVE dps - the damage that actually lands on the hull pool,
# per second - which is the number the Lab's "Total DPS" row is not. Two weapons
# with identical Total DPS can differ by a factor of six in this column, and that
# difference IS the caliber slider.
static func vs_material(shot: float, interval: float, dmg_class: String,
		material: String, thickness: float = REFERENCE_THICKNESS) -> Dictionary:
	var pair: Vector2 = DamageResolverScript.get_material_threshold(material, dmg_class, thickness)
	var dealt: float = DamageResolverScript.compute_hull_damage(shot, pair.x, pair.y)
	return {
		"material": material,
		"label": short_label(material),
		"threshold": pair.x,
		"reduction": pair.y,
		"per_shot": dealt,
		"dps": dealt / maxf(interval, MIN_INTERVAL),
		# Share of the raw shot that survives the armour. The headline evidence
		# for the chip regime: 0.10 here means ninety per cent of the shot was
		# stopped by a threshold the design never crosses.
		"fraction": (dealt / shot) if shot > 0.0 else 0.0,
		"regime": regime(shot, pair.x),
	}


# The whole design's striking power, for the Design Lab readout. Mirrors
# WeaponRange.analyze()'s contract exactly: one call, one dictionary, a FULL key
# set on every path including a null hull, and no caller-side maths.
#
# That last part is not a style preference. design_stats.gd calls its analyzers
# unconditionally, before its own hull validity check, precisely because they all
# promise a complete dictionary - an earlier version that returned `{}` for an
# invalid hull took the whole Lab down on clear_hull(). See the comment at
# design_stats.gd:81.
static func analyze(hull_node: Node3D) -> Dictionary:
	var out := {
		"has_weapons": false,
		# The design's HARDEST single shot, and the weapon that lands it. The
		# hardest shot is the right aggregate rather than a sum or a mean,
		# because thresholds are crossed one shot at a time: a design whose big
		# gun punches through is not stopped by also carrying a machine gun that
		# chips.
		"per_shot": 0.0,
		"interval": 0.0,
		"hardest": "",
		"hardest_class": "",
		# Per armed module, in hull child order. {name, type_id, damage_class,
		# per_shot, interval, dps, vs: {material -> vs_material() row}}.
		"weapons": [],
		# Summed across every armed module: what this design actually lands per
		# second on a hull of each material.
		"effective_dps": {},
		# The regime of the HARDEST shot against each material.
		"regime": {},
		# Materials whose threshold the hardest shot does not reach, as
		# {material, label, threshold} - i.e. the armour this design is reduced
		# to chipping at. Pre-shaped for the verdict, which is only allowed to
		# phrase what it is handed.
		"chipped_by": [],
		"material_count": 0,
		# Best and worst matchups, by effective dps. Named from the ATTACKER's
		# point of view: strongest_against is the plate this design shreds.
		"strongest_against": "",
		"weakest_against": "",
		"reference_thickness": REFERENCE_THICKNESS,
	}
	for material in DamageResolverScript.ARMOR_TABLE:
		out["effective_dps"][material] = 0.0
		out["regime"][material] = ""
		out["material_count"] += 1
	if hull_node == null or not is_instance_valid(hull_node):
		return out

	var hardest: float = 0.0
	for child in hull_node.get_children():
		if not child.has_meta("module_data"):
			continue
		if child.is_queued_for_deletion():
			continue
		var data = child.get_meta("module_data")
		if data == null or data.category != "weapon":
			continue
		# Same filter WeaponRange.analyze() applies, and for the same reason: a
		# smoke discharger or a decoy launcher has a cadence but no damage, and
		# folding zeroes into an "effective damage" table says nothing.
		if data.get_dps() <= 0.0:
			continue

		var interval: float = shot_interval(data.type_id, data.tweaks)
		var dmg_class: String = damage_class(data.type_id, data.tweaks)
		var shot: float = per_shot(data, interval)
		var entry := {
			"name": str(ModuleCatalog.get_module_data(data.type_id).get("name", data.type_id)),
			"type_id": data.type_id,
			"damage_class": dmg_class,
			"per_shot": shot,
			"interval": interval,
			"dps": data.get_dps(),
			"vs": {},
		}
		for material in DamageResolverScript.ARMOR_TABLE:
			var row := vs_material(shot, interval, dmg_class, material)
			entry["vs"][material] = row
			out["effective_dps"][material] += row["dps"]
		out["weapons"].append(entry)
		out["has_weapons"] = true

		if shot > hardest:
			hardest = shot
			out["per_shot"] = shot
			out["interval"] = interval
			out["hardest"] = entry["name"]
			out["hardest_class"] = dmg_class
			out["regime"] = {}
			out["chipped_by"] = []
			for material in DamageResolverScript.ARMOR_TABLE:
				var row: Dictionary = entry["vs"][material]
				out["regime"][material] = row["regime"]
				if row["regime"] == REGIME_CHIP:
					out["chipped_by"].append({
						"material": material,
						"label": row["label"],
						"threshold": row["threshold"],
					})

	if out["has_weapons"]:
		var best := ""
		var worst := ""
		for material in out["effective_dps"]:
			var v: float = out["effective_dps"][material]
			if best == "" or v > float(out["effective_dps"][best]):
				best = material
			if worst == "" or v < float(out["effective_dps"][worst]):
				worst = material
		out["strongest_against"] = best
		out["weakest_against"] = worst
	return out
