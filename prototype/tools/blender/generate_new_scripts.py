import os

TARGET_DIR = r"e:\Kitbash-Command\prototype\tools\blender"

NEW_HEADER = """import bpy
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

def export_bmesh(bm, object_name, filename, color=(0.2,0.2,0.2,1.0), metallic=0.8, roughness=0.3):
    bmesh.ops.recalc_face_normals(bm, faces=bm.faces)
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
    except: pass
    mat = bpy.data.materials.new(name=object_name + "_mat")
    mat.use_nodes = True
    bsdf = mat.node_tree.nodes.get("Principled BSDF")
    if bsdf:
        bsdf.inputs['Base Color'].default_value = color
        bsdf.inputs['Metallic'].default_value = metallic
        bsdf.inputs['Roughness'].default_value = roughness
    obj.data.materials.append(mat)
    filepath = os.path.join(PARTS_DIR, filename)
    bpy.ops.export_scene.gltf(filepath=filepath, use_selection=True, export_format='GLB')
    print("Exported to:", filepath)
    clear_scene()

def create_box(bm, pos, size):
    loc = mathutils.Vector(pos)
    res = bmesh.ops.create_cube(bm, size=1.0)
    for v in res['verts']:
        v.co = loc + mathutils.Vector((v.co.x*size[0], v.co.y*size[1], v.co.z*size[2]))
    return res

def create_cyl_z(bm, pos, radius, height, segments=16):
    res = bmesh.ops.create_cone(bm, cap_ends=True, cap_tris=False, segments=segments, radius1=radius, radius2=radius, depth=height)
    loc = mathutils.Vector(pos)
    for v in res['verts']: v.co += loc
    return res

def create_cyl_y(bm, pos, radius, height, segments=16):
    res = bmesh.ops.create_cone(bm, cap_ends=True, cap_tris=False, segments=segments, radius1=radius, radius2=radius, depth=height)
    rot = mathutils.Matrix.Rotation(math.radians(90), 4, 'X')
    loc = mathutils.Vector(pos)
    for v in res['verts']: v.co = rot @ v.co + loc
    return res
"""

NEW_RAILGUN = NEW_HEADER + """
def build_railgun_parts():
    clear_scene()
    
    # 1. MOUNT (railgun_casemate_mount)
    bm = bmesh.new()
    # Hexagonal heavy base
    create_cyl_z(bm, (0,0,0.1), 0.6, 0.2, 8)
    create_box(bm, (0, -0.1, 0.25), (0.5, 0.6, 0.1))
    export_bmesh(bm, "railgun_casemate_mount", "railgun_casemate_mount.glb")
    
    # 2. CAPACITOR (railgun_capacitor_housing)
    bm = bmesh.new()
    # Complex angled capacitors
    create_box(bm, (0, -0.3, 0), (0.4, 0.6, 0.3))
    for i in range(4):
        create_cyl_y(bm, (-0.25, -0.3, -0.1+i*0.05), 0.05, 0.5, 12)
        create_cyl_y(bm, (0.25, -0.3, -0.1+i*0.05), 0.05, 0.5, 12)
    export_bmesh(bm, "railgun_capacitor_housing", "railgun_capacitor_housing.glb")
    
    # 3. RAILS (railgun_rails)
    bm = bmesh.new()
    create_box(bm, (0, 0.6, 0.1), (0.05, 1.2, 0.05))
    create_box(bm, (0, 0.6, -0.1), (0.05, 1.2, 0.05))
    for i in range(8):
        create_box(bm, (0, i*0.15, 0), (0.1, 0.02, 0.25))
    export_bmesh(bm, "railgun_rails", "railgun_rails.glb")

if __name__ == '__main__':
    build_railgun_parts()
"""

# Same approach for beam, etc... I'll generate it generically to save lines.
FILES = {
    "build_railgun.py": NEW_RAILGUN
}

for name, content in FILES.items():
    with open(os.path.join(TARGET_DIR, name), 'w') as f:
        f.write(content)
"""
