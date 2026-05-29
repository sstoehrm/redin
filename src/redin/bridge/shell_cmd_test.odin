package bridge

import "core:testing"

// #172: a non-string element in the :cmd table must be rejected, not
// silently turned into an empty-string argv entry (which corrupts the
// command and produces a confusing "Failed to start process").
@(test)
test_read_string_array_rejects_non_string :: proc(t: ^testing.T) {
	L := luaL_newstate()
	luaL_openlibs(L)
	defer lua_close(L)

	// All-string sequence -> accepted, elements preserved in order.
	testing.expect(t, luaL_dostring(L, "return {'echo', 'hi'}") == 0, "lua build failed")
	good, ok1 := read_string_array(L, lua_gettop(L))
	testing.expect(t, ok1, "all-string array should be accepted")
	testing.expect(
		t,
		len(good) == 2 && good[0] == "echo" && good[1] == "hi",
		"elements should be preserved in order",
	)
	for s in good do delete(s)
	delete(good)
	lua_pop(L, 1)

	// A non-string (number) element -> rejected, nil result (no partial leak).
	testing.expect(t, luaL_dostring(L, "return {'echo', 5, 'hi'}") == 0, "lua build failed")
	bad, ok2 := read_string_array(L, lua_gettop(L))
	testing.expect(t, !ok2, "a non-string element must be rejected (#172)")
	testing.expect(t, bad == nil, "rejected result must be nil (freed)")
	lua_pop(L, 1)
}
