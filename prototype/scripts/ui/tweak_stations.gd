# TweakStations: the one table mapping a tweak's NAME (never its index in a
# module's spec list) to a clock-face station angle on the module action ring.
#
# WHY NAME AND NOT INDEX. TweakCallout used to place callouts by
# `idx % dir_count` (tweak_callout_manager.gd's old `_add_callout`), so
# "caliber" landed at a different clock position on every module depending on
# what else that module's TWEAK_SPECS entry happened to list before it. A
# player who learned "caliber lives at 2 o'clock" on one weapon had to
# relearn it on the next. Angle is a property of the CONCEPT (this is the bore
# tweak), not an accident of authoring order.
#
# LAYOUT. Two bands, station distance stays the same, second radial tier only
# on overflow:
#   - Inner band (existing D13 verb wedges, unchanged): 12, 3, 6, 9 o'clock.
#   - Outer band (new tweak stations): 1, 2, 4, 5, 7, 8, 10, 11 o'clock - the
#     8 clock positions NOT already claimed by a verb wedge.
# A module missing a given tweak simply leaves that station empty. When two
# of one module's tweaks share an angle (the table is per NAME, so collisions
# across names are expected - rotary cannon's barrel_count and motor_size both
# live at 11), the newcomer takes the nearest free outer-band station first:
# the first layer fills before anything builds outward. Only when all eight
# are taken does a second tier open at the canonical angle (station distance +
# one panel height) - the 8 angular slots are the whole alphabet, the tier is
# the overflow valve. Claiming lives in ModuleActionRing.add_tweak_station,
# which owns what is already placed for this module.
#
# No class_name - same convention as module_volume.gd / hull_surface.gd:
# class_name globals aren't reliable in scripts that can run headless before
# the .godot cache exists. Preload it.

# Angle expressed as a fraction of TAU, clockwise from 12 o'clock (i.e. 0.0 is
# straight up, 0.25 is 3 o'clock), matching RingDraw's existing wedge-angle
# convention for the verb band.
const CLOCK_12 := 0.0
const CLOCK_1 := 1.0 / 12.0
const CLOCK_2 := 2.0 / 12.0
const CLOCK_3 := 3.0 / 12.0
const CLOCK_4 := 4.0 / 12.0
const CLOCK_5 := 5.0 / 12.0
const CLOCK_6 := 6.0 / 12.0
const CLOCK_7 := 7.0 / 12.0
const CLOCK_8 := 8.0 / 12.0
const CLOCK_9 := 9.0 / 12.0
const CLOCK_10 := 10.0 / 12.0
const CLOCK_11 := 11.0 / 12.0

# The inner band's verb wedges. Reserved here purely so a lookup never hands a
# tweak the same station as a verb - the ring itself still draws verbs from
# its own existing wedge table.
const VERB_STATIONS := [CLOCK_12, CLOCK_3, CLOCK_6, CLOCK_9]

# The 8 outer-band stations, in the fixed assignment order tweaks claim them.
# Order here is simply first-come in the table below; it does not change once
# a tweak has been assigned, since that would relocate a station a player
# already memorized.
const OUTER_STATIONS := [CLOCK_1, CLOCK_2, CLOCK_4, CLOCK_5, CLOCK_7, CLOCK_8, CLOCK_10, CLOCK_11]

# One angle per tweak NAME. Seeded from every "name" appearing in
# LabDocument.TWEAK_SPECS, plus ModuleCatalog.AMMO_TWEAK_KEY ("ammo") and the
# locomotion settings vocabulary read off module_catalog.gd's per-locomotion
# `settings.get(...)` calls (axle_count, wheel_size, leg_count, pad_count,
# etc.) so every reachable tweak - weapon or locomotion - resolves to a
# station. Assignment order below is alphabetical by name purely so the table
# is easy to audit for a missing entry; it carries no meaning at runtime.
const TWEAK_ANGLES := {
	"afterburner": CLOCK_1,
	"arm_length": CLOCK_2,
	"arm_reach": CLOCK_4,
	"array_faces": CLOCK_5,
	"ascent_thruster": CLOCK_7,
	"axle_count": CLOCK_8,
	"bank_capacity": CLOCK_10,
	"barrel_count": CLOCK_11,
	"barrel_length": CLOCK_1,
	"bay_volume": CLOCK_2,
	"bipod_deploy": CLOCK_4,
	"blade_count": CLOCK_5,
	"blade_length": CLOCK_7,
	"blade_pitch": CLOCK_8,
	"bogie_count": CLOCK_10,
	"bogie_pairs": CLOCK_11,
	"busbar_gauge": CLOCK_1,
	"caliber": CLOCK_2,
	"charge_time": CLOCK_4,
	"coil_count": CLOCK_5,
	"containment": CLOCK_7,
	"cooling_jacket": CLOCK_8,
	"cooling_radiator": CLOCK_10,
	"cutter_head": CLOCK_11,
	"dish_aperture": CLOCK_1,
	"dispersion": CLOCK_2,
	"drive_sprocket": CLOCK_4,
	"drum_diameter": CLOCK_5,
	"drum_size": CLOCK_7,
	"drum_width": CLOCK_8,
	"duct": CLOCK_10,
	"emv_level": CLOCK_11,
	"engine_count": CLOCK_1,
	"envelope_volume": CLOCK_4,
	"field_strength": CLOCK_5,
	"focal_length": CLOCK_7,
	"foot_size": CLOCK_8,
	"front_axle_size": CLOCK_10,
	"fuse_setting": CLOCK_11,
	"grid_size": CLOCK_1,
	"ground_coupling": CLOCK_2,
	"hangar_size": CLOCK_2,
	"hatch_width": CLOCK_4,
	"helix_depth": CLOCK_5,
	"hopper_depth": CLOCK_7,
	"housing_girth": CLOCK_11,
	"intake_size": CLOCK_8,
	"launch_catapult": CLOCK_10,
	"leg_count": CLOCK_11,
	"leg_length": CLOCK_1,
	"leg_type": CLOCK_12,
	"leg_width": CLOCK_2,
	"lens_aperture": CLOCK_4,
	"lift_fan_count": CLOCK_5,
	"mast_extension": CLOCK_7,
	"mast_height": CLOCK_8,
	"motor_length": CLOCK_10,
	"motor_size": CLOCK_11,
	"mount_extension": CLOCK_1,
	"multi_barrel": CLOCK_2,
	"num_axles": CLOCK_4,
	"nozzle_count": CLOCK_5,
	"nozzle_width": CLOCK_7,
	"optic_aperture": CLOCK_8,
	"optic_power": CLOCK_10,
	"pad_count": CLOCK_11,
	"payload_size": CLOCK_2,
	"plate_count": CLOCK_4,
	"plenum_pressure": CLOCK_5,
	"pressure_valve": CLOCK_8,
	"projector_diameter": CLOCK_10,
	"prop_count": CLOCK_11,
	"pylon_height": CLOCK_8,
	"radar_dish": CLOCK_2,
	"radar_size": CLOCK_4,
	"reactor_length": CLOCK_7,
	"rod_thickness": CLOCK_8,
	"rotor_units": CLOCK_10,
	"rotor_mass": CLOCK_1,
	"containment_armor": CLOCK_10,
	"cell_layers": CLOCK_11,
	"dielectric_thickness": CLOCK_2,
	"engine_displacement": CLOCK_1,
	"radiator_fins": CLOCK_10,
	"core_diameter": CLOCK_2,
	"heatsink_fins": CLOCK_7,
	"scan_arc": CLOCK_10,
	"seeker_size": CLOCK_11,
	"survey_radius": CLOCK_4,
	"skirt_diameter": CLOCK_1,
	"stabilizer_ring": CLOCK_2,
	"tread_width": CLOCK_4,
	"track_count": CLOCK_7,
	"tube_count": CLOCK_5,
	"turbine_compression": CLOCK_7,
	"warhead_size": CLOCK_8,
	"welder_count": CLOCK_10,
	"wheel_size": CLOCK_11,
	"wheels_per_axle": CLOCK_1,
	"wing_sweep": CLOCK_2,
	"wingspan": CLOCK_4,
	"ammo": CLOCK_5,
	"drone_type": CLOCK_12,
}


## Returns the station angle (fraction of TAU, clockwise from 12 o'clock) for
## a tweak name, or -1.0 if the name isn't in the table (a coverage gap - the
## caller should treat this as a bug to fix in TWEAK_ANGLES, not silently
## drop the tweak).
static func angle_for(tweak_name: String) -> float:
	return TWEAK_ANGLES.get(tweak_name, -1.0)


## True if a tweak name has a declared station.
static func has_station(tweak_name: String) -> bool:
	return TWEAK_ANGLES.has(tweak_name)


## Every outer-band station a set of tweak names claims, keeping angle
## grouped by radial tier: station index i within the returned list overflows
## to tier `i / OUTER_STATIONS.size()` at the same angle, tier computed by the
## caller (RingDraw/TweakStation) as station_distance + tier * panel_height.
static func tier_for(station_index_within_angle: int) -> int:
	return station_index_within_angle
