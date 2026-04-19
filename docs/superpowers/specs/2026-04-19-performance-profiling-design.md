# Performance Profiling — Design

**Date:** 2026-04-19
**Status:** Approved, ready for implementation planning

## Goal

Add always-on (opt-in) profiling infrastructure to redin so future performance work has a foundation. The profiler captures per-phase frame timings into a short ring buffer, draws an on-screen overlay, and exposes the data through the dev server for tools and AI-driven analysis.

Non-goals: Lua-side (per-subscription, per-handler) profiling; long session history; microbenchmarks of specific hot paths. Those remain future work once a specific bottleneck is identified.

## Activation

A new CLI flag `--profile`, orthogonal to `--dev` and `--track-mem`:

| Flags | Collection | Overlay | `/profile` endpoint |
|-------|------------|---------|---------------------|
| (none) | off | hidden | not registered |
| `--profile` | on | visible | not registered (no dev server) |
| `--dev` | off | hidden | not registered |
| `--profile --dev` | on | visible | registered |

`F3` toggles overlay visibility at runtime, but only has effect when `--profile` is active. When `--profile` is off, `profile.begin`/`end` are predictable no-ops: a single branch on a package-level `enabled` bool, no syscall, no allocation.

## Phases

Five coarse phases cover the main loop:

1. `Input` — `input.poll` plus all `apply_*` / `process_*` calls.
2. `Bridge` — all Lua work: `deliver_events`, `render_tick`, `poll_http`, `poll_timers`, `poll_shell`, `check_hotreload`.
3. `Devserver` — `bridge.poll_devserver`.
4. `Layout` — sizing pass that populates `node_rects`.
5. `Render` — Raylib draw calls for the node tree.

This requires splitting the current `render_tree` into `layout_tree` (sizing + `node_rects`) and `draw_tree` (drawing) so Layout and Render are separately measurable. The split is a small prerequisite refactor with independent value — it also lets hit-testing use rects computed before drawing.

## Data model

Lives in `src/host/profile/profile.odin`:

```odin
FRAME_CAP :: 120   // 2 seconds at 60 FPS

Phase :: enum { Input, Bridge, Layout, Render, Devserver }

FrameSample :: struct {
    frame_idx: u64,
    total_ns:  i64,
    phase_ns:  [Phase]i64,
}

Ring :: struct {
    samples: [FRAME_CAP]FrameSample,  // fixed storage, no alloc
    head:    int,                     // index of next write
    count:   int,                     // saturates at FRAME_CAP
}
```

One package-level `Ring`, zero-initialized at startup. Time source is `core:time` `tick_now()` / `tick_diff()` — nanosecond resolution, monotonic.

Memory footprint: 120 × (8 + 8 + 5×8) ≈ 6.7 KB, fixed.

## Instrumentation API

```odin
profile.init(enabled: bool)         // sets package-level `enabled`, zeros the ring
                                    // and prepares the snapshot mutex

profile.begin_frame()                // top of main loop; records frame-start tick
profile.end_frame()                  // bottom of main loop; writes FrameSample to ring

Scope :: struct { phase: Phase, start: time.Tick }
profile.begin :: proc(p: Phase) -> Scope
profile.end   :: proc(s: Scope)
```

Call sites in `main.odin`:

```odin
profile.begin_frame()

{ s := profile.begin(.Input);     defer profile.end(s); /* input.poll + applies */ }
{ s := profile.begin(.Bridge);    defer profile.end(s); /* bridge.* calls       */ }
{ s := profile.begin(.Devserver); defer profile.end(s); /* poll_devserver       */ }

rl.BeginDrawing()
rl.ClearBackground({255, 255, 255, 255})
{ s := profile.begin(.Layout);    defer profile.end(s); layout_tree(...) }
{ s := profile.begin(.Render);    defer profile.end(s); draw_tree(...)   }
profile.draw_overlay()              // drawn AFTER the Render phase closes,
                                    // so overlay cost is not attributed to Render
canvas.end_frame()
rl.EndDrawing()

profile.end_frame()
```

When `enabled == false`, `begin` returns a zero `Scope` and `end` early-returns — one branch, no syscall, no allocation.

## Overlay

`profile.draw_overlay()` is called from `main.odin` between the draw pass and `canvas.end_frame()`. Only runs when `--profile` is active and `visible` is true.

- **Panel:** 180×110 px, top-right corner, semi-transparent black (alpha ~180).
- **Line 1:** `FPS 59  frame 16.4ms` (last-sample total, 0.1 ms precision).
- **Lines 2–6:** one per phase, right-aligned: `input 0.3ms`, `bridge 8.4ms`, etc.
- **Mini graph:** 120-pixel-wide strip along the bottom; one bar per ring slot, height ∝ `total_ns / 33ms` (clamped). Red if `total_ns > 16.67ms`, green otherwise.
- **Text rendering:** `rl.DrawText` with the Raylib default font — independent of `font.*` and app theme so a broken app theme can't break the profiler.
- **Toggle:** `rl.IsKeyPressed(.F3)` flips a package-level `visible` bool inside `draw_overlay`. No key consumption — app handlers still see F3 if they bind it (unlikely).

## Dev server endpoint

`GET /profile` registered in `src/host/bridge/devserver.odin` when both `--dev` and `--profile` are active; returns 404 otherwise (so callers can detect profiling is off).

Response body:

```json
{
  "enabled": true,
  "frame_cap": 120,
  "count": 120,
  "phases": ["input", "bridge", "layout", "render", "devserver"],
  "frames": [
    {"idx": 4820, "total_us": 14230, "phase_us": [310, 8420, 1890, 3480, 130]},
    {"idx": 4821, "total_us": 15110, "phase_us": [290, 9150, 2010, 3530, 130]}
  ]
}
```

- Units: microseconds as integers (lossless vs nanoseconds we store; avoids JSON float precision).
- `phase_us` is positional, matching `phases[]`, so callers can build per-phase time-series without per-sample key lookup.
- Frames ordered oldest → newest. No pagination — full ring fits in ~6.7 KB on the wire.

**Thread-safety:** the devserver handler runs on its own thread. It copies the ring under `profile.snapshot_mutex`, which the main loop holds only during `end_frame`'s write. Copy is a plain `mem.copy` — sub-10 µs.

## File layout

### New files

```
src/host/profile/
  profile.odin       Public API: init, begin_frame, end_frame, begin, end,
                     snapshot, draw_overlay. Owns Ring, visible, mutex.
  overlay.odin       draw_overlay implementation.
  profile_test.odin  Unit tests (ring semantics, no-op behaviour).
```

### Touched files

- `src/host/main.odin` — parse `--profile`, call `profile.init`, wrap phases in `begin`/`end` scopes, split `render_tree` into `layout_tree` + `draw_tree`, call `draw_overlay`.
- `src/host/render.odin` — split `render_tree` into `layout_tree` (sizing + `node_rects`) and `draw_tree` (Raylib draw calls). `node_rects` lifetime unchanged.
- `src/host/bridge/devserver.odin` — register `GET /profile` when profile enabled; JSON encode snapshot.
- `CLAUDE.md` — add `/profile` row to the dev-server table.
- `docs/reference/dev-server.md` — document `/profile` response schema.

## Testing

### Unit (Odin)

`src/host/profile/profile_test.odin`:

- **Ring fill:** write 30 samples → `count == 30`, `head == 30`, snapshot order oldest→newest.
- **Ring wrap:** write 200 samples → `count == 120`, `head == 200 % 120 == 80`, snapshot order oldest→newest, oldest sample has `frame_idx == 80`.
- **No-op:** with `enabled == false`, `begin(.Input)` returns zero `Scope`, `end` is a nop, ring `count` remains 0.

### Integration (Babashka)

Following the `test/ui/` convention:

- `test/ui/profile_app.fnl` — minimal app that renders a text node.
- `test/ui/test_profile.bb` — launches `./build/redin --dev --profile test/ui/profile_app.fnl`; after ~1s polls `/profile`; asserts:
  - `enabled == true`.
  - `phases == ["input", "bridge", "layout", "render", "devserver"]`.
  - `count` grows and reaches `frame_cap` (120) after sufficient wait.
  - For each frame, `sum(phase_us) ≈ total_us` within 5% (accounts for untimed glue between phases).
  - With only `--dev` (no `--profile`), `GET /profile` returns 404.

### Build check

`odin build src/host -out:build/redin` must pass (existing maintenance checklist, no change).

## Rollout

One implementation plan covering, in order:

1. Split `render_tree` into `layout_tree` + `draw_tree`; verify existing UI tests still pass.
2. Create `profile` package with API, ring, unit tests.
3. Wire `--profile` flag and `begin`/`end` scopes into `main.odin`.
4. Implement overlay.
5. Add `/profile` endpoint + JSON encoding.
6. Add `test/ui/test_profile.bb` integration test.
7. Update `CLAUDE.md` and `docs/reference/dev-server.md`.

Each step leaves the tree green (build + existing tests), so the work can be paused between steps without partial state.
