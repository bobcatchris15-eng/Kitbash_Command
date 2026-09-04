extends Control
# MATCH SETTINGS - the skirmish pre-game screen, rebuilt 2026-09-02 as a
# STAGED FLOW.
#
# WHAT THE PLAYER DOES HERE HAS NOT CHANGED, and deliberately so: pick the map,
# pick the roster, set three match options, go. The screen's OUTPUT is the same
# MatchRuleSet the old version wrote, field for field - see _on_start_pressed(),
# which is the old function with its arguments untouched. Everything that moved
# is presentation.
#
# WHY IT WAS REBUILT RATHER THAN RESTYLED. The old screen was a two-column
# dropdown grid with a 12-well roster crammed underneath it. Three specific
# failures, none of which a restyle could reach:
#
#   1. THE MAP WAS A DROPDOWN. data/maps/ ships a baked terrain texture per
#      map and the screen showed the player a NAME. The single biggest asset
#      already on disk was spent on a line of text.
#   2. EVERYTHING COMPETED FOR ONE SCREEN. Four selectors, three library
#      strips, sixteen wells and a paragraph of caption, all at once, so
#      nothing was the subject and the roster - the part that takes real
#      thought - got the least room.
#   3. THE ROSTER REQUIRED DRAGGING. Twelve press-move-release gestures to
#      express "field these twelve". Click-to-assign now carries it (see
#      roster_picker.gd's assign_to_next_free); drag remains for deliberate
#      placement.
#
# THE FLOW. Three stages, one screen each, with a persistent spine across the
# top saying where you are and what remains. Every stage is built ONCE and
# hidden rather than rebuilt, which is what makes going back free: the roster
# you filled, the map you chose and the options you set are the same nodes when
# you return to them. A stage is reachable when the stages before it have been
# confirmed, so LAUNCH cannot be pressed out of an unvisited flow.
#
# VISUAL REGISTER: flat instrument. Flat dark fills, 1 px edges, real grid
# discipline, depth from layout and elevation rather than from a generated
# texture - the same vocabulary the Design Lab now uses, so the two screens
# read as one system. Every colour, spacing, radius and opacity comes from
# ui_tokens.gd; the panel factory is UITheme.flat_style(); the chrome glyphs are
# authored monochrome SVGs in assets/ui/matchsetup/, tinted with modulate and
# degrading to text when absent (UITheme.chrome_rect returns null).

const BlueprintManagerScript = preload("res://scripts/blueprint_manager.gd")
const LiveryScript = preload("res://scripts/livery.gd")
const UITheme = preload("res://scripts/ui_theme.gd")
const Tokens = preload("res://scripts/ui_tokens.gd")
const MapCatalog = preload("res://scripts/map_catalog.gd")
const RosterPickerScript = preload("res://scripts/roster_picker.gd")
const UIFeedbackScript = preload("res://scripts/ui_feedback.gd")
const UIAnimScript = preload("res://scripts/ui_anim.gd")
const MatchRuleSetScript = preload("res://scripts/match_rule_set.gd")
const BlueprintThumbnailScript = preload("res://scripts/blueprint_thumbnail.gd")
const DesignCostingScript = preload("res://scripts/battle/economy/design_costing.gd")

# --- The match's own vocabulary. UNCHANGED from the pre-rebuild screen; these
# are what the rule set is written from and moving them would change the game
# rather than the screen. ---
#
# The premade factions are gone (faction_catalog.gd, deleted 2026-08-31): the
# player authors ONE livery of their own, it is a profile setting rather than a
# per-match choice, and it carries no mechanical bonus - so there is nothing
# left for this screen to ask. The opponent's livery is GENERATED PER MATCH
# (LiveryScript.new_ai_livery_id()); it used to be the fixed string "enemy",
# which hashed to one livery, so every AI army ever wore the same colours.
const DIFFICULTIES = ["easy", "normal", "hard"]
const DIFFICULTY_LABELS = ["Easy", "Normal", "Hard"]
# Starting credits; -1 means "use the match's own default" (Standard reproduces
# it exactly). The old (metal, crystal) pairs were converted at the 2x crystal
# rate: 250/75 -> 400, 900/400 -> 1700.
const RESOURCE_PRESETS = [-1, 400, 1700]
const RESOURCE_LABELS = ["Standard", "Low (tight economy)", "High (build fast, fight fast)"]
# None = MatchRuleSet.enable_ai false (no CommanderScript at all, which is also
# the A/B control for the per-frame hitch investigation); Standard = a regular
# skirmish.
const AI_OPPONENT_LABELS = ["None", "Standard"]
# Matches the director's own roster.slice(0, 12).
const ROSTER_CAP = 12
# How many designs the director auto-drafts when the roster is left empty
# (match_director.ROSTER_AUTOPICK_LIMIT). Mirrored rather than read: the
# director is not loaded at this point in the flow, and this screen needs the
# number to SHOW the player what auto-draft will do, not to perform it.
const AUTOPICK_LIMIT = 8

# --- Stage table. The flow is data: a stage is an entry here, and the spine,
# the host and the nav footer all iterate it. Adding a stage is a row. ---
const STAGES = [
	{"id": "map", "title": "THEATRE", "glyph": "stage_map",
		"caption": "Choose where the match is fought."},
	{"id": "roster", "title": "ROSTER", "glyph": "stage_roster",
		"caption": "Choose which of your designs deploy."},
	{"id": "launch", "title": "LAUNCH", "glyph": "stage_launch",
		"caption": "Confirm the engagement and deploy."},
]

var bp_manager: Node
var roster_picker: RosterPicker

# Selectors. Still OptionButtons, still routed through UITheme.style_dropdown()
# - the shared theme carries their plate and popup, and the house chevron is the
# one piece a StyleBox cannot express. They live on the LAUNCH stage now, beside
# the summary they modify, rather than above a roster they have nothing to do
# with.
var difficulty_btn: OptionButton
var resources_btn: OptionButton
var ai_btn: OptionButton

var MAP_IDS: Array = []
var _map_id: String = ""
var _stage: int = 0
var _unlocked: int = 0        # highest stage the flow has confirmed its way to

var _spine_chips: Array = []  # one Button per stage
var _stage_host: Control
var _stage_pages: Array = []  # one Control per stage, all alive, one visible
var _caption: Label

var _preview: MapPreview
var _map_title: Label
var _map_desc: Label
var _map_facts: VBoxContainer
var _map_tiles: Array = []

var _summary_map: Label
var _summary_rules: Label
var _summary_roster: PanelContainer
var _manifest_list: VBoxContainer
var _manifest_footer: Label
var _summary_note: Label
var _hero_view: SquadronHeroView = null

var _back_btn: Button
var _next_btn: Button
var _launch_btn: Button
var _readiness: Label
var _narrow_viewport: bool = false
var _spine_title: Label
var _map_side: VBoxContainer

# Console Mode (War Room Ops-Table)
var _ops_table_mode: bool = false
var _ops_table_page: Control = null
var _ops_mode_btn: Button = null
var _nav_bar: Control = null
var _stage_roster_host: Control = null
var _ops_roster_host: Control = null

var _ops_map_select: OptionButton = null
var _ops_preview: MapPreview = null
var _ops_map_title: Label = null
var _ops_map_desc: Label = null
var _ops_map_facts: VBoxContainer = null

var _ops_hero_view: SquadronHeroView = null
var _ops_difficulty_btn: OptionButton = null
var _ops_resources_btn: OptionButton = null
var _ops_ai_btn: OptionButton = null

var _ops_summary_map: Label = null
var _ops_summary_rules: Label = null
var _ops_manifest_list: VBoxContainer = null
var _ops_manifest_footer: Label = null
var _ops_summary_note: Label = null


func _ready() -> void:
	bp_manager = BlueprintManagerScript.new()
	add_child(bp_manager)

	# The screen's floor. A flat fill, not a material: this register gets its
	# depth from the value ladder between floor, panel and tile, and a generated
	# texture underneath a flat panel stack reads as two unrelated skins.
	var floor_rect := ColorRect.new()
	floor_rect.set_anchors_preset(Control.PRESET_FULL_RECT)
	floor_rect.color = Tokens.BASE_900
	add_child(floor_rect)

	var frame := MarginContainer.new()
	frame.set_anchors_preset(Control.PRESET_FULL_RECT)
	for side in ["margin_left", "margin_right", "margin_top", "margin_bottom"]:
		frame.add_theme_constant_override(side, Tokens.STAGE_PAD)
	add_child(frame)

	var column := VBoxContainer.new()
	column.add_theme_constant_override("separation", Tokens.SPACE_MD)
	frame.add_child(column)

	column.add_child(_build_spine())
	_caption = Label.new()
	_caption.theme_type_variation = "HintLabel"
	column.add_child(_caption)

	_stage_host = Control.new()
	_stage_host.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_stage_host.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	column.add_child(_stage_host)

	for content: Control in [_build_map_stage(), _build_roster_stage(), _build_launch_stage()]:
		# Keep the navigation fixed while dense content scrolls at short heights.
		var page := ScrollContainer.new()
		page.name = content.name
		content.name = "Content"
		page.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
		page.follow_focus = true
		page.set_anchors_preset(Control.PRESET_FULL_RECT)
		content.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		content.size_flags_vertical = Control.SIZE_EXPAND_FILL
		_stage_host.add_child(page)
		page.add_child(content)
		_stage_pages.append(page)

	_ops_table_page = _build_ops_table()
	_ops_table_page.set_anchors_preset(Control.PRESET_FULL_RECT)
	_ops_table_page.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_ops_table_page.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_ops_table_page.visible = false
	column.add_child(_ops_table_page)

	_nav_bar = _build_nav()
	column.add_child(_nav_bar)

	_sync_map_selection()
	_goto_stage(0, false)
	get_viewport().size_changed.connect(_on_viewport_size_changed)
	_on_viewport_size_changed()
	UIFeedbackScript.wire_tree(self)
	(_spine_chips[0] as Button).grab_focus.call_deferred()


# ---------------------------------------------------------------------------
# THE PROGRESS SPINE
# ---------------------------------------------------------------------------
# Persistent, always visible, and clickable: it is the navigation, not a
# decoration of it. A chip shows one of three states - DONE (behind you),
# CURRENT (amber), PENDING (dim and not yet reachable) - and jumping back to a
# done stage keeps every choice, because the page is the same node.
#
# The connector rule between chips is drawn as a real element rather than
# implied by spacing, so the three read as one instrument rather than three
# buttons that happen to be in a row.
func _build_spine() -> Control:
	var band := PanelContainer.new()
	band.add_theme_stylebox_override("panel", UITheme.flat_style(
		Tokens.BASE_800, Tokens.BASE_500, Tokens.SPACE_MD, "raised"))
	band.custom_minimum_size = Vector2(0, Tokens.SPINE_HEIGHT)

	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", Tokens.SPACE_SM)
	band.add_child(row)

	var title := Label.new()
	_spine_title = title
	title.text = "MATCH SETTINGS"
	title.theme_type_variation = "TitleLabel"
	title.custom_minimum_size = Vector2(Tokens.SUMMARY_COL_MIN, 0)
	row.add_child(title)

	for i in range(STAGES.size()):
		if i > 0:
			var rule := Panel.new()
			rule.custom_minimum_size = Vector2(Tokens.SPACE_XL, Tokens.SPINE_RULE)
			rule.size_flags_vertical = Control.SIZE_SHRINK_CENTER
			rule.add_theme_stylebox_override("panel", UITheme.flat_style(
				Tokens.BASE_500, Tokens.BASE_500, 0, "flush", 0))
			row.add_child(rule)
		row.add_child(_build_chip(i))

	var mode_spacer := Control.new()
	mode_spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(mode_spacer)

	var mode_rule := Panel.new()
	mode_rule.custom_minimum_size = Vector2(Tokens.SPACE_MD, Tokens.SPINE_RULE)
	mode_rule.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	mode_rule.add_theme_stylebox_override("panel", UITheme.flat_style(
		Tokens.BASE_500, Tokens.BASE_500, 0, "flush", 0))
	row.add_child(mode_rule)

	_ops_mode_btn = Button.new()
	_ops_mode_btn.theme_type_variation = "TabButton"
	_ops_mode_btn.custom_minimum_size = Vector2(240, Tokens.HIT_TARGET_MIN + Tokens.SPACE_SM)
	_ops_mode_btn.focus_mode = Control.FOCUS_ALL
	_ops_mode_btn.toggle_mode = true
	_ops_mode_btn.text = "[MODE: WAR ROOM OPS-TABLE]"
	_ops_mode_btn.pressed.connect(_toggle_console_mode)
	UIFeedbackScript.wire(_ops_mode_btn, "select")
	row.add_child(_ops_mode_btn)
	return band


func _build_chip(idx: int) -> Button:
	var stage: Dictionary = STAGES[idx]
	var chip := Button.new()
	chip.theme_type_variation = "TabButton"
	chip.custom_minimum_size = Vector2(0, Tokens.HIT_TARGET_MIN + Tokens.SPACE_SM)
	chip.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	chip.focus_mode = Control.FOCUS_ALL
	chip.clip_text = true
	# toggle_mode so TabButton's pressed plate can express "this is the stage
	# you are on" - the variation inverts the bevel for the active tab.
	chip.toggle_mode = true
	# Glyph then text. The glyph is authored chrome; when the asset is missing
	# chrome_rect returns null and the chip is text-only - a renamed file costs
	# a picture, never the screen.
	var box := HBoxContainer.new()
	box.add_theme_constant_override("separation", Tokens.SPACE_SM)
	box.alignment = BoxContainer.ALIGNMENT_CENTER
	box.set_anchors_preset(Control.PRESET_FULL_RECT)
	box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	chip.add_child(box)

	var glyph := UITheme.chrome_rect(str(stage["glyph"]), Tokens.SPINE_ICON)
	if glyph != null:
		glyph.name = "Glyph"
		box.add_child(glyph)

	var label := Label.new()
	label.name = "Legend"
	label.theme_type_variation = "HeadingLabel"
	label.text = "%d  %s" % [idx + 1, str(stage["title"])]
	box.add_child(label)
	chip.custom_minimum_size.x = box.get_combined_minimum_size().x + Tokens.SPACE_MD * 2

	chip.pressed.connect(_on_chip_pressed.bind(idx))
	UIFeedbackScript.wire(chip, "select")
	_spine_chips.append(chip)
	return chip


func _on_chip_pressed(idx: int) -> void:
	if _ops_table_mode:
		set_console_mode(false)
	# Backwards always; forwards only into a stage the flow has already
	# confirmed. That is the whole gate on LAUNCH - it cannot be reached out of
	# an unvisited flow, and it needs no separate validity rule to say so.
	if idx <= _unlocked:
		_goto_stage(idx)
	else:
		UIAnimScript.shake(_spine_chips[idx])
		UIFeedbackScript.play(_spine_chips[idx], "reject")


func _goto_stage(idx: int, animate: bool = true) -> void:
	var previous_stage := _stage
	if _ops_table_mode:
		set_console_mode(false)
	_stage = clampi(idx, 0, STAGES.size() - 1)
	_unlocked = maxi(_unlocked, _stage)
	for i in range(_stage_pages.size()):
		_stage_pages[i].visible = i == _stage
	if animate:
		# From the right on the way forward, from the left on the way back, so
		# the motion agrees with the spine's direction of travel.
		UIAnimScript.slide_in(_stage_pages[_stage], Tokens.STAGE_TRANSITION_OFFSET * (1 if _stage >= previous_stage else -1))
	_caption.text = str(STAGES[_stage]["caption"])
	_refresh_spine()
	_refresh_nav()
	if _stage == STAGES.size() - 1:
		_refresh_summary()
	_refresh_readiness()


func _toggle_console_mode() -> void:
	set_console_mode(not _ops_table_mode)


func set_console_mode(enabled: bool) -> void:
	if enabled and _narrow_viewport:
		UIFeedbackScript.play(_ops_mode_btn, "reject")
		return
	_ops_table_mode = enabled
	if _stage_host != null:
		_stage_host.visible = not _ops_table_mode
	if _ops_table_page != null:
		_ops_table_page.visible = _ops_table_mode
	if _nav_bar != null:
		_nav_bar.visible = not _ops_table_mode

	_sync_roster_parent()
	_refresh_spine()

	if _ops_table_mode:
		_caption.text = "WAR ROOM OPS-TABLE — High-density command deck: theatre recon, squadron turntable, roster wells & directives."
		_refresh_map_facts()
		_refresh_summary()
	else:
		_caption.text = str(STAGES[_stage]["caption"])
		_refresh_nav()
	_refresh_readiness()


func _sync_roster_parent() -> void:
	if roster_picker == null:
		return
	var target_parent: Control = _ops_roster_host if _ops_table_mode else _stage_roster_host
	if target_parent != null and roster_picker.get_parent() != target_parent:
		roster_picker.reparent(target_parent)
		roster_picker.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		roster_picker.size_flags_vertical = Control.SIZE_EXPAND_FILL


func _refresh_spine() -> void:
	for i in range(_spine_chips.size()):
		var chip: Button = _spine_chips[i]
		var legend: Label = chip.get_node_or_null("HBoxContainer/Legend")
		if legend == null:
			for child in chip.get_children():
				legend = child.get_node_or_null("Legend")
				if legend != null:
					break
		var col: Color = Tokens.TEXT_DISABLED
		if not _ops_table_mode and i == _stage:
			col = Tokens.SIGNAL_HAZARD
		elif not _ops_table_mode and i < _stage:
			col = Tokens.SIGNAL_GO
		elif i <= _unlocked:
			col = Tokens.TEXT_SECONDARY
		if legend != null:
			legend.add_theme_color_override("font_color", col)
		chip.button_pressed = (i == _stage and not _ops_table_mode)
		chip.disabled = (i > _unlocked)
		# A completed stage swaps its glyph tint to GO rather than swapping the
		# glyph itself, except for the tick, which is the one place a different
		# mark says something the colour cannot.
		var glyph: TextureRect = null
		for child in chip.get_children():
			glyph = child.get_node_or_null("Glyph")
			if glyph != null:
				break
		if glyph != null:
			glyph.modulate = col
			if not _ops_table_mode and i < _stage:
				var done := UITheme.chrome_icon("stage_done")
				if done != null:
					glyph.texture = done
			else:
				var own := UITheme.chrome_icon(str(STAGES[i]["glyph"]))
				if own != null:
					glyph.texture = own

	if _ops_mode_btn != null:
		_ops_mode_btn.button_pressed = _ops_table_mode
		if _ops_table_mode:
			_ops_mode_btn.add_theme_color_override("font_color", Tokens.SIGNAL_HAZARD)
		else:
			_ops_mode_btn.remove_theme_color_override("font_color")


# ---------------------------------------------------------------------------
# NAV FOOTER
# ---------------------------------------------------------------------------
func _build_nav() -> Control:
	var band := PanelContainer.new()
	band.add_theme_stylebox_override("panel", UITheme.flat_style(
		Tokens.BASE_800, Tokens.BASE_500, Tokens.SPACE_SM, "raised"))
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", Tokens.SPACE_MD)
	band.add_child(row)

	_back_btn = _nav_button("BACK", "nav_prev", false)
	_back_btn.pressed.connect(_on_back_pressed)
	row.add_child(_back_btn)

	var spacer := Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(spacer)

	_next_btn = _nav_button("NEXT", "nav_next", true)
	_next_btn.pressed.connect(_on_next_pressed)
	row.add_child(_next_btn)

	# The one PRIMARY on the screen, and the one commit point. Only visible on
	# the LAUNCH stage; the style guide allows at most one primary and "this is
	# the match you are about to fight" is unambiguously it.
	_launch_btn = Button.new()
	_launch_btn.text = "DEPLOY"
	_launch_btn.theme_type_variation = "PrimaryButton"
	_launch_btn.custom_minimum_size = Tokens.NAV_BUTTON_MIN
	_launch_btn.pressed.connect(_on_start_pressed)
	row.add_child(_launch_btn)

	_readiness = Label.new()
	_readiness.name = "MatchSetupReadiness"
	_readiness.theme_type_variation = "HintLabel"
	_readiness.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_readiness.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_readiness.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_readiness.mouse_filter = Control.MOUSE_FILTER_IGNORE
	row.add_child(_readiness)

	UIFeedbackScript.wire(_back_btn)
	UIFeedbackScript.wire(_next_btn, "select")
	UIFeedbackScript.wire(_launch_btn, "confirm")
	return band


func _nav_button(text: String, glyph: String, trailing: bool) -> Button:
	var btn := Button.new()
	btn.custom_minimum_size = Tokens.NAV_BUTTON_MIN
	btn.focus_mode = Control.FOCUS_ALL
	var icon := UITheme.chrome_icon(glyph)
	if icon != null:
		btn.icon = icon
		btn.expand_icon = true
		btn.add_theme_constant_override("icon_max_width", Tokens.SPINE_ICON)
		btn.add_theme_constant_override("h_separation", Tokens.SPACE_SM)
		# Godot draws a Button's icon on the leading edge only, so a trailing
		# chevron is expressed by mirroring the whole control rather than by a
		# second icon slot that does not exist.
		if trailing:
			btn.icon_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	btn.text = text
	return btn


func _refresh_nav() -> void:
	var last: bool = _stage == STAGES.size() - 1
	_next_btn.visible = not last
	_launch_btn.visible = last
	_back_btn.text = "MAIN MENU" if _stage == 0 else "BACK"
	_refresh_readiness()


func _refresh_readiness() -> void:
	if _readiness == null:
		return
	if _stage < STAGES.size() - 1:
		_readiness.text = "STEP %d OF %d — %s" % [_stage + 1, STAGES.size(), str(STAGES[_stage]["caption"])]
		_readiness.add_theme_color_override("font_color", Tokens.TEXT_SECONDARY)
		return
	var manual_count := roster_picker.filled_unit_count() + roster_picker.filled_defence_count() if roster_picker else 0
	var has_auto_draft: bool = bp_manager != null and not bp_manager.list_blueprints(true).is_empty()
	_launch_btn.disabled = manual_count == 0 and not has_auto_draft
	_launch_btn.tooltip_text = "Save a blueprint in the Design Lab before deploying." if _launch_btn.disabled else "Deploy the reviewed roster"
	if manual_count > 0:
		_readiness.text = "READY — %d DESIGN%s FIELD ASSIGNED" % [manual_count, "S" if manual_count != 1 else ""]
		_readiness.add_theme_color_override("font_color", Tokens.SIGNAL_GO)
	elif has_auto_draft:
		_readiness.text = "READY — AUTO-DRAFT WILL FIELD STANDARD RESERVES"
		_readiness.add_theme_color_override("font_color", Tokens.SIGNAL_INFO)
	else:
		_readiness.text = "BLOCKED — SAVE A BLUEPRINT OR RETURN TO THE DESIGN LAB"
		_readiness.add_theme_color_override("font_color", Tokens.SIGNAL_HAZARD)


func _on_viewport_size_changed() -> void:
	var width := get_viewport_rect().size.x
	_narrow_viewport = width <= Tokens.NARROW_VIEWPORT_WIDTH
	var compact := width <= Tokens.COMPACT_VIEWPORT_WIDTH
	if _ops_mode_btn != null:
		_ops_mode_btn.visible = not compact
	if compact and _ops_table_mode:
		set_console_mode(false)
	if _spine_title:
		_spine_title.custom_minimum_size.x = 200 if compact else Tokens.SUMMARY_COL_MIN
	if _preview:
		_preview.custom_minimum_size = Vector2(240 if compact else Tokens.MAP_PREVIEW_MIN.x, 300 if compact else Tokens.MAP_PREVIEW_MIN.y)
	if _map_side:
		_map_side.custom_minimum_size.x = 260 if compact else Tokens.SUMMARY_COL_MIN


func is_narrow_viewport() -> bool:
	return _narrow_viewport


func _on_back_pressed() -> void:
	if _stage == 0:
		_return_to_menu()
	else:
		_goto_stage(_stage - 1)


func _on_next_pressed() -> void:
	_goto_stage(_stage + 1)


# ---------------------------------------------------------------------------
# STAGE 1 - THEATRE
# ---------------------------------------------------------------------------
# The map is SHOWN, not named. Left: a rail of every map in the catalogue, each
# its own baked terrain texture. Centre: the selection at size, with a schematic
# overlay of the things that decide a match - spawns, deposits, water, cover.
# Right: that map's own metadata.
#
# No dropdown survives here. MapCatalog is still the source, so a new file in
# data/maps/ appears with no code change - discovery over declaration, the same
# as the hull roster.
func _build_map_stage() -> Control:
	var page := HBoxContainer.new()
	page.name = "StageTheatre"
	page.add_theme_constant_override("separation", Tokens.SPACE_MD)

	MAP_IDS = MapCatalog.get_map_ids()

	var rail_wrap := PanelContainer.new()
	rail_wrap.add_theme_stylebox_override("panel", UITheme.flat_style(
		Color("#141713"), Tokens.BASE_500, Tokens.SPACE_SM, "flush"))
	rail_wrap.custom_minimum_size = Vector2(Tokens.MAP_TILE_MIN.x + Tokens.SPACE_XL, 0)
	page.add_child(rail_wrap)

	var scroll := ScrollContainer.new()
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	rail_wrap.add_child(scroll)
	var rail := VBoxContainer.new()
	rail.add_theme_constant_override("separation", Tokens.SPACE_SM)
	rail.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(rail)

	var rail_header := HBoxContainer.new()
	rail_header.add_theme_constant_override("separation", Tokens.SPACE_SM)
	rail.add_child(rail_header)
	
	var sort_btn := OptionButton.new()
	sort_btn.add_item("Name")
	sort_btn.add_item("Size")
	sort_btn.item_selected.connect(_on_sort_selected)
	rail_header.add_child(sort_btn)
	
	for map_id in MAP_IDS:
		var tile := MapTile.new()
		tile.configure(str(map_id), self)
		rail.add_child(tile)
		_map_tiles.append(tile)

	_preview = MapPreview.new()
	_preview.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_preview.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_preview.custom_minimum_size = Tokens.MAP_PREVIEW_MIN
	page.add_child(_preview)
	var side := VBoxContainer.new()
	_map_side = side
	side.custom_minimum_size = Vector2(Tokens.SUMMARY_COL_MIN, 0)
	side.add_theme_constant_override("separation", Tokens.SPACE_MD)
	page.add_child(side)

	var facts_panel := PanelContainer.new()
	facts_panel.add_theme_stylebox_override("panel", UITheme.flat_style(
		Tokens.BASE_800, Tokens.BASE_500, Tokens.SPACE_MD, "raised"))
	var facts_box := VBoxContainer.new()
	facts_box.add_theme_constant_override("separation", Tokens.SPACE_SM)
	facts_panel.add_child(facts_box)

	var facts_hdr := HBoxContainer.new()
	facts_hdr.add_theme_constant_override("separation", Tokens.SPACE_SM)
	var facts_icon = UITheme.chrome_rect("stage_theatre", Tokens.SPINE_ICON, Tokens.TEXT_PRIMARY)
	if facts_icon:
		facts_hdr.add_child(facts_icon)
	_map_title = Label.new()
	_map_title.theme_type_variation = "HeadingLabel"
	_map_title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_map_title.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	facts_hdr.add_child(_map_title)
	facts_box.add_child(facts_hdr)

	_map_desc = Label.new()
	_map_desc.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_map_desc.theme_type_variation = "HintLabel"
	facts_box.add_child(_map_desc)

	facts_box.add_child(HSeparator.new())

	_map_facts = VBoxContainer.new()
	_map_facts.add_theme_constant_override("separation", Tokens.SPACE_XS)
	facts_box.add_child(_map_facts)

	side.add_child(facts_panel)
	side.add_child(_build_legend())
	return page


# The schematic's key. Without it the overlay is four colours of dot; with it
# the preview is readable at a glance, which is the whole reason the stage
# exists.
func _build_legend() -> Control:
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", Tokens.SPACE_XS)
	var heading := Label.new()
	heading.text = "TOPOGRAPHIC RECONNAISSANCE"
	heading.theme_type_variation = "HeadingLabel"
	box.add_child(heading)

	var sub := Label.new()
	sub.text = "SERIES 1:25,000 · 7.5 MINUTE QUADRANGLE"
	sub.theme_type_variation = "StatLabel"
	box.add_child(sub)
	var rows := [
		["pin_spawn", Tokens.MAP_SPAWN_PLAYER, "Your deployment zone"],
		["pin_spawn", Tokens.MAP_SPAWN_ENEMY, "Hostile deployment zone"],
		["pin_resource", Tokens.MAP_RESOURCE, "Resource deposit"],
		["", Tokens.MAP_WATER, "Water"],
		["", Tokens.MAP_OBSTACLE, "Cover and obstruction"],
		["", Tokens.MAP_USGS_CONTOUR_INDEX, "Index contour"],
		["", Tokens.MAP_USGS_CONTOUR_INTER, "Intermediate contour"],
	]
	for row_def in rows:
		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", Tokens.SPACE_SM)
		var swatch: Control = null
		if str(row_def[0]) != "":
			swatch = UITheme.chrome_rect(str(row_def[0]), Tokens.SPINE_ICON, row_def[1])
		if swatch == null:
			var chip := Panel.new()
			chip.custom_minimum_size = Vector2(Tokens.SPINE_ICON, Tokens.SPINE_ICON)
			chip.add_theme_stylebox_override("panel", UITheme.flat_style(
				row_def[1], row_def[1], 0, "flush", 0))
			swatch = chip
		row.add_child(swatch)
		var label := Label.new()
		label.text = str(row_def[2])
		label.theme_type_variation = "HintLabel"
		row.add_child(label)
		box.add_child(row)
	return box


# Called by a MapTile. Writes straight through to MatchConfig, exactly as the
# old dropdown handler did, so the choice survives backing out to the menu.
func select_map(map_id: String) -> void:
	if map_id == "" or not MAP_IDS.has(map_id):
		return
	_map_id = map_id
	var match_config = get_node_or_null("/root/MatchConfig")
	if match_config:
		match_config.selected_map_id = map_id
	for tile in _map_tiles:
		tile.set_selected(tile.map_id == map_id)
	if _ops_map_select != null:
		var midx := MAP_IDS.find(map_id)
		if midx >= 0 and _ops_map_select.selected != midx:
			_ops_map_select.selected = midx
	_refresh_map_facts()
	if _stage == STAGES.size() - 1 or _ops_table_mode:
		_refresh_summary()


func _refresh_map_facts() -> void:
	var map_def: Dictionary = MapCatalog.get_map(_map_id)
	if _preview:
		_preview.set_map(_map_id, map_def)
	if _ops_preview:
		_ops_preview.set_map(_map_id, map_def)
	if _map_title:
		_map_title.text = str(map_def.get("name", MapCatalog.get_map_name(_map_id)))
	if _ops_map_title:
		_ops_map_title.text = str(map_def.get("name", MapCatalog.get_map_name(_map_id)))
	if _map_desc:
		_map_desc.text = str(map_def.get("description", ""))
	if _ops_map_desc:
		_ops_map_desc.text = str(map_def.get("description", ""))

	var target_boxes: Array[VBoxContainer] = []
	if _map_facts != null:
		target_boxes.append(_map_facts)
	if _ops_map_facts != null:
		target_boxes.append(_ops_map_facts)

	if target_boxes.is_empty():
		return

	for box in target_boxes:
		for child in box.get_children():
			child.queue_free()
		
	var he: Vector2 = MapCatalog.half_extents(map_def)
	var deposits: Dictionary = {}
	for node_def in map_def.get("resource_nodes", []):
		var kind := str(node_def.get("type", "ore"))
		deposits[kind] = int(deposits.get(kind, 0)) + 1
	var spawns: Array = map_def.get("spawns", [])
	var waters: Array = map_def.get("water_areas", [])
	var covers: Array = map_def.get("obstacles", [])

	# Compute accurate elevation stats
	var min_elev: float = 0.0
	var max_elev: float = 0.0
	var terrain = map_def.get("terrain", {})
	if terrain is Dictionary:
		var sg = terrain.get("sculpt_grid", {})
		if sg is Dictionary and sg.has("data") and not sg["data"].is_empty():
			min_elev = 9999.0
			max_elev = -9999.0
			for val in sg["data"]:
				var fv = float(val)
				min_elev = minf(min_elev, fv)
				max_elev = maxf(max_elev, fv)
		elif terrain.has("height_scale"):
			var hs = float(terrain.get("height_scale", 20.0))
			min_elev = -hs * 0.5
			max_elev = hs
		elif terrain.has("features"):
			for f in terrain["features"]:
				var fh = float(f.get("height", 0.0))
				min_elev = minf(min_elev, fh)
				max_elev = maxf(max_elev, fh)

	var relief: float = maxf(0.0, max_elev - min_elev)
	var ci: float = 5.0
	if relief < 15.0:
		ci = 2.0
	elif relief < 40.0:
		ci = 5.0
	elif relief < 100.0:
		ci = 10.0
	else:
		ci = 20.0

	var facts := [
		["FIELD", "%d x %d m" % [int(he.x * 2.0), int(he.y * 2.0)]],
		["ELEVATION", "%.0f to %.0f m" % [min_elev, max_elev]],
		["RELIEF", "%.0f m" % relief],
		["CONTOUR INT", "%.0f m" % ci],
		["SPAWNS", str(spawns.size())],
		["WATER", str(waters.size())],
		["COVER", str(covers.size())],
	]
	for kind in deposits.keys():
		facts.append([str(kind).to_upper(), str(deposits[kind])])

	for fact in facts:
		for box in target_boxes:
			var row := HBoxContainer.new()
			var key := Label.new()
			key.text = str(fact[0])
			key.theme_type_variation = "StatLabel"
			key.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			row.add_child(key)
			var val := Label.new()
			val.text = str(fact[1])
			val.theme_type_variation = "HUDValueLabel"
			row.add_child(val)
			box.add_child(row)


func _sync_map_selection() -> void:
	var match_config = get_node_or_null("/root/MatchConfig")
	var current: String = ""
	if match_config and "selected_map_id" in match_config:
		current = str(match_config.selected_map_id)
	if not MAP_IDS.has(current):
		current = MapCatalog.DEFAULT_MAP_ID if MAP_IDS.has(MapCatalog.DEFAULT_MAP_ID) \
			else (str(MAP_IDS[0]) if not MAP_IDS.is_empty() else "")
	select_map(current)


# ---------------------------------------------------------------------------
# STAGE 2 - ROSTER
# ---------------------------------------------------------------------------
# The whole screen, which is the point: this is the stage that takes thought.
# named_only, because this is the "what goes into the match" list - unnamed
# leftovers from testing stay in the Blueprint Library.
func _build_roster_stage() -> Control:
	var page := VBoxContainer.new()
	page.name = "StageRoster"
	page.add_theme_constant_override("separation", Tokens.SPACE_SM)

	_stage_roster_host = VBoxContainer.new()
	_stage_roster_host.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_stage_roster_host.size_flags_vertical = Control.SIZE_EXPAND_FILL
	page.add_child(_stage_roster_host)

	var entries: Array = bp_manager.list_blueprints(true)

	roster_picker = RosterPickerScript.new()
	roster_picker.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	roster_picker.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_stage_roster_host.add_child(roster_picker)
	roster_picker.setup(entries, ROSTER_CAP)
	roster_picker.roster_changed.connect(_on_roster_changed)

	# AUTO-DRAFT, SURFACED. The old screen ended a paragraph with "leave the
	# roster empty to auto-include your newest designs", which told the player
	# neither which designs nor whether it was still in effect. The picker now
	# shows the actual names while the roster is empty and drops the placard the
	# moment one is fielded. The list is the same walk the director makes -
	# the first AUTOPICK_LIMIT of this same library listing.
	var auto_names: Array = []
	for entry in entries:
		if auto_names.size() >= AUTOPICK_LIMIT:
			break
		auto_names.append(str(entry.get("name", "Untitled")))
	roster_picker.set_auto_draft(auto_names)
	return page


func _on_roster_changed() -> void:
	if _stage == STAGES.size() - 1 or _ops_table_mode:
		_refresh_summary()
	_refresh_readiness()


# ---------------------------------------------------------------------------
# STAGE 3 - LAUNCH
# ---------------------------------------------------------------------------
# Confirm, do not hope. The three match options sit beside a written-out
# summary of the map, the rules and the exact roster that will be fielded, so
# the player reads the match they are about to start instead of trusting that
# the previous two stages took.
func _build_launch_stage() -> Control:
	var page := HBoxContainer.new()
	page.name = "StageLaunch"
	page.add_theme_constant_override("separation", Tokens.SPACE_MD)

	# Left column holds Rules and Deployment Manifest stacked vertically
	# so Rules does not waste 80% vertical dead space.
	var left_col := VBoxContainer.new()
	left_col.add_theme_constant_override("separation", Tokens.SPACE_MD)
	left_col.custom_minimum_size = Vector2(Tokens.SUMMARY_COL_MIN + Tokens.SPACE_XL + 120, 0)
	left_col.size_flags_vertical = Control.SIZE_EXPAND_FILL
	page.add_child(left_col)

	var rules_wrap := PanelContainer.new()
	rules_wrap.add_theme_stylebox_override("panel", UITheme.flat_style(
		Tokens.BASE_800, Tokens.BASE_500, Tokens.SPACE_MD, "raised"))
	rules_wrap.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	rules_wrap.size_flags_vertical = Control.SIZE_SHRINK_BEGIN
	left_col.add_child(rules_wrap)

	var rules := VBoxContainer.new()
	rules.add_theme_constant_override("separation", Tokens.SPACE_SM)
	rules_wrap.add_child(rules)

	var rules_heading := Label.new()
	rules_heading.text = "ENGAGEMENT RULES"
	rules_heading.theme_type_variation = "HeadingLabel"
	rules.add_child(rules_heading)

	var grid := GridContainer.new()
	grid.columns = 2
	grid.add_theme_constant_override("h_separation", Tokens.SPACE_MD)
	grid.add_theme_constant_override("v_separation", Tokens.SPACE_SM)
	rules.add_child(grid)

	difficulty_btn = _add_dropdown(grid, "AI Difficulty", DIFFICULTY_LABELS)
	difficulty_btn.selected = 1
	# Real, not cosmetic (enemy_ai.gd's DIFFICULTY_TIMER_MULT/PITY_MULT).
	difficulty_btn.tooltip_text = "Changes how fast the AI builds/attacks and how quickly it recovers from a bad economy. Doesn't change unit stats - just AI pacing."
	difficulty_btn.set_item_tooltip(0, "AI builds and attacks more slowly, and struggles longer if its economy falls behind.")
	difficulty_btn.set_item_tooltip(1, "Balanced AI pacing.")
	difficulty_btn.set_item_tooltip(2, "AI builds and attacks faster, and recovers quickly from economic setbacks.")

	resources_btn = _add_dropdown(grid, "Starting Resources", RESOURCE_LABELS)
	# Standard by default, so a player who never opens it gets the match the
	# screen got before the control existed.
	resources_btn.selected = 0

	ai_btn = _add_dropdown(grid, "AI Opponent", AI_OPPONENT_LABELS)
	ai_btn.selected = 1
	ai_btn.tooltip_text = "Whether the AI commander runs in this match. None plays the map solo with no opposing force; Standard is a regular Skirmish."
	ai_btn.set_item_tooltip(0, "No AI commander. Plays the map solo; useful for testing designs on a live map, and for isolating whether the AI is the cause of a per-frame cost.")
	ai_btn.set_item_tooltip(1, "AI commander runs (Skirmish default).")

	for btn in [difficulty_btn, resources_btn, ai_btn]:
		btn.item_selected.connect(_on_rule_changed)
	UIFeedbackScript.wire_tree(grid, "select")

	var summary_wrap := PanelContainer.new()
	summary_wrap.add_theme_stylebox_override("panel", UITheme.flat_style(
		Tokens.BASE_800, Tokens.BASE_500, Tokens.SPACE_MD, "raised"))
	summary_wrap.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	summary_wrap.size_flags_vertical = Control.SIZE_EXPAND_FILL
	left_col.add_child(summary_wrap)

	var summary := VBoxContainer.new()
	summary.add_theme_constant_override("separation", Tokens.SPACE_SM)
	summary.size_flags_vertical = Control.SIZE_EXPAND_FILL
	summary_wrap.add_child(summary)

	var summary_heading := Label.new()
	summary_heading.text = "ECHELON DEPLOYMENT MANIFEST"
	summary_heading.theme_type_variation = "HeadingLabel"
	summary.add_child(summary_heading)

	var meta_row := HBoxContainer.new()
	meta_row.add_theme_constant_override("separation", Tokens.SPACE_LG)
	summary.add_child(meta_row)

	var map_col := VBoxContainer.new()
	map_col.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_summary_map = _summary_line(map_col, "THEATRE")
	meta_row.add_child(map_col)

	var rules_col := VBoxContainer.new()
	rules_col.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_summary_rules = _summary_line(rules_col, "PARAMETERS")
	meta_row.add_child(rules_col)

	# Manifest table container
	_summary_roster = PanelContainer.new()
	_summary_roster.add_theme_stylebox_override("panel", UITheme.flat_style(
		Tokens.BASE_900, Tokens.BASE_600, Tokens.SPACE_SM, "recessed"))
	_summary_roster.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_summary_roster.size_flags_vertical = Control.SIZE_EXPAND_FILL
	summary.add_child(_summary_roster)

	var manifest_box := VBoxContainer.new()
	manifest_box.add_theme_constant_override("separation", Tokens.SPACE_XS)
	manifest_box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	manifest_box.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_summary_roster.add_child(manifest_box)

	# Column headers
	var col_hdr := HBoxContainer.new()
	col_hdr.add_theme_constant_override("separation", Tokens.SPACE_SM)
	var h_role := Label.new()
	h_role.text = "ROLE"
	h_role.custom_minimum_size = Vector2(48, 0)
	h_role.theme_type_variation = "StatLabel"
	h_role.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	col_hdr.add_child(h_role)

	var h_name := Label.new()
	h_name.text = "DESIGN NAME"
	h_name.theme_type_variation = "StatLabel"
	h_name.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	col_hdr.add_child(h_name)

	var h_cls := Label.new()
	h_cls.text = "CLASS / ARMOR"
	h_cls.custom_minimum_size = Vector2(110, 0)
	h_cls.theme_type_variation = "StatLabel"
	h_cls.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	col_hdr.add_child(h_cls)

	var h_cost := Label.new()
	h_cost.text = "COST"
	h_cost.custom_minimum_size = Vector2(90, 0)
	h_cost.theme_type_variation = "StatLabel"
	h_cost.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	col_hdr.add_child(h_cost)
	manifest_box.add_child(col_hdr)

	# Scrollable list of units
	var scroll := ScrollContainer.new()
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	manifest_box.add_child(scroll)

	_manifest_list = VBoxContainer.new()
	_manifest_list.add_theme_constant_override("separation", Tokens.SPACE_XS)
	_manifest_list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(_manifest_list)

	# Total deployment cost footer
	var footer_panel := PanelContainer.new()
	footer_panel.add_theme_stylebox_override("panel", UITheme.flat_style(
		Tokens.BASE_800, Tokens.BASE_500, Tokens.SPACE_XS, "flush"))
	manifest_box.add_child(footer_panel)

	_manifest_footer = Label.new()
	_manifest_footer.theme_type_variation = "HUDValueLabel"
	_manifest_footer.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	_manifest_footer.add_theme_color_override("font_color", Tokens.SIGNAL_HAZARD)
	footer_panel.add_child(_manifest_footer)

	_summary_note = Label.new()
	_summary_note.theme_type_variation = "HintLabel"
	_summary_note.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	summary.add_child(_summary_note)

	_hero_view = SquadronHeroView.new()
	_hero_view.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_hero_view.size_flags_vertical = Control.SIZE_EXPAND_FILL
	page.add_child(_hero_view)
	return page


func _summary_line(parent: Control, heading_text: String) -> Label:
	var heading := Label.new()
	heading.text = heading_text
	heading.theme_type_variation = "StatLabel"
	parent.add_child(heading)
	var body := Label.new()
	body.theme_type_variation = "HUDValueLabel"
	body.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	parent.add_child(body)
	return body


func _on_rule_changed(_idx: int) -> void:
	if _ops_difficulty_btn != null and difficulty_btn != null:
		_ops_difficulty_btn.selected = difficulty_btn.selected
	if _ops_resources_btn != null and resources_btn != null:
		_ops_resources_btn.selected = resources_btn.selected
	if _ops_ai_btn != null and ai_btn != null:
		_ops_ai_btn.selected = ai_btn.selected
	_refresh_summary()


func _on_ops_rule_changed(_idx: int) -> void:
	if difficulty_btn != null and _ops_difficulty_btn != null:
		difficulty_btn.selected = _ops_difficulty_btn.selected
	if resources_btn != null and _ops_resources_btn != null:
		resources_btn.selected = _ops_resources_btn.selected
	if ai_btn != null and _ops_ai_btn != null:
		ai_btn.selected = _ops_ai_btn.selected
	_refresh_summary()


func _on_ops_map_selected(idx: int) -> void:
	if idx >= 0 and idx < MAP_IDS.size():
		select_map(str(MAP_IDS[idx]))


func _format_number(val: int) -> String:
	var s := str(val)
	var out := ""
	var count := 0
	for i in range(s.length() - 1, -1, -1):
		if count > 0 and count % 3 == 0:
			out = "," + out
		out = s[i] + out
		count += 1
	return out


func _build_manifest_row(path: String) -> Dictionary:
	var data: Dictionary = {}
	if bp_manager != null:
		data = bp_manager.load_blueprint(path)
	if data.is_empty() and FileAccess.file_exists(path):
		var f := FileAccess.open(path, FileAccess.READ)
		if f != null:
			var parsed = JSON.parse_string(f.get_as_text())
			if parsed is Dictionary:
				data = parsed
			f.close()
	if data.is_empty():
		return {}

	var cost: Vector2i = DesignCostingScript.blueprint_materials(data)
	var is_def: bool = data.get("is_defensive", false) or data.get("hull_type", "").begins_with("foundation")
	if roster_picker and roster_picker.is_building_path(path):
		is_def = true
	var is_harv: bool = (roster_picker and roster_picker.is_harvester_path(path)) or data.get("is_harvester", false)
	var is_supp: bool = (roster_picker and roster_picker.is_repair_path(path))
	var queue: String = DesignCostingScript.queue_for_design(data).to_lower()

	var tag := "MED"
	var tag_col: Color = Color(0.38, 0.65, 0.85)
	if is_def:
		tag = "DEF"
		tag_col = Tokens.SIGNAL_HAZARD
	elif is_harv:
		tag = "HARV"
		tag_col = Tokens.SIGNAL_GO
	elif is_supp:
		tag = "SUPP"
		tag_col = Tokens.SIGNAL_INFO
	elif "heavy" in queue:
		tag = "HVY"
		tag_col = Color(0.88, 0.48, 0.22)
	elif "light" in queue:
		tag = "LGT"
		tag_col = Color(0.85, 0.82, 0.35)

	var row_panel := PanelContainer.new()
	row_panel.add_theme_stylebox_override("panel", UITheme.flat_style(
		Tokens.BASE_800, Tokens.BASE_600, 3, "flush", 1))
	row_panel.size_flags_horizontal = Control.SIZE_EXPAND_FILL

	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", Tokens.SPACE_SM)
	row_panel.add_child(row)

	var badge := Label.new()
	badge.text = "[%s]" % tag
	badge.custom_minimum_size = Vector2(48, 0)
	badge.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	badge.theme_type_variation = "StatLabel"
	badge.add_theme_color_override("font_color", tag_col)
	row.add_child(badge)

	var name_lbl := Label.new()
	var dname: String = str(data.get("name", path.get_file().get_basename()))
	name_lbl.text = dname
	name_lbl.theme_type_variation = "HUDValueLabel"
	name_lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	name_lbl.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	name_lbl.tooltip_text = dname
	row.add_child(name_lbl)

	var mat_id: String = str(data.get("armor_material", data.get("armor", {}).get("material", "hardened_steel")))
	var arm_res: int = RosterPickerScript.calculate_armor_resistance(mat_id)
	var cls_name := "DEFENCE" if is_def else ("HARVESTER" if is_harv else queue.capitalize())
	var cls_lbl := Label.new()
	cls_lbl.text = "%s · %d%% Arm" % [cls_name, arm_res]
	cls_lbl.theme_type_variation = "StatLabel"
	cls_lbl.add_theme_color_override("font_color", Tokens.TEXT_SECONDARY)
	cls_lbl.custom_minimum_size = Vector2(110, 0)
	cls_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	row.add_child(cls_lbl)

	var cost_lbl := Label.new()
	var cost_str := ""
	if cost.y > 0:
		cost_str = "%sM / %sC" % [_format_number(cost.x), _format_number(cost.y)]
	else:
		cost_str = "%sM" % _format_number(cost.x)
	cost_lbl.text = cost_str
	cost_lbl.theme_type_variation = "StatLabel"
	cost_lbl.add_theme_color_override("font_color", Tokens.SIGNAL_HAZARD)
	cost_lbl.custom_minimum_size = Vector2(90, 0)
	cost_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	row.add_child(cost_lbl)

	return {
		"node": row_panel,
		"metal": cost.x,
		"crystal": cost.y
	}


func _refresh_summary() -> void:
	if _summary_map == null and _ops_summary_map == null:
		return
	var map_title_str := "%s  (%s)" % [MapCatalog.get_map_name(_map_id), _map_id]
	if _summary_map != null:
		_summary_map.text = map_title_str
	if _ops_summary_map != null:
		_ops_summary_map.text = map_title_str

	var diff_idx: int = difficulty_btn.selected if difficulty_btn != null else 1
	var res_idx: int = resources_btn.selected if resources_btn != null else 0
	var ai_idx: int = ai_btn.selected if ai_btn != null else 1

	var rules_text := "%s diff · %s bank · AI %s" % [
		DIFFICULTY_LABELS[diff_idx],
		RESOURCE_LABELS[res_idx],
		AI_OPPONENT_LABELS[ai_idx],
	]
	if _summary_rules != null:
		_summary_rules.text = rules_text
	if _ops_summary_rules != null:
		_ops_summary_rules.text = rules_text

	if _manifest_list != null or _ops_manifest_list != null:
		if _manifest_list != null:
			for child in _manifest_list.get_children():
				child.queue_free()
		if _ops_manifest_list != null:
			for child in _ops_manifest_list.get_children():
				child.queue_free()

		var paths: Array = roster_picker.ordered_paths() if roster_picker else []
		var is_autodraft := paths.is_empty()
		if is_autodraft and bp_manager != null:
			var listed: Array = bp_manager.list_blueprints(true)
			for b in listed:
				var bp_path := str(b.get("path", ""))
				if bp_path != "":
					paths.append(bp_path)
				if paths.size() >= AUTOPICK_LIMIT:
					break

		var total_metal := 0
		var total_crystal := 0

		if is_autodraft:
			if _manifest_list != null:
				var notice := PanelContainer.new()
				notice.add_theme_stylebox_override("panel", UITheme.flat_style(
					Color(0.12, 0.16, 0.22), Tokens.BASE_500, 4, "flush"))
				var n_lbl := Label.new()
				n_lbl.text = "AUTO-DRAFT ACTIVE — Fielded from standard reserves"
				n_lbl.theme_type_variation = "HintLabel"
				n_lbl.add_theme_color_override("font_color", Tokens.SIGNAL_INFO)
				notice.add_child(n_lbl)
				_manifest_list.add_child(notice)

			if _ops_manifest_list != null:
				var ops_notice := PanelContainer.new()
				ops_notice.add_theme_stylebox_override("panel", UITheme.flat_style(
					Color(0.12, 0.16, 0.22), Tokens.BASE_500, 4, "flush"))
				var ops_n_lbl := Label.new()
				ops_n_lbl.text = "AUTO-DRAFT ACTIVE — Fielded from standard reserves"
				ops_n_lbl.theme_type_variation = "HintLabel"
				ops_n_lbl.add_theme_color_override("font_color", Tokens.SIGNAL_INFO)
				ops_notice.add_child(ops_n_lbl)
				_ops_manifest_list.add_child(ops_notice)

		for path in paths:
			var path_str := str(path)
			if path_str == "":
				continue
			var row_data := _build_manifest_row(path_str)
			if not row_data.is_empty():
				total_metal += int(row_data.metal)
				total_crystal += int(row_data.crystal)
				if _manifest_list != null:
					_manifest_list.add_child(row_data.node)
				if _ops_manifest_list != null:
					var ops_row := _build_manifest_row(path_str)
					if not ops_row.is_empty():
						_ops_manifest_list.add_child(ops_row.node)

		var cost_str := "TOTAL ECHELON DEPLOYMENT COST: %s M / %s C" % [
			_format_number(total_metal), _format_number(total_crystal)
		]
		if _manifest_footer != null:
			_manifest_footer.text = cost_str
		if _ops_manifest_footer != null:
			_ops_manifest_footer.text = cost_str

	var names: Array = roster_picker.ordered_names() if roster_picker else []
	var has_harvester := false
	if roster_picker:
		for path in roster_picker.ordered_paths():
			if roster_picker.is_harvester_path(str(path)):
				has_harvester = true
				break

	var note_text := ""
	var note_col: Color = Tokens.TEXT_SECONDARY
	if not names.is_empty() and not has_harvester:
		note_text = "No harvester in the roster - the match will add one for you so the economy can start."
		note_col = Tokens.SIGNAL_HAZARD
	else:
		note_text = "Ready to deploy."
		note_col = Tokens.TEXT_SECONDARY

	if _summary_note != null:
		_summary_note.text = note_text
		_summary_note.add_theme_color_override("font_color", note_col)
	if _ops_summary_note != null:
		_ops_summary_note.text = note_text
		_ops_summary_note.add_theme_color_override("font_color", note_col)

	var hero_paths: Array = roster_picker.ordered_paths() if roster_picker else []
	if hero_paths.is_empty() and bp_manager != null:
		var listed: Array = bp_manager.list_blueprints(true)
		for b in listed:
			var bp_path := str(b.get("path", ""))
			if bp_path != "":
				hero_paths.append(bp_path)
	if _hero_view != null:
		_hero_view.update_squadron(hero_paths)
	if _ops_hero_view != null:
		_ops_hero_view.update_squadron(hero_paths)


func _add_dropdown(parent: Control, label_text: String, labels: PackedStringArray) -> OptionButton:
	var label = Label.new()
	label.text = label_text
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	parent.add_child(label)

	var btn = OptionButton.new()
	btn.custom_minimum_size = Vector2(260, Tokens.HIT_TARGET_MIN)
	for l in labels:
		btn.add_item(l)
	# The house dropdown language. bomber_theme.tres already carries the plate
	# and the popup; this is the chevron, the height and the type size, i.e.
	# the parts a StyleBox cannot express.
	UITheme.style_dropdown(btn)
	parent.add_child(btn)
	return btn


# ---------------------------------------------------------------------------
# WAR ROOM OPS-TABLE - CONSOLE MODE
# ---------------------------------------------------------------------------
# A unified high-density command deck bringing together Theatre Recon,
# the 3D Squadron Apron Turntable, Roster Tray, and Directives on one screen.
func _build_ops_table() -> Control:
	var deck := HBoxContainer.new()
	deck.add_theme_constant_override("separation", Tokens.SPACE_MD)
	deck.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	deck.size_flags_vertical = Control.SIZE_EXPAND_FILL

	# -----------------------------------------------------------------------
	# COLUMN 1: THEATRE RECON (Left, 360px)
	# -----------------------------------------------------------------------
	var col1 := PanelContainer.new()
	col1.custom_minimum_size = Vector2(360, 0)
	col1.size_flags_vertical = Control.SIZE_EXPAND_FILL
	col1.add_theme_stylebox_override("panel", UITheme.flat_style(
		Tokens.BASE_800, Tokens.BASE_500, Tokens.SPACE_MD, "raised"))
	deck.add_child(col1)

	var col1_vbox := VBoxContainer.new()
	col1_vbox.add_theme_constant_override("separation", Tokens.SPACE_SM)
	col1_vbox.size_flags_vertical = Control.SIZE_EXPAND_FILL
	col1.add_child(col1_vbox)

	var col1_hdr := HBoxContainer.new()
	col1_hdr.add_theme_constant_override("separation", Tokens.SPACE_SM)
	var col1_icon = UITheme.chrome_rect("stage_theatre", Tokens.SPINE_ICON, Tokens.TEXT_PRIMARY)
	if col1_icon != null:
		col1_hdr.add_child(col1_icon)
	var col1_title := Label.new()
	col1_title.text = "THEATRE RECON"
	col1_title.theme_type_variation = "HeadingLabel"
	col1_title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	col1_hdr.add_child(col1_title)
	col1_vbox.add_child(col1_hdr)

	# Map Selector Dropdown
	var map_sel_row := HBoxContainer.new()
	map_sel_row.add_theme_constant_override("separation", Tokens.SPACE_SM)
	var map_sel_lbl := Label.new()
	map_sel_lbl.text = "SECTOR:"
	map_sel_lbl.theme_type_variation = "StatLabel"
	map_sel_row.add_child(map_sel_lbl)

	_ops_map_select = OptionButton.new()
	_ops_map_select.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_ops_map_select.custom_minimum_size = Vector2(0, Tokens.HIT_TARGET_MIN)
	for id in MAP_IDS:
		_ops_map_select.add_item(MapCatalog.get_map_name(str(id)))
	UITheme.style_dropdown(_ops_map_select)
	_ops_map_select.item_selected.connect(_on_ops_map_selected)
	map_sel_row.add_child(_ops_map_select)
	col1_vbox.add_child(map_sel_row)

	# Topo Preview
	_ops_preview = MapPreview.new()
	_ops_preview.custom_minimum_size = Vector2(340, 220)
	_ops_preview.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_ops_preview.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_ops_preview.size_flags_stretch_ratio = 1.0
	col1_vbox.add_child(_ops_preview)

	# Map facts & SITREP
	var sitrep_box := VBoxContainer.new()
	sitrep_box.add_theme_constant_override("separation", Tokens.SPACE_XS)
	sitrep_box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	sitrep_box.size_flags_vertical = Control.SIZE_EXPAND_FILL
	sitrep_box.size_flags_stretch_ratio = 1.0

	var sitrep_hdr := Label.new()
	sitrep_hdr.text = "SITREP BRIEFING"
	sitrep_hdr.theme_type_variation = "HeadingLabel"
	sitrep_box.add_child(sitrep_hdr)

	_ops_map_title = Label.new()
	_ops_map_title.theme_type_variation = "HUDValueLabel"
	_ops_map_title.add_theme_color_override("font_color", Tokens.SIGNAL_HAZARD)
	sitrep_box.add_child(_ops_map_title)

	_ops_map_desc = Label.new()
	_ops_map_desc.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_ops_map_desc.theme_type_variation = "HintLabel"
	sitrep_box.add_child(_ops_map_desc)

	sitrep_box.add_child(HSeparator.new())

	var sitrep_scroll := ScrollContainer.new()
	sitrep_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	sitrep_scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	sitrep_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	sitrep_box.add_child(sitrep_scroll)

	_ops_map_facts = VBoxContainer.new()
	_ops_map_facts.add_theme_constant_override("separation", Tokens.SPACE_XS)
	_ops_map_facts.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	sitrep_scroll.add_child(_ops_map_facts)

	col1_vbox.add_child(sitrep_box)

	# -----------------------------------------------------------------------
	# COLUMN 2: SQUADRON TURNTABLE & ROSTER TRAY (Center, Expand Fill)
	# -----------------------------------------------------------------------
	var col2 := VBoxContainer.new()
	col2.add_theme_constant_override("separation", Tokens.SPACE_MD)
	col2.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	col2.size_flags_vertical = Control.SIZE_EXPAND_FILL
	deck.add_child(col2)

	# Center-Top: 3D Squadron Formation Turntable
	_ops_hero_view = SquadronHeroView.new()
	_ops_hero_view.custom_minimum_size = Vector2(0, 240)
	_ops_hero_view.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_ops_hero_view.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_ops_hero_view.size_flags_stretch_ratio = 1.0
	col2.add_child(_ops_hero_view)

	# Center-Bottom: Roster wells and blueprint library drawer host
	_ops_roster_host = VBoxContainer.new()
	_ops_roster_host.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_ops_roster_host.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_ops_roster_host.size_flags_stretch_ratio = 1.5
	col2.add_child(_ops_roster_host)

	# -----------------------------------------------------------------------
	# COLUMN 3: DIRECTIVES & MANIFEST (Right, 380px)
	# -----------------------------------------------------------------------
	var col3 := PanelContainer.new()
	col3.custom_minimum_size = Vector2(380, 0)
	col3.size_flags_vertical = Control.SIZE_EXPAND_FILL
	col3.add_theme_stylebox_override("panel", UITheme.flat_style(
		Tokens.BASE_800, Tokens.BASE_500, Tokens.SPACE_MD, "raised"))
	deck.add_child(col3)

	var col3_vbox := VBoxContainer.new()
	col3_vbox.add_theme_constant_override("separation", Tokens.SPACE_SM)
	col3_vbox.size_flags_vertical = Control.SIZE_EXPAND_FILL
	col3.add_child(col3_vbox)

	var col3_hdr := HBoxContainer.new()
	col3_hdr.add_theme_constant_override("separation", Tokens.SPACE_SM)
	var col3_icon = UITheme.chrome_rect("stage_launch", Tokens.SPINE_ICON, Tokens.TEXT_PRIMARY)
	if col3_icon != null:
		col3_hdr.add_child(col3_icon)
	var col3_title := Label.new()
	col3_title.text = "ENGAGEMENT DIRECTIVES"
	col3_title.theme_type_variation = "HeadingLabel"
	col3_title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	col3_hdr.add_child(col3_title)
	col3_vbox.add_child(col3_hdr)

	# Engagement Rules
	var rules_grid := GridContainer.new()
	rules_grid.columns = 2
	rules_grid.add_theme_constant_override("h_separation", Tokens.SPACE_MD)
	rules_grid.add_theme_constant_override("v_separation", Tokens.SPACE_XS)
	col3_vbox.add_child(rules_grid)

	_ops_difficulty_btn = _add_dropdown(rules_grid, "AI Difficulty", DIFFICULTY_LABELS)
	_ops_difficulty_btn.custom_minimum_size = Vector2(180, Tokens.HIT_TARGET_MIN)
	_ops_difficulty_btn.selected = difficulty_btn.selected if difficulty_btn else 1

	_ops_resources_btn = _add_dropdown(rules_grid, "Resources", RESOURCE_LABELS)
	_ops_resources_btn.custom_minimum_size = Vector2(180, Tokens.HIT_TARGET_MIN)
	_ops_resources_btn.selected = resources_btn.selected if resources_btn else 0

	_ops_ai_btn = _add_dropdown(rules_grid, "AI Opponent", AI_OPPONENT_LABELS)
	_ops_ai_btn.custom_minimum_size = Vector2(180, Tokens.HIT_TARGET_MIN)
	_ops_ai_btn.selected = ai_btn.selected if ai_btn else 1

	for b in [_ops_difficulty_btn, _ops_resources_btn, _ops_ai_btn]:
		b.item_selected.connect(_on_ops_rule_changed)
	UIFeedbackScript.wire_tree(rules_grid, "select")

	col3_vbox.add_child(HSeparator.new())

	# Manifest Header & Summary
	var manifest_hdr := Label.new()
	manifest_hdr.text = "ECHELON MANIFEST"
	manifest_hdr.theme_type_variation = "HeadingLabel"
	col3_vbox.add_child(manifest_hdr)

	var ops_meta_row := HBoxContainer.new()
	ops_meta_row.add_theme_constant_override("separation", Tokens.SPACE_SM)
	col3_vbox.add_child(ops_meta_row)

	var ops_map_col := VBoxContainer.new()
	ops_map_col.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_ops_summary_map = _summary_line(ops_map_col, "THEATRE")
	ops_meta_row.add_child(ops_map_col)

	var ops_rules_col := VBoxContainer.new()
	ops_rules_col.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_ops_summary_rules = _summary_line(ops_rules_col, "PARAMETERS")
	ops_meta_row.add_child(ops_rules_col)

	# Manifest table container
	var ops_roster_wrap := PanelContainer.new()
	ops_roster_wrap.add_theme_stylebox_override("panel", UITheme.flat_style(
		Tokens.BASE_900, Tokens.BASE_600, Tokens.SPACE_SM, "recessed"))
	ops_roster_wrap.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	ops_roster_wrap.size_flags_vertical = Control.SIZE_EXPAND_FILL
	col3_vbox.add_child(ops_roster_wrap)

	var ops_manifest_box := VBoxContainer.new()
	ops_manifest_box.add_theme_constant_override("separation", Tokens.SPACE_XS)
	ops_manifest_box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	ops_manifest_box.size_flags_vertical = Control.SIZE_EXPAND_FILL
	ops_roster_wrap.add_child(ops_manifest_box)

	# Column headers
	var col_hdr := HBoxContainer.new()
	col_hdr.add_theme_constant_override("separation", Tokens.SPACE_SM)
	var h_role := Label.new()
	h_role.text = "ROLE"
	h_role.custom_minimum_size = Vector2(42, 0)
	h_role.theme_type_variation = "StatLabel"
	h_role.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	col_hdr.add_child(h_role)

	var h_name := Label.new()
	h_name.text = "DESIGN NAME"
	h_name.theme_type_variation = "StatLabel"
	h_name.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	col_hdr.add_child(h_name)

	var h_cost := Label.new()
	h_cost.text = "COST"
	h_cost.custom_minimum_size = Vector2(80, 0)
	h_cost.theme_type_variation = "StatLabel"
	h_cost.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	col_hdr.add_child(h_cost)
	ops_manifest_box.add_child(col_hdr)

	# Scrollable list of units
	var scroll := ScrollContainer.new()
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	ops_manifest_box.add_child(scroll)

	_ops_manifest_list = VBoxContainer.new()
	_ops_manifest_list.add_theme_constant_override("separation", Tokens.SPACE_XS)
	_ops_manifest_list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(_ops_manifest_list)

	# Total deployment cost footer
	var footer_panel := PanelContainer.new()
	footer_panel.add_theme_stylebox_override("panel", UITheme.flat_style(
		Tokens.BASE_800, Tokens.BASE_500, Tokens.SPACE_XS, "flush"))
	ops_manifest_box.add_child(footer_panel)

	_ops_manifest_footer = Label.new()
	_ops_manifest_footer.theme_type_variation = "HUDValueLabel"
	_ops_manifest_footer.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	_ops_manifest_footer.add_theme_color_override("font_color", Tokens.SIGNAL_HAZARD)
	footer_panel.add_child(_ops_manifest_footer)

	_ops_summary_note = Label.new()
	_ops_summary_note.theme_type_variation = "HintLabel"
	_ops_summary_note.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	col3_vbox.add_child(_ops_summary_note)

	# Heavy Primary Actuator: [ENGAGE // DEPLOY]
	var deploy_btn := Button.new()
	deploy_btn.text = "ENGAGE // DEPLOY"
	deploy_btn.theme_type_variation = "PrimaryButton"
	deploy_btn.custom_minimum_size = Vector2(0, Tokens.HIT_TARGET_MIN + Tokens.SPACE_SM)
	deploy_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	deploy_btn.pressed.connect(_on_start_pressed)
	UIFeedbackScript.wire(deploy_btn, "confirm")
	col3_vbox.add_child(deploy_btn)

	var menu_btn := Button.new()
	menu_btn.text = "MAIN MENU"
	menu_btn.custom_minimum_size = Vector2(0, Tokens.HIT_TARGET_MIN)
	menu_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	menu_btn.pressed.connect(_return_to_menu)
	UIFeedbackScript.wire(menu_btn)
	col3_vbox.add_child(menu_btn)

	return deck


# ---------------------------------------------------------------------------
# COMMIT
# ---------------------------------------------------------------------------
# UNCHANGED FROM THE PRE-REBUILD SCREEN, deliberately and in full. Every field
# written here, and the order they are written in, is what the old
# _on_start_pressed() wrote: the same MatchRuleSetScript.skirmish() call with
# the same five arguments, the same two post-construction assignments
# (starting_credits, enable_ai), the same MatchConfig.selected_map_id, and the
# same SceneRouter hop to Battle.tscn. The rebuild is presentation; the output
# contract is not part of it.
func _on_start_pressed() -> void:
	_refresh_readiness()
	if _launch_btn.disabled:
		UIAnimScript.shake(_readiness)
		UIFeedbackScript.play(self, "error")
		return
	var match_config = get_node_or_null("/root/MatchConfig")
	if match_config:
		# Fixed ids rather than a player choice - see the note at the top of
		# this file. LiveryScript resolves PLAYER_ID to the player's authored
		# scheme and any other id to a deterministic roll.
		var player_livery: String = LiveryScript.PLAYER_ID
		var enemy_livery: String = LiveryScript.new_ai_livery_id()
		var ai_difficulty: String = DIFFICULTIES[difficulty_btn.selected]
		var starting_credits: int = RESOURCE_PRESETS[resources_btn.selected]
		var ai_enabled: bool = ai_btn.selected != 0
		# Slot order, left to right and top to bottom, gaps skipped; units
		# first, then defences.
		var paths: Array = roster_picker.ordered_paths() if roster_picker else []
		# selected_map_id is still on MatchConfig (the HUD and the after-action
		# report read it for display) - not part of the rule set.
		match_config.selected_map_id = _map_id if _map_id != "" else MapCatalog.DEFAULT_MAP_ID

		match_config.rule_set = MatchRuleSetScript.skirmish(
			match_config.selected_map_id,
			player_livery,
			enemy_livery,
			paths,
			ai_difficulty,
		)
		# The factory doesn't take starting_credits because it exists to enforce
		# the rule set's SHAPE; the bank preset is a screen value, not a
		# mode-level one. Sentinel -1 keeps the director's own STARTING_CREDITS.
		match_config.rule_set.starting_credits = starting_credits
		match_config.rule_set.enable_ai = ai_enabled

	# Routed through SceneRouter rather than change_scene_to_file(): loading the
	# battle scene synchronously blocks the main thread for over a second, and
	# Windows marks the window "(Not Responding)" while it does.
	var router = get_node_or_null("/root/SceneRouter")
	var map_name := MapCatalog.get_map_name(_map_id) if _map_id != "" else ""
	if router:
		router.goto("res://scenes/Battle.tscn", map_name)
	else:
		get_tree().change_scene_to_file("res://scenes/Battle.tscn")


func _return_to_menu() -> void:
	var router = get_node_or_null("/root/SceneRouter")
	if router:
		router.goto("res://scenes/MainMenu.tscn")
	else:
		get_tree().change_scene_to_file("res://scenes/MainMenu.tscn")


# ---------------------------------------------------------------------------
# MAP CHROME
# ---------------------------------------------------------------------------
# The baked terrain textures in data/maps/ are the asset this screen was
# wasting. There is no single canonical "preview" bake, so both the tile and the
# full preview resolve through the same precedence chain and neither invents its
# own: macro (the closest thing to an aerial photograph), then the splat map,
# then the heightmap. Every map has at least a splat.
#
# A map with none of the three is not an error - it falls back to its authored
# ground_color and the schematic still draws. A missing texture must cost a
# picture, never the stage.
# One map in the chooser rail. A flat tile: baked texture, name, and an amber
# edge when selected - selection is the only interactive accent in this
# language, so it is the only thing the tile changes.
class MapTile extends PanelContainer:
	var map_id: String = ""
	var _screen: Control = null
	var _selected: bool = false

	func configure(id: String, screen: Control) -> void:
		map_id = id
		_screen = screen
		custom_minimum_size = Tokens.MAP_TILE_MIN
		mouse_filter = Control.MOUSE_FILTER_STOP
		var map_def: Dictionary = MapCatalog.get_map(map_id)
		tooltip_text = "%s\n%s" % [MapCatalog.get_map_name(map_id),
			str(map_def.get("description", ""))]

		var box := VBoxContainer.new()
		box.add_theme_constant_override("separation", Tokens.SPACE_XS)
		add_child(box)

		var shot := TextureRect.new()
		shot.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		shot.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_COVERED
		shot.custom_minimum_size = Vector2(0, Tokens.MAP_TILE_MIN.y * 0.62)
		shot.size_flags_vertical = Control.SIZE_EXPAND_FILL
		shot.mouse_filter = Control.MOUSE_FILTER_IGNORE
		var tex := MatchSetupChrome.texture_for(map_id)
		if tex != null:
			shot.texture = tex
		else:
			var fill := ColorRect.new()
			fill.color = MatchSetupChrome.ground_for(map_def)
			fill.set_anchors_preset(Control.PRESET_FULL_RECT)
			fill.mouse_filter = Control.MOUSE_FILTER_IGNORE
			shot.add_child(fill)
		box.add_child(shot)

		var name_label := Label.new()
		name_label.text = MapCatalog.get_map_name(map_id)
		name_label.theme_type_variation = "HintLabel"
		name_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		box.add_child(name_label)

		set_selected(false)
		mouse_entered.connect(_on_hover.bind(true))
		mouse_exited.connect(_on_hover.bind(false))

	func set_selected(on: bool) -> void:
		_selected = on
		_paint(on)

	func _on_hover(on: bool) -> void:
		_paint(_selected or on)

	func _paint(lit: bool) -> void:
		var edge: Color = Tokens.ACCENT_INTERACTIVE if lit else Tokens.BASE_500
		var fill: Color = Tokens.BASE_700 if lit else Tokens.BASE_800
		var border: int = Tokens.BORDER_EMPHASIS if lit else Tokens.BORDER_HAIRLINE
		add_theme_stylebox_override("panel", UITheme.flat_style(
			fill, edge, Tokens.SPACE_SM, "raised" if lit else "flush", border))

	func _gui_input(event: InputEvent) -> void:
		if event is InputEventMouseButton and event.pressed \
				and event.button_index == MOUSE_BUTTON_LEFT:
			if _screen and _screen.has_method("select_map"):
				_screen.select_map(map_id)
				UIFeedbackScript.play(self, "select")
			accept_event()


# The selected map at size: the baked texture, and over it a schematic of the
# things that actually decide a match. The overlay is a _draw() on a child
# Control at display resolution rather than pixels written into an image - the
# same split hud_minimap.gd settled on, for the same reason: the raster changes
# only when the map does, the vectors are cheap and stay crisp.
class MapPreview extends PanelContainer:
	var _shot: TextureRect = null
	var _fill: ColorRect = null
	var _overlay: MapSchematic = null

	func _init() -> void:
		add_theme_stylebox_override("panel", UITheme.flat_style(
			Tokens.BASE_900, Tokens.BASE_500, Tokens.SPACE_SM, "raised"))
		var host := Control.new()
		host.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		host.size_flags_vertical = Control.SIZE_EXPAND_FILL
		host.mouse_filter = Control.MOUSE_FILTER_IGNORE
		add_child(host)

		_fill = ColorRect.new()
		_fill.set_anchors_preset(Control.PRESET_FULL_RECT)
		_fill.color = Tokens.MAP_TERRAIN
		_fill.mouse_filter = Control.MOUSE_FILTER_IGNORE
		host.add_child(_fill)

		_shot = TextureRect.new()
		_shot.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		# KEEP_ASPECT_CENTERED, not COVERED: COVERED crops whichever axis
		# overhangs, which hides part of the playable area behind the frame.
		# A setup screen has to show the whole map, so letterbox instead - the
		# ground-token fill behind this rect (below) becomes the letterbox
		# margin for free, no separate margin colour needed.
		_shot.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		_shot.set_anchors_preset(Control.PRESET_FULL_RECT)
		_shot.mouse_filter = Control.MOUSE_FILTER_IGNORE
		host.add_child(_shot)

		_overlay = MapSchematic.new()
		_overlay.set_anchors_preset(Control.PRESET_FULL_RECT)
		_overlay.mouse_filter = Control.MOUSE_FILTER_IGNORE
		host.add_child(_overlay)

		# Four corner brackets frame the photo like an instrument readout -
		# the one authored chrome glyph this screen was not yet placing.
		# Rotation is done via flip flags rather than shipping 4 SVGs: the
		# source asset is a top-left L, and flip_h/flip_v cover the other
		# three corners exactly.
		for corner in ["tl", "tr", "bl", "br"]:
			var bracket := UITheme.chrome_rect("corner_bracket", Tokens.SPINE_ICON,
				Tokens.BASE_500)
			if bracket == null:
				break
			bracket.flip_h = corner in ["tr", "br"]
			bracket.flip_v = corner in ["bl", "br"]
			match corner:
				"tl": bracket.set_anchors_preset(Control.PRESET_TOP_LEFT)
				"tr": bracket.set_anchors_preset(Control.PRESET_TOP_RIGHT)
				"bl": bracket.set_anchors_preset(Control.PRESET_BOTTOM_LEFT)
				"br": bracket.set_anchors_preset(Control.PRESET_BOTTOM_RIGHT)
			host.add_child(bracket)

	func set_map(map_id: String, map_def: Dictionary) -> void:
		var tex := MatchSetupChrome.texture_for(map_id)
		_shot.texture = tex
		_shot.visible = tex != null
		_fill.color = MatchSetupChrome.ground_for(map_def)
		_overlay.set_map(map_def, tex.get_size() if tex != null else Vector2.ZERO)


# The vector half of the preview. Everything it draws is a token colour; it
# holds no palette of its own.
class MapSchematic extends Control:
	var _def: Dictionary = {}
	var _half: Vector2 = Vector2(400, 400)
	var _tex_size: Vector2 = Vector2.ZERO

	func set_map(map_def: Dictionary, tex_size: Vector2 = Vector2.ZERO) -> void:
		_def = map_def
		_tex_size = tex_size
		_half = MapCatalog.half_extents(map_def)
		if _half.x <= 0.0 or _half.y <= 0.0:
			_half = Vector2(400, 400)
		queue_redraw()

	# The texture beneath this overlay is STRETCH_KEEP_ASPECT_CENTERED, so it
	# letterboxes into a centred sub-rect of this control rather than filling
	# it. Recomputed every call (never cached) so a resize or a map swap to a
	# different aspect ratio can't leave stale margins. With no texture (a map
	# with no baked shot) the content rect is the full control - there is no
	# letterbox to account for.
	func _content_rect() -> Rect2:
		if _tex_size.x <= 0.0 or _tex_size.y <= 0.0 or size.x <= 0.0 or size.y <= 0.0:
			return Rect2(Vector2.ZERO, size)
		var fit_scale: float = min(size.x / _tex_size.x, size.y / _tex_size.y)
		var content_size := _tex_size * fit_scale
		return Rect2((size - content_size) * 0.5, content_size)

	# World XZ -> preview px, mapped onto the letterboxed CONTENT rect (the
	# actual drawn area of the texture) rather than the full control rect, so
	# markers land on the terrain features they label regardless of the map's
	# aspect ratio relative to the frame.
	func _to_px(x: float, z: float) -> Vector2:
		var rect := _content_rect()
		return rect.position + Vector2(
			(x + _half.x) / (_half.x * 2.0) * rect.size.x,
			(z + _half.y) / (_half.y * 2.0) * rect.size.y)

	func _vec3(value) -> Vector3:
		if value is Vector3:
			return value
		if value is Array and value.size() >= 3:
			return Vector3(float(value[0]), float(value[1]), float(value[2]))
		return Vector3.ZERO

	func _vec2(value) -> Vector2:
		if value is Vector2:
			return value
		if value is Array and value.size() >= 2:
			return Vector2(float(value[0]), float(value[1]))
		return Vector2.ZERO

	func _rect_for(centre: Vector3, half: Vector2) -> Rect2:
		var a := _to_px(centre.x - half.x, centre.z - half.y)
		var b := _to_px(centre.x + half.x, centre.z + half.y)
		return Rect2(a, b - a)

	func _draw() -> void:
		if size.x <= 1.0 or size.y <= 1.0:
			return
		# A survey grid, first, under everything. It is what makes the preview
		# read as an instrument's plot rather than as a photograph. Drawn over
		# the same content rect as the markers, so the grid lines up with the
		# terrain photo rather than the letterbox margin.
		var content := _content_rect()
		var step := content.size / float(Tokens.MAP_GRID_DIVISIONS)
		for i in range(1, Tokens.MAP_GRID_DIVISIONS):
			draw_line(content.position + Vector2(step.x * i, 0),
				content.position + Vector2(step.x * i, content.size.y),
				Tokens.MAP_GRID, 1.0)
			draw_line(content.position + Vector2(0, step.y * i),
				content.position + Vector2(content.size.x, step.y * i),
				Tokens.MAP_GRID, 1.0)

		for water in _def.get("water_areas", []):
			var r := _rect_for(_vec3(water.get("center", Vector3.ZERO)),
				_vec2(water.get("half_extents", Vector2.ZERO)))
			draw_rect(r, Color(Tokens.MAP_WATER, 0.35), true)
			draw_rect(r, Color(Tokens.MAP_WATER, 0.85), false, Tokens.MAP_MARKER_EDGE)

		for obstacle in _def.get("obstacles", []):
			var r2 := _rect_for(_vec3(obstacle.get("center", Vector3.ZERO)),
				_vec2(obstacle.get("half_extents", Vector2.ZERO)))
			draw_rect(r2, Color(Tokens.MAP_OBSTACLE, 0.55), true)
			if str(obstacle.get("type", "")) == "rock":
				_draw_rocky_hash(r2)

		for zone in _def.get("surface_zones", []):
			var r := _rect_for(_vec3(zone.get("center", Vector3.ZERO)),
				_vec2(zone.get("half_extents", Vector2.ZERO)))
			var z_type := str(zone.get("surface_type", zone.get("type", "")))
			if z_type == "forest":
				draw_rect(r, Color(Tokens.MAP_USGS_WOODLAND, 0.45), true)
				_draw_tree_hash(r)
			elif z_type in ["rocky", "gravel"]:
				_draw_rocky_hash(r)


		for deposit in _def.get("resource_nodes", []):
			var p := _to_px(_vec3(deposit.get("position", Vector3.ZERO)).x,
				_vec3(deposit.get("position", Vector3.ZERO)).z)
			draw_circle(p, Tokens.MAP_MARKER_R, Color(Tokens.MAP_RESOURCE, 0.9))
			draw_arc(p, Tokens.MAP_MARKER_R + 2.0, 0.0, TAU, 16,
				Color(Tokens.MAP_RESOURCE, 0.5), Tokens.MAP_MARKER_EDGE)

		# Neatline
		draw_rect(content, Tokens.MAP_USGS_NEATLINE, false, 2.0)
		
		# Tick Marks (simplified USGS ticks)
		var tick_len = 8.0
		draw_line(content.position, content.position + Vector2(tick_len, 0), Tokens.MAP_USGS_NEATLINE, 2.0)
		draw_line(content.position, content.position + Vector2(0, tick_len), Tokens.MAP_USGS_NEATLINE, 2.0)
		
		# Scale Bar
		var scale_y = content.position.y + content.size.y - 20
		draw_line(Vector2(content.position.x + 10, scale_y), Vector2(content.position.x + 60, scale_y), Tokens.MAP_USGS_NEATLINE, 3.0)
		
		# North Star
		draw_string(ThemeDB.fallback_font, content.position + Vector2(content.size.x - 30, 30), "★ N", HORIZONTAL_ALIGNMENT_CENTER, -1, 16, Tokens.MAP_USGS_NEATLINE)
		
		# Spawns last, on top
		var spawns: Array = _def.get("spawns", [])
		for i in range(spawns.size()):
			var spawn: Dictionary = spawns[i]
			var hq := _vec3(spawn.get("hq", Vector3.ZERO))
			var p2 := _to_px(hq.x, hq.z)
			var col: Color = Tokens.MAP_SPAWN_PLAYER if str(spawn.get("id", "")) == "player" \
				else Tokens.MAP_SPAWN_ENEMY
			var r3 := Tokens.MAP_MARKER_R * 2.0
			# Refined markers: filled circle with center cross
			draw_circle(p2, r3, col)
			draw_line(p2 - Vector2(r3, 0), p2 + Vector2(r3, 0), Color.WHITE, 1.0)
			draw_line(p2 - Vector2(0, r3), p2 + Vector2(0, r3), Color.WHITE, 1.0)

	func _draw_rocky_hash(r: Rect2) -> void:
		var h_step := 10.0
		var col := Color(0.45, 0.42, 0.38, 0.7)
		var diag_len := r.size.x + r.size.y
		var i := 0.0
		while i < diag_len:
			var p1 := Vector2(clampf(r.position.x + i, r.position.x, r.position.x + r.size.x),
				clampf(r.position.y + maxf(0.0, i - r.size.x), r.position.y, r.position.y + r.size.y))
			var p2 := Vector2(clampf(r.position.x + maxf(0.0, i - r.size.y), r.position.x, r.position.x + r.size.x),
				clampf(r.position.y + i, r.position.y, r.position.y + r.size.y))
			draw_line(p1, p2, col, 1.0)
			i += h_step

	func _draw_tree_hash(r: Rect2) -> void:
		var t_step := 12.0
		var col := Color(0.25, 0.42, 0.20, 0.85)
		var x := r.position.x + 4.0
		while x < r.position.x + r.size.x:
			var y := r.position.y + 4.0
			while y < r.position.y + r.size.y:
				draw_line(Vector2(x - 2, y), Vector2(x + 2, y), col, 1.0)
				draw_line(Vector2(x, y - 3), Vector2(x, y + 2), col, 1.0)
				y += t_step
			x += t_step



# Static helpers reachable from the inner classes. An inner class cannot call
# the outer script's own statics by bare name, and duplicating the precedence
# chain into each of them is how the tile and the preview would end up showing
# different pictures of the same map.
func _on_sort_selected(idx: int) -> void:
	_sort_tiles(idx)

func _sort_tiles(criteria: int) -> void:
	if _map_tiles.is_empty():
		return
	var sorted := _map_tiles.duplicate()
	match criteria:
		0: # Name (A-Z)
			sorted.sort_custom(func(a, b): return MapCatalog.get_map_name(a.map_id) < MapCatalog.get_map_name(b.map_id))
		1: # Size (Asc)
			sorted.sort_custom(func(a, b): 
				var sa = MapCatalog.half_extents(MapCatalog.get_map(a.map_id))
				var sb = MapCatalog.half_extents(MapCatalog.get_map(b.map_id))
				return (sa.x * sa.y) < (sb.x * sb.y))
		2: # Size (Desc)
			sorted.sort_custom(func(a, b): 
				var sa = MapCatalog.half_extents(MapCatalog.get_map(a.map_id))
				var sb = MapCatalog.half_extents(MapCatalog.get_map(b.map_id))
				return (sa.x * sa.y) > (sb.x * sb.y))
		3: # Spawns
			sorted.sort_custom(func(a, b):
				var na = MapCatalog.get_map(a.map_id).get("spawns", []).size()
				var nb = MapCatalog.get_map(b.map_id).get("spawns", []).size()
				return na > nb)
		4: # Resources
			sorted.sort_custom(func(a, b):
				var ra = MapCatalog.get_map(a.map_id).get("resource_nodes", []).size()
				var rb = MapCatalog.get_map(b.map_id).get("resource_nodes", []).size()
				return ra > rb)
	
	var rail = _map_tiles[0].get_parent()
	for tile in sorted:
		rail.move_child(tile, -1)

class MatchSetupChrome extends RefCounted:
	static func texture_for(map_id: String) -> Texture2D:
		for suffix in ["_topo", "_macro", "_splat", "_height"]:
			var path := "res://data/maps/%s%s.png" % [map_id, suffix]
			if ResourceLoader.exists(path):
				var tex: Texture2D = load(path) as Texture2D
				if tex != null:
					return tex
		return null

	static func ground_for(map_def: Dictionary) -> Color:
		var raw = map_def.get("ground_color", null)
		if raw is Color:
			return raw
		if raw is Array and raw.size() >= 3:
			return Color(float(raw[0]), float(raw[1]), float(raw[2]))
		return Tokens.MAP_USGS_BUFF


class SquadronHeroView extends PanelContainer:
	var _subviewport: SubViewport = null
	var _camera: Camera3D = null
	var _squadron_root: Node3D = null
	var _active_paths: Array = []
	var _is_dragging: bool = false

	func _init() -> void:
		size_flags_horizontal = Control.SIZE_EXPAND_FILL
		size_flags_vertical = Control.SIZE_EXPAND_FILL
		mouse_filter = Control.MOUSE_FILTER_STOP
		add_theme_stylebox_override("panel", UITheme.flat_style(
			Tokens.BASE_800, Tokens.BASE_500, Tokens.SPACE_LG, "raised"))

		var box := VBoxContainer.new()
		box.add_theme_constant_override("separation", Tokens.SPACE_SM)
		box.set_anchors_preset(Control.PRESET_FULL_RECT)
		add_child(box)

		var header := HBoxContainer.new()
		header.add_theme_constant_override("separation", Tokens.SPACE_SM)
		var icon = UITheme.chrome_rect("stage_launch", Tokens.SPINE_ICON, Tokens.TEXT_PRIMARY)
		if icon:
			header.add_child(icon)
		var title := Label.new()
		title.text = "SQUADRON FORMATION"
		title.theme_type_variation = "HeadingLabel"
		title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		# Let the heading wrap before its minimum width pushes Launch offscreen.
		title.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		header.add_child(title)

		var livery_tag := Label.new()
		livery_tag.text = "PLAYER LIVERY"
		livery_tag.theme_type_variation = "StatLabel"
		header.add_child(livery_tag)
		box.add_child(header)

		var vp_cont := SubViewportContainer.new()
		vp_cont.stretch = true
		vp_cont.mouse_filter = Control.MOUSE_FILTER_PASS
		vp_cont.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		vp_cont.size_flags_vertical = Control.SIZE_EXPAND_FILL
		box.add_child(vp_cont)

		_subviewport = SubViewport.new()
		_subviewport.transparent_bg = true
		_subviewport.handle_input_locally = false
		_subviewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
		_subviewport.msaa_3d = Viewport.MSAA_2X
		_subviewport.own_world_3d = true
		_subviewport.world_3d = World3D.new()
		vp_cont.add_child(_subviewport)

		_camera = Camera3D.new()
		_camera.fov = 40.0
		_camera.current = true
		_camera.position = Vector3(0.0, 9.0, 18.0)
		_camera.look_at_from_position(_camera.position, Vector3(0.0, 0.8, -0.5), Vector3.UP)
		_subviewport.add_child(_camera)

		var sun := DirectionalLight3D.new()
		sun.rotation_degrees = Vector3(-42.0, 135.0, 0.0)
		sun.light_color = Tokens.INSPECTION_KEY_COLOR
		sun.light_energy = Tokens.INSPECTION_KEY_ENERGY
		_subviewport.add_child(sun)

		var fill := DirectionalLight3D.new()
		fill.rotation_degrees = Vector3(25.0, -45.0, 0.0)
		fill.light_color = Tokens.INSPECTION_FILL_COLOR
		fill.light_energy = Tokens.INSPECTION_FILL_ENERGY
		_subviewport.add_child(fill)

		var env := UITheme.inspection_environment()
		var w_env := WorldEnvironment.new()
		w_env.environment = env
		_subviewport.add_child(w_env)

		# Outer perimeter kerb collar / foundation ring in hazard amber / dark steel
		var kerb := MeshInstance3D.new()
		var kmesh := CylinderMesh.new()
		kmesh.top_radius = 28.5
		kmesh.bottom_radius = 29.8
		kmesh.height = 0.55
		kerb.mesh = kmesh
		# Plinth sits 15mm below driving surface (y = 0.0) to prevent co-planar z-fighting
		kerb.position = Vector3(0.0, -0.29, -2.0)
		var kmat := StandardMaterial3D.new()
		kmat.albedo_color = Color(0.35, 0.30, 0.15)
		kmat.roughness = 0.65
		kmat.metallic = 0.35
		kerb.material_override = kmat
		_subviewport.add_child(kerb)

		# Ground apron plinth - industrial dark asphalt tarmac
		var apron := MeshInstance3D.new()
		var amesh := CylinderMesh.new()
		amesh.top_radius = 28.0
		amesh.bottom_radius = 28.3
		amesh.height = 0.50
		apron.mesh = amesh
		apron.position = Vector3(0.0, -0.25, -2.0)
		var amat := StandardMaterial3D.new()
		amat.albedo_color = Color(0.14, 0.15, 0.16)
		amat.roughness = 0.90
		amat.metallic = 0.05
		apron.material_override = amat
		_subviewport.add_child(apron)

		# 4 low-profile perimeter ground floodlights at cardinal points around the plinth rim
		var beacon_coords: Array[Vector3] = [
			Vector3(0.0, 0.15, -29.0),   # North
			Vector3(0.0, 0.15, 25.0),    # South
			Vector3(27.0, 0.15, -2.0),   # East
			Vector3(-27.0, 0.15, -2.0),  # West
		]
		for bpos in beacon_coords:
			var b_inst := MeshInstance3D.new()
			var b_mesh := CylinderMesh.new()
			b_mesh.top_radius = 0.4
			b_mesh.bottom_radius = 0.6
			b_mesh.height = 0.3
			b_inst.mesh = b_mesh
			b_inst.position = bpos
			var b_mat := StandardMaterial3D.new()
			b_mat.albedo_color = Color(0.2, 0.2, 0.22)
			b_mat.emission_enabled = true
			b_mat.emission = Color(1.0, 0.85, 0.5)
			b_mat.emission_energy_multiplier = 1.5
			b_inst.material_override = b_mat
			_subviewport.add_child(b_inst)

			var omni := OmniLight3D.new()
			omni.position = bpos + Vector3(0.0, 0.25, 0.0)
			omni.light_color = Color(1.0, 0.90, 0.72)
			omni.light_energy = 0.8
			omni.omni_range = 15.0
			omni.omni_attenuation = 1.2
			_subviewport.add_child(omni)

		_squadron_root = Node3D.new()
		_subviewport.add_child(_squadron_root)

	func _process(delta: float) -> void:
		if _squadron_root != null and not _is_dragging:
			_squadron_root.rotation.y += delta * 0.05

	func _gui_input(event: InputEvent) -> void:
		if event is InputEventMouseButton:
			if event.button_index == MOUSE_BUTTON_LEFT:
				_is_dragging = event.pressed
		elif event is InputEventMouseMotion and _is_dragging:
			if _squadron_root != null:
				_squadron_root.rotation.y += event.relative.x * 0.008

	func update_squadron(paths: Array) -> void:
		if _subviewport == null or _squadron_root == null:
			return
		if paths == _active_paths and not _squadron_root.get_children().is_empty():
			return
		_squadron_root.rotation.y = 0.0
		_active_paths = paths.duplicate()
		for child in _squadron_root.get_children():
			child.queue_free()

		var valid_paths: Array = []
		for p in paths:
			var sp := str(p)
			if sp != "" and FileAccess.file_exists(sp):
				valid_paths.append(sp)

		if valid_paths.is_empty():
			return

		var count := mini(valid_paths.size(), 7)
		var bp := BlueprintManagerScript.new()
		add_child(bp)

		var vehicles: Array[Node3D] = []
		var half_widths: Array[float] = []

		for i in range(count):
			var path: String = valid_paths[i]
			var f := FileAccess.open(path, FileAccess.READ)
			if f == null:
				continue
			var text := f.get_as_text()
			f.close()
			var json = JSON.parse_string(text)
			if not (json is Dictionary):
				continue
			var vehicle: Node3D = bp.reconstruct_vehicle(json, _squadron_root, false, LiveryScript.PLAYER_ID)
			if vehicle:
				vehicles.append(vehicle)
				# Measure vehicle bounding box at reconstruct position to find half-width
				var v_box: AABB = BlueprintThumbnailScript.merged_aabb(vehicle, vehicle.transform)
				var hw: float = v_box.size.x * 0.5 if v_box.size.x > 0.0 else 2.0
				half_widths.append(hw)

		bp.queue_free()

		if vehicles.is_empty():
			return

		# Compute non-overlapping adaptive wedge positions
		var lead_z := 4.5
		var z_step := 3.8
		var min_gap := 1.8
		var pair_ranks = [[1, 2], [3, 4], [5, 6]]
		var placed_positions: Array[Vector3] = []
		placed_positions.append(Vector3(0.0, 0.0, lead_z))

		var left_edge: float = -half_widths[0]
		var right_edge: float = half_widths[0]
		var row := 1

		for pr in pair_ranks:
			if pr[0] >= vehicles.size():
				break
			var left_idx: int = pr[0]
			var right_idx: int = pr[1] if pr[1] < vehicles.size() else -1
			var z_pos := lead_z - float(row) * z_step
			var top_radius := 28.0

			var left_hw: float = half_widths[left_idx]
			var left_x := clampf(left_edge - min_gap - left_hw, -top_radius + left_hw, top_radius - left_hw)
			placed_positions.append(Vector3(left_x, 0.0, z_pos))
			left_edge = left_x - left_hw

			if right_idx >= 0:
				var right_hw: float = half_widths[right_idx]
				var right_x := clampf(right_edge + min_gap + right_hw, -top_radius + right_hw, top_radius - right_hw)
				placed_positions.append(Vector3(right_x, 0.0, z_pos))
				right_edge = right_x + right_hw
			row += 1

		for i in range(vehicles.size()):
			var vehicle := vehicles[i]
			var recon_y: float = vehicle.position.y
			var pos := placed_positions[i]
			vehicle.position = Vector3(pos.x, recon_y, pos.z)

			var yaw := 0.0
			if pos.x < -0.5:
				yaw = deg_to_rad(12.0)
			elif pos.x > 0.5:
				yaw = deg_to_rad(-12.0)
			vehicle.rotation = Vector3(0, yaw, 0)

		var aabb := BlueprintThumbnailScript.merged_aabb(_squadron_root, Transform3D.IDENTITY)
		if aabb.size != Vector3.ZERO:
			var centre := aabb.get_center()
			var extent := maxf(aabb.size.x, aabb.size.z)
			var dist := extent * 1.05 + 5.0
			_camera.position = Vector3(centre.x, centre.y + extent * 0.42 + 2.4, centre.z + dist)
			_camera.look_at(Vector3(centre.x, centre.y + 0.3, centre.z), Vector3.UP)
			_camera.current = true
