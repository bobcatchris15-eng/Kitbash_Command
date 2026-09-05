task_id: main-menu-full-units
objective: Make the main-menu preview turntable rotate complete reconstructed units only; bare hull records must never be admitted as showcase entries.
acceptance:
- Showcase candidate source filters or constructs only complete units.
- Turntable operates and skips invalid candidates safely.
- Focused probe or equivalent source-backed validation demonstrates no bare hull candidate is eligible.
- Targeted Godot compile check passes.
- Commit only scoped task changes to the task branch and record the commit SHA.
artifacts:
- prototype/scripts/main_menu.gd
- prototype/tools/probe_main_menu_showcase.gd (if updating/using an existing probe)
constraints:
- Do not change blueprint persistence, menu routes, or other showcase styling.
authority: May modify only scoped files in the task worktree and task receipt/state.
returns: C:/Users/Chris/.codex/skills/clanker-mode/contracts/clinker-receipt.schema.json
budget: Gemini 3.8 Flash Medium, one pass, 20 minutes.
