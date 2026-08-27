"""
build_terrain_props.py (Volumetric Foliage & Matte Zero-Shine Terrain Props Engine)
Generates 36 authentic volumetric trees, 3 lumber node stands, 35 geological rocks,
6 wide carpet grass turf mats, 4 shrubs, 3 cattails/reeds, and 3 wildflowers.

Key Features:
1. Volumetric canopy puffs (organic 3D leafy lobes with spherical upward-biased normals,
   eliminating all planar cards and spiky fin artifacts).
2. Tiered horizontal conifer bough skirts with realistic downward gravitational droop.
3. Arched palm fronds and vertical cascading weeping willow ribbons.
4. Strictly matte bark (Roughness=0.98, Specular=0.0, Metallic=0.0, zero shiny spots).
5. Wide carpet lawn turf mats (1.1m diameter, 32 blades, 0.20m height).
"""

import bpy
import bmesh
from mathutils import Vector, Matrix
import math
import random
import os
import numpy as np

OUTPUT_DIR = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
TERRAIN_DIR = os.path.join(OUTPUT_DIR, "assets", "models", "terrain")


# ---------------------------------------------------------------------------
# 3D Noise Utilities
# ---------------------------------------------------------------------------

def organic_noise_3d(x, y, z, seed=0):
    """Produces smooth, multi-octave continuous 3D noise for organic displacement."""
    rng = random.Random(seed)
    phase_x = rng.uniform(0, 100)
    phase_y = rng.uniform(0, 100)
    phase_z = rng.uniform(0, 100)

    sx = x + phase_x
    sy = y + phase_y
    sz = z + phase_z

    n1 = math.sin(sx * 1.7 + sz * 1.3) * math.cos(sy * 1.5 + sx * 0.8)
    n2 = math.sin(sy * 3.4 - sz * 3.1) * math.cos(sx * 3.2 + sy * 2.4)
    n3 = math.sin(sx * 7.3 + sz * 6.5) * math.cos(sy * 6.9 - sx * 5.1)
    
    return n1 * 0.55 + n2 * 0.32 + n3 * 0.13


def clear_scene():
    """Purges all objects, meshes, materials, textures, and images between prop builds."""
    bpy.ops.object.select_all(action='SELECT')
    bpy.ops.object.delete(use_global=False)
    for block in (bpy.data.meshes, bpy.data.materials, bpy.data.textures, bpy.data.images):
        for item in list(block):
            if item.users == 0:
                block.remove(item)


# ---------------------------------------------------------------------------
# Procedural PBR Texture & Material Engine (Zero Shine & Matte Bark)
# ---------------------------------------------------------------------------

def make_pbr_image(name, width, height, pixels_rgba, is_data=False):
    """Creates a Blender image datablock, populates pixel float buffer, sets color space, and packs it."""
    img = bpy.data.images.new(name, width=width, height=height, alpha=True)
    img.pixels.foreach_set(np.ascontiguousarray(pixels_rgba, dtype=np.float32).flatten())
    if is_data:
        img.colorspace_settings.name = 'Non-Color'
    img.pack()
    return img


def create_node_material(name, img_albedo, img_rough, img_norm, metallic=0.0, normal_strength=0.25, is_foliage=False):
    """Assembles a full PBR Principled BSDF material node tree with ZERO specular shine on bark."""
    mat = bpy.data.materials.new(name=name)
    mat.use_nodes = True
    nodes = mat.node_tree.nodes
    links = mat.node_tree.links
    bsdf = nodes.get("Principled BSDF")

    # 1. Albedo map + Alpha
    tex_alb = nodes.new("ShaderNodeTexImage")
    tex_alb.image = img_albedo
    links.new(tex_alb.outputs["Color"], bsdf.inputs["Base Color"])
    if is_foliage:
        links.new(tex_alb.outputs["Alpha"], bsdf.inputs["Alpha"])
        try:
            mat.blend_method = 'CLIP'
            mat.alpha_threshold = 0.35
        except Exception:
            pass

    # 2. Roughness map (matte wood / foliage = 0.98, zero specular reflections)
    tex_r = nodes.new("ShaderNodeTexImage")
    tex_r.image = img_rough
    links.new(tex_r.outputs["Color"], bsdf.inputs["Roughness"])

    # 3. Normal map (soft, subtle normal strength to prevent glancing specular spikes)
    tex_n = nodes.new("ShaderNodeTexImage")
    tex_n.image = img_norm
    norm_map = nodes.new("ShaderNodeNormalMap")
    norm_map.inputs["Strength"].default_value = normal_strength
    links.new(tex_n.outputs["Color"], norm_map.inputs["Color"])
    links.new(norm_map.outputs["Normal"], bsdf.inputs["Normal"])

    # 4. Zero Metallic & Zero Specular (eliminates all white shiny spots)
    if "Metallic" in bsdf.inputs:
        bsdf.inputs["Metallic"].default_value = metallic
    if "Specular IOR Level" in bsdf.inputs:
        bsdf.inputs["Specular IOR Level"].default_value = 0.0
    elif "Specular" in bsdf.inputs:
        bsdf.inputs["Specular"].default_value = 0.0

    return mat


def build_bark_pbr_material(name, base_color=(0.28, 0.20, 0.14), roughness=0.98, seed=0, is_birch=False):
    """Generates procedural bark PBR textures with soft matte finish and zero specular shine."""
    rng = np.random.default_rng(seed)
    w, h = 128, 128
    y, x = np.mgrid[0:h, 0:w]

    grain_freq = 12.0
    grain = np.sin(x * (2.0 * math.pi / w * grain_freq) + np.sin(y * 0.2) * 1.2) * 0.035
    furrow = np.sin(x * (2.0 * math.pi / w * 3.0) + rng.uniform(-1, 1)) * 0.045
    noise = rng.normal(0, 0.015, (h, w))

    albedo = np.zeros((h, w, 4), dtype=np.float32)
    if is_birch:
        lenticels = np.zeros((h, w), dtype=np.float32)
        for _ in range(16):
            ly = rng.integers(6, h - 6)
            lx = rng.integers(0, w)
            lw = rng.integers(6, 24)
            lh = rng.integers(1, 3)
            for dy in range(-lh, lh + 1):
                for dx in range(-lw, lw + 1):
                    px = (lx + dx) % w
                    py = np.clip(ly + dy, 0, h - 1)
                    dist = (dx / (lw + 0.1))**2 + (dy / (lh + 0.1))**2
                    if dist <= 1.0:
                        lenticels[py, px] = max(lenticels[py, px], (1.0 - dist) * 0.52)
        for c in range(3):
            albedo[:, :, c] = np.clip(base_color[c] + grain * 0.3 + noise - lenticels, 0.08, 0.95)
    else:
        for c in range(3):
            albedo[:, :, c] = np.clip(base_color[c] + grain + furrow + noise, 0.03, 0.95)
    albedo[:, :, 3] = 1.0

    img_albedo = make_pbr_image(name + "_albedo", w, h, albedo, is_data=False)

    # Strictly matte roughness (0.96 - 0.99)
    rough_val = np.clip(roughness + furrow * 0.1 + noise * 0.1, 0.95, 0.99).astype(np.float32)
    rough_data = np.dstack([rough_val, rough_val, rough_val, np.ones((h, w), dtype=np.float32)])
    img_rough = make_pbr_image(name + "_rough", w, h, rough_data, is_data=True)

    height_map = grain * 1.2 + furrow * 1.5 + noise * 0.8
    dx = np.roll(height_map, -1, axis=1) - np.roll(height_map, 1, axis=1)
    dy = np.roll(height_map, -1, axis=0) - np.roll(height_map, 1, axis=0)
    nx = -dx * 1.2
    ny = -dy * 1.2
    nz = np.ones((h, w), dtype=np.float32)
    n_len = np.sqrt(nx*nx + ny*ny + nz*nz)
    nx /= n_len; ny /= n_len; nz /= n_len

    norm_data = np.dstack([nx*0.5 + 0.5, ny*0.5 + 0.5, nz*0.5 + 0.5, np.ones((h, w), dtype=np.float32)])
    img_norm = make_pbr_image(name + "_norm", w, h, norm_data, is_data=True)

    return create_node_material(name, img_albedo, img_rough, img_norm, metallic=0.0, normal_strength=0.25, is_foliage=False)


def build_foliage_alpha_material(name, base_color=(0.18, 0.35, 0.15), species_type="broadleaf", seed=0):
    """Generates procedural rich organic leaf PBR textures with soft sunlight gradients and matte finish."""
    rng = np.random.default_rng(seed)
    w, h = 256, 256
    y, x = np.mgrid[0:h, 0:w]

    uv_y = y / float(h)

    # Leaf dapple pattern
    dapple = rng.normal(0, 0.04, (h, w)).astype(np.float32)
    sun_grad = (1.0 - uv_y * 0.35) # Sunlit top gradient

    albedo = np.zeros((h, w, 4), dtype=np.float32)
    for c in range(3):
        c_tint = sun_grad if c != 0 else sun_grad * 0.95
        albedo[:, :, c] = np.clip(base_color[c] * c_tint + dapple * 0.8, 0.04, 0.95)
    albedo[:, :, 3] = 1.0

    img_albedo = make_pbr_image(name + "_albedo", w, h, albedo, is_data=False)

    # Matte leaf roughness (0.96 - 0.99)
    rough_val = np.clip(0.97 + dapple * 0.2, 0.95, 0.99).astype(np.float32)
    rough_data = np.dstack([rough_val, rough_val, rough_val, np.ones((h, w), dtype=np.float32)])
    img_rough = make_pbr_image(name + "_rough", w, h, rough_data, is_data=True)

    # Subtle soft leaf normal map
    dx = np.roll(dapple, -1, axis=1) - np.roll(dapple, 1, axis=1)
    dy = np.roll(dapple, -1, axis=0) - np.roll(dapple, 1, axis=0)
    nx = -dx * 1.2
    ny = -dy * 1.2
    nz = np.ones((h, w), dtype=np.float32)
    n_len = np.sqrt(nx*nx + ny*ny + nz*nz)
    nx /= n_len; ny /= n_len; nz /= n_len

    norm_data = np.dstack([nx*0.5 + 0.5, ny*0.5 + 0.5, nz*0.5 + 0.5, np.ones((h, w), dtype=np.float32)])
    img_norm = make_pbr_image(name + "_norm", w, h, norm_data, is_data=True)

    return create_node_material(name, img_albedo, img_rough, img_norm, metallic=0.0, normal_strength=0.35, is_foliage=False)


def build_rock_pbr_material(name, base_color=(0.42, 0.40, 0.38), roughness=0.92, metallic=0.0, seed=0, strata_freq=28.0):
    """Generates procedural stone PBR textures with strata layering, mineral flecks, and chiseled facets."""
    rng = np.random.default_rng(seed)
    w, h = 128, 128
    y, x = np.mgrid[0:h, 0:w]

    strata = np.sin(y * (2.0 * math.pi / strata_freq) + rng.uniform(-0.5, 0.5)) * 0.04
    fine_noise = rng.normal(0, 0.03, (h, w))
    coarse_noise = rng.uniform(-0.025, 0.025, (h, w))
    flecks = (rng.uniform(0, 1, (h, w)) > 0.95).astype(np.float32) * 0.08

    albedo = np.zeros((h, w, 4), dtype=np.float32)
    for c in range(3):
        albedo[:, :, c] = np.clip(base_color[c] + strata + fine_noise + coarse_noise + flecks, 0.04, 0.96)
    albedo[:, :, 3] = 1.0
    img_albedo = make_pbr_image(name + "_albedo", w, h, albedo, is_data=False)

    rough_val = np.clip(roughness + fine_noise * 1.2 - flecks * 2.0, 0.75, 0.98).astype(np.float32)
    rough_data = np.dstack([rough_val, rough_val, rough_val, np.ones((h, w), dtype=np.float32)])
    img_rough = make_pbr_image(name + "_rough", w, h, rough_data, is_data=True)

    height_map = strata * 2.8 + fine_noise * 2.5 + coarse_noise * 3.0
    dx = np.roll(height_map, -1, axis=1) - np.roll(height_map, 1, axis=1)
    dy = np.roll(height_map, -1, axis=0) - np.roll(height_map, 1, axis=0)
    nx = -dx * 2.5
    ny = -dy * 2.5
    nz = np.ones((h, w), dtype=np.float32)
    n_len = np.sqrt(nx*nx + ny*ny + nz*nz)
    nx /= n_len; ny /= n_len; nz /= n_len

    norm_data = np.dstack([nx*0.5 + 0.5, ny*0.5 + 0.5, nz*0.5 + 0.5, np.ones((h, w), dtype=np.float32)])
    img_norm = make_pbr_image(name + "_norm", w, h, norm_data, is_data=True)

    return create_node_material(name, img_albedo, img_rough, img_norm, metallic=metallic, normal_strength=0.75, is_foliage=False)


def build_grass_pbr_material(name, base_color=(0.28, 0.40, 0.20), roughness=0.95, seed=0):
    """Generates procedural grass blade PBR textures with longitudinal veining and tip gradients."""
    rng = np.random.default_rng(seed)
    w, h = 128, 128
    y, x = np.mgrid[0:h, 0:w]

    blade_vein = np.sin(x * (2.0 * math.pi / 8.0)) * 0.035
    length_grad = (y / float(h) - 0.5) * 0.05
    noise = rng.normal(0, 0.02, (h, w))

    albedo = np.zeros((h, w, 4), dtype=np.float32)
    for c in range(3):
        albedo[:, :, c] = np.clip(base_color[c] + blade_vein + length_grad + noise, 0.05, 0.95)
    albedo[:, :, 3] = 1.0
    img_albedo = make_pbr_image(name + "_albedo", w, h, albedo, is_data=False)

    rough_val = np.clip(roughness + noise * 0.5, 0.92, 0.99).astype(np.float32)
    rough_data = np.dstack([rough_val, rough_val, rough_val, np.ones((h, w), dtype=np.float32)])
    img_rough = make_pbr_image(name + "_rough", w, h, rough_data, is_data=True)

    height_map = blade_vein * 1.5 + noise * 1.0
    dx = np.roll(height_map, -1, axis=1) - np.roll(height_map, 1, axis=1)
    dy = np.roll(height_map, -1, axis=0) - np.roll(height_map, 1, axis=0)
    nx = -dx * 1.8
    ny = -dy * 1.8
    nz = np.ones((h, w), dtype=np.float32)
    n_len = np.sqrt(nx*nx + ny*ny + nz*nz)
    nx /= n_len; ny /= n_len; nz /= n_len

    norm_data = np.dstack([nx*0.5 + 0.5, ny*0.5 + 0.5, nz*0.5 + 0.5, np.ones((h, w), dtype=np.float32)])
    img_norm = make_pbr_image(name + "_norm", w, h, norm_data, is_data=True)

    return create_node_material(name, img_albedo, img_rough, img_norm, metallic=0.0, normal_strength=0.40, is_foliage=False)


# ---------------------------------------------------------------------------
# Mesh Finalization & Export
# ---------------------------------------------------------------------------

def unwrap_mesh(obj):
    """Applies smart UV projection across all non-card faces."""
    bpy.context.view_layer.objects.active = obj
    bpy.ops.object.select_all(action='DESELECT')
    obj.select_set(True)

    bpy.ops.object.mode_set(mode='EDIT')
    bpy.ops.mesh.select_all(action='SELECT')
    bpy.ops.uv.smart_project(
        angle_limit=math.radians(66.0),
        island_margin=0.02,
        area_weight=0.0,
        correct_aspect=True,
        scale_to_bounds=False
    )
    bpy.ops.object.mode_set(mode='OBJECT')


def finalize_mesh(bm, name, mat_builder, smooth=True, auto_smooth_angle=35):
    """Finalizes a single-material bmesh into an object with UV unwrapping and PBR material."""
    boundary = [e for e in bm.edges if len(e.link_faces) == 1]
    if boundary:
        bmesh.ops.holes_fill(bm, edges=boundary)
    bmesh.ops.recalc_face_normals(bm, faces=list(bm.faces))
    mesh_data = bpy.data.meshes.new(name + "_mesh")
    bm.to_mesh(mesh_data)
    bm.free()

    obj = bpy.data.objects.new(name, mesh_data)
    bpy.context.collection.objects.link(obj)
    bpy.context.view_layer.objects.active = obj
    obj.select_set(True)

    if smooth:
        bpy.ops.object.shade_smooth()
        try:
            obj.data.use_auto_smooth = True
            obj.data.auto_smooth_angle = math.radians(auto_smooth_angle)
        except Exception:
            pass
    else:
        bpy.ops.object.shade_flat()

    unwrap_mesh(obj)

    mat = mat_builder(name + "_mat")
    obj.data.materials.append(mat)
    return obj


def finalize_mesh_dual(bm, name, mat0_builder, mat1_builder, smooth=True, auto_smooth_angle=35):
    """Finalizes a dual-material bmesh into an object with both PBR materials."""
    bmesh.ops.recalc_face_normals(bm, faces=list(bm.faces))
    mesh_data = bpy.data.meshes.new(name + "_mesh")
    bm.to_mesh(mesh_data)
    bm.free()

    obj = bpy.data.objects.new(name, mesh_data)
    bpy.context.collection.objects.link(obj)
    bpy.context.view_layer.objects.active = obj
    obj.select_set(True)

    if smooth:
        bpy.ops.object.shade_smooth()
        try:
            obj.data.use_auto_smooth = True
            obj.data.auto_smooth_angle = math.radians(auto_smooth_angle)
        except Exception:
            pass
    else:
        bpy.ops.object.shade_flat()

    mat0 = mat0_builder(name + "_mat0")
    mat1 = mat1_builder(name + "_mat1")
    obj.data.materials.append(mat0)
    obj.data.materials.append(mat1)
    return obj


def export_glb(obj, filepath):
    """Exports the active object to standard GLB with embedded PBR textures and UV layers."""
    bpy.ops.object.select_all(action='DESELECT')
    obj.select_set(True)
    bpy.context.view_layer.objects.active = obj
    bpy.ops.export_scene.gltf(
        filepath=filepath,
        use_selection=True,
        export_format='GLB',
        export_yup=True,
        export_apply=True
    )
    print("Exported GLB: %s" % filepath)
    mesh_data = obj.data
    bpy.data.objects.remove(obj, do_unlink=True)
    if mesh_data and mesh_data.users == 0:
        bpy.data.meshes.remove(mesh_data)


# ---------------------------------------------------------------------------
# BMesh Primitive Helpers in Blender Z-Up Space
# ---------------------------------------------------------------------------

def add_cylinder_z(bm, center, radius_bottom, height, segments=8, radius_top=None):
    """Creates a vertical cylinder along +Z axis."""
    r_bot = radius_bottom
    r_top = radius_bottom if radius_top is None else radius_top
    half_h = height * 0.5
    z_bot = center[2] - half_h
    z_top = center[2] + half_h

    bot_verts = []
    top_verts = []
    for i in range(segments):
        theta = (2.0 * math.pi * i) / segments
        cx, cy = math.cos(theta), math.sin(theta)
        bot_verts.append(bm.verts.new((center[0] + cx * r_bot, center[1] + cy * r_bot, z_bot)))
        if r_top > 0.001:
            top_verts.append(bm.verts.new((center[0] + cx * r_top, center[1] + cy * r_top, z_top)))

    bm.verts.ensure_lookup_table()
    created_faces = []

    if r_top > 0.001:
        for i in range(segments):
            i_next = (i + 1) % segments
            created_faces.append(bm.faces.new([bot_verts[i], bot_verts[i_next], top_verts[i_next], top_verts[i]]))
        created_faces.append(bm.faces.new(top_verts))
    else:
        apex = bm.verts.new((center[0], center[1], z_top))
        for i in range(segments):
            i_next = (i + 1) % segments
            created_faces.append(bm.faces.new([bot_verts[i], bot_verts[i_next], apex]))

    created_faces.append(bm.faces.new(list(reversed(bot_verts))))
    return created_faces


def add_curved_trunk_segment(bm, p_start, p_end, r_start, r_end, segments=7):
    """Creates an authentic tapered limb segment connecting p_start and p_end."""
    p0 = Vector(p_start)
    p1 = Vector(p_end)
    axis = (p1 - p0).normalized()
    if axis.length_squared < 0.001:
        axis = Vector((0, 0, 1))

    ref = Vector((0, 0, 1)) if abs(axis.z) < 0.9 else Vector((0, 1, 0))
    right = axis.cross(ref).normalized()
    forward = axis.cross(right).normalized()

    v_bot = []
    v_top = []
    for i in range(segments):
        theta = (2.0 * math.pi * i) / segments
        cos_t, sin_t = math.cos(theta), math.sin(theta)
        radial = right * cos_t + forward * sin_t
        v_bot.append(bm.verts.new(p0 + radial * r_start))
        v_top.append(bm.verts.new(p1 + radial * r_end))

    bm.verts.ensure_lookup_table()
    faces = []
    for i in range(segments):
        i_next = (i + 1) % segments
        faces.append(bm.faces.new([v_bot[i], v_bot[i_next], v_top[i_next], v_top[i]]))
    return faces, v_bot, v_top


# ---------------------------------------------------------------------------
# Volumetric Canopy & Bough Geometry Builders (Zero Spikiness)
# ---------------------------------------------------------------------------

def add_foliage_puff(bm, center, radius, crown_center, uv_layer, rng=None, scale_z=0.82, noise_amp=0.18):
    """Creates a soft, rounded, volumetric 3D foliage puff with upward-biased spherical normals."""
    if rng is None:
        rng = random.Random(42)
    center_v = Vector(center)
    ret = bmesh.ops.create_icosphere(bm, subdivisions=2, radius=radius)
    verts = ret["verts"]
    
    for v in verts:
        disp = organic_noise_3d(v.co.x * 2.5, v.co.y * 2.5, v.co.z * 2.5, seed=rng.randint(0, 10000))
        v.co += v.co.normalized() * (disp * noise_amp * radius)
        v.co.z *= scale_z
        v.co += center_v
        
        # Soft pillowy spherical normal pointing outward with subtle upward sky bias
        v.normal = ((v.co - Vector(crown_center)).normalized() + Vector((0, 0, 0.28))).normalized()
        
    faces = {f for v in verts for f in v.link_faces}
    for f in faces:
        f.material_index = 1
        for loop in f.loops:
            n = (loop.vert.co - center_v).normalized()
            u = 0.5 + math.atan2(n.y, n.x) / (2.0 * math.pi)
            v_coord = 0.5 - math.asin(np.clip(n.z, -1.0, 1.0)) / math.pi
            loop[uv_layer].uv = Vector((u, v_coord))
    return faces


def add_conifer_skirt(bm, center, radius_base, height, crown_center, uv_layer, rng=None, segments=9, droop=0.35):
    """Creates an authentic tiered conifer bough skirt with downward drooping rim and volumetric thickness."""
    if rng is None:
        rng = random.Random(42)
    center_v = Vector(center)
    apex = bm.verts.new(center_v + Vector((0, 0, height)))
    rim_verts = []
    under_verts = []
    
    for i in range(segments):
        theta = (2.0 * math.pi * i) / float(segments) + rng.uniform(-0.08, 0.08)
        r = radius_base * rng.uniform(0.90, 1.10)
        rx = math.cos(theta) * r
        ry = math.sin(theta) * r
        rz = -droop * rng.uniform(0.85, 1.15)
        
        v_rim = bm.verts.new(center_v + Vector((rx, ry, rz)))
        v_under = bm.verts.new(center_v + Vector((rx * 0.72, ry * 0.72, rz + height * 0.25)))
        rim_verts.append(v_rim)
        under_verts.append(v_under)
        
    for v in [apex] + rim_verts + under_verts:
        v.normal = ((v.co - Vector(crown_center)).normalized() + Vector((0, 0, 0.22))).normalized()
        
    faces = []
    for i in range(segments):
        i_next = (i + 1) % segments
        # Top slope face
        f_top = bm.faces.new([apex, rim_verts[i], rim_verts[i_next]])
        f_top.material_index = 1
        faces.append(f_top)
        
        # Underside face
        f_bot = bm.faces.new([rim_verts[i], under_verts[i], under_verts[i_next], rim_verts[i_next]])
        f_bot.material_index = 1
        faces.append(f_bot)
        
        for f in (f_top, f_bot):
            for loop in f.loops:
                n = (loop.vert.co - center_v).normalized()
                u = 0.5 + math.atan2(n.y, n.x) / (2.0 * math.pi)
                v_coord = 0.5 - math.asin(np.clip(n.z, -1.0, 1.0)) / math.pi
                loop[uv_layer].uv = Vector((u, v_coord))
    return faces


def add_palm_frond(bm, start_pt, length, angle, crown_center, uv_layer, rng=None, segments=6):
    """Creates a smooth, downward-curving tropical palm frond ribbon."""
    if rng is None:
        rng = random.Random(42)
    start_v = Vector(start_pt)
    frond_verts_left = []
    frond_verts_right = []
    
    for s in range(segments + 1):
        t = float(s) / float(segments)
        dist_h = t * length
        z_droop = -(t ** 1.8) * length * 0.55
        
        fx = math.cos(angle) * dist_h
        fy = math.sin(angle) * dist_h
        fz = math.sin(t * math.pi * 0.4) * 0.3 + z_droop
        center_pt = start_v + Vector((fx, fy, fz))
        
        w = 0.45 * (1.0 - t * 0.85) * (math.sin(t * math.pi) * 0.6 + 0.4)
        perp_x = -math.sin(angle) * w * 0.5
        perp_y = math.cos(angle) * w * 0.5
        
        vl = bm.verts.new(center_pt + Vector((perp_x, perp_y, 0)))
        vr = bm.verts.new(center_pt - Vector((perp_x, perp_y, 0)))
        vl.normal = ((vl.co - Vector(crown_center)).normalized() + Vector((0, 0, 0.4))).normalized()
        vr.normal = ((vr.co - Vector(crown_center)).normalized() + Vector((0, 0, 0.4))).normalized()
        frond_verts_left.append(vl)
        frond_verts_right.append(vr)
        
    faces = []
    for s in range(segments):
        f = bm.faces.new([frond_verts_left[s], frond_verts_left[s+1], frond_verts_right[s+1], frond_verts_right[s]])
        f.material_index = 1
        faces.append(f)
        for loop in f.loops:
            loop[uv_layer].uv = Vector((0.5, float(s) / float(segments)))
    return faces


def add_willow_streamer(bm, start_pt, length, crown_center, uv_layer, rng=None):
    """Creates a vertical cascading weeping willow foliage ribbon hanging toward the ground."""
    if rng is None:
        rng = random.Random(42)
    start_v = Vector(start_pt)
    segments = 5
    v_l = []
    v_r = []
    yaw = rng.uniform(0, 2.0 * math.pi)
    perp_x = -math.sin(yaw) * 0.35
    perp_y = math.cos(yaw) * 0.35
    
    for s in range(segments + 1):
        t = float(s) / float(segments)
        sway = math.sin(t * math.pi * 1.5) * 0.15
        cur_pt = start_v + Vector((sway, sway * 0.5, -t * length))
        w = 0.4 * (1.0 - t * 0.5)
        vl = bm.verts.new(cur_pt + Vector((perp_x * w, perp_y * w, 0)))
        vr = bm.verts.new(cur_pt - Vector((perp_x * w, perp_y * w, 0)))
        vl.normal = Vector((perp_y, -perp_x, 0.2)).normalized()
        vr.normal = Vector((perp_y, -perp_x, 0.2)).normalized()
        v_l.append(vl)
        v_r.append(vr)
        
    faces = []
    for s in range(segments):
        f = bm.faces.new([v_l[s], v_l[s+1], v_r[s+1], v_r[s]])
        f.material_index = 1
        faces.append(f)
    return faces


def fracture_mesh_z(bm, cuts=6, radius=1.0, rng=None, bias_horizontal=0.0):
    """Applies random planar bisect cuts in Z-up space to create sharp rock facets."""
    if rng is None:
        rng = random.Random(42)
    for _ in range(cuts):
        theta = rng.uniform(0, 2.0 * math.pi)
        phi = rng.uniform(-math.pi * 0.4, math.pi * 0.4)
        nx = math.cos(phi) * math.cos(theta)
        ny = math.cos(phi) * math.sin(theta)
        nz = math.sin(phi) * (1.0 - bias_horizontal)
        n = Vector((nx, ny, nz)).normalized()
        dist = radius * rng.uniform(0.35, 0.75)
        plane_co = n * dist
        bmesh.ops.bisect_plane(
            bm,
            geom=bm.verts[:] + bm.edges[:] + bm.faces[:],
            plane_co=plane_co,
            plane_no=n,
            clear_outer=True,
            clear_inner=False
        )
        boundary = [e for e in bm.edges if len(e.link_faces) == 1]
        if boundary:
            bmesh.ops.holes_fill(bm, edges=boundary)
        bmesh.ops.recalc_face_normals(bm, faces=list(bm.faces))


# ---------------------------------------------------------------------------
# 1. Authentic Volumetric Trees (12 Species x 3 Variants = 36 Models)
# ---------------------------------------------------------------------------

def build_organic_tree(name, tree_idx=0):
    """Generates a realistic volumetric tree with organic branching and zero spikiness."""
    seed = 600 + tree_idx
    rng = random.Random(seed)
    bm = bmesh.new()
    uv_layer = bm.loops.layers.uv.new("UVMap")

    species = tree_idx // 3  # 0 to 11
    variant = tree_idx % 3   # 0 to 2

    # Species Palettes & Types
    species_configs = [
        # (bark_color, leaf_color, leaf_type, name)
        ((0.28, 0.20, 0.14), (0.13, 0.28, 0.11), "needle", "Spruce"),
        ((0.24, 0.19, 0.13), (0.11, 0.25, 0.13), "needle", "Fir"),
        ((0.34, 0.22, 0.12), (0.16, 0.32, 0.13), "needle", "Pine"),
        ((0.30, 0.23, 0.16), (0.18, 0.38, 0.14), "broadleaf", "Oak"),
        ((0.74, 0.72, 0.68), (0.24, 0.44, 0.16), "broadleaf", "Birch"),
        ((0.38, 0.35, 0.32), (0.22, 0.40, 0.12), "broadleaf", "Maple"),
        ((0.26, 0.20, 0.15), (0.20, 0.36, 0.15), "willow", "Willow"),
        ((0.32, 0.24, 0.15), (0.22, 0.34, 0.12), "broadleaf", "Acacia"),
        ((0.36, 0.28, 0.18), (0.19, 0.37, 0.14), "palm", "Palm"),
        ((0.25, 0.21, 0.17), (0.14, 0.30, 0.12), "needle", "Cypress"),
        ((0.44, 0.41, 0.38), (0.44, 0.41, 0.38), "snag", "Snag"),
        ((0.30, 0.20, 0.13), (0.15, 0.30, 0.14), "needle", "CoastalPine")
    ]

    trunk_col, canopy_col, leaf_type, species_name = species_configs[species]

    # --- Species 0: Nordic Spruce (Conifer Layered Skirts) ---
    if species == 0:
        height = 7.2 + variant * 1.4
        trunk_h = height * 0.95
        trunk_r = 0.26 + variant * 0.04
        crown_center = (0, 0, height * 0.60)
        t_faces = add_cylinder_z(bm, (0, 0, trunk_h * 0.5), radius_bottom=trunk_r * 1.5, height=trunk_h, segments=7, radius_top=trunk_r * 0.3)
        for f in t_faces: f.material_index = 0

        tiers = 5 + variant
        canopy_h = height * 0.82
        for t in range(tiers):
            prog = float(t) / float(tiers - 1)
            z_tier = height * 0.18 + t * (canopy_h / float(tiers)) * 0.95
            r_tier = (2.6 + variant * 0.4) * (1.0 - prog * 0.72)
            add_conifer_skirt(bm, (0, 0, z_tier), radius_base=r_tier, height=1.2, crown_center=crown_center, uv_layer=uv_layer, rng=rng, droop=0.45)

    # --- Species 1: Alpine Fir (Conifer Spire Skirts) ---
    elif species == 1:
        height = 7.5 + variant * 1.4
        trunk_h = height * 0.96
        trunk_r = 0.22
        crown_center = (0, 0, height * 0.65)
        t_faces = add_cylinder_z(bm, (0, 0, trunk_h * 0.5), radius_bottom=trunk_r * 1.4, height=trunk_h, segments=7, radius_top=trunk_r * 0.25)
        for f in t_faces: f.material_index = 0

        tiers = 7 + variant * 2
        for t in range(tiers):
            prog = float(t) / float(tiers - 1)
            z_tier = height * 0.15 + prog * (height * 0.82)
            r_tier = (2.1 + variant * 0.3) * (1.0 - prog * 0.78)
            add_conifer_skirt(bm, (0, 0, z_tier), radius_base=r_tier, height=0.9, crown_center=crown_center, uv_layer=uv_layer, rng=rng, droop=0.35)

    # --- Species 2: Mountain Pine (Conifer Twisted Umbrella Pads) ---
    elif species == 2:
        height = 6.4 + variant * 1.2
        trunk_h = height * 0.60
        trunk_r = 0.28 + variant * 0.05
        crown_center = (0.3, 0.3, height * 0.75)
        p_mid = Vector((0.55 + variant * 0.15, -0.25, trunk_h * 0.45))
        p_top = Vector((p_mid.x * 0.5, p_mid.y + 0.5, trunk_h))
        f1, _, _ = add_curved_trunk_segment(bm, (0, 0, 0), p_mid, trunk_r * 1.5, trunk_r, segments=6)
        f2, _, _ = add_curved_trunk_segment(bm, p_mid, p_top, trunk_r, trunk_r * 0.65, segments=6)
        for f in f1 + f2: f.material_index = 0

        n_pads = 3 + variant
        for p in range(n_pads):
            p_ang = (2.0 * math.pi * p) / float(n_pads)
            pad_center = p_top + Vector((math.cos(p_ang) * 2.0, math.sin(p_ang) * 2.0, (p - 0.5) * 0.5 - 0.2))
            bf, _, _ = add_curved_trunk_segment(bm, p_top, pad_center, trunk_r * 0.5, trunk_r * 0.2, segments=4)
            for f in bf: f.material_index = 0
            add_foliage_puff(bm, pad_center, radius=1.6 + variant * 0.25, crown_center=crown_center, uv_layer=uv_layer, rng=rng, scale_z=0.65)

    # --- Species 3: Ancient Oak (Broadleaf Deciduous Patriarch) ---
    elif species == 3:
        height = 7.4 + variant * 1.3
        trunk_h = height * 0.42
        trunk_r = 0.42 + variant * 0.10
        crown_center = (0, 0, height * 0.68)
        t_faces = add_cylinder_z(bm, (0, 0, trunk_h * 0.5), radius_bottom=trunk_r * 1.7, height=trunk_h, segments=8, radius_top=trunk_r)
        for f in t_faces: f.material_index = 0

        n_branches = 4 + variant
        for b in range(n_branches):
            b_ang = (2.0 * math.pi * b) / float(n_branches) + rng.uniform(-0.15, 0.15)
            spread = 2.5 + variant * 0.5
            b_end = Vector((math.cos(b_ang) * spread, math.sin(b_ang) * spread, trunk_h + rng.uniform(0.3, 0.9)))
            bf, _, _ = add_curved_trunk_segment(bm, (0, 0, trunk_h * 0.75), b_end, trunk_r * 0.65, trunk_r * 0.3, segments=5)
            for f in bf: f.material_index = 0
            add_foliage_puff(bm, b_end, radius=1.9 + variant * 0.25, crown_center=crown_center, uv_layer=uv_layer, rng=rng, scale_z=0.85)
        # Central crown dome
        add_foliage_puff(bm, (0, 0, trunk_h + 2.2), radius=2.3 + variant * 0.3, crown_center=crown_center, uv_layer=uv_layer, rng=rng, scale_z=0.80)

    # --- Species 4: Paper Birch (Broadleaf Slender White) ---
    elif species == 4:
        height = 7.6 + variant * 1.2
        trunk_h = height * 0.72
        trunk_r = 0.20 + variant * 0.03
        crown_center = (0, 0, height * 0.75)
        top_pt = Vector((rng.uniform(-0.3, 0.3), rng.uniform(-0.3, 0.3), trunk_h))
        f1, _, _ = add_curved_trunk_segment(bm, (0, 0, 0), top_pt, trunk_r * 1.3, trunk_r * 0.6, segments=6)
        for f in f1: f.material_index = 0

        for p in range(4 + variant):
            p_ang = (2.0 * math.pi * p) / float(4 + variant)
            c_pos = top_pt + Vector((math.cos(p_ang) * 1.3, math.sin(p_ang) * 1.3, (p - 1.5) * 0.75 - 0.2))
            add_foliage_puff(bm, c_pos, radius=1.5 + variant * 0.2, crown_center=crown_center, uv_layer=uv_layer, rng=rng, scale_z=0.88)
        add_foliage_puff(bm, top_pt + Vector((0, 0, 1.2)), radius=1.6 + variant * 0.2, crown_center=crown_center, uv_layer=uv_layer, rng=rng, scale_z=0.85)

    # --- Species 5: Maple / Beech (Broadleaf Volumetric Dome) ---
    elif species == 5:
        height = 7.2 + variant * 1.3
        trunk_h = height * 0.38
        trunk_r = 0.32 + variant * 0.06
        crown_center = (0, 0, height * 0.70)
        t_faces = add_cylinder_z(bm, (0, 0, trunk_h * 0.5), radius_bottom=trunk_r * 1.5, height=trunk_h, segments=7, radius_top=trunk_r)
        for f in t_faces: f.material_index = 0

        n_lobes = 5 + variant
        for l in range(n_lobes):
            l_ang = (2.0 * math.pi * l) / float(n_lobes)
            l_spread = 2.1 + variant * 0.4
            l_pos = Vector((math.cos(l_ang) * l_spread, math.sin(l_ang) * l_spread, trunk_h + 0.9 + (l % 2) * 0.6))
            add_foliage_puff(bm, l_pos, radius=1.8 + variant * 0.25, crown_center=crown_center, uv_layer=uv_layer, rng=rng, scale_z=0.82)
        add_foliage_puff(bm, (0, 0, trunk_h + 2.4), radius=2.2 + variant * 0.3, crown_center=crown_center, uv_layer=uv_layer, rng=rng, scale_z=0.80)

    # --- Species 6: Weeping Willow (Riparian Cascading Canopies) ---
    elif species == 6:
        height = 6.8 + variant * 1.2
        trunk_h = height * 0.55
        trunk_r = 0.35 + variant * 0.07
        crown_center = (0.6, 0, height * 0.70)
        top_lean = Vector((0.9 + variant * 0.25, 0.2, trunk_h))
        f1, _, _ = add_curved_trunk_segment(bm, (0, 0, 0), top_lean, trunk_r * 1.6, trunk_r * 0.8, segments=7)
        for f in f1: f.material_index = 0

        # Upper canopy puff
        add_foliage_puff(bm, top_lean + Vector((0, 0, 0.6)), radius=2.4 + variant * 0.3, crown_center=crown_center, uv_layer=uv_layer, rng=rng, scale_z=0.75)
        # Cascading hanging streamers
        n_streamers = 8 + variant * 2
        for d in range(n_streamers):
            d_ang = (2.0 * math.pi * d) / float(n_streamers)
            d_pos = top_lean + Vector((math.cos(d_ang) * 2.2, math.sin(d_ang) * 2.2, 0.2))
            add_willow_streamer(bm, d_pos, length=3.0 + variant * 0.5, crown_center=crown_center, uv_layer=uv_layer, rng=rng)

    # --- Species 7: Savanna Umbrella Acacia (Arid Flat-Topped) ---
    elif species == 7:
        height = 6.0 + variant * 1.0
        trunk_h = height * 0.65
        trunk_r = 0.28 + variant * 0.05
        crown_center = (0, 0, height * 0.85)
        t_mid = Vector((0.35, -0.2, trunk_h * 0.45))
        f1, _, _ = add_curved_trunk_segment(bm, (0, 0, 0), t_mid, trunk_r * 1.4, trunk_r, segments=6)
        for f in f1: f.material_index = 0

        for a in range(3):
            a_ang = (2.0 * math.pi * a) / 3.0 + 0.3
            a_end = t_mid + Vector((math.cos(a_ang) * 2.6, math.sin(a_ang) * 2.6, trunk_h * 0.55))
            bf, _, _ = add_curved_trunk_segment(bm, t_mid, a_end, trunk_r * 0.6, trunk_r * 0.25, segments=5)
            for f in bf: f.material_index = 0
            add_foliage_puff(bm, a_end + Vector((0, 0, 0.1)), radius=2.0 + variant * 0.3, crown_center=crown_center, uv_layer=uv_layer, rng=rng, scale_z=0.45)

    # --- Species 8: Desert Date Palm (Tropical / Oasis Arched Fronds) ---
    elif species == 8:
        height = 7.5 + variant * 1.5
        trunk_h = height * 0.90
        trunk_r = 0.24 + variant * 0.03
        crown_center = (0.6, 0, trunk_h)
        p_mid = Vector((0.65 + variant * 0.15, -0.20, trunk_h * 0.5))
        p_top = p_mid * 1.5 + Vector((0, 0, trunk_h * 0.5))
        f1, _, _ = add_curved_trunk_segment(bm, (0, 0, 0), p_mid, trunk_r * 1.4, trunk_r * 0.9, segments=6)
        f2, _, _ = add_curved_trunk_segment(bm, p_mid, p_top, trunk_r * 0.9, trunk_r * 0.8, segments=6)
        for f in f1 + f2: f.material_index = 0

        n_fronds = 10 + variant * 2
        for fr in range(n_fronds):
            fr_ang = (2.0 * math.pi * fr) / float(n_fronds)
            add_palm_frond(bm, p_top, length=3.4 + variant * 0.4, angle=fr_ang, crown_center=crown_center, uv_layer=uv_layer, rng=rng)

    # --- Species 9: Columnar Cypress (Mediterranean Flame) ---
    elif species == 9:
        height = 8.5 + variant * 1.6
        trunk_h = height * 0.95
        trunk_r = 0.24
        crown_center = (0, 0, height * 0.60)
        t_faces = add_cylinder_z(bm, (0, 0, trunk_h * 0.5), radius_bottom=trunk_r * 1.3, height=trunk_h, segments=6, radius_top=trunk_r * 0.2)
        for f in t_faces: f.material_index = 0

        n_levels = 8 + variant * 2
        for lev in range(n_levels):
            prog = float(lev) / float(n_levels)
            z_pos = height * 0.12 + prog * (height * 0.82)
            card_sz = (1.4 + variant * 0.25) * (math.sin(prog * math.pi) * 0.7 + 0.35)
            add_foliage_puff(bm, (0, 0, z_pos), radius=card_sz, crown_center=crown_center, uv_layer=uv_layer, rng=rng, scale_z=0.75)

    # --- Species 10: Weathered Snag / Lightning Deadwood ---
    elif species == 10:
        height = 6.2 + variant * 1.2
        trunk_h = height
        trunk_r = 0.35 + variant * 0.08
        t_faces = add_cylinder_z(bm, (0, 0, trunk_h * 0.5), radius_bottom=trunk_r * 1.6, height=trunk_h, segments=7, radius_top=trunk_r * 0.35)
        for f in t_faces: f.material_index = 0
        # Broken splinter jagged tops
        for sp in range(4):
            ang = (2.0 * math.pi * sp) / 4.0
            r_sp = trunk_r * 0.3
            add_cylinder_z(bm, (math.cos(ang) * r_sp, math.sin(ang) * r_sp, trunk_h + 0.5),
                           radius_bottom=0.06, height=1.0, segments=4, radius_top=0.0)

    # --- Species 11: Windswept Coastal Pine (Bonsai Sculpted) ---
    else:
        height = 5.6 + variant * 1.0
        trunk_h = height * 0.55
        trunk_r = 0.30 + variant * 0.05
        crown_center = (2.0, 0, height * 0.60)
        top_lean = Vector((2.2 + variant * 0.5, 0.0, trunk_h))
        f1, _, _ = add_curved_trunk_segment(bm, (0, 0, 0), top_lean, trunk_r * 1.5, trunk_r * 0.65, segments=6)
        for f in f1: f.material_index = 0

        for p in range(3 + variant):
            pad_pos = top_lean + Vector((0.9 * p, rng.uniform(-0.3, 0.3), -0.35 * p + 0.10))
            add_foliage_puff(bm, pad_pos, radius=1.6 + variant * 0.25, crown_center=crown_center, uv_layer=uv_layer, rng=rng, scale_z=0.60)

    min_z = min(v.co.z for v in bm.verts)
    if min_z != 0.0:
        bmesh.ops.translate(bm, verts=bm.verts, vec=(0, 0, -min_z))

    mat0_fn = lambda mat_name: build_bark_pbr_material(mat_name, base_color=trunk_col, roughness=0.98, seed=seed, is_birch=(species == 4))
    mat1_fn = lambda mat_name: build_foliage_alpha_material(mat_name, base_color=canopy_col, species_type=leaf_type, seed=seed + 10)
    return finalize_mesh_dual(bm, name, mat0_builder=mat0_fn, mat1_builder=mat1_fn, smooth=True, auto_smooth_angle=40)


# ---------------------------------------------------------------------------
# 2. Authentic Geological Rocks (7 Formations x 5 Variants = 35 Models)
# ---------------------------------------------------------------------------

def build_geological_rock(name, rock_idx=0):
    """Generates an authentic geological rock model belonging to one of 7 formation types and 5 variants."""
    seed = 700 + rock_idx
    rng = random.Random(seed)
    bm = bmesh.new()

    formation = rock_idx // 5  # 0 to 6
    variant = rock_idx % 5    # 0 to 4

    rock_palettes = [
        (0.24, 0.23, 0.22),  # 0: Basalt (dark charcoal volcanic)
        (0.55, 0.48, 0.38),  # 1: Sandstone / Shale (warm sedimentary tan)
        (0.44, 0.42, 0.40),  # 2: Granite / Tor (neutral grey corestone)
        (0.58, 0.56, 0.54),  # 3: Karst Limestone (weathered pale chalk-grey)
        (0.38, 0.39, 0.37),  # 4: Glacial Erratic / River Stone (water-smoothed dark stone)
        (0.46, 0.43, 0.40),  # 5: Scree / Talus (sharp fractured scree)
        (0.35, 0.33, 0.32)   # 6: Crystalline Matrix (dark host rock with bright crystals)
    ]
    col = rock_palettes[formation]

    if formation == 0:  # Columnar Basalt
        n_columns = 3 + variant
        for col_i in range(n_columns):
            angle = (2.0 * math.pi * col_i) / float(n_columns) + rng.uniform(-0.15, 0.15)
            r_dist = 0.55 * (col_i > 0)
            col_x = math.cos(angle) * r_dist
            col_y = math.sin(angle) * r_dist
            col_h = rng.uniform(1.2, 2.6)
            col_r = rng.uniform(0.35, 0.55)
            faces = add_cylinder_z(bm, (col_x, col_y, col_h * 0.5), radius_bottom=col_r, height=col_h, segments=6, radius_top=col_r * 0.95)
            for f in faces: f.material_index = 0
        fracture_mesh_z(bm, cuts=3, radius=1.8, rng=rng, bias_horizontal=0.6)

    elif formation == 1:  # Sedimentary Sandstone
        base_h = rng.uniform(1.0, 1.8)
        base_r = rng.uniform(1.4, 2.2)
        add_cylinder_z(bm, (0, 0, base_h * 0.5), radius_bottom=base_r, height=base_h, segments=8, radius_top=base_r * 0.75)
        fracture_mesh_z(bm, cuts=6, radius=base_r * 1.2, rng=rng, bias_horizontal=0.75)

    elif formation == 2:  # Granite Tor / Corestone
        ret = bmesh.ops.create_icosphere(bm, subdivisions=2, radius=1.5 + variant * 0.2)
        for v in ret["verts"]:
            disp = organic_noise_3d(v.co.x, v.co.y, v.co.z, seed=seed)
            v.co += v.co.normalized() * (disp * 0.35)
            v.co.z *= 0.75
        fracture_mesh_z(bm, cuts=4, radius=2.0, rng=rng, bias_horizontal=0.2)

    elif formation == 3:  # Karst Limestone
        base_h = rng.uniform(1.5, 2.4)
        base_r = rng.uniform(0.9, 1.5)
        add_cylinder_z(bm, (0, 0, base_h * 0.5), radius_bottom=base_r * 1.3, height=base_h, segments=7, radius_top=base_r * 0.4)
        fracture_mesh_z(bm, cuts=7, radius=base_r * 1.5, rng=rng, bias_horizontal=0.1)

    elif formation == 4:  # Glacial Erratic
        ret = bmesh.ops.create_icosphere(bm, subdivisions=2, radius=1.3 + variant * 0.25)
        for v in ret["verts"]:
            disp = organic_noise_3d(v.co.x * 0.8, v.co.y * 0.8, v.co.z * 0.8, seed=seed)
            v.co += v.co.normalized() * (disp * 0.18)
            v.co.z *= 0.65
        fracture_mesh_z(bm, cuts=2, radius=1.8, rng=rng, bias_horizontal=0.3)

    elif formation == 5:  # Scree / Talus
        n_chunks = 4 + variant
        for ch in range(n_chunks):
            ch_ang = (2.0 * math.pi * ch) / float(n_chunks) + rng.uniform(-0.3, 0.3)
            ch_dist = rng.uniform(0.3, 1.1)
            ch_r = rng.uniform(0.35, 0.75)
            ch_h = rng.uniform(0.4, 0.9)
            add_cylinder_z(bm, (math.cos(ch_ang) * ch_dist, math.sin(ch_ang) * ch_dist, ch_h * 0.5),
                           radius_bottom=ch_r, height=ch_h, segments=5, radius_top=ch_r * 0.4)
        fracture_mesh_z(bm, cuts=8, radius=2.0, rng=rng, bias_horizontal=0.1)

    else:  # Crystalline Matrix
        base_r = 1.3 + variant * 0.2
        add_cylinder_z(bm, (0, 0, 0.5), radius_bottom=base_r, height=1.0, segments=7, radius_top=base_r * 0.8)
        for sp in range(5):
            c_ang = (2.0 * math.pi * sp) / 5.0 + rng.uniform(-0.2, 0.2)
            c_h = rng.uniform(1.2, 2.2)
            c_r = rng.uniform(0.18, 0.32)
            add_cylinder_z(bm, (math.cos(c_ang) * 0.45, math.sin(c_ang) * 0.45, 0.5 + c_h * 0.4),
                           radius_bottom=c_r, height=c_h, segments=6, radius_top=0.0)
        fracture_mesh_z(bm, cuts=3, radius=1.8, rng=rng, bias_horizontal=0.1)

    min_z = min(v.co.z for v in bm.verts)
    bmesh.ops.translate(bm, verts=bm.verts, vec=(0, 0, -min_z))

    mat_fn = lambda mat_name: build_rock_pbr_material(mat_name, base_color=col, roughness=0.92, metallic=0.0, seed=seed)
    return finalize_mesh(bm, name, mat_builder=mat_fn, smooth=True, auto_smooth_angle=38)


# ---------------------------------------------------------------------------
# 3. Wide Carpet Grass Turf Mats (Lush Ground Cover)
# ---------------------------------------------------------------------------

def build_organic_grass_tuft(name, seed=0, style="prairie"):
    """Builds wide, dense, carpet-forming grass turf mats (1.1m diameter, 32 blades, 0.20m height)."""
    rng = random.Random(seed)
    bm = bmesh.new()

    count = 32
    base_height = rng.uniform(0.18, 0.24)
    base_width = rng.uniform(0.045, 0.075)

    for i in range(count):
        angle = (2.0 * math.pi * i) / float(count) + rng.uniform(-0.12, 0.12)
        lean_dir = angle + rng.uniform(-0.15, 0.15)
        lean_mag = rng.uniform(0.40, 0.75)
        h = base_height * rng.uniform(0.85, 1.25)
        w = base_width * rng.uniform(0.85, 1.25)
        segments = 3

        spine = []
        r_off = rng.uniform(0.06, 0.52) # Wide spreading circular turf mat (up to 1.1m diameter)
        start_x = math.cos(angle) * r_off
        start_y = math.sin(angle) * r_off

        for s in range(segments + 1):
            t = float(s) / segments
            arch = (t * t) * lean_mag * h
            pz = t * h * (1.0 - t * 0.15)
            px = start_x + math.cos(lean_dir) * arch
            py = start_y + math.sin(lean_dir) * arch
            spine.append(Vector((px, py, pz)))

        blade_verts = []
        perp_x = -math.sin(angle)
        perp_y = math.cos(angle)

        for s in range(segments + 1):
            t = float(s) / segments
            cur_w = w * (1.0 - t * 0.85)
            center = spine[s]
            v_l = bm.verts.new(center + Vector((perp_x * cur_w * 0.5, perp_y * cur_w * 0.5, 0.0)))
            v_r = bm.verts.new(center - Vector((perp_x * cur_w * 0.5, perp_y * cur_w * 0.5, 0.0)))
            blade_verts.append((v_l, v_r))

        bm.verts.ensure_lookup_table()
        for s in range(segments):
            v0_l, v0_r = blade_verts[s]
            v1_l, v1_r = blade_verts[s + 1]
            try:
                bm.faces.new([v0_l, v1_l, v1_r, v0_r])
            except ValueError:
                pass

    col_map = {
        "prairie": (0.30, 0.42, 0.22),
        "dense": (0.24, 0.36, 0.18),
        "fescue": (0.32, 0.40, 0.24),
        "windswept": (0.28, 0.38, 0.20),
        "tussock": (0.34, 0.40, 0.24),
        "tall": (0.26, 0.38, 0.19)
    }
    col = col_map.get(style, (0.30, 0.42, 0.22))
    mat_fn = lambda mat_name: build_grass_pbr_material(mat_name, base_color=col, roughness=0.95, seed=seed)
    return finalize_mesh(bm, name, mat_builder=mat_fn, smooth=True)


def build_organic_shrub(name, seed=0, style="dense"):
    """Builds an organic shrub with branching woody stems and foliage puffs in Z-up space."""
    rng = random.Random(seed)
    bm = bmesh.new()
    uv_layer = bm.loops.layers.uv.new("UVMap")

    shrub_h = rng.uniform(0.9, 1.4)
    n_stems = rng.randint(4, 6)
    canopy_centers = []

    for i in range(n_stems):
        angle = (2.0 * math.pi * i) / float(n_stems) + rng.uniform(-0.3, 0.3)
        spread = rng.uniform(0.4, 0.75) * shrub_h
        branch_h = rng.uniform(0.5, 0.85) * shrub_h
        top_pos = (math.cos(angle) * spread, math.sin(angle) * spread, branch_h)
        canopy_centers.append(top_pos)
        faces = add_cylinder_z(bm, (top_pos[0] * 0.5, top_pos[1] * 0.5, top_pos[2] * 0.5),
                               radius_bottom=0.055, height=branch_h, segments=5, radius_top=0.03)
        for f in faces:
            f.material_index = 0

    canopy_centers.append((0.0, 0.0, shrub_h * 0.85))
    crown_center = (0.0, 0.0, shrub_h * 0.7)
    for center in canopy_centers:
        r = rng.uniform(0.45, 0.7)
        add_foliage_puff(bm, center, radius=r, crown_center=crown_center, uv_layer=uv_layer, rng=rng, scale_z=0.75)

    stem_col = (0.28, 0.20, 0.14)
    leaf_col = (0.20, 0.38, 0.16)
    mat0_fn = lambda mat_name: build_bark_pbr_material(mat_name, base_color=stem_col, roughness=0.98, seed=seed)
    mat1_fn = lambda mat_name: build_foliage_alpha_material(mat_name, base_color=leaf_col, species_type="broadleaf", seed=seed + 1)
    return finalize_mesh_dual(bm, name, mat0_builder=mat0_fn, mat1_builder=mat1_fn, smooth=True)


def build_organic_reeds(name, seed=0):
    """Builds wetland cattails & marsh reeds in Z-up space."""
    rng = random.Random(seed)
    bm = bmesh.new()

    n_reeds = rng.randint(10, 16)
    for i in range(n_reeds):
        angle = rng.uniform(0, 2.0 * math.pi)
        r = rng.uniform(0.05, 0.55)
        pos = (math.cos(angle) * r, math.sin(angle) * r, 0.0)
        h = rng.uniform(1.4, 2.4)
        faces = add_cylinder_z(bm, (pos[0], pos[1], h * 0.5), radius_bottom=0.03, height=h, segments=4, radius_top=0.008)
        for f in faces:
            f.material_index = 0
        if rng.random() < 0.5:
            c_h = rng.uniform(0.22, 0.35)
            c_pos = (pos[0], pos[1], h * 0.72)
            c_faces = add_cylinder_z(bm, c_pos, radius_bottom=0.05, height=c_h, segments=6)
            for f in c_faces:
                f.material_index = 1

    mat0_fn = lambda mat_name: build_grass_pbr_material(mat_name, base_color=(0.26, 0.38, 0.15), roughness=0.95, seed=seed)
    mat1_fn = lambda mat_name: build_bark_pbr_material(mat_name, base_color=(0.25, 0.16, 0.10), roughness=0.98, seed=seed + 2)
    return finalize_mesh_dual(bm, name, mat0_builder=mat0_fn, mat1_builder=mat1_fn, smooth=True)


def build_organic_wildflower(name, seed=0, flower_color=(0.92, 0.78, 0.15)):
    """Builds vibrant wildflower tufts with green leaves and petal blossom heads in Z-up space."""
    rng = random.Random(seed)
    bm = bmesh.new()

    # Base foliage
    for i in range(12):
        angle = (2.0 * math.pi * i) / 12.0 + rng.uniform(-0.2, 0.2)
        h = rng.uniform(0.45, 0.85)
        faces = add_cylinder_z(bm, (math.cos(angle) * 0.1, math.sin(angle) * 0.1, h * 0.5),
                               radius_bottom=0.025, height=h, segments=4, radius_top=0.004)
        for f in faces:
            f.material_index = 0

    # Flower stems + blossom heads
    n_flowers = rng.randint(5, 8)
    for i in range(n_flowers):
        angle = (2.0 * math.pi * i) / float(n_flowers) + rng.uniform(-0.25, 0.25)
        r = rng.uniform(0.1, 0.35)
        fh = rng.uniform(0.65, 1.1)
        fpos = (math.cos(angle) * r, math.sin(angle) * r, fh)
        s_faces = add_cylinder_z(bm, (fpos[0], fpos[1], fh * 0.5), radius_bottom=0.015, height=fh, segments=4)
        for f in s_faces:
            f.material_index = 0
        b_faces = add_cylinder_z(bm, fpos, radius_bottom=0.08, height=0.035, segments=6)
        for f in b_faces:
            f.material_index = 1

    mat0_fn = lambda mat_name: build_grass_pbr_material(mat_name, base_color=(0.24, 0.40, 0.16), roughness=0.95, seed=seed)
    mat1_fn = lambda mat_name: build_bark_pbr_material(mat_name, base_color=flower_color, roughness=0.90, seed=seed + 3)
    return finalize_mesh_dual(bm, name, mat0_builder=mat0_fn, mat1_builder=mat1_fn, smooth=True)


def build_organic_tree_stand(name, stand_idx=0):
    """Builds a stand of 3 authentic volumetric conifer trees for harvestable lumber nodes."""
    seed = 800 + stand_idx
    rng = random.Random(seed)
    bm = bmesh.new()
    uv_layer = bm.loops.layers.uv.new("UVMap")

    offsets = [
        Vector((0.0, 0.0, 0.0)),
        Vector((rng.uniform(1.2, 2.0), rng.uniform(-0.8, 0.8), 0.0)),
        Vector((rng.uniform(-1.5, -0.8), rng.uniform(1.0, 1.8), 0.0))
    ]

    trunk_col = (0.28, 0.20, 0.14)
    canopy_col = (0.13, 0.28, 0.11)

    for i, base_pos in enumerate(offsets):
        tree_h = rng.uniform(5.2, 6.8)
        trunk_h = tree_h * 0.95
        trunk_r = rng.uniform(0.18, 0.24)
        crown_center = base_pos + Vector((0, 0, tree_h * 0.60))

        t_faces = add_cylinder_z(bm, base_pos + Vector((0, 0, trunk_h * 0.5)), radius_bottom=trunk_r * 1.5, height=trunk_h, segments=6, radius_top=trunk_r * 0.3)
        for f in t_faces: f.material_index = 0

        tiers = 4
        canopy_h = tree_h * 0.80
        for t in range(tiers):
            prog = float(t) / float(tiers - 1)
            z_tier = base_pos.z + tree_h * 0.20 + t * (canopy_h / float(tiers)) * 0.95
            r_tier = (1.9 - prog * 0.85)
            add_conifer_skirt(bm, base_pos + Vector((0, 0, z_tier)), radius_base=r_tier, height=1.0, crown_center=crown_center, uv_layer=uv_layer, rng=rng, droop=0.40)

    min_z = min(v.co.z for v in bm.verts)
    if min_z != 0.0:
        bmesh.ops.translate(bm, verts=bm.verts, vec=(0, 0, -min_z))

    mat0_fn = lambda mat_name: build_bark_pbr_material(mat_name, base_color=trunk_col, roughness=0.98, seed=seed)
    mat1_fn = lambda mat_name: build_foliage_alpha_material(mat_name, base_color=canopy_col, species_type="needle", seed=seed + 10)
    return finalize_mesh_dual(bm, name, mat0_builder=mat0_fn, mat1_builder=mat1_fn, smooth=True, auto_smooth_angle=40)


# ---------------------------------------------------------------------------
# Main Generation Runner
# ---------------------------------------------------------------------------

def generate_all_terrain_props():
    os.makedirs(TERRAIN_DIR, exist_ok=True)
    print("==========================================================")
    print("Generating 36 Authentic Volumetric Trees (Zero Spikes)...")
    print("==========================================================")
    for i in range(36):
        clear_scene()
        name = "ambient_tree_%d" % i
        obj = build_organic_tree(name, tree_idx=i)
        export_glb(obj, os.path.join(TERRAIN_DIR, "%s.glb" % name))

    print("==========================================================")
    print("Generating 3 Harvestable Lumber Node Stands...")
    print("==========================================================")
    for i in range(3):
        clear_scene()
        name = "resource_lumber_%d" % i
        obj = build_organic_tree_stand(name, stand_idx=i)
        export_glb(obj, os.path.join(TERRAIN_DIR, "%s.glb" % name))

    print("==========================================================")
    print("Generating 35 Geological Rock Formations...")
    print("==========================================================")
    for i in range(35):
        clear_scene()
        name = "boulder_%d" % i
        obj = build_geological_rock(name, rock_idx=i)
        export_glb(obj, os.path.join(TERRAIN_DIR, "%s.glb" % name))

    print("==========================================================")
    print("Generating 6 Wide Carpet Grass Turf Mats...")
    print("==========================================================")
    grass_styles = ["prairie", "dense", "fescue", "windswept", "tussock", "tall"]
    for i, style in enumerate(grass_styles):
        clear_scene()
        name = "grass_tuft_%d" % i
        obj = build_organic_grass_tuft(name, seed=800 + i, style=style)
        export_glb(obj, os.path.join(TERRAIN_DIR, "%s.glb" % name))

    print("==========================================================")
    print("Generating 4 Organic Shrubs...")
    print("==========================================================")
    for i in range(4):
        clear_scene()
        name = "shrub_%d" % i
        obj = build_organic_shrub(name, seed=900 + i)
        export_glb(obj, os.path.join(TERRAIN_DIR, "%s.glb" % name))

    print("==========================================================")
    print("Generating 3 Cattails / Wetland Reeds...")
    print("==========================================================")
    for i in range(3):
        clear_scene()
        name = "reed_%d" % i
        obj = build_organic_reeds(name, seed=1000 + i)
        export_glb(obj, os.path.join(TERRAIN_DIR, "%s.glb" % name))

    print("==========================================================")
    print("Generating 3 Wildflower Clumps...")
    print("==========================================================")
    flower_colors = [
        (0.95, 0.78, 0.12),  # Buttercup gold
        (0.88, 0.32, 0.35),  # Alpine red / rose
        (0.45, 0.58, 0.92)   # Mountain bluebell
    ]
    for i, f_col in enumerate(flower_colors):
        clear_scene()
        name = "wildflower_%d" % i
        obj = build_organic_wildflower(name, seed=1100 + i, flower_color=f_col)
        export_glb(obj, os.path.join(TERRAIN_DIR, "%s.glb" % name))

    print("==========================================================")
    print("All Terrain Props Successfully Built and Exported!")
    print("==========================================================")


if __name__ == "__main__":
    generate_all_terrain_props()
