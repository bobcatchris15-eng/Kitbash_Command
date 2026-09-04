# Industrial Design UI Rebuild — Design Brief

**Status:** Draft for human review  
**Date:** 2026-09-04  
**Scope:** Main Menu, Design Lab, Match Setup, shared UI system, and bespoke visual assets

## Goal

Replace the current menu/UI presentation with a coherent, bespoke visual system for an industrial design simulator: tactile, responsive, modern, mechanically legible, and internally distinctive.

The prior “sincere miniature war theater versus absurd units” tone split is superseded. Humor remains welcome in naming, presentation, configuration, and especially absurd weapon sounds, but no visual surface is required to perform a tonal binary.

## Governing principles

1. **Industrial design simulator first.** The player should feel they are operating a design bureau, not navigating a genre skin.
2. **Mechanics must be visible.** A part communicates its role through geometry, attachment, motion, material, sound, and live stat response.
3. **Polished kitbash.** Strange combinations are intentional; accidental-looking joins, floating parts, and unexplained visual noise are defects.
4. **Tactility serves operation.** Physical cues, pressed states, radial controls, contextual panels, and motion shorten the path from intent to action.
5. **Legibility outranks atmosphere.** Selection, ownership, damage, affordability, invalid placement, and readiness must read immediately.
6. **Expression comes from parameters.** Continuous edits and live feedback matter as much as choosing parts.
7. **Internal distinctiveness.** The project’s own construction grammar, control behavior, materials, typography, and state language are authoritative. External references are historical inspiration only.
8. **Humor is optional expression, not a global constraint.** Absurd audio remains a deliberate isolated channel; it does not dictate the visual tone of the interface or world.

## System layers

### Layer 1 — Governing language

Owns the principles above, the definition of “industrial design simulator,” the relationship between operator, machine, and interface, and the acceptance tests. This belongs in `docs/design/CORE_DESIGN_LANGUAGE.md`.

### Layer 2 — Domain translations

- `prototype/docs/UI_STYLE_GUIDE.md`: UI tokens, components, typography, interaction states, motion, and responsive layout.
- `docs/design/VISUAL_ART_DIRECTION.md`: machine construction, materials, faction/team/readability coding, terrain, and authored asset rules.
- `prototype/docs/RENDER_SETTINGS.md`: Godot rendering implementation and performance rationale only.

These documents may interpret the governing language for their domain, but must not redefine its tone.

### Layer 3 — Paint pass

Exact colors, texture frequencies, roughness values, shader mechanisms, lighting energies, DOF distances, transition durations, icon shapes, and individual prop designs are tunable implementation choices. They must be labeled as current values or experiments, not permanent identity.

## Navigation and information architecture

Clonkers may revise the existing navigation and screen hierarchy. The flow must remain discoverable and preserve the project’s functional loop:

- **Main Menu:** clear destinations and a strong vehicle/design showcase.
- **Design Lab:** the machine and active operation are the visual hero; menus, radials, and the bottom-edge lab document remain core interaction patterns, but are rebuilt with clearer affordances and stronger material/texture/normal/structure treatment.
- **Match Setup:** Theatre, Roster, and Launch may become a unified console or another clearer composition if the user can still understand progress, return freely, and see readiness.
- **Shared navigation spine:** all screens share destination hierarchy, focus treatment, transition language, and state semantics.

Existing functionality is substrate, not a layout mandate. Rework is allowed when it improves intuition, response, or visual hierarchy without hiding core operations.

## Bespoke asset program

- **Godot/UI:** shared shell, component states, layout, accessibility/readability, input affordances, and integration.
- **Blender:** a small high-visibility fixture/console/workbench kit; no expansion of the vehicle catalog is implied.
- **GIMP/raster:** authored plate, field, workbench, wear, and material textures with reusable tiling/9-slice rules.
- **Inkscape/vector:** navigation glyphs, slot states, drag/drop indicators, warnings, map markers, blueprint marks, and other crisp state assets.
- **Typography:** use the existing font inventory deliberately; reserve display faces for display, and give operational data enough size and contrast.
- **Motion/lighting:** responsive control feedback, restrained transitions, clear selection/readiness lighting, and context-specific showcase versus tactical lighting.

## Retained foundations

The rebuild should reuse and evolve `ui_shell.gd`, `ui_theme.gd`, `ui_tokens.gd`, `ui_anim.gd`, `ui_feedback.gd`, existing specialized controls, the current Design Lab radial/document concepts, and the data-driven Match Setup flow where they remain structurally sound.

## Acceptance tests

- A first-time user can identify the primary action and current mode without an instruction wall.
- Menu, Lab, and Match Setup feel like one product through shared geometry, typography, state semantics, focus behavior, and transitions.
- A fresh observer can identify a module’s role, attachment, moving mechanism, and current state without explanatory prose.
- Valid kitbash assemblies look intentionally manufactured; no floating, pasted, or unexplained construction artifacts remain.
- Selection, ownership, damage, affordability, invalid placement, and launch readiness remain legible at tested viewport sizes and zoom levels.
- Design Lab edits visibly connect geometry changes to live stat changes.
- Radials remain usable with mouse, keyboard, and gamepad paths where supported; item counts and animation do not undermine selection speed.
- Empty, populated, hover, focus, pressed, disabled, invalid-drop, blocked-launch, and narrow-viewport states are authored and captured.
- Independent rendered UX/visual review is performed after each major surface pass; fixes are re-rendered and re-reviewed.
- Each durable principle has one owner document. Paint-pass values are marked as tunable. Superseded references are visibly archived.

## Out of scope for this brief

- Rebalancing combat, economy, or unit mechanics.
- Replacing the absurd weapon-sound program.
- Importing an external visual identity or copying a third-party asset pack.
- Expanding the full vehicle/weapon model catalog.
