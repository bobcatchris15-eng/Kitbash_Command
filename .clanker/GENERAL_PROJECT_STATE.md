# General Project State

## Current

- Kitbash Command is a Godot 4.7.1 RTS prototype rooted at `prototype/`.
- Graphify is the structural-knowledge backend. Its current graph is
  `graphify-out/graph.json`; baseline digest: `d9aedbd28459b841`.
- Routine verification is a targeted Godot parse check plus an area-specific
  `tools/probe_*.gd`; there is no unit-test suite.
- The working tree contains uncommitted work from several areas. Treat it as
  user-owned unless a task explicitly names the affected paths.

## Durable Constraints

- Use a task-local state file and receipt for every dispatched bounded task.
- Do not use the Clanker checkpoint command while unrelated worktree changes
  are present: it stages the entire tree before committing.
- The bundled Clanker Bash tools cannot run on this Windows host because its
  `bash.exe` has no installed Linux shell. Python graph-delta and task-state
  validation remain available directly; PowerShell-native enforcement wrappers
  are deferred pending a user decision.

## Evidence

- Current graph: `graphify-out/graph.json` (refreshed 2026-09-04).
- Prior Clanker migration: `.clanker/receipts/2026-09-03-clanker-migration.json`.
- Legacy state preserved in `.clanker/state.json`; pre-migration instructions
  remain in `.clanker/history/AGENTS.pre-clanker-migration.md`.
