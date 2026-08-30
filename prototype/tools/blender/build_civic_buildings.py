import bpy
import bmesh
import math
import os
import mathutils

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
OUT_DIR = os.path.normpath(os.path.join(SCRIPT_DIR, "..", "..", "assets", "models", "buildings", "civic"))
os.makedirs(OUT_DIR, exist_ok=True)


def clear_scene():
    bpy.ops.object.select_all(action='SELECT')
    bpy.ops.object.delete(use_global=False)
    for block in list(bpy.data.meshes):
        if block.users == 0:
            bpy.data.meshes.remove(block)
    for block in list(bpy.data.materials):
        if block.users == 0:
            bpy.data.materials.remove(block)


def get_building_materials():
    """Builds rich multi-material PBR palette for Cold-War architectural structures."""
    # 0: Concrete foundation / plinth / sidewalk
    m_concrete = bpy.data.materials.new("Mat_Concrete")
    m_concrete.use_nodes = True
    b = m_concrete.node_tree.nodes.get("Principled BSDF")
    if b:
        b.inputs['Base Color'].default_value = (0.52, 0.53, 0.50, 1.0)
        b.inputs['Metallic'].default_value = 0.02
        b.inputs['Roughness'].default_value = 0.92

    # 1: Red brick masonry
    m_brick = bpy.data.materials.new("Mat_Brick")
    m_brick.use_nodes = True
    b = m_brick.node_tree.nodes.get("Principled BSDF")
    if b:
        b.inputs['Base Color'].default_value = (0.58, 0.24, 0.18, 1.0)
        b.inputs['Metallic'].default_value = 0.02
        b.inputs['Roughness'].default_value = 0.88

    # 2: Painted siding / Stucco / White plaster
    m_stucco = bpy.data.materials.new("Mat_StuccoWhite")
    m_stucco.use_nodes = True
    b = m_stucco.node_tree.nodes.get("Principled BSDF")
    if b:
        b.inputs['Base Color'].default_value = (0.78, 0.76, 0.72, 1.0)
        b.inputs['Metallic'].default_value = 0.02
        b.inputs['Roughness'].default_value = 0.85

    # 3: Industrial steel / corrugated siding / olive-grey panels
    m_metal = bpy.data.materials.new("Mat_MetalPanels")
    m_metal.use_nodes = True
    b = m_metal.node_tree.nodes.get("Principled BSDF")
    if b:
        b.inputs['Base Color'].default_value = (0.35, 0.38, 0.36, 1.0)
        b.inputs['Metallic'].default_value = 0.45
        b.inputs['Roughness'].default_value = 0.65

    # 4: Wood timber / dark cedar clapboard / cabin logs
    m_wood = bpy.data.materials.new("Mat_WoodClapboard")
    m_wood.use_nodes = True
    b = m_wood.node_tree.nodes.get("Principled BSDF")
    if b:
        b.inputs['Base Color'].default_value = (0.42, 0.28, 0.18, 1.0)
        b.inputs['Metallic'].default_value = 0.02
        b.inputs['Roughness'].default_value = 0.90

    # 5: Roof shingles / tar roof / dark slate
    m_roof = bpy.data.materials.new("Mat_RoofDark")
    m_roof.use_nodes = True
    b = m_roof.node_tree.nodes.get("Principled BSDF")
    if b:
        b.inputs['Base Color'].default_value = (0.20, 0.22, 0.24, 1.0)
        b.inputs['Metallic'].default_value = 0.05
        b.inputs['Roughness'].default_value = 0.80

    # 6: Roof tile red / terracotta / barn red
    m_roof_red = bpy.data.materials.new("Mat_RoofRed")
    m_roof_red.use_nodes = True
    b = m_roof_red.node_tree.nodes.get("Principled BSDF")
    if b:
        b.inputs['Base Color'].default_value = (0.65, 0.18, 0.14, 1.0)
        b.inputs['Metallic'].default_value = 0.02
        b.inputs['Roughness'].default_value = 0.82

    # 7: Glass windows / curtain wall
    m_glass = bpy.data.materials.new("Mat_Glass")
    m_glass.use_nodes = True
    b = m_glass.node_tree.nodes.get("Principled BSDF")
    if b:
        b.inputs['Base Color'].default_value = (0.15, 0.28, 0.42, 1.0)
        b.inputs['Metallic'].default_value = 0.60
        b.inputs['Roughness'].default_value = 0.25

    # 8: Industrial dark iron / pipes / fire escapes / trusses
    m_iron = bpy.data.materials.new("Mat_DarkIron")
    m_iron.use_nodes = True
    b = m_iron.node_tree.nodes.get("Principled BSDF")
    if b:
        b.inputs['Base Color'].default_value = (0.16, 0.16, 0.18, 1.0)
        b.inputs['Metallic'].default_value = 0.70
        b.inputs['Roughness'].default_value = 0.55

    # 9: Hazard yellow / Emergency red / Signage accent
    m_accent = bpy.data.materials.new("Mat_Accent")
    m_accent.use_nodes = True
    b = m_accent.node_tree.nodes.get("Principled BSDF")
    if b:
        b.inputs['Base Color'].default_value = (0.85, 0.20, 0.18, 1.0)
        b.inputs['Metallic'].default_value = 0.10
        b.inputs['Roughness'].default_value = 0.60

    return [m_concrete, m_brick, m_stucco, m_metal, m_wood, m_roof, m_roof_red, m_glass, m_iron, m_accent]


# --- BMesh Architectural Primitives ---

def add_box(bm, center, size, mat_idx=0):
    start_faces = len(bm.faces)
    m = mathutils.Matrix.Translation(mathutils.Vector(center)) @ mathutils.Matrix.Diagonal(
        mathutils.Vector((size[0], size[1], size[2], 1.0)))
    bmesh.ops.create_cube(bm, size=1.0, matrix=m)
    for f in bm.faces[start_faces:]:
        f.material_index = mat_idx
    return bm.faces[start_faces:]


def add_cyl(bm, center, radius, height, axis='Z', segments=12, mat_idx=8):
    start_faces = len(bm.faces)
    m = mathutils.Matrix.Translation(mathutils.Vector(center))
    if axis == 'X':
        m = m @ mathutils.Matrix.Rotation(math.radians(90), 4, 'Y')
    elif axis == 'Y':
        m = m @ mathutils.Matrix.Rotation(math.radians(-90), 4, 'X')
    bmesh.ops.create_cone(bm, cap_ends=True, cap_tris=False, segments=segments,
                          radius1=radius, radius2=radius, depth=height, matrix=m)
    for f in bm.faces[start_faces:]:
        f.material_index = mat_idx
    return bm.faces[start_faces:]


def add_roof_gable(bm, base_center, width, length, height, axis='Y', overhang=0.4, mat_idx=5):
    """Creates a gabled pitched roof prism with overhanging eaves."""
    start_faces = len(bm.faces)
    hw = (width * 0.5) + overhang
    hl = (length * 0.5) + overhang
    bx, by, bz = base_center[0], base_center[1], base_center[2]
    
    if axis == 'Y': # Ridge runs along Y (Length)
        v0 = bm.verts.new((bx - hw, by - hl, bz))
        v1 = bm.verts.new((bx + hw, by - hl, bz))
        v2 = bm.verts.new((bx, by - hl, bz + height))
        v3 = bm.verts.new((bx - hw, by + hl, bz))
        v4 = bm.verts.new((bx + hw, by + hl, bz))
        v5 = bm.verts.new((bx, by + hl, bz + height))
        
        f0 = bm.faces.new((v0, v1, v2)) # Front gable
        f1 = bm.faces.new((v4, v3, v5)) # Back gable
        f2 = bm.faces.new((v0, v2, v5, v3)) # Left slope
        f3 = bm.faces.new((v1, v4, v5, v2)) # Right slope
        f4 = bm.faces.new((v0, v3, v4, v1)) # Bottom
    else: # Ridge runs along X (Width)
        v0 = bm.verts.new((bx - hw, by - hl, bz))
        v1 = bm.verts.new((bx - hw, by + hl, bz))
        v2 = bm.verts.new((bx - hw, by, bz + height))
        v3 = bm.verts.new((bx + hw, by - hl, bz))
        v4 = bm.verts.new((bx + hw, by + hl, bz))
        v5 = bm.verts.new((bx + hw, by, bz + height))
        
        f0 = bm.faces.new((v0, v2, v1))
        f1 = bm.faces.new((v3, v4, v5))
        f2 = bm.faces.new((v0, v3, v5, v2))
        f3 = bm.faces.new((v1, v2, v5, v4))
        f4 = bm.faces.new((v0, v1, v4, v3))

    for f in bm.faces[start_faces:]:
        f.material_index = mat_idx
    return bm.faces[start_faces:]


def add_roof_hipped(bm, base_center, width, length, height, overhang=0.3, mat_idx=5):
    """Creates a 4-sided hipped roof."""
    start_faces = len(bm.faces)
    hw = (width * 0.5) + overhang
    hl = (length * 0.5) + overhang
    bx, by, bz = base_center[0], base_center[1], base_center[2]
    
    # Peak ridge offset
    rw = max(0.1, hw * 0.3)
    rl = max(0.1, hl * 0.5)
    
    # Base verts
    b0 = bm.verts.new((bx - hw, by - hl, bz))
    b1 = bm.verts.new((bx + hw, by - hl, bz))
    b2 = bm.verts.new((bx + hw, by + hl, bz))
    b3 = bm.verts.new((bx - hw, by + hl, bz))
    
    # Ridge verts
    p0 = bm.verts.new((bx, by - rl, bz + height))
    p1 = bm.verts.new((bx, by + rl, bz + height))
    
    f0 = bm.faces.new((b0, b1, p0))
    f1 = bm.faces.new((b1, b2, p1, p0))
    f2 = bm.faces.new((b2, b3, p1))
    f3 = bm.faces.new((b3, b0, p0, p1))
    f4 = bm.faces.new((b0, b3, b2, b1))
    
    for f in bm.faces[start_faces:]:
        f.material_index = mat_idx


def add_roof_hvac(bm, roof_center, count=2):
    """Adds realistic rooftop HVAC units, vents, and conduits."""
    bx, by, bz = roof_center
    for i in range(count):
        ox = (i - (count - 1) * 0.5) * 2.8
        add_box(bm, (bx + ox, by, bz + 0.45), (1.4, 1.1, 0.9), mat_idx=8)
        add_cyl(bm, (bx + ox, by, bz + 0.95), radius=0.35, height=0.2, axis='Z', mat_idx=3)


def add_water_tower(bm, roof_center, radius=1.0, height=2.2):
    """Adds a wooden/metal rooftop water tank with support stilts."""
    bx, by, bz = roof_center
    # 4 stilts
    d = radius * 0.7
    for sx, sy in [(-d, -d), (d, -d), (d, d), (-d, d)]:
        add_cyl(bm, (bx + sx, by + sy, bz + 0.6), radius=0.08, height=1.2, axis='Z', mat_idx=8)
    # tank
    add_cyl(bm, (bx, by, bz + 1.2 + height * 0.5), radius=radius, height=height, axis='Z', mat_idx=4)
    # conical cap
    add_cyl(bm, (bx, by, bz + 1.2 + height + 0.25), radius=radius * 1.05, height=0.5, axis='Z', mat_idx=5)


def add_loading_dock(bm, wall_center, width=4.0, height=3.0, depth=1.5):
    """Adds industrial loading dock with concrete bumper and rollup door."""
    bx, by, bz = wall_center
    # Concrete platform
    add_box(bm, (bx, by - depth * 0.5, bz + 0.6), (width + 1.0, depth, 1.2), mat_idx=0)
    # Roll-up door
    add_box(bm, (bx, by + 0.05, bz + 1.2 + height * 0.5), (width, 0.1, height), mat_idx=3)
    # Hazard striped bumper
    add_box(bm, (bx, by - depth + 0.05, bz + 0.6), (width + 0.8, 0.1, 0.3), mat_idx=9)


def add_window_stripes(bm, center, size, rows=3, cols=4, axis='Y', mat_idx=7):
    """Adds recessed glass window bands across building facades."""
    bx, by, bz = center
    w, l, h = size
    r_step = h / float(rows + 1)
    for r in range(1, rows + 1):
        wz = bz - (h * 0.5) + (r * r_step)
        if axis == 'Y': # Facade faces X
            add_box(bm, (bx + (w * 0.505), by, wz), (0.05, l * 0.85, r_step * 0.55), mat_idx=mat_idx)
            add_box(bm, (bx - (w * 0.505), by, wz), (0.05, l * 0.85, r_step * 0.55), mat_idx=mat_idx)
        else: # Facade faces Y
            add_box(bm, (bx, by + (l * 0.505), wz), (w * 0.85, 0.05, r_step * 0.55), mat_idx=mat_idx)
            add_box(bm, (bx, by - (l * 0.505), wz), (w * 0.85, 0.05, r_step * 0.55), mat_idx=mat_idx)


def add_fire_escape(bm, wall_pos, levels=3, level_height=3.0, width=1.8):
    """Adds exterior steel fire escape ladders and platforms."""
    bx, by, bz = wall_pos
    for lv in range(levels):
        lz = bz + (lv * level_height) + 1.0
        # Platform
        add_box(bm, (bx, by - 0.8, lz), (width, 1.4, 0.1), mat_idx=8)
        # Railing
        add_box(bm, (bx, by - 1.45, lz + 0.45), (width, 0.05, 0.9), mat_idx=8)
        add_box(bm, (bx - (width * 0.5), by - 0.8, lz + 0.45), (0.05, 1.3, 0.9), mat_idx=8)
        add_box(bm, (bx + (width * 0.5), by - 0.8, lz + 0.45), (0.05, 1.3, 0.9), mat_idx=8)
        # Ladder connecting to next level
        if lv < levels - 1:
            add_box(bm, (bx + (width * 0.25) * (1 if lv % 2 == 0 else -1), by - 0.8, lz + (level_height * 0.5)), (0.4, 0.1, level_height), mat_idx=8)


def export_model(bm, name, materials):
    mesh = bpy.data.meshes.new(name)
    bm.to_mesh(mesh)
    bm.free()
    
    obj = bpy.data.objects.new(name, mesh)
    bpy.context.collection.objects.link(obj)
    
    for mat in materials:
        obj.data.materials.append(mat)
        
    bpy.context.view_layer.objects.active = obj
    obj.select_set(True)
    
    # Center origin at ground level (Z min = 0)
    bpy.ops.object.origin_set(type='ORIGIN_GEOMETRY', center='BOUNDS')
    # Shift so bottom is at Z=0
    min_z = min([v.co.z for v in obj.data.vertices])
    for v in obj.data.vertices:
        v.co.z -= min_z
        
    # In Godot, Y is Up, Z is Forward/Back. Blender uses Z as Up.
    # Export glb transforms coordinates seamlessly.
    out_file = os.path.join(OUT_DIR, f"{name}.glb")
    bpy.ops.export_scene.gltf(
        filepath=out_file,
        use_selection=True,
        export_format='GLB',
        export_apply=True
    )
    print(f"[EXPORT] {name}.glb generated -> {out_file}")
    clear_scene()


# ==============================================================================
# 60 DETAILED ARCHITECTURAL BUILDING GENERATORS
# ==============================================================================

def generate_all_buildings():
    print("==================================================")
    print("  BUILDING 60 DETAILED COLD-WAR CIVIC STRUCTURES")
    print("==================================================")
    
    # -------------------------------------------------------------------------
    # 1. RURAL & AGRICULTURAL (10 Models)
    # -------------------------------------------------------------------------
    
    # 1.1 shed_tool_wood
    clear_scene()
    mats = get_building_materials()
    bm = bmesh.new()
    add_box(bm, (0, 0, 0.1), (3.6, 2.8, 0.2), mat_idx=0)
    add_box(bm, (0, 0, 1.2), (3.2, 2.4, 2.2), mat_idx=4)
    add_roof_gable(bm, (0, 0, 2.3), width=3.2, length=2.4, height=1.0, axis='Y', mat_idx=5)
    add_box(bm, (0, -1.22, 1.0), (1.0, 0.1, 1.8), mat_idx=8)
    export_model(bm, "shed_tool_wood", mats)

    # 1.2 shed_corrugated_metal
    clear_scene()
    mats = get_building_materials()
    bm = bmesh.new()
    add_box(bm, (0, 0, 0.1), (4.5, 3.5, 0.2), mat_idx=0)
    add_box(bm, (0, 0, 1.4), (4.0, 3.0, 2.6), mat_idx=3)
    add_roof_gable(bm, (0, 0, 2.7), width=4.0, length=3.0, height=0.9, axis='X', mat_idx=5)
    add_box(bm, (0, -1.52, 1.2), (2.2, 0.1, 2.2), mat_idx=8)
    export_model(bm, "shed_corrugated_metal", mats)

    # 1.3 cabin_log_timber
    clear_scene()
    mats = get_building_materials()
    bm = bmesh.new()
    add_box(bm, (0, 0, 0.2), (5.5, 4.5, 0.4), mat_idx=0)
    add_box(bm, (0, 0, 1.8), (5.0, 4.0, 3.2), mat_idx=4)
    add_roof_gable(bm, (0, 0, 3.4), width=5.0, length=4.0, height=1.8, axis='Y', mat_idx=5)
    add_box(bm, (1.8, 0.8, 4.0), (0.7, 0.7, 2.5), mat_idx=1) # Stone chimney
    add_box(bm, (0, -2.4, 0.2), (3.0, 1.2, 0.3), mat_idx=4) # Front porch deck
    add_cyl(bm, (-1.2, -2.8, 1.3), 0.08, 2.2, axis='Z', mat_idx=4)
    add_cyl(bm, (1.2, -2.8, 1.3), 0.08, 2.2, axis='Z', mat_idx=4)
    export_model(bm, "cabin_log_timber", mats)

    # 1.4 barn_classic_gambrel
    clear_scene()
    mats = get_building_materials()
    bm = bmesh.new()
    add_box(bm, (0, 0, 0.25), (10.5, 14.5, 0.5), mat_idx=0)
    add_box(bm, (0, 0, 3.25), (10.0, 14.0, 6.0), mat_idx=6) # Red barn wood
    # Gambrel roof tier 1 & 2
    add_roof_gable(bm, (0, 0, 6.25), width=10.0, length=14.0, height=3.5, axis='Y', mat_idx=5)
    add_box(bm, (0, -7.05, 2.5), (4.0, 0.15, 4.5), mat_idx=2) # Big white X barn doors
    add_cyl(bm, (0, 0, 10.2), 0.4, 0.8, axis='Z', mat_idx=2) # Cupola
    export_model(bm, "barn_classic_gambrel", mats)

    # 1.5 barn_pole_storage
    clear_scene()
    mats = get_building_materials()
    bm = bmesh.new()
    add_box(bm, (0, 0, 0.2), (12.0, 16.0, 0.4), mat_idx=0)
    add_box(bm, (0, 0, 2.8), (11.4, 15.4, 5.2), mat_idx=3)
    add_roof_gable(bm, (0, 0, 5.4), width=11.4, length=15.4, height=2.2, axis='Y', mat_idx=5)
    add_box(bm, (0, -7.75, 2.6), (5.5, 0.1, 4.2), mat_idx=8) # Open bay door
    export_model(bm, "barn_pole_storage", mats)

    # 1.6 farmhouse_two_story
    clear_scene()
    mats = get_building_materials()
    bm = bmesh.new()
    add_box(bm, (0, 0, 0.3), (9.0, 11.0, 0.6), mat_idx=0)
    add_box(bm, (0, 0, 3.5), (8.4, 10.4, 6.4), mat_idx=2) # White clapboard
    add_roof_gable(bm, (0, 0, 6.7), width=8.4, length=10.4, height=2.8, axis='Y', mat_idx=6)
    add_box(bm, (2.6, 2.5, 7.5), (0.8, 0.8, 2.4), mat_idx=1) # Chimney
    add_box(bm, (0, -5.8, 0.3), (6.0, 1.8, 0.4), mat_idx=4) # Porch
    add_window_stripes(bm, (0, 0, 3.5), (8.4, 10.4, 6.4), rows=2, cols=3, axis='Y', mat_idx=7)
    export_model(bm, "farmhouse_two_story", mats)

    # 1.7 grain_silo_twin
    clear_scene()
    mats = get_building_materials()
    bm = bmesh.new()
    add_box(bm, (0, 0, 0.4), (7.0, 4.5, 0.8), mat_idx=0)
    for sx in [-1.8, 1.8]:
        add_cyl(bm, (sx, 0, 6.4), radius=1.6, height=11.2, axis='Z', segments=16, mat_idx=3)
        add_cyl(bm, (sx, 0, 12.5), radius=1.65, height=1.2, axis='Z', segments=16, mat_idx=5)
    # Connecting auger conveyor pipe
    add_cyl(bm, (0, 0, 11.0), radius=0.25, height=3.6, axis='X', mat_idx=8)
    export_model(bm, "grain_silo_twin", mats)

    # 1.8 windmill_aeromotor
    clear_scene()
    mats = get_building_materials()
    bm = bmesh.new()
    add_box(bm, (0, 0, 0.2), (3.0, 3.0, 0.4), mat_idx=0)
    # 4 lattice legs
    for lx, ly in [(-1, -1), (1, -1), (1, 1), (-1, 1)]:
        add_cyl(bm, (lx * 0.6, ly * 0.6, 6.0), radius=0.08, height=11.6, axis='Z', mat_idx=8)
    add_box(bm, (0, 0, 12.0), (1.2, 1.2, 0.3), mat_idx=8) # Platform
    add_cyl(bm, (0, -0.6, 13.0), radius=1.8, height=0.1, axis='Y', segments=12, mat_idx=3) # Vane blades
    add_box(bm, (0, 0.8, 13.0), (0.1, 1.6, 0.8), mat_idx=9) # Tail vane
    export_model(bm, "windmill_aeromotor", mats)

    # 1.9 stable_paddock
    clear_scene()
    mats = get_building_materials()
    bm = bmesh.new()
    add_box(bm, (0, 0, 0.2), (14.0, 8.0, 0.4), mat_idx=0)
    add_box(bm, (0, 0, 2.2), (13.4, 7.4, 4.0), mat_idx=4)
    add_roof_gable(bm, (0, 0, 4.2), width=13.4, length=7.4, height=2.0, axis='X', mat_idx=5)
    for ox in [-4.5, -1.5, 1.5, 4.5]:
        add_box(bm, (ox, -3.75, 1.4), (1.8, 0.1, 2.4), mat_idx=8) # Stall doors
    export_model(bm, "stable_paddock", mats)

    # 1.10 tractor_garage
    clear_scene()
    mats = get_building_materials()
    bm = bmesh.new()
    add_box(bm, (0, 0, 0.25), (9.0, 8.0, 0.5), mat_idx=0)
    add_box(bm, (0, 0, 2.5), (8.4, 7.4, 4.5), mat_idx=3)
    add_roof_gable(bm, (0, 0, 4.75), width=8.4, length=7.4, height=1.8, axis='X', mat_idx=5)
    add_loading_dock(bm, (0, -3.75, 0.0), width=4.5, height=3.2, depth=1.2)
    export_model(bm, "tractor_garage", mats)

    # -------------------------------------------------------------------------
    # 2. SUBURBAN & RESIDENTIAL (10 Models)
    # -------------------------------------------------------------------------
    
    # 2.1 house_suburban_bungalow
    clear_scene()
    mats = get_building_materials()
    bm = bmesh.new()
    add_box(bm, (0, 0, 0.25), (10.0, 9.0, 0.5), mat_idx=0)
    add_box(bm, (0, 0, 2.25), (9.4, 8.4, 3.5), mat_idx=2)
    add_roof_hipped(bm, (0, 0, 4.0), width=9.4, length=8.4, height=2.2, mat_idx=5)
    add_box(bm, (2.8, -4.3, 1.4), (2.4, 0.1, 2.2), mat_idx=3) # Garage door
    add_window_stripes(bm, (0, 0, 2.25), (9.4, 8.4, 3.5), rows=1, cols=3, axis='Y', mat_idx=7)
    export_model(bm, "house_suburban_bungalow", mats)

    # 2.2 house_two_story_colonial
    clear_scene()
    mats = get_building_materials()
    bm = bmesh.new()
    add_box(bm, (0, 0, 0.3), (11.0, 8.5, 0.6), mat_idx=0)
    add_box(bm, (0, 0, 3.6), (10.4, 7.9, 6.6), mat_idx=1) # Red brick
    add_roof_gable(bm, (0, 0, 6.9), width=10.4, length=7.9, height=2.6, axis='X', mat_idx=5)
    add_box(bm, (-3.8, 2.0, 7.8), (0.8, 0.8, 2.2), mat_idx=1)
    add_box(bm, (3.8, 2.0, 7.8), (0.8, 0.8, 2.2), mat_idx=1)
    add_window_stripes(bm, (0, 0, 3.6), (10.4, 7.9, 6.6), rows=2, cols=4, axis='Y', mat_idx=7)
    export_model(bm, "house_two_story_colonial", mats)

    # 2.3 house_split_level
    clear_scene()
    mats = get_building_materials()
    bm = bmesh.new()
    add_box(bm, (0, 0, 0.25), (13.0, 8.5, 0.5), mat_idx=0)
    add_box(bm, (-3.0, 0, 3.25), (6.5, 8.0, 6.0), mat_idx=2) # 2-story side
    add_box(bm, (3.2, 0, 2.0), (6.0, 8.0, 3.5), mat_idx=1) # 1-story side
    add_roof_gable(bm, (-3.0, 0, 6.25), width=6.5, length=8.0, height=1.8, axis='Y', mat_idx=5)
    add_roof_gable(bm, (3.2, 0, 3.75), width=6.0, length=8.0, height=1.5, axis='Y', mat_idx=5)
    export_model(bm, "house_split_level", mats)

    # 2.4 house_ranch_brick
    clear_scene()
    mats = get_building_materials()
    bm = bmesh.new()
    add_box(bm, (0, 0, 0.25), (15.0, 8.0, 0.5), mat_idx=0)
    add_box(bm, (0, 0, 2.0), (14.4, 7.4, 3.5), mat_idx=1)
    add_roof_hipped(bm, (0, 0, 3.75), width=14.4, length=7.4, height=1.8, mat_idx=5)
    add_window_stripes(bm, (0, 0, 2.0), (14.4, 7.4, 3.5), rows=1, cols=5, axis='Y', mat_idx=7)
    export_model(bm, "house_ranch_brick", mats)

    # 2.5 villa_modern_estate
    clear_scene()
    mats = get_building_materials()
    bm = bmesh.new()
    add_box(bm, (0, 0, 0.3), (16.0, 12.0, 0.6), mat_idx=0)
    add_box(bm, (-2.0, 0, 3.0), (10.0, 10.0, 5.4), mat_idx=2) # Main pavilion
    add_box(bm, (4.5, -1.0, 2.2), (6.0, 7.0, 3.8), mat_idx=3) # Wing
    # Flat modern roof slabs
    add_box(bm, (-2.0, 0, 5.9), (11.0, 11.0, 0.4), mat_idx=5)
    add_box(bm, (4.5, -1.0, 4.3), (6.8, 7.8, 0.4), mat_idx=5)
    add_window_stripes(bm, (-2.0, 0, 3.0), (10.0, 10.0, 5.4), rows=2, cols=4, axis='Y', mat_idx=7)
    export_model(bm, "villa_modern_estate", mats)

    # 2.6 duplex_residential
    clear_scene()
    mats = get_building_materials()
    bm = bmesh.new()
    add_box(bm, (0, 0, 0.3), (14.0, 9.0, 0.6), mat_idx=0)
    add_box(bm, (0, 0, 3.5), (13.4, 8.4, 6.4), mat_idx=1)
    add_roof_gable(bm, (0, 0, 6.7), width=13.4, length=8.4, height=2.4, axis='X', mat_idx=5)
    # Dual symmetrical front porches
    add_box(bm, (-3.5, -4.8, 0.3), (2.6, 1.4, 0.3), mat_idx=4)
    add_box(bm, (3.5, -4.8, 0.3), (2.6, 1.4, 0.3), mat_idx=4)
    add_window_stripes(bm, (0, 0, 3.5), (13.4, 8.4, 6.4), rows=2, cols=4, axis='Y', mat_idx=7)
    export_model(bm, "duplex_residential", mats)

    # 2.7 townhouse_row_unit
    clear_scene()
    mats = get_building_materials()
    bm = bmesh.new()
    add_box(bm, (0, 0, 0.3), (6.5, 11.0, 0.6), mat_idx=0)
    add_box(bm, (0, 0, 4.5), (6.0, 10.4, 8.4), mat_idx=1)
    add_roof_hipped(bm, (0, 0, 8.7), width=6.0, length=10.4, height=2.0, mat_idx=5)
    add_window_stripes(bm, (0, 0, 4.5), (6.0, 10.4, 8.4), rows=3, cols=2, axis='Y', mat_idx=7)
    export_model(bm, "townhouse_row_unit", mats)

    # 2.8 townhouse_row_corner
    clear_scene()
    mats = get_building_materials()
    bm = bmesh.new()
    add_box(bm, (0, 0, 0.3), (8.0, 11.0, 0.6), mat_idx=0)
    add_box(bm, (0, 0, 4.5), (7.4, 10.4, 8.4), mat_idx=2)
    add_roof_hipped(bm, (0, 0, 8.7), width=7.4, length=10.4, height=2.2, mat_idx=5)
    add_window_stripes(bm, (0, 0, 4.5), (7.4, 10.4, 8.4), rows=3, cols=3, axis='Y', mat_idx=7)
    export_model(bm, "townhouse_row_corner", mats)

    # 2.9 modular_pre_fab_home
    clear_scene()
    mats = get_building_materials()
    bm = bmesh.new()
    add_box(bm, (0, 0, 0.2), (14.0, 5.0, 0.4), mat_idx=0)
    add_box(bm, (0, 0, 1.8), (13.6, 4.6, 3.2), mat_idx=3)
    add_roof_gable(bm, (0, 0, 3.4), width=13.6, length=4.6, height=1.0, axis='X', mat_idx=5)
    export_model(bm, "modular_pre_fab_home", mats)

    # 2.10 cozy_cottage
    clear_scene()
    mats = get_building_materials()
    bm = bmesh.new()
    add_box(bm, (0, 0, 0.25), (7.0, 6.0, 0.5), mat_idx=0)
    add_box(bm, (0, 0, 2.25), (6.4, 5.4, 3.5), mat_idx=4)
    add_roof_gable(bm, (0, 0, 4.0), width=6.4, length=5.4, height=2.2, axis='Y', mat_idx=6)
    add_box(bm, (1.8, 1.4, 4.8), (0.6, 0.6, 2.0), mat_idx=1)
    export_model(bm, "cozy_cottage", mats)

    # -------------------------------------------------------------------------
    # 3. URBAN & APARTMENTS (10 Models)
    # -------------------------------------------------------------------------
    
    # 3.1 apartment_walkup_3s
    clear_scene()
    mats = get_building_materials()
    bm = bmesh.new()
    add_box(bm, (0, 0, 0.4), (12.0, 14.0, 0.8), mat_idx=0)
    add_box(bm, (0, 0, 5.4), (11.2, 13.2, 9.2), mat_idx=1)
    add_box(bm, (0, 0, 10.2), (11.6, 13.6, 0.5), mat_idx=0) # Parapet roof
    add_roof_hvac(bm, (0, 0, 10.4), count=2)
    add_fire_escape(bm, (5.65, 0, 0), levels=3, level_height=2.8)
    add_window_stripes(bm, (0, 0, 5.4), (11.2, 13.2, 9.2), rows=3, cols=4, axis='Y', mat_idx=7)
    export_model(bm, "apartment_walkup_3s", mats)

    # 3.2 apartment_block_brick_5s
    clear_scene()
    mats = get_building_materials()
    bm = bmesh.new()
    add_box(bm, (0, 0, 0.5), (14.0, 18.0, 1.0), mat_idx=0)
    add_box(bm, (0, 0, 8.5), (13.2, 17.2, 15.0), mat_idx=1)
    add_box(bm, (0, 0, 16.2), (13.6, 17.6, 0.6), mat_idx=0)
    add_roof_hvac(bm, (0, 0, 16.4), count=3)
    add_water_tower(bm, (3.5, 4.0, 16.4), radius=1.2, height=2.6)
    add_fire_escape(bm, (-6.65, 0, 0), levels=5, level_height=2.8)
    add_window_stripes(bm, (0, 0, 8.5), (13.2, 17.2, 15.0), rows=5, cols=5, axis='Y', mat_idx=7)
    export_model(bm, "apartment_block_brick_5s", mats)

    # 3.3 apartment_tenement_fireescape
    clear_scene()
    mats = get_building_materials()
    bm = bmesh.new()
    add_box(bm, (0, 0, 0.4), (10.0, 12.0, 0.8), mat_idx=0)
    add_box(bm, (0, 0, 7.0), (9.2, 11.2, 12.4), mat_idx=1)
    add_box(bm, (0, 0, 13.4), (9.6, 11.6, 0.5), mat_idx=0)
    add_fire_escape(bm, (0, -5.65, 0), levels=4, level_height=2.8)
    add_window_stripes(bm, (0, 0, 7.0), (9.2, 11.2, 12.4), rows=4, cols=3, axis='Y', mat_idx=7)
    export_model(bm, "apartment_tenement_fireescape", mats)

    # 3.4 apartment_modern_balconies
    clear_scene()
    mats = get_building_materials()
    bm = bmesh.new()
    add_box(bm, (0, 0, 0.5), (15.0, 15.0, 1.0), mat_idx=0)
    add_box(bm, (0, 0, 9.5), (14.0, 14.0, 17.0), mat_idx=2)
    # Balconies protruding
    for f in range(1, 6):
        fz = f * 2.8 + 0.5
        add_box(bm, (0, -7.5, fz), (12.0, 1.2, 0.8), mat_idx=8)
    add_box(bm, (0, 0, 18.2), (14.6, 14.6, 0.6), mat_idx=0)
    add_roof_hvac(bm, (0, 0, 18.4), count=3)
    add_window_stripes(bm, (0, 0, 9.5), (14.0, 14.0, 17.0), rows=5, cols=4, axis='Y', mat_idx=7)
    export_model(bm, "apartment_modern_balconies", mats)

    # 3.5 apartment_corner_groundstore
    clear_scene()
    mats = get_building_materials()
    bm = bmesh.new()
    add_box(bm, (0, 0, 0.4), (12.0, 12.0, 0.8), mat_idx=0)
    add_box(bm, (0, 0, 2.0), (11.4, 11.4, 3.2), mat_idx=7) # Ground floor retail glass
    add_box(bm, (0, 0, 6.8), (11.2, 11.2, 6.4), mat_idx=1) # Upper residential
    add_box(bm, (0, 0, 10.2), (11.6, 11.6, 0.5), mat_idx=0)
    add_roof_hvac(bm, (0, 0, 10.4), count=2)
    add_window_stripes(bm, (0, 0, 6.8), (11.2, 11.2, 6.4), rows=2, cols=3, axis='Y', mat_idx=7)
    export_model(bm, "apartment_corner_groundstore", mats)

    # 3.6 residential_tower_10s
    clear_scene()
    mats = get_building_materials()
    bm = bmesh.new()
    add_box(bm, (0, 0, 0.6), (16.0, 16.0, 1.2), mat_idx=0)
    add_box(bm, (0, 0, 15.0), (14.8, 14.8, 28.0), mat_idx=2)
    add_box(bm, (0, 0, 29.3), (15.2, 15.2, 0.8), mat_idx=0)
    add_roof_hvac(bm, (0, 0, 29.6), count=4)
    add_water_tower(bm, (-3.5, -3.5, 29.6), radius=1.5, height=3.0)
    add_window_stripes(bm, (0, 0, 15.0), (14.8, 14.8, 28.0), rows=9, cols=5, axis='Y', mat_idx=7)
    export_model(bm, "residential_tower_10s", mats)

    # 3.7 office_lowrise_concrete
    clear_scene()
    mats = get_building_materials()
    bm = bmesh.new()
    add_box(bm, (0, 0, 0.5), (18.0, 12.0, 1.0), mat_idx=0)
    add_box(bm, (0, 0, 6.5), (17.0, 11.0, 11.0), mat_idx=0) # Brutalist concrete
    add_window_stripes(bm, (0, 0, 6.5), (17.0, 11.0, 11.0), rows=3, cols=6, axis='Y', mat_idx=7)
    add_roof_hvac(bm, (0, 0, 12.2), count=3)
    export_model(bm, "office_lowrise_concrete", mats)

    # 3.8 office_midrise_glass
    clear_scene()
    mats = get_building_materials()
    bm = bmesh.new()
    add_box(bm, (0, 0, 0.6), (16.0, 16.0, 1.2), mat_idx=0)
    add_box(bm, (0, 0, 11.0), (15.0, 15.0, 20.0), mat_idx=7) # Full glass curtain
    # Steel frame mullions
    add_box(bm, (0, 0, 11.0), (15.2, 0.4, 20.0), mat_idx=8)
    add_box(bm, (0, 0, 11.0), (0.4, 15.2, 20.0), mat_idx=8)
    add_box(bm, (0, 0, 21.3), (15.4, 15.4, 0.8), mat_idx=8)
    add_roof_hvac(bm, (0, 0, 21.6), count=4)
    export_model(bm, "office_midrise_glass", mats)

    # 3.9 hotel_motor_inn
    clear_scene()
    mats = get_building_materials()
    bm = bmesh.new()
    add_box(bm, (0, 0, 0.3), (22.0, 8.0, 0.6), mat_idx=0)
    add_box(bm, (0, 0, 3.8), (21.2, 7.2, 6.8), mat_idx=2)
    add_roof_gable(bm, (0, 0, 7.2), width=21.2, length=7.2, height=1.8, axis='X', mat_idx=5)
    # Exterior walkway railings
    add_box(bm, (0, -4.0, 3.8), (20.5, 0.8, 0.8), mat_idx=8)
    add_window_stripes(bm, (0, 0, 3.8), (21.2, 7.2, 6.8), rows=2, cols=7, axis='Y', mat_idx=7)
    export_model(bm, "hotel_motor_inn", mats)

    # 3.10 motel_strip_l_shape
    clear_scene()
    mats = get_building_materials()
    bm = bmesh.new()
    add_box(bm, (0, 0, 0.25), (18.0, 14.0, 0.5), mat_idx=0)
    add_box(bm, (0, 3.5, 2.2), (17.2, 5.0, 3.8), mat_idx=1) # North wing
    add_box(bm, (-6.0, -2.5, 2.2), (5.2, 7.0, 3.8), mat_idx=1) # West wing
    add_roof_gable(bm, (0, 3.5, 4.1), width=17.2, length=5.0, height=1.4, axis='X', mat_idx=5)
    add_roof_gable(bm, (-6.0, -2.5, 4.1), width=5.2, length=7.0, height=1.4, axis='Y', mat_idx=5)
    export_model(bm, "motel_strip_l_shape", mats)

    # -------------------------------------------------------------------------
    # 4. COMMERCIAL & RETAIL (10 Models)
    # -------------------------------------------------------------------------
    
    # 4.1 gas_station_fuel_canopy
    clear_scene()
    mats = get_building_materials()
    bm = bmesh.new()
    add_box(bm, (0, 4.0, 0.25), (10.0, 6.0, 0.5), mat_idx=0)
    add_box(bm, (0, 4.0, 2.2), (9.2, 5.2, 3.6), mat_idx=2) # Convenience store
    # Fuel canopy
    add_box(bm, (0, -4.0, 0.15), (14.0, 8.0, 0.3), mat_idx=0) # Pump island pad
    for px in [-4.0, 4.0]:
        add_cyl(bm, (px, -4.0, 2.4), radius=0.25, height=4.5, axis='Z', mat_idx=3)
        add_box(bm, (px, -4.0, 0.8), (1.2, 0.6, 1.4), mat_idx=9) # Fuel pumps
    add_box(bm, (0, -4.0, 4.8), (14.5, 8.5, 0.6), mat_idx=9) # Red canopy roof
    export_model(bm, "gas_station_fuel_canopy", mats)

    # 4.2 diner_retro_roadside
    clear_scene()
    mats = get_building_materials()
    bm = bmesh.new()
    add_box(bm, (0, 0, 0.25), (12.0, 6.0, 0.5), mat_idx=0)
    add_box(bm, (0, 0, 2.2), (11.2, 5.2, 3.6), mat_idx=3) # Stainless steel modular body
    add_box(bm, (0, 0, 4.1), (11.6, 5.6, 0.4), mat_idx=9) # Red accent trim
    add_window_stripes(bm, (0, 0, 2.2), (11.2, 5.2, 3.6), rows=1, cols=6, axis='Y', mat_idx=7)
    export_model(bm, "diner_retro_roadside", mats)

    # 4.3 convenience_store_corner
    clear_scene()
    mats = get_building_materials()
    bm = bmesh.new()
    add_box(bm, (0, 0, 0.25), (11.0, 9.0, 0.5), mat_idx=0)
    add_box(bm, (0, 0, 2.5), (10.2, 8.2, 4.2), mat_idx=1)
    add_box(bm, (0, -4.2, 2.0), (8.0, 0.1, 2.8), mat_idx=7) # Front glass window
    add_box(bm, (0, 0, 4.8), (10.6, 8.6, 0.4), mat_idx=9)
    add_roof_hvac(bm, (0, 0, 5.0), count=2)
    export_model(bm, "convenience_store_corner", mats)

    # 4.4 strip_mall_retail_row
    clear_scene()
    mats = get_building_materials()
    bm = bmesh.new()
    add_box(bm, (0, 0, 0.3), (26.0, 10.0, 0.6), mat_idx=0)
    add_box(bm, (0, 0, 3.0), (25.0, 9.0, 5.2), mat_idx=2)
    add_box(bm, (0, -4.6, 2.0), (24.0, 0.1, 3.2), mat_idx=7) # Retail storefront glass
    add_box(bm, (0, -4.8, 3.8), (24.5, 1.2, 0.3), mat_idx=9) # Overhanging awning
    add_roof_hvac(bm, (0, 0, 5.8), count=4)
    export_model(bm, "strip_mall_retail_row", mats)

    # 4.5 bank_branch_vault
    clear_scene()
    mats = get_building_materials()
    bm = bmesh.new()
    add_box(bm, (0, 0, 0.4), (14.0, 12.0, 0.8), mat_idx=0)
    add_box(bm, (0, 0, 3.2), (13.0, 11.0, 5.4), mat_idx=1) # Brick bank building
    # Classical entryway with 4 columns
    for cx in [-4.0, -1.3, 1.3, 4.0]:
        add_cyl(bm, (cx, -5.8, 3.0), radius=0.35, height=5.2, axis='Z', mat_idx=0)
    add_box(bm, (0, -5.8, 5.8), (10.0, 1.5, 0.6), mat_idx=0)
    add_roof_hvac(bm, (0, 0, 6.2), count=2)
    export_model(bm, "bank_branch_vault", mats)

    # 4.6 post_office_civic
    clear_scene()
    mats = get_building_materials()
    bm = bmesh.new()
    add_box(bm, (0, 0, 0.35), (13.0, 11.0, 0.7), mat_idx=0)
    add_box(bm, (0, 0, 3.0), (12.2, 10.2, 5.0), mat_idx=2) # Civic stucco
    add_box(bm, (0, -5.2, 1.8), (4.0, 0.1, 2.6), mat_idx=7) # Public entrance
    add_loading_dock(bm, (0, 5.15, 0.0), width=4.0, height=3.0, depth=1.4) # Mail truck dock
    export_model(bm, "post_office_civic", mats)

    # 4.7 fast_food_burger_drive_thru
    clear_scene()
    mats = get_building_materials()
    bm = bmesh.new()
    add_box(bm, (0, 0, 0.25), (12.0, 8.5, 0.5), mat_idx=0)
    add_box(bm, (0, 0, 2.4), (11.2, 7.7, 4.0), mat_idx=2)
    add_box(bm, (0, 0, 4.6), (11.6, 8.1, 0.5), mat_idx=9) # Bright red roof mansard
    add_box(bm, (5.7, 0, 2.0), (0.2, 1.4, 1.6), mat_idx=7) # Drive-thru pickup window
    add_roof_hvac(bm, (0, 0, 4.9), count=2)
    export_model(bm, "fast_food_burger_drive_thru", mats)

    # 4.8 auto_body_mechanic_garage
    clear_scene()
    mats = get_building_materials()
    bm = bmesh.new()
    add_box(bm, (0, 0, 0.3), (16.0, 11.0, 0.6), mat_idx=0)
    add_box(bm, (0, 0, 3.2), (15.2, 10.2, 5.6), mat_idx=3)
    add_roof_gable(bm, (0, 0, 6.0), width=15.2, length=10.2, height=1.8, axis='X', mat_idx=5)
    for bx in [-4.5, 0.0, 4.5]:
        add_box(bm, (bx, -5.15, 2.2), (3.4, 0.1, 3.8), mat_idx=8) # Rollup service bays
    export_model(bm, "auto_body_mechanic_garage", mats)

    # 4.9 pharmacy_drive_thru
    clear_scene()
    mats = get_building_materials()
    bm = bmesh.new()
    add_box(bm, (0, 0, 0.3), (14.0, 10.0, 0.6), mat_idx=0)
    add_box(bm, (-1.5, 0, 2.8), (10.5, 9.2, 4.8), mat_idx=2)
    add_box(bm, (5.0, 0, 2.8), (3.0, 9.2, 0.4), mat_idx=3) # Drive-thru canopy
    add_cyl(bm, (5.5, -3.5, 1.4), radius=0.2, height=2.8, axis='Z', mat_idx=8)
    add_cyl(bm, (5.5, 3.5, 1.4), radius=0.2, height=2.8, axis='Z', mat_idx=8)
    export_model(bm, "pharmacy_drive_thru", mats)

    # 4.10 supermarket_anchor_store
    clear_scene()
    mats = get_building_materials()
    bm = bmesh.new()
    add_box(bm, (0, 0, 0.4), (28.0, 20.0, 0.8), mat_idx=0)
    add_box(bm, (0, 0, 4.2), (27.0, 19.0, 7.4), mat_idx=2)
    add_box(bm, (0, -9.6, 2.5), (18.0, 0.1, 4.0), mat_idx=7) # Front entrance glass
    add_loading_dock(bm, (-8.0, 9.6, 0.0), width=5.0, height=3.5, depth=1.8)
    add_roof_hvac(bm, (0, 0, 8.2), count=5)
    export_model(bm, "supermarket_anchor_store", mats)

    # -------------------------------------------------------------------------
    # 5. CIVIC & INSTITUTIONAL (10 Models)
    # -------------------------------------------------------------------------
    
    # 5.1 hospital_main_complex
    clear_scene()
    mats = get_building_materials()
    bm = bmesh.new()
    add_box(bm, (0, 0, 0.6), (28.0, 22.0, 1.2), mat_idx=0)
    add_box(bm, (0, 0, 10.0), (22.0, 18.0, 18.0), mat_idx=2) # 6-story main hospital
    add_box(bm, (-8.0, -4.0, 6.0), (10.0, 10.0, 10.0), mat_idx=2) # Side clinical wing
    # Helipad on roof
    add_box(bm, (0, 0, 19.2), (10.0, 10.0, 0.4), mat_idx=0)
    add_cyl(bm, (0, 0, 19.45), radius=3.5, height=0.05, axis='Z', mat_idx=9) # Red H circle
    # Red cross emblem on facade
    add_box(bm, (0, -9.1, 15.0), (2.4, 0.1, 0.8), mat_idx=9)
    add_box(bm, (0, -9.1, 15.0), (0.8, 0.1, 2.4), mat_idx=9)
    add_window_stripes(bm, (0, 0, 10.0), (22.0, 18.0, 18.0), rows=6, cols=7, axis='Y', mat_idx=7)
    add_roof_hvac(bm, (6.0, 4.0, 19.4), count=3)
    export_model(bm, "hospital_main_complex", mats)

    # 5.2 hospital_emergency_er_wing
    clear_scene()
    mats = get_building_materials()
    bm = bmesh.new()
    add_box(bm, (0, 0, 0.4), (20.0, 14.0, 0.8), mat_idx=0)
    add_box(bm, (0, 0, 4.5), (19.0, 13.0, 8.0), mat_idx=2)
    # Ambulance drop-off canopy
    add_box(bm, (0, -7.5, 0.2), (12.0, 5.0, 0.4), mat_idx=0)
    add_box(bm, (0, -7.5, 4.0), (13.0, 5.5, 0.5), mat_idx=9) # Red ER canopy
    add_cyl(bm, (-5.5, -9.5, 2.0), radius=0.25, height=4.0, axis='Z', mat_idx=8)
    add_cyl(bm, (5.5, -9.5, 2.0), radius=0.25, height=4.0, axis='Z', mat_idx=8)
    add_window_stripes(bm, (0, 0, 4.5), (19.0, 13.0, 8.0), rows=2, cols=6, axis='Y', mat_idx=7)
    export_model(bm, "hospital_emergency_er_wing", mats)

    # 5.3 clinic_urgent_care
    clear_scene()
    mats = get_building_materials()
    bm = bmesh.new()
    add_box(bm, (0, 0, 0.3), (15.0, 10.0, 0.6), mat_idx=0)
    add_box(bm, (0, 0, 3.0), (14.2, 9.2, 5.2), mat_idx=1) # Brick medical clinic
    add_box(bm, (0, -4.7, 2.0), (4.5, 0.1, 2.8), mat_idx=7) # Glass entrance
    add_box(bm, (0, 0, 5.8), (14.6, 9.6, 0.4), mat_idx=0)
    add_roof_hvac(bm, (0, 0, 6.0), count=2)
    export_model(bm, "clinic_urgent_care", mats)

    # 5.4 school_brick_elementary
    clear_scene()
    mats = get_building_materials()
    bm = bmesh.new()
    add_box(bm, (0, 0, 0.4), (26.0, 14.0, 0.8), mat_idx=0)
    add_box(bm, (0, 0, 4.5), (25.0, 13.0, 8.0), mat_idx=1) # 2-story brick school
    # Center clock / bell tower
    add_box(bm, (0, -3.0, 10.0), (5.0, 5.0, 4.0), mat_idx=1)
    add_roof_hipped(bm, (0, -3.0, 12.0), width=5.0, length=5.0, height=2.0, mat_idx=5)
    add_roof_hipped(bm, (0, 0, 8.5), width=25.0, length=13.0, height=3.0, mat_idx=5)
    add_window_stripes(bm, (0, 0, 4.5), (25.0, 13.0, 8.0), rows=2, cols=8, axis='Y', mat_idx=7)
    export_model(bm, "school_brick_elementary", mats)

    # 5.5 police_station_lockup
    clear_scene()
    mats = get_building_materials()
    bm = bmesh.new()
    add_box(bm, (0, 0, 0.4), (16.0, 12.0, 0.8), mat_idx=0)
    add_box(bm, (0, 0, 4.2), (15.2, 11.2, 7.4), mat_idx=2)
    add_box(bm, (0, -5.7, 2.0), (5.0, 0.1, 3.2), mat_idx=8) # Armored entrance
    add_cyl(bm, (6.0, 4.0, 9.0), radius=0.1, height=4.0, axis='Z', mat_idx=8) # Radio antenna
    add_roof_hvac(bm, (0, 0, 8.1), count=2)
    export_model(bm, "police_station_lockup", mats)

    # 5.6 fire_station_engine_bays
    clear_scene()
    mats = get_building_materials()
    bm = bmesh.new()
    add_box(bm, (0, 0, 0.4), (18.0, 14.0, 0.8), mat_idx=0)
    add_box(bm, (0, 0, 4.0), (17.2, 13.2, 7.0), mat_idx=1) # Red brick firehouse
    # 3 big red engine garage bays
    for bx in [-5.0, 0.0, 5.0]:
        add_box(bm, (bx, -6.65, 2.5), (4.0, 0.1, 4.6), mat_idx=9)
    # Hose drying drill tower
    add_box(bm, (6.0, 4.0, 8.5), (3.6, 3.6, 11.0), mat_idx=1)
    add_roof_hipped(bm, (6.0, 4.0, 14.0), width=3.6, length=3.6, height=1.6, mat_idx=5)
    export_model(bm, "fire_station_engine_bays", mats)

    # 5.7 city_hall_colonnade
    clear_scene()
    mats = get_building_materials()
    bm = bmesh.new()
    add_box(bm, (0, 0, 0.6), (22.0, 16.0, 1.2), mat_idx=0)
    add_box(bm, (0, 0, 5.5), (20.5, 14.5, 9.6), mat_idx=2) # Stone municipal hall
    # 6 Monumental Columns
    for cx in [-7.5, -4.5, -1.5, 1.5, 4.5, 7.5]:
        add_cyl(bm, (cx, -7.5, 5.0), radius=0.45, height=8.6, axis='Z', mat_idx=0)
    add_roof_gable(bm, (0, -7.5, 9.5), width=18.0, length=2.0, height=2.2, axis='X', mat_idx=0)
    # Central dome
    add_cyl(bm, (0, 0, 12.0), radius=3.2, height=3.5, axis='Z', segments=16, mat_idx=3)
    export_model(bm, "city_hall_colonnade", mats)

    # 5.8 church_chapel_bell_tower
    clear_scene()
    mats = get_building_materials()
    bm = bmesh.new()
    add_box(bm, (0, 0, 0.4), (12.0, 18.0, 0.8), mat_idx=0)
    add_box(bm, (0, 2.0, 4.2), (11.0, 13.0, 7.4), mat_idx=2) # Nave
    add_roof_gable(bm, (0, 2.0, 7.9), width=11.0, length=13.0, height=4.2, axis='Y', mat_idx=5)
    # Bell tower & steeple
    add_box(bm, (0, -6.5, 7.0), (4.5, 4.5, 13.0), mat_idx=2)
    add_cyl(bm, (0, -6.5, 17.5), radius=2.4, height=8.0, axis='Z', segments=8, mat_idx=5) # Spire
    export_model(bm, "church_chapel_bell_tower", mats)

    # 5.9 library_municipal
    clear_scene()
    mats = get_building_materials()
    bm = bmesh.new()
    add_box(bm, (0, 0, 0.4), (18.0, 14.0, 0.8), mat_idx=0)
    add_box(bm, (0, 0, 4.0), (17.0, 13.0, 7.0), mat_idx=1)
    add_box(bm, (0, -6.6, 2.5), (6.0, 0.1, 4.0), mat_idx=7) # Glass entrance atrium
    add_roof_hipped(bm, (0, 0, 7.5), width=17.0, length=13.0, height=2.4, mat_idx=5)
    export_model(bm, "library_municipal", mats)

    # 5.10 courthouse_classical_steps
    clear_scene()
    mats = get_building_materials()
    bm = bmesh.new()
    add_box(bm, (0, 0, 0.75), (24.0, 18.0, 1.5), mat_idx=0) # Grand plinth
    add_box(bm, (0, 2.0, 6.0), (22.0, 13.0, 10.5), mat_idx=2)
    # Front staircase
    for st in range(5):
        add_box(bm, (0, -7.0 - (st * 0.6), 0.75 - (st * 0.15)), (14.0, 0.6, 0.3), mat_idx=0)
    for cx in [-5.0, -2.5, 0.0, 2.5, 5.0]:
        add_cyl(bm, (cx, -6.0, 5.8), radius=0.45, height=9.0, axis='Z', mat_idx=0)
    add_roof_gable(bm, (0, -6.0, 10.5), width=14.0, length=2.0, height=2.4, axis='X', mat_idx=0)
    export_model(bm, "courthouse_classical_steps", mats)

    # -------------------------------------------------------------------------
    # 6. INDUSTRIAL & LOGISTICS (10 Models)
    # -------------------------------------------------------------------------
    
    # 6.1 warehouse_small_quonset
    clear_scene()
    mats = get_building_materials()
    bm = bmesh.new()
    add_box(bm, (0, 0, 0.25), (10.0, 14.0, 0.5), mat_idx=0)
    # Barrel vault / Quonset arch
    add_cyl(bm, (0, 0, 0.5), radius=4.5, height=13.2, axis='Y', segments=16, mat_idx=3)
    add_box(bm, (0, -6.65, 1.8), (3.6, 0.1, 3.2), mat_idx=8) # Rollup door
    export_model(bm, "warehouse_small_quonset", mats)

    # 6.2 warehouse_distribution_dock
    clear_scene()
    mats = get_building_materials()
    bm = bmesh.new()
    add_box(bm, (0, 0, 0.4), (28.0, 18.0, 0.8), mat_idx=0)
    add_box(bm, (0, 0, 4.2), (27.0, 17.0, 7.4), mat_idx=3) # Metal warehouse
    # 4 Truck loading docks
    for lx in [-9.0, -3.0, 3.0, 9.0]:
        add_loading_dock(bm, (lx, -8.55, 0.0), width=4.2, height=3.5, depth=1.6)
    add_roof_hvac(bm, (0, 0, 8.1), count=4)
    export_model(bm, "warehouse_distribution_dock", mats)

    # 6.3 hangar_aircraft_barrel_roof
    clear_scene()
    mats = get_building_materials()
    bm = bmesh.new()
    add_box(bm, (0, 0, 0.35), (24.0, 20.0, 0.7), mat_idx=0)
    add_box(bm, (0, 0, 3.5), (23.0, 19.0, 6.0), mat_idx=3)
    add_cyl(bm, (0, 0, 6.5), radius=8.0, height=18.8, axis='Y', segments=20, mat_idx=3) # Barrel roof
    add_box(bm, (0, -9.55, 3.5), (18.0, 0.1, 6.5), mat_idx=8) # Giant aircraft hangar door
    export_model(bm, "hangar_aircraft_barrel_roof", mats)

    # 6.4 factory_sawtooth_roof
    clear_scene()
    mats = get_building_materials()
    bm = bmesh.new()
    add_box(bm, (0, 0, 0.4), (24.0, 16.0, 0.8), mat_idx=0)
    add_box(bm, (0, 0, 3.5), (23.0, 15.0, 6.0), mat_idx=1) # Brick manufacturing plant
    # 4 Sawtooth northlight roof ridges
    for s in range(4):
        sy = -6.0 + (s * 4.0)
        add_roof_gable(bm, (0, sy, 6.5), width=23.0, length=3.5, height=2.2, axis='X', mat_idx=5)
    add_loading_dock(bm, (8.0, -7.55, 0.0), width=4.5, height=3.2, depth=1.4)
    export_model(bm, "factory_sawtooth_roof", mats)

    # 6.5 factory_brick_smokestacks
    clear_scene()
    mats = get_building_materials()
    bm = bmesh.new()
    add_box(bm, (0, 0, 0.4), (22.0, 14.0, 0.8), mat_idx=0)
    add_box(bm, (0, 0, 4.0), (21.0, 13.0, 7.0), mat_idx=1)
    # Twin industrial smokestacks
    add_cyl(bm, (7.0, 3.5, 12.0), radius=1.2, height=18.0, axis='Z', segments=14, mat_idx=1)
    add_cyl(bm, (7.0, -3.5, 12.0), radius=1.2, height=18.0, axis='Z', segments=14, mat_idx=1)
    # White/Red warning rings on top
    add_cyl(bm, (7.0, 3.5, 20.0), radius=1.25, height=1.5, axis='Z', segments=14, mat_idx=9)
    add_cyl(bm, (7.0, -3.5, 20.0), radius=1.25, height=1.5, axis='Z', segments=14, mat_idx=9)
    export_model(bm, "factory_brick_smokestacks", mats)

    # 6.6 oil_storage_tank_battery
    clear_scene()
    mats = get_building_materials()
    bm = bmesh.new()
    add_box(bm, (0, 0, 0.4), (22.0, 16.0, 0.8), mat_idx=0) # Containment berm
    for tx in [-6.0, 6.0]:
        for ty in [-4.0, 4.0]:
            add_cyl(bm, (tx, ty, 4.5), radius=3.2, height=8.0, axis='Z', segments=18, mat_idx=3)
            add_cyl(bm, (tx, ty, 8.7), radius=3.25, height=0.4, axis='Z', segments=18, mat_idx=5)
    # Interconnecting pipes
    add_cyl(bm, (0, 0, 3.0), radius=0.2, height=12.0, axis='X', mat_idx=8)
    export_model(bm, "oil_storage_tank_battery", mats)

    # 6.7 electrical_substation_switchyard
    clear_scene()
    mats = get_building_materials()
    bm = bmesh.new()
    add_box(bm, (0, 0, 0.2), (18.0, 14.0, 0.4), mat_idx=0) # Gravel switchyard pad
    # Control building
    add_box(bm, (-5.5, 0, 1.8), (5.0, 7.0, 3.2), mat_idx=1)
    # 2 Heavy step-up transformers with cooling radiators
    for tx in [2.0, 6.0]:
        add_box(bm, (tx, 0, 1.8), (2.6, 3.2, 3.2), mat_idx=8)
        # Bushing ceramic insulators
        add_cyl(bm, (tx, -0.8, 3.8), radius=0.2, height=1.2, axis='Z', mat_idx=9)
        add_cyl(bm, (tx, 0.8, 3.8), radius=0.2, height=1.2, axis='Z', mat_idx=9)
    export_model(bm, "electrical_substation_switchyard", mats)

    # 6.8 grain_elevator_concrete_tower
    clear_scene()
    mats = get_building_materials()
    bm = bmesh.new()
    add_box(bm, (0, 0, 0.6), (18.0, 12.0, 1.2), mat_idx=0)
    # Battery of 6 tall concrete silos
    for sx in [-4.0, 0.0, 4.0]:
        for sy in [-2.5, 2.5]:
            add_cyl(bm, (sx, sy, 10.0), radius=2.0, height=18.0, axis='Z', segments=16, mat_idx=0)
    # Headhouse work tower
    add_box(bm, (0, 0, 21.0), (10.0, 6.0, 5.0), mat_idx=3)
    export_model(bm, "grain_elevator_concrete_tower", mats)

    # 6.9 cooling_tower_hyperbolic
    clear_scene()
    mats = get_building_materials()
    bm = bmesh.new()
    add_box(bm, (0, 0, 0.5), (18.0, 18.0, 1.0), mat_idx=0)
    # Hyperbolic cooling tower stack
    start_f = len(bm.faces)
    bmesh.ops.create_cone(bm, cap_ends=False, cap_tris=False, segments=24,
                          radius1=7.0, radius2=4.8, depth=22.0,
                          matrix=mathutils.Matrix.Translation((0, 0, 11.5)))
    for f in bm.faces[start_f:]:
        f.material_index = 0
    export_model(bm, "cooling_tower_hyperbolic", mats)

    # 6.10 water_tower_lattice_steel
    clear_scene()
    mats = get_building_materials()
    bm = bmesh.new()
    add_box(bm, (0, 0, 0.4), (8.0, 8.0, 0.8), mat_idx=0)
    # 4 Steel lattice legs
    for lx, ly in [(-2.5, -2.5), (2.5, -2.5), (2.5, 2.5), (-2.5, 2.5)]:
        add_cyl(bm, (lx, ly, 8.5), radius=0.18, height=16.0, axis='Z', mat_idx=8)
    # Center riser pipe
    add_cyl(bm, (0, 0, 8.5), radius=0.45, height=16.0, axis='Z', mat_idx=8)
    # Spherical/cylindrical tank
    add_cyl(bm, (0, 0, 19.5), radius=4.2, height=5.5, axis='Z', segments=20, mat_idx=3)
    add_cyl(bm, (0, 0, 22.8), radius=4.3, height=1.2, axis='Z', segments=20, mat_idx=9) # Red aviation stripe
    export_model(bm, "water_tower_lattice_steel", mats)

    print("==================================================")
    print("  ALL 60 BUILDING MODELS GENERATED SUCCESSFULLY!")
    print("==================================================")


if __name__ == "__main__":
    generate_all_buildings()
