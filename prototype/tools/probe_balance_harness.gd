extends SceneTree
# Balance harness — pits average fleets against each other via DamageResolver
# Run: Godot_v4.7.1-stable_win64_console.exe --headless --path . --script res://tools/probe_balance_harness.gd --quit
# Permanent harness per balancing task — keep for regression.

const WeaponAlphaScript = preload("res://scripts/weapon_alpha.gd")
const DamageResolverScript = preload("res://scripts/damage_resolver.gd")

const WEAPON_STATS := {
	"basic_cannon": {"dps": 40.0, "interval": 1.8},
	"heavy_machine_gun": {"dps": 32.5, "interval": 0.66},
	"rotary_cannon": {"dps": 105.0, "interval": 0.05},
	"gauss_railgun": {"dps": 99.0, "interval": 3.5},
	"artillery": {"dps": 90.0, "interval": 4.5},
	"mortar_array": {"dps": 50.0, "interval": 2.0},
	"guided_missile": {"dps": 55.0, "interval": 3.0},
	"missile_pod": {"dps": 72.0, "interval": 2.8},
	"flamethrower": {"dps": 112.0, "interval": 0.06},
	"heavy_laser": {"dps": 112.0, "interval": 0.05},
	"plasma_lobber": {"dps": 95.0, "interval": 2.2},
	"ion_cannon": {"dps": 97.5, "interval": 3.2},
	"particle_lance": {"dps": 120.0, "interval": 5.5},
	"bunker_buster": {"dps": 95.0, "interval": 4.2},
	"autocannon": {"dps": 62.0, "interval": 0.28},
	"coil_gun": {"dps": 88.0, "interval": 1.6},
}

const FLEETS := {
	"kinetic_brawler": ["basic_cannon", "heavy_machine_gun"],
	"kinetic_sniper": ["gauss_railgun", "autocannon"],
	"explosive_artillery": ["artillery", "mortar_array"],
	"explosive_missile": ["guided_missile", "missile_pod"],
	"energy_laser": ["heavy_laser", "ion_cannon"],
	"energy_thermal": ["flamethrower", "plasma_lobber"],
	"mixed_balanced": ["basic_cannon", "missile_pod", "heavy_laser"],
	"rapid_swarm": ["rotary_cannon", "heavy_machine_gun", "autocannon"],
	"alpha_strike": ["particle_lance", "bunker_buster"],
}
const ARMORS := ["hardened_steel", "titanium_plate", "ceramic_ablative", "reactive_armor", "energy_shielding", "composite_plate"]
const HULL_HP := 600.0

func _weapon_effective_dps(type_id: String, material: String) -> float:
	var stats: Dictionary = WEAPON_STATS.get(type_id, {})
	if stats.is_empty(): return 0.0
	var dps: float = float(stats.get("dps", 0.0))
	var interval: float = float(stats.get("interval", 1.0))
	var shot: float = dps * interval
	var dmg_class: String = WeaponAlphaScript.damage_class(type_id, {})
	var pair: Vector2 = DamageResolverScript.get_material_threshold(material, dmg_class, 1.0)
	return DamageResolverScript.compute_hull_damage(shot, pair.x, pair.y) / maxf(interval, 0.001)

func _fleet_dps(weapons: Array, material: String) -> float:
	var t := 0.0
	for w in weapons: t += _weapon_effective_dps(w, material)
	return t

func _init() -> void:
	await process_frame
	print("=== BALANCE HARNESS (HP %.0f) Chip=%.2f Brute %.1f/%.2f ===" % [HULL_HP, DamageResolverScript.CHIP_THROUGH_FACTOR, DamageResolverScript.BRUTE_FORCE_RATIO, DamageResolverScript.BRUTE_FORCE_MAX_BLEND])
	for fname in FLEETS:
		var best := ""; var worst := ""; var b := -1.0; var w := 999999.0
		for m in ARMORS:
			var d: float = _fleet_dps(FLEETS[fname], m)
			if d > b: b = d; best = m
			if d < w: w = d; worst = m
		print("%-20s ratio %.2fx (%s %.1f vs %s %.1f)" % [fname, b/maxf(w,0.01), best, b, worst, w])
	print("=== DONE ===")
	quit(0)
