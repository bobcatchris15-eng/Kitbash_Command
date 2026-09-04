# Render settings — why the environment values are what they are

**Why this file exists.** These notes were written as `#` comments inside
`Battle.tscn`, `MainLab.tscn` and `ModularHullBuilder.tscn`. **Godot's text scene
format does not support comments.** A `#` line inside a `[node]` block is a
hard parse error — `_parse_node_tag` rejects it, the whole `.tscn` fails to
load, and every consumer of it dies with it. In `Battle.tscn` that took out the
Proving Ground *and* Skirmish (both route to that scene, see
`main_menu.gd:128`) and cascaded into every headless test suite, because
`tests/suite_base.gd:216` preloads `Battle.tscn`.

Comments inside `[sub_resource]` blocks happen to survive the parser today.
Do not rely on that — it is incidental tolerance in a different code path, not
a supported feature. **Keep `.tscn` files free of comments entirely** and put
the reasoning here.

---

## History

The pipeline documented below was authored in `b2340f4` (AgX tonemapping,
SDFGI/SSIL, physical light units, far-only DOF). It was reverted in
`df5270b` (a "Sync working tree" commit that re-introduced ACES tonemapping
and added volumetric fog as a GI substitute) and re-restored in the
2026-08-15 perf investigation. The reversion was never measured: the
volumetric fog reprojection at 2.25 Hz on a 2660×1080 viewport with 50+
structures in depth produced 800–1000 ms periodic hitches every 2 seconds
(cadence matched the AI commander's 2 s decision interval and the fog's
temporal reprojection window lining up). Do **not** revert this pipeline
again without re-measuring; the file lives here so the next time someone
wants to swap the tonemapper, the reasoning is one read away.

---

## Battle.tscn

### Tonemapping — AgX

AgX preserves hue under intense light without the cyan/yellow shifts ACES
produces, which is critical for bright saturated unit colours. Its slightly
desaturated output is compensated by the post-process saturation boost below.

### Ambient light — RA2-style flat overcast

Ambient comes from a neutral sky-grey **flat source**, not from the sky itself.
Sky-sourced ambient would introduce directional colour variation that the
bright flat brief does not want. Warm-neutral grey at moderate contribution, so
unlit unit faces still read their colour rather than going dark.

### SDFGI

Macro-bounced GI from the entire static scene. Terrain normals only resolve
with GI that reacts to them — without this the ground reads as flat.

### SSIL

Micro-bounces in crevices SDFGI's voxels cannot resolve. SDFGI handles the
macro scale; SSIL fills in what SDFGI misses at normal zoom.

### Adjustments — saturation and contrast

A saturation + contrast lift compensating for AgX's desaturation at peak
brightness, keeping the RA2 bright-and-smooth feel. Applied after tonemapping.

### Depth of field — tilt-shift band

Miniature-scale lens feel. **Far blur only:** near blur on an RTS camera
creates a double-blur artifact (near plane + camera pan) that reads as a lens
scratch rather than as a depth effect. Tuned conservative to avoid the 3 FPS
regression `rts_camera.gd`'s original DOF caused.

### Volumetric fog — OFF in Battle, by design

`volumetric_fog_enabled = false`. Volumetric fog was tried in `df5270b` as a
SDFGI substitute; it produced the periodic hitches described in the History
section and is the single most expensive feature in the file. It is **on** in
`MainLab.tscn` and `ModularHullBuilder.tscn` because those scenes are close-up with
a single subject, where the depth contribution is one mesh and the cost is
absorbed by the static-camera frame budget.

### Sun — physical light units

Calibrated for **bright overcast, not harsh clear sun**, matching
`CORE_DESIGN_LANGUAGE.md` §3.2: "high ambient, low directional, soft long
shadows, bright neutral grey sky."

`light_color` and `light_angular_distance` describe the sun disc in the sky;
the overcast sky itself is `ambient_color`. The wide angular distance gives a
softer disc and a less harsh directional shadow, paired with `shadow_blur` for
the soft overcast shadow feel.

### MSAA — 2x (project default), 4x is OFF in Battle

`project.godot` defaults to `msaa_3d = 2` (4x). The Battle scene's
`Camera3D.attributes` does NOT override this, so Battle inherits the project
default. **Do not raise it to 4x for Battle**: 4× MSAA at 2660×1080 was
measured at ~31% of frame time on an empty map (per `perf_hud.gd`'s
header). If a sharper edge read is needed, prefer TAA over MSAA in a
follow-up pipeline change.

---

## MainLab.tscn and ModularHullBuilder.tscn

Same AgX tonemapper as the battle scene, for visual coherence across modes.

**No SDFGI or SSIL here.** Both are close-up single-object views with no static
scene to bounce light from, so neither earns its cost. `designer_camera.gd`
handles depth of field in these scenes rather than the environment.

The same saturation + contrast lift compensates for AgX's peak desaturation.

Volumetric fog **is** on in these two scenes, because the camera is close
to the subject and the depth contribution is bounded; see the Battle section
for the reasoning that excludes it from the battle scene.
