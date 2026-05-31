package bridge

// #162 M2: json_decode_array used a bare `idx: i32` with no upper bound.
// A JSON array of 2^31+ entries would overflow idx to negative, after
// which lua_rawseti(L, -2, idx) writes via the Lua C API with a negative
// key — undefined behaviour for the VM. MAX_BODY (1 MiB) makes this hard
// from the dev server, but a Lua-side json_decode of an attacker-supplied
// HTTP response body has no such bound. json_array_index_ok caps the
// count before the rawseti so the decoder rejects (returns false) rather
// than wrapping. json_decode_array itself is @(private="file"); the cap
// logic is factored into this pure, package-visible predicate so it can
// be unit-tested directly.

import "core:testing"

@(test)
test_json_array_index_ok_boundary :: proc(t: ^testing.T) {
	testing.expect(t, json_array_index_ok(1), "first index is fine")
	testing.expect(t, json_array_index_ok(MAX_JSON_ARRAY_LEN), "exactly the cap is allowed")
	testing.expect(t, !json_array_index_ok(MAX_JSON_ARRAY_LEN + 1), "one past the cap is rejected")
}

@(test)
test_max_json_array_len_constant :: proc(t: ^testing.T) {
	// Pin the cap: 1,000,000 — comfortably above any legitimate array a
	// 1 MiB body could hold, far below i32 max where the wrap happens.
	testing.expect_value(t, MAX_JSON_ARRAY_LEN, 1_000_000)
}
