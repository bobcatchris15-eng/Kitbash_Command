# Current Work

## Objective

Establish a replacement-ready direction for Kitbash Command's entire UI and
menu architecture. Preserve the Design Lab module-selection radial interaction
as a pattern, while treating all other UI and menu infrastructure as open to
redesign.

## Current Status

The investigations are complete and validated. The durable evidence is in:

- `tasks/ui-current-architecture-audit/AUDIT.md`
- `tasks/ui-current-architecture-audit/receipt.json`
- `tasks/ui-novel-interface-research/receipt.json`
- `UI_REPLACEMENT_DIRECTION.md`

Recommended direction: use **Command Constellation** for the global shell,
**Anatomy Bench** for the Design Lab, and **War Thread** for Operations. The
selected-module radial remains a retained interaction grammar, restyled as a
diagnostic halo in the lab.

## Active Autonomous Slice

Three isolated, AGY-backed tasks are running under the 2026-09-04 handoff:

- `blueprint-library-visibility`
- `main-menu-full-units`
- `match-setup-roster-preview`

Each has a task-local receipt/state file. Integration is forbidden until its
receipt validates; independent native adversarial review follows any meaningful
structural delta.

## Constraints

- Keep existing `.clanker/` task evidence and receipts.
- Do not checkpoint while the shared working tree is dirty with unrelated work.
- Use the current Graphify graph and baseline digest before requesting an
  adversarial review.
- Hold implementation dispatches until the user supplies the remaining desired
  changes. Once released, prefer AGY Gemini 3.8 Flash Medium Clinkers for
  suitable bounded offloads and use native Clinkers in parallel for independent
  work where that adds useful coverage.
- Held repair scope gathered since the UI direction review:
  - Blueprint Library: prevent the first preview model from occluding the
    design list.
  - Main Menu: rotate only complete units, never bare hulls.
  - Match Setup roster: equalize unit/harvester/defence scroller sizing and
    replace the flat-grey preview ground with a materialled environment.
  - Match Setup launch preview: make all twelve units visible and stage them in
    a motor-pool or unload-zone turntable environment.
- Inject suitable specialist skills into dispatched Clinkers: Godot GDScript,
  Godot UI Control, Blender, GIMP, game UI/UX, and game-design fundamentals.
