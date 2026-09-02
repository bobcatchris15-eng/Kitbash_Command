extends RefCounted
class_name UITheme
# Helpers for the parts of the interface a Theme resource can't express -
# the shader-backed backdrop, and a few "style this node like X" shortcuts
# for controls built in code.
#
# Everything with a StyleBox belongs in tools/build_ui_theme.gd instead.
# This file is for what has to happen at runtime.

const MATERIAL_SHADER = preload("res://shaders/ui_material.gdshader")
const Tokens = preload("res://scripts/ui_tokens.gd")
const LiveryScript = preload("res://scripts/livery.gd")

# ---------------------------------------------------------------------------
# MATERIAL VOCABULARY
# ---------------------------------------------------------------------------
# Surfaces are grouped by layer (L0..L3 from TACTILE_INTERFACE_PLAN.md Part 0.5).
# Each entry is what a thing is MADE OF; the appearance follows. The brightness
# rule in UI_STYLE_GUIDE.md §3.2 governs every per-material default - the
# backdrop is the floor of the luminance stack, and anything laid on top has to
# sit above it.
#
#   L0 WORKBENCH (hobby desk - backdrop register, no plates)
#     CUTTING_MAT, CARDBOARD, KRAFT, CORK, CHIPBOARD
#
#   L1 EQUIPMENT (cold-war hardware)
#     POWDERCOAT  panel and dock bodies, HUD chrome
#     STEEL       frames, rails, splitters, toolbars, dividers, the in-match backdrop
#     MOULDED     buttons, tabs, toggles, the radial ring
#     CANVAS      drawer/flyout backing, tooltips
#     CARBON      primary action only - SPARING, at most two per screen
#     FIBERGLASS  hazard placards, alert states
#     TOOLBOX     Design Lab parts dock shell - and nothing else
const MATERIALS = [
	# L0 workbench
	"cutting_mat", "cardboard", "kraft", "cork", "chipboard",
	# L1 equipment
	"powdercoat", "steel", "moulded", "canvas", "carbon", "fiberglass", "toolbox",
	"bakelite", "wood",
]

const FIELD_DIR = "res://assets/textures/ui/"

# Per-material shader defaults. Kept here rather than at call sites so that
# "canvas" looks like canvas everywhere without every caller remembering to
# turn the vignette down on cloth.
const MATERIAL_DEFAULTS = {
	# L0 workbench. Fields only - L0 is a backdrop register, not a control
	# register, and these materials have no plates (see tools/generate_ui_plates.py,
	# which is a separate script from the L0 field PNGs that exist on disk).
	# Brightness 0.85 lands each L0 final luminance in the 0.07-0.10 range -
	# visible as a hobby desk, near the 0.42-brightness steel backdrop (which
	# lands at 0.084), and well below the powdercoat panel body at ~0.110. The
	# floor/surface/control stack stays strictly ascending.
	"cutting_mat": {"wear": 0.10, "grime": 0.18, "scale": 1.2, "vignette": 0.18, "brightness": 0.85},
	"cardboard":   {"wear": 0.12, "grime": 0.16, "scale": 1.0, "vignette": 0.20, "brightness": 0.85},
	"kraft":       {"wear": 0.14, "grime": 0.18, "scale": 1.0, "vignette": 0.22, "brightness": 0.85},
	"cork":        {"wear": 0.16, "grime": 0.14, "scale": 1.1, "vignette": 0.20, "brightness": 0.85},
	"chipboard":   {"wear": 0.18, "grime": 0.16, "scale": 1.0, "vignette": 0.22, "brightness": 0.85},
	# L1 equipment.
	"powdercoat": {"wear": 0.25, "grime": 0.20, "scale": 1.0, "vignette": 0.30},
	"steel":      {"wear": 0.35, "grime": 0.12, "scale": 1.0, "vignette": 0.22},
	"moulded":    {"wear": 0.10, "grime": 0.18, "scale": 0.8, "vignette": 0.18},
	# Cloth does not scuff to a bright edge and does not carry a corner
	# falloff the way a curved metal plate does - it is matte and flat.
	"canvas":     {"wear": 0.06, "grime": 0.30, "scale": 0.7, "vignette": 0.12},
	"carbon":     {"wear": 0.04, "grime": 0.08, "scale": 0.6, "vignette": 0.20},
	"fiberglass": {"wear": 0.15, "grime": 0.14, "scale": 1.0, "vignette": 0.24},
	# The Design Lab parts dock, and nothing else. wear is LOW despite this
	# being the most worn-looking surface in the game: the chips and scratches
	# are baked into field_toolbox.png as actual bare metal, and stacking the
	# shader's luminance scuff on top of them just washes the enamel out. grime
	# runs high instead - a toolbox collects dirt in every recess.
	"toolbox":    {"wear": 0.05, "grime": 0.34, "scale": 1.0, "vignette": 0.34},
	# Commander's desk surface - warm bakelite plastic. Slightly worn, grimey.
	"bakelite":   {"wear": 0.15, "grime": 0.25, "scale": 1.0, "vignette": 0.35, "brightness": 0.75},
	# Paint bay / Armor station workbench - warm planed timber finish.
	"wood":       {"wear": 0.08, "grime": 0.15, "scale": 1.0, "vignette": 0.22, "brightness": 0.52},
}

static var _field_cache: Dictionary = {}


static func material_field(material: String) -> Texture2D:
	if _field_cache.has(material):
		return _field_cache[material]
	var path := FIELD_DIR + "field_%s.png" % material
	var tex: Texture2D = null
	if ResourceLoader.exists(path):
		tex = load(path) as Texture2D
	else:
		# Not an error worth crashing over - the shader falls back to a flat
		# base_color - but it IS worth saying, because the symptom otherwise is
		# a panel that looks merely a bit plain.
		push_warning("UITheme: missing material field '%s'" % path)
	_field_cache[material] = tex
	return tex


# Paints a named MATERIAL onto a node. The general entry point; prefer this
# over apply_backdrop() for anything that is a surface rather than a backdrop.
#
# Like apply_backdrop(), this keeps the shader's `panel_size` in sync with the
# node - a Control's size is not final until layout has run, so pushing it once
# at setup gives a material that is correct at the design resolution and wrong
# at every other window size.
static func apply_material(node: CanvasItem, material: String,
		overrides: Dictionary = {}) -> void:
	if material not in MATERIALS:
		push_warning("UITheme: unknown material '%s'" % material)
		material = "powdercoat"

	var mat := node.material as ShaderMaterial
	if not mat or mat.shader != MATERIAL_SHADER:
		mat = ShaderMaterial.new()
		mat.shader = MATERIAL_SHADER
		node.material = mat

	var field := material_field(material)
	mat.set_shader_parameter("material_field", field)
	mat.set_shader_parameter("has_field", field != null)

	var d: Dictionary = MATERIAL_DEFAULTS.get(material, MATERIAL_DEFAULTS["powdercoat"])
	mat.set_shader_parameter("wear_amount", overrides.get("wear", d["wear"]))
	mat.set_shader_parameter("grime_amount", overrides.get("grime", d["grime"]))
	mat.set_shader_parameter("field_scale", overrides.get("scale", d["scale"]))
	mat.set_shader_parameter("vignette", overrides.get("vignette", d["vignette"]))
	# brightness defaults to whatever the material's own entry says (L0 workbench
	# materials carry 0.70 to keep the floor low), or 1.0 for materials that
	# do not specify one (the L1 equipment, where panels and controls are at
	# their authored luminance).
	mat.set_shader_parameter("brightness", overrides.get("brightness", d.get("brightness", 1.0)))
	mat.set_shader_parameter("tint_strength", overrides.get("tint_strength", 0.0))
	if overrides.has("tint"):
		mat.set_shader_parameter("accent_tint", overrides["tint"])

	_bind_panel_size(node, mat)


# Shared between apply_material() and apply_backdrop(): push the node's pixel
# size into the shader now and on every resize.
static func _bind_panel_size(node: CanvasItem, mat: ShaderMaterial) -> void:
	if not (node is Control):
		return
	var ctrl := node as Control
	var push := func() -> void:
		var s := ctrl.size
		if s.x > 1.0 and s.y > 1.0:
			mat.set_shader_parameter("panel_size", s)
	push.call()
	if not ctrl.resized.is_connected(push):
		ctrl.resized.connect(push)


# Paints the sheet-metal backdrop onto a full-screen (or panel-sized) node.
#
# The shader needs to know the node's pixel size to keep its grain a fixed
# physical size, and a Control's size isn't final until layout has run - so
# this both pushes the current size and keeps it current via `resized`.
# Without that, the backdrop is correct at the design resolution and wrong
# at every other window size, which is the kind of bug that only shows up on
# someone else's monitor.
# Now a thin wrapper over apply_material(). Backdrops are STEEL - the bare
# sheet the whole console is built on - held well below panel luminance by
# `brightness`, so that anything laid on top separates from it.
#
# That last part is load-bearing and was a real defect once: the first version
# of the backdrop used the same value as the panel bodies, and menu cards had
# nothing to sit on. A panel and its background at equal luminance read as one
# flat field no matter what border sits between them. The backdrop is the
# floor; everything else is above it.
static func apply_backdrop(node: CanvasItem, accent: Color = Color.WHITE, accent_strength: float = 0.0) -> void:
	apply_material(node, "steel", {
		"brightness": 0.42,
		"wear": 0.30,
		"grime": 0.25,
		"vignette": 0.30,
		"tint": accent,
		"tint_strength": accent_strength,
	})


# apply_brushed_panel() lived here as a back-compat shim over apply_backdrop()
# while the call sites were migrated off faction-tinted chrome. All of them have
# now moved - match_setup and the Design Lab call apply_backdrop() directly, and
# skirmish's top bar became a HUDPanel theme variation - so the shim is gone.
# Same for style_option_button() and style_slider(), which had already been
# reduced to `pass` once OptionButton and HSlider were themed centrally: a no-op
# that every screen still called only made it look like styling was happening.
#
# For a genuine faction-identity surface - the faction picker's preview
# swatch, and nothing else. Kept separate so it can't be reached by accident.
static func apply_faction_preview(node: CanvasItem, faction: String) -> void:
	apply_backdrop(node, LiveryScript.zone_color(faction, "hull_upper"), 0.45)




# Applies a theme type variation, with a clear failure mode. Typo'd
# variation names fail silently in Godot (the control just renders with the
# base type's style), which is hard to spot in a screenshot.
const KNOWN_VARIATIONS = [
	"CardPanel", "HeaderPanel", "HUDPanel", "InsetPanel",
	"DockPanel", "DockRail", "FlyoutPanel", "CalloutPanel",
	"PrimaryButton", "DangerButton", "TabButton", "ListButton",
	"DisplayLabel", "TitleLabel", "HeadingLabel", "HintLabel",
	"HUDValueLabel", "StatLabel",
]

static func variation(ctrl: Control, name: String) -> Control:
	if name not in KNOWN_VARIATIONS:
		push_warning("UITheme: unknown theme variation '%s'" % name)
	ctrl.theme_type_variation = name
	return ctrl


# ---------------------------------------------------------------------------
# DROPDOWN CONTROLS - the last stock-engine glyph left on the setup screens.
# ---------------------------------------------------------------------------
# bomber_theme.tres already carries the OptionButton panel/font/PopupMenu
# styleboxes (tools/build_ui_theme.gd), so the CLOSED plate and the popup
# list panel already read as this game's chrome. What still reads as a
# default engine control is the caret: OptionButton falls back to the
# built-in theme's triangle icon whenever no "arrow" icon override is set,
# and nothing set one. This paints a small flat amber chevron that matches
# the rest of the control's type colour instead of the stock grey wedge.
static var _arrow_icon_cache: ImageTexture = null

static func _dropdown_arrow_icon() -> ImageTexture:
	if _arrow_icon_cache != null:
		return _arrow_icon_cache
	# 12x8, a flat-shaded downward chevron in ACCENT_INTERACTIVE. Procedural
	# rather than an authored SVG: this is a single-purpose glyph reused by
	# every dropdown in the game, not a HUD icon with its own asset entry.
	var w := 12
	var h := 8
	var img := Image.create(w, h, false, Image.FORMAT_RGBA8)
	img.fill(Color(0, 0, 0, 0))
	var col := Tokens.ACCENT_INTERACTIVE
	for y in range(h):
		# Widest at the top, narrowing to a point - a chevron, not a full
		# triangle, so it reads as "opens a list" rather than "play".
		var inset := int(float(y) / float(h - 1) * (w / 2.0))
		for x in range(inset, w - inset):
			img.set_pixel(x, y, col)
	var tex := ImageTexture.create_from_image(img)
	_arrow_icon_cache = tex
	return tex


# Applies the project's dropdown language to a stock OptionButton: the flat
# amber chevron above, a consistent minimum height off HIT_TARGET_MIN so
# every selector on a settings grid lines up, and the body type size so the
# closed label matches the rest of the form instead of the engine default.
#
# Call this on every OptionButton the setup screens build - match_setup.gd,
# operations_setup.gd's difficulty and per-engagement map pickers. The panel
# and popup styling already come free from the shared Theme resource; this
# is only the piece a StyleBox cannot express.
static func style_dropdown(btn: OptionButton) -> OptionButton:
	btn.add_theme_icon_override("arrow", _dropdown_arrow_icon())
	btn.add_theme_constant_override("arrow_margin", Tokens.SPACE_SM)
	btn.add_theme_font_size_override("font_size", Tokens.FONT_BODY)
	if btn.custom_minimum_size.y < Tokens.HIT_TARGET_MIN:
		btn.custom_minimum_size.y = Tokens.HIT_TARGET_MIN
	return btn
