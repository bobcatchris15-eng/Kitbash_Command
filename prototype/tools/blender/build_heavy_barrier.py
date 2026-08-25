"""
Kitbash Command - Heavy Barrier Projector Mesh Builder
Authors refined multi-part GLB meshes for the Heavy Barrier Projector (Aegis Field Projector):
  - heavy_barrier_mount.glb   — Heavy armored traverse pedestal & ring gear
  - heavy_barrier_turret.glb  — Dual-coil gimbal turret body with cooling arrays
  - heavy_barrier_emitter.glb — Parabolic field projector horn with collimators
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
def add_cyl_z(bm, pos, radius, height, segments=20):
    res = bmesh.ops.create_cone(bm, cap_ends=True, cap_tris=False, segments=segments,
                                radius1=radius, radius2=radius, depth=height)
    loc = mathutils.Vector(pos)
    for v in res['verts']:
        v.co = v.co + loc


def add_cone_z(bm, pos, r_bot, r_top, height, segments=20):
    res = bmesh.ops.create_cone(bm, cap_ends=True, cap_tris=False, segments=segments,
                                radius1=r_top, radius2=r_bot, depth=height)
    loc = mathutils.Vector(pos)
    for v in res['verts']:
        v.co = v.co + loc


def add_cyl_x(bm, pos, radius, height, segments=16):
    rot = mathutils.Matrix.Rotation(math.radians(90), 4, 'Y')
    res = bmesh.ops.create_cone(bm, cap_ends=True, cap_tris=False, segments=segments,
                                radius1=radius, radius2=radius, depth=height)
    loc = mathutils.Vector(pos)
    for v in res['verts']:
        v.co = (rot @ v.co) + loc


def add_cyl_y(bm, pos, radius, height, segments=16):
    rot = mathutils.Matrix.Rotation(math.radians(90), 4, 'X')
    res = bmesh.ops.create_cone(bm, cap_ends=True, cap_tris=False, segments=segments,
                                radius1=radius, radius2=radius, depth=height)
    loc = mathutils.Vector(pos)
    for v in res['verts']:
        v.co = (rot @ v.co) + loc


def add_box(bm, pos, size):
    res = bmesh.ops.create_cube(bm, size=1.0)
    sx, sy, sz = size
    mat = mathutils.Matrix.Diagonal((sx, sy, sz, 1.0))
    loc = mathutils.Vector(pos)
    for v in res['verts']:
        v.co = (mat @ v.co) + loc


def export_bmesh(bm, obj_name, file_name):
    clear_scene()
    mesh = bpy.data.meshes.new(obj_name + "_mesh")
    bm.to_mesh(mesh)
    bm.free()

    obj = bpy.data.objects.new(obj_name, mesh)
    bpy.context.scene.collection.objects.link(obj)
    bpy.context.view_layer.objects.active = obj
    obj.select_set(True)

    out_path = os.path.join(PARTS_DIR, file_name)
    bpy.ops.export_scene.gltf(
        filepath=out_path,
        use_selection=True,
        export_format='GLB',
        export_apply=True
    )
    print(f"Exported: {out_path}")


# 1. HEAVY BARRIER MOUNT
def build_heavy_barrier_mount():
    bm = bmesh.new()

    # Heavy faceted base collar
    add_cyl_z(bm, (0, 0, 0.05), radius=0.48, height=0.10, segments=24)
    add_cone_z(bm, (0, 0, 0.12), r_bot=0.48, r_top=0.42, height=0.06, segments=24)

    # Traverse ring gear lip
    add_cyl_z(bm, (0, 0, 0.17), radius=0.38, height=0.04, segments=24)

    # Lateral conduit connection boxes
    add_box(bm, (0.38, 0, 0.07), (0.16, 0.22, 0.09))
    add_box(bm, (-0.38, 0, 0.07), (0.16, 0.22, 0.09))

    # Heavy cabling glands
    add_cyl_x(bm, (0.46, 0.05, 0.07), radius=0.035, height=0.08)
    add_cyl_x(bm, (0.46, -0.05, 0.07), radius=0.035, height=0.08)
    add_cyl_x(bm, (-0.46, 0.05, 0.07), radius=0.035, height=0.08)
    add_cyl_x(bm, (-0.46, -0.05, 0.07), radius=0.035, height=0.08)

    # Foundation perimeter bolt bosses (8x)
    for i in range(8):
        ang = i * (math.tau / 8)
        bx = math.cos(ang) * 0.44
        by = math.sin(ang) * 0.44
        add_cyl_z(bm, (bx, by, 0.11), radius=0.025, height=0.03, segments=8)

    export_bmesh(bm, "heavy_barrier_mount", "heavy_barrier_mount.glb")


# 2. HEAVY BARRIER TURRET
def build_heavy_barrier_turret():
    bm = bmesh.new()

    # Armored turret center core
    add_box(bm, (0, -0.02, 0.18), (0.50, 0.42, 0.22))
    # Chamfered front cheeks
    add_box(bm, (0.18, 0.14, 0.17), (0.16, 0.14, 0.18))
    add_box(bm, (-0.18, 0.14, 0.17), (0.16, 0.14, 0.18))

    # Dual heavy magnetic capacitor coil banks (left & right)
    add_cyl_y(bm, (0.31, -0.02, 0.18), radius=0.12, height=0.34, segments=20)
    add_cyl_y(bm, (-0.31, -0.02, 0.18), radius=0.12, height=0.34, segments=20)

    # Flux coil containment rings (4x per bank)
    for y_off in [-0.12, -0.04, 0.04, 0.12]:
        add_cyl_y(bm, (0.31, y_off, 0.18), radius=0.135, height=0.025, segments=16)
        add_cyl_y(bm, (-0.31, y_off, 0.18), radius=0.135, height=0.025, segments=16)

    # Elevation trunnion bearing housings
    add_cyl_x(bm, (0.24, 0.06, 0.24), radius=0.07, height=0.08, segments=16)
    add_cyl_x(bm, (-0.24, 0.06, 0.24), radius=0.07, height=0.08, segments=16)

    # Rear heat exchanger radiator block & cooling fins
    add_box(bm, (0, -0.25, 0.18), (0.36, 0.08, 0.18))
    for f in range(6):
        fz = 0.11 + f * 0.026
        add_box(bm, (0, -0.27, fz), (0.38, 0.06, 0.012))

    export_bmesh(bm, "heavy_barrier_turret", "heavy_barrier_turret.glb")


# 3. HEAVY BARRIER EMITTER HORN
def build_heavy_barrier_emitter():
    bm = bmesh.new()

    # Emitter elevation yoke / trunnion bridge
    add_box(bm, (0, 0, 0), (0.38, 0.16, 0.14))
    add_cyl_x(bm, (0, 0, 0), radius=0.055, height=0.46, segments=16)

    # Heavy forward projector waveguide base
    add_box(bm, (0, 0.14, 0.02), (0.32, 0.18, 0.18))

    # Flared parabolic field-focusing horn (+Y forward in Godot -Z forward conversion)
    # Throat to flare
    add_cone_z(bm, (0, 0, 0.28), r_bot=0.14, r_top=0.28, height=0.22, segments=24)

    # Collimator tines (top, bottom, left, right)
    add_box(bm, (0, 0.26, 0.40), (0.07, 0.14, 0.20))
    add_box(bm, (0, -0.26, 0.40), (0.07, 0.14, 0.20))
    add_box(bm, (0.26, 0, 0.40), (0.14, 0.07, 0.20))
    add_box(bm, (-0.26, 0, 0.40), (0.14, 0.07, 0.20))

    # Center dielectric focal emitter crystal core
    add_cone_z(bm, (0, 0, 0.38), r_bot=0.08, r_top=0.02, height=0.18, segments=12)

    export_bmesh(bm, "heavy_barrier_emitter", "heavy_barrier_emitter.glb")


def main():
    print("=== BUILDING HEAVY BARRIER PROJECTOR MESHES ===")
    build_heavy_barrier_mount()
    build_heavy_barrier_turret()
    build_heavy_barrier_emitter()
    print("=== ALL HEAVY BARRIER MESHES EXPORTED ===")


if __name__ == "__main__":
    main()
