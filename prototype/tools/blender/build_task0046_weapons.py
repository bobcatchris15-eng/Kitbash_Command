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

def export_bmesh(bm, object_name, filename, color=(0.2,0.22,0.24,1.0)):
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
        bsdf.inputs['Metallic'].default_value = 0.8
        bsdf.inputs['Roughness'].default_value = 0.3
    obj.data.materials.append(mat)
    
    filepath = os.path.join(PARTS_DIR, filename)
    bpy.ops.export_scene.gltf(filepath=filepath, use_selection=True, export_format='GLB')
    print("Exported:", filepath)
    clear_scene()

def add_box(bm, pos, size):
    loc = mathutils.Vector(pos)
    res = bmesh.ops.create_cube(bm, size=1.0)
    for v in res['verts']:
        v.co = loc + mathutils.Vector((v.co.x*size[0], v.co.y*size[1], v.co.z*size[2]))

def add_cyl(bm, pos, radius, height, axis='Z', segments=16):
    res = bmesh.ops.create_cone(bm, cap_ends=True, cap_tris=False, segments=segments, radius1=radius, radius2=radius, depth=height)
    loc = mathutils.Vector(pos)
    rot = mathutils.Matrix.Identity(4)
    if axis == 'Y': rot = mathutils.Matrix.Rotation(math.radians(90), 4, 'X')
    elif axis == 'X': rot = mathutils.Matrix.Rotation(math.radians(90), 4, 'Y')
    for v in res['verts']: v.co = rot @ v.co + loc

# High-Detail Generators
def add_detailed_mount(bm):
    # Base Ring
    add_cyl(bm, (0,0,0.05), 0.35, 0.1, 'Z', 24)
    # Bolts
    for i in range(12):
        a = (i/12)*math.tau
        add_cyl(bm, (math.cos(a)*0.3, math.sin(a)*0.3, 0.1), 0.02, 0.04, 'Z', 6)
    # Yokes
    add_box(bm, (-0.25, 0, 0.2), (0.1, 0.4, 0.3))
    add_box(bm, (0.25, 0, 0.2), (0.1, 0.4, 0.3))
    # Trunnions
    add_cyl(bm, (-0.25, 0, 0.35), 0.08, 0.15, 'X', 16)
    add_cyl(bm, (0.25, 0, 0.35), 0.08, 0.15, 'X', 16)

def build_heavy_laser():
    # Mount
    bm = bmesh.new(); add_detailed_mount(bm); export_bmesh(bm, "heavy_laser_mount", "heavy_laser_mount.glb")
    # Housing
    bm = bmesh.new()
    add_box(bm, (0, -0.4, 0), (0.4, 0.8, 0.4))
    for i in range(5): add_cyl(bm, (0, -0.2-i*0.1, 0.2), 0.1, 0.1, 'X', 12) # Heat sinks
    export_bmesh(bm, "heavy_laser_housing", "heavy_laser_housing.glb")
    # Lens
    bm = bmesh.new()
    add_cyl(bm, (0, 0.5, 0), 0.15, 1.0, 'Y', 16)
    add_cyl(bm, (0, 1.0, 0), 0.18, 0.1, 'Y', 16) # Aperture ring
    export_bmesh(bm, "heavy_laser_lens", "heavy_laser_lens.glb")

def build_pd_laser():
    bm = bmesh.new(); add_detailed_mount(bm); export_bmesh(bm, "pd_laser_mount", "pd_laser_mount.glb")
    bm = bmesh.new(); add_box(bm, (0, -0.2, 0), (0.25, 0.4, 0.25)); export_bmesh(bm, "pd_laser_housing", "pd_laser_housing.glb")
    bm = bmesh.new(); add_cyl(bm, (0, 0.3, 0), 0.08, 0.6, 'Y', 12); export_bmesh(bm, "pd_laser_lens", "pd_laser_lens.glb")

def build_railgun():
    bm = bmesh.new(); add_detailed_mount(bm); export_bmesh(bm, "railgun_casemate_mount", "railgun_casemate_mount.glb")
    bm = bmesh.new(); add_box(bm, (0, -0.3, 0), (0.35, 0.6, 0.35)); export_bmesh(bm, "railgun_capacitor_housing", "railgun_capacitor_housing.glb")
    bm = bmesh.new()
    add_box(bm, (0, 0.6, 0.1), (0.05, 1.2, 0.05))
    add_box(bm, (0, 0.6, -0.1), (0.05, 1.2, 0.05))
    for i in range(8): add_box(bm, (0, i*0.15, 0), (0.1, 0.02, 0.25))
    export_bmesh(bm, "railgun_rails", "railgun_rails.glb")

def build_coilgun():
    bm = bmesh.new(); add_detailed_mount(bm); export_bmesh(bm, "coilgun_mount", "coilgun_mount.glb")
    bm = bmesh.new(); add_box(bm, (0, -0.2, 0), (0.3, 0.4, 0.3)); export_bmesh(bm, "coilgun_breech", "coilgun_breech.glb")
    bm = bmesh.new(); add_cyl(bm, (0, 0.5, 0), 0.05, 1.0, 'Y', 12); export_bmesh(bm, "coilgun_rail", "coilgun_rail.glb")
    bm = bmesh.new(); add_cyl(bm, (0, 0, 0), 0.1, 0.05, 'Y', 16); export_bmesh(bm, "coilgun_coil", "coilgun_coil.glb")
    bm = bmesh.new(); add_box(bm, (0, 0, -0.15), (0.2, 0.2, 0.1)); export_bmesh(bm, "coilgun_capacitors", "coilgun_capacitors.glb")

def build_flamethrower():
    bm = bmesh.new(); add_detailed_mount(bm); export_bmesh(bm, "flamethrower_mount", "flamethrower_mount.glb")
    bm = bmesh.new(); add_cyl(bm, (0, -0.2, 0), 0.2, 0.4, 'Y', 16); add_box(bm, (0, -0.2, -0.2), (0.3,0.3,0.1)); export_bmesh(bm, "flamethrower_body", "flamethrower_body.glb")
    bm = bmesh.new(); add_cyl(bm, (0, 0.4, 0), 0.08, 0.8, 'Y', 12); add_cyl(bm, (0, 0.8, 0), 0.12, 0.1, 'Y', 12); export_bmesh(bm, "flamethrower_nozzle", "flamethrower_nozzle.glb")

def build_ion_cannon():
    bm = bmesh.new(); add_detailed_mount(bm); export_bmesh(bm, "ion_cannon_mount", "ion_cannon_mount.glb")
    bm = bmesh.new(); add_box(bm, (0, -0.3, 0), (0.4, 0.6, 0.4)); add_cyl(bm, (0, -0.3, 0.2), 0.2, 0.6, 'Y', 16); export_bmesh(bm, "ion_cannon_housing", "ion_cannon_housing.glb")
    bm = bmesh.new(); add_cyl(bm, (0, 0.5, 0), 0.2, 1.0, 'Y', 16); add_cyl(bm, (0, 0.9, 0), 0.25, 0.2, 'Y', 16); export_bmesh(bm, "ion_cannon_lens", "ion_cannon_lens.glb")

def build_arc_projector():
    bm = bmesh.new(); add_detailed_mount(bm); export_bmesh(bm, "arc_projector_mount", "arc_projector_mount.glb")
    bm = bmesh.new(); add_box(bm, (0, -0.25, 0), (0.35, 0.5, 0.35)); export_bmesh(bm, "arc_projector_body", "arc_projector_body.glb")
    bm = bmesh.new(); add_cyl(bm, (0, 0.4, 0), 0.1, 0.8, 'Y', 12); add_box(bm, (0, 0.8, 0), (0.3, 0.2, 0.1)); export_bmesh(bm, "arc_projector_emitter", "arc_projector_emitter.glb")

def build_bunker_buster():
    bm = bmesh.new(); add_box(bm, (0,0,0.1), (0.4, 0.6, 0.2)); export_bmesh(bm, "bb_body", "bb_body.glb")
    bm = bmesh.new(); add_cyl(bm, (0, 0.5, 0), 0.15, 1.0, 'Y', 16); add_cyl(bm, (0, 1.0, 0), 0.05, 0.2, 'Y', 12); export_bmesh(bm, "bb_penetrator", "bb_penetrator.glb")
    bm = bmesh.new(); add_detailed_mount(bm); export_bmesh(bm, "missile_pedestal", "missile_pedestal.glb")

def build_hypervelocity_missile():
    bm = bmesh.new(); add_box(bm, (0,0,0.1), (0.3, 0.5, 0.2)); export_bmesh(bm, "hvm_body", "hvm_body.glb")
    bm = bmesh.new(); add_box(bm, (0, 0.4, 0), (0.2, 0.8, 0.2)); export_bmesh(bm, "hvm_canister", "hvm_canister.glb")

def build_guided_missile():
    bm = bmesh.new(); add_detailed_mount(bm); export_bmesh(bm, "tow_pintle_mount", "tow_pintle_mount.glb")
    bm = bmesh.new(); add_cyl(bm, (0, 0.4, 0), 0.1, 0.8, 'Y', 12); export_bmesh(bm, "tow_launch_tube", "tow_launch_tube.glb")
    bm = bmesh.new(); add_cyl(bm, (0, 0.4, 0), 0.08, 0.6, 'Y', 12); export_bmesh(bm, "tow_missile_warhead", "tow_missile_warhead.glb")

def build_missile_pod():
    bm = bmesh.new(); add_detailed_mount(bm); export_bmesh(bm, "missile_pod_pintle_mount", "missile_pod_pintle_mount.glb")
    bm = bmesh.new(); add_box(bm, (0, 0.2, 0), (0.4, 0.6, 0.3)); export_bmesh(bm, "missile_pod_housing", "missile_pod_housing.glb")
    bm = bmesh.new(); add_cyl(bm, (0, 0.2, 0), 0.04, 0.4, 'Y', 8); export_bmesh(bm, "missile_pod_missile", "missile_pod_missile.glb")

def build_sam_launcher():
    bm = bmesh.new(); add_box(bm, (0,0,0.1), (0.5, 0.5, 0.2)); export_bmesh(bm, "sam_body", "sam_body.glb")
    bm = bmesh.new(); add_cyl(bm, (0, 0.4, 0), 0.12, 0.8, 'Y', 12); export_bmesh(bm, "sam_missile", "sam_missile.glb")

def build_cruise_missile():
    bm = bmesh.new(); add_box(bm, (0,0,0.1), (0.6, 0.8, 0.2)); export_bmesh(bm, "cruise_body", "cruise_body.glb")
    bm = bmesh.new(); add_box(bm, (0, 0.5, 0), (0.3, 1.0, 0.3)); export_bmesh(bm, "cruise_container", "cruise_container.glb")

def build_cluster_dispenser():
    bm = bmesh.new(); add_detailed_mount(bm); export_bmesh(bm, "cluster_dispenser_mount", "cluster_dispenser_mount.glb")
    bm = bmesh.new(); add_box(bm, (0, 0, 0), (0.5, 0.4, 0.4)); export_bmesh(bm, "cluster_dispenser_housing", "cluster_dispenser_housing.glb")

def build_ciws():
    bm = bmesh.new(); add_detailed_mount(bm); export_bmesh(bm, "ciws_mount", "ciws_mount.glb")
    bm = bmesh.new(); add_cyl(bm, (0, -0.2, 0.4), 0.25, 0.2, 'Z', 16); export_bmesh(bm, "ciws_radar", "ciws_radar.glb")
    bm = bmesh.new(); add_cyl(bm, (0, 0.4, 0), 0.1, 0.8, 'Y', 12); export_bmesh(bm, "ciws_barrel", "ciws_barrel.glb")

if __name__ == '__main__':
    clear_scene()
    build_heavy_laser()
    build_pd_laser()
    build_railgun()
    build_coilgun()
    build_flamethrower()
    build_ion_cannon()
    build_arc_projector()
    build_bunker_buster()
    build_hypervelocity_missile()
    build_guided_missile()
    build_missile_pod()
    build_sam_launcher()
    build_cruise_missile()
    build_cluster_dispenser()
    build_ciws()
