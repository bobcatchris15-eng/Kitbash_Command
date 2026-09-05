# UI / menu architecture audit

## Scope and method

Read-only inventory on 2026-09-04. Evidence was collected with `rg` across
`prototype/scenes`, `prototype/scripts`, and `project.godot`, then by reading
the route table, scene roots, and constructing scripts named below. This maps
implemented player-facing surfaces; unimplemented labels are called out rather
than treated as screens.

## Player-facing surface map

| Surface | Owner(s) | Entry / exit and durable boundary |
|---|---|---|
| Front Desk / Main Menu | `scenes/MainMenu.tscn` -> `scripts/main_menu.gd` | `project.godot:19` starts here. `GROUPS` at `main_menu.gd:57` sends players to Skirmish, Operations, Proving Ground, Lab, Library, Hull/Block Hull builders, Terrain Sculpt, and tutorial; its explicit Livery action is at lines 749-750. Escape opens global SystemLayer. |
| Loading | `Loading.tscn` / `loading_screen.gd`, `LoadingPreview.tscn` / `loading_preview.gd` | `SceneRouter.change_scene_async()` is used only for warm MainLab/Battle routes (`scene_router.gd:64, 158-196`). |
| Skirmish setup | `MatchSetup.tscn` -> `match_setup.gd` | Four-stage map/rules/roster/launch wizard (`STAGES`, lines 85-93; stage builders 607/885/932). `OptionButton`s set difficulty/resources/AI; roster picker commits a `MatchRuleSet`, then Battle. Back returns Front Desk. |
| Operations setup and re-draft | `OperationsSetup.tscn` -> `operations_setup.gd`; `OperationsDraft.tscn` -> `operations_draft.gd` | Setup has theatre/staging/directives columns (144/177/231/284) and writes the rule set at launch (617). Battle completion routes to draft (`match_director.gd:2730`); draft deploys/abandons (272/278). |
| Proving Ground | `test_range_launcher.gd` -> `Battle.tscn` | Both Main Menu card and Lab launch it; launcher writes test-range `MatchRuleSet` and routes through router (test_range_launcher:107-114). SystemLayer returns to MainLab. |
| Design Lab | `MainLab.tscn` -> `module_placer.gd` | Instanced `UI_StatBlock` (`lab_document.gd`), `UI_PartsMenu` (`parts_menu.gd`), and hidden `UI_ArmorStationPanel` (`armor_station_panel.gd`); persistent model/blueprint nodes remain in scene. Toolbar is runtime `lab_toolbar.gd`; `drag_drop_manager.gd` drives placement. |
| Selected-module radial (retain) | `tweak_callout_manager.gd` -> `ui/module_action_ring.gd`, `ui/tweak_stations.gd`, `ui/radial_dial.gd`, `ui/radial_ammo_selector.gd` | The callout manager constructs the ring at line 48 and specialized radial selectors at 278/570/584. It is the module-selection manipulation/tweak interface and must remain. `ui_radial_menu.gd` is also used by `modular_hull_builder.gd` (1197), not the main Lab ring. |
| Lab sub-modes/dialogs | `lab_toolbar.gd`, `lab_document.gd`, `armor_station_panel.gd` | Paint Station swaps an in-scene environment and parts UI; Library and Main Menu use direct changes (`lab_toolbar:207,810`); save/load/name/compare menus and inspector sliders are built dynamically. |
| Blueprint Library | `BlueprintLibrary.tscn` -> `blueprint_library_screen.gd` | Runtime list/turntable/action footer; edit -> MainLab (641), test -> Battle via launcher (670), rename/delete use `ConfirmationDialog`/`LineEdit` (679+). Its own router preference is explicitly mixed with direct scene changes (254-261). |
| Livery | `Livery.tscn` -> `livery_screen.gd` | Main Menu-only direct entry. Runtime tabs cover colors, patterns, finishes, decals, presets, building styles (302-676), with `ColorPickerButton`, `OptionButton`, sliders, text, checkbox. Persists through `livery.gd`; not represented in `Navigation.ROUTES`. |
| Builder/tool scenes | `HullBuilder.tscn` -> `hull_builder.gd`; `ModularHullBuilder.tscn` -> `modular_hull_builder.gd`; `TerrainSculpt.tscn` -> `terrain_sculpt.gd` | All are Front Desk cards. Classic HullBuilder has authored CanvasLayer buttons/options; Hull and Modular builders directly return MainMenu (`hull_builder:2506`, `modular_hull_builder:2140`). Terrain route has no `Navigation` entry. |
| Tutorial | `TwoPhaseTutorialManager` autoload; `two_phase_tutorial_overlay.gd` | Menu tutorial starts phase one in Battle (manager:156), then routes phase two to Lab (183-185). Overlay is its own CanvasLayer above scenes. |
| Battle / match UI | `Battle.tscn` -> `battle/match_director.gd`; `hud/hud_root.gd` | Director builds one `HUDRoot` (match_director:5111-5176). HUDRoot constructs ribbon, alert log, minimap, production deck, command card, hint and hover tooltip (`hud_root:95-242`), and owns the only refresh clock (318+). |
| Battle overlays | `SystemLayer` autoload; `after_action_report.gd`; `battle/hud/admin_menu.gd`, `debug_overlay.gd`, perf HUD/toast; tutorial overlay | SystemLayer is Escape/pause/settings/leave (system_layer:39-302); after-action report is spawned at match_director:2655-56. Admin/debug/perf surfaces are developer/session support and attach to HUD column, not primary HUD regions. |

## Shared UI systems and exact seams

| System | Current ownership / callers | Replacement seam |
|---|---|---|
| Global theme and tokens | `ui_theme.gd`, `ui_tokens.gd`, project `bomber_theme.tres`; screens call `UITheme` and assign `theme_type_variation`. `UITheme.style_dropdown()` says its callers are setup screens at 319-328. | Retheme factory methods/Theme resource first; keep Godot control contracts and named variations (`PrimaryButton`, `DangerButton`, `TabButton`, `ListButton`) stable until callers migrate. |
| Out-of-match shell / chrome | `UIShell` factories (`workbench`, `screen_frame`, `action`, `stat_row`) used by Main Menu, Library, Livery, Operations Draft, After Action, settings/spec placard. 3D `UIPropStage`, `StampedButton`, `StampedLabel`, `MeshIcon` add hardware rendering. | Replace at `UIShell` and theme factories. The hardware layer is optional visually but has real button focus/hit targets underneath (`ui_stamped_button.gd:33-68`); do not replace it by removing native controls. |
| Dock/flyout/feedback/motion | `UIDock`, `UIFlyout`, `UIFeedback`, `UIAnim`; dock persists `user://ui_layout.cfg`; feedback wires BaseButton/SpinBox/focus descendants (ui_feedback:69-135). | Migrate these abstractions before individual screen bespoke panels. UIFlyout intentionally is not a Godot Popup (`ui_flyout.gd:20-25`), so preserve its input/position behavior if changing overlay implementation. |
| Forms | `OptionButton`, `SpinBox`, sliders, `LineEdit`, `CheckBox`, native `Button` created in Match/Operations setup, Livery, Lab document, Settings, Library dialogs. Exact setup fields: Match `difficulty_btn/resources_btn/ai_btn` at 102-104; Ops `difficulty_btn/engagements_spin` at 53-54; Livery fields at 23-24,63-82; settings option at 247. | Treat value-change signals and `MatchRuleSet`/livery/blueprint writes as the seam, not the drawn control. |
| Battle HUD (separate language) | `scripts/hud/hud_style.gd` plus region scripts (`hud_root` imports at 33-38); built from plain controls/SVG icons. | Replace `HUDRoot._build_layout()` region-by-region, retaining one instance and `attach_to_column()`. Do not route battle through `ui_tokens`/stamped 3D chrome: HUD deliberately does not use it. |
| Routing / transitions | `Navigation.ROUTES` gives intended hierarchy, `SceneRouter.goto()` is universal fade/load gate, but many scripts direct-call `change_scene_to_file`. | Centralize each direct caller on `Navigation.go`/`SceneRouter.goto` only after route entries cover Livery, ModularHullBuilder, TerrainSculpt, and all intended back contexts. |

## Duplicated, contradictory, and replacement-ready findings

1. **Route authority is split (high evidence).** `core/navigation.gd` describes itself as the route-table answer, but it omits Livery, ModularHullBuilder, and TerrainSculpt while Main Menu exposes all of them (`main_menu:57-123,749-750`). Lab toolbar, match director, builders, and Library use direct `change_scene_to_file` calls. This is a replacement seam, not a safe cosmetic-only change.
2. **Two Lab stat/control implementations coexist (high evidence).** `UI_StatBlock.tscn` still instances `lab_document.gd` and declares a right rail with Save/Test/Delete; `lab_document.gd` then dynamically builds a broader console with inspector/popups (1010+). `lab_toolbar.gd` builds another top bar and save/load/test affordances. Inventory before consolidating avoids breaking BlueprintManager's scene-root hooks.
3. **Two distinct radial implementations exist (high evidence).** Main Lab selected modules use `ModuleActionRing` via `TweakCalloutManager`; `UIRadialMenu` is used by ModularHullBuilder. Both share `ring_draw.gd`, but should not be conflated. Retain the main Lab selected-module radial interaction; any visual replacement needs an adapter at `tweak_callout_manager.gd`.
4. **HUD is a deliberate replacement boundary (high evidence).** It uses `hud_style.gd`, not `ui_theme/tokens`, and consolidates former duplicated minimap/production components by construction (`hud_root:95-242`). A new general UI system must leave this boundary intact until a deliberate HUD migration.
5. **Menu labels do not equal implemented screens (medium evidence).** SystemLayer builds SYSTEM/SETTINGS; `OBJECTIVES` only warns "not yet built" (`system_layer:302`). Main Menu exposes no Records surface despite descriptive project prose naming it. Do not assume those labels have callable surfaces.
6. **Developer overlays remain reachable in match construction (high evidence).** `match_director.gd` imports/builds DebugOverlay and perf HUD/toast alongside HUDRoot; `admin_menu.gd` still exists. They should be isolated from player-facing redesign acceptance and not reused as shipping navigation.

## Mechanically stable contracts during replacement

- Scene start/transition: MainMenu remains start scene; warm MainLab/Battle routing through `SceneRouter` keeps fade/loading behavior. Maintain the route flows listed above, including Operations -> Draft and test range -> Lab.
- Match state: setup/operations/test entry points must still create `MatchRuleSet` and assign it through `MatchConfig` before `Battle.tscn`; match director reads that single mode contract.
- Blueprint state: Lab's `BlueprintManager` serializes saved blueprints under `user://blueprints`; test-range scratch/pending-restore behavior must remain. Library edit/test/rename/delete actions must preserve their selected-entry identity.
- Retained interaction: selected-module radial action/tweak controls in the Design Lab remain reachable from `TweakCalloutManager`; preserve radial positioning around module, action callbacks, radial dials, and ammo/leg selectors.
- Battle composition: exactly one HUD region instance; refresh ownership stays in `HUDRoot._process`, and external overlays enter through `attach_to_column()`.

## Prioritized replacement sequence

1. Create a route inventory/adapter, add missing destinations, and replace direct scene-change callers while preserving setup and scratch contracts.
2. Stabilize shared control factories and variations (`UIShell`, `UITheme`, feedback) behind compatibility wrappers; inventory dynamic Lab controls.
3. Replace Front Desk, setup flows, Library, Livery, and settings forms using those wrappers; test each value/persistence route.
4. Refactor Lab chrome/rail/parts drawer around existing BlueprintManager and retain the selected-module radial via an adapter; do not remove radial family until callers are separately migrated.
5. Replace battle HUD independently, region by region, preserving `HUDRoot` layout/clock/column contracts; keep dev overlays out of scope.
6. Remove legacy/duplicate implementations only after every caller is migrated and routes/dialogs have a playtest pass.

