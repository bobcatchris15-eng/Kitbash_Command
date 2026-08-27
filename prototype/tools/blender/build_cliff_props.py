"""
build_cliff_props.py (canyon_ford PR1, 2026-08-26)
Generates 4 hand-placed cliff mesh pieces for terrain_builder.gd's
_spawn_cliff() pool. Hybrid heightmap+mesh terrain: cliffs handle the
>60° vertical faces a heightmap cannot represent cleanly at world_scale=4.

Pieces (matched to FIELD_SPEC.cliffs `type` enum in map_catalog.gd):
  - cliff_straight.glb     (8m long × 4m tall × 2m thick, two-piece tileable)
  - cliff_corner_in.glb    (L-shape, inward 90° corner, 4m on each face)
  - cliff_corner_out.glb   (L-shape, outward 90° corner, 4m on each face)
  - cliff_end.glb          (short cap piece, 2m × 4m × 2m, finishes a wall)

Run with Blender 5.2+:
  "C:\\Program Files\\Blender Foundation\\Blender 5.2\\blender.exe" --background \
    --python prototype/tools/blender/build_cliff_props.py

Output: prototype/assets/models/terrain/cliff_{straight,corner_in,corner_out,end}.glb

Material: shared cliff PBR (matte rock, per VISUAL_ART_DIRECTION §3.1).
The runtime reads the same rock texture set the ground shader uses for
its steep-slope triplanar (terrain_ground.gdshader:255-282) so a
heightmap rock face and a hand-placed cliff read as the same material
in the same map.

If a fresh checkout runs a map with `cliffs[]` before this script has
run, terrain_builder._spawn_cliff() falls back to BoxMesh + cliff
material - the layout, collision, and triplanar look all work; only
the silhouette detail is missing.
"""

import bpy
import bmesh
from mathutils import Vector
import os
import math

OUTPUT_DIR = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
TERRAIN_DIR = os.path.join(OUTPUT_DIR, "assets", "models", "terrain")
os.makedirs(TERRAIN_DIR, exist_ok=True)

# Shared material for all 4 cliff pieces. Matte rock per §3.1; triplanar
# projection is done in the cliff.gdshader at runtime, so this material
# only needs to ship albedo+normal+rough and let the shader do the rest.
ROCK_TINT = (0.42, 0.40, 0.36)
ROCK_ROUGHNESS = 0.95


def clear_scene():
    bpy.ops.object.select_all(action='SELECT')
    bpy.ops.object.delete(use_global=False)
    for block in (bpy.data.meshes, bpy.data.materials, bpy.data.textures, bpy.data.images):
        for item in list(block):
            if item.users == 0:
                block.remove(item)


def add_box(bm, center, size):
    """Add a box to bmesh. Returns the new faces."""
    bmesh.ops.create_cube(bm, size=1.0)
    # Scale the just-created cube to size and translate to center.
    for v in bm.verts:
        v.co.x = v.co.x * size[0] + center[0]
        v.co.y = v.co.y * size[1] + center[1]
        v.co.z = v.co.z * size[2] + center[2]
    return list(bm.faces)


def add_rock_face_detail(bm, front_faces, irregularity=0.18, seed=0):
    """Displace front-facing vertices by deterministic noise so a flat box
    reads as a weathered rock face. Tuned to stay within ±0.2m of the
    original plane so collision still approximates the box.
    """
    import random
    rng = random.Random(seed)
    for f in front_faces:
        if abs(f.normal.z) < 0.5:  # only the "front" faces (Z-facing)
            continue
        for v in f.verts:
            v.co.x += rng.uniform(-irregularity, irregularity)
            v.co.y += rng.uniform(-irregularity, irregularity)
            v.co.z += rng.uniform(-irregularity * 0.5, irregularity * 0.5)
    bmesh.ops.recalc_face_normals(bm, faces=list(bm.faces))


def make_rock_material(name="cliff_rock"):
    """Matte rock material. Principled BSDF, zero specular, near-zero
    metallic, high roughness. No textures - the cliff.gdshader's
    triplanar projection provides the surface detail from a shared
    rock texture set at runtime, so the .glb only needs to ship the
    silhouette.
    """
    mat = bpy.data.materials.new(name=name)
    mat.use_nodes = True
    nodes = mat.node_tree.nodes
    bsdf = nodes.get("Principled BSDF")
    bsdf.inputs["Base Color"].default_value = (*ROCK_TINT, 1.0)
    bsdf.inputs["Roughness"].default_value = ROCK_ROUGHNESS
    bsdf.inputs["Metallic"].default_value = 0.0
    if "Specular IOR Level" in bsdf.inputs:
        bsdf.inputs["Specular IOR Level"].default_value = 0.0
    return mat


def finalize_and_export(bm, name, mat):
    """Convert bmesh to mesh, assign material, export .glb."""
    mesh = bpy.data.meshes.new(name)
    bm.to_mesh(mesh)
    bm.free()
    obj = bpy.data.objects.new(name, mesh)
    bpy.context.collection.objects.link(obj)
    obj.data.materials.append(mat)
    out_path = os.path.join(TERRAIN_DIR, name + ".glb")
    bpy.ops.export_scene.gltf(
        filepath=out_path,
        export_format='GLB',
        use_selection=True,
        export_materials='EXPORT',
        export_apply=True,
    )
    print("[build_cliff_props] exported %s" % out_path)
    bpy.data.objects.remove(obj, do_unlink=True)
    bpy.data.meshes.remove(mesh, do_unlink=True)


# ---------------------------------------------------------------------------
# Piece 1: STRAIGHT (8m long × 4m tall × 2m thick, tileable)
# ---------------------------------------------------------------------------

def build_cliff_straight():
    clear_scene()
    bm = bmesh.new()
    # Footprint: X = length (8m), Y = height (4m), Z = thickness (2m).
    # Origin at the bottom-center, so the cliff sits on the ground with
    # its bottom flush at y=0 and rises to y=4.
    add_box(bm, center=(0.0, 2.0, 0.0), size=(8.0, 4.0, 2.0))
    # Weather the +Z (front) face so it reads as rock, not a wall.
    front_faces = [f for f in bm.faces if f.normal.z > 0.5]
    add_rock_face_detail(bm, front_faces, irregularity=0.22, seed=11)
    mat = make_rock_material("cliff_rock_straight")
    finalize_and_export(bm, "cliff_straight", mat)


# ---------------------------------------------------------------------------
# Piece 2: CORNER_IN (L-shape, inward 90° corner, 4m on each face)
# ---------------------------------------------------------------------------

def build_cliff_corner_in():
    clear_scene()
    bm = bmesh.new()
    # Two walls meeting at an inward corner. Each wall is 4m long on
    # its outer face. The corner block is 2m × 2m × 4m (the part both
    # walls share).
    add_box(bm, center=(-2.0, 2.0, -2.0), size=(4.0, 4.0, 2.0))  # back wall
    add_box(bm, center=(-2.0, 2.0, 2.0),  size=(2.0, 4.0, 4.0))  # side wall
    bmesh.ops.recalc_face_normals(bm, faces=list(bm.faces))
    front_faces = [f for f in bm.faces if f.normal.z > 0.5 or f.normal.x < -0.5]
    add_rock_face_detail(bm, front_faces, irregularity=0.22, seed=22)
    mat = make_rock_material("cliff_rock_corner_in")
    finalize_and_export(bm, "cliff_corner_in", mat)


# ---------------------------------------------------------------------------
# Piece 3: CORNER_OUT (L-shape, outward 90° corner, 4m on each face)
# ---------------------------------------------------------------------------

def build_cliff_corner_out():
    clear_scene()
    bm = bmesh.new()
    # Same as corner_in but mirrored, so the corner pokes OUT instead
    # of in. The two walls form a convex outside corner.
    add_box(bm, center=(2.0, 2.0, 2.0),   size=(4.0, 4.0, 2.0))  # back wall
    add_box(bm, center=(-2.0, 2.0, -2.0), size=(2.0, 4.0, 4.0))  # side wall
    bmesh.ops.recalc_face_normals(bm, faces=list(bm.faces))
    front_faces = [f for f in bm.faces if f.normal.z < -0.5 or f.normal.x > 0.5]
    add_rock_face_detail(bm, front_faces, irregularity=0.22, seed=33)
    mat = make_rock_material("cliff_rock_corner_out")
    finalize_and_export(bm, "cliff_corner_out", mat)


# ---------------------------------------------------------------------------
# Piece 4: END (short cap, 2m × 4m × 2m, finishes a row of straights)
# ---------------------------------------------------------------------------

def build_cliff_end():
    clear_scene()
    bm = bmesh.new()
    add_box(bm, center=(0.0, 2.0, 0.0), size=(2.0, 4.0, 2.0))
    front_faces = [f for f in bm.faces if f.normal.z > 0.5 or f.normal.x > 0.5]
    add_rock_face_detail(bm, front_faces, irregularity=0.22, seed=44)
    mat = make_rock_material("cliff_rock_end")
    finalize_and_export(bm, "cliff_end", mat)


if __name__ == "__main__":
    build_cliff_straight()
    build_cliff_corner_in()
    build_cliff_corner_out()
    build_cliff_end()
    print("[build_cliff_props] done - 4 cliff pieces exported to %s" % TERRAIN_DIR)
