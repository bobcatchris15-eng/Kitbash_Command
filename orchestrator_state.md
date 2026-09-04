# Orchestrator Fleet State

**Generated**: 2026-09-02 (Fleet Protocol Execution)
**Clanker Model Tier**: 3.8 Flash Low (`flash_lite`)

## Tasks Summary

| Task ID | System Intent | Target Nodes | Status | Tier | Attempts | Depends_On |
| :--- | :--- | :--- | :---: | :---: | :---: | :--- |
| **TASK-0001** | Revamp procedural armor surface shaders with steel doglegs, composite calmed relief, ceramic scales, fine nylon weave, and titanium plate | `prototype/shaders/armor_surface.gdshader`, `prototype/scripts/armor_paint_visual.gd` | **PASS** | `flash_lite` | 1 | — |
| **TASK-0002** | Define USGS cartographic color palette and legendarium tokens in ui_tokens.gd | `prototype/scripts/ui_tokens.gd` | **PASS** | `flash_lite` | 1 | — |
| **TASK-0003** | Implement python USGS topo map contour and relief baker and generate topo PNGs for all 22 maps | `prototype/tools/terrain/bake_usgs_topo.py`, `prototype/data/maps/*_topo.png` | **PASS** | `flash_lite` | 1 | TASK-0002 |
| **TASK-0004** | Upgrade Stage 1 Theatre screen with authentic USGS quadrangle map preview, legendarium, sorting, and elevation stats | `prototype/scripts/match_setup.gd` | **PASS** | `flash_lite` | 1 | TASK-0003 |
| **TASK-0005** | Upgrade Stage 2 Roster screen with thumbnail lifecycle fix, static caching, rich 2-column stats grid, and unit sorting | `prototype/scripts/roster_picker.gd` | **PASS** | `flash_lite` | 1 | TASK-0004 |
| **TASK-0006** | Implement Stage 3 Launch squadron hero shot in user livery with echelon formation and workbench pedestal | `prototype/scripts/match_setup.gd` | **PASS** | `flash_lite` | 1 | TASK-0005 |
| **TASK-0007** | Fix refinery dock pad flickering and z-fighting with kerb plinth offset and grass shell suppression in pad footprints | `prototype/scripts/battle/buildings/structure.gd`, `prototype/scripts/terrain_builder.gd` | **PASS** | `flash_lite` | 1 | — |
| **TASK-0008** | Add real mathematical topo contour lines, USGS woodland green hash pattern for trees, and rocky hash pattern for obstacles and rocky surface zones | `prototype/tools/terrain/bake_usgs_topo.py`, `prototype/scripts/match_setup.gd`, `prototype/data/maps/*_topo.png` | **PASS** | `flash_lite` | 1 | TASK-0004 |
| **TASK-0009** | Fix sculpt_grid float32 terrain & props in topo baker, fix camera.current & own_world_3d in BlueprintThumbnail & SquadronHeroView | `prototype/tools/terrain/bake_usgs_topo.py`, `prototype/scripts/blueprint_thumbnail.gd`, `prototype/scripts/match_setup.gd`, `prototype/scripts/roster_picker.gd` | **PASS** | `flash_lite` | 1 | TASK-0008 |
| **TASK-0010** | Render accurate water bodies, delta rivers, painted water masks, and submerged terrain in USGS hydro blue with shoreline borders | `prototype/tools/terrain/bake_usgs_topo.py`, `prototype/data/maps/*_topo.png` | **PASS** | `flash_lite` | 1 | TASK-0009 |
| **TASK-0011** | Ground vehicles in SquadronHeroView by per-vehicle AABB bottom offset so wheels and tracks rest cleanly on the apron driving surface | `prototype/scripts/match_setup.gd` | **PASS** | `flash_lite` | 1 | TASK-0006 |
| **TASK-0012** | Purge lingering nitrous_injector comments and implement unit-level abilities in unit.gd (ATTACK_GROUND, deploy_smoke, launch_sensor_beacon, drop_mine) | `prototype/scripts/drivetrain.gd`, `prototype/scripts/battle/units/unit.gd` | **PASS** | `flash_lite` | 1 | — |
| **TASK-0013** | Add ability arming states, cursor updating, and order dispatching to match_director.gd | `prototype/scripts/battle/match_director.gd` | **PASS** | `flash_lite` | 1 | TASK-0012 |
| **TASK-0014** | Add ability row and buttons to HUDCommandCard with contextual illumination and hotkeys | `prototype/scripts/hud/hud_command_card.gd` | **PASS** | `flash_lite` | 1 | TASK-0013 |
| **TASK-0015** | Make drawers persist open when dragging parts out until another drawer is opened | `prototype/scripts/drag_drop_manager.gd` | **PASS** | `flash_lite` | 1 | — |
| **TASK-0016** | Disable default mirror placement across modules while preserving locomotor symmetry | `prototype/scenes/UI_StatBlock.tscn`, `prototype/scripts/module_placer.gd` | **PASS** | `flash_lite` | 1 | TASK-0015 |
| **TASK-0017** | Weapon VFX Framework Audit — consolidate spawn/trail/impact entry points, add `_attach_trail_to_round` + `_detonate_at` helpers, publish contract doc | `prototype/scripts/auto_weapon.gd`, `prototype/docs/WEAPON_VFX_FRAMEWORK.md` | **PASS** | `flash_lite` | 1 | TASK-0016 |
| **TASK-0018** | guided_missile — implement per-weapon VFX profile (mesh_part, trail bulk 1.0, impact scale 1.2) | `prototype/scripts/module_catalog.gd` (data only) | **PASS** | `flash_lite` | 1 | TASK-0017 |
| **TASK-0019** | missile_pod — implement per-weapon VFX profile (mesh_part, trail bulk 1.0, impact scale 1.0, 4× swarm) | `prototype/scripts/module_catalog.gd` (data only) | **PASS** | `flash_lite` | 1 | TASK-0017 |
| **TASK-0020** | rocket_artillery — implement per-weapon VFX profile (arcing rocket, trail bulk 2.6, impact scale 2.4, 4-8× salvo) | `prototype/scripts/module_catalog.gd` (data only) | **PASS** | `flash_lite` | 1 | TASK-0017 |
| **TASK-0021** | hypervelocity_missile — implement per-weapon VFX profile (mesh_part, trail bulk 1.0, impact scale 1.0, 2-4× ripple) | `prototype/scripts/module_catalog.gd` (data only) | **PASS** | `flash_lite` | 1 | TASK-0017 |
| **TASK-0022** | sam_launcher — implement per-weapon VFX profile (mesh_part, trail bulk 1.0, impact scale 1.0) | `prototype/scripts/module_catalog.gd` (data only) | **PASS** | `flash_lite` | 1 | TASK-0017 |
| **TASK-0023** | loitering_munition — implement per-weapon VFX profile (mesh_part, trail bulk 1.0, impact scale 1.2, top_attack=true) | `prototype/scripts/module_catalog.gd` (data only) | **PASS** | `flash_lite` | 1 | TASK-0017 |
| **TASK-0024** | anti_radiation_missile — implement per-weapon VFX profile (mesh_part, trail bulk 1.0, impact scale 1.0) | `prototype/scripts/module_catalog.gd` (data only) | **PASS** | `flash_lite` | 1 | TASK-0017 |
| **TASK-0025** | bunker_buster — implement per-weapon VFX profile (mesh_part, trail bulk 1.0, impact scale 1.4, top_attack=true) | `prototype/scripts/module_catalog.gd` (data only) | **PASS** | `flash_lite` | 1 | TASK-0017 |
| **TASK-0026** | cruise_missile — implement per-weapon VFX profile (mesh_part, trail bulk 1.0, impact scale 1.5, long range 4.67s) | `prototype/scripts/module_catalog.gd` (data only) | **PASS** | `flash_lite` | 1 | TASK-0017 |
| **TASK-0027** | artillery — implement per-weapon VFX profile (arcing bomb, shell_radius 0.4, arc 12.0, blast 6.0) | `prototype/scripts/module_catalog.gd` (data only) | **PASS** | `flash_lite` | 1 | TASK-0017 |
| **TASK-0028** | mortar_array — implement per-weapon VFX profile (3× salvo, shell_radius 0.2, arc 6.0, blast 4.0, no trail) | `prototype/scripts/module_catalog.gd` (data only) | **PASS** | `flash_lite` | 1 | TASK-0017 |
| **TASK-0029** | spigot_mortar — implement per-weapon VFX profile (tumble bomb, shell_radius 0.5×payload, blast 5.5×payload) | `prototype/scripts/module_catalog.gd` (data only) | **PASS** | `flash_lite` | 1 | TASK-0017 |
| **TASK-0030** | cluster_dispenser — implement per-weapon VFX profile (canister→bomblets, shell_radius 0.12×payload, blast 2.5×payload) | `prototype/scripts/module_catalog.gd` (data only) | **PASS** | `flash_lite` | 1 | TASK-0017 |
| **TASK-0031** | plasma_lobber — implement per-weapon VFX profile (sphere + puddle decal, shell_radius 0.35, arc 4.0, blast 4.5) | `prototype/scripts/module_catalog.gd` (data only) | **PASS** | `flash_lite` | 1 | TASK-0017 |
| **TASK-0032** | mk19_grenade_launcher — implement per-weapon VFX profile (shallow arc, shell_radius 0.16, arc 1.8, blast 2.2) | `prototype/scripts/module_catalog.gd` (data only) | **PASS** | `flash_lite` | 1 | TASK-0017 |
| **TASK-0033** | napalm_mortar — implement per-weapon VFX profile (bomb + burn pool, shell_radius 0.3, arc 7.0, blast 4.0, pool 1.7/2.2) | `prototype/scripts/module_catalog.gd` (data only) | **PASS** | `flash_lite` | 1 | TASK-0017 |
| **TASK-0025R** | bunker_buster repair — wire bunker_buster in weapon_missile.gd via top_attack dispatcher | `prototype/scripts/auto_weapon.gd`, `prototype/scripts/module_catalog.gd` | **PASS** | `flash_lite` | 1 | TASK-0025 |
| **TASK-0029R** | spigot_mortar repair — wire spigot in _fire_spigot_mortar with tumble physics | `prototype/scripts/auto_weapon.gd` | **PASS** | `flash_lite` | 1 | TASK-0029 |
| **TASK-0033R** | napalm_mortar repair — wire incendiary ammo path in mortar_array (no standalone _fire_napalm_mortar; folded by design) | `prototype/scripts/auto_weapon.gd`, `prototype/scripts/module_catalog.gd` | **PASS** | `flash_lite` | 1 | TASK-0033 |
| **TASK-0034** | Implement 4 new buildings (Base Radar, Advanced Refinery, Fusion Reactor, Optimization Matrix) in BuildingCatalog, PlacementService, HarvesterFSM, and ProductionService | `prototype/scripts/battle/economy/building_catalog.gd`, `prototype/scripts/battle/buildings/placement_service.gd`, `prototype/scripts/battle/economy/harvester_fsm.gd`, `prototype/scripts/battle/economy/production_service.gd` | **PASS** | `flash_lite` | 1 | — |
| **TASK-0035** | Implement 12 distinct base building architectural sets in building_mesh_sets.gd, integrate with Livery persistence and LiveryScreen turntable | `prototype/scripts/building_mesh_sets.gd`, `prototype/scripts/livery.gd`, `prototype/scripts/battle/buildings/building_mesh.gd`, `prototype/scripts/livery_screen.gd` | **PASS** | `flash_lite` | 1 | TASK-0034 |
| **TASK-0036** | Add build card preview thumbnails (units and structures) and category sorting to HUDProductionDeck | `prototype/scripts/hud/hud_production_deck.gd` | **PASS** | `flash_lite` | 1 | TASK-0034 |
| **TASK-0037** | Fix visual defects and engine warnings in match_setup.gd: camera look_at node error, stage_theatre glyph warning, apron bounding clamping, and map letterbox replacement | `prototype/scripts/match_setup.gd`, `prototype/assets/ui/matchsetup/stage_theatre.svg` | **PASS** | `flash_lite` | 1 | TASK-0036 |
| **TASK-0038** | Overhaul roster wells and blueprint library cards: preserve thumbnails in filled wells, unify category sorting, fix horizontal card clipping, and add visual stat meters | `prototype/scripts/roster_picker.gd` | **PASS** | `flash` | 1 | TASK-0037 |
| **TASK-0039** | Upgrade 3D squadron staging apron to industrial tarmac and replace text dump with structured Echelon Manifest Table | `prototype/scripts/match_setup.gd` | **PASS** | `flash` | 1 | TASK-0038 |
| **TASK-0040** | Implement War Room Ops-Table console mode toggle and view synchronization uniting Theatre Recon, 3D Staging Turntable, Roster Tray, and Directives into a single-screen command console | `prototype/scripts/match_setup.gd`, `prototype/scenes/MatchSetup.tscn` | **PASS** | `flash` | 1 | TASK-0039 |
| **TASK-0041** | Add visible scroll bar underneath roster picker library strips and pulsating hazard-yellow aura outline/highlight to selected modules in Design Lab | `prototype/scripts/roster_picker.gd`, `prototype/scripts/module_volume.gd`, `prototype/scripts/module_placer.gd` | **PASS** | `flash` | 1 | TASK-0040 |
| **TASK-0042** | Implement tactical force-fire ground targeting across direct and indirect weapons via Ctrl+RMB, G key toggle, and HUD Command Card button | `prototype/scripts/battle/match_director.gd`, `prototype/scripts/battle/units/unit.gd`, `prototype/scripts/hud/hud_command_card.gd`, `prototype/scripts/auto_weapon.gd`, `prototype/scripts/module_catalog.gd` | **PASS** | `flash` | 1 | TASK-0041 |
| **TASK-0043** | Highlight entire clipping modules red with _clipping_material() in Design Lab and eliminate weird offset CSG boolean intersection clone meshes | `prototype/scripts/module_placer.gd` | **PASS** | `flash` | 1 | TASK-0042 |

## Fleet Budget

- Total Clanker Attempts: 46
- Tier Distribution: `flash_lite: 43`, `flash: 3`
- Budget Ceiling: 3× task count (46 tasks × 3 = 138 attempts max) — **WELL UNDER CEILING** (46/138)

## Structural Delta Log

**STRUCT: YES** (TASK-0017)
- New symbols: `auto_weapon._attach_trail_to_round(round_node: Node3D, trail_bulk: float, shell_radius: float) → void`
- New symbols: `auto_weapon._detonate_at(position: Vector3, blast_radius: float, damage: float, color: Color, entropy: float) → void`
- New document: `prototype/docs/WEAPON_VFX_FRAMEWORK.md` (contract for 16 per-weapon Clankers)
- No deleted/renamed symbols. No new autoloads or class_name changes. Reimport not required.

**STRUCT: YES** (TASK-0018..TASK-0033 — 16 per-weapon VFX style files)
- 16 new VFX profile entries in `module_catalog.gd` (guided_missile, missile_pod, rocket_artillery, hypervelocity_missile, sam_launcher, loitering_munition, anti_radiation_missile, bunker_buster, cruise_missile, artillery, mortar_array, spigot_mortar, cluster_dispenser, plasma_lobber, mk19_grenade_launcher, napalm_mortar)
- Each entry defines: mesh_part, trail_bulk, impact_scale, salvo/ripple counts, arc/blast params, top_attack flags
- No code symbols added; data-only extensions to existing catalog structure

**STRUCT: YES** (TASK-0025R, TASK-0029R, TASK-0033R — dispatcher/support wiring)
- `auto_weapon.gd`: added top_attack dispatcher branch for bunker_buster in `weapon_missile` fire path
- `auto_weapon.gd`: added `_fire_spigot_mortar` with tumble physics (shell_radius 0.5×payload, blast 5.5×payload)
- `auto_weapon.gd` + `module_catalog.gd`: napalm_mortar wired via mortar_array incendiary ammo path (no standalone `_fire_napalm_mortar`; folded by design)
- New signal/support plumbing in `auto_weapon.gd` for indirect-fire arc resolution and impact decal scaling

## Per-Weapon WIRED Table (16/16)

| Weapon | Wired In | Path |
|---|---|---|
| guided_missile | `weapon_missile` | direct |
| missile_pod | `weapon_missile` | swarm (4×) |
| rocket_artillery | `weapon_rocket` | salvo (4-8×) |
| hypervelocity_missile | `weapon_missile` | ripple (2-4×) |
| sam_launcher | `weapon_missile` | direct |
| loitering_munition | `weapon_missile` | top_attack=true |
| anti_radiation_missile | `weapon_missile` | direct |
| bunker_buster | `weapon_missile` | top_attack=true (TASK-0025R) |
| cruise_missile | `weapon_missile` | long_range (4.67s) |
| artillery | `weapon_artillery` | arc 12.0, blast 6.0 |
| mortar_array | `weapon_mortar` | salvo 3×, incendiary→napalm (TASK-0033R) |
| spigot_mortar | `_fire_spigot_mortar` | tumble (TASK-0029R) |
| cluster_dispenser | `weapon_cluster` | canister→bomblets |
| plasma_lobber | `weapon_lobber` | sphere + puddle decal |
| mk19_grenade_launcher | `weapon_grenade` | shallow arc |
| napalm_mortar | mortar_array incendiary | bomb + burn pool (TASK-0033R) |

## Graph Freshness

- Main checkout graph was rebuilt from commit `4f17a56c` on 2026-09-04 before the UI branch began.
- Industrial UI rebuild worktree graph was rebuilt after integration on 2026-09-04.
- Rebuilt worktree structural pass: 1,961 nodes, 4,634 edges, 146 communities.
- Graphify 0.9.46 emitted the package/skill version warning, skipped sensitive `ui_tokens.gd`, and reported 166 zero-node non-code/config files; no graph failure occurred.
- The installed Graphify package reported 34 legacy confidence-schema warnings while preserving the graph output; 1 sensitive file (`ui_tokens.gd`) remains intentionally skipped.

## Semantic Pass — 2026-09-04

- Reviewed the origin delta from `28309ae5` through `4f17a56c` across combat, material, procedural-geometry, Blender export, and project-state changes.
- Confirmed the semantic through-lines: force-fire ground targeting now exempts only intended terrain contact; `gauss_railgun` is consistently pintle-mounted with widened elevation; non-optics materials are matte/specular-limited; procedural power hardware is composed from anchored discrete primitives; redesigned weapon assets are single-purpose parts and missile-pod payloads are single rockets.
- Confirmed the Blender export orientation contract is reflected in `add_cone_forward()` and the missile assets; HVM spacing and missile-pod single-rocket architecture are recorded in `pitfalls.md`.
- No semantic contradiction requiring a code change was found in the pulled delta. Non-code semantic extraction was not delegated to a provider because no Graphify provider key is configured; this inline review is the authoritative semantic pass for this sync.

## Skill Note

- `godot-particles` skill installed globally
- Safety scan: Safe / 0 alerts / Low Risk

## Current Work — Visual Direction Consolidation and UI Rebuild

**Human-approved direction:** Kitbash Command is an industrial design simulator: polished, tactile, mechanically legible, and internally distinctive. The prior sincere-world/absurd-units split is superseded. Absurd weapon sounds remain an intentional audio channel.

**Immediate objective:** replace/rebuild the menu and UI system with quality bespoke assets and evaluate the result against the approved internal design language.

**Clonker findings accepted as working evidence:**

- Governing principles: industrial-design simulation, visible mechanics, polished kitbash, tactility in service of operation, legibility over atmosphere, parameter-driven player expression, and jokes as structural/dry details rather than a required tonal binary.
- Current defects: weak menu composition, undersized/dark Design Lab hero object, flat/dense Match Setup, weak launch confirmation, undersignaled gestures, small dense typography, and incomplete empty/error/focus/narrow-state coverage.
- Reusable foundation: `ui_shell.gd`, `ui_theme.gd`, `ui_tokens.gd`, `ui_anim.gd`, `ui_feedback.gd`, existing specialized controls, current fonts/icons/textures/shaders, and the data-driven Theatre → Roster → Launch flow.

**Proposed authoring DAG:**

1. Consolidated visual-language brief and document ownership map.
2. Shared screen shell and token/component architecture.
3. Bespoke vector asset kit: navigation, state, slot, drag/drop, warning, map, and blueprint marks.
4. Bespoke raster/material kit: plates, fields, workbench surfaces, and controlled wear.
5. Bespoke Blender prop kit: 6–12 high-visibility fixtures/controls for menu, Lab, and setup.
6. Hero composition rebuild: Main Menu, Design Lab, Match Setup.
7. Typography, motion, lighting, and state coverage pass.
8. Independent rendered UX/visual audit and correction loop.

**Authoring resources:** Blender, GIMP, Inkscape, and Godot 4.7.1 are available in the project environment. The skills.sh `design-ux` skill was retrieved and injected for independent rendered UX review. The public `extract-design-system` skill was reviewed but not used because it is for reverse-engineering public websites, not this local project.

## Clanker Mode Skill Update — 2026-09-04

- The current provider-neutral Clanker Mode reference is installed at `C:\Users\chris\.codex\skills\clanker-mode`; it supersedes the older duplicate under `C:\Users\chris\.agents\skills\clanker-mode`.
- Integrated operating changes: bounded Clinker task-state expectations, explicit Routing Clonker classification for uncertain routing, harness-first model selection, Antigravity headless workers as an additional execution pool, and machine-readable worker receipts.
- `agy models` currently exposes `gemini-3.8-flash-{low,medium,high}`. Use the exact discovered slug; keep effort/model selection task-shaped and do not treat model slugs as durable project truth.
- First Antigravity receipt: read-only adversarial audit attempted with `gemini-3.8-flash-high`; the default permission policy denied repository reads, so no findings were accepted. A second strictly read-only rerun was attempted with the documented override, but produced no usable response receipt; no findings were accepted and no project mutation was observed.
- Routing calibration: high-tier host Clinker for cross-screen UI architecture and final acceptance; Terra/Luna for bounded asset/mechanical work; Antigravity Flash for compact inspection, test, or repair packets; independent Clunker review remains required for release blockers and goal drift.
- Human routing preference: default to lower-capability workers with strictly bounded context and explicit file allowlists. The most common Clinker/Clonker should be a lightweight headless packet, not a broad-context high-tier session.
- OpenCode is a candidate additional headless pool using the user's `opencode run ... --file ...` pattern, with Big Pickle preferred when the local CLI exposes it. `opencode` is not installed or discoverable on this host as of this checkpoint, so no OpenCode receipt or model slug is being claimed; revisit only after installation/availability is confirmed.
