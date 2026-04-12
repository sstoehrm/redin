# Fennel Canvas 2D Drawing API

An immediate-mode 2D drawing API that lets Fennel code draw on canvas elements without modifying the Odin binary. Canvas draw functions are independent from the view/dataflow system — they run during the Odin render phase, read app-db directly via standard Lua table access, and dispatch events back through re-frame.

## Programming model

- **Immediate-mode:** Draw function is called every frame with a context object. No retained state on the framework side.
- **Command buffer:** Draw calls append to a Lua table. Odin reads the table after the function returns and executes Raylib calls. One buffer per frame, discarded after execution.
- **Isolated from view/dataflow:** Canvas draw functions are not part of the frame tree or effect system. They run in a separate phase (during Odin render, not during `render-tick`).
- **State:** Draw functions manage their own state via closures/upvalues. They read app-db directly. Writes to app-db go through `ctx.dispatch`.

## Registration & lifecycle

New Fennel module: `src/runtime/canvas.fnl`.

```fennel
(local canvas (require :canvas))

(canvas.register :my-chart
  (fn [ctx]
    (ctx.rect 10 10 80 40 {:fill [200 100 50]})
    (ctx.circle 200 150 30 {:fill [50 100 200]})))

(canvas.unregister :my-chart)
```

In the view, reference by name:

```fennel
[:canvas {:provider :my-chart :width 400 :height 300}]
```

### Call chain per frame

```
Odin render loop
  → canvas.process("my-chart", rect)
  → generic provider calls Lua: canvas._draw("my-chart", rect, input_state)
  → canvas.fnl looks up registered fn, builds ctx with empty _buffer, calls fn(ctx)
  → fn appends commands to ctx._buffer
  → canvas.fnl returns _buffer to Odin
  → Odin iterates buffer, applies coordinate offset, scissor clips, executes Raylib calls
```

The draw function runs **during the Odin render phase**, not during `render-tick`. It is called synchronously from the renderer.

## Context object

The `ctx` table passed to draw functions has drawing methods, input queries, and canvas dimensions.

### Drawing primitives

All coordinates are relative to canvas origin (0,0 = top-left of content area). Last argument is always an opts table.

```fennel
;; Rectangles
(ctx.rect x y w h {:fill [r g b] :stroke [r g b] :stroke-width 2 :radius 4})

;; Circles
(ctx.circle cx cy r {:fill [r g b] :stroke [r g b] :stroke-width 1})

;; Ellipses
(ctx.ellipse cx cy rx ry {:fill [r g b]})

;; Lines
(ctx.line x1 y1 x2 y2 {:stroke [r g b] :width 2})

;; Text
(ctx.text x y "hello" {:size 16 :color [r g b] :font "sans"})

;; Polygons (closed path from point list)
(ctx.polygon [[x1 y1] [x2 y2] [x3 y3]] {:fill [r g b] :stroke [r g b]})

;; Images (loaded by name)
(ctx.image x y w h "asset-name")
```

**Style rules:**
- `fill` fills the shape, `stroke` draws the outline. Both can be present.
- Colors are `[r g b]` or `[r g b a]`.
- `ctx.width` and `ctx.height` are read-only properties (content area dimensions from the Odin rect).

**Not in v1:** Transforms (translate/rotate/scale), gradients, clipping regions, bezier curves. These can be added later as new ctx methods — the command buffer approach makes extension straightforward.

### Input queries

All coordinates are canvas-relative. Input state is passed from Odin when invoking the draw function.

```fennel
;; Mouse position relative to canvas
(ctx.mouse-x)
(ctx.mouse-y)

;; Mouse buttons (default: left; accepts :right, :middle)
(ctx.mouse-down?)
(ctx.mouse-pressed?)    ;; pressed this frame
(ctx.mouse-released?)   ;; released this frame
(ctx.mouse-down? :right)
(ctx.mouse-pressed? :middle)

;; Mouse inside canvas bounds
(ctx.mouse-in?)

;; Keyboard (when canvas has focus)
(ctx.key-down? :space)
(ctx.key-pressed? :enter)

;; Dispatch into re-frame dataflow
(ctx.dispatch [:my-event {:x (ctx.mouse-x) :y (ctx.mouse-y)}])
```

**Focus:** Canvas receives keyboard events when focused (clicked on), using the existing `focused_idx` mechanism in the input package.

**Dispatch:** `ctx.dispatch` wraps the global `dispatch` function from dataflow. It is a direct call during the draw phase — it does not go through the command buffer.

## Command buffer format

Each draw call appends a sequential entry to `ctx._buffer`:

```fennel
;; ctx.rect internally does:
(table.insert ctx._buffer [:rect x y w h opts])

;; ctx.circle internally does:
(table.insert ctx._buffer [:circle cx cy r opts])
```

The buffer is a plain Lua sequential table. After the draw function returns, Odin reads it via the Lua C API:

```
for each entry in buffer:
  tag = entry[1]  (string)
  switch tag:
    "rect"    → read x,y,w,h,opts → rl.DrawRectangle / rl.DrawRectangleLines
    "circle"  → read cx,cy,r,opts → rl.DrawCircle / rl.DrawCircleLines
    "line"    → read x1,y1,x2,y2,opts → rl.DrawLineEx
    "text"    → read x,y,str,opts → rl.DrawTextEx
    "ellipse" → read cx,cy,rx,ry,opts → rl.DrawEllipse
    "polygon" → read points,opts → rl.DrawTriangleFan (triangulated)
    "image"   → read x,y,w,h,name → rl.DrawTexturePro
```

**Coordinate offset:** All coordinates in the buffer are canvas-relative. Odin offsets them by the canvas rect origin (`rect.x`, `rect.y`) before issuing Raylib calls.

**Scissor clipping:** The generic provider wraps all execution in `rl.BeginScissorMode` / `rl.EndScissorMode` using the canvas rect. Nothing draws outside canvas bounds.

**No persistence:** The buffer is rebuilt every frame. No caching, no diffing.

## Odin integration

### Generic Fennel canvas provider

One generic provider handles all Fennel-registered canvases. No per-registration provider instances on the Odin side.

When `canvas.register` is called from Fennel, it:
1. Stores the draw function in a Lua-side registry table (in `canvas.fnl`)
2. Calls a new host function `redin.canvas_register(name)` which registers the name with `canvas.register(name, fennel_provider)` where `fennel_provider` is always the same generic callback set

### Generic provider callbacks

- `start(rect)` — no-op
- `update(rect)` — calls `lua_canvas_draw(name, rect, input_state)`:
  1. Pushes `canvas._draw` onto the Lua stack
  2. Pushes name, rect dimensions (x, y, w, h), and input state table
  3. pcall
  4. Reads returned buffer table
  5. Iterates and executes Raylib commands with coordinate offset and scissor clipping
- `suspend()` — no-op
- `stop()` — no-op (only called during Odin shutdown via `canvas.destroy`; Lua state is already being torn down)

### Unregister flow

**From Fennel** (`canvas.unregister :name`):
1. Removes draw function from the Lua-side registry table
2. Calls `redin.canvas_unregister(name)` which calls `canvas.unregister(name)` on the Odin side (removes from the Odin provider map, no callback into Lua)

**From Odin shutdown** (`canvas.destroy`):
1. Calls `stop()` on all providers (no-op for the generic Fennel provider)
2. Lua state is torn down separately by bridge.destroy

### New host functions

- `redin.canvas_register(name)` — registers the name with the Odin canvas system using the generic provider
- `redin.canvas_unregister(name)` — unregisters from the Odin canvas system and cleans up

### Files

**New:**
- `src/runtime/canvas.fnl` — Fennel module: `register`, `unregister`, ctx builder, `_draw` entry point

**Modified:**
- `src/host/bridge/bridge.odin` — add `redin.canvas_register`, `redin.canvas_unregister` host functions; add `lua_canvas_draw` function that builds input state, calls Lua, reads command buffer, executes Raylib commands
- `src/runtime/init.fnl` — require and wire up the canvas module

No new Odin files. The generic provider logic lives in `bridge.odin` and registers into the existing `canvas.odin` system.

## Example: interactive painter

```fennel
(local canvas (require :canvas))

(var points [])

(canvas.register :painter
  (fn [ctx]
    ;; Add points on click
    (when (ctx.mouse-pressed?)
      (table.insert points [(ctx.mouse-x) (ctx.mouse-y)])
      (ctx.dispatch [:point-added {:count (length points)}]))

    ;; Draw background
    (ctx.rect 0 0 ctx.width ctx.height {:fill [240 240 240]})

    ;; Draw all points
    (each [_ p (ipairs points)]
      (ctx.circle (. p 1) (. p 2) 5 {:fill [255 50 50]}))

    ;; Cursor preview
    (when (ctx.mouse-in?)
      (ctx.circle (ctx.mouse-x) (ctx.mouse-y) 5
        {:stroke [100 100 100] :stroke-width 1}))))
```
