package bridge

import "core:sync"
import "core:testing"

// Regression for #170: lua_flatten_node (and the render passes that walk its
// output) recurse once per nesting level with no native-stack guard. A deeply
// self-nesting view tree would overflow the C stack and SIGSEGV uncatchably.
// flatten must cap the depth so the flat tree — and thus every render pass —
// is bounded.
@(test)
test_flatten_caps_deep_nesting :: proc(t: ^testing.T) {
	sync.lock(&g_test_bridge_global_mutex)
	defer sync.unlock(&g_test_bridge_global_mutex)

	L := luaL_newstate()
	luaL_openlibs(L)
	defer lua_close(L)

	b: Bridge
	b.L = L
	saved := g_bridge
	g_bridge = &b
	defer g_bridge = saved
	defer clear_frame(&b)

	// Build a 1000-deep nested vbox on the Lua stack. 1000 > MAX_VIEW_DEPTH
	// (256) but shallow enough that the unfixed full recursion fails the
	// assertion cleanly rather than overflowing the test thread's stack.
	code: cstring = `local t = {"vbox", {}}
for i = 1, 1000 do t = {"vbox", {}, t} end
return t`
	rc := luaL_dostring(L, code)
	testing.expectf(t, rc == 0, "failed to build nested table (rc=%d)", rc)

	cur: [dynamic]u8
	defer delete(cur)
	lua_flatten_node(L, lua_gettop(L), &cur, &b, -1)

	testing.expect(t, len(b.nodes) > 0, "expected nodes to be emitted")

	max_depth := 0
	for p in b.paths {
		if int(p.length) > max_depth do max_depth = int(p.length)
	}
	testing.expectf(
		t,
		max_depth <= MAX_VIEW_DEPTH,
		"view-tree depth %d exceeded cap %d -> unbounded native recursion risk (#170)",
		max_depth,
		MAX_VIEW_DEPTH,
	)
}
