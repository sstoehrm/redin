package bridge

import "core:sync"
import "core:testing"

// #277 L1: deliver_http_response pushed header keys/values through
// clone_to_cstring + lua_pushstring, which truncates at the first NUL —
// unlike the sibling id/body/error fields, already NUL-safe since #225 L4.
// A NUL-bearing header from a (compromised / MITM'd) upstream silently
// lost its tail on the app side: `Content-Type: application/json\0junk`
// dispatched the JSON handler, a NUL-split X-Signature verified on the
// prefix, a NUL-split Location passed an app-side redirect gate. Keys and
// values must round-trip byte-exact.

@(test)
test_deliver_http_response_headers_preserve_nul :: proc(t: ^testing.T) {
	sync.lock(&g_test_bridge_global_mutex)
	defer sync.unlock(&g_test_bridge_global_mutex)

	L := luaL_newstate()
	luaL_openlibs(L)
	defer lua_close(L)

	rc := luaL_dostring(L, `
		function redin_events(evs)
			captured = evs[1][2].headers
		end`)
	testing.expectf(t, rc == 0, "failed to define redin_events (rc=%d)", rc)

	b: Bridge
	b.L = L

	key := "X-Sig\x00extra"
	val := "prefix\x00suffix"
	resp: Http_Response
	resp.id = "1"
	resp.status = 200
	resp.headers = make(map[string]string)
	defer delete(resp.headers)
	resp.headers[key] = val

	deliver_http_response(&b, &resp)

	lua_getglobal(L, "captured")
	testing.expect(t, lua_istable(L, -1), "headers table must be delivered")
	lua_pushlstring(L, cstring(raw_data(transmute([]u8)key)), uint(len(key)))
	lua_rawget(L, -2)
	got := lua_tostring_str(L, -1)
	testing.expectf(t, got == val, "header value truncated: got %q", got)
	lua_pop(L, 2)
}
