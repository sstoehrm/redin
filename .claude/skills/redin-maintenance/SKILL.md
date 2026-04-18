---
name: redin-maintenance
description: Use when verifying changes to the redin framework — build checks, test suites, memory leak detection, and integration test workflows.
---

# redin Maintenance

Use this skill to verify changes to the redin framework before committing.

## Build

```bash
odin build src/host -out:build/redin
```

Requires: `libssl-dev`, `libraylib-dev`, and the `lib/odin-http` git submodule (`git submodule update --init`).

## Fennel runtime tests

```bash
luajit test/lua/runner.lua test/lua/test_*.fnl
```

Covers dataflow, effects, frames, views, themes, canvas, and shell. Currently 122 tests. Run after any change to `src/runtime/`.

## UI integration tests

Each component has a paired app + test:
- `test/ui/<component>_app.fnl` — minimal app exercising the component
- `test/ui/test_<component>.bb` — Babashka tests using `redin-test` framework

### Run all

```bash
bash test/ui/run-all.sh
```

Builds redin, then for each pair: starts dev server, runs tests, shuts down. Requires `bb` (Babashka).

### Run one

```bash
./build/redin --dev test/ui/<component>_app.fnl &
bb test/ui/run.bb test/ui/test_<component>.bb
curl -s -X POST http://localhost:8800/shutdown
```

### Available test suites

`smoke`, `input`, `button`, `canvas`, `drag`, `image`, `line_height`, `modal`, `multiline`, `popout`, `resize`, `scroll`, `scroll_x`, `shadow`, `viewport`

## Memory leak detection

Add `--track-mem` to enable the tracking allocator:

```bash
./build/redin --dev --track-mem test/ui/<component>_app.fnl
```

On shutdown, the tracking allocator reports outstanding allocations. Check stderr/stdout for lines containing `leak` or `outstanding`.

To run all integration tests with memory tracking:

```bash
# Modify run-all.sh's server start line to include --track-mem:
#   "$BINARY" --dev --track-mem "$app_file" &
# Or run manually per-component as above.
```

## Verification checklist

After changes to the framework, verify in this order:

1. **Build** — `odin build src/host -out:build/redin`
2. **Runtime tests** — `luajit test/lua/runner.lua test/lua/test_*.fnl`
3. **Integration tests** — `bash test/ui/run-all.sh`
4. **Visual check** — for rendering changes, take a screenshot via `GET /screenshot` on the dev server and inspect
5. **Memory check** — for allocation/bridge changes, run with `--track-mem` and verify no leaks on shutdown

## When to run what

| Change area | Build | Runtime tests | UI tests | Memory check |
|---|---|---|---|---|
| `src/runtime/` (Fennel) | - | Yes | Yes | - |
| `src/host/render.odin` | Yes | - | Yes (visual) | - |
| `src/host/bridge/` | Yes | - | Yes | Yes |
| `src/host/input/` | Yes | - | Yes | - |
| `src/host/types/` | Yes | - | Yes | - |
| `src/host/text/` | Yes | - | Yes (multiline) | - |
