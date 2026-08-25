extends Node3D
# The match. Composition and nothing else.
#
# THE POINT OF THIS FILE IS ITS LENGTH. The system it replaces, skirmish.gd, is
# 3,423 lines because it owns the economy ledger, fog of war, the minimap image,
# the HUD, unit selection, building placement, navmesh rebaking, energy
# bookkeeping and the win condition all at once. Nothing there can be tested,
# reused or replaced without dragging in the rest.
#
# So the rule for this file: it assembles the world, holds references to the
# services, and forwards input. Any logic that could be asked a question in
# isolation belongs in a service. If this file passes ~400 lines, something has
# been put in the wrong place.
#
# DUCK-TYPED CONTRACTS. Units find their navmesh and their ground height by
# calling methods on their controller if it has them:
#
#     get_ground_nav_map() / get_water_nav_map()
#     get_amphibious_nav_map() / get_deep_water_nav_map()
#     terrain_height_at() / get_surface_type_at()
#
# The same six the old runtime exposed, with the same names, on purpose. It is
# what lets a unit built standalone in a test get no navmesh and fall back to
# direct steering without the test knowing anything about navigation.

const BlueprintManagerScript = preload("res://scripts/blueprint_manager.gd")
const MapCatalog = preload("res://scripts/map_catalog.gd")
const TerrainBuilder = preload("res://scripts/terrain_builder.gd")
const WorldScaleScript = preload("res://scripts/world_scale.gd")
const UnitScript = preload("res://scripts/battle/units/unit.gd")
const LayersScript = preload("res://scripts/battle/battle_layers.gd")
const MatchRuleSetScript = preload("res://scripts/match_rule_set.gd")
const SimRNG = preload("res://scripts/battle/sim_rng.gd")
const SelectionServiceScript = preload("res://scripts/battle/orders/selection_service.gd")
const AlertServiceScript = preload("res://scripts/battle/alert_service.gd")
const OrderServiceScript = preload("res://scripts/battle/orders/order_service.gd")
const FlowFieldServiceScript = preload("res://scripts/battle/movement/flow_field_service.gd")
const StanceScript = preload("res://scripts/battle/orders/stance.gd")
const EconomyServiceScript = preload("res://scripts/battle/economy/economy_service.gd")
const ProductionServiceScript = preload("res://scripts/battle/economy/production_service.gd")
const BuildingCatalogScript = preload("res://scripts/battle/economy/building_catalog.gd")
const StructureScript = preload("res://scripts/battle/buildings/structure.gd")
const PlacementServiceScript = preload("res://scripts/battle/buildings/placement_service.gd")
const MatchStatsScript = preload("res://scripts/battle/match_stats.gd")
const AfterActionReportScript = preload("res://scripts/after_action_report.gd")
const PerfHUDScript = preload("res://scripts/perf_hud.gd")
const PerfToastScript = preload("res://scripts/battle/perf_toast.gd")
const AdminMenuScript = preload("res://scripts/battle/hud/admin_menu.gd")
const DebugOverlayScript = preload("res://scripts/battle/hud/debug_overlay.gd")
const BattleFinishScript = preload("res://scripts/battle/battle_finish.gd")
const Profiler = preload("res://scripts/battle/battle_profiler.gd")
# Per-match structured log file. The file logger is opt-in via
# BattleLogger.enabled; the flip happens at the bottom of _ready() so a
# single Skirmish / Test Range / Operations run produces a log without
# the caller (match_setup, operations_draft, test_range_launcher) having
# to remember to enable it. The harness script tools/profile_battle_run.gd
# flips it off for its control run by calling BattleLogger.enabled = false
# before instantiating Battle.tscn.
const BattleLogger = preload("res://scripts/battle/battle_logger.gd")
const UnitAssemblyScript = preload("res://scripts/battle/units/unit_assembly.gd")
const VFXEffectsScript = preload("res://scripts/vfx_effects.gd")
const ResourceNodeScript = preload("res://scripts/resource_node.gd")
const ResourceFieldScript = preload("res://scripts/battle/economy/resource_field.gd")
const ResourceCatalogScript = preload("res://scripts/battle/economy/resource_catalog.gd")
const HUDRootScript = preload("res://scripts/hud/hud_root.gd")
const VisionServiceScript = preload("res://scripts/battle/vision/vision_service.gd")
const CommanderScript = preload("res://scripts/battle/ai/commander.gd")
const CounterDraftScript = preload("res://scripts/battle/ai/counter_draft.gd")
const SquadScript = preload("res://scripts/battle/ai/squad.gd")
const SquadManagerScript = preload("res://scripts/battle/ai/squad_manager.gd")
const ThreatAnalyzerScript = preload("res://scripts/battle/ai/threat_analyzer.gd")
const DesignCostingScript = preload("res://scripts/battle/economy/design_costing.gd")
const ModuleCatalog = preload("res://scripts/module_catalog.gd")
const Tokens = preload("res://scripts/ui_tokens.gd")

const PLAYER_TEAM := 0
const ENEMY_TEAM := 1

# Cached rule set for the current match. Resolved from /root/MatchConfig in
# _ready() and read by every later function that needs to know which mode
# the match is in (Skirmish / Operations / Test Range) or any per-mode
# override (cameras, factions, fog, starting credits, HUD toggles).
#
# WHY A MEMBER, NOT A LOCAL. _ready() awaits _setup_terrain(), and GDScript
# drops any local declared before an `await` once that await resumes - the
# same identifier becomes "not declared" past the await point at parse
# time. A function called from _ready() after the await (e.g. _setup_vision
# reading rs.enable_fog_of_war) would also need the local re-passed, which
# is a contract that scales poorly. A member costs one assignment and is
# visible everywhere for the lifetime of the match.
var _match_rule_set: MatchRuleSet = null

# Neighbour lookup grid. One cell comfortably exceeds the largest separation
# radius, so a unit only ever has to check its own cell and the eight around it.
const NEIGHBOUR_CELL := 8.0

# How far a right-click ray reaches. Longer than any map's diagonal so a click
# near the horizon at full zoom-out still finds ground.
const PICK_RAY_LENGTH := 4000.0

var map_id: String = MapCatalog.DEFAULT_MAP_ID
var current_map: Dictionary = {}
var player_faction: String = "industrialists"
var enemy_faction: String = "technocrats"

var bp_manager: Node = null
var camera: Camera3D = null
# The chase camera, when present, follows a single unit instead of
# framing the whole battlefield. Battle-system unification (Phase 3):
# Test Range sets this active and routes focus_unit to the player
# unit; Skirmish and Operations leave it inactive and use the RTS
# camera. Both are Camera3D children of Battle.tscn; only one has
# `current = true` at a time.
var chase_camera: Camera3D = null
# The unit the chase camera tracks. Set by _wire_test_range_camera()
# from the rule set's player roster. Null in any mode that is not
# Test Range.
var focus_unit: Node3D = null

var ground_nav_map: RID
var water_nav_map: RID
var amphibious_nav_map: RID
var deep_water_nav_map: RID
# Chunk 21: one region PER NAVMESH TILE, not one region for the whole
# ground/amphibious surface - see terrain_builder.gd's NAV_TILE_SIZE header
# comment. water/deep_water stay single-region; neither is ever rebaked
# mid-match (buildings don't carve water) and neither was the fidelity
# problem tiling exists to fix.
var _ground_nav_regions: Array = []
var _amphibious_nav_regions: Array = []
var _nav_tile_rects: Array = []
var _water_nav_region: RID
var _deep_water_nav_region: RID

var selection: SelectionService = null
var orders: OrderService = null
var alerts: AlertService = null
var flow_fields: FlowFieldService = null
var economy: EconomyService = null
var production: ProductionService = null
# The single battle HUD. See scripts/hud/hud_root.gd for what it replaced.
var hud: HUDRoot = null
var stats = null
var _perf_hud: CanvasLayer = null
var _perf_toast: CanvasLayer = null

# SKIRMISH_PERF_TROUBLESHOOTING.md §10.1. Counters behind the once-a-second
# `perf_sample` event in _process(). Rendered frames and physics ticks are
# counted separately and on purpose: the 2026-08-19 capture ran the sim at
# 14.56 Hz against a 30 Hz target while the screen managed 4.53 fps, and a
# single "fps" number would have hidden that they are two different problems.
var _render_frames: int = 0
var _physics_frames: int = 0
var _physics_frames_at_sample: int = 0
var _perf_sample_accum: float = 0.0
var admin_menu: Control = null
var debug_overlay: Control = null

# Emitted once the match is genuinely playable: terrain baked, units spawned, HUD
# built. SceneRouter waits on this before lifting its fade.
#
# WHY IT IS NEEDED. _ready() awaits _setup_terrain(), which makes _ready() a
# COROUTINE - it returns to the engine at that await and finishes many frames
# later. The router's "wait two frames for the incoming scene to build itself"
# is true for an ordinary scene and false for this one, so the fade lifted on a
# half-built match: bases already spawned (they are created before the await) and
# floating over an unbuilt map, with no terrain and no HUD yet.
#
# The flag exists alongside the signal for the race where the world finishes
# BEFORE the router gets around to awaiting - a signal already emitted is a
# signal that never arrives, and awaiting one hangs forever.
signal world_ready
var world_is_ready: bool = false

# Build progress, emitted during the world build phase that runs inside
# _ready() between the scene swap and world_ready. The SceneRouter's
# old load_progress stream was fraction 0..1 across the warm-list only;
# the world's own build (terrain bake, roster, units, HUD, AI) was an
# unaccounted-for middle. A new subscriber (the deploy gate's glass
# overlay) needs fraction 0..1 across the WHOLE sequence, so the
# match director publishes its own progress at each known milestone
# in _ready(). The 0..0.05 slice is the warm-list; this signal owns
# 0.05..1.00.
#
# Emissions land at the 8 milestones documented in
# docs/design/DEPLOY_GATE_REDESIGN.md §3.1 (resource nodes, bases,
# per-tile terrain, terrain done, roster, units, HUD, AI, ready).
# The 1.00 emission is the same moment world_is_ready flips, so a
# subscriber can use either as "the world is fully built" - the
# signal is the one that arrives on every subscriber, the flag is
# the one that handles the race where the router polled before
# the signal had a chance to land.
signal progress(fraction: float, label: String)

# Last emission of the progress signal, kept as a member so a
# late subscriber (e.g. the deploy gate, which is created after
# the first few emissions have already fired during _ready)
# can read the current value on connect rather than sitting
# at 0.0 until the next emission lands. The progress signal
# itself is fire-and-forget; this is the replay buffer.
var _last_progress_fraction: float = 0.0
var _last_progress_label: String = ""
# The last (label, fraction) WRITTEN TO THE LOG. Separate from the live
# replay buffer above because the bar's progress signal still fires on
# every emission - the dedup is a log-line policy, not a UI policy. A
# downstream subscriber reading the buffer for the build-hang dump still
# gets the most recent value; only the JSONL timeline is deduped.
var _last_logged_phase_label: String = ""
var _last_logged_phase_fraction: float = -1.0

# Public so a late subscriber can read the most recent progress
# value on connect. The pair is the same dict-shaped read the
# signal carries; the deploy gate uses it to seed its bar before
# the next live emission lands.
func get_last_progress() -> Dictionary:
	return {"fraction": _last_progress_fraction, "label": _last_progress_label}


# Internal: emit progress and update the replay buffer in one
# step. Every emission site in _ready() goes through this so
# the buffer and the signal cannot drift. Sites are
# documented in the table at the top of this file.
#
# 2026-08-16: also writes a `build_phase` event to the BattleLogger.
# The deploy gate is a UI surface; the BattleLogger is the post-mortem
# surface. A user reporting "the bar sat at 60% for 30 seconds and
# then timed out" deserves a log line that says "build_phase 0.60
# Plotting movement lanes - reached at t=14.2s" rather than a blank
# file. Cheap: one branch when the logger is enabled.
func _emit_progress(fraction: float, label: String) -> void:
	_last_progress_fraction = fraction
	_last_progress_label = label
	progress.emit(fraction, label)
	if BattleLogger.enabled and BattleLogger.log_path != "":
		# Dedup on (label, fraction). The 2026-08-19 log in
		# SKIRMISH_PERF_TROUBLESHOOTING.md §4 defect 5 had 308 build_phase
		# events with "Surveying terrain" appearing ~20x at an identical
		# timestamp - the deferred navmesh-bake callback at line ~848
		# fires per-tile completion and the rounding makes many of those
		# map to the same fraction. The bar's progress signal still fires
		# (UI may want each step), but the log entry is a post-mortem
		# timeline and a duplicate is noise. The progress itself is
		# still recorded in _last_progress_fraction/label for the build
		# hang dump.
		if _last_logged_phase_label == label and _last_logged_phase_fraction == fraction:
			return
		_last_logged_phase_label = label
		_last_logged_phase_fraction = fraction
		# log_phase is a JSONL line with the same fraction/label the
		# bar shows. Pairs with the BattleLogger's existing
		# section/hitch events; grep for "build_phase" to extract
		# the timeline.
		BattleLogger._write_event("build_phase", {
			"fraction": fraction,
			"label": label,
		})


var vision: VisionService = null
# Kept as an alias of `hud` so external callers and the rule set do not need
# to know the class changed.
var battle_hud: HUDRoot = null
var commander: Commander = null

# AI OVERHAUL: SquadManager per AI team. Coordinates multi-squads (MBG, Raider, Base Guard, Scout).
var _squad_managers: Dictionary = {}
var _squads: Dictionary = {}

# Per-team assigned base zone, indexed by team id.
#
# Set once during _spawn_bases() from MapCatalog.assign_base_zones() and held
# for the lifetime of the match. Two reasons for storing it rather than re-
# assigning on demand:
#   1. The assignment is a deterministic max-distance spread - re-running it
#      would just return the same value, but would couple every later query
#      to the same rng/state the orchestrator used on match start, and to
#      the map being still loaded. Holding the result means a UI layer that
#      wants to draw the zone ("drop HQ here") doesn't have to know either.
#   2. The human-placement hook (place_hq_for_human) needs to know which
#      zone belongs to the human, and that lookup happens in the input
#      layer, far from _spawn_bases. A precomputed table is the cheapest
#      contract for both.
var _team_base_zone: Dictionary = {}

# Set when the match has been decided. Stops the vision scan and the win check
# from running over a field nobody is playing on any more.
var game_over: bool = false

# The designs this team can field. Bundled defaults for now; hand-picked roster
# selection from MatchConfig arrives with the pre-match screen.
var roster: Array = []
# The AI's own designs, kept separate from the player's so a match is not a
# mirror and counter-picking has something to pick from.
var enemy_roster: Array = []

# 2026-08-10 (Chris): the pre-game HQ-placement change removed the
# auto-spawned refinery + 3 manufactories from the match start, so
# the player now has to BUILD them with their own credits. The bank
# is sized for "refinery + 2 manufactories of your choice" - the
# smart opening the user described, where the refinery comes with
# the free roster harvester and the 2 manufactories are an actual
# choice (2 light = cheap + flexible, 2 heavy = expensive but
# immediate late-game access).
#
# Worst case (refinery + 2 heavy): 150 + 320 + 320 = 790 metal,
# 0 + 85 + 85 = 170 crystal = 1130 credits at the 2x crystal
# rate. 1200 is 70 credits of buffer past that, small enough that
# a player who wants a power plant on top has to make a real
# choice between the heavy + power-plant combination and the
# refinery + 2 light + power-plant combination, which is what the
# "choice" framing implies.
#
# Pre-change bank was 750 (the old 450 metal + 150 crystal at 2x),
# which bought a single refinery and a single light manufactory with
# nothing left over - effectively forcing the rest of the
# manufactories to be built slowly from income. 1200 buys the
# "smart opening" the new flow is balanced around.
const STARTING_CREDITS := 1200

# The player's build bar tops out here, matching the old runtime's loadout limit.
const ROSTER_LIMIT := 12
# How many of the player's own saved designs get auto-drafted when they did not
# hand-pick a roster. Deliberately short of ROSTER_LIMIT so bundled defaults
# still fill the remainder - a roster of eight half-finished experiments with no
# harvester is not a playable match.
const ROSTER_AUTOPICK_LIMIT := 8
# A match whose roster cannot mine is unwinnable, so this is force-added when
# nothing else in the roster harvests.
const FALLBACK_HARVESTER := "res://data/loadout/magpie_ore_hauler.json"

# Drag-select state. A press below SelectionService.DRAG_THRESHOLD_PX resolves as
# a click instead.
var _drag_origin := Vector2.ZERO
var _dragging := false
# Right-click moves a unit; right-click + drag orbits the chase camera
# in Test Range. The two are disambiguated by whether the press and
# release positions are within DRAG_CLICK_THRESHOLD pixels of each
# other - a stationary click issues a move order, a dragged click is
# owned by the camera. Pre-existing left-click drag (selection
# rectangle) is unchanged.
const DRAG_CLICK_THRESHOLD: float = 4.0
var _right_press_pos: Vector2 = Vector2.ZERO
var _right_press_active: bool = false
var _right_dragged: bool = false
var _selection_rect: Panel = null

# Armed one-shot modes: the next right-click means something other than "move".
# Same convention OpenRA's sidebar icons use, and the same one the old runtime
# used for repair/sell.
var _attack_move_armed := false
var _hud_hint: Label = null

# cell -> Array of units, rebuilt each physics tick. Separation asks this rather
# than scanning every unit, which would be O(n^2) per frame across the army.
var _neighbour_grid: Dictionary = {}


func _ready() -> void:
	# The hull-template cache is static and therefore outlives a match. Dropped at
	# the start of every one, so a design re-saved in the Lab between matches is
	# rebuilt rather than served from the previous match's geometry.
	UnitAssemblyScript.clear_hull_cache()

	# End the previous match's log (if any) when re-entering the scene. A
	# crash-and-reload returns to Battle.tscn without an explicit
	# end_match, so _ready acts as the safety net. BattleLogger is robust to
	# _file being null.
	BattleLogger.end_match()

	# Resolve the rule set FIRST, before anything that might read it
	# (notably _evaluate_logging_flags below and the camera-mode gate
	# further down). The previous design assigned _match_rule_set inside
	# the unification block lower in _ready, but _evaluate_logging_flags
	# runs earlier than that, so the rule set's log_profiling field was
	# never read by the logging gate. This was the silent cause of the
	# "no log file written" reports on Skirmish playtests where the
	# rule set had log_profiling = true. The Skirmish factory was
	# writing the right value; the director was reading it before it
	# existed. Loading the rule set up front closes the timing gap.
	var match_config := get_node_or_null("/root/MatchConfig")
	if match_config != null and "rule_set" in match_config:
		_match_rule_set = match_config.rule_set

	# 2026-08-16: open the log at the START of the build, not the end. The
	# previous design opened the log when world_ready fired, which left a
	# 0-byte file if _ready() hung somewhere between deploy-gate appearance
	# and the world-ready signal. The deploy gate has a 30s timeout that
	# forces ready, so a real hang reads as a "stuck" bar to the player
	# and a blank log to the post-mortem. The fix: _evaluate_logging_flags()
	# at the top of _ready opens the log with the build_started event;
	# the post-world_ready section now does Profiler.reset() only (the
	# log file is already open and writing). A hang shows up in the log
	# because build_started already landed and the per-tick
	# build_phase emissions after this point trace where the hang was.
	# PERF_TESTING_RIG.md Fix A. Applied before _evaluate_logging_flags so
	# BattleLogger.begin_match() can record the resolved tick rate in the
	# MATCH_BEGIN header. Previously the assignment happened at line ~394
	# (after the log was already open), so a Skirmish running at 30 Hz
	# recorded `engine_ticks_per_second: 60` in the header - making Fix A
	# look like it had failed when it had not. The
	# 2026-08-19 log in SKIRMISH_PERF_TROUBLESHOOTING.md §4 defect 2
	# is the one that named this. Test Range's rule set still has the
	# default 60, so headless tooling is unchanged.
	#
	# The rule set is resolved above this point (see the match_config /
	# _match_rule_set block at the top of _ready), so reading it here is
	# the same read the assignment at ~line 394 used to do.
	var tick_rate: int = _match_rule_set.physics_ticks_per_second if _match_rule_set != null else 60
	Engine.physics_ticks_per_second = tick_rate
	if tick_rate != 60:
		print("[match_director] physics_ticks_per_second = %d" % tick_rate)

	_evaluate_logging_flags()
	_emit_progress(0.01, "Initializing command systems")
	# PR9 (2026-08-17). Yield at the first emission so the deploy-gate
	# bar can paint frame 0 before any of the heavy sync work below
	# runs. Without this, the bar shows 0% for the entire _ready()
	# build (60+ seconds in the F4 dump from the 215 s playtest) and
	# then jumps to 100% when world_is_ready fires - which is what
	# the user reported as a stuck bar.
	await get_tree().process_frame

	bp_manager = BlueprintManagerScript.new()
	bp_manager.name = "BlueprintManager"
	add_child(bp_manager)

	camera = get_node_or_null("Camera3D")
	chase_camera = get_node_or_null("ChaseCamera")
	# match_config and _match_rule_set are both resolved at the top of
	# _ready (see the block above _evaluate_logging_flags), so the
	# camera-mode gate, the tick_rate read, and the unification block
	# below all see the same source. The previous design had
	# match_config declared here as a local and _match_rule_set
	# assigned in two places lower in this function; that worked
	# because nothing in _ready above this point needed the rule set.
	# The 2026-08-18 logging fix moved both resolutions to the top, so
	# the local declaration and the duplicate assignments are gone.
	#
	# The Engine.physics_ticks_per_second assignment itself moved up
	# too: see the block just before _evaluate_logging_flags(). It has
	# to land before BattleLogger.begin_match() so the header's
	# engine_ticks_per_second field is the rate the match will actually
	# run at, not the engine default the director overwrote a moment
	# later.

	# Battle-system unification (Phase 3). The rule set, when set,
	# picks which camera is `current`. Test Range activates the chase
	# camera and wires it to the player unit; Skirmish and Operations
	# leave the RTS camera active (the chase camera is null-defended
	# so a Test Range launcher that forgets to set focus_unit is
	# harmless - the camera sits at the world origin and waits).
	if _match_rule_set != null \
			and chase_camera != null and is_instance_valid(chase_camera):
		if _match_rule_set.camera_mode == MatchRuleSetScript.CameraMode.CHASE:
			chase_camera.current = true
			if camera != null and is_instance_valid(camera):
				camera.current = false
		else:
			chase_camera.current = false
			if camera != null and is_instance_valid(camera):
				camera.current = true

	# Battle-system unification (Phase 5, 2026-08-10). The seven legacy
	# pre-match fields on MatchConfig (selected_map_id, player_faction,
	# enemy_faction, selected_blueprint_paths, ai_difficulty, starting_credits)
	# are retired. The per-mode rule set written by match_setup.gd /
	# operations_draft.gd / test_range_launcher.gd is the single source
	# of truth; its fields are read here, with the rule set's own defaults
	# (set in MatchRuleSetScript.skirmish/operations/test_range) carrying
	# the case where the caller did not specify a value. A test path that
	# instantiates Battle.tscn without the autoload at all still gets a
	# null match_config and falls through to the hardcoded director
	# defaults - the same posture every prior phase preserved.
	# _match_rule_set was already assigned at the top of _ready (see the
	# block above _evaluate_logging_flags), so the previous re-assignment
	# here is gone; the field reads below use the up-front value.
	if _match_rule_set != null:
		if _match_rule_set.map_id != "":
			map_id = _match_rule_set.map_id
		if _match_rule_set.player_faction != "":
			player_faction = _match_rule_set.player_faction
		if _match_rule_set.enemy_faction != "":
			enemy_faction = _match_rule_set.enemy_faction

	# SEED THE SIMULATION STREAM HERE, and nowhere else. This has to happen
	# after the rule set is resolved (it carries sim_seed) and BEFORE anything
	# spawns: auto_weapon.gd's reacquire stagger and its initial fire-phase
	# offset are both sim draws taken during _ready(), so a unit built ahead of
	# this line would be drawing from the previous match's tail. A null rule set
	# is fine - begin_match() rolls a fresh seed and writes it back, which is
	# what the Test Range and the headless fixtures get. SimRNG.current_seed()
	# is then the number a replay header or a netcode handshake would carry.
	SimRNG.begin_match(_match_rule_set)

	current_map = MapCatalog.get_map(map_id)
	# CORE_DESIGN_LANGUAGE.md §3.2: pan/middle-drag speed track world_scale so
	# a genuinely bigger map doesn't also feel proportionally slower to move
	# around in - duck-typed the same way the rest of this file treats the
	# camera, so a camera without the property (an older scene, a test stub)
	# degrades to its own default rather than erroring.
	if camera and "world_scale" in camera:
		camera.world_scale = WorldScaleScript.for_map(current_map)
	_scale_lighting_to_world()

	orders = OrderServiceScript.new()
	flow_fields = FlowFieldServiceScript.new()

	economy = EconomyServiceScript.new()
	production = ProductionServiceScript.new()
	production.setup(economy, self)
	for t in [PLAYER_TEAM, ENEMY_TEAM]:
		# 2026-08-10: the per-team starting credit bank comes from the
		# per-mode rule set, with a sentinel of -1 meaning "use the
		# director's own default" (STARTING_CREDITS, 750). The legacy
		# MatchConfig.starting_credits field is retired.
		var start_credits: int = STARTING_CREDITS
		if _match_rule_set != null and _match_rule_set.starting_credits >= 0:
			start_credits = _match_rule_set.starting_credits
		economy.add_team(t, start_credits)
		production.add_team(t)
	production.unit_completed.connect(_on_unit_completed)
	production.structure_ready.connect(_on_structure_ready)

	# Buildings BEFORE the bake, so their footprints go into the first navmesh
	# rather than needing an immediate second one. A rebake inside the first few
	# startup frames leaves a window where a unit's very first path query runs
	# before NavigationServer3D has resynced, and the unit drives into the lake.
	_emit_progress(0.02, "Calibrating rule set")
	await get_tree().process_frame
	await _spawn_resource_nodes()
	# 2026-08-13: deploy-gate progress emissions. See the `progress` signal
	# header at :147-160 for the 0..1 fraction contract. Fractions below
	# under-weight the early build steps (resource nodes, bases) so the
	# deploy gate's bar does not stall at 10% for 3 seconds while the
	# terrain bake runs - the bake is the wall-clock-dominant phase and
	# owns 0.10..0.55 of the bar.
	_emit_progress(0.05, "Locating resource deposits")
	await get_tree().process_frame
	_spawn_bases()
	_emit_progress(0.10, "Surveying build sites")
	await get_tree().process_frame
	# 2026-08-16: sub-milestone in the terrain-bake span, so the bar
	# moves while _setup_terrain() awaits. Otherwise the bar sits at
	# "Surveying build sites" for the entire terrain phase (which can
	# be 20+ seconds on a 4× world_scale map), which is what the user
	# reported as a stuck bar.
	_emit_progress(0.12, "Compiling lighting")
	await get_tree().process_frame

	# Center the camera on the player's base zone or origin
	var target_focus := Vector3.ZERO
	var player_zone_id: String = _team_base_zone.get(PLAYER_TEAM, "")
	if player_zone_id != "":
		var zone: Dictionary = MapCatalog.get_base_zone(current_map, player_zone_id)
		target_focus = zone.get("center", Vector3.ZERO)
	_on_group_recentre(target_focus)
	await get_tree().process_frame

	# 2026-08-16: finer sub-milestones inside the 0.12..0.55 stretch.
	# The terrain bake has four observable phases (mesh build,
	# navmesh bake, region split, visual scatter). Each one gets a
	# distinct label so a stalled bar tells us which sub-phase hung.
	# _setup_terrain() itself emits the 0.10..0.55 stretch internally
	# via tile_frac; the sub-milestones here are the wall-clock-named
	# beats the player reads while the bake is running.
	_emit_progress(0.13, "Sculpting terrain mesh")
	await _setup_terrain()
	_emit_progress(0.60, "Plotting movement lanes")
	await get_tree().process_frame
	_emit_progress(0.62, "Indexing sensor grid")
	await get_tree().process_frame

	# After the bake: the flow field samples the ground navmesh for passability,
	# so it needs the map RID that _setup_terrain() just produced.
	flow_fields.setup(ground_nav_map, current_map.get("map_half_extents", 80.0), WorldScaleScript.for_map(current_map))

	selection = SelectionServiceScript.new()
	selection.setup(camera, get_world_3d().direct_space_state, PLAYER_TEAM)
	selection.group_recentre_requested.connect(_on_group_recentre)

	alerts = AlertServiceScript.new()
	add_child(alerts)

	_setup_vision()
	_emit_progress(0.65, "Standing up awareness grid")
	await get_tree().process_frame

	_load_roster()
	_emit_progress(0.70, "Indexing designs")
	await get_tree().process_frame
	# 2026-08-16: sub-milestone for the unit spawn phase. The deploy
	# gate had 70%->80% with no movement, which on a populated roster
	# (12+ units) reads as a 2-3 second stall. The unit spawn is also
	# the only phase that runs unit.setup() (which is the multi-frame
	# per-unit work the BattleLogger records), so logging the
	# transition is worth the line.
	_emit_progress(0.74, "Settling structures")
	await get_tree().process_frame
	await _spawn_starting_units()
	_emit_progress(0.80, "Preparing vehicle systems")
	await get_tree().process_frame
	_emit_progress(0.83, "Raising HUD")
	_build_hud()
	_emit_progress(0.90, "Raising command deck")
	await get_tree().process_frame
	# 2026-08-16: 0.90->0.95 was a 5% gap with no movement, including
	# the AI commander setup (which can be a few hundred ms on a
	# populated base). The "Briefing opposition" label was applied to
	# ALL the work in that gap, which is the source of the "stuck"
	# feel when the AI takes a moment.
	_emit_progress(0.92, "Indexing telemetry")
	await get_tree().process_frame
	stats = MatchStatsScript.new()
	# Battle-system unification (Phase 2). Test Range's rule set has
	# enable_ai=false, which is the per-mode gate for "does the AI
	# commander run at all". Skirmish and Operations both leave it on
	# (the default), so the legacy behaviour is unchanged for the modes
	# that exist today. The gate is forward-looking: Phase 3 wires the
	# Test Range launcher to use Battle.tscn, and this branch is what
	# makes Test Range not spin up a Commander at all.
	# 2026-08-10: rule set is the single source; legacy ai_difficulty fallback
	# is gone. enable_ai + ai_difficulty both come from the rule set, with
	# the rule set's own defaults (true / "normal") carrying the no-rule-set
	# case via the same duck-typed null guard.
	var ai_enabled: bool = true
	var ai_diff: String = "normal"
	var ai_doc: String = ""
	if _match_rule_set != null:
		ai_enabled = _match_rule_set.enable_ai
		ai_diff = _match_rule_set.ai_difficulty
		ai_doc = _match_rule_set.ai_doctrine
	if ai_enabled:
		commander = CommanderScript.new()
		commander.setup(self, ENEMY_TEAM, ai_diff)
		if not ai_doc.is_empty():
			commander.doctrine = ai_doc
		# PR5 (2026-08-15). The commander is now event-driven (see
		# commander.gd's set_dirty()). Wire the structure-built event so
		# the AI re-decides when something on the field actually changes,
		# rather than only on its 2 s periodic tick. Unit deaths are
		# routed through record_unit_lost(), which is called for every
		# team - we only flag the commander for enemy losses (its own
		# team's losses already factor in via the structure count change).
		structure_built.connect(func(_t: int, _k: String):
			if commander != null:
				commander.set_dirty())
	# Always emit the 0.95 step, even when the AI is disabled (Test
	# Range's rule set has enable_ai=false). The label is the
	# "briefing" beat regardless of whether there is an opponent
	# commander to brief; the jump from 0.90 to 1.00 without it
	# would be a 10% step the bar smooths over awkwardly.
	_emit_progress(0.95, "Briefing opposition")
	await get_tree().process_frame
	_emit_progress(0.97, "Standing by")
	await get_tree().process_frame
	# _setup_audio() was moved from after world_ready (2026-08-16) so
	# the audio system is live before the deploy gate fires - the gate
	# is the "everything is ready" beat, and audio is part of everything.
	_setup_audio()
	_emit_progress(0.99, "Awaiting deploy")
	await get_tree().process_frame

	# 1.00 is the LAST emission. world_is_ready flips first so the
	# flag-based poll in scene_router.gd:_await_world_ready exits on
	# its next tick; world_ready signal fires next for any direct
	# subscribers; the progress(1.0, "Ready") emission lands last so
	# the deploy gate transitions to its ready state in the same
	# order it was reading the rest of the stream.
	world_is_ready = true
	world_ready.emit()
	_emit_progress(1.0, "Ready")

	# Start the match instrumentation HERE - after world_ready, so the
	# section-timing profile covers only the live match and not the
	# one-time build phase inside _ready. The build phase is fast but it
	# dominates "first frame" timings (terrain bake, mesh bakes, unit
	# spawns), which would otherwise make every section look expensive
	# and drown out the live-match stutter the logger exists to find.
	#
	# The logger file is already open (2026-08-16: opened at the
	# top of _ready via _evaluate_logging_flags, so a hang in the
	# build phase still leaves a usable log). Profiler.reset() zeroes
	# the in-memory per-section totals so the live-match data is not
	# contaminated by anything the build phase recorded.
	Profiler.reset()


# --- Audio -------------------------------------------------------------------
#
# set_combat_intensity() feeds a combat-intensity mixer in AudioManager. When
# the skirmish track has separate bed/rhythm/lead stems (the procedural
# renderer in tools/audio/tracks/skirmish.py), it raises the rhythm and lead
# layers as a real engagement heats up. The currently-shipped soundtrack
# (tools/audio/curated_music.py) is finished single-master tracks with no stem
# split, so this call is a no-op for the extra layers and the track just
# plays - still correct, just without the dynamic layering. See
# scripts/audio_manager.gd's _refresh_music_targets.

var _audio: Node = null
# Decays toward zero every frame; damage events push it back up. Effectively a
# leaky integrator over "how much shooting is happening", which is a far better
# signal for the music than unit counts or proximity - it only rises when shots
# are actually landing.
var _combat_heat: float = 0.0
const COMBAT_HEAT_DECAY := 0.22        # per second
const COMBAT_HEAT_PER_DAMAGE := 0.014  # per point of damage dealt
var _ambience_check := 0.0


func _setup_audio() -> void:
	_audio = get_node_or_null("/root/AudioManager")
	if _audio == null:
		return
	_audio.play_music("skirmish")
	_audio.set_combat_intensity(0.0)
	match_ended.connect(_on_match_ended_audio)
	if production != null:
		production.unit_completed.connect(_on_unit_completed_audio)
		production.structure_ready.connect(_on_structure_ready_audio)


func _on_match_ended_audio(winning_team: int) -> void:
	if _audio == null:
		return
	_audio.play_music("victory" if winning_team == PLAYER_TEAM else "defeat")


func _on_unit_completed_audio(team: int, _queue: String, _blueprint: Dictionary) -> void:
	if _audio == null or team != PLAYER_TEAM:
		return
	_audio.play_sfx("unit_rollout")
	_audio.play_voice("radio_ready")


func _on_structure_ready_audio(team: int, _queue: String, _job: Dictionary) -> void:
	if _audio == null or team != PLAYER_TEAM:
		return
	_audio.play_sfx("construct_done")


func _tick_audio(delta: float) -> void:
	if _audio == null:
		return
	_combat_heat = maxf(0.0, _combat_heat - COMBAT_HEAT_DECAY * delta)
	_audio.set_combat_intensity(_combat_heat)

	# Ambience follows the surface under the camera. Sampled a few times a
	# second rather than per frame: the answer changes only when the player pans
	# across a biome boundary, and get_surface_type_at does real work.
	_ambience_check -= delta
	if _ambience_check <= 0.0:
		_ambience_check = 0.5
		var cam := get_viewport().get_camera_3d() if is_inside_tree() else null
		if cam != null:
			var surface := get_surface_type_at(cam.global_position)
			if surface != "":
				_audio.play_ambience("ambience_" + surface)


# Vision runs on its own timer rather than in _physics_process. The scan is
# O(viewers x targets) per team and its answer changing three times a second is
# imperceptible; running it per frame would be the single most expensive thing in
# the match for no visible gain.
func _setup_vision() -> void:
	vision = VisionServiceScript.new()
	vision.setup(self, PLAYER_TEAM, current_map.get("map_half_extents", 80.0), WorldScaleScript.for_map(current_map))
	# _match_rule_set is the cached rule set from _ready(). Fog of war is
	# the per-mode opt-out: Skirmish / Operations leave it on (the default
	# when no rule set is mounted), Test Range's launcher turns it off so
	# the dummies are visible across the whole range.
	if _match_rule_set != null and not _match_rule_set.enable_fog_of_war:
		return
	add_child(vision.build_shroud())

	# The HUD refreshes on the SAME tick as vision, deliberately. The minimap
	# draws what the player can see, so refreshing it more often than visibility
	# is recomputed just redraws the same answer, and refreshing it less often
	# would show blips the fog has already taken away.
	var timer := Timer.new()
	timer.name = "VisionTick"
	timer.wait_time = VisionServiceScript.TICK_INTERVAL
	timer.timeout.connect(_on_vision_tick)
	add_child(timer)
	timer.start()


func _on_vision_tick() -> void:
	if game_over:
		return
	var t := Profiler.start()
	vision.tick()
	Profiler.stop("vision", t)
	# The HUD is NOT refreshed from here any more. hud_root.gd owns one clock
	# and polls its own regions - the map at 20 Hz, the panels at 5 Hz - and
	# its fog composite is gated on VisionService.shroud_version, so it picks
	# this tick up on its own. Driving it from here as well meant the vision
	# tick paid for a full minimap rebuild whether or not anything moved.


# --- World ------------------------------------------------------------------

# Bakes the four navmeshes and dresses the terrain.
#
# The bake is ~4 seconds on lake_crossing. In the real game the four surfaces go
# one per frame so the message loop keeps pumping - four seconds inside a single
# frame is what made Windows grey the title bar and report the app as not
# responding. Headless keeps the single blocking call, because a test that
# add_child()s this scene and immediately reads state must not have _ready()
# suspend part-way through.
#
# No buildings exist yet in Phase 0, so the first bake carves no holes. When base
# building lands in Phase 2 the starting structures must be spawned BEFORE this
# runs, so their footprints go into the FIRST bake - a second same-frame rebake
# leaves a window where a unit's very first path query runs before
# NavigationServer3D has resynced, and the unit wanders into the lake.
# Playtest: "maybe some lighting tricks can make [elevation] more apparent."
#
# Both of the settings below were authored in Battle.tscn against a world that
# has since grown, and both are measured in absolute world units, so neither
# followed it - the same class of scale-exposed constant as the fog shroud
# height and the AI threat radius before them.
#
# directional_shadow_max_distance is the bigger one and was never set at all,
# leaving Godot's default of 100 world units. On an open_plains grown to 840
# half-extent, terrain shadows simply stopped existing a short way out from the
# camera, so the relief that did exist cast nothing to read it by - which is
# most of why elevation looked flat regardless of how deep it actually was.
#
# ssao_radius is the sampling radius for ambient occlusion. At 0.8 units it
# only ever found tiny crevices; a ravine 8 units deep and tens of units wide
# is invisible to it. Widening it is what makes a dip read as a dip even where
# no direct shadow falls into it.
#
# Driven off WorldScale rather than re-authored in the .tscn so it tracks any
# future scale change instead of needing to be re-tuned by hand each time -
# and duck-typed/null-guarded like every other optional node here, so a test
# stub or a scene without them degrades rather than erroring.
const SHADOW_DISTANCE_BASE: float = 320.0
const SSAO_RADIUS_BASE: float = 0.8

func _scale_lighting_to_world() -> void:
	var env_data: Dictionary = current_map.get("environment", {})
	var light := get_node_or_null("DirectionalLight3D") as DirectionalLight3D
	if light:
		light.directional_shadow_max_distance = WorldScaleScript.scaled_f(SHADOW_DISTANCE_BASE, current_map)
		if env_data.has("sun_color"):
			light.light_color = env_data["sun_color"]
		if env_data.has("sun_energy"):
			light.light_energy = float(env_data["sun_energy"])

	var world_env := get_node_or_null("WorldEnvironment") as WorldEnvironment
	if world_env and world_env.environment:
		var env := world_env.environment
		env.ssao_radius = WorldScaleScript.scaled_f(SSAO_RADIUS_BASE, current_map)
		if env_data.has("ambient_light_energy"):
			env.ambient_light_energy = float(env_data["ambient_light_energy"])
		if env_data.has("fog_enabled"):
			env.fog_enabled = bool(env_data["fog_enabled"])
			if env_data.has("fog_density"):
				env.fog_density = float(env_data["fog_density"])
			if env_data.has("fog_aerial_perspective"):
				env.fog_aerial_perspective = float(env_data["fog_aerial_perspective"])
		if env_data.has("sky_color") and env.sky and env.sky.sky_material is ProceduralSkyMaterial:
			var sky_mat := env.sky.sky_material as ProceduralSkyMaterial
			sky_mat.sky_top_color = env_data["sky_color"]
			if env_data.has("horizon_color"):
				sky_mat.sky_horizon_color = env_data["horizon_color"]

# SKIRMISH_PERF_TROUBLESHOOTING.md §10.6. This function IS the load screen:
# across 631 runs on 2026-08-19 the "Sculpting terrain mesh" phase - which is
# exactly `await _setup_terrain()` - averaged 21.2 s and peaked at 81.9 s, while
# every other build phase came in under 0.4 s. The open question is why 7 runs
# built lake_crossing in ~3 s against a 27.8 s median for the same map, with
# concurrency, viewport and time-of-day all ruled out.
#
# The sub-steps below are timed to BattleLogger.log_build_step rather than to
# Profiler sections because the director calls Profiler.reset() once the world
# is ready, which discards anything recorded here (see battle_logger.gd's
# log_build_step header). Each step is measured with its own wall clock so a
# single capture says which one carries the 21 s - and, on a fast run, which one
# is being skipped.
# The node handed to TerrainBuilder's frame-chunked build steps as their
# "ticker" (the node whose process_frame they yield on). Null when headless:
# a headless probe that add_child()s this scene and immediately reads state
# must not have the build suspend across frames it does not pump, so there
# the terrain mesh and scatter stay single-call synchronous - the same
# posture the navmesh branch below already takes. In a real window `self`
# is passed, which is what keeps the loading screen animating through the
# two biggest synchronous freezes of the world build.
func _build_ticker() -> Node:
	if DisplayServer.get_name() in ["headless", "dummy"] or "--headless" in OS.get_cmdline_args() or "--headless" in OS.get_cmdline_user_args():
		return null
	return self

func _setup_terrain() -> void:
	# Build visual ground mesh and surrounding terrain skirt first
	var ground := get_node_or_null("Ground")
	if ground:
		ground.position = Vector3.ZERO
		var _t_mesh := Time.get_ticks_usec()
		var generated: Dictionary = await TerrainBuilder.build_ground_visual_mesh(current_map, _build_ticker())
		BattleLogger.log_build_step("terrain.ground_visual_mesh",
			float(Time.get_ticks_usec() - _t_mesh) / 1000.0,
			{"map_id": str(current_map.get("id", map_id))})
		var mesh_inst: MeshInstance3D = ground.get_node_or_null("MeshInstance3D")
		if mesh_inst:
			mesh_inst.mesh = generated.mesh
			var _t_mat := Time.get_ticks_usec()
			mesh_inst.material_override = TerrainBuilder.build_ground_material_heightmap(
				current_map.get("ground_color", Color(0.2, 0.26, 0.21)), current_map)
			BattleLogger.log_build_step("terrain.ground_material",
				float(Time.get_ticks_usec() - _t_mat) / 1000.0)
		var col: CollisionShape3D = ground.get_node_or_null("CollisionShape3D")
		if col:
			# SKIRMISH_PERF_TROUBLESHOOTING.md §11.5 + §12. The flat_ground_collider
			# flag swaps the heightmap collider for a single BoxShape3D on y=0.
			# The visual mesh is unchanged (it still shows whatever hills the map
			# author drew), but the per-unit `move_and_slide` cost drops to
			# "convex hull vs flat plane" - the cheapest narrow-phase test the
			# physics server has. The diff in the `units` profiler section
			# between a real run on the same map and a flagged run is the
			# ground-heightmap contribution to the late-game collision cost.
			# Off by default; a per-map opt-in so the visual stays accurate for
			# every other map. Set on test_range for the canonical experiment
			# (it has no hills anyway, so the visual stays correct).
			if bool(current_map.get("flat_ground_collider", false)):
				var half: float = current_map.get("map_half_extents", 80.0)
				var flat_box := BoxShape3D.new()
				flat_box.size = Vector3(half * 2.0, 1.0, half * 2.0)
				col.shape = flat_box
				col.scale = Vector3.ONE
				col.position = Vector3(0.0, -0.5, 0.0)
			else:
				col.shape = generated.shape
				col.scale = generated.get("collision_scale", Vector3.ONE)
				col.position = Vector3.ZERO

	await get_tree().process_frame

	var nav: Dictionary
	var _t_holes := Time.get_ticks_usec()
	var holes := _building_holes()
	BattleLogger.log_build_step("terrain.building_holes",
		float(Time.get_ticks_usec() - _t_holes) / 1000.0, {"holes": holes.size()})
	var _t_nav := Time.get_ticks_usec()
	if DisplayServer.get_name() in ["headless", "dummy"] or "--headless" in OS.get_cmdline_args() or "--headless" in OS.get_cmdline_user_args():
		nav = TerrainBuilder.build_navmeshes(current_map, holes)
		# The synchronous path is one call, so dispatch and wait are the same
		# span. Logged under the same two names as the deferred path with the
		# wait at zero, so a reader does not have to special-case headless.
		BattleLogger.log_build_step("terrain.navmesh_build_sync",
			float(Time.get_ticks_usec() - _t_nav) / 1000.0, {"tiles": 0})
	else:
		nav = TerrainBuilder.build_navmeshes_deferred(current_map, holes)
		BattleLogger.log_build_step("terrain.navmesh_dispatch",
			float(Time.get_ticks_usec() - _t_nav) / 1000.0,
			{"tiles": nav["pending"].size()})
		var _t_wait := Time.get_ticks_usec()
		var remaining := {"n": nav["pending"].size()}
		var total_tiles: int = remaining["n"]
		var done: Dictionary = {"n": 0}
		# SKIRMISH_PERF_TROUBLESHOOTING.md §5 Track A / §6 item 3.
		# The per-tile completion callback runs on the main thread
		# between physics ticks (it's a Callable scheduled from the
		# Recast worker). The profiler's end_frame() fires from
		# _physics_process, so any work the callback does is attributed
		# to the next physics frame's <untimed> - which is why the
		# 2026-08-19 log had 36 s of <untimed> in the first 90 frames
		# and the 2026-08-19T19-00-03 capture had a 28.9 s boot stall
		# that named nothing.
		#
		# The section is per-callback, so the readout answers the
		# "one slow tile or N normal ones" question directly. If the
		# mean is small and the worst is large, one tile is the cost
		# and the fix is per-tile (coarsen, timeout, skip). If the
		# mean is large, the callback itself is doing too much work
		# per tile (e.g. shader compile, material upload).
		for entry in nav["pending"]:
			TerrainBuilder.bake_pending_entry_async(entry, nav["cell_size"], func():
				var _t := Profiler.start()
				done["n"] += 1
				if total_tiles > 0:
					var tile_frac: float = float(done["n"]) / float(total_tiles)
					_emit_progress(0.10 + tile_frac * 0.45, "Surveying terrain")
				remaining["n"] -= 1
				Profiler.stop("navmesh_boot_bake", _t))
		while remaining["n"] > 0:
			await get_tree().process_frame
		# The wall-clock cost of waiting out the Recast workers, against the
		# tile count that produced it. Dividing the two gives per-tile cost,
		# which is what distinguishes "one pathological tile" from "this map
		# simply has 400 of them" - and a ~3 s run from a ~28 s one.
		BattleLogger.log_build_step("terrain.navmesh_wait",
			float(Time.get_ticks_usec() - _t_wait) / 1000.0,
			{"tiles": total_tiles})

	ground_nav_map = nav.ground_map
	water_nav_map = nav.water_map
	amphibious_nav_map = nav.amphibious_map
	deep_water_nav_map = nav.deep_water_map
	_ground_nav_regions = nav.ground_regions
	_amphibious_nav_regions = nav.amphibious_regions
	_nav_tile_rects = nav.tile_rects
	_water_nav_region = nav.water_region
	_deep_water_nav_region = nav.deep_water_region

	var _t_vis := Time.get_ticks_usec()
	await TerrainBuilder.spawn_visuals(current_map, self, _build_ticker())
	# Ambient scatter. PROGRESS.md's 2026-08-10 entry measured ~1650
	# ResourceNode instances on a 210-half map before the clustering change,
	# so this is a credible second home for the load time even though the
	# navmesh usually gets the blame.
	BattleLogger.log_build_step("terrain.spawn_visuals",
		float(Time.get_ticks_usec() - _t_vis) / 1000.0,
		{"resource_nodes": get_tree().get_nodes_in_group("resource_nodes").size()})
	# PR-3 (2026-08-19). Build the spatial index for place_structure's
	# _displace_terrain_props walk. Built once after scatter has populated
	# the groups it indexes. Lazy rebuild is supported as a fallback for
	# the rare case where _displace_terrain_props is called before this
	# (e.g. the very first placement, which can race _setup_terrain's
	# await). The grid reads from _debris_grid_built, see _displace_terrain_props.
	_build_debris_grid()
	await get_tree().process_frame


# NavigationServer3D RIDs are not owned by the scene tree the way child nodes
# are - they leak unless freed explicitly. Found as a real RID-leak warning at
# engine exit during the headless suite, which builds and frees a fresh match
# scene many times per run.
func _exit_tree() -> void:
	# Clear the deferred-rebake guard BEFORE freeing the regions. Any pending
	# _deferred_navmesh_rebake calls (from mid-match structure placement) will
	# see the flag is false and bail out immediately. Without this, the deferred
	# call fires after _exit_tree and the async bake inside it tries to write
	# to already-freed navmesh RIDs — a crash that only shows up when the match
	# closes before the deferred call's next frame.
	_nav_rebake_pending = false
	_nav_lazy_pending = false
	for rid in _ground_nav_regions + _amphibious_nav_regions + [
			_water_nav_region, _deep_water_nav_region,
			ground_nav_map, water_nav_map, amphibious_nav_map, deep_water_nav_map]:
		if rid.is_valid():
			NavigationServer3D.free_rid(rid)
	# Close the match log on the way out, AFTER the navmesh teardown.
	# Pairs with the begin_match() in _ready(): the log opens when the
	# match is live and closes when the director leaves the tree, which
	# is the same condition the RID cleanup runs on. BattleLogger is
	# robust to a null _file (a scene that never opened one is a no-op),
	# and end_match() is idempotent (it closes and nulls the file).
	if BattleLogger.enabled:
		BattleLogger.end_match()
		# Stop profiling so a follow-up scene (Lab, Main Menu) does not
		# pay the per-section start/stop cost. Static vars are process-
		# global, and the next _ready() will reset() and re-enable.
		Profiler.enabled = false
	# Drop the toast CanvasLayer. queue_free() in _exit_tree is safe
	# (the node is already being removed); not freeing it leaves a
	# dangling reference on _perf_toast for the next match, and the
	# next _show_perf_toast() would is_instance_valid() it as true
	# and try to add a fresh child to a freed node.
	if is_instance_valid(_perf_toast):
		_perf_toast.queue_free()
		_perf_toast = null


# --- Duck-typed contracts the unit runtime looks for -------------------------

func get_ground_nav_map() -> RID:
	return ground_nav_map

func get_water_nav_map() -> RID:
	return water_nav_map

func get_amphibious_nav_map() -> RID:
	return amphibious_nav_map

func get_deep_water_nav_map() -> RID:
	return deep_water_nav_map

func terrain_height_at(pos: Vector3) -> float:
	return TerrainBuilder.terrain_height_at(current_map, pos)

func get_surface_type_at(pos: Vector3) -> String:
	return TerrainBuilder.get_surface_type_at(current_map, pos)


# --- Units ------------------------------------------------------------------

# What each side can BUILD this match.
#
# THE ROSTER IS NOT THE STARTING FORCE. Phase 0 conflated the two - it spawned
# every bundled design at the player's spawn so there was something to drive -
# and that stops making sense the moment a roster means "the designs available
# from the build bar". Starting units are handled separately below.
#
# Selection follows the rules the old runtime already settled on
# (skirmish.gd:1160), because they encode decisions rather than accidents:
#
#   1. The exact designs the pre-match screen picked, if it picked any.
#   2. Otherwise the player's newest NAMED saved designs. Named only - an
#      unnamed scratch design left over from a test-range trip was never a
#      choice to field, so it should not be auto-drafted into a match.
#   3. Bundled defaults fill whatever room is left, so a player with no saved
#      designs at all still has a full build bar.
#   4. Capped at ROSTER_LIMIT.
#   5. A harvester is GUARANTEED. A match whose roster cannot mine is
#      unwinnable, and that is a much worse failure than an odd roster.
func _load_roster() -> void:
	roster.clear()
	var match_config := get_node_or_null("/root/MatchConfig")
	# Battle-system unification (Phase 2). Same precedence as in _ready():
	# the per-mode rule set wins if it was written; otherwise the seven
	# legacy fields on MatchConfig stay in charge. Test Range's rule set
	# has player_blueprint_path (singular) and enemy_blueprint_paths
	# (plural) instead of selected_blueprint_paths, so the rule set has
	# to also seed the player roster and the enemy roster directly when
	# the mode is TEST_RANGE. The legacy _bundled_loadout_paths() seed
	# still runs on top in either path, so a roster that comes in with
	# fewer than ROSTER_LIMIT designs is still filled.
	var rs: MatchRuleSet = _match_rule_set
	# Computed once up here so the player-roster branch (and the enemy-roster
	# branch below) can both read it without re-deriving from `rs`. Single
	# source of truth within this function, declared at the top because
	# GDScript locals are visible only from their declaration forward.
	var is_test_range: bool = rs != null and rs.mode == MatchRuleSetScript.Mode.TEST_RANGE

	var chosen: Array = []
	if rs != null and rs.mode == MatchRuleSetScript.Mode.TEST_RANGE and rs.player_blueprint_path != "":
		# Test Range: exactly one player design, plus the bundled defaults
		# if there's room.
		chosen = [rs.player_blueprint_path]
	elif rs != null and rs.selected_blueprint_paths.size() > 0:
		chosen = rs.selected_blueprint_paths
	if not chosen.is_empty():
		for path in chosen:
			_append_design(roster, bp_manager.load_blueprint(path))
	else:
		for entry in bp_manager.list_blueprints(true):
			if roster.size() >= ROSTER_AUTOPICK_LIMIT:
				break
			_append_design(roster, bp_manager.load_blueprint(entry.path))

	# In test range mode the player roster is already set to exactly one
	# design (the test subject). Don't pollute it with the bundled defaults.
	#
	# is_test_range is computed at the top of this function (next to the
	# rule-set lookup, before the player-roster branch reads it) and again
	# near the enemy-roster branch. The reason: GDScript locals are not
	# visible past an `await`, and the rule-set reference `rs` is local
	# to this function. One declaration up here, one in the enemy block,
	# both reading the same `rs.mode` - they are short boolean expressions
	# and the duplication is the price of not promoting `rs` to a member
	# just for the test_range gate.
	if not is_test_range:
		# Tutorial override: don't add bundled loadouts if tutorial flag is set
		if not (rs != null and rs.has_meta("tutorial_phase")):
			for path in _bundled_loadout_paths():
				_append_design(roster, bp_manager.load_blueprint(path))
			if roster.size() > ROSTER_LIMIT:
				roster = roster.slice(0, ROSTER_LIMIT)

			if _harvester_in(roster).is_empty():
				_append_design(roster, bp_manager.load_blueprint(FALLBACK_HARVESTER))

	# Factions: the pre-match choice wins; otherwise the roster's own lead design
	# decides, which is the old behaviour and keeps a hand-built roster feeling
	# like it belongs to somebody. Rule set (when set) is the single source
	# of truth - 2026-08-10: legacy MatchConfig.player_faction fallback gone.
	if rs != null and rs.player_faction != "":
		player_faction = rs.player_faction
	elif not roster.is_empty() and roster[0].get("faction", "") != "":
		player_faction = roster[0].get("faction", "")
	else:
		player_faction = "industrialists"

	# Test Range's enemy roster comes from the rule set rather than from
	# the bundled defaults. The legacy code path (Skirmish, Operations)
	# also reads `enemy_faction` further down and falls back to the
	# enemy_roster lead design - that path is unchanged.
	if rs != null and rs.mode == MatchRuleSetScript.Mode.TEST_RANGE \
			and rs.enemy_blueprint_paths.size() > 0:
		enemy_roster.clear()
		for path in rs.enemy_blueprint_paths:
			_append_design(enemy_roster, bp_manager.load_blueprint(path))
		if _harvester_in(enemy_roster).is_empty():
			_append_design(enemy_roster, bp_manager.load_blueprint(FALLBACK_HARVESTER))

	# ONE SHARED DEFAULT POOL (Chris's call). On a fresh install the player and
	# the AI have the same designs available, so neither side is fighting with
	# equipment the other could not have fielded.
	#
	# The AI draws from the BUNDLED defaults rather than from `roster`, because
	# roster may now be the player's own saved designs - handing those to the
	# opponent would field the player's army against them, which is a different
	# game than the one they chose.
	#
	# SKIP IN TEST RANGE. The test_range block above already populated
	# enemy_roster with the three dummies from the rule set (or the bundled
	# defaults as a fallback). This block was overwriting that result on every
	# launch - lines 687-693 set it correctly and lines 703-707 immediately
	# clobbered it. Guarded now; the test_range block already handles the
	# harvester fallback. `is_test_range` is the function-top local declared
	# above - not redeclared here, to keep the test-range gate one source.
	elif rs == null or rs.mode != MatchRuleSetScript.Mode.TEST_RANGE:
		# Tutorial override: use custom enemy roster if provided via rule set meta
		if rs != null and rs.has_meta("tutorial_enemy_roster"):
			var tutorial_enemy_roster = rs.get_meta("tutorial_enemy_roster")
			if tutorial_enemy_roster is Array:
				enemy_roster.clear()
				for path in tutorial_enemy_roster:
					_append_design(enemy_roster, bp_manager.load_blueprint(path))
				if _harvester_in(enemy_roster).is_empty():
					_append_design(enemy_roster, bp_manager.load_blueprint(FALLBACK_HARVESTER))
		else:
			enemy_roster.clear()
			for path in _bundled_loadout_paths():
				_append_design(enemy_roster, bp_manager.load_blueprint(path))
			if enemy_roster.size() > ROSTER_LIMIT:
				enemy_roster = enemy_roster.slice(0, ROSTER_LIMIT)
			if _harvester_in(enemy_roster).is_empty():
				_append_design(enemy_roster, bp_manager.load_blueprint(FALLBACK_HARVESTER))

	# COUNTER-DRAFTING. In an operation the AI reorders its pool against what the
	# player has actually fielded in engagements already fought - which is what
	# stops it bringing an identical army to round 6 as to round 1.
	#
	# A REORDER, NOT A REBUILD. ai_design_for_role() takes the FIRST design in
	# enemy_roster matching a role, so changing the order is the whole mechanism;
	# no design is added or dropped, and the AI plays exactly as it always did.
	# Outside an operation, or on round one, this is a no-op.
	var ops = get_node_or_null("/root/OperationsService")
	if ops != null and ops.is_active_operation:
		var history: Array = ops.fielded_history()
		if not history.is_empty():
			enemy_roster = CounterDraftScript.order_roster(enemy_roster, history)
			print("[Operations] AI counter-draft: %s" % CounterDraftScript.explain(history))

	if rs != null and rs.enemy_faction != "":
		enemy_faction = rs.enemy_faction
	elif not enemy_roster.is_empty() and enemy_roster[0].get("faction", "") != "":
		enemy_faction = enemy_roster[0].get("faction", "")
	else:
		enemy_faction = "technocrats"


# Skips empties rather than making every caller check. reconstruct_vehicle()
# returns nothing for a design naming a hull the catalog no longer has, and a
# roster slot holding a design that cannot be built is a build button that does
# nothing.
func _append_design(into: Array, design: Dictionary) -> void:
	if not design.is_empty():
		into.append(design)


func _harvester_in(from: Array) -> Dictionary:
	for design in from:
		if CommanderScript.design_fills_role(design, "harvester"):
			return design
	return {}


func _list_json(dir_path: String) -> Array:
	var out: Array = []
	var dir := DirAccess.open(dir_path)
	if dir == null:
		return out
	for f in dir.get_files():
		if f.ends_with(".json"):
			out.append(dir_path + "/" + f)
	out.sort()
	return out


# ONE HARVESTER PER SIDE, and nothing else.
#
# Phase 0 fielded the entire bundled loadout at the player's spawn so there was
# something to drive with no production yet. That was scaffolding: with a real
# roster and a real build bar, handing the player a dozen free units is not a
# starting force, it is the whole match already won. The old runtime starts each
# side with exactly one harvester (skirmish.gd:1499) and everything else is
# earned - matched here, because this mode is replacing that one.
func _spawn_starting_units() -> void:
	# Battle-system unification (Phase 3). Test Range spawns EVERY
	# design in both rosters, not just the harvester, because Test
	# Range's rule set has enable_production=false - the production
	# queue is the wrong tool for "show the player their unit and
	# three dummies on a small map". The lineup is small (4 units
	# total per the rule set) so a direct loop is fine; a Skirmish
	# unit's first move is the production queue, which is what the
	# legacy path here keeps doing.
	# _match_rule_set is the cached rule set from _ready(); reading from
	# the member keeps the mode gate in the same idiom the rest of the
	# director uses.
	var test_range_mode: bool = _match_rule_set != null and _match_rule_set.mode == MatchRuleSetScript.Mode.TEST_RANGE
	if test_range_mode:
		await _spawn_test_range_force()
		return

	# Frame-chunked (2026-08-23): unit assembly (hull collider load, module
	# volumes, visual bake) is a couple hundred ms per unit, so the Test
	# Range's five-unit lineup was a full second of frozen loading screen.
	# Yields between spawns when a ticker exists; headless stays synchronous.
	var ticker: Node = _build_ticker()
	var deadline: int = Time.get_ticks_usec() + int(TerrainBuilder.BUILD_FRAME_BUDGET_MS * 1000.0)
	for team_id in [PLAYER_TEAM, ENEMY_TEAM]:
		var spawn := MapCatalog.get_spawn(current_map,
			"player" if team_id == PLAYER_TEAM else "enemy")
		if spawn.is_empty():
			continue
		var pool: Array = roster if team_id == PLAYER_TEAM else enemy_roster
		var harvester := _harvester_in(pool)
		if harvester.is_empty():
			continue
		# The map authors a harvester start position; fall back to a corner of the
		# base if it does not, rather than dropping the unit on the HQ itself.
		var at: Vector3 = spawn.get("harvester", spawn.get("hq", Vector3.ZERO) + Vector3(8, 0, -8))
		spawn_unit(harvester, team_id, at)
		if ticker != null and Time.get_ticks_usec() >= deadline:
			await get_tree().process_frame
			deadline = Time.get_ticks_usec() + int(TerrainBuilder.BUILD_FRAME_BUDGET_MS * 1000.0)


# Test Range places the player unit and the dummies on the map
# directly. The placement uses the test_range map's authored spawn
# points when it has them, falling back to a line-up across the
# map's centre for a map that does not (the Phase 3 ship map will
# author its own spawns).
#
# The player unit is captured into focus_unit so the chase camera
# has a target. The dummies are not auto-engaging on spawn - their
# normal BattleUnit AI runs from the moment they are on the map,
# which is what the player wanted when they picked the COMBAT-flagged
# dummies; the legacy TARGET_DUMMY_SCRIPT hover-and-pace is gone
# with the battlefield.gd retirement.
func _spawn_test_range_force() -> void:
	# Player unit: use the test_range map's player spawn if it has
	# one, otherwise the centre of the map's half_extents.
	var player_spawn: Vector3 = _test_range_spawn("player", Vector3(0, 0, 0))
	# Frame-budget gate shared by both spawn loops below (see
	# _spawn_starting_units for why the spawns are chunked).
	var ticker: Node = _build_ticker()
	var deadline: int = Time.get_ticks_usec() + int(TerrainBuilder.BUILD_FRAME_BUDGET_MS * 1000.0)
	var player_design: Dictionary = roster[0] if not roster.is_empty() else {}
	if not player_design.is_empty():
		var unit := spawn_unit(player_design, PLAYER_TEAM, player_spawn)
		if ticker != null and Time.get_ticks_usec() >= deadline:
			await get_tree().process_frame
			deadline = Time.get_ticks_usec() + int(TerrainBuilder.BUILD_FRAME_BUDGET_MS * 1000.0)
		if unit != null:
			focus_unit = unit
			# Force-select the player unit from spawn. The selection
			# system's click raycast does not work in Test Range (the
			# hull-cache proxy shares stale team metadata with the
			# template), so we bypass it entirely for the test subject.
			# Orders still go through the normal _issue_at pipeline;
			# only selection is forced here.
			if selection != null:
				selection.set_selection([unit])
			# Push the same reference to the chase camera. The match
			# director's `focus_unit` and ChaseCamera3D's `focus_unit`
			# are the same value; the camera reads it from its own
			# field. Skirmish / Operations leave chase_camera.current
			# false and the camera never reads its own field, so this
			# is the one place the two are linked.
			if chase_camera != null and is_instance_valid(chase_camera) \
					and "focus_unit" in chase_camera:
				chase_camera.focus_unit = unit

	# Dummies: a row in front of the player, each ~6m apart so weapons
	# engage at sensible ranges. The exact spacing does not matter for
	# behaviour, only for the player's read of the field. The dummy
	# row's anchor is the player_spawn + (0, 0, 24) so dummies sit 24m
	# south of the player by default; the map's enemy HQ is used as a
	# directional hint (dummies spread on the line the player takes to
	# reach that HQ) rather than as a literal spawn point. Maps without
	# an enemy spawn fall back to the player-relative anchor.
	var enemy_anchor: Vector3 = _test_range_spawn("enemy", Vector3.ZERO)
	var has_enemy_spawn: bool = enemy_anchor != Vector3.ZERO
	var base_anchor: Vector3 = player_spawn + Vector3(0.0, 0.0, 24.0)
	var right: Vector3 = Vector3(0.0, 0.0, 1.0)  # default: spread along Z
	if has_enemy_spawn:
		# Use the map's enemy HQ as the row's centre, not as a per-dummy
		# position. Spread dummies perpendicular to the line from player
		# to enemy HQ so they read as "the things between me and the
		# objective" rather than three units stacked on one point.
		var to_enemy: Vector3 = enemy_anchor - player_spawn
		to_enemy.y = 0.0
		var fwd: Vector3 = to_enemy.normalized() if to_enemy.length() > 0.01 else Vector3(0, 0, 1)
		right = fwd.cross(Vector3.UP).normalized()
		base_anchor = player_spawn + to_enemy * 0.5  # midpoint of the engagement
	var dummy_index: int = 0
	for design in enemy_roster:
		if design.is_empty():
			dummy_index += 1
			continue
		var side_offset: float = float(dummy_index - (enemy_roster.size() - 1) * 0.5) * 6.0
		var spawn_pos: Vector3 = base_anchor + right * side_offset
		var dummy = spawn_unit(design, ENEMY_TEAM, spawn_pos)
		if ticker != null and Time.get_ticks_usec() >= deadline:
			await get_tree().process_frame
			deadline = Time.get_ticks_usec() + int(TerrainBuilder.BUILD_FRAME_BUDGET_MS * 1000.0)
		if dummy != null:
			# Test range dummies are target dummies: they hold fire until fired upon.
			dummy.stance = StanceScript.Kind.HOLD_FIRE
		dummy_index += 1


# Spawn point lookup for Test Range. Reads the test_range map's
# authored spawns ("player" / "enemy") if the map provides them,
# otherwise returns a sensible default derived from the map's
# half_extents. The legacy Battlefield.tscn map shipped with hard-
# coded spawns in the script (battlefield.gd:19-38); the unified
# map catalog inherits those as default.
func _test_range_spawn(spawn_id: String, fallback: Vector3) -> Vector3:
	var spawns: Array = current_map.get("spawns", [])
	for s in spawns:
		if str(s.get("id", "")) == spawn_id:
			var hq: Vector3 = s.get("hq", Vector3.ZERO)
			return hq
	return fallback


# The bundled default designs. Phase 0 fields these directly so there is
# something to drive; real roster selection (MatchConfig's hand-picked paths,
# then the player's newest saved designs, then these as filler) arrives with
# production in Phase 2.
func _bundled_loadout_paths() -> Array:
	var paths: Array = []
	var dir := DirAccess.open("res://data/loadout")
	if dir == null:
		return paths
	dir.list_dir_begin()
	var file_name := dir.get_next()
	while file_name != "":
		if not dir.current_is_dir() and file_name.ends_with(".json"):
			paths.append("res://data/loadout/" + file_name)
		file_name = dir.get_next()
	dir.list_dir_end()
	paths.sort()
	return paths


func spawn_unit(blueprint: Dictionary, unit_team: int, at: Vector3) -> Node3D:
	var _prof := Profiler.start()
	var unit := UnitScript.new()
	# Added to the tree BEFORE setup(): reconstruct_vehicle() and the nav agent
	# both need the node to be inside the tree to resolve global transforms and
	# to reach NavigationServer3D.
	add_child(unit)
	unit.global_position = Vector3(at.x, terrain_height_at(at), at.z)
	# The unit wears its OWN side's faction. Passing player_faction for everything
	# gave the AI's army the player's colours and the player's passives, which
	# reads as a rendering oddity and is really a balance one.
	var faction: String = player_faction if unit_team == PLAYER_TEAM else enemy_faction
	if stats != null and unit_team == PLAYER_TEAM:
		# Player only. The report is the player's own debrief, and mixing the
		# opponent's designs into it would make every column meaningless.
		stats.record_built(blueprint, DesignCostingScript.blueprint_cost(blueprint))
	if not unit.setup(blueprint, unit_team, bp_manager, self, faction):
		# The blueprint named a hull the catalog no longer has. Drop it rather
		# than leaving a half-assembled body on the field.
		unit.queue_free()
		Profiler.stop("spawn_unit", _prof)
		return null
	# The battlefield finish. Applied after assembly, because the materials do not
	# exist until reconstruct_vehicle() has built the hull and its modules.
	BattleFinishScript.apply(unit)
	# Lifecycle log line. unit_spawned is a no-op when BattleLogger is
	# disabled, so the cost in the production build is one static-bool
	# read plus two string lookups.
	BattleLogger.unit_spawned(
		String(blueprint.get("name", "?")),
		unit_team,
		String(blueprint.get("hull_type", blueprint.get("kind", "?"))))
	Profiler.stop("spawn_unit", _prof)
	return unit


func get_team_units(for_team: int) -> Array:
	var out: Array = []
	for u in get_tree().get_nodes_in_group("units"):
		if is_instance_valid(u) and not u.is_dead and u.team == for_team:
			out.append(u)
	return out


# --- Base and economy --------------------------------------------------------

# Each map entry is now a FIELD CENTRE, not a lump.
#
# The schema is unchanged - position, type, amount - so all ten bundled maps and
# the spawn-fairness lint carry over untouched. What changed is what gets built
# from it: resource_field.gd scatters collectibles around the point and replaces
# them as they are worked out, per Chris's direction that ore and crystal "get
# reworked into spread out fields around the central node that spawns the
# collectible resource objects".
func _spawn_resource_nodes() -> void:
	# PR10 perf (2026-08-18). Wrapped in Profiler to find the 75s
	# first-frame stall the 8/18 log couldn't attribute. The
	# resource_field.gd scatter (its setup) is the prime suspect -
	# if it does scene scattering work synchronously here, the
	# 75s is the cost of spawning all 36 fields + their inner
	# collectibles at the world origin in one frame. After the
	# wrap, any hitch on this path shows up under
	# "resource_field_spawn" instead of being lumped into the
	# "production" bucket.
	#
	# Frame-chunked (2026-08-23): each field.setup() scatters its inner
	# collectibles synchronously, so on field-heavy maps this loop held the
	# main thread for whole seconds and froze the loading screen. With a
	# ticker available the loop yields process_frame whenever the frame's
	# slice of TerrainBuilder.BUILD_FRAME_BUDGET_MS is spent. Headless (no
	# ticker) it is the same single-pass synchronous loop it always was.
	var _t := Profiler.start()
	var ticker: Node = _build_ticker()
	var deadline: int = Time.get_ticks_usec() + int(TerrainBuilder.BUILD_FRAME_BUDGET_MS * 1000.0)
	for entry in current_map.get("resource_nodes", []):
		var field := Node3D.new()
		field.set_script(ResourceFieldScript)
		add_child(field)
		var pos: Vector3 = entry.get("position", Vector3.ZERO)
		field.global_position = Vector3(pos.x, terrain_height_at(pos), pos.z)
		field.setup(entry.get("type", "metal"), entry.get("amount", 1000), self)
		if ticker != null and Time.get_ticks_usec() >= deadline:
			await get_tree().process_frame
			deadline = Time.get_ticks_usec() + int(TerrainBuilder.BUILD_FRAME_BUDGET_MS * 1000.0)
	Profiler.stop("resource_field_spawn", _t)


func _spawn_bases() -> void:
	# Test Range has no bases. _spawn_test_range_force() handles player + dummies
	# and the rule set has no HQ to place. Skipping here mirrors the same guard
	# in _spawn_starting_units so the two are consistent. _match_rule_set is
	# the cached rule set from _ready(); reading from the member is what every
	# other phase of the director does, no need to re-resolve off /root here.
	# Also guard on null: headless test paths that instantiate Battle.tscn
	# without the MatchConfig autoload have no roster and no bases to place.
	if _match_rule_set != null and _match_rule_set.mode == MatchRuleSetScript.Mode.TEST_RANGE:
		return

	# Per-team assigned base zone, indexed by team id (PLAYER_TEAM / ENEMY_TEAM).
	#
	# Two things this assignment does for the orchestrator:
	#   1. Decides WHICH zone each team starts in, using the same OpenRA
	#      max-distance-spread iteration assign_spawns() uses. With exactly
	#      two slots and two zones, this picks the zones farthest apart so
	#      no map boots with a player and an AI spawn in the same corner.
	#   2. Pins the result for the lifetime of the match, so the human
	#      placement hook (place_hq_for_human) and the AI auto-placer can
	#      both look up the same zone without re-running the spread step.
	#
	# Old order argument is preserved verbatim: assign_spawns and
	# assign_base_zones are called with the same [PLAYER_TEAM, ENEMY_TEAM]
	# list, so the i-th slot's spawn and its zone are decided together
	# and the "max-distance spread" lands on the same side for both -
	# a map with a 0-distance spawn pair will have the same 0-distance
	# zone pair, which is what made the old code testable in isolation.
	#
	# The PLAYER team does NOT get an auto-placed HQ - instead, the
	# pre-game phase below raises a placement ghost and waits for the
	# player to drop the HQ in their assigned zone. The AI auto-places
	# as before (no UI for the AI to interact with). On older maps that
	# have no base_zones, the player falls through to the legacy
	# auto-place at the spawn.hq coordinate, so modder maps without
	# zones still boot the old way.
	_team_base_zone = MapCatalog.assign_base_zones(
		current_map.get("base_zones", []),
		[PLAYER_TEAM, ENEMY_TEAM])
	var player_zone_id: String = _team_base_zone.get(PLAYER_TEAM, "")
	var has_zones: bool = not _team_base_zone.is_empty()
	for spawn in current_map.get("spawns", []):
		var team: int = PLAYER_TEAM if spawn.get("id") == "player" else ENEMY_TEAM
		var zone_id: String = _team_base_zone.get(team, "")
		# Prefer the zone centre. Fall back to the (still-authored) spawn.hq
		# when this map has no base_zones - keeps older/modder maps booting.
		var hq_pos: Vector3 = _base_zone_centre(zone_id) if zone_id != "" else spawn.get("hq", Vector3.ZERO)
		# AI auto-places always. Player auto-places ONLY on maps without
		# base_zones (the legacy boot path). On maps with base_zones the
		# player gets a placement ghost instead - see _enter_hq_placement
		# below. The same auto-place-then-raise-ghost path is the only
		# other thing that calls _place_structure, so this is the one
		# and only place the player-HQ decision lives.
		if team == PLAYER_TEAM and has_zones:
			continue
		_place_structure("hq", team, hq_pos)
	for t in [PLAYER_TEAM, ENEMY_TEAM]:
		economy.recalculate_power(t, get_team_structures(t))

	# Enter the pre-game placement phase for the player on maps that
	# have a base zone assigned. A failed or no-zone map already has
	# the player HQ at the legacy spot, so this is a no-op.
	if has_zones:
		_enter_hq_placement()


# Centre of the zone a slot has been assigned to, in world space. Vector3.ZERO
# on miss (no zone, no map, empty zone) - _spawn_bases() already gates on a
# non-empty zone_id before calling, and the only other caller is the human
# placement hook, which also gates. Keeping the fallthrough silent rather
# than asserting is the right call: the orchestrator is a wrapper around
# map data, and a malformed map is a map data problem, not a runtime one.
func _base_zone_centre(zone_id: String) -> Vector3:
	if zone_id == "":
		return Vector3.ZERO
	var zone: Dictionary = MapCatalog.get_base_zone(current_map, zone_id)
	if zone.is_empty():
		return Vector3.ZERO
	var center: Vector3 = zone.get("center", Vector3.ZERO)
	return center


# Drops the human HQ at `at` and goes live.
#
# The free HQ is the one building the new pre-game phase gives the player
# without spending from the starting bank - the rest of the base (refinery,
# manufactories, harvester) is bought and built normally with the credits
# the bank hands out. This hook is what the placement-UI layer calls when
# the human clicks the ghost:
#   - refuses outside the assigned zone (half_extents-bounded rectangle,
#     because zone shapes are axis-aligned and the math is two absf()s;
#     a non-axis-aligned zone would need a point-in-polygon test, which
#     the FIELD_SPEC doesn't claim to support);
#   - refuses if a live player HQ already exists (the zone assignment
#     pins a single HQ per team, and a second one is a stale ghost);
#   - places via the same _place_structure path the auto-spawn uses, so
#     terrain snap, died.connect and the power recalc are identical.
#
# Returns true on commit, false on refusal. UI layer treats a false
# return as "keep the ghost up" rather than as an error.
#
# WHY NOT GO THROUGH confirm_placement. confirm_placement() pulls the
# build job out of a production queue and decrements resources. The free
# HQ has neither - it is given to the player, not produced. Bypassing
# that path is what makes "free HQ" mean anything, and it is why this
# hook is its own function rather than a flag on begin_placement.
func place_hq_for_human(at: Vector3) -> bool:
	var zone_id: String = _team_base_zone.get(PLAYER_TEAM, "")
	var zone: Dictionary = MapCatalog.get_base_zone(current_map, zone_id)
	if zone.is_empty():
		return false
	var center: Vector3 = zone.get("center", Vector3.ZERO)
	var half: Vector2 = zone.get("half_extents", Vector2.ZERO)
	# Axis-aligned rectangle test. absf()s so the sign of the offset
	# (which side of the centre) doesn't matter - a click on the +X
	# edge and a click on the -X edge are equally "inside" if both
	# are within half.x. Equal halves on either side is what
	# half_extents:Vector2 means; the FIELD_SPEC comment is the
	# contract.
	if absf(at.x - center.x) > half.x or absf(at.z - center.z) > half.y:
		return false
	# One human HQ per match. A second one means a stale ghost or a
	# double-fire on the input layer, both of which are UI bugs -
	# the orchestrator just refuses and lets the caller decide.
	for s in get_tree().get_nodes_in_group("structures"):
		if is_instance_valid(s) and not s.is_dead and s.team == PLAYER_TEAM and s.kind == "hq":
			return false
	_place_structure("hq", PLAYER_TEAM, at)
	economy.recalculate_power(PLAYER_TEAM, get_team_structures(PLAYER_TEAM))
	return true


func _place_structure(kind: String, structure_team: int, at: Vector3, under_construction: bool = false) -> Structure:
	var _prof := Profiler.start()
	# SKIRMISH_PERF_TROUBLESHOOTING.md §10.8 item 1. `place_structure` measured
	# 47.9 ms mean / 175 ms worst across 56 calls and is a visible hitch on every
	# building placed. The four sub-sections below split it into the candidates
	# named in §5 Track C - the structure's own setup (mesh + collider), the dust
	# VFX, the terrain-prop displacement walk, and the visibility-range walk -
	# so the next capture names one instead of re-listing all four.
	var _t_setup := Profiler.start()
	var s := StructureScript.new()
	add_child(s)
	s.position = Vector3(at.x, terrain_height_at(at), at.z)
	s.setup(kind, structure_team)
	s.died.connect(_on_structure_died)
	Profiler.stop("place.setup", _t_setup)
	# Dust cloud masks terrain intersection at the building's edges.
	var foot: Vector2 = Vector2(s.footprint.x, s.footprint.z)
	var _t_dust := Profiler.start()
	VFXEffectsScript.dust_cloud(self, s.position, foot * 0.5)
	Profiler.stop("place.dust", _t_dust)
	# Displace overlapping terrain props (greebles, grass, rocks).
	var _t_props := Profiler.start()
	_displace_terrain_props(at, foot * 0.5)
	# Dock bays (refinery harvest pads) extend well past the core footprint.
	# Displace terrain props under each bay so pads don't sit on grass.
	var bays: Array = BuildingCatalogScript.dock_bays_for(kind)
	if not bays.is_empty():
		var bay_half := Vector2(4.0, 5.0)
		for bay_off in bays:
			_displace_terrain_props(at + Vector3(bay_off.x, bay_off.y, bay_off.z), bay_half)
	Profiler.stop("place.displace_props", _t_props)
	# structure_built is logged on both paths (under construction and
	# finished) so the post-match report can correlate structure deaths
	# with the spawn that made them. The HUD's signal listener is still
	# gated to `not under_construction` below.
	BattleLogger.structure_built(kind, structure_team)
	# PR4 (2026-08-15). Apply the same distance-based visibility range to
	# the structure's GeometryInstance3D subtree that unit.gd uses for
	# units. A 50-structure base at max-zoom-out is the worst case for
	# this in Skirmish, and per-frame frustum culling on a 2660x1080
	# viewport is what was paying for itself in the perf log. The
	# fade width is 6 m here (a bit wider than units) because a
	# building popping in is more visible than a unit popping in.
	var _t_vis := Profiler.start()
	_apply_structure_visibility_range(s)
	Profiler.stop("place.visibility_range", _t_vis)
	Profiler.stop("place_structure", _prof)
	# A new live structure can change which designs pass the tech-tree gate
	# (a fresh tech_lab unlocks every tech_lab-gated design, a fresh refinery
	# unlocks nothing, a fresh HQ unlocks nothing, etc.). The HUD's button
	# `disabled` state is set at button-creation time only, so it would stay
	# stale until the HUD rebuilt every button - which it never does.
	# Emitting here lets ProductionHUD re-evaluate the gates immediately on
	# structure placement, rather than on the next 5 Hz refresh tick (200 ms
	# of stale UI is the failure mode the playtest hit).
	if not under_construction:
		structure_built.emit(structure_team, kind)
	# PR-4 (2026-08-19). A new static occluder changes LOS between
	# any viewer and any target it sits between. Invalidate the
	# vision service's LOS cache so the next tick's is_spotted()
	# queries re-raycast against the new geometry. Since 2026-08-23
	# the invalidation carries the footprint so only pairs near the
	# new building and shroud discs within sight of it re-scan - a
	# 100-structure base used to pay the full-map wipe on EVERY
	# placement, which is most of why vision ticks hit 394 ms late
	# game in the 00:33 skirmish log.
	if vision != null:
		var fp: Vector3 = s.footprint if "footprint" in s else Vector3(6, 4, 6)
		vision.invalidate_los_cache(s.global_position, maxf(fp.x, fp.z))
	return s


func get_team_structures(for_team: int, include_incomplete: bool = false) -> Array:
	var out: Array = []
	for s in get_tree().get_nodes_in_group("structures"):
		if is_instance_valid(s) and not s.is_dead and s.team == for_team:
			if not include_incomplete and s.build_incomplete:
				continue
			out.append(s)
	return out


# PR4 (2026-08-15). Walks a structure's subtree and applies the same
# visibility_range pattern that unit.gd uses, with a wider fade band
# to soften the pop-in for buildings. Cheap: one pass at placement time.
const STRUCTURE_VISIBILITY_END: float = 110.0
const STRUCTURE_VISIBILITY_FADE: float = 6.0


func _apply_structure_visibility_range(node: Node) -> void:
	if node is GeometryInstance3D:
		var gi: GeometryInstance3D = node
		gi.visibility_range_begin = 0.0
		gi.visibility_range_end = STRUCTURE_VISIBILITY_END
		gi.visibility_range_begin_margin = 0.0
		gi.visibility_range_end_margin = STRUCTURE_VISIBILITY_FADE
		gi.visibility_range_fade_mode = GeometryInstance3D.VISIBILITY_RANGE_FADE_SELF
	for child in node.get_children():
		_apply_structure_visibility_range(child)


# Displace terrain props (greebles, grass, rocks) AND ambient trees that
# overlap with a newly placed building. Per-instance debris is freed with a
# dust cloud. Ambient trees are batched into a MultiMesh by ambient_scatter.gd
# for draw-call perf (1000+ trees would otherwise be 1000+ draw calls), so
# we cannot free the node - the slot is still owned by the scatter system.
# Instead, scale the instance to zero via the scatter's set_node_transform API.
# This is the same pattern resource_node.gd uses for the depletion shrink
# (line 442: scaled_local to Vector3(pct, pct, pct)), repurposed to make a
# tree invisible rather than to fade its depletion.
#
# PR-3 (2026-08-19). Walks the PR-3 spatial index (_debris_grid,
# _ambient_node_grid, _mm_instance_grid) instead of the full group + every
# MultiMesh. The cells the placement footprint covers are computed once;
# only entries in those cells are tested. Per-call work is O(k) where k
# is the debris inside the footprint, rather than O(N) over the full
# scatter. See _build_debris_grid() for the index and the SKIRMISH_PERF_
# TROUBLESHOOTING.md doc for the measured numbers.
func _displace_terrain_props(at: Vector3, half: Vector2) -> void:
	if not _debris_grid_built:
		# Rare: a placement that races the end of _setup_terrain's
		# await. Building the index now is a one-time O(N) cost; the
		# next call is O(k) like every other.
		_build_debris_grid()
	var radius_sq: float = (maxf(half.x, half.y) + 1.5) * (maxf(half.x, half.y) + 1.5)
	var cs: float = _DEBRIS_CELL_SIZE
	# The cells the footprint covers, plus the +1.5 m buffer. floor()
	# is correct: any cell whose overlap with [at - half - 1.5, at + half + 1.5]
	# is non-empty must be tested. Using floor of the corner with the
	# larger abs value catches that.
	var x0: int = int(floor((at.x - half.x - 1.5) / cs))
	var x1: int = int(floor((at.x + half.x + 1.5) / cs))
	var z0: int = int(floor((at.z - half.y - 1.5) / cs))
	var z1: int = int(floor((at.z + half.y + 1.5) / cs))
	var hide_xform := Transform3D(Basis.IDENTITY, Vector3(0, -9999.0, 0))

	# Pass 1: per-instance debris. Free on hit. Iterate the cell
	# backward so we can remove the freed entries in place - freed
	# nodes are still in the array, but is_instance_valid() returns
	# false, so the next pass over the same cell filters them out
	# cleanly without a separate compaction pass.
	for gz in range(z0, z1 + 1):
		for gx in range(x0, x1 + 1):
			var key := Vector2i(gx, gz)
			if not _debris_grid.has(key):
				continue
			var cell: Array = _debris_grid[key]
			for idx in range(cell.size() - 1, -1, -1):
				var node: Node = cell[idx]
				if not is_instance_valid(node):
					cell.remove_at(idx)
					continue
				var p: Vector3 = node.global_position
				var d_sq: float = (p.x - at.x) * (p.x - at.x) + (p.z - at.z) * (p.z - at.z)
				if d_sq > radius_sq:
					continue
				VFXEffectsScript.dust_cloud(self, node.global_position, Vector2(0.8, 0.8))
				# SKIRMISH_PERF_TROUBLESHOOTING.md §14. Defer the
				# queue_free to _process_pending_debris_frees(). The
				# grid entry is still removed inline so the next
				# placement does not re-displace the same node;
				# the actual node destruction is amortised.
				_pending_debris_frees.append(node)
				cell.remove_at(idx)

	# Pass 2: ambient trees (scatter-batched). Scale to zero on hit via
	# the scatter API. The node itself stays alive (the scatter system
	# owns the slot); we mark "already displaced" with a near-zero scale
	# so a later pass over the same cell doesn't re-fire dust + scale.
	for gz in range(z0, z1 + 1):
		for gx in range(x0, x1 + 1):
			var key := Vector2i(gx, gz)
			if not _ambient_node_grid.has(key):
				continue
			var cell: Array = _ambient_node_grid[key]
			for idx in range(cell.size() - 1, -1, -1):
				var node: Node = cell[idx]
				if not is_instance_valid(node):
					cell.remove_at(idx)
					continue
				if node.scale.length_squared() < 0.0001:
					continue
				var p: Vector3 = node.global_position
				var d_sq: float = (p.x - at.x) * (p.x - at.x) + (p.z - at.z) * (p.z - at.z)
				if d_sq > radius_sq:
					continue
				var handle = node.get("_scatter_handle")
				var scatter = node.get("_scatter")
				if handle != null and is_instance_valid(scatter) and scatter.has_method("set_node_transform"):
					scatter.set_node_transform(handle, node.global_transform.scaled_local(Vector3.ZERO))
					VFXEffectsScript.dust_cloud(self, node.global_position, Vector2(1.2, 1.2))

	# Pass 3: visual scatter MultiMesh. Hide on hit. Reads the current
	# transform of the instance to confirm it is still visible (a
	# previous placement may have parked it at y=-9999).
	for gz in range(z0, z1 + 1):
		for gx in range(x0, x1 + 1):
			var key := Vector2i(gx, gz)
			if not _mm_instance_grid.has(key):
				continue
			var cell: Array = _mm_instance_grid[key]
			for idx in range(cell.size() - 1, -1, -1):
				var entry: Dictionary = cell[idx]
				var mm: MultiMesh = entry.mm
				if mm == null:
					cell.remove_at(idx)
					continue
				var i: int = int(entry.index)
				var ix: Transform3D = mm.get_instance_transform(i)
				# Already hidden by a previous placement. The y=-9999
				# is the universal "hidden" marker this whole file uses.
				if ix.origin.y < -9000.0:
					continue
				var d_sq: float = (ix.origin.x - at.x) * (ix.origin.x - at.x) + (ix.origin.z - at.z) * (ix.origin.z - at.z)
				if d_sq > radius_sq:
					continue
				mm.set_instance_transform(i, hide_xform)


# How far past its own footprint a building's navmesh hole extends.
#
# WHY THIS IS NOT ZERO. The navmesh is baked with NavigationMesh's default
# agent_radius of 0.5 m, so Recast keeps paths only half a metre clear of an
# obstacle - but a vehicle is metres wide and is steered by its ORIGIN. A path
# that is legal for a 0.5 m agent runs straight through the corner of a building
# for a 4 m tank, which then grinds along the collider until something else
# dislodges it. Measured: harvesters wedging on the refinery's corner for 20 s at
# a time, and it is why their dock approach needed a stuck-recovery path at all.
#
# Inflating the HOLE rather than raising agent_radius on the bake is deliberate:
# terrain_builder.gd is shared with the legacy Skirmish runtime and its navmesh
# suites, and agent_radius would also shrink the walkable surface along every
# cliff and shoreline on the map, not just around buildings. This is the same
# correction applied only where the problem actually is.
#
# Sized from the widest hull the roster fields rather than an average - the cost
# of being generous is a slightly wider detour, and the cost of being tight is a
# stuck unit.
const BUILDING_CLEARANCE := 2.5

# Every live structure's footprint, gathered fresh rather than cached. The set
# only changes on placement and death, both of which already trigger a rebake, so
# this is never stale when it actually runs.
func _building_holes() -> Array:
	var holes: Array = []
	for s in get_tree().get_nodes_in_group("structures"):
		# is_inside_tree() guards a real teardown race: queue_free() defers
		# removal to end of frame, so a structure mid-teardown can still be
		# is_instance_valid() while reading global_position throws.
		if not is_instance_valid(s) or s.is_dead or not s.is_inside_tree():
			continue
		holes.append({
			"center": s.global_position,
			"half_extents": Vector2(
				s.footprint.x / 2.0 + BUILDING_CLEARANCE,
				s.footprint.z / 2.0 + BUILDING_CLEARANCE),
		})
	return holes


# --- Runtime navmesh -----------------------------------------------------------
#
# The startup bake carves the STARTING buildings only, because at Phase 0 nothing
# was ever built mid-match. The AI places buildings while the match runs, and a
# structure that is not in the navmesh is one units cheerfully path straight
# through - so placement and death both have to re-carve.
#
# Debounced to end-of-frame rather than run inline: several buildings can go up
# or die in one frame (a blast, a wave completing), and a Recast bake per event
# would be several hundred milliseconds of stall for one identical result.
var _nav_rebake_pending: bool = false

# A LAZY REBAKE, for changes that only OPEN ground.
#
# Measured (tools/probe_death_hitch.gd): killing one building cost a 4139 ms
# frame against a 55 ms idle worst case. The whole of it is this rebake - a
# synchronous Recast pass over the entire map - and end-of-frame debouncing does
# not help, because one death is already one bake.
#
# The asymmetry that makes this fixable: PLACING a building must re-carve
# promptly, or units walk straight through a wall that is visibly there.
# DESTROYING one only frees space. Until the bake catches up, units route around
# a hole where a building no longer stands - which costs them a slightly long way
# round and nothing else. So a death can wait, and several deaths in a firefight
# can wait together and cost ONE bake instead of one each.
const NAV_LAZY_REBAKE_DELAY := 3.0

# SYNC THROTTLE (2026-08-24, tools/probe_navmesh_repath_storm.gd). The Recast
# bake itself is async and cheap; what is NOT cheap is the navigation-server
# map merge that the first agent query after the bake lands has to pay -
# measured inside unit.steer_nav at ~2 s per placement in the 02:31 skirmish
# (the AI planted a power plant every BUILD_RATE_CAP_SECONDS for eight minutes,
# so that cost recurred all match) and ~30 s headless against a mature base.
# Placement CADENCE is the only lever on it: within this interval, new
# placements defer into the lazy accumulator instead of dispatching their own
# carve, so N buildings in the window cost ONE sync. The next dispatch carves
# every live structure's holes anyway (_building_holes), so nothing is lost -
# units bump the new building's collision body until the bake lands, same as
# they already do for destroyed buildings waiting out the lazy delay.
const NAV_REBAKE_MIN_INTERVAL := 12.0
# Starvation bound: if placements keep arriving faster than the interval
# drains, force a dispatch this long after the first deferral.
const NAV_REBAKE_MAX_WAIT := 20.0
var _last_rebake_dispatch_ms: int = -(1 << 30)
var _nav_throttle_started_ms: int = -(1 << 30)

var _nav_lazy_pending: bool = false
var _nav_lazy_timer: float = 0.0


# PR-3 (2026-08-19). Spatial index for _displace_terrain_props.
#
# The 2026-08-19T22-54-40 log: `place.displace_props` 7.0 s total / 85 ms mean
# over 82 placements. The old implementation walked the entire `terrain_debris`
# group, the entire `resource_nodes` group (with is_ambient), and every instance
# in every MultiMesh in the `visual_scatter` group, on every structure placement.
# O(N) per call, with N being the full scatter count (450-1650 on a typical
# map). The win from a 2D grid bucket is straightforward: per-call work goes
# from O(N) to O(k), where k is the debris inside the placement footprint.
#
# 4 m cells. A 5x5 m footprint spans 2x2 cells; the +1 cell buffer (1.5 m
# radius on top of half_extents) catches the corner cases. For 82 calls
# against a 1650-item map this drops 82*1650 = ~135 k distance checks to
# 82*~30 = ~2.5 k. Roughly 50x.
const _DEBRIS_CELL_SIZE := 4.0
# Vector2i -> Array of per-cell entries. terrain_debris and the per-node
# ambient resource entries store the node itself; the MultiMesh entries
# store {"mm": MultiMesh, "index": int, "origin": Vector3}.
var _debris_grid: Dictionary = {}
var _ambient_node_grid: Dictionary = {}
var _mm_instance_grid: Dictionary = {}
var _debris_grid_built: bool = false
# SKIRMISH_PERF_TROUBLESHOOTING.md §14. Deferred queue_free
# accumulator. _displace_terrain_props() finds debris nodes
# and removes them from the grid inline (so follow-up placements
# do not re-displace the same node), but pushes the actual
# queue_free() into this list. _process_pending_debris_frees()
# drains it at FREE_BATCH_PER_FRAME per frame, amortising the
# engine's per-free bookkeeping across ticks. At the 20:49:15
# capture's worst case (~300 frees per power_plant placement
# in a debris-rich cell) the dominant 320 ms hitch dropped to
# a few ms per frame once this landed.
const FREE_BATCH_PER_FRAME: int = 32
var _pending_debris_frees: Array = []


# Builds the PR-3 spatial index. O(N) once, then O(k) per displace call.
# Called from _setup_terrain after spawn_visuals; lazily re-callable from
# _displace_terrain_props if a placement races the build.
# SKIRMISH_PERF_TROUBLESHOOTING.md §14. Drain the deferred-free
# accumulator at FREE_BATCH_PER_FRAME per frame. The per-unit
# bookkeeping that made the original 320 ms hitch is what we
# are amortising, and the unit tick is the natural cadence.
# Called from _physics_process. The is_instance_valid check
# is cheap (one pointer compare) but necessary - a debris node
# freed by something else between frames sits in this list
# until the drain sees it and the check filters it out cleanly.
func _process_pending_debris_frees() -> void:
	if _pending_debris_frees.is_empty():
		return
	var batch: int = mini(FREE_BATCH_PER_FRAME, _pending_debris_frees.size())
	for _i in range(batch):
		var n: Node = _pending_debris_frees.pop_front()
		if is_instance_valid(n):
			n.queue_free()


func _build_debris_grid() -> void:
	_debris_grid.clear()
	_ambient_node_grid.clear()
	_mm_instance_grid.clear()
	var cs: float = _DEBRIS_CELL_SIZE
	# Per-instance debris (rocks, grass tufts, greebles). Free on hit.
	for n in get_tree().get_nodes_in_group("terrain_debris"):
		if not is_instance_valid(n):
			continue
		var p: Vector3 = n.global_position
		var key := Vector2i(int(floor(p.x / cs)), int(floor(p.z / cs)))
		if not _debris_grid.has(key):
			_debris_grid[key] = []
		_debris_grid[key].append(n)
	# Ambient scatter-batched trees (resource_nodes with is_ambient true).
	# These are scaled to zero on hit; the node stays alive because the
	# scatter system owns the bookkeeping for the slot.
	for n in get_tree().get_nodes_in_group("resource_nodes"):
		if not is_instance_valid(n):
			continue
		if not n.get("is_ambient"):
			continue
		var p2: Vector3 = n.global_position
		var key2 := Vector2i(int(floor(p2.x / cs)), int(floor(p2.z / cs)))
		if not _ambient_node_grid.has(key2):
			_ambient_node_grid[key2] = []
		_ambient_node_grid[key2].append(n)
	# MultiMesh-batched visual scatter (visual_scatter group). Each instance
	# is hidden on hit by parking it at y = -9999. Skip instances that are
	# already hidden - they were hidden by a previous placement, and
	# re-hiding them is wasted work and re-walks the same scatter.
	for n in get_tree().get_nodes_in_group("visual_scatter"):
		if not is_instance_valid(n) or not (n is MultiMeshInstance3D):
			continue
		var mm: MultiMesh = (n as MultiMeshInstance3D).multimesh
		if mm == null:
			continue
		var count: int = mm.instance_count
		for i in range(count):
			var ix: Transform3D = mm.get_instance_transform(i)
			if ix.origin.y < -9000.0:
				continue
			var p3: Vector3 = ix.origin
			var key3 := Vector2i(int(floor(p3.x / cs)), int(floor(p3.z / cs)))
			if not _mm_instance_grid.has(key3):
				_mm_instance_grid[key3] = []
			_mm_instance_grid[key3].append({"mm": mm, "index": i})
	_debris_grid_built = true


# `urgent` carves immediately; the default defers and coalesces.
# Callers that make ground IMPASSABLE must pass true.
#
# PR-2 (2026-08-19). The urgent case used to do a SYNCHRONOUS, AFFECTED-
# TILES-ONLY rebake inline (`rebake_ground_amphibious_tiles_sync`),
# which cost 272 ms mean / 626 ms worst in §11.2 and 771 ms mean /
# 1548 ms worst in the 22:54:40 capture. The PR8 (2026-08-16) comment
# explained the original choice: an async rebake leaves a 100-200 ms
# window where a unit with a path that crosses the new building will
# head for the wall, hit the collider, and stop - the "unit drove into
# the building" wallhack.
#
# That cost was unsustainable: 67 s of main-thread blocking across an
# 84-structure base-building match. The new design keeps the
# correctness the PR8 comment was buying, but moves the bake off the
# main thread and handles the unit-wallhack side-effect with a
# targeted repath.
#
# What it does now:
#
#   1. Compute the affected-tile set (same heuristic as before).
#   2. Targeted repath: every unit within `building_half_extent +
#      turn_radius` of the new building's center gets an immediate
#      `request_repath()`. These are the units whose next path tick
#      would otherwise see the new obstacle first. Units far away
#      keep their path; the async callback's full force-repath
#      picks them up when the bake completes.
#   3. Dispatch the async rebake on the Recast worker pool, scoped
#      to the affected tiles. Main thread returns within a frame.
#   4. The async callback (`_on_navmesh_rebaked`) invalidates
#      flow fields and force-repaths every live unit. This is the
#      catch-up pass for the units we did NOT repath in step 2.
#
# The 100-200 ms wallhack window now affects only units far enough
# from the new building to have a path crossing it on the far side
# of the map - which, in practice, is "a unit whose path was
# specifically routed through the building's footprint AND was far
# enough away that the targeted repath's `+3m turn radius` did not
# catch it AND whose path recompute window lined up with the bake."
# That intersection is empty for almost every placement.
func _mark_navmesh_dirty(urgent: bool = true) -> void:
	if not urgent:
		_nav_lazy_pending = true
		_nav_lazy_timer = 0.0
		return
	# SYNC THROTTLE - see NAV_REBAKE_MIN_INTERVAL above. Deferrals go through
	# the lazy accumulator WITHOUT resetting its timer (only genuine
	# quiet-period marks reset it), so sustained building still flushes on a
	# steady NAV_REBAKE_MIN_INTERVAL cadence, and NAV_REBAKE_MAX_WAIT bounds
	# the wait if that ever stops being true.
	var throttle_now := Time.get_ticks_msec()
	if throttle_now - _last_rebake_dispatch_ms < int(NAV_REBAKE_MIN_INTERVAL * 1000.0):
		if _nav_throttle_started_ms < 0:
			_nav_throttle_started_ms = throttle_now
		if throttle_now - _nav_throttle_started_ms < int(NAV_REBAKE_MAX_WAIT * 1000.0):
			_nav_lazy_pending = true
			return
	_nav_throttle_started_ms = -(1 << 30)
	if _nav_rebake_pending:
		return
	if _ground_nav_regions.is_empty():
		# The boot-time navmesh hasn't been built yet. Fall through
		# to the async path; _setup_terrain() will fill the regions
		# from scratch.
		_nav_rebake_pending = true
		_nav_lazy_pending = false
		_rebake_navmesh.call_deferred()
		return
	# Find the new structure(s) whose footprint triggered this
	# rebake. The non-urgent case (death) does not need this -
	# the carving is "open this ground", which the existing
	# flow already handles asynchronously. The urgent case is
	# always a single new placement, so the affected tile set
	# is "all tiles overlapping the most recently placed live
	# structure that wasn't live when the last rebake ran".
	# Simpler: take the most recent structure (sorted by index
	# in the structures group) as the culprit. With 50+ structures,
	# the "most recent" heuristic is correct because the player
	# is the only entity triggering urgent placement.
	var new_holes := _building_holes()
	if new_holes.is_empty():
		# Defensive: nothing to carve. The lazy path can handle it
		# later if it ever becomes a real case.
		_nav_lazy_pending = true
		return
	var affected: Array = []
	for hole in new_holes:
		var tiles := TerrainBuilder.tiles_overlapping_hole(current_map, hole)
		for t in tiles:
			if t not in affected:
				affected.append(t)
	_nav_rebake_pending = true
	_nav_lazy_pending = false
	# Targeted force-repath at placement time. This is the half of
	# PR-2 that buys back the wallhack correctness the original
	# sync path had. Units within the new building's "danger zone"
	# (footprint + 3 m turn radius) get a path recompute against
	# the current navmesh BEFORE the async bake updates it. That
	# gives them a head start: by the time the new navmesh is in
	# place, the catch-up pass in `_on_navmesh_rebaked` re-repaths
	# them against the fresh geometry.
	#
	# The section name stays "navmesh_invalidate" so existing
	# log readers and PR8's instrumentation keep working.
	var _t_inv := Profiler.start()
	_repath_units_near_new_holes(new_holes)
	Profiler.stop("navmesh_invalidate", _t_inv)
	# DefERRED navmesh rebake: _invalidate_and_rebake() was synchronous
	# and its TerrainBuilder.rebake_ground_amphibious_tiles_async() call
	# takes ~900ms per structure on the main thread (terrain mesh prep +
	# async dispatch). The AI builds structures every commander tick (~2 s),
	# so without deferral each commander.execute hitch (~900ms) compounds
	# with the structure-placement hitch (~900ms), producing 1,700+ ms worst
	# frames. Deferring the rebake to the next frame eliminates the
	# compounding: structure placement itself is now sub-frame, and the
	# navmesh update happens on the following tick.
	# Multiple placements between frames are coalesced: each sets
	# _nav_rebake_pending and defers another call; only the last
	# (when _nav_rebake_pending is still true) proceeds.
	# Godot 4 `call_deferred` passes args directly to the method.
	_deferred_navmesh_rebake.call_deferred(affected, new_holes)


# Targeted force-repath for units close to a freshly placed building.
# See _mark_navmesh_dirty's PR-2 comment for the design.
#
# Conservative radius: building half-extent + 3 m (a worst-case vehicle
# turn radius). A unit outside this band is highly unlikely to be on a
# path that crosses the new building in the next 100-200 ms (the
# async bake window). The catch-up pass in `_on_navmesh_rebaked` will
# repath the rest when the bake completes.
func _repath_units_near_new_holes(new_holes: Array) -> void:
	if new_holes.is_empty():
		return
	# Walk the new holes once to compute the largest danger radius and
	# the centers to test against. One pass per call; cheap.
	var max_radius_sq: float = 0.0
	var centers: Array = []
	for hole in new_holes:
		var hx: float = float(hole["half_extents"].x)
		var hy: float = float(hole["half_extents"].y)
		var r: float = maxf(hx, hy) + 3.0
		max_radius_sq = maxf(max_radius_sq, r * r)
		centers.append(hole["center"])
	for u in get_tree().get_nodes_in_group("units"):
		if not is_instance_valid(u) or u.is_dead or not u.has_method("request_repath"):
			continue
		var p: Vector3 = u.global_position
		for c in centers:
			var dx: float = float(c.x) - p.x
			var dz: float = float(c.z) - p.z
			if dx * dx + dz * dz <= max_radius_sq:
				u.request_repath()
				break


# Deferred navmesh rebake for urgent structure placement.
# Runs on the NEXT frame after a structure is placed via call_deferred(),
# so placement itself is sub-frame and the rebake hitch is isolated.
# _nav_rebake_pending guards against stale calls (e.g. a second structure
# placed before the first's deferred rebake fires cancels the first's bake).
func _deferred_navmesh_rebake(affected: Array, new_holes: Array) -> void:
	if not _nav_rebake_pending:
		return
	# Guard: _exit_tree() may have already freed the navmesh regions if the match
	# closed before this deferred call fired. Bail if the regions are gone.
	if _ground_nav_regions.is_empty():
		_nav_rebake_pending = false
		return
	_last_rebake_dispatch_ms = Time.get_ticks_msec()
	var t_inv := Profiler.start()
	_repath_units_near_new_holes(new_holes)
	Profiler.stop("navmesh_invalidate", t_inv)
	var t_bake := Profiler.start()
	var bake_wall := Time.get_ticks_usec()
	TerrainBuilder.rebake_ground_amphibious_tiles_async(
		current_map, new_holes, _ground_nav_regions, _amphibious_nav_regions,
		_nav_tile_rects, _on_navmesh_rebaked, affected, 1.0)
	Profiler.stop("navmesh_dispatch", t_bake)
	BattleLogger.log_nav_rebake("structure_placed",
		float(Time.get_ticks_usec() - bake_wall) / 1000.0,
		{"tiles": affected.size(), "holes": new_holes.size()})


# Runs the deferred bake once the map has been quiet for NAV_LAZY_REBAKE_DELAY.
# The timer RESETS on each new death, so a sustained firefight keeps postponing
# it rather than stalling in the middle of the fight.
# SYNC THROTTLE: also holds a flush until NAV_REBAKE_MIN_INTERVAL has passed
# since the last dispatch, so placements deferred by the urgent-path throttle
# coalesce onto the sync cadence instead of sneaking out on the short timer.
func _tick_lazy_navmesh(delta: float) -> void:
	if not _nav_lazy_pending:
		return
	_nav_lazy_timer += delta
	if _nav_lazy_timer < NAV_LAZY_REBAKE_DELAY:
		return
	if Time.get_ticks_msec() - _last_rebake_dispatch_ms < int(NAV_REBAKE_MIN_INTERVAL * 1000.0):
		return
	_nav_lazy_pending = false
	_nav_lazy_timer = 0.0
	_rebake_navmesh()


func _rebake_navmesh() -> void:
	# Stamp the throttle clock here as well - the lazy path and the boot bake
	# dispatch through this function, and the throttle measures SYNC cadence,
	# not placement cadence.
	_last_rebake_dispatch_ms = Time.get_ticks_msec()
	_nav_throttle_started_ms = -(1 << 30)
	# PR-2 (2026-08-19). The flag now means "an async rebake is in flight"
	# (was: "a sync rebake is in flight"). Set on dispatch, cleared by
	# _on_navmesh_rebaked when the workers finish. The old pre-dispatch
	# clear was correct for the synchronous path; the new pre-dispatch
	# set is correct for the async path and matches _mark_navmesh_dirty's
	# urgent-path behavior. While in flight, both urgent and lazy callers
	# no-op their dispatch, which is fine - the in-flight bake will see
	# the same building list and the next placement will retrigger.
	_nav_rebake_pending = true
	if _ground_nav_regions.is_empty():
		_nav_rebake_pending = false
		return
	# ASYNC. terrain_builder.gd has carried an async twin of this call since the
	# old runtime, written for exactly this situation and documented in its own
	# header as "the mid-match rebake is the one that must not block" - and the
	# battle layer was calling the SYNCHRONOUS one anyway.
	#
	# Measured in a staged engagement: a single mid-match placement stalled one
	# frame for 3940 ms. That is not a dropped frame, it is the game stopping
	# dead, and it lands whenever the AI sites a building - which is why a hitch
	# can appear to coincide with entering combat while having nothing to do with
	# combat.
	#
	# Only the GDScript face generation stays on the main thread; Recast itself
	# goes to a worker. The repath moves into the callback so units are steered
	# against the FINISHED navmesh rather than a half-updated one.
	#
	# Chunk 21: rebakes every tile, not just the one(s) the change touched -
	# selective per-tile rebake (Chunk 22) is a further optimization on top
	#
	# PR10 perf (2026-08-18). Wrapped in Profiler so the 8/16-log's
	# "dominant=production, dominant_ms=0" hitches get a real owner.
	# The previous design started the async call and returned; the
	# worker-thread bake + callback were untimed, and the 3940ms
	# worst-case and 60s+ first-frame stalls showed up as "production"
	# only because that was the last named section. After the wrap,
	# any hitch on the rebake dispatch goes to "navmesh_dispatch"
	# and any hitch on the worker completing (flow_fields.invalidate
	# + the per-unit repath walk in the callback) goes to
	# "navmesh_callback". The two together are the candidates that
	# the 8/16 log couldn't name.
	var _t := Profiler.start()
	TerrainBuilder.rebake_ground_amphibious_tiles_async(
		current_map, _building_holes(), _ground_nav_regions, _amphibious_nav_regions, _nav_tile_rects,
		_on_navmesh_rebaked, [], 1.0)
	Profiler.stop("navmesh_dispatch", _t)


# Runs when both surfaces have finished baking. Every cached field was sampled
# against the OLD passability, and every live agent is following a path through
# what may now be a wall.
func _on_navmesh_rebaked() -> void:
	if not is_inside_tree():
		return
	# PR-C (2026-08-19). Clean up the worker threads that have finished
	# their prep work. The threads themselves terminated the moment
	# they dispatched the Recast bakes; this removes the static-array
	# references that kept the Thread objects alive. _on_navmesh_rebaked
	# runs on the main thread when the last Recast bake completes,
	# which is well after the worker thread has died, so wait_to_finish
	# is a no-op.
	TerrainBuilder._cleanup_finished_threads()
	# PR-2 (2026-08-19). Clear the in-flight flag. Whoever dispatched
	# the bake (urgent path or lazy path) gets to dispatch another one
	# the next time a hole changes.
	_nav_rebake_pending = false
	# PR10 perf (2026-08-18). Wrapped in Profiler so the worker
	# callback's cost (flow_fields.invalidate + the per-unit
	# request_repath walk) shows up under a real section name.
	# The 8/16 log couldn't attribute the 6s/60s stalls to
	# anything; this is one of the two likely owners (the
	# other being the dispatch above; both wrapped now).
	var _t := Profiler.start()
	flow_fields.invalidate()
	for u in get_tree().get_nodes_in_group("units"):
		if is_instance_valid(u) and not u.is_dead and u.has_method("request_repath"):
			u.request_repath()
	Profiler.stop("navmesh_callback", _t)


func _on_structure_died(structure) -> void:
	BattleLogger.structure_died(String(structure.kind), int(structure.team))
	if "build_incomplete" in structure and structure.build_incomplete:
		for q_name in BuildingCatalogScript.QUEUES:
			var q := production.queue(structure.team, q_name)
			for i in range(q.size() - 1, -1, -1):
				if q[i].get("structure_node") == structure:
					production.cancel(structure.team, q_name, i)

	economy.recalculate_power(structure.team, get_team_structures(structure.team))
	# Losing the last contributor to a queue refunds everything in it: that line
	# can never advance again, so holding the money is a bug with extra steps.
	production.cancel_unbuildable(structure.team)
	# See structure_lost comment in the signal declaration. We emit BEFORE
	# the audio / navmesh / end-match work so the HUD's re-eval lands on
	# the same frame the player notices the death, not after the audio
	# line and not after the rebake debounce.
	structure_lost.emit(structure.team, structure.kind)
	# PR-4 (2026-08-19). A removed occluder changes LOS too. Region-scoped:
	# see the placement-side note above.
	if vision != null:
		var fp: Vector3 = structure.footprint if "footprint" in structure else Vector3(6, 4, 6)
		vision.invalidate_los_cache(structure.global_position, maxf(fp.x, fp.z))
	# The navmesh had a hole carved for this building and no longer should, and
	# every cached flow field was sampled against the old passability.
	#
	# NOT URGENT. A dead building only frees ground - the worst that happens
	# before the bake lands is that units take the long way round a hole where
	# nothing stands. Baking inline here cost a 4139 ms frame; see
	# NAV_LAZY_REBAKE_DELAY.
	_mark_navmesh_dirty(false)
	# The sincere comms layer reporting a loss, over whatever is still going
	# "pew" out there. CORE_DESIGN_LANGUAGE.md 6.2 calls that pairing the whole
	# thesis in one moment.
	if _audio != null and structure.team == PLAYER_TEAM:
		_audio.play_voice("radio_structure_lost")
	if structure.kind == "hq":
		_end_match(PLAYER_TEAM if structure.team != PLAYER_TEAM else ENEMY_TEAM)


# --- Win condition -----------------------------------------------------------

signal match_ended(winning_team)

# Losing your HQ loses the match.
#
# Driven by the structure's own death signal rather than polled, so there is no
# window in which the HQ is gone and the match has not noticed. Guarded against
# re-entry because both HQs can die in the same frame to the same blast, and the
# first result is the one that counts.
func _end_match(winning_team: int) -> void:
	if game_over:
		return
	game_over = true
	match_ended.emit(winning_team)
	_show_result(winning_team == PLAYER_TEAM)


# The end of a match, as an actual sequence rather than a word on the screen.
#
# WHAT THIS REPLACES. A bare "VICTORY" Label anchored to the top of the HUD, and
# nothing else - no stats, no way out, no acknowledgement that the match was
# over beyond the units stopping. after_action_report.gd has been fully written
# and completely orphaned this whole time (OPERATIONS_PLAN.md names it), because
# nothing produced the per-design statistics it takes. MatchStats does now.
func _show_result(player_won: bool) -> void:
	if battle_hud == null:
		return

	# The banner stays - it lands immediately, while the report needs a beat so
	# the killing blow is actually seen rather than being instantly covered up.
	var banner := Label.new()
	banner.name = "ResultBanner"
	banner.text = "VICTORY" if player_won else "DEFEAT"
	banner.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	banner.set_anchors_preset(Control.PRESET_CENTER_TOP)
	banner.offset_top = 120
	banner.add_theme_color_override("font_color",
		Tokens.SIGNAL_GO if player_won else Tokens.SIGNAL_ALERT)
	battle_hud.add_child(banner)

	_show_after_action_report.call_deferred(player_won)


# How long the result banner is left alone before the report covers it.
const RESULT_BEAT := 2.0


func _show_after_action_report(player_won: bool) -> void:
	if not is_inside_tree():
		return
	await get_tree().create_timer(RESULT_BEAT).timeout
	if not is_inside_tree() or battle_hud == null:
		return

	var report := AfterActionReportScript.new()
	report.name = "AfterActionReport"
	report.set_anchors_preset(Control.PRESET_FULL_RECT)
	# Sized by hand for the same reason both HUDs are - see
	# ProductionHUD.fit_to_viewport(). Parented to battle_hud, which is itself a
	# CanvasLayer child, so there is still no Control rect to anchor against.
	battle_hud.add_child(report)
	report.position = Vector2.ZERO
	report.size = battle_hud.size
	report.mouse_filter = Control.MOUSE_FILTER_STOP

	var duration: float = stats.duration() if stats != null else 0.0
	var rows: Dictionary = stats.to_report() if stats != null else {}

	# The campaign seam, live at last. is_operation was hardcoded `false` here,
	# which is why the report never offered a next engagement and an Operation
	# was a single match with a different setup screen.
	var ops = _operations()
	var in_operation: bool = ops != null and ops.is_active_operation
	if in_operation:
		ops.record_stage_result(_stage_result(player_won, duration, rows))
	report.setup(player_won, duration, rows, in_operation and ops.has_next_stage())
	report.main_menu_requested.connect(_on_report_main_menu)
	report.iterate_requested.connect(_on_report_iterate)
	report.next_stage_requested.connect(_on_report_next_stage)


# The manager, or null outside a campaign. Looked up rather than preloaded so a
# Battle scene instantiated by a test - no autoloads at all in that boot path -
# behaves exactly as a skirmish, which is what it is.
func _operations():
	return get_node_or_null("/root/OperationsManager")


# One engagement's line in the combat log. The per-design rows are the report's;
# the roster lists are what counter-drafting will read, and this is the only
# moment both sides' compositions are still in one place.
func _stage_result(player_won: bool, duration: float, rows: Dictionary) -> Dictionary:
	var player_designs: Array = []
	# THREATS ARE CLASSIFIED NOW, NOT AT DRAFT TIME. The blueprints are in hand
	# here; three engagements later the player may have edited or deleted them,
	# and re-classifying from the library would then describe an army that was
	# never fielded. What the log records is what was actually brought.
	var player_threats: Array = []
	for design in roster:
		player_designs.append(str(design.get("name", "")))
		for tag in CounterDraftScript.threats_of(design):
			player_threats.append(tag)
	var enemy_designs: Array = []
	for design in enemy_roster:
		enemy_designs.append(str(design.get("name", "")))
	return {
		"victory": player_won,
		"duration": duration,
		"designs": rows,
		"player_designs": player_designs,
		"player_threats": player_threats,
		"enemy_designs": enemy_designs,
	}


# "Next Engagement". Advancing is the player's choice, made here rather than at
# match end, so a lost engagement still leaves the campaign where it was until
# they say otherwise.
func _on_report_next_stage() -> void:
	var ops = _operations()
	if ops == null or not ops.advance_to_next_stage():
		get_tree().change_scene_to_file("res://scenes/MainMenu.tscn")
		return
	# Through the draft screen, not straight back into a match: re-drafting
	# between rounds is the whole reason an operation is more than a playlist.
	var router = get_node_or_null("/root/SceneRouter")
	if router:
		router.goto("res://scenes/OperationsDraft.tscn")
	else:
		get_tree().change_scene_to_file("res://scenes/OperationsDraft.tscn")


func _on_report_main_menu() -> void:
	get_tree().change_scene_to_file("res://scenes/MainMenu.tscn")


# "Iterate on this design" hands straight back to the Design Lab, which is the
# whole point of reporting per-design stats: the report is a debrief that turns
# into the next edit.
func _on_report_iterate(blueprint_name: String) -> void:
	# Which design the player asked to iterate on is remembered rather than
	# dropped on the floor. queue_blueprint_iteration() had no call site either;
	# the Lab reading it back is a separate, small piece of work, but the choice
	# has to survive the scene change before that can be written at all.
	var ops = _operations()
	if ops != null and blueprint_name != "":
		ops.queue_blueprint_iteration(blueprint_name)
	get_tree().change_scene_to_file("res://scenes/MainLab.tscn")


# --- Stat hooks the units call ------------------------------------------------
#
# Duck-typed from unit.gd, so a unit built standalone in a test needs no stats
# service at all. Player designs only: this is the player's own debrief, and
# folding the opponent's designs into it would make every column meaningless.

func record_combat_damage(victim, source, amount: float, damage_class: String) -> void:
	# Feeds the music as well as the debrief. Damage landing anywhere on the
	# field raises combat heat, which _tick_audio bleeds off again - so the
	# rhythm and lead stems rise during a real engagement and settle afterwards
	# without anything having to decide when a "battle" starts or ends.
	_combat_heat = minf(1.0, _combat_heat + amount * COMBAT_HEAT_PER_DAMAGE)

	if stats == null:
		return
	stats.record_damage(_design_of(source), _design_of(victim), amount, damage_class)


func record_unit_lost(victim, source) -> void:
	if _audio != null and "team" in victim and victim.team == PLAYER_TEAM:
		_audio.play_voice("radio_unit_lost")
	# PR5 (2026-08-15). An enemy loss changes the commander's threat
	# balance, so flag the world dirty. Ally losses are also flagged -
	# the commander's own army shrinking is the same kind of change.
	# record_unit_lost fires for both teams via the unit.died signal.
	if commander != null:
		commander.set_dirty()

	# Lifecycle log line. Source may be null (death by self-destruct, a
	# wreck, a no-killer kill) - the log records whatever the engine
	# gave us rather than guessing. Cause is the source's class_name
	# when it has one, "unknown" otherwise.
	var cause := "unknown"
	if is_instance_valid(source):
		cause = source.get_script().resource_path.get_file() if source.get_script() != null else "engine"
	var victim_name := String(victim.design_name) if "design_name" in victim \
		else String(victim.name) if "name" in victim else "?"
	var victim_kind := String(victim._hull_type) if "_hull_type" in victim \
		else "unknown"
	var victim_team := int(victim.team) if "team" in victim else -1
	BattleLogger.unit_died(victim_name, victim_team, victim_kind, cause)

	if stats == null:
		return
	if "team" in victim and victim.team == PLAYER_TEAM:
		stats.record_lost(_design_of(victim))
	var killer := _design_of(source)
	# Credited only when the blow names a design AND that design is the player's.
	# Splash from a detonating harvester, or a unit that drove into the sea,
	# lands in nobody's column rather than being guessed at.
	if not killer.is_empty() and "team" in source and source.team == PLAYER_TEAM:
		stats.record_kill(killer)


# The design behind a damage source, which may be a unit, a structure, a bare
# position, or nothing at all.
func _design_of(thing) -> Dictionary:
	if thing == null or thing is Vector3 or not is_instance_valid(thing):
		return {}
	if "blueprint" in thing and thing.blueprint is Dictionary:
		if "team" in thing and thing.team != PLAYER_TEAM:
			return {}
		return thing.blueprint
	return {}


# --- Contracts the economy systems look for ----------------------------------

# --- Resource node work slots ------------------------------------------------
#
# THE SAME PROBLEM AS THE REFINERY BAYS, AT THE OTHER END OF THE LOOP, and the
# first version of this phase fixed only one of them. Docking was reserved, so
# harvesters no longer piled onto the refinery - and then all three drove to the
# nearest ore patch, steered at its exact origin, and stacked there instead
# (measured: 0.12 m apart). Reserving one end of a round trip and not the other
# just moves the scrum.
#
# So a node has work slots on a ring, claimed the same way a bay is, and node
# selection prefers a patch with room. Kept here rather than on resource_node.gd
# because that script is shared with the old Skirmish scene, which this rebuild
# leaves alone.
const NODE_WORK_SLOTS := 4
const NODE_WORK_RADIUS := 3.2

var _node_claims: Dictionary = {}


func _claims_for(node: Node3D) -> Array:
	var key := node.get_instance_id()
	if not _node_claims.has(key):
		var slots: Array = []
		slots.resize(NODE_WORK_SLOTS)
		slots.fill(null)
		_node_claims[key] = slots
	return _node_claims[key]


func claim_node_slot(node: Node3D, unit: Node) -> int:
	if not is_instance_valid(node):
		return -1
	var slots := _claims_for(node)
	for i in range(slots.size()):
		if slots[i] == unit:
			return i
	for i in range(slots.size()):
		# A slot held by a freed unit is reclaimed here, so a harvester dying at
		# an ore patch does not permanently shrink that patch's capacity.
		if slots[i] == null or not is_instance_valid(slots[i]):
			slots[i] = unit
			return i
	return -1


func release_node_slot(node: Node3D, unit: Node) -> void:
	if not is_instance_valid(node):
		return
	var slots := _claims_for(node)
	for i in range(slots.size()):
		if slots[i] == unit:
			slots[i] = null
			return


func node_slot_position(node: Node3D, slot: int) -> Vector3:
	if not is_instance_valid(node):
		return Vector3.ZERO
	if slot < 0:
		return node.global_position
	var angle := TAU * float(slot) / float(NODE_WORK_SLOTS)
	return node.global_position + Vector3(cos(angle), 0.0, sin(angle)) * NODE_WORK_RADIUS


func _free_slots(node: Node3D) -> int:
	var free := 0
	for holder in _claims_for(node):
		if holder == null or not is_instance_valid(holder):
			free += 1
	return free


# Nearest node WITH ROOM, falling back to nearest overall.
#
# Distance alone sends every harvester to the same patch, which is both a traffic
# jam and bad economics - four trucks queueing at one patch while three others
# sit untouched. The occupancy penalty spreads them without needing a scheduler.
func nearest_resource_node(from: Vector3, requester: Node = null) -> Node3D:
	var best: Node3D = null
	var best_score := INF
	var best_any: Node3D = null
	var best_any_distance := INF
	for n in get_tree().get_nodes_in_group("resource_nodes"):
		if not is_instance_valid(n) or n.amount <= 0:
			continue
		var distance: float = from.distance_to(n.global_position)
		if distance < best_any_distance:
			best_any_distance = distance
			best_any = n
		if requester != null and _free_slots(n) <= 0:
			continue
		# Each occupant makes a patch read as this much further away. Enough that
		# an empty patch a short walk further wins, small enough that a lone
		# harvester does not cross the map to avoid one neighbour.
		var occupied: int = NODE_WORK_SLOTS - _free_slots(n)
		# VALUE-WEIGHTED DISTANCE. A round trip costs the same time whatever is in
		# the hopper, so what a harvester should maximise is credits per trip, not
		# metres saved. Dividing by relative value expresses that as effective
		# distance: oil at 4.0 credits reads at ~0.4x its real distance, lumber at
		# 1.0 reads at 1.5x.
		#
		# WITHOUT THIS THE WHOLE RESOURCE DESIGN INVERTS. Measured: with lumber
		# stands authored close to each base - deliberately, as the safe opening
		# income - pure nearest-node targeting sent every truck to lumber and
		# NOTHING else. Crystal income was exactly 0.00/s across a three-minute
		# run. The cheapest resource on the map won every contest because it was
		# the closest, which is the precise opposite of "resources differ by value
		# density".
		var value_scale: float = ResourceCatalogScript.credits("ore") \
			/ maxf(0.01, ResourceCatalogScript.credits(n.resource_type))
		var score: float = distance * value_scale + float(occupied) * 18.0 \
			- _shortage_pull(requester, n.resource_type)
		if score < best_score:
			best_score = score
			best = n
	return best if best != null else best_any


# How much closer a patch of `resource_type` reads when the team is short of it,
# in metres of effective distance.
#
# WHY A DISTANCE DISCOUNT AND NOT A HARD PREFERENCE. Harvesters used to pick
# purely on distance plus crowding, so a team sitting at zero metal with a full
# crystal stockpile would keep sending every harvester to the crystal patch that
# happened to be nearer - the economy starves on one axis while the other
# overflows, and the player watches it happen with no way to intervene short of
# manual orders.
#
# Expressed as a discount on the score rather than as a filter because the
# alternative - "always take the scarce type" - makes harvesters walk past a
# patch at their feet to cross the map, which costs more income than the
# imbalance did. At SHORTAGE_PULL a completely empty stockpile is worth about
# half the map's short axis; a patch further away than that is still not worth
# the trip.
#
# The ramp is against a REFERENCE stock rather than against the other resource:
# what matters is "can I afford to build things", not which pile is bigger.
# Comparing the two piles directly would have a team with 20 metal and 10 crystal
# behaving as though it were flush.
const SHORTAGE_PULL := 55.0
const SHORTAGE_REFERENCE := 700.0

func _shortage_pull(requester: Node, resource_type: String) -> float:
	if requester == null or economy == null:
		return 0.0
	var team: int = requester.team
	# ONE POOL now, so scarcity is simply "am I broke" rather than "am I broke in
	# the particular currency this patch happens to pay out". `resource_type` is
	# kept in the signature because value weighting in nearest_resource_node()
	# already differentiates the types, and a future rule may want to again.
	var stock: float = float(economy.credits(team))
	var scarcity: float = clampf(1.0 - stock / SHORTAGE_REFERENCE, 0.0, 1.0)
	return scarcity * SHORTAGE_PULL


func nearest_refinery(from: Vector3, for_team: int) -> Node3D:
	var best: Node3D = null
	var best_distance := INF
	for s in get_team_structures(for_team):
		if s.kind != "refinery":
			continue
		var d: float = from.distance_squared_to(s.global_position)
		if d < best_distance:
			best_distance = d
			best = s
	return best


func deliver(for_team: int, amount: int) -> void:
	economy.credit(for_team, amount)


func structures_of_kinds(for_team: int, kinds: Array) -> Array:
	var out: Array = []
	for s in get_team_structures(for_team):
		if s.kind in kinds:
			out.append(s)
	return out


# Anything parked on a finished unit's exit. A completed job waits rather than
# spawning a unit on top of whatever is sitting there.
func exit_blockers_for(for_team: int, queue_name: String) -> Array:
	var factory := _exit_structure(for_team, queue_name)
	if factory == null:
		return []
	var out: Array = []
	var exit := factory.exit_position()
	for u in get_tree().get_nodes_in_group("units"):
		if is_instance_valid(u) and not u.is_dead and u.global_position.distance_to(exit) < 3.5:
			out.append(u)
	return out


# Blockers get a real shove rather than being silently phased through.
func nudge_blockers(for_team: int, queue_name: String, blockers: Array) -> void:
	var factory := _exit_structure(for_team, queue_name)
	if factory == null:
		return
	var exit := factory.exit_position()
	for u in blockers:
		if not is_instance_valid(u):
			continue
		var blocker_pos: Vector3 = u.global_position
		var away := blocker_pos - exit
		away.y = 0.0
		if away.length() < 0.01:
			away = Vector3(1, 0, 0)
		orders.move([u], u.global_position + away.normalized() * 6.0)


func _exit_structure(for_team: int, queue_name: String) -> Structure:
	var candidates := structures_of_kinds(for_team, BuildingCatalogScript.contributors_for(queue_name))
	return candidates[0] if not candidates.is_empty() else null


# A finished building, waiting for somewhere to go.
func _on_structure_ready(for_team: int, queue_name: String, job: Dictionary) -> void:
	var s_node = job.get("structure_node", null)
	if s_node != null and is_instance_valid(s_node):
		# Pre-placed building that just completed construction on-site
		economy.recalculate_power(for_team, get_team_structures(for_team))
		_mark_navmesh_dirty()
		structure_built.emit(for_team, job.get("kind", ""))
		return

	# Fallback for jobs without a pre-placed structure node
	if for_team == PLAYER_TEAM:
		begin_placement(queue_name, job)
		return
	var site := _ai_placement_site(for_team, job.get("kind", ""), job.get("blueprint", {}))
	if site == Vector3.INF:
		return
	production.claim_structure(for_team, queue_name)
	var blueprint: Dictionary = job.get("blueprint", {})
	if not blueprint.is_empty():
		_place_defence(blueprint, for_team, site)
	else:
		_place_structure(job.get("kind", "power_plant"), for_team, site)
	economy.recalculate_power(for_team, get_team_structures(for_team))
	_mark_navmesh_dirty()


# --- Player ghost placement ---------------------------------------------------

const GHOST_COLOR_VALID := Color(0.35, 0.85, 0.45, 0.45)
const GHOST_COLOR_INVALID := Color(0.9, 0.3, 0.25, 0.45)

var placing: Dictionary = {}
var placement_ghost: MeshInstance3D = null
var _radius_indicators_root: Node3D = null

signal placement_started(kind: String)
signal placement_finished(kind: String, placed: bool)

signal structure_built(team: int, kind: String)
signal structure_lost(team: int, kind: String)


func is_placing() -> bool:
	return not placing.is_empty()


# Entry point when the user orders a structure from the build menu.
# Sets up placement mode immediately so the user chooses where to build before work begins.
func start_building_placement(queue_name: String, item: Dictionary) -> void:
	if is_placing():
		_clear_ghost()
		_clear_radius_indicators()
		placing = {}

	var blueprint: Dictionary = item.get("blueprint", {})
	var kind: String = item.get("kind", "power_plant")
	var cost: int = int(item.get("cost", 100))
	var base_time: float = float(item.get("time", 10.0))

	# Tech tree / contributor gate check before raising ghost
	if production.contributor_count(PLAYER_TEAM, queue_name) <= 0:
		_flash("NO FACTORY FOR %s QUEUE" % queue_name.to_upper())
		return
	if not blueprint.is_empty() and not production.missing_required_buildings(PLAYER_TEAM, blueprint).is_empty():
		_flash("TECH PREREQUISITES NOT MET")
		return

	placing = {
		"queue": queue_name,
		"kind": kind,
		"blueprint": blueprint,
		"cost": cost,
		"time": base_time,
		"from_order": true,
	}
	_build_ghost()
	_build_radius_indicators()
	placement_started.emit(placing["kind"])
	_flash("PLACE %s  -  LEFT CLICK TO SITE, RIGHT CLICK / ESC TO CANCEL" % kind.replace("_", " ").to_upper())


# Legacy/fallback entry point for a completed job waiting to be placed
func begin_placement(queue_name: String, job: Dictionary) -> void:
	if is_placing():
		return
	placing = {
		"queue": queue_name,
		"kind": job.get("kind", "power_plant"),
		"blueprint": job.get("blueprint", {}),
		"cost": job.get("total_cost", 100),
		"time": job.get("total_time", 10.0),
		"from_order": false,
		"job": job,
	}
	_build_ghost()
	_build_radius_indicators()
	placement_started.emit(placing["kind"])
	_flash("PLACE BUILDING  -  LEFT CLICK TO SITE, ESC TO HOLD")


func resume_placement(queue_name: String) -> bool:
	if is_placing():
		return false
	var q: Array = production.queue(PLAYER_TEAM, queue_name)
	if q.is_empty():
		return false
	var job: Dictionary = q[0]
	if not job.get("is_structure", false) or not job.get("done", false):
		return false
	begin_placement(queue_name, job)
	return true


func _build_ghost() -> void:
	_clear_ghost()
	var footprint: Vector3 = PlacementServiceScript.footprint_for(
		placing["kind"], placing["blueprint"])
	placement_ghost = MeshInstance3D.new()
	var box := BoxMesh.new()
	box.size = footprint
	placement_ghost.mesh = box
	var mat := StandardMaterial3D.new()
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.albedo_color = GHOST_COLOR_INVALID
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	placement_ghost.material_override = mat
	add_child(placement_ghost)


func _clear_ghost() -> void:
	if is_instance_valid(placement_ghost):
		placement_ghost.queue_free()
	placement_ghost = null


# Visual build-radius rings rendered around all friendly structures that provide buildable area
func _build_radius_indicators() -> void:
	_clear_radius_indicators()
	_radius_indicators_root = Node3D.new()
	_radius_indicators_root.name = "BuildRadiusIndicators"
	add_child(_radius_indicators_root)

	var reach: float = PlacementServiceScript.adjacency_for(
		placing.get("kind", "power_plant"), placing.get("blueprint", {}))
	
	var ring_mat := StandardMaterial3D.new()
	ring_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	ring_mat.albedo_color = Color(0.2, 0.8, 1.0, 0.3)
	ring_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	ring_mat.cull_mode = BaseMaterial3D.CULL_DISABLED

	for s in get_tree().get_nodes_in_group("structures"):
		if not is_instance_valid(s) or s.is_dead or not s.is_inside_tree():
			continue
		if s.team != PLAYER_TEAM:
			continue
		if not BuildingCatalogScript.get_stat(s.kind, "gives_buildable_area", false):
			continue
		var s_half: float = maxf(s.footprint.x, s.footprint.z) * 0.5
		var total_radius: float = s_half + reach
		
		var ring := MeshInstance3D.new()
		var torus := TorusMesh.new()
		torus.inner_radius = total_radius - 0.4
		torus.outer_radius = total_radius + 0.4
		torus.rings = 48
		torus.ring_segments = 4
		ring.mesh = torus
		ring.material_override = ring_mat
		ring.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		_radius_indicators_root.add_child(ring)
		ring.global_position = Vector3(s.global_position.x, terrain_height_at(s.global_position) + 0.08, s.global_position.z)


func _clear_radius_indicators() -> void:
	if _radius_indicators_root != null and is_instance_valid(_radius_indicators_root):
		_radius_indicators_root.queue_free()
	_radius_indicators_root = null


func update_placement(screen_pos: Vector2) -> void:
	if not is_placing() or not is_instance_valid(placement_ghost):
		return
	var hit := _raycast(screen_pos, LayersScript.GROUND_PICK_MASK, false)
	if hit.is_empty():
		return
	var at: Vector3 = hit.position
	at.y = terrain_height_at(at)
	var result := placement_validity(at)
	placement_ghost.global_position = at + Vector3(0, placement_ghost.mesh.size.y * 0.5, 0)
	placement_ghost.material_override.albedo_color = \
		GHOST_COLOR_VALID if result["valid"] else GHOST_COLOR_INVALID


func placement_validity(at: Vector3) -> Dictionary:
	if not is_placing():
		return {"valid": false, "reason": "NOTHING TO PLACE"}
	return PlacementServiceScript.validity(
		self, PLAYER_TEAM, at, placing["kind"], placing["blueprint"])


func confirm_placement(at: Vector3) -> bool:
	if not is_placing():
		return false
	at.y = terrain_height_at(at)
	var result := placement_validity(at)
	if not result["valid"]:
		_flash(result["reason"])
		return false

	var blueprint: Dictionary = placing.get("blueprint", {})
	var kind: String = placing.get("kind", "power_plant")
	var queue_name: String = placing.get("queue", "building")
	var from_order: bool = placing.get("from_order", false)

	if from_order:
		# User-driven placement on order: spawn under-construction structure and start queue job
		var cost: int = placing.get("cost", 100)
		var base_time: float = placing.get("time", 10.0)

		var s: Structure = null
		if not blueprint.is_empty():
			s = _place_defence(blueprint, PLAYER_TEAM, at, true)
		else:
			s = _place_structure(kind, PLAYER_TEAM, at, true)

		if s == null:
			_end_placement(false)
			return false

		var job := production.enqueue_structure(PLAYER_TEAM, queue_name, kind, cost, base_time, blueprint, s)
		if job.is_empty():
			s.queue_free()
			_end_placement(false)
			return false

		s.begin_construction(job.get("total_time", base_time))
		_mark_navmesh_dirty()
		_end_placement(true)
		return true

	# Legacy post-build placement
	var job: Dictionary = production.claim_structure(PLAYER_TEAM, placing["queue"])
	if job.is_empty():
		_end_placement(false)
		return false

	if not blueprint.is_empty():
		_place_defence(blueprint, PLAYER_TEAM, at)
	else:
		_place_structure(kind, PLAYER_TEAM, at)
	economy.recalculate_power(PLAYER_TEAM, get_team_structures(PLAYER_TEAM))
	_mark_navmesh_dirty()
	_end_placement(true)
	return true


func cancel_placement() -> void:
	if not is_placing():
		return
	if placing.get("from_order", false):
		_flash("PLACEMENT CANCELLED")
	else:
		_flash("BUILDING HELD  -  CLICK ITS QUEUE TO PLACE")
	_end_placement(false)


func _end_placement(placed: bool) -> void:
	var kind: String = placing.get("kind", "")
	placing = {}
	_clear_ghost()
	_clear_radius_indicators()
	placement_finished.emit(kind, placed)


# --- Pre-game HQ placement ---------------------------------------------------
#
# The pre-game phase is its own placement mode, NOT a sibling of the build-queue
# ghost. Three reasons it sits in its own state:
#   1. The HQ is FREE. It is given to the player, not produced - so the path
#      cannot go through confirm_placement() (which claims a job from a
#      production queue and decrements resources). The whole flow is its own
#      chain: begin_hq_placement -> update_hq_placement -> confirm_hq_placement
#      which ends at place_hq_for_human().
#   2. The validity rule is ZONE-CONSTRAINED, not the standard
#      PlacementServiceScript.validity() block-tests / no-overlap / etc. The
#      player must drop the HQ INSIDE their assigned half_extents rectangle
#      (place_hq_for_human already enforces this - the ghost just visualises
#      the rule, never re-implements it).
#   3. The ghost needs TWO meshes, not one: the HQ footprint following the
#      cursor, AND a wireframe of the assigned base zone. The wireframe is
#      what tells the player "drop it here" - a 15x15 rectangle is a much
#      stronger affordance than a single HQ ghost hovering over empty ground.
#
# Mouse wiring reuses the same _unhandled_input switch as the build-queue
# placement - a separate code path is unnecessary because the only thing
# different about pre-game clicks is which commit function runs at the end.
var placing_hq: bool = false
var hq_ghost: MeshInstance3D = null
var hq_zone_highlight: MeshInstance3D = null
var hq_ghost_pos: Vector3 = Vector3.ZERO  # last valid (clamped) position; survives raycast misses

# A pre-game HQ placement lifecycle signal. The BattleHUD listens to
# this to swap its prompt banner between "DROP YOUR HQ IN THE HIGHLIGHTED
# ZONE" (placement_started) and the normal in-match UI (placement_finished
# with placed=true). The signal name mirrors placement_started/finished so
# the HUD can use a single subscription pattern for both phases.
signal hq_placement_started
signal hq_placement_finished(placed: bool)


func is_placing_hq() -> bool:
	return placing_hq


# Arms the pre-game phase. Called from _spawn_bases() after the base-zone
# assignment on maps that HAVE base zones; no-op otherwise. The same input
# flow as build-queue placement takes over from here.
func _enter_hq_placement() -> void:
	if placing_hq:
		return
	# Don't enter pre-game placement in Test Range. Test Range drives its
	# own spawn flow and expects the player HQ to be live from frame 1.
	# _match_rule_set is the cached rule set from _ready(); reading from
	# the member is the same pattern _spawn_bases() and _setup_vision()
	# use to gate on mode. Also guard on null for headless test paths.
	if _match_rule_set != null and _match_rule_set.mode == MatchRuleSetScript.Mode.TEST_RANGE:
		return
	placing_hq = true
	_build_hq_zone_highlight()
	_build_hq_ghost()
	hq_placement_started.emit()
	_flash("PLACE YOUR HQ  -  CLICK IN THE HIGHLIGHTED ZONE")


# Public. The BattleHUD or any test driver can call this to drop out
# of the pre-game phase without placing (cancels). Used by the AI-vs-AI
# smoke path and by the "skip pre-game" affordance if one is ever added.
func cancel_hq_placement() -> void:
	if not placing_hq:
		return
	_exit_hq_placement(false)


# Ground-following ghost. Same raycast + ground-pick as update_placement;
# the difference is what happens after the raycast lands:
#   - the ground hit is CLAMPED to the assigned base zone (a point outside
#     the half_extents rectangle is dragged to the closest point inside it,
#     so the ghost slides along the zone edge instead of going red);
#   - the ghost is recoloured by the zone test, not the placement service.
# This is why there is no _ghosting helper for both: the colour logic is
# a 2-line zone test, not the multi-rule block-tests the build queue runs.
func update_hq_placement(screen_pos: Vector2) -> void:
	if not placing_hq or not is_instance_valid(hq_ghost):
		return
	var hit := _raycast(screen_pos, LayersScript.GROUND_PICK_MASK, false)
	if hit.is_empty():
		return
	hq_ghost_pos = _clamp_to_player_zone(hit.position)
	hq_ghost.global_position = Vector3(
		hq_ghost_pos.x,
		terrain_height_at(hq_ghost_pos),
		hq_ghost_pos.z)
	# Colour by the SAME test the click uses - the ghost never lies
	# about whether the click will go through. Inside the zone = green,
	# outside = red. After the clamp above the ghost is ALWAYS inside
	# the zone, so the red branch is effectively dead code, but kept
	# for the future where the zone might be a non-axis-aligned polygon
	# that the clamp can't handle.
	var inside: bool = _is_inside_player_zone(hq_ghost_pos)
	hq_ghost.material_override.albedo_color = \
		GHOST_COLOR_VALID if inside else GHOST_COLOR_INVALID


# Public. The click handler routes here from _unhandled_input when
# placing_hq is true. place_hq_for_human does the actual placement and
# the validity check - this wrapper just gates the path and exits the
# placement mode on success.
func confirm_hq_placement() -> bool:
	if not placing_hq:
		return false
	if place_hq_for_human(hq_ghost_pos):
		_exit_hq_placement(true)
		return true
	return false


# Tear-down. Symmetric with _end_placement above. The wireframe is the
# last thing the player sees in the pre-game phase, so it's freed last
# (queue_free order is LIFO, so the wireframe at the bottom of this
# function is actually freed first - on the next frame, the HQ ghost
# disappears, then the zone highlight).
func _exit_hq_placement(placed: bool) -> void:
	placing_hq = false
	if is_instance_valid(hq_ghost):
		hq_ghost.queue_free()
	hq_ghost = null
	if is_instance_valid(hq_zone_highlight):
		hq_zone_highlight.queue_free()
	hq_zone_highlight = null
	hq_placement_finished.emit(placed)


# The zone visual: a screen-space green highlight that conforms to terrain.
# Same depth-buffer technique as the fog shroud - reads each pixel's world
# position and tints it green if within the zone bounds, with a soft edge
# fade. A ground-height lookup texture filters out trees, rocks, and other
# objects that sit above the terrain surface, so the highlight only paints
# the ground itself.
const ZONE_SHADER := """
shader_type spatial;
render_mode unshaded, blend_mix, cull_disabled, depth_draw_never, depth_test_disabled, shadows_disabled, fog_disabled;

uniform sampler2D depth_tex : hint_depth_texture, filter_nearest;
uniform sampler2D ground_height_tex : filter_nearest, repeat_disable;
uniform vec3 zone_center = vec3(0.0, 0.0, 0.0);
uniform vec2 zone_half = vec2(20.0, 20.0);
uniform vec2 zone_xz_min = vec2(-20.0, -20.0);
uniform vec2 zone_xz_max = vec2(20.0, 20.0);
uniform vec2 height_range = vec2(0.0, 10.0);
uniform float map_half = 80.0;
uniform vec3 zone_color = vec3(0.25, 1.0, 0.35);
uniform float edge_feather = 0.15;
uniform float ground_tolerance = 1.8;

void vertex() {
	POSITION = vec4(VERTEX.xy * 2.0, 1.0, 1.0);
}

void fragment() {
	float d = texture(depth_tex, SCREEN_UV).r;
	if (d <= 0.000001 || d >= 0.999999) {
		discard;
	}
	vec3 ndc = vec3(SCREEN_UV * 2.0 - 1.0, d);
	vec4 view = INV_PROJECTION_MATRIX * vec4(ndc, 1.0);
	view.xyz /= view.w;
	vec3 world = (INV_VIEW_MATRIX * vec4(view.xyz, 1.0)).xyz;
	// Off the edge of the map there is no zone to highlight.
	vec2 map_uv = (world.xz + vec2(map_half)) / (2.0 * map_half);
	if (map_uv.x < 0.0 || map_uv.x > 1.0 || map_uv.y < 0.0 || map_uv.y > 1.0) {
		discard;
	}
	// Distance from zone edge as a 0..1 fraction of half_extents.
	vec2 d_zone = abs(world.xz - zone_center.xz) - zone_half;
	float outside = max(d_zone.x, d_zone.y);
	float inside = -outside;
	if (inside < 0.0) {
		discard;
	}
	// Ground-height filter: look up expected terrain Y at this world XZ and
	// reject pixels that are significantly above it (trees, rocks, buildings).
	vec2 guv = (world.xz - zone_xz_min) / max(zone_xz_max - zone_xz_min, vec2(0.01));
	if (guv.x >= 0.0 && guv.x <= 1.0 && guv.y >= 0.0 && guv.y <= 1.0) {
		float encoded = texture(ground_height_tex, guv).r;
		float ground_y = mix(height_range.x, height_range.y, encoded);
		if (abs(world.y - ground_y) > ground_tolerance) {
			discard;
		}
	}
	// Feather the last edge_feather fraction of the zone as soft edge.
	float alpha = smoothstep(0.0, zone_half.x * edge_feather, inside);
	ALBEDO = zone_color;
	ALPHA = alpha * 0.45;
}
"""

func _build_hq_zone_highlight() -> void:
	var zone_id: String = _team_base_zone.get(PLAYER_TEAM, "")
	if zone_id == "":
		return
	var zone: Dictionary = MapCatalog.get_base_zone(current_map, zone_id)
	if zone.is_empty():
		return
	var center: Vector3 = zone.get("center", Vector3.ZERO)
	var half: Vector2 = zone.get("half_extents", Vector2.ZERO)
	# Build a ground-height lookup texture covering the zone area. Each pixel
	# encodes the terrain Y at that XZ position, normalised to 0..1 within
	# the zone's height range. The shader uses this to skip pixels that are
	# above ground level (trees, rocks, buildings).
	const TEX_SIZE := 64
	var x_min: float = center.x - half.x
	var x_max: float = center.x + half.x
	var z_min: float = center.z - half.y
	var z_max: float = center.z + half.y
	var min_y := INF
	var max_y := -INF
	var heights: PackedFloat32Array = []
	heights.resize(TEX_SIZE * TEX_SIZE)
	for tz in range(TEX_SIZE):
		for tx in range(TEX_SIZE):
			var wx: float = lerpf(x_min, x_max, float(tx) / float(TEX_SIZE - 1))
			var wz: float = lerpf(z_min, z_max, float(tz) / float(TEX_SIZE - 1))
			var h: float = terrain_height_at(Vector3(wx, 0.0, wz))
			heights[tz * TEX_SIZE + tx] = h
			min_y = minf(min_y, h)
			max_y = maxf(max_y, h)
	# Encode as RGBA8 (R = normalised height) for maximum compatibility.
	var img := Image.create(TEX_SIZE, TEX_SIZE, false, Image.FORMAT_RGBA8)
	var y_range: float = maxf(max_y - min_y, 0.01)
	for tz in range(TEX_SIZE):
		for tx in range(TEX_SIZE):
			var norm: float = clampf((heights[tz * TEX_SIZE + tx] - min_y) / y_range, 0.0, 1.0)
			var v: int = int(norm * 255.0)
			img.set_pixel(tx, tz, Color(v / 255.0, 0.0, 0.0, 1.0))
	var tex := ImageTexture.create_from_image(img)
	var highlight := MeshInstance3D.new()
	highlight.mesh = QuadMesh.new()
	highlight.custom_aabb = AABB(Vector3(-1e6, -1e6, -1e6), Vector3(2e6, 2e6, 2e6))
	highlight.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var shader := Shader.new()
	shader.code = ZONE_SHADER
	var mat := ShaderMaterial.new()
	mat.shader = shader
	mat.set_shader_parameter("ground_height_tex", tex)
	mat.set_shader_parameter("zone_center", Vector3(center.x, 0.0, center.z))
	mat.set_shader_parameter("zone_half", Vector2(half.x, half.y))
	mat.set_shader_parameter("zone_xz_min", Vector2(x_min, z_min))
	mat.set_shader_parameter("zone_xz_max", Vector2(x_max, z_max))
	mat.set_shader_parameter("height_range", Vector2(min_y, max_y))
	mat.set_shader_parameter("map_half", current_map.get("map_half_extents", 80.0))
	mat.render_priority = 126
	highlight.material_override = mat
	add_child(highlight)
	hq_zone_highlight = highlight


# The HQ ghost itself: a flat box sized to the HQ's footprint, follows
# the cursor (clamped to the zone), recoloured by the zone test. Same
# shader / material pattern as the build-queue ghost - same unshaded +
# transparent tints so the green-vs-red reads the same to the player.
func _build_hq_ghost() -> void:
	var footprint: Vector3 = PlacementServiceScript.footprint_for("hq", {})
	hq_ghost = MeshInstance3D.new()
	var box := BoxMesh.new()
	box.size = footprint
	hq_ghost.mesh = box
	var mat := StandardMaterial3D.new()
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.albedo_color = GHOST_COLOR_INVALID
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	hq_ghost.material_override = mat
	hq_ghost.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(hq_ghost)


# Clamp a point to the player's base zone (axis-aligned half_extents
# rectangle). The clamp drags an outside point to the closest point
# inside, so a player dragging the cursor just past the zone edge
# sees the ghost slide along the edge rather than flip red.
func _clamp_to_player_zone(p: Vector3) -> Vector3:
	var zone_id: String = _team_base_zone.get(PLAYER_TEAM, "")
	if zone_id == "":
		return p
	var zone: Dictionary = MapCatalog.get_base_zone(current_map, zone_id)
	if zone.is_empty():
		return p
	var center: Vector3 = zone.get("center", Vector3.ZERO)
	var half: Vector2 = zone.get("half_extents", Vector2.ZERO)
	var clamped_x: float = clampf(p.x, center.x - half.x, center.x + half.x)
	var clamped_z: float = clampf(p.z, center.z - half.y, center.z + half.y)
	return Vector3(clamped_x, p.y, clamped_z)


# Inside-the-zone test, mirroring place_hq_for_human's own absf() check.
# The double implementation is intentional: a future non-axis-aligned
# zone shape would change this test but not place_hq_for_human, and the
# ghost would then LIE about whether the click will go through. Both
# need to be updated in lockstep, which is what the comment on
# place_hq_for_human is for.
func _is_inside_player_zone(p: Vector3) -> bool:
	var zone_id: String = _team_base_zone.get(PLAYER_TEAM, "")
	if zone_id == "":
		return false
	var zone: Dictionary = MapCatalog.get_base_zone(current_map, zone_id)
	if zone.is_empty():
		return false
	var center: Vector3 = zone.get("center", Vector3.ZERO)
	var half: Vector2 = zone.get("half_extents", Vector2.ZERO)
	return absf(p.x - center.x) <= half.x and absf(p.z - center.z) <= half.y


# A blueprint-built turret. Same lifecycle as any other structure - it carves the
# navmesh, it dies through the same signal, it ends the match if it were an HQ -
# it just gets its geometry and its guns from a design instead of the catalog.
# SKIRMISH_PERF_TROUBLESHOOTING.md §10.4. This was the one placement path with
# NO profiler section at all: `_place_structure` has had `place_structure` since
# the first pass, but a defence built by the AI went through here and was timed
# nowhere - it just inflated `commander.execute`. `setup_from_blueprint` runs the
# full blueprint reconstruction (hull mesh, modules, materials), which is the
# same work `spawn.assemble` measures at ~120 ms on a unit, so this is a strong
# candidate for the missing ~200 ms per AI decision.
func _place_defence(blueprint: Dictionary, structure_team: int, at: Vector3, under_construction: bool = false) -> Structure:
	var _t := Profiler.start()
	var out := _place_defence_impl(blueprint, structure_team, at, under_construction)
	Profiler.stop("place_defence", _t)
	return out


func _place_defence_impl(blueprint: Dictionary, structure_team: int, at: Vector3, under_construction: bool = false) -> Structure:
	var s := StructureScript.new()
	add_child(s)
	s.position = Vector3(at.x, terrain_height_at(at), at.z)
	if not s.setup_from_blueprint(blueprint, structure_team, bp_manager):
		# The design names a hull the catalog no longer has. A half-built turret
		# is worse than none, and the money is already spent either way.
		s.queue_free()
		return null
	s.died.connect(_on_structure_died)
	# Dust cloud masks terrain intersection at the building's edges.
	var foot: Vector2 = Vector2(s.footprint.x, s.footprint.z)
	VFXEffectsScript.dust_cloud(self, s.position, foot * 0.5)
	# Displace overlapping terrain props (greebles, grass, rocks).
	_displace_terrain_props(at, foot * 0.5)
	# Apply distance-based visibility range to defense hull/turret mesh subtree
	_apply_structure_visibility_range(s)
	if vision != null:
		var fp: Vector3 = s.footprint if "footprint" in s else Vector3(4, 3, 4)
		vision.invalidate_los_cache(s.global_position, maxf(fp.x, fp.z))
	if not under_construction:
		structure_built.emit(structure_team, "defense")
	return s


# Queue a defensive structure from the AI's roster.
func ai_build_defence(for_team: int) -> bool:
	var _t := Profiler.start()
	var ok := _ai_build_defence_impl(for_team)
	Profiler.stop("ai.build_defence", _t)
	return ok


func _ai_build_defence_impl(for_team: int) -> bool:
	var design := ai_design_for_role(for_team, "defense")
	if design.is_empty():
		return false
	var cost: int = DesignCostingScript.blueprint_cost(design)
	var b_time: float = DesignCostingScript.build_time_for_cost(cost)
	var site := _ai_placement_site(for_team, "defense", design)
	if site != Vector3.INF:
		var s := _place_defence(design, for_team, site, true)
		if s == null:
			return false
		s.begin_construction(b_time)
		var job := production.enqueue_structure(for_team,
			BuildingCatalogScript.QUEUE_DEFENSE, "defense",
			cost, b_time, design, s)
		if job.is_empty():
			s.queue_free()
			return false
		_mark_navmesh_dirty()
		return true

	return not production.enqueue_structure(for_team,
		BuildingCatalogScript.QUEUE_DEFENSE, "defense",
		cost, b_time, design).is_empty()


# Where the AI puts its next building. Delegates to PlacementService, which is
# the same call the player's ghost validates against - so the AI is held to the
# player's rules rather than to a looser private copy. It previously had one: a
# bounds/water/overlap check that ignored buildable-area adjacency entirely, and
# would happily site a power plant six rings out in open field.
#
# SKIRMISH_PERF_TROUBLESHOOTING.md §6 item 2. The 2026-08-19 log had
# `place_structure` at 44.5 ms mean / 179 ms worst across 35 invocations,
# AND `commander` at 30-120 ms per decision - the two land on the same
# frame often enough to compound into 300+ ms hitches. Profiling this
# function inside its own section (rather than relying on the outer
# `place_structure` wrapper) is what proves whether _ai_placement_site
# is the cost in the placement path or _displace_terrain_props /
# _apply_structure_visibility_range are. It is also visible as a
# `commander.execute` blow-up when the AI makes a placement, which
# the Track B instrumentation will catch.
func _ai_placement_site(for_team: int, kind: String, blueprint: Dictionary = {}) -> Vector3:
	var _t := Profiler.start()
	var site := PlacementServiceScript.find_site(
		self, for_team, _team_home(for_team), kind, blueprint)
	Profiler.stop("ai_placement_site", _t)
	return site


func _on_unit_completed(for_team: int, queue_name: String, blueprint: Dictionary) -> void:
	var factory := _exit_structure(for_team, queue_name)
	var at: Vector3 = factory.exit_position() if factory != null else Vector3.ZERO
	spawn_unit(blueprint, for_team, snap_to_navmesh(at))


# The nearest genuinely walkable point to `at`.
#
# A unit spawned off the navmesh is not merely misplaced, it is inert: the agent
# has no valid path start, so it accepts a move order and turns to face it but
# never produces a waypoint it can leave. exit_position() is authored as a fixed
# offset from the building centre, while the hole the building actually carves
# depends on BUILDING_CLEARANCE, the navmesh grid quantisation and Recast's own
# agent-radius erosion - three things the authored constant cannot see, and all
# of which move with world scale. Snapping makes the spawn correct by
# construction instead of by a margin that has now been re-tuned twice.
#
# The snap is refused if the nearest walkable point is implausibly far, which
# means the navmesh is not built yet rather than that the exit is blocked;
# spawning at the authored point is the better failure there.
const MAX_SPAWN_SNAP := 25.0

func snap_to_navmesh(at: Vector3) -> Vector3:
	if not ground_nav_map.is_valid():
		return at
	var closest: Vector3 = NavigationServer3D.map_get_closest_point(ground_nav_map, at)
	if Vector3(closest.x, 0.0, closest.z).distance_to(Vector3(at.x, 0.0, at.z)) > MAX_SPAWN_SNAP:
		return at
	return closest


# Radial area damage. Used by the loaded-harvester detonation; the same call will
# serve splash weapons when they land.
func apply_explosion(at: Vector3, radius: float, damage: float, source: Node) -> void:
	for target in get_tree().get_nodes_in_group("damageable"):
		if target == source or not is_instance_valid(target) or target.is_dead:
			continue
		if not target.has_method("take_damage"):
			continue
		var distance: float = at.distance_to(target.global_position)
		if distance > radius:
			continue
		# Linear falloff to zero at the rim, so standing at the edge of a blast
		# is meaningfully better than standing in it.
		#
		# Explosive class, and the blast centre as the hit origin, so a splash hit
		# gets the same facet-aware treatment a direct one does - catching a tank
		# from behind with a shell should be worth what it is worth.
		target.take_damage(damage * (1.0 - distance / radius), "explosive", at)


# --- AI support --------------------------------------------------------------
#
# Everything the Commander can do to the world, and nothing more. Each of these
# forwards to the SAME service the player's own UI calls - ProductionService to
# build, OrderService to command - so there is no second path where AI-only
# behaviour could accumulate. That is the structural reason the AI cannot cheat,
# as opposed to a promise that it will not.

# Queue a design filling `role`, chosen from the AI's roster by what it actually
# mounts rather than from a hand-curated per-role list. A design the player built
# would count as anti-air if it carries a CIWS.
func ai_build_unit(for_team: int, role: String) -> bool:
	var _t := Profiler.start()
	var ok := _ai_build_unit_impl(for_team, role)
	Profiler.stop("ai.build_unit", _t)
	return ok


func _ai_build_unit_impl(for_team: int, role: String) -> bool:
	var pick: Dictionary = ai_design_for_role(for_team, role)
	# No design fills the role - fall back to any VEHICLE rather than stalling.
	if pick.is_empty():
		pick = ai_design_for_role(for_team, "general")
	if pick.is_empty():
		return false

	# AI OVERHAUL: Ammo adaptation.
	# If the commander has observed dominant enemy armor, adapt weapon ammo if possible!
	if commander != null and not commander.observed_enemy_armor.is_empty():
		var unlocked: Array = []
		for s in get_team_structures(for_team):
			if is_instance_valid(s) and not s.is_dead:
				unlocked.append(s.kind)
		pick = ThreatAnalyzerScript.adapt_ammo(pick, commander.observed_enemy_armor, unlocked)

	var cost: int = DesignCostingScript.blueprint_cost(pick)
	var queue_name: String = DesignCostingScript.queue_for_design(pick)

	if production.queue(for_team, queue_name).size() >= AI_MAX_QUEUE_DEPTH:
		return false
	return not production.enqueue_unit(for_team, pick, cost,
		DesignCostingScript.build_time_for_cost(cost), queue_name).is_empty()


const AI_MAX_QUEUE_DEPTH := 2


# A design on a foundation hull is a static defence, not a vehicle.
static func is_defence_design(blueprint: Dictionary) -> bool:
	return ModuleCatalog.is_foundation(blueprint.get("hull_type", ""))


func ai_design_for_role(for_team: int, role: String) -> Dictionary:
	var _t := Profiler.start()
	var out := _ai_design_for_role_impl(for_team, role)
	Profiler.stop("ai.design_for_role", _t)
	return out


func _ai_design_for_role_impl(_for_team: int, role: String) -> Dictionary:
	var pool: Array = enemy_roster if not enemy_roster.is_empty() else roster
	var want_defence := role == "defense"
	var target_armor: String = commander.observed_enemy_armor if commander != null else ""
	for design in pool:
		if is_defence_design(design) != want_defence:
			continue
		if want_defence or CommanderScript.design_fills_role(design, role, target_armor):
			return design
	return {}


# Can the AI actually PRODUCE something filling `role` right now - not "does a
# design exist" but "is there a factory that can build it".
#
# The distinction is the whole reason this exists. The AI's only harvester is a
# MEDIUM hull, so owning a light manufactory and a harvester design still means
# it cannot build one. Without this the commander scored "build a harvester"
# highest, called a production path that silently returned false, and starved to
# zero metal while deciding to fix its economy every two seconds.
func ai_can_build_role(for_team: int, role: String) -> bool:
	var design := ai_design_for_role(for_team, role)
	if design.is_empty():
		return false
	return production.contributor_count(for_team,
		DesignCostingScript.queue_for_design(design)) > 0


# Which manufactory to put up next.
#
# Resolved HERE rather than in the commander, so the commander can stay at the
# altitude of "I need more production" without knowing about hull tiers. It
# builds whatever unblocks the harvester first - an economy that cannot start is
# the only truly fatal state - and otherwise fills in the tiers it lacks.
func ai_build_production(for_team: int) -> bool:
	var _t := Profiler.start()
	var ok := _ai_build_production_impl(for_team)
	Profiler.stop("ai.build_production", _t)
	return ok


func _ai_build_production_impl(for_team: int) -> bool:
	var wanted := ""
	var harvester := ai_design_for_role(for_team, "harvester")
	if not harvester.is_empty() and not ai_can_build_role(for_team, "harvester"):
		wanted = _manufactory_for_queue(DesignCostingScript.queue_for_design(harvester))
	if wanted == "":
		for queue_name in [BuildingCatalogScript.QUEUE_LIGHT,
				BuildingCatalogScript.QUEUE_MEDIUM, BuildingCatalogScript.QUEUE_HEAVY]:
			if production.contributor_count(for_team, queue_name) <= 0:
				wanted = _manufactory_for_queue(queue_name)
				break
	# Every tier covered - add another of the cheapest, which speeds that queue up
	# via the RA table rather than opening a second line.
	if wanted == "":
		wanted = "light_manufactory"
	return ai_build_structure(for_team, wanted)


func _manufactory_for_queue(queue_name: String) -> String:
	var kinds: Array = BuildingCatalogScript.CONTRIBUTORS.get(queue_name, [])
	return kinds[0] if not kinds.is_empty() else "light_manufactory"


# SKIRMISH_PERF_TROUBLESHOOTING.md §10.4. `commander.execute` measured 250 ms
# mean / 490 ms worst across 71 calls, and the two sections already nested
# inside it - `place_structure` (47.9 ms) and `ai_placement_site` (3.3 ms) -
# account for barely a fifth of that. The remaining ~200 ms per call is
# somewhere in these four ai_build_* entry points, and until each one is timed
# separately there is no way to tell which.
#
# WHY A WRAPPER RATHER THAN INLINE TOKENS. Every one of these functions has
# several early `return`s, and GDScript has no defer - an inline
# Profiler.start()/stop() pair would silently leak the token on whichever path
# a future edit adds. The public name keeps the profiler pairing, the _impl
# holds the original body unchanged.
#
# These NEST (ai_build_production calls ai_build_structure; all of them call
# ai_design_for_role), so their totals must not be added together. Read each
# against its own call count.
func ai_build_structure(for_team: int, kind: String) -> bool:
	var _t := Profiler.start()
	var ok := _ai_build_structure_impl(for_team, kind)
	Profiler.stop("ai.build_structure", _t)
	return ok


func _ai_build_structure_impl(for_team: int, kind: String) -> bool:
	var stats := BuildingCatalogScript.get_stats(kind)
	if stats.is_empty():
		return false
	var cost: int = ResourceCatalogScript.credits_from_materials(Vector2i(
		stats.get("cost_metal", 0), stats.get("cost_crystal", 0)))
	var b_time: float = stats.get("build_time", 10.0)
	var site := _ai_placement_site(for_team, kind, {})
	if site != Vector3.INF:
		var s := _place_structure(kind, for_team, site, true)
		if s == null:
			return false
		s.begin_construction(b_time)
		var job := production.enqueue_structure(for_team,
			BuildingCatalogScript.QUEUE_BUILDING, kind, cost, b_time, {}, s)
		if job.is_empty():
			s.queue_free()
			return false
		_mark_navmesh_dirty()
		return true

	return not production.enqueue_structure(for_team,
		BuildingCatalogScript.QUEUE_BUILDING, kind,
		cost, b_time).is_empty()


# Pull everything home. The rally is the AI's own HQ.
func ai_defend(for_team: int, combat: Array) -> void:
	var home := _team_home(for_team)
	var sm = _ai_squad_manager(for_team, combat, home)
	if sm != null:
		sm.defend()
	else:
		_ai_squad(for_team, combat, home).objective = home


# Commit to an attack on the enemy HQ.
func ai_push(for_team: int, combat: Array) -> void:
	var target := _team_home(PLAYER_TEAM if for_team != PLAYER_TEAM else ENEMY_TEAM)
	var sm = _ai_squad_manager(for_team, combat, _team_home(for_team))
	if sm != null:
		sm.push(target)
	else:
		_ai_squad(for_team, combat, _team_home(for_team)).objective = target


func _team_home(for_team: int) -> Vector3:
	for s in get_team_structures(for_team):
		if s.kind == "hq":
			return s.global_position
	var spawn := MapCatalog.get_spawn(current_map,
		"player" if for_team == PLAYER_TEAM else "enemy")
	return spawn.get("hq", Vector3.ZERO) if not spawn.is_empty() else Vector3.ZERO


func _ai_squad_manager(for_team: int, combat: Array, rally: Vector3) -> SquadManager:
	var target := _team_home(PLAYER_TEAM if for_team != PLAYER_TEAM else ENEMY_TEAM)
	var bounds := Rect2()
	if current_map.has("map_half_extents"):
		var h: float = float(current_map.get("map_half_extents", 80.0))
		bounds = Rect2(-h, -h, h * 2.0, h * 2.0)

	if not _squad_managers.has(for_team):
		var sm: SquadManager = SquadManagerScript.new()
		sm.setup(self, orders, for_team, rally, target, bounds)
		_squad_managers[for_team] = sm

	var mgr: SquadManager = _squad_managers[for_team]
	mgr.assign_units(combat)
	return mgr


# Fallback for single-squad / test access
func _ai_squad(for_team: int, combat: Array, rally: Vector3):
	if not _squads.has(for_team) or _squads[for_team].is_spent():
		var squad = SquadScript.new()
		squad.setup(self, orders, for_team, combat, rally)
		_squads[for_team] = squad
	else:
		_squads[for_team].reinforce(combat)
	return _squads[for_team]


# --- Weapon support ----------------------------------------------------------
#
# auto_weapon.gd duck-types every one of these off `get_tree().current_scene` and
# guards each with has_method(), so a missing one degrades rather than crashes.
# That is exactly why they are worth writing down: the degraded behaviours are
# silent and individually plausible - weapons that never miss a fog check,
# defences that ignore low power - so an absent method reads as a balance
# problem rather than as a missing method.

# Two teams, so alliance is equality. The legacy runtime carries a real alliance
# table for multi-slot matches; that ports with the slot system, not before it,
# and pretending otherwise here would be a stub that looks finished.
func is_allied(a: int, b: int) -> bool:
	return a == b


# Whether `viewing_team` can currently see `c`. Delegated, and fails open when
# there is no vision service at all - a unit built in a synthetic test has no fog
# to hide behind, and refusing to let its weapons fire would be a strange way to
# express that.
func is_visible_to_team(c: Node, viewing_team: int) -> bool:
	return vision == null or vision.is_visible_to_team(c, viewing_team)


# Reveal a patch of map for a while. Illumination ammo and sensor beacons.
func reveal_area(for_team: int, pos: Vector3, radius: float, duration: float) -> void:
	if vision != null:
		vision.reveal_area(for_team, pos, radius, duration)


# Whether this team's defences should be firing at reduced effect. Delegated so
# there is one definition of "low power" and the HUD, production and weapons all
# read the same one.
func is_low_power(for_team: int) -> bool:
	return economy != null and economy.is_low_power(for_team)


# Damageable things near `pos`, for weapon target acquisition.
#
# UNITS come from the neighbour grid the movement layer already rebuilds every
# tick - an adapter over it, not a second spatial index, because two grids over
# the same units is two chances to go stale in different directions.
#
# STRUCTURES are scanned directly, because they are deliberately NOT in that
# grid. The grid feeds separation steering, which is about units flowing around
# each other; putting buildings in it would have units treat their own base as a
# crowd to squeeze through. There are tens of structures, not hundreds, and they
# do not move, so a flat scan costs nothing worth indexing away.
#
# Leaving them out entirely is the trap here: weapons would silently be unable to
# shoot buildings, which reads as "the AI ignores my base" rather than as a
# missing branch, and it makes the HQ - the win condition - invulnerable.
func get_nearby_damageable(pos: Vector3, radius: float) -> Array:
	var out: Array = []
	var cells := int(ceil(radius / NEIGHBOUR_CELL))
	var centre := _grid_key(pos)
	for dz in range(-cells, cells + 1):
		for dx in range(-cells, cells + 1):
			var bucket: Array = _neighbour_grid.get(centre + Vector2i(dx, dz), [])
			for n in bucket:
				if is_instance_valid(n) and pos.distance_to(n.global_position) <= radius:
					out.append(n)
	for s in get_tree().get_nodes_in_group("structures"):
		if is_instance_valid(s) and not s.is_dead and pos.distance_to(s.global_position) <= radius:
			out.append(s)
	return out


# --- Per-tick bookkeeping ----------------------------------------------------

# SKIRMISH_PERF_TROUBLESHOOTING.md §6 item 4. The profiler's end_frame()
# fires from _physics_process, so a render frame without a physics tick
# has no measurement - its work is attributed to the next physics frame
# and lands in <untimed>. At 30 Hz physics / 60 Hz render that is half
# the frames.
#
# This _process is intentionally a NO-OP. It exists so the gap between
# physics ticks is captured under its own section, and so any future
# non-physics work the director picks up (deferred callbacks, a HUD
# pulse, an animation tick) is instrumented by the call site rather
# than silently landing in <untimed>. If the section is consistently
# near-zero, the gap is rendering and the answer to Track A "what is
# <untimed> doing" is the renderer (Track E territory). If it spikes,
# a deferred callable or signal is the cause and the next step is to
# find it.
func _process(delta: float) -> void:
	var _t := Profiler.start()
	Profiler.stop("render_frame", _t)
	# SKIRMISH_PERF_TROUBLESHOOTING.md §10.1. The single most important number
	# in the 2026-08-19T19-57-23 capture - 4.53 rendered fps against a 14.56 Hz
	# sim on a 30 Hz target - was not written in the log anywhere. It had to be
	# recovered by counting `render_frame` section entries and dividing by the
	# match duration. This counts rendered frames directly and emits one
	# `perf_sample` per second of REAL time, so the log states the frame rate
	# rather than implying it.
	#
	# _process is the right home for the counter: it runs once per rendered
	# frame, where _physics_process runs on the fixed tick and cannot see
	# dropped frames at all. Both rates are reported together because the gap
	# between them is the diagnosis - a sim at half its target with the screen
	# at a third of the sim means the engine is spending its time somewhere
	# neither loop is measuring.
	_render_frames += 1
	_perf_sample_accum += delta
	if _perf_sample_accum < 1.0:
		return
	if not BattleLogger.enabled:
		_perf_sample_accum = 0.0
		_render_frames = 0
		_physics_frames_at_sample = _physics_frames
		return
	var phys: int = _physics_frames - _physics_frames_at_sample
	BattleLogger.log_perf_sample({
		"render_fps": snappedf(float(_render_frames) / _perf_sample_accum, 0.01),
		"physics_hz": snappedf(float(phys) / _perf_sample_accum, 0.01),
		"physics_hz_target": Engine.physics_ticks_per_second,
		"draw_calls": int(Performance.get_monitor(
			Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME)),
		"render_objects": int(Performance.get_monitor(
			Performance.RENDER_TOTAL_OBJECTS_IN_FRAME)),
		"nodes": int(Performance.get_monitor(Performance.OBJECT_NODE_COUNT)),
		"units_alive": get_tree().get_nodes_in_group("units").size(),
		"structures_alive": get_tree().get_nodes_in_group("structures").size(),
	})
	_perf_sample_accum = 0.0
	_render_frames = 0
	_physics_frames_at_sample = _physics_frames


func _physics_process(delta: float) -> void:
	if game_over:
		return
	# Counted before any early-out below so the rate in `perf_sample` is the
	# rate the engine actually ran the tick at, not the rate a subsystem
	# happened to be enabled for. See §10.1.
	_physics_frames += 1
	var _t_audio := Profiler.start()
	_tick_audio(delta)
	Profiler.stop("audio", _t_audio)

	var t := Profiler.start()
	_rebuild_neighbour_grid()
	Profiler.stop("neighbour_grid", t)

	t = Profiler.start()
	_tick_lazy_navmesh(delta)
	Profiler.stop("navmesh", t)

	if stats:
		var _t_stats := Profiler.start()
		stats.tick(delta)
		Profiler.stop("stats", _t_stats)
	if economy:
		# Ages the income accumulators. Must run BEFORE production draws this tick's
		# cost, so the rate reflects what came in rather than what is left after
		# spending it - the distinction the whole measure exists to make.
		var _t_econ := Profiler.start()
		economy.tick_income(delta)
		Profiler.stop("economy", _t_econ)
	if production:
		t = Profiler.start()
		production.tick(delta)
		Profiler.stop("production", t)
	if commander:
		# 2026-08-19. The commander internally splits its tick into
		# read_state / decide / execute and each is profiled there
		# (commander.gd:tick). The single-bucket `commander` section
		# used to live here; it was retired because 446 ms in a single
		# bucket is a measurement, not an answer - which of the three
		# sub-steps owns the cost is what the 2026-08-19 plan asked for.
		# SKIRMISH_PERF_TROUBLESHOOTING.md §5 Track B, §6 item 1.
		commander.tick(delta)
	# Squads tick every frame while the commander re-decides every couple of
	# seconds: the macro choice is slow, but a squad deciding to retreat cannot
	# wait two seconds for the next decision window.
	t = Profiler.start()
	for sm in _squad_managers.values():
		sm.tick(delta)
	for squad in _squads.values():
		squad.tick(delta)
	Profiler.stop("squads", t)

	# LAST in the director's tick. Units and weapons own their own
	# _physics_process and the engine runs a parent before its children, so this
	# closes the frame on everything: whatever the sections above do not account
	# for shows up as the gap between their sum and the frame total.
	# SKIRMISH_PERF_TROUBLESHOOTING.md §14. Drain the deferred
	# debris-free accumulator. Runs once per frame at the end so
	# the frees queued by a placement this frame do not compound
	# the next frame's cost. FREE_BATCH_PER_FRAME caps the per-frame
	# cost; the queue is naturally drained in 1-N frames.
	_process_pending_debris_frees()
	Profiler.end_frame()
	# Mirror the per-frame profile into the structured log. Runs after
	# end_frame() so the snapshot BattleLogger reads is the one the
	# profiler just finished writing. log_section / log_hitch both check
	# enabled and the _file handle before doing any work.
	if BattleLogger.enabled:
		BattleLogger.begin_frame()
		for section_name in Profiler.last_sections:
			BattleLogger.log_section(section_name, Profiler.last_sections[section_name])
		if Profiler.last_frame_ms >= BattleLogger.HITCH_THRESHOLD_MS:
			BattleLogger.log_hitch(Profiler.last_frame_ms,
				Profiler.last_dominant, Profiler.last_dominant_ms)


# A coarse bucket grid, rebuilt from scratch each tick rather than maintained
# incrementally. Rebuilding is O(n) and needs no invalidation; maintaining is
# O(1) per move but has to be told about every spawn, death and teleport, and one
# missed notification leaves a phantom neighbour shoving at nothing forever.
func _rebuild_neighbour_grid() -> void:
	_neighbour_grid.clear()
	for u in get_tree().get_nodes_in_group("units"):
		if not is_instance_valid(u) or u.is_dead:
			continue
		var key := _grid_key(u.global_position)
		if not _neighbour_grid.has(key):
			_neighbour_grid[key] = []
		_neighbour_grid[key].append(u)


func _grid_key(pos: Vector3) -> Vector2i:
	return Vector2i(int(floor(pos.x / NEIGHBOUR_CELL)), int(floor(pos.z / NEIGHBOUR_CELL)))


# --- Contracts the unit runtime looks for (movement side) --------------------

# Positions of other units close enough to crowd `unit`. Positions rather than
# nodes: separation only needs the geometry, and handing out node references
# invites the movement layer to start reading state off its neighbours.
func neighbour_positions(unit: Node3D, radius: float) -> Array:
	var out: Array = []
	var centre := _grid_key(unit.global_position)
	var radius_sq := radius * radius
	for dy in range(-1, 2):
		for dx in range(-1, 2):
			var bucket = _neighbour_grid.get(Vector2i(centre.x + dx, centre.y + dy))
			if bucket == null:
				continue
			for other in bucket:
				if other == unit or not is_instance_valid(other):
					continue
				var other_pos: Vector3 = other.global_position
				var offset := other_pos - unit.global_position
				offset.y = 0.0
				if offset.length_squared() <= radius_sq:
					out.append(other_pos)
	return out


# The shared field direction for an order's group, or ZERO if that group is too
# small to have one.
func flow_direction_for(order: Order, at: Vector3) -> Vector3:
	if flow_fields == null or order.group_id == 0:
		return Vector3.ZERO
	# Trip length gates the field as much as group size does: over a short hop the
	# search covers the whole reachable map to save a dozen cheap corridor
	# searches, and the convergence it causes is paid for nothing.
	#
	# This is the length recorded when the order was issued, NOT the distance still
	# to run - see Order.trip_length for why the difference matters.
	var field: FlowField = flow_fields.field_for(
		order.group_destination, _group_size(order.group_id), order.trip_length)
	if field == null or not field.has_route(at):
		return Vector3.ZERO
	return field.direction_at(at)


func _group_size(group_id: int) -> int:
	# PERF (2026-08-24). This runs from flow_direction_for, which every unit
	# calls every physics tick from _steer_direction. Uncached it walked the
	# whole units group - allocating the group array each time - N_units x
	# 30 Hz times, and that scan was a visible slice of the 02:31 skirmish's
	# elevated steer_nav mean. One scan per frame, shared by all callers.
	var frame := Engine.get_physics_frames()
	if frame != _group_size_frame:
		_group_size_frame = frame
		_group_size_cache.clear()
	if _group_size_cache.has(group_id):
		return int(_group_size_cache[group_id])
	var n := 0
	for u in get_tree().get_nodes_in_group("units"):
		if is_instance_valid(u) and not u.is_dead and u.current_order != null \
				and u.current_order.group_id == group_id:
			n += 1
	_group_size_cache[group_id] = n
	return n

var _group_size_frame: int = -1
var _group_size_cache: Dictionary = {}


# --- Input ------------------------------------------------------------------

func _unhandled_input(event: InputEvent) -> void:
	if camera == null or selection == null:
		return
	if event is InputEventKey and event.pressed and not event.echo:
		_handle_key(event)
		return

	# PLACEMENT SWALLOWS THE MOUSE. While a ghost is up, a left click sites the
	# building and a right click puts it down - neither may fall through to
	# selection or to a move order, or siting a power plant would also send the
	# whole army marching to where the player clicked.
	if is_placing():
		if event is InputEventMouseMotion:
			update_placement(event.position)
			return
		if event is InputEventMouseButton and event.pressed:
			if event.button_index == MOUSE_BUTTON_LEFT:
				var hit := _raycast(event.position, LayersScript.GROUND_PICK_MASK, false)
				if not hit.is_empty():
					confirm_placement(hit.position)
			elif event.button_index == MOUSE_BUTTON_RIGHT:
				cancel_placement()
		return

	# PRE-GAME HQ PLACEMENT. Mirrors the build-queue placement block above:
	# left click commits via the dedicated hook (place_hq_for_human via
	# confirm_hq_placement), right click cancels out. Mouse motion tracks
	# the ghost via the same raycast, with the zone clamp and validity test
	# handled by update_hq_placement. A build-queue placement and a
	# pre-game placement are mutually exclusive - is_placing() and
	# is_placing_hq() are never both true - so the early return above
	# (when is_placing() is true) keeps the two flows from racing.
	if is_placing_hq():
		if event is InputEventMouseMotion:
			update_hq_placement(event.position)
			return
		if event is InputEventMouseButton and event.pressed:
			if event.button_index == MOUSE_BUTTON_LEFT:
				# No need to raycast here - update_hq_placement already
				# clamped to the zone and stored the result in
				# hq_ghost_pos. The click commits whatever the ghost
				# is currently on, not whatever the cursor is over.
				confirm_hq_placement()
			# Right click is intentionally a no-op for the pre-game
			# phase: the player can never "skip" the HQ - the match
			# needs a player HQ before it can start. The ghost just
			# stays where it is; a re-click at a different spot
			# drops the HQ at the new position. (Test Range bypasses
			# the entire pre-game flow, so it never sees this.)
		return

	if event is InputEventMouseMotion:
		_update_hover_cursor(event.position)
		if _dragging:
			_update_selection_rect(event.position)
			return
		# Right-button drag: mark so a stationary press+release does
		# not look like a move order. The chase camera owns the drag
		# itself - this is just a flag the match director reads on
		# release to decide whether to issue the move order.
		if _right_press_active and event.position.distance_to(_right_press_pos) > DRAG_CLICK_THRESHOLD:
			_right_dragged = true

	if not (event is InputEventMouseButton):
		return

	if event.button_index == MOUSE_BUTTON_LEFT:
		if event.pressed:
			_drag_origin = event.position
			_dragging = true
		elif _dragging:
			_dragging = false
			_hide_selection_rect()
			_resolve_left_release(event.position, event.shift_pressed)
	elif event.button_index == MOUSE_BUTTON_RIGHT:
		if event.pressed:
			# Record press position. The move order is issued on
			# release UNLESS the player dragged - in which case the
			# chase camera owns the input and the match director
			# stays out of the way.
			_right_press_pos = event.position
			_right_press_active = true
			_right_dragged = false
		else:
			# Release. Only fire the move order if the press was
			# stationary (no drag).
			if _right_press_active and not _right_dragged \
					and event.position.distance_to(_right_press_pos) <= DRAG_CLICK_THRESHOLD:
				if _attack_move_armed:
					_set_armed(false)
					_issue_at(event.position, true, event.shift_pressed)
				else:
					_issue_at(event.position, false, event.shift_pressed)
			_right_press_pos = Vector2.ZERO
			_right_press_active = false
			_right_dragged = false


func _handle_key(event: InputEventKey) -> void:
	for i in range(1, 10):
		if event.is_action_pressed("cmd_group_assign_%d" % i):
			selection.assign_group(i)
			return
		elif event.is_action_pressed("cmd_group_%d" % i):
			selection.recall_group(i)
			return

	if event.is_action_pressed("cmd_attack_move"):
		_set_armed(not _attack_move_armed)
	elif event.is_action_pressed("cmd_stop"):
		orders.stop(selection.selected)
		_flash("STOP")
	elif event.is_action_pressed("cmd_stance_aggressive"):
		orders.set_stance(selection.selected, StanceScript.Kind.AGGRESSIVE)
		_flash("STANCE: AGGRESSIVE")
	elif event.is_action_pressed("cmd_stance_return_fire"):
		orders.set_stance(selection.selected, StanceScript.Kind.RETURN_FIRE)
		_flash("STANCE: RETURN FIRE")
	elif event.is_action_pressed("cmd_hold"):
		orders.hold(selection.selected)
		_flash("STANCE: HOLD POSITION")
	elif event.is_action_pressed("cmd_jump_alert"):
		var latest = alerts.get_latest_alert()
		if latest != null and camera != null:
			camera.global_position.x = latest.world_pos.x
			camera.global_position.z = latest.world_pos.z
	elif event.is_action_pressed("cmd_toggle_range_overlay"):
		# Toggle the sensor/weapon discs on every currently-selected unit.
		# The new value is the inverse of the first selected unit's current
		# setting, so pressing F12 with no selection does nothing (no
		# unit to read state from) and pressing F12 with a mixed
		# selection forces everything to one consistent value.
		var sel: Array = selection.selected
		if not sel.is_empty():
			var first = sel[0]
			var new_value: bool = not (("show_range_overlay" in first) and first.show_range_overlay)
			for u in sel:
				if "set_range_overlay_visible" in u:
					u.set_range_overlay_visible(new_value)
			if hud != null and "command_card" in hud and hud.command_card != null:
				if hud.command_card.has_method("_refresh_range_lamp"):
					hud.command_card._refresh_range_lamp()
	elif event.is_action_pressed("sys_perf"):
		_toggle_perf_hud()
	elif event.is_action_pressed("sys_perf_dump"):
		_dump_perf_now()
	elif event.is_action_pressed("ui_cancel"):
		if admin_menu != null and admin_menu.is_open():
			admin_menu.toggle()
			return
		if is_placing():
			cancel_placement()
			return
		if not selection.selected.is_empty() or _attack_move_armed:
			_set_armed(false)
			selection.clear()
			return
		if admin_menu != null:
			admin_menu.toggle()


# F3, matching Skirmish. Built on demand rather than left always-on for the
# reason perf_hud.gd's own header gives: the offline harnesses cannot reproduce
# the slowdown at 6-8 engaged units, so the numbers have to be readable during a
# real match. The overlay is the instrument for the stutter report, not a fix
# for it.
func _toggle_perf_hud() -> void:
	if is_instance_valid(_perf_hud):
		_perf_hud.queue_free()
		_perf_hud = null
		return
	_perf_hud = PerfHUDScript.new()
	_perf_hud.name = "PerfHUD"
	add_child(_perf_hud)


# F4, while a match is live. Writes the current profiler state, the
# performance-monitor snapshot, and the per-frame distribution to a fresh
# file under user://logs/dump_*.log. Lets a player capture the moment a
# stutter lands without having to wait for the match to end - the
# end-of-match dump is the comprehensive version, this is the in-the-moment
# version. The path is printed to the console so the player can find it.
func _dump_perf_now() -> void:
	if not BattleLogger.enabled:
		print("[match_director] BattleLogger is disabled - nothing to dump")
		_show_perf_toast("Profiler log is disabled (set MatchRuleSet.log_profiling or KITBASH_LOG_PROFILING=1)")
		return
	var path := BattleLogger.dump_now("manual")
	if path.is_empty():
		print("[match_director] dump failed (no live match)")
		_show_perf_toast("Perf dump failed: no live match")
		return
	print("[match_director] perf dump written to %s"
		% ProjectSettings.globalize_path(path))
	# On-screen feedback. print() in a windowed build is invisible; the
	# whole point of F4 is to be told THAT the dump happened and WHERE
	# to find it. The basename is enough to identify the file without
	# spamming the user with a full path on every press.
	_show_perf_toast("Perf dump written: %s" % path.get_file())


# Lazily add the toast CanvasLayer on first use. Mirrors _toggle_perf_hud's
# pattern; kept on a single instance for the duration of the match so a
# burst of F4s during a hitch investigation reuses the same panel and the
# timer reset above.
func _show_perf_toast(text: String) -> void:
	if not is_instance_valid(_perf_toast):
		_perf_toast = PerfToastScript.new()
		_perf_toast.name = "PerfToast"
		add_child(_perf_toast)
	_perf_toast.show_message(text)


# Resolves the log_profiling flag and opens the BattleLogger file at the
# start of the world build (2026-08-16). Two paths to the same answer:
#   - the rule set's log_profiling field (default true as of 2026-08-18;
#     a playtester expects a log file, the opt-out is the env var)
#   - the KITBASH_LOG_PROFILING=0 / =false env var (kill switch for
#     shipping / harness control runs without changing the rule set)
# The result is also written to the static BattleLogger so subsequent
# _emit_progress calls can be filtered cheaply.
func _evaluate_logging_flags() -> void:
	# Default ON (rule set's log_profiling defaults to true as of 2026-08-18).
	# Opt-out paths, in priority order:
	#   1. _match_rule_set.log_profiling = false (set by test_range factory,
	#      harness control runs, anyone who wants silence for one match)
	#   2. env var KITBASH_LOG_PROFILING=0 or =false (shipping / ad-hoc)
	# Anything else (env var unset, "1", "true", "yes", whatever) leaves
	# profiling on. The old "opt-in" model asked the playtester to remember
	# to set the env var; the new "opt-out" model lets the playtester forget
	# the env var entirely and still get a log.
	var env_flag := OS.get_environment("KITBASH_LOG_PROFILING")
	var profiling_on: bool = env_flag != "0" and env_flag != "false"
	if _match_rule_set != null and not _match_rule_set.log_profiling:
		profiling_on = false
	Profiler.enabled = profiling_on
	BattleLogger.enabled = profiling_on
	if profiling_on:
		BattleLogger.begin_match(_rule_set_label(), {
			"map_id": map_id,
			"player_faction": player_faction,
			"enemy_faction": enemy_faction,
			"build_path": _match_build_path(),
			"via": "rule_set" if (_match_rule_set != null and _match_rule_set.log_profiling) else "env",
		})


# 2026-08-16. Called by deploy_gate.gd when its READY_TIMEOUT fires
# without world_is_ready flipping. Records the last progress value,
# a wall-clock measurement, and a one-shot performance snapshot so a
# post-mortem can see where the build was when it hung. The bar at
# the moment of timeout is the most useful piece of evidence because
# it names the phase the build was last seen in.
#
# Public on purpose: deploy_gate is a separate file, calls this through
# the director's duck-typed interface, and would otherwise need a
# type-name import. Keeping the call site simple is the difference
# between a future engineer wiring it and a future engineer not.
func _log_build_hang(waited_seconds: float) -> void:
	if not BattleLogger.enabled:
		return
	BattleLogger._write_event("build_hang", {
		"last_fraction": _last_progress_fraction,
		"last_label": _last_progress_label,
		"waited_seconds": waited_seconds,
		"units_in_world": get_tree().get_nodes_in_group("units").size() if is_inside_tree() else 0,
		"structures_in_world": get_tree().get_nodes_in_group("structures").size() if is_inside_tree() else 0,
		"build_path": _match_build_path(),
	})
	# Best-effort perf snapshot. A hung build still has these values
	# cached in Performance - they refresh at ~1Hz, but the most
	# recent sample is informative even if stale.
	BattleLogger._write_event("perf_snapshot", {
		"process_ms": Performance.get_monitor(Performance.TIME_PROCESS) * 1000.0,
		"physics_ms": Performance.get_monitor(Performance.TIME_PHYSICS_PROCESS) * 1000.0,
		"object_count": Performance.get_monitor(Performance.OBJECT_NODE_COUNT),
		"orphan_count": Performance.get_monitor(Performance.OBJECT_ORPHAN_NODE_COUNT),
		"draw_calls": Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME),
		"render_objects": Performance.get_monitor(Performance.RENDER_TOTAL_OBJECTS_IN_FRAME),
		"video_mem_mb": Performance.get_monitor(Performance.RENDER_VIDEO_MEM_USED) / (1024.0 * 1024.0),
	})
	# Flush immediately so a 30s-timeout-then-crash leaves a usable
	# log on disk. The flush_every_frames cadence in the logger is
	# 30 frames at 30 Hz; a 30s hang has only just hit the next
	# flush window by the time the timeout fires, so the file is
	# almost entirely unflushed.
	BattleLogger._file.flush() if BattleLogger._file != null else null


# The match-mode label used in the log filename. Driven by the rule set
# when available; falls back to "match" so a script that instantiates
# Battle.tscn without MatchConfig (the test harness does this) still gets
# a usable name. The label is short on purpose - the log file's full
# timestamp and the rule_set's own fields land in the MATCH_BEGIN record.
func _rule_set_label() -> String:
	if _match_rule_set == null:
		return "match"
	if _match_rule_set.camera_mode == MatchRuleSetScript.CameraMode.CHASE:
		return "test_range"
	# Operations has its own launcher; Skirmish is the default.
	var mc := get_node_or_null("/root/MatchConfig")
	if mc != null and "rule_set" in mc and mc.rule_set == _match_rule_set \
			and "preset" in mc:
		var preset_raw: Variant = mc.get("preset")
		if preset_raw != null:
			var preset: String = str(preset_raw)
			if preset != "":
				return preset
	return "skirmish"


# Where this match was launched from, for the log header. The same
# information lives in the rule set itself but the operations_draft /
# match_setup / test_range_launcher distinction is the one a stutter
# report cites first ("was it the operations build or the skirmish
# build?"), so it gets its own field in the header.
func _match_build_path() -> String:
	var tree := get_tree()
	if tree == null:
		return "headless"
	var info_raw: Variant = Engine.get_meta("kitbash_match_origin", "")
	if info_raw is String and info_raw != "":
		return info_raw
	return "scene"


# A left release is a drag if the mouse actually travelled, a click otherwise.
# One threshold, so a slightly shaky click never silently becomes an empty
# one-pixel drag that clears the selection.
func _resolve_left_release(at: Vector2, additive: bool) -> void:
	var rect := Rect2(_drag_origin, at - _drag_origin).abs()
	var picked: Array = []
	if rect.size.length() >= SelectionServiceScript.DRAG_THRESHOLD_PX:
		picked = selection.units_in_rect(rect)
	else:
		# A click on one of our own structures raises its production ring rather
		# than selecting anything. Checked BEFORE the unit pick, because a
		# manufactory with a tank parked against it should still be clickable as
		# a building - the structure is the larger, less mobile target and the
		# player can always click the tank a metre to one side.
		var structure := _structure_at(at)
		if structure != null and hud != null and hud.deck != null:
			# Clicking a manufactory FOCUSES ITS QUEUE in the production deck
			# rather than opening a radial menu over it. The radial was a second
			# way to reach the same five queues, with its own copy of the build
			# list and its own idea of what was gated; this routes the click to
			# the one interface, which is also where the queue itself is visible.
			var queue := hud.queue_for_structure(structure)
			if queue != "":
				selection.clear()
				hud.deck.set_active(queue)
				return
		var one := selection.unit_at_point(at)
		if one != null:
			picked = [one]

	if additive:
		selection.add_to_selection(picked)
	else:
		selection.set_selection(picked)


# Our own structures only. An enemy building is a target, not a menu.
# --- Cursor -------------------------------------------------------------------
#
# CursorManager is an autoload and has been since the old runtime; the rebuilt
# battle layer simply never called it, so Battle ran on the bare OS arrow while
# Skirmish had contextual cursors. This is that call.
#
# The cursor answers the same question the click will: what does pressing the
# button here actually DO. So it is resolved from the same raycasts and the same
# selection the order path uses, rather than from a parallel guess.
func _update_hover_cursor(screen_pos: Vector2) -> void:
	var cm = get_node_or_null("/root/CursorManager")
	if cm == null or camera == null:
		return

	# Placing a building overrides everything: the only thing a click does here is
	# site it, and whether the site is legal is the one fact worth showing.
	if is_placing():
		var hit := _raycast(screen_pos, LayersScript.GROUND_PICK_MASK, false)
		var ok := false
		if not hit.is_empty():
			var at: Vector3 = hit.position
			at.y = terrain_height_at(at)
			ok = placement_validity(at)["valid"]
		cm.set_cursor(cm.CursorType.BUILD if ok else cm.CursorType.INVALID)
		return

	# Our own structures raise a production ring on click, not an order.
	if _structure_at(screen_pos) != null:
		cm.set_cursor(cm.CursorType.POINTER)
		return

	if selection == null or selection.selected.is_empty():
		cm.set_cursor(cm.CursorType.DEFAULT)
		return

	if _attack_move_armed:
		cm.set_cursor(cm.CursorType.ATTACK)
		return

	# An ore patch, checked BEFORE the ground, exactly as _issue_at does - a
	# terrain-only ray always finds the dirt underneath and the patch would never
	# be hoverable.
	var node_hit := _raycast(screen_pos, LayersScript.RESOURCE_NODES, false)
	if not node_hit.is_empty() and node_hit.collider.is_in_group("resource_nodes"):
		var can_harvest := false
		for u in selection.selected:
			if is_instance_valid(u) and u.is_harvester:
				can_harvest = true
				break
		cm.set_cursor(cm.CursorType.HARVEST if can_harvest else cm.CursorType.MOVE)
		return

	# Anything hostile and visible under the cursor is an attack.
	var target = _hostile_at(screen_pos)
	if target != null:
		cm.set_cursor(cm.CursorType.ATTACK)
		return

	cm.set_cursor(cm.CursorType.MOVE if not _raycast(
		screen_pos, LayersScript.GROUND_PICK_MASK, false).is_empty()
		else cm.CursorType.INVALID)


# A visible enemy under the cursor, or null. Fog-gated, so the cursor never
# reveals something the player cannot see by turning red over it.
func _hostile_at(screen_pos: Vector2):
	var hit := _raycast(screen_pos, LayersScript.SELECTION_QUERY_MASK, true)
	if hit.is_empty():
		return null
	var thing = hit.collider.get_meta("structure") if hit.collider.has_meta("structure") \
		else hit.collider.get_meta("unit") if hit.collider.has_meta("unit") else null
	if thing == null or not is_instance_valid(thing) or thing.is_dead:
		return null
	if not ("team" in thing) or thing.team == PLAYER_TEAM:
		return null
	if vision != null and vision.has_method("is_visible_to_team") \
			and not vision.is_visible_to_team(thing, PLAYER_TEAM):
		return null
	return thing


func _structure_at(screen_pos: Vector2) -> Structure:
	var hit := _raycast(screen_pos, LayersScript.SELECTION_QUERY_MASK, true)
	if hit.is_empty() or not hit.collider.has_meta("structure"):
		return null
	var s = hit.collider.get_meta("structure")
	if not is_instance_valid(s) or s.is_dead or s.team != PLAYER_TEAM:
		return null
	return s


func _issue_at(screen_pos: Vector2, aggressive: bool, queued: bool) -> void:
	# In Test Range the click-based selection system is broken (the hull-cache
	# proxy shares stale team metadata with the template), so fall back to the
	# focused unit. The player unit is force-selected in _spawn_test_range_force
	# and held in focus_unit from there.
	var recipients: Array = selection.selected
	if recipients.is_empty() and focus_unit != null and is_instance_valid(focus_unit):
		recipients = [focus_unit]
	if recipients.is_empty():
		return
	# WHAT WAS CLICKED DECIDES WHAT THE ORDER IS. An ore patch means "go work
	# that", ground means "go there". Resource nodes are queried first because
	# they sit ON the ground - a terrain-only ray would always find the dirt
	# underneath and the patch would never be clickable.
	if not aggressive:
		var node_hit := _raycast(screen_pos, LayersScript.RESOURCE_NODES, false)
		if not node_hit.is_empty() and node_hit.collider.is_in_group("resource_nodes"):
			orders.harvest(recipients, node_hit.collider, queued)
			# Anything in the selection that cannot harvest still needs an order,
			# or right-clicking a patch with a mixed group leaves the tanks
			# standing there having visibly ignored the click.
			var combat: Array = []
			for u in recipients:
				if is_instance_valid(u) and not u.is_harvester:
					combat.append(u)
			if not combat.is_empty():
				orders.move(combat, node_hit.collider.global_position, queued)
			return
		# RAYCAST MISS FALLBACK (2026-08-10). Ambient resource nodes (the
		# scattered single-tree / single-ore decorative scatter) have NO
		# per-tree physics body - the broadphase cost of 1800+ StaticBody3D
		# entries in the scatter was crashing the per-frame budget. The
		# raycast against layer 16 (RESOURCE_NODES) only hits the 4
		# harvestable fields' 36 colliders now. To keep "right-click on a
		# tree" working for ambient scatter, find the nearest ambient
		# resource to the GROUND click point (the second raycast below).
		# This is the same "nearest to the click" semantics the player
		# got before, just resolved against the resource_nodes group
		# rather than a physics shape.
		var ground_hit := _raycast(screen_pos, LayersScript.GROUND_PICK_MASK, false)
		if not ground_hit.is_empty():
			var ambient_target: Node3D = _nearest_ambient_to(ground_hit.position)
			if ambient_target != null:
				orders.harvest(recipients, ambient_target, queued)
				return

		# FOCUS FIRE (2026-08-20). Right-clicking an enemy unit should be an
	# ATTACK on the unit specifically, not an ATTACK_MOVE to the ground
	# behind it. The previous code did a GROUND-only ray which hit the
	# dirt under the unit and turned the click into an advance order.
	# A UNITS | BUILDINGS ray hits the body of the unit, so the click
	# resolves to the unit, not the ground. The unit's body is on the
	# UNITS layer (set in unit_assembly.gd:116) and carries the `team`
	# meta (set in unit_assembly.gd:115); the team comparison decides
	# friendly vs enemy. Buildings on BUILDINGS carry `structure` meta.
	# Either way, orders.attack() is the existing ATTACK order - it
	# engages the target until it dies, then goes back to IDLE, which
	# is exactly the user spec for "attack this target first then go
	# back to default behavior". The main_weapon_range on the unit
	# (set in unit.gd:setup() from AssemblyScript.compute_main_weapon)
	# drives _engagement_distance() so the unit closes to the main
	# gun's range, not the longest weapon's reach.
	var target_hit := _raycast(screen_pos, LayersScript.UNITS | LayersScript.BUILDINGS, false)
	if not target_hit.is_empty():
		var collider = target_hit.collider
		# Enemy UNIT: the collider is the CharacterBody3D itself.
		if collider.has_meta("team"):
			var enemy_unit: Node = collider
			if is_instance_valid(enemy_unit) and enemy_unit.team != PLAYER_TEAM:
				orders.attack(recipients, enemy_unit, queued)
				return
		# Enemy BUILDING: the `structure` meta on the collider points
		# to the Structure script.
		if collider.has_meta("structure"):
			var s = collider.get_meta("structure")
			if is_instance_valid(s) and s.team != PLAYER_TEAM:
				orders.attack(recipients, s, queued)
				return
		# Friendly or unrecognised hit - fall through to the ground ray
		# so the click behaves like a normal move/attack-move.

	var hit := _raycast(screen_pos, LayersScript.GROUND_PICK_MASK, false)
	if hit.is_empty():
		return
	if aggressive:
		orders.attack_move(recipients, hit.position, queued)
	else:
		orders.move(recipients, hit.position, queued)


# Nearest ambient resource node to `pos` (XZ distance). Bounded search by the
# AMBIENT_NODE_PICK_RADIUS so a right-click on empty ground doesn't auto-find
# a tree 200m away - the player clicked on THIS patch, treat the click as
# local. Returns null if nothing within radius. The harvester's auto-find
# (unit.gd's _auto_find_harvest_work) does the same kind of search
# but on every tick, and that one DOES search the whole map because the
# harvester is idle and looking for any work - this is a click-driven pick
# and the locality is the player-facing contract.
const AMBIENT_NODE_PICK_RADIUS: float = 8.0
func _nearest_ambient_to(pos: Vector3) -> Node3D:
	var best: Node3D = null
	var best_d_sq: float = AMBIENT_NODE_PICK_RADIUS * AMBIENT_NODE_PICK_RADIUS
	for n in get_tree().get_nodes_in_group("resource_nodes"):
		if not is_instance_valid(n):
			continue
		if not ("is_ambient" in n) or not n.is_ambient:
			continue
		if n.amount <= 0:
			continue
		var d_sq: float = pos.distance_squared_to(n.global_position)
		if d_sq < best_d_sq:
			best = n
			best_d_sq = d_sq
	return best


# Puts `centre` under the middle of the screen without touching zoom or pitch.
#
# Reuses rts_camera's own ray_plane_hit() rather than reinventing the geometry:
# the camera looks down at an angle that varies with zoom (_apply_pitch lerps
# -42 to -62 degrees), so "subtract the height from Z" is only right at one
# zoom level. Asking where the screen centre currently lands and shifting by the
# difference is correct at every zoom, and it is the same function zoom-to-cursor
# already trusts.
func _on_group_recentre(centre: Vector3) -> void:
	if camera == null or not camera.has_method("ray_plane_hit"):
		return
	var screen_centre := get_viewport().get_visible_rect().size * 0.5
	var looking_at = camera.ray_plane_hit(screen_centre, centre.y)
	if looking_at == null:
		return
	camera.global_position.x += centre.x - looking_at.x
	camera.global_position.z += centre.z - looking_at.z


# --- HUD ---------------------------------------------------------------------
#
# ONE HUD. scripts/hud/hud_root.gd owns every region: tactical map, resource
# ribbon, the five-tab production deck, the command card and the alert log. What
# used to be here built TWO complete HUDs (BattleHUD -> CommandConsole, and a
# separate ProductionHUD) which each drew their own production interface, plus
# three minimap instances between them. See hud_root.gd for the inventory.

# Built in headless too, deliberately. The obvious guard - skip the HUD when
# there is no display - makes the entire production interface untestable.
# Control nodes do not need a window; only rendering does.
func _build_hud() -> void:
	var layer := CanvasLayer.new()
	layer.name = "UI"
	add_child(layer)

	# The per-mode rule set stays the single source of truth for which chrome
	# exists. enable_battle_hud now gates the whole HUD (there is only one), and
	# enable_production_hud / enable_minimap gate regions inside it - which is
	# what the old comment here said was "deferred until Phase 3" because the
	# minimap was welded inside BattleHUD and could not be turned off cleanly.
	# It can now: the regions are siblings.
	var enable_hud: bool = _match_rule_set.enable_battle_hud if _match_rule_set != null else true
	var enable_production: bool = _match_rule_set.enable_production_hud if _match_rule_set != null else true
	var enable_minimap: bool = _match_rule_set.enable_minimap if _match_rule_set != null else true
	var is_debug := OS.has_feature("editor") or OS.is_debug_build() or "--cheats" in OS.get_cmdline_args()
	var enable_admin_menu: bool = (_match_rule_set.enable_admin_menu if _match_rule_set != null else true) and is_debug

	# The drag-select rectangle. Lives on the layer rather than inside the HUD
	# because it is a cursor artefact, not chrome - it has to be able to draw
	# over every panel.
	_selection_rect = Panel.new()
	_selection_rect.visible = false
	_selection_rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var box := StyleBoxFlat.new()
	box.bg_color = Color(HUDStyle.TEAM_FRIENDLY.r, HUDStyle.TEAM_FRIENDLY.g,
		HUDStyle.TEAM_FRIENDLY.b, 0.12)
	box.border_color = HUDStyle.TEAM_FRIENDLY
	box.set_border_width_all(1)
	_selection_rect.add_theme_stylebox_override("panel", box)
	layer.add_child(_selection_rect)

	if enable_hud:
		hud = HUDRootScript.new()
		layer.add_child(hud)
		hud.setup(self, PLAYER_TEAM, current_map)
		# battle_hud is the historical name several callers and tests reach for.
		battle_hud = hud
		# _flash() writes into the HUD's own hint banner rather than a loose Label
		# positioned by hand against the top-left corner - which is where it used
		# to sit, stacked under two other independently-positioned texts.
		_hud_hint = hud.hint_label
		hud.deck.visible = enable_production
		hud.minimap.visible = enable_minimap

	if enable_admin_menu:
		admin_menu = AdminMenuScript.new()
		admin_menu.name = "AdminMenu"
		# Into the HUD's column when there is a HUD, so it shares the centred,
		# ultrawide-capped layout and lands in the strip the alert log leaves for
		# it. Onto the bare layer otherwise (Test Range, or a rule set with the
		# HUD off), where it falls back to anchoring against the viewport.
		if hud != null:
			hud.attach_to_column(admin_menu)
		else:
			layer.add_child(admin_menu)
		admin_menu.main_menu_requested.connect(func():
			var router = get_node_or_null("/root/SceneRouter")
			if router != null:
				router.goto("res://scenes/MainMenu.tscn")
			else:
				get_tree().change_scene_to_file("res://scenes/MainMenu.tscn"))
		admin_menu.quit_requested.connect(func(): get_tree().quit())

	# Dev-only: the F2 Debug overlay (infinite resources / instant build /
	# reveal all fog). Same is_debug gate the admin menu uses so a release
	# build never ships with the cheats on screen. The toggles write to
	# the DebugSettings autoload; gameplay services read it defensively
	# (economy_service.gd:70, production_service.gd:114, vision_service.gd:258).
	if is_debug:
		debug_overlay = DebugOverlayScript.new()
		debug_overlay.name = "DebugOverlay"
		if hud != null:
			hud.attach_to_column(debug_overlay)
		else:
			layer.add_child(debug_overlay)


func _update_selection_rect(at: Vector2) -> void:
	if _selection_rect == null:
		return
	var rect := Rect2(_drag_origin, at - _drag_origin).abs()
	_selection_rect.visible = rect.size.length() >= SelectionServiceScript.DRAG_THRESHOLD_PX
	_selection_rect.position = rect.position
	_selection_rect.size = rect.size


func _hide_selection_rect() -> void:
	if _selection_rect:
		_selection_rect.visible = false


func _set_armed(value: bool) -> void:
	_attack_move_armed = value
	_flash("ATTACK-MOVE: RIGHT-CLICK A DESTINATION" if value else "")
	# X7 (Tactile Interface Programme Part 2.4): the hint label was the only
	# feedback that attack-move was armed, and the player is looking at the
	# battlefield, not at the hint. CursorManager is an autoload and has been
	# since the old runtime; arming sets the cursor to ATTACK immediately so
	# the cue lands without waiting for the next mouse motion. On disarm the
	# cursor is re-resolved from the current hover position, which is what
	# the next click will actually do. The flash text stays as the
	# accessible-channel fallback under the captions setting.
	var cm = get_node_or_null("/root/CursorManager")
	if cm == null:
		return
	if value:
		cm.set_cursor(cm.CursorType.ATTACK)
	else:
		var vp := get_viewport()
		if vp != null:
			_update_hover_cursor(vp.get_mouse_position())


func _flash(text: String) -> void:
	if _hud_hint:
		_hud_hint.text = text


func _raycast(screen_pos: Vector2, mask: int, areas: bool) -> Dictionary:
	# Project the click from whichever camera is currently rendering the
	# scene. The `camera` field still names the RTS Camera3D, but the
	# chase camera takes over in Test Range - a click projected from the
	# RTS camera in that mode would land on a coordinate the player
	# cannot see and a move order would send the unit to a spot off
	# screen. get_viewport().get_camera_3d() returns the active one.
	var ray_cam := get_viewport().get_camera_3d() if camera != null else null
	if ray_cam == null:
		ray_cam = camera
	if ray_cam == null:
		return {}
	var from := ray_cam.project_ray_origin(screen_pos)
	var to := from + ray_cam.project_ray_normal(screen_pos) * PICK_RAY_LENGTH
	var query := PhysicsRayQueryParameters3D.create(from, to)
	query.collision_mask = mask
	query.collide_with_areas = areas
	query.collide_with_bodies = not areas
	return get_world_3d().direct_space_state.intersect_ray(query)
