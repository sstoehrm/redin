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
