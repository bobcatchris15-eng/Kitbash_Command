class_name UIShell
extends RefCounted
# Shared industrial-design screen structure. Screens own routes and game data;
# this file owns the frame, destination controls and structural readouts.
#
# HISTORY, because the name promises more than the file delivers: this started
# as a full shell toolkit - build_screen() to scaffold a full-bleed frame with a
# persistent bottom action bar, column() for side-by-side choices, field() for
# labelled dropdowns, action() for buttons, select_row() for list entries - all
# built to replace the fixed-size-card-floating-in-an-empty-frame shape every
# shell screen used to hand-roll.
#
# Only stat_row() was ever actually adopted. MapSelect, the screen that drove
# the rest of the API, was folded into match_setup.gd's map dropdown, and
# match_setup/operations_setup build their own layouts directly. The other six
# helpers sat here with zero call sites and have been removed; git history has
# them if that architecture is ever revisited.
#
# Structural helper only - all colour and type comes from the theme
# (tools/build_ui_theme.gd), so nothing here hardcodes appearance.

const Tokens = preload("res://scripts/ui_tokens.gd")
const UITheme = preload("res://scripts/ui_theme.gd")
const Feedback = preload("res://scripts/ui_feedback.gd")
const UIPropStageScript = preload("res://scripts/ui/ui_prop_stage.gd")


# ---------------------------------------------------------------------------
# SCREEN SCAFFOLD
# ---------------------------------------------------------------------------
# The two nodes every out-of-match screen opens with: a full-bleed backdrop and
# a margin frame inset from the window edge.
#
# ADDED ON EVIDENCE, not on spec - which is the whole lesson of the history note
# above. These are not a guess at what screens might want; they are what four
# screens were already hand-rolling, and all four call sites move onto them in
# the same commit that adds them. The six helpers that were removed from this
# file had zero call sites because they were written first and adopted never.
#
# The margins were also genuinely DRIFTING, which is the second reason this is
# worth centralising rather than leaving alone:
#
#   main_menu, blueprint_library   SPACE_XL + SPACE_LG / SPACE_LG   (52 / 20)
#   operations_setup               48 / 48 / 36 / 36                (off-grid)
#   loading_screen                 72 / 72 / 56 / 48                (off-grid)
#
# Three different frames for the same job, two of them off the 4px grid the
# spacing tokens exist to enforce. The canonical value is the one the two
# already-correct screens use, which is also the frame UI_STYLE_GUIDE.md's
# main-menu layout section describes.
const SCREEN_MARGIN_H := Tokens.SCREEN_MARGIN_H
const SCREEN_MARGIN_V := Tokens.SCREEN_MARGIN_V


# Full-bleed steel backdrop. Returns it so a caller that wants a non-default
# finish can re-apply a material over the top (match_setup does, deliberately -
# see its own comment).
#
# AUTOMATIC STAGE. Creates a UIPropStage as a sibling of the backdrop so
# every StampedButton and MeshIcon on the screen can find it in their
# ancestor chain. The stage sits between the backdrop and the controls in
# draw order: under the controls (so the 3D content shows through where
# the controls are transparent) and over the backdrop (so the 3D content
# is not eaten by the steel). Its mouse_filter is IGNORE (set on the
# stage itself in _init) so it does not steal clicks - that is the
# documented failure mode in TACTILE_INTERFACE_PLAN.md Part 4 Phase 1.
static func backdrop(parent: Node) -> ColorRect:
	var bg := ColorRect.new()
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	# IGNORE, always: the backdrop sits under every control on the screen, and a
	# full-rect rect that accepts mouse input swallows clicks meant for them.
	bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	parent.add_child(bg)
	UITheme.apply_backdrop(bg)
	stage(parent)
	return bg


# Full-bleed L0 workbench backdrop. The out-of-match screens sit on a hobby
# desk - a cutting mat, a sheet of cardboard, kraft paper, a corkboard, or
# chipboard - rather than on the steel the in-match screens use. The choice
# is per-screen: matching_setup, livery_editor and operations_draft pick a
# different L0 each, so the surfaces that surround the same match
# configuration do not all read as one continuous desk.
#
# `material` must be one of UITheme.MATERIALS's L0 entries. Anything else
# is a category error (workbench is a backdrop register, not a control
# register) and is refused with a warning rather than silently falling
# through to a flat colour.
#
# The brightness rule still governs: L0 materials carry their own per-
# material brightness in UITheme.MATERIAL_DEFAULTS so the final luminance
# lands below the powdercoat panel body. If a screen's panels sink into
# the field, darken the field's brightness at the call site with an
# override - do not raise the panels.
#
# AUTOMATIC STAGE. Same as backdrop(): creates a UIPropStage alongside
# the field so every StampedButton / MeshIcon on the screen finds it in
# their ancestor chain. See backdrop()'s note on ordering and the
# IGNORE mouse_filter.
static func workbench(parent: Node, material: String) -> ColorRect:
	const L0_MATERIALS = ["cutting_mat", "cardboard", "kraft", "cork", "chipboard"]
	if material not in L0_MATERIALS:
		push_warning("UIShell.workbench: '%s' is not an L0 workbench material. Expected one of %s." % [material, L0_MATERIALS])
	var bg := ColorRect.new()
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	parent.add_child(bg)
	UITheme.apply_material(bg, material)
	stage(parent)
	return bg


# The shared 3D UI viewport for the screen. One per screen, sitting
# between the backdrop and the controls in draw order. Every
# StampedButton and MeshIcon on the screen looks up the stage via
# _find_stage() in their own _ready and uses it for the 3D rendering
# of their prop.
#
# Idempotent: a second call on the same parent returns the existing
# stage. backdrop() and workbench() both call this on the way out,
# so any screen that uses one of them already has a stage by the
# time its own _ready runs the rest of its UI assembly. A screen
# that does not call UIShell.backdrop() or workbench() (match_setup,
# the Settings panel, the Lab toolbar) calls stage() explicitly
# after it builds its own backdrop.
#
# WHY A FULL-BLEED STAGE INSTEAD OF A SMALLER ONE: the stage's rect
# IS the screen rect, by design. The ortho camera in the stage
# (see UIPropStage for the math) uses the stage's size to set the
# world-to-pixel ratio, and every prop on the stage is positioned
# relative to the stage's centre. A non-full-bleed stage would
# shift the world origin and break the rect-to-world mapping the
# test suite asserts on.
static func stage(parent: Node) -> UIPropStage:
	# Check for an existing stage first. A second call on the same
	# parent is a no-op, which makes the API safe to call from
	# both UIShell.backdrop() AND a screen's own _ready().
	for child in parent.get_children():
		if child is UIPropStage:
			return child
	var s := UIPropStageScript.new()
	s.name = "PropStage"
	s.set_anchors_preset(Control.PRESET_FULL_RECT)
	# mouse_filter is MOUSE_FILTER_IGNORE - set in the stage's _init;
	# re-asserting here is cheap and documents the invariant at the
	# call site that installs the stage.
	s.mouse_filter = Control.MOUSE_FILTER_IGNORE
	parent.add_child(s)
	return s


# The margin frame content is laid out inside. Pass overrides only for a screen
# that genuinely needs a different inset, and say why at the call site.
static func screen_frame(parent: Node, margin_h: int = SCREEN_MARGIN_H,
		margin_v: int = SCREEN_MARGIN_V) -> MarginContainer:
	var frame := MarginContainer.new()
	frame.set_anchors_preset(Control.PRESET_FULL_RECT)
	frame.mouse_filter = Control.MOUSE_FILTER_IGNORE
	frame.add_theme_constant_override("margin_left", margin_h)
	frame.add_theme_constant_override("margin_right", margin_h)
	frame.add_theme_constant_override("margin_top", margin_v)
	frame.add_theme_constant_override("margin_bottom", margin_v)
	parent.add_child(frame)
	return frame


# Entries: {id: String, label: String, disabled?: bool, tooltip?: String}.
# Emits intent through on_navigate(id); only the owning screen changes scenes.
# The current destination stays latched until the owner rebuilds the spine.
static func navigation_spine(parent: Node, destinations: Array[Dictionary],
		current: String, on_navigate: Callable) -> HBoxContainer:
	var spine := HBoxContainer.new()
	spine.name = "NavigationSpine"
	spine.mouse_filter = Control.MOUSE_FILTER_IGNORE
	spine.add_theme_constant_override("separation", Tokens.NAVIGATION_GAP)
	parent.add_child(spine)
	for destination: Dictionary in destinations:
		var id: String = destination.get("id", "")
		var button := action(spine, destination.get("label", id),
			"active" if id == current else "secondary", "select")
		button.set_meta(&"destination_id", id)
		button.tooltip_text = destination.get("tooltip", "")
		button.disabled = destination.get("disabled", false)
		button.toggle_mode = true
		button.set_pressed_no_signal(id == current)
		button.pressed.connect(func() -> void:
			button.set_pressed_no_signal(id == current)
			if not button.disabled and id != current and on_navigate.is_valid():
				on_navigate.call(id)
		)
	return spine

static func action(parent: Node, text: String, role: String = "secondary",
		feedback_role: String = "default") -> Button:
	var button := Button.new()
	button.text = text
	UITheme.apply_action(button, role)
	button.disabled = role == "disabled"
	parent.add_child(button)
	Feedback.wire(button, feedback_role)
	return button


# A label/value pair for a specification readout. Value uses the tabular
# monospace face so a column of these lines up.
static func stat_row(parent: Control, label_text: String, value_text: String) -> Label:
	var row = HBoxContainer.new()
	row.add_theme_constant_override("separation", Tokens.SPACE_SM)
	parent.add_child(row)

	var key = Label.new()
	key.text = label_text
	key.theme_type_variation = "HintLabel"
	key.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(key)

	var value = Label.new()
	value.text = value_text
	value.theme_type_variation = "StatLabel"
	value.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	row.add_child(value)
	return value
