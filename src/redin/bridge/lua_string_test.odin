package bridge

import "core:testing"

// NUL-safe Lua string reads. Lua strings carry an explicit length and may
// contain embedded NUL bytes; the strlen-based reads the bridge used to use
// truncated at the first NUL. Two length-carrying helpers replaced them:
//
//   lua_clone_string  (#217 L3/L4) — owning copy; dropped shell-stdin past a
//                     NUL (L4) and defeated header_safe on the URL (L3).
//   lua_tostring_str  (#225 L2)    — borrowed view used by ten dev-server
//                     handlers (agent-edit values, mouse-button / key names).
//
// Each helper is pinned against a string with an embedded NUL, and the old
// strlen-based read is asserted to still truncate so the two paths can't
// silently converge.

@(test)
test_lua_clone_string_preserves_embedded_nul :: proc(t: ^testing.T) {
	L := luaL_newstate()
	luaL_openlibs(L)
	defer lua_close(L)

	// "a" + NUL + "b" — 3 bytes. strlen would stop at index 1, yielding "a".
	buf := [3]u8{'a', 0, 'b'}
	lua_pushlstring(L, cstring(raw_data(buf[:])), 3)

	got := lua_clone_string(L, lua_gettop(L))
	defer delete(got)

	testing.expect_value(t, len(got), 3)
	testing.expect(t, got == "a\x00b",
		"byte range after embedded NUL must survive the clone (#217 L3/L4)")
}

// An ordinary NUL-free string must clone identically — the length-carrying
// read is a strict superset of the old behaviour, not a change for the common
// case.
@(test)
test_lua_clone_string_plain :: proc(t: ^testing.T) {
	L := luaL_newstate()
	luaL_openlibs(L)
	defer lua_close(L)

	lua_pushlstring(L, "hello", 5)
	got := lua_clone_string(L, lua_gettop(L))
	defer delete(got)

	testing.expect(t, got == "hello", "plain string clones unchanged")
}

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
