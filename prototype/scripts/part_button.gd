extends Button

var module_type_id: String = ""

func _ready() -> void:
	if has_meta("thumbnail_rect"):
		var thumb: TextureRect = get_meta("thumbnail_rect")
		var cache = _get_thumbnail_cache()
		if cache != null:
			var existing = cache.get_thumbnail_now(module_type_id)
			if existing != null:
				thumb.texture = existing
				print("Thumb loaded immediately for: ", module_type_id)
			else:
				print("Running async bake for: ", module_type_id)
				_run_bake(cache, thumb)
		else:
			print("ERROR: No cache found in part_button _ready!")
	else:
		print("ERROR: No thumbnail_rect meta on button for: ", module_type_id)

# When a drag exits the toolbox panel while carrying a module_part, spin up
# the 3D ghost immediately so it is already tracking the hull by the time
# the cursor reaches the 3D viewport.
func _gui_input(event: InputEvent) -> void:
	if not (event is InputEventMouseButton or event is InputEventMouseMotion):
		return
	if not get_viewport().gui_is_dragging():
		return
	var drag_data = get_viewport().gui_get_drag_data()
	if typeof(drag_data) != TYPE_DICTIONARY:
		return
	if drag_data.get("type", "") != "module_part":
		return
	var local_pos := get_local_mouse_position()
	if not get_rect().has_point(local_pos):
		var ddm := get_node_or_null("/root/MainLab/DragDropManager")
		if ddm and ddm.has_method("show_ghost_for_drag"):
			ddm.show_ghost_for_drag(module_type_id, get_global_mouse_position())

# VISUAL_IMPROVEMENT_PLAN.md chunk G: Godot's default tooltip is a plain
# PopupPanel - this overrides the virtual _make_custom_tooltip() Godot
# itself calls to build one, returning a styled card instead. `for_text` is
# whatever this button's own `tooltip_text` is currently set to (parts_menu.
# gd's _stat_tooltip() - "<name>\nHP: ... | Weight: ...\nCost: ...\nDPS: ...")
# - split on newlines into a bold title row (the part name) plus smaller
# stat rows below, matching the "icon + title + stat rows" card shape the
# plan calls for (no icon graphic system exists in this project yet - see
# VISUAL_IMPROVEMENT_PLAN.md's own note that every "icon" today is emoji in
# button text, which the title row already carries through unchanged).
func _make_custom_tooltip(for_text: String) -> Control:
	var panel = PanelContainer.new()
	# CANVAS from the theme, the same soft backing the flyouts and callouts use -
	# a tooltip is exactly that category of object, laid over the interface rather
	# than built into it.
	#
	# The inline stylebox this replaces was a blue-black fill with a 5px "Yellow
	# Model Kit Instruction Decal Border" and 4px corners: three separate values
	# that appear nowhere in ui_tokens.gd, on the one card a player reads dozens of
	# times per session while comparing parts.
	panel.theme_type_variation = "FlyoutPanel"

	var vbox = VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 3)
	panel.add_child(vbox)

	var lines = for_text.split("\n")
	if lines.is_empty():
		return panel
	var title = Label.new()
	title.text = lines[0]
	title.theme_type_variation = "HeadingLabel"
	vbox.add_child(title)
	for i in range(1, lines.size()):
		var row = Label.new()
		row.text = lines[i]
		# StatLabel: these rows ARE stats ("HP: 75 | Weight: 65 kg"), and the mono
		# face is what makes a column of them comparable between two tooltips.
		row.theme_type_variation = "StatLabel"
		vbox.add_child(row)

	# Flavor row (VISUAL_ART_DIRECTION.md 1.2 - the tone target's cheapest
	# detail-scale channel; see ModuleCatalog.MODULE_FLAVOR for the voice
	# rules). Looked up from module_type_id rather than parsed out of
	# `for_text`: keeps tooltip_text as pure stat data with no sentinel
	# encoding, and means the flavor line can't be mistaken for a stat row
	# by anything else reading that string.
	var flavor := ""
	if module_type_id != "":
		flavor = ModuleCatalog.get_module_flavor(module_type_id)
	if flavor != "":
		# Thin rule separating hard numbers from voice, so the card doesn't
		# read as though the flavor line were another stat.
		var sep = HSeparator.new()
		sep.add_theme_constant_override("separation", 6)
		vbox.add_child(sep)

		var flavor_label = Label.new()
		flavor_label.text = flavor
		# HintLabel is the secondary-text role: present but subordinate, so the
		# voice line never competes with the numbers a player is comparing. That is
		# what the old hand-mixed (0.62, 0.60, 0.55) was approximating - it is
		# within a hair of Tokens.TEXT_SECONDARY, which HintLabel already carries.
		flavor_label.theme_type_variation = "HintLabel"
		# These lines run to ~90 chars; without an explicit wrap the tooltip
		# card would stretch into a single very wide strip.
		flavor_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		flavor_label.custom_minimum_size = Vector2(260, 0)
		vbox.add_child(flavor_label)

	return panel

func _get_drag_data(at_position: Vector2):
	# No 2D cursor-following preview here. DragDropManager's 3D ghost (spawned
	# by show_ghost_for_drag() below and kept live by _can_drop_data()) is the
	# only drag preview now - a flat thumbnail chip riding the OS cursor was a
	# second, disconnected preview that never got cleared in step with the 3D
	# one, so both stayed on screen at once.
	return {"type": "module_part", "id": module_type_id}


# The cache lives on MainLab as a sibling node (see MainLab.tscn). The
# button is created in the parts menu deep inside UI_PartsMenu, so a
# direct path lookup is the cleanest reach. Returns null if MainLab has
# been torn down (test teardown, scene swap) so the preview falls back
# to the label-only form rather than crashing.
func _get_thumbnail_cache() -> Node:
	var tree := get_tree()
	if tree == null:
		return null
	if tree.root != null:
		var lab := tree.root.get_node_or_null("MainLab")
		if lab and lab.get_node_or_null("PartThumbnailCache"):
			return lab.get_node_or_null("PartThumbnailCache")
	if tree.current_scene != null:
		var cache = tree.current_scene.get_node_or_null("PartThumbnailCache")
		if cache != null:
			return cache
	if tree.root != null:
		var cache = tree.root.find_child("PartThumbnailCache", true, false)
		if cache != null:
			return cache
	return null


func _run_bake(cache: Node, target: TextureRect) -> void:
	var tex: Texture2D = await cache.get_thumbnail(module_type_id)
	# The button or the texture rect can have been freed between the
	# bake and its await resuming (parts-menu rebuild, scene swap, a
	# fast second click). is_instance_valid guards both without having
	# to track ownership.
	if tex != null and is_instance_valid(target):
		target.texture = tex
		print("Bake complete for: ", module_type_id, " tex: ", tex)
	else:
		print("Bake failed or target invalid for: ", module_type_id)
