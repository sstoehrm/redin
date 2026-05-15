# Archived implementation plans

The files in this directory are **historical implementation plans** that were used while building a feature. They are *not* maintained as current documentation.

A plan in here may reference:

- Source paths that have since moved (e.g. `src/host/...` instead of `src/cmd/redin/` + `src/redin/`).
- Runtime CLI flags that no longer exist (e.g. `--dev`, `--profile`, `--track-mem`). These are now compile-time flags (`-define:REDIN_DEV=true`, etc.).
- Endpoint shapes or APIs that have since changed.

When in doubt, treat the code, [`CLAUDE.md`](../../../CLAUDE.md), and the maintained references under [`docs/`](../..) as the source of truth. Use these plans only as background reading for *why* a feature was built the way it was.
