package bridge

// #216: http workers are spawned with init_context set (http_client.odin), so
// core:thread's teardown skips _maybe_destroy_default_temp_allocator — it
// leaves custom-context cleanup to the thread proc. _select_context_for_thread
// still hands the worker its OWN thread-local default temp arena, and the
// worker path allocates from it (scheme lowercasing + the whitelist host
// compare), so without an explicit destroy each request leaks one arena. The
// leak is invisible to REDIN_TRACK_MEM (the arena bypasses context.allocator),
// so this test observes the runtime arena state directly: a live block exists
// after a temp alloc, and must be gone after the worker's cleanup runs.

import "base:runtime"
import "core:strings"
import "core:sync"
import "core:testing"
import "core:thread"

@(private = "file")
Arena_Probe :: struct {
	block_after_alloc:   bool,
	block_after_cleanup: bool,
}

@(private = "file")
arena_probe_proc :: proc(raw: rawptr) {
	p := cast(^Arena_Probe)raw

	// Allocate from the thread-local default temp arena, exactly like
	// execute_http_request's strings.to_lower(..., context.temp_allocator).
	_ = strings.to_lower("ABC", context.temp_allocator)
	p.block_after_alloc = runtime.global_default_temp_allocator_data.arena.curr_block != nil

	// The fix under test: free this thread's temp arena before it exits.
	destroy_thread_temp_arena()
	p.block_after_cleanup = runtime.global_default_temp_allocator_data.arena.curr_block != nil
}

@(test)
test_http_worker_frees_thread_temp_arena :: proc(t: ^testing.T) {
	probe := new(Arena_Probe)
	defer free(probe)

	// Mirror http_client_request: spawn with init_context set (the condition
	// that makes the runtime skip its own temp-arena cleanup).
	worker_ctx := context
	th := thread.create_and_start_with_data(probe, arena_probe_proc,
		init_context = worker_ctx, self_cleanup = false)
	thread.join(th)
	thread.destroy(th)

	testing.expect(t, probe.block_after_alloc,
		"a temp alloc must initialize the thread-local arena (test precondition)")
	testing.expect(t, !probe.block_after_cleanup,
		"#216: the worker must free its thread-local temp arena before exit")
}
