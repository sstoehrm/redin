# Dev Server Reference

HTTP server for inspecting and driving redin apps from external tools.

---

## Overview

Starts when the app is launched with `--dev`. Listens on `localhost:8800` (walks upward if busy).

Read endpoints reflect the last state pushed to the host. Write endpoints queue events into the main input channel as if they came from real user input.

Implementation: `src/host/bridge/devserver.odin`.

### Authentication

On startup the server generates a random 256-bit token and writes it to `./.redin-token` (mode 0600, removed on shutdown). Every non-OPTIONS request must include:

```
Authorization: Bearer <contents of .redin-token>
```

The server also verifies the `Host` header matches `localhost:<port>` or `127.0.0.1:<port>` to blunt DNS-rebinding attacks. CORS preflight is not served — the endpoint is intended for local tools, not browsers. Missing token → `401`; bad Host → `403`; OPTIONS → `405`.

All examples below assume:

```bash
PORT=$(cat .redin-port)
TOKEN=$(cat .redin-token)
AUTH="Authorization: Bearer $TOKEN"
```

---

## Read endpoints

### `GET /frames` -- full frame tree

```bash
curl -H "$AUTH" http://localhost:$PORT/frames
```

Response: the full frame tree as JSON. Calls `view.get-last-push` in Lua to retrieve the last rendered frame.

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

### `GET /profile` -- frame timing ring buffer

Returns frame-timing samples from the ring buffer. Requires `--dev` (for the server) and `--profile` (to enable collection). When the host is started without `--profile`, the route returns `404 "profile not enabled"`.

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

**CLI flag:** `--profile` activates collection and the on-screen overlay (top-right corner). Press `F3` at runtime to hide/show the overlay without restarting. The overlay is independent of `--dev` -- you can run `--profile` alone for local eyeballing or `--profile --dev` to expose the endpoint.

### `GET /screenshot` -- PNG capture

```bash
curl -H "$AUTH" http://localhost:$PORT/screenshot -o screenshot.png
```

Returns binary PNG. Content-Type: `image/png`. Captures the current Raylib window.

---

## Write endpoints

### `POST /events` -- dispatch an event

```bash
curl -X POST -H "$AUTH" http://localhost:$PORT/events \
  -H 'Content-Type: application/json' \
  -d '{"event": ["event/increment"]}'
```

Response: `{"ok": true}`

The JSON body is decoded into a Lua value and passed to the event system.

### `POST /click` -- synthetic click

Hit-tests at the given pixel coordinate and dispatches through input handling.

```bash
curl -X POST -H "$AUTH" http://localhost:$PORT/click \
  -H 'Content-Type: application/json' \
  -d '{"x": 400, "y": 300}'
```

Response: `{"ok": true}`

Queues a `MouseEvent` with `button = LEFT` into the input event queue.

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
