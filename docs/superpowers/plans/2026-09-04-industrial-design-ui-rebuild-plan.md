# Industrial Design UI Rebuild Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Rebuild the Main Menu, Design Lab, and Match Setup as one bespoke industrial-design-simulator interface with authored UI, raster, vector, and 3D fixture assets.

**Architecture:** Preserve the existing data and interaction substrate where it is sound, while moving shared presentation into one shell/token/component system. Build a playable Main Menu + Design Lab vertical slice first, then extend the same language to Match Setup and finish with rendered state coverage and independent review.

**Tech Stack:** Godot 4.7.1/GDScript, existing Control/Theme system, CanvasItem shaders, Blender 5.2 Python/bmesh, GIMP-compatible raster workflows, Inkscape SVG assets, project-root Godot console binary.

**Spec:** `docs/superpowers/specs/2026-09-04-industrial-design-ui-rebuild-design.md`

## Global Constraints

- The product identity is an industrial design simulator: polished, tactile, mechanically legible, and internally distinctive.
- The prior sincere-world/absurd-units split is superseded; absurd weapon sounds remain an intentional isolated audio channel.
- External references are behavior/inspiration sources only; do not import an external visual identity or copy third-party asset packs.
- Existing functionality is substrate, not a layout mandate; navigation and information architecture may be redesigned when intuition, response, or hierarchy improve.
- Reuse and evolve `ui_shell.gd`, `ui_theme.gd`, `ui_tokens.gd`, `ui_anim.gd`, `ui_feedback.gd`, existing Lab radial/document concepts, and data-driven Match Setup where structurally sound.
- Exact colors, textures, shader mechanisms, lighting values, transition durations, icon shapes, and prop designs are paint-pass values and must remain tunable.
- Godot validation uses `..\Godot_v4.7.1-stable_win64_console.exe --headless --path prototype --editor --quit` from the repository root.
- Preserve the user’s existing `prototype/scripts/vfx/weapon_vfx_guided_missile.gd` edit; do not modify it.

---

### Task 1: Establish execution ledger and shared visual contract

**Files:**
- Modify: `.gitignore`
- Create: `.superpowers/sdd/industrial-design-ui-rebuild/progress.md`
- Reference: `docs/superpowers/specs/2026-09-04-industrial-design-ui-rebuild-design.md`, `orchestrator_state.md`

**Interfaces:**
- Consumes: approved design brief and existing UI system paths.
- Produces: isolated worktree, execution ledger, and task DAG baseline.

- [ ] **Step 1: Verify branch/worktree state**

Run:

```powershell
git status --short --branch
git worktree list
```

Expected: the preserved weapon-VFX edit is visible and no worktree is active for this plan.

- [ ] **Step 2: Create the isolated worktree**

Run:

```powershell
git worktree add .worktrees/industrial-design-ui-rebuild -b codex/industrial-design-ui-rebuild
```

- [ ] **Step 3: Create the plan ledger**

Write `.superpowers/sdd/industrial-design-ui-rebuild/progress.md` with first line `# SDD ledger — plan: docs/superpowers/plans/2026-09-04-industrial-design-ui-rebuild-plan.md`, then record the baseline SHA, task DAG, shared-file conflict scan, and the ruling that the weapon-VFX file is outside this plan’s write set.

- [ ] **Step 4: Validate the baseline**

Run from the worktree:

```powershell
..\Godot_v4.7.1-stable_win64_console.exe --headless --path prototype --editor --quit
```

Expected: exit code 0; record any existing ObjectDB/resource warnings without treating them as new UI regressions.

- [ ] **Step 5: Commit the execution setup**

```powershell
git add .gitignore .superpowers/sdd/industrial-design-ui-rebuild/progress.md
git commit -m "chore: initialize UI rebuild execution ledger"
```

### Task 2: Consolidate the shared UI shell and state language

**Files:**
- Modify: `prototype/scripts/ui_tokens.gd`
- Modify: `prototype/scripts/ui_theme.gd`
- Modify: `prototype/scripts/ui_shell.gd`
- Modify: `prototype/scripts/ui_anim.gd`
- Modify: `prototype/scripts/ui_feedback.gd`
- Modify: `prototype/docs/UI_STYLE_GUIDE.md`
- Test: `prototype/tests/test_ui_and_camera.gd` or the existing UI test entrypoint discovered by the implementer

**Interfaces:**
- Consumes: existing `UITokens`, `UITheme`, `UIShell`, `UIAnim`, and `UIFeedback` APIs.
- Produces: shared screen frame, navigation spine, panel/material roles, focus/hover/pressed/disabled states, and motion constants consumed by Main Menu, Lab, and Match Setup.

- [ ] **Step 1: Add failing checks for shared state semantics**

Cover that the shared shell exposes stable roles for primary action, secondary action, info, warning, error, disabled, selected, and active states; that every interactive control receives focus styling; and that animation values are centralized.

- [ ] **Step 2: Run the focused UI checks**

Run the project’s existing UI test command and record the expected failures before implementation.

- [ ] **Step 3: Implement the smallest shared contract**

Add typed helpers and token roles without changing gameplay data flow. Keep paint-pass values grouped and named so later asset passes can tune them without screen-script rewrites.

- [ ] **Step 4: Verify the shared contract**

Run the focused UI tests and the Godot headless editor validation; capture any warnings introduced by the new theme paths.

- [ ] **Step 5: Update the UI guide and commit**

Document the new ownership boundary and commit:

```powershell
git add prototype/scripts/ui_tokens.gd prototype/scripts/ui_theme.gd prototype/scripts/ui_shell.gd prototype/scripts/ui_anim.gd prototype/scripts/ui_feedback.gd prototype/docs/UI_STYLE_GUIDE.md prototype/tests
git commit -m "feat: establish industrial design UI shell contract"
```

### Task 3: Build the authored vector and raster asset kits

**Files:**
- Create/modify: `prototype/assets/ui/` vector and raster subdirectories selected by the implementer
- Modify: `prototype/scripts/ui_theme.gd` and `prototype/tools/build_ui_theme.gd`
- Test: asset manifest or existing UI audit entrypoint

**Interfaces:**
- Consumes: shared token/material roles from Task 2.
- Produces: bespoke navigation glyphs, slot/drag/drop/status marks, panel plates, workbench fields, wear/normal/detail textures, and a manifest consumed by the theme builder.

- [ ] **Step 1: Inventory existing assets and define replacement set**

Keep existing assets that pass the new direction; identify exact replacements for the highest-visibility defects rather than generating an unbounded asset library.

- [ ] **Step 2: Author vector states in Inkscape**

Create a consistent stroke/shape family for navigation, slots, selection, invalid placement, readiness, map markers, and blueprint status. Export SVGs with stable names and no hidden editor-only dependencies.

- [ ] **Step 3: Author raster/material plates**

Create reusable 9-slice plates and workbench textures with controlled normal/roughness detail. Keep textures subordinate to hierarchy and avoid decorative noise that competes with the operated object.

- [ ] **Step 4: Wire the asset manifest and rebuild the generated theme**

Update the theme builder and run:

```powershell
..\Godot_v4.7.1-stable_win64_console.exe --headless --path prototype --script tools/build_ui_theme.gd --quit-after 2
```

- [ ] **Step 5: Commit the asset kit**

```powershell
git add prototype/assets prototype/scripts/ui_theme.gd prototype/tools/build_ui_theme.gd prototype/resources/bomber_theme.tres
git commit -m "feat: add bespoke UI vector and material asset kit"
```

### Task 4: Rebuild Main Menu and Design Lab vertical slice

**Files:**
- Modify: `prototype/scripts/main_menu.gd`
- Modify: `prototype/scripts/module_placer.gd`
- Modify: relevant Design Lab scene files discovered from `MainLab.tscn`
- Modify: relevant radial and bottom-edge document/control scripts discovered by the implementer
- Test: existing Main Menu/Design Lab smoke and UI audit scripts

**Interfaces:**
- Consumes: Task 2 shell contract, Task 3 asset kit, existing showcase, radial, bottom-edge document, drag/drop, undo/redo, and clipping behavior.
- Produces: a playable, visually coherent Main Menu and Design Lab where the machine/work operation is the hero and gestures are visible at the point of use.

- [ ] **Step 1: Add focused regression coverage**

Cover destination navigation, radial open/close and selection, bottom-edge document visibility, selected-module state, invalid placement feedback, and preservation of undo/redo behavior.

- [ ] **Step 2: Recompose the Main Menu**

Replace dead space and weak bottom-only navigation with a clear destination hierarchy, a stronger showcase composition, and shared navigation/focus behavior. Keep the existing showcase data and tool props unless an authored replacement is required by the composition.

- [ ] **Step 3: Recompose the Design Lab**

Make the hull and active operation the visual anchor. Keep the radial and bottom-edge lab document concepts, but rebuild their material/texture/normal/structure presentation and add visible drag/orbit/pan/zoom/placement affordances.

- [ ] **Step 4: Run the vertical-slice validation**

Run the focused tests, Godot headless validation, and the project’s existing capture scripts for Main Menu and Main Lab. Record screenshots as playtest artifacts.

- [ ] **Step 5: Commit the playable slice**

```powershell
git add prototype/scripts/main_menu.gd prototype/scripts/module_placer.gd prototype/scenes prototype/scripts prototype/tests
git commit -m "feat: rebuild main menu and design lab visual slice"
```

### Task 5: Rebuild Match Setup information architecture and hero states

**Files:**
- Modify: `prototype/scripts/match_setup.gd`
- Modify: `prototype/scripts/roster_picker.gd`
- Modify: `prototype/scenes/MatchSetup.tscn`
- Test: existing Match Setup UI and stage-navigation tests

**Interfaces:**
- Consumes: Task 2 shared shell, Task 3 state assets, and Task 4 navigation conventions.
- Produces: intuitive Theatre/Roster/Launch navigation or unified console flow with clear progress, readiness, empty states, and return paths.

- [ ] **Step 1: Add failing state coverage**

Cover empty roster, populated roster, blocked launch, invalid drop, stage return, focus navigation, and narrow viewport layout.

- [ ] **Step 2: Choose and implement the clearest composition**

Retain the current data-driven stage model unless a unified console demonstrably improves task completion. Put selected map, roster, and launch readiness in the visual hierarchy; remove dead space and card clipping.

- [ ] **Step 3: Integrate bespoke state assets and motion**

Use the shared navigation spine, typography roles, state glyphs, and transitions. Keep map/roster data and launch semantics unchanged.

- [ ] **Step 4: Validate all Match Setup states**

Run focused tests, Godot headless validation, and captures for Theatre, Roster, Launch, empty, populated, blocked, and narrow states.

- [ ] **Step 5: Commit the Match Setup pass**

```powershell
git add prototype/scripts/match_setup.gd prototype/scripts/roster_picker.gd prototype/scenes/MatchSetup.tscn prototype/tests
git commit -m "feat: rebuild match setup visual flow"
```

### Task 6: Author Blender fixture and workbench prop kit

**Files:**
- Create/modify: `prototype/tools/blender/` authoring script(s)
- Create/modify: `prototype/assets/models/ui/` or the project’s existing UI prop destination
- Modify: `prototype/scripts/main_menu.gd` and relevant Lab/setup scripts for integration
- Test: Blender headless export plus Godot import validation

**Interfaces:**
- Consumes: the shared visual brief and Task 4/5 composition requirements.
- Produces: 6–12 high-visibility fixtures/controls with stable origins, normals, materials, and collision/render budgets.

- [ ] **Step 1: Define the prop manifest**

Select only props that improve the menu/Lab/setup hierarchy: console frame, control dial, document clamp, fixture rail, inspection lamp, tray/slot hardware, and comparable high-visibility elements.

- [ ] **Step 2: Add export validation to the Blender script**

Verify outward normals, forward-axis convention, stable object naming, bounded triangle counts, and material slot expectations before writing GLBs.

- [ ] **Step 3: Generate the prop kit headlessly**

Run the project’s Blender 5.2 command and export only the manifest set.

- [ ] **Step 4: Reimport through the root Godot binary**

Run the headless editor/import validation and inspect for orientation, material, and resource errors.

- [ ] **Step 5: Integrate and commit**

```powershell
git add prototype/tools/blender prototype/assets/models prototype/scripts
git commit -m "feat: add bespoke industrial UI fixture kit"
```

### Task 7: Typography, lighting, motion, and responsive state pass

**Files:**
- Modify: `prototype/scripts/ui_tokens.gd`, `prototype/scripts/ui_anim.gd`, `prototype/scripts/ui_theme.gd`
- Modify: `prototype/docs/RENDER_SETTINGS.md`
- Modify: relevant Main Menu, Lab, and Match Setup scripts/scenes
- Test: capture matrix and UI audit scripts

**Interfaces:**
- Consumes: all prior shared and screen-level assets.
- Produces: readable operational typography, responsive feedback, context-specific showcase/tactical lighting, and complete state coverage.

- [ ] **Step 1: Add the capture matrix**

Define captures for default, hover, focus, pressed, disabled, empty, populated, invalid-drop, blocked-launch, Armor Station, and narrow viewport.

- [ ] **Step 2: Tune typography hierarchy**

Use display faces only for display, increase dense operational sizes, and reserve mono treatment for numeric/telemetry values.

- [ ] **Step 3: Tune motion and lighting**

Keep responses immediate and restrained; make the operated object readable before atmosphere; distinguish showcase/Lab inspection lighting from battle readability without creating separate products.

- [ ] **Step 4: Run the complete capture matrix**

Run Godot headless/capture commands and store outputs in ignored playtest/capture paths.

- [ ] **Step 5: Commit the polish/state pass**

```powershell
git add prototype/scripts prototype/scenes prototype/docs/RENDER_SETTINGS.md prototype/tests
git commit -m "feat: complete UI readability and state pass"
```

### Task 8: Independent rendered review and playtest checkpoint

**Files:**
- Create: review package and playtest manifest in the plan ledger workspace
- Modify: only files required by review findings, through a bounded fix task

**Interfaces:**
- Consumes: the complete rebuilt UI and capture matrix.
- Produces: independent UX/visual verdict, corrected critical findings, and a reproducible playtest build/checkpoint.

- [ ] **Step 1: Render the default and primary-task flows**

Capture Main Menu → Design Lab → Match Setup and the primary design interaction at wide and narrow sizes.

- [ ] **Step 2: Dispatch independent UX review**

Use the retrieved `design-ux` skill. Score the rendered artifact against visibility, real-world match, control/freedom, consistency, error prevention/recovery, recognition, efficiency, aesthetic hierarchy, and help burden.

- [ ] **Step 3: Fix Critical/Important findings through one bounded worker**

The worker must rerun covering tests and regenerate affected captures.

- [ ] **Step 4: Run final validation**

Run all focused tests, the full available test suite, Godot headless editor validation, and the final capture matrix. Confirm no new parse errors, import failures, or layout overflow.

- [ ] **Step 5: Mark playtest-ready**

Record the commit SHA, launch command, known warnings, test results, and playtest focus questions in the ledger. Do not report “ready for playtest” until the independent review and final validation pass are complete.

---

## Model routing

- Task 1: fast model; mechanical setup.
- Task 2: high-capability model; shared API and design-system judgment.
- Task 3: mid-tier model with asset-authoring context; bounded files.
- Task 4: high-capability model; coupled UI interaction and composition.
- Task 5: standard model; multi-file flow integration.
- Task 6: mid-tier specialist; Blender geometry/export constraints.
- Task 7: standard model; cross-screen polish and capture coverage.
- Task 8: highest available model for independent final review; fast model for bounded fixes if findings are mechanical.
