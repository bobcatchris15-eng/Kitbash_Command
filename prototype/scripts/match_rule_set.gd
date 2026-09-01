class_name MatchRuleSet
extends RefCounted
# Per-match configuration: which mode this is, what the world contains, and
# which player/AI actions are available in this match. One per match, written
# by the setup screen, read by the match director and (later) by OrderService.
#
# WHAT THIS REPLACES. Today MatchConfig (scripts/match_config.gd) carries seven
# loose fields: selected_map_id, player_livery, enemy_livery,
# selected_blueprint_paths, ai_difficulty, starting_credits, plus a "roster"
# implied by the order. match_director.gd:220-280 reads them individually and
# makes per-mode decisions inline. The problem is that "which mode is this" is
# implicit (it's whichever setup screen handed us here), and every new per-mode
# flag becomes another `if match_config.something` scattered across the
# director. Three new flags and the field set is unwieldy.
#
# The rule set folds the same configuration into a single value with three
# advantages: (1) every per-mode flag is in one place, so adding a flag is
# one field and one factory branch, not one MatchConfig field and one
# director read; (2) `is_order_legal()` is the single chokepoint for "is this
# order allowed in this match", so OrderService can consult it instead of
# every caller re-asking the same question; (3) the static factories read as a
# sentence at the call site - `MatchRuleSet.test_range(player_path,
# dummy_paths)` says what it is.
#
# WHAT THIS DELIBERATELY DOES NOT DO. It is not a scene (no .tscn, no Node, no
# signals). It is a value, held by the MatchConfig autoload, carried across
# the scene change the way the seven loose fields are today. The match
# director takes a reference and reads it; nothing in the rule set owns a
# long-lived scene-tree node. Keeping it RefCounted rather than Resource keeps
# the door open for cheap copies and for shipping a `to_dict()` for the
# operations save path later, without committing to a serialisation shape yet.
#
# MIGRATION. Phase 1 of the unification plan adds this class and writes from
# the two setup screens; nothing reads it yet. Phase 2 wires match_director to
# read the rule set. The seven legacy fields on MatchConfig stay as
# backward-compat shims through Phase 4 and are deleted in Phase 5.

# --- Mode + camera + win condition enums -------------------------------------
#
# Three modes, one per entry point in MainMenu.
#   TEST_RANGE  Design Lab's "Test in Arena" — one player unit vs dummies.
#   SKIRMISH    Pick map + roster, single battle.
#   OPERATIONS  Iterative campaign, 3-12 engagements, with redesign between.
#
# Camera is the only place a runtime node (the chase camera vs the RTS camera)
# is chosen by the rule set, so the enum lives here rather than in a separate
# camera file. Win conditions and after-match actions are also rule-set
# concerns because the question "what is this match optimising for" is
# per-mode.

const LiveryScript = preload("res://scripts/livery.gd")

enum Mode { TEST_RANGE, SKIRMISH, OPERATIONS }
enum CameraMode { RTS, CHASE }
enum WinCondition {
	KILL_ALL_ENEMIES,    # all units on team 1 dead (or all production blocked)
	KILL_ALL_DUMMIES,    # Test Range: the pre-spawned enemy dummies dead
	DESTROY_HQ,          # the enemy HQ structure destroyed
	SURVIVE_TIMER,       # Test Range: alive at t=N (defensive playtest)
	NONE,                # no automatic end condition; manual exit only
}
enum AfterMatchAction {
	RETURN_TO_LAB,           # Test Range: back to MainLab
	ADVANCE_TO_NEXT_STAGE,   # Operations: next engagement's draft screen
	SHOW_AAR,                # Skirmish / last Operations stage: AAR
}


# --- Fields ------------------------------------------------------------------
#
# Plain data. No setters, no signals, no side effects. Mutated only by the
# static factories below, so a match_director reading a rule set can trust
# the values to be self-consistent. (The factories are the ONLY constructors
# in normal use; `MatchRuleSet.new()` is allowed for tests and for the
# write-once bootstrap path in MatchConfig where the rule set is set after
# the autoload mounts.)

var mode: Mode = Mode.SKIRMISH

# Map + sides
var map_id: String = ""
# LIVERY IDS, not faction ids - the ten premade factions are gone
# (faction_catalog.gd deleted 2026-08-31). The player wears the livery they
# authored in the Livery Workshop; the opponent wears one generated for the
# match. Defaults are the safe fallbacks for a rule set built by hand in a
# test: PLAYER_ID resolves to user://livery.json, and an empty enemy id is
# filled in by whichever factory runs.
#
# These were "industrialists" / "technocrats" - ids that no longer resolve to
# anything, so they fell through to a hash-derived random livery that was
# nonetheless identical in every match.
var player_livery: String = LiveryScript.PLAYER_ID
var enemy_livery: String = ""

# Roster. The "blueprint paths" form is for Skirmish/Operations; the
# "player_blueprint_path" form is the Test Range case where exactly one
# player design is given and 0..N dummies are spawned. Both can be set on
# the same rule set if you want to write a hybrid test, but each factory
# only fills the one it knows about.
var selected_blueprint_paths: Array = []      # Skirmish / Operations
var player_blueprint_path: String = ""         # Test Range
var enemy_blueprint_paths: Array = []          # Test Range (dummies)

# World contents - explicit pre-placement lists rather than the implicit
# "load from JSON, then hardcode" of the old runtime. Each entry is a
# dictionary the match director knows how to read:
#   spawn_player_buildings / spawn_enemy_buildings:
#       {type_id: String, position: Vector3}
#   spawn_player_units / spawn_enemy_units:
#       {blueprint: Dictionary OR blueprint_path: String, position: Vector3}
#   spawn_resource_fields:
#       {type: String, position: Vector3, amount: int}
var spawn_player_buildings: Array = []
var spawn_enemy_buildings: Array = []
var spawn_player_units: Array = []
var spawn_enemy_units: Array = []
var spawn_resource_fields: Array = []

# Economy. The flags are the per-mode gates - every other file in the match
# asks "is X allowed in this rule set" rather than "which mode is this and
# does the mode have X". The defaults are the Skirmish values; the Test
# Range factory flips them to false.
var starting_credits: int = -1                # -1 = use director's default
var enable_economy: bool = true                # refinery + harvester loop
var enable_production: bool = true             # build queues (player + AI)
var enable_player_build: bool = true           # player's PLACE_BUILDING
var enable_ai: bool = true                     # Commander-driven AI economy
var enable_fog_of_war: bool = true             # vision service active

# Camera + HUD. Each flag gates one sub-HUD or one camera-mode choice. The
# flags are independent because a future mode (e.g. "spectator replay") might
# want minimap but no production HUD. Default Skirmish values; Test Range
# flips minimap / production / admin off and picks CHASE.
var camera_mode: CameraMode = CameraMode.RTS
var enable_minimap: bool = true
var enable_production_hud: bool = true
var enable_battle_hud: bool = true
var enable_admin_menu: bool = true

# Game flow.
var win_condition: WinCondition = WinCondition.DESTROY_HQ
var win_timer_seconds: float = 0.0             # for SURVIVE_TIMER
var after_match_action: AfterMatchAction = AfterMatchAction.SHOW_AAR
var operation_id: String = ""                   # Operations only
var stage_index: int = 0                        # Operations only (0..N-1)
var ai_difficulty: String = "normal"
var ai_doctrine: String = ""  # Empty = auto-derived from difficulty

# Physics. PERF_TESTING_RIG.md Fix A: 30Hz halves the per-unit cost of
# unit.gd::_physics_process, which at ~2.4ms/unit headless means 60fps is
# only achievable for ~7 units at 60Hz. 30Hz doubles that to ~14 — within
# range of a typical Skirmish mid-game — while visually imperceptible for
# an RTS. Test Range stays at 60 so unit responsiveness feels snappy.
var physics_ticks_per_second: int = 60

# PR6 (2026-08-15). Enable the structured per-match JSONL log +
# the in-memory section profiler. Default ON (2026-08-18): the
# perf-investigation loop kept hitting "no log file written"
# because the rule set was false by default and the env var
# rarely survived across editor launches. Forcing the default on
# means every playtest produces a file; the env var
# (KITBASH_LOG_PROFILING=0) opts out for shipping. The match_setup /
# operations_draft / test_range_launcher factories can still flip
# it for their mode if a particular flow wants silence.
var log_profiling: bool = true

# --- Simulation seed ----------------------------------------------------------
#
# The seed for the simulation random stream (scripts/battle/sim_rng.gd). This
# is the rule set's home rather than the match director's because the seed is
# per-match CONFIGURATION, not per-match runtime state: it belongs with the map,
# the factions and the roster, and it has to travel the same path they do. Two
# consequences fall straight out of putting it here - to_dict() already
# serialises it, so a replay file or a future netcode handshake carries the seed
# alongside everything else needed to reconstruct the match, and a test can pin
# a match's randomness by setting one field on the rule set it was already
# building.
#
# 0 MEANS "UNSET", NOT "SEED ZERO". An int field defaults to 0, so leaving this
# alone is the overwhelmingly common case and it must mean "roll me a fresh
# one". SimRNG.seed_with() is the single place that decision is made: it
# substitutes a real entropy-derived seed for 0 and writes the resolved value
# back onto this field, so after begin_match() this always holds the number that
# actually reproduces the match. Without that substitution every unseeded match
# in the game would run the identical sequence of hit rolls and strip choices -
# a silent failure that reads as balance drift rather than as a bug, which is
# why the sentinel is handled at one chokepoint instead of trusted to callers.
#
# None of the three factories set it. A caller that wants a reproducible match
# assigns it explicitly after construction; everything else gets a fresh roll
# and can read the resolved value back off this field (or SimRNG.current_seed())
# once the match has started.
var sim_seed: int = 0


# --- Order legality ----------------------------------------------------------
#
# The single chokepoint for "can this unit do this order right now". The
# OrderService is the only thing that should construct Orders today
# (battle/orders/order.gd's header is explicit about that); once Phase 2
# lands, OrderService.issue_order() will call into this method before
# accepting the order, and reject with a feedback event if it returns false.
#
# Today (Phase 1) the method is defined and tested but no caller consults
# it. Adding the read-side is Phase 2. The test suite covers every
# (mode, order_type) pair so the matrix is locked in before anyone relies
# on it.
#
# `unit` is passed so a future expansion (e.g. "harvesters only" rules) can
# read unit metadata. The current implementation does not need it; the
# signature is future-proof.
func is_order_legal(_unit: Node, order_type: int) -> bool:
	match order_type:
		Order.Type.IDLE, Order.Type.HOLD:
			# Every mode allows stopping / holding - the cost of these is
			# zero and the player always has a "do nothing" option.
			return true
		Order.Type.MOVE, Order.Type.ATTACK, Order.Type.ATTACK_GROUND:
			# Combat and movement: available in all three modes. Test
			# Range uses these for player and AI dummies; Skirmish and
			# Operations obviously do.
			return true
		Order.Type.ATTACK_MOVE:
			# ATTACK_MOVE is the player command, the AI uses MOVE +
			# auto-engage. Both flows need it allowed in all three modes.
			return true
		Order.Type.HARVEST:
			# Gated on economy. Test Range has no resource fields, so
			# enabling harvest there would be a no-op that confuses
			# the player; the rule set reflects that.
			return enable_economy
		_:
			# Unknown order type. Fail closed - the same posture as
			# SettingsService.get() (per minimax.md §2.6) and
			# ModuleCatalog.module_exists(). A future order type added
			# without a branch here is silently rejected, which is
			# strictly better than silently accepted.
			return false


# --- Factory: Skirmish --------------------------------------------------------
#
# The standard pick-map-pick-roster path. Skirmish is the "everything on"
# default of the rule set, so the factory exists mostly to enforce the
# shape (required map_id) and to give the call site a sentence to read.
# All the per-mode flags stay at their default values.
static func skirmish(map_id: String, player_livery: String,
		enemy_livery: String, blueprint_paths: Array,
		difficulty: String = "normal") -> MatchRuleSet:
	var rs := MatchRuleSet.new()
	rs.mode = Mode.SKIRMISH
	rs.map_id = map_id
	rs.player_livery = player_livery
	# A FRESH livery every skirmish - see new_ai_livery_id() in livery.gd. Filled
	# here rather than trusting each caller, so a hand-built rule set in a test
	# gets a valid opponent paint scheme too.
	rs.enemy_livery = enemy_livery if enemy_livery != "" else LiveryScript.new_ai_livery_id()
	rs.selected_blueprint_paths = blueprint_paths.duplicate()
	rs.ai_difficulty = difficulty
	rs.physics_ticks_per_second = 30   # Fix A: double the unit ceiling
	# PR6 (2026-08-15). Skirmish is the playtest entry point; default to
	# the structured log on so a playtest always produces a file the
	# post-mortem can read. The harness sets it back to false for its
	# control runs.
	rs.log_profiling = true
	# Defaults are the Skirmish values; nothing else to flip.
	return rs


# --- Factory: Operations -----------------------------------------------------
#
# One stage of an operations campaign. The rule set holds the per-stage
# fields; the operations_manager autoload holds the campaign state across
# stages. The factory takes the minimal per-stage data; the campaign
# operations_id is the join key with the saved campaign file.
static func operations(map_id: String, player_livery: String,
		enemy_livery: String, blueprint_paths: Array,
		difficulty: String, operation_id: String,
		stage_index: int) -> MatchRuleSet:
	var rs := MatchRuleSet.new()
	rs.mode = Mode.OPERATIONS
	rs.map_id = map_id
	rs.player_livery = player_livery
	# ONE opponent identity for the whole campaign, keyed off operation_id, so
	# the enemy does not repaint between stages of the same operation.
	rs.enemy_livery = enemy_livery if enemy_livery != "" else LiveryScript.ai_livery_id_for(operation_id)
	rs.selected_blueprint_paths = blueprint_paths.duplicate()
	rs.ai_difficulty = difficulty
	rs.operation_id = operation_id
	rs.stage_index = stage_index
	# Operations: kill the enemy HQ, show AAR, then either advance to
	# the next stage or end the campaign. The director reads win_condition
	# + after_match_action from these fields.
	rs.win_condition = WinCondition.DESTROY_HQ
	rs.after_match_action = AfterMatchAction.SHOW_AAR
	rs.physics_ticks_per_second = 30   # Fix A: double the unit ceiling
	return rs


# --- Factory: Test Range -----------------------------------------------------
#
# The Design Lab's "Test in Arena" mode. One player unit, a handful of
# dummies, no economy, no production, no AI commander, no fog, chase
# camera. The world is small (the launcher will pick a hand-authored
# `test_range` map from MapCatalog - or, until the unified map catalog
# learns about test ranges, the legacy `Battlefield.tscn` map dict at
# battlefield.gd:19-38 is the temporary source).
#
# Win condition defaults to KILL_ALL_DUMMIES with no timer, which is the
# current "kill them all then go home" Test Range behaviour. SURVIVE_TIMER
# is reserved for a future "hold out for N minutes" playtest mode and is
# not set by this factory.
static func test_range(player_blueprint_path: String,
		enemy_blueprint_paths: Array,
		map_id: String = "test_range") -> MatchRuleSet:
	var rs := MatchRuleSet.new()
	rs.mode = Mode.TEST_RANGE
	rs.map_id = map_id
	# PLAYER_ID so reconstruct_vehicle reads the authored livery from
	# user://livery.json rather than rolling a random one; the dummies are
	# forced to team=1 in the launcher.
	#
	# The dummies' livery is stable per proving-ground session rather than fresh
	# per trip: this screen exists to judge YOUR design, and a target that
	# repaints itself every time you re-enter is a distraction.
	rs.player_livery = LiveryScript.PLAYER_ID
	rs.enemy_livery = LiveryScript.ai_livery_id_for("test_range")
	rs.player_blueprint_path = player_blueprint_path
	rs.enemy_blueprint_paths = enemy_blueprint_paths.duplicate()
	# Economy off. The player's harvester (if the design has one) is
	# still a valid mounted module, it just has nothing to harvest - the
	# rule set's HARVEST legality check returns false because
	# enable_economy is false, and the AI commander is not built so no
	# resource fields are claimed. This is the "Test Range is the full
	# engine with rules off" framing, and it is the property that makes
	# the unification a one-engine project.
	rs.enable_economy = false
	rs.enable_production = false
	rs.enable_player_build = false
	rs.enable_ai = false
	# Fog ON as of 2026-08-22. The dummies at HOLD_FIRE are not visible
	# until a player's unit walks into sensor range, which is exactly the
	# "range check" the player runs in the range. The previous no-fog
	# default made the unit's vision_range disc purely decorative: the
	# player could see the dummies from across the map regardless. With
	# fog on, the disc IS the sensor coverage that determines what the
	# player can shoot, which is the property the test range exists to
	# measure.
	rs.enable_fog_of_war = true
	# Camera + HUD. BattleHUD is on (selection rings, HP bars, the player's
	# HP label all live there). Minimap, production HUD, and admin menu
	# are off - there is nothing to put in them.
	rs.camera_mode = CameraMode.RTS
	rs.enable_minimap = false
	rs.enable_production_hud = false
	rs.enable_admin_menu = false
	# Game flow: kill all dummies, then back to the Lab. The dummy squad
	# dies by design (no commander respawns it), and the launcher wires
	# _on_match_ended to reload the Design Lab scene.
	rs.win_condition = WinCondition.KILL_ALL_DUMMIES
	rs.after_match_action = AfterMatchAction.RETURN_TO_LAB
	return rs


# --- to_dict / from_dict (stub) ----------------------------------------------
#
# The two preconditions for adding serialisation: (1) the rule set is a
# value the campaign save format will need to write/read, and (2) the
# tests below should be able to round-trip a rule set through a dict. The
# real save/load lives in Phase 2 alongside the Operations save path;
# leaving these as stubs is a known gap, not an oversight.
func to_dict() -> Dictionary:
	return {
		"mode": mode,
		"map_id": map_id,
		"player_livery": player_livery,
		"enemy_livery": enemy_livery,
		"selected_blueprint_paths": selected_blueprint_paths.duplicate(),
		"player_blueprint_path": player_blueprint_path,
		"enemy_blueprint_paths": enemy_blueprint_paths.duplicate(),
		"spawn_player_buildings": spawn_player_buildings.duplicate(true),
		"spawn_enemy_buildings": spawn_enemy_buildings.duplicate(true),
		"spawn_player_units": spawn_player_units.duplicate(true),
		"spawn_enemy_units": spawn_enemy_units.duplicate(true),
		"spawn_resource_fields": spawn_resource_fields.duplicate(true),
		"starting_credits": starting_credits,
		"enable_economy": enable_economy,
		"enable_production": enable_production,
		"enable_player_build": enable_player_build,
		"enable_ai": enable_ai,
		"enable_fog_of_war": enable_fog_of_war,
		"camera_mode": camera_mode,
		"enable_minimap": enable_minimap,
		"enable_production_hud": enable_production_hud,
		"enable_battle_hud": enable_battle_hud,
		"enable_admin_menu": enable_admin_menu,
		"win_condition": win_condition,
		"win_timer_seconds": win_timer_seconds,
		"after_match_action": after_match_action,
		"operation_id": operation_id,
		"stage_index": stage_index,
		"ai_difficulty": ai_difficulty,
		# Written unconditionally, including when it is still the 0 sentinel.
		# A dict captured before the match started honestly says "unseeded";
		# one captured after begins_match() carries the real seed and is
		# therefore replayable. Dropping the key when it is 0 would make those
		# two cases indistinguishable from a missing field on an older save.
		"sim_seed": sim_seed,
	}
