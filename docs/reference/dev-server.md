# Dev Server Reference

HTTP server for inspecting and driving redin apps from external tools.

---

## Overview

Starts when the binary was built with `-define:REDIN_DEV=true` (or `-define:REDIN_AGENT=true`). Listens on `localhost:8800` (walks upward if busy).

Read endpoints reflect the last state pushed to the host. Write endpoints queue events into the main input channel as if they came from real user input.

The listener is an acceptor thread plus a fixed pool of 16 handler threads, so up to 16 requests can be in flight at once. Beyond that, new connections queue until a handler frees up. Each connection is bounded by a 2-second per-recv timeout and a 10-second total request deadline — slowloris caps, not user-facing knobs.

Implementation: `src/redin/bridge/devserver.odin`.

### Authentication

On startup the server generates a random 256-bit token and writes it to `./.redin-token` (mode 0600, removed on shutdown). Every non-OPTIONS request must include:

```
Authorization: Bearer <contents of .redin-token>
```

The server also verifies the `Host` header matches `localhost:<port>` or `127.0.0.1:<port>` to blunt DNS-rebinding attacks. CORS preflight is not served — the endpoint is intended for local tools, not browsers. Missing token → `401`; bad Host → `403`; OPTIONS → `405`; malformed `Content-Length` (more than 12 digits) → `400 Bad Request`.

If the server cannot write `.redin-token` or `.redin-port` at startup (read-only directory, etc.), it aborts startup and prints a clear stderr line. The dev server never runs without a token file in place.

All examples below assume:

```bash
PORT=$(cat .redin-port)
TOKEN=$(cat .redin-token)
AUTH="Authorization: Bearer $TOKEN"
```

### Runtime caveats

**When built with `-define:REDIN_DEV=true`, the framework trusts its filesystem.** The hot-reload watcher re-requires `src/runtime/*.fnl` whenever their mtimes advance. Anyone who can write to `src/runtime` gets code execution in the running process on the next tick. Don't run a dev build from a world-writable directory, and don't ship dev builds in production.

Hot-reload (and the cwd-relative `src/runtime/?.fnl` / `vendor/fennel/?.lua` package paths it depends on) only activates when the dev binary is run from inside the redin source tree itself — detected by the presence of `src/cmd/redin/main.odin` in the working directory. A dev-flagged binary run from an external app directory still serves the HTTP endpoints, but does not watch any files.

**The bearer token is a capability.** Any holder can dispatch events, which means any app-registered `:shell` or `:http` effect is one authenticated POST away from arbitrary shell execution or network access in the user's context. The token is 0600 and per-run, so this only matters if the token leaks — but plan accordingly when wiring `:shell` handlers.

---

## Read endpoints

### `GET /frames` -- full frame tree

```bash
curl -H "$AUTH" http://localhost:$PORT/frames
```

Response: the full frame tree as JSON. Calls `view.get-last-push` in Lua to retrieve the last rendered frame. Each node's attrs object includes a `"rect":[x,y,w,h]` field from the most recent layout pass. Tests use this to resolve element coordinates without hard-coding positions.

### `GET /state` -- full app-db

```bash
curl -H "$AUTH" http://localhost:$PORT/state
```

Response: JSON-serialized Lua state table.

### `GET /state/:path` -- nested value

Dot-separated path. Segments are string keys into the Lua state table.

```bash
curl -H "$AUTH" http://localhost:$PORT/state/items.text
```

### `GET /aspects` -- theme table

```bash
curl -H "$AUTH" http://localhost:$PORT/aspects
```

Response: full theme as JSON object (serialized from host-side `Theme` structs).

### `GET /selection` -- active text selection

```bash
curl -H "$AUTH" http://localhost:$PORT/selection
```

Response: a JSON object describing the current text selection. When nothing is selected, returns `{"kind":"none"}`. Otherwise returns the selection kind plus its source node path and resolved text range.

### `GET /window` -- current window size

```bash
curl -H "$AUTH" http://localhost:$PORT/window
```

Response: `{"width": N, "height": N}` — the current Raylib screen dimensions in pixels.

### `GET /profile` -- frame timing ring buffer

Returns frame-timing samples from the ring buffer. Requires the binary to be built with `-define:REDIN_DEV=true` (for the server) and `-define:REDIN_PROFILE=true` (to enable collection). When the binary was built without `-define:REDIN_PROFILE=true`, the route returns `404 "profile not enabled"`.

**Example response:**

```json
{
  "enabled": true,
  "frame_cap": 120,
  "count": 120,
  "phases": ["input", "bridge", "layout", "render", "devserver"],
  "frames": [
    {"idx": 4820, "total_us": 14230, "phase_us": [310, 8420, 1890, 3480, 130]}
  ]
}
```

- `frame_cap` -- ring size (fixed at 120 frames, ~2 seconds at 60 FPS).
- `count` -- number of samples currently in the ring (grows from 0 to `frame_cap`).
- `phases` -- phase names in positional order; matches each frame's `phase_us` array.
- `frames` -- oldest first, newest last.
- `idx` -- monotonic frame counter since process start.
- Units: microseconds.

The sum of `phase_us` may be less than `total_us` because glue code between phases (event bookkeeping, temp_allocator reset, hotreload check) and the Raylib vsync wait inside `EndDrawing` are not attributed to any phase.

**Build flag:** `-define:REDIN_PROFILE=true` activates collection and the on-screen overlay (top-right corner). Press `F3` at runtime to hide/show the overlay without restarting. The overlay is independent of `-define:REDIN_DEV=true` -- you can build with `-define:REDIN_PROFILE=true` alone for local eyeballing or combine both flags to expose the endpoint.

### `GET /screenshot` -- PNG capture

```bash
curl -H "$AUTH" http://localhost:$PORT/screenshot -o screenshot.png
```

Returns binary PNG. Content-Type: `image/png`. Captures the current Raylib window.

---

## Write endpoints

### `POST /events` -- dispatch an event

The JSON body is the event vector itself — the first element is the event name, and any remaining elements are positional args. The handler decodes it, wraps it in a one-element list, and hands it to the Fennel-side `view.deliver-events`.

```bash
curl -X POST -H "$AUTH" http://localhost:$PORT/events \
  -H 'Content-Type: application/json' \
  -d '["counter/inc"]'
```

```bash
curl -X POST -H "$AUTH" http://localhost:$PORT/events \
  -H 'Content-Type: application/json' \
  -d '["todo/add","Buy milk"]'
```

Response: `{"ok": true}`

### `POST /click` -- synthetic click

Hit-tests at the given pixel coordinate and dispatches through input handling.

```bash
curl -X POST -H "$AUTH" http://localhost:$PORT/click \
  -H 'Content-Type: application/json' \
  -d '{"x": 400, "y": 300}'
```

Response: `{"ok": true}`

Queues a `MouseEvent` with `button = LEFT` into the input event queue.

### `POST /resize` -- resize the window

```bash
curl -X POST -H "$AUTH" -d '{"width":1280,"height":800}' \
  http://localhost:$PORT/resize
```

Response: `{"ok": true}` on success; `400` if the body is not a JSON object or either dimension is outside `[100, 8192]`. Calls `rl.SetWindowSize`.

### `POST /maximize` -- maximize the window

```bash
curl -X POST -H "$AUTH" http://localhost:$PORT/maximize
```

Response: `{"ok": true}`. Calls `rl.MaximizeWindow`.

### `POST /restore` -- restore the window from maximized

```bash
curl -X POST -H "$AUTH" http://localhost:$PORT/restore
```

Response: `{"ok": true}`. Calls `rl.RestoreWindow`.

### `POST /shutdown` -- graceful shutdown

```bash
curl -X POST -H "$AUTH" http://localhost:$PORT/shutdown
```

Response: `{"ok": true}`

Sets `shutdown_requested = true` on the dev server.

### `PUT /aspects` -- replace theme

```bash
curl -X PUT -H "$AUTH" http://localhost:$PORT/aspects \
  -H 'Content-Type: application/json' \
  -d '{"button": {"bg": [76, 86, 106], "radius": 6}}'
```

Response: `{"ok": true}`

Decodes the JSON body and calls `theme.set-theme` in Lua, replacing the entire theme.

Errors: `400 {"error":"invalid JSON"}` for an unparseable body,
`400 {"error":"body must be a JSON object"}` for a valid-JSON non-object,
`500 {"error":"set-theme failed"}` when the Lua call errors.

### `POST /input/takeover` -- take over mouse polling

```bash
curl -X POST -H "$AUTH" http://localhost:$PORT/input/takeover
```

Response: `{"ok": true}`. Flips a flag so raylib mouse polls are ignored; position and button states come from the override instead. Returns `409` if takeover is already active.

### `POST /input/release` -- restore raylib mouse polling

```bash
curl -X POST -H "$AUTH" http://localhost:$PORT/input/release
```

Response: `{"ok": true}`. Restores raylib polling and clears all override state.

### `POST /input/mouse/move` -- set override position

Requires takeover to be active.

```bash
curl -X POST -H "$AUTH" -d '{"x":50,"y":80}' http://localhost:$PORT/input/mouse/move
```

Response: `{"ok": true}`.

### `POST /input/mouse/down` -- press a mouse button

Requires takeover. Flips the held-state and synthesises a press edge for the next input poll.

```bash
curl -X POST -H "$AUTH" -d '{"button":"left"}' http://localhost:$PORT/input/mouse/down
```

`button` is one of `"left"`, `"right"`, `"middle"`. Returns `409` if that button is already down.

### `POST /input/mouse/up` -- release a mouse button

Requires takeover. Flips the held-state and synthesises a release edge.

```bash
curl -X POST -H "$AUTH" -d '{"button":"left"}' http://localhost:$PORT/input/mouse/up
```

Returns `409` if that button is already up.

### `POST /input/key` -- synthesise a key event

Does **not** require takeover — keys are event-driven, not continuous polling.

```bash
curl -X POST -H "$AUTH" -d '{"key":"escape"}' http://localhost:$PORT/input/key
```

Body: `{"key": "<name>", "mods": [...]}`. Synthesises a single `KeyEvent` delivered on the next input poll.

---

### Worked example: drive a drag from a test

```bash
PORT=$(cat .redin-port); TOKEN=$(cat .redin-token)
H="Authorization: Bearer $TOKEN"
curl -sH "$H" -X POST http://localhost:$PORT/input/takeover
curl -sH "$H" -X POST -d '{"x":50,"y":50}'   http://localhost:$PORT/input/mouse/move
curl -sH "$H" -X POST -d '{"button":"left"}' http://localhost:$PORT/input/mouse/down
curl -sH "$H" -X POST -d '{"x":80,"y":50}'   http://localhost:$PORT/input/mouse/move
curl -sH "$H" -X POST -d '{"button":"left"}' http://localhost:$PORT/input/mouse/up
curl -sH "$H" -X POST http://localhost:$PORT/input/release
```

---

## Agent channel (REDIN_AGENT only)

These endpoints are compiled in only when the binary is built with
`-define:REDIN_AGENT=true`. Without that flag the routes return 404.
When the flag is set, the dev-server listener starts automatically.

```bash
odin build src/cmd/redin -collection:lib=lib -collection:luajit=vendor/luajit \
    -define:REDIN_AGENT=true -out:build/redin
```

### `GET /agent/nodes` -- list agent-tagged nodes

```bash
curl -H "$AUTH" http://localhost:$PORT/agent/nodes
```

Response: JSON array of `{id, mode, type}` objects for every node
whose attributes include both `:agent` (`:read` or `:edit`) and `:id`.
Canvas nodes are silently excluded.

### `GET /agent/content/<id>` -- read node content

```bash
curl -H "$AUTH" http://localhost:$PORT/agent/content/reply
```

Response: `{"content": <string-or-array>}`. Returns `404` if no
agent-tagged node with the given id exists in the last pushed frame.

### `PUT /agent/content/<id>` -- write node content

Body: `{"content": <string-or-array>}`.

```bash
PORT=$(cat .redin-port); TOKEN=$(cat .redin-token)
curl -H "Authorization: Bearer $TOKEN" \
     -X PUT -d '{"content":"**Answer:** 4"}' \
     http://localhost:$PORT/agent/content/reply
```

Response: `{"ok": true}`. Dispatches `:event/agent-edit {id "<id>" content <value>}` into the Fennel event queue. The framework stores the value in `db.agent[id]`; the next render swaps the node's content with the stored value.

Error codes: `404` — id not found; `403` — node is `:agent :read` (not editable); `400` — malformed body.

---

## Not implemented

The following endpoints from the previous design are **not** present:

- No WebSocket (`/ws`)
- No `GET /frames/:id` (subtree by id)
- No `PUT /frames/:id` (frame injection)
- No `POST /type` (type text)
- No `POST /input` (set input value by id)
- No `POST /focus` (focus an element)
- No `/bindings` endpoint
