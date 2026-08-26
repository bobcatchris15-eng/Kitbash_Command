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

# The drag payload's type tag. Namespaced because _can_drop_data() is called for
# EVERY drag that passes over a slot, including part drags from the Design Lab if
# these controls are ever reused there - an untagged payload would be accepted.
const DRAG_TYPE = "roster_blueprint"

const HARVESTER_SLOT_INDEX = 11  # 0-indexed: slot 12 of 12

# Card tint colors. Harvesters get green, repair units get blue. These are
# light washes applied to the card background so the card reads as a
# CATEGORY at a glance without obscuring the thumbnail or stat text.
const HARVESTER_TINT := Color(0.15, 0.30, 0.12, 0.45)
const REPAIR_TINT := Color(0.12, 0.18, 0.30, 0.45)

	# A FLOOR, not a fixed size. The slots expand to share the full width of the
	# tray (see _build_slot_grid), so this only sets how small one is allowed to get
	# on a narrow window. Raised from 96x78: at that height the thumbnail had barely
	# 56px left under the name line, which is not enough to tell two similar
	# kitbashes apart at a glance - the entire job of the slot.
const SLOT_SIZE = Vector2(104, 132)
# Library card height. Tall enough for thumbnail + wrapped name + four-line spec
# block. Kept at 240 so two library strips (combat + harvester) plus the slot
# grid all fit on a 900px viewport without scrolling the parent VBoxContainer.
const CARD_SIZE = Vector2(168, 240)
# Tall enough for the thumbnail plus a wrapped name plus a four-line spec block.
# The first version was 120x104 and forced the name to a single ellipsised line,
# which is the worst thing to truncate on a card whose whole job is telling two
# similar kitbashes apart.
#
# WIDTH is set by the padding, not by the text. CardPanel's content margins are
# SPACE_XL horizontal (32 a side, so 64 total), which left a 136px card with only
# 72px of usable width - not enough for a padded monospace line like "HP     420"
# at FONT_SMALL. 168 gives ~104px of content.
#
# HEIGHT is a floor, not a cap: the VBox sizes to its content, so this only has to
# be large enough that the ScrollContainer below does not clip a card whose name
# wrapped to three lines. thumbnail 78 + wrapped name ~34 + four stat lines ~64 +
# separations 12 + 40 of vertical padding is ~228, so 248 leaves headroom.
# Grown twice as stat_line() gained rows: 248 -> 268 for HARVESTER, 268 -> 288
# for PWR. The worst case is now six lines (HP, Speed, DPS, Range, HARVESTER,
# PWR) where it was four.
#
# This has to track, because the card's height is a custom_minimum_size inside a
# scroll whose viewport is reserved from this same constant - a card that
# outgrew it would not scroll, it would clip the extra row off the bottom,
# hiding exactly the line that was added to be noticed. 20px per row is one 13px
# monospace line plus its leading.
const CARD_THUMB_H = 78
# The drag ghost stays compact deliberately - it is not a card, it is a token of
# one. A full spec block following the cursor obscures the wells it is about to
# land in, and the player has already read the stats before starting the drag.
const DRAG_PREVIEW_SIZE = Vector2(112, 96)

signal roster_changed()

# Plain Array, not Array[RosterSlot]: GDScript will not accept an inner class as
# a typed array's element type, and the parse error it raises names the line
# rather than the reason.
var _slots: Array = []
var _baker: BlueprintThumbnail = null
var _slot_grid: GridContainer = null
var _library_row: HBoxContainer = null
var _harvester_row: HBoxContainer = null
var _counter: Label = null
var _capacity: int = 12
var _data_by_path: Dictionary = {}
var _harvester_paths: Dictionary = {}  # path -> entry, for slot validation


# `entries` is blueprint_manager.list_blueprints(true) output.
func setup(entries: Array, capacity: int) -> void:
	_capacity = capacity
	add_theme_constant_override("separation", Tokens.SPACE_SM)

	_baker = BlueprintThumbnailScript.new()
	add_child(_baker)

	for entry in entries:
		var path := str(entry.get("path", ""))
		if path != "":
			_data_by_path[path] = _load_blueprint(path)

	# --- Top row: two library strips side by side ---
	var lib_row := HBoxContainer.new()
	lib_row.add_theme_constant_override("separation", Tokens.SPACE_MD)
	lib_row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	add_child(lib_row)

	lib_row.add_child(_build_combat_scroll(entries))
	lib_row.add_child(_build_harvester_scroll(entries))

	# --- Bottom: slot grid (6×2) ---
	add_child(_build_slot_section())
	_update_counter()

	_bake_thumbnails(entries)


func _build_combat_scroll(entries: Array) -> VBoxContainer:
	var col := VBoxContainer.new()
	col.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	col.size_flags_stretch_ratio = 3.0
	col.add_theme_constant_override("separation", Tokens.SPACE_XS)

	var heading := Label.new()
	heading.text = "BLUEPRINT LIBRARY"
	heading.theme_type_variation = "HeadingLabel"
	col.add_child(heading)

	var combat_entries := []
	for entry in entries:
		if not entry.get("is_harvester", false):
			combat_entries.append(entry)

	if combat_entries.is_empty():
		var hint := Label.new()
		hint.text = "No saved designs yet — save a design in the Lab to field it."
		hint.theme_type_variation = "HintLabel"
		hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		col.add_child(hint)
		return col

	var scroll := ScrollContainer.new()
	scroll.vertical_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	scroll.custom_minimum_size = Vector2(0, CARD_SIZE.y + Tokens.SPACE_SM)
	scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	col.add_child(scroll)

	_library_row = HBoxContainer.new()
	_library_row.add_theme_constant_override("separation", Tokens.SPACE_SM)
	scroll.add_child(_library_row)

	for entry in combat_entries:
		var card := RosterCard.new()
		card.configure(entry, _data_by_path.get(str(entry.get("path", "")), {}))
		_library_row.add_child(card)

	call_deferred("_animate_library_entrance")
	return col


func _build_harvester_scroll(entries: Array) -> VBoxContainer:
	var col := VBoxContainer.new()
	col.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	col.size_flags_stretch_ratio = 2.0
	col.add_theme_constant_override("separation", Tokens.SPACE_XS)

	var heading := Label.new()
	heading.text = "HARVESTER BAY"
	heading.theme_type_variation = "HeadingLabel"
	col.add_child(heading)

	var harv_entries := []
	for entry in entries:
		if entry.get("is_harvester", false):
			harv_entries.append(entry)
			_harvester_paths[str(entry.get("path", ""))] = entry

	if harv_entries.is_empty():
		var hint := Label.new()
		hint.text = "No harvesters saved yet — add a Resource Harvester in the Lab."
		hint.theme_type_variation = "HintLabel"
		hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		col.add_child(hint)
		return col

	var scroll := ScrollContainer.new()
	scroll.vertical_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	scroll.custom_minimum_size = Vector2(0, CARD_SIZE.y + Tokens.SPACE_SM)
	scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	col.add_child(scroll)

	_harvester_row = HBoxContainer.new()
	_harvester_row.add_theme_constant_override("separation", Tokens.SPACE_SM)
	scroll.add_child(_harvester_row)

	for entry in harv_entries:
		var card := RosterCard.new()
		card.configure(entry, _data_by_path.get(str(entry.get("path", "")), {}))
		_harvester_row.add_child(card)

	return col


func _build_slot_section() -> VBoxContainer:
	var section := VBoxContainer.new()
	section.add_theme_constant_override("separation", Tokens.SPACE_XS)
	section.size_flags_horizontal = Control.SIZE_EXPAND_FILL

	var heading := Label.new()
	heading.text = "MATCH ROSTER  (slot 12 = harvester only)"
	heading.theme_type_variation = "HeadingLabel"
	section.add_child(heading)

	_counter = Label.new()
	_counter.theme_type_variation = "StatLabel"
	section.add_child(_counter)

	var well := PanelContainer.new()
	well.theme_type_variation = "InsetPanel"
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
		slot.configure(i, self)
		slot.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		_slot_grid.add_child(slot)
		_slots.append(slot)

	return section


func _animate_library_entrance() -> void:
	if is_instance_valid(_library_row):
		# From the LEFT, not from below: the strip is a horizontal rack, and cards
		# arriving upward would read as unrelated to the direction it scrolls.
		UIAnimScript.stagger_in(_library_row, Vector2(-16, 0))
	if is_instance_valid(_harvester_row):
		UIAnimScript.stagger_in(_harvester_row, Vector2(-16, 0))


func _bake_thumbnails(entries: Array) -> void:
	for entry in entries:
		var path := str(entry.get("path", ""))
		if path == "":
			continue
		# Reuses the documents loaded in setup() rather than re-parsing.
		var data: Dictionary = _data_by_path.get(path, {})
		if data.is_empty():
			continue
		var tex: ImageTexture = await _baker.bake(data)
		# Read immediately after the await: the baker holds only the LAST bake's
		# stats, so they must be taken before the next loop iteration overwrites
		# them.
		var stats: Dictionary = _baker.last_stats.duplicate()
		# The screen may have been left while a bake was in flight.
		if not is_inside_tree():
			return
		# Stats are published even when the render failed - a missing picture is no
		# reason to withhold working numbers.
		for card in _cards():
			if card.entry_path == path:
				if tex != null:
					card.set_thumbnail(tex)
				card.set_stats(stats)
		if tex != null:
			for slot in _slots:
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
	for row in [_library_row, _harvester_row]:
		if row == null:
			continue
		for c in row.get_children():
			if c is RosterCard:
				out.append(c)
	return out


# Called by a slot once it has accepted or released a payload.
func notify_slot_changed(_slot: RosterSlot) -> void:
	_update_counter()
	roster_changed.emit()


func _update_counter() -> void:
	if _counter == null:
		return
	var n := ordered_paths().size()
	var harv_slot_filled := false
	for slot in _slots:
		if slot.index == HARVESTER_SLOT_INDEX and slot.entry_path != "":
			harv_slot_filled = true
			break
	var harv_text := "  (harvester slot: %s)" % ("filled" if harv_slot_filled else "empty")
	_counter.text = "%d / %d slots filled%s" % [n, _capacity, harv_text]
	if n == 0:
		_counter.add_theme_color_override("font_color", Tokens.TEXT_SECONDARY)
	else:
		_counter.add_theme_color_override("font_color", Tokens.SIGNAL_GO)


# Finds the slot currently holding a path, or null. Used to enforce that a design
# occupies at most one slot.
func slot_holding(path: String) -> RosterSlot:
	for slot in _slots:
		if slot.entry_path == path:
			return slot
	return null


func is_harvester_slot(index: int) -> bool:
	return index == HARVESTER_SLOT_INDEX


func is_harvester_path(path: String) -> bool:
	return _harvester_paths.has(path)


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
		if filled >= _slots.size():
			break
		if not _data_by_path.has(path_str):
			continue
		if slot_holding(path_str) != null:
			continue
		var data: Dictionary = _data_by_path[path_str]
		# null thumbnail: _bake_thumbnails() is still in flight from setup() and
		# fills every slot holding this path when its render lands.
		_slots[filled].assign(path_str, str(data.get("name", path_str.get_file())), null)
		filled += 1
	_update_counter()
	return filled


# THE OUTPUT CONTRACT. Left-to-right, top-to-bottom, gaps skipped.
func ordered_paths() -> Array:
	var out := []
	for slot in _slots:
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

	func configure(entry: Dictionary, data: Dictionary) -> void:
		entry_path = str(entry.get("path", ""))
		entry_name = str(entry.get("name", "Untitled"))
		theme_type_variation = "CardPanel"
		custom_minimum_size = RosterPicker.CARD_SIZE
		mouse_filter = Control.MOUSE_FILTER_PASS
		tooltip_text = "%s\nDrag into a roster slot." % entry_name

		# Category tint: harvesters get green, repair units get blue.
		# Applied as a StyleBoxFlat background override so the tint is visible
		# behind the thumbnail and stat text without obscuring them.
		if entry.get("is_harvester", false):
			_apply_tint(RosterPicker.HARVESTER_TINT)
		elif entry.get("has_repair", false):
			_apply_tint(RosterPicker.REPAIR_TINT)

		var box := VBoxContainer.new()
		box.add_theme_constant_override("separation", Tokens.SPACE_XS)
		add_child(box)

		_thumb = TextureRect.new()
		_thumb.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		_thumb.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		_thumb.custom_minimum_size = Vector2(0, RosterPicker.CARD_THUMB_H)
		box.add_child(_thumb)

		var name_label := Label.new()
		name_label.text = entry_name
		# WRAPS rather than ellipsises. The card is tall enough for two or three
		# lines now, and a design's name is the one field where losing the tail
		# ("...Mk II" vs "...Mk III") defeats the point of the card.
		name_label.theme_type_variation = "HintLabel"
		name_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		name_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		# Instance-level lift off HintLabel's secondary colour: within this card
		# the name is the primary text and the spec block below it is the
		# secondary, so the variation's default has the hierarchy inverted here.
		name_label.add_theme_color_override("font_color", Tokens.TEXT_PRIMARY)
		box.add_child(name_label)

		_spec = Label.new()
		# StatLabel is 13px MONOSPACE, which is load-bearing here rather than
		# decorative: the stat lines are padded key/value pairs ("HP     420"), so
		# a proportional font would leave the numbers ragged both down a card and
		# across the row of cards beside it.
		_spec.theme_type_variation = "StatLabel"
		_spec.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		_spec.size_flags_vertical = Control.SIZE_EXPAND_FILL
		_spec.text = RosterPicker.spec_summary(entry, data)
		box.add_child(_spec)

	# Called once the design has been reconstructed and measured.
	func set_stats(stats: Dictionary) -> void:
		if _spec:
			_spec.text = RosterPicker.stat_line(stats)

	func set_thumbnail(tex: Texture2D) -> void:
		_tex = tex
		if _thumb:
			_thumb.texture = tex
			# Fade the thumbnail in rather than popping it: bakes land a frame or
			# more apart, and a row of images snapping in one by one reads as
			# stutter.
			UIAnimScript.fade(_thumb, 1.0, UIAnimScript.DURATION_NORMAL)

	func _apply_tint(tint: Color) -> void:
		# Create a tinted StyleBoxFlat as the card background. The tint sits
		# behind the thumbnail and text so the card reads as category-coloured
		# at a glance without obscuring content.
		var style := StyleBoxFlat.new()
		style.bg_color = tint
		style.set_corner_radius_all(4)
		style.set_content_margin_all(8)
		add_theme_stylebox_override("panel", style)

	func _get_drag_data(_at_position: Vector2) -> Variant:
		if entry_path == "":
			return null
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

	var _picker: RosterPicker = null
	var _thumb: TextureRect = null
	var _label: Label = null
	var _tex: Texture2D = null

	func configure(i: int, picker: RosterPicker) -> void:
		index = i
		_picker = picker
		custom_minimum_size = RosterPicker.SLOT_SIZE
		mouse_filter = Control.MOUSE_FILTER_PASS

		var box := VBoxContainer.new()
		box.add_theme_constant_override("separation", 0)
		add_child(box)

		_thumb = TextureRect.new()
		_thumb.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		_thumb.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		_thumb.size_flags_vertical = Control.SIZE_EXPAND_FILL
		box.add_child(_thumb)

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
		# InsetPanel: an empty slot is a recess. That is what makes the grid read
		# as something to drop into rather than as a row of blank buttons.
		theme_type_variation = "InsetPanel"
		if _thumb:
			_thumb.texture = null
		if _label:
			if _picker and _picker.is_harvester_slot(index):
				_label.text = "HRV"
				_label.add_theme_color_override("font_color", RosterPicker.HARVESTER_TINT.lightened(0.4))
			else:
				_label.text = str(index + 1)
				_label.add_theme_color_override("font_color", Tokens.TEXT_DISABLED)
		var slot_type := "any design" if not (_picker and _picker.is_harvester_slot(index)) else "harvester only"
		tooltip_text = "Empty slot %d (%s). Drag a design here." % [index + 1, slot_type]

	func _render_filled() -> void:
		# CardPanel: a filled slot is an object sitting IN the recess, so it
		# switches from the recessed variation to the raised one. The elevation
		# change is doing the work here, not a colour change.
		theme_type_variation = "CardPanel"
		# Apply category tint to the filled slot background.
		if _picker and _picker.is_harvester_path(entry_path):
			var style := StyleBoxFlat.new()
			style.bg_color = RosterPicker.HARVESTER_TINT
			style.set_corner_radius_all(4)
			style.set_content_margin_all(4)
			add_theme_stylebox_override("panel", style)
		elif _has_repair_in_data():
			var style := StyleBoxFlat.new()
			style.bg_color = RosterPicker.REPAIR_TINT
			style.set_corner_radius_all(4)
			style.set_content_margin_all(4)
			add_theme_stylebox_override("panel", style)
		else:
			remove_theme_stylebox_override("panel")
		if _thumb:
			_thumb.texture = _tex
		if _label:
			_label.text = entry_name
			_label.remove_theme_color_override("font_color")
		tooltip_text = "%s\nDrag out or right-click to clear." % entry_name

	func _has_repair_in_data() -> bool:
		if _picker == null or entry_path == "":
			return false
		var data: Dictionary = _picker._data_by_path.get(entry_path, {})
		return data.get("has_repair", false)

	func assign(path: String, name_text: String, tex: Texture2D) -> void:
		entry_path = path
		entry_name = name_text
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

	func _can_drop_data(_at_position: Vector2, data: Variant) -> bool:
		if not (data is Dictionary and data.get("type", "") == RosterPicker.DRAG_TYPE):
			return false
		# Slot 12 (HARVESTER_SLOT_INDEX) only accepts harvesters.
		if _picker and _picker.is_harvester_slot(index):
			var path := str(data.get("path", ""))
			return _picker.is_harvester_path(path)
		return true

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
		if from != null and from != self:
			if entry_path != "":
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
		set_drag_preview(RosterPicker.make_drag_preview(_tex, entry_name))
		return {
			"type": RosterPicker.DRAG_TYPE,
			"path": entry_path,
			"name": entry_name,
			"tex": _tex,
			"from_slot": self,
		}

	func _gui_input(event: InputEvent) -> void:
		# Right-click clears. Dragging a unit off the grid and dropping it on
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
static func spec_summary(entry: Dictionary, data: Dictionary) -> String:
	var lines: Array = []
	lines.append(prettify(str(entry.get("hull_type", ""))))

	var loco: Dictionary = data.get("locomotion", {}) if data else {}
	var loco_id := str(loco.get("type_id", ""))
	if loco_id != "":
		lines.append(prettify(loco_id))

	lines.append("measuring...")
	return "\n".join(PackedStringArray(lines))


# The card's REAL stats.
#
# Every figure comes from DesignStats.analyze() run against the reconstructed
# hull - the same Drivetrain / WeaponRange / ModuleCatalog calls battle_unit.gd
# makes when it spawns the unit for combat. Nothing here is re-derived from the
# JSON, which matters because stat_calculator.gd has twice had to delete a local
# re-derivation that drifted (a capacity calculation that knew four locomotion
# types out of seventeen, and an armour table showing the explosive threshold
# labelled as energy).
#
# HP is the HULL pool, not hull + modules. Module HP is a separate pool that
# subsystem stripping drains without touching hull HP, so adding them would
# overstate durability - the same mistake the Design Lab sidebar used to make.
#
# Speed is move_speed, i.e. after the overload penalty and faction passives,
# because that is the speed the unit will actually travel at. A design that is
# over its weight capacity should read slow on the card, since it will be.
static func stat_line(stats: Dictionary) -> String:
	if stats.is_empty():
		return "stats unavailable"
	var lines: Array = []
	lines.append("HP     %.0f" % float(stats.get("hull_hp", 0.0)))
	lines.append("Speed  %.1f" % float(stats.get("move_speed", 0.0)))
	# An unarmed design (a harvester, a scout, a sensor platform) is a legitimate
	# thing to field, so it says so rather than printing a misleading 0.0.
	if bool(stats.get("has_weapons", false)):
		lines.append("DPS    %.0f" % float(stats.get("dps", 0.0)))
		lines.append("Range  %.0f" % float(stats.get("longest_range", 0.0)))
	else:
		lines.append("unarmed")
	# HARVESTER is the one line here that describes a different KIND of unit
	# rather than a different amount of the same stat, which is why it gets its
	# own row instead of being folded into the "unarmed" branch: a harvester can
	# also be armed, and an unarmed design is very often NOT a harvester. Reading
	# "unarmed" and inferring "economy unit" is a real way to draft twelve slots
	# of scouts and start a match with no income.
	#
	# The payload comes with it because that is the number a hauler is chosen
	# on - a bare arm on a light hull and a bay-laden heavy are both "harvester"
	# and are not remotely the same pick.
	if bool(stats.get("is_harvester", false)):
		lines.append("HARVESTER  %d" % int(stats.get("cargo_capacity", 0)))
	# Power, as the at-rest net. A design that cannot keep its own electronics
	# running browns out in the field - shields first, then its sight, then its
	# energy weapons - and that is not visible anywhere else on this card. HP and
	# Speed both stay at their full printed values right up until the buffer
	# empties, so a card without this row reads as perfectly healthy.
	#
	# The at-rest figure, not the firing one: a burst design that runs a tab
	# against its buffer while shooting is a legitimate build, and flagging it
	# here the same way as a permanently under-powered one would be wrong. The
	# Design Lab draws that distinction in full; a roster card has room for the
	# one that means "this design has a problem".
	var pw: Dictionary = stats.get("power", {})
	if not pw.is_empty():
		lines.append("PWR   %+.1f/s" % float(pw.get("net", 0.0)))
	return "\n".join(PackedStringArray(lines))


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
