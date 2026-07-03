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

	// #225 L3: an element with an embedded NUL would be truncated at the NUL
	// by execve (os.process_start builds a C argv). Reject it, don't truncate.
	testing.expect(t, luaL_dostring(L, "return {'echo', 'hello\\0world'}") == 0, "lua build failed")
	nul, ok3 := read_string_array(L, lua_gettop(L))
	testing.expect(t, !ok3, "an element with an embedded NUL must be rejected (#225 L3)")
	testing.expect(t, nul == nil, "rejected result must be nil (freed)")
	lua_pop(L, 1)

	// A bare NUL byte at the end is still an embedded NUL and must be rejected.
	testing.expect(t, luaL_dostring(L, "return {'ok', 'x\\0'}") == 0, "lua build failed")
	nul2, ok4 := read_string_array(L, lua_gettop(L))
	testing.expect(t, !ok4, "trailing NUL must be rejected")
	testing.expect(t, nul2 == nil, "rejected result must be nil (freed)")
	lua_pop(L, 1)
}

// #225 L4: deliver_shell_response echoed the app-controlled `id` back through
// clone_to_cstring + lua_pushstring, truncating it at the first NUL. A
// truncated id no longer matches the app's pending-shell slot, so the
// response callback silently never fires. The delivery must preserve the
// full id via lua_pushlstring (as it already does for stdout/stderr).
@(test)
test_deliver_shell_response_preserves_nul_id :: proc(t: ^testing.T) {
	L := luaL_newstate()
	luaL_openlibs(L)
	defer lua_close(L)

	b: Bridge
	b.L = L

	// Capture the delivered id's length into a Lua global.
	setup: cstring = `captured_id_len = -1
function redin_events(evs)
  local d = evs[1][2]
  captured_id_len = d.id and #d.id or -1
end`
	testing.expect(t, luaL_dostring(L, setup) == 0, "lua setup failed")

	resp: Shell_Response
	resp.id = "a\x00b" // 3 bytes, embedded NUL
	deliver_shell_response(&b, &resp)

	lua_getglobal(L, "captured_id_len")
	got := int(lua_tonumber(L, -1))
	lua_pop(L, 1)
	testing.expect_value(t, got, 3)
}
