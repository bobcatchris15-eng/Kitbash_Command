extends Control

signal part_hovered(type_id: String)
signal part_unhovered()

# The Design Lab's hardware catalog.
#
# THE SHAPE: a permanent LEFT VERTICAL DOCK, built to read as a mechanic's
# steel toolbox standing on end. A 2x2 grid of family tabs (Hulls / Weapons /
# Support / Drives) selects which family's category drawers are listed below
# it; only one family is shown at a time, and within a family the category
# drawers accordion among themselves (_open_category). A search field at the
# top filters across all four families at once and opens whatever it finds.
#
# THE CHROME is three concentric layers, outermost first - a bare-steel lip,
# a rubber gasket, and the chipped oxide-enamel body. See _build_shell for why
# each is a plain Panel rather than a PanelContainer, and for why the body's
# paint is a theme material (field_toolbox.png, authored by
# tools/generate_ui_plates.py) rather than a bespoke shader.
#
# A NOTE ON THIS FILE'S HISTORY, because it explains the names still in it.
# A 2026-08-10 rewrite replaced the dock with four floating toolboxes along the
# BOTTOM of the screen, mirroring the Skirmish build queue. That direction was
# abandoned and the left dock reinstated, but the revert left the file
# describing a layout it no longer built: _layout_bar() and _close_family()
# were empty stubs, _family_widgets was declared and never written (which
# silently broke get_bar_focus_rect - see there), and a dozen bar-geometry
# constants had no readers. That wreckage is gone as of 2026-08-13. What
# survives from the bottom-bar build is the vocabulary it introduced and the
# dock still uses: ToolboxPlate + StampedLabel on the family tabs.
#
# THE DRAWER METADATA CONTRACT is load-bearing and must not drift:
# drawer_category, content_container, header_btn, drawer_open, family, tier,
# plus the _all_drawers array. The test suites walk THAT, not the node
# hierarchy, which is what lets this panel be rebuilt without rewriting suites
# that only ever had an opinion about catalog data. _make_section sets them.
#
# get_dock() returns null and is kept only for callers that still ask. There is
# no UIDock here; anything wanting a rect to highlight wants get_bar_focus_rect.

const ModuleCatalog = preload("res://scripts/module_catalog.gd")
const ArmorPaint = preload("res://scripts/armor_paint.gd")
const UITheme = preload("res://scripts/ui_theme.gd")
const Tokens = preload("res://scripts/ui_tokens.gd")
const UIAnim = preload("res://scripts/ui_anim.gd")
const ToolboxPlateScript = preload("res://scripts/ui_toolbox_plate.gd")
const StampedLabelScript = preload("res://scripts/ui_stamped_label.gd")
const UIFeedbackScript = preload("res://scripts/ui_feedback.gd")

# --- Grouping (unchanged from the previous build) ----------------------------
# Weight is the right sort key here rather than cost or name: it is the one
# stat every single part in the catalog has, it is monotonic with "how big a
# commitment is this", and on a game where payload capacity is the binding
# constraint it is the number a player is actually budgeting against while
# browsing. Alphabetical would scatter the light starter parts through the
# list; cost would put the crystal-heavy exotics next to the cheap junk.
## Chassis bins come from the hull's DECLARED class, not from its weight.
##
## They used to be pure weight thresholds at 200 / 450, picked against the old
## catalogue. Against the 60-hull one they collapsed: the lightest hull in the
## game weighs 197, so "Light Chassis" contained exactly ONE entry and the other
## seven scouts sat under Medium next to genuine mediums.
##
## Bumping the thresholds alone cannot fix it cleanly either, because the
## classes overlap by weight - the heaviest Medium is 666 and the lightest
## Transport is 657, so no single number separates them. The class is the
## authoritative answer and every shipped hull declares it.
##
## ModuleCatalog.get_hull_size_tier() already maps the six classes onto three
## tiers for the manufactory system; reusing HULL_TIER_BY_CLASS here keeps the
## parts bin and the production tiers from ever disagreeing about what counts as
## a light chassis.
const HULL_GROUP_ORDER = [
	"Scout & Light Chassis",
	"Medium Battle Chassis",
	"Heavy & Assault Chassis",
	"Specialty & Transports",
	"Aerospace & Aviation",
	"Static Foundations"
]

# The four TOP-LEVEL TOOLBOXES, in left-to-right order along the bottom.
# The "weapons"/"support"/"locomotion" tier ids are the same ones the
# previous build used, so data logic and the tests that read it do not
# change - only the way those tier ids get rendered changes.
const TIERS = [
	{"id": "hulls", "label": "Hulls"},
	{"id": "weapons", "label": "Weapons"},
	{"id": "support", "label": "Support"},
	{"id": "locomotion", "label": "Drives"},
	{"id": "armor", "label": "Armor"},
]

# Which module ROLES are weapons. Taken from the catalog's own wording rather
# than invented here: smoke and mines belong with the guns even at 0 dps.
const WEAPON_ROLES = [
	"Direct-Fire Guns", "Energy & Electromagnetic", "Indirect Fire",
	"Missiles", "Point Defense", "Deployables",
]

# Propulsion routes to Support — speed upgrades live with their sibling
# utilities (Power, Armor) rather than with locomotion drive types.
# DRIVE_ROLES kept as empty to avoid breaking any callers.
const DRIVE_ROLES: Array = []

# Display order within the Support tab. Propulsion sits last so the
# utility/infrastructure groupings (Armor, Power, general Support) read
# first and the speed-modifiers are a logical follow-on.
const SUPPORT_ROLE_ORDER = ["Armor", "Power", "Support"]

const CARD_MIN_WIDTH := 80
const CARD_HEIGHT := 100

# --- Dock dimensions --------------------------------------------------------
# Wide enough for two part cards per row at CARD_MIN_WIDTH plus the concentric
# lip/gasket/body insets and the scrollbar.
const TOOLBOX_WIDTH := 288.0

# --- State ------------------------------------------------------------------
var _filter: String = ""
# Which family's body is currently open. "" means none - the very first
# landing on the screen shows only the four headers, no body content.
var _open_family: String = ""

var _family_vboxes: Dictionary = {}
var _family_tabs: Dictionary = {}

# Every section built, across all three families, so search can sweep them
# without re-walking the scene tree on each keystroke.
var _all_drawers: Array = []

var _search_box: LineEdit

# Empty-state hint, shown when the search filters out every part.
var _empty_hint: Label

# Retained so the old API keeps working for any caller that still sets them;
# the new panel does not enforce single-open and the per-family accordion
# replaces these strings as the source of truth.
var open_drawer_hulls: String = ""
var open_drawer_modules: String = ""
var open_drawer_locomotion: String = ""


func _ready() -> void:
	# FULL_RECT, so the bar's hand-laid-out toolboxes can use the real viewport
	# size. The screen behind the 3D viewport is the one that matters here -
	# not the per-dock size the old build used.
	set_anchors_preset(Control.PRESET_FULL_RECT)
	# The bar's children own their own clicks; this is a no-op surface above
	# the 3D viewport, and a STOP filter would eat clicks meant for the model.
	mouse_filter = Control.MOUSE_FILTER_IGNORE

	_build_shell()

	var catalog = ModuleCatalog.get_catalog()
	var hull_groups: Dictionary = {}
	var module_groups: Dictionary = {}
	var loco_entries: Array = []

	for type_id in catalog.keys():
		var data = catalog[type_id]
		var category = data.get("category", "module")

		# Armor is PAINTED, not placed - it is applied per hull facet in the
		# Armor Bay, so it has no card here. Its catalog rows still exist and
		# are still read (they are the paint types, priced per reference patch);
		# they are simply not draggable. Deliberately no legacy placement path:
		# two ways to armor a hull is exactly the drift that leaves one of them
		# silently broken. `energy_barrier_projector` is category "armor" but is
		# a projector, so it stays placeable.
		if ArmorPaint.PAINT_TYPE_IDS.has(type_id):
			continue

		if category == "hull":
			_bucket(hull_groups, _hull_group(data), type_id, data)
		elif category == "locomotion":
			loco_entries.append({"id": type_id, "data": data, "weight": float(data.get("weight", 0.0))})
		else:
			_bucket(module_groups, ModuleCatalog.get_module_role(type_id, category), type_id, data)

	_populate(hull_groups, HULL_GROUP_ORDER, "hulls")
	# Weapons roles first, then support roles with Propulsion last
	var combined_order = ModuleCatalog.MODULE_ROLE_ORDER.filter(func(r): return r in WEAPON_ROLES)
	combined_order.append_array(SUPPORT_ROLE_ORDER)
	_populate(module_groups, combined_order, "modules")
	_populate_flat(loco_entries, "locomotion")

	if _family_tabs.has("hulls"):
		_family_tabs["hulls"].button_pressed = true

	_apply_filters()
	call_deferred("_setup_armor_panel")


# --- Shell ------------------------------------------------------------------

var _dock_panel: PanelContainer
var _main_vbox: VBoxContainer
var _dock_scroll: ScrollContainer

# Gap between toolbar bottom and our dock top, and left inset from screen edge.
const DOCK_GAP := 10.0
const DOCK_LEFT_INSET := 20.0   # inset from screen edge


func _build_shell() -> void:
	# ----------------------------------------------------------------
	# UNIFIED TO THE RAIL'S FLAT INSTRUMENT LANGUAGE (Chris, design pass):
	# this dock used to be three concentric layers - a bare-steel lip, a
	# rubber gasket, and a chipped oxide-enamel "toolbox" body sampled from
	# field_toolbox.png - built to read as a mechanic's steel toolbox
	# standing on end. telemetry_rail.gd's dock at the bottom of the same
	# screen is flat dark panels with 1px hairline edges and amber-on-dark
	# type, and the two clashed hard enough that a screenshot of either did
	# not look like it belonged with the other. Direction is to bring THIS
	# dock down to THAT vocabulary, not the reverse, so the lip/gasket
	# Panels and the toolbox material are gone; `_dock_panel` alone is now
	# a single flat BASE_800 fill with a BASE_500 hairline border, exactly
	# the shape `_build_warning_panel()` and the rail's other panels use.
	#
	#   outer  (Control)          — positions the whole block
	#   └─ _dock_panel (PanelContainer) — flat panel body; children here
	# ----------------------------------------------------------------

	const TOTAL_INSET := Tokens.SPACE_SM

	# ---- 1. Outer positioner ----------------------------------------
	var outer = Control.new()
	outer.name = "ToolboxOuter"
	outer.anchor_left   = 0.0
	outer.anchor_top    = 0.0
	outer.anchor_right  = 0.0
	outer.anchor_bottom = 1.0
	outer.offset_left   = DOCK_LEFT_INSET
	outer.offset_right  = DOCK_LEFT_INSET + TOOLBOX_WIDTH
	outer.offset_top    = Tokens.TOOLBAR_HEIGHT + DOCK_GAP
	outer.offset_bottom = -DOCK_GAP
	# STOP so scroll wheel events don't fall through to the 3D camera
	outer.mouse_filter = Control.MOUSE_FILTER_STOP
	add_child(outer)

	# A STOP filter ALONE DOES NOT DO IT, which is what Chris hit on 2026-08-13:
	# scrolling the parts list also zoomed the viewport behind it.
	#
	# mouse_filter only decides whether a control is HIT by the pointer. What
	# stops an event reaching designer_camera.gd's _unhandled_input is a control
	# ACCEPTING it, and ScrollContainer accepts the wheel only when it can
	# actually scroll that direction - so at either end of the range, or with a
	# drawer short enough to fit, the wheel fell straight through to the camera.
	# From the player's side that reads as the dock randomly losing the scroll.
	#
	# Godot offers unconsumed GUI events to each ancestor control in turn, so
	# the whole dock gets one backstop here rather than needing every scrollable
	# descendant to be airtight. Children still get first refusal, which is why
	# this cannot swallow clicks meant for the tabs, the drawer headers or a
	# part card's drag.
	# Motion is swallowed too, so a right-drag that wanders over the dock does
	# not orbit the model behind it - but NOT while a part is being dragged out
	# of the bin, because that gesture starts inside this rect and has to keep
	# being tracked as it leaves.
	outer.gui_input.connect(func(event: InputEvent):
		if event is InputEventMouseButton:
			outer.accept_event()
		elif event is InputEventMouseMotion and not get_viewport().gui_is_dragging():
			outer.accept_event())

	# ---- 2. Flat instrument body panel ------------------------------
	# One flat fill, one hairline edge - the same shape the telemetry rail's
	# panels use (see telemetry_rail.gd's `_build_warning_panel` and
	# `_build_combat_profile_header`): BASE_800 body, BASE_500 border,
	# RADIUS_PANEL corners. No shader, no bevel ring, no rivets.
	_dock_panel = PanelContainer.new()
	_dock_panel.name = "Toolboxes"
	_dock_panel.anchor_left   = 0.0
	_dock_panel.anchor_top    = 0.0
	_dock_panel.anchor_right  = 1.0
	_dock_panel.anchor_bottom = 1.0
	_dock_panel.offset_left   = TOTAL_INSET
	_dock_panel.offset_top    = TOTAL_INSET
	_dock_panel.offset_right  = -TOTAL_INSET
	_dock_panel.offset_bottom = -TOTAL_INSET
	_dock_panel.mouse_filter = Control.MOUSE_FILTER_STOP

	var body_style = StyleBoxFlat.new()
	body_style.bg_color = Tokens.BASE_800
	body_style.border_color = Tokens.BASE_500
	body_style.set_border_width_all(Tokens.BORDER_HAIRLINE)
	body_style.corner_radius_top_left    = Tokens.RADIUS_PANEL
	body_style.corner_radius_top_right   = Tokens.RADIUS_PANEL
	body_style.corner_radius_bottom_left = Tokens.RADIUS_PANEL
	body_style.corner_radius_bottom_right = Tokens.RADIUS_PANEL
	body_style.content_margin_left = Tokens.SPACE_XS
	body_style.content_margin_right = Tokens.SPACE_XS
	body_style.content_margin_top = Tokens.SPACE_XS
	body_style.content_margin_bottom = Tokens.SPACE_XS
	_dock_panel.add_theme_stylebox_override("panel", body_style)
	outer.add_child(_dock_panel)

	var margin = MarginContainer.new()
	margin.add_theme_constant_override("margin_left", 8)
	margin.add_theme_constant_override("margin_right", 8)
	margin.add_theme_constant_override("margin_top", 10)
	margin.add_theme_constant_override("margin_bottom", 12)
	_dock_panel.add_child(margin)

	var layout_vbox = VBoxContainer.new()
	layout_vbox.add_theme_constant_override("separation", Tokens.SPACE_SM)
	margin.add_child(layout_vbox)

	_build_search_widget(layout_vbox)

	# Tab rows — 2×2 grid for parts + 1 full-width row for Armor
	var tabs_box = VBoxContainer.new()
	tabs_box.name = "FamilyTabs"
	tabs_box.add_theme_constant_override("separation", Tokens.SPACE_XS)
	layout_vbox.add_child(tabs_box)

	var tab_row1 = HBoxContainer.new()
	tab_row1.name = "FamilyRow1"
	tab_row1.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	tab_row1.add_theme_constant_override("separation", Tokens.SPACE_XS)
	tabs_box.add_child(tab_row1)

	var tab_row2 = HBoxContainer.new()
	tab_row2.name = "FamilyRow2"
	tab_row2.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	tab_row2.add_theme_constant_override("separation", Tokens.SPACE_XS)
	tabs_box.add_child(tab_row2)

	var tab_row3 = HBoxContainer.new()
	tab_row3.name = "FamilyRow3"
	tab_row3.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	tab_row3.add_theme_constant_override("separation", Tokens.SPACE_XS)
	tabs_box.add_child(tab_row3)

	_dock_scroll = ScrollContainer.new()
	_dock_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	_dock_scroll.vertical_scroll_mode = ScrollContainer.SCROLL_MODE_AUTO
	_dock_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	# Explicit STOP so the scroll container swallows wheel events completely
	_dock_scroll.mouse_filter = Control.MOUSE_FILTER_STOP
	layout_vbox.add_child(_dock_scroll)

	_main_vbox = VBoxContainer.new()
	_main_vbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_main_vbox.add_theme_constant_override("separation", Tokens.SPACE_SM)
	_dock_scroll.add_child(_main_vbox)

	var button_group = ButtonGroup.new()

	for tier in TIERS:
		var tier_id = tier["id"]
		
		var tier_vbox = VBoxContainer.new()
		tier_vbox.name = "Tier_" + tier_id
		tier_vbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		tier_vbox.add_theme_constant_override("separation", Tokens.SPACE_SM)
		tier_vbox.visible = false
		_main_vbox.add_child(tier_vbox)
		_family_vboxes[tier_id] = tier_vbox
		
		var tab_btn = Button.new()
		tab_btn.custom_minimum_size = Vector2(0, 32)
		tab_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		tab_btn.size_flags_vertical = Control.SIZE_EXPAND_FILL
		tab_btn.toggle_mode = true
		tab_btn.button_group = button_group
		for state in ["normal", "hover", "pressed", "focus", "disabled"]:
			tab_btn.add_theme_stylebox_override(state, StyleBoxEmpty.new())
			
		var plate = ToolboxPlateScript.new()
		plate.set_anchors_preset(Control.PRESET_FULL_RECT)
		plate.mouse_filter = Control.MOUSE_FILTER_IGNORE
		_plates_set_defaults(plate)
		tab_btn.add_child(plate)
		
		var stamp = StampedLabelScript.new()
		stamp.text = tier["label"]
		stamp.font_size = 13
		stamp.set_anchors_preset(Control.PRESET_FULL_RECT)
		plate.add_child(stamp)
		
		if tier_id == "hulls" or tier_id == "weapons":
			tab_row1.add_child(tab_btn)
		elif tier_id == "support" or tier_id == "locomotion":
			tab_row2.add_child(tab_btn)
		else:
			tab_row3.add_child(tab_btn)
		_family_tabs[tier_id] = tab_btn
		
		tab_btn.toggled.connect(func(pressed: bool):
			if pressed:
				# Active tab: lifted body, amber accent rim on bottom edge
				plate.body_color = Tokens.BASE_600
				plate.edge_color = Tokens.SIGNAL_HAZARD
				_show_family(tier_id)
			else:
				# Inactive tab: default body, no accent
				plate.body_color = Tokens.BASE_700
				plate.edge_color = Tokens.BASE_500
		)

	_empty_hint = Label.new()
	_empty_hint.text = "No parts match."
	_empty_hint.theme_type_variation = "HintLabel"
	_empty_hint.visible = false
	layout_vbox.add_child(_empty_hint)


# Stamps the chrome defaults onto a ToolboxPlate. The plate's own constructor
# sets sensible defaults from tokens, but the design lab wants a slightly
# different finish than the Skirmish build queue - same vocabulary, just a
# hair darker on the body so the busy part cards sit forward of it.
func _plates_set_defaults(plate: Control) -> void:
	plate.body_color = Tokens.BASE_700
	plate.lit_color = Tokens.BASE_500
	plate.shade_color = Tokens.BASE_900
	plate.edge_color = Tokens.BASE_500


# --- Layout -----------------------------------------------------------------

func _show_family(tier_id: String) -> void:
	var prev_family = _open_family
	for id in _family_vboxes.keys():
		_family_vboxes[id].visible = (id == tier_id)
	_open_family = tier_id

	var root = get_node_or_null("/root/MainLab")
	var armor_panel = root.get_node_or_null("UI_ArmorStationPanel") if root else null
	if tier_id == "armor":
		if armor_panel and root:
			var hull = root.hull if ("hull" in root and root.hull) else root.get_node_or_null("Hull")
			if not armor_panel.is_paint_mode and hull:
				armor_panel.enter(hull, root)
	elif prev_family == "armor":
		if armor_panel and armor_panel.is_paint_mode:
			armor_panel.exit()

func _setup_armor_panel() -> void:
	var root = get_node_or_null("/root/MainLab")
	var armor_panel = root.get_node_or_null("UI_ArmorStationPanel") if root else null
	if armor_panel and armor_panel.has_method("build_into") and _family_vboxes.has("armor"):
		armor_panel.build_into(_family_vboxes["armor"])

func select_family(tier_id: String) -> void:
	if _family_tabs.has(tier_id):
		_family_tabs[tier_id].button_pressed = true

func get_open_family() -> String:
	return _open_family

func _open_family_cross(tier_id: String) -> void:
	if _family_tabs.has(tier_id):
		_family_tabs[tier_id].button_pressed = true
	_open_family = tier_id


# --- Search widget ----------------------------------------------------------
#
# A plain LineEdit at the top of the dock. The abandoned bottom-toolbox build
# put this behind a magnifying-glass button that opened a UIFlyout; with a
# permanent left dock there is room for the field itself, and a search you can
# see is worth more than a search you have to open.

func _build_search_widget(parent: Control) -> void:
	_search_box = LineEdit.new()
	_search_box.placeholder_text = "Search parts..."
	_search_box.clear_button_enabled = true
	_search_box.custom_minimum_size = Vector2(0, Tokens.HIT_TARGET_MIN)
	_search_box.text_changed.connect(_on_search_changed)
	
	var style = StyleBoxFlat.new()
	style.bg_color = Tokens.BASE_900
	style.border_color = Tokens.BASE_500
	style.set_border_width_all(2)
	style.set_content_margin_all(8)
	_search_box.add_theme_stylebox_override("normal", style)
	_search_box.add_theme_stylebox_override("focus", style)
	
	parent.add_child(_search_box)


# --- Grouping helpers (unchanged) -------------------------------------------

func _bucket(groups: Dictionary, group: String, type_id: String, data: Dictionary) -> void:
	if not groups.has(group):
		groups[group] = []
	groups[group].append({"id": type_id, "data": data, "weight": float(data.get("weight", 0.0))})


func _hull_group(data: Dictionary) -> String:
	if data.get("is_foundation", false):
		return "Static Foundations"
	var declared := str(data.get("hull_class", "")).to_lower()
	var traits: Array = data.get("traits", [])
	if "airborne" in traits or "fixed_wing" in traits or "rotary_wing" in traits:
		return "Aerospace & Aviation"
	if declared == "scout" or declared == "light":
		return "Scout & Light Chassis"
	elif declared == "medium":
		return "Medium Battle Chassis"
	elif declared == "heavy":
		return "Heavy & Assault Chassis"
	elif declared == "transport" or declared == "oddball":
		return "Specialty & Transports"

	# Fallback by weight
	var w = float(data.get("weight", 0.0))
	if w <= ModuleCatalog.HULL_TIER_LIGHT_MAX_WEIGHT:
		return "Scout & Light Chassis"
	elif w <= ModuleCatalog.HULL_TIER_MEDIUM_MAX_WEIGHT:
		return "Medium Battle Chassis"
	return "Heavy & Assault Chassis"


func _populate_flat(entries: Array, family: String) -> void:
	# LIGHT TO HEAVY. Ties broken by name for stable ordering.
	entries.sort_custom(func(a, b):
		if is_equal_approx(a.weight, b.weight):
			return String(a.data.get("name", a.id)) < String(b.data.get("name", b.id))
		return a.weight < b.weight)

	var grid = GridContainer.new()
	grid.name = "DrivesGrid"
	grid.columns = 2
	grid.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	grid.add_theme_constant_override("h_separation", Tokens.SPACE_XS)
	grid.add_theme_constant_override("v_separation", Tokens.SPACE_XS)

	for entry in entries:
		grid.add_child(_build_part_card(entry.id, entry.data))
	grid.visible = true

	var drawer_body = PanelContainer.new()
	drawer_body.name = "DrivesBody"
	drawer_body.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	drawer_body.visible = true

	var recess_style = StyleBoxFlat.new()
	recess_style.bg_color = Tokens.BASE_900
	recess_style.corner_radius_top_left = 4
	recess_style.corner_radius_top_right = 4
	recess_style.corner_radius_bottom_left = 4
	recess_style.corner_radius_bottom_right = 4
	recess_style.border_width_top = 2
	recess_style.border_color = Color(0.0, 0.0, 0.0, 0.55)
	recess_style.content_margin_left = Tokens.SPACE_XS
	recess_style.content_margin_right = Tokens.SPACE_XS
	recess_style.content_margin_top = Tokens.SPACE_XS
	recess_style.content_margin_bottom = Tokens.SPACE_SM
	drawer_body.add_theme_stylebox_override("panel", recess_style)
	drawer_body.add_child(grid)

	var section = VBoxContainer.new()
	section.name = "Drives_All"
	section.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	section.add_child(drawer_body)

	section.set_meta("drawer_category", "Drives")
	section.set_meta("drawer_tab", family)
	section.set_meta("drawer_open", true)
	section.set_meta("content_container", grid)
	section.set_meta("family", family)
	section.set_meta("tier", family)
	section.set_meta("is_flat", true)

	_family_tier_body(family).add_child(section)
	_all_drawers.append(section)


# --- Construction -----------------------------------------------------------

func _populate(groups: Dictionary, order: Array, family: String) -> void:
	# Any group the catalog produced that the order array doesn't name still
	# gets shown, appended after the known ones. Same reasoning as
	# get_module_role()'s fallback: an unlisted group must be visible, not
	# silently dropped.
	var seen: Dictionary = {}
	var ordered := []
	for g in order:
		if groups.has(g):
			ordered.append(g)
			seen[g] = true
	for g in groups.keys():
		if not seen.has(g):
			ordered.append(g)

	for group in ordered:
		var entries: Array = groups[group]
		# LIGHT TO HEAVY. Ties broken by name so the order is stable across
		# runs - Dictionary.keys() order is insertion order, not sorted, and an
		# unstable sidebar is genuinely disorienting to browse.
		entries.sort_custom(func(a, b):
			if is_equal_approx(a.weight, b.weight):
				return String(a.data.get("name", a.id)) < String(b.data.get("name", b.id))
			return a.weight < b.weight)

		var cards := []
		for entry in entries:
			cards.append(_build_part_card(entry.id, entry.data))
		var tier_id := _tier_for(family, group)
		var section = _make_section(group, cards, family)
		# The toolbox this group is filed under, kept separate from the `family`
		# meta above - see the TIERS comment for why the two axes differ.
		section.set_meta("tier", tier_id)
		# Into the family's own tier body, which is what makes the hierarchy
		# structural. _all_drawers still gets every section, so sections_for()
		# and the test suites are unaffected by the re-parenting.
		_family_tier_body(tier_id).add_child(section)
		_all_drawers.append(section)


# A part card. Compact, gridded, and carrying its weight inline.
#
# Styling comes from the THEME (moulded plates, from tools/build_ui_theme.gd),
# not from a local StyleBoxFlat. The previous version hand-rolled four
# styleboxes per card here, which duplicated what the theme already builds for
# Button and - because local overrides beat the theme - actively prevented the
# design system from reaching the single most numerous control in the game.
# The only per-part colour left is the catalog accent, as a thin left stripe.
func _build_part_card(type_id: String, data: Dictionary) -> Button:
	var btn = Button.new()
	btn.set_script(preload("res://scripts/part_button.gd"))
	btn.module_type_id = type_id
	btn.custom_minimum_size = Vector2(CARD_MIN_WIDTH, CARD_HEIGHT)
	btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	btn.focus_mode = Control.FOCUS_NONE

	# Clear out the normal button styling completely so it's just a transparent hit target
	for state in ["normal", "hover", "pressed", "focus", "disabled"]:
		btn.add_theme_stylebox_override(state, StyleBoxEmpty.new())
		
	# The Spore-style item grid
	var vbox = VBoxContainer.new()
	vbox.set_anchors_preset(Control.PRESET_FULL_RECT)
	vbox.add_theme_constant_override("separation", 2)
	vbox.mouse_filter = Control.MOUSE_FILTER_IGNORE
	btn.add_child(vbox)

	# 1. Top space for the 3D rendered icon (drag out)
	var icon_rect = ColorRect.new()
	icon_rect.color = Color(0, 0, 0, 0.2) # Dim placeholder for 3D render
	icon_rect.size_flags_vertical = Control.SIZE_EXPAND_FILL
	icon_rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
	vbox.add_child(icon_rect)
	
	# Actual TextureRect for the 3D model thumbnail
	var icon_tex = TextureRect.new()
	icon_tex.name = "Thumbnail"
	icon_tex.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	icon_tex.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	icon_tex.set_anchors_preset(Control.PRESET_FULL_RECT)
	icon_tex.mouse_filter = Control.MOUSE_FILTER_IGNORE
	icon_rect.add_child(icon_tex)
	btn.set_meta("thumbnail_rect", icon_tex)
	var slot_icon := TextureRect.new()
	slot_icon.name = "SlotModuleIcon"
	slot_icon.texture = UITheme.industrial_icon("slot_module")
	slot_icon.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	slot_icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	slot_icon.custom_minimum_size = Vector2(Tokens.SPINE_ICON, Tokens.SPINE_ICON)
	slot_icon.size = Vector2(Tokens.SPINE_ICON, Tokens.SPINE_ICON)
	slot_icon.position = Vector2(Tokens.SPACE_XS, Tokens.SPACE_XS)
	slot_icon.modulate = Tokens.TEXT_SECONDARY
	slot_icon.mouse_filter = Control.MOUSE_FILTER_IGNORE
	icon_rect.add_child(slot_icon)
	
	# The catalog accent as a painted stripe inside the icon area
	var stripe = ColorRect.new()
	stripe.color = data["color"]
	stripe.custom_minimum_size = Vector2(4, 0)
	stripe.set_anchors_preset(Control.PRESET_LEFT_WIDE)
	stripe.mouse_filter = Control.MOUSE_FILTER_IGNORE
	icon_rect.add_child(stripe)

	# 2. Bottom tag — stamped metal label, sized to be readable
	var tag_rect = ColorRect.new()
	tag_rect.color = Tokens.BASE_900
	tag_rect.custom_minimum_size = Vector2(0, 34)
	tag_rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
	vbox.add_child(tag_rect)

	var name_lbl = Label.new()
	name_lbl.text = data["name"]
	name_lbl.add_theme_font_size_override("font_size", Tokens.FONT_SMALL)
	name_lbl.add_theme_color_override("font_color", Tokens.TEXT_PRIMARY)
	name_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	name_lbl.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	# TRIM_ELLIPSIS, not clip_text. clip_text truncates from both the left AND
	# right of a centered label once the text overflows ("Rocker-Bogie
	# Suspension" rendered as "cker-Bogie Suspensi") - unreadable either way.
	# Ellipsising keeps the label anchored at its natural start and only
	# truncates the tail, so a long name is still identifiable.
	name_lbl.clip_text = false
	name_lbl.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	name_lbl.autowrap_mode = TextServer.AUTOWRAP_OFF
	name_lbl.set_anchors_preset(Control.PRESET_FULL_RECT)
	name_lbl.mouse_filter = Control.MOUSE_FILTER_IGNORE
	tag_rect.add_child(name_lbl)
	
	# Focus ring for hover
	var focus_ring = ReferenceRect.new()
	focus_ring.border_width = 2.0
	focus_ring.editor_only = false
	focus_ring.visible = false
	focus_ring.set_anchors_preset(Control.PRESET_FULL_RECT)
	focus_ring.mouse_filter = Control.MOUSE_FILTER_IGNORE
	btn.add_child(focus_ring)
	
	btn.mouse_entered.connect(func():
		focus_ring.visible = true
		part_hovered.emit(type_id))
	btn.mouse_exited.connect(func():
		focus_ring.visible = false
		part_unhovered.emit())

	if data.get("category", "") == "hull":
		var size = data.get("size", Vector3.ZERO)
		var domain = "Static Building" if data.get("is_foundation", false) else "Vehicle"
		btn.tooltip_text = "%s
%s hull
HP: %.0f | Weight: %.0f
Cost: %d Metal, %d Crystal
Size: %.1f x %.1f x %.1f" % [
			data["name"], domain, data.get("hp", 0.0), data.get("weight", 0.0),
			data.get("metal", 0), data.get("crystal", 0),
			size.x, size.y, size.z]
	else:
		btn.tooltip_text = _stat_tooltip(data, type_id)

	btn.set_meta("search_key", ("%s %s" % [data.get("name", ""), type_id]).to_lower())
	return btn


# A titled group of cards — styled as a physical drawer handle.
# The header is a knurled-metal bar, lighter than the family tabs above,
# with the category name stamped on it and a count badge at the right.
func _make_section(category: String, cards: Array, family: String) -> Control:
	var section = VBoxContainer.new()
	section.name = "Drawer_%s" % category.replace(" ", "_").replace("&", "and")
	section.size_flags_horizontal = Control.SIZE_EXPAND_FILL

	var header_btn = Button.new()
	header_btn.custom_minimum_size = Vector2(0, 38)  # taller = more physical handle feel
	header_btn.focus_mode = Control.FOCUS_NONE
	header_btn.toggle_mode = true
	header_btn.button_pressed = false
	for state in ["normal", "hover", "pressed", "focus", "disabled"]:
		header_btn.add_theme_stylebox_override(state, StyleBoxEmpty.new())

	# Flat drawer header, matching the rail's panel language rather than a
	# knurled physical handle: BASE_700 fill, BASE_500 hairline edge, amber
	# left accent when the drawer would be selected. No shader, no bevel -
	# "minimal texture" per the unify-toward-flat-instrument direction.
	var handle_panel = PanelContainer.new()
	handle_panel.set_anchors_preset(Control.PRESET_FULL_RECT)
	handle_panel.mouse_filter = Control.MOUSE_FILTER_IGNORE

	var handle_style = StyleBoxFlat.new()
	handle_style.bg_color = Tokens.BASE_700
	handle_style.corner_radius_top_left = Tokens.RADIUS_PANEL
	handle_style.corner_radius_top_right = Tokens.RADIUS_PANEL
	handle_style.corner_radius_bottom_left = Tokens.RADIUS_PANEL
	handle_style.corner_radius_bottom_right = Tokens.RADIUS_PANEL
	handle_style.border_color = Tokens.BASE_500
	handle_style.set_border_width_all(Tokens.BORDER_HAIRLINE)
	handle_style.border_width_bottom = Tokens.BORDER_EMPHASIS
	handle_style.set_content_margin_all(0)
	handle_panel.add_theme_stylebox_override("panel", handle_style)
	header_btn.add_child(handle_panel)

	# Row inside the handle: label on left, count on right
	var inner_row = HBoxContainer.new()
	inner_row.set_anchors_preset(Control.PRESET_FULL_RECT)
	inner_row.add_theme_constant_override("separation", 4)
	inner_row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	handle_panel.add_child(inner_row)

	var pad_left = Control.new()
	pad_left.custom_minimum_size = Vector2(8, 0)
	pad_left.mouse_filter = Control.MOUSE_FILTER_IGNORE
	inner_row.add_child(pad_left)

	# Category name — amber-on-dark, matching the rail's HeadingLabel role.
	var name_label = Label.new()
	name_label.text = category.to_upper()
	name_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	name_label.size_flags_vertical = Control.SIZE_EXPAND_FILL
	name_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	name_label.add_theme_font_size_override("font_size", Tokens.FONT_SMALL)
	name_label.add_theme_color_override("font_color", Tokens.SIGNAL_HAZARD)
	name_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	inner_row.add_child(name_label)

	# Count badge — secondary text token, right-aligned
	var count_label = Label.new()
	count_label.text = str(cards.size())
	count_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	count_label.size_flags_vertical = Control.SIZE_EXPAND_FILL
	count_label.add_theme_font_size_override("font_size", Tokens.FONT_MICRO)
	count_label.add_theme_color_override("font_color", Tokens.TEXT_SECONDARY)
	count_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	inner_row.add_child(count_label)

	var pad_right = Control.new()
	pad_right.custom_minimum_size = Vector2(8, 0)
	pad_right.mouse_filter = Control.MOUSE_FILTER_IGNORE
	inner_row.add_child(pad_right)

	section.add_child(header_btn)

	var grid = GridContainer.new()
	grid.columns = 2
	grid.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	grid.add_theme_constant_override("h_separation", Tokens.SPACE_XS)
	grid.add_theme_constant_override("v_separation", Tokens.SPACE_XS)
	for c in cards:
		grid.add_child(c)
	grid.visible = false

	# The open drawer's interior: a dark grimy recess the cards sit INSIDE.
	#
	# TWO BUGS DIED HERE, and together they are why an opened drawer looked
	# broken rather than merely plain.
	#
	# 1. The body was a bare Control. A Control is not a Container: it computes
	#    no minimum size from its children, so inside this VBoxContainer it was
	#    allotted ZERO height no matter how many cards it held. The grid then
	#    drew outside its parent's rect, overlapping the next drawer's header,
	#    and the VBox reserved no room for it. PanelContainer is the fix - it
	#    both draws the recess and propagates the grid's minimum size, so the
	#    drawer actually pushes its siblings down when it opens.
	#
	# 2. The grime was added AFTER the grid, i.e. ON TOP of it, as a full-rect
	#    ColorRect at 0.82 alpha. Every part card in an open drawer was sitting
	#    under an almost-opaque brown sheet. It only escaped notice because bug 1
	#    collapsed the overlay to zero size too - fixing the layout alone would
	#    have made an invisible overlay suddenly visible and hidden the cards.
	#    The recess is a STYLEBOX BEHIND the cards now, which is what it always
	#    wanted to be.
	var drawer_body = PanelContainer.new()
	drawer_body.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	drawer_body.visible = false

	var recess_style = StyleBoxFlat.new()
	recess_style.bg_color = Tokens.BASE_900
	recess_style.corner_radius_bottom_left = 4
	recess_style.corner_radius_bottom_right = 4
	# Inner shadow read: the drawer interior is sunk into the box, so its top
	# edge is the darkest line on the panel.
	recess_style.border_width_top = 2
	recess_style.border_color = Color(0.0, 0.0, 0.0, 0.55)
	recess_style.content_margin_left = Tokens.SPACE_XS
	recess_style.content_margin_right = Tokens.SPACE_XS
	recess_style.content_margin_top = Tokens.SPACE_XS
	recess_style.content_margin_bottom = Tokens.SPACE_SM
	drawer_body.add_theme_stylebox_override("panel", recess_style)

	section.add_child(drawer_body)
	drawer_body.add_child(grid)

	# The recess follows the GRID's visibility rather than being switched
	# alongside it. `content_container` (the grid) is the drawer metadata
	# contract - _open_category, _apply_filters, collapse_all_drawers and
	# reveal_part all reach in and set grid.visible directly, and the test
	# suites walk the same meta. Mirroring here means every one of those paths
	# keeps working untouched; switching drawer_body at each call site instead
	# would be five places to forget, and forgetting one leaves either an empty
	# recess strip under a closed drawer or an open drawer with no backing.
	grid.visibility_changed.connect(func():
		drawer_body.visible = grid.visible)

	section.set_meta("drawer_category", category)
	section.set_meta("drawer_tab", family)
	section.set_meta("drawer_open", false)
	section.set_meta("header_btn", header_btn)
	section.set_meta("content_container", grid)
	section.set_meta("family", family)

	header_btn.toggled.connect(func(pressed: bool):
		grid.visible = pressed
		if pressed:
			_open_category(section)
			UIAnim.stagger_in(grid)
		else:
			section.set_meta("drawer_open", false))
	UIFeedbackScript.wire(header_btn, "select")

	return section


# --- Tier routing -----------------------------------------------------------

# Presentation tier for a (category, group) pair. Only "modules" splits, into
# Weapons, Propulsion (routed to the Drives toolbox, alongside the locomotion
# types these parts modify - see DRIVE_ROLES) and Support - see the TIERS and
# WEAPON_ROLES comments for why that is a presentation decision rather than a
# reclassification.
func _tier_for(family: String, group: String) -> String:
	if family != "modules":
		return family
	# Propulsion is now grouped with Support
	return "weapons" if group in WEAPON_ROLES else "support"


# Returns the VBoxContainer (under the panel's ScrollContainer) that
# sections of this family are added to. Lazily creates the family's chrome
# the first time a section asks - in practice all four families are
# seeded in _build_shell, so this is just a defensive null check.
func _family_tier_body(tier_id: String) -> VBoxContainer:
	if _family_vboxes.has(tier_id):
		return _family_vboxes[tier_id]
	return _main_vbox


# Opens a family tier in the cross-toolbox sense, used by search and by
# reveal_part(). With the new layout, this is just _open_family_cross
# under a more domain-specific name.
func _force_open_family(tier_id: String) -> void:
	_open_family_cross(tier_id)


# Opens one category drawer and closes its siblings within the same toolbox.
func _open_category(section: Control) -> void:
	var tier_id := str(section.get_meta("tier", ""))
	for other in _all_drawers:
		if not is_instance_valid(other):
			continue
		if str(other.get_meta("tier", "")) != tier_id:
			continue
		if other.has_meta("is_flat") and other.get_meta("is_flat"):
			continue
		var is_target: bool = other == section
		var grid: Control = other.get_meta("content_container")
		if other.has_meta("header_btn"):
			var header: Button = other.get_meta("header_btn")
			header.set_pressed_no_signal(is_target)
		grid.visible = is_target
		other.set_meta("drawer_open", is_target)


# --- Filtering --------------------------------------------------------------

func _on_search_changed(new_text: String) -> void:
	_filter = new_text.strip_edges().to_lower()
	_apply_filters()


# One pass that applies the search text.
#
# The previous build also ran a family filter here; with the four toolboxes
# that axis is structural rather than a control, so there is nothing to
# apply at the search level. The filter collapses a part's visibility;
# whether its section's grid is open or closed is the section's own
# responsibility, and the search's job is to find the section.
func _apply_filters() -> void:
	var any_visible := false

	for section in _all_drawers:
		if not is_instance_valid(section):
			continue

		var grid: Node = section.get_meta("content_container")
		var matches := 0
		for card in grid.get_children():
			var hit := _filter == "" or String(card.get_meta("search_key", "")).contains(_filter)
			card.visible = hit
			if hit:
				matches += 1

		# A section with nothing in it is hidden entirely rather than left as
		# an empty header - a column of dead headers reads as "the search
		# broke" rather than "no hits in this group".
		section.visible = matches > 0
		if matches > 0:
			any_visible = true
			# While filtering, force the surviving sections open. Making the
			# player click a header to see the thing they just searched for
			# would defeat the search.
			if _filter != "":
				grid.visible = true
				if section.has_meta("header_btn"):
					section.get_meta("header_btn").set_pressed_no_signal(true)
				section.set_meta("drawer_open", true)
				# The family tier above it has to open too, or the match is
				# revealed inside a closed family and stays invisible. The
				# cross-toolbox accordion means the matching family closes
				# the others, which is the right read: "the search found
				# something, here it is, in this family".
				_force_open_family(str(section.get_meta("tier", "")))

	if _empty_hint:
		_empty_hint.visible = not any_visible and _filter != ""


# --- Introspection ----------------------------------------------------------

# Every group section belonging to one family ("hulls" | "modules" |
# "locomotion").
#
# This exists so the grouping suites in run_tests.gd have a stable way in.
# They used to reach through a hardcoded node path
# ("PanelContainer/VBoxContainer/TabContainer/Hulls/VBoxContainer"), which
# coupled tests about CATALOG DATA - do modules group by their own role, do
# hulls group by their own weight class - to the widget tree that happened to
# display it. Rebuilding the panel then broke tests that had no opinion about
# panels. Asking the panel a question instead keeps those suites testing the
# thing they are actually about.
func sections_for(family: String) -> Array:
	var out: Array = []
	for section in _all_drawers:
		if is_instance_valid(section) and section.get_meta("family", "") == family:
			out.append(section)
	return out


# The dock this panel lives in, for callers that need to expand it.
#
# RETURNS NULL. The bottom toolboxes are not a UIDock; they have no
# collapse-to-rail state, no auto-hide, and no per-instance expansion. Any
# caller that used to expand the dock to make a part visible should call
# reveal_part() instead, which handles the cross-toolbox accordion for them.
func get_dock() -> Control:
	return null


# The screen rect the catalogue occupies, for the tutorial to spotlight.
#
# THIS WAS RETURNING AN EMPTY RECT ON EVERY CALL. It walked _family_widgets,
# a dictionary the abandoned bottom-toolbox build populated and this one never
# writes to, so `_family_widgets.is_empty()` was always true. The two-phase
# tutorial's overlay treats an empty rect as "target not resolvable, draw no
# hole at all" (two_phase_tutorial_overlay.gd:36), so the failure was silent:
# the tutorial step that points at the parts bin simply pointed at nothing.
#
# The dock is one rect, so it is now read straight off the outer positioner
# rather than reconstructed from per-family plates that no longer exist.
#
# Still returns an empty Rect2 before _build_shell has run, which is the signal
# the tutorial already knows how to handle.
func get_bar_focus_rect() -> Rect2:
	var outer := get_node_or_null("ToolboxOuter") as Control
	if outer == null or not is_instance_valid(outer):
		return Rect2()
	return outer.get_global_rect()


# Opens the catalogue down to one specific part and hands back its card.
#
# Written for the tutorial, which has to point at "the Medium Hull" when the
# family containing it is closed and the sub-family drawer is closed. Returns
# null for an unknown type_id rather than asserting, so a step naming a part
# that has since been retired from the catalog degrades to "no spotlight"
# instead of taking the screen down.
#
# Built entirely on the existing drawer metadata contract (see _make_section) so
# it cannot drift from how the panel actually works.
func reveal_part(type_id: String) -> Button:
	for section in _all_drawers:
		if not is_instance_valid(section):
			continue
		var grid: Control = section.get_meta("content_container")
		for card in grid.get_children():
			if not (card is Button) or card.module_type_id != type_id:
				continue
			# Open the family first - the cross-toolbox accordion means
			# the other three close, which is fine because the tutorial
			# only ever needs one family visible at a time.
			_force_open_family(str(section.get_meta("tier", "")))
			# Through the header's toggle rather than _open_category() directly,
			# so the drawer's own accordion and its pressed state stay in step.
			if section.has_meta("header_btn"):
				var header: Button = section.get_meta("header_btn")
				if not header.button_pressed:
					header.button_pressed = true
			return card
	return null


# --- Compatibility ----------------------------------------------------------

func collapse_all_drawers() -> void:
	for section in _all_drawers:
		if is_instance_valid(section):
			if section.has_meta("is_flat") and section.get_meta("is_flat"):
				continue
			if section.has_meta("header_btn"):
				section.get_meta("header_btn").button_pressed = false
			section.get_meta("content_container").visible = false
			section.set_meta("drawer_open", false)
	open_drawer_hulls = ""
	open_drawer_modules = ""
	open_drawer_locomotion = ""


# NOTE: line 0 is the part NAME, and that is load-bearing - part_button.gd's
# _make_custom_tooltip() renders the first line as the card's bold gold title
# row and every line after it as a smaller stat row.
func _stat_tooltip(data: Dictionary, type_id: String = "") -> String:
	var lines = [data.get("name", "Unknown Part")]
	if type_id.is_empty():
		type_id = data.get("type_id", "")
	lines.append("HP: %.0f | Weight: %.0f kg" % [data.get("hp", 0.0), data.get("weight", 0.0)])
	lines.append("Cost: %d Metal, %d Crystal" % [data.get("metal", 0), data.get("crystal", 0)])

	var category: String = data.get("category", "")

	# Weapons & Projectiles
	var dps = float(data.get("dps", 0.0))
	var fp = ModuleCatalog.get_fire_profile(type_id)
	var reach = float(fp.get("fire_range", 0.0))
	var fire_rate = float(fp.get("fire_rate", 0.0))
	if dps > 0.0:
		var tier = ModuleCatalog.get_range_tier_label(reach)
		var dmg_per_shot = dps * fire_rate
		lines.append("DPS: %.0f | Dmg/Shot: %.0f" % [dps, dmg_per_shot])
		lines.append("Cycle: %.2fs | Range: %.0fm (%s)" % [fire_rate, reach, tier])
	elif category == "weapon" and reach > 0.0:
		var tier = ModuleCatalog.get_range_tier_label(reach)
		lines.append("Range: %.0fm (%s) | Cycle: %.2fs" % [reach, tier, fire_rate])

	# Locomotion stats
	if category == "locomotion":
		var speed = float(data.get("base_top_speed", 0.0))
		var capacity = float(data.get("base_weight_capacity", 0.0))
		if speed > 0.0 or capacity > 0.0:
			lines.append("Top Speed: %.1f m/s | Capacity: %.0f kg" % [speed, capacity])
		var traits: Array = data.get("traits", [])
		if not traits.is_empty():
			var trait_strs: Array = []
			for t in traits:
				trait_strs.append(str(t).replace("_", " ").capitalize())
			lines.append("Mobility: %s" % ", ".join(trait_strs))

	# Support & Repair
	var heal_rate = float(data.get("heal_rate", 0.0))
	if heal_rate > 0.0:
		lines.append("Repair Rate: +%.1f HP/s" % heal_rate)

	# Sensors & Recon
	var vision = float(data.get("vision_bonus", 0.0))
	if vision > 0.0:
		lines.append("Vision Bonus: +%.0fm" % vision)
	var scan_arc = float(data.get("scan_arc", 0.0))
	if scan_arc > 0.0:
		lines.append("Scan Sector: %.0f° Forward" % scan_arc)

	# Power & Energy
	var gen = float(data.get("energy_regen", 0.0))
	if gen <= 0.0:
		gen = float(data.get("power_output", 0.0))
	if gen > 0.0:
		lines.append("Power Gen: +%.1f kW" % gen)

	var cap = float(data.get("energy_capacity", 0.0))
	if cap > 0.0:
		lines.append("Power Storage: %.0f kJ" % cap)

	var p_draw = float(data.get("power_draw", 0.0))
	if p_draw > 0.0:
		lines.append("Power Draw: -%.1f kW" % p_draw)

	# Rocket Boosters
	if data.has("boost"):
		var b: Dictionary = data["boost"]
		var mult = float(b.get("speed_mult", 1.0))
		var dur = float(b.get("duration", 0.0))
		var cd = float(b.get("cooldown", 0.0))
		lines.append("Sprint Boost: +%.0f%% Speed (%.1fs duration, %.0fs cd)" % [(mult - 1.0) * 100.0, dur, cd])

	# Shields & Forcefields
	if data.has("default_tweaks"):
		var tweaks: Dictionary = data["default_tweaks"]
		if tweaks.has("barrier_capacity"):
			lines.append("Energy Barrier: Absorbs incoming projectile/beam damage")

	return "\n".join(lines)
