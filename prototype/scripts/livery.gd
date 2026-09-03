extends RefCounted
# THE PLAYER'S OWN FACTION, REPLACING THE TEN PREMADE ONES.
#
# faction_catalog.gd used to hold 10 hand-authored factions, each pairing a
# fixed visual identity with a mechanical passive (-20% armor weight, +15%
# vision, ...). Both halves are gone, and so is that file - deleted 2026-08-31
# once nothing referenced it but stale comments. What replaces them is this: a livery the
# player authors themselves, which is PURELY COSMETIC. There is no longer any
# such thing as a faction bonus, so two identical designs fight identically no
# matter whose colours they wear - every stat now comes from what the player
# actually built, which is the premise of the whole game.
#
# FIVE ZONES, chosen so a livery reads at RTS camera distance rather than
# rewarding pixel-peeping:
#   hull_lower    - the hull below the belt line
#   hull_upper    - the hull above it (the face the top-down camera sees most)
#   hull_stripe   - a stripe/pattern overlay running across the hull
#   weapon_action - receivers, breeches, mounts, turret bodies
#   weapon_barrel - barrels, muzzles, launch tubes
# Weapons split from the hull because a weapon is the part a player looks at
# when identifying what a unit DOES, and letting it carry its own two-tone is
# what makes "same chassis, different gun" readable across a battle line.
#
# Each zone carries a COLOUR and a FINISH. The finish is the PBR half - a
# colour alone cannot tell matte primer from anodised metal, and that
# difference is most of what makes a livery look authored rather than tinted.

const SAVE_PATH := "user://livery.json"

# GLOSS IS CAPPED IN THE SATIN RANGE for dielectrics to prevent blown-out mirror reflections.
const SATIN_ROUGHNESS_FLOOR := 0.35

# Surface types for procedural micro-normal synthesis:
# 0 = standard/smooth
# 1 = carbon_fibre (2x2 twill weave normal + anisotropic sheen)
# 2 = hammered (crater dimples / peened armor)
# 3 = cast_iron (rough granular sand-cast)
# 4 = galvanised (voronoi crystal zinc spangle flakes)
# 5 = brushed (directional linear grain streaks)
# 6 = cerakote / matte_primer (micro-stipple chalk diffuse absorption)
# 7 = rubberised (soft-fresnel velvety polymer)
# 8 = fiberglass (woven fiber strand bump)
# 9 = anodised (ultra-smooth high-chroma metallic sheen)

const FINISHES = {
	# --- Dielectric, very matte ---
	"cerakote":         {"name": "Cerakote",                "metallic": 0.00, "roughness": 0.98, "surface_type": 6},
	"matte_primer":     {"name": "Matte Primer",            "metallic": 0.00, "roughness": 0.95, "surface_type": 6},
	"ghillie":          {"name": "Ghillie Netting",         "metallic": 0.00, "roughness": 0.92, "surface_type": 8,
		"albedo_tint": Color(0.42, 0.48, 0.30)},
	"powdercoat":       {"name": "Powdercoat",              "metallic": 0.00, "roughness": 0.92, "surface_type": 6},
	"rubberised":       {"name": "Rubberised",              "metallic": 0.00, "roughness": 0.90, "surface_type": 7},
	"weathered_enamel": {"name": "Weathered Enamel",        "metallic": 0.10, "roughness": 0.86, "surface_type": 0},
	"phosphate":        {"name": "Phosphate (Parkerized)",  "metallic": 0.30, "roughness": 0.85, "surface_type": 3,
		"albedo_tint": Color(0.32, 0.30, 0.28)},
	# --- Dielectric with tooth, mid-matte ---
	"cast_iron":        {"name": "Cast Iron",               "metallic": 0.45, "roughness": 0.80, "surface_type": 3},
	"hammered":         {"name": "Hammered Metal",          "metallic": 0.55, "roughness": 0.72, "surface_type": 2},
	"fiberglass":       {"name": "Fiberglass",              "metallic": 0.00, "roughness": 0.65, "surface_type": 8,
		"albedo_tint": Color(0.78, 0.74, 0.66)},
	"eggshell":         {"name": "Eggshell",                "metallic": 0.05, "roughness": 0.68, "surface_type": 0},
	# --- Metal, satin & textured ---
	"galvanised":       {"name": "Galvanised Zinc",         "metallic": 0.72, "roughness": 0.62, "surface_type": 4},
	"gunmetal":         {"name": "Gunmetal",                "metallic": 0.78, "roughness": 0.58, "surface_type": 5},
	"brushed_steel":    {"name": "Brushed Steel",           "metallic": 0.74, "roughness": 0.52, "surface_type": 5},
	"carbon_fibre":     {"name": "Carbon Fibre",            "metallic": 0.42, "roughness": 0.50, "surface_type": 1},
	"brushed_alloy":    {"name": "Brushed Alloy",           "metallic": 0.66, "roughness": 0.48, "surface_type": 5},
	"satin_enamel":     {"name": "Satin Enamel",            "metallic": 0.08, "roughness": 0.48, "surface_type": 0},
	# --- Metal, glossiest satin ---
	"anodised":         {"name": "Anodised Aluminum",       "metallic": 0.82, "roughness": 0.40, "surface_type": 9},
}

# 17 Procedural pattern types
const PATTERNS := {
	"none":           {"name": "Solid / Clean Split",     "id_int": 0,  "desc": "Clean two-tone hull without overlay pattern"},
	"stripe":         {"name": "Centerline Stripe",       "id_int": 1,  "desc": "Single bold racing stripe down the center"},
	"dual_stripe":    {"name": "Dual Racing Stripes",     "id_int": 2,  "desc": "Twin parallel Le Mans rally stripes"},
	"offset_stripe":  {"name": "Offset Rally Stripe",     "id_int": 3,  "desc": "Asymmetric single stripe on port flank"},
	"chevrons":       {"name": "Assault Chevrons",        "id_int": 4,  "desc": "Forward-pointing tactical V-stripes"},
	"hazard":         {"name": "Hazard Caution Bands",    "id_int": 5,  "desc": "Industrial 45° diagonal warning chevrons"},
	"hex_grid":       {"name": "Hex Tactical Grid",       "id_int": 6,  "desc": "High-tech honeycomb armor lattice"},
	"digital_camo":   {"name": "Digital Pixel Camo",      "id_int": 7,  "desc": "Multi-tone digital block camouflage"},
	"splinter_camo":  {"name": "Splinter Dazzle Camo",   "id_int": 8,  "desc": "Angular geometric military camouflage"},
	"tiger_camo":     {"name": "Tiger Wave Camo",         "id_int": 9,  "desc": "Organic disruptive predator wave camouflage"},
	"nose_dip":       {"name": "Dipped Nose / Cowl",      "id_int": 10, "desc": "Front cowl / nose accent blocking"},
	"half_split":     {"name": "Longitudinal Split",      "id_int": 11, "desc": "High-contrast port/starboard color split"},
	"gradient":       {"name": "Airbrush Gradient Fade",  "id_int": 12, "desc": "Smooth continuous transition along the hull"},
	"checkerboard":   {"name": "Checkerboard Flash",      "id_int": 13, "desc": "Classic motorsport checker-flag block grid"},
	"zigzag":         {"name": "Zigzag Lightning Stripe",  "id_int": 14, "desc": "Sharp lightning-bolt racing stripe"},
	"urban_camo":     {"name": "Urban Brick Camo",        "id_int": 15, "desc": "Offset rectangular block city camouflage"},
	"arrowhead_flash": {"name": "Arrowhead Flash",        "id_int": 16, "desc": "Single bold forward-pointing arrow marking"},
}

# 10 Insignia icons
const MASCOT_SHAPES: Array = [
	"gear", "hex", "star_compass", "cross", "blade",
	"star_snowflake", "star_sunburst", "diamond", "leaf", "star_propeller",
]

# Default set
const DEFAULT_BUILDING_MESH_SET := "standard_industrial"

# Curated themed presets.
#
# COLOUR RULE, applied 2026-08-31 and worth keeping to when adding one.
# Chroma is capped hard per zone; VALUE is deliberately not capped, because
# value is not what made the old paint look cheap - a bright desaturated
# surface (snow, sand, bare aluminium) is fine and appears throughout the
# reference frames. The caps are:
#
#   hull_upper     saturation <= 0.32
#   hull_lower     saturation <= 0.26, and value * 0.55  (grounding - the belt
#                  line down sits in the vehicle's own shadow)
#   hull_stripe    saturation <= 0.24, and value held within 0.22 of
#                  hull_upper. This zone is the CAMOUFLAGE PARTNER of the
#                  upper hull, not a contrast band: a real camo pair is two
#                  close tones. The sign of the difference is preserved, so a
#                  scheme whose second tone is darker stays darker.
#   weapon_action  saturation <= 0.18, value <= 0.28
#   weapon_barrel  saturation <= 0.16, value <= 0.24
#
# When a colour is pulled well below its authored chroma, its value is scaled
# down in proportion (v * (0.72 + 0.28 * cap/sat)), so a saturated hue becomes
# a DEEP muted version of itself - maroon, ochre, olive - instead of a chalky
# pastel of itself - pink, cream, mint. Colours already inside the cap are
# untouched, which is what keeps the snow schemes white.
#
# The saturated identity each scheme lost is not discarded: it became that
# preset's `accent_emissive` lamp colour.
const PRESETS := {
	"soviet_4bo": {
		"name": "4BO Soviet Drab",
		"pattern_type": "none",
		"pattern_scale": 1.0,
		"pattern_angle": 0.0,
		"pattern_softness": 0.012,
		"weathering": 0.45,
		"accent_emissive": Color(1.000, 0.609, 0.150),
		"accent_emissive_strength": 2.2,
		"decal_icon": "star_compass",
		"decal_badge": "none",
		"hull_upper": {"color": Color(0.237, 0.272, 0.185), "finish": "cast_iron"},
		"hull_lower": {"color": Color(0.088, 0.099, 0.077), "finish": "matte_primer"},
		"hull_stripe": {"color": Color(0.492, 0.474, 0.434), "finish": "weathered_enamel"},
		"weapon_action": {"color": Color(0.180, 0.200, 0.170), "finish": "cast_iron"},
		"weapon_barrel": {"color": Color(0.120, 0.120, 0.130), "finish": "phosphate"},
	},
	"nato_bronzegreen": {
		"name": "NATO Bronzegreen",
		"pattern_type": "splinter_camo",
		"pattern_scale": 1.3,
		"pattern_angle": 15.0,
		"pattern_softness": 0.008,
		"weathering": 0.35,
		"accent_emissive": Color(1.000, 0.622, 0.150),
		"accent_emissive_strength": 2.2,
		"decal_icon": "diamond",
		"decal_badge": "none",
		"hull_upper": {"color": Color(0.220, 0.260, 0.200), "finish": "cerakote"},
		"hull_lower": {"color": Color(0.077, 0.072, 0.066), "finish": "matte_primer"},
		"hull_stripe": {"color": Color(0.308, 0.275, 0.234), "finish": "cerakote"},
		"weapon_action": {"color": Color(0.200, 0.220, 0.200), "finish": "gunmetal"},
		"weapon_barrel": {"color": Color(0.110, 0.110, 0.120), "finish": "gunmetal"},
	},
	"warsaw_pact": {
		"name": "Warsaw Pact Camo",
		"pattern_type": "tiger_camo",
		"pattern_scale": 1.2,
		"pattern_angle": -20.0,
		"pattern_softness": 0.015,
		"weathering": 0.50,
		"accent_emissive": Color(0.150, 0.660, 1.000),
		"accent_emissive_strength": 2.2,
		"decal_icon": "hex",
		"decal_badge": "none",
		"hull_upper": {"color": Color(0.320, 0.340, 0.240), "finish": "cast_iron"},
		"hull_lower": {"color": Color(0.099, 0.099, 0.088), "finish": "matte_primer"},
		"hull_stripe": {"color": Color(0.250, 0.280, 0.300), "finish": "weathered_enamel"},
		"weapon_action": {"color": Color(0.180, 0.190, 0.180), "finish": "cast_iron"},
		"weapon_barrel": {"color": Color(0.100, 0.100, 0.110), "finish": "phosphate"},
	},
	"winter_wash": {
		"name": "Winter Whitewash",
		"pattern_type": "splinter_camo",
		"pattern_scale": 1.4,
		"pattern_angle": 0.0,
		"pattern_softness": 0.020,
		"weathering": 0.70,
		# Derived amber-green from the camo tone; overridden by hand. This
		# scheme's identity is ice, and the auto-derivation read its
		# desaturated olive second tone as the identity hue.
		"accent_emissive": Color(0.400, 0.780, 1.000),
		"accent_emissive_strength": 2.2,
		"decal_icon": "star_snowflake",
		"decal_badge": "none",
		"hull_upper": {"color": Color(0.850, 0.870, 0.880), "finish": "weathered_enamel"},
		"hull_lower": {"color": Color(0.110, 0.121, 0.099), "finish": "matte_primer"},
		"hull_stripe": {"color": Color(0.581, 0.660, 0.502), "finish": "cerakote"},
		"weapon_action": {"color": Color(0.220, 0.240, 0.220), "finish": "cast_iron"},
		"weapon_barrel": {"color": Color(0.120, 0.120, 0.130), "finish": "phosphate"},
	},
	"apex_motorsport": {
		"name": "Apex Motorsport",
		"pattern_type": "dual_stripe",
		"pattern_scale": 1.0,
		"pattern_angle": 0.0,
		"pattern_softness": 0.012,
		"weathering": 0.05,
		"accent_emissive": Color(1.000, 0.452, 0.150),
		"accent_emissive_strength": 2.2,
		"decal_icon": "star_propeller",
		"decal_badge": "circle",
		"hull_upper": {"color": Color(0.920, 0.930, 0.950), "finish": "satin_enamel"},
		"hull_lower": {"color": Color(0.069, 0.077, 0.093), "finish": "carbon_fibre"},
		"hull_stripe": {"color": Color(0.775, 0.655, 0.589), "finish": "anodised"},
		"weapon_action": {"color": Color(0.199, 0.217, 0.243), "finish": "brushed_steel"},
		"weapon_barrel": {"color": Color(0.120, 0.120, 0.140), "finish": "gunmetal"},
	},
	"desert_nomad": {
		"name": "Desert Nomad",
		"pattern_type": "digital_camo",
		"pattern_scale": 1.4,
		"pattern_angle": 0.0,
		"pattern_softness": 0.005,
		"weathering": 0.65,
		"accent_emissive": Color(0.150, 1.000, 0.929),
		"accent_emissive_strength": 2.2,
		"decal_icon": "star_compass",
		"decal_badge": "none",
		"hull_upper": {"color": Color(0.732, 0.640, 0.498), "finish": "cerakote"},
		"hull_lower": {"color": Color(0.206, 0.182, 0.152), "finish": "matte_primer"},
		"hull_stripe": {"color": Color(0.389, 0.512, 0.502), "finish": "weathered_enamel"},
		"weapon_action": {"color": Color(0.280, 0.257, 0.230), "finish": "cast_iron"},
		"weapon_barrel": {"color": Color(0.166, 0.153, 0.139), "finish": "phosphate"},
	},
	"arctic_phantom": {
		"name": "Arctic Phantom",
		"pattern_type": "splinter_camo",
		"pattern_scale": 1.2,
		"pattern_angle": 0.0,
		"pattern_softness": 0.008,
		"weathering": 0.25,
		"accent_emissive": Color(0.150, 0.707, 1.000),
		"accent_emissive_strength": 2.2,
		"decal_icon": "star_snowflake",
		"decal_badge": "circle",
		"hull_upper": {"color": Color(0.920, 0.950, 0.980), "finish": "galvanised"},
		"hull_lower": {"color": Color(0.130, 0.152, 0.176), "finish": "cerakote"},
		"hull_stripe": {"color": Color(0.578, 0.697, 0.760), "finish": "anodised"},
		"weapon_action": {"color": Color(0.230, 0.251, 0.280), "finish": "brushed_alloy"},
		"weapon_barrel": {"color": Color(0.159, 0.172, 0.189), "finish": "gunmetal"},
	},
	"heavy_hazard": {
		"name": "Heavy Industrial",
		"pattern_type": "hazard",
		"pattern_scale": 1.5,
		"pattern_angle": 45.0,
		"pattern_softness": 0.010,
		"weathering": 0.75,
		"accent_emissive": Color(1.000, 0.609, 0.150),
		"accent_emissive_strength": 2.2,
		"decal_icon": "gear",
		"decal_badge": "circle",
		"hull_upper": {"color": Color(0.753, 0.695, 0.512), "finish": "powdercoat"},
		"hull_lower": {"color": Color(0.099, 0.099, 0.105), "finish": "cast_iron"},
		"hull_stripe": {"color": Color(0.533, 0.533, 0.533), "finish": "hammered"},
		"weapon_action": {"color": Color(0.250, 0.240, 0.220), "finish": "cast_iron"},
		"weapon_barrel": {"color": Color(0.120, 0.120, 0.120), "finish": "phosphate"},
	},
	"royal_vanguard": {
		"name": "Royal Vanguard",
		"pattern_type": "chevrons",
		"pattern_scale": 1.1,
		"pattern_angle": 0.0,
		"pattern_softness": 0.012,
		"weathering": 0.10,
		"accent_emissive": Color(1.000, 0.784, 0.150),
		"accent_emissive_strength": 2.2,
		"decal_icon": "star_sunburst",
		"decal_badge": "circle",
		"hull_upper": {"color": Color(0.454, 0.308, 0.321), "finish": "satin_enamel"},
		"hull_lower": {"color": Color(0.065, 0.056, 0.075), "finish": "carbon_fibre"},
		"hull_stripe": {"color": Color(0.674, 0.633, 0.512), "finish": "anodised"},
		"weapon_action": {"color": Color(0.220, 0.200, 0.240), "finish": "brushed_steel"},
		"weapon_barrel": {"color": Color(0.240, 0.229, 0.202), "finish": "anodised"},
	},
	"covert_ops": {
		"name": "Covert Ops",
		"pattern_type": "hex_grid",
		"pattern_scale": 1.3,
		"pattern_angle": 0.0,
		"pattern_softness": 0.008,
		"weathering": 0.30,
		"accent_emissive": Color(0.150, 0.865, 1.000),
		"accent_emissive_strength": 2.2,
		"decal_icon": "hex",
		"decal_badge": "none",
		"hull_upper": {"color": Color(0.160, 0.180, 0.200), "finish": "carbon_fibre"},
		"hull_lower": {"color": Color(0.044, 0.050, 0.055), "finish": "rubberised"},
		"hull_stripe": {"color": Color(0.319, 0.404, 0.420), "finish": "anodised"},
		"weapon_action": {"color": Color(0.140, 0.150, 0.160), "finish": "cerakote"},
		"weapon_barrel": {"color": Color(0.080, 0.080, 0.090), "finish": "gunmetal"},
	},
	"jungle_strike": {
		"name": "Jungle Strike",
		"pattern_type": "tiger_camo",
		"pattern_scale": 1.2,
		"pattern_angle": 0.0,
		"pattern_softness": 0.015,
		"weathering": 0.55,
		# Overridden by hand: the derived lamp was green, which on a green
		# hull on green terrain is unreadable. A marker light is the one
		# element that has to contrast with the map, not with the paint.
		"accent_emissive": Color(1.000, 0.560, 0.140),
		"accent_emissive_strength": 2.2,
		"decal_icon": "leaf",
		"decal_badge": "none",
		"hull_upper": {"color": Color(0.259, 0.345, 0.235), "finish": "matte_primer"},
		"hull_lower": {"color": Color(0.106, 0.097, 0.078), "finish": "cerakote"},
		"hull_stripe": {"color": Color(0.129, 0.157, 0.119), "finish": "weathered_enamel"},
		"weapon_action": {"color": Color(0.220, 0.240, 0.200), "finish": "phosphate"},
		"weapon_barrel": {"color": Color(0.120, 0.130, 0.110), "finish": "gunmetal"},
	},
	"stealth_prototype": {
		"name": "Stealth Prototype",
		"pattern_type": "gradient",
		"pattern_scale": 1.0,
		"pattern_angle": 0.0,
		"pattern_softness": 0.20,
		"weathering": 0.0,
		"accent_emissive": Color(1.000, 0.150, 0.220),
		"accent_emissive_strength": 2.2,
		"decal_icon": "blade",
		"decal_badge": "circle",
		"hull_upper": {"color": Color(0.180, 0.200, 0.220), "finish": "carbon_fibre"},
		"hull_lower": {"color": Color(0.033, 0.033, 0.039), "finish": "rubberised"},
		"hull_stripe": {"color": Color(0.440, 0.334, 0.343), "finish": "anodised"},
		"weapon_action": {"color": Color(0.150, 0.160, 0.180), "finish": "brushed_alloy"},
		"weapon_barrel": {"color": Color(0.080, 0.080, 0.090), "finish": "gunmetal"},
	},
}

# Zone order is the order the editor lists them in
const ZONES: Array = [
	{"id": "hull_upper",    "name": "Hull - Upper"},
	{"id": "hull_lower",    "name": "Hull - Lower"},
	{"id": "hull_stripe",   "name": "Pattern Accent"},
	{"id": "weapon_action", "name": "Weapon - Action"},
	{"id": "weapon_barrel", "name": "Weapon - Barrel"},
]

# The subset the Livery editor exposes as controls.
#
# weapon_action and weapon_barrel are omitted deliberately (2026-08-31). They
# no longer reach any geometry: part_materials.ZONE_BY_ROLE points the `action`
# role at hull_upper (a receiver bolted to a painted hull is painted with the
# hull), and the barrel roles have no zone at all so a barrel keeps its own
# gunmetal whatever the vehicle is painted. Two colour pickers that change
# nothing on screen are worse than no pickers.
#
# They stay in ZONES rather than being deleted, because ZONES is what to_json /
# from_json iterate: dropping them would silently discard those fields from
# every livery.json already on disk. Nothing reads them, they cost two dict
# entries, and keeping them means the weapon zones can be revived as explicit
# opt-in overrides without a save migration.
const EDITABLE_ZONES: Array = [
	{"id": "hull_upper",  "name": "Hull - Upper"},
	{"id": "hull_lower",  "name": "Hull - Lower"},
	{"id": "hull_stripe", "name": "Pattern Accent"},
]

const HUE_POOL: Array = [
	0.02, 0.06, 0.10, 0.13, 0.17, 0.28, 0.33, 0.45, 0.52, 0.58, 0.63, 0.72, 0.82, 0.92,
]

# The pool random_livery() may draw a BODY hue from, as opposed to HUE_POOL,
# which is the full wheel the Livery editor offers a player who wants a pink
# tank and is entitled to one. Restricted to the earth/olive/tan/steel-blue
# band a service vehicle is actually painted in, because a random draw off the
# full wheel is how an AI unit ended up magenta - see the note on
# RANDOM_SAT_BODY below.
const RANDOM_BODY_HUE_POOL: Array = [
	0.06, 0.09, 0.11, 0.13, 0.17, 0.22, 0.28, 0.33, 0.55, 0.58, 0.61,
]

# HSV bands random_livery() draws within. These were 0.35-0.75 saturation /
# 0.45-0.80 value for the body and 0.6-0.95 / 0.7-0.95 for the accent stripe,
# which is a fluorescent range: every AI unit in a skirmish arrived in a
# randomly-hued high-chroma two-tone, and the twelve hand-authored PRESETS
# below - the muted military palettes this game is supposed to look like -
# were never reached by a battle at all (see for_id).
#
# The numbers now describe paint: a low-chroma dark body, and an accent with
# just enough chroma to read as a deliberate marking at RTS camera distance
# without becoming the brightest thing on screen.
const RANDOM_SAT_BODY := Vector2(0.10, 0.30)
const RANDOM_VAL_BODY := Vector2(0.18, 0.42)
const RANDOM_SAT_ACCENT := Vector2(0.20, 0.45)
const RANDOM_VAL_ACCENT := Vector2(0.45, 0.70)
# Nothing rolls off the line factory-fresh. The old floor of 0.05 let a unit
# render as clean enamel, which is most of what makes a vehicle read as a
# render rather than a machine.
const RANDOM_WEATHERING := Vector2(0.25, 0.65)

# Finish was drawn from the whole FINISHES table, so a hull could roll
# "anodised" (metallic 0.82 / roughness 0.40 - a mirror) and a barrel could
# roll "fiberglass". Split by what the zone physically is.
const RANDOM_HULL_FINISHES: Array = [
	"matte_primer", "cerakote", "cast_iron", "weathered_enamel", "powdercoat", "phosphate",
]
const RANDOM_WEAPON_FINISHES: Array = [
	"gunmetal", "phosphate", "cast_iron", "brushed_steel", "hammered",
]

# Patterns a random livery may draw. The full PATTERNS table includes
# high-visibility markings ("hazard", "chequer", the racing stripes) that are
# right for a player who picks them and wrong as a coin flip on an AI unit.
const RANDOM_PATTERN_POOL: Array = [
	"none", "splinter_camo", "tiger_camo", "digital_camo", "stripe", "offset_stripe",
]


static func finish_ids() -> Array:
	return FINISHES.keys()

static func get_finish(finish_id: String) -> Dictionary:
	return FINISHES.get(finish_id, FINISHES["matte_primer"])

static func finish_name(finish_id: String) -> String:
	return get_finish(finish_id).get("name", finish_id)

static func finish_surface_type(finish_id: String) -> int:
	return int(get_finish(finish_id).get("surface_type", 0))

static func finish_roughness(finish_id: String) -> float:
	return maxf(SATIN_ROUGHNESS_FLOOR, float(get_finish(finish_id).get("roughness", 0.8)))

static func finish_metallic(finish_id: String) -> float:
	return clampf(float(get_finish(finish_id).get("metallic", 0.0)), 0.0, 1.0)

static func pattern_ids() -> Array:
	return PATTERNS.keys()

static func pattern_name(pattern_id: String) -> String:
	return PATTERNS.get(pattern_id, PATTERNS["stripe"]).get("name", pattern_id)

static func pattern_id_int(pattern_id: String) -> int:
	return int(PATTERNS.get(pattern_id, PATTERNS["stripe"]).get("id_int", 1))

# A complete livery: every zone gets a colour and a finish, plus pattern, weathering, and decal parameters.
static func random_livery(livery_seed: int = 0) -> Dictionary:
	var rng := RandomNumberGenerator.new()
	rng.seed = livery_seed if livery_seed != 0 else randi()

	var base_hue: float = RANDOM_BODY_HUE_POOL[rng.randi() % RANDOM_BODY_HUE_POOL.size()]
	var accent_hue: float = fmod(base_hue + rng.randf_range(0.35, 0.65), 1.0)
	var chosen_pattern: String = RANDOM_PATTERN_POOL[rng.randi() % RANDOM_PATTERN_POOL.size()]

	var out := {
		"building_mesh_set": DEFAULT_BUILDING_MESH_SET,
		"pattern": {
			"type": chosen_pattern,
			"scale": rng.randf_range(0.8, 1.6),
			"angle": rng.randf_range(-45.0, 45.0) if rng.randf() > 0.5 else 0.0,
			"softness": rng.randf_range(0.008, 0.025),
		},
		"weathering": rng.randf_range(RANDOM_WEATHERING.x, RANDOM_WEATHERING.y),
		# The lamp is the ONE place a random livery is allowed full chroma -
		# it covers a few percent of the surface. Reuses accent_hue so the
		# lights agree with what little accent paint there is.
		"accent_emissive": Color.from_hsv(accent_hue, 0.85, 1.0),
		"accent_emissive_strength": rng.randf_range(1.8, 2.6),
		"decal": {
			"icon": MASCOT_SHAPES[rng.randi() % MASCOT_SHAPES.size()],
			"badge": "circle" if rng.randf() > 0.3 else "none",
			"serial": str(100 + (rng.randi() % 900)),
			"show_hazard": rng.randf() > 0.3,
		}
	}
	for zone in ZONES:
		var zid: String = zone["id"]
		var hue := base_hue
		var sat := rng.randf_range(RANDOM_SAT_BODY.x, RANDOM_SAT_BODY.y)
		var val := rng.randf_range(RANDOM_VAL_BODY.x, RANDOM_VAL_BODY.y)
		var pool := RANDOM_HULL_FINISHES
		match zid:
			"hull_lower":
				# The belt line down is in the vehicle's own shadow and picks
				# up the ground; darker than the upper hull, not a second hue.
				val *= 0.65
			"hull_stripe":
				hue = accent_hue
				sat = rng.randf_range(RANDOM_SAT_ACCENT.x, RANDOM_SAT_ACCENT.y)
				val = rng.randf_range(RANDOM_VAL_ACCENT.x, RANDOM_VAL_ACCENT.y)
			"weapon_action":
				sat *= 0.5
				val *= 0.55
				pool = RANDOM_WEAPON_FINISHES
			"weapon_barrel":
				hue = accent_hue
				sat *= 0.35
				val *= 0.5
				pool = RANDOM_WEAPON_FINISHES
		out[zid] = {
			"color": Color.from_hsv(hue, clampf(sat, 0.0, 1.0), clampf(val, 0.05, 1.0)),
			"finish": pool[rng.randi() % pool.size()],
		}
	return out


# PRESETS are authored in a flat shape (pattern_type, decal_icon, ...); every
# runtime reader - the shader uniforms via hull_material_builder, to_json,
# livery_screen's controls - wants the nested shape random_livery() returns.
# This is the one conversion between them. livery_screen._apply_preset used to
# carry its own inline copy; it now calls this, so a preset reaching a battle
# and a preset reaching the editor cannot drift apart.
static func from_preset(preset_key: String, serial_seed: int = 0) -> Dictionary:
	var p: Dictionary = PRESETS.get(preset_key, {})
	if p.is_empty():
		return random_livery(serial_seed)
	var out := {
		"pattern": {
			"type": str(p.get("pattern_type", "stripe")),
			"scale": float(p.get("pattern_scale", 1.0)),
			"angle": float(p.get("pattern_angle", 0.0)),
			"softness": float(p.get("pattern_softness", 0.015)),
		},
		"weathering": float(p.get("weathering", 0.2)),
		"building_mesh_set": str(p.get("building_mesh_set", DEFAULT_BUILDING_MESH_SET)),
		"accent_emissive": p.get("accent_emissive", Color(1.0, 0.62, 0.18)),
		"accent_emissive_strength": float(p.get("accent_emissive_strength", 2.2)),
		"decal": {
			"icon": str(p.get("decal_icon", "gear")),
			"badge": str(p.get("decal_badge", "circle")),
			# Deterministic per caller so a faction's units carry a stable
			# hull number instead of every vehicle being 101.
			"serial": str(101 + (absi(serial_seed) % 899)),
			"show_hazard": bool(p.get("show_hazard", true)),
		},
	}
	for zone in ZONES:
		var zid: String = zone["id"]
		var z = p.get(zid, null)
		if typeof(z) == TYPE_DICTIONARY:
			out[zid] = (z as Dictionary).duplicate()
		else:
			out[zid] = {"color": Color(0.30, 0.31, 0.28), "finish": "matte_primer"}
	return out

static func default_livery() -> Dictionary:
	return random_livery()

# ---------------------------------------------------------------------------
# PERSISTENCE
# ---------------------------------------------------------------------------

static func to_json(livery: Dictionary) -> Dictionary:
	var out := {}
	for zone in ZONES:
		var zid: String = zone["id"]
		var z: Dictionary = livery.get(zid, {})
		var c: Color = z.get("color", Color(0.5, 0.5, 0.5))
		out[zid] = {"color": [c.r, c.g, c.b], "finish": str(z.get("finish", "matte_primer"))}
	
	# Extended properties
	var pat: Dictionary = livery.get("pattern", {})
	out["pattern"] = {
		"type": str(pat.get("type", "stripe")),
		"scale": float(pat.get("scale", 1.0)),
		"angle": float(pat.get("angle", 0.0)),
		"softness": float(pat.get("softness", 0.015)),
	}
	out["weathering"] = float(livery.get("weathering", 0.2))
	out["building_mesh_set"] = str(livery.get("building_mesh_set", DEFAULT_BUILDING_MESH_SET))
	var dec: Dictionary = livery.get("decal", {})
	out["decal"] = {
		"icon": str(dec.get("icon", "gear")),
		"badge": str(dec.get("badge", "circle")),
		"serial": str(dec.get("serial", "101")),
		"show_hazard": bool(dec.get("show_hazard", true)),
	}
	return out

static func from_json(data: Dictionary) -> Dictionary:
	var out := {}
	for zone in ZONES:
		var zid: String = zone["id"]
		var z = data.get(zid, null)
		if typeof(z) != TYPE_DICTIONARY:
			out[zid] = random_livery(hash(zid))[zid]
			continue
		var rgb = z.get("color", [0.5, 0.5, 0.5])
		var col := Color(0.5, 0.5, 0.5)
		if typeof(rgb) == TYPE_ARRAY and rgb.size() >= 3:
			col = Color(float(rgb[0]), float(rgb[1]), float(rgb[2]))
		var fin := str(z.get("finish", "matte_primer"))
		if not FINISHES.has(fin):
			fin = "matte_primer"
		out[zid] = {"color": col, "finish": fin}
	
	# Pattern
	var pat_data = data.get("pattern", {})
	var pat_type = "stripe"
	var pat_scale = 1.0
	var pat_angle = 0.0
	var pat_softness = 0.015
	if typeof(pat_data) == TYPE_DICTIONARY:
		pat_type = str(pat_data.get("type", "stripe"))
		if not PATTERNS.has(pat_type):
			pat_type = "stripe"
		pat_scale = float(pat_data.get("scale", 1.0))
		pat_angle = float(pat_data.get("angle", 0.0))
		pat_softness = float(pat_data.get("softness", 0.015))
	out["pattern"] = {
		"type": pat_type,
		"scale": pat_scale,
		"angle": pat_angle,
		"softness": pat_softness,
	}

	# Weathering
	out["weathering"] = clampf(float(data.get("weathering", 0.2)), 0.0, 1.0)
	out["building_mesh_set"] = str(data.get("building_mesh_set", DEFAULT_BUILDING_MESH_SET))

	# Decal
	var dec_data = data.get("decal", {})
	var dec_icon = "gear"
	var dec_badge = "circle"
	var dec_serial = "101"
	var dec_hazard = true
	if typeof(dec_data) == TYPE_DICTIONARY:
		dec_icon = str(dec_data.get("icon", "gear"))
		if not MASCOT_SHAPES.has(dec_icon):
			dec_icon = "gear"
		dec_badge = str(dec_data.get("badge", "circle"))
		dec_serial = str(dec_data.get("serial", "101"))
		dec_hazard = bool(dec_data.get("show_hazard", true))
	out["decal"] = {
		"icon": dec_icon,
		"badge": dec_badge,
		"serial": dec_serial,
		"show_hazard": dec_hazard,
	}

	return out

static func save_player(livery: Dictionary) -> void:
	var f := FileAccess.open(SAVE_PATH, FileAccess.WRITE)
	if f == null:
		push_error("Livery: could not write " + SAVE_PATH)
		return
	f.store_string(JSON.stringify(to_json(livery), "\t"))
	f.close()

static func load_player() -> Dictionary:
	if not FileAccess.file_exists(SAVE_PATH):
		return random_livery()
	var f := FileAccess.open(SAVE_PATH, FileAccess.READ)
	if f == null:
		return random_livery()
	var parsed = JSON.parse_string(f.get_as_text())
	f.close()
	if typeof(parsed) != TYPE_DICTIONARY:
		return random_livery()
	return from_json(parsed)

# ---------------------------------------------------------------------------
# RESOLUTION BY ID
# ---------------------------------------------------------------------------
# AI LIVERY IDS.
#
# The ten premade factions are gone (faction_catalog.gd deleted 2026-08-31);
# what a side "is" visually is now just a livery id handed to for_id(). An id
# that matches no preset resolves through random_livery(hash(id)) inside the
# muted bands at the top of this file, so an arbitrary unique string IS a
# complete, plausible, deterministic paint scheme - which is all an AI opponent
# needs.
#
# Two flavours, because the two modes want different lifetimes:
#
#   new_ai_livery_id()      - fresh every call. A skirmish opponent should not
#                             wear the same colours it wore last match.
#   ai_livery_id_for(key)   - stable for a given key. An operations campaign
#                             passes its operation_id, so the enemy keeps one
#                             identity across every stage of that campaign
#                             instead of repainting between engagements.
#
# Deliberately NOT routed through sim_rng.gd. Livery is cosmetic and touches no
# simulation state, so it must not consume from the deterministic sim stream -
# doing so would make a replay's outcome depend on what colour the enemy rolled.
const AI_ID_PREFIX := "ai_"

static func new_ai_livery_id() -> String:
	return "%s%d" % [AI_ID_PREFIX, randi()]


static func ai_livery_id_for(key: String) -> String:
	if key.is_empty():
		return new_ai_livery_id()
	return "%s%d" % [AI_ID_PREFIX, abs(hash(key))]


const PLAYER_ID := "player"
const NO_LIVERY := ""

static var _cache: Dictionary = {}

# RESOLUTION ORDER. This used to be "player id -> the saved livery, anything
# else -> random_livery(hash(id))", and since armor_paint_visual.gd passes a
# blueprint's `faction` string in here, "anything else" was every unit in
# every battle. The twelve curated PRESETS were unreachable from a match.
#
# Ordered most-specific-first so a caller can pass a preset key directly
# (useful for authored rosters) and anything else falls through to the muted
# random path.
static func for_id(livery_id: String) -> Dictionary:
	if _cache.has(livery_id):
		return _cache[livery_id]
	var l: Dictionary
	if livery_id == PLAYER_ID:
		l = load_player()
	elif PRESETS.has(livery_id):
		l = from_preset(livery_id, hash(livery_id))
	else:
		# Any other id - an AI livery id, a hand-written or modded string.
		# Random, but inside the muted bands at the top of this file rather than
		# anywhere on the hue wheel, so an arbitrary id still produces a
		# plausible service paint scheme.
		l = random_livery(hash(livery_id))
	_cache[livery_id] = l
	return l

static func invalidate(livery_id: String = PLAYER_ID) -> void:
	_cache.erase(livery_id)

# ACCENT LAMP. The saturated faction hue, which used to be applied as paint
# over whole objects. See accent_emissive_color in
# shaders/hull_faction_material.gdshader for why it moved here.
#
# Falls back to a dim amber rather than to black, so a hand-written livery that
# does not declare one still gets marker lights instead of a dead hull.
static func accent_emissive_color(livery_id: String) -> Color:
	return for_id(livery_id).get("accent_emissive", Color(1.0, 0.62, 0.18))


static func accent_emissive_strength(livery_id: String) -> float:
	return float(for_id(livery_id).get("accent_emissive_strength", 2.0))


static func zone_color(livery_id: String, zone_id: String) -> Color:
	var z: Dictionary = for_id(livery_id).get(zone_id, {})
	return z.get("color", Color(0.5, 0.5, 0.55))

static func zone_finish(livery_id: String, zone_id: String) -> String:
	var z: Dictionary = for_id(livery_id).get(zone_id, {})
	return str(z.get("finish", "matte_primer"))

static func pattern_type(livery_id: String) -> String:
	var p: Dictionary = for_id(livery_id).get("pattern", {})
	return str(p.get("type", "stripe"))

static func pattern_type_int(livery_id: String) -> int:
	return pattern_id_int(pattern_type(livery_id))

static func pattern_scale(livery_id: String) -> float:
	var p: Dictionary = for_id(livery_id).get("pattern", {})
	return float(p.get("scale", 1.0))

static func pattern_angle(livery_id: String) -> float:
	var p: Dictionary = for_id(livery_id).get("pattern", {})
	return float(p.get("angle", 0.0))

static func pattern_softness(livery_id: String) -> float:
	var p: Dictionary = for_id(livery_id).get("pattern", {})
	return float(p.get("softness", 0.015))

static func weathering(livery_id: String) -> float:
	return float(for_id(livery_id).get("weathering", 0.2))

static func decal_icon(livery_id: String) -> String:
	var d: Dictionary = for_id(livery_id).get("decal", {})
	return str(d.get("icon", "gear"))

static func decal_badge(livery_id: String) -> String:
	var d: Dictionary = for_id(livery_id).get("decal", {})
	return str(d.get("badge", "circle"))

static func decal_serial(livery_id: String) -> String:
	var d: Dictionary = for_id(livery_id).get("decal", {})
	return str(d.get("serial", "101"))

static func decal_show_hazard(livery_id: String) -> bool:
	var d: Dictionary = for_id(livery_id).get("decal", {})
	return bool(d.get("show_hazard", true))

static func building_mesh_set(livery_id: String) -> String:
	return str(for_id(livery_id).get("building_mesh_set", DEFAULT_BUILDING_MESH_SET))
