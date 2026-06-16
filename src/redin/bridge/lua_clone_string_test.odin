package bridge

import "core:strings"
import "core:testing"

// #217 L3/L4: Lua strings carry an explicit length and may contain embedded
// NUL bytes. The bridge read them with strings.clone_from_cstring(
// lua_tostring_raw(...)), which is strlen-based and truncates at the first
// NUL. That silently dropped shell-stdin payload past the NUL (L4) and
// defeated header_safe on the URL, which never saw the NUL it was meant to
// reject (L3). lua_clone_string must read the length-carrying value and keep
// the full byte range so the bytes after a NUL survive.
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
