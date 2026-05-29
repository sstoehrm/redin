package input

import "core:testing"

// #179: a byte offset that lands inside a multibyte UTF-8 sequence must snap
// back to the codepoint start, so a later insert/delete can't split it.
@(test)
test_clamp_to_codepoint_start :: proc(t: ^testing.T) {
	// "aé" = 0x61 0xC3 0xA9 (the 'é' is a 2-byte sequence).
	text := []u8{0x61, 0xC3, 0xA9}
	testing.expect_value(t, clamp_to_codepoint_start(text, 2), 1) // continuation byte -> snap to 'é' start
	testing.expect_value(t, clamp_to_codepoint_start(text, 1), 1) // already a boundary (lead byte)
	testing.expect_value(t, clamp_to_codepoint_start(text, 0), 0)
	testing.expect_value(t, clamp_to_codepoint_start(text, 3), 3) // end is a boundary
	testing.expect_value(t, clamp_to_codepoint_start(text, 9), 3) // past end -> clamp to len
}
