package bridge

import "core:strings"
import "core:testing"

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
