# Effects Reference

Declarative side effects. Handlers return pure data describing what should happen; the effect system executes it.

---

## How effects work

When a handler returns an fx map -- a table with a `:db` key plus additional keys -- the effect system executes each non-`:db` key:

```fennel
(reg-handler :event/fetch
  (fn [db event]
    {:db   (assoc db :loading true)
     :http {:url "/api/items"
            :method :get
            :on-success :event/items-loaded
            :on-error :event/items-failed}
     :log  "fetching..."}))
```

1. Dataflow extracts `:db` and applies the recorded path changes.
2. The remaining keys are passed to `effect.execute`.
3. For each key, the registered executor is called with the value.
4. Unknown keys produce a warning (no crash).

Implementation: `src/runtime/effect.fnl`.

---

## Built-in: `:log`

Print to console.

```fennel
{:db db :log "something happened"}
```

---

## Built-in: `:dispatch`

Dispatch another event immediately.

```fennel
{:db (assoc db :status :done)
 :dispatch [:event/notify "Saved"]}
```

---

## Built-in: `:dispatch-later`

Schedule event dispatch after a delay. Accepts a single timer map or a sequence of timer maps.

```fennel
;; Single
{:db db :dispatch-later {:ms 100 :dispatch [:timer/tick]}}

;; Multiple
{:db db :dispatch-later [{:ms 100  :dispatch [:timer/tick]}
                         {:ms 5000 :dispatch [:session/timeout]}]}
```

Each entry: `{:ms N :dispatch event-vector}`. The timer fires when `poll-timers` is called with `now >= start + ms`. The host calls `poll-timers` once per frame.

---

## Built-in: `:http`

Make an async HTTP request. The response is routed back as an event.

```fennel
(reg-handler :event/fetch-items
  (fn [db event]
    {:db (assoc db :loading true)
     :http {:url "https://api.example.com/items"
            :method :get
            :headers {"Authorization" "Bearer token"}
            :timeout 5000
            :on-success :event/items-loaded
            :on-error :event/items-failed}}))
```

| Field | Type | Required | Default | Description |
|-------|------|----------|---------|-------------|
| `url` | string | yes | -- | Request URL (HTTP or HTTPS) |
| `method` | keyword | no | `:get` | `:get`, `:post`, `:put`, `:delete`, `:patch` |
| `headers` | table | no | `{}` | Key-value header pairs |
| `body` | string | no | `nil` | Request body |
| `timeout` | number | no | `30000` | Timeout in milliseconds |
| `on-success` | keyword | yes | -- | Event dispatched on 2xx response |
| `on-error` | keyword | yes | -- | Event dispatched on error |

**Response routing:** 2xx status codes dispatch to `on-success`, all others to `on-error`. The host calls `effect.handle-http-response` with `{:id :status :headers :body}`.

**Success handler** receives `[event-name response]`:

```fennel
(reg-handler :event/items-loaded
  (fn [db [_ response]]
    ;; response.status  = 200
    ;; response.headers = {"content-type" "application/json" ...}
    ;; response.body    = "{\"items\": [...]}"
    (assoc db :items response.body :loading false)))
```

**Error handler** receives `[event-name error]`:

```fennel
(reg-handler :event/items-failed
  (fn [db [_ error]]
    ;; HTTP error:    error.status = 500, error.body = "..."
    ;; Network error: error.status = 0, error.error = "timeout"
    (assoc db :error (or error.error (.. "HTTP " (tostring error.status)))
              :loading false)))
```

---

## Custom effects

`reg-fx` registers an executor for any key. Replaces any existing executor for that key.

```fennel
(reg-fx :save-file
  (fn [params]
    ;; params = {:path "foo.txt" :content "hello"}
    ))
```

**Executor signature:** `(fn [params] -> nil)` -- params is whatever value was in the fx map for this key.

---

## Timer internals

Timers are stored as `{:at <absolute-ms> :event <vector>}` in a queue. The queue is scanned linearly.

| Function | Purpose |
| -------- | ------- |
| `effect.poll-timers(now-ms)` | Fire ready timers, returns count fired |
| `effect.pending-timers()` | Returns count of queued timers |
| `effect.clear-timers()` | Empty the timer queue |

The host calls `poll-timers(os.clock() * 1000)` once per frame. Timers where `at <= now` are fired and removed from the queue.

### Global aliases

| Global | Purpose |
| ------ | ------- |
| `_G.redin_poll_timers` | Poll timer queue |
| `_G.redin_pending_timers` | Count pending timers |
| `_G.redin_clear_timers` | Clear timer queue |

---

## Testing effects

Effects are fully swappable. Register stubs in tests, real executors in production. Handlers do not change.

```fennel
(local calls [])
(reg-fx :http (fn [params] (table.insert calls params)))
(dispatch [:event/fetch])
(assert (= (. calls 1 :url) "/api/items"))
```
