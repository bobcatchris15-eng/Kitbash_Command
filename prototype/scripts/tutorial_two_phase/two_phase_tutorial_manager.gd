extends Node
# Autoload. Drives the two-phase guided loop:
#   Phase 1 - Skirmish with poor units (player loses)
#   Phase 2 - Design Lab to build a better unit
#
# WHY AN AUTOLOAD: the tutorial spans two scenes and a round trip
# (Battle -> MainLab). Every node in the scene it started in is
# freed on the way, so the step counter has to live somewhere that
# outlives a scene change. Same reasoning as OperationsManager.
#
# WHY CONDITIONS ARE POLLED: the battle and lab scripts emit no
# tutorial signals. Rather than thread a signal bus through scripts
# that ten suites already drive, each step names a condition id and
# this file reads live state once a frame. Cheap (a step is a handful
# of property reads), and it means the tutorial observes the game
# rather than the game having to announce itself to the tutorial.

const TwoPhaseTutorialSteps = preload("res://scripts/tutorial_two_phase/two_phase_tutorial_steps.gd")
const TwoPhaseTutorialOverlay = preload("res://scripts/tutorial_two_phase/two_phase_tutorial_overlay.gd")
const ModuleCatalog = preload("res://scripts/module_catalog.gd")
const BlueprintManagerScript = preload("res://scripts/blueprint_manager.gd")
const Tokens = preload("res://scripts/ui_tokens.gd")
const UIFeedbackScript = preload("res://scripts/ui_feedback.gd")
const MatchRuleSetScript = preload("res://scripts/match_rule_set.gd")
const MatchConfigScript = preload("res://scripts/match_config.gd")
const TestRangeLauncherScript = preload("res://scripts/test_range_launcher.gd")

## Emitted when the run ends. `completed` is false when the player skipped.
signal finished(completed: bool)

const SEEN_PATH := "user://two_phase_tutorial_seen.cfg"

# Above the battle HUD layer and lab UI layer, but BELOW SceneRouter's fade at 128
const OVERLAY_LAYER := 110

var active: bool = false
var current_phase: int = 1  # 1 = skirmish, 2 = design lab

var _step: int = 0
var _layer: CanvasLayer = null
var _overlay: Control = null
var _last_scene: Node = null
var _button_pressed: bool = false
# Per-step "what it looked like when this step began", for the conditions that
# are differences rather than absolutes.
var _baseline: Dictionary = {}

# Weak player roster for Phase 1 (guaranteed to lose)
const WEAK_PLAYER_ROSTER := [
	"res://data/loadout/tutorial_weak_scout.json",
	"res://data/loadout/tutorial_weak_hauler.json",
	"res://data/loadout/tutorial_weak_defender.json",
]

# Strong enemy roster for Phase 1 (will crush the weak player units)
const STRONG_ENEMY_ROSTER := [
	"res://data/loadout/tutorial_enemy_striker.json",
	"res://data/loadout/tutorial_enemy_artillery.json",
]

# The map to use for the tutorial skirmish (needs base_zones for HQ placement)
const TUTORIAL_MAP_ID := "delta_blues"  # Has base zones for HQ placement

func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	set_process(false)

# --- Lifecycle --------------------------------------------------------------

func begin() -> void:
	if active:
		return
	active = true
	current_phase = 1
	_step = 0
	_last_scene = null
	mark_seen()
	set_process(true)
	_launch_phase_1_skirmish()

func skip() -> void:
	_end(false)

func has_been_seen() -> bool:
	return FileAccess.file_exists(SEEN_PATH)

func mark_seen() -> void:
	var f := FileAccess.open(SEEN_PATH, FileAccess.WRITE)
	if f:
		f.store_line("seen=true")
		f.close()

# Called by the overlay's NEXT / FINISH button. A flag rather than a direct
# advance so that every step, button-driven or state-driven, is resolved through
# the same _condition_met() path on the same frame boundary.
func notify_button() -> void:
	_button_pressed = true

func _end(completed: bool) -> void:
	active = false
	set_process(false)
	_teardown_overlay()
	_step = 0
	_baseline.clear()
	current_phase = 1
	finished.emit(completed)

func _teardown_overlay() -> void:
	if is_instance_valid(_layer):
		_layer.queue_free()
	_layer = null
	_overlay = null

# --- Phase 1: Launch Skirmish with weak units -------------------------------

func _launch_phase_1_skirmish() -> void:
	# Create a MatchConfig with our weak vs strong rosters
	var mc: Node = _ensure_match_config()
	mc.selected_map_id = TUTORIAL_MAP_ID
	
	# Create a skirmish rule set with our tutorial rosters
	var rs = MatchRuleSetScript.skirmish(
		TUTORIAL_MAP_ID,
		"industrialists",  # player faction
		"technocrats",     # enemy faction
		WEAK_PLAYER_ROSTER,
		"normal"
	)
	# Override starting credits to be low (but enough for the weak roster)
	rs.starting_credits = 400  # Low resources - "Low (tight economy)" preset
	# Disable AI so we control when the enemy attacks? No, keep AI enabled for real battle feel
	# But make enemy roster strong
	rs.enemy_faction = "technocrats"
	
	# We need to inject the enemy roster. The rule set uses selected_blueprint_paths for player.
	# For enemy, we need to set it up differently. Let's check how enemy roster works...
	# Actually, match_director.gd loads enemy_roster from _bundled_loadout_paths() by default.
	# We need a way to override this. Let's use a custom approach:
	# Store the enemy roster paths in a global that match_director can read.
	
	# For now, let's use the test range launcher approach but with skirmish rule set
	# and custom rosters. We'll need to modify how the match director gets enemy roster.
	
	# Simpler approach: Use a custom rule set factory for tutorial
	rs = _create_tutorial_rule_set()
	mc.rule_set = rs
	
	# Route through SceneRouter
	var router := get_node_or_null("/root/SceneRouter")
	if router != null:
		router.goto("res://scenes/Battle.tscn", "TWO_PHASE_TUTORIAL_PHASE1")
	else:
		get_tree().change_scene_to_file("res://scenes/Battle.tscn")

func _create_tutorial_rule_set() -> MatchRuleSet:
	var rs = MatchRuleSetScript.skirmish(
		TUTORIAL_MAP_ID,
		"industrialists",
		"technocrats",
		WEAK_PLAYER_ROSTER,
		"normal"
	)
	rs.starting_credits = 400
	# Mark this as tutorial so match_director can read our custom enemy roster
	rs.set_meta("tutorial_phase", 1)
	rs.set_meta("tutorial_enemy_roster", STRONG_ENEMY_ROSTER)
	return rs

# --- Phase 2: Launch Design Lab ---------------------------------------------

func _launch_phase_2_design_lab() -> void:
	current_phase = 2
	_step = 0  # Reset step counter for phase 2
	_baseline.clear()
	_button_pressed = false
	
	# Route to MainLab
	var router := get_node_or_null("/root/SceneRouter")
	if router != null:
		router.goto("res://scenes/MainLab.tscn", "TWO_PHASE_TUTORIAL_PHASE2")
	else:
		get_tree().change_scene_to_file("res://scenes/MainLab.tscn")

# --- Per-frame driving ------------------------------------------------------

func _process(_delta: float) -> void:
	if not active:
		return

	# current_scene goes null for a frame during a change
	var scene := get_tree().current_scene
	if scene != _last_scene:
		_last_scene = scene
		_teardown_overlay()
		if is_instance_valid(scene):
			_spawn_overlay_if_relevant()

	if _condition_met():
		_advance()

func _advance() -> void:
	_step += 1
	var steps = TwoPhaseTutorialSteps.get_steps_for_phase(current_phase)
	if _step >= steps.size():
		if current_phase == 1:
			# Phase 1 complete, launch Phase 2
			_launch_phase_2_design_lab()
			return
		else:
			# Phase 2 complete, tutorial done
			_end(true)
			return
	_enter_step()

func _enter_step() -> void:
	_button_pressed = false
	_baseline.clear()

	# Capture baseline state for difference-based conditions
	var placer := _lab()
	if placer and is_instance_valid(placer.hull):
		_baseline["hull_id"] = placer.hull.get_instance_id()
	
	var director := _battle_director()
	if director:
		_baseline["player_units"] = _count_player_units(director)
		_baseline["enemy_units"] = _count_enemy_units(director)
		_baseline["placing_hq"] = bool(director.is_placing_hq()) if director.has_method("is_placing_hq") else false

	_spawn_overlay_if_relevant()
	if is_instance_valid(_overlay):
		var step_data = TwoPhaseTutorialSteps.get_step(current_phase, _step)
		_overlay.show_step(current_phase, _step, step_data)

# The overlay only exists while the player is actually on the step's own screen.
# Conditions keep being evaluated regardless - phase transition steps complete
# when the scene changes.
func _spawn_overlay_if_relevant() -> void:
	var scene := get_tree().current_scene
	if not is_instance_valid(scene):
		return
	var step_data = TwoPhaseTutorialSteps.get_step(current_phase, _step)
	if scene.scene_file_path != str(step_data.get("scene", "")):
		_teardown_overlay()
		return
	if is_instance_valid(_overlay):
		return

	_layer = CanvasLayer.new()
	_layer.name = "TwoPhaseTutorialLayer"
	_layer.layer = OVERLAY_LAYER
	_layer.process_mode = Node.PROCESS_MODE_ALWAYS
	scene.add_child(_layer)

	_overlay = TwoPhaseTutorialOverlay.new()
	_overlay.name = "TwoPhaseTutorialOverlay"
	_overlay.manager = self
	_layer.add_child(_overlay)
	var step = TwoPhaseTutorialSteps.get_step(current_phase, _step)
	_overlay.show_step(current_phase, _step, step)

# --- Conditions -------------------------------------------------------------

func _condition_met() -> bool:
	var step_data = TwoPhaseTutorialSteps.get_step(current_phase, _step)
	if step_data.is_empty():
		return false

	match str(step_data.get("advance", "")):
		"next_button", "finish_button":
			return _button_pressed
		"scene_is_battle":
			return _battle_director() != null
		"battle_started":
			var d := _battle_director()
			return d != null and d.world_is_ready
		"hq_placed":
			var d := _battle_director()
			if d == null or not d.has_method("is_placing_hq"):
				return false
			# Check if player was placing HQ and now has placed it (placing_hq went from true to false)
			var was_placing := bool(_baseline.get("placing_hq", false))
			var is_placing := bool(d.is_placing_hq())
			return was_placing and not is_placing
		"player_unit_lost":
			var d := _battle_director()
			if d == null:
				return false
			var current_player = _count_player_units(d)
			return current_player < int(_baseline.get("player_units", 0))
		"player_defeated":
			var d := _battle_director()
			if d == null:
				return false
			# Check if match ended with player loss
			return d.game_over and not _player_won(d)
		"scene_is_lab":
			return _lab() != null
		"hull_replaced":
			var placer := _lab()
			if placer == null or not is_instance_valid(placer.hull):
				return false
			return placer.hull.get_instance_id() != _baseline.get("hull_id", 0)
		"locomotion_placed":
			return _has_module_of_category(["locomotion"])
		"weapon_placed":
			return _has_module_of_category(["weapon"])
		"module_selected":
			var p := _lab()
			return p != null and is_instance_valid(p.selected_module)
		"design_named":
			var edit = _stat_member("blueprint_name_edit")
			if edit == null:
				return false
			return BlueprintManagerScript.is_named(edit.text)
		"blueprint_saved":
			var pl := _lab()
			if pl == null or not is_instance_valid(pl.hull):
				return false
			return str(pl.hull.get_meta("blueprint_id", "")) != ""
		"test_in_arena":
			var pl := _lab()
			if pl == null or not is_instance_valid(pl.hull):
				return false
			# Check if test button was pressed (scene will change)
			return _button_pressed  # This step uses button advance
		"arena_dummy_destroyed":
			var a := _arena()
			if a == null:
				return false
			return _live_dummies(a) < int(_baseline.get("dummies", 3))
		"return_to_lab":
			return _lab() != null
	return false

func _player_won(director) -> bool:
	# Check if player won - we'd need access to the match_ended signal data
	# For now, assume if game_over and player has units, they won
	return _count_player_units(director) > 0

func _has_module_of_category(categories: Array) -> bool:
	var placer := _lab()
	if placer == null or not is_instance_valid(placer.hull):
		return false
	for child in placer.hull.get_children():
		if not child.has_meta("module_data"):
			continue
		var type_id := str(child.get_meta("module_data").type_id)
		var data: Dictionary = ModuleCatalog.get_module_data(type_id)
		if str(data.get("category", "")) in categories:
			return true
	return false

# --- Scene accessors --------------------------------------------------------

func _battle_director() -> Node:
	var scene := get_tree().current_scene
	if is_instance_valid(scene) and scene.has_method("get_ground_nav_map"):
		return scene
	return null

func _lab() -> Node:
	var scene := get_tree().current_scene
	if is_instance_valid(scene) and scene.has_method("_place_hull_from_ui"):
		return scene
	return null

func _arena() -> Node:
	var scene := get_tree().current_scene
	if is_instance_valid(scene) and "target_dummies" in scene:
		return scene
	return null

func _count_player_units(director: Node) -> int:
	# Count units on player team (team 0)
	var count = 0
	if director.has_method("get_children"):
		for child in director.get_children():
			if child is Node3D and child.get_meta("team", -1) == 0:
				count += 1
	return count

func _count_enemy_units(director: Node) -> int:
	var count = 0
	if director.has_method("get_children"):
		for child in director.get_children():
			if child is Node3D and child.get_meta("team", -1) == 1:
				count += 1
	return count

func _live_dummies(arena: Node) -> int:
	var n := 0
	for dummy in arena.target_dummies:
		if is_instance_valid(dummy):
			n += 1
	return n

func _stat_member(member: String):
	var ui := get_tree().get_first_node_in_group("stat_ui")
	if ui == null:
		return null
	return ui.get(member)

# --- MatchConfig helper -----------------------------------------------------

func _ensure_match_config() -> Node:
	var existing := get_tree().root.get_node_or_null("MatchConfig")
	if existing != null:
		return existing
	var mc = Node.new()
	mc.name = "MatchConfig"
	mc.set_script(MatchConfigScript)
	get_tree().root.add_child(mc)
	return mc
