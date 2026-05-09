package bridge

// Tests for the JSON encoder primitives in json.odin.
// Issue #129 H2: json_string must escape U+0000-U+001F per RFC 8259 §7.
// Issue #129 H3: json_number must emit `null` for NaN / +Inf / -Inf.

import "core:math"
import "core:strings"
import "core:testing"

@(test)
test_json_string_existing_escapes :: proc(t: ^testing.T) {
	// Regression: the five pre-existing escapes still work.
	cases := [][2]string{
		{"\"",   `"\""`},
		{"\\",   `"\\"`},
		{"\n",   `"\n"`},
		{"\r",   `"\r"`},
		{"\t",   `"\t"`},
		{"hi",   `"hi"`},
		{"",     `""`},
	}
	for c in cases {
		b := strings.builder_make(context.temp_allocator)
		json_string(&b, c[0])
		testing.expect_value(t, strings.to_string(b), c[1])
	}
}

@(test)
test_json_string_control_bytes_escape :: proc(t: ^testing.T) {
	// Per RFC 8259 §7, all U+0000-U+001F must be escaped. Bytes not
	// covered by \n / \r / \t fall through to \u00XX (lower-case hex).
	cases := [][2]string{
		{"\x00", `"\u0000"`},
		{"\x01", `"\u0001"`},
		{"\x07", `"\u0007"`},
		{"\x08", `"\u0008"`},
		{"\x0b", `"\u000b"`},
		{"\x0c", `"\u000c"`},
		{"\x0e", `"\u000e"`},
		{"\x1f", `"\u001f"`},
	}
	for c in cases {
		b := strings.builder_make(context.temp_allocator)
		json_string(&b, c[0])
		testing.expect_value(t, strings.to_string(b), c[1])
	}
}

@(test)
test_json_string_high_bytes_pass_through :: proc(t: ^testing.T) {
	// 0x20 (space) and above are not escaped.
	b := strings.builder_make(context.temp_allocator)
	json_string(&b, " A~")
	testing.expect_value(t, strings.to_string(b), `" A~"`)
}
