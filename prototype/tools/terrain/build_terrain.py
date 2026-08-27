"""
RTS_CORE_ROADMAP.md B4 & MAP_ROSTER_REBUILD_PLAN.md Phase 4:
The Python terrain authoring/generation pipeline.
Generates deterministic heightmaps, surfacemaps, splatmaps, wetness rasters,
macro-tint maps, and curvature AO maps from map JSON definitions.

Deterministic: every feature and post-pass is fully described by its JSON params
and seeded from the map ID/params (no external random state) - identical inputs
always produce byte-identical PNG outputs.

Usage:
  python tools/terrain/build_terrain.py <map_json_path> [--resolution N] [--pixels-per-unit P]
  python tools/terrain/build_terrain.py --all [--resolution N]
"""
import argparse
import glob
import json
import math
import os
import sys
import zlib

import numpy as np
from PIL import Image

# Default pixels per world unit. Keeps mapping exact at integer coordinates.
DEFAULT_PIXELS_PER_UNIT = 1.0

# 16-bit heightmap encoding: normalized = clamp(raw_height_world / height_scale, -1, 1),
# pixel16 = round((normalized + 1.0) * 32767.5). Split across R+G channels of RGBA8 PNG.
HEIGHT_PIXEL_MAX = 65535

# Surface palette (Index 0 is "no surface_zone" / plain ground)
SURFACE_PALETTE = ["", "marsh", "rocky", "snow_mud", "sand", "gravel", "forest", "ice", "dirt", "steppe_grass", "dry_grass", "mud", "cobble", "scree", "volcanic"]


def _smoothstep(t):
    t = np.clip(t, 0.0, 1.0)
    return t * t * (3.0 - 2.0 * t)


def _quintic(t):
    t = np.clip(t, 0.0, 1.0)
    return t * t * t * (t * (t * 6.0 - 15.0) + 10.0)


def _point_to_segment_dist_and_t(px, pz, x0, z0, x1, z1):
    """Vectorized point-to-segment distance, plus the projected t in [0,1]."""
    dx, dz = x1 - x0, z1 - z0
    seg_len2 = dx * dx + dz * dz
    if seg_len2 <= 1e-9:
        t = np.zeros_like(px)
        cx, cz = x0, z0
    else:
        t = ((px - x0) * dx + (pz - z0) * dz) / seg_len2
        t = np.clip(t, 0.0, 1.0)
        cx = x0 + t * dx
        cz = z0 + t * dz
    dist = np.sqrt((px - cx) ** 2 + (pz - cz) ** 2)
    return dist, t


def _signed_dist_to_line(px, pz, x0, z0, x1, z1):
    """Signed perpendicular distance to the infinite line through (x0,z0)->(x1,z1)."""
    dx, dz = x1 - x0, z1 - z0
    length = math.hypot(dx, dz)
    if length <= 1e-9:
        return np.zeros_like(px)
    nx, nz = -dz / length, dx / length  # left-hand normal
    return (px - x0) * nx + (pz - z0) * nz


# ---------------------------------------------------------------------------
# Deterministic Noise & Domain Warping
# ---------------------------------------------------------------------------

def _hash21(ix, iz, seed=0):
    """Vectorized deterministic 2D integer hash returning float in [0, 1)."""
    ux = ix.astype(np.int64) & 0xFFFFFFFF
    uz = iz.astype(np.int64) & 0xFFFFFFFF
    s = int(seed) & 0xFFFFFFFF
    n = (ux * 374761393 + uz * 668265263 + s * 1442695041) & 0xFFFFFFFF
    n = ((n ^ (n >> 13)) * 1274126177) & 0xFFFFFFFF
    n = (n ^ (n >> 16)) & 0xFFFFFFFF
    return n.astype(np.float64) / 4294967296.0


def _value_noise_2d(px, pz, seed=0):
    """Vectorized 2D smooth value noise with quintic interpolation."""
    ix0 = np.floor(px).astype(np.int32)
    iz0 = np.floor(pz).astype(np.int32)
    ix1 = ix0 + 1
    iz1 = iz0 + 1

    fx = px - ix0
    fz = pz - iz0
    ux = _quintic(fx)
    uz = _quintic(fz)

    v00 = _hash21(ix0, iz0, seed)
    v10 = _hash21(ix1, iz0, seed)
    v01 = _hash21(ix0, iz1, seed)
    v11 = _hash21(ix1, iz1, seed)

    vx0 = v00 + (v10 - v00) * ux
    vx1 = v01 + (v11 - v01) * ux
    return vx0 + (vx1 - vx0) * uz


def _fbm_2d(px, pz, octaves=4, frequency=0.05, amplitude=1.0, lacunarity=2.0, gain=0.5, seed=0):
    """Vectorized fractal Brownian motion noise."""
    val = np.zeros_like(px, dtype=np.float64)
    amp = float(amplitude)
    freq = float(frequency)
    for i in range(octaves):
        val += amp * _value_noise_2d(px * freq, pz * freq, seed + i * 1013)
        amp *= gain
        freq *= lacunarity
    return val


def _domain_warp_2d(px, pz, strength=5.0, frequency=0.02, seed=0):
    """Returns domain-warped (px_warped, pz_warped) coordinates."""
    wx = _fbm_2d(px + 17.1, pz + 31.7, octaves=2, frequency=frequency, amplitude=strength, seed=seed + 11)
    wz = _fbm_2d(px + 67.3, pz + 89.2, octaves=2, frequency=frequency, amplitude=strength, seed=seed + 73)
    return px + (wx - 0.5 * strength), pz + (wz - 0.5 * strength)


# ---------------------------------------------------------------------------
# Terrain Feature Primitives
# ---------------------------------------------------------------------------

def _hill(px, pz, center, radius, height, falloff):
    dist = np.sqrt((px - center[0]) ** 2 + (pz - center[1]) ** 2)
    t = np.zeros_like(dist)
    if falloff > 0.0:
        t = _smoothstep((dist - radius) / falloff)
    else:
        t = np.where(dist > radius, 1.0, 0.0)
    return height * (1.0 - t)


def _basin(px, pz, center, radius, depth, falloff):
    return -_hill(px, pz, center, radius, depth, falloff)


def _plateau(px, pz, center, half_extents, height, falloff):
    dx = np.abs(px - center[0]) - half_extents[0]
    dz = np.abs(pz - center[1]) - half_extents[1]
    outside = np.sqrt(np.clip(dx, 0, None) ** 2 + np.clip(dz, 0, None) ** 2)
    t = np.zeros_like(outside)
    if falloff > 0.0:
        t = _smoothstep(outside / falloff)
    else:
        t = np.where(outside > 0.0, 1.0, 0.0)
    return height * (1.0 - t)


def _ridge(px, pz, start, end, width, height, falloff):
    dist, _ = _point_to_segment_dist_and_t(px, pz, start[0], start[1], end[0], end[1])
    half_w = width / 2.0
    t = np.zeros_like(dist)
    if falloff > 0.0:
        t = _smoothstep((dist - half_w) / falloff)
    else:
        t = np.where(dist > half_w, 1.0, 0.0)
    return height * (1.0 - t)


def _ravine(px, pz, start, end, width, depth, falloff):
    return -_ridge(px, pz, start, end, width, depth, falloff)


def _escarpment(px, pz, start, end, height, falloff, side):
    signed = _signed_dist_to_line(px, pz, start[0], start[1], end[0], end[1])
    if side == "right":
        signed = -signed
    if falloff <= 0.0:
        falloff = 0.01
    t = _smoothstep(signed / falloff)
    return height * t


def _cliff(px, pz, start, end, height, side, falloff=0.01):
    # canyon_ford PR2 (2026-08-26): `falloff` was hardcoded to 0.01 here.
    # A cliff author needs to be able to soften it (a gentle 1m ramp
    # reads as a "steep slope", a 0.01m ramp reads as a "vertical wall")
    # without writing a custom feature type. The default preserves the
    # pre-PR2 behavior so existing fixtures keep baking identically.
    return _escarpment(px, pz, start, end, height, falloff, side)


def _river(px, pz, f):
    """Meandering spline river channel."""
    width = float(f.get("width", 12.0))
    depth = float(f.get("depth", 4.0))
    falloff = float(f.get("falloff", 8.0))
    bed_flatness = float(f.get("bed_flatness", 0.4))
    meander_amp = float(f.get("meander_amplitude", 0.0))
    meander_freq = float(f.get("meander_frequency", 0.02))

    points = f.get("points")
    if points and len(points) >= 2:
        # Multi-segment polyline path
        min_dist = np.full_like(px, 1e9)
        for i in range(len(points) - 1):
            p0, p1 = points[i], points[i + 1]
            d, _ = _point_to_segment_dist_and_t(px, pz, p0[0], p0[1], p1[0], p1[1])
            min_dist = np.minimum(min_dist, d)
        dist = min_dist
    else:
        start = f.get("start", [-100.0, 0.0])
        end = f.get("end", [100.0, 0.0])
        if meander_amp > 0.0:
            # Subdivide segment with sinusoidal meander displacement
            dx, dz = end[0] - start[0], end[1] - start[1]
            seg_len = math.hypot(dx, dz)
            num_sub = max(8, int(seg_len / 10.0))
            nx, nz = -dz / max(seg_len, 1e-6), dx / max(seg_len, 1e-6)
            
            sub_points = []
            for k in range(num_sub + 1):
                t_sub = k / float(num_sub)
                bx = start[0] + t_sub * dx
                bz = start[1] + t_sub * dz
                offset = meander_amp * math.sin(t_sub * seg_len * meander_freq * 2.0 * math.pi)
                sub_points.append([bx + offset * nx, bz + offset * nz])
            
            min_dist = np.full_like(px, 1e9)
            for i in range(len(sub_points) - 1):
                p0, p1 = sub_points[i], sub_points[i + 1]
                d, _ = _point_to_segment_dist_and_t(px, pz, p0[0], p0[1], p1[0], p1[1])
                min_dist = np.minimum(min_dist, d)
            dist = min_dist
        else:
            dist, _ = _point_to_segment_dist_and_t(px, pz, start[0], start[1], end[0], end[1])

    half_w = width / 2.0
    flat_w = half_w * bed_flatness
    total_w = half_w + falloff

    # Profile: -depth at flat bed, smoothly rising to 0 at total_w
    t = np.zeros_like(dist)
    mask_slope = (dist > flat_w) & (dist <= total_w)
    denom = max(total_w - flat_w, 1e-6)
    t[dist <= flat_w] = 0.0
    t[mask_slope] = _smoothstep((dist[mask_slope] - flat_w) / denom)
    t[dist > total_w] = 1.0

    return -depth * (1.0 - t)


def _terrace(px, pz, f):
    """Shogun-style stepped agriculture / contour terraces."""
    center = f.get("center", [0.0, 0.0])
    radius = float(f.get("radius", 40.0))
    step_height = float(f.get("step_height", 2.5))
    step_count = int(f.get("step_count", 4))
    total_height = float(f.get("height", step_height * step_count))
    falloff = float(f.get("falloff", 10.0))
    smoothness = float(f.get("smoothness", 0.25))

    dist = np.sqrt((px - center[0]) ** 2 + (pz - center[1]) ** 2)
    # Normalized radial distance [0, 1] inside radius
    u = np.clip(dist / max(radius, 1e-6), 0.0, 1.0)
    base_h = total_height * (1.0 - _smoothstep(u))

    # Stepped quantization
    k = base_h / max(step_height, 1e-6)
    k_floor = np.floor(k)
    k_frac = k - k_floor

    # Smooth transition across the riser
    trans = _smoothstep(np.clip((k_frac - (1.0 - smoothness)) / max(smoothness, 1e-6), 0.0, 1.0))
    stepped = (k_floor + trans) * step_height

    # Outer falloff outside radius
    outer_t = np.zeros_like(dist)
    if falloff > 0.0:
        outer_t = _smoothstep((dist - radius) / falloff)
    else:
        outer_t = np.where(dist > radius, 1.0, 0.0)

    return stepped * (1.0 - outer_t)


def _crater(px, pz, f):
    """Impact crater / caldera with central depression and raised ejecta rim."""
    center = f.get("center", [0.0, 0.0])
    radius = float(f.get("radius", 25.0))
    depth = float(f.get("depth", 6.0))
    rim_height = float(f.get("rim_height", depth * 0.3))
    rim_width = float(f.get("rim_width", radius * 0.25))
    falloff = float(f.get("falloff", radius * 0.6))

    dist = np.sqrt((px - center[0]) ** 2 + (pz - center[1]) ** 2)
    h = np.zeros_like(dist)

    # Inside crater: parabolic bowl from -depth up to +rim_height at rim
    inner_mask = dist <= radius
    u_inner = dist[inner_mask] / max(radius, 1e-6)
    # Parabolic cross-section
    h[inner_mask] = -depth + (depth + rim_height) * (u_inner ** 2)

    # Outside rim: decay from +rim_height down to 0 over rim_width + falloff
    outer_mask = dist > radius
    outer_dist = dist[outer_mask] - radius
    t_outer = _smoothstep(outer_dist / max(rim_width + falloff, 1e-6))
    h[outer_mask] = rim_height * (1.0 - t_outer)

    return h


def _berm(px, pz, f):
    """Raised trapezoidal earthen embankment along a line segment."""
    start = f.get("start", [-20.0, 0.0])
    end = f.get("end", [20.0, 0.0])
    width = float(f.get("width", 8.0))
    height = float(f.get("height", 4.0))
    crest_width = float(f.get("crest_width", 2.0))
    falloff = float(f.get("falloff", 4.0))

    dist, _ = _point_to_segment_dist_and_t(px, pz, start[0], start[1], end[0], end[1])
    half_crest = crest_width / 2.0
    half_base = (width / 2.0) + falloff

    t = np.zeros_like(dist)
    mask = dist > half_crest
    denom = max(half_base - half_crest, 1e-6)
    t[mask] = _smoothstep((dist[mask] - half_crest) / denom)
    t[dist > half_base] = 1.0

    return height * (1.0 - t)


def _road_cut(px, pz, f):
    """Excavated / cut corridor through terrain."""
    start = f.get("start", [-30.0, 0.0])
    end = f.get("end", [30.0, 0.0])
    width = float(f.get("width", 10.0))
    depth = float(f.get("depth", 4.0))
    falloff = float(f.get("falloff", 6.0))

    dist, _ = _point_to_segment_dist_and_t(px, pz, start[0], start[1], end[0], end[1])
    half_w = width / 2.0
    total_w = half_w + falloff

    t = np.zeros_like(dist)
    mask = dist > half_w
    denom = max(total_w - half_w, 1e-6)
    t[mask] = _smoothstep((dist[mask] - half_w) / denom)
    t[dist > total_w] = 1.0

    return -depth * (1.0 - t)


FEATURE_BUILDERS = {
    "hill": lambda px, pz, f: _hill(px, pz, f["center"], f["radius"], f["height"], f.get("falloff", 10.0)),
    "basin": lambda px, pz, f: _basin(px, pz, f["center"], f["radius"], f["depth"], f.get("falloff", 10.0)),
    "plateau": lambda px, pz, f: _plateau(px, pz, f["center"], f["half_extents"], f["height"], f.get("falloff", 10.0)),
    "ridge": lambda px, pz, f: _ridge(px, pz, f["start"], f["end"], f["width"], f["height"], f.get("falloff", 10.0)),
    "ravine": lambda px, pz, f: _ravine(px, pz, f["start"], f["end"], f["width"], f["depth"], f.get("falloff", 10.0)),
    "escarpment": lambda px, pz, f: _escarpment(px, pz, f["start"], f["end"], f["height"], f.get("falloff", 6.0), f.get("side", "left")),
    "cliff": lambda px, pz, f: _cliff(px, pz, f["start"], f["end"], f["height"], f.get("side", "left"), f.get("falloff", 0.01)),
    "river": _river,
    "terrace": _terrace,
    "crater": _crater,
    "berm": _berm,
    "road_cut": _road_cut,
    # User-facing aliases for the dramatic feature types (2026-08-26 PR1).
    # The heightmap shape is identical to the existing primitive; the
    # aliases exist so the GDScript terrain_builder can use a more
    # evocative name (canyon is the "long sheer-walled depression" the
    # canyon_ford work calls for, lake is the "round water feature with
    # a shoreline" the user asks for in the playtest feedback).
    "canyon": lambda px, pz, f: _ravine(px, pz, f["start"], f["end"], f["width"], f["depth"], f.get("wall_falloff", f.get("falloff", 10.0))),
    "lake": lambda px, pz, f: _basin(px, pz, f["center"], f["radius"], f["depth"], f.get("shoreline_falloff", f.get("falloff", 10.0))),
}


# ---------------------------------------------------------------------------
# Erosion & Post-Pass Simulations (Deterministic)
# ---------------------------------------------------------------------------

def simulate_thermal_erosion(height, iterations=8, talus_angle=0.45, rate=0.25, cell_size=1.0):
    """Vectorized talus relaxation thermal erosion."""
    h = height.copy().astype(np.float64)
    talus_threshold = talus_angle * cell_size
    diag_talus = talus_threshold * math.sqrt(2.0)

    for _ in range(iterations):
        diff_up = h[1:-1, 1:-1] - h[:-2, 1:-1]
        diff_dn = h[1:-1, 1:-1] - h[2:, 1:-1]
        diff_lf = h[1:-1, 1:-1] - h[1:-1, :-2]
        diff_rt = h[1:-1, 1:-1] - h[1:-1, 2:]

        excess_up = np.maximum(diff_up - talus_threshold, 0.0)
        excess_dn = np.maximum(diff_dn - talus_threshold, 0.0)
        excess_lf = np.maximum(diff_lf - talus_threshold, 0.0)
        excess_rt = np.maximum(diff_rt - talus_threshold, 0.0)

        total_excess = excess_up + excess_dn + excess_lf + excess_rt
        transfer = total_excess * (rate * 0.25)

        h[1:-1, 1:-1] -= transfer
        h[:-2, 1:-1] += excess_up * (rate * 0.25)
        h[2:, 1:-1] += excess_dn * (rate * 0.25)
        h[1:-1, :-2] += excess_lf * (rate * 0.25)
        h[1:-1, 2:] += excess_rt * (rate * 0.25)

    return h.astype(np.float32)


def simulate_hydraulic_erosion(height, iterations=12, rain=0.015, solubility=0.08, evaporation=0.15, cell_size=1.0):
    """Vectorized hydraulic stream-power erosion and sediment transport."""
    h = height.copy().astype(np.float64)
    water = np.zeros_like(h)
    sediment = np.zeros_like(h)

    for _ in range(iterations):
        water += rain
        # Central difference gradients
        dh_dx = (h[1:-1, 2:] - h[1:-1, :-2]) / (2.0 * cell_size)
        dh_dz = (h[2:, 1:-1] - h[:-2, 1:-1]) / (2.0 * cell_size)
        slope = np.sqrt(dh_dx ** 2 + dh_dz ** 2)

        # Capacity is proportional to slope and water volume
        w_inner = water[1:-1, 1:-1]
        capacity = slope * w_inner * 0.5

        # Dissolve or deposit
        sed_inner = sediment[1:-1, 1:-1]
        diff = capacity - sed_inner
        carve = np.where(diff > 0, diff * solubility, diff * 0.2)
        h[1:-1, 1:-1] -= carve
        sediment[1:-1, 1:-1] += carve

        # Evaporate
        water *= (1.0 - evaporation)
        sediment *= (1.0 - evaporation * 0.5)

    return h.astype(np.float32)


def apply_terrain_post_pass(height, px, pz, post_pass_config, seed=0):
    """Applies deterministic fBM domain warping, noise relief, and erosion."""
    h = height.copy()
    cell_size = abs(px[0, 1] - px[0, 0]) if px.shape[1] > 1 else 1.0

    # 1. fBM height noise relief
    if post_pass_config.get("noise", False):
        noise_cfg = post_pass_config.get("noise") if isinstance(post_pass_config.get("noise"), dict) else {}
        freq = float(noise_cfg.get("frequency", 0.04))
        amp = float(noise_cfg.get("amplitude", 1.2))
        octaves = int(noise_cfg.get("octaves", 3))
        noise_val = _fbm_2d(px, pz, octaves=octaves, frequency=freq, amplitude=amp, seed=seed + 101)
        h += noise_val.astype(np.float32)

    # 2. Thermal talus erosion
    if post_pass_config.get("thermal_erosion", False) or post_pass_config.get("erosion", False):
        erosion_cfg = post_pass_config.get("erosion") if isinstance(post_pass_config.get("erosion"), dict) else {}
        iters = int(erosion_cfg.get("thermal_iterations", 8))
        talus = float(erosion_cfg.get("talus_angle", 0.45))
        h = simulate_thermal_erosion(h, iterations=iters, talus_angle=talus, cell_size=cell_size)

    # 3. Hydraulic erosion
    if post_pass_config.get("hydraulic_erosion", False):
        erosion_cfg = post_pass_config.get("erosion") if isinstance(post_pass_config.get("erosion"), dict) else {}
        h_iters = int(erosion_cfg.get("hydraulic_iterations", 10))
        h = simulate_hydraulic_erosion(h, iterations=h_iters, cell_size=cell_size)

    return h


# ---------------------------------------------------------------------------
# Heightfield Builder
# ---------------------------------------------------------------------------

def build_heightfield(half_extents, features, resolution=None, pixels_per_unit=DEFAULT_PIXELS_PER_UNIT, post_pass=None, seed=0):
    """Returns (heightfield: np.ndarray[H,W] float32 world-unit heights, dim: int)."""
    dim = resolution or (int(round(half_extents * 2 * pixels_per_unit)) + 1)
    coords = np.linspace(-half_extents, half_extents, dim, dtype=np.float64)
    px, pz = np.meshgrid(coords, coords)  # px varies along columns (x), pz along rows (z)

    # If domain warp is enabled in post_pass, evaluate features at warped coords
    sample_px, sample_pz = px, pz
    if post_pass and post_pass.get("domain_warp", False):
        warp_cfg = post_pass.get("domain_warp") if isinstance(post_pass.get("domain_warp"), dict) else {}
        w_strength = float(warp_cfg.get("strength", 4.0))
        w_freq = float(warp_cfg.get("frequency", 0.02))
        sample_px, sample_pz = _domain_warp_2d(px, pz, strength=w_strength, frequency=w_freq, seed=seed + 55)

    height = np.zeros_like(px, dtype=np.float32)
    for f in features:
        builder = FEATURE_BUILDERS.get(f.get("type"))
        if builder is None:
            raise ValueError(f"Unknown terrain feature type: {f.get('type')!r}")
        # Pass the feature dict as-is. The cliff lambda (and any other
        # builder that wants to read `falloff` from the dict) does so
        # with its own default. We don't transform the dict here -
        # the build_heightfield signature is pure data in, height out.
        height += builder(sample_px, sample_pz, f).astype(np.float32)

    if post_pass:
        height = apply_terrain_post_pass(height, px, pz, post_pass, seed=seed)

    return height.astype(np.float32), dim


def encode_heightmap(height, height_scale):
    """Returns an (H, W, 4) uint8 RGBA array - R=high byte, G=low byte of 16-bit height."""
    normalized = np.clip(height / height_scale, -1.0, 1.0)
    pixel16 = np.round((normalized + 1.0) * (HEIGHT_PIXEL_MAX / 2.0)).astype(np.uint32)
    rgba = np.zeros(pixel16.shape + (4,), dtype=np.uint8)
    rgba[..., 0] = (pixel16 >> 8) & 0xFF  # R = high byte
    rgba[..., 1] = pixel16 & 0xFF          # G = low byte
    rgba[..., 2] = 0
    rgba[..., 3] = 255
    return rgba


# ---------------------------------------------------------------------------
# Auxiliary Raster Generators: Surface, Splat, Wetness, Macro, Curvature
# ---------------------------------------------------------------------------

def build_surfacemap(half_extents, surface_zones, dim):
    coords = np.linspace(-half_extents, half_extents, dim, dtype=np.float64)
    px, pz = np.meshgrid(coords, coords)
    indices = np.zeros_like(px, dtype=np.uint8)
    for z in reversed(surface_zones):
        cx, cz = z["center"][0], z["center"][2]
        hx, hz = z["half_extents"][0], z["half_extents"][1]
        mask = (np.abs(px - cx) <= hx) & (np.abs(pz - cz) <= hz)
        try:
            idx = SURFACE_PALETTE.index(z.get("surface_type", ""))
        except ValueError:
            raise ValueError(f"Unknown surface_type {z.get('surface_type')!r}, not in SURFACE_PALETTE")
        indices[mask] = idx
    return indices


def build_wetnessmap(half_extents, map_def, dim, max_dist=18.0):
    """Outputs an (H, W) uint8 grayscale distance-transform from all water features."""
    coords = np.linspace(-half_extents, half_extents, dim, dtype=np.float64)
    px, pz = np.meshgrid(coords, coords)
    min_dist = np.full_like(px, 1e9)

    # 1. Water Areas (rectangles)
    for w in map_def.get("water_areas", []):
        cx, cz = w["center"][0], w["center"][2] if len(w["center"]) > 2 else w["center"][1]
        hx, hz = w["half_extents"][0], w["half_extents"][1]
        dx = np.maximum(np.abs(px - cx) - hx, 0.0)
        dz = np.maximum(np.abs(pz - cz) - hz, 0.0)
        d = np.sqrt(dx * dx + dz * dz)
        min_dist = np.minimum(min_dist, d)

    # 2. Shallow Water Areas
    for w in map_def.get("shallow_water_areas", []):
        cx, cz = w["center"][0], w["center"][2] if len(w["center"]) > 2 else w["center"][1]
        hx, hz = w["half_extents"][0], w["half_extents"][1]
        dx = np.maximum(np.abs(px - cx) - hx, 0.0)
        dz = np.maximum(np.abs(pz - cz) - hz, 0.0)
        d = np.sqrt(dx * dx + dz * dz)
        min_dist = np.minimum(min_dist, d)

    # 3. Water Blobs
    for b in map_def.get("water_blobs", []):
        cx, cz = b["center"][0], b["center"][2] if len(b["center"]) > 2 else b["center"][1]
        radius = float(b.get("radius", 20.0))
        d_center = np.sqrt((px - cx) ** 2 + (pz - cz) ** 2)
        d = np.maximum(d_center - radius, 0.0)
        min_dist = np.minimum(min_dist, d)

    # 4. River Features from terrain
    terrain = map_def.get("terrain", {})
    for f in terrain.get("features", []):
        if f.get("type") == "river":
            width = float(f.get("width", 12.0))
            half_w = width / 2.0
            start = f.get("start", [-100.0, 0.0])
            end = f.get("end", [100.0, 0.0])
            d_line, _ = _point_to_segment_dist_and_t(px, pz, start[0], start[1], end[0], end[1])
            d = np.maximum(d_line - half_w, 0.0)
            min_dist = np.minimum(min_dist, d)

    # Convert distance to wetness: 1.0 (255) at water/shore, smoothly decaying to 0
    t = _smoothstep(np.clip(1.0 - (min_dist / max(max_dist, 1e-6)), 0.0, 1.0))
    wetness = (t * 255.0).astype(np.uint8)
    return wetness


def build_macromap(half_extents, dim, seed=0):
    """Outputs an (H, W, 3) uint8 RGB macro tint variation map centered at neutral 128."""
    coords = np.linspace(-half_extents, half_extents, dim, dtype=np.float64)
    px, pz = np.meshgrid(coords, coords)

    # Very low frequency multi-scale noise for subtle large-scale shifts
    n_warm = _fbm_2d(px, pz, octaves=3, frequency=0.006, amplitude=0.18, seed=seed + 201)
    n_cool = _fbm_2d(px + 45.0, pz - 80.0, octaves=3, frequency=0.008, amplitude=0.18, seed=seed + 307)
    n_veg  = _fbm_2d(px - 90.0, pz + 60.0, octaves=3, frequency=0.007, amplitude=0.15, seed=seed + 419)

    r = np.clip(128.0 + (n_warm - 0.5 * 0.18) * 120.0, 0, 255).astype(np.uint8)
    g = np.clip(128.0 + (n_veg  - 0.5 * 0.15) * 100.0, 0, 255).astype(np.uint8)
    b = np.clip(128.0 + (n_cool - 0.5 * 0.18) * 120.0, 0, 255).astype(np.uint8)

    macro = np.stack([r, g, b], axis=-1)
    return macro


def build_curvaturemap(height, cell_size=1.0):
    """Outputs an (H, W) uint8 grayscale curvature ambient occlusion map from the heightfield."""
    h = height.astype(np.float64)
    laplacian = np.zeros_like(h)

    # 5-point discrete 2D Laplacian operator
    h_up = h[:-2, 1:-1]
    h_dn = h[2:, 1:-1]
    h_lf = h[1:-1, :-2]
    h_rt = h[1:-1, 2:]
    h_cc = h[1:-1, 1:-1]

    lap = (h_up + h_dn + h_lf + h_rt - 4.0 * h_cc) / (cell_size * cell_size)
    laplacian[1:-1, 1:-1] = lap

    # Convex (peaks/ridges, lap < 0) -> brighter > 128
    # Concave (valleys/hollows, lap > 0) -> darker < 128
    # Flat -> 128
    gain = 45.0
    curv = np.clip(128.0 - laplacian * gain, 0, 255).astype(np.uint8)
    return curv


def build_splatmap(half_extents, surface_zones, height, wetness, dim, cell_size=1.0):
    """Outputs an (H, W, 4) uint8 RGBA splat weight map.
    R: Grass/Base, G: Rock/Steep, B: Dirt/Highland/Snow, A: Sand/Wetland.
    """
    coords = np.linspace(-half_extents, half_extents, dim, dtype=np.float64)
    px, pz = np.meshgrid(coords, coords)

    # 1. Slope calculation
    dh_dx = np.zeros_like(height)
    dh_dz = np.zeros_like(height)
    dh_dx[:, 1:-1] = (height[:, 2:] - height[:, :-2]) / (2.0 * cell_size)
    dh_dz[1:-1, :] = (height[2:, :] - height[:-2, :]) / (2.0 * cell_size)
    slope = np.sqrt(dh_dx ** 2 + dh_dz ** 2)

    # Slope-driven rock weight
    w_rock = _smoothstep(np.clip((slope - 0.45) / 0.25, 0.0, 1.0))

    # Wetness-driven shoreline / sand / wetland weight
    w_wet = (wetness.astype(np.float64) / 255.0) * (1.0 - w_rock)

    # Surface zones contribution
    w_dirt = np.zeros_like(w_rock)
    w_sand = w_wet.copy()

    for z in reversed(surface_zones):
        cx, cz = z["center"][0], z["center"][2]
        hx, hz = z["half_extents"][0], z["half_extents"][1]
        mask = (np.abs(px - cx) <= hx) & (np.abs(pz - cz) <= hz)
        stype = z.get("surface_type", "")
        if stype in ["rocky", "gravel"]:
            w_rock[mask] = np.maximum(w_rock[mask], 0.85)
        elif stype in ["snow_mud", "forest"]:
            w_dirt[mask] = 0.85
        elif stype in ["sand", "marsh"]:
            w_sand[mask] = np.maximum(w_sand[mask], 0.9)

    w_grass = np.maximum(0.0, 1.0 - w_rock - w_dirt - w_sand)

    # Normalize weights to sum to 255
    total = w_grass + w_rock + w_dirt + w_sand + 1e-6
    r = np.clip(np.round((w_grass / total) * 255.0), 0, 255).astype(np.uint8)
    g = np.clip(np.round((w_rock  / total) * 255.0), 0, 255).astype(np.uint8)
    b = np.clip(np.round((w_dirt  / total) * 255.0), 0, 255).astype(np.uint8)
    a = np.clip(np.round((w_sand  / total) * 255.0), 0, 255).astype(np.uint8)

    splat = np.stack([r, g, b, a], axis=-1)
    return splat


# ---------------------------------------------------------------------------
# Main Generation Pipeline
# ---------------------------------------------------------------------------

def generate(map_json_path, resolution=None, pixels_per_unit=None):
    with open(map_json_path, "r") as f:
        map_def = json.load(f)

    terrain = map_def.get("terrain")
    if not terrain:
        print(f"'{map_json_path}' has no terrain block - nothing to generate.")
        return

    half_extents = float(map_def["map_half_extents"])
    map_id = os.path.splitext(os.path.basename(map_json_path))[0]
    out_dir = os.path.dirname(map_json_path)

    ppu = float(pixels_per_unit or terrain.get("pixels_per_unit", DEFAULT_PIXELS_PER_UNIT))
    res = resolution or terrain.get("resolution")
    dim = res or (int(round(half_extents * 2 * ppu)) + 1)
    cell_size = (2.0 * half_extents) / max(dim - 1, 1)

    # Deterministic map seed from map_id hash
    seed = zlib.crc32(map_id.encode("utf-8")) & 0xFFFFFFFF

    post_pass = terrain.get("post_pass")
    height = None

    # 1. Heightmap
    if terrain.get("features") is not None:
        height_scale = float(terrain.get("height_scale", 20.0))
        height, dim = build_heightfield(
            half_extents,
            terrain["features"],
            resolution=dim,
            pixels_per_unit=ppu,
            post_pass=post_pass,
            seed=seed,
        )
        pixels = encode_heightmap(height, height_scale)
        height_path = os.path.join(out_dir, f"{map_id}_height.png")
        Image.fromarray(pixels, mode="RGBA").save(height_path)
        print(f"Wrote {height_path} ({dim}x{dim})")
    else:
        height = np.zeros((dim, dim), dtype=np.float32)

    # 2. Surfacemap
    if terrain.get("surfacemap"):
        surface_zones = map_def.get("surface_zones", [])
        indices = build_surfacemap(half_extents, surface_zones, dim)
        surf_img = Image.fromarray(indices, mode="P")
        palette = []
        for i in range(256):
            palette.extend([i, i, i])
        surf_img.putpalette(palette)
        surface_path = os.path.join(out_dir, f"{map_id}_surface.png")
        surf_img.save(surface_path)
        print(f"Wrote {surface_path} ({dim}x{dim})")

    # 3. Wetness Map
    wetness = build_wetnessmap(half_extents, map_def, dim)
    wetness_path = os.path.join(out_dir, f"{map_id}_wetness.png")
    Image.fromarray(wetness, mode="L").save(wetness_path)
    print(f"Wrote {wetness_path} ({dim}x{dim})")

    # 4. Macro Tint Map
    macro = build_macromap(half_extents, dim, seed=seed)
    macro_path = os.path.join(out_dir, f"{map_id}_macro.png")
    Image.fromarray(macro, mode="RGB").save(macro_path)
    print(f"Wrote {macro_path} ({dim}x{dim})")

    # 5. Curvature AO Map
    curvature = build_curvaturemap(height, cell_size=cell_size)
    curvature_path = os.path.join(out_dir, f"{map_id}_curvature.png")
    Image.fromarray(curvature, mode="L").save(curvature_path)
    print(f"Wrote {curvature_path} ({dim}x{dim})")

    # 6. Splat Weight Map
    surface_zones = map_def.get("surface_zones", [])
    splat = build_splatmap(half_extents, surface_zones, height, wetness, dim, cell_size=cell_size)
    splat_path = os.path.join(out_dir, f"{map_id}_splat.png")
    Image.fromarray(splat, mode="RGBA").save(splat_path)
    print(f"Wrote {splat_path} ({dim}x{dim})")


def generate_all(maps_dir, resolution=None, pixels_per_unit=None):
    pattern = os.path.join(maps_dir, "*.json")
    map_files = sorted(glob.glob(pattern))
    print(f"Found {len(map_files)} map definitions in '{maps_dir}'")
    for mf in map_files:
        generate(mf, resolution=resolution, pixels_per_unit=pixels_per_unit)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description="Build-A-Bomber Terrain Generator")
    parser.add_argument("map_json_path", nargs="?", default=None, help="Path to map JSON file")
    parser.add_argument("--all", action="store_true", help="Regenerate all maps in data/maps/*.json")
    parser.add_argument("--resolution", type=int, default=None, help="Explicit dimension override")
    parser.add_argument("--pixels-per-unit", type=float, default=None, help="Pixels per world unit")
    args = parser.parse_args()

    if args.all:
        default_maps_dir = os.path.normpath(os.path.join(os.path.dirname(__file__), "..", "..", "data", "maps"))
        generate_all(default_maps_dir, resolution=args.resolution, pixels_per_unit=args.pixels_per_unit)
    elif args.map_json_path:
        generate(args.map_json_path, resolution=args.resolution, pixels_per_unit=args.pixels_per_unit)
    else:
        parser.print_help()
        sys.exit(1)
