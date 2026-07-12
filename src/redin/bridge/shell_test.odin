package bridge

import "core:fmt"
import "core:mem"
import "core:strings"
import "core:sync"
import "core:sys/linux"
import "core:testing"
import "core:thread"
import "core:time"

// Regression tests for the shell env allowlist.
//
// When set_shell_env_allowlist is set to a non-nil slice, child processes
// spawned by execute_shell see only the env vars whose KEYs match an
// entry in the allowlist (exact match, case-sensitive). When unset
// (default, nil) the child gets an empty environment — secure-by-default
// per #136 H3. The sentinel "*" entry restores full parent-env passthrough
// (the pre-#136 default) for apps that explicitly opt in.

// Tests in this file mutate the package-level shell env allowlist
// (g_shell_env_allowlist). Odin's test runner runs tests in parallel by
// default, so a test that sets the allowlist can race against another
// test that calls execute_shell and depends on the allowlist being unset.
// Acquire this mutex in any test that either calls set_shell_env_allowlist
// or relies on the default-empty-env behaviour.
@(private = "file")
g_test_shell_state_mutex: sync.Mutex

// Deny-by-default env (#136 H3) means tests that spawn children needing
// $PATH to find their cmd (yes, sleep, etc.) must opt in to passthrough.
// The sentinel "*" entry restores full parent-env inheritance.
@(private = "file")
allow_open_shell_env :: proc() {
	set_shell_env_allowlist([]string{"*"})
}

@(test)
test_shell_env_allowlist_filters :: proc(t: ^testing.T) {
	sync.lock(&g_test_shell_state_mutex)
	defer sync.unlock(&g_test_shell_state_mutex)

	// /usr/bin/env exists on Linux/macOS; Linux is the supported platform.
	set_shell_env_allowlist([]string{"PATH"})
	defer set_shell_env_allowlist(nil)

	cmd := make([]string, 1)
	cmd[0] = strings.clone("/usr/bin/env")
	defer { for s in cmd do delete(s); delete(cmd) }

	req := Shell_Request{
		id    = strings.clone("env-1"),
		cmd   = cmd,
		stdin = strings.clone(""),
	}
	defer { delete(req.id); delete(req.stdin) }

	got := execute_shell(req)
	defer {
		delete(got.id); delete(got.stdout); delete(got.stderr); delete(got.error_msg)
	}

	// stdout should contain PATH=... but no other typical user env vars.
	testing.expect(t, strings.contains(got.stdout, "PATH="),
		"expected PATH in env output")
	testing.expect(t, !strings.contains(got.stdout, "HOME="),
		"expected HOME stripped by allowlist")
}

@(test)
test_shell_env_allowlist_unset_is_empty :: proc(t: ^testing.T) {
	sync.lock(&g_test_shell_state_mutex)
	defer sync.unlock(&g_test_shell_state_mutex)

	// Default (nil allowlist) must mean empty env after #136 H3.
	set_shell_env_allowlist(nil)

	cmd := make([]string, 1)
	cmd[0] = strings.clone("/usr/bin/env")
	defer { for s in cmd do delete(s); delete(cmd) }
	req := Shell_Request{
		id    = strings.clone("env-empty"),
		cmd   = cmd,
		stdin = strings.clone(""),
	}
	defer { delete(req.id); delete(req.stdin) }

	got := execute_shell(req)
	defer {
		delete(got.id); delete(got.stdout); delete(got.stderr); delete(got.error_msg)
	}
	// /usr/bin/env should print nothing — no PATH, no HOME, no anything.
	testing.expect(t, !strings.contains(got.stdout, "PATH="),
		fmt.tprintf("expected empty env (deny-by-default), got %q", got.stdout))
	testing.expect(t, !strings.contains(got.stdout, "HOME="),
		fmt.tprintf("expected empty env (deny-by-default), got %q", got.stdout))
}

@(test)
test_shell_env_allowlist_wildcard_is_full_passthrough :: proc(t: ^testing.T) {
	sync.lock(&g_test_shell_state_mutex)
	defer sync.unlock(&g_test_shell_state_mutex)

	// The sentinel "*" entry is the explicit opt-out of deny-by-default.
	set_shell_env_allowlist([]string{"*"})
	defer set_shell_env_allowlist(nil)

	cmd := make([]string, 1)
	cmd[0] = strings.clone("/usr/bin/env")
	defer { for s in cmd do delete(s); delete(cmd) }
	req := Shell_Request{
		id    = strings.clone("env-star"),
		cmd   = cmd,
		stdin = strings.clone(""),
	}
	defer { delete(req.id); delete(req.stdin) }

	got := execute_shell(req)
	defer {
		delete(got.id); delete(got.stdout); delete(got.stderr); delete(got.error_msg)
	}
	// PATH is reliably present in the test runner's env.
	testing.expect(t, strings.contains(got.stdout, "PATH="),
		"expected PATH= in wildcard-passthrough env output")
}

@(test)
test_shell_output_cap_kills_child :: proc(t: ^testing.T) {
	sync.lock(&g_test_shell_state_mutex)
	defer sync.unlock(&g_test_shell_state_mutex)
	allow_open_shell_env()
	defer set_shell_env_allowlist(nil)

	// `yes` runs forever; with a 1 MiB cap it should be killed quickly.
	cmd := make([]string, 1)
	cmd[0] = strings.clone("yes")
	defer { for s in cmd do delete(s); delete(cmd) }

	req := Shell_Request{
		id = strings.clone("cap-1"),
		cmd = cmd,
		stdin = strings.clone(""),
		max_output_bytes = 1 * 1024 * 1024,
	}
	defer { delete(req.id); delete(req.stdin) }

	got := execute_shell(req)
	defer {
		delete(got.id); delete(got.stdout); delete(got.stderr); delete(got.error_msg)
	}

	testing.expect_value(t, got.exit_code, -1)
	testing.expect(t, strings.contains(got.error_msg, "exceeded"),
		fmt.tprintf("expected 'exceeded' in error_msg, got %q", got.error_msg))
	testing.expect_value(t, len(got.stdout), 0)
	testing.expect_value(t, len(got.stderr), 0)
}

@(test)
test_shell_timeout_kills_child :: proc(t: ^testing.T) {
	sync.lock(&g_test_shell_state_mutex)
	defer sync.unlock(&g_test_shell_state_mutex)
	allow_open_shell_env()
	defer set_shell_env_allowlist(nil)

	// `sleep 60` should be killed by a 200 ms timeout.
	cmd := make([]string, 2)
	cmd[0] = strings.clone("sleep")
	cmd[1] = strings.clone("60")
	defer { for s in cmd do delete(s); delete(cmd) }

	req := Shell_Request{
		id = strings.clone("to-1"),
		cmd = cmd,
		stdin = strings.clone(""),
		timeout_ms = 200,
	}
	defer { delete(req.id); delete(req.stdin) }

	got := execute_shell(req)
	defer {
		delete(got.id); delete(got.stdout); delete(got.stderr); delete(got.error_msg)
	}

	testing.expect_value(t, got.exit_code, -1)
	testing.expect(t, strings.contains(got.error_msg, "timeout"),
		fmt.tprintf("expected 'timeout' in error_msg, got %q", got.error_msg))
}

// Regression test for #214: shell worker threads ran under
// runtime.default_context(), so Shell_Response strings were allocated with
// the plain heap allocator while the main thread freed them with whatever
// context.allocator it runs under — the tracking allocator in
// REDIN_TRACK_MEM builds, which trapped on the mismatched free (SIGILL)
// the moment the first :shell result was delivered. shell_client_request
// now hands the caller's context to the worker (mirroring Http_Client), so
// every allocation that crosses the thread boundary — response strings,
// the request strings freed worker-side, the Shell_Thread_Data box, the
// results array's backing — goes through one allocator.

@(test)
test_shell_worker_uses_caller_allocator :: proc(t: ^testing.T) {
	// Mirror REDIN_TRACK_MEM: wrap this test's allocator in a tracking
	// allocator. Record bad frees instead of panicking (the default
	// callback traps -> SIGILL) so a regression fails with a message.
	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, context.allocator)
	defer mem.tracking_allocator_destroy(&track)
	track.bad_free_callback = mem.tracking_allocator_bad_free_callback_add_to_array
	context.allocator = mem.tracking_allocator(&track)

	sc: Shell_Client
	shell_client_init(&sc)

	// Absolute path: the env allowlist is deny-by-default, so the child
	// has no PATH to resolve against (see shell_test.odin).
	cmd := make([]string, 2)
	cmd[0] = strings.clone("/bin/echo")
	cmd[1] = strings.clone("cross-thread")
	req := Shell_Request {
		id    = strings.clone("track-1"),
		cmd   = cmd,
		stdin = strings.clone(""),
	}
	// The worker owns req from here (shell_thread_proc frees it).
	shell_client_request(&sc, req)

	// Drain like bridge.poll_shell does: copy results out, then free each
	// response on this thread — the exact free that trapped pre-fix.
	results: [dynamic]Shell_Response
	deadline := time.time_add(time.now(), 5 * time.Second)
	for time.diff(time.now(), deadline) > 0 {
		shell_client_poll(&sc, &results)
		if len(results) > 0 do break
		time.sleep(20 * time.Millisecond)
	}

	testing.expect(t, len(results) == 1, "expected one shell result")
	if len(results) == 1 {
		testing.expectf(t, strings.has_prefix(results[0].stdout, "cross-thread"),
			"unexpected stdout %q", results[0].stdout)
	}
	for &r in results do shell_response_destroy(&r)
	delete(results)

	shell_client_destroy(&sc)

	// The worker's Thread struct was also allocated under the tracking
	// allocator and is self-freed shortly after the worker proc returns
	// (after workers_alive hits 0), so give the books a moment to balance.
	outstanding := -1
	balance_deadline := time.time_add(time.now(), 2 * time.Second)
	for time.diff(time.now(), balance_deadline) > 0 {
		sync.lock(&track.mutex)
		outstanding = len(track.allocation_map)
		sync.unlock(&track.mutex)
		if outstanding == 0 do break
		time.sleep(10 * time.Millisecond)
	}

	for bf in track.bad_free_array {
		testing.expectf(t, false,
			"bad free of %p at %v — worker and main thread disagree on the allocator (#214)",
			bf.memory, bf.location)
	}
	testing.expectf(t, outstanding == 0,
		"%d allocation(s) never freed through the caller's allocator (#214)", outstanding)
}

// #172: a non-string element in the :cmd table must be rejected, not
// silently turned into an empty-string argv entry (which corrupts the
// command and produces a confusing "Failed to start process").
@(test)
test_read_string_array_rejects_non_string :: proc(t: ^testing.T) {
	L := luaL_newstate()
	luaL_openlibs(L)
	defer lua_close(L)

	// All-string sequence -> accepted, elements preserved in order.
	testing.expect(t, luaL_dostring(L, "return {'echo', 'hi'}") == 0, "lua build failed")
	good, ok1 := read_string_array(L, lua_gettop(L))
	testing.expect(t, ok1, "all-string array should be accepted")
	testing.expect(
		t,
		len(good) == 2 && good[0] == "echo" && good[1] == "hi",
		"elements should be preserved in order",
	)
	for s in good do delete(s)
	delete(good)
	lua_pop(L, 1)

	// A non-string (number) element -> rejected, nil result (no partial leak).
	testing.expect(t, luaL_dostring(L, "return {'echo', 5, 'hi'}") == 0, "lua build failed")
	bad, ok2 := read_string_array(L, lua_gettop(L))
	testing.expect(t, !ok2, "a non-string element must be rejected (#172)")
	testing.expect(t, bad == nil, "rejected result must be nil (freed)")
	lua_pop(L, 1)

	// #225 L3: an element with an embedded NUL would be truncated at the NUL
	// by execve (os.process_start builds a C argv). Reject it, don't truncate.
	testing.expect(t, luaL_dostring(L, "return {'echo', 'hello\\0world'}") == 0, "lua build failed")
	nul, ok3 := read_string_array(L, lua_gettop(L))
	testing.expect(t, !ok3, "an element with an embedded NUL must be rejected (#225 L3)")
	testing.expect(t, nul == nil, "rejected result must be nil (freed)")
	lua_pop(L, 1)

	// A bare NUL byte at the end is still an embedded NUL and must be rejected.
	testing.expect(t, luaL_dostring(L, "return {'ok', 'x\\0'}") == 0, "lua build failed")
	nul2, ok4 := read_string_array(L, lua_gettop(L))
	testing.expect(t, !ok4, "trailing NUL must be rejected")
	testing.expect(t, nul2 == nil, "rejected result must be nil (freed)")
	lua_pop(L, 1)
}

// #225 L4: deliver_shell_response echoed the app-controlled `id` back through
// clone_to_cstring + lua_pushstring, truncating it at the first NUL. A
// truncated id no longer matches the app's pending-shell slot, so the
// response callback silently never fires. The delivery must preserve the
// full id via lua_pushlstring (as it already does for stdout/stderr).
@(test)
test_deliver_shell_response_preserves_nul_id :: proc(t: ^testing.T) {
	L := luaL_newstate()
	luaL_openlibs(L)
	defer lua_close(L)

	b: Bridge
	b.L = L

	// Capture the delivered id's length into a Lua global.
	setup: cstring = `captured_id_len = -1
function redin_events(evs)
  local d = evs[1][2]
  captured_id_len = d.id and #d.id or -1
end`
	testing.expect(t, luaL_dostring(L, setup) == 0, "lua setup failed")

	resp: Shell_Response
	resp.id = "a\x00b" // 3 bytes, embedded NUL
	deliver_shell_response(&b, &resp)

	lua_getglobal(L, "captured_id_len")
	got := int(lua_tonumber(L, -1))
	lua_pop(L, 1)
	testing.expect_value(t, got, 3)
}

// #167: SIGPIPE's default disposition terminates the process. After
// ignore_sigpipe(), a self-directed SIGPIPE must be a no-op; without the
// fix this test binary would die (exit 141) instead of reaching the assert.
@(test)
test_sigpipe_ignored :: proc(t: ^testing.T) {
	ignore_sigpipe()
	linux.kill(linux.getpid(), .SIGPIPE)
	testing.expect(t, true, "process survived a self-directed SIGPIPE")
}

// #167: a large :stdin to a child that never drains it must not block past
// the timeout. The pre-fix blocking os.write ran before the read loop, so
// the timeout/output-cap checks could never fire and the worker hung for
// the child's entire lifetime.
@(test)
test_shell_large_stdin_respects_timeout :: proc(t: ^testing.T) {
	ignore_sigpipe() // the kill-on-timeout closes the child's stdin read end

	big := make([]u8, 256 * 1024) // > pipe buffer: can't be written in one go
	defer delete(big)
	for i in 0 ..< len(big) do big[i] = 'x'

	cmd := make([]string, 2)
	cmd[0] = strings.clone("/usr/bin/sleep")
	cmd[1] = strings.clone("10")
	req := Shell_Request {
		id         = strings.clone("stdin-timeout"),
		cmd        = cmd,
		stdin      = strings.clone(string(big)),
		timeout_ms = 500,
	}
	defer {
		delete(req.id)
		delete(req.stdin)
		for s in req.cmd do delete(s)
		delete(req.cmd)
	}

	t0 := time.now()
	resp := execute_shell(req)
	elapsed := time.diff(t0, time.now())
	shell_response_destroy(&resp)

	testing.expectf(
		t,
		elapsed < 3 * time.Second,
		"execute_shell blocked %v on a large stdin to a non-reading child; the 500ms timeout never fired (#167)",
		elapsed,
	)
}

@(private = "file")
Drain_Sim_Ctx :: struct {
	sc:       ^Shell_Client,
	delay_ms: int,
}

// Mimics shell_thread_proc's tail: respect `destroying`, then drop the
// worker count last — without doing real work.
@(private = "file")
shell_drain_sim_worker :: proc(raw: rawptr) {
	c := cast(^Drain_Sim_Ctx)raw
	time.sleep(time.Duration(c.delay_ms) * time.Millisecond)
	sync.lock(&c.sc.results_mutex)
	// (destroying is set by the time we wake; nothing to append in the sim)
	_ = sync.atomic_load(&c.sc.destroying)
	sync.unlock(&c.sc.results_mutex)
	sync.atomic_sub(&c.sc.workers_alive, 1)
}

// #166: shell_client_destroy must wait for in-flight workers to finish
// before freeing the client, or a late worker writes into freed memory.
@(test)
test_shell_destroy_waits_for_inflight_worker :: proc(t: ^testing.T) {
	sc: Shell_Client
	shell_client_init(&sc)

	sync.atomic_add(&sc.workers_alive, 1)
	ctx := Drain_Sim_Ctx {
		sc       = &sc,
		delay_ms = 40,
	}
	h := thread.create_and_start_with_data(&ctx, shell_drain_sim_worker)

	shell_client_destroy(&sc)

	testing.expect(
		t,
		sync.atomic_load(&sc.workers_alive) == 0,
		"shell_client_destroy returned with a worker still in flight (use-after-free risk) (#166)",
	)

	thread.join(h)
	thread.destroy(h)
}
