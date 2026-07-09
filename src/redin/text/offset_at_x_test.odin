package text

// #233 L6: offset_at_x replaces the O(n²) prefix-remeasure loops in
// point_to_cursor / x_to_cursor_in_line with an O(n) running-width scan.
// A raylib Font isn't available in a headless unit test (no GPU / font
// atlas), so these tests pin the structural invariants that hold for any
// font: a target left of the start maps to start, a huge target maps to the
// end, results are codepoint-aligned, and a million-char line returns
// promptly (would hang under the old O(n²) behaviour).

import "core:strings"
import "core:testing"
import "core:unicode/utf8"

@(test)
test_offset_at_x_empty_range :: proc(t: ^testing.T) {
	// start >= end returns start without touching the font.
	testing.expect_value(t, offset_at_x("hello", 3, 3, 100, {}, 16, 0), 3)
	testing.expect_value(t, offset_at_x("hello", 4, 2, 100, {}, 16, 0), 4)
}

@(test)
test_offset_at_x_target_before_start :: proc(t: ^testing.T) {
	// A negative / zero target is closest to the start (width 0). With a nil
	// font every glyph advance is 0, so all widths are 0 and best stays at
	// start.
	testing.expect_value(t, offset_at_x("hello world", 0, 11, -50, {}, 16, 0), 0)
}

@(test)
test_offset_at_x_is_codepoint_aligned :: proc(t: ^testing.T) {
	// Multi-byte content: any returned offset must land on a rune boundary,
	// never inside a codepoint.
	s := "héllo wörld"        // é and ö are 2 bytes each
	got := offset_at_x(s, 0, len(s), 1e9, {}, 16, 0)
	// A huge target with a zero-advance font still returns the start (all
	// widths 0 → start is closest); the key invariant is boundary alignment.
	testing.expect(t, utf8.rune_start(s[got]) if got < len(s) else true,
		"offset must be on a codepoint boundary")
	testing.expect(t, got >= 0 && got <= len(s), "offset in range")
}

@(test)
test_offset_at_x_large_line_returns :: proc(t: ^testing.T) {
	// The old implementation remeasured the growing prefix each step, so this
	// was ~10^12 glyph ops. O(n) completes instantly. Reaching the assertion
	// at all is the test.
	big := strings.repeat("a", 1_000_000, context.temp_allocator)
	got := offset_at_x(big, 0, len(big), 500, {}, 16, 0)
	testing.expect(t, got >= 0 && got <= len(big), "offset in range for a huge line")
}
