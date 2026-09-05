extends Control
# OPERATIONS WAR ROOM - the campaign setup screen expressed as one persistent
# Ops-Table rather than a form split into unrelated columns.
#
# The interaction contract is intentionally the same as the War Room mode in
# match_setup.gd: theatre intelligence, a live squadron staging surface, roster
# wells and command directives remain visible together. Operations adds the one
# thing a skirmish does not have: a 3-12 engagement route whose map choices and
# difficulty ramp must be readable as a campaign, not as a single-match option.
#
# Everything below the presentation boundary remains the established Operations
# contract. build_itinerary() still resolves Random sectors at commit time,
# ramped_difficulty() still owns every engagement tier, and Begin Operation still
# writes the same MatchRuleSet before routing to Battle.tscn.

const BlueprintManagerScript = preload("res://scripts/blueprint_manager.gd")
const LiveryScript = preload("res://scripts/livery.gd")
const UITheme = preload("res://scripts/ui_theme.gd")
const MapCatalog = preload("res://scripts/map_catalog.gd")
const OperationsManager = preload("res://scripts/operations_manager.gd")
const Tokens = preload("res://scripts/ui_tokens.gd")
const UIFeedbackScript = preload("res://scripts/ui_feedback.gd")
const UIAnimScript = preload("res://scripts/ui_anim.gd")
const RosterPickerScript = preload("res://scripts/roster_picker.gd")
const StampedButtonScript = preload("res://scripts/ui_stamped_button.gd")
const MatchSetupScript = preload("res://scripts/match_setup.gd")
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
const AUTOPICK_LIMIT := 8

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
var _theatre_preview = null
var _theatre_title: Label = null
var _theatre_desc: Label = null
var _route_summary: VBoxContainer = null
var _readiness: Label = null
var _begin_btn: Button = null
var _hero_view = null
var _active_engagement := 0

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

	# MatchSetup's console is the reference surface: a flat, warm-black command
	# floor with raised instrument plates. Operations is a command room, not a
	# paper worksheet, so it deliberately does not use UIShell's kraft workbench.
	var floor_rect := ColorRect.new()
	floor_rect.set_anchors_preset(Control.PRESET_FULL_RECT)
	floor_rect.color = Tokens.BASE_900
	floor_rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(floor_rect)

	var frame := MarginContainer.new()
	frame.set_anchors_preset(Control.PRESET_FULL_RECT)
	for side in ["margin_left", "margin_right", "margin_top", "margin_bottom"]:
		frame.add_theme_constant_override(side, Tokens.STAGE_PAD)
	add_child(frame)

	var column := VBoxContainer.new()
	column.add_theme_constant_override("separation", Tokens.SPACE_MD)
	frame.add_child(column)
	column.add_child(_build_console_header())

	var deck_scroll := ScrollContainer.new()
	deck_scroll.name = "OperationsOpsTableScroll"
	deck_scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	deck_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	deck_scroll.follow_focus = true
	column.add_child(deck_scroll)

	var deck := HBoxContainer.new()
	deck.name = "OperationsOpsTable"
	deck.add_theme_constant_override("separation", Tokens.SPACE_MD)
	deck.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	deck.size_flags_vertical = Control.SIZE_EXPAND_FILL
	deck_scroll.add_child(deck)

	_build_theatre_column(deck)
	_build_staging_column(deck)
	_build_directives_column(deck)

	_rebuild_itinerary()
	_refresh_staging()
	_refresh_readiness()
	UIFeedbackScript.wire_tree(self)
	call_deferred("_animate_entrance")


func _build_console_header() -> Control:
	var band := PanelContainer.new()
	band.name = "OperationsConsoleHeader"
	band.custom_minimum_size.y = Tokens.SPINE_HEIGHT
	band.add_theme_stylebox_override("panel", UITheme.flat_style(
		Tokens.BASE_800, Tokens.BASE_500, Tokens.SPACE_MD, "raised"))

	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", Tokens.SPACE_MD)
	band.add_child(row)

	var icon = UITheme.chrome_rect("stage_launch", Tokens.SPINE_ICON, Tokens.SIGNAL_HAZARD)
	if icon != null:
		row.add_child(icon)
	var title := Label.new()
	title.text = "OPERATIONS WAR ROOM // OPS-TABLE"
	title.theme_type_variation = "TitleLabel"
	row.add_child(title)

	var spacer := Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(spacer)

	var cycle := Label.new()
	cycle.text = "CAMPAIGN PLANNING NET // LIVE"
	cycle.theme_type_variation = "StatLabel"
	cycle.add_theme_color_override("font_color", Tokens.SIGNAL_GO)
	row.add_child(cycle)
	return band


# --- Left: theatre recon and the full campaign route -------------------------

func _build_theatre_column(parent: Control) -> void:
	var panel := _command_panel("TheatreRecon", 420)
	parent.add_child(panel)
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", Tokens.SPACE_SM)
	box.size_flags_vertical = Control.SIZE_EXPAND_FILL
	panel.add_child(box)

	box.add_child(_section_heading("stage_theatre", "THEATRE RECON // CAMPAIGN ROUTE"))
	_theatre_preview = MatchSetupScript.MapPreview.new()
	_theatre_preview.custom_minimum_size = Vector2(390, 220)
	_theatre_preview.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_theatre_preview.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_theatre_preview.size_flags_stretch_ratio = 0.8
	box.add_child(_theatre_preview)

	var readout := PanelContainer.new()
	readout.add_theme_stylebox_override("panel", UITheme.flat_style(
		Tokens.BASE_900, Tokens.BASE_600, Tokens.SPACE_SM, "flush"))
	var readout_box := VBoxContainer.new()
	readout_box.add_theme_constant_override("separation", Tokens.SPACE_XS)
	readout.add_child(readout_box)
	_theatre_title = Label.new()
	_theatre_title.theme_type_variation = "HUDValueLabel"
	_theatre_title.add_theme_color_override("font_color", Tokens.SIGNAL_HAZARD)
	readout_box.add_child(_theatre_title)
	_theatre_desc = Label.new()
	_theatre_desc.theme_type_variation = "HintLabel"
	_theatre_desc.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	readout_box.add_child(_theatre_desc)
	box.add_child(readout)

	var route_hdr := Label.new()
	route_hdr.text = "ENGAGEMENT ITINERARY"
	route_hdr.theme_type_variation = "HeadingLabel"
	box.add_child(route_hdr)
	var route_hint := Label.new()
	route_hint.text = "Select a route card, then set its sector. Random is resolved when the operation begins."
	route_hint.theme_type_variation = "HintLabel"
	route_hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	box.add_child(route_hint)

	var scroll := ScrollContainer.new()
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	box.add_child(scroll)
	itinerary_list = VBoxContainer.new()
	itinerary_list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	itinerary_list.add_theme_constant_override("separation", Tokens.SPACE_XS)
	scroll.add_child(itinerary_list)


# --- Centre: live formation turntable and shared roster tray -----------------

func _build_staging_column(parent: Control) -> void:
	var centre := VBoxContainer.new()
	centre.name = "SquadronStaging"
	centre.custom_minimum_size.x = 720
	centre.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	centre.size_flags_vertical = Control.SIZE_EXPAND_FILL
	centre.add_theme_constant_override("separation", Tokens.SPACE_MD)
	parent.add_child(centre)

	_hero_view = MatchSetupScript.SquadronHeroView.new()
	_hero_view.custom_minimum_size = Vector2(0, 260)
	_hero_view.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_hero_view.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_hero_view.size_flags_stretch_ratio = 0.75
	centre.add_child(_hero_view)

	var roster_panel := PanelContainer.new()
	roster_panel.name = "StartingEchelon"
	roster_panel.add_theme_stylebox_override("panel", UITheme.flat_style(
		Tokens.BASE_800, Tokens.BASE_500, Tokens.SPACE_MD, "raised"))
	roster_panel.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	roster_panel.size_flags_vertical = Control.SIZE_EXPAND_FILL
	roster_panel.size_flags_stretch_ratio = 1.5
	centre.add_child(roster_panel)

	var roster_box := VBoxContainer.new()
	roster_box.add_theme_constant_override("separation", Tokens.SPACE_SM)
	roster_box.size_flags_vertical = Control.SIZE_EXPAND_FILL
	roster_panel.add_child(roster_box)
	roster_box.add_child(_section_heading("stage_roster", "STARTING ECHELON // ROSTER TRAY"))
	var hint := Label.new()
	hint.text = "Click a design to assign the next free well, or drag for exact order. The roster returns to this table between engagements."
	hint.theme_type_variation = "HintLabel"
	hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	roster_box.add_child(hint)

	roster_picker = RosterPickerScript.new()
	roster_picker.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	roster_picker.size_flags_vertical = Control.SIZE_EXPAND_FILL
	roster_box.add_child(roster_picker)
	var entries: Array = bp_manager.list_blueprints(true)
	roster_picker.setup(entries, ROSTER_CAP)
	var auto_names: Array = []
	for entry in entries:
		if auto_names.size() >= AUTOPICK_LIMIT:
			break
		auto_names.append(str(entry.get("name", "Untitled")))
	roster_picker.set_auto_draft(auto_names)
	roster_picker.roster_changed.connect(_on_roster_changed)


# --- Right: campaign directives, ramp telemetry and commit actuator ----------

func _build_directives_column(parent: Control) -> void:
	var panel := _command_panel("CampaignDirectives", 360)
	parent.add_child(panel)
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", Tokens.SPACE_SM)
	box.size_flags_vertical = Control.SIZE_EXPAND_FILL
	panel.add_child(box)
	box.add_child(_section_heading("stage_launch", "CAMPAIGN DIRECTIVES"))

	var grid := GridContainer.new()
	grid.columns = 2
	grid.add_theme_constant_override("h_separation", Tokens.SPACE_MD)
	grid.add_theme_constant_override("v_separation", Tokens.SPACE_SM)
	box.add_child(grid)
	_add_grid_label(grid, "ENGAGEMENTS")
	engagements_spin = SpinBox.new()
	engagements_spin.min_value = OperationsManager.MIN_ENGAGEMENTS
	engagements_spin.max_value = OperationsManager.MAX_ENGAGEMENTS
	engagements_spin.value = 5
	engagements_spin.custom_minimum_size = Vector2(170, Tokens.HIT_TARGET_MIN)
	engagements_spin.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	engagements_spin.tooltip_text = "Three to twelve battles, with a roster re-draft after each engagement."
	engagements_spin.value_changed.connect(_on_engagements_changed)
	grid.add_child(engagements_spin)

	_add_grid_label(grid, "FINAL AI TIER")
	difficulty_btn = OptionButton.new()
	for d in DIFFICULTY_LABELS:
		difficulty_btn.add_item(d)
	difficulty_btn.selected = 1
	difficulty_btn.custom_minimum_size = Vector2(170, Tokens.HIT_TARGET_MIN)
	difficulty_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	difficulty_btn.tooltip_text = "The operation ramps toward this tier. Opening engagements run easier so the roster has room to adapt."
	difficulty_btn.item_selected.connect(_on_difficulty_selected)
	UITheme.style_dropdown(difficulty_btn)
	grid.add_child(difficulty_btn)

	box.add_child(HSeparator.new())
	var ramp_title := Label.new()
	ramp_title.text = "THREAT RAMP // ROUTE READBACK"
	ramp_title.theme_type_variation = "HeadingLabel"
	box.add_child(ramp_title)
	var ramp_scroll := ScrollContainer.new()
	ramp_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	ramp_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	box.add_child(ramp_scroll)
	_route_summary = VBoxContainer.new()
	_route_summary.add_theme_constant_override("separation", Tokens.SPACE_XS)
	_route_summary.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	ramp_scroll.add_child(_route_summary)

	var readiness_panel := PanelContainer.new()
	readiness_panel.add_theme_stylebox_override("panel", UITheme.flat_style(
		Tokens.BASE_900, Tokens.BASE_600, Tokens.SPACE_SM, "flush"))
	_readiness = Label.new()
	_readiness.name = "OperationsReadiness"
	_readiness.theme_type_variation = "StatLabel"
	_readiness.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	readiness_panel.add_child(_readiness)
	box.add_child(readiness_panel)

	_begin_btn = StampedButtonScript.new()
	_begin_btn.name = "BeginOperation"
	_begin_btn.legend = "BEGIN OPERATION >"
	_begin_btn.variant = StampedButtonScript.Variant.PRIMARY
	_begin_btn.custom_minimum_size = Vector2(0, Tokens.HIT_TARGET_MIN + Tokens.SPACE_MD)
	_begin_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_begin_btn.pressed.connect(_on_start_operation_pressed)
	box.add_child(_begin_btn)

	var back_btn := StampedButtonScript.new()
	back_btn.legend = "< MAIN MENU"
	back_btn.variant = StampedButtonScript.Variant.GHOST
	back_btn.custom_minimum_size = Vector2(0, Tokens.HIT_TARGET_MIN)
	back_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	back_btn.pressed.connect(_return_to_menu)
	box.add_child(back_btn)
	UIFeedbackScript.wire(_begin_btn, "confirm")
	UIFeedbackScript.wire(back_btn)


func _command_panel(node_name: String, width: int) -> PanelContainer:
	var panel := PanelContainer.new()
	panel.name = node_name
	panel.custom_minimum_size.x = width
	panel.size_flags_vertical = Control.SIZE_EXPAND_FILL
	panel.add_theme_stylebox_override("panel", UITheme.flat_style(
		Tokens.BASE_800, Tokens.BASE_500, Tokens.SPACE_MD, "raised"))
	return panel


func _section_heading(icon_name: String, text: String) -> Control:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", Tokens.SPACE_SM)
	var icon = UITheme.chrome_rect(icon_name, Tokens.SPINE_ICON, Tokens.TEXT_PRIMARY)
	if icon != null:
		row.add_child(icon)
	var label := Label.new()
	label.text = text
	label.theme_type_variation = "HeadingLabel"
	label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	row.add_child(label)
	return row


func _add_grid_label(parent: Control, text: String) -> void:
	var label = Label.new()
	label.text = text
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	label.theme_type_variation = "StatLabel"
	parent.add_child(label)


func _on_engagements_changed(_value: float) -> void:
	_active_engagement = mini(_active_engagement, int(engagements_spin.value) - 1)
	_rebuild_itinerary()


func _on_difficulty_selected(_index: int) -> void:
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
		var card := PanelContainer.new()
		card.name = "Engagement%02d" % (i + 1)
		var selected := i == _active_engagement
		card.add_theme_stylebox_override("panel", UITheme.flat_style(
			Tokens.SIGNAL_HAZARD_DIM if selected else Tokens.BASE_900,
			Tokens.SIGNAL_HAZARD if selected else Tokens.BASE_600,
			Tokens.SPACE_XS, "flush", Tokens.BORDER_EMPHASIS if selected else Tokens.BORDER_HAIRLINE))
		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", Tokens.SPACE_SM)
		card.add_child(row)

		var index_btn := Button.new()
		index_btn.text = "E%02d" % (i + 1)
		index_btn.theme_type_variation = "TabButton"
		index_btn.toggle_mode = true
		index_btn.button_pressed = selected
		index_btn.custom_minimum_size = Vector2(54, Tokens.HIT_TARGET_MIN)
		index_btn.tooltip_text = "Bring engagement %d onto the reconnaissance display." % (i + 1)
		index_btn.pressed.connect(_select_engagement.bind(i))
		row.add_child(index_btn)

		var map_btn = OptionButton.new()
		map_btn.add_item(RANDOM_MAP_LABEL)
		for map_id in MAP_IDS:
			map_btn.add_item(MapCatalog.get_map_name(map_id))
		map_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		map_btn.custom_minimum_size.y = Tokens.HIT_TARGET_MIN
		UITheme.style_dropdown(map_btn)
		if i < previous.size():
			map_btn.selected = previous[i]
		else:
			# +1 for the Random entry occupying index 0.
			var default_idx: int = MAP_IDS.find(str(defaults[i].get("map_id", "")))
			map_btn.selected = default_idx + 1 if default_idx >= 0 else 0
		row.add_child(map_btn)
		_map_pickers.append(map_btn)
		map_btn.item_selected.connect(_on_itinerary_map_selected.bind(i))

		# The per-engagement tier, shown because the ramp is what makes the
		# difficulty dropdown mean something other than a flat setting.
		var tier_label = Label.new()
		tier_label.text = str(defaults[i].get("ai_difficulty", "normal")).to_upper()
		tier_label.theme_type_variation = "HintLabel"
		tier_label.custom_minimum_size.x = 58
		tier_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
		tier_label.add_theme_color_override("font_color",
			Tokens.SIGNAL_HAZARD if i == count - 1 else Tokens.TEXT_SECONDARY)
		row.add_child(tier_label)
		itinerary_list.add_child(card)

	UIFeedbackScript.wire_tree(itinerary_list, "select")
	_refresh_active_engagement()
	_refresh_route_summary()


func _select_engagement(index: int) -> void:
	_active_engagement = clampi(index, 0, maxi(_map_pickers.size() - 1, 0))
	_rebuild_itinerary()


func _on_itinerary_map_selected(_selection: int, engagement_index: int) -> void:
	_active_engagement = engagement_index
	_rebuild_itinerary()


func _selected_map_id(index: int) -> String:
	if index < 0 or index >= _map_pickers.size():
		return ""
	var selection: int = _map_pickers[index].selected
	if selection <= 0 or selection - 1 >= MAP_IDS.size():
		return ""
	return str(MAP_IDS[selection - 1])


func _refresh_active_engagement() -> void:
	if _theatre_title == null or _map_pickers.is_empty():
		return
	_active_engagement = clampi(_active_engagement, 0, _map_pickers.size() - 1)
	var map_id := _selected_map_id(_active_engagement)
	if map_id == "":
		_theatre_title.text = "E%02d // RANDOM SECTOR" % (_active_engagement + 1)
		_theatre_desc.text = "Sector intelligence remains sealed until Begin Operation resolves the route."
		if not MAP_IDS.is_empty() and _theatre_preview != null:
			var fallback_id := str(MAP_IDS[0])
			_theatre_preview.set_map(fallback_id, MapCatalog.get_map(fallback_id))
		return
	var map_def: Dictionary = MapCatalog.get_map(map_id)
	_theatre_title.text = "E%02d // %s" % [
		_active_engagement + 1, str(map_def.get("name", MapCatalog.get_map_name(map_id))).to_upper()]
	_theatre_desc.text = str(map_def.get("description", "No sector briefing available."))
	if _theatre_preview != null:
		_theatre_preview.set_map(map_id, map_def)


func _refresh_route_summary() -> void:
	if _route_summary == null or difficulty_btn == null or engagements_spin == null:
		return
	for child in _route_summary.get_children():
		child.queue_free()
	var count := int(engagements_spin.value)
	var base_difficulty: String = DIFFICULTIES[difficulty_btn.selected]
	for i in range(count):
		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", Tokens.SPACE_SM)
		var stage := Label.new()
		stage.text = "E%02d" % (i + 1)
		stage.theme_type_variation = "StatLabel"
		stage.custom_minimum_size.x = 38
		row.add_child(stage)
		var sector := Label.new()
		var map_id := _selected_map_id(i)
		sector.text = "RANDOM SECTOR" if map_id == "" else MapCatalog.get_map_name(map_id).to_upper()
		sector.theme_type_variation = "HintLabel"
		sector.clip_text = true
		sector.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		row.add_child(sector)
		var tier := Label.new()
		tier.text = OperationsManager.ramped_difficulty(i, count, base_difficulty).to_upper()
		tier.theme_type_variation = "StatLabel"
		tier.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
		tier.add_theme_color_override("font_color",
			Tokens.SIGNAL_HAZARD if i == count - 1 else Tokens.TEXT_SECONDARY)
		row.add_child(tier)
		_route_summary.add_child(row)
	_refresh_readiness()


func _on_roster_changed() -> void:
	_refresh_staging()
	_refresh_readiness()


func _refresh_staging() -> void:
	if _hero_view == null or roster_picker == null:
		return
	var paths: Array = roster_picker.ordered_paths()
	if paths.is_empty() and bp_manager != null:
		for entry in bp_manager.list_blueprints(true):
			var path := str(entry.get("path", ""))
			if path != "":
				paths.append(path)
			if paths.size() >= AUTOPICK_LIMIT:
				break
	_hero_view.update_squadron(paths)


func _refresh_readiness() -> void:
	if _readiness == null or roster_picker == null:
		return
	var assigned := roster_picker.filled_unit_count() + roster_picker.filled_defence_count()
	if assigned > 0:
		_readiness.text = "ROUTE READY // %d ENGAGEMENTS // %d FIELD-ASSIGNED DESIGN%s" % [
			int(engagements_spin.value), assigned, "S" if assigned != 1 else ""]
		_readiness.add_theme_color_override("font_color", Tokens.SIGNAL_GO)
	else:
		_readiness.text = "ROUTE READY // AUTO-DRAFT WILL FIELD STANDARD RESERVES"
		_readiness.add_theme_color_override("font_color", Tokens.SIGNAL_INFO)


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
