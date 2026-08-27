extends Control
# Pre-match settings screen: MapSelect.tscn routes here after the map is
# chosen (MatchConfig.selected_map_id is already set by then), this screen
# adds faction selection, Blueprint Library import, AI difficulty, and
# starting resources - then "Start Match" writes everything into
# MatchConfig and continues to Skirmish.tscn, same relay pattern
# MapSelect already established for the map choice.
#
# Every field here is genuinely optional: leaving factions on "Auto",
# selecting zero blueprints, and leaving resources on "Standard" all
# reproduce the exact old hardcoded-default behavior (see match_config.gd's
# own field comments) - this screen only OVERRIDES skirmish.gd's existing
# defaults, it doesn't replace them.

const BlueprintManagerScript = preload("res://scripts/blueprint_manager.gd")
const LiveryScript = preload("res://scripts/livery.gd")
const UITheme = preload("res://scripts/ui_theme.gd")
const Tokens = preload("res://scripts/ui_tokens.gd")
const MapCatalog = preload("res://scripts/map_catalog.gd")
const RosterPickerScript = preload("res://scripts/roster_picker.gd")
const UIFeedbackScript = preload("res://scripts/ui_feedback.gd")
const MatchRuleSetScript = preload("res://scripts/match_rule_set.gd")
const StampedButtonScript = preload("res://scripts/ui_stamped_button.gd")
const UIShell = preload("res://scripts/ui_shell.gd")

var bg_rect: ColorRect

# WAS a 10-entry faction picker built from FactionCatalog.get_ids(). The
# premade factions are gone: the player authors ONE livery of their own
# (livery.gd), it is a persistent profile setting rather than a per-match
# choice, and it carries no mechanical bonus - so there is nothing left for
# this screen to ask. Enemy teams roll their own livery deterministically from
# their team id.
#
# The two ids below are what the match still needs to plumb through, and they
# are constants now rather than dropdown state.
const DIFFICULTIES = ["easy", "normal", "hard"]
const DIFFICULTY_LABELS = ["Easy", "Normal", "Hard"]
# Starting credits; -1 means "use the match's own default" (Standard reproduces
# it exactly, not just a same-looking copy of it). The old (metal, crystal) pairs
# were converted at the 2x crystal rate: 250/75 -> 400, 900/400 -> 1700.
const RESOURCE_PRESETS = [-1, 400, 1700]
const RESOURCE_LABELS = ["Standard", "Low (tight economy)", "High (build fast, fight fast)"]
# AI Opponent. WHAT THIS REPLACES, AND WHY: a hardcoded `enemy_faction = "enemy"`
# in _on_start_pressed() that left the player no way to play the map without an
# AI commander. The infrastructure for "no AI" already exists - MatchRuleSet
# has carried an enable_ai field since the test_range factory was added
# (match_rule_set.gd:117, used at match_director.gd:561-578 to gate the
# CommanderScript instantiation) - so this dropdown is just exposing a
# per-match switch that the setup screen previously hid.
#
# Added 2026-08-18 for the live perf investigation: a playtest in each mode
# (Standard vs None) is the A/B test for whether the AI commander is the
# cause of the per-frame hitches. If the hitches collapse in None mode the
# commander was the source; if they stay it is something else.
const AI_OPPONENT_LABELS = ["None", "Standard"]
# Matches skirmish.gd's own hardcoded roster.slice(0, 12) - kept as a
# separate constant here (not read from skirmish.gd, which isn't loaded
# yet at this point in the flow) since this screen needs to warn BEFORE
# the roster is ever built, not just match its cap after the fact.
const ROSTER_CAP = 12

var map_btn: OptionButton
var map_desc_label: Label
var MAP_IDS: Array = []
var difficulty_btn: OptionButton
var resources_btn: OptionButton
var ai_btn: OptionButton
var bp_manager: Node
var roster_picker: RosterPicker

func _ready():
	bp_manager = BlueprintManagerScript.new()
	add_child(bp_manager)


	bg_rect = ColorRect.new()
	bg_rect.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(bg_rect)
	# Out-of-match screen - sits on the workbench, not on the in-match steel.
	# The match setup screen is the per-match pre-game lobby: rules, map,
	# roster, opponent. Cutting mat reads as the workbench surface you set a
	# model down on while you decide what goes in the match - the most
	# "kitbashing" of the L0 surfaces, and the right one for a screen whose
	# job is configuring units.
	#
	# Tuned a little lighter than the L0 default (0.85 vs 0.70). The screen
	# is dominated by text and form controls, not by chrome panels, and a
	# slightly lighter cutting mat keeps the controls reading as the
	# subject. The brightness rule (UI_STYLE_GUIDE.md §3.2) still holds -
	# moulded buttons land near 0.144 and the workbench lands near 0.10,
	# so the floor is well below the control tier.
	UITheme.apply_material(bg_rect, "cutting_mat", {
		"brightness": 0.85,
		"wear": 0.05,
		"grime": 0.04,
		"scale": 2.0,
		"vignette": 0.12,
	})

	# The shared 3D UI viewport for this screen. match_setup builds
	# its own backdrop rather than calling UIShell.workbench(), so
	# the stage does not get auto-installed the way backdrop() /
	# workbench() would have installed it. Adding it here so the
	# StampedButton instances below find it in their ancestor chain.
	UIShell.stage(self)

	var root_vbox = VBoxContainer.new()
	root_vbox.set_anchors_preset(Control.PRESET_FULL_RECT)
	root_vbox.offset_top = 24
	root_vbox.offset_bottom = -24
	root_vbox.offset_left = 160
	root_vbox.offset_right = -160
	root_vbox.add_theme_constant_override("separation", Tokens.SPACE_SM)
	add_child(root_vbox)

	var title = Label.new()
	title.text = "MATCH SETTINGS"
	# TitleLabel is the registered screen-title variation: 24px stencil in
	# TEXT_PRIMARY. Deliberately smaller than the 34px it used to be - 34 is not
	# a step on the type scale, and the ad-hoc amber modulate it carried was a
	# near-miss on SIGNAL_HAZARD that spent an attention colour on decoration.
	# Amber has one job (attention required), and a screen title is not it.
	title.theme_type_variation = "TitleLabel"
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	root_vbox.add_child(title)
	root_vbox.add_child(HSeparator.new())

	var grid = GridContainer.new()
	grid.columns = 2
	grid.add_theme_constant_override("h_separation", Tokens.SPACE_LG)
	grid.add_theme_constant_override("v_separation", Tokens.SPACE_MD)
	root_vbox.add_child(grid)

	# Map selection now lives HERE rather than on a screen in front of this
	# one. MapSelect.tscn was a whole screen for a single choice, and picking
	# a map committed you to it - the old list transitioned scenes on click,
	# so you left before seeing anything about the map and had to back out to
	# change your mind. Folding it in makes the map one setting among the
	# others, visible alongside the forces it will be fought over.
	map_btn = _add_dropdown(grid, "Map", _build_map_labels())
	map_btn.item_selected.connect(_on_map_selected)
	map_btn.tooltip_text = "Where the match is fought."
	_sync_map_selection()


	# There used to be a _refresh_theme() re-theme wired to this dropdown, on the
	# premise that the screen's chrome repainted in the player's faction colour.
	# That premise is gone: UI chrome deliberately stopped being faction-tinted,
	# because faction colour's real job is telling the player who owns a unit on
	# the battlefield and repainting the menus in it collided with that. The
	# backdrop is now the same steel for every faction, so there is nothing left
	# to refresh and no handler to connect.

	difficulty_btn = _add_dropdown(grid, "AI Difficulty", DIFFICULTY_LABELS)
	difficulty_btn.selected = 1 # Normal
	# Real, not cosmetic (enemy_ai.gd's own DIFFICULTY_TIMER_MULT/PITY_MULT) -
	# explained here since the dropdown itself gives no hint what changes.
	difficulty_btn.tooltip_text = "Changes how fast the AI builds/attacks and how quickly it recovers from a bad economy. Doesn't change unit stats - just AI pacing."
	difficulty_btn.set_item_tooltip(0, "AI builds and attacks more slowly, and struggles longer if its economy falls behind.")
	difficulty_btn.set_item_tooltip(1, "Balanced AI pacing.")
	difficulty_btn.set_item_tooltip(2, "AI builds and attacks faster, and recovers quickly from economic setbacks.")
	resources_btn = _add_dropdown(grid, "Starting Resources", RESOURCE_LABELS)
	# Default to Standard so a player who never opens the dropdown gets the
	# same match they got before this control was added. enable_ai defaults
	# to true on MatchRuleSet, so the explicit `selected = 1` is a no-op
	# for the rule set today, but a future change to that default would
	# not silently break the screen's promise of "looks like the old
	# Skirmish on a fresh load".
	ai_btn = _add_dropdown(grid, "AI Opponent", AI_OPPONENT_LABELS)
	ai_btn.selected = 1
	ai_btn.tooltip_text = "Whether the AI commander runs in this match. None plays the map solo with no opposing force; Standard is a regular Skirmish."
	ai_btn.set_item_tooltip(0, "No AI commander. Plays the map solo; useful for testing designs on a live map, and for isolating whether the AI is the cause of a per-frame cost.")
	ai_btn.set_item_tooltip(1, "AI commander runs (Skirmish default).")

	# The selected map's description, live beneath the settings grid. On the
	# old MapSelect screen this text existed but you had to leave the screen
	# to act on it; here it updates in place as you change the dropdown.
	map_desc_label = Label.new()
	map_desc_label.theme_type_variation = "HintLabel"
	map_desc_label.autowrap_mode = TextServer.AUTOWRAP_WORD
	root_vbox.add_child(map_desc_label)
	_update_map_description()

	root_vbox.add_child(HSeparator.new())

	var library_label = Label.new()
	library_label.text = "Drag units into slots 1-11 and a harvester into slot 12 (harvester-only; harvesters also fit any other slot). Defensive buildings go in their own four wells and are placed during the match. Leave the roster empty to auto-include your newest designs."
	library_label.theme_type_variation = "HintLabel"
	library_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	root_vbox.add_child(library_label)

	# named_only: this is the "what goes into the match" list, so it shows
	# only designs the player deliberately saved under a name. Unnamed
	# leftovers from testing stay in the Blueprint Library where they can be
	# renamed or deleted.
	var entries = bp_manager.list_blueprints(true)

	# Replaces a flat CheckBox list. See roster_picker.gd's header for why: the
	# checkbox version could express neither the ORDER designs are fielded in nor
	# the roster cap as anything more than a warning string. Its output contract
	# is identical - an ordered Array of blueprint paths - so _on_start_pressed()
	# below is unchanged apart from where it reads that array from.
	roster_picker = RosterPickerScript.new()
	roster_picker.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	roster_picker.size_flags_vertical = Control.SIZE_EXPAND_FILL
	root_vbox.add_child(roster_picker)
	roster_picker.setup(entries, ROSTER_CAP)

	root_vbox.add_child(HSeparator.new())

	var button_row = HBoxContainer.new()
	button_row.alignment = BoxContainer.ALIGNMENT_CENTER
	button_row.add_theme_constant_override("separation", Tokens.SPACE_LG)
	root_vbox.add_child(button_row)

	# GHOST variant for Back: the screen is not asking the player to commit,
	# just to leave. The 3D mesh renders with a lighter, less metallic finish
	# and no signal emission, so the visual hierarchy reads PRIMARY > GHOST.
	var back_btn = StampedButtonScript.new()
	back_btn.legend = "BACK"
	back_btn.variant = StampedButtonScript.Variant.GHOST
	back_btn.custom_minimum_size = Vector2(200, 48)
	# Back now returns to the main menu, not to MapSelect - map choice is a
	# column on this screen, so there is no intermediate screen to go back to.
	back_btn.pressed.connect(_return_to_menu)
	button_row.add_child(back_btn)

	# PRIMARY variant for Start Match. The single commit point on this screen -
	# the style guide allows at most one PRIMARY, and "this is the match you
	# are about to fight" is unambiguously it. The 3D mesh carries the green
	# emission on its chamfer; the legend stays amber for consistency.
	var start_btn = StampedButtonScript.new()
	start_btn.legend = "START MATCH"
	start_btn.variant = StampedButtonScript.Variant.PRIMARY
	start_btn.custom_minimum_size = Vector2(240, 48)
	start_btn.pressed.connect(_on_start_pressed)
	button_row.add_child(start_btn)

	# "confirm" on Start Match: it commits to a match, so it gets the radio
	# acknowledgement rather than a click. The dropdown grid is "select".
	UIFeedbackScript.wire(start_btn, "confirm")
	UIFeedbackScript.wire(back_btn)
	UIFeedbackScript.wire_tree(grid, "select")

# Map list, sourced from MapCatalog so a newly-added map file appears here
# with no code change - same discovery-over-declaration approach the terrain
# variants and hull roster already use.
func _build_map_labels() -> PackedStringArray:
	MAP_IDS = MapCatalog.get_map_ids()
	var labels := PackedStringArray()
	for map_id in MAP_IDS:
		labels.append(MapCatalog.get_map_name(map_id))
	return labels

# Selecting a map writes straight through to MatchConfig, so the choice
# survives even if the player backs out to the menu and returns - the old
# flow only recorded it at the moment of scene transition.
func _on_map_selected(idx: int) -> void:
	if idx < 0 or idx >= MAP_IDS.size():
		return
	var match_config = get_node_or_null("/root/MatchConfig")
	if match_config:
		match_config.selected_map_id = MAP_IDS[idx]
	_update_map_description()

func _sync_map_selection() -> void:
	var match_config = get_node_or_null("/root/MatchConfig")
	var current: String = ""
	if match_config and "selected_map_id" in match_config:
		current = str(match_config.selected_map_id)
	var idx := MAP_IDS.find(current)
	if idx < 0:
		idx = maxi(0, MAP_IDS.find(MapCatalog.DEFAULT_MAP_ID))
	map_btn.selected = idx
	_on_map_selected(idx)

func _update_map_description() -> void:
	if not map_desc_label or map_btn.selected < 0 or map_btn.selected >= MAP_IDS.size():
		return
	var map_def: Dictionary = MapCatalog.get_map(MAP_IDS[map_btn.selected])
	map_desc_label.text = str(map_def.get("description", ""))

func _add_dropdown(parent: Control, label_text: String, labels: PackedStringArray) -> OptionButton:
	var label = Label.new()
	label.text = label_text
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	parent.add_child(label)

	var btn = OptionButton.new()
	btn.custom_minimum_size = Vector2(260, 36)
	for l in labels:
		btn.add_item(l)
	parent.add_child(btn)
	return btn

# _update_selection_counter() lived here. The whole function - the count, the
# over-cap HAZARD message, and the loop disabling unchecked boxes once the cap
# was hit - existed to compensate for a list that could not represent the cap.
# The slot grid represents it structurally: there are exactly ROSTER_CAP wells
# and no way to fill a thirteenth, so there is no over-cap state left to warn
# about. RosterPicker keeps its own "n / 12 slots filled" readout.

# _prettify() moved to RosterPicker.prettify() along with its only caller - the
# blueprint row that became a roster card.

func _on_start_pressed():
	var match_config = get_node_or_null("/root/MatchConfig")
	if match_config:
		# Fixed ids rather than a player choice - see the note at the top of
		# this file. LiveryScript resolves PLAYER_ID to the player's authored
		# scheme and any other id to a deterministic roll, so "enemy" is a
		# stable, distinct look with nothing to persist.
		var player_faction: String = LiveryScript.PLAYER_ID
		var enemy_faction: String = "enemy"
		var ai_difficulty: String = DIFFICULTIES[difficulty_btn.selected]
		var starting_credits: int = RESOURCE_PRESETS[resources_btn.selected]
		# The AI Opponent dropdown writes through to MatchRuleSet.enable_ai
		# (match_rule_set.gd:117). None = false (no CommanderScript), Standard
		# = true (default behaviour, what the match used to do before this
		# control existed). Set on the rule set after the factory call rather
		# than adding an enable_ai parameter to skirmish() - same pattern as
		# starting_credits below, same justification.
		var ai_enabled: bool = ai_btn.selected != 0
		# Slot order, left to right and top to bottom, gaps skipped. Under the old
		# checkbox list this was library sort order, which meant which designs
		# survived skirmish.gd's roster.slice(0, 12) was effectively incidental.
		var paths: Array = roster_picker.ordered_paths() if roster_picker else []
		# selected_map_id is still on MatchConfig (battle_hud / after-action
		# report read it for display) - not part of the rule set.
		match_config.selected_map_id = MAP_IDS[map_btn.selected] if map_btn.selected >= 0 and map_btn.selected < MAP_IDS.size() else MapCatalog.DEFAULT_MAP_ID

		# Battle-system unification (Phase 1, now Phase 5 final form). The
		# per-mode rule set is the single source of truth; the seven
		# legacy pre-match fields (player_faction / enemy_faction /
		# selected_blueprint_paths / ai_difficulty / starting_credits) are
		# retired. Everything below is what MatchConfig now carries.
		match_config.rule_set = MatchRuleSetScript.skirmish(
			match_config.selected_map_id,
			player_faction,
			enemy_faction,
			paths,
			ai_difficulty,
		)
		# The skirmish() factory doesn't take starting_credits because the
		# factory exists to enforce the rule set's SHAPE; the bank preset
		# is a screen value, not a mode-level one. Set it on the rule
		# set after construction - sentinel -1 keeps MatchRuleSet's own
		# default of "use the director's STARTING_CREDITS" intact when
		# the screen does not override.
		match_config.rule_set.starting_credits = starting_credits
		match_config.rule_set.enable_ai = ai_enabled

	# Routed through SceneRouter rather than change_scene_to_file(): loading
	# Skirmish.tscn synchronously blocks the main thread for over a second,
	# during which Windows marks the window "(Not Responding)". The router
	# loads it on a worker thread behind a loading screen instead.
	var router = get_node_or_null("/root/SceneRouter")
	var map_name := ""
	if map_btn and map_btn.selected >= 0 and map_btn.selected < MAP_IDS.size():
		map_name = MapCatalog.get_map_name(MAP_IDS[map_btn.selected])
	# Battle.tscn is the match runtime. It used to be Skirmish.tscn, and briefly a
	# MatchConfig.target_scene indirection while both existed - that indirection
	# died with the legacy runtime rather than being left as a seam pointing at
	# one option.
	if router:
		router.goto("res://scenes/Battle.tscn", map_name)
	else:
		get_tree().change_scene_to_file("res://scenes/Battle.tscn")


# Routed through SceneRouter so leaving this screen fades out rather than cutting.
# The get_node_or_null guard keeps the direct call as a fallback, matching the
# pattern the other router call sites in this file already use - a scene
# instantiated outside the running game (a test fixture) has no autoloads.
func _return_to_menu() -> void:
	var router = get_node_or_null("/root/SceneRouter")
	if router:
		router.goto("res://scenes/MainMenu.tscn")
	else:
		get_tree().change_scene_to_file("res://scenes/MainMenu.tscn")
