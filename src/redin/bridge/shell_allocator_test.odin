package bridge

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

import "core:mem"
import "core:strings"
import "core:sync"
import "core:testing"
import "core:time"

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
