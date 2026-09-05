# Clanker State

This directory stores durable Clanker Fleet state for Kitbash Command.

- `state.json` records the active protocol and discovered worker backends.
- `history/` preserves pre-migration material that was not already protected by Git history.
- `receipts/` records migrations and other state-changing operations.
- `logs/` is reserved for worker and orchestration logs.

Historical evidence must be retained across future schema migrations whenever compatible.
