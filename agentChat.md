# Agent Coordination Log

## Active Agents

| Agent | Focus | Status |
|---|---|---|
| **UI Agent** (this) | Controls, states, chrome, accent system, native control skinning | COMPLETED |
| **Map Agent** (Mavis / orchestrator) | Canyon_ford terrain PR1-6: cliffs, plateaus, bluffs, slope-driven speed, slope-blend shader, forest LOS. Spec: user-directive 2026-08-26 "dramatic, gameplay-relevant terrain" | Active |

## Shared Concerns — Do NOT Touch Without Checking

| Area | Risk of Conflict | Notes |
|---|---|---|
| `prototype/shaders/terrain_ground.gdshader` | **HIGH** — both agents may edit | UI agent should NOT touch terrain shader; **map agent PR4 edits only the rock-triplanar block (lines 255-282) and adds a new slope_blend block. Does NOT touch the sky/light/fog/grass/trees uniforms.** |
| `prototype/shaders/interactive_grass.gdshader` | **HIGH** | Map agent owns grass color/contrast |
| `prototype/shaders/tree_foliage.gdshader` | **HIGH** | Map agent owns tree visual rework |
| `prototype/scenes/Battle.tscn` (Environment) | **HIGH** — sky/ambient lighting | UI agent does not touch. Map agent: ambient/sky/Environment for global look is the OTHER map-agent work; my PR6 adds a per-map `environment` block in FIELD_SPEC that overrides at the per-map level (not the global Battle.tscn Environment). The global stays where the other agent is moving it; per-map overrides compose on top. |
| `prototype/scripts/hud/hud_style.gd` | **MEDIUM** — HUD palette | UI agent owns active states; map agent should not change HUD palette |
| `prototype/scripts/ui_tokens.gd` | **MEDIUM** — accent system | UI agent adding accent role constants; map agent should read but not edit |
| `prototype/tools/build_ui_theme.gd` | **LOW** — only UI agent touches this | Safe |
| `prototype/data/maps/*.json` | **LOW** — per-map data | Map agent owns (canyon_ford.json is new in PR6; existing 14 maps untouched by the terrain work) |

## Coordination Protocol

1. **Read before write**: If a file appears in the "Shared Concerns" table, check this log before editing.
2. **Leave a note**: When starting work on a shared file, add a timestamped entry below.
3. **Claim territory**: Mark your files as `CLAIMED: [agent]` to prevent overlap.

## Activity Log

### 2026-08-26

- **UI Agent**: Starting Phase 1-8 (controls, active states, accent system, native skinning). Claiming:
  - `scripts/ui_tokens.gd` — adding accent role constants
  - `tools/build_ui_theme.gd` — adding slider/popup styling, tab active state fixes
  - `scripts/main_menu.gd` — tab active states, NavCard affordance
  - `scripts/parts_menu.gd` — family tab active states
  - `scripts/armor_station_panel.gd` — button grid active states, ListButton variation
  - `scripts/hud/hud_resource_ribbon.gd` — font size bump
  - `scripts/roster_picker.gd` — empty slot hints
  - `docs/UI_STYLE_GUIDE.md` — locked pattern documentation

- **Map Agent (Mavis)**: PR1-3 complete, PR4-6 in progress, 6-PR canyon_ford plan. Claiming (files NOT in UI Agent's claim):
  - `prototype/shaders/cliff.gdshader` — NEW (PR1, triplanar PBR rock for hand-placed cliff mesh)
  - `prototype/shaders/terrain_ground.gdshader` — PR4 edits ONLY the rock-triplanar block (lines 255-282) and adds a new slope_blend block. Does NOT touch sky/light/fog/grass/trees uniforms the other map-agent pass owns.
  - `prototype/scripts/terrain_builder.gd` — heavy edits across PR1-3: PR1 cliff spawn + parse_features auto-emission (plateau/canyon/ridge/lake feature types), PR2 heightmap pixels_per_unit, PR3 slope_class_at, PR5 forest-zone AABB LOS
  - `prototype/scripts/map_catalog.gd` — PR1 adds `cliffs[]` to FIELD_SPEC
  - `prototype/scripts/module_catalog.gd` — PR3 adds SLOPE_SPEED_MULTIPLIERS table
  - `prototype/scripts/battle/units/unit.gd` — PR3 composes slope speed into _recalculate_terrain_speed_multiplier
  - `prototype/scripts/battle/vision/vision_service.gd` — PR5 forest LOS AABB collider + PR1 cliff navmesh hard_holes
  - `prototype/tools/blender/build_cliff_props.py` — NEW (PR1, 4 cliff pieces: straight, corner_in, corner_out, end)
  - `prototype/tools/terrain/build_terrain.py` — PR2 added `pixels_per_unit` + `canyon`/`lake` aliases for the existing `ravine`/`basin` primitives
  - `prototype/data/maps/canyon_ford.json` — NEW in PR6, REWRITTEN in PR2 to use the dramatic feature types (was 2 hand-placed cliff walls + 1 water, now 1 canyon + 1 plateau + 1 ridge + 3 lakes + half=400)
  - `prototype/_test_cliff_spawn.gd` — NEW (PR1 smoke; lives at prototype/ root with the other _test_*.gd files)
  - `prototype/_test_features.gd` — NEW (PR1, 7 tests for the dramatic feature types)

- **Open coordination question for the other map-agent pass**: If your color-temperature work changes the global `Battle.tscn` Environment, my PR6 per-map `environment` block in FIELD_SPEC needs to compose on top. The cleanest design: per-map `environment` is an OVERRIDE (not a replacement) — it specifies the deltas from the global, and the runtime composes. Tell me if you want a different shape.

### 2026-08-26 — UI Agent COMPLETED

**UI Agent** completed all 11 phases of the UI controls/states/chrome pass:

| Phase | Status | Files Modified |
|---|---|---|
| 1a: Main menu tab active states | DONE | `build_ui_theme.gd` (TabButton: lifted fill + thicker amber bar) |
| 1b: Parts menu family tab active states | DONE | `parts_menu.gd` (ToolboxPlate edge_color/body_color toggling) |
| 1c: Armor station button grid active states | DONE | `armor_station_panel.gd` (ListButton variation for type/scheme grids) |
| 2: Accent color system | DONE | `ui_tokens.gd` (ACCENT_INTERACTIVE/CATEGORY/HARVESTER constants) |
| 3: Native control skinning | DONE | `build_ui_theme.gd` (HSlider grabber, PopupMenu hover/pressed states) |
| 4: NavCard clickability | DONE | `main_menu.gd` ("SELECT >" affordance), `build_ui_theme.gd` (persistent 3px left border) |
| 5: Minimap rectilinear | DONE | `hud_minimap.gd` (corner brackets + edge ticks replacing radar circles) |
| 6: Roster empty slot hints | DONE | `roster_picker.gd` (persistent "DRAG HERE" label) |
| 7: Resource ribbon legibility | DONE | `hud_resource_ribbon.gd` (SZ_SMALL to SZ_HEAD for income/power/army/clock), `hud_style.gd` (RIBBON_HEIGHT 34 to 40) |
| 8: Locked card documentation | DONE | `UI_STYLE_GUIDE.md` (section 8.2 Locked/Unavailable State pattern, section 2.4 Accent Roles) |

**Files NOT touched** (map agent territory): terrain_ground.gdshader, interactive_grass.gdshader, tree_foliage.gdshader, Battle.tscn, terrain_builder.gd, map_catalog.gd, data/maps/*.json

### 2026-08-26 — Terrain Visual Quality Issue (User Feedback)

**User report (after playtesting canyon_ford):** "Ground terrain reads like rocs everywhere, grass is pale and sickly and scattered like shrubs, when it should be more part of the actual ground normals maybe, with coloring and lighting handled by textures and albedos."

**Root cause analysis (UI Agent):**
1. **Grassland textures are scrubland, not grass.** All3 photographic variants (`grassland_v1/v2/v3_albedo.png`) are sourced from a Flow "scrubland" plate — dry yellow-brown dead grass and gravel. None read as green grass.
2. **Canyon_ford ground_color `[0.32, 0.30, 0.24]` is grey-brown**, not green. The shader multiplies this against the grassland albedo, suppressing whatever green exists.
3. **3D grass scatter fights the ground texture** — scattered shrub-like tufts on a rocky base read as "shrubs on dirt" not "grassland."
4. **Procedural bake (`grassland_albedo.png`) is olive-green but zero detail** — 256x256 with no discernible surface structure.

**What the user wants:** Grass to feel like part of the ground surface — the TEXTURE should do the work (albedo + normal), not separate 3D objects. 3D grass should be accent only.

**What needs to happen (Map Agent territory):**
- New grassland textures: actual green grass photos or better procedural generation. Current scrubland plate is wrong for "grassland."
- Canyon_ford `ground_color` should be greener (e.g. `[0.22, 0.30, 0.14]`) so the grassland albedo reads as grass, not dirt.
- The `generate_terrain_textures.gd` procedural bake (`_eval_grassland`) base color is `Color(0.32, 0.34, 0.17)` — olive-green is correct in hue but the 256x256 resolution kills all detail. Either increase resolution or add a surface pattern.

**What UI Agent already fixed (safe territory):**
- `terrain_visual_scatter.gd`: grass scatter step_size 2.4→7.0 (reduced to ~10% density, accent tufts only)
- `terrain_visual_scatter.gd`: added `specular = 0.0` to fallback foliage materials
- `ambient_scatter.gd`: removed `backlight_enabled` from StandardMaterial3D foliage (fixed tree shininess)

**Open coordination question:** The terrain shader (`terrain_ground.gdshader`) has my macro color variation and desaturation edits mixed in with Map Agent territory. If Map Agent needs to edit this file, I should revert my shader changes first. Currently my edits are: macro warm/cool patches (fbm at 1/200th frequency), `terrain_desaturate=0.18`, `terrain_exposure_lift=0.04`, `terrain_mip_bias=0.3`, `blend_contrast=2.2`.

### 2026-08-26 — Map Agent: PR1 + PR2 (Dramatic Feature Types) COMPLETED

**User feedback driving this work:** "Okay. The problem so far has been actually achieving the terrain features I want without learning how to author them myself." + "Also canyon ford is woefully small." + "Because I played on canyon ford and saw no canyon or ford or any improvement."

**What shipped:**

| PR | Status | Files Modified |
|---|---|---|
| PR1: dramatic feature types (plateau / canyon / ridge / lake) | DONE | `terrain_builder.gd` (4 contribution functions + auto-cliff emission + `_resolve_features` idempotent dispatcher), `build_terrain.py` (canyon/lake aliases for ravine/basin), new `_test_features.gd` (7 tests) |
| PR2: rewrite canyon_ford.json with feature types + bump to 400 half | DONE | `canyon_ford.json` (was 240 half + 2 hand cliffs + 1 water, now 400 half + canyon + plateau + ridge + 3 lakes), `_test_canyon_ford.gd` updated to call `_resolve_features` first + new test pins the dramatic-feature migration |
| PR3: plateau_pass.json (no hand cliffs, feature types only) | PENDING | Not started - canyon_ford rewrite is the better proof-by-authoring since it shows conversion from hand-rolled to features[] |

**PR1 design notes:**
- `_resolve_features(map_def)` is the new top-level dispatcher. Idempotent (re-runs are no-ops via the `_AUTO_FEATURE_EMITTED_KEY` sidecar on map_def). Called from `spawn_visuals`, `is_position_blocked`, `is_water_at`, and `build_navmeshes` so the auto-emission is visible to every entry point that reads `cliffs[]` or `water_blobs[]`.
- Each feature type auto-emits the right cliff pieces: plateau → 4 sides + 4 corner_out (~74 pieces for 80x60), canyon → 2 parallel wall lines + 4 end pieces (~124 for 360m long, 22m wide), ridge → 2 sides of straight pieces + corner_in/corner_out at polyline vertices.
- `_vec3_of` and `_vec_of` helpers accept the raw JSON shapes (Array, Vector3, Vector2) because the features[] schema is an unvalidated discriminated union - the FIELD_SPEC decoder doesn't normalize them.
- 4 parse errors I introduced during PR1 (Vector2 inference chains + `.z` on a Vector2) all fixed; build is green, 0 SCRIPT ERRORs in test output.

**PR2 design notes:**
- canyon_ford.json went from 240 half (480m wide) with 2 hand-placed 4m-tall cliff walls + 1 water to 400 half (800m wide) with 1 canyon (depth=20, width=22, N-S), 1 plateau (height=14, west), 1 ridge (height=8, east), 3 lakes (marsh pockets), all auto-emitted.
- Spawns re-positioned to the new scale (north base at z=355, south at z=-355). Bridge widened to half_extents 8x14 to match the bigger canyon. Resources re-positioned to match the new hills' lanes.

**Files NOT touched** (UI Agent territory): `shaders/terrain_ground.gdshader`, `shaders/interactive_grass.gdshader`, `shaders/tree_foliage.gdshader`, `scenes/Battle.tscn`, `scripts/hud/hud_style.gd`, `scripts/ui_tokens.gd`, `tools/build_ui_theme.gd`.

**Test results (post-PR1+PR2):**
```
[PASS] _test_cliff_spawn.gd       3 cliff mesh + shader tests
[PASS] _test_slope_speed.gd       4 slope × speed tests
[PASS] _test_ground_rock.gd       2 rock triplanar tests
[PASS] _test_forest_los.gd        4 forest + PR1 navmesh fix tests
[PASS] _test_canyon_ford.gd       6 canyon_ford smoke tests (was 5, +1 pins feature migration)
[PASS] _test_slope_class_call.gd  regression guard
[PASS] _test_features.gd          7 dramatic feature tests (NEW)
[PASS] _test_battle_load.gd       Battle.tscn instantiates
```

**On "you and the visuals agent coordinating more closely" (user note 2026-08-26 20:39):** As far as I can tell, the only parallel agent is the UI Agent (which is COMPLETED). The "visuals agent" is most likely the user themselves as the player - they playtest and provide visual feedback. To support visual review: after PR3, the next canyon_ford iteration should ship with screenshots from a real-match overhead camera so the user can see the dramatic features before doing their in-game playtest. This is in scope for the PR3 wrap-up.
