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
import sys
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
    """Creates a Blender image datablock, populates pixel float buffer, sets color space, and packs it.

    THE COLORSPACE ASSIGNMENT MUST COME FIRST. Setting
    `colorspace_settings.name` signals a colour-management change, which frees
    the image's buffers and regenerates them from source - and a generated
    image has no source, so it regenerates as the flat generated colour
    (black). Assigning it AFTER foreach_set therefore silently discarded every
    pixel just written.

    Because only `is_data=True` images take that branch, the damage was
    confined to exactly the maps nobody looks at directly: every NORMAL map
    (and every roughness map) produced by this file was solid zero. Verified
    on the shipped assets - ambient_tree_0_mat0_norm.png, boulder_3_mat_norm
    .png and shrub_0_mat0_norm.png are all mean 0.000 - and reproduced in
    isolation: same array, colorspace set after -> 0.0000, set before ->
    0.5020.

    A zero normal map is not a flat normal. Flat is (0.5, 0.5, 1.0); zero
    decodes to (-1, -1, -1), so every prop was shading against a normal
    pointing away from its own surface, which is what rendered them black
    here and washed them out in game.
    """
    img = bpy.data.images.new(name, width=width, height=height, alpha=True)
    if is_data:
        img.colorspace_settings.name = 'Non-Color'
    img.pixels.foreach_set(np.ascontiguousarray(pixels_rgba, dtype=np.float32).flatten())
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


# Foliage albedo, measured and retargeted rather than eyeballed.
#
# The authored species colours are written straight into an sRGB image, so a
# leaf_color of (0.13, 0.28, 0.11) is an sRGB texel - linear (0.015, 0.061,
# 0.011). Measured on the shipped GLBs the spruce canopy averaged sRGB
# (0.102, 0.231, 0.092) = linear luminance 0.034, and the old `sun_grad`
# darkened it a further 17% because it ran 1.00 -> 0.65 instead of straddling
# 1.0. Real foliage sits at 0.05-0.09 linear and is far LESS saturated than it
# looks by eye. Under-bright, over-saturated canopy is what turns a tree into a
# dark silhouette that only reads by its outline.
FOLIAGE_TARGET_LINEAR = 0.062
# Partial corrections, not snaps. Measured after the first pass: forcing every
# species to exactly TARGET and desaturating 30% made spruce (authored linear
# luminance 0.049) and oak (0.091) come out at 0.187/0.302/0.185 and
# 0.185/0.303/0.178 - indistinguishable. A correction that erases the
# difference between a fir and an oak is over-correcting. FOLIAGE_PULL < 1
# moves each colour most of the way to the target while preserving the
# ordering; a gentler desaturate keeps the hue spread the palettes carry.
FOLIAGE_DESATURATE = 0.18
FOLIAGE_PULL = 0.75


def _srgb_to_linear(c):
    return c / 12.92 if c <= 0.04045 else ((c + 0.055) / 1.055) ** 2.4


def _linear_to_srgb(c):
    c = max(0.0, min(1.0, c))
    return c * 12.92 if c <= 0.0031308 else 1.055 * (c ** (1.0 / 2.4)) - 0.055


def retarget_foliage_colour(base_color, target_linear=FOLIAGE_TARGET_LINEAR,
                            desat=FOLIAGE_DESATURATE):
    """Pull an authored leaf colour onto a physical albedo, keeping its hue."""
    lin = [_srgb_to_linear(c) for c in base_color]
    lum = 0.2126 * lin[0] + 0.7152 * lin[1] + 0.0722 * lin[2]
    lin = [c + (lum - c) * desat for c in lin]
    lum = 0.2126 * lin[0] + 0.7152 * lin[1] + 0.0722 * lin[2]
    if lum > 1e-6:
        k = (target_linear / lum) ** FOLIAGE_PULL
        lin = [min(c * k, 0.9) for c in lin]
    return tuple(_linear_to_srgb(c) for c in lin)


def build_foliage_alpha_material(name, base_color=(0.18, 0.35, 0.15), species_type="broadleaf", seed=0):
    """Generates procedural rich organic leaf PBR textures with soft sunlight gradients and matte finish."""
    rng = np.random.default_rng(seed)
    w, h = 256, 256
    y, x = np.mgrid[0:h, 0:w]

    uv_y = y / float(h)
    base_color = retarget_foliage_colour(base_color)

    # Leaf dapple pattern
    dapple = rng.normal(0, 0.04, (h, w)).astype(np.float32)
    # Straddles 1.0, so the gradient MODULATES the albedo instead of darkening
    # it. The old form (1.0 - uv_y * 0.35) had a mean of 0.825.
    sun_grad = (1.175 - uv_y * 0.35)

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


def build_rock_pbr_material(name, base_color=(0.42, 0.40, 0.38), roughness=0.92, metallic=0.0, seed=0, strata_freq=28.0, size=128):
    """Generates procedural stone PBR textures with strata layering, mineral flecks, and chiseled facets.

    `size` is a parameter rather than a constant because the boulder pool bakes
    ambient occlusion INTO this albedo (see _bake_ao_into_albedo) and 128 px is
    too coarse to hold a crevice edge. Rocks pass ROCK_TEX_SIZE; every other
    caller keeps the original 128 and is unaffected.
    """
    rng = np.random.default_rng(seed)
    w, h = size, size
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
        # DEAD ON BLENDER 4.1+, WHICH INCLUDES THE 5.2 THIS PROJECT BUILDS
        # WITH. `Mesh.use_auto_smooth` was removed in 4.1, so this raises
        # AttributeError and the except swallows it - meaning `smooth=True`
        # here is plain shade_smooth() with no angle limit whatsoever.
        #
        # Left in place deliberately: unlimited smoothing is the right answer
        # for foliage (canopy puffs, blades, fronds), which is all that still
        # reaches this function, and "fixing" it would restyle the whole tree
        # and shrub roster as a side effect. Anything that needs real facets
        # must use apply_faceted_shading() instead - see its docstring, and
        # the hard-surface toolkit header, for what this cost the rock pool.
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


def unwrap_material_slot(obj, slot_index):
    """Smart-project ONLY the faces on `slot_index`, leaving every other UV alone.

    finalize_mesh() unwraps the whole object, but the dual-material props cannot:
    their foliage faces carry hand-authored spherical UVs assigned face by face
    in add_foliage_lobe / add_conifer_skirt / add_palm_frond, and a whole-object
    smart_project would overwrite them. So unwrap the woody slot and only that.
    """
    bpy.context.view_layer.objects.active = obj
    bpy.ops.object.select_all(action='DESELECT')
    obj.select_set(True)

    bpy.ops.object.mode_set(mode='EDIT')
    bpy.ops.mesh.select_mode(type='FACE')
    bpy.ops.mesh.select_all(action='DESELECT')
    bpy.ops.object.mode_set(mode='OBJECT')

    wanted = False
    for poly in obj.data.polygons:
        poly.select = (poly.material_index == slot_index)
        wanted = wanted or poly.select
    if not wanted:
        return

    bpy.ops.object.mode_set(mode='EDIT')
    bpy.ops.uv.smart_project(
        angle_limit=math.radians(66.0),
        island_margin=0.02,
        area_weight=0.0,
        correct_aspect=True,
        scale_to_bounds=False
    )
    bpy.ops.object.mode_set(mode='OBJECT')


def finalize_mesh_dual(bm, name, mat0_builder, mat1_builder, smooth=True,
                       auto_smooth_angle=35, faceted=False, facet_angle=30.0):
    """Finalizes a dual-material bmesh into an object with both PBR materials.

    UNWRAPS SLOT 0. This function used to unwrap nothing at all, which meant
    every trunk, stem and branch in the tree and shrub roster shipped with a
    single UV coordinate: measured on the built GLBs, prim0 of every tree had
    u[0,0] v[1,1], one distinct UV across all 56 verts. The whole bark texture
    - grain, furrows, the birch lenticels below - collapsed to one texel, so a
    trunk rendered as one flat unshaded colour. That is what made the birch
    (bark 0.74) read as a white pole and the pines (0.34,0.22,0.12) as orange
    ones. Nothing was wrong with the bark textures; they were never sampled.

    `faceted` splits every edge sharper than `facet_angle` instead of smoothing
    the whole shell. Foliage built from lobes needs this - see add_foliage_lobe.
    """
    bmesh.ops.recalc_face_normals(bm, faces=list(bm.faces))
    mesh_data = bpy.data.meshes.new(name + "_mesh")
    bm.to_mesh(mesh_data)
    bm.free()

    obj = bpy.data.objects.new(name, mesh_data)
    bpy.context.collection.objects.link(obj)
    bpy.context.view_layer.objects.active = obj
    obj.select_set(True)

    mat0 = mat0_builder(name + "_mat0")
    mat1 = mat1_builder(name + "_mat1")
    obj.data.materials.append(mat0)
    obj.data.materials.append(mat1)

    unwrap_material_slot(obj, 0)

    if faceted:
        apply_faceted_shading(obj, angle_deg=facet_angle)
    elif smooth:
        bpy.ops.object.shade_smooth()
    else:
        bpy.ops.object.shade_flat()
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

# A leaf mass is built as a CLUSTER OF ANGULAR LOBES, never as a sphere.
#
# What this replaces: add_foliage_puff used to emit one bmesh icosphere at
# subdivisions=2 (42 verts / 80 tris) with 18% radial noise, smooth-shaded.
# Measured on the shipped roster, an oak canopy was exactly 210 verts / 400
# tris = five of those spheres, and a shrub was the same five. Smooth-shaded
# spheres on a stick is the literal description of a cotton bud, which is what
# they looked like at the RTS camera.
#
# Three things make a lobe read as foliage instead:
#   - an IRREGULAR silhouette. Per-vertex radial jitter at low segment counts,
#     so no two lobes share a profile and none of them is round.
#   - a FLAT UNDERSIDE. Real foliage masses are domes sitting on their
#     branching, not floating balls; closing the base with an n-gon also drops
#     the vertex count below the sphere it replaces.
#   - FACETED shading. The same fix the rock pool needed: hard edges catch the
#     sun in planes, which is what gives a canopy its dappled break-up. Smooth
#     shading over a blobby shell gives one soft gradient and nothing else.
#
# 36 tris per lobe against the icosphere's 80, so a 4-lobe cluster is roughly
# double the geometry of the single sphere it replaces, for a silhouette that
# actually varies.

def add_foliage_lobe(bm, center, radius, height, uv_layer, rng, mat_index=1,
                     segments=7, irregular=0.34, tilt=0.0, tilt_dir=0.0):
    """One angular, irregular, flat-bottomed foliage lobe."""
    center_v = Vector(center)
    # (radius_frac, height_frac) up the lobe; the last entry is the apex ring.
    profile = [(1.00, 0.00), (0.88, 0.42), (0.55, 0.76)]
    yaw = rng.uniform(0.0, 2.0 * math.pi)

    rings = []
    for r_frac, h_frac in profile:
        ring = []
        for i in range(segments):
            theta = yaw + (2.0 * math.pi * i) / float(segments)
            jitter = rng.uniform(1.0 - irregular, 1.0 + irregular)
            r = radius * r_frac * jitter
            z = height * (h_frac + rng.uniform(-0.09, 0.09))
            ring.append(Vector((math.cos(theta) * r, math.sin(theta) * r, z)))
        rings.append(ring)
    apex = Vector((rng.uniform(-0.18, 0.18) * radius,
                   rng.uniform(-0.18, 0.18) * radius,
                   height))

    # Lean the whole lobe. Foliage grows toward the light, and a cluster of
    # lobes all standing plumb re-introduces the symmetry we just removed.
    if tilt != 0.0:
        rot = Matrix.Rotation(tilt, 3, Vector((math.cos(tilt_dir), math.sin(tilt_dir), 0.0)))
        rings = [[rot @ p for p in ring] for ring in rings]
        apex = rot @ apex

    vrings = [[bm.verts.new(center_v + p) for p in ring] for ring in rings]
    v_apex = bm.verts.new(center_v + apex)

    faces = []
    for k in range(len(vrings) - 1):
        lo, hi = vrings[k], vrings[k + 1]
        for i in range(segments):
            j = (i + 1) % segments
            faces.append(bm.faces.new([lo[i], lo[j], hi[j], hi[i]]))
    top = vrings[-1]
    for i in range(segments):
        j = (i + 1) % segments
        faces.append(bm.faces.new([top[i], top[j], v_apex]))
    # Flat underside, wound to face down.
    faces.append(bm.faces.new(list(reversed(vrings[0]))))

    for f in faces:
        f.material_index = mat_index
        for loop in f.loops:
            n = (loop.vert.co - center_v)
            n = n.normalized() if n.length > 1e-6 else Vector((0, 0, 1))
            u = 0.5 + math.atan2(n.y, n.x) / (2.0 * math.pi)
            v_coord = 0.5 - math.asin(np.clip(n.z, -1.0, 1.0)) / math.pi
            loop[uv_layer].uv = Vector((u, v_coord))
    return faces


def add_foliage_puff(bm, center, radius, crown_center, uv_layer, rng=None, scale_z=0.82, noise_amp=0.18):
    """A foliage mass occupying roughly the old puff's volume, built from lobes.

    Signature preserved on purpose: all twelve tree species, the shrub and the
    lumber stand call this, and keeping it means they all improve without any
    of them being edited. `crown_center` and `noise_amp` are now unused - the
    hand-set vertex normals crown_center drove were dead anyway (bmesh
    `v.normal` does not survive to_mesh; the exported NORMAL accessors measured
    a mean Z of 0.000, not the intended +0.28 sky bias), and irregularity is a
    property of the lobe rather than a displacement over a sphere.
    """
    if rng is None:
        rng = random.Random(42)
    n_lobes = 3 if radius < 1.2 else (4 if radius < 2.0 else 5)
    faces = []
    for i in range(n_lobes):
        # Pack the lobes around the centre so the cluster spans about the same
        # width as the sphere it replaces (0.55R lobes at up to 0.48R offset).
        ang = (2.0 * math.pi * i) / float(n_lobes) + rng.uniform(-0.4, 0.4)
        off_r = radius * (0.0 if i == 0 else rng.uniform(0.30, 0.48))
        off = Vector((math.cos(ang) * off_r, math.sin(ang) * off_r,
                      rng.uniform(-0.16, 0.24) * radius * scale_z))
        lobe_r = radius * rng.uniform(0.50, 0.66)
        faces += add_foliage_lobe(
            bm, Vector(center) + off, lobe_r,
            height=lobe_r * 1.55 * scale_z, uv_layer=uv_layer, rng=rng,
            tilt=rng.uniform(0.0, 0.34), tilt_dir=ang)
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


# Fronds and streamers are SOLID thin wedges, not one-sided quad strips.
#
# A flat strip is invisible from behind under back-face culling, and the batcher
# only disables culling for materials whose albedo carries alpha - the foliage
# albedo is fully opaque, so it does not qualify. The palms and willows were
# therefore half-disappearing as the camera swung around them. Four verts per
# station instead of two costs almost nothing at these segment counts and makes
# the frond correct from every angle.

def _add_solid_ribbon(bm, stations, uv_layer, mat_index=1, uv_of=None):
    """Skin a list of 4-vertex cross sections into a closed thin solid."""
    ring_verts = [[bm.verts.new(p) for p in st] for st in stations]
    faces = []
    for s in range(len(stations) - 1):
        a, b = ring_verts[s], ring_verts[s + 1]
        for i in range(4):
            j = (i + 1) % 4
            faces.append(bm.faces.new([a[i], a[j], b[j], b[i]]))
    faces.append(bm.faces.new(list(reversed(ring_verts[0]))))
    faces.append(bm.faces.new(ring_verts[-1]))
    for f in faces:
        f.material_index = mat_index
        for loop in f.loops:
            loop[uv_layer].uv = uv_of(loop.vert.co) if uv_of else Vector((0.5, 0.5))
    return faces


def add_palm_frond(bm, start_pt, length, angle, crown_center, uv_layer, rng=None, segments=6):
    """A downward-curving palm frond, built solid."""
    if rng is None:
        rng = random.Random(42)
    start_v = Vector(start_pt)
    px, py = -math.sin(angle), math.cos(angle)
    stations = []
    for s in range(segments + 1):
        t = float(s) / float(segments)
        fz = math.sin(t * math.pi * 0.4) * 0.3 - (t ** 1.8) * length * 0.55
        c = start_v + Vector((math.cos(angle) * t * length,
                              math.sin(angle) * t * length, fz))
        w = 0.45 * (1.0 - t * 0.85) * (math.sin(t * math.pi) * 0.6 + 0.4) * 0.5
        half = Vector((px * w, py * w, 0.0))
        up = Vector((0.0, 0.0, 0.035 * (1.0 - t * 0.5)))
        stations.append([c + half + up, c - half + up, c - half - up, c + half - up])
    return _add_solid_ribbon(bm, stations, uv_layer,
                             uv_of=lambda co: Vector((0.5, np.clip((co - start_v).length / max(length, 1e-3), 0.0, 1.0))))


def add_willow_streamer(bm, start_pt, length, crown_center, uv_layer, rng=None):
    """A cascading willow streamer hanging toward the ground, built solid."""
    if rng is None:
        rng = random.Random(42)
    start_v = Vector(start_pt)
    segments = 5
    yaw = rng.uniform(0, 2.0 * math.pi)
    px, py = -math.sin(yaw), math.cos(yaw)
    stations = []
    for s in range(segments + 1):
        t = float(s) / float(segments)
        sway = math.sin(t * math.pi * 1.5) * 0.15
        c = start_v + Vector((sway, sway * 0.5, -t * length))
        w = 0.35 * 0.4 * (1.0 - t * 0.5)
        half = Vector((px * w, py * w, 0.0))
        up = Vector((0.0, 0.0, 0.03))
        stations.append([c + half + up, c - half + up, c - half - up, c + half - up])
    return _add_solid_ribbon(bm, stations, uv_layer,
                             uv_of=lambda co: Vector((0.5, np.clip((start_v.z - co.z) / max(length, 1e-3), 0.0, 1.0))))


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
    return finalize_mesh_dual(bm, name, mat0_builder=mat0_fn, mat1_builder=mat1_fn, faceted=True)


# ---------------------------------------------------------------------------
# 2. Authentic Geological Rocks (7 Formations x 5 Variants = 35 Models)
# ---------------------------------------------------------------------------

# ---------------------------------------------------------------------------
# Hard-surface rock toolkit (2026-08-27 rebuild)
# ---------------------------------------------------------------------------
#
# Playtest: the boulder pool read as "rounded cotton/popcorn or coral-like
# blobs rather than stone". The geometry was not actually the whole story -
# fracture_mesh_z() below has always cut real planar facets - so it is worth
# recording what the three causes actually were, because two of them are
# invisible in the source.
#
# 1. THE FACETS WERE BEING SHADED AWAY. finalize_mesh() called
#    shade_smooth() and then set `mesh.use_auto_smooth` / `auto_smooth_angle`
#    inside a bare `except Exception: pass`. `Mesh.use_auto_smooth` was
#    REMOVED in Blender 4.1; this project builds with 5.2. So the assignment
#    raised AttributeError on every single prop, was swallowed, and every
#    rock shipped fully smooth-shaded with NO angle limit - vertex normals
#    averaged straight across every fracture plane. Verified directly against
#    this Blender: `hasattr(mesh, "use_auto_smooth")` is False,
#    `bpy.ops.object.shade_auto_smooth` exists. apply_faceted_shading() below
#    uses the new operator and RAISES if neither path is available, because a
#    silent shading failure is exactly what cost us the last pool.
#
# 2. Two of the seven families were icospheres. "Granite Tor" and "Glacial
#    Erratic" were create_icosphere() + sine-noise displacement, which is a
#    lumpy ball however much the silhouette is noised - build_meshes.py's own
#    build_boulder() docstring had already reached this conclusion and moved
#    to plane cuts. Three more families were 5-8 segment cylinders, which are
#    lobes. Every family is now built from angular convex chunks instead.
#
# 3. Nothing darkened the creases. There was no AO anywhere in this file, so
#    at the game's low light levels a fracture and a flat face returned the
#    same value and the silhouette carried the entire read. AO is now baked
#    into the albedo (_bake_ao_into_albedo), which is independent of scene
#    lighting and therefore survives a night map.
#
# The construction is deliberately mechanical - convex hull of jittered
# points, boolean union, angle-limited bevel - rather than sculpted or
# subdivided. Every rock is reproducible from its index, and nothing here
# needs an artist's judgement to re-run.

ROCK_TEX_SIZE = 256
# Cycles AO bake settings. Fixed seed + denoising off: re-running this script
# must produce byte-identical GLBs or every regeneration is a multi-megabyte
# binary diff for no change (same determinism rule tools/audio/ works under).
ROCK_AO_SAMPLES = 32
ROCK_AO_SEED = 0
# How far AO is allowed to pull the albedo down in a fully-occluded crevice.
# Applied AFTER normalising the bake's exposed-face level to 1.0, so this
# darkens creases without dimming the rock as a whole - which matters because
# the terrain these sit on is already short of value range.
ROCK_AO_STRENGTH = 0.75


def _active_only(obj):
    """Make `obj` the sole selected + active object.

    Operators below read both selection AND active independently, and every
    one of them is called in sequence on different objects, so this has to be
    re-asserted rather than assumed.
    """
    bpy.ops.object.select_all(action='DESELECT')
    bpy.context.view_layer.objects.active = obj
    obj.select_set(True)


def apply_faceted_shading(obj, angle_deg=24.0):
    """Split the mesh along every edge sharper than `angle_deg`, then smooth.

    EDGE_SPLIT rather than shade_auto_smooth(), deliberately. Both produce the
    same look in Blender, but they survive glTF export very differently:

      - shade_auto_smooth() in 4.1+ adds a "Smooth by Angle" geometry-nodes
        modifier that writes CUSTOM SPLIT NORMALS. Whether those reach the GLB
        depends on the exporter applying modifiers and on custom normals being
        carried through - two more places the facets can silently vanish
        between here and Godot.
      - EDGE_SPLIT physically duplicates the vertices along sharp edges. Once
        applied it is ordinary geometry with ordinary normals. There is no
        export setting that can quietly undo it.

    Given cause (1) in the block header - an entire rock pool shipped smooth
    because a shading call failed without saying so - the version that cannot
    fail silently is worth the handful of extra vertices.
    """
    _active_only(obj)
    bpy.ops.object.shade_smooth()
    mod = obj.modifiers.new(name="rock_edge_split", type='EDGE_SPLIT')
    mod.use_edge_angle = True
    mod.use_edge_sharp = False
    mod.split_angle = math.radians(angle_deg)
    bpy.ops.object.modifier_apply(modifier=mod.name)


def _chunk_points(rng, half, n_points=14, roughness=0.30):
    """Jittered points on an anisotropic ellipsoid, for convex-hull input.

    Pulling each point inward by a random fraction is what makes the hull
    FACETED rather than a polygonised ellipsoid: neighbouring points at
    different radii put the hull plane through both of them at an angle, so
    one face spans a wide arc instead of each point getting its own tiny
    face. `half` being a 3-tuple is what gives slabs, columns and cubes from
    one primitive.
    """
    pts = []
    for _ in range(n_points):
        v = Vector((rng.gauss(0.0, 1.0), rng.gauss(0.0, 1.0), rng.gauss(0.0, 1.0)))
        if v.length < 1e-6:
            v = Vector((1.0, 0.0, 0.0))
        v.normalize()
        r = 1.0 - rng.random() * roughness
        pts.append(Vector((v.x * half[0], v.y * half[1], v.z * half[2])) * r)
    return pts


def _hull_object(name, pts):
    """A convex, outward-facing solid through `pts`."""
    bm = bmesh.new()
    for p in pts:
        bm.verts.new(p)
    bm.verts.ensure_lookup_table()
    res = bmesh.ops.convex_hull(bm, input=bm.verts[:])
    # convex_hull leaves the points it did not use behind. Left in place they
    # are loose verts inside the solid, which survive into the GLB and give
    # smart_project stray islands to allocate UV space to.
    # Deduped by identity: the three result lists OVERLAP (a vert can be both
    # interior and unused), and bmesh.ops.delete raises ValueError - "found
    # the same element used multiple times" - rather than ignoring the repeat.
    seen = set()
    junk = []
    for key in ("geom_interior", "geom_unused", "geom_holes"):
        for g in res.get(key, []):
            if isinstance(g, bmesh.types.BMVert) and g.is_valid and id(g) not in seen:
                seen.add(id(g))
                junk.append(g)
    if junk:
        bmesh.ops.delete(bm, geom=junk, context='VERTS')
    bmesh.ops.recalc_face_normals(bm, faces=bm.faces[:])
    me = bpy.data.meshes.new(name + "_mesh")
    bm.to_mesh(me)
    bm.free()
    obj = bpy.data.objects.new(name, me)
    bpy.context.collection.objects.link(obj)
    return obj


def _boolean_union(base, others):
    """Fuse `others` into `base` and delete them.

    EXACT solver, not FAST: the chunks meet at shallow angles where FAST
    drops faces and leaves the rock with holes that holes_fill() then caps
    flat, which reads as a sliced-off rock rather than a fused one.
    """
    for other in others:
        mod = base.modifiers.new(name="rock_union", type='BOOLEAN')
        mod.operation = 'UNION'
        mod.object = other
        mod.solver = 'EXACT'
        _active_only(base)
        bpy.ops.object.modifier_apply(modifier=mod.name)
        bpy.data.objects.remove(other, do_unlink=True)


def _bevel_edges(obj, width, angle_deg=35.0, segments=1):
    """Selective bevel - only edges sharper than `angle_deg`.

    This is the "catch the light" pass: a perfectly sharp fracture edge is
    one pixel wide at RTS zoom and disappears, while a narrow bevel gives it
    a lit sliver that holds the facet's boundary. Angle-limited so it hits
    fracture edges and skips the near-flat ones inside a face.
    """
    mod = obj.modifiers.new(name="rock_bevel", type='BEVEL')
    mod.width = width
    mod.segments = segments
    mod.limit_method = 'ANGLE'
    mod.angle_limit = math.radians(angle_deg)
    mod.harden_normals = False
    _active_only(obj)
    bpy.ops.object.modifier_apply(modifier=mod.name)


def _albedo_image_of(mat):
    """The albedo image inside a material built by build_rock_pbr_material."""
    for n in mat.node_tree.nodes:
        if n.type == 'TEX_IMAGE' and n.image is not None and n.image.name.endswith("_albedo"):
            return n.image
    return None


def _bake_ao_into_albedo(obj, size=ROCK_TEX_SIZE, samples=ROCK_AO_SAMPLES,
                         strength=ROCK_AO_STRENGTH):
    """Multiply a Cycles AO bake into the rock's albedo texture.

    Baked rather than left to the engine because the game runs dark: SSAO at
    the scene's radius does not find a 3 cm fracture, and a night map has
    almost no direct light to carve one out. Baking it into albedo makes the
    facets readable at any light level, which is the whole point.

    Normalised before it is applied. A raw AO bake on a convex-ish solid sits
    well below 1.0 even on fully exposed faces, so multiplying it in directly
    would darken the entire rock - the opposite of what is wanted here. The
    90th percentile of the MAPPED texels is taken as "fully exposed" and
    scaled to 1.0, so only genuinely occluded texels lose value.

    Returns True if AO was applied. A failed bake leaves the albedo untouched
    and warns, rather than multiplying it by a black image.
    """
    # First NON-EMPTY slot, not slot 0. The boolean modifier inherits a slot
    # from each operand, and the chunk objects carry no material, so a fused
    # rock arrives here with one or more empty slots ahead of the real one.
    mat = next((m for m in obj.data.materials if m is not None and m.node_tree is not None), None)
    if mat is None:
        return False
    albedo_img = _albedo_image_of(mat)
    if albedo_img is None:
        print("  [ao] %s: no albedo image found, skipping AO" % obj.name)
        return False

    scene = bpy.context.scene
    prev_engine = scene.render.engine
    node_tree = mat.node_tree
    ao_img = bpy.data.images.new(obj.name + "_ao_tmp", width=size, height=size)
    node = node_tree.nodes.new("ShaderNodeTexImage")
    node.image = ao_img
    prev_active = node_tree.nodes.active
    # bpy.ops.object.bake writes to the ACTIVE image texture node of the
    # material - there is no explicit target argument.
    node_tree.nodes.active = node

    applied = False
    try:
        scene.render.engine = 'CYCLES'
        scene.cycles.device = 'CPU'
        scene.cycles.samples = samples
        scene.cycles.use_denoising = False
        scene.cycles.seed = ROCK_AO_SEED
        scene.render.bake.use_selected_to_active = False
        scene.render.bake.margin = 6
        _active_only(obj)
        bpy.ops.object.bake(type='AO')

        ao = np.empty(size * size * 4, dtype=np.float32)
        ao_img.pixels.foreach_get(ao)
        ao = ao.reshape(-1, 4)[:, 0]

        # Texels no UV island covers bake to 0. Treated as unmapped rather
        # than as fully occluded - the bake margin bleeds over most of them,
        # and darkening the rest to black would show as blotches wherever a
        # seam lands.
        mapped = ao > 0.001
        if not mapped.any():
            print("  [ao] %s: bake produced no mapped texels, skipping" % obj.name)
        else:
            exposed = float(np.percentile(ao[mapped], 90.0))
            if exposed <= 1e-4:
                exposed = 1.0
            norm = np.clip(ao / exposed, 0.0, 1.0)
            factor = np.where(mapped, 1.0 - strength * (1.0 - norm), 1.0).astype(np.float32)

            alb = np.empty(size * size * 4, dtype=np.float32)
            albedo_img.pixels.foreach_get(alb)
            alb = alb.reshape(-1, 4)
            alb[:, 0:3] *= factor[:, None]
            albedo_img.pixels.foreach_set(np.ascontiguousarray(alb).ravel())
            albedo_img.pack()
            applied = True
    except Exception as e:
        # Never fail the whole roster over one rock's bake - but say so
        # loudly, because a pool built without AO is the thing we are here to
        # fix and it must not pass silently.
        print("  [ao] %s: bake FAILED (%s: %s) - albedo left unmodified"
              % (obj.name, type(e).__name__, e))
    finally:
        node_tree.nodes.remove(node)
        node_tree.nodes.active = prev_active
        bpy.data.images.remove(ao_img)
        scene.render.engine = prev_engine
    return applied


# Per-formation construction recipe. `spread`/`chunk_scale` are what deliver
# the brief's "mix of large fractured masses and smaller rubble" instead of
# uniform lobes of one size: every rock gets one dominant mass plus a tail of
# subordinate chunks an order of magnitude smaller.
#
#   base_half   - half-extents of the dominant mass (x, y, z), Z-up
#   extras      - (count_min, count_max) subordinate chunks
#   chunk_scale - (min, max) fraction of the dominant mass
#   spread      - how far subordinate chunks sit from centre, in mass radii
#   cuts        - fracture_mesh_z plane cuts, applied to the fused mass
#   h_bias      - fracture bias_horizontal (1.0 = bedding planes only)
#   shade       - edge-split angle; lower = crisper facets
#   points      - convex-hull input points for the dominant mass
#   rubble      - (min, max) ground-level debris chips fused in after cutting
#
# Two numbers here are the difference between "rock" and "shard", and both
# were wrong on the first pass:
#
#   `points` was 8-13, which is not enough to hull a chunky solid. A hull
#   through that few points is dominated by 3 or 4 huge faces, so one fracture
#   cut turns it into a wedge - it read as broken glass rather than as mass.
#   14-19 gives a blockier base that still cuts cleanly.
#
#   `cuts` was 3-7. Combined with the wedge problem above, the rocks were
#   being sliced rather than shaved. 2-4 is enough to plant a couple of
#   convincing flat fracture faces without eating the silhouette.
ROCK_FORMATIONS = [
    # 0: Columnar Basalt - tall, near-vertical, strongly bedded
    dict(base_half=(0.70, 0.68, 1.45), extras=(3, 5), chunk_scale=(0.30, 0.55),
         spread=0.85, cuts=3, h_bias=0.72, shade=18.0, points=16, rubble=(3, 5)),
    # 1: Sedimentary Sandstone - wide low slabs, horizontal breaks
    dict(base_half=(1.50, 1.30, 0.78), extras=(2, 4), chunk_scale=(0.30, 0.60),
         spread=0.80, cuts=4, h_bias=0.88, shade=20.0, points=18, rubble=(3, 6)),
    # 2: Granite Tor - stacked blocky corestones (was an icosphere)
    # shade 21, not 26: at 26 the corestone's shallower facet joins smoothed
    # together and it read as a potato next to the other six families.
    dict(base_half=(1.25, 1.15, 1.10), extras=(2, 3), chunk_scale=(0.45, 0.75),
         spread=0.62, cuts=3, h_bias=0.30, shade=21.0, points=18, rubble=(2, 4)),
    # 3: Karst Limestone - tall fluted spire
    dict(base_half=(0.95, 0.90, 1.65), extras=(2, 4), chunk_scale=(0.25, 0.45),
         spread=0.75, cuts=4, h_bias=0.15, shade=20.0, points=17, rubble=(3, 5)),
    # 4: Glacial Erratic - one big angular mass, barely broken (was an icosphere)
    dict(base_half=(1.40, 1.20, 1.05), extras=(1, 2), chunk_scale=(0.30, 0.50),
         spread=0.70, cuts=2, h_bias=0.35, shade=23.0, points=19, rubble=(2, 4)),
    # 5: Scree / Talus - a low wide pile, no dominant mass at all.
    # extras/rubble held down relative to the other families: this one fuses
    # the most hulls and was the polycount outlier at 671 tris against ~300
    # for the rest. _spawn_slope_rocks() instances up to 260 of these as
    # separate PackedScenes (not a MultiMesh), so the tail matters.
    dict(base_half=(0.80, 0.75, 0.48), extras=(5, 7), chunk_scale=(0.40, 1.00),
         spread=1.60, cuts=2, h_bias=0.25, shade=18.0, points=12, rubble=(3, 5)),
    # 6: Crystalline Matrix - blocky host with angular prisms breaking out
    dict(base_half=(1.15, 1.05, 0.95), extras=(4, 6), chunk_scale=(0.22, 0.42),
         spread=0.85, cuts=2, h_bias=0.15, shade=16.0, points=14, rubble=(3, 5)),
]

# Ground-level debris fused into every rock after it is cut. Every family gets
# some, not just the talus pile: a fractured mass that sheds nothing reads as
# a prop set down on the terrain, while a few chips at its base read as
# something that broke where it sits - and they give the eye a size reference,
# which is most of what sells a boulder as large.
# Kept close and given real thickness on purpose. At the first pass these were
# 0.07-0.19 scale out at 0.85-1.55 mass radii, and they read as scattered paper
# litter rather than rock fall - too small to have mass, too far out to belong
# to the boulder they came off. Debris has to touch its parent to be debris.
RUBBLE_SCALE = (0.10, 0.24)
RUBBLE_RING = (0.60, 1.15)  # distance from centre, in mass radii


def build_geological_rock(name, rock_idx=0):
    """An angular, faceted rock in one of 7 formation families x 5 variants.

    Built from convex chunks fused with a boolean union, cut with fracture
    planes, selectively bevelled and angle-shaded - see the toolkit header
    above for why each of those steps is load-bearing.
    """
    seed = 700 + rock_idx
    rng = random.Random(seed)

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

    spec = ROCK_FORMATIONS[formation]
    # Variant is a SCALE ladder, not just a reshuffle. 0.62 -> 1.34 of the
    # family's base size, so the 35-model pool spans small rubble to large
    # masses on its own. terrain_builder.gd then jitters each instance
    # 0.55-1.5 on top, but that only stretches whatever range the pool has -
    # if every model were one size, per-instance scaling reads as the same
    # rock zoomed, which is exactly the "uniform lobes" complaint.
    v_scale = 0.62 + 0.18 * variant
    base_half = tuple(c * v_scale for c in spec["base_half"])

    chunks = [_hull_object("%s_c0" % name,
                           _chunk_points(rng, base_half, n_points=spec["points"]))]
    mass_r = max(base_half)
    n_extra = rng.randint(spec["extras"][0], spec["extras"][1])
    for i in range(n_extra):
        f = rng.uniform(spec["chunk_scale"][0], spec["chunk_scale"][1])
        half = tuple(c * f for c in base_half)
        ang = rng.uniform(0.0, 2.0 * math.pi)
        dist = mass_r * spec["spread"] * rng.uniform(0.35, 1.0)
        # Biased LOW and inward. A subordinate chunk should read as broken
        # off the mass and settled against it; perched on top it reads as a
        # snowman, which is half of what made the old pool look like popcorn.
        off = Vector((math.cos(ang) * dist,
                      math.sin(ang) * dist,
                      rng.uniform(-0.20, 0.45) * base_half[2]))
        pts = [p + off for p in _chunk_points(rng, half,
                                              n_points=max(6, spec["points"] - 3))]
        chunks.append(_hull_object("%s_c%d" % (name, i + 1), pts))

    obj = chunks[0]
    _boolean_union(obj, chunks[1:])

    # Fracture planes AFTER the union, not per chunk. Cutting each chunk
    # first only shaves corners the union then buries; cutting the fused
    # solid drives one continuous break across several chunks, which is what
    # a real fracture does and what makes a pile read as one broken rock
    # rather than several pebbles touching.
    bm = bmesh.new()
    bm.from_mesh(obj.data)
    bound_r = max((v.co.length for v in bm.verts), default=mass_r)
    # fracture_mesh_z puts its plane at radius * U(0.35, 0.75). Scaled so that
    # lands at 0.74-1.58 x the real bounding radius, i.e. the plane either
    # shaves the outer quarter or misses entirely. At the previous 1.75x the
    # near end reached 0.61x and cut through the body of the rock, which is
    # what produced the thin triangular wedges.
    fracture_mesh_z(bm, cuts=spec["cuts"], radius=bound_r * 2.1, rng=rng,
                    bias_horizontal=spec["h_bias"])
    bm.to_mesh(obj.data)
    bm.free()

    # Rubble goes in AFTER the cuts, or the fracture planes - which sit at
    # 0.74x the bounding radius and outward - would simply delete chips that
    # by definition live at 0.85x and beyond.
    base_z = -base_half[2]
    rubble = []
    for i in range(rng.randint(spec["rubble"][0], spec["rubble"][1])):
        f = rng.uniform(*RUBBLE_SCALE)
        half = tuple(max(0.04, c * f) for c in base_half)
        ang = rng.uniform(0.0, 2.0 * math.pi)
        dist = mass_r * rng.uniform(*RUBBLE_RING)
        off = Vector((math.cos(ang) * dist,
                      math.sin(ang) * dist,
                      base_z + half[2] * rng.uniform(0.35, 0.9)))
        # 9 points at low roughness, not 7 at high: a chip hulled from too few
        # scattered points comes out as a flat sliver, which is what made the
        # first pass look like litter.
        pts = [p + off for p in _chunk_points(rng, half, n_points=9, roughness=0.28)]
        rubble.append(_hull_object("%s_r%d" % (name, i), pts))
    _boolean_union(obj, rubble)

    # Sit the whole assembly on z=0 last, once every piece is in place.
    bm = bmesh.new()
    bm.from_mesh(obj.data)
    min_z = min((v.co.z for v in bm.verts), default=0.0)
    bmesh.ops.translate(bm, verts=bm.verts, vec=(0, 0, -min_z))
    for f in bm.faces:
        f.material_index = 0
    bm.to_mesh(obj.data)
    bm.free()

    # Narrow, angle-limited. A perfectly sharp fracture edge is sub-pixel at
    # RTS zoom and disappears; a small bevel gives it a lit sliver that holds
    # the facet boundary. Scaled to the rock so a small one is not all bevel.
    _bevel_edges(obj, width=min(0.05, mass_r * 0.035), angle_deg=35.0)
    apply_faceted_shading(obj, angle_deg=spec["shade"])
    unwrap_mesh(obj)

    # Drop the empty slots the boolean modifier inherited from the chunk
    # operands before appending, so material_index 0 (set on every face
    # above) resolves to the rock material rather than to an empty slot.
    obj.data.materials.clear()
    mat = build_rock_pbr_material(name + "_mat", base_color=col, roughness=0.92,
                                  metallic=0.0, seed=seed, size=ROCK_TEX_SIZE)
    obj.data.materials.append(mat)
    _bake_ao_into_albedo(obj)
    return obj


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
    return finalize_mesh_dual(bm, name, mat0_builder=mat0_fn, mat1_builder=mat1_fn, faceted=True)


# ---------------------------------------------------------------------------
# Ground vegetation: bushes, ferns, brush mats and thickets
# ---------------------------------------------------------------------------
#
# WHY THIS EXISTS. Everything green on the map used to be a 6-9 m tree on a
# bare floor, which at the RTS camera is a field of lollipops over nothing. The
# grass tufts that were supposed to cover the floor were 1.1 m across and did
# not resolve at that distance at all - they were dropped for exactly that
# reason, and dropping them left the ground bare rather than fixing it.
#
# The size rule this set is built to: a prop has to be at least ~2 m across
# before it registers from the battle camera, and ground cover has to be 3 m+
# because it is being read at a glancing angle. So none of these are scaled-
# down trees; they are authored at the size that reads, and they are WIDER THAN
# THEY ARE TALL, which is what stops them reading as more lollipops.
#
#   ground_bush   2.0-3.0 m wide, 0.9-1.5 m tall   the workhorse
#   fern_clump    1.6-2.4 m wide, 0.6-1.0 m tall   arching fronds, shade/damp
#   brush_mat     3.0-4.2 m wide, 0.3-0.6 m tall   ground cover, replaces grass
#   thicket       2.6-3.8 m wide, 1.5-2.3 m tall   dense undergrowth mass

# Authored as sRGB leaf colours; retarget_foliage_colour() puts each onto a
# physical albedo. Varied so a hillside of one layer is not one flat green.
FOLIAGE_PALETTES = [
    ((0.20, 0.38, 0.16), (0.26, 0.19, 0.13)),   # broadleaf green
    ((0.24, 0.36, 0.14), (0.30, 0.22, 0.14)),   # olive
    ((0.16, 0.32, 0.18), (0.24, 0.18, 0.13)),   # deep shade green
    ((0.28, 0.34, 0.17), (0.32, 0.24, 0.15)),   # dry sage
    ((0.15, 0.30, 0.22), (0.22, 0.18, 0.15)),   # blue-green
    ((0.32, 0.30, 0.15), (0.34, 0.25, 0.14)),   # late-season russet
    ((0.18, 0.35, 0.13), (0.27, 0.20, 0.12)),   # fresh growth
    ((0.22, 0.31, 0.19), (0.29, 0.21, 0.14)),   # dusty heath
]


def add_woody_stem(bm, start_pt, end_pt, r_start, r_end, mat_index=0, segments=4):
    """A short tapered stem. Thin enough that it is structure, not silhouette."""
    faces, _, _ = add_curved_trunk_segment(bm, start_pt, end_pt, r_start, r_end, segments=segments)
    for f in faces:
        f.material_index = mat_index
    return faces


def add_fern_frond(bm, start_pt, length, angle, uv_layer, rng, mat_index=1,
                   segments=6, arch=0.55, width=0.30, thickness=0.035):
    """An arching frond built as a SOLID thin wedge, not a ribbon.

    A single-sided quad strip disappears from one side under back-face culling,
    which is why the existing palm fronds and willow streamers vanish when the
    camera swings around them. Four verts per station costs little and makes
    the frond readable from every angle.
    """
    start_v = Vector(start_pt)
    px, py = -math.sin(angle), math.cos(angle)
    stations = []
    for s in range(segments + 1):
        t = float(s) / float(segments)
        # Rises then arches over - the fern's whole character is in this curve.
        z = math.sin(t * math.pi * 0.62) * length * arch - (t ** 2.4) * length * 0.42
        c = start_v + Vector((math.cos(angle) * t * length,
                              math.sin(angle) * t * length, z))
        w = width * math.sin(min(1.0, t * 1.25 + 0.12) * math.pi) * rng.uniform(0.85, 1.15)
        half = Vector((px * w, py * w, 0.0))
        up = Vector((0.0, 0.0, thickness * (1.0 - t * 0.5)))
        stations.append([c + half + up, c - half + up, c - half - up, c + half - up])

    ring_verts = [[bm.verts.new(p) for p in st] for st in stations]
    faces = []
    for s in range(segments):
        a, b = ring_verts[s], ring_verts[s + 1]
        for i in range(4):
            j = (i + 1) % 4
            faces.append(bm.faces.new([a[i], a[j], b[j], b[i]]))
    faces.append(bm.faces.new(list(reversed(ring_verts[0]))))
    faces.append(bm.faces.new(ring_verts[-1]))

    for f in faces:
        f.material_index = mat_index
        for loop in f.loops:
            d = (loop.vert.co - start_v).length / max(length, 1e-3)
            loop[uv_layer].uv = Vector((0.5 + 0.4 * math.sin(d * 9.0), np.clip(d, 0.0, 1.0)))
    return faces


def _finalise_ground_plant(bm, name, seed, leaf_col, stem_col):
    min_z = min(v.co.z for v in bm.verts)
    if min_z != 0.0:
        bmesh.ops.translate(bm, verts=bm.verts, vec=(0, 0, -min_z))
    mat0_fn = lambda n: build_bark_pbr_material(n, base_color=stem_col, roughness=0.98, seed=seed)
    mat1_fn = lambda n: build_foliage_alpha_material(n, base_color=leaf_col, seed=seed + 7)
    return finalize_mesh_dual(bm, name, mat0_builder=mat0_fn, mat1_builder=mat1_fn,
                              faceted=True, facet_angle=28.0)


def build_ground_bush(name, seed=0, palette=0):
    """A broad, low, multi-lobed woody bush - wider than tall."""
    rng = random.Random(seed)
    bm = bmesh.new()
    uv_layer = bm.loops.layers.uv.new("UVMap")
    leaf_col, stem_col = FOLIAGE_PALETTES[palette % len(FOLIAGE_PALETTES)]

    spread = rng.uniform(1.00, 1.50)      # half-width, so 2.0-3.0 m across
    height = rng.uniform(0.90, 1.50)
    n_lobes = rng.randint(6, 9)

    for i in range(rng.randint(3, 5)):
        ang = (2.0 * math.pi * i) / 4.0 + rng.uniform(-0.4, 0.4)
        tip = Vector((math.cos(ang) * spread * 0.45, math.sin(ang) * spread * 0.45,
                      height * rng.uniform(0.45, 0.70)))
        add_woody_stem(bm, (0, 0, 0), tip, 0.075, 0.035)

    for i in range(n_lobes):
        ang = (2.0 * math.pi * i) / float(n_lobes) + rng.uniform(-0.30, 0.30)
        # Bias outward and downward: the mass sits low and sprawls.
        r = spread * rng.uniform(0.30, 0.86)
        z = height * rng.uniform(0.34, 0.80) * (1.0 - 0.42 * (r / spread))
        lobe_r = spread * rng.uniform(0.34, 0.50)
        add_foliage_lobe(bm, (math.cos(ang) * r, math.sin(ang) * r, z),
                         radius=lobe_r, height=lobe_r * rng.uniform(0.80, 1.15),
                         uv_layer=uv_layer, rng=rng,
                         tilt=rng.uniform(0.10, 0.42), tilt_dir=ang)
    return _finalise_ground_plant(bm, name, seed, leaf_col, stem_col)


def build_fern_clump(name, seed=0, palette=2):
    """A rosette of arching fronds. Reads as damp, shaded ground."""
    rng = random.Random(seed)
    bm = bmesh.new()
    uv_layer = bm.loops.layers.uv.new("UVMap")
    leaf_col, stem_col = FOLIAGE_PALETTES[palette % len(FOLIAGE_PALETTES)]

    n_fronds = rng.randint(8, 12)
    reach = rng.uniform(0.80, 1.20)       # half-width, 1.6-2.4 m across
    for i in range(n_fronds):
        ang = (2.0 * math.pi * i) / float(n_fronds) + rng.uniform(-0.22, 0.22)
        base = Vector((math.cos(ang) * 0.08, math.sin(ang) * 0.08, 0.04))
        add_fern_frond(bm, base, length=reach * rng.uniform(0.85, 1.15), angle=ang,
                       uv_layer=uv_layer, rng=rng,
                       arch=rng.uniform(0.46, 0.66), width=rng.uniform(0.22, 0.34))
    # A little mass at the crown so the centre is not a hole seen from above.
    add_foliage_lobe(bm, (0, 0, 0.10), radius=reach * 0.26, height=reach * 0.22,
                     uv_layer=uv_layer, rng=rng, segments=6, irregular=0.40)
    return _finalise_ground_plant(bm, name, seed, leaf_col, stem_col)


def build_brush_mat(name, seed=0, palette=7):
    """Low sprawling ground cover, 3-4 m across and ankle height.

    This is the direct answer to the grass tufts: same job, ~3x the footprint
    and a fraction of the instance count, because one mat covers what a dozen
    tufts did.
    """
    rng = random.Random(seed)
    bm = bmesh.new()
    uv_layer = bm.loops.layers.uv.new("UVMap")
    leaf_col, stem_col = FOLIAGE_PALETTES[palette % len(FOLIAGE_PALETTES)]

    reach = rng.uniform(1.50, 2.10)       # half-width, 3.0-4.2 m across
    n_lobes = rng.randint(12, 20)
    for i in range(n_lobes):
        ang = rng.uniform(0.0, 2.0 * math.pi)
        # sqrt keeps the scatter area-uniform instead of crowding the centre.
        r = reach * math.sqrt(rng.uniform(0.0, 1.0))
        lobe_r = reach * rng.uniform(0.16, 0.30) * (1.0 - 0.30 * (r / reach))
        add_foliage_lobe(bm, (math.cos(ang) * r, math.sin(ang) * r,
                              rng.uniform(0.0, 0.12)),
                         radius=lobe_r, height=lobe_r * rng.uniform(0.42, 0.70),
                         uv_layer=uv_layer, rng=rng, segments=6, irregular=0.40,
                         tilt=rng.uniform(0.0, 0.26), tilt_dir=ang)
    return _finalise_ground_plant(bm, name, seed, leaf_col, stem_col)


def build_thicket(name, seed=0, palette=4):
    """Dense tangled undergrowth - a solid mass, not a plant with a silhouette."""
    rng = random.Random(seed)
    bm = bmesh.new()
    uv_layer = bm.loops.layers.uv.new("UVMap")
    leaf_col, stem_col = FOLIAGE_PALETTES[palette % len(FOLIAGE_PALETTES)]

    reach = rng.uniform(1.30, 1.90)       # half-width, 2.6-3.8 m across
    height = rng.uniform(1.50, 2.30)

    # Crossing stems, deliberately not radial - a thicket has no centre.
    for _ in range(rng.randint(5, 8)):
        a0 = rng.uniform(0.0, 2.0 * math.pi)
        a1 = a0 + rng.uniform(1.8, 4.4)
        p0 = Vector((math.cos(a0) * reach * rng.uniform(0.3, 0.8),
                     math.sin(a0) * reach * rng.uniform(0.3, 0.8), 0.0))
        p1 = Vector((math.cos(a1) * reach * rng.uniform(0.2, 0.6),
                     math.sin(a1) * reach * rng.uniform(0.2, 0.6),
                     height * rng.uniform(0.55, 0.95)))
        add_woody_stem(bm, p0, p1, 0.065, 0.028)

    for _ in range(rng.randint(9, 14)):
        ang = rng.uniform(0.0, 2.0 * math.pi)
        r = reach * math.sqrt(rng.uniform(0.0, 1.0)) * 0.92
        z = height * rng.uniform(0.28, 0.88)
        lobe_r = reach * rng.uniform(0.26, 0.42)
        add_foliage_lobe(bm, (math.cos(ang) * r, math.sin(ang) * r, z),
                         radius=lobe_r, height=lobe_r * rng.uniform(0.85, 1.30),
                         uv_layer=uv_layer, rng=rng,
                         tilt=rng.uniform(0.0, 0.38), tilt_dir=ang)
    return _finalise_ground_plant(bm, name, seed, leaf_col, stem_col)


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
    return finalize_mesh_dual(bm, name, mat0_builder=mat0_fn, mat1_builder=mat1_fn, faceted=True)


# ---------------------------------------------------------------------------
# Main Generation Runner
# ---------------------------------------------------------------------------

# Group name -> what it writes, for the --only filter below.
PROP_GROUPS = ["trees", "lumber", "rocks", "grass", "shrubs", "reeds", "flowers",
               "bushes", "ferns", "brushmats", "thickets"]

# How many of each ground-vegetation family to write. Kept here rather than
# inline so the rule file's prop_set `count` and this stay easy to reconcile -
# a mismatch is silent, _prop_paths() just stops at the first missing file.
GROUND_VEG_COUNTS = {"bush": 10, "fern": 6, "brush_mat": 8, "thicket": 6}


def generate_all_terrain_props(only=None):
    """Build every terrain prop, or just the groups named in `only`.

    The filter exists because these groups are NOT independent of each other
    in practice: make_pbr_image()'s colorspace fix (see its docstring) changes
    the normal map of every prop in this file, so a full run would silently
    restyle the tree and shrub roster as a side effect of rebaking rocks.
    Re-exporting a group should be a decision, not a consequence.
    """
    want = (lambda g: True) if not only else (lambda g: g in only)
    unknown = sorted(set(only or []) - set(PROP_GROUPS))
    if unknown:
        raise SystemExit("unknown --only group(s): %s (known: %s)"
                         % (", ".join(unknown), ", ".join(PROP_GROUPS)))

    os.makedirs(TERRAIN_DIR, exist_ok=True)
    if not want("trees"):
        print("[skip] trees")
    else:
        _generate_trees()
    if not want("lumber"):
        print("[skip] lumber")
    else:
        _generate_lumber()
    if not want("rocks"):
        print("[skip] rocks")
    else:
        _generate_rocks()
    if not want("grass"):
        print("[skip] grass")
    else:
        _generate_grass()
    if not want("shrubs"):
        print("[skip] shrubs")
    else:
        _generate_shrubs()
    if not want("reeds"):
        print("[skip] reeds")
    else:
        _generate_reeds()
    if not want("flowers"):
        print("[skip] flowers")
    else:
        _generate_flowers()
    if not want("bushes"):
        print("[skip] bushes")
    else:
        _generate_ground_veg("bush", build_ground_bush, 1200)
    if not want("ferns"):
        print("[skip] ferns")
    else:
        _generate_ground_veg("fern", build_fern_clump, 1300)
    if not want("brushmats"):
        print("[skip] brushmats")
    else:
        _generate_ground_veg("brush_mat", build_brush_mat, 1400)
    if not want("thickets"):
        print("[skip] thickets")
    else:
        _generate_ground_veg("thicket", build_thicket, 1500)

    print("==========================================================")
    print("Terrain prop build complete.")
    print("==========================================================")


def _generate_trees():
    print("==========================================================")
    print("Generating 36 Authentic Volumetric Trees (Zero Spikes)...")
    print("==========================================================")
    for i in range(36):
        clear_scene()
        name = "ambient_tree_%d" % i
        obj = build_organic_tree(name, tree_idx=i)
        export_glb(obj, os.path.join(TERRAIN_DIR, "%s.glb" % name))


def _generate_lumber():
    print("==========================================================")
    print("Generating 3 Harvestable Lumber Node Stands...")
    print("==========================================================")
    for i in range(3):
        clear_scene()
        name = "resource_lumber_%d" % i
        obj = build_organic_tree_stand(name, stand_idx=i)
        export_glb(obj, os.path.join(TERRAIN_DIR, "%s.glb" % name))


def _generate_rocks():
    print("==========================================================")
    print("Generating 35 Geological Rock Formations...")
    print("==========================================================")
    for i in range(35):
        clear_scene()
        name = "boulder_%d" % i
        obj = build_geological_rock(name, rock_idx=i)
        me = obj.data
        print("  %-12s verts=%-5d faces=%-5d" % (name, len(me.vertices), len(me.polygons)))
        export_glb(obj, os.path.join(TERRAIN_DIR, "%s.glb" % name))


def _generate_grass():
    print("==========================================================")
    print("Generating 6 Wide Carpet Grass Turf Mats...")
    print("==========================================================")
    grass_styles = ["prairie", "dense", "fescue", "windswept", "tussock", "tall"]
    for i, style in enumerate(grass_styles):
        clear_scene()
        name = "grass_tuft_%d" % i
        obj = build_organic_grass_tuft(name, seed=800 + i, style=style)
        export_glb(obj, os.path.join(TERRAIN_DIR, "%s.glb" % name))


def _generate_shrubs():
    print("==========================================================")
    print("Generating 4 Organic Shrubs...")
    print("==========================================================")
    for i in range(4):
        clear_scene()
        name = "shrub_%d" % i
        obj = build_organic_shrub(name, seed=900 + i)
        export_glb(obj, os.path.join(TERRAIN_DIR, "%s.glb" % name))


def _generate_reeds():
    print("==========================================================")
    print("Generating 3 Cattails / Wetland Reeds...")
    print("==========================================================")
    for i in range(3):
        clear_scene()
        name = "reed_%d" % i
        obj = build_organic_reeds(name, seed=1000 + i)
        export_glb(obj, os.path.join(TERRAIN_DIR, "%s.glb" % name))


def _generate_flowers():
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


def _generate_ground_veg(prefix, builder, seed_base):
    """Write one ground-vegetation family. Palette cycles so a field varies."""
    n = GROUND_VEG_COUNTS[prefix]
    print("==========================================================")
    print("Generating %d %s..." % (n, prefix))
    print("==========================================================")
    for i in range(n):
        clear_scene()
        name = "%s_%d" % (prefix, i)
        obj = builder(name, seed=seed_base + i, palette=i)
        me = obj.data
        dims = me.vertices and max(
            (max(v.co[a] for v in me.vertices) - min(v.co[a] for v in me.vertices))
            for a in (0, 1))
        print("  %-14s verts=%-5d faces=%-5d width=%.2fm" % (name, len(me.vertices),
                                                             len(me.polygons), dims))
        export_glb(obj, os.path.join(TERRAIN_DIR, "%s.glb" % name))


def _parse_only(argv):
    """--only rocks / --only rocks,shrubs. Args after Blender's `--`."""
    if "--" in argv:
        argv = argv[argv.index("--") + 1:]
    else:
        argv = []
    for i, a in enumerate(argv):
        if a == "--only" and i + 1 < len(argv):
            return [g.strip() for g in argv[i + 1].split(",") if g.strip()]
        if a.startswith("--only="):
            return [g.strip() for g in a.split("=", 1)[1].split(",") if g.strip()]
    return None


if __name__ == "__main__":
    generate_all_terrain_props(only=_parse_only(sys.argv))
