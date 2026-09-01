# TweakStations: clock-face station geometry for the module action ring.
# A tweak has no NAME-owned position - stations are claimed sequentially, so
# this file only supplies the face's angles and band lists.
#
# LAYOUT. Two bands:
#   - Inner band (verb wedges, unchanged): 12, 3, 6, 9 o'clock.
#   - Outer band (tweak dials): the full 12 clock positions, orbiting clear
#     of the verb band.
#
# Your position is an accident of authoring order. Dials fill by alternating
# sides as they work down from the top: 12, 1, 11, 2, 10, 3, 9, 4, 8, 5, 7,
# then 6 o'clock. A subsequent dial recycles to 12 o'clock on a second radial
# tier (tier = flat index / 12). Claiming lives in
# ModuleActionRing.add_tweak_station, which owns what is already placed.
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

# The inner band's verb wedges (drawn by RingDraw from the ring's action list).
# Informational only - the fill order below no longer avoids them.
const VERB_STATIONS := [CLOCK_12, CLOCK_3, CLOCK_6, CLOCK_9]

# The outer-band stations, in the order tweaks claim them: alternating sides
# down from the top, so a module's dials fan out evenly instead of hugging one
# side of the ring. 12 stations (one full face) before a dial wraps to a
# second radial tier.
const OUTER_STATIONS := [CLOCK_12, CLOCK_1, CLOCK_11, CLOCK_2, CLOCK_10, CLOCK_3, CLOCK_9, CLOCK_4, CLOCK_8, CLOCK_5, CLOCK_7, CLOCK_6]