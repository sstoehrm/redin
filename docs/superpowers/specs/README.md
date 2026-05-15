# Archived design specs

The files in this directory are **historical design specs** that fed the corresponding implementation plans in [`../plans/`](../plans/). They are *not* maintained as current documentation.

A spec in here may reference:

- Source paths that have since moved (e.g. `src/host/...` instead of `src/cmd/redin/` + `src/redin/`).
- Runtime CLI flags that no longer exist (e.g. `--dev`, `--profile`, `--track-mem`). These are now compile-time flags (`-define:REDIN_DEV=true`, etc.).
- Endpoint shapes, attribute names, or APIs that have since evolved.

When in doubt, treat the code, [`CLAUDE.md`](../../../CLAUDE.md), and the maintained references under [`docs/`](../..) as the source of truth. Use these specs only as background reading for *why* a feature was designed the way it was.
