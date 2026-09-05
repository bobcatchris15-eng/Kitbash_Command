# AGENTS.md

This file provides guidance to Codex (Codex.ai/code) when working with code in this repository.

## Project Overview

**Kitbash Command** — A prototype RTS where you design the units. Think Spore's vehicle creator meets Command & Conquer skirmishes. The prototype is a **Godot 4.7** project in `prototype/`.

## Running the Prototype

The repo bundles its own Godot engine executables **at the repo root** (not in
`prototype/`, despite the project living there). Run from the root and point
Godot at the project with `--path`:

```bash
./Godot_v4.7.1-stable_win64.exe --path prototype       # run the game
./Godot_v4.7.1-stable_win64.exe -e --path prototype    # open in the editor
```

`cd prototype && ./Godot_...` fails with "No such file or directory" — there is
no exe in that directory. Both binaries are gitignored, so a fresh worktree or
clone has neither.

The main menu (DEPLOY / DESIGN sections) links the full game loop:

**DEPLOY**
1. **SKIRMISH** — C&C-style battle (`MatchSetup.tscn` → `Battle.tscn`). Harvest metal/crystal with harvesters, build Refineries/Manufactories/Power Plants/labs, produce saved designs from the build bar, place custom defense blueprints, destroy the enemy HQ.
2. **OPERATIONS** — a campaign of 3–12 engagements with roster re-drafts between them (`OperationsSetup.tscn` → `Battle.tscn`).
3. **PROVING GROUND** — drive your latest scratch design against target dummies on `Battle.tscn` behind a chase camera (`test_range_launcher.gd`).

**DESIGN**

4. **DESIGN LAB** — Build blueprints on a 3D canvas. Drag parts from the bin onto a hull, drag gizmo handles to stretch barrels/calibers (stats update live), pick armor paint + thickness, toggle bilateral symmetry (M), rotate modules (R), and save to your Blueprint Library.
5. **BLUEPRINT LIBRARY** — browse, manage, preview saved designs; its "Test in Arena" button routes through the same Proving Ground launcher.
6. **HULL AUTHORING** — shape new hull forms from primitives (SDF / marching-cubes bake).

Plus a guided TUTORIAL card, and LIVERY (cosmetic paint authoring) / RECORDS / SYSTEM along the bottom.

## Checks

**There is no automated test suite.** The headless suite (`tests/`, `run_tests.{ps1,sh,gd}`, golden fixtures in `suite_base.gd`) was deleted on 2026-08-10 during the battle-system unification ("drop tests" commits; see PROGRESS.md). Do not reference it or try to revive it without asking. Verification today is:

1. **Parse check after edits.** Targeted first (edit the `FILES` list at the top to your touched scripts):

   ```bash
   ./Godot_v4.7.1-stable_win64_console.exe --headless --path prototype --script res://tools/compile_check_changed.gd --quit
   ```

   Full-tree check when something structural changed (autoloads, `class_name`s):

   ```bash
   ./Godot_v4.7.1-stable_win64_console.exe --headless --path prototype --script res://tools/compile_check_all.gd
   ```

   This one is **slow** (loads 200+ interdependent scripts with `CACHE_MODE_IGNORE`, observed 20+ min). Godot block-buffers stdout when piped, so expect no output until it exits — always pass `--quit`/`--path`.

2. **Headless probe scripts.** `tools/probe_*.gd` are one-off SceneTree scripts that boot a slice of the game (navmesh, economy, AI, placement…) and print findings — this is the de-facto regression harness now. Run pattern:

   ```bash
   ./Godot_v4.7.1-stable_win64_console.exe --headless --path prototype --script res://tools/probe_<area>.gd --quit
   ```

3. **Manual playtest** for anything visual/interactive.

Note: the `.godot` import cache is gitignored and goes stale whenever a new autoload or `class_name` script lands — if a headless script dies with a misleading `Identifier "X" not declared`, reimport first (`--headless --editor --import`).

## High-Level Architecture

### Core Systems

**Blueprint System** (`blueprint_manager.gd`, `module_catalog.gd`, `hull_loader.gd`)
- Blueprints are JSON saved to `user://blueprints/` with versioning (current: 3.0).
- `blueprint_manager.gd` handles serialize/deserialize, reconstruction into live vehicles, and the scratch vs. saved design split (scratch for test-range trips, saved only on explicit user Save).
- `module_catalog.gd` defines weapon modules, locomotion types, armor materials, and their stats; **hull entries are data-driven** — `hull_loader.gd` scans `.glb`+`.json` sidecar pairs from `assets/models/hulls/` (plus player mods under `user://mods/hulls/`) once and merges them into the catalog shape.

**Combat & Damage Model** (`damage_resolver.gd`, `battle/units/unit.gd`, `auto_weapon.gd`)
- **Damage classes**: kinetic, thermal, explosive, energy.
- **Armor materials**: hardened_steel, reactive_armor, ablative_ceramic, energy_shielding — each with per-class thresholds and reduction multipliers.
- **Threshold system**: hits below threshold deal chip damage (15% of reduced damage); brute-force hits (≥4× threshold) blend reduction toward 1.0.
- **Subsystem stripping**: 35% of hits target exposed modules; losing all locomotion immobilizes.
- **Directional armor**: armor modules only protect the facet facing the attacker.

**Unit Runtime** (`battle/units/unit.gd`)
- Generic team-aware combat unit built from blueprint via `BlueprintManager.reconstruct_vehicle()`.
- Handles armor/damage, subsystem stripping, movement orders, flying/naval/screw-drive locomotion, harvester economy loop.
- Fog-of-war: vision range from hull base + sensor modules; `fog_hidden` gates rendering and targetability.
- Navigation: `NavigationAgent3D` under a real match controller; falls back to direct-line steering otherwise. Movement math lives in `battle/movement/` (`steering.gd`, `flow_field_service.gd`).

**Design Lab** (`lab_document.gd`, `telemetry_rail.gd`, `lab_toolbar.gd`, `parts_menu.gd`, `gizmo_3d.gd`, `module_placer.gd`, `visual_builder.gd`)
- There is no `main_lab.gd` and no `stat_calculator.gd`. `scenes/MainLab.tscn` is only the 3D world plus two UI sub-scenes: `UI_StatBlock.tscn` (script `telemetry_rail.gd` — the right-hand stat/tweak rail, backed by `lab_document.gd`'s `LabDocument` model and `lab_toolbar.gd`'s toolbar) and `UI_PartsMenu.tscn` (script `parts_menu.gd` — the parts bin).
- 3D canvas for building blueprints. Drag parts from parts menu onto hull facets.
- Gizmo handles for stretching barrels/calibers (live stat updates), bilateral symmetry (M), free rotation (R).
- Clipping detection prevents overlapping modules.
- `module_placer.gd` computes locomotion station positions (10 types × 3 hull sizes) as pure functions of hull size — keep them stable; the old golden fixture went with the test suite.

**Match Controller** (`battle/match_director.gd`, `match_config.gd`, `match_rule_set.gd`, `match_setup.gd`)
- Every mode boots `Battle.tscn` through a **`MatchRuleSet`** written by its setup screen (`match_setup.gd` / `operations_draft.gd` / `operations_setup.gd` / `test_range_launcher.gd`). `match_director.gd` reads only the rule set; `MatchConfig` (autoload) carries just `rule_set` + a display-only `selected_map_id`.
- RTS economy: metal/crystal harvested by harvester units, delivered to Refineries (`battle/economy/` services).
- Production queues at the three Manufactory tiers (light/medium/heavy); extra same-tier manufactories speed their queue (100/75/60/50% per contributor).
- Energy system: base from hull + generator modules; regenerates; spent by energy weapons; can be drained (`power_budget.gd`, `boost_controller.gd`).
- Enemy AI: wave-based (`battle/ai/`), counter-picks player composition, places defenses when HQ threatened.

**Terrain & Navigation** (`terrain_builder.gd`, `map_catalog.gd`)
- Maps are JSON (migrated from hardcoded constants). Heightmap-based terrain; surface types are data-driven from `SURFACE_PALETTE` in `terrain_builder.gd` (14 named types).
- Multiple navmeshes: ground, water, deep water, amphibious (combined ground+water for screw-drive).
- Hull draught routes naval units onto deep_water_map vs water_map.

**Collision Geometry** (`module_volume.gd`, `hull_surface.gd`, `mesh_weld.gd`, `hull_collision_shapes.gd`)
- **`module_volume.gd` is the single source of a module's occupied space.** It measures each `MeshInstance3D` into a parallelepiped (centre + three half-edge vectors, so nested non-uniform scale shear survives) in module-local space, caches it on the node, and is invalidated by `VisualBuilder.build_visual()`. Both the Lab's click collider and the clipping test read it — they used to disagree, and the clip test was the one using `ModuleCatalog`'s authoring `size`.
- Design Lab clipping is a merged-AABB broad phase then a 15-axis **separating-axis test per mesh pair**. A module with no meshes at all falls back to its catalog box (`clip_boxes()`); `boxes()`/`bounds()` deliberately do not, because callers rely on "empty means it draws nothing".
- A battle module gets an **`Area3D` hit volume** (one box per visible mesh, capped at `BATTLE_MODULE_MAX_SHAPES`) on `BattleLayers.UNIT_MODULES`. Built before `bake_module_visual()` merges the sub-parts away. `Area3D` not `StaticBody3D`: it rides a moving unit, and `build_visual()` only spares `StaticBody3D` children when clearing.
- **Layers are the trap here.** `UNIT_MODULES` (128) is deliberately not the Lab's modules bit (2), which is in `auto_weapon`'s LOS mask — a hit volume must not double as an occluder. `HULL_SURFACE` (256) is deliberately not `hull_surface.gd`'s own default (16), which is `RESOURCE_NODES` in a match.
- Hull colliders are three tiers: the baked convex decomposition (`assets/models/hulls/<id>_collision.res`), else a single `create_convex_shape()` fit, else a box. See the Art Pipeline section for baking.

**Battle HUD** (`scripts/hud/`)
- **`scripts/hud/` is the only battle HUD.** `scripts/battle/hud/` now holds nothing but
  the two dev tools (`admin_menu.gd`, `debug_overlay.gd`). Anything in-match goes in
  `scripts/hud/`.
- Deliberately **does not** use `ui_tokens.gd`, `bomber_theme.tres`, or any of the
  `scripts/ui/` runtime-texture skins (`bakelite_panel`, `crt_readout`, `aluminum_trim`,
  `folded_paper_panel`, `phosphor_panel`). Those are the out-of-match / Design Lab
  language. `hud_style.gd` is the whole in-match vocabulary: flat fills, 1 px edges,
  no texture generation at runtime.
- Icons are **authored SVGs** in `assets/hud/icons/`, monochrome white, tinted with
  `modulate`. Editable in Inkscape; `assets/hud/icons/_author_icons.py` laid the set
  down originally but the SVGs are the asset — edit them, do not re-run it.
  `hud_icons.gd` declares every name the HUD asks for, and a missing icon degrades to
  text rather than failing the build.

| File | Owns |
|---|---|
| `hud_root.gd` | Layout, the single refresh clock, hotkeys, camera focus. A new region goes in `_build_layout()` or it does not exist. |
| `battle/hud/admin_menu.gd` | Session menu (pause / abandon / quit). Kept in `battle/hud/` because its lifetime is the match, but restyled to `hud_style.gd` and parented into the HUD column. |
| `hud_style.gd` | Palette, metrics, type, and the panel/label/button/bar factories. |
| `hud_skin.gd` | Optional texture/noise overlays over the flat panels (CIC instrument feel). Phase 1: returns nulls — pure flat fills are the default. |
| `hud_icons.gd` | SVG icon loading and tinting. |
| `hud_minimap.gd` | Tactical map: terrain bake, three-state fog, blips, frustum, click-to-jump, right-click orders. |
| `hud_production_deck.gd` | The five queues as five tabs, queue strip, build palette, tech gating. |
| `hud_command_card.gd` | Selection aggregated by design, order buttons, stance. |
| `hud_resource_ribbon.gd` | Credits, income, power, army count, clock. |
| `hud_alert_log.gd` | Transient top-right events, click to jump. |

Three things about it are load-bearing and were each a bug in the version it replaced:

- **One instance of each region.** The old tree had `BattleHUD` build a `CommandConsole`
  *and* a `MinimapOverlay`, `CommandConsole` build a second `MinimapOverlay`, and
  `BattleHUD` also carry an inlined third copy of the whole minimap; separately
  `match_director` built a `ProductionHUD` whose five accordion toolboxes duplicated
  `CommandConsole`'s tab bar and drawer. Two production interfaces and three minimaps
  were on screen at once.
- **Raster and vector are split in the minimap.** The texture (terrain + fog) is
  rebuilt only when `VisionService.shroud_version` changes; blips, selection rings,
  the camera frustum and alert pings are `_draw()` calls on an overlay `Control` at
  display resolution. The old version wrote blips as pixels into a low-res image and
  uploaded a texture every tick whether anything had moved or not.
- **The HUD drives itself.** `hud_root._process()` is the only clock — map at 20 Hz,
  panels at 5 Hz. `match_director` no longer refreshes it from the vision tick, and
  `HUDRoot.refresh()` is a deliberate no-op kept for the old call contract.
- **Everything lives in `HUDRoot.column`**, which is the viewport width capped at
  `COLUMN_MAX_WIDTH` (1920) and centred. At 1920 wide it is the whole screen; wider
  than that and the surplus becomes a symmetric gutter of battlefield rather than a
  stretched HUD. `layout_for(size)` is the single entry point — `fit_to_viewport()`
  calls it with the viewport size. Anything else that needs to sit in the same
  column (the session menu, the debug overlay) goes in via `attach_to_column()`,
  never onto the raw `CanvasLayer`.

The automated HUD capture harness (`tools/capture_hud.tscn`, `tools/capture_battle.gd`,
`visual_regression/`) went with the test suite. For interface work, run the game with
a real window and eyeball it; `battle/hud/debug_overlay.gd`, `perf_hud.gd` and
`battle/perf_toast.gd` are there for runtime inspection.

**Out-of-match UI** (`ui_shell.gd`, `ui_dock.gd`, `ui_flyout.gd`, `ui_theme.gd`, `ui_tokens.gd`, `bomber_theme.tres`)
- Menus, Design Lab, blueprint library. Animated cards, dock/flyout panels, control groups (assign/recall/double-tap recenter).
- Theme system with tokens for spacing, colors, typography. No decorative glyphs/emoji in UI text.

### Key Data Files

| File | Purpose |
|---|---|
| `scripts/module_catalog.gd` | Weapon modules, locomotion, armor materials, weapon archetypes (hulls merged in from `hull_loader.gd`) |
| `scripts/damage_resolver.gd` | ARMOR_TABLE, damage math (threshold, chip, brute-force, module strip) |
| `scripts/lab_document.gd` | LabDocument: live stat computation from blueprint (weight, speed, range, DPS, etc.) plus TWEAK_SPECS |
| `scripts/telemetry_rail.gd` | The right-hand telemetry rail UI (readouts, cards, verdict) |
| `scripts/lab_toolbar.gd` | The Design Lab top toolbar |
| `scripts/drivetrain.gd` | Drivetrain analysis: weight capacity, overload penalty, top speed |
| `scripts/faction_catalog.gd` | Ten-faction visual identities; mechanical passives retired with Livery — only `armor_weight_mult` is still read (`armor_paint.gd`) |
| `assets/blueprints/default_roster/` | Built-in default roster blueprints (JSON), loaded by `blueprint_manager.gd` |
| `data/loadout/` | Default player designs — build palette, Proving Ground dummies, tutorial units |
| `data/enemy/` | Enemy AI rosters (JSON) |
| `data/maps/` | Map definitions + baked terrain textures, discovered by `map_catalog.gd` |

## Development Commands

```bash
# Run the game
./Godot_v4.7.1-stable_win64.exe --path prototype

# Open editor
./Godot_v4.7.1-stable_win64.exe -e --path prototype

# Parse check all scripts (slow - see Checks)
./Godot_v4.7.1-stable_win64_console.exe --headless --path prototype --script res://tools/compile_check_all.gd

# Regenerate ALL audio (SFX, vocalisations, comms, ambience; music is copied
# from Tracks/, not synthesised - see below)
# Needs: pip install numpy scipy soundfile
cd prototype && python tools/generate_audio.py
cd prototype && python tools/generate_audio.py --only cannon,click   # one bank
cd prototype && python tools/generate_audio.py --music-only
# Render the from-scratch procedural soundtrack instead of the curated Tracks/
# set (both exist; curated is what currently ships - see Audio Pipeline below):
cd prototype && python tools/generate_audio.py --music-only --procedural-music
# Then reimport so Godot writes the .import sidecars:
./Godot_v4.7.1-stable_win64_console.exe --headless --editor --import --path prototype

# Regenerate parts/foundations/buildings meshes (Blender)
cd prototype && "/c/Program Files/Blender Foundation/Blender 5.2/blender.exe" --background --python tools/blender/build_meshes.py
# Then reimport in Godot:
./Godot_v4.7.1-stable_win64_console.exe --headless --editor --import --path prototype
```

## Art Pipeline

Everything is authored procedurally in Blender, not hand-modeled. **Two
separate scripts, and the split matters:**

| Script | Owns | Outputs |
|---|---|---|
| `tools/blender/build_vehicle_hulls.py` (+ `hull_forge.py`) | The vehicle hull roster — 114 hulls across 11 manufacturers | `assets/models/hulls/*.glb` + matching `.json` sidecars (non-foundation) |
| `tools/blender/build_meshes.py` | Parts, foundations, buildings, terrain props | `assets/models/parts/*.glb`, the 13 `is_foundation: true` hulls, buildings |

`build_meshes.py`'s `generate_hulls()` is **retired and raises if called**. It
authored through an axis helper with determinant −1 and then applied a second
determinant −1 matrix *after* `recalc_face_normals`, so every hull it produced
shipped inside out. Do not resurrect it; see
[`prototype/docs/HULL_NAMING.md`](prototype/docs/HULL_NAMING.md) for the
measured Blender↔Godot axis chain, the two winding checks, and the rule that
**forward is local −Z**. Foundations and buildings are unaffected — they never
went through that path.

`visual_builder.gd` falls back to procedural primitives for any part not yet authored in Blender.

```bash
# Rebuild the vehicle hull catalogue, then reimport
cd prototype && "/c/Program Files/Blender Foundation/Blender 5.2/blender.exe" --background --python tools/blender/build_vehicle_hulls.py
```

### Hull collision shells

Every hull ships a third file next to its mesh and sidecar:
`assets/models/hulls/<id>_collision.res` — the convex **decomposition** of its
welded shell, mounted by `unit_assembly._add_hull_collider()` as one
`CollisionShape3D` per piece. Without it a unit falls back to a single convex
fit, which fills deck wells, the gap under a tapered keel and the space between
sponsons. A minority of the roster splits into 2–5 pieces; most hulls are
genuinely convex and get one, i.e. no change.

```bash
# Re-derive collision for the whole roster WITHOUT touching hull geometry
./Godot_v4.7.1-stable_win64_console.exe --headless --path prototype --script res://tools/bake_hull_roster.gd --quit -- --collision-only
```

Three things about this are non-obvious and were each found the hard way:

- **`--collision-only` exists so adding collision data never rewrites a hull
  mesh.** A full bake regenerates every `<id>.res` — a large binary diff, and it
  re-runs marching cubes on geometry that already shipped. It also enumerates a
  *different set*: the shipped roster is 127 Blender-authored `.glb` hulls with
  no assembly sources at all, so collision-only lists the OUT_DIR sidecars and
  resolves each mesh through `MeshAssetLoader.get_hull_mesh()` — the same
  precedence chain the game uses, which is what guarantees the shell matches
  what a unit spawns with.
- **The weld is mandatory and is not `SurfaceTool.index()`.** That dedupes on
  the whole vertex tuple, and a faceted hull's coincident corners carry
  different normals, so it merges nothing. `mesh_weld.gd` welds on position
  only; measured, it takes the roster from ~18% to 100% shared topology. Without
  it the decomposer has no vertex adjacency and hangs.
- **`max_concavity` defaults to 1.0, which silently does nothing.** At the
  default VHACD returns one piece for every hull in the roster — reproducing the
  single convex fit exactly. `DECOMP_MAX_CONCAVITY = 0.05` is where the real
  splits appear and stop changing. Also note there is no `Mesh.convex_decompose`
  in Godot 4.7.1; the only decomposition entry point in ClassDB is
  `MeshInstance3D.create_multiple_convex_collisions()`, which attaches a
  `StaticBody3D` of shapes rather than returning them.

Hull-specific gotcha when adding one: an element's **vertical extent must be a
function of the hull's height alone**. Deriving it from width makes the
`autofit()` envelope solve non-convergent, and `hull_forge.normalize()` raises
rather than silently squashing the hull.

**Orrin uses tumblehome** — the cross-section is wider at the bottom (full
underside) and narrower at the top (`mass_w * tumblehome_frac`, default 0.80).
The tumblehome slope is part of the outline, not a post-process.

**Prominent greebles (masts, spines, barbettes) are integrated as
cross-section peaks** for Orrin, Kestrel, Rackham, Calder and Pillar — each
peak is a 4-vertex mesa bump on top of the chassis, active only in a small
z range, with the peak vertices held in the outline at every z (collapsed
to a flat segment on the deck when not active) so the cross-section point
count stays constant for the loft. This kills the "floating detail" look
that bolted-on `add_chamfered_box()` greebles used to leave behind on the
drone tender, command car, prospector and similar hulls.

## Audio Pipeline

**All audio is procedural and generated by `tools/audio/`** — there are no
recorded samples anywhere in the project. `tools/generate_audio.py` is a thin
CLI over that package, which is layered strictly downward:

| Module | Owns |
|---|---|
| `tools/audio/dsp.py` | numpy/scipy primitives: oscillators, filters, envelopes, saturation, reverb, tape |
| `tools/audio/instruments.py` | Music patches (guitar, bass, brass, kit, modal metal) |
| `tools/audio/sequencer.py` | Tracker-style patterns and timing |
| `tools/audio/tracks/` | One module per song |
| `tools/audio/voice.py` | Formant synthesis — the vocalised ordnance AND the radio comms |
| `tools/audio/sfx.py` | Every non-music sound, and the manifest of what exists |
| `tools/audio/render.py` | File output and pruning |
| `tools/audio/curated_music.py` | Copies the shipped soundtrack in from `Tracks/` at the repo root (see below) |

**The shipped soundtrack is currently curated, not synthesised.** `Tracks/` at
the repo root holds externally-generated finished tracks; `curated_music.py`
maps 5 states to one file each and copies it into `assets/audio/music/`.
**Skirmish is a rotation pool of 8 tracks, not one file** — `audio_manager.gd`
auto-advances to a new track (never repeating consecutively) each time the
current one finishes, so a skirmish running longer than any single track
doesn't just loop. See `curated_music.py` for the full state→track mapping.
The from-scratch synthesis engine in `tools/audio/tracks/` (oscillators →
instruments → a tracker sequencer → mastering) is still complete and still
works — `generate_audio.py --procedural-music` renders it — but it is not the
default. **Provenance of the `Tracks/` files is unconfirmed** — see the ⚠ note
in `CREDITS.md` before shipping. One consequence of curated tracks being
single mixed masters with no stem split: `match_director.gd`'s combat-intensity
mixing (which raises a rhythm/lead layer under a real engagement) has nothing
to act on and just lets the current rotation track play — correct, just
without the dynamic layering the procedural engine provides.

**`assets/audio/audio_manifest.json` is the contract.** The generator writes it;
`audio_manager.gd` loads it at boot to build its variant banks. Adding a sound is
a one-line edit to `sfx.py`'s `manifest()` plus a re-run — **no GDScript change**.
This exists because the old hand-maintained `SFX_PATHS` dictionary drifted from
`ui_feedback.gd`'s role table and left eight UI roles silently playing nothing.

**Determinism is required.** Every generator takes a seed and re-running must
produce byte-identical output, or each regeneration becomes a multi-megabyte
binary diff. Do not introduce an unseeded `random()` anywhere in `tools/audio/`.

**The sincere/absurd split is enforced by module.** `CORE_DESIGN_LANGUAGE.md` §6
requires ordnance to be vocalised (absurd) and everything else — comms, engines,
interface, ambience — to be played straight. Ordnance banks come from
`voice.ORDNANCE`; everything authored in `sfx.py` is sincere. If a sound in
`sfx.py` wants to be funny, it is in the wrong module.

## Important Notes

- **Godot version**: 4.7.1 (bundled executables in `prototype/`, gitignored; copies also sit at the repo root). **Do not open the project in Godot ≤4.3**: it is authored for 4.4+ (`.uid` sidecars, `bomber_theme.tres` at `format=4`, `config/features = ("4.7", ...)`), and an older editor downgrades features and can strip UIDs.
- **`compile_check_all.gd` is not a "quick" check** at this codebase's size. It loads 200+ interdependent scripts with `CACHE_MODE_IGNORE`, and has been observed running 20+ minutes without completing. Prefer the targeted `compile_check_changed.gd` for routine edits, and probe scripts for behavior (see Checks).

### Art direction docs

| Document | Owns |
|---|---|
| `docs/design/CORE_DESIGN_LANGUAGE.md` | Whole-game identity: philosophy, camera optics, environment, unit finish, motion, FX/audio split. Start here. |
| `docs/design/VISUAL_ART_DIRECTION.md` | Faction material/shader parameters, the ten factions, per-terrain-type texture direction, weapon-module modelling rules. |
| `prototype/docs/UI_STYLE_GUIDE.md` | Interface chrome only — tokens, type scale, materials, elevation, motion. |

- **No emoji/dingbats in UI text** — a standing rule, but note it is **not** currently enforced by anything. `ui_audit.gd` checks panel overflow / offscreen controls, theme-resource validity, icon/cursor assets, input-binding collisions, material luminance and layer discipline. Box-drawing and arrows are allowed (technical notation).
- **Blueprint version**: Only bumped when JSON schema changes could silently mis-load older saves (currently 3.0).
- **Scratch vs Saved designs**: "Test in Arena" writes a scratch file (`user://lab_scratch.json`), never a roster entry. Only explicit Save creates `user://blueprints/<id>.json`.
---

## VALIDATE

Adapter for Orchestrator Mode (see `~/.Codex/AGENTS.md`). Paste the relevant
line verbatim into a dispatch packet as `Validate:`. Run from the **repo
root** — the engine exes live there, not in `prototype/`.

```
Fast:   ./Godot_v4.7.1-stable_win64_console.exe --headless --path prototype \
          --script res://tools/compile_check_<slug>.gd --quit
Full:   ./Godot_v4.7.1-stable_win64_console.exe --headless --path prototype \
          --script res://tools/compile_check_all.gd
Probe:  ./Godot_v4.7.1-stable_win64_console.exe --headless --path prototype \
          --script res://tools/probe_<area>.gd --quit
```

Notes:
- **There is no unit test suite** — deleted 2026-08-10 (see `## Checks`). The
  152 `tools/probe_*.gd` scripts are the regression harness. Name one in
  `Acceptance_Criteria` whenever behavior, not just parsing, must hold.
- `Fast` above is deliberately **not** `compile_check_changed.gd`. That script
  hardcodes `const FILES := [...]`, so parallel Clankers editing it collide.
  Each task gets its own `tools/compile_check_<slug>.gd` — the 20-line pattern
  with its own `Target_Nodes` in the array — deleted on PASS.
  **Whoever dispatches writes it when the Clanker cannot.** `impl-worker` has
  `Write` and makes its own; `validate-runner` is `disallowedTools: Write,
  Edit`, so it must be handed a script that already exists or it fails the
  packet.
- `Full` loads 200+ interdependent scripts with `CACHE_MODE_IGNORE` — 20+ min
  observed. Structural-change gate only, never per-task, never retried by a
  circuit breaker.
- Godot block-buffers stdout when piped: no output until exit. Always pass
  `--path` and `--quit`.
- On a structural change (new autoload or `class_name`), reimport before
  validating or you get a misleading `Identifier "X" not declared`:
  `./Godot_v4.7.1-stable_win64_console.exe --headless --editor --import`.
  Same trigger as the graphify rebuild — do both.
