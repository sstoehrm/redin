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

// #180 (re-flagged as #263 L3): each path step is a u8, so a container
// with more than 256 direct children wraps — child 256's step collides
// with child 0's, and path-keyed identity (text selection, /selection)
// can resolve to the wrong sibling. Widening the encoding was triaged in
// #180 as too regression-prone to do casually (it must change every path
// builder and comparer in lockstep); the agreed safe first step is a
// one-time diagnostic so an affected app says so instead of silently
// misbehaving.
@(test)
test_flatten_warns_once_on_path_step_overflow :: proc(t: ^testing.T) {
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

	g_path_step_overflow_warned = false
	defer g_path_step_overflow_warned = false

	// 300 direct children under one vbox — past the 256 wrap point.
	code: cstring = `local t = {"vbox", {}}
for i = 1, 300 do t[#t+1] = {"text", {}, "row"} end
return t`
	rc := luaL_dostring(L, code)
	testing.expectf(t, rc == 0, "failed to build wide table (rc=%d)", rc)

	cur: [dynamic]u8
	defer delete(cur)
	lua_flatten_node(L, lua_gettop(L), &cur, &b, -1)

	testing.expect_value(t, len(b.nodes), 301) // vbox + 300 texts
	testing.expect(t, g_path_step_overflow_warned,
		"flatten must warn when a container exceeds 256 direct children (#180 / #263 L3)")
}

@(test)
test_flatten_no_overflow_warning_under_wrap_point :: proc(t: ^testing.T) {
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

	g_path_step_overflow_warned = false

	// 256 children is the widest collision-free container (steps 0..255).
	code: cstring = `local t = {"vbox", {}}
for i = 1, 256 do t[#t+1] = {"text", {}, "row"} end
return t`
	rc := luaL_dostring(L, code)
	testing.expectf(t, rc == 0, "failed to build wide table (rc=%d)", rc)

	cur: [dynamic]u8
	defer delete(cur)
	lua_flatten_node(L, lua_gettop(L), &cur, &b, -1)

	testing.expect_value(t, len(b.nodes), 257)
	testing.expect(t, !g_path_step_overflow_warned,
		"256 direct children are collision-free and must not warn (#180 / #263 L3)")
}
