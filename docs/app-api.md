# app API

The programming model for redin apps: state management, event handling, subscriptions, and side effects.

## Dataflow

Single state atom, event-driven updates, path-tracked subscriptions. All state lives in `app-db` (a Lua table), but it is never accessed directly. All reads and writes go through tracked accessor functions.

### `dataflow.init(initial-db)`

Initialize the application state. Call once at startup.

```fennel
(dataflow.init {:counter 0
                :items [{:id 1 :text "first" :done false}]})
```

```lua
dataflow.init({counter = 0, items = {{id = 1, text = "first", done = false}}})
```

Replaces `app-db` with the given table (or `{}` if nil). Returns the new `app-db`.

### State accessors

`app-db` is not public. Handlers and subscriptions interact with it through tracked functions. Every `get`/`get-in` call records the path as a dependency. Every `assoc`/`assoc-in`/`update`/`update-in`/`dissoc`/`dissoc-in` call records the path as a change. This enables precise subscription invalidation without a global version counter.

#### Reads

| Function | Signature                    | Purpose                                 |
| -------- | ---------------------------- | --------------------------------------- |
| `get`    | `(get db key)`               | Read top-level key                      |
| `get`    | `(get db key default)`       | Read top-level key, return default if nil |
| `get-in` | `(get-in db path)`           | Read nested path                        |
| `get-in` | `(get-in db path default)`   | Read nested path, return default if nil |

```fennel
(get db :counter)                      ;; tracks [:counter]
(get db :filter "all")                 ;; tracks [:filter], returns "all" if nil
(get-in db [:items 1 :done])           ;; tracks [:items 1 :done]
(get-in db [:user :name] "anonymous")  ;; tracks [:user :name], returns "anonymous" if nil
```

#### Writes

| Function    | Signature                  | Purpose                           |
| ----------- | -------------------------- | --------------------------------- |
| `assoc`     | `(assoc db key value)`     | Set top-level key                 |
| `assoc-in`  | `(assoc-in db path value)` | Set nested path                   |
| `update`    | `(update db key f)`        | Apply function to top-level value |
| `update-in` | `(update-in db path f)`    | Apply function to nested value    |
| `dissoc`    | `(dissoc db key)`          | Remove top-level key              |
| `dissoc-in` | `(dissoc-in db path)`      | Remove nested path                |

```fennel
(assoc db :counter 1)                          ;; records [:counter]
(assoc-in db [:items 1 :done] true)            ;; records [:items 1 :done]
(update db :counter #(+ $1 1))                 ;; records [:counter]
(update-in db [:items 1 :done] #(not $1))      ;; records [:items 1 :done]
(dissoc db :loading)                           ;; records [:loading]
(dissoc-in db [:user :session])                ;; records [:user :session]
```

#### Dependency granularity

The tracked path determines invalidation precision. Coarse reads depend on more; fine reads depend on less.

```fennel
;; Coarse: depends on [:items]. Any change under :items invalidates.
(get db :items)

;; Fine: depends on [:items 1 :done]. Only changes to this leaf invalidate.
(get-in db [:items 1 :done])
```

Once `get` returns a raw Lua table, further reads on that table are untracked. The dependency is recorded at the `get`/`get-in` call site.

### `reg-handler(event-key, handler-fn)`

Register an event handler.

**Handler signature:** `(fn [db event] -> db)`

- `db` -- the tracked state accessor (not the raw table)
- `event` -- the event vector, e.g. `[:event/increment]` or `[:event/add-todo "Buy milk"]`
- Return `db` (the accessor). Write paths are recorded automatically.

```fennel
;; Simple state update
(reg-handler :event/increment
  (fn [db event]
    (update db :counter #(+ $1 1))))

;; Event with parameters
(reg-handler :event/set-filter
  (fn [db [_ filter]]
    (assoc db :filter filter)))

;; Toggle a nested value
(reg-handler :event/toggle-todo
  (fn [db [_ idx]]
    (update-in db [:items idx :done] #(not $1))))
```

```lua
reg_handler("event/increment", function(db, event)
  return update(db, "counter", function(n) return n + 1 end)
end)

reg_handler("event/set-filter", function(db, event)
  return assoc(db, "filter", event[2])
end)
```

**Handler with side effects:** return an fx map instead of `db`. The `:db` key holds the accessor; everything else is an effect.

```fennel
(reg-handler :event/fetch-items
  (fn [db event]
    {:db   (assoc db :loading true)
     :http {:url "/api/items"
            :on-success :event/items-loaded}
     :log  "fetching items..."}))
```

The `:db` key is extracted as the new state. All other keys are passed to the effect system. See [Effects](#effects) below.

### `dispatch(event)`

Dispatch an event vector. Looks up the handler for `event[1]`, calls it, records changed paths.

```fennel
(dispatch [:event/increment])
(dispatch [:event/add-todo "Write tests"])
```

```lua
dispatch({"event/increment"})
dispatch({"event/add-todo", "Write tests"})
```

Dispatches do not trigger an immediate rerender. Changed paths accumulate until the next render tick, when the system:

1. Collects all paths changed since last frame
2. Invalidates subscriptions whose tracked paths overlap
3. Recomputes invalidated subscriptions
4. Runs the view and sends the new frame to the renderer

This naturally batches rapid-fire dispatches (e.g. typing in an input).

### Path invalidation rules

A write to path `W` invalidates a subscription on path `S` if either is a prefix of the other:

| Write path         | Subscription path  | Match? | Reason                                   |
| ------------------ | ------------------ | ------ | ---------------------------------------- |
| `[:items 1 :done]` | `[:items]`         | yes    | Write is deeper, parent sub sees change  |
| `[:items 1 :done]` | `[:items 1 :done]` | yes    | Exact match                              |
| `[:items]`         | `[:items 1 :done]` | yes    | Write replaces parent, child invalidated |
| `[:items 1 :done]` | `[:counter]`       | no     | Unrelated paths                          |

### `reg-sub(sub-key, query-fn)`

Register a subscription. Dependencies are recorded automatically via `get`/`get-in` calls during computation.

**Query signature:** `(fn [db] -> derived-value)`

```fennel
(reg-sub :sub/counter
  (fn [db] (get db :counter)))
;; Depends on [:counter]. Only invalidated by writes to [:counter].

(reg-sub :sub/active-items
  (fn [db]
    (icollect [_ item (ipairs (get db :items))]
      (when (not item.done) item))))
;; Depends on [:items]. Invalidated by any write under :items.

(reg-sub :sub/first-item-done
  (fn [db] (get-in db [:items 1 :done])))
;; Depends on [:items 1 :done]. Not invalidated by [:items 2 :done].
```

```lua
reg_sub("sub/counter", function(db)
  return get(db, "counter")
end)

reg_sub("sub/active-items", function(db)
  local result = {}
  for _, item in ipairs(get(db, "items")) do
    if not item.done then table.insert(result, item) end
  end
  return result
end)
```

**Dynamic dependencies.** Subscriptions re-record their dependencies on every recomputation. A sub that reads different paths depending on state tracks the right dependencies automatically:

```fennel
(reg-sub :sub/selected-item
  (fn [db]
    (let [idx (get db :selected-index)]
      (get-in db [:items idx :text]))))
```

First run with `idx = 1`: depends on `[:selected-index]` and `[:items 1 :text]`. User selects item 3: `[:selected-index]` changes, sub recomputes, now depends on `[:selected-index]` and `[:items 3 :text]`. The old dependency on `[:items 1 :text]` is dropped.

No explicit subscription graph needed. No Layer 2/3 distinction. No wiring. You just read what you need and the framework figures out the dependencies.

### `subscribe(sub-key)`

Read the current value of a subscription. Returns the cached value if none of the subscription's tracked paths have changed. Otherwise recomputes.

```fennel
(let [count (subscribe :sub/counter)
      items (subscribe :sub/active-items)]
  ...)
```

```lua
local count = subscribe("sub/counter")
local items = subscribe("sub/active-items")
```

Warns on missing subscription, returns nil.

### `flush()`

Process pending state changes and invalidate affected subscriptions. Called automatically by the view runner before each render tick. Can be called manually in tests to trigger invalidation between dispatches.

```fennel
(dataflow.flush)
```

Flush does two things:

1. Walks all registered subscriptions and marks dirty any whose tracked dependencies overlap with accumulated changed paths.
2. Clears the changed-paths buffer.

Subscriptions are not recomputed during flush. They recompute lazily on the next `subscribe` call.

### Views

A view function returns `{:frame [...] :bind {}}`. It reads subscriptions and builds the frame tree from current state. The `:bind` table is currently unused (reserved for future use) but the API expects it.

```fennel
(fn main-view []
  (let [count (subscribe :sub/counter)]
    {:frame
     [:vbox {:aspect :surface}
       [:text {:aspect :heading} (tostring count)]
       [:button {:aspect :button :click [:event/increment]} "+1"]]
     :bind {}}))

(global main_view main-view)
```

The view runner calls `main_view` on each render tick (after flushing invalidated subscriptions). The returned frame is flattened and pushed to the host via `redin.push`.

#### View runner: `view.render-tick`

Each frame, the host calls `redin_render_tick`. The view runner:

1. Checks if there are pending changes (or if this is the first render).
2. Calls `dataflow.flush` to invalidate affected subscriptions.
3. Calls `_G.main_view()` to get `{:frame ... :bind ...}`.
4. Flattens the frame tree (splicing nested lists into the parent).
5. Pushes the flattened frame to the host via `redin.push`.

If there are no changes since the last tick and the view has rendered at least once, the tick is a no-op.

#### Event delivery: `view.deliver-events`

The host delivers input events each frame via `redin_events`. The view runner routes them:

- `:dispatch` events: unwraps the inner vector and calls `dataflow.dispatch`.
- `:http-response` events: forwarded to `effect.handle-http-response`.
- Application events (e.g. from element callbacks): dispatched directly via `dataflow.dispatch`.
- Raw input events (`:click`, `:hover`, `:key`, `:char`, `:resize`): currently ignored by the view runner (handled by the host input system).

### Global exports

The dataflow module registers these globals:

| Global           | Alias                | Purpose               |
| ---------------- | -------------------- | --------------------- |
| `_G.get`         | --                   | Tracked read          |
| `_G.get-in`      | `_G.get_in`          | Tracked nested read   |
| `_G.assoc`       | --                   | Tracked write         |
| `_G.assoc-in`    | `_G.assoc_in`        | Tracked nested write  |
| `_G.update`      | --                   | Tracked update        |
| `_G.update-in`   | `_G.update_in`       | Tracked nested update |
| `_G.dissoc`      | --                   | Tracked remove        |
| `_G.dissoc-in`   | `_G.dissoc_in`       | Tracked nested remove |
| `_G.reg-handler` | `_G.reg_handler`     | Register handler      |
| `_G.dispatch`    | `_G.redin_dispatch`  | Dispatch event        |
| `_G.reg-sub`     | `_G.reg_sub`         | Register subscription |
| `_G.subscribe`   | `_G.redin_subscribe` | Read subscription     |

Both hyphenated Fennel names and underscored Lua names are registered. Fennel's mangled global forms (`__fnl_global__get_2din` etc.) are also set so that Fennel code can use these as bare globals without requiring the module.

---

## Effects

Declarative side effects. Handlers return pure data describing what should happen; the effect system executes it.

### How effects work

When a handler returns an fx map (a table with a `:db` key plus other keys):

```fennel
{:db   (assoc db :loading true)   ;; extracted by dataflow, not passed to effects
 :http {:url "/api"}              ;; passed to :http executor
 :log  "hello"}                   ;; passed to :log executor
```

1. Dataflow extracts `:db` and applies the recorded path changes
2. The remaining keys are passed to `effect.execute`
3. For each key, the registered executor is called with the value
4. Unknown keys produce a warning (no crash)

### `reg-fx(fx-key, executor-fn)`

Register a side-effect executor. Replaces any existing executor for that key.

```fennel
(reg-fx :save-file
  (fn [params]
    ;; params = {:path "foo.txt" :content "hello"}
    ;; do the I/O here
    ))
```

```lua
reg_fx("save-file", function(params)
  -- params.path, params.content
end)
```

**Executor signature:** `(fn [params] -> nil)` -- params is whatever value was in the fx map for this key.

### Built-in effects

#### `:dispatch`

Dispatch another event immediately.

```fennel
{:db (assoc db :status :done)
 :dispatch [:event/notify "Saved"]}
```

#### `:dispatch-later`

Schedule event dispatch after a delay.

```fennel
;; Single timer
{:db (assoc db :status :pending)
 :dispatch-later {:ms 100 :dispatch [:timer/tick]}}

;; Multiple timers
{:db db
 :dispatch-later [{:ms 100 :dispatch [:timer/tick]}
                  {:ms 5000 :dispatch [:session/timeout]}]}
```

Each entry: `{:ms N :dispatch event-vector}`. Timer fires when `poll-timers` is called with `now >= start + ms`. The host calls `poll-timers` once per frame.

#### `:log`

Print to console.

```fennel
{:db db
 :log "something happened"}
```

#### `:http`

Make an async HTTP request. The request is sent to the host via `_G.redin_http(id, url, method, headers, body, timeout)`. The host performs the request asynchronously and delivers the response back as an `:http-response` event, which is routed through `effect.handle-http-response` to dispatch the appropriate success or error handler.

```fennel
{:db (assoc db :loading true)
 :http {:url "/api/items"
        :method :get
        :on-success :event/items-loaded
        :on-error :event/items-failed}}
```

Fields: `url` (required), `method` (default `"get"`), `headers` (table, default `{}`), `body` (string, default `""`), `timeout` (ms, default 30000), `on-success` (required), `on-error` (required).

Success handler receives `[event-name {:status N :headers {} :body "..."}]`. Error handler receives the same for HTTP errors (status >= 300), or `{:status 0 :error "message"}` for network/timeout errors.

### Timer internals

- Timers stored as `{:at <absolute-ms> :event <vector>}` in a queue
- `effect.poll-timers(now-ms)` walks the queue, fires timers where `at <= now`, removes them
- Queue scanned linearly (efficient for typical UI timer counts)
- Host calls `poll-timers` once per frame with current time in milliseconds

Utility functions:

| Function                     | Purpose                                |
| ---------------------------- | -------------------------------------- |
| `effect.poll-timers(now-ms)` | Fire ready timers, returns count fired |
| `effect.pending-timers()`    | Returns count of queued timers         |
| `effect.clear-timers()`      | Empty the timer queue                  |

### Testing effects

Stub the executor, dispatch, assert on what was received:

```fennel
(local calls [])
(reg-fx :http (fn [params] (table.insert calls params)))

(dispatch [:event/fetch-items])

(assert (= (. calls 1 :url) "/api/items"))
(assert (= (. calls 1 :on-success) :event/items-loaded))
```

```lua
local calls = {}
reg_fx("http", function(params) table.insert(calls, params) end)

dispatch({"event/fetch-items"})

assert(calls[1].url == "/api/items")
assert(calls[1].on_success == "event/items-loaded")
```

Effects are fully swappable. In tests, register stubs. In production, register real executors. The handlers don't change.

### Global exports

| Global                    | Alias           | Purpose                  |
| ------------------------- | --------------- | ------------------------ |
| `_G.reg-fx`               | `_G.reg_fx`     | Register effect executor |
| `_G.redin_poll_timers`    | --              | Poll timer queue         |
| `_G.redin_pending_timers` | --              | Count pending timers     |
| `_G.redin_clear_timers`   | --              | Clear timer queue        |

---

## Theme

Theme is a flat table mapping aspect names to property tables. State variants use `#` notation.

```fennel
(theme-mod.set-theme
  {:button        {:bg [76 86 106] :color [236 239 244] :radius 6 :padding [6 14 6 14]}
   :button#hover  {:bg [94 105 126]}
   :button#active {:bg [59 66 82]}
   :input         {:bg [59 66 82] :color [236 239 244] :border [76 86 106]}
   :input#focus   {:border [136 192 208]}})
```

Aspect resolution merges base properties with matching state variants. For `button` in hover state, the resolver starts with `:button` props, then overlays `:button#hover` props. Multiple aspects can be composed via a vector: `{:aspect [:button :small]}`.

Theme is pushed to the host on `set-theme` via `redin.set_theme`.

---

## Canvas providers

The `canvas` element supports a `:provider` attribute naming a registered canvas provider. Canvas providers are a planned extension point; the element is parsed by the host but the provider registry is not yet implemented.

```fennel
[:canvas {:provider "sparkline" :width 200 :height 40}]
```

---

## Host bridge

The host (Odin + Raylib) exposes a `redin` global table with these functions:

| Function              | Purpose                                          |
| --------------------- | ------------------------------------------------ |
| `redin.push(frame)`   | Send flattened frame tree to the renderer         |
| `redin.set_theme(t)`  | Send theme table to the host                      |
| `redin.log(...)`      | Print to host console                             |
| `redin.now()`         | Current time as Unix seconds (float)              |
| `redin.measure_text(text, size)` | Measure text dimensions, returns width, height |
| `redin.http(id, url, method, headers, body, timeout)` | Queue async HTTP request |
| `redin.json_encode(v)` | Encode Lua value to JSON string                 |
| `redin.json_decode(s)` | Decode JSON string to Lua value                 |

The host calls these Lua globals each frame:

| Global               | Purpose                           |
| -------------------- | --------------------------------- |
| `redin_render_tick`  | Run one render tick (view runner) |
| `redin_events`       | Deliver input events              |
| `redin_poll_timers`  | Fire ready timers                 |
