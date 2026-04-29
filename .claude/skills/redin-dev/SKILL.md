---
name: redin-dev
description: Use when developing redin apps or modifying the redin framework. Covers architecture, node types, canvas API, theme system, testing, and dev server.
---

# redin Development Guide

Use this skill when building redin apps (Fennel or Lua) or extending the framework (Odin).

## Architecture

```
src/cmd/redin/      Thin CLI entry (package main)
  main.odin         Arg parsing, --track-mem setup, calls redin.run
src/redin/          Importable framework (package redin)
  runtime.odin      Public API: set_window/set_size/set_title, on_init/
                    on_input/on_frame/on_shutdown hooks, run, request_shutdown
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

NodeText accepts `:selectable` (boolean, default `true`); set to `false` to opt the node out of mouse-selection.

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

## Scrolling

`:overflow :scroll-y` on vbox or `:overflow :scroll-x` on hbox clips children to the container rect and maps the mouse wheel to a per-element scroll offset (shift + vertical wheel → horizontal scroll).

- **scroll-y children** may omit `:height` — intrinsic height is measured recursively (text line count × line height; nested vbox sums; nested hbox/stack takes max).
- **scroll-x children** must set `:width`. No intrinsic width is computed. Missing width → 0-width render + stderr warning.
- Text nodes accept both; `:scroll-x` on text disables word-wrap and turns content into a single scrollable line.

## Viewport (stack)

```fennel
[:stack {:viewport [[:top_left 0 0 :full :full]
                    [:bottom_center 0 0 :1_4 42]]}
  [:vbox {} ...]
  [:hbox {} ...]]
```

Format: `[anchor x y w h]` — 5 elements. Values: px number, `:full`, or `:M_N` fraction.

## Animate attribute

Any element accepts an `:animate` map that draws a registered canvas provider at a host-relative rect. Same `[anchor x y w h]` syntax as viewport, but `w`/`h`/offset are resolved against the host element's size, not the screen.

```fennel
[:button {:click [:dismiss]
          :animate {:provider :star-blink
                    :rect [:top_left -4 -4 16 16]
                    :z :above}}        ;; :above (default) or :behind
  "Dismiss"]
```

Click-through: the decoration's rect never enters the hit-test arrays, so clicks land on the host. Same canvas registry as `:canvas` — providers are the animation engine, the framework just positions them. Unknown provider names silently no-op; malformed `:rect` warns at parse time and skips drawing.

## Drag-and-drop attributes

`vbox` and `hbox` accept three universal attributes, all sharing `[tags {options} ?payload]`:

- `:draggable [tags {options} payload]` — what the element IS while dragged. Required: `:event`. Optional: `:mode` (`:preview` (default, clone-at-cursor) | `:none`), `:aspect`, `:animate`.
- `:dropable [tags {options} payload]` — what the element ACCEPTS. Required: `:event`. Optional: `:aspect`, `:animate`.
- `:drag-over [tags {options}]` — container-level zone (no payload). Optional: `:event` (fires `{:phase :enter}` / `{:phase :leave}`), `:aspect`, `:animate`.

Tags = single keyword (`:item`) or vector (`[:item :sword]`); a draggable and a dropable interact when their tag sets intersect. Visual feedback is via `:aspect` swap (no `#`-cascade). Events: drag-start fires `{:value <payload>}`, drop fires `{:from <src> :to <dst>}`.

```fennel
[:vbox {:overflow :scroll-y
        :aspect :muted
        :drag-over [:row-drag {:event :event/over :aspect :muted-armed}]}
  (icollect [i item (ipairs items)]
    [:hbox {:aspect :row
            :draggable [:row-drag {:mode :preview
                                   :event :event/drag
                                   :aspect :row-dragging} i]
            :dropable [:row-drag {:event :event/drop
                                  :aspect :row-drop-hot} i]}
      ...])]
```

### Drag handles

When a draggable container has interactive children (text that should be selectable, buttons), the click winner is the deepest hit — usually the text — so dragging-by-row-body breaks. Use a drag handle:

```fennel
[:hbox {:draggable [:row-drag {:handle false :event :event/drag} payload]
        :dropable  [:row-drag {:event :event/drop} payload]}
 [:vbox {:width 24 :aspect :grip :drag-handle true}]   ;; grab surface
 [:text {} item.text]                                  ;; selectable
 [:button {:click :remove} "x"]]                       ;; clickable
```

`:handle false` on the draggable opts the container out; `:drag-handle true` on any descendant marks it as a grab surface for the nearest `:draggable` ancestor. `:handle true` (default) keeps the container as a grab surface and makes any handles additive.

`:drag-handle` is allowed on `:vbox`, `:hbox`, and `:button`. On a button, it is mutually exclusive with `:click` (parser warns, drops `:click`).

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
- Properties: `bg`, `color`, `border`, `border-width`, `radius`, `padding` [top right bottom left], `font-size`, `font`, `weight` (0=normal, 1=bold), `line-height` (ratio, e.g. 1.5), `opacity` (0-1, affects bg alpha), `shadow` `[x y blur [r g b a]]` (drop shadow; consumed by vbox/hbox/button/popout/canvas)
- `:selection` controls the selection highlight color for both `:input` nodes and `:text` nodes (text selection added on feat/text-highlight)

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

## Dev server (--dev mode, default port 8800)

Authenticated: every non-OPTIONS request needs `Authorization: Bearer <token>`, where the token is written to `./.redin-token` on startup (0600, deleted on shutdown). The `Host` header must also be `localhost:<port>` or `127.0.0.1:<port>`. Bound port is in `./.redin-port`.

```bash
PORT=$(cat .redin-port); TOKEN=$(cat .redin-token)
curl -H "Authorization: Bearer $TOKEN" http://localhost:$PORT/state
```

| Method | Path | Description |
|--------|------|-------------|
| GET | /frames | Last pushed frame tree |
| GET | /state | Full app state |
| GET | /state/path.to.value | Nested state lookup |
| GET | /aspects | Current theme |
| GET | /selection | Current text/input selection: `{kind: none\|input\|text, start, end, text}` |
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

# Or run the whole suite:
bash test/ui/run-all.sh             # windowed
bash test/ui/run-all.sh --headless  # xvfb-run, for CI / no display (requires xvfb)
```

Uses `redin-test` framework: `get-frame`, `get-state`, `dispatch`, `find-element`, `assert-state`, `wait-for`.

### Build check
```bash
odin build src/cmd/redin -collection:lib=lib -collection:luajit=vendor/luajit -out:build/redin
```

## Adding a new node type (framework development)

1. `src/redin/types/view_tree.odin` — add struct + union variant
2. `src/redin/bridge/bridge.odin` — add parsing case in `lua_read_node`
3. `src/redin/render.odin` — add rendering case in `render_node`
4. `src/redin/render.odin` — add `node_preferred_width` / `node_preferred_height` cases
5. `src/runtime/theme.fnl` — add to consumption table if it uses aspects
6. `test/ui/<component>_app.fnl` + `test/ui/test_<component>.bb` — UI test

## Adding a host function

### From user code (preferred — `--native` projects)

In `app.odin`, register before or after `redin.run`:

```odin
my_cfunc :: proc(L: ^bridge.Lua_State) -> i32 {
    // No `proc "c"`, no manual context. The bridge's trampoline already
    // set `context = bridge.host_context()` before calling.
    n := lua_tointeger(L, 1)
    // ...
    return 0  // number of return values pushed onto the stack
}

main :: proc() {
    bridge.register_cfunc("my_cfunc", my_cfunc)
    // ...
    redin.run(cfg)
}
```

Pre-`redin.run` registrations are buffered and flushed inside `bridge.init`. From Fennel: `(redin.my_cfunc ...)`. From Lua: `redin.my_cfunc(...)`.

For `proc "c"` cfuncs (escape hatch — usually not needed), use `bridge.register_cfunc_raw` and call `context = bridge.host_context()` yourself at entry.

### From the framework (in-tree contributors only)

1. `src/redin/bridge/bridge.odin` — write `proc "c" (L: ^Lua_State) -> i32` callback with `context = g_context`
2. `src/redin/bridge/bridge.odin` — add `register_cfunc_init(b.L, "name", callback)` line inside the `init` proc, between `lua_newtable(b.L)` and `lua_setglobal(b.L, "redin")`
3. Call from Fennel: `(redin.name ...)` or from Lua: `redin.name(...)`

## Bridge API for native code

`package bridge` (importable from user `app.odin`) exposes:

| Proc | Use |
|---|---|
| `bridge.register_cfunc(name, fn: proc(L) -> i32)` | Register a Lua cfunc with a regular Odin proc. Trampoline auto-sets context. Safe before or after `bridge.init`. |
| `bridge.register_cfunc_raw(name, fn: Lua_CFunction)` | Same but takes `proc "c"` directly. Caller manages context. |
| `bridge.host_context() -> runtime.Context` | The runtime context the bridge captured at init. Only needed by `register_cfunc_raw` callers. |
| `bridge.push(L, value: any)` | Marshaller: Odin → Lua. Supports primitives, slices, arrays, dynamic arrays, maps, structs, unions, pointers, enums, any. Bails at depth 32 on cycles. |
| `bridge.dispatch(event, payload: any) -> (ok, err)` | Marshal payload + push to Fennel as `[:dispatch [:event-name payload]]`. Calls the matching `reg-handler`. |
| `bridge.dispatch_tos(L, event) -> (ok, err)` | Zero-copy: caller already pushed payload onto the stack (hot path, e.g. per-frame state). |

## redin-cli

Project manager for redin. Install: `curl -sL https://raw.githubusercontent.com/sstoehrm/redin-cli/main/install.sh | bash` (requires Babashka).

| Command | Description |
|---|---|
| `redin-cli new-fnl [--native] <name>` | Scaffold Fennel project (main.fnl, flsproject.fnl, .redin/, .claude/skills/). With `--native`, also drops `app.odin` + `build.sh` at project root for native Odin development. |
| `redin-cli new-lua [--native] <name>` | Scaffold Lua project. `--native` same as above. |
| `redin-cli update [version]` | Update redin binary + runtime in .redin/. Also refreshes .claude/skills/. |
| `redin-cli latest` | Print latest available version |
| `redin-cli help` | Show all commands, project structure, dev server endpoints |

`upgrade-to-native` is a deprecated alias for `new-fnl --native .` (or `new-lua --native .`); will be removed in a future release.

### Project structure (after new-fnl/new-lua, no `--native`)

```
my-app/
  .redin/          # binary + runtime + docs (gitignored)
  .claude/skills/  # Claude Code skill (extracted from .redin/)
  redinw           # wrapper script: exec .redin/redin "$@"
  main.fnl         # app code (or main.lua)
  flsproject.fnl   # Fennel linter config (or .luarc.json for Lua)
  .gitignore       # ignores .redin/
```

### Project structure (after new-fnl --native / new-lua --native)

The `--native` flag adds two user-owned files at project root and pulls
the redin source into `.redin/src/redin/` so `app.odin` can import it.

```
my-app/
  app.odin         # USER-OWNED: package main, calls redin.run(cfg)
  build.sh         # USER-OWNED: odin build . -collection:lib=.redin/lib ...
  build/           # native build output (gitignored)
  .redin/          # binary + runtime + source + docs (gitignored)
    src/redin/     # framework source — overwritten by `redin-cli update`
    lib/           # odin-http
    vendor/luajit/ # libluajit-5.1.a
    redin          # prebuilt binary fallback
  .claude/skills/
  redinw           # updated: prefers build/redin over .redin/redin
  main.fnl         # app code
```

The user owns `app.odin`. The framework lives in `.redin/` and is
overwritten by `redin-cli update` with no merge conflicts. Customize
the window, register canvas providers / Lua cfuncs / per-frame hooks
in `app.odin` before the call to `redin.run`:

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
    cfg.app = "main.fnl"
    for arg in os.args[1:] {
        switch arg {
        case "--dev":     cfg.dev = true
        case "--profile": cfg.profile = true
        case:             cfg.app = arg
        }
    }
    redin.run(cfg)
}
```

### Running

```bash
./redinw --dev main.fnl          # dev server + hot reload
./redinw main.fnl                # normal mode
./redinw --track-mem main.fnl    # memory leak tracking
./build.sh                        # (--native only) rebuild after editing app.odin
```

## Key conventions

- String ownership in bridge: `strings.clone_from_cstring` for persisted strings, `string(lua_tostring_raw(...))` for transient reads
- Lua stack: every push needs a matching pop/defer-pop
- Host callbacks: `proc "c"` needs `context = g_context` at the start (uses saved init context for tracking allocator compatibility)
- Flat parallel arrays (Structure of Arrays / SoA) for view tree: `nodes[]`, `paths[]`, `parent_indices[]`, `children_list[]` — DFS order, i32 indices. Any per-node side table (scroll offsets, intrinsic-height cache, `node_rects`) should be indexed by the same idx so lookups stay O(1) and invariants hold across packages. On re-flatten, Bridge's `clear_frame` must invalidate every idx-keyed side table.
- `focused_idx` lives in the `input` package, read by `render` for cursor
- `node_rects` lives in `render`, passed as parameter to input functions

## Documentation

Full docs are in the `docs/` directory:
- `docs/core-api.md` — Frame format, events, host functions
- `docs/app-api.md` — Dataflow, subscriptions, effects
- `docs/guide/` — Quickstart, Fennel cheatsheet, Lua guide, building apps
- `docs/reference/` — Elements, theme, effects, canvas, dev server
