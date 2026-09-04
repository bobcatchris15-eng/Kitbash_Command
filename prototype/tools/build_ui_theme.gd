@tool
extends MainLoop
# Generates res://resources/bomber_theme.tres from the tokens in
# scripts/ui_tokens.gd. Run:
#   ./Godot_v4.3-stable_win64_console.exe --headless --script tools/build_ui_theme.gd --quit-after 2
#
# The theme is generated rather than hand-edited in the inspector so the
# palette lives in reviewable source and one token change repaints the whole
# interface. Do not edit bomber_theme.tres directly - it is an artifact.
#
# Coverage matters here. The previous version styled Panel, Button and two
# Label variations and nothing else, so every OptionButton, CheckBox,
# ProgressBar, ScrollBar and LineEdit in the game fell through to Godot's
# stock grey-blue default theme. That is the actual reason the shipped
# screens looked like a mix of two products: they were.

const Tokens = preload("res://scripts/ui_tokens.gd")
const ThemeHelpers = preload("res://scripts/ui_theme.gd")

func _process(_delta: float) -> bool:
	build_theme()
	return true

func _load_font(path: String) -> FontFile:
	var font = FontFile.new()
	if font.load_dynamic_font(path) == OK:
		return font
	if ResourceLoader.exists(path):
		var res = load(path)
		if res is FontFile:
			return res as FontFile
	return null

# StyleBoxFlat has no set_*_all() helpers in Godot 4 (they were Godot 3 APIs -
# calling them silently aborted the rest of the styling function, which is how
# the old theme's borders quietly never applied). These wrap the per-side
# assignment so that mistake can't recur.
func _flat(bg: Color, border: Color, border_width: int, radius: int) -> StyleBoxFlat:
	var sb = StyleBoxFlat.new()
	sb.bg_color = bg
	sb.border_color = border
	sb.border_width_left = border_width
	sb.border_width_right = border_width
	sb.border_width_top = border_width
	sb.border_width_bottom = border_width
	sb.corner_radius_top_left = radius
	sb.corner_radius_top_right = radius
	sb.corner_radius_bottom_left = radius
	sb.corner_radius_bottom_right = radius
	return sb

func _pad(sb: StyleBox, h: int, v: int) -> StyleBox:
	sb.content_margin_left = h
	sb.content_margin_right = h
	sb.content_margin_top = v
	sb.content_margin_bottom = v
	return sb


# ---------------------------------------------------------------------------
# MATERIAL PLATES
# ---------------------------------------------------------------------------
# The theme is now built from StyleBoxTexture over the plates baked by
# tools/generate_ui_plates.py, not from flat fills.
#
# WHY THIS IS THE HIGHEST-LEVERAGE PIECE OF THE WHOLE MATERIAL PASS: a Theme
# resource can carry a StyleBoxTexture. So assigning a moulded plate to
# "Button" here repaints every Button in the game - in the Design Lab, in the
# Skirmish HUD, in every dialog - with no call-site edits at all. Colour alone
# could never have got the interface to read as physical; this is what does.
#
# THE 9-SLICE CONTRACT, which generate_ui_plates.py holds up the other end of:
# Godot stretches the CENTRE region of a StyleBoxTexture to fill the control
# and leaves the margin ring unstretched. So the plates carry all of their
# bevel and outline inside a 12px margin and keep the centre flat and
# tileable. texture_margin_* below must match PLATE_MARGIN there or the bevel
# either gets stretched into a smear or gets sliced through the middle.
func _plate_texture(material: String, state: String) -> Texture2D:
	var texture := ThemeHelpers.industrial_plate_texture(material, state)
	if texture == null:
		# Loud, because the silent version of this failure is a theme that
		# builds "successfully" and renders every control as a blank box.
		push_error("build_ui_theme: missing industrial plate %s/%s" % [material, state])
		return null
	return texture

# One styleboxed plate. `h`/`v` are content margins - the padding INSIDE the
# control, unrelated to the 9-slice texture margin.
func _plate(material: String, state: String, h: int, v: int) -> StyleBox:
	var tex = _plate_texture(material, state)
	if tex == null:
		# Degrade to a flat box rather than returning null, which Godot would
		# render as "no style at all" and make the failure look cosmetic.
		return _pad(_flat(Tokens.BASE_700, Tokens.BASE_500,
			Tokens.BORDER_HAIRLINE, Tokens.RADIUS_CONTROL), h, v)
	var plate_spec: Dictionary = ThemeHelpers.industrial_material_spec(material).get("plate", {})
	var sb = StyleBoxTexture.new()
	sb.texture = tex
	# The unstretched frame now has to cover the shadow pad as well as the bevel,
	# or the 9-slice stretches the shadow along with the centre and every wide
	# panel gets a smeared grey band down its sides.
	var frame: int = plate_spec.get("slice", 28)
	sb.texture_margin_left = frame
	sb.texture_margin_right = frame
	sb.texture_margin_top = frame
	sb.texture_margin_bottom = frame

	# THE LOAD-BEARING PART. expand_margin lets the box draw OUTSIDE the
	# control's rect, which is what keeps the 96px body aligned to the rect the
	# layout actually assigned. Without it the visible panel shrinks by
	# PLATE_PAD on every side and every margin, gutter and column alignment in
	# every screen silently shifts by 16px.
	var expand: int = plate_spec.get("expand", 16)
	sb.expand_margin_left = expand
	sb.expand_margin_right = expand
	sb.expand_margin_top = expand
	sb.expand_margin_bottom = expand
	return _pad(sb, h, v)


# A plate finished in a signal colour.
#
# StyleBoxTexture has NO border properties - that is a real constraint, not an
# oversight, and it is the one thing lost in moving off StyleBoxFlat. So a
# signal role cannot be "grey material plus a coloured hairline" any more.
#
# Rather than fake a border by stacking boxes (Godot draws one stylebox per
# control state, so there is nowhere to stack them), the signal becomes a
# property OF THE MATERIAL: the plate is modulated toward the role colour, so
# a danger control is a placard actually finished in hazard amber-red and a
# primary control is carbon with a green cast. This is arguably the more
# honest reading anyway - real equipment signals with the colour of the part,
# not with a stroke around it.
#
# Modulation is kept well below 1.0 saturation. Multiplying a plate by a fully
# saturated signal colour crushes the material texture out of it entirely and
# leaves a flat coloured rectangle, which loses the whole point of the plate.
func _plate_tinted(material: String, state: String, role: Color,
		h: int, v: int, strength: float = 0.55) -> StyleBox:
	var sb = _plate(material, state, h, v)
	if sb is StyleBoxTexture:
		(sb as StyleBoxTexture).modulate_color = Color.WHITE.lerp(role * 1.6, strength)
	return sb

func build_theme() -> void:
	print("Building theme -> res://resources/bomber_theme.tres")
	var manifest := ThemeHelpers.industrial_manifest()
	if manifest.get("schema", "") != "kitbash-command.ui.industrial.v2":
		push_error("build_ui_theme: industrial manifest is missing or has an unsupported schema")
		return
	var theme = Theme.new()

	var ui_reg = _load_font("res://assets/fonts/UIFont-Regular.ttf")
	var ui_bold = _load_font("res://assets/fonts/UIFont-Bold.ttf")
	var mono_reg = _load_font("res://assets/fonts/MonoFont-Regular.ttf")
	var stencil = _load_font("res://assets/fonts/StencilFont-Regular.ttf")

	# The DEFAULT font is the clean UI sans, not the stencil face.
	#
	# This is a deliberate reversal. The stencil (Special Elite - a worn
	# typewriter face) used to be the default, which meant every label,
	# button, tooltip and dropdown in the game rendered in a deliberately
	# irregular, ink-blotted typeface at 13-15px. It gives one strong
	# impression on a title and becomes unreadable mush in a 24-row parts
	# list - see the MainLab and MatchSetup baseline captures, where the
	# body text is genuinely hard to parse.
	#
	# The stencil now does what a display face should: titles and section
	# headers, where it is large, short, and carrying the tone on its own.
	if ui_reg:
		ui_reg.multichannel_signed_distance_field = true
		theme.set_default_font(ui_reg)
	elif stencil:
		theme.set_default_font(stencil)
	theme.set_default_font_size(Tokens.FONT_BODY)

	_build_panels(theme)
	_build_buttons(theme)
	ThemeHelpers.configure_typography(theme, ui_reg, ui_bold, stencil, mono_reg)
	_build_inputs(theme)
	_build_bars(theme)
	_build_misc(theme)
	_build_industrial_assets(theme)
	# MUST come after the builders above - see _register_variations().
	_register_variations(theme)

	var err = ResourceSaver.save(theme, "res://resources/bomber_theme.tres")
	print("  saved" if err == OK else "  FAILED, error %d" % err)


# Publish the complete authored kit into the generated Theme. Screens may use
# the semantic vector/field registries directly, while plate theme types expose
# reusable four-state 9-slices without duplicating margin or asset-path logic.
func _build_industrial_assets(theme: Theme) -> void:
	var manifest := ThemeHelpers.industrial_manifest()
	var vectors: Dictionary = manifest.get("vectors", {})
	for key: String in vectors:
		var icon := ThemeHelpers.industrial_icon(key)
		if icon != null:
			theme.set_icon(key, ThemeHelpers.INDUSTRIAL_ICON_TYPE, icon)

	var materials: Dictionary = manifest.get("materials", {})
	for material: String in materials:
		var field := ThemeHelpers.industrial_material_field(material)
		if field != null:
			theme.set_icon(material, ThemeHelpers.INDUSTRIAL_FIELD_TYPE, field)
		var material_spec: Dictionary = materials[material]
		var plate_spec: Dictionary = material_spec.get("plate", {})
		var type_name: String = material_spec.get("theme_type", "")
		if plate_spec.is_empty() or type_name.is_empty():
			continue
		var states: Dictionary = plate_spec.get("states", {})
		for state: String in states:
			theme.set_stylebox(state, type_name, _plate(material, state, 0, 0))


# Every theme type variation MUST be registered against its base class or
# Godot never resolves it.
#
# This was silently broken for the entire life of the old theme. Setting
# `theme_type_variation = "CardPanel"` on a PanelContainer does nothing
# unless the Theme also knows CardPanel derives from PanelContainer - the
# lookup finds no such type and quietly falls back to the control's own
# class. So every CardPanel, HeaderPanel, TitleLabel, PrimaryButton and
# DangerButton in the game was rendering as a plain Panel/Label/Button.
#
# It was invisible because the old theme's default font was the stencil
# face, which made the "TitleLabel" headings look intentional. They were
# just inheriting the default.
#
# There is no error and no warning for this. The only symptom is a control
# that looks slightly plainer than expected, which is exactly the kind of
# thing that survives review for months.
#
# ORDERING, learned the hard way: set_type_variation_base() only takes on a
# theme type that ALREADY EXISTS. Called before the styleboxes/fonts that
# create the type, it is silently discarded - nothing is written and nothing
# complains. So this runs last, after every builder has populated its types.
# Verified with scratch/probe_theme.gd, which asks a live Control what it
# resolves rather than trusting the saved .tres.
const VARIATION_BASES = {
	"CardPanel": "PanelContainer",
	"HeaderPanel": "PanelContainer",
	"HUDPanel": "PanelContainer",
	"InsetPanel": "PanelContainer",
	"DockPanel": "PanelContainer",
	"DockRail": "PanelContainer",
	"FlyoutPanel": "PanelContainer",
	"CalloutPanel": "PanelContainer",
	"PrimaryButton": "Button",
	"DangerButton": "Button",
	"TabButton": "Button",
	"ListButton": "Button",
	"NavCard": "Button",
	"DisplayLabel": "Label",
	"TitleLabel": "Label",
	"HeadingLabel": "Label",
	"HintLabel": "Label",
	"HUDValueLabel": "Label",
	"StatLabel": "Label",
	# Command Console additions
	"BakelitePanel": "PanelContainer",
	"WoodPanel": "PanelContainer",
	"FoldedPaperPanel": "PanelContainer",
	"CRTReadout": "PanelContainer",
	"DrawerTab": "Button",
	"AlertIcon": "Button",
	"QuickJumpPill": "Button",
	"QueueItemButton": "Button",
}

func _register_variations(theme: Theme) -> void:
	# NOTE the asymmetric API: the setter is set_type_variation(), but the
	# getter is get_type_variation_base(). Calling the plausible-sounding
	# set_type_variation_base() raises "Nonexistent function" - which, in a
	# @tool MainLoop, does not stop the build. The theme saved "successfully"
	# with the variation bases missing, so the only visible symptom was
	# controls continuing to render as their plain base class.
	for variation in VARIATION_BASES:
		theme.set_type_variation(variation, VARIATION_BASES[variation])


func _build_panels(theme: Theme) -> void:
	# Base panel: opaque enough to actually be a surface. The old panel was
	# 0.88 alpha and several screens used no panel at all, so text was
	# landing directly on the 3D viewport (see the MainLab baseline capture -
	# the entire right-hand stat column is unreadable against the sky).
	# Chrome that a player reads mid-fight is not a place for transparency.
	# POWDERCOAT.
	var panel = _plate("powdercoat", "normal", Tokens.SPACE_MD, Tokens.SPACE_MD)
	theme.set_stylebox("panel", "Panel", panel)
	theme.set_stylebox("panel", "PanelContainer", panel)

	# CardPanel - a free-floating card on a backdrop (menus, dialogs). Same
	# material as the base panel but roomier. A card earns its separation from
	# the backdrop by the BACKDROP being held darker (UITheme.apply_backdrop
	# runs it at 0.42 brightness), not by being a different colour itself.
	theme.set_stylebox("panel", "CardPanel",
		_plate("powdercoat", "normal", Tokens.SPACE_XL, Tokens.SPACE_LG))

	# HeaderPanel - a titled band. Its identity is the hazard underline, not
	# a fill, so it can sit on top of any panel without introducing a
	# third background value.
	#
	# Kept as a StyleBoxFlat deliberately - the one survivor in this function.
	# An underline is a RULE, not a material, and StyleBoxTexture has no border
	# properties, so expressing it as a plate would mean tinting the whole band
	# amber to get an amber edge.
	var header = _flat(Tokens.BASE_700, Tokens.SIGNAL_HAZARD, 0, 0)
	header.border_width_bottom = Tokens.BORDER_EMPHASIS
	_pad(header, Tokens.SPACE_MD, Tokens.SPACE_SM)
	theme.set_stylebox("panel", "HeaderPanel", header)

	# HUDPanel - in-match chrome. The "pressed" plate, which is the same
	# powdercoat held darker with its bevel inverted - it reads as recessed into
	# the frame, and it keeps unit colours from bleeding through and confusing
	# ownership reads.
	theme.set_stylebox("panel", "HUDPanel",
		_plate("powdercoat", "pressed", Tokens.SPACE_SM, Tokens.SPACE_XS))

	# InsetPanel - a recessed well (list backgrounds, viewport surrounds).
	# CANVAS: a drawer lined with duck cloth. This is the one material with a
	# genuinely different tactile read from the metal around it, which is what
	# makes a recess look recessed rather than merely darker.
	theme.set_stylebox("panel", "InsetPanel",
		_plate("canvas", "pressed", Tokens.SPACE_SM, Tokens.SPACE_SM))

	# The dock and flyout primitives (scripts/ui_dock.gd, ui_flyout.gd).
	theme.set_stylebox("panel", "DockPanel",
		_plate("powdercoat", "normal", Tokens.SPACE_SM, Tokens.SPACE_SM))
	theme.set_stylebox("panel", "DockRail",
		_plate("steel", "normal", Tokens.SPACE_XS, Tokens.SPACE_SM))
	theme.set_stylebox("panel", "FlyoutPanel",
		_plate("canvas", "normal", Tokens.SPACE_MD, Tokens.SPACE_MD))

	# CalloutPanel - the annotation panels hanging off a selected module
	# (scripts/tweak_callout.gd). Same CANVAS duck as a flyout, because it is the
	# same kind of object: a soft thing laid over the model rather than chrome
	# welded to the frame.
	#
	# Tighter margins than FlyoutPanel, and that is the whole reason this is a
	# separate variation rather than a reuse. A callout is a label-sized panel
	# sitting a few dozen pixels from the geometry it points at, and there are up
	# to eight of them on screen at once; FlyoutPanel's SPACE_MD ring made them
	# large enough to collide with each other before tweak_callout.gd's overlap
	# resolution had any room to work.
	#
	# The hub/satellite signal edge is NOT here. It is a rule, not a material -
	# same reasoning as HeaderPanel above - and it also has to change colour per
	# callout, which a shared theme entry cannot do. tweak_callout.gd draws it as
	# a strip inside this plate.
	theme.set_stylebox("panel", "CalloutPanel",
		_plate("canvas", "normal", Tokens.SPACE_XS, 2))

	# BakelitePanel - commander's desk surface. Warm plastic with baked bevel.
	theme.set_stylebox("panel", "BakelitePanel",
		_plate("bakelite", "normal", Tokens.SPACE_MD, Tokens.SPACE_MD))

	# WoodPanel - paint bay and workbench dock surface.
	theme.set_stylebox("panel", "WoodPanel",
		_plate("wood", "normal", Tokens.SPACE_MD, Tokens.SPACE_MD))

	# FoldedPaperPanel - slide-up drawer panels. Canvas/duck cloth texture.
	theme.set_stylebox("panel", "FoldedPaperPanel",
		_plate("canvas", "pressed", Tokens.SPACE_MD, Tokens.SPACE_MD))

	# CRTReadout - phosphor display panel. Uses shader, not plate.
	var crt = _flat(Tokens.PHOSPHOR_GLASS, Color(0, 0, 0, 0), 0, 0)
	_pad(crt, Tokens.BEZEL_INSET, Tokens.BEZEL_INSET)
	theme.set_stylebox("panel", "CRTReadout", crt)


func _build_buttons(theme: Theme) -> void:
	# MOULDED. Heavy moulded mechanical switches.
	#
	# The physical press language survives the move off StyleBoxFlat, because
	# it worked - it is just carried by the plate now instead of by border
	# widths. At rest the plate's bevel lights the TOP edge; the pressed plate
	# inverts that and lights the BOTTOM (see STATES in
	# tools/generate_ui_plates.py). A control that changes WHICH WAY it catches
	# light reads as physically moving; one that merely darkens reads as
	# changing colour.
	# Padding widened from MD/SM to LG/MD. A moulded switch has a bezel around
	# its legend - the old 12/8 put the label almost on the bevel, which read as
	# cramped and made the plate look like a tight box around text rather than a
	# faceplate with text on it. LG/MD also carries the label clear of the 12px
	# bevel ring, so the grain under small text stops competing with it.
	#
	# The vertical MD also puts the button's natural height at 12 + ~15 + 12 =
	# ~39px, clear of Tokens.HIT_TARGET_MIN (32) without needing a per-call
	# custom_minimum_size. Theme has no minimum-height constant for Button, so
	# content margins are the only place this can be expressed centrally.
	var normal = _plate("moulded", "normal", Tokens.SPACE_LG, Tokens.SPACE_MD)
	var hover = _plate("moulded", "hover", Tokens.SPACE_LG, Tokens.SPACE_MD)
	var pressed = _plate("moulded", "pressed", Tokens.SPACE_LG, Tokens.SPACE_MD)
	var disabled = _plate("moulded", "disabled", Tokens.SPACE_LG, Tokens.SPACE_MD)

	# Focus stays a hazard hairline. Focus is a state of the INTERFACE - where
	# keyboard attention is - not a property of the object, so it should not
	# look like the control changed material.
	var focus = _flat(Color(0, 0, 0, 0), Tokens.SIGNAL_HAZARD,
		2, Tokens.RADIUS_CONTROL)

	# NAVCARD - the main menu's destination cards.
	#
	# This resolves the open question in UI_IMPLEMENTATION_PLAN.md about whether
	# these stay as per-instance styleboxes. They become a real variation, but
	# deliberately a FLAT one rather than a plate: the card's identity is an
	# asymmetric left gutter that thickens on hover, and a 9-sliced plate texture
	# has no border properties at all (see _plate_tinted's comment) so it cannot
	# express one. This is the one place a flat stylebox is the right answer.
	#
	# It replaces main_menu.gd's _create_industrial_button_style(), whose colours
	# were hardcoded cool blue-greys - Color(0.12, 0.13, 0.15) and friends, the
	# exact drifted off-palette accent ui_tokens.gd's header calls out - with
	# 4px and 6px borders against a BORDER_EMPHASIS of 2.
	var nav_normal := _flat(Tokens.BASE_800, Tokens.BASE_500,
		Tokens.BORDER_HAIRLINE, Tokens.RADIUS_PANEL)
	# The gutter. Persistent 3px at rest (was 5, only visible on hover before)
	# so the card reads as interactive even when not hovered.
	nav_normal.border_width_left = 3
	Tokens.apply_elevation(nav_normal, "raised")

	var nav_hover := _flat(Tokens.BASE_700, Tokens.SIGNAL_HAZARD,
		Tokens.BORDER_EMPHASIS, Tokens.RADIUS_PANEL)
	nav_hover.border_width_left = 6
	Tokens.apply_elevation(nav_hover, "floating")

	# Pressed uses the DIM hazard fill, not the full signal colour: a card the
	# player is holding down should warm, not light up like a warning.
	var nav_pressed := _flat(Tokens.SIGNAL_HAZARD_DIM, Tokens.SIGNAL_HAZARD,
		Tokens.BORDER_EMPHASIS, Tokens.RADIUS_PANEL)
	nav_pressed.border_width_left = 6
	Tokens.apply_elevation(nav_pressed, "flush")

	var nav_pad := Vector2i(Tokens.SPACE_MD, Tokens.SPACE_SM)
	theme.set_stylebox("normal", "NavCard", _pad(nav_normal, nav_pad.x, nav_pad.y))
	theme.set_stylebox("hover", "NavCard", _pad(nav_hover, nav_pad.x, nav_pad.y))
	theme.set_stylebox("pressed", "NavCard", _pad(nav_pressed, nav_pad.x, nav_pad.y))
	theme.set_stylebox("disabled", "NavCard", _pad(nav_normal, nav_pad.x, nav_pad.y))
	theme.set_stylebox("focus", "NavCard", focus)
	theme.set_color("font_color", "NavCard", Tokens.TEXT_PRIMARY)
	theme.set_color("font_hover_color", "NavCard", Tokens.TEXT_PRIMARY)
	theme.set_color("font_pressed_color", "NavCard", Tokens.TEXT_PRIMARY)

	for type in ["Button", "MenuButton", "OptionButton"]:
		theme.set_stylebox("normal", type, normal)
		theme.set_stylebox("hover", type, hover)
		theme.set_stylebox("pressed", type, pressed)
		theme.set_stylebox("disabled", type, disabled)
		theme.set_stylebox("focus", type, focus)
		theme.set_color("font_color", type, Tokens.TEXT_PRIMARY)
		theme.set_color("font_hover_color", type, Color(1, 1, 1))
		theme.set_color("font_pressed_color", type, Tokens.TEXT_SECONDARY)
		theme.set_color("font_disabled_color", type, Tokens.TEXT_DISABLED)
		# The plates are dark and TEXTURED - a weave or a grain running under
		# small text makes it vibrate, so every label gets a little separation.
		theme.set_color("font_outline_color", type, Color.BLACK)
		theme.set_constant("outline_size", type, 3)
		theme.set_constant("h_separation", type, Tokens.SPACE_SM)
		# ICON STATE. tools/generate_icons.py authors every icon in one neutral
		# stroke (TEXT_SECONDARY) on the rule that colour belongs to the control's
		# state rather than to the glyph - so the control has to actually supply it.
		# These are MODULATES over the authored colour, hence WHITE for "as
		# authored" rather than a colour of their own; anything else would tint a
		# grey icon.
		theme.set_color("icon_normal_color", type, Color.WHITE)
		theme.set_color("icon_hover_color", type, Color.WHITE)
		theme.set_color("icon_pressed_color", type, Color.WHITE)
		# The one that earns its keep: a disabled button's icon dims WITH the
		# button. Previously the icons carried their own saturated colours, so a
		# greyed-out build button kept a bright sky-blue glyph on a darkened plate
		# and read as still-clickable.
		theme.set_color("icon_disabled_color", type, Color(0.45, 0.45, 0.45, 0.7))

	# PrimaryButton - CARBON, cast toward go-green. Carbon is deliberately
	# rationed across the whole interface (see UITheme.MATERIALS); spending it
	# on the single primary action per screen is what keeps it meaning
	# "this is the one".
	theme.set_stylebox("normal", "PrimaryButton",
		_plate_tinted("carbon", "normal", Tokens.SIGNAL_GO,
			Tokens.SPACE_MD, Tokens.SPACE_SM, 0.45))
	theme.set_stylebox("hover", "PrimaryButton",
		_plate_tinted("carbon", "hover", Tokens.SIGNAL_GO,
			Tokens.SPACE_MD, Tokens.SPACE_SM, 0.60))
	theme.set_stylebox("pressed", "PrimaryButton",
		_plate_tinted("carbon", "pressed", Tokens.SIGNAL_GO,
			Tokens.SPACE_MD, Tokens.SPACE_SM, 0.45))
	theme.set_stylebox("disabled", "PrimaryButton", disabled)
	theme.set_stylebox("focus", "PrimaryButton", focus)
	theme.set_color("font_color", "PrimaryButton", Color(0.88, 1.0, 0.88))
	theme.set_color("font_outline_color", "PrimaryButton", Color.BLACK)
	theme.set_constant("outline_size", "PrimaryButton", 3)
	theme.set_color("font_disabled_color", "PrimaryButton", Tokens.TEXT_DISABLED)

	# DangerButton - Machined BIG RED BUTTON
	# DangerButton - a FIBERGLASS hazard placard, not a big red fill.
	#
	# The old version was a saturated red slab that sat in a row beside a
	# saturated green Save and a blue Test, spending the player's entire
	# attention budget on three controls none of which are emergencies. A
	# placard says "read me before you press this" without shouting.
	theme.set_stylebox("normal", "DangerButton",
		_plate_tinted("fiberglass", "normal", Tokens.SIGNAL_ALERT,
			Tokens.SPACE_MD, Tokens.SPACE_SM, 0.50))
	theme.set_stylebox("hover", "DangerButton",
		_plate_tinted("fiberglass", "hover", Tokens.SIGNAL_ALERT,
			Tokens.SPACE_MD, Tokens.SPACE_SM, 0.68))
	theme.set_stylebox("pressed", "DangerButton",
		_plate_tinted("fiberglass", "pressed", Tokens.SIGNAL_ALERT,
			Tokens.SPACE_MD, Tokens.SPACE_SM, 0.50))
	theme.set_stylebox("disabled", "DangerButton", disabled)
	theme.set_stylebox("focus", "DangerButton", focus)
	theme.set_color("font_color", "DangerButton", Color(1.0, 0.90, 0.88))
	theme.set_color("font_outline_color", "DangerButton", Color.BLACK)
	theme.set_constant("outline_size", "DangerButton", 3)

	# TabButton - a latched selector. Selected state is carried by a hazard
	# bar along the bottom edge plus a lifted fill, so it reads as a
	# mechanically held-down control rather than just a recolor. This is the
	# pattern the build tabs and the parts-catalog categories both use.
	#
	# Unselected tabs use the PRESSED moulded plate and the selected one a
	# flat lifted fill - i.e. the inactive tabs are the ones sunk into the
	# frame. That inversion is what makes a tab strip read as one control with
	# a chosen position rather than as a row of independent buttons.
	var tab = _plate("moulded", "pressed", Tokens.SPACE_MD, Tokens.SPACE_SM)
	var tab_hover = _plate("moulded", "normal", Tokens.SPACE_MD, Tokens.SPACE_SM)
	var tab_on = _flat(Tokens.BASE_500, Tokens.SIGNAL_HAZARD, 0, 0)
	tab_on.border_width_bottom = 4
	_pad(tab_on, Tokens.SPACE_MD, Tokens.SPACE_SM)
	theme.set_stylebox("normal", "TabButton", tab)
	theme.set_stylebox("hover", "TabButton", tab_hover)
	theme.set_stylebox("pressed", "TabButton", tab_on)
	theme.set_stylebox("disabled", "TabButton", tab)
	theme.set_color("font_color", "TabButton", Tokens.TEXT_SECONDARY)
	theme.set_color("font_pressed_color", "TabButton", Color(1.0, 0.93, 0.78))
	theme.set_color("font_hover_color", "TabButton", Tokens.TEXT_PRIMARY)

	# ListButton - a row in a scrolling list (parts catalog, map select,
	# blueprint library). Flat and borderless at rest so a long list reads
	# as a list instead of as fifty stacked buttons; gains a hazard left
	# edge when selected.
	var row = _pad(_flat(Color(0, 0, 0, 0), Color(0, 0, 0, 0), 0, 0),
		Tokens.SPACE_MD, Tokens.SPACE_SM)
	var row_hover = _pad(_flat(Tokens.BASE_700, Color(0, 0, 0, 0), 0, 0),
		Tokens.SPACE_MD, Tokens.SPACE_SM)
	var row_on = _flat(Tokens.BASE_600, Tokens.SIGNAL_HAZARD, 0, 0)
	row_on.border_width_left = 3
	_pad(row_on, Tokens.SPACE_MD, Tokens.SPACE_SM)
	theme.set_stylebox("normal", "ListButton", row)
	theme.set_stylebox("hover", "ListButton", row_hover)
	theme.set_stylebox("pressed", "ListButton", row_on)
	theme.set_stylebox("focus", "ListButton", row)
	theme.set_color("font_color", "ListButton", Tokens.TEXT_SECONDARY)
	theme.set_color("font_hover_color", "ListButton", Tokens.TEXT_PRIMARY)
	theme.set_color("font_pressed_color", "ListButton", Tokens.TEXT_PRIMARY)

	# DrawerTab - context drawer tab buttons. Canvas material, flat at rest,
	# lifted on active with hazard bottom edge.
	var drawer_normal = _plate("canvas", "normal", Tokens.SPACE_MD, Tokens.SPACE_SM)
	var drawer_hover = _plate("canvas", "hover", Tokens.SPACE_MD, Tokens.SPACE_SM)
	var drawer_active = _flat(Tokens.BASE_600, Tokens.SIGNAL_HAZARD, 0, 0)
	drawer_active.border_width_bottom = 3
	_pad(drawer_active, Tokens.SPACE_MD, Tokens.SPACE_SM)
	theme.set_stylebox("normal", "DrawerTab", drawer_normal)
	theme.set_stylebox("hover", "DrawerTab", drawer_hover)
	theme.set_stylebox("pressed", "DrawerTab", drawer_active)
	theme.set_stylebox("disabled", "DrawerTab", drawer_normal)
	theme.set_color("font_color", "DrawerTab", Tokens.TEXT_SECONDARY)
	theme.set_color("font_pressed_color", "DrawerTab", Tokens.TEXT_PRIMARY)
	theme.set_color("font_hover_color", "DrawerTab", Tokens.TEXT_PRIMARY)

	# AlertIcon - small icon buttons in desk bar alert stack. Transparent at rest,
	# hazard tint on active/flash.
	var alert_normal = _flat(Color(0, 0, 0, 0), Color(0, 0, 0, 0), 0, Tokens.RADIUS_CONTROL)
	var alert_hover = _flat(Tokens.BASE_700, Color(0, 0, 0, 0), 0, Tokens.RADIUS_CONTROL)
	var alert_pressed = _flat(Tokens.SIGNAL_HAZARD_DIM, Tokens.SIGNAL_HAZARD, Tokens.BORDER_HAIRLINE, Tokens.RADIUS_CONTROL)
	_pad(alert_normal, Tokens.SPACE_XS, Tokens.SPACE_XS)
	_pad(alert_hover, Tokens.SPACE_XS, Tokens.SPACE_XS)
	_pad(alert_pressed, Tokens.SPACE_XS, Tokens.SPACE_XS)
	theme.set_stylebox("normal", "AlertIcon", alert_normal)
	theme.set_stylebox("hover", "AlertIcon", alert_hover)
	theme.set_stylebox("pressed", "AlertIcon", alert_pressed)
	theme.set_stylebox("disabled", "AlertIcon", alert_normal)
	theme.set_color("icon_normal_color", "AlertIcon", Tokens.TEXT_SECONDARY)
	theme.set_color("icon_hover_color", "AlertIcon", Tokens.SIGNAL_HAZARD)
	theme.set_color("icon_pressed_color", "AlertIcon", Color(1, 1, 1))

	# QuickJumpPill - small pills in context drawer STATUS tab for quick tab switching.
	var pill_normal = _flat(Tokens.BASE_600, Color(0, 0, 0, 0), 0, Tokens.RADIUS_CONTROL)
	var pill_hover = _flat(Tokens.BASE_500, Tokens.SIGNAL_HAZARD, Tokens.BORDER_HAIRLINE, Tokens.RADIUS_CONTROL)
	var pill_pressed = _flat(Tokens.SIGNAL_HAZARD_DIM, Tokens.SIGNAL_HAZARD, Tokens.BORDER_EMPHASIS, Tokens.RADIUS_CONTROL)
	_pad(pill_normal, Tokens.SPACE_SM, Tokens.SPACE_XS)
	_pad(pill_hover, Tokens.SPACE_SM, Tokens.SPACE_XS)
	_pad(pill_pressed, Tokens.SPACE_SM, Tokens.SPACE_XS)
	theme.set_stylebox("normal", "QuickJumpPill", pill_normal)
	theme.set_stylebox("hover", "QuickJumpPill", pill_hover)
	theme.set_stylebox("pressed", "QuickJumpPill", pill_pressed)
	theme.set_stylebox("disabled", "QuickJumpPill", pill_normal)
	theme.set_color("font_color", "QuickJumpPill", Tokens.TEXT_PRIMARY)
	theme.set_color("font_hover_color", "QuickJumpPill", Tokens.TEXT_PRIMARY)
	theme.set_color("font_pressed_color", "QuickJumpPill", Color(1, 1, 1))
	theme.set_font_size("font_size", "QuickJumpPill", Tokens.FONT_SMALL)

	# QueueItemButton - production drawer item buttons. Canvas material, full width.
	var qi_normal = _plate("canvas", "normal", Tokens.SPACE_MD, Tokens.SPACE_SM)
	var qi_hover = _plate("canvas", "hover", Tokens.SPACE_MD, Tokens.SPACE_SM)
	var qi_pressed = _plate("canvas", "pressed", Tokens.SPACE_MD, Tokens.SPACE_SM)
	var qi_disabled = _plate("canvas", "disabled", Tokens.SPACE_MD, Tokens.SPACE_SM)
	theme.set_stylebox("normal", "QueueItemButton", qi_normal)
	theme.set_stylebox("hover", "QueueItemButton", qi_hover)
	theme.set_stylebox("pressed", "QueueItemButton", qi_pressed)
	theme.set_stylebox("disabled", "QueueItemButton", qi_disabled)
	theme.set_color("font_color", "QueueItemButton", Tokens.TEXT_PRIMARY)
	theme.set_color("font_hover_color", "QueueItemButton", Tokens.TEXT_PRIMARY)
	theme.set_color("font_pressed_color", "QueueItemButton", Tokens.TEXT_PRIMARY)
	theme.set_color("font_disabled_color", "QueueItemButton", Tokens.TEXT_DISABLED)
	theme.set_color("icon_normal_color", "QueueItemButton", Color.WHITE)
	theme.set_color("icon_disabled_color", "QueueItemButton", Color(0.45, 0.45, 0.45, 0.7))


func _build_inputs(theme: Theme) -> void:
	# A text field is a recess milled into the panel, so it gets the PRESSED
	# steel plate - inverted bevel, sunk into the frame. Focus keeps the flat
	# hazard hairline for the same reason buttons do: focus is interface state,
	# not a change of material.
	var field = _plate("steel", "pressed", Tokens.SPACE_SM, Tokens.SPACE_SM)
	var field_focus = _flat(Color(0, 0, 0, 0), Tokens.SIGNAL_HAZARD,
		Tokens.BORDER_EMPHASIS, Tokens.RADIUS_CONTROL)
	_pad(field_focus, Tokens.SPACE_SM, Tokens.SPACE_SM)
	theme.set_stylebox("normal", "LineEdit", field)
	theme.set_stylebox("focus", "LineEdit", field_focus)
	theme.set_color("font_color", "LineEdit", Tokens.TEXT_PRIMARY)
	theme.set_color("font_placeholder_color", "LineEdit", Tokens.TEXT_DISABLED)
	theme.set_color("caret_color", "LineEdit", Tokens.SIGNAL_HAZARD)

	theme.set_color("font_color", "CheckBox", Tokens.TEXT_PRIMARY)
	theme.set_color("font_hover_color", "CheckBox", Tokens.TEXT_PRIMARY)
	theme.set_color("font_disabled_color", "CheckBox", Tokens.TEXT_DISABLED)
	theme.set_constant("h_separation", "CheckBox", Tokens.SPACE_SM)

	# Slider: a thin recessed track with a substantial grabber. The old theme
	# styled only "grabber_area" and left the track and grabber themselves
	# on engine defaults, so sliders were the most obviously off-brand
	# control in the Design Lab.
	var track = _flat(Tokens.BASE_900, Tokens.BASE_700, Tokens.BORDER_HAIRLINE, 1)
	track.content_margin_top = 3
	track.content_margin_bottom = 3
	theme.set_stylebox("slider", "HSlider", track)
	var fill = _flat(Tokens.SIGNAL_HAZARD_DIM, Tokens.SIGNAL_HAZARD, Tokens.BORDER_HAIRLINE, 1)
	theme.set_stylebox("grabber_area", "HSlider", fill)
	theme.set_stylebox("grabber_area_highlight", "HSlider", fill)
	# Grabber handle — amber accent, visible against the dark track.
	var grabber = _flat(Tokens.SIGNAL_HAZARD, Tokens.BASE_500,
		Tokens.BORDER_EMPHASIS, Tokens.RADIUS_CONTROL)
	grabber.content_margin_top = 6
	grabber.content_margin_bottom = 6
	grabber.content_margin_left = 6
	grabber.content_margin_right = 6
	theme.set_stylebox("grabber", "HSlider", grabber)
	theme.set_constant("grabber_size", "HSlider", 16)

	var popup = _pad(_flat(Tokens.BASE_800, Tokens.BASE_400,
		Tokens.BORDER_EMPHASIS, Tokens.RADIUS_PANEL), Tokens.SPACE_XS, Tokens.SPACE_XS)
	var popup_hover = _pad(_flat(Tokens.BASE_600, Tokens.SIGNAL_HAZARD,
		Tokens.BORDER_HAIRLINE, Tokens.RADIUS_PANEL), Tokens.SPACE_XS, Tokens.SPACE_XS)
	theme.set_stylebox("panel", "PopupMenu", popup)
	theme.set_stylebox("hover", "PopupMenu", popup_hover)
	theme.set_stylebox("focus", "PopupMenu", popup)
	theme.set_stylebox("pressed", "PopupMenu", popup_hover)
	theme.set_color("font_color", "PopupMenu", Tokens.TEXT_PRIMARY)
	theme.set_color("font_hover_color", "PopupMenu", Tokens.SIGNAL_HAZARD)
	theme.set_color("font_separator_color", "PopupMenu", Tokens.BASE_500)
	theme.set_constant("v_separation", "PopupMenu", Tokens.SPACE_XS)


func _build_bars(theme: Theme) -> void:
	# ProgressBar is load-bearing in this game - it is the production queue
	# readout and the power meter. It was running on engine defaults.
	theme.set_stylebox("background", "ProgressBar",
		_flat(Tokens.BASE_900, Tokens.BASE_700, Tokens.BORDER_HAIRLINE, 1))
	theme.set_stylebox("fill", "ProgressBar",
		_flat(Tokens.SIGNAL_GO_DIM, Tokens.SIGNAL_GO, Tokens.BORDER_HAIRLINE, 1))
	theme.set_color("font_color", "ProgressBar", Tokens.TEXT_PRIMARY)

	for axis in ["HScrollBar", "VScrollBar"]:
		theme.set_stylebox("scroll", axis, _flat(Tokens.BASE_900, Color(0, 0, 0, 0), 0, 1))
		theme.set_stylebox("grabber", axis, _flat(Tokens.BASE_600, Color(0, 0, 0, 0), 0, 1))
		theme.set_stylebox("grabber_highlight", axis, _flat(Tokens.BASE_500, Color(0, 0, 0, 0), 0, 1))
		theme.set_stylebox("grabber_pressed", axis, _flat(Tokens.SIGNAL_HAZARD, Color(0, 0, 0, 0), 0, 1))


func _build_misc(theme: Theme) -> void:
	# Tooltips were unstyled, which meant every hover hint in the game
	# appeared in Godot's stock pale-yellow box.
	var tip = _pad(_flat(Tokens.BASE_900, Tokens.SIGNAL_HAZARD,
		Tokens.BORDER_HAIRLINE, Tokens.RADIUS_CONTROL), Tokens.SPACE_SM, Tokens.SPACE_XS)
	theme.set_stylebox("panel", "TooltipPanel", tip)
	theme.set_color("font_color", "TooltipLabel", Tokens.TEXT_PRIMARY)
	theme.set_font_size("font_size", "TooltipLabel", Tokens.FONT_SMALL)

	theme.set_color("separator", "HSeparator", Tokens.BASE_500)
	theme.set_constant("separation", "HSeparator", Tokens.SPACE_SM)
	theme.set_color("separator", "VSeparator", Tokens.BASE_500)

	theme.set_stylebox("panel", "AcceptDialog",
		_pad(_flat(Tokens.BASE_800, Tokens.BASE_400, Tokens.BORDER_EMPHASIS,
			Tokens.RADIUS_PANEL), Tokens.SPACE_LG, Tokens.SPACE_LG))
