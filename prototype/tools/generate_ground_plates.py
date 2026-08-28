"""Wide seamless ground plates for the terrain v2 shader.

WHY THIS EXISTS
---------------
Playtest: "the actual texture image being used for the ground needs work too.
It's tiled too densely, so we probably need a physically larger resolution
texture for it with more variation across its totality."

Measured, that was exactly right:

    grassland_albedo.png     256 x 256
    shader tile size         6.0 m
    map span                 1920 m   ->  320 repeats across the map

At 320 repeats the eye reads the LATTICE, not the material - and a 256 px
plate has no room for variation larger than about two metres, so every one of
those 320 tiles is identical at every scale. Raising the tile size alone is not
enough either: stretch a 256 px plate over 30 m and it is a blurry smear.

So these plates are built for a large tile:

  * 2048 px, so a 28 m tile still lands ~73 px per metre.
  * Variation at FOUR scales, the largest being a low-period mask that puts
    metre-scale patches of a second and third tone across the plate. That is
    what "variation across its totality" means in practice - without it a
    plate is uniform noise and reads as flat felt however high its resolution.
  * Seamless by construction: every noise octave is periodic, and the normal
    map's gradient is taken with wraparound, so tiles join without a seam.

Named `ground_*` rather than `<surface>_v<n>`, deliberately. terrain_builder's
v1 variant discovery probes for the `_v1.._v8` suffix on a surface name, so a
file called `grassland_v2_albedo.png` would be picked up by every v1 map and
silently restyle terrain that is supposed to be frozen. `ground_grass` is
outside that pattern and is referenced only by V2_LAYERS.

Deterministic: every octave is seeded from the plate name, so re-running
produces byte-identical output rather than a multi-megabyte binary diff.

    python tools/generate_ground_plates.py [--size 2048]
"""
import argparse
import os
import numpy as np
from PIL import Image

PROJECT_ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
TEXTURES_DIR = os.path.join(PROJECT_ROOT, "assets", "textures", "terrain")
DEFAULT_SIZE = 2048


def periodic_noise(size, period, seed):
    """Seamless value noise on a `period` x `period` lattice, quintic-smoothed."""
    rng = np.random.default_rng(seed)
    lattice = rng.random((period, period))
    coords = np.linspace(0, period, size, endpoint=False)
    gx, gy = np.meshgrid(coords, coords)
    x0 = np.floor(gx).astype(int) % period
    y0 = np.floor(gy).astype(int) % period
    x1 = (x0 + 1) % period
    y1 = (y0 + 1) % period
    fx = gx - np.floor(gx)
    fy = gy - np.floor(gy)
    ux = fx * fx * fx * (fx * (fx * 6.0 - 15.0) + 10.0)
    uy = fy * fy * fy * (fy * (fy * 6.0 - 15.0) + 10.0)
    top = lattice[y0, x0] * (1.0 - ux) + lattice[y0, x1] * ux
    bot = lattice[y1, x0] * (1.0 - ux) + lattice[y1, x1] * ux
    return top * (1.0 - uy) + bot * uy


def fbm(size, base_period, octaves, seed, gain=0.5, lacunarity=2):
    """Sum of periodic octaves. Stays seamless because every octave is periodic."""
    out = np.zeros((size, size), dtype=np.float64)
    amp = 1.0
    total = 0.0
    period = base_period
    for o in range(octaves):
        out += amp * periodic_noise(size, period, seed + o * 977)
        total += amp
        amp *= gain
        period *= lacunarity
    return out / max(total, 1e-6)


def srgb_to_linear(c):
    return np.where(c <= 0.04045, c / 12.92, ((c + 0.055) / 1.055) ** 2.4)


def linear_to_srgb(c):
    c = np.clip(c, 0.0, 1.0)
    return np.where(c <= 0.0031308, c * 12.92, 1.055 * c ** (1.0 / 2.4) - 0.055)


def retarget_albedo(albedo, target_linear):
    """Scale the plate so its MEAN LINEAR luminance equals target_linear.

    Authoring tone triples by eye produces sRGB values, but the renderer
    consumes them as linear reflectance - and the gap is brutal: the first
    pass' tones averaged 0.21 sRGB, which is 0.038 LINEAR, darker than
    asphalt (~0.05) and a third of the plate they replaced (0.127). No amount
    of exposure or sun energy rescues ground that reflects 4% of the light
    hitting it; it has to be fixed at the source.

    Doing it as a measured retarget rather than by hand-tuning the triples
    means the palette can be edited for HUE without anyone having to re-derive
    its brightness.
    """
    lin = srgb_to_linear(albedo)
    cur = float((lin @ [0.2126, 0.7152, 0.0722]).mean())
    if cur > 1e-6:
        lin = np.clip(lin * (target_linear / cur), 0.0, 1.0)
    return linear_to_srgb(lin)


def normalize(a):
    lo, hi = a.min(), a.max()
    return (a - lo) / max(hi - lo, 1e-6)


# Each plate: a palette of tones that the macro masks select between, plus how
# rough/bumpy it is. Three tones minimum - two reads as a duotone pattern
# rather than as ground.
PLATES = {
    "ground_grass": dict(
        target_linear=0.130,
        seed=1101,
        tones=[(0.165, 0.204, 0.114), (0.243, 0.271, 0.153),
               (0.125, 0.157, 0.094), (0.290, 0.290, 0.180)],
        tone_weights=[0.38, 0.30, 0.20, 0.12],
        grain=0.055, bump=0.55, rough=(0.86, 0.96),
    ),
    "ground_rock": dict(
        target_linear=0.155,
        seed=2202,
        tones=[(0.290, 0.278, 0.259), (0.196, 0.188, 0.180),
               (0.376, 0.361, 0.337), (0.157, 0.153, 0.149)],
        tone_weights=[0.34, 0.30, 0.22, 0.14],
        grain=0.075, bump=1.00, rough=(0.78, 0.94),
    ),
    "ground_dirt": dict(
        target_linear=0.115,
        seed=3303,
        tones=[(0.286, 0.224, 0.161), (0.216, 0.169, 0.122),
               (0.353, 0.286, 0.212), (0.176, 0.141, 0.106)],
        tone_weights=[0.36, 0.28, 0.22, 0.14],
        grain=0.050, bump=0.62, rough=(0.84, 0.95),
    ),
    "ground_sand": dict(
        target_linear=0.250,
        seed=4404,
        tones=[(0.478, 0.427, 0.314), (0.365, 0.325, 0.239),
               (0.573, 0.522, 0.396), (0.298, 0.267, 0.204)],
        tone_weights=[0.38, 0.28, 0.20, 0.14],
        grain=0.035, bump=0.34, rough=(0.72, 0.88),
    ),
    "grassland": dict(
        target_linear=0.220,
        seed=5505,
        tones=[(0.38, 0.52, 0.24), (0.48, 0.62, 0.30),
               (0.28, 0.42, 0.18), (0.54, 0.65, 0.36)],
        tone_weights=[0.36, 0.30, 0.20, 0.14],
        grain=0.045, bump=0.45, rough=(0.84, 0.95),
    ),
    "grassland_v1": dict(
        target_linear=0.220,
        seed=5511,
        tones=[(0.36, 0.50, 0.22), (0.46, 0.60, 0.28),
               (0.26, 0.40, 0.16), (0.52, 0.64, 0.34)],
        tone_weights=[0.38, 0.30, 0.20, 0.12],
        grain=0.045, bump=0.45, rough=(0.84, 0.95),
    ),
    "grassland_v2": dict(
        target_linear=0.250,
        seed=5522,
        tones=[(0.44, 0.58, 0.28), (0.54, 0.66, 0.34),
               (0.34, 0.48, 0.22), (0.58, 0.68, 0.40)],
        tone_weights=[0.35, 0.32, 0.20, 0.13],
        grain=0.040, bump=0.40, rough=(0.82, 0.94),
    ),
    "grassland_v3": dict(
        target_linear=0.205,
        seed=5533,
        tones=[(0.34, 0.46, 0.22), (0.44, 0.42, 0.26),
               (0.26, 0.38, 0.16), (0.40, 0.50, 0.24)],
        tone_weights=[0.36, 0.28, 0.22, 0.14],
        grain=0.050, bump=0.50, rough=(0.86, 0.96),
    ),
    "grassland_v4": dict(
        target_linear=0.235,
        seed=5544,
        tones=[(0.40, 0.54, 0.25), (0.50, 0.62, 0.32),
               (0.30, 0.44, 0.18), (0.54, 0.65, 0.38)],
        tone_weights=[0.38, 0.28, 0.20, 0.14],
        grain=0.042, bump=0.42, rough=(0.84, 0.95),
    ),
}


def build_plate(name, cfg, size):
    seed = cfg["seed"]
    # NO WHOLE-PLATE FEATURES. The first version of this put a period-2 octave
    # in, on the reasoning that "variation across its totality" meant variation
    # at plate scale. Tiled, that is the worst thing you can do: a distinctive
    # metre-wide pale patch becomes a LANDMARK, and the eye locks onto it
    # repeating every tile. It made the lattice more obvious, not less.
    #
    # A tiling plate wants the opposite - statistically uniform at large scale,
    # rich at small scale - and the large-scale variation belongs in the shader
    # where it is a function of WORLD position and therefore never repeats.
    # See terrain_ground_v2.gdshader's macro break-up.
    #
    # Periods here are chosen against a ~28 m tile at this resolution: period
    # 13 puts a tone clump at roughly 2 m, and the finest octave lands near
    # 5 cm, which is what makes the surface hold up when the camera comes down.
    sel = normalize(fbm(size, 13, 3, seed + 29))
    clump = normalize(fbm(size, 41, 3, seed + 53))
    grain = normalize(fbm(size, 157, 2, seed + 97))
    micro = normalize(fbm(size, 509, 1, seed + 131))
    tones = cfg["tones"]
    weights = np.cumsum(np.array(cfg["tone_weights"], dtype=np.float64))
    weights /= weights[-1]

    # Weighted blend of the palette. NORMALISE THE WEIGHTS, not the result:
    # dividing the summed colour by its own channel total (the first version
    # of this) forces every pixel to the same luminance and produces a plate
    # with a 0.026 spread - uniform felt, which is precisely the problem these
    # plates exist to fix. Normalising the weights keeps each tone's own value.
    acc = np.zeros((size, size, 3), dtype=np.float64)
    wsum = np.zeros((size, size), dtype=np.float64)
    prev = 0.0
    for i, tone in enumerate(tones):
        hi = weights[i]
        centre = 0.5 * (prev + hi)
        width = max(hi - prev, 1e-3)
        w = np.clip(1.0 - np.abs(sel - centre) / (width * 1.85), 0.0, 1.0)
        w = w * w * (3.0 - 2.0 * w)  # smoothstep the membership
        acc += w[..., None] * np.array(tone)[None, None, :]
        wsum += w
        prev = hi
    # Where no tone claims the texel (possible at the extreme ends of `sel`),
    # fall back to the nearest end tone rather than to black.
    empty = wsum < 1e-4
    if empty.any():
        ends = np.where(sel < 0.5, 0, len(tones) - 1)
        for i, tone in enumerate(tones):
            m = empty & (ends == i)
            if m.any():
                acc[m] = np.array(tone)
                wsum[m] = 1.0
    albedo = acc / np.clip(wsum, 1e-6, None)[..., None]

    # Surface texture at three descending scales. `micro` is what stops the
    # plate reading as blurry felt when the camera comes down close.
    albedo *= (1.0 + (clump - 0.5) * 0.20)[..., None]
    albedo *= (1.0 + (grain - 0.5) * 2.0 * cfg["grain"])[..., None]
    albedo *= (1.0 + (micro - 0.5) * 1.2 * cfg["grain"])[..., None]
    albedo = np.clip(albedo, 0.0, 1.0)
    albedo = retarget_albedo(albedo, cfg["target_linear"])

    # Height drives both the normal map and the packed height channel.
    height = normalize(clump * 0.34 + grain * 0.38 + micro * 0.28)

    # Periodic central differences: np.roll wraps, so the normal is seamless.
    strength = cfg["bump"] * (size / 512.0)
    dzdx = (np.roll(height, -1, axis=1) - np.roll(height, 1, axis=1)) * strength
    dzdy = (np.roll(height, -1, axis=0) - np.roll(height, 1, axis=0)) * strength
    nx, ny, nz = -dzdx, -dzdy, np.ones_like(height)
    inv = 1.0 / np.sqrt(nx * nx + ny * ny + nz * nz)
    normal = np.dstack([nx * inv * 0.5 + 0.5, ny * inv * 0.5 + 0.5, nz * inv * 0.5 + 0.5])

    r_lo, r_hi = cfg["rough"]
    rough = r_lo + (r_hi - r_lo) * (1.0 - grain)
    # G carries HEIGHT: terrain_ground_v2 does not read it today (it derives
    # height from albedo luminance, because the shipped plates pack a copy of
    # roughness here instead), but packing it correctly costs nothing and
    # leaves the door open.
    rough_img = np.dstack([rough, height, np.zeros_like(rough)])

    return albedo, normal, rough_img


def save(arr, path):
    Image.fromarray((np.clip(arr, 0, 1) * 255).astype(np.uint8)).save(path)
    print("  wrote %s (%dx%d)" % (os.path.basename(path), arr.shape[1], arr.shape[0]))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--size", type=int, default=DEFAULT_SIZE)
    ap.add_argument("--only", default="")
    args = ap.parse_args()

    os.makedirs(TEXTURES_DIR, exist_ok=True)
    wanted = [w.strip() for w in args.only.split(",") if w.strip()] or list(PLATES)
    for name in wanted:
        if name not in PLATES:
            raise SystemExit("unknown plate %r (known: %s)" % (name, ", ".join(PLATES)))
        print("%s @ %dpx" % (name, args.size))
        alb, nrm, rgh = build_plate(name, PLATES[name], args.size)
        save(alb, os.path.join(TEXTURES_DIR, "%s_albedo.png" % name))
        save(nrm, os.path.join(TEXTURES_DIR, "%s_normal.png" % name))
        save(rgh, os.path.join(TEXTURES_DIR, "%s_roughness.png" % name))
        lum = alb @ [0.2126, 0.7152, 0.0722]
        linlum = srgb_to_linear(alb) @ [0.2126, 0.7152, 0.0722]
        print("  sRGB mean=%.3f spread=%.3f | LINEAR albedo=%.4f (target %.3f)"
              % (lum.mean(), np.percentile(lum, 95) - np.percentile(lum, 5),
                 linlum.mean(), PLATES[name]["target_linear"]))


if __name__ == "__main__":
    main()
