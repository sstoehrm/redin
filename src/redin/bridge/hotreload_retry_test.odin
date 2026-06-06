package bridge

// F5 (#204): a hot reload triggered by a non-atomic editor save can land on
// a half-written file and fail. The watcher arms one short retry so the
// editor's finished write is picked up automatically. The timing rule and
// the arm-at-most-once rule are factored into pure predicates so they can be
// checked without a real clock, Lua state, or filesystem.

import "core:testing"

@(test)
test_hotreload_retry_due_timing :: proc(t: ^testing.T) {
	// Not armed: never due, regardless of elapsed time.
	testing.expect(t, !hotreload_retry_due(false, 0), "disarmed never fires")
	testing.expect(t, !hotreload_retry_due(false, 1000), "disarmed never fires even much later")

	// Armed but before the deadline: not yet.
	testing.expect(t, !hotreload_retry_due(true, 0), "armed but no time passed")
	testing.expect(t, !hotreload_retry_due(true, HOTRELOAD_RETRY_MS - 1), "armed but just under the deadline")

	// Armed and at/after the deadline: due.
	testing.expect(t, hotreload_retry_due(true, HOTRELOAD_RETRY_MS), "exactly at the deadline fires")
	testing.expect(t, hotreload_retry_due(true, HOTRELOAD_RETRY_MS + 5), "past the deadline fires")
}

@(test)
test_hotreload_should_arm_retry :: proc(t: ^testing.T) {
	// Only a fresh mtime change that failed arms a retry.
	testing.expect(t, hotreload_should_arm_retry(.Changed, false), "failed fresh change arms a retry")

	// Everything else leaves it disarmed — crucially, a failed *retry* does
	// not arm another, bounding a broken file to two attempts.
	testing.expect(t, !hotreload_should_arm_retry(.Changed, true), "successful change does not arm")
	testing.expect(t, !hotreload_should_arm_retry(.Retry, false), "failed retry does not re-arm (no loop)")
	testing.expect(t, !hotreload_should_arm_retry(.Retry, true), "successful retry does not arm")
	testing.expect(t, !hotreload_should_arm_retry(.None, false), "no trigger never arms")
	testing.expect(t, !hotreload_should_arm_retry(.None, true), "no trigger never arms")
}
