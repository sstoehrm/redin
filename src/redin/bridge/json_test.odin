package bridge

import "core:math"
import "core:strings"
import "core:testing"

// Tests for the JSON encoder primitives in json.odin.
// Issue #129 H2: json_string must escape U+0000-U+001F per RFC 8259 §7.
// Issue #129 H3: json_number must emit `null` for NaN / +Inf / -Inf.

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

@(test)
test_json_number_finite :: proc(t: ^testing.T) {
	cases := []struct{ n: f64, expected: string }{
		{0.0,    "0"},
		{1.0,    "1"},
		{-1.5,   "-1.5"},
		{42.0,   "42"},
		{1e10,   "1e10"},
	}
	for c in cases {
		b := strings.builder_make(context.temp_allocator)
		json_number(&b, c.n)
		testing.expect_value(t, strings.to_string(b), c.expected)
	}
}

@(test)
test_json_number_non_finite_emits_null :: proc(t: ^testing.T) {
	non_finite := []f64{math.nan_f64(), math.inf_f64(1), math.inf_f64(-1)}
	for n in non_finite {
		b := strings.builder_make(context.temp_allocator)
		json_number(&b, n)
		testing.expect_value(t, strings.to_string(b), "null")
	}
}

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

// F2 (#204): the JSON encoder/decoder recurse per nesting level, pushing a
// few Lua slots each. MAX_JSON_DEPTH (128) keeps the worst case far under
// LuaJIT's 8000-slot default, but the recursion now calls lua_checkstack
// before descending so a future raised cap or a non-default-stack thread
// fails cleanly instead of overflowing the stack unchecked.
//
// The exhaustion path itself can't be provoked deterministically at depth
// 128, so these tests pin the two things that can regress: the binding is
// wired (checkstack reports headroom), and the guard leaves the happy path
// — a deep-but-valid payload — decoding correctly while the depth cap still
// rejects past the limit.

@(test)
test_lua_checkstack_binding_reports_headroom :: proc(t: ^testing.T) {
	L := luaL_newstate()
	luaL_openlibs(L)
	defer lua_close(L)

	// A fresh state has ample room; the guard's happy path must pass.
	testing.expect(t, lua_checkstack(L, 8) != 0, "checkstack(8) should succeed on a fresh state")
}

// Build `[`×n + `]`×n: an array nested n levels deep with an empty array
// at the bottom. The innermost array is decoded by json_decode_value_at at
// depth n-1, so n stays clear of the depth cap.
@(private = "file")
nested_arrays :: proc(n: int) -> string {
	b := strings.builder_make()
	for _ in 0 ..< n do strings.write_byte(&b, '[')
	for _ in 0 ..< n do strings.write_byte(&b, ']')
	return strings.to_string(b)
}

@(test)
test_decode_deep_within_cap_succeeds :: proc(t: ^testing.T) {
	L := luaL_newstate()
	luaL_openlibs(L)
	defer lua_close(L)

	// 100 levels: deep enough to exercise the per-level checkstack guard
	// many times, comfortably under MAX_JSON_DEPTH (128).
	s := nested_arrays(100)
	defer delete(s)
	pos := 0
	testing.expect(t, json_decode_value(L, s, &pos), "100-level nesting is within the cap and must decode")
}

@(test)
test_decode_over_cap_rejected :: proc(t: ^testing.T) {
	L := luaL_newstate()
	luaL_openlibs(L)
	defer lua_close(L)

	// 200 levels is well past MAX_JSON_DEPTH; the depth guard rejects it
	// before the stack guard would ever matter.
	s := nested_arrays(200)
	defer delete(s)
	pos := 0
	testing.expect(t, !json_decode_value(L, s, &pos), "200-level nesting exceeds the depth cap and must be rejected")
}

// #173: Lua strings carry an explicit length and may contain embedded NULs.
// The encoder read values via lua_tostring_raw (strlen-based), which
// truncates at the first NUL. It must use a length-carrying read so the full
// value is serialized (the NUL escaped, the bytes after it preserved).
@(test)
test_json_encode_preserves_embedded_nul :: proc(t: ^testing.T) {
	L := luaL_newstate()
	luaL_openlibs(L)
	defer lua_close(L)

	// "a" + NUL + "b" — 3 bytes.
	buf := [3]u8{'a', 0, 'b'}
	lua_pushlstring(L, cstring(raw_data(buf[:])), 3)

	b := strings.builder_make()
	defer strings.builder_destroy(&b)
	lua_value_to_json(&b, L, lua_gettop(L))

	out := strings.to_string(b)
	// Truncating at the NUL yields `"a"`; the correct output escapes the NUL
	// (json_string emits a 4-hex-digit \u escape) and keeps the trailing 'b'.
	testing.expectf(t, strings.contains(out, "b"),
		"byte after embedded NUL was dropped; got %q (#173)", out)
	testing.expectf(t, strings.contains(out, "0000"),
		"embedded NUL should be escaped, not dropped; got %q (#173)", out)
}
