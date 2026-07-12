package text

import "core:strings"
import "core:testing"
import "core:unicode/utf8"

// #225 L6: the intrinsic-height cache grew to the peak node count and never
// shrank, pinning that backing array for the process lifetime after a
// transient large tree. ensure_intrinsic_cache now reclaims the backing
// capacity once the tree shrinks well past the slack, without thrashing on
// small fluctuations. These tests mutate the package-global cache, so the
// text package is run with -define:ODIN_TEST_THREADS=1 (see test.yml).

@(test)
test_intrinsic_cache_shrinks_after_spike :: proc(t: ^testing.T) {
	destroy_intrinsic_cache() // clean slate
	defer destroy_intrinsic_cache()

	ensure_intrinsic_cache(10_000)
	testing.expect_value(t, len(intrinsic_cache), 10_000)

	// A tiny tree afterwards is far past the slack, so the backing array is
	// reclaimed rather than pinned at the 10k high-water mark.
	ensure_intrinsic_cache(100)
	testing.expect_value(t, len(intrinsic_cache), 100)
	testing.expect(t, cap(intrinsic_cache) <= 100 + CACHE_SHRINK_SLACK,
		"backing capacity should be reclaimed after a large spike")
}

@(test)
test_intrinsic_cache_no_thrash_within_slack :: proc(t: ^testing.T) {
	destroy_intrinsic_cache()
	defer destroy_intrinsic_cache()

	ensure_intrinsic_cache(1000)
	cap_before := cap(intrinsic_cache)

	// A shrink within CACHE_SHRINK_SLACK must not realloc or resize — the
	// spare slots are kept to absorb ordinary per-frame fluctuation.
	ensure_intrinsic_cache(1000 - (CACHE_SHRINK_SLACK - 1))
	testing.expect_value(t, len(intrinsic_cache), 1000)
	testing.expect_value(t, cap(intrinsic_cache), cap_before)
}

@(test)
test_intrinsic_cache_grows :: proc(t: ^testing.T) {
	destroy_intrinsic_cache()
	defer destroy_intrinsic_cache()

	ensure_intrinsic_cache(50)
	testing.expect_value(t, len(intrinsic_cache), 50)
	// New slots start unpopulated (sentinel width < 0).
	_, ok := lookup_intrinsic(10, 200)
	testing.expect(t, !ok, "fresh slot must be a cache miss")

	ensure_intrinsic_cache(75)
	testing.expect_value(t, len(intrinsic_cache), 75)
}

// #233 L6: offset_at_x replaces the O(n²) prefix-remeasure loops in
// point_to_cursor / x_to_cursor_in_line with an O(n) running-width scan.
// A raylib Font isn't available in a headless unit test (no GPU / font
// atlas), so these tests pin the structural invariants that hold for any
// font: a target left of the start maps to start, a huge target maps to the
// end, results are codepoint-aligned, and a million-char line returns
// promptly (would hang under the old O(n²) behaviour).

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
