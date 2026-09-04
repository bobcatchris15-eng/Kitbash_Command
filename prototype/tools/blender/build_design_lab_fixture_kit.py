"""Author the small, reusable industrial fixture kit for the Design Lab.

Run from ``prototype`` with Blender 5.2:
    "C:\\Program Files\\Blender Foundation\\Blender 5.2\\blender.exe" --background \
        --python tools/blender/build_design_lab_fixture_kit.py

The exports are set dressing, not gameplay collision.  Each GLB has a base-centre
origin, uses Godot space (X right, Y up, +Z forward), and contains named PBR
materials so a scene can instance it without making a one-off mesh.
"""

from __future__ import annotations

import math
import os
from dataclasses import dataclass

import bmesh
import bpy
import mathutils


OUT_DIR = os.path.normpath(os.path.join(os.path.dirname(__file__), "..", "..", "assets", "models", "ui"))


@dataclass(frozen=True)
class FixtureSpec:
    name: str
    triangle_limit: int


FIXTURES = (
    FixtureSpec("lab_console_frame", 3200),
    FixtureSpec("lab_document_clamp", 1800),
    FixtureSpec("lab_fixture_rail", 2400),
    FixtureSpec("lab_inspection_lamp", 3200),
    FixtureSpec("lab_parts_tray", 2400),
    FixtureSpec("lab_service_pedestal", 3200),
)
MATERIALS = (
    ("powder_coat", (0.075, 0.095, 0.105, 1.0), 0.72, 0.18),
    ("machined_metal", (0.38, 0.42, 0.43, 1.0), 0.42, 0.78),
    ("signal_accent", (0.95, 0.46, 0.08, 1.0), 0.46, 0.34),
)


def gv(point: tuple[float, float, float]) -> tuple[float, float, float]:
    """Map Godot X/Y/Z to Blender space without reflecting triangle winding.

    Blender's glTF exporter maps its coordinates as X/Z/-Y into glTF's
    X/Y/Z. Negating Godot Z here therefore produces the documented Godot
    X-right, Y-up, +Z-forward result. The previous Y/Z swap had determinant
    -1, so every hand-authored face was mirrored and rendered inside out.
    """
    return (point[0], -point[2], point[1])


def clear_scene() -> None:
    bpy.ops.object.select_all(action="SELECT")
    bpy.ops.object.delete(use_global=False)
    for collection in (bpy.data.meshes, bpy.data.materials, bpy.data.objects):
        for block in list(collection):
            if block.users == 0:
                collection.remove(block)


def make_materials() -> list[bpy.types.Material]:
    materials = []
    for name, color, roughness, metallic in MATERIALS:
        material = bpy.data.materials.new(name)
        material.use_nodes = True
        bsdf = material.node_tree.nodes.get("Principled BSDF")
        bsdf.inputs["Base Color"].default_value = color
        bsdf.inputs["Roughness"].default_value = roughness
        bsdf.inputs["Metallic"].default_value = metallic
        materials.append(material)
    return materials


def new_mesh(name: str) -> tuple[bpy.types.Object, bmesh.types.BMesh]:
    mesh = bpy.data.meshes.new(name)
    obj = bpy.data.objects.new(name, mesh)
    bpy.context.collection.objects.link(obj)
    obj["forward_axis"] = "+Z"
    obj["origin"] = "base_center"
    return obj, bmesh.new()


def face(bm: bmesh.types.BMesh, vertices: list[bmesh.types.BMVert], material: int) -> None:
    try:
        new_face = bm.faces.new(vertices)
        new_face.material_index = material
    except ValueError:
        pass


def box(bm: bmesh.types.BMesh, centre: tuple[float, float, float], size: tuple[float, float, float], material: int = 0) -> None:
    cx, cy, cz = centre
    sx, sy, sz = (value / 2.0 for value in size)
    vertices = [bm.verts.new(gv((cx + dx * sx, cy + dy * sy, cz + dz * sz)))
                for dx in (-1, 1) for dy in (-1, 1) for dz in (-1, 1)]
    for indices in ((0, 1, 3, 2), (4, 6, 7, 5), (0, 4, 5, 1),
                    (2, 3, 7, 6), (0, 2, 6, 4), (1, 5, 7, 3)):
        face(bm, [vertices[index] for index in indices], material)


def cylinder_y(bm: bmesh.types.BMesh, centre: tuple[float, float, float], radius: float, height: float,
               material: int = 1, segments: int = 12) -> None:
    """A Godot-Y-up cylinder, with caps, authored as a prism for crisp machining."""
    bottom, top = [], []
    for index in range(segments):
        angle = index / segments * math.tau
        x, z = math.cos(angle) * radius, math.sin(angle) * radius
        bottom.append(bm.verts.new(gv((centre[0] + x, centre[1] - height / 2, centre[2] + z))))
        top.append(bm.verts.new(gv((centre[0] + x, centre[1] + height / 2, centre[2] + z))))
    for index in range(segments):
        next_index = (index + 1) % segments
        face(bm, [top[index], top[next_index], bottom[next_index], bottom[index]], material)
    bottom_centre = bm.verts.new(gv((centre[0], centre[1] - height / 2, centre[2])))
    top_centre = bm.verts.new(gv((centre[0], centre[1] + height / 2, centre[2])))
    for index in range(segments):
        next_index = (index + 1) % segments
        face(bm, [bottom_centre, bottom[index], bottom[next_index]], material)
        face(bm, [top_centre, top[next_index], top[index]], material)


def tube(bm: bmesh.types.BMesh, start: tuple[float, float, float], end: tuple[float, float, float],
         radius: float, material: int = 1, segments: int = 10) -> None:
    """Create a capped tube between two Godot-space points."""
    start_v, end_v = mathutils.Vector(gv(start)), mathutils.Vector(gv(end))
    direction = end_v - start_v
    midpoint = (start_v + end_v) / 2.0
    for vertex in bm.verts:
        vertex.tag = False
    cone = bmesh.ops.create_cone(
        bm, cap_ends=True, cap_tris=True, segments=segments,
        radius1=radius, radius2=radius, depth=direction.length,
        matrix=mathutils.Matrix.Translation(midpoint) @ direction.to_track_quat("Z", "Y").to_matrix().to_4x4(),
    )
    for vertex in cone["verts"]:
        vertex.tag = True
    new_faces = [new_face for new_face in bm.faces if all(vertex.tag for vertex in new_face.verts)]
    for vertex in cone["verts"]:
        vertex.tag = False
    for new_face in new_faces:
        new_face.material_index = material


def bolt(bm: bmesh.types.BMesh, point: tuple[float, float, float], radius: float = 0.045) -> None:
    cylinder_y(bm, (point[0], point[1] + radius * 0.45, point[2]), radius, radius * 0.9, 1, 6)


def finish(obj: bpy.types.Object, bm: bmesh.types.BMesh, materials: list[bpy.types.Material]) -> None:
    bm.normal_update()
    bm.to_mesh(obj.data)
    bm.free()
    for material in materials:
        obj.data.materials.append(material)
    obj.data.validate(verbose=True)
    obj.data.update(calc_edges=True)
    obj.data.calc_loop_triangles()


def build_console_frame() -> bpy.types.Object:
    obj, bm = new_mesh("lab_console_frame")
    # Open gantry around the work surface: readable at a distance without obscuring the vehicle.
    box(bm, (0, 0.08, 0), (3.4, 0.16, 0.70))
    for side in (-1, 1):
        box(bm, (side * 1.45, 1.18, -0.12), (0.18, 2.20, 0.24))
        box(bm, (side * 1.22, 0.35, 0.15), (0.44, 0.30, 0.22), 1)
        bolt(bm, (side * 1.45, 0.19, 0.20))
        bolt(bm, (side * 1.45, 0.19, -0.35))
    box(bm, (0, 2.18, -0.12), (3.08, 0.18, 0.24))
    box(bm, (0, 1.95, 0.03), (2.10, 0.10, 0.08), 2)
    for x in (-1.05, -0.35, 0.35, 1.05):
        bolt(bm, (x, 2.31, -0.12))
    finish(obj, bm, make_materials())
    return obj


def build_fixture_rail() -> bpy.types.Object:
    obj, bm = new_mesh("lab_fixture_rail")
    box(bm, (0, 0.06, 0), (3.20, 0.12, 0.52))
    box(bm, (0, 0.17, 0), (3.00, 0.10, 0.16), 1)
    for z in (-0.19, 0.19):
        box(bm, (0, 0.25, z), (3.00, 0.14, 0.07), 0)
    for x in (-1.25, -0.75, -0.25, 0.25, 0.75, 1.25):
        box(bm, (x, 0.28, 0), (0.055, 0.06, 0.25), 2)
    for x in (-1.48, 1.48):
        box(bm, (x, 0.34, 0), (0.14, 0.42, 0.46), 0)
        cylinder_y(bm, (x, 0.58, 0), 0.08, 0.08, 1, 12)
    finish(obj, bm, make_materials())
    return obj


def build_inspection_lamp() -> bpy.types.Object:
    obj, bm = new_mesh("lab_inspection_lamp")
    cylinder_y(bm, (0, 0.06, 0), 0.36, 0.12, 0, 20)
    cylinder_y(bm, (0, 0.16, 0), 0.22, 0.10, 1, 16)
    tube(bm, (0, 0.22, 0), (0, 0.98, 0.14), 0.055, 1)
    cylinder_y(bm, (0, 0.99, 0.14), 0.12, 0.10, 1, 12)
    tube(bm, (0, 1.03, 0.14), (0.05, 1.48, 0.60), 0.050, 0)
    # Shade opens toward +Z, the documented forward axis.
    tube(bm, (0.05, 1.48, 0.60), (0.05, 1.48, 0.84), 0.23, 0, 16)
    tube(bm, (0.05, 1.48, 0.82), (0.05, 1.48, 0.86), 0.15, 2, 16)
    for x in (-0.18, 0.18):
        bolt(bm, (x, 0.13, 0))
    finish(obj, bm, make_materials())
    return obj


def build_document_clamp() -> bpy.types.Object:
    obj, bm = new_mesh("lab_document_clamp")
    box(bm, (0, 0.04, 0), (1.55, 0.08, 1.10), 0)
    # Raised side lip and a movable-looking brass clamp bar keep a flat document legible.
    for x in (-0.70, 0.70):
        box(bm, (x, 0.10, 0), (0.08, 0.12, 1.02), 1)
    box(bm, (0, 0.13, -0.40), (1.22, 0.13, 0.16), 1)
    box(bm, (0, 0.22, -0.43), (0.95, 0.08, 0.08), 2)
    for x in (-0.50, 0.50):
        bolt(bm, (x, 0.13, 0.37))
    finish(obj, bm, make_materials())
    return obj


def build_parts_tray() -> bpy.types.Object:
    obj, bm = new_mesh("lab_parts_tray")
    box(bm, (0, 0.04, 0), (1.85, 0.08, 1.30), 0)
    for x in (-0.86, 0.86):
        box(bm, (x, 0.16, 0), (0.13, 0.28, 1.30), 1)
    for z in (-0.58, 0.58):
        box(bm, (0, 0.16, z), (1.85, 0.28, 0.13), 1)
    # Four shallow slot dividers make it read as a used assembly tray rather than a box.
    for x in (-0.42, 0.0, 0.42):
        box(bm, (x, 0.12, 0.04), (0.055, 0.16, 0.94), 0)
    box(bm, (0, 0.23, -0.64), (0.74, 0.09, 0.05), 2)
    for x in (-0.67, 0.67):
        bolt(bm, (x, 0.24, -0.55))
    finish(obj, bm, make_materials())
    return obj


def build_service_pedestal() -> bpy.types.Object:
    obj, bm = new_mesh("lab_service_pedestal")
    cylinder_y(bm, (0, 0.08, 0), 0.70, 0.16, 0, 24)
    cylinder_y(bm, (0, 0.24, 0), 0.56, 0.18, 1, 20)
    cylinder_y(bm, (0, 0.73, 0), 0.28, 0.82, 0, 16)
    cylinder_y(bm, (0, 1.18, 0), 0.52, 0.14, 1, 24)
    # Four locating pads support a model without becoming a second turntable.
    for x, z in ((-0.30, -0.30), (-0.30, 0.30), (0.30, -0.30), (0.30, 0.30)):
        box(bm, (x, 1.29, z), (0.20, 0.12, 0.20), 2)
    for index in range(8):
        angle = index / 8 * math.tau
        bolt(bm, (math.cos(angle) * 0.60, 0.18, math.sin(angle) * 0.60), 0.035)
    finish(obj, bm, make_materials())
    return obj


BUILDERS = {
    "lab_console_frame": build_console_frame,
    "lab_document_clamp": build_document_clamp,
    "lab_fixture_rail": build_fixture_rail,
    "lab_inspection_lamp": build_inspection_lamp,
    "lab_parts_tray": build_parts_tray,
    "lab_service_pedestal": build_service_pedestal,
}


def validate(obj: bpy.types.Object, specification: FixtureSpec) -> None:
    if obj.location.length > 1e-6:
        raise RuntimeError(f"{specification.name}: origin moved from base centre")
    if obj.get("forward_axis") != "+Z":
        raise RuntimeError(f"{specification.name}: forward axis is not +Z")
    if [material.name for material in obj.data.materials] != [item[0] for item in MATERIALS]:
        raise RuntimeError(f"{specification.name}: material slots do not match fixture convention")
    if not obj.data.polygons:
        raise RuntimeError(f"{specification.name}: fixture has no surface polygons")
    if any(polygon.normal.length < 0.99 for polygon in obj.data.polygons):
        raise RuntimeError(f"{specification.name}: invalid outward normals")
    if any(polygon.material_index < 0 or polygon.material_index >= len(obj.data.materials)
           for polygon in obj.data.polygons):
        raise RuntimeError(f"{specification.name}: polygon has an invalid material slot")
    signed_volumes = [0.0 for _material in obj.data.materials]
    for triangle in obj.data.loop_triangles:
        a, b, c = (obj.data.vertices[index].co for index in triangle.vertices)
        signed_volumes[triangle.material_index] += a.dot(b.cross(c)) / 6.0
    for material_index, volume in enumerate(signed_volumes):
        if volume <= 1e-6:
            material_name = obj.data.materials[material_index].name
            raise RuntimeError(
                f"{specification.name}: {material_name} primitive has inward or degenerate winding ({volume})"
            )
    triangle_count = len(obj.data.loop_triangles)
    if triangle_count > specification.triangle_limit:
        raise RuntimeError(f"{specification.name}: {triangle_count} triangles exceeds {specification.triangle_limit}")


def export_glb(obj: bpy.types.Object, specification: FixtureSpec) -> None:
    validate(obj, specification)
    bpy.ops.object.select_all(action="DESELECT")
    obj.select_set(True)
    bpy.context.view_layer.objects.active = obj
    output_path = os.path.join(OUT_DIR, specification.name + ".glb")
    bpy.ops.export_scene.gltf(
        filepath=output_path,
        use_selection=True,
        export_format="GLB",
        export_yup=True,
        export_normals=True,
        export_extras=True,
        export_apply=True,
    )
    print(f"exported {specification.name}: {len(obj.data.loop_triangles)} triangles")


def main() -> None:
    os.makedirs(OUT_DIR, exist_ok=True)
    for specification in FIXTURES:
        clear_scene()
        export_glb(BUILDERS[specification.name](), specification)
    clear_scene()
    print("DESIGN_LAB_FIXTURE_KIT_DONE")


if __name__ == "__main__":
    main()
