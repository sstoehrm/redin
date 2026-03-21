# redin — a re-frame inspired desktop UI framework

Odin + Raylib render engine. Fennel + Lua scripting layer.
The core idea: **UI is a pure data problem**.

## Architecture

```
Fennel (app code)
  │
  ▼
Lua VM  ──  app-db (single state table)
  │
  ├──▶ interactions (path → event mapping)
  ├──▶ aspects (theme / design tokens)
  ▼
Frames (pure visual data, Lua tables)
  │
  ├──▶ Odin/Raylib renderer  ──▶ pixels on screen
  ├──▶ redin server ◄──────────── AI agent (read/inject frames)
  └──▶ test harness (assert on pure data)
```

## Three layers

A view function returns three things, cleanly separated:

```fennel
{:frame   [...]   ;; pure visual tree — what to draw
 :bind    [...]   ;; interactions — what responds to input
 :aspects [...]   ;; which design tokens to apply
}
```

### 1. Frames (visual data)

Frames describe **what to draw**. Nothing else. No callbacks, no behavior.

```fennel
[:vbox {:aspect :surface :gap 8}
  [:text {:aspect :heading} "counter"]
  [:hbox {:gap 4}
    [:text {:id :count :aspect :display} "42"]
    [:rect {:id :inc-btn :aspect :button} [:text {} "+"]]
    [:rect {:id :dec-btn :aspect :button} [:text {} "-"]]]]
```

Frames are:
- Serializable (Lua tables / JSON)
- Diffable (for tests: `deep=` on two frames)
- Readable by AI (structured, no opaque callbacks)
- Addressable by `:id` for binding interactions and AI injection

#### Element catalog (minimal)

| element   | purpose                |
|-----------|------------------------|
| `:text`   | text run               |
| `:rect`   | rectangle / container  |
| `:image`  | texture from path      |
| `:hbox`   | horizontal layout      |
| `:vbox`   | vertical layout        |
| `:scroll` | scrollable container   |
| `:input`  | text field (visual)    |

#### Attributes (visual only)

```
:id                                   — identity for binding + AI targeting
:aspect                               — design token name (see aspects)
:width :height :min-width :max-width  — dimensions (px, :fill, :hug)
:padding :gap                         — spacing
:visible                              — conditional display
```

No `:color`, `:bg`, `:font-size` on elements directly — those come from aspects.

### 2. Bindings (interaction map)

Bindings connect **paths** (element ids) to **events**. Separate from the frame.

```fennel
[{:path :inc-btn  :action :click  :event [:counter/inc]}
 {:path :dec-btn  :action :click  :event [:counter/dec]}
 {:path :count    :action :hover  :event [:counter/tooltip]}
 {:path :query    :action :change :event [:search/update]}
 {:path :query    :action :submit :event [:search/go]}]
```

This separation means:
- The frame is **pure visual data** — no functions, no closures
- Interactions are **declarative** — an AI can read "what is clickable" without parsing callbacks
- The same frame can be rebound to different interactions (reuse, testing)
- Actions are a closed set: `:click`, `:hover`, `:change`, `:submit`, `:focus`, `:blur`, `:key`

### 3. Aspects (design system)

Aspects replace CSS/inline styles. They are **named bundles of visual properties** — the design system as data.

```fennel
;; theme definition
{:surface    {:bg [30 30 40] :padding 16 :radius 4}
 :heading    {:font-size 24 :color [255 255 255] :weight :bold}
 :display    {:font-size 48 :color [200 220 255] :font :mono}
 :button     {:bg [60 60 80] :padding [8 16] :radius 4 :color [255 255 255]}
 :button.hover {:bg [80 80 110]}
 :input      {:bg [20 20 30] :border [60 60 80] :padding [8 12] :color [255 255 255]}
 :input.focus {:border [100 120 255]}
 :danger     {:color [255 80 80]}
 :muted      {:color [120 120 140]}}
```

Key properties:
- **Composable** — an element can have multiple aspects: `{:aspect [:button :danger]}` merges right-to-left
- **Stateful variants** — `button.hover`, `input.focus` are resolved by the renderer based on interaction state. The app code never manages hover/focus styling.
- **Themeable** — swap the aspect table, the entire app changes look. Light/dark is just two aspect maps.
- **Inspectable** — an AI can read the full aspect map to understand the design language

#### Aspect properties

```
:bg :color :border               — colors as [r g b] or [r g b a]
:font-size :font :weight         — typography
:padding :radius                 — spacing and shape
:border-width                    — stroke
:opacity                         — transparency
```

Elements **never** set these directly. All visual styling goes through aspects.

## Data flow

```
event ──▶ handler ──▶ new app-db ──▶ subscriptions ──▶ view fn
                                                         │
                                                    ┌────┴────┐
                                                    │  frame  │  (visual tree)
                                                    │  bind   │  (interaction map)
                                                    │  aspects│  (design tokens)
                                                    └────┬────┘
                                                         │
                                                    ┌────┴────┐
                                                    │ renderer│──▶ pixels
                                                    │ server  │◄─▶ AI
                                                    │ tests   │──▶ assertions
                                                    └─────────┘
```

1. **app-db** — single Lua table. The entire application state.
2. **events** — `[:counter/inc]` style vectors. Pure data, logged, replayable.
3. **handlers** — `(fn [db event] new-db)`. Pure functions. No side effects.
4. **effects** — handlers can return an fx map: `{:db new-db :http {...}}`. The runtime executes effects.
5. **subscriptions** — derived views of app-db. Memoized.
6. **view functions** — return `{:frame ... :bind ... :aspects ...}`. Pure data out.

## The redin server

The host runs an HTTP/WebSocket server on localhost. This is the AI's interface — and also useful for dev tools, remote inspection, and testing.

### Endpoints

```
GET  /frames                — list all named frames
GET  /frames/:id            — read a frame subtree by element id
PUT  /frames/:id            — inject/replace a frame subtree at element id
GET  /state                 — read full app-db
GET  /state/:path           — read a nested path in app-db
POST /events                — dispatch an event
GET  /bindings              — read all active bindings
GET  /aspects               — read the current aspect map
PUT  /aspects               — replace the aspect map (live theme swap)
WS   /ws                    — stream: frame updates, events, state changes
```

### AI interaction patterns

**Read what the user sees:**
```json
GET /frames
→ {"frame": ["vbox", {"aspect": "surface"}, ...], "bind": [...]}
```

**Inject UI into a target area:**
```json
PUT /frames/ai-panel
← {"frame": ["vbox", {}, ["text", {"aspect": "heading"}, "suggestion"], ...]}
```

The app reserves a frame slot (e.g. `:id :ai-panel`) where the AI can inject content. The AI writes pure frame data — same format as the app itself. The renderer draws it like any other frame.

**Dispatch interaction:**
```json
POST /events
← {"event": ["counter/inc"]}
```

**Watch live:**
```
WS /ws
→ {"type": "frame", "data": [...]}
→ {"type": "state", "path": ["counter"], "value": 43}
→ {"type": "event", "data": ["counter/inc"]}
```

### Frame injection rules

- AI can only write to elements marked with `:ai true` in the frame
- Injected frames go through the same aspect system (AI uses the app's design tokens)
- Injected frames can include bindings (AI can make its content interactive)
- The app decides where AI panels live — the AI fills them

## Testing

Frames are pure data — test without rendering:

```fennel
(let [db {:counter 5}
      result (views.counter db)]
  ;; test the visual output
  (assert (deep= result.frame
    [:vbox {:aspect :surface :gap 8}
      [:text {:aspect :heading} "counter"]
      [:text {:id :count :aspect :display} "5"]]))
  ;; test that interactions are wired up
  (assert (some #(= $.path :inc-btn) result.bind)))
```

Handlers are pure functions:

```fennel
(let [db {:counter 5}
      new-db (handlers.counter-inc db [:counter/inc])]
  (assert (= new-db.counter 6)))
```

Aspects are data — test the design system:

```fennel
(let [theme (themes.dark)]
  (assert (= (. theme :button :radius) 4))
  (assert (not= (. theme :button :bg) (. theme :surface :bg))))
```

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

## Non-goals (for now)

- Accessibility
- Multi-window
- GPU shaders
- Animation (beyond aspect state transitions)
- Persistent storage (beyond simple file effects)

## Principles

1. **Data > functions > macros.** Prefer plain tables over abstractions.
2. **Frames are visual. Bindings are behavioral. Aspects are aesthetic.** Three concerns, three data structures.
3. **Pure by default.** Side effects only through the fx system.
4. **One state atom.** If you need to know what the app is doing, print app-db.
5. **AI-native.** The server exposes the same data the renderer consumes. AI writes frames, not pixels.
6. **Design system, not styles.** No inline colors. Name your intentions.
