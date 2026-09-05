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

def add_cone_forward(bm, pos, radius_base, radius_tip, height, segments=16):
    """Creates a cone along Y pointing forward (+Y). Base at -height/2, tip at +height/2."""
    res = bmesh.ops.create_cone(bm, cap_ends=True, cap_tris=False, segments=segments, radius1=radius_base, radius2=radius_tip, depth=height)
    rot = mathutils.Matrix.Rotation(math.radians(-90), 4, 'X')
    loc = mathutils.Vector(pos)
    for v in res['verts']: v.co = rot @ v.co + loc

def add_cone_z(bm, pos, radius_base, radius_tip, height, segments=16):
    """Creates a cone along Z. Base at -height/2, tip at +height/2."""
    res = bmesh.ops.create_cone(bm, cap_ends=True, cap_tris=False, segments=segments, radius1=radius_base, radius2=radius_tip, depth=height)
    loc = mathutils.Vector(pos)
    for v in res['verts']: v.co = v.co + loc

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
    add_tube_between(bm, (0, 0.1, -0.07), (0, 0.8, -0.12), 0.015)
    export_bmesh(bm, "flamethrower_nozzle", "flamethrower_nozzle.glb")

def build_arc_projector():
    bm = bmesh.new(); add_heavy_mount(bm, 1.0); export_bmesh(bm, "arc_projector_mount", "arc_projector_mount.glb")
    bm = bmesh.new()
    add_box(bm, (0, -0.2, 0), (0.35, 0.6, 0.35), bevel=0.015)
    add_mechanical_greebles(bm, (0, -0.2, 0), (0.35, 0.6, 0.35))
    for side in (-1, 1): add_cyl(bm, (side*0.22, -0.2, -0.15), 0.08, 0.5, 'Y', 16)
    export_bmesh(bm, "arc_projector_body", "arc_projector_body.glb")
    bm = bmesh.new()
    add_cyl(bm, (0, 0.5, 0), 0.15, 1.0, 'Y', 8)
    for i in range(3):
        y = 0.2 + i*0.3
        add_cyl(bm, (0, y, 0), 0.18, 0.05, 'Y', 8)
        bolt_ring(bm, (0, y, 0.16), 0.16, 8, 'Y')
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
    # Accelerator barrel extending forward to Y = +0.60
    add_cyl(bm, (0, 0.35, 0), 0.20, 0.50, 'Y', 24)
    add_cyl(bm, (0, 0.25, 0), 0.23, 0.06, 'Y', 24)
    add_cyl(bm, (0, 0.45, 0), 0.23, 0.06, 'Y', 24)
    add_cyl(bm, (0, 0.58, 0), 0.22, 0.04, 'Y', 24)
    bolt_ring(bm, (0, 0.58, 0), 0.20, 16, 'Y')
    fin_stack(bm, -0.2, 0.5, -0.25, -0.15, 0.15, 8, 0.01, 0.08)
    fin_stack(bm, -0.2, 0.5, 0.25, -0.15, 0.15, 8, 0.01, 0.08)
    export_bmesh(bm, "ion_cannon_housing", "ion_cannon_housing.glb", color=(0.20, 0.24, 0.30, 1.0))
    bm = bmesh.new()
    # Focusing lens origin at front barrel interface Y=0.0 connecting flush
    add_cyl(bm, (0, 0.15, 0), 0.20, 0.30, 'Y', 24)
    for angle in (0, 90, 180, 270):
        rad = math.radians(angle)
        cx = math.cos(rad) * 0.18
        cz = math.sin(rad) * 0.18
        add_box(bm, (cx, 0.15, cz), (0.05, 0.22, 0.05), bevel=0.005)
        add_tube_between(bm, (cx, 0.04, cz), (cx, 0.26, cz), 0.015)
    add_cone_forward(bm, (0, 0.33, 0), radius_base=0.18, radius_tip=0.22, height=0.06, segments=24)
    add_cyl(bm, (0, 0.35, 0), 0.14, 0.02, 'Y', 24)
    export_bmesh(bm, "ion_cannon_lens", "ion_cannon_lens.glb", color=(0.25, 0.60, 0.85, 1.0))

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
        if i < 6:
            add_tube_between(bm, (0.12, y, 0), (0.12, y+0.2, 0), 0.015)
            add_tube_between(bm, (-0.12, y, 0), (-0.12, y+0.2, 0), 0.015)
    export_bmesh(bm, "railgun_rails", "railgun_rails.glb", color=(0.15,0.15,0.16,1.0))

def build_guided_missile():
    bm = bmesh.new(); add_heavy_mount(bm, 0.6); export_bmesh(bm, "tow_pintle_mount", "tow_pintle_mount.glb")
    bm = bmesh.new()
    # Centered at (0, 0, 0) so trunnion mounts at the midway point: Y from -0.60 to +0.60
    add_cyl(bm, (0, 0.0, 0), 0.11, 1.20, 'Y', 20)
    # Central trunnion mounting collar
    add_box(bm, (0, 0.0, 0), (0.26, 0.12, 0.26), bevel=0.01)
    bolt_ring(bm, (0, 0.0, 0.14), 0.08, 6, 'Z', 0.008, 0.02)
    # Front and rear shock absorber collars
    add_cyl(bm, (0, 0.55, 0), 0.13, 0.10, 'Y', 20)
    bolt_ring(bm, (0, 0.55, 0), 0.135, 8, 'Y', 0.006, 0.02)
    add_cyl(bm, (0, -0.55, 0), 0.13, 0.10, 'Y', 20)
    bolt_ring(bm, (0, -0.55, 0), 0.135, 8, 'Y', 0.006, 0.02)
    # Guidance optic sight on left side
    add_box(bm, (-0.18, 0.0, 0.05), (0.12, 0.28, 0.20), bevel=0.01)
    add_cyl(bm, (-0.18, 0.14, 0.09), 0.035, 0.03, 'Y', 12)
    add_cyl(bm, (-0.18, 0.14, 0.01), 0.025, 0.03, 'Y', 12)
    # Conduit line along bottom of tube
    add_tube_between(bm, (0, -0.55, -0.12), (0, 0.55, -0.12), 0.012)
    export_bmesh(bm, "tow_launch_tube", "tow_launch_tube.glb", color=(0.24, 0.26, 0.22, 1.0))
    bm = bmesh.new()
    # Missile warhead origin at front opening Y=0.0, extending forward
    add_cyl(bm, (0, 0.08, 0), 0.075, 0.16, 'Y', 16)
    add_cone_forward(bm, (0, 0.22, 0), radius_base=0.075, radius_tip=0.02, height=0.12, segments=16)
    add_cyl(bm, (0, 0.33, 0), 0.01, 0.10, 'Y', 8)
    for i in range(4):
        a = (i / 4.0) * math.tau
        add_box(bm, (math.cos(a) * 0.09, 0.06, math.sin(a) * 0.09), (0.008, 0.12, 0.05))
    export_bmesh(bm, "tow_missile_warhead", "tow_missile_warhead.glb", color=(0.85, 0.85, 0.85, 1.0))

def build_missile_pod():
    bm = bmesh.new(); add_heavy_mount(bm, 0.8); export_bmesh(bm, "missile_pod_pintle_mount", "missile_pod_pintle_mount.glb")
    
    bm = bmesh.new()
    # Main pod housing octagonal shell (centered at Z=0 trunnion axis, Y from -0.375 to +0.375)
    add_cyl(bm, (0, 0.0, 0), 0.28, 0.75, 'Y', 8)
    # Side trunnion pivot lugs at Z=0
    add_cyl(bm, (-0.28, 0.0, 0), 0.06, 0.10, 'X', 16)
    add_cyl(bm, (0.28, 0.0, 0), 0.06, 0.10, 'X', 16)
    # Rear exhaust boat-tail cone: attaches at Y=-0.375, tapers backward to Y=-0.46
    # add_cone_forward: base (-Y) is 0.22, tip (+Y) is 0.28, so it points backward!
    add_cone_forward(bm, (0, -0.42, 0), radius_base=0.22, radius_tip=0.28, height=0.09, segments=8)
    add_cyl(bm, (0, -0.47, 0), 0.23, 0.02, 'Y', 8)
    # Front face plate cowl & aperture ring at Y=+0.36
    add_cyl(bm, (0, 0.36, 0), 0.29, 0.04, 'Y', 8)
    bolt_ring(bm, (0, 0.37, 0), 0.26, 12, 'Y', 0.008, 0.02)
    # Umbilical raceway on top (+Z)
    add_box(bm, (0, 0.0, 0.28), (0.10, 0.65, 0.03), bevel=0.005)
    export_bmesh(bm, "missile_pod_housing", "missile_pod_housing.glb", color=(0.28, 0.30, 0.26, 1.0))
    
    bm = bmesh.new()
    # Individual rocket with origin at front tube aperture Y=0.0
    # Rocket nose cone points forward (+Y) slightly out the front of the aperture
    add_cone_forward(bm, (0, 0.05, 0), radius_base=0.040, radius_tip=0.005, height=0.10, segments=16)
    add_cyl(bm, (0, 0.11, 0), 0.010, 0.02, 'Y', 8)
    # Rocket motor body extends backward (-Y) inside the tube from 0.0 to -0.40
    add_cyl(bm, (0, -0.20, 0), 0.040, 0.40, 'Y', 16)
    add_cyl(bm, (0, -0.41, 0), 0.036, 0.02, 'Y', 12)
    for i in range(4):
        a = (i / 4.0) * math.tau
        add_box(bm, (math.cos(a) * 0.044, -0.36, math.sin(a) * 0.044), (0.006, 0.07, 0.015))
    export_bmesh(bm, "missile_pod_missile", "missile_pod_missile.glb", color=(0.42, 0.44, 0.40, 1.0))

def build_sam_launcher():
    bm = bmesh.new()
    add_box(bm, (0, 0, 0.12), (0.50, 0.65, 0.25), bevel=0.02)
    for side in (-1, 1):
        add_box(bm, (side * 0.22, 0.0, 0.30), (0.08, 0.40, 0.20), bevel=0.01)
        add_cyl(bm, (side * 0.22, 0.0, 0.35), 0.07, 0.12, 'X', 16)
    add_tube_between(bm, (-0.15, -0.25, 0.15), (-0.15, 0.05, 0.32), 0.025)
    add_tube_between(bm, (0.15, -0.25, 0.15), (0.15, 0.05, 0.32), 0.025)
    add_box(bm, (0, -0.32, 0.40), (0.28, 0.08, 0.28), bevel=0.015)
    bolt_ring(bm, (0, -0.33, 0.40), 0.10, 8, 'Y', 0.006, 0.015)
    add_cyl(bm, (0, -0.32, 0.25), 0.05, 0.15, 'Z', 12)
    export_bmesh(bm, "sam_body", "sam_body.glb")
    
    bm = bmesh.new()
    add_cyl(bm, (0, 0.30, 0), 0.045, 0.75, 'Y', 16)
    add_cone_forward(bm, (0, 0.82, 0), radius_base=0.045, radius_tip=0.003, height=0.30, segments=16)
    add_cyl(bm, (0, 0.98, 0), 0.005, 0.05, 'Y', 8)
    for i in range(4):
        a = (i / 4.0) * math.tau
        cx = math.cos(a) * 0.075
        cz = math.sin(a) * 0.075
        add_box(bm, (cx, 0.65, cz), (0.006, 0.10, 0.06), bevel=0.001)
    add_cyl(bm, (0, -0.15, 0), 0.048, 0.20, 'Y', 16)
    add_cyl(bm, (0, -0.27, 0), 0.038, 0.05, 'Y', 16)
    for i in range(4):
        a = (i / 4.0) * math.tau + (math.pi / 4.0)
        rot = mathutils.Matrix.Rotation(a, 4, 'Y')
        v1 = rot @ mathutils.Vector((0.004, 0.05, 0.045))
        v2 = rot @ mathutils.Vector((-0.004, 0.05, 0.045))
        v3 = rot @ mathutils.Vector((-0.004, -0.22, 0.045))
        v4 = rot @ mathutils.Vector((0.004, -0.22, 0.045))
        v5 = rot @ mathutils.Vector((0.003, -0.10, 0.175))
        v6 = rot @ mathutils.Vector((-0.003, -0.10, 0.175))
        v7 = rot @ mathutils.Vector((-0.003, -0.22, 0.175))
        v8 = rot @ mathutils.Vector((0.003, -0.22, 0.175))
        for face_indices in [
            [v1, v2, v3, v4], [v5, v6, v7, v8],
            [v1, v2, v6, v5], [v3, v4, v8, v7],
            [v1, v4, v8, v5], [v2, v3, v7, v6]
        ]:
            bm_verts = [bm.verts.new(pt) for pt in face_indices]
            try: bm.faces.new(bm_verts)
            except: pass
    export_bmesh(bm, "sam_missile", "sam_missile.glb", color=(0.82, 0.82, 0.78, 1.0))

def build_hypervelocity_missile():
    bm = bmesh.new()
    add_box(bm, (0, 0, 0.10), (0.46, 0.55, 0.20), bevel=0.015)
    for side in (-1, 1):
        add_box(bm, (side * 0.22, 0.0, 0.22), (0.06, 0.35, 0.18), bevel=0.01)
        add_cyl(bm, (side * 0.22, 0.0, 0.26), 0.05, 0.08, 'X', 16)
    add_tube_between(bm, (-0.14, -0.18, 0.08), (-0.14, 0.08, 0.24), 0.02)
    add_tube_between(bm, (0.14, -0.18, 0.08), (0.14, 0.08, 0.24), 0.02)
    add_box(bm, (0, -0.22, 0.18), (0.22, 0.12, 0.08))
    export_bmesh(bm, "hvm_body", "hvm_body.glb")
    
    bm = bmesh.new()
    add_cyl(bm, (0, 0.40, 0), 0.105, 0.95, 'Y', 8)
    for i in range(4):
        a = (i / 4.0) * math.tau + (math.pi / 4.0)
        rx = math.cos(a) * 0.115
        rz = math.sin(a) * 0.115
        add_box(bm, (rx, 0.40, rz), (0.015, 0.90, 0.02))
    for y in [0.05, 0.40, 0.75]:
        add_cyl(bm, (0, y, 0), 0.12, 0.05, 'Y', 8)
        bolt_ring(bm, (0, y, 0), 0.115, 8, 'Y', 0.005, 0.02)
        add_box(bm, (0.13, y, 0), (0.03, 0.04, 0.04))
        add_box(bm, (-0.13, y, 0), (0.03, 0.04, 0.04))
    add_cone_forward(bm, (0, 0.90, 0), radius_base=0.108, radius_tip=0.08, height=0.06, segments=8)
    bolt_ring(bm, (0, 0.89, 0), 0.105, 12, 'Y', 0.005, 0.015)
    add_cyl(bm, (0, 0.93, 0), 0.04, 0.02, 'Y', 12)
    add_cyl(bm, (0, -0.10, 0), 0.115, 0.06, 'Y', 8)
    add_cone_forward(bm, (0, -0.14, 0), 0.11, 0.07, 0.04, 8)
    add_box(bm, (0, 0.15, 0.12), (0.06, 0.20, 0.04), bevel=0.005)
    add_tube_between(bm, (0, 0.25, 0.12), (0, 0.70, 0.12), 0.01)
    export_bmesh(bm, "hvm_canister", "hvm_canister.glb", color=(0.28, 0.30, 0.26, 1.0))

def build_bunker_buster():
    bm = bmesh.new()
    add_heavy_mount(bm, 1.1)
    export_bmesh(bm, "missile_pedestal", "missile_pedestal.glb")
    
    bm = bmesh.new()
    add_box(bm, (0, 0, 0.15), (0.55, 0.80, 0.28), bevel=0.025)
    add_mechanical_greebles(bm, (0, 0, 0.15), (0.55, 0.80, 0.28))
    for side in (-1, 1):
        add_box(bm, (side * 0.28, -0.05, 0.35), (0.10, 0.45, 0.25), bevel=0.015)
        add_cyl(bm, (side * 0.28, -0.05, 0.42), 0.10, 0.14, 'X', 18)
        bolt_ring(bm, (side * (0.28 + 0.07), -0.05, 0.42), 0.08, 8, 'X')
    add_tube_between(bm, (-0.18, -0.30, 0.15), (-0.18, 0.10, 0.38), 0.035)
    add_tube_between(bm, (0.18, -0.30, 0.15), (0.18, 0.10, 0.38), 0.035)
    add_box(bm, (0, -0.42, 0.20), (0.42, 0.25, 0.18), bevel=0.02)
    export_bmesh(bm, "bb_body", "bb_body.glb")
    
    bm = bmesh.new()
    add_cyl(bm, (0, 0.50, 0), 0.15, 0.90, 'Y', 24)
    add_cyl(bm, (0, 0.98, 0), 0.142, 0.08, 'Y', 24)
    add_cyl(bm, (0, 1.04, 0), 0.130, 0.06, 'Y', 24)
    add_cone_forward(bm, (0, 1.19, 0), radius_base=0.130, radius_tip=0.035, height=0.24, segments=24)
    add_cone_forward(bm, (0, 1.34, 0), radius_base=0.035, radius_tip=0.005, height=0.08, segments=16)
    add_box(bm, (0, 0.50, 0.155), (0.03, 0.85, 0.015))
    add_box(bm, (0, 0.50, -0.155), (0.03, 0.85, 0.015))
    add_box(bm, (0.155, 0.55, 0), (0.02, 0.12, 0.04))
    add_box(bm, (-0.155, 0.55, 0), (0.02, 0.12, 0.04))
    add_cyl(bm, (0, 0.0, 0), 0.158, 0.18, 'Y', 24)
    bolt_ring(bm, (0, 0.06, 0), 0.15, 16, 'Y', 0.007, 0.02)
    add_cone_forward(bm, (0, -0.14, 0), radius_base=0.14, radius_tip=0.09, height=0.12, segments=20)
    add_cyl(bm, (0, -0.21, 0), 0.09, 0.04, 'Y', 20)
    for i in range(4):
        a = (i / 4.0) * math.tau + (math.pi / 4.0)
        gx = math.cos(a) * 0.22
        gz = math.sin(a) * 0.22
        add_tube_between(bm, (math.cos(a)*0.14, -0.05, math.sin(a)*0.14), (gx, -0.05, gz), 0.015)
        add_box(bm, (gx, -0.05, gz), (0.02, 0.14, 0.12), bevel=0.002)
        for ly in [-0.08, -0.05, -0.02]:
            add_box(bm, (gx, ly, gz), (0.015, 0.008, 0.11))
    export_bmesh(bm, "bb_penetrator", "bb_penetrator.glb", color=(0.18, 0.19, 0.20, 1.0), metallic=0.55, roughness=0.58)

def build_cruise_missile():
    bm = bmesh.new()
    add_box(bm, (0, 0, 0.12), (0.60, 0.90, 0.22), bevel=0.02)
    add_mechanical_greebles(bm, (0, 0, 0.12), (0.60, 0.90, 0.22))
    add_box(bm, (-0.16, 0.25, 0.25), (0.04, 1.20, 0.06), bevel=0.005)
    add_box(bm, (0.16, 0.25, 0.25), (0.04, 1.20, 0.06), bevel=0.005)
    add_tube_between(bm, (0, -0.30, 0.12), (0, 0.10, 0.26), 0.035)
    add_box(bm, (0, -0.45, 0.18), (0.45, 0.22, 0.15), bevel=0.01)
    export_bmesh(bm, "cruise_body", "cruise_body.glb")
    
    bm = bmesh.new()
    add_box(bm, (0, 0.45, 0), (0.18, 0.85, 0.15), bevel=0.025)
    add_cyl(bm, (0, 0.45, 0), 0.09, 0.85, 'Y', 16)
    add_cone_forward(bm, (0, 0.96, 0), radius_base=0.088, radius_tip=0.035, height=0.22, segments=16)
    add_box(bm, (0, 1.02, -0.04), (0.045, 0.08, 0.04), bevel=0.005)
    add_cone_forward(bm, (0, 1.09, 0), radius_base=0.035, radius_tip=0.005, height=0.06, segments=16)
    
    for side in (-1, 1):
        wx = side * 0.105
        add_cyl(bm, (wx, 0.68, 0.02), 0.022, 0.03, 'Z', 12)
        bolt_ring(bm, (wx, 0.68, 0.02), 0.016, 6, 'Z', 0.003, 0.01)
        add_box(bm, (wx, 0.35, 0.02), (0.014, 0.60, 0.07), bevel=0.002)
        add_tube_between(bm, (wx, 0.05, 0.04), (wx, 0.65, 0.04), 0.006)
    
    add_box(bm, (0, 0.35, -0.09), (0.07, 0.28, 0.04), bevel=0.005)
    add_cone_forward(bm, (0, 0.50, -0.09), radius_base=0.04, radius_tip=0.03, height=0.05, segments=12)
    add_cone_forward(bm, (0, -0.04, 0), radius_base=0.088, radius_tip=0.065, height=0.18, segments=16)
    bolt_ring(bm, (0, -0.06, 0), 0.075, 12, 'Y', 0.005, 0.015)
    add_cone_forward(bm, (0, -0.17, 0), radius_base=0.062, radius_tip=0.042, height=0.10, segments=16)
    for i in range(4):
        a = (i / 4.0) * math.tau
        tx = math.cos(a) * 0.075
        tz = math.sin(a) * 0.075
        add_box(bm, (tx, -0.08, tz), (0.006, 0.16, 0.06), bevel=0.001)
    
    export_bmesh(bm, "cruise_container", "cruise_container.glb", color=(0.70, 0.72, 0.68, 1.0), metallic=0.35, roughness=0.65)

def build_heavy_laser():
    bm = bmesh.new(); add_heavy_mount(bm, 1.2); export_bmesh(bm, "heavy_laser_mount", "heavy_laser_mount.glb")
    bm = bmesh.new()
    # Resonator housing body centered behind trunnion (Y from -0.70 to +0.10)
    add_box(bm, (0, -0.30, 0), (0.40, 0.80, 0.35), bevel=0.02)
    add_mechanical_greebles(bm, (0, -0.30, 0), (0.40, 0.80, 0.35))
    # Front interface collar at Y = +0.10
    add_cyl(bm, (0, 0.10, 0), 0.14, 0.04, 'Y', 20)
    bolt_ring(bm, (0, 0.10, 0), 0.12, 8, 'Y', 0.008, 0.02)
    fin_stack(bm, -0.30, 0.60, -0.22, -0.10, 0.10, 6, 0.012, 0.05)
    fin_stack(bm, -0.30, 0.60, 0.22, -0.10, 0.10, 6, 0.012, 0.05)
    export_bmesh(bm, "heavy_laser_housing", "heavy_laser_housing.glb", color=(0.24, 0.28, 0.32, 1.0))
    
    bm = bmesh.new()
    # Lens telescope barrel: connects flush at Y = +0.10 (extending to +0.94)
    # Starts inside collar at Y = +0.08 to Y = +0.92
    add_box(bm, (0, 0.50, 0), (0.20, 0.84, 0.20), bevel=0.015)
    # Focusing coil stations along the barrel
    for i in range(3):
        y = 0.30 + i * 0.25
        add_cyl(bm, (0, y, 0), 0.14, 0.05, 'Y', 20)
        bolt_ring(bm, (0, y, 0), 0.13, 8, 'Y', 0.006, 0.02)
    add_tube_between(bm, (0.12, 0.10, 0), (0.12, 0.90, 0), 0.012)
    add_tube_between(bm, (-0.12, 0.10, 0), (-0.12, 0.90, 0), 0.012)
    # Aperture shroud / emitter lens at front
    add_cyl(bm, (0, 0.95, 0), 0.15, 0.08, 'Y', 24)
    add_cyl(bm, (0, 0.99, 0), 0.11, 0.02, 'Y', 24)
    export_bmesh(bm, "heavy_laser_lens", "heavy_laser_lens.glb", color=(0.15, 0.18, 0.22, 1.0))

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

def build_cluster_dispenser():
    bm = bmesh.new(); add_heavy_mount(bm, 1.0); export_bmesh(bm, "cluster_dispenser_mount", "cluster_dispenser_mount.glb")
    bm = bmesh.new(); add_box(bm, (0, 0.1, 0), (0.55, 0.5, 0.45), bevel=0.02); add_mechanical_greebles(bm, (0, 0.1, 0), (0.55, 0.5, 0.45)); export_bmesh(bm, "cluster_dispenser_housing", "cluster_dispenser_housing.glb")

def build_ciws():
    # 1. Authentic Phalanx Pedestal Mount (ciws_mount.glb)
    bm = bmesh.new()
    # Turret base flange at deck level Z=0.03
    add_cyl(bm, (0, 0, 0.03), 0.32, 0.06, 'Z', 24)
    bolt_ring(bm, (0, 0, 0.06), 0.29, 16, 'Z', 0.010, 0.02)
    # Octagonal pedestal equipment trunk (Z from 0.06 to 0.22)
    add_cyl(bm, (0, 0, 0.14), 0.25, 0.16, 'Z', 8)
    # Rear equipment access hatch
    add_box(bm, (0, -0.24, 0.14), (0.18, 0.03, 0.12), bevel=0.005)
    bolt_ring(bm, (0, -0.25, 0.14), 0.08, 6, 'Y', 0.006, 0.015)
    # Lower ammunition drum underneath the trunnions
    add_cyl(bm, (0, 0.0, 0.16), 0.16, 0.26, 'X', 18)
    # Twin vertical trunnion riser stanchions (Z from 0.18 to 0.36)
    for side in (-1, 1):
        x = side * 0.19
        add_box(bm, (x, 0.0, 0.27), (0.06, 0.26, 0.18), bevel=0.01)
        add_cyl(bm, (x + side * 0.03, 0.0, 0.32), 0.055, 0.06, 'X', 16)
        bolt_ring(bm, (x + side * 0.06, 0.0, 0.32), 0.042, 6, 'X', 0.006, 0.015)
    # Elevation drive servo on left stanchion
    add_cyl(bm, (-0.24, -0.06, 0.25), 0.04, 0.08, 'X', 14)
    add_tube_between(bm, (-0.24, -0.06, 0.21), (-0.16, -0.12, 0.12), 0.015)
    export_bmesh(bm, "ciws_mount", "ciws_mount.glb", color=(0.85, 0.86, 0.88, 1.0))
    
    # 2. Distinctive White Radome & Tracking Housing (ciws_radar.glb)
    bm = bmesh.new()
    # Avionics carriage box sitting on trunnion (Z=0 to Z=0.18)
    add_box(bm, (0, -0.05, 0.09), (0.22, 0.26, 0.18), bevel=0.01)
    # Cooling exhaust louvers on aft face
    for i in range(4):
        add_box(bm, (0, -0.185, 0.05 + i * 0.03), (0.16, 0.01, 0.015))
    # Iconic Phalanx White Radome cylinder (Z from 0.18 to 0.50)
    add_cyl(bm, (0, -0.04, 0.34), 0.15, 0.32, 'Z', 24)
    # Smooth hemispherical radome top dome
    add_cyl(bm, (0, -0.04, 0.51), 0.145, 0.02, 'Z', 24)
    add_cone_z(bm, (0, -0.04, 0.55), 0.14, 0.09, 0.06, 24)
    add_cone_z(bm, (0, -0.04, 0.59), 0.09, 0.02, 0.04, 20)
    # Forward tracking radar / optics dish on front face (+Y)
    add_cyl(bm, (0, 0.09, 0.22), 0.08, 0.06, 'Y', 18)
    add_cone_forward(bm, (0, 0.12, 0.22), radius_base=0.07, radius_tip=0.03, height=0.04, segments=16)
    # Starboard FLIR sensor turret pod
    add_cyl(bm, (0.14, 0.06, 0.18), 0.04, 0.10, 'Y', 14)
    add_cyl(bm, (0.14, 0.11, 0.18), 0.025, 0.02, 'Y', 12)
    export_bmesh(bm, "ciws_radar", "ciws_radar.glb", color=(0.92, 0.93, 0.95, 1.0), metallic=0.08, roughness=0.55)
    
    # 3. 20mm 6-Barrel M61A1 Vulcan Rotary Gatling Cannon Cluster (ciws_barrel.glb)
    bm = bmesh.new()
    # Rotor breech housing at trunnion
    add_cyl(bm, (0, 0.08, 0), 0.09, 0.16, 'Y', 24)
    add_box(bm, (0, -0.05, 0), (0.15, 0.14, 0.15), bevel=0.01)
    # Central support drive shaft / spindle
    add_cyl(bm, (0, 0.50, 0), 0.03, 0.76, 'Y', 16)
    # 6 individual Vulcan barrels arranged in a circular array (60 deg spacing)
    r_cluster = 0.060
    r_barrel = 0.013
    for i in range(6):
        ang = i * (math.tau / 6.0)
        bx = math.cos(ang) * r_cluster
        bz = math.sin(ang) * r_cluster
        # Barrel runs from Y=0.12 to Y=0.92 (length 0.80)
        add_cyl(bm, (bx, 0.52, bz), r_barrel, 0.80, 'Y', 12)
        # Muzzle flash suppressor / flared tip at Y=0.93
        add_cyl(bm, (bx, 0.93, bz), r_barrel * 1.25, 0.03, 'Y', 10)
    # 3 barrel restraint clamp rings holding the cluster rigid
    add_cyl(bm, (0, 0.32, 0), 0.080, 0.035, 'Y', 24)
    add_cyl(bm, (0, 0.62, 0), 0.080, 0.035, 'Y', 24)
    add_cyl(bm, (0, 0.90, 0), 0.080, 0.025, 'Y', 24)
    bolt_ring(bm, (0, 0.32, 0), 0.076, 6, 'Y', 0.005, 0.04)
    export_bmesh(bm, "ciws_barrel", "ciws_barrel.glb", color=(0.18, 0.20, 0.22, 1.0), metallic=0.75, roughness=0.35)

if __name__ == '__main__':
    import sys
    clear_scene()
    targets = None
    if '--only' in sys.argv:
        idx = sys.argv.index('--only')
        if idx + 1 < len(sys.argv):
            targets = [t.strip() for t in sys.argv[idx + 1].split(',')]
    elif '--targets' in sys.argv:
        idx = sys.argv.index('--targets')
        if idx + 1 < len(sys.argv):
            targets = [t.strip() for t in sys.argv[idx + 1].split(',')]

    weapon_map = {
        'flamethrower': build_flamethrower,
        'arc_projector': build_arc_projector,
        'ion_cannon': build_ion_cannon,
        'railgun': build_railgun,
        'guided_missile': build_guided_missile,
        'missile_pod': build_missile_pod,
        'sam_launcher': build_sam_launcher,
        'cruise_missile': build_cruise_missile,
        'heavy_laser': build_heavy_laser,
        'pd_laser': build_pd_laser,
        'coilgun': build_coilgun,
        'bunker_buster': build_bunker_buster,
        'hypervelocity_missile': build_hypervelocity_missile,
        'cluster_dispenser': build_cluster_dispenser,
        'ciws': build_ciws,
    }

    if targets:
        for t in targets:
            if t in weapon_map:
                print(f"Building target: {t}")
                weapon_map[t]()
            else:
                print(f"Unknown target: {t}")
    else:
        for name, fn in weapon_map.items():
            fn()
