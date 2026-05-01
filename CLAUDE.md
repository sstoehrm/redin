# redin

A re-frame inspired desktop UI framework.

## Status

Active development on `reboot` branch. Core rendering, bridge, input, and runtime are functional.

## Documentation

- [docs/core-api.md](docs/core-api.md) -- Frame format, events, host functions, interaction model, dev server
- [docs/app-api.md](docs/app-api.md) -- Dataflow, tracked state accessors, subscriptions, effect system
- [docs/reference/native-bridge.md](docs/reference/native-bridge.md) -- Public bridge API for `--native` projects (`register_cfunc`, `dispatch`, `push`)

These docs are the source of truth. When implementing, follow them exactly.

## Stack

- **Host/renderer:** Odin + Raylib
- **Scripting:** LuaJIT (Lua 5.1 API) with Fennel compiled to Lua 5.1 target
- **AI interface:** localhost HTTP dev server (`--dev` mode). Default port 8800; if busy, walks upward to the next free port. Bound port is written to `./.redin-port`; a per-run random auth token is written to `./.redin-token` (mode 0600). Both files are removed on shutdown. Every non-`OPTIONS` request must include `Authorization: Bearer <contents of .redin-token>`; the server also rejects requests whose `Host` header isn't `localhost:<port>` or `127.0.0.1:<port>` (DNS-rebinding defence). Optional `--profile` flag adds a 5-phase frame-timing ring buffer exposed at `/profile` and an F3-togglable on-screen overlay.

## Building

```bash
odin build src/cmd/redin -collection:lib=lib -collection:luajit=vendor/luajit -out:build/redin
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

# UI integration tests (requires running dev server)
./build/redin --dev test/ui/<app>.fnl &
bb test/ui/run.bb test/ui/test_<name>.bb

# Build check
odin build src/cmd/redin -collection:lib=lib -collection:luajit=vendor/luajit -out:build/redin
```

### UI test convention

When touching a component, write a UI test if one doesn't exist yet, or add to the existing test file. Each component gets:
- `test/ui/<component>_app.fnl` -- minimal app exercising just that component
- `test/ui/test_<component>.bb` -- Babashka tests using the `redin-test` framework

Existing UI tests: `test_smoke` (basic dispatch/state), `test_input` (input change/key/submit).

## Architecture

```
src/cmd/redin/      Thin CLI entry (package main)
  main.odin         Arg parsing, --track-mem setup, calls redin.run
src/redin/          Importable framework package (package redin)
  runtime.odin      Public API: set_window/set_size/set_title, on_* hooks, run, request_shutdown
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

## Dev server HTTP API

Available when running with `--dev`. Listens on port 8800 by default; walks upward (8801, 8802, ...) if busy, and writes the bound port to `./.redin-port`. A per-run random auth token is written to `./.redin-token` (0600). Every non-`OPTIONS` request must carry `Authorization: Bearer <token>`, and the `Host` header must be `localhost:<port>` / `127.0.0.1:<port>`.

| Method | Path | Description |
|--------|------|-------------|
| `GET` | `/frames` | Last pushed frame (view tree as JSON). Each node's attrs include `"rect":[x,y,w,h]` from the most recent layout. |
| `GET` | `/state` | Full app state |
| `GET` | `/state/<dot.path>` | Nested state lookup (e.g. `/state/form.name`) |
| `GET` | `/aspects` | Current theme map |
| `GET` | `/profile` | Ring-buffered frame timings (requires `--profile`) |
| `GET` | `/screenshot` | PNG screenshot of the window |
| `POST` | `/events` | Dispatch an event (JSON body: `[:event-name, payload]`) |
| `POST` | `/click` | Inject a mouse click (JSON body: `{"x":N,"y":N}`) |
| `POST` | `/shutdown` | Request graceful shutdown |
| `PUT` | `/aspects` | Replace the theme map (JSON body) |
| `POST` | `/input/takeover` | Take over mouse polling for tests. Required before `/input/mouse/*`. |
| `POST` | `/input/release` | Restore raylib mouse polling. |
| `POST` | `/input/mouse/move` | Set override mouse position (`{x,y}`). Requires takeover. |
| `POST` | `/input/mouse/down` | Press a button (`{button:"left\|right\|middle"}`). Requires takeover. |
| `POST` | `/input/mouse/up` | Release a button (`{button:...}`). Requires takeover. |
| `POST` | `/input/key` | Synthesise one KeyEvent (`{key, mods?}`). Does not require takeover. |

Example:

```bash
curl -H "Authorization: Bearer $(cat .redin-token)" \
     http://localhost:$(cat .redin-port)/state/counter
```

## Key conventions

- Node types: `NodeStack`, `NodeCanvas`, `NodeVbox`, `NodeHbox`, `NodeInput`, `NodeButton`, `NodeText`, `NodeImage`, `NodePopout`, `NodeModal`
- Theme state variants use `#` notation: `button#hover`, `input#focus`
- Width/height on most nodes: `union {SizeValue, f32}` or `union {SizeValue, f16}`
- Flat parallel arrays for view tree: `nodes[]`, `paths[]`, `parent_indices[]`, `children_list[]` (DFS order, i32 indices)
- Bridge converts Lua tables directly to flat arrays (no intermediate tree)
- `focused_idx` lives in the `input` package, read by `render` for cursor
- `node_rects` lives in `render`, passed as parameter to input functions
