class_name ThreatAnalyzer
extends RefCounted
# Static analysis of blueprints and live units for the AI's combat intelligence.
#
# WHAT THIS IS. The AI's "eyes" for the damage-type × armor-material matchup
# system that IS the game's core design puzzle. Without this, the AI sees two
# threat axes (air, armor) and is blind to the 4×6 rock-paper-scissors grid
# that the player manipulates in the Design Lab every round.
#
# WHAT IT REPLACES. CounterDraft.threats_of() only tagged "air" and "armor".
# This module extracts a full tactical profile — damage class mix, armor
# weakness, engagement range, locomotion traits — and exposes the pure math
# for "what weapon type beats this armor" and "what ammo should I load against
# this threat mix". CounterDraft still owns the roster reorder; this is the
# analysis layer it reads.
#
# CHEAT-FREE. Every function is a pure static analysis of a blueprint dict
# or the ARMOR_TABLE — no game state, no vision bypass, no privileged
# knowledge. The commander feeds it fog-gated observations the same way it
# feeds Considerations.

const DamageResolverScript = preload("res://scripts/damage_resolver.gd")
const ModuleCatalogScript = preload("res://scripts/module_catalog.gd")

# --- Damage classes recognized by the game ---
const DAMAGE_CLASSES := ["kinetic", "thermal", "explosive", "energy"]

# --- Ammo types and their native damage class (from ModuleCatalog.AMMO_TYPES) ---
# Kept in sync with module_catalog.gd's AMMO_TYPES. If a new ammo type lands
# there, it needs an entry here or adapt_ammo() will ignore it.
const AMMO_DAMAGE_CLASS := {
	"standard": "",   # inherits from the weapon's native class
	"ap": "kinetic",
	"he": "explosive",
	"incendiary": "thermal",
	"flechette": "kinetic",
	"emp": "energy",
	"smoke": "",      # utility, no damage
	"illumination": "",
}

# Ammo types that deal real damage and are worth considering for counter-picks.
# Smoke/illumination are utility — they do not shift the damage profile.
const COMBAT_AMMO := ["standard", "ap", "he", "incendiary", "flechette", "emp"]


# --- Profile extraction --------------------------------------------------------
#
# A profile is a plain Dictionary describing what a design does and what it is
# vulnerable to. Pure data, no game state.
#
# Keys:
#   damage_mix:     Dictionary { "kinetic": 0.6, "thermal": 0.4, ... } (shares of 1.0 by DPS)
#   dominant_damage: String — the damage class with the highest DPS share
#   armor_material: String
#   armor_thickness: float
#   armor_weakness:  String — the damage class with the lowest threshold against this material
#   hull_class:     String (scout, light, medium, heavy, transport, oddball, foundation)
#   engagement_range: float — range of the highest-DPS weapon
#   is_indirect:    bool — true if primary weapon fires in an arc
#   has_point_defense: int — count of PD weapons
#   locomotion_traits: Array[String]
#   total_dps:      float
#   weapon_count:   int

static func profile(blueprint: Dictionary) -> Dictionary:
	var modules: Array = blueprint.get("modules", [])
	var hull_type: String = str(blueprint.get("hull_type", ""))
	var loco_type: String = str(blueprint.get("locomotion", {}).get("type_id", ""))
	var armor_mat: String = str(blueprint.get("armor_material", "hardened_steel"))
	var armor_thick: float = float(blueprint.get("armor_thickness", 1.0))

	# Damage mix by DPS contribution
	var class_dps := {}
	for dc in DAMAGE_CLASSES:
		class_dps[dc] = 0.0

	var total_dps := 0.0
	var best_weapon_dps := 0.0
	var best_weapon_range := 0.0
	var best_weapon_projectile := ""
	var weapon_count := 0
	var pd_count := 0

	for m in modules:
		var type_id: String = str(m.get("type_id", ""))
		var mod_data: Dictionary = ModuleCatalogScript.get_module_data(type_id)
		if mod_data.is_empty():
			continue

		var category: String = str(mod_data.get("category", ""))

		# Count point defense
		if category == "point_defense":
			pd_count += 1

		# Only count weapons that deal damage
		if category not in ["weapon", "energy_weapon", "point_defense", "deployable", "indirect_fire"]:
			# Not a weapon — skip. But also check the fire profile.
			pass
		var fire_profile: Dictionary = _get_fire_profile(type_id)
		if fire_profile.is_empty():
			continue

		weapon_count += 1
		var dps: float = float(m.get("stats", {}).get("dps", fire_profile.get("dps", 0.0)))
		if dps <= 0.0:
			continue

		# Determine effective damage class (native class, possibly overridden by ammo)
		var native_class: String = str(fire_profile.get("damage_class",
			mod_data.get("damage_class", "kinetic")))
		var ammo: String = str(m.get("tweaks", {}).get("ammo", "standard"))
		var effective_class: String = _effective_damage_class(native_class, ammo)

		class_dps[effective_class] = class_dps.get(effective_class, 0.0) + dps
		total_dps += dps

		if dps > best_weapon_dps:
			best_weapon_dps = dps
			best_weapon_range = float(fire_profile.get("range",
				m.get("stats", {}).get("range", 30.0)))
			best_weapon_projectile = str(fire_profile.get("projectile_class", "ballistic"))

	# Normalize to shares
	var damage_mix := {}
	var dominant_damage := "kinetic"
	var dominant_share := 0.0
	for dc in DAMAGE_CLASSES:
		var share: float = class_dps[dc] / total_dps if total_dps > 0.0 else 0.0
		damage_mix[dc] = share
		if share > dominant_share:
			dominant_share = share
			dominant_damage = dc

	# Hull class
	var hull_data: Dictionary = ModuleCatalogScript.get_module_data(hull_type)
	var hull_class: String = str(hull_data.get("hull_class", "medium")).to_lower()

	# Locomotion traits
	var traits: Array = ModuleCatalogScript.get_traits(hull_type, loco_type)

	return {
		"damage_mix": damage_mix,
		"dominant_damage": dominant_damage,
		"armor_material": armor_mat,
		"armor_thickness": armor_thick,
		"armor_weakness": weakest_class_against(armor_mat),
		"hull_class": hull_class,
		"engagement_range": best_weapon_range,
		"is_indirect": best_weapon_projectile == "arc",
		"has_point_defense": pd_count,
		"locomotion_traits": traits,
		"total_dps": total_dps,
		"weapon_count": weapon_count,
	}


# --- Armor weakness analysis ---------------------------------------------------
#
# Given an armor material, what damage class has the lowest threshold against it?
# That is the Achilles' heel — the damage type that bypasses the most armor.

static func weakest_class_against(material: String) -> String:
	var row: Dictionary = DamageResolverScript.ARMOR_TABLE.get(material, {})
	if row.is_empty():
		row = DamageResolverScript.ARMOR_TABLE.get("hardened_steel", {})
	var worst_class := "kinetic"
	var worst_threshold := INF
	for dc in DAMAGE_CLASSES:
		var entry: Array = row.get(dc, [15.0, 0.7])
		# Lower threshold = easier to penetrate = bigger weakness
		var threshold: float = float(entry[0])
		if threshold < worst_threshold:
			worst_threshold = threshold
			worst_class = dc
	return worst_class


# The effective DPS a weapon deals against a specific armor material, accounting
# for threshold and pass_through. Used to rank counter-picks.
#
# Uses single-hit math: dps * fire_interval gives per-shot damage, then
# resolve through armor, then back to DPS. This is the same math
# DamageResolver.compute_hull_damage() uses, condensed for comparison.
static func effective_dps_against(dps: float, fire_interval: float,
		damage_class: String, material: String, thickness: float = 1.0) -> float:
	if dps <= 0.0 or fire_interval <= 0.0:
		return 0.0
	var per_shot: float = dps * fire_interval
	var row: Dictionary = DamageResolverScript.ARMOR_TABLE.get(material, {})
	if row.is_empty():
		return dps
	var entry: Array = row.get(damage_class, [10.0, 0.8])
	var threshold: float = float(entry[0]) * thickness
	var pass_through: float = float(entry[1])
	var resolved: float = DamageResolverScript.compute_hull_damage(
		per_shot, threshold, pass_through)
	return resolved / fire_interval if fire_interval > 0.0 else 0.0


# --- Threat tagging (replaces CounterDraft.threats_of) -------------------------
#
# Returns an array of threat tags for a blueprint. Superset of the old system:
# "air" and "armor" are still here, plus damage-class-dominant tags and
# "missile_spam" for guided-projectile saturation.

static func threats_of(blueprint: Dictionary) -> Array:
	var out: Array = []
	var p: Dictionary = profile(blueprint)

	# Airborne
	if "airborne" in p["locomotion_traits"]:
		out.append("air")

	# Heavy armor (same rule as old CounterDraft)
	if p["hull_class"] == "heavy" or p["armor_thickness"] >= 1.5:
		out.append("armor")

	# Dominant damage class, if it exceeds a meaningful share.
	# "kinetic_heavy" means "this design mostly deals kinetic damage, so
	# the counter is armor that resists kinetic". The naming convention is
	# <damage_class>_heavy.
	var dominant: String = p["dominant_damage"]
	var dominant_share: float = float(p["damage_mix"].get(dominant, 0.0))
	if dominant_share >= 0.5 and p["total_dps"] > 0.0:
		out.append(dominant + "_heavy")

	# Armor material as a tag — tells the counter-drafter what damage class
	# to bring. Named as "wears_<material>".
	out.append("wears_" + p["armor_material"])

	# Missile spam: more than half the DPS comes from guided projectiles.
	var guided_dps := _guided_dps_share(blueprint)
	if guided_dps >= 0.5:
		out.append("missile_spam")

	# Indirect fire dominant
	if p["is_indirect"] and p["total_dps"] > 0.0:
		out.append("indirect")

	return out


# --- Counter-pick recommendations ----------------------------------------------
#
# Given what the AI has SEEN the player fielding (an array of profiles from
# fog-gated observations), what should the AI build?

# Returns the damage class that would be most effective against the observed
# enemy force's dominant armor material.
static func best_damage_class_against_force(observed_profiles: Array) -> String:
	# Tally armor materials weighted by unit count (not DPS — the question is
	# "what are they wearing", not "what are they shooting")
	var material_count := {}
	for p in observed_profiles:
		var mat: String = str(p.get("armor_material", "hardened_steel"))
		material_count[mat] = int(material_count.get(mat, 0)) + 1

	if material_count.is_empty():
		return "kinetic"  # safe default

	# Find the dominant material
	var dominant_mat := "hardened_steel"
	var dominant_count := 0
	for mat in material_count:
		if int(material_count[mat]) > dominant_count:
			dominant_count = int(material_count[mat])
			dominant_mat = mat

	return weakest_class_against(dominant_mat)


# Which of the AI's available ammo types best counters the given armor material?
# Returns an ammo type string suitable for blueprint tweaks.ammo.
static func best_ammo_against(material: String) -> String:
	var weakness: String = weakest_class_against(material)
	# Map damage class back to the ammo that produces it
	match weakness:
		"thermal":
			return "incendiary"
		"kinetic":
			return "ap"
		"explosive":
			return "he"
		"energy":
			return "emp"
	return "standard"


# --- Ammo adaptation -----------------------------------------------------------
#
# Given a blueprint and an observed dominant enemy armor material, return a
# SHALLOW COPY of the blueprint with weapon ammo types swapped to counter.
# Only swaps weapons whose native damage class is NOT already the counter —
# a weapon already dealing the right damage class keeps its current ammo.
#
# Does NOT swap to ammo that requires a tech gate the AI hasn't unlocked.
# `unlocked_techs` is an Array of tech building IDs the AI has built.

static func adapt_ammo(blueprint: Dictionary, enemy_armor: String,
		unlocked_techs: Array = []) -> Dictionary:
	if enemy_armor.is_empty():
		return blueprint

	var counter_ammo: String = best_ammo_against(enemy_armor)
	if counter_ammo == "standard":
		return blueprint

	# Check tech gate for the counter ammo
	var ammo_data: Dictionary = ModuleCatalogScript.get_catalog().get("ammo_types", {})
	# Tech gates from AMMO_TYPES in module_catalog.gd
	var ammo_tech_gate := {
		"incendiary": "tech_lab",
		"flechette": "tech_lab",
		"emp": "exotics_lab",
		"smoke": "tech_lab",
		"illumination": "tech_lab",
	}
	var gate: String = ammo_tech_gate.get(counter_ammo, "")
	if not gate.is_empty() and gate not in unlocked_techs:
		return blueprint

	# Shallow-copy the blueprint, deep-copy only the modules array
	var adapted: Dictionary = blueprint.duplicate()
	var new_modules: Array = []
	for m in blueprint.get("modules", []):
		var type_id: String = str(m.get("type_id", ""))
		var fire_profile: Dictionary = _get_fire_profile(type_id)
		if fire_profile.is_empty():
			new_modules.append(m)
			continue

		# Only swap if this weapon would benefit from the change
		var native_class: String = str(fire_profile.get("damage_class", "kinetic"))
		var current_ammo: String = str(m.get("tweaks", {}).get("ammo", "standard"))
		var current_class: String = _effective_damage_class(native_class, current_ammo)
		var counter_class: String = str(AMMO_DAMAGE_CLASS.get(counter_ammo, ""))

		# Don't swap if already dealing the right damage class
		if current_class == counter_class or counter_class.is_empty():
			new_modules.append(m)
			continue

		# Don't swap utility weapons (PD, deployables that don't deal damage)
		var dps: float = float(fire_profile.get("dps", 0.0))
		if dps <= 0.0:
			new_modules.append(m)
			continue

		# Swap it
		var new_m: Dictionary = m.duplicate()
		var new_tweaks: Dictionary = new_m.get("tweaks", {}).duplicate()
		new_tweaks["ammo"] = counter_ammo
		new_m["tweaks"] = new_tweaks
		new_modules.append(new_m)

	adapted["modules"] = new_modules
	return adapted


# --- Armor adaptation (Operations) ---------------------------------------------
#
# Between Operations rounds, the AI can swap its own armor material to counter
# the player's observed dominant damage class. Returns a shallow copy of the
# blueprint with the armor_material changed.

static func adapt_armor(blueprint: Dictionary, enemy_dominant_damage: String,
		unlocked_techs: Array = []) -> Dictionary:
	if enemy_dominant_damage.is_empty():
		return blueprint

	var best_mat: String = best_material_against(enemy_dominant_damage)
	if best_mat.is_empty() or best_mat == str(blueprint.get("armor_material", "")):
		return blueprint

	# Tech gates for higher-end materials
	var material_tech_gate := {
		"carbon_fiber": "tech_lab",
		"titanium_plate": "tech_lab",
		"energy_shielding": "",  # base tier
	}
	var gate: String = material_tech_gate.get(best_mat, "")
	if not gate.is_empty() and gate not in unlocked_techs:
		return blueprint

	var adapted: Dictionary = blueprint.duplicate()
	adapted["armor_material"] = best_mat
	return adapted


# Given a damage class, which armor material has the highest threshold against it?
static func best_material_against(damage_class: String) -> String:
	var best_mat := ""
	var best_threshold := 0.0
	for mat in DamageResolverScript.ARMOR_TABLE:
		var row: Dictionary = DamageResolverScript.ARMOR_TABLE[mat]
		var entry: Array = row.get(damage_class, [10.0, 0.8])
		var threshold: float = float(entry[0])
		# Prefer higher threshold AND lower pass_through (more protection)
		# Combined score: threshold * (1.0 - pass_through) gives "effective block"
		var pass_through: float = float(entry[1])
		var effectiveness: float = threshold * (1.0 - pass_through)
		if effectiveness > best_threshold:
			best_threshold = effectiveness
			best_mat = mat
	return best_mat


# --- Helpers -------------------------------------------------------------------

static func _get_fire_profile(type_id: String) -> Dictionary:
	if not ModuleCatalogScript.needs_combat_script(type_id):
		# Check if it's still a weapon by looking for fire profile data
		pass
	var cat: Dictionary = ModuleCatalogScript.get_catalog()
	var mod_data: Dictionary = cat.get(type_id, {})
	if mod_data.is_empty():
		return {}
	# Weapons have dps and fire_rate in the catalog or in WEAPON_FIRE_PROFILES
	var dps: float = float(mod_data.get("dps", 0.0))
	var fire_rate: float = float(mod_data.get("fire_rate", 0.0))
	if dps <= 0.0 and fire_rate <= 0.0:
		return {}
	return {
		"dps": dps,
		"fire_rate": fire_rate,
		"range": float(mod_data.get("range", 30.0)),
		"damage_class": str(mod_data.get("damage_class", "kinetic")),
		"projectile_class": str(mod_data.get("projectile_class", "ballistic")),
	}


static func _effective_damage_class(native_class: String, ammo: String) -> String:
	if ammo == "standard" or ammo.is_empty():
		return native_class
	var override: String = AMMO_DAMAGE_CLASS.get(ammo, "")
	return override if not override.is_empty() else native_class


static func _guided_dps_share(blueprint: Dictionary) -> float:
	var guided := 0.0
	var total := 0.0
	for m in blueprint.get("modules", []):
		var type_id: String = str(m.get("type_id", ""))
		var fp: Dictionary = _get_fire_profile(type_id)
		if fp.is_empty():
			continue
		var dps: float = float(m.get("stats", {}).get("dps", fp.get("dps", 0.0)))
		if dps <= 0.0:
			continue
		total += dps
		if str(fp.get("projectile_class", "")) == "guided":
			guided += dps
	return guided / total if total > 0.0 else 0.0
