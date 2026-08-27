class_name UITokens
extends RefCounted
# Single source of truth for the interface's visual language - palette, type
# scale, spacing, and border radii. Everything else (build_ui_theme.gd, the
# per-screen scripts, the panel shader) reads from here rather than writing
# its own literals.
#
# Why this file exists: before it, roughly half the UI came from
# bomber_theme.tres and the other half from StyleBoxFlat instances built
# inline in skirmish.gd / stat_calculator.gd / match_setup.gd with hardcoded
# colors. The two halves had drifted - the theme's accent was a cyan-blue
# (0.20, 0.60, 0.85) while the inline panels used a grey-blue (0.30, 0.35,
# 0.40), and the build buttons used flat saturated web red/green/blue that
# appear nowhere in the theme at all. A design system that only covers half
# the screen isn't one, so the literals had to collect somewhere.
#
# DIRECTION (Chris): units are cartoonish and semi-zany, terrain is serious
# and realistic, and all of it is played completely straight. The interface
# is on the serious side of that split. Its job is to be a quiet, credible
# instrument housing so the saturated toy-like units read as the loud thing
# on screen. If the UI competes with the units for saturation, both lose.

# ---------------------------------------------------------------------------
# PALETTE
# ---------------------------------------------------------------------------
# Base is a WARM neutral dark, not the blue-black it used to be. The old
# (0.07, 0.08, 0.10) base with a cyan accent is the default "sci-fi dark
# mode" palette that ships with every engine demo, and it fought the warm
# aluminum/olive direction the units and terrain already commit to. Warm
# greys also sit further from the cool sky and water the terrain renders,
# so the chrome separates from the world instead of blending into it.
const BASE_900 = Color(0.075, 0.074, 0.068, 1.0)  # deepest recess, modal scrim
const BASE_800 = Color(0.108, 0.106, 0.098, 1.0)  # panel body
const BASE_700 = Color(0.145, 0.142, 0.131, 1.0)  # raised control body
const BASE_600 = Color(0.196, 0.190, 0.174, 1.0)  # hover / raised edge
const BASE_500 = Color(0.290, 0.281, 0.257, 1.0)  # borders, dividers
const BASE_400 = Color(0.404, 0.392, 0.360, 1.0)  # disabled text, hairlines

# Text. Warm off-white rather than pure white - pure white on a warm dark
# panel reads as a blown-out highlight and vibrates at small sizes.
const TEXT_PRIMARY = Color(0.937, 0.925, 0.898, 1.0)
const TEXT_SECONDARY = Color(0.678, 0.663, 0.627, 1.0)
const TEXT_DISABLED = Color(0.435, 0.424, 0.396, 1.0)
# SIGNAL COLORS. Deliberately few, and each one means exactly one thing
# everywhere it appears. This is the rule the old UI broke worst: it had a
# saturated red "Delete", a saturated green "Save", and a saturated blue
# "Test" sitting in a row, which spends the player's entire attention budget
# on three buttons that are not emergencies. Signal color is for STATE, not
# for decorating actions.
const SIGNAL_HAZARD = Color(0.878, 0.667, 0.180, 1.0)   # attention, selection, warning
const SIGNAL_ALERT = Color(0.784, 0.267, 0.196, 1.0)    # damage, failure, destructive
const SIGNAL_GO = Color(0.400, 0.612, 0.290, 1.0)       # ready, affordable, confirmed
const SIGNAL_INFO = Color(0.376, 0.573, 0.663, 1.0)     # informational only, never an action

# Dimmed variants, for fills that sit UNDER text rather than beside it.
const SIGNAL_HAZARD_DIM = Color(0.259, 0.204, 0.075, 1.0)
const SIGNAL_ALERT_DIM = Color(0.243, 0.098, 0.078, 1.0)
const SIGNAL_GO_DIM = Color(0.133, 0.196, 0.106, 1.0)

# Toolkit skin physical hardware accents.
const TOOLKIT_WARM_HIGHLIGHT = Color(0.850, 0.720, 0.450, 0.15) # Physical brass touch feedback
const TOOLKIT_PATINA         = Color(0.350, 0.420, 0.380, 0.25) # Aged tool rail patina accent

# ACCENT ROLES — the semantic system for non-signal colour use.
# Amber is the ONLY interactive accent (selected, active, clickable).
# Category grouping uses a muted neutral, never a signal colour.
const ACCENT_INTERACTIVE = SIGNAL_HAZARD       # amber — selected, active, clickable
const ACCENT_CATEGORY    = BASE_500            # muted warm grey — category grouping
const ACCENT_HARVESTER   = SIGNAL_INFO         # steel blue — harvester bay identity only

# ---------------------------------------------------------------------------
# TYPE SCALE
# ---------------------------------------------------------------------------
# Fixed steps, not arbitrary per-call font sizes. The old UI had 14, 15, 16,
# 18, 22, 24 and 42 scattered across call sites with no relationship between
# them, which is why nothing on screen looked like it belonged to anything
# else on screen.
const FONT_DISPLAY = 40  # title screen wordmark only
const FONT_TITLE = 24    # screen titles
const FONT_HEADING = 17  # panel/section headers
const FONT_BODY = 15     # default reading size
const FONT_SMALL = 13    # secondary/hint text
const FONT_MICRO = 11    # dense tabular readouts, footnotes

# ---------------------------------------------------------------------------
# SPACING - a 4px base grid. Every margin and gap should be one of these.
# ---------------------------------------------------------------------------
# The Design Lab's top toolbar height (VISUAL/UI plan item 7). Lives here rather
# than in stat_calculator.gd because the docks have to start BELOW it: the toolbar
# spans the full width, and the first version had the parts catalogue drawn over
# the top of it, clipping the mirror toggle to "ment [M]". Two scenes need the
# same number, so the number belongs to the token set.
#
# 64, RAISED FROM 44, and the reason is worth recording because the failure mode
# recurred: this token is what both docks inset their top by, but it does NOT
# constrain the toolbar - a PanelContainer cannot render shorter than its content's
# combined minimum size, so offset_bottom is a floor the buttons can exceed.
#
# When button padding went from SPACE_MD/SPACE_SM to SPACE_LG/SPACE_MD (the
# "buttons look cramped" fix), the bar's real height became 64 while the docks
# still inset by 44. The top 20px of each collapsed rail then covered the bottom
# 20px of the toolbar - exactly the band holding UNDO/REDO on the left and
# SAVE/TEST on the right, which is why those became unclickable.
#
# stat_calculator.gd's _build_toolbar() now warns at runtime if the bar's measured
# height exceeds this token, so the next change to button padding says so instead
# of silently eating the toolbar again.
const TOOLBAR_HEIGHT = 64

const SPACE_XS = 4
const SPACE_SM = 8
const SPACE_MD = 12
const SPACE_LG = 20
const SPACE_XL = 32

# ---------------------------------------------------------------------------
# GEOMETRY
# ---------------------------------------------------------------------------
# Near-square corners. The old 4-6px radii read as consumer-software
# roundedness; stamped and machined panels have a barely-broken edge. 2px is
# enough to keep corners from looking like an aliasing artifact without
# reading as "soft".
const RADIUS_PANEL = 2
const RADIUS_CONTROL = 2
const BORDER_HAIRLINE = 1
const BORDER_EMPHASIS = 2

# Minimum hit target for anything clicked during real-time play. Below this,
# the bottom command bar starts costing players fights.
const HIT_TARGET_MIN = 32

# ---------------------------------------------------------------------------
# ELEVATION
# ---------------------------------------------------------------------------
# Four tiers of "how far off the backdrop does this surface sit". Before this,
# nothing in the interface cast a shadow at all - every panel, dock, flyout and
# tooltip sat in exactly the same plane, separated only by a 1px border. That
# reads as a diagram of an interface rather than a stack of real hardware, and
# it is the single biggest reason the chrome looked unfinished next to the 3D.
#
# The shadow is a WARM near-black, not black. On a warm neutral ground a
# neutral or cool shadow doesn't read as shadow - it reads as grime, or as a
# dark smudge painted onto the panel. Matching the base hue keeps it reading as
# absence of light. Same reasoning as the palette's warm-vs-blue-black note.
#
# Offset is straight DOWN, never sideways. The plate textures are authored with
# their bevel lit from the top-left (see the plate spec in
# UI_IMPLEMENTATION_PLAN.md), so a light source above means the cast falls
# below. A shadow offset that disagrees with the bevel highlight makes both
# read as texture noise instead of as depth.
const SHADOW_COLOR = Color(0.035, 0.032, 0.026, 1.0)

# Blur radius in px. FLUSH is 0 because a recessed surface must not cast at
# all - HUDPanel and InsetPanel are sunk INTO their parent, and giving them a
# shadow would claim they float above the very thing they're set into.
const ELEVATION_FLUSH = 0
const ELEVATION_RAISED = 3     # cards, docks, header bands - sits on the backdrop
const ELEVATION_FLOATING = 8   # flyouts, callouts, tooltips - sits over content
const ELEVATION_MODAL = 18     # dialogs over a scrim - sits over everything

# Deliberately much smaller than the blur. A large offset with a small blur is
# the drop-shadow look of 2000s web design; hardware sitting on a surface has a
# tight contact shadow directly beneath it.
const SHADOW_OFFSET_RAISED = 1
const SHADOW_OFFSET_FLOATING = 3
const SHADOW_OFFSET_MODAL = 6

# ---------------------------------------------------------------------------
# MOTION
# ---------------------------------------------------------------------------
# These were previously private to ui_anim.gd, which meant the motion system
# and the visual system had separate sources of truth and only ui_anim's own
# call sites could reach the timings. The theme builder and the per-screen
# scripts need them too (a hover transition has to match the hover plate swap),
# so they belong with the rest of the language. ui_anim.gd re-exports its
# original constant names as aliases onto these, so no existing call site moved.
#
# Everything is SHORT. Gritty means mechanical, not showy: a mechanism responds
# immediately or it feels broken. Anything above DURATION_SLOW on an
# interaction (as opposed to a scene transition) reads as the game hesitating.
const DURATION_INSTANT = 0.06  # hover acknowledgement - must feel like no delay
const DURATION_FAST = 0.12     # press feedback, ring pop
const DURATION_NORMAL = 0.22   # panel/card entrance, toast
const DURATION_SLOW = 0.4      # scene fade, full-screen overlay

# Per-child delay for a staggered list entrance. At 35ms a 12-row list finishes
# in ~0.4s, which reads as one gesture sweeping down the list. Much larger and
# the last row arrives late enough to feel like a loading bug.
const STAGGER_STEP = 0.035

const EASE_STANDARD := Tween.EASE_OUT
const TRANS_STANDARD := Tween.TRANS_CUBIC


# Returns the fill/border pair for a signal role, so callers don't hand-pick
# a dim variant and get the pairing subtly wrong.
static func signal_pair(role: String) -> Dictionary:
	match role:
		"hazard":
			return {"fill": SIGNAL_HAZARD_DIM, "edge": SIGNAL_HAZARD}
		"alert":
			return {"fill": SIGNAL_ALERT_DIM, "edge": SIGNAL_ALERT}
		"go":
			return {"fill": SIGNAL_GO_DIM, "edge": SIGNAL_GO}
		_:
			return {"fill": BASE_700, "edge": BASE_500}


# Returns the shadow triple for an elevation tier, for the same reason
# signal_pair() exists: the blur, the offset and the alpha are three numbers
# that only look right in the combinations tuned here. Hand-picking a blur of 8
# with an offset of 1 gives a floating panel a contact shadow, which reads as a
# rendering mistake rather than as a different height.
#
# Returns size 0 / a fully transparent colour for "flush" so a caller can apply
# the result unconditionally without branching on the tier - assigning these to
# a StyleBoxFlat is a no-op rather than a faint smudge.
static func elevation(tier: String) -> Dictionary:
	match tier:
		"raised":
			return {
				"size": ELEVATION_RAISED,
				"offset": Vector2(0, SHADOW_OFFSET_RAISED),
				"color": Color(SHADOW_COLOR, 0.35),
			}
		"floating":
			return {
				"size": ELEVATION_FLOATING,
				"offset": Vector2(0, SHADOW_OFFSET_FLOATING),
				"color": Color(SHADOW_COLOR, 0.45),
			}
		"modal":
			return {
				"size": ELEVATION_MODAL,
				"offset": Vector2(0, SHADOW_OFFSET_MODAL),
				"color": Color(SHADOW_COLOR, 0.55),
			}
		_:
			return {
				"size": ELEVATION_FLUSH,
				"offset": Vector2.ZERO,
				"color": Color(SHADOW_COLOR, 0.0),
			}


# Applies an elevation tier to a StyleBoxFlat. Kept here rather than in
# build_ui_theme.gd because the runtime screens build state-indicator styleboxes
# too (see stat_calculator.gd's load-bar fills) and should elevate them the same
# way the theme does.
#
# StyleBoxTexture - which every plate-backed variation uses - has no shadow
# properties at all, so it cannot go through this path. Those variations get
# their depth from the plate's own baked bevel instead; see build_ui_theme.gd.
static func apply_elevation(box: StyleBoxFlat, tier: String) -> void:
	var e := elevation(tier)
	box.shadow_size = e["size"]
	box.shadow_offset = e["offset"]
	box.shadow_color = e["color"]


# ---------------------------------------------------------------------------
# L2 PHOSPHOR - the CRT substrate. Amber = Design Lab, green = battle. These
# are a SUBSTRATE, not a state - never reused for warning/go/etc even where a
# colour happens to be close. See shaders/phosphor_display.gdshader's header
# and PhosphorPanel for how the pair is actually applied.
# ---------------------------------------------------------------------------

const PHOSPHOR_AMBER = Color(1.0, 0.690, 0.0, 1.0)
const PHOSPHOR_AMBER_DIM = Color(0.220, 0.145, 0.020, 1.0)
const PHOSPHOR_GREEN = Color(0.365, 1.0, 0.494, 1.0)
const PHOSPHOR_GREEN_DIM = Color(0.055, 0.196, 0.078, 1.0)
const PHOSPHOR_GLASS = Color(0.031, 0.043, 0.035, 1.0)

# Screen-pixel scanline pitch, not UV - see the shader header, note 1. Kept
# here rather than hardcoded in the shader's default so every phosphor surface
# in the game shares one tuned value.
const SCANLINE_PITCH = 3.0
const PERSISTENCE_DECAY = 0.4

# How far a phosphor readout insets its content from the bezel edge - the L2
# equivalent of a plate's own margin, called out separately because a glass
# surface with no inset reads as content bleeding off a broken screen.
const BEZEL_INSET = 6


# Returns the lit/unlit/glass triple for a tube colour, so a caller cannot
# assemble the wrong pairing (e.g. green lit against an amber unlit) the way
# hand-picking three separate constants would allow.
static func phosphor_pair(tube: String) -> Dictionary:
	match tube:
		"green":
			return {"lit": PHOSPHOR_GREEN, "unlit": PHOSPHOR_GREEN_DIM, "glass": PHOSPHOR_GLASS}
		_:
			return {"lit": PHOSPHOR_AMBER, "unlit": PHOSPHOR_AMBER_DIM, "glass": PHOSPHOR_GLASS}
