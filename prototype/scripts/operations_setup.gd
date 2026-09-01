extends Control
# Setup screen for Operations Mode (iterative campaign).
#
# An operation is 3-12 engagements of the same match Skirmish runs, with a draft
# between each. So this screen is Match Settings plus an itinerary: the same
# faction and difficulty controls, the same 12-slot RosterPicker, and a list of
# maps rather than one.
#
# WHAT THIS REPLACES. The first version hardcoded a 3-stage itinerary you could
# only read, and used a flat CheckBox list for the roster - the exact control
# match_setup.gd replaced with RosterPicker, for reasons that apply here
# identically: a checkbox list can express neither the ORDER designs are fielded
# in nor the 12-slot cap as anything more than a warning string. Sharing the
# picker also means the two setup screens cannot drift, which they already had.

const BlueprintManagerScript = preload("res://scripts/blueprint_manager.gd")
const LiveryScript = preload("res://scripts/livery.gd")
const UITheme = preload("res://scripts/ui_theme.gd")
const MapCatalog = preload("res://scripts/map_catalog.gd")
const OperationsManager = preload("res://scripts/operations_manager.gd")
const UIShell = preload("res://scripts/ui_shell.gd")
const Tokens = preload("res://scripts/ui_tokens.gd")
const UIFeedbackScript = preload("res://scripts/ui_feedback.gd")
const UIAnimScript = preload("res://scripts/ui_anim.gd")
const RosterPickerScript = preload("res://scripts/roster_picker.gd")
const StampedButtonScript = preload("res://scripts/ui_stamped_button.gd")
# MatchRuleSet uses class_name, not the older *Script preload pattern
# (the class is in match_rule_set.gd, which registers itself under that
# name). The old name leaked into this file when the class was renamed
# and a pre-existing check never got re-run, so the test runner bailed
# at the parse step whenever this file got included.
const MatchRuleSet = preload("res://scripts/match_rule_set.gd")

# Matches match_setup.gd's cap and match_director.ROSTER_LIMIT. Kept as its own
# constant rather than read off the director, which is not loaded at this point
# in the flow.
const ROSTER_CAP := 12

# Index 0 of every map dropdown. Resolved to a concrete map when the operation
# starts, so "Random" means a different rotation each run rather than a fixed
# one dressed up as a surprise.
const RANDOM_MAP_LABEL := "Random"

const DIFFICULTIES = ["easy", "normal", "hard"]
const DIFFICULTY_LABELS = ["Easy", "Normal", "Hard"]

# Height of the resume list's scroll box. Three rows of 36px plus their gaps,
# with the fourth row's top edge showing - a list that is exactly N rows tall
# gives no hint that there is an N+1th, and this one has no other affordance.
const RESUME_LIST_HEIGHT := 132

var difficulty_btn: OptionButton
var engagements_spin: SpinBox
var itinerary_list: VBoxContainer
var roster_picker: RosterPicker
var bp_manager: Node

# The resume list. `resume_section` is built unconditionally and hidden when
# there is nothing to resume, so discarding the last saved campaign has a place
# to leave from rather than needing the column rebuilt around it.
var resume_section: VBoxContainer = null
var resume_list: VBoxContainer = null
# The list_saved() entries currently drawn, in row order. Public for the same
# reason build_itinerary() is: headless cannot press a RESUME button, so the
# test asserts what the screen decided to OFFER.
var resume_entries: Array = []

# The 10-faction pickers are gone - the player authors one livery of their own
# (livery.gd), it is a profile setting rather than a per-operation choice, and
# it carries no mechanical bonus, so there is nothing here to choose.
var MAP_IDS: Array = []

# One OptionButton per engagement, index-aligned with the itinerary. Rebuilt
# whenever the engagement count changes.
var _map_pickers: Array = []


func _ready() -> void:
	bp_manager = BlueprintManagerScript.new()
	add_child(bp_manager)

	# Between the menu and the skirmish in intensity: a briefing room, not an
	# engagement. Marching snare, no guitar.
	var audio := get_node_or_null("/root/AudioManager")
	if audio != null:
		audio.play_music("operations")

	MAP_IDS = MapCatalog.get_map_ids()

	# Out-of-match screen - sits on the workbench, not on the in-match steel.
	# Kraft reads as a paper planning sheet, which fits a campaign-setup
	# screen that lives on paper more than on hardware. A cutting mat
	# would be too "modelling" for a screen that has no actual parts on it.
	UIShell.workbench(self, "kraft")
	var frame := UIShell.screen_frame(self)

	var vbox = VBoxContainer.new()
	vbox.add_theme_constant_override("separation", Tokens.SPACE_MD)
	frame.add_child(vbox)

	var title = Label.new()
	title.text = "OPERATIONS CAMPAIGN SETUP"
	title.theme_type_variation = "DisplayLabel"
	vbox.add_child(title)

	var subtitle = Label.new()
	subtitle.text = "Fight a run of engagements against the same opponent. Between each, read the After-Action Report and re-draft - the designs that worked stay, the ones that died get rebuilt."
	subtitle.theme_type_variation = "HintLabel"
	subtitle.autowrap_mode = TextServer.AUTOWRAP_WORD
	vbox.add_child(subtitle)

	var content_hbox = HBoxContainer.new()
	content_hbox.size_flags_vertical = Control.SIZE_EXPAND_FILL
	content_hbox.add_theme_constant_override("separation", Tokens.SPACE_XL)
	vbox.add_child(content_hbox)

	_build_left_column(content_hbox)
	_build_right_column(content_hbox)

	vbox.add_child(HSeparator.new())
	_build_action_bar(vbox, content_hbox)


# --- Left: campaign settings and the itinerary --------------------------------

func _build_left_column(parent: Control) -> void:
	var left_col = VBoxContainer.new()
	left_col.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	left_col.size_flags_stretch_ratio = 1.0
	left_col.add_theme_constant_override("separation", Tokens.SPACE_MD)
	parent.add_child(left_col)

	var settings_heading = Label.new()
	settings_heading.text = "CAMPAIGN SETTINGS"
	settings_heading.theme_type_variation = "HeadingLabel"
	left_col.add_child(settings_heading)

	var grid = GridContainer.new()
	grid.columns = 2
	grid.add_theme_constant_override("h_separation", Tokens.SPACE_LG)
	grid.add_theme_constant_override("v_separation", Tokens.SPACE_MD)
	left_col.add_child(grid)

	# Engagements. A SpinBox rather than a dropdown: the range is a count, and
	# ten near-identical numbered items in a list is a worse way to say "3 to 12".
	_add_grid_label(grid, "Engagements")
	engagements_spin = SpinBox.new()
	engagements_spin.min_value = OperationsManager.MIN_ENGAGEMENTS
	engagements_spin.max_value = OperationsManager.MAX_ENGAGEMENTS
	engagements_spin.value = 5
	engagements_spin.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	engagements_spin.tooltip_text = "How many battles the operation runs for. You re-draft your roster between each one."
	engagements_spin.value_changed.connect(_on_engagements_changed)
	grid.add_child(engagements_spin)

	_add_grid_label(grid, "AI Difficulty")
	difficulty_btn = OptionButton.new()
	for d in DIFFICULTY_LABELS:
		difficulty_btn.add_item(d)
	difficulty_btn.selected = 1
	difficulty_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	# The ramp is real and is not obvious from a single dropdown, so it is said
	# here rather than left for the player to infer from losing the last one.
	difficulty_btn.tooltip_text = "Where the operation ENDS UP. The opening engagements run one tier easier, so the first battle is somewhere to find out what your roster does wrong."
	difficulty_btn.item_selected.connect(func(_i): _rebuild_itinerary())
	grid.add_child(difficulty_btn)

	left_col.add_child(HSeparator.new())

	var itin_heading = Label.new()
	itin_heading.text = "ITINERARY"
	itin_heading.theme_type_variation = "HeadingLabel"
	left_col.add_child(itin_heading)

	var itin_hint = Label.new()
	itin_hint.text = "Pick the ground for each engagement, or leave one on Random."
	itin_hint.theme_type_variation = "HintLabel"
	left_col.add_child(itin_hint)

	var scroll = ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	left_col.add_child(scroll)

	itinerary_list = VBoxContainer.new()
	itinerary_list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	itinerary_list.add_theme_constant_override("separation", Tokens.SPACE_SM)
	scroll.add_child(itinerary_list)

	_rebuild_itinerary()


func _add_grid_label(parent: Control, text: String) -> void:
	var label = Label.new()
	label.text = text
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	label.custom_minimum_size.x = Tokens.SPACE_XL * 4
	parent.add_child(label)


func _on_engagements_changed(_value: float) -> void:
	_rebuild_itinerary()


# Rebuilt rather than resized, but the EXISTING CHOICES ARE CARRIED OVER: going
# 5 -> 6 engagements must not silently reshuffle the five maps already picked.
func _rebuild_itinerary() -> void:
	if itinerary_list == null:
		return
	var previous: Array = []
	for picker in _map_pickers:
		if is_instance_valid(picker):
			previous.append(picker.selected)

	for child in itinerary_list.get_children():
		child.queue_free()
	_map_pickers.clear()

	var count := int(engagements_spin.value)
	var base_difficulty: String = DIFFICULTIES[difficulty_btn.selected]
	var defaults: Array = OperationsManager.default_itinerary(count, base_difficulty)

	for i in range(count):
		var row = HBoxContainer.new()
		row.add_theme_constant_override("separation", Tokens.SPACE_SM)

		var index_label = Label.new()
		index_label.text = "%d." % (i + 1)
		index_label.custom_minimum_size.x = Tokens.SPACE_LG
		row.add_child(index_label)

		var map_btn = OptionButton.new()
		map_btn.add_item(RANDOM_MAP_LABEL)
		for map_id in MAP_IDS:
			map_btn.add_item(MapCatalog.get_map_name(map_id))
		map_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		if i < previous.size():
			map_btn.selected = previous[i]
		else:
			# +1 for the Random entry occupying index 0.
			var default_idx: int = MAP_IDS.find(str(defaults[i].get("map_id", "")))
			map_btn.selected = default_idx + 1 if default_idx >= 0 else 0
		row.add_child(map_btn)
		_map_pickers.append(map_btn)

		# The per-engagement tier, shown because the ramp is what makes the
		# difficulty dropdown mean something other than a flat setting.
		var tier_label = Label.new()
		tier_label.text = str(defaults[i].get("ai_difficulty", "normal")).to_upper()
		tier_label.theme_type_variation = "HintLabel"
		tier_label.custom_minimum_size.x = Tokens.SPACE_XL * 2
		tier_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
		row.add_child(tier_label)

		itinerary_list.add_child(row)

	UIFeedbackScript.wire_tree(itinerary_list, "select")


# --- Right: the roster --------------------------------------------------------

func _build_right_column(parent: Control) -> void:
	var right_col = VBoxContainer.new()
	right_col.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	right_col.size_flags_stretch_ratio = 1.4
	right_col.add_theme_constant_override("separation", Tokens.SPACE_MD)
	parent.add_child(right_col)

	var roster_heading = Label.new()
	roster_heading.text = "STARTING ROSTER"
	roster_heading.theme_type_variation = "HeadingLabel"
	right_col.add_child(roster_heading)

	var hint = Label.new()
	hint.text = "Drag designs into a slot. Leave it empty to field your newest designs. You re-draft between engagements."
	hint.theme_type_variation = "HintLabel"
	hint.autowrap_mode = TextServer.AUTOWRAP_WORD
	right_col.add_child(hint)

	# named_only, matching match_setup.gd: this is the "what goes into the match"
	# list, so unnamed test leftovers stay in the Blueprint Library.
	roster_picker = RosterPickerScript.new()
	roster_picker.size_flags_vertical = Control.SIZE_EXPAND_FILL
	right_col.add_child(roster_picker)
	roster_picker.setup(bp_manager.list_blueprints(true), ROSTER_CAP)


# --- Bottom bar ---------------------------------------------------------------

func _build_action_bar(parent: Control, feedback_root: Control) -> void:
	var bottom_bar = HBoxContainer.new()
	bottom_bar.add_theme_constant_override("separation", Tokens.SPACE_MD)
	parent.add_child(bottom_bar)

	var back_btn = StampedButtonScript.new()
	back_btn.legend = "< BACK TO MAIN MENU"
	back_btn.variant = StampedButtonScript.Variant.GHOST
	back_btn.custom_minimum_size = Vector2(180, 44)
	back_btn.pressed.connect(_return_to_menu)
	bottom_bar.add_child(back_btn)

	var spacer = Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	bottom_bar.add_child(spacer)

	var start_btn = StampedButtonScript.new()
	start_btn.legend = "BEGIN OPERATION >"
	start_btn.variant = StampedButtonScript.Variant.PRIMARY
	start_btn.custom_minimum_size = Vector2(220, 44)
	start_btn.pressed.connect(_on_start_operation_pressed)
	bottom_bar.add_child(start_btn)

	# "Begin Operation" commits to a campaign, so it gets the radio
	# acknowledgement rather than a click.
	UIFeedbackScript.wire(start_btn, "confirm")
	UIFeedbackScript.wire(back_btn)
	UIFeedbackScript.wire_tree(feedback_root, "select")

	call_deferred("_animate_entrance")


func _animate_entrance() -> void:
	if is_instance_valid(itinerary_list):
		UIAnimScript.stagger_in(itinerary_list)


# --- Starting the operation ---------------------------------------------------

# The itinerary the pickers currently describe. Public so a test can assert the
# screen's output without driving its buttons - headless cannot press them.
func build_itinerary() -> Array:
	var count := int(engagements_spin.value)
	var base_difficulty: String = DIFFICULTIES[difficulty_btn.selected]
	var rng := RandomNumberGenerator.new()
	rng.randomize()

	var out: Array = []
	for i in range(count):
		var map_id: String = ""
		if i < _map_pickers.size():
			var sel: int = _map_pickers[i].selected
			if sel > 0 and sel - 1 < MAP_IDS.size():
				map_id = str(MAP_IDS[sel - 1])
		if map_id == "" and not MAP_IDS.is_empty():
			map_id = str(MAP_IDS[rng.randi_range(0, MAP_IDS.size() - 1)])
		out.append({
			"map_id": map_id,
			"ai_difficulty": OperationsManager.ramped_difficulty(i, count, base_difficulty),
			"title": "Engagement %d of %d" % [i + 1, count],
		})
	return out


func _on_start_operation_pressed() -> void:
	var itinerary := build_itinerary()
	var sel_diff: String = DIFFICULTIES[difficulty_btn.selected]

	# ONE manager, the autoload. It used to be constructed here - a throwaway to
	# read the default itinerary, then a second one parented into /root - which
	# is exactly why nothing else in the game could reach the campaign state.
	# The fallback covers a fixture instantiated with no autoloads.
	var ops_node = get_node_or_null("/root/OperationsManager")
	if not ops_node:
		ops_node = OperationsManager.new()
		ops_node.name = "OperationsManager"
		get_tree().root.add_child(ops_node)
	ops_node.start_new_operation(itinerary, sel_diff)

	_write_match_config(ops_node.get_current_stage_info(), ops_node.operation_id, ops_node.current_stage)
	ops_node.set_player_roster(roster_picker.ordered_paths())

	var router = get_node_or_null("/root/SceneRouter")
	if router:
		router.goto("res://scenes/Battle.tscn")
	else:
		get_tree().change_scene_to_file("res://scenes/Battle.tscn")


# Everything the first engagement needs. Split out because the between-rounds
# loop has to do exactly this again for stage 2..N, and the two must not drift.
#
# 2026-08-10: writes only the rule set and the display-only selected_map_id.
# The seven legacy pre-match fields on MatchConfig are retired; everything
# match_director needs (player_livery, enemy_livery, blueprint paths,
# ai_difficulty) now lives on the rule set. selected_map_id stays on
# MatchConfig itself because battle_hud's minimap title and the
# after-action report read it for display purposes - it is not a
# match-config input, just a "what map is this" label.
func _write_match_config(stage: Dictionary, operation_id: String, stage_index: int) -> void:
	var match_config = get_node_or_null("/root/MatchConfig")
	if match_config == null:
		return
	var map_id: String = str(stage.get("map_id", MapCatalog.DEFAULT_MAP_ID))
	var ai_difficulty: String = str(stage.get("ai_difficulty", "normal"))
	var paths: Array = roster_picker.ordered_paths()
	match_config.selected_map_id = map_id
	match_config.rule_set = MatchRuleSet.operations(
		map_id,
		# Fixed ids rather than a player choice - see the note by the
		# removed pickers above. operations_draft.gd reads the rule set
		# back rather than these legacy fields, so the literals here
		# become the per-stage constants and the rest of the campaign
		# never has to re-think them.
		LiveryScript.PLAYER_ID,
		"enemy",
		paths,
		ai_difficulty,
		operation_id,
		stage_index,
	)


# Routed through SceneRouter so leaving this screen fades out rather than cutting.
# The get_node_or_null guard keeps the direct call as a fallback - a scene
# instantiated outside the running game (a test fixture) has no autoloads.
func _return_to_menu() -> void:
	var router = get_node_or_null("/root/SceneRouter")
	if router:
		router.goto("res://scenes/MainMenu.tscn")
	else:
		get_tree().change_scene_to_file("res://scenes/MainMenu.tscn")
