extends RefCounted
class_name PartMaterials
# Material ROLES for bolt-on module parts (weapons, locomotion, utility).
#
# THE PROBLEM THIS SOLVES
# ---------------------------------------------------------------------------
# Every authored weapon part in this project reached the screen through
# visual_builder's _mesh_inst(), which built a StandardMaterial3D and set
# exactly one property on it: albedo_color. Everything else stayed at Godot's
# defaults, which are metallic 0.0 and roughness 1.0 - the PBR description of
# matte plastic. So a gun barrel, an ammo drum, a hydraulic ram, a lens and a
# rubber tyre all had identical surface response and differed only in how dark
# their paint was. The geometry was detailed; the surfaces were vinyl. That is
# why the weapons read as flat next to the hulls, which have had a real shader
# with faction texture, wear and grime on them for months
# (hull_material_builder.gd).
#
# The fix is NOT one better material - it is having more than one KIND of
# material, which is the "different materials on different parts" half of the
# question, and giving each of them real surface texture, which is the "better
# textures" half. Both, because they're solving different problems: roles make
# a barrel read as a different substance from the receiver it's bolted into,
# and texture stops any single substance from reading as a flat vinyl decal.
#
# WHY PROCEDURAL TEXTURE RATHER THAN AUTHORED MAPS
# ---------------------------------------------------------------------------
# The authored part .glbs are built in bmesh from primitives (see
# tools/blender/build_*.py) and have no meaningful UV layout - nothing ever
# unwrapped them, and hand-unwrapping ~190 procedurally-generated parts is not
# a realistic ask. Triplanar projection needs no UVs at all: it samples the
# texture along world/local axes and blends by surface normal. Combined with a
# runtime-generated FastNoiseLite that costs nothing on disk and nothing in the
# repo, every part gets micro-roughness variation and paint mottling for free,
# at any scale, including on parts stretched by a tweak slider.
#
# SHARING IS LOAD-BEARING
# ---------------------------------------------------------------------------
# Materials are cached and SHARED between every part that asks for the same
# role and tint. That is not just an allocation micro-optimisation:
# visual_builder.bake_module_visual() merges a battle module's meshes grouped
# by material IDENTITY, so a fresh-but-identical material per part would
# silently defeat the merge and ship one draw call per bolt.
#
# Because they're shared, NOTHING MAY MUTATE A RETURNED MATERIAL IN PLACE -
# the same rule munition_pool.gd's shared meshes/materials carry, and for the
# same reason. Need a variant? Add a role, or pass a different tint.

# --- Role table -------------------------------------------------------------
# metallic/roughness chosen against hull_material_builder.gd's hard-won notes:
# high metallic crushes diffuse response (a near-pure-metal surface is black
# except where a highlight lands), so even the "bare metal" roles keep enough
# diffuse to read from any angle, and nothing goes glossy enough to produce
# the blown-out specular streak that file documents.
#
# `tint` is how much of the caller's requested colour survives. A painted
# housing is whatever colour the faction painted it (1.0). A gun barrel is
# gunmetal regardless of what colour the rest of the weapon is (0.15) - which
# is exactly the per-part differentiation the flat-albedo path couldn't
# express, since there the colour WAS the material.
const ROLES := {
	# Default. Fabricated steel structure: mounts, cradles, frames.
	"steel": {"metallic": 0.55, "roughness": 0.52, "tint": 0.85, "base": Color(0.30, 0.31, 0.33), "wear": 0.55},

	# Painted sheet: housings, covers, ammo boxes. Holds its colour, and
	# takes the most paint mottling of anything here.
	"painted": {"metallic": 0.25, "roughness": 0.62, "tint": 1.0, "base": Color(0.35, 0.35, 0.35), "wear": 0.85},

	# Bolt-on armor plates (slat, spaced composite, ablative, energy
	# barrier). Treated as a SKIN of the hull rather than as a separate
	# substance: a player's chosen hull livery has to read across the
	# armor or the unit looks like two different vehicles zippered
	# together. tint_weight and zone_tint are both high (0.95 / 1.0) so
	# the livery dominates the surface and only the role's base grey
	# bleeds through in the deepest shadow. Wear is higher than steel's
	# because armor takes hits - the eye expects a plate to look
	# slightly more lived-in than the frame it bolts onto.
	"armor": {"metallic": 0.45, "roughness": 0.58, "tint": 0.95, "zone_tint": 1.0, "base": Color(0.35, 0.35, 0.35), "wear": 0.70},

	# Barrels, rails, tubes, bores. Dark, hard, and almost colour-immune to an
	# INCIDENTAL tint - a barrel is gunmetal on a red gun and on a green gun
	# alike, which is what `tint` 0.15 protects.
	#
	# `zone_tint` is the separate, much higher weight used when the player's
	# own livery is driving this role (see ZONE_BY_ROLE). The two cases are
	# genuinely different: a catalog colour bleeding onto a barrel is noise and
	# should be resisted, whereas a colour the player deliberately chose for
	# the barrel zone has to actually appear. Collapsing them into one number
	# meant a red WEAPON turned its own barrel red even with no livery active.
	"gunmetal": {"metallic": 0.80, "roughness": 0.34, "tint": 0.15, "zone_tint": 0.78, "base": Color(0.13, 0.135, 0.145), "wear": 0.30},

	# Receivers, breeches, bolts - the ACTION, as distinct from the barrel.
	# Split out of gunmetal (identical PBR, so nothing changed visually on its
	# own) purely so the two halves of a weapon can be separate livery zones,
	# which is what Chris's "two zones per weapon, action and barrel" needs.
	# ROLE_HINTS already told them apart by part name; they just both landed
	# on gunmetal before.
	"action": {"metallic": 0.80, "roughness": 0.34, "tint": 0.15, "zone_tint": 0.78, "base": Color(0.13, 0.135, 0.145), "wear": 0.30},

	# The last few inches of a barrel and any muzzle device: heat-scorched,
	# rougher and browner than the tube behind it. Reads as "this end is the
	# business end" without needing an emissive cheat.
	"scorched": {"metallic": 0.62, "roughness": 0.72, "tint": 0.10, "base": Color(0.115, 0.10, 0.095), "wear": 0.95},

	# Brass/bronze fittings, shell cases, feed lips. The one warm note - used
	# sparingly, it is what stops a weapon reading as monochrome.
	# Toned down from a brighter, glossier starting point after a real render:
	# at metallic 0.90 / roughness 0.30 an ammo drum came out as polished
	# trumpet brass and pulled the eye straight off the gun. Aged bronze reads
	# as the same material and stays subordinate, which is the job - this is
	# an accent, and an accent that wins is a mistake.
	"brass": {"metallic": 0.82, "roughness": 0.44, "tint": 0.10, "base": Color(0.46, 0.35, 0.17), "wear": 0.55},

	# Optics, vision blocks, sensor faces. Smooth, barely metallic, dark, and
	# with a strong specular so it catches the light like glass should.
	"optics": {"metallic": 0.15, "roughness": 0.08, "tint": 0.30, "base": Color(0.06, 0.10, 0.13), "wear": 0.0},

	# Tyres, track pads, hose, seals, mantlet boots. Matte, non-metal, and
	# the single most obvious thing that was wrong when everything shared one
	# material - rubber and steel are not the same substance.
	"rubber": {"metallic": 0.0, "roughness": 0.92, "tint": 0.25, "base": Color(0.075, 0.075, 0.08), "wear": 0.35},

	# Ceramic insulators, radomes, coil formers. Non-metal, pale, dry.
	"ceramic": {"metallic": 0.0, "roughness": 0.45, "tint": 0.55, "base": Color(0.72, 0.70, 0.66), "wear": 0.25},

	# Energy-weapon internals: coils, capacitors, emitters. Caller supplies
	# the glow via the emission arguments; this just keeps the substrate dark
	# so the emission has something to read against.
	"energized": {"metallic": 0.45, "roughness": 0.30, "tint": 0.60, "base": Color(0.14, 0.15, 0.18), "wear": 0.20},

	# Gravitic and field hardware: hover rings, anti-grav emitter plates.
	# Chris: they "should both look like they're made out of real materials if
	# inexplicable in what and how." So: a real substance, just not one we
	# have - a dark near-black alloy polished to almost a mirror, which is
	# what sells "exotic" rather than emissive glow does. Nearly colour-immune
	# for the same reason gunmetal is: the substance should not change when
	# the team paint does. It is the polish that makes it read as engineered
	# and the darkness that stops it competing with the field glow on top.
	"exotic": {"metallic": 0.95, "roughness": 0.11, "tint": 0.18, "base": Color(0.085, 0.095, 0.115), "wear": 0.10},

	# The working face of that hardware - emitter windows, ring cores. Glassy
	# and non-metallic so the caller's emission reads as light coming FROM
	# somewhere rather than paint that happens to be bright.
	"fieldglass": {"metallic": 0.10, "roughness": 0.05, "tint": 0.45, "base": Color(0.05, 0.08, 0.11), "wear": 0.0},

	# Carbon composite: moulded limb shells, wrapped spars. Non-metallic and
	# dark like rubber, but SEMI-GLOSS rather than matte - that difference is
	# the whole read. Routed through "rubber" it looked like a tyre, and
	# through "gunmetal" like polished steel; a composite thigh is neither.
	"composite": {"metallic": 0.0, "roughness": 0.38, "tint": 0.20, "base": Color(0.085, 0.085, 0.095), "wear": 0.25},

	# Machinery-yellow plant paint. Deliberately near colour-IMMUNE (tint
	# 0.15, like gunmetal) rather than a "painted" variant: hazard yellow is
	# a safety convention, not a livery choice, so it should read the same on
	# every faction. A faction-tinted hazard stripe is not a hazard stripe.
	"hazard": {"metallic": 0.20, "roughness": 0.58, "tint": 0.15, "base": Color(0.72, 0.56, 0.09), "wear": 0.90},

	# The same argument in red - warning panels, pinch-point markings, the
	# painted parts of a limb you are meant to stay clear of.
	"warning": {"metallic": 0.20, "roughness": 0.58, "tint": 0.15, "base": Color(0.55, 0.13, 0.11), "wear": 0.90},

	# Module accent: mount brackets, casings, housings that carry the
	# player's livery accent colour (hull_stripe zone) while the rest of
	# the module keeps its catalog colour.  Metallic painted finish so it
	# reads as factory-applied paint on structural steel.
	"accent": {"metallic": 0.45, "roughness": 0.50, "tint": 1.0, "zone_tint": 0.92, "base": Color(0.32, 0.33, 0.35), "wear": 0.60},
}

const DEFAULT_ROLE := "steel"

# --- Livery zones -----------------------------------------------------------
# Modules keep their catalog colour for body, barrel, action, and substance
# parts.  Only two roles are zoned:
#   "accent"  -> hull_stripe  (mount brackets, casings, housings — the
#                              player's livery accent appears here)
#   "armor"   -> hull_upper   (bolt-on armor plates match the hull skin)
#
# Everything else (gunmetal, action, steel, painted, brass, rubber, optics,
# etc.) is a SUBSTANCE role that keeps its authored colour regardless of
# livery.  This is what keeps modules from reading as solid plastic toys:
# a barrel is always gunmetal, a tyre is always black, and only the accent
# bracket carries the player's team colour.
const ZONE_BY_ROLE := {
	"accent": "hull_stripe",
	# Bolt-on armor plates read as the hull's outer skin, so they take
	# the upper hull's livery colour.  hull_upper rather than hull_lower
	# because at RTS zoom what the player sees is the upper silhouette;
	# the lower zone is mostly the track skirt / running gear, which the
	# armor plates don't cover.
	"armor": "hull_upper",
}

const LiveryScript = preload("res://scripts/livery.gd")

# The livery currently being painted, as a RENDER CONTEXT rather than an
# argument.
#
# Threading a livery id down to every material call would mean adding a
# parameter to visual_builder.build_visual() and to all ~100 of its internal
# _mesh_inst() calls, which is a large, error-prone edit for something that is
# genuinely ambient state: one unit is built at a time, start to finish, and
# every part of it wears the same livery.
#
# The contract that makes this safe is that a build is SYNCHRONOUS -
# blueprint_manager.reconstruct_vehicle() sets this, builds, and clears it
# within one call, with no await in between - so two units can never be
# interleaved. Left empty (the default) nothing is zoned and every role keeps
# its authored colour, which is what the Design Lab's unpainted scale-model
# view wants.
static var _livery_id: String = ""

static func set_livery(livery_id: String) -> void:
	_livery_id = livery_id

static func clear_livery() -> void:
	_livery_id = ""

# --- Name-driven role hints -------------------------------------------------
# Mapped off the authored part FILENAME, checked as substrings in this order
# (first match wins, so the more specific entries come first). This is what
# makes the roles apply across ~190 existing parts without editing 190 call
# sites: the parts are already named after what they are, so the name is
# already the classification. A part that matches nothing gets DEFAULT_ROLE,
# which is a strict improvement on the flat-plastic it had before, so an
# unmatched or modded part degrades to "fine" rather than to "broken".
const ROLE_HINTS := [
	# Gravitic hardware first: these part names also contain "plate" and
	# "ring", which would otherwise fall through to steel.
	# All of it is the ALLOY, not the glass. Routing the rings to fieldglass
	# plus the emission the builders already pass rendered them as flat neon
	# hoops with no material read at all - the opposite of Chris's "real
	# materials if inexplicable". The polish is what sells it; the glow is a
	# trim, not the substance.
	["agp_", "exotic"],
	["hover_ring", "exotic"],
	["grav", "exotic"],
	["muzzle", "scorched"],
	["venturi", "scorched"],
	["nozzle", "scorched"],
	["exhaust", "scorched"],
	# Armor plates: classified before the generic "plate" / "composite"
	# substrings below, which would otherwise misroute them. The
	# substring is the type_id from module_catalog.gd, NOT the rendered
	# .glb filename - visual_builder hands the catalog id through
	# role_for_part().
	["slat_armor", "armor"],
	["spaced_composite", "armor"],
	["ablative_foam", "armor"],
	["armor_plating", "armor"],
	["energy_barrier", "armor"],
	["lens", "optics"],
	["radar", "optics"],
	["dish", "optics"],
	["periscope", "optics"],
	["vision", "optics"],
	["sensor_dome", "optics"],
	["headlight", "optics"],
	["tread_belt", "rubber"],
	["tread_plate", "rubber"],
	["tyre", "rubber"],
	["wheel_hub", "rubber"],
	["skirt", "rubber"],
	["membrane", "rubber"],
	["toroid", "ceramic"],
	["insulator", "ceramic"],
	["coil", "energized"],
	["capacitor", "energized"],
	["busbar", "brass"],
	["radiator", "steel"],
	["pipes", "brass"],
	["rotor", "steel"],
	["tray", "painted"],
	["rail_array", "energized"],
	["railgun_rails", "energized"],
	["emitter", "energized"],
	# Barrel-zone parts (the tube itself) vs action-zone parts (the mechanism
	# behind it). Both were "gunmetal" before; splitting them is what lets the
	# player colour a weapon's two halves separately - see ZONE_BY_ROLE.
	["barrel", "gunmetal"],
	["rail", "gunmetal"],
	["tube", "gunmetal"],
	["bore", "gunmetal"],
	["receiver", "action"],
	["breech", "action"],
	["action", "action"],
	["bolt", "action"],
	# More specific than the generic "ammo" -> brass below, and checked
	# first. A belt-fed can with exposed links reads as brass; a sealed
	# linkless drum magazine is a painted steel housing, and rendering it in
	# bright brass made it the brightest object on the weapon.
	["autocannon_ammo", "painted"],
	["linkless", "painted"],
	["ammo", "brass"],
	["drum", "brass"],
	["belt", "brass"],
	["canister", "painted"],
	["housing", "painted"],
	["cover", "painted"],
	["box", "painted"],
	["tank", "painted"],
	["pod", "painted"],
	["mount", "steel"],
	["pintle", "steel"],
	["cradle", "steel"],
	["frame", "steel"],
	["strut", "steel"],
]

static func role_for_part(part_name: String) -> String:
	var lower := part_name.to_lower()
	for hint in ROLE_HINTS:
		if lower.contains(hint[0]):
			return hint[1]
	return DEFAULT_ROLE


# Role for a material AUTHORED INTO a .glb, by its name in the source file.
#
# ROLE_HINTS above answers "what is this part made of" from the part's own
# filename, which is all a single-material part needs. A multi-surface authored
# asset carries the answer per surface instead: the six leg sets name their
# materials Gunmetal / DarkSteel / BrightAlloy / CarbonBlack / IndustrialYellow
# / WarningRed, and a leg is genuinely several substances at once - a composite
# thigh on a steel gearbox with a painted warning panel.
#
# Mapping them onto roles rather than keeping the authored materials verbatim is
# what keeps faction tint and the battle-side mesh merge working: every surface
# still resolves to one of the shared, cached role materials.
#
# An unlisted name falls through to the part-name hint, then to DEFAULT_ROLE -
# so a re-export that renames or adds a material degrades to plain steel instead
# of failing to build the limb.
const AUTHORED_MATERIAL_ROLES := {
	"Gunmetal": "gunmetal",
	"DarkSteel": "gunmetal",
	"BrightAlloy": "steel",
	"CarbonBlack": "composite",
	"IndustrialYellow": "hazard",
	"WarningRed": "warning",
}

static func role_for_authored_material(material_name: String, fallback_part: String = "") -> String:
	if AUTHORED_MATERIAL_ROLES.has(material_name):
		return AUTHORED_MATERIAL_ROLES[material_name]
	if fallback_part != "":
		return role_for_part(fallback_part)
	return DEFAULT_ROLE

# --- Shared procedural surface texture --------------------------------------
# Two frequencies, because they do different jobs. The fine one breaks up
# specular so a flat face stops reading as a decal; the coarse one mottles
# albedo so paint reads as sprayed onto metal rather than as a solid fill.
static var _fine_noise: NoiseTexture2D = null
static var _coarse_noise: NoiseTexture2D = null

static func _make_noise(frequency: float, seed_value: int, size: int) -> NoiseTexture2D:
	var noise := FastNoiseLite.new()
	noise.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	noise.frequency = frequency
	noise.seed = seed_value
	noise.fractal_octaves = 3
	var tex := NoiseTexture2D.new()
	tex.noise = noise
	tex.width = size
	tex.height = size
	# Seamless, because triplanar tiles it across an arbitrary number of world
	# units and a visible repeat seam on a stretched barrel would be worse
	# than no texture at all.
	tex.seamless = true
	return tex

static func fine_noise() -> NoiseTexture2D:
	if _fine_noise == null:
		_fine_noise = _make_noise(0.045, 1337, 256)
	return _fine_noise

static func coarse_noise() -> NoiseTexture2D:
	if _coarse_noise == null:
		_coarse_noise = _make_noise(0.010, 90210, 256)
	return _coarse_noise

# --- Material cache ---------------------------------------------------------
# Keyed on role + quantised tint + emission, so parts that look the same
# genuinely SHARE one material resource (see the note at the top about
# bake_module_visual grouping by material identity). Tint is quantised to
# 1/32 because callers pass colours derived from arithmetic
# (base_color.darkened(0.25) and friends) and floating-point-exact keys would
# make the cache almost never hit.
static var _cache: Dictionary = {}

static func _quantise(c: Color) -> String:
	return "%d_%d_%d" % [int(c.r * 32.0), int(c.g * 32.0), int(c.b * 32.0)]

static func get_material(role: String, tint: Color, emission: Color = Color(0, 0, 0, 0),
						 emission_energy: float = 0.0) -> StandardMaterial3D:
	var spec: Dictionary = ROLES.get(role, ROLES[DEFAULT_ROLE])
	# LIVERY OVERRIDE. When a livery is being painted and this role belongs to
	# one of its zones, the player's chosen colour REPLACES the caller's tint
	# and the chosen finish replaces the role's metallic/roughness. The role
	# still contributes its base colour and tint weight, so a barrel in a pale
	# livery is a pale gunmetal rather than pale paint - the substance survives
	# the paint job.
	var zone: String = ZONE_BY_ROLE.get(role, "") if _livery_id != "" else ""
	var effective_tint := tint
	var tint_weight: float = float(spec["tint"])
	var metallic: float = spec["metallic"]
	var roughness: float = spec["roughness"]
	if zone != "":
		effective_tint = LiveryScript.zone_color(_livery_id, zone)
		# A role may declare a higher tint weight for the livery case than for
		# an incidental caller tint - see gunmetal's note.
		tint_weight = float(spec.get("zone_tint", spec["tint"]))
		var finish := LiveryScript.zone_finish(_livery_id, zone)
		metallic = LiveryScript.finish_metallic(finish)
		# finish_roughness() is the satin-capped read - never the raw table
		# value - so a player-chosen finish can't reintroduce the near-mirror
		# specular that hull_material_builder.gd's ARMOR_PBR note records.
		roughness = LiveryScript.finish_roughness(finish)

	# Cache key carries the zone AND the livery id: two liveries paint the same
	# role differently, and without this the first one built would be handed
	# out to every subsequent unit on the map.
	var key := "%s|%s|%s|%.2f|%s|%s" % [role, _quantise(effective_tint), _quantise(emission),
		emission_energy, zone, _livery_id if zone != "" else ""]
	if _cache.has(key):
		return _cache[key]

	var mat := StandardMaterial3D.new()
	# The role's own base colour blended toward whatever the caller asked for,
	# by the role's tint weight. This is the mechanism that lets a barrel stay
	# gunmetal on a weapon whose catalog colour is bright red, while the
	# weapon's painted housing takes that red in full.
	mat.albedo_color = Color(spec["base"]).lerp(effective_tint, tint_weight)
	mat.metallic = metallic
	mat.roughness = roughness

	# CULL_DISABLED preserved from the _mesh_inst() this replaces. Several
	# authored parts are single-sided shells (wing membranes, skirts, the
	# hemisphere caps) and backface culling makes them vanish from one side.
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED

	var wear := float(spec["wear"])
	if wear > 0.0:
		# Roughness texture, triplanar - no UVs required, which is the whole
		# reason this works on procedurally-built meshes.
		mat.roughness_texture = fine_noise()
		mat.roughness_texture_channel = BaseMaterial3D.TEXTURE_CHANNEL_RED
		mat.uv1_triplanar = true
		# Scale set in world-ish units so the grain stays the same physical
		# size on a small bolt and on a stretched girder, instead of the
		# texture stretching with the part.
		mat.uv1_scale = Vector3(2.2, 2.2, 2.2)
		mat.uv1_triplanar_sharpness = 1.0

		# Coarse mottling on albedo via the detail layer, which has its own
		# independent UV channel - so the paint blotching runs at a different
		# frequency to the micro-roughness and the two don't beat against
		# each other into a visible plaid.
		mat.detail_enabled = true
		mat.detail_blend_mode = BaseMaterial3D.BLEND_MODE_MUL
		mat.detail_uv_layer = BaseMaterial3D.DETAIL_UV_2
		mat.detail_albedo = coarse_noise()
		mat.uv2_triplanar = true
		mat.uv2_scale = Vector3(0.55, 0.55, 0.55)

	if emission_energy > 0.0:
		mat.emission_enabled = true
		mat.emission = emission
		mat.emission_energy_multiplier = emission_energy

	_cache[key] = mat
	return mat

