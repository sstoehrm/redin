# redin

A re-frame inspired desktop UI framework.

## Status

Active development on `reboot` branch. Core rendering, bridge, input, and runtime are functional.

## Documentation

- [docs/core-api.md](docs/core-api.md) -- Frame format, events, host functions, interaction model, dev server
- [docs/app-api.md](docs/app-api.md) -- Dataflow, tracked state accessors, subscriptions, effect system

These docs are the source of truth. When implementing, follow them exactly.

## Stack

- **Host/renderer:** Odin + Raylib
- **Scripting:** LuaJIT (Lua 5.1 API) with Fennel compiled to Lua 5.1 target
- **AI interface:** localhost HTTP dev server (port 8800, `--dev` mode)

## Building

```bash
odin build src/host -out:build/redin
```

## Running

```bash
./build/redin examples/kitchen-sink.fnl        # normal mode
./build/redin --dev examples/kitchen-sink.fnl   # dev server + hot reload
```

## Testing

```bash
# Fennel runtime tests (95 tests)
luajit test/lua/runner.lua test/lua/test_*.fnl

# Build check
odin build src/host -out:build/redin
```

## Architecture

```
src/host/           Odin host
  main.odin         Entry point, main loop
  render.odin       Raylib renderer (node_rects for hit testing)
  bridge/           Lua/Fennel bridge package
    bridge.odin     Bridge struct, init/destroy, host callbacks, Lua<->Odin conversion
    lua_api.odin    LuaJIT FFI bindings (statically linked)
    http_client.odin  Async HTTP via threads
    json.odin       JSON encode/decode for Lua
    devserver.odin  HTTP dev server (--dev mode only)
    hotreload.odin  File watcher for .fnl hot reload
    loader.odin     App file loading (Fennel via fennel.dofile, Lua via luaL_dofile)
  input/            Input handling package
    input.odin      Event polling (Raylib), listener extraction from nodes+theme
    apply.odin      Focus/active state from mouse clicks (hit testing via node_rects)
    user_events.odin  User-facing events (click, hover, key, change)
  parser/           EDN-like .fnl file parsers
  types/            Shared type definitions (Node, Theme, Listener, events)
src/runtime/        Fennel runtime (loaded by bridge at startup)
  init.fnl          Bootstrap, wires dataflow->effects
  dataflow.fnl      State management with path-tracked subscriptions
  effect.fnl        Side effects (log, dispatch, dispatch-later, http)
  frame.fnl         Nested list flattening
  view.fnl          View runner (render tick, event delivery)
  theme.fnl         Theme storage, resolution, validation
```

## Key conventions

- Node types: `NodeStack`, `NodeCanvas`, `NodeVbox`, `NodeHbox`, `NodeInput`, `NodeButton`, `NodeText`, `NodeImage`, `NodePopout`, `NodeModal`
- Theme state variants use `#` notation: `button#hover`, `input#focus`
- Width/height on most nodes: `union {SizeValue, f32}` or `union {SizeValue, f16}`
- Flat parallel arrays for view tree: `nodes[]`, `paths[]`, `parent_indices[]`, `children_list[]` (DFS order, i32 indices)
- Bridge converts Lua tables directly to flat arrays (no intermediate tree)
- `focused_idx` lives in the `input` package, read by `render` for cursor
- `node_rects` lives in `render`, passed as parameter to input functions
