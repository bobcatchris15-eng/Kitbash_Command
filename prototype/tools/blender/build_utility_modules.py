"""
Kitbash Command - Utility Module Mesh Builder (Rework Pass)
Run headlessly with UPBGE:
  UPBGE-0.30-windows-x86_64\\blender.exe --background --python tools\\blender\\build_utility_modules.py

Produces refined multi-part GLBs for three support modules:
  - Sensor Suite (Radar Mast):   sensor_suite_mount / sensor_suite_mast / sensor_suite_dish
  - Resource Harvester:          resource_harvester_mount / resource_harvester_arm / resource_harvester_drill
  - Repair Array:                repair_array_mount / repair_array_arm / repair_array_welder
  - Drone Carrier (unchanged):   drone_carrier_mount / drone_carrier_housing / drone_carrier_drone

COORDINATE CONVENTION  (same as build_meshes.py):
  Blender is authored Z-up. The glTF exporter's Y-up conversion maps:
    Godot_X = Blender_X,  Godot_Y = Blender_Z,  Godot_Z = Blender_Y
  GV(x, y, z) -> raw Blender (x, z, y)   [point positions]
  GS(sx, sy, sz) -> raw Blender (sx, sz, sy) [sizes/scales]
  So all authoring code is written in Godot X/Y/Z semantics.

ANIMATION CONTRACTS (must NOT be broken - game code depends on these):
  sensor_suite_dish.glb  - origin at Godot (0,0,0), dish faces +Z (Blender +Y).
                           auto_weapon.gd gets node "sensor_suite_dish" and calls rotate_y each frame.
  resource_harvester_drill.glb - origin at tip pivot. visual_builder places it at the boom end.
  repair_array_arm / repair_array_welder - visual_builder positions & rotates each radially at runtime.

ART RULES (VISUAL_ART_DIRECTION.md):
  - No crew-served fittings: no grips, triggers, handwheels, eyepieces, seats.
  - Optics: boxed camera housings with a lens disc on the outside face, or LIDAR drums.
  - Remote hardware vocabulary: servo cans, cable glands, solenoid conduits, heat fins.
  - Mount origins sit at deck level (Godot Y=0, raw Blender Z=0).
  - Bevels keyed to part size - use smaller bevels on instanced/repeated geometry.
"""

import bpy
import bmesh
import math
import os
import mathutils

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
PROJECT_ROOT = os.path.abspath(os.path.join(SCRIPT_DIR, "..", ".."))
PARTS_DIR = os.path.join(PROJECT_ROOT, "assets", "models", "parts")
os.makedirs(PARTS_DIR, exist_ok=True)


# ---------------------------------------------------------------------------
# Coordinate helpers (Godot-space -> raw Blender-space)
# ---------------------------------------------------------------------------

def GV(x, y, z):
    """Godot (x, y_up, z_depth) -> raw Blender (x, z, y)."""
    return (x, z, y)


def GS(sx, sy, sz):
    """Godot (width, height, depth) -> raw Blender scale (width, depth, height)."""
    return (sx, sz, sy)


# ---------------------------------------------------------------------------
# Scene helpers
# ---------------------------------------------------------------------------

def clear_scene():
    bpy.ops.object.select_all(action='SELECT')
    bpy.ops.object.delete(use_global=False)
    for block in list(bpy.data.meshes):
        if block.users == 0:
            bpy.data.meshes.remove(block)
    for block in list(bpy.data.materials):
        if block.users == 0:
            bpy.data.materials.remove(block)


# ---------------------------------------------------------------------------
# Primitive builders  (all take raw Blender coordinates for pos/size)
# ---------------------------------------------------------------------------

def _cone(bm, pos, r1, r2, depth, segments, rot=None):
    res = bmesh.ops.create_cone(bm, cap_ends=True, cap_tris=False, segments=segments,
                                radius1=r1, radius2=r2, depth=depth)
    loc = mathutils.Vector(pos)
    for v in res['verts']:
        v.co = (rot @ v.co if rot else v.co) + loc


def add_cyl_z(bm, pos, radius, height, segments=16):
    """Vertical cylinder (Blender Z / Godot Y up)."""
    _cone(bm, pos, radius, radius, height, segments)


def add_cone_z(bm, pos, r_bot, r_top, height, segments=16):
    """Frustum/cone along Blender Z."""
    _cone(bm, pos, r_top, r_bot, height, segments)


def add_cyl_y(bm, pos, radius, height, segments=16):
    """Horizontal cylinder along Blender Y (Godot -Z / forward)."""
    rot = mathutils.Matrix.Rotation(math.radians(90), 4, 'X')
    _cone(bm, pos, radius, radius, height, segments, rot)


def add_cyl_x(bm, pos, radius, height, segments=16):
    """Horizontal cylinder along Blender X."""
    rot = mathutils.Matrix.Rotation(math.radians(90), 4, 'Y')
    _cone(bm, pos, radius, radius, height, segments, rot)


def add_box(bm, pos, size, bevel=0.0, bevel_segments=2, rot_z=0.0):
    """Box centred at pos with given size. rot_z rotates around Blender Z."""
    loc = mathutils.Vector(pos)
    res = bmesh.ops.create_cube(bm, size=1.0)
    rot = mathutils.Matrix.Rotation(rot_z, 4, 'Z')
    for v in res['verts']:
        v.co = rot @ mathutils.Vector((v.co.x * size[0],
                                       v.co.y * size[1],
                                       v.co.z * size[2])) + loc
    if bevel > 0.001:
        edges = [e for e in bm.edges if any(v in res['verts'] for v in e.verts)]
        try:
            bmesh.ops.bevel(bm, geom=edges, offset=bevel,
                            segments=max(1, bevel_segments), affect='EDGES')
        except Exception:
            pass


def add_tube_between(bm, p0, p1, radius, segments=8):
    """Tube spanning two Blender-space points."""
    a = mathutils.Vector(p0)
    b = mathutils.Vector(p1)
    d = b - a
    length = d.length
    if length < 1e-5:
        return
    res = bmesh.ops.create_cone(bm, cap_ends=True, cap_tris=False, segments=segments,
                                radius1=radius, radius2=radius, depth=length)
    rot = mathutils.Vector((0, 0, 1)).rotation_difference(d.normalized()).to_matrix().to_4x4()
    mid = (a + b) / 2.0
    for v in res['verts']:
        v.co = (rot @ v.co) + mid


def bolt_ring_z(bm, z, radius, count=8, bolt_r=0.007, bolt_h=0.012):
    """Ring of cylindrical bolt heads around a Z-axis circle."""
    for i in range(count):
        a = (i / count) * math.tau
        add_cyl_z(bm, (math.cos(a) * radius, math.sin(a) * radius, z), bolt_r, bolt_h, segments=6)


# ---------------------------------------------------------------------------
# Export helper
# ---------------------------------------------------------------------------

def export_bmesh(bm, object_name, filename,
                 color=(0.24, 0.26, 0.28), metallic=0.70, roughness=0.32):
    me = bpy.data.meshes.new(object_name + "_mesh")
    bm.to_mesh(me)
    bm.free()

    obj = bpy.data.objects.new(object_name, me)
    bpy.context.collection.objects.link(obj)

    bpy.ops.object.select_all(action='DESELECT')
    obj.select_set(True)
    bpy.context.view_layer.objects.active = obj
    bpy.ops.object.shade_smooth()
    try:
        obj.data.use_auto_smooth = True
        obj.data.auto_smooth_angle = math.radians(35)
    except Exception:
        pass

    mat = bpy.data.materials.new(name=object_name + "_mat")
    mat.use_nodes = True
    bsdf = mat.node_tree.nodes.get("Principled BSDF")
    if bsdf:
        bsdf.inputs['Base Color'].default_value = (color[0], color[1], color[2], 1.0)
        bsdf.inputs['Metallic'].default_value = metallic
        bsdf.inputs['Roughness'].default_value = roughness
    obj.data.materials.append(mat)

    filepath = os.path.join(PARTS_DIR, filename)
    bpy.ops.export_scene.gltf(
        filepath=filepath,
        use_selection=True,
        export_format='GLB',
        export_yup=True,
        export_apply=True,
    )
    print("Exported:", filepath)
    clear_scene()


# ---------------------------------------------------------------------------
# SENSOR SUITE (RADAR MAST)
# ---------------------------------------------------------------------------
# Three separate GLBs:
#   sensor_suite_mount.glb  — static deck pedestal, bolt ring, cable conduit trunks
#   sensor_suite_mast.glb   — lattice truss mast (static, Y-scaled by mast_height tweak)
#   sensor_suite_dish.glb   — rotating phased-array/parabolic head + yoke pivot
#                             Origin at (0,0,0) in its own space = the rotation axis
#                             auto_weapon.gd calls rotate_y() on the node named "sensor_suite_dish"

def build_sensor_suite_mount():
    """
    Octagonal deck pedestal with weld collar, cable conduit trunks and bolt ring.
    Sits flush at Godot Y=0 / Blender Z=0.  Top face is at Blender Z=0.12.
    """
    bm = bmesh.new()

    # Main octagonal base plate
    add_cyl_z(bm, (0, 0, 0.04), 0.26, 0.08, segments=8)
    # Bevelled top collar
    add_cone_z(bm, (0, 0, 0.10), 0.17, 0.13, 0.04, segments=16)
    # Mast socket tube sticking up
    add_cyl_z(bm, (0, 0, 0.13), 0.055, 0.06, segments=12)

    # Bolt ring around base
    bolt_ring_z(bm, 0.09, 0.20, count=8)

    # Four cable conduit trunks at 45-degree offsets
    for i in range(4):
        a = math.radians(45 + i * 90)
        cx = math.cos(a) * 0.19
        cy = math.sin(a) * 0.19
        add_box(bm, (cx, cy, 0.06), (0.03, 0.05, 0.07), bevel=0.004)

    # Servo drive housing on one side (art rule: remote operation hardware)
    add_box(bm, (0.0, -0.21, 0.07), (0.07, 0.06, 0.06), bevel=0.006)
    # Cable gland stub on servo housing
    add_cyl_y(bm, (0.0, -0.25, 0.07), 0.012, 0.03, segments=8)

    export_bmesh(bm, "sensor_suite_mount", "sensor_suite_mount.glb",
                 color=(0.18, 0.20, 0.24), metallic=0.72, roughness=0.38)


def build_sensor_suite_mast():
    """
    Lattice truss mast column.  Total height in Blender Z = 1.0 unit.
    visual_builder.gd scales this Vector3(1.0, mast_height, 1.0) so cross-truss
    ring heights are evenly distributed and stretch correctly.
    Origin at base (Blender Z=0), top at Blender Z=1.0.
    """
    bm = bmesh.new()

    mast_h = 1.0

    # Central spine column — slightly tapered (wider at base)
    add_cone_z(bm, (0, 0, mast_h * 0.5), 0.038, 0.028, mast_h, segments=12)

    # Four corner truss legs, angled inward as they rise (braced lattice look)
    for angle in (0, 90, 180, 270):
        rad = math.radians(angle + 22.5)
        base_r = 0.095
        top_r = 0.035
        bx0 = math.cos(rad) * base_r
        by0 = math.sin(rad) * base_r
        bx1 = math.cos(rad) * top_r
        by1 = math.sin(rad) * top_r
        add_tube_between(bm, (bx0, by0, 0.0), (bx1, by1, mast_h), radius=0.012, segments=8)

    # Diagonal cross-braces between legs (two X patterns at 1/3 and 2/3 height)
    for frac in (0.28, 0.62):
        zh = mast_h * frac
        for ia, ib in ((0, 2), (1, 3)):
            a0 = math.radians(ia * 90 + 22.5)
            a1 = math.radians(ib * 90 + 22.5)
            fr = 0.095 - (0.095 - 0.035) * frac   # interpolate radius at height
            p0 = (math.cos(a0) * fr, math.sin(a0) * fr, zh)
            p1 = (math.cos(a1) * fr, math.sin(a1) * fr, zh)
            add_tube_between(bm, p0, p1, radius=0.008, segments=6)

    # Three ring collars at 25%, 55%, 80% height
    for frac in (0.25, 0.55, 0.80):
        zh = mast_h * frac
        # Collar ring
        r_at = 0.095 - (0.095 - 0.035) * frac
        add_cyl_z(bm, (0, 0, zh), r_at + 0.015, 0.018, segments=12)

    # Equipment pod at 70% height: small junction box on one face
    pod_h = mast_h * 0.70
    r_pod = 0.095 - (0.095 - 0.035) * 0.70
    add_box(bm, (r_pod + 0.025, 0.0, pod_h), (0.04, 0.055, 0.04), bevel=0.005)
    # Tiny cable stub running to spine
    add_cyl_x(bm, (r_pod * 0.5, 0.0, pod_h), 0.008, r_pod * 0.8, segments=6)

    export_bmesh(bm, "sensor_suite_mast", "sensor_suite_mast.glb",
                 color=(0.22, 0.25, 0.28), metallic=0.68, roughness=0.40)


def build_sensor_suite_dish():
    """
    Rotating phased-array / parabolic dish head.
    Sits on a U-shaped elevation yoke so it can visually tilt.
    Origin at (0,0,0) = the mast-top rotation axis (Blender Z=0).
    auto_weapon.gd spins the MeshInstance3D named "sensor_suite_dish" around Y each frame.

    Geometry extends mostly in +Z (Blender) = Godot -Z (forward) so the dish face
    points 'outward' from the mast, and Y (Blender) / Godot_X is the horizontal pan axis.
    The dish bowl opening faces Blender +Y (Godot -Z / forward).
    """
    bm = bmesh.new()

    # --- Elevation yoke (U-frame that the dish rocks in) ---
    # Yoke base / rotation collar
    add_cyl_z(bm, (0, 0, 0.04), 0.065, 0.08, segments=14)
    # Left yoke arm
    add_box(bm, (-0.16, 0.0, 0.14), (0.025, 0.025, 0.16), bevel=0.005)
    # Right yoke arm
    add_box(bm, (0.16, 0.0, 0.14), (0.025, 0.025, 0.16), bevel=0.005)
    # Cross-piece joining tops of arms
    add_box(bm, (0.0, 0.0, 0.225), (0.345, 0.025, 0.025), bevel=0.004)
    # Pivot axle pins at each arm tip
    add_cyl_x(bm, (-0.16, 0.0, 0.225), 0.018, 0.04, segments=10)
    add_cyl_x(bm, (0.16, 0.0, 0.225), 0.018, 0.04, segments=10)

    # Servo drive on left arm (elevation actuator)
    add_box(bm, (-0.20, 0.0, 0.17), (0.045, 0.04, 0.052), bevel=0.005)
    add_cyl_y(bm, (-0.20, -0.04, 0.17), 0.010, 0.03, segments=6)   # cable gland

    # --- Dish back-plate / spine ---
    # Back centre rib
    add_box(bm, (0.0, -0.075, 0.225), (0.025, 0.10, 0.20), bevel=0.005)
    # Feed arm tube from centre
    add_cyl_y(bm, (0.0, 0.04, 0.225), 0.012, 0.22, segments=8)

    # --- Phased-array panel (rectangular grid face) ---
    # Main panel body
    add_box(bm, (0.0, 0.0, 0.225), (0.42, 0.015, 0.32), bevel=0.008)
    # Panel frame lip
    add_box(bm, (0.0, -0.016, 0.225), (0.45, 0.012, 0.35), bevel=0.006)
    # Radiating element rows (5×3 grid of small rectangular emitters)
    for col in range(5):
        for row in range(3):
            ex = (col - 2) * 0.074
            ez = (row - 1) * 0.088 + 0.225
            add_box(bm, (ex, 0.012, ez), (0.052, 0.012, 0.064), bevel=0.003)

    # --- Feed horn assembly at front centre ---
    # Main horn cylinder
    add_cyl_y(bm, (0.0, 0.115, 0.225), 0.026, 0.08, segments=14)
    # Horn cap / lens disc (represents the active receive element)
    add_cyl_y(bm, (0.0, 0.165, 0.225), 0.032, 0.012, segments=14)
    # Secondary LIDAR drum beside horn (art rule: camera/sensor, not eyepiece)
    add_cyl_z(bm, (0.07, 0.10, 0.235), 0.022, 0.042, segments=14)
    add_cyl_z(bm, (0.07, 0.10, 0.258), 0.024, 0.008, segments=14)  # lens cap ring

    export_bmesh(bm, "sensor_suite_dish", "sensor_suite_dish.glb",
                 color=(0.82, 0.85, 0.88), metallic=0.55, roughness=0.28)


# ---------------------------------------------------------------------------
# RESOURCE HARVESTER
# ---------------------------------------------------------------------------
# Three separate GLBs:
#   resource_harvester_mount.glb — heavy rotary turntable + upright pivot frame
#   resource_harvester_arm.glb   — articulated boom arm with hydraulic cylinder detail
#   resource_harvester_drill.glb — rotary auger/drill head (animated spin by visual_builder)
#
# visual_builder.gd assembles them:
#   mount at (0,0,0), arm at (0,0,0) scaled by ext_size on Z,
#   drill at (0, 0, -0.28*ext_size)

def build_resource_harvester_mount():
    """
    Heavy-duty turntable mount with upright bearing posts and hydraulic manifold.
    All geometry in raw Blender coords (no GV needed since this file's helpers are raw).
    """
    bm = bmesh.new()

    # Base turntable disc — thick, industrial
    add_cyl_z(bm, (0, 0, 0.05), 0.32, 0.10, segments=24)
    # Outer race ring
    add_cyl_z(bm, (0, 0, 0.11), 0.35, 0.018, segments=24)
    bolt_ring_z(bm, 0.115, 0.30, count=12, bolt_r=0.009, bolt_h=0.015)

    # Central slew bearing column
    add_cyl_z(bm, (0, 0, 0.12), 0.09, 0.06, segments=16)

    # Two upright bearing posts (left/right of arm)
    for sx in (-0.14, 0.14):
        add_box(bm, (sx, 0.0, 0.22), (0.055, 0.065, 0.24), bevel=0.008)
        # Pivot pin
        add_cyl_x(bm, (sx, 0.0, 0.345), 0.022, 0.075, segments=10)

    # Cross-beam connecting posts
    add_box(bm, (0.0, 0.0, 0.345), (0.30, 0.055, 0.04), bevel=0.006)

    # Hydraulic manifold block (art rule: servo/hydraulic hardware, not hand cranks)
    add_box(bm, (0.0, -0.18, 0.15), (0.08, 0.07, 0.08), bevel=0.008)
    # Hydraulic line ports (two small cylinder stubs)
    for px in (-0.025, 0.025):
        add_cyl_z(bm, (px, -0.22, 0.15), 0.010, 0.04, segments=8)

    # Two cable conduit runs from base to bearing posts
    for sx in (-0.14, 0.14):
        add_tube_between(bm, (sx * 0.6, -0.12, 0.10), (sx, -0.08, 0.30), radius=0.010, segments=6)

    export_bmesh(bm, "resource_harvester_mount", "resource_harvester_mount.glb",
                 color=(0.20, 0.22, 0.20), metallic=0.65, roughness=0.45)


def build_resource_harvester_arm():
    """
    Articulated extractor boom arm.
    Origin at the pivot pin (Blender Z=0.345 in mount space becomes the joint).
    The arm extends in Blender +Y (Godot -Z) direction.
    visual_builder scales Z (Godot Z / Blender Y) by ext_size tweak.
    """
    bm = bmesh.new()

    # Main structural box boom
    add_box(bm, (0, 0.28, 0.0), (0.10, 0.52, 0.08), bevel=0.010)
    # Underside flange stiffeners
    add_box(bm, (-0.03, 0.28, -0.052), (0.012, 0.48, 0.012), bevel=0.003)
    add_box(bm, (0.03, 0.28, -0.052), (0.012, 0.48, 0.012), bevel=0.003)

    # Elbow joint (mid-arm knuckle)
    add_cyl_x(bm, (0, 0.52, 0.0), 0.045, 0.12, segments=14)

    # Lower forearm box section
    add_box(bm, (0, 0.72, -0.015), (0.085, 0.36, 0.065), bevel=0.008)

    # Hydraulic cylinder (main lift ram)
    add_cyl_y(bm, (0, 0.18, 0.06), 0.022, 0.28, segments=12)   # outer cylinder
    add_cyl_y(bm, (0, 0.42, 0.06), 0.016, 0.20, segments=10)   # piston rod
    # Ram mount clevis at each end
    add_box(bm, (0, 0.06, 0.06), (0.04, 0.03, 0.035), bevel=0.004)
    add_box(bm, (0, 0.62, 0.06), (0.04, 0.03, 0.035), bevel=0.004)

    # Wrist joint at forearm tip
    add_cyl_x(bm, (0, 0.90, -0.015), 0.038, 0.11, segments=12)
    # Wrist servo actuator housing (art rule: remote operation)
    add_box(bm, (0.08, 0.90, -0.015), (0.04, 0.055, 0.04), bevel=0.005)

    # Cable runs along the boom top chord
    add_tube_between(bm, (0.0, 0.0, 0.045), (0.0, 0.88, 0.045), radius=0.008, segments=6)
    # Cable clamp clips every ~0.15 units
    for t in (0.15, 0.30, 0.45, 0.60, 0.75):
        add_box(bm, (0.0, t, 0.058), (0.024, 0.018, 0.012), bevel=0.002, bevel_segments=1)

    export_bmesh(bm, "resource_harvester_arm", "resource_harvester_arm.glb",
                 color=(0.72, 0.48, 0.12), metallic=0.60, roughness=0.42)


def build_resource_harvester_drill():
    """
    Heavy-duty Tricone Rotary Drill Head with Protective Cage Shroud.
    Origin at base attachment plate (Blender Z=0).
    Drill bores forward along Blender +Z (Godot +Y outward normal).
    """
    bm = bmesh.new()

    # 1. BASE MOUNTING COLLAR (Z = 0.0 to 0.08)
    add_cyl_z(bm, (0, 0, 0.04), radius=0.48, height=0.08, segments=24)
    add_cyl_z(bm, (0, 0, 0.07), radius=0.44, height=0.04, segments=24)
    bolt_ring_z(bm, 0.082, 0.44, count=12, bolt_r=0.012, bolt_h=0.016)

    # 2. ROTARY TRANSMISSION & DRIVE MOTOR HOUSING (Z = 0.08 to 0.35)
    add_cyl_z(bm, (0, 0, 0.20), radius=0.41, height=0.24, segments=24)
    add_cyl_z(bm, (0, 0, 0.33), radius=0.43, height=0.04, segments=24)
    bolt_ring_z(bm, 0.34, 0.40, count=12, bolt_r=0.009, bolt_h=0.012)

    # Dual hydraulic drive motor pods (left / right)
    for sx in (-0.38, 0.38):
        add_cyl_z(bm, (sx, 0.0, 0.20), radius=0.075, height=0.18, segments=14)
        add_box(bm, (sx * 0.90, 0.0, 0.20), (0.08, 0.12, 0.14), bevel=0.008)
        add_tube_between(bm, (sx, 0.0, 0.27), (sx * 0.65, 0.20, 0.12), radius=0.012, segments=6)
        add_tube_between(bm, (sx, 0.0, 0.13), (sx * 0.65, -0.20, 0.12), radius=0.012, segments=6)

    # Lubrication / grease manifold on top
    add_box(bm, (0.0, 0.36, 0.20), (0.16, 0.08, 0.12), bevel=0.008)
    for px in (-0.04, 0.04):
        add_cyl_y(bm, (px, 0.40, 0.20), radius=0.010, height=0.03, segments=8)

    # 3. TRICONE JOURNAL LUG ASSEMBLY (Z = 0.35 to 0.72)
    add_cone_z(bm, (0, 0, 0.48), r_bot=0.38, r_top=0.27, height=0.26, segments=24)

    for i in range(3):
        angle = i * (math.tau / 3.0)
        ca = math.cos(angle)
        sa = math.sin(angle)

        lug_base = mathutils.Vector((ca * 0.32, sa * 0.32, 0.42))
        lug_knuckle = mathutils.Vector((ca * 0.36, sa * 0.36, 0.62))
        cone_apex_target = mathutils.Vector((ca * 0.08, sa * 0.08, 0.98))

        add_box(bm, ((lug_base.x + lug_knuckle.x)*0.5, (lug_base.y + lug_knuckle.y)*0.5, 0.52),
                (0.12, 0.14, 0.24), bevel=0.010, rot_z=angle)
        add_tube_between(bm, lug_knuckle, cone_apex_target, radius=0.055, segments=12)

        for bz in (0.48, 0.56, 0.64):
            stud_pos = mathutils.Vector((ca * 0.40, sa * 0.40, bz))
            add_cyl_z(bm, stud_pos, radius=0.010, height=0.016, segments=6)

    # Slurry flush nozzles between lugs
    for i in range(3):
        angle = (i * 120.0 + 60.0) * (math.pi / 180.0)
        nx = math.cos(angle) * 0.16
        ny = math.sin(angle) * 0.16
        add_cone_z(bm, (nx, ny, 0.60), r_bot=0.024, r_top=0.014, height=0.10, segments=8)

    # 4. 3 CONICAL ROLLER CUTTERS (TRICONE CONES) (Z = 0.58 to 1.08)
    for i in range(3):
        angle = i * (math.tau / 3.0)
        ca = math.cos(angle)
        sa = math.sin(angle)

        p_base = mathutils.Vector((ca * 0.32, sa * 0.32, 0.62))
        p_tip = mathutils.Vector((ca * 0.06, sa * 0.06, 1.02))
        cone_axis = (p_tip - p_base).normalized()
        cone_len = (p_tip - p_base).length

        add_tube_between(bm, p_base, p_tip, radius=0.14, segments=16)

        # Heel row (8 carbide gauge teeth)
        r1_pos = p_base + cone_axis * (cone_len * 0.20)
        add_tube_between(bm, r1_pos - cone_axis * 0.03, r1_pos + cone_axis * 0.03, radius=0.165, segments=16)
        for t in range(8):
            ta = t * (math.tau / 8.0)
            up_v = mathutils.Vector((0, 0, 1))
            rad_u = cone_axis.cross(up_v).normalized()
            rad_v = cone_axis.cross(rad_u).normalized()
            t_offset = (rad_u * math.cos(ta) + rad_v * math.sin(ta)) * 0.165
            add_box(bm, r1_pos + t_offset, (0.022, 0.022, 0.035), bevel=0.004)

        # Middle row (6 chisel teeth)
        r2_pos = p_base + cone_axis * (cone_len * 0.55)
        add_tube_between(bm, r2_pos - cone_axis * 0.025, r2_pos + cone_axis * 0.025, radius=0.125, segments=14)
        for t in range(6):
            ta = (t + 0.5) * (math.tau / 6.0)
            rad_u = cone_axis.cross(mathutils.Vector((0, 0, 1))).normalized()
            rad_v = cone_axis.cross(rad_u).normalized()
            t_offset = (rad_u * math.cos(ta) + rad_v * math.sin(ta)) * 0.125
            add_box(bm, r2_pos + t_offset, (0.020, 0.020, 0.032), bevel=0.003)

        # Apex row (4 chisel teeth)
        r3_pos = p_base + cone_axis * (cone_len * 0.85)
        add_tube_between(bm, r3_pos - cone_axis * 0.02, r3_pos + cone_axis * 0.02, radius=0.080, segments=12)
        for t in range(4):
            ta = t * (math.tau / 4.0)
            rad_u = cone_axis.cross(mathutils.Vector((0, 0, 1))).normalized()
            rad_v = cone_axis.cross(rad_u).normalized()
            t_offset = (rad_u * math.cos(ta) + rad_v * math.sin(ta)) * 0.080
            add_box(bm, r3_pos + t_offset, (0.016, 0.016, 0.028), bevel=0.002)

    # Pilot tip
    add_cone_z(bm, (0, 0, 1.08), r_bot=0.045, r_top=0.008, height=0.06, segments=10)

    # 5. HEAVY DUTY PROTECTIVE CAGE SHROUD (Z = 0.05 to 0.82)
    for a_deg in (45, 135, 225, 315):
        a = math.radians(a_deg)
        gx = math.cos(a) * 0.46
        gy = math.sin(a) * 0.46
        add_box(bm, (gx, gy, 0.10), (0.08, 0.08, 0.12), bevel=0.006, rot_z=a)

    hoop_segs = 12
    for i in range(hoop_segs):
        t0 = (i / float(hoop_segs)) * math.pi
        t1 = ((i + 1) / float(hoop_segs)) * math.pi
        add_tube_between(bm, (math.cos(t0) * 0.54, math.sin(t0) * 0.54, 0.16),
                             (math.cos(t1) * 0.54, math.sin(t1) * 0.54, 0.16), radius=0.022, segments=8)
        add_tube_between(bm, (math.cos(t0) * 0.52, math.sin(t0) * 0.52, 0.46),
                             (math.cos(t1) * 0.52, math.sin(t1) * 0.52, 0.46), radius=0.020, segments=8)
        add_tube_between(bm, (math.cos(t0) * 0.47, math.sin(t0) * 0.47, 0.76),
                             (math.cos(t1) * 0.47, math.sin(t1) * 0.47, 0.76), radius=0.018, segments=8)

    for ang_deg in (15, 50, 90, 130, 165):
        a = math.radians(ang_deg)
        ca = math.cos(a)
        sa = math.sin(a)
        p_base = (ca * 0.48, sa * 0.48, 0.06)
        p_h1 = (ca * 0.54, sa * 0.54, 0.16)
        p_h2 = (ca * 0.52, sa * 0.52, 0.46)
        p_h3 = (ca * 0.47, sa * 0.47, 0.76)
        add_tube_between(bm, p_base, p_h1, radius=0.018, segments=8)
        add_tube_between(bm, p_h1, p_h2, radius=0.018, segments=8)
        add_tube_between(bm, p_h2, p_h3, radius=0.018, segments=8)

    cowl_segs = 6
    for i in range(cowl_segs):
        frac = i / float(cowl_segs)
        a = math.radians(35.0 + frac * 110.0)
        cowl_pos = (math.cos(a) * 0.52, math.sin(a) * 0.52, 0.44)
        add_box(bm, cowl_pos, (0.12, 0.024, 0.52), bevel=0.004, rot_z=a + math.pi*0.5)

    for ang_deg in (30, 70, 110, 150):
        a = math.radians(ang_deg)
        tx = math.cos(a) * 0.48
        ty = math.sin(a) * 0.48
        add_box(bm, (tx, ty, 0.81), (0.035, 0.050, 0.080), bevel=0.004, rot_z=a)

    for sx in (-0.38, 0.38):
        add_tube_between(bm, (sx, 0.0, 0.32), (sx * 1.35, 0.0, 0.46), radius=0.018, segments=6)

    export_bmesh(bm, "resource_harvester_drill", "resource_harvester_drill.glb",
                 color=(0.28, 0.30, 0.33, 1.0), metallic=0.82, roughness=0.32)


# ---------------------------------------------------------------------------
# ---------------------------------------------------------------------------
# REPAIR ARRAY  (Folded Industrial Factory Robot Arms Rework)
# ---------------------------------------------------------------------------
# Three separate GLBs:
#   repair_array_mount.glb   — octagonal pedestal with central power core & arm stations
#   repair_array_arm.glb     — articulated folded industrial robot arm (shoulder, high bicep, elbow, forearm, wrist)
#   repair_array_welder.glb  — industrial arc welding torch head, swan neck, seam-tracking optics, electrode tip
#
# visual_builder.gd spawns welder_count (1-4) arms in a radial ring at r=0.14,
# each arm.rotation.y = -angle, with welder head precisely attached to the wrist flange.

def build_repair_array_mount():
    """
    Heavy industrial deck turntable pedestal with central power core,
    rotary transformer hub, hydraulic manifold, and radial supply trunks.
    """
    bm = bmesh.new()

    # 1. Main octagonal cast deck base plate (Z = 0.0 to 0.06)
    add_cyl_z(bm, (0, 0, 0.03), 0.30, 0.06, segments=8)
    # Beveled step
    add_cyl_z(bm, (0, 0, 0.065), 0.26, 0.02, segments=8)
    # Perimeter mounting bolt circle
    bolt_ring_z(bm, 0.060, 0.275, count=8, bolt_r=0.007, bolt_h=0.012)

    # 2. Central rotary transformer & utility core (Z = 0.06 to 0.18)
    add_cyl_z(bm, (0, 0, 0.095), 0.10, 0.05, segments=16)
    # Core cooling louvers / ventilation collar
    add_cyl_z(bm, (0, 0, 0.125), 0.085, 0.02, segments=16)
    # Domed service cover with diagnostic port
    add_cone_z(bm, (0, 0, 0.145), 0.085, 0.045, 0.025, segments=16)
    add_cyl_z(bm, (0, 0, 0.165), 0.035, 0.018, segments=6)

    # 3. Turntable seat recesses and radial hydraulic/power conduits
    for i in range(4):
        a = i * (math.tau / 4.0)
        ca = math.cos(a)
        sa = math.sin(a)
        # Recessed circular turntable seat plate at r=0.14
        add_cyl_z(bm, (ca * 0.14, sa * 0.14, 0.076), 0.062, 0.012, segments=16)
        # Turntable retaining ring
        add_cyl_z(bm, (ca * 0.14, sa * 0.14, 0.083), 0.056, 0.005, segments=16)

        # Heavy high-voltage braided cable trunk from central core to arm seat
        add_tube_between(bm, (ca * 0.085, sa * 0.085, 0.09),
                         (ca * 0.13, sa * 0.13, 0.08), radius=0.010, segments=8)

        # Hydraulic manifold block between seats
        a_diag = a + (math.tau / 8.0)
        cda = math.cos(a_diag)
        sda = math.sin(a_diag)
        add_box(bm, (cda * 0.18, sda * 0.18, 0.075), (0.045, 0.045, 0.035), bevel=0.004)
        # Status LED indicator lens
        add_cyl_z(bm, (cda * 0.18, sda * 0.18, 0.095), 0.008, 0.006, segments=8)

    export_bmesh(bm, "repair_array_mount", "repair_array_mount.glb",
                 color=(0.18, 0.21, 0.26), metallic=0.75, roughness=0.32)


def build_repair_array_arm():
    """
    Folded Industrial Factory Robot Arm (KUKA/ABB 6-axis style).
    Stands upright with bicep rising steeply to high elbow, forearm folding downward.
    Origin at base (Z=0) — sits directly on the mount turntable seat.
    """
    bm = bmesh.new()

    # 1. BASE TURNTABLE & SHOULDER SWIVEL (Z = 0.0 to 0.12)
    # Turntable disc
    add_cyl_z(bm, (0, 0, 0.015), 0.052, 0.030, segments=16)
    bolt_ring_z(bm, 0.028, 0.042, count=6, bolt_r=0.004, bolt_h=0.006)

    # Shoulder upright yoke casting (dual vertical ears)
    add_box(bm, (-0.034, 0.0, 0.085), (0.016, 0.068, 0.085), bevel=0.004)
    add_box(bm, (0.034, 0.0, 0.085), (0.016, 0.068, 0.085), bevel=0.004)

    # Shoulder pivot hub (X-axis transverse)
    add_cyl_x(bm, (0, 0, 0.10), 0.028, 0.078, segments=14)
    # Shoulder servo drive canister (left side)
    add_cyl_x(bm, (-0.048, 0, 0.10), 0.034, 0.024, segments=14)
    # Servo cooling rings
    for c in range(3):
        add_tube_between(bm, (-0.042 - c * 0.007, 0, 0.10), (-0.044 - c * 0.007, 0, 0.10), radius=0.036, segments=12)

    # 2. LOWER ARM / BICEP BOOM (Rising UPWARDS from Z=0.10 to high elbow Z=0.52, Y=0.12)
    p_shoulder = mathutils.Vector((0, 0, 0.10))
    p_elbow = mathutils.Vector((0, 0.12, 0.52))

    # Main structural bicep casting
    add_tube_between(bm, p_shoulder, p_elbow, radius=0.028, segments=12)

    # Reinforcement side web plates along the bicep
    boom_dir = (p_elbow - p_shoulder).normalized()
    boom_len = (p_elbow - p_shoulder).length
    boom_mid = p_shoulder + boom_dir * (boom_len * 0.50)

    # Cast stiffener flanges on front and rear faces of bicep
    add_tube_between(bm, p_shoulder + mathutils.Vector((0, 0.016, 0.012)),
                     p_elbow + mathutils.Vector((0, 0.016, -0.012)), radius=0.012, segments=8)
    add_tube_between(bm, p_shoulder + mathutils.Vector((0, -0.016, -0.012)),
                     p_elbow + mathutils.Vector((0, -0.016, 0.012)), radius=0.012, segments=8)

    # Hydraulic Counterbalance Cylinder (parallel to lower boom on right side)
    cyl_base = mathutils.Vector((0.032, -0.030, 0.065))
    cyl_mid = mathutils.Vector((0.032, 0.035, 0.28))
    cyl_rod_end = mathutils.Vector((0.032, 0.090, 0.44))

    # Cylinder barrel (dark hydraulic body)
    add_tube_between(bm, cyl_base, cyl_mid, radius=0.014, segments=10)
    add_cyl_x(bm, cyl_base, 0.012, 0.018, segments=8)
    # Chrome extending rod
    add_tube_between(bm, cyl_mid, cyl_rod_end, radius=0.0075, segments=8)
    add_cyl_x(bm, cyl_rod_end, 0.010, 0.016, segments=8)

    # 3. HIGH ELBOW JOINT KNUCKLE (Z = 0.52, Y = 0.12)
    # Main elbow pivot cylinder
    add_cyl_x(bm, p_elbow, 0.032, 0.082, segments=16)
    # High-torque elbow servo motor (right side)
    add_cyl_x(bm, (0.048, 0.12, 0.52), 0.034, 0.024, segments=14)
    # Bearing end cap with center bolt
    add_cyl_x(bm, (-0.044, 0.12, 0.52), 0.026, 0.010, segments=12)

    # 4. FOREARM BOOM (Folding DOWNWARDS and reaching forward from Z=0.52, Y=0.12 to Z=0.28, Y=0.36)
    p_wrist = mathutils.Vector((0, 0.36, 0.28))

    # Main forearm structural beam
    add_tube_between(bm, p_elbow, p_wrist, radius=0.022, segments=12)
    # Forearm top spine rib
    add_tube_between(bm, p_elbow + mathutils.Vector((0, 0.012, 0.012)),
                     p_wrist + mathutils.Vector((0, 0.012, 0.012)), radius=0.009, segments=8)

    # 5. WRIST 3-AXIS GIMBAL & TOOL FLANGE (Z = 0.28, Y = 0.36)
    # Pitch axis knuckle
    add_cyl_x(bm, p_wrist, 0.022, 0.054, segments=12)
    # Tool mounting collar extending to flange
    p_flange = mathutils.Vector((0, 0.39, 0.26))
    add_tube_between(bm, p_wrist, p_flange, radius=0.020, segments=10)
    # Circular tool mounting flange
    add_tube_between(bm, p_flange - mathutils.Vector((0, 0.006, -0.004)),
                     p_flange + mathutils.Vector((0, 0.006, -0.004)), radius=0.028, segments=14)

    # 6. FLEXIBLE CONDUIT / CABLE DRESS PACK (Looping over shoulder, bicep, and elbow)
    add_tube_between(bm, (0.024, -0.02, 0.04), (0.026, -0.01, 0.12), radius=0.008, segments=6)
    add_tube_between(bm, (0.026, -0.01, 0.12), (0.024, 0.05, 0.32), radius=0.008, segments=6)
    # Loop over high elbow
    add_tube_between(bm, (0.024, 0.05, 0.32), (0.026, 0.10, 0.54), radius=0.008, segments=6)
    add_tube_between(bm, (0.026, 0.10, 0.54), (0.024, 0.22, 0.44), radius=0.008, segments=6)
    add_tube_between(bm, (0.024, 0.22, 0.44), (0.022, 0.34, 0.30), radius=0.008, segments=6)

    export_bmesh(bm, "repair_array_arm", "repair_array_arm.glb",
                 color=(0.24, 0.27, 0.32), metallic=0.72, roughness=0.35)


def build_repair_array_welder():
    """
    Industrial Arc Welding End Effector & Laser Seam Tracker.
    Mounts directly onto the robot arm wrist tool flange at (0, 0.39, 0.26).
    """
    bm = bmesh.new()

    p_flange = mathutils.Vector((0, 0.39, 0.26))

    # 1. Tool Base Adapter & Quick-Change Collar (attaches to wrist flange)
    add_tube_between(bm, p_flange, p_flange + mathutils.Vector((0, 0.025, -0.016)), radius=0.026, segments=12)

    p_torch_body = p_flange + mathutils.Vector((0, 0.035, -0.022))
    # Insulated torch main body block
    add_box(bm, p_torch_body, (0.048, 0.055, 0.045), bevel=0.005)

    # Wire-feed servo motor housing on torch body top
    add_cyl_y(bm, p_torch_body + mathutils.Vector((0, 0.0, 0.032)), 0.016, 0.040, segments=12)

    # 2. Optical Seam Tracker & Dual-Lens Camera Pod (mounted on top of torch)
    p_cam = p_torch_body + mathutils.Vector((0, 0.020, 0.052))
    add_box(bm, p_cam, (0.042, 0.036, 0.028), bevel=0.003)
    # Stereo camera lenses aiming toward the weld arc
    add_cyl_y(bm, p_cam + mathutils.Vector((-0.012, 0.020, 0.0)), 0.007, 0.008, segments=10)
    add_cyl_y(bm, p_cam + mathutils.Vector((0.012, 0.020, 0.0)), 0.007, 0.008, segments=10)
    # Sunshade hood
    add_box(bm, p_cam + mathutils.Vector((0, 0.018, 0.016)), (0.044, 0.016, 0.005), bevel=0.001)

    # 3. Industrial Swan-Neck Welding Torch Nozzle
    p_neck_start = p_torch_body + mathutils.Vector((0, 0.025, -0.015))
    p_neck_bend = p_torch_body + mathutils.Vector((0, 0.065, -0.065))
    p_nozzle_base = p_torch_body + mathutils.Vector((0, 0.085, -0.125))

    # Curved swan-neck copper conduit
    add_tube_between(bm, p_neck_start, p_neck_bend, radius=0.012, segments=10)
    add_tube_between(bm, p_neck_bend, p_nozzle_base, radius=0.011, segments=10)

    # Heavy-duty conical gas nozzle cup
    p_nozzle_tip = p_nozzle_base + mathutils.Vector((0, 0.015, -0.045))
    nozzle_axis = (p_nozzle_tip - p_nozzle_base).normalized()
    add_tube_between(bm, p_nozzle_base, p_nozzle_tip, radius=0.016, segments=14)

    # Cooling shroud fins on nozzle base
    for f in range(3):
        f_pos = p_nozzle_base + nozzle_axis * (0.010 * f)
        add_tube_between(bm, f_pos - nozzle_axis * 0.002, f_pos + nozzle_axis * 0.002, radius=0.019, segments=12)

    # Ceramic insulator ring
    add_tube_between(bm, p_nozzle_tip - nozzle_axis * 0.005, p_nozzle_tip, radius=0.012, segments=10)

    # Tungsten arc electrode / welding wire tip protruding from nozzle center
    p_electrode_tip = p_nozzle_tip + nozzle_axis * 0.025
    add_cone_z(bm, p_electrode_tip, r_bot=0.005, r_top=0.001, height=0.025, segments=8)

    export_bmesh(bm, "repair_array_welder", "repair_array_welder.glb",
                 color=(0.18, 0.22, 0.26), metallic=0.80, roughness=0.25)


# ---------------------------------------------------------------------------
# DRONE CARRIER  (geometry unchanged from original, just preserved here)
# ---------------------------------------------------------------------------

def build_drone_carrier_parts():
    clear_scene()
    bm1 = bmesh.new()
    add_box(bm1, (0, 0, 0.03), (0.50, 0.80, 0.06), bevel=0.015)
    add_box(bm1, (-0.12, 0.0, 0.07), (0.04, 0.76, 0.03), bevel=0.005)
    add_box(bm1, (0.12, 0.0, 0.07), (0.04, 0.76, 0.03), bevel=0.005)
    export_bmesh(bm1, "drone_carrier_mount", "drone_carrier_mount.glb",
                 color=(0.20, 0.22, 0.26))

    bm2 = bmesh.new()
    add_box(bm2, (0, 0.15, 0.16), (0.46, 0.44, 0.22), bevel=0.02)
    add_box(bm2, (0, -0.06, 0.16), (0.42, 0.04, 0.18), bevel=0.01)
    export_bmesh(bm2, "drone_carrier_housing", "drone_carrier_housing.glb",
                 color=(0.28, 0.30, 0.34))

    bm3 = bmesh.new()
    add_box(bm3, (0, 0, 0), (0.06, 0.18, 0.04), bevel=0.008)
    add_box(bm3, (0, 0, 0.01), (0.24, 0.05, 0.015), bevel=0.003)
    add_box(bm3, (0, 0.08, 0.02), (0.02, 0.04, 0.03), bevel=0.002)
    export_bmesh(bm3, "drone_carrier_drone", "drone_carrier_drone.glb",
                 color=(0.85, 0.85, 0.88))


# ---------------------------------------------------------------------------
# LASER DESIGNATOR  (Target Painter)
# ---------------------------------------------------------------------------
# Two GLBs:
#   laser_designator_mount.glb — static deck pedestal with servo drive
#   laser_designator_head.glb  — pivoting optical gimbal head with lens & laser tube

def build_laser_designator_mount():
    bm = bmesh.new()
    # Main octagonal pedestal base
    add_cyl_z(bm, (0, 0, 0.04), 0.22, 0.08, segments=8)
    add_cone_z(bm, (0, 0, 0.10), 0.15, 0.11, 0.04, segments=12)
    # Azimuth servo housing yoke
    for sx in (-0.08, 0.08):
        add_box(bm, (sx, 0.0, 0.18), (0.04, 0.14, 0.12), bevel=0.008)
    bolt_ring_z(bm, 0.08, 0.17, count=6)
    export_bmesh(bm, "laser_designator_mount", "laser_designator_mount.glb",
                 color=(0.20, 0.22, 0.26), metallic=0.75, roughness=0.30)


def build_laser_designator_head():
    bm = bmesh.new()
    # Central optical camera housing
    add_box(bm, (0, 0.0, 0.0), (0.16, 0.22, 0.14), bevel=0.01)
    # Main optical camera lens disc on front (+Z in Godot, +Y in Blender)
    add_cyl_y(bm, (0.0, 0.12, 0.02), 0.055, 0.03, segments=20)
    # Secondary laser painter emitter barrel (coaxial under main lens)
    add_cyl_y(bm, (0.04, 0.13, -0.03), 0.025, 0.05, segments=16)
    # Cooling fins on rear (-Y in Blender)
    for iz in range(4):
        zh = -0.04 + iz * 0.025
        add_box(bm, (0.0, -0.10, zh), (0.14, 0.02, 0.01), bevel=0.002)
    export_bmesh(bm, "laser_designator_head", "laser_designator_head.glb",
                 color=(0.25, 0.28, 0.32), metallic=0.60, roughness=0.35)


# ---------------------------------------------------------------------------
# ENERGY BARRIER PROJECTOR  (Directional Forcefield Shield)
# ---------------------------------------------------------------------------
# Three GLBs:
#   energy_barrier_projector_mount.glb  — high-voltage junction base
#   energy_barrier_projector_array.glb  — 4 curved field-focusing tines & capacitor
#   energy_barrier_projector_shield.glb — translucent parabolic forcefield arc mesh

def build_energy_barrier_projector_mount():
    bm = bmesh.new()
    add_cyl_z(bm, (0, 0, 0.04), 0.28, 0.08, segments=8)
    add_box(bm, (0, 0, 0.12), (0.32, 0.32, 0.08), bevel=0.015)
    # High-voltage cable conduit trunks
    for sx in (-0.12, 0.12):
        add_cyl_z(bm, (sx, 0.10, 0.18), 0.03, 0.06, segments=10)
    bolt_ring_z(bm, 0.08, 0.22, count=8)
    export_bmesh(bm, "energy_barrier_projector_mount", "energy_barrier_projector_mount.glb",
                 color=(0.18, 0.20, 0.24), metallic=0.80, roughness=0.25)


def build_energy_barrier_projector_array():
    bm = bmesh.new()
    # Central capacitor core cylinder
    add_cyl_z(bm, (0, 0, 0.14), 0.10, 0.16, segments=16)
    # 4 curved projector focusing tines
    for i in range(4):
        ang = i * (math.pi / 2.0)
        tx = math.cos(ang) * 0.16
        ty = math.sin(ang) * 0.16
        add_box(bm, (tx, ty, 0.22), (0.03, 0.05, 0.20), bevel=0.008, rot_z=ang)
        add_cone_z(bm, (tx * 1.15, ty * 1.15, 0.33), 0.02, 0.005, 0.06, segments=8)
    export_bmesh(bm, "energy_barrier_projector_array", "energy_barrier_projector_array.glb",
                 color=(0.15, 0.65, 0.85), metallic=0.40, roughness=0.20)


def build_energy_barrier_projector_shield():
    bm = bmesh.new()
    # Glowing translucent parabolic shield barrier arc
    add_cone_z(bm, (0, 0.50, 0.20), 1.20, 0.90, 0.10, segments=24)
    export_bmesh(bm, "energy_barrier_projector_shield", "energy_barrier_projector_shield.glb",
                 color=(0.20, 0.85, 1.0), metallic=0.10, roughness=0.10)


# ---------------------------------------------------------------------------
# FIRE CONTROL RADAR  (Long-Range Target Finder)
# ---------------------------------------------------------------------------
# Three GLBs:
#   fire_control_radar_mount.glb — octagonal base pedestal with slip-ring motor
#   fire_control_radar_mast.glb  — structural lattice mast column with waveguides
#   fire_control_radar_dish.glb  — rotating planar array radar panel + feed horn

def build_fire_control_radar_mount():
    bm = bmesh.new()
    add_cyl_z(bm, (0, 0, 0.04), 0.24, 0.08, segments=8)
    add_cyl_z(bm, (0, 0, 0.10), 0.16, 0.04, segments=16)
    bolt_ring_z(bm, 0.08, 0.19, count=8)
    export_bmesh(bm, "fire_control_radar_mount", "fire_control_radar_mount.glb",
                 color=(0.18, 0.20, 0.24), metallic=0.75, roughness=0.35)


def build_fire_control_radar_mast():
    bm = bmesh.new()
    mast_h = 0.80
    add_cone_z(bm, (0, 0, mast_h * 0.5), 0.04, 0.03, mast_h, segments=12)
    for angle in (0, 90, 180, 270):
        rad = math.radians(angle)
        tx = math.cos(rad) * 0.07
        ty = math.sin(rad) * 0.07
        add_cyl_z(bm, (tx, ty, mast_h * 0.5), 0.012, mast_h, segments=8)
    for iz in range(2):
        zh = (iz + 1) * (mast_h / 3.0)
        add_cyl_z(bm, (0, 0, zh), 0.08, 0.02, segments=12)
    export_bmesh(bm, "fire_control_radar_mast", "fire_control_radar_mast.glb",
                 color=(0.25, 0.28, 0.32), metallic=0.65, roughness=0.35)


def build_fire_control_radar_dish():
    bm = bmesh.new()
    # Planar array radar panel (rectangular array face)
    add_box(bm, (0, 0.06, 0.0), (0.42, 0.04, 0.28), bevel=0.01)
    # Array face grid segments
    add_box(bm, (0, 0.085, 0.0), (0.38, 0.01, 0.24), bevel=0.002)
    # Feed horn receiver probe on front
    add_cyl_y(bm, (0, 0.18, 0.0), 0.015, 0.15, segments=10)
    add_cone_z(bm, (0, 0.26, 0.0), 0.03, 0.01, 0.04, segments=12)
    export_bmesh(bm, "fire_control_radar_dish", "fire_control_radar_dish.glb",
                 color=(0.80, 0.82, 0.85), metallic=0.50, roughness=0.40)


# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------

def build_utility_parts():
    print("=== Building Sensor Suite (Radar Mast) ===")
    clear_scene()
    build_sensor_suite_mount()
    clear_scene()
    build_sensor_suite_mast()
    clear_scene()
    build_sensor_suite_dish()

    print("=== Building Resource Harvester ===")
    clear_scene()
    build_resource_harvester_mount()
    clear_scene()
    build_resource_harvester_arm()
    clear_scene()
    build_resource_harvester_drill()

    print("=== Building Repair Array ===")
    clear_scene()
    build_repair_array_mount()
    clear_scene()
    build_repair_array_arm()
    clear_scene()
    build_repair_array_welder()

    print("=== Building Drone Carrier (unchanged) ===")
    build_drone_carrier_parts()

    print("=== Building Laser Designator ===")
    clear_scene()
    build_laser_designator_mount()
    clear_scene()
    build_laser_designator_head()

    print("=== Building Energy Barrier Projector ===")
    clear_scene()
    build_energy_barrier_projector_mount()
    clear_scene()
    build_energy_barrier_projector_array()
    clear_scene()
    build_energy_barrier_projector_shield()

    print("=== Building Fire Control Radar ===")
    clear_scene()
    build_fire_control_radar_mount()
    clear_scene()
    build_fire_control_radar_mast()
    clear_scene()
    build_fire_control_radar_dish()

    print("=== All utility modules exported successfully ===")


if __name__ == "__main__":
    build_utility_parts()

