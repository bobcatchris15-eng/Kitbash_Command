# Human Handoff — 2026-09-04

## Source evidence (verbatim)

> "In the blueprint library, the actual list of designs isn't visible, just the first-loaded preview model over everything"
>
> "The main menu preview turntable includes bare hulls in the rotation, it should be full units only."
>
> "In the Roster picker, the units and the harvester / defence scrollboxes aren't the same size. And the background should have a texture / normal map / albedo map to it, just a flat grey plane is not great."
>
> "On the launch screen for the skirmish, it only shows seven of the twelve units in preview. That preview window can get some props too, look like a motor pool or unload zone surrounding the turntable."
>
> "Take the tasks i've given you, and engage autoclankery, sticking rigorously to the protocol."

## Boundaries

- Implement the four stated repairs only. Do not begin the broader UI replacement initiative.
- Use AGY `gemini-3.8-flash-medium` for implementation and native agents only for independent validation.
- Preserve the Design Lab selected-module radial; it is out of scope.
- No deploys, dependencies, destructive operations, or whole-worktree checkpoint commits.

## Spend and wake ceilings

- At most three concurrent implementation tasks and one final review.
- One AGY implementation pass per task; no retry without a new receipt finding.
- This is a single bounded autonomous run. `.clanker/HALT` stops dispatch.
