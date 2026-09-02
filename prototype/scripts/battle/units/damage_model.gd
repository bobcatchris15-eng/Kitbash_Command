class_name DamageModel
extends RefCounted
# How a hit becomes HP loss. Shared by units and structures.
#
# WHY THIS IS NOT A METHOD ON THE UNIT. In the old runtime this was 110 lines in
# the middle of battle_unit.gd's take_damage(), interleaved with smoke reflexes,
# shield flashes, HP bar updates and audio. Structures needed the same armour
# rules, so building.gd grew its own partial copy, and the two drifted. Pulling
# the RULES out - facet classification, strip eligibility, the strip roll, the
# final hull number - leaves each caller with only its own presentation.
#
# WHAT IS DELIBERATELY NOT HERE. The math that was already shared stays where it
# is: damage_resolver.gd owns ARMOR_TABLE, the threshold/chip/brute-force curve
# and MODULE_STRIP_DAMAGE_FACTOR. This file decides WHICH module a hit is allowed
# to strip and WHETHER it strips, and delegates every number to the resolver.
# Reimplementing that math here is exactly how the old copies diverged.
#
# Everything is static and takes what it needs explicitly, so the rules can be
# tested without building a unit, a hull or a physics world.

const DamageResolverScript = preload("res://scripts/damage_resolver.gd")
const ModuleCatalog = preload("res://scripts/module_catalog.gd")

# Share of hits that land on an exposed module rather than the hull proper.
const MODULE_STRIP_CHANCE := 0.35


# Live module nodes under a hull. Queued-for-deletion children are excluded: a
# module destroyed earlier this frame is still a child until the tree flushes,
# and counting it would let a dead sensor keep soaking hits.
static func active_modules(hull_node: Node3D) -> Array:
	var list: Array = []
	if not is_instance_valid(hull_node):
		return list
	for child in hull_node.get_children():
		if child.has_meta("module_data") and not child.is_queued_for_deletion():
			list.append(child)
	return list


# Which face of the target the shot came from, as a ModuleCatalog facet name, or
# "" when the caller could not say where the hit came from.
#
# The empty string is meaningful and is not an error - a direct take_damage()
# call from a test, a script, or anything that never had an origin to give. See
# strippable() for what it deliberately does with it.
static func hit_facet(body: Node3D, hit_origin) -> String:
	if hit_origin == null or not is_instance_valid(body):
		return ""
	var origin: Vector3 = hit_origin if hit_origin is Vector3 else hit_origin.global_position
	var local_dir: Vector3 = body.global_transform.basis.inverse() * (origin - body.global_position)
	return ModuleCatalog.classify_facet(local_dir)


# The modules a hit from `facet` is allowed to strip.
#
# TWO RULES, BOTH LOAD-BEARING.
#
# Armour is never strippable. Armour already gets facet-aware treatment inside
# DamageResolver.resolve(); letting it also be picked as a strip target would
# make it absorb the hit twice by two different mechanisms.
#
# A module must be on the facet that was hit. Without this a howitzer shell can
# "whiff" a third of its damage into a wheel on the far side of the tank while
# the hull takes nothing, which reads to the player as a phantom miss rather than
# as the deliberate shoot-the-treads counterplay it is meant to be.
#
# When `facet` is "" the facet rule is skipped and every non-armour module is
# eligible. That keeps a caller with no hit origin from silently losing stripping
# altogether, which is a much quieter and worse failure than over-permitting it.
static func strippable(modules: Array, facet: String) -> Array:
	var out: Array = []
	for m in modules:
		var data = m.get_meta("module_data")
		if data == null or data.category == "armor":
			continue
		if facet != "" and ModuleCatalog.classify_facet(m.position) != facet:
			continue
		out.append(m)
	return out


# The modules a shot actually passes through, found by tracing the shot line
# against the per-module hit volumes blueprint_manager builds on
# BattleLayers.UNIT_MODULES - volumes that match each module's visible meshes
# (module_volume.gd) rather than a catalog box.
#
# WHY THIS IS NOT JUST strippable(). That one filters by FACET: every module
# classified onto the face the shot came from is an equally likely victim, so a
# shot at the front of a tank was as likely to take a roof sensor at the back of
# the front half as the mantlet it visibly struck. Tracing answers the question
# the facet test was approximating.
#
# THE RNG CONTRACT IS UNCHANGED, and that is deliberate. unit.gd draws exactly
# one randf() (does this hit strip?) and one randi() (which module?), and
# SimRNG.pick() draws its randi() regardless of how long the array is - so
# narrowing the candidate list changes WHICH module is taken without moving the
# stream one step. Replays and the seeded-match tests stay valid.
#
# Falls back to strippable() whenever tracing cannot answer: no origin, no
# physics world (every headless test that calls take_damage() directly), or a
# ray that reaches the hull without crossing any of this unit's modules.
const _TRACE_STEPS := 4

static func strippable_along_shot(body: Node3D, hull_node: Node3D, modules: Array,
		hit_origin, facet: String) -> Array:
	var fallback := strippable(modules, facet)
	if hit_origin == null or not is_instance_valid(body) or fallback.is_empty():
		return fallback
	var world := body.get_world_3d()
	if world == null:
		return fallback
	var space := world.direct_space_state
	if space == null:
		return fallback

	var from: Vector3 = hit_origin if hit_origin is Vector3 else hit_origin.global_position
	# Aimed at the HULL's centre, not body.global_position - a ground unit's
	# origin is its ground contact point, so a ray to it passes underneath
	# everything mounted on the deck.
	var to: Vector3 = hull_node.global_position if is_instance_valid(hull_node) \
		else body.global_position + Vector3(0, 0.5, 0)
	if from.is_equal_approx(to):
		return fallback

	# Membership is tested against every non-armour module, NOT against the
	# facet-filtered fallback. The facet filter is an approximation of "which
	# side did this come from"; the trace is the real answer, so constraining it
	# to the approximation's verdict would throw away the improvement - a shot
	# that visibly passes through a module classified onto a neighbouring facet
	# still hit that module.
	var own := strippable(modules, "")
	var exclude: Array = []
	for _step in range(_TRACE_STEPS):
		var query := PhysicsRayQueryParameters3D.create(from, to)
		query.collision_mask = BattleLayers.UNIT_MODULES
		# The hit volumes are Area3Ds (blueprint_manager builds them that way so
		# they can ride a moving unit without lying to the physics server about
		# being static), and a ray ignores areas unless asked.
		query.collide_with_areas = true
		query.exclude = exclude
		var hit := space.intersect_ray(query)
		if hit.is_empty():
			break
		var collider = hit.get("collider")
		if collider == null:
			break
		exclude.append(collider.get_rid())
		var module = collider.get_parent()
		# Not one of OUR modules - some other unit's gun between us and the
		# target. Keep going rather than giving up: it is in the way of the
		# trace, not of the shot (units do not block fire, see auto_weapon).
		if module == null or not (module in own):
			continue
		return [module]
	return fallback


# Apply `amount` to one module and report whether it died. Damage is a FRACTION
# of the raw hit (the resolver's MODULE_STRIP_DAMAGE_FACTOR), not the old flat
# `amount - 5.0`, which rounded every rapid-fire weapon's strip damage to zero
# and quietly made small sustained guns the one archetype that could not strip.
static func damage_module(module: Node3D, amount: float) -> bool:
	var data = module.get_meta("module_data")
	var module_hp: float = module.get_meta("current_hp") if module.has_meta("current_hp") else data.get_hp()
	module_hp = maxf(0.0, module_hp - amount * DamageResolverScript.MODULE_STRIP_DAMAGE_FACTOR)
	module.set_meta("current_hp", module_hp)
	return module_hp <= 0.0


# Threshold and pass_through for a hit of `damage_type` against this hull,
# straight from the resolver so armour materials, facets and elevation stay in
# one place.
static func resolve(hull_node: Node3D, modules: Array, damage_type: String,
		body: Node3D, hit_origin) -> Vector2:
	return DamageResolverScript.resolve(hull_node, modules, damage_type, body, hit_origin)


# What actually comes off the HP pool, after chip-through and brute-force.
static func hull_damage(amount: float, threshold: float, pass_through: float, threshold_exempt: bool = false) -> float:
	return DamageResolverScript.compute_hull_damage(amount, threshold, pass_through, threshold_exempt)
