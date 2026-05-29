package bridge

import "core:strings"
import "core:sync"
import "core:testing"
import "../types"

// Shared by tests that mutate the package-global g_bridge (clear_node_strings
// and clear_frame unref via g_bridge.L). Odin's test runner runs tests in
// parallel, so any test touching g_bridge must serialize on this. Mirrors
// g_test_http_state_mutex in http_client_test.odin.
g_test_bridge_global_mutex: sync.Mutex

// Regression for #165: a NodeButton whose :click carries a context payload
// (the documented `:click [:event ctx]` form) takes a Lua registry ref via
// luaL_ref in lua_get_event_ctx. clear_node_strings rebuilds every frame, so
// if it fails to luaL_unref click_ctx the registry grows without bound.
//
// We detect the leak via Lua 5.1 / LuaJIT's ref freelist: luaL_unref pushes
// the slot onto the freelist and the next luaL_ref hands it straight back.
// So a freed slot is reused; a leaked slot is not.
@(test)
test_clear_node_unrefs_button_click_ctx :: proc(t: ^testing.T) {
	sync.lock(&g_test_bridge_global_mutex)
	defer sync.unlock(&g_test_bridge_global_mutex)

	L := luaL_newstate()
	luaL_openlibs(L)
	defer lua_close(L)

	// clear_node_strings unrefs against g_bridge.L (mirrors
	// clear_dropable_attrs); point the global at our throwaway state.
	b := Bridge{L = L}
	saved := g_bridge
	g_bridge = &b
	defer g_bridge = saved

	lua_pushboolean(L, 1)
	ref := luaL_ref(L, LUA_REGISTRYINDEX)
	testing.expect(t, ref > 0, "expected a valid registry ref")

	btn := types.NodeButton{click = strings.clone("event/click"), click_ctx = ref}
	node: types.Node = btn
	clear_node_strings(node)

	lua_pushboolean(L, 1)
	ref2 := luaL_ref(L, LUA_REGISTRYINDEX)
	luaL_unref(L, LUA_REGISTRYINDEX, ref2)
	testing.expectf(
		t,
		ref2 == ref,
		"click_ctx ref %d was not freed by clear_node_strings (next ref was %d) -> registry leak",
		ref,
		ref2,
	)
}
