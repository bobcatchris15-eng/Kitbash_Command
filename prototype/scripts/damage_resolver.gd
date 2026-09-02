class_name DamageResolver
# Shared armor/threshold resolution for unit.gd (Skirmish + Test Range,
# the only unit script in the tree post-2026-08-10 retirement of
# battle_unit.gd / player_vehicle.gd) and building.gd (defense structures).
# Previously this math was duplicated inline across all three and already
# drifted once (had to be manually kept in sync when the armor-module bonus
# was added) - single source of truth from here on. See DECISIONS_NEEDED.md
# for the phased directional-armor build-out plan this is part of.

const ModuleCatalogScript = preload("res://scripts/module_catalog.gd")
# Preloaded rather than leaned on as a class_name global so the layer bit in
# SLOPE_TRACE_MASK below cannot drift from its definition. battle_layers.gd has
# no preloads of its own, so this closes no cycle.
const BattleLayersScript = preload("res://scripts/battle/battle_layers.gd")
# Elevation combat advantage (multi-map pass): shooting down at a target on
# meaningfully lower ground pierces more easily - real armor doesn't
# protect top-down as well as face-on, and it gives holding a hill a real
# combat payoff on top of the vision bonus (skirmish.gd's
# _recalc_fog_of_war()). Threshold-based (lowers how much armor blocks
# entirely), not a flat damage multiplier, so it composes with everything
# else resolve() already does. Reads directly off hit_origin/defender's
# real Y coordinates - no map/zone awareness needed here, since
# terrain_builder.gd's terrain_height_at() is the only place elevation Y
# ever gets set in the first place.
const ELEVATION_COMBAT_THRESHOLD: float = 2.0
const ELEVATION_COMBAT_PIERCE_MULTIPLIER: float = 0.85

# damage_type -> [base_threshold, pass_through] per armor material.
#
# `pass_through` is NOT a reduction fraction - it is the multiplier applied
# TO the damage that gets through, i.e. how much survives the armor. Low
# pass_through (0.20, energy_shielding vs energy) means the armor stops
# almost everything; high pass_through (0.92, steel vs thermal) means it
# stops almost nothing. The field used to be named "reduction", which reads
# backwards at every call site - a low "reduction" value looked like weak
# armor when it meant the opposite. Renamed for legibility only; no value
# below has moved.
#
# "energy" row added this pass (ENERGY_AND_BALANCE_SPEC.md #4 follow-up):
# previously there was no "energy" key at all, so any weapon dealing
# damage_class=="energy" (arc_projector/ion_cannon) silently fell
# through get_material_threshold()'s row.get(damage_type, row["explosive"])
# fallback and actually resolved as EXPLOSIVE damage - a real bug, not just
# a missing feature, found while scoping the energy-weapon-reclassification
# work. energy_shielding gets a genuinely strong energy threshold (its own
# name is the thematic justification); hardened_steel/reactive_armor are
# weak against it (plate steel and reactive plates don't stop directed
# energy); ablative_ceramic is moderate (ablative/heat-resistant materials
# have some real answer to it, just not a dedicated one).
#
# ALIASES. Fourteen material keys exist (for save-compat and naming history)
# but only five distinct stat rows do. Building each alias group from ONE
# shared Dictionary literal - rather than retyping the numbers per key - means
# they are the SAME object in memory: editing "steel_plate"'s numbers edits
# "hardened_steel"/"armor_plating"/"slat_armor" too, so the group can never
# silently drift apart again the way it already had once. ARMOR_MATERIAL_ALIAS
# below documents the grouping explicitly for anything that wants to know a
# key's canonical name (e.g. collapsing UI rows) without walking ARMOR_TABLE.
static var _STEEL_ROW := {"kinetic": [15.0, 0.7], "thermal": [4.0, 0.92], "explosive": [10.0, 0.8], "energy": [6.0, 0.88]}
static var _COMPOSITE_ROW := {"kinetic": [20.0, 0.65], "thermal": [18.0, 0.6], "explosive": [25.0, 0.45], "energy": [15.0, 0.7]}
static var _CERAMIC_ROW := {"kinetic": [6.0, 0.95], "thermal": [28.0, 0.25], "explosive": [10.0, 0.7], "energy": [15.0, 0.6]}
static var _NYLON_ROW := {"kinetic": [7.0, 0.85], "thermal": [22.0, 0.4], "explosive": [24.0, 0.5], "energy": [12.0, 0.7]}
static var _REACTIVE_ROW := {"kinetic": [9.0, 0.82], "thermal": [10.0, 0.8], "explosive": [30.0, 0.4], "energy": [8.0, 0.85]}
static var _ENERGY_SHIELDING_ROW := {"kinetic": [8.0, 0.85], "thermal": [20.0, 0.5], "explosive": [20.0, 0.5], "energy": [48.0, 0.20]}
static var _TITANIUM_ROW := {"kinetic": [30.0, 0.45], "thermal": [6.0, 0.90], "explosive": [14.0, 0.7], "energy": [9.0, 0.8]}

static var ARMOR_TABLE := {
	"steel_plate": _STEEL_ROW,
	"hardened_steel": _STEEL_ROW,
	"armor_plating": _STEEL_ROW,
	"slat_armor": _STEEL_ROW,
	"composite_plate": _COMPOSITE_ROW,
	"spaced_composite": _COMPOSITE_ROW,
	"ceramic_ablative": _CERAMIC_ROW,
	"ablative_ceramic": _CERAMIC_ROW,
	"ablative_foam": _CERAMIC_ROW,
	"ballistic_nylon": _NYLON_ROW,
	"carbon_fiber": _NYLON_ROW,
	"reactive_armor": _REACTIVE_ROW,
	"energy_shielding": _ENERGY_SHIELDING_ROW,
	"titanium_plate": _TITANIUM_ROW,
}

# material key -> canonical key (itself, for the canonical keys). Consumers
# that need to know "which materials are really the same thing" (e.g. to
# collapse duplicate UI rows) should use this rather than comparing
# ARMOR_TABLE rows by value.
const ARMOR_MATERIAL_ALIAS := {
	"steel_plate": "steel_plate", "hardened_steel": "steel_plate",
	"armor_plating": "steel_plate", "slat_armor": "steel_plate",
	"composite_plate": "composite_plate", "spaced_composite": "composite_plate",
	"ceramic_ablative": "ceramic_ablative", "ablative_ceramic": "ceramic_ablative",
	"ablative_foam": "ceramic_ablative",
	"ballistic_nylon": "ballistic_nylon", "carbon_fiber": "ballistic_nylon",
	"reactive_armor": "reactive_armor",
	"energy_shielding": "energy_shielding",
	"titanium_plate": "titanium_plate",
}

# --- Hit damage math (FABLE_REVIEW.md 1.1 / 3.6 / 2.5) ---
# Shared by unit.gd / building.gd so the two take_damage() implementations
# can't drift (same reason resolve() exists). player_vehicle.gd and
# battle_unit.gd were retired 2026-08-10.
#
# CHIP_THROUGH_FACTOR: a hit below the armor threshold is no longer fully
# negated - it deals a small "chip" fraction of its post-reduction damage.
# This is the fix for the review's headline finding: per-shot damage is
# dps*fire_rate, so every rapid-fire weapon (rotary/HMG/CIWS/laser/flamer)
# landed under every real threshold and dealt literally zero damage to any
# armored hull, deleting the whole sustained-fire archetype. At 0.10, armor
# still blanks ~90% of sub-threshold fire (thresholds remain the dominant
# mechanic and heavy alpha still rules head-on), but massed small guns now
# grind - the Damage_And_Armor_Model.md action-economy counter actually
# exists.
const CHIP_THROUGH_FACTOR: float = 0.10
# Brute Force Rule (Damage_And_Armor_Model.md, documented since the start
# but never implemented): an overwhelmingly large hit "punches straight
# through the mitigation multipliers." From BRUTE_FORCE_RATIO x threshold
# upward, the pass_through multiplier blends linearly toward 1.0 (full damage),
# reaching at most BRUTE_FORCE_MAX_BLEND of the way there at 2x that ratio.
const BRUTE_FORCE_RATIO: float = 6.0
const BRUTE_FORCE_MAX_BLEND: float = 0.50
# Subsystem strips deal a fraction of the raw hit instead of the old flat
# `amount - 5.0` (which rounded rapid-fire strip damage to zero and made the
# doc's "swarms strip exposed modules" counter impossible). Modules stay
# threshold-exempt - they're exposed hardware, that's the whole point.
const MODULE_STRIP_DAMAGE_FACTOR: float = 0.75

static func compute_hull_damage(amount: float, threshold: float, pass_through: float, threshold_exempt: bool = false) -> float:
	# DoT ticks (burn) are threshold-exempt, same reasoning as module strips
	# above: a burn tick is an artifact of how often we choose to sample a
	# continuous effect, not a discrete "shot" that a threshold should be able
	# to shrug off entirely. Without this, finer ticking makes DoT weaker
	# (each slice falls further under the threshold) - backwards. pass_through
	# still applies, so armor keeps mattering against fire; only the
	# below-threshold chip-through gate is skipped.
	if threshold_exempt:
		return amount * pass_through
	if threshold > 0.0 and amount < threshold:
		return amount * pass_through * CHIP_THROUGH_FACTOR
	var eff_pass_through = pass_through
	if threshold > 0.0 and amount >= threshold * BRUTE_FORCE_RATIO:
		var brute_t = clamp((amount / threshold - BRUTE_FORCE_RATIO) / BRUTE_FORCE_RATIO, 0.0, 1.0)
		eff_pass_through = lerpf(pass_through, 1.0, brute_t * BRUTE_FORCE_MAX_BLEND)
	return amount * eff_pass_through

static func get_material_threshold(material: String, damage_type: String, thickness: float) -> Vector2:
	var row = ARMOR_TABLE.get(material, ARMOR_TABLE["hardened_steel"])
	var pair = row.get(damage_type, row["explosive"])
	return Vector2(pair[0] * thickness, pair[1])

# Resolves the full threshold/pass_through pair for a hit, from the hull's baseline
# material+thickness plus whatever armor is PAINTED on the facet struck.
#
# `active_modules` is retained for signature compatibility and is no longer read
# for armor. Armor stopped being a placeable module: it is per-facet coverage
# now, carried on the hull as the `armor_plan` meta. See ArmorPaint.
#
# THREE PATHS, in descending order of what we know:
#   1. defender + hit_origin, and the trace recovers the triangle struck ->
#      the EXACT facet's assignment, or bare hull if that facet is unpainted.
#   2. defender + hit_origin, no usable triangle -> the facing side's summary,
#      blended by how much of that side is covered.
#   3. no direction at all (AoE) -> the whole hull's summary, blended by total
#      coverage.
# A hull with no plan resolves as bare metal on every path, which is what
# buildings have always done and still do.
static func resolve(hull: Node3D, active_modules: Array, damage_type: String, defender: Node3D = null, hit_origin = null) -> Vector2:
	var hull_mat = "hardened_steel"
	var hull_thick = 1.0
	if is_instance_valid(hull) and hull.has_meta("armor_material") and hull.has_meta("armor_thickness"):
		hull_mat = hull.get_meta("armor_material")
		hull_thick = hull.get_meta("armor_thickness")
	var baseline = get_material_threshold(hull_mat, damage_type, hull_thick)
	var threshold = baseline.x
	var pass_through = baseline.y

	# PAINTED ARMOR. The plan is built once at reconstruct time and hung on the
	# hull (see ArmorPaint). An absent plan means bare hull, which is exactly
	# what a structure gets - structure.gd calls resolve(null, [], ...) and must
	# keep behaving as it always has.
	var plan: Dictionary = {}
	if is_instance_valid(hull) and hull.has_meta("armor_plan"):
		plan = hull.get_meta("armor_plan")
	var has_plan: bool = not plan.is_empty() and not bool(plan.get("empty", true))

	var origin_vec := Vector3.ZERO
	var has_origin := false
	if hit_origin != null:
		if hit_origin is Vector3:
			origin_vec = hit_origin
			has_origin = true
		elif hit_origin is Node3D and is_instance_valid(hit_origin):
			origin_vec = hit_origin.global_position
			has_origin = true

	if defender != null and has_origin:
		var local_dir = defender.global_transform.basis.inverse() * (origin_vec - defender.global_position)
		var trace := trace_hull(defender, origin_vec)

		if has_plan:
			var assignment: Dictionary = {}
			# EXACT FACET FIRST. The triangle struck resolves to one facet, and
			# that facet is either painted or it is not - no blending, no
			# averaging over a side. This is the whole point of recovering
			# face_index: a hull whose front is 60% covered means a shot into
			# the bare 40% gets NOTHING, rather than everyone on that side
			# receiving 60% of a plate.
			# The tri_map is embedded in the plan at build time from the live
			# segment — no baked sidecar lookup needed at resolve time.
			var tri_map: PackedInt32Array = plan.get("tri_map", PackedInt32Array())
			var face_idx := int(trace.get("face_index", -1))
			var fid := -1
			if face_idx >= 0 and face_idx < tri_map.size():
				fid = tri_map[face_idx]
			if fid >= 0:
				var facets: Dictionary = plan.get("facets", {})
				if facets.has(fid):
					assignment = facets[fid]
				else:
					# Resolved to a real facet that simply is not painted.
					# Bare hull, and deliberately NOT a fall through to the
					# side summary - we know precisely what was hit.
					assignment = {}
				var applied := _apply_assignment(baseline, assignment, damage_type)
				threshold = applied.x
				pass_through = applied.y
			else:
				# No usable triangle: no hull surface body, an unbaked hull, or
				# a shot that never reached the defender. Fall back to the
				# side's area-weighted summary, blended by how much of that side
				# is actually covered.
				var side := ModuleCatalogScript.classify_facet(local_dir)
				var summary: Dictionary = (plan.get("sides", {}) as Dictionary).get(side, {})
				var blended := _blend_side(baseline, summary, damage_type)
				threshold = blended.x
				pass_through = blended.y

		threshold *= float(trace.get("slope", 1.0))
	elif has_plan:
		# AoE and any caller with no direction. One answer for the whole hull,
		# blended by overall coverage - the honest expected value when we cannot
		# say where the blast landed. `mean_thickness` carries the plan's real
		# area-weighted thickness so a heavily-plated hull isn't silently
		# resolved as bare 1.0x armor on the one path with no facet or side to
		# read a thickness off of.
		var whole := {
			"coverage": float(plan.get("coverage", 0.0)),
			"type_id": _dominant_type(plan),
			"material": _dominant_material(plan),
			"mean_thickness": float(plan.get("mean_thickness", 1.0)),
		}
		var blended_all := _blend_side(baseline, whole, damage_type)
		threshold = blended_all.x
		pass_through = blended_all.y

	if defender != null and has_origin:
		var height_advantage = origin_vec.y - defender.global_position.y
		if height_advantage >= ELEVATION_COMBAT_THRESHOLD:
			threshold *= ELEVATION_COMBAT_PIERCE_MULTIPLIER

	return Vector2(threshold, pass_through)

# One painted facet's contribution. Coverage is definitionally 1 here - the
# facet either carries this assignment or it does not.
#
# The material REPLACES the hull baseline rather than stacking with it, which is
# what the original per-plate branch always intended ("a plate can be reactive
# on the front and ablative on the sides"): the attack strikes the plate, not
# the bare hull beneath it. That branch was unreachable for as long as armor was
# a module, because nothing ever wrote a per-plate material. Painting does.
static func _apply_assignment(baseline: Vector2, a: Dictionary, damage_type: String) -> Vector2:
	if a.is_empty():
		return baseline
	var material := str(a.get("material", ""))
	if material == "":
		return baseline
	# The armor TYPE (plating/slat/composite/foam) is purely cosmetic - the
	# painted likeness on the skin. Threshold and pass_through come from the
	# MATERIAL and its THICKNESS alone; the old per-type catalog-HP bonus and
	# rock-paper-scissors bias multipliers were retired with the type rows.
	var plate := get_material_threshold(material, damage_type, float(a.get("thickness", 1.0)))
	return plate


# Partial coverage, blended linearly on both channels.
#
# Exact at both ends - 0% painted is the bare hull, 100% is the full plate - and
# the middle is the honest expected value of "a random shot at this side has
# `coverage` chance of meeting armor". Needs no tuning constant, which is why it
# is a lerp rather than a curve. Only ever used when the exact facet could not
# be recovered; the precise path never blends.
static func _blend_side(baseline: Vector2, summary: Dictionary, damage_type: String) -> Vector2:
	var coverage := clampf(float(summary.get("coverage", 0.0)), 0.0, 1.0)
	if coverage <= 0.0:
		return baseline
	var material := str(summary.get("material", ""))
	if material == "":
		return baseline
	var plated := _apply_assignment(baseline, {
		"material": material,
		"type_id": str(summary.get("type_id", "")),
		"thickness": summary.get("mean_thickness", 1.0),
	}, damage_type)
	return Vector2(
		lerpf(baseline.x, plated.x, coverage),
		lerpf(baseline.y, plated.y, coverage))


static func _dominant_type(plan: Dictionary) -> String:
	return _dominant_field(plan, "type_id")


static func _dominant_material(plan: Dictionary) -> String:
	return _dominant_field(plan, "material")


static func _dominant_field(plan: Dictionary, key: String) -> String:
	var by_area := {}
	for fid in (plan.get("facets", {}) as Dictionary).keys():
		var a: Dictionary = plan["facets"][fid]
		var k := str(a.get(key, ""))
		by_area[k] = float(by_area.get(k, 0.0)) + float(a.get("area", 0.0))
	var best := ""
	var best_a := 0.0
	for k in by_area.keys():
		if float(by_area[k]) > best_a:
			best_a = float(by_area[k])
			best = str(k)
	return best


# Real raycast from the attacker to the defender's hull, reading the actual
# surface normal at impact - not an analytical shortcut off the facet's
# canonical axis. Effective thickness = base / cos(angle), the standard
# sloped-armor formula; clamped so a razor-thin grazing angle doesn't produce
# an absurd multiplier.
#
# THE MASK WAS WRONG IN BATTLE and this function was inert there. It asked for
# layer 1 alone, which is the DESIGN LAB's hull (a real StaticBody3D on layer 1,
# so the Lab and the headless tests worked) but in a match is TERRAIN: a spawned
# unit's body is on UNITS (4), its running gear on 0, and nothing it owns is on
# layer 1 at all. So every shot in every skirmish either hit the ground on the
# way over and read the ground's normal, or hit nothing and fell through to 1.0.
# Sloped armour has never actually applied in a battle.
#
# Both layers are masked now, plus BattleLayers.HULL_SURFACE - the precise
# trimesh skin blueprint_manager builds on the battle path. This function's
# previous note said it "starts reflecting true sloped surfaces automatically
# the moment hull collision becomes mesh-accurate"; that is now true, because
# the thing being traced is the visible mesh rather than a bounding box.
#
# The hit is REQUIRED to belong to the defender. Masking terrain is what makes
# the Lab case work, and without an ownership check a ridge between attacker and
# target would hand back the ridge's normal as if it were armour slope. A shot
# that never reaches the defender gets the neutral 1.0, which is the right
# conservative answer.
const SLOPE_TRACE_MASK := 1 | BattleLayersScript.HULL_SURFACE

static func compute_slope_multiplier(defender: Node3D, hit_origin: Vector3) -> float:
	return float(trace_hull(defender, hit_origin).get("slope", 1.0))


# ONE trace, TWO answers: the slope multiplier and the index of the triangle
# actually struck.
#
# This exists because the facet a shot lands on was previously unknowable and is
# now free. The ray was already being fired for slope and its result discarded
# except for the normal; `face_index` on that same result names the triangle,
# and HullFacets' baked map turns a triangle into a facet. Measured on the
# shipped roster (tools/probe_face_index.gd): 960 rays, zero missing indices,
# worst off-plane error 0.0000 - face_index indexes Mesh.get_faces() order
# exactly, which is the order the facet map is baked against.
#
# THE SECOND QUERY IS NOT REDUNDANT. `face_index` is -1 unless the shape struck
# is a ConcavePolygonShape3D. SLOPE_TRACE_MASK includes layer 1, which in the
# Design Lab is the hull's BOX collider - it sits outside the mesh skin and is
# therefore hit first, so a single masked query returns -1 on exactly the path
# the tests exercise. When that happens we re-query against HULL_SURFACE alone.
# The slope then comes from the concave hit too, which is a straight
# improvement: the box's axis-aligned normal was never the real surface angle.
static func trace_hull(defender: Node3D, hit_origin: Vector3) -> Dictionary:
	var out := {"slope": 1.0, "face_index": -1, "hit": false}
	if not is_instance_valid(defender):
		return out
	var world = defender.get_world_3d()
	if not world:
		return out
	var space_state = world.direct_space_state
	var target_point = defender.global_position + Vector3(0, 0.1, 0)

	var result = _trace_masked(space_state, hit_origin, target_point, SLOPE_TRACE_MASK, defender)
	if result.is_empty():
		return out
	if int(result.get("face_index", -1)) < 0:
		var precise = _trace_masked(space_state, hit_origin, target_point,
			BattleLayersScript.HULL_SURFACE, defender)
		if not precise.is_empty() and int(precise.get("face_index", -1)) >= 0:
			result = precise

	if not result.has("normal"):
		return out
	var incoming_dir = (target_point - hit_origin).normalized()
	var hit_normal = result.normal as Vector3
	var cos_angle = clamp(abs(hit_normal.dot(-incoming_dir)), 0.15, 1.0)
	out["slope"] = 1.0 / cos_angle
	out["face_index"] = int(result.get("face_index", -1))
	out["hit"] = true
	return out


static func _trace_masked(space_state, from: Vector3, to: Vector3, mask: int,
		defender: Node3D) -> Dictionary:
	var query = PhysicsRayQueryParameters3D.create(from, to)
	query.collision_mask = mask
	var result = space_state.intersect_ray(query)
	if result.is_empty():
		return {}
	if not _hit_belongs_to(result.get("collider"), defender):
		return {}
	return result


# Is `collider` the defender, or something the defender owns?
#
# `defender` is the CharacterBody3D in battle and the hull StaticBody3D in the
# Lab, and the thing the ray hits is a HullSurface body nested under the former
# or the hull body itself in the latter - so this walks up rather than comparing
# identity. Cheap: the tree between a hull surface and its unit is two nodes.
static func _hit_belongs_to(collider, defender: Node3D) -> bool:
	if collider == null or not is_instance_valid(defender):
		return false
	if not (collider is Node):
		return false
	var walker: Node = collider
	while walker != null:
		if walker == defender:
			return true
		walker = walker.get_parent()
	return false
