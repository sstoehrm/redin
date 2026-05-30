package redin

// Defense-in-depth backstop for the layout / intrinsic-height recursion
// (#162 H1). The bridge flatten pass already caps view-tree depth at
// bridge.MAX_VIEW_DEPTH (#170), which bounds every render walk over the
// flat tree — so this backstop never trips on a legitimate tree. It
// exists only so a future change to the flatten cap (or a new path that
// builds the flat arrays) can't silently reintroduce the unbounded
// native-stack recursion H1 describes.

import "bridge"
import "core:testing"

@(test)
test_layout_depth_within_bound :: proc(t: ^testing.T) {
	testing.expect(t, !layout_depth_exceeded(0), "depth 0 is fine")
	testing.expect(t, !layout_depth_exceeded(LAYOUT_DEPTH_BACKSTOP), "exactly the backstop is allowed")
}

@(test)
test_layout_depth_past_bound :: proc(t: ^testing.T) {
	testing.expect(t, layout_depth_exceeded(LAYOUT_DEPTH_BACKSTOP + 1), "one past the backstop is refused")
}

@(test)
test_layout_backstop_exceeds_flatten_cap :: proc(t: ^testing.T) {
	// Keep the backstop strictly above the flatten cap so it never trips
	// on an already-bounded tree and only catches a regression that lets
	// a deeper flat tree through. #162 H1, #170.
	testing.expect(t, LAYOUT_DEPTH_BACKSTOP > bridge.MAX_VIEW_DEPTH, "backstop must exceed the flatten cap")
}
