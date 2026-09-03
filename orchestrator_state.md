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
| **TASK-0018** | guided_missile — implement per-weapon VFX profile (mesh_part, trail bulk 1.0, impact scale 1.2) | `prototype/scripts/module_catalog.gd` (data only) | **QUEUED** | `flash_lite` | 0 | TASK-0017 |
| **TASK-0019** | missile_pod — implement per-weapon VFX profile (mesh_part, trail bulk 1.0, impact scale 1.0, 4× swarm) | `prototype/scripts/module_catalog.gd` (data only) | **QUEUED** | `flash_lite` | 0 | TASK-0017 |
| **TASK-0020** | rocket_artillery — implement per-weapon VFX profile (arcing rocket, trail bulk 2.6, impact scale 2.4, 4-8× salvo) | `prototype/scripts/module_catalog.gd` (data only) | **QUEUED** | `flash_lite` | 0 | TASK-0017 |
| **TASK-0021** | hypervelocity_missile — implement per-weapon VFX profile (mesh_part, trail bulk 1.0, impact scale 1.0, 2-4× ripple) | `prototype/scripts/module_catalog.gd` (data only) | **QUEUED** | `flash_lite` | 0 | TASK-0017 |
| **TASK-0022** | sam_launcher — implement per-weapon VFX profile (mesh_part, trail bulk 1.0, impact scale 1.0) | `prototype/scripts/module_catalog.gd` (data only) | **QUEUED** | `flash_lite` | 0 | TASK-0017 |
| **TASK-0023** | loitering_munition — implement per-weapon VFX profile (mesh_part, trail bulk 1.0, impact scale 1.2, top_attack=true) | `prototype/scripts/module_catalog.gd` (data only) | **QUEUED** | `flash_lite` | 0 | TASK-0017 |
| **TASK-0024** | anti_radiation_missile — implement per-weapon VFX profile (mesh_part, trail bulk 1.0, impact scale 1.0) | `prototype/scripts/module_catalog.gd` (data only) | **QUEUED** | `flash_lite` | 0 | TASK-0017 |
| **TASK-0025** | bunker_buster — implement per-weapon VFX profile (mesh_part, trail bulk 1.0, impact scale 1.4, top_attack=true) | `prototype/scripts/module_catalog.gd` (data only) | **QUEUED** | `flash_lite` | 0 | TASK-0017 |
| **TASK-0026** | cruise_missile — implement per-weapon VFX profile (mesh_part, trail bulk 1.0, impact scale 1.5, long range 4.67s) | `prototype/scripts/module_catalog.gd` (data only) | **QUEUED** | `flash_lite` | 0 | TASK-0017 |
| **TASK-0027** | artillery — implement per-weapon VFX profile (arcing bomb, shell_radius 0.4, arc 12.0, blast 6.0) | `prototype/scripts/module_catalog.gd` (data only) | **QUEUED** | `flash_lite` | 0 | TASK-0017 |
| **TASK-0028** | mortar_array — implement per-weapon VFX profile (3× salvo, shell_radius 0.2, arc 6.0, blast 4.0, no trail) | `prototype/scripts/module_catalog.gd` (data only) | **QUEUED** | `flash_lite` | 0 | TASK-0017 |
| **TASK-0029** | spigot_mortar — implement per-weapon VFX profile (tumble bomb, shell_radius 0.5×payload, blast 5.5×payload) | `prototype/scripts/module_catalog.gd` (data only) | **QUEUED** | `flash_lite` | 0 | TASK-0017 |
| **TASK-0030** | cluster_dispenser — implement per-weapon VFX profile (canister→bomblets, shell_radius 0.12×payload, blast 2.5×payload) | `prototype/scripts/module_catalog.gd` (data only) | **QUEUED** | `flash_lite` | 0 | TASK-0017 |
| **TASK-0031** | plasma_lobber — implement per-weapon VFX profile (sphere + puddle decal, shell_radius 0.35, arc 4.0, blast 4.5) | `prototype/scripts/module_catalog.gd` (data only) | **QUEUED** | `flash_lite` | 0 | TASK-0017 |
| **TASK-0032** | mk19_grenade_launcher — implement per-weapon VFX profile (shallow arc, shell_radius 0.16, arc 1.8, blast 2.2) | `prototype/scripts/module_catalog.gd` (data only) | **QUEUED** | `flash_lite` | 0 | TASK-0017 |
| **TASK-0033** | napalm_mortar — implement per-weapon VFX profile (bomb + burn pool, shell_radius 0.3, arc 7.0, blast 4.0, pool 1.7/2.2) | `prototype/scripts/module_catalog.gd` (data only) | **QUEUED** | `flash_lite` | 0 | TASK-0017 |

## Fleet Budget

- Total Clanker Attempts: 14
- Tier Distribution: `flash_lite: 14`
- Budget Ceiling: 3× task count (99 tasks × 3 = 297 attempts max)

## Structural Delta Log

**STRUCT: YES** (TASK-0017)
- New symbols: `auto_weapon._attach_trail_to_round(round_node: Node3D, trail_bulk: float, shell_radius: float) → void`
- New symbols: `auto_weapon._detonate_at(position: Vector3, blast_radius: float, damage: float, color: Color, entropy: float) → void`
- New document: `prototype/docs/WEAPON_VFX_FRAMEWORK.md` (contract for 16 per-weapon Clankers)
- No deleted/renamed symbols. No new autoloads or class_name changes. Reimport not required.

## Graph Freshness

- `graphify-out/graph.json` built from commit `4af4a0c046ae3e7d61e697a1f81d7d355e4e93fc`
- Current HEAD is 1 framework commit stale (TASK-0017 changes not yet indexed)
- Graph rebuild scheduled before next fleet dispatch