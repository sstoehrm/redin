# Security audit #129 — H6 + H8 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Close the two structural findings deferred from the #129 mechanical-fixes spec — H6 (cwd-relative `fennel.path` / hot-reload paths only fire inside the redin source tree) and H8 (replace the single dev-server accept loop with a small worker pool so one slow client cannot starve others).

**Architecture:**
- H6: introduce `is_redin_source_tree()` (checks for `src/cmd/redin/main.odin`), cache the bool on the `Bridge` struct, gate the cwd-relative entries in `setup_lua_paths`, `load_fennel`, and `hotreload_init` on it.
- H8: split `server_thread_proc` into one acceptor thread (does only `accept_tcp`, hands sockets via a sema-blocked queue) and four handler threads (each does the existing recv/auth/enqueue-to-main/respond/close logic). Concurrent in-flight bound = 4.

**Tech Stack:** Odin (`core:os`, `core:net`, `core:sync`, `core:thread`, `core:container/queue`), Lua C API via FFI, Babashka (Clojure) for the dev-server integration test.

**Spec:** `docs/superpowers/specs/2026-05-09-security-audit-129-h6-h8-design.md`

---

## File map

| File | Status | Responsibility |
|------|--------|----------------|
| `src/redin/bridge/source_tree.odin` | NEW | `is_redin_source_tree()` and a path-injectable helper for tests. |
| `src/redin/bridge/source_tree_test.odin` | NEW | Unit tests for the marker check. |
| `src/redin/bridge/bridge.odin` | MODIFY | Add `source_tree: bool` to `Bridge`; set it in `init`; thread it into `setup_lua_paths`, `load_fennel`, `hotreload_init`. |
| `src/redin/bridge/hotreload.odin` | MODIFY | `hotreload_init` accepts `source_tree`; skip cwd-relative file list when false. |
| `src/redin/bridge/devserver.odin` | MODIFY | Add `Conn_Queue` type; replace `server_thread_proc` with `acceptor_thread_proc` + `handler_thread_proc`; restructure `Dev_Server`, `devserver_init`, `devserver_destroy`. Lift per-request body into `handle_one_connection`. |
| `src/redin/bridge/devserver_pool_test.odin` | NEW | Odin unit tests for `Conn_Queue` push/pop and nil-sentinel. |
| `test/ui/devserver_pool_app.fnl` | NEW | Minimal app for the pool integration test. |
| `test/ui/test_devserver_pool.bb` | NEW | Babashka test: 3 stalled connections + 1 normal request, asserts pool > 1. |

---

## Task 1: H6 — `is_redin_source_tree()` helper

**Files:**
- Create: `src/redin/bridge/source_tree.odin`
- Create: `src/redin/bridge/source_tree_test.odin`

- [ ] **Step 1: Write the failing test**

Create `src/redin/bridge/source_tree_test.odin`:

```odin
package bridge

// Tests for the redin source-tree marker introduced for issue #129 H6.
// The marker decides whether the bridge may use cwd-relative
// fennel.path / package.path entries and watch cwd-relative files for
// hot reload. The presence of `src/cmd/redin/main.odin` is the marker.

import "core:testing"

@(test)
test_is_redin_source_tree_at_present :: proc(t: ^testing.T) {
	// `odin test` runs from the redin source root; the canonical marker
	// is therefore present.
	testing.expect(
		t,
		is_redin_source_tree_at("src/cmd/redin/main.odin"),
		"expected marker to exist when running from redin source root",
	)
}

@(test)
test_is_redin_source_tree_at_absent :: proc(t: ^testing.T) {
	// A path no test fixture creates returns false.
	testing.expect(
		t,
		!is_redin_source_tree_at("does/not/exist/anywhere/marker.txt"),
		"expected absent marker to return false",
	)
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `odin test src/redin/bridge -collection:lib=lib -collection:luajit=vendor/luajit`
Expected: compile error — `is_redin_source_tree_at` is undefined.

- [ ] **Step 3: Write minimal implementation**

Create `src/redin/bridge/source_tree.odin`:

```odin
package bridge

import "core:os"

// is_redin_source_tree reports whether the current working directory
// looks like the redin source tree. The marker `src/cmd/redin/main.odin`
// is unique to this repo — no chance a user app or shared workspace
// has a `src/cmd/redin/` directory by accident. Issue #129 H6.
//
// When false, the bridge skips cwd-relative entries in fennel.path /
// package.path and disables hot reload, so a poisoned
// `./src/runtime/init.fnl` next to the user's working directory is
// not loaded.
is_redin_source_tree :: proc() -> bool {
	return is_redin_source_tree_at("src/cmd/redin/main.odin")
}

@(private = "package")
is_redin_source_tree_at :: proc(marker_path: string) -> bool {
	_, err := os.stat(marker_path, context.temp_allocator)
	return err == os.ERROR_NONE
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `odin test src/redin/bridge -collection:lib=lib -collection:luajit=vendor/luajit`
Expected: PASS for `test_is_redin_source_tree_at_present` and `test_is_redin_source_tree_at_absent` (alongside existing bridge tests).

- [ ] **Step 5: Commit**

```bash
git add src/redin/bridge/source_tree.odin src/redin/bridge/source_tree_test.odin
git commit -m "$(cat <<'EOF'
feat(bridge): add is_redin_source_tree marker (#129 H6)

Detects whether cwd is the redin repo by checking for
src/cmd/redin/main.odin. Used by upcoming gating of cwd-relative
fennel.path / package.path entries and hot-reload watch list.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 2: H6 — gate `setup_lua_paths` cwd entry on source tree

**Files:**
- Modify: `src/redin/bridge/bridge.odin` — add `source_tree: bool` to `Bridge`, set in `init`, change `setup_lua_paths` signature, gate `vendor/fennel/?.lua` cwd entry.

- [ ] **Step 1: Add `source_tree` field to the `Bridge` struct**

In `src/redin/bridge/bridge.odin`, locate the `Bridge` struct (around line 40-51, fields `markdown_skips`, `theme`, `http_client`, `shell_client`, `hot_reload`, `dev_server`, `frame_changed`). Add a new field:

```odin
	frame_changed:   bool,
	source_tree:     bool,
}
```

- [ ] **Step 2: Set `source_tree` in `init` before `setup_lua_paths`**

Locate `init :: proc(b: ^Bridge)` (around `bridge.odin:56`). Currently:

```odin
	exe_dir := filepath.dir(string(os.args[0]))
	lua_pushstring(b.L, strings.clone_to_cstring(exe_dir))
	lua_setglobal(b.L, "_redin_exe_dir")

	setup_lua_paths(b.L)
```

Change to:

```odin
	exe_dir := filepath.dir(string(os.args[0]))
	lua_pushstring(b.L, strings.clone_to_cstring(exe_dir))
	lua_setglobal(b.L, "_redin_exe_dir")

	b.source_tree = is_redin_source_tree()
	setup_lua_paths(b.L, b.source_tree)
```

- [ ] **Step 3: Update `setup_lua_paths` signature and gate the cwd entry**

Locate `setup_lua_paths :: proc(L: ^Lua_State)` (around `bridge.odin:2598`). Replace the entire proc with:

```odin
setup_lua_paths :: proc(L: ^Lua_State, source_tree: bool) {
	// Push the gate flag into Lua so the snippet below can branch on it
	// without string manipulation.
	lua_pushboolean(L, source_tree ? 1 : 0)
	lua_setglobal(L, "_redin_source_tree")

	// Search paths, in priority order:
	//   <exe>/...           — pinned release (binary sits next to vendor/+runtime/)
	//   <exe>/../.redin/... — redin-cli's --native layout (build/redin's
	//                         sibling is .redin/, which has vendor/ + runtime/)
	//   vendor/fennel/...   — cwd-relative, only if running from the
	//                         redin source tree (issue #129 H6).
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

- [ ] **Step 4: Build and run the existing UI smoke test**

Run:
```bash
odin build src/cmd/redin -collection:lib=lib -collection:luajit=vendor/luajit -out:build/redin
```
Expected: clean build.

Run:
```bash
./build-dev.sh
./build/redin test/ui/smoke_app.fnl &
sleep 1
bb test/ui/run.bb test/ui/test_smoke.bb
kill %1 2>/dev/null; wait 2>/dev/null
```
Expected: smoke tests pass. Confirms the source-tree path still loads Fennel correctly when `source_tree == true`.

- [ ] **Step 5: Commit**

```bash
git add src/redin/bridge/bridge.odin
git commit -m "$(cat <<'EOF'
feat(bridge): gate cwd vendor/fennel/?.lua on source tree (#129 H6)

Push _redin_source_tree into Lua and skip the cwd-relative
package.path entry when running outside the redin repo. The
exe-relative entries (release / --native) are unaffected.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 3: H6 — gate `load_fennel` cwd entries on source tree

**Files:**
- Modify: `src/redin/bridge/bridge.odin` — change `load_fennel`, gate `src/runtime/?.fnl` and the `pcall(dofile, "vendor/fennel/fennel.lua")` fallback.

- [ ] **Step 1: Update `load_fennel` to gate cwd entries**

Locate `load_fennel :: proc(L: ^Lua_State)` (around `bridge.odin:2617`). Replace the entire proc with:

```odin
load_fennel :: proc(L: ^Lua_State) {
	// `_redin_source_tree` was set in setup_lua_paths and persists for
	// the lifetime of the Lua state.
	code := `
		local d = _redin_exe_dir
		package.loaded["fennel"] = {}
		local ok = pcall(dofile, d .. "/vendor/fennel/fennel.lua")
		if not ok then ok = pcall(dofile, d .. "/../.redin/vendor/fennel/fennel.lua") end
		if not ok and _redin_source_tree then
		  pcall(dofile, "vendor/fennel/fennel.lua")
		end
		package.loaded["fennel"] = nil
		local fennel = require("fennel")
		table.insert(package.loaders, fennel.searcher)
		fennel.path =
		  d .. "/runtime/?.fnl;" ..
		  d .. "/../.redin/runtime/?.fnl;" ..
		  (_redin_source_tree and "src/runtime/?.fnl;" or "") ..
		  fennel.path
	`
	if luaL_dostring(L, cstring(raw_data(code))) != 0 {
		msg := lua_tostring_raw(L, -1)
		fmt.eprintfln("Error loading Fennel: %s", msg)
		lua_pop(L, 1)
	}
}
```

The two changes are:
1. `pcall(dofile, "vendor/fennel/fennel.lua")` is now wrapped in `if not ok and _redin_source_tree then`.
2. The `"src/runtime/?.fnl;"` entry in `fennel.path` is conditional on `_redin_source_tree`.

- [ ] **Step 2: Build**

Run: `odin build src/cmd/redin -collection:lib=lib -collection:luajit=vendor/luajit -out:build/redin`
Expected: clean build.

- [ ] **Step 3: Run UI smoke test from source tree (positive case)**

Run:
```bash
./build-dev.sh
./build/redin test/ui/smoke_app.fnl &
sleep 1
bb test/ui/run.bb test/ui/test_smoke.bb
kill %1 2>/dev/null; wait 2>/dev/null
```
Expected: pass. Confirms the source-tree path resolves `src/runtime/init.fnl` via `fennel.path`.

- [ ] **Step 4: Verify the gate from a non-source-tree directory (negative case)**

Run:
```bash
mkdir -p /tmp/redin-h6-check && cd /tmp/redin-h6-check
mkdir -p src/runtime
cat > src/runtime/init.fnl <<'EOF'
;; Poisoned init that would override the real runtime if the
;; cwd-relative fennel.path entry were active.
(error "POISONED INIT WAS LOADED")
EOF
"$OLDPWD/build/redin" "$OLDPWD/test/ui/smoke_app.fnl" &
SERVER_PID=$!
sleep 1
PORT=$(cat .redin-port 2>/dev/null || echo 8800)
TOKEN=$(cat .redin-token 2>/dev/null)
curl -s -H "Authorization: Bearer $TOKEN" "http://localhost:$PORT/state" | head -c 200
echo
kill $SERVER_PID 2>/dev/null; wait 2>/dev/null
cd "$OLDPWD"
rm -rf /tmp/redin-h6-check
```
Expected:
- Binary starts cleanly (no "POISONED INIT" error).
- `/state` returns a JSON document, not an error.
- The poisoned `src/runtime/init.fnl` is **not** loaded because the cwd-relative entry is gated off.

If the binary errors out with `POISONED INIT WAS LOADED`, the gate is broken — investigate before continuing.

- [ ] **Step 5: Commit**

```bash
git add src/redin/bridge/bridge.odin
git commit -m "$(cat <<'EOF'
feat(bridge): gate cwd src/runtime/?.fnl on source tree (#129 H6)

Skip the cwd-relative fennel.path entry and the cwd-relative
fennel.lua fallback when running outside the redin repo. A
poisoned ./src/runtime/init.fnl in a shared workspace is no
longer loaded.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 4: H6 — gate hot-reload watch list on source tree

**Files:**
- Modify: `src/redin/bridge/hotreload.odin` — `hotreload_init` takes a `source_tree: bool` and skips file population when false.
- Modify: `src/redin/bridge/bridge.odin` — pass `b.source_tree` to `hotreload_init`.

- [ ] **Step 1: Update `hotreload_init` signature**

In `src/redin/bridge/hotreload.odin`, replace `hotreload_init` (lines 14-28) with:

```odin
hotreload_init :: proc(hr: ^Hot_Reload, source_tree: bool) {
	hr.check_interval = 60
	if !source_tree do return  // #129 H6: cwd-relative watch list only
	                            // active inside the redin source tree.
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

When `source_tree == false`, `watch_paths` stays empty and `hotreload_check`'s `for path in hr.watch_paths` loop is a no-op. `hotreload_destroy` already handles the empty case.

- [ ] **Step 2: Update the call site in `bridge.odin`**

Locate the `hotreload_init` call in `init` (around `bridge.odin:105`):

```odin
	when REDIN_DEV {
		hotreload_init(&b.hot_reload)
	}
```

Change to:

```odin
	when REDIN_DEV {
		hotreload_init(&b.hot_reload, b.source_tree)
	}
```

- [ ] **Step 3: Build**

Run: `odin build src/cmd/redin -collection:lib=lib -collection:luajit=vendor/luajit -out:build/redin`
Expected: clean build.

- [ ] **Step 4: Run UI smoke test (regression check)**

Run:
```bash
./build-dev.sh
./build/redin test/ui/smoke_app.fnl &
sleep 1
bb test/ui/run.bb test/ui/test_smoke.bb
kill %1 2>/dev/null; wait 2>/dev/null
```
Expected: pass. Hot reload still initialises (with the file list) when running from the source tree.

- [ ] **Step 5: Verify hot reload skips outside source tree**

Run from a non-source-tree directory:
```bash
mkdir -p /tmp/redin-h6-hr && cd /tmp/redin-h6-hr
mkdir -p src/runtime
echo '(error "HOT-RELOAD POISONED")' > src/runtime/init.fnl
"$OLDPWD/build/redin" "$OLDPWD/test/ui/smoke_app.fnl" &
SERVER_PID=$!
sleep 1
# Mutate the poisoned file; if hot reload were watching it, the
# server would re-execute the file and crash on the (error ...) call.
echo '(error "HOT-RELOAD STILL POISONED")' > src/runtime/init.fnl
sleep 2
PORT=$(cat .redin-port 2>/dev/null || echo 8800)
TOKEN=$(cat .redin-token 2>/dev/null)
curl -s -o /dev/null -w "%{http_code}\n" -H "Authorization: Bearer $TOKEN" "http://localhost:$PORT/state"
kill $SERVER_PID 2>/dev/null; wait 2>/dev/null
cd "$OLDPWD"
rm -rf /tmp/redin-h6-hr
```
Expected: `200`. The dev server keeps responding because the cwd-relative file list is empty outside the source tree.

- [ ] **Step 6: Commit**

```bash
git add src/redin/bridge/hotreload.odin src/redin/bridge/bridge.odin
git commit -m "$(cat <<'EOF'
feat(bridge): gate hot-reload watch list on source tree (#129 H6)

hotreload_init takes a source_tree bool and skips the cwd-relative
src/runtime/*.fnl file list when running outside the redin repo.
Closes the H6 cwd-relative attack surface.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 5: H8 — `Conn_Queue` type and unit tests

**Files:**
- Modify: `src/redin/bridge/devserver.odin` — add `Pending_Conn`, `Conn_Queue`, `conn_push`, `conn_pop_blocking`, and `HANDLER_POOL_SIZE`.
- Create: `src/redin/bridge/devserver_pool_test.odin` — unit tests for queue ops.

- [ ] **Step 1: Write the failing test**

Create `src/redin/bridge/devserver_pool_test.odin`:

```odin
package bridge

// Tests for the dev-server handler-pool queue introduced for
// issue #129 H8. The queue is a simple sema-blocked FIFO of socket
// pointers; the acceptor pushes, handlers pop. A nil push is the
// shutdown sentinel.

import "core:container/queue"
import "core:testing"

@(test)
test_conn_queue_fifo :: proc(t: ^testing.T) {
	cq: Conn_Queue
	queue.init(&cq.q)
	defer queue.destroy(&cq.q)

	pc1 := new(Pending_Conn);  defer free(pc1)
	pc2 := new(Pending_Conn);  defer free(pc2)

	conn_push(&cq, pc1)
	conn_push(&cq, pc2)

	got1 := conn_pop_blocking(&cq)
	got2 := conn_pop_blocking(&cq)

	testing.expect(t, got1 == pc1, "first pop should return first push")
	testing.expect(t, got2 == pc2, "second pop should return second push")
}

@(test)
test_conn_queue_nil_sentinel :: proc(t: ^testing.T) {
	cq: Conn_Queue
	queue.init(&cq.q)
	defer queue.destroy(&cq.q)

	conn_push(&cq, nil)
	got := conn_pop_blocking(&cq)
	testing.expect(t, got == nil, "nil sentinel must round-trip")
}

@(test)
test_handler_pool_size_constant :: proc(t: ^testing.T) {
	// Pool size is part of the contract — fix the value here so an
	// accidental tweak in devserver.odin trips this test.
	testing.expect_value(t, HANDLER_POOL_SIZE, 4)
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `odin test src/redin/bridge -collection:lib=lib -collection:luajit=vendor/luajit`
Expected: compile error — `Conn_Queue`, `Pending_Conn`, `conn_push`, `conn_pop_blocking`, `HANDLER_POOL_SIZE` undefined.

- [ ] **Step 3: Add types and ops to `devserver.odin`**

In `src/redin/bridge/devserver.odin`, locate the `Sync_Queue` struct definition (around line 38-41). Immediately after it, add:

```odin
// --- Handler pool queue (#129 H8) ---

HANDLER_POOL_SIZE :: 4

Pending_Conn :: struct {
	socket: net.TCP_Socket,
}

Conn_Queue :: struct {
	q:    queue.Queue(^Pending_Conn),
	mu:   sync.Mutex,
	sema: sync.Sema,
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

- [ ] **Step 4: Run test to verify it passes**

Run: `odin test src/redin/bridge -collection:lib=lib -collection:luajit=vendor/luajit`
Expected: PASS for the three new tests; existing bridge tests still pass.

- [ ] **Step 5: Commit**

```bash
git add src/redin/bridge/devserver.odin src/redin/bridge/devserver_pool_test.odin
git commit -m "$(cat <<'EOF'
feat(bridge): add Conn_Queue for dev-server handler pool (#129 H8)

Sema-blocked FIFO of socket pointers used by the upcoming
acceptor + 4-handler restructure. nil push = handler shutdown
sentinel. Unit tests cover FIFO order, nil round-trip, and
the HANDLER_POOL_SIZE constant.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 6: H8 — extract `handle_one_connection`

**Files:**
- Modify: `src/redin/bridge/devserver.odin` — lift the per-request body of `server_thread_proc` into `handle_one_connection(ds, client, stack_buf)`. No behaviour change.

- [ ] **Step 1: Add `handle_one_connection` proc**

In `src/redin/bridge/devserver.odin`, locate `server_thread_proc :: proc(ds: ^Dev_Server)` (around line 253). The current shape is:

```odin
server_thread_proc :: proc(ds: ^Dev_Server) {
	stack_buf: [8192]u8
	MAX_BODY :: 1024 * 1024

	for ds.running {
		client, _, accept_err := net.accept_tcp(ds.tcp_sock)
		if accept_err != nil || !ds.running {
			break
		}
		// ... 200+ lines of recv/host/auth/enqueue/send/close ...
	}
}
```

Replace it entirely with:

```odin
server_thread_proc :: proc(ds: ^Dev_Server) {
	stack_buf: [8192]u8
	for ds.running {
		client, _, accept_err := net.accept_tcp(ds.tcp_sock)
		if accept_err != nil || !ds.running {
			break
		}
		handle_one_connection(ds, client, stack_buf[:])
	}
}

// Existing single-thread per-request handling, unchanged. Lifted out
// of server_thread_proc so the upcoming handler-pool restructure
// (#129 H8) can call the same body from N worker threads.
handle_one_connection :: proc(ds: ^Dev_Server, client: net.TCP_Socket, stack_buf: []u8) {
	MAX_BODY :: 1024 * 1024

	// Receive timeout on this client: each recv returns within
	// CLIENT_RECV_TIMEOUT even if the peer sends nothing, so
	// "open TCP and stall" no longer pins the server thread.
	// Ignore errors — a missing timeout isn't fatal, it just
	// means we fall back to the per-request deadline below.
	_ = net.set_option(client, .Receive_Timeout, CLIENT_RECV_TIMEOUT)

	deadline := time.time_add(time.now(), CLIENT_REQUEST_DEADLINE)

	buf: []u8 = stack_buf
	heap_buf: []u8
	defer if heap_buf != nil do delete(heap_buf)

	// Read full request into buffer
	total := 0
	too_large := false
	bad_request := false
	timed_out := false
	for {
		if time.diff(time.now(), deadline) < 0 {
			timed_out = true
			break
		}
		n, recv_err := net.recv_tcp(client, buf[total:])
		if recv_err != nil || n <= 0 {
			break
		}
		total += n
		// Check for end of headers (double CRLF)
		if total >= 4 {
			req_str := string(buf[:total])
			if header_end := strings.index(req_str, "\r\n\r\n"); header_end >= 0 {
				// Check Content-Length for body
				cl := find_content_length(req_str[:header_end])
				body_start := header_end + 4
				if cl < 0 {
					bad_request = true
					break
				}
				if cl > MAX_BODY {
					too_large = true
					break
				}
				needed := body_start + cl
				if needed > len(buf) {
					heap_buf = make([]u8, needed)
					copy(heap_buf, buf[:total])
					buf = heap_buf
				}
				for total < needed {
					if time.diff(time.now(), deadline) < 0 {
						timed_out = true
						break
					}
					n2, err2 := net.recv_tcp(client, buf[total:])
					if err2 != nil || n2 <= 0 do break
					total += n2
				}
				break
			}
		}
		if total >= len(buf) {
			// Headers did not fit in the stack buffer
			too_large = true
			break
		}
	}

	if timed_out {
		resp := "HTTP/1.1 408 Request Timeout\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
		net.send_tcp(client, transmute([]u8)resp)
		net.close(client)
		return
	}

	if too_large {
		resp := "HTTP/1.1 413 Payload Too Large\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
		net.send_tcp(client, transmute([]u8)resp)
		net.close(client)
		return
	}

	if bad_request {
		resp := "HTTP/1.1 400 Bad Request\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
		net.send_tcp(client, transmute([]u8)resp)
		net.close(client)
		return
	}

	if total == 0 {
		net.close(client)
		return
	}

	req_str := string(buf[:total])

	// Parse request line
	rline_end := strings.index(req_str, "\r\n")
	if rline_end < 0 {
		net.close(client)
		return
	}
	rline := req_str[:rline_end]

	method, path: string
	{
		sp1 := strings.index_byte(rline, ' ')
		if sp1 < 0 {
			net.close(client)
			return
		}
		method = rline[:sp1]
		rest := rline[sp1 + 1:]
		sp2 := strings.index_byte(rest, ' ')
		path = rest[:sp2] if sp2 >= 0 else rest
	}

	// Split headers / body. Headers are everything up to the first
	// "\r\n\r\n" — the request line is included, which is fine:
	// header lookup works with any leading line, and the second
	// line onward are real headers.
	headers := req_str
	body := ""
	if header_end := strings.index(req_str, "\r\n\r\n"); header_end >= 0 {
		headers = req_str[:header_end]
		body_start := header_end + 4
		if body_start < total {
			body = req_str[body_start:]
		}
	}

	// DNS-rebinding defence: require Host: localhost:<port> or
	// 127.0.0.1:<port>. A malicious site resolving an attacker
	// hostname to 127.0.0.1 would send a different Host header,
	// so the request is rejected before the auth check runs.
	host_ok := check_host_header(headers, ds.expected_host_v4, ds.expected_host_name)
	if !host_ok {
		deny := "HTTP/1.1 403 Forbidden\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
		net.send_tcp(client, transmute([]u8)deny)
		net.close(client)
		return
	}

	// OPTIONS: reject — we don't serve CORS preflight. With auth
	// required and no Access-Control-Allow-Origin emitted, browsers
	// can't make cross-origin calls regardless, so OPTIONS has no
	// legitimate use here.
	if method == "OPTIONS" {
		deny := "HTTP/1.1 405 Method Not Allowed\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
		net.send_tcp(client, transmute([]u8)deny)
		net.close(client)
		return
	}

	// Require a matching Bearer token on every non-OPTIONS request.
	if !check_bearer_token(headers, ds.auth_token) {
		deny := "HTTP/1.1 401 Unauthorized\r\nWWW-Authenticate: Bearer\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
		net.send_tcp(client, transmute([]u8)deny)
		net.close(client)
		return
	}

	// Dispatch to main thread
	channel: Response_Channel
	pending := new(Pending_Request)
	pending.method = method
	pending.path = path
	pending.body = body
	pending.response = &channel

	sync_queue_push(&ds.incoming, pending)
	sync.sema_wait(&channel.done)

	// Build and send HTTP response
	status_line := status_text(channel.status)
	ct := channel.content_type if len(channel.content_type) > 0 else "application/json"
	resp_body := channel.body if len(channel.body) > 0 else ""
	body_len := len(channel.binary) if len(channel.binary) > 0 else len(resp_body)

	send_str(client, "HTTP/1.1 ")
	send_str(client, status_line)
	send_str(client, "\r\nContent-Type: ")
	send_str(client, ct)
	send_str(client, "\r\nContent-Length: ")
	{
		int_buf: [20]u8
		send_str(client, int_to_str(int_buf[:], body_len))
	}
	send_str(client, "\r\nConnection: close\r\n\r\n")

	if len(channel.binary) > 0 {
		net.send_tcp(client, channel.binary)
	} else {
		send_str(client, resp_body)
	}

	net.close(client)
	sync.sema_post(&channel.ack)
	free(pending)
}
```

The body is byte-for-byte identical to the existing code; the only differences are (a) early-out is `return` instead of `continue`, (b) the `MAX_BODY` const is local to `handle_one_connection`, (c) `buf` is now `stack_buf` from the parameter rather than a local stack slice.

- [ ] **Step 2: Build**

Run: `odin build src/cmd/redin -collection:lib=lib -collection:luajit=vendor/luajit -out:build/redin`
Expected: clean build.

- [ ] **Step 3: Run dev-server unit tests**

Run: `odin test src/redin/bridge -collection:lib=lib -collection:luajit=vendor/luajit`
Expected: existing devserver tests still pass; pool tests still pass.

- [ ] **Step 4: Run UI smoke test (end-to-end regression)**

Run:
```bash
./build-dev.sh
./build/redin test/ui/smoke_app.fnl &
sleep 1
bb test/ui/run.bb test/ui/test_smoke.bb
kill %1 2>/dev/null; wait 2>/dev/null
```
Expected: pass.

- [ ] **Step 5: Commit**

```bash
git add src/redin/bridge/devserver.odin
git commit -m "$(cat <<'EOF'
refactor(bridge): extract handle_one_connection (#129 H8)

Lifts the per-request body of server_thread_proc into a separate
proc with no behaviour change. The upcoming handler-pool
restructure will call the same body from N worker threads.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 7: H8 — replace single thread with acceptor + handler pool

**Files:**
- Modify: `src/redin/bridge/devserver.odin` — restructure `Dev_Server` (drop `server_thread`, add `accepted_conns`, `acceptor_thread`, `handler_threads`); add `acceptor_thread_proc` and `handler_thread_proc`; update `devserver_init` and `devserver_destroy`; remove `server_thread_proc`.

- [ ] **Step 1: Update `Dev_Server` struct**

In `src/redin/bridge/devserver.odin`, locate the `Dev_Server` struct (around line 43-56). Replace `server_thread: ^thread.Thread` with three new fields:

```odin
Dev_Server :: struct {
	bridge:             ^Bridge,
	tcp_sock:           net.TCP_Socket,
	port:               int,
	auth_token:         string, // 64-char hex, required as Bearer on every non-OPTIONS request
	expected_host_v4:   string, // "127.0.0.1:<port>"
	expected_host_name: string, // "localhost:<port>"
	accepted_conns:     Conn_Queue,
	acceptor_thread:    ^thread.Thread,
	handler_threads:    [HANDLER_POOL_SIZE]^thread.Thread,
	incoming:           Sync_Queue,
	event_queue:        [dynamic]types.InputEvent,
	current_rects:      []rl.Rectangle, // borrowed during a poll cycle, nil otherwise
	running:            bool,
	shutdown_requested: bool,
}
```

- [ ] **Step 2: Replace `server_thread_proc` with acceptor + handler procs**

Delete the current `server_thread_proc :: proc(ds: ^Dev_Server)` (the trimmed version from Task 6 — the outer `for ds.running { accept; handle_one_connection }` loop). Replace it with:

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
	// Wake every handler so they observe the nil sentinel and exit.
	for _ in 0 ..< HANDLER_POOL_SIZE {
		conn_push(&ds.accepted_conns, nil)
	}
}

handler_thread_proc :: proc(ds: ^Dev_Server) {
	stack_buf: [8192]u8
	for {
		pc := conn_pop_blocking(&ds.accepted_conns)
		if pc == nil do return
		handle_one_connection(ds, pc.socket, stack_buf[:])
		free(pc)
	}
}
```

- [ ] **Step 3: Initialise the queue and start the threads in `devserver_init`**

Locate `devserver_init` (around line 122). Find:

```odin
	queue.init(&ds.incoming.q)
```

Add immediately after:

```odin
	queue.init(&ds.accepted_conns.q)
```

Then locate the existing `thread.create_and_start_with_poly_data` call (around line 171):

```odin
	ds.server_thread = thread.create_and_start_with_poly_data(ds, server_thread_proc, context)
	fmt.printfln("Dev server listening on http://localhost:%d (auth token in %s)", bound_port, TOKEN_FILE)
```

Replace with:

```odin
	ds.acceptor_thread = thread.create_and_start_with_poly_data(ds, acceptor_thread_proc, context)
	for i in 0 ..< HANDLER_POOL_SIZE {
		ds.handler_threads[i] = thread.create_and_start_with_poly_data(ds, handler_thread_proc, context)
	}
	fmt.printfln("Dev server listening on http://localhost:%d (auth token in %s)", bound_port, TOKEN_FILE)
```

- [ ] **Step 4: Update `devserver_destroy` for ordered shutdown**

Locate `devserver_destroy` (around line 211). The current shutdown block is:

```odin
	if ds.running {
		ds.running = false
		// Connect to unblock the accept call
		if unblock, err := net.dial_tcp(net.Endpoint{address = net.IP4_Loopback, port = ds.port}); err == nil {
			net.close(unblock)
		}
		if ds.server_thread != nil {
			thread.join(ds.server_thread)
			thread.destroy(ds.server_thread)
		}
		net.close(ds.tcp_sock)
		os.remove(PORT_FILE)
		os.remove(TOKEN_FILE)
	}
```

Replace with:

```odin
	if ds.running {
		ds.running = false
		// Connect-and-close to unblock the accept call.
		if unblock, err := net.dial_tcp(net.Endpoint{address = net.IP4_Loopback, port = ds.port}); err == nil {
			net.close(unblock)
		}
		if ds.acceptor_thread != nil {
			thread.join(ds.acceptor_thread)
			thread.destroy(ds.acceptor_thread)
		}
		// Acceptor pushed HANDLER_POOL_SIZE nils on its way out; each
		// handler will pop one nil and exit.
		for t in ds.handler_threads {
			if t != nil {
				thread.join(t)
				thread.destroy(t)
			}
		}
		net.close(ds.tcp_sock)
		// Defensive drain: any Pending_Conn the acceptor enqueued before
		// it observed running=false has already been consumed by a
		// handler in the join above. The queue should be empty here, but
		// if it isn't (e.g. tighter races on slow hosts), close the
		// stragglers so we don't leak file descriptors.
		for {
			sync.lock(&ds.accepted_conns.mu)
			empty := queue.len(ds.accepted_conns.q) == 0
			sync.unlock(&ds.accepted_conns.mu)
			if empty do break
			pc, ok := queue.pop_front_safe(&ds.accepted_conns.q)
			if !ok do break
			if pc != nil {
				net.close(pc.socket)
				free(pc)
			}
		}
		os.remove(PORT_FILE)
		os.remove(TOKEN_FILE)
	}
```

Then locate the existing `queue.destroy(&ds.incoming.q)` near the bottom of `devserver_destroy` (around line 229). Add immediately after:

```odin
	queue.destroy(&ds.accepted_conns.q)
```

- [ ] **Step 5: Build**

Run: `odin build src/cmd/redin -collection:lib=lib -collection:luajit=vendor/luajit -out:build/redin`
Expected: clean build. If a stale reference to `server_thread` or `server_thread_proc` remains, Odin will name it.

- [ ] **Step 6: Run all bridge unit tests**

Run: `odin test src/redin/bridge -collection:lib=lib -collection:luajit=vendor/luajit`
Expected: PASS.

- [ ] **Step 7: Run UI smoke test (regression)**

Run:
```bash
./build-dev.sh
./build/redin test/ui/smoke_app.fnl &
sleep 1
bb test/ui/run.bb test/ui/test_smoke.bb
kill %1 2>/dev/null; wait 2>/dev/null
```
Expected: pass.

- [ ] **Step 8: Memory-leak check on shutdown**

Run:
```bash
./build/redin test/ui/smoke_app.fnl &
SERVER_PID=$!
sleep 1
PORT=$(cat .redin-port); TOKEN=$(cat .redin-token)
curl -s -X POST -H "Authorization: Bearer $TOKEN" "http://localhost:$PORT/shutdown"
wait $SERVER_PID 2>&1 | grep -E "leak|outstanding" || echo "no leaks reported"
```
Expected: `no leaks reported`. The dev build links the tracking allocator, so any unbalanced `new(Pending_Conn)` / `make(...)` would print a leak summary on exit.

- [ ] **Step 9: Commit**

```bash
git add src/redin/bridge/devserver.odin
git commit -m "$(cat <<'EOF'
feat(bridge): acceptor + 4-handler pool for dev server (#129 H8)

Replaces the single accept-loop thread with one acceptor and four
handler threads that share a sema-blocked Conn_Queue. Concurrent
in-flight requests are bounded at 4; one slow client can no longer
block the next. Per-request latency is unchanged because the main
thread remains the single processor.

Shutdown sequence: clear running, unblock accept via dial+close,
join acceptor (which pushes 4 nil sentinels), join the four
handlers, defensively drain any straggler conns.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 8: H8 — integration test exercising the pool

**Files:**
- Create: `test/ui/devserver_pool_app.fnl`
- Create: `test/ui/test_devserver_pool.bb`

- [ ] **Step 1: Write the minimal app**

Create `test/ui/devserver_pool_app.fnl`:

```fennel
;; Minimal app for the dev-server handler-pool test (#129 H8).
;; The test only exercises HTTP behaviour, so the app just needs a
;; valid frame and a non-empty state.
(local dataflow (require :dataflow))

(dataflow.init {:counter 0})

(global redin_get_state (. dataflow :_get-raw-db))

(reg-sub :sub/counter
  (fn [db] (get db :counter)))

(reg-view :main
  (fn []
    [:vbox {}
      [:text {} "devserver-pool app"]]))
```

- [ ] **Step 2: Write the failing test**

Create `test/ui/test_devserver_pool.bb`:

```clojure
;; Integration test for the dev-server handler pool (#129 H8).
;;
;; Opens three TCP connections that send a partial HTTP request and
;; never finish the headers. With the old single-thread design the
;; first stalled connection would hold the loop until its 30s
;; deadline, blocking every other client. With the acceptor +
;; 4-handler pool, three stalled connections still leave one
;; handler free, so a fourth normal request must complete promptly.

(require '[redin-test :refer :all]
         '[babashka.http-client :as http])

(deftest pool-allows-concurrent-requests-while-others-stall
  (let [port  (read-port-file)
        token (read-token-file)]
    (assert port  "expected .redin-port to be present")
    (assert token "expected .redin-token to be present")
    (let [stalled (doall
                    (for [_ (range 3)]
                      (let [s (java.net.Socket. "127.0.0.1" port)]
                        (.write (.getOutputStream s)
                                (.getBytes "GET /state HTTP/1.1\r\n"))
                        (.flush (.getOutputStream s))
                        s)))]
      (try
        ;; Give the acceptor a moment to enqueue all three stalled conns
        ;; and three handlers a moment to pick them up.
        (Thread/sleep 200)
        (let [start (System/currentTimeMillis)
              resp  (http/get (str "http://localhost:" port "/state")
                              {:headers {"Authorization" (str "Bearer " token)}
                               :timeout 5000})
              took  (- (System/currentTimeMillis) start)]
          (assert (= 200 (:status resp))
                  (str "fourth request returned " (:status resp)
                       ", expected 200"))
          (assert (< took 2000)
                  (str "fourth request took " took
                       "ms (>2s) — handler pool is not active")))
        (finally
          (doseq [s stalled]
            (try (.close s) (catch Exception _))))))))
```

- [ ] **Step 3: Run the test against the new pool build**

Run:
```bash
./build-dev.sh
./build/redin test/ui/devserver_pool_app.fnl &
sleep 1
bb test/ui/run.bb test/ui/test_devserver_pool.bb
kill %1 2>/dev/null; wait 2>/dev/null
```
Expected: `1 passed, 0 failed`.

- [ ] **Step 4: Sanity-check that the test would catch a regression**

Manual gut check (don't commit a regression — just verify the test logic):

```bash
# Inspect the test: confirm the assertion would fail with took >= 2000ms
# under the single-thread design. (The test sleeps 200ms after opening
# 3 stalled connections, then times the 4th request. Single-thread:
# the first stalled connection holds the loop until CLIENT_REQUEST_DEADLINE
# (30s), so the 4th request can't even reach `accept` until then. With the
# pool, the 4th request lands on a free handler within milliseconds.)
grep -n "Thread/sleep\|< took 2000\|range 3" test/ui/test_devserver_pool.bb
```

Expected: greps return the three lines documenting the wait/cap/fanout. No code change.

- [ ] **Step 5: Run the full UI suite to confirm no regressions**

Run:
```bash
bash test/ui/run-all.sh --headless
```
Expected: every test passes, including the new `test_devserver_pool`.

- [ ] **Step 6: Commit**

```bash
git add test/ui/devserver_pool_app.fnl test/ui/test_devserver_pool.bb
git commit -m "$(cat <<'EOF'
test(ui): integration test for dev-server handler pool (#129 H8)

Three stalled TCP connections + a normal GET /state. The fourth
request must complete within 2s; under the single-thread design
it would block until the first stalled connection's 30s deadline.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 9: documentation sync + final verification

**Files:**
- Modify: `.claude/skills/redin-maintenance/SKILL.md` — add `devserver_pool` to the listed UI test suites.
- Modify: `docs/reference/dev-server.md` (only if the file lists internal threading details — likely not; check first).

- [ ] **Step 1: Check whether dev-server docs reference the internal threading model**

Run: `rg -n "single.thread|server_thread|accept loop" docs/`
Expected: no matches, or matches only in spec/plan files (not in `docs/reference/` or `docs/core-api.md`). If any user-facing doc claims a single-thread accept loop, update it to mention "small handler pool".

- [ ] **Step 2: Add `devserver_pool` to the UI test suite list**

In `.claude/skills/redin-maintenance/SKILL.md`, locate the line that lists test suites (around the "Available test suites" section):

```
`smoke`, `input`, `button`, `canvas`, `drag`, `image`, `line_height`, `modal`, `multiline`, `popout`, `resize`, `scroll`, `scroll_x`, `shadow`, `text_select`, `viewport`, `animate`
```

Append `, `devserver_pool``:

```
`smoke`, `input`, `button`, `canvas`, `drag`, `image`, `line_height`, `modal`, `multiline`, `popout`, `resize`, `scroll`, `scroll_x`, `shadow`, `text_select`, `viewport`, `animate`, `devserver_pool`
```

- [ ] **Step 3: Run the full verification matrix**

```bash
odin build src/cmd/redin -collection:lib=lib -collection:luajit=vendor/luajit -out:build/redin
luajit test/lua/runner.lua test/lua/test_*.fnl
odin test src/redin/parser
odin test src/redin/markdown -collection:lib=lib -collection:luajit=vendor/luajit
odin test src/redin/profile  -collection:lib=lib -collection:luajit=vendor/luajit
odin test src/redin/input    -collection:lib=lib -collection:luajit=vendor/luajit -define:ODIN_TEST_THREADS=1
odin test src/redin/bridge   -collection:lib=lib -collection:luajit=vendor/luajit
./build-dev.sh
bash test/ui/run-all.sh --headless
```
Expected: every step succeeds. Bridge tests include the new `source_tree` and `devserver_pool` test files. UI suite includes `test_devserver_pool`.

- [ ] **Step 4: Memory-leak sanity sweep**

Run:
```bash
./build-dev.sh && bash test/ui/run-all.sh --headless 2>&1 | grep -E "leak|outstanding" || echo "no leaks across the UI suite"
```
Expected: `no leaks across the UI suite`.

- [ ] **Step 5: Commit**

```bash
git add .claude/skills/redin-maintenance/SKILL.md
git commit -m "$(cat <<'EOF'
docs(skills): list devserver_pool in maintenance test suites (#129)

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

If `rg` in step 1 surfaced user-facing docs that mention the single-thread loop, fold that fix into this commit (or its own `docs(reference): ...` commit if substantive).

---

## Self-review checklist (run after the plan is written)

- **Spec coverage**:
  - H6 marker → Task 1.
  - H6 `setup_lua_paths` gate → Task 2.
  - H6 `load_fennel` gate → Task 3.
  - H6 hot-reload gate → Task 4.
  - H8 queue type + ops → Task 5.
  - H8 extract per-request body → Task 6.
  - H8 acceptor + handler pool + shutdown → Task 7.
  - H8 integration test → Task 8.
  - Docs sync + verification → Task 9.
- **Placeholders**: scanned for "TBD", "TODO", "Similar to Task N", "appropriate error handling" — none.
- **Type consistency**: `Conn_Queue`, `Pending_Conn`, `conn_push`, `conn_pop_blocking`, `HANDLER_POOL_SIZE`, `acceptor_thread`, `handler_threads`, `accepted_conns`, `is_redin_source_tree`, `is_redin_source_tree_at`, `source_tree` (field), `handle_one_connection` — same names used everywhere they appear.
