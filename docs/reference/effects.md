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
| `url` | string | yes | -- | Request URL. Scheme must be `http` or `https`. |
| `method` | keyword | no | `:get` | `:get`, `:post`, `:put`, `:delete`, `:patch` |
| `headers` | table | no | `{}` | Key-value header pairs. Keys/values containing `\r`, `\n`, or `\x00` are rejected. |
| `body` | string | no | `nil` | Request body |
| `timeout` | number | no | `30000` | Per-call timeout in milliseconds. On expiry the call fails with `error = "http timeout exceeded"`. |
| `on-success` | keyword | yes | -- | Event dispatched on 2xx response |
| `on-error` | keyword | yes | -- | Event dispatched on error |

**Response routing:** 2xx status codes dispatch to `on-success`, all others to `on-error`. The host calls `effect.handle-http-response` with `{:id :status :headers :body}`.

**Redirects** are **not** auto-followed. 3xx responses surface to the caller as-is, including the `Location` header.

**Failure response shape.** Network/host-side failures dispatch to `on-error` with `{:status 0 :error "<message>"}`. Possible messages:

| Message | Cause |
|---|---|
| `"http scheme must be http or https"` | URL scheme is not `http`/`https` (e.g. `file://`, `ftp://`). |
| `"http header contains invalid character"` | A header key or value contained `\r`, `\n`, or `\x00`. |
| `"http timeout exceeded"` | Wall-clock timeout (per-call `:timeout`, default 30000 ms) elapsed. |
| `"too many concurrent http requests (cap 64)"` | Submitted while 64 in-flight requests were already running. |
| `"host <name> not in http whitelist"` | Whitelist is set (`bridge.set_http_whitelist`) and the URL host is not on it. See [native bridge](native-bridge.md). |

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

## Built-in: `:shell`

Spawn a child process. The result is routed back as an event.

```fennel
(reg-handler :event/run-build
  (fn [db event]
    {:db (assoc db :building true)
     :shell {:cmd ["bb" "build.bb" "--release"]
             :timeout 60000
             :max-output 32
             :on-success :event/build-done
             :on-error :event/build-failed}}))
```

| Field | Type | Required | Default | Description |
|-------|------|----------|---------|-------------|
| `cmd` | array of strings | yes | -- | Argv (no shell interpolation). |
| `stdin` | string | no | `nil` | Bytes piped to the child's stdin. |
| `timeout` | number | no | `30000` | Per-call timeout in milliseconds. On expiry the child is killed and the call fails. |
| `max-output` | number | no | `16` | Per-call cap on combined stdout + stderr in MiB. On exceedance the child is killed. |
| `on-success` | keyword | yes | -- | Event dispatched on `exit-code == 0`. |
| `on-error` | keyword | yes | -- | Event dispatched on non-zero exit, kill, or host-side failure. |

**Failure response shape.** Failures dispatch to `on-error` with `{:exit-code -1 :error "<message>"}` (no partial output). Possible messages:

| Message | Cause |
|---|---|
| `"shell timeout exceeded N ms"` | Wall-clock timeout (per-call `:timeout`, default 30000 ms) elapsed; child killed. |
| `"shell output exceeded N MiB cap"` | Combined stdout + stderr exceeded the cap (per-call `:max-output`, default 16 MiB); child killed. |

The shell-env allowlist (`bridge.set_shell_env_allowlist`, see [native bridge](native-bridge.md)) is applied at spawn time and does not produce a runtime failure — children just see a stripped environment when it is set.

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
