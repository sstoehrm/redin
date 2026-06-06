package bridge

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

import "core:strings"
import "core:testing"

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
