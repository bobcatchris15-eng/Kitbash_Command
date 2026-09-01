extends Control
# The between-engagements draft screen.
#
# An operation is only more than a playlist of matches if the roster can change
# between them, and it is only a DECISION if you can see what you are drafting
# against. So this is the same 12-slot RosterPicker as both setup screens, plus
# the one thing they cannot show: what the opponent actually fielded, and how
# your own designs did against it.
#
# Reached from the after-action report's "Next Engagement", after
# OperationsManager.advance_to_next_stage() has already moved the pointer - so
# get_current_stage_info() here is the engagement about to be fought.

const BlueprintManagerScript = preload("res://scripts/blueprint_manager.gd")
const UITheme = preload("res://scripts/ui_theme.gd")
const MapCatalog = preload("res://scripts/map_catalog.gd")
const UIShell = preload("res://scripts/ui_shell.gd")
const Tokens = preload("res://scripts/ui_tokens.gd")
const UIFeedbackScript = preload("res://scripts/ui_feedback.gd")
const UIAnimScript = preload("res://scripts/ui_anim.gd")
# write_match_config() reads LiveryScript.PLAYER_ID for the player faction id.
# This preload was missing since the Phase 1-5 unification (0a8226a), so the
# whole script failed to compile with `Identifier "LiveryScript" not declared`
# and the Operations draft screen could not load at all - the same defect
# DECISIONS.md logged against battle/buildings/structure.gd, which got its
# preload while this twin did not. Declared identically to structure.gd:19.
const LiveryScript = preload("res://scripts/livery.gd")
const RosterPickerScript = preload("res://scripts/roster_picker.gd")
const CounterDraftScript = preload("res://scripts/battle/ai/counter_draft.gd")
const MatchRuleSetScript = preload("res://scripts/match_rule_set.gd")
const StampedButtonScript = preload("res://scripts/ui_stamped_button.gd")

const ROSTER_CAP := 12

# How many rows of the last engagement's per-design table to show. The report
# already gave the full breakdown; this is a reminder, not a second report.
const DEBRIEF_ROWS := 6

var bp_manager: Node
var roster_picker: RosterPicker
var _ops: Node = null


func _ready() -> void:
	bp_manager = BlueprintManagerScript.new()
	add_child(bp_manager)
	_ops = get_node_or_null("/root/OperationsManager")

	# Out-of-match screen - sits on the workbench, not on the in-match steel.
	# Operations draft is the between-engagement screen, the paper the
	# campaign is planned on. Cork fits better than the kraft paper of
	# operations_setup (which is the pre-campaign planning) - cork is
	# what a board you stick notes to is made of.
	UIShell.workbench(self, "cork")
	var frame := UIShell.screen_frame(self)

	var vbox = VBoxContainer.new()
	vbox.add_theme_constant_override("separation", Tokens.SPACE_MD)
	frame.add_child(vbox)

	var stage: Dictionary = _ops.get_current_stage_info() if _ops else {}
	var index: int = (_ops.current_stage + 1) if _ops else 1
	var total: int = _ops.total_stages if _ops else 1

	var title = Label.new()
	title.text = "ENGAGEMENT %d OF %d" % [index, total]
	title.theme_type_variation = "DisplayLabel"
	vbox.add_child(title)

	var map_id: String = str(stage.get("map_id", MapCatalog.DEFAULT_MAP_ID))
	var subtitle = Label.new()
	subtitle.text = "%s - %s. Opposition on %s difficulty." % [
		MapCatalog.get_map_name(map_id),
		str(MapCatalog.get_map(map_id).get("description", "Standard battlefield.")),
		str(stage.get("ai_difficulty", "normal"))]
	subtitle.theme_type_variation = "HintLabel"
	subtitle.autowrap_mode = TextServer.AUTOWRAP_WORD
	vbox.add_child(subtitle)

	var content = HBoxContainer.new()
	content.size_flags_vertical = Control.SIZE_EXPAND_FILL
	content.add_theme_constant_override("separation", Tokens.SPACE_XL)
	vbox.add_child(content)

	_build_debrief(content)
	_build_roster(content)

	vbox.add_child(HSeparator.new())
	_build_action_bar(vbox)


# --- Left: what just happened -------------------------------------------------

func _build_debrief(parent: Control) -> void:
	var col = VBoxContainer.new()
	col.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	col.size_flags_stretch_ratio = 0.9
	col.add_theme_constant_override("separation", Tokens.SPACE_SM)
	parent.add_child(col)

	var heading = Label.new()
	heading.text = "LAST ENGAGEMENT"
	heading.theme_type_variation = "HeadingLabel"
	col.add_child(heading)

	var history: Array = _ops.fielded_history() if _ops else []
	if history.is_empty():
		var none = Label.new()
		none.text = "No engagements fought yet."
		none.theme_type_variation = "HintLabel"
		col.add_child(none)
		return

	var last: Dictionary = history[history.size() - 1]
	var outcome = Label.new()
	outcome.text = "%s on %s" % [
		"VICTORY" if last.get("victory", false) else "DEFEAT",
		MapCatalog.get_map_name(str(last.get("map_id", "")))]
	outcome.add_theme_color_override("font_color",
		Tokens.SIGNAL_GO if last.get("victory", false) else Tokens.SIGNAL_ALERT)
	col.add_child(outcome)

	col.add_child(HSeparator.new())

	# THE POINT OF THIS SCREEN. Re-drafting without knowing what you are drafting
	# against is a chore; with it, it is the decision the operation is built on.
	var opp_heading = Label.new()
	opp_heading.text = "THEY FIELDED"
	opp_heading.theme_type_variation = "HeadingLabel"
	col.add_child(opp_heading)

	var enemy_designs: Array = last.get("enemy_designs", [])
	var enemy_label = Label.new()
	enemy_label.text = ", ".join(PackedStringArray(enemy_designs)) if not enemy_designs.is_empty() else "Unrecorded."
	enemy_label.theme_type_variation = "HintLabel"
	enemy_label.autowrap_mode = TextServer.AUTOWRAP_WORD
	col.add_child(enemy_label)

	# WHAT THEY WILL BRING NEXT. The AI counter-drafts off this same history, and
	# an opponent that adapts invisibly reads as an inconsistent one rather than
	# a responsive one - the player has to be able to see the adaptation to draft
	# against it. Stated in the AI's own words, from the same function that does
	# the reordering, so the two cannot describe different plans.
	var intent_heading = Label.new()
	intent_heading.text = "THEY HAVE NOTICED"
	intent_heading.theme_type_variation = "HeadingLabel"
	col.add_child(intent_heading)

	var intent = Label.new()
	intent.text = CounterDraftScript.explain(history)
	intent.theme_type_variation = "HintLabel"
	intent.autowrap_mode = TextServer.AUTOWRAP_WORD
	intent.add_theme_color_override("font_color", Tokens.SIGNAL_HAZARD)
	col.add_child(intent)

	col.add_child(HSeparator.new())

	var yours_heading = Label.new()
	yours_heading.text = "YOUR DESIGNS"
	yours_heading.theme_type_variation = "HeadingLabel"
	col.add_child(yours_heading)

	var rows: Dictionary = {}
	if _ops and not _ops.stage_results_history.is_empty():
		rows = _ops.stage_results_history[_ops.stage_results_history.size() - 1].get("designs", {})
	if rows.is_empty():
		var no_rows = Label.new()
		no_rows.text = "No per-design record for that engagement."
		no_rows.theme_type_variation = "HintLabel"
		col.add_child(no_rows)
		return

	var grid = GridContainer.new()
	grid.columns = 4
	grid.add_theme_constant_override("h_separation", Tokens.SPACE_LG)
	col.add_child(grid)
	for header in ["DESIGN", "BUILT", "KILLS", "LOST"]:
		var h = Label.new()
		h.text = header
		h.theme_type_variation = "HintLabel"
		grid.add_child(h)

	var shown := 0
	for design_name in rows:
		if shown >= DEBRIEF_ROWS:
			break
		shown += 1
		var row: Dictionary = rows[design_name]
		for value in [str(design_name), str(row.get("built", 0)),
				str(row.get("kills", 0)), str(row.get("lost", 0))]:
			var cell = Label.new()
			cell.text = value
			cell.theme_type_variation = "StatLabel"
			grid.add_child(cell)


# --- Right: the draft ---------------------------------------------------------

func _build_roster(parent: Control) -> void:
	var col = VBoxContainer.new()
	col.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	col.size_flags_stretch_ratio = 1.6
	col.add_theme_constant_override("separation", Tokens.SPACE_MD)
	parent.add_child(col)

	var heading = Label.new()
	heading.text = "DRAFT YOUR ROSTER"
	heading.theme_type_variation = "HeadingLabel"
	col.add_child(heading)

	var hint = Label.new()
	hint.text = "Designs you edited in the Design Lab appear here. Leave a slot empty to drop that design."
	hint.theme_type_variation = "HintLabel"
	hint.autowrap_mode = TextServer.AUTOWRAP_WORD
	col.add_child(hint)

	roster_picker = RosterPickerScript.new()
	roster_picker.size_flags_vertical = Control.SIZE_EXPAND_FILL
	col.add_child(roster_picker)
	roster_picker.setup(bp_manager.list_blueprints(true), ROSTER_CAP)

	# Carried forward, not reset. The default between rounds is "field what I
	# fielded last time" - a draft screen that empties every slot would make
	# keeping a working roster more work than changing it.
	if _ops:
		roster_picker.fill_from(_ops.player_roster_paths)


# --- Bottom bar ---------------------------------------------------------------

func _build_action_bar(parent: Control) -> void:
	var bar = HBoxContainer.new()
	bar.add_theme_constant_override("separation", Tokens.SPACE_MD)
	parent.add_child(bar)

	# Between-rounds iteration is the whole premise - the report's "iterate on
	# this design" goes to the Lab, and this is the way back to it from here.
	# Lab and Abandon are both GHOST - this screen's commit point is Deploy.
	var lab_btn = StampedButtonScript.new()
	lab_btn.legend = "< DESIGN LAB"
	lab_btn.variant = StampedButtonScript.Variant.GHOST
	lab_btn.custom_minimum_size = Vector2(180, 44)
	lab_btn.pressed.connect(func(): _goto("res://scenes/MainLab.tscn"))
	bar.add_child(lab_btn)

	# DANGER variant for Abandon: the action is destructive (it cancels the
	# whole operation), and the red emission on the chamfer signals that
	# before the player reads the legend.
	var abandon_btn = StampedButtonScript.new()
	abandon_btn.legend = "ABANDON OPERATION"
	abandon_btn.variant = StampedButtonScript.Variant.DANGER
	abandon_btn.custom_minimum_size = Vector2(180, 44)
	abandon_btn.pressed.connect(_on_abandon)
	bar.add_child(abandon_btn)

	var spacer = Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	bar.add_child(spacer)

	var deploy_btn = StampedButtonScript.new()
	deploy_btn.legend = "DEPLOY >"
	deploy_btn.variant = StampedButtonScript.Variant.PRIMARY
	deploy_btn.custom_minimum_size = Vector2(220, 44)
	deploy_btn.pressed.connect(_on_deploy)
	bar.add_child(deploy_btn)

	UIFeedbackScript.wire(deploy_btn, "confirm")
	UIFeedbackScript.wire(lab_btn)
	UIFeedbackScript.wire(abandon_btn)


func _on_abandon() -> void:
	if _ops:
		_ops.reset_operation()
	_goto("res://scenes/MainMenu.tscn")


func _on_deploy() -> void:
	write_match_config()
	if _ops:
		_ops.set_player_roster(roster_picker.ordered_paths())
	_goto("res://scenes/Battle.tscn")


# Everything the next engagement needs. Public so a test can assert it without
# pressing Deploy - headless cannot.
func write_match_config() -> void:
	var match_config = get_node_or_null("/root/MatchConfig")
	if match_config == null or _ops == null:
		return
	var stage: Dictionary = _ops.get_current_stage_info()
	var map_id: String = str(stage.get("map_id", MapCatalog.DEFAULT_MAP_ID))
	var ai_difficulty: String = str(stage.get("ai_difficulty", "normal"))
	# Factions were chosen once for the whole operation (operations_setup.gd
	# writes them into the rule set) and stay stable per operation. Same
	# shape as the pre-Phase-5 code: no per-stage rewrite.
	var player_livery: String = LiveryScript.PLAYER_ID
	# ONE opponent identity for the whole campaign, keyed off the operation id,
	# so the enemy does not repaint between stages. Was the fixed string
	# "enemy", identical in every campaign and every skirmish alike.
	var enemy_livery: String = LiveryScript.ai_livery_id_for(str(_ops.operation_id))
	var paths: Array = roster_picker.ordered_paths()
	# selected_map_id is still on MatchConfig (battle_hud / after-action
	# report read it for display) - not part of the rule set.
	match_config.selected_map_id = map_id

	# Battle-system unification (Phase 1, Phase 5 final form). The
	# per-mode rule set is the single source of truth; the seven
	# legacy pre-match fields are retired.
	match_config.rule_set = MatchRuleSetScript.operations(
		map_id,
		player_livery,
		enemy_livery,
		paths,
		ai_difficulty,
		_ops.operation_id,
		_ops.current_stage,
	)


func _goto(path: String) -> void:
	var router = get_node_or_null("/root/SceneRouter")
	if router:
		router.goto(path)
	else:
		get_tree().change_scene_to_file(path)
