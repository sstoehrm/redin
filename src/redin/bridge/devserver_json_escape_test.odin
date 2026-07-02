package bridge

import "core:strings"
import "core:testing"
import rl "vendor:raylib"

// #225 L1: /frames and /agent/nodes emitted the node `tag` / `id` raw, so a
// Lua node whose tag or :id contains a `"` produced structurally broken JSON
// (and could inject an extra key an agent consumer would trust). Both must
// route through json_string.

@(test)
test_frame_tag_is_json_escaped :: proc(t: ^testing.T) {
	L := luaL_newstate()
	luaL_openlibs(L)
	defer lua_close(L)

	// A node whose tag carries a quote + injection attempt.
	testing.expect(t, luaL_dostring(L, `return {'ev"il', {}}`) == 0, "lua build failed")

	b := strings.builder_make()
	defer strings.builder_destroy(&b)
	skips := make(map[i32]i32)
	defer delete(skips)
	dfs := 0
	frame_value_to_json(&b, L, lua_gettop(L), []rl.Rectangle{}, skips, &dfs)
	out := strings.to_string(b)

	testing.expectf(t, strings.contains(out, `\"`), "quote in tag must be escaped: %s", out)
	testing.expectf(t, strings.contains(out, `"ev\"il"`), "tag must be a single escaped string: %s", out)
	// The raw, unescaped `ev"il"` (a broken close) must not appear.
	testing.expectf(t, !strings.contains(out, `ev"il"`), "tag must not close the JSON string early: %s", out)
}

// agent_nodes_walker is compiled only in REDIN_AGENT builds, so this test
// is too. Run it with: odin test src/redin/bridge ... -define:REDIN_AGENT=true
when REDIN_AGENT {
@(test)
test_agent_nodes_id_is_json_escaped :: proc(t: ^testing.T) {
	L := luaL_newstate()
	luaL_openlibs(L)
	defer lua_close(L)

	testing.expect(
		t,
		luaL_dostring(L, `return {'text', {agent='edit', id='a"b'}}`) == 0,
		"lua build failed",
	)

	b := strings.builder_make()
	defer strings.builder_destroy(&b)
	first := true
	agent_nodes_walker(&b, L, lua_gettop(L), &first)
	out := strings.to_string(b)

	testing.expectf(t, strings.contains(out, `"id":"a\"b"`), "id quote must be escaped: %s", out)
	testing.expectf(t, strings.contains(out, `"mode":"edit"`), "mode present: %s", out)
	testing.expectf(t, strings.contains(out, `"type":"text"`), "type present: %s", out)
}
} // when REDIN_AGENT
