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
var _summary_roster: Label
var _summary_note: Label

var _back_btn: Button
var _next_btn: Button
var _launch_btn: Button


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

	_stage_pages = [_build_map_stage(), _build_roster_stage(), _build_launch_stage()]
	for page in _stage_pages:
		page.set_anchors_preset(Control.PRESET_FULL_RECT)
		_stage_host.add_child(page)

	column.add_child(_build_nav())

	_sync_map_selection()
	_goto_stage(0, false)


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
	return band


func _build_chip(idx: int) -> Button:
	var stage: Dictionary = STAGES[idx]
	var chip := Button.new()
	chip.theme_type_variation = "TabButton"
	chip.custom_minimum_size = Vector2(0, Tokens.HIT_TARGET_MIN + Tokens.SPACE_SM)
	chip.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	chip.focus_mode = Control.FOCUS_NONE
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

	chip.pressed.connect(_on_chip_pressed.bind(idx))
	UIFeedbackScript.wire(chip, "select")
	_spine_chips.append(chip)
	return chip


func _on_chip_pressed(idx: int) -> void:
	# Backwards always; forwards only into a stage the flow has already
	# confirmed. That is the whole gate on LAUNCH - it cannot be reached out of
	# an unvisited flow, and it needs no separate validity rule to say so.
	if idx <= _unlocked:
		_goto_stage(idx)
	else:
		UIAnimScript.shake(_spine_chips[idx])
		UIFeedbackScript.play(_spine_chips[idx], "reject")


func _goto_stage(idx: int, animate: bool = true) -> void:
	_stage = clampi(idx, 0, STAGES.size() - 1)
	_unlocked = maxi(_unlocked, _stage)
	for i in range(_stage_pages.size()):
		_stage_pages[i].visible = i == _stage
	if animate:
		# From the right on the way forward, from the left on the way back, so
		# the motion agrees with the spine's direction of travel.
		UIAnimScript.slide_in(_stage_pages[_stage], Vector2(16, 0))
	_caption.text = str(STAGES[_stage]["caption"])
	_refresh_spine()
	_refresh_nav()
	if _stage == STAGES.size() - 1:
		_refresh_summary()


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
		if i == _stage:
			col = Tokens.SIGNAL_HAZARD
		elif i < _stage:
			col = Tokens.SIGNAL_GO
		elif i <= _unlocked:
			col = Tokens.TEXT_SECONDARY
		if legend != null:
			legend.add_theme_color_override("font_color", col)
		chip.button_pressed = i == _stage
		chip.disabled = i > _unlocked
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
			if i < _stage:
				var done := UITheme.chrome_icon("stage_done")
				if done != null:
					glyph.texture = done
			else:
				var own := UITheme.chrome_icon(str(STAGES[i]["glyph"]))
				if own != null:
					glyph.texture = own


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

	UIFeedbackScript.wire(_back_btn)
	UIFeedbackScript.wire(_next_btn, "select")
	UIFeedbackScript.wire(_launch_btn, "confirm")
	return band


func _nav_button(text: String, glyph: String, trailing: bool) -> Button:
	var btn := Button.new()
	btn.custom_minimum_size = Tokens.NAV_BUTTON_MIN
	btn.focus_mode = Control.FOCUS_NONE
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
	page.add_theme_constant_override("separation", Tokens.SPACE_MD)

	MAP_IDS = MapCatalog.get_map_ids()

	var rail_wrap := PanelContainer.new()
	rail_wrap.add_theme_stylebox_override("panel", UITheme.flat_style(
		Tokens.BASE_800, Tokens.BASE_500, Tokens.SPACE_SM, "flush"))
	rail_wrap.custom_minimum_size = Vector2(Tokens.MAP_TILE_MIN.x + Tokens.SPACE_XL, 0)
	page.add_child(rail_wrap)

	var scroll := ScrollContainer.new()
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	rail_wrap.add_child(scroll)

	var rail := VBoxContainer.new()
	rail.add_theme_constant_override("separation", Tokens.SPACE_SM)
	rail.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(rail)

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

	var facts_wrap := PanelContainer.new()
	facts_wrap.add_theme_stylebox_override("panel", UITheme.flat_style(
		Tokens.BASE_800, Tokens.BASE_500, Tokens.SPACE_MD, "raised"))
	facts_wrap.custom_minimum_size = Vector2(Tokens.SUMMARY_COL_MIN, 0)
	page.add_child(facts_wrap)

	var facts := VBoxContainer.new()
	facts.add_theme_constant_override("separation", Tokens.SPACE_SM)
	facts_wrap.add_child(facts)

	_map_title = Label.new()
	_map_title.theme_type_variation = "TitleLabel"
	_map_title.autowrap_mode = TextServer.AUTOWRAP_WORD
	facts.add_child(_map_title)

	_map_desc = Label.new()
	_map_desc.theme_type_variation = "HintLabel"
	_map_desc.autowrap_mode = TextServer.AUTOWRAP_WORD
	facts.add_child(_map_desc)

	facts.add_child(HSeparator.new())

	_map_facts = VBoxContainer.new()
	_map_facts.add_theme_constant_override("separation", Tokens.SPACE_XS)
	facts.add_child(_map_facts)

	facts.add_child(_build_legend())
	return page


# The schematic's key. Without it the overlay is four colours of dot; with it
# the preview is readable at a glance, which is the whole reason the stage
# exists.
func _build_legend() -> Control:
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", Tokens.SPACE_XS)
	var heading := Label.new()
	heading.text = "SCHEMATIC"
	heading.theme_type_variation = "HeadingLabel"
	box.add_child(heading)
	var rows := [
		["pin_spawn", Tokens.MAP_SPAWN_PLAYER, "Your deployment zone"],
		["pin_spawn", Tokens.MAP_SPAWN_ENEMY, "Hostile deployment zone"],
		["pin_resource", Tokens.MAP_RESOURCE, "Resource deposit"],
		["", Tokens.MAP_WATER, "Water"],
		["", Tokens.MAP_OBSTACLE, "Cover and obstruction"],
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
	_refresh_map_facts()
	if _stage == STAGES.size() - 1:
		_refresh_summary()


func _refresh_map_facts() -> void:
	var map_def: Dictionary = MapCatalog.get_map(_map_id)
	if _preview:
		_preview.set_map(_map_id, map_def)
	if _map_title:
		_map_title.text = str(map_def.get("name", MapCatalog.get_map_name(_map_id)))
	if _map_desc:
		_map_desc.text = str(map_def.get("description", ""))
	if _map_facts == null:
		return
	for child in _map_facts.get_children():
		child.queue_free()
	var he: Vector2 = MapCatalog.half_extents(map_def)
	var deposits: Dictionary = {}
	for node_def in map_def.get("resource_nodes", []):
		var kind := str(node_def.get("type", "ore"))
		deposits[kind] = int(deposits.get(kind, 0)) + 1
	var spawns: Array = map_def.get("spawns", [])
	var waters: Array = map_def.get("water_areas", [])
	var covers: Array = map_def.get("obstacles", [])
	var facts := [
		["FIELD", "%d x %d m" % [int(he.x * 2.0), int(he.y * 2.0)]],
		["SPAWNS", str(spawns.size())],
		["WATER", str(waters.size())],
		["COVER", str(covers.size())],
	]
	for kind in deposits.keys():
		facts.append([str(kind).to_upper(), str(deposits[kind])])
	for fact in facts:
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
		_map_facts.add_child(row)


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
	page.add_theme_constant_override("separation", Tokens.SPACE_SM)

	var entries: Array = bp_manager.list_blueprints(true)

	roster_picker = RosterPickerScript.new()
	roster_picker.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	roster_picker.size_flags_vertical = Control.SIZE_EXPAND_FILL
	page.add_child(roster_picker)
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
	if _stage == STAGES.size() - 1:
		_refresh_summary()


# ---------------------------------------------------------------------------
# STAGE 3 - LAUNCH
# ---------------------------------------------------------------------------
# Confirm, do not hope. The three match options sit beside a written-out
# summary of the map, the rules and the exact roster that will be fielded, so
# the player reads the match they are about to start instead of trusting that
# the previous two stages took.
func _build_launch_stage() -> Control:
	var page := HBoxContainer.new()
	page.add_theme_constant_override("separation", Tokens.SPACE_MD)

	var rules_wrap := PanelContainer.new()
	rules_wrap.add_theme_stylebox_override("panel", UITheme.flat_style(
		Tokens.BASE_800, Tokens.BASE_500, Tokens.SPACE_LG, "raised"))
	rules_wrap.custom_minimum_size = Vector2(Tokens.SUMMARY_COL_MIN + Tokens.SPACE_XL, 0)
	page.add_child(rules_wrap)

	var rules := VBoxContainer.new()
	rules.add_theme_constant_override("separation", Tokens.SPACE_MD)
	rules_wrap.add_child(rules)

	var rules_heading := Label.new()
	rules_heading.text = "ENGAGEMENT RULES"
	rules_heading.theme_type_variation = "HeadingLabel"
	rules.add_child(rules_heading)

	var grid := GridContainer.new()
	grid.columns = 2
	grid.add_theme_constant_override("h_separation", Tokens.SPACE_MD)
	grid.add_theme_constant_override("v_separation", Tokens.SPACE_MD)
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
		Tokens.BASE_800, Tokens.BASE_500, Tokens.SPACE_LG, "raised"))
	summary_wrap.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	page.add_child(summary_wrap)

	var summary := VBoxContainer.new()
	summary.add_theme_constant_override("separation", Tokens.SPACE_MD)
	summary_wrap.add_child(summary)

	var summary_heading := Label.new()
	summary_heading.text = "DEPLOYMENT ORDER"
	summary_heading.theme_type_variation = "HeadingLabel"
	summary.add_child(summary_heading)

	_summary_map = _summary_line(summary, "THEATRE")
	_summary_rules = _summary_line(summary, "RULES")
	_summary_roster = _summary_line(summary, "ROSTER")

	_summary_note = Label.new()
	_summary_note.theme_type_variation = "HintLabel"
	_summary_note.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	summary.add_child(_summary_note)
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
	_refresh_summary()


func _refresh_summary() -> void:
	if _summary_map == null:
		return
	_summary_map.text = "%s  (%s)" % [MapCatalog.get_map_name(_map_id), _map_id]
	_summary_rules.text = "%s difficulty  ·  %s bank  ·  AI opponent %s" % [
		DIFFICULTY_LABELS[difficulty_btn.selected],
		RESOURCE_LABELS[resources_btn.selected],
		AI_OPPONENT_LABELS[ai_btn.selected],
	]
	var names: Array = roster_picker.ordered_names() if roster_picker else []
	var units: int = roster_picker.filled_unit_count() if roster_picker else 0
	var defences: int = roster_picker.filled_defence_count() if roster_picker else 0
	if names.is_empty():
		_summary_roster.text = "AUTO-DRAFT - no design hand-picked, so the match fields your first %d saved designs plus the built-in defaults." % AUTOPICK_LIMIT
	else:
		_summary_roster.text = "%d units, %d defences\n%s" % [
			units, defences, ", ".join(PackedStringArray(names))]
	# An advisory, not a gate. The director force-adds a fallback harvester to a
	# roster that cannot mine, so this is worth SAYING and not worth blocking -
	# the screen must not invent a rule the match does not have.
	var has_harvester := false
	if roster_picker:
		for path in roster_picker.ordered_paths():
			if roster_picker.is_harvester_path(str(path)):
				has_harvester = true
				break
	if not names.is_empty() and not has_harvester:
		_summary_note.text = "No harvester in the roster - the match will add one for you so the economy can start."
		_summary_note.add_theme_color_override("font_color", Tokens.SIGNAL_HAZARD)
	else:
		_summary_note.text = "Ready to deploy."
		_summary_note.add_theme_color_override("font_color", Tokens.TEXT_SECONDARY)


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

		for deposit in _def.get("resource_nodes", []):
			var p := _to_px(_vec3(deposit.get("position", Vector3.ZERO)).x,
				_vec3(deposit.get("position", Vector3.ZERO)).z)
			draw_circle(p, Tokens.MAP_MARKER_R, Color(Tokens.MAP_RESOURCE, 0.9))
			draw_arc(p, Tokens.MAP_MARKER_R + 2.0, 0.0, TAU, 16,
				Color(Tokens.MAP_RESOURCE, 0.5), Tokens.MAP_MARKER_EDGE)

		# Spawns last, on top, and the only markers drawn as a ring plus a
		# crosshair: they are the two points the player reads first.
		var spawns: Array = _def.get("spawns", [])
		for i in range(spawns.size()):
			var spawn: Dictionary = spawns[i]
			var hq := _vec3(spawn.get("hq", Vector3.ZERO))
			var p2 := _to_px(hq.x, hq.z)
			var col: Color = Tokens.MAP_SPAWN_PLAYER if str(spawn.get("id", "")) == "player" \
				else Tokens.MAP_SPAWN_ENEMY
			var r3 := Tokens.MAP_MARKER_R * 2.0
			draw_arc(p2, r3, 0.0, TAU, 24, col, Tokens.MAP_MARKER_EDGE * 1.5)
			draw_line(p2 - Vector2(r3 * 1.6, 0), p2 + Vector2(r3 * 1.6, 0), col, 1.0)
			draw_line(p2 - Vector2(0, r3 * 1.6), p2 + Vector2(0, r3 * 1.6), col, 1.0)


# Static helpers reachable from the inner classes. An inner class cannot call
# the outer script's own statics by bare name, and duplicating the precedence
# chain into each of them is how the tile and the preview would end up showing
# different pictures of the same map.
class MatchSetupChrome extends RefCounted:
	static func texture_for(map_id: String) -> Texture2D:
		for suffix in ["_macro", "_splat", "_height"]:
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
		return Tokens.MAP_TERRAIN
