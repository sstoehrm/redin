package bridge

import "core:strings"
import "core:sync"
import "core:sys/linux"
import "core:testing"
import "core:thread"
import "core:time"

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
