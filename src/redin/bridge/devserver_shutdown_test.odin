package bridge

import "core:container/queue"
import "core:sync"
import "core:testing"
import "core:thread"

// Mirrors the relevant half of handle_one_connection: enqueue a request,
// park on channel.done, and once woken post ack (without touching the
// channel afterward, since the drainer owns and frees it then).
@(private = "file")
Drain_Test_Ctx :: struct {
	ch:   ^Response_Channel,
	woke: bool,
}

@(private = "file")
drain_test_parked_handler :: proc(raw: rawptr) {
	c := cast(^Drain_Test_Ctx)raw
	sync.sema_wait(&c.ch.done)
	c.woke = true
	sync.sema_post(&c.ch.ack)
}

// Regression for #168: a handler that enqueued a request and parked on
// channel.done is only woken by the main render loop, which has exited at
// shutdown. drain_incoming_503 must wake every parked handler (post done +
// observe ack) so devserver_destroy's thread.join doesn't deadlock.
@(test)
test_devserver_drain_incoming_wakes_parked_handler :: proc(t: ^testing.T) {
	ds: Dev_Server
	queue.init(&ds.incoming.q)
	defer queue.destroy(&ds.incoming.q)

	ctx := Drain_Test_Ctx {
		ch = new(Response_Channel),
	}
	pending := new(Pending_Request)
	pending.method = "GET"
	pending.path = "/state"
	pending.response = ctx.ch
	sync_queue_push(&ds.incoming, pending)

	h := thread.create_and_start_with_data(&ctx, drain_test_parked_handler)

	// Blocks inside respond_* until the handler posts ack; on return the
	// channel + pending have been freed and the handler has exited.
	drain_incoming_503(&ds)

	testing.expect(t, ctx.woke, "drain_incoming_503 must wake the parked handler (#168)")
	testing.expect(t, queue.len(ds.incoming.q) == 0, "incoming queue must be empty after drain")

	if ctx.woke {
		thread.join(h)
		thread.destroy(h)
	}
}
