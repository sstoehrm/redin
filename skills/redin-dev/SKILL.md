---
name: redin-dev
description: Use when developing redin apps or modifying the redin framework. Covers architecture, node types, canvas API, theme system, testing, and dev server.
---

# redin Development Guide

Use this skill when building redin apps (Fennel or Lua) or extending the framework (Odin).

## Architecture

```
src/host/           Odin host (renderer, bridge, input)
  main.odin         Entry point, main loop
  render.odin       Raylib renderer, layout (draw_box, draw_text, viewport)
  bridge/           Lua/Fennel bridge
    bridge.odin     Host callbacks, Lua<->Odin conversion, canvas draw execution
    lua_api.odin    LuaJIT FFI bindings
    devserver.odin  HTTP dev server (--dev mode)
    hotreload.odin  File watcher for hot reload
    loader.odin     App file loading (.fnl via fennel.dofile, .lua via luaL_dofile)
  canvas/           Canvas provider system
    canvas.odin     Provider registry, lifecycle (start/update/suspend/stop)
  input/            Input handling
    input.odin      Event polling, listener extraction
    apply.odin      Focus/active state
    user_events.odin  Click, hover, key, change events
  types/            Shared types (Node, Theme, Anchor, Listener)
src/runtime/        Fennel runtime (loaded by bridge at startup)
  init.fnl          Bootstrap, wires dataflow->effects
  dataflow.fnl      State management with path-tracked subscriptions
  effect.fnl        Side effects (log, dispatch, dispatch-later, http)
  frame.fnl         Nested list flattening
  view.fnl          View runner (render tick, event delivery)
  theme.fnl         Theme storage, resolution, validation
  canvas.fnl        Fennel canvas API (register, ctx builder, command buffer)
```

## Node types

`NodeStack`, `NodeCanvas`, `NodeVbox`, `NodeHbox`, `NodeInput`, `NodeButton`, `NodeText`, `NodeImage`, `NodePopout`, `NodeModal`

## Frame format (Fennel)

```fennel
[:tag {:attr value ...} child1 child2 ...]
```

Examples:
```fennel
[:vbox {:aspect :surface :layout :center}
  [:text {:aspect :heading} "Hello"]
  [:button {:aspect :button :click [:event/inc]} "+1"]
  [:canvas {:provider :my-drawing :width :full :height 300}]]
```

## Layout system

Layout uses the Anchor enum: `top_left`, `top_center`, `top_right`, `center_left`, `center`, `center_right`, `bottom_left`, `bottom_center`, `bottom_right`.

- **Vbox**: vertical anchor = where children group is positioned vertically, horizontal anchor = how each child is aligned horizontally
- **Hbox**: horizontal anchor = where children group is positioned horizontally, vertical anchor = how each child is aligned vertically
- **Text**: both axes control text alignment within its rect
- Main-axis centering only applies when all children have explicit sizes (no fill nodes)

## Viewport (stack)

```fennel
[:stack {:viewport [[:top_left 0 0 :full :full]
                    [:bottom_center 0 0 :1_4 42]]}
  [:vbox {} ...]
  [:hbox {} ...]]
```

Format: `[anchor x y w h]` — 5 elements. Values: px number, `:full`, or `:M_N` fraction.

## Canvas API (Fennel/Lua)

### Drawing from scripting (no binary changes needed)

```fennel
(local canvas (require :canvas))

(canvas.register :my-drawing
  (fn [ctx]
    (ctx.rect 10 10 100 50 {:fill [200 100 50] :radius 4})
    (ctx.circle 200 150 30 {:fill [50 100 200]})
    (ctx.line 0 0 100 100 {:stroke [0 0 0] :width 2})
    (ctx.text 10 180 "hello" {:size 16 :color [0 0 0]})
    (ctx.ellipse 100 100 40 20 {:fill [0 0 255]})
    (ctx.polygon [[0 0] [100 0] [50 80]] {:fill [255 255 0]})
    (ctx.image 10 10 64 64 "asset-name")

    ;; Input queries (canvas-relative coordinates)
    (when (ctx.mouse-pressed?)
      (ctx.dispatch [:clicked {:x (ctx.mouse-x) :y (ctx.mouse-y)}]))

    ;; Read app state directly
    (let [count (subscribe :sub/counter)]
      (ctx.text 10 10 (tostring count) {:size 24 :color [255 255 255]}))))
```

Primitives: `rect`, `circle`, `ellipse`, `line`, `text`, `polygon`, `image`.
Input: `mouse-x`, `mouse-y`, `mouse-in?`, `mouse-down?`, `mouse-pressed?`, `mouse-released?`, `key-down?`, `key-pressed?`.
Style: `fill` = [r g b] or [r g b a], `stroke` = outline color, `stroke-width`, `radius` (rect corners).

### Native canvas (Odin, requires binary rebuild)

```odin
my_provider := canvas.Canvas_Provider{
    update = proc(rect: rl.Rectangle) {
        rl.DrawRectangleRec(rect, rl.Color{40, 40, 60, 255})
    },
}
canvas.register("my-provider", my_provider)
```

## Theme system

```fennel
(theme-mod.set-theme
  {:surface {:bg [46 52 64] :padding [24 24 24 24] :opacity 0.5}
   :heading {:font-size 24 :color [236 239 244] :weight 1}
   :button  {:bg [76 86 106] :color [236 239 244] :radius 6 :padding [8 16 8 16]}
   :button#hover {:bg [94 105 126]}
   :button#active {:bg [59 66 82]}
   :input#focus {:border [136 192 208]}})
```

- State variants use `#` notation: `button#hover`, `input#focus`
- Properties: `bg`, `color`, `border`, `border-width`, `radius`, `padding` [top right bottom left], `font-size`, `font`, `weight` (0=normal, 1=bold), `opacity` (0-1, affects bg alpha)

## Dataflow (re-frame pattern)

```fennel
;; State
(dataflow.init {:counter 0})

;; Handlers (pure functions: db, event -> db or effect map)
(reg-handler :event/inc
  (fn [db event] (update db :counter #(+ $1 1))))

;; Subscriptions (derived views of state)
(reg-sub :sub/counter (fn [db] (get db :counter)))

;; In view
(let [count (subscribe :sub/counter)] ...)

;; Dispatch
(dispatch [:event/inc])

;; Effects
(reg-handler :event/save
  (fn [db event]
    {:db (assoc db :saving true)
     :http {:url "..." :method :post :on-success :event/saved}
     :dispatch-later {:ms 1000 :dispatch [:event/timeout]}}))
```

## Dev server (--dev mode, port 8800)

| Method | Path | Description |
|--------|------|-------------|
| GET | /frames | Last pushed frame tree |
| GET | /state | Full app state |
| GET | /state/path.to.value | Nested state lookup |
| GET | /aspects | Current theme |
| GET | /screenshot | PNG screenshot |
| POST | /events | Dispatch event (JSON: `["event-name", payload]`) |
| POST | /click | Inject click (JSON: `{"x":N,"y":N}`) |
| POST | /shutdown | Graceful shutdown |
| PUT | /aspects | Replace theme |

## Testing

### Fennel unit tests
```bash
luajit test/lua/runner.lua test/lua/test_*.fnl
```

Pattern: `(local t {}) (fn t.test-name [] (assert ...)) t`

### UI integration tests (requires --dev mode)
```bash
./build/redin --dev test/ui/<component>_app.fnl &
bb test/ui/run.bb test/ui/test_<component>.bb
```

Uses `redin-test` framework: `get-frame`, `get-state`, `dispatch`, `find-element`, `assert-state`, `wait-for`.

### Build check
```bash
odin build src/host -out:build/redin
```

## Adding a new node type (framework development)

1. `src/host/types/view_tree.odin` — add struct + union variant
2. `src/host/bridge/bridge.odin` — add parsing case in `lua_read_node`
3. `src/host/render.odin` — add rendering case in `render_node`
4. `src/host/render.odin` — add `node_preferred_width` / `node_preferred_height` cases
5. `src/runtime/theme.fnl` — add to consumption table if it uses aspects
6. `test/ui/<component>_app.fnl` + `test/ui/test_<component>.bb` — UI test

## Adding a host function (framework development)

1. `src/host/bridge/bridge.odin` — write `proc "c" (L: ^Lua_State) -> i32` callback with `context = runtime.default_context()`
2. `src/host/bridge/bridge.odin` — register with `register_cfunc(b.L, "name", callback)` in `init` proc
3. Call from Fennel: `(redin.name ...)` or from Lua: `redin.name(...)`

## Key conventions

- String ownership in bridge: `strings.clone_from_cstring` for persisted strings, `string(lua_tostring_raw(...))` for transient reads
- Lua stack: every push needs a matching pop/defer-pop
- Host callbacks: `proc "c"` needs `context = runtime.default_context()` at the start
- Flat parallel arrays for view tree: `nodes[]`, `paths[]`, `parent_indices[]`, `children_list[]` (DFS order, i32 indices)
- `focused_idx` lives in the `input` package, read by `render` for cursor
- `node_rects` lives in `render`, passed as parameter to input functions

## Documentation

Full docs are in the `docs/` directory:
- `docs/core-api.md` — Frame format, events, host functions
- `docs/app-api.md` — Dataflow, subscriptions, effects
- `docs/guide/` — Quickstart, Fennel cheatsheet, Lua guide, building apps
- `docs/reference/` — Elements, theme, effects, canvas, dev server
