# Security audit fixes (#129) — H6 + H8 design

## Goal

Address the two structural findings from issue #129 deferred from
`docs/superpowers/specs/2026-05-09-security-audit-129-design.md`:

- **H6** — cwd-relative `src/runtime/?.fnl` in `fennel.path` plus the
  cwd-relative file list in `hotreload_init` are loaded outside the
  redin source tree, so a poisoned `./src/runtime/init.fnl` next to
  the user's working directory can be picked up. Realistic only on
  shared NFS / multi-tenant workstations, but worth closing.
- **H8** — the single-threaded dev-server accept loop processes one
  connection at a time. A slow client holds the loop for up to 30s
  (the per-request deadline), starving other clients. Local-only,
  classified by the audit as a hardening note rather than a
  vulnerability, but the audit explicitly recommends "switch to a
  small worker pool" for concurrent test runners and agents.

Both ride a single follow-up branch off `fix/security-audit-129`.
H6 ships first (smaller, mechanical, no threading); H8 second.

The redin trust model is unchanged. End users running release builds
on a single-user machine see no behavioural difference. Source-tree
contributors see the same hot-reload behaviour as today.

## H6 — gate cwd-relative paths on a source-tree marker

### Marker

Add `is_redin_source_tree` to `src/redin/bridge/`:

```odin
@(private = "package")
is_redin_source_tree :: proc() -> bool {
    return os.exists("src/cmd/redin/main.odin")
}
```

`src/cmd/redin/main.odin` is the CLI entry — present only inside the
redin repo. A user app or shared workspace will not have a
`src/cmd/redin/` directory by accident, and a deliberate mimic would
require the attacker to be able to write a multi-level directory
structure next to cwd, which already implies the trust boundary has
been crossed.

The marker is computed once during `bridge.init` and cached on the
`Bridge` struct as `b.source_tree: bool`. All three call sites read
the cached value rather than re-stat'ing.

### Call sites

**1. `setup_lua_paths` (`bridge.odin:2598`)** — currently appends
`"vendor/fennel/?.lua;"` to `package.path` cwd-relative. Same risk
class: a poisoned `./vendor/fennel/fennel.lua` would be loaded by
`require("fennel")`. Push the marker into Lua before running the
snippet:

```odin
setup_lua_paths :: proc(L: ^Lua_State, source_tree: bool) {
    lua_pushboolean(L, source_tree ? 1 : 0)
    lua_setglobal(L, "_redin_source_tree")
    code := `
        local d = _redin_exe_dir
        local cwd = _redin_source_tree and "vendor/fennel/?.lua;" or ""
        package.path =
          d .. "/vendor/fennel/?.lua;" ..
          d .. "/runtime/?.lua;" ..
          d .. "/../.redin/vendor/fennel/?.lua;" ..
          d .. "/../.redin/runtime/?.lua;" ..
          cwd ..
          package.path
    `
    luaL_dostring(L, cstring(raw_data(code)))
}
```

**2. `load_fennel` (`bridge.odin:2617`)** — currently appends
`"src/runtime/?.fnl;"` to `fennel.path` cwd-relative. Gate the same
way using the same `_redin_source_tree` global already pushed in
step 1:

```odin
fennel.path =
  d .. "/runtime/?.fnl;" ..
  d .. "/../.redin/runtime/?.fnl;" ..
  (_redin_source_tree and "src/runtime/?.fnl;" or "") ..
  fennel.path
```

The `pcall(dofile, "vendor/fennel/fennel.lua")` fallback at
`bridge.odin:2623` similarly only fires inside the source tree —
gate it on `_redin_source_tree` to remove the extra cwd-relative
load attempt outside the source tree.

**3. `hotreload_init` (`hotreload.odin:14`)** — only populate the
cwd-relative file list when the marker is true:

```odin
hotreload_init :: proc(hr: ^Hot_Reload, source_tree: bool) {
    hr.check_interval = 60
    if !source_tree do return
    files := []string{
        "src/runtime/dataflow.fnl",
        "src/runtime/effect.fnl",
        "src/runtime/frame.fnl",
        "src/runtime/theme.fnl",
        "src/runtime/view.fnl",
        "src/runtime/init.fnl",
    }
    for f in files {
        append(&hr.watch_paths, f)
        hr.last_mtimes[f] = get_file_mtime(f)
    }
}
```

When `source_tree` is false, `watch_paths` stays empty and
`hotreload_check` becomes a no-op (the existing `for path in
hr.watch_paths` loop simply doesn't iterate). `hotreload_destroy`
already handles the empty case.

### Tests

Add `src/redin/bridge/source_tree_test.odin`:

- `chdir` to a temp dir created via `os.make_directory`. Assert
  `is_redin_source_tree()` is false.
- Create `src/cmd/redin/` and touch `src/cmd/redin/main.odin` inside
  the temp dir. Assert true.
- `chdir` back to the original cwd in the test teardown.

The integration tests in `test/ui/` continue to run from the source
tree, so the true-path is already exercised end-to-end. No new
integration test is required.

Wire the new `*_test.odin` into `.github/workflows/test.yml`'s
`bridge` step — that step already runs `odin test src/redin/bridge`,
so the new file is picked up automatically without a workflow
change.

### Migration risk

None for end users — their cwd is never a redin source tree.

For redin contributors:
- `cd /path/to/redin && ./build/redin foo.fnl` — unchanged. Marker
  fires, cwd-relative paths apply, hot reload works.
- `cd /tmp && /path/to/redin/build/redin foo.fnl` — hot reload no
  longer fires, and a poisoned `/tmp/src/runtime/init.fnl` is no
  longer loaded. Both desired.

`build-dev.sh` and `redin-cli` flows are unaffected; neither runs
out of `/tmp` or a non-source-tree directory.

## H8 — acceptor + 4-handler pool

### Goal

Replace the single `server_thread_proc` with one acceptor thread and
four handler threads. One slow client can no longer block other
clients (up to three slow clients still leave one handler free).
Per-request latency is unchanged because the main thread remains the
single processor; handlers only do socket I/O.

### Types

```odin
HANDLER_POOL_SIZE :: 4

Pending_Conn :: struct {
    socket: net.TCP_Socket,
}

Conn_Queue :: struct {
    q:    queue.Queue(^Pending_Conn),
    mu:   sync.Mutex,
    sema: sync.Sema,            // posted on push, waited on by pop
}

conn_push :: proc(cq: ^Conn_Queue, c: ^Pending_Conn) {
    sync.lock(&cq.mu)
    queue.push_back(&cq.q, c)
    sync.unlock(&cq.mu)
    sync.sema_post(&cq.sema)
}

conn_pop_blocking :: proc(cq: ^Conn_Queue) -> ^Pending_Conn {
    sync.sema_wait(&cq.sema)
    sync.lock(&cq.mu)
    defer sync.unlock(&cq.mu)
    c, _ := queue.pop_front_safe(&cq.q)
    return c
}
```

A `nil` push is the "exit" sentinel for handlers.

### `Dev_Server` changes

Replace `server_thread: ^thread.Thread` with:

```odin
accepted_conns:  Conn_Queue
acceptor_thread: ^thread.Thread
handler_threads: [HANDLER_POOL_SIZE]^thread.Thread
```

The existing `incoming: Sync_Queue` (handler → main) stays untouched
— its semantics (drained per frame, no blocking) are still correct.

### Threads

**`acceptor_thread_proc(ds)`:**

```odin
acceptor_thread_proc :: proc(ds: ^Dev_Server) {
    for ds.running {
        client, _, accept_err := net.accept_tcp(ds.tcp_sock)
        if accept_err != nil || !ds.running {
            break
        }
        pc := new(Pending_Conn)
        pc.socket = client
        conn_push(&ds.accepted_conns, pc)
    }
    // Wake every handler so they observe ds.running = false and exit.
    for _ in 0 ..< HANDLER_POOL_SIZE {
        conn_push(&ds.accepted_conns, nil)
    }
}
```

**`handler_thread_proc(ds)`:**

```odin
handler_thread_proc :: proc(ds: ^Dev_Server) {
    stack_buf: [8192]u8
    for {
        pc := conn_pop_blocking(&ds.accepted_conns)
        if pc == nil do return
        defer free(pc)
        handle_one_connection(ds, pc.socket, stack_buf[:])
    }
}
```

`handle_one_connection` is the existing per-request body of
`server_thread_proc:253–467` lifted verbatim: per-recv timeout,
deadline, header/body read, host check, OPTIONS reject, Bearer
auth, enqueue to `incoming`, `sema_wait(done)`, send response,
close socket. No logic change.

### Shutdown (`devserver_destroy`)

```odin
devserver_destroy :: proc(ds: ^Dev_Server) {
    if ds.running {
        ds.running = false
        // Connect-and-close to unblock accept (existing trick).
        if unblock, err := net.dial_tcp(net.Endpoint{
            address = net.IP4_Loopback, port = ds.port,
        }); err == nil {
            net.close(unblock)
        }
        if ds.acceptor_thread != nil {
            thread.join(ds.acceptor_thread)
            thread.destroy(ds.acceptor_thread)
        }
        // Acceptor pushed HANDLER_POOL_SIZE nils on its way out.
        for t in ds.handler_threads {
            if t != nil {
                thread.join(t)
                thread.destroy(t)
            }
        }
        net.close(ds.tcp_sock)
        // Defensive: drain any conn the acceptor enqueued before
        // observing running=false. Should be empty in practice.
        for {
            sync.lock(&ds.accepted_conns.mu)
            empty := queue.len(ds.accepted_conns.q) == 0
            sync.unlock(&ds.accepted_conns.mu)
            if empty do break
            pc := conn_pop_blocking(&ds.accepted_conns)
            if pc == nil do continue
            net.close(pc.socket)
            free(pc)
        }
        os.remove(PORT_FILE)
        os.remove(TOKEN_FILE)
    }
    // …existing token / host string deletes unchanged…
    queue.destroy(&ds.incoming.q)
    queue.destroy(&ds.accepted_conns.q)
}
```

The defensive drain after `net.close(ds.tcp_sock)` is paranoia — by
the time we joined every thread the queue is empty. Cheap to keep
because it makes the invariant locally provable.

### Bound and characteristics

- **Concurrent in-flight requests:** at most `HANDLER_POOL_SIZE = 4`.
- **Memory:** 4 × 8 KiB stack buffer plus 4 × thread struct. ~33 KiB
  baseline.
- **Latency under no contention:** unchanged — one extra hop through
  `accepted_conns`, dominated by the existing main-thread sync.
- **Worst case under 4 stalled clients:** new connections queue in
  `accepted_conns` until a handler finishes its 30s deadline, then
  drains. Strictly better than the single-thread design where any
  one stalled client triggers the same wait.

### Tests

Add `test/ui/test_devserver_pool.bb` (Babashka, parallel to other
dev-server tests). Reuses `test/ui/run.bb`'s auth-token reading.

```clojure
;; Open three TCP connections that send a partial request and never
;; finish the headers. Each will sit in handler `recv` until the 5s
;; per-recv timeout / 30s deadline.
(def stalled (doall (for [_ (range 3)]
  (let [s (java.net.Socket. "127.0.0.1" port)]
    (.write (.getOutputStream s)
            (.getBytes "GET /state HTTP/1.1\r\n"))
    (.flush (.getOutputStream s))
    s))))

;; A normal request must still succeed within ~1s.
(let [start (System/currentTimeMillis)
      resp  (curl/get (str "http://localhost:" port "/state")
                      {:headers {"Authorization" (str "Bearer " token)}})
      took  (- (System/currentTimeMillis) start)]
  (assert (= 200 (:status resp)) "fourth request returned non-200")
  (assert (< took 2000)
          (str "fourth request took " took "ms — pool not active")))

;; Tear down stalled connections.
(doseq [s stalled] (.close s))
```

The 2000ms cap is generous (real measurement is single-digit ms);
the test still flunks the single-thread baseline, where the fourth
request blocks behind the first stalled connection until that
connection's 30s deadline expires.

Add the test to `test/ui/run-all.sh` so CI exercises it.

A unit-level Odin test for the pool would require mocking
`net.accept_tcp`, which is more invasive than warranted. The
Babashka end-to-end is the cheaper, higher-fidelity check.

### Migration risk

External behaviour is unchanged: same endpoints, same auth, same
shutdown semantics. The only observable difference is that multiple
in-flight requests no longer serialise. UI tests that happened to
rely on serialisation (none known today, but worth a grep over
`test/ui/`) would need adjustment. The audit explicitly described
the single-thread loop as a hardening note, not a vulnerability —
no security regression possible from this change.

## Out of scope

- **H1** — fail-open `redin.http` / `redin.shell` defaults. Policy
  call (secure-by-default vs scripting-toolkit posture); separate
  thread.
- **L2 / L3** — IDN / case-sensitivity documentation deltas.
  Pure-docs change; can ride a docs commit later.

## Verification

After both fixes:

1. `odin build src/cmd/redin -collection:lib=lib -collection:luajit=vendor/luajit -out:build/redin`
2. `odin test src/redin/bridge -collection:lib=lib -collection:luajit=vendor/luajit`
3. `luajit test/lua/runner.lua test/lua/test_*.fnl`
4. `bash test/ui/run-all.sh --headless`
5. `./build-dev.sh && bash test/ui/run-all.sh --headless` (memory tracker on)
6. From a non-source-tree dir: `cd /tmp && /path/to/redin/build/redin /path/to/example.fnl`. Confirm hot reload doesn't fire (touch `src/runtime/init.fnl` if you want, no reload message). Confirm no `src/runtime/?.fnl` is loaded by tracing `package.path` / `fennel.path` via the dev server `/state`.
