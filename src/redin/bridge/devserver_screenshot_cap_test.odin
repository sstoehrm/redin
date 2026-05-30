package bridge

// Tests for the /screenshot pixel cap (#162 H3). handle_screenshot
// allocates an RGBA frame buffer plus a PNG-encoded copy via raylib. At
// the maximum window size /resize allows (8192x8192) that is ~256 MB of
// transient allocation per request — an authenticated caller can drive
// the window large then hammer /screenshot to OOM the host. The cap
// rejects captures whose pixel count exceeds MAX_SCREENSHOT_PIXELS
// before any allocation happens.

import "core:testing"

@(test)
test_screenshot_dims_ok_accepts_normal :: proc(t: ^testing.T) {
	testing.expect(t, screenshot_dims_ok(1920, 1080), "1080p is well under the cap")
	testing.expect(t, screenshot_dims_ok(1, 1), "a 1x1 capture is fine")
}

@(test)
test_screenshot_dims_ok_rejects_oversize :: proc(t: ^testing.T) {
	// 8192x8192 = 67 MP, far past the 16 MP cap.
	testing.expect(t, !screenshot_dims_ok(8192, 8192), "max-window capture must be rejected")
}

@(test)
test_screenshot_dims_ok_boundary :: proc(t: ^testing.T) {
	// Exactly at the cap is allowed; one pixel over is not.
	testing.expect(t, screenshot_dims_ok(MAX_SCREENSHOT_PIXELS, 1), "exactly the cap is allowed")
	testing.expect(t, !screenshot_dims_ok(MAX_SCREENSHOT_PIXELS + 1, 1), "one over the cap is rejected")
}

@(test)
test_screenshot_dims_ok_rejects_nonpositive :: proc(t: ^testing.T) {
	// A degenerate window (minimized / zero-area) has nothing to capture
	// and must not reach the allocator with a zero or negative extent.
	testing.expect(t, !screenshot_dims_ok(0, 1080), "zero width is rejected")
	testing.expect(t, !screenshot_dims_ok(1920, 0), "zero height is rejected")
	testing.expect(t, !screenshot_dims_ok(-1, -1), "negative dims are rejected")
}

@(test)
test_max_screenshot_pixels_constant :: proc(t: ^testing.T) {
	// 16 MP — comfortably above any real display, well below the
	// 8192x8192 (67 MP) ceiling /resize permits. #162 H3.
	testing.expect_value(t, MAX_SCREENSHOT_PIXELS, 16 * 1024 * 1024)
}

@(test)
test_status_text_has_413 :: proc(t: ^testing.T) {
	// handle_screenshot replies 413 when the capture is too large; the
	// status line must say 413, not fall through to the "200 OK" default.
	// #162 H3.
	testing.expect_value(t, status_text(413), "413 Payload Too Large")
}
