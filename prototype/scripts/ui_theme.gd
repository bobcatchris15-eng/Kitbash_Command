extends RefCounted
class_name UITheme
# Helpers for the parts of the interface a Theme resource can't express -
# the shader-backed backdrop, and a few "style this node like X" shortcuts
# for controls built in code.
#
# The generated Theme remains the legacy baseline. Runtime semantic factories
# below let shared shell controls use roles without regenerating that resource.

const MATERIAL_SHADER = preload("res://shaders/ui_material.gdshader")
const Tokens = preload("res://scripts/ui_tokens.gd")
const LiveryScript = preload("res://scripts/livery.gd")
const INDUSTRIAL_MANIFEST_PATH := "res://assets/ui/industrial/manifest.json"
const INDUSTRIAL_ICON_TYPE := "IndustrialIcons"
const INDUSTRIAL_FIELD_TYPE := "IndustrialFields"

static var _industrial_manifest_cache: Dictionary = {}
static var _industrial_icon_cache: Dictionary = {}
static var _industrial_plate_cache: Dictionary = {}


# The authored industrial manifest is the production registry for vectors,
# material fields, state plates, 9-slice geometry and weathering defaults.
# Keeping path and material metadata together prevents the runtime helper and
# generated Theme from silently drifting onto two different asset libraries.
static func industrial_manifest() -> Dictionary:
	if not _industrial_manifest_cache.is_empty():
		return _industrial_manifest_cache
	var file := FileAccess.open(INDUSTRIAL_MANIFEST_PATH, FileAccess.READ)
	if file == null:
		push_error("UITheme: missing industrial manifest '%s'" % INDUSTRIAL_MANIFEST_PATH)
		return {}
	var parsed = JSON.parse_string(file.get_as_text())
	if not parsed is Dictionary:
		push_error("UITheme: invalid industrial manifest JSON")
		return {}
	_industrial_manifest_cache = parsed
	return _industrial_manifest_cache


static func industrial_vector_spec(key: String) -> Dictionary:
	return industrial_manifest().get("vectors", {}).get(key, {})


static func industrial_material_spec(material: String) -> Dictionary:
	return industrial_manifest().get("materials", {}).get(material, {})


static func industrial_material_for_role(role: String) -> String:
	return industrial_manifest().get("theme_roles", {}).get(role, "")


static func industrial_icon(key: String) -> Texture2D:
	if _industrial_icon_cache.has(key):
		return _industrial_icon_cache[key]
	var spec := industrial_vector_spec(key)
	var path: String = spec.get("path", "")
	var texture: Texture2D = null
	if not path.is_empty() and ResourceLoader.exists(path):
		texture = load(path) as Texture2D
	else:
		push_warning("UITheme: missing industrial vector '%s'" % key)
	_industrial_icon_cache[key] = texture
	return texture


static func industrial_plate_texture(material: String, state: String) -> Texture2D:
	var cache_key := "%s/%s" % [material, state]
	if _industrial_plate_cache.has(cache_key):
		return _industrial_plate_cache[cache_key]
	var spec := industrial_material_spec(material)
	var path: String = spec.get("plate", {}).get("states", {}).get(state, "")
	var texture: Texture2D = null
	if not path.is_empty() and ResourceLoader.exists(path):
		texture = load(path) as Texture2D
	else:
		push_warning("UITheme: missing industrial plate '%s'" % cache_key)
	_industrial_plate_cache[cache_key] = texture
	return texture


static func industrial_material_field(material: String) -> Texture2D:
	if _field_cache.has(material):
		return _field_cache[material]
	var spec := industrial_material_spec(material)
	var path: String = spec.get("field", {}).get("path", "")
	var texture: Texture2D = null
	if not path.is_empty() and ResourceLoader.exists(path):
		texture = load(path) as Texture2D
	else:
		push_warning("UITheme: missing industrial material field '%s'" % material)
	_field_cache[material] = texture
	return texture

# Shared type ownership for the generated theme. Display stays on large titles;
# operations use sans, and only numeric/telemetry variations use mono.
static func configure_typography(theme: Theme, ui: Font, bold: Font, display: Font, mono: Font) -> void:
	if ui:
		theme.default_font = ui
		theme.set_font("font", "LineEdit", ui)
	theme.default_font_size = Tokens.FONT_BODY
	var sizes := {"Label": Tokens.FONT_BODY, "DisplayLabel": Tokens.FONT_DISPLAY,
		"TitleLabel": Tokens.FONT_TITLE, "HeadingLabel": Tokens.FONT_HEADING,
		"HintLabel": Tokens.FONT_SMALL, "HUDValueLabel": Tokens.FONT_HEADING,
		"StatLabel": Tokens.FONT_SMALL}
	for type: String in sizes:
		theme.set_font_size("font_size", type, sizes[type])
		theme.set_color("font_color", type, Tokens.TEXT_SECONDARY if type in ["HintLabel", "StatLabel"] else Tokens.TEXT_PRIMARY)
	if display:
		for type in ["DisplayLabel", "TitleLabel"]: theme.set_font("font", type, display)
	if bold: theme.set_font("font", "HeadingLabel", bold)
	if mono:
		for type in ["HUDValueLabel", "StatLabel"]: theme.set_font("font", type, mono)

static func inspection_environment() -> Environment:
	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = Tokens.BASE_900
	env.tonemap_mode = Environment.TONE_MAPPER_AGX
	env.tonemap_exposure = Tokens.INSPECTION_EXPOSURE
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Tokens.TEXT_PRIMARY
	env.ambient_light_energy = Tokens.INSPECTION_AMBIENT
	env.ssao_enabled = true
	env.ssao_radius = 0.8
	env.ssao_intensity = 1.2
	# Inspection needs crisp seams and selection edges, not bloom around them.
	env.glow_enabled = false
	return env

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

static var _field_cache: Dictionary = {}


static func material_field(material: String) -> Texture2D:
	return industrial_material_field(material)


# Paints a named MATERIAL onto a node. The general entry point; prefer this
# over apply_backdrop() for anything that is a surface rather than a backdrop.
#
# Like apply_backdrop(), this keeps the shader's `panel_size` in sync with the
# node - a Control's size is not final until layout has run, so pushing it once
# at setup gives a material that is correct at the design resolution and wrong
# at every other window size.
static func apply_material(node: CanvasItem, material: String,
		overrides: Dictionary = {}) -> void:
	var material_spec := industrial_material_spec(material)
	if material_spec.is_empty():
		push_warning("UITheme: unknown material '%s'" % material)
		material = "powdercoat"
		material_spec = industrial_material_spec(material)

	var mat := node.material as ShaderMaterial
	if not mat or mat.shader != MATERIAL_SHADER:
		mat = ShaderMaterial.new()
		mat.shader = MATERIAL_SHADER
		node.material = mat

	var field := material_field(material)
	mat.set_shader_parameter("material_field", field)
	mat.set_shader_parameter("has_field", field != null)

	var d: Dictionary = material_spec.get("wear", {})
	mat.set_shader_parameter("wear_amount", overrides.get("wear", d["wear"]))
	mat.set_shader_parameter("grime_amount", overrides.get("grime", d["grime"]))
	mat.set_shader_parameter("field_scale", overrides.get("scale", d["scale"]))
	mat.set_shader_parameter("vignette", overrides.get("vignette", d["vignette"]))
	# brightness defaults to whatever the material's own entry says (L0 workbench
	# materials carry 0.70 to keep the floor low), or 1.0 for materials that
	# do not specify one (the L1 equipment, where panels and controls are at
	# their authored luminance).
	mat.set_shader_parameter("brightness", overrides.get("brightness", d["brightness"]))
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


# ---------------------------------------------------------------------------
# FLAT INSTRUMENT CHROME - authored SVG glyphs + flat panel factory
# ---------------------------------------------------------------------------
# The "flat instrument, richer" register the Design Lab and the rebuilt Match
# Settings screen share: flat dark fills, 1px edges, depth from LAYOUT and
# elevation rather than from a generated texture. A screen in this register
# builds panels through flat_style() so that no call site holds a colour, a
# radius or a margin of its own; everything routes back to ui_tokens.gd.
#
# Deliberately NOT apply_material(): a material-backed StyleBoxTexture cannot
# carry a border colour or a shadow, which is precisely what this register uses
# to separate surfaces. The two are alternatives, not layers.
static func flat_style(fill: Color = Tokens.BASE_800, edge: Color = Tokens.BASE_500,
		margin: int = Tokens.SPACE_MD, tier: String = "flush",
		border: int = Tokens.BORDER_HAIRLINE) -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = fill
	sb.border_color = edge
	sb.set_border_width_all(border)
	sb.set_corner_radius_all(Tokens.RADIUS_PANEL)
	sb.set_content_margin_all(margin)
	Tokens.apply_elevation(sb, tier)
	return sb


# Shared panel/material roles. Material names describe the authored finish;
# flat styles provide a legible fallback before a screen's asset pass.
const PANEL_ROLES: Dictionary[String, Dictionary] = {
	"surface": {"material": "powdercoat", "fill": Tokens.BASE_800, "tier": "raised"},
	"inset": {"material": "moulded", "fill": Tokens.BASE_900, "tier": "flush"},
	"header": {"material": "steel", "fill": Tokens.BASE_700, "tier": "raised"},
	"navigation": {"material": "steel", "fill": Tokens.BASE_800, "tier": "flush"},
	"floating": {"material": "canvas", "fill": Tokens.BASE_800, "tier": "floating"},
	"modal": {"material": "powdercoat", "fill": Tokens.BASE_800, "tier": "modal"},
}

static func panel_style(role: String = "surface") -> StyleBoxFlat:
	var spec: Dictionary = PANEL_ROLES.get(role, PANEL_ROLES["surface"])
	return flat_style(spec["fill"], Tokens.BASE_500, Tokens.SPACE_MD, spec["tier"])

static func panel_material(role: String = "surface") -> String:
	return PANEL_ROLES.get(role, PANEL_ROLES["surface"])["material"]

static func action_style(role: String = "secondary", state: String = "normal") -> StyleBoxFlat:
	var colors := Tokens.role_colors(role, state)
	var box := flat_style(colors["fill"], colors["edge"])
	box.set_corner_radius_all(Tokens.RADIUS_CONTROL)
	# Persistence is conveyed by geometry as well as hue. Disabled wins over it.
	if state != "disabled" and role != "disabled":
		if role == "selected":
			box.border_width_left = Tokens.SELECTED_RULE_WIDTH
		elif role == "active":
			box.border_width_left = Tokens.ACTIVE_RULE_WIDTH
	return box

static func focus_style() -> StyleBoxFlat:
	var box := flat_style(Color.TRANSPARENT, Tokens.ACCENT_INTERACTIVE, 0,
		"flush", Tokens.BORDER_EMPHASIS)
	box.draw_center = false
	return box

# A draw hook also covers TextureButton, LinkButton and Slider, which do not
# all consume a native "focus" StyleBox. It adds no layout or input surface.
static func ensure_focus(ctrl: Control) -> void:
	if ctrl is SpinBox:
		ensure_focus((ctrl as SpinBox).get_line_edit())
		return
	ctrl.focus_mode = Control.FOCUS_ALL
	ctrl.add_theme_stylebox_override("focus", focus_style())
	var redraw := ctrl.queue_redraw
	if not ctrl.focus_entered.is_connected(redraw):
		ctrl.focus_entered.connect(redraw)
		ctrl.focus_exited.connect(redraw)
	var draw_focus := _draw_focus.bind(ctrl)
	if not ctrl.draw.is_connected(draw_focus):
		ctrl.draw.connect(draw_focus)

static func _draw_focus(ctrl: Control) -> void:
	if ctrl.has_focus():
		ctrl.get_theme_stylebox("focus").draw(ctrl.get_canvas_item(), Rect2(Vector2.ZERO, ctrl.size))

static func apply_action(button: Button, role: String = "secondary") -> Button:
	for state: String in Tokens.CONTROL_STATES:
		button.add_theme_stylebox_override(state, action_style(role, state))
	button.add_theme_stylebox_override("hover_pressed", action_style(role, "pressed"))
	for state: String in ["normal", "hover", "pressed", "hover_pressed", "disabled", "focus"]:
		var key := "font_color" if state == "normal" else "font_%s_color" % state
		button.add_theme_color_override(key, Tokens.role_colors(role, state)["text"])
	button.custom_minimum_size.y = maxf(button.custom_minimum_size.y, Tokens.HIT_TARGET_MIN)
	ensure_focus(button)
	return button


# Authored screen chrome, monochrome white SVG tinted with `modulate` at the
# call site - the same contract assets/hud/icons + hud_icons.gd established for
# the in-match HUD, kept separate from it because these are out-of-match assets
# and the two languages do not share a registry.
#
# Returns null when the asset is missing rather than substituting a placeholder,
# so a renamed file costs a glyph and the caller falls back to text. Nothing here
# may become load-bearing enough to break a build.
const CHROME_DIR = "res://assets/ui/matchsetup/"
static var _chrome_cache: Dictionary = {}

static func chrome_icon(name: String) -> Texture2D:
	if name == "stage_theatre": name = "stage_map"
	if _chrome_cache.has(name):
		return _chrome_cache[name]
	var path := CHROME_DIR + name + ".svg"
	var tex: Texture2D = null
	if ResourceLoader.exists(path):
		tex = load(path) as Texture2D
	else:
		push_warning("UITheme: missing chrome glyph '%s' - falling back to text." % path)
	_chrome_cache[name] = tex
	return tex


# A tinted chrome glyph sized to `px`, or null if the asset is absent. Callers
# that need a text fallback test for null; callers that only want decoration can
# add the result unconditionally with an is_instance_valid guard.
static func chrome_rect(name: String, px: int, tint: Color = Tokens.TEXT_PRIMARY) -> TextureRect:
	var tex := chrome_icon(name)
	if tex == null:
		return null
	var tr := TextureRect.new()
	tr.texture = tex
	tr.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	tr.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	tr.custom_minimum_size = Vector2(px, px)
	tr.modulate = tint
	tr.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return tr
