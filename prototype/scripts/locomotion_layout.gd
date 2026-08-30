extends RefCounted
class_name LocomotionLayout
# Where each locomotion type's instances go on a hull, expressed as data.
#
# This replaces the ~540-line `if type_id == "wheels": ... elif ...` chain that
# used to live inside module_placer.gd's update_locomotion(). Every branch of
# that chain did the same six things - read tweaks, compute a mount pattern,
# build a geo_tweaks dict, place, reset the node's transform, mirror - and only
# the second of those was ever genuinely per-type. The other five were
# copy-pasted ten times, so a fix to one (or a new type that forgot one) drifted
# silently.
#
# Here, a locomotion type is a LAYOUTS entry: which of six mount PATTERNS it
# uses, the offsets that pattern needs, and which tweak keys it forwards to its
# mesh builder. Adding a locomotion type is a data declaration; module_placer.gd
# is not touched. The six patterns cover all ten shipped types and all seven
# planned in LOCOMOTION_EXPANSION_PLAN.md 4.
#
# stations() returns Array[Dictionary], each a MOUNT STATION:
#   position   - hull-LOCAL offset, before _place_weapon()'s 0.25m grid snap
#   normal     - surface normal handed to _place_weapon() (also decides which
#                axes that snap applies to, so it is layout-significant, not
#                cosmetic)
#   geo        - the tweaks dict for this instance's mesh builder
#   side       - -1.0 / +1.0 for paired patterns, 0.0 for radial ones
#   mirror     - whether this instance gets _apply_mirror_flip()
#   final_position / has_final_position - see OVERRIDE below
#   meta       - extra per-instance metadata (legs' walk-cycle phase)
#
# OVERRIDE: wheels and legs assign node.position directly after placement,
# which deliberately bypasses the grid snap _place_weapon() would otherwise
# apply. That is load-bearing (a snapped wheel row visibly steps in and out),
# so it is preserved as an explicit per-type flag rather than quietly
# normalised away.

const ModuleCatalog = preload("res://scripts/module_catalog.gd")

enum Pattern {
	SIDE_PAIRS,   ## N stations per side, spread along Z. Wheels, legs, treads, rotors, wings.
	RING_XZ,      ## N stations round a plan-view ellipse. Hover pads, skirts, grav plates.
	RING_XY,      ## N stations round a nose-on ellipse. Engine clusters.
	STERN_ROW,    ## N stations in a row aft of the hull. Props, water jets.
	CORNER_SPAN,  ## One span per side, anchored fore and aft. Screw drums, hydrofoils.
	ROOF_PAIRS,   ## N stations per side, above the hull. Reserved; rotors use SIDE_PAIRS
	              ## with a positive Y offset, which is the same thing.
	SIDE_PODS,    ## Pods per side along Z, with an odd one under the belly.
	              ## The count progression Chris specified for the envelope
	              ## drive: 1-2 one per side, 3 adds a belly pod, 4 is two per
	              ## side, and so on to 6.
	FOOTPRINT,    ## ONE station under the hull's centre, handed the hull's plan
	              ## dimensions. For gear that is a single continuous thing
	              ## wrapping the whole vehicle rather than a row of units.
}

## How a placed instance's node.scale is decided.
##
## HULL_RELATIVE is the default. The locomotor is treated as a self-contained
## system "tuned for the unit" (Chris, 2026-08-16): when a player drops a hull
## into the Lab, the running gear grows or shrinks to fit it. The factor is
## the CUBE ROOT OF THE HULL'S VOLUME, applied uniformly to all three axes -
## so a 2x bigger hull in every dimension makes the wheel 2x bigger, and a
## 2x bigger hull in just one dimension makes the wheel ~1.26x bigger
## (proportional, not stretched to match the hull's aspect ratio). The
## previous (footprint, height, footprint) split made tall+narrow hulls
## grow egg-shaped wheels (Chris, 2026-08-16), so the factor is now
## uniform. The visual is the only thing that scales - the catalog's own
## part weight follows it, and the chassis/loco mass is the "free baseline"
## excluded from the locomotor's load and speed math (see
## Drivetrain.analyze(), `carried_weight`).
##
## FIXED opts out. `legs` opts out because a taller hull on legs gives
## proportionally taller legs, which raises the body, which is the
## giant-spider-legs problem (Chris, 2026-08-02). `ornithopter_wing` opts out
## with a deliberate `node_scale = (2, 1, 2)` because "impractically long
## wings" is the archetype and a hull-relative scale would compound it.
##
## HULL_HEIGHT is the older "Y only" mode. None of the shipped types use it
## (HULL_RELATIVE replaces it), but the enum is kept because external callers
## could still reference it by name.
enum ScaleMode {
	FIXED,          ## Use the layout's `node_scale` verbatim, no hull-relative scale.
	HULL_HEIGHT,    ## Vector3(1, hull_height_factor, 1) - Y only, kept for compat.
	HULL_RELATIVE,  ## Vector3(s, s, s) where s = cbrt(h * fp * fp) - cube root of volume, uniform.
}

## Which spelling of the reach vector this type's mesh builder expects. The
## concept is one thing - "from my own origin back to the hull's centre" - but
## it shipped in four spellings across six types; they are enumerated here
## rather than unified, because unifying them means editing visual_builder.gd's
## builders, which this pass deliberately does not touch.
enum ReachKeys {
	NONE,
	XYZ,        ## mount_reach_x / _y / _z
	SIDE_XY,    ## mount_side + mount_reach_x / _y (helicopter_rotors)
	FORE_AFT,   ## mount_reach_fore_* and mount_reach_aft_* (screw_drive)
}

# --- The table ---------------------------------------------------------
#
# Keys, all optional unless noted:
#   pattern         (required) Pattern enum
#   count_key       tweak that sets instance count; absent = fixed count
#   count_fallback  legacy settings key checked before the default
#   count_default   default when neither key is present
#   count_min/max   clamp applied to the count
#   count_even      round odd counts up (paired patterns need an even total)
#   per_side        stations per side for SIDE_PAIRS when count_key is absent
#   normal          surface normal, or LEFT/RIGHT per side when `normal_is_side`
#   geo_keys        tweak names forwarded to the mesh builder, with defaults
#   reach_keys      ReachKeys enum, default NONE
#   node_scale      Vector3 assigned to the placed node, default ONE
#   scale_mode      ScaleMode enum, default FIXED
#   mirror          mirror-flip instances on the -X side, default false
#   override_pos    assign node.position directly, bypassing the grid snap
const LAYOUTS := {
	"wheels": {
		"pattern": Pattern.SIDE_PAIRS,
		"count_key": "num_axles", "count_fallback": "count", "count_default": 4,
		"count_min": 2, "count_even": true,
		"geo_keys": {"wheel_size": 1.0, "wheels_per_axle": 1.0},
		"geo_aliases": {"wheel_size": ["size"]},
		"normal": Vector3.UP,
		"mirror": true, "override_pos": true,
		# Default HULL_RELATIVE - a 2x bigger hull gets 2x bigger wheels. The
		# wheel_size tweak is then a DELTA on top of the hull-relative baseline.
		"scale_mode": ScaleMode.HULL_RELATIVE,
	},
	"tracked_treads": {
		"pattern": Pattern.SIDE_PAIRS, "per_side": 1,
		"geo_keys": {"tread_width": 1.0, "drive_sprocket": true},
		"geo_aliases": {"tread_width": ["width", "size"]},
		# The belt snaps its whole loop to the hull's real length rather than
		# its own (small, placeholder) catalog size.z.
		"hull_length_geo_key": "target_length",
		"normal_is_side": true,
		"mirror": true,
		"scale_mode": ScaleMode.FIXED,
		"node_scale": Vector3.ONE,
	},
	"heavy_quad_tracks": {
		"pattern": Pattern.SIDE_PAIRS, "per_side": 1,
		"geo_keys": {"tread_width": 1.0, "track_count": 4.0},
		"geo_aliases": {"tread_width": ["width", "size"]},
		"hull_length_geo_key": "target_length",
		"normal_is_side": true,
		"mirror": true,
		"scale_mode": ScaleMode.FIXED,
		"node_scale": Vector3.ONE,
	},
	"legs": {
		"pattern": Pattern.SIDE_PAIRS,
		"count_key": "leg_count", "count_fallback": "count", "count_default": 4,
		"count_min": 2, "count_even": true,
		# leg_type is in here for one reason: _resolve_geo() forwards ONLY the
		# keys declared here into each module's tweaks dict, and the builder
		# reads the fitted set out of those tweaks. Left out, the LAYOUT knew
		# which set was chosen (it resolves the geometry row straight from
		# settings) but _build_legs() did not - so picking Mantis moved the
		# stations onto the hull flank and then built a Stryker limb on them.
		# A string among the floats is fine: _resolve_geo copies values through
		# without touching them.
		"geo_keys": {"leg_length": 1.0, "foot_size": 1.0, "leg_width": 1.0,
			"leg_type": "stryker"},
		"geo_aliases": {"leg_length": ["size"]},
		# The hip stays flush against the chassis; only the thigh/shin/foot
		# chain splays outward, for a wide stance without a floating hip.
		"stance_geo_key": "leg_stance_reach", "stance_frac": 0.8,
		# No drop_by_part_length either: the hip is build_wheel_mount(), and
		# that mount only works because the module origin sits AT the hull's
		# underside. Pushing the origin down by the leg's length left the
		# driveshaft reaching up into empty air.
		"normal_is_side": true,
		"mirror": true, "override_pos": true,
		# FIXED, not HULL_RELATIVE. Scaling the leg by hull_height_factor is
		# the giant-spider-legs problem (Chris, 2026-08-02): a taller body
		# gets taller legs, which raises the body further, in a feedback loop
		# that left every tall hull on legs floating half a hull above the
		# ground. Ride height belongs to the running gear - see the DROP
		# comment in visual_builder.gd's _build_legs() - and the leg_length
		# tweak is the only way to scale a leg.
		"scale_mode": ScaleMode.FIXED,
	},
	"helicopter_rotors": {
		"pattern": Pattern.SIDE_PAIRS,
		"count_key": "rotor_units", "count_fallback": "count", "count_default": 4,
		"count_min": 2, "count_even": true,
		"geo_keys": {"blade_count": 4.0, "blade_length": 1.0, "duct": false},
		"geo_aliases": {"blade_length": ["size"]},
		"normal": Vector3.UP, "reach_keys": ReachKeys.SIDE_XY,
		"scale_mode": ScaleMode.FIXED,
		"node_scale": Vector3.ONE,
	},
	"ornithopter_wing": {
		"pattern": Pattern.SIDE_PAIRS, "per_side": 1,
		"geo_keys": {"wingspan": 1.0},
		"geo_aliases": {"wingspan": ["size"]},
		"normal_is_side": true,
		# The shoulder rig is a roof-spanning frame, so the builder has to know
		# how much roof there is to span and how far inboard the far rail sits.
		"hull_length_geo_key": "target_length",
		"stance_geo_key": "roof_reach", "stance_frac": 0.5,
		"mirror": true, "node_scale": Vector3(2.0, 1.0, 2.0),
		# FIXED, not HULL_RELATIVE. "Impractically long wings" is the
		# archetype (Chris, 2026-08-02), and the 2x node_scale is sized to
		# land just inside the 5.5x width clamp at hull x=1.0. A
		# hull-relative scale would compound the 2x with the hull's own
		# footprint and overshoot the clamp on any non-reference hull.
		"scale_mode": ScaleMode.FIXED,
	},
	"hover_engine": {
		"pattern": Pattern.RING_XZ,
		"count_key": "pad_count", "count_default": 4, "count_min": 4, "count_max": 8,
		"geo_keys": {"emv_level": 1.0},
		"geo_aliases": {"emv_level": ["size"]},
		"normal": Vector3.DOWN, "reach_keys": ReachKeys.XYZ,
		"scale_mode": ScaleMode.FIXED,
		"node_scale": Vector3.ONE,
	},
	"buoyant_envelope": {
		# SIDE_PODS, not STERN_ROW. An airship's cruise engines hang off
		# outriggers along the flanks, not in a row across the stern, and Chris
		# specified the count progression explicitly - see the pattern.
		"pattern": Pattern.SIDE_PODS,
		"count_key": "prop_count", "count_fallback": "count", "count_default": 2,
		"count_min": 1, "count_max": 6,
		"geo_keys": {"blade_count": 3.0, "blade_pitch": 1.0},
		"normal_is_side": true, "mirror": false,
		"scale_mode": ScaleMode.FIXED,
		"node_scale": Vector3.ONE,
	},
	# --- Expansion types (LOCOMOTION_EXPANSION_PLAN.md 4) ---
	# Every one of these is a data declaration and nothing else - no new branch
	# in module_placer.gd, which is the whole point of the factoring. Where a
	# type needed a pattern that did not exist yet, the pattern was added to
	# stations() once and is now available to everything.
	"half_track": {
		"pattern": Pattern.SIDE_PAIRS, "per_side": 1,
		"geo_keys": {"bogie_count": 3.0, "front_axle_size": 1.0, "tread_width": 1.0},
		"hull_length_geo_key": "target_length",
		"normal_is_side": true,
		"mirror": true,
		"scale_mode": ScaleMode.FIXED,
		"node_scale": Vector3.ONE,
	},
	"rocker_bogie": {
		"pattern": Pattern.SIDE_PAIRS, "per_side": 1,
		"geo_keys": {"bogie_pairs": 3.0, "arm_length": 1.0, "wheel_size": 1.0},
		"hull_length_geo_key": "target_length",
		"normal_is_side": true,
		"mirror": true,
		"scale_mode": ScaleMode.FIXED,
		"node_scale": Vector3.ONE,
	},
	"air_cushion_skirt": {
		# FOOTPRINT, not RING_XZ. A hovercraft's bag is ONE continuous loop
		# around the hull's bottom edge (Chris), so spawning N instances round
		# a ring gave N little skirts instead - "just a few little boxy
		# things". The lift fans are still a ring, but they now live inside
		# the single skirt instance where they belong.
		"pattern": Pattern.FOOTPRINT,
		"count_key": "lift_fan_count", "count_default": 3, "count_min": 2, "count_max": 6,
		"geo_keys": {"skirt_diameter": 1.0, "plenum_pressure": 1.0},
		"normal": Vector3.DOWN, "reach_keys": ReachKeys.XYZ,
		"scale_mode": ScaleMode.FIXED,
		"node_scale": Vector3.ONE,
	},
	"anti_grav_plate": {
		"pattern": Pattern.RING_XZ,
		"count_key": "plate_count", "count_default": 4, "count_min": 3, "count_max": 8,
		"geo_keys": {"field_strength": 1.0, "stabilizer_ring": true},
		"normal": Vector3.DOWN, "reach_keys": ReachKeys.XYZ,
		"scale_mode": ScaleMode.FIXED,
		"node_scale": Vector3.ONE,
	},
	"screw_drive": {
		"pattern": Pattern.CORNER_SPAN,
		"geo_keys": {"drum_diameter": 1.0, "helix_depth": 1.0},
		"geo_aliases": {"drum_diameter": ["drum_width", "size"]},
		"normal_is_side": true,
		"mirror": true,
		"scale_mode": ScaleMode.FIXED,
		"node_scale": Vector3.ONE,
	},
	"plasma_thruster": {
		"pattern": Pattern.SIDE_PAIRS,
		"count_key": "thruster_count", "count_default": 4, "count_min": 2, "count_max": 8, "count_even": true,
		"geo_keys": {"nozzle_width": 1.0, "afterburner": false},
		"normal": Vector3.UP, "reach_keys": ReachKeys.XYZ,
		"scale_mode": ScaleMode.FIXED,
		"node_scale": Vector3.ONE,
		"mirror": false,
	},
}

## Per-pattern geometry. Kept out of LAYOUTS because these are the numbers a
## designer tunes when a part reads wrong against a hull, and they want to be
## findable as a block rather than scattered through the table.
const GEOMETRY := {
	# SIDE_PAIRS: how far outboard, how high, how far fore/aft the row spreads.
	"wheels":            {"x_pad": 0.15, "x_pad_scales_with": "wheel_size", "y": "underside", "z_span": 0.35},
	"tracked_treads":    {"x_from": "running_gear", "x_inset_frac": 0.12, "y": "below_gear", "z_span": 0.0},
	"legs":              {"x_from": "running_gear", "y": "underside", "z_span": 0.35},
	# The SHOULDERED leg sets (Mantis, Crawler - see ModuleCatalog.LEG_TYPES)
	# bolt to the hull's FLANK instead of its belly. Their Part1 reaches
	# outboard before the limb proper begins, so under a hull that shoulder is
	# buried in it.
	#
	# Selected per-variant by _leg_geometry() below, not by a second LAYOUTS
	# entry: the count, mirroring, stance and scale rules are identical, and
	# only the station differs.
	#
	# x_pad 0.0 against the hull's half-width puts the station exactly on the
	# side plane, which is the surface the plate bolts to. y is a third of the
	# way up the flank rather than at the underside, because a shoulder mounted
	# at the very bottom corner reads as an underside mount that missed.
	"legs_flank":        {"x_pad": 0.0, "y": "flank", "y_frac": 0.30, "z_span": 0.35},
	"helicopter_rotors": {"x_pad": 1.2, "y_pad": 0.3, "y": "topside", "z_span": 0.35},
	# On the ROOF EDGE, not floating beside the hull at mid-height. The old
	# entry pushed the station further outboard as wingspan grew
	# (x_pad_scales_with), so the longer Chris made the wings the further the
	# whole assembly walked away from the vehicle - which is why they read as
	# unattached. The station now sits exactly on the top corner rail and the
	# builder reaches inboard across the roof for its frame, the same invariant
	# build_wheel_mount() uses under the hull.
	"ornithopter_wing":  {"x_pad": 0.0, "y": "topside", "y_pad": 0.0, "z_frac": 0.0},
	# RING_*: ellipse radii and the fixed offset on the third axis.
	"hover_engine":      {"pad_from_catalog": true, "y": "underside"},
	# SIDE_PODS: how far outboard the pylon reaches, how far the row spreads
	# fore/aft, and how far below the hull the belly pod hangs.
	# Standoff doubled (Chris): 0.55 -> 1.10 outboard, and the belly pod drops
	# the same amount further. An airship's engines hang well clear of the
	# envelope - close in they read as blisters on the hull rather than
	# outriggers.
	"buoyant_envelope":  {"x_pad": 1.10, "z_span": 0.30, "belly_drop": 1.10},
	# CORNER_SPAN: the drum's down-and-out offset, and how far each end brace
	# reaches toward the hull's own centre.
	"screw_drive":       {"drum_offset_frac": 0.6, "reach_fraction": 0.8},
	# --- Expansion types ---
	"half_track":        {"x_from": "running_gear", "y": "below_gear", "z_span": 0.0},
	# "underside", not "below_gear": the extra 0.30 * hull height that the
	# belted types want (so their belts hang clear of the body) left the
	# rocker-bogie's pivot mount reaching up at empty air, its struts stopping
	# short of the hull (Chris). This linkage hangs from a pivot ON the hull,
	# not from a beam slung under it.
	"rocker_bogie":      {"x_from": "running_gear", "y": "underside", "z_span": 0.0},
	# A hovercraft's skirt is a single big cushion, so its fans sit INSIDE the
	# hull footprint rather than outboard of it like hover_engine's pads.
	"air_cushion_skirt": {"pad_from_catalog": false, "y": "underside"},
	"anti_grav_plate":   {"pad_from_catalog": true, "y": "underside"},
	"plasma_thruster":   {"x_pad": 0.25, "y": "underside", "z_span": 0.38},
}

## MOUNT KITS - the structural interface between a hull and its running gear.
##
## Locomotion had no mounting CONVENTION: every type improvised its own way of
## attaching (rotors grew a pylon, screws a cradle, legs a hip, wheels a gearbox
## column), so there was nothing for a new type to be consistent with and nothing
## shared to improve. A generic chassis frame tried underneath all of it just
## fought the improvised mounts, because two answers to the same question were
## being drawn at once.
##
## The weapons roster solved this with a convention rather than a part. This is
## the locomotion equivalent: five structural archetypes, authored once in
## tools/blender/build_mount_kits.py, that every type draws from. Five and not
## one because a hover pad and a road wheel genuinely need different structure -
## but each answer is now the same everywhere it is used.
enum Kit {
	NONE,            ## Type supplies its own structure (airborne, mostly).
	SUSPENSION_ARM,  ## Swing arm + coil-over + hub carrier.
	TRACK_FRAME,     ## Rigid side frame, bearing stations, final drive.
	STRUT_LEG,       ## Vertical blade, hull flange, actuator.
	PYLON,           ## Tapered strut to a nacelle collar.
	HARDPOINT_PAD,   ## Flush pad, standoffs, power conduit.
}

## Per-type kit choice and its parameters. `drop` is how far below the mount
## station the running gear hangs, in the module's own local units; `stations`
## is how many repeats of the kit's repeating element (bearing blocks, standoffs)
## to lay along it.
const MOUNT_KITS := {
	"wheels":            {"kit": Kit.SUSPENSION_ARM, "drop": 0.30, "stations": 1},
	"half_track":        {"kit": Kit.TRACK_FRAME, "drop": 0.26, "stations": 4},
	"rocker_bogie":      {"kit": Kit.SUSPENSION_ARM, "drop": 0.34, "stations": 2},
	# NONE, deliberately. _build_tracked_treads() now builds its own structure -
	# a swing arm per road wheel up to the sub-frame line, plus the sprocket
	# carriers - so the generic TRACK_FRAME kit was a SECOND set of frame rails
	# and bearing blocks hanging below the belt, which is the object Chris kept
	# seeing under the bottom run. One structure per assembly, not two.
	"tracked_treads":    {"kit": Kit.NONE, "drop": 0.0, "stations": 0},
	"helicopter_rotors": {"kit": Kit.PYLON, "drop": 0.0, "stations": 1},
	"buoyant_envelope":  {"kit": Kit.PYLON, "drop": 0.0, "stations": 1},
	"hover_engine":      {"kit": Kit.HARDPOINT_PAD, "drop": 0.16, "stations": 4},
	"air_cushion_skirt": {"kit": Kit.HARDPOINT_PAD, "drop": 0.14, "stations": 4},
	"anti_grav_plate":   {"kit": Kit.HARDPOINT_PAD, "drop": 0.12, "stations": 3},
	"plasma_thruster":   {"kit": Kit.HARDPOINT_PAD, "drop": 0.16, "stations": 4},
	# An ornithopter's wing root IS its structure - a shoulder joint, not a
	# bolted-on mount. Declared NONE rather than left out, so the absence is a
	# decision and not an omission.
	"ornithopter_wing":  {"kit": Kit.NONE, "drop": 0.0, "stations": 0},
}

## Which types ride the subframe under the hull.
##
## Ground contact and hover, because both are carried by a chassis. Naval and
## airborne are deliberately excluded: a stern propeller on a pylon and a rotor
## on a mast are not carried by a chassis, and forcing them onto one is exactly
## what made the first generic frame collide with everything it was added to.
## They keep their own structure until they get a system of their own.
# Empty: Chris asked for the subframe dropped from everything (2026-08-02),
# along with the running-gear slab in module_placer.gd. Both were extra
# structure bolted under the hull to give locomotion something to mount to,
# and both fought the per-type mounting instead of supporting it. Every type
# now hangs off the hull directly - build_wheel_mount() for the ground types,
# a pylon for the ones that project away from it.
const SUBFRAME_TYPES := []

static func uses_subframe(type_id: String) -> bool:
	return type_id in SUBFRAME_TYPES


static func mount_kit(type_id: String) -> Dictionary:
	return MOUNT_KITS.get(type_id, {"kit": Kit.NONE, "drop": 0.0, "stations": 0})


## How far outboard a type may reach, as a multiple of the hull's own half-width.
##
## Not one number for everything: a rotor disc is SUPPOSED to overhang the
## fuselage and a road wheel is not, so a single limit would either crop the
## helicopter or leave the walker at 2.7x. 0.0 disables the clamp entirely for
## types whose whole identity is span.
const MAX_WIDTH_FACTOR := {
	# Ground contact: the running gear must sit under the vehicle, not beside
	# it. Measured tracked/wheeled types already land at ~1.1-1.25x, so this is
	# a ceiling the well-behaved types never touch.
	"wheels": 1.5, "tracked_treads": 0.0, "half_track": 0.0,
	"heavy_quad_tracks": 0.0, "rocker_bogie": 0.0, "screw_drive": 0.0,
	# A walker legitimately stands wider than its body - that IS the stance -
	# but 2.69x read as a spider rather than a vehicle.
	"legs": 1.9,
	# Hover skirts and grav plates spread to carry the footprint.
	# Raised for the two field types (Chris asked for both "larger and more
	# prominent on the ends of their pylons"). At 1.6/1.7 the width clamp was
	# shrinking the enlarged emitter heads straight back down - anti_grav_plate
	# measured 0.018 bulk after the size-up, LOWER than the 0.107 it had
	# before it.
	"hover_engine": 0.0, "air_cushion_skirt": 0.0, "anti_grav_plate": 0.0,
	"plasma_thruster": 0.0,
	# Air: span is the point. Rotors and engine clusters overhang by design.
	# Setting to 0.0 disables width clamping so pylons and mounting struts
	# maintain true physical reach to the hull on small hulls without shrinking.
	"helicopter_rotors": 0.0, "buoyant_envelope": 0.0,
	# The ornithopter is SUPPOSED to be absurd (Chris: "they're kind of an
	# absurd choice and they need to feel like it. Impractically long"). This
	# is the one type where a span several times the vehicle's width is the
	# design, so the clamp is set to stop authoring accidents rather than to
	# enforce proportion.
	"ornithopter_wing": 5.5,
}

static func max_width_factor(type_id: String) -> float:
	return float(MAX_WIDTH_FACTOR.get(type_id, 1.8))

static func has_layout(type_id: String) -> bool:
	return LAYOUTS.has(type_id)

## The node scale the placed instance will be given.
##
## HULL_RELATIVE is the default, so the visual grows with the hull it lands on.
## FIXED types (legs, ornithopter_wing) use their own `node_scale` verbatim;
## `legs` because scaling it raised the body (giant-spider-legs) and
## `ornithopter_wing` because its 2x is the design intent, not a hull-relative
## auto-scale.
##
## The HULL_RELATIVE factor is the CUBE ROOT OF THE HULL'S VOLUME, applied
## uniformly to all three axes. A 2x bigger hull in any one axis makes the
## wheel bigger; a 2x bigger hull in every axis makes it 2x bigger; a hull
## that is 2x tall but only 1x wide gives the same wheel as a hull that is
## 1x tall and 2x wide. The previous (footprint, height, footprint) split
## stretched the wheel into a tall ovoid on a tall+narrow hull ("egg-
## shaped wheels", Chris, 2026-08-16) - which is what proportional scale
## exists to prevent.
static func node_scale_for(type_id: String, hull_height_factor: float,
		hull_footprint_factor: float = 1.0) -> Vector3:
	var spec: Dictionary = LAYOUTS.get(type_id, {})
	match int(spec.get("scale_mode", ScaleMode.FIXED)):
		ScaleMode.HULL_RELATIVE:
			# (h * fp * fp)^(1/3) = cbrt(hull_height_factor * hull_footprint_factor^2).
			# Pass the same factor the geometry got, in all three axes, so
			# the wheel stays a wheel rather than stretching to match the
			# hull's aspect ratio.
			var uniform: float = pow(hull_height_factor * hull_footprint_factor * hull_footprint_factor, 1.0 / 3.0)
			return Vector3(uniform, uniform, uniform)
		ScaleMode.HULL_HEIGHT:
			return Vector3(1.0, hull_height_factor, 1.0)
		_:
			return spec.get("node_scale", Vector3.ONE)

## scale_multiplier exists so module_data's weight/cost read the same factor the
## geometry got. A HULL_RELATIVE factor IS folded in here, because the
## auto-scaled part is a real physical object of the auto-scaled size - a 2x
## bigger wheel weighs more than a 1x wheel, whether the size was a player
## choice or a consequence of the hull. The reverse is also true: a 0.5x
## smaller wheel weighs less. Folding it in means the catalog weight of the
## locomotor tracks its actual rendered size, and the chassis/loco mass scales
## with the hull - which is what Drivetrain.analyze() then subtracts to get
## `carried_weight`. FIXED types (legs, ornithopter) get their `node_scale`
## verbatim - same as before.
##
## The HULL_RELATIVE branch mirrors node_scale_for(): a single uniform factor
## in all three axes, the cube root of the hull's volume, so the catalog
## weight tracks the actual rendered size and `vol = scale^3` is a true
## volumetric scale, not a per-axis artefact of the hull's aspect ratio.
static func scale_multiplier_for(type_id: String, hull_height_factor: float = 1.0,
		hull_footprint_factor: float = 1.0) -> Vector3:
	var spec: Dictionary = LAYOUTS.get(type_id, {})
	match int(spec.get("scale_mode", ScaleMode.FIXED)):
		ScaleMode.HULL_RELATIVE:
			var uniform: float = pow(hull_height_factor * hull_footprint_factor * hull_footprint_factor, 1.0 / 3.0)
			return Vector3(uniform, uniform, uniform)
		ScaleMode.HULL_HEIGHT:
			return Vector3.ONE
		_:
			return spec.get("node_scale", Vector3.ONE)

static func _resolve_count(spec: Dictionary, settings: Dictionary) -> int:
	if not spec.has("count_key"):
		return int(spec.get("per_side", 1))
	var raw = settings.get(spec["count_key"], null)
	if raw == null and spec.has("count_fallback"):
		raw = settings.get(spec["count_fallback"], null)
	if raw == null:
		raw = spec.get("count_default", 1)
	var n := int(raw)
	if spec.has("count_min"):
		n = max(n, int(spec["count_min"]))
	if spec.has("count_max"):
		n = min(n, int(spec["count_max"]))
	if bool(spec.get("count_even", false)) and n % 2 != 0:
		n += 1
	return n

## Resolves the tweaks a type's mesh builder reads.
##
## `geo_aliases` matters more than it looks: before the modular rebuild every
## locomotion type had one universal "size" tweak, and a few types still accept
## that spelling (and, for treads and screws, an intermediate one) so old
## blueprints keep loading. Those aliases are per-KEY, not per-type - "size"
## means wheel radius on wheels and blade length on rotors, but it has never
## meant blade COUNT or the afterburner toggle. Applying it to every key would
## quietly let a legacy `{"size": 2.0}` set `blade_count` to 2.
static func _resolve_geo(spec: Dictionary, settings: Dictionary) -> Dictionary:
	var geo := {}
	var aliases: Dictionary = spec.get("geo_aliases", {})
	for key in spec.get("geo_keys", {}):
		var value = settings.get(key, null)
		if value == null:
			for alias in aliases.get(key, []):
				value = settings.get(alias, null)
				if value != null:
					break
		if value == null:
			value = spec["geo_keys"][key]
		geo[key] = value
	return geo

static func _apply_reach(geo: Dictionary, spec: Dictionary, reach: Vector3,
		side: float, fore: Vector3 = Vector3.ZERO, aft: Vector3 = Vector3.ZERO) -> void:
	match int(spec.get("reach_keys", ReachKeys.NONE)):
		ReachKeys.XYZ:
			geo["mount_reach_x"] = reach.x
			geo["mount_reach_y"] = reach.y
			geo["mount_reach_z"] = reach.z
		ReachKeys.SIDE_XY:
			geo["mount_side"] = side
			geo["mount_reach_x"] = reach.x
			geo["mount_reach_y"] = reach.y
		ReachKeys.FORE_AFT:
			geo["mount_reach_fore_x"] = fore.x
			geo["mount_reach_fore_y"] = fore.y
			geo["mount_reach_fore_z"] = fore.z
			geo["mount_reach_aft_x"] = aft.x
			geo["mount_reach_aft_y"] = aft.y
			geo["mount_reach_aft_z"] = aft.z
		_:
			pass

static func _station(pos: Vector3, normal: Vector3, geo: Dictionary, side: float,
		mirror: bool) -> Dictionary:
	return {
		"position": pos, "normal": normal, "geo": geo, "side": side,
		"mirror": mirror, "has_final_position": false,
		"final_position": Vector3.ZERO, "meta": {},
	}

## The GEOMETRY row for a type, which for legs depends on which set is fitted.
##
## Every other locomotion type has exactly one row. Legs have two, because the
## six authored sets split into belly-mounted and shoulder-mounted hardware and
## that genuinely moves the station - it is not a cosmetic difference. Resolved
## here rather than by giving the flank sets their own LAYOUTS entry, because
## everything else about them (count, mirroring, stance, scale mode) is
## identical and duplicating it would be two things to keep in step.
static func _geometry_for(type_id: String, settings: Dictionary) -> Dictionary:
	if type_id != "legs":
		return GEOMETRY.get(type_id, {})
	# Runtime load: module_catalog.gd preloads this file, so a preload back the
	# other way would close a cycle.
	var ModuleCatalogScript = load("res://scripts/module_catalog.gd")
	if ModuleCatalogScript == null:
		return GEOMETRY["legs"]
	var leg_id: String = ModuleCatalogScript.get_leg_type(settings)
	var mount: String = str(ModuleCatalogScript.get_leg_profile(leg_id).get("mount", "underside"))
	return GEOMETRY["legs_flank"] if mount == "flank" else GEOMETRY["legs"]


## The whole layout, for one type on one hull.
##
## `ctx` carries what only the placer knows: hull_size, running_gear_size,
## underside_y_bias, and the locomotion type's own catalog size.
static func stations(type_id: String, settings: Dictionary, ctx: Dictionary) -> Array:
	var spec: Dictionary = LAYOUTS.get(type_id, {})
	if spec.is_empty():
		return []
	var geom: Dictionary = _geometry_for(type_id, settings)
	var hull_size: Vector3 = ctx.get("hull_size", ModuleCatalog.REFERENCE_HULL_SIZE)
	var gear: Vector3 = ctx.get("running_gear_size", Vector3.ZERO)
	var bias: float = ctx.get("underside_y_bias", 0.0)
	var cat_size: Vector3 = ctx.get("catalog_size", Vector3.ONE)
	var geo_base := _resolve_geo(spec, settings)
	# How far the mount kit must reach UP from this station to meet the hull's
	# underside. Several types sit well below it (a leg's origin is near its
	# foot, a hydrofoil's near its flange) so a kit drawn only downward from the
	# station leaves running gear hanging in space with nothing joining it to
	# the vehicle - measured at 1.04 for tracked_treads, 0.23 for legs. The kit
	# stretches its connecting element by this, so the bridge is always closed
	# regardless of hull size or which station the type uses.
	geo_base["kit_reach"] = 0.0
	var out: Array = []
	# Where on the hull a mount kit anchors. This is the generalisation of what
	# made the OLD wheels and treads work: their driveshaft was not a fixed lump
	# dropped at the station, it was solved to span the actual gap from the part
	# back into the hull, angling inboard and up. Every type gets that now - the
	# layout hands each station a full reach VECTOR to its anchor, and the kit
	# draws a strut of exactly that length and orientation. A fixed-size kit plus
	# a vertical riser could never close these gaps, because the gap is different
	# for every type, every hull and every station.
	var anchor_y: float = -hull_size.y * 0.5 + hull_size.y * 0.08

	match int(spec["pattern"]):
		Pattern.SIDE_PAIRS, Pattern.ROOF_PAIRS:
			var per_side := int(spec.get("per_side", 0))
			if per_side == 0:
				per_side = int(_resolve_count(spec, settings) / 2)
			var x_offset := 0.0
			if geom.get("x_from", "") == "running_gear":
				# The running-gear slab is gone (Chris, 2026-08-02), so `gear`
				# is a zero vector and this used to collapse the whole row onto
				# the centreline. These types now mount at the HULL'S OWN EDGE,
				# which is where Chris asked for them: "these ones I think can
				# go directly under the hull edges."
				# x_inset_frac pulls the station in from the hull's edge so the
				# mount's own struts land INSIDE the hull's volume rather than
				# grazing its skin (Chris: "they need to move in further, so
				# their struts actually intersect the hull"). The running gear
				# itself is pushed back out in the builder, which is the other
				# half of that same ask - see BELT_OUTBOARD_NUDGE in
				# visual_builder.gd.
				x_offset = (hull_size.x / 2.0) * (1.0 - float(geom.get("x_inset_frac", 0.0)))
			else:
				var pad := float(geom.get("x_pad", 0.0))
				if geom.has("x_pad_scales_with"):
					pad *= float(geo_base.get(geom["x_pad_scales_with"], 1.0))
				x_offset = hull_size.x / 2.0 + pad
			var y := 0.0
			match geom.get("y", ""):
				"underside": y = -hull_size.y / 2.0 + bias
				# "below_gear" used to mean the hull's underside minus half the
				# running-gear slab. With the slab gone the naive reading is
				# just the underside - which moved every belted type UP by that
				# half-slab and left the sprockets overlapping the hull's sides
				# (Chris: "the tracked treads are too high up now somehow").
				# The drop it was really providing is kept explicitly, as a
				# fraction of the hull's own height, so the belt still hangs
				# below the body rather than beside it.
				# 0.30, was 0.20: Chris asked for the treads "down a smidge
				# further, say half the remaining distance to the bottom of the
				# visible hull mesh."
				"below_gear": y = -hull_size.y / 2.0 + bias - hull_size.y * 0.30
				"topside": y = hull_size.y / 2.0 + float(geom.get("y_pad", 0.0))
				# Partway UP the hull's side, measured from its underside - where
				# a shouldered leg bolts on. Deliberately distinct from the bare
				# y_frac fallback below, which measures from the hull's CENTRE and
				# so would put the same fraction somewhere else on a tall hull.
				"flank": y = -hull_size.y / 2.0 + bias + hull_size.y * float(geom.get("y_frac", 0.0))
				_: y = hull_size.y * float(geom.get("y_frac", 0.0))
			var z_base := hull_size.z * float(geom.get("z_frac", 0.0))
			var z_limit := hull_size.z * float(geom.get("z_span", 0.0))

			# Types whose part spans or hangs off the hull need to be told the
			# hull's own dimensions - their builders see only their catalog size.
			if spec.has("hull_length_geo_key"):
				geo_base[spec["hull_length_geo_key"]] = hull_size.z
			if spec.has("stance_geo_key"):
				geo_base[spec["stance_geo_key"]] = hull_size.x * float(spec.get("stance_frac", 0.0))
			# How far this station sits ABOVE the hull's underside line.
			#
			# Zero for everything mounted under the belly, and legs are the whole
			# point of it: a shouldered set bolts partway up the flank, so
			# uncompensated its sole would stop short of the ground by exactly
			# this much and the vehicle would stand higher on Mantis than on
			# Stryker. _build_legs() adds it to the limb's target drop, which is
			# what keeps ride height identical across all six sets - the property
			# test_leg_sets_share_one_ride_height pins.
			geo_base["mount_rise"] = maxf(0.0, y - (-hull_size.y / 2.0 + bias))
			# A part that hangs BELOW the chassis (a leg) sits at its own
			# half-length under it, rather than at the hull's underside.
			var final_y := y
			var has_final := bool(spec.get("override_pos", false))
			if spec.has("drop_by_part_length"):
				var part_len := float(geo_base.get(spec["drop_by_part_length"], 1.0))
				final_y = -hull_size.y / 2.0 - gear.y / 2.0 - (cat_size.y * part_len) / 2.0
			if spec.has("centerline_geo_key"):
				geo_base[spec["centerline_geo_key"]] = -final_y

			for side in [-1.0, 1.0]:
				var normal: Vector3 = spec.get("normal", Vector3.UP)
				if bool(spec.get("normal_is_side", false)):
					normal = Vector3.LEFT if side < 0.0 else Vector3.RIGHT
				for i in range(per_side):
					var z_pos := z_base
					if per_side > 1:
						z_pos = -z_limit + (2.0 * z_limit * i) / (per_side - 1)
					var pos := Vector3(x_offset * side, y, z_pos)
					var geo := geo_base.duplicate()
					var st_y: float = final_y if has_final else y
					geo["kit_reach"] = maxf(0.0, (-hull_size.y * 0.5) - st_y)
					# Inboard and up, exactly like the old wheel driveshaft.
					var anchor := Vector3(side * hull_size.x * 0.30, anchor_y, z_pos)
					geo["kit_anchor_x"] = anchor.x - pos.x
					geo["kit_anchor_y"] = anchor.y - st_y
					geo["kit_anchor_z"] = anchor.z - pos.z
					# helicopter_rotors' pylon reach is the UNSIGNED distance
					# back to the hull's centreline on each axis - the builder
					# applies mount_side itself.
					_apply_reach(geo, spec, Vector3(x_offset, y, 0.0), side)
					var st := _station(pos, normal, geo, side,
						bool(spec.get("mirror", false)) and side < 0.0)
					st["index"] = i
					if has_final:
						st["has_final_position"] = true
						st["final_position"] = Vector3(pos.x, final_y, pos.z)
					# Alternating walk-cycle phase: a checkerboard across the
					# side/fore-aft grid, so adjacent legs swing opposite ways
					# like a real trot. Read by VisualBuilder.pose_leg().
					#
					# GATED ON THE TYPE, not on drop_by_part_length. It asked for
					# a key the legs entry explicitly does NOT set - see its "No
					# drop_by_part_length either" comment above - so the condition
					# was never true, leg_phase was never written, and every leg
					# on every walker read the 0.0 default and stepped in perfect
					# unison. Silent for as long as it lasted, because a missing
					# meta has a sensible-looking fallback and one rigid pivot
					# swinging together does not obviously read as wrong.
					if type_id == "legs":
						var side_idx := 0 if side < 0.0 else 1
						st["meta"]["leg_phase"] = PI if (side_idx + i) % 2 == 1 else 0.0
					out.append(st)

		Pattern.RING_XZ:
			var n := _resolve_count(spec, settings)
			var pad_radius: float = cat_size.x * 0.5 * (2.3 if type_id == "anti_grav_plate" else 2.1)
			var hx: float = hull_size.x / 2.0
			var hz: float = hull_size.z / 2.0
			var y := -hull_size.y / 2.0 + bias
			for i in range(n):
				var angle := i * TAU / float(n)
				var cos_a := cos(angle)
				var sin_a := sin(angle)
				# Ray from origin to box perimeter along radial angle to find exact hull contact point
				var t_box: float = minf(hx / maxf(absf(cos_a), 0.001), hz / maxf(absf(sin_a), 0.001))
				var contact_pt := Vector3(cos_a * t_box, y, sin_a * t_box)
				var p := contact_pt + Vector3(cos_a * pad_radius, 0.0, sin_a * pad_radius)
				var geo := geo_base.duplicate()
				geo["kit_reach"] = maxf(0.0, (-hull_size.y * 0.5) - p.y)
				# Anchor vector points directly from pad center back to hull contact point
				var anchor_vec := contact_pt - p
				geo["kit_anchor_x"] = anchor_vec.x
				geo["kit_anchor_y"] = anchor_vec.y
				geo["kit_anchor_z"] = anchor_vec.z
				geo["mount_reach_x"] = anchor_vec.x
				geo["mount_reach_y"] = anchor_vec.y
				geo["mount_reach_z"] = anchor_vec.z
				var st := _station(p, spec.get("normal", Vector3.DOWN), geo, 0.0, false)
				st["index"] = i
				out.append(st)

		Pattern.RING_XY:
			var n := _resolve_count(spec, settings)
			var x_radius := hull_size.x / 2.0 + float(geom.get("x_pad", 0.0))
			var y_radius := hull_size.y / 2.0 + float(geom.get("y_pad", 0.0))
			var z_offset := hull_size.z * float(geom.get("z_frac", 0.0))
			for i in range(n):
				var angle := i * TAU / float(n)
				var p := Vector3(cos(angle) * x_radius, sin(angle) * y_radius, z_offset)
				var geo := geo_base.duplicate()
				_apply_reach(geo, spec, -p, 0.0)
				var st := _station(p, spec.get("normal", Vector3.RIGHT), geo, 0.0, false)
				st["index"] = i
				out.append(st)

		Pattern.STERN_ROW:
			var n := _resolve_count(spec, settings)
			var x_limit := hull_size.x * float(geom.get("x_frac", 0.3))
			var z_end := hull_size.z * 0.5 + float(geom.get("z_clearance", 0.0))
			var y := hull_size.y * float(geom.get("y_frac", 0.0))
			for i in range(n):
				var x_pos := 0.0
				if n > 1:
					x_pos = -x_limit + (2.0 * x_limit * i) / (n - 1)
				var p := Vector3(x_pos, y, z_end)
				var geo := geo_base.duplicate()
				_apply_reach(geo, spec, -p, 0.0)
				var st := _station(p, spec.get("normal", Vector3.BACK), geo, 0.0, false)
				st["index"] = i
				out.append(st)

		Pattern.SIDE_PODS:
			# Chris's progression: pods go on in SIDE PAIRS, and an odd count
			# puts the extra one under the belly rather than leaving the
			# vehicle lopsided. 1 -> one pod (belly), 2 -> one per side,
			# 3 -> one per side plus belly, 4 -> two per side, 5 -> two per
			# side plus belly, 6 -> three per side.
			var total := _resolve_count(spec, settings)
			var per_flank := int(total / 2)
			var has_belly: bool = (total % 2) == 1
			var out_x := hull_size.x * 0.5 + float(geom.get("x_pad", 0.5))
			var z_reach := hull_size.z * float(geom.get("z_span", 0.3))
			for side in [-1.0, 1.0]:
				for i in range(per_flank):
					var zf: float = 0.0 if per_flank <= 1 						else -1.0 + 2.0 * (float(i) / float(per_flank - 1))
					var geo := geo_base.duplicate()
					geo["mount_side"] = side
					# Internal geometry channel: the builder knows its catalog
					# size (1.0) but not the hull's, and an engine pod sized off
					# the catalog came out as a speck against a real airship.
					geo["pod_scale"] = hull_size.y
					# How far the pylon has to span to reach the hull's skin.
					# The pod used to carry a fixed-length pylon in its own
					# units, which stopped reaching the moment the standoff
					# changed.
					geo["pod_reach"] = float(geom.get("x_pad", 0.5))
					var st := _station(Vector3(out_x * side, 0.0, zf * z_reach),
						Vector3.LEFT if side < 0.0 else Vector3.RIGHT, geo, side,
						bool(spec.get("mirror", false)) and side < 0.0)
					st["index"] = i
					out.append(st)
			if has_belly:
				var bgeo := geo_base.duplicate()
				bgeo["mount_side"] = 0.0
				# The belly pod hangs DOWN rather than out, so it is told to
				# point its pylon at the hull's underside instead of its side.
				bgeo["pod_belly"] = true
				bgeo["pod_scale"] = hull_size.y
				bgeo["pod_reach"] = float(geom.get("belly_drop", 0.5))
				var by := -hull_size.y * 0.5 - float(geom.get("belly_drop", 0.5))
				var bst := _station(Vector3(0.0, by, 0.0), Vector3.UP, bgeo, 0.0, false)
				bst["index"] = 0
				out.append(bst)

		Pattern.FOOTPRINT:
			var geo := geo_base.duplicate()
			# The builder knows its catalog size but not the hull's, and this
			# part has to match the hull's plan outline exactly.
			geo["footprint_x"] = hull_size.x
			geo["footprint_z"] = hull_size.z
			var st := _station(Vector3(0.0, -hull_size.y / 2.0 + bias, 0.0),
				spec.get("normal", Vector3.UP), geo, 0.0, false)
			st["index"] = 0
			out.append(st)

		Pattern.CORNER_SPAN:
			# Chris, twice: "pin the gearboxes to the corners of the hull, have
			# them descend from there (with the struts intersecting into the
			# hull to read as attached) and then stretch the drum between
			# them."
			#
			# So the station IS the hull's bottom side edge - corner_x by
			# -hull_size.y/2 - and nothing else. The drum used to be pushed
			# outboard and UP by drum_offset (a 45-degree offset off the
			# corner), which is what left it floating beside the hull at
			# mid-height instead of hanging under the corner. Sitting the
			# origin exactly on the underside is also what build_wheel_mount()
			# requires to reach into the hull without measuring it, which is
			# how the struts come to intersect the hull rather than aim at it.
			var span_length := hull_size.z
			var half_span := span_length * 0.5
			var corner_x := hull_size.x / 2.0
			for side in [-1.0, 1.0]:
				var normal: Vector3 = Vector3.LEFT if side < 0.0 else Vector3.RIGHT
				if not bool(spec.get("normal_is_side", false)):
					normal = spec.get("normal", Vector3.UP)
				var geo := geo_base.duplicate()
				geo["drum_length"] = span_length
				# Internal geometry channel, not a player tweak: the builder
				# knows its own catalog size but not the hull's, and a drum
				# sized off the catalog came out far too thin against a real
				# hull ("the screw is too small").
				geo["drum_bore"] = hull_size.y
				# hydrofoil shares this pattern and still solves its struts
				# from a reach vector. screw_drive no longer declares
				# reach_keys, so this is a no-op for it.
				var pos := Vector3(corner_x * side, -hull_size.y / 2.0, 0.0)
				_apply_reach(geo, spec, Vector3.ZERO, side,
					-(pos + Vector3(0, 0, half_span)) * 0.8,
					-(pos + Vector3(0, 0, -half_span)) * 0.8)
				var st := _station(pos,
					normal, geo, side,
					bool(spec.get("mirror", false)) and side < 0.0)
				st["index"] = 0
				out.append(st)
	return out
