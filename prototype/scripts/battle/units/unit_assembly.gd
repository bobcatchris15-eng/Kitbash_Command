class_name UnitAssembly
extends RefCounted
# Turns a blueprint into a physical body. Geometry, colliders, HP, nav agent -
# no behaviour.
#
# WHY THIS IS SPLIT OUT AT ALL. In the old runtime this was the first 130 lines
# of battle_unit.gd's setup(), directly above the harvester detection, the
# auto-engage timers and the order enum. Assembly and behaviour sharing one
# function is why battle_unit.gd reached 1,701 lines and why there was no way to
# build a unit for a test without also getting its AI.
#
# WHY IT IS A COPY RATHER THAN AN EXTRACTION. battle_unit.gd still ran the old
# Skirmish scene when unit_assembly was first split out. Extracting would have
# meant editing a file behind ~120 passing suites for the benefit of code that
# did not ship yet, so the duplication was deliberate. battle_unit.gd and its
# Skirmish scene were retired on 2026-08-10 in the unification's Phase 4;
# the duplication ended then. unit.gd calls into unit_assembly directly and
# there is no parallel hand-copy to maintain.
#
# The physics values, the convex-hull rationale and the running-gear collider are
# carried over as-is - they encode real bugs that were found the hard way (a
# collider a full ride-height below its own hull, shots passing through visible
# geometry). What is NEW here is the selection proxy.

const ModuleCatalog = preload("res://scripts/module_catalog.gd")
const MeshAssetLoader = preload("res://scripts/mesh_asset_loader.gd")
const PowerBudgetScript = preload("res://scripts/power_budget.gd")
const MatchDirectorScript = preload("res://scripts/battle/match_director.gd")
# BattleLayers declares class_name, so it resolves globally with no preload here.

# How much bigger the collider gets per point of armour thickness. Armour is
# modelled as bulk on the X/Y faces only - a thicker tank is wider and taller,
# not longer, because the plate goes on the glacis and the flanks.
const ARMOR_BULK_PER_THICKNESS := 0.15


# Populates `body` from `blueprint_data` and returns the derived facts the
# behaviour layer needs. Returns an empty dictionary if the blueprint could not
# be reconstructed, which the caller must treat as "do not spawn this unit" -
# reconstruct_vehicle() returns null for a blueprint naming a hull that no longer
# exists in the catalog, and a half-built unit is worse than none.
# ONE ASSEMBLED HULL PER DESIGN, DUPLICATED THEREAFTER.
#
# MEASURED: reconstruct_vehicle() is the entire cost of spawning a unit -
# spawn_unit totalled 1069.94ms mean per call, of which spawn.assemble was
# 1046.90ms, against 2.94ms for weapons and 0.07ms for the nav agent. Every unit
# that rolls out of a factory rebuilds its hull from the blueprint, and the
# blueprint version note in CLAUDE.md says why that is so expensive: the hulls
# are SDF/marching-cubes geometry, generated rather than loaded.
#
# A player who queues four tanks therefore pays four multi-second stalls, and
# they land when reinforcements ARRIVE - which is why the hitches looked like
# they belonged to combat.
#
# WHAT MAKES THE DUPLICATE SAFE. The assembly code downstream reads the hull
# through metadata (type_id, armor_thickness, armor_material, hull_scale,
# faction, base_hull_size) and attach_weapons() reads module_data off each child,
# so metadata surviving duplication is a correctness requirement, not a detail -
# probe_spawn_cache.gd asserts a duplicated hull carries the identical metadata
# and the same weapon count as a freshly built one.
#
# MATERIALS ARE SHARED between duplicates, deliberately. battle_finish.gd states
# absolute targets (a floor and a ceiling) rather than applying a delta, so
# applying it repeatedly to the same shared material is idempotent - and sharing
# gives the renderer fewer distinct materials, which is the direction the ~31
# draw calls per unit needs to move anyway.
#
# The cache is keyed on the blueprint's full content plus the faction, so two
# designs that differ by one module or one armour value do not collide, and a
# design edited between matches does not serve a stale hull.
static var _hull_cache: Dictionary = {}


# Dropped between matches. The templates are detached nodes owned by this
# dictionary, so without this they would outlive the match that built them and,
# worse, a design re-saved in the Lab would keep serving its old geometry.
static func clear_hull_cache() -> void:
	for template in _hull_cache.values():
		if is_instance_valid(template):
			template.free()
	_hull_cache.clear()


static func _acquire_hull(blueprint_data: Dictionary, body: Node3D,
		bp_manager: Node, match_faction: String) -> Node3D:
	var key := "%s|%s" % [JSON.stringify(blueprint_data), match_faction]
	var template = _hull_cache.get(key)
	if template == null or not is_instance_valid(template):
		# Built into a detached holder rather than into `body`, so the template is
		# never part of a live unit and cannot be freed when that unit dies.
		var holder := Node3D.new()
		var built: Node3D = bp_manager.reconstruct_vehicle(
			blueprint_data, holder, false, match_faction)
		if built == null:
			holder.free()
			return null
		holder.remove_child(built)
		holder.free()
		_hull_cache[key] = built
		template = built

	var copy: Node3D = template.duplicate()
	# duplicate() copies metadata, so the proxy's "unit" meta now points to
	# the TEMPLATE's body (the first one that populated the cache), not the
	# live `body` we just built. Fix it: the proxy's meta must reference the
	# actual spawned unit so team checks and selection work correctly.
	var proxy: Node3D = copy.find_child("SelectionProxy", false, false)
	if proxy != null and proxy.has_meta("unit"):
		proxy.set_meta("unit", body)
	body.add_child(copy)
	return copy


static func build(body: CharacterBody3D, blueprint_data: Dictionary, team: int,
		bp_manager: Node, match_faction: String = "") -> Dictionary:
	body.set_meta("team", team)
	body.collision_layer = BattleLayers.UNITS
	# Terrain and buildings, but NOT other units: units pass through each other
	# and are kept apart by steering separation instead, because solid unit-unit
	# collision on a CharacterBody3D turns any dense group into a shoving match.
	# Colliding with buildings is a BACKSTOP for a navmesh miss (a unit already
	# mid-path when a building goes up), not the primary avoidance.
	body.collision_mask = BattleLayers.TERRAIN | BattleLayers.BUILDINGS

	var locomotion: Dictionary = blueprint_data.get("locomotion", {})
	var locomotion_type: String = locomotion.get("type_id", "")
	var locomotion_settings: Dictionary = locomotion.get("settings", {})

	# Movement paradigm comes from the TRAIT system, not from matching type_id
	# strings, so a hull/locomotion combination added later picks up the right
	# behaviour without this function learning its name.
	var hull_type_hint: String = blueprint_data.get("hull_type", "brenntal_medium_a")
	var traits: Array = ModuleCatalog.get_traits(hull_type_hint, locomotion_type)

	var hull_node: Node3D = _acquire_hull(blueprint_data, body, bp_manager, match_faction)
	if not hull_node:
		return {}

	var hull_type: String = hull_node.get_meta("type_id") if hull_node.has_meta("type_id") else "brenntal_medium_a"
	var catalog_data: Dictionary = ModuleCatalog.get_module_data(hull_type)
	var thickness: float = hull_node.get_meta("armor_thickness") if hull_node.has_meta("armor_thickness") else 1.0
	var material: String = hull_node.get_meta("armor_material") if hull_node.has_meta("armor_material") else "hardened_steel"
	var hull_scale: Vector3 = hull_node.get_meta("hull_scale") if hull_node.has_meta("hull_scale") else Vector3.ONE
	var faction: String = hull_node.get_meta("faction") if hull_node.has_meta("faction") else "industrialists"

	# One shared HP function across combat, defences and the Design Lab sidebar,
	# so the number the player sizes a hull against is the number it fights with.
	var max_hp: float = ModuleCatalog.compute_hull_max_hp(hull_type, thickness, material, hull_scale)

	# base_hull_size is the FITTED AABB (set in _place_hull_from_ui /
	# update_hull_appearance / reconstruct_vehicle) - the actual mesh
	# footprint, not the catalog box. Reading it here keeps the
	# selection-proxy / running-gear / hull collider in sync with the
	# Design Lab's view of the same design; the catalog fallback only
	# fires when the hull arrived without a base_hull_size meta, which is
	# a "no hull loaded" safety-net case, and the reference anchor is the
	# right size to fall back to.
	var base_size: Vector3 = Vector3(ModuleCatalog.REFERENCE_HULL_SIZE)
	if hull_node.has_meta("base_hull_size") and hull_node.has_meta("hull_scale"):
		base_size = hull_node.get_meta("base_hull_size") * hull_node.get_meta("hull_scale")
	var bulk := Vector3(
		1.0 + (thickness - 1.0) * ARMOR_BULK_PER_THICKNESS,
		1.0 + (thickness - 1.0) * ARMOR_BULK_PER_THICKNESS,
		1.0)

	_add_hull_collider(body, hull_node, hull_type, base_size, hull_scale, bulk)
	if ModuleCatalog.needs_running_gear(locomotion_type):
		_add_running_gear_collider(body, hull_node, base_size, bulk)
	_add_selection_proxy(body, hull_node, base_size, bulk)
	_apply_team_visuals(body, hull_node, team, {})

	return {
		"hull_node": hull_node,
		"hull_type": hull_type,
		"locomotion_type": locomotion_type,
		"locomotion_settings": locomotion_settings,
		"traits": traits,
		"is_flying": "airborne" in traits,
		"is_fixed_wing": "fixed_wing" in traits,
		"is_naval": "naval" in traits,
		"is_amphibious": "amphibious" in traits,
		# A hovercraft rides on a cushion of air; there is nothing about water
		# it cares about. Only hovercraft_skirt carried BOTH "hovering" and
		# "amphibious", so hover_engine, grav_plates and the rest were being
		# routed onto the GROUND navmesh and treated a lake as a wall.
		"is_hovering": "hovering" in traits,
		"hull_draught": ModuleCatalog.get_hull_draught(hull_type_hint),
		"base_size": base_size,
		"max_hp": max_hp,
		"armor_material": material,
		"armor_thickness": thickness,
		"faction": faction,
	}


# The body collider. Godot only allows ConcavePolygonShape3D on a StaticBody3D,
# so a trimesh is not a legal shape on a CharacterBody3D at all - the shape of a
# MOVING hull has to be convex. Three tiers, best first:
#
#   1. The BAKED DECOMPOSITION (assets/models/hulls/<id>_collision.res), a set
#      of convex pieces in a CompoundShape3D. The pieces keep the hull's
#      concavities; the compound means one CollisionShape3D node on the
#      CharacterBody3D regardless of piece count. This used to be impossible:
#      convex decomposition hung on these meshes - it never returned on the
#      smallest hull in the roster at max_convex_hulls as low as 4 - because
#      sdf_mesh_baker emits unwelded triangle soup and the decomposer had no
#      vertex adjacency to work from. mesh_weld.gd fixed the input and
#      tools/bake_hull_roster.gd now does the work at tool time, so a spawn
#      pays only for mounting the shapes.
#   2. A SINGLE CONVEX FIT of the authored mesh, for any hull not yet re-baked.
#      This is what shipped before and it is still correct, just coarse: deck
#      wells, the gap under a tapered keel and the space between sponsons all
#      collide as solid.
#   3. A BOX, when there is no authored mesh at all.
#
# The selection proxy below still does NOT reuse this, and the decomposition
# does not change that: a hit volume that follows the silhouette into every
# recess is exactly the wrong thing to click on. See its own header.
static func _add_hull_collider(body: CharacterBody3D, hull_node: Node3D, hull_type: String,
		base_size: Vector3, hull_scale: Vector3, bulk: Vector3) -> void:
	var authored := MeshAssetLoader.get_hull_mesh(hull_type)

	# WHAT THIS REPLACES, AND WHY.
	# Old: MeshAssetLoader.get_hull_collision() loaded a baked convex
	# decomposition (.res file) and created one CollisionShape3D per piece.
	# Godot's broadphase generates one collision pair PER SHAPE per interacting
	# body, so 11 pieces × N enemies = 11N broadphase pairs. At 16 units that's
	# 176 piece-vs-world pairs before terrain or buildings. The physics kernel
	# probe confirmed that Godot's collision detection is the bottleneck
	# (~11.9ms of the 16.67ms 60Hz budget with zero GDScript activity).
	#
	# New: a single convex fit of the authored hull mesh. This is coarser than
	# the decomposition — deck wells and sponsons collide as solid — but it is
	# ONE shape on the CharacterBody3D. Broadphase pairs drop from 11N to N.
	# CompoundShape3D (the correct solution) has no GDScript constructor and
	# PhysicsServer3D's shape-building API is not exposed to GDScript, so a C++
	# extension would be needed to get proper multi-piece compound collision
	# without the coarse-fit tradeoff.
	var col := CollisionShape3D.new()
	col.name = "HullCollider"
	if authored:
		col.shape = authored.create_convex_shape()
		col.scale = hull_scale * bulk
		col.position = hull_node.position
	else:
		var box := BoxShape3D.new()
		box.size = base_size * bulk
		col.shape = box
		# Centred on where the hull VISUAL sits, not on half its own height.
		# Those agree only for a design with no ground locomotion; the moment
		# reconstruct_vehicle() lifts the hull to put running gear on the floor,
		# half-height leaves the collider a full ride-height BELOW the hull it
		# represents, and shots pass through the visible model into empty air.
		col.position = Vector3(0, hull_node.position.y, 0)
	body.add_child(col)


# A second box spanning the wheels/treads/legs the hull was just lifted clear of.
# Without it the CharacterBody3D has nothing to rest on and the unit slides along
# on its belly, because the hull collider's bottom sits at ride height.
static func _add_running_gear_collider(body: CharacterBody3D, hull_node: Node3D,
		base_size: Vector3, bulk: Vector3) -> void:
	var gear_size: Vector3 = ModuleCatalog.get_running_gear_size(base_size * bulk)
	var col := CollisionShape3D.new()
	col.name = "RunningGearCollider"
	var box := BoxShape3D.new()
	box.size = gear_size
	col.shape = box
	col.position = Vector3(
		0,
		hull_node.position.y - (base_size.y * bulk.y) / 2.0 - gear_size.y / 2.0,
		0)
	body.add_child(col)


# THE SELECTION PROXY - the one genuinely new piece of assembly.
#
# An Area3D carrying an axis-aligned box sized from the HULL, on its own physics
# layer, monitoring nothing. It exists only to be hit by SelectionService's
# frustum query and by click-picking.
#
# Three reasons it is not the body collider:
#
#   1. SHAPE. The body collider is a convex fit that swallows concavities and
#      stretches to whatever the silhouette's extremes are. Players aim at the
#      chassis, so the proxy is the chassis.
#   2. PREDICTABILITY. Two designs on the same hull select the same way
#      regardless of what is bolted to them. A drag-box that catches one tank and
#      misses its neighbour because the neighbour mounts a longer barrel is a bug
#      report waiting to happen.
#   3. SEPARATION. The frustum query can mask to exactly this layer and get one
#      hit per unit. Querying the units layer would also return module bodies and
#      hulls and force the caller to walk up parents and dedupe.
#
# Sized WITHOUT the armour bulk multiplier: bulk models plate thickness, and a
# heavily armoured tank should not be easier to click than a bare one.
static func _add_selection_proxy(body: CharacterBody3D, hull_node: Node3D,
		base_size: Vector3, _bulk: Vector3) -> void:
	var area := Area3D.new()
	area.name = "SelectionProxy"
	area.collision_layer = BattleLayers.SELECTION
	area.collision_mask = 0
	# Nothing about this volume needs to react to anything entering it. Leaving
	# monitoring on would have the physics server track overlaps for every unit
	# on the field to feed signals nobody connects.
	area.monitoring = false
	area.monitorable = true
	# The owning unit, so the query result can get from a shape hit straight back
	# to the unit without walking the tree and guessing how deep it is.
	area.set_meta("unit", body)

	var col := CollisionShape3D.new()
	var box := BoxShape3D.new()
	# A floor on each axis: a scout hull scaled right down is still something the
	# player has to be able to hit at full zoom-out.
	box.size = Vector3(
		maxf(base_size.x, 1.5),
		maxf(base_size.y, 1.5),
		maxf(base_size.z, 1.5))
	col.shape = box
	col.position = Vector3(0, hull_node.position.y, 0)
	area.add_child(col)
	body.add_child(area)


# --- Weapons -----------------------------------------------------------------
#
# WEAPONS ARE ATTACHED BY SCRIPT SWAP, not by instancing a scene. Every module a
# blueprint mounts is already a real node under the hull, positioned, scaled and
# carrying its ModuleData - reconstruct_vehicle() built it. A weapon is that same
# node with behaviour bolted on, so the only thing missing is the script.
#
# `_ready()` is called by hand because set_script() on a node already in the tree
# does not re-run it, and auto_weapon.gd does all of its setup there - reading its
# own module_data, facet and sponson metas, and its mount's faction.
#
# WHICH MODULES QUALIFY is ModuleCatalog.needs_combat_script()'s call and nothing
# else's. It is the single source of truth precisely because three spawn paths
# used to decide this independently, and repair_array and drone_carrier - which
# are not category "weapon" - got missed by all of them in real matches while
# passing in tests that attached the script by hand.
#
# Returns the longest reach mounted, which is what an ATTACK order closes to.
# MAIN WEAPON. The single module type the unit carries that outputs
# the most total DPS, summed across every mount of that type. A unit
# with 2x basic_cannon (80 DPS total) and 1x gauss_railgun (70 DPS
# single, 70 DPS total) has main weapon = basic_cannon: 80 > 70, so
# the unit closes to the cannon's range, not the gauss's. The user
# spec is "the single module type it carries that outputs the most
# DPS in total" - "in total" is the key word, this is argmax over
# types not argmax over individual mounts.
#
# Returns a Dictionary { type_id, total_dps, range, count } for the
# top type, or an empty Dictionary if the unit has no weapons (which
# harvesters and scouts can be).
#
# Ties broken by fire_range (lower first) so a unit with two weapon
# types at the same total DPS picks the closer one, which is the
# intuitive choice for "main weapon". A deterministic seed is not
# needed - the iteration order over a Dictionary in GDScript is
# insertion order in Godot 4.x, and two types at the exact same
# total DPS do not naturally arise in the bundled module catalog.
#
# Walks the same children that attach_weapons() walks and reads the
# same `module_data` meta, so a "this module does not get a weapon
# script" filter on one side is a filter on the other.
static func compute_main_weapon(hull_node: Node3D) -> Dictionary:
	if not is_instance_valid(hull_node):
		return {}
	# Group mounts by type, summing DPS. The per-mount DPS comes from
	# the module catalog's "dps" field on the type's data dictionary.
	var by_type: Dictionary = {}
	for child in hull_node.get_children():
		if not child.has_meta("module_data"):
			continue
		# data is a ModuleData Resource (set by visual_builder.gd:582 and
		# module_placer.gd:1087), not a Dictionary. Resource has typed
	# property access (data.type_id, data.get_dps()) - its `get()` only
	# takes a property name, not a key+default pair. Fields not on
	# the Resource (fire_range is catalog-only) come from the
	# module catalog via ModuleCatalog.get_module_data().
		var data = child.get_meta("module_data")
		if data == null or not ModuleCatalog.needs_combat_script(data.type_id):
			continue
		var type_id: String = data.type_id
		# get_dps() is the volume-scaled runtime DPS (base_dps * volume
	# factor * tweak multiplies). It is what the weapon actually
	# produces, which is what the user spec asks for - "the most
	# DPS in total". For a unit with 2x twin-linked cannon, the
	# tweaks are already baked into each module's get_dps() value, so
	# the per-type total is the right number.
		var dps: float = float(data.get_dps())
		# fire_range is on the catalog (module_catalog.gd's
	# WEAPON_FIRE_PROFILES dict), not on the Resource. The weapon
	# child carries the runtime value (auto_weapon.gd:31) but the
	# child might be a non-weapon module (sensor/generator) which
	# has no fire_range. The catalog is the safe source for all
	# module types; non-weapons default to 0.0 which we treat as
	# "not a weapon" downstream.
		var fire_range: float = float(child.fire_range) if ("fire_range" in child and float(child.fire_range) > 0.0) else float(ModuleCatalog.get_module_data(type_id).get("fire_range", 0.0))
		if not by_type.has(type_id):
			by_type[type_id] = {"type_id": type_id, "count": 0, "dps_per": dps, "range": fire_range}
		by_type[type_id]["count"] += 1
	# Pick the type with the highest TOTAL DPS. Ties broken by range
	# (lower first) so a unit with two equal-DPS types picks the
	# closer main weapon, which is the intuitive "main" choice.
	var best: Dictionary = {}
	for type_id in by_type:
		var entry: Dictionary = by_type[type_id]
		var total_dps: float = float(entry["dps_per"]) * int(entry["count"])
		var best_dps: float = float(best.get("total_dps", -1.0))
		if best.is_empty() or total_dps > best_dps or (is_equal_approx(total_dps, best_dps) and float(entry["range"]) < float(best.get("range", 0.0))):
			best = {"type_id": type_id, "total_dps": total_dps, "range": float(entry["range"]), "count": int(entry["count"])}
	return best


static func attach_weapons(hull_node: Node3D) -> float:
	if not is_instance_valid(hull_node):
		return 0.0
	var weapon_script := load("res://scripts/auto_weapon.gd")
	var longest := 0.0
	for child in hull_node.get_children():
		if not child.has_meta("module_data"):
			continue
		var data = child.get_meta("module_data")
		if data == null or not ModuleCatalog.needs_combat_script(data.type_id):
			continue
		child.set_script(weapon_script)
		child.set_physics_process(true)
		child._ready()
		if "fire_range" in child:
			longest = maxf(longest, child.fire_range)
	return longest


# --- Energy ------------------------------------------------------------------
#
# Hull base capacity plus whatever generators are mounted, in the same "hull base
# + module bonus" shape vision and HP already use. Recomputed rather than stored,
# so losing a generator mid-battle shrinks the pool.
#
# Returns {max_energy, energy_regen_rate, power}.
#
# Delegates to PowerBudget.analyze() rather than summing here. It used to do the
# sum itself and derive the refill rate as `capacity * 0.08 + regen`, which is
# the conflation the power split exists to end: storage manufactured generation,
# so no design could hold a big buffer and trickle, or hold a small one and
# refill fast.
#
# energy_regen_rate is now NET - generation minus continuous draw - so a design
# that draws more than it makes has a negative rate and genuinely empties. That
# is what makes electronics cost something, and it is the whole mechanism behind
# the brownout in unit.gd. The old formula could not go negative, because there
# was nothing in it to subtract.
#
# The keys are unchanged so every existing caller keeps working; `power` is the
# full analysis, for callers that want the breakdown rather than the two numbers
# the runtime needs each frame.
static func compute_energy(hull_node: Node3D, hull_type: String) -> Dictionary:
	# hull_type passed explicitly: this function is handed the authoritative type
	# by its caller, and a standalone or test-built hull does not always carry
	# the type_id meta that analyze() would otherwise fall back on.
	var power: Dictionary = PowerBudgetScript.analyze(hull_node, hull_type)
	return {
		"max_energy": power["storage"],
		"energy_regen_rate": power["net"],
		"power": power,
	}


# The four nav maps are duck-typed off the match controller, exactly as the old
# runtime did it (`has_method("get_ground_nav_map")`), so a unit built standalone
# in a test simply gets no agent and falls back to direct steering. That property
# is load-bearing for testability and is kept on purpose.
#
# Returns null when the unit does not path (flying) or no controller was found.
static func build_nav_agent(body: CharacterBody3D, facts: Dictionary, controller: Node) -> NavigationAgent3D:
	if facts.get("is_flying", false) or facts.get("is_fixed_wing", false):
		return null
	if controller == null \
			or not controller.has_method("get_ground_nav_map") \
			or not controller.has_method("get_water_nav_map"):
		return null

	var agent := NavigationAgent3D.new()
	agent.name = "NavAgent"
	# Local avoidance is OFF. Separation is handled in steering.gd, where it can
	# be reconciled with formation slots - NavigationAgent3D's built-in avoidance
	# fights a formation, because it treats the neighbour a unit is deliberately
	# lining up beside as an obstacle to swerve around.
	agent.avoidance_enabled = false
	body.add_child(agent)

	if facts.get("is_naval", false):
		var draught: float = facts.get("hull_draught", 0.0)
		if draught > ModuleCatalog.SHALLOW_WATER_DRAUGHT_THRESHOLD and controller.has_method("get_deep_water_nav_map"):
			agent.set_navigation_map(controller.get_deep_water_nav_map())
		else:
			agent.set_navigation_map(controller.get_water_nav_map())
	elif (facts.get("is_amphibious", false) or facts.get("is_hovering", false)) 			and controller.has_method("get_amphibious_nav_map"):
		# Amphibious AND hovering share the amphibious map: it is the surface
		# that covers land and water alike. Flying units never get here at all -
		# they return null above and steer directly, so they already cross
		# anything.
		agent.set_navigation_map(controller.get_amphibious_nav_map())
	else:
		agent.set_navigation_map(controller.get_ground_nav_map())
	return agent


# --- Team Outline / Rim-Light ------------------------------------------------
# Applied once after hull construction. Enemies get an inverted-hull outline
# (back-face pass, pushed outward). Friendlies get a rim-light uniform set on
# their hull materials so the shader adds a subtle bright edge at silhouettes.

const ENEMY_OUTLINE_SHADER = preload("res://shaders/enemy_outline.gdshader")
const FRIENDLY_RIM_STRENGTH := 0.30
const FRIENDLY_RIM_COLOR := Vector3(1.0, 0.95, 0.85)
const FRIENDLY_RIM_POWER := 3.0
const ENEMY_OUTLINE_WIDTH := 0.025
const ENEMY_OUTLINE_COLOR := Color(0.0, 0.0, 0.0, 1.0)


static func _apply_team_visuals(body: CharacterBody3D, hull_node: Node3D,
		team: int, _facts: Dictionary) -> void:
	if hull_node == null:
		return
	# Route through PLAYER_TEAM / ENEMY_TEAM rather than bare 0/1. The bare-number
	# version of this check (`if team == 0`) read PLAYER as "enemy" - correct in
	# some battles but wrong here: PLAYER_TEAM is 0 (match_director.gd:76) and
	# ENEMY_TEAM is 1, so every player unit ended up wearing the inverted-hull
	# enemy outline (solid black, cull_front, vertices pushed 0.025m along
	# normals) - a duplicate of every hull mesh rendered as a black shell.
	# Friendlies also got the rim-light uniforms set, which is harmless but
	# pointless. Swapping the conditions and naming the constants keeps the two
	# branches from drifting again.
	if team == MatchDirectorScript.PLAYER_TEAM:
		_apply_friendly_rim(hull_node)
	else:
		_apply_enemy_outline(hull_node)


static func _apply_enemy_outline(hull_node: Node3D) -> void:
	var outline_mat := ShaderMaterial.new()
	outline_mat.shader = ENEMY_OUTLINE_SHADER
	outline_mat.set_shader_parameter("outline_color", ENEMY_OUTLINE_COLOR)
	outline_mat.set_shader_parameter("outline_width", ENEMY_OUTLINE_WIDTH)
	_add_outline_passes(hull_node, outline_mat)


static func _apply_friendly_rim(hull_node: Node3D) -> void:
	for child in hull_node.find_children("*", "", true, false):
		if child is MeshInstance3D and child.material_override is ShaderMaterial:
			var mat: ShaderMaterial = child.material_override
			if mat.shader != null and "friendly_rim_strength" in mat.shader.get_shader_uniform_list():
				mat.set_shader_parameter("friendly_rim_strength", FRIENDLY_RIM_STRENGTH)
				mat.set_shader_parameter("friendly_rim_color", FRIENDLY_RIM_COLOR)
				mat.set_shader_parameter("friendly_rim_power", FRIENDLY_RIM_POWER)


static func _add_outline_passes(hull_node: Node3D, outline_mat: ShaderMaterial) -> void:
	var outline_root := Node3D.new()
	outline_root.name = "EnemyOutline"
	hull_node.add_child(outline_root)
	for child in hull_node.find_children("*", "", true, false):
		if child is MeshInstance3D and child.mesh != null:
			var mi := MeshInstance3D.new()
			mi.mesh = child.mesh
			mi.material_override = outline_mat
			mi.cast_shadow = 0  # OFF
			mi.gi_mode = 0  # DISABLED
			# Inherit transform from the original mesh
			mi.transform = child.transform
			outline_root.add_child(mi)
