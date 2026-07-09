package text

// #225 L6: the intrinsic-height cache grew to the peak node count and never
// shrank, pinning that backing array for the process lifetime after a
// transient large tree. ensure_intrinsic_cache now reclaims the backing
// capacity once the tree shrinks well past the slack, without thrashing on
// small fluctuations. These tests mutate the package-global cache, so the
// text package is run with -define:ODIN_TEST_THREADS=1 (see test.yml).

import "core:testing"

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
