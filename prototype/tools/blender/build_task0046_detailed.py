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

def export_bmesh(bm, object_name, filename, color=(0.22,0.24,0.26,1.0), metallic=0.35, roughness=0.72):
    bmesh.ops.recalc_face_normals(bm, faces=bm.faces)
    me = bpy.data.meshes.new(object_name + "_mesh")
    bm.to_mesh(me)
    bm.free()
    obj = bpy.data.objects.new(object_name, me)
    bpy.context.collection.objects.link(obj)
    bpy.ops.object.select_all(action='DESELECT')
    obj.select_set(True)
    bpy.context.view_layer.objects.active = obj
    if hasattr(bpy.ops.object, 'shade_smooth_by_angle'):
        bpy.ops.object.shade_smooth_by_angle(angle=math.radians(35))
    else:
        bpy.ops.object.shade_smooth()
    mat = bpy.data.materials.new(name=object_name + "_mat")
    mat.use_nodes = True
    bsdf = mat.node_tree.nodes.get("Principled BSDF")
    if bsdf:
        if 'Base Color' in bsdf.inputs: bsdf.inputs['Base Color'].default_value = color
        if 'Metallic' in bsdf.inputs: bsdf.inputs['Metallic'].default_value = metallic
        if 'Roughness' in bsdf.inputs: bsdf.inputs['Roughness'].default_value = roughness
        if 'Specular IOR Level' in bsdf.inputs: bsdf.inputs['Specular IOR Level'].default_value = 0.20
        elif 'Specular' in bsdf.inputs: bsdf.inputs['Specular'].default_value = 0.20
    obj.data.materials.append(mat)
    filepath = os.path.join(PARTS_DIR, filename)
    bpy.ops.export_scene.gltf(filepath=filepath, use_selection=True, export_format='GLB')
    print("Exported:", filepath)
    clear_scene()

def add_box(bm, pos, size, bevel=0.0):
    loc = mathutils.Vector(pos)
    res = bmesh.ops.create_cube(bm, size=1.0)
    for v in res['verts']:
        v.co = loc + mathutils.Vector((v.co.x*size[0], v.co.y*size[1], v.co.z*size[2]))
    if bevel > 0.001:
        edges = [e for e in bm.edges if any(v in res['verts'] for v in e.verts)]
        try: bmesh.ops.bevel(bm, geom=edges, offset=bevel, segments=2, affect='EDGES')
        except: pass

def add_cyl(bm, pos, radius, height, axis='Z', segments=16):
    res = bmesh.ops.create_cone(bm, cap_ends=True, cap_tris=False, segments=segments, radius1=radius, radius2=radius, depth=height)
    loc = mathutils.Vector(pos)
    rot = mathutils.Matrix.Identity(4)
    if axis == 'Y': rot = mathutils.Matrix.Rotation(math.radians(90), 4, 'X')
    elif axis == 'X': rot = mathutils.Matrix.Rotation(math.radians(90), 4, 'Y')
    for v in res['verts']: v.co = rot @ v.co + loc

def add_tube_between(bm, p0, p1, radius, segments=8):
    a = mathutils.Vector(p0)
    b = mathutils.Vector(p1)
    d = b - a
    length = d.length
    if length < 1e-5: return
    res = bmesh.ops.create_cone(bm, cap_ends=True, cap_tris=False, segments=segments, radius1=radius, radius2=radius, depth=length)
    rot = mathutils.Vector((0, 0, 1)).rotation_difference(d.normalized()).to_matrix().to_4x4()
    mid = (a + b) / 2.0
    for v in res['verts']: v.co = (rot @ v.co) + mid

def bolt_ring(bm, pos, radius, count, axis='Y', bolt_r=0.01, bolt_len=0.02):
    for i in range(count):
        a = (i / count) * math.tau
        if axis == 'Y': add_cyl(bm, (pos[0] + math.cos(a)*radius, pos[1], pos[2] + math.sin(a)*radius), bolt_r, bolt_len, 'Y', 6)
        elif axis == 'Z': add_cyl(bm, (pos[0] + math.cos(a)*radius, pos[1] + math.sin(a)*radius, pos[2]), bolt_r, bolt_len, 'Z', 6)
        elif axis == 'X': add_cyl(bm, (pos[0], pos[1] + math.cos(a)*radius, pos[2] + math.sin(a)*radius), bolt_r, bolt_len, 'X', 6)

def fin_stack(bm, y_centre, y_len, x_at, z_lo, z_hi, count, thickness=0.014, depth=0.055):
    for i in range(count):
        t = i / max(1, count - 1)
        z = z_lo + (z_hi - z_lo) * t
        add_box(bm, (x_at, y_centre, z), (depth, y_len, thickness), bevel=0.002)

def add_mechanical_greebles(bm, pos, size):
    # Accumulator bottles
    add_cyl(bm, (pos[0]+size[0]*0.4, pos[1]-size[1]*0.3, pos[2]+size[2]*0.6), 0.04, 0.2, 'Y', 12)
    add_cyl(bm, (pos[0]-size[0]*0.4, pos[1]-size[1]*0.3, pos[2]+size[2]*0.6), 0.04, 0.2, 'Y', 12)
    # Hydraulic rods running forward
    add_tube_between(bm, (pos[0]+size[0]*0.4, pos[1]-size[1]*0.2, pos[2]+size[2]*0.6), (pos[0]+size[0]*0.4, pos[1]+size[1]*0.5, pos[2]+size[2]*0.6), 0.015)
    add_tube_between(bm, (pos[0]-size[0]*0.4, pos[1]-size[1]*0.2, pos[2]+size[2]*0.6), (pos[0]-size[0]*0.4, pos[1]+size[1]*0.5, pos[2]+size[2]*0.6), 0.015)
    # Cooling ribs
    for i in range(4): add_box(bm, (pos[0], pos[1]-size[1]*0.1 + i*0.05, pos[2]-size[2]*0.55), (size[0]*0.8, 0.02, 0.05))
    # Bolted access panel
    add_box(bm, (pos[0], pos[1], pos[2]+size[2]*0.52), (size[0]*0.6, size[1]*0.6, 0.02))
    bolt_ring(bm, (pos[0], pos[1], pos[2]+size[2]*0.53), size[0]*0.25, 8, 'Z')
    # Pressure manifold block
    add_box(bm, (pos[0], pos[1]+size[1]*0.2, pos[2]-size[2]*0.6), (0.1, 0.1, 0.08))
    add_tube_between(bm, (pos[0], pos[1]+size[1]*0.2, pos[2]-size[2]*0.6), (pos[0]+size[0]*0.4, pos[1]-size[1]*0.2, pos[2]+size[2]*0.6), 0.02)
    add_tube_between(bm, (pos[0], pos[1]+size[1]*0.2, pos[2]-size[2]*0.6), (pos[0]-size[0]*0.4, pos[1]-size[1]*0.2, pos[2]+size[2]*0.6), 0.02)

def add_heavy_mount(bm, scale=1.0):
    add_cyl(bm, (0, 0, 0.05*scale), 0.35*scale, 0.1*scale, 'Z', 24)
    bolt_ring(bm, (0, 0, 0.1*scale), 0.3*scale, 16, 'Z', 0.012*scale, 0.03*scale)
    add_box(bm, (0, 0, 0.18*scale), (0.45*scale, 0.35*scale, 0.1*scale), bevel=0.01)
    for side in (-1, 1):
        x = side * 0.22 * scale
        add_box(bm, (x, -0.05*scale, 0.25*scale), (0.1*scale, 0.25*scale, 0.2*scale), bevel=0.01)
        add_box(bm, (x, -0.05*scale, 0.38*scale), (0.08*scale, 0.15*scale, 0.1*scale), bevel=0.008)
        add_cyl(bm, (x, 0, 0.4*scale), 0.09*scale, 0.12*scale, 'X', 18)
        bolt_ring(bm, (x+side*0.06*scale, 0, 0.4*scale), 0.07*scale, 6, 'X')
    add_cyl(bm, (-0.1*scale, -0.15*scale, 0.22*scale), 0.04*scale, 0.08*scale, 'Z', 12)
    add_cyl(bm, (0.1*scale, -0.15*scale, 0.22*scale), 0.04*scale, 0.08*scale, 'Z', 12)
    # Heavy hydraulic slew drives
    add_tube_between(bm, (0, -0.3*scale, 0.1*scale), (0.15*scale, -0.05*scale, 0.15*scale), 0.03*scale)
    add_tube_between(bm, (0, -0.3*scale, 0.1*scale), (-0.15*scale, -0.05*scale, 0.15*scale), 0.03*scale)

# --- REWORKED WEAPONS ---

def build_flamethrower():
    bm = bmesh.new(); add_heavy_mount(bm, 0.8); export_bmesh(bm, "flamethrower_mount", "flamethrower_mount.glb")
    bm = bmesh.new()
    add_cyl(bm, (0, -0.2, 0), 0.18, 0.6, 'Y', 20)
    add_mechanical_greebles(bm, (0,-0.2,0), (0.2, 0.3, 0.2))
    add_box(bm, (0, -0.2, -0.25), (0.35, 0.45, 0.15), bevel=0.01)
    bolt_ring(bm, (0, -0.2, -0.3), 0.1, 8, 'Z')
    add_tube_between(bm, (-0.15, -0.2, -0.25), (-0.15, -0.1, 0), 0.04)
    add_tube_between(bm, (0.15, -0.2, -0.25), (0.15, -0.1, 0), 0.04)
    export_bmesh(bm, "flamethrower_body", "flamethrower_body.glb")
    bm = bmesh.new()
    add_cyl(bm, (0, 0.4, 0), 0.06, 0.8, 'Y', 16)
    add_cyl(bm, (0, 0.85, 0), 0.12, 0.1, 'Y', 16)
    for i in range(3):
        a = (i/3)*math.tau
        add_cyl(bm, (math.cos(a)*0.08, 0.88, math.sin(a)*0.08), 0.02, 0.15, 'Y', 8)
    add_tube_between(bm, (0, 0.1, -0.07), (0, 0.8, -0.12), 0.015) # Pilot gas line
    export_bmesh(bm, "flamethrower_nozzle", "flamethrower_nozzle.glb")

def build_arc_projector():
    bm = bmesh.new(); add_heavy_mount(bm, 1.0); export_bmesh(bm, "arc_projector_mount", "arc_projector_mount.glb")
    bm = bmesh.new()
    add_box(bm, (0, -0.2, 0), (0.35, 0.6, 0.35), bevel=0.015)
    add_mechanical_greebles(bm, (0, -0.2, 0), (0.35, 0.6, 0.35))
    for side in (-1, 1): add_cyl(bm, (side*0.22, -0.2, -0.15), 0.08, 0.5, 'Y', 16)
    export_bmesh(bm, "arc_projector_body", "arc_projector_body.glb")
    bm = bmesh.new()
    add_cyl(bm, (0, 0.5, 0), 0.15, 1.0, 'Y', 8) # Octagonal
    for i in range(3):
        y = 0.2 + i*0.3
        add_cyl(bm, (0, y, 0), 0.18, 0.05, 'Y', 8)
        bolt_ring(bm, (0, y, 0.16), 0.16, 8, 'Y') # Ceramic insulator collars
    for i in range(4):
        a = (i/4)*math.tau + math.pi/4
        add_tube_between(bm, (math.cos(a)*0.16, 0.1, math.sin(a)*0.16), (math.cos(a)*0.16, 0.9, math.sin(a)*0.16), 0.015)
    for i in range(3):
        a = (i/3)*math.tau + math.pi/2
        add_cyl(bm, (math.cos(a)*0.12, 1.0, math.sin(a)*0.12), 0.06, 0.2, 'Y', 12)
        add_cyl(bm, (math.cos(a)*0.12, 1.15, math.sin(a)*0.12), 0.03, 0.2, 'Y', 12)
        add_tube_between(bm, (0, 0.95, 0), (math.cos(a)*0.12, 1.0, math.sin(a)*0.12), 0.02)
    export_bmesh(bm, "arc_projector_emitter", "arc_projector_emitter.glb", color=(0.20,0.22,0.24,1.0))

def build_ion_cannon():
    bm = bmesh.new(); add_heavy_mount(bm, 1.2); export_bmesh(bm, "ion_cannon_mount", "ion_cannon_mount.glb")
    bm = bmesh.new()
    add_box(bm, (0, -0.2, 0), (0.45, 0.6, 0.45), bevel=0.02)
    add_mechanical_greebles(bm, (0, -0.2, 0), (0.45, 0.6, 0.45))
    add_cyl(bm, (0, 0.3, 0), 0.2, 0.4, 'Y', 24)
    bolt_ring(bm, (0, 0.45, 0), 0.18, 12, 'Y')
    fin_stack(bm, -0.2, 0.5, -0.25, -0.15, 0.15, 8, 0.01, 0.08)
    fin_stack(bm, -0.2, 0.5, 0.25, -0.15, 0.15, 8, 0.01, 0.08)
    export_bmesh(bm, "ion_cannon_housing", "ion_cannon_housing.glb")
    bm = bmesh.new()
    add_cyl(bm, (0, 0.6, 0), 0.18, 1.2, 'Y', 24)
    for i in range(3):
        y = 0.3 + i*0.4
        add_cyl(bm, (0, y, 0), 0.24, 0.08, 'Y', 24)
        bolt_ring(bm, (0, y, 0), 0.22, 16, 'Y')
        add_tube_between(bm, (0, y, -0.24), (0, 0.0, -0.24), 0.02)
        add_tube_between(bm, (0.24, y, 0), (0.24, 0.0, 0), 0.02)
        add_tube_between(bm, (-0.24, y, 0), (-0.24, 0.0, 0), 0.02)
    export_bmesh(bm, "ion_cannon_lens", "ion_cannon_lens.glb")

def build_railgun():
    bm = bmesh.new()
    add_box(bm, (0, 0, 0.1), (0.6, 0.7, 0.2), bevel=0.02)
    add_box(bm, (0, -0.05, 0.25), (0.5, 0.6, 0.15), bevel=0.015)
    bolt_ring(bm, (0, 0, 0.35), 0.2, 12, 'Z', 0.015, 0.04)
    add_cyl(bm, (-0.2, 0, 0.35), 0.08, 0.12, 'X', 16)
    add_cyl(bm, (0.2, 0, 0.35), 0.08, 0.12, 'X', 16)
    export_bmesh(bm, "railgun_casemate_mount", "railgun_casemate_mount.glb")
    
    bm = bmesh.new()
    add_box(bm, (0, -0.2, 0), (0.35, 0.6, 0.3), bevel=0.015)
    add_mechanical_greebles(bm, (0, -0.2, 0), (0.35, 0.6, 0.3))
    for i in range(4):
        y = -0.05 - i*0.1
        add_box(bm, (0, y, 0), (0.38, 0.04, 0.32), bevel=0.005)
    add_cyl(bm, (-0.22, -0.2, -0.1), 0.05, 0.5, 'Y', 12)
    add_cyl(bm, (0.22, -0.2, -0.1), 0.05, 0.5, 'Y', 12)
    export_bmesh(bm, "railgun_capacitor_housing", "railgun_capacitor_housing.glb")
    
    bm = bmesh.new()
    add_cyl(bm, (0, 0.7, 0), 0.04, 1.4, 'Y', 16)
    add_box(bm, (0, 0.7, 0.12), (0.08, 1.4, 0.06), bevel=0.01)
    add_box(bm, (0, 0.7, -0.12), (0.08, 1.4, 0.06), bevel=0.01)
    for i in range(7):
        y = 0.2 + i*0.2
        add_box(bm, (0, y, 0), (0.12, 0.05, 0.35), bevel=0.01)
        bolt_ring(bm, (0, y, 0.15), 0.03, 4, 'Y', 0.005, 0.06)
        bolt_ring(bm, (0, y, -0.15), 0.03, 4, 'Y', 0.005, 0.06)
        add_box(bm, (0.1, y, 0), (0.02, 0.1, 0.1))
        add_box(bm, (-0.1, y, 0), (0.02, 0.1, 0.1))
        # Add thick copper busbars between insulators
        if i < 6:
            add_tube_between(bm, (0.12, y, 0), (0.12, y+0.2, 0), 0.015)
            add_tube_between(bm, (-0.12, y, 0), (-0.12, y+0.2, 0), 0.015)
    export_bmesh(bm, "railgun_rails", "railgun_rails.glb", color=(0.15,0.15,0.16,1.0))

def build_guided_missile():
    bm = bmesh.new(); add_heavy_mount(bm, 0.6); export_bmesh(bm, "tow_pintle_mount", "tow_pintle_mount.glb")
    bm = bmesh.new()
    add_cyl(bm, (0, 0.4, 0), 0.12, 0.9, 'Y', 16)
    add_box(bm, (-0.2, 0.1, 0.0), (0.15, 0.35, 0.25), bevel=0.01)
    add_cyl(bm, (-0.2, 0.28, 0.05), 0.05, 0.05, 'Y', 12)
    bolt_ring(bm, (-0.2, 0.28, 0.05), 0.04, 8, 'Y')
    for y in [0.0, 0.4, 0.8]:
        add_cyl(bm, (0, y, 0), 0.13, 0.05, 'Y', 16)
        bolt_ring(bm, (0, y, 0), 0.14, 8, 'Y', 0.006, 0.04)
        add_tube_between(bm, (0, y, -0.13), (0, 0.8, -0.13), 0.01) # Sensor lines
    add_cyl(bm, (0, -0.05, 0), 0.15, 0.1, 'Y', 16)
    export_bmesh(bm, "tow_launch_tube", "tow_launch_tube.glb")
    bm = bmesh.new()
    add_cyl(bm, (0, 0.4, 0), 0.08, 0.6, 'Y', 16)
    res = bmesh.ops.create_cone(bm, cap_ends=True, cap_tris=False, segments=16, radius1=0.08, radius2=0.02, depth=0.3)
    rot = mathutils.Matrix.Rotation(math.radians(90), 4, 'X')
    loc = mathutils.Vector((0, 0.85, 0))
    for v in res['verts']: v.co = rot @ v.co + loc
    add_cyl(bm, (0, 1.1, 0), 0.01, 0.2, 'Y', 8)
    add_box(bm, (0, 0.4, -0.08), (0.02, 0.5, 0.02))
    export_bmesh(bm, "tow_missile_warhead", "tow_missile_warhead.glb")

def build_missile_pod():
    bm = bmesh.new(); add_heavy_mount(bm, 0.8); export_bmesh(bm, "missile_pod_pintle_mount", "missile_pod_pintle_mount.glb")
    bm = bmesh.new()
    add_cyl(bm, (0, 0.3, 0), 0.35, 1.0, 'Y', 24)
    add_mechanical_greebles(bm, (0, 0.3, 0), (0.35, 1.0, 0.35))
    res = bmesh.ops.create_cone(bm, cap_ends=True, cap_tris=False, segments=24, radius1=0.35, radius2=0.1, depth=0.3)
    rot = mathutils.Matrix.Rotation(math.radians(90), 4, 'X')
    loc = mathutils.Vector((0, -0.35, 0))
    for v in res['verts']: v.co = rot @ v.co + loc
    bolt_ring(bm, (0, -0.2, 0), 0.34, 16, 'Y')
    bolt_ring(bm, (0, 0.8, 0), 0.34, 16, 'Y')
    export_bmesh(bm, "missile_pod_housing", "missile_pod_housing.glb")
    bm = bmesh.new()
    for q in range(19):
        if q == 0: x, y_off, z = 0, 0, 0
        elif q < 7: 
            a = ((q-1)/6) * math.tau
            x, y_off, z = math.cos(a)*0.12, 0, math.sin(a)*0.12
        else:
            a = ((q-7)/12) * math.tau
            x, y_off, z = math.cos(a)*0.24, 0, math.sin(a)*0.24
        res = bmesh.ops.create_cone(bm, cap_ends=True, cap_tris=False, segments=12, radius1=0.04, radius2=0.01, depth=0.15)
        rot = mathutils.Matrix.Rotation(math.radians(90), 4, 'X')
        loc = mathutils.Vector((x, 0.75, z))
        for v in res['verts']: v.co = rot @ v.co + loc
        add_cyl(bm, (x, 0.6, z), 0.04, 0.15, 'Y', 12)
    export_bmesh(bm, "missile_pod_missile", "missile_pod_missile.glb")

def build_sam_launcher():
    bm = bmesh.new()
    add_box(bm, (0, 0, 0.2), (0.6, 0.8, 0.4), bevel=0.02)
    add_mechanical_greebles(bm, (0, 0, 0.2), (0.6, 0.8, 0.4))
    add_cyl(bm, (0, -0.3, 0.5), 0.08, 0.2, 'Z', 16)
    add_box(bm, (0, -0.3, 0.6), (0.4, 0.1, 0.4), bevel=0.02)
    export_bmesh(bm, "sam_body", "sam_body.glb")
    bm = bmesh.new()
    for ix in [-0.2, 0.2]:
        for iz in [0.2, 0.5]:
            add_cyl(bm, (ix, 0.5, iz), 0.08, 1.0, 'Y', 16)
            res = bmesh.ops.create_cone(bm, cap_ends=True, cap_tris=False, segments=16, radius1=0.08, radius2=0.0, depth=0.3)
            rot = mathutils.Matrix.Rotation(math.radians(90), 4, 'X')
            loc = mathutils.Vector((ix, 1.15, iz))
            for v in res['verts']: v.co = rot @ v.co + loc
            for i in range(4):
                a = (i/4)*math.tau
                add_box(bm, (ix + math.cos(a)*0.1, 0.9, iz + math.sin(a)*0.1), (0.02, 0.15, 0.1))
            for i in range(4):
                a = (i/4)*math.tau + math.pi/4
                add_box(bm, (ix + math.cos(a)*0.15, 0.1, iz + math.sin(a)*0.15), (0.02, 0.3, 0.2))
    export_bmesh(bm, "sam_missile", "sam_missile.glb")

def build_cruise_missile():
    bm = bmesh.new()
    add_box(bm, (0, 0, 0.15), (0.8, 1.0, 0.3), bevel=0.02)
    add_mechanical_greebles(bm, (0, 0, 0.15), (0.8, 1.0, 0.3))
    add_box(bm, (0, -0.5, 0.15), (0.6, 0.2, 0.2))
    bolt_ring(bm, (0, -0.5, 0.15), 0.3, 12, 'Z')
    export_bmesh(bm, "cruise_body", "cruise_body.glb")
    bm = bmesh.new()
    add_box(bm, (0, 0.6, 0), (0.45, 1.4, 0.45), bevel=0.015)
    for y in [-0.0, 0.3, 0.6, 0.9, 1.2]:
        add_box(bm, (0, y, 0), (0.48, 0.05, 0.48), bevel=0.005)
        bolt_ring(bm, (0, y, 0.24), 0.2, 8, 'Z')
    add_box(bm, (0, 1.32, 0), (0.44, 0.04, 0.44))
    add_cyl(bm, (0.24, 1.32, 0), 0.04, 0.1, 'Z', 12)
    add_box(bm, (0, -0.15, 0), (0.4, 0.1, 0.4))
    export_bmesh(bm, "cruise_container", "cruise_container.glb")

# And basic calls for the rest, elevated with mechanical greebles
def build_heavy_laser():
    bm = bmesh.new(); add_heavy_mount(bm, 1.2); export_bmesh(bm, "heavy_laser_mount", "heavy_laser_mount.glb")
    bm = bmesh.new(); add_box(bm, (0, -0.3, 0), (0.4, 0.8, 0.35), bevel=0.02); add_mechanical_greebles(bm, (0, -0.3, 0), (0.4, 0.8, 0.35)); export_bmesh(bm, "heavy_laser_housing", "heavy_laser_housing.glb")
    bm = bmesh.new(); add_box(bm, (0, 0.6, 0), (0.2, 0.8, 0.2), bevel=0.015); add_mechanical_greebles(bm, (0, 0.6, 0), (0.2, 0.8, 0.2)); export_bmesh(bm, "heavy_laser_lens", "heavy_laser_lens.glb")

def build_pd_laser():
    bm = bmesh.new(); add_heavy_mount(bm, 0.7); export_bmesh(bm, "pd_laser_mount", "pd_laser_mount.glb")
    bm = bmesh.new(); add_box(bm, (0, -0.2, 0), (0.25, 0.5, 0.2), bevel=0.01); add_mechanical_greebles(bm, (0, -0.2, 0), (0.25, 0.5, 0.2)); export_bmesh(bm, "pd_laser_housing", "pd_laser_housing.glb")
    bm = bmesh.new(); add_box(bm, (0, 0.2, 0), (0.18, 0.3, 0.12), bevel=0.01); add_mechanical_greebles(bm, (0, 0.2, 0), (0.18, 0.3, 0.12)); export_bmesh(bm, "pd_laser_lens", "pd_laser_lens.glb")

def build_coilgun():
    bm = bmesh.new(); add_heavy_mount(bm, 1.0); export_bmesh(bm, "coilgun_mount", "coilgun_mount.glb")
    bm = bmesh.new(); add_box(bm, (0, -0.15, 0), (0.25, 0.5, 0.25), bevel=0.01); add_mechanical_greebles(bm, (0, -0.15, 0), (0.25, 0.5, 0.25)); export_bmesh(bm, "coilgun_breech", "coilgun_breech.glb")
    bm = bmesh.new(); add_box(bm, (0, 0.6, 0), (0.1, 1.2, 0.1), bevel=0.01); add_mechanical_greebles(bm, (0, 0.6, 0), (0.1, 1.2, 0.1)); export_bmesh(bm, "coilgun_rail", "coilgun_rail.glb")
    bm = bmesh.new(); add_cyl(bm, (0, 0, 0), 0.15, 0.08, 'Y', 24); export_bmesh(bm, "coilgun_coil", "coilgun_coil.glb")
    bm = bmesh.new(); add_box(bm, (0, -0.1, -0.2), (0.3, 0.4, 0.15), bevel=0.01); add_mechanical_greebles(bm, (0, -0.1, -0.2), (0.3, 0.4, 0.15)); export_bmesh(bm, "coilgun_capacitors", "coilgun_capacitors.glb")

def build_bunker_buster():
    bm = bmesh.new(); add_box(bm, (0, 0, 0.15), (0.45, 0.7, 0.3), bevel=0.02); add_mechanical_greebles(bm, (0, 0, 0.15), (0.45, 0.7, 0.3)); export_bmesh(bm, "bb_body", "bb_body.glb")
    bm = bmesh.new(); add_cyl(bm, (0, 0.6, 0), 0.18, 1.2, 'Y', 20); export_bmesh(bm, "bb_penetrator", "bb_penetrator.glb")
    bm = bmesh.new(); add_heavy_mount(bm, 1.0); export_bmesh(bm, "missile_pedestal", "missile_pedestal.glb")

def build_hypervelocity_missile():
    bm = bmesh.new(); add_box(bm, (0, 0, 0.1), (0.35, 0.6, 0.25), bevel=0.015); add_mechanical_greebles(bm, (0, 0, 0.1), (0.35, 0.6, 0.25)); export_bmesh(bm, "hvm_body", "hvm_body.glb")
    bm = bmesh.new(); add_box(bm, (0, 0.5, 0), (0.25, 1.0, 0.25), bevel=0.01); add_mechanical_greebles(bm, (0, 0.5, 0), (0.25, 1.0, 0.25)); export_bmesh(bm, "hvm_canister", "hvm_canister.glb")

def build_cluster_dispenser():
    bm = bmesh.new(); add_heavy_mount(bm, 1.0); export_bmesh(bm, "cluster_dispenser_mount", "cluster_dispenser_mount.glb")
    bm = bmesh.new(); add_box(bm, (0, 0.1, 0), (0.55, 0.5, 0.45), bevel=0.02); add_mechanical_greebles(bm, (0, 0.1, 0), (0.55, 0.5, 0.45)); export_bmesh(bm, "cluster_dispenser_housing", "cluster_dispenser_housing.glb")

def build_ciws():
    bm = bmesh.new(); add_heavy_mount(bm, 0.9); export_bmesh(bm, "ciws_mount", "ciws_mount.glb")
    bm = bmesh.new(); add_cyl(bm, (0, -0.2, 0.4), 0.3, 0.25, 'Z', 24); add_mechanical_greebles(bm, (0, -0.2, 0.2), (0.4, 0.3, 0.2)); export_bmesh(bm, "ciws_radar", "ciws_radar.glb")
    bm = bmesh.new(); add_cyl(bm, (0, 0.5, 0), 0.04, 1.0, 'Y', 12); add_mechanical_greebles(bm, (0, 0.5, 0), (0.1, 1.0, 0.1)); export_bmesh(bm, "ciws_barrel", "ciws_barrel.glb")

if __name__ == '__main__':
    clear_scene()
    build_flamethrower()
    build_arc_projector()
    build_ion_cannon()
    build_railgun()
    build_guided_missile()
    build_missile_pod()
    build_sam_launcher()
    build_cruise_missile()
    build_heavy_laser()
    build_pd_laser()
    build_coilgun()
    build_bunker_buster()
    build_hypervelocity_missile()
    build_cluster_dispenser()
    build_ciws()
