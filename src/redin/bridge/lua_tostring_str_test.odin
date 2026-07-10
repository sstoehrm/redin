package bridge

import "core:testing"

// #225 L2: ten dev-server handlers read Lua strings via
// `string(lua_tostring_raw(...))`, which is strlen-based and truncates at the
// first NUL — so an agent-edit value or a mouse-button / key name containing a
// NUL round-tripped or matched incorrectly. They now use lua_tostring_str,
// which reads the length-carrying value. These tests pin that helper against a
// string with an embedded NUL and confirm the old read really did truncate.

@(test)
test_lua_tostring_str_preserves_embedded_nul :: proc(t: ^testing.T) {
	L := luaL_newstate()
	luaL_openlibs(L)
	defer lua_close(L)

	// "ab" + NUL + "cd" — 5 bytes. strlen stops at index 2, yielding "ab".
	buf := [5]u8{'a', 'b', 0, 'c', 'd'}
	lua_pushlstring(L, cstring(raw_data(buf[:])), 5)
	idx := lua_gettop(L)

	got := lua_tostring_str(L, idx)
	testing.expect_value(t, len(got), 5)
	testing.expect(t, got == "ab\x00cd", "full byte range must survive the NUL")

	// The old strlen-based read truncates at the NUL — this is the bug the
	// helper fixes, asserted so the two paths can't silently converge.
	truncated := string(lua_tostring_raw(L, idx))
	testing.expect_value(t, len(truncated), 2)
	testing.expect(t, truncated == "ab", "strlen-based read stops at the NUL")
}

@(test)
test_lua_tostring_str_plain :: proc(t: ^testing.T) {
	L := luaL_newstate()
	luaL_openlibs(L)
	defer lua_close(L)

	lua_pushlstring(L, "hello", 5)
	got := lua_tostring_str(L, lua_gettop(L))
	testing.expect(t, got == "hello", "plain string reads unchanged")
}

@(test)
test_lua_tostring_str_empty :: proc(t: ^testing.T) {
	L := luaL_newstate()
	luaL_openlibs(L)
	defer lua_close(L)

	lua_pushlstring(L, "", 0)
	got := lua_tostring_str(L, lua_gettop(L))
	testing.expect_value(t, len(got), 0)
}
