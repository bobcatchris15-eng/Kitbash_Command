task_id: blueprint-library-visibility
objective: Fix Blueprint Library so the design list remains visible and usable; the first-loaded 3D preview model must be clipped to its preview region and never paint over the list.
acceptance:
- Preview is constrained to a dedicated visual bounds region, with clipping/layering proven by inspection.
- Design list remains visible and receives input after preview loads.
- Existing blueprint selection, preview, and Test in Arena behavior remain.
- Targeted Godot compile check passes.
- Produce a patch relative to the supplied initial snapshot; do not commit or modify the primary worktree.
artifacts:
- prototype/scripts/blueprint_library_screen.gd
- prototype/scenes/BlueprintLibrary.tscn (only if necessary)
- .clanker/tasks/blueprint-library-visibility/initial-blueprint_library_screen.gd
constraints:
- Preserve pre-existing edits in the snapshot. No new dependencies or UI redesign.
- Write receipt/state/patch only under the root task directory.
authority: May modify only this task worktree's Blueprint Library files and task evidence; may not commit, alter locks, or touch the primary worktree.
returns: C:/Users/Chris/.codex/skills/clanker-mode/contracts/clinker-receipt.schema.json
budget: Gemini 3.8 Flash Medium, one pass, 20 minutes.
