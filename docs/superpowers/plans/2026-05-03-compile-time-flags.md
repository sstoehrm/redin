# Compile-time flags for dev / profile / track-mem — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Convert the runtime CLI flags `--dev`, `--profile`, and `--track-mem` into compile-time `-define` constants matching the existing `REDIN_AGENT` pattern, so release binaries strip the dev server, profile instrumentation, and tracking allocator to zero bytes.

**Architecture:** Each feature gets a `#config(REDIN_*, false)` constant declared in the package(s) that consume it. Bodies of the gated procs live inside `when REDIN_* { ... }` blocks. CLI flag parsing is removed; the `redin.Config` struct shrinks to `{app: string}`. A new top-level `./build-dev.sh` bakes in all three flags for the everyday dev workflow. Bare `odin build` stays as the release-stripped path.

**Tech Stack:** Odin (`#config` + `when`), bash (`./build-dev.sh`), GitHub Actions (workflows), Babashka (test scripts unchanged), no new dependencies.

**Spec:** `docs/superpowers/specs/2026-05-03-compile-time-flags-design.md`

---

## File Structure

**Modified:**

- `src/redin/bridge/bridge.odin` — add `REDIN_DEV` constant (next to existing `REDIN_AGENT`), drop `Bridge.dev_mode` field, drop `dev_mode` parameter from `init`, replace `if dev_mode || REDIN_AGENT` patterns with `when REDIN_DEV || REDIN_AGENT`
- `src/redin/bridge/devserver.odin` — wrap `devserver_init`/`destroy`/`poll` callers' guard logic at use sites (already `when REDIN_AGENT`-aware in places)
- `src/redin/canvas/canvas.odin` — declare `REDIN_DEV`, drop `g_dev_mode` + `set_dev_mode`, replace `if g_dev_mode` with `when REDIN_DEV`
- `src/redin/profile/profile.odin` — declare `REDIN_PROFILE`, replace `init(bool)` body with `when REDIN_PROFILE`-gated initialization, gate every public proc's body in `when REDIN_PROFILE`
- `src/redin/profile/overlay.odin` — gate body in `when REDIN_PROFILE`
- `src/redin/runtime.odin` — drop `Config.dev` and `Config.profile` fields, drop `canvas.set_dev_mode` call, simplify `bridge.init` and `profile.init` calls
- `src/cmd/redin/main.odin` — declare `REDIN_TRACK_MEM`, drop `--dev` / `--profile` / `--track-mem` arg parsing, wrap tracker setup in `when REDIN_TRACK_MEM`
- `test/ui/run-all.sh` — call `./build-dev.sh` instead of inline `odin build`, drop `--dev` from binary invocation
- `.github/workflows/test.yml` — same swap; agent test job uses `./build-dev.sh -define:REDIN_AGENT=true`
- `.github/workflows/release.yml` — main build uses `./build-dev.sh`; agent build appends `-define:REDIN_AGENT=true`
- `release.sh` — call `./build-dev.sh`
- `scripts/smoke-native.sh` — update inline `app.odin` template (drop `cfg.dev`), update inline `build.sh` template (add `-define:REDIN_DEV=true` etc.), drop `--dev` from binary invocation
- `CLAUDE.md` — Building, Running, Dev server sections
- `docs/core-api.md` — `--dev` / `--profile` / `--track-mem` references
- `docs/reference/dev-server.md` — gating model
- `docs/reference/native-bridge.md` — `Config.dev` reference
- `.claude/skills/redin-dev/SKILL.md` — Running, Dev server, native scaffold sections
- `.claude/skills/redin-maintenance/SKILL.md` — Build, UI tests, `--track-mem`, agent build sections

**Created:**

- `build-dev.sh` — top-level script that wraps `odin build` with the three `-define` flags; forwards `"$@"` for additional flags

**Deleted:** none.

---

### Task 1: Add `REDIN_DEV`, `REDIN_PROFILE`, `REDIN_TRACK_MEM` constants

**Files:**
- Modify: `src/redin/bridge/bridge.odin:1-7` (add `REDIN_DEV` next to `REDIN_AGENT`)
- Modify: `src/redin/canvas/canvas.odin:1-12` (add `REDIN_DEV` declaration)
- Modify: `src/redin/profile/profile.odin:1-7` (add `REDIN_PROFILE`)
- Modify: `src/cmd/redin/main.odin:1-7` (add `REDIN_TRACK_MEM`)

These declarations are no-ops (they don't gate any code yet). Adding them first lets every later task reference the constant from its package without a separate "introduce constant" step.

- [ ] **Step 1: Add `REDIN_DEV` to bridge package**

Open `src/redin/bridge/bridge.odin`. The file starts with:

```odin
package bridge

// Compile-time flag enabling the agent channel feature. Default is false;
// set with `odin build ... -define:REDIN_AGENT=true`. When false, the
// agent endpoints, walker, and listener-gate widening all compile out
// to zero bytes.
REDIN_AGENT :: #config(REDIN_AGENT, false)
```

Add after the `REDIN_AGENT` line:

```odin
// Compile-time flag enabling the dev server, hot reload, and dev-only
// canvas warnings. Default is false; set with `odin build ... -define:REDIN_DEV=true`
// (or use `./build-dev.sh`). When false, the listener thread, file watcher,
// port/token files, and dev-only HTTP handlers compile out to zero bytes.
REDIN_DEV :: #config(REDIN_DEV, false)
```

- [ ] **Step 2: Add `REDIN_DEV` to canvas package**

Open `src/redin/canvas/canvas.odin`. The file starts with:

```odin
// src/redin/canvas/canvas.odin
package canvas

import "core:fmt"
import rl "vendor:raylib"
```

Add after the `package canvas` line (before imports):

```odin
// src/redin/canvas/canvas.odin
package canvas

// Same compile-time flag declared in bridge — Odin's `#config` reads
// the same -define value regardless of which package declares it, so
// this stays in lockstep without a cross-package import.
REDIN_DEV :: #config(REDIN_DEV, false)

import "core:fmt"
import rl "vendor:raylib"
```

- [ ] **Step 3: Add `REDIN_PROFILE` to profile package**

Open `src/redin/profile/profile.odin`. The file starts with:

```odin
package profile

import "core:sync"
import "core:time"
```

Insert the constant declaration:

```odin
package profile

// Compile-time flag enabling frame-timing instrumentation, the F3
// overlay, and the /profile HTTP endpoint. Default is false; set with
// `odin build ... -define:REDIN_PROFILE=true`. When false, every public
// proc body in this package compiles out to zero bytes.
REDIN_PROFILE :: #config(REDIN_PROFILE, false)

import "core:sync"
import "core:time"
```

- [ ] **Step 4: Add `REDIN_TRACK_MEM` to main**

Open `src/cmd/redin/main.odin`. The file starts with:

```odin
package main

import "core:fmt"
import "core:mem"
import "core:os"
import redin "../../redin"
```

Insert the constant declaration:

```odin
package main

// Compile-time flag enabling the tracking allocator. Default is false;
// set with `odin build ... -define:REDIN_TRACK_MEM=true`. When false,
// the tracker setup and leak dump compile out to zero bytes.
REDIN_TRACK_MEM :: #config(REDIN_TRACK_MEM, false)

import "core:fmt"
import "core:mem"
import "core:os"
import redin "../../redin"
```

- [ ] **Step 5: Verify build**

Run:

```bash
odin build src/cmd/redin -collection:lib=lib -collection:luajit=vendor/luajit -out:build/redin
```

Expected: clean build, no output. The constants are declared but unused yet.

- [ ] **Step 6: Commit**

```bash
git add src/redin/bridge/bridge.odin src/redin/canvas/canvas.odin \
        src/redin/profile/profile.odin src/cmd/redin/main.odin
git commit -m "$(cat <<'EOF'
feat(config): declare REDIN_DEV / REDIN_PROFILE / REDIN_TRACK_MEM constants

Foundation for converting --dev / --profile / --track-mem CLI flags to
compile-time -define constants. These declarations are no-ops on their
own; subsequent commits gate code paths behind `when` blocks reading
these flags. Same shape as the existing REDIN_AGENT pattern.
EOF
)"
```

---

### Task 2: Create `./build-dev.sh`

**Files:**
- Create: `build-dev.sh`

The dev binary becomes a one-line script. Tests in later tasks switch to it; without it, removing the runtime CLI flags would leave us unable to build a dev binary.

- [ ] **Step 1: Write the script**

Create `build-dev.sh`:

```bash
#!/usr/bin/env bash
# build-dev.sh — build the redin binary with all dev features compiled in.
#
# This is the everyday dev build. The release-stripped variant is just
# `odin build src/cmd/redin -collection:lib=lib -collection:luajit=vendor/luajit -out:build/redin`
# without any -define flags.
#
# Forwards "$@" so callers can append extra flags, e.g.:
#   ./build-dev.sh -define:REDIN_AGENT=true     # dev + agent channel
#   ./build-dev.sh -o:speed                     # optimized dev build
set -e
exec odin build src/cmd/redin \
    -collection:lib=lib -collection:luajit=vendor/luajit \
    -define:REDIN_DEV=true \
    -define:REDIN_PROFILE=true \
    -define:REDIN_TRACK_MEM=true \
    -out:build/redin "$@"
```

- [ ] **Step 2: Make executable**

```bash
chmod +x build-dev.sh
```

- [ ] **Step 3: Run it to verify it builds equivalently**

```bash
./build-dev.sh
```

Expected: clean build, no output. Resulting `build/redin` behaves identically to the previous release binary because the constants don't gate anything yet.

- [ ] **Step 4: Commit**

```bash
git add build-dev.sh
git commit -m "$(cat <<'EOF'
feat(build): add ./build-dev.sh for the everyday dev binary

One-line wrapper around `odin build` that bakes in REDIN_DEV / REDIN_PROFILE
/ REDIN_TRACK_MEM. Forwards "$@" so callers can append extra flags
(REDIN_AGENT, optimization level, etc.). Bare `odin build` stays as the
release-stripped path.
EOF
)"
```

---

### Task 3: Migrate canvas package's dev gate

**Files:**
- Modify: `src/redin/canvas/canvas.odin:29-36, 38-46`
- Modify: `src/redin/runtime.odin:156`

The canvas package logs a warning when `register` is called with a duplicate name. The warning is suppressed unless `g_dev_mode` is true. Replace the runtime bool with a compile-time `when REDIN_DEV` gate, then drop `set_dev_mode` and its caller.

- [ ] **Step 1: Replace `g_dev_mode` + `set_dev_mode` with `when REDIN_DEV`**

In `src/redin/canvas/canvas.odin`, find:

```odin
@(private = "file")
g_dev_mode: bool

// Toggle dev-mode warnings. Called by redin.run; user code shouldn't need
// this directly.
set_dev_mode :: proc(dev: bool) {
	g_dev_mode = dev
}

register :: proc(name: string, provider: Canvas_Provider) {
	if existing, ok := entries[name]; ok {
		if g_dev_mode {
			fmt.eprintfln("redin: warn: canvas.register(%q) replaces an existing provider", name)
		}
		if existing.provider.stop != nil {
			existing.provider.stop()
		}
	}
```

Replace with:

```odin
register :: proc(name: string, provider: Canvas_Provider) {
	if existing, ok := entries[name]; ok {
		when REDIN_DEV {
			fmt.eprintfln("redin: warn: canvas.register(%q) replaces an existing provider", name)
		}
		if existing.provider.stop != nil {
			existing.provider.stop()
		}
	}
```

The `g_dev_mode` variable, the `set_dev_mode` proc, and the `@(private = "file")` line above `g_dev_mode` all go.

- [ ] **Step 2: Drop the `canvas.set_dev_mode` caller**

In `src/redin/runtime.odin`, find around line 156:

```odin
	canvas.set_dev_mode(cfg.dev)
```

Delete the line entirely. The line above (`profile.init(cfg.profile)`) stays for now; Task 4 handles it.

- [ ] **Step 3: Verify build**

```bash
odin build src/cmd/redin -collection:lib=lib -collection:luajit=vendor/luajit -out:build/redin
```

Expected: clean build. Without `-define:REDIN_DEV=true`, the canvas warning compiles out — the `fmt` import is still in use elsewhere in the file (`fmt.eprintfln` is still present in the `when` block), so no import errors.

- [ ] **Step 4: Run UI tests**

```bash
./build-dev.sh
bash test/ui/run-all.sh --headless
```

Expected: all suites pass. Canvas test exercises `register` so this proves the warning still fires in dev builds.

- [ ] **Step 5: Commit**

```bash
git add src/redin/canvas/canvas.odin src/redin/runtime.odin
git commit -m "$(cat <<'EOF'
feat(canvas): gate duplicate-register warning on REDIN_DEV at compile time

Drop the runtime g_dev_mode bool and set_dev_mode proc. The duplicate-name
warning is now wrapped in `when REDIN_DEV { ... }` so release builds
strip the warning entirely and runtime.run no longer threads cfg.dev
into the canvas package.
EOF
)"
```

---

### Task 4: Migrate profile package to `REDIN_PROFILE`

**Files:**
- Modify: `src/redin/profile/profile.odin:29, 40-85`
- Modify: `src/redin/profile/overlay.odin` (entire body)
- Modify: `src/redin/runtime.odin:154`

Today `profile.init(true)` flips the runtime `enabled_flag`; every begin/end checks it and bails. After this task the bool parameter goes, `enabled_flag` becomes a compile-time-gated initialization, and every public proc body lives inside `when REDIN_PROFILE`.

- [ ] **Step 1: Drop `enabled_flag`, gate proc bodies on `REDIN_PROFILE`**

In `src/redin/profile/profile.odin`, find:

```odin
@(private) enabled_flag: bool
@(private) visible_flag: bool
@(private) ring:         Ring
@(private) snapshot_mu:  sync.Mutex
```

Replace with:

```odin
@(private) visible_flag: bool
@(private) ring:         Ring
@(private) snapshot_mu:  sync.Mutex
```

Then find:

```odin
is_enabled :: proc() -> bool { return enabled_flag }

overlay_visible :: proc() -> bool { return visible_flag }
set_overlay_visible :: proc(v: bool) { visible_flag = v }

init :: proc(enabled: bool) {
    enabled_flag = enabled
    visible_flag = enabled
    ring = {}
    frame_start = {}
    phase_scratch = {}
}

begin_frame :: proc() {
    if !enabled_flag do return
    frame_start = time.tick_now()
    phase_scratch = {}
}

end_frame :: proc() {
    if !enabled_flag do return
    total := time.tick_diff(frame_start, time.tick_now())
```

Replace with:

```odin
is_enabled :: proc() -> bool {
    when REDIN_PROFILE { return true }
    return false
}

overlay_visible :: proc() -> bool { return visible_flag }
set_overlay_visible :: proc(v: bool) { visible_flag = v }

init :: proc() {
    when REDIN_PROFILE {
        visible_flag = true
        ring = {}
        frame_start = {}
        phase_scratch = {}
    }
}

begin_frame :: proc() {
    when !REDIN_PROFILE do return
    frame_start = time.tick_now()
    phase_scratch = {}
}

end_frame :: proc() {
    when !REDIN_PROFILE do return
    total := time.tick_diff(frame_start, time.tick_now())
```

Then find:

```odin
begin :: proc(p: Phase) -> Scope {
    if !enabled_flag do return Scope{}
    return Scope{phase = p, start = time.tick_now(), live = true}
}

end :: proc(s: Scope) {
    if !s.live do return
    phase_scratch[s.phase] += i64(time.tick_diff(s.start, time.tick_now()))
}
```

Replace with:

```odin
begin :: proc(p: Phase) -> Scope {
    when !REDIN_PROFILE do return Scope{}
    return Scope{phase = p, start = time.tick_now(), live = true}
}

end :: proc(s: Scope) {
    when !REDIN_PROFILE do return
    if !s.live do return
    phase_scratch[s.phase] += i64(time.tick_diff(s.start, time.tick_now()))
}
```

The `Scope.live` field stays — it's the per-call gate that already correctly distinguishes a real Scope from the zero-valued no-op return.

- [ ] **Step 2: Gate `overlay.odin`**

Open `src/redin/profile/overlay.odin`. Read the full file:

```bash
cat src/redin/profile/overlay.odin
```

Wrap the body of any `draw_overlay` (or similarly named) proc in `when REDIN_PROFILE { ... }`. If the file declares helpers used only by the overlay, leave them — Odin doesn't error on unused private procs in non-test builds. The goal is that calls from `runtime.odin` collapse to no-ops in release builds.

Concretely, for each public proc declared in `overlay.odin`, add at the top of its body:

```odin
when !REDIN_PROFILE do return
```

If a proc returns a non-default value (e.g., `bool`), use a `when REDIN_PROFILE { ... }` wrapper around the whole body and a `return false` (or zero-value) outside.

- [ ] **Step 3: Update `profile.init` caller in runtime.odin**

In `src/redin/runtime.odin`, find:

```odin
	profile.init(cfg.profile)
```

Replace with:

```odin
	profile.init()
```

- [ ] **Step 4: Verify build**

```bash
odin build src/cmd/redin -collection:lib=lib -collection:luajit=vendor/luajit -out:build/redin
```

Expected: clean build (release variant; profile gates compile out).

```bash
./build-dev.sh
```

Expected: clean build (dev variant; profile compiled in).

- [ ] **Step 5: Run UI tests**

```bash
bash test/ui/run-all.sh --headless
```

Expected: all suites pass. The `test_profile.bb` suite specifically exercises the profile path — it must build redin via `./build-dev.sh` (the run-all.sh swap happens in Task 6, but for this verification step run the suite manually so REDIN_PROFILE is on for the profile test).

If `test_profile.bb` fails because run-all.sh still calls plain `odin build`, override the `BINARY` it sees by editing run-all.sh's `BINARY=...` line locally for this verification only — Task 6 finalizes the swap.

- [ ] **Step 6: Run profile package's own tests**

```bash
odin test src/redin/profile -collection:lib=lib -collection:luajit=vendor/luajit -define:REDIN_PROFILE=true -define:ODIN_TEST_THREADS=1
```

Expected: all profile_test.odin tests pass when `REDIN_PROFILE=true`.

```bash
odin test src/redin/profile -collection:lib=lib -collection:luajit=vendor/luajit -define:ODIN_TEST_THREADS=1
```

Expected: tests still pass (they assert no-op behavior when REDIN_PROFILE is off, OR they fail gracefully — read the test file first; if any test assumes `init(true)`, mark it `when REDIN_PROFILE` only). If a test fails because it expects runtime-enabled profiling without the define, gate that test with `when REDIN_PROFILE { ... }` around its body.

- [ ] **Step 7: Commit**

```bash
git add src/redin/profile/profile.odin src/redin/profile/overlay.odin src/redin/runtime.odin
git commit -m "$(cat <<'EOF'
feat(profile): gate package on REDIN_PROFILE at compile time

Drop the runtime enabled_flag and the bool parameter from profile.init.
Every public proc body is now wrapped in `when REDIN_PROFILE { ... }`,
so release builds strip the ring buffer, frame instrumentation, and
overlay rendering to zero bytes. Callers in runtime.run stay unchanged.
EOF
)"
```

---

### Task 5: Migrate bridge package's `dev_mode`

**Files:**
- Modify: `src/redin/bridge/bridge.odin:25-46, 51-54, 97-156`
- Modify: `src/redin/runtime.odin:159`

The bridge holds a runtime `dev_mode` bool. After this task the field is gone, the parameter is gone, and every guard that today reads `b.dev_mode || REDIN_AGENT` reads `REDIN_DEV || REDIN_AGENT` at compile time.

- [ ] **Step 1: Drop `Bridge.dev_mode` field**

In `src/redin/bridge/bridge.odin`, find the `Bridge` struct ending:

```odin
	frame_changed:   bool,
	dev_mode:        bool,
}
```

Replace with:

```odin
	frame_changed:   bool,
}
```

- [ ] **Step 2: Drop `dev_mode` parameter from `init`**

In the same file, find:

```odin
init :: proc(b: ^Bridge, dev_mode: bool) {
	g_bridge = b
	g_context = context
	b.dev_mode = dev_mode
	http_client_init(&b.http_client)
```

Replace with:

```odin
init :: proc(b: ^Bridge) {
	g_bridge = b
	g_context = context
	http_client_init(&b.http_client)
```

Then find further down in `init`:

```odin
	needs_listener := dev_mode
	when REDIN_AGENT {
		needs_listener = true
	}
	if needs_listener {
		devserver_init(&b.dev_server, b)
	}
	if dev_mode {
		hotreload_init(&b.hot_reload)
	}
}
```

Replace with:

```odin
	when REDIN_DEV || REDIN_AGENT {
		devserver_init(&b.dev_server, b)
	}
	when REDIN_DEV {
		hotreload_init(&b.hot_reload)
	}
}
```

- [ ] **Step 3: Update `destroy`, `poll_devserver`, `is_shutdown_requested`, `check_hotreload`**

In the same file, find `destroy`:

```odin
destroy :: proc(b: ^Bridge) {
	needs_listener := b.dev_mode
	when REDIN_AGENT {
		needs_listener = true
	}
	if needs_listener {
		devserver_destroy(&b.dev_server)
	}
	if b.dev_mode {
		hotreload_destroy(&b.hot_reload)
	}
```

Replace the gating block with:

```odin
destroy :: proc(b: ^Bridge) {
	when REDIN_DEV || REDIN_AGENT {
		devserver_destroy(&b.dev_server)
	}
	when REDIN_DEV {
		hotreload_destroy(&b.hot_reload)
	}
```

Find `poll_devserver`:

```odin
poll_devserver :: proc(b: ^Bridge, events: ^[dynamic]types.InputEvent, node_rects: []rl.Rectangle) {
	needs_poll := b.dev_mode
	when REDIN_AGENT {
		needs_poll = true
	}
	if !needs_poll do return
	b.dev_server.current_rects = node_rects
	devserver_poll(&b.dev_server)
	devserver_drain_events(&b.dev_server, events)
	b.dev_server.current_rects = nil
}
```

Replace with:

```odin
poll_devserver :: proc(b: ^Bridge, events: ^[dynamic]types.InputEvent, node_rects: []rl.Rectangle) {
	when !(REDIN_DEV || REDIN_AGENT) do return
	b.dev_server.current_rects = node_rects
	devserver_poll(&b.dev_server)
	devserver_drain_events(&b.dev_server, events)
	b.dev_server.current_rects = nil
}
```

Find `is_shutdown_requested`:

```odin
is_shutdown_requested :: proc(b: ^Bridge) -> bool {
	needs_listener := b.dev_mode
	when REDIN_AGENT {
		needs_listener = true
	}
	return needs_listener && b.dev_server.shutdown_requested
}
```

Replace with:

```odin
is_shutdown_requested :: proc(b: ^Bridge) -> bool {
	when REDIN_DEV || REDIN_AGENT {
		return b.dev_server.shutdown_requested
	}
	return false
}
```

Find `check_hotreload`:

```odin
check_hotreload :: proc(b: ^Bridge) {
	if !b.dev_mode do return
	if hotreload_check(&b.hot_reload) {
		hotreload_execute(b)
		b.frame_changed = true
	}
}
```

Replace with:

```odin
check_hotreload :: proc(b: ^Bridge) {
	when !REDIN_DEV do return
	if hotreload_check(&b.hot_reload) {
		hotreload_execute(b)
		b.frame_changed = true
	}
}
```

- [ ] **Step 4: Sweep for remaining `b.dev_mode` references**

Run:

```bash
grep -rn "b\.dev_mode\|dev_mode:" src/redin/
```

Expected: zero results. If anything remains (e.g., another consumer in input/ or runtime/), replace it with the same `when REDIN_DEV { ... }` pattern. The struct field is gone, so any leftover reference is a compile error anyway.

- [ ] **Step 5: Update `bridge.init` caller**

In `src/redin/runtime.odin`, find:

```odin
	bridge.init(&b, cfg.dev)
```

Replace with:

```odin
	bridge.init(&b)
```

- [ ] **Step 6: Verify both build flavors**

```bash
odin build src/cmd/redin -collection:lib=lib -collection:luajit=vendor/luajit -out:build/redin
```

Expected: clean build (release; dev server stripped).

```bash
./build-dev.sh
```

Expected: clean build (dev; dev server compiled in).

- [ ] **Step 7: Smoke test the dev variant**

```bash
./build-dev.sh
DISPLAY= xvfb-run -a ./build/redin test/ui/markdown_app.fnl &
disown
until [ -f .redin-port ] && [ -f .redin-token ]; do sleep 0.2; done
echo "dev server up — port=$(cat .redin-port)"
PORT=$(cat .redin-port); TOKEN=$(cat .redin-token)
curl -s -X POST -H "Authorization: Bearer $TOKEN" "http://localhost:$PORT/shutdown" > /dev/null
sleep 1
```

Expected: `.redin-port` / `.redin-token` appear, the curl shutdown succeeds. Note: the binary is invoked WITHOUT `--dev` because the runtime CLI flag still exists and would still be accepted as a no-op (the flag goes in Task 7); we omit it here to confirm the dev server starts purely from compile-time gating.

- [ ] **Step 8: Smoke test the release variant has no dev server**

```bash
odin build src/cmd/redin -collection:lib=lib -collection:luajit=vendor/luajit -out:build/redin
DISPLAY= xvfb-run -a ./build/redin test/ui/markdown_app.fnl &
PID=$!
disown
sleep 2
ls .redin-port .redin-token 2>&1
kill -9 $PID 2>/dev/null || true
```

Expected: `.redin-port` / `.redin-token` do NOT appear (release binary has no dev server). The `ls` lines should both report "No such file or directory".

- [ ] **Step 9: Commit**

```bash
git add src/redin/bridge/bridge.odin src/redin/runtime.odin
git commit -m "$(cat <<'EOF'
feat(bridge): gate dev_mode on REDIN_DEV at compile time

Drop Bridge.dev_mode field, drop the bool parameter from bridge.init.
Every guard that read `b.dev_mode || REDIN_AGENT` now reads
`REDIN_DEV || REDIN_AGENT` at compile time, and the dev-only branches
in destroy / poll_devserver / is_shutdown_requested / check_hotreload
move from `if` to `when`. Release builds strip the listener thread,
hot-reload watcher, and dev HTTP handlers entirely.
EOF
)"
```

---

### Task 6: Update `test/ui/run-all.sh` to use `./build-dev.sh`

**Files:**
- Modify: `test/ui/run-all.sh:46-49, 92-95`

The test suite needs the dev server. After Task 5 the dev server is gated on `REDIN_DEV`, which only `./build-dev.sh` enables. Switch run-all.sh now (BEFORE removing the `--dev` CLI flag in Task 7), so that today's `--dev` argv is already irrelevant.

- [ ] **Step 1: Replace inline `odin build` with `./build-dev.sh`**

In `test/ui/run-all.sh`, find lines 46-49:

```bash
# Build
echo "=== Building redin ==="
odin build "$ROOT_DIR/src/cmd/redin" -collection:lib="$ROOT_DIR/lib" -collection:luajit="$ROOT_DIR/vendor/luajit" -out:"$BINARY"
echo ""
```

Replace with:

```bash
# Build
echo "=== Building redin ==="
( cd "$ROOT_DIR" && ./build-dev.sh )
echo ""
```

The `( cd … && … )` subshell ensures `./build-dev.sh` runs from the repo root regardless of where the test was invoked from.

- [ ] **Step 2: Drop `--dev` from the binary invocation**

Find line 94:

```bash
  "${LAUNCHER[@]}" "$BINARY" --dev "${extra_flags[@]}" "$app_file" &
```

Replace with:

```bash
  "${LAUNCHER[@]}" "$BINARY" "${extra_flags[@]}" "$app_file" &
```

The dev binary now starts the dev server purely because it was compiled with `REDIN_DEV=true` — no runtime flag needed.

- [ ] **Step 3: Verify the suite still runs**

```bash
bash test/ui/run-all.sh --headless
```

Expected: `=== Building redin ===` shows `./build-dev.sh` runs (will be silent on success), then every test suite passes. The `test_profile.bb` suite in particular validates that `REDIN_PROFILE=true` is now baked into the test binary.

- [ ] **Step 4: Commit**

```bash
git add test/ui/run-all.sh
git commit -m "$(cat <<'EOF'
test(ui): build via ./build-dev.sh and drop --dev argv from invocations

run-all.sh now calls ./build-dev.sh (which bakes in REDIN_DEV /
REDIN_PROFILE / REDIN_TRACK_MEM) and starts the binary with no --dev
flag. The dev server starts purely from the compile-time gate.
Prepares the suite for the upcoming removal of the --dev CLI flag.
EOF
)"
```

---

### Task 7: Drop `Config.dev` / `Config.profile` + CLI flag parsing + tracker hoist

**Files:**
- Modify: `src/redin/runtime.odin:16-20, 153-155`
- Modify: `src/cmd/redin/main.odin` (entire file)

After this task the binary no longer recognises `--dev`, `--profile`, or `--track-mem`. Order matters: run-all.sh has already been updated (Task 6), so removing the runtime parsing won't break the integration suite.

- [ ] **Step 1: Shrink the `Config` struct**

In `src/redin/runtime.odin`, find:

```odin
Config :: struct {
	app:     string,
	dev:     bool,
	profile: bool,
}
```

Replace with:

```odin
Config :: struct {
	app: string,
}
```

- [ ] **Step 2: Drop `cfg.dev` references in run() docstring**

In the same file, find:

```odin
// Block until the window closes or `request_shutdown` is called. Sets up
// the window, bridge, and dev server (if cfg.dev), then runs the loop.
//
// Per-frame call order:
//   poll_input -> on_input(filter) -> bridge tick -> on_frame -> render
```

Replace with:

```odin
// Block until the window closes or `request_shutdown` is called. Sets up
// the window, bridge, and dev server (when built with -define:REDIN_DEV=true),
// then runs the loop.
//
// Per-frame call order:
//   poll_input -> on_input(filter) -> bridge tick -> on_frame -> render
```

- [ ] **Step 3: Verify runtime.odin builds**

```bash
./build-dev.sh
```

Expected: clean build. Confirms `cfg.dev` and `cfg.profile` are no longer referenced anywhere in the redin package (callers were already updated in Tasks 3-5).

- [ ] **Step 4: Rewrite `src/cmd/redin/main.odin`**

Replace the entire file with:

```odin
package main

// Compile-time flag enabling the tracking allocator. Default is false;
// set with `odin build ... -define:REDIN_TRACK_MEM=true`. When false,
// the tracker setup and leak dump compile out to zero bytes.
REDIN_TRACK_MEM :: #config(REDIN_TRACK_MEM, false)

import "core:fmt"
import "core:mem"
import "core:os"
import redin "../../redin"

main :: proc() {
	cfg: redin.Config
	for arg in os.args[1:] {
		cfg.app = arg
	}

	when REDIN_TRACK_MEM {
		track: mem.Tracking_Allocator
		mem.tracking_allocator_init(&track, context.allocator)
		fmt.eprintln("Memory tracking enabled (REDIN_TRACK_MEM)")
		// Assign at proc scope. Odin's `context` is block-scoped: setting
		// context.allocator inside a `when` block reverts when the block
		// ends, so the tracker would never reach `redin.run`. Hoisting
		// the assignment out of the conditional fixes it.
		context.allocator = mem.tracking_allocator(&track)
		defer {
			if len(track.allocation_map) > 0 {
				fmt.eprintf("=== %v allocations not freed: ===\n", len(track.allocation_map))
				for _, entry in track.allocation_map {
					fmt.eprintf("- %v bytes @ %v\n", entry.size, entry.location)
				}
			}
			if len(track.bad_free_array) > 0 {
				fmt.eprintf("=== %v incorrect frees: ===\n", len(track.bad_free_array))
				for entry in track.bad_free_array {
					fmt.eprintf("- %p @ %v\n", entry.memory, entry.location)
				}
			}
			mem.tracking_allocator_destroy(&track)
		}
	}

	redin.run(cfg)
}
```

Note: `when REDIN_TRACK_MEM` wraps the entire tracker block — `track`, the init, the `context.allocator =` hoist, and the `defer`. When the flag is off, the entire block compiles out and `mem` becomes unused (which Odin doesn't error on for top-level imports). If `fmt` ends up unused too in non-track builds, that's also fine — Odin doesn't error on unused imports.

The assignment loop `for arg in os.args[1:] { cfg.app = arg }` keeps the existing semantic that the LAST non-flag argv wins (matches today's behavior).

- [ ] **Step 5: Verify both build flavors**

```bash
odin build src/cmd/redin -collection:lib=lib -collection:luajit=vendor/luajit -out:build/redin
```

Expected: clean release build.

```bash
./build-dev.sh
```

Expected: clean dev build.

- [ ] **Step 6: Verify behavior**

```bash
./build-dev.sh
DISPLAY= xvfb-run -a ./build/redin test/ui/markdown_app.fnl &
disown
until [ -f .redin-port ] && [ -f .redin-token ]; do sleep 0.2; done
echo "dev binary started server"
PORT=$(cat .redin-port); TOKEN=$(cat .redin-token)
curl -s -X POST -H "Authorization: Bearer $TOKEN" "http://localhost:$PORT/shutdown" > /dev/null
sleep 1
```

Expected: dev server comes up. Then run the same test against a release binary:

```bash
odin build src/cmd/redin -collection:lib=lib -collection:luajit=vendor/luajit -out:build/redin
DISPLAY= xvfb-run -a ./build/redin test/ui/markdown_app.fnl &
PID=$!
disown
sleep 2
ls .redin-port .redin-token 2>&1
kill -9 $PID 2>/dev/null || true
```

Expected: release binary does NOT create `.redin-port` / `.redin-token`.

- [ ] **Step 7: Verify track-mem behavior**

```bash
./build-dev.sh
DISPLAY= xvfb-run -a ./build/redin test/ui/markdown_app.fnl > /tmp/track.log 2>&1 &
disown
until [ -f .redin-port ] && [ -f .redin-token ]; do sleep 0.2; done
sleep 1
PORT=$(cat .redin-port); TOKEN=$(cat .redin-token)
curl -s -X POST -H "Authorization: Bearer $TOKEN" "http://localhost:$PORT/shutdown" > /dev/null
sleep 2
grep "Memory tracking enabled" /tmp/track.log
```

Expected: "Memory tracking enabled (REDIN_TRACK_MEM)" line appears (dev binary has REDIN_TRACK_MEM baked in, so the tracker is active without any runtime flag).

- [ ] **Step 8: Run the full UI suite**

```bash
bash test/ui/run-all.sh --headless
```

Expected: all suites pass.

- [ ] **Step 9: Commit**

```bash
git add src/redin/runtime.odin src/cmd/redin/main.odin
git commit -m "$(cat <<'EOF'
feat(cli): drop --dev / --profile / --track-mem CLI flags

Removes the runtime CLI flag parsing and the cfg.dev / cfg.profile
fields on redin.Config (now {app: string} only). All three features
are now gated purely by their compile-time -define constants. The
tracker setup is wrapped in `when REDIN_TRACK_MEM { ... }` so
release builds strip both the allocator and the leak-dump defer.

BREAKING CHANGE: `./redin --dev main.fnl` no longer recognises --dev;
the argv is treated as a missing file path. Use `./build-dev.sh`
to produce a binary with the dev server compiled in (then run it
without --dev). --native projects' app.odin must drop cfg.dev and
cfg.profile assignments.
EOF
)"
```

---

### Task 8: Update CI workflows (`test.yml`, `release.yml`)

**Files:**
- Modify: `.github/workflows/test.yml:39, 67-71`
- Modify: `.github/workflows/release.yml:48, 51, 99-100, 151, 158`

CI builds need to switch to `./build-dev.sh` for the test job and the release tarball (the redin binary in the release tarball is itself a dev tool — its target audience needs the dev server). The agent build appends `-define:REDIN_AGENT=true` to `./build-dev.sh "$@"`.

- [ ] **Step 1: Update `test.yml` main build**

In `.github/workflows/test.yml`, find around line 38:

```yaml
      - name: Build redin
        run: |
          mkdir -p build
          odin build src/cmd/redin -collection:lib=lib -collection:luajit=vendor/luajit -out:build/redin
```

Replace with:

```yaml
      - name: Build redin
        run: |
          mkdir -p build
          ./build-dev.sh
```

- [ ] **Step 2: Update `test.yml` agent build**

In the same file, find around line 67-71:

```yaml
      - name: Build redin (REDIN_AGENT=true)
        run: |
          mkdir -p build
          odin build src/cmd/redin -collection:lib=lib -collection:luajit=vendor/luajit \
            -define:REDIN_AGENT=true -out:build/redin
```

Replace with:

```yaml
      - name: Build redin (REDIN_AGENT=true)
        run: |
          mkdir -p build
          ./build-dev.sh -define:REDIN_AGENT=true
```

- [ ] **Step 3: Update `release.yml` test-step build**

In `.github/workflows/release.yml`, find around line 44-48:

```yaml
      - name: Run tests
        run: |
          luajit test/lua/runner.lua test/lua/test_*.fnl
          mkdir -p build
          odin build src/cmd/redin -collection:lib=lib -collection:luajit=vendor/luajit -out:build/redin
```

Replace with:

```yaml
      - name: Run tests
        run: |
          luajit test/lua/runner.lua test/lua/test_*.fnl
          mkdir -p build
          ./build-dev.sh
```

- [ ] **Step 4: Update `release.yml` release-binary build**

In the same file, find around line 50-51:

```yaml
      - name: Build release binary
        run: odin build src/cmd/redin -collection:lib=lib -collection:luajit=vendor/luajit -out:build/redin -o:speed
```

Replace with:

```yaml
      - name: Build release binary
        run: ./build-dev.sh -o:speed
```

The redin binary in the tarball needs the dev server (its consumers run AI-driven workflows that depend on it). `-o:speed` is forwarded via `"$@"`.

- [ ] **Step 5: Update `release.yml` agent build**

In the same file, find around line 95-100:

```yaml
      - name: Build agent binary
        run: |
          rm -rf dist-agent
          mkdir -p dist-agent
          odin build src/cmd/redin -collection:lib=lib -collection:luajit=vendor/luajit \
            -define:REDIN_AGENT=true -out:dist-agent/redin -o:speed
```

Replace with:

```yaml
      - name: Build agent binary
        run: |
          rm -rf dist-agent
          mkdir -p dist-agent
          ./build-dev.sh -define:REDIN_AGENT=true -o:speed -out:dist-agent/redin
```

`./build-dev.sh` accepts a trailing `-out:` because `"$@"` is passed AFTER the script's hard-coded `-out:build/redin`, so the second `-out:` overrides. Verify this assumption by reading the script: `-out:build/redin "$@"` means the second `-out:` from `"$@"` overrides. Test locally:

```bash
./build-dev.sh -out:build/redin-test
ls build/redin-test
```

Expected: `build/redin-test` exists. Delete it:

```bash
rm build/redin-test
```

- [ ] **Step 6: Update the release-notes "What's included" block**

In `release.yml` around lines 147-159:

```yaml
          body: |
            ## What's included
            - `redin` binary (Linux x86_64, LuaJIT statically linked)
            - AOT-compiled Fennel runtime
            - Fennel compiler (for --dev mode hot reload)
            - Developer documentation (guides + reference)
            - Claude Code skill for redin development

            ## Quick start
            ```
            redin-cli new-fnl my-app
            cd my-app && ./redinw --dev main.fnl
            ```
```

Replace with:

```yaml
          body: |
            ## What's included
            - `redin` binary (Linux x86_64, LuaJIT statically linked,
              built with REDIN_DEV / REDIN_PROFILE / REDIN_TRACK_MEM)
            - AOT-compiled Fennel runtime
            - Fennel compiler (for hot reload)
            - Developer documentation (guides + reference)
            - Claude Code skill for redin development

            ## Quick start
            ```
            redin-cli new-fnl my-app
            cd my-app && ./redinw main.fnl
            ```
```

- [ ] **Step 7: Verify the workflows parse**

```bash
# Quick lint via Python (yaml is in the standard lib).
python3 -c "import yaml; yaml.safe_load(open('.github/workflows/test.yml'))"
python3 -c "import yaml; yaml.safe_load(open('.github/workflows/release.yml'))"
```

Expected: no output (parse succeeds).

- [ ] **Step 8: Commit**

```bash
git add .github/workflows/test.yml .github/workflows/release.yml
git commit -m "$(cat <<'EOF'
ci: switch test + release workflows to ./build-dev.sh

The test job builds via ./build-dev.sh (REDIN_DEV / REDIN_PROFILE /
REDIN_TRACK_MEM all on); the agent test job appends
`-define:REDIN_AGENT=true` to that. The release tarball binary is
also built via ./build-dev.sh because its consumers (AI workflow
drivers) need the dev server compiled in. The agent release binary
appends -define:REDIN_AGENT=true and -out:dist-agent/redin via "$@".
Drops `--dev` from the quick-start example in release notes.
EOF
)"
```

---

### Task 9: Update `release.sh` and `scripts/smoke-native.sh`

**Files:**
- Modify: `release.sh:10`
- Modify: `scripts/smoke-native.sh:6, 48-58, 62-71, 92-93`

`release.sh` is a manual local-release helper paralleling `release.yml`. `scripts/smoke-native.sh` inlines its own copies of the `app.odin` and `build.sh` templates that mirror redin-cli's `app-odin-fnl` and `build-sh-native` constants — the maintenance skill calls out this parity rule explicitly.

- [ ] **Step 1: Update `release.sh`**

In `release.sh`, find around line 10:

```bash
echo "Building redin ${VERSION}..."
odin build src/cmd/redin -collection:lib=lib -collection:luajit=vendor/luajit -out:build/redin
```

Replace with:

```bash
echo "Building redin ${VERSION}..."
./build-dev.sh
```

- [ ] **Step 2: Update `smoke-native.sh` header comment**

In `scripts/smoke-native.sh`, find line 6:

```bash
# ./build.sh → launch binary under --dev → curl /state.
```

Replace with:

```bash
# ./build.sh → launch binary → curl /state.
```

- [ ] **Step 3: Update inline `app.odin` template**

In `scripts/smoke-native.sh`, find around lines 48-59:

```bash
cat > "$PROJECT/app.odin" <<'APP_ODIN'
package main

import redin "./.redin/src/redin"

main :: proc() {
	cfg: redin.Config
	cfg.dev = true
	cfg.app = "main.fnl"
	redin.run(cfg)
}
APP_ODIN
```

Replace with:

```bash
cat > "$PROJECT/app.odin" <<'APP_ODIN'
package main

import redin "./.redin/src/redin"

main :: proc() {
	cfg: redin.Config
	cfg.app = "main.fnl"
	redin.run(cfg)
}
APP_ODIN
```

`cfg.dev = true` is gone — Config no longer has the field. The dev server is now compile-time gated; the `build.sh` template (next step) bakes in `-define:REDIN_DEV=true`.

- [ ] **Step 4: Update inline `build.sh` template**

In `scripts/smoke-native.sh`, find around lines 62-70:

```bash
cat > "$PROJECT/build.sh" <<'BUILD_SH'
#!/usr/bin/env bash
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
mkdir -p "$SCRIPT_DIR/build"
odin build "$SCRIPT_DIR" \
  -collection:lib="$SCRIPT_DIR/.redin/lib" \
  -collection:luajit="$SCRIPT_DIR/.redin/vendor/luajit" \
  -out:"$SCRIPT_DIR/build/redin"
BUILD_SH
```

Replace with:

```bash
cat > "$PROJECT/build.sh" <<'BUILD_SH'
#!/usr/bin/env bash
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
mkdir -p "$SCRIPT_DIR/build"
odin build "$SCRIPT_DIR" \
  -collection:lib="$SCRIPT_DIR/.redin/lib" \
  -collection:luajit="$SCRIPT_DIR/.redin/vendor/luajit" \
  -define:REDIN_DEV=true \
  -define:REDIN_PROFILE=true \
  -define:REDIN_TRACK_MEM=true \
  -out:"$SCRIPT_DIR/build/redin"
BUILD_SH
```

The smoke check exercises a `--native` project's typical dev build, so it bakes in all three flags. This must mirror redin-cli's `build-sh-native` constant — when redin-cli's PR ships, its constant gets the same flags.

- [ ] **Step 5: Update binary-launch line**

In `scripts/smoke-native.sh`, find around lines 92-93:

```bash
echo "=== 4/5 launching build/redin --dev ==="
"${LAUNCHER[@]}" "$PROJECT/build/redin" --dev main.fnl &
```

Replace with:

```bash
echo "=== 4/5 launching build/redin ==="
"${LAUNCHER[@]}" "$PROJECT/build/redin" main.fnl &
```

- [ ] **Step 6: Test `release.sh` locally**

```bash
./release.sh v0.1.X-test
```

Expected: builds the binary via `./build-dev.sh`, packages a tarball into `dist/`. Inspect the tarball to confirm the binary has REDIN_DEV baked in (next step).

- [ ] **Step 7: Run the smoke check against the freshly-built tarball**

```bash
bash scripts/smoke-native.sh dist/redin-v0.1.X-test-linux-amd64.tar.gz
```

Expected: smoke check completes with "smoke check PASSED". Confirms:
- App.odin without `cfg.dev = true` builds (Config no longer has the field).
- build.sh with `-define:REDIN_DEV=true` produces a binary that starts the dev server.
- `/frames` polling sees the sentinel string.

Clean up:

```bash
rm -rf dist
```

- [ ] **Step 8: Commit**

```bash
git add release.sh scripts/smoke-native.sh
git commit -m "$(cat <<'EOF'
build: switch release.sh + smoke-native templates to compile-time flags

release.sh now calls ./build-dev.sh (matches release.yml). The smoke
script's inline app.odin drops `cfg.dev = true` (Config has no dev
field anymore) and its inline build.sh adds the three -define:REDIN_*
flags so the smoke check exercises the same defaults a fresh
`--native` project will get.
EOF
)"
```

---

### Task 10: Update `CLAUDE.md`

**Files:**
- Modify: `CLAUDE.md:21, 25-39, 41-58, 75, 84, 102-126`

CLAUDE.md is the project's top-level orientation document — the AI agent's first stop. Every reference to `--dev`, `--profile`, `--track-mem` needs the new mental model.

- [ ] **Step 1: Read the current top section**

```bash
sed -n '1,90p' CLAUDE.md
```

Note the sections that reference flags:
- "AI interface" line (mentions `--dev` and `--profile`)
- "Building" code blocks (basic build + REDIN_AGENT build)
- "Running" examples
- "Testing" UI integration test recipe
- "Architecture" tree comments referencing `--track-mem` and `--dev`
- "Dev server HTTP API" intro line and the `/profile` row

- [ ] **Step 2: Update the AI-interface paragraph**

In `CLAUDE.md`, find the "AI interface" line:

```markdown
- **AI interface:** localhost HTTP dev server (`--dev` mode). Default port 8800; … Optional `--profile` flag adds a 5-phase frame-timing ring buffer exposed at `/profile` and an F3-togglable on-screen overlay.
```

Replace with:

```markdown
- **AI interface:** localhost HTTP dev server (compile with `-define:REDIN_DEV=true`, or use `./build-dev.sh`). Default port 8800; if busy, walks upward to the next free port. Bound port is written to `./.redin-port`; a per-run random auth token is written to `./.redin-token` (mode 0600). Both files are removed on shutdown. Every non-`OPTIONS` request must include `Authorization: Bearer <contents of .redin-token>`; the server also rejects requests whose `Host` header isn't `localhost:<port>` or `127.0.0.1:<port>` (DNS-rebinding defence). Build with `-define:REDIN_PROFILE=true` to add a 5-phase frame-timing ring buffer exposed at `/profile` and an F3-togglable on-screen overlay. Build with `-define:REDIN_TRACK_MEM=true` to enable the tracking allocator and a leak dump on shutdown.
```

- [ ] **Step 3: Replace the Building section**

Find the "Building" section (around line 25):

```markdown
## Building

Default build:

```bash
odin build src/cmd/redin -collection:lib=lib -collection:luajit=vendor/luajit -out:build/redin
```

With the agent channel feature:

```bash
odin build src/cmd/redin -collection:lib=lib -collection:luajit=vendor/luajit \
    -define:REDIN_AGENT=true -out:build/redin
```

When `REDIN_AGENT` is set, the dev-server listener starts in any run
(not just `--dev`) and exposes the `/agent/*` endpoints. Default
release builds carry zero agent code.
```

Replace with:

```markdown
## Building

Release-stripped build (no dev server, no profile, no tracker):

```bash
odin build src/cmd/redin -collection:lib=lib -collection:luajit=vendor/luajit -out:build/redin
```

Dev build (REDIN_DEV + REDIN_PROFILE + REDIN_TRACK_MEM all baked in):

```bash
./build-dev.sh
```

Add the agent channel:

```bash
./build-dev.sh -define:REDIN_AGENT=true
```

When `REDIN_AGENT` is set, the dev-server listener starts in any run
(even without `REDIN_DEV`) and exposes the `/agent/*` endpoints.
Default release builds carry zero agent code, zero dev-server code,
zero profile instrumentation, and zero tracking-allocator overhead.
```

- [ ] **Step 4: Replace the Running section**

Find the "Running" section (around line 41):

```markdown
## Running

```bash
./build/redin examples/kitchen-sink.fnl        # normal mode
./build/redin --dev examples/kitchen-sink.fnl   # dev server + hot reload
```
```

Replace with:

```markdown
## Running

```bash
./build/redin examples/kitchen-sink.fnl
```

Whether the dev server starts depends on the build flags. A binary
built with `./build-dev.sh` starts the dev server unconditionally; a
bare `odin build` binary never does. There are no runtime CLI flags.
```

- [ ] **Step 5: Replace the Testing section**

Find the "Testing" section (around line 50):

```markdown
## Testing

```bash
# Fennel runtime tests (95 tests)
luajit test/lua/runner.lua test/lua/test_*.fnl

# UI integration tests (requires running dev server)
./build/redin --dev test/ui/<app>.fnl &
bb test/ui/run.bb test/ui/test_<name>.bb

# Build check
odin build src/cmd/redin -collection:lib=lib -collection:luajit=vendor/luajit -out:build/redin
```
```

Replace with:

```markdown
## Testing

```bash
# Fennel runtime tests
luajit test/lua/runner.lua test/lua/test_*.fnl

# UI integration tests (run the dev binary, no --dev flag needed)
./build-dev.sh
./build/redin test/ui/<app>.fnl &
bb test/ui/run.bb test/ui/test_<name>.bb

# Release build check
odin build src/cmd/redin -collection:lib=lib -collection:luajit=vendor/luajit -out:build/redin
```
```

- [ ] **Step 6: Update the architecture tree comments**

Find around line 75:

```markdown
  main.odin         Arg parsing, --track-mem setup, calls redin.run
```

Replace with:

```markdown
  main.odin         Arg parsing (app file only), tracker setup gated on REDIN_TRACK_MEM, calls redin.run
```

Find around line 84:

```markdown
    devserver.odin  HTTP dev server (--dev mode only)
```

Replace with:

```markdown
    devserver.odin  HTTP dev server (gated on REDIN_DEV / REDIN_AGENT)
```

- [ ] **Step 7: Update the Dev server HTTP API intro**

Find around line 102-104:

```markdown
## Dev server HTTP API

Available when running with `--dev`. Listens on port 8800 by default; walks upward (8801, 8802, ...) if busy, and writes the bound port to `./.redin-port`. A per-run random auth token is written to `./.redin-token` (0600). Every non-`OPTIONS` request must carry `Authorization: Bearer <token>`, and the `Host` header must be `localhost:<port>` / `127.0.0.1:<port>`.
```

Replace with:

```markdown
## Dev server HTTP API

Available when the binary was built with `-define:REDIN_DEV=true`
(or `-define:REDIN_AGENT=true`). Listens on port 8800 by default;
walks upward (8801, 8802, ...) if busy, and writes the bound port to
`./.redin-port`. A per-run random auth token is written to
`./.redin-token` (0600). Every non-`OPTIONS` request must carry
`Authorization: Bearer <token>`, and the `Host` header must be
`localhost:<port>` / `127.0.0.1:<port>`.
```

- [ ] **Step 8: Update the `/profile` row**

Find around line 112:

```markdown
| `GET` | `/profile` | Ring-buffered frame timings (requires `--profile`) |
```

Replace with:

```markdown
| `GET` | `/profile` | Ring-buffered frame timings (requires `-define:REDIN_PROFILE=true`) |
```

- [ ] **Step 9: Verify the markdown still renders**

```bash
# Quick visual check of the changed sections.
sed -n '20,50p' CLAUDE.md
sed -n '70,90p' CLAUDE.md
sed -n '95,130p' CLAUDE.md
```

Expected: clean prose, no leftover `--dev` / `--profile` / `--track-mem` references that should have been updated. Run a final grep:

```bash
grep -n "\-\-dev\|\-\-profile\|\-\-track-mem" CLAUDE.md
```

Expected: zero results.

- [ ] **Step 10: Commit**

```bash
git add CLAUDE.md
git commit -m "$(cat <<'EOF'
docs(CLAUDE.md): update for compile-time flag gating

Replace --dev / --profile / --track-mem CLI flag references with the
REDIN_DEV / REDIN_PROFILE / REDIN_TRACK_MEM compile-time model.
Building section now contrasts release-stripped (`odin build`) and dev
(`./build-dev.sh`) variants. Running and Testing sections drop the
runtime --dev argv. Architecture tree and Dev-server HTTP API intro
get matching wording updates.
EOF
)"
```

---

### Task 11: Update `docs/core-api.md`, `docs/reference/dev-server.md`, `docs/reference/native-bridge.md`

**Files:**
- Modify: `docs/core-api.md` (every `--dev` / `--profile` / `--track-mem` reference)
- Modify: `docs/reference/dev-server.md:9` and any other flag references
- Modify: `docs/reference/native-bridge.md:35` (`Config.dev == true` reference)

These are the public reference docs that ship in the release tarball. Their wording must match CLAUDE.md's new model.

- [ ] **Step 1: Sweep `docs/core-api.md` for `--dev` / `--profile` / `--track-mem`**

```bash
grep -n "\-\-dev\|\-\-profile\|\-\-track-mem" docs/core-api.md
```

For each match, replace the runtime-flag wording with the compile-time-flag wording. Common patterns:
- `running with --dev` → `built with -define:REDIN_DEV=true (or via ./build-dev.sh)`
- `the --profile flag` → `building with -define:REDIN_PROFILE=true`
- `--track-mem` → `-define:REDIN_TRACK_MEM=true`

If a sentence introduces the dev server with "available when running with `--dev`", change to "available when the binary was built with `-define:REDIN_DEV=true` (or `-define:REDIN_AGENT=true`)".

After each edit, re-run the grep — fix until zero matches remain (excluding any deliberately-historical mentions, which should be quoted or in a "before" context).

- [ ] **Step 2: Update `docs/reference/dev-server.md` line 9**

Find:

```markdown
Starts when the app is launched with `--dev`. Listens on `localhost:8800` (walks upward if busy).
```

Replace with:

```markdown
Starts when the binary was built with `-define:REDIN_DEV=true` (or `-define:REDIN_AGENT=true`). Listens on `localhost:8800` (walks upward if busy).
```

Sweep the rest of the file:

```bash
grep -n "\-\-dev\|\-\-profile\|\-\-track-mem" docs/reference/dev-server.md
```

For each match, apply the same pattern.

- [ ] **Step 3: Update `docs/reference/native-bridge.md`**

Find around line 35:

```markdown
**Duplicate names:** silent replace. In dev mode (`Config.dev == true`), logs a stderr warning before replacing — same policy as `canvas.register`.
```

Replace with:

```markdown
**Duplicate names:** silent replace. When the binary was built with `-define:REDIN_DEV=true`, logs a stderr warning before replacing — same policy as `canvas.register`.
```

Sweep the rest:

```bash
grep -n "\-\-dev\|\-\-profile\|\-\-track-mem\|cfg\.dev\|cfg\.profile\|Config\.dev\|Config\.profile" docs/reference/native-bridge.md
```

For each match, update accordingly. Note that `Config` no longer has `dev` or `profile` fields — any code example that sets them must be updated to drop those lines.

- [ ] **Step 4: Final grep across `docs/`**

```bash
grep -rn "\-\-dev\b\|\-\-profile\b\|\-\-track-mem\b\|cfg\.dev\|cfg\.profile\|Config\.dev\|Config\.profile" docs/
```

Expected: zero results outside historical/spec files (`docs/superpowers/specs/*` and `docs/superpowers/plans/*` are frozen and should NOT be updated).

If any `docs/guide/*.md` files surface, update them too (sweep the same way).

- [ ] **Step 5: Commit**

```bash
git add docs/core-api.md docs/reference/dev-server.md docs/reference/native-bridge.md
# Also stage any docs/guide/*.md files the sweep updated.
git commit -m "$(cat <<'EOF'
docs(reference): swap CLI flag wording for compile-time -define wording

docs/core-api.md, docs/reference/dev-server.md, and
docs/reference/native-bridge.md no longer reference --dev / --profile
/ --track-mem runtime flags or Config.dev / Config.profile fields.
Dev server availability is now described as "built with
-define:REDIN_DEV=true" throughout.
EOF
)"
```

---

### Task 12: Update `.claude/skills/redin-dev/SKILL.md` and `.claude/skills/redin-maintenance/SKILL.md`

**Files:**
- Modify: `.claude/skills/redin-dev/SKILL.md:14, 22, 229, 262, 278-280, 417-431` (and any others surfaced by grep)
- Modify: `.claude/skills/redin-maintenance/SKILL.md:48, 71-95, 136, 140-145, 182` (and any others)

The skills are part of the contract: they ship in the release tarball and are loaded into AI agents working on redin projects. Their command examples must match the new model exactly.

- [ ] **Step 1: Sweep redin-dev**

```bash
grep -n "\-\-dev\|\-\-profile\|\-\-track-mem\|cfg\.dev\|cfg\.profile" .claude/skills/redin-dev/SKILL.md
```

Address each match:

- The architecture tree comments (lines ~14, 22): match the CLAUDE.md updates from Task 10.
- The "Dev server (--dev mode, default port 8800)" header (~line 229): change to "Dev server (built with `-define:REDIN_DEV=true` or `./build-dev.sh`, default port 8800)".
- The Agent channel section's "starts even without `--dev`" (~line 262): change to "starts even without `REDIN_DEV`".
- The UI integration tests example (~lines 278-280): switch the command sequence to `./build-dev.sh` then `./build/redin test/ui/<component>_app.fnl &`.
- The native scaffolding example (~lines 417-431): the `app.odin` template currently shows `cfg.dev = true` and a `case "--dev"` in arg parsing. The new shape:

  ```odin
  package main

  import "core:os"
  import redin "./.redin/src/redin"
  import "./.redin/src/redin/canvas"

  main :: proc() {
      redin.set_window(1920, 1080, "my game", {.WINDOW_RESIZABLE})

      canvas.register("my-bg", my_bg_provider)
      redin.on_frame(per_frame_tick)

      cfg: redin.Config
      for arg in os.args[1:] {
          cfg.app = arg
      }
      redin.run(cfg)
  }
  ```

  And the run examples (~line 429-431):

  ```bash
  ./redinw main.fnl                # built with REDIN_DEV → dev server starts
  ./redinw main.fnl                # built without REDIN_DEV → no dev server
  ./build.sh                        # rebuild after editing app.odin
  ```

  Drop the `--dev` / `--track-mem` argv lines.

After all edits, re-grep:

```bash
grep -n "\-\-dev\|\-\-profile\|\-\-track-mem" .claude/skills/redin-dev/SKILL.md
```

Expected: zero matches.

- [ ] **Step 2: Sweep redin-maintenance**

```bash
grep -n "\-\-dev\|\-\-profile\|\-\-track-mem" .claude/skills/redin-maintenance/SKILL.md
```

Address each match. Notable rewrites:

- The basic build command (line ~10 area): contrast `odin build ...` (release) vs `./build-dev.sh` (dev).
- The "Run one" example (~line 48): change `./build/redin --dev test/ui/<component>_app.fnl &` to `./build/redin test/ui/<component>_app.fnl &` (binary built via `./build-dev.sh`).
- The Memory leak detection section (~lines 71-95): explain that REDIN_TRACK_MEM is baked in by `./build-dev.sh`. The recipe `./build/redin --dev --track-mem test/ui/<component>_app.fnl` becomes `./build-dev.sh && ./build/redin test/ui/<component>_app.fnl` — the tracker is on by virtue of REDIN_TRACK_MEM being compiled in.
- The "Modify run-all.sh's server start line to include --track-mem" tip: that approach is obsolete. Replace with: "track-mem is baked into ./build-dev.sh's binary, so run-all.sh already exercises it."
- The change-area table row `src/cmd/redin/ (CLI flags, --track-mem)` (~line 136): change to `src/cmd/redin/ (top-level main, REDIN_TRACK_MEM gating)`.
- The Agent channel build section (~line 140-145):

  ```bash
  ./build-dev.sh -define:REDIN_AGENT=true
  bash test/ui/run-all.sh --headless
  ```

- The smoke check section (~line 182): the description "Launch the resulting binary under `--dev`" becomes "Launch the resulting binary".

After all edits, re-grep:

```bash
grep -n "\-\-dev\|\-\-profile\|\-\-track-mem" .claude/skills/redin-maintenance/SKILL.md
```

Expected: zero matches.

- [ ] **Step 3: Final grep across `.claude/`**

```bash
grep -rn "\-\-dev\|\-\-profile\|\-\-track-mem\|cfg\.dev\|cfg\.profile\|Config\.dev\|Config\.profile" .claude/
```

Expected: zero matches.

- [ ] **Step 4: Commit**

```bash
git add .claude/skills/redin-dev/SKILL.md .claude/skills/redin-maintenance/SKILL.md
git commit -m "$(cat <<'EOF'
skills: update redin-dev / redin-maintenance for compile-time flags

Both skills lose every --dev / --profile / --track-mem reference.
Build commands now contrast `odin build` (release) vs ./build-dev.sh
(dev). The native scaffolding example drops cfg.dev assignment and
the case "--dev" arg-parsing branch. Memory-leak detection drops the
old run-all.sh tip and explains that ./build-dev.sh already bakes in
REDIN_TRACK_MEM. Agent build recipe uses ./build-dev.sh -define:....
EOF
)"
```

---

### Task 13: Final verification

**Files:** none (this is a verification-only task; no commit unless something failed).

Confirm both build flavors work end-to-end and that the strip claims hold.

- [ ] **Step 1: Clean build, all variants**

```bash
rm -f build/redin
odin build src/cmd/redin -collection:lib=lib -collection:luajit=vendor/luajit -out:build/redin
ls -lh build/redin
```

Note the size of the release binary.

```bash
./build-dev.sh
ls -lh build/redin
```

Note the size of the dev binary. Expected: dev binary larger than release binary (dev server, hot reload, profile ring buffer, tracking allocator all add bytes).

- [ ] **Step 2: Strip check**

```bash
odin build src/cmd/redin -collection:lib=lib -collection:luajit=vendor/luajit -out:build/redin-release
nm build/redin-release | grep -ci 'devserver_\|hotreload_' || true
```

Expected: 0 (release binary has no devserver / hotreload symbols). If non-zero, identify the leaking symbol — every `devserver_` / `hotreload_` proc body must be inside a `when REDIN_DEV || REDIN_AGENT` block (or the calling site must be).

```bash
./build-dev.sh -out:build/redin-dev
nm build/redin-dev | grep -ci 'devserver_\|hotreload_'
```

Expected: non-zero (dev binary has the symbols).

```bash
rm -f build/redin-release build/redin-dev
```

- [ ] **Step 3: Behavioral test — release binary runs, no dev server**

```bash
odin build src/cmd/redin -collection:lib=lib -collection:luajit=vendor/luajit -out:build/redin
rm -f .redin-port .redin-token
DISPLAY= xvfb-run -a ./build/redin test/ui/markdown_app.fnl &
PID=$!
disown
sleep 3
ls .redin-port .redin-token 2>&1
kill -9 $PID 2>/dev/null || true
sleep 1
```

Expected: both `ls` lines say "No such file or directory". Release binary cannot start the dev server.

- [ ] **Step 4: Behavioral test — dev binary runs and starts dev server**

```bash
./build-dev.sh
rm -f .redin-port .redin-token
DISPLAY= xvfb-run -a ./build/redin test/ui/markdown_app.fnl &
disown
until [ -f .redin-port ] && [ -f .redin-token ]; do sleep 0.2; done
echo "dev server: port=$(cat .redin-port)"
PORT=$(cat .redin-port); TOKEN=$(cat .redin-token)
curl -s -H "Authorization: Bearer $TOKEN" "http://localhost:$PORT/state" | head -c 80
echo
curl -s -X POST -H "Authorization: Bearer $TOKEN" "http://localhost:$PORT/shutdown" > /dev/null
sleep 1
```

Expected: port/token files appear, `/state` returns valid JSON, shutdown succeeds.

- [ ] **Step 5: Track-mem behavioral test**

```bash
./build-dev.sh
DISPLAY= xvfb-run -a ./build/redin test/ui/markdown_app.fnl > /tmp/track.log 2>&1 &
disown
until [ -f .redin-port ] && [ -f .redin-token ]; do sleep 0.2; done
sleep 1
PORT=$(cat .redin-port); TOKEN=$(cat .redin-token)
curl -s -X POST -H "Authorization: Bearer $TOKEN" "http://localhost:$PORT/shutdown" > /dev/null
sleep 2
grep -E "Memory tracking enabled|allocations not freed" /tmp/track.log
```

Expected: at least the "Memory tracking enabled (REDIN_TRACK_MEM)" line. The leak count line may or may not appear depending on whether anything leaked (today's baseline is 23 long-lived global allocations).

- [ ] **Step 6: Full Fennel + Odin unit test sweep**

```bash
luajit test/lua/runner.lua test/lua/test_*.fnl
echo ---
odin test src/redin/markdown -collection:lib=lib -collection:luajit=vendor/luajit -define:ODIN_TEST_THREADS=1
odin test src/redin/bridge -collection:lib=lib -collection:luajit=vendor/luajit -define:ODIN_TEST_THREADS=1
odin test src/redin/parser -collection:lib=lib -collection:luajit=vendor/luajit -define:ODIN_TEST_THREADS=1
odin test src/redin/input -collection:lib=lib -collection:luajit=vendor/luajit -define:ODIN_TEST_THREADS=1
odin test src/redin/profile -collection:lib=lib -collection:luajit=vendor/luajit -define:REDIN_PROFILE=true -define:ODIN_TEST_THREADS=1
```

Expected: all suites green.

- [ ] **Step 7: Full UI integration suite**

```bash
bash test/ui/run-all.sh --headless
```

Expected: "All test suites passed".

- [ ] **Step 8: Smoke-native check (dry run against a fresh tarball)**

```bash
./release.sh v0.1.X-test
bash scripts/smoke-native.sh dist/redin-v0.1.X-test-linux-amd64.tar.gz
rm -rf dist
```

Expected: "smoke check PASSED". Confirms the `--native` template path stays viable end-to-end.

- [ ] **Step 9: No commit needed**

If every step above passed, the implementation is complete. The branch is ready for PR.

If any step failed, fix the underlying issue in the relevant earlier task and re-run the failing step. Don't paper over a failure here — Task 13's job is to catch regressions before they ship.

---

## Self-review (post-write)

**1. Spec coverage:** Every section of the spec maps to tasks:

- "New compile-time constants" → Task 1
- "CLI flags removed" → Task 7 step 4
- "`redin.Config` shrinks" → Task 7 step 1
- "Per-package code changes" `main.odin` → Task 7
- `runtime.odin` → Tasks 3 step 2, 4 step 3, 5 step 5, 7 steps 1-2
- `bridge/` → Task 5
- `profile/` → Task 4
- `canvas/` → Task 3
- "`./build-dev.sh`" → Task 2
- "Test + CI integration" → Tasks 6, 8, 9
- "redin-cli template parity" — *not* covered here; lives in a separate redin-cli PR. The smoke-native templates that mirror redin-cli's constants ARE covered in Task 9. The redin-cli PR is out of scope for this plan but should ship in the same release bump (per the spec).
- "Documentation updates" → Tasks 10, 11, 12
- "Migration / breaking changes" → Task 7's commit message captures the BREAKING CHANGE
- "Verification" → Task 13

**2. Placeholder scan:** No "TBD", "TODO", "implement later" patterns. The one near-placeholder is Task 4 step 2's instruction to "wrap the body of any `draw_overlay`-like proc in `when REDIN_PROFILE`" — but that's accompanied by a concrete `cat overlay.odin` step that lets the engineer see the file and a precise pattern (`when !REDIN_PROFILE do return` at the top of each public proc). Acceptable.

**3. Type consistency:** `Config :: struct { app: string }` referenced consistently across Tasks 7, 9, and 12. `bridge.init(b)` (no parameter) consistent across Tasks 5 and 7. `profile.init()` (no parameter) consistent across Tasks 4 and 7. `canvas.set_dev_mode` removed entirely (Task 3) — no later task references it.

**4. Ambiguity check:** The one judgment call is in Task 4: how to gate `is_enabled() -> bool` (returns `true` when `REDIN_PROFILE`, else `false`). I picked the explicit form. If a caller currently special-cases `!is_enabled()` for fast-path, gating works fine because the result is a compile-time constant. No later task contradicts.

The plan is ready.

---

## Execution Handoff

**Plan complete and saved to `docs/superpowers/plans/2026-05-03-compile-time-flags.md`.** Two execution options:

**1. Subagent-Driven (recommended)** — I dispatch a fresh subagent per task, review between tasks, fast iteration.

**2. Inline Execution** — Execute tasks in this session using executing-plans, batch execution with checkpoints for review.

Which approach?
