# core API

The rendering data format, interaction model, theme system, host functions, and dev server interface.

## Overview

### Odin -> Fennel (host delivers input)

Odin collects all input and delivers it to Fennel through a single channel:

| Function               | Purpose                                             |
| ---------------------- | --------------------------------------------------- |
| `redin_events(events)` | Delivers pending input events to the Fennel context |

The `events` list contains all inputs since the last call:

| Event         | Format                   | Source              |
| ------------- | ------------------------ | ------------------- |
| Mouse click   | `[:click x y]`          | Raylib input        |
| Key press     | `[:key key mods]`       | Raylib input        |
| Character     | `[:char char]`          | Raylib input        |
| Window resize | `[:resize w h]`         | Raylib window       |
| AI dispatch   | `[:dispatch event]`     | Dev server POST /events |
| HTTP response | `[:http-response data]` | Async HTTP callback |

Fennel owns the entire dataflow loop: it receives events, runs handlers, recomputes subscriptions, and pushes new frames when ready.

**Server read endpoints** (GET /frames, /state, /aspects) read from the last state Fennel pushed to Odin. No Lua call needed for /aspects; /frames and /state call into Lua.

### Fennel -> Odin (scripts push state)

Functions available under the `redin` global table:

| Function                                             | Purpose                                          |
| ---------------------------------------------------- | ------------------------------------------------ |
| `redin.push(frame)`                                  | Push new frame tree to Odin for rendering        |
| `redin.set_theme(theme)`                             | Persist theme to Odin for native aspect resolution |
| `redin.log(...)`                                     | Print to stdout                                  |
| `redin.now()`                                        | Current Unix timestamp (float seconds)           |
| `redin.measure_text(text, font_size [, font_name])`  | Returns `(width, height)` using named or default font |
| `redin.http(id, url, method, headers, body, timeout)` | Queue async HTTP request (called by `:http` effect) |
| `redin.json_encode(value)`                           | Encode Lua value to JSON string                  |
| `redin.json_decode(string)`                          | Decode JSON string to Lua value                  |

### Fennel app API (scripts only)

Functions for building apps (see [app-api](app-api.md) for details):

| Function                       | Purpose                          |
| ------------------------------ | -------------------------------- |
| `dataflow.init(db)`            | Initialize app state             |
| `reg-handler(key, fn)`         | Register event handler           |
| `dispatch(event)`              | Dispatch event vector            |
| `reg-sub(key, fn)`             | Register subscription            |
| `subscribe(key)`               | Read subscription value          |
| `get(db, key)`                 | Tracked state read               |
| `get(db, key, default)`        | Tracked state read with fallback |
| `get-in(db, path [, default])` | Tracked nested state read        |
| `assoc(db, key, value)`        | Tracked state write              |
| `assoc-in(db, path, value)`    | Tracked nested state write       |
| `update(db, key, f)`           | Tracked state update             |
| `update-in(db, path, f)`       | Tracked nested state update      |
| `dissoc(db, key)`              | Tracked state remove             |
| `dissoc-in(db, path)`          | Tracked nested state remove      |
| `reg-fx(key, fn)`              | Register effect executor         |

---

## Security model

redin is a desktop framework, not a sandboxed runtime. The posture matches `python script.py` or any other interpreter you launch yourself: the script you run gets full local-user authority. This section spells out the consequences, since "I'll ship this app to a friend" is a tempting next step that requires more thought than people sometimes give it.

### Lua / Fennel app code

The `.fnl` (or `.lua`) file you pass on the command line runs in the same Lua state as redin's own runtime, with `luaL_openlibs` having loaded everything: `os`, `io`, `debug`, `package`, `ffi`. Anything your shell user can do, the app can do — read your home directory, spawn processes, dlopen system libraries, mutate global state.

This is by design and appropriate for a development framework. **It does mean redin should not be used to run untrusted `.fnl` files.** If you're considering distributing a redin app to someone else, package and audit the application code as you would any other native binary; treat it as code, not data.

The runtime's internal tables (`dataflow`, `effect`, `view`, etc.) are reachable from app code via `require`. Don't rely on them being private — they're "internal" by convention only.

### `redin.http` — unrestricted URLs

The `redin.http` host function (and the `:http` effect that wraps it) sends whatever URL the app constructs. There is no allowlist for loopback (`127/8`), link-local (`169.254/16`), RFC1918 (`10/8`, `172.16/12`, `192.168/16`), or `file://`. Any string that reaches the helper hits the network as-is.

For most apps this is fine — the app author chose the URL. If your app embeds third-party templates, plugin URLs, or anything that could turn a remote string into a request target, **sanitize before dispatching**. Server-side request forgery (SSRF) is otherwise on the table.

A 16 MiB cap on response bodies is enforced by the host (oversized announcements fail fast with a "Response body too large" error). Per-request wall-clock timeout is not yet wired through to the worker thread; the `:timeout` field on the effect is currently advisory.

### Dev server (`--dev`)

The dev server is the one place redin actively defends against external callers. It binds loopback only and requires a per-run Bearer token written to `./.redin-token` (mode 0600) plus a matching `Host` header to defend against DNS rebinding. See [Dev server](#dev-server-http) below for details.

Production builds (no `--dev`) don't run the server at all and have no listening sockets.

---

## Frame format

A frame is a nested array: `[tag, attrs, ...children]`.

- Position 1: element tag (keyword string)
- Position 2: attributes table (always present, `{}` if none)
- Position 3+: children (nested frames) or content (string for `text`, `button`)

```fennel
[:vbox {}
  [:text {:aspect :body} "hello"]
  [:hbox {}
    [:text {} "content"]]]
```

### Nested list flattening

Children that are nested lists (a table whose first element is a table, not a string tag) are automatically flattened into the parent's children. This enables loops and component functions that return multiple elements without a wrapper container:

```fennel
;; icollect returns a list -- flattened into vbox's children
[:vbox {}
  [:text {:aspect :heading} "Todos"]
  (icollect [_ item (ipairs items)]
    [:hbox {} [:text {} item.text]])
  [:text {:aspect :muted} "footer"]]

;; Component functions returning multiple elements
(fn status-icons [status]
  [[:text {:aspect :muted} status]
   [:text {:aspect :muted} "v1.0"]])

[:hbox {}
  [:text {} "File"]
  (status-icons "Ready")]
```

The flattening is a single pass when the frame enters the pipeline. No fragment operator or helper functions needed.

### Element tags

**Leaf nodes** (no children):

| Tag       | Purpose                                                | Status        | Required attrs |
| --------- | ------------------------------------------------------ | ------------- | -------------- |
| `text`    | Text content. Last positional arg is the string.       | implemented   | --             |
| `image`   | Texture from file.                                     | implemented   | `src`          |
| `input`   | Editable text field.                                   | implemented   | --             |
| `button`  | Clickable button. Last positional arg is the label.    | implemented   | --             |
| `canvas`  | Independent render region. Runs a registered provider. | implemented   | `provider`     |

**Container nodes** (have children):

| Tag      | Purpose                                                   | Status      | Required attrs |
| -------- | --------------------------------------------------------- | ----------- | -------------- |
| `stack`  | Overlapping children. Each child gets the full parent rect. | implemented | --           |
| `hbox`   | Horizontal flow. Children left to right.                  | implemented | --             |
| `vbox`   | Vertical flow. Children top to bottom.                    | implemented | --             |
| `modal`  | Full-screen overlay. Blocks interaction behind it.        | implemented | --             |
| `popout` | Anchored popup, escapes parent clipping.                  | implemented | --             |

### Attributes

**Common (all elements):**

| Attribute | Type                       | Notes                                   |
| --------- | -------------------------- | --------------------------------------- |
| `aspect`  | keyword or `[kw ...]`      | Theme reference. Single or composed list. |
| `width`   | px number or `"full"`      | Fixed size or fill remaining space      |
| `height`  | px number or `"full"`      | Fixed size or fill remaining space      |
| `layout`  | anchor keyword (see below) | Child alignment on vbox/hbox; text alignment on text. Default `"top_left"`. |

`:layout` takes one of nine two-axis anchors: `"top_left"`, `"top_center"`, `"top_right"`, `"center_left"`, `"center"`, `"center_right"`, `"bottom_left"`, `"bottom_center"`, `"bottom_right"`. On a `vbox`, the horizontal component aligns each child across the row (cross axis) and the vertical component positions the children group within the container's height (main axis); on an `hbox` the roles swap. On `text`, both components control alignment of the text within its rect. Main-axis centering only takes effect when every child has an explicit size. Unknown values fall back to `"top_left"`.

**Container-specific:**

| Attribute  | Type     | Applies to | Notes |
| ---------- | -------- | ---------- | ----- |
| `overflow` | string   | vbox, hbox, text | `"scroll-y"` (vbox/text) or `"scroll-x"` (hbox/text). Enables clipping + wheel scroll on the matching axis. See Scrolling below. |
| `viewport` | `[[anchor x y w h] ...]` | stack | Window-relative rects with anchor point, one per child. Anchor: `"top_left"`, `"top_center"`, `"top_right"`, `"center_left"`, `"center"`, `"center_right"`, `"bottom_left"`, `"bottom_center"`, `"bottom_right"`. Values for x/y/w/h: px, `"full"`, or `"M_N"` fraction. The anchor determines the origin and growth direction. |

**Element-specific:**

| Attribute  | Type                    | Applies to |
| ---------- | ----------------------- | ---------- |
| `provider` | keyword                 | canvas (registered provider name, required) |
| `click`    | event vector            | button (dispatched on click) |
| `change`   | event vector            | input (dispatched on text change) |
| `key`      | event vector            | input (dispatched on key press) |
| `mode`     | `"mouse"` `"fixed"`     | popout (positioning mode) |
| `x`        | number                  | popout (fixed position x) |
| `y`        | number                  | popout (fixed position y) |

**Rule:** Visual properties (`bg`, `color`, `border`, `font-size`, `font`, `weight`, `radius`, `border-width`, `opacity`, `shadow`, `line-height`, `padding`) belong in the theme only, never on elements.

### Animation

Any element may carry an `:animate` map that renders a registered canvas provider at a viewport-anchored rect relative to the host. Useful for corner ornaments — a blinking notification star, a soft glow behind a tile, a badge in the bottom-right.

```fennel
[:button {:animate {:provider :star-blink
                    :rect [:top_left -4 -4 16 16]
                    :z :above}}
  "Click me"]
```

| Field | Required | Type | Notes |
|---|---|---|---|
| `:provider` | yes | keyword or string | Name of a registered canvas provider (same registry as `:canvas`). |
| `:rect` | yes | 5-element vector | `[anchor x y w h]`, identical to the `:viewport` syntax on `:stack`. Negative `x`/`y` allowed for overhang outside the host. |
| `:z` | no | `:above` (default) or `:behind` | Draw order relative to the host element. |

The decoration is purely visual: clicks fall through to the host. The provider's `mouse-in?` / `mouse-pressed?` queries still work in canvas-local coordinates so the decoration can react visually to hover.

If the provider name isn't registered, `canvas.process` silently no-ops (same posture as a `:canvas` pointing at an unregistered name). Malformed `:rect` (wrong arity, unknown anchor token) prints a warning at parse time and the decoration is skipped — the host element renders normally.

### Sizing model

Single top-down pass. Parent tells children their size.

**Size values:**

- **px number** -- fixed pixels: `{:width 200}`
- **`"full"`** -- expand to consume remaining space. Multiple `"full"` siblings share equally.

Children without an explicit size default to `"full"`.

**Allocation order:**

1. Fixed-px children get their size
2. `"full"` children split whatever remains equally
3. Elements with `visible = false` are skipped entirely

**Current limitations:** Only basic vbox/hbox layout is implemented. Percentage sizing (`"N%"`), `min-width`/`min-height` clamping, responsive breakpoints, and `"fill"` (the old name for `"full"`) are not yet supported.

### Scrolling

`:overflow :scroll-y` on a vbox (or `:scroll-x` on an hbox) clips the content to the element's rect and maps the mouse wheel to a per-element scroll offset. Shift + vertical wheel is promoted to horizontal scroll.

The two axes handle child sizing differently:

- **`scroll-y` (vbox)** — children **do not** need an explicit `:height`. The renderer computes each child's intrinsic height by recursing: text uses wrapped-line count × line height; nested vbox sums its children; nested hbox/stack takes the max.
- **`scroll-x` (hbox)** — children **must** set `:width`. The renderer does not infer horizontal size from content. Children without an explicit width render at zero width and a warning is printed to stderr.

Text nodes with `:overflow :scroll-x` additionally disable word-wrap so the content forms a single long line that can scroll horizontally.

---

## Interaction model

Input handling uses **listeners** extracted from the node tree and theme, not a separate bindings table.

### How it works

Each frame, after `redin.push(frame)` delivers a new tree, the host:

1. Walks the flat node array
2. Extracts listeners based on node type and attributes:
   - `button` with a `click` attribute -> `ClickListener`
   - `input` -> `FocusListener` (always), plus `ChangeListener` if `change` attr set, `KeyListener` if `key` attr set
3. Checks the theme for state variants: if an element has an `aspect` and the theme contains `aspect#hover`, a `HoverListener` is added; similarly `aspect#focus` adds a `FocusListener`
4. On each input event, listeners are matched against hit-test results (node rects from the previous frame's layout)

### Listener types

| Listener          | Trigger                         | Effect                                  |
| ----------------- | ------------------------------- | --------------------------------------- |
| `ClickListener`   | Mouse click on node rect        | Dispatches the button's `click` event   |
| `FocusListener`   | Mouse click on node rect        | Sets keyboard focus to that node        |
| `HoverListener`   | Cursor over node rect           | Applies `aspect#hover` theme variant    |
| `KeyListener`     | Key press while node is focused | Dispatches the input's `key` event      |
| `ChangeListener`  | Character input while focused   | Dispatches the input's `change` event   |

### Focus

A single global `focused_idx` tracks which node has keyboard focus. Clicking a `FocusListener` node sets focus; clicking elsewhere clears it. The renderer uses focus state to look up `aspect#focus` theme variants (e.g. changed border color on a focused input).

---

## Theme (aspects)

The theme is a global flat map: `keyword -> property-table`. Elements reference aspects by name; they never carry visual properties directly.

```fennel
{:button       {:bg [76 86 106] :color [236 239 244] :radius 6 :padding [8 16]}
 :button#hover {:bg [94 105 126]}
 :danger       {:bg [191 97 106] :color [236 239 244]}
 :body         {:color [216 222 233] :font-size 14 :font :sans}}
```

### Properties

| Category   | Properties                                                           | Values                           |
| ---------- | -------------------------------------------------------------------- | -------------------------------- |
| Color      | `bg` `color` `border` `cursor` `selection` `placeholder` `scrollbar` | `[r g b]` or `[r g b a]`, 0--255 |
| Typography | `font-size`                                                          | px number                        |
|            | `font`                                                               | `"sans"` `"mono"` `"serif"`      |
|            | `weight`                                                             | `"normal"` `"bold"`              |
|            | `line-height`                                                        | ratio (e.g. 1.5)                 |
|            | `align`                                                              | `"left"` `"center"` `"right"`    |
| Shape      | `radius` `border-width`                                              | px number                        |
| Spacing    | `padding`                                                            | px or `[v h]` or `[t r b l]`     |
| Display    | `opacity`                                                            | 0--1                             |
|            | `shadow`                                                             | `[x y blur [r g b a]]`           |

**Host-side representation:** On the Odin side, theme entries are stored as `Theme` structs with fields for `bg`, `color`, `border`, `padding`, `border_width`, `radius`, `weight`, `font_size`, `line_height`, `font`, `opacity`, and `shadow`.

### Which elements consume which properties

```
            bg  color  border  font  padding  radius  border-w  opacity  shadow
text         .    x      .      x      .        .       .         x       .
image        .    .      .      .      .        .       .         x       .
hbox         x    .      .      .      x        .       .         x       x
vbox         x    .      .      .      x        .       .         x       x
input        x    x      x      x      x        x       x         x       .
button       x    x      .      x      x        x       .         x       x
modal        x    .      .      .      .        .       .         x       .
popout       x    .      x      .      x        x       x         x       x
canvas       x    .      x      .      x        x       x         x       x
```

Properties not consumed by an element are ignored silently.

### Aspect composition

An element can reference multiple aspects. They merge left-to-right (later wins):

```fennel
[:vbox {:aspect [:button :danger]} ...]
;; Start with :button props, overlay :danger props
```

### State variants

The renderer automatically resolves state variants by appending a `#` suffix:

| State    | Suffix      | Trigger             |
| -------- | ----------- | ------------------- |
| hover    | `#hover`    | Cursor over element |
| focus    | `#focus`    | Keyboard focus      |
| active   | `#active`   | Mouse down          |
| disabled | `#disabled` | Disabled element    |

Define only the properties that change:

```fennel
{:button       {:bg [76 86 106] :color [236 239 244]}
 :button#hover {:bg [94 105 126]}}
;; On hover: bg changes, color stays from :button
```

**Composed + state:** For `[:button :danger]` when hovered:

1. Resolve `:button`
2. Merge `:danger`
3. Merge `:button#hover` (if exists)
4. Merge `:danger#hover` (if exists)

Missing aspects resolve to `{}` (no error).

### Naming conventions

Aspects should be named by role, not appearance:

- **Surfaces:** `surface` `surface-alt` `surface-raised`
- **Typography:** `heading` `subheading` `body` `caption` `label` `mono` `display`
- **Interactive:** `button` `button-secondary` `button-ghost` `input`
- **Status:** `danger` `warning` `success` `info` `muted`
- **Structure:** `overlay` `scrollbar`

### Validation

```fennel
(local theme-mod (require :theme))
(theme-mod.validate theme)
;; => {:ok true}
;; or {:ok false :errors [{:aspect :button :property :bg :message "expected [r g b]"}]}
```

Checks: color format, enum membership (`font`, `weight`, `align`), opacity range, numeric types, padding format, shadow format.

---

## Host functions

Functions Odin exposes to the Lua VM under the `redin` global table. Available from any Fennel or Lua code.

> Extending this table from user Odin code (in `--native` projects) is documented separately in [`reference/native-bridge.md`](reference/native-bridge.md). Use `bridge.register_cfunc(name, fn)` to add `redin.<name>` entries at runtime without forking framework files.

### `redin.log(...)`

Print to stdout. Variadic, joins arguments with tabs.

```fennel
(redin.log "debug" some-value)
```

### `redin.now()`

Returns current Unix timestamp as a float (seconds).

```fennel
(local t (redin.now))
```

### `redin.measure_text(text, font_size [, font_name])`

Measures text dimensions. Returns width and height. If `font_name` is provided, uses that font; otherwise uses the default sans font.

```fennel
(let [(w h) (redin.measure_text "Hello" 14)]
  ...)
```

Delegates to Raylib's `MeasureTextEx`.

### `redin.set_theme(theme)`

Persists the theme table to the Odin side. Odin converts each aspect's properties to native `Theme` structs for direct use during rendering -- no Lua calls needed per node.

Call once at startup (from your app file) or when swapping themes at runtime.

```fennel
(local theme-mod (require :theme))
(theme-mod.set-theme
  {:surface      {:bg [46 52 64] :padding [24 24 24 24]}
   :heading      {:font-size 24 :color [236 239 244] :weight 1}
   :button       {:bg [76 86 106] :color [236 239 244] :radius 6 :padding [6 14 6 14]}
   :button#hover {:bg [94 105 126]}})
```

The `theme-mod.set-theme` wrapper calls `redin.set_theme` internally and also stores the theme on the Fennel side for aspect resolution.

### `redin.push(frame)`

Converts the Lua frame table to flat parallel arrays (DFS traversal) on the Odin side. The arrays are: paths, nodes, parent indices, and children lists. This is the primary interface for delivering UI to the renderer.

Called automatically by the view runner after `main_view` returns.

### `redin.http(id, url, method, headers, body, timeout)`

Queues an async HTTP request. The request runs on a background thread. When complete, the response is delivered as an `[:http-response data]` event where `data` is `{id, status, body, headers, error}`.

Typically called through the `:http` effect rather than directly.

### `redin.json_encode(value)`

Encodes a Lua value (table, string, number, boolean, nil) to a JSON string.

### `redin.json_decode(string)`

Decodes a JSON string to a Lua value. Raises an error on invalid JSON.

---

## Canvas providers

A canvas element delegates rendering to a registered Odin-side **provider**. Providers draw directly using Raylib during their `update` callback.

### Usage

```fennel
[:canvas {:provider :line-chart :aspect :chart-chrome :width 400 :height 200}]
```

The host draws aspect chrome (bg, border, radius), computes the inner rect (inset by padding), and calls the provider's `update(inner_rect)` every frame. Providers use Raylib directly for all drawing -- 2D, 3D, scissor mode, cameras, shaders.

### Lifecycle

| Callback | Signature | When |
| -------- | --------- | ---- |
| `start` | `proc(rect: rl.Rectangle)` | Canvas appears in the frame tree |
| `update` | `proc(rect: rl.Rectangle)` | Each frame the canvas is visible |
| `suspend` | `proc()` | Canvas leaves the frame tree (may return) |
| `stop` | `proc()` | Provider unregistered (final cleanup) |

Providers register in Odin via `canvas.register(name, provider)`. See the [canvas provider reference](../reference/canvas.md) for full details and examples.

---

## Dev server (HTTP)

Runs on `localhost:8800` when started with `--dev` flag. All responses are JSON unless noted.

**Authentication.** Every non-`OPTIONS` request must include `Authorization: Bearer <token>`, where the token is read from `./.redin-token` (generated on startup, mode 0600, removed on shutdown). The server also verifies the `Host` header is `localhost:<port>` or `127.0.0.1:<port>` (DNS-rebinding defence). Missing token → `401`, bad Host → `403`, `OPTIONS` → `405` (CORS preflight not served — the endpoint is for local tools, not browsers). See [dev-server reference](../reference/dev-server.md) for usage examples.

### Frames

| Method | Path      | Body | Response                             |
| ------ | --------- | ---- | ------------------------------------ |
| GET    | `/frames` | --   | Full frame tree (from last `redin.push`) |

Calls into Lua (`view.get-last-push`) to retrieve the last pushed frame.

### State

| Method | Path           | Body | Response                                 |
| ------ | -------------- | ---- | ---------------------------------------- |
| GET    | `/state`       | --   | Full app-db (calls `redin_get_state` global) |
| GET    | `/state/:path` | --   | Nested value at dot-separated path       |

Path navigation: `/state/items.0.text` walks into the state table. Note: the `redin_get_state` global must be defined by the app for these endpoints to return data.

### Selection

| Method | Path          | Body | Response                                                                   |
| ------ | ------------- | ---- | -------------------------------------------------------------------------- |
| GET    | `/selection`  | --   | Current text/input selection: `{kind: none\|input\|text, start, end, text}` |

### Events

| Method | Path      | Body          | Response        |
| ------ | --------- | ------------- | --------------- |
| POST   | `/events` | JSON value    | `{"ok": true}`  |

The JSON body is decoded and wrapped in a single-element event list, then delivered to `redin_events`. Example: posting `["counter/inc"]` dispatches that event.

### Theme

| Method | Path       | Body                | Response        |
| ------ | ---------- | ------------------- | --------------- |
| GET    | `/aspects` | --                  | Full theme table (from Odin-side theme map) |
| PUT    | `/aspects` | `{aspect: {props}}` | `{"ok": true}`  |

PUT calls into Lua (`theme.set-theme`) to replace the theme, which also updates the Odin-side theme map.

### Media

| Method | Path          | Body               | Response                 |
| ------ | ------------- | ------------------ | ------------------------ |
| GET    | `/screenshot` | --                 | PNG binary (`image/png`) |
| POST   | `/click`      | `{"x": N, "y": N}` | `{"ok": true}`           |

Click injects a `MouseEvent` into the input queue, which is processed on the next frame.

### Control

| Method | Path        | Body | Response        |
| ------ | ----------- | ---- | --------------- |
| POST   | `/shutdown` | --   | `{"ok": true}`  |

Requests graceful shutdown of the application.

### CORS

The dev server emits no `Access-Control-*` headers and serves `OPTIONS` with a `405 Method Not Allowed`. CORS preflight is intentionally not supported: the server is for local tools (curl, Claude, IDE extensions), not browser-origin code, and admitting browser callers would weaken the same-origin protection that already comes for free with the auth-token requirement.
