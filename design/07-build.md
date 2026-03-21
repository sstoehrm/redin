# Build & module layout

## Module layout

```
redin-next/
  src/
    host/            — Odin code
      main.odin      — window, main loop, Lua VM init
      render.odin    — frame tree → Raylib draw calls
      layout.odin    — frame tree → positioned rects
      input.odin     — Raylib input → redin events (via bindings)
      aspects.odin   — resolve aspect names → concrete styles
      server.odin    — HTTP/WS server for AI + dev tools
      lua_bridge.odin — Odin ↔ Lua FFI
    runtime/         — Lua/Fennel code
      core.fnl       — app-db, dispatch, subscribe
      fx.fnl         — effect handlers (db, http, timer, etc.)
      frame.fnl      — frame helpers / validation
      aspects.fnl    — aspect/theme definitions + merging
    app/             — example app (Fennel)
      main.fnl       — event handlers, subs, views
      theme.fnl      — app's aspect map
  test/              — Fennel tests against pure data
  vendor/            — Lua, Fennel, Raylib bindings
```

## Build

- Odin compiles the host binary, statically linking Lua and Raylib.
- Fennel files are compiled to Lua at build time (or loaded live for dev).
- Hot reload: re-evaluate Fennel files without restarting. State in app-db survives.
- The server starts automatically in dev mode, opt-in for production.
