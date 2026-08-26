# hull_forge.py - geometry core for the vehicle hull catalogue.
#
# WHY THIS EXISTS SEPARATELY FROM build_meshes.py
# -----------------------------------------------
# build_meshes.py's hull path authors through GV(x, y, z) -> (x, z, y), which
# is an axis SWAP: determinant -1, i.e. a reflection. _build_hull then applied
# a second reflection (_hull_orient_matrix, also determinant -1) to "correct"
# the orientation. Two reflections cancel out into a rotation for the vertex
# POSITIONS, but recalc_face_normals ran BETWEEN them, so the winding was
# fixed up against the first reflection and then flipped again by the second.
# Result: every hull built through that path shipped inside out. Verified in
# Godot - see scratch/hull_probe/ and the table below.
#
# This module authors in Godot space and converts with ONE proper rotation.
#
# THE AXIS CHAIN, MEASURED (not assumed)
# --------------------------------------
# scratch/hull_probe/probe_build.py exports six markers on the six raw-Blender
# half-axes; scratch/hull_probe/probe_read.gd reads the .glb back through
# Godot's own GLTFDocument importer and prints where each landed:
#
#   raw Blender +X  ->  Godot +X        (right)
#   raw Blender +Y  ->  Godot -Z        (forward / nose)
#   raw Blender +Z  ->  Godot +Y        (up)
#
# i.e. Godot = (Bx, Bz, -By), so Blender = (Gx, -Gz, Gy). That is BV() below.
# Its determinant is +1, so winding survives it untouched and the single
# recalc_face_normals() at the end of each build is the last word on normals.
#
# Godot's own conventions this matches: forward is local -Z (unit.gd:706
# steers along -transform.basis.z, auto_weapon.gd:571 fires along it,
# classify_facet() classifies armour facets against it). So a hull's nose is
# authored at NEGATIVE Godot Z here, and lands there in game.
#
# NO CURVES, CHAMFERS BY CONSTRUCTION
# -----------------------------------
# Every solid is a loft through explicit polygonal cross-sections. Chamfers
# come from the section outlines themselves (cut corners) plus an auto-inserted
# inset section at each cap, so all edges are chamfered without a single
# bmesh.ops.bevel call - no clamp_overlap surprises, no collapsed bow fans,
# and the facet count stays predictable. Nothing in this module emits a
# circle, sphere or cylinder.

import math

import bmesh


# ---------------------------------------------------------------------------
# Axis conversion
# ---------------------------------------------------------------------------

def BV(gx, gy, gz):
    """Godot-space (x=right, y=up, z=depth, -z=forward) -> raw Blender tuple.

    Blender = (Gx, -Gz, Gy). Determinant +1 - a rotation, NOT a reflection.
    Do not "simplify" this to a bare axis swap like (x, z, y): that is a
    reflection and it inverts face winding, which is the bug this module
    exists to avoid.
    """
    return (gx, -gz, gy)


BV_DETERMINANT = 1.0  # asserted by selftest_axis_determinant()


def selftest_axis_determinant():
    """Guards the one property the whole module rests on."""
    e1 = BV(1, 0, 0)
    e2 = BV(0, 1, 0)
    e3 = BV(0, 0, 1)
    det = (
        e1[0] * (e2[1] * e3[2] - e2[2] * e3[1])
        - e1[1] * (e2[0] * e3[2] - e2[2] * e3[0])
        + e1[2] * (e2[0] * e3[1] - e2[1] * e3[0])
    )
    if abs(det - BV_DETERMINANT) > 1e-9:
        raise AssertionError(
            "BV() determinant is %s, expected %s - a non-+1 determinant "
            "reflects the mesh and inverts winding" % (det, BV_DETERMINANT)
        )
    return det


# ---------------------------------------------------------------------------
# 2D cross-section outlines. All return a list of (x, y) in consistent order.
# These are the per-manufacturer "physical structure" vocabulary - the thing
# that makes a Halvorsen read differently from a Brenntal at 40 metres.
# ---------------------------------------------------------------------------

def rect_outline(w, h, cy=0.0, cx=0.0):
    """Plain rectangle. Brenntal's crisp orthogonal box."""
    hw, hh = w / 2.0, h / 2.0
    return [
        (cx - hw, cy - hh),
        (cx + hw, cy - hh),
        (cx + hw, cy + hh),
        (cx - hw, cy + hh),
    ]


def oct_outline(w, h, cut_x, cut_y, cy=0.0, cx=0.0):
    """Rectangle with its four corners cut off - 8 flat facets, no curve.

    The workhorse. cut_x/cut_y are absolute chamfer widths, clamped so the
    outline can never self-intersect on a thin section.
    """
    hw, hh = w / 2.0, h / 2.0
    cx_ = min(cut_x, hw * 0.9)
    cy_ = min(cut_y, hh * 0.9)
    return [
        (cx - hw + cx_, cy - hh),
        (cx + hw - cx_, cy - hh),
        (cx + hw, cy - hh + cy_),
        (cx + hw, cy + hh - cy_),
        (cx + hw - cx_, cy + hh),
        (cx - hw + cx_, cy + hh),
        (cx - hw, cy + hh - cy_),
        (cx - hw, cy - hh + cy_),
    ]


def trap_outline(w_bot, w_top, h, cy=0.0, cx=0.0):
    """Trapezoid - narrower or wider at the top. Sloped side facets."""
    hh = h / 2.0
    return [
        (cx - w_bot / 2.0, cy - hh),
        (cx + w_bot / 2.0, cy - hh),
        (cx + w_top / 2.0, cy + hh),
        (cx - w_top / 2.0, cy + hh),
    ]


def chine_outline(w_deck, w_keel, h, chine_frac=0.42, cy=0.0, cx=0.0,
                  deck_cut=0.0):
    """HALVORSEN: a hard-chine boat section.

    Wide flat deck on top, near-vertical topsides down to a hard chine break,
    then steeply angled deadrise panels converging on a narrow flat keel.
    Six to eight flat facets, one unmistakable horizontal crease (the chine)
    running the length of the hull. Nothing about it is round.
    """
    hh = h / 2.0
    y_chine = cy - hh + h * chine_frac
    w_chine = w_deck
    pts = [
        (cx - w_keel / 2.0, cy - hh),      # keel, port
        (cx + w_keel / 2.0, cy - hh),      # keel, starboard
        (cx + w_chine / 2.0, y_chine),     # chine, starboard
        (cx + w_deck / 2.0, cy + hh - deck_cut),
    ]
    if deck_cut > 0.0:
        pts.append((cx + w_deck / 2.0 - deck_cut, cy + hh))
        pts.append((cx - w_deck / 2.0 + deck_cut, cy + hh))
    else:
        pts.append((cx - w_deck / 2.0, cy + hh))
    pts.append((cx - w_deck / 2.0, cy + hh - deck_cut))
    pts.append((cx - w_chine / 2.0, y_chine))
    # De-duplicate the degenerate deck point when deck_cut == 0.
    out = []
    for p in pts:
        if not out or (abs(p[0] - out[-1][0]) > 1e-6 or abs(p[1] - out[-1][1]) > 1e-6):
            out.append(p)
    return out


def cant_outline(w, h, shear_top=0.0, shear_bot=0.0, cy=0.0, cx=0.0,
                 cut=0.0):
    """ORRIN: a sheared quadrilateral - top and bottom edges offset in X by
    different amounts, so the two side facets are NOT parallel. Feed different
    shear values per section and no two faces on the hull agree."""
    hh = h / 2.0
    hw = w / 2.0
    c = min(cut, hw * 0.8)
    return [
        (cx - hw + shear_bot + c, cy - hh),
        (cx + hw + shear_bot, cy - hh),
        (cx + hw + shear_top, cy + hh),
        (cx - hw + shear_top + c, cy + hh),
    ]


def hex_flat_outline(w, h, top_frac=0.55, bottom_frac=0.55, cy=0.0, cx=0.0):
    """HEXTON: flat-top hexagon - 6 flat facets, longer than wide extrusion.

    Top and bottom edges are horizontal, mid-sides come to a point at
    (±w/2, cy). top_frac/bottom_frac scale the top/bottom edge lengths
    relative to w (0.55 ≈ regular flat-top hex). Irregular hex supported
    for variant width without losing the 6-sided read."""
    hh = h / 2.0
    # Clamp fracs so top/bottom never exceed mid width.
    tf = max(0.1, min(0.9, top_frac))
    bf = max(0.1, min(0.9, bottom_frac))
    tw = w * tf
    bw = w * bf
    return [
        (cx - bw / 2.0, cy - hh),   # 0 bottom-left
        (cx + bw / 2.0, cy - hh),   # 1 bottom-right
        (cx + w / 2.0, cy),         # 2 mid-right point
        (cx + tw / 2.0, cy + hh),   # 3 top-right
        (cx - tw / 2.0, cy + hh),   # 4 top-left
        (cx - w / 2.0, cy),         # 5 mid-left point
    ]


def flat_floor_oct_outline(w, h, cut, cy=0.0, cx=0.0):
    """KESTREL: faceted fuselage tube - eight facets, but with a FLAT wide
    floor (a cargo deck was cut into it) and heavier chamfers up top. Reads
    as an aircraft body section that has been squared off, not a pipe."""
    hw, hh = w / 2.0, h / 2.0
    c = min(cut, hw * 0.7, hh * 0.7)
    floor_half = hw - c * 0.35
    return [
        (cx - floor_half, cy - hh),
        (cx + floor_half, cy - hh),
        (cx + hw, cy - hh + c * 0.8),
        (cx + hw, cy + hh - c),
        (cx + hw - c, cy + hh),
        (cx - hw + c, cy + hh),
        (cx - hw, cy + hh - c),
        (cx - hw, cy - hh + c * 0.8),
    ]


# ---------------------------------------------------------------------------
# Outline transforms
# ---------------------------------------------------------------------------

def scale_outline(pts, fx, fy, cy=0.0):
    return [(x * fx, (y - cy) * fy + cy) for (x, y) in pts]


def offset_outline(pts, dx=0.0, dy=0.0):
    return [(x + dx, y + dy) for (x, y) in pts]


def inset_outline(pts, amount):
    """Pull every point toward the outline's centroid by `amount` (absolute).

    Used to build the cap chamfer: a section inset by the chamfer width,
    placed one chamfer-width in from the end, turns the flat end cap into a
    ring of angled facets. Cheap, robust, and never self-intersects because
    the pull is clamped to 40% of each point's own distance from the centre.
    """
    if not pts:
        return pts
    cx = sum(p[0] for p in pts) / len(pts)
    cy = sum(p[1] for p in pts) / len(pts)
    out = []
    for (x, y) in pts:
        dx, dy = cx - x, cy - y
        d = math.hypot(dx, dy)
        if d < 1e-9:
            out.append((x, y))
            continue
        t = min(amount / d, 0.4)
        out.append((x + dx * t, y + dy * t))
    return out


# ---------------------------------------------------------------------------
# Lofted solid construction
# ---------------------------------------------------------------------------

def add_solid(bm, sections, cap_chamfer=0.0):
    """Loft a closed solid through `sections`, in Godot space.

    sections: list of (z, outline) ordered nose(-z) -> tail(+z). Every outline
              must have the same point count.
    cap_chamfer: if > 0, an inset section is inserted just inside each end so
              the end caps meet the sides through angled facets instead of a
              90-degree edge.

    Non-convex outlines are supported. A non-convex outline happens when a
    hull's cross-section is a single closed polygon that includes all the
    structural features as part of the outline (e.g. the T-shape of a
    plinth + casemate). bmesh's quad-strip between two rings of verts can
    fail for a non-planar or twisted quad, and that failure is caught and
    the face is replaced with two triangles (a strip split) so the
    non-convex outline still produces a closed surface. This is what
    makes the single-mesh, single-loft body builder possible - the
    casemate is no longer a separate solid tier, it is part of the
    main body's cross-section.

    Returns the list of bmesh faces created, so callers can tag them (e.g.
    frontal armour -> material slot 1).
    """
    secs = [(z, list(o)) for (z, o) in sections]
    if len(secs) < 2:
        raise ValueError("add_solid needs at least 2 sections")
    n = len(secs[0][1])
    for z, o in secs:
        if len(o) != n:
            raise ValueError(
                "all sections need the same point count (%d != %d at z=%s)"
                % (len(o), n, z)
            )

    if cap_chamfer > 0.0:
        z0, o0 = secs[0]
        z1, o1 = secs[-1]
        span = abs(secs[-1][0] - secs[0][0])
        c = min(cap_chamfer, span * 0.2)
        secs.insert(0, (z0 - 0.0, inset_outline(o0, c)))
        secs[1] = (z0 + c, o0)
        secs.append((z1, inset_outline(o1, c)))
        secs[-2] = (z1 - c, o1)

    rings = []
    for z, outline in secs:
        rings.append([bm.verts.new(BV(x, y, z)) for (x, y) in outline])

    faces = []
    for k in range(len(rings) - 1):
        a, b = rings[k], rings[k + 1]
        for i in range(n):
            j = (i + 1) % n
            try:
                faces.append(bm.faces.new((a[i], a[j], b[j], b[i])))
            except ValueError:
                # Non-convex outline: the quad is twisted or non-planar, so
                # bmesh refuses it. Split it into two triangles along the
                # shorter diagonal - that's a robust fallback for any pair
                # of corresponding edges between two rings.
                try:
                    faces.append(bm.faces.new((a[i], a[j], b[j])))
                except ValueError:
                    pass
                try:
                    faces.append(bm.faces.new((a[i], b[j], b[i])))
                except ValueError:
                    pass
    try:
        faces.append(bm.faces.new(tuple(rings[0])))
    except ValueError:
        pass
    try:
        faces.append(bm.faces.new(tuple(reversed(rings[-1]))))
    except ValueError:
        pass
    return faces


def loft_evolution(bm, z_start, z_end, section_fn, n_sections,
                   cap_chamfer=0.0):
    """Loft a solid by sampling section_fn at evenly-spaced z positions.

    This is the cross-section-evolution pattern that the 8-manufacturer
    rewrite leans on. The caller writes a section_fn(z) -> outline (list of
    (x, y) points, in Godot cross-section space). The function samples it at
    n_sections positions from z_start to z_end, then defers to add_solid().

    All sampled outlines must have the same point count (add_solid() asserts
    this). That is the discipline that makes the result a single, continuous
    mesh rather than a stack of bolted-on boxes: the cross-section has a
    fixed number of "stations" around its perimeter, and as z progresses
    those stations move - up, down, in, out - to grow bulges, wheel arches,
    cab roofs, sponson shoulders and similar structural features. A feature
    that is only present over part of the length collapses its extra
    stations onto the main outline outside its z range, so the mesh stays
    one closed surface with no separate solid to glue to the next one.

    n_sections of 2 means "front section, back section" - the degenerate
    case where a hull with no length-wise evolution just becomes a lozenge.
    n_sections of 6-8 is a good default for most bodies; bump it for a hull
    whose cross-section changes a lot along its length (a raked bow, a
    stepped tail boom).
    """
    if n_sections < 2:
        raise ValueError("loft_evolution needs at least 2 sections")
    sections = []
    for i in range(n_sections):
        t = i / (n_sections - 1)
        z = z_start + (z_end - z_start) * t
        sections.append((z, section_fn(z)))
    return add_solid(bm, sections, cap_chamfer=cap_chamfer)


def smooth_transition(z, z_center, z_half_width):
    """0/1 smoothstep that is 0 outside [z_center - z_half_width,
    z_center + z_half_width] and 1 inside it, with a 30% ramp at each edge.

    Used by section_fn callers to grow a feature (casemate, sponson, bulge)
    up from 0 to full height as z enters its region, and back down as z
    leaves it. Multiplying a bulge's height (or width) by this gives the
    cross-section a real evolution instead of a step.
    """
    dz = abs(z - z_center) - z_half_width
    if dz <= 0.0:
        return 1.0
    ramp = z_half_width * 0.30
    if dz >= ramp:
        return 0.0
    t = 1.0 - (dz / ramp)
    return t * t * (3.0 - 2.0 * t)


def add_chamfered_box(bm, center, size, cut=None, cut_y=None):
    """Axis-aligned box with all twelve edges chamfered. The generic large
    greeble: masts, plinths, beams, outrigger pods, ballast blocks."""
    cx, cy, cz = center
    sx, sy, sz = size
    if cut is None:
        cut = min(sx, sy, sz) * 0.16
    if cut_y is None:
        cut_y = cut
    outline = oct_outline(sx, sy, cut, cut_y, cy=cy, cx=cx)
    hz = sz / 2.0
    return add_solid(
        bm,
        [(cz - hz, outline), (cz + hz, outline)],
        cap_chamfer=cut,
    )


def add_wedge(bm, center, size, front_h_frac=0.35, cut=None):
    """A box whose front is a single big angled plate - the glacis vocabulary.
    front_h_frac is the front face's height as a fraction of the rear's."""
    cx, cy, cz = center
    sx, sy, sz = size
    if cut is None:
        cut = min(sx, sy) * 0.12
    hz = sz / 2.0
    y_bot = cy - sy / 2.0
    front_h = sy * front_h_frac
    front = oct_outline(sx * 0.94, front_h, cut, cut * 0.6,
                        cy=y_bot + front_h / 2.0, cx=cx)
    rear = oct_outline(sx, sy, cut, cut, cy=cy, cx=cx)
    return add_solid(bm, [(cz - hz, front), (cz + hz, rear)], cap_chamfer=cut)


def add_ridge(bm, z0, z1, y0, y1, w_bot, w_top, cx=0.0, cut=None):
    """A dorsal spine: a long low trapezoidal-section ridge along the hull's
    top. Large-scale role greeble, readable in silhouette from any angle."""
    if cut is None:
        cut = w_top * 0.3
    h = y1 - y0
    outline = trap_outline(w_bot, w_top, h, cy=(y0 + y1) / 2.0, cx=cx)
    return add_solid(bm, [(z0, outline), (z1, outline)], cap_chamfer=cut)


# There is deliberately no add_plate()/tilt primitive. An earlier one built its
# quad in the XZ plane with the thickness on Y, so "tilting" a thin plate moved
# its edges by almost nothing and the Halvorsen bow ramp rendered as a flat
# tongue. Anything that needs to lean should be lofted through add_solid() with
# the cross-section's cy moving between sections - the lean is then real
# geometry and every facet stays planar by construction.


# ---------------------------------------------------------------------------
# Face tagging
# ---------------------------------------------------------------------------

def mark_frontal_armour(bm, hz, front_frac=0.32, slot=1):
    """Tag the frontal arc for material slot 1 (the armour material).

    hull_material_builder.gd's apply_hull_materials() puts the structural
    material on surface 0 and the armour material on surface 1+, so a hull
    wants exactly two material slots with the front faces on the second.
    Faces are selected by POSITION (front fraction of length) rather than
    normal angle, and belly faces are excluded - armouring the underside
    spends area nobody ever sees.

    Godot -Z is the nose, so "front" is the most-negative-Z end. In raw
    Blender space that is +Y (BV maps Godot z to Blender -y), and Godot +Y
    (up) is Blender +Z - hence the .y / .z reads below.
    """
    cutoff_gz = -hz + 2.0 * hz * front_frac
    count = 0
    for f in bm.faces:
        c = f.calc_center_median()
        godot_z = -c.y
        godot_normal_y = f.normal.z
        if godot_z < cutoff_gz and godot_normal_y > -0.55:
            f.material_index = slot
            count += 1
    return count


def finish(bm):
    """The last word on winding. Called once per hull, after every solid is
    in place and before the mesh leaves bmesh. Nothing may transform the mesh
    after this point - that is precisely the mistake that shipped the previous
    catalogue inside out."""
    bmesh.ops.recalc_face_normals(bm, faces=list(bm.faces))


def measure(bm):
    """Godot-space AABB (min, size) of everything currently in the bmesh."""
    xs, ys, zs = [], [], []
    for v in bm.verts:
        xs.append(v.co.x)
        ys.append(v.co.z)     # Blender +Z is Godot +Y
        zs.append(-v.co.y)    # Blender +Y is Godot -Z
    if not xs:
        return (0.0, 0.0, 0.0), (0.0, 0.0, 0.0)
    lo = (min(xs), min(ys), min(zs))
    size = (max(xs) - lo[0], max(ys) - lo[1], max(zs) - lo[2])
    return lo, size


# Tight on purpose. build_vehicle_hulls.py's autofit() solves the working size
# first, so every hull in the shipped lineup normalizes at exactly 1.000 on all
# three axes and this only fires on a genuinely broken new design - most often
# an element whose vertical extent was derived from `w` instead of `h`, which
# makes the autofit solve non-convergent. Fix the element, don't raise this.
NORMALIZE_TOLERANCE = 0.10


def normalize(bm, target, tolerance=NORMALIZE_TOLERANCE):
    """Scale and recentre the mesh so its Godot AABB is exactly `target`.

    Why exact rather than "measure whatever came out and declare that":
    a hull's declared `size` drives HP, weight, metal, crystal and the
    module-mounting area, so the class bands have to mean something. Letting a
    tall sensor mast silently inflate a scout's envelope by 60% would hand it
    a heavy's stat line. The envelope is the design contract; the geometry
    fits it.

    Every scale factor is POSITIVE, so the transform's determinant is positive
    and face winding is untouched - the one property this whole module is
    organised around. That is asserted, not assumed.

    `tolerance` guards against a design that missed its envelope so badly that
    normalizing would visibly distort it: a factor outside
    [1-tolerance, 1+tolerance] on any axis raises instead of quietly squashing
    the hull. Tune the design, don't widen the tolerance.

    Returns the (sx, sy, sz) factors applied, for reporting.
    """
    lo, size = measure(bm)
    tx, ty, tz = target
    factors = []
    for actual, want in ((size[0], tx), (size[1], ty), (size[2], tz)):
        factors.append(1.0 if actual < 1e-9 else want / actual)
    fx, fy, fz = factors
    for f, axis in zip(factors, "xyz"):
        if f <= 0.0:
            raise AssertionError("non-positive scale on %s would flip winding" % axis)
        if not (1.0 - tolerance <= f <= 1.0 + tolerance):
            raise AssertionError(
                "normalize factor %.3f on %s is outside +-%.0f%% - the design "
                "envelope and the geometry disagree too much to fix by scaling "
                "(measured %s, target %s)"
                % (f, axis, tolerance * 100.0, size, target))

    # Centre of the measured box, in Godot axes.
    mid_g = (lo[0] + size[0] / 2.0, lo[1] + size[1] / 2.0, lo[2] + size[2] / 2.0)
    for v in bm.verts:
        gx = v.co.x
        gy = v.co.z
        gz = -v.co.y
        gx = (gx - mid_g[0]) * fx
        gy = (gy - mid_g[1]) * fy
        gz = (gz - mid_g[2]) * fz
        v.co = BV(gx, gy, gz)
    return (fx, fy, fz)
