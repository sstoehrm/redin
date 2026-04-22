# Hello redin -- Quickstart

Get from zero to a running counter app in 5 minutes.

## Prerequisites

- **Odin** with Raylib bundled (see [odin-lang.org](https://odin-lang.org))
- **LuaJIT** on your PATH
- **Fennel** -- vendored in the project under `vendor/fennel.lua`, no install needed

## Build the host

```sh
odin build src/host -collection:lib=lib -out:build/redin
```

This produces the `build/redin` binary: the Odin/Raylib host that embeds LuaJIT and runs your Fennel scripts.

## Create `counter.fnl`

```fennel
;; counter.fnl -- counter app

(local dataflow (require :dataflow))
(local theme-mod (require :theme))

;; 1. Set a Nord theme
(theme-mod.set-theme
  {:surface      {:bg [46 52 64] :padding [24 24 24 24]}
   :heading      {:color [216 222 233] :font-size 32 :weight 1}
   :button       {:bg [76 86 106] :color [236 239 244]
                  :radius 6 :padding [10 20 10 20]}
   :button#hover {:bg [94 105 126]}})

;; 2. Initialize app state
(dataflow.init {:counter 0})

;; 3. Register an event handler
(reg-handler :event/inc
  (fn [db _event]
    (update db :counter #(+ $1 1))))

;; 4. Register a subscription
(reg-sub :sub/counter
  (fn [db]
    (get db :counter)))

;; 5. Define the view -- called by the runtime each frame
(global main_view
  (fn []
    (let [count (subscribe :sub/counter)]
      [:vbox {:aspect :surface}
        [:text {:aspect :heading} (tostring count)]
        [:button {:aspect :button :click [:event/inc]} "+1"]])))
```

### What each piece does

| Piece | Purpose |
|---|---|
| `(require :dataflow)` | Load the dataflow module |
| `(require :theme)` | Load the theme module |
| `theme-mod.set-theme` | Push the theme to the renderer; aspects are referenced by name on elements |
| `dataflow.init` | Seed `app-db` with `{:counter 0}` |
| `reg-handler` | Register `:event/inc`; handler receives `db` and returns updated `db` |
| `reg-sub` | Register `:sub/counter`; recomputes only when `:counter` changes |
| `main_view` | Global the runtime calls each frame; returns the frame tree directly |

### How events work

```
User clicks the button
  -> button has :click [:event/inc]
  -> dispatch([:event/inc])
  -> handler increments :counter
  -> :sub/counter invalidated, recomputed
  -> main_view re-runs, new frame sent to renderer
```

Events like `:click`, `:change`, and `:key` are declared directly on elements as attributes.

## Run

```sh
./build/redin counter.fnl
```

The window opens. Click the button -- the counter increments.

### Dev mode

```sh
./build/redin --dev counter.fnl
```

`--dev` enables the HTTP dev server. It picks port 8800 by default (walks upward if busy) and writes the bound port to `./.redin-port` plus a per-run bearer token to `./.redin-token`.

```sh
PORT=$(cat .redin-port)
TOKEN=$(cat .redin-token)
AUTH="Authorization: Bearer $TOKEN"

# Inspect live state
curl -H "$AUTH" localhost:$PORT/state

# Inspect the current frame tree
curl -H "$AUTH" localhost:$PORT/frames

# Dispatch an event from the terminal
curl -X POST -H "$AUTH" -H 'Content-Type: application/json' \
  -d '["event/inc"]' \
  localhost:$PORT/events
```

See [dev-server.md](../reference/dev-server.md) for the full endpoint list and auth details.

## Next steps

- [Building apps](building-apps.md) -- subscriptions, effects, multi-handler flows
- [re-frame quickstart](re-frame-quickstart.md) -- coming from re-frame? start here
- [Lua guide](lua-guide.md) -- using Lua instead of Fennel
- [core-api.md](../core-api.md) -- frame format, theme, host functions
- [app-api.md](../app-api.md) -- dataflow, subscriptions, effects in full detail
