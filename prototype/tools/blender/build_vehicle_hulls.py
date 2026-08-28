# build_vehicle_hulls.py - the vehicle hull catalogue: 14 manufacturers,
# 138 hulls. One bmesh per hull. Structural features (cabs, sponsons,
# casemates, wheel arches, outriggers) are part of the cross-section evolution
# that gets lofted through, not bolted-on chamfered boxes glued to the main
# body.
#
# Run:
#   cd prototype
#   & "C:\Program Files\Blender Foundation\Blender 5.2\blender.exe" --background \
#       --python tools/blender/build_vehicle_hulls.py
#   ./Godot_v4.7.1-stable_win64_console.exe --headless --editor --import
#
# Options after a `--` separator:
#   --only <id>[,<id>...]   build a subset (fast iteration)
#   --out <dir>             override the output directory
#   --list                  print the lineup and exit without touching Blender
#
# DESIGN CONTRACT
# ---------------
# Manufacturer owns the BODY STRUCTURE (which cross-section, which bulges,
# which tiers). Class owns the PROPORTIONS and the large role element. Variant
# owns one further structural change. No hull carries surface detail - no
# rivets, no panel lines, no bolt rings. Every silhouette difference is
# load-bearing geometry you could read as a black shape at 40 metres.
#
# SINGLE-MESH BUILDS
# ------------------
# Every body function builds ONE bmesh and exports it as one GLB. Structural
# features are integrated by:
#   - For bulges in the main body (wheel arches, cab roofs, sponson
#     shoulders): the cross-section has a fixed number of "stations" around
#     its perimeter and those stations move (up/down/in/out) as z progresses
#     so the feature grows out of the main body. loft_evolution() handles this.
#   - For tiered features (casemate on plinth, bulwark on deck): a SECOND
#     add_solid() in the same bmesh, placed so the tier's bottom face shares
#     a face with the body. Still one mesh, just with the tier as its own
#     loft. add_chamfered_box() / add_wedge() are the tiered helpers.
#
# The fourteen houses:
#
#   halvorsen  Boat hulls dragged ashore. Hard-chine section: wide flat deck
#              with bow flare (deck widens at bow), near-vertical topsides,
#              hard chine crease, steep deadrise to narrow flat keel. Raked
#              stem, high freeboard, continuous raised bulwark rim.
#
#   kestrel    Aircraft fuselages with the wings sawn off. Faceted eight-sided
#              tube with flat cargo floor, mid-fuselage swell (broad width
#              bulge at mid), stepped-down tail boom, vertical fin, angular
#              canopy at nose, thick wing-root stubs, dorsal spine ridge.
#
#   brenntal   Mobile bunkers. Dog-bone plan - wide plinth at nose and tail
#              pinched at mid-hull, T-section with narrower casemate offset
#              rearward. Casemate now ramps with sloped leading/trailing
#              faces (side view) and the lower plinth carries the chamfered
#              hexagonal rear and bulbous front.
#
#   tallow     Closed trucks. Boxy oct section with near-vertical cab rear
#              wall, flat cargo bed, paired wheel-arch flares (wide fender
#              bulges at two axle stations). Reads as mule/boxer at 40 m.
#
#   orrin      Symmetric salvage + wide belt. Tumblehome trapezoid (wider at
#              bottom, narrower at top) with a broad mid-height belt bulge at
#              mid-hull, plus centred dorsal spine/mast peak. No port/star-
#              board lean, so locomotion mounts stay clean.
#
#   rackham    Industrial crawler. Stout body with boiler barrel ridge on top,
#              deep radiator grille at nose, wide flat side-skirt flare at
#              mid-hull, full-length side rails at deck level, no curves.
#
#   calder     Fast-attack wedge. Low-slung, narrow at nose with nose flare,
#              widening to full-width at tail, mid side sponsons, rear wing,
#              optional barbette mesa and straight-bevel plan.
#
#   pillar     Modular boxy. Stacked chamfered cells with a wide flat mid-
#              ridge (broad width bulge) at mid-hull. Transport variants are
#              a 2x2 cell wall with open well; combat variants are solid stacks
#              with barbette and ridge.
#
#   hartmann   Real tanks. A proper MBT tub: narrow flat belly, lower sides
#              sloping out to a hard sponson crease, near-vertical sides up to
#              the deck. Blunt flat glacis bow (70% width at the tip, straight
#              bevel to full width - no point), long glacis rise in profile,
#              stepped rear engine deck. Most hulls carry an integrated turret
#              race mesa for module mounting.
#
#   ballard    Submarines. Faceted teardrop with bow sonar bulb (bulbous
#              forward widening), flat keel strip, bilge panels to max beam
#              below mid-height, slanted topsides to narrower deck. Blunt bow
#              growth, parallel midbody, eased stern taper. Conning sail mesa
#              on deck; periscope masts and missile trunks on top.
#
#   moreau     Wave-formers. Rounded superellipse section (flat keel chord),
#              both ends taper away (canoe/arrowhead/diamond plan), waist
#              pinch at midships, plus dorsal blister (broad height bump at
#              mid) for distinct Moreau read. Never touches bounding box.
#
#   durham     Regular trucks / APCs. Boxy oct section with near-vertical cab
#              rear wall, flat cargo bed. Reads as a mule/boxer/HEMTT at 40 m.
#
#   spectre    Arrowhead stealth. Sharp delta plan with straight bevel sides
#              meeting at a ~3-5% tip, low flat profile, optional canopy mesa.
#
#   hexton     Hexagonal prism, longer than wide. Flat-top hex section (6 facets),
#              blunt glacis bow, twin-tube heavy with cross-members and high
#              aft-cab transport variants.

import json
import math
import os
import sys

import bpy
import bmesh

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import hull_forge as HF  # noqa: E402


HULLS_DIR = os.path.join(
    os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__)))),
    "assets", "models", "hulls",
)


# ---------------------------------------------------------------------------
# Manufacturers
# ---------------------------------------------------------------------------

MANUFACTURERS = {
    "halvorsen": {
        "display": "Halvorsen Yard",
        "color": (0.376, 0.435, 0.415, 1.0),
    },
    "kestrel": {
        "display": "Kestrel Aeroworks",
        "color": (0.717, 0.729, 0.749, 1.0),
    },
    "brenntal": {
        "display": "Brenntal Schwerbau",
        "color": (0.298, 0.302, 0.322, 1.0),
    },
    "tallow": {
        "display": "Tallow & Vance",
        "color": (0.616, 0.482, 0.204, 1.0),
    },
    "orrin": {
        "display": "Orrin Collective",
        "color": (0.451, 0.341, 0.259, 1.0),
    },
    "rackham": {
        "display": "Rackham Forge",
        # A sooty iron grey with a warm tint - "industrial forge".
        "color": (0.340, 0.330, 0.310, 1.0),
    },
    "calder": {
        "display": "Calder Mobility",
        # A bright racing red - "fast attack".
        "color": (0.660, 0.190, 0.155, 1.0),
    },
    "pillar": {
        "display": "Pillar Ironworks",
        # A pale steel blue - "modular container".
        "color": (0.420, 0.490, 0.560, 1.0),
    },
    "hartmann": {
        "display": "Hartmann Panzerwerk",
        # Olive drab - the conventional-armour read.
        "color": (0.352, 0.392, 0.263, 1.0),
    },
    "ballard": {
        "display": "Ballard Deepworks",
        # A deep sea-water teal.
        "color": (0.216, 0.329, 0.373, 1.0),
    },
    "moreau": {
        "display": "Moreau Yards",
        # Pale bone - the ocean-liner register.
        "color": (0.780, 0.745, 0.660, 1.0),
    },
    "durham": {
        "display": "Durham Motors",
        # Flat utilitarian tan-grey - regular workhorse truck/APC.
        "color": (0.523, 0.498, 0.412, 1.0),
    },
    "spectre": {
        "display": "Spectre Dynamics",
        # Matte stealth grey with cold blue tint.
        "color": (0.388, 0.412, 0.435, 1.0),
    },
    "hexton": {
        "display": "Hexton Works",
        # Cool industrial teal-grey - hexagonal prism read.
        "color": (0.415, 0.482, 0.498, 1.0),
    },
}

CLASSES = ["scout", "light", "medium", "heavy", "transport", "oddball"]


# ---------------------------------------------------------------------------
# Bodies - one per manufacturer. Every body function is ONE add_solid() call
# (or loft_evolution() sampling one section function). The cross-section at
# every z is a single closed polygon, and the structural features (cabs,
# casemates, sponsons, outriggers, wheel arches) are part of the cross-
# section's evolution as z progresses, not bolted-on chamfered boxes.
#
# Discipline that makes the single-mesh work:
#   1. The cross-section has a FIXED number of vertices at every z (so the
#      loft between sections is well-defined). Features that are only present
#      in a z range have their vertices positioned at the "inactive" location
#      outside the range, and at the "active" location inside, with smooth
#      transitions in between.
#   2. The bottom of the cross-section is always at y = -h/2 (the hull's
#      underside). Locomotion mounts at the underside therefore work on every
#      hull uniformly, regardless of body shape.
#   3. The front of the hull rises up out of the flat underside as a sloped
#      face (a glacis), not as a dropping keel. Nose drops are small, kept
#      under 0.3*h, so a Halvorsen or Brenntal bow never reaches below the
#      underside plane.
#   4. Non-convex cross-sections (e.g. the Brenntal T-shape with plinth
#      shoulders + narrower casemate on top) are supported. hull_forge's
#      add_solid() now triangulates quads that fail to create, so a T-shape
#      with a real shoulder produces a closed, single-mesh surface.
#
# Role elements (masts, fins, ridges) stay as separate add_chamfered_box() /
# add_ridge() in the same bmesh - they are small thin features on top of
# the body, and treating them as part of the cross-section would force the
# outline to carry a tall vertical spike for a small mast, distorting the
# rest of the silhouette.
# ---------------------------------------------------------------------------

# --- HALVORSEN YARD ---------------------------------------------------------

def _halvorsen_section(z, hw, hl, w, h, l, chine, keel, deck_cut, rim_h,
                       bow_drop, flare_frac, flare_zc, flare_zw, oc=None):
    """Cross-section for Halvorsen at a given z.

    A chine outline is the base, sized to fit the hull's height fraction at
    this z. The keel is always at y = -h/2 (flat underside, no rake), the
    deck is at y = -h/2 + h_frac*h, the chine is in between. The bulwark rim
    is integrated as a small upward bulge of the deck top edges in the
    mid-z range. A bow flare widens the deck at the bow (top-down flare),
    giving the boat its raked stem read without a separate solid.

    h_frac(z) is the body's vertical fill at this z. At the very bow it is
    small (the bow rises out of the flat underside as a sloped face, not a
    dropping keel), at the middle it is full, at the stern it dips slightly.
    The cross-section outline has constant point count (10 vertices for the
    chine_outline + 2 deck-top points that the rim lives on).
    """
    # Height fraction along z. Front rises out of the flat underside as a
    # sloped face (no nose drop), middle is full, stern dips a little.
    if z <= -hl:
        h_frac = 0.30
    elif z <= -hl + l * 0.18:
        t = (z - (-hl)) / (l * 0.18)
        h_frac = 0.30 + (1.00 - 0.30) * t
    elif z <= hl - l * 0.16:
        h_frac = 1.00
    else:
        t = (z - (hl - l * 0.16)) / (l * 0.16)
        h_frac = 1.00 - 0.15 * t

    # Width fraction - hull narrows at the bow and stern slightly
    if z <= -hl:
        w_frac = 0.70
    elif z <= -hl + l * 0.18:
        t = (z - (-hl)) / (l * 0.18)
        w_frac = 0.70 + 0.30 * t
    elif z <= hl - l * 0.16:
        w_frac = 1.00
    else:
        w_frac = 0.95

    # Integrated outcrops - grown into the loft by modulating the section
    # height/width along z, never bolted on. Bigger hulls pass larger
    # magnitudes, so they read as more heavily structured.
    if oc:
        block_t = HF.smooth_transition(z, oc["block_zc"], oc["block_zw"]) if oc["block_h"] > 1e-6 else 0.0
        h_frac = min(1.7, h_frac + oc["block_h"] * block_t)
        boss_t = HF.smooth_transition(z, oc["boss_zc"], oc["boss_zw"]) if oc["boss_d"] > 1e-6 else 0.0
        w_frac = min(1.5, w_frac + oc["boss_d"] * boss_t)
        pad_t = HF.smooth_transition(z, oc["pad_zc"], oc["pad_zw"]) if oc["pad_h"] > 1e-6 else 0.0
        h_frac = min(1.7, h_frac + oc["pad_h"] * pad_t)

    h_active = h * h_frac
    # Bow flare - deck widens at the bow, keel stays narrow.
    flare_t = HF.smooth_transition(z, flare_zc, flare_zw) if flare_frac > 1e-6 else 0.0
    w_deck_eff = w * w_frac * (1.0 + flare_frac * flare_t)
    w_keel_eff = w * w_frac * keel
    # Centre the chine outline so the keel is at -h/2 (flat underside) and
    # the deck is at -h/2 + h_active.
    cy = h_active / 2.0 - h / 2.0

    base = HF.chine_outline(
        w_deck=w_deck_eff, w_keel=w_keel_eff,
        h=h_active, chine_frac=chine, cy=cy, deck_cut=deck_cut,
    )
    if rim_h <= 1e-6:
        return base
    # Lift the top deck-edge points to form the bulwark rim. chine_outline's
    # top is a pair of deck-edge points; raise them by rim_h and chamfer the
    # rim corners to match the deck chamfer. Outside the rim's z range the
    # lift is zero, so the deck is flat.
    deck_top_y = -h / 2.0 + h_active - deck_cut
    lifted = []
    for (x, y) in base:
        if y > deck_top_y - deck_cut * 0.6:
            lifted.append((x, y + rim_h))
        else:
            lifted.append((x, y))
    return lifted


def body_halvorsen(bm, w, h, l, opt):
    """Hard-chine boat section, flat keel, integrated bulwark rim + bow flare.

    ONE loft. The cross-section's keel is always at y = -h/2, the deck is
    at -h/2 + h_frac(z)*h. Bow flare widens the deck at the bow (top-down
    read) without moving the keel. The bow rises out of the flat underside
    as a sloped face (no nose drop), the middle is full height, the stern
    dips slightly. The bulwark rim is part of the cross-section, not bolted
    on.
    """
    hl = l / 2.0
    chine = opt.get("chine_frac", 0.42)
    keel = opt.get("keel_frac", 0.34)
    deck_cut = w * 0.055
    rim_h = h * opt.get("bulwark_h", 0.17) if opt.get("bulwark", True) else 0.0
    bow_drop = opt.get("bow_drop", 0.0)  # kept for backward compat, ignored
    flare_frac = opt.get("flare", 0.16)
    flare_zc = hl * opt.get("flare_zc", -0.58)
    flare_zw = l * opt.get("flare_zw", 0.14)

    # Outcrops scale with hull size so larger hulls carry more structure.
    oc = {
        "block_h": opt.get("block_h", 0.0),
        "block_zc": hl * opt.get("block_zc", -0.10),
        "block_zw": l * opt.get("block_zw", 0.20),
        "boss_d": opt.get("boss_d", 0.0),
        "boss_zc": hl * opt.get("boss_zc", 0.0),
        "boss_zw": l * opt.get("boss_zw", 0.34),
        "pad_h": opt.get("pad_h", 0.0),
        "pad_zc": hl * opt.get("pad_zc", 0.0),
        "pad_zw": l * opt.get("pad_zw", 0.12),
    }

    def sec(z):
        return _halvorsen_section(
            z, w / 2.0, hl, w, h, l, chine, keel, deck_cut, rim_h, bow_drop,
            flare_frac, flare_zc, flare_zw, oc,
        )

    HF.loft_evolution(bm, -hl, hl, sec, n_sections=10, cap_chamfer=min(w, h) * 0.10)


# --- KESTREL AEROWORKS ------------------------------------------------------

def _kestrel_section(z, hw, hl, w, h, l, fuse_w, cut, boom_frac, boom_z,
                     stub_w, stub_z, stub_l, wing_root_h, canopy_h,
                     spine_h, spine_zw, swell_frac, swell_zc, swell_zw):
    """Cross-section for Kestrel at a given z.

    A flat-floor octagon is the base, sized to fit the hull's fraction at
    this z. Wing-root stubs are integrated as side bulges in the cross-
    section in the mid-z range (the fuselage is inset to leave room for
    them, then widens back out). The canopy is a centered top peak in
    the nose region. The optional dorsal spine is a wider, lower top
    ridge in the mid-z range (vertex 4 and 6 also rise, so the top is
    a flat ridge from v4 to v6). The tail boom is a stepped narrowing
    at the rear.

    Outline vertices, clockwise from bottom-left, when the tail boom is
    narrow:
      0: bottom-left, at the flat floor y
      1: bottom-right, at the flat floor y
      2: right side lower
      3: right side upper
      4: right stub top / right spine side
      5: top center (canopy or spine peak)
      6: left stub top / left spine side
      7: left side upper
      8: left side lower

    The bottom edge (vertices 0-1) is always at y = -h/2 (flat floor).
    The top edge rises and falls as the canopy/spine grows and shrinks.
    """
    # Width and height of the fuselage, with stepped tail boom
    if z <= -hl:
        fw = 0.46
        fh = 0.50
    elif z <= -hl + l * 0.14:
        t = (z - (-hl)) / (l * 0.14)
        fw = 0.46 + (0.80 - 0.46) * t
        fh = 0.50 + (0.84 - 0.50) * t
    elif z <= -hl + l * 0.34:
        t = (z - (-hl + l * 0.14)) / (l * 0.20)
        fw = 0.80 + (1.00 - 0.80) * t
        fh = 0.84 + (1.00 - 0.84) * t
    elif z <= hl * boom_z - l * 0.06:
        fw = 1.00
        fh = 1.00
    elif z <= hl * boom_z:
        # Hard step - fuselage narrows in one jump at the empennage joint.
        t = (z - (hl * boom_z - l * 0.06)) / (l * 0.06)
        fw = 1.00 + (boom_frac - 1.00) * t
        fh = 1.00 + (boom_frac + 0.06 - 1.00) * t
    else:
        fw = boom_frac
        fh = boom_frac + 0.06

    # Inset fuselage width to make room for wing-root stub bulges in the
    # stub region. Outside the stub region, full width.
    in_stub = abs(z - stub_z) < stub_l / 2.0
    if in_stub:
        # Stub region: full width (stub bulges are outboard of fuse)
        full_w = w * fw
    else:
        # Outside stub region: inset by 2*stub_w on the sides
        full_w = w * fw - 2.0 * stub_w
    # Mid-fuselage swell - wide lateral bulge at mid (distinct Kestrel language)
    swell_t = HF.smooth_transition(z, swell_zc, swell_zw) if swell_frac > 1e-6 else 0.0
    full_w *= 1.0 + swell_frac * swell_t
    full_h = h * fh

    # Canopy bulge: a centered top peak in the canopy z range.
    in_canopy = z <= -hl + l * 0.30
    canopy_top = canopy_h if in_canopy else 0.0

    # Dorsal spine: a wider, lower top ridge in the mid-z range. The
    # spine widens the top (vertices 4 and 6 also rise to the same height
    # as vertex 5), so the silhouette has a flat ridge from v4 to v6
    # rather than a single peak at v5.
    in_spine = abs(z) < spine_zw
    spine_top = spine_h if in_spine else 0.0

    top_bulge = max(canopy_top, spine_top)
    top_widen = spine_top > 0.0 and canopy_top <= 0.0

    return _flat_floor_with_top_bulge(
        full_w, full_h, cut, top_bulge, top_widen,
    )


def _flat_floor_with_top_bulge(w, h, cut, top_bulge, widen=False):
    """Flat-floor octagon outline with an optional centered top bulge.

    9 vertices always. The bottom is at y = -h/2 (flat floor). When
    top_bulge = 0, the top is a flat octagon. When top_bulge > 0, the
    top center (vertex 5) rises by top_bulge. When widen is also True,
    the top sides (vertices 4 and 6) rise to the same height as vertex 5,
    forming a flat ridge from v4 to v6 (the dorsal-spine look). When
    widen is False, only v5 rises (the canopy look - a single peak).
    """
    hw, hh = w / 2.0, h / 2.0
    c = min(cut, hw * 0.7, hh * 0.7)
    floor_y = -hh
    side_top_y = hh - c
    if top_bulge > 1e-6:
        if widen:
            bulged_top_y = hh + top_bulge - c
            center_y = hh + top_bulge
        else:
            bulged_top_y = side_top_y
            center_y = side_top_y + top_bulge
    else:
        bulged_top_y = side_top_y
        center_y = side_top_y
    floor_half = hw - c * 0.35
    return [
        (-floor_half, floor_y),       # 0: bottom-left
        (floor_half, floor_y),        # 1: bottom-right
        (hw, floor_y + c * 0.8),      # 2: right side lower
        (hw, side_top_y),             # 3: right side upper
        (hw - c, bulged_top_y),       # 4: right stub top / bulge right
        (0, center_y),                # 5: top center (raised by bulge)
        (-hw + c, bulged_top_y),      # 6: left stub top / bulge left
        (-hw, side_top_y),            # 7: left side upper
        (-hw, floor_y + c * 0.8),     # 8: left side lower
    ]


def body_kestrel(bm, w, h, l, opt):
    """Faceted eight-sided fuselage, stepped tail boom, integrated wing
    stubs and canopy/spine bulge, flat floor.

    ONE loft. The cross-section is a flat-floor octagon with optional
    side bulges for wing-root stubs and a centered top bulge for the
    canopy or dorsal spine. The fuselage narrows at the tail boom in a
    hard step.
    """
    hl = l / 2.0
    boom_frac = opt.get("boom_frac", 0.52)
    boom_z = opt.get("boom_z", 0.30)
    stub_frac = opt.get("stub_w", 0.15)
    stub_w = w * stub_frac
    stub_l = l * opt.get("stub_l", 0.24)
    stub_z = hl * opt.get("stub_z", -0.10)
    wing_root_h = h * 0.34
    cut = min(w, h) * opt.get("facet_cut", 0.26)
    fuse_w = w * (1.0 - 2.0 * stub_frac * 0.88)
    canopy_h = h * 0.30 if opt.get("canopies", (-0.52,)) else 0.0
    spine_h = h * opt.get("spine_h", 0.0)
    spine_zw = l * opt.get("spine_zw", 0.0)
    swell_frac = opt.get("swell", 0.09)
    swell_zc = hl * opt.get("swell_zc", 0.05)
    swell_zw = l * opt.get("swell_zw", 0.20)

    def sec(z):
        return _kestrel_section(
            z, w / 2.0, hl, w, h, l, fuse_w, cut, boom_frac, boom_z,
            stub_w, stub_z, stub_l, wing_root_h, canopy_h,
            spine_h, spine_zw, swell_frac, swell_zc, swell_zw,
        )

    HF.loft_evolution(bm, -hl, hl, sec, n_sections=10, cap_chamfer=cut * 0.7)

    # Tail fin - small thin element on top, still a tiered add_solid in the
    # same bmesh (the fin is too thin to fit in the cross-section without
    # distorting the fuselage).
    if opt.get("fin", True):
        fin_h = h * opt.get("fin_h", 0.42)
        HF.add_solid(
            bm,
            [(hl - l * 0.30, HF.trap_outline(w * 0.14, w * 0.07, fin_h,
                                            cy=fin_h / 2.0 - h * 0.04,
                                            cx=0.0)),
             (hl - l * 0.02, HF.trap_outline(w * 0.11, w * 0.05, fin_h * 0.8,
                                             cy=fin_h * 0.4 - h * 0.04,
                                             cx=0.0))],
            cap_chamfer=w * 0.035,
        )


# --- BRENNTAL SCHWERBAU -----------------------------------------------------

def _brenntal_section(z, hl, w, h, l, plinth_w, casemate_w, casemate_h, cut,
                     glacis_z_frac, casemate_z_frac, casemate_l_frac,
                     tiers, top_cap_h, top_cap_l, top_cap_w,
                     waist, waist_zc, waist_zw):
    """Cross-section for Brenntal at a given z - reworked to the sketch.

    Top-down: dog-bone plan. Lower plinth is wide at nose and tail, pinched
    at mid-hull by `waist` (Moreau-style) so the hull reads as two pads
    joined by a narrow spine — the left sketch's top view.

    Front elevation: bulbous lower plinth with flat underside at y=-h/2,
    chamfered shoulders, and a narrow centred casemate mesa on top — middle
    sketch's T-shape.

    Side elevation: long glacis bow rise, full-height mid, slight tail dip;
    the casemate now ramps with HF.smooth_transition so its leading/trailing
    faces are sloped (right sketch) not a vertical step.

    The bottom of the cross-section is at y = -h/2 (flat underside, no
    drop). The bow rises out of the flat underside as a sloped face.
    """
    # Height fraction along z. Bow rises as a glacis, full at the casemate,
    # medium at the rear.
    if z <= -hl:
        h_frac = 0.20  # bow is short, sloped face
    elif z <= -hl + l * glacis_z_frac:
        t = (z - (-hl)) / max(l * glacis_z_frac, 1e-6)
        h_frac = 0.20 + 0.80 * t  # ramps from 0.20 to 1.00
    elif z <= hl - l * casemate_l_frac:
        h_frac = 1.00
    else:
        t = (z - (hl - l * casemate_l_frac)) / max(l * casemate_l_frac, 1e-6)
        h_frac = 1.00 - 0.35 * t  # back end dips to 0.65

    # Width fraction. Bow slightly narrower, plus dog-bone waist at mid.
    if z <= -hl:
        w_frac = 0.92
    elif z <= -hl + l * glacis_z_frac:
        t = (z - (-hl)) / max(l * glacis_z_frac, 1e-6)
        w_frac = 0.92 + 0.08 * t
    else:
        w_frac = 1.00
    # Pinch at waist - top-down dog-bone (sketch left)
    w_frac *= 1.0 - waist * HF.smooth_transition(z, waist_zc, waist_zw)

    # Casemate present factor - smooth, not binary, so side elevation ramps.
    cas_center = -hl + l * casemate_z_frac
    cas_half = l * casemate_l_frac / 2.0
    cas_active = HF.smooth_transition(z, cas_center, cas_half)

    # Plinth top y, casemate top y. Bottom is always at -h/2 (flat).
    plinth_top_y = -h / 2.0 + h * h_frac
    casemate_top_y = plinth_top_y + h * 0.30 * cas_active  # casemate is 30% of h tall, sloped
    if top_cap_h > 0.0:
        # Top cap (a tier) - small box on top of the casemate. Same z range
        # as casemate, also sloped with it.
        cap_center = cas_center
        cap_half = l * (top_cap_l * 0.5)
        cap_active = HF.smooth_transition(z, cap_center, cap_half) * cas_active
        cap_top_y = casemate_top_y + h * top_cap_h * cap_active
    else:
        cap_top_y = casemate_top_y

    plinth_w_at = w * w_frac
    cas_w_at = plinth_w_at * casemate_w
    cap_w_at = cas_w_at * top_cap_w if top_cap_h > 0.0 else cas_w_at

    # 11-vertex T-shape cross-section. The casemate vertices collapse to
    # the plinth top when cas_active = 0, so the cross-section becomes a
    # flat-topped shape. When cas_active = 1, the casemate is a real
    # bulge on top of the plinth.
    c = cut
    return [
        (-plinth_w_at / 2.0 + c, -h / 2.0),                # 0: bottom-left
        (plinth_w_at / 2.0 - c, -h / 2.0),                 # 1: bottom-right
        (plinth_w_at / 2.0, -h / 2.0 + c),                 # 2: right lower
        (plinth_w_at / 2.0, plinth_top_y - c),              # 3: right shoulder
        (cas_w_at / 2.0, plinth_top_y),                     # 4: right notch
        (cas_w_at / 2.0, casemate_top_y - c * cas_active),  # 5: right casemate side
        (cap_w_at / 2.0, cap_top_y),                        # 6: right cap side (or casemate top)
        (-cap_w_at / 2.0, cap_top_y),                       # 7: left cap side (mirror)
        (-cas_w_at / 2.0, casemate_top_y - c * cas_active), # 8: left casemate side
        (-cas_w_at / 2.0, plinth_top_y),                    # 9: left notch
        (-plinth_w_at / 2.0, plinth_top_y - c),             # 10: left shoulder
        (-plinth_w_at / 2.0, -h / 2.0 + c),                 # 11: left lower
    ]


def body_brenntal(bm, w, h, l, opt):
    """Wide low plinth + narrower casemate on top + frontal glacis, all in
    ONE lofted solid - dog-bone plan rework.

    The cross-section is a T-shape with the wider plinth at the bottom
    (full width) and a narrower casemate on top. Casemate now ramps with
    smooth_transition so its front/rear are sloped in side view. Lower
    plinth pinches at mid-hull via waist (top-down dog-bone). Bottom is
    always at y=-h/2 (flat underside, no drop). Bow rises as sloped face.
    """
    hl = l / 2.0
    casemate_w = opt.get("casemate_w", 0.62)
    casemate_h = opt.get("casemate_h", 0.30)
    glacis_z_frac = opt.get("glacis_z", 0.20)
    casemate_z_frac = opt.get("casemate_z_frac", 0.58)
    casemate_l_frac = opt.get("casemate_l", 0.55)
    tiers = opt.get("tiers", 1)
    cut = min(w, h) * 0.11
    top_cap_h = opt.get("top_cap_h", 0.0)
    top_cap_l = opt.get("top_cap_l", 0.40)
    top_cap_w = opt.get("top_cap_w", 0.62)
    waist = opt.get("waist", 0.18)
    waist_zc = hl * opt.get("waist_zc", -0.02)
    waist_zw = l * opt.get("waist_zw", 0.22)

    def sec(z):
        return _brenntal_section(
            z, hl, w, h, l, 1.0, casemate_w, casemate_h, cut,
            glacis_z_frac, casemate_z_frac, casemate_l_frac, tiers,
            top_cap_h, top_cap_l, top_cap_w,
            waist, waist_zc, waist_zw,
        )

    HF.loft_evolution(bm, -hl, hl, sec, n_sections=12, cap_chamfer=cut)


# --- TALLOW & VANCE ---------------------------------------------------------

def _tallow_section(z, hl, l, w, h, frame_w, cab_l_frac, cab_h_frac, cab_w_frac,
                    cab_rake, cut, flare_frac, flare_z1, flare_zw1, flare_z2, flare_zw2,
                    oc):
    """Cross-section for Tallow at a given z, with outcrops grown into the
    single loft (NOT bolted-on parts).

    Constant 16-vertex outline, so the result is ONE continuous mesh. The
    cross-section is an octagon whose height varies along z (tall raked cab
    at the front, low flatbed at the rear, flat underside at y=-h/2). The
    outcrops are reserved vertex slots that collapse onto the base edge when
    inactive and rise into the body when active:

      * collar  - a raised octagonal NECK on the cab roof (turret seat). Grows
                  over the cab z-range; reads as "a turret mounts here".
      * boss    - a longitudinal bulge on each side (sponson shoulder / gun
                  mount). Grows over the mid body z-range.
      * rail    - the flatbed deck edge lifts into a perimeter RAIL lip over
                  the flatbed z-range (cargo/equipment runs along it).
      * plinth  - a raised PAD on the rear deck (module feet land here). Grows
                  over the rear z-range.

    Bigger hulls pass larger collar_h / boss_d / plinth_h / rail_h, so they
    simply carry more and larger outcrops - the structural diversity the
    catalogue was missing. Every outcrop height is derived from h (never w),
    so autofit() stays convergent.
    """
    cab_z_start = -hl
    cab_z_end = -hl + l * cab_l_frac
    flatbed_z_start = cab_z_end

    if z <= cab_z_start:
        h_frac = 0.40
    elif z <= cab_z_start + l * 0.04:
        t = (z - cab_z_start) / (l * 0.04)
        h_frac = 0.40 + (cab_h_frac * cab_rake - 0.40) * t
    elif z <= cab_z_end:
        t = (z - cab_z_start) / max(l * cab_l_frac, 1e-6)
        h_front = cab_h_frac * cab_rake
        h_back = cab_h_frac
        h_frac = h_front + (h_back - h_front) * t
    elif z <= flatbed_z_start + l * 0.04:
        t = (z - flatbed_z_start) / (l * 0.04)
        h_frac = cab_h_frac + (0.40 - cab_h_frac) * t
    else:
        h_frac = 0.40

    full_w = frame_w
    if flare_frac > 1e-6:
        t1 = HF.smooth_transition(z, flare_z1, flare_zw1)
        t2 = HF.smooth_transition(z, flare_z2, flare_zw2)
        full_w *= 1.0 + flare_frac * max(t1, t2)
    full_h = h * h_frac
    cy = full_h / 2.0 - h / 2.0

    # Outcrop activations along z (0..1)
    t_collar = HF.smooth_transition(z, oc["collar_zc"], oc["collar_zw"]) if oc["collar_h"] > 0 else 0.0
    t_boss = HF.smooth_transition(z, oc["boss_zc"], oc["boss_zw"]) if oc["boss_d"] > 0 else 0.0
    t_plinth = HF.smooth_transition(z, oc["plinth_zc"], oc["plinth_zw"]) if oc["plinth_h"] > 0 else 0.0
    t_rail = HF.smooth_transition(z, oc["rail_zc"], oc["rail_zw"]) if oc["rail_h"] > 0 else 0.0

    deck_y0 = cy + full_h
    deck_y = deck_y0 + oc["rail_h"] * t_rail
    collar_h = oc["collar_h"] * h * t_collar
    plinth_h = oc["plinth_h"] * h * t_plinth
    boss_d = oc["boss_d"] * w * t_boss

    hw = full_w / 2.0
    cx_ = min(cut, hw * 0.9)
    cy_ = min(cut, full_h * 0.9)
    y_bot = cy - full_h

    # Base octagon corners
    bl = (-hw + cx_, y_bot)
    br = ( hw - cx_, y_bot)
    rb = ( hw, y_bot + cy_)
    rt = ( hw, deck_y - cy_)
    tr = ( hw - cx_, deck_y)
    tl = (-hw + cx_, deck_y)
    lt = (-hw, deck_y - cy_)
    lb = (-hw, y_bot + cy_)

    # Side boss bulges (vertical right/left edges pushed outward in x)
    y_bot_edge = y_bot + cy_
    y_top_edge = deck_y - cy_
    y_b = cy - (full_h - cy_) * 0.30
    y_t = cy + (full_h - cy_) * 0.30
    rbb = (hw + boss_d, y_b)
    rbt = (hw + boss_d, y_t)
    lbb = (-hw - boss_d, y_b)
    lbt = (-hw - boss_d, y_t)

    # Deck-top peak slots (collar front, plinth rear). Inactive: sit on the
    # flat deck edge at monotonically descending x so the top edge stays a
    # straight line. collar_hw / plinth_hw are small enough (< the inactive
    # slot x) that an active peak never reorders the perimeter.
    deck_xR = hw - cx_
    span = deck_xR - (-hw + cx_)
    cR = (deck_xR - 0.15 * span, deck_y)
    cL = (deck_xR - 0.30 * span, deck_y)
    pR = (deck_xR - 0.55 * span, deck_y)
    pL = (deck_xR - 0.70 * span, deck_y)
    if collar_h > 1e-4:
        cR = (oc["collar_hw"] * w, deck_y + collar_h)
        cL = (-oc["collar_hw"] * w, deck_y + collar_h)
    if plinth_h > 1e-4:
        pR = (oc["plinth_hw"] * w, deck_y + plinth_h)
        pL = (-oc["plinth_hw"] * w, deck_y + plinth_h)

    # 16 vertices, counter-clockwise, constant count for every z
    return [bl, br, rb, rbb, rbt, rt, tr, cR, cL, pR, pL, tl, lt, lbt, lbb, lb]


def body_tallow(bm, w, h, l, opt):
    """Closed-body truck. Cab at the front, flatbed at the rear. ONE loft.

    The outcrops (collar neck, side bosses, bed rail, rear plinth) are grown
    into the loft via _tallow_section - there are no bolted-on elements, so
    the hull is a single continuous mesh. Bigger hulls pass larger outcrop
    heights, so they read as structurally richer (more mount-looking geometry)
    rather than a scaled copy of the small one.
    """
    hl = l / 2.0
    frame_w = w * opt.get("frame_w", 0.90)
    cab_l_frac = opt.get("cab_l", 0.26)
    cab_h_frac = opt.get("cab_h", 0.72)
    cab_w_frac = opt.get("cab_w", 0.94)
    cab_rake = opt.get("cab_rake", 0.66)
    cut = min(w, h) * 0.09
    flare_frac = opt.get("flare", 0.10)
    flare_z1 = hl * opt.get("flare_z1", -0.22)
    flare_zw1 = l * opt.get("flare_zw1", 0.10)
    flare_z2 = hl * opt.get("flare_z2", 0.52)
    flare_zw2 = l * opt.get("flare_zw2", 0.12)

    # Outcrop parameters. collar/boss/plinth/rail heights are fractions of
    # h or w; z-centres/widths are absolute z (Godot -Z is nose). Defaults
    # give a modest pickup; each LINEUP entry scales them up for bigger hulls.
    oc = {
        "collar_h": opt.get("collar_h", 0.0),
        "collar_hw": opt.get("collar_hw", 0.18),
        "collar_zc": opt.get("collar_zc", -hl + l * cab_l_frac * 0.5),
        "collar_zw": opt.get("collar_zw", l * cab_l_frac * 0.7),
        "boss_d": opt.get("boss_d", 0.0),
        "boss_zc": opt.get("boss_zc", 0.04 * l),
        "boss_zw": opt.get("boss_zw", 0.72 * l),
        "plinth_h": opt.get("plinth_h", 0.0),
        "plinth_hw": opt.get("plinth_hw", 0.10),
        "plinth_zc": opt.get("plinth_zc", 0.42 * l),
        "plinth_zw": opt.get("plinth_zw", 0.42 * l),
        "rail_h": opt.get("rail_h", 0.0),
        "rail_zc": opt.get("rail_zc", 0.30 * l),
        "rail_zw": opt.get("rail_zw", 0.95 * l),
    }

    def sec(z):
        return _tallow_section(
            z, hl, l, w, h, frame_w, cab_l_frac, cab_h_frac, cab_w_frac,
            cab_rake, cut, flare_frac, flare_z1, flare_zw1, flare_z2, flare_zw2,
            oc,
        )

    HF.loft_evolution(bm, -hl, hl, sec, n_sections=14, cap_chamfer=cut)


# --- ORRIN COLLECTIVE (symmetric, tumblehome) -------------------------------

def body_orrin(bm, w, h, l, opt):
    """Symmetric salvage with TUMBLEHOME cross-section - now with wide belt.

    BILATERALLY symmetric. ONE loft. The cross-section is a trapezoid
    (naval-architecture tumblehome): wider at the bottom (full w), narrower
    at the top (w * tumblehome_frac, default 0.80). A wide mid-height belt
    (broad flat bulge) widens the whole section at mid-hull for a distinct
    Orrin read. The bottom is always at y = -h/2 (flat underside, no drop).
    The bow rises out of the flat underside as a sloped face.

    Optional centered dorsal spine or tall mast is integrated as a 4-vertex
    mesa peak in its z range, so the peak is a cross-section bulge (not a
    separate add_chamfered_box bolted on top). Spine and mast are mutually
    exclusive - one peak per hull. The peak vertices are kept in the
    outline at every z, collapsed to a flat segment on the deck when not
    active, so the cross-section point count is constant for the loft.
    """
    hl = l / 2.0
    mass_w = w * opt.get("mass_w", 0.85)
    cut = min(w, h) * 0.09
    tumblehome_frac = opt.get("tumblehome_frac", 0.80)
    belt_frac = opt.get("belt", 0.09)
    belt_zc = hl * opt.get("belt_zc", 0.05)
    belt_zw = l * opt.get("belt_zw", 0.24)

    # Peak: a spine (wide + low) or a mast (narrow + tall). Mutually
    # exclusive - one peak per hull.
    spine_h_frac = opt.get("spine_h", 0.0)
    spine_w_frac = opt.get("spine_w", 0.0)
    spine_zc = hl * opt.get("spine_zc", 0.0)
    spine_zw = l * opt.get("spine_zw", 0.20)

    mast_h_frac = opt.get("mast_h", 0.0)
    mast_w_frac = opt.get("mast_w", 0.0)
    mast_zc = hl * opt.get("mast_zc", 0.10)
    mast_zw = l * opt.get("mast_zw", 0.05)

    if spine_h_frac > 0.0 and spine_w_frac > 0.0:
        peak_h = h * spine_h_frac
        peak_w = w * spine_w_frac
        peak_zc = spine_zc
        peak_zw = spine_zw
    elif mast_h_frac > 0.0 and mast_w_frac > 0.0:
        peak_h = h * mast_h_frac
        peak_w = w * mast_w_frac
        peak_zc = mast_zc
        peak_zw = mast_zw
    else:
        peak_h = 0.0
        peak_w = 0.0
        peak_zc = 0.0
        peak_zw = 0.0

    def sec(z):
        # Width and height fractions along z. Slight vertical squish at
        # the bow and stern.
        if z <= -hl:
            fw, fh = 0.52, 0.58
        elif z <= -hl + l * 0.24:
            t = (z - (-hl)) / (l * 0.24)
            fw = 0.52 + 0.48 * t
            fh = 0.58 + 0.42 * t
        elif z <= hl * 0.74:
            fw, fh = 1.00, 1.00
        else:
            t = (z - hl * 0.74) / (hl * 0.26)
            fw = 1.00 - 0.18 * t
            fh = 1.00 - 0.18 * t

        full_w = mass_w * fw
        # Wide belt - broad mid-hull width bulge
        if belt_frac > 1e-6:
            belt_t = HF.smooth_transition(z, belt_zc, belt_zw)
            full_w *= 1.0 + belt_frac * belt_t
        full_h = h * fh
        top_w = full_w * tumblehome_frac
        deck_y = -h / 2.0 + full_h

        t_peak = HF.smooth_transition(z, peak_zc, peak_zw) if peak_h > 0 else 0.0

        return _tumblehome_with_peak(
            full_w, full_h, top_w, deck_y, cut, peak_w, peak_h, t_peak,
        )

    HF.loft_evolution(bm, -hl, hl, sec, n_sections=12, cap_chamfer=cut)


def _tumblehome_with_peak(full_w, full_h, top_w, deck_y, cut, peak_w,
                            peak_h, t_peak):
    """Tumblehome trapezoid cross-section with optional centered peak.

    12 vertices ALWAYS (constant count for the loft). The bottom is at
    y = -h/2 with full width; the top is at deck_y with top_w (narrower
    than the bottom for tumblehome). When t_peak = 0, the 4 center
    vertices form a flat segment along the deck top, so the cross-section
    has no peak. When t_peak = 1, the 4 center vertices form a centered
    mesa bump (peak base on the deck, peak top at deck_y + peak_h).

    The smooth_transition() interpolation makes the peak grow smoothly
    out of the flat deck as z enters the peak region, and recede back to
    the flat deck as z leaves it.
    """
    hw = full_w / 2.0
    tw = top_w / 2.0
    floor_y = deck_y - full_h  # = -h/2 (the flat underside)
    ceiling_y = deck_y
    c = cut

    if peak_w > 0.0 and peak_h > 0.0:
        pw = peak_w / 2.0
        peak_y = ceiling_y + peak_h

        # Flat positions (t_peak = 0): the 4 peak vertices form a flat
        # segment along the deck top, between (tw - c) and (-tw + c).
        # Spacing them prevents degenerate faces in the loft.
        flat_outer_x = tw - c * 0.7
        flat_inner_x = c * 0.4

        # Active positions (t_peak = 1): the 4 peak vertices form a
        # centered mesa bump with base at pw and top at peak_y.
        v5_x = (1.0 - t_peak) * flat_outer_x + t_peak * pw
        v6_x = (1.0 - t_peak) * flat_inner_x + t_peak * pw
        v7_x = (1.0 - t_peak) * (-flat_inner_x) + t_peak * (-pw)
        v8_x = (1.0 - t_peak) * (-flat_outer_x) + t_peak * (-pw)
        v5_y = ceiling_y
        v6_y = (1.0 - t_peak) * ceiling_y + t_peak * peak_y
        v7_y = (1.0 - t_peak) * ceiling_y + t_peak * peak_y
        v8_y = ceiling_y
    else:
        # No peak possible - place the 4 vertices on the deck top.
        v5_x, v5_y = tw - c * 0.7, ceiling_y
        v6_x, v6_y = c * 0.4, ceiling_y
        v7_x, v7_y = -c * 0.4, ceiling_y
        v8_x, v8_y = -tw + c * 0.7, ceiling_y

    return [
        (-hw + c, floor_y),       # 0: bottom-left
        (hw - c, floor_y),        # 1: bottom-right
        (hw, floor_y + c),        # 2: right lower side
        (tw, ceiling_y),          # 3: right tumblehome top
        (tw - c, ceiling_y),      # 4: right deck top (chamfered)
        (v5_x, v5_y),             # 5: right peak base / flat
        (v6_x, v6_y),             # 6: right peak top / flat
        (v7_x, v7_y),             # 7: left peak top / flat
        (v8_x, v8_y),             # 8: left peak base / flat
        (-tw + c, ceiling_y),     # 9: left deck top (chamfered)
        (-tw, ceiling_y),         # 10: left tumblehome top
        (-hw, floor_y + c),       # 11: left lower side
    ]


# --- RACKHAM FORGE ----------------------------------------------------------

def _rackham_section(z, hl, l, w, h, cut, mast_w, mast_h, mast_zc, mast_zw,
                     skirt_frac, skirt_zc, skirt_zw):
    """Cross-section for Rackham at a given z.

    ONE loft. The cross-section is a chassis rectangle (octagon) at the
    bottom, with a centered boiler barrel bulge on top in the mid-z
    range, a taller radiator bulge in the front, and a smokestack bulge
    in the mid-rear. All bulges are part of the cross-section. A wide
    flat side skirt flares the chassis width at mid-hull for the distinct
    Rackham read.

    The optional centered mast is a tall thin vertical structure in the
    mast z range - integrated as a 4-vertex mesa peak in the cross-
    section, not bolted on. The mast sits on top of whatever is at the
    chassis top in that z range (chassis alone, boiler, or smokestack).

    12 vertices always. When the mast is not active, its 4 vertices
    form a flat segment along the bulged top, so the cross-section has
    no peak. When the mast is active, the 4 vertices form a centered
    mesa bump (base on the bulged top, peak at bulged_top + mast_h).
    """
    # Chassis height (constant)
    chassis_h = 0.46
    chassis_top_y = -h / 2.0 + h * chassis_h
    chassis_w_at_z = w * (0.92 if z > -hl + l * 0.14 else 0.88 + 0.04 * max(0, (z - (-hl)) / (l * 0.14)))
    # Wide side skirt flare at mid-hull
    if skirt_frac > 1e-6:
        skirt_t = HF.smooth_transition(z, skirt_zc, skirt_zw)
        chassis_w_at_z *= 1.0 + skirt_frac * skirt_t

    # Bulge heights: boiler in mid-z, radiator in front, smokestack mid-rear
    in_boiler = abs(z) < l * 0.32
    in_radiator = -hl <= z <= -hl + l * 0.20
    in_stack = abs(z - hl * 0.20) < l * 0.10

    boiler_top = h * 0.30 if in_boiler else 0.0
    rad_top = h * 0.40 if in_radiator else 0.0
    stack_top = h * 0.18 if in_stack else 0.0
    top_bulge = max(boiler_top, rad_top, stack_top)

    chassis_top_chamfered = chassis_top_y
    full_top_y = chassis_top_y + top_bulge

    # Mast peak - a 4-vertex mesa on top of the bulged top, active in
    # the mast z range. smooth_transition gives a soft ramp.
    t_mast = HF.smooth_transition(z, mast_zc, mast_zw) if mast_h > 0 else 0.0

    c = cut
    if mast_w > 0.0 and mast_h > 0.0:
        mw = mast_w / 2.0
        mast_peak_y = full_top_y + mast_h
        # Flat positions (t_mast = 0): 4 vertices on a flat segment along
        # the bulged top, ordered RIGHT-TO-LEFT (decreasing x) so each
        # face's bmesh normal points UP (+Y) and the glTF export flips
        # it to the convention (top faces DOWN, -Y).
        flat_outer_x = chassis_w_at_z * 0.30
        flat_inner_x = chassis_w_at_z * 0.08
        v5_x = (1.0 - t_mast) * flat_outer_x + t_mast * mw
        v6_x = (1.0 - t_mast) * flat_inner_x + t_mast * mw
        v7_x = (1.0 - t_mast) * (-flat_inner_x) + t_mast * (-mw)
        v8_x = (1.0 - t_mast) * (-flat_outer_x) + t_mast * (-mw)
        v5_y = full_top_y
        v6_y = (1.0 - t_mast) * full_top_y + t_mast * mast_peak_y
        v7_y = (1.0 - t_mast) * full_top_y + t_mast * mast_peak_y
        v8_y = full_top_y
    else:
        v5_x, v5_y = chassis_w_at_z * 0.30, full_top_y
        v6_x, v6_y = chassis_w_at_z * 0.08, full_top_y
        v7_x, v7_y = -chassis_w_at_z * 0.08, full_top_y
        v8_x, v8_y = -chassis_w_at_z * 0.30, full_top_y

    return [
        (-chassis_w_at_z / 2.0 + c, -h / 2.0),                # 0: bottom-left
        (chassis_w_at_z / 2.0 - c, -h / 2.0),                 # 1: bottom-right
        (chassis_w_at_z / 2.0, -h / 2.0 + c),                 # 2: right lower
        (chassis_w_at_z / 2.0, chassis_top_chamfered - c),    # 3: right chassis top
        (chassis_w_at_z / 2.0 - c, full_top_y),               # 4: right top (bulged)
        (v5_x, v5_y),                                         # 5: right mast base / flat
        (v6_x, v6_y),                                         # 6: right mast top / flat
        (v7_x, v7_y),                                         # 7: left mast top / flat
        (v8_x, v8_y),                                         # 8: left mast base / flat
        (-chassis_w_at_z / 2.0 + c, full_top_y),              # 9: left top (bulged)
        (-chassis_w_at_z / 2.0, chassis_top_chamfered - c),   # 10: left chassis top
        (-chassis_w_at_z / 2.0, -h / 2.0 + c),                # 11: left lower
    ]


def body_rackham(bm, w, h, l, opt):
    """Industrial crawler. ONE loft with integrated boiler, radiator,
    smokestack, optional centered mast and wide side skirt flare.
    Flat underside, no drop.
    """
    hl = l / 2.0
    cut = min(w, h) * 0.09
    mast_w = w * opt.get("mast_w", 0.0)
    mast_h = h * opt.get("mast_h", 0.0)
    mast_zc = hl * opt.get("mast_zc", 0.0)
    mast_zw = l * opt.get("mast_zw", 0.05)
    skirt_frac = opt.get("skirt", 0.10)
    skirt_zc = hl * opt.get("skirt_zc", 0.05)
    skirt_zw = l * opt.get("skirt_zw", 0.28)

    def sec(z):
        return _rackham_section(z, hl, l, w, h, cut, mast_w, mast_h,
                                mast_zc, mast_zw, skirt_frac, skirt_zc, skirt_zw)

    HF.loft_evolution(bm, -hl, hl, sec, n_sections=10, cap_chamfer=cut)


# --- CALDER MOBILITY --------------------------------------------------------

def _calder_section(z, hw, hl, l, w, h, body_w_min_frac, body_h_min_frac,
                    body_h_max_frac, cut, sponson_w, sponson_zc, sponson_zw):
    """Cross-section for Calder at a given z.

    Body is an octagon whose width and height grow linearly with z. Outside
    sponson_zw of sponson_zc, the body is inset (2*sponson_w narrower) so
    the sponson bulge can grow back out to full w inside the sponson region.
    The sponson is therefore a bulge in the body, not an add-on.
    """
    if z <= -hl:
        fw, fh = 0.55, 0.65
    elif z >= hl:
        fw, fh = 1.00, 1.00
    else:
        t = (z - (-hl)) / (2.0 * hl)
        fw = body_w_min_frac + (1.0 - body_w_min_frac) * t
        fh = body_h_min_frac + (body_h_max_frac - body_h_min_frac) * t

    sponson_active = abs(z - sponson_zc) < sponson_zw
    body_w_at = w if sponson_active else w - 2.0 * sponson_w
    full_w = body_w_at * fw
    return HF.oct_outline(full_w, h * fh, cut, cut,
                          cy=-h * 0.05 * (1.0 - fh))


def _calder_section(z, hl, l, w, h, body_w_min_frac, body_h_min_frac,
                    body_h_max_frac, cut, sponson_w, sponson_zc, sponson_zw,
                    wing_h_frac, barbette_w, barbette_h, barbette_zc,
                    barbette_zw, flare_frac, flare_zc, flare_zw):
    """Cross-section for Calder at a given z.

    The body width and height grow linearly with z. The body is inset
    by 2*sponson_w outside the sponson z range and full-width inside,
    so the sponsons are a width bulge in the mid-z. The rear wing
    is a top bulge in the rear. The optional centered barbette is a
    mesa bump on top of the chassis (or on top of the wing if both
    are active at this z) in the barbette z range - integrated as a
    4-vertex peak in the cross-section, not bolted on. A nose flare
    widens the forward hull for the wedge read.

    12 vertices always. When the barbette is not active, its 4 vertices
    form a flat segment along the bulged top, so the cross-section has
    no peak. When the barbette is active, the 4 vertices form a centered
    mesa bump (base on the bulged top, peak at bulged_top + barbette_h).
    """
    if z <= -hl:
        fw, fh = 0.55, 0.65
    elif z >= hl:
        fw, fh = 1.00, 1.00
    else:
        t = (z - (-hl)) / (2.0 * hl)
        fw = body_w_min_frac + (1.0 - body_w_min_frac) * t
        fh = body_h_min_frac + (body_h_max_frac - body_h_min_frac) * t

    in_sponson = abs(z - sponson_zc) < sponson_zw
    body_w_at = w if in_sponson else w - 2.0 * sponson_w
    full_w = body_w_at * fw
    # Nose flare - forward hull flare for wedge read
    if flare_frac > 1e-6:
        flare_t = HF.smooth_transition(z, flare_zc, flare_zw)
        full_w *= 1.0 + flare_frac * flare_t
    full_h = h * fh
    # Top: in the rear, add the wing as a centered top bulge.
    in_wing = z > hl * 0.55
    wing_top = wing_h_frac if in_wing else 0.0
    top_y = -h / 2.0 + full_h
    bulged_top_y = top_y + wing_top

    # Barbette peak - a 4-vertex mesa on top of the bulged top, active
    # in the barbette z range. smooth_transition gives a soft ramp.
    t_barbette = HF.smooth_transition(z, barbette_zc, barbette_zw) if barbette_h > 0 else 0.0

    c = cut
    if barbette_w > 0.0 and barbette_h > 0.0:
        bw = barbette_w / 2.0
        barbette_peak_y = bulged_top_y + barbette_h
        # Flat positions (t_barbette = 0): 4 vertices on a flat segment
        # along the bulged top, ordered RIGHT-TO-LEFT (decreasing x) so
        # each face's bmesh normal points UP (+Y) and the glTF export
        # flips it to the convention (top faces DOWN, -Y). The flat
        # positions are well inside the chamfered top corners (v4, v9)
        # so the interpolation to the active barbette base (bw) is a
        # smooth inward slide rather than a crossover.
        flat_outer_x = full_w * 0.30
        flat_inner_x = full_w * 0.08
        v5_x = (1.0 - t_barbette) * flat_outer_x + t_barbette * bw
        v6_x = (1.0 - t_barbette) * flat_inner_x + t_barbette * bw
        v7_x = (1.0 - t_barbette) * (-flat_inner_x) + t_barbette * (-bw)
        v8_x = (1.0 - t_barbette) * (-flat_outer_x) + t_barbette * (-bw)
        v5_y = bulged_top_y
        v6_y = (1.0 - t_barbette) * bulged_top_y + t_barbette * barbette_peak_y
        v7_y = (1.0 - t_barbette) * bulged_top_y + t_barbette * barbette_peak_y
        v8_y = bulged_top_y
    else:
        v5_x, v5_y = full_w * 0.30, bulged_top_y
        v6_x, v6_y = full_w * 0.08, bulged_top_y
        v7_x, v7_y = -full_w * 0.08, bulged_top_y
        v8_x, v8_y = -full_w * 0.30, bulged_top_y

    return [
        (-full_w / 2.0 + c, -h / 2.0),                 # 0: bottom-left
        (full_w / 2.0 - c, -h / 2.0),                  # 1: bottom-right
        (full_w / 2.0, -h / 2.0 + c),                  # 2: right lower
        (full_w / 2.0, top_y - c),                      # 3: right top (chamfered)
        (full_w / 2.0 - c, bulged_top_y),               # 4: right top (bulged)
        (v5_x, v5_y),                                  # 5: right barbette base / flat
        (v6_x, v6_y),                                  # 6: right barbette top / flat
        (v7_x, v7_y),                                  # 7: left barbette top / flat
        (v8_x, v8_y),                                  # 8: left barbette base / flat
        (-full_w / 2.0 + c, bulged_top_y),              # 9: left top (bulged)
        (-full_w / 2.0, top_y - c),                     # 10: left top (chamfered)
        (-full_w / 2.0, -h / 2.0 + c),                  # 11: left lower
    ]


def body_calder(bm, w, h, l, opt):
    """Fast-attack wedge. ONE loft with integrated sponson bulges,
    rear wing, optional barbette and nose flare. Flat underside,
    no drop. Body narrows at the nose.
    """
    hl = l / 2.0
    body_w_min_frac = opt.get("body_w_min", 0.55)
    body_h_min_frac = opt.get("body_h_min", 0.45)
    body_h_max_frac = opt.get("body_h_max", 0.78)
    cut = min(w, h) * 0.10
    sponson_w = w * opt.get("sponson_w", 0.18)
    sponson_zc = hl * opt.get("sponson_zc", 0.05)
    sponson_zw = l * opt.get("sponson_zw", 0.35)
    wing_h_frac = h * 0.06 if opt.get("wing", True) else 0.0
    barbette_w = w * opt.get("barbette_w", 0.0)
    barbette_h = h * opt.get("barbette_h", 0.0)
    barbette_zc = hl * opt.get("barbette_zc", 0.0)
    barbette_zw = l * opt.get("barbette_zw", 0.05)
    flare_frac = opt.get("flare", 0.10)
    flare_zc = hl * opt.get("flare_zc", -0.58)
    flare_zw = l * opt.get("flare_zw", 0.16)

    def sec(z):
        return _calder_section(
            z, hl, l, w, h, body_w_min_frac, body_h_min_frac, body_h_max_frac,
            cut, sponson_w, sponson_zc, sponson_zw, wing_h_frac,
            barbette_w, barbette_h, barbette_zc, barbette_zw,
            flare_frac, flare_zc, flare_zw,
        )

    HF.loft_evolution(bm, -hl, hl, sec, n_sections=10, cap_chamfer=cut)


# --- PILLAR IRONWORKS -------------------------------------------------------

def _pillar_section(z, hl, l, w, h, transport_well, cut, barbette_w,
                     barbette_h, barbette_zc, barbette_zw,
                     ridge_frac, ridge_zc, ridge_zw):
    """Cross-section for Pillar at a given z.

    ONE loft. Combat variants are a single tall box (the modular cell
    stack reads as chamfered ridges in the silhouette) plus a wide
    mid-hull ridge (broad flat bulge) for distinct Pillar read.
    Transport variants are a U-shape (two side walls + a floor) - the
    cavity is part of the cross-section.

    Cell-stack look: the cross-section has step bulges on the sides
    that grow out and back in, like a stack of cells. Implemented as
    a periodic width modulation.

    The optional centered barbette (combat mode only) is a 4-vertex
    mesa peak on top of the box, integrated as a cross-section bulge.
    12 vertices for combat (8 base + 4 barbette). Transport mode is
    unchanged (U-shape, no barbette).
    """
    # Width modulation: stacked cells, each cell is l * 0.18 long
    cell_w_mod = 1.00 if (int((z + hl) / (l * 0.10)) % 2 == 0) else 0.96
    # Wide ridge - broad flat width bulge at mid (combat only)
    if not transport_well and ridge_frac > 1e-6:
        ridge_t = HF.smooth_transition(z, ridge_zc, ridge_zw)
        cell_w_mod *= 1.0 + ridge_frac * ridge_t

    if transport_well:
        # U-shape: two side walls + a thin floor at the underside
        wall_w = w * 0.30
        well_w = w - 2.0 * wall_w
        floor_thick = h * 0.10
        # The cross-section is a U with the floor at the bottom and walls
        # going up. The underside (floor bottom) is at -h/2, the wall tops
        # are at +h/2 - floor_thick.
        wall_top_y = -h / 2.0 + h - floor_thick
        floor_top_y = -h / 2.0 + floor_thick
        return [
            (-w / 2.0 + cut, -h / 2.0),                                # 0: floor BL
            (w / 2.0 - cut, -h / 2.0),                                 # 1: floor BR
            (w / 2.0, -h / 2.0 + cut),                                 # 2: floor right
            (w / 2.0, wall_top_y),                                     # 3: wall right top
            (w / 2.0 - wall_w, wall_top_y - cut),                      # 4: well right
            (w / 2.0 - wall_w, floor_top_y),                          # 5: well floor right
            (-w / 2.0 + wall_w, floor_top_y),                         # 6: well floor left
            (-w / 2.0 + wall_w, wall_top_y - cut),                     # 7: well left
            (-w / 2.0, wall_top_y),                                    # 8: wall left top
            (-w / 2.0, -h / 2.0 + cut),                                # 9: floor left
        ]
    else:
        # Solid box with cell-stack ridges, 12 vertices (8 base +
        # 4 barbette). The barbette is centered on top.
        full_w = w * cell_w_mod
        full_h = h
        top_y = full_h / 2.0  # = h/2 since full_h = h
        c = cut

        # Barbette peak - 4-vertex mesa on top of the box, active in
        # the barbette z range.
        t_barbette = HF.smooth_transition(z, barbette_zc, barbette_zw) if barbette_h > 0 else 0.0

        if barbette_w > 0.0 and barbette_h > 0.0:
            bw = barbette_w / 2.0
            barbette_peak_y = top_y + barbette_h
            # Flat positions (t_barbette = 0): 4 vertices on a flat
            # segment along the top, ordered RIGHT-TO-LEFT (decreasing
            # x) so each face's bmesh normal points UP (+Y) and the
            # glTF export flips it to the convention (top faces DOWN,
            # -Y). Positions are well inside the chamfered top corners
            # (v4, v9) so the interpolation to the active barbette base
            # (bw) is a smooth inward slide.
            flat_outer_x = full_w * 0.30
            flat_inner_x = full_w * 0.08
            v5_x = (1.0 - t_barbette) * flat_outer_x + t_barbette * bw
            v6_x = (1.0 - t_barbette) * flat_inner_x + t_barbette * bw
            v7_x = (1.0 - t_barbette) * (-flat_inner_x) + t_barbette * (-bw)
            v8_x = (1.0 - t_barbette) * (-flat_outer_x) + t_barbette * (-bw)
            v5_y = top_y
            v6_y = (1.0 - t_barbette) * top_y + t_barbette * barbette_peak_y
            v7_y = (1.0 - t_barbette) * top_y + t_barbette * barbette_peak_y
            v8_y = top_y
        else:
            v5_x, v5_y = full_w * 0.30, top_y
            v6_x, v6_y = full_w * 0.08, top_y
            v7_x, v7_y = -full_w * 0.08, top_y
            v8_x, v8_y = -full_w * 0.30, top_y

        return [
            (-full_w / 2.0 + c, -h / 2.0),                # 0: bottom-left
            (full_w / 2.0 - c, -h / 2.0),                 # 1: bottom-right
            (full_w / 2.0, -h / 2.0 + c),                 # 2: right lower
            (full_w / 2.0, top_y - c),                     # 3: right top (chamfered)
            (full_w / 2.0 - c, top_y),                     # 4: right top (flat)
            (v5_x, v5_y),                                 # 5: right barbette base / flat
            (v6_x, v6_y),                                 # 6: right barbette top / flat
            (v7_x, v7_y),                                 # 7: left barbette top / flat
            (v8_x, v8_y),                                 # 8: left barbette base / flat
            (-full_w / 2.0 + c, top_y),                    # 9: left top (flat)
            (-full_w / 2.0, top_y - c),                    # 10: left top (chamfered)
            (-full_w / 2.0, -h / 2.0 + c),                 # 11: left lower
        ]


def body_pillar(bm, w, h, l, opt):
    """Modular boxy. ONE loft, flat underside, no drop.

    Combat variants are a single tall box (12-vertex cross-section with
    optional centered barbette mesa and wide mid ridge, the cell-stack
    reads as chamfered ridges in the silhouette). Transport variants are
    a U-shape (two side walls + a floor), with the cavity as part of the
    cross-section.
    """
    hl = l / 2.0
    cut = min(w, h) * 0.12
    transport_well = opt.get("transport_well", False)
    barbette_w = w * opt.get("barbette_w", 0.0)
    barbette_h = h * opt.get("barbette_h", 0.0)
    barbette_zc = hl * opt.get("barbette_zc", 0.0)
    barbette_zw = l * opt.get("barbette_zw", 0.05)
    ridge_frac = 0.0 if transport_well else opt.get("ridge", 0.10)
    ridge_zc = hl * opt.get("ridge_zc", 0.08)
    ridge_zw = l * opt.get("ridge_zw", 0.26)

    def sec(z):
        return _pillar_section(z, hl, l, w, h, transport_well, cut,
                                 barbette_w, barbette_h, barbette_zc,
                                 barbette_zw, ridge_frac, ridge_zc, ridge_zw)

    HF.loft_evolution(bm, -hl, hl, sec, n_sections=10, cap_chamfer=cut)


# --- HARTMANN PANZERWERK ----------------------------------------------------

def _hartmann_section(z, hl, l, w, h, cut, nose_frac, tip_w, belly_frac,
                      sill_frac, engine_z, engine_drop,
                      race_w, race_h, race_zc, race_zw):
    """Cross-section for Hartmann at a given z.

    A proper tank tub: narrow flat belly at y = -h/2, lower sides sloping
    out to a hard sponson crease (the "chine" of the tub), near-vertical
    sides up to the deck. The PLAN view is a blunt glacis bow: width
    fraction stays ~70% at the tip and widens with a STRAIGHT bevel to
    full width over the front `nose_frac` of the length — no arrowhead
    point — holds full width through mid-hull, then tapers slightly at the
    stern. Height rises out of the bow tip as one long glacis ramp and
    drops one step for the rear engine deck. An optional turret race is
    integrated as a 4-vertex mesa on the deck (collapsed flat when
    inactive), same pattern as Orrin/Calder.

    12 vertices always.
    """
    # Plan-view width fraction - blunt glacis, not a point.
    nose_len = l * nose_frac
    if z <= -hl:
        fw = tip_w
    elif z <= -hl + nose_len:
        t = (z + hl) / nose_len
        fw = tip_w + (1.0 - tip_w) * t
    elif z >= hl - l * 0.10:
        t = (z - (hl - l * 0.10)) / (l * 0.10)
        fw = 1.0 - 0.06 * t
    else:
        fw = 1.0

    # Height fraction - long glacis rise out of the bow tip, engine-deck
    # step down at the rear.
    if z <= -hl:
        fh = 0.26
    elif z <= -hl + nose_len:
        t = (z + hl) / nose_len
        fh = 0.26 + 0.74 * t
    elif z <= hl * engine_z:
        fh = 1.00
    else:
        t = (z - hl * engine_z) / max(hl * (1.0 - engine_z), 1e-6)
        fh = 1.00 - engine_drop * t

    W = w * fw
    Hh = h * fh
    floor_y = -h / 2.0
    deck_y = floor_y + Hh
    sill_y = floor_y + Hh * sill_frac
    bw = W * belly_frac / 2.0

    # Chamfers scale with THIS section's size, or the near-point bow would
    # self-intersect once W drops below the global cut.
    c = min(cut, W * 0.19, Hh * 0.22)
    bw = max(bw, c * 1.3)

    # Turret race mesa on the deck.
    t_race = HF.smooth_transition(z, race_zc, race_zw) if race_w > 0 else 0.0
    if race_w > 0 and t_race > 0.0:
        rw = min(W * race_w / 2.0, (W / 2.0 - c) * 0.90)
        rht = rw * 0.80
        RH = h * race_h * t_race
        v5_x, v5_y = rw, deck_y
        v6_x, v6_y = rht, deck_y + RH
        v7_x, v7_y = -rht, deck_y + RH
        v8_x, v8_y = -rw, deck_y
    else:
        # Flat positions: a segment along the deck, well inside the deck
        # chamfer corners (v4/v9), right-to-left so face normals point up.
        v5_x, v5_y = W * 0.30, deck_y
        v6_x, v6_y = W * 0.09, deck_y
        v7_x, v7_y = -W * 0.09, deck_y
        v8_x, v8_y = -W * 0.30, deck_y

    return [
        (-bw + c, floor_y),      # 0: belly port
        (bw - c, floor_y),       # 1: belly starboard
        (W / 2.0, sill_y),       # 2: starboard sponson crease
        (W / 2.0, deck_y - c),   # 3: starboard side top
        (W / 2.0 - c, deck_y),   # 4: starboard deck edge
        (v5_x, v5_y),            # 5: race right base / flat
        (v6_x, v6_y),            # 6: race right top / flat
        (v7_x, v7_y),            # 7: race left top / flat
        (v8_x, v8_y),            # 8: race left base / flat
        (-W / 2.0 + c, deck_y),  # 9: port deck edge
        (-W / 2.0, deck_y - c),  # 10: port side top
        (-W / 2.0, sill_y),      # 11: port sponson crease
    ]


def body_hartmann(bm, w, h, l, opt):
    """Real-tank hull. ONE loft: blunt glacis bow, tank-tub section with
    hard sponson crease, long frontal glacis rise, stepped rear engine deck,
    optional turret race as an integrated deck mesa. Flat underside."""
    hl = l / 2.0
    cut = min(w, h) * 0.09
    nose_frac = opt.get("nose_frac", 0.18)
    tip_w = opt.get("tip_w", 0.68)
    belly_frac = opt.get("belly_frac", 0.46)
    sill_frac = opt.get("sill_frac", 0.40)
    engine_z = opt.get("engine_z", 0.64)
    engine_drop = opt.get("engine_drop", 0.16)
    race_w = opt.get("race_w", 0.54)
    race_h = opt.get("race_h", 0.11) if race_w > 0 else 0.0
    race_zc = hl * opt.get("race_zc", -0.04)
    race_zw = l * opt.get("race_zw", 0.17)

    def sec(z):
        return _hartmann_section(
            z, hl, l, w, h, cut, nose_frac, tip_w, belly_frac, sill_frac,
            engine_z, engine_drop, race_w, race_h, race_zc, race_zw,
        )

    HF.loft_evolution(bm, -hl, hl, sec, n_sections=14, cap_chamfer=cut * 0.7)


# --- BALLARD DEEPWORKS ------------------------------------------------------

def _ballard_section(z, hl, l, w, h, cut, keel_frac, deck_frac, beam_frac,
                     sail_w, sail_h, sail_zc, sail_zw,
                     bow_frac, stern_start, stern_w, stern_h,
                     bulb_w, bulb_h, bulb_zc, bulb_zw):
    """Cross-section for Ballard at a given z - now with bow sonar bulb.

    A faceted teardrop pressure hull. The bottom is a FLAT KEEL strip at
    y = -h/2 (locomotion mounts still anchor to the AABB underside). Bilge
    panels flare from the keel edges up to maximum beam BELOW mid-height,
    then slanted topsides run in to a narrower top deck - the teardrop
    read. A bulbous bow bulb widens the forward hull for distinct Ballard
    read. The conning sail is a 4-vertex mesa on the deck, collapsed flat
    outside its z range. Width/height fractions give a blunt rounded bow
    growth, a long parallel midbody, and a stern that eases in to the
    propulsion gear in both axes.

    12 vertices always.
    """
    # Lengthwise evolution: bow growth, parallel midbody, stern taper.
    bow_len = l * bow_frac
    if z <= -hl:
        fw, fh = 0.16, 0.42
    elif z <= -hl + bow_len:
        t = (z + hl) / bow_len
        fw = 0.16 + 0.84 * (t * t)
        fh = 0.42 + 0.58 * t
    elif z <= hl * stern_start:
        fw, fh = 1.00, 1.00
    else:
        t = (z - hl * stern_start) / max(hl * (1.0 - stern_start), 1e-6)
        fw = 1.00 - (1.0 - stern_w) * (t * t)
        fh = 1.00 - (1.0 - stern_h) * t

    W = w * fw
    H = h * fh
    # Bow sonar bulb - bulbous forward widening
    if bulb_w > 1e-6 or bulb_h > 1e-6:
        bulb_t = HF.smooth_transition(z, bulb_zc, bulb_zw)
        W *= 1.0 + bulb_w * bulb_t
        H *= 1.0 + bulb_h * bulb_t
    floor_y = -h / 2.0
    deck_y = floor_y + H
    hw = W / 2.0
    kw = max(W * keel_frac / 2.0, 1e-3)
    beam_y = floor_y + H * beam_frac

    c = min(cut, kw * 0.55, H * 0.25)
    dx = hw * deck_frac

    # Conning sail mesa on the deck.
    sail_on = sail_w > 0 and sail_h > 0
    t_sail = HF.smooth_transition(z, sail_zc, sail_zw) if sail_on else 0.0
    if sail_on and t_sail > 0.0:
        sr = min(W * sail_w / 2.0, dx * 0.90)
        srt = sr * 0.72
        SH = h * sail_h * t_sail
        v6_x, v6_y = sr, deck_y
        v7_x, v7_y = srt, deck_y + SH
        v8_x, v8_y = -srt, deck_y + SH
        v9_x, v9_y = -sr, deck_y
    else:
        v6_x, v6_y = dx * 0.62, deck_y
        v7_x, v7_y = dx * 0.20, deck_y
        v8_x, v8_y = -dx * 0.20, deck_y
        v9_x, v9_y = -dx * 0.62, deck_y

    return [
        (-kw + c, floor_y),     # 0: keel port
        (kw - c, floor_y),      # 1: keel starboard
        (hw, floor_y + c),      # 2: starboard bilge
        (hw, beam_y),           # 3: starboard maximum beam
        (dx, deck_y),           # 4: starboard deck edge
        (v6_x, v6_y),           # 5: sail right base / flat
        (v7_x, v7_y),           # 6: sail right top / flat
        (v8_x, v8_y),           # 7: sail left top / flat
        (v9_x, v9_y),           # 8: sail left base / flat
        (-dx, deck_y),          # 9: port deck edge
        (-hw, beam_y),          # 10: port maximum beam
        (-hw, floor_y + c),     # 11: port bilge
    ]


def body_ballard(bm, w, h, l, opt):
    """Submarine hull. ONE loft: faceted teardrop with flat keel, blunt
    bow growth, bulbous sonar bow, parallel midbody, eased stern taper,
    integrated conning sail. Flat underside."""
    hl = l / 2.0
    cut = min(w, h) * 0.09
    keel_frac = opt.get("keel_frac", 0.36)
    deck_frac = opt.get("deck_frac", 0.62)
    beam_frac = opt.get("beam_frac", 0.46)
    sail_w = opt.get("sail_w", 0.30)
    sail_h = opt.get("sail_h", 0.34) if sail_w > 0 else 0.0
    sail_zc = hl * opt.get("sail_zc", -0.18)
    sail_zw = l * opt.get("sail_zw", 0.09)
    bow_frac = opt.get("bow_frac", 0.20)
    stern_start = opt.get("stern_start", 0.46)
    stern_w = opt.get("stern_w", 0.30)
    stern_h = opt.get("stern_h", 0.50)
    bulb_w = opt.get("bulb", 0.09)
    bulb_h = opt.get("bulb_h", 0.06)
    bulb_zc = hl * opt.get("bulb_zc", -0.78)
    bulb_zw = l * opt.get("bulb_zw", 0.10)

    def sec(z):
        return _ballard_section(
            z, hl, l, w, h, cut, keel_frac, deck_frac, beam_frac,
            sail_w, sail_h, sail_zc, sail_zw,
            bow_frac, stern_start, stern_w, stern_h,
            bulb_w, bulb_h, bulb_zc, bulb_zw,
        )

    HF.loft_evolution(bm, -hl, hl, sec, n_sections=14, cap_chamfer=cut * 0.7)


# --- MOREAU YARDS -----------------------------------------------------------

def _moreau_se(v, e):
    """Signed power for the superellipse sampler: keeps the quadrant sign
    so the outline stays a closed convex-ish ring."""
    return math.copysign(abs(v) ** e, v)


def _moreau_round_outline(w, h, n, cy=0.0):
    """Rounded superellipse section sampled at n points.

    Exponent 2.6 sits between an ellipse (2.0) and a rounded rectangle (4+):
    round bilges, round shoulders, a softly flattened bottom. The two samples
    straddling the lowest point are clamped to the section floor, so the hull
    still sits on a real flat keel chord and locomotion mounts keep their
    AABB-underside anchor. Every facet is flat; the roundness is the facet
    count, not a shading trick.
    """
    a, b = w / 2.0, h / 2.0
    e = 2.0 / 2.6
    floor_y = cy - b
    pts = []
    for i in range(n):
        # Half-step grid: no sample exactly at the bottom, so the two
        # straddling points define the keel chord when clamped.
        ang = -math.pi / 2.0 + (i + 0.5) * (2.0 * math.pi / n)
        c, s = math.cos(ang), math.sin(ang)
        pts.append((a * _moreau_se(c, e), cy + b * _moreau_se(s, e)))
    pts[0] = (pts[0][0], floor_y)
    pts[-1] = (pts[-1][0], floor_y)
    return pts


def _moreau_section(z, hl, l, w, h, facets, bow_style, bow_frac, tip_w, tip_h,
                    stern_style, stern_frac, stern_tip_w, stern_tip_h,
                    waist, waist_zc, waist_zw, blister_h, blister_zc, blister_zw):
    """Cross-section for Moreau at a given z.

    A rounded superellipse ring scaled by width/height fractions that NEVER
    plateau: both ends taper away (bow per bow_style - "rounded" smoothstep
    or "arrow" quadratic - stern per stern_style), so the plan and profile
    are curves end to end. An optional waist multiplies the width by
    (1 - waist) around waist_zc, pinching the plan view in at midships.
    A dorsal blister raises the deck at mid for distinct Moreau read.

    `facets` vertices always.
    """
    bow_len = l * bow_frac
    if z <= -hl:
        fw_b, fh_b = tip_w, tip_h
    elif z <= -hl + bow_len:
        t = (z + hl) / bow_len
        if bow_style == "arrow":
            g = t * t
        else:
            g = t * t * (3.0 - 2.0 * t)
        fw_b = tip_w + (1.0 - tip_w) * g
        fh_b = tip_h + (1.0 - tip_h) * g
    else:
        fw_b, fh_b = 1.0, 1.0

    stern_len = l * stern_frac
    if z >= hl:
        fw_s, fh_s = stern_tip_w, stern_tip_h
    elif z >= hl - stern_len:
        t = (hl - z) / stern_len
        if stern_style == "point":
            g = t * t
        else:
            g = t * t * (3.0 - 2.0 * t)
        fw_s = stern_tip_w + (1.0 - stern_tip_w) * g
        fh_s = stern_tip_h + (1.0 - stern_tip_h) * g
    else:
        fw_s, fh_s = 1.0, 1.0

    fw = fw_b * fw_s
    fh = fh_b * fh_s
    fw *= 1.0 - waist * HF.smooth_transition(z, waist_zc, waist_zw)
    # Dorsal blister - broad height bump at mid
    if blister_h > 1e-6:
        fh *= 1.0 + blister_h * HF.smooth_transition(z, blister_zc, blister_zw)

    W = max(w * fw, w * 0.03)
    H = max(h * fh, h * 0.20)
    return _moreau_round_outline(W, H, facets, cy=-h / 2.0 + H / 2.0)


def body_moreau(bm, w, h, l, opt):
    """Wave-former. ONE loft: rounded 16-facet section, double-ended taper
    (rounded canoe / sharp arrowhead bow / full diamond plan), optional
    midships waist. Flat keel chord, no flat transom, no parallel midbody
    unless the taper fractions are set tiny."""
    hl = l / 2.0
    facets = opt.get("facets", 16)
    bow_style = opt.get("bow_style", "rounded")
    bow_frac = opt.get("bow_frac", 0.24)
    tip_w = opt.get("tip_w", 0.30)
    tip_h = opt.get("tip_h", 0.55)
    stern_style = opt.get("stern_style", "rounded")
    stern_frac = opt.get("stern_frac", 0.24)
    stern_tip_w = opt.get("stern_tip_w", 0.30)
    stern_tip_h = opt.get("stern_tip_h", 0.55)
    waist = opt.get("waist", 0.0)
    waist_zc = hl * opt.get("waist_zc", 0.0)
    waist_zw = l * opt.get("waist_zw", 0.15)
    blister_h = opt.get("blister", 0.10)
    blister_zc = hl * opt.get("blister_zc", 0.05)
    blister_zw = l * opt.get("blister_zw", 0.20)

    def sec(z):
        return _moreau_section(
            z, hl, l, w, h, facets, bow_style, bow_frac, tip_w, tip_h,
            stern_style, stern_frac, stern_tip_w, stern_tip_h,
            waist, waist_zc, waist_zw, blister_h, blister_zc, blister_zw,
        )

    HF.loft_evolution(bm, -hl, hl, sec, n_sections=18, cap_chamfer=min(w, h) * 0.05)


# --- DURHAM MOTORS ----------------------------------------------------------

def _durham_section(z, hl, l, w, h, cut, cab_frac, cab_h, cargo_h, wind_frac,
                    nose_taper):
    """Cross-section for Durham at a given z.

    A regular-old-vehicle box: oct_outline throughout, constant width
    (slight front taper only), height steps from bumper → windshield →
    cab roof → cargo bed. Reads as a pickup / APC / HEMTT at 40 m with
    no sci-fi vocabulary — just a boxy cab and a flat cargo volume.
    Bottom is always at y = -h/2 (flat underside). 8 vertices always.
    """
    # Width fraction - almost constant, slight nose inset like a real bumper/grille.
    if z <= -hl + l * nose_taper:
        t = (z + hl) / max(l * nose_taper, 1e-6)
        fw = 0.84 + 0.16 * t
    elif z >= hl - l * 0.08:
        t = (z - (hl - l * 0.08)) / max(l * 0.08, 1e-6)
        fw = 1.00 - 0.04 * t
    else:
        fw = 1.00

    # Height fraction - bumper low, rises to windshield, cab roof, then
    # VERTICAL drop to cargo bed. The rear cab wall is a near 90-degree
    # step, not a tapered slope, so the hull reads as a real truck cab
    # with a separate cargo bed.
    cab_z_end = -hl + l * cab_frac
    wind_z = -hl + l * wind_frac
    if z <= -hl:
        fh = 0.52
    elif z <= wind_z:
        t = (z + hl) / max(wind_z + hl, 1e-6)
        fh = 0.52 + (0.78 - 0.52) * t
    elif z <= cab_z_end:
        # Cab roof - flat from windshield top to rear wall.
        fh = cab_h
    else:
        fh = cargo_h

    W = w * fw
    H = h * fh
    # Bottom at -h/2: center the outline half-height above floor.
    cy = -h / 2.0 + H / 2.0
    # Scale cut with this section's size so narrow nose doesn't self-intersect.
    c = min(cut, W * 0.20, H * 0.28)
    cx_ = min(c, W * 0.40)
    cy_ = min(c, H * 0.40)
    return HF.oct_outline(W, H, cx_, cy_, cy=cy)


def body_durham(bm, w, h, l, opt):
    """Regular vehicle. ONE loft: boxy oct section with windshield step,
    cab roof and flat cargo bed. Flat underside, no exotic taper.

    The cab's rear wall is a near-vertical step, so the loft uses a
    non-uniform section list with a tight pair straddling the cab/cargo
    seam (eps = 1.2% of length). loft_evolution's uniform sampling
    would smear that step over one whole interval (~0.8 units) into a
    long slope."""
    hl = l / 2.0
    cut = min(w, h) * 0.10
    cab_frac = opt.get("cab_frac", 0.32)
    cab_h = opt.get("cab_h", 0.96)
    cargo_h = opt.get("cargo_h", 0.72)
    wind_frac = opt.get("wind_frac", 0.10)
    nose_taper = opt.get("nose_taper", 0.10)

    def sec(z):
        return _durham_section(z, hl, l, w, h, cut, cab_frac, cab_h,
                               cargo_h, wind_frac, nose_taper)

    # Non-uniform sampling: cluster a pair around the cab rear wall.
    cab_z_end = -hl + l * cab_frac
    eps = l * 0.012
    # Clamp eps pair inside the hull so cap inset doesn't swallow it.
    z_low = max(cab_z_end - eps, -hl + 0.01)
    z_high = min(cab_z_end + eps, hl - 0.01)
    # Build a sorted unique list that still captures the nose taper and
    # windshield slope, plus the vertical seam.
    raw_zs = [
        -hl,
        -hl + l * nose_taper * 0.5,
        -hl + l * nose_taper,
        -hl + l * wind_frac,
        ( -hl + l * wind_frac + cab_z_end) * 0.5,
        z_low,
        z_high,
        (z_high + hl) * 0.5,
        hl - l * 0.06,
        hl,
    ]
    zs = sorted(set(raw_zs))
    # Ensure the seam pair stays adjacent after dedup.
    sections = [(z, sec(z)) for z in zs]
    HF.add_solid(bm, sections, cap_chamfer=cut)


# --- SPECTRE DYNAMICS -------------------------------------------------------

def _spectre_section(z, hl, l, w, h, cut, nose_frac, tip_w, tip_h_frac,
                     stern_frac, stern_tip_w, stern_tip_h_frac,
                     canopy_w, canopy_h, canopy_zc, canopy_zw):
    """Cross-section for Spectre at a given z.

    Pure arrowhead / delta: plan view is a sharp triangle (tip_w ~0.03 at
    the nose, LINEAR to full width over nose_frac), height is low
    and flat (stealth bomber / arrowhead tank read). Sides are straight
    bevels meeting at the tip — no tangential quadratic curve unlike
    Hartmann/Calder/Moreau's eased bows. An optional centered canopy mesa
    is integrated as a 4-vertex bump on the deck, collapsed flat outside
    its z range — same pattern as Hartmann/Calder/Rackham.
    Bottom is always at y = -h/2. 12 vertices always.
    """
    nose_len = l * nose_frac
    if z <= -hl:
        fw = tip_w
        fh = tip_h_frac
    elif z <= -hl + nose_len:
        t = (z + hl) / max(nose_len, 1e-6)
        g = t  # linear - straight arrowhead bevel
        fw = tip_w + (1.0 - tip_w) * g
        fh = tip_h_frac + (1.0 - tip_h_frac) * g
    elif z >= hl - l * stern_frac:
        t = (hl - z) / max(l * stern_frac, 1e-6)
        g = t  # linear - straight stern bevel
        fw = stern_tip_w + (1.0 - stern_tip_w) * g
        fh = stern_tip_h_frac + (1.0 - stern_tip_h_frac) * g
    else:
        fw = 1.00
        fh = 1.00

    W = w * fw
    H = h * fh
    floor_y = -h / 2.0
    deck_y = floor_y + H

    # Chamfer scales with this section's size — narrow tip would self-intersect otherwise.
    c = min(cut, W * 0.18, H * 0.26)
    # Keep belly width safe for deck edge inset.
    # Mesa / canopy on the deck — 4-vertex peak, right-to-left flat segment when inactive.
    t_canopy = HF.smooth_transition(z, canopy_zc, canopy_zw) if canopy_w > 0 else 0.0
    if canopy_w > 0 and canopy_h > 0 and t_canopy > 1e-6:
        rw = min(W * canopy_w / 2.0, (W / 2.0 - c) * 0.88)
        rht = rw * 0.70
        RH = h * canopy_h * t_canopy
        # Active: centered mesa straddling deck_y.
        v5_x, v5_y = rw, deck_y
        v6_x, v6_y = rht, deck_y + RH
        v7_x, v7_y = -rht, deck_y + RH
        v8_x, v8_y = -rw, deck_y
    else:
        v5_x, v5_y = W * 0.28, deck_y
        v6_x, v6_y = W * 0.08, deck_y
        v7_x, v7_y = -W * 0.08, deck_y
        v8_x, v8_y = -W * 0.28, deck_y

    # 12-vertex outline: bottom edge → sides → deck chamfer → canopy mesa → deck chamfer → sides.
    return [
        (-W / 2.0 + c, floor_y),       # 0: bottom-left
        (W / 2.0 - c, floor_y),        # 1: bottom-right
        (W / 2.0, floor_y + c),        # 2: right lower
        (W / 2.0, deck_y - c),         # 3: right side top
        (W / 2.0 - c, deck_y),         # 4: right deck edge
        (v5_x, v5_y),                  # 5: canopy right base / flat
        (v6_x, v6_y),                  # 6: canopy right top / flat
        (v7_x, v7_y),                  # 7: canopy left top / flat
        (v8_x, v8_y),                  # 8: canopy left base / flat
        (-W / 2.0 + c, deck_y),        # 9: left deck edge
        (-W / 2.0, deck_y - c),        # 10: left side top
        (-W / 2.0, floor_y + c),       # 11: left lower
    ]


def body_spectre(bm, w, h, l, opt):
    """Arrowhead stealth hull. ONE loft: sharp delta plan, low flat profile,
    optional centered canopy mesa. Flat underside."""
    hl = l / 2.0
    cut = min(w, h) * 0.09
    nose_frac = opt.get("nose_frac", 0.36)
    tip_w = opt.get("tip_w", 0.04)
    tip_h_frac = opt.get("tip_h", 0.38)
    stern_frac = opt.get("stern_frac", 0.12)
    stern_tip_w = opt.get("stern_tip_w", 0.72)
    stern_tip_h_frac = opt.get("stern_tip_h", 0.88)
    canopy_w = opt.get("canopy_w", 0.0)
    canopy_h = opt.get("canopy_h", 0.0)
    canopy_zc = hl * opt.get("canopy_zc", -0.08)
    canopy_zw = l * opt.get("canopy_zw", 0.09)

    def sec(z):
        return _spectre_section(
            z, hl, l, w, h, cut, nose_frac, tip_w, tip_h_frac,
            stern_frac, stern_tip_w, stern_tip_h_frac,
            canopy_w, canopy_h, canopy_zc, canopy_zw,
        )

    HF.loft_evolution(bm, -hl, hl, sec, n_sections=14, cap_chamfer=cut * 0.7)


# --- HEXTON WORKS -----------------------------------------------------------

def _hexton_fw_fh(z, hl, l, nose_frac, tail_frac):
    """Width/height fractions for Hexton along z. Blunt nose/tail, longer than wide.

    At the very tip the hex is ~75% width / 68% height, ramping quickly to
    full over nose_frac / tail_frac. Mid-hull is full. This keeps the bow
    flat-ish (a real glacis) not a Spectre point, and the section stays
    hexagonal throughout."""
    nose_len = l * nose_frac
    tail_len = l * tail_frac
    if z <= -hl:
        return 0.76, 0.70
    if z <= -hl + nose_len:
        t = (z + hl) / max(nose_len, 1e-6)
        fw = 0.76 + 0.24 * t
        fh = 0.70 + 0.30 * t
        return fw, fh
    if z >= hl:
        return 0.78, 0.72
    if z >= hl - tail_len:
        t = (hl - z) / max(tail_len, 1e-6)  # 1 at seam, 0 at tip
        fw = 0.78 + 0.22 * t
        fh = 0.72 + 0.28 * t
        return fw, fh
    return 1.0, 1.0


def body_hexton(bm, w, h, l, opt):
    """Hexagonal prism, longer than wide. Single hex by default; twin mode
    builds two parallel hex cylinders with cross-members, high-aft-cab adds
    an elevated box at the stern. Flat underside (y=-h/2) always."""
    hl = l / 2.0
    top_frac = opt.get("top_frac", 0.56)
    bottom_frac = opt.get("bottom_frac", 0.58)
    nose_frac = opt.get("nose_frac", 0.14)
    tail_frac = opt.get("tail_frac", 0.10)
    twin = opt.get("twin", False)
    gap_frac = opt.get("gap_frac", 0.14)
    aft_cab = opt.get("aft_cab", False)
    aft_cab_h = opt.get("aft_cab_h", 0.38)
    aft_cab_w = opt.get("aft_cab_w", 0.62)
    aft_cab_len = opt.get("aft_cab_len", 0.26)
    aft_cab_z = opt.get("aft_cab_z", 0.48)

    if twin:
        gap = w * gap_frac
        # Two parallel hex tubes
        for side in (-1, 1):
            sections = []
            for i in range(8):
                t = i / 7.0
                z = -hl + (2.0 * hl) * t
                fw, fh = _hexton_fw_fh(z, hl, l, nose_frac, tail_frac)
                W_each = max((w * fw - gap) / 2.0, w * 0.12)
                H = h * fh
                cy = -h / 2.0 + H / 2.0
                cx = side * (w * fw + gap) / 4.0
                outline = HF.hex_flat_outline(W_each, H, top_frac, bottom_frac, cy, cx)
                sections.append((z, outline))
            HF.add_solid(bm, sections, cap_chamfer=min(w, h) * 0.07)
        # Cross-members spanning the gap
        beam_zs = opt.get("beam_z", (-0.38, 0.0, 0.38))
        for zf in beam_zs:
            z = hl * zf
            fw, fh = _hexton_fw_fh(z, hl, l, nose_frac, tail_frac)
            H = h * fh
            beam_y = -h / 2.0 + H * 0.52
            beam_w = gap + w * 0.06
            beam_h = h * 0.11
            beam_len = l * 0.07
            HF.add_chamfered_box(bm, (0.0, beam_y, z),
                                 (beam_w, beam_h, beam_len),
                                 cut=min(beam_w, beam_h) * 0.18)
    else:
        def sec(z):
            fw, fh = _hexton_fw_fh(z, hl, l, nose_frac, tail_frac)
            W = w * fw
            H = h * fh
            cy = -h / 2.0 + H / 2.0
            return HF.hex_flat_outline(W, H, top_frac, bottom_frac, cy, 0.0)

        HF.loft_evolution(bm, -hl, hl, sec, n_sections=10, cap_chamfer=min(w, h) * 0.07)

    if aft_cab:
        # Elevated box at the stern, sitting on the hex deck
        aft_z = hl * aft_cab_z
        fw, fh = _hexton_fw_fh(aft_z, hl, l, nose_frac, tail_frac)
        H = h * fh
        deck_y = -h / 2.0 + H
        cab_h_abs = h * aft_cab_h
        cab_w_abs = w * aft_cab_w
        cab_len_abs = l * aft_cab_len
        cab_y = deck_y + cab_h_abs / 2.0
        HF.add_chamfered_box(bm, (0.0, cab_y, aft_z),
                             (cab_w_abs, cab_h_abs, cab_len_abs),
                             cut=min(cab_w_abs, cab_h_abs) * 0.14)


BODIES = {
    "halvorsen": body_halvorsen,
    "kestrel": body_kestrel,
    "brenntal": body_brenntal,
    "tallow": body_tallow,
    "orrin": body_orrin,
    "rackham": body_rackham,
    "calder": body_calder,
    "pillar": body_pillar,
    "hartmann": body_hartmann,
    "ballard": body_ballard,
    "moreau": body_moreau,
    "durham": body_durham,
    "spectre": body_spectre,
    "hexton": body_hexton,
}


# ---------------------------------------------------------------------------
# Role elements - the large greebles that read a class on top of a
# manufacturer body. These are tiered structures: an add_chamfered_box()
# or add_wedge() in the same bmesh, with the bottom face sitting on the
# body's top or flank. They are separate lofts in one mesh.
# ---------------------------------------------------------------------------

def _local_top_at_z(bm, godot_z: float, tolerance: float = 0.5) -> float:
    """Y coordinate of the highest TOP-facing facet near the given Godot-Z.

    Elements that sit on the body deck (bolster / gantry / second_deck / flatbed
    / trunk / barbette / well / bridge / mast / spine) used to be placed at
    `hh + ...` (top of the body's bounding box). That worked for hulls with a
    uniform top (block, slab) but on a tallow - which has a tall cab at the
    nose and a low flatbed at the rear - it put the rear elements high in the
    air. The screenshot in the floating-parts bug report showed exactly that:
    the bolster posts floating 0.9 units above the flatbed.

    The body's true top is whatever face is currently facing up. The face's
    centroid Z is the height in Godot, and Blender Y maps to Godot -Z (see
    mark_frontal_armour's coordinate note at line ~441), so we convert the
    Godot-Z to a Blender-Y target and pick the highest up-facing face near it.
    Fallback to 0.0 if no top face is in range - the element ends up exactly
    where the old code put it, so the behaviour is never worse than before.

    bmesh face.normal is unreliable on freshly created faces (the bmesh.ops
    call may not have computed the winding yet), so we derive the normal
    manually from two edge vectors and take the +Z component.
    """
    target_blender_y = -godot_z
    best: float = -1e9
    for f in bm.faces:
        verts = f.verts
        if len(verts) < 3:
            continue
        v0 = verts[0].co
        v1 = verts[1].co
        v2 = verts[2].co
        e1 = v1 - v0
        e2 = v2 - v0
        n = e1.cross(e2)
        if n.length < 1e-6:
            continue
        nz = n.z / n.length
        if nz < 0.5:
            continue
        c = f.calc_center_median()
        if abs(c.y - target_blender_y) > tolerance:
            continue
        if c.z > best:
            best = c.z
    return best if best > -1e8 else 0.0


def el_mast(bm, w, h, l, p):
    """Tall square-section sensor mast. The scout tell.

    Base anchored to the body's local top at the mast z, not the bbox top.
    See _local_top_at_z() - same rationale as el_bolster. The -h*0.04
    inset on the old code was a poor attempt at "slightly below the
    bbox top"; with the real top in hand it just disappears.
    """
    hl = l / 2.0
    mh = h * p.get("mh", 1.05)
    base = w * p.get("base", 0.15)
    z = hl * p.get("z", 0.10)
    x = w * p.get("x", 0.0)
    local_top = _local_top_at_z(bm, z)
    base_y = local_top
    HF.add_solid(bm, [
        (z - base / 2.0, HF.oct_outline(base, mh, base * 0.26, mh * 0.05,
                                        cy=base_y + mh / 2.0, cx=x)),
        (z + base / 2.0, HF.oct_outline(base * 0.9, mh, base * 0.26, mh * 0.05,
                                        cy=base_y + mh / 2.0, cx=x)),
    ], cap_chamfer=base * 0.22)
    HF.add_chamfered_box(bm, (x, base_y + mh * 0.86, z),
                         (w * p.get("vane", 0.46), h * 0.07, base * 0.7),
                         cut=h * 0.02)


def el_barbette(bm, w, h, l, p):
    """Low octagonal-PLAN turret plinth. The medium/heavy gun-platform tell.

    Base anchored to the body's local top at the barbette z. See
    _local_top_at_z() - same rationale as el_bolster.
    """
    hl = l / 2.0
    r = w * p.get("r", 0.34)
    bh = h * p.get("bh", 0.22)
    z = hl * p.get("z", 0.0)
    base_y = _local_top_at_z(bm, z)
    cy = base_y + bh / 2.0
    wide = HF.oct_outline(r * 2.0, bh, r * 0.30, bh * 0.28, cy=cy)
    narrow = HF.oct_outline(r * 1.46, bh * 0.92, r * 0.24, bh * 0.26, cy=cy)
    HF.add_solid(bm, [
        (z - r * 0.98, narrow),
        (z - r * 0.44, wide),
        (z + r * 0.44, wide),
        (z + r * 0.98, narrow),
    ], cap_chamfer=bh * 0.22)


def el_bridge(bm, w, h, l, p):
    """Stepped superstructure stack. The command-variant tell.

    First step base anchored to the body's local top at the bridge z. See
    _local_top_at_z() - same rationale as el_bolster.
    """
    hl = l / 2.0
    steps = p.get("steps", 3)
    z = hl * p.get("z", 0.10)
    total = h * p.get("total", 0.95)
    w0 = w * p.get("w", 0.62)
    l0 = l * p.get("l", 0.30)
    y = _local_top_at_z(bm, z)
    for i in range(steps):
        f = 1.0 - i * (0.62 / max(1, steps))
        sh = total / steps
        HF.add_chamfered_box(bm, (w * p.get("x", 0.0), y + sh / 2.0, z),
                             (w0 * f, sh, l0 * f), cut=min(w0 * f, sh) * 0.16)
        y += sh


def el_spine(bm, w, h, l, p):
    """Full-length dorsal ridge.

    Base anchored to the body's local top at the spine's mid z, not the
    bbox top. See _local_top_at_z() - same rationale as el_bolster. The
    spine runs the length of the hull, so the local top can vary along
    its z range; we use the spine's mid-z as a representative sample.
    """
    hl = l / 2.0
    z0 = hl * p.get("z0", -0.72)
    z1 = hl * p.get("z1", 0.86)
    mid_z = (z0 + z1) / 2.0
    base_y = _local_top_at_z(bm, mid_z)
    sh = h * p.get("sh", 0.30)
    HF.add_ridge(bm, z0, z1,
                 base_y, base_y + sh + h * 0.02,
                 w * p.get("w_bot", 0.24), w * p.get("w_top", 0.10),
                 cx=w * p.get("x", 0.0), cut=w * 0.035)


def el_flatbed(bm, w, h, l, p):
    """Open cargo deck with low perimeter rails. The transport tell.

    Deck base anchored to the body's local top across the deck's z range.
    See _local_top_at_z() - same rationale as el_bolster. Use the lowest
    local top so the deck doesn't clip through the hull.
    """
    hl = l / 2.0
    z0 = hl * p.get("z0", -0.10)
    z1 = hl * p.get("z1", 0.94)
    bw = w * p.get("w", 0.86)
    mid_z = (z0 + z1) / 2.0
    base_y = _local_top_at_z(bm, mid_z)
    deck_y = base_y + h * 0.02
    HF.add_chamfered_box(bm, (0.0, deck_y, mid_z),
                         (bw, h * p.get("deck_h", 0.20), z1 - z0), cut=h * 0.04)
    rail_h = h * p.get("rail_h", 0.30)
    for xs in (-1, 1):
        HF.add_chamfered_box(
            bm, (xs * (bw / 2.0 - w * 0.03), deck_y + rail_h / 2.0, mid_z),
            (w * 0.06, rail_h, z1 - z0), cut=w * 0.015)
    HF.add_chamfered_box(bm, (0.0, deck_y + rail_h / 2.0, z1 - w * 0.03),
                         (bw, rail_h, w * 0.06), cut=w * 0.015)


def el_trunk(bm, w, h, l, p):
    """Raised full-length trunk deck - the tanker/bulk-carrier read.

    Base anchored to the body's local top at the trunk's mid z. See
    _local_top_at_z() - same rationale as el_bolster.
    """
    hl = l / 2.0
    th = h * p.get("th", 0.42)
    z0 = hl * p.get("z0", -0.62)
    z1 = hl * p.get("z1", 0.90)
    tw = w * p.get("w", 0.66)
    mid_z = (z0 + z1) / 2.0
    base_y = _local_top_at_z(bm, mid_z)
    outline = HF.oct_outline(tw, th, tw * 0.22, th * 0.30,
                             cy=base_y + th / 2.0)
    HF.add_solid(bm, [(z0, outline), (z1, outline)], cap_chamfer=th * 0.24)


def el_well(bm, w, h, l, p):
    """Open cargo well: two tall side walls and a rear gate, nothing between.

    Wall bases anchored to the body's local top across the well's z range.
    See _local_top_at_z() - same rationale as el_bolster.
    """
    hl = l / 2.0
    z0 = hl * p.get("z0", -0.20)
    z1 = hl * p.get("z1", 0.94)
    ww = w * p.get("w", 0.88)
    wall_h = h * p.get("wall_h", 0.52)
    t = w * 0.09
    base_y = _local_top_at_z(bm, (z0 + z1) / 2.0)
    for xs in (-1, 1):
        HF.add_chamfered_box(
            bm, (xs * (ww / 2.0 - t / 2.0), base_y + wall_h / 2.0,
                 (z0 + z1) / 2.0),
            (t, wall_h, z1 - z0), cut=t * 0.26)
    HF.add_chamfered_box(bm, (0.0, base_y + wall_h / 2.0, z1 - t / 2.0),
                         (ww, wall_h, t), cut=t * 0.26)
    HF.add_chamfered_box(bm, (0.0, base_y + wall_h * 0.30, z0 + t / 2.0),
                         (ww * 0.9, wall_h * 0.7, t), cut=t * 0.26)


def el_ramp(bm, w, h, l, p):
    """Enormous raked bow gate - the landing-craft read."""
    hh, hl = h / 2.0, l / 2.0
    z_foot = -hl * p.get("z_foot", 0.99)
    z_head = -hl * p.get("z_head", 0.52)
    y_foot = -hh * p.get("y_foot", 0.62)
    y_head = hh + h * p.get("rise", 0.26)
    gw = w * p.get("w", 0.80)
    th = h * p.get("th", 0.16)
    HF.add_solid(bm, [
        (z_foot, HF.oct_outline(gw, th, gw * 0.10, th * 0.30, cy=y_foot)),
        (z_head, HF.oct_outline(gw * 0.96, th, gw * 0.10, th * 0.30, cy=y_head)),
    ], cap_chamfer=th * 0.30)


def el_glacis(bm, w, h, l, p):
    """A second, steeper armour plate stacked over the front. Heavy-class."""
    hh, hl = h / 2.0, l / 2.0
    HF.add_wedge(bm, (0.0, hh * p.get("y", 0.10), -hl * p.get("z", 0.58)),
                 (w * p.get("w", 0.94), h * p.get("hh", 0.46), l * p.get("len", 0.34)),
                 front_h_frac=p.get("front", 0.28), cut=min(w, h) * 0.08)


def el_ballast(bm, w, h, l, p):
    """Big solid rear counterweight block. Prime-mover / wrecker read."""
    hh, hl = h / 2.0, l / 2.0
    HF.add_chamfered_box(
        bm, (w * p.get("x", 0.0), hh * p.get("y", 0.32), hl * p.get("z", 0.72)),
        (w * p.get("w", 0.70), h * p.get("h", 0.54), l * p.get("len", 0.24)),
        cut=min(w, h) * 0.09)


def el_gantry(bm, w, h, l, p):
    """Portal-frame arch straddling the deck. Two legs and a beam.

    Leg base anchored to the body's local top at the gantry z, not the
    bounding-box top. See _local_top_at_z() - same rationale as el_bolster.
    """
    hw, hl = w / 2.0, l / 2.0
    gh = h * p.get("gh", 0.86)
    t = w * p.get("t", 0.11)
    z = hl * p.get("z", 0.24)
    beam_h = h * p.get("beam_h", 0.13)
    local_top = _local_top_at_z(bm, z)
    leg_center_y = local_top + gh / 2.0
    beam_center_y = local_top + gh - beam_h / 2.0
    for xs in (-1, 1):
        HF.add_chamfered_box(bm, (xs * (hw - t * 0.8), leg_center_y, z),
                             (t, gh, t * 1.2), cut=t * 0.24)
    HF.add_chamfered_box(bm, (0.0, beam_center_y, z),
                         (w * 0.96, beam_h, t * 1.2), cut=min(beam_h, t) * 0.24)


def el_bolster(bm, w, h, l, p):
    """Tall transverse bolsters - the log/pipe hauler read.

    The post base is now anchored to the body's actual top at the bolster's
    z position, not the bounding-box top. Old code used `hh + bh / 2.0`
    which is `h/2 + bh/2` - the top of the hull's bbox, which on a tallow
    hull is the cab roof. The bolster at z = -0.06 and z = 0.60 is in the
    flatbed area, where the body is much lower, so the old code put the
    whole structure 0.9 units in the air. See _local_top_at_z().
    """
    hl = l / 2.0
    bh = h * p.get("bh", 0.62)
    for zf in p.get("z", (-0.12, 0.66)):
        z_actual = hl * zf
        local_top = _local_top_at_z(bm, z_actual)
        # Post center: bottom at local_top, so the post sits on the body.
        post_y = local_top + bh / 2.0
        # Beam center: same Y as the post center - the beam is a cross-brace
        # in the middle of the post pair, like a sawhorse rail. Old code
        # shared this Y with the post (and the bug was that Y was bbox-top,
        # not flatbed-top).
        beam_y = post_y
        HF.add_chamfered_box(bm, (0.0, beam_y, z_actual),
                             (w * 0.90, bh * 0.24, l * 0.05), cut=h * 0.03)
        for xs in (-1, 1):
            HF.add_chamfered_box(
                bm, (xs * (w * 0.44), post_y, z_actual),
                (w * 0.07, bh, l * 0.05), cut=w * 0.018)


def el_second_deck(bm, w, h, l, p):
    """A whole second open deck on posts above the first.

    Post bases anchored to the body's local top across the deck's z range,
    not the bounding-box top. See _local_top_at_z() - same rationale as
    el_bolster. We sample the local top at each post's z so the deck sits
    flat even when the hull under it is not.
    """
    hl = l / 2.0
    lift = h * p.get("lift", 0.62)
    z0 = hl * p.get("z0", -0.30)
    z1 = hl * p.get("z1", 0.92)
    dw = w * 0.88
    sample_zs = [z0 + l * 0.04, (z0 + z1) / 2.0, z1 - l * 0.04]
    # Use the LOWEST local top across the deck's z range so every post sits
    # on the body. If we used the highest, the posts on the lower side of
    # the deck would float again.
    base_y = min(_local_top_at_z(bm, z) for z in sample_zs)
    for xs in (-1, 1):
        for zf in sample_zs:
            HF.add_chamfered_box(bm, (xs * (dw / 2.0 - w * 0.05),
                                      base_y + lift / 2.0, zf),
                                 (w * 0.08, lift, w * 0.08), cut=w * 0.02)
    HF.add_chamfered_box(bm, (0.0, base_y + lift + h * 0.05, (z0 + z1) / 2.0),
                         (dw, h * 0.11, z1 - z0),
                         cut=h * 0.026)


ELEMENTS = {
    "mast": el_mast,
    "barbette": el_barbette,
    "bridge": el_bridge,
    "spine": el_spine,
    "flatbed": el_flatbed,
    "trunk": el_trunk,
    "well": el_well,
    "ramp": el_ramp,
    "glacis": el_glacis,
    "ballast": el_ballast,
    "gantry": el_gantry,
    "bolster": el_bolster,
    "second_deck": el_second_deck,
}


# ---------------------------------------------------------------------------
# The lineup. 114 hulls. Deliberately unbalanced across manufacturers, per the
# brief: Brenntal and Halvorsen carry the heavy end, Tallow owns transports at
# every size, Kestrel skews small and fast, Orrin is symmetric salvage, Rackham
# is industrial mid, Calder is fast-attack light, Pillar is modular boxy,
# Hartmann is conventional tanks, Ballard is submarines.
#
# size is the Godot-space envelope (width, height, length) and it is EXACT:
# autofit() solves for the working size whose natural AABB lands here, and
# HF.normalize() finishes the job, so the shipped .glb measures exactly this.
# ---------------------------------------------------------------------------

HEIGHT_BOOST = 1.38


def H(hid, mfr, cls, name, size, elements=(), body=None, domain="Ground"):
    return {
        "id": hid, "mfr": mfr, "cls": cls, "name": name,
        "size": (size[0], round(size[1] * HEIGHT_BOOST, 3), size[2]),
        "elements": list(elements), "body": dict(body or {}), "domain": domain,
    }


LINEUP = [
    # -- HALVORSEN YARD (13): boats ashore -------------------------------
    H("halvorsen_scout_a", "halvorsen", "scout", "Halvorsen Picket Launch",
      (2.4, 1.15, 3.9), [],
      {"bulwark_h": 0.20, "block_h": 0.42, "block_zc": 0.20, "block_zw": 0.10}),
    H("halvorsen_light_a", "halvorsen", "light", "Halvorsen Gunboat",
      (2.8, 1.15, 4.8), [],
      {"pad_h": 0.28, "pad_zc": -0.30, "pad_zw": 0.12}),
    H("halvorsen_medium_a", "halvorsen", "medium", "Halvorsen Monitor",
      (3.8, 1.35, 5.7), [],
      {"pad_h": 0.30, "pad_zc": -0.14, "pad_zw": 0.14, "boss_d": 0.10}),
    H("halvorsen_heavy_a", "halvorsen", "heavy", "Halvorsen Armoured Monitor",
      (4.5, 1.75, 7.3), [],
      {"block_h": 0.30, "block_zc": 0.0, "block_zw": 0.40, "boss_d": 0.16,
       "pad_h": 0.22, "pad_zc": -0.20, "pad_zw": 0.16}),
    H("halvorsen_transport_a", "halvorsen", "transport", "Halvorsen Landing Barge",
      (4.1, 1.45, 7.7), [("ramp", {}), ("well", {"z0": -0.22, "wall_h": 0.40})],
      {"bulwark": False}),
    H("halvorsen_oddball_a", "halvorsen", "oddball", "Halvorsen Catamaran",
      (5.3, 1.50, 7.1), [],
      {"bulwark": False, "block_h": 0.34, "block_zc": 0.0, "block_zw": 0.30}),

    # -- KESTREL AEROWORKS (12): fuselages, wings sawn off ---------------
    H("kestrel_scout_a", "kestrel", "scout", "Kestrel Recon Fuselage",
      (2.5, 1.15, 4.1), [], {"boom_frac": 0.48, "fin_h": 0.46}),
    H("kestrel_light_a", "kestrel", "light", "Kestrel Strafer",
      (3.2, 1.05, 5.3), [], {"stub_w": 0.22, "stub_l": 0.30, "fin_h": 0.34}),
    H("kestrel_medium_a", "kestrel", "medium", "Kestrel Gunship",
      (3.6, 1.50, 6.1), [],
      {"facet_cut": 0.22, "stub_w": 0.14, "fin_h": 0.34}),
    H("kestrel_heavy_a", "kestrel", "heavy", "Kestrel Heavy Lifter",
      (4.5, 1.95, 7.7), [],
      {"facet_cut": 0.20, "stub_w": 0.12, "stub_z": -0.44,
       "boom_frac": 0.60, "fin_h": 0.40}),
    H("kestrel_transport_a", "kestrel", "transport", "Kestrel Freighter",
      (3.8, 1.70, 8.7), [("well", {"z0": 0.28, "wall_h": 0.30, "w": 0.72})],
      {"boom_frac": 0.66, "boom_z": 0.52, "canopies": (-0.60,),
       "stub_w": 0.12, "fin_h": 0.38}),
    H("kestrel_oddball_a", "kestrel", "oddball", "Kestrel Twin Boom",
      (4.4, 1.62, 6.9), [],
      {"boom_frac": 0.46, "boom_z": -0.10, "fin": False, "stub_w": 0.20}),
    H("kestrel_oddball_b", "kestrel", "oddball", "Kestrel Flying Boat",
      (4.2, 1.65, 7.1), [],
      {"boom_frac": 0.56, "stub_w": 0.11, "fin_h": 0.40}, domain="Naval"),

    # -- BRENNTAL SCHWERBAU (13): mobile bunkers ------------------------
    H("brenntal_scout_a", "brenntal", "scout", "Brenntal Recon Casemate",
      (2.7, 1.10, 4.0), [], {"plinth_h": 0.58, "casemate_l": 0.46,
                             "glacis_z": 0.30}),
    H("brenntal_light_a", "brenntal", "light", "Brenntal Casemate Gun",
      (3.2, 1.05, 5.1), [], {"plinth_h": 0.72, "casemate_l": 0.40,
                             "casemate_w": 0.62, "glacis_z": 0.34}),
    H("brenntal_medium_a", "brenntal", "medium", "Brenntal Casemate Medium",
      (3.6, 1.40, 5.9), [], {"glacis_z": 0.26}),
    H("brenntal_heavy_a", "brenntal", "heavy", "Brenntal Breakthrough",
      (4.7, 1.90, 7.5), [], {"glacis_z": 0.22}),
    H("brenntal_heavy_c", "brenntal", "heavy", "Brenntal Assault Gun",
      (4.5, 1.65, 7.9), [], {"plinth_h": 0.86, "casemate_l": 0.34,
                             "casemate_w": 0.54, "glacis_z": 0.46}),
    H("brenntal_transport_a", "brenntal", "transport", "Brenntal Armoured Carrier",
      (4.1, 1.60, 7.7), [], {"plinth_h": 0.62, "casemate_l": 0.88,
                             "casemate_w": 0.90, "casemate_z": 0.06}),
    H("brenntal_oddball_a", "brenntal", "oddball", "Brenntal Tandem Casemate",
      (4.3, 1.75, 7.9), [],
      {"casemate_l": 0.30, "casemate_z": -0.44, "glacis_z": 0.22}),

    # -- TALLOW & VANCE: cab + flatbed trucks. Outcrops (collar neck, side
    #    bosses, bed rail, rear plinth) are grown into the single loft in
    #    body_tallow - no bolted-on elements. Fewer hulls than before, but
    #    each bigger one carries more and larger outcrops, so the roster
    #    reads as distinct vehicles rather than one scaled hull.
    H("tallow_scout_a", "tallow", "scout", "Tallow Runabout",
      (2.4, 1.05, 3.9),
      [], {"cab_l": 0.34, "collar_h": 0.16, "boss_d": 0.05}),
    H("tallow_light_a", "tallow", "light", "Tallow Pickup",
      (2.8, 1.15, 4.9),
      [], {"cab_l": 0.30, "collar_h": 0.22, "boss_d": 0.08, "rail_h": 0.10}),
    H("tallow_medium_a", "tallow", "medium", "Tallow Flatbed",
      (3.4, 1.25, 6.3),
      [], {"cab_l": 0.26, "collar_h": 0.24, "boss_d": 0.10,
          "rail_h": 0.14, "plinth_h": 0.12}),
    H("tallow_medium_b", "tallow", "medium", "Tallow Stake Bed",
      (3.5, 1.60, 6.5),
      [], {"cab_l": 0.26, "collar_h": 0.26, "boss_d": 0.10,
          "rail_h": 0.16, "plinth_h": 0.16}),
    H("tallow_heavy_a", "tallow", "heavy", "Tallow Lowboy",
      (4.3, 1.40, 8.1),
      [], {"cab_l": 0.22, "cab_h": 0.90, "collar_h": 0.28, "boss_d": 0.13,
          "rail_h": 0.18, "plinth_h": 0.20}),
    H("tallow_transport_a", "tallow", "transport", "Tallow Carrier",
      (3.9, 1.35, 8.9),
      [], {"cab_l": 0.22, "collar_h": 0.24, "boss_d": 0.12,
          "rail_h": 0.18, "plinth_h": 0.22}),

    # -- ORRIN COLLECTIVE (8): symmetric salvage -----------------------
    H("orrin_scout_a", "orrin", "scout", "Orrin Skulker",
      (2.6, 1.10, 4.1), [],
      {"mass_w": 0.58, "spine_h": 0.20, "spine_w": 0.36,
       "spine_zc": 0.0, "spine_zw": 0.30}),
    H("orrin_light_a", "orrin", "light", "Orrin Raider",
      (3.3, 1.15, 5.3), [],
      {"mass_w": 0.56, "tumblehome_frac": 0.78}),
    H("orrin_medium_a", "orrin", "medium", "Orrin Bodge Tank",
      (3.7, 1.55, 6.1), [],
      {"mass_w": 0.62, "tumblehome_frac": 0.76,
       "spine_h": 0.16, "spine_w": 0.30,
       "spine_zc": 0.0, "spine_zw": 0.30}),
    H("orrin_heavy_a", "orrin", "heavy", "Orrin Wrecker",
      (4.9, 1.95, 7.7), [],
      {"mass_w": 0.58, "tumblehome_frac": 0.74,
       "spine_h": 0.18, "spine_w": 0.34,
       "spine_zc": 0.0, "spine_zw": 0.28}),
    H("orrin_transport_a", "orrin", "transport", "Orrin Scav Hauler",
      (4.3, 1.50, 8.1), [("flatbed", {"z0": -0.06, "w": 0.58})],
      {"mass_w": 0.60, "tumblehome_frac": 0.82}),
    H("orrin_oddball_a", "orrin", "oddball", "Orrin Crab",
      (5.1, 1.65, 6.3), [],
      {"mass_w": 0.44, "tumblehome_frac": 0.72,
       "spine_h": 0.24, "spine_w": 0.40,
       "spine_zc": 0.0, "spine_zw": 0.30}),
    H("orrin_oddball_b", "orrin", "oddball", "Orrin Twin Spine",
      (3.9, 1.85, 6.7), [],
      {"mass_w": 0.64, "tumblehome_frac": 0.78,
       "spine_h": 0.28, "spine_w": 0.36,
       "spine_zc": 0.0, "spine_zw": 0.32}),

    # -- RACKHAM FORGE (8): industrial crawler -------------------------
    H("rackham_scout_a", "rackham", "scout", "Rackham Prospector",
      (2.6, 1.30, 4.0), [],
      {"mast_h": 0.50, "mast_w": 0.10,
       "mast_zc": 0.20, "mast_zw": 0.05}),
    H("rackham_light_a", "rackham", "light", "Rackham Yard Truck",
      (3.0, 1.10, 4.9), [], {"boiler_l": 0.66, "boiler_h": 0.26,
                             "stack_h": 0.18}),
    H("rackham_medium_a", "rackham", "medium", "Rackham Forge Crawler",
      (3.7, 1.30, 6.1), [], {"boiler_l": 0.70, "boiler_w": 0.50,
                             "boiler_h": 0.30}),
    H("rackham_heavy_a", "rackham", "heavy", "Rackham Iron Hulk",
      (4.5, 1.65, 7.5), [], {"boiler_l": 0.72, "boiler_w": 0.54,
                             "boiler_h": 0.30, "body_h": 0.58}),
    H("rackham_heavy_b", "rackham", "heavy", "Rackham Siege Engine",
      (4.7, 1.85, 7.7), [("barbette", {"z": 0.0, "r": 0.34, "bh": 0.20})],
      {"boiler_l": 0.66, "boiler_w": 0.50, "boiler_h": 0.28,
       "body_h": 0.60, "radiator": False}),
    H("rackham_transport_a", "rackham", "transport", "Rackham Coal Hauler",
      (3.9, 1.50, 8.5), [("flatbed", {"z0": -0.20, "z1": 0.96,
                                      "deck_h": 0.18, "rail_h": 0.26})],
      {"boiler_l": 0.46, "boiler_w": 0.40, "boiler_h": 0.24,
       "body_h": 0.66, "stack": False}),

    # -- CALDER MOBILITY (8): fast-attack wedge -----------------------
    H("calder_scout_a", "calder", "scout", "Calder Spotter",
      (2.4, 1.00, 4.1), [], {"body_w_min": 0.45, "body_h_min": 0.40,
                             "body_h_max": 0.72, "sponson_w": 0.14,
                             "sponson_zc": 0.10, "sponson_zw": 0.30}),
    H("calder_scout_b", "calder", "scout", "Calder Pathrunner",
      (2.2, 0.95, 4.3), [("mast", {"mh": 0.40, "z": 0.20, "vane": 0.36})],
      {"body_w_min": 0.40, "body_h_min": 0.42, "body_h_max": 0.66,
       "sponson_w": 0.10, "sponson_zc": 0.05, "sponson_zw": 0.28}),
    H("calder_light_c", "calder", "light", "Calder Skirmisher",
      (2.8, 1.20, 5.5), [],
      {"body_w_min": 0.50, "body_h_min": 0.44, "body_h_max": 0.76,
       "sponson_w": 0.18, "sponson_zc": 0.10, "sponson_zw": 0.32,
       "barbette_w": 0.36, "barbette_h": 0.16,
       "barbette_zc": 0.50, "barbette_zw": 0.05}),
    H("calder_medium_a", "calder", "medium", "Calder Racer",
      (3.4, 1.20, 5.9), [], {"body_w_min": 0.50, "body_h_min": 0.42,
                             "body_h_max": 0.78, "sponson_w": 0.22,
                             "sponson_zc": 0.05, "sponson_zw": 0.36,
                             "wing_w": 1.20}),
    H("calder_medium_b", "calder", "medium", "Calder Assault Car",
      (3.6, 1.35, 6.1), [],
      {"body_w_min": 0.52, "body_h_min": 0.44, "body_h_max": 0.80,
       "sponson_w": 0.22, "sponson_zc": 0.05, "sponson_zw": 0.38,
       "wing_w": 1.10,
       "barbette_w": 0.40, "barbette_h": 0.20,
       "barbette_zc": 0.30, "barbette_zw": 0.06}),
    H("calder_heavy_a", "calder", "heavy", "Calder Command Car",
      (4.0, 1.55, 6.9), [],
      {"body_w_min": 0.56, "body_h_min": 0.48, "body_h_max": 0.82,
       "sponson_w": 0.22, "sponson_zc": 0.05, "sponson_zw": 0.40,
       "wing_w": 1.20,
       "barbette_w": 0.42, "barbette_h": 0.22,
       "barbette_zc": 0.20, "barbette_zw": 0.06}),

    # -- PILLAR IRONWORKS (7): modular boxy ---------------------------
    H("pillar_medium_a", "pillar", "medium", "Pillar Cell Block",
      (3.6, 1.60, 6.0), [], {}),
    H("pillar_medium_b", "pillar", "medium", "Pillar Twin Stack",
      (3.8, 1.80, 6.3), [], {"barbette_w": 0.30, "barbette_h": 0.20,
                             "barbette_zc": 0.30, "barbette_zw": 0.06}),
    H("pillar_heavy_a", "pillar", "heavy", "Pillar Slab",
      (4.5, 1.90, 7.5), [], {}),
    H("pillar_heavy_b", "pillar", "heavy", "Pillar Battlement",
      (4.7, 2.10, 7.7), [],
      {"barbette_w": 0.42, "barbette_h": 0.20,
       "barbette_zc": 0.20, "barbette_zw": 0.06}),
    H("pillar_transport_a", "pillar", "transport", "Pillar Container Carrier",
      (3.9, 1.50, 8.5), [("flatbed", {"z0": -0.20, "z1": 0.96,
                                      "deck_h": 0.18, "rail_h": 0.30})],
      {"transport_well": True}),
    H("pillar_transport_c", "pillar", "transport", "Pillar Twin Well",
      (4.3, 1.80, 8.9), [], {"transport_well": True}),

    # -- HARTMANN PANZERWERK (8): real tanks ---------------------------
    # Arrowhead plan bow, tank-tub section with a hard sponson crease,
    # long glacis rise, stepped rear engine deck, optional turret race.
    H("hartmann_scout_a", "hartmann", "scout", "Hartmann Ferret",
      (2.5, 1.05, 4.2), [("mast", {"mh": 0.55, "z": 0.16})],
      {"race_w": 0.48, "race_h": 0.09, "tip_w": 0.70, "nose_frac": 0.16}),
    H("hartmann_light_a", "hartmann", "light", "Hartmann Lancer",
      (2.9, 1.10, 5.0), [],
      {"race_w": 0.52, "race_h": 0.10, "race_zw": 0.16}),
    H("hartmann_medium_a", "hartmann", "medium", "Hartmann Sabre",
      (3.5, 1.35, 5.9), [],
      {"race_w": 0.56, "race_h": 0.11, "race_zw": 0.17, "race_zc": -0.04}),
    H("hartmann_heavy_a", "hartmann", "heavy", "Hartmann Bastion",
      (4.4, 1.70, 7.2), [],
      {"race_w": 0.58, "race_h": 0.12, "race_zw": 0.18, "belly_frac": 0.52}),
    H("hartmann_transport_a", "hartmann", "transport", "Hartmann Grenadier",
      (3.9, 1.55, 7.4), [("well", {"z0": -0.16, "z1": 0.88,
                                   "wall_h": 0.26, "w": 0.78})],
      {"nose_frac": 0.18, "tip_w": 0.70, "race_w": 0.54, "race_h": 0.10,
       "engine_drop": 0.06}),
    H("hartmann_oddball_a", "hartmann", "oddball", "Hartmann Long Nose",
      (4.0, 1.25, 6.8), [],
      {"nose_frac": 0.28, "tip_w": 0.64, "race_w": 0.50, "race_h": 0.10,
       "engine_z": 0.98, "engine_drop": 0.0, "sill_frac": 0.34}),

    # -- BALLARD DEEPWORKS (7): submarines ------------------------------
    # Faceted teardrop: flat keel, max beam below mid-height, slanted
    # topsides to a narrower deck, integrated conning sail.
    H("ballard_scout_a", "ballard", "scout", "Ballard Minnow",
      (2.4, 1.20, 4.1), [],
      {"sail_w": 0.26, "sail_h": 0.30, "bow_frac": 0.24}, domain="Naval"),
    H("ballard_light_a", "ballard", "light", "Ballard Pike",
      (2.9, 1.35, 5.2), [("mast", {"mh": 0.42, "z": -0.18})],
      {"sail_h": 0.38}, domain="Naval"),
    H("ballard_medium_a", "ballard", "medium", "Ballard Greyback",
      (3.5, 1.60, 6.2), [],
      {"sail_w": 0.32, "sail_h": 0.40}, domain="Naval"),
    H("ballard_heavy_a", "ballard", "heavy", "Ballard Leviathan",
      (4.4, 1.90, 7.5), [("mast", {"mh": 0.46, "z": -0.18})],
      {"sail_h": 0.36, "stern_w": 0.34}, domain="Naval"),
    H("ballard_transport_a", "ballard", "transport", "Ballard Whale",
      (3.9, 1.70, 8.4), [("trunk", {"th": 0.30, "w": 0.56,
                                    "z0": -0.30, "z1": 0.40})],
      {"sail_h": 0.30, "sail_w": 0.26, "deck_frac": 0.68}, domain="Naval"),
    H("ballard_oddball_a", "ballard", "oddball", "Ballard Ram",
      (4.1, 1.50, 6.5), [],
      {"sail_w": 0.0, "bow_frac": 0.12, "keel_frac": 0.44,
       "stern_w": 0.42}, domain="Naval"),

    # -- TALLOW additions folded into the consolidated block above --------

    # -- KESTREL AEROWORKS additions (2): more fuselages ----------------
    # -- HALVORSEN YARD additions (3): more boats -----------------------
    # -- CALDER MOBILITY additions (2): extreme arrowheads --------------
    # -- MOREAU YARDS (8): rounded, waisted, double-ended ---------------
    # 16-facet rounded section, both ends taper away, optional midships
    # waist. The hull leaves its bounding box alone for most of its length.
    H("moreau_scout_a", "moreau", "scout", "Moreau Otter",
      (2.5, 1.10, 4.3), [("mast", {"mh": 0.50, "z": 0.05})],
      {"bow_frac": 0.22, "stern_frac": 0.22}, domain="Naval"),
    H("moreau_light_a", "moreau", "light", "Moreau Wavepiercer",
      (3.0, 1.25, 5.4), [],
      {"bow_style": "arrow", "bow_frac": 0.30, "tip_w": 0.08,
       "tip_h": 0.40, "stern_frac": 0.18}, domain="Naval"),
    H("moreau_medium_a", "moreau", "medium", "Moreau Wasp",
      (3.6, 1.50, 6.2), [],
      {"waist": 0.30, "waist_zw": 0.16, "bow_frac": 0.20,
       "stern_frac": 0.20, "blister": 0.16, "blister_zc": 0.03,
       "blister_zw": 0.08}, domain="Naval"),
    H("moreau_heavy_a", "moreau", "heavy", "Moreau Colossus",
      (4.5, 1.90, 7.6), [],
      {"waist": 0.24, "waist_zw": 0.14, "bow_frac": 0.22,
       "stern_frac": 0.22, "blister": 0.40, "blister_zc": 0.0,
       "blister_zw": 0.16}, domain="Naval"),
    H("moreau_transport_a", "moreau", "transport", "Moreau Wellship",
      (4.0, 1.60, 8.3), [("well", {"z0": -0.10, "z1": 0.80,
                                   "wall_h": 0.28, "w": 0.70})],
      {"waist": 0.10, "waist_zc": -0.40, "bow_frac": 0.20,
       "stern_frac": 0.20}, domain="Naval"),
    H("moreau_oddball_a", "moreau", "oddball", "Moreau Diamond",
      (4.2, 1.45, 6.6), [],
      {"bow_style": "arrow", "bow_frac": 0.46, "tip_w": 0.04,
       "tip_h": 0.30, "stern_style": "point", "stern_frac": 0.46,
       "stern_tip_w": 0.04, "stern_tip_h": 0.30, "waist": 0.10},
      domain="Naval"),
    H("moreau_oddball_b", "moreau", "oddball", "Moreau Skimmer",
      (3.7, 1.25, 5.7), [],
      {"waist": 0.34, "waist_zw": 0.15, "bow_style": "arrow",
       "bow_frac": 0.28, "tip_w": 0.06, "tip_h": 0.38,
       "stern_frac": 0.24}),

    # -- DURHAM MOTORS (8): regular-old-vehicles -------------------------
    # Boxy utility trucks / APCs: flat sides, cab-over windshield step,
    # cargo bed. Every silhouette reads as a real truck at 40 m.
    H("durham_scout_a", "durham", "scout", "Durham Courier",
      (2.5, 1.05, 4.2), [("mast", {"mh": 0.52, "z": 0.14})],
      {"cab_frac": 0.34, "cab_h": 0.92, "cargo_h": 0.62}),
    H("durham_light_a", "durham", "light", "Durham Mule",
      (2.9, 1.10, 5.0), [],
      {"cab_frac": 0.30, "cab_h": 0.96, "cargo_h": 0.70}),
    H("durham_light_b", "durham", "light", "Durham Gun Mule",
      (3.0, 1.15, 5.1), [("barbette", {"z": 0.22, "r": 0.26, "bh": 0.20})],
      {"cab_frac": 0.28, "cab_h": 0.94, "cargo_h": 0.72}),
    H("durham_medium_a", "durham", "medium", "Durham Boxer",
      (3.5, 1.35, 6.0), [],
      {"cab_frac": 0.32, "cab_h": 1.00, "cargo_h": 0.74}),
    H("durham_medium_b", "durham", "medium", "Durham Stake Bed",
      (3.6, 1.45, 6.1), [("flatbed", {"z0": 0.08, "z1": 0.88, "rail_h": 0.22})],
      {"cab_frac": 0.26, "cab_h": 0.96, "cargo_h": 0.68, "nose_taper": 0.08}),
    H("durham_heavy_a", "durham", "heavy", "Durham Hauler",
      (4.4, 1.70, 7.4), [("well", {"z0": -0.10, "z1": 0.84, "wall_h": 0.28, "w": 0.80})],
      {"cab_frac": 0.30, "cab_h": 1.00, "cargo_h": 0.78}),
    H("durham_transport_a", "durham", "transport", "Durham Flatbed",
      (3.9, 1.55, 8.2), [("flatbed", {"z0": -0.06, "z1": 0.92, "rail_h": 0.20})],
      {"cab_frac": 0.22, "cab_h": 0.98, "cargo_h": 0.66}),
    H("durham_oddball_a", "durham", "oddball", "Durham Longnose",
      (4.0, 1.60, 6.4), [("trunk", {"th": 0.30, "w": 0.56, "z0": -0.10, "z1": 0.30})],
      {"cab_frac": 0.44, "cab_h": 0.88, "cargo_h": 0.82, "nose_taper": 0.18}),

    # -- SPECTRE DYNAMICS (8): arrowhead stealth --------------------------
    # Sharp delta plan: tip_w 0.03-0.05, quadratic ease, low flat profile.
    # The arrowhead IS the hull — no extra wings or sponsons needed.
    H("spectre_scout_a", "spectre", "scout", "Spectre Needle",
      (2.4, 0.95, 4.3), [],
      {"nose_frac": 0.40, "tip_w": 0.03, "tip_h": 0.34, "stern_tip_w": 0.68}),
    H("spectre_light_a", "spectre", "light", "Spectre Dart",
      (2.9, 1.05, 5.0), [],
      {"nose_frac": 0.36, "tip_w": 0.04, "tip_h": 0.36}),
    H("spectre_light_b", "spectre", "light", "Spectre Kestrel",
      (3.0, 1.10, 5.2), [],
      {"nose_frac": 0.34, "tip_w": 0.05, "tip_h": 0.38,
       "canopy_w": 0.28, "canopy_h": 0.22, "canopy_zc": -0.06}),
    H("spectre_medium_a", "spectre", "medium", "Spectre Arrowhead",
      (3.5, 1.25, 6.0), [],
      {"nose_frac": 0.36, "tip_w": 0.04, "tip_h": 0.36}),
    H("spectre_medium_b", "spectre", "medium", "Spectre Glaive",
      (3.6, 1.35, 6.2), [("barbette", {"z": 0.08, "r": 0.24, "bh": 0.18})],
      {"nose_frac": 0.38, "tip_w": 0.05, "tip_h": 0.38,
       "canopy_w": 0.32, "canopy_h": 0.20}),
    H("spectre_heavy_a", "spectre", "heavy", "Spectre Halberd",
      (4.5, 1.65, 7.5), [("barbette", {"z": -0.04, "r": 0.30, "bh": 0.20})],
      {"nose_frac": 0.36, "tip_w": 0.04, "tip_h": 0.38, "stern_tip_w": 0.62}),
    H("spectre_transport_a", "spectre", "transport", "Spectre Haul",
      (4.0, 1.55, 8.3), [("well", {"z0": 0.06, "z1": 0.82, "wall_h": 0.26, "w": 0.76})],
      {"nose_frac": 0.30, "tip_w": 0.06, "tip_h": 0.40, "stern_frac": 0.08}),
    H("spectre_oddball_a", "spectre", "oddball", "Spectre Lance",
      (4.1, 1.30, 6.8), [],
      {"nose_frac": 0.50, "tip_w": 0.02, "tip_h": 0.30, "stern_tip_w": 0.48}),

    # -- HEXTON WORKS (8): hexagonal prism, longer than wide ---------------
    # Flat-top hex section (6 facets), blunt glacis bow, not a point.
    # Variants show twin-tube heavies and high aft cabs.
    H("hexton_scout_a", "hexton", "scout", "Hexton Surveyor",
      (2.4, 1.10, 4.4), [("mast", {"mh": 0.48, "z": 0.10})],
      {"top_frac": 0.58, "bottom_frac": 0.60, "nose_frac": 0.12}),
    H("hexton_light_a", "hexton", "light", "Hexton Runner",
      (2.9, 1.15, 5.0), [],
      {"top_frac": 0.55, "bottom_frac": 0.57, "nose_frac": 0.14}),
    H("hexton_light_b", "hexton", "light", "Hexton Picket",
      (3.0, 1.20, 5.1), [("barbette", {"z": 0.10, "r": 0.24, "bh": 0.18})],
      {"top_frac": 0.52, "bottom_frac": 0.55}),
    H("hexton_medium_a", "hexton", "medium", "Hexton Hauler",
      (3.5, 1.35, 6.0), [],
      {"top_frac": 0.56, "bottom_frac": 0.58}),
    H("hexton_medium_b", "hexton", "medium", "Hexton Grid",
      (3.6, 1.45, 6.2), [("flatbed", {"z0": 0.10, "z1": 0.88, "rail_h": 0.20})],
      {"top_frac": 0.54, "bottom_frac": 0.56, "nose_frac": 0.16}),
    H("hexton_heavy_a", "hexton", "heavy", "Hexton Twin",
      (4.6, 1.80, 7.6), [],
      {"twin": True, "gap_frac": 0.14, "top_frac": 0.58, "bottom_frac": 0.60}),
    H("hexton_transport_a", "hexton", "transport", "Hexton Aft-Cab",
      (4.0, 1.60, 8.3), [],
      {"aft_cab": True, "aft_cab_h": 0.42, "aft_cab_w": 0.60, "aft_cab_len": 0.28,
       "top_frac": 0.56, "bottom_frac": 0.58}),
    H("hexton_oddball_a", "hexton", "oddball", "Hexton Longspan",
      (4.2, 1.40, 6.6), [("well", {"z0": -0.06, "z1": 0.70, "wall_h": 0.24, "w": 0.72})],
      {"top_frac": 0.48, "bottom_frac": 0.52, "nose_frac": 0.18, "tail_frac": 0.12}),
]


# ---------------------------------------------------------------------------
# Blender plumbing. Deliberately local rather than imported from
# build_meshes.py: that module's hull path is the one with the reflected axis
# helper, and this catalogue must not be able to pick it up by accident.
# ---------------------------------------------------------------------------

def clear_scene():
    bpy.ops.object.select_all(action="SELECT")
    bpy.ops.object.delete(use_global=False)
    for block in list(bpy.data.meshes):
        if block.users == 0:
            bpy.data.meshes.remove(block)
    for block in list(bpy.data.materials):
        if block.users == 0:
            bpy.data.materials.remove(block)


def new_material(name, color, metallic, roughness):
    mat = bpy.data.materials.new(name)
    mat.use_nodes = True
    bsdf = mat.node_tree.nodes.get("Principled BSDF")
    if bsdf:
        bsdf.inputs["Base Color"].default_value = (
            color[0], color[1], color[2], 1.0)
        if "Metallic" in bsdf.inputs:
            bsdf.inputs["Metallic"].default_value = metallic
        if "Roughness" in bsdf.inputs:
            bsdf.inputs["Roughness"].default_value = roughness
    return mat


def finalize_dual(obj, name, color):
    """Two material slots: 0 = structural, 1 = armour.

    hull_material_builder.gd's apply_hull_materials() overrides surface 0 with
    the structural material and surfaces 1+ with the armour material, so the
    slot ORDER here is load-bearing even though these colours never reach the
    game. Two genuinely distinct materials are also what makes Blender's glTF
    exporter emit two primitives.
    """
    obj.name = name
    bpy.ops.object.select_all(action="DESELECT")
    obj.select_set(True)
    bpy.context.view_layer.objects.active = obj

    bpy.ops.object.shade_flat()
    obj.data.materials.append(
        new_material(name + "_structural_mat", color, 0.15, 0.82))
    obj.data.materials.append(
        new_material(name + "_armor_mat",
                     tuple(min(1.0, c * 1.14) for c in color[:3]), 0.75, 0.40))


def export_glb(obj, path):
    bpy.ops.object.select_all(action="DESELECT")
    obj.select_set(True)
    bpy.context.view_layer.objects.active = obj
    bpy.ops.export_scene.gltf(
        filepath=path,
        use_selection=True,
        export_format="GLB",
        export_yup=True,
        export_apply=True,
    )


def write_sidecar(out_dir, spec, size, color):
    """Sidecar schema per scripts/hull_loader.gd's REQUIRED_FIELDS + optionals."""
    sx, sy, sz = size
    volume = sx * (sy / HEIGHT_BOOST) * sz
    data = {
        "name": spec["name"],
        "hp": round(100.0 + volume * 20.0, 1),
        "weight": round(50.0 + volume * 15.0, 1),
        "metal": 20 + int(volume * 5.0),
        "crystal": 5 + int(volume * 1.0),
        "size": [round(sx, 3), round(sy, 3), round(sz, 3)],
        "color": [round(color[0], 3), round(color[1], 3), round(color[2], 3), 1.0],
        "domain": spec["domain"],
        "base_energy": round(30.0 + volume * 1.5, 1),
        "base_power": round(2.0 + volume * 0.12, 2),
        "base_vision": 20.0,
        "is_foundation": False,
        "category": "hull",
        "visual_yaw_offset_deg": 0.0,
        "visual_pitch_offset_deg": 0.0,
        "visual_roll_offset_deg": 0.0,
        "manufacturer": MANUFACTURERS[spec["mfr"]]["display"],
        "hull_class": spec["cls"].capitalize(),
    }
    with open(os.path.join(out_dir, spec["id"] + ".json"), "w") as f:
        json.dump(data, f, indent=2)
    return data


AUTOFIT_PASSES = 2


def build_geometry(spec, w, h, l):
    """Body + role elements into a fresh bmesh, at the given working size."""
    bm = bmesh.new()
    BODIES[spec["mfr"]](bm, w, h, l, spec["body"])
    for kind, params in spec["elements"]:
        ELEMENTS[kind](bm, w, h, l, params)
    return bm


def autofit(spec):
    """Solve for the working size whose natural AABB lands on the envelope."""
    target = spec["size"]
    work = list(target)
    natural = None
    for _ in range(AUTOFIT_PASSES):
        bm = build_geometry(spec, *work)
        _lo, natural = HF.measure(bm)
        bm.free()
        for i in range(3):
            if natural[i] > 1e-9:
                work[i] *= target[i] / natural[i]
    return tuple(work), natural


def build_one(spec, out_dir):
    w, h, l = spec["size"]
    work, _natural = autofit(spec)
    bm = build_geometry(spec, *work)

    factors = HF.normalize(bm, (w, h, l))
    HF.finish(bm)
    armour_faces = HF.mark_frontal_armour(bm, l / 2.0, front_frac=0.32)
    lo, size = HF.measure(bm)

    mesh = bpy.data.meshes.new(spec["id"] + "_mesh")
    bm.to_mesh(mesh)
    bm.free()
    mesh.update()
    obj = bpy.data.objects.new(spec["id"], mesh)
    bpy.context.collection.objects.link(obj)

    color = MANUFACTURERS[spec["mfr"]]["color"]
    finalize_dual(obj, spec["id"], color)
    export_glb(obj, os.path.join(out_dir, spec["id"] + ".glb"))
    sidecar = write_sidecar(out_dir, spec, size, color)

    mesh_data = obj.data
    bpy.data.objects.remove(obj, do_unlink=True)
    if mesh_data and mesh_data.users == 0:
        bpy.data.meshes.remove(mesh_data)

    print("HULL %-24s aabb=(%.2f, %.2f, %.2f) min=(%.2f, %.2f, %.2f) "
          "fit=(%.3f, %.3f, %.3f) armour=%d hp=%.0f" % (
              spec["id"], size[0], size[1], size[2], lo[0], lo[1], lo[2],
              factors[0], factors[1], factors[2], armour_faces, sidecar["hp"]))
    return size


def parse_args():
    argv = sys.argv
    args = argv[argv.index("--") + 1:] if "--" in argv else []
    only, out_dir, do_list = None, HULLS_DIR, False
    i = 0
    while i < len(args):
        if args[i] == "--only" and i + 1 < len(args):
            only = set(args[i + 1].split(","))
            i += 2
        elif args[i] == "--out" and i + 1 < len(args):
            out_dir = args[i + 1]
            i += 2
        elif args[i] == "--list":
            do_list = True
            i += 1
        else:
            i += 1
    return only, out_dir, do_list


def validate_lineup():
    ids = [s["id"] for s in LINEUP]
    dupes = {i for i in ids if ids.count(i) > 1}
    if dupes:
        raise AssertionError("duplicate hull ids: %s" % sorted(dupes))
    for s in LINEUP:
        if s["mfr"] not in MANUFACTURERS:
            raise AssertionError("%s: unknown manufacturer %s" % (s["id"], s["mfr"]))
        if s["cls"] not in CLASSES:
            raise AssertionError("%s: unknown class %s" % (s["id"], s["cls"]))
        if not s["id"].replace("_", "").isalnum() or s["id"] != s["id"].lower():
            raise AssertionError(
                "%s: HullLoader requires lowercase snake_case [a-z0-9_]+" % s["id"])
        for kind, _p in s["elements"]:
            if kind not in ELEMENTS:
                raise AssertionError("%s: unknown element %s" % (s["id"], kind))
    missing = set(CLASSES) - {s["cls"] for s in LINEUP}
    if missing:
        raise AssertionError("classes with no hull: %s" % sorted(missing))


def main():
    HF.selftest_axis_determinant()
    validate_lineup()
    only, out_dir, do_list = parse_args()

    if do_list:
        for m in MANUFACTURERS:
            rows = [s for s in LINEUP if s["mfr"] == m]
            print("%-11s %2d  %s" % (
                m, len(rows),
                " ".join("%s:%d" % (c, len([r for r in rows if r["cls"] == c]))
                         for c in CLASSES
                         if any(r["cls"] == c for r in rows))))
        print("TOTAL %d hulls" % len(LINEUP))
        return

    os.makedirs(out_dir, exist_ok=True)
    specs = [s for s in LINEUP if only is None or s["id"] in only]
    print("Building %d hull(s) into %s" % (len(specs), out_dir))
    for spec in specs:
        clear_scene()
        build_one(spec, out_dir)
    print("DONE %d hull(s)" % len(specs))


main()
