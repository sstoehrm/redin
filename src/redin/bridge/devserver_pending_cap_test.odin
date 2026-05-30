package bridge

// Tests for the acceptor's pending-connection bound (#162 H2). The
// acceptor previously pushed every accepted socket onto accepted_conns
// with no upper bound, so a client opening connections faster than the
// 16-handler pool drains them grows the queue (and the held fds)
// without limit — a memory / fd-exhaustion DoS. conn_try_push refuses
// to enqueue past MAX_PENDING_CONNS so the acceptor can close the
// straggler instead.

import "core:container/queue"
import "core:testing"

@(test)
test_conn_try_push_enforces_cap :: proc(t: ^testing.T) {
	cq: Conn_Queue
	queue.init(&cq.q)
	defer queue.destroy(&cq.q)

	CAP :: 4
	conns: [CAP]^Pending_Conn
	for i in 0 ..< CAP {
		conns[i] = new(Pending_Conn)
		ok := conn_try_push(&cq, conns[i], CAP)
		testing.expectf(t, ok, "push %d within cap should succeed", i)
	}

	// Queue is now full. The next push must be refused without growing
	// the queue, so the caller knows to close the socket itself.
	overflow := new(Pending_Conn)
	defer free(overflow)
	ok := conn_try_push(&cq, overflow, CAP)
	testing.expect(t, !ok, "push beyond cap must be rejected")
	testing.expect_value(t, queue.len(cq.q), CAP)

	// Drain + free the accepted entries.
	for _ in 0 ..< CAP {
		got := conn_pop_blocking(&cq)
		free(got)
	}
}

@(test)
test_conn_try_push_nil_sentinel_bypasses_cap :: proc(t: ^testing.T) {
	// The shutdown sentinel (nil) must always enqueue regardless of the
	// cap — handlers can only observe the stop signal if it reaches the
	// queue. A full queue at shutdown must not swallow the sentinel.
	cq: Conn_Queue
	queue.init(&cq.q)
	defer queue.destroy(&cq.q)

	pc := new(Pending_Conn)
	ok := conn_try_push(&cq, pc, 1)
	testing.expect(t, ok, "first push fills the cap")

	// Even though the queue is at cap, a nil sentinel still goes in.
	ok2 := conn_try_push(&cq, nil, 1)
	testing.expect(t, ok2, "nil sentinel must bypass the cap")
	testing.expect_value(t, queue.len(cq.q), 2)

	got1 := conn_pop_blocking(&cq)
	testing.expect(t, got1 == pc, "first pop is the real conn")
	free(got1)
	got2 := conn_pop_blocking(&cq)
	testing.expect(t, got2 == nil, "second pop is the sentinel")
}

@(test)
test_max_pending_conns_constant :: proc(t: ^testing.T) {
	// Pool bound is part of the contract; pin it so an accidental tweak
	// trips this test. Sized well above HANDLER_POOL_SIZE (16) so normal
	// bursts queue fine, but low enough to cap a flood. #162 H2.
	testing.expect_value(t, MAX_PENDING_CONNS, 256)
}
