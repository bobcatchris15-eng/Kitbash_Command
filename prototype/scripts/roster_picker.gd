extends VBoxContainer
class_name RosterPicker
# Drag-and-drop roster selection: a library of saved designs on top, a fixed
# grid of roster slots below, drag a design into a slot to field it.
#
# REPLACES a flat list of CheckBoxes. Two things that list could not express:
#
#   1. ORDER. The old flow collected checked paths in list order and skirmish.gd
#      took the first 12, so which designs actually made it in was a function of
#      how the library happened to be sorted. A slot grid makes position explicit
#      and intentional.
#   2. THE CAP. ROSTER_CAP was a number in a warning string. Twelve visible
#      wells, filling up as you drag, is the same information as a spatial fact.
#
# The output contract is unchanged: ordered_paths() returns what the old
# checkbox loop returned, so match_setup.gd's _on_start_pressed() still writes a
# plain Array of paths into MatchConfig.selected_blueprint_paths.

const Tokens = preload("res://scripts/ui_tokens.gd")
const UIAnimScript = preload("res://scripts/ui_anim.gd")
const BlueprintThumbnailScript = preload("res://scripts/blueprint_thumbnail.gd")
const UIFeedbackScript = preload("res://scripts/ui_feedback.gd")
const DamageResolverScript = preload("res://scripts/damage_resolver.gd")
const DesignCostingScript = preload("res://scripts/battle/economy/design_costing.gd")
const ModuleCatalog = preload("res://scripts/module_catalog.gd")

static var _thumbnail_cache: Dictionary = {}
static var _stats_cache: Dictionary = {}

# The drag payload's type tag. Namespaced because _can_drop_data() is called for
# EVERY drag that passes over a slot, including part drags from the Design Lab if
# these controls are ever reused there - an untagged payload would be accepted.
const DRAG_TYPE = "roster_blueprint"

const HARVESTER_SLOT_INDEX = 11  # 0-indexed: slot 12 of 12

# Defence loadout. Separate from the unit roster because these are placed on
# the map during the match rather than produced from a manufactory queue, so
# spending unit slots on them would price two unrelated things against each
# other.
const BUILDING_CAPACITY = 4

# Slot kinds. Replaces the old `index == HARVESTER_SLOT_INDEX` special case:
# with a third category that test does not generalise, and a slot that knows
# what it accepts can say so in its own tooltip and reject a bad drop without
# the picker having to special-case indices.
enum SlotKind { UNIT, HARVESTER, BUILDING }

# Card tint colors. Harvesters get green, repair units get blue, defences
# amber. These are light washes applied to the card background so the card
# reads as a CATEGORY at a glance without obscuring the thumbnail or stat text.
const HARVESTER_TINT := Color(0.15, 0.30, 0.12, 0.45)
const REPAIR_TINT := Color(0.12, 0.18, 0.30, 0.45)
const BUILDING_TINT := Color(0.30, 0.24, 0.10, 0.45)

# --- Surfaces -------------------------------------------------------------
#
# Playtest: "it feels too dark without enough lightness or contrast in here."
# The screen was three values of near-black - page, tray and card sat within
# about 0.07 of each other in linear terms - so nothing read as raised and the
# whole tray looked like one flat sheet with text on it.
#
# These are a deliberate LADDER with real gaps between the rungs: the tray
# recedes, the card sits on it, the card's edge catches light. Local constants
# rather than new tokens because this is one screen's surface treatment, and
# ui_tokens.gd's BASE_ ramp is shared with the Design Lab and the HUD-adjacent
# chrome that both want to stay darker than this.
const SURFACE_TRAY := Color(0.128, 0.126, 0.117, 1.0)
const SURFACE_CARD := Color(0.212, 0.206, 0.190, 1.0)
const SURFACE_EDGE := Color(0.365, 0.354, 0.325, 1.0)
const SURFACE_RADIUS := 3
# How far a category tint pulls the card off SURFACE_CARD. Low on purpose: the
# tint is a category cue, and at full strength it swamped the value ladder
# above - a tinted card stopped reading as the same KIND of object as an
# untinted one, which is what made the harvester strip look like a different
# widget.
const TINT_STRENGTH := 0.55

# Category ICONS, from the out-of-match registry (scripts/ui_icons.gd ->
# assets/icons/). Deliberately NOT scripts/hud/hud_icons.gd: that set is the
# in-match HUD's own vocabulary and CLAUDE.md keeps the two languages apart.
#
# A tint alone was not enough. It tells you two cards differ, but not what the
# difference IS, and it disappears entirely on the empty reserved slot where
# the player most needs to know what belongs there. The icon carries the
# meaning; the tint stays as reinforcement.
const ICON_HARVESTER := "extractor"
const ICON_REPAIR := "repair"
const ICON_BUILDING := "defense"
const CARD_BADGE_SIZE := Vector2(22, 22)
const SLOT_GHOST_SIZE := Vector2(30, 30)
# The empty-slot ghost is the same glyph as the card badge at low alpha - the
# slot is showing you what it is waiting for, so it must be recognisably the
# same mark, just not competing with a filled slot's thumbnail.
const SLOT_GHOST_ALPHA := 0.32

# ---------------------------------------------------------------------------
# THE TILE VARIANT TABLE - one card implementation, four (now five) variants.
# ---------------------------------------------------------------------------
# Before this, a library card, a filled slot and an empty well each built their
# own surface, their own tint decision and their own badge row, and the three
# had already drifted (different borders, different padding, a badge on one and
# a ghost glyph on another for the same category). A fifth kind would have been
# a fourth hand-styled copy.
#
# Now there is ONE surface builder (tile_style) and ONE glyph/label lookup
# (variant_def), both keyed off a variant name. Adding a variant - a commander
# unit, an aircraft well, whatever - is an entry in this dictionary plus a
# clause in variant_for_path(). It is a DATA change; no drawing code moves.
#
# `tint` is the category wash, `icon` the UIIcons registry name (degrades to no
# badge when absent), `label` the empty-well legend, `tip` the badge tooltip.
const TILE_VARIANTS := {
	"unit": {
		"tint": Color(0, 0, 0, 0), "icon": "", "label": "",
		"tip": "Combat design - fits any unit slot",
	},
	"harvester": {
		"tint": HARVESTER_TINT, "icon": ICON_HARVESTER, "label": "HARVESTER",
		"tip": "Harvester - can gather resources",
	},
	"defence": {
		"tint": BUILDING_TINT, "icon": ICON_BUILDING, "label": "DEFENCE",
		"tip": "Defensive building - placed on the map during the match",
	},
	"support": {
		"tint": REPAIR_TINT, "icon": ICON_REPAIR, "label": "SUPPORT",
		"tip": "Support - carries a repair array",
	},
	"empty": {
		"tint": Color(0, 0, 0, 0), "icon": "", "label": "",
		"tip": "Empty slot",
	},
}

# The three surface STATES a variant can be rendered in. Separated from the
# variant so a harvester reads as the same category whether it is a library
# card, a filled well or the empty well reserved for it - only the surface
# changes, never the hue.
const TILE_STATES := {
	"card": {"recess": false, "margin": 8, "tint_mult": 1.0},
	"slot_filled": {"recess": false, "margin": 4, "tint_mult": 1.0},
	# Half tint on an empty well: enough to say "this well belongs to a
	# category" without competing with the ghost glyph sharing the recess.
	"slot_empty": {"recess": true, "margin": 4, "tint_mult": 0.5},
}


static func variant_def(variant: String) -> Dictionary:
	return TILE_VARIANTS.get(variant, TILE_VARIANTS["unit"])


# Variant from the ENTRY FLAGS the blueprint manager already resolved. Order is
# load-bearing and matches _category_of(): a foundation-hull design carrying a
# harvester module is a static extractor, so defensive wins.
static func variant_for_entry(entry: Dictionary) -> String:
	if entry.get("is_defensive", false):
		return "defence"
	if entry.get("is_harvester", false):
		return "harvester"
	if entry.get("has_repair", false):
		return "support"
	return "unit"


# The one surface builder. Every tile on this screen - card, filled well, empty
# well - comes out of here, so two tiles can differ in hue and in depth but
# never in border weight, radius or padding.
static func tile_style(variant: String, state: String) -> StyleBoxFlat:
	var v := variant_def(variant)
	var st: Dictionary = TILE_STATES.get(state, TILE_STATES["card"])
	var tint: Color = v["tint"]
	tint.a *= float(st["tint_mult"])
	var fill: Color = SURFACE_TRAY.darkened(0.28) if st["recess"] else SURFACE_CARD
	var edge: Color = SURFACE_EDGE.darkened(0.35) if st["recess"] else SURFACE_EDGE
	return surface_style(tint, fill, edge, int(st["margin"]))


# Maps a slot kind onto the variant its EMPTY state advertises. A general unit
# well announces nothing (it takes almost anything); the two reserved kinds do.
static func variant_for_kind(kind: int) -> String:
	match kind:
		SlotKind.HARVESTER: return "harvester"
		SlotKind.BUILDING: return "defence"
		_: return "empty"

	# A FLOOR, not a fixed size. The slots expand to share the full width of the
	# tray (see _build_slot_grid), so this only sets how small one is allowed to get
	# on a narrow window. Raised from 96x78: at that height the thumbnail had barely
	# 56px left under the name line, which is not enough to tell two similar
	# kitbashes apart at a glance - the entire job of the slot.
const SLOT_SIZE = Vector2(104, 132)
# Library card height. Tall enough for thumbnail + wrapped name + four-line spec
# block. Kept at 240 so two library strips (combat + harvester) plus the slot
# grid all fit on a 900px viewport without scrolling the parent VBoxContainer.
const CARD_SIZE = Vector2(176, 268)
# Tall enough for the thumbnail plus a wrapped name plus a four-line spec block.
# The first version was 120x104 and forced the name to a single ellipsised line,
# which is the worst thing to truncate on a card whose whole job is telling two
# similar kitbashes apart.
#
# WIDTH is set by the padding, not by the text. CardPanel's content margins are
# SPACE_XL horizontal (32 a side, so 64 total), which left a 136px card with only
# 72px of usable width - not enough for a padded monospace line like "HP     420"
# at FONT_SMALL. 176 gives ~112px of content.
#
# HEIGHT is a floor, not a cap: the VBox sizes to its content, so this only has to
# be large enough that the ScrollContainer below does not clip a card whose name
# wrapped to three lines. thumbnail 92 + wrapped name ~34 + four stat lines ~68 +
# separations 12 + 40 of vertical padding is ~246, so 268 leaves plenty of headroom.
const CARD_THUMB_H = 92
# The drag ghost stays compact deliberately - it is not a card, it is a token of
# one. A full spec block following the cursor obscures the wells it is about to
# land in, and the player has already read the stats before starting the drag.
const DRAG_PREVIEW_SIZE = Vector2(112, 96)

signal roster_changed()

# Plain Array, not Array[RosterSlot]: GDScript will not accept an inner class as
# a typed array's element type, and the parse error it raises names the line
# rather than the reason.
var _slots: Array = []            # unit roster slots (kind UNIT / HARVESTER)
var _building_slots: Array = []   # defence loadout slots (kind BUILDING)
var _baker: BlueprintThumbnail = null
var _slot_grid: GridContainer = null
var _building_grid: GridContainer = null
var _library_row: HBoxContainer = null
var _harvester_row: HBoxContainer = null
var _building_row: HBoxContainer = null
var _counter: Label = null
var _capacity: int = 12
var _data_by_path: Dictionary = {}
var _harvester_paths: Dictionary = {}  # path -> entry, for slot validation
var _building_paths: Dictionary = {}   # path -> entry, for slot validation
var _repair_paths: Dictionary = {}     # path -> true, for the support badge
# The auto-draft placard. Empty array = the screen using this picker has no
# auto-draft behaviour to announce (the Operations draft does not), so nothing
# is built and those screens are untouched.
var _auto_names: Array = []
var _auto_panel: PanelContainer = null
var _auto_label: Label = null


# `entries` is blueprint_manager.list_blueprints(true) output.
func setup(entries: Array, capacity: int) -> void:
	_capacity = capacity
	add_theme_constant_override("separation", Tokens.SPACE_SM)

	_baker = BlueprintThumbnailScript.new()
	add_child(_baker)

	for entry in entries:
		var path := str(entry.get("path", ""))
		if path == "":
			continue
		_data_by_path[path] = _load_blueprint(path)
		# Classification is read off the ENTRY, not recomputed from blueprint
		# data here: blueprint_manager.list_blueprints() already resolved it
		# through ModuleCatalog, and a second, independently-derived answer in
		# the UI is exactly how a design ends up in one library and a different
		# category in the match.
		if entry.get("is_defensive", false):
			_building_paths[path] = entry
		elif entry.get("is_harvester", false):
			_harvester_paths[path] = entry
		if entry.get("has_repair", false):
			_repair_paths[path] = true

	# --- Top row: three library strips side by side ---
	var lib_row := HBoxContainer.new()
	lib_row.add_theme_constant_override("separation", Tokens.SPACE_MD)
	lib_row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	add_child(lib_row)

	lib_row.add_child(_build_units_scroll(entries))
	lib_row.add_child(_build_harvester_scroll(entries))
	lib_row.add_child(_build_building_scroll(entries))

	# --- Bottom: unit roster and defence loadout SIDE BY SIDE ---
	#
	# Stacked, the two grids added ~160px to a screen whose own comments record
	# that the libraries plus one grid "all fit on a 900px viewport without
	# scrolling". Side by side both are two rows tall, so the defence loadout
	# costs width - which the tray has - instead of height, which it does not.
	var trays := HBoxContainer.new()
	trays.add_theme_constant_override("separation", Tokens.SPACE_MD)
	trays.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	add_child(trays)

	var roster_section := _build_slot_section()
	roster_section.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	roster_section.size_flags_stretch_ratio = 3.0
	trays.add_child(roster_section)

	var defence_section := _build_building_section()
	defence_section.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	defence_section.size_flags_stretch_ratio = 1.0
	trays.add_child(defence_section)
	_update_counter()

	_bake_thumbnails(entries)


# One library column. The three categories differ only in which entries they
# take, what they are called and how wide they sit, so they share a builder -
# three near-identical 40-line functions was how the second one drifted from
# the first (the combat strip animated its entrance, the harvester strip did
# not, for no stated reason).
#
# `category` is one of "unit" / "harvester" / "building" and is matched against
# the entry flags the blueprint manager resolved.
func _build_library_column(entries: Array, category: String, heading_text: String,
		empty_hint: String, stretch: float) -> VBoxContainer:
	var col := VBoxContainer.new()
	col.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	col.size_flags_stretch_ratio = stretch
	col.add_theme_constant_override("separation", Tokens.SPACE_XS)

	var hdr := HBoxContainer.new()
	hdr.add_theme_constant_override("separation", Tokens.SPACE_SM)
	col.add_child(hdr)

	var heading := Label.new()
	heading.text = heading_text
	heading.theme_type_variation = "HeadingLabel"
	heading.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	hdr.add_child(heading)

	var picked := []
	for entry in entries:
		if _category_of(entry) == category:
			picked.append(entry)

	if picked.is_empty():
		var hint := Label.new()
		hint.text = empty_hint
		hint.theme_type_variation = "HintLabel"
		hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		col.add_child(hint)
		return col

	var sort_btn: OptionButton = null
	if category == "unit" or picked.size() > 2:
		sort_btn = OptionButton.new()
		sort_btn.add_item("Sort: Name")
		sort_btn.add_item("Sort: Tier")
		sort_btn.add_item("Sort: HP")
		sort_btn.add_item("Sort: Speed")
		sort_btn.add_item("Sort: DPS")
		sort_btn.add_item("Sort: Cost")
		sort_btn.theme_type_variation = "StatLabel"
		hdr.add_child(sort_btn)
	else:
		var count_lbl := Label.new()
		count_lbl.text = "%d design%s" % [picked.size(), "" if picked.size() == 1 else "s"]
		count_lbl.theme_type_variation = "StatLabel"
		count_lbl.add_theme_color_override("font_color", Tokens.TEXT_DISABLED)
		hdr.add_child(count_lbl)

	# Tray surface behind the strip.
	var tray := PanelContainer.new()
	tray.add_theme_stylebox_override("panel", surface_style(
		Color(0, 0, 0, 0), SURFACE_TRAY, SURFACE_EDGE.darkened(0.45), 6))
	tray.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	col.add_child(tray)

	var scroll := ScrollContainer.new()
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_SHOW_ALWAYS
	scroll.vertical_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	scroll.custom_minimum_size = Vector2(0, CARD_SIZE.y + Tokens.SPACE_SM + 24)
	scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	tray.add_child(scroll)

	var hsb := scroll.get_h_scroll_bar()
	hsb.custom_minimum_size = Vector2(0, 10)

	var hsb_grabber := StyleBoxFlat.new()
	hsb_grabber.bg_color = Tokens.BASE_400
	hsb_grabber.corner_radius_top_left = 3
	hsb_grabber.corner_radius_top_right = 3
	hsb_grabber.corner_radius_bottom_left = 3
	hsb_grabber.corner_radius_bottom_right = 3

	var hsb_grabber_hl := StyleBoxFlat.new()
	hsb_grabber_hl.bg_color = Tokens.SIGNAL_HAZARD
	hsb_grabber_hl.corner_radius_top_left = 3
	hsb_grabber_hl.corner_radius_top_right = 3
	hsb_grabber_hl.corner_radius_bottom_left = 3
	hsb_grabber_hl.corner_radius_bottom_right = 3

	var hsb_grabber_pressed := StyleBoxFlat.new()
	hsb_grabber_pressed.bg_color = Tokens.SIGNAL_HAZARD.lightened(0.15)
	hsb_grabber_pressed.corner_radius_top_left = 3
	hsb_grabber_pressed.corner_radius_top_right = 3
	hsb_grabber_pressed.corner_radius_bottom_left = 3
	hsb_grabber_pressed.corner_radius_bottom_right = 3

	var hsb_track := StyleBoxFlat.new()
	hsb_track.bg_color = Tokens.BASE_900
	hsb_track.border_color = Tokens.BASE_600
	hsb_track.set_border_width_all(1)
	hsb_track.corner_radius_top_left = 3
	hsb_track.corner_radius_top_right = 3
	hsb_track.corner_radius_bottom_left = 3
	hsb_track.corner_radius_bottom_right = 3
	hsb_track.content_margin_top = 2
	hsb_track.content_margin_bottom = 2

	hsb.add_theme_stylebox_override("grabber", hsb_grabber)
	hsb.add_theme_stylebox_override("grabber_highlight", hsb_grabber_hl)
	hsb.add_theme_stylebox_override("grabber_pressed", hsb_grabber_pressed)
	hsb.add_theme_stylebox_override("scroll", hsb_track)
	hsb.add_theme_stylebox_override("scroll_focus", hsb_track)

	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", Tokens.SPACE_SM)
	scroll.add_child(row)

	if sort_btn != null:
		sort_btn.item_selected.connect(func(idx: int): _sort_cards(row, idx))

	for entry in picked:
		var card := RosterCard.new()
		card.configure(entry, _data_by_path.get(str(entry.get("path", "")), {}))
		card.bind_picker(self)
		card.size_flags_vertical = Control.SIZE_EXPAND_FILL
		row.add_child(card)

	match category:
		"harvester": _harvester_row = row
		"building": _building_row = row
		_: _library_row = row
	return col


func _sort_cards(row: HBoxContainer, criteria: int) -> void:
	if not is_instance_valid(row):
		return
	var cards: Array = []
	for child in row.get_children():
		if child is RosterCard:
			cards.append(child)
	match criteria:
		0: # Name (A-Z)
			cards.sort_custom(func(a, b): return a.entry_name < b.entry_name)
		1: # Tier
			var get_tier = func(c):
				var q = str(c.stats.get("factory_queue", "")).to_lower()
				if "light" in q: return 1
				if "med" in q: return 2
				if "heavy" in q: return 3
				return 4
			cards.sort_custom(func(a, b): return get_tier.call(a) < get_tier.call(b))
		2: # HP (highest first)
			cards.sort_custom(func(a, b): return float(a.stats.get("hull_hp", 0.0)) > float(b.stats.get("hull_hp", 0.0)))
		3: # Speed (fastest first)
			cards.sort_custom(func(a, b): return float(a.stats.get("move_speed", 0.0)) > float(b.stats.get("move_speed", 0.0)))
		4: # DPS (highest first)
			cards.sort_custom(func(a, b): return float(a.stats.get("dps", 0.0)) > float(b.stats.get("dps", 0.0)))
		5: # Cost (cheapest first)
			cards.sort_custom(func(a, b): return int(a.stats.get("cost_metal", 0)) < int(b.stats.get("cost_metal", 0)))
	for card in cards:
		row.move_child(card, -1)


# THE one place an entry's library is decided. Defensive is tested FIRST: a
# foundation-hull design carrying a harvester module is a static extractor, and
# it must not be offered as something a manufactory can build.
func _category_of(entry: Dictionary) -> String:
	if entry.get("is_defensive", false):
		return "building"
	if entry.get("is_harvester", false):
		return "harvester"
	return "unit"


func _build_units_scroll(entries: Array) -> VBoxContainer:
	var c := _build_library_column(entries, "unit", "UNITS",
		"No saved unit designs yet — save a design in the Lab to field it.", 3.0)
	call_deferred("_animate_library_entrance")
	return c


func _build_harvester_scroll(entries: Array) -> VBoxContainer:
	return _build_library_column(entries, "harvester", "HARVESTERS",
		"No harvesters saved yet — add a Resource Harvester in the Lab.", 2.0)


func _build_building_scroll(entries: Array) -> VBoxContainer:
	return _build_library_column(entries, "building", "DEFENSIVE BUILDINGS",
		"No defence designs yet — build one on a foundation hull in the Lab.", 2.0)


func _build_slot_section() -> VBoxContainer:
	var section := VBoxContainer.new()
	section.add_theme_constant_override("separation", Tokens.SPACE_XS)
	section.size_flags_horizontal = Control.SIZE_EXPAND_FILL

	var heading := Label.new()
	# No parenthetical restriction caption: the reserved well says HARVESTER on
	# its own face (see RosterSlot._render_empty).
	heading.text = "MATCH ROSTER"
	heading.theme_type_variation = "HeadingLabel"
	section.add_child(heading)

	_counter = Label.new()
	_counter.theme_type_variation = "StatLabel"
	section.add_child(_counter)

	var well := PanelContainer.new()
	well.theme_type_variation = "InsetPanel"
	# Same tray surface as the library strips, so the two halves of the screen
	# sit on one value ladder instead of each inventing its own.
	well.add_theme_stylebox_override("panel", surface_style(
		Color(0, 0, 0, 0), SURFACE_TRAY, SURFACE_EDGE.darkened(0.45), 6))
	well.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	section.add_child(well)

	_slot_grid = GridContainer.new()
	_slot_grid.columns = 6
	_slot_grid.add_theme_constant_override("h_separation", Tokens.SPACE_SM)
	_slot_grid.add_theme_constant_override("v_separation", Tokens.SPACE_SM)
	_slot_grid.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	well.add_child(_slot_grid)

	for i in range(_capacity):
		var slot := RosterSlot.new()
		var kind: int = SlotKind.HARVESTER if i == HARVESTER_SLOT_INDEX else SlotKind.UNIT
		slot.configure(i, self, kind)
		slot.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		_slot_grid.add_child(slot)
		_slots.append(slot)

	return section


func _build_building_section() -> VBoxContainer:
	var section := VBoxContainer.new()
	section.add_theme_constant_override("separation", Tokens.SPACE_XS)
	section.size_flags_horizontal = Control.SIZE_EXPAND_FILL

	var heading := Label.new()
	heading.text = "DEFENCE LOADOUT"
	heading.theme_type_variation = "HeadingLabel"
	section.add_child(heading)

	var sub := Label.new()
	sub.text = "placed during the match"
	sub.theme_type_variation = "StatLabel"
	sub.add_theme_color_override("font_color", Tokens.TEXT_SECONDARY)
	section.add_child(sub)

	var well := PanelContainer.new()
	well.theme_type_variation = "InsetPanel"
	# Same tray surface as the library strips, so the two halves of the screen
	# sit on one value ladder instead of each inventing its own.
	well.add_theme_stylebox_override("panel", surface_style(
		Color(0, 0, 0, 0), SURFACE_TRAY, SURFACE_EDGE.darkened(0.45), 6))
	well.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	section.add_child(well)

	_building_grid = GridContainer.new()
	# 2x2, matching the roster grid's two rows so the trays sit level.
	_building_grid.columns = 2
	_building_grid.add_theme_constant_override("h_separation", Tokens.SPACE_SM)
	_building_grid.add_theme_constant_override("v_separation", Tokens.SPACE_SM)
	_building_grid.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	well.add_child(_building_grid)

	for i in range(BUILDING_CAPACITY):
		var slot := RosterSlot.new()
		slot.configure(i, self, SlotKind.BUILDING)
		slot.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		_building_grid.add_child(slot)
		_building_slots.append(slot)

	return section


func _animate_library_entrance() -> void:
	if is_instance_valid(_library_row):
		# From the LEFT, not from below: the strip is a horizontal rack, and cards
		# arriving upward would read as unrelated to the direction it scrolls.
		UIAnimScript.stagger_in(_library_row, Vector2(-16, 0))
	if is_instance_valid(_harvester_row):
		UIAnimScript.stagger_in(_harvester_row, Vector2(-16, 0))
	if is_instance_valid(_building_row):
		UIAnimScript.stagger_in(_building_row, Vector2(-16, 0))


func _bake_thumbnails(entries: Array) -> void:
	if not is_inside_tree():
		await tree_entered
	for entry in entries:
		var path := str(entry.get("path", ""))
		if path == "":
			continue

		# Check static cache first
		if _thumbnail_cache.has(path):
			var cached_tex = _thumbnail_cache[path]
			var cached_stats: Dictionary = _stats_cache.get(path, {})
			for card in _cards():
				if card.entry_path == path:
					if cached_tex != null:
						card.set_thumbnail(cached_tex)
					if not cached_stats.is_empty():
						card.set_stats(cached_stats)
			if cached_tex != null:
				for slot in _all_slots():
					if slot.entry_path == path:
						slot.refresh_thumbnail(cached_tex)
			continue

		var data: Dictionary = _data_by_path.get(path, {})
		if data.is_empty():
			continue
		var tex: ImageTexture = await _baker.bake(data)
		var stats: Dictionary = _baker.last_stats.duplicate()
		if tex != null:
			_thumbnail_cache[path] = tex
		if not stats.is_empty():
			_stats_cache[path] = stats

		if not is_inside_tree():
			await tree_entered

		for card in _cards():
			if card.entry_path == path:
				if tex != null:
					card.set_thumbnail(tex)
				card.set_stats(stats)
		if tex != null:
			for slot in _all_slots():
				if slot.entry_path == path:
					slot.refresh_thumbnail(tex)


func _load_blueprint(path: String) -> Dictionary:
	if not FileAccess.file_exists(path):
		return {}
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return {}
	var parsed = JSON.parse_string(f.get_as_text())
	f.close()
	return parsed if parsed is Dictionary else {}


func _cards() -> Array:
	var out := []
	for row in [_library_row, _harvester_row, _building_row]:
		if row == null:
			continue
		for c in row.get_children():
			if c is RosterCard:
				out.append(c)
	return out


# Every slot in both grids. Used wherever "is this design already placed"
# has to be answered across the whole screen rather than one grid.
func _all_slots() -> Array:
	return _slots + _building_slots


# Called by a slot once it has accepted or released a payload.
func notify_slot_changed(_slot: RosterSlot) -> void:
	_update_counter()
	roster_changed.emit()


func _update_counter() -> void:
	if _counter == null:
		return
	var units := 0
	var harv_slot_filled := false
	for slot in _slots:
		if slot.entry_path == "":
			continue
		units += 1
		if slot.kind == SlotKind.HARVESTER:
			harv_slot_filled = true
	var defences := 0
	for slot in _building_slots:
		if slot.entry_path != "":
			defences += 1
	var harv_text := "  (harvester slot: %s)" % ("filled" if harv_slot_filled else "empty")
	_counter.text = "%d / %d unit slots  ·  %d / %d defences%s" % [
		units, _capacity, defences, BUILDING_CAPACITY, harv_text]
	if units == 0:
		_counter.add_theme_color_override("font_color", Tokens.TEXT_SECONDARY)
	else:
		_counter.add_theme_color_override("font_color", Tokens.SIGNAL_GO)
	_refresh_auto_placard(units)


# Finds the slot currently holding a path, or null. Used to enforce that a design
# occupies at most one slot ACROSS BOTH GRIDS - a design dragged from the units
# grid into the defence grid must leave the first, not appear twice.
func slot_holding(path: String) -> RosterSlot:
	for slot in _all_slots():
		if slot.entry_path == path:
			return slot
	return null


func is_harvester_slot(index: int) -> bool:
	return index == HARVESTER_SLOT_INDEX


func is_harvester_path(path: String) -> bool:
	return _harvester_paths.has(path)


# A small capability glyph. Returns null when the icon is missing rather than
# substituting a placeholder - the same degrade-to-nothing contract
# hud_icons.gd uses, so a renamed asset costs a badge rather than a broken
# texture rect on every card.
# One surface builder for every card and filled slot, so a tinted card and an
# untinted one differ only in HUE. Previously the tint path replaced the whole
# stylebox with a flat fill and the untinted path kept the themed CardPanel
# texture, so the two had different borders, different corner radii and
# different padding - visible in the setup screen as the harvester column
# sitting at a different height and weight from the units column.
static func surface_style(tint: Color = Color(0, 0, 0, 0), fill: Color = SURFACE_CARD,
		edge: Color = SURFACE_EDGE, margin: int = 8) -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = fill if tint.a <= 0.0 else fill.lerp(Color(tint.r, tint.g, tint.b, 1.0), TINT_STRENGTH * tint.a / 0.45)
	sb.border_color = edge if tint.a <= 0.0 else edge.lerp(Color(tint.r, tint.g, tint.b, 1.0), 0.45)
	sb.set_border_width_all(1)
	sb.set_corner_radius_all(SURFACE_RADIUS)
	sb.set_content_margin_all(margin)
	return sb


static func make_badge(icon_name: String, tip: String, size: Vector2 = CARD_BADGE_SIZE,
		alpha: float = 1.0) -> TextureRect:
	if not UIIcons.has_icon(icon_name):
		push_warning("RosterPicker: no icon '%s' in UIIcons registry - badge omitted." % icon_name)
		return null
	var tr := TextureRect.new()
	tr.texture = UIIcons.get_icon(icon_name)
	tr.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	tr.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	tr.custom_minimum_size = size
	tr.size = size
	tr.modulate = Color(1, 1, 1, alpha)
	tr.tooltip_text = tip
	tr.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return tr


func is_building_path(path: String) -> bool:
	return _building_paths.has(path)


func is_repair_path(path: String) -> bool:
	return _repair_paths.has(path)


# Does `path` belong in a slot of `kind`?
#
# The unit grid takes harvesters in ANY slot, not just the reserved one - the
# reservation exists to guarantee you field at least one, not to cap you at
# one. What it will not take is a defence, and vice versa.
func path_fits_kind(path: String, kind: int) -> bool:
	match kind:
		SlotKind.BUILDING:
			return is_building_path(path)
		SlotKind.HARVESTER:
			return is_harvester_path(path)
		_:
			return not is_building_path(path)


# Fills the slots from an ordered list of paths, as the inverse of
# ordered_paths(). Added for the Operations draft screen, which opens on the
# roster you fielded last engagement rather than on twelve empty wells - between
# rounds the common case is keeping what worked, so an empty default would make
# holding a roster more work than changing it.
#
# A PATH THE LIBRARY NO LONGER HAS IS SKIPPED, not slotted blank: a design
# deleted from the Blueprint Library between engagements must leave a gap you can
# fill, not a slot that looks filled and fields nothing.
func fill_from(paths: Array) -> int:
	var filled := 0
	for path in paths:
		var path_str := str(path)
		if not _data_by_path.has(path_str):
			continue
		if slot_holding(path_str) != null:
			continue
		# ROUTED BY CATEGORY, not packed in order. The incoming list is a flat
		# array (that is what ordered_paths returns and what the rule set
		# carries), so a defence in it has to find its way to the defence grid
		# rather than eating a unit slot - which is what a naive "fill slot N"
		# loop did once buildings joined the screen.
		var slot: RosterSlot = _first_free_slot_for(path_str)
		if slot == null:
			continue
		var data: Dictionary = _data_by_path[path_str]
		# null thumbnail: _bake_thumbnails() is still in flight from setup() and
		# fills every slot holding this path when its render lands.
		slot.assign(path_str, str(data.get("name", path_str.get_file())), null)
		filled += 1
	_update_counter()
	return filled


func _first_free_slot_for(path: String) -> RosterSlot:
	var pool: Array = _building_slots if is_building_path(path) else _slots
	# Prefer a general slot so the reserved harvester well stays open for a
	# harvester that has not been placed yet.
	for slot in pool:
		if slot.entry_path == "" and slot.kind != SlotKind.HARVESTER \
				and path_fits_kind(path, slot.kind):
			return slot
	for slot in pool:
		if slot.entry_path == "" and path_fits_kind(path, slot.kind):
			return slot
	return null


# THE OUTPUT CONTRACT. Left-to-right, top-to-bottom, gaps skipped; units first,
# then defences.
#
# Still ONE flat array. The match runtime sorts units from defences itself via
# match_director.is_defence_design(), and hud_production_deck already routes
# each into its own queue, so splitting them here would mean inventing a second
# rule-set field for information the runtime re-derives anyway.
func ordered_paths() -> Array:
	var out := []
	for slot in _slots:
		if slot.entry_path != "":
			out.append(slot.entry_path)
	for slot in _building_slots:
		if slot.entry_path != "":
			out.append(slot.entry_path)
	return out


# ---------------------------------------------------------------------------
# A draggable design in the library strip.
# ---------------------------------------------------------------------------
class RosterCard extends PanelContainer:
	var entry_path: String = ""
	var entry_name: String = ""
	var _thumb: TextureRect = null
	var _tex: Texture2D = null
	var _spec: Label = null
	var variant: String = "unit"
	var _picker: RosterPicker = null
	var _entry: Dictionary = {}
	var _data: Dictionary = {}
	var stats: Dictionary = {}

	func configure(entry: Dictionary, data: Dictionary) -> void:
		_entry = entry
		_data = data
		entry_path = str(entry.get("path", ""))
		entry_name = str(entry.get("name", "Untitled"))
		theme_type_variation = "CardPanel"
		custom_minimum_size = RosterPicker.CARD_SIZE
		mouse_filter = Control.MOUSE_FILTER_PASS
		tooltip_text = "%s\nClick to field in the next free slot. Drag to place it deliberately." % entry_name

		var is_harv: bool = entry.get("is_harvester", false)
		var is_def: bool = entry.get("is_defensive", false)
		var has_rep: bool = entry.get("has_repair", false)
		variant = RosterPicker.variant_for_entry(entry)
		add_theme_stylebox_override("panel", RosterPicker.tile_style(variant, "card"))

		var box := VBoxContainer.new()
		box.add_theme_constant_override("separation", Tokens.SPACE_XS)
		add_child(box)

		var thumb_wrap := Control.new()
		thumb_wrap.custom_minimum_size = Vector2(0, RosterPicker.CARD_THUMB_H)
		thumb_wrap.mouse_filter = Control.MOUSE_FILTER_IGNORE
		box.add_child(thumb_wrap)

		_thumb = TextureRect.new()
		_thumb.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		_thumb.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		_thumb.set_anchors_preset(Control.PRESET_FULL_RECT)
		_thumb.mouse_filter = Control.MOUSE_FILTER_IGNORE
		thumb_wrap.add_child(_thumb)

		var badges: Array = []
		if is_harv:
			badges.append([RosterPicker.ICON_HARVESTER, "Harvester — can gather resources"])
		if is_def:
			badges.append([RosterPicker.ICON_BUILDING, "Defensive building — placed on the map"])
		if has_rep:
			badges.append([RosterPicker.ICON_REPAIR, "Support — carries a repair array"])
		for i in range(badges.size()):
			var badge := RosterPicker.make_badge(badges[i][0], badges[i][1])
			if badge == null:
				continue
			badge.set_anchors_preset(Control.PRESET_TOP_LEFT)
			badge.position = Vector2(2 + i * (RosterPicker.CARD_BADGE_SIZE.x + 3), 2)
			thumb_wrap.add_child(badge)

		var name_label := Label.new()
		name_label.text = entry_name
		name_label.theme_type_variation = "HintLabel"
		name_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		name_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		name_label.add_theme_color_override("font_color", Tokens.TEXT_PRIMARY)
		box.add_child(name_label)

		# Preliminary stats directly from blueprint data
		var fac: String = "Bldg" if is_def else DesignCostingScript.queue_for_design(data).capitalize()
		var mat_id: String = str(data.get("armor", {}).get("material", "steel_plate"))
		var arm_res: int = RosterPicker.calculate_armor_resistance(mat_id)
		var cost: Vector2i = DesignCostingScript.blueprint_materials(data)
		var est_hp: float = float(entry.get("hull_blocks", 8)) * 25.0
		var est_spd: float = 12.0
		var est_dps: float = 0.0
		var est_rng: float = 0.0
		var weapons = data.get("weapons", [])
		if weapons is Array:
			for w in weapons:
				est_dps += float(w.get("dps", 15.0))
				est_rng = maxf(est_rng, float(w.get("range", 100.0)))

		stats = {
			"factory_queue": fac,
			"armor_resist": arm_res,
			"hull_hp": est_hp,
			"move_speed": est_spd,
			"dps": est_dps,
			"longest_range": est_rng,
			"vision": 160.0,
			"cost_metal": cost.x,
			"cost_crystal": cost.y,
			"is_harvester": is_harv,
			"cargo_capacity": 100 if is_harv else 0,
			"has_weapons": est_dps > 0.0
		}

		_spec = Label.new()
		_spec.theme_type_variation = "StatLabel"
		_spec.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		_spec.size_flags_vertical = Control.SIZE_EXPAND_FILL
		_spec.text = RosterPicker.format_rich_stats(stats, entry, data)
		box.add_child(_spec)

	# Called once the design has been reconstructed and measured.
	func set_stats(measured_stats: Dictionary) -> void:
		if _spec == null:
			return
		if not measured_stats.is_empty():
			for k in measured_stats.keys():
				stats[k] = measured_stats[k]
			if not stats.has("factory_queue") or str(stats["factory_queue"]) == "":
				stats["factory_queue"] = "Bldg" if _entry.get("is_defensive", false) else DesignCostingScript.queue_for_design(_data).capitalize()
			if not stats.has("armor_resist"):
				var mat_id = str(_data.get("armor", {}).get("material", "steel_plate"))
				stats["armor_resist"] = RosterPicker.calculate_armor_resistance(mat_id)
		_spec.text = RosterPicker.format_rich_stats(stats, _entry, _data)

	func set_thumbnail(tex: Texture2D) -> void:
		_tex = tex
		if _thumb:
			_thumb.texture = tex
			_thumb.modulate.a = 1.0
			UIAnimScript.fade(_thumb, 1.0, UIAnimScript.DURATION_FAST, 0.4)

	func bind_picker(picker: RosterPicker) -> void:
		_picker = picker

	# Click, not drag. Guarded on gui_is_dragging so the release that ENDS a
	# drag out of this card does not also fire an assign - Godot delivers the
	# button-up to the source control, and without the guard every drag placed
	# the design twice (once where it was dropped, once in the next free well).
	func _gui_input(event: InputEvent) -> void:
		if not (event is InputEventMouseButton) or event.pressed:
			return
		if event.button_index != MOUSE_BUTTON_LEFT:
			return
		if get_viewport() and get_viewport().gui_is_dragging():
			return
		if _picker == null or entry_path == "":
			return
		_picker.assign_to_next_free(entry_path, entry_name, _tex, self)
		accept_event()

	func _get_drag_data(_at_position: Vector2) -> Variant:
		if entry_path == "":
			return null
		if _tex == null and _picker != null and _picker._thumbnail_cache.has(entry_path):
			_tex = _picker._thumbnail_cache[entry_path]
		set_drag_preview(RosterPicker.make_drag_preview(_tex, entry_name))
		return {
			"type": RosterPicker.DRAG_TYPE,
			"path": entry_path,
			"name": entry_name,
			"tex": _tex,
			# No source slot: dragging FROM the library is always a copy-in, never
			# a move. A slot-to-slot drag sets this so the origin can be cleared.
			"from_slot": null,
		}


# ---------------------------------------------------------------------------
# One roster slot. Empty is a numbered well; filled shows the unit.
# ---------------------------------------------------------------------------
class RosterSlot extends PanelContainer:
	var entry_path: String = ""
	var entry_name: String = ""
	var index: int = 0
	var kind: int = RosterPicker.SlotKind.UNIT

	var _picker: RosterPicker = null
	var _thumb: TextureRect = null
	var _label: Label = null
	var _tex: Texture2D = null
	var _ghost: TextureRect = null

	func configure(i: int, picker: RosterPicker, slot_kind: int = RosterPicker.SlotKind.UNIT) -> void:
		index = i
		_picker = picker
		kind = slot_kind
		custom_minimum_size = RosterPicker.SLOT_SIZE
		mouse_filter = Control.MOUSE_FILTER_PASS
		mouse_entered.connect(_on_mouse_entered)
		mouse_exited.connect(_on_mouse_exited)

		var box := VBoxContainer.new()
		box.add_theme_constant_override("separation", 0)
		add_child(box)

		# Same wrapper trick as the card: the empty-slot ghost has to sit ON the
		# thumbnail area, not above or below it, or an empty slot is a different
		# height from a filled one and the grid jumps as you fill it.
		var thumb_wrap := Control.new()
		thumb_wrap.custom_minimum_size = Vector2(88, 72)
		thumb_wrap.size_flags_vertical = Control.SIZE_EXPAND_FILL
		thumb_wrap.mouse_filter = Control.MOUSE_FILTER_IGNORE
		box.add_child(thumb_wrap)

		_thumb = TextureRect.new()
		_thumb.custom_minimum_size = Vector2(88, 72)
		_thumb.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		_thumb.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		_thumb.set_anchors_preset(Control.PRESET_FULL_RECT)
		_thumb.mouse_filter = Control.MOUSE_FILTER_IGNORE
		thumb_wrap.add_child(_thumb)

		# The ghost says what this well is FOR while it is empty. Only the two
		# reserved kinds get one; a general unit slot takes almost anything and
		# a glyph there would be noise.
		var ghost_icon := ""
		match kind:
			RosterPicker.SlotKind.HARVESTER: ghost_icon = RosterPicker.ICON_HARVESTER
			RosterPicker.SlotKind.BUILDING: ghost_icon = RosterPicker.ICON_BUILDING
		if ghost_icon != "":
			_ghost = RosterPicker.make_badge(ghost_icon, "", RosterPicker.SLOT_GHOST_SIZE,
				RosterPicker.SLOT_GHOST_ALPHA)
			if _ghost != null:
				_ghost.set_anchors_preset(Control.PRESET_CENTER)
				_ghost.grow_horizontal = Control.GROW_DIRECTION_BOTH
				_ghost.grow_vertical = Control.GROW_DIRECTION_BOTH
				thumb_wrap.add_child(_ghost)

		_label = Label.new()
		_label.theme_type_variation = "HintLabel"
		_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		_label.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
		_label.clip_text = true
		box.add_child(_label)

		_render_empty()

	func _render_empty() -> void:
		entry_path = ""
		entry_name = ""
		_tex = null
		# An empty slot is a RECESS - darker than the tray it sits in, with a
		# lit edge. That is what makes the grid read as something to drop into
		# rather than as a row of blank buttons, and it needs to be built
		# explicitly here so the empty and filled states sit on the same value
		# ladder as the cards (see SURFACE_TRAY's header).
		theme_type_variation = "InsetPanel"
		# A restricted well (harvester / defence) carries a faint category tint
		# even while EMPTY, so it reads as "this well is different" without
		# needing the parenthetical caption in the section heading to explain
		# it. A general unit well stays untinted - it takes almost anything,
		# so it has no category to announce.
		add_theme_stylebox_override("panel", RosterPicker.tile_style(
			RosterPicker.variant_for_kind(kind), "slot_empty"))
		if _thumb:
			_thumb.texture = null
			_thumb.visible = false
		if _ghost:
			_ghost.visible = true
		# Legend and colour come from the variant table, so the restriction
		# reads off the WELL itself. That is what retired the parenthetical
		# "(slot 12 = harvester only)" caption in the section heading.
		if _label:
			var v := RosterPicker.variant_def(RosterPicker.variant_for_kind(kind))
			var legend := str(v["label"])
			if legend == "":
				_label.text = str(index + 1)
				_label.add_theme_color_override("font_color", Tokens.TEXT_DISABLED)
			else:
				var tint_col: Color = v["tint"]
				if kind == RosterPicker.SlotKind.BUILDING:
					_label.text = "%s %d" % [legend, index + 1]
				else:
					_label.text = legend
				_label.add_theme_color_override("font_color",
					Color(tint_col.r, tint_col.g, tint_col.b, 1.0).lightened(0.5))
		# Persistent drag hint — discoverable without mousing over
		var drag_hint = get_node_or_null("DragHint")
		if drag_hint:
			drag_hint.visible = true
		else:
			drag_hint = Label.new()
			drag_hint.name = "DragHint"
			drag_hint.text = "CLICK OR DRAG"
			drag_hint.theme_type_variation = "HintLabel"
			drag_hint.add_theme_color_override("font_color", Tokens.BASE_400)
			drag_hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
			drag_hint.size_flags_vertical = Control.SIZE_EXPAND_FILL
			add_child(drag_hint)
		var slot_type := "any unit"
		match kind:
			RosterPicker.SlotKind.HARVESTER: slot_type = "harvester only"
			RosterPicker.SlotKind.BUILDING: slot_type = "defensive buildings only"
		tooltip_text = "Empty slot %d (%s). Click a design to field it here, or drag one in." % [index + 1, slot_type]

	func _render_filled() -> void:
		# CardPanel: a filled slot is an object sitting IN the recess, so it
		# switches from the recessed variation to the raised one. The elevation
		# change is doing the work here, not a colour change.
		theme_type_variation = "CardPanel"
		# Same surface builder the library cards use, so a design looks like the
		# same object in the slot it was dragged into.
		var variant := "unit"
		if _picker and _picker.is_building_path(entry_path):
			variant = "defence"
		elif _picker and _picker.is_harvester_path(entry_path):
			variant = "harvester"
		elif _has_repair_in_data():
			variant = "support"
		add_theme_stylebox_override("panel", RosterPicker.tile_style(variant, "slot_filled"))
		# The ghost is a "what goes here" prompt, so it goes away the moment
		# something does.
		if _ghost:
			_ghost.visible = false
		if _tex == null and _picker != null and _picker._thumbnail_cache.has(entry_path):
			_tex = _picker._thumbnail_cache[entry_path]
		if _thumb:
			_thumb.texture = _tex
			_thumb.visible = true
		if _label:
			_label.text = entry_name
			_label.remove_theme_color_override("font_color")
		# Hide drag hint when slot is filled
		var drag_hint = get_node_or_null("DragHint")
		if drag_hint:
			drag_hint.visible = false
		tooltip_text = "%s\nClick to clear. Drag to move it to another slot." % entry_name

	func _has_repair_in_data() -> bool:
		if _picker == null or entry_path == "":
			return false
		var data: Dictionary = _picker._data_by_path.get(entry_path, {})
		return data.get("has_repair", false)

	# Hover distinct from both empty and filled: a lit amber edge over
	# whatever surface is already showing, so a well the cursor is over reads
	# as "you could drop here" without having to wait for an actual drag to
	# start. add_theme_color_override on "panel" isn't a thing for a
	# StyleBoxFlat panel property, so this swaps the border colour on the
	# existing stylebox directly rather than rebuilding it.
	func _on_mouse_entered() -> void:
		var sb := get_theme_stylebox("panel") as StyleBoxFlat
		if sb == null:
			return
		sb = sb.duplicate()
		sb.border_color = Tokens.SIGNAL_HAZARD
		sb.border_width_top = maxi(sb.border_width_top, Tokens.BORDER_EMPHASIS)
		sb.border_width_bottom = maxi(sb.border_width_bottom, Tokens.BORDER_EMPHASIS)
		sb.border_width_left = maxi(sb.border_width_left, Tokens.BORDER_EMPHASIS)
		sb.border_width_right = maxi(sb.border_width_right, Tokens.BORDER_EMPHASIS)
		add_theme_stylebox_override("panel", sb)

	func _on_mouse_exited() -> void:
		if entry_path == "":
			_render_empty()
		else:
			_render_filled()

	func assign(path: String, name_text: String, tex: Texture2D) -> void:
		entry_path = path
		entry_name = name_text
		if tex == null and _picker != null and _picker._thumbnail_cache.has(path):
			tex = _picker._thumbnail_cache[path]
		_tex = tex
		_render_filled()

	func clear_slot() -> void:
		_render_empty()

	func refresh_thumbnail(tex: Texture2D) -> void:
		if entry_path == "":
			return
		_tex = tex
		if _thumb:
			_thumb.texture = tex
			_thumb.visible = true

	func _can_drop_data(_at_position: Vector2, data: Variant) -> bool:
		if not (data is Dictionary and data.get("type", "") == RosterPicker.DRAG_TYPE):
			return false
		if _picker == null:
			return true
		# Each slot asks the picker whether the design belongs in a slot of
		# THIS kind. Rejecting here (rather than accepting and sorting it out
		# in _drop_data) is what makes Godot show the no-drop cursor, so the
		# rule is visible during the drag instead of after it.
		return _picker.path_fits_kind(str(data.get("path", "")), kind)

	func _drop_data(_at_position: Vector2, data: Variant) -> void:
		var path := str(data.get("path", ""))
		if path == "":
			return
		var from: RosterSlot = data.get("from_slot", null)

		# A design already in the roster moves rather than duplicating. Without
		# this, dragging the same library card twice fills two slots with the same
		# unit and silently spends roster capacity on a duplicate.
		var existing: RosterSlot = _picker.slot_holding(path) if _picker else null
		if existing != null and existing != self:
			existing.clear_slot()

		# Swap rather than overwrite when dragging slot-to-slot onto an occupied
		# slot, so reordering never destroys a pick.
		#
		# The swap only happens if the displaced design is legal in the source
		# slot. Dragging a defence onto an occupied UNIT slot would otherwise
		# push that unit into the defence grid - a slot that rejects units on
		# drop, but has no say when something is assigned to it directly.
		if from != null and from != self:
			var can_swap: bool = entry_path != "" and _picker != null \
				and _picker.path_fits_kind(entry_path, from.kind)
			if can_swap:
				from.assign(entry_path, entry_name, _tex)
			else:
				from.clear_slot()

		assign(path, str(data.get("name", "")), data.get("tex", null))
		UIAnimScript.button_press_feedback(self)
		UIFeedbackScript.play(self, "place")
		if _picker:
			_picker.notify_slot_changed(self)

	func _get_drag_data(_at_position: Vector2) -> Variant:
		if entry_path == "":
			return null
		if _tex == null and _picker != null and _picker._thumbnail_cache.has(entry_path):
			_tex = _picker._thumbnail_cache[entry_path]
		set_drag_preview(RosterPicker.make_drag_preview(_tex, entry_name))
		return {
			"type": RosterPicker.DRAG_TYPE,
			"path": entry_path,
			"name": entry_name,
			"tex": _tex,
			"from_slot": self,
		}

	func _gui_input(event: InputEvent) -> void:
		# LEFT-click-release on a filled well clears it. Same gui_is_dragging
		# guard the library card uses: the button-up that finishes a drag OUT of
		# this well is delivered here too, and without the guard every
		# slot-to-slot move cleared the well it had just filled.
		if event is InputEventMouseButton and not event.pressed \
				and event.button_index == MOUSE_BUTTON_LEFT and entry_path != "":
			if get_viewport() and get_viewport().gui_is_dragging():
				return
			clear_slot()
			UIFeedbackScript.play(self, "select")
			if _picker:
				_picker.notify_slot_changed(self)
			accept_event()
			return
		# Right-click clears too, kept as the gesture the drag-first version
		# taught. Dragging a unit off the grid and dropping it on
		# nothing does NOT clear the slot - Godot gives no "dropped on nowhere"
		# callback, so an unhandled drop is indistinguishable from a cancelled
		# one, and guessing wrong would silently delete a pick.
		if event is InputEventMouseButton and event.pressed \
				and event.button_index == MOUSE_BUTTON_RIGHT and entry_path != "":
			clear_slot()
			UIFeedbackScript.play(self, "select")
			if _picker:
				_picker.notify_slot_changed(self)
			accept_event()


# Shared by both drag sources so a library drag and a slot drag look identical -
# the thing under the cursor should not change appearance depending on where it
# came from.
# The card's spec block, before its stats have been measured.
#
# Shown immediately from the blueprint document so a card is never blank, then
# replaced by stat_line() once the design has actually been reconstructed. Only
# metadata is available at this point - real HP/Speed/DPS/Range need a live hull
# node, which is what the thumbnail bake produces.
static func calculate_armor_resistance(mat_id: String) -> int:
	var row = DamageResolverScript.ARMOR_TABLE.get(mat_id, DamageResolverScript.ARMOR_TABLE["steel_plate"])
	var total_pt := 0.0
	for dt in ["kinetic", "thermal", "explosive", "energy"]:
		var arr = row.get(dt, [10.0, 0.8])
		total_pt += float(arr[1])
	var avg_pt := total_pt / 4.0
	return int(round((1.0 - avg_pt) * 100.0))


static func format_rich_stats(stats: Dictionary, entry: Dictionary = {}, data: Dictionary = {}) -> String:
	var raw_fac: String = str(stats.get("factory_queue", "")).strip_edges().to_upper()
	var is_def: bool = entry.get("is_defensive", false) or data.get("is_defensive", false)
	var cls_tag := "MEDIUM"
	if is_def or "BLDG" in raw_fac:
		cls_tag = "DEFENCE"
	elif "LIGHT" in raw_fac:
		cls_tag = "LIGHT"
	elif "HEAVY" in raw_fac:
		cls_tag = "HEAVY"
	elif "MED" in raw_fac:
		cls_tag = "MEDIUM"
	elif raw_fac != "":
		cls_tag = raw_fac
	elif entry.get("is_harvester", false):
		cls_tag = "HARVESTER"

	var arm: int = int(stats.get("armor_resist", 30))
	var hp: float = float(stats.get("hull_hp", 300.0))
	var spd: float = float(stats.get("move_speed", 10.0))
	var dps: float = float(stats.get("dps", 0.0))
	var rng: float = float(stats.get("longest_range", 0.0))
	var m: int = int(stats.get("cost_metal", 100))
	var c: int = int(stats.get("cost_crystal", 0))
	var is_harv: bool = bool(stats.get("is_harvester", entry.get("is_harvester", false)))
	var crg: int = int(stats.get("cargo_capacity", 0))

	var lines: Array = []
	# Line 1: Class / Armor (e.g. [HEAVY] Arm: 18%)
	lines.append("[%s] Arm: %d%%" % [cls_tag, arm])
	# Line 2: Durability / Speed (e.g. HP: 1129  Spd: 1.5)
	lines.append("HP: %.0f  Spd: %.1f" % [hp, spd])
	# Line 3: Combat (e.g. DPS: 1020  Rng: 100m or CRG: 100t (Unarmed))
	if is_harv:
		var cargo_val: int = crg if crg > 0 else 100
		if dps > 0.0:
			lines.append("CRG: %dt  DPS: %.0f" % [cargo_val, dps])
		else:
			lines.append("CRG: %dt (Unarmed)" % cargo_val)
	else:
		if dps > 0.0:
			lines.append("DPS: %.0f  Rng: %.0fm" % [dps, rng])
		elif bool(entry.get("has_repair", false)) or bool(stats.get("has_repair", false)):
			lines.append("Support (Repair)")
		else:
			lines.append("(Unarmed)")
	# Line 4: Cost (e.g. Cost: 1427M / 252C)
	if c > 0:
		lines.append("Cost: %dM / %dC" % [m, c])
	else:
		lines.append("Cost: %dM" % m)

	return "\n".join(PackedStringArray(lines))


static func spec_summary(entry: Dictionary, data: Dictionary) -> String:
	return format_rich_stats({}, entry, data)


static func stat_line(stats: Dictionary) -> String:
	return format_rich_stats(stats)


# snake_case id -> "Snake Case". Moved here from match_setup.gd with its only
# caller when the blueprint row became a roster card.
static func prettify(id: String) -> String:
	if id == "":
		return "Unknown"
	var out: Array = []
	for w in id.split("_"):
		if w.length() > 0:
			out.append(w[0].to_upper() + w.substr(1))
	return " ".join(PackedStringArray(out))


static func make_drag_preview(tex: Texture2D, label_text: String) -> Control:
	var wrap := PanelContainer.new()
	wrap.theme_type_variation = "FlyoutPanel"
	# The preview is parented under the viewport's drag layer, so it needs its own
	# size - it gets no layout from a container. DRAG_PREVIEW_SIZE, not CARD_SIZE:
	# the card is now tall enough that reusing its height would put a mostly-empty
	# 196px panel under the cursor.
	wrap.custom_minimum_size = DRAG_PREVIEW_SIZE
	wrap.size = DRAG_PREVIEW_SIZE
	# Slightly transparent so the slot underneath stays readable while dragging;
	# a fully opaque ghost hides the well it is about to land in.
	wrap.modulate = Color(1, 1, 1, 0.85)

	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", Tokens.SPACE_XS)
	wrap.add_child(box)

	if tex != null:
		var img := TextureRect.new()
		img.texture = tex
		img.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		img.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		img.custom_minimum_size = Vector2(0, 62)
		img.size_flags_vertical = Control.SIZE_EXPAND_FILL
		box.add_child(img)

	var name_label := Label.new()
	name_label.text = label_text
	name_label.theme_type_variation = "HintLabel"
	name_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	name_label.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	name_label.clip_text = true
	box.add_child(name_label)
	return wrap


# ---------------------------------------------------------------------------
# CLICK-TO-ASSIGN
# ---------------------------------------------------------------------------
# The gesture that makes a twelve-well roster fillable. Drag still works and
# still places deliberately; this is the same operation without the motion.
#
# Routing is _first_free_slot_for()'s, i.e. exactly what fill_from() uses, so a
# click and a drag put a design in the same well - a defence goes to the defence
# grid, a harvester prefers a general well so the reserved one stays open.
# Returns the slot it landed in, or null when the relevant grid is full: a full
# roster REJECTS rather than silently replacing a pick.
func assign_to_next_free(path: String, name_text: String = "", tex: Texture2D = null,
		source: Control = null) -> RosterSlot:
	if path == "":
		return null
	# Already fielded: clicking it again is a no-op rather than a move, because
	# the design is visibly in a well and a second click reads as "yes, that
	# one" not "move it somewhere else".
	var held: RosterSlot = slot_holding(path)
	if held != null:
		UIAnimScript.shake(held)
		if source != null:
			UIFeedbackScript.play(source, "reject")
		return null
	var slot: RosterSlot = _first_free_slot_for(path)
	if slot == null:
		if source != null:
			UIAnimScript.shake(source)
			UIFeedbackScript.play(source, "reject")
		return null
	var label := name_text
	if label == "":
		var data: Dictionary = _data_by_path.get(path, {})
		label = str(data.get("name", path.get_file()))
	slot.assign(path, label, tex)
	UIAnimScript.button_press_feedback(slot)
	UIFeedbackScript.play(slot, "place")
	notify_slot_changed(slot)
	return slot


# ---------------------------------------------------------------------------
# AUTO-DRAFT, AS A VISIBLE STATE
# ---------------------------------------------------------------------------
# "Leave the roster empty to auto-include your newest designs" used to be one
# clause at the end of a caption, which is the same as not saying it: the
# player could not tell WHICH designs, or whether it was still in effect after
# they filled a single well.
#
# The caller passes the names the match will actually draft (match_director
# takes the first ROSTER_AUTOPICK_LIMIT of the same library listing, then tops
# up from the bundled loadout). The placard shows them while the roster is
# empty and goes away the moment a unit is fielded, so the state is legible in
# both directions.
func set_auto_draft(names: Array) -> void:
	_auto_names = names.duplicate()
	if _auto_panel == null and not _auto_names.is_empty():
		_auto_panel = PanelContainer.new()
		var sb := StyleBoxFlat.new()
		sb.bg_color = Color("#1e293b")
		sb.border_color = Color(Tokens.SIGNAL_HAZARD.r, Tokens.SIGNAL_HAZARD.g, Tokens.SIGNAL_HAZARD.b, 0.45)
		sb.set_border_width_all(1)
		sb.set_corner_radius_all(SURFACE_RADIUS)
		sb.set_content_margin_all(Tokens.SPACE_SM)
		_auto_panel.add_theme_stylebox_override("panel", sb)
		_auto_label = Label.new()
		_auto_label.theme_type_variation = "HintLabel"
		_auto_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		_auto_panel.add_child(_auto_label)
		add_child(_auto_panel)
		move_child(_auto_panel, 0)
	_update_counter()


func _refresh_auto_placard(unit_count: int) -> void:
	if _auto_panel == null or _auto_label == null:
		return
	var active: bool = unit_count == 0 and not _auto_names.is_empty()
	_auto_panel.visible = active
	if not active:
		return
	var count: int = _auto_names.size() if _auto_names.size() > 0 else 8
	_auto_label.text = "[ AUTO-DRAFT ACTIVE: %d Standard Combat Blueprints Loaded ]" % count
	_auto_label.add_theme_color_override("font_color", Color("#38bdf8"))
	_auto_panel.tooltip_text = "Match will field: %s. Assign any custom blueprint to override." % ", ".join(PackedStringArray(_auto_names))


# How many unit wells are filled. The launch stage gates on this rather than
# reaching into _slots, so "is this roster fieldable" has one answer.
func filled_unit_count() -> int:
	var n := 0
	for slot in _slots:
		if slot.entry_path != "":
			n += 1
	return n


func filled_defence_count() -> int:
	var n := 0
	for slot in _building_slots:
		if slot.entry_path != "":
			n += 1
	return n


# The names in slot order, for the launch stage's summary. Parallel to
# ordered_paths() and derived from the same walk, so a summary can never list a
# roster the rule set will not carry.
func ordered_names() -> Array:
	var out := []
	for slot in _slots:
		if slot.entry_path != "":
			out.append(slot.entry_name)
	for slot in _building_slots:
		if slot.entry_path != "":
			out.append(slot.entry_name)
	return out
