class_name HUDStyle
extends RefCounted
# The whole visual vocabulary of the battle HUD, in one file.
#
# THIS IS A DELIBERATE BREAK from ui_tokens.gd / bakelite_panel.gd /
# crt_readout.gd / aluminum_trim.gd / folded_paper_panel.gd. Those build a
# diegetic 1950s command desk by generating textures at runtime, and the battle
# HUD is the one surface where that costs more than it pays: the player reads
# these panels while something is shooting at them. Every value here is chosen
# for legibility at a glance, and nothing here generates a texture.
#
# The rules, so a later addition stays consistent:
#   - Panels are flat fills with a 1 px edge. No gradients, no bevels, no noise.
#   - Colour carries exactly one meaning at a time. TEAM_FRIENDLY is never used
#     for "good", OK is never used for "friendly".
#   - Numbers are monospaced so a changing digit does not reflow the row.
#   - Icons are monochrome white SVGs tinted by modulate. Never a coloured icon.

# --- Palette ----------------------------------------------------------------
# Neutral ramp. Cold-War military console olive-charcoal.
const VOID        := Color(0.045, 0.065, 0.055)   # Deepest unpowered CRT / unexplored
const PANEL       := Color(0.088, 0.120, 0.100)   # Cold-War milspec console housing
const PANEL_RAISE := Color(0.128, 0.170, 0.142)   # Raised instrument switch body
const PANEL_HOVER := Color(0.178, 0.238, 0.198)   # Active switch / hover surface
const EDGE        := Color(0.200, 0.280, 0.225)   # Machined console seam
const EDGE_BRIGHT := Color(0.320, 0.520, 0.380)   # Phosphor CRT illuminated active bezel
const CIC_EDGE    := Color(0.320, 0.520, 0.380)   # Cold-War CIC phosphor accent border
const SCAN_LINE   := Color(0.365, 1.000, 0.494, 0.03) # Faint CRT scanline tint
const RETICLE     := Color(0.400, 0.700, 0.450, 0.70) # Radar reticle / tracking green

const TEXT        := Color(0.910, 0.950, 0.900)   # Gauge dial off-white primary
const TEXT_DIM    := Color(0.580, 0.680, 0.600)   # Cold-War green-grey secondary
const TEXT_FAINT  := Color(0.350, 0.450, 0.380)   # Disabled / hint
const STENCIL_DIM := Color(0.720, 0.820, 0.740)   # Cold-War CIC placard heading text

# Semantic.
const OK          := Color(0.350, 0.850, 0.500)   # Radar phosphor green complete, affordable
const WARN        := Color(0.950, 0.700, 0.200)   # Incandescent amber warning lamp
const BAD         := Color(0.920, 0.260, 0.220)   # Alarm red lamp

# Team identity.
const TEAM_FRIENDLY := Color(0.300, 0.720, 0.920)
const TEAM_HOSTILE  := Color(0.920, 0.260, 0.220)
const TEAM_NEUTRAL  := Color(0.680, 0.740, 0.700)

# Resources. Distinct from every status colour so a resource count is never
# mistaken for a warning.
const METAL       := Color(0.760, 0.820, 0.800)
const CRYSTAL     := Color(0.450, 0.750, 0.900)
const POWER       := Color(0.950, 0.800, 0.250)

const SELECTED    := Color(1.0, 1.0, 1.0)

# --- Metrics ----------------------------------------------------------------
const SP_XS := 3
const SP_SM := 6
const SP_MD := 10
const SP_LG := 16
const SP_XL := 24

const RADIUS := 2        # near-square. Rounded corners read as "app", not "instrument".
const BORDER := 1

# Minimum comfortable click target. Every button here meets it.
const HIT := 28

# --- Layout -----------------------------------------------------------------
# The bottom band that holds map / production / command card. Everything above
# it is battle viewport and stays clear.
# The map is SQUARE and fills the band's full height, so these two are one
# number. They were 208 and 240, which made the map 32 px taller than the band it
# sits in - it would have hung over the production deck's top edge.
const BAND_HEIGHT := 224.0
const MAP_SIZE := 224.0
const CARD_WIDTH := 320.0
const RIBBON_HEIGHT := 40.0

# --- Type -------------------------------------------------------------------
const FONT_UI := "res://assets/fonts/UIFont-Regular.ttf"
const FONT_UI_BOLD := "res://assets/fonts/UIFont-Bold.ttf"
const FONT_MONO := "res://assets/fonts/MonoFont-Regular.ttf"
const FONT_STENCIL := "res://assets/fonts/StencilFont-Regular.ttf"

const SZ_MICRO := 10
const SZ_SMALL := 12
const SZ_BODY  := 14
const SZ_HEAD  := 16
const SZ_BIG   := 20


static func font(path: String) -> Font:
	# load() not preload(): a static func cannot hold a preload constant, and
	# the engine resource cache makes the repeat cost a dictionary lookup.
	var f = load(path)
	return f if f is Font else null


const PLATE_DIR := "res://assets/textures/ui/"
const PLATE_MARGIN := 12
const PLATE_PAD := 16

static var _plate_cache: Dictionary = {}

static func _plate_box(material: String, state: String, margin_h: int = SP_MD, margin_v: int = SP_SM) -> StyleBox:
	var key := "%s_%s" % [material, state]
	if _plate_cache.has(key):
		var cached = _plate_cache[key]
		if cached is StyleBoxTexture:
			var sb := cached.duplicate() as StyleBoxTexture
			sb.content_margin_left = margin_h
			sb.content_margin_right = margin_h
			sb.content_margin_top = margin_v
			sb.content_margin_bottom = margin_v
			return sb

	var path := PLATE_DIR + "plate_%s_%s.png" % [material, state]
	if ResourceLoader.exists(path):
		var tex = load(path) as Texture2D
		if tex != null:
			var sb := StyleBoxTexture.new()
			sb.texture = tex
			var frame := PLATE_MARGIN + PLATE_PAD
			sb.texture_margin_left = frame
			sb.texture_margin_right = frame
			sb.texture_margin_top = frame
			sb.texture_margin_bottom = frame
			sb.expand_margin_left = PLATE_PAD
			sb.expand_margin_right = PLATE_PAD
			sb.expand_margin_top = PLATE_PAD
			sb.expand_margin_bottom = PLATE_PAD
			sb.content_margin_left = margin_h
			sb.content_margin_right = margin_h
			sb.content_margin_top = margin_v
			sb.content_margin_bottom = margin_v
			_plate_cache[key] = sb
			return sb

	var flat := StyleBoxFlat.new()
	flat.bg_color = PANEL_HOVER if state == "hover" else (PANEL_RAISE if state == "pressed" else PANEL)
	flat.set_border_width_all(BORDER)
	flat.border_color = EDGE_BRIGHT if state == "hover" else EDGE
	flat.set_corner_radius_all(RADIUS)
	flat.content_margin_left = margin_h
	flat.content_margin_right = margin_h
	flat.content_margin_top = margin_v
	flat.content_margin_bottom = margin_v
	return flat


# --- Panels -----------------------------------------------------------------

# The one panel look. `raised` is for anything the mouse interacts with;
# unraised is for backing surfaces.
static func panel_box(raised: bool = false, _edge: Color = EDGE) -> StyleBox:
	return _plate_box("cic_frame", "hover" if raised else "normal", SP_MD, SP_MD)


# A filled swatch with no border - progress fills, badges, 2D blips.
static func fill_box(c: Color, radius: int = RADIUS) -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = c
	sb.set_corner_radius_all(radius)
	sb.set_content_margin_all(0)
	return sb


# An empty box that only draws one edge. Used for tab underlines, where a full
# border would box in content meant to read as continuous with its body.
static func underline_box(c: Color, thickness: int = 2) -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.draw_center = false
	sb.border_width_bottom = thickness
	sb.border_color = c
	sb.set_content_margin_all(0)
	return sb


static func apply_panel(to: Control, raised: bool = false, edge: Color = EDGE) -> void:
	to.add_theme_stylebox_override("panel", panel_box(raised, edge))


# --- Labels -----------------------------------------------------------------

static func label(text: String, size: int = SZ_BODY, color: Color = TEXT,
		mono: bool = false, bold: bool = false) -> Label:
	var l := Label.new()
	l.text = text
	var path := FONT_MONO if mono else (FONT_UI_BOLD if bold else FONT_UI)
	var f := font(path)
	if f != null:
		l.add_theme_font_override("font", f)
	l.add_theme_font_size_override("font_size", size)
	l.add_theme_color_override("font_color", color)
	l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	l.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	return l


# A number that changes every tick. Monospaced and right-aligned so the row does
# not twitch as digits gain and lose width.
static func readout(text: String, size: int = SZ_BODY, color: Color = TEXT) -> Label:
	var l := label(text, size, color, true)
	l.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	return l


# Small all-caps section heading.
static func heading(text: String) -> Label:
	return label(text.to_upper(), SZ_MICRO, TEXT_DIM, false, true)


# Cold-War CIC stamped heading with StencilFont.
static func heading_stencil(text: String, size: int = SZ_HEAD, color: Color = STENCIL_DIM) -> Label:
	var l := Label.new()
	l.text = text.to_upper()
	var f := font(FONT_STENCIL)
	if f != null:
		l.add_theme_font_override("font", f)
	l.add_theme_font_size_override("font_size", size)
	l.add_theme_color_override("font_color", color)
	l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	l.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	return l


# Hardware status lamp / indicator dot.
static func lamp(color: Color = OK, diameter: int = 8) -> Panel:
	var p := Panel.new()
	p.custom_minimum_size = Vector2(diameter, diameter)
	p.add_theme_stylebox_override("panel", fill_box(color, int(diameter * 0.5)))
	p.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return p


# --- Buttons ----------------------------------------------------------------
# Cold-War military console tactile keycaps.
static func style_button(b: Button, _accent: Color = TEAM_FRIENDLY) -> void:
	var normal := _plate_box("cic_button", "normal", SP_SM, SP_XS)
	var hover := _plate_box("cic_button", "hover", SP_SM, SP_XS)
	var pressed := _plate_box("cic_button", "pressed", SP_SM, SP_XS)
	var disabled := _plate_box("cic_button", "disabled", SP_SM, SP_XS)

	b.add_theme_stylebox_override("normal", normal)
	b.add_theme_stylebox_override("hover", hover)
	b.add_theme_stylebox_override("pressed", pressed)
	b.add_theme_stylebox_override("focus", normal)
	b.add_theme_stylebox_override("disabled", disabled)

	var f := font(FONT_UI_BOLD)
	if f != null:
		b.add_theme_font_override("font", f)
	b.add_theme_font_size_override("font_size", SZ_SMALL)
	b.add_theme_color_override("font_color", TEXT)
	b.add_theme_color_override("font_hover_color", Color(0.45, 1.0, 0.65)) # Phosphor illuminated hover
	b.add_theme_color_override("font_pressed_color", Color.WHITE)
	b.add_theme_color_override("font_disabled_color", TEXT_FAINT)
	b.focus_mode = Control.FOCUS_NONE


static func button(text: String, accent: Color = TEAM_FRIENDLY) -> Button:
	var b := Button.new()
	b.text = text
	b.custom_minimum_size = Vector2(0, HIT)
	style_button(b, accent)
	return b


# --- Small compound widgets -------------------------------------------------

# A 1 px rule. Horizontal by default; `vertical` for column separators.
static func divider(vertical: bool = false) -> Panel:
	var p := Panel.new()
	p.add_theme_stylebox_override("panel", fill_box(EDGE, 0))
	p.mouse_filter = Control.MOUSE_FILTER_IGNORE
	if vertical:
		p.custom_minimum_size = Vector2(1, 0)
		p.size_flags_vertical = Control.SIZE_EXPAND_FILL
	else:
		p.custom_minimum_size = Vector2(0, 1)
		p.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	return p


# A thin bar. ProgressBar rather than two Panels because it already clamps and
# lays out the fill; the theme baggage is fully overridden here.
static func bar(height: int, fill: Color, track: Color = VOID) -> ProgressBar:
	var pb := ProgressBar.new()
	pb.show_percentage = false
	pb.min_value = 0.0
	pb.max_value = 1.0
	pb.value = 0.0
	pb.custom_minimum_size = Vector2(0, height)
	pb.add_theme_stylebox_override("background", fill_box(track, 0))
	pb.add_theme_stylebox_override("fill", fill_box(fill, 0))
	pb.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return pb


# Colour for an HP fraction. Three bands, not a gradient: a gradient makes "is
# that unit in trouble" a judgement call instead of a glance.
static func health_color(frac: float) -> Color:
	if frac > 0.6:
		return OK
	if frac > 0.3:
		return WARN
	return BAD
