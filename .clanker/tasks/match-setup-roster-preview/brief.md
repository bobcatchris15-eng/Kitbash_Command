task_id: match-setup-roster-preview
objective: Repair Match Setup roster-panel parity and launch preview staging: make unit, harvester, and defence scrollboxes visually equivalent; replace flat grey ground with a materialled motor-pool/unload-zone turntable; and ensure all twelve roster unit preview positions are visible.
acceptance:
- Unit/harvester/defence source-panel sizing follows one shared sizing rule.
- Preview ground has actual albedo plus normal/texture material depth, not a uniform grey plane.
- Preview layout creates twelve unit positions and has no seven-unit cap; overflow is spatially arranged, not dropped.
- Local props evoke a restrained motor pool/unload zone without obstructing units or external downloads.
- Existing roster selection, drag/drop, and MatchRuleSet launch handoff remain.
- Targeted Godot compile check and relevant probe pass.
- Commit only scoped task changes to the task branch and record the commit SHA.
artifacts:
- prototype/scripts/match_setup.gd
- prototype/scenes/MatchSetup.tscn (only if necessary)
- related local preview helpers/assets only if necessary
constraints:
- Maintain War Room Ops-Table language. No external downloads, packages, persistence/schema changes, or battle logic changes.
- Consult Godot UI Control, GDScript, Blender material/camera references when relevant.
authority: May modify only files needed for this task in the task worktree and task receipt/state; do not alter Operations Setup or Blueprint Library.
returns: C:/Users/Chris/.codex/skills/clanker-mode/contracts/clinker-receipt.schema.json
budget: Gemini 3.8 Flash Medium, one pass, 35 minutes.
