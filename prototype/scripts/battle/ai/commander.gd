class_name Commander
extends RefCounted
# The AI's macro brain: what to spend on next.
#
# WHAT REPLACES WHAT. enemy_ai.gd was four fixed-interval timers - produce every
# 14 s, wave every 55 s, check structures every 8 s, trickle resources - driving
# imperative rules. Nothing was ever weighed against anything else, so the AI
# could not be behind on economy and know it, and its "counter-picking" was a
# single boolean bias in front of a round-robin cycle. Waves were not a plan
# either: _launch_wave() ordered EVERY live unit to attack the HQ, so the AI had
# exactly one tactic and used it on a timer regardless of whether it could win.
#
# THE MODEL. Every tick, score a fixed list of actions with
# U(a) = sum of w_i * c_i(x_i) and take the best one that is affordable. The
# weights are the personality; the considerations are in considerations.gd.
#
# WHAT IT MAY NOT DO. It reads the same EconomyService and VisionService the
# player's HUD does, and it issues orders through OrderService like the player.
# It has no privileged knowledge: if it cannot see a unit, it cannot count it.
# That is enforced by construction - there is no other way in here - rather than
# by discipline, which is the whole reason the AI was rebuilt on the services
# instead of beside them.
#
# The one concession is a difficulty-scaled income trickle, which the old AI
# already had as PITY_METAL/PITY_CRYSTAL. It is honest about being a handicap
# rather than pretending to be intelligence.

const C = preload("res://scripts/battle/ai/considerations.gd")
const BuildingCatalogScript = preload("res://scripts/battle/economy/building_catalog.gd")
const ModuleCatalog = preload("res://scripts/module_catalog.gd")
const ThreatAnalyzer = preload("res://scripts/battle/ai/threat_analyzer.gd")

# SKIRMISH_PERF_TROUBLESHOOTING.md §14. Cap the rate at which the AI
# issues the same structure type. The 20:49:15 capture showed 14
# power plants in 1000 frames (1 every 16 frames = 0.5 s), each
# placement driving a 320-368 ms units-bucket hitch. The cap is
# per TYPE, so the AI can still place a refinery while the power
# plant is rate-limited. The cap is at execute() not decide() so
# the AI's score for a structure doesn't decay just because the
# build itself was rate-limited - it keeps choosing the best
# action; the cap drops the actual placement call.
const BUILD_RATE_CAP_SECONDS := 2.0
# ESCALATION (2026-08-24). The 02:31 skirmish log shows what a fixed cap does
# when the reason for building never clears: is_low_power stayed true for eight
# straight minutes (past ~150 structures the upkeep-per-structure draw outruns
# what another plant returns), so ADD_POWER landed one plant every 2.0 s all
# match - and every placement forces a navmesh sync that measured multi-second
# frames. A repeat that fails to satisfy its own trigger now stretches that
# type's cooldown; a satisfied check resets it. This bounds navmesh churn from
# ANY runaway build loop without touching the balance numbers themselves.
const BUILD_RATE_ESCALATION := 1.75
const BUILD_RATE_MAX_SECONDS := 24.0
var _build_rate_escalation: Dictionary = {}
const WorldScaleScript = preload("res://scripts/world_scale.gd")
# SKIRMISH_PERF_TROUBLESHOOTING.md §5 Track B / §6 item 1.
# Profiler sections are added INSIDE this class so the per-step
# breakdown is captured even when the caller forgets to time
# commander.tick() as a whole. Cost when disabled: one static bool
# read per call site (battle_profiler.gd's contract).
const Profiler = preload("res://scripts/battle/battle_profiler.gd")

# Reused verbatim from enemy_ai.gd:109-118. The CLASSIFICATION was sound - these
# really are the roster's answers to air and to armour - it was only its consumer
# that was weak. Rewriting the lists would throw away roster knowledge that has
# nothing to do with why the old AI was bad.
#
# sam_launcher ADDED. The original list predates the roster expansion, so the
# one purpose-built surface-to-air weapon in the game was not recognised as an
# answer to air - an AI holding a SAM turret design would keep scoring "build
# anti-air" and pick something else.
const ANTI_AIR_WEAPONS := ["ciws", "flak_cannon", "pd_laser", "sam_launcher", "aa_autocannon"]
const ANTI_ARMOR_WEAPONS := ["gauss_railgun", "artillery", "ion_cannon",
	"coil_gun", "recoilless_rifle", "ballista", "anti_materiel_rifle", "particle_lance"]
const POINT_DEFENSE_WEAPONS := ["ciws", "pd_laser", "flak_cannon"]
const INDIRECT_WEAPONS := ["artillery", "mortar_array", "spigot_mortar", "rocket_artillery", "cluster_dispenser", "plasma_lobber", "mk19_grenade_launcher", "napalm_mortar"]

enum Action {
	EXPAND_ECONOMY,   # another harvester
	ADD_REFINERY,
	ADD_POWER,
	ADD_PRODUCTION,   # another manufactory: faster queue, not a second one
	BUILD_ANTI_AIR,
	BUILD_ANTI_ARMOR,
	BUILD_GENERAL,
	DEFEND,           # pull squads home
	BUILD_DEFENSE,    # a turret, which holds ground a squad would have to stand on
	PUSH,             # commit to an attack
	# --- AI overhaul: damage-type-aware actions ---
	# These fire when the AI detects specific armor/weapon patterns in the
	# observed enemy force and has designs in its roster that counter them.
	BUILD_COUNTER_ARMOR,  # enemy wears a specific material → build the damage class that cracks it
	BUILD_POINT_DEFENSE,  # enemy spams guided missiles → build PD-equipped units
	BUILD_INDIRECT,       # enemy turtles with static defenses → build artillery
}

# How long a decision stands before it is re-scored. Not a cooldown on acting -
# it is the tick rate of thinking. Fast enough to react to a raid, slow enough
# that the AI does not thrash between two near-equal actions every frame.
const DECISION_INTERVAL := 2.0

# Below this the AI will not commit to an attack no matter how good the target
# looks. An army that attacks in dribs is an army that dies in dribs, and the old
# runtime's every-unit-attacks-on-a-timer is exactly that failure.
const MIN_PUSH_SQUAD := 4

# Personality. These are the numbers to move to make an AI greedy, turtly or
# aggressive; nothing else about it needs to change.
#
# AI OVERHAUL: now the DEFAULT weights, overridden per-doctrine. The doctrine
# system gives three distinct AI flavors with readable, exploitable biases.
# The player discovers the doctrine through observed behavior, not through a
# label on the setup screen — an opponent that telegraphs its strategy before
# the game starts is not an opponent worth reading.
const WEIGHTS := {
	Action.EXPAND_ECONOMY: 1.0,
	Action.ADD_REFINERY: 0.9,
	Action.ADD_POWER: 1.2,
	Action.ADD_PRODUCTION: 0.8,
	Action.BUILD_ANTI_AIR: 1.1,
	Action.BUILD_ANTI_ARMOR: 1.1,
	Action.BUILD_GENERAL: 0.6,
	Action.DEFEND: 1.6,
	Action.BUILD_DEFENSE: 1.0,
	Action.PUSH: 0.7,
	# New damage-type-aware actions — same default weight as the role-based
	# equivalents. The consideration math gates them on actual observations.
	Action.BUILD_COUNTER_ARMOR: 1.1,
	Action.BUILD_POINT_DEFENSE: 1.0,
	Action.BUILD_INDIRECT: 0.9,
}

# --- Doctrine system -----------------------------------------------------------
#
# Three AI personalities. Each overrides a subset of WEIGHTS and tweaks
# tactical constants. The player learns the doctrine from observed behavior:
#   - Blitz attacks early, raids often, under-invests in economy
#   - Attrition is balanced, counter-picks carefully, trades efficiently
#   - Fortress turtles with defenses, builds heavy economy, rarely pushes
#
# EXPLOITABLE BY DESIGN:
#   Blitz    → kill its harvesters and it collapses (fragile economy)
#   Attrition → rush before it adapts (slow to push, needs time to read you)
#   Fortress → out-tech and overwhelm (never pressures you, lets you scale)
const DOCTRINES := {
	"blitz": {
		"weight_overrides": {
			Action.PUSH: 1.2,
			Action.EXPAND_ECONOMY: 0.7,
			Action.BUILD_DEFENSE: 0.4,
			Action.ADD_PRODUCTION: 1.0,
			Action.BUILD_COUNTER_ARMOR: 0.8,
		},
		"min_push_squad": 3,
		"defence_target": 2,
		"retreat_health_fraction": 0.3,
		"raider_priority": 1.4,
	},
	"attrition": {
		"weight_overrides": {
			Action.BUILD_COUNTER_ARMOR: 1.3,
			Action.BUILD_ANTI_AIR: 1.3,
			Action.BUILD_ANTI_ARMOR: 1.3,
		},
		"min_push_squad": 5,
		"defence_target": 3,
		"retreat_health_fraction": 0.4,
		"raider_priority": 1.0,
	},
	"fortress": {
		"weight_overrides": {
			Action.BUILD_DEFENSE: 1.8,
			Action.ADD_REFINERY: 1.2,
			Action.PUSH: 0.4,
			Action.DEFEND: 2.0,
			Action.BUILD_INDIRECT: 0.5,
		},
		"min_push_squad": 7,
		"defence_target": 6,
		"retreat_health_fraction": 0.5,
		"raider_priority": 0.5,
	},
}

# Default difficulty → doctrine mapping. Easy gets fortress (passive, lets the
# player breathe); normal gets attrition (balanced, learns); hard gets blitz
# (aggressive, punishing). In Operations, the AI cycles doctrines between
# rounds so the player faces varied challenges.
const DIFFICULTY_DOCTRINE := {
	"easy": "fortress",
	"normal": "attrition",
	"hard": "blitz",
}

# Turrets the AI will put up before it stops seeing the point. A base ringed with
# static defence is a base that has spent its economy on ground it already holds.
# Overridden by the doctrine's defence_target.
const DEFENCE_TARGET := 3

# Target harvester count, PER REFINERY.
#
# Three because a refinery has exactly three dock bays: a fourth truck cannot
# unload any sooner than the queue lets it, so it costs a unit's worth of metal
# to add nothing. The old value of 4 had the AI spending its entire income on a
# truck that would only orbit - measured, it reached three harvesters and never
# once fielded a combat unit, because every credit went into the next harvester
# before anything else could compete.
const HARVESTERS_PER_REFINERY := 3

# How far ahead an affordability decision looks, in seconds.
#
# THE BUG THIS FIXES, because it is not obvious from the constant. Every action
# below gates on a metal ramp with a floor of 100-200. Production draws its cost
# gradually across the build, so a team with anything queued sits at ~0 metal for
# the entire build - which means every one of those ramps read zero, score() vetoes
# on any zero consideration, and the commander returned "no action at all".
#
# Measured before this change: `decision=NOTHING, scores: all zero` unbroken from
# tick 3600 to 19800 of a match that ended at 27447. The AI still grew, but only
# on the momentum of units queued in the first two seconds - it was not deciding
# anything for two thirds of the match. It looked like a stalled economy and was
# really a commander that had blinded itself by asking the wrong question.
#
# 30 s because that is roughly one build: the question worth asking is "can I pay
# for this by the time it would finish", not "can I pay for it this instant".
const PLANNING_HORIZON := 30.0

# Minimum time between re-decides. PR5 (2026-08-15) added event-driven
# re-decide via set_dirty(); this cap prevents a burst of dirty events
# (e.g. a wipe that kills 6 units in 2 seconds) from triggering 6
# re-decides back-to-back. The full DECISION_INTERVAL still applies if
# nothing marks the world dirty; this is only a floor.
const MIN_DECISION_INTERVAL := 0.5

var team: int = 1
# SKIRMISH_PERF_TROUBLESHOOTING.md §14. Last placement time per
# structure type, in milliseconds (Time.get_ticks_msec()). Empty
# until the first placement of each type; the cap check is
# `now - last < BUILD_RATE_CAP_SECONDS * 1000` so a missing key
# (treated as 0) lets the first placement through.
var _last_build_at_ms: Dictionary = {}
var difficulty: String = "normal"

# AI OVERHAUL: the active doctrine, resolved from difficulty at setup.
# Determines weight overrides, tactical constants, and exploitable bias.
var doctrine: String = "attrition"
# AI OVERHAUL: the dominant enemy armor material observed through fog.
# Updated by read_state() every decision tick. Used by ammo adaptation.
var observed_enemy_armor: String = ""

var _world = null
var _timer: float = 0.0
var _last_action: int = -1
# PR5 (2026-08-15). Event-driven re-decide flag. set_dirty() is called from
# the match director when a relevant event lands (structure built, unit
# died, enemy sighted). tick() short-circuits unless either the periodic
# interval has elapsed OR the flag is set; the flag is cleared after a
# decision lands. Net: 90 re-decides over a 3-minute match become ~30,
# with the same responsiveness to the events that matter.
var _dirty: bool = true


func setup(world, ai_team: int, ai_difficulty: String = "normal") -> void:
	_world = world
	team = ai_team
	difficulty = ai_difficulty
	# Resolve doctrine from difficulty, with fallback to attrition
	doctrine = DIFFICULTY_DOCTRINE.get(difficulty, "attrition")


# The effective weight for an action, with doctrine overrides applied.
# Base WEIGHTS are the floor; the doctrine can raise or lower individual
# actions to express its personality. Actions not mentioned in the doctrine's
# overrides use the base weight unchanged.
func _get_weight(action: int) -> float:
	var base: float = WEIGHTS.get(action, 0.0)
	var doc: Dictionary = DOCTRINES.get(doctrine, {})
	var overrides: Dictionary = doc.get("weight_overrides", {})
	return overrides.get(action, base)

# The effective min push squad size, overridden by doctrine.
func _min_push_squad() -> int:
	var doc: Dictionary = DOCTRINES.get(doctrine, {})
	return int(doc.get("min_push_squad", MIN_PUSH_SQUAD))

# The effective defence target, overridden by doctrine.
func _defence_target() -> int:
	var doc: Dictionary = DOCTRINES.get(doctrine, {})
	return int(doc.get("defence_target", DEFENCE_TARGET))


# Mark the world state as needing a re-decide. Cheap; the match_director
# calls this from structure_built.connect, unit_died signal handlers, and
# the fog-revealed callback. Without this, the commander would only
# re-consider on a fixed 2 s interval, missing urgent changes.
func set_dirty() -> void:
	_dirty = true


func tick(delta: float) -> void:
	if _world == null:
		return
	_timer += delta
	# PR5 (2026-08-15). Two gates, not one:
	#   1. The periodic gate: at least DECISION_INTERVAL since the last
	#      decision. This is the "think about whether to change strategy"
	#      pace; the AI does not thrash between two near-equal actions
	#      every frame.
	#   2. The dirty gate: the world state has changed since the last
	#      decision (set_dirty() was called). If nothing changed, there
	#      is nothing new to score, and re-deciding is wasted work.
	# A re-decide runs when EITHER gate fires. The MIN_DECISION_INTERVAL
	# floor keeps a burst of dirty events from re-deciding back-to-back.
	var periodic_due: bool = _timer >= DECISION_INTERVAL
	var dirty_due: bool = _dirty and _timer >= MIN_DECISION_INTERVAL
	if not (periodic_due or dirty_due):
		return
	_timer = 0.0
	_dirty = false

	# SKIRMISH_PERF_TROUBLESHOOTING.md §6 item 1. The 2026-08-19
	# log showed `commander` as a single bucket at 8048 ms total and
	# 446 ms worst. Without the split, the answer to "why is the
	# re-decide slow" is a number, not a place to look. The three
	# sections here convert that bucket into per-step totals so a
	# single capture answers Track B before any commander code is
	# touched. read_state walks every unit and structure on both
	# teams; decide runs the consideration fan-out; execute is
	# thin (a single ai_* call) and is profiled so a regression
	# inside _ai_placement_site, which is the Track C suspect, is
	# visible as commander.execute blowing up rather than as
	# "commander" being slow.
	var _t_state := Profiler.start()
	var state := read_state()
	Profiler.stop("commander.read_state", _t_state)

	var _t_decide := Profiler.start()
	var choice := decide(state)
	Profiler.stop("commander.decide", _t_decide)

	_last_action = choice
	if choice >= 0:
		var _t_execute := Profiler.start()
		_execute(choice, state)
		Profiler.stop("commander.execute", _t_execute)


# --- Perception --------------------------------------------------------------

# Everything the commander is allowed to know, gathered once so scoring is a pure
# function of a dictionary. That is what makes decide() testable without a match:
# hand it a state, assert what it picks.
#
# ENEMY COUNTS ARE FOG-GATED. is_visible_to_team() is the same call the player's
# minimap uses, so an unscouted army is an unknown army to the AI too.
func read_state() -> Dictionary:
	var economy = _world.economy
	var own_units: Array = _world.get_team_units(team)
	var own_structures: Array = _world.get_team_structures(team)

	var harvesters := 0
	var combat: Array = []
	for u in own_units:
		if u.is_harvester:
			harvesters += 1
		else:
			combat.append(u)

	# IN-FLIGHT PRODUCTION COUNTS. This is the difference between an AI that
	# builds an economy and one that never builds an army.
	#
	# Reading only LIVE harvesters means a truck that is paid for and 90% built
	# does not exist yet, so EXPAND_ECONOMY keeps scoring highest and keeps
	# queueing more. The queue depth cap (AI_MAX_QUEUE_DEPTH = 2) then fills
	# permanently with harvesters, and every ai_build_unit() call for a COMBAT
	# design is refused at the door because that queue is full.
	#
	# Measured before this: the medium queue sat at depth 2 with an Ore Trucker at
	# its head for the entire match, the commander chose BUILD_GENERAL 3,702 times,
	# and ZERO combat units were ever enqueued - let alone produced. It looked like
	# an economy problem and survived the economy being fixed.
	harvesters += _queued_harvesters()

	var enemy_air := 0
	var enemy_armour := 0
	var enemy_seen := 0
	# AI OVERHAUL: damage-type intelligence. Tally what the enemy is wearing
	# and shooting so the new counter-pick actions can fire.
	var enemy_armor_counts: Dictionary = {}  # material -> count
	var enemy_missile_count := 0
	var enemy_defence_count := 0
	for enemy_team in [0]:
		for u in _world.get_team_units(enemy_team):
			if not is_instance_valid(u) or u.is_dead:
				continue
			if _world.has_method("is_visible_to_team") and not _world.is_visible_to_team(u, team):
				continue
			enemy_seen += 1
			if u.is_flying:
				enemy_air += 1
			if is_instance_valid(u.hull_node) and u.hull_node.has_meta("armor_thickness") \
					and u.hull_node.get_meta("armor_thickness") >= 2.0:
				enemy_armour += 1
			# AI OVERHAUL: read armor material from the unit's metadata
			var mat: String = ""
			if is_instance_valid(u.hull_node) and u.hull_node.has_meta("armor_material"):
				mat = str(u.hull_node.get_meta("armor_material"))
			elif "armor_material" in u:
				mat = str(u.armor_material)
			if not mat.is_empty():
				enemy_armor_counts[mat] = int(enemy_armor_counts.get(mat, 0)) + 1
			# Count guided-projectile units (missile spam detection)
			if "blueprint" in u and u.blueprint is Dictionary:
				var guided_share: float = ThreatAnalyzer._guided_dps_share(u.blueprint)
				if guided_share >= 0.4:
					enemy_missile_count += 1
		# Count enemy static defenses
		if _world.has_method("get_team_structures"):
			for s in _world.get_team_structures(enemy_team):
				if not is_instance_valid(s):
					continue
				if _world.has_method("is_visible_to_team") \
						and not _world.is_visible_to_team(s, team):
					continue
				if s.kind == "defense":
					enemy_defence_count += 1

	# AI OVERHAUL: resolve the dominant enemy armor material for counter-picks
	var dominant_enemy_armor := ""
	var dominant_armor_count := 0
	for mat in enemy_armor_counts:
		if int(enemy_armor_counts[mat]) > dominant_armor_count:
			dominant_armor_count = int(enemy_armor_counts[mat])
			dominant_enemy_armor = mat
	# Cache for ammo adaptation (used by _execute via match_director)
	observed_enemy_armor = dominant_enemy_armor

	return {
		"credits": economy.credits(team),
		# What the affordability considerations below actually read. See
		# PLANNING_HORIZON - cash-on-hand is the wrong number under drip-fed
		# production, and reading it was why this commander scored every action at
		# zero for four minutes of a seven-minute match.
		"budget": economy.budget(team, PLANNING_HORIZON),
		"income_rate": economy.income_rate(team),
		"harvesters": harvesters,
		"combat_units": combat.size(),
		"refineries": _count_kind(own_structures, "refinery"),
		"manufactories": _count_manufactories(own_structures),
		"low_power": economy.is_low_power(team),
		"enemy_seen": enemy_seen,
		"enemy_air_share": C.share(enemy_air, enemy_seen),
		"enemy_armour_share": C.share(enemy_armour, enemy_seen),
		"base_threatened": _base_threatened(),
		"can_build_harvester": _world.ai_can_build_role(team, "harvester"),
		"defences": _count_kind(own_structures, "defense"),
		"combat": combat,
		# AI OVERHAUL: damage-type intelligence
		"dominant_enemy_armor": dominant_enemy_armor,
		"enemy_missile_share": C.share(enemy_missile_count, enemy_seen),
		"enemy_defence_count": enemy_defence_count,
	}


func _count_kind(structures: Array, kind: String) -> int:
	var n := 0
	for s in structures:
		if s.kind == kind:
			n += 1
	return n


# Harvesters already paid for and moving through a production queue.
#
# Matched on the job's blueprint rather than on its label, so a design the PLAYER
# built and the AI happened to draft still counts - the same "roles come from
# modules" rule design_fills_role() follows everywhere else.
func _queued_harvesters() -> int:
	if _world == null or _world.production == null:
		return 0
	var n := 0
	for queue_name in BuildingCatalogScript.QUEUES:
		for job in _world.production.queue(team, queue_name):
			var bp: Dictionary = job.get("blueprint", {})
			if not bp.is_empty() and design_fills_role(bp, "harvester"):
				n += 1
	return n


func _count_manufactories(structures: Array) -> int:
	var n := 0
	for s in structures:
		if s.kind.ends_with("manufactory"):
			n += 1
	return n


# Anything hostile and VISIBLE near a building the AI owns. Fog-gated like
# everything else: an AI that reacts to an attack it cannot see is cheating, and
# a raid that goes unnoticed until the first structure burns is correct.
func _base_threatened() -> bool:
	# Was a flat 45.0. Bases stay compact under world_scale (map_catalog.gd's
	# _compact_spawns), but the enemy has to cross four times the map to
	# reach one at world_scale=4 - a radius sized against a 1x base is now
	# barely wider than the base's own footprint, so the AI would not
	# register a threat until the attacker was already inside the walls.
	# Scaling keeps the same relative warning distance regardless of world
	# size.
	var threat_radius := 45.0
	if _world != null and "current_map" in _world:
		threat_radius = WorldScaleScript.scaled_f(threat_radius, _world.current_map)
	for s in _world.get_team_structures(team):
		for u in _world.get_team_units(0):
			if not is_instance_valid(u) or u.is_dead or u.is_harvester:
				continue
			if _world.has_method("is_visible_to_team") and not _world.is_visible_to_team(u, team):
				continue
			if u.global_position.distance_to(s.global_position) <= threat_radius:
				return true
	return false


# --- Scoring -----------------------------------------------------------------

# The whole decision, as a pure function. No side effects, no world access.
func decide(state: Dictionary) -> int:
	var scores := score_all(state)
	var best := -1
	var best_score := 0.0
	for action in scores:
		if scores[action] > best_score:
			best_score = scores[action]
			best = action
	return best


func score_all(state: Dictionary) -> Dictionary:
	var out := {}
	for action in WEIGHTS:
		out[action] = _score(action, state)
	return out


func _score(action: int, state: Dictionary) -> float:
	var w: float = _get_weight(action)
	match action:
		Action.EXPAND_ECONOMY:
			# Wants harvesters early and stops caring once the refinery is
			# saturated. Gated on somewhere to deliver AND the ability to actually
			# build one: without the second veto this outscores everything from the
			# opening tick, fails silently for want of the right factory, and
			# re-wins next tick - an AI that spends the whole match deciding to
			# build a harvester it has no way to build.
			return C.score(w, [
				C.falloff(state["harvesters"], 0.0,
					float(maxi(1, state["refineries"]) * HARVESTERS_PER_REFINERY)),
				C.ramp(state["budget"], 100.0, 400.0),
				1.0 if state["refineries"] > 0 else 0.0,
				# "Can I build one", not "do I own a factory". Owning a light
				# manufactory while the only harvester design is a medium hull is
				# exactly the state that starved it at 86 metal.
				1.0 if state["can_build_harvester"] else 0.0,
			])
		Action.ADD_REFINERY:
			# One is enough until there are trucks queueing for it.
			return C.score(w, [
				C.falloff(state["refineries"], 0.0, 2.0),
				C.ramp(state["harvesters"], 2.0, 5.0),
				C.ramp(state["budget"], 200.0, 500.0),
			])
		Action.ADD_POWER:
			# A veto in reverse: worthless at full power, urgent in a brownout.
			# Low power throttles the production queues, so this outranks almost
			# everything while it is true.
			return C.score(w, [
				1.0 if state["low_power"] else 0.0,
				C.ramp(state["budget"], 100.0, 300.0),
			])
		Action.ADD_PRODUCTION:
			# More manufactories make the ONE queue faster (the RA speed table),
			# so this saturates where that table does rather than growing forever.
			#
			# DELIBERATELY NOT GATED ON HAVING HARVESTERS. The obvious "only expand
			# production once the economy is running" consideration reads as sense
			# and is a deadlock: at zero harvesters it vetoes this to nothing, while
			# EXPAND_ECONOMY cannot run without a factory, so the AI sits on its
			# opening money forever. The first manufactory is what breaks the
			# chicken-and-egg, so nothing may veto it.
			#
			# URGENT while the economy cannot start. Being unable to build a
			# harvester is the one genuinely unrecoverable state - there is no
			# income to dig out of it with - so it outranks the ordinary "more
			# factories is nice" reading by a wide margin.
			var blocked: float = 0.0 if state["can_build_harvester"] else 1.0
			return C.score(w, [
				maxf(C.falloff(state["manufactories"], 1.0, 4.0), blocked),
				maxf(C.ramp(state["budget"], 150.0, 700.0), blocked),
			]) + blocked * w * 2.0
		Action.BUILD_ANTI_AIR:
			# Curved hard: a scout flyer should not trigger a full AA pivot, but a
			# real air army should outrank general production decisively.
			return C.score(w, [
				C.curve(state["enemy_air_share"], 1.6),
				C.ramp(state["budget"], 150.0, 400.0),
				1.0 if state["manufactories"] > 0 else 0.0,
			])
		Action.BUILD_ANTI_ARMOR:
			return C.score(w, [
				C.curve(state["enemy_armour_share"], 1.6),
				C.ramp(state["budget"], 150.0, 400.0),
				1.0 if state["manufactories"] > 0 else 0.0,
			])
		Action.BUILD_GENERAL:
			# The floor. Deliberately low-weighted so it loses to anything with an
			# actual reason, and wins when nothing else has one.
			# The metal floor is deliberately BELOW what EXPAND_ECONOMY needs, so
			# once the economy is running this can win a tick rather than being
			# perpetually outbid by the next harvester.
			return C.score(w, [
				C.ramp(state["budget"], 120.0, 400.0),
				1.0 if state["manufactories"] > 0 else 0.0,
			])
		Action.DEFEND:
			# Highest weight in the table, and vetoed unless the base is genuinely
			# under threat. Losing production to a raid costs more than any build.
			return C.score(w, [
				1.0 if state["base_threatened"] else 0.0,
				C.ramp(state["combat_units"], 1.0, 4.0),
			])
		Action.BUILD_DEFENSE:
			# Wanted once the AI has SEEN something, and more so while its base is
			# being hit - a turret holds ground that would otherwise cost a squad
			# standing on it. Saturates at _defence_target() so it does not turtle
			# its whole economy into concrete (unless the doctrine IS turtling).
			return C.score(w, [
				C.falloff(state["defences"], 0.0, float(_defence_target())),
				C.ramp(state["budget"], 200.0, 500.0),
				maxf(C.share(state["enemy_seen"], 4.0), 1.0 if state["base_threatened"] else 0.0),
			])
		Action.PUSH:
			# Needs a real army AND something worth walking to. The _min_push_squad()
			# floor is what stops the old trickle-attack behaviour. Doctrines
			# lower this floor to push earlier (blitz) or raise it to be patient
			# (fortress).
			var push_min: int = _min_push_squad()
			return C.score(w, [
				1.0 if state["combat_units"] >= push_min else 0.0,
				C.ramp(state["combat_units"], float(push_min), 10.0),
				0.0 if state["base_threatened"] else 1.0,
			])
		# --- AI OVERHAUL: damage-type-aware actions ---
		Action.BUILD_COUNTER_ARMOR:
			# Fires when the AI has seen enough enemy units wearing a specific
			# armor material to identify a pattern worth countering. The dominant
			# enemy armor's weakness becomes the target damage class.
			# Curved like BUILD_ANTI_AIR — one scout in bad armor is noise,
			# a whole army in energy shields is a signal.
			var has_armor_intel: float = 1.0 if not state["dominant_enemy_armor"].is_empty() else 0.0
			return C.score(w, [
				has_armor_intel,
				C.ramp(state["budget"], 150.0, 400.0),
				1.0 if state["manufactories"] > 0 else 0.0,
				C.ramp(float(state["enemy_seen"]), 2.0, 6.0),
			])
		Action.BUILD_POINT_DEFENSE:
			# Fires when the enemy is running a lot of guided-projectile weapons
			# (missile spam). PD intercepts those projectiles.
			return C.score(w, [
				C.curve(state["enemy_missile_share"], 1.6),
				C.ramp(state["budget"], 150.0, 400.0),
				1.0 if state["manufactories"] > 0 else 0.0,
			])
		Action.BUILD_INDIRECT:
			# Fires when the enemy is turtling behind static defenses. Artillery
			# outranges turrets and breaks the turtle. Also useful when the enemy
			# has a lot of visible units (massed formation → splash value).
			return C.score(w, [
				C.ramp(float(state["enemy_defence_count"]), 1.0, 4.0),
				C.ramp(state["budget"], 200.0, 500.0),
				1.0 if state["manufactories"] > 0 else 0.0,
			])
	return 0.0


func last_action() -> int:
	return _last_action


func action_name(action: int) -> String:
	if action < 0:
		return "NOTHING"
	return Action.keys()[action]


# --- Execution ---------------------------------------------------------------
#
# Deliberately thin. Everything the AI does goes through the same services the
# player's UI calls - ProductionService to build, OrderService to command - so
# there is no second path where AI-only behaviour could accumulate.

func _execute(action: int, state: Dictionary) -> void:
	match action:
		Action.EXPAND_ECONOMY:
			_world.ai_build_unit(team, "harvester")
		Action.ADD_REFINERY:
			if _build_rate_ok("refinery"):
				_world.ai_build_structure(team, "refinery")
		Action.ADD_POWER:
			if _build_rate_ok("power_plant", func() -> bool: return not bool(state.get("low_power", false))):
				_world.ai_build_structure(team, "power_plant")
		Action.ADD_PRODUCTION:
			# The director picks WHICH manufactory - it knows about hull tiers and
			# this does not need to.
			_world.ai_build_production(team)
		Action.BUILD_ANTI_AIR:
			_world.ai_build_unit(team, "anti_air")
		Action.BUILD_ANTI_ARMOR:
			_world.ai_build_unit(team, "anti_armor")
		Action.BUILD_GENERAL:
			_world.ai_build_unit(team, "general")
		Action.DEFEND:
			_world.ai_defend(team, state["combat"])
		Action.BUILD_DEFENSE:
			_world.ai_build_defence(team)
		Action.PUSH:
			_world.ai_push(team, state["combat"])
		# --- AI OVERHAUL: damage-type-aware execution ---
		Action.BUILD_COUNTER_ARMOR:
			# Routes through the same ai_build_unit pipeline, but the role
			# "counter_armor" is resolved by design_fills_role using the
			# dominant enemy armor's weakness from ThreatAnalyzer.
			_world.ai_build_unit(team, "counter_armor")
		Action.BUILD_POINT_DEFENSE:
			_world.ai_build_unit(team, "point_defense")
		Action.BUILD_INDIRECT:
			_world.ai_build_unit(team, "indirect")


# SKIRMISH_PERF_TROUBLESHOOTING.md §14. Per-type build rate cap. The
# first placement of a type (last_ms == 0) always passes; subsequent
# placements need BUILD_RATE_CAP_SECONDS since the last one. Returns
# true and records the timestamp on pass, returns false on block.
func _build_rate_ok(type: String, satisfied_check: Callable = Callable()) -> bool:
	var now_ms: int = Time.get_ticks_msec()
	var last_ms: int = int(_last_build_at_ms.get(type, 0))
	var wait_s: float = BUILD_RATE_CAP_SECONDS * float(_build_rate_escalation.get(type, 1.0))
	if now_ms - last_ms < int(wait_s * 1000.0):
		return false
	_last_build_at_ms[type] = now_ms
	if satisfied_check.is_valid():
		if satisfied_check.call():
			_build_rate_escalation[type] = 1.0
		else:
			_build_rate_escalation[type] = minf(
				float(_build_rate_escalation.get(type, 1.0)) * BUILD_RATE_ESCALATION,
				BUILD_RATE_MAX_SECONDS)
	return true


# Does this design answer `role`? The blueprint's own module list is the source
# of truth, so a design the PLAYER built counts as anti-air if it mounts a CIWS -
# the AI does not need a curated list of its own units.
static func design_fills_role(blueprint: Dictionary, role: String, target_armor: String = "") -> bool:
	if role == "harvester":
		for m in blueprint.get("modules", []):
			if m.get("type_id", "") == "resource_harvester":
				return true
		return false
	if role == "general":
		return not design_fills_role(blueprint, "harvester")
	if role == "point_defense":
		for m in blueprint.get("modules", []):
			if m.get("type_id", "") in POINT_DEFENSE_WEAPONS:
				return true
		return false
	if role == "indirect":
		for m in blueprint.get("modules", []):
			if m.get("type_id", "") in INDIRECT_WEAPONS:
				return true
		return false
	if role == "counter_armor":
		# If target_armor specified, find if this design deals the damage class that cracks it
		if not target_armor.is_empty():
			var weakness: String = ThreatAnalyzer.weakest_class_against(target_armor)
			var p: Dictionary = ThreatAnalyzer.profile(blueprint)
			if p.get("dominant_damage", "") == weakness:
				return true
		# Fallback: anti-armor weapons count as cracking heavy armor
		for m in blueprint.get("modules", []):
			if m.get("type_id", "") in ANTI_ARMOR_WEAPONS:
				return true
		return false

	var wanted: Array = ANTI_AIR_WEAPONS if role == "anti_air" else ANTI_ARMOR_WEAPONS
	for m in blueprint.get("modules", []):
		if m.get("type_id", "") in wanted:
			return true
	return false
