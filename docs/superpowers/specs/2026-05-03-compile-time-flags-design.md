# Compile-time flags for dev / profile / track-mem

**Status:** design  
**Date:** 2026-05-03  
**Track:** developer ergonomics + release hygiene

## Goal

Convert the runtime CLI flags `--dev`, `--profile`, and `--track-mem`
into compile-time `-define` constants, matching the existing
`REDIN_AGENT` pattern. Bare `odin build` produces a release-stripped
binary; `./build-dev.sh` produces a debug binary with all three
features compiled in.

## Why

- **Strip dev surface from release builds.** Today the dev server,
  hot reload, frame-timing ring buffer, and tracking allocator are
  always compiled in; only their *activation* is gated by a runtime
  flag. The HTTP listener thread, file watcher, port/token files, and
  every `profile.begin / .end` call site live in the release binary.
  Compile-time gating removes them entirely from binaries that don't
  need them.
- **Zero runtime cost for stripped features.** `when` blocks at the
  call sites collapse to nothing, so the layout/render hot path
  doesn't pay even an unused-branch cost.
- **Consistency.** `REDIN_AGENT` already uses `#config(...) + when` to
  ship zero agent code in default builds. The new flags follow the
  same shape, so there's one mental model for "feature gated by build
  flag" across the framework.
- **Security posture.** A release binary that physically lacks the
  dev-server listener can't be tricked into starting it.

## Surface

### New compile-time constants

Declared in `src/redin/bridge/bridge.odin` next to `REDIN_AGENT`:

```odin
REDIN_DEV       :: #config(REDIN_DEV, false)
REDIN_PROFILE   :: #config(REDIN_PROFILE, false)
REDIN_TRACK_MEM :: #config(REDIN_TRACK_MEM, false)
```

All default `false`. Enable per-feature with `-define:REDIN_DEV=true`
etc., or in bulk via `./build-dev.sh`.

### CLI flags removed

`--dev`, `--profile`, `--track-mem` are removed from `src/cmd/redin/main.odin`.
The first non-flag argv stays as the app file (e.g., `./redin main.fnl`).

### `redin.Config` shrinks

```odin
// before
Config :: struct { app: string, dev: bool, profile: bool }

// after
Config :: struct { app: string }
```

Public API change for `--native` projects.

## Per-package code changes

### `src/cmd/redin/main.odin`

- Drop arg parsing for `--dev`, `--profile`, `--track-mem`.
- Wrap the tracker setup in `when bridge.REDIN_TRACK_MEM { ... }` so
  the `mem.Tracking_Allocator`, the `context.allocator =` hoist
  (added in #108), and the deferred leak dump are absent in non-track
  builds.
- The arg loop becomes: `for arg in os.args[1:] do cfg.app = arg`.

### `src/redin/runtime.odin`

- `Config` struct: drop `dev` and `profile`.
- `run()`: drop `cfg.dev` / `cfg.profile` references.
- `profile.init(cfg.profile)` → `profile.init()`.
- `canvas.set_dev_mode(cfg.dev)` → `canvas.set_dev_mode()`,
  internally reading `bridge.REDIN_DEV`. If the proc collapses to a
  no-op outside dev, remove it entirely and inline a `when` block at
  any call site that survives.
- `bridge.init(&b, cfg.dev)` → `bridge.init(&b)`.

### `src/redin/bridge/`

- `Bridge.dev_mode` field removed.
- `bridge.init` signature: drop the `dev_mode bool` parameter.
- `bridge.destroy`'s `needs_listener := b.dev_mode || REDIN_AGENT`
  becomes `needs_listener := REDIN_DEV || REDIN_AGENT`.
- All `if b.dev_mode { ... }` becomes `when REDIN_DEV { ... }` so the
  listener thread, hot-reload watcher, port/token file lifecycle, and
  dev-only HTTP handler set are stripped from release binaries.
- Existing `when REDIN_AGENT { ... }` branches remain unchanged. The
  combined gate `REDIN_DEV || REDIN_AGENT` keeps the listener
  available when either flag is set.

### `src/redin/profile/`

- `profile.init(profile bool)` → `profile.init()`.
- Every public proc (`begin_frame`, `end_frame`, `begin`, `end`,
  `draw_overlay`) wraps its body in `when REDIN_PROFILE { ... }`.
  Callers in `runtime.run` stay unchanged — this preserves the call
  sites and avoids sprinkling `when` blocks across the per-frame loop.
- The `/profile` HTTP endpoint and the F3 overlay toggle are gated by
  `when REDIN_PROFILE` so they're absent in non-profile builds.

### `src/redin/canvas/`

- `set_dev_mode(b: bool)` → `set_dev_mode()` reading `bridge.REDIN_DEV`,
  *or* removed entirely if its only effect is a `when REDIN_DEV` at
  the use sites. Pick the option that leaves fewer dead args at the
  end of the implementation.

## `./build-dev.sh`

New script at the repo root:

```bash
#!/usr/bin/env bash
set -e
exec odin build src/cmd/redin \
    -collection:lib=lib -collection:luajit=vendor/luajit \
    -define:REDIN_DEV=true \
    -define:REDIN_PROFILE=true \
    -define:REDIN_TRACK_MEM=true \
    -out:build/redin "$@"
```

`"$@"` forwards extra flags so the agent test job can run
`./build-dev.sh -define:REDIN_AGENT=true` without duplicating the
debug-flag list.

## Test + CI integration

- `test/ui/run-all.sh`: replace its inline `odin build` with
  `./build-dev.sh`. The dev server is mandatory for the integration
  suite, so this build is correct for testing.
- `.github/workflows/test.yml`: same swap.
- `.github/workflows/release.yml` / `release.sh`: switch to
  `./build-dev.sh`. The redin binary in the release tarball is a dev
  tool — its target audience (LLM/AI workflow drivers) needs the dev
  server. The "stripped release binary" remains a `bare odin build`
  away for `--native` users who want it for shipping their own apps.
- `scripts/smoke-native.sh` inlines its own copies of the
  `app.odin` and `build.sh` templates that mirror redin-cli's
  `app-odin-fnl` / `build-sh-native` constants (per the
  redin-maintenance skill's parity rule). Update both inline copies
  alongside the redin-cli constants so the smoke check exercises the
  same defaults a fresh `--native` project would.

## redin-cli template parity

Per `redin-maintenance/SKILL.md`'s parity rule (`app-odin-fnl` and
`build-sh-native` constants in redin-cli must mirror the in-tree
templates), this PR's coordinated update covers:

- `redin-cli`'s `build-sh-native` constant: add the three
  `-define:REDIN_*=true` flags as the default for new `--native`
  projects.
- `redin-cli`'s `app-odin-fnl` constant: drop any references to
  `cfg.dev` / `cfg.profile`. Native projects parse `os.args` for
  their app file only; debug features are compile-time.

The `redin-cli` change ships in the same release bump as this PR.

## Documentation updates

Same commit (or adjacent commits in the same PR):

- `CLAUDE.md` — Building, Running, Dev server sections.
- `docs/core-api.md` — `--dev`, `--profile`, `--track-mem`
  references → "compile with `-define:REDIN_DEV=true`".
- `docs/reference/dev-server.md` — gating model.
- `docs/reference/native-bridge.md` — note that `--native` `build.sh`
  needs the flags for development.
- `.claude/skills/redin-dev/SKILL.md` — Running, Dev server sections.
- `.claude/skills/redin-maintenance/SKILL.md` — Build, UI tests,
  `--track-mem`, agent build sections (multiple call sites).

## Migration / breaking changes

Atomic in this PR; called out in the PR description and any release
notes:

- `./redin --dev main.fnl` no longer recognises `--dev`. The first
  argv becomes the app path, so `--dev` is treated as a missing file.
- `redin.Config.dev` and `.profile` fields removed. `--native`
  projects that set these fail to compile until updated.
- `bridge.init`, `profile.init`, possibly `canvas.set_dev_mode` lose
  their bool parameters.

No deprecation period — the runtime flags map cleanly onto compile
flags, and we'd rather take the breakage in a single PR than carry
two parallel control surfaces. PR description includes a one-line
migration recipe for each affected user.

## Out of scope

- Changing `REDIN_AGENT`'s shape or default.
- Adding new debug features (memory snapshot endpoint, etc.).
- Refactoring the profile package's API beyond removing the bool
  parameter.
- Refactoring the canvas package's dev-mode mechanism beyond
  collapsing the bool parameter.
- A `make`-based or task-runner build system. `./build-dev.sh` is the
  ergonomic floor; anything richer is a separate decision.
- Cross-compilation flag matrices.

## Verification

- `odin build src/cmd/redin -collection:lib=lib -collection:luajit=vendor/luajit -out:build/redin`
  produces a release binary; running it with no `.redin-port` /
  `.redin-token` files appearing confirms the dev server is absent.
- `./build-dev.sh && ./build/redin --dev …` — wait, `--dev` is gone:
  `./build-dev.sh && ./build/redin examples/kitchen-sink.fnl` should
  start the dev server because `REDIN_DEV` was baked in.
- Strip check: `nm build/redin | grep -ci 'devserver_\|hotreload_'`
  should be 0 for a release build, non-zero for a `./build-dev.sh`
  build.
- All Fennel runtime tests pass.
- `bash test/ui/run-all.sh --headless` passes after switching to
  `./build-dev.sh`.
- `--track-mem`-style verification: a `./build-dev.sh` binary still
  reports tracker stats on graceful shutdown (the tracker is now
  baked into dev builds, no flag needed). A bare-`odin build` binary
  has no tracker overhead.
