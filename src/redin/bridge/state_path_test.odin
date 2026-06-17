package bridge

// #217 L6: /state/<path> caps the number of dot-separated segments (32) but
// never bounded the length of any single segment. It is safe in practice today
// — the request path is already bounded by the header buffer — but the cap is
// cheap defence-in-depth. any_segment_too_long is the pure predicate behind it.

import "core:strings"
import "core:testing"

@(test)
test_any_segment_too_long_flags_overlong :: proc(t: ^testing.T) {
	long := strings.repeat("a", MAX_PATH_SEGMENT_LEN + 1, context.temp_allocator)
	segments := []string{"form", long, "name"}
	testing.expect(t, any_segment_too_long(segments),
		"a segment past MAX_PATH_SEGMENT_LEN must be flagged")
}

@(test)
test_any_segment_too_long_allows_normal :: proc(t: ^testing.T) {
	at_cap := strings.repeat("b", MAX_PATH_SEGMENT_LEN, context.temp_allocator)
	segments := []string{"form", "name", at_cap}
	testing.expect(t, !any_segment_too_long(segments),
		"segments at or under the cap must pass")
}

@(test)
test_any_segment_too_long_empty :: proc(t: ^testing.T) {
	testing.expect(t, !any_segment_too_long([]string{}), "no segments => nothing too long")
	testing.expect(t, !any_segment_too_long([]string{""}), "empty segment is not too long")
}
