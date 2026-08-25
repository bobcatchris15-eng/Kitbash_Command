"""
Kitbash Command - Sensor Suite Module Mesh Builder
Authors refined multi-part GLB meshes for simplified sensor suites:
  - Rugged electronics housing (sensor_housing_rugged.glb)
  - Multispectrum Radome (sensor_radome_multispectrum.glb)
  - Parabolic Radar Dish (sensor_dish_parabolic.glb / sensor_suite_dish.glb)
  - Phased Array Sector Radar (sensor_phased_array.glb / directional_radar_dish.glb)
  - Coiled Whip Antenna (antenna_whip_coiled.glb)
  - Heavy Sensor Pylon (sensor_pylon_heavy.glb)
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


def clear_scene():
    bpy.ops.object.select_all(action='SELECT')
    bpy.ops.object.delete(use_global=False)
    for block in list(bpy.data.meshes):
        if block.users == 0:
            bpy.data.meshes.remove(block)
    for block in list(bpy.data.materials):
        if block.users == 0:
            bpy.data.materials.remove(block)


# Primitive helpers (Blender Z-up -> exported Y-up)
def add_cyl_z(bm, pos, radius, height, segments=16):
    res = bmesh.ops.create_cone(bm, cap_ends=True, cap_tris=False, segments=segments,
                                radius1=radius, radius2=radius, depth=height)
    loc = mathutils.Vector(pos)
    for v in res['verts']:
        v.co = v.co + loc


def add_cone_z(bm, pos, r_bot, r_top, height, segments=16):
    res = bmesh.ops.create_cone(bm, cap_ends=True, cap_tris=False, segments=segments,
                                radius1=r_top, radius2=r_bot, depth=height)
    loc = mathutils.Vector(pos)
    for v in res['verts']:
        v.co = v.co + loc


def add_cyl_y(bm, pos, radius, height, segments=16):
    rot = mathutils.Matrix.Rotation(math.radians(90), 4, 'X')
    res = bmesh.ops.create_cone(bm, cap_ends=True, cap_tris=False, segments=segments,
                                radius1=radius, radius2=radius, depth=height)
    loc = mathutils.Vector(pos)
    for v in res['verts']:
        v.co = (rot @ v.co) + loc


def add_cyl_x(bm, pos, radius, height, segments=16):
    rot = mathutils.Matrix.Rotation(math.radians(90), 4, 'Y')
    res = bmesh.ops.create_cone(bm, cap_ends=True, cap_tris=False, segments=segments,
                                radius1=radius, radius2=radius, depth=height)
    loc = mathutils.Vector(pos)
    for v in res['verts']:
        v.co = (rot @ v.co) + loc


def add_box(bm, pos, size, bevel=0.0, bevel_segments=2, rot_z=0.0):
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
    for i in range(count):
        a = (i / count) * math.tau
        add_cyl_z(bm, (math.cos(a) * radius, math.sin(a) * radius, z), bolt_r, bolt_h, segments=6)


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


# ===========================================================================
# 1. RUGGED ELECTRONICS HOUSING / PEDESTAL
# ===========================================================================
def build_rugged_sensor_housing():
    """
    Rugged cast-alloy avionics and electronics enclosure.
    Features:
      - Chamfered baseplate with perimeter mounting bolts
      - Raised gasket-sealed electronics bay
      - Lateral cooling heatsink fin banks (left & right)
      - Front military connector glands and armored cable conduit trunks
      - Central mast socket ring with reinforce gussets
    """
    bm = bmesh.new()

    # Base deck plate (chamfered slab)
    add_box(bm, (0.0, 0.0, 0.025), (0.52, 0.44, 0.05), bevel=0.008)

    # Perimeter mounting bolts
    for bx in (-0.23, 0.0, 0.23):
        for by in (-0.19, 0.19):
            add_cyl_z(bm, (bx, by, 0.055), 0.008, 0.012, segments=6)

    # Main sealed electronics enclosure
    add_box(bm, (0.0, 0.0, 0.09), (0.42, 0.34, 0.08), bevel=0.006)

    # Top access lid with gasket rim
    add_box(bm, (0.0, 0.0, 0.135), (0.36, 0.28, 0.015), bevel=0.003)

    # Left heatsink cooling fins
    for i in range(6):
        fy = -0.12 + i * 0.048
        add_box(bm, (-0.22, fy, 0.09), (0.02, 0.01, 0.06), bevel=0.001)

    # Right heatsink cooling fins
    for i in range(6):
        fy = -0.12 + i * 0.048
        add_box(bm, (0.22, fy, 0.09), (0.02, 0.01, 0.06), bevel=0.001)

    # Front military connector glands (Blender +Y / Godot -Z)
    for gx in (-0.10, 0.0, 0.10):
        add_cyl_y(bm, (gx, 0.18, 0.085), 0.014, 0.03, segments=8)
        # Conduit nut
        add_cyl_y(bm, (gx, 0.17, 0.085), 0.018, 0.01, segments=6)

    # Rear power bus junction box (Blender -Y / Godot +Z)
    add_box(bm, (0.0, -0.18, 0.085), (0.16, 0.04, 0.06), bevel=0.004)
    add_cyl_x(bm, (0.09, -0.18, 0.085), 0.012, 0.02, segments=8)

    # Central mast socket ring atop housing
    add_cone_z(bm, (0.0, 0.0, 0.16), 0.14, 0.11, 0.04, segments=16)
    add_cyl_z(bm, (0.0, 0.0, 0.19), 0.07, 0.04, segments=16)
    bolt_ring_z(bm, 0.175, 0.125, count=8, bolt_r=0.006, bolt_h=0.01)

    export_bmesh(bm, "sensor_housing_rugged", "sensor_housing_rugged.glb",
                 color=(0.20, 0.22, 0.25), metallic=0.75, roughness=0.35)


# ===========================================================================
# 2. MULTISPECTRUM RADOME (Tier 2 Advanced Array Head)
# ===========================================================================
def build_multispectrum_radome():
    """
    Multispectrum Radome head assembly.
    Features:
      - Dielectric composite aerodynamic radome bubble
      - Forward EO/IR thermal imaging window
      - Integrated LIDAR transceiver rotating drum
      - Laser rangefinder aperture lens
      - Rear telemetry heat dissipation shroud
    """
    bm = bmesh.new()

    # Base rotating yoke/collar
    add_cyl_z(bm, (0.0, 0.0, 0.04), 0.15, 0.08, segments=16)
    bolt_ring_z(bm, 0.075, 0.13, count=8, bolt_r=0.006, bolt_h=0.01)

    # Structural collar pedestal
    add_cone_z(bm, (0.0, 0.0, 0.11), 0.15, 0.22, 0.06, segments=20)

    # Main composite Radome sphere/ellipsoid (dielectric bubble)
    res = bmesh.ops.create_icosphere(bm, subdivisions=3, radius=0.24)
    loc = mathutils.Vector((0.0, 0.0, 0.28))
    for v in res['verts']:
        v.co = mathutils.Vector((v.co.x * 1.0, v.co.y * 1.15, v.co.z * 1.05)) + loc

    # Forward EO/IR Thermal Camera Aperture Shroud (Blender +Y / Godot -Z)
    add_box(bm, (0.0, 0.26, 0.27), (0.16, 0.06, 0.12), bevel=0.006)
    # Germanium IR Window Disc
    add_cyl_y(bm, (-0.04, 0.295, 0.27), 0.035, 0.012, segments=16)
    # Day/Night Optical Sight Lens
    add_cyl_y(bm, (0.04, 0.295, 0.27), 0.025, 0.012, segments=16)

    # Top LIDAR Transceiver Scanner Turret
    add_cyl_z(bm, (0.0, 0.06, 0.54), 0.075, 0.07, segments=16)
    # 360-degree glass scanner slit band
    add_cyl_z(bm, (0.0, 0.06, 0.54), 0.082, 0.025, segments=16)
    # LIDAR cap with bolt ring
    add_cone_z(bm, (0.0, 0.06, 0.585), 0.075, 0.06, 0.02, segments=16)

    # Port side Laser Rangefinder pod
    add_cyl_y(bm, (-0.23, 0.08, 0.28), 0.032, 0.14, segments=12)
    add_cyl_y(bm, (-0.23, 0.155, 0.28), 0.025, 0.01, segments=12)

    # Starboard side RF horn antenna
    add_cone_z(bm, (0.23, 0.08, 0.32), 0.025, 0.045, 0.08, segments=10)

    # Rear heat dissipation exhaust shroud (Blender -Y)
    add_box(bm, (0.0, -0.25, 0.28), (0.18, 0.08, 0.14), bevel=0.008)
    for i in range(4):
        lz = 0.23 + i * 0.03
        add_box(bm, (0.0, -0.295, lz), (0.14, 0.01, 0.015), bevel=0.001)

    export_bmesh(bm, "sensor_radome_multispectrum", "sensor_radome_multispectrum.glb",
                 color=(0.88, 0.90, 0.92), metallic=0.35, roughness=0.25)


# ===========================================================================
# 3. HEAVY SENSOR PYLON MAST (Tier 2 Pylon Column)
# ===========================================================================
def build_heavy_sensor_pylon():
    """
    Heavy reinforced sensor pylon mast column.
    Blender Z height = 1.0 unit (scaled by pylon_height tweak in visual_builder).
    """
    bm = bmesh.new()
    pylon_h = 1.0

    # Central tubular structural pylon with aerodynamic taper
    add_cone_z(bm, (0, 0, pylon_h * 0.5), 0.09, 0.06, pylon_h, segments=16)

    # Four external stiffener ribs spanning full height
    for angle in (45, 135, 225, 315):
        rad = math.radians(angle)
        for frac in (0.2, 0.45, 0.7, 0.9):
            zh = pylon_h * frac
            r_at = 0.09 - (0.09 - 0.06) * frac
            rx = math.cos(rad) * (r_at + 0.025)
            ry = math.sin(rad) * (r_at + 0.025)
            add_box(bm, (rx, ry, zh), (0.02, 0.02, 0.08), bevel=0.003, rot_z=rad)

    # Mid-height avionics junction collar (at 50% height)
    add_cyl_z(bm, (0, 0, pylon_h * 0.5), 0.115, 0.06, segments=16)
    bolt_ring_z(bm, pylon_h * 0.5 + 0.025, 0.105, count=8, bolt_r=0.005, bolt_h=0.01)

    # External RF waveguide conduit running up the spine
    add_box(bm, (0.0, -0.085, pylon_h * 0.5), (0.025, 0.02, pylon_h * 0.95), bevel=0.002)

    # Top flange mounting plate
    add_cyl_z(bm, (0, 0, pylon_h - 0.02), 0.10, 0.04, segments=16)
    bolt_ring_z(bm, pylon_h - 0.01, 0.085, count=8, bolt_r=0.005, bolt_h=0.01)

    export_bmesh(bm, "sensor_pylon_heavy", "sensor_pylon_heavy.glb",
                 color=(0.25, 0.28, 0.32), metallic=0.70, roughness=0.38)


# ===========================================================================
# 4. PARABOLIC RADAR DISH (Tier 1 Refined Dish)
# ===========================================================================
def build_parabolic_radar_dish():
    """
    Precision high-grain parabolic radar dish.
    Sits on an elevation pivot yoke at origin (0,0,0).
    Rotates continuously around Y in Godot.
    """
    bm = bmesh.new()

    # Elevation Yoke Base
    add_cyl_z(bm, (0, 0, 0.04), 0.065, 0.08, segments=14)
    add_box(bm, (-0.16, 0.0, 0.14), (0.025, 0.025, 0.16), bevel=0.005)
    add_box(bm, (0.16, 0.0, 0.14), (0.025, 0.025, 0.16), bevel=0.005)
    add_cyl_x(bm, (-0.16, 0.0, 0.22), 0.018, 0.04, segments=10)
    add_cyl_x(bm, (0.16, 0.0, 0.22), 0.018, 0.04, segments=10)

    # Dish back hub and elevation pivot
    add_cyl_x(bm, (0.0, 0.0, 0.22), 0.035, 0.28, segments=12)
    add_box(bm, (0.0, -0.06, 0.22), (0.05, 0.08, 0.06), bevel=0.004)

    # Parabolic Dish Bowl (faces Blender +Y / Godot -Z)
    dish_radius = 0.32
    dish_depth = 0.09
    add_cone_z(bm, (0.0, 0.0, 0.22), 0.06, dish_radius, dish_depth, segments=24)
    add_cyl_z(bm, (0.0, 0.0, 0.22 + dish_depth * 0.5), dish_radius + 0.012, 0.012, segments=24)

    # Central feed horn tripod struts
    tripod_tip = (0.0, 0.20, 0.22)
    for i in range(3):
        a = (i / 3.0) * math.tau + math.radians(30)
        base_pt = (math.cos(a) * (dish_radius * 0.85),
                   math.sin(a) * (dish_radius * 0.85),
                   0.22 + dish_depth * 0.4)
        add_tube_between(bm, base_pt, tripod_tip, radius=0.006, segments=6)

    # Central feed horn collector at tripod tip
    add_cyl_y(bm, tripod_tip, 0.022, 0.06, segments=12)
    add_cyl_y(bm, (tripod_tip[0], tripod_tip[1] + 0.035, tripod_tip[2]), 0.028, 0.01, segments=12)

    export_bmesh(bm, "sensor_dish_parabolic", "sensor_dish_parabolic.glb",
                 color=(0.85, 0.88, 0.90), metallic=0.60, roughness=0.30)


# ===========================================================================
# 5. PHASED ARRAY SECTOR DISH (Tier 3 Directional Array)
# ===========================================================================
def build_phased_array_sector():
    """
    Directional phased-array sector radar antenna.
    Features:
      - Heavy rectangular active phased array face
      - Rear cooling radiator fin array
      - 6x4 Grid of T/R (Transmit/Receive) Module Emitter Patches
      - Heavy steerable elevation/azimuth yoke
    """
    bm = bmesh.new()

    # Heavy azimuth rotation base
    add_cyl_z(bm, (0, 0, 0.05), 0.09, 0.10, segments=16)
    bolt_ring_z(bm, 0.08, 0.08, count=8, bolt_r=0.006, bolt_h=0.01)

    # Heavy dual-pillar elevation yoke
    add_box(bm, (-0.22, 0.0, 0.18), (0.04, 0.05, 0.20), bevel=0.006)
    add_box(bm, (0.22, 0.0, 0.18), (0.04, 0.05, 0.20), bevel=0.006)
    add_cyl_x(bm, (-0.22, 0.0, 0.26), 0.025, 0.05, segments=12)
    add_cyl_x(bm, (0.22, 0.0, 0.26), 0.025, 0.05, segments=12)

    # Phased Array Back Frame & Spine
    add_box(bm, (0.0, 0.0, 0.26), (0.42, 0.04, 0.18), bevel=0.006)
    add_box(bm, (0.0, -0.06, 0.26), (0.34, 0.08, 0.22), bevel=0.008)

    # Rear cooling radiator fins
    for i in range(8):
        fx = -0.14 + i * 0.04
        add_box(bm, (fx, -0.105, 0.26), (0.015, 0.04, 0.20), bevel=0.001)

    # Main Phased Array Planar Face (Blender +Y / Godot -Z)
    add_box(bm, (0.0, 0.03, 0.26), (0.54, 0.02, 0.36), bevel=0.008)
    add_box(bm, (0.0, 0.045, 0.26), (0.51, 0.01, 0.33), bevel=0.004)

    # 6x4 Grid of T/R (Transmit/Receive) Module Emitter Patches
    for col in range(6):
        for row in range(4):
            ex = (col - 2.5) * 0.078
            ez = (row - 1.5) * 0.074 + 0.26
            add_box(bm, (ex, 0.055, ez), (0.056, 0.01, 0.054), bevel=0.002)

    # Calibration horn / receiver probe on top rim
    add_cyl_z(bm, (0.0, 0.04, 0.46), 0.012, 0.06, segments=8)
    add_cone_z(bm, (0.0, 0.04, 0.50), 0.012, 0.024, 0.03, segments=8)

    export_bmesh(bm, "sensor_phased_array", "sensor_phased_array.glb",
                 color=(0.35, 0.55, 0.85), metallic=0.70, roughness=0.30)


# ===========================================================================
# 6. COILED WHIP ANTENNA
# ===========================================================================
def build_coiled_whip_antenna():
    """
    Rugged whip antenna with helical base loading coil and flexible whip.
    Origin at base mounting stud (0,0,0).
    """
    bm = bmesh.new()

    # Hex mounting base stud
    add_cyl_z(bm, (0, 0, 0.015), 0.025, 0.03, segments=6)
    # Ceramic/Polymer isolator collar
    add_cyl_z(bm, (0, 0, 0.04), 0.020, 0.02, segments=12)

    # Helical base loading coil housing (ribbed spring cylinder)
    add_cyl_z(bm, (0, 0, 0.10), 0.022, 0.10, segments=12)
    # 5 loading coil rings
    for i in range(5):
        cz = 0.06 + i * 0.02
        add_cyl_z(bm, (0, 0, cz), 0.026, 0.008, segments=12)

    # Upper spring damper collar
    add_cone_z(bm, (0, 0, 0.16), 0.020, 0.010, 0.02, segments=10)

    # Tapered flexible spring-steel whip (Z=0.17 to Z=0.72)
    add_cone_z(bm, (0, 0, 0.445), 0.008, 0.003, 0.55, segments=8)

    # Top RF corona ball / static discharge tip
    add_cyl_z(bm, (0, 0, 0.725), 0.009, 0.012, segments=8)

    export_bmesh(bm, "antenna_whip_coiled", "antenna_whip_coiled.glb",
                 color=(0.75, 0.78, 0.80), metallic=0.85, roughness=0.20)


def main():
    print("=== BUILDING SENSOR MODULE 3D MESHES ===")
    clear_scene()
    build_rugged_sensor_housing()
    build_multispectrum_radome()
    build_heavy_sensor_pylon()
    build_parabolic_radar_dish()
    build_phased_array_sector()
    build_coiled_whip_antenna()
    print("=== ALL SENSOR MESHES BUILT SUCCESSFULLY ===")


if __name__ == "__main__":
    main()
