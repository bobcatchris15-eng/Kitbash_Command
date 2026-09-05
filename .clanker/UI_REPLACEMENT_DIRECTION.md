# UI Replacement Direction

## Decision

Do not reskin the existing screens into prettier forms. Replace their visible
interaction model with a single premise: commands should be manipulated as
physical things in the war room, service bay, and campaign intelligence wall.

Use three related but purpose-specific surfaces:

| Scope | Direction | Primary interaction |
|---|---|---|
| Global navigation | Command Constellation | Navigate physical stations around the active chassis; push a selected mission wafer down a launch rail. |
| Design Lab | Anatomy Bench | Pull compatible parts toward real sockets; understand constraints as vehicle diagnostics. |
| Operations | War Thread | Pull an operation's intelligence thread through a dispatch slot after staging roster dog-tags. |

The retained Design Lab module radial is not optional. Preserve its module-local
attachment, fast directional commit, held explanation, and generous dead-zone
cancel. Re-present it as a diagnostic halo that visibly connects the selected
part to its mass, power, firing arc, and compatibility state.

## Why this is the recommendation

- It abandons menus as the dominant metaphor without making every decision an
  opaque cinematic sequence.
- Each surface uses direct manipulation suited to its domain rather than
  forcing the same sidebar/forms pattern everywhere.
- It is replacement-ready while preserving the current game's mechanical
  contracts: `MatchRuleSet` handoff, blueprint persistence, placement/clipping,
  and the selected-module radial callbacks.

## Architecture constraints from the audit

1. Create a route adapter first. Current transition authority is split among
   `Navigation`, `SceneRouter`, and direct scene changes.
2. Preserve all setup-to-Battle paths that construct a `MatchRuleSet` and set
   `MatchConfig` before Battle loads.
3. Treat `BlueprintManager` persistence and scratch/pending restoration as
   back-end contracts; new surfaces may replace only their presentation.
4. Keep the in-match HUD as an independent subsystem during the first pass.
   It deliberately has its own layout/refresh rules and should not be folded
   into out-of-match UI tokens.
5. Do not confuse the Design Lab `ModuleActionRing` with the separate
   `UIRadialMenu` used by Modular Hull Builder.

## Migration order

1. **Navigation seam** — add one route adapter and make existing routes call it;
   preserve all current scenes as fallback.
2. **Vertical slice: Operations** — build a War Thread proof of interaction
   against current itinerary/difficulty/Begin Operation behavior. This gives
   a contained, high-value test without touching Battle or blueprint authoring.
3. **Vertical slice: Lab** — build the Anatomy Bench overlay for one part
   category, projecting existing sockets, clipping, and the retained radial.
4. **Global shell** — replace the main menu with Command Constellation only
   after destinations have a unified route adapter.
5. **Then migrate library, livery, setup, and settings** into the same
   physical-object grammar; delete legacy UI only after playtesting and
   keyboard/controller accessibility checks.
6. **HUD last** — evolve one region at a time under its existing HUDRoot
   constraints.

## Evidence

- Full current-system audit: `tasks/ui-current-architecture-audit/AUDIT.md`
- Independent interaction research and source links:
  `tasks/ui-novel-interface-research/receipt.json`
- Keyframes were generated as review-only concept renders on 2026-09-04.

