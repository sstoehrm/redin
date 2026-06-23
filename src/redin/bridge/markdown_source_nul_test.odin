package bridge

import "core:sync"
import "core:testing"

import "../types"

// #221 M1: the markdown branch of lua_flatten_node read its `source` (the
// verbatim text behind a `[:markdown {...} "source"]` node) with
// `string(lua_tostring_raw(...))`, a strlen-based read that truncates at the
// first NUL. The truncated source then flows into markdown.lower's
// copy_text — the #112 Copy button's "copy verbatim source" payload — so a
// source carrying an embedded NUL (e.g. markdown built from redin.shell
// stdout) silently lost every byte after the NUL, both on screen and on the
// clipboard. The fix routes the read through lua_clone_string, which is
// length-carrying (lua_tolstring), the same NUL-safe pattern #217 standardised
// across the other 23 sites.
@(test)
test_markdown_source_preserves_embedded_nul :: proc(t: ^testing.T) {
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
	// clear_frame only clear()s markdown_skips (keeps backing for reuse); free
	// it too so the test's leak tracker stays clean. LIFO: clear_frame runs
	// first, then delete frees the now-empty map.
	defer delete(b.markdown_skips)
	defer clear_frame(&b)

	// {"markdown", {copyable = true}, "foo\0bar"} — string.char keeps the
	// embedded NUL unambiguous. strlen would stop at "foo" (3 bytes).
	code: cstring = `return {"markdown", {copyable = true},
		string.char(102, 111, 111, 0, 98, 97, 114)}`
	rc := luaL_dostring(L, code)
	testing.expectf(t, rc == 0, "failed to build markdown table (rc=%d)", rc)

	cur: [dynamic]u8
	defer delete(cur)
	lua_flatten_node(L, lua_gettop(L), &cur, &b, -1)

	// The copyable wrapper lowers to a copy-bar > copy-button whose copy_text
	// is the verbatim source. Find it and assert the full byte range survived.
	found := false
	for node in b.nodes {
		btn, ok := node.(types.NodeButton)
		if !ok || len(btn.copy_text) == 0 do continue
		found = true
		testing.expect_value(t, len(btn.copy_text), 7)
		testing.expect(t, btn.copy_text == "foo\x00bar",
			"copy_text must keep bytes after the embedded NUL (#221 M1)")
	}
	testing.expect(t, found, "expected a copy button with copy_text")
}
