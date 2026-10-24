package bridge

import "core:strings"
import "core:sync"
import "core:testing"
import "../types"

// Review C13: `:aspect [:a :b]` is documented (core-api, app-api,
// theme.md, elements.md) as left-to-right composition with state
// variants merged per aspect in the same order, but the bridge read
// :aspect as a string — a table became "" and the node was unthemed.

@(private = "file")
put_theme :: proc(theme: ^map[string]types.Theme, key: string, t: types.Theme) {
	t := t
	if len(t.font) > 0 do t.font = strings.clone(t.font)
	theme[strings.clone(key)] = t
}

@(private = "file")
cleanup_bridge_theme :: proc(b: ^Bridge) {
	free_theme_map(&b.theme)
	free_composed_aspects(b)
}

@(test)
test_compose_theme_entry_later_wins_zero_does_not_override :: proc(t: ^testing.T) {
	theme: map[string]types.Theme
	defer free_theme_map(&theme)
	put_theme(&theme, "button", {bg = {1, 1, 1}, color = {2, 2, 2}, radius = 6})
	put_theme(&theme, "danger", {bg = {9, 0, 0}})

	got, found := compose_theme_entry(theme, {"button", "danger"}, "")
	testing.expect(t, found)
	testing.expect_value(t, got.bg, [3]u8{9, 0, 0})      // later wins
	testing.expect_value(t, got.color, [3]u8{2, 2, 2})   // not overridden by zero
	testing.expect_value(t, got.radius, u8(6))

	// Missing aspects resolve to {} (no error) — the rest still composes.
	got2, found2 := compose_theme_entry(theme, {"nope", "danger"}, "")
	testing.expect(t, found2)
	testing.expect_value(t, got2.bg, [3]u8{9, 0, 0})

	_, found3 := compose_theme_entry(theme, {"nope", "nada"}, "")
	testing.expect(t, !found3, "all-missing composition must be a lookup miss")
}

@(test)
test_flatten_reads_aspect_list_as_composed_key :: proc(t: ^testing.T) {
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
	defer cleanup_bridge_theme(&b)
	defer clear_frame(&b)

	put_theme(&b.theme, "red", {bg = {220, 0, 0}, font = "mono"})
	put_theme(&b.theme, "hr-rule", {padding = {1, 0, 1, 0}, radius = 2})

	rc := luaL_dostring(L, `return {"vbox", {aspect = {"red", "hr-rule"}, height = 20}}`)
	testing.expect_value(t, rc, i32(0))
	cur: [dynamic]u8
	defer delete(cur)
	lua_flatten_node(L, lua_gettop(L), &cur, &b, -1)
	lua_settop(L, 0)

	testing.expect_value(t, len(b.nodes), 1)
	v, ok := b.nodes[0].(types.NodeVbox)
	testing.expect(t, ok)
	key := strings.concatenate({"red", COMPOSED_ASPECT_SEP, "hr-rule"}, context.temp_allocator)
	testing.expect_value(t, v.aspect, key)

	entry, has := b.theme[key]
	testing.expect(t, has, "composed key must resolve in the theme map")
	testing.expect_value(t, entry.bg, [3]u8{220, 0, 0})
	testing.expect_value(t, entry.radius, u8(2))
	testing.expect_value(t, entry.padding, [4]u8{1, 0, 1, 0})
	testing.expect_value(t, entry.font, "mono")
	// The composed entry must own its font (not alias "red"'s), or the
	// theme free loops would double free it.
	testing.expect(t, raw_data(entry.font) != raw_data(b.theme["red"].font))
}

@(test)
test_single_element_aspect_list_is_plain_aspect :: proc(t: ^testing.T) {
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
	defer cleanup_bridge_theme(&b)
	defer clear_frame(&b)

	rc := luaL_dostring(L, `return {"text", {aspect = {"body"}}, "hi"}`)
	testing.expect_value(t, rc, i32(0))
	cur: [dynamic]u8
	defer delete(cur)
	lua_flatten_node(L, lua_gettop(L), &cur, &b, -1)
	lua_settop(L, 0)

	n, ok := b.nodes[0].(types.NodeText)
	testing.expect(t, ok)
	testing.expect_value(t, n.aspect, "body")
	testing.expect_value(t, len(b.composed_aspects), 0)
}

@(test)
test_composed_state_variants_merge_per_state :: proc(t: ^testing.T) {
	sync.lock(&g_test_bridge_global_mutex)
	defer sync.unlock(&g_test_bridge_global_mutex)

	b: Bridge
	defer cleanup_bridge_theme(&b)

	put_theme(&b.theme, "button", {bg = {1, 1, 1}, color = {2, 2, 2}})
	put_theme(&b.theme, "danger", {bg = {9, 0, 0}})
	put_theme(&b.theme, "button#hover", {bg = {5, 5, 5}, radius = 3})
	put_theme(&b.theme, "danger#hover", {bg = {7, 0, 0}})
	put_theme(&b.theme, "button#focus", {border = {4, 4, 4}})

	key := strings.concatenate({"button", COMPOSED_ASPECT_SEP, "danger"}, context.temp_allocator)
	register_composed_aspect(&b, key)

	// Docs: resolve :button, merge :danger, merge :button#hover, merge
	// :danger#hover. The renderer applies base then key#hover, so the
	// #hover entry must be button#hover < danger#hover.
	base := b.theme[key]
	testing.expect_value(t, base.bg, [3]u8{9, 0, 0})
	testing.expect_value(t, base.color, [3]u8{2, 2, 2})

	hover_key := strings.concatenate({key, "#hover"}, context.temp_allocator)
	hover, has_hover := b.theme[hover_key]
	testing.expect(t, has_hover)
	testing.expect_value(t, hover.bg, [3]u8{7, 0, 0})
	testing.expect_value(t, hover.radius, u8(3))

	focus_key := strings.concatenate({key, "#focus"}, context.temp_allocator)
	focus, has_focus := b.theme[focus_key]
	testing.expect(t, has_focus, "#focus exists on one component -> composed #focus exists")
	testing.expect_value(t, focus.border, [3]u8{4, 4, 4})

	active_key := strings.concatenate({key, "#active"}, context.temp_allocator)
	_, has_active := b.theme[active_key]
	testing.expect(t, !has_active, "no component has #active -> no composed #active entry")

	// Synthetic entries are not part of the user's theme.
	testing.expect(t, is_composed_theme_key(&b, key))
	testing.expect(t, is_composed_theme_key(&b, hover_key))
	testing.expect(t, !is_composed_theme_key(&b, "button#hover"))
}

@(test)
test_set_theme_recomposes_registered_aspects :: proc(t: ^testing.T) {
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
	defer cleanup_bridge_theme(&b)
	defer clear_frame(&b)
	// Host cfuncs (redin_set_theme) enter through `context = g_context`.
	saved_ctx := g_context
	g_context = context
	defer g_context = saved_ctx

	// Composition seen at flatten time, before any theme exists.
	rc := luaL_dostring(L, `return {"vbox", {aspect = {"red", "hr-rule"}}}`)
	testing.expect_value(t, rc, i32(0))
	cur: [dynamic]u8
	defer delete(cur)
	lua_flatten_node(L, lua_gettop(L), &cur, &b, -1)
	lua_settop(L, 0)

	key := strings.concatenate({"red", COMPOSED_ASPECT_SEP, "hr-rule"}, context.temp_allocator)
	_, has_before := b.theme[key]
	testing.expect(t, !has_before)

	// set_theme (also the PUT /aspects path) must build it without a re-flatten,
	// and again on every later theme swap.
	lua_pushcfunction(L, redin_set_theme)
	rc = luaL_dostring(L, `return {red = {bg = {200, 0, 0}, font = "mono"}, ["hr-rule"] = {radius = 2}}`)
	testing.expect_value(t, rc, i32(0))
	testing.expect_value(t, lua_pcall(L, 1, 0, 0), i32(0))

	e1, has1 := b.theme[key]
	testing.expect(t, has1)
	testing.expect_value(t, e1.bg, [3]u8{200, 0, 0})
	testing.expect_value(t, e1.radius, u8(2))

	lua_pushcfunction(L, redin_set_theme)
	rc = luaL_dostring(L, `return {red = {bg = {10, 0, 0}}, ["hr-rule"] = {bg = {0, 0, 10}, ["font"] = "serif"}}`)
	testing.expect_value(t, rc, i32(0))
	testing.expect_value(t, lua_pcall(L, 1, 0, 0), i32(0))

	e2, has2 := b.theme[key]
	testing.expect(t, has2)
	testing.expect_value(t, e2.bg, [3]u8{0, 0, 10})
	testing.expect_value(t, e2.radius, u8(0))
	testing.expect_value(t, e2.font, "serif")
}
