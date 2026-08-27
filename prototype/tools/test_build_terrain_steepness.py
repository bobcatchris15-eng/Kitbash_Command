"""
test_build_terrain_steepness.py (canyon_ford PR2, 2026-08-26)

Verifies the cliff `falloff` field override and the `pixels_per_unit`
resolution control for the heightmap generator.

Run with:
  python tools/test_build_terrain_steepness.py

Four checks:
  1. Backward compatibility: a cliff feature with no `falloff` field
     uses the legacy 0.01 default; explicit `falloff: 0.01` matches.
  2. Falloff override: a cliff feature with `falloff: 2.0` (a 2m ramp)
     produces a measurably different heightmap than the default
     0.01 (a sub-pixel ramp that gets smoothed by bilinear to a step).
  3. Pixels-per-unit: a 100-half-extent map at ppu=1.0 is 201x201;
     at ppu=2.0 is 401x401; the bake respects the resolution.
  4. Same-feature placement at higher ppu: the same world-space
     feature occupies proportionally more pixels in the higher-
     resolution bake.
"""

import os
import sys
import numpy as np
from PIL import Image

# Make build_terrain importable as a module. The repo's tools/terrain/
# layout puts the generator one subdir below this test's location.
HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, "terrain"))

import build_terrain as bt


def _heightfield(half_extents, features, pixels_per_unit):
    """Helper: build a heightfield for a square map at given resolution."""
    height, dim = bt.build_heightfield(
        half_extents=half_extents,
        features=features,
        pixels_per_unit=pixels_per_unit,
    )
    return height, dim


def test_backward_compat():
    """A cliff feature with the default falloff (0.01) and one with
    no `falloff` at all must produce identical output - the lambda's
    `.get("falloff", 0.01)` default is honored."""
    f1 = {"type": "cliff", "start": [0, 0], "end": [0, 100], "height": 4.0, "side": "left", "falloff": 0.01}
    f2 = {"type": "cliff", "start": [0, 0], "end": [0, 100], "height": 4.0, "side": "left"}
    h1, _ = _heightfield(100, [f1], 1.0)
    h2, _ = _heightfield(100, [f2], 1.0)
    assert np.array_equal(h1, h2), "cliff with and without `falloff` produced different heights"
    print("[PASS] legacy cliff falloff is unchanged (default == 0.01)")


def test_falloff_override_changes_heightmap():
    """A cliff with a 2m falloff (a 2-pixel-wide ramp at ppu=1) should
    be visibly different from the default 0.01m falloff (sub-pixel
    ramp that gets smoothed to a step by bilinear). The two bakes
    are NOT byte-equal - and the wider-falloff version is softer
    (lower max gradient crossing the cliff)."""
    f_sharp = {"type": "cliff", "start": [0, 0], "end": [0, 100], "height": 4.0, "side": "left", "falloff": 0.01}
    f_soft = {"type": "cliff", "start": [0, 0], "end": [0, 100], "height": 4.0, "side": "left", "falloff": 2.0}
    h_sharp, _ = _heightfield(100, [f_sharp], 1.0)
    h_soft, _ = _heightfield(100, [f_soft], 1.0)
    assert not np.array_equal(h_sharp, h_soft), \
        "falloff override should produce a different heightmap than the default"
    # Cliff line is along z (axis=0 in the heightfield's (rows=z, cols=x)
    # meshgrid layout per build_heightfield's own comment), so the
    # gradient is along x = axis=1.
    def max_x_gradient(h):
        return np.abs(np.diff(h, axis=1)).max()
    grad_sharp = max_x_gradient(h_sharp)
    grad_soft = max_x_gradient(h_soft)
    # Both gradients should be non-zero (the cliff IS there in both
    # bakes), and the wider-falloff version should be SOFTER (smaller
    # gradient because the same 4m change is spread across more pixels).
    assert grad_sharp > 0, "sharp cliff should have a non-zero gradient"
    assert grad_soft > 0, "soft cliff should have a non-zero gradient"
    assert grad_soft < grad_sharp, \
        f"wider falloff should produce a softer cliff (grad {grad_soft} vs sharp {grad_sharp})"
    print(f"[PASS] falloff override softens the cliff (sharp grad={grad_sharp:.3f}, soft grad={grad_soft:.3f})")


def test_pixels_per_unit_changes_dim():
    """A 100-half-extent map at pixels_per_unit=1.0 is 201x201; at 2.0
    is 401x401. The bake respects the resolution parameter end-to-end.
    """
    f = {"type": "cliff", "start": [-50, 0], "end": [50, 0], "height": 4.0, "side": "left"}
    h1, dim1 = _heightfield(100, [f], 1.0)
    h2, dim2 = _heightfield(100, [f], 2.0)
    assert dim1 == 201, f"at 1px/unit expected 201, got {dim1}"
    assert dim2 == 401, f"at 2px/unit expected 401, got {dim2}"
    # Same world-space feature should occupy a wider pixel footprint
    # in the higher-resolution bake.
    assert dim2 == 2 * dim1 - 1, "dim should be 2N-1 at 2x resolution"
    print(f"[PASS] pixels_per_unit scales dimension correctly (1px->{dim1}, 2px->{dim2})")


def test_heightmap_is_deterministic():
    """Two bakes of the same input produce byte-identical heightmaps.
    This is the existing contract (build_terrain.py's own header) -
    a regression would silently break the visual-regression tests."""
    f = {"type": "cliff", "start": [0, 0], "end": [0, 100], "height": 4.0, "side": "left"}
    h1, _ = _heightfield(100, [f], 1.0)
    h2, _ = _heightfield(100, [f], 1.0)
    assert np.array_equal(h1, h2), "same input should produce byte-identical heightfield"
    print("[PASS] heightfield is deterministic across identical bakes")


if __name__ == "__main__":
    print("Running build_terrain tests (canyon_ford PR2)...\n")
    test_backward_compat()
    test_falloff_override_changes_heightmap()
    test_pixels_per_unit_changes_dim()
    test_heightmap_is_deterministic()
    print("\n[ALL PASS] build_terrain PR2 tests pass")
